#include "PaperIndex.h"
#include "PdfFixture.h"
#include "ResearchStore.h"
#include "SemanticIndex.h"

#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUuid>
#include <QtTest>

namespace {
// A stand-in for Ollama's /api/embed: words with the same meaning land on the same dimension, so
// "cup hidden behind desk" is close to "mug occluded behind the table" without sharing a word.
class FakeEmbeddings : public QObject {
public:
    int inputs = 0;
    FakeEmbeddings()
    {
        m_server.listen(QHostAddress::LocalHost);
        connect(&m_server, &QTcpServer::newConnection, this, [this] {
            auto *socket = m_server.nextPendingConnection();
            auto buffer = std::make_shared<QByteArray>();
            connect(socket, &QTcpSocket::readyRead, socket, [this, socket, buffer] {
                *buffer += socket->readAll();
                const auto split = buffer->indexOf("\r\n\r\n");
                if (split < 0) return;
                const auto head = QString::fromUtf8(buffer->left(split));
                const auto length = head.section("Content-Length: ", 1).section("\r\n", 0, 0).toInt();
                if (buffer->size() < split + 4 + length) return;
                const auto body = QJsonDocument::fromJson(buffer->mid(split + 4, length)).object();
                QJsonArray embeddings;
                for (const auto &input : body["input"].toArray()) {
                    ++inputs;
                    embeddings.append(vector(input.toString()));
                }
                const auto reply
                    = QJsonDocument(QJsonObject{{"embeddings", embeddings}}).toJson(QJsonDocument::Compact);
                socket->write(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
                    + QByteArray::number(reply.size()) + "\r\n\r\n" + reply);
                socket->disconnectFromHost();
            });
        });
    }
    QString base() const { return QStringLiteral("http://127.0.0.1:%1/").arg(m_server.serverPort()); }
    static QJsonArray vector(const QString &text)
    {
        static const QList<QStringList> concepts{{"cup", "mug"}, {"hidden", "occluded", "behind", "occlusion"},
            {"desk", "table"}, {"lidar", "radar", "odometry"}, {"gravity", "inertial"}, {"coffee", "tea"}};
        QList<double> values(concepts.size() + 1, 0.01);
        for (const auto &word : text.toLower().split(QRegularExpression("\\W+"), Qt::SkipEmptyParts)) {
            bool known = false;
            for (qsizetype i = 0; i < concepts.size(); ++i)
                if (concepts[i].contains(word)) {
                    values[i] += 1;
                    known = true;
                }
            if (!known) values.last() += .05;
        }
        QJsonArray array;
        for (const auto v : values) array.append(v);
        return array;
    }

private:
    QTcpServer m_server;
};
}

class SemanticTest : public QObject {
    Q_OBJECT
private slots:
    void meaningSearchIsOptionalIncrementalAndFindsSynonyms()
    {
        QTemporaryDir directory;
        const auto a = QUrl::fromLocalFile(directory.filePath("scene.pdf"));
        const auto b = QUrl::fromLocalFile(directory.filePath("odometry.pdf"));
        const auto c = QUrl::fromLocalFile(directory.filePath("office.pdf"));
        writeTextFixture(a.toLocalFile(), {"In our scene the mug was occluded behind the table for most frames."});
        writeTextFixture(b.toLocalFile(), {"Radar and lidar odometry is corrected with gravity from inertial data."});
        writeTextFixture(c.toLocalFile(), {"A cup stood on the desk, partly hidden behind a monitor."});
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        for (const auto &url : {a, b, c}) QVERIFY(store.rememberDocument(url));
        auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 20000);
        auto *semantic = qobject_cast<SemanticIndex *>(store.semantic());
        QVERIFY(semantic);
        // Off: nothing is created or contacted.
        QVERIFY(!semantic->enabled());
        QVERIFY(!QFileInfo::exists(directory.filePath("data/semantic.sqlite3")));
        QSignalSpy found(semantic, &SemanticIndex::found);
        semantic->search("cup hidden behind desk");
        QTRY_COMPARE(found.size(), 1);
        QVERIFY(found[0][1].toList().isEmpty());

        FakeEmbeddings server;
        store.setSetting("semantic.baseUrl.ollama", server.base());
        semantic->configure("ollama", "test-embed");
        QTRY_VERIFY_WITH_TIMEOUT(!semantic->busy() && semantic->storedCount() >= 3, 20000);
        QVERIFY2(semantic->error().isEmpty(), qPrintable(semantic->error()));
        const int embedded = server.inputs;

        // A query with none of the page's words still finds it by meaning.
        found.clear();
        semantic->search("cup hidden behind desk");
        QTRY_COMPARE_WITH_TIMEOUT(found.size(), 1, 10000);
        auto rows = found[0][1].toList();
        QVERIFY(rows.size() >= 2);
        const auto first = rows[0].toMap();
        QCOMPARE(first["kind"].toString(), QString("text"));
        QVERIFY(first["semantic"].toBool());
        QVERIFY(first["source"].toUrl() == a || first["source"].toUrl() == c);
        QVERIFY(rows.last().toMap()["source"].toUrl() == b);

        // Related papers: the office scene is closest to the occluded mug, odometry is farthest.
        found.clear();
        semantic->relatedPapers(a);
        QTRY_COMPARE_WITH_TIMEOUT(found.size(), 1, 10000);
        rows = found[0][1].toList();
        QCOMPARE(rows.size(), 2);
        QCOMPARE(rows[0].toMap()["source"].toUrl(), c);
        QCOMPARE(rows[0].toMap()["kind"].toString(), QString("paper"));

        // Incremental: unchanged text is not embedded again; a new note is.
        semantic->configure("ollama", "test-embed");
        QTRY_VERIFY_WITH_TIMEOUT(!semantic->busy(), 20000);
        QCOMPARE(server.inputs, embedded + 1); // Only the earlier query.
        const auto note = store.createNote("Coffee break", "The mug sits behind the desk.");
        QVERIFY(!note.isEmpty());
        semantic->configure("ollama", "test-embed");
        QTRY_VERIFY_WITH_TIMEOUT(!semantic->busy() && server.inputs > embedded + 1, 20000);
        found.clear();
        semantic->search("tea cup");
        QTRY_COMPARE_WITH_TIMEOUT(found.size(), 1, 10000);
        for (const auto &r : found[0][1].toList())
            qDebug() << r.toMap()["kind"] << r.toMap()["id"] << r.toMap()["similarity"] << r.toMap()["title"];
        qDebug() << "stored" << semantic->storedCount() << server.inputs << embedded;
        QCOMPARE(found[0][1].toList().first().toMap()["id"].toString(), note);

        // Off again: no results, and clearing frees the stored vectors.
        semantic->configure("", "");
        found.clear();
        semantic->search("cup");
        QTRY_COMPARE(found.size(), 1);
        QVERIFY(found[0][1].toList().isEmpty());
        semantic->clear();
        QCOMPARE(semantic->storedCount(), 0);
    }
};

QTEST_MAIN(SemanticTest)
#include "SemanticTest.moc"
