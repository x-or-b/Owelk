#include "AiProviders.h"
#include "ChatGptAccount.h"
#include "UiText.h"

#include <QDir>

#include <QCoreApplication>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QStandardPaths>

namespace {
QString compactError(const QByteArray &body)
{
    const auto json = QJsonDocument::fromJson(body).object();
    const auto error = json.value("error");
    if (error.isObject()) return error.toObject().value("message").toString();
    if (error.isString()) return error.toString();
    // ChatGPT plan requests can be turned away before they start, with only a detail.
    if (json.value("detail").isString()) return json.value("detail").toString();
    return QString::fromUtf8(body.left(300)).simplified();
}
// What a ChatGPT plan error means for the reader (empty for the others).
QString planError(const QString &code)
{
    if (code == "subscription_sharing_usage_limit_exceeded")
        return ui("ChatGPT plan usage limit reached. Review it at chatgpt.com/settings/usage.");
    if (code == "subscription_sharing_user_not_eligible")
        return ui("This ChatGPT account cannot use its plan in other apps.");
    if (code == "subscription_sharing_usage_unavailable" || code == "subscription_sharing_user_unavailable")
        return ui("ChatGPT plan usage is unavailable right now. Try again shortly.");
    if (code == "subscription_sharing_invalid_user")
        return ui("ChatGPT did not accept the sign-in. Continue with ChatGPT again in Settings → AI.");
    return {};
}
}

void AiProvider::cite(const QString &url, const QString &title)
{
    if (!url.startsWith("https://") && !url.startsWith("http://")) return;
    for (const auto &seen : std::as_const(m_cited))
        if (seen.first == url) return;
    m_cited.append({url, title.simplified()});
}

QString AiProvider::webSources(const QString &answer) const
{
    QStringList lines;
    for (const auto &[url, title] : m_cited) {
        if (answer.contains(url) || lines.size() >= 8) continue;
        auto name = title.isEmpty() ? QUrl(url).host() : title.left(120);
        name.replace('[', '(').replace(']', ')');
        auto target = url;
        target.replace('(', "%28").replace(')', "%29").replace(' ', "%20");
        lines << "- [" + name + "](" + target + ")";
    }
    return lines.isEmpty() ? QString() : "\n\nSources:\n" + lines.join('\n');
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
    connect(m_reply, &QNetworkReply::finished, this, [this, reply = m_reply.data()] {
        // The reply holds the whole request (paper text, images) until it is deleted.
        reply->deleteLater();
        if (m_done) return;
        const int status = m_reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (m_reply->error() == QNetworkReply::OperationCanceledError) return;
        if (status >= 400 || (m_reply->error() != QNetworkReply::NoError && status == 0)) {
            fail(errorFrom(status, m_buffer + m_reply->readAll()));
            return;
        }
        read();
        if (!m_done) {
            // A stream that ended without its closing event (the connection dropped) still produced usable text:
            // kept, and marked as ending early.
            if (m_text.isEmpty())
                fail(ui("The response ended without an answer."));
            else {
                m_interrupted = true;
                finish(QString());
            }
        }
    });
}

QString HttpStreamProvider::errorFrom(int status, const QByteArray &body) const
{
    const auto detail = compactError(body);
    if (status == 0)
        return ui("Cannot reach the AI service. Check the connection.") + (detail.isEmpty() ? QString() : " " + detail);
    return ui("AI service error %1: %2").arg(status).arg(detail);
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
    // Web pages the answer cites without linking them (Claude's citations): listed after it.
    if (const auto more = webSources(m_text); !more.isEmpty()) {
        m_text += more;
        emit delta(more);
    }
    emit finished(m_text, model);
}

