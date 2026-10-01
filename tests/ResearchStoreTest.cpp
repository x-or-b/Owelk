#include "ResearchStore.h"
#include "SelectionGeometry.h"
#include "PdfFixture.h"
#include "PaperMetadata.h"
#include <QDir>
#include <QFile>
#include <QImage>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QSignalSpy>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

class ResearchStoreTest : public QObject {
    Q_OBJECT
private slots:
    void paperMetadataIsReadLocally()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("2305.01234v2.pdf");
        writeFixture(path, "Declared Paper Title");
        const auto metadata = extractPaperMetadata(path);
        QCOMPARE(metadata.title, QString("Declared Paper Title"));
        QCOMPARE(metadata.arxiv, QString("2305.01234"));
        QCOMPARE(metadata.year, QString("2023"));
        QVERIFY(!PaperMetadataText::usableTitle("Microsoft Word - draft.docx", "draft.pdf"));
        QVERIFY(!PaperMetadataText::usableTitle("paper", "x.pdf"));
        QVERIFY(PaperMetadataText::usableTitle("Paper Plane: Folding Models", "x.pdf"));
        QCOMPARE(PaperMetadataText::findDoi("see doi:10.1145/3592433. Next"), QString("10.1145/3592433"));
        QCOMPARE(PaperMetadataText::findArxiv("arXiv:2101.00001v3 [cs.CV]"), QString("2101.00001"));
    }
    void urlKeyedDataMovesToDocumentIdsWithBackup()
    {
        QTemporaryDir directory;
        QVERIFY(QDir().mkpath(directory.filePath("data")));
        const auto pdf = directory.filePath("Kept paper.pdf");
        writeFixture(pdf, "Kept Paper Title");
        const auto url = QUrl::fromLocalFile(pdf).toString();
        {
            ResearchStore fresh(directory.filePath("data"));
            QString error;
            QVERIFY2(fresh.initialize(&error), qPrintable(error));
        }
        {
            // Rebuild the schema-2 shape (every table keyed by file URL) as the previous release wrote it.
            auto db = QSqlDatabase::addDatabase("QSQLITE", "v2");
            db.setDatabaseName(directory.filePath("data/owelk.sqlite3"));
            QVERIFY(db.open());
            QSqlQuery query(db);
            for (const auto *sql : {"DROP TABLE documents", "DROP TABLE recent_documents",
                     "DROP TABLE reading_positions", "DROP TABLE workspace_documents",
                     "DROP TABLE workspace_document_exclusions", "DROP TABLE captures", "DROP TABLE highlights",
                     "CREATE TABLE recent_documents (url TEXT PRIMARY KEY, opened_at TEXT NOT NULL)",
                     "CREATE TABLE reading_positions (url TEXT PRIMARY KEY, position TEXT NOT NULL)",
                     "CREATE TABLE workspace_documents (workspace_id TEXT NOT NULL, url TEXT NOT NULL, "
                     "PRIMARY KEY(workspace_id,url))",
                     "CREATE TABLE workspace_document_exclusions (workspace_id TEXT NOT NULL, url TEXT NOT NULL, "
                     "PRIMARY KEY(workspace_id,url))",
                     "CREATE TABLE captures (id TEXT PRIMARY KEY, source TEXT NOT NULL, sha256 TEXT NOT NULL, "
                     "page INTEGER NOT NULL, x REAL NOT NULL, y REAL NOT NULL, width REAL NOT NULL, height REAL NOT "
                     "NULL, "
                     "image TEXT NOT NULL, created_at TEXT NOT NULL)",
                     "CREATE TABLE highlights (id TEXT PRIMARY KEY, source TEXT NOT NULL, sha256 TEXT NOT NULL, "
                     "page INTEGER NOT NULL,text TEXT NOT NULL,rectangles TEXT NOT NULL,start_index INTEGER NOT NULL,"
                     "end_index INTEGER NOT NULL,created_at TEXT NOT NULL,deleted_at TEXT,color TEXT NOT NULL DEFAULT "
                     "'#426b9a',kind TEXT NOT NULL DEFAULT 'highlight',body TEXT NOT NULL DEFAULT '',image TEXT NOT "
                     "NULL "
                     "DEFAULT '',drawing TEXT NOT NULL DEFAULT '[]')",
                     "PRAGMA user_version=2"})
                QVERIFY2(query.exec(sql), qPrintable(query.lastError().text()));
            for (const auto *sql : {"INSERT INTO recent_documents VALUES('%1','2026-09-01')",
                     "INSERT INTO reading_positions VALUES('%1','{\"page\":5,\"y\":0.25}')",
                     "INSERT INTO workspaces VALUES('w1','Topic','{}','2026-09-01')",
                     "INSERT INTO workspace_documents VALUES('w1','%1')",
                     "INSERT INTO workspace_document_exclusions VALUES('w2','%1')",
                     "INSERT INTO captures VALUES('91ffeb1a-df10-4a54-a6fc-8a8b2c629b13','%1','h',2,.1,.2,.3,.4,'',"
                     "'2026-09-01')",
                     "INSERT INTO text_captures VALUES('91ffeb1a-df10-4a54-a6fc-8a8b2c629b13','kept excerpt "
                     "words',0,5,'','')",
                     "INSERT INTO highlights(id,source,sha256,page,text,rectangles,start_index,end_index,created_at) "
                     "VALUES('h1','%1','h',1,'kept highlight words','[]',0,4,'2026-09-01')"})
                QVERIFY2(query.exec(QString(sql).arg(url)), qPrintable(query.lastError().text()));
            db.close();
        }
        QSqlDatabase::removeDatabase("v2");
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        const QUrl source(url);
        QCOMPARE(store.recentDocuments().size(), 1);
        QCOMPARE(store.readingPosition(source)["page"].toInt(), 5);
        QCOMPARE(store.captures().size(), 1);
        QCOMPARE(store.captures()[0].toMap()["source"].toUrl(), source);
        QCOMPARE(store.searchKnowledge("kept excerpt").size(), 1);
        QCOMPARE(store.searchKnowledge("kept highlight").size(), 1);
        QCOMPARE(store.workspaceDetails("w1")["documents"].toList().size(), 1);
        QCOMPARE(QDir(directory.filePath("data/backups")).entryList({"before-schema-3-*.sqlite3"}).size(), 1);
        // Details are read from the PDF in the background and replace the file name for display.
        QTRY_COMPARE_WITH_TIMEOUT(store.displayName(source), QString("Kept Paper Title"), 10000);
        QCOMPARE(store.searchKnowledge("Kept Paper Title").first().toMap()["kind"].toString(), QString("paper"));
        QVERIFY(store.updateDocumentDetails(
            source, {{"title", "My Own Title"}, {"authors", "A. Author"}, {"year", "2024"}}));
        QCOMPARE(store.displayName(source), QString("My Own Title"));
        QCOMPARE(store.searchKnowledge("A. Author").size(), 1);
        QVERIFY(!store.updateDocumentDetails(source, {{"year", "20x4"}}));
    }
    void unversionedDataMigratesInPlaceAndNewerIsRefused()
    {
        QTemporaryDir directory;
        QVERIFY(QDir().mkpath(directory.filePath("data")));
        const auto file = directory.filePath("data/owelk.sqlite3");
        {
            // A pre-versioning file: highlights without annotation columns, one existing row.
            auto db = QSqlDatabase::addDatabase("QSQLITE", "legacy");
            db.setDatabaseName(file);
            QVERIFY(db.open());
            QSqlQuery query(db);
            QVERIFY(query.exec(
                "CREATE TABLE highlights (id TEXT PRIMARY KEY, source TEXT NOT NULL, sha256 TEXT NOT NULL, "
                "page INTEGER NOT NULL,text TEXT NOT NULL,rectangles TEXT NOT NULL,start_index INTEGER NOT NULL, "
                "end_index INTEGER NOT NULL,created_at TEXT NOT NULL,deleted_at TEXT)"));
            QVERIFY(query.exec(
                "INSERT INTO highlights VALUES('kept','file:///a.pdf','h',0,'old text','[]',0,8,'2026-01-01',NULL)"));
            db.close();
        }
        QSqlDatabase::removeDatabase("legacy");
        {
            ResearchStore store(directory.filePath("data"));
            QString error;
            QVERIFY2(store.initialize(&error), qPrintable(error));
            QCOMPARE(store.searchKnowledge("old text").size(), 1);
        }
        {
            auto db = QSqlDatabase::addDatabase("QSQLITE", "check");
            db.setDatabaseName(file);
            QVERIFY(db.open());
            QSqlQuery query(db);
            QVERIFY(query.exec("SELECT color,kind FROM highlights WHERE id='kept'") && query.next());
            QCOMPARE(query.value(0).toString(), ResearchStore::defaultAnnotationColor());
            QCOMPARE(query.value(1).toString(), QString("highlight"));
            QVERIFY(query.exec("PRAGMA user_version") && query.next());
            QVERIFY(query.value(0).toInt() >= 2);
            QVERIFY(query.exec("PRAGMA user_version=99"));
            db.close();
        }
        QSqlDatabase::removeDatabase("check");
        ResearchStore newer(directory.filePath("data"));
        QString error;
        QVERIFY(!newer.initialize(&error));
        QVERIFY(error.contains("newer Owelk"));
    }
    void captureRestorePersistsNotesImagesAndLinks()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("preserved.pdf");
        writeFixture(path);
        const auto source = QUrl::fromLocalFile(path);
        QString id, workspace, other;
        QImage pixels;
        {
            ResearchStore store(directory.filePath("data"));
            QString error;
            QVERIFY(store.initialize(&error));
            store.captureRegion(source, 2, QRectF(.1, .2, .4, .3));
            QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
            const auto capture = store.captures().first().toMap();
            id = capture["id"].toString();
            pixels.load(capture["image"].toUrl().toLocalFile());
            QVERIFY(!pixels.isNull());
            workspace = store.createWorkspace("Restore topic");
            other = store.createWorkspace("Other topic");
            QVERIFY(store.setWorkspaceCapture(workspace, id, true));
            QVERIFY(store.setWorkspaceCapture(other, id, true));
            QVERIFY(store.saveCaptureNote(id, "Restorable uniquequestion"));
            QVERIFY(store.deleteCapture(id));
            QCOMPARE(store.trashedCaptures().size(), 1);
            QVERIFY(store.workspaceDetails(workspace)["captures"].toList().isEmpty());
            QVERIFY(store.searchKnowledge("uniquequestion").isEmpty());
        }
        {
            ResearchStore store(directory.filePath("data"));
            QString error;
            QVERIFY(store.initialize(&error));
            QCOMPARE(store.trashedCaptures().size(), 1);
            const auto trash = store.trashedCaptures()[0].toMap();
            QCOMPARE(trash["id"].toString(), id);
            QVERIFY(!trash["deletedAt"].toString().isEmpty());
            QCOMPARE(QImage(trash["image"].toUrl().toLocalFile()), pixels);
            // Restoring evidence must not require or modify the original PDF.
            QVERIFY(QFile::rename(path, path + ".moved"));
            QVERIFY(store.restoreCapture(id));
            QVERIFY(!store.restoreCapture(id));
            QVERIFY(!store.restoreCapture("../../preserved.pdf"));
            QVERIFY(store.trashedCaptures().isEmpty());
            QCOMPARE(store.captures().size(), 1);
            const auto restored = store.captures()[0].toMap();
            QCOMPARE(restored["note"].toString(), "Restorable uniquequestion");
            QCOMPARE(QImage(restored["image"].toUrl().toLocalFile()), pixels);
            QVERIFY(!QFile::exists(trash["image"].toUrl().toLocalFile()));
            QCOMPARE(store.workspaceDetails(workspace)["captures"].toList().size(), 1);
            QCOMPARE(store.workspaceDetails(other)["captures"].toList().size(), 1);
            QCOMPARE(store.searchKnowledge("uniquequestion").size(), 1);
            QVERIFY(QFile::rename(path + ".moved", path));
            QSignalSpy ready(&store, &ResearchStore::sourceReady);
            store.openCapture(id);
            QTRY_COMPARE_WITH_TIMEOUT(ready.size(), 1, 10000);
            QCOMPARE(ready[0][0].toUrl(), source);
            QCOMPARE(ready[0][1].toInt(), 2);
            QCOMPARE(ready[0][2].toRectF(), QRectF(.1, .2, .4, .3));
        }
        ResearchStore reopened(directory.filePath("data"));
        QString error;
        QVERIFY(reopened.initialize(&error));
        QCOMPARE(reopened.captures().size(), 1);
        QVERIFY(reopened.trashedCaptures().isEmpty());
        QVERIFY(reopened.deleteCapture(id));
        QVERIFY(reopened.restoreCapture(id));
    }
    void captureRestoreFailureKeepsTrashAndNeverOverwrites()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("paper.pdf");
        writeFixture(path);
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        store.captureRegion(QUrl::fromLocalFile(path), 0, QRectF(.1, .1, .3, .2));
        QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
        const auto capture = store.captures().first().toMap();
        const auto id = capture["id"].toString(), original = capture["image"].toUrl().toLocalFile();
        QVERIFY(store.deleteCapture(id));
        const auto archived = store.trashedCaptures()[0].toMap()["image"].toUrl().toLocalFile();
        QVERIFY(QFile::rename(archived, archived + ".held"));
        QVERIFY(!store.restoreCapture(id));
        QVERIFY(store.captures().isEmpty());
        QVERIFY(QFile::rename(archived + ".held", archived));
        QFile collision(original);
        QVERIFY(collision.open(QIODevice::WriteOnly));
        collision.write("Do not overwrite");
        collision.close();
        QVERIFY(!store.restoreCapture(id));
        QVERIFY(collision.open(QIODevice::ReadOnly));
        QCOMPARE(collision.readAll(), QByteArray("Do not overwrite"));
        collision.close();
        QVERIFY(collision.remove());
        const QString connection = "restore-failure-check";
        {
            auto db = QSqlDatabase::addDatabase("QSQLITE", connection);
            db.setDatabaseName(directory.filePath("data/owelk.sqlite3"));
            QVERIFY(db.open());
            QSqlQuery query(db);
            QVERIFY(query.exec("CREATE TRIGGER reject_restore BEFORE DELETE ON deleted_captures BEGIN SELECT "
                               "RAISE(ABORT,'test failure'); END"));
            QVERIFY(!store.restoreCapture(id));
            QVERIFY(store.captures().isEmpty());
            QCOMPARE(store.trashedCaptures().size(), 1);
            QVERIFY(QFile::exists(archived));
            QVERIFY(!QFile::exists(original));
            QVERIFY(query.exec("DROP TRIGGER reject_restore"));
        }
        QSqlDatabase::removeDatabase(connection);
        QVERIFY(store.restoreCapture(id));
    }
    void workspaceLinksPersistWithoutDeletingSources()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("source.pdf");
        writeFixture(path);
        const auto source = QUrl::fromLocalFile(path);
        QString workspaceId, captureId;
        {
            ResearchStore store(directory.filePath("data"));
            QString error;
            QVERIFY(store.initialize(&error));
            workspaceId = store.createWorkspace("Topic links");
            const auto other = store.createWorkspace("Other topic");
            QVariantMap state{{"workspace", workspaceId}, {"workspaceName", "Topic links"},
                {"left", QVariantMap{{"source", source.toString()}, {"position", QVariantMap{{"page", 2}}}}}};
            QVERIFY(store.saveWorkspace(workspaceId, state));
            QVERIFY(store.saveSession(state));
            QCOMPARE(store.workspaceDetails(workspaceId)["documents"].toList().size(), 1);
            QVERIFY(store.setWorkspaceDocument(workspaceId, source, false));
            QVERIFY(store.saveWorkspace(workspaceId, state)); // Open tab autosave must respect explicit unlink.
            QVERIFY(store.workspaceDetails(workspaceId)["documents"].toList().isEmpty());
            QVERIFY(store.setWorkspaceDocument(workspaceId, source, true));
            QVERIFY(store.setWorkspaceDocument(workspaceId, source, true));
            QCOMPARE(store.workspaceDetails(workspaceId)["documents"].toList().size(), 1);
            store.captureRegion(source, 1, QRectF(.1, .1, .3, .2));
            QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
            captureId = store.captures()[0].toMap()["id"].toString();
            QVERIFY(store.saveCaptureNote(captureId, "Keep this note"));
            QVERIFY(store.setWorkspaceCapture(workspaceId, captureId, true));
            QVERIFY(store.setWorkspaceCapture(other, captureId, true));
            QVERIFY(store.setWorkspaceCapture(workspaceId, captureId, false));
            QCOMPARE(store.workspaceDetails(other)["captures"].toList().size(), 1);
            QCOMPARE(store.captures()[0].toMap()["note"].toString(), "Keep this note");
            QVERIFY(store.setWorkspaceCapture(workspaceId, captureId, true));
            QVERIFY(!store.setWorkspaceCapture(workspaceId, "missing", true));
            QVERIFY(!store.renameWorkspace(workspaceId, " "));
            QVERIFY(store.renameWorkspace(workspaceId, "Renamed topic"));
        }
        ResearchStore reopened(directory.filePath("data"));
        QString error;
        QVERIFY(reopened.initialize(&error));
        QCOMPARE(reopened.workspaceDetails(workspaceId)["name"].toString(), "Renamed topic");
        QCOMPARE(reopened.workspaceDetails(workspaceId)["captures"].toList().size(), 1);
        QCOMPARE(reopened.workspaceDetails(workspaceId)["documents"].toList().size(), 1);
        const auto before = reopened.loadWorkspace(workspaceId);
        QVERIFY(reopened.deleteWorkspace(workspaceId));
        QVERIFY(reopened.workspaceDetails(workspaceId).isEmpty());
        QVERIFY(reopened.loadWorkspace(workspaceId).isEmpty());
        QVERIFY(!reopened.saveWorkspace(workspaceId, before));
        QVERIFY(!reopened.renameWorkspace(workspaceId, "Do not resurrect"));
        QVERIFY(reopened.session()["workspace"].toString().isEmpty());
        QCOMPARE(reopened.session()["left"].toMap()["source"].toString(), source.toString());
        QCOMPARE(reopened.captures()[0].toMap()["note"].toString(), "Keep this note");
        QVERIFY(QFile::exists(path));
        QVERIFY(reopened.searchKnowledge("Renamed topic").isEmpty());
    }
    void removalPreservesOriginalAndCaptureTrash()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("keep.pdf");
        writeFixture(path);
        const auto source = QUrl::fromLocalFile(path);
        const auto originalSize = QFileInfo(path).size();
        QString captureId;
        {
            ResearchStore store(directory.filePath("data"));
            QString error;
            QVERIFY(store.initialize(&error));
            QVERIFY(store.rememberDocument(source));
            store.captureRegion(source, 0, QRectF(.1, .1, .4, .2));
            QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
            QCOMPARE(store.captures().size(), 1);
            captureId = store.captures().first().toMap()["id"].toString();
            QVERIFY(store.removeRecentDocument(source));
            QVERIFY(store.recentDocuments().isEmpty());
            QCOMPARE(store.captures().size(), 1);
            QVERIFY(store.deleteCapture(captureId));
            QVERIFY(!store.deleteCapture(captureId));
            QVERIFY(!store.deleteCapture("../../keep.pdf"));
            QVERIFY(store.captures().isEmpty());
            // Removing a recent entry does not remove the PDF from the text index.
            QVERIFY(store.searchKnowledge("keep", QUrl(), "captures").isEmpty());
            QVERIFY(!QFileInfo::exists(directory.filePath("data/captures/" + captureId + ".png")));
            QVERIFY(QFileInfo::exists(directory.filePath("data/captures/trash/" + captureId + ".png")));
            QCOMPARE(QFileInfo(path).size(), originalSize);
        }
        ResearchStore reopened(directory.filePath("data"));
        QString error;
        QVERIFY(reopened.initialize(&error));
        QVERIFY(reopened.captures().isEmpty());
        QVERIFY(reopened.recentDocuments().isEmpty());
        QVERIFY(QFileInfo::exists(path));
    }
    void tabSessionsAndWorkspacesPersist()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.path());
        QString error;
        QVERIFY(store.initialize(&error));
        const auto source = QUrl::fromLocalFile(directory.filePath("paper.pdf"));
        const QVariantMap first{{"id", "t1"}, {"source", source.toString()}, {"position", QVariantMap{{"page", 2}}}};
        const QVariantMap second{{"id", "t2"}, {"source", source.toString()}, {"position", QVariantMap{{"page", 6}}}};
        const QVariantMap group{
            {"kind", "group"}, {"id", "g1"}, {"activeTab", "t1"}, {"tabs", QVariantList{first, second}}};
        const QVariantMap state{{"version", 2}, {"tree", group}, {"activeGroup", "g1"}};
        QVERIFY(store.saveSession(state));
        QCOMPARE(store.readingPosition(source)["page"].toInt(), 2);
        QCOMPARE(store.continueReading()["id"].toString(), "t1");
        const auto id = store.createWorkspace("Tabs");
        QVERIFY(store.saveWorkspace(id, state));
        QCOMPARE(store.loadWorkspace(id)["tree"].toMap()["tabs"].toList().size(), 2);
        QCOMPARE(store.recentWorkspaces()[0].toMap()["papers"].toInt(), 1);
    }
    void activePaneOwnsRecentPosition()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.path());
        QString error;
        QVERIFY(store.initialize(&error));
        const auto source = QUrl::fromLocalFile(directory.filePath("paper.pdf"));
        QVariantMap state{{"left", QVariantMap{{"source", source.toString()}, {"position", QVariantMap{{"page", 2}}}}},
            {"right", QVariantMap{{"source", source.toString()}, {"position", QVariantMap{{"page", 5}}}}},
            {"split", true}, {"active", 0}};
        QVERIFY(store.saveSession(state));
        QCOMPARE(store.readingPosition(source)["page"].toInt(), 2);
        state["active"] = 1;
        QVERIFY(store.saveSession(state));
        QCOMPARE(store.readingPosition(source)["page"].toInt(), 5);
        QCOMPARE(store.continueReading()["position"].toMap()["page"].toInt(), 5);
        QVERIFY(!store.saveWorkspace("missing", state));
        QVERIFY(store.saveSession(state)); // A failed workspace write must not leave a transaction open.
    }
    void homeDataAndWorkspacesSurviveRestart()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("Alpha Paper.pdf");
        writeFixture(path);
        const auto source = QUrl::fromLocalFile(path);
        QString id;
        {
            ResearchStore store(directory.filePath("data"));
            QString error;
            QVERIFY(store.initialize(&error));
            QVERIFY(store.rememberDocument(source));
            id = store.createWorkspace("Alpha study");
            QVERIFY(!id.isEmpty());
            QVERIFY(store.createWorkspace("  ").isEmpty());
            const QVariantMap position{{"page", 3}, {"y", .2}, {"zoom", 1.4}};
            const QVariantMap state{{"left", QVariantMap{{"source", source.toString()}, {"position", position}}},
                {"workspace", id}, {"active", 0}};
            QVERIFY(store.saveSession(state));
            QVERIFY(store.saveWorkspace(id, state));
            QCOMPARE(store.continueReading().value("position").toMap().value("page").toInt(), 3);
            QCOMPARE(store.readingPosition(source), position);
            const auto results = store.searchKnowledge("ALPHA");
            QCOMPARE(results.size(), 2);
            QCOMPARE(results[0].toMap()["kind"].toString(), "paper");
            QCOMPARE(results[1].toMap()["kind"].toString(), "workspace");
            QVERIFY(store.searchKnowledge("' OR 1=1 --").isEmpty());
            QVERIFY(store.searchKnowledge("").isEmpty());
        }
        ResearchStore reopened(directory.filePath("data"));
        QString error;
        QVERIFY(reopened.initialize(&error));
        QCOMPARE(reopened.recentWorkspaces().size(), 1);
        QCOMPARE(reopened.recentWorkspaces()[0].toMap()["papers"].toInt(), 1);
        const auto workspace = reopened.loadWorkspace(id);
        QCOMPARE(workspace["workspaceName"].toString(), "Alpha study");
        QCOMPARE(workspace["left"].toMap()["position"].toMap()["page"].toInt(), 3);
    }
    void selectionUsesLineRectangles()
    {
        SelectionGeometry geometry;
        const auto glyph = [](qreal x, qreal y, qreal w = 5, qreal h = 10) { return QPolygonF(QRectF(x, y, w, h)); };
        const auto joined = geometry.lineRectangles({glyph(10, 10), glyph(17, 11, 5, 9), glyph(28, 10)});
        QCOMPARE(joined.size(), 1);
        const auto rect = joined.first().toRectF();
        QCOMPARE(rect.x(), 10);
        QCOMPARE(rect.width(), 23);
        QVERIFY(qAbs(rect.top() - 8.2) < .001);
        QVERIFY(qAbs(rect.bottom() - 21.8) < .001);
        const auto separate = geometry.lineRectangles({glyph(10, 10), glyph(17, 10), glyph(200, 10), glyph(10, 30)});
        QCOMPARE(separate.size(), 3);
        const auto closeLines = geometry.lineRectangles({glyph(10, 10), glyph(10, 21)});
        QCOMPARE(closeLines.size(), 2);
        QVERIFY(closeLines[0].toRectF().bottom() <= closeLines[1].toRectF().top());
        QVERIFY(geometry.lineRectangles({}).isEmpty());
        QVERIFY(geometry.lineRectangles({QPolygonF()}).isEmpty());
    }
    void selectionHeightDoesNotFollowSelectedGlyphs()
    {
        SelectionGeometry geometry;
        const QPolygonF small(QRectF(10, 13, 5, 6));
        const QPolygonF capital(QRectF(17, 10, 5, 9));
        const QPolygonF descender(QRectF(24, 13, 5, 9));
        const auto lines = geometry.lineRectangles({small, capital, descender});
        QCOMPARE(lines.size(), 1);
        const auto a = geometry.stableRectangles({small}, lines).first().toRectF();
        const auto ag = geometry.stableRectangles({small, capital, descender}, lines).first().toRectF();
        QCOMPARE(a.top(), ag.top());
        QCOMPARE(a.bottom(), ag.bottom());
        QVERIFY(a.top() < 10);
        QVERIFY(a.bottom() > 22);
        QCOMPARE(a.width(), 5);
    }
    void sessionSurvivesRestart()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        const QVariantMap expected{{"left",
                                       QVariantMap{{"source", "file:///paper.pdf"},
                                           {"position", QVariantMap{{"page", 4}, {"y", .38}, {"zoom", 1.2}}}}},
            {"split", true}};
        {
            ResearchStore store(directory.path());
            QString error;
            QVERIFY2(store.initialize(&error), qPrintable(error));
            QVERIFY(store.saveSession(expected));
        }
        ResearchStore reopened(directory.path());
        QString error;
        QVERIFY(reopened.initialize(&error));
        QCOMPARE(reopened.session().value("left").toMap().value("position").toMap().value("y").toDouble(), .38);
        QCOMPARE(reopened.session().value("left").toMap().value("position").toMap().value("page").toInt(), 4);
    }

    void captureKeepsPixelsAndVerifiesSource()
    {
        QTemporaryDir directory;
        const QString path = directory.filePath("paper with spaces.pdf");
        writeFixture(path);
        QPdfDocument pdf;
        QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
        QCOMPARE(pdf.pageCount(), 8);
        QVERIFY(pdf.getAllText(3).text().contains("occlusion"));

        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        const QUrl source = QUrl::fromLocalFile(path);
        QVERIFY(store.rememberDocument(source));
        QVERIFY(store.rememberDocument(source));
        QCOMPARE(store.recentDocuments().size(), 1);
        QSignalSpy saved(&store, &ResearchStore::captureSaved);
        QSignalSpy ready(&store, &ResearchStore::sourceReady);
        QSignalSpy messages(&store, &ResearchStore::message);
        store.captureRegion(source, 3, QRectF(.1, .5, .75, .25));
        QVERIFY(store.busy());
        QTRY_COMPARE_WITH_TIMEOUT(saved.size(), 1, 15000);
        QVERIFY(!store.busy());
        QCOMPARE(store.captures().size(), 1);
        const auto capture = store.captures().first().toMap();
        const auto found = store.searchKnowledge("paper with spaces");
        QCOMPARE(found.size(), 2);
        QCOMPARE(found[1].toMap()["kind"].toString(), "capture");
        QCOMPARE(found[1].toMap()["id"].toString(), capture["id"].toString());
        const QImage image(capture.value("image").toUrl().toLocalFile());
        QVERIFY(!image.isNull());
        QVERIFY(image.width() > 800);
        QVERIFY(image.height() > 350);
        store.openCapture(capture.value("id").toString());
        QTRY_COMPARE_WITH_TIMEOUT(ready.size(), 1, 10000);
        QCOMPARE(ready.first()[1].toInt(), 3);
        QCOMPARE(ready.first()[2].toRectF(), QRectF(.1, .5, .75, .25));

        pdf.close();
        QFile changed(path);
        QVERIFY(changed.open(QIODevice::Append));
        changed.write("\n% changed after capture\n");
        changed.close();
        messages.clear();
        store.openCapture(capture.value("id").toString());
        QTRY_VERIFY_WITH_TIMEOUT(!messages.isEmpty(), 10000);
        QCOMPARE(ready.size(), 1);
        QVERIFY(messages.last()[0].toString().contains("changed"));
        QVERIFY(QFileInfo::exists(capture.value("image").toUrl().toLocalFile()));

        ResearchStore reopened(directory.filePath("data"));
        QVERIFY(reopened.initialize(&error));
        QCOMPARE(reopened.captures().size(), 1);
    }

    void invalidCaptureDoesNotCreateEvidence()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.path());
        QString error;
        QVERIFY(store.initialize(&error));
        QSignalSpy messages(&store, &ResearchStore::message);
        store.captureRegion(QUrl("https://example.com/paper.pdf"), 0, QRectF(0, 0, 1, 1));
        QCOMPARE(messages.size(), 1);
        QVERIFY(!store.busy());
        store.captureRegion(QUrl::fromLocalFile(directory.filePath("missing.pdf")), 0, QRectF(0, 0, 1, 1));
        QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
        QCOMPARE(store.captures().size(), 0);
        QCOMPARE(messages.size(), 2);
    }
    void folderListingIsReadOnlyAndScoped()
    {
        QTemporaryDir directory;
        QVERIFY(QDir(directory.path()).mkdir("Papers"));
        writeFixture(directory.filePath("sample.PDF"));
        QFile other(directory.filePath("notes.txt"));
        QVERIFY(other.open(QIODevice::WriteOnly));
        other.write("preserved");
        other.close();
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        QSignalSpy listed(&store, &ResearchStore::folderLoaded);
        const int id = store.listFolder(QUrl::fromLocalFile(directory.path()));
        QTRY_COMPARE_WITH_TIMEOUT(listed.size(), 1, 10000);
        QCOMPARE(listed.first()[0].toInt(), id);
        QVERIFY(listed.first()[3].toString().isEmpty());
        const auto rows = listed.first()[2].toList();
        bool foundPdf = false, foundFolder = false;
        for (const auto &value : rows) {
            const auto row = value.toMap();
            QVERIFY(row["name"].toString() != "notes.txt");
            if (row["name"].toString() == "sample.PDF") foundPdf = true;
            if (row["name"].toString() == "Papers") foundFolder = true;
        }
        QVERIFY(foundPdf && foundFolder);
        QVERIFY(other.open(QIODevice::ReadOnly));
        QCOMPARE(other.readAll(), QByteArray("preserved"));
        store.listFolder(QUrl("https://example.com"));
        QTRY_COMPARE_WITH_TIMEOUT(listed.size(), 2, 10000);
        QVERIFY(!listed.last()[3].toString().isEmpty());
    }
};
QTEST_MAIN(ResearchStoreTest)
#include "ResearchStoreTest.moc"
