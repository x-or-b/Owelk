#include "LibrarySync.h"
#include "PdfFixture.h"
#include "ResearchStore.h"
#include "StoreFixture.h"
#include "WorkerConnection.h"
#include <QDirIterator>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPdfDocument>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QTemporaryDir>
#include <QtTest>

// The iPad app (ios/) takes part in folder sync with its own Swift code. These files keep the two from drifting
// apart; the iPad's XCTest reads and writes the same ones (ios/OwelkTests/ConformanceTests.swift):
//
//   tests/data/sync/mac/Owelk/       a sync folder written by this code (OWELK_WRITE_SYNC_FIXTURE=1 writes it anew)
//   tests/data/sync/mac/expected.json what that library holds, for the iPad's tests to compare with
//   tests/data/sync/ipad/<id>/       change files written by the iPad app's code (its tests write them anew)
//   tests/data/sync/ipad/Papers/     the PDF the iPad adds there
namespace {
const QString fixture = QStringLiteral(TEST_SOURCE_DIR "/data/sync");
// The iPad's device ID and clock in its conformance test (2030-01-01), so its files are always the same.
const QString ipadDevice = QStringLiteral("0a11ce00-0000-4000-8000-000000000001");

bool copyFolder(const QString &from, const QString &to)
{
    if (!QDir().mkpath(to)) return false;
    QDirIterator files(from, QDir::Files | QDir::Hidden, QDirIterator::Subdirectories);
    while (files.hasNext()) {
        const auto path = files.next();
        const auto target = to + "/" + QDir(from).relativeFilePath(path);
        if (!QDir().mkpath(QFileInfo(target).absolutePath()) || !QFile::copy(path, target)) return false;
    }
    return true;
}

QVariantList rows(const ResearchStore &store, const QString &sql)
{
    WorkerConnection db(store.dataDirectory() + "/owelk.sqlite3", true);
    QSqlQuery query(db.db);
    QVariantList result;
    if (!query.exec(sql)) return result;
    while (query.next()) {
        QVariantMap row;
        for (int i = 0; i < query.record().count(); ++i) row.insert(query.record().fieldName(i), query.value(i));
        result << row;
    }
    return result;
}

QVariant scalar(const ResearchStore &store, const QString &sql)
{
    const auto list = rows(store, sql);
    return list.isEmpty() ? QVariant() : list[0].toMap().values().value(0);
}

QJsonObject readObject(const QString &path)
{
    QFile file(path);
    return file.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(file.readAll()).object() : QJsonObject();
}

// Saves an annotation and waits for it; its id.
QString annotation(ResearchStore &store, const QUrl &source, int page, QVariantMap input)
{
    QSignalSpy loaded(&store, &ResearchStore::highlightsLoaded), done(&store, &ResearchStore::annotationFinished);
    store.loadHighlights(source);
    if (!loaded.wait(10000)) return {};
    input.insert("sha256", loaded.last()[4]);
    store.saveAnnotation(source, page, input);
    if (!done.wait(10000) || !done.last()[0].toBool()) return {};
    return done.last()[1].toString();
}

QVariantMap box(double x, double y, double width, double height)
{
    return {{"x", x}, {"y", y}, {"width", width}, {"height", height}};
}
}

