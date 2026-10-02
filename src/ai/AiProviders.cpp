#include "AiProviders.h"

#include <QCoreApplication>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QStandardPaths>

namespace {
QString compactError(const QByteArray &body)
{
    const auto json = QJsonDocument::fromJson(body).object();
    const auto error = json.value("error");
    if (error.isObject()) return error.toObject().value("message").toString();
    if (error.isString()) return error.toString();
    return QString::fromUtf8(body.left(300)).simplified();
}
}

HttpStreamProvider::HttpStreamProvider(QNetworkAccessManager *network, QUrl endpoint, QObject *parent)
    : AiProvider(parent), m_network(network), m_endpoint(std::move(endpoint))
{
}

void HttpStreamProvider::post(const QHash<QByteArray, QByteArray> &headers, const QJsonObject &body, bool sse)
{
    m_sse = sse;
    QNetworkRequest request(m_endpoint);
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    for (auto it = headers.cbegin(); it != headers.cend(); ++it) request.setRawHeader(it.key(), it.value());
    // Long answers stream for minutes; only a silent connection counts as a timeout.
    request.setTransferTimeout(120000);
    m_reply = m_network->post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(m_reply, &QNetworkReply::readyRead, this, &HttpStreamProvider::read);
    connect(m_reply, &QNetworkReply::finished, this, [this] {
        if (m_done) return;
        const int status = m_reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (m_reply->error() == QNetworkReply::OperationCanceledError) return;
        if (status >= 400 || (m_reply->error() != QNetworkReply::NoError && status == 0)) {
            fail(errorFrom(status, m_buffer + m_reply->readAll()));
            return;
        }
        read();
        if (!m_done) {
            // A stream that ended without its closing event still produced usable text.
            if (m_text.isEmpty())
                fail("The response ended without an answer.");
            else
                finish(QString());
        }
    });
}

QString HttpStreamProvider::errorFrom(int status, const QByteArray &body) const
{
    const auto detail = compactError(body);
    if (status == 0)
        return "Cannot reach the AI service. Check the connection." + (detail.isEmpty() ? QString() : " " + detail);
    return QStringLiteral("AI service error %1: %2").arg(status).arg(detail);
}

void HttpStreamProvider::read()
{
    if (!m_reply || m_done) return;
    const int status = m_reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status >= 400) {
        m_buffer += m_reply->readAll(); // An error body is read whole when the reply finishes.
        return;
    }
    m_buffer += m_reply->readAll();
    const QByteArray separator = m_sse ? "\n\n" : "\n";
    m_buffer.replace("\r\n", "\n");
    for (qsizetype end; !m_done && (end = m_buffer.indexOf(separator)) >= 0;) {
        const auto chunk = m_buffer.left(end);
        m_buffer.remove(0, end + separator.size());
        if (chunk.trimmed().isEmpty()) continue;
        QString event;
        QByteArray data;
        if (m_sse) {
            for (const auto &line : chunk.split('\n')) {
                if (line.startsWith("event:"))
                    event = QString::fromUtf8(line.mid(6).trimmed());
                else if (line.startsWith("data:"))
                    data += line.mid(5).trimmed();
            }
            if (data == "[DONE]") continue;
        } else
            data = chunk;
        const auto json = QJsonDocument::fromJson(data).object();
        if (json.isEmpty()) continue;
        if (event.isEmpty() && m_sse) event = json.value("type").toString();
        if (!handle(event, json)) break;
    }
}

void HttpStreamProvider::finish(const QString &model)
{
    if (m_done) return;
    m_done = true;
    emit finished(m_text, model);
}

void HttpStreamProvider::fail(const QString &error)
{
    if (m_done) return;
    m_done = true;
    emit failed(error);
}

void HttpStreamProvider::cancel()
{
    if (m_done) return;
    m_done = true;
    if (m_reply) m_reply->abort();
    emit failed("Stopped.");
}

// --- Claude (Messages API) ---------------------------------------------------------------

