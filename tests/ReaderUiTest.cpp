#include "ResearchStore.h"
#include "AnnotationImageProvider.h"
#include "MathImageProvider.h"
#include "SelectionGeometry.h"
#include "Theme.h"
#include "AppInstance.h"
#include <QFileOpenEvent>
#include "PdfFixture.h"
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QtQml/QQmlExtensionPlugin>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QMouseEvent>
#include <QClipboard>
#include <QGuiApplication>
#include <QPointingDevice>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QDir>
#include <QFile>
#include <QUuid>
#include <QRegularExpression>
#include <QJsonObject>
#include <QJsonDocument>
#include <QJsonArray>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <memory>
#include <QtQuickTest/quicktest.h>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <memory>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>
#include <QtTest/QTest>

Q_IMPORT_QML_PLUGIN(OwelkStylePlugin)

class ReaderSetup : public QObject {
    Q_OBJECT
public:
    // A byte-identical copy of fixture.pdf under a new name, for duplicate detection.
    Q_INVOKABLE bool fileExists(const QUrl &url) const { return QFile::exists(url.toLocalFile()); }
    // What Finder sends when a PDF is opened with Owelk.
    Q_INVOKABLE void finderOpen(const QUrl &url)
    {
        QFileOpenEvent event(url);
        QCoreApplication::sendEvent(QGuiApplication::instance(), &event);
    }
    // A heavier real PDF for measurements, if OWELK_PERF_PDF names one (copied, never opened in place).
    Q_INVOKABLE QUrl perfFixture(const QString &name)
    {
        const auto from = qEnvironmentVariable("OWELK_PERF_PDF");
        if (from.isEmpty() || !QFile::exists(from)) return QUrl::fromLocalFile(m_directory.filePath("long.pdf"));
        const auto path = m_directory.filePath(name);
        QFile::remove(path);
        QFile::copy(from, path);
        return QUrl::fromLocalFile(path);
    }
    // A copy with bytes of its own (a comment after the end), so the Library takes it as another paper.
    Q_INVOKABLE QUrl uniqueFixture(const QString &name)
    {
        const auto url = copyFixture(name);
        QFile file(url.toLocalFile());
        if (file.open(QIODevice::Append)) file.write("\n% " + QUuid::createUuid().toByteArray() + "\n");
        return url;
    }
    Q_INVOKABLE bool removeFile(const QUrl &url) const { return QFile::remove(url.toLocalFile()); }
    Q_INVOKABLE QUrl copyFixture(const QString &name)
    {
        const auto path = m_directory.filePath(name);
        QFile::remove(path);
        QFile::copy(m_directory.filePath("fixture.pdf"), path);
        return QUrl::fromLocalFile(path);
    }
    Q_INVOKABLE QVariantMap relinkFixture(bool specialPath = false)
    {
        const auto prefix = m_directory.filePath(
            (specialPath ? "relink paper 한글-" : "relink-") + QUuid::createUuid().toString(QUuid::WithoutBraces));
        const auto old = prefix + "-old.pdf", next = prefix + "-new.pdf", wrong = prefix + "-wrong.pdf";
        QFile::copy(m_directory.filePath("fixture.pdf"), old);
        QFile::copy(old, next);
        QFile::copy(m_directory.filePath("outline.pdf"), wrong);
        return {{"source", QUrl::fromLocalFile(old)}, {"candidate", QUrl::fromLocalFile(next)},
            {"wrong", QUrl::fromLocalFile(wrong)}};
    }
    Q_INVOKABLE void nativePinch(QQuickItem *item, int phase, qreal value, QPointF point)
    {
        if (!item || !item->window()) return;
        auto *window = item->window();
        const auto scene = item->mapToScene(point);
        const auto type = phase == 0 ? Qt::BeginNativeGesture
            : phase == 2             ? Qt::EndNativeGesture
                                     : Qt::ZoomNativeGesture;
        QNativeGestureEvent event(type, &m_trackpad, 2, scene, scene, window->mapToGlobal(scene), value, {}, 1);
        event.setTimestamp(++m_timestamp);
        QCoreApplication::sendEvent(window, &event);
        QCoreApplication::processEvents();
    }
    Q_INVOKABLE QString clipboardText() const { return QGuiApplication::clipboard()->text(); }
    Q_INVOKABLE int cursorShape(QQuickItem *item) const
    {
        return item && item->window() ? item->window()->cursor().shape() : -1;
    }
    Q_INVOKABLE void keyClick(QQuickItem *item, int key, int modifiers = 0)
    {
        if (!item || !item->window()) return;
        item->window()->requestActivate();
        QCoreApplication::processEvents();
        item->forceActiveFocus();
        QTest::keyClick(item->window(), Qt::Key(key), Qt::KeyboardModifiers(modifiers));
    }
    // Clicks in quick succession at one point (two: a double click, three: a triple click), as a mouse sends them.
    Q_INVOKABLE void clicks(QQuickItem *item, QPointF point, int count)
    {
        if (!item || !item->window()) return;
        auto *window = item->window();
        const QPointF local = item->mapToScene(point);
        for (int n = 0; n < count; ++n)
            for (const auto type : {QEvent::MouseButtonPress, QEvent::MouseButtonRelease}) {
                const bool press = type == QEvent::MouseButtonPress;
                QMouseEvent event(type, local, window->mapToGlobal(local), Qt::LeftButton,
                    press ? Qt::MouseButtons(Qt::LeftButton) : Qt::NoButton, Qt::NoModifier);
                m_timestamp += 40;
                event.setTimestamp(m_timestamp);
                QCoreApplication::sendEvent(window, &event);
                QCoreApplication::processEvents();
            }
        m_timestamp += 2000; // The next click starts afresh.
    }
    // Exercise input-device filtering inside the offscreen test window only.
    Q_INVOKABLE void pointerDrag(QQuickItem *item, QPointF start, QPointF end, bool trackpad)
    {
        if (!item || !item->window()) return;
        auto *window = item->window();
        const auto *device = trackpad ? &m_trackpad : QPointingDevice::primaryPointingDevice();
        auto send = [&](QEvent::Type type, QPointF point, Qt::MouseButton button, Qt::MouseButtons buttons) {
            const QPointF local = item->mapToScene(point);
            QMouseEvent event(type, local, window->mapToGlobal(local), button, buttons, Qt::NoModifier, device);
            event.setTimestamp(++m_timestamp);
            QCoreApplication::sendEvent(window, &event);
            QCoreApplication::processEvents();
        };
        send(QEvent::MouseButtonPress, start, Qt::LeftButton, Qt::LeftButton);
        for (int step = 1; step <= 20; ++step)
            send(QEvent::MouseMove, start + (end - start) * (step / 20.0), Qt::NoButton, Qt::LeftButton);
        send(QEvent::MouseButtonRelease, end, Qt::LeftButton, Qt::NoButton);
    }
public slots:
    void applicationAvailable()
    {
        // API keys the tests write, and the ChatGPT account they read, are never the real ones.
        qputenv("OWELK_KEYCHAIN_SERVICE",
            ("org.owelk.tests." + QUuid::createUuid().toString(QUuid::WithoutBraces)).toUtf8());
        qputenv("OWELK_CODEX", QByteArray(QUICK_TEST_SOURCE_DIR) + "/fake_codex.py");
        QQuickStyle::setStyle("OwelkStyle");
        writeFixture(m_directory.filePath("fixture.pdf"));
        QImage preview(80, 60, QImage::Format_RGB32);
        preview.fill(Qt::blue);
        if (!preview.save(m_directory.filePath("preview 한글 %.png"))) qFatal("Cannot create image fixture");
        writeFixture(m_directory.filePath("long.pdf"), "Long PDF benchmark", 120);
        if (!writeOutlineFixture(m_directory.filePath("outline.pdf"))) qFatal("Cannot create outline fixture");
        if (!writeLinkFixture(m_directory.filePath("links.pdf"))) qFatal("Cannot create link fixture");
        writeReferenceFixture(m_directory.filePath("references.pdf"));
        if (!writeLinkFixture(m_directory.filePath("lost-links.pdf"), true)) qFatal("Cannot create link fixture");
        if (!writeLinkFixture(m_directory.filePath("reference-links.pdf"), false, true))
            qFatal("Cannot create link fixture");
        QDir().mkpath(m_directory.filePath("library/Group"));
        QFile::copy(m_directory.filePath("fixture.pdf"), m_directory.filePath("library/root.pdf"));
        QFile::copy(m_directory.filePath("fixture.pdf"), m_directory.filePath("library/Group/inside.pdf"));
        m_store = new ResearchStore(m_directory.filePath("data"), this);
        QString error;
        if (!m_store->initialize(&error)) qFatal("%s", qPrintable(error));
        // Fixtures open from where they are (keeping copies is covered by the store tests).
        m_store->setSetting("library.keepPdfs", "0");
        // Downloads (web tabs, For You's Add) land in the test folder, never in the real Downloads.
        QDir().mkpath(m_directory.filePath("downloads"));
        m_store->setSetting("downloadFolder", m_directory.filePath("downloads"));
        m_theme = new Theme(m_store, this);
        qmlRegisterSingletonInstance("Owelk.Ui", 1, 0, "Theme", m_theme);
    }
    void qmlEngineAvailable(QQmlEngine *engine)
    {
        engine->addImageProvider("annotation", new AnnotationImageProvider);
        engine->addImageProvider("math", new MathImageProvider);
        engine->rootContext()->setContextProperty("initialFiles", QVariantList{});
        engine->rootContext()->setContextProperty(
            "fixtureFolder", QUrl::fromLocalFile(m_directory.filePath("library")));
        engine->rootContext()->setContextProperty("selectionGeometry", &m_geometry);
        engine->rootContext()->setContextProperty("testInput", this);
        engine->rootContext()->setContextProperty("researchStore", m_store);
        if (!m_instance) {
            // Finder's file-open events, as the app receives them (no local server needed here).
            m_instance = new AppInstance(m_directory.filePath("data"), this);
            QGuiApplication::instance()->installEventFilter(m_instance);
        }
        engine->rootContext()->setContextProperty("appInstance", m_instance);
        engine->rootContext()->setContextProperty(
            "fixtureSource", QUrl::fromLocalFile(m_directory.filePath("fixture.pdf")));
        engine->rootContext()->setContextProperty(
            "fixtureImage", QUrl::fromLocalFile(m_directory.filePath("preview 한글 %.png")));
        engine->rootContext()->setContextProperty(
            "outlineSource", QUrl::fromLocalFile(m_directory.filePath("outline.pdf")));
        engine->rootContext()->setContextProperty("linkSource", QUrl::fromLocalFile(m_directory.filePath("links.pdf")));
        engine->rootContext()->setContextProperty("longSource", QUrl::fromLocalFile(m_directory.filePath("long.pdf")));
        engine->rootContext()->setContextProperty(
            "referenceLinkSource", QUrl::fromLocalFile(m_directory.filePath("reference-links.pdf")));
        engine->rootContext()->setContextProperty(
            "lostLinkSource", QUrl::fromLocalFile(m_directory.filePath("lost-links.pdf")));
        engine->rootContext()->setContextProperty(
            "referenceSource", QUrl::fromLocalFile(m_directory.filePath("references.pdf")));
        {
            // Where "[2]" sits on the first page of the reference fixture, in PDF points.
            QPdfDocument references;
            references.load(m_directory.filePath("references.pdf"));
            const auto text = references.getAllText(0).text();
            engine->rootContext()->setContextProperty(
                "referenceCitation", references.getSelectionAtIndex(0, text.indexOf("[2]"), 3).boundingRectangle());
            engine->rootContext()->setContextProperty("referenceRange",
                references.getSelectionAtIndex(0, text.indexOf(QString::fromUtf8("[1\u20133]")), 5)
                    .boundingRectangle());
            engine->rootContext()->setContextProperty(
                "referenceFigure", references.getSelectionAtIndex(0, text.indexOf("Fig. 2"), 6).boundingRectangle());
            engine->rootContext()->setContextProperty(
                "referenceTable", references.getSelectionAtIndex(0, text.indexOf("Table 1"), 7).boundingRectangle());
        }
        QPdfDocument pdf;
        pdf.load(m_directory.filePath("fixture.pdf"));
        const auto text = pdf.getAllText(0).text();
        const auto line = pdf.getSelectionAtIndex(0, text.indexOf("Research finding"), 45);
        engine->rootContext()->setContextProperty("fixtureTextBounds", line.boundingRectangle());
        const int start = text.indexOf("Research finding") + 1;
        engine->rootContext()->setContextProperty(
            "fixtureLowerBounds", pdf.getSelectionAtIndex(0, start, 6).boundingRectangle());
        engine->rootContext()->setContextProperty(
            "fixtureMixedBounds", pdf.getSelectionAtIndex(0, start, 15).boundingRectangle());
    }
    void cleanupTestCase()
    {
        delete m_store;
        m_store = nullptr;
    }