void HttpStreamProvider::think(const QString &text, bool newPart)
{
    if (newPart && m_thought) emit thinkingDelta("\n\n");
    if (text.isEmpty()) return;
    m_thought = true;
    emit thinkingDelta(text);
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

bool anthropicThinks(const QString &model)
{
    return model.startsWith("claude-opus-5") || model.startsWith("claude-sonnet-5") || model.startsWith("claude-fable")
        || model.startsWith("claude-haiku-5") || model.startsWith("claude-mythos");
}

bool anthropicFast(const QString &model)
{
    return model.startsWith("claude-opus-5");
}

// Web search that filters its results before reading them; older models take the basic version.
static bool anthropicFiltersSearch(const QString &model)
{
    return model.startsWith("claude-opus-5") || model.startsWith("claude-sonnet-5")
        || model.startsWith("claude-opus-4-6") || model.startsWith("claude-opus-4-7")
        || model.startsWith("claude-opus-4-8") || model.startsWith("claude-sonnet-4-6");
}

void AnthropicProvider::start(const AiRequest &request)
{
    m_model = request.model;
    QJsonArray content;
    // The paper first, with its own cache mark: later questions about it read it from the cache.
    if (!request.context.isEmpty())
        content.append(QJsonObject{
            {"type", "text"}, {"text", request.context}, {"cache_control", QJsonObject{{"type", "ephemeral"}}}});
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
    // Follow-ups resend the conversation (a whole paper, often): cached, the repeat costs a tenth.
    body.insert("cache_control", QJsonObject{{"type", "ephemeral"}});
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
    // These models think anyway; "summarized" makes the reasoning readable instead of empty.
    if (request.thinkingSummary && anthropicThinks(request.model))
        body.insert("thinking", QJsonObject{{"type", "adaptive"}, {"display", "summarized"}});
    // Anthropic's own web search, a few searches per answer.
    if (request.webSearch)
        body.insert("tools",
            QJsonArray{QJsonObject{
                {"type", anthropicFiltersSearch(request.model) ? "web_search_20260209" : "web_search_20250305"},
                {"name", "web_search"}, {"max_uses", 5}}});
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
    } else if (event == "content_block_start") {
        // Each thinking block is a paragraph of the summary.
        const auto block = data.value("content_block").toObject();
        if (block.value("type").toString() == "thinking") think({}, true);
        if (block.value("type").toString() == "server_tool_use" && block.value("name").toString() == "web_search") {
            m_searchBlock = data.value("index").toInt();
            m_searchInput.clear();
            emit status(ui("Searching the web…"));
        }
    } else if (event == "content_block_delta") {
        // Text is the answer, thinking the summarized reasoning; signatures and other blocks are not shown.
        const auto delta = data.value("delta").toObject();
        const auto type = delta.value("type").toString();
        if (type == "text_delta") {
            const auto text = delta.value("text").toString();
            m_text += text;
            emit this->delta(text);
        } else if (type == "thinking_delta")
            think(delta.value("thinking").toString());
        else if (type == "input_json_delta" && data.value("index").toInt() == m_searchBlock)
            m_searchInput += delta.value("partial_json").toString();
        else if (type == "citations_delta") {
            const auto citation = delta.value("citation").toObject();
            if (citation.value("type").toString() == "web_search_result_location")
                cite(citation.value("url").toString(), citation.value("title").toString());
        }
    } else if (event == "content_block_stop") {
        if (data.value("index").toInt() == m_searchBlock) {
            m_searchBlock = -1;
            const auto query = QJsonDocument::fromJson(m_searchInput.toUtf8()).object().value("query").toString();
            if (!query.trimmed().isEmpty()) emit status(QString(ui("Searching the web: %1")).arg(query.simplified()));
        }
    } else if (event == "message_delta") {
        const auto reason = data.value("delta").toObject().value("stop_reason").toString();
        if (!reason.isEmpty()) m_stopReason = reason;
    } else if (event == "message_stop") {
        m_cutOff = m_stopReason == "max_tokens";
        // Paused during a long web search: kept as far as it got, marked as ending early.
        if (m_stopReason == "pause_turn") {
            if (m_text.isEmpty()) {
                fail(ui("Claude paused while searching the web. Ask again."));
                return false;
            }
            m_interrupted = true;
        }
        if (m_stopReason == "refusal") {
            // A declined answer is discarded, even if part of it streamed.
            fail(ui("Claude declined this request. Rephrase it or try another provider."));
            return false;
        }
        finish(m_model);
        return false;
    } else if (event == "error") {
        fail(ui("Claude: ")
            + data.value("error").toObject().value("message").toString(ui("The service reported an error.")));
        return false;
    }
    return true;
}

