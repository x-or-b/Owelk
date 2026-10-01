#pragma once

#include <QHash>
#include <QObject>
#include <QPointer>
#include <QVariantList>
#include <QVariantMap>

class AiProvider;
class CodexBridge;
class QNetworkAccessManager;
class ResearchStore;

// Reading help from an AI provider: builds the request from the paper, page, selection, captures and
// notes, streams the answer, and keeps keys in the Keychain. Nothing is sent before the user agreed
// to what a provider receives (consent is per provider).
class AiService final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList providers READ providers NOTIFY providersChanged)
    Q_PROPERTY(QString provider READ provider WRITE setProvider NOTIFY providersChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
public:
    explicit AiService(ResearchStore *store, QObject *parent = nullptr);
    ~AiService() override;
    // id, name, kind (api | local | account), sends (where data goes), configured, model.
    QVariantList providers() const;
    QString provider() const;
    void setProvider(const QString &id);
    bool busy() const { return !m_running.isEmpty(); }

    Q_INVOKABLE QString model(const QString &provider) const;
    Q_INVOKABLE void setModel(const QString &provider, const QString &model);
    Q_INVOKABLE bool setApiKey(const QString &provider, const QString &key);
    Q_INVOKABLE bool hasApiKey(const QString &provider) const;
    Q_INVOKABLE bool clearApiKey(const QString &provider);
    Q_INVOKABLE bool consented(const QString &provider) const;
    Q_INVOKABLE void giveConsent(const QString &provider);
    // spec: provider, action (explain|translate|summarize|ask|figure), question, source, page (0-based),
    // scope (selection|page|paper|none), selection, captureId, noteIds. Returns a request id.
    // threadId continues a conversation (earlier turns are sent along); empty starts a new thread.
    Q_INVOKABLE int ask(const QVariantMap &spec);
    // Models the provider offers: Claude's current lineup, the OpenAI/Ollama/Codex lists from the service.
    Q_INVOKABLE void listModels(const QString &provider);
    Q_INVOKABLE void cancel(int request);
    Q_INVOKABLE void testConnection(const QString &provider);
    // Codex app server: account status, ChatGPT sign-in (opens the browser) and sign-out.
    Q_INVOKABLE void refreshCodexAccount();
    Q_INVOKABLE void codexSignIn();
    Q_INVOKABLE void codexSignOut();
    Q_INVOKABLE void listOllamaModels();

signals:
    void providersChanged();
    void busyChanged();
    void started(int request, const QString &threadId, const QString &provider, const QString &model, bool truncated);
    void delta(int request, const QString &text);
    void finished(int request, const QString &text, const QVariantMap &details);
    void failed(int request, const QString &error);
    void connectionTested(const QString &provider, bool ok, const QString &detail);
    void codexAccountChanged(const QVariantMap &account);
    void ollamaModelsLoaded(const QStringList &models);
    // models: [{id, name}]
    void modelsLoaded(const QString &provider, const QVariantList &models);

private:
    QString keyAccount(const QString &provider) const;
    QUrl baseUrl(const QString &provider) const;
    AiProvider *createProvider(const QString &provider, QString *error);
    void run(int request, const QString &provider, const QVariantMap &spec, const QVariantMap &prepared);
    ResearchStore *m_store;
    QNetworkAccessManager *m_network;
    CodexBridge *m_codex;
    QHash<int, QPointer<AiProvider>> m_running;
    int m_nextRequest = 0;
    QVariantMap m_codexAccount;
};
