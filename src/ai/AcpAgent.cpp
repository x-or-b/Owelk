#include "AcpAgent.h"

#include <QCoreApplication>
#include <QJsonDocument>
#include <utility>

const QList<AcpAgentSpec> &acpAgents()
{
    // --hide-claude-auth: the official adapter's mode for apps that must never bill a claude.ai
    // subscription; Claude Agent runs only on the user's Claude API key.
    static const QList<AcpAgentSpec> agents{
        {"claude-agent", "Claude Agent", "@agentclientprotocol/claude-agent-acp", "claude-agent-acp",
            {"--hide-claude-auth"}, "Anthropic via Claude Agent"},
        {"codex-agent", "Codex Agent", "@agentclientprotocol/codex-acp", "codex-acp", {}, "OpenAI via Codex Agent"},
        {"gemini-agent", "Gemini CLI", "@google/gemini-cli", "gemini", {"--acp"}, "Google via Gemini CLI"},
    };
    return agents;
}

const AcpAgentSpec *acpAgent(const QString &id)
{
    for (const auto &agent : acpAgents())
        if (id == QLatin1String(agent.id)) return &agent;
    return nullptr;
}

AcpBridge::AcpBridge(
    QString program, QStringList args, QProcessEnvironment environment, QString workingDirectory, QObject *parent)
    : QObject(parent), m_program(std::move(program)), m_args(std::move(args)), m_environment(std::move(environment)),
      m_workingDirectory(std::move(workingDirectory))
{
    m_process.setProcessEnvironment(m_environment);
    m_process.setWorkingDirectory(m_workingDirectory);
    connect(&m_process, &QProcess::readyReadStandardOutput, this, &AcpBridge::readLines);
    connect(&m_process, &QProcess::finished, this, [this] {
        m_ready = false;
        failAll("The agent stopped.");
    });
    connect(&m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) failAll("Cannot start the agent. Reinstall it in Settings → AI.");
    });
}

AcpBridge::~AcpBridge()
{
    stop();
}

void AcpBridge::stop()
{
    if (m_process.state() == QProcess::NotRunning) return;
    m_process.closeWriteChannel();
    if (!m_process.waitForFinished(1500)) m_process.kill();
    m_process.waitForFinished(1000);
}

void AcpBridge::failAll(const QString &message)
{
    const auto callbacks = std::exchange(m_callbacks, {});
    m_waiting.clear();
    for (const auto &callback : callbacks) callback({}, {{"message", message}});
    emit stopped(message);
}

void AcpBridge::ensureStarted()
{
    if (m_process.state() != QProcess::NotRunning) return;
    m_ready = false;
    m_buffer.clear();
    m_initialized = {};
    m_process.start(m_program, m_args);
    const int id = m_nextId++;
    m_callbacks.insert(id, [this](const QJsonValue &result, const QJsonObject &error) {
        if (!error.isEmpty()) return;
        m_initialized = result.toObject();
        m_ready = true;
        const auto waiting = std::exchange(m_waiting, {});
        for (const auto &message : waiting) send(message);
    });
    // Read-only client: no file access, no terminal for the agent.
    send({{"jsonrpc", "2.0"}, {"id", id}, {"method", "initialize"},
        {"params",
            QJsonObject{{"protocolVersion", 1},
                {"clientCapabilities",
                    QJsonObject{
                        {"fs", QJsonObject{{"readTextFile", false}, {"writeTextFile", false}}}, {"terminal", false}}},
                {"clientInfo",
                    QJsonObject{{"name", "owelk"}, {"title", "Owelk"},
                        {"version", QCoreApplication::applicationVersion()}}}}}});
}

void AcpBridge::call(const QString &method, const QJsonObject &params, Callback callback)
{
    ensureStarted();
    const int id = m_nextId++;
    m_callbacks.insert(id, std::move(callback));
    const QJsonObject message{{"jsonrpc", "2.0"}, {"id", id}, {"method", method}, {"params", params}};
    if (m_ready)
        send(message);
    else
        m_waiting.append(message);
}

void AcpBridge::notify(const QString &method, const QJsonObject &params)
{
    if (m_process.state() == QProcess::NotRunning) return;
    const QJsonObject message{{"jsonrpc", "2.0"}, {"method", method}, {"params", params}};
    if (m_ready)
        send(message);
    else
        m_waiting.append(message);
}