QString AnthropicProvider::errorFrom(int status, const QByteArray &body) const
{
    if (status == 401) return ui("Claude rejected the API key. Check it in Settings → AI.");
    if (status == 429) return ui("Claude rate limit reached. Try again shortly.");
    if (status == 529) return ui("Claude is temporarily overloaded. Try again shortly.");
    return HttpStreamProvider::errorFrom(status, body);
}

// --- OpenAI (Responses API) --------------------------------------------------------------

OpenAiProvider::OpenAiProvider(QNetworkAccessManager *network, const QUrl &base, const QString &key, QObject *parent)
    : HttpStreamProvider(network, base.resolved(QUrl("v1/responses")), parent), m_key(key)
{
}

OpenAiProvider::OpenAiProvider(
    QNetworkAccessManager *network, const QUrl &base, ChatGptAccount *account, QObject *parent)
    : HttpStreamProvider(network, base.resolved(QUrl("v1/responses")), parent), m_account(account), m_plan(true)
{
}

void OpenAiProvider::start(const AiRequest &request)
{
    m_model = request.model;
    QJsonArray content{QJsonObject{{"type", "input_text"}, {"text", request.fullText()}}};
    for (const auto &image : request.images)
        content.append(QJsonObject{{"type", "input_image"},
            {"image_url", "data:" + image.mediaType + ";base64," + QString::fromLatin1(image.data.toBase64())}});
    QJsonObject body{{"model", request.model}, {"instructions", request.system}, {"stream", true},
        {"input", [&] {
             QJsonArray input;
             for (const auto &turn : request.history)
                 input.append(QJsonObject{{"role", turn.role}, {"content", turn.text}});
             input.append(QJsonObject{{"role", "user"}, {"content", content}});
             return input;
         }()}};
    QJsonObject reasoning;
    if (!request.effort.isEmpty()) reasoning.insert("effort", request.effort);
    if (request.thinkingSummary && openAiReasons(request.model)) reasoning.insert("summary", "auto");
    if (!reasoning.isEmpty()) body.insert("reasoning", reasoning);
    // OpenAI's own web search.
    if (request.webSearch) body.insert("tools", QJsonArray{QJsonObject{{"type", "web_search"}}});
    if (!m_plan) {
        body.insert("max_output_tokens", request.maxTokens);
        if (request.webSearch) body.insert("max_tool_calls", 5);
        // OpenAI's faster processing tier.
        if (request.fast) body.insert("service_tier", "priority");
        post({{"Authorization", "Bearer " + m_key.toUtf8()}}, body, true);
        return;
    }
    body.insert("store", false);
    if (!m_account) {
        fail(ui("Continue with ChatGPT in Settings → AI."));
        return;
    }
    // The token may be refreshed first; a request stopped meanwhile is not sent.
    m_account->withAccessToken(this, [this, body](const QString &token, const QString &error) {
        if (m_done) return;
        if (token.isEmpty())
            fail(error);
        else
            post({{"Authorization", "Bearer " + token.toUtf8()}}, body, true);
    });
}

bool openAiReasons(const QString &model)
{
    static const QRegularExpression reasoning("^(gpt-[5-9]|o\\d)");
    return reasoning.match(model).hasMatch();
}

