#include "AiContext.h"
#include "AiProviders.h"
#include "AiService.h"
#include "PaperIndex.h"
#include "Keychain.h"
#include "PdfFixture.h"
#include "ResearchStore.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUuid>
#include <QtTest>

namespace {
// A local HTTP server that records each request and answers with a canned (streamed) body.
class MockServer : public QObject {
public:
    struct Seen {
        QString requestLine;
        QHash<QString, QString> headers;
        QJsonObject body;
    };
    QList<Seen> seen;
    int status = 200;
    QByteArray contentType = "text/event-stream";
    QList<QByteArray> chunks;
    // Send the chunks and leave the stream open (an answer still coming).
    bool keepOpen = false;
    explicit MockServer(QObject *parent = nullptr) : QObject(parent)
    {
        server.listen(QHostAddress::LocalHost);
        connect(&server, &QTcpServer::newConnection, this, [this] {
            auto *socket = server.nextPendingConnection();
            auto buffer = std::make_shared<QByteArray>();
            connect(socket, &QTcpSocket::readyRead, socket, [this, socket, buffer] {
                *buffer += socket->readAll();
                const auto end = buffer->indexOf("\r\n\r\n");
                if (end < 0) return;
                const auto head = QString::fromUtf8(buffer->left(end));
                int length = 0;
                Seen request;
                const auto lines = head.split("\r\n");
                request.requestLine = lines.value(0);
                for (const auto &line : lines.mid(1)) {
                    const auto colon = line.indexOf(':');
                    request.headers.insert(line.left(colon).trimmed().toLower(), line.mid(colon + 1).trimmed());
                }
                length = request.headers.value("content-length").toInt();
                if (buffer->size() < end + 4 + length) return;
                request.body = QJsonDocument::fromJson(buffer->mid(end + 4, length)).object();
                seen.append(request);
                QByteArray body;
                for (const auto &chunk : chunks) body += chunk;
                if (keepOpen) {
                    socket->write("HTTP/1.1 200 X\r\nContent-Type: " + contentType + "\r\n\r\n" + body);
                    return;
                }
                socket->write("HTTP/1.1 " + QByteArray::number(status) + " X\r\nContent-Type: " + contentType
                    + "\r\nConnection: close\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n\r\n"
                    + body);
                socket->disconnectFromHost();
            });
        });
    }
    QUrl base() const { return QUrl(QStringLiteral("http://127.0.0.1:%1/").arg(server.serverPort())); }
    static QByteArray sse(const QByteArray &event, const QJsonObject &data)
    {
        return "event: " + event + "\ndata: " + QJsonDocument(data).toJson(QJsonDocument::Compact) + "\n\n";
    }

private:
    QTcpServer server;
};

struct Outcome {
    QString text, error, thinking;
    QStringList deltas;
};
Outcome run(AiProvider *provider, const AiRequest &request)
{
    Outcome outcome;
    QObject::connect(provider, &AiProvider::delta, [&](const QString &text) { outcome.deltas << text; });
    QObject::connect(provider, &AiProvider::thinkingDelta, [&](const QString &text) { outcome.thinking += text; });
    QSignalSpy finished(provider, &AiProvider::finished), failed(provider, &AiProvider::failed);
    provider->start(request);
    if (!QTest::qWaitFor([&] { return finished.size() + failed.size() > 0; }, 10000)) outcome.error = "timeout";
    if (!finished.isEmpty()) outcome.text = finished[0][0].toString();
    if (!failed.isEmpty()) outcome.error = failed[0][0].toString();
    return outcome;
}
}