    // A local web server for web-tab tests: /page.html links to /paper.pdf (the fixture PDF).
    Q_INVOKABLE QUrl webFixture(const QString &path)
    {
        if (!m_web.isListening()) {
            m_web.listen(QHostAddress::LocalHost);
            connect(&m_web, &QTcpServer::newConnection, this, [this] {
                auto *socket = m_web.nextPendingConnection();
                connect(socket, &QTcpSocket::readyRead, socket, [this, socket] {
                    auto request = socket->property("requestBuffer").toByteArray();
                    request += socket->readAll();
                    socket->setProperty("requestBuffer", request);
                    const auto headerEnd = request.indexOf("\r\n\r\n");
                    if (headerEnd < 0) return;
                    int contentLength = 0;
                    const auto headers = QString::fromUtf8(request.left(headerEnd)).split("\r\n");
                    for (const auto &line : headers)
                        if (line.startsWith("Content-Length:", Qt::CaseInsensitive)) {
                            contentLength = line.section(':', 1).trimmed().toInt();
                            break;
                        }
                    if (request.size() < headerEnd + 4 + contentLength) return;
                    const auto head = QString::fromUtf8(request).section("\r\n", 0, 0);
                    QByteArray body, type = "text/html";
                    if (head.contains("POST /api/embed")) {
                        // Ollama-style embeddings where related words share a dimension (meaning search).
                        type = "application/json";
                        const auto input = QJsonDocument::fromJson(request.mid(request.indexOf("\r\n\r\n") + 4))
                                               .object()
                                               .value("input")
                                               .toArray();
                        static const QList<QStringList> concepts{{"occlusion", "hidden", "occluded", "covered"},
                            {"observation", "view", "seen"}, {"context", "surroundings", "scene"}};
                        QJsonArray embeddings;
                        for (const auto &text : input) {
                            QJsonArray vector;
                            const auto words = text.toString().toLower().split(QRegularExpression("\\W+"));
                            for (const auto &related : concepts) {
                                double value = .01;
                                for (const auto &word : words) value += related.contains(word) ? 1 : 0;
                                vector.append(value);
                            }
                            vector.append(.05);
                            embeddings.append(vector);
                        }
                        body = QJsonDocument(QJsonObject{{"embeddings", embeddings}}).toJson(QJsonDocument::Compact);
                    } else if (head.contains("POST /v1/messages")) {
                        // A Claude-style stream for AI panel tests.
                        type = "text/event-stream";
                        // Tab organization prompts get groups back; everything else a fixed answer.
                        const bool grouping = request.contains("Group these tabs");
                        const bool sorting = request.contains("Group these papers");
                        const bool comparing = request.contains("Aspects: ");
                        const bool ranking = request.contains("decide which new papers to read");
                        QList<QByteArray> pieces = grouping
                            ? QList<QByteArray>{"{\\\"groups\\\": [{\\\"name\\\": \\\"Fixture papers\\\", ",
                                  "\\\"tabs\\\": [\\\"t1\\\", \\\"t2\\\"]}]}"}
                            : sorting
                            ? QList<QByteArray>{"{\\\"groups\\\": [{\\\"name\\\": \\\"Occlusion studies\\\", ",
                                  "\\\"papers\\\": [\\\"p1\\\", \\\"p2\\\"]}]}"}
                            : comparing
                            ? QList<QByteArray>{"| Paper | Method |\\n|---|---|\\n", "| One 2020 | occlusion |"}
                            : QList<QByteArray>{"Mock ", "answer about **occlusion**."};
                        // For You: each new paper scored, with a reason.
                        if (ranking)
                            pieces = {"{\\\"papers\\\": [{\\\"id\\\": \\\"p1\\\", \\\"score\\\": 92, ",
                                "\\\"why\\\": \\\"Directly on the odometry you follow.\\\"}]}"};
                        // Asked to rewrite an attached note (or write one): the whole note in Owelk's block.
                        // The latest request comes last in the conversation; earlier ones stay in it.
                        if (request.contains("Write a new note")) {
                            pieces = {"Done.\\n<note_new title=\\\"Fresh note\\\">\\nA fresh ", "note.\\n</note_new>"};
                        } else if (request.contains("Rewrite my note")) {
                            const auto id = QRegularExpression("note id=\\\\\"([^\\\\\"]+)\\\\\"")
                                                .match(QString::fromUtf8(request))
                                                .captured(1);
                            pieces = {
                                "Here it is.\\n<note_update id=\\\"" + id.toUtf8() + "\\\" title=\\\"Rewritten\\\">\\n",
                                "# Rewritten\\n\\nNew body.\\n</note_update>"};
                        }
                        // Answers to questions come with a reasoning summary, as Claude's summarized thinking.
                        if (!grouping && !sorting && !comparing && !ranking)
                            body += "event: content_block_start\ndata: {\"type\":\"content_block_start\","
                                    "\"content_block\":{\"type\":\"thinking\"}}\n\n"
                                    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":"
                                    "{\"type\":\"thinking_delta\",\"thinking\":\"**Reading the selection**\"}}\n\n";
                        for (const auto &piece : pieces)
                            body += QByteArray(
                                        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":"
                                        "{\"type\":\"text_delta\",\"text\":\"")
                                + piece + "\"}}\n\n";
                        body += "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";
                    } else if (head.contains("/graph/v1/paper/")) {
                        // Semantic Scholar: one reference and two citing papers.
                        type = "application/json";
                        body = head.contains("/references")
                            ? R"({"data":[{"citedPaper":{"paperId":"r1","title":"Cited Work","year":2018,"externalIds":{"ArXiv":"1801.00001"},"citationCount":3}}]})"
                            : R"({"data":[{"citingPaper":{"paperId":"c1","title":"Later Work","year":2024,"citationCount":9}},{"citingPaper":{"paperId":"c2","title":"Another Work","year":2025}}]})";
                    } else if (head.contains("/api/query")) {
                        // arXiv for For You: one new paper today, its PDF the fixture.
                        type = "application/atom+xml";
                        const auto today = QDate::currentDate().toString(Qt::ISODate);
                        body = ("<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><entry>"
                                "<id>http://arxiv.org/abs/2609.01234v1</id><published>"
                            + today
                            + "T08:00:00Z</published><title>Fresh Odometry From arXiv</title><summary>A new "
                              "odometry method.</summary><author><name>Ada Lovelace</name></author><link title=\"pdf\" "
                              "href=\"http://127.0.0.1:"
                            + QString::number(m_web.serverPort()) + "/paper.pdf\"/></entry></feed>")
                                   .toUtf8();
                    } else if (head.contains("/recommendations/v1/papers/")) {
                        // Semantic Scholar for For You: one paper like a followed collection's.
                        type = "application/json";
                        body = QStringLiteral("{\"recommendedPapers\":[{\"paperId\":\"r9\",\"title\":\"Like Your "
                                              "Collection\",\"authors\":[{\"name\":\"Grace Hopper\"}],"
                                              "\"publicationDate\":\"%1\",\"externalIds\":{\"DOI\":\"10.7/like\"}}]}")
                                   .arg(QDate::currentDate().toString(Qt::ISODate))
                                   .toUtf8();
                    } else if (head.contains("/slow.pdf")) {
                        // A large PDF sent in pieces with its size up front, for download progress.
                        QFile pdf(m_directory.filePath("fixture.pdf"));
                        pdf.open(QIODevice::ReadOnly);
                        const auto data = pdf.readAll() + QByteArray(900 * 1024, ' ');
                        socket->write("HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nConnection: close\r\n"
                                      "Content-Length: "
                            + QByteArray::number(data.size()) + "\r\n\r\n");
                        auto *timer = new QTimer(socket);
                        auto sent = std::make_shared<qsizetype>(0);
                        connect(timer, &QTimer::timeout, socket, [socket, timer, data, sent] {
                            const auto piece = data.mid(*sent, data.size() / 12 + 1);
                            socket->write(piece);
                            *sent += piece.size();
                            if (*sent >= data.size()) {
                                timer->stop();
                                socket->disconnectFromHost();
                            }
                        });
                        timer->start(120);
                        return;
                    } else if (head.contains("GET /authors?")) {
                        // OpenAlex for For You: one researcher by that name, no institution, and her new preprint.
                        type = "application/json";
                        body = "{\"results\":[{\"id\":\"https://openalex.org/A777\",\"display_name\":\"Grace "
                               "Hopper\",\"last_known_institutions\":[{\"display_name\":\"Harvard\"}],"
                               "\"works_count\":40}]}";
                    } else if (head.contains("GET /institutions?")) {
                        type = "application/json";
                        body = "{\"results\":[]}";
                    } else if (head.contains("GET /works?")) {
                        type = "application/json";
                        body = QStringLiteral("{\"results\":[{\"id\":\"https://openalex.org/W777\",\"doi\":"
                                              "\"https://doi.org/10.48550/arXiv.2610.05555\",\"title\":\"Compilers "
                                              "For Everyone\",\"publication_date\":\"%1\",\"authorships\":[{"
                                              "\"author\":{\"display_name\":\"Grace Hopper\"}}]}]}")
                                   .arg(QDate::currentDate().toString(Qt::ISODate))
                                   .toUtf8();
                    } else if (head.contains("/data.zip")) {
                        // Not a PDF: saved only when the reader agrees.
                        body = "PK fixture";
                        type = "application/zip\r\nContent-Disposition: attachment; filename=\"data.zip\"";
                    } else if (head.contains("/popup.html")) {
                        // Opens a window by itself, without a click.
                        body = "<html><head><title>Popup Page</title></head><body>"
                               "<script>setTimeout(function(){window.open('/page.html')},200)</script></body></html>";
                    } else if (head.contains("/embed.html")) {
                        // Like IEEE's getPDF.jsp: an HTML page showing the PDF in a frame.
                        body = "<html><head><title>getPDF</title></head><body>"
                               "<iframe id='frame' src='/paper.pdf' width='600' height='400'></iframe></body></html>";
                    } else if (head.contains("/paper.pdf")) {
                        QFile pdf(m_directory.filePath("fixture.pdf"));
                        pdf.open(QIODevice::ReadOnly);
                        body = pdf.readAll();
                        type = "application/pdf";
                    } else
                        body = "<html><head><title>Owelk Test Page</title></head><body><h1>Paper page</h1>"
                               "<a id='pdf' href='/paper.pdf'>PDF</a></body></html>";
                    socket->write("HTTP/1.1 200 OK\r\nContent-Type: " + type
                        + "\r\nConnection: close\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n\r\n"
                        + body);
                    socket->disconnectFromHost();
                });
            });
        }
        return QUrl(QStringLiteral("http://127.0.0.1:%1%2").arg(m_web.serverPort()).arg(path));
    }
    Q_INVOKABLE QSize imageSize(const QUrl &file) { return QImage(file.toLocalFile()).size(); }
    // A copy of a checked-in test file (tests/data), so tests never change the original.
    Q_INVOKABLE QUrl dataFile(const QString &name)
    {
        const auto target = m_directory.filePath("data-" + name);
        QFile::remove(target);
        QFile::copy(QStringLiteral(QUICK_TEST_SOURCE_DIR) + "/data/" + name, target);
        return QUrl::fromLocalFile(target);
    }
    Q_INVOKABLE QString temporaryFolder(const QString &name)
    {
        QDir().mkpath(m_directory.filePath(name));
        return m_directory.filePath(name);
    }

private:
    QTcpServer m_web;
    SelectionGeometry m_geometry;
    QPointingDevice m_trackpad{"Test trackpad", 42, QInputDevice::DeviceType::TouchPad,
        QPointingDevice::PointerType::Finger, QInputDevice::Capability::Position, 5, 3};
    quint64 m_timestamp = 1000;
    QTemporaryDir m_directory;
    ResearchStore *m_store = nullptr;
    AppInstance *m_instance = nullptr;
    Theme *m_theme = nullptr;
};

QUICK_TEST_MAIN_WITH_SETUP(reader_ui, ReaderSetup)
#include "ReaderUiTest.moc"

// QUICK_TEST_MAIN creates the application object; WebEngine must be initialised before that.
static void initializeWebEngine()
{
    QtWebEngineQuick::initialize();
}
Q_CONSTRUCTOR_FUNCTION(initializeWebEngine)
