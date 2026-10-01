#include "ResearchStore.h"
#include "PaperIndex.h"
#include "PdfFixture.h"
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QSqlQuery>
#include <QUuid>
#include <QtTest>

namespace {
QVariantMap state(const QUrl &source)
{
    return {{"version", 1},
        {"left", QVariantMap{{"source", source.toString()}, {"position", QVariantMap{{"page", 3}, {"zoom", 1.4}}}}}};
}
QVariantList sql(const QString &path, const QString &statement)
{
    const auto name = QUuid::createUuid().toString();
    QVariantList rows;
    {
        auto db = QSqlDatabase::addDatabase("QSQLITE", name);
        db.setDatabaseName(path);
        if (db.open()) {
            QSqlQuery query(db);
            if (query.exec(statement))
                while (query.next()) rows.append(query.value(0));
        }
        db.close();
    }
    QSqlDatabase::removeDatabase(name);
    return rows;
}
}
class RelinkTest : public QObject {
    Q_OBJECT
private slots:
    void updatesReferencesPreservesCaptureAndIndexId()
    {
        QTemporaryDir dir;
        const auto old = QUrl::fromLocalFile(dir.filePath("old.pdf")),
                   next = QUrl::fromLocalFile(dir.filePath("moved.pdf"));
        writeFixture(old.toLocalFile());
        QString capture, documentId, workspace;
        {
            ResearchStore store(dir.filePath("data"));
            QString error;
            QVERIFY(store.initialize(&error));
            auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
            QVERIFY(store.rememberDocument(old));
            QVERIFY(store.saveSession(state(old)));
            workspace = store.createWorkspace("Research");
            QVERIFY(store.saveWorkspace(workspace, state(old)));
            const auto unlinked = store.createWorkspace("Unlinked research");
            QVERIFY(store.saveWorkspace(unlinked, state(old)));
            QVERIFY(store.setWorkspaceDocument(unlinked, old, false));
            store.captureRegion(old, 0, QRectF(.1, .1, .4, .2));
            QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
            QCOMPARE(store.captures().size(), 1);
            capture = store.captures().first().toMap()["id"].toString();
            QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 10000);
            documentId = index->documents().first().toMap()["id"].toString();
            QVERIFY(QFile::rename(old.toLocalFile(), next.toLocalFile())); // Only temporary generated fixture.
            QSignalSpy done(&store, &ResearchStore::relinkFinished);
            store.relinkSource(old, next);
            QVERIFY(done.wait(10000));
            QVERIFY2(done.first()[0].toBool(), qPrintable(done.first()[1].toString()));
            QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 10000);
            QCOMPARE(store.resolvedSource(old), next);
            QCOMPARE(store.session()["left"].toMap()["source"].toString(), next.toString());
            QCOMPARE(store.loadWorkspace(workspace)["left"].toMap()["source"].toString(), next.toString());
            QVERIFY(store.saveWorkspace(unlinked, state(old)));
            QVERIFY(store.workspaceDetails(unlinked)["documents"].toList().isEmpty());
            QCOMPARE(store.readingPosition(next)["page"].toInt(), 3);
            QCOMPARE(store.recentDocuments().first().toMap()["url"].toUrl(), next);
            QCOMPARE(store.captures().first().toMap()["source"].toUrl(), next);
            QCOMPARE(index->documents().size(), 1);
            QCOMPARE(index->documents().first().toMap()["id"].toString(), documentId);
            QSignalSpy opened(&store, &ResearchStore::sourceReady);
            store.openCapture(capture);
            QVERIFY(opened.wait(10000));
            QCOMPARE(opened.first()[0].toUrl(), next);
            QVERIFY(store.saveSession(state(old))); // A stale queued save must not restore the old path.
            QCOMPARE(store.session()["left"].toMap()["source"].toString(), next.toString());
            QVERIFY(QFileInfo::exists(store.captures().first().toMap()["image"].toUrl().toLocalFile()));
        }
        // Simulate exit after primary data committed but before the separate search cache was updated.
        sql(dir.filePath("data/search.sqlite3"),
            "UPDATE documents SET state='paused',url='" + QString(old.toString()).replace("'", "''") + "'");
        QCOMPARE(
            sql(dir.filePath("data/search.sqlite3"), "SELECT url FROM documents").first().toString(), old.toString());
        ResearchStore reopened(dir.filePath("data"));
        QString error;
        QVERIFY(reopened.initialize(&error));
        auto *index = qobject_cast<PaperIndex *>(reopened.paperIndex());
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 10000);
        QCOMPARE(reopened.resolvedSource(old), next);
        QCOMPARE(index->documents().size(), 1);
        QCOMPARE(index->documents().first().toMap()["id"].toString(), documentId);
        QCOMPARE(index->documents().first().toMap()["source"].toUrl(), next);
        QVERIFY(QFileInfo::exists(next.toLocalFile()));
    }
    void wrongFileAndUnknownFingerprintDoNotModifyData()
    {
        QTemporaryDir dir;
        const auto old = QUrl::fromLocalFile(dir.filePath("old.pdf")),
                   wrong = QUrl::fromLocalFile(dir.filePath("wrong.pdf"));
        writeFixture(old.toLocalFile());
        writeFixture(wrong.toLocalFile(), "Different PDF");
        ResearchStore store(dir.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        store.rememberDocument(old);
        store.saveSession(state(old));
        auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 10000);
        QSignalSpy done(&store, &ResearchStore::relinkFinished);
        store.relinkSource(old, wrong);
        QVERIFY(done.wait(10000));
        QVERIFY(!done.last()[0].toBool());
        QCOMPARE(store.resolvedSource(old), old);
        QCOMPARE(store.session()["left"].toMap()["source"].toString(), old.toString());
        const auto unknown = QUrl::fromLocalFile(dir.filePath("missing.pdf"));
        done.clear();
        store.relinkSource(unknown, wrong);
        QVERIFY(done.wait(10000));
        QVERIFY(!done.last()[0].toBool());
        QVERIFY(done.last()[1].toString().contains("No saved fingerprint"));
        QVERIFY(QFileInfo::exists(old.toLocalFile()));
        QVERIFY(QFileInfo::exists(wrong.toLocalFile()));
    }
    void mergesKnownTargetAndPreservesDeletedCapture()
    {
        QTemporaryDir dir;
        const auto old = QUrl::fromLocalFile(dir.filePath("old.pdf")),
                   next = QUrl::fromLocalFile(dir.filePath("copy.pdf"));
        writeFixture(old.toLocalFile());
        QVERIFY(QFile::copy(old.toLocalFile(), next.toLocalFile()));
        ResearchStore store(dir.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
        store.rememberDocument(old);
        store.saveSession(state(old));
        store.rememberDocument(next);
        store.captureRegion(old, 0, QRectF(.1, .1, .4, .2));
        QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
        const auto id = store.captures().first().toMap()["id"].toString();
        QVERIFY(store.deleteCapture(id));
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 10000);
        QSignalSpy done(&store, &ResearchStore::relinkFinished);
        store.relinkSource(old, next);
        QVERIFY(done.wait(10000));
        QVERIFY2(done.first()[0].toBool(), qPrintable(done.first()[1].toString()));
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 10000);
        QCOMPARE(store.recentDocuments().size(), 1);
        QCOMPARE(index->documents().size(), 1);
        QCOMPARE(sql(dir.filePath("data/owelk.sqlite3"),
                     "SELECT d.url FROM captures c JOIN documents d ON d.id=c.document_id")
                     .first()
                     .toString(),
            next.toString());
        QCOMPARE(sql(dir.filePath("data/owelk.sqlite3"), "SELECT count(*) FROM deleted_captures").first().toInt(), 1);
        QVERIFY(store.captures().isEmpty());
        QVERIFY(QFileInfo::exists(old.toLocalFile()));
    }
    void invalidSavedStateRollsBackEverything()
    {
        QTemporaryDir dir;
        const auto old = QUrl::fromLocalFile(dir.filePath("old.pdf")),
                   next = QUrl::fromLocalFile(dir.filePath("copy.pdf"));
        writeFixture(old.toLocalFile());
        QVERIFY(QFile::copy(old.toLocalFile(), next.toLocalFile()));
        ResearchStore store(dir.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        store.rememberDocument(old);
        store.saveSession(state(old));
        sql(dir.filePath("data/owelk.sqlite3"), "UPDATE settings SET value='broken' WHERE key='session'");
        QSignalSpy done(&store, &ResearchStore::relinkFinished);
        store.relinkSource(old, next);
        QVERIFY(done.wait(10000));
        QVERIFY(!done.first()[0].toBool());
        QCOMPARE(store.recentDocuments().first().toMap()["url"].toUrl(), old);
        QCOMPARE(store.resolvedSource(old), old);
        QCOMPARE(sql(dir.filePath("data/owelk.sqlite3"), "SELECT value FROM settings WHERE key='session'")
                     .first()
                     .toString(),
            "broken");
        QCOMPARE(sql(dir.filePath("data/owelk.sqlite3"), "SELECT count(*) FROM source_relinks").first().toInt(), 0);
    }
    void mixedVersionsAreRejected()
    {
        QTemporaryDir dir;
        const auto old = QUrl::fromLocalFile(dir.filePath("old.pdf")),
                   next = QUrl::fromLocalFile(dir.filePath("copy.pdf"));
        writeFixture(old.toLocalFile());
        QVERIFY(QFile::copy(old.toLocalFile(), next.toLocalFile()));
        ResearchStore store(dir.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        store.captureRegion(old, 0, QRectF(.1, .1, .4, .2));
        QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
        writeFixture(old.toLocalFile(), "New version");
        store.rememberDocument(old);
        auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 10000);
        QSignalSpy done(&store, &ResearchStore::relinkFinished);
        store.relinkSource(old, next);
        QCOMPARE(done.size(), 1);
        QVERIFY(!done.first()[0].toBool());
        QVERIFY(done.first()[1].toString().contains("different PDF versions"));
        QCOMPARE(store.captures().first().toMap()["source"].toUrl(), old);
    }
};
QTEST_MAIN(RelinkTest)
#include "RelinkTest.moc"