bool OpenAiProvider::handle(const QString &event, const QJsonObject &data)
{
    if (event == "response.reasoning_summary_part.added") {
        think({}, true);
    } else if (event == "response.reasoning_summary_text.delta") {
        think(data.value("delta").toString());
    } else if (event == "response.output_text.delta") {
        const auto text = data.value("delta").toString();
        m_text += text;
        emit delta(text);
    } else if (event == "response.output_item.added" || event == "response.output_item.done") {
        // A web search: its words once known.
        const auto item = data.value("item").toObject();
        if (item.value("type").toString() == "web_search_call") {
            const auto query = item.value("action").toObject().value("query").toString().simplified();
            emit status(query.isEmpty() ? ui("Searching the web…") : QString(ui("Searching the web: %1")).arg(query));
        }
    } else if (event == "response.output_text.annotation.added") {
        const auto annotation = data.value("annotation").toObject();
        if (annotation.value("type").toString() == "url_citation")
            cite(annotation.value("url").toString(), annotation.value("title").toString());
    } else if (event == "response.completed") {
        finish(data.value("response").toObject().value("model").toString(m_model));
        return false;
    } else if (event == "response.failed" || event == "response.incomplete") {
        const auto response = data.value("response").toObject();
        const auto message = response.value("error").toObject().value("message").toString();
        if (event == "response.incomplete" && !m_text.isEmpty()) {
            m_cutOff
                = response.value("incomplete_details").toObject().value("reason").toString() == "max_output_tokens";
            finish(response.value("model").toString(m_model));
            return false;
        }
        // The plan's usage limit can also end an answer already streaming.
        if (const auto plan
            = m_plan ? planError(response.value("error").toObject().value("code").toString()) : QString();
            !plan.isEmpty())
            fail(plan);
        else
            fail((m_plan ? ui("ChatGPT: ") : ui("OpenAI: "))
                + (message.isEmpty() ? ui("The response could not be completed.") : message));
        return false;
    } else if (event == "error") {
        if (const auto plan = m_plan ? planError(data.value("code").toString()) : QString(); !plan.isEmpty())
            fail(plan);
        else
            fail((m_plan ? ui("ChatGPT: ") : ui("OpenAI: "))
                + data.value("message").toString(ui("The service reported an error.")));
        return false;
    }
    return true;
}

QString OpenAiProvider::errorFrom(int status, const QByteArray &body) const
{
    if (m_plan) {
        const auto plan
            = planError(QJsonDocument::fromJson(body).object().value("error").toObject().value("code").toString());
        if (!plan.isEmpty()) return plan;
        if (status == 401)
            return ui("ChatGPT did not accept the sign-in. Continue with ChatGPT again in Settings → AI.");
        if (status == 429) return ui("ChatGPT plan usage limit reached. Review it at chatgpt.com/settings/usage.");
        if (status == 503) return ui("ChatGPT plan usage is unavailable right now. Try again shortly.");
        return HttpStreamProvider::errorFrom(status, body);
    }
    if (status == 401) return ui("OpenAI rejected the API key. Check it in Settings → AI.");
    if (status == 429) return ui("OpenAI rate limit or quota reached. ") + compactError(body);
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
    QJsonObject user{{"role", "user"}, {"content", request.fullText()}};
    if (!images.isEmpty()) user.insert("images", images);
    QJsonArray messages{QJsonObject{{"role", "system"}, {"content", request.system}}};
    for (const auto &turn : request.history) messages.append(QJsonObject{{"role", turn.role}, {"content", turn.text}});
    messages.append(user);
    // Ollama's own window (a few thousand tokens) silently drops the start of a paper. One fixed size for every
    // request, so the model is not reloaded between questions.
    post({},
        QJsonObject{{"model", request.model}, {"stream", true}, {"messages", messages},
            {"options", QJsonObject{{"num_ctx", 16384}}}},
        false);
}

