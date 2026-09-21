#include "PaperIndex.h"
#include "PdfFixture.h"
#include <QFile>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

namespace {
void textFixture(const QString &path, const QStringList &pages)
{
    QPdfWriter writer(path);
    writer.setResolution(72);
    QPainter painter(&writer);
    painter.setFont(QFont("Helvetica", 12));
    for (int p = 0; p < pages.size(); ++p) {
        if (p) writer.newPage();
        painter.drawText(QRectF(35, 40, 480, 700), Qt::TextWordWrap, pages[p]);
        painter.drawRect(30, 30, 500, 720); // Blank-text pages still have visible graphics.
    }
}
QVariantList find(PaperIndex &index, const QString &query)
{
    QSignalSpy done(&index, &PaperIndex::searchFinished);
    const int id = index.search(query);
    if (!done.wait(10000)) return {};
    if (done.first()[0].toInt() != id || !done.first()[2].toString().isEmpty()) { qWarning() << done.first(); return {}; }
    return done.first()[1].toList();
}
}

class PaperIndexTest : public QObject
{
    Q_OBJECT
private slots:
    void groupedResultsAndPaperScope() {
        QTemporaryDir directory;
        const auto a = QUrl::fromLocalFile(directory.filePath("Paper A.pdf"));
        const auto b = QUrl::fromLocalFile(directory.filePath("Paper B.pdf"));
        textFixture(a.toLocalFile(), QStringList(45, "occlusion observation"));
        textFixture(b.toLocalFile(), QStringList(5, "occlusion evidence"));
        PaperIndex index(directory.path()); QString error;
        QVERIFY(index.initialize(&error)); index.enqueue(a); index.enqueue(b);
        QTRY_VERIFY_WITH_TIMEOUT(!index.busy(), 15000);
        QSignalSpy done(&index, &PaperIndex::searchFinished);
        index.searchGrouped("occlu", {}, 0);
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 10000);
        QVERIFY2(done[0][2].toString().isEmpty(), qPrintable(done[0][2].toString()));
        int groups = 0, hits = 0, more = 0;
        for (const auto &value : done[0][1].toList()) {
            const auto kind = value.toMap()["kind"].toString();
            groups += kind == "paperGroup"; hits += kind == "text"; more += kind == "moreInPaper";
        }
        QCOMPARE(groups, 2); QCOMPARE(hits, 6); QCOMPARE(more, 2);
        done.clear(); index.searchGrouped("occlu", a, 40);
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 10000);
        QVERIFY(done[0][2].toString().isEmpty());
        QCOMPARE(done[0][1].toList().size(), 6); // One heading + five remaining matching pages.
        for (const auto &value : done[0][1].toList()) QCOMPARE(value.toMap()["source"].toUrl(), a);
    }
    void textSearchPagesPrefixAndSafeSyntax() {
        QTemporaryDir dir;
        const auto a = QUrl::fromLocalFile(dir.filePath("a.pdf"));
        const auto b = QUrl::fromLocalFile(dir.filePath("b.pdf"));
        textFixture(a.toLocalFile(), {"Introduction observation", "Rareword counterfactual evidence <example>", "counterfactual alone"});
        textFixture(b.toLocalFile(), {"Rareword additional evidence"});
        PaperIndex index(dir.path()); QString error;
        QVERIFY2(index.initialize(&error), qPrintable(error));
        index.enqueue(a); index.enqueue(b); index.enqueue(a);
        QTRY_VERIFY_WITH_TIMEOUT(!index.busy(), 10000);
        QCOMPARE(index.documents().size(), 2);
        QCOMPARE(index.documents().first().toMap()["state"].toString(), "ready");
        auto rows = find(index, "rareword counter");
        QCOMPARE(rows.size(), 1);
        const auto row = rows[0].toMap();
        QCOMPARE(row["source"].toUrl(), a);
        QCOMPARE(row["page"].toInt(), 1);
        QVERIFY(row["snippet"].toString().contains("counterfactual"));
        QVERIFY(!row["documentId"].toString().isEmpty());
        QCOMPARE(row["sha256"].toString().size(), 64);
        QCOMPARE(find(index, "RAREWORD").size(), 2);
        QCOMPARE(find(index, "\"rareword\"*").size(), 2); // Syntax is tokenized literally.
        QSignalSpy done(&index, &PaperIndex::searchFinished);
        index.search("\" ) OR NEAR(:*");
        QVERIFY(done.wait(10000));
        QVERIFY(done.first()[2].toString().isEmpty());
        QVERIFY(find(index, "***").isEmpty());
        QSignalSpy opened(&index, &PaperIndex::resultReady);
        index.openResult(row["documentId"].toString(), 1, row["sha256"].toString());
        QVERIFY(opened.wait(10000));
        QCOMPARE(opened.first()[1].toInt(), 1);
    }
    void changedSourceIsRejectedAndReindexedWithSameId() {
        QTemporaryDir dir;
        const auto source = QUrl::fromLocalFile(dir.filePath("changed.pdf"));
        textFixture(source.toLocalFile(), {"Oldword evidence"});
        PaperIndex index(dir.path()); QString error; QVERIFY(index.initialize(&error));
        index.enqueue(source); QTRY_VERIFY_WITH_TIMEOUT(!index.busy(), 10000);
        const auto original = find(index, "oldword");
        QCOMPARE(original.size(), 1);
        const auto old = original.first().toMap();
        textFixture(source.toLocalFile(), {"Replacementword evidence"});
        QSignalSpy opened(&index, &PaperIndex::resultReady), message(&index, &PaperIndex::message);
        index.openResult(old["documentId"].toString(), 0, old["sha256"].toString());
        QVERIFY(message.wait(10000));
        QTRY_VERIFY_WITH_TIMEOUT(!index.busy(), 10000);
        QVERIFY(opened.isEmpty());
        QVERIFY(find(index, "oldword").isEmpty());
        const auto current = find(index, "replacementword");
        QCOMPARE(current.size(), 1);
        QCOMPARE(current.first().toMap()["documentId"], old["documentId"]);
        QSignalSpy invalid(&index, &PaperIndex::message);
        index.openResult(old["documentId"].toString(), 0, old["sha256"].toString());
        QCOMPARE(invalid.size(), 1);
        QVERIFY(QFileInfo::exists(source.toLocalFile()));
    }
    void persistenceAndNoTextAndMissing() {
        QTemporaryDir dir;
        const auto blank = QUrl::fromLocalFile(dir.filePath("blank.pdf"));
        const auto source = QUrl::fromLocalFile(dir.filePath("saved.pdf"));
        textFixture(blank.toLocalFile(), {""});
        textFixture(source.toLocalFile(), {"Persistedword evidence"});
        QString id;
        {
            PaperIndex index(dir.path()); QString error; QVERIFY(index.initialize(&error));
            index.enqueue(blank); index.enqueue(source); QTRY_VERIFY_WITH_TIMEOUT(!index.busy(), 10000);
            QCOMPARE(index.documents().first().toMap()["state"].toString(), "empty");
            id = find(index, "persistedword").first().toMap()["documentId"].toString();
        }
        PaperIndex reopened(dir.path()); QString error; QVERIFY(reopened.initialize(&error));
        QTRY_VERIFY_WITH_TIMEOUT(!reopened.busy(), 10000);
        QCOMPARE(find(reopened, "persistedword").first().toMap()["documentId"].toString(), id);
        // Only generated temporary fixture is removed, never a user document.
        QVERIFY(QFile::remove(source.toLocalFile()));
        reopened.retry(source); QTRY_VERIFY_WITH_TIMEOUT(!reopened.busy(), 10000);
        QVERIFY(find(reopened, "persistedword").isEmpty());
        QCOMPARE(reopened.documents().last().toMap()["state"].toString(), "missing");
        textFixture(source.toLocalFile(), {"Restoredword evidence"});
        reopened.retry(source); QTRY_VERIFY_WITH_TIMEOUT(!reopened.busy(), 10000);
        QCOMPARE(find(reopened, "restoredword").size(), 1);
    }
    void pauseResumeAndInterruptedRestart() {
        QTemporaryDir dir;
        const auto source = QUrl::fromLocalFile(dir.filePath("long.pdf"));
        writeFixture(source.toLocalFile(), "Cancel test", 120);
        {
            PaperIndex index(dir.path()); QString error; QVERIFY(index.initialize(&error));
            index.setPaused(true); index.enqueue(source);
            QVERIFY(index.busy()); QVERIFY(index.paused());
            QTest::qWait(30); QVERIFY(index.documents().isEmpty());
            index.setPaused(false); index.setPaused(true);
            QTRY_VERIFY_WITH_TIMEOUT(!index.documents().isEmpty() && index.documents().first().toMap()["state"] == "paused", 10000);
            index.setPaused(false); QTRY_VERIFY_WITH_TIMEOUT(!index.busy(), 10000);
            QCOMPARE(find(index, "occlusion").size(), 40); // Result cap.
        }
        // Simulate a process interruption in a persisted document record.
        const auto name = QStringLiteral("interruption-test");
        {
            auto db = QSqlDatabase::addDatabase("QSQLITE", name);
            db.setDatabaseName(dir.filePath("search.sqlite3")); QVERIFY(db.open());
            { QSqlQuery q(db); QVERIFY(q.exec("UPDATE documents SET state='indexing'")); }
            db.close();
        }
        QSqlDatabase::removeDatabase(name);
        PaperIndex index(dir.path()); QString error; QVERIFY(index.initialize(&error));
        QTRY_VERIFY_WITH_TIMEOUT(!index.busy(), 10000);
        QCOMPARE(index.documents().first().toMap()["state"].toString(), "ready");
        QCOMPARE(find(index, "occlusion").size(), 40);
    }
    void malformedDoesNotBlockOtherFiles() {
        QTemporaryDir dir;
        const auto bad = QUrl::fromLocalFile(dir.filePath("bad.pdf"));
        { QFile file(bad.toLocalFile()); QVERIFY(file.open(QIODevice::WriteOnly)); file.write("not a PDF"); }
        const auto good = QUrl::fromLocalFile(dir.filePath("good.pdf"));
        textFixture(good.toLocalFile(), {"Healthyword"});
        PaperIndex index(dir.path()); QString error; QVERIFY(index.initialize(&error));
        index.enqueue(bad); index.enqueue(good); QTRY_VERIFY_WITH_TIMEOUT(!index.busy(), 10000);
        QCOMPARE(index.documents().first().toMap()["state"].toString(), "failed");
        QCOMPARE(find(index, "healthyword").size(), 1);
    }
    void interactionYieldsAndDestroyedReaderReleasesIndex() {
        QTemporaryDir dir;
        const auto source = QUrl::fromLocalFile(dir.filePath("interactive.pdf"));
        textFixture(source.toLocalFile(), {"Interactiveword evidence"});
        PaperIndex index(dir.path()); QString error; QVERIFY(index.initialize(&error));
        auto reader = std::make_unique<QObject>();
        index.setReaderInteracting(reader.get(), true);
        index.enqueue(source);
        QTRY_VERIFY_WITH_TIMEOUT(!index.documents().isEmpty() && index.documents().first().toMap()["state"] == "indexing", 10000);
        QTest::qWait(30); QVERIFY(index.busy());
        reader.reset();
        QTRY_VERIFY_WITH_TIMEOUT(!index.busy(), 10000);
        QCOMPARE(find(index, "interactiveword").size(), 1);
    }
    void normalizedHyphensAndColumns() {
        QTemporaryDir dir;
        const auto source = QUrl::fromLocalFile(dir.filePath("columns.pdf"));
        {
            // Built-in PDF font avoids platform font-subsetting variations in this layout fixture.
            const QByteArray content = "BT /F1 12 Tf 35 730 Td (counter-) Tj 0 -20 Td (factual leftcolumn) Tj ET "
                                       "BT /F1 12 Tf 300 730 Td (rightcolumn evidence) Tj ET";
            const QList<QByteArray> objects = {
                "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
                "<< /Length " + QByteArray::number(content.size()) + " >>\nstream\n" + content + "\nendstream",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"};
            QByteArray pdf("%PDF-1.4\n"), xref("xref\n0 6\n0000000000 65535 f \n");
            for (int i = 0; i < objects.size(); ++i) {
                xref += QByteArray::number(pdf.size()).rightJustified(10, '0') + " 00000 n \n";
                pdf += QByteArray::number(i + 1) + " 0 obj\n" + objects[i] + "\nendobj\n";
            }
            const auto offset = pdf.size();
            pdf += xref + "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" + QByteArray::number(offset) + "\n%%EOF\n";
            QFile file(source.toLocalFile()); QVERIFY(file.open(QIODevice::WriteOnly)); QCOMPARE(file.write(pdf), pdf.size());
        }
        PaperIndex index(dir.path()); QString error; QVERIFY(index.initialize(&error));
        index.enqueue(source); QTRY_VERIFY_WITH_TIMEOUT(!index.busy(), 10000);
        QCOMPARE(find(index, "leftcolumn").size(), 1);
        QCOMPARE(find(index, "rightcolumn").size(), 1);
        QCOMPARE(find(index, "counterfactual").size(), 1);
    }
};
QTEST_MAIN(PaperIndexTest)
#include "PaperIndexTest.moc"