AnthropicProvider::AnthropicProvider(
    QNetworkAccessManager *network, const QUrl &base, const QString &key, QObject *parent)
    : HttpStreamProvider(network, base.resolved(QUrl("v1/messages")), parent), m_key(key)
{
}

bool anthropicEfforts(const QString &model)
{
    return model.startsWith("claude-opus-5") || model.startsWith("claude-sonnet-5") || model.startsWith("claude-fable");
}

bool anthropicFast(const QString &model)
{
    return model.startsWith("claude-opus-5");
}

void AnthropicProvider::start(const AiRequest &request)
{
    m_model = request.model;
    QJsonArray content;
    for (const auto &image : request.images)
        content.append(QJsonObject{{"type", "image"},
            {"source",
                QJsonObject{{"type", "base64"}, {"media_type", image.mediaType},
                    {"data", QString::fromLatin1(image.data.toBase64())}}}});
    content.append(QJsonObject{{"type", "text"}, {"text", request.text}});
    QJsonArray messages;
    // Earlier turns go back as plain text; thinking blocks are not replayed.
    for (const auto &turn : request.history) messages.append(QJsonObject{{"role", turn.role}, {"content", turn.text}});
    messages.append(QJsonObject{{"role", "user"}, {"content", content}});
    QJsonObject body{{"model", request.model}, {"max_tokens", request.maxTokens}, {"stream", true},
        {"system", request.system}, {"messages", messages}};
    // A safety decline is retried server-side on the model Anthropic recommends for that category.
    const bool fallbacks = request.model.startsWith("claude-opus-5") || request.model.startsWith("claude-sonnet-5-5")
        || request.model.startsWith("claude-fable-5");
    if (fallbacks) body.insert("fallbacks", "default");
    // Reading help is routine work: medium effort unless the reader chose another level (Haiku has none).
    if (anthropicEfforts(request.model))
        body.insert("output_config", QJsonObject{{"effort", request.effort.isEmpty() ? "medium" : request.effort}});
    // Fast mode: the same model at a higher output speed and premium price (Claude Opus 5 / 5.5 only).
    const bool fast = request.fast && anthropicFast(request.model);
    if (fast) body.insert("speed", "fast");
    QHash<QByteArray, QByteArray> headers{{"x-api-key", m_key.toUtf8()}, {"anthropic-version", "2023-06-01"}};
    QStringList betas;
    if (fallbacks) betas << "server-side-fallback-2026-07-01";
    if (fast) betas << "fast-mode-2026-02-01";
    if (!betas.isEmpty()) headers.insert("anthropic-beta", betas.join(',').toUtf8());
    post(headers, body, true);
}

bool AnthropicProvider::handle(const QString &event, const QJsonObject &data)
{
    if (event == "message_start") {
        m_model = data.value("message").toObject().value("model").toString(m_model);
    } else if (event == "content_block_delta") {
        // Thinking and other non-text blocks are not shown.
        const auto delta = data.value("delta").toObject();
        if (delta.value("type").toString() == "text_delta") {
            const auto text = delta.value("text").toString();
            m_text += text;
            emit this->delta(text);
        }
    } else if (event == "message_delta") {
        const auto reason = data.value("delta").toObject().value("stop_reason").toString();
        if (!reason.isEmpty()) m_stopReason = reason;
    } else if (event == "message_stop") {
        if (m_stopReason == "refusal") {
            // A declined answer is discarded, even if part of it streamed.
            fail("Claude declined this request. Rephrase it or try another provider.");
            return false;
        }
        finish(m_model);
        return false;
    } else if (event == "error") {
        fail("Claude: " + data.value("error").toObject().value("message").toString("The service reported an error."));
        return false;
    }
    return true;
}

QString AnthropicProvider::errorFrom(int status, const QByteArray &body) const
{
    if (status == 401) return "Claude rejected the API key. Check it in Settings → AI.";
    if (status == 429) return "Claude rate limit reached. Try again shortly.";
    if (status == 529) return "Claude is temporarily overloaded. Try again shortly.";
    return HttpStreamProvider::errorFrom(status, body);
}

// --- OpenAI (Responses API) --------------------------------------------------------------

