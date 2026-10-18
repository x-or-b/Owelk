#include "LibraryInsights.h"
#include "ResearchStore.h"
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUuid>
#include <QtTest>

class Server : public QObject {
public:
    QTcpServer server;
    QList<QJsonArray> batches;
    QList<QByteArray> requests;
    bool hold = false, fail = false;
    Server()
    {
        connect(&server, &QTcpServer::newConnection, this, [this] {
            auto *socket = server.nextPendingConnection();
            connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
            connect(socket, &QTcpSocket::readyRead, socket, [this, socket] {
                auto data = socket->property("data").toByteArray() + socket->readAll();
                socket->setProperty("data", data);
                const auto end = data.indexOf("\r\n\r\n");
                if (end < 0 || socket->property("done").toBool()) return;
                const int length
                    = QRegularExpression("Content-Length: (\\d+)", QRegularExpression::CaseInsensitiveOption)
                          .match(QString::fromUtf8(data.left(end)))
                          .captured(1)
                          .toInt();
                if (data.size() < end + 4 + length) return;
                socket->setProperty("done", true);
                requests << data;
                const auto ids = QJsonDocument::fromJson(data.mid(end + 4)).object().value("ids").toArray();
                batches << ids;
                if (hold) return;
                QJsonArray rows;
                for (const auto &id : ids) {
                    if (id.toString().endsWith("missing"))
                        rows << QJsonValue::Null;
                    else
                        rows << QJsonObject{{"tldr", QJsonObject{{"text", "A short summary."}}}, {"citationCount", 0}};
                }
                const auto body = fail ? QByteArray("{\"error\":\"rate limited\"}")
                                       : QJsonDocument(rows).toJson(QJsonDocument::Compact);
                socket->write(QByteArray(fail ? "HTTP/1.1 429 Too Many Requests\r\n" : "HTTP/1.1 200 OK\r\n")
                    + "Content-Type: application/json\r\nConnection: close\r\nContent-Length: "
                    + QByteArray::number(body.size()) + "\r\n\r\n" + body);
                socket->disconnectFromHost();
            });
        });
    }
    QString url() const { return QString("http://127.0.0.1:%1/graph/v1").arg(server.serverPort()); }
};

