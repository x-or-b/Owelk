#include "ResearchStore.h"
#include "LibrarySync.h"
#include "MathRenderer.h"
#include "WorkerConnection.h"
#include "PaperIndex.h"
#include "ReferenceFinder.h"
#include "FileFingerprint.h"
#include "FileNames.h"
#include "AppInstance.h"
#include <QFileOpenEvent>
#include "SelectionGeometry.h"
#include "PdfFixture.h"
#include "StoreFixture.h"
#include "PaperMetadata.h"
#include "MetadataLookup.h"
#include "ForYou.h"
#include "ReadingClock.h"
#include "ArxivVersions.h"
#include "ImagePalette.h"
#include "Theme.h"
#include "DesktopPet.h"
#include "SwipeNavigation.h"
#include <QJSEngine>
#include <QWheelEvent>
#include <QWindow>
#include <QTimeZone>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTcpServer>
#include <QLocalServer>
#include <QTcpSocket>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QSqlRecord>
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
    void readingTimeAddsUpByDayAndComputer()
    {
        // The clock counts while a paper is in front and used, splits at local midnight, stops three minutes after
        // the last use, and starts its stretch again after five minutes away.
        ReadingClock clock;
        auto now = QDateTime(QDate(2026, 3, 10), QTime(23, 59)).toMSecsSinceEpoch();
        clock.setClock([&now] { return now; });
        QHash<QString, int> counted;
        connect(&clock, &ReadingClock::counted, this,
            [&counted](const QUrl &, const QString &day, int seconds) { counted[day] += seconds; });
        clock.setSource(QUrl::fromLocalFile("/papers/a.pdf"));
        QVERIFY(clock.reading());
        now += 30000;
        clock.touch();
        now += 60000;
        clock.touch();
        clock.flush();
        QCOMPARE(counted.value("2026-03-10"), 60);
        QCOMPARE(counted.value("2026-03-11"), 30);
        QCOMPARE(clock.stretch(), 90);
        // Four minutes untouched: three count, then it stops; the next use starts it again from then.
        now += 4 * 60000;
        clock.update();
        QVERIFY(!clock.reading());
        clock.flush();
        QCOMPARE(counted.value("2026-03-11"), 210);
        now += 60000;
        clock.touch();
        QVERIFY(clock.reading());
        now += 30000;
        clock.flush();
        QCOMPARE(counted.value("2026-03-11"), 240);
        QCOMPARE(clock.stretch(), 300);
        // Away from the paper (Home, the window closed): it stops, and five minutes later the stretch is over.
        clock.setSource({});
        QVERIFY(!clock.reading());
        now += 4 * 60000;
        clock.update();
        QCOMPARE(clock.stretch(), 300);
        now += 60000;
        clock.update();
        QCOMPARE(clock.stretch(), 0);
        clock.flush();
        QCOMPARE(counted.value("2026-03-11"), 240);

        // The store keeps it by computer, paper and day, and adds it up.
        QTemporaryDir directory;
        const auto path = directory.filePath("paper.pdf");
        writeFixture(path);
        const auto source = QUrl::fromLocalFile(path);
        ResearchStore store(directory.filePath("data"));
        QVERIFY(store.initialize(nullptr));
        QCOMPARE(store.readingCalendar(7)["streak"].toInt(), 0);
        const auto day = [](int ago) { return QDate::currentDate().addDays(-ago).toString(Qt::ISODate); };
        QVERIFY(store.recordReading(source, day(1), 600));
        QVERIFY(store.recordReading(source, day(1), 300));
        QVERIFY(store.recordReading(source, day(2), 90));
        QVERIFY(store.recordReading(source, day(4), 3000));
        QVERIFY(!store.recordReading(source, "yesterday", 60));
        QCOMPARE(store.readingSeconds(source), 3990);
        {
            // Another computer's time on the same day, as sync brings it.
            WorkerConnection db(store.dataDirectory() + "/owelk.sqlite3", false);
            QVERIFY(QSqlQuery(db.db).exec("INSERT INTO reading_days(device,document_id,day,seconds) SELECT 'other',id,'"
                + day(1) + "',100 FROM documents"));
        }
        QCOMPARE(store.readingSeconds(source), 4090);
        QCOMPARE(store.documentDetails(source)["readSeconds"].toInt(), 4090);
        {
            // A copy of this paper merged into it by sync: rows under its old ID count as this paper's, and the same
            // computer's day there twice (its own row and its move from elsewhere) counts once.
            WorkerConnection db(store.dataDirectory() + "/owelk.sqlite3", false);
            QSqlQuery query(db.db);
            QVERIFY(query.exec("CREATE TABLE IF NOT EXISTS sync_alias(kind TEXT NOT NULL, from_id TEXT NOT NULL, to_id "
                               "TEXT NOT NULL, PRIMARY KEY(kind,from_id))"));
            QVERIFY(query.exec(
                "INSERT INTO sync_alias(kind,from_id,to_id) SELECT 'document','merged-copy',id FROM documents"));
            QVERIFY(query.exec("INSERT INTO reading_days(device,document_id,day,seconds) VALUES('third','merged-copy','"
                + day(3) + "',50),('other','merged-copy','" + day(1) + "',100)"));
        }
        QCOMPARE(store.readingSeconds(source), 4140);
        QCOMPARE(store.readingCalendar(7)["days"].toList()[3].toMap()["papers"].toInt(), 1);
        auto calendar = store.readingCalendar(7);
        const auto days = calendar["days"].toList();
        QCOMPARE(days.size(), 7);
        QCOMPARE(days.last().toMap()["day"].toString(), day(0));
        QCOMPARE(days[5].toMap()["seconds"].toInt(), 1000);
        QCOMPARE(days[5].toMap()["papers"].toInt(), 1);
        QCOMPARE(calendar["week"].toInt(), 4140);
        // Before today's first minute the run counts up to yesterday; day 3 breaks it.
        QCOMPARE(calendar["streak"].toInt(), 2);
        QVERIFY(store.recordReading(source, day(0), 30));
        QCOMPARE(store.readingCalendar(7)["streak"].toInt(), 2);
        QVERIFY(store.recordReading(source, day(0), 30));
        calendar = store.readingCalendar(7);
        QCOMPARE(calendar["streak"].toInt(), 3);
        QCOMPARE(calendar["today"].toInt(), 60);
        // What the store's own clock counts is saved there.
        auto *storeClock = qobject_cast<ReadingClock *>(store.readingClock());
        auto clockNow = QDateTime::currentMSecsSinceEpoch();
        storeClock->setClock([&clockNow] { return clockNow; });
        QSignalSpy saved(&store, &ResearchStore::readingSaved);
        storeClock->setSource(source);
        clockNow += 45000;
        storeClock->flush();
        QCOMPARE(saved.size(), 1);
        QCOMPARE(store.readingSeconds(source), 4140 + 60 + 45);
        storeClock->setSource({});
        // The papers read in a span of days, longest first; one no longer in the Library has no source.
        const auto otherPath = directory.filePath("other.pdf");
        writeFixture(otherPath);
        const auto other = QUrl::fromLocalFile(otherPath);
        QVERIFY(store.recordReading(other, day(1), 2000));
        QVERIFY(store.recordReading(other, day(9), 500));
        {
            WorkerConnection db(store.dataDirectory() + "/owelk.sqlite3", false);
            QVERIFY(QSqlQuery(db.db).exec(
                "INSERT INTO reading_days(device,document_id,day,seconds) VALUES('other','gone','" + day(1) + "',70)"));
        }
        const auto papers = store.readingPapers(day(1), day(1));
        QCOMPARE(papers.size(), 3);
        QVERIFY(store.sameSource(papers[0].toMap()["source"].toUrl(), other));
        QCOMPARE(papers[0].toMap()["seconds"].toInt(), 2000);
        QVERIFY(store.sameSource(papers[1].toMap()["source"].toUrl(), source));
        QCOMPARE(papers[1].toMap()["seconds"].toInt(), 1000);
        QVERIFY(!papers[1].toMap()["name"].toString().isEmpty());
        QVERIFY(papers[2].toMap()["source"].toUrl().isEmpty());
        QCOMPARE(store.readingPapers(day(6), day(0)).size(), 3);
        QCOMPARE(store.readingPapers(day(9), day(9)).size(), 1);
        // The seven days before the last seven.
        QCOMPARE(store.readingCalendar(7)["previousWeek"].toInt(), 500);
    }
    void picturesRotateOnlyWhenReadingAllowsIt()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QVERIFY(store.initialize(nullptr));
        QImage picture(20, 30, QImage::Format_RGB32);
        picture.fill(Qt::blue);
        const auto first = directory.filePath("first.png"), second = directory.filePath("second.png");
        QVERIFY(picture.save(first));
        picture.fill(Qt::green);
        QVERIFY(picture.save(second));
        QString before;
        {
            Theme theme(&store);
            QCOMPARE(theme.pictureInterval(), 0);
            QVERIFY(theme.usePicture(QUrl::fromLocalFile(first)));
            QVERIFY(theme.usePicture(QUrl::fromLocalFile(second)));
            before = theme.picture().toString();
            theme.setPictureScale(60);
            theme.setPictureInterval(30);
            theme.setPictureInterval(7);
            QCOMPARE(theme.pictureInterval(), 30);
        }
        store.setSetting("appearance.pictureNext", QDateTime::currentDateTimeUtc().addSecs(-60).toString(Qt::ISODate));
        {
            Theme theme(&store);
            QCOMPARE(theme.picture().toString(), before);
            theme.setPictureRotationAllowed(false);
            QCOMPARE(theme.picture().toString(), before);
            theme.setPictureRotationAllowed(true);
            QVERIFY(theme.picture().toString() != before);
            QCOMPARE(theme.pictureScale(), 100);
            const auto now = theme.picture();
            theme.setPictureRotationAllowed(false);
            theme.setPictureRotationAllowed(true);
            QCOMPARE(theme.picture(), now); // Next due time was moved forward, one change only.
            theme.setPictureInterval(-1);
            before = theme.picture().toString();
        }
        {
            Theme theme(&store);
            QCOMPARE(theme.pictureInterval(), -1);
            QVERIFY(theme.picture().toString() != before);
            QCOMPARE(theme.pictureScale(), 60);
            theme.removePicture();
            before = theme.picture().toString();
        }
        Theme single(&store);
        QCOMPARE(single.picture().toString(), before);
    }

    void repositoriesComeFromBodyAndPdfLinks()
    {
        const auto links = ReferenceFinder::repositoryLinks(
            {"Code: https://github.com/Owner/Repo/tree/main. github.com/owner/repo.git\n"
             "https://gitlab.com/lab/project/-/tree/main https://huggingface.co/spaces/team/demo/tree/main\n"
             "https://github.com/extra/four\nReferences\nhttps://github.com/cited/other"});
        QCOMPARE(links,
            QStringList({"https://github.com/Owner/Repo", "https://gitlab.com/lab/project",
                "https://huggingface.co/spaces/team/demo"}));
        QVERIFY(ReferenceFinder::repositoryLinks(
            {"github.com/person https://github.com/explore/projects evilgithub.com/a/b "
             "https://github.com.evil/a/b\nReferences\ngithub.com/cited/repo",
                "github.com/cited/another"})
                .isEmpty());
        QCOMPARE(ReferenceFinder::repositoryLinks({"An article\n7. References\ngithub.com/skip/this"},
                     {QVariantMap{{"page", 0}, {"url", "https://huggingface.co/datasets/team/data"}, {"body", true}},
                         QVariantMap{{"page", 0}, {"url", "https://github.com/skip/annotation"}, {"body", false}}}),
            QStringList({"https://huggingface.co/datasets/team/data"}));
        QTemporaryDir directory;
        const auto path = directory.filePath("repository.pdf");
        QVERIFY(writeLinkFixture(path, false, false, "https://github.com/test/repository/tree/main"));
        ReferenceFinder finder(std::make_shared<std::atomic_bool>(false));
        QSignalSpy found(&finder, &ReferenceFinder::codeLinksFound);
        const auto request = finder.codeLinks(QUrl::fromLocalFile(path));
        // New pointer requests must not cancel this document request.
        finder.resolve(QUrl::fromLocalFile(path), 0, {60, 60});
        finder.resolve(QUrl::fromLocalFile(path), 1, {60, 60});
        QTRY_COMPARE(found.size(), 1);
        QCOMPARE(found.first()[0].toInt(), request);
        QCOMPARE(found.first()[1].toStringList(), QStringList({"https://github.com/test/repository"}));
    }

    void trackpadNavigation()
    {
        class Window : public QWindow {
        public:
            int passed = 0;
            bool event(QEvent *event) override
            {
                if (event->type() == QEvent::Wheel) ++passed;
                return QWindow::event(event);
            }
        } window;
        SwipeNavigation swipe;
        swipe.setWindow(&window);
        swipe.setProperty("enabled", true);
        QSignalSpy back(&swipe, &SwipeNavigation::back), forward(&swipe, &SwipeNavigation::forward);
        auto send = [&](QPoint delta, Qt::ScrollPhase phase, bool inverted) {
            QWheelEvent event({}, {}, delta, {}, Qt::NoButton, Qt::NoModifier, phase, inverted);
            QCoreApplication::sendEvent(&window, &event);
        };
        for (bool inverted : {false, true}) {
            const int right = inverted ? 1 : -1;
            const int before = window.passed, count = back.count();
            send({}, Qt::ScrollBegin, inverted);
            send({right * 5, 0}, Qt::ScrollUpdate, inverted);
            QCOMPARE(window.passed, before + 2);
            send({right * 10, 0}, Qt::ScrollUpdate, inverted);
            QVERIFY(swipe.progress() < 0);
            send({right * 140, 0}, Qt::ScrollUpdate, inverted);
            QCOMPARE(swipe.progress(), -1.0);
            send({}, Qt::ScrollEnd, inverted);
            QCOMPARE(back.count(), count + 1);
            send({right * 200, 0}, Qt::ScrollMomentum, inverted);
            send({}, Qt::ScrollEnd, inverted);
            QCOMPARE(back.count(), count + 1);
            QCOMPARE(window.passed, before + 2);
            const int next = forward.count();
            send({}, Qt::ScrollBegin, inverted);
            send({-right * 160, 0}, Qt::ScrollUpdate, inverted);
            send({}, Qt::ScrollEnd, inverted);
            QCOMPARE(forward.count(), next + 1);
            // Reversing before release cancels; vertical gestures stay scrolling all the way.
            send({}, Qt::ScrollBegin, inverted);
            send({right * 150, 0}, Qt::ScrollUpdate, inverted);
            send({-right * 100, 0}, Qt::ScrollUpdate, inverted);
            send({}, Qt::ScrollEnd, inverted);
            QCOMPARE(back.count(), count + 1);
            send({}, Qt::ScrollBegin, inverted);
            send({15, 20}, Qt::ScrollUpdate, inverted);
            send({200, 0}, Qt::ScrollUpdate, inverted);
            QCOMPARE(swipe.progress(), 0.0);
        }
        QJSEngine js;
        swipe.setProperty("allowed", QVariant::fromValue(js.evaluate("(function() { return false })")));
        int before = window.passed;
        send({}, Qt::ScrollBegin, true);
        send({200, 0}, Qt::ScrollUpdate, true);
        send({}, Qt::ScrollEnd, true);
        QCOMPARE(window.passed, before + 3);
        swipe.setProperty("enabled", false);
        before = window.passed;
        send({}, Qt::ScrollBegin, true);
        send({200, 0}, Qt::ScrollUpdate, true);
        send({}, Qt::ScrollEnd, true);
        send({200, 0}, Qt::NoScrollPhase, true);
        QCOMPARE(window.passed, before + 4);
    }

    void aSecondLaunchHandsItsFilesToTheRunningOne()
    {
        QTemporaryDir directory;
        // The running Owelk answers on its own thread here (in real use, it is another process).
        QThread thread;
        auto *running = new AppInstance(directory.filePath("data"));
        running->moveToThread(&thread);
        thread.start();
        bool listening = false;
        QMetaObject::invokeMethod(
            running,
            [&] {
                listening = running->listen();
                running->takePending();
            },
            Qt::BlockingQueuedConnection);
        QVERIFY(listening);
        QVariantList urls;
        QMutex mutex;
        connect(
            running, &AppInstance::filesRequested, running,
            [&](const QVariantList &list) {
                QMutexLocker lock(&mutex);
                urls = list;
            },
            Qt::DirectConnection);
        // Same data folder: the files go to the running one, which answers.
        AppInstance second(directory.filePath("data"));
        QCOMPARE(second.serverName(), running->serverName());
        QVERIFY(second.forward({directory.filePath("a.pdf"), directory.filePath("b c.pdf")}));
        QTRY_VERIFY([&] {
            QMutexLocker lock(&mutex);
            return urls.size() == 2;
        }());
        QMetaObject::invokeMethod(running, [running] { delete running; }, Qt::BlockingQueuedConnection);
        thread.quit();
        thread.wait();
        QCOMPARE(urls.size(), 2);
        QCOMPARE(urls[1].toUrl(), QUrl::fromLocalFile(directory.filePath("b c.pdf")));
        // Another data folder is another Owelk; with nobody running, nothing is forwarded.
        AppInstance nobody(directory.filePath("other"));
        QVERIFY(!nobody.forward({}, 300));
        QVERIFY(!nobody.busy());
        // A running one that does not answer (still starting): the launch knows, and its name is not taken.
        AppInstance stuck(directory.filePath("stuck")), late(directory.filePath("stuck"));
        QLocalServer silent;
        QVERIFY(silent.listen(stuck.serverName()));
        QVERIFY(!late.forward({}, 300));
        QVERIFY(late.busy());
        QVERIFY(!late.listen());
        QVERIFY(silent.isListening());
        // Finder's file-open event, before the window asked: kept until then.
        AppInstance finder(directory.filePath("finder"));
        QFileOpenEvent pdf(QUrl::fromLocalFile(directory.filePath("paper.pdf")));
        QVERIFY(finder.eventFilter(nullptr, &pdf));
        QFileOpenEvent other(QUrl::fromLocalFile(directory.filePath("notes.txt")));
        QVERIFY(!finder.eventFilter(nullptr, &other));
        QCOMPARE(finder.takePending(), QVariantList{QUrl::fromLocalFile(directory.filePath("paper.pdf"))});
    }
    void wordsAreKeptWithTheirSentenceAndTravel()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("words.pdf");
        writeTextFixture(
            path, {"Odometry estimates motion. The drift term grows slowly over time. Loop closure fixes it."});
        const auto source = QUrl::fromLocalFile(path);
        // Where "drift" is on the page, as a selection's two ends (PDF points).
        QPdfDocument pdf;
        QCOMPARE(PdfAccess::load(pdf, path), QPdfDocument::Error::None);
        const auto at = pdf.getAllText(0).text().indexOf("drift");
        const auto box = pdf.getSelectionAtIndex(0, int(at), 5).boundingRectangle();
        const QPointF from(box.left() + 1, box.center().y()), to(box.right() - 1, box.center().y());
        QString error;
        ResearchStore mac(directory.filePath("mac"));
        QVERIFY2(mac.initialize(&error), qPrintable(error));
        QVERIFY(mac.rememberDocument(source));
        QSignalSpy saved(&mac, &ResearchStore::wordSaved);
        mac.saveWord({{"source", source}, {"page", 0}, {"from", from}, {"to", to}, {"term", " drift "},
            {"meaning", "**drift** — 표류. Error that adds up."}});
        QVERIFY(saved.wait(10000));
        QCOMPARE(saved.last()[1].toBool(), false);
        auto words = mac.words();
        QCOMPARE(words.size(), 1);
        auto word = words[0].toMap();
        QCOMPARE(word["term"].toString(), QString("drift"));
        QCOMPARE(word["sentence"].toString(), QString("The drift term grows slowly over time."));
        QCOMPARE(word["page"].toInt(), 0);
        QCOMPARE(word["source"].toUrl(), source);
        // The same term in the same paper again: only its meaning changes.
        mac.saveWord({{"source", source}, {"page", 0}, {"from", from}, {"to", to}, {"term", "Drift"},
            {"meaning", "Slowly growing error."}});
        QVERIFY(saved.wait(10000));
        QCOMPARE(saved.last()[1].toBool(), true);
        QCOMPARE(mac.words().size(), 1);
        QCOMPARE(mac.words()[0].toMap()["meaning"].toString(), QString("Slowly growing error."));
        QCOMPARE(mac.words()[0].toMap()["term"].toString(), QString("drift"));
        const auto id = word["id"].toString();
        QVERIFY(mac.setWordMeaning(id, "Error that grows."));
        QCOMPARE(mac.words("grows")[0].toMap()["meaning"].toString(), QString("Error that grows."));
        QCOMPARE(mac.words("closure").size(), 0);
        QCOMPARE(mac.words("words").size(), 1); // its paper's name
        // Removed, and back with Undo.
        QCOMPARE(mac.removeWords({id}), 1);
        QCOMPARE(mac.words().size(), 0);
        QCOMPARE(mac.restoreWords({id}), 1);
        QCOMPARE(mac.words().size(), 1);
        // To another computer through the sync folder; a removal goes too.
        const auto drive = directory.filePath("Drive");
        QVERIFY(QDir().mkpath(drive));
        QCOMPARE(mac.librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
        QVERIFY(mac.librarySync()->syncBlocking().error.isEmpty());
        ResearchStore ubuntu(directory.filePath("ubuntu"));
        QVERIFY2(ubuntu.initialize(&error), qPrintable(error));
        QCOMPARE(ubuntu.librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
        QVERIFY(ubuntu.librarySync()->syncBlocking().error.isEmpty());
        QCOMPARE(ubuntu.words().size(), 1);
        QCOMPARE(ubuntu.words()[0].toMap()["meaning"].toString(), QString("Error that grows."));
        QVERIFY(!ubuntu.words()[0].toMap()["source"].toUrl().isEmpty());
        QCOMPARE(ubuntu.removeWords({id}), 1);
        QVERIFY(ubuntu.librarySync()->syncBlocking().error.isEmpty());
        QVERIFY(mac.librarySync()->syncBlocking().error.isEmpty());
        QCOMPARE(mac.words().size(), 0);
    }
    void wordsExportForSpreadsheetsAndAnki()
    {
        const QVariantList words{
            QVariantMap{{"term", "drift"}, {"meaning", "**drift** — 표류.\nError that \"adds\" up."},
                {"sentence", "The drift term grows, slowly."}, {"paper", "Odometry, 2024"}, {"page", 2},
                {"createdAt", "2026-10-19T01:02:03.000Z"}},
            QVariantMap{{"term", "loop\tclosure"}, {"meaning", "a <b>fix</b>"}, {"sentence", ""}, {"paper", ""},
                {"page", 0}, {"createdAt", "2026-10-18T00:00:00.000Z"}}};
        // CSV: a BOM, a header, every field quoted with its quotes doubled, pages from 1.
        const auto csv = ResearchStore::wordsCsv(words);
        QVERIFY(csv.startsWith("\xEF\xBB\xBF"
                               "term,meaning,sentence,paper,page,saved\r\n"));
        QVERIFY(
            csv.contains(QString("\"drift\",\"**drift** — 표류.\nError that \"\"adds\"\" up.\",\"The drift term grows, "
                                 "slowly.\",\"Odometry, 2024\",3,\"2026-10-19\"\r\n")
                    .toUtf8()));
        // Anki: header lines, then front and back apart by one tab, HTML with no tab or line break inside a card.
        const auto anki = QString::fromUtf8(ResearchStore::wordsAnki(words));
        const auto lines = anki.split('\n', Qt::SkipEmptyParts);
        QCOMPARE(lines.size(), 4);
        QCOMPARE(lines[0], QString("#separator:tab"));
        QCOMPARE(lines[1], QString("#html:true"));
        QCOMPARE(lines[2],
            QString("drift\t<b>drift</b> — 표류.<br>Error that &quot;adds&quot; up.<br><br><i>The drift term "
                    "grows, slowly.</i><br><small>Odometry, 2024, p. 3</small>"));
        QCOMPARE(lines[3], QString("loop closure\ta &lt;b&gt;fix&lt;/b&gt;"));
        // A store writes its words to a file.
        QTemporaryDir directory;
        const auto path = directory.filePath("words.pdf");
        writeTextFixture(path, {"Odometry estimates motion. The drift term grows slowly over time."});
        ResearchStore store(directory.filePath("data"));
        QVERIFY(store.initialize(nullptr));
        QSignalSpy saved(&store, &ResearchStore::wordSaved);
        store.saveWord({{"source", QUrl::fromLocalFile(path)}, {"page", 0}, {"from", QPointF(100, 50)},
            {"to", QPointF(130, 50)}, {"term", "drift"}, {"meaning", "Error that adds up."}});
        QVERIFY(saved.wait(10000));
        const auto out = QUrl::fromLocalFile(directory.filePath("out.csv"));
        QCOMPARE(store.exportWords(out, "csv"), 1);
        QFile written(out.toLocalFile());
        QVERIFY(written.open(QIODevice::ReadOnly));
        QVERIFY(written.readAll().contains("\"drift\",\"Error that adds up.\""));
        QCOMPARE(store.exportWords(out, "pdf"), -1);
    }
    void arxivVersionsAreReadFromTheFeedAndThePage()
    {
        QCOMPARE(ArxivVersions::plainId("2401.12345v3"), QString("2401.12345"));
        QCOMPARE(ArxivVersions::plainId("hep-th/9901001"), QString("hep-th/9901001"));
        QCOMPARE(ArxivVersions::plainId("10.1000/xyz"), QString());
        QCOMPARE(ArxivVersions::versionOf("2401.12345v3"), 3);
        QCOMPARE(ArxivVersions::versionOf("2401.12345"), 0);
        // The stamp arXiv prints in the first page's margin, for this paper only.
        QCOMPARE(ArxivVersions::printedVersion("arXiv:2401.12345v2  [cs.RO]  3 Jan 2024", "2401.12345"), 2);
        QCOMPARE(ArxivVersions::printedVersion("cites arXiv:2310.00001v4", "2401.12345"), 0);
        QCOMPARE(ArxivVersions::printedVersion("2401.12345v5", "2401.12345"), 0);
        const auto entries = ArxivVersions::parseFeed(
            "<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><entry><id>http://arxiv.org/abs/"
            "2401.12345v3</id></entry><entry><id>http://arxiv.org/abs/hep-th/9901001v2</id></entry><entry>"
            "<id>http://arxiv.org/api/errors#incorrect_id_format_for_1234</id></entry></feed>");
        QCOMPARE(entries.size(), 2);
        QCOMPARE(entries[0].id, QString("2401.12345"));
        QCOMPARE(entries[0].version, 3);
        QCOMPARE(entries[1].id, QString("hep-th/9901001"));
        QCOMPARE(entries[1].version, 2);
        // Where it was published, when the authors told arXiv.
        const auto published = ArxivVersions::parseFeed(
            "<feed xmlns=\"http://www.w3.org/2005/Atom\" xmlns:arxiv=\"http://arxiv.org/schemas/atom\"><entry>"
            "<arxiv:journal_ref>IEEE  RA-L 9(2), 2024</arxiv:journal_ref><id>http://arxiv.org/abs/2401.12345v3</id>"
            "<arxiv:doi>10.1109/LRA.2024.1</arxiv:doi></entry></feed>");
        QCOMPARE(published.size(), 1);
        QCOMPARE(published[0].journalRef, QString("IEEE RA-L 9(2), 2024"));
        QCOMPARE(published[0].doi, QString("10.1109/LRA.2024.1"));
        QVERIFY(entries[0].doi.isEmpty());
    }
    void figuresAreFoundByTheirCaptions()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("references.pdf");
        writeReferenceFixture(path);
        ReferenceFinder finder(std::make_shared<std::atomic_bool>(false));
        QSignalSpy found(&finder, &ReferenceFinder::figuresFound);
        const int request = finder.figures(QUrl::fromLocalFile(path));
        QVERIFY(found.wait(10000));
        QCOMPARE(found.last()[0].toInt(), request);
        const auto figures = found.last()[1].toList();
        // "Fig. 2." and "TABLE I" start their lines on page 2; the mentions on page 1 do not.
        QCOMPARE(figures.size(), 2);
        const auto figure = figures[0].toMap(), table = figures[1].toMap();
        QCOMPARE(figure["label"].toString(), QString("Figure 2"));
        QCOMPARE(figure["kind"].toString(), QString("figure"));
        QCOMPARE(figure["page"].toInt(), 1);
        QVERIFY(figure["caption"].toString().contains("Overview of the pipeline"));
        QVERIFY(figure["width"].toDouble() > 0 && figure["height"].toDouble() > 0);
        QCOMPARE(table["label"].toString(), QString("Table I"));
        QCOMPARE(table["kind"].toString(), QString("table"));
        // Asked again for the same file: the same answer.
        finder.figures(QUrl::fromLocalFile(path));
        QVERIFY(found.wait(10000));
        QCOMPARE(found.last()[1].toList(), figures);
    }
    void referencesWithoutLinksPointToTheirTargets()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("paper.pdf");
        writeReferenceFixture(path);
        QPdfDocument pdf;
        QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
        // The middle of a character of `needle` (offset into it) on a page, in PDF points.
        const auto spot = [&pdf](int page, const QString &needle, int offset = 0) {
            const auto text = pdf.getAllText(page).text();
            const auto index = text.indexOf(needle);
            return index < 0 ? QPointF(-1, -1)
                             : pdf.getSelectionAtIndex(page, index + offset, 1).boundingRectangle().center();
        };
        const auto lineTop = [&pdf](int page, const QString &needle) {
            const auto text = pdf.getAllText(page).text();
            return pdf.getSelectionAtIndex(page, text.indexOf(needle), needle.size()).boundingRectangle().top();
        };
        ReferenceFinder finder(std::make_shared<std::atomic_bool>(false));
        QSignalSpy resolved(&finder, &ReferenceFinder::resolved);
        const auto resolve = [&](int page, const QPointF &point) {
            const int request = finder.resolve(QUrl::fromLocalFile(path), page, point);
            for (int i = 0; i < 100; ++i) {
                for (const auto &call : resolved)
                    if (call[0].toInt() == request) return call[1].toMap();
                resolved.wait(100);
            }
            return QVariantMap{{"timeout", true}};
        };
        // A numbered citation goes to its entry; in a list, to the number under the pointer.
        auto target = resolve(0, spot(0, "[2]", 1));
        QCOMPARE(target["label"].toString(), QString("[2]"));
        QCOMPARE(target["page"].toInt(), 2);
        QVERIFY(qAbs(target["y"].toDouble() - lineTop(2, "[2] A. Vaswani")) < 3);
        target = resolve(0, spot(0, "[1, 3]", 4));
        QCOMPARE(target["label"].toString(), QString("[3]"));
        QVERIFY(qAbs(target["y"].toDouble() - lineTop(2, "[3] S. Hochreiter")) < 3);
        // Figures and tables go to their captions (Table 1 is TABLE I), equations to their number.
        target = resolve(0, spot(0, "Fig. 2", 2));
        QCOMPARE(target["kind"].toString(), QString("figure"));
        QCOMPARE(target["page"].toInt(), 1);
        QVERIFY(qAbs(target["y"].toDouble() - lineTop(1, "Fig. 2. Overview")) < 3);
        target = resolve(0, spot(0, "Table 1", 6));
        QCOMPARE(target["page"].toInt(), 1);
        QVERIFY(qAbs(target["y"].toDouble() - lineTop(1, "TABLE I")) < 3);
        target = resolve(0, spot(0, "Eq. (3)", 5));
        QCOMPARE(target["kind"].toString(), QString("equation"));
        QCOMPARE(target["page"].toInt(), 1);
        QVERIFY(qAbs(target["y"].toDouble() - lineTop(1, "(3)")) < 3);
        // Author and year find the entry with that name and year.
        target = resolve(0, spot(0, "Vaswani et al.", 2));
        QCOMPARE(target["kind"].toString(), QString("author"));
        QCOMPARE(target["page"].toInt(), 2);
        QVERIFY(qAbs(target["y"].toDouble() - lineTop(2, "[2] A. Vaswani")) < 3);
        // Plain words and a caption itself are not references.
        QVERIFY(resolve(0, spot(0, "Plain words", 2)).isEmpty());
        QVERIFY(resolve(1, spot(1, "Fig. 2. Overview", 2)).isEmpty());
        // Several papers cited together: each entry, in order, the hovered one marked.
        target = resolve(0, spot(0, "[1, 3]", 1));
        auto entries = target["entries"].toList();
        QCOMPARE(entries.size(), 2);
        QCOMPARE(entries[0].toMap()["label"].toString(), QString("[1]"));
        QVERIFY(entries[0].toMap()["current"].toBool());
        QVERIFY(entries[1].toMap()["text"].toString().contains("Hochreiter"));
        target = resolve(0, spot(0, QString::fromUtf8("[1\u20133]"), 1));
        QCOMPARE(target["entries"].toList().size(), 3);
        QVERIFY(target["entries"].toList()[1].toMap()["text"].toString().contains("Vaswani"));
        target = resolve(0, spot(0, QString::fromUtf8("[1]\u2013[3]"), 5));
        QCOMPARE(target["entries"].toList().size(), 3);
        QCOMPARE(target["label"].toString(), QString("[3]"));
        // Text-only steps.
        QCOMPARE(ReferenceFinder::referenceAt("see [12] here", 5)["key"].toString(), QString("12"));
        QVERIFY(ReferenceFinder::referenceAt("Figure 3: A caption", 2).isEmpty());
        QCOMPARE(ReferenceFinder::referenceAt("in Figure 3 we", 5)["key"].toString(), QString("3"));
        QCOMPARE(ReferenceFinder::referenceAt(QString::fromUtf8("see [12\u201314] here"), 6)["numbers"].toStringList(),
            QStringList({"12", "13", "14"}));
        QCOMPARE(ReferenceFinder::referenceAt("see [1-30]", 6)["numbers"].toStringList().size(), 8);
        // The entry around a point in a reference list (a link's destination).
        const QString list = "References\r\n[1] A. One. 2001.\r\n[2] B. Two, a long\r\ntitle. 2002.\r\n[3] C. Three.";
        auto entry = ReferenceFinder::entryAround(list, list.indexOf("title"));
        QCOMPARE(entry["label"].toString(), QString("[2]"));
        QCOMPARE(list.mid(entry["start"].toInt(), entry["length"].toInt()).trimmed(),
            QString("[2] B. Two, a long\r\ntitle. 2002."));
        QVERIFY(ReferenceFinder::entryAround("No list here.", 3).isEmpty());
    }
    void bundledIconFontAndShaders()
    {
        // The icon font and, when built with Qt ShaderTools, the dark-pages shader are compiled in.
        QFile font(":/owelk/icons/lucide.ttf");
        QVERIFY(font.open(QIODevice::ReadOnly));
        QVERIFY(font.size() > 10000 && font.size() < 100000);
        // The window icon (Linux and Windows title bars).
        QCOMPARE(QImage(":/owelk/app/owelk.png").size(), QSize(512, 512));
        QCOMPARE(QImage(":/owelk/app/owelk-white.png").size(), QSize(512, 512));
        QCOMPARE(QImage(":/owelk/app/owelk-navy.png").size(), QSize(512, 512));
#ifdef OWELK_HAVE_SHADERS
        QFile shader(":/owelk/shaders/invert.frag.qsb");
        QVERIFY(shader.open(QIODevice::ReadOnly));
        QVERIFY(shader.size() > 100);
#endif
    }
    void pictureColorsAndTintedSeeds()
    {
        // A cut-out character: transparent around it, black outlines, a large yellow body, small red cheeks.
        QImage pikachu(200, 200, QImage::Format_ARGB32);
        pikachu.fill(Qt::transparent);
        {
            QPainter p(&pikachu);
            p.setPen(QPen(Qt::black, 4));
            p.setBrush(QColor("#f5dc6e"));
            p.drawEllipse(30, 20, 140, 170);
            p.setPen(Qt::NoPen);
            p.setBrush(QColor("#e0503a"));
            p.drawEllipse(60, 90, 22, 22);
        }
        auto colors = ImagePalette::extract(pikachu);
        QVERIFY(colors.main.isValid());
        QVERIFY(qAbs(colors.main.hslHueF() - QColor("#f5dc6e").hslHueF()) < .02);
        QCOMPARE(colors.swatches.size(), 2);
        QVERIFY(qAbs(colors.swatches[1].hslHueF() - QColor("#e0503a").hslHueF()) < .03);
        // Pale skin over a larger area loses to a smaller area of pink hair; white is never a color.
        QImage girl(100, 100, QImage::Format_ARGB32);
        girl.fill(Qt::white);
        {
            QPainter p(&girl);
            p.fillRect(0, 0, 50, 100, QColor("#f6d5c3"));
            p.fillRect(50, 0, 30, 100, QColor("#f2a0c4"));
        }
        colors = ImagePalette::extract(girl);
        QVERIFY(qAbs(colors.main.hslHueF() - QColor("#f2a0c4").hslHueF()) < .02);
        // Grays only: no main color.
        QImage gray(50, 50, QImage::Format_ARGB32);
        gray.fill(QColor("#808080"));
        QVERIFY(!ImagePalette::extract(gray).main.isValid());
        QVERIFY(!ImagePalette::extract(QImage()).main.isValid());

        // Seeds keep the lightness of Neutral and Dark and lean toward the hue.
        Theme theme;
        const QColor yellow("#f5dc6e");
        for (const bool dark : {false, true}) {
            const auto tinted = theme.tintedSeeds(yellow, dark), plain = theme.seeds(dark ? "dark" : "neutral");
            QCOMPARE(tinted.value("dark").toBool(), dark);
            for (const auto *key : {"window", "sidebar", "content", "raised", "text", "separator", "backdrop"}) {
                const QColor a(tinted.value(key).toString()), b(plain.value(key).toString());
                QVERIFY2(qAbs(a.lightnessF() - b.lightnessF()) < .04, key);
                if (a != b && a.hslSaturationF() > .05) QVERIFY2(qAbs(a.hslHueF() - yellow.hslHueF()) < .06, key);
            }
            QVERIFY(QColor(tinted.value("window").toString()) != QColor(plain.value("window").toString()));
        }
        QCOMPARE(theme.tintedSeeds(QColor(), false), theme.seeds("neutral"));
    }
    void pictureThemeKeepsACopyAndGoesBack()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        Theme theme(&store);
        theme.setTheme("paper");
        theme.setAccentName("green");
        QVERIFY(!theme.usePicture(QUrl::fromLocalFile(directory.filePath("missing.png"))));
        QVERIFY(theme.picture().isEmpty());

        // A cut-out: kept trimmed to the character, its color becomes the theme's.
        QImage cutout(300, 400, QImage::Format_ARGB32);
        cutout.fill(Qt::transparent);
        QPainter(&cutout).fillRect(50, 100, 100, 200, QColor("#f2a0c4"));
        const auto cutoutPath = directory.filePath("character.png");
        QVERIFY(cutout.save(cutoutPath));
        QVERIFY(theme.usePicture(QUrl::fromLocalFile(cutoutPath)));
        QVERIFY(theme.pictureCutout());
        const auto first = theme.picture().toLocalFile();
        QVERIFY(first.startsWith(QDir(store.dataDirectory()).filePath("picture")));
        QCOMPARE(QImage(first).size(), QSize(100, 200));
        QCOMPARE(theme.theme(), QString("custom"));
        QCOMPARE(theme.accentName(), QString("custom"));
        QCOMPARE(theme.pictureColors().size(), 1);
        QVERIFY(qAbs(QColor(theme.pictureColors().first()).hslHueF() - QColor("#f2a0c4").hslHueF()) < .02);
        QCOMPARE(store.setting("appearance.picture"), QFileInfo(first).fileName());
        // Backups keep it, beside the settings that name it.
        QSignalSpy backedUp(&store, &ResearchStore::backupFinished);
        store.backUp(directory.filePath("backups"));
        QTRY_COMPARE_WITH_TIMEOUT(backedUp.size(), 1, 10000);
        QVERIFY(backedUp[0][0].toBool());
        QVERIFY(QFileInfo::exists(backedUp[0][1].toString() + "/picture/" + QFileInfo(first).fileName()));

        // A large photo is kept beside it, no larger than a window shows it, and is the one in use.
        QImage photo(5000, 1000, QImage::Format_RGB32);
        photo.fill(QColor("#3a6ea5"));
        const auto photoPath = directory.filePath("photo.jpg");
        QVERIFY(photo.save(photoPath));
        QVERIFY(theme.usePicture(QUrl::fromLocalFile(photoPath)));
        QVERIFY(!theme.pictureCutout());
        QVERIFY(QFile::exists(first));
        const auto second = theme.picture().toLocalFile();
        QCOMPARE(QImage(second).size(), QSize(2560, 512));
        QCOMPARE(theme.pictures().size(), 2);
        QVERIFY(theme.pictures()[1].toMap()["current"].toBool());
        // The first again, with the accent last chosen for it.
        const auto firstId = QFileInfo(first).fileName(), secondId = QFileInfo(second).fileName();
        QVERIFY(theme.choosePicture(firstId));
        QCOMPARE(theme.picture().toLocalFile(), first);
        QVERIFY(theme.pictureCutout());
        QVERIFY(qAbs(theme.customAccent().hslHueF() - QColor("#f2a0c4").hslHueF()) < .02);
        QVERIFY(theme.setCustomAccent(QColor("#3a6ea5")));
        QVERIFY(theme.choosePicture(secondId));
        QVERIFY(theme.choosePicture(firstId));
        QCOMPARE(theme.customAccent(), QColor("#3a6ea5"));
        // Its size too, for it alone.
        theme.setPictureScale(70);
        QVERIFY(theme.choosePicture(secondId));
        QCOMPARE(theme.pictureScale(), 100);
        QVERIFY(theme.choosePicture(firstId));
        QCOMPARE(theme.pictureScale(), 70);
        QVERIFY(!theme.choosePicture("missing.png"));
        // Read again on the next start.
        {
            Theme again(&store);
            QCOMPARE(again.pictures().size(), 2);
            QCOMPARE(again.picture().toLocalFile(), first);
            QVERIFY(again.pictureCutout());
            QCOMPARE(again.pictureScale(), 70);
        }
        // Another kept picture goes alone; the one in use goes to the next.
        theme.removePicture(secondId);
        QVERIFY(!QFile::exists(second));
        QCOMPARE(theme.pictures().size(), 1);
        QCOMPARE(theme.picture().toLocalFile(), first);
        QVERIFY(theme.usePicture(QUrl::fromLocalFile(photoPath)));
        const auto third = theme.picture().toLocalFile();
        QVERIFY(theme.choosePicture(firstId));
        theme.removePicture();
        QCOMPARE(theme.picture().toLocalFile(), third);
        QCOMPARE(theme.theme(), QString("custom"));

        // Removing the last goes back to the theme and accent from before the first picture.
        theme.removePicture();
        QVERIFY(theme.picture().isEmpty());
        QVERIFY(theme.pictures().isEmpty());
        QVERIFY(!QFile::exists(third));
        QCOMPARE(theme.theme(), QString("paper"));
        QCOMPARE(theme.accentName(), QString("green"));
        QCOMPARE(store.setting("appearance.custom"), QString());
        QCOMPARE(theme.accents().size(), 7);

        // One picture kept before there could be several becomes the first of the list.
        QVERIFY(QImage(cutout).save(QDir(store.dataDirectory()).filePath("picture/picture-1.png")));
        store.setSetting("appearance.pictures", "");
        store.setSetting("appearance.picture", "picture-1.png");
        store.setSetting("appearance.pictureCutout", "1");
        store.setSetting("appearance.pictureColors", "#f2a0c4");
        Theme upgraded(&store);
        QCOMPARE(upgraded.pictures().size(), 1);
        QVERIFY(upgraded.picture().toLocalFile().endsWith("picture-1.png"));
        QCOMPARE(upgraded.pictureColors(), QStringList{"#f2a0c4"});
        QVERIFY(upgraded.pictureCutout());
    }
    void petFacesAreKeptWithTheirPicture()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QVERIFY(store.initialize(nullptr));
        // A cut-out character, and a wider one for its faces (a different color: the picture's colors stay).
        QImage picture(200, 400, QImage::Format_ARGB32), talking(500, 400, QImage::Format_ARGB32);
        picture.fill(Qt::transparent);
        talking.fill(Qt::transparent);
        QPainter(&picture).fillRect(20, 20, 160, 380, QColor("#c03030"));
        QPainter(&talking).fillRect(20, 20, 460, 380, QColor("#3050c0"));
        const auto main = directory.filePath("main.png"), talk = directory.filePath("talk.png");
        QVERIFY(picture.save(main));
        QVERIFY(talking.save(talk));
        const auto folder = QDir(store.dataDirectory()).filePath("picture");
        const auto frames
            = [](Theme &theme, const QString &mood) { return theme.pictureMoods()[mood].toMap()["frames"].toList(); };
        const auto file = [](const QVariant &frame) { return frame.toMap()["url"].toUrl().toLocalFile(); };
        QStringList colors;
        {
            Theme theme(&store);
            QVERIFY(theme.usePicture(QUrl::fromLocalFile(main)));
            colors = theme.pictureColors();
            QVERIFY(theme.pictureMoods().isEmpty());
            QVERIFY(!theme.addPictureMood("smile", QUrl::fromLocalFile(talk)));
            QVERIFY(!theme.addPictureMood("talk", QUrl::fromLocalFile(directory.filePath("missing.png"))));
            QVERIFY(theme.addPictureMood("talk", QUrl::fromLocalFile(talk)));
            QCOMPARE(theme.pictureColors(), colors);
            const auto face = frames(theme, "talk");
            QCOMPARE(face.size(), 1);
            // Kept like the picture: a copy beside it, trimmed to what is drawn.
            QVERIFY(file(face[0]).startsWith(folder));
            QVERIFY(QFileInfo::exists(file(face[0])));
            QCOMPARE(face[0].toMap()["aspect"].toDouble(), 460.0 / 380.0);
            QCOMPARE(theme.pictureMoods()["talk"].toMap()["mode"].toString(), QString("random"));
            QVERIFY(!theme.pictureMoods().contains("think"));
            // Several for thinking, one after another; six at most.
            for (int i = 0; i < 6; ++i)
                QVERIFY(theme.addPictureMood("think", QUrl::fromLocalFile(i % 2 ? talk : main)));
            QVERIFY(!theme.addPictureMood("think", QUrl::fromLocalFile(talk)));
            QCOMPARE(frames(theme, "think").size(), 6);
            theme.setPictureMoodMode("think", "cycle");
            theme.setPictureMoodMode("think", "sideways");
            QCOMPARE(theme.pictureMoods()["think"].toMap()["mode"].toString(), QString("cycle"));
        }
        // Read again at the next launch.
        Theme theme(&store);
        QCOMPARE(frames(theme, "think").size(), 6);
        QCOMPARE(theme.pictureMoods()["think"].toMap()["mode"].toString(), QString("cycle"));
        // One removed: its copy goes, the others stay in order. The last one removed: the mood goes.
        const auto second = file(frames(theme, "think")[1]), third = file(frames(theme, "think")[2]);
        theme.removePictureMood("think", 1);
        QVERIFY(!QFileInfo::exists(second));
        QCOMPARE(file(frames(theme, "think")[1]), third);
        const auto face = file(frames(theme, "talk")[0]);
        theme.removePictureMood("talk", 0);
        QVERIFY(!QFileInfo::exists(face));
        QVERIFY(!theme.pictureMoods().contains("talk"));
        // Faces kept by the first version (one for talking and thinking each) are read as one each.
        auto pictures = QJsonDocument::fromJson(store.setting("appearance.pictures").toUtf8()).array();
        auto kept = pictures[0].toObject();
        kept.remove("moods");
        kept.insert("talk", QFileInfo(third).fileName());
        pictures[0] = kept;
        store.setSetting(
            "appearance.pictures", QString::fromUtf8(QJsonDocument(pictures).toJson(QJsonDocument::Compact)));
        {
            Theme older(&store);
            QCOMPARE(frames(older, "talk").size(), 1);
            QCOMPARE(file(frames(older, "talk")[0]), third);
        }
        // Removing the picture removes all its faces too.
        theme.removePicture();
        QCOMPARE(QDir(folder).entryList(QDir::Files).size(), 0);
    }
    void pictureThemeTurnsOffAndOn()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        Theme theme(&store);
        // The reader's own Custom colors, then another theme.
        auto own = theme.seeds("paper");
        own["window"] = "#123456";
        QVERIFY(theme.setCustomSeeds(own));
        theme.setTheme("paper");
        theme.setAccentName("green");
        QImage cutout(300, 400, QImage::Format_ARGB32);
        cutout.fill(Qt::transparent);
        QPainter(&cutout).fillRect(50, 100, 100, 200, QColor("#f2a0c4"));
        const auto path = directory.filePath("character.png");
        QVERIFY(cutout.save(path));
        QVERIFY(theme.usePicture(QUrl::fromLocalFile(path)));
        QVERIFY(theme.pictureShown());
        const auto file
            = QDir(store.dataDirectory()).filePath("picture/" + theme.pictures()[0].toMap()["id"].toString());

        // Off: the theme, accent and Custom colors from before; the picture is kept, not shown.
        theme.setPictureOn(false);
        QVERIFY(!theme.pictureOn());
        QVERIFY(theme.picture().isEmpty());
        QVERIFY(!theme.pictureShown());
        QCOMPARE(theme.theme(), QString("paper"));
        QCOMPARE(theme.accentName(), QString("green"));
        QCOMPARE(theme.seeds("custom")["window"].toString(), QString("#123456"));
        QCOMPARE(theme.accents().size(), 7);
        QCOMPARE(theme.pictures().size(), 1);
        QVERIFY(QFile::exists(file));
        {
            Theme again(&store);
            QVERIFY(!again.pictureOn());
            QVERIFY(again.picture().isEmpty());
        }
        // On again, from whatever is in use then; off goes back to that.
        theme.setTheme("nord");
        theme.setPictureOn(true);
        QVERIFY(theme.pictureShown());
        QCOMPARE(theme.accentName(), QString("custom"));
        QVERIFY(theme.dark()); // like the theme in use
        theme.setPictureOn(false);
        QCOMPARE(theme.theme(), QString("nord"));
        QCOMPARE(theme.accentName(), QString("green"));
        QCOMPARE(theme.seeds("custom")["window"].toString(), QString("#123456"));
        // Choosing a picture turns it on too.
        QVERIFY(theme.usePicture(QUrl::fromLocalFile(path)));
        QVERIFY(theme.pictureOn());
        QCOMPARE(theme.pictures().size(), 2);
    }
    void petTakesClicksOnlyOnThePicture()
    {
        QTemporaryDir directory;
        // A figure in the middle of a transparent picture.
        QImage cutout(100, 200, QImage::Format_ARGB32);
        cutout.fill(Qt::transparent);
        QPainter(&cutout).fillRect(30, 50, 40, 100, QColor("#f2a0c4"));
        const auto path = directory.filePath("character.png");
        QVERIFY(cutout.save(path));
        // Drawn 12 points down; hops up to 16.
        const auto region = DesktopPet::pictureRegion(path, QSize(100, 200), 12, 16);
        QVERIFY(region.contains(QPoint(50, 12 + 100)));
        QVERIFY2(region.contains(QPoint(28, 12 + 100)), "a little around the edge");
        QVERIFY(!region.contains(QPoint(20, 12 + 100)));
        QVERIFY(!region.contains(QPoint(5, 12 + 5)));
        QVERIFY2(region.contains(QPoint(50, 12 + 50 - 15)), "where it hops to");
        QVERIFY(!region.contains(QPoint(50, 12 + 50 - 25)));
        // Fitted into a smaller area, centred.
        const auto small = DesktopPet::pictureRegion(path, QSize(50, 100), 0, 0);
        QVERIFY(small.contains(QPoint(25, 50)));
        QVERIFY(!small.contains(QPoint(5, 50)));
        // A photo has no transparent part: all of the window takes clicks.
        QImage photo(80, 60, QImage::Format_RGB32);
        photo.fill(Qt::darkCyan);
        const auto photoPath = directory.filePath("photo.jpg");
        QVERIFY(photo.save(photoPath));
        QVERIFY(DesktopPet::pictureRegion(photoPath, QSize(80, 60), 0, 0).isEmpty());
        // Applied to a window (as a shape where the platform passes clicks outside it on).
        QWindow window;
        window.resize(100, 212);
        DesktopPet pet;
        pet.letClicksThrough(&window, QUrl::fromLocalFile(path), QSize(100, 200), 12, 16);
        if (QGuiApplication::platformName() != "cocoa") QCOMPARE(window.mask(), region);
    }
    void markedRegionKeepsFigureCaption()
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
        const auto id = markRegion(store, QUrl::fromLocalFile(path), 0,
            QRectF(95. / size.width(), 115. / size.height(), 310. / size.width(), 210. / size.height()));
        QVERIFY(!id.isEmpty());
        const auto caption = store.anchor(id)["quote"].toMap()["exact"].toString();
        QVERIFY2(caption.startsWith("Figure 2: Occlusion examples"), qPrintable(caption));
        QVERIFY2(caption.contains("after aggregation"), qPrintable(caption));
        QVERIFY(!caption.contains("Unrelated"));
        QCOMPARE(store.searchKnowledge("kitchen scene").value(0).toMap()["kind"].toString(), QString("highlight"));
    }
    void syncKeepsLibrariesTheSameThroughAFolder()
    {
        QTemporaryDir directory;
        const auto drive = directory.filePath("Drive");
        QVERIFY(QDir().mkpath(drive));
        const auto path = directory.filePath("shared.pdf");
        writeFixture(path, "Shared Paper");
        const auto source = QUrl::fromLocalFile(path);
        const auto scalar = [](const ResearchStore &store, const QString &sql) {
            WorkerConnection db(store.dataDirectory() + "/owelk.sqlite3", true);
            QSqlQuery query(db.db);
            return query.exec(sql) && query.next() ? query.value(0) : QVariant();
        };
        const auto annotate = [](ResearchStore &store, const QUrl &paper, const QString &body) {
            QSignalSpy loaded(&store, &ResearchStore::highlightsLoaded),
                done(&store, &ResearchStore::annotationFinished);
            store.loadHighlights(paper);
            QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 1, 10000);
            store.saveAnnotation(paper, 1,
                {{"kind", "text"}, {"body", body}, {"sha256", loaded.last()[4]},
                    {"rectangles", QVariantList{QVariantMap{{"x", .1}, {"y", .2}, {"width", .3}, {"height", .1}}}}});
            QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 10000);
            QVERIFY(done.last()[0].toBool());
        };
        QString error;
        ResearchStore mac(directory.filePath("mac"));
        QVERIFY2(mac.initialize(&error), qPrintable(error));
        QVERIFY(mac.rememberDocument(source));
        QTRY_COMPARE_WITH_TIMEOUT(mac.displayName(source), QString("Shared Paper"), 10000);
        QTRY_VERIFY_WITH_TIMEOUT(!scalar(mac, "SELECT sha256 FROM documents").toString().isEmpty(), 10000);
        const auto sha = scalar(mac, "SELECT sha256 FROM documents").toString();
        annotate(mac, source, "Check the drift term");
        const auto region = markRegion(mac, source);
        QVERIFY(!region.isEmpty());
        const auto note = mac.createNote("Idea", "Radar drift");
        const auto robots = mac.createCollection("Robots");
        QVERIFY(mac.setDocumentCollection(source, robots, true));
        QVERIFY(mac.setReadingState(source, "read"));
        QVERIFY(mac.recordReading(source, "2026-10-01", 120));
        // AI chats travel in their Threads: the paper's own and one made by hand.
        const QVariantMap chat{{"provider", "claude"}, {"model", "m"}};
        auto about = chat;
        about.insert({{"title", "About drift"}, {"source", source}});
        const auto macChat = mac.createAiThread(about);
        const auto looseChat = mac.createAiThread(chat);
        const auto thesis = mac.createAiFolder("Thesis");
        QCOMPARE(mac.moveAiThreads({looseChat}, thesis), 1);
        const auto folderOf = [&](const ResearchStore &store, const QString &id) {
            return scalar(store, "SELECT folder_id FROM ai_threads WHERE id='" + id + "'").toString();
        };
        auto *macSync = mac.librarySync();
        QCOMPARE(macSync->setFolder(QUrl::fromLocalFile(drive)), QString());
        QVERIFY2(macSync->syncBlocking().error.isEmpty(), qPrintable(macSync->status()));
        QVERIFY(QFileInfo::exists(drive + "/Owelk/Papers/" + sha + ".pdf"));

        // A second computer choosing the same folder gets everything, the PDF and images included.
        ResearchStore ubuntu(directory.filePath("ubuntu"));
        QVERIFY2(ubuntu.initialize(&error), qPrintable(error));
        auto *ubuntuSync = ubuntu.librarySync();
        QCOMPARE(ubuntuSync->setFolder(QUrl::fromLocalFile(drive)), QString());
        const auto outcome = ubuntuSync->syncBlocking();
        QVERIFY2(outcome.error.isEmpty(), qPrintable(outcome.error));
        QCOMPARE(outcome.waiting, 0);
        const auto papers = ubuntu.libraryDocuments();
        QCOMPARE(papers.size(), 1);
        const auto copy = papers[0].toMap()["url"].toUrl();
        QVERIFY(copy.toLocalFile().startsWith(ubuntu.dataDirectory() + "/papers/"));
        QVERIFY(QFileInfo::exists(copy.toLocalFile()));
        QCOMPARE(ubuntu.displayName(copy), QString("Shared Paper"));
        QCOMPARE(papers[0].toMap()["readingState"].toString(), QString("read"));
        QCOMPARE(ubuntu.readingSeconds(copy), 120);
        QCOMPARE(ubuntu.note(note)["title"].toString(), QString("Idea"));
        QCOMPARE(ubuntu.collections().size(), 1);
        QCOMPARE(scalar(ubuntu, "SELECT body FROM highlights WHERE kind='text'").toString(),
            QString("Check the drift term"));
        QCOMPARE(scalar(ubuntu, "SELECT count(*) FROM highlights WHERE kind='area' AND deleted_at IS NULL").toInt(), 1);
        QCOMPARE(folderOf(ubuntu, macChat), "document:" + scalar(ubuntu, "SELECT id FROM documents").toString());
        QCOMPARE(folderOf(ubuntu, looseChat), thesis);
        QCOMPARE(scalar(ubuntu, "SELECT name FROM ai_folders WHERE id='" + thesis + "'").toString(), QString("Thesis"));

        // Edits travel back, and of two edits to the same note the later one wins on both. Time read on the
        // same day on two computers adds up.
        QVERIFY(ubuntu.saveNote(note, "Idea from Ubuntu", "Radar drift"));
        QVERIFY(ubuntu.recordReading(copy, "2026-10-01", 60));
        QVERIFY(ubuntuSync->syncBlocking().error.isEmpty());
        QVERIFY(macSync->syncBlocking().error.isEmpty());
        QCOMPARE(mac.note(note)["title"].toString(), QString("Idea from Ubuntu"));
        QCOMPARE(mac.readingSeconds(source), 180);
        QCOMPARE(mac.readingCalendar(400)["days"].toList().size(), 400);
        QVERIFY(mac.saveNote(note, "Older", "x"));
        QTest::qWait(5);
        QVERIFY(ubuntu.saveNote(note, "Newer", "y"));
        for (auto *sync : {macSync, ubuntuSync, macSync}) QVERIFY(sync->syncBlocking().error.isEmpty());
        QCOMPARE(mac.note(note)["title"].toString(), QString("Newer"));
        QCOMPARE(ubuntu.note(note)["title"].toString(), QString("Newer"));
        // Removals travel too; the Mac's own PDF stays where it was.
        QVERIFY(ubuntu.deleteCollection(robots));
        QVERIFY(ubuntuSync->syncBlocking().error.isEmpty());
        QVERIFY(macSync->syncBlocking().error.isEmpty());
        QCOMPARE(mac.collections().size(), 0);
        QCOMPARE(mac.libraryDocuments()[0].toMap()["url"].toUrl(), source);

        // A computer that already had the same PDF ends with one paper holding everybody's notes.
        const auto own = directory.filePath("own copy.pdf");
        QVERIFY(QFile::copy(path, own));
        ResearchStore laptop(directory.filePath("laptop"));
        QVERIFY2(laptop.initialize(&error), qPrintable(error));
        QVERIFY(laptop.rememberDocument(QUrl::fromLocalFile(own)));
        QTRY_VERIFY_WITH_TIMEOUT(!scalar(laptop, "SELECT sha256 FROM documents").toString().isEmpty(), 10000);
        annotate(laptop, QUrl::fromLocalFile(own), "Laptop remark");
        QVERIFY(laptop.recordReading(QUrl::fromLocalFile(own), "2026-10-01", 30));
        about.insert("source", QUrl::fromLocalFile(own));
        const auto laptopChat = laptop.createAiThread(about);
        QCOMPARE(laptop.librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
        QVERIFY(laptop.librarySync()->syncBlocking().error.isEmpty());
        for (auto *store : {&laptop, &mac}) {
            if (store == &mac) QVERIFY(macSync->syncBlocking().error.isEmpty());
            QCOMPARE(store->libraryDocuments().size(), 1);
            QCOMPARE(scalar(*store, "SELECT count(*) FROM documents").toInt(), 1);
            QCOMPARE(scalar(*store, "SELECT count(*) FROM highlights WHERE deleted_at IS NULL").toInt(), 3);
            QCOMPARE(
                scalar(*store, "SELECT count(*) FROM highlights h JOIN documents d ON d.id=h.document_id").toInt(), 3);
            QCOMPARE(store->readingSeconds(store->libraryDocuments()[0].toMap()["url"].toUrl()), 210);
        }
        QCOMPARE(laptop.libraryDocuments()[0].toMap()["url"].toUrl(), QUrl::fromLocalFile(own));
        QCOMPARE(scalar(laptop, "SELECT id FROM documents"), scalar(mac, "SELECT id FROM documents"));
        // The paper's Thread merges with it: one Thread, holding the laptop's chat too.
        const auto paperThread = "document:" + scalar(mac, "SELECT id FROM documents").toString();
        QCOMPARE(folderOf(laptop, laptopChat), paperThread);
        QCOMPARE(scalar(laptop, "SELECT count(*) FROM ai_folders WHERE id LIKE 'document:%'").toInt(), 1);
        // A removed annotation is removed on the others too, even when they merge the papers in the same
        // pass as they read the removal.
        QVERIFY(mac.removeHighlight(region));
        QVERIFY(macSync->syncBlocking().error.isEmpty());
        QVERIFY(ubuntuSync->syncBlocking().error.isEmpty());
        QCOMPARE(scalar(ubuntu, "SELECT count(*) FROM highlights WHERE kind='area' AND deleted_at IS NULL").toInt(), 0);
        // Once everything has gone round, a pass neither sends nor receives anything.
        for (int round = 0; round < 2; ++round)
            for (auto *sync : {macSync, ubuntuSync, laptop.librarySync()})
                QVERIFY(sync->syncBlocking().error.isEmpty());
        for (auto *sync : {macSync, ubuntuSync, laptop.librarySync()}) {
            const auto quiet = sync->syncBlocking();
            QCOMPARE(quiet.sent, 0);
            QCOMPARE(quiet.received, 0);
        }
        QCOMPARE(scalar(ubuntu, "SELECT count(*) FROM documents").toInt(), 1);
        for (auto *store : {&mac, &ubuntu, &laptop})
            QCOMPARE(store->readingSeconds(store->libraryDocuments()[0].toMap()["url"].toUrl()), 210);
        for (auto *store : {&mac, &ubuntu}) {
            QCOMPARE(folderOf(*store, laptopChat), paperThread);
            QCOMPARE(scalar(*store, "SELECT count(*) FROM ai_folders WHERE id LIKE 'document:%'").toInt(), 1);
        }
    }
    void syncPassesOverAChangeItCannotApply()
    {
        QTemporaryDir directory;
        const auto drive = directory.filePath("Drive");
        QVERIFY(QDir().mkpath(drive));
        QString error;
        ResearchStore mac(directory.filePath("mac"));
        QVERIFY2(mac.initialize(&error), qPrintable(error));
        auto *sync = mac.librarySync();
        QCOMPARE(sync->setFolder(QUrl::fromLocalFile(drive)), QString());
        QVERIFY(sync->syncBlocking().error.isEmpty());
        // Another computer's changes: one this computer cannot apply (a tag without a name), then a note.
        QVERIFY(QDir().mkpath(drive + "/Owelk/devices/other"));
        const auto now = QDateTime::currentMSecsSinceEpoch();
        const auto stamp = QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
        const auto line = [&](const QString &table, const QString &id, const QJsonObject &row) {
            return QJsonDocument(
                       QJsonObject{{"t", table}, {"k", QJsonArray{id}}, {"v", now}, {"d", "other"}, {"r", row}})
                       .toJson(QJsonDocument::Compact)
                + '\n';
        };
        QFile log(drive + "/Owelk/devices/other/00000001.jsonl");
        QVERIFY(log.open(QIODevice::WriteOnly));
        log.write(line("tags", "broken", {{"id", "broken"}, {"name", QJsonValue::Null}})
            + line("notes", "elsewhere",
                {{"id", "elsewhere"}, {"title", "From elsewhere"}, {"body", "b"}, {"created_at", stamp},
                    {"updated_at", stamp}, {"deleted_at", QJsonValue::Null}}));
        log.close();
        QVERIFY(!mac.createNote("Mine", "x").isEmpty());
        // The note arrives and this computer's own change goes out; the other is passed over, counted once.
        const auto outcome = sync->syncBlocking();
        QVERIFY2(outcome.error.isEmpty(), qPrintable(outcome.error));
        QCOMPARE(outcome.skipped, 1);
        QVERIFY(outcome.sent > 0);
        QCOMPARE(mac.note("elsewhere")["title"].toString(), QString("From elsewhere"));
        QCOMPARE(sync->syncBlocking().skipped, 0);
    }
    void syncGoesOnFromWhereAStoppedPassLeftOff()
    {
        QTemporaryDir directory;
        const auto drive = directory.filePath("Drive");
        QVERIFY(QDir().mkpath(drive));
        QString error;
        ResearchStore mac(directory.filePath("mac"));
        QVERIFY2(mac.initialize(&error), qPrintable(error));
        auto *sync = mac.librarySync();
        QCOMPARE(sync->setFolder(QUrl::fromLocalFile(drive)), QString());
        QVERIFY(sync->syncBlocking().error.isEmpty());
        QVERIFY(QDir().mkpath(drive + "/Owelk/devices/other"));
        const auto now = QDateTime::currentMSecsSinceEpoch();
        const auto stamp = QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
        const auto notes = [&](int first, int count) {
            QByteArray lines;
            for (int n = first; n < first + count; ++n) {
                const auto id = "n" + QString::number(n);
                lines += QJsonDocument(
                             QJsonObject{{"t", "notes"}, {"k", QJsonArray{id}}, {"v", now}, {"d", "other"},
                                 {"r",
                                     QJsonObject{{"id", id}, {"title", id}, {"body", "b"}, {"created_at", stamp},
                                         {"updated_at", stamp}, {"deleted_at", QJsonValue::Null}}}})
                             .toJson(QJsonDocument::Compact)
                    + '\n';
            }
            return lines;
        };
        const auto write = [&](const QString &name, const QByteArray &lines) {
            QFile log(drive + "/Owelk/devices/other/" + name);
            return log.open(QIODevice::WriteOnly) && log.write(lines) == lines.size();
        };
        const auto seen = [&](const QString &name) {
            WorkerConnection db(mac.dataDirectory() + "/owelk.sqlite3", true);
            QSqlQuery query(db.db);
            query.prepare("SELECT size,lines,(SELECT count(*) FROM sync_pause) FROM sync_seen WHERE file=?");
            query.addBindValue(name);
            return query.exec() && query.next()
                ? QList<qint64>{query.value(0).toLongLong(), query.value(1).toLongLong(), query.value(2).toLongLong()}
                : QList<qint64>{};
        };
        // A pass stopped after two of four lines (Owelk quit): the file is marked as read that far, with no size.
        const auto four = notes(0, 4);
        QVERIFY(write("00000001.jsonl", four));
        {
            WorkerConnection db(mac.dataDirectory() + "/owelk.sqlite3");
            QSqlQuery query(db.db);
            QVERIFY(query.exec("INSERT INTO sync_seen(device,file,size,lines) VALUES('other','00000001.jsonl',-1,2)"));
        }
        // The next pass reads on from the third line, and records the whole file as read.
        QVERIFY(sync->syncBlocking().error.isEmpty());
        QVERIFY(mac.note("n1").isEmpty());
        QCOMPARE(mac.note("n2")["title"].toString(), QString("n2"));
        QCOMPARE(mac.note("n3")["title"].toString(), QString("n3"));
        QCOMPARE(seen("00000001.jsonl"), (QList<qint64>{four.size(), 4, 0}));
        // A long file is saved in parts (200 changes each) and all of it arrives.
        const auto many = notes(100, 450);
        QVERIFY(write("00000002.jsonl", many));
        QVERIFY(sync->syncBlocking().error.isEmpty());
        QCOMPARE(mac.note("n100")["title"].toString(), QString("n100"));
        QCOMPARE(mac.note("n549")["title"].toString(), QString("n549"));
        QCOMPARE(seen("00000002.jsonl"), (QList<qint64>{many.size(), 450, 0}));
        // This computer's own edits still go out afterwards (nothing was left paused).
        QVERIFY(!mac.createNote("Mine", "x").isEmpty());
        QVERIFY(sync->syncBlocking().sent > 0);
    }
    void syncReadsEverythingAgainAfterAnUpdate()
    {
        QTemporaryDir directory;
        const auto drive = directory.filePath("Drive");
        QVERIFY(QDir().mkpath(drive));
        QString error;
        ResearchStore mac(directory.filePath("mac")), ubuntu(directory.filePath("ubuntu"));
        QVERIFY2(mac.initialize(&error) && ubuntu.initialize(&error), qPrintable(error));
        const auto note = mac.createNote("Kept title", "body");
        for (auto *store : {&mac, &ubuntu}) {
            QCOMPARE(store->librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
            QVERIFY(store->librarySync()->syncBlocking().error.isEmpty());
        }
        QCOMPARE(ubuntu.note(note)["title"].toString(), QString("Kept title"));
        // An older Owelk passed over a column it did not know; then it was updated.
        {
            WorkerConnection db(ubuntu.dataDirectory() + "/owelk.sqlite3");
            QSqlQuery query(db.db);
            for (const auto *sql : {"INSERT INTO sync_pause(paused) VALUES(1)", "UPDATE notes SET title=''",
                     "DELETE FROM sync_pause", "UPDATE settings SET value='17' WHERE key='sync.schema'"})
                QVERIFY2(query.exec(sql), qPrintable(query.lastError().text()));
        }
        QVERIFY(ubuntu.librarySync()->syncBlocking().error.isEmpty());
        QCOMPARE(ubuntu.note(note)["title"].toString(), QString("Kept title"));
        // Read again once, not on every pass.
        QCOMPARE(ubuntu.librarySync()->syncBlocking().received, 0);
    }
    void restoredLibraryCatchesUpThroughSync()
    {
        QTemporaryDir directory;
        const auto drive = directory.filePath("Drive");
        QVERIFY(QDir().mkpath(drive));
        const auto data = directory.filePath("mac");
        const auto device = [&] {
            WorkerConnection db(data + "/owelk.sqlite3", true);
            QSqlQuery query(db.db);
            return query.exec("SELECT value FROM settings WHERE key='sync.device'") && query.next()
                ? query.value(0).toString()
                : QString();
        };
        QString error, note, before;
        {
            ResearchStore mac(data);
            QVERIFY2(mac.initialize(&error), qPrintable(error));
            note = mac.createNote("Before", "x");
            QCOMPARE(mac.librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
            QVERIFY(mac.librarySync()->syncBlocking().error.isEmpty());
            QSignalSpy done(&mac, &ResearchStore::backupFinished);
            mac.backUp(directory.filePath("backups"));
            QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 10000);
            QVERIFY(done[0][0].toBool());
            // This computer changes the note after the backup and sends it; then the backup is restored.
            QVERIFY(mac.saveNote(note, "After", "x"));
            QVERIFY(mac.librarySync()->syncBlocking().error.isEmpty());
            before = device();
            QVERIFY(mac.scheduleRestore(done[0][1].toString()));
        }
        ResearchStore restored(data);
        QVERIFY2(restored.initialize(&error), qPrintable(error));
        QVERIFY2(restored.startupMessage().contains("Sync now brings"), qPrintable(restored.startupMessage()));
        QVERIFY(!QFileInfo::exists(data + "/restore-pending"));
        QCOMPARE(restored.note(note)["title"].toString(), QString("Before"));
        // It joins as a new computer and catches up with everyone, its own change since the backup included.
        QVERIFY(restored.librarySync()->syncBlocking().error.isEmpty());
        QCOMPARE(restored.note(note)["title"].toString(), QString("After"));
        QVERIFY(!device().isEmpty() && device() != before);
    }
    void syncKeepsFileNamesFromTheFolderInPlace()
    {
        QTemporaryDir directory;
        const auto drive = directory.filePath("Drive");
        QVERIFY(QDir().mkpath(drive));
        QString error;
        ResearchStore mac(directory.filePath("mac"));
        QVERIFY2(mac.initialize(&error), qPrintable(error));
        auto *sync = mac.librarySync();
        QCOMPARE(sync->setFolder(QUrl::fromLocalFile(drive)), QString());
        QVERIFY(sync->syncBlocking().error.isEmpty());
        // A row naming its image "../escaped.png" (written by hand or by a broken program) must not reach a file
        // outside the annotation images.
        QVERIFY(QDir().mkpath(drive + "/Owelk/devices/other") && QDir().mkpath(drive + "/Owelk/Files"));
        QFile planted(drive + "/Owelk/Files/escaped.png");
        QVERIFY(planted.open(QIODevice::WriteOnly) && planted.write("x") == 1);
        planted.close();
        const auto stamp = QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
        const QJsonObject row{{"id", "h1"}, {"document_id", "d1"}, {"sha256", "x"}, {"page", 0}, {"text", ""},
            {"rectangles", "[]"}, {"start_index", -1}, {"end_index", -1}, {"created_at", stamp}, {"kind", "image"},
            {"image", "../escaped.png"}};
        QFile log(drive + "/Owelk/devices/other/00000001.jsonl");
        QVERIFY(log.open(QIODevice::WriteOnly));
        log.write(QJsonDocument(QJsonObject{{"t", "highlights"}, {"k", QJsonArray{"h1"}},
                                    {"v", QDateTime::currentMSecsSinceEpoch()}, {"d", "other"}, {"r", row}})
                      .toJson(QJsonDocument::Compact)
            + '\n');
        log.close();
        QVERIFY(sync->syncBlocking().error.isEmpty());
        QVERIFY(sync->syncBlocking().error.isEmpty());
        QVERIFY(!QFileInfo::exists(mac.dataDirectory() + "/escaped.png"));
    }
    void markdownShowsMathAsImages()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        const auto html = store.markdownHtml("Energy $E=mc^2$ with $a_1 \\cdot b_2$ and\n\n$$\\frac{a}{b}$$\n\n"
                                             "Cost $5 and $10, `$PATH`, \\$x\\$ and $$still open",
            "#3366cc", "#202020", 14);
        // Three formulas become images (the display one centred); _ inside math is not emphasis.
        QCOMPARE(html.count("image://math/"), 3);
        QVERIFY(html.contains("align=\"center\""));
        QVERIFY(!html.contains("<em>") && !html.contains("font-style:italic"));
        // Prices, code, escaped dollars and an unclosed formula stay text.
        QVERIFY(html.contains("$5 and $10"));
        QVERIFY(html.contains("$PATH"));
        QVERIFY(html.contains("$x$"));
        QVERIFY(html.contains("$$still open"));
        // The images are real drawings in the text colour, at twice the shown size.
        static const QRegularExpression image(R"re(image://math/(\w+)" width="(\d+)" height="(\d+)")re");
        const auto m = image.match(html);
        QVERIFY(m.hasMatch());
        const auto drawn = MathRenderer::cached(m.captured(1));
        QVERIFY(!drawn.isNull());
        QCOMPARE(drawn.width(), m.captured(2).toInt() * 2);
        bool inked = false;
        for (int y = 0; y < drawn.height() && !inked; ++y)
            for (int x = 0; x < drawn.width() && !inked; ++x) inked = qAlpha(drawn.pixel(x, y)) > 128;
        QVERIFY(inked);
        // A formula that would be drawn enormous is not drawn at all.
        QSize huge;
        QVERIFY(MathRenderer::render("\\rule{2000cm}{1cm}", false, 14, Qt::black, &huge).isEmpty());
        QVERIFY(!MathRenderer::render("\\rule{2cm}{1cm}", false, 14, Qt::black, &huge).isEmpty());
        // Copied or quoted, the formulas come back as LaTeX.
        const auto plain = store.plainTextWithMath(html);
        QVERIFY(plain.contains("$E=mc^2$"));
        QVERIFY(plain.contains("$$\\frac{a}{b}$$"));
        QVERIFY(plain.contains("Energy"));
        // Without math the HTML is what Qt makes of the Markdown.
        QVERIFY(!store.markdownHtml("Plain **text**", "#3366cc").contains("image://"));
        // Pictures on the web are never fetched (an AI answer could carry words away in the address): their
        // alt text stays.
        const auto remote = store.markdownHtml(
            "See ![the chart](https://example.com/c.png?q=secret) and ![x][r]\n\n[r]: https://example.com/d.png",
            "#3366cc");
        QVERIFY(!remote.contains("<img") && !remote.contains("example.com"));
        QVERIFY(remote.contains("the chart"));
    }
    void quotedPassagesAreFoundOnTheirPage()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("quoted.pdf");
        writeFixture(path, "Quoted Paper");
        QPdfDocument pdf;
        QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
        // Line 4 of page 2 is at y = 189 + 3 * 20 points on an A4 page (842 points high).
        const auto region = ResearchStore::passageRegion(pdf, 1, "Research finding 2.4: occlusion links observation");
        QVERIFY(!region.isEmpty());
        QVERIFY(region.y() > 0.27 && region.y() < 0.31);
        // Case, quotes and a changed ending still find the place; text from another page does not.
        QVERIFY(
            !ResearchStore::passageRegion(pdf, 1, "\u201cresearch FINDING 2.4: occlusion links something else\u201d")
                .isEmpty());
        QVERIFY(ResearchStore::passageRegion(pdf, 1, "Research finding 5.4: occlusion links observation").isEmpty());
        QVERIFY(ResearchStore::passageRegion(pdf, 9, "Research finding").isEmpty());
    }
    void figurePreviewsCoverTheFigureAndItsCaption()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("figure.pdf");
        writeFixture(path, "Figure Paper");
        QPdfDocument pdf;
        QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
        // The fixture: body text down to y ~ 392, the chart at 430-595, the caption line at ~613-626,
        // then more text at 678.
        const auto all = pdf.getAllText(0).text();
        const auto at = all.indexOf("Figure 1.");
        QVERIFY(at >= 0);
        const auto caption = pdf.getSelectionAtIndex(0, int(at), 20).boundingRectangle();
        QVERIFY(!caption.isEmpty());
        const auto region = ReferenceFinder::floatRegion(pdf, 0, caption, false);
        QVERIFY(!region.isEmpty());
        const QRectF area(
            region["x"].toDouble(), region["y"].toDouble(), region["width"].toDouble(), region["height"].toDouble());
        QVERIFY2(area.top() > 380 && area.top() < 430, qPrintable(QString::number(area.top())));
        QVERIFY2(area.bottom() >= caption.bottom() && area.bottom() < 660, qPrintable(QString::number(area.bottom())));
        QVERIFY2(
            area.left() < 40 && area.right() > 340, qPrintable(QString("%1 %2").arg(area.left()).arg(area.right())));
        QVERIFY2(region["caption"].toString().startsWith("Figure 1. Capture this chart"),
            qPrintable(region["caption"].toString()));
    }
    void explainFindsTheObjectUnderThePointer()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("objects.pdf");
        writeFixture(path, "Object Paper", 1);
        QPdfDocument pdf;
        QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
        // Inside the chart (430-595) and on its caption: the figure with its caption.
        for (const auto &point : {QPointF(250, 500), QPointF(120, 620)}) {
            const auto figure = ReferenceFinder::findObject(pdf, 0, point);
            QCOMPARE(figure["kind"].toString(), QString("figure"));
            QCOMPARE(figure["label"].toString(), QString("Figure 1"));
            QCOMPARE(figure["page"].toInt(), 0);
        }
        // Running text is no object.
        QVERIFY(ReferenceFinder::findObject(pdf, 0, QPointF(120, 230)).isEmpty());

        // A displayed equation between paragraphs, and an algorithm with its steps.
        const auto mathPath = directory.filePath("math.pdf");
        {
            QPdfWriter writer(mathPath);
            writer.setPageSize(QPageSize(QPageSize::A4));
            writer.setResolution(72);
            QPainter painter(&writer);
            painter.setFont(QFont("Helvetica", 11));
            painter.drawText(35, 100, "The state is propagated with the motion model of the robot as follows:");
            painter.drawText(150, 140, QString::fromUtf8("x = A x + B u + w"));
            painter.drawText(500, 140, "(2)");
            painter.drawText(35, 180, "where the noise term is drawn from a zero mean Gaussian distribution here.");
            painter.drawText(35, 260, "Algorithm 1 Frontier Selection");
            painter.drawText(35, 280, "Require: frontier set F, robot position p");
            painter.drawText(35, 298, "1: for each frontier f in F do");
            painter.drawText(35, 316, "2: score f by distance");
            painter.drawText(35, 334, "3: end for");
            painter.drawText(
                35, 400, "After the selection the robot moves to the best frontier and the map is updated.");
            painter.drawText(35, 418, "This continues until the goal object is found or the time budget is spent.");
        }
        QPdfDocument math;
        QCOMPARE(math.load(mathPath), QPdfDocument::Error::None);
        // Points on the words themselves (the writer adds page margins).
        const auto text = math.getAllText(0).text();
        const auto at = [&](const QString &words) {
            return math.getSelectionAtIndex(0, int(text.indexOf(words)), int(words.size()))
                .boundingRectangle()
                .center();
        };
        const auto equation = ReferenceFinder::findObject(math, 0, at("B u"));
        QCOMPARE(equation["kind"].toString(), QString("equation"));
        QCOMPARE(equation["label"].toString(), QString("Equation (2)"));
        const QRectF box(equation["x"].toDouble(), equation["y"].toDouble(), equation["width"].toDouble(),
            equation["height"].toDouble());
        QVERIFY(box.contains(at("(2)")) && box.contains(at("x = A")));
        QVERIFY(box.bottom() < at("where the noise").y() && box.top() > at("The state").y());
        const auto algorithm = ReferenceFinder::findObject(math, 0, at("score f"));
        QCOMPARE(algorithm["kind"].toString(), QString("algorithm"));
        QCOMPARE(algorithm["label"].toString(), QString("Algorithm 1"));
        const QRectF steps(algorithm["x"].toDouble(), algorithm["y"].toDouble(), algorithm["width"].toDouble(),
            algorithm["height"].toDouble());
        QVERIFY(steps.contains(at("Algorithm 1")) && steps.contains(at("3: end")));
        QVERIFY(!steps.contains(at("After the selection")));
        QVERIFY(ReferenceFinder::findObject(math, 0, at("propagated with")).isEmpty());
    }
    void twoColumnPagesKeepObjectsInTheirColumn()
    {
        // A two-column page: body text on the left beside an algorithm on the right, line for line (their
        // lines once ran together across the gutter), then two figures and a table caption side by side.
        QTemporaryDir directory;
        const auto path = directory.filePath("columns.pdf");
        {
            QPdfWriter writer(path);
            writer.setPageSize(QPageSize(QPageSize::A4));
            writer.setResolution(72);
            QPainter painter(&writer);
            painter.setFont(QFont("Helvetica", 9));
            // Column by column, as typesetting writes them.
            for (int line = 0; line < 22; ++line)
                painter.drawText(
                    30, 60 + line * 12, QString("Body text of the left column, line %1 here.").arg(line + 1));
            for (int line = 0; line < 22; ++line) {
                if (line == 0)
                    painter.drawText(300, 60, "Algorithm 1 Frontier Selection");
                else if (line == 1)
                    painter.drawText(300, 72, "Require: frontier set F");
                else
                    painter.drawText(
                        300 + (line % 3) * 8, 60 + line * 12, QString("%1: x%1 = step(x, %1)").arg(line - 1));
            }
            painter.drawText(30, 360, "After the steps the paper goes on in the left column as usual text.");
            painter.fillRect(QRect(40, 400, 220, 120), QColor("#bbbbbb"));
            painter.drawText(30, 540, "Fig. 6: The left figure.");
            painter.fillRect(QRect(310, 400, 220, 90), QColor("#bbbbbb"));
            painter.drawText(300, 510, "Fig. 8: The right figure.");
            painter.drawText(300, 530, "TABLE IV: The right table");
            painter.drawText(300, 548, "Method   Error   Time");
            painter.drawText(300, 562, "Ours     0.10    12");
            painter.fillRect(QRect(40, 570, 220, 80), QColor("#bbbbbb"));
            painter.drawText(30, 666, "Fig. 7: Another left figure.");
            for (int line = 0; line < 6; ++line)
                painter.drawText(
                    300, 600 + line * 12, QString("More text of the right column, line %1 here.").arg(line + 1));
        }
        QPdfDocument pdf;
        QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
        const auto text = pdf.getAllText(0).text();
        const auto at = [&](const QString &words) {
            return pdf.getSelectionAtIndex(0, int(text.indexOf(words)), int(words.size())).boundingRectangle().center();
        };
        const auto label
            = [&](const QPointF &point) { return ReferenceFinder::findObject(pdf, 0, point)["label"].toString(); };
        // Every step of the algorithm, also the last ones beside the body text.
        QCOMPARE(label(at("1: x1")), QString("Algorithm 1"));
        QCOMPARE(label(at("19: x19")), QString("Algorithm 1"));
        QVERIFY(label(at("line 20 here")).isEmpty());
        // Each figure in its own column; a table's title is the table's.
        const auto rightFigure = at("Fig. 8") - QPointF(-60, 60);
        QCOMPARE(label(rightFigure), QString("Figure 8"));
        QCOMPARE(label(at("Fig. 6") - QPointF(-60, 60)), QString("Figure 6"));
        QCOMPARE(label(at("TABLE IV")), QString("Table IV"));
        QCOMPARE(label(at("Ours")), QString("Table IV"));
        QCOMPARE(label(at("Fig. 7") - QPointF(-60, 40)), QString("Figure 7"));
    }
    void wordsUnderThePointerAreFoundAcrossTheWholeGlyph()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("symbols.pdf");
        {
            QPdfWriter writer(path);
            writer.setResolution(72);
            QPainter painter(&writer);
            painter.setFont(QFont("Helvetica", 28));
            painter.drawText(40, 80, QString::fromUtf8("x ⊞ δx and y"));
        }
        QPdfDocument pdf;
        QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
        const auto text = pdf.getAllText(0).text();
        const auto box = [&](const QString &part) {
            return pdf.getSelectionAtIndex(0, int(text.indexOf(part)), int(part.size())).boundingRectangle();
        };
        ReferenceFinder finder(std::make_shared<std::atomic_bool>(false));
        QSignalSpy found(&finder, &ReferenceFinder::wordFound);
        const auto source = QUrl::fromLocalFile(path);
        const auto wordAt = [&](const QPointF &point) {
            const auto before = found.size();
            finder.wordAt(source, 0, point, 1);
            [&] { QTRY_COMPARE_WITH_TIMEOUT(found.size(), before + 1, 5000); }();
            return found.last().at(1).toMap();
        };
        // Anywhere on the glyph: its middle, near its left edge, near its top (a short selection used to
        // find a character only at the glyph's right edge).
        const auto symbol = box(QString::fromUtf8("⊞"));
        QVERIFY(!symbol.isEmpty());
        for (const auto &point : {symbol.center(), QPointF(symbol.left() + 1, symbol.center().y()),
                 QPointF(symbol.center().x(), symbol.top() + 1)})
            QCOMPARE(wordAt(point)["glyph"].toString(), QString::fromUtf8("⊞"));
        QCOMPARE(wordAt(box("δx").center())["word"].toString(), QString::fromUtf8("δx"));
        // Off the text by more than the tolerance: nothing.
        QVERIFY(wordAt(QPointF(symbol.center().x(), symbol.bottom() + 20)).isEmpty());
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
        const auto region = markRegion(store, source, 1);
        QVERIFY(!region.isEmpty());
        const auto paper = store.documentLinkId(source);
        // A note body links with owelk:// URLs; saving keeps the link table in sync.
        const auto ideas = store.createNote("Ideas", "See " + store.markdownLink("document", paper));
        QVERIFY(!ideas.isEmpty());
        QVERIFY(store.markdownLink("document", paper).contains("Linked Paper"));
        QCOMPARE(store.backlinks("document", paper).size(), 1);
        // A save that keeps a link leaves it as it was (when it was made, and nothing to send to other computers).
        const auto madeAt = [&] {
            WorkerConnection db(store.dataDirectory() + "/owelk.sqlite3", true);
            QSqlQuery query(db.db);
            return query.exec("SELECT created_at FROM links WHERE from_id='" + ideas + "'") && query.next()
                ? query.value(0).toString()
                : QString();
        };
        const auto made = madeAt();
        QVERIFY(!made.isEmpty());
        QTest::qWait(5);
        QVERIFY(store.saveNote(ideas, "Ideas", "See " + store.markdownLink("document", paper) + " and more"));
        QCOMPARE(madeAt(), made);
        const auto other = store.createNote("Other", "");
        QVERIFY(store.appendNoteLink(other, "highlight", region));
        QVERIFY(store.appendNoteLink(other, "highlight", region)); // Idempotent.
        QCOMPARE(store.note(other)["body"].toString().count("owelk://highlight/"), 1);
        // A paper's backlinks include notes that link to its annotations.
        QCOMPARE(store.backlinks("document", paper).size(), 2);
        QCOMPARE(store.backlinks("highlight", region)[0].toMap()["id"].toString(), other);
        QVERIFY(store.saveNote(ideas, "Ideas", "no links now"));
        QCOMPARE(store.backlinks("document", paper).size(), 1);
        // Search, link candidates and trash.
        QCOMPARE(store.searchKnowledge("no links now").value(0).toMap()["kind"].toString(), QString("note"));
        const auto linkedCandidates = store.linkCandidates("Linked");
        QVERIFY(std::any_of(linkedCandidates.cbegin(), linkedCandidates.cend(),
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
        QVERIFY(store.backlinks("highlight", region).isEmpty());
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
        const auto visualHits = store.searchKnowledge("visual");
        QVERIFY(std::any_of(visualHits.cbegin(), visualHits.cend(),
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
        // What the extra entry was filed under moves to the copy kept.
        const auto shelf = store.createCollection("Shelf");
        QVERIFY(store.setDocumentCollection(second, shelf, true));
        QVERIFY(store.setDocumentTags(second, {"twin"}));
        QVERIFY(store.useExistingCopy(second, first));
        QCOMPARE(store.documentOrganization(first)["collections"].toStringList(), QStringList{shelf});
        QCOMPARE(store.documentOrganization(first)["tags"].toStringList(), QStringList{"twin"});
        QCOMPARE(store.recentDocuments().size(), 1);
        QCOMPARE(store.recentDocuments()[0].toMap()["url"].toUrl(), first);
        QVERIFY(QFileInfo::exists(copy)); // Files are never touched.
    }
    void doubleAndTripleClicksTakeAWordAndASentence()
    {
        // Text-only steps: a word stops at spaces and punctuation; a sentence at . ! ? that end one.
        const QString text = "See Fig. 3 for approx. ten runs, e.g. the best one. A third (one) ends here! Next";
        const auto at = [&](const QString &needle) { return text.indexOf(needle); };
        const auto word = ReferenceFinder::wordBounds(text, at("approx") + 2);
        QCOMPARE(text.mid(word.first, word.second - word.first), QString("approx"));
        QCOMPARE(ReferenceFinder::wordBounds(text, at(",")).first, qsizetype(-1));
        const auto first = ReferenceFinder::sentenceBounds(text, at("ten"));
        QCOMPARE(text.mid(first.first, first.second - first.first),
            QString("See Fig. 3 for approx. ten runs, e.g. the best one."));
        const auto second = ReferenceFinder::sentenceBounds(text, at("third"));
        QCOMPARE(text.mid(second.first, second.second - second.first), QString("A third (one) ends here!"));
        const QString apostrophe = "we don't stop";
        const auto inner = ReferenceFinder::wordBounds(apostrophe, 5);
        QCOMPARE(apostrophe.mid(inner.first, inner.second - inner.first), QString("don't"));
        // On a PDF: the points returned select exactly that word or sentence, also a one-letter word.
        QTemporaryDir directory;
        const auto path = directory.filePath("sentences.pdf");
        writeTextFixture(path, {text + " and a word", "axis x of the plot"});
        QPdfDocument pdf;
        QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
        const auto pageText = pdf.getAllText(0).text();
        const auto point = [&](const QString &needle, int offset) {
            return pdf.getSelectionAtIndex(0, int(pageText.indexOf(needle)) + offset, 1).boundingRectangle().center();
        };
        const auto span = [&](const QString &needle, int offset, const QString &unit) {
            return ReferenceFinder::findSpan(pdf, 0, point(needle, offset), unit)["text"].toString();
        };
        QCOMPARE(span("approx", 3, "word"), QString("approx"));
        QCOMPARE(span("runs", 0, "word"), QString("runs"));
        // One letter: alone mid-line; at the end of a line Qt's selection can only start in the space before it.
        QCOMPARE(span(" a word", 1, "word").trimmed(), QString("a"));
        QCOMPARE(
            span("ten", 1, "sentence").simplified(), QString("See Fig. 3 for approx. ten runs, e.g. the best one."));
        QCOMPARE(span("third", 2, "sentence").simplified(), QString("A third (one) ends here!"));
        QVERIFY(ReferenceFinder::findSpan(pdf, 0, QPointF(5, 5), "word").isEmpty()); // Off the text.
        const auto plot = pdf.getAllText(1).text();
        const auto x = pdf.getSelectionAtIndex(1, int(plot.indexOf(" x ")) + 1, 1).boundingRectangle().center();
        // Mid-line it is the letter alone, or with the space after it on some fonts (Linux).
        QCOMPARE(ReferenceFinder::findSpan(pdf, 1, x, "word")["text"].toString().trimmed(), QString("x"));
        // A heading or a short last line ends a sentence without a full stop; lines that run on do not.
        const auto layout = directory.filePath("layout.pdf");
        writeFixture(layout, "A Small Research Reader", 1);
        QPdfDocument page;
        QCOMPARE(page.load(layout), QPdfDocument::Error::None);
        const auto all = page.getAllText(0).text();
        const auto on = [&](const QString &needle) {
            return page.getSelectionAtIndex(0, int(all.indexOf(needle)) + 2, 1).boundingRectangle().center();
        };
        QCOMPARE(ReferenceFinder::findSpan(page, 0, on("occlusion"), "sentence")["text"].toString().simplified(),
            QString("Research finding 1.1: occlusion links observation to context."));
        QCOMPARE(ReferenceFinder::findSpan(page, 0, on("Remember"), "sentence")["text"].toString().simplified(),
            QString::fromUtf8("Section 1 \u2014 Remember the evidence"));
    }
    void forYouOfflineIsNotTodaysCheck()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *forYou = qobject_cast<ForYou *>(store.forYou());
        // Nothing answers there: the check reaches no source.
        QTcpServer closed;
        QVERIFY(closed.listen(QHostAddress::LocalHost));
        const auto port = closed.serverPort();
        closed.close();
        QVERIFY(store.setSetting("forYou.arxivBaseUrl", QStringLiteral("http://127.0.0.1:%1/api").arg(port)));
        QVERIFY(forYou->saveTopics({QVariantMap{{"words", "lidar"}, {"categories", "cs.RO"}}}));
        forYou->refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!forYou->checking(), 10000);
        QVERIFY(!forYou->problem().isEmpty());
        // So it is not today's check (here, nor through sync on the other computers): the next one tries again.
        QVERIFY(!forYou->lastChecked().isValid());
    }
    void forYouFindsNewPapersAndAddsThem()
    {
        // The arXiv query for a topic: any of the words, in any of the categories, in the period.
        const auto from = QDateTime(QDate(2026, 1, 1), QTime(6, 0), QTimeZone::UTC);
        QCOMPARE(ForYouParse::arxivQuery("lidar odometry, SLAM", "cs.RO cs.CV", from, from.addDays(7)),
            QString("(all:\"lidar odometry\" OR all:SLAM) AND (cat:cs.RO OR cat:cs.CV) AND "
                    "submittedDate:[202601010600 TO 202601080600]"));
        QVERIFY(ForYouParse::arxivQuery("", "", from, from).isEmpty());
        // Stand-ins for arXiv and Semantic Scholar, and the PDF they point to.
        QTemporaryDir directory;
        const auto fixturePdf = directory.filePath("served.pdf");
        writeFixture(fixturePdf, "Served Paper");
        QFile served(fixturePdf);
        QVERIFY(served.open(QIODevice::ReadOnly));
        const auto pdfBytes = served.readAll();
        const auto today = QDate::currentDate().toString(Qt::ISODate);
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        const auto base = QStringLiteral("http://127.0.0.1:%1").arg(server.serverPort());
        QStringList requests;
        connect(&server, &QTcpServer::newConnection, &server, [&] {
            auto *socket = server.nextPendingConnection();
            auto *buffer = new QByteArray;
            connect(socket, &QObject::destroyed, socket, [buffer] { delete buffer; });
            connect(socket, &QTcpSocket::readyRead, socket, [&, socket, buffer] {
                buffer->append(socket->readAll());
                const auto end = buffer->indexOf("\r\n\r\n");
                if (end < 0) return;
                const auto length
                    = QRegularExpression("Content-Length: (\\d+)", QRegularExpression::CaseInsensitiveOption)
                          .match(QString::fromLatin1(buffer->left(end)))
                          .captured(1)
                          .toInt();
                if (buffer->size() < end + 4 + length) return;
                const auto head = QString::fromUtf8(buffer->left(end));
                requests.append(QString::fromUtf8(*buffer));
                QByteArray body, type = "application/json";
                if (head.contains("/api/query")) {
                    type = "application/atom+xml";
                    body = QStringLiteral(
                        "<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\" "
                        "xmlns:arxiv=\"http://arxiv.org/schemas/atom\">"
                        "<entry><id>http://arxiv.org/abs/2601.00001v2</id><published>%1T10:00:00Z</published>"
                        "<title>Fresh  LiDAR"
                        " Odometry</title><summary>New method.</summary><author><name>Ada "
                        "Lovelace</name></author><author><name>Alan Turing</name></author>"
                        "<link title=\"pdf\" href=\"%2/pdf/2601.00001v2\" rel=\"related\" "
                        "type=\"application/pdf\"/><arxiv:doi>10.9/fresh</arxiv:doi></entry>"
                        "<entry><id>http://arxiv.org/abs/2601.00002v1</id><published>%1T09:00:00Z</"
                        "published><title>Already Kept</title>"
                        "<author><name>Kept Author</name></author></entry></feed>")
                               .arg(today, base)
                               .toUtf8();
                } else if (head.contains("/recommendations/v1/papers/")) {
                    body = QStringLiteral(
                        "{\"recommendedPapers\":[{\"paperId\":\"s1\",\"title\":\"Like Your "
                        "Collection\",\"authors\":[{\"name\":\"Grace "
                        "Hopper\"}],\"year\":2026,\"publicationDate\":\"%1\",\"externalIds\":{\"DOI\":\"10.5/"
                        "like\"},\"openAccessPdf\":{\"url\":\"%2/pdf/like\"}},"
                        "                        {\"paperId\":\"s2\",\"title\":\"Old "
                        "Classic\",\"year\":2010,\"publicationDate\":\"2010-05-01\",\"externalIds\":{\"DOI\":\"10.5/"
                        "old\"}},"
                        "                        {\"paperId\":\"s3\",\"title\":\"Fresh LiDAR "
                        "Odometry\",\"publicationDate\":\"%1\",\"externalIds\":{\"ArXiv\":\"2601.00001\"}}]}")
                               .arg(today, base)
                               .toUtf8();
                } else if (head.contains("/pdf/")) {
                    type = "application/pdf";
                    body = pdfBytes;
                }
                socket->write("HTTP/1.1 200 OK\r\nContent-Type: " + type + "\r\nConnection: close\r\nContent-Length: "
                    + QByteArray::number(body.size()) + "\r\n\r\n" + body);
                socket->disconnectFromHost();
            });
        });
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *forYou = qobject_cast<ForYou *>(store.forYou());
        QVERIFY(forYou);
        QVERIFY(!forYou->configured());
        store.setSetting("forYou.arxivBaseUrl", base + "/api");
        store.setSetting("forYou.recommendBaseUrl", base + "/recommendations/v1");
        store.setSetting("forYou.delayMs", "10");
        store.setSetting("pdfNames.parts", "author,year,title");
        // A paper already kept, and a followed collection with one paper Semantic Scholar knows.
        const auto kept = QUrl::fromLocalFile(directory.filePath("kept.pdf"));
        writeFixture(kept.toLocalFile(), "Already Kept");
        QVERIFY(store.rememberDocument(kept));
        QVERIFY(store.updateDocumentDetails(kept, {{"title", "Already Kept"}, {"arxiv", "2601.00002v1"}}));
        const auto topic = store.createCollection("Odometry");
        QVERIFY(store.setDocumentCollection(kept, topic, true));
        QCOMPARE(forYou->usablePapers(topic), 1);
        QVERIFY(forYou->saveTopics({QVariantMap{{"words", "lidar odometry, SLAM"}, {"categories", "cs.RO"}}}));
        forYou->follow(topic, true);
        QVERIFY(forYou->configured());
        QVERIFY(forYou->following(topic));
        forYou->refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!forYou->checking(), 10000);
        QVERIFY2(forYou->problem().isEmpty(), qPrintable(forYou->problem()));
        QVERIFY(requests.join('\n').contains(
            "search_query=%28all%3A%22lidar+odometry%22+OR+all%3ASLAM%29+AND+cat%3Acs.RO"));
        QVERIFY(requests.join('\n').contains("\"positivePaperIds\":[\"ArXiv:2601.00002\"]"));
        // New papers only: not the kept one, not the old one, and the same paper once.
        auto items = forYou->items();
        QCOMPARE(items.size(), 2);
        QStringList ids;
        for (const auto &value : items) ids << value.toMap()["id"].toString();
        QVERIFY(ids.contains("arxiv:2601.00001"));
        QVERIFY(ids.contains("doi:10.5/like"));
        const auto fresh = forYou->items()[ids.indexOf("arxiv:2601.00001")].toMap();
        QCOMPARE(fresh["title"].toString(), QString("Fresh LiDAR Odometry"));
        QCOMPARE(fresh["authors"].toString(), QString("Ada Lovelace, Alan Turing"));
        QCOMPARE(fresh["sourceName"].toString(), QString("lidar odometry, SLAM"));
        QVERIFY(forYou->lastChecked().isValid());
        // Dismissed papers stay away, even when found again.
        forYou->dismiss({"doi:10.5/like"});
        QCOMPARE(forYou->items().size(), 1);
        forYou->refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!forYou->checking(), 10000);
        QCOMPARE(forYou->items().size(), 1);
        // Preview: the PDF comes into a cache, not the Library; Add then uses it without asking again.
        QSignalSpy previews(forYou, &ForYou::previewReady);
        forYou->preview("arxiv:2601.00001");
        QTRY_COMPARE_WITH_TIMEOUT(previews.size(), 1, 10000);
        const auto previewFile = previews[0][1].toUrl().toLocalFile();
        QVERIFY(QFileInfo(previewFile).size() > 0);
        QVERIFY(!store.hasPaper("2601.00001", ""));
        const auto asked = requests.join('\n').count("/pdf/2601.00001");
        // Add: the PDF comes into the Library, named and described from arXiv.
        forYou->add({"arxiv:2601.00001"});
        QTRY_VERIFY_WITH_TIMEOUT(forYou->adding().isEmpty(), 10000);
        QCOMPARE(forYou->items().size(), 0);
        QVERIFY(store.hasPaper("2601.00001v2", ""));
        QCOMPARE(requests.join('\n').count("/pdf/2601.00001"), asked);
        QVERIFY(!QFileInfo::exists(previewFile));
        const auto added
            = store.paperWithFile(QUrl::fromLocalFile(store.papersFolder() + "/Lovelace et al. - "
                                      + QString::number(QDate::currentDate().year()) + " - Fresh LiDAR Odometry.pdf"),
                {});
        QVERIFY(!added.isEmpty());
        QCOMPARE(store.documentDetails(added)["arxiv"].toString(), QString("2601.00001"));
        QCOMPARE(store.documentDetails(added)["doi"].toString(), QString("10.9/fresh"));
        // Kept across restarts.
        {
            ResearchStore again(directory.filePath("data"));
            QVERIFY2(again.initialize(&error), qPrintable(error));
            auto *later = qobject_cast<ForYou *>(again.forYou());
            QVERIFY(later->lastChecked().isValid());
            QCOMPARE(later->items().size(), 0);
        }
    }
    void forYouFollowsResearchersAndInstitutions()
    {
        // OpenAlex's answers: the abstract as words with their places, arXiv through its DOI or an arxiv.org page.
        const auto today = QDate::currentDate().toString(Qt::ISODate);
        const auto parsed = ForYouParse::openAlexWorks(QStringLiteral(
            "{\"results\":[{\"id\":\"https://openalex.org/W1\",\"doi\":\"https://doi.org/10.48550/arXiv.2601.00042\","
            "\"title\":\"Preprint\",\"publication_date\":\"%1\",\"publication_year\":2026,"
            "\"abstract_inverted_index\":{\"order.\":[2],\"Words\":[0],\"in\":[1]},"
            "\"authorships\":[{\"author\":{\"display_name\":\"Ada "
            "Lovelace\"}}],\"best_oa_location\":null,\"locations\":[]},"
            "{\"id\":\"https://openalex.org/W2\",\"doi\":\"https://doi.org/10.7/Journal\",\"title\":\"Journal Paper\","
            "\"publication_date\":\"%1\",\"authorships\":[],\"best_oa_location\":{\"landing_page_url\":"
            "\"https://arxiv.org/abs/2601.00043v2\",\"pdf_url\":\"https://arxiv.org/pdf/"
            "2601.00043v2\"},\"locations\":[]},"
            "{\"id\":\"https://openalex.org/W3\",\"title\":null}]}")
                .arg(today)
                .toUtf8());
        QCOMPARE(parsed.size(), 2);
        QCOMPARE(parsed[0].toMap()["arxiv"].toString(), QString("2601.00042"));
        QVERIFY(parsed[0].toMap()["doi"].toString().isEmpty());
        QCOMPARE(parsed[0].toMap()["abstract"].toString(), QString("Words in order."));
        QCOMPARE(parsed[0].toMap()["pdf"].toString(), QString("https://arxiv.org/pdf/2601.00042"));
        QCOMPARE(parsed[1].toMap()["arxiv"].toString(), QString("2601.00043"));
        QCOMPARE(parsed[1].toMap()["doi"].toString(), QString("10.7/Journal"));
        // Stand-ins for OpenAlex and arXiv.
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        const auto base = QStringLiteral("http://127.0.0.1:%1").arg(server.serverPort());
        QStringList requests;
        connect(&server, &QTcpServer::newConnection, &server, [&] {
            auto *socket = server.nextPendingConnection();
            connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                const auto head = QUrl::fromPercentEncoding(socket->readAll().split('\r').value(0));
                requests << head;
                QByteArray body = "{\"results\":[]}", type = "application/json", status = "200 OK";
                const auto authorship = [](const QString &id, const QString &name, const QString &position) {
                    return QStringLiteral("{\"author_position\":\"%3\",\"author\":{\"id\":\"https://openalex.org/"
                                          "%1\",\"display_name\":\"%2\"}}")
                        .arg(id, name, position);
                };
                const auto work = [&](const QString &id, const QString &title, const QString &doi) {
                    return QStringLiteral("{\"results\":[{\"id\":\"https://openalex.org/%1\",\"doi\":\"https://doi.org/"
                                          "%3\",\"title\":\"%2\",\"publication_date\":\"%4\",\"authorships\":[],"
                                          "\"best_oa_location\":{\"pdf_url\":\"%5/pdf/%1\"},\"locations\":[]}]}")
                        .arg(id, title, doi, today, base)
                        .toUtf8();
                };
                if (head.contains("/works/doi:10.7/missing"))
                    status = "404 Not Found";
                else if (head.contains("/works/doi:10.48550/arXiv.2601.00099"))
                    body = ("{\"id\":\"https://openalex.org/W9\",\"title\":\"By arXiv\",\"authorships\":["
                        + authorship("A1", "First Student", "first") + "," + authorship("A2", "Middle One", "middle")
                        + "," + authorship("A3", "Lab Head", "last") + "]}")
                               .toUtf8();
                else if (head.contains("/works?search="))
                    body = ("{\"results\":[{\"title\":\"Another Paper\",\"authorships\":["
                        + authorship("A8", "Wrong Person", "first") + "]},{\"title\":\"Exactly This Title!\","
                        + "\"authorships\":[" + authorship("A9", "Right Person", "first") + "]}]}")
                               .toUtf8();
                else if (head.contains("/authors?"))
                    body = "{\"results\":[{\"id\":\"https://openalex.org/A111\",\"display_name\":\"Ada Lovelace\","
                           "\"last_known_institutions\":[{\"display_name\":\"Analytical "
                           "University\"}],\"works_count\":12},"
                           "{\"id\":\"https://openalex.org/I5\",\"display_name\":\"Not a person\"}]}";
                else if (head.contains("/institutions?"))
                    body = "{\"results\":[{\"id\":\"https://openalex.org/I222\",\"display_name\":\"Analytical "
                           "University\","
                           "\"country_code\":\"GB\",\"works_count\":5000}]}";
                else if (head.contains("authorships.author.id:A111"))
                    body = work("W10", "By Ada", "10.7/ada");
                else if (head.contains("authorships.institutions.lineage:I222"))
                    body = work("W20", "From the University", "10.7/university");
                else if (head.contains("/api/query")) {
                    type = "application/atom+xml";
                    body
                        = QStringLiteral("<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><entry>"
                                         "<id>http://arxiv.org/abs/2601.00077v1</id><published>%1T10:00:00Z</published>"
                                         "<title>On The Topic</title></entry></feed>")
                              .arg(today)
                              .toUtf8();
                }
                socket->write("HTTP/1.1 " + status + "\r\nContent-Type: " + type
                    + "\r\nConnection: close\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n\r\n"
                    + body);
                socket->disconnectFromHost();
            });
        });
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        auto *forYou = qobject_cast<ForYou *>(store.forYou());
        store.setSetting("forYou.openAlexBaseUrl", base);
        store.setSetting("forYou.arxivBaseUrl", base + "/api");
        store.setSetting("forYou.delayMs", "10");
        // Found by name: researchers with where they work, and institutions; asked for once, not while typing.
        QSignalSpy found(forYou, &ForYou::peopleFound);
        forYou->findPeople("Ada");
        QTRY_COMPARE_WITH_TIMEOUT(found.size(), 1, 10000);
        QVERIFY(!forYou->findingPeople());
        const auto people = found[0][1].toList();
        QCOMPARE(people.size(), 2);
        QCOMPARE(people[0].toMap()["kind"].toString(), QString("person"));
        QCOMPARE(people[0].toMap()["detail"].toString(), QString("Analytical University"));
        QCOMPARE(people[1].toMap()["kind"].toString(), QString("institution"));
        QCOMPARE(people[1].toMap()["detail"].toString(), QString("GB"));
        QVERIFY(found[0][2].toString().isEmpty());
        QVERIFY(!forYou->configured());
        QVERIFY(!forYou->followPerson({{"id", "A1 OR 1=1"}, {"kind", "person"}})); // Only OpenAlex IDs.
        QVERIFY(forYou->followPerson(people[0].toMap()));
        QVERIFY(forYou->followPerson(people[1].toMap()));
        QVERIFY(forYou->configured());
        QCOMPARE(forYou->people().size(), 2);
        QVERIFY(forYou->saveTopics({QVariantMap{{"words", "topic"}}}));
        // One of them brings at most its own number of papers; the others the usual one.
        forYou->setPerCheck("person:A111", 3);
        QCOMPARE(forYou->perCheck("person:A111"), 3);
        QCOMPARE(forYou->perCheck("institution:I222"), 0);
        // Their new articles and preprints, up to today, newest first.
        forYou->refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!forYou->checking(), 10000);
        QVERIFY2(forYou->problem().isEmpty(), qPrintable(forYou->problem()));
        const auto asked = requests.join('\n');
        QVERIFY(asked.contains("filter=authorships.author.id:A111,from_publication_date:"));
        QVERIFY(asked.contains(",to_publication_date:" + today + ",type:article|preprint"));
        QVERIFY(asked.contains("sort=publication_date:desc"));
        QVERIFY(QRegularExpression("author\\.id:A111[^ ]*per-page=3[& ]").match(asked).hasMatch());
        QVERIFY(QRegularExpression("lineage:I222[^ ]*per-page=10[& ]").match(asked).hasMatch());
        QVERIFY(asked.contains("max_results=10"));
        forYou->setPerCheck("person:A111", 0);
        QCOMPARE(forYou->perCheck("person:A111"), 0);
        QCOMPARE(forYou->items().size(), 3);
        // By the AI's score, theirs too: a topic paper scored high comes before them (Following lists theirs by date).
        {
            WorkerConnection db(store.dataDirectory() + "/owelk.sqlite3");
            QSqlQuery query(db.db);
            QVERIFY(query.exec("UPDATE foryou_items SET score=99 WHERE id='arxiv:2601.00077'"));
        }
        forYou->reload();
        const auto items = forYou->items();
        QCOMPARE(items[0].toMap()["id"].toString(), QString("arxiv:2601.00077"));
        QVERIFY(ForYou::fromPerson(items[1].toMap()["source"].toString()));
        QVERIFY(ForYou::fromPerson(items[2].toMap()["source"].toString()));
        QStringList sources{items[1].toMap()["source"].toString(), items[2].toMap()["source"].toString()};
        sources.sort();
        QCOMPARE(sources, (QStringList{"institution:I222", "person:A111"}));
        // A paper's authors: by DOI (none here), then by its arXiv ID; the last author first.
        QSignalSpy authors(forYou, &ForYou::authorsFound);
        forYou->findAuthors({{"doi", "10.7/missing"}, {"arxiv", "2601.00099v2"}, {"title", "By arXiv"}});
        QTRY_COMPARE_WITH_TIMEOUT(authors.size(), 1, 10000);
        const auto byArxiv = authors[0][1].toList();
        QCOMPARE(byArxiv.size(), 3);
        QCOMPARE(byArxiv[0].toMap()["name"].toString(), QString("Lab Head"));
        QCOMPARE(byArxiv[1].toMap()["name"].toString(), QString("First Student"));
        // Without either: a search by title, taking only a paper of exactly that title.
        forYou->findAuthors({{"title", "Exactly this title"}});
        QTRY_COMPARE_WITH_TIMEOUT(authors.size(), 2, 10000);
        QCOMPARE(authors[1][1].toList().value(0).toMap()["name"].toString(), QString("Right Person"));
        forYou->findAuthors({{"title", "Nothing like it at all"}});
        QTRY_COMPARE_WITH_TIMEOUT(authors.size(), 3, 10000);
        QVERIFY(authors[2][1].toList().isEmpty());
        QVERIFY(!authors[2][2].toString().isEmpty());
        // Turned off or no longer followed: not asked for.
        forYou->setPersonOn("A111", false);
        forYou->unfollowPerson("I222");
        QCOMPARE(forYou->people().size(), 1);
        requests.clear();
        forYou->refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!forYou->checking(), 10000);
        QVERIFY(!requests.join('\n').contains("/works"));
    }
    void forYouPapersWithoutAFreePdf()
    {
        QVERIFY(ForYouParse::isPdfAddress("https://arxiv.org/pdf/2601.00001"));
        QVERIFY(!ForYouParse::isPdfAddress("https://doi.org/10.1109/x"));
        QVERIFY(!ForYouParse::isPdfAddress(""));
        // A Semantic Scholar "open PDF" that is only a DOI link is no PDF; an arXiv ID still gives one.
        const auto parsed = ForYouParse::recommendations(
            "{\"recommendedPapers\":[{\"paperId\":\"a\",\"title\":\"Journal "
            "Only\",\"externalIds\":{\"DOI\":\"10.1/j\"},"
            "\"openAccessPdf\":{\"url\":\"https://doi.org/10.1/j\"}},{\"paperId\":\"b\",\"title\":\"Also On arXiv\","
            "\"externalIds\":{\"ArXiv\":\"2601.00009\"},\"openAccessPdf\":{\"url\":\"\"}}]}");
        QCOMPARE(parsed.size(), 2);
        QCOMPARE(parsed[0].toMap()["pdf"].toString(), QString());
        QCOMPARE(parsed[1].toMap()["pdf"].toString(), QString("https://arxiv.org/pdf/2601.00009"));
        // A stand-in Semantic Scholar recommending one journal paper.
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        connect(&server, &QTcpServer::newConnection, &server, [&] {
            auto *socket = server.nextPendingConnection();
            connect(socket, &QTcpSocket::readyRead, socket, [socket] {
                if (!socket->readAll().contains("\r\n\r\n")) return;
                const QByteArray body = QStringLiteral(
                    "{\"recommendedPapers\":[{\"paperId\":\"j1\",\"title\":\"Journal Only\",\"publicationDate\":\"%1\","
                    "\"externalIds\":{\"DOI\":\"10.1/j\"},\"openAccessPdf\":{\"url\":\"https://doi.org/10.1/j\"}}]}")
                                            .arg(QDate::currentDate().toString(Qt::ISODate))
                                            .toUtf8();
                socket->write(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
                    + QByteArray::number(body.size()) + "\r\n\r\n" + body);
                socket->disconnectFromHost();
            });
        });
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        store.setSetting("forYou.recommendBaseUrl", QStringLiteral("http://127.0.0.1:%1").arg(server.serverPort()));
        store.setSetting("forYou.delayMs", "10");
        const auto seed = QUrl::fromLocalFile(directory.filePath("seed.pdf"));
        writeFixture(seed.toLocalFile(), "Seed Paper");
        QVERIFY(store.rememberDocument(seed));
        QVERIFY(store.updateDocumentDetails(seed, {{"title", "Seed Paper"}, {"arxiv", "2501.00001"}}));
        const auto topic = store.createCollection("Journals");
        QVERIFY(store.setDocumentCollection(seed, topic, true));
        auto *forYou = qobject_cast<ForYou *>(store.forYou());
        forYou->follow(topic, true);
        forYou->refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!forYou->checking(), 10000);
        QCOMPARE(forYou->items().size(), 1);
        QVERIFY(!forYou->items()[0].toMap()["hasPdf"].toBool());
        // Added with others, it is left (its page would open a tab of its own); alone, its page opens.
        QSignalSpy pages(forYou, &ForYou::webRequested);
        forYou->add({"doi:10.1/j", "doi:10.1/missing"});
        QCOMPARE(pages.size(), 0);
        QVERIFY(forYou->adding().isEmpty());
        forYou->add({"doi:10.1/j"});
        QTRY_COMPARE_WITH_TIMEOUT(pages.size(), 1, 5000);
        QCOMPARE(forYou->items().size(), 1);
        // A PDF of it that reaches the Library some other way (downloaded from that page) takes it off the list.
        const auto got = QUrl::fromLocalFile(directory.filePath("got.pdf"));
        writeFixture(got.toLocalFile(), "Journal Only");
        QCOMPARE(store.addDocuments({got}), 1);
        QVERIFY(store.updateDocumentDetails(got, {{"title", "What The PDF Says"}, {"doi", "10.1/J"}}));
        QTRY_COMPARE_WITH_TIMEOUT(forYou->items().size(), 0, 10000);
        // Its page was opened for it, so it gets Add's details and collection, and stays unread.
        const auto arrived = store.paperUrlFor("", "10.1/j");
        QCOMPARE(store.documentDetails(arrived)["title"].toString(), QString("Journal Only"));
        QCOMPARE(store.documentDetails(arrived)["readingState"].toString(), QString("unread"));
        QCOMPARE(store.libraryDocuments({{"collection", topic}}).size(), 2);
    }
    void forYouAddGoesThroughTheBrowserWhenTheDownloadFails()
    {
        // arXiv answers the query; its "PDF" address answers with a web page instead.
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        const auto base = QStringLiteral("http://127.0.0.1:%1").arg(server.serverPort());
        const auto today = QDate::currentDate().toString(Qt::ISODate);
        connect(&server, &QTcpServer::newConnection, &server, [&] {
            auto *socket = server.nextPendingConnection();
            connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                const auto head = QString::fromUtf8(socket->readAll()).section("\r\n", 0, 0);
                const QByteArray body = head.contains("/api/query")
                    ? QStringLiteral(
                          "<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><entry><id>"
                          "http://arxiv.org/abs/2609.07777v1</id><published>%1T08:00:00Z</published><title>"
                          "Behind A Wall</title><author><name>Ada Lovelace</name></author><link title=\"pdf\" "
                          "href=\"%2/pdf/wall\"/></entry></feed>")
                          .arg(today, base)
                          .toUtf8()
                    : QByteArray("<html><body>Please verify you are human.</body></html>");
                socket->write("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\nContent-Length: "
                    + QByteArray::number(body.size()) + "\r\n\r\n" + body);
                socket->disconnectFromHost();
            });
        });
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        store.setSetting("forYou.arxivBaseUrl", base + "/api");
        store.setSetting("forYou.delayMs", "10");
        auto *forYou = qobject_cast<ForYou *>(store.forYou());
        QVERIFY(forYou->saveTopics({QVariantMap{{"words", "walls"}}}));
        forYou->refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!forYou->checking(), 10000);
        QCOMPARE(forYou->items().size(), 1);
        // Add: the download is not a PDF, so the PDF's address opens in the browser instead.
        QSignalSpy pages(forYou, &ForYou::webRequested);
        forYou->add({"arxiv:2609.07777"});
        QTRY_COMPARE_WITH_TIMEOUT(pages.size(), 1, 10000);
        QCOMPARE(pages[0][0].toUrl().toString(), base + "/pdf/wall");
        QCOMPARE(forYou->items().size(), 1);
        // The browser's download reaches the Library: it gets Add's details and leaves the list.
        const auto got = QUrl::fromLocalFile(directory.filePath("wall.pdf"));
        writeFixture(got.toLocalFile(), "Some Title The PDF Shows");
        QVERIFY(store.rememberDocument(got));
        QVERIFY(store.updateDocumentDetails(got, {{"title", "Some Title The PDF Shows"}, {"arxiv", "2609.07777v1"}}));
        QTRY_COMPARE_WITH_TIMEOUT(forYou->items().size(), 0, 10000);
        QCOMPARE(store.documentDetails(got)["title"].toString(), QString("Behind A Wall"));
        QCOMPARE(store.documentDetails(got)["authors"].toString(), QString("Ada Lovelace"));
    }
    void forYouMovesIntoTheLibraryAndSyncs()
    {
        QTemporaryDir directory;
        const auto data = directory.filePath("mac");
        QString error;
        QString odometry;
        {
            ResearchStore fresh(data);
            QVERIFY2(fresh.initialize(&error), qPrintable(error));
            odometry = fresh.createCollection("Odometry");
        }
        {
            // As the first version kept it: topics and follows in settings, papers in foryou.json.
            auto db = QSqlDatabase::addDatabase("QSQLITE", "v17");
            db.setDatabaseName(data + "/owelk.sqlite3");
            QVERIFY(db.open());
            QSqlQuery query(db);
            for (const auto &sql : {QString("DROP TABLE foryou_topics"), QString("DROP TABLE foryou_follows"),
                     QString("DROP TABLE foryou_items"), QString("DROP TABLE foryou_meta"),
                     QString("INSERT INTO settings VALUES('pref.forYou.topics','[{\"id\":\"t1\",\"words\":\"SLAM\","
                             "\"categories\":\"cs.RO\",\"on\":true}]')"),
                     "INSERT INTO settings VALUES('pref.forYou.collections','" + odometry + "')",
                     QString("PRAGMA user_version=17")})
                QVERIFY2(query.exec(sql), qPrintable(query.lastError().text() + sql));
            db.close();
        }
        QSqlDatabase::removeDatabase("v17");
        QFile old(data + "/foryou.json");
        QVERIFY(old.open(QIODevice::WriteOnly));
        old.write(
            R"({"items":[{"id":"arxiv:2601.00001","title":"Kept Paper","date":"2026-01-02","foundAt":"2026-10-01T00:00:00Z","score":88,"why":"On SLAM."}],"dismissed":["doi:10.1/gone"],"checkedAt":"2026-10-01T00:00:00Z"})");
        old.close();
        ResearchStore mac(data);
        QVERIFY2(mac.initialize(&error), qPrintable(error));
        auto *forYou = qobject_cast<ForYou *>(mac.forYou());
        QCOMPARE(forYou->topics().size(), 1);
        QCOMPARE(forYou->topics()[0].toMap()["words"].toString(), QString("SLAM"));
        QVERIFY(forYou->following(odometry));
        QVERIFY(mac.setting("forYou.topics").isEmpty());
        mac.setSetting("forYou.keepDays", "0");
        QCOMPARE(forYou->items().size(), 1);
        QCOMPARE(forYou->items()[0].toMap()["why"].toString(), QString("On SLAM."));
        QCOMPARE(forYou->items()[0].toMap()["score"].toInt(), 88);
        QVERIFY(forYou->lastChecked().isValid());
        QVERIFY(!QFileInfo::exists(data + "/foryou.json"));
        // Kept for the days chosen: a paper found long ago leaves the list (it is not deleted).
        mac.setSetting("forYou.keepDays", "7");
        QCOMPARE(forYou->items().size(), 0);
        mac.setSetting("forYou.keepDays", "0");
        // Another computer gets the topics, the follows and the papers with the AI's reasons, so nothing is
        // asked twice; what is dismissed on one goes on the other.
        const auto drive = directory.filePath("Drive");
        QVERIFY(QDir().mkpath(drive));
        QCOMPARE(mac.librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
        QVERIFY(mac.librarySync()->syncBlocking().error.isEmpty());
        ResearchStore laptop(directory.filePath("laptop"));
        QVERIFY2(laptop.initialize(&error), qPrintable(error));
        laptop.setSetting("forYou.keepDays", "0");
        QCOMPARE(laptop.librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
        QVERIFY(laptop.librarySync()->syncBlocking().error.isEmpty());
        auto *other = qobject_cast<ForYou *>(laptop.forYou());
        QCOMPARE(other->topics().size(), 1);
        QVERIFY(other->following(odometry));
        QCOMPARE(other->items().size(), 1);
        QCOMPARE(other->items()[0].toMap()["why"].toString(), QString("On SLAM."));
        QCOMPARE(other->lastChecked(), forYou->lastChecked());
        other->dismiss({"arxiv:2601.00001"});
        QVERIFY(laptop.librarySync()->syncBlocking().error.isEmpty());
        QVERIFY(mac.librarySync()->syncBlocking().error.isEmpty());
        QCOMPARE(forYou->items().size(), 0);
    }
    void forYouTopicsTravelAfterAnUpgradeWhileSyncing()
    {
        // Syncing already, then upgraded: the topics brought into the library still travel.
        QTemporaryDir directory;
        const auto data = directory.filePath("mac"), drive = directory.filePath("Drive");
        QVERIFY(QDir().mkpath(drive));
        QString error;
        {
            ResearchStore fresh(data);
            QVERIFY2(fresh.initialize(&error), qPrintable(error));
            QCOMPARE(fresh.librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
            QVERIFY(fresh.librarySync()->syncBlocking().error.isEmpty());
        }
        {
            auto db = QSqlDatabase::addDatabase("QSQLITE", "v17sync");
            db.setDatabaseName(data + "/owelk.sqlite3");
            QVERIFY(db.open());
            QSqlQuery query(db);
            for (const auto &sql : {QString("DROP TABLE foryou_topics"), QString("DROP TABLE foryou_follows"),
                     QString("DROP TABLE foryou_items"), QString("DROP TABLE foryou_meta"),
                     QString("INSERT INTO settings VALUES('pref.forYou.topics','[{\"id\":\"t9\",\"words\":\"lidar\","
                             "\"categories\":\"\",\"on\":true}]')"),
                     QString("PRAGMA user_version=17")})
                QVERIFY2(query.exec(sql), qPrintable(query.lastError().text() + sql));
            db.close();
        }
        QSqlDatabase::removeDatabase("v17sync");
        ResearchStore mac(data);
        QVERIFY2(mac.initialize(&error), qPrintable(error));
        QVERIFY(mac.librarySync()->syncBlocking().error.isEmpty());
        ResearchStore laptop(directory.filePath("laptop"));
        QVERIFY2(laptop.initialize(&error), qPrintable(error));
        QCOMPARE(laptop.librarySync()->setFolder(QUrl::fromLocalFile(drive)), QString());
        QVERIFY(laptop.librarySync()->syncBlocking().error.isEmpty());
        const auto topics = qobject_cast<ForYou *>(laptop.forYou())->topics();
        QCOMPARE(topics.size(), 1);
        QCOMPARE(topics[0].toMap()["words"].toString(), QString("lidar"));
    }
    void citationsComeFromSemanticScholarAndMatchTheLibrary()
    {
        // A local stand-in for Semantic Scholar: answers by path and records what was asked.
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        QStringList requests;
        connect(&server, &QTcpServer::newConnection, &server, [&] {
            auto *socket = server.nextPendingConnection();
            connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                const auto head = QString::fromUtf8(socket->readAll()).section("\r\n", 0, 0);
                requests.append(head);
                QByteArray body, status = "200 OK";
                if (head.contains("/search/match"))
                    body = R"({"data":[{"paperId":"m1","title":"Untitled match"}]})";
                else if (head.contains("missing"))
                    status = "404 Not Found";
                else if (head.contains("/references"))
                    body
                        = R"({"data":[{"citedPaper":{"paperId":"r1","title":"Known Cited Paper","year":2019,"authors":[{"name":"Ann Lee"},{"name":"Bo Kim"}],"externalIds":{},"citationCount":5}},
                                      {"citedPaper":{"paperId":"r2","title":"Other Paper","externalIds":{"ArXiv":"2001.00001"}}},
                                      {"citedPaper":{"paperId":null,"title":null}}]})";
                else if (head.contains("/citations"))
                    body = R"({"data":[{"citingPaper":{"paperId":"c1","title":"Low","citationCount":1}},
                                      {"citingPaper":{"paperId":"c2","title":"High","citationCount":50,"externalIds":{"DOI":"10.2/x"}}}]})";
                socket->write("HTTP/1.1 " + status
                    + "\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
                    + QByteArray::number(body.size()) + "\r\n\r\n" + body);
                socket->disconnectFromHost();
            });
        });
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        store.setSetting("citations.baseUrl", QStringLiteral("http://127.0.0.1:%1/graph/v1").arg(server.serverPort()));
        const auto paper = QUrl::fromLocalFile(directory.filePath("paper.pdf")),
                   cited = QUrl::fromLocalFile(directory.filePath("cited.pdf"));
        writeFixture(paper.toLocalFile(), "Citing Paper");
        writeFixture(cited.toLocalFile(), "Known Cited Paper");
        QVERIFY(store.rememberDocument(paper));
        QVERIFY(store.rememberDocument(cited));
        QVERIFY(store.updateDocumentDetails(paper, {{"title", "Citing Paper"}, {"doi", "10.1/abc"}}));
        QVERIFY(store.updateDocumentDetails(cited, {{"title", "Known Cited Paper"}}));
        QSignalSpy loaded(&store, &ResearchStore::citationsLoaded);
        const auto load = [&](const QUrl &source, bool refresh) {
            const int request = store.loadCitations(source, refresh);
            for (int i = 0; i < 100; ++i) {
                for (const auto &call : loaded)
                    if (call[0].toInt() == request) return call[2].toMap();
                loaded.wait(100);
            }
            return QVariantMap{{"error", "timeout"}};
        };
        auto result = load(paper, false);
        QVERIFY2(result["error"].toString().isEmpty(), qPrintable(result["error"].toString()));
        QVERIFY(requests.join(' ').contains("/graph/v1/paper/DOI:10.1/abc/references?"));
        const auto references = result["references"].toList();
        QCOMPARE(references.size(), 2); // Rows without a title are dropped.
        auto first = references[0].toMap();
        QCOMPARE(first["authors"].toString(), QString("Ann Lee et al."));
        QCOMPARE(first["year"].toString(), QString("2019"));
        QCOMPARE(first["inLibrary"].toUrl(), cited); // Same title as a Library paper.
        QCOMPARE(first["url"].toString(), QString("https://www.semanticscholar.org/paper/r1"));
        QCOMPARE(references[1].toMap()["url"].toString(), QString("https://arxiv.org/abs/2001.00001"));
        // Most cited first.
        const auto citedBy = result["citedBy"].toList();
        QCOMPARE(citedBy[0].toMap()["title"].toString(), QString("High"));
        QCOMPARE(citedBy[0].toMap()["url"].toString(), QString("https://doi.org/10.2/x"));
        // Asked again: from the cache, without the network; Refresh asks again.
        const auto asked = requests.size();
        result = load(paper, false);
        QVERIFY(result["cached"].toBool());
        QCOMPARE(requests.size(), asked);
        QCOMPARE(result["references"].toList()[0].toMap()["inLibrary"].toUrl(), cited);
        load(paper, true);
        QCOMPARE(requests.size(), asked + 2);
        // No DOI or arXiv ID: found by title first.
        result = load(cited, false);
        QVERIFY(result["error"].toString().isEmpty());
        QVERIFY(requests.join(' ').contains("/paper/search/match?query=Known"));
        QVERIFY(requests.join(' ').contains("/paper/m1/references"));
        // Unknown to Semantic Scholar.
        QVERIFY(store.updateDocumentDetails(paper, {{"title", "Citing Paper"}, {"doi", ""}, {"arxiv", "missing"}}));
        result = load(paper, true);
        QVERIFY(!result["error"].toString().isEmpty());
    }
    void missingDetailsAreLookedUpByDoiOrArxivOnly()
    {
        QTemporaryDir directory;
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        QStringList requests;
        connect(&server, &QTcpServer::newConnection, &server, [&] {
            auto *socket = server.nextPendingConnection();
            connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                const auto head = QString::fromUtf8(socket->readAll()).section("\r\n", 0, 0);
                requests.append(head);
                const QByteArray body = head.contains("/arxiv")
                    ? "<?xml version='1.0'?><feed xmlns='http://www.w3.org/2005/Atom'><entry>"
                      "<id>http://arxiv.org/abs/2305.01234v2</id><published>2023-05-02T00:00:00Z</published>"
                      "<title>Online Title</title><author><name>Ada Lovelace</name></author></entry></feed>"
                    : R"({"message":{"title":["Crossref Work"],"DOI":"10.1145/3592433","author":[{"given":"Grace","family":"Hopper"}],"published-print":{"date-parts":[[2024,5]]}}})";
                socket->write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: "
                    + QByteArray::number(body.size()) + "\r\n\r\n" + body);
                socket->disconnectFromHost();
            });
        });
        ResearchStore store(directory.filePath("data"));
        QVERIFY(store.initialize(nullptr));
        store.detailsPauseMs = 0;
        auto *lookup = static_cast<MetadataLookup *>(store.metadataLookup());
        const auto base = QStringLiteral("http://127.0.0.1:%1").arg(server.serverPort());
        lookup->arxivBase = QUrl(base + "/arxiv");
        lookup->crossrefBase = QUrl(base + "/works");
        // By arXiv ID (its title kept), by DOI, by title only (not looked up: it could find another paper).
        QList<QUrl> papers;
        const QList<QVariantMap> details{{{"title", "My Own Title"}, {"arxiv", "2305.01234"}},
            {{"title", ""}, {"doi", "10.1145/3592433"}, {"year", "2020"}}, {{"title", "Only A Title Here"}}};
        for (int i = 0; i < details.size(); ++i) {
            const auto path = directory.filePath(QString("missing %1.pdf").arg(i));
            writeFixture(path);
            papers << QUrl::fromLocalFile(path);
            QVERIFY(store.updateDocumentDetails(papers.last(), details[i]));
        }
        QCOMPARE(store.missingDetails()["count"].toInt(), 3);
        QCOMPARE(store.missingDetails()["lookable"].toInt(), 2);
        QCOMPARE(store.libraryDocuments({{"missing", true}}).size(), 3);
        store.fillMissingDetails();
        QVERIFY(store.fillingDetails());
        QTRY_VERIFY_WITH_TIMEOUT(!store.fillingDetails(), 10000);
        QCOMPARE(requests.size(), 2);
        const auto first = store.documentDetails(papers[0]), second = store.documentDetails(papers[1]),
                   third = store.documentDetails(papers[2]);
        QCOMPARE(first["title"].toString(), QString("My Own Title"));
        QCOMPARE(first["authors"].toString(), QString("Ada Lovelace"));
        QCOMPARE(first["year"].toString(), QString("2023"));
        QCOMPARE(second["title"].toString(), QString("Crossref Work"));
        QCOMPARE(second["authors"].toString(), QString("Grace Hopper"));
        QCOMPARE(second["year"].toString(), QString("2020"));
        QVERIFY(third["authors"].toString().isEmpty());
        QCOMPARE(store.missingDetails()["count"].toInt(), 1);
        QVERIFY(store.tasks().isEmpty());
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
        // Authors nearly as tall as the title (as superscripts can make them), a little way below it: not the title.
        const auto tall = directory.filePath("tall authors.pdf");
        {
            QPdfWriter writer(tall);
            writer.setResolution(72);
            writer.setPageSize(QPageSize(QPageSize::A4));
            QPainter painter(&writer);
            const auto line = [&](qreal y, int size, const QString &text, qreal x = 60) {
                painter.setFont(QFont("Helvetica", size));
                painter.drawText(QPointF(x, y), text);
            };
            line(120, 20, "Lunar Odometry with Warped Feature Matching");
            line(144, 20, "on Repetitive Terrain");
            line(189, 18, "Gregory Pyle1, Jay Quigley2");
            line(232, 10, "Abstract");
            for (int i = 0; i < 30; ++i) line(252 + i * 14, 10, "Body text of the page number " + QString::number(i));
        }
        const auto read = extractPaperMetadata(tall);
        QCOMPARE(read.title, QString("Lunar Odometry with Warped Feature Matching on Repetitive Terrain"));
        QCOMPARE(read.authors, QString("Gregory Pyle, Jay Quigley"));
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
            for (const auto *sql : {"DROP TABLE documents", "DROP TABLE recent_documents",
                     "DROP TABLE reading_positions", "DROP TABLE IF EXISTS workspace_documents",
                     "DROP TABLE IF EXISTS workspace_document_exclusions", "DROP TABLE IF EXISTS captures",
                     "DROP TABLE highlights", "DROP TABLE collections", "DROP TABLE collection_documents",
                     "DROP TABLE tags", "DROP TABLE document_tags", "DROP TABLE notes", "DROP TABLE ai_responses",
                     "DROP TABLE ai_messages", "DROP TABLE ai_threads", "DROP TABLE ai_folders", "DROP TABLE links",
                     "CREATE TABLE recent_documents (url TEXT PRIMARY KEY, opened_at TEXT NOT NULL)",
                     "CREATE TABLE reading_positions (url TEXT PRIMARY KEY, position TEXT NOT NULL)",
                     "CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, state TEXT NOT NULL, "
                     "opened_at TEXT NOT NULL)",
                     "CREATE TABLE deleted_workspaces (id TEXT PRIMARY KEY, deleted_at TEXT NOT NULL)",
                     "CREATE TABLE workspace_captures (workspace_id TEXT NOT NULL, capture_id TEXT NOT NULL, "
                     "PRIMARY KEY(workspace_id,capture_id))",
                     "CREATE TABLE workspace_documents (workspace_id TEXT NOT NULL, url TEXT NOT NULL, "
                     "PRIMARY KEY(workspace_id,url))",
                     "CREATE TABLE workspace_document_exclusions (workspace_id TEXT NOT NULL, url TEXT NOT NULL, "
                     "PRIMARY KEY(workspace_id,url))",
                     "CREATE TABLE captures (id TEXT PRIMARY KEY, source TEXT NOT NULL, sha256 TEXT NOT NULL, "
                     "page INTEGER NOT NULL, x REAL NOT NULL, y REAL NOT NULL, width REAL NOT NULL, height REAL NOT "
                     "NULL, "
                     "image TEXT NOT NULL, created_at TEXT NOT NULL)",
                     "CREATE TABLE IF NOT EXISTS text_captures (capture_id TEXT PRIMARY KEY, text TEXT NOT NULL, "
                     "start_index INTEGER NOT NULL, end_index INTEGER NOT NULL, prefix TEXT NOT NULL, suffix TEXT NOT "
                     "NULL)",
                     "CREATE TABLE IF NOT EXISTS capture_notes (capture_id TEXT PRIMARY KEY, body TEXT NOT NULL, "
                     "updated_at TEXT NOT NULL)",
                     "CREATE TABLE IF NOT EXISTS deleted_captures (id TEXT PRIMARY KEY, deleted_at TEXT NOT NULL)",
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
        // The excerpt went on to become a highlight (schema 15).
        QCOMPARE(store.anchor("91ffeb1a-df10-4a54-a6fc-8a8b2c629b13")["source"].toUrl(), source);
        QCOMPARE(store.searchKnowledge("kept excerpt").size(), 1);
        QCOMPARE(store.searchKnowledge("kept highlight").size(), 1);
        // Workspaces became collections of their papers.
        const auto topic = store.collections().first().toMap();
        QCOMPARE(topic["name"].toString(), QString("Topic"));
        QCOMPARE(topic["count"].toInt(), 1);
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
    void capturesBecomeAnnotationsAndNotes()
    {
        QTemporaryDir directory;
        const auto data = directory.filePath("data");
        const auto pdf = directory.filePath("paper.pdf");
        writeFixture(pdf);
        const auto source = QUrl::fromLocalFile(pdf);
        QString paper;
        {
            ResearchStore fresh(data);
            QString error;
            QVERIFY2(fresh.initialize(&error), qPrintable(error));
            QVERIFY(fresh.rememberDocument(source));
            paper = fresh.documentLinkId(source);
        }
        QVERIFY(!paper.isEmpty());
        QVERIFY(QDir().mkpath(data + "/captures/trash"));
        QImage clip(8, 8, QImage::Format_RGB32);
        clip.fill(Qt::red);
        QVERIFY(clip.save(data + "/captures/web.png"));
        QVERIFY(clip.save(data + "/captures/trash/gone.png"));
        {
            // The capture tables as schema 14 had them, with one capture of each kind.
            auto db = QSqlDatabase::addDatabase("QSQLITE", "v14");
            db.setDatabaseName(data + "/owelk.sqlite3");
            QVERIFY(db.open());
            QSqlQuery query(db);
            const QStringList statements{"DROP TABLE ai_folders", "ALTER TABLE ai_threads DROP COLUMN folder_id",
                "CREATE TABLE captures (id TEXT PRIMARY KEY, document_id TEXT NOT NULL, sha256 TEXT NOT NULL, page "
                "INTEGER NOT NULL, x REAL NOT NULL, y REAL NOT NULL, width REAL NOT NULL, height REAL NOT NULL, image "
                "TEXT NOT NULL, created_at TEXT NOT NULL, caption TEXT NOT NULL DEFAULT '', anchor_kind TEXT NOT NULL "
                "DEFAULT 'pdf')",
                "CREATE TABLE text_captures (capture_id TEXT PRIMARY KEY, text TEXT NOT NULL, start_index INTEGER NOT "
                "NULL, end_index INTEGER NOT NULL, prefix TEXT NOT NULL, suffix TEXT NOT NULL)",
                "CREATE TABLE capture_notes (capture_id TEXT PRIMARY KEY, body TEXT NOT NULL, updated_at TEXT NOT "
                "NULL)",
                "CREATE TABLE deleted_captures (id TEXT PRIMARY KEY, deleted_at TEXT NOT NULL)",
                "INSERT INTO documents(id,url,added_at,kind) VALUES('web-doc','https://example.com/post','2026-09-01',"
                "'web')",
                "INSERT INTO captures VALUES('region','" + paper
                    + "','h',1,.1,.2,.3,.4,'region.png','2026-09-01','Figure 2: Drift','pdf')",
                "INSERT INTO capture_notes VALUES('region','compare with table one','2026-09-02')",
                "INSERT INTO captures VALUES('excerpt','" + paper + "','h',2,.1,.5,.8,.1,'','2026-09-01','','pdf')",
                "INSERT INTO text_captures VALUES('excerpt','kept excerpt words',10,28,'','')",
                "INSERT INTO captures VALUES('trashed','" + paper + "','h',3,.1,.1,.2,.2,'','2026-09-01','','pdf')",
                "INSERT INTO text_captures VALUES('trashed','thrown away words',0,5,'','')",
                "INSERT INTO deleted_captures VALUES('trashed','2026-09-03')",
                "INSERT INTO captures VALUES('web','web-doc','',0,0,0,1,1,'web.png','2026-09-01','A web chart','web')",
                "INSERT INTO capture_notes VALUES('web','seen on the blog','2026-09-02')",
                "INSERT INTO captures VALUES('gone','web-doc','',0,0,0,1,1,'gone.png','2026-09-01','','web')",
                "INSERT INTO deleted_captures VALUES('gone','2026-09-04')",
                "INSERT INTO notes(id,title,body,created_at,updated_at) VALUES('n1','Reading','See "
                "owelk://capture/excerpt and owelk://capture/web','2026-09-01','2026-09-01')",
                "INSERT INTO links(from_kind,from_id,to_kind,to_id,created_at) VALUES('note','n1','capture','excerpt',"
                "'2026-09-01')",
                "INSERT INTO links(from_kind,from_id,to_kind,to_id,created_at) VALUES('note','n1','capture','web',"
                "'2026-09-01')",
                "INSERT INTO links(from_kind,from_id,to_kind,to_id,created_at) VALUES('note','n1','capture','purged',"
                "'2026-09-01')",
                "PRAGMA user_version=14"};
            for (const auto &sql : statements) QVERIFY2(query.exec(sql), qPrintable(query.lastError().text() + sql));
            db.close();
        }
        QSqlDatabase::removeDatabase("v14");
        ResearchStore store(data);
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QCOMPARE(QDir(data + "/backups").entryList({"before-schema-15-*.sqlite3"}).size(), 1);
        const auto rows = [&](const QString &sql) {
            WorkerConnection db(data + "/owelk.sqlite3", true);
            QSqlQuery query(db.db);
            QStringList out;
            if (query.exec(sql))
                while (query.next()) {
                    QStringList fields;
                    for (int i = 0; i < query.record().count(); ++i) fields << query.value(i).toString();
                    out << fields.join('|');
                }
            return out;
        };
        // A region is an area annotation with its caption and note; excerpts are highlights, a trashed one
        // removed (kept in the table).
        QCOMPARE(rows("SELECT kind,page,text,body,deleted_at FROM highlights WHERE id='region'"),
            QStringList{"area|1|Figure 2: Drift|compare with table one|"});
        QCOMPARE(store.anchor("region")["bounds"].toMap()["width"].toDouble(), .3);
        QCOMPARE(rows("SELECT kind,text,start_index,end_index FROM highlights WHERE id='excerpt'"),
            QStringList{"highlight|kept excerpt words|10|28"});
        QCOMPARE(
            rows("SELECT kind,deleted_at FROM highlights WHERE id='trashed'"), QStringList{"highlight|2026-09-03"});
        QCOMPARE(store.searchKnowledge("compare with table").value(0).toMap()["kind"].toString(), QString("highlight"));
        // Web clips are notes with their picture (copied next to the annotation images); a trashed one is a
        // trashed note.
        const auto web = store.note("web");
        QCOMPARE(web["title"].toString(), QString("A web chart"));
        QVERIFY(web["body"].toString().startsWith("![](annotations/web.png)"));
        QVERIFY(web["body"].toString().contains("seen on the blog"));
        QVERIFY(web["body"].toString().contains("(https://example.com/post)"));
        QVERIFY(store.markdownHtml(web["body"].toString(), "", "", 0)
                .contains(QUrl::fromLocalFile(data + "/annotations/web.png").toString()));
        QVERIFY(QFileInfo::exists(data + "/annotations/web.png"));
        QVERIFY(QFileInfo::exists(data + "/annotations/gone.png"));
        QCOMPARE(rows("SELECT deleted_at FROM notes WHERE id='gone'"), QStringList{"2026-09-04"});
        // Links and note links follow; a link to a capture deleted for good is gone.
        QCOMPARE(store.note("n1")["body"].toString(), QString("See owelk://highlight/excerpt and owelk://note/web"));
        QCOMPARE(rows("SELECT to_kind,to_id FROM links WHERE from_id='n1' ORDER BY to_id"),
            (QStringList{"highlight|excerpt", "note|web"}));
        QCOMPARE(rows("SELECT name FROM sqlite_master WHERE name LIKE '%capture%'"), QStringList{});
        QVERIFY(QFileInfo::exists(data + "/captures/web.png")); // The old files stay where they were.
    }
    void keptPdfsAreRenamedAfterTheirTitles()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        // An added PDF is Owelk's copy under its original name; one kept elsewhere is not Owelk's to rename.
        const auto original = directory.filePath("2401.12345v2.pdf");
        writeFixture(original, "Radar: Odometry at Night");
        QCOMPARE(store.addDocuments({QUrl::fromLocalFile(original)}), 1);
        const auto kept = store.libraryDocuments()[0].toMap()["url"].toUrl();
        QVERIFY(store.keptByOwelk(kept));
        QCOMPARE(QFileInfo(kept.toLocalFile()).fileName(), QString("2401.12345v2.pdf"));
        QTRY_COMPARE_WITH_TIMEOUT(store.displayName(kept), QString("Radar: Odometry at Night"), 10000);
        const auto id = store.documentLinkId(kept);
        QVERIFY(store.setSetting("library.keepPdfs", "0"));
        const auto outside = QUrl::fromLocalFile(directory.filePath("outside.pdf"));
        writeFixture(outside.toLocalFile(), "Outside Paper");
        QCOMPARE(store.addDocuments({outside}), 1);
        QVERIFY(!store.keptByOwelk(outside));
        QTRY_COMPARE_WITH_TIMEOUT(store.displayName(outside), QString("Outside Paper"), 10000);
        // Renamed like a download ("Title - Subtitle"); the paper keeps its ID, the old path still finds it.
        QSignalSpy relinked(&store, &ResearchStore::sourceRelinked);
        QCOMPARE(store.renamePapersToTitles({kept, outside}), 1);
        const auto renamed = store.resolvedSource(kept);
        QCOMPARE(QFileInfo(renamed.toLocalFile()).fileName(), QString("Radar - Odometry at Night.pdf"));
        QVERIFY(QFileInfo::exists(renamed.toLocalFile()));
        QVERIFY(!QFileInfo::exists(kept.toLocalFile()));
        QCOMPARE(store.documentLinkId(renamed), id);
        QCOMPARE(relinked.size(), 1);
        QCOMPARE(store.displayName(renamed), QString("Radar: Odometry at Night"));
        QVERIFY(QFileInfo::exists(original)); // The file it came from is untouched.
        QCOMPARE(QFileInfo(store.resolvedSource(outside).toLocalFile()).fileName(), QString("outside.pdf"));
        // Already named after its title: nothing to do, and it says so.
        QSignalSpy said(&store, &ResearchStore::message);
        QCOMPARE(store.renamePapersToTitles({renamed}), 0);
        QCOMPARE(said.last().at(0).toString(), QString("Every PDF already has this name."));
        // Owelk shows the paper by the same parts (the title as written), everywhere it names it.
        QVERIFY(store.updateDocumentDetails(renamed,
            {{"title", "Radar: Odometry at Night"}, {"authors", "Ada Lovelace, Alan Turing"}, {"year", "1843"}}));
        QVERIFY(store.setSetting("pdfNames.parts", "author,year,title,-arxiv"));
        QCOMPARE(store.displayName(renamed), QString("Lovelace et al. - 1843 - Radar: Odometry at Night"));
        const auto rows = store.libraryDocuments();
        QVERIFY(std::any_of(rows.cbegin(), rows.cend(), [&](const QVariant &row) {
            return row.toMap()["name"].toString() == "Lovelace et al. - 1843 - Radar: Odometry at Night";
        }));
        QVERIFY(store.setSetting("pdfNames.parts", "title,-author,-year,-arxiv"));
        QCOMPARE(store.displayName(renamed), QString("Radar: Odometry at Night"));
    }
    void aiChatsMoveIntoThreadsOnUpgrade()
    {
        QTemporaryDir directory;
        const auto data = directory.filePath("data");
        const auto pdf = QUrl::fromLocalFile(directory.filePath("paper.pdf"));
        writeFixture(pdf.toLocalFile());
        QString paperChat, filedChat, looseChat, methods, paper;
        {
            ResearchStore fresh(data);
            QString error;
            QVERIFY2(fresh.initialize(&error), qPrintable(error));
            QVERIFY(fresh.rememberDocument(pdf));
            paper = fresh.documentLinkId(pdf);
            methods = fresh.createCollection("Methods");
            const QVariantMap base{{"provider", "claude"}, {"model", "m"}};
            auto about = base;
            about.insert({{"title", "About"}, {"source", pdf}});
            paperChat = fresh.createAiThread(about);
            filedChat = fresh.createAiThread(base);
            looseChat = fresh.createAiThread(base);
        }
        {
            // As schema 16 had it: no folders; a chat filed under a collection by a link.
            auto db = QSqlDatabase::addDatabase("QSQLITE", "v16");
            db.setDatabaseName(data + "/owelk.sqlite3");
            QVERIFY(db.open());
            QSqlQuery query(db);
            for (const auto &sql :
                {QString("DROP TABLE ai_folders"), QString("ALTER TABLE ai_threads DROP COLUMN folder_id"),
                    "INSERT INTO links VALUES('ai','" + filedChat + "','collection','" + methods + "','2026-10-12')",
                    QString("PRAGMA user_version=16")})
                QVERIFY2(query.exec(sql), qPrintable(query.lastError().text() + sql));
            db.close();
        }
        QSqlDatabase::removeDatabase("v16");
        ResearchStore store(data);
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QCOMPARE(QDir(data + "/backups").entryList({"before-schema-17-*.sqlite3"}).size(), 1);
        QMap<QString, QString> folders;
        for (const auto &value : store.aiThreads())
            folders.insert(value.toMap()["id"].toString(), value.toMap()["folder"].toString());
        QCOMPARE(folders.value(paperChat), "document:" + paper);
        QCOMPARE(folders.value(filedChat), "collection:" + methods);
        QCOMPARE(folders.value(looseChat), QString());
        QCOMPARE(store.aiFolders().size(), 2);
        // The collection links are gone (the chat lives in the collection's Thread now).
        WorkerConnection db(data + "/owelk.sqlite3", true);
        QSqlQuery links(db.db);
        QVERIFY(links.exec("SELECT count(*) FROM links WHERE to_kind='collection'") && links.next());
        QCOMPARE(links.value(0).toInt(), 0);
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
    void removalPreservesOriginalAndAnnotations()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("keep.pdf");
        writeFixture(path);
        const auto source = QUrl::fromLocalFile(path);
        const auto originalSize = QFileInfo(path).size();
        QString region;
        {
            ResearchStore store(directory.filePath("data"));
            QString error;
            QVERIFY(store.initialize(&error));
            QVERIFY(store.rememberDocument(source));
            region = markRegion(store, source);
            QVERIFY(!region.isEmpty());
            QVERIFY(store.removeRecentDocument(source));
            QVERIFY(store.recentDocuments().isEmpty());
            QCOMPARE(store.anchor(region)["source"].toUrl(), source);
            QCOMPARE(QFileInfo(path).size(), originalSize);
        }
        ResearchStore reopened(directory.filePath("data"));
        QString error;
        QVERIFY(reopened.initialize(&error));
        QCOMPARE(reopened.anchor(region)["source"].toUrl(), source);
        QVERIFY(reopened.recentDocuments().isEmpty());
        QVERIFY(QFileInfo::exists(path));
    }
    void tabSessionsPersist()
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
    }
    void webTabAddressesSurviveSaving()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.path());
        QString error;
        QVERIFY(store.initialize(&error));
        // QUrl::toString() would decode %20 to a space, which the tab layout check rejects on the next start.
        const QString address = "https://scholar.google.com/scholar?q=radar%20inertial%20odometry";
        const QVariantMap web{
            {"id", "w1"}, {"kind", "web"}, {"source", address}, {"title", ""}, {"position", QVariantMap{{"page", 0}}}};
        const QVariantMap group{{"kind", "group"}, {"id", "g1"}, {"activeTab", "w1"}, {"tabs", QVariantList{web}}};
        QVERIFY(store.saveSession(QVariantMap{{"version", 2}, {"tree", group}, {"activeGroup", "g1"}}));
        const auto tabs = store.session()["tree"].toMap()["tabs"].toList();
        QCOMPARE(tabs.size(), 1);
        QCOMPARE(tabs[0].toMap()["source"].toString(), address);
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
    }
    void homeDataSurvivesRestart()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("Alpha Paper.pdf");
        writeFixture(path);
        const auto source = QUrl::fromLocalFile(path);
        {
            ResearchStore store(directory.filePath("data"));
            QString error;
            QVERIFY(store.initialize(&error));
            QVERIFY(store.rememberDocument(source));
            const QVariantMap position{{"page", 3}, {"y", .2}, {"zoom", 1.4}};
            const QVariantMap state{
                {"left", QVariantMap{{"source", source.toString()}, {"position", position}}}, {"active", 0}};
            QVERIFY(store.saveSession(state));
            QCOMPARE(store.continueReading().value("position").toMap().value("page").toInt(), 3);
            QCOMPARE(store.readingPosition(source), position);
            const auto results = store.searchKnowledge("ALPHA");
            QCOMPARE(results.size(), 1);
            QCOMPARE(results[0].toMap()["kind"].toString(), "paper");
            QVERIFY(store.searchKnowledge("' OR 1=1 --").isEmpty());
            QVERIFY(store.searchKnowledge("").isEmpty());
        }
        ResearchStore reopened(directory.filePath("data"));
        QString error;
        QVERIFY(reopened.initialize(&error));
        QCOMPARE(reopened.continueReading().value("position").toMap().value("page").toInt(), 3);
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
    void textIndexKeepsOnlyLibraryPapers()
    {
        // A paper deleted on another computer arrives as a missing row: its index entry goes too.
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        const auto a = QUrl::fromLocalFile(directory.filePath("a.pdf")),
                   b = QUrl::fromLocalFile(directory.filePath("b.pdf"));
        writeFixture(a.toLocalFile());
        writeFixture(b.toLocalFile());
        QVERIFY(store.rememberDocument(a));
        QVERIFY(store.rememberDocument(b));
        auto *index = qobject_cast<PaperIndex *>(store.paperIndex());
        QTRY_VERIFY_WITH_TIMEOUT(!index->busy() && index->documents().size() == 2, 20000);
        {
            WorkerConnection db(store.dataDirectory() + "/owelk.sqlite3");
            QSqlQuery query(db.db);
            query.prepare("DELETE FROM documents WHERE url=?");
            query.addBindValue(b.toString());
            QVERIFY(query.exec());
        }
        QFile::remove(b.toLocalFile());
        QCOMPARE(store.pruneIndex(), 1);
        QTRY_COMPARE_WITH_TIMEOUT(index->documents().size(), 1, 10000);
        QCOMPARE(index->documents()[0].toMap()["source"].toUrl(), a);
        QCOMPARE(store.pruneIndex(), 0);
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
    void annotationsFromAnotherCopyCanBeShownWhenTheyFit()
    {
        QTemporaryDir directory;
        const auto path = directory.filePath("stamped.pdf");
        writeFixture(path, "Stamped Paper", 2);
        const auto source = QUrl::fromLocalFile(path);
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QVERIFY(store.rememberDocument(source));
        QSignalSpy loaded(&store, &ResearchStore::highlightsLoaded), saved(&store, &ResearchStore::highlightSaved);
        {
            QPdfDocument pdf;
            QCOMPARE(pdf.load(path), QPdfDocument::Error::None);
            const auto bounds
                = pdf.getSelectionAtIndex(0, int(pdf.getAllText(0).text().indexOf("Research finding 1.2")), 40)
                      .boundingRectangle();
            const QPointF from(bounds.left(), bounds.center().y()), to(bounds.right(), bounds.center().y());
            store.highlightText(source, 0, from, to, pdf.getSelection(0, from, to).text());
        }
        QTRY_COMPARE_WITH_TIMEOUT(saved.size(), 1, 10000);
        store.loadHighlights(source);
        QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 1, 5000);
        QCOMPARE(loaded.last().at(2).toList().size(), 1);
        // The same paper downloaded again, stamped differently: other bytes, same pages.
        QFile::remove(path);
        writeFixture(path, "Stamped Paper (downloaded again)", 2);
        FileFingerprint::clearCache();
        store.loadHighlights(source);
        QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 2, 5000);
        QVERIFY(loaded.last().at(2).toList().isEmpty());
        QCOMPARE(loaded.last().at(5).toInt(), 1);
        QVERIFY(loaded.last().at(3).toString().contains("another copy"));
        QCOMPARE(store.adoptAnnotations(source)["moved"].toInt(), 1);
        store.loadHighlights(source);
        QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 3, 5000);
        QCOMPARE(loaded.last().at(2).toList().size(), 1);
        QCOMPARE(loaded.last().at(5).toInt(), 0);
        // A different paper under the same name: the words are not there, so they stay hidden.
        QFile::remove(path);
        writeTextFixture(path, {"Something else entirely.", "Nothing about findings here."});
        FileFingerprint::clearCache();
        // Asked first: nothing changes until the reader agrees, then they are deleted.
        QCOMPARE(store.adoptAnnotations(source)["misfits"].toInt(), 1);
        store.loadHighlights(source);
        QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 4, 5000);
        QCOMPARE(loaded.last().at(5).toInt(), 1);
        QCOMPARE(store.adoptAnnotations(source, true)["misfits"].toInt(), 1);
        store.loadHighlights(source);
        QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 5, 5000);
        QCOMPARE(loaded.last().at(5).toInt(), 0);
        QVERIFY(loaded.last().at(3).toString().isEmpty());
    }
    void aiConversationsGoToTheTrashFirst()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QStringList ids;
        for (const auto &title : {"First", "Second", "Third"}) {
            const auto id = store.createAiThread({{"title", title}, {"provider", "claude"}, {"model", "m"}});
            QVERIFY(store.appendAiMessage(id, {{"role", "user"}, {"content", QString("question about ") + title}}));
            ids << id;
        }
        QCOMPARE(store.aiThreads().size(), 3);
        // Two moved to the Trash: hidden from the list and from search, kept whole.
        QCOMPARE(store.trashAiThreads({ids[0], ids[1]}), 2);
        QCOMPARE(store.aiThreads().size(), 1);
        QCOMPARE(store.trashCount(), 2);
        QCOMPARE(store.trash()[0].toMap()["kind"].toString(), QString("ai"));
        QVERIFY(store.trash()[0].toMap()["daysLeft"].toInt() >= 29);
        const auto hits = store.searchKnowledge("question about");
        QVERIFY(std::none_of(
            hits.cbegin(), hits.cend(), [&](const QVariant &hit) { return hit.toMap()["id"].toString() == ids[0]; }));
        QCOMPARE(store.aiThread(ids[0])["messages"].toList().size(), 1);
        // A note linking to one shows where it is: in the Trash, or (deleted for good) greyed.
        const auto linked = "[First](owelk://ai/" + ids[0] + ") and [Second](owelk://ai/" + ids[1] + ")";
        QVERIFY(store.aiThread(ids[0])["trashed"].toBool());
        QVERIFY(store.linkTarget("ai", ids[0])["trashed"].toBool());
        // Restored as it was; deleted for good only from the Trash.
        QCOMPARE(store.trashAiThreads({ids[0]}, false), 1);
        QVERIFY(!store.aiThread(ids[0])["trashed"].toBool());
        QCOMPARE(store.aiThreads().size(), 2);
        QCOMPARE(store.emptyTrash(), 1);
        QVERIFY(store.aiThread(ids[1]).isEmpty());
        const auto html = store.markdownHtml(linked, "#0000aa", "#111111", 14, "#999999");
        QCOMPARE(html.count("owelk://ai/"), 1);
        QVERIFY(html.contains("Deleted conversation"));
        QCOMPARE(store.trashCount(), 0);
        QCOMPARE(store.aiThreads().size(), 2);
    }
    void aiChatsLiveInThreads()
    {
        QTemporaryDir directory;
        const auto pdf = QUrl::fromLocalFile(directory.filePath("paper.pdf"));
        writeFixture(pdf.toLocalFile(), "Grouped Paper");
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QVERIFY(store.setSetting("library.keepPdfs", "0"));
        QVERIFY(store.rememberDocument(pdf));
        const auto methods = store.createCollection("Methods");
        const auto chat = [&](const char *title, const QVariantMap &extra = {}) {
            QVariantMap thread{{"title", title}, {"provider", "claude"}, {"model", "m"}};
            thread.insert(extra);
            return store.createAiThread(thread);
        };
        const auto folderOf = [&](const QString &id) {
            for (const auto &value : store.aiThreads())
                if (value.toMap()["id"].toString() == id) return value.toMap()["folder"].toString();
            return QStringLiteral("missing");
        };
        const auto folderField = [&](const QString &id, const char *field) {
            for (const auto &value : store.aiFolders())
                if (value.toMap()["id"].toString() == id) return value.toMap()[field].toString();
            return QString();
        };
        const auto folderName = [&](const QString &id) { return folderField(id, "name"); };
        // A paper's chats start in its own Thread, named after the paper; the same one for every chat.
        const auto first = chat("About the paper", {{"source", pdf}});
        const auto second = chat("More about it", {{"source", pdf}});
        const auto paperThread = folderOf(first);
        QCOMPARE(paperThread, "document:" + store.documentLinkId(pdf));
        QCOMPARE(folderOf(second), paperThread);
        QCOMPARE(folderName(paperThread), store.displayName(pdf));
        // A chat asked of a collection starts in the collection's Thread; one about nothing, unfiled.
        const auto asked = chat("Asked of Methods", {{"collection", methods}});
        QCOMPARE(folderOf(asked), "collection:" + methods);
        QCOMPARE(folderName("collection:" + methods), QString("Methods"));
        const auto loose = chat("Loose");
        QCOMPARE(folderOf(loose), QString());
        // Threads of one's own: made, chats moved in (a chat started there stays there), renamed.
        const auto thesis = store.createAiFolder("  Thesis  ");
        QCOMPARE(folderName(thesis), QString("Thesis"));
        QCOMPARE(chat("Begun in Thesis", {{"source", pdf}, {"folder", thesis}}).isEmpty(), false);
        // Moved in, a chat does not make its new Thread more recent; nor does a new name.
        const auto thesisUpdated = folderField(thesis, "updatedAt");
        QTest::qSleep(5);
        QCOMPARE(store.moveAiThreads({loose, first}, thesis), 2);
        QCOMPARE(folderOf(loose), thesis);
        QCOMPARE(folderField(thesis, "updatedAt"), thesisUpdated);
        QCOMPARE(store.moveAiThreads({loose}, thesis), 0);
        QCOMPARE(store.moveAiThreads({loose}, "missing"), 0);
        const auto paperUpdated = folderField(paperThread, "updatedAt");
        QVERIFY(store.renameAiFolder(paperThread, "My paper"));
        QCOMPARE(folderName(paperThread), QString("My paper"));
        QCOMPARE(folderField(paperThread, "updatedAt"), paperUpdated);
        QVERIFY(!store.renameAiFolder(thesis, "  "));
        // A deleted Thread lets its chats go unfiled; a deleted collection's Thread keeps its name.
        QVERIFY(store.deleteAiFolder(thesis));
        QCOMPARE(folderOf(loose), QString());
        QCOMPARE(folderOf(first), QString());
        QCOMPARE(store.aiThreads().size(), 5);
        QVERIFY(store.deleteCollection(methods));
        QCOMPARE(folderName("collection:" + methods), QString("Methods"));
        // Search finds the words of titles and answers; % and _ are plain characters.
        QVERIFY(store.appendAiMessage(
            loose, {{"role", "assistant"}, {"content", "Transformer depth matters, 100% of the time."}}));
        QCOMPARE(store.aiThreads("transformer").size(), 1);
        QCOMPARE(store.aiThreads("100%").size(), 1);
        QCOMPARE(store.aiThreads("Methods").size(), 1);
        QVERIFY(store.aiThreads("no_such").isEmpty());
        // A question is found by what was typed, not by the paper text sent along with it: here and in the search.
        QVERIFY(store.appendAiMessage(loose,
            {{"role", "user"}, {"display", "What about depth?"}, {"content", "<paper>quaternion appendix</paper>"}}));
        const auto ai = [&](const QString &words) {
            int found = 0;
            for (const auto &row : store.searchKnowledge(words, {}, "ai")) found += row.toMap()["kind"] == "ai";
            return found;
        };
        QCOMPARE(ai("transformer depth"), 1);
        QCOMPARE(ai("What about depth"), 1);
        QCOMPARE(ai("quaternion"), 0);
        QVERIFY(store.aiThreads("quaternion").isEmpty());
    }
    void oneTrashForPapersNotesAndConversations()
    {
        QTemporaryDir directory;
        const auto pdf = QUrl::fromLocalFile(directory.filePath("paper.pdf"));
        writeFixture(pdf.toLocalFile(), "Trashed Paper");
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QVERIFY(store.setSetting("library.keepPdfs", "0"));
        QVERIFY(store.rememberDocument(pdf));
        const auto thread = store.createAiThread({{"title", "Old question"}, {"provider", "claude"}, {"model", "m"}});
        const auto note = store.createNote("Draft", "about it");
        // A note that stays links to the conversation and the paper.
        const auto keeper = store.createNote(
            "Keeper", "[q](owelk://ai/" + thread + ") [p](owelk://document/" + store.documentLinkId(pdf) + ")");
        QCOMPARE(store.trashAiThreads({thread}), 1);
        QTest::qWait(5);
        QVERIFY(store.deleteNote(note));
        QTest::qWait(5);
        QCOMPARE(store.deletePapers({pdf}), 1);
        // All three together, newest first.
        auto rows = store.trash();
        QCOMPARE(store.trashCount(), 3);
        QCOMPARE(rows.size(), 3);
        QCOMPARE(rows[0].toMap()["kind"].toString(), QString("paper"));
        QCOMPARE(rows[0].toMap()["url"].toUrl(), pdf);
        QCOMPARE(rows[1].toMap()["kind"].toString(), QString("note"));
        QCOMPARE(rows[2].toMap()["kind"].toString(), QString("ai"));
        QCOMPARE(store.notesLinkingTo({rows[0], rows[2]}), 1);
        QCOMPARE(store.notesLinkingTo({rows[1]}), 0);
        // Restored as they were.
        QCOMPARE(store.restoreFromTrash({rows[1]}), 1);
        QVERIFY(!store.note(note)["deleted"].toBool());
        QCOMPARE(store.trashCount(), 2);
        // Older than the chosen days: deleted for good (never with "Never").
        {
            WorkerConnection db(store.dataDirectory() + "/owelk.sqlite3");
            QSqlQuery old(db.db);
            QVERIFY(
                old.exec("UPDATE ai_threads SET trashed_at='2020-01-01T00:00:00.000Z' WHERE trashed_at IS NOT NULL"));
        }
        QVERIFY(store.setSetting("trash.days", "0"));
        store.purgeExpired();
        QCOMPARE(store.trashCount(), 2);
        QVERIFY(store.setSetting("trash.days", "30"));
        store.purgeExpired();
        QCOMPARE(store.trashCount(), 1);
        QVERIFY(store.aiThread(thread).isEmpty());
        QCOMPARE(store.emptyTrash(), 1);
        QCOMPARE(store.trashCount(), 0);
        QVERIFY(QFileInfo::exists(pdf.toLocalFile())); // A file outside Owelk is left alone.
        QVERIFY(!store.note(keeper).isEmpty());
    }
    void downloadedPdfsTakeTheirPaperName()
    {
        PaperMetadata paper;
        paper.title = "OpenFrontier: General Navigation with Visual-Language Grounded Frontiers";
        paper.authors = "Esteban Padilla-Cerdio, Boyang Sun";
        paper.year = "2026";
        QCOMPARE(PaperMetadataText::fileStem(paper),
            QString("OpenFrontier - General Navigation with Visual-Language Grounded Frontiers"));
        paper.title = QString("What? A/B \"tests\" ") + QString(120, 'x') + "...";
        QVERIFY(!PaperMetadataText::fileStem(paper).contains(QRegularExpression("[?/\"]")));
        QVERIFY(PaperMetadataText::fileStem(paper).size() <= 120);
        QCOMPARE(PaperMetadataText::fileStem({"A/B Test: Faster.", "", "", "", ""}), QString("A B Test - Faster"));
        QVERIFY(PaperMetadataText::fileStem({}).isEmpty());
        // Parts chosen in Settings, in their order; a part the paper lacks is left out.
        paper.title = "OpenFrontier: General Navigation with Visual-Language Grounded Frontiers";
        QCOMPARE(PaperMetadataText::fileStem(paper, {"author", "year", "title"}),
            QString("Padilla-Cerdio et al. - 2026 - OpenFrontier - General Navigation with Visual-Language Grounded "
                    "Frontiers"));
        QCOMPARE(PaperMetadataText::fileStem(paper, {"title", "year"}),
            QString("OpenFrontier - General Navigation with Visual-Language Grounded Frontiers - 2026"));
        QCOMPARE(PaperMetadataText::fileStem({"Solo", "Jane Doe", "20xx", "", ""}, {"author", "year", "title"}),
            QString("Doe - Solo"));
        QCOMPARE(PaperMetadataText::fileStem({"Untitled Authors", "", "", "", ""}, {"author", "title"}),
            QString("Untitled Authors"));
        paper.title = QString(200, 'y');
        QVERIFY(PaperMetadataText::fileStem(paper, {"author", "year", "title"}).size() <= 120);

        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QCOMPARE(store.fileNameParts(), QStringList{"title"});
        QVERIFY(store.setSetting("pdfNames.parts", "year,-author,title,-arxiv"));
        QCOMPARE(store.fileNameParts(), (QStringList{"year", "title"}));
        QCOMPARE(store.sampleFileName(store.fileNameParts()), QString("2017 - Attention Is All You Need.pdf"));
        QVERIFY(store.setSetting("pdfNames.parts", "title"));
        QSignalSpy named(&store, &ResearchStore::downloadNamed);
        const auto download = store.downloadTarget("2305.01234v2.pdf", true)["url"].toUrl();
        writeFixture(download.toLocalFile(), "Downloaded Paper Title");
        store.nameDownloadedPdf(download);
        QTRY_COMPARE_WITH_TIMEOUT(named.size(), 1, 10000);
        const auto renamed = named.first().at(1).toUrl();
        QCOMPARE(named.first().at(0).toUrl(), download);
        QCOMPARE(QFileInfo(renamed.toLocalFile()).fileName(), QString("Downloaded Paper Title.pdf"));
        QVERIFY(!QFileInfo::exists(download.toLocalFile()));
        // A file the Library uses keeps its name, and so does every download when the setting says so.
        QVERIFY(store.rememberDocument(renamed));
        store.nameDownloadedPdf(renamed);
        QTRY_COMPARE_WITH_TIMEOUT(named.size(), 2, 10000);
        QCOMPARE(named.last().at(1).toUrl(), renamed);
        QVERIFY(store.setSetting("web.pdfNames", "original"));
        const auto other = store.downloadTarget("other.pdf", true)["url"].toUrl();
        writeFixture(other.toLocalFile(), "Another Paper Title");
        store.nameDownloadedPdf(other);
        QTRY_COMPARE_WITH_TIMEOUT(named.size(), 3, 10000);
        QCOMPARE(named.last().at(1).toUrl(), other);
    }
    void keptPdfsAreCopiedIntoTheLibrary()
    {
        QTemporaryDir directory;
        QVERIFY(QDir().mkpath(directory.filePath("Downloads")));
        const auto path = directory.filePath("Downloads/paper.pdf");
        writeFixture(path, "Kept Paper");
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        // A PDF from elsewhere opens as Owelk's own copy, under its name; the original stays.
        const auto kept = store.adoptPdf(QUrl::fromLocalFile(path));
        QVERIFY(kept.toLocalFile().startsWith(store.papersFolder() + "/"));
        QCOMPARE(QFileInfo(kept.toLocalFile()).fileName(), QString("paper.pdf"));
        QVERIFY(QFileInfo::exists(path));
        QVERIFY(store.rememberDocument(kept));
        QCOMPARE(store.adoptPdf(kept), kept);
        QTRY_COMPARE_WITH_TIMEOUT(store.displayName(kept), QString("Kept Paper"), 10000);
        QTRY_VERIFY_WITH_TIMEOUT(!store.libraryDocuments().isEmpty(), 5000);
        // The same bytes again open the same paper; a repeated download is not kept twice.
        const auto again = directory.filePath("Downloads/paper (1).pdf");
        QVERIFY(QFile::copy(path, again));
        QTRY_COMPARE_WITH_TIMEOUT(store.adoptPdf(QUrl::fromLocalFile(again)), kept, 10000);
        const auto download = store.downloadTarget("paper.pdf", true)["url"].toUrl();
        QVERIFY(download.toLocalFile().startsWith(store.papersFolder() + "/"));
        QVERIFY(download != kept);
        QVERIFY(QFile::copy(path, download.toLocalFile()));
        QCOMPARE(store.adoptPdf(download), kept);
        QVERIFY(!QFileInfo::exists(download.toLocalFile()));
        QCOMPARE(QDir(store.papersFolder()).entryList(QDir::Files).size(), 1);
        // Other downloads still go to the download folder.
        QVERIFY(!store.downloadTarget("data.zip", false)["url"].toUrl().toLocalFile().startsWith(store.papersFolder()));

        // A paper added while PDFs were not kept is copied in on request and keeps its ID; the old
        // path still finds it and the original file is untouched.
        QVERIFY(store.setSetting("library.keepPdfs", "0"));
        const auto old = QUrl::fromLocalFile(directory.filePath("old.pdf"));
        writeFixture(old.toLocalFile(), "Old Paper");
        QCOMPARE(store.addDocuments({old}), 1);
        const auto id = store.documentLinkId(old);
        QVERIFY(store.setSetting("library.keepPdfs", "1"));
        QCOMPARE(store.outsidePdfCount(), 1);
        QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
        store.copyPdfsIntoLibrary();
        QVERIFY(store.copyingPdfs());
        QTRY_VERIFY_WITH_TIMEOUT(!store.copyingPdfs(), 10000);
        QCOMPARE(store.outsidePdfCount(), 0);
        QVERIFY(QFileInfo::exists(old.toLocalFile()));
        const auto moved = store.resolvedSource(old);
        QVERIFY(moved.toLocalFile().startsWith(store.papersFolder() + "/"));
        QCOMPARE(store.documentLinkId(moved), id);
        QCOMPARE(store.documentLinkId(old), id);
        QCOMPARE(store.libraryDocuments().size(), 2);
        // Two files with the same bytes added together become one paper.
        const auto twin = QUrl::fromLocalFile(directory.filePath("twin.pdf")),
                   twinCopy = QUrl::fromLocalFile(directory.filePath("twin copy.pdf"));
        writeFixture(twin.toLocalFile(), "Twin Paper");
        QVERIFY(QFile::copy(twin.toLocalFile(), twinCopy.toLocalFile()));
        store.addDocuments({twin, twinCopy});
        QTRY_COMPARE_WITH_TIMEOUT(store.libraryDocuments().size(), 3, 5000);
    }
    void quittingWhileCopyingPdfsInIsSafe()
    {
        QTemporaryDir directory;
        QVariantList papers;
        for (int i = 0; i < 6; ++i) {
            const auto path = directory.filePath(QStringLiteral("paper %1.pdf").arg(i));
            writeFixture(path, QStringLiteral("Paper %1").arg(i), 40);
            papers << QUrl::fromLocalFile(path);
        }
        {
            ResearchStore store(directory.filePath("data"));
            QString error;
            QVERIFY2(store.initialize(&error), qPrintable(error));
            QVERIFY(store.setSetting("library.keepPdfs", "0"));
            QCOMPARE(store.addDocuments(papers), 6);
            QVERIFY(store.setSetting("library.keepPdfs", "1"));
            store.copyPdfsIntoLibrary();
            QVERIFY(store.copyingPdfs());
        } // Gone while copying: the copy stops after its file and the store waits for it.
        ResearchStore reopened(directory.filePath("data"));
        QString error;
        QVERIFY2(reopened.initialize(&error), qPrintable(error));
        QCOMPARE(reopened.libraryDocuments().size(), 6);
        for (const auto &paper : papers) QVERIFY(QFileInfo::exists(paper.toUrl().toLocalFile()));
    }
    void fileNamesWorkOnEverySystem()
    {
        // A name from a Mac (or a server) becomes one Windows accepts too.
        QCOMPARE(portableFileName("Is attention all you need?.pdf"), QString("Is attention all you need.pdf"));
        QCOMPARE(portableFileName("A <b> \"quoted\" | piped*.pdf"), QString("A b quoted piped.pdf"));
        QCOMPARE(portableFileName("CON.pdf"), QString("CON_.pdf"));
        QCOMPARE(portableFileName("nul.tar.pdf"), QString("nul_.tar.pdf"));
        QCOMPARE(portableFileName("Draft. .pdf"), QString("Draft.pdf"));
        QCOMPARE(portableFileName("Console notes.pdf"), QString("Console notes.pdf"));
        QVERIFY(portableFileName("???.pdf").isEmpty());
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QCOMPARE(QFileInfo(store.downloadTarget("Why?.pdf", true)["url"].toUrl().toLocalFile()).fileName(),
            QString("Why.pdf"));
    }
    void redirectsNeverCaptureAnotherFile()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        // A paper renamed after its title still answers to its old name; a different PDF with that name becomes
        // a paper of its own, under another name.
        QVERIFY(QDir().mkpath(directory.filePath("a")) && QDir().mkpath(directory.filePath("b")));
        writeFixture(directory.filePath("a/fulltext.pdf"), "First Paper");
        writeFixture(directory.filePath("b/fulltext.pdf"), "Second Paper");
        const auto first = store.adoptPdf(QUrl::fromLocalFile(directory.filePath("a/fulltext.pdf")));
        QCOMPARE(QFileInfo(first.toLocalFile()).fileName(), QString("fulltext.pdf"));
        QVERIFY(store.rememberDocument(first));
        QTRY_COMPARE_WITH_TIMEOUT(store.displayName(first), QString("First Paper"), 10000);
        QCOMPARE(store.renamePapersToTitles({first}), 1);
        QVERIFY(store.resolvedSource(first) != first);
        const auto second = store.adoptPdf(QUrl::fromLocalFile(directory.filePath("b/fulltext.pdf")));
        QVERIFY(second != first);
        QVERIFY(store.rememberDocument(second));
        QVERIFY(store.documentLinkId(second) != store.documentLinkId(first));
        // A paper copied into the Library and then deleted for good: its original opens again, as itself.
        QVERIFY(store.setSetting("library.keepPdfs", "0"));
        const auto original = QUrl::fromLocalFile(directory.filePath("original.pdf"));
        writeFixture(original.toLocalFile(), "Original Paper");
        QCOMPARE(store.addDocuments({original}), 1);
        QVERIFY(store.setSetting("library.keepPdfs", "1"));
        QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
        store.copyPdfsIntoLibrary();
        QTRY_VERIFY_WITH_TIMEOUT(!store.copyingPdfs(), 10000);
        const auto copy = store.resolvedSource(original);
        QVERIFY(copy != original);
        QVERIFY(QFile::remove(copy.toLocalFile())); // Gone already, so the test sends nothing to the system Trash.
        QCOMPARE(store.deletePapers({original}), 1);
        QCOMPARE(store.purgePapers({original}), 1);
        QCOMPARE(store.resolvedSource(original), original);
        const auto reopened = store.adoptPdf(original);
        QVERIFY(QFileInfo::exists(reopened.toLocalFile()));
        QVERIFY(store.rememberDocument(reopened));
    }
    void keptPdfsFollowTheirFolder()
    {
        // PDFs kept in the data folder move when the PDF folder changes (the move to Documents/Owelk Library/Papers);
        // each paper keeps its ID and the old path still finds it.
        QTemporaryDir directory;
        const auto original = directory.filePath("paper.pdf");
        writeFixture(original, "Moving Paper");
        QUrl kept;
        QString id, error;
        {
            ResearchStore store(directory.filePath("data"));
            QVERIFY2(store.initialize(&error), qPrintable(error));
            kept = store.adoptPdf(QUrl::fromLocalFile(original));
            QVERIFY(kept.toLocalFile().startsWith(directory.filePath("data/papers/")));
            QVERIFY(store.rememberDocument(kept));
            id = store.documentLinkId(kept);
            QVERIFY(store.setSetting("library.folder", directory.filePath("Documents/Owelk/Papers")));
            QTRY_VERIFY_WITH_TIMEOUT(!store.busy(), 10000);
        }
        ResearchStore store(directory.filePath("data"));
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QCOMPARE(store.papersFolder(), directory.filePath("Documents/Owelk/Papers"));
        const auto moved = store.resolvedSource(kept);
        QCOMPARE(moved, QUrl::fromLocalFile(directory.filePath("Documents/Owelk/Papers/paper.pdf")));
        QVERIFY(QFileInfo::exists(moved.toLocalFile()));
        QVERIFY(!QFileInfo::exists(kept.toLocalFile()));
        QVERIFY(QFileInfo::exists(original));
        QCOMPARE(store.documentLinkId(moved), id);
        QCOMPARE(store.libraryDocuments().size(), 1);
        QCOMPARE(store.libraryDocuments()[0].toMap()["url"].toUrl(), moved);
    }
    void deletedPapersWaitInTheTrash()
    {
        QTemporaryDir directory;
        const auto a = QUrl::fromLocalFile(directory.filePath("a.pdf")),
                   b = QUrl::fromLocalFile(directory.filePath("b.pdf"));
        writeFixture(a.toLocalFile(), "Paper A");
        writeFixture(b.toLocalFile(), "Paper B");
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY2(store.initialize(&error), qPrintable(error));
        QVERIFY(store.setSetting("library.keepPdfs", "0")); // Files outside Owelk's folder are never touched.
        const auto topic = store.createCollection("Topic");
        QCOMPARE(store.addDocuments({a, b}, topic), 2);
        const auto region = markRegion(store, a);
        QVERIFY(!region.isEmpty());
        QSignalSpy deleted(&store, &ResearchStore::papersDeleted);
        // Deleted: out of the Library, still whole in the Trash, back with its collection on Restore.
        QCOMPARE(store.deletePapers({a, b}), 2);
        QCOMPARE(deleted.size(), 1);
        QCOMPARE(store.libraryDocuments().size(), 0);
        QCOMPARE(store.trashCount(), 2);
        QCOMPARE(store.collections()[0].toMap()["count"].toInt(), 0);
        QCOMPARE(store.restorePapers({b}), 1);
        QCOMPARE(store.libraryDocuments({{"collection", topic}}).size(), 1);
        // Opening a deleted paper's file brings it back too.
        QVERIFY(store.deletePapers({b}) == 1 && store.rememberDocument(b));
        QCOMPARE(store.trashCount(), 1);
        // Deleting for good removes the paper with its annotations; its own file outside Owelk stays.
        QCOMPARE(store.purgePapers({a}), 1);
        QCOMPARE(store.trashCount(), 0);
        {
            WorkerConnection db(store.dataDirectory() + "/owelk.sqlite3", true);
            QSqlQuery query(db.db);
            QVERIFY(query.exec("SELECT count(*) FROM highlights") && query.next());
            QCOMPARE(query.value(0).toInt(), 0);
        }
        QVERIFY(QFileInfo::exists(a.toLocalFile()));
        QCOMPARE(store.libraryDocuments().size(), 1);
        // After the chosen days the Trash empties itself; "Never" keeps papers.
        QCOMPARE(store.deletePapers({b}), 1);
        {
            WorkerConnection db(store.dataDirectory() + "/owelk.sqlite3");
            QSqlQuery old(db.db);
            QVERIFY(
                old.exec("UPDATE documents SET trashed_at='2020-01-01T00:00:00.000Z' WHERE trashed_at IS NOT NULL"));
        }
        QVERIFY(store.setSetting("trash.days", "0"));
        store.purgeExpired();
        QCOMPARE(store.trashCount(), 1);
        QVERIFY(store.setSetting("trash.days", "30"));
        store.purgeExpired();
        QCOMPARE(store.trashCount(), 0);
        QVERIFY(QFileInfo::exists(b.toLocalFile()));
    }
    void addRemoveAndRestoreLibraryPapers()
    {
        QTemporaryDir directory;
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        QVERIFY(store.setSetting("library.keepPdfs", "0")); // Papers read from where they are.
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
        // While it runs it is in the status bar's progress; gone once done.
        QCOMPARE(store.tasks().size(), 1);
        QVERIFY(store.tasks()[0].toMap()["id"].toString().startsWith("import:"));
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 10000);
        QTRY_VERIFY(store.tasks().isEmpty());
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
        // Background work such as annotations can open it too.
        QVERIFY(!markRegion(store, source).isEmpty());
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
            // A picture annotation: its file goes into the backup too.
            QImage picture(8, 8, QImage::Format_RGB32);
            picture.fill(Qt::blue);
            QVERIFY(picture.save(directory.filePath("picture.png")));
            QSignalSpy loaded(&store, &ResearchStore::highlightsLoaded),
                saved(&store, &ResearchStore::annotationFinished);
            store.loadHighlights(pdf);
            QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 1, 10000);
            store.saveAnnotation(pdf, 0,
                {{"kind", "image"}, {"imageSource", QUrl::fromLocalFile(directory.filePath("picture.png")).toString()},
                    {"sha256", loaded.last()[4]},
                    {"rectangles", QVariantList{QVariantMap{{"x", .1}, {"y", .1}, {"width", .3}, {"height", .2}}}}});
            QTRY_COMPARE_WITH_TIMEOUT(saved.size(), 1, 10000);
            QVERIFY(saved.last()[0].toBool());
            QSignalSpy done(&store, &ResearchStore::backupFinished);
            store.backUp(directory.filePath("backups"));
            QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 10000);
            QVERIFY2(done[0][0].toBool(), qPrintable(done[0][2].toString()));
            backupPath = done[0][1].toString();
            QVERIFY(QFileInfo::exists(backupPath + "/owelk.sqlite3"));
            QVERIFY(QFileInfo::exists(backupPath + "/owelk-backup.json"));
            QCOMPARE(QDir(backupPath + "/annotations").entryList({"*.png"}).size(), 1);
            QCOMPARE(store.checkBackup(backupPath), QString());
            QVERIFY(!store.checkBackup(directory.path()).isEmpty());
            // Changes after the backup are undone by restoring it (on the next start).
            later = store.createNote("Later", "Written after the backup.");
            QVERIFY(store.scheduleRestore(backupPath));
            // Drafts: kept until saved or discarded.
            QVERIFY(store.saveDraft("note:x", "half a thought"));
            QCOMPARE(store.draft("note:x"), QString("half a thought"));
            store.clearDraft("note:x");
            QCOMPARE(store.draft("note:x"), QString());
        }
        QVERIFY(!QFileInfo::exists(data + "/.running")); // A clean exit removes the marker.
        {
            ResearchStore store(data);
            QString error;
            QVERIFY(store.initialize(&error));
            QVERIFY(store.startupMessage().startsWith("Restored the backup"));
            QVERIFY(!store.note(kept).isEmpty());
            QVERIFY(store.note(later).isEmpty());
            QCOMPARE(QDir(data + "/annotations").entryList({"*.png"}).size(), 1);
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
        // Reading notes for paper A: a text box, a marked region with a comment, and a linked note.
        QSignalSpy loaded(&store, &ResearchStore::highlightsLoaded), done(&store, &ResearchStore::annotationFinished);
        store.loadHighlights(a);
        QTRY_COMPARE_WITH_TIMEOUT(loaded.size(), 1, 10000);
        store.saveAnnotation(a, 1,
            {{"kind", "text"}, {"body", "Check the drift term"}, {"color", "#d87797"}, {"sha256", loaded.last()[4]},
                {"rectangles", QVariantList{QVariantMap{{"x", .1}, {"y", .2}, {"width", .3}, {"height", .1}}}}});
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 10000);
        const auto region = markRegion(store, a);
        QVERIFY(store.updateHighlight(region, ResearchStore::defaultAnnotationColor(), "Figure shows drift"));
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
        QVERIFY(markdown.contains("- p. 1 · region"));
        QVERIFY(markdown.contains("> Figure shows drift"));
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
    void annotationsHaveOneAnchor()
    {
        QTemporaryDir directory;
        const auto source = QUrl::fromLocalFile(directory.filePath("paper.pdf"));
        writeFixture(source.toLocalFile());
        ResearchStore store(directory.filePath("data"));
        QString error;
        QVERIFY(store.initialize(&error));
        const auto id = markRegion(store, source, 2, QRectF(.1, .2, .3, .1));
        QVERIFY(!id.isEmpty());
        const auto anchor = store.anchor(id);
        QCOMPARE(anchor["documentId"].toString(), store.documentLinkId(source));
        QCOMPARE(anchor["page"].toInt(), 2);
        QCOMPARE(anchor["source"].toUrl(), source);
        QVERIFY(qAbs(anchor["bounds"].toMap()["y"].toDouble() - .2) < 1e-6);
        QVERIFY(!anchor["sha256"].toString().isEmpty());
        QVERIFY(store.anchor("missing").isEmpty());
        // Opening verifies the file, then reveals the place.
        QSignalSpy ready(&store, &ResearchStore::sourceReady);
        store.openHighlight(id);
        QTRY_COMPARE_WITH_TIMEOUT(ready.size(), 1, 10000);
        QCOMPARE(ready[0][0].toUrl(), source);
        QCOMPARE(ready[0][1].toInt(), 2);
        QCOMPARE(ready[0][2].toRectF(), QRectF(.1, .2, .3, .1));
        // A changed file is not revealed; the annotation is kept.
        writeFixture(source.toLocalFile(), "Changed", 4);
        QSignalSpy messages(&store, &ResearchStore::message);
        store.openHighlight(id);
        QTRY_VERIFY_WITH_TIMEOUT(!messages.isEmpty(), 10000);
        QVERIFY(messages.last()[0].toString().contains("changed"));
        QCOMPARE(ready.size(), 1);
        QVERIFY(!store.anchor(id).isEmpty());
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
    void textBlocksSpanningTwoLinesDoNotDoubleTheHighlight()
    {
        // Some PDFs (GaRLIO, p.2) report page text in blocks spanning two lines; a selected line must keep
        // its own height instead of borrowing the block's.
        SelectionGeometry geometry;
        const QVariantList pageLines{
            QRectF(54, 483, 245, 27), QRectF(54, 483.5, 245, 13.5), QRectF(54, 497.5, 245, 22)};
        const auto selected
            = geometry.stableRectangles({QPolygonF(QRectF(54, 486, 245, 9)), QPolygonF(QRectF(54, 498, 245, 9)),
                                            QPolygonF(QRectF(54, 510, 245, 9))},
                pageLines);
        QCOMPARE(selected.size(), 3);
        for (qsizetype i = 0; i < selected.size(); ++i) {
            const auto rect = selected[i].toRectF();
            QVERIFY2(rect.height() < 14.5, qPrintable(QString::number(rect.height())));
            if (i) QVERIFY(rect.top() >= selected[i - 1].toRectF().bottom() - 1);
        }
    }
    void linesTallerThanTheirSpacingDoNotOverlap()
    {
        // Many PDFs give each line its font's full height, more than the distance to the next line (here 14 pt
        // boxes every 11 pt). Selected bands meet halfway instead of covering each other, and keep their glyphs.
        SelectionGeometry geometry;
        QList<QPolygonF> page, selected;
        for (int row = 0; row < 6; ++row) {
            const QRectF line(54, 100 + row * 11, 240, 14);
            page.append(QPolygonF(line));
            if (row >= 1 && row <= 3) selected.append(QPolygonF(QRectF(54, line.top() + 3, row == 2 ? 30 : 240, 8)));
        }
        const auto lines = geometry.lineRectangles(page);
        for (qsizetype i = 1; i < lines.size(); ++i)
            QVERIFY(lines[i].toRectF().top() >= lines[i - 1].toRectF().bottom() - .01);
        const auto bands = geometry.stableRectangles(selected, lines);
        QCOMPARE(bands.size(), 3);
        for (qsizetype i = 0; i < bands.size(); ++i) {
            const auto band = bands[i].toRectF();
            const auto glyphs = selected[i].boundingRect();
            QVERIFY(band.top() <= glyphs.top() && band.bottom() >= glyphs.bottom());
            if (i) QVERIFY(band.top() >= bands[i - 1].toRectF().bottom() - .01);
        }
        // A part of a line (row 2, 30 pt) is as tall as the whole lines around it.
        QCOMPARE(bands[1].toRectF().height(), bands[0].toRectF().height());
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
