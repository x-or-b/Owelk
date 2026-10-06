#include "ResearchStore.h"
#include "PaperIndex.h"
#include "SelectionGeometry.h"
#include "PdfFixture.h"
#include "PaperMetadata.h"
#include "MetadataLookup.h"
#include <QTcpServer>
#include <QTcpSocket>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QPainter>
#include <QPdfDocument>
#include <QPdfWriter>
#include <QPdfSelection>
#include <QSignalSpy>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include "PdfAccess.h"
#include <QUuid>
#include <QtTest>

class ResearchStoreTest : public QObject {
    Q_OBJECT
private slots:
    void bundledIconFontAndShaders()
    {
        // The icon font and, when built with Qt ShaderTools, the dark-pages shader are compiled in.
        QFile font(":/owelk/icons/lucide.ttf");
        QVERIFY(font.open(QIODevice::ReadOnly));
        QVERIFY(font.size() > 10000 && font.size() < 100000);
#ifdef OWELK_HAVE_SHADERS
        QFile shader(":/owelk/shaders/invert.frag.qsb");
        QVERIFY(shader.open(QIODevice::ReadOnly));
        QVERIFY(shader.size() > 100);
#endif
    }
    void regionCaptureKeepsFigureCaption()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("figure.pdf");
        {
            QPdfWriter writer(path);
            writer.setResolution(72);
            writer.setPageSize(QPageSize(QPageSize::A4));
            QPainter painter(&writer);
            painter.setFont(QFont("Helvetica", 10));
            painter.drawText(QPointF(60, 80), "Body text above the figure.");
            painter.drawRect(QRectF(100, 120, 300, 200)); // The figure.
            painter.drawText(QPointF(100, 340), "Figure 2: Occlusion examples from the kitchen scene,");
            painter.drawText(QPointF(100, 353), "shown before and after aggregation.");
            painter.drawText(QPointF(60, 420), "Unrelated paragraph that is not part of the caption.");
        }
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        const auto size = QPageSize(QPageSize::A4).sizePoints();
        store.captureRegion(QUrl::fromLocalFile(path), 0,
            QRectF(95. / size.width(), 115. / size.height(), 310. / size.width(), 210. / size.height()));
        QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
        QCOMPARE(store.captures().size(), 1);
        const auto caption = store.captures()[0].toMap()["caption"].toString();
        QVERIFY2(caption.startsWith("Figure 2: Occlusion examples"), qPrintable(caption));
        QVERIFY2(caption.contains("after aggregation"), qPrintable(caption));
        QVERIFY(!caption.contains("Unrelated"));
        QCOMPARE(store.searchKnowledge("kitchen scene").value(0).toMap()["kind"].toString(), QString("capture"));
    }
    void deletedWorkspaceCanBeRestored()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        const auto id = store.createWorkspace("Hidden topic");
        QVERIFY(store.deleteWorkspace(id));
        QVERIFY(store.recentWorkspaces().isEmpty());
        QCOMPARE(store.deletedWorkspaces().size(), 1);
        QVERIFY(store.restoreWorkspace(id));
        QCOMPARE(store.recentWorkspaces().size(), 1);
        QVERIFY(store.deletedWorkspaces().isEmpty());
        QVERIFY(!store.restoreWorkspace(id));
        QVERIFY(!store.loadWorkspace(id).isEmpty());
    }
    void notesLinksBacklinksAndTrash()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("linked.pdf");
        writeFixture(path, "Linked Paper");
        const auto source = QUrl::fromLocalFile(path);
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QVERIFY(store.rememberDocument(source));
        // The title is read from the PDF in the background.
        QTRY_COMPARE_WITH_TIMEOUT(store.displayName(source), QString("Linked Paper"), 10000);
        store.captureRegion(source, 1, QRectF(.1, .1, .3, .2));
        QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
        const auto capture = store.captures()[0].toMap()["id"].toString();
        const auto paper = store.documentLinkId(source);
        // A note body links with owelk:// URLs; saving keeps the link table in sync.
        const auto ideas = store.createNote("Ideas", "See " + store.markdownLink("document", paper));
        QVERIFY(!ideas.isEmpty());
        QVERIFY(store.markdownLink("document", paper).contains("Linked Paper"));
        QCOMPARE(store.backlinks("document", paper).size(), 1);
        const auto other = store.createNote("Other", "");
        QVERIFY(store.appendNoteLink(other, "capture", capture));
        QVERIFY(store.appendNoteLink(other, "capture", capture)); // Idempotent.
        QCOMPARE(store.note(other)["body"].toString().count("owelk://capture/"), 1);
        // A paper's backlinks include notes that link to its captures.
        QCOMPARE(store.backlinks("document", paper).size(), 2);
        QCOMPARE(store.backlinks("capture", capture)[0].toMap()["id"].toString(), other);
        QVERIFY(store.saveNote(ideas, "Ideas", "no links now"));
        QCOMPARE(store.backlinks("document", paper).size(), 1);
        // Search, link candidates and trash.
        QCOMPARE(store.searchKnowledge("no links now").value(0).toMap()["kind"].toString(), QString("standalone-note"));
        QVERIFY(std::any_of(store.linkCandidates("Linked").cbegin(), store.linkCandidates("Linked").cend(),
            [](const QVariant &r) { return r.toMap()["kind"] == "document"; }));
        QVERIFY(!store.purgeNote(other)); // Only trashed notes can be purged.
        QVERIFY(store.deleteNote(other));
        QVERIFY(store.backlinks("document", paper).isEmpty()); // Trashed notes are not shown as backlinks.
        QCOMPARE(store.notes(true).size(), 1);
        QVERIFY(!store.saveNote(other, "x", "y"));
        QVERIFY(store.restoreNote(other));
        QCOMPARE(store.backlinks("document", paper).size(), 1);
        QVERIFY(store.deleteNote(other));
        QVERIFY(store.purgeNote(other));
        QVERIFY(store.note(other).isEmpty());
        QVERIFY(store.backlinks("capture", capture).isEmpty());
        QVERIFY(!store.addLink("note", ideas, "note", ideas)); // No self links.
    }
    void libraryCollectionsTagsFiltersAndExclusion()
    {
        QTemporaryDir directory;
        QList<QUrl> papers;
        const QStringList titles{"Gaussian Splatting Study", "Occlusion Reasoning", "Semantic Mapping Survey"};
        for (int i = 0; i < 3; ++i) {
            const auto path = directory.filePath(QString("paper%1.pdf").arg(i));
            writeFixture(path, titles[i]);
            papers << QUrl::fromLocalFile(path);
        }
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        for (const auto &paper : papers) QVERIFY(store.rememberDocument(paper));
        QTRY_COMPARE_WITH_TIMEOUT(store.displayName(papers[2]), titles[2], 10000);
        QCOMPARE(store.libraryDocuments().size(), 3);
        // Collections nest; a parent shows its sub-collections' papers. Deleting keeps the papers.
        const auto robotics = store.createCollection("Robotics"), slam = store.createCollection("SLAM", robotics);
        QVERIFY(!robotics.isEmpty() && !slam.isEmpty());
        QVERIFY(store.createCollection("Orphan", "missing-parent").isEmpty());
        QVERIFY(store.setDocumentCollection(papers[0], slam, true));
        QVERIFY(store.setDocumentCollection(papers[1], robotics, true));
        QCOMPARE(store.libraryDocuments({{"collection", robotics}}).size(), 2);
        QCOMPARE(store.libraryDocuments({{"collection", slam}}).size(), 1);
        QCOMPARE(store.collections()[1].toMap()["depth"].toInt(), 1);
        QVERIFY(store.renameCollection(slam, "Visual SLAM"));
        // Tags: case-insensitive, unused ones vanish.
        QVERIFY(store.setDocumentTags(papers[0], {"to read", "SLAM", "slam"}));
        QVERIFY(store.setDocumentTags(papers[2], {"To Read"}));
        QCOMPARE(store.tags().size(), 2);
        const auto toRead = store.tags()[1].toMap();
        QCOMPARE(toRead["name"].toString(), QString("to read"));
        QCOMPARE(store.libraryDocuments({{"tag", toRead["id"]}}).size(), 2);
        QVERIFY(store.setDocumentTags(papers[0], {}));
        QCOMPARE(store.tags().size(), 1);
        // State, favorite, text and year filters; sorting by title.
        QVERIFY(store.setReadingState(papers[1], "read"));
        QVERIFY(store.setFavorite(papers[2], true));
        QCOMPARE(store.libraryDocuments({{"state", "read"}}).size(), 1);
        QCOMPARE(store.libraryDocuments({{"favorite", true}}).size(), 1);
        QCOMPARE(store.libraryDocuments({{"text", "occlusion"}}).size(), 1);
        QVERIFY(store.updateDocumentDetails(papers[0], {{"title", titles[0]}, {"year", "2023"}}));
        QCOMPARE(store.libraryDocuments({{"yearFrom", 2020}, {"yearTo", 2024}}).size(), 1);
        QCOMPARE(store.libraryDocuments({{"sort", "title"}})[0].toMap()["name"].toString(), titles[0]);
        // Search finds collections and tags, and library scope limits saved-item search.
        QVERIFY(std::any_of(store.searchKnowledge("visual").cbegin(), store.searchKnowledge("visual").cend(),
            [](const QVariant &r) { return r.toMap()["kind"] == "collection"; }));
        const QVariantList scope{papers[1]};
        QCOMPARE(store.searchKnowledge("study", {}, "filename", scope).size(), 0);
        QCOMPARE(store.searchKnowledge("study", {}, "filename").size(), 1);
        QVERIFY(store.deleteCollection(robotics));
        QCOMPARE(store.collections().size(), 1); // The sub-collection moved up.
        QCOMPARE(store.libraryDocuments({{"collection", slam}}).size(), 1);
        // Excluding a paper removes its pages from text search; including it indexes it again.
        auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 20000);
        QSignalSpy found(index, &PaperIndex::searchFinished);
        const auto search = [&] {
            found.clear();
            index->searchGrouped("occlusion", {}, 0);
            return found.wait(5000) ? found[0][1].toList() : QVariantList();
        };
        QVERIFY(!search().isEmpty());
        QVERIFY(store.setExcludedFromIndex(papers[0], true));
        QVERIFY(store.setExcludedFromIndex(papers[1], true));
        QVERIFY(store.setExcludedFromIndex(papers[2], true));
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 10000);
        QVERIFY(search().isEmpty());
        QVERIFY(store.rememberDocument(papers[0])); // Opening an excluded paper does not re-index it.
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 10000);
        QVERIFY(search().isEmpty());
        QVERIFY(store.setExcludedFromIndex(papers[0], false));
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 20000);
        QVERIFY(!search().isEmpty());
        // A collection/tag scope restricts PDF text search to its papers.
        found.clear();
        index->searchGrouped("occlusion", {}, 0, QStringList{});
        QVERIFY(found.wait(5000));
        QVERIFY(found[0][1].toList().isEmpty());
    }
    void readingStateFavoriteAndDuplicates()
    {
        QTemporaryDir directory;
        const auto original = directory.filePath("original.pdf"), copy = directory.filePath("copy.pdf");
        writeFixture(original, "Duplicate Paper");
        QVERIFY(QFile::copy(original, copy));
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QSignalSpy duplicates(&store, &ResearchStore::duplicateFound);
        const auto first = QUrl::fromLocalFile(original), second = QUrl::fromLocalFile(copy);
        QVERIFY(store.rememberDocument(first));
        QCOMPARE(store.documentDetails(first)["readingState"].toString(), QString("reading"));
        QVERIFY(store.setReadingState(first, "read"));
        QVERIFY(store.rememberDocument(first)); // Reopening does not demote a finished paper.
        QCOMPARE(store.documentDetails(first)["readingState"].toString(), QString("read"));
        QVERIFY(!store.setReadingState(first, "skimmed"));
        QVERIFY(store.setFavorite(first, true));
        QTRY_VERIFY_WITH_TIMEOUT(store.recentDocuments().value(0).toMap()["favorite"].toBool(), 5000);
        QTest::qWait(200);
        QVERIFY(duplicates.isEmpty()); // The only copy is not its own duplicate.
        QVERIFY(store.rememberDocument(second));
        QTRY_COMPARE_WITH_TIMEOUT(duplicates.size(), 1, 10000);
        QCOMPARE(duplicates[0][0].toUrl(), second);
        QCOMPARE(duplicates[0][1].toUrl(), first);
        QVERIFY(store.keepDuplicate(second));
        QVERIFY(store.rememberDocument(second));
        QTest::qWait(500);
        QCOMPARE(duplicates.size(), 1); // "Keep both" stops asking for this file version.
        QVERIFY(store.useExistingCopy(second, first));
        QCOMPARE(store.recentDocuments().size(), 1);
        QCOMPARE(store.recentDocuments()[0].toMap()["url"].toUrl(), first);
        QVERIFY(QFileInfo::exists(copy)); // Files are never touched.
    }
    void trashPurgeRemovesOnlyTrashedCaptures()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("purge.pdf");
        writeFixture(path);
        const auto source = QUrl::fromLocalFile(path);
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        for (int i = 0; i < 3; ++i) {
            store.captureRegion(source, i, QRectF(.1, .1, .3, .2));
            QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
        }
        QCOMPARE(store.captures().size(), 3);
        const auto kept = store.captures()[0].toMap()["id"].toString();
        const auto first = store.captures()[1].toMap()["id"].toString();
        const auto second = store.captures()[2].toMap()["id"].toString();
        const auto workspace = store.createWorkspace("Purge topic");
        QVERIFY(store.setWorkspaceCapture(workspace, first, true));
        QVERIFY(store.saveCaptureNote(first, "purged note words"));
        QVERIFY(!store.purgeCapture(kept)); // A saved capture is never deleted permanently.
        QVERIFY(store.deleteCapture(first));
        QVERIFY(store.deleteCapture(second));
        const auto trashImage = directory.filePath("data/captures/trash/" + first + ".png");
        QVERIFY(QFileInfo::exists(trashImage));
        QVERIFY(store.purgeCapture(first));
        QVERIFY(!QFileInfo::exists(trashImage));
        QCOMPARE(store.trashedCaptures().size(), 1);
        QVERIFY(store.workspaceDetails(workspace)["captures"].toList().isEmpty());
        QVERIFY(!store.restoreCapture(first));
        QCOMPARE(store.emptyCaptureTrash(), 1);
        QVERIFY(store.trashedCaptures().isEmpty());
        QVERIFY(!QFileInfo::exists(directory.filePath("data/captures/trash/" + second + ".png")));
        QCOMPARE(store.captures().size(), 1);
        QCOMPARE(store.captures()[0].toMap()["id"].toString(), kept);
        QVERIFY(QFileInfo(store.captures()[0].toMap()["image"].toUrl().toLocalFile()).isFile());
        QVERIFY(QFileInfo::exists(path));
        QCOMPARE(store.emptyCaptureTrash(), 0);
    }
    void onlineLookupParsesArxivAndCrossref()
    {
        // A local stand-in for arXiv and Crossref: answers by path and records what was asked.
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        QStringList requests;
        connect(&server, &QTcpServer::newConnection, &server, [&] {
            auto *socket = server.nextPendingConnection();
            connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                const auto head = QString::fromUtf8(socket->readAll()).section("\r\n", 0, 0);
                requests.append(head);
                QByteArray body;
                if (head.contains("/arxiv"))
                    body = "<?xml version='1.0'?><feed xmlns='http://www.w3.org/2005/Atom'><title>query</title><entry>"
                           "<id>http://arxiv.org/abs/2305.01234v2</id><published>2023-05-02T00:00:00Z</published>"
                           "<title>Online\n  Title</title><author><name>Ada Lovelace</name></author>"
                           "<author><name>Alan Turing</name></author></entry></feed>";
                else if (head.contains("query.bibliographic"))
                    body
                        = R"({"message":{"items":[{"title":["Found By Title"],"DOI":"10.1/xyz","issued":{"date-parts":[[2021]]}}]}})";
                else
                    body
                        = R"({"message":{"title":["Crossref Work"],"DOI":"10.1145/3592433","author":[{"given":"Grace","family":"Hopper"}],"published-print":{"date-parts":[[2024,5]]}}})";
                socket->write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: "
                    + QByteArray::number(body.size()) + "\r\n\r\n" + body);
                socket->disconnectFromHost();
            });
        });
        MetadataLookup lookup;
        const auto base = QStringLiteral("http://127.0.0.1:%1").arg(server.serverPort());
        lookup.arxivBase = QUrl(base + "/arxiv");
        lookup.crossrefBase = QUrl(base + "/works");
        QSignalSpy done(&lookup, &MetadataLookup::lookupFinished);
        lookup.lookup({{"arxiv", "2305.01234"}, {"doi", "10.1/ignored"}});
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 5000);
        auto found = done[0][1].toMap();
        QVERIFY2(done[0][2].toString().isEmpty(), qPrintable(done[0][2].toString()));
        QCOMPARE(found["title"].toString(), QString("Online Title"));
        QCOMPARE(found["authors"].toString(), QString("Ada Lovelace, Alan Turing"));
        QCOMPARE(found["year"].toString(), QString("2023"));
        QCOMPARE(found["source"].toString(), QString("arXiv"));
        lookup.lookup({{"doi", "10.1145/3592433"}});
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 2, 5000);
        found = done[1][1].toMap();
        QCOMPARE(found["title"].toString(), QString("Crossref Work"));
        QCOMPARE(found["authors"].toString(), QString("Grace Hopper"));
        QCOMPARE(found["year"].toString(), QString("2024"));
        QVERIFY(requests.last().contains("/works/10.1145/3592433"));
        lookup.lookup({{"title", "Something Found By Title"}});
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 3, 5000);
        QCOMPARE(done[2][1].toMap()["doi"].toString(), QString("10.1/xyz"));
        lookup.lookup({{"title", "short"}}); // Too little to search: no request is made.
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 4, 5000);
        QVERIFY(!done[3][2].toString().isEmpty());
        QCOMPARE(requests.size(), 3);
    }
    void firstPageTitleAndAuthorsFromLayout()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("layout.pdf");
        {
            QPdfWriter writer(path);
            writer.setResolution(72);
            writer.setPageSize(QPageSize(QPageSize::A4));
            QPainter painter(&writer);
            const auto line = [&](qreal y, int size, const QString &text, qreal x = 60) {
                painter.setFont(QFont("Helvetica", size));
                painter.drawText(QPointF(x, y), text);
            };
            line(24, 7, "Proceedings of the 41st International Conference on Testing, 2026");
            line(62, 24, "IEEE TRANSACTIONS ON ROBOTICS"); // Taller than the title, but a venue banner.
            line(120, 20, "Occlusion-Aware Semantic Mapping");
            line(146, 20, "with Open-Vocabulary Scene Graphs");
            line(184, 11, "Alice Smith1*, Bob Jones2 and Carol Wu1");
            line(200, 9, "1University of Testing, Korea   2Example Research Lab");
            line(216, 9, "alice@example.edu");
            line(250, 10, "Abstract");
            for (int i = 0; i < 30; ++i) {
                line(270 + i * 14, 10, "Body text of the left column number " + QString::number(i));
                line(270 + i * 14, 10, "Right column body text " + QString::number(i), 320);
            }
        }
        const auto metadata = extractPaperMetadata(path);
        QCOMPARE(metadata.title, QString("Occlusion-Aware Semantic Mapping with Open-Vocabulary Scene Graphs"));
        QCOMPARE(metadata.authors, QString("Alice Smith, Bob Jones, Carol Wu"));
        QCOMPARE(PaperMetadataText::authorNames({"J. R. R. Tolkien, Ludwig van Beethoven", "Department of Music"}),
            QStringList({"J. R. R. Tolkien", "Ludwig van Beethoven"}));
        QVERIFY(PaperMetadataText::authorNames({"Deep learning for all of us"}).isEmpty());
    }
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
            for (const auto *sql :
                {"DROP TABLE documents", "DROP TABLE recent_documents", "DROP TABLE reading_positions",
                    "DROP TABLE workspace_documents", "DROP TABLE workspace_document_exclusions", "DROP TABLE captures",
                    "DROP TABLE highlights", "DROP TABLE collections", "DROP TABLE collection_documents",
                    "DROP TABLE tags", "DROP TABLE document_tags", "DROP TABLE notes", "DROP TABLE ai_responses",
                    "DROP TABLE ai_messages", "DROP TABLE ai_threads", "DROP TABLE links",
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
    void searchRanksTitlesAndMatchesWordsInAnyOrder()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        // Saved items: all words, any order; a title hit outranks a body hit.
        const auto inBody = store.createNote("Reading log", "We saw mapping fail under heavy occlusion.");
        const auto inTitle = store.createNote("Occlusion mapping", "Notes for later.");
        QVERIFY(!inBody.isEmpty() && !inTitle.isEmpty());
        auto rows = store.searchKnowledge("mapping occlusion");
        QCOMPARE(rows.size(), 2);
        QCOMPARE(rows[0].toMap()["id"].toString(), inTitle);
        QCOMPARE(rows[1].toMap()["id"].toString(), inBody);
        QVERIFY(store.searchKnowledge("mapping lidar").isEmpty());
        // PDF text: two papers with the same pages; the one whose title has the words comes first.
        const auto a = QUrl::fromLocalFile(directory.filePath("a.pdf")),
                   b = QUrl::fromLocalFile(directory.filePath("b.pdf"));
        writeFixture(a.toLocalFile());
        writeFixture(b.toLocalFile());
        QVERIFY(store.rememberDocument(a));
        QVERIFY(store.rememberDocument(b));
        auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 20000);
        QSignalSpy found(index, &PaperIndex::searchFinished);
        const auto firstPaper = [&] {
            found.clear();
            index->searchGrouped("context observation", {}, 0);
            if (!found.wait(5000)) return QUrl();
            for (const auto &row : found[0][1].toList())
                if (row.toMap()["kind"] == "paperGroup") return row.toMap()["source"].toUrl();
            return QUrl();
        };
        QVERIFY(store.updateDocumentDetails(a, {{"title", "Context and Observation"}}));
        QCOMPARE(firstPaper(), a);
        store.resetDocumentDetails(a);
        // The reset re-reads the PDF's own title in the background.
        QTRY_VERIFY_WITH_TIMEOUT(store.documentDetails(a)["title"].toString() != "Context and Observation", 10000);
        QVERIFY(store.updateDocumentDetails(b, {{"title", "Observation in Context"}}));
        QCOMPARE(firstPaper(), b);
    }
    void relatedPapersAndNotesShareDistinctiveWords()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        const auto radar = QStringLiteral("Radar odometry fuses doppler velocity with inertial gravity estimates. ");
        const auto a = QUrl::fromLocalFile(directory.filePath("a.pdf")),
                   b = QUrl::fromLocalFile(directory.filePath("b.pdf")),
                   c = QUrl::fromLocalFile(directory.filePath("c.pdf"));
        writeTextFixture(a.toLocalFile(), {radar.repeated(6), "Doppler radar odometry under gravity drift."});
        writeTextFixture(
            b.toLocalFile(), {"We study doppler radar odometry and inertial velocity. " + radar.repeated(3)});
        writeTextFixture(
            c.toLocalFile(), {QStringLiteral("Semantic segmentation of indoor furniture scenes. ").repeated(8)});
        for (const auto &url : {a, b, c}) QVERIFY(store.rememberDocument(url));
        QTRY_VERIFY_WITH_TIMEOUT(!qobject_cast<PaperIndex *>(store.paperIndex())->busy(), 20000);
        const auto related = store.createNote("Odometry ideas", "Try doppler velocity for radar drift.");
        const auto unrelated = store.createNote("Furniture", "Chairs and tables in scenes.");
        QSignalSpy found(&store, &ResearchStore::relatedFound);
        const int request = store.relatedTo(a);
        QTRY_COMPARE_WITH_TIMEOUT(found.size(), 1, 10000);
        QCOMPARE(found[0][0].toInt(), request);
        const auto papers = found[0][1].toList();
        QVERIFY(!papers.isEmpty());
        QCOMPARE(papers[0].toMap()["source"].toUrl(), b);
        QVERIFY(std::none_of(
            papers.cbegin(), papers.cend(), [&](const QVariant &p) { return p.toMap()["source"].toUrl() == a; }));
        const auto notes = found[0][2].toList();
        QCOMPARE(notes.size(), 1);
        QCOMPARE(notes[0].toMap()["id"].toString(), related);
        // A note's related notes share its words; the note itself is never listed.
        const auto twin = store.createNote("Drift", "Radar doppler drift and velocity checks.");
        const auto close = store.relatedNotes(related);
        QCOMPARE(close.size(), 1);
        QCOMPARE(close[0].toMap()["id"].toString(), twin);
        QVERIFY(store.relatedNotes(unrelated).isEmpty());
    }
    void addRemoveAndRestoreLibraryPapers()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        const auto a = QUrl::fromLocalFile(directory.filePath("a.pdf")),
                   b = QUrl::fromLocalFile(directory.filePath("b.pdf"));
        writeFixture(a.toLocalFile(), "Paper A");
        writeFixture(b.toLocalFile(), "Paper B");
        QFile notes(directory.filePath("notes.txt"));
        QVERIFY(notes.open(QIODevice::WriteOnly));
        notes.write("x");
        notes.close();
        // Added straight into a collection, without opening (not "recent"); other files are skipped.
        const auto topic = store.createCollection("Imported");
        QCOMPARE(store.addDocuments({a, b, QUrl::fromLocalFile(directory.filePath("notes.txt"))}, topic), 2);
        QCOMPARE(store.libraryDocuments({{"collection", topic}}).size(), 2);
        QVERIFY(store.recentDocuments().isEmpty());
        // Removing hides the paper everywhere but keeps the file; opening it again restores it.
        QCOMPARE(store.removeFromLibrary({a}), 1);
        QCOMPARE(store.libraryDocuments({}).size(), 1);
        QCOMPARE(store.libraryDocuments({{"collection", topic}}).size(), 1);
        QVERIFY(QFile::exists(a.toLocalFile()));
        QVERIFY(store.rememberDocument(a));
        QTRY_COMPARE_WITH_TIMEOUT(store.libraryDocuments({}).size(), 2, 2000);
        // A file that is not there is not "moved to the Trash", and nothing changes.
        QCOMPARE(store.movePdfsToTrash({QUrl::fromLocalFile(directory.filePath("missing.pdf"))}), 0);
        QCOMPARE(store.libraryDocuments({}).size(), 2);
    }
    void importAFolderAsCollections()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        QDir root(directory.filePath("Papers"));
        QVERIFY(root.mkpath("SLAM/LiDAR") && root.mkpath(".hidden"));
        writeFixture(root.filePath("survey.pdf"), "Survey");
        writeFixture(root.filePath("SLAM/loop.pdf"), "Loop");
        writeFixture(root.filePath("SLAM/LiDAR/lio.pdf"), "LIO");
        writeFixture(root.filePath(".hidden/skip.pdf"), "Skip");
        QFile text(root.filePath("SLAM/readme.txt"));
        QVERIFY(text.open(QIODevice::WriteOnly));
        text.close();
        QSignalSpy done(&store, &ResearchStore::folderImported);
        const int request = store.importFolder(QUrl::fromLocalFile(root.absolutePath()), QString(), true);
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 10000);
        QCOMPARE(done[0][0].toInt(), request);
        QCOMPARE(done[0][1].toInt(), 3); // hidden folders and other files are skipped
        QCOMPARE(done[0][2].toInt(), 3); // Papers, Papers/SLAM, Papers/SLAM/LiDAR
        const auto byName = [&](const QString &name) {
            for (const auto &c : store.collections())
                if (c.toMap()["name"] == name) return c.toMap();
            return QVariantMap{};
        };
        QCOMPARE(byName("LiDAR")["parentId"], byName("SLAM")["id"]);
        QCOMPARE(byName("SLAM")["parentId"], byName("Papers")["id"]);
        QCOMPARE(store.libraryDocuments({{"collection", byName("Papers")["id"]}}).size(), 3); // incl. sub-collections
        QCOMPARE(store.libraryDocuments({{"collection", byName("LiDAR")["id"]}}).size(), 1);
        // Importing again reuses the same collections and adds nothing twice.
        store.importFolder(QUrl::fromLocalFile(root.absolutePath()), QString(), true);
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 2, 10000);
        QCOMPARE(done[1][2].toInt(), 0);
        QCOMPARE(store.libraryDocuments({}).size(), 3);
    }
    void deletedWorkspacesCanBeForgotten()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        const auto path = directory.filePath("paper.pdf");
        writeFixture(path);
        const auto source = QUrl::fromLocalFile(path);
        QVERIFY(store.rememberDocument(source));
        const auto keep = store.createWorkspace("Keep"), first = store.createWorkspace("Old A"),
                   second = store.createWorkspace("Old B");
        QVERIFY(store.setWorkspaceDocument(first, source, true));
        QVERIFY(store.deleteWorkspace(first));
        QVERIFY(store.deleteWorkspace(second));
        QCOMPARE(store.deletedWorkspaces().size(), 2);
        // One, then the rest; only deleted workspaces can be forgotten.
        QCOMPARE(store.purgeDeletedWorkspaces(first), 1);
        QCOMPARE(store.deletedWorkspaces().size(), 1);
        QVERIFY(!store.restoreWorkspace(first));
        QCOMPARE(store.purgeDeletedWorkspaces(keep), 0);
        QCOMPARE(store.purgeDeletedWorkspaces(), 1);
        QVERIFY(store.deletedWorkspaces().isEmpty());
        const auto recent = store.recentWorkspaces();
        QVERIFY(
            std::any_of(recent.cbegin(), recent.cend(), [&](const QVariant &w) { return w.toMap()["id"] == keep; }));
        // The paper itself stays in the library.
        QCOMPARE(store.libraryDocuments({}).size(), 1);
    }
    void unsortedPapersAndCollectionSuggestions()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        const auto radar = QStringLiteral("Radar odometry fuses doppler velocity with inertial gravity estimates. ");
        const auto a = QUrl::fromLocalFile(directory.filePath("a.pdf")),
                   b = QUrl::fromLocalFile(directory.filePath("b.pdf")),
                   c = QUrl::fromLocalFile(directory.filePath("c.pdf"));
        writeTextFixture(a.toLocalFile(), {radar.repeated(6), "Doppler radar odometry under gravity drift."});
        writeTextFixture(
            b.toLocalFile(), {"We study doppler radar odometry and inertial velocity. " + radar.repeated(3)});
        writeTextFixture(
            c.toLocalFile(), {QStringLiteral("Semantic segmentation of indoor furniture scenes. ").repeated(8)});
        for (const auto &url : {a, b, c}) QVERIFY(store.rememberDocument(url));
        QTRY_VERIFY_WITH_TIMEOUT(!qobject_cast<PaperIndex *>(store.paperIndex())->busy(), 20000);
        QCOMPARE(store.unsortedCount(), 3);
        // Several papers go into a collection at once.
        const auto odometry = store.createCollection("Odometry"), scenes = store.createCollection("Scenes");
        QVERIFY(store.setDocumentsCollection({b}, odometry, true));
        QVERIFY(store.setDocumentsCollection({c}, scenes, true));
        QCOMPARE(store.unsortedCount(), 1);
        const auto unsorted = store.libraryDocuments({{"unsorted", true}});
        QCOMPARE(unsorted.size(), 1);
        QCOMPARE(unsorted[0].toMap()["url"].toUrl(), a);
        // The radar paper is like the one in Odometry, not like the furniture one.
        QSignalSpy suggested(&store, &ResearchStore::collectionsSuggested);
        const int request = store.suggestCollections(a);
        QTRY_COMPARE_WITH_TIMEOUT(suggested.size(), 1, 10000);
        QCOMPARE(suggested[0][0].toInt(), request);
        const auto list = suggested[0][2].toList();
        QCOMPARE(list.size(), 1);
        QCOMPARE(list[0].toMap()["id"].toString(), odometry);
        QCOMPARE(list[0].toMap()["name"].toString(), QString("Odometry"));
        // Once filed there, it is no longer suggested (and no longer unsorted).
        QVERIFY(store.setDocumentsCollection({a}, odometry, true));
        QTRY_COMPARE_WITH_TIMEOUT(store.unsortedCount(), 0, 2000);
        store.suggestCollections(a);
        QTRY_COMPARE_WITH_TIMEOUT(suggested.size(), 2, 10000);
        QVERIFY(suggested[1][2].toList().isEmpty());
        QVERIFY(store.setDocumentsCollection({a, b}, odometry, false));
        QCOMPARE(store.unsortedCount(), 2);
    }
    void lockedPdfsWorkOnceTheReaderGivesThePassword()
    {
        qputenv("OWELK_KEYCHAIN_SERVICE",
            ("org.owelk.tests." + QUuid::createUuid().toString(QUuid::WithoutBraces)).toUtf8());
        QTemporaryDir directory;
        const auto path = directory.filePath("locked.pdf");
        QVERIFY(QFile::copy(QStringLiteral(TEST_DATA_DIR) + "/locked.pdf", path));
        const auto source = QUrl::fromLocalFile(path);
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
        QVERIFY(store.rememberDocument(source));
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 20000);
        const auto state = [&] {
            for (const auto &row : index->documents())
                if (row.toMap()["source"].toUrl() == source) return row.toMap()["state"].toString();
            return QString();
        };
        QCOMPARE(state(), QString("locked"));
        QPdfDocument pdf;
        QCOMPARE(PdfAccess::load(pdf, path), QPdfDocument::Error::IncorrectPassword);
        // The viewer reports the password that opened it: indexing retries and finds the text.
        store.rememberPdfPassword(source, "owelk", false);
        QTRY_COMPARE_WITH_TIMEOUT(state(), QString("ready"), 20000);
        QSignalSpy found(index, &PaperIndex::searchFinished);
        index->search("research finding");
        QVERIFY(found.wait(5000));
        QVERIFY(!found[0][1].toList().isEmpty());
        QPdfDocument reopened;
        QCOMPARE(PdfAccess::load(reopened, path), QPdfDocument::Error::None);
        // Background work such as captures can open it too.
        QSignalSpy saved(&store, &ResearchStore::captureSaved);
        store.captureRegion(source, 0, QRectF(.1, .1, .3, .2));
        QTRY_COMPARE_WITH_TIMEOUT(saved.size(), 1, 10000);
        // Remembered in the keyring: a new session finds it there.
        PdfAccess::remember(path, "owelk", true, store.dataDirectory());
        PdfAccess::forget(path);
        QCOMPARE(store.pdfPassword(source), QString());
        PdfAccess::remember(path, "owelk", true, store.dataDirectory());
        QCOMPARE(store.pdfPassword(source), QString("owelk"));
        PdfAccess::forget(path);
        qunsetenv("OWELK_KEYCHAIN_SERVICE");
    }
    void scannedPagesAreReadByOcrWhenTesseractIsInstalled()
    {
        QTemporaryDir directory;
        const auto scanned = QUrl::fromLocalFile(directory.filePath("scan.pdf"));
        // One page with text, two pages that are pictures only.
        writeTextFixture(scanned.toLocalFile(), {"A typed cover page.", "", ""});
        // Without Tesseract the picture pages stay unsearchable.
        qputenv("OWELK_TESSERACT", directory.filePath("missing-tesseract").toUtf8());
        {
            ResearchStore store(directory.filePath("plain"));
            QString error;
            QVERIFY(store.initialize(&error));
            QVERIFY(store.rememberDocument(scanned));
            auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
            QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 20000);
            QSignalSpy found(index, &PaperIndex::searchFinished);
            index->search("furniture");
            QVERIFY(found.wait(5000));
            QVERIFY(found[0][1].toList().isEmpty());
        }
        qputenv("OWELK_TESSERACT", QByteArray(TEST_SOURCE_DIR) + "/fake_tesseract.py");
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        QTRY_VERIFY_WITH_TIMEOUT(store.ocrStatus()["languages"].toString() == "eng+kor", 10000);
        QVERIFY(store.ocrStatus()["found"].toBool());
        QVERIFY(store.rememberDocument(scanned));
        auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy(), 30000);
        QSignalSpy found(index, &PaperIndex::searchFinished);
        index->searchGrouped("furniture", {}, 0);
        QVERIFY(found.wait(5000));
        int pages = 0;
        for (const auto &row : found[0][1].toList())
            if (row.toMap()["kind"] == "text") {
                QVERIFY(row.toMap()["ocr"].toBool());
                ++pages;
            }
        QCOMPARE(pages, 2);
        // Turned off: no further OCR, and the setting is kept.
        store.setOcr(false, {});
        QVERIFY(!store.ocrStatus()["enabled"].toBool());
        QVERIFY(!index->ocr().enabled());
        qunsetenv("OWELK_TESSERACT");
    }
    void backupRestoreCrashMarkerAndDrafts()
    {
        QTemporaryDir directory;
        const auto data = directory.filePath("data");
        const auto pdf = QUrl::fromLocalFile(directory.filePath("paper.pdf"));
        writeFixture(pdf.toLocalFile());
        QString backupPath, kept, later;
        {
            ResearchStore store(data);
            QString error;
            QVERIFY(store.initialize(&error));
            QVERIFY(!store.recoveredFromCrash());
            kept = store.createNote("Kept", "Written before the backup.");
            QSignalSpy captured(&store, &ResearchStore::captureSaved);
            store.captureRegion(pdf, 0, QRectF(.1, .1, .3, .2));
            QTRY_COMPARE_WITH_TIMEOUT(captured.size(), 1, 10000);
            QSignalSpy done(&store, &ResearchStore::backupFinished);
            store.backUp(directory.filePath("backups"));
            QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 10000);
            QVERIFY2(done[0][0].toBool(), qPrintable(done[0][2].toString()));
            backupPath = done[0][1].toString();
            QVERIFY(QFileInfo::exists(backupPath + "/owelk.sqlite3"));
            QVERIFY(QFileInfo::exists(backupPath + "/owelk-backup.json"));
            QCOMPARE(QDir(backupPath + "/captures").entryList({"*.png"}).size(), 1);
            QCOMPARE(store.checkBackup(backupPath), QString());
            QVERIFY(!store.checkBackup(directory.path()).isEmpty());
            // Changes after the backup are undone by restoring it (on the next start).
            later = store.createNote("Later", "Written after the backup.");
            QVERIFY(store.scheduleRestore(backupPath));
            // Drafts: kept until saved or discarded.
            QVERIFY(store.saveDraft("capture-note:x", "half a thought"));
            QCOMPARE(store.draft("capture-note:x"), QString("half a thought"));
            store.clearDraft("capture-note:x");
            QCOMPARE(store.draft("capture-note:x"), QString());
        }
        QVERIFY(!QFileInfo::exists(data + "/.running")); // A clean exit removes the marker.
        {
            ResearchStore store(data);
            QString error;
            QVERIFY(store.initialize(&error));
            QVERIFY(store.startupMessage().startsWith("Restored the backup"));
            QVERIFY(!store.note(kept).isEmpty());
            QVERIFY(store.note(later).isEmpty());
            QCOMPARE(store.captures().size(), 1);
            QVERIFY(QFileInfo(store.captures()[0].toMap()["image"].toUrl().toLocalFile()).exists());
            // The previous library was moved aside, not deleted.
            QCOMPARE(QDir(data + "/backups").entryList({"before-restore-*"}, QDir::Dirs).size(), 1);
        }
        // An unexpected exit leaves the marker; the next start notices.
        QFile marker(data + "/.running");
        QVERIFY(marker.open(QIODevice::WriteOnly));
        marker.close();
        ResearchStore store(data);
        QString error;
        QVERIFY(store.initialize(&error));
        QVERIFY(store.recoveredFromCrash());
    }
    void markdownAndBibtexExports()
    {
        QTemporaryDir directory;
        const auto a = QUrl::fromLocalFile(directory.filePath("a.pdf")),
                   b = QUrl::fromLocalFile(directory.filePath("b.pdf"));
        writeFixture(a.toLocalFile(), "Radar & Lidar Odometry");
        writeFixture(b.toLocalFile(), "Radar Mapping");
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        QVERIFY(store.rememberDocument(a));
        QVERIFY(store.rememberDocument(b));
        QVERIFY(store.updateDocumentDetails(a,
            {{"title", "Radar & Lidar Odometry"}, {"authors", "Ada Kim, Bo Lee"}, {"year", "2025"},
                {"doi", "10.1000/xyz_1"}}));
        QVERIFY(store.updateDocumentDetails(
            b, {{"title", "Radar Mapping"}, {"authors", "Ada Kim"}, {"year", "2025"}, {"arxiv", "2501.01234"}}));
        // Reading notes for paper A: a text box, a capture with a note, and a linked note.
        QSignalSpy loaded(&store, &ResearchStore::highlightsLoaded), done(&store, &ResearchStore::annotationFinished);
        store.loadHighlights(a);
        QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 1, 10000);
        store.saveAnnotation(a, 1,
            {{"kind", "text"}, {"body", "Check the drift term"}, {"color", "#d87797"}, {"sha256", loaded.last()[4]},
                {"rectangles", QVariantList{QVariantMap{{"x", .1}, {"y", .2}, {"width", .3}, {"height", .1}}}}});
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 10000);
        QSignalSpy captured(&store, &ResearchStore::captureSaved);
        store.captureRegion(a, 0, QRectF(.1, .1, .3, .2));
        QTRY_COMPARE_WITH_TIMEOUT(captured.size(), 1, 10000);
        QVERIFY(store.saveCaptureNote(captured[0][0].toString(), "Figure shows drift"));
        const auto note = store.createNote(
            "Odometry plan", "Compare with " + store.markdownLink("document", store.documentLinkId(a)));
        const auto out = directory.filePath("export");
        const auto path = store.exportPaperMarkdown(a, out);
        QVERIFY(QFileInfo::exists(path));
        QFile file(path);
        QVERIFY(file.open(QIODevice::ReadOnly));
        const auto markdown = QString::fromUtf8(file.readAll());
        QVERIFY(markdown.startsWith("# Radar & Lidar Odometry"));
        QVERIFY(markdown.contains("Ada Kim, Bo Lee · 2025 · DOI 10.1000/xyz_1"));
        QVERIFY(markdown.contains("- p. 2 · text box"));
        QVERIFY(markdown.contains("> Check the drift term"));
        QVERIFY(markdown.contains("Note: Figure shows drift"));
        QVERIFY(markdown.contains("![p. 1](Radar%20&%20Lidar%20Odometry%20images/"));
        QCOMPARE(QDir(out + "/Radar & Lidar Odometry images").entryList({"*.png"}).size(), 1);
        QVERIFY(markdown.contains("- Odometry plan"));
        // Exporting again never overwrites.
        QVERIFY(store.exportPaperMarkdown(a, out).endsWith("Radar & Lidar Odometry 2.md"));
        // Every note as a file; Owelk-only links become their text.
        QCOMPARE(store.exportNotesMarkdown(directory.filePath("notes")), 1);
        QFile exported(directory.filePath("notes/Odometry plan.md"));
        QVERIFY(exported.open(QIODevice::ReadOnly));
        const auto noteText = QString::fromUtf8(exported.readAll());
        QVERIFY(noteText.startsWith("# Odometry plan"));
        QVERIFY(!noteText.contains("owelk://"));
        QVERIFY(!note.isEmpty());
        // BibTeX: escaped, "and"-joined authors, unique keys, DOI as article, arXiv as preprint.
        const auto bib = store.bibtex({a.toString(), b.toString(), b.toString()});
        QVERIFY(bib.contains("@article{kim2025radar,"));
        QVERIFY(bib.contains("title = {Radar \\& Lidar Odometry}"));
        QVERIFY(bib.contains("author = {Ada Kim and Bo Lee}"));
        QVERIFY(bib.contains("doi = {10.1000/xyz\\_1}"));
        QVERIFY(bib.contains("@misc{kim2025radara,"));
        QVERIFY(bib.contains("eprint = {2501.01234}"));
        QVERIFY(bib.contains("@misc{kim2025radarb,"));
        QVERIFY(store.exportBibTeX({a.toString()}, directory.filePath("refs.bib")));
        QVERIFY(QFileInfo(directory.filePath("refs.bib")).size() > 50);
    }
    void capturesAndAnnotationsShareOneAnchor()
    {
        QTemporaryDir directory;
        const auto source = QUrl::fromLocalFile(directory.filePath("paper.pdf"));
        writeFixture(source.toLocalFile());
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        QSignalSpy captured(&store, &ResearchStore::captureSaved);
        store.captureRegion(source, 2, QRectF(.1, .2, .3, .1));
        QTRY_COMPARE_WITH_TIMEOUT(captured.size(), 1, 10000);
        const auto anchor = store.anchor("capture", captured[0][0].toString());
        QCOMPARE(anchor["kind"].toString(), QString("pdf"));
        QCOMPARE(anchor["documentId"].toString(), store.documentLinkId(source));
        QCOMPARE(anchor["page"].toInt(), 2);
        QCOMPARE(anchor["source"].toUrl(), source);
        QVERIFY(qAbs(anchor["bounds"].toMap()["y"].toDouble() - .2) < 1e-6);
        QVERIFY(!anchor["sha256"].toString().isEmpty());
        QVERIFY(store.anchor("capture", "missing").isEmpty());
        QVERIFY(store.anchor("note", "x").isEmpty());
        // Opening goes through the same path: verify, then reveal.
        QSignalSpy ready(&store, &ResearchStore::sourceReady);
        store.openCapture(captured[0][0].toString());
        QTRY_COMPARE_WITH_TIMEOUT(ready.size(), 1, 10000);
        QCOMPARE(ready[0][0].toUrl(), source);
        QCOMPARE(ready[0][1].toInt(), 2);
        // A changed file is not revealed; the item is kept.
        writeFixture(source.toLocalFile(), "Changed", 4);
        QSignalSpy messages(&store, &ResearchStore::message);
        store.revealAnchor(anchor);
        QTRY_VERIFY_WITH_TIMEOUT(!messages.isEmpty(), 10000);
        QVERIFY(messages.last()[0].toString().contains("changed"));
        QCOMPARE(ready.size(), 1);
    }
    void pathsUseThePlatformForm()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        const auto path = directory.filePath("a folder/paper.pdf");
        const auto url = store.fileUrl(QDir::toNativeSeparators(path));
        QCOMPARE(url, QUrl::fromLocalFile(path));
        QCOMPARE(store.localPath(url), QDir::toNativeSeparators(path));
        QCOMPARE(store.localPath(QUrl("https://arxiv.org/abs/1")), QString("https://arxiv.org/abs/1"));
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
    void marginStampDoesNotMergeLines()
    {
        // arXiv prints its identifier rotated in the left margin: one glyph box spanning most of the page.
        SelectionGeometry geometry;
        QList<QPolygonF> page{QPolygonF(QRectF(11, 213, 7, 519))};
        for (int row = 0; row < 20; ++row)
            for (qreal x : {54.0, 320.0}) page.append(QPolygonF(QRectF(x, 220 + row * 10, 240, 8)));
        const auto lines = geometry.lineRectangles(page);
        QCOMPARE(lines.size(), 41);
        int tall = 0;
        for (const auto &line : lines) tall += line.toRectF().height() > 20;
        QCOMPARE(tall, 1);
        // A selection inside one column keeps its own line height.
        const auto selected = geometry.stableRectangles({QPolygonF(QRectF(166, 220, 45, 8))}, lines);
        QCOMPARE(selected.size(), 1);
        QVERIFY(selected.first().toRectF().height() < 12);
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
