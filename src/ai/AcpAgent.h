#pragma once

#include "AiProviders.h"

#include <QJsonArray>
#include <QProcessEnvironment>
#include <QStringList>

// Coding agents that speak the Agent Client Protocol (JSON-RPC over stdio), installed into Owelk's
// data folder from npm on request. Owelk is a read-only client: it offers no file system or terminal,
// and declines every permission request, so an agent can only answer.
struct AcpAgentSpec {
    const char *id, *name, *package, *bin;
    QStringList args;
    const char *sends;
};
const QList<AcpAgentSpec> &acpAgents();
const AcpAgentSpec *acpAgent(const QString &id);

class AcpBridge final : public QObject {
    Q_OBJECT
public:
    AcpBridge(QString program, QStringList args, QProcessEnvironment environment, QString workingDirectory,
        QObject *parent = nullptr);
    ~AcpBridge() override;
    using Callback = std::function<void(const QJsonValue &result, const QJsonObject &error)>;
    void call(const QString &method, const QJsonObject &params, Callback callback);
    void notify(const QString &method, const QJsonObject &params);
    // From initialize: authMethods and agentCapabilities (empty until the agent answered).
    QJsonObject agentInfo() const { return m_initialized; }
    QString workingDirectory() const { return m_workingDirectory; }
    void stop();
signals:
    void notification(const QString &method, const QJsonObject &params);
    void stopped(const QString &error);

private:
    void ensureStarted();
    void send(const QJsonObject &message);
    void readLines();
    void failAll(const QString &message);
    QString m_program;
    QStringList m_args;
    QProcessEnvironment m_environment;
    QString m_workingDirectory;
    QProcess m_process;
    QByteArray m_buffer;
    int m_nextId = 1;
    bool m_ready = false;
    QJsonObject m_initialized;
    QHash<int, Callback> m_callbacks;
    QList<QJsonObject> m_waiting;
};

// One answer through an ACP agent: a fresh session per request (Owelk's thread carries the history).
class AcpProvider final : public AiProvider {
    Q_OBJECT
public:
    AcpProvider(AcpBridge *bridge, QString agentName, QObject *parent = nullptr);
    void start(const AiRequest &request) override;
    void cancel() override;
    static QString errorText(const QString &agentName, const QJsonObject &error);
    // The model choice an agent offers as a session config option (category "model").
    static QJsonObject modelOption(const QJsonObject &session);
    static QVariantList modelChoices(const QJsonObject &option);
    static QJsonObject option(const QJsonObject &session, const QString &category);
    // The agent's most restrictive mode among those it offers (empty when it has no modes).
    static QString safestMode(const QJsonObject &modes);

private:
    void configure(QList<QPair<QString, QString>> settings, const QString &required);
    void prompt();
    void fail(const QString &error);
    AcpBridge *m_bridge;
    QString m_agentName, m_sessionId, m_text, m_model;
    AiRequest m_request;
    bool m_done = false;
};