void AcpBridge::send(const QJsonObject &message)
{
    m_process.write(QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n');
}

void AcpBridge::readLines()
{
    m_buffer += m_process.readAllStandardOutput();
    for (qsizetype end; (end = m_buffer.indexOf('\n')) >= 0;) {
        const auto json = QJsonDocument::fromJson(m_buffer.left(end)).object();
        m_buffer.remove(0, end + 1);
        if (json.isEmpty()) continue;
        const bool hasId = json.contains("id");
        const auto method = json.value("method").toString();
        if (hasId && !method.isEmpty()) {
            // Owelk only asks questions: every tool permission is declined, and file or terminal
            // requests are not supported.
            if (method == "session/request_permission") {
                QString reject;
                for (const auto &value : json.value("params").toObject().value("options").toArray()) {
                    const auto option = value.toObject();
                    if (option.value("kind").toString() == "reject_once") reject = option.value("optionId").toString();
                }
                const auto outcome = reject.isEmpty() ? QJsonObject{{"outcome", "cancelled"}}
                                                      : QJsonObject{{"outcome", "selected"}, {"optionId", reject}};
                send({{"jsonrpc", "2.0"}, {"id", json.value("id")}, {"result", QJsonObject{{"outcome", outcome}}}});
            } else
                send({{"jsonrpc", "2.0"}, {"id", json.value("id")},
                    {"error", QJsonObject{{"code", -32601}, {"message", "Not supported by Owelk"}}}});
        } else if (hasId) {
            const auto callback = m_callbacks.take(json.value("id").toInt());
            if (callback) callback(json.value("result"), json.value("error").toObject());
        } else if (!method.isEmpty())
            emit notification(method, json.value("params").toObject());
    }
}

AcpProvider::AcpProvider(AcpBridge *bridge, QString agentName, QObject *parent)
    : AiProvider(parent), m_bridge(bridge), m_agentName(std::move(agentName))
{
    connect(m_bridge, &AcpBridge::notification, this, [this](const QString &method, const QJsonObject &params) {
        if (m_done || method != "session/update" || params.value("sessionId").toString() != m_sessionId) return;
        const auto update = params.value("update").toObject();
        if (update.value("sessionUpdate").toString() != "agent_message_chunk") return;
        const auto content = update.value("content").toObject();
        if (content.value("type").toString() != "text") return;
        const auto text = content.value("text").toString();
        m_text += text;
        emit delta(text);
    });
    connect(m_bridge, &AcpBridge::stopped, this, [this](const QString &error) { fail(m_agentName + ": " + error); });
}

QString AcpProvider::errorText(const QString &agentName, const QJsonObject &error)
{
    // -32000 is ACP's "authentication required".
    if (error.value("code").toInt() == -32000) return agentName + ": sign in first in Settings → AI.";
    const auto message = error.value("message").toString();
    return agentName + ": " + (message.isEmpty() ? QStringLiteral("The agent could not answer.") : message);
}

QJsonObject AcpProvider::modelOption(const QJsonObject &session)
{
    return option(session, "model");
}

QVariantList AcpProvider::modelChoices(const QJsonObject &option)
{
    QVariantList models;
    const auto add = [&](const QJsonObject &choice) {
        const auto value = choice.value("value").toString();
        if (!value.isEmpty())
            models.append(QVariantMap{{"id", value}, {"name", choice.value("name").toString(value)},
                {"isDefault", value == option.value("currentValue").toString()}});
    };
    for (const auto &value : option.value("options").toArray()) {
        const auto entry = value.toObject();
        if (entry.contains("group"))
            for (const auto &choice : entry.value("options").toArray()) add(choice.toObject());
        else
            add(entry);
    }
    return models;
}

QJsonObject AcpProvider::option(const QJsonObject &session, const QString &category)
{
    for (const auto &value : session.value("configOptions").toArray()) {
        const auto entry = value.toObject();
        if (entry.value("category").toString() == category && entry.value("type").toString() == "select") return entry;
    }
    return {};
}

QString AcpProvider::safestMode(const QJsonObject &modes)
{
    // Read-only first; otherwise the mode that asks before every change (Owelk declines the asks).
    const auto values = modelChoices(modes);
    for (const auto *preferred : {"read-only", "default", "plan"})
        for (const auto &value : values)
            if (value.toMap().value("id").toString() == QLatin1String(preferred)) return preferred;
    return {};
}

void AcpProvider::start(const AiRequest &request)
{
    m_request = request;
    m_model = request.model;
    QPointer<AcpProvider> self(this);
    m_bridge->call("session/new", {{"cwd", m_bridge->workingDirectory()}, {"mcpServers", QJsonArray()}},
        [self](const QJsonValue &result, const QJsonObject &error) {
            if (!self || self->m_done) return;
            if (!error.isEmpty()) return self->fail(errorText(self->m_agentName, error));
            const auto session = result.toObject();
            self->m_sessionId = session.value("sessionId").toString();
            const auto modes = option(session, "mode");
            const auto mode = safestMode(modes);
            const auto models = modelOption(session);
            if (self->m_model.isEmpty()) self->m_model = models.value("currentValue").toString();
            QList<QPair<QString, QString>> settings;
            if (!mode.isEmpty() && mode != modes.value("currentValue").toString())
                settings.append({modes.value("id").toString(), mode});
            if (!models.isEmpty() && self->m_model != models.value("currentValue").toString())
                settings.append({models.value("id").toString(), self->m_model});
            self->configure(settings, !mode.isEmpty() ? modes.value("id").toString() : QString());
        });
}

void AcpProvider::configure(QList<QPair<QString, QString>> settings, const QString &required)
{
    if (settings.isEmpty()) return prompt();
    const auto [id, value] = settings.takeFirst();
    QPointer<AcpProvider> self(this);
    m_bridge->call("session/set_config_option", {{"sessionId", m_sessionId}, {"configId", id}, {"value", value}},
        [self, settings, required, id](const QJsonValue &, const QJsonObject &error) {
            if (!self || self->m_done) return;
            // The question is only sent once the agent is in its safest mode; an unknown model just
            // keeps the agent's default.
            if (!error.isEmpty() && id == required)
                return self->fail(self->m_agentName + ": cannot switch the agent to a read-only mode.");
            self->configure(settings, required);
        });
}

void AcpProvider::prompt()
{
    // A fresh session per request: the thread's earlier turns travel in the text.
    QStringList parts;
    if (!m_request.system.isEmpty()) parts << m_request.system;
    if (!m_request.history.isEmpty()) {
        QStringList lines{"Earlier in this conversation:"};
        for (const auto &turn : m_request.history)
            lines << (turn.role == "user" ? "Reader: " : "Assistant: ") + turn.text;
        parts << lines.join("\n\n") << "New request:";
    }
    parts << m_request.text;
    QJsonArray blocks{QJsonObject{{"type", "text"}, {"text", parts.join("\n\n")}}};
    const bool images = m_bridge->agentInfo()
                            .value("agentCapabilities")
                            .toObject()
                            .value("promptCapabilities")
                            .toObject()
                            .value("image")
                            .toBool();
    if (images)
        for (const auto &image : m_request.images)
            if (!image.data.isEmpty())
                blocks.append(QJsonObject{{"type", "image"}, {"data", QString::fromLatin1(image.data.toBase64())},
                    {"mimeType", image.mediaType}});
    QPointer<AcpProvider> self(this);
    m_bridge->call("session/prompt", {{"sessionId", m_sessionId}, {"prompt", blocks}},
        [self](const QJsonValue &result, const QJsonObject &error) {
            if (!self || self->m_done) return;
            if (!error.isEmpty()) return self->fail(errorText(self->m_agentName, error));
            const auto reason = result.toObject().value("stopReason").toString();
            if (reason == "cancelled") return self->fail("Stopped.");
            if (reason == "refusal") return self->fail(self->m_agentName + " declined to answer this request.");
            self->m_done = true;
            emit self->finished(self->m_text, self->m_model);
        });
}

void AcpProvider::fail(const QString &error)
{
    if (m_done) return;
    m_done = true;
    emit failed(error);
}

void AcpProvider::cancel()
{
    if (m_done) return;
    if (!m_sessionId.isEmpty()) m_bridge->notify("session/cancel", {{"sessionId", m_sessionId}});
    fail("Stopped.");
}