bool OllamaProvider::handle(const QString &, const QJsonObject &data)
{
    if (data.contains("error")) {
        fail(ui("Ollama: ") + data.value("error").toString());
        return false;
    }
    // Thinking models put their reasoning beside the answer.
    think(data.value("message").toObject().value("thinking").toString());
    const auto text = data.value("message").toObject().value("content").toString();
    if (!text.isEmpty()) {
        m_text += text;
        emit delta(text);
    }
    if (data.value("done").toBool()) {
        m_cutOff = data.value("done_reason").toString() == "length";
        finish(data.value("model").toString(m_model));
        return false;
    }
    return true;
}

// --- OpenAI sign-in through the Codex app server -----------------------------------------

#if QT_CONFIG(process)
CodexBridge::CodexBridge(QObject *parent) : QObject(parent)
{
    connect(&m_process, &QProcess::readyReadStandardOutput, this, &CodexBridge::readLines);
    connect(&m_process, &QProcess::finished, this, [this] {
        m_ready = false;
        m_waiting.clear(); // Their callbacks are answered below; a new process must not replay them.
        const auto callbacks = std::exchange(m_callbacks, {});
        for (const auto &callback : callbacks) callback({}, "The Codex app server stopped.");
        emit stopped("The Codex app server stopped.");
    });
    connect(&m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart) return;
        const auto callbacks = std::exchange(m_callbacks, {});
        m_waiting.clear();
        const auto message = ui("Cannot start Codex (%1). Install the Codex CLI to sign in with ChatGPT.")
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
    if (!found.isEmpty()) return found;
    // Apps started from Finder, a desktop launcher or the Start menu often miss the shell's PATH:
    // look where Homebrew, npm and pipx-style installs put the command.
    const auto home = QDir::homePath();
    QStringList folders{"/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin",
        home + "/.volta/bin", home + "/bin"};
#ifdef Q_OS_WIN
    folders = {qEnvironmentVariable("APPDATA") + "/npm", qEnvironmentVariable("LOCALAPPDATA") + "/Programs/codex"};
#endif
    return QStandardPaths::findExecutable("codex", folders);
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
    // Its log on stderr is not read; kept, it would only grow in memory for as long as the process runs.
    m_process.setStandardErrorFile(QProcess::nullDevice());
    // npm installs a .cmd launcher on Windows; scripts (tests) run through their interpreter.
    if (program.endsWith(".cmd", Qt::CaseInsensitive) || program.endsWith(".bat", Qt::CaseInsensitive))
        m_process.start("cmd.exe", {"/c", program, "app-server"});
    else if (program.endsWith(".py"))
        m_process.start(
            QStandardPaths::findExecutable("python3").isEmpty() ? "python" : "python3", {program, "app-server"});
    else
        m_process.start(program, {"app-server"});
    const int id = m_nextId++;
    m_callbacks.insert(id, [this](const QJsonValue &, const QString &error) {
        // Refused to start: stopping it answers everything waiting (finished), instead of leaving it waiting forever.
        if (!error.isEmpty()) {
            m_process.kill();
            return;
        }
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
                json.contains("error") ? (error.isEmpty() ? ui("Codex error") : error) : QString());
        } else if (json.contains("method"))
            emit notification(json.value("method").toString(), json.value("params").toObject());
    }
}
#else
CodexBridge::CodexBridge(QObject *parent) : QObject(parent) { }

CodexBridge::~CodexBridge() = default;

QString CodexBridge::executable()
{
    return {};
}

void CodexBridge::ensureStarted() { }

void CodexBridge::send(const QJsonObject &) { }

void CodexBridge::readLines() { }

void CodexBridge::call(const QString &, const QJsonObject &, Callback callback)
{
    QMetaObject::invokeMethod(
        this, [callback] { callback({}, ui("ChatGPT account (Codex) cannot run on this device.")); },
        Qt::QueuedConnection);
}
#endif

