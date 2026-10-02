#include "ResearchStore.h"
#include "AnnotationImageProvider.h"
#include "SelectionGeometry.h"
#include "PdfFixture.h"
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
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

class ReaderSetup : public QObject {
    Q_OBJECT
public:
    // A byte-identical copy of fixture.pdf under a new name, for duplicate detection.
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
        QQuickStyle::setStyle("Basic");
        writeFixture(m_directory.filePath("fixture.pdf"));
        QImage preview(80, 60, QImage::Format_RGB32);
        preview.fill(Qt::blue);
        if (!preview.save(m_directory.filePath("preview 한글 %.png"))) qFatal("Cannot create image fixture");
        writeFixture(m_directory.filePath("long.pdf"), "Long PDF benchmark", 120);
        if (!writeOutlineFixture(m_directory.filePath("outline.pdf"))) qFatal("Cannot create outline fixture");
        if (!writeLinkFixture(m_directory.filePath("links.pdf"))) qFatal("Cannot create link fixture");
        QDir().mkpath(m_directory.filePath("library/Group"));
        QFile::copy(m_directory.filePath("fixture.pdf"), m_directory.filePath("library/root.pdf"));
        QFile::copy(m_directory.filePath("fixture.pdf"), m_directory.filePath("library/Group/inside.pdf"));
        m_store = new ResearchStore(m_directory.filePath("data"), this);
        QString error;
        if (!m_store->initialize(&error)) qFatal("%s", qPrintable(error));
    }
    void qmlEngineAvailable(QQmlEngine *engine)
    {
        engine->addImageProvider("annotation", new AnnotationImageProvider);
        engine->rootContext()->setContextProperty("initialFiles", QVariantList{});
        engine->rootContext()->setContextProperty(
            "fixtureFolder", QUrl::fromLocalFile(m_directory.filePath("library")));
        engine->rootContext()->setContextProperty("selectionGeometry", &m_geometry);
        engine->rootContext()->setContextProperty("testInput", this);
        engine->rootContext()->setContextProperty("researchStore", m_store);
        engine->rootContext()->setContextProperty(
            "fixtureSource", QUrl::fromLocalFile(m_directory.filePath("fixture.pdf")));
        engine->rootContext()->setContextProperty(
            "fixtureImage", QUrl::fromLocalFile(m_directory.filePath("preview 한글 %.png")));
        engine->rootContext()->setContextProperty(
            "outlineSource", QUrl::fromLocalFile(m_directory.filePath("outline.pdf")));
        engine->rootContext()->setContextProperty("linkSource", QUrl::fromLocalFile(m_directory.filePath("links.pdf")));
        engine->rootContext()->setContextProperty("longSource", QUrl::fromLocalFile(m_directory.filePath("long.pdf")));
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
                    const auto head = QString::fromUtf8(socket->readAll()).section("\r\n", 0, 0);
                    QByteArray body, type = "text/html";
                    if (head.contains("POST /v1/messages")) {
                        // A Claude-style stream for AI panel tests.
                        type = "text/event-stream";
                        for (const auto *piece : {"Mock ", "answer about **occlusion**."})
                            body += QByteArray(
                                        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":"
                                        "{\"type\":\"text_delta\",\"text\":\"")
                                + piece + "\"}}\n\n";
                        body += "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";
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
    Q_INVOKABLE void setEnvironment(const QString &name, const QString &value)
    {
        if (value.isEmpty())
            qunsetenv(name.toUtf8());
        else
            qputenv(name.toUtf8(), value.toUtf8());
    }
    Q_INVOKABLE QString sourcePath(const QString &name) { return QStringLiteral(QUICK_TEST_SOURCE_DIR) + "/" + name; }
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
};

QUICK_TEST_MAIN_WITH_SETUP(reader_ui, ReaderSetup)
#include "ReaderUiTest.moc"

// QUICK_TEST_MAIN creates the application object; WebEngine must be initialised before that.
static void initializeWebEngine()
{
    QtWebEngineQuick::initialize();
}
Q_CONSTRUCTOR_FUNCTION(initializeWebEngine)
