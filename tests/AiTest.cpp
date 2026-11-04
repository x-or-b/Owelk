#include "AiContext.h"
#include "AiProviders.h"
#include "AiService.h"
#include "PaperIndex.h"
#include "Keychain.h"
#include "PdfFixture.h"
#include "ResearchStore.h"

#include <QClipboard>
#include <QCryptographicHash>
#include <QDesktopServices>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUrlQuery>
#include <QUuid>
#include <QtTest>

// Takes the addresses Owelk would open in the browser (QDesktopServices::setUrlHandler).
class BrowserCatcher : public QObject {
    Q_OBJECT
public:
    QList<QUrl> urls;
public slots:
    void open(const QUrl &url) { urls.append(url); }
};

namespace {
// A local HTTP server that records each request and answers with a canned (streamed) body.
class MockServer : public QObject {
public:
    struct Seen {
        QString requestLine;
        QHash<QString, QString> headers;
        QJsonObject body;
        // The body as sent (forms are not JSON).
        QByteArray raw;
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
                request.raw = buffer->mid(end + 4, length);
                request.body = QJsonDocument::fromJson(request.raw).object();
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
        QVERIFY(!prompt.system.contains("note_update"));
        // Attached notes go with their id and title, and questions may get a whole note back to apply.
        materials.notes = {"Old body"};
        materials.noteIds = {"n1"};
        materials.noteTitles = {"A \"quoted\" title"};
        prompt = buildAiPrompt("ask", "ko", "Rewrite it", materials);
        QVERIFY(prompt.text.contains("<note id=\"n1\" title=\"A &quot;quoted&quot; title\">\nOld body\n</note>"));
        QVERIFY(prompt.system.contains("<note_update id=\"ID\""));
        QVERIFY(prompt.system.contains("<note_new title="));
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
        QCOMPARE(server.seen.last().body["options"].toObject()["num_ctx"].toInt(), 16384);
        QCOMPARE(server.seen.last().body["messages"].toArray()[1].toObject()["images"].toArray()[0].toString(),
            QString(QByteArray("img").toBase64()));
    }
    void chatGptSignInRefreshesAndAnswersOnThePlan()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        QVERIFY(ai);
        MockServer auth, api;
        auth.contentType = api.contentType = "application/json";
        store.setSetting("ai.authUrl.chatgpt", auth.base().toString());
        store.setSetting("ai.baseUrl.chatgpt", api.base().toString());
        // The sign-in page is not opened: its address comes here.
        BrowserCatcher browser;
        QDesktopServices::setUrlHandler("http", &browser, "open");
        const auto restore = qScopeGuard([] { QDesktopServices::unsetUrlHandler("http"); });
        ai->chatGptSignIn();
        QTRY_COMPARE_WITH_TIMEOUT(browser.urls.size(), 1, 5000);
        const QUrlQuery authorize(browser.urls[0]);
        const auto value = [&](const char *key) { return authorize.queryItemValue(key, QUrl::FullyDecoded); };
        QCOMPARE(browser.urls[0].path(), QString("/api/accounts/authorize"));
        QCOMPARE(value("client_id"), QString("dynamic_agent_client"));
        QCOMPARE(value("agent_name_hint"), QString("Owelk"));
        QVERIFY(value("ext_agent_host_id").startsWith("urn:uuid:"));
        QCOMPARE(value("resource"), QString("https://api.openai.com/v1"));
        QVERIFY(value("scope").split(' ').contains("chatgpt.tokens.use.direct"));
        QCOMPARE(value("code_challenge_method"), QString("S256"));
        const QUrl redirect(value("redirect_uri"));
        QCOMPARE(redirect.host(), QString("127.0.0.1"));
        QCOMPARE(redirect.path(), QString("/auth/callback"));
        QVERIFY(ai->chatGptAccount().value("pending").toBool());
        // OpenAI exchanges the code for tokens; the ID token names the account and this attempt.
        const auto jwt = [](const QJsonObject &claims) {
            return "e30."
                + QJsonDocument(claims)
                      .toJson(QJsonDocument::Compact)
                      .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)
                + ".signature";
        };
        const QString scope = "chatgpt.tokens.use.direct email offline_access openid profile resource.invoke";
        auth.chunks = {
            QJsonDocument(QJsonObject{{"access_token", "at-1"}, {"refresh_token", "rt-1"}, {"expires_in", 30},
                              {"token_type", "Bearer"}, {"scope", scope},
                              {"id_token",
                                  QString::fromLatin1(jwt({{"iss", "https://auth.openai.com"}, {"aud", "oaiapp_test"},
                                      {"sub", "user-1"}, {"email", "reader@example.com"}, {"nonce", value("nonce")},
                                      {"exp", QDateTime::currentSecsSinceEpoch() + 3600}}))}})
                .toJson()};
        // The browser comes back to Owelk's listener.
        QNetworkAccessManager network;
        const auto back = [&](const QString &query) {
            auto url = redirect;
            url.setQuery(query);
            auto *reply = network.get(QNetworkRequest(url));
            const bool finished = QTest::qWaitFor([reply] { return reply->isFinished(); }, 5000);
            const auto page = finished ? QString::fromUtf8(reply->readAll()) : QString();
            reply->deleteLater();
            return page;
        };
        // Another attempt's answer is turned away, and this one keeps waiting.
        QVERIFY(back("code=forged&state=other&client_id=oaiapp_test").contains("no longer waiting"));
        QVERIFY(ai->chatGptAccount().value("pending").toBool());
        QVERIFY(auth.seen.isEmpty());
        QVERIFY(back("code=abc&state=" + value("state") + "&client_id=oaiapp_test").contains("Signed in"));
        QTRY_VERIFY_WITH_TIMEOUT(ai->chatGptAccount().value("signedIn").toBool(), 5000);
        QCOMPARE(ai->chatGptAccount().value("email").toString(), QString("reader@example.com"));
        QVERIFY(auth.seen[0].requestLine.startsWith("POST /api/accounts/oauth/token"));
        QUrlQuery form(QString::fromLatin1(auth.seen[0].raw));
        QCOMPARE(form.queryItemValue("grant_type"), QString("authorization_code"));
        QCOMPARE(form.queryItemValue("client_id"), QString("oaiapp_test"));
        QCOMPARE(form.queryItemValue("code"), QString("abc"));
        QCOMPARE(QUrl(form.queryItemValue("redirect_uri", QUrl::FullyDecoded)), redirect);
        QCOMPARE(form.queryItemValue("resource", QUrl::FullyDecoded), QString("https://api.openai.com/v1"));
        // The verifier sent with the code is the one the challenge was made from.
        QCOMPARE(QString::fromLatin1(QCryptographicHash::hash(
                     form.queryItemValue("code_verifier").toLatin1(), QCryptographicHash::Sha256)
                         .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)),
            value("code_challenge"));
        // Only the refresh token is kept, in the keyring.
        QCOMPARE(Keychain::read("chatgpt-refresh-token", store.dataDirectory()), QString("rt-1"));
        const auto providers = ai->providers();
        QVERIFY(std::any_of(providers.cbegin(), providers.cend(), [](const QVariant &p) {
            return p.toMap().value("id").toString() == "chatgpt" && p.toMap().value("configured").toBool();
        }));
        // The access token is about to expire: listing the models refreshes it first.
        auth.chunks = {QJsonDocument(
            QJsonObject{{"access_token", "at-2"}, {"refresh_token", "rt-2"}, {"expires_in", 3600}, {"scope", scope}})
                .toJson()};
        api.chunks = {QJsonDocument(QJsonObject{{"models",
                                        QJsonArray{QJsonObject{{"slug", "gpt-6.1-sol"}, {"display_name", "GPT-6.1 Sol"},
                                                       {"visibility", "list"}},
                                            QJsonObject{{"slug", "internal"}, {"visibility", "hide"}}}}})
                .toJson()};
        QSignalSpy models(ai, &AiService::modelsLoaded);
        ai->listModels("chatgpt");
        QTRY_COMPARE_WITH_TIMEOUT(models.size(), 1, 5000);
        const auto list = models[0][1].toList();
        QCOMPARE(list.size(), 1);
        QCOMPARE(list[0].toMap().value("name").toString(), QString("GPT-6.1 Sol"));
        QVERIFY(!list[0].toMap().value("fast").toBool());
        QCOMPARE(ai->model("chatgpt"), QString("gpt-6.1-sol"));
        form = QUrlQuery(QString::fromLatin1(auth.seen[1].raw));
        QCOMPARE(form.queryItemValue("grant_type"), QString("refresh_token"));
        QCOMPARE(form.queryItemValue("refresh_token"), QString("rt-1"));
        QCOMPARE(form.queryItemValue("client_id"), QString("oaiapp_test"));
        QCOMPARE(Keychain::read("chatgpt-refresh-token", store.dataDirectory()), QString("rt-2"));
        QCOMPARE(api.seen[0].headers.value("authorization"), QString("Bearer at-2"));
        // An answer on the plan: nothing stored at OpenAI, no output limit or faster tier.
        api.contentType = "text/event-stream";
        api.chunks
            = {MockServer::sse("response.output_text.delta", {{"type", "response.output_text.delta"}, {"delta", "ok"}}),
                MockServer::sse("response.completed",
                    {{"type", "response.completed"}, {"response", QJsonObject{{"model", "gpt-6.1-sol"}}}})};
        QSignalSpy tested(ai, &AiService::connectionTested);
        ai->testConnection("chatgpt");
        QTRY_COMPARE_WITH_TIMEOUT(tested.size(), 1, 5000);
        QVERIFY2(tested[0][1].toBool(), qPrintable(tested[0][2].toString()));
        const auto body = api.seen.last().body;
        QVERIFY(api.seen.last().requestLine.startsWith("POST /v1/responses"));
        QCOMPARE(api.seen.last().headers.value("authorization"), QString("Bearer at-2"));
        QCOMPARE(body["model"].toString(), QString("gpt-6.1-sol"));
        QCOMPARE(body["store"], QJsonValue(false));
        QCOMPARE(body["stream"], QJsonValue(true));
        QVERIFY(!body.contains("max_output_tokens") && !body.contains("service_tier"));
        QCOMPARE(auth.seen.size(), 2); // The new token is still good.
        // The plan's limit says where to look.
        api.status = 429;
        api.contentType = "application/json";
        api.chunks = {R"({"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}})"};
        ai->testConnection("chatgpt");
        QTRY_COMPARE_WITH_TIMEOUT(tested.size(), 2, 5000);
        QVERIFY(!tested[1][1].toBool());
        QVERIFY(tested[1][2].toString().contains("chatgpt.com/settings/usage"));
        // Signing out ends the session at OpenAI and keeps the registration for next time.
        auth.chunks
            = {QJsonDocument(QJsonObject{{"revocation_endpoint", auth.base().toString() + "oauth/revoke"}}).toJson()};
        ai->chatGptSignOut();
        QVERIFY(!ai->chatGptAccount().value("signedIn").toBool());
        QVERIFY(Keychain::read("chatgpt-refresh-token", store.dataDirectory()).isEmpty());
        QTRY_COMPARE_WITH_TIMEOUT(auth.seen.size(), 4, 5000);
        QVERIFY(auth.seen[2].requestLine.startsWith("GET /.well-known/openid-configuration"));
        QVERIFY(auth.seen[3].requestLine.startsWith("POST /oauth/revoke"));
        form = QUrlQuery(QString::fromLatin1(auth.seen[3].raw));
        QCOMPARE(form.queryItemValue("token"), QString("rt-2"));
        QCOMPARE(form.queryItemValue("token_type_hint"), QString("refresh_token"));
        QCOMPARE(form.queryItemValue("client_id"), QString("oaiapp_test"));
        // The next sign-in reuses the issued client and suggests the same account.
        ai->chatGptSignIn();
        QTRY_COMPARE_WITH_TIMEOUT(browser.urls.size(), 2, 5000);
        const QUrlQuery again(browser.urls[1]);
        QCOMPARE(again.queryItemValue("client_id"), QString("oaiapp_test"));
        QVERIFY(!again.hasQueryItem("agent_name_hint"));
        QCOMPARE(again.queryItemValue("login_hint", QUrl::FullyDecoded), QString("reader@example.com"));
        // A refused exchange stays in Settings with OpenAI's reason (the browser was in front when it came).
        auth.status = 400;
        auth.chunks = {R"({"error":"invalid_grant","error_description":"Workspace not allowed"})"};
        auto url = QUrl(again.queryItemValue("redirect_uri", QUrl::FullyDecoded));
        url.setQuery("code=refused&state=" + again.queryItemValue("state") + "&client_id=oaiapp_test");
        auto *reply = network.get(QNetworkRequest(url));
        QTRY_VERIFY_WITH_TIMEOUT(reply->isFinished(), 5000);
        reply->deleteLater();
        QTRY_VERIFY_WITH_TIMEOUT(
            ai->chatGptAccount().value("error").toString().contains("Workspace not allowed"), 5000);
        QVERIFY(ai->chatGptAccount().value("error").toString().contains("HTTP 400"));
        QVERIFY(!ai->chatGptAccount().value("signedIn").toBool());
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
        // A Codex that refuses to start answers what waits with an error instead of leaving it waiting forever.
        qputenv("FAKE_CODEX_REFUSE", "1");
        {
            CodexBridge refusing;
            QString refused;
            bool answered = false;
            refusing.call("account/read", {}, [&](const QJsonValue &, const QString &error) {
                refused = error;
                answered = true;
            });
            QTRY_VERIFY_WITH_TIMEOUT(answered, 10000);
            QVERIFY(!refused.isEmpty());
        }
        qunsetenv("FAKE_CODEX_REFUSE");
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
    void severalPapersAreReadOrSearched()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
        QList<QUrl> papers;
        for (const auto *name : {"Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta"}) {
            const auto pdf = directory.filePath(QString(name) + ".pdf");
            writeFixture(pdf, QString(name) + " Paper", 2);
            papers << QUrl::fromLocalFile(pdf);
            QVERIFY(store.rememberDocument(papers.last()));
            index->enqueue(papers.last());
        }
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 20000);
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        const auto answer = [&](const QString &text) {
            server.chunks = {
                MockServer::sse("content_block_delta",
                    {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", text}}}}),
                MockServer::sse("message_stop", {{"type", "message_stop"}})};
        };
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->setProvider("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-several"));
        ai->giveConsent("claude");
        QSignalSpy finished(ai, &AiService::finished), failed(ai, &AiService::failed);
        const auto lastText = [&] {
            return server.seen.last()
                .body["messages"]
                .toArray()
                .last()
                .toObject()["content"]
                .toArray()[0]
                .toObject()["text"]
                .toString();
        };
        // Two papers: both read, each opened by its marker; a citation names the paper and links to it.
        answer("Beta differs [P2 p. 1: \"Research finding 1.1\"] from Alpha [p. 2]. Both say so [P1 p. 1: "
               "\u201cResearch finding 1.1\u201d; P2 p. 2: \u201cResearch finding 2.1\u201d; p. 2].");
        ai->ask({{"source", papers[0]}, {"scope", "paper"}, {"papers", QVariantList{papers[1].toString()}},
            {"question", "How do they differ?"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size() + failed.size(), 1, 10000);
        QVERIFY2(failed.isEmpty(), failed.isEmpty() ? "" : qPrintable(failed[0][1].toString()));
        QVERIFY(lastText().contains("=== P1: Alpha Paper ==="));
        QVERIFY(lastText().contains("=== P2: Beta Paper ==="));
        QVERIFY(server.seen.last().body["system"].toString().contains("[P2 p. N:"));
        const auto linked = finished[0][1].toString();
        QVERIFY2(linked.contains("[P2 p. 1](owelk://document/" + store.documentLinkId(papers[1]) + "#page=1"),
            qPrintable(linked));
        QVERIFY(linked.contains("[p. 2](owelk://document/" + store.documentLinkId(papers[0]) + "#page=2"));
        // Citations sharing brackets each become a link; one without a marker is of the paper named before it.
        QVERIFY2(linked.contains("Both say so [P1 p. 1](owelk://document/" + store.documentLinkId(papers[0])
                     + "#page=1&q=Research%20finding%201.1); [P2 p. 2](owelk://document/"
                     + store.documentLinkId(papers[1]) + "#page=2&q=Research%20finding%202.1); [p. 2](owelk://document/"
                     + store.documentLinkId(papers[1]) + "#page=2)."),
            qPrintable(linked));
        const auto thread = finished[0][2].toMap()["threadId"].toString();
        // The other paper finds the chat among its links; the question keeps what went with it.
        const auto links = store.backlinks("document", store.documentLinkId(papers[1]));
        QVERIFY(std::any_of(
            links.cbegin(), links.cend(), [&](const QVariant &b) { return b.toMap()["id"].toString() == thread; }));
        const auto asked = store.aiThread(thread)["messages"].toList()[0].toMap()["context"].toMap();
        QCOMPARE(asked["papers"].toStringList(), QStringList{"Beta Paper"});
        // Five papers: too many to read; the passages come from those five only.
        answer("occlusion, context [1]");
        QVariantList five;
        for (int i = 1; i < 5; ++i) five << papers[i].toString();
        ai->ask({{"source", papers[0]}, {"scope", "paper"}, {"papers", five}, {"question", "Where is occlusion?"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size() + failed.size(), 2, 10000);
        QVERIFY2(failed.isEmpty(), failed.isEmpty() ? "" : qPrintable(failed[0][1].toString()));
        const auto sent = lastText()
            + server.seen.last()
                  .body["messages"]
                  .toArray()
                  .last()
                  .toObject()["content"]
                  .toArray()
                  .last()
                  .toObject()["text"]
                  .toString();
        QVERIFY(sent.contains("<library_passages>"));
        QVERIFY(!sent.contains("Zeta Paper"));
        QVERIFY(!sent.contains("=== P1"));
        // Each of the five comes first with its overview (beginning and conclusion), before the passages.
        const auto from = sent.indexOf("<paper_overviews>"), to = sent.indexOf("</paper_overviews>");
        QVERIFY(from >= 0 && to > from && to < sent.indexOf("<library_passages>"));
        const auto overviews = sent.mid(from, to - from);
        QCOMPARE(overviews.count("Beginning (page 1): "), 5);
        for (const auto *name : {"Alpha", "Beta", "Gamma", "Delta", "Epsilon"})
            QVERIFY2(overviews.contains(QStringLiteral("%1 Paper").arg(name)), qPrintable(overviews.left(600)));
        // A question about all of them has no topic words: no passage matches, yet every paper is there.
        answer("zzqx, wqzz");
        ai->ask({{"source", papers[0]}, {"scope", "paper"}, {"papers", five},
            {"question", "여기있는 논문들 전부 간단하게 요약해줘"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size() + failed.size(), 3, 10000);
        QVERIFY2(failed.isEmpty(), failed.isEmpty() ? "" : qPrintable(failed[0][1].toString()));
        const auto summarized = server.seen.last()
                                    .body["messages"]
                                    .toArray()
                                    .last()
                                    .toObject()["content"]
                                    .toArray()
                                    .last()
                                    .toObject()["text"]
                                    .toString();
        QVERIFY(summarized.contains("<paper_overviews>"));
        QVERIFY(!summarized.contains("<library_passages>"));
        for (const auto *name : {"Alpha", "Beta", "Gamma", "Delta", "Epsilon"})
            QVERIFY2(summarized.contains(QStringLiteral("%1 Paper").arg(name)), name);
        QVERIFY(summarized.contains("covers every paper in the overviews"));
        QVERIFY(ai->clearApiKey("claude"));
    }
    void readingEachPaperInFull()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QList<QUrl> papers;
        for (const auto *name : {"Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota"}) {
            const auto pdf = directory.filePath(QString(name) + ".pdf");
            writeFixture(pdf, QString(name) + " Paper", 2);
            papers << QUrl::fromLocalFile(pdf);
            QVERIFY(store.rememberDocument(papers.last()));
        }
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        // Every request gets this: as notes on a paper, then as the answer, which cites the second paper.
        server.chunks = {MockServer::sse("content_block_delta",
                             {{"type", "content_block_delta"},
                                 {"delta",
                                     QJsonObject{{"type", "text_delta"},
                                         {"text", "Beta is clearest [P2 p. 1: \"Research finding 1.1\"]."}}}}),
            MockServer::sse("message_stop", {{"type", "message_stop"}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->setProvider("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-read-each"));
        ai->giveConsent("claude");
        QSignalSpy finished(ai, &AiService::finished), failed(ai, &AiService::failed),
            progress(ai, &AiService::progress);
        const auto others = [&](int count) {
            QVariantList list;
            for (int i = 1; i <= count; ++i) list << papers[i].toString();
            return list;
        };
        // Four papers: a request per paper with its whole text and the question, then the answer from the notes.
        ai->ask({{"source", papers[0]}, {"scope", "paper"}, {"papers", others(3)}, {"readEach", true},
            {"question", "Which is easiest to present?"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size() + failed.size(), 1, 15000);
        QVERIFY2(failed.isEmpty(), failed.isEmpty() ? "" : qPrintable(failed[0][1].toString()));
        QCOMPARE(server.seen.size(), 5);
        const auto textOf = [](const QJsonObject &body) {
            QString text;
            for (const auto &part : body["messages"].toArray().last().toObject()["content"].toArray())
                text += part.toObject()["text"].toString();
            return text;
        };
        QStringList read;
        for (int i = 0; i < 4; ++i) {
            const auto body = server.seen[i].body;
            QVERIFY(body["system"].toString().contains("You read one research paper in full"));
            const auto text = textOf(body);
            QVERIFY(text.contains("[Page 2]") && text.contains("Question: Which is easiest to present?"));
            read << text.section("Title: ", 1, 1).section('\n', 0, 0);
        }
        read.sort();
        QCOMPARE(read, QStringList({"Alpha Paper", "Beta Paper", "Delta Paper", "Gamma Paper"}));
        const auto last = server.seen.last().body;
        QVERIFY(last["system"].toString().contains("notes made by reading the whole paper"));
        const auto material = textOf(last);
        for (const auto *marker : {"=== P1: Alpha Paper ===", "=== P2: Beta Paper ===", "=== P4: Delta Paper ==="})
            QVERIFY2(material.contains(marker), marker);
        QVERIFY(!material.contains("[Page 2]") && !material.contains("<library_passages>"));
        // The answer's citation opens the second paper at its page; the question keeps that it read each in full.
        const auto answer = finished[0][1].toString();
        QVERIFY2(answer.contains("[P2 p. 1](owelk://document/" + store.documentLinkId(papers[1]) + "#page=1"),
            qPrintable(answer));
        QVERIFY(progress.size() >= 5);
        QVERIFY(progress.last()[1].toString().contains("4"));
        const auto thread = finished[0][2].toMap()["threadId"].toString();
        const auto asked = store.aiThread(thread)["messages"].toList()[0].toMap()["context"].toMap();
        QVERIFY(asked["readEach"].toBool());
        QVERIFY(asked["attachments"].toStringList().contains("library"));
        QVERIFY(!asked["attachments"].toStringList().contains("paper"));
        // Nine papers: too many to read each.
        ai->ask({{"source", papers[0]}, {"scope", "paper"}, {"papers", others(8)}, {"readEach", true},
            {"question", "Which is easiest?"}});
        QTRY_COMPARE_WITH_TIMEOUT(failed.size(), 1, 5000);
        QVERIFY(failed[0][1].toString().contains("up to 8"));
        QCOMPARE(server.seen.size(), 5);
        // Three at a time; Stop ends them all and reads no more.
        server.keepOpen = true;
        server.chunks = {};
        const int request = ai->ask({{"source", papers[0]}, {"scope", "paper"}, {"papers", others(4)},
            {"readEach", true}, {"question", "Which is easiest?"}});
        QTRY_COMPARE_WITH_TIMEOUT(server.seen.size(), 8, 5000);
        QTest::qWait(200);
        QCOMPARE(server.seen.size(), 8);
        ai->cancel(request);
        QTRY_COMPARE_WITH_TIMEOUT(failed.size(), 2, 5000);
        QCOMPARE(failed[1][1].toString(), QString("Stopped."));
        QTest::qWait(200);
        QCOMPARE(server.seen.size(), 8);
        QVERIFY(!ai->busy());
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
    void droppedTextIsExplainedWithoutAPaper()
    {
        // Text dropped on the desktop pet: no paper, no question; the passage names the conversation and
        // the AI explains it at the reader's level.
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        server.chunks = {MockServer::sse("content_block_delta",
                             {{"type", "content_block_delta"},
                                 {"delta", QJsonObject{{"type", "text_delta"}, {"text", "They add up to one."}}}}),
            MockServer::sse("message_stop", {{"type", "message_stop"}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->giveConsent("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-explain-test"));
        QSignalSpy finished(ai, &AiService::finished);
        ai->ask({{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"action", "explain"},
            {"selection", "The attention   weights sum to one."}, {"question", ""}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 1, 10000);
        const auto threadId = finished[0][2].toMap()["threadId"].toString();
        QCOMPARE(store.aiThread(threadId)["title"].toString(), QString("The attention weights sum to one."));
        const auto request = QJsonDocument(server.seen[0].body).toJson();
        QVERIFY(request.contains("Help me understand this material."));
        QVERIFY(request.contains("The attention   weights sum to one."));
        QVERIFY(request.contains("a student new to this field"));
        ai->clearApiKey("claude");
    }
    void chatsAreNamedByTheirFirstAnswer()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        server.chunks = {
            MockServer::sse("content_block_delta",
                {{"type", "content_block_delta"},
                    {"delta",
                        QJsonObject{{"type", "text_delta"},
                            {"text", "Radar waves pass through fog.\n<chat_title>\"안개 속 레이더.\"</chat_title>"}}}}),
            MockServer::sse("message_stop", {{"type", "message_stop"}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->giveConsent("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-title-test"));
        QSignalSpy finished(ai, &AiService::finished);
        // The first answer names the chat, in the same request; the name is not part of the answer.
        ai->ask({{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"action", "ask"},
            {"question", "레이더는 안개를 어떻게 통과하나요?"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 1, 10000);
        const auto threadId = finished[0][2].toMap()["threadId"].toString();
        QCOMPARE(store.aiThread(threadId)["title"].toString(), QString("안개 속 레이더"));
        QCOMPARE(finished[0][1].toString(), QString("Radar waves pass through fog."));
        QCOMPARE(server.seen.size(), 1);
        QVERIFY(server.seen[0].body["system"].toString().contains("<chat_title>"));
        // Later turns keep the name (also one the reader gave): no naming asked, a stray block taken out.
        QVERIFY(store.renameAiThread(threadId, "My radar notes"));
        ai->ask({{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"action", "ask"}, {"threadId", threadId},
            {"question", "더 자세히"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 2, 10000);
        QCOMPARE(store.aiThread(threadId)["title"].toString(), QString("My radar notes"));
        QVERIFY(!server.seen[1].body["system"].toString().contains("<chat_title>"));
        QVERIFY(!finished[1][1].toString().contains("chat_title"));
        // A translation keeps its plain name.
        ai->ask({{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"action", "translate"},
            {"selection", "Radar waves pass through fog."}, {"question", ""}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 3, 10000);
        QVERIFY(!server.seen[2].body["system"].toString().contains("<chat_title>"));
        QCOMPARE(
            store.aiThread(finished[2][2].toMap()["threadId"].toString())["title"].toString(), QString("Translate"));
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
    void glossIsQuickAndKeptNowhere()
    {
        QTemporaryDir directory;
        const auto pdf = directory.filePath("gloss.pdf");
        writeFixture(pdf, "Gloss Paper", 1);
        const auto source = QUrl::fromLocalFile(pdf);
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        server.chunks = {MockServer::sse("content_block_delta",
                             {{"type", "content_block_delta"},
                                 {"delta", QJsonObject{{"type", "text_delta"}, {"text", "**occlusion** — 가림"}}}}),
            MockServer::sse("message_stop", {{"type", "message_stop"}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->setProvider("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-gloss-test"));
        QSignalSpy finished(ai, &AiService::finished), failed(ai, &AiService::failed);
        // Nothing leaves before the provider was agreed to.
        ai->gloss({{"source", source}, {"page", 0}, {"text", "occlusion"}});
        QTRY_COMPARE_WITH_TIMEOUT(failed.size(), 1, 5000);
        QVERIFY(server.seen.isEmpty());
        ai->giveConsent("claude");
        // A word: its meaning here, from the fast model, with the sentences around it and no paper.
        ai->gloss({{"source", source}, {"page", 0}, {"text", "occlusion"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 1, 10000);
        QCOMPARE(finished[0][1].toString(), QString("**occlusion** — 가림"));
        const auto body = server.seen[0].body;
        QCOMPARE(body["model"].toString(), QString("claude-haiku-5-5"));
        QVERIFY(!body.contains("thinking"));
        const auto text
            = body["messages"].toArray().last().toObject()["content"].toArray().last().toObject()["text"].toString();
        QVERIFY(text.contains("<selection>\nocclusion\n</selection>"));
        QVERIFY(text.contains("<passage>") && text.contains("occlusion links observation to context"));
        QVERIFY(!text.contains("<paper_text>"));
        QVERIFY(text.contains("what it means in this passage"));
        QVERIFY(store.aiThreads().isEmpty());
        // A passage: its translation; with the model and effort chosen for Gloss.
        ai->setGloss("claude", "claude-sonnet-5-5", "medium");
        QCOMPARE(ai->glossChoice("claude"), QString("claude-sonnet-5-5"));
        ai->gloss({{"source", source}, {"page", 0},
            {"text", "Research finding 1.1: occlusion links observation to context."}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 2, 10000);
        QCOMPARE(server.seen[1].body["model"].toString(), QString("claude-sonnet-5-5"));
        QCOMPARE(server.seen[1].body["output_config"].toObject()["effort"].toString(), QString("medium"));
        ai->setGloss("claude", "", "low");
        QCOMPARE(ai->glossModel("claude"), QString("claude-haiku-5-5"));
        QVERIFY(QJsonDocument(server.seen[1].body).toJson().contains("Translate the selection into Korean"));
        QVERIFY(store.aiThreads().isEmpty());
        ai->clearApiKey("claude");
    }
    void attachedPicturesNobodyNeedsAreCleanedUp()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        const auto folder = store.dataDirectory() + "/ai-attachments";
        QVERIFY(QDir().mkpath(folder));
        const auto make = [&](const QString &name, int daysOld) {
            QFile file(folder + "/" + name);
            if (!file.open(QIODevice::WriteOnly)) return;
            file.write("png");
            file.flush();
            file.setFileTime(QDateTime::currentDateTime().addDays(-daysOld), QFileDevice::FileModificationTime);
        };
        make("kept.png", 3);
        make("orphan.png", 3);
        make("fresh.png", 0);
        const auto thread = store.createAiThread({{"provider", "claude"}, {"model", "m"}, {"title", "Pictures"}});
        QVERIFY(store.appendAiMessage(thread,
            {{"role", "user"}, {"content", "q"}, {"display", "q"},
                {"context",
                    QVariantMap{{"imageFiles", QStringList{QUrl::fromLocalFile(folder + "/kept.png").toString()}}}}}));
        // One a chat shows stays; one nobody refers to goes once a day old; a new one (about to be sent) stays.
        QMetaObject::invokeMethod(ai, "sweepAttachments");
        QTRY_VERIFY_WITH_TIMEOUT(!QFileInfo::exists(folder + "/orphan.png"), 5000);
        QVERIFY(QFileInfo::exists(folder + "/kept.png"));
        QVERIFY(QFileInfo::exists(folder + "/fresh.png"));
    }
    void ollamaOnAnotherComputerAsksFirst()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        const auto sends = [&] {
            for (const auto &row : ai->providers())
                if (row.toMap()["id"] == "ollama") return row.toMap()["sends"].toString();
            return QString();
        };
        // On this computer nothing leaves it: no question.
        QVERIFY(ai->consented("ollama"));
        QCOMPARE(sends(), QString("this computer only"));
        // A host elsewhere (a lab server) receives the text: asked first, and said where.
        QVERIFY(store.setSetting("ai.baseUrl.ollama", "http://192.168.0.20:11434/"));
        QVERIFY(!ai->consented("ollama"));
        QCOMPARE(sends(), QString("Ollama on 192.168.0.20"));
        ai->giveConsent("ollama");
        QVERIFY(ai->consented("ollama"));
        QVERIFY(store.setSetting("ai.baseUrl.ollama", "http://localhost:11434/"));
        QCOMPARE(sends(), QString("this computer only"));
    }
    void askedAgainSendsWhatWasSentAndBranchesKeepTheTurns()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        const auto answer = [&server](const QString &text) {
            server.chunks = {
                MockServer::sse("content_block_delta",
                    {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", text}}}}),
                MockServer::sse("message_stop", {{"type", "message_stop"}})};
        };
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->giveConsent("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-again-test"));
        QSignalSpy finished(ai, &AiService::finished);
        const QVariantMap base{{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"action", "ask"}};
        answer("First answer");
        auto first = base;
        first.insert({{"question", "What is it?"}, {"selection", "The selected words"}});
        ai->ask(first);
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 1, 5000);
        const auto thread = finished[0][2].toMap()["threadId"].toString();
        answer("Second answer");
        auto second = base;
        second.insert({{"question", "And then?"}, {"threadId", thread}, {"quote", "A quoted line"}});
        ai->ask(second);
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 2, 5000);
        auto messages = store.aiThread(thread)["messages"].toList();
        QCOMPARE(messages.size(), 4);
        const auto asked = messages[2].toMap();
        QVERIFY(asked["content"].toString().contains("A quoted line"));
        QCOMPARE(asked["context"].toMap()["action"].toString(), QString("ask"));
        // Asked again: the turn goes, and exactly what was sent then goes again after the turns before it.
        QVERIFY(!store.truncateAiThread(thread, "missing"));
        QVERIFY(store.truncateAiThread(thread, asked["id"].toString()));
        QCOMPARE(store.aiThread(thread)["messages"].toList().size(), 2);
        answer("Better answer");
        auto again = base;
        again.insert({{"question", "And then?"}, {"threadId", thread}, {"resend", asked["content"]},
            {"resendContext", asked["context"]}, {"scope", "none"}});
        ai->ask(again);
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 3, 5000);
        const auto sent = server.seen.last().body["messages"].toArray();
        QCOMPARE(sent.size(), 3);
        QString lastText;
        for (const auto &block : sent.last().toObject()["content"].toArray())
            if (block.toObject()["type"].toString() == "text") lastText += block.toObject()["text"].toString();
        if (lastText.isEmpty()) lastText = sent.last().toObject()["content"].toString();
        QCOMPARE(lastText, asked["content"].toString());
        messages = store.aiThread(thread)["messages"].toList();
        QCOMPARE(messages.size(), 4);
        QCOMPARE(messages[2].toMap()["content"], asked["content"]);
        QCOMPARE(messages[2].toMap()["display"].toString(), QString("And then?"));
        QCOMPARE(messages[2].toMap()["context"].toMap()["quote"].toString(), QString("A quoted line"));
        QCOMPARE(messages[3].toMap()["content"].toString(), QString("Better answer"));
        // A new chat from the first answer: those turns, in order, in the same Thread; the original stays whole.
        const auto fork = store.forkAiThread(thread, messages[1].toMap()["id"].toString());
        QVERIFY(!fork.isEmpty());
        const auto branch = store.aiThread(fork), original = store.aiThread(thread);
        QCOMPARE(branch["title"].toString(), "Branch · " + original["title"].toString());
        QCOMPARE(branch["folder"], original["folder"]);
        const auto copied = branch["messages"].toList();
        QCOMPARE(copied.size(), 2);
        QCOMPARE(copied[0].toMap()["content"], messages[0].toMap()["content"]);
        QCOMPARE(copied[1].toMap()["content"].toString(), QString("First answer"));
        QVERIFY(copied[0].toMap()["id"] != messages[0].toMap()["id"]);
        QCOMPARE(original["messages"].toList().size(), 4);
        // A branch of a branch keeps one prefix.
        QCOMPARE(
            store.aiThread(store.forkAiThread(fork, copied[1].toMap()["id"].toString()))["title"], branch["title"]);
    }

    void suggestedQuestionsAreKeptApartFromTheAnswer()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *ai = qobject_cast<AiService *>(store.ai());
        MockServer server;
        server.chunks = {MockServer::sse("content_block_delta",
                             {{"type", "content_block_delta"},
                                 {"delta",
                                     QJsonObject{{"type", "text_delta"},
                                         {"text",
                                             "The answer.\n\n<followups>\n- What comes next?\n2. Why "
                                             "so?\n</followups>\n"}}}}),
            MockServer::sse("message_stop", {{"type", "message_stop"}})};
        store.setSetting("ai.baseUrl.claude", server.base().toString());
        ai->giveConsent("claude");
        QVERIFY(ai->setApiKey("claude", "sk-ant-next-test"));
        QSignalSpy finished(ai, &AiService::finished);
        const QVariantMap base{{"provider", "claude"}, {"model", "claude-opus-5-5"}};
        auto ask = base;
        ask.insert({{"action", "ask"}, {"question", "What is it?"}});
        ai->ask(ask);
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 1, 5000);
        QVERIFY(server.seen.last().body["system"].toString().contains("<followups>"));
        // The answer is what is shown, copied and sent again; the questions go with it.
        QCOMPARE(finished[0][1].toString(), QString("The answer."));
        const auto messages = store.aiThread(finished[0][2].toMap()["threadId"].toString())["messages"].toList();
        QCOMPARE(messages[1].toMap()["content"].toString(), QString("The answer."));
        QCOMPARE(messages[1].toMap()["context"].toMap()["followUps"].toStringList(),
            QStringList({"What comes next?", "Why so?"}));
        // Not for a translation, nor when turned off.
        auto translate = base;
        translate.insert({{"action", "translate"}, {"selection", "Ein Satz."}});
        ai->ask(translate);
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 2, 5000);
        QVERIFY(!server.seen.last().body["system"].toString().contains("<followups>"));
        store.setSetting("ai.followUps", "0");
        ai->ask(ask);
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 3, 5000);
        QVERIFY(!server.seen.last().body["system"].toString().contains("<followups>"));
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
        // The connection ends before the answer does (no closing event): what arrived is kept, marked as such.
        server.keepOpen = false;
        server.chunks = {MockServer::sse("content_block_delta",
            {{"type", "content_block_delta"}, {"delta", QJsonObject{{"type", "text_delta"}, {"text", "Cut short"}}}})};
        ai->ask({{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"action", "ask"}, {"question", "More"}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 2, 5000);
        QVERIFY(finished[1][2].toMap()["interrupted"].toBool());
        QVERIFY(!finished[1][2].toMap()["cutOff"].toBool());
        const auto cut = store.aiThread(finished[1][2].toMap()["threadId"].toString())["messages"].toList();
        QVERIFY(cut.last().toMap()["context"].toMap()["interrupted"].toBool());
        // Owelk closing: answers still coming are kept, the question too when nothing had come yet (marked closed),
        // and a later question in that conversation does not send the unanswered one again.
        server.keepOpen = true;
        server.chunks = {};
        auto seenBefore = server.seen.size();
        ai->ask(
            {{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"action", "ask"}, {"question", "Before closing"}});
        QTRY_VERIFY_WITH_TIMEOUT(server.seen.size() == seenBefore + 1, 5000);
        ai->closeAll();
        QVERIFY(!ai->busy());
        const auto closed = store.aiThreads("Before closing");
        QCOMPARE(closed.size(), 1);
        const auto closedId = closed[0].toMap()["id"].toString();
        const auto kept = store.aiThread(closedId)["messages"].toList();
        QCOMPARE(kept.size(), 2);
        QVERIFY(kept[1].toMap()["content"].toString().isEmpty());
        QVERIFY(kept[1].toMap()["context"].toMap()["closed"].toBool());
        server.keepOpen = false;
        server.chunks = {MockServer::sse("content_block_delta",
                             {{"type", "content_block_delta"},
                                 {"delta", QJsonObject{{"type", "text_delta"}, {"text", "Answered"}}}}),
            MockServer::sse("message_stop", {{"type", "message_stop"}})};
        seenBefore = server.seen.size();
        ai->ask({{"provider", "claude"}, {"model", "claude-opus-5-5"}, {"action", "ask"},
            {"question", "After reopening"}, {"threadId", closedId}});
        QTRY_VERIFY_WITH_TIMEOUT(server.seen.size() == seenBefore + 1, 5000);
        const auto sent = QJsonDocument(server.seen.last().body).toJson();
        QVERIFY(sent.contains("After reopening"));
        QVERIFY(!sent.contains("Before closing"));
        QTRY_COMPARE_WITH_TIMEOUT(store.aiThread(closedId)["messages"].toList().size(), 4, 5000);
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
        // The answer is kept as a thread: searchable and linked to the paper.
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
        for (const auto &row : store.searchKnowledge("Page", QUrl(), "notes"))
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
        QCOMPARE(store.purgeAiThreads({threadId}), 1);
        QVERIFY(store.aiThread(threadId).isEmpty());
        QVERIFY(ai->clearApiKey("claude"));
        QVERIFY(!ai->hasApiKey("claude"));
    }
};

QTEST_MAIN(AiTest)
#include "AiTest.moc"
