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
    QString text, error;
    QStringList deltas;
};
Outcome run(AiProvider *provider, const AiRequest &request)
{
    Outcome outcome;
    QObject::connect(provider, &AiProvider::delta, [&](const QString &text) { outcome.deltas << text; });
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
        prompt = buildAiPrompt("summarize", "ja", {}, materials);
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
        server.chunks = {MockServer::sse("response.failed",
            {{"type", "response.failed"}, {"response", QJsonObject{{"error", QJsonObject{{"message", "quota"}}}}}})};
        QVERIFY(run(new OpenAiProvider(&network, server.base(), "k", this), request).error.contains("quota"));
        server.contentType = "application/x-ndjson";
        server.chunks = {R"({"message":{"role":"assistant","content":"Lo"},"done":false})"
                         "\n",
            R"({"message":{"role":"assistant","content":"cal"},"done":false})"
            "\n",
            R"({"model":"llama3.2","done":true})"
            "\n"};
        outcome = run(new OllamaProvider(&network, server.base(), this), request);
        QCOMPARE(outcome.text, QString("Local"));
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
        const QVariantMap spec{{"provider", "claude"}, {"action", "summarize"}, {"source", QUrl::fromLocalFile(pdf)},
            {"page", 2}, {"scope", "page"}};
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
        QVERIFY(server.seen[0].body["system"].toString().contains("Korean"));
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
        QCOMPARE(thread[0].toMap()["display"].toString(), QString("Summarize"));
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
        QVERIFY(store.deleteAiThread(threadId));
        QVERIFY(store.aiThread(threadId).isEmpty());
        QVERIFY(ai->clearApiKey("claude"));
        QVERIFY(!ai->hasApiKey("claude"));
    }
};

QTEST_MAIN(AiTest)
#include "AiTest.moc"
