#pragma once

#include <QByteArray>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QUrl>
#include <functional>

class QNetworkAccessManager;
class QNetworkReply;

struct AiImage {
    QByteArray data; // PNG/JPEG bytes for HTTP providers.
    QString mediaType; // e.g. image/png
    QString path; // Local file for the Codex app server.
};

// An earlier turn of the same thread, sent as text.
struct AiTurn {
    QString role; // user | assistant
    QString text;
};

struct AiRequest {
    QString system;
    QList<AiTurn> history;
    QString text;
    QList<AiImage> images;
    QString model;
    int maxTokens = 16000;
};

// One streamed answer. A provider object handles a single request and is deleted afterwards.
class AiProvider : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    virtual void start(const AiRequest &request) = 0;
    virtual void cancel() = 0;
signals:
    void delta(const QString &text);
    void finished(const QString &text, const QString &model);
    void failed(const QString &error);
};

// Server-sent events (Claude, OpenAI) or newline-delimited JSON (Ollama) over one HTTP POST.
class HttpStreamProvider : public AiProvider {
    Q_OBJECT
public:
    HttpStreamProvider(QNetworkAccessManager *network, QUrl endpoint, QObject *parent = nullptr);
    void cancel() override;

protected:
    void post(const QHash<QByteArray, QByteArray> &headers, const QJsonObject &body, bool sse);
    // event is empty for NDJSON lines. Return false to stop reading (after emitting finished/failed).
    virtual bool handle(const QString &event, const QJsonObject &data) = 0;
    virtual QString errorFrom(int status, const QByteArray &body) const;
    void finish(const QString &model);
    void fail(const QString &error);
    QString m_text;
    bool m_done = false;

private:
    void read();
    QNetworkAccessManager *m_network;
    QUrl m_endpoint;
    QPointer<QNetworkReply> m_reply;
    QByteArray m_buffer;
    bool m_sse = true;
};

class AnthropicProvider final : public HttpStreamProvider {
    Q_OBJECT
public:
    AnthropicProvider(QNetworkAccessManager *network, const QUrl &base, const QString &key, QObject *parent = nullptr);
    void start(const AiRequest &request) override;

protected:
    bool handle(const QString &event, const QJsonObject &data) override;
    QString errorFrom(int status, const QByteArray &body) const override;

private:
    QString m_key, m_model, m_stopReason;
};

class OpenAiProvider final : public HttpStreamProvider {
    Q_OBJECT
public:
    OpenAiProvider(QNetworkAccessManager *network, const QUrl &base, const QString &key, QObject *parent = nullptr);
    void start(const AiRequest &request) override;

protected:
    bool handle(const QString &event, const QJsonObject &data) override;
    QString errorFrom(int status, const QByteArray &body) const override;

private:
    QString m_key, m_model;
};

class OllamaProvider final : public HttpStreamProvider {
    Q_OBJECT
public:
    OllamaProvider(QNetworkAccessManager *network, const QUrl &base, QObject *parent = nullptr);
    void start(const AiRequest &request) override;

protected:
    bool handle(const QString &event, const QJsonObject &data) override;

private:
    QString m_model;
};

// The OpenAI sign-in path: the Codex app server (JSON-RPC over stdio) runs requests on the user's
// ChatGPT account. One process is shared; it is started on first use.
class CodexBridge final : public QObject {
    Q_OBJECT
public:
    explicit CodexBridge(QObject *parent = nullptr);
    ~CodexBridge() override;
    static QString executable();
    using Callback = std::function<void(const QJsonValue &result, const QString &error)>;
    void call(const QString &method, const QJsonObject &params, Callback callback);
    bool running() const { return m_process.state() != QProcess::NotRunning; }
signals:
    void notification(const QString &method, const QJsonObject &params);
    void stopped(const QString &error);

private:
    void ensureStarted();
    void send(const QJsonObject &message);
    void readLines();
    QProcess m_process;
    QByteArray m_buffer;
    int m_nextId = 1;
    bool m_ready = false;
    QHash<int, Callback> m_callbacks;
    QList<QJsonObject> m_waiting;
};

class CodexProvider final : public AiProvider {
    Q_OBJECT
public:
    CodexProvider(CodexBridge *bridge, QObject *parent = nullptr);
    void start(const AiRequest &request) override;
    void cancel() override;

private:
    CodexBridge *m_bridge;
    QString m_threadId, m_turnId, m_text, m_model;
    bool m_done = false;
};
