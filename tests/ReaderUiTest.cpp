#include "ResearchStore.h"
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
#include <QtQuickTest/quicktest.h>
#include <QtTest/QTest>

class ReaderSetup : public QObject
{
    Q_OBJECT
public:
    Q_INVOKABLE QVariantMap relinkFixture() {
        const auto prefix = m_directory.filePath("relink-" + QUuid::createUuid().toString(QUuid::WithoutBraces));
        const auto old = prefix + "-old.pdf", next = prefix + "-new.pdf", wrong = prefix + "-wrong.pdf";
        QFile::copy(m_directory.filePath("fixture.pdf"),old);
        QFile::copy(old,next);
        QFile::copy(m_directory.filePath("outline.pdf"),wrong);
        return {{"source",QUrl::fromLocalFile(old)}, {"candidate",QUrl::fromLocalFile(next)}, {"wrong",QUrl::fromLocalFile(wrong)}};
    }
    Q_INVOKABLE void nativePinch(QQuickItem *item, int phase, qreal value, QPointF point) {
        if (!item || !item->window()) return;
        auto *window = item->window();
        const auto scene = item->mapToScene(point);
        const auto type = phase == 0 ? Qt::BeginNativeGesture : phase == 2 ? Qt::EndNativeGesture : Qt::ZoomNativeGesture;
        QNativeGestureEvent event(type, &m_trackpad, 2, scene, scene, window->mapToGlobal(scene), value, {}, 1);
        event.setTimestamp(++m_timestamp);
        QCoreApplication::sendEvent(window, &event);
        QCoreApplication::processEvents();
    }
    Q_INVOKABLE QString clipboardText() const { return QGuiApplication::clipboard()->text(); }
    Q_INVOKABLE void keyClick(QQuickItem *item, int key, int modifiers = 0) {
        if (!item || !item->window()) return;
        item->window()->requestActivate();
        QCoreApplication::processEvents();
        item->forceActiveFocus();
        QTest::keyClick(item->window(), Qt::Key(key), Qt::KeyboardModifiers(modifiers));
    }
    // Exercise input-device filtering inside the offscreen test window only.
    Q_INVOKABLE void pointerDrag(QQuickItem *item, QPointF start, QPointF end, bool trackpad) {
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
    void applicationAvailable() {
        QQuickStyle::setStyle("Basic");
        writeFixture(m_directory.filePath("fixture.pdf"));
        writeFixture(m_directory.filePath("long.pdf"), "Long PDF benchmark", 120);
        if (!writeOutlineFixture(m_directory.filePath("outline.pdf"))) qFatal("Cannot create outline fixture");
        QDir().mkpath(m_directory.filePath("library/Group"));
        QFile::copy(m_directory.filePath("fixture.pdf"), m_directory.filePath("library/root.pdf"));
        QFile::copy(m_directory.filePath("fixture.pdf"), m_directory.filePath("library/Group/inside.pdf"));
        m_store = new ResearchStore(m_directory.filePath("data"), this);
        QString error;
        if (!m_store->initialize(&error)) qFatal("%s", qPrintable(error));
    }
    void qmlEngineAvailable(QQmlEngine *engine) {
        engine->rootContext()->setContextProperty("initialFiles", QVariantList{});
        engine->rootContext()->setContextProperty("fixtureFolder", QUrl::fromLocalFile(m_directory.filePath("library")));
        engine->rootContext()->setContextProperty("selectionGeometry", &m_geometry);
        engine->rootContext()->setContextProperty("testInput", this);
        engine->rootContext()->setContextProperty("researchStore", m_store);
        engine->rootContext()->setContextProperty("fixtureSource", QUrl::fromLocalFile(m_directory.filePath("fixture.pdf")));
        engine->rootContext()->setContextProperty("outlineSource", QUrl::fromLocalFile(m_directory.filePath("outline.pdf")));
        engine->rootContext()->setContextProperty("longSource", QUrl::fromLocalFile(m_directory.filePath("long.pdf")));
        QPdfDocument pdf;
        pdf.load(m_directory.filePath("fixture.pdf"));
        const auto text = pdf.getAllText(0).text();
        const auto line = pdf.getSelectionAtIndex(0, text.indexOf("Research finding"), 45);
        engine->rootContext()->setContextProperty("fixtureTextBounds", line.boundingRectangle());
        const int start = text.indexOf("Research finding") + 1;
        engine->rootContext()->setContextProperty("fixtureLowerBounds", pdf.getSelectionAtIndex(0, start, 6).boundingRectangle());
        engine->rootContext()->setContextProperty("fixtureMixedBounds", pdf.getSelectionAtIndex(0, start, 15).boundingRectangle());
    }
    void cleanupTestCase() {
        delete m_store;
        m_store = nullptr;
    }
private:
    SelectionGeometry m_geometry;
    QPointingDevice m_trackpad{"Test trackpad", 42, QInputDevice::DeviceType::TouchPad,
        QPointingDevice::PointerType::Finger, QInputDevice::Capability::Position, 5, 3};
    quint64 m_timestamp = 1000;
    QTemporaryDir m_directory;
    ResearchStore *m_store = nullptr;
};

QUICK_TEST_MAIN_WITH_SETUP(reader_ui, ReaderSetup)
#include "ReaderUiTest.moc"
