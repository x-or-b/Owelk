#include "ResearchStore.h"
#include "PdfFixture.h"
#include "PdfPrinting.h"
#include <QPdfDocument>
#include <QPdfSelection>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>
#include <limits>

class TextCaptureTest : public QObject
{
    Q_OBJECT
private slots:
    void annotationColorsCommentsImagesAndDrawing() {
        QTemporaryDir dir;const auto path=dir.filePath("annotated.pdf");writeFixture(path);
        ResearchStore store(dir.filePath("data"));QString error;QVERIFY(store.initialize(&error));
        const auto source=QUrl::fromLocalFile(path);
        QSignalSpy loaded(&store,&ResearchStore::highlightsLoaded),done(&store,&ResearchStore::annotationFinished);
        store.loadHighlights(source);QTRY_COMPARE_WITH_TIMEOUT(loaded.size(),1,10000);
        const auto hash=loaded.last()[4].toString();QVERIFY(!hash.isEmpty());
        const QVariantList rects{QVariantMap{{"x",.1},{"y",.2},{"width",.3},{"height",.1}}};
        QVariantMap mark{{"kind","text"},{"body","Visible annotation"},{"color","#d87797"},{"sha256",hash},{"rectangles",rects}};
        store.saveAnnotation(source,0,mark);QTRY_COMPARE_WITH_TIMEOUT(done.size(),1,10000);QVERIFY(done.last()[0].toBool());
        const auto textId=done.last()[1].toString();
        mark["id"]=textId;mark["body"]="Edited annotation";
        store.saveAnnotation(source,0,mark);QTRY_COMPARE_WITH_TIMEOUT(done.size(),2,10000);QVERIFY(done.last()[0].toBool());
        QCOMPARE(store.searchKnowledge("Edited annotation").size(),1);
        mark.remove("id");mark["kind"]="image";mark["body"]="";
        QImage image(40,30,QImage::Format_RGB32);image.fill(Qt::red);QVERIFY(image.save(dir.filePath("image.png")));
        mark["imageSource"]=QUrl::fromLocalFile(dir.filePath("image.png")).toString();
        store.saveAnnotation(source,0,mark);QTRY_COMPARE_WITH_TIMEOUT(done.size(),3,10000);QVERIFY(done.last()[0].toBool());
        mark["kind"]="draw";mark.remove("imageSource");mark["drawing"]=QVariantList{QVariantMap{{"x",.1},{"y",.2}},QVariantMap{{"x",.4},{"y",.3}}};
        store.saveAnnotation(source,0,mark);QTRY_COMPARE_WITH_TIMEOUT(done.size(),4,10000);QVERIFY(done.last()[0].toBool());
        QPdfDocument pdf;QCOMPARE(pdf.load(path),QPdfDocument::Error::None);
        const auto bounds=pdf.getSelectionAtIndex(0,pdf.getAllText(0).text().indexOf("Research finding"),45).boundingRectangle();
        const QPointF from(bounds.left(),bounds.center().y()),to(bounds.right(),bounds.center().y());
        const auto quote=pdf.getSelection(0,from,to).text();
        store.commentText(source,0,from,to,quote,"Comment on a sentence","#9274c3");QTRY_COMPARE_WITH_TIMEOUT(done.size(),5,10000);QVERIFY(done.last()[0].toBool());
        store.loadHighlights(source);QTRY_COMPARE_WITH_TIMEOUT(loaded.size(),2,10000);
        const auto rows=loaded.last()[2].toList();QCOMPARE(rows.size(),4);
        bool copied=false,comment=false;
        for(const auto &r:rows){const auto m=r.toMap();if(m["kind"]=="image"){QVERIFY(QFile::exists(m["image"].toUrl().toLocalFile()));copied=true;}if(m["kind"]=="comment"){QCOMPARE(m["text"].toString(),quote);QCOMPARE(m["color"].toString(),QString("#9274c3"));comment=true;}}
        QVERIFY(copied&&comment);QCOMPARE(store.searchKnowledge("sentence").size(),1);
        QImage printed(600,800,QImage::Format_RGB32);printed.fill(Qt::white);paintPdfAnnotations(printed,rows,1);
        QVERIFY(printed.pixelColor(100,180)!=QColor(Qt::white));
        QVERIFY(!store.updateHighlight(textId,"not-a-color",""));
        mark["rectangles"]=QVariantList{QVariantMap{{"x",.9},{"y",.2},{"width",.3},{"height",.1}}};
        store.saveAnnotation(source,0,mark);QTRY_COMPARE_WITH_TIMEOUT(done.size(),6,10000);QVERIFY(!done.last()[0].toBool());
        ResearchStore reopened(dir.filePath("data"));QVERIFY(reopened.initialize(&error));QCOMPARE(reopened.searchKnowledge("Edited annotation").size(),1);
    }
    void highlightsPersistVerifyRelinkAndRemove() {
        QTemporaryDir directory;
        const auto path = directory.filePath("marked.pdf"); writeFixture(path);
        const auto source = QUrl::fromLocalFile(path);
        QFile original(path); QVERIFY(original.open(QIODevice::ReadOnly));
        const auto bytes = original.readAll(); original.close();
        QString id;
        {
            ResearchStore store(directory.filePath("data")); QString error; QVERIFY(store.initialize(&error));
            QPdfDocument pdf; QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
            const auto bounds = pdf.getSelectionAtIndex(0, pdf.getAllText(0).text().indexOf("Research finding"), 45).boundingRectangle();
            const QPointF from(bounds.left(), bounds.center().y()), to(bounds.right(), bounds.center().y() + 20);
            const auto selected = pdf.getSelection(0, from, to).text();
            QSignalSpy saved(&store, &ResearchStore::highlightSaved), loaded(&store, &ResearchStore::highlightsLoaded);
            store.highlightText(source, 0, from, to, selected);
            QTRY_COMPARE_WITH_TIMEOUT(saved.size(), 1, 10000); id = saved[0][0].toString();
            QVERIFY(store.captures().isEmpty());
            store.loadHighlights(source); QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 1, 10000);
            const auto marks = loaded[0][2].toList(); QCOMPARE(marks.size(), 1);
            QCOMPARE(marks[0].toMap()["text"].toString(), selected);
            QVERIFY(marks[0].toMap()["rectangles"].toList().size() >= 2);
            for (const auto &r : marks[0].toMap()["rectangles"].toList()) {
                const auto rect = r.toMap(); QVERIFY(rect["x"].toDouble() >= 0); QVERIFY(rect["width"].toDouble() > 0);
                QVERIFY(rect["x"].toDouble() + rect["width"].toDouble() <= 1.0001);
            }
            store.highlightText(source, 0, from, to, selected);
            QTRY_COMPARE_WITH_TIMEOUT(saved.size(), 2, 10000); QCOMPARE(saved[1][0].toString(), id);
            const auto results = store.searchKnowledge("occlusion"); QCOMPARE(results.size(), 1);
            QCOMPARE(results[0].toMap()["kind"].toString(), "highlight");
            QVERIFY(original.open(QIODevice::ReadOnly)); QCOMPARE(original.readAll(), bytes); original.close();
        }
        {
            ResearchStore store(directory.filePath("data")); QString error; QVERIFY(store.initialize(&error));
            QSignalSpy loaded(&store, &ResearchStore::highlightsLoaded), ready(&store, &ResearchStore::sourceReady);
            store.loadHighlights(source); QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 1, 10000);
            QCOMPARE(loaded.last()[2].toList().size(), 1);
            // A different version at the same path must not receive old highlights.
            QVERIFY(original.open(QIODevice::Append)); original.write("\n% modified\n"); original.close();
            store.loadHighlights(source); QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 2, 10000);
            QVERIFY(loaded.last()[2].toList().isEmpty()); QVERIFY(!loaded.last()[3].toString().isEmpty());
            QVERIFY(original.open(QIODevice::WriteOnly)); original.write(bytes); original.close();
            const auto moved = directory.filePath("moved.pdf"); QVERIFY(QFile::rename(path, moved));
            QSignalSpy relinked(&store, &ResearchStore::relinkFinished);
            store.relinkSource(source, QUrl::fromLocalFile(moved));
            QTRY_COMPARE_WITH_TIMEOUT(relinked.size(), 1, 10000); QVERIFY(relinked[0][0].toBool());
            store.openHighlight(id); QTRY_COMPARE_WITH_TIMEOUT(ready.size(), 1, 10000);
            QCOMPARE(ready[0][0].toUrl(), QUrl::fromLocalFile(moved));
            store.loadHighlights(QUrl::fromLocalFile(moved)); QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 3, 10000);
            QCOMPARE(loaded.last()[2].toList()[0].toMap()["id"].toString(), id);
            QVERIFY(store.removeHighlight(id)); QVERIFY(!store.removeHighlight(id));
            QVERIFY(store.searchKnowledge("occlusion").isEmpty());
        }
        ResearchStore reopened(directory.filePath("data")); QString error; QVERIFY(reopened.initialize(&error));
        QVERIFY(reopened.searchKnowledge("occlusion").isEmpty());
    }
    void captureNotesPersistSearchAndKeepSource() {
        QTemporaryDir directory;
        const auto path = directory.filePath("source.pdf");
        writeFixture(path);
        QString id, original;
        {
            ResearchStore store(directory.path()); QString error;
            QVERIFY(store.initialize(&error));
            QPdfDocument pdf; QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
            const auto bounds = pdf.getSelectionAtIndex(0, pdf.getAllText(0).text().indexOf("Research finding"), 45).boundingRectangle();
            const QPointF from(bounds.left(), bounds.center().y()), to(bounds.right(), bounds.center().y());
            original = pdf.getSelection(0, from, to).text();
            store.captureText(QUrl::fromLocalFile(path), 0, from, to, original);
            QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
            QCOMPARE(store.captures().size(), 1);
            id = store.captures()[0].toMap()["id"].toString();
            QVERIFY(store.saveCaptureNote(id, "My uniquecomparison <b>not HTML</b>\n한글 메모"));
            QCOMPARE(store.captures()[0].toMap()["text"].toString(), original);
            const auto results = store.searchKnowledge("uniquecomparison", QUrl::fromLocalFile(path), "captures");
            QCOMPARE(results.size(), 1); QCOMPARE(results[0].toMap()["kind"].toString(), "note");
            QVERIFY(store.searchKnowledge("uniquecomparison", QUrl::fromLocalFile("/another.pdf")).isEmpty());
            QVERIFY(!store.saveCaptureNote(id, QString(10001, 'a')));
            QVERIFY(!store.saveCaptureNote("missing", "No orphan note"));
        }
        ResearchStore reopened(directory.path()); QString error;
        QVERIFY(reopened.initialize(&error));
        QVERIFY(reopened.captures()[0].toMap()["note"].toString().contains("uniquecomparison"));
        QVERIFY(reopened.saveCaptureNote(id, "Revised question"));
        QVERIFY(reopened.searchKnowledge("uniquecomparison").isEmpty());
        QVERIFY(reopened.saveCaptureNote(id, ""));
        QVERIFY(reopened.captures()[0].toMap()["note"].toString().isEmpty());
        QCOMPARE(reopened.captures()[0].toMap()["text"].toString(), original);
        reopened.captureRegion(QUrl::fromLocalFile(path), 1, QRectF(.1, .2, .3, .2));
        QTRY_VERIFY_WITH_TIMEOUT(!reopened.busy(), 10000);
        QString regionId;
        for (const auto &row : reopened.captures()) if (row.toMap()["kind"] == "region") regionId = row.toMap()["id"].toString();
        QVERIFY(!regionId.isEmpty()); QVERIFY(reopened.saveCaptureNote(regionId, "Figure note"));
        QVERIFY(reopened.deleteCapture(regionId));
        QVERIFY(reopened.searchKnowledge("Figure note").isEmpty());
        QVERIFY(!reopened.saveCaptureNote(regionId, "Cannot edit trashed capture"));
        QVERIFY(QFile::exists(path));
    }
    void legacyRegionSchemaIsPreserved() {
        QTemporaryDir directory;
        const auto connection = QStringLiteral("legacy-capture-check");
        const auto id = QStringLiteral("91ffeb1a-df10-4a54-a6fc-8a8b2c629b13");
        {
            auto db = QSqlDatabase::addDatabase("QSQLITE", connection);
            db.setDatabaseName(directory.filePath("owelk.sqlite3"));
            QVERIFY(db.open());
            QSqlQuery query(db);
            QVERIFY(query.exec("CREATE TABLE captures (id TEXT PRIMARY KEY, source TEXT NOT NULL, "
                "sha256 TEXT NOT NULL,page INTEGER NOT NULL,x REAL NOT NULL,y REAL NOT NULL,"
                "width REAL NOT NULL,height REAL NOT NULL,image TEXT NOT NULL,created_at TEXT NOT NULL)"));
            query.prepare("INSERT INTO captures VALUES(?,'file:///preserved.pdf','hash',2,.1,.2,.3,.4,?,'2026-01-01')");
            query.addBindValue(id); query.addBindValue(id + ".png");
            QVERIFY(query.exec());
        }
        QSqlDatabase::removeDatabase(connection);
        ResearchStore store(directory.path());
        QString error;
        QVERIFY(store.initialize(&error));
        QCOMPARE(store.captures().size(), 1);
        const auto capture = store.captures()[0].toMap();
        QCOMPARE(capture["id"].toString(), id);
        QCOMPARE(capture["kind"].toString(), "region");
        QCOMPARE(capture["page"].toInt(), 2);
        QVERIFY(capture["text"].toString().isEmpty());
        QVERIFY(capture["image"].toUrl().toLocalFile().endsWith(id + ".png"));
    }
    void failedPayloadInsertRollsBackAnchor() {
        QTemporaryDir directory;
        const auto path = directory.filePath("source.pdf");
        writeFixture(path);
        ResearchStore store(directory.path());
        QString error;
        QVERIFY(store.initialize(&error));
        const auto connection = QStringLiteral("capture-failure-check");
        {
            auto db = QSqlDatabase::addDatabase("QSQLITE", connection);
            db.setDatabaseName(directory.filePath("owelk.sqlite3"));
            QVERIFY(db.open());
            QSqlQuery query(db);
            QVERIFY(query.exec("CREATE TRIGGER reject_text BEFORE INSERT ON text_captures BEGIN SELECT RAISE(ABORT,'test failure'); END"));
            QPdfDocument pdf;
            QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
            const auto bounds = pdf.getSelectionAtIndex(0, pdf.getAllText(0).text().indexOf("Research finding"), 45).boundingRectangle();
            const QPointF from(bounds.left(), bounds.center().y()), to(bounds.right(), bounds.center().y());
            const auto text = pdf.getSelection(0, from, to).text();
            QSignalSpy saved(&store, &ResearchStore::captureSaved);
            QSignalSpy messages(&store, &ResearchStore::message);
            store.captureText(QUrl::fromLocalFile(path), 0, from, to, text);
            QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
            QCOMPARE(saved.size(), 0);
            QVERIFY(!messages.isEmpty());
            QVERIFY(store.captures().isEmpty());
            QVERIFY(query.exec("SELECT COUNT(*) FROM captures") && query.next());
            QCOMPARE(query.value(0).toInt(), 0);
            query.finish();
            QVERIFY(query.exec("DROP TRIGGER reject_text"));
            store.captureText(QUrl::fromLocalFile(path), 0, from, to, text);
            QTRY_COMPARE_WITH_TIMEOUT(saved.size(), 1, 10000);
        }
        QSqlDatabase::removeDatabase(connection);
    }
    void saveAndReopen_data() {
        QTest::addColumn<bool>("reverse");
        QTest::addColumn<int>("lines");
        QTest::newRow("single") << false << 1;
        QTest::newRow("multiline") << false << 3;
        QTest::newRow("reversed") << true << 3;
    }
    void saveAndReopen() {
        QFETCH(bool, reverse);
        QFETCH(int, lines);
        QTemporaryDir directory;
        const auto path = directory.filePath("evidence.pdf");
        writeFixture(path);
        QPdfDocument pdf;
        QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
        const auto bounds = pdf.getSelectionAtIndex(2, pdf.getAllText(2).text().indexOf("Research finding"), 45).boundingRectangle();
        QPointF from(bounds.left(), bounds.center().y());
        QPointF to(bounds.right(), bounds.center().y() + (lines - 1) * 20);
        if (reverse) std::swap(from, to);
        const auto selection = pdf.getSelection(2, from, to);
        const auto text = selection.text();
        QVERIFY(text.contains("Research finding 3.1"));
        if (lines > 1) QVERIFY(text.contains("Research finding 3.2"));
        const QUrl source = QUrl::fromLocalFile(path);
        QString id, error;
        {
            ResearchStore store(directory.filePath("data"));
            QVERIFY2(store.initialize(&error), qPrintable(error));
            QSignalSpy saved(&store, &ResearchStore::captureSaved);
            store.captureText(source, 2, from, to, text);
            QVERIFY(store.busy());
            QTRY_COMPARE_WITH_TIMEOUT(saved.size(), 1, 10000);
            QVERIFY(!store.busy());
            QCOMPARE(store.captures().size(), 1);
            const auto capture = store.captures()[0].toMap();
            id = capture["id"].toString();
            QCOMPARE(capture["kind"].toString(), "text");
            QCOMPARE(capture["text"].toString(), text);
            QVERIFY(capture["image"].toUrl().isEmpty());
            QVERIFY(QDir(directory.filePath("data/captures")).entryList(QDir::Files).isEmpty());
            const auto results = store.searchKnowledge("OCCLUSION");
            QCOMPARE(results.size(), 1);
            QCOMPARE(results[0].toMap()["id"].toString(), id);
            QVERIFY(results[0].toMap()["snippet"].toString().contains("occlusion"));
            QSignalSpy ready(&store, &ResearchStore::sourceReady);
            store.openCapture(id);
            QTRY_COMPARE_WITH_TIMEOUT(ready.size(), 1, 10000);
            QCOMPARE(ready[0][0].toUrl(), source);
            QCOMPARE(ready[0][1].toInt(), 2);
            const auto rect = ready[0][2].toRectF();
            const auto page = pdf.pagePointSize(2);
            QVERIFY(qAbs(rect.x() * page.width() - selection.boundingRectangle().x()) < .001);
            QVERIFY(qAbs(rect.height() * page.height() - selection.boundingRectangle().height()) < .001);
            // Existing image captures coexist with the new payload table.
            store.captureRegion(source, 0, QRectF(.1, .1, .2, .2));
            QTRY_COMPARE_WITH_TIMEOUT(saved.size(), 2, 10000);
        }
        ResearchStore reopened(directory.filePath("data"));
        QVERIFY(reopened.initialize(&error));
        QCOMPARE(reopened.captures().size(), 2);
        QCOMPARE(reopened.searchKnowledge("occlusion").size(), 1);
        // Relinking keeps the text payload and verifies the same source bytes.
        pdf.close();
        const auto moved = directory.filePath("moved.pdf");
        QVERIFY(QFile::rename(path, moved));
        QSignalSpy relinked(&reopened, &ResearchStore::relinkFinished);
        reopened.relinkSource(source, QUrl::fromLocalFile(moved));
        QTRY_COMPARE_WITH_TIMEOUT(relinked.size(), 1, 10000);
        QVERIFY2(relinked[0][0].toBool(), qPrintable(relinked[0][1].toString()));
        for (const auto &entry : reopened.captures()) {
            const auto capture = entry.toMap();
            QCOMPARE(capture["source"].toUrl(), QUrl::fromLocalFile(moved));
            if (capture["id"].toString() == id) QCOMPARE(capture["text"].toString(), text);
        }
        QVERIFY(reopened.saveCaptureNote(id, "Preserved text note"));
        QVERIFY(reopened.deleteCapture(id));
        QVERIFY(!reopened.deleteCapture(id));
        QCOMPARE(reopened.captures().size(), 1);
        QVERIFY(reopened.searchKnowledge("occlusion").isEmpty());
        QVERIFY(QFileInfo::exists(moved));
        QCOMPARE(reopened.trashedCaptures().size(), 1);
        QCOMPARE(reopened.trashedCaptures()[0].toMap()["text"].toString(), text);
        QVERIFY(reopened.restoreCapture(id));
        QVERIFY(reopened.trashedCaptures().isEmpty());
        QCOMPARE(reopened.searchKnowledge("occlusion").size(), 1);
        for (const auto &entry : reopened.captures()) {
            if (entry.toMap()["id"].toString() == id) {
                QCOMPARE(entry.toMap()["text"].toString(), text);
                QCOMPARE(entry.toMap()["note"].toString(), "Preserved text note");
                QVERIFY(entry.toMap()["image"].toUrl().isEmpty());
            }
        }
        // Soft deletion must preserve the original quote in SQLite, without inventing a PNG.
        const auto connection = QStringLiteral("text-capture-check");
        {
            auto db = QSqlDatabase::addDatabase("QSQLITE", connection);
            db.setDatabaseName(directory.filePath("data/owelk.sqlite3"));
            QVERIFY(db.open());
            QSqlQuery query(db);
            query.prepare("SELECT text,start_index,end_index FROM text_captures WHERE capture_id=?");
            query.addBindValue(id);
            QVERIFY(query.exec() && query.next());
            QCOMPARE(query.value(0).toString(), text);
            QCOMPARE(query.value(1).toInt(), selection.startIndex());
            QCOMPARE(query.value(2).toInt(), selection.endIndex());
        }
        QSqlDatabase::removeDatabase(connection);
    }
    void rejectInvalidOrStaleSelections() {
        QTemporaryDir directory;
        const auto path = directory.filePath("original.pdf");
        writeFixture(path);
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        QSignalSpy saved(&store, &ResearchStore::captureSaved);
        const auto source = QUrl::fromLocalFile(path);
        store.captureText(source, 0, {}, {}, "");
        store.captureText(source, -1, {}, {}, "quote");
        store.captureText(QUrl("https://example.com/test.pdf"), 0, {}, {}, "quote");
        store.captureText(source, 0, {std::numeric_limits<double>::quiet_NaN(), 0}, {}, "quote");
        QVERIFY(!store.busy());
        QPdfDocument pdf;
        QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
        const auto bounds = pdf.getSelectionAtIndex(0, pdf.getAllText(0).text().indexOf("Research finding"), 45).boundingRectangle();
        const QPointF from(bounds.left(), bounds.center().y()), to(bounds.right(), bounds.center().y());
        const auto text = pdf.getSelection(0, from, to).text();
        store.captureText(source, 0, from, to, "stale UI text");
        store.captureText(source, 1000, from, to, text);
        QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
        QCOMPARE(saved.size(), 0);
        QVERIFY(store.captures().isEmpty());
        store.captureText(source, 0, from, to, text);
        QTRY_COMPARE_WITH_TIMEOUT(saved.size(), 1, 10000);
        const auto id = saved[0][0].toString();
        pdf.close();
        QFile changed(path);
        QVERIFY(changed.open(QIODevice::Append));
        changed.write("\n% changed\n"); changed.close();
        QSignalSpy messages(&store, &ResearchStore::message);
        QSignalSpy ready(&store, &ResearchStore::sourceReady);
        store.openCapture(id);
        QTRY_VERIFY_WITH_TIMEOUT(!messages.isEmpty(), 10000);
        QVERIFY(messages.last()[0].toString().contains("changed"));
        QCOMPARE(ready.size(), 0);
        QCOMPARE(store.captures()[0].toMap()["text"].toString(), text);
        QVERIFY(QFile::rename(path, directory.filePath("missing.pdf")));
        QSignalSpy missing(&store, &ResearchStore::relinkRequested);
        store.openCapture(id);
        QTRY_COMPARE_WITH_TIMEOUT(missing.size(), 1, 10000);
        QCOMPARE(ready.size(), 0);
    }
};
QTEST_MAIN(TextCaptureTest)
#include "TextCaptureTest.moc"