CodexProvider::CodexProvider(CodexBridge *bridge, QObject *parent) : AiProvider(parent), m_bridge(bridge)
{
    connect(m_bridge, &CodexBridge::notification, this, [this](const QString &method, const QJsonObject &params) {
        if (m_done || params.value("threadId").toString() != m_threadId || m_threadId.isEmpty()) return;
        if (method == "item/agentMessage/delta") {
            const auto item = params.value("itemId").toString();
            auto text = params.value("delta").toString();
            if (m_commentary.contains(item)) {
                if (!text.isEmpty()) {
                    m_thought = true;
                    emit thinkingDelta(text);
                }
                return;
            }
            if (item != m_textItem && !m_text.isEmpty() && !text.isEmpty() && !m_text.endsWith("\n\n"))
                text.prepend(m_text.endsWith('\n') ? "\n" : "\n\n");
            m_textItem = item;
            m_text += text;
            emit delta(text);
        } else if (method == "item/started" || method == "item/completed") {
            const auto item = params.value("item").toObject();
            const auto type = item.value("type").toString();
            if (type == "webSearch") {
                const auto query = item.value("query").toString().simplified();
                if (!query.isEmpty())
                    emit status(QString(ui("Searching the web: %1")).arg(query));
                else if (method == "item/started")
                    emit status(ui("Searching the web…"));
            } else if (type == "agentMessage" && method == "item/started"
                && item.value("phase").toString() == "commentary") {
                m_commentary << item.value("id").toString();
                if (m_thought) emit thinkingDelta("\n\n");
            }
        } else if (method == "item/reasoning/summaryPartAdded") {
            if (m_thought) emit thinkingDelta("\n\n");
        } else if (method == "item/reasoning/summaryTextDelta") {
            const auto text = params.value("delta").toString();
            if (!text.isEmpty()) {
                m_thought = true;
                emit thinkingDelta(text);
            }
        } else if (method == "turn/completed") {
            m_done = true;
            const auto turn = params.value("turn").toObject();
            if (turn.value("status").toString() == "completed")
                emit finished(m_text, m_model);
            else
                emit failed(ui("ChatGPT: ")
                    + turn.value("error").toObject().value("message").toString(
                        turn.value("status").toString() == "interrupted" ? "Stopped."
                                                                         : ui("The answer could not be completed.")));
        } else if (method == "error" && !params.value("willRetry").toBool()) {
            m_done = true;
            emit failed(ui("ChatGPT: ") + params.value("error").toObject().value("message").toString());
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
    m_summary = request.thinkingSummary;
    // Codex's own web search, live, only when the reader turned it on (its default may search a cache).
    QJsonObject thread{{"ephemeral", true}, {"sandbox", "read-only"}, {"approvalPolicy", "never"},
        {"developerInstructions", request.system},
        {"config", QJsonObject{{"web_search", request.webSearch ? "live" : "disabled"}}}};
    if (!request.model.isEmpty()) thread.insert("model", request.model);
    // Each Owelk request is a fresh read-only thread, so earlier turns travel inside the text.
    QString text = request.fullText();
    if (!request.history.isEmpty()) {
        QStringList lines{"Earlier in this conversation:"};
        for (const auto &turn : request.history)
            lines << (turn.role == "user" ? "Reader: " : "Assistant: ") + turn.text;
        text = lines.join("\n\n") + "\n\nNew request:\n" + request.fullText();
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
        if (self->m_summary) turn.insert("summary", "auto");
        const QPointer<CodexBridge> bridge = self->m_bridge;
        self->m_bridge->call("turn/start", turn,
            [self, bridge, threadId = self->m_threadId](const QJsonValue &turn, const QString &error) {
                // Stopped while the turn was starting: it is stopped now too, not left answering on the account.
                if (!self || self->m_done) {
                    const auto turnId = turn.toObject().value("turn").toObject().value("id").toString();
                    if (bridge && error.isEmpty() && !turnId.isEmpty())
                        bridge->call("turn/interrupt", {{"threadId", threadId}, {"turnId", turnId}},
                            [](const QJsonValue &, const QString &) { });
                    return;
                }
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