OpenAiProvider::OpenAiProvider(QNetworkAccessManager *network, const QUrl &base, const QString &key, QObject *parent)
    : HttpStreamProvider(network, base.resolved(QUrl("v1/responses")), parent), m_key(key)
{
}

void OpenAiProvider::start(const AiRequest &request)
{
    m_model = request.model;
    QJsonArray content{QJsonObject{{"type", "input_text"}, {"text", request.text}}};
    for (const auto &image : request.images)
        content.append(QJsonObject{{"type", "input_image"},
            {"image_url", "data:" + image.mediaType + ";base64," + QString::fromLatin1(image.data.toBase64())}});
    QJsonObject body{{"model", request.model}, {"instructions", request.system}, {"stream", true},
        {"max_output_tokens", request.maxTokens},
        {"input", [&] {
             QJsonArray input;
             for (const auto &turn : request.history)
                 input.append(QJsonObject{{"role", turn.role}, {"content", turn.text}});
             input.append(QJsonObject{{"role", "user"}, {"content", content}});
             return input;
         }()}};
    if (!request.effort.isEmpty()) body.insert("reasoning", QJsonObject{{"effort", request.effort}});
    // OpenAI's faster processing tier.
    if (request.fast) body.insert("service_tier", "priority");
    post({{"Authorization", "Bearer " + m_key.toUtf8()}}, body, true);
}

bool OpenAiProvider::handle(const QString &event, const QJsonObject &data)
{
    if (event == "response.output_text.delta") {
        const auto text = data.value("delta").toString();
        m_text += text;
        emit delta(text);
    } else if (event == "response.completed") {
        finish(data.value("response").toObject().value("model").toString(m_model));
        return false;
    } else if (event == "response.failed" || event == "response.incomplete") {
        const auto response = data.value("response").toObject();
        const auto message = response.value("error").toObject().value("message").toString();
        if (event == "response.incomplete" && !m_text.isEmpty()) {
            finish(response.value("model").toString(m_model));
            return false;
        }
        fail("OpenAI: " + (message.isEmpty() ? QStringLiteral("The response could not be completed.") : message));
        return false;
    } else if (event == "error") {
        fail("OpenAI: " + data.value("message").toString("The service reported an error."));
        return false;
    }
    return true;
}

QString OpenAiProvider::errorFrom(int status, const QByteArray &body) const
{
    if (status == 401) return "OpenAI rejected the API key. Check it in Settings → AI.";
    if (status == 429) return "OpenAI rate limit or quota reached. " + compactError(body);
    return HttpStreamProvider::errorFrom(status, body);
}

// --- Ollama (local) ----------------------------------------------------------------------

OllamaProvider::OllamaProvider(QNetworkAccessManager *network, const QUrl &base, QObject *parent)
    : HttpStreamProvider(network, base.resolved(QUrl("api/chat")), parent)
{
}

void OllamaProvider::start(const AiRequest &request)
{
    m_model = request.model;
    QJsonArray images;
    for (const auto &image : request.images) images.append(QString::fromLatin1(image.data.toBase64()));
    QJsonObject user{{"role", "user"}, {"content", request.text}};
    if (!images.isEmpty()) user.insert("images", images);
    QJsonArray messages{QJsonObject{{"role", "system"}, {"content", request.system}}};
    for (const auto &turn : request.history) messages.append(QJsonObject{{"role", turn.role}, {"content", turn.text}});
    messages.append(user);
    post({}, QJsonObject{{"model", request.model}, {"stream", true}, {"messages", messages}}, false);
}

bool OllamaProvider::handle(const QString &, const QJsonObject &data)
{
    if (data.contains("error")) {
        fail("Ollama: " + data.value("error").toString());
        return false;
    }
    const auto text = data.value("message").toObject().value("content").toString();
    if (!text.isEmpty()) {
        m_text += text;
        emit delta(text);
    }
    if (data.value("done").toBool()) {
        finish(data.value("model").toString(m_model));
        return false;
    }
    return true;
}

// --- OpenAI sign-in through the Codex app server -----------------------------------------

