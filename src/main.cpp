#include "ResearchStore.h"
#include "AppInstance.h"
#include "AnnotationImageProvider.h"
#include "MathImageProvider.h"
#include "SelectionGeometry.h"
#include "Theme.h"
#include <QCommandLineParser>
#include <QDir>
#include <QFileInfo>
#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QtQml/QQmlExtensionPlugin>
#include <QStandardPaths>
#include <QTimer>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>
#include <cstdio>

Q_IMPORT_QML_PLUGIN(OwelkStylePlugin)

int main(int argc, char *argv[])
{
    // Web tabs need WebEngine set up before the application object exists.
    QtWebEngineQuick::initialize();
    QApplication app(argc, argv);
    app.setOrganizationName("Owelk");
    app.setApplicationName("Owelk");
    app.setApplicationVersion("0.1.0");
    // The window and Dock icon follow Settings → Appearance (Theme); the macOS bundle has owelk.icns.
    app.setDesktopFileName("owelk");
    QQuickStyle::setStyle("OwelkStyle");

    QCommandLineParser parser;
    parser.setApplicationDescription("Owelk — a local research reader");
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addOption({"data-dir", "Store local data in this directory.", "directory"});
    parser.addOption({"smoke-test", "Load the UI and exit after three seconds."});
    parser.addPositionalArgument("pdf", "PDF files to open in the left and right panes.", "[pdf ...]");
    parser.process(app);
    const QString dataDir = parser.isSet("data-dir")
        ? QDir(parser.value("data-dir")).absolutePath()
        : QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
    // A second launch hands its files to the Owelk already running (Linux, Windows, command line).
    AppInstance instance(dataDir);
    if (!parser.isSet("smoke-test") && instance.forward(parser.positionalArguments())) return 0;
    instance.listen();
    // Finder: Open With and double-click arrive as file-open events.
    app.installEventFilter(&instance);
    ResearchStore store(dataDir);
    QString error;
    if (!store.initialize(&error)) {
        fprintf(stderr, "Owelk: %s\n", qPrintable(error));
        return 1;
    }
    QVariantList initialFiles;
    for (const auto &path : parser.positionalArguments())
        initialFiles.append(QUrl::fromLocalFile(QFileInfo(path).absoluteFilePath()));

    SelectionGeometry selectionGeometry;
    // Read before the window exists, so the first frame already has the chosen theme.
    Theme theme(&store);
    qmlRegisterSingletonInstance("Owelk.Ui", 1, 0, "Theme", &theme);
    QQmlApplicationEngine engine;
    engine.addImageProvider("annotation", new AnnotationImageProvider);
    engine.addImageProvider("math", new MathImageProvider);
    engine.rootContext()->setContextProperty("selectionGeometry", &selectionGeometry);
    engine.rootContext()->setContextProperty("researchStore", &store);
    engine.rootContext()->setContextProperty("initialFiles", initialFiles);
    engine.rootContext()->setContextProperty("appInstance", &instance);
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); },
        Qt::QueuedConnection);
    engine.loadFromModule("Owelk", "Main");
    if (parser.isSet("smoke-test")) QTimer::singleShot(3000, &app, &QCoreApplication::quit);
    return app.exec();
}