class SyncConformanceTest : public QObject {
    Q_OBJECT
private slots:
    // A library with every kind of row the iPad reads, synced into a folder that becomes the fixture.
    void regenerateFixture()
    {
        if (qEnvironmentVariableIsEmpty("OWELK_WRITE_SYNC_FIXTURE")) QSKIP("Set OWELK_WRITE_SYNC_FIXTURE=1 to write it anew.");
        QTemporaryDir directory;
        const auto path = directory.filePath("Small Rooms.pdf");
        writeFixture(path, "Occlusion in Small Rooms", 3);
        const auto source = QUrl::fromLocalFile(path);
        QString error;
        ResearchStore mac(directory.filePath("mac"));
        QVERIFY2(mac.initialize(&error), qPrintable(error));
        QVERIFY(mac.rememberDocument(source));
        QTRY_VERIFY_WITH_TIMEOUT(!scalar(mac, "SELECT sha256 FROM documents").toString().isEmpty(), 10000);
        QVERIFY(mac.updateDocumentDetails(
            source, {{"title", "Occlusion in Small Rooms"}, {"authors", "Ada Park, Min Lee"}, {"year", "2025"}}));
        QVERIFY(mac.setReadingState(source, "reading"));
        const auto robots = mac.createCollection("Robots");
        const auto mapping = mac.createCollection("Mapping", robots);
        QVERIFY(mac.setDocumentCollection(source, mapping, true));
        QVERIFY(mac.setDocumentTags(source, {"radar", "to read"}));

        // A highlight over two lines with a note, then one of each page mark.
        QPdfDocument pdf;
        QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
        const auto bounds
            = pdf.getSelectionAtIndex(0, pdf.getAllText(0).text().indexOf("Research finding"), 45).boundingRectangle();
        const QPointF from(bounds.left(), bounds.center().y()), to(bounds.right(), bounds.center().y() + 20);
        QSignalSpy saved(&mac, &ResearchStore::highlightSaved);
        mac.highlightText(source, 0, from, to, pdf.getSelection(0, from, to).text(), "#e0b83f");
        QVERIFY(saved.wait(10000));
        QVERIFY(mac.updateHighlight(saved[0][0].toString(), "#e0b83f", "The key claim"));
        QVERIFY(!annotation(mac, source, 0, {{"kind", "comment"}, {"body", "Ask about this figure"},
                                                {"rectangles", QVariantList{box(.06, .56, .3, .2)}}})
                     .isEmpty());
        QVERIFY(!annotation(mac, source, 1, {{"kind", "text"}, {"body", "Check the drift term"}, {"fontSize", 12},
                                                {"rectangles", QVariantList{box(.1, .1, .4, .06)}}})
                     .isEmpty());
        QVERIFY(!markRegion(mac, source, 1, {.06, .55, .86, .22}).isEmpty());
        QVariantList stroke;
        for (int i = 0; i <= 8; ++i) stroke << QVariantMap{{"x", .2 + i * .05}, {"y", .4 + (i % 2) * .02}};
        QVERIFY(!annotation(mac, source, 1, {{"kind", "draw"}, {"color", "#d87797"}, {"drawing", stroke},
                                                {"rectangles", QVariantList{box(.2, .4, .4, .02)}}})
                     .isEmpty());
        QImage picture(40, 30, QImage::Format_ARGB32);
        picture.fill(QColor("#54a878"));
        const auto picturePath = directory.filePath("picture.png");
        QVERIFY(picture.save(picturePath));
        QVERIFY(!annotation(mac, source, 2, {{"kind", "image"}, {"imageSource", QUrl::fromLocalFile(picturePath).toString()},
                                                {"rectangles", QVariantList{box(.6, .1, .2, .15)}}})
                     .isEmpty());

        // Where the paper was left, as the reader saves it.
        const QVariantMap tab{{"id", "t1"}, {"source", source.toString()},
            {"position", QVariantMap{{"page", 1}, {"y", .25}, {"x", 0}, {"zoom", 1}, {"fit", "width"}}}};
        QVERIFY(mac.saveSession({{"version", 2}, {"activeGroup", "g1"},
            {"tree", QVariantMap{{"kind", "group"}, {"id", "g1"}, {"activeTab", "t1"}, {"tabs", QVariantList{tab}}}}}));

        const auto drive = directory.filePath("Drive");
        QVERIFY(QDir().mkpath(drive));
        QCOMPARE(mac.librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
        QVERIFY2(mac.librarySync()->syncBlocking().error.isEmpty(), qPrintable(mac.librarySync()->status()));

        // What the iPad should find: the rows as this computer holds them.
        QJsonObject expected;
        for (const auto &table : {"documents", "collections", "tags", "highlights", "reading_positions", "recent_documents"})
            expected.insert(table, QJsonArray::fromVariantList(rows(mac, QStringLiteral("SELECT * FROM %1").arg(table))));
        const auto target = fixture + "/mac";
        QDir(target).removeRecursively();
        QVERIFY(copyFolder(drive + "/Owelk", target + "/Owelk"));
        // The computer's own name stays out of the repository.
        for (const auto &about : QDir(target + "/Owelk/devices").entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
            QFile file(target + "/Owelk/devices/" + about + "/device.json");
            QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
            file.write(QJsonDocument(QJsonObject{{"name", "Mac"}, {"system", "macOS"}}).toJson());
        }
        QFile out(target + "/expected.json");
        QVERIFY(out.open(QIODevice::WriteOnly | QIODevice::Truncate));
        out.write(QJsonDocument(expected).toJson());
    }

    // The committed folder still reads here: Qt changes that would leave older logs (and the iPad) behind show up.
    void fixtureStillReads()
    {
        QTemporaryDir directory;
        const auto drive = directory.filePath("Drive");
        QVERIFY(copyFolder(fixture + "/mac/Owelk", drive + "/Owelk"));
        const auto expected = readObject(fixture + "/mac/expected.json");
        QString error;
        ResearchStore ubuntu(directory.filePath("ubuntu"));
        QVERIFY2(ubuntu.initialize(&error), qPrintable(error));
        QCOMPARE(ubuntu.librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
        const auto outcome = ubuntu.librarySync()->syncBlocking();
        QVERIFY2(outcome.error.isEmpty(), qPrintable(outcome.error));
        QCOMPARE(outcome.waiting, 0);
        QCOMPARE(outcome.skipped, 0);
        const auto paper = expected["documents"].toArray()[0].toObject();
        QCOMPARE(scalar(ubuntu, "SELECT id FROM documents").toString(), paper["id"].toString());
        QCOMPARE(scalar(ubuntu, "SELECT title FROM documents").toString(), paper["title"].toString());
        QCOMPARE(scalar(ubuntu, "SELECT count(*) FROM highlights WHERE deleted_at IS NULL").toInt(),
            expected["highlights"].toArray().size());
        QCOMPARE(scalar(ubuntu, "SELECT count(*) FROM collections").toInt(), expected["collections"].toArray().size());
        QCOMPARE(scalar(ubuntu, "SELECT count(*) FROM tags").toInt(), expected["tags"].toArray().size());
        QCOMPARE(scalar(ubuntu, "SELECT position FROM reading_positions").toString(),
            expected["reading_positions"].toArray()[0].toObject()["position"].toString());
        QCOMPARE(ubuntu.librarySync()->computers(), QStringList{"Mac"});
    }

    // Change files the iPad wrote reach the library here: its reading position and when it opened the paper.
    void readsTheIpadsChanges()
    {
        QTemporaryDir directory;
        const auto drive = directory.filePath("Drive");
        QVERIFY(copyFolder(fixture + "/mac/Owelk", drive + "/Owelk"));
        QVERIFY2(QFileInfo::exists(fixture + "/ipad/" + ipadDevice + "/00000001.jsonl"),
            "Run the iPad app's tests with OWELK_WRITE_FIXTURES=1 (see ios/README.md).");
        QVERIFY(copyFolder(fixture + "/ipad/" + ipadDevice, drive + "/Owelk/devices/" + ipadDevice));
        QVERIFY(copyFolder(fixture + "/ipad/Papers", drive + "/Owelk/Papers"));
        QString error;
        ResearchStore mac(directory.filePath("mac"));
        QVERIFY2(mac.initialize(&error), qPrintable(error));
        QCOMPARE(mac.librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
        const auto outcome = mac.librarySync()->syncBlocking();
        QVERIFY2(outcome.error.isEmpty(), qPrintable(outcome.error));
        QCOMPARE(outcome.skipped, 0);
        const auto paper
            = QUrl(scalar(mac, "SELECT url FROM documents WHERE id='ec0dbb6f-06b8-4012-b0b2-eb317af23825'").toString());
        QVERIFY(paper.isLocalFile());
        const auto position = mac.readingPosition(paper);
        QCOMPARE(position["page"].toInt(), 2);
        QCOMPARE(position["y"].toDouble(), .5);
        // The rest of the position is the Mac's own, as it left it.
        QCOMPARE(position["fit"].toString(), QString("width"));
        QCOMPARE(position["zoom"].toDouble(), 1.0);
        QCOMPARE(scalar(mac, "SELECT opened_at FROM recent_documents").toString(), QString("2030-01-01T00:00:00.000Z"));
        QCOMPARE(mac.recentDocuments().value(0).toMap()["url"].toUrl(), paper);
        QVERIFY(mac.librarySync()->computers().contains("iPad"));

        // A pen stroke drawn with Apple Pencil: a pen mark of this paper's PDF, as one drawn here would be. The Mac's
        // own pen mark, erased on the iPad, is erased here too.
        const auto stroke = rows(mac,
            "SELECT document_id,sha256,page,kind,color,drawing,rectangles,start_index,deleted_at FROM highlights WHERE "
            "id='0a11ce00-0000-4000-8000-00000000b001'");
        QCOMPARE(stroke.size(), 1);
        const auto pen = stroke[0].toMap();
        QCOMPARE(pen["document_id"].toString(), QString("ec0dbb6f-06b8-4012-b0b2-eb317af23825"));
        QCOMPARE(pen["sha256"].toString(),
            scalar(mac, "SELECT sha256 FROM documents WHERE id='ec0dbb6f-06b8-4012-b0b2-eb317af23825'").toString());
        QCOMPARE(pen["page"].toInt(), 1);
        QCOMPARE(pen["kind"].toString(), QString("draw"));
        QCOMPARE(pen["color"].toString(), QString("#54a878"));
        QCOMPARE(pen["start_index"].toInt(), -1);
        QVERIFY(pen["deleted_at"].isNull());
        const auto points = QJsonDocument::fromJson(pen["drawing"].toByteArray()).array();
        QCOMPARE(points.size(), 3);
        QCOMPARE(points[1].toObject()["x"].toDouble(), .2);
        QCOMPARE(points[1].toObject()["y"].toDouble(), .15);
        QCOMPARE(QJsonDocument::fromJson(pen["rectangles"].toByteArray()).array().size(), 1);
        QVERIFY(!scalar(mac, "SELECT deleted_at FROM highlights WHERE id='4c08b2b3-27fd-40fe-9175-8f82166b1ed0'")
                     .toString()
                     .isEmpty());

        // A highlight and a comment made on the text on the iPad, as ones made here would be: the text, a rectangle
        // per line and the character range. The Mac's own highlight has the color and note the iPad gave it.
        const auto marked = rows(mac,
            "SELECT id,document_id,sha256,page,kind,color,text,body,rectangles,start_index,end_index,deleted_at FROM "
            "highlights WHERE id IN ('0a11ce00-0000-4000-8000-00000000c001','0a11ce00-0000-4000-8000-00000000c002') "
            "ORDER BY id");
        QCOMPARE(marked.size(), 2);
        const auto highlight = marked[0].toMap(), comment = marked[1].toMap();
        QCOMPARE(highlight["document_id"].toString(), QString("ec0dbb6f-06b8-4012-b0b2-eb317af23825"));
        QCOMPARE(highlight["sha256"].toString(), pen["sha256"].toString());
        QCOMPARE(highlight["page"].toInt(), 0);
        QCOMPARE(highlight["kind"].toString(), QString("highlight"));
        QCOMPARE(highlight["color"].toString(), QString("#e0b83f"));
        QCOMPARE(highlight["text"].toString(), QString("Words the iPad marked"));
        QCOMPARE(highlight["start_index"].toInt(), 10);
        QCOMPARE(highlight["end_index"].toInt(), 31);
        QVERIFY(highlight["deleted_at"].isNull());
        const auto lines = QJsonDocument::fromJson(highlight["rectangles"].toByteArray()).array();
        QCOMPARE(lines.size(), 2);
        QCOMPARE(lines[1].toObject()["y"].toDouble(), .325);
        QCOMPARE(lines[1].toObject()["width"].toDouble(), .3);
        QCOMPARE(comment["kind"].toString(), QString("comment"));
        QCOMPARE(comment["page"].toInt(), 1);
        QCOMPARE(comment["body"].toString(), QString("Why this bound?"));
        QCOMPARE(comment["text"].toString(), QString("The bound"));
        const auto edited
            = rows(mac, "SELECT color,body,text FROM highlights WHERE id='1474cf62-bae3-4649-ac90-d077a1513e14'");
        QCOMPARE(edited.size(), 1);
        QCOMPARE(edited[0].toMap()["color"].toString(), QString("#54a878"));
        QCOMPARE(edited[0].toMap()["body"].toString(), QString("Checked on the iPad"));
        QVERIFY(edited[0].toMap()["text"].toString().startsWith("Research finding 1.1"));

        // The paper filed on the iPad: a favorite, read, out of "to read", in a new tag and a new collection.
        const auto filed
            = rows(mac, "SELECT favorite,reading_state FROM documents WHERE id='ec0dbb6f-06b8-4012-b0b2-eb317af23825'");
        QCOMPARE(filed[0].toMap()["favorite"].toInt(), 1);
        QCOMPARE(filed[0].toMap()["reading_state"].toString(), QString("read"));
        const auto tags = rows(mac,
            "SELECT t.name FROM document_tags m JOIN tags t ON t.id=m.tag_id WHERE "
            "m.document_id='ec0dbb6f-06b8-4012-b0b2-eb317af23825' ORDER BY t.name");
        QCOMPARE(tags.size(), 2);
        QCOMPARE(tags[0].toMap()["name"].toString(), QString("from iPad"));
        QCOMPARE(tags[1].toMap()["name"].toString(), QString("radar"));
        QCOMPARE(scalar(mac,
                     "SELECT c.name FROM collection_documents m JOIN collections c ON c.id=m.collection_id WHERE "
                     "m.document_id='ec0dbb6f-06b8-4012-b0b2-eb317af23825' AND c.parent_id IS NULL")
                     .toString(),
            QString("Reading list"));

        // A note written on the iPad about the paper: its text, and the link its text makes, as one made here.
        const auto note = rows(mac,
            "SELECT title,body,deleted_at FROM notes WHERE id='0a11ce00-0000-4000-8000-00000000a004'");
        QCOMPARE(note.size(), 1);
        QCOMPARE(note[0].toMap()["title"].toString(), QString("From the iPad"));
        QVERIFY(note[0].toMap()["body"].toString().endsWith("The walls echo."));
        QVERIFY(note[0].toMap()["deleted_at"].isNull());
        QCOMPARE(mac.note("0a11ce00-0000-4000-8000-00000000a004")["title"].toString(), QString("From the iPad"));
        QCOMPARE(scalar(mac,
                     "SELECT count(*) FROM links WHERE from_kind='note' AND "
                     "from_id='0a11ce00-0000-4000-8000-00000000a004' AND to_kind='document' AND "
                     "to_id='ec0dbb6f-06b8-4012-b0b2-eb317af23825'")
                     .toInt(),
            1);

        // The paper added on the iPad: in the Library under its file's name, with the PDF copied in, in the
        // collection and tag it was added to, and its details left for this computer to read.
        const auto added = rows(mac,
            "SELECT url,title,sha256,kind,reading_state,metadata_origin,removed_at FROM documents WHERE "
            "id='0a11ce00-0000-4000-8000-00000000a001'");
        QCOMPARE(added.size(), 1);
        const auto row = added[0].toMap();
        const auto sha = QStringLiteral("e549b32af3d995d3d7d8b61f5c7b8f3af29ca1df65a1618884a400c14a19a263");
        QCOMPARE(row["title"].toString(), QString("Echoes in Long Halls"));
        QCOMPARE(row["sha256"].toString(), sha);
        QCOMPARE(row["kind"].toString(), QString("pdf"));
        QCOMPARE(row["reading_state"].toString(), QString("unread"));
        QCOMPARE(row["metadata_origin"].toString(), QString());
        QVERIFY(row["removed_at"].isNull());
        const auto file = QUrl(row["url"].toString()).toLocalFile();
        QCOMPARE(QFileInfo(file).fileName(), QString("Long Halls.pdf"));
        QVERIFY2(file.startsWith(mac.dataDirectory()), qPrintable(file));
        QFile copy(file), original(fixture + "/ipad/Papers/" + sha + ".pdf");
        QVERIFY(copy.open(QIODevice::ReadOnly) && original.open(QIODevice::ReadOnly));
        QCOMPARE(copy.readAll(), original.readAll());
        QCOMPARE(scalar(mac,
                     "SELECT c.name FROM collection_documents m JOIN collections c ON c.id=m.collection_id WHERE "
                     "m.document_id='0a11ce00-0000-4000-8000-00000000a001'")
                     .toString(),
            QString("Mapping"));
        QCOMPARE(scalar(mac,
                     "SELECT t.name FROM document_tags m JOIN tags t ON t.id=m.tag_id WHERE "
                     "m.document_id='0a11ce00-0000-4000-8000-00000000a001'")
                     .toString(),
            QString("radar"));
    }
};

QTEST_MAIN(SyncConformanceTest)
#include "SyncConformanceTest.moc"