CodexBridge::CodexBridge(QObject *parent) : QObject(parent)
{
    connect(&m_process, &QProcess::readyReadStandardOutput, this, &CodexBridge::readLines);
    connect(&m_process, &QProcess::finished, this, [this] {
        m_ready = false;
        const auto callbacks = std::exchange(m_callbacks, {});
        for (const auto &callback : callbacks) callback({}, "The Codex app server stopped.");
        emit stopped("The Codex app server stopped.");
    });
    connect(&m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart) return;
        const auto callbacks = std::exchange(m_callbacks, {});
        m_waiting.clear();
        const auto message = QStringLiteral("Cannot start Codex (%1). Install the Codex CLI to sign in with ChatGPT.")
                                 .arg(executable().isEmpty() ? QStringLiteral("not found") : executable());
        for (const auto &callback : callbacks) callback({}, message);
        emit stopped(message);
    });
}

CodexBridge::~CodexBridge()
{
    if (m_process.state() == QProcess::NotRunning) return;
    m_process.closeWriteChannel();
    if (!m_process.waitForFinished(1500)) m_process.kill();
    m_process.waitForFinished(1000);
}

QString CodexBridge::executable()
{
    const auto override = qEnvironmentVariable("OWELK_CODEX");
    if (!override.isEmpty()) return override;
    auto found = QStandardPaths::findExecutable("codex");
    // Apps started from Finder do not see the shell's PATH.
    for (const auto *candidate : {"/opt/homebrew/bin/codex", "/usr/local/bin/codex"})
        if (found.isEmpty() && QFileInfo(candidate).isExecutable()) found = candidate;
    return found;
}

void CodexBridge::ensureStarted()
{
    if (m_process.state() != QProcess::NotRunning) return;
    m_ready = false;
    m_buffer.clear();
    const auto program = executable();
    if (program.isEmpty()) {
        QMetaObject::invokeMethod(
            this,
            [this] {
                const auto callbacks = std::exchange(m_callbacks, {});
                m_waiting.clear();
                for (const auto &callback : callbacks)
                    callback({}, "Codex was not found. Install the Codex CLI to sign in with ChatGPT.");
            },
            Qt::QueuedConnection);
        return;
    }
    m_process.start(program, {"app-server"});
    const int id = m_nextId++;
    m_callbacks.insert(id, [this](const QJsonValue &, const QString &error) {
        if (!error.isEmpty()) return;
        m_ready = true;
        send({{"method", "initialized"}});
        const auto waiting = std::exchange(m_waiting, {});
        for (const auto &message : waiting) send(message);
    });
    send({{"id", id}, {"method", "initialize"},
        {"params",
            QJsonObject{{"clientInfo",
                QJsonObject{
                    {"name", "owelk"}, {"title", "Owelk"}, {"version", QCoreApplication::applicationVersion()}}}}}});
}

void CodexBridge::call(const QString &method, const QJsonObject &params, Callback callback)
{
    ensureStarted();
    const int id = m_nextId++;
    m_callbacks.insert(id, std::move(callback));
    const QJsonObject message{{"id", id}, {"method", method}, {"params", params}};
    if (m_ready)
        send(message);
    else
        m_waiting.append(message);
}