class AiTest : public QObject {
    Q_OBJECT
private slots:
    void initTestCase()
    {
        // Keychain items written by tests never mix with the app's.
        qputenv("OWELK_KEYCHAIN_SERVICE",
            ("org.owelk.tests." + QUuid::createUuid().toString(QUuid::WithoutBraces)).toUtf8());
    }
    void promptCarriesTaskLanguageAndBudget()
    {
        AiMaterials materials;
        materials.title = "Occlusion Paper";
        materials.selection = "The FAV gate filters views.";
        materials.pageText = QString(5000, 'x');
        materials.pageNumber = 3;
        auto prompt = buildAiPrompt("translate", "ko", {}, materials, 1000);
        QVERIFY(prompt.system.contains("Korean"));
        QVERIFY(prompt.text.contains("<selection>\nThe FAV gate filters views.\n</selection>"));
        QVERIFY(prompt.text.contains("Translate the selected passage into Korean"));
        QVERIFY(prompt.text.contains("[…truncated]"));
        QVERIFY(prompt.truncated);
        QVERIFY(prompt.text.size() < 2000);
        prompt = buildAiPrompt("ask", "source", "왜 이 방법이 필요한가?", materials);
        QVERIFY(prompt.system.contains("language of the reader"));
        QVERIFY(prompt.text.endsWith("왜 이 방법이 필요한가?"));
        QVERIFY(!prompt.truncated);
        // A typed question keeps its own language even with a preferred one; actions use the preference.
        prompt = buildAiPrompt("ask", "ja", "What does this show?", materials);
        QVERIFY(prompt.system.contains("language of the reader's request"));
        QVERIFY(!prompt.system.contains("Japanese"));
        prompt = buildAiPrompt("translate", "ja", {}, materials);
        QVERIFY(prompt.system.contains("Answer in Japanese"));
        // "Same as the paper" still needs a translation target.
        prompt = buildAiPrompt("translate", "source", {}, materials);
        QVERIFY(prompt.text.contains("into English"));
    }
    void keychainRoundTrip()
    {
        QTemporaryDir directory;
        QVERIFY(Keychain::write("claude-api-key", "sk-test-123456", directory.path()));
        QCOMPARE(Keychain::read("claude-api-key", directory.path()), QString("sk-test-123456"));
        QVERIFY(Keychain::write("claude-api-key", "sk-test-replaced", directory.path()));
        QCOMPARE(Keychain::read("claude-api-key", directory.path()), QString("sk-test-replaced"));
        QVERIFY(Keychain::remove("claude-api-key", directory.path()));
        QVERIFY(Keychain::read("claude-api-key", directory.path()).isEmpty());
    }
    void claudeStreamsTextAndHandlesRefusalAndErrors()
    {
        MockServer server;
        server.chunks = {MockServer::sse("message_start",
                             {{"type", "message_start"}, {"message", QJsonObject{{"model", "claude-opus-5-5"}}}}),
            MockServer::sse("content_block_start", {{"type", "content_block_start"}, {"index", 0}}),
            MockServer::sse("ping", {{"type", "ping"}}),
            MockServer::sse("content_block_delta",
                {{"type", "content_block_delta"},
                    {"delta", QJsonObject{{"type", "thinking_delta"}, {"thinking", ""}}}}),
            MockServer::sse("content_block_delta",
                {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", "Hello "}}}}),
            MockServer::sse("content_block_delta",
                {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", "reader"}}}}),
            MockServer::sse(
                "message_delta", {{"type", "message_delta"}, {"delta", QJsonObject{{"stop_reason", "end_turn"}}}}),
            MockServer::sse("message_stop", {{"type", "message_stop"}})};
        QNetworkAccessManager network;
        AiRequest request;
        request.system = "system text";
        request.text = "question";
        request.model = "claude-opus-5-5";
        request.images = {{QByteArray("png-bytes"), "image/png", {}}};
        auto outcome = run(new AnthropicProvider(&network, server.base(), "sk-ant-test", this), request);
        QCOMPARE(outcome.error, QString());
        QCOMPARE(outcome.text, QString("Hello reader"));
        QCOMPARE(outcome.deltas, QStringList({"Hello ", "reader"}));
        const auto &seen = server.seen[0];
        QVERIFY(seen.requestLine.startsWith("POST /v1/messages"));
        QCOMPARE(seen.headers.value("x-api-key"), QString("sk-ant-test"));
        QCOMPARE(seen.headers.value("anthropic-version"), QString("2023-06-01"));
        QCOMPARE(seen.headers.value("anthropic-beta"), QString("server-side-fallback-2026-07-01"));
        QCOMPARE(seen.body["model"].toString(), QString("claude-opus-5-5"));
        QCOMPARE(seen.body["fallbacks"].toString(), QString("default"));
        QVERIFY(seen.body["stream"].toBool());
        QCOMPARE(seen.body["system"].toString(), QString("system text"));
        QCOMPARE(seen.body["output_config"].toObject()["effort"].toString(), QString("medium"));
        QCOMPARE(seen.body["cache_control"].toObject()["type"].toString(), QString("ephemeral"));
        QVERIFY(!seen.body.contains("thinking")); // Opus 5.5 thinks adaptively; it cannot be configured off.
        const auto content = seen.body["messages"].toArray()[0].toObject()["content"].toArray();
        QCOMPARE(content[0].toObject()["type"].toString(), QString("image"));
        QCOMPARE(
            content[0].toObject()["source"].toObject()["data"].toString(), QString(QByteArray("png-bytes").toBase64()));
        QCOMPARE(content[1].toObject()["text"].toString(), QString("question"));
        // The reader's effort and fast mode reach the request; fast mode is Opus-only.
        request.effort = "xhigh";
        request.fast = true;
        run(new AnthropicProvider(&network, server.base(), "k", this), request);
        QCOMPARE(server.seen.last().body["output_config"].toObject()["effort"].toString(), QString("xhigh"));
        QCOMPARE(server.seen.last().body["speed"].toString(), QString("fast"));
        QCOMPARE(server.seen.last().headers.value("anthropic-beta"),
            QString("server-side-fallback-2026-07-01,fast-mode-2026-02-01"));
        request.model = "claude-sonnet-5-5";
        run(new AnthropicProvider(&network, server.base(), "k", this), request);
        QVERIFY(!server.seen.last().body.contains("speed"));
        QCOMPARE(server.seen.last().headers.value("anthropic-beta"), QString("server-side-fallback-2026-07-01"));
        request.model = "claude-haiku-4-5";
        run(new AnthropicProvider(&network, server.base(), "k", this), request);
        QVERIFY(!server.seen.last().body.contains("output_config")); // Haiku 4.5 has no effort levels.
        QVERIFY(!server.seen.last().headers.contains("anthropic-beta"));
        request.model = "claude-opus-5-5";
        request.effort.clear();
        request.fast = false;
        // Asked for, the reasoning summary streams apart from the answer, a paragraph per thinking block.
        server.chunks = {MockServer::sse("content_block_start",
                             {{"type", "content_block_start"}, {"content_block", QJsonObject{{"type", "thinking"}}}}),
            MockServer::sse("content_block_delta",
                {{"type", "content_block_delta"},
                    {"delta", QJsonObject{{"type", "thinking_delta"}, {"thinking", "Checking the setup."}}}}),
            MockServer::sse("content_block_delta",
                {{"type", "content_block_delta"},
                    {"delta", QJsonObject{{"type", "signature_delta"}, {"signature", "x"}}}}),
            MockServer::sse("content_block_start",
                {{"type", "content_block_start"}, {"content_block", QJsonObject{{"type", "thinking"}}}}),
            MockServer::sse("content_block_delta",
                {{"type", "content_block_delta"},
                    {"delta", QJsonObject{{"type", "thinking_delta"}, {"thinking", "Then the data."}}}}),
            MockServer::sse("content_block_delta",
                {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", "Answer."}}}}),
            MockServer::sse("message_stop", {{"type", "message_stop"}})};
        request.thinkingSummary = true;
        outcome = run(new AnthropicProvider(&network, server.base(), "k", this), request);
        QCOMPARE(outcome.text, QString("Answer."));
        QCOMPARE(outcome.thinking, QString("Checking the setup.\n\nThen the data."));
        QCOMPARE(server.seen.last().body["thinking"].toObject(),
            QJsonObject({{"type", "adaptive"}, {"display", "summarized"}}));
        request.model = "claude-haiku-4-5"; // No adaptive thinking there: nothing is asked.
        run(new AnthropicProvider(&network, server.base(), "k", this), request);
        QVERIFY(!server.seen.last().body.contains("thinking"));
        request.model = "claude-opus-5-5";
        request.thinkingSummary = false;
        // An answer that hit the output limit is kept and marked as cut off.
        server.chunks
            = {MockServer::sse("content_block_delta",
                   {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", "Long"}}}}),
                MockServer::sse("message_delta",
                    {{"type", "message_delta"}, {"delta", QJsonObject{{"stop_reason", "max_tokens"}}}}),
                MockServer::sse("message_stop", {{"type", "message_stop"}})};
        auto *limited = new AnthropicProvider(&network, server.base(), "k", this);
        QCOMPARE(run(limited, request).text, QString("Long"));
        QVERIFY(limited->cutOff());
        QCOMPARE(server.seen.last().body["max_tokens"].toInt(), 64000);
        // A refusal discards partial text.
        server.chunks = {
            MockServer::sse("content_block_delta",
                {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", "partial"}}}}),
            MockServer::sse(
                "message_delta", {{"type", "message_delta"}, {"delta", QJsonObject{{"stop_reason", "refusal"}}}}),
            MockServer::sse("message_stop", {{"type", "message_stop"}})};
        outcome = run(new AnthropicProvider(&network, server.base(), "k", this), request);
        QVERIFY(outcome.error.contains("declined"));
        QVERIFY(outcome.text.isEmpty());
        // A mid-stream error event and an HTTP error both surface as messages.
        server.chunks = {MockServer::sse("error",
            {{"type", "error"}, {"error", QJsonObject{{"type", "overloaded_error"}, {"message", "Overloaded"}}}})};
        QVERIFY(run(new AnthropicProvider(&network, server.base(), "k", this), request).error.contains("Overloaded"));
        server.status = 401;
        server.contentType = "application/json";
        server.chunks = {R"({"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}})"};
        QVERIFY(run(new AnthropicProvider(&network, server.base(), "k", this), request).error.contains("API key"));
    }
    void openAiAndOllamaStream()
    {
        MockServer server;
        server.chunks = {MockServer::sse("response.created", {{"type", "response.created"}}),
            MockServer::sse("response.output_text.delta", {{"type", "response.output_text.delta"}, {"delta", "Open"}}),
            MockServer::sse("response.output_text.delta", {{"type", "response.output_text.delta"}, {"delta", "AI"}}),
            MockServer::sse(
                "response.completed", {{"type", "response.completed"}, {"response", QJsonObject{{"model", "gpt-5"}}}})};
        QNetworkAccessManager network;
        AiRequest request;
        request.system = "sys";
        request.text = "q";
        request.model = "gpt-5";
        request.images = {{QByteArray("img"), "image/png", {}}};
        auto outcome = run(new OpenAiProvider(&network, server.base(), "sk-openai", this), request);
        QCOMPARE(outcome.text, QString("OpenAI"));
        QVERIFY(server.seen[0].requestLine.startsWith("POST /v1/responses"));
        QCOMPARE(server.seen[0].headers.value("authorization"), QString("Bearer sk-openai"));
        QCOMPARE(server.seen[0].body["instructions"].toString(), QString("sys"));
        const auto content = server.seen[0].body["input"].toArray()[0].toObject()["content"].toArray();
        QCOMPARE(content[1].toObject()["image_url"].toString(),
            QString("data:image/png;base64,") + QByteArray("img").toBase64());
        QVERIFY(!server.seen[0].body.contains("reasoning"));
        // Reasoning models give a summary when asked; each part is a paragraph.
        server.chunks = {MockServer::sse("response.reasoning_summary_part.added",
                             {{"type", "response.reasoning_summary_part.added"}}),
            MockServer::sse("response.reasoning_summary_text.delta",
                {{"type", "response.reasoning_summary_text.delta"}, {"delta", "**Reading the table**"}}),
            MockServer::sse(
                "response.reasoning_summary_part.added", {{"type", "response.reasoning_summary_part.added"}}),
            MockServer::sse("response.reasoning_summary_text.delta",
                {{"type", "response.reasoning_summary_text.delta"}, {"delta", "Comparing rows."}}),
            MockServer::sse("response.output_text.delta", {{"type", "response.output_text.delta"}, {"delta", "Done"}}),
            MockServer::sse(
                "response.completed", {{"type", "response.completed"}, {"response", QJsonObject{{"model", "gpt-5"}}}})};
        request.thinkingSummary = true;
        outcome = run(new OpenAiProvider(&network, server.base(), "k", this), request);
        QCOMPARE(outcome.text, QString("Done"));
        QCOMPARE(outcome.thinking, QString("**Reading the table**\n\nComparing rows."));
        QCOMPARE(server.seen.last().body["reasoning"].toObject()["summary"].toString(), QString("auto"));
        request.thinkingSummary = false;
        server.chunks = {MockServer::sse("response.failed",
            {{"type", "response.failed"}, {"response", QJsonObject{{"error", QJsonObject{{"message", "quota"}}}}}})};
        QVERIFY(run(new OpenAiProvider(&network, server.base(), "k", this), request).error.contains("quota"));
        server.contentType = "application/x-ndjson";
        server.chunks = {R"({"message":{"role":"assistant","content":"","thinking":"Hmm, local."},"done":false})"
                         "\n",
            R"({"message":{"role":"assistant","content":"Lo"},"done":false})"
            "\n",
            R"({"message":{"role":"assistant","content":"cal"},"done":false})"
            "\n",
            R"({"model":"llama3.2","done":true})"
            "\n"};
        outcome = run(new OllamaProvider(&network, server.base(), this), request);
        QCOMPARE(outcome.text, QString("Local"));
        QCOMPARE(outcome.thinking, QString("Hmm, local."));
        QVERIFY(server.seen.last().requestLine.startsWith("POST /api/chat"));
        QCOMPARE(server.seen.last().body["messages"].toArray()[1].toObject()["images"].toArray()[0].toString(),
            QString(QByteArray("img").toBase64()));
    }
    void codexAppServerSignInAndTurns()
    {
        qputenv("OWELK_CODEX", QByteArray(QUICK_TEST_SOURCE_DIR) + "/fake_codex.py");
        CodexBridge bridge;
        QJsonValue account;
        bool answered = false;
        bridge.call("account/read", {}, [&](const QJsonValue &result, const QString &) {
            account = result;
            answered = true;
        });
        QTRY_VERIFY_WITH_TIMEOUT(answered, 10000);
        QVERIFY(account.toObject()["account"].isNull());
        AiRequest request;
        request.system = "sys";
        request.text = "<selection>\nquote\n</selection>";
        auto outcome = run(new CodexProvider(&bridge, this), request);
        QCOMPARE(outcome.error, QString());
        QCOMPARE(outcome.text, QString("Codex answer"));
        // Codex lists the account's models, without hidden ones.
        QJsonValue models;
        answered = false;
        bridge.call("model/list", {}, [&](const QJsonValue &result, const QString &) {
            models = result;
            answered = true;
        });
        QTRY_VERIFY_WITH_TIMEOUT(answered, 5000);
        QCOMPARE(models.toObject()["data"].toArray().size(), 2);
        // Effort and the fast tier go with the turn.
        request.effort = "high";
        request.fast = true;
        QCOMPARE(run(new CodexProvider(&bridge, this), request).text, QString("Codex answer [high, priority]"));
        request.effort.clear();
        request.fast = false;
        // Earlier turns travel inside the text for the stateless Codex threads.
        request.history = {{"user", "first question"}, {"assistant", "first answer"}};
        outcome = run(new CodexProvider(&bridge, this), request);
        QCOMPARE(outcome.text, QString("Codex answer"));
        request.history.clear();
        request.text = "no material";
        QVERIFY(!run(new CodexProvider(&bridge, this), request).error.isEmpty());
    }
    void organizeTabsSuggestsGroupsWithoutApplying()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        // The model answers with tab names t1…tN; unknown names and repeats are ignored.
        const auto answer = QStringLiteral(
            "Here you go: {\"groups\": [{\"name\": \"Radar odometry\", \"tabs\": [\"t1\", \"t3\", \"t9\"]}, "
            "{\"name\": \"Scenes\", \"tabs\": [\"t2\", \"t1\"]}, {\"name\": \"Empty\", \"tabs\": []}]}");
        server.chunks
            = {MockServer::sse("content_block_delta",
                   {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", answer}}}}),
                MockServer::sse("message_stop", {{"type", "message_stop"}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->setProvider("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-test-key"));
        QSignalSpy organized(ai, &AiService::tabsOrganized);
        const QVariantList tabs{
            QVariantMap{{"id", "tab-a"}, {"title", "Radar odometry under gravity"}, {"opening", "We fuse doppler…"}},
            QVariantMap{{"id", "tab-b"}, {"title", "Indoor scenes"}, {"url", "https://example.org/scenes"}},
            QVariantMap{
                {"id", "tab-c"}, {"title", "Doppler radar inertial odometry"}, {"authors", "Kim"}, {"year", "2025"}}};
        ai->organizeTabs(tabs);
        QTRY_COMPARE_WITH_TIMEOUT(organized.size(), 1, 10000);
        QCOMPARE(organized[0][2].toString(), QString());
        const auto groups = organized[0][1].toList();
        QCOMPARE(groups.size(), 2);
        QCOMPARE(groups[0].toMap()["name"].toString(), QString("Radar odometry"));
        QCOMPARE(groups[0].toMap()["tabIds"].toStringList(), QStringList({"tab-a", "tab-c"}));
        QCOMPARE(groups[1].toMap()["tabIds"].toStringList(), QStringList({"tab-b"}));
        // What was sent: titles, openings and short tab names, no tab IDs.
        const auto sent = server.seen.last()
                              .body["messages"]
                              .toArray()
                              .last()
                              .toObject()["content"]
                              .toArray()
                              .last()
                              .toObject()["text"]
                              .toString();
        QVERIFY(sent.contains("t1: Radar odometry under gravity"));
        QVERIFY(sent.contains("begins: We fuse doppler"));
        QVERIFY(!sent.contains("tab-a"));
        // One tab: nothing to organize, nothing sent.
        const auto requests = server.seen.size();
        ai->organizeTabs({tabs[0]});
        QTRY_COMPARE_WITH_TIMEOUT(organized.size(), 2, 5000);
        QVERIFY(!organized[1][2].toString().isEmpty());
        QCOMPARE(server.seen.size(), requests);
        QVERIFY(ai->clearApiKey("claude"));
    }
    void comparePapersSendsExcerptsAndAspects()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        const auto answer = QStringLiteral("| Paper | Method |\n|---|---|\n| A 2020 | radar |");
        server.chunks
            = {MockServer::sse("content_block_delta",
                   {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", answer}}}}),
                MockServer::sse("message_stop", {{"type", "message_stop"}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        store.setSetting("aiLanguage", "en");
        ai->setProvider("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-test-key"));
        QSignalSpy compared(ai, &AiService::papersCompared);
        QSignalSpy streamed(ai, &AiService::comparisonDelta);
        const QVariantList papers{QVariantMap{{"title", "Radar odometry"}, {"year", "2020"},
                                      {"opening", "We fuse doppler"}, {"closing", "Radar wins"}},
            QVariantMap{{"title", "Lidar odometry"}, {"opening", "We match scans"}}};
        ai->comparePapers(papers, {"Method", " Data ", ""});
        QTRY_COMPARE_WITH_TIMEOUT(compared.size(), 1, 10000);
        QCOMPARE(compared[0][2].toString(), QString());
        QCOMPARE(compared[0][1].toString(), answer);
        QVERIFY(!streamed.isEmpty());
        const auto body = server.seen.last().body;
        const auto sent
            = body["messages"].toArray().last().toObject()["content"].toArray().last().toObject()["text"].toString();
        QVERIFY(sent.startsWith("Aspects: Method, Data\n"));
        QVERIFY(sent.contains("<paper n=\"1\">\nTitle: Radar odometry"));
        QVERIFY(sent.contains("Conclusion:\nRadar wins"));
        QVERIFY(sent.contains("Beginning:\nWe match scans"));
        QVERIFY(body["system"].toString().contains("Write in English"));
        // One paper: nothing to compare, nothing sent.
        const auto requests = server.seen.size();
        ai->comparePapers({papers[0]}, {});
        QTRY_COMPARE_WITH_TIMEOUT(compared.size(), 2, 5000);
        QVERIFY(!compared[1][2].toString().isEmpty());
        QCOMPARE(server.seen.size(), requests);
        QVERIFY(ai->clearApiKey("claude"));
    }
    void askingTheLibraryCitesPagesFromPassages()
    {
        QTemporaryDir directory;
        const auto pdf = directory.filePath("occlusion.pdf");
        writeFixture(pdf, "Occlusion Paper");
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QVERIFY(store.rememberDocument(QUrl::fromLocalFile(pdf)));
        auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
        index->enqueue(QUrl::fromLocalFile(pdf));
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 10000);
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        // Both requests get this answer: as search terms it finds the fixture's pages; as the answer, [1] cites one.
        const auto answer = QStringLiteral("occlusion, context [1]");
        server.chunks
            = {MockServer::sse("content_block_delta",
                   {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", answer}}}}),
                MockServer::sse("message_stop", {{"type", "message_stop"}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->setProvider("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-test-key"));
        ai->giveConsent("claude");
        QSignalSpy finished(ai, &AiService::finished), failed(ai, &AiService::failed);
        ai->ask(
            {{"provider", "claude"}, {"action", "ask"}, {"scope", "library"}, {"question", "가려짐은 어떻게 다루나?"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size() + failed.size(), 1, 10000);
        QVERIFY2(failed.isEmpty(), failed.isEmpty() ? "" : qPrintable(failed[0][1].toString()));
        // Two requests: search terms, then the answer from passages marked [n].
        QCOMPARE(server.seen.size(), 2);
        const auto sent = server.seen.last()
                              .body["messages"]
                              .toArray()
                              .last()
                              .toObject()["content"]
                              .toArray()
                              .last()
                              .toObject()["text"]
                              .toString();
        QVERIFY(sent.contains("<library_passages>"));
        QVERIFY(sent.contains("[1] Occlusion Paper"));
        // The saved answer links [1] to the paper's page and lists the sources.
        const auto text = finished[0][1].toString();
        QVERIFY2(text.contains("[[1]](owelk://document/"), qPrintable(text));
        QVERIFY(text.contains("#page="));
        QVERIFY(text.contains("**Sources**"));
        QVERIFY(ai->clearApiKey("claude"));
    }
    void organizePapersSuggestsCollectionsWithoutApplying()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        // An existing collection is reused by name; papers are named p1…pN.
        const auto answer = QStringLiteral("{\"groups\": [{\"name\": \"Radar\", \"papers\": [\"p2\", \"p1\"]}, "
                                           "{\"name\": \"Scenes\", \"papers\": [\"p3\", \"t1\"]}]}");
        server.chunks
            = {MockServer::sse("content_block_delta",
                   {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", answer}}}}),
                MockServer::sse("message_stop", {{"type", "message_stop"}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->setProvider("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-test-key"));
        QSignalSpy organized(ai, &AiService::papersOrganized);
        const QVariantList papers{QVariantMap{{"id", "file:///a.pdf"}, {"title", "Radar odometry"}},
            QVariantMap{{"id", "file:///b.pdf"}, {"title", "Doppler inertial odometry"}, {"year", "2025"}},
            QVariantMap{{"id", "file:///c.pdf"}, {"title", "Indoor scenes"}, {"opening", "We render rooms…"}}};
        ai->organizePapers(papers, {"Radar", "Reading list"});
        QTRY_COMPARE_WITH_TIMEOUT(organized.size(), 1, 10000);
        QCOMPARE(organized[0][2].toString(), QString());
        const auto groups = organized[0][1].toList();
        QCOMPARE(groups.size(), 2);
        QCOMPARE(groups[0].toMap()["paperIds"].toStringList(), QStringList({"file:///b.pdf", "file:///a.pdf"}));
        QCOMPARE(groups[1].toMap()["paperIds"].toStringList(), QStringList({"file:///c.pdf"}));
        const auto sent = server.seen.last()
                              .body["messages"]
                              .toArray()
                              .last()
                              .toObject()["content"]
                              .toArray()
                              .last()
                              .toObject()["text"]
                              .toString();
        QVERIFY(sent.contains("- Reading list"));
        QVERIFY(sent.contains("p3: Indoor scenes"));
        QVERIFY(!sent.contains("file:///"));
        QVERIFY(ai->clearApiKey("claude"));
    }
    void serviceKeepsThinkingApartFromTheAnswer()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        server.chunks = {MockServer::sse("content_block_start",
                             {{"type", "content_block_start"}, {"content_block", QJsonObject{{"type", "thinking"}}}}),
            MockServer::sse("content_block_delta",
                {{"type", "content_block_delta"},
                    {"delta", QJsonObject{{"type", "thinking_delta"}, {"thinking", "Weighing the evidence."}}}}),
            MockServer::sse("content_block_delta",
                {{"type", "content_block_delta"},
                    {"delta", QJsonObject{{"type", "text_delta"}, {"text", "The answer."}}}}),
            MockServer::sse("message_stop", {{"type", "message_stop"}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->giveConsent("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-thinking-test"));
        QSignalSpy finished(ai, &AiService::finished), thinking(ai, &AiService::thinking);
        ai->ask({{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"action", "ask"}, {"question", "Why?"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 1, 10000);
        QCOMPARE(thinking.size(), 1);
        QCOMPARE(server.seen[0].body["thinking"].toObject()["display"].toString(), QString("summarized"));
        // Stored beside the answer, not in it.
        const auto threadId = finished[0][2].toMap()["threadId"].toString();
        auto messages = store.aiThread(threadId)["messages"].toList();
        const auto answer = messages[1].toMap();
        QCOMPARE(answer["content"].toString(), QString("The answer."));
        QCOMPARE(answer["context"].toMap()["thinking"].toString(), QString("Weighing the evidence."));
        QVERIFY(answer["context"].toMap()["thinkingSeconds"].toInt() >= 1);
        // A follow-up resends the answer without its reasoning; turned off, no summary is asked for.
        store.setSetting("ai.showThinking", "0");
        ai->ask({{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"threadId", threadId}, {"action", "ask"},
            {"question", "And then?"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 2, 10000);
        const auto followUp = server.seen.last().body;
        QCOMPARE(followUp["messages"].toArray()[1].toObject()["content"].toString(), QString("The answer."));
        QVERIFY(!QJsonDocument(followUp).toJson().contains("Weighing"));
        QVERIFY(!followUp.contains("thinking"));
        ai->clearApiKey("claude");
    }
    void attachedFiguresAreNamedAndSymbolsAreKept()
    {
        QTemporaryDir directory;
        const auto pdf = directory.filePath("attach.pdf");
        writeFixture(pdf, "Attach Paper", 2);
        const auto source = QUrl::fromLocalFile(pdf);
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QVERIFY(store.rememberDocument(source));
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        const auto answer = [&](const QString &text) {
            server.chunks = {
                MockServer::sse("content_block_delta",
                    {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", text}}}}),
                MockServer::sse("message_stop", {{"type", "message_stop"}})};
        };
        answer("It shows $x$ [p. 1: \"Research finding 1.1\"].");
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->setProvider("claude");
        ai->giveConsent("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-attach-test"));
        store.setSetting("ai.instructions", "Put English terms in brackets.");
        QSignalSpy finished(ai, &AiService::finished), failed(ai, &AiService::failed);
        // A figure from the paper goes with its name; the paper leads the request with its own cache mark.
        const auto image = ai->saveRegionImage(source, 0, QRectF(0.05, 0.5, 0.9, 0.25));
        QVERIFY(!image.isEmpty());
        ai->ask({{"source", source}, {"scope", "paper"}, {"question", "What does the chart compare?"},
            {"imageFiles", QVariantList{image}}, {"imageLabels", QStringList{"Figure 1, page 1"}}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 1, 10000);
        const auto content = server.seen[0].body["messages"].toArray().last().toObject()["content"].toArray();
        QCOMPARE(content[0].toObject()["cache_control"].toObject()["type"].toString(), QString("ephemeral"));
        QVERIFY(content[0].toObject()["text"].toString().contains("<paper_text>"));
        QCOMPARE(content[1].toObject()["type"].toString(), QString("image"));
        QVERIFY(content[2].toObject()["text"].toString().contains("Attached from the paper: Figure 1, page 1."));
        const auto system = server.seen[0].body["system"].toString();
        QVERIFY(system.contains("new to this field"));
        QVERIFY(system.contains("Put English terms in brackets."));
        QVERIFY(finished[0][1].toString().contains("owelk://document/"));
        store.setSetting("ai.explainLevel", "brief");
        ai->ask({{"source", source}, {"scope", "paper"}, {"question", "Again"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 2, 10000);
        QVERIFY(server.seen[1].body["system"].toString().contains("Be brief"));
        store.setSetting("ai.explainLevel", "easy");
        const auto threads = store.aiThreads().size();

        // The paper's symbols: kept for the Symbols tab and hints, not as a conversation.
        answer(
            "```json\n{\"symbols\": [{\"symbol\": \"\\\\omega_m\", \"text\": [\"ωm\"], \"meaning\": \"angular "
            "velocity\", "
            "\"page\": 2, \"quote\": \"the angular velocity from the IMU\", \"background\": false}, {\"symbol\": "
            "\"\\\\mathbf{p}_r\", \"text\": \"𝐩𝑟\", \"meaning\": \"robot position\", \"page\": null, \"background\": "
            "true}]}\n```");
        QSignalSpy notation(ai, &AiService::notationChanged);
        QVERIFY(ai->notation(source).isEmpty());
        ai->findSymbols(source);
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 3, 10000);
        QCOMPARE(notation.size(), 1);
        QCOMPARE(finished[2][2].toMap()["symbols"].toInt(), 2);
        QCOMPARE(store.aiThreads().size(), threads);
        const auto symbols = ai->notation(source);
        QCOMPARE(symbols.size(), 2);
        QCOMPARE(symbols[0].toMap()["quote"].toString(), QString("the angular velocity from the IMU"));
        QCOMPARE(symbols[0].toMap()["page"].toInt(), 2);
        // Background knowledge has no page; printed math letters match as plain ones.
        QCOMPARE(symbols[1].toMap()["page"].toInt(), 0);
        QCOMPARE(symbols[1].toMap()["match"].toStringList(), QStringList{"pr"});
        // A list that does not come back is an error, and the kept one stays.
        answer("Sorry, no list.");
        ai->findSymbols(source);
        QTRY_COMPARE_WITH_TIMEOUT(failed.size(), 1, 10000);
        QCOMPARE(ai->notation(source).size(), 2);
        ai->clearApiKey("claude");
    }
    void stoppedAnswersKeepWhatArrived()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        server.keepOpen = true;
        server.chunks = {MockServer::sse("content_block_delta",
            {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", "Half an "}}}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->giveConsent("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-stop-test"));
        QSignalSpy finished(ai, &AiService::finished), failed(ai, &AiService::failed), delta(ai, &AiService::delta);
        const int request
            = ai->ask({{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"action", "ask"}, {"question", "Go on"}});
        QTRY_COMPARE_WITH_TIMEOUT(delta.size(), 1, 10000);
        ai->cancel(request);
        // The text so far is kept as the answer, marked as stopped.
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 1, 5000);
        QCOMPARE(failed.size(), 0);
        QVERIFY(finished[0][2].toMap()["stopped"].toBool());
        const auto messages = store.aiThread(finished[0][2].toMap()["threadId"].toString())["messages"].toList();
        QCOMPARE(messages.size(), 2);
        QCOMPARE(messages[1].toMap()["content"].toString(), QString("Half an "));
        QVERIFY(messages[1].toMap()["context"].toMap()["stopped"].toBool());
        // Stopped before any text: nothing is stored.
        server.chunks = {};
        const int empty
            = ai->ask({{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"action", "ask"}, {"question", "Wait"}});
        QTRY_VERIFY_WITH_TIMEOUT(server.seen.size() == 2, 5000);
        ai->cancel(empty);
        QTRY_COMPARE_WITH_TIMEOUT(failed.size(), 1, 5000);
        QCOMPARE(failed[0][1].toString(), QString("Stopped."));
        int stored = 0;
        for (const auto &thread : store.aiThreads()) stored += thread.toMap()["messages"].toInt();
        QCOMPARE(stored, 2);
        ai->clearApiKey("claude");
    }
    void serviceRequiresConsentKeyAndSavesAnswers()
    {
        QTemporaryDir directory;
        const auto pdf = directory.filePath("paper.pdf");
        writeFixture(pdf, "Service Paper");
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QVERIFY(store.rememberDocument(QUrl::fromLocalFile(pdf)));
        // The title is read from the PDF in the background.
        QTRY_COMPARE_WITH_TIMEOUT(store.displayName(QUrl::fromLocalFile(pdf)), QString("Service Paper"), 10000);
        auto *ai = qobject_cast<AiService *>(store.ai());
        QVERIFY(ai);
        MockServer server;
        server.chunks = {MockServer::sse("content_block_delta",
                             {{"type", "content_block_delta"},
                                 {"delta", QJsonObject{{"type", "text_delta"}, {"text", "Page answer"}}}}),
            MockServer::sse("message_stop", {{"type", "message_stop"}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        QSignalSpy finished(ai, &AiService::finished), failed(ai, &AiService::failed);
        const QVariantMap spec{{"provider", "claude"}, {"action", "ask"}, {"question", "Summarize this page"},
            {"source", QUrl::fromLocalFile(pdf)}, {"page", 2}, {"scope", "page"}};
        ai->ask(spec);
        QTRY_COMPARE_WITH_TIMEOUT(failed.size(), 1, 5000);
        QVERIFY(failed[0][1].toString().contains("Review what is sent")); // No consent yet: nothing leaves the Mac.
        QVERIFY(server.seen.isEmpty());
        ai->giveConsent("claude");
        ai->ask(spec);
        QTRY_COMPARE_WITH_TIMEOUT(failed.size(), 2, 5000);
        QVERIFY(failed[1][1].toString().contains("key")); // No key yet.
        QVERIFY(ai->setApiKey("claude", "sk-ant-service-test"));
        QVERIFY(ai->hasApiKey("claude"));
        QVERIFY(store.setting("ai.consent.claude") == "1");
        ai->ask(spec);
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 1, 10000);
        QCOMPARE(finished[0][1].toString(), QString("Page answer"));
        // The page's text and the paper's title went into the request.
        const auto text = server.seen[0]
                              .body["messages"]
                              .toArray()[0]
                              .toObject()["content"]
                              .toArray()
                              .last()
                              .toObject()["text"]
                              .toString();
        QVERIFY(text.contains("Title: Service Paper"));
        QVERIFY(text.contains("<page number=\"3\">"));
        QVERIFY(text.contains("Research finding 3.1"));
        // Page text comes with the request to cite places.
        QVERIFY(server.seen[0].body["system"].toString().contains("[p. N: \"exact words\"]"));
        QVERIFY(server.seen[0].body["system"].toString().contains("language of the reader's request"));
        // Saved answers are searchable knowledge objects linked to the paper.
        auto details = finished[0][2].toMap();
        details.insert("answer", finished[0][1].toString());
        const auto id = store.saveAiResponse(details);
        QVERIFY(!id.isEmpty());
        QCOMPARE(store.aiResponse(id)["answer"].toString(), QString("Page answer"));
        QCOMPARE(store.searchKnowledge("Page answer").value(0).toMap()["kind"].toString(), QString("ai"));
        QCOMPARE(
            store.backlinks("document", store.documentLinkId(QUrl::fromLocalFile(pdf)))[0].toMap()["kind"].toString(),
            QString("ai"));
        // The answer was stored as a thread; a follow-up sends the earlier turn along and extends the thread.
        const auto threadId = finished[0][2].toMap()["threadId"].toString();
        QVERIFY(!threadId.isEmpty());
        QCOMPARE(store.aiThread(threadId)["messages"].toList().size(), 2);
        ai->ask({{"provider", "claude"}, {"threadId", threadId}, {"action", "ask"}, {"question", "And the method?"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 2, 10000);
        const auto followUp = server.seen.last().body["messages"].toArray();
        QCOMPARE(followUp.size(), 3);
        QCOMPARE(followUp[0].toObject()["role"].toString(), QString("user"));
        QCOMPARE(followUp[1].toObject()["content"].toString(), QString("Page answer"));
        QVERIFY(followUp[2].toObject()["content"].toArray().last().toObject()["text"].toString().endsWith(
            "And the method?"));
        const auto thread = store.aiThread(threadId)["messages"].toList();
        QCOMPARE(thread.size(), 4);
        QCOMPARE(thread[2].toMap()["display"].toString(), QString("And the method?"));
        QCOMPARE(thread[0].toMap()["display"].toString(), QString("Summarize this page"));
        QCOMPARE(store.searchKnowledge("the method").value(0).toMap()["id"].toString(), threadId);
        // A fresh turn (one page translated) goes alone, with its own label, and still joins the thread.
        ai->ask({{"provider", "claude"}, {"threadId", threadId}, {"action", "translate"}, {"scope", "page"},
            {"source", QUrl::fromLocalFile(pdf)}, {"page", 0}, {"fresh", true}, {"label", "Translate page 1"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 3, 10000);
        QCOMPARE(server.seen.last().body["messages"].toArray().size(), 1);
        QCOMPARE(store.aiThread(threadId)["messages"].toList().size(), 6);
        QCOMPARE(store.aiThread(threadId)["messages"].toList()[4].toMap()["display"].toString(),
            QString("Translate page 1"));
        // The AI filter returns threads only; other targets leave them out.
        const auto aiOnly = store.searchKnowledge("Page", QUrl(), "ai");
        QVERIFY(!aiOnly.isEmpty());
        for (const auto &row : aiOnly) QCOMPARE(row.toMap()["kind"].toString(), QString("ai"));
        for (const auto &row : store.searchKnowledge("Page", QUrl(), "captures"))
            QVERIFY(row.toMap()["kind"].toString() != "ai");
        // An attached JPEG is sent as a PNG, scaled to the vision limit, and noted in the thread.
        const auto photo = directory.filePath("photo.jpg");
        QImage big(3000, 1500, QImage::Format_RGB32);
        big.fill(Qt::darkCyan);
        QVERIFY(big.save(photo, "JPG"));
        ai->ask({{"provider", "claude"}, {"threadId", threadId}, {"action", "ask"}, {"question", "What is this?"},
            {"imageFiles", QVariantList{QUrl::fromLocalFile(photo).toString()}}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 4, 10000);
        const auto withImage = server.seen.last().body["messages"].toArray().last().toObject()["content"].toArray();
        QCOMPARE(withImage[0].toObject()["type"].toString(), QString("image"));
        const auto png
            = QByteArray::fromBase64(withImage[0].toObject()["source"].toObject()["data"].toString().toLatin1());
        QCOMPARE(QImage::fromData(png, "PNG").size(), QSize(1568, 784));
        QVERIFY(store.aiThread(threadId)["messages"]
                .toList()[6]
                .toMap()["context"]
                .toMap()["attachments"]
                .toStringList()
                .contains("image"));
        QVERIFY(QFileInfo::exists(photo)); // The reader's file is left as it was.
        // A pasted screenshot is saved under the data folder.
        QImage shot(40, 30, QImage::Format_RGB32);
        shot.fill(Qt::red);
        QGuiApplication::clipboard()->setImage(shot);
        QVERIFY(ai->clipboardHasImage());
        const QUrl pasted(ai->saveClipboardImage());
        QVERIFY(pasted.toLocalFile().startsWith(store.dataDirectory() + "/ai-attachments/"));
        QCOMPARE(QImage(pasted.toLocalFile()).size(), QSize(40, 30));
        QGuiApplication::clipboard()->setText("text only");
        QVERIFY(ai->saveClipboardImage().isEmpty());
        QSignalSpy models(ai, &AiService::modelsLoaded);
        ai->listModels("claude");
        QCOMPARE(models[0][1].toList()[0].toMap()["id"].toString(), QString("claude-opus-5-5"));
        // Page citations in an answer about the paper become links to the page and the quoted words.
        server.chunks
            = {MockServer::sse("content_block_delta",
                   {{"type", "content_block_delta"},
                       {"delta",
                           QJsonObject{{"type", "text_delta"},
                               {"text", "Occlusion matters [p. 3: \u201cResearch finding 3.1\u201d]; see [p. 4]."}}}}),
                MockServer::sse("message_stop", {{"type", "message_stop"}})};
        ai->ask(spec);
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 5, 10000);
        const auto paper = store.documentLinkId(QUrl::fromLocalFile(pdf));
        QVERIFY(finished[4][1].toString().contains(
            "[p. 3](owelk://document/" + paper + "#page=3&q=Research%20finding%203.1)"));
        QVERIFY(finished[4][1].toString().contains("[p. 4](owelk://document/" + paper + "#page=4)"));
        QVERIFY(store.deleteAiThread(threadId));
        QVERIFY(store.aiThread(threadId).isEmpty());
        QVERIFY(ai->clearApiKey("claude"));
        QVERIFY(!ai->hasApiKey("claude"));
    }
};

QTEST_MAIN(AiTest)
#include "AiTest.moc"