class LibraryInsightsTest : public QObject {
    Q_OBJECT
    static bool seed(ResearchStore &store, int count)
    {
        const auto name = QUuid::createUuid().toString();
        bool ok = true;
        {
            auto db = QSqlDatabase::addDatabase("QSQLITE", name);
            db.setDatabaseName(store.dataDirectory() + "/owelk.sqlite3");
            if (!db.open()) return false;
            db.transaction();
            QSqlQuery q(db);
            q.prepare("INSERT INTO documents(id,url,title,added_at,kind,doi,arxiv,metadata_origin) "
                      "VALUES(?,?,?,'2026-01-01','pdf',?,?,'manual')");
            for (int i = 0; i < count; ++i) {
                q.bindValue(0, QString::number(i));
                q.bindValue(1, "file:///unavailable/paper-" + QString::number(i) + ".pdf");
                q.bindValue(2, "PRIVATE TITLE");
                q.bindValue(3, i == count - 1 ? QStringLiteral("") : "10.1234/" + QString::number(i));
                q.bindValue(4, QStringLiteral(""));
                ok = q.exec() && ok;
            }
            ok = db.commit() && ok;
        }
        QSqlDatabase::removeDatabase(name);
        return ok;
    }
    static QJsonObject read(const QString &directory)
    {
        QFile file(directory + "/library-insights.json");
        if (!file.open(QIODevice::ReadOnly)) return {};
        return QJsonDocument::fromJson(file.readAll()).object();
    }
    static void write(const QString &directory, const QJsonObject &data)
    {
        QFile file(directory + "/library-insights.json");
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write(QJsonDocument(data).toJson());
    }
private slots:
    void identifiersOnly()
    {
        QCOMPARE(LibraryInsights::identifier("10.1234/AbC", "2301.00001v2"), "DOI:10.1234/abc");
        QCOMPARE(LibraryInsights::identifier("", "2301.00001v2"), "ARXIV:2301.00001");
        QCOMPARE(LibraryInsights::identifier("", "hep-th/9901001v3"), "ARXIV:hep-th/9901001");
        QVERIFY(LibraryInsights::identifier("private title", "private note").isEmpty());
    }
    void consentBatchLimitAndDailyCheck()
    {
        QTemporaryDir directory;
        Server server;
        QVERIFY(server.server.listen(QHostAddress::LocalHost));
        ResearchStore store(directory.path());
        QVERIFY(store.initialize(nullptr));
        QVERIFY(seed(store, 502)); // 501 DOI papers, one without an identifier.
        store.setSetting("citations.baseUrl", server.url());
        auto *insights = qobject_cast<LibraryInsights *>(store.libraryInsights());
        QVERIFY(insights);
        QVERIFY(!insights->enabled());
        insights->check();
        QTest::qWait(30);
        QVERIFY(server.requests.isEmpty());
        store.setSetting("library.insights", "1");
        QTRY_COMPARE_WITH_TIMEOUT(server.batches.size(), 2, 5000);
        QCOMPARE(server.batches[0].size(), 500);
        QCOMPARE(server.batches[1].size(), 1);
        QTRY_COMPARE(insights->details("10.1234/500", "").value("tldr").toString(), "A short summary.");
        for (const auto &request : server.requests) {
            QVERIFY(request.startsWith("POST /graph/v1/paper/batch?fields=tldr,citationCount "));
            QVERIFY(!request.contains("PRIVATE TITLE"));
            QVERIFY(!request.contains("file:"));
        }
        QCOMPARE(read(directory.path()).value("entries").toObject().size(), 501);
        insights->check();
        QTest::qWait(30);
        QCOMPARE(server.requests.size(), 2);
        store.setSetting("library.insights", "0");
        QVERIFY(insights->details("10.1234/0", "").isEmpty());
    }
    void cacheSurvivesRestartAndRefreshesAfterThirtyDays()
    {
        QTemporaryDir directory;
        Server server;
        QVERIFY(server.server.listen(QHostAddress::LocalHost));
        {
            ResearchStore store(directory.path());
            QVERIFY(store.initialize(nullptr));
            QVERIFY(seed(store, 2));
            store.setSetting("citations.baseUrl", server.url());
            store.setSetting("library.insights", "1");
            QTRY_COMPARE(read(directory.path()).value("entries").toObject().size(), 1);
        }
        auto cached = read(directory.path());
        cached["checked"] = QDateTime::currentDateTimeUtc().addDays(-2).toString(Qt::ISODate);
        write(directory.path(), cached);
        {
            ResearchStore store(directory.path());
            QVERIFY(store.initialize(nullptr));
            auto *insights = qobject_cast<LibraryInsights *>(store.libraryInsights());
            QCOMPARE(insights->details("10.1234/0", "").value("citationCount").toInt(), 0);
            insights->check();
            QTest::qWait(50);
            QCOMPARE(server.requests.size(), 1); // Daily checks do not refetch a fresh cache.
        }
        cached = read(directory.path());
        cached["checked"] = QDateTime::currentDateTimeUtc().addDays(-2).toString(Qt::ISODate);
        auto entries = cached.value("entries").toObject();
        auto entry = entries.value("DOI:10.1234/0").toObject();
        entry["fetched"] = QDateTime::currentDateTimeUtc().addDays(-31).toString(Qt::ISODate);
        entries["DOI:10.1234/0"] = entry;
        cached["entries"] = entries;
        write(directory.path(), cached);
        ResearchStore store(directory.path());
        QVERIFY(store.initialize(nullptr));
        QTest::qWait(50);
        QCOMPARE(server.requests.size(), 1); // Nothing while the window opens.
        qobject_cast<LibraryInsights *>(store.libraryInsights())->check();
        QTRY_COMPARE(server.requests.size(), 2);
        QTRY_VERIFY(
            read(directory.path()).value("entries").toObject().value("DOI:10.1234/0").toObject().value("fetched")
            != entry.value("fetched"));
    }
    void disablingAbortsAndErrorsWaitUntilTomorrow_data()
    {
        QTest::addColumn<bool>("hold");
        QTest::newRow("abort") << true;
        QTest::newRow("rate-limit") << false;
    }
    void disablingAbortsAndErrorsWaitUntilTomorrow()
    {
        QFETCH(bool, hold);
        QTemporaryDir directory;
        Server server;
        server.hold = hold;
        server.fail = !hold;
        QVERIFY(server.server.listen(QHostAddress::LocalHost));
        ResearchStore store(directory.path());
        QVERIFY(store.initialize(nullptr));
        QVERIFY(seed(store, 2));
        store.setSetting("citations.baseUrl", server.url());
        store.setSetting("library.insights", "1");
        QTRY_COMPARE(server.requests.size(), 1);
        auto *insights = qobject_cast<LibraryInsights *>(store.libraryInsights());
        if (hold) store.setSetting("library.insights", "0");
        QTest::qWait(50);
        insights->check();
        QTest::qWait(30);
        QCOMPARE(server.requests.size(), 1);
        QVERIFY(read(directory.path()).value("entries").toObject().isEmpty());
    }
};
QTEST_MAIN(LibraryInsightsTest)
#include "LibraryInsightsTest.moc"