void CodexBridge::send(const QJsonObject &message)
{
    m_process.write(QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n');
}

void CodexBridge::readLines()
{
    m_buffer += m_process.readAllStandardOutput();
    for (qsizetype end; (end = m_buffer.indexOf('\n')) >= 0;) {
        const auto json = QJsonDocument::fromJson(m_buffer.left(end)).object();
        m_buffer.remove(0, end + 1);
        if (json.isEmpty()) continue;
        const bool hasId = json.contains("id");
        if (hasId && json.contains("method")) {
            // Owelk only asks questions: decline approvals and any other server request.
            send({{"id", json.value("id")},
                {"error", QJsonObject{{"code", -32601}, {"message", "Not supported by Owelk"}}}});
        } else if (hasId) {
            const auto callback = m_callbacks.take(json.value("id").toInt());
            if (!callback) continue;
            const auto error = json.value("error").toObject().value("message").toString();
            callback(json.value("result"),
                json.contains("error") ? (error.isEmpty() ? QStringLiteral("Codex error") : error) : QString());
        } else if (json.contains("method"))
            emit notification(json.value("method").toString(), json.value("params").toObject());
    }
}

CodexProvider::CodexProvider(CodexBridge *bridge, QObject *parent) : AiProvider(parent), m_bridge(bridge)
{
    connect(m_bridge, &CodexBridge::notification, this, [this](const QString &method, const QJsonObject &params) {
        if (m_done || params.value("threadId").toString() != m_threadId || m_threadId.isEmpty()) return;
        if (method == "item/agentMessage/delta") {
            const auto text = params.value("delta").toString();
            m_text += text;
            emit delta(text);
        } else if (method == "turn/completed") {
            m_done = true;
            const auto turn = params.value("turn").toObject();
            if (turn.value("status").toString() == "completed")
                emit finished(m_text, m_model);
            else
                emit failed("ChatGPT: "
                    + turn.value("error").toObject().value("message").toString(
                        turn.value("status").toString() == "interrupted" ? "Stopped."
                                                                         : "The answer could not be completed."));
        } else if (method == "error" && !params.value("willRetry").toBool()) {
            m_done = true;
            emit failed("ChatGPT: " + params.value("error").toObject().value("message").toString());
        }
    });
    connect(m_bridge, &CodexBridge::stopped, this, [this](const QString &error) {
        if (m_done) return;
        m_done = true;
        emit failed(error);
    });
}

void CodexProvider::start(const AiRequest &request)
{
    m_model = request.model;
    m_effort = request.effort;
    m_fast = request.fast;
    QJsonObject thread{{"ephemeral", true}, {"sandbox", "read-only"}, {"approvalPolicy", "never"},
        {"developerInstructions", request.system}};
    if (!request.model.isEmpty()) thread.insert("model", request.model);
    // Each Owelk request is a fresh read-only thread, so earlier turns travel inside the text.
    QString text = request.text;
    if (!request.history.isEmpty()) {
        QStringList lines{"Earlier in this conversation:"};
        for (const auto &turn : request.history)
            lines << (turn.role == "user" ? "Reader: " : "Assistant: ") + turn.text;
        text = lines.join("\n\n") + "\n\nNew request:\n" + request.text;
    }
    QJsonArray input{QJsonObject{{"type", "text"}, {"text", text}}};
    for (const auto &image : request.images)
        if (!image.path.isEmpty()) input.append(QJsonObject{{"type", "localImage"}, {"path", image.path}});
    QPointer<CodexProvider> self(this);
    m_bridge->call("thread/start", thread, [self, input](const QJsonValue &result, const QString &error) {
        if (!self || self->m_done) return;
        if (!error.isEmpty()) {
            self->m_done = true;
            emit self->failed(error);
            return;
        }
        self->m_threadId = result.toObject().value("thread").toObject().value("id").toString();
        self->m_model = result.toObject().value("model").toString(self->m_model);
        QJsonObject turn{{"threadId", self->m_threadId}, {"input", input}};
        if (!self->m_effort.isEmpty()) turn.insert("effort", self->m_effort);
        // Codex names its fast tier "priority".
        if (self->m_fast) turn.insert("serviceTier", "priority");
        self->m_bridge->call("turn/start", turn, [self](const QJsonValue &turn, const QString &error) {
            if (!self || self->m_done) return;
            if (!error.isEmpty()) {
                self->m_done = true;
                emit self->failed(error);
                return;
            }
            self->m_turnId = turn.toObject().value("turn").toObject().value("id").toString();
        });
    });
}

void CodexProvider::cancel()
{
    if (m_done) return;
    if (!m_threadId.isEmpty() && !m_turnId.isEmpty())
        m_bridge->call("turn/interrupt", {{"threadId", m_threadId}, {"turnId", m_turnId}},
            [](const QJsonValue &, const QString &) { });
    m_done = true;
    emit failed("Stopped.");
}
