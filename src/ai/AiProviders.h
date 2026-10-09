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
    // Reasoning effort (provider's own level names, e.g. low…max) and the faster, pricier tier.
    QString effort;
    bool fast = false;
    // A ceiling, not a target (only what is written is billed); thinking counts toward it.
    int maxTokens = 64000;
    // Ask for a readable summary of the model's reasoning, streamed through thinkingDelta.
    bool thinkingSummary = false;
};

// One streamed answer. A provider object handles a single request and is deleted afterwards.
class AiProvider : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    virtual void start(const AiRequest &request) = 0;
    virtual void cancel() = 0;
    // The answer stopped at the output limit (read after finished).
    bool cutOff() const { return m_cutOff; }
    // The answer so far (kept when the reader stops it).
    virtual QString partialText() const = 0;
signals:
    void delta(const QString &text);
    // Summarized reasoning, shown apart from the answer and never sent back to the model.
    void thinkingDelta(const QString &text);
    void finished(const QString &text, const QString &model);
    void failed(const QString &error);

protected:
    bool m_cutOff = false;
};

// Server-sent events (Claude, OpenAI) or newline-delimited JSON (Ollama) over one HTTP POST.
class HttpStreamProvider : public AiProvider {
    Q_OBJECT
public:
    HttpStreamProvider(QNetworkAccessManager *network, QUrl endpoint, QObject *parent = nullptr);
    void cancel() override;
    QString partialText() const override { return m_text; }

protected:
    void post(const QHash<QByteArray, QByteArray> &headers, const QJsonObject &body, bool sse);
    // event is empty for NDJSON lines. Return false to stop reading (after emitting finished/failed).
    virtual bool handle(const QString &event, const QJsonObject &data) = 0;
    virtual QString errorFrom(int status, const QByteArray &body) const;
    void finish(const QString &model);
    void fail(const QString &error);
    // A piece of reasoning summary; a new part starts on its own paragraph.
    void think(const QString &text, bool newPart = false);
    QString m_text;
    bool m_thought = false;
    bool m_done = false;

private:
    void read();
    QNetworkAccessManager *m_network;
    QUrl m_endpoint;
    QPointer<QNetworkReply> m_reply;
    QByteArray m_buffer;
    bool m_sse = true;
};

// Which Claude models take output_config.effort, and which offer fast mode.
bool anthropicEfforts(const QString &model);
// Claude models that always think (adaptive): asking for a summary only makes it visible.
bool anthropicThinks(const QString &model);
// OpenAI reasoning models, which take reasoning.effort and reasoning.summary.
bool openAiReasons(const QString &model);
bool anthropicFast(const QString &model);

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
    QString partialText() const override { return m_text; }

private:
    CodexBridge *m_bridge;
    QString m_threadId, m_turnId, m_text, m_model, m_effort;
    bool m_fast = false, m_summary = false, m_thought = false;
    bool m_done = false;
};
