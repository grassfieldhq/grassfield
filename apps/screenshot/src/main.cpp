#include <QCommandLineParser>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImageReader>
#include <QLibraryInfo>
#include <QQmlApplicationEngine>
#include <QTextStream>
#include <QUrl>

#include "translationloader.h"
#include "globalmenu.h"
#include "keywindow.h"
#include "windowchrome.h"
#include "screenshotapp.h"
#include "screenshotlogic.h"
#include "textrender.h"

#ifndef GRASSFIELD_SCREENSHOT_QML_DIR
#define GRASSFIELD_SCREENSHOT_QML_DIR "/usr/share/grassfield/screenshot/qml"
#endif
#ifndef GRASSFIELD_VERSION
#define GRASSFIELD_VERSION "unknown" // the real one comes from VERSION (cmake/GrassfieldVersion.cmake, build-direct.sh)
#endif

// Exit codes: 0 the window closed, 1 the window could not be built, 2 the arguments were refused (nothing opened).
int main(int argc, char *argv[])
{
    // The controls follow the Grassfield style when it is installed (ui/Grassfield), the Basic style otherwise; chosen here for
    // this app only, never for the session (GF-085); an explicit environment value wins.
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE")) {
        QStringList roots = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
        roots += qEnvironmentVariable("QML2_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
        roots << QLibraryInfo::path(QLibraryInfo::QmlImportsPath);
        bool installed = false;
        for (const QString &root : std::as_const(roots))
            installed = installed || QFileInfo::exists(root + QStringLiteral("/Grassfield/qmldir"));
        qputenv("QT_QUICK_CONTROLS_STYLE", installed ? "Grassfield" : "Basic");
        if (installed && qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_FALLBACK_STYLE"))
            qputenv("QT_QUICK_CONTROLS_FALLBACK_STYLE", "Basic");
    }
    // Untrusted pictures: bound every decoder (also QML Image) to this much memory.
    QImageReader::setAllocationLimit(screenshot::kAllocationLimitMb);

    QGuiApplication app(argc, argv);
    // The app's static text is rasterised natively (ADR-0039 Q5, step 19); see textrender.h.
    grassfield::apps::applyTextRenderType();
    // Before any QML: no global menu item may hold Qt's first shortcut id (globalmenu.h).
    grassfield::apps::reserveFirstShortcutId(app);
    // ADR-0015: windows that draw their own chrome (QML property gfChromeRole) are tagged for the compositor plugin.
    new grassfield::apps::ChromeTagger(&app);
    grassfield::i18n::installForApplication(); // English source; fr via grassfield_fr.qm
    app.setApplicationName(QStringLiteral("grassfield-screenshot"));
    app.setApplicationVersion(QStringLiteral(GRASSFIELD_VERSION));
    app.setOrganizationName(QStringLiteral("Grassfield"));
    // Wayland app_id: matches org.grassfield.Screenshot.desktop (the pin mode has its own, slice B11).
    app.setDesktopFileName(QStringLiteral("org.grassfield.Screenshot"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QObject::tr("Edit and annotate a screenshot"));
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addPositionalArgument(QStringLiteral("file"), QObject::tr("A local PNG file or a file: URL."), QStringLiteral("<file>"));
    QTextStream err(stderr);
    if (!parser.parse(app.arguments())) {
        err << "grassfield-screenshot: " << parser.errorText() << Qt::endl;
        return 2;
    }
    if (parser.isSet(QStringLiteral("help")))
        parser.showHelp(0);
    if (parser.isSet(QStringLiteral("version")))
        parser.showVersion();

    const screenshot::Arguments args = screenshot::resolveArguments(parser.positionalArguments(), QDir::currentPath());
    if (args.path.isEmpty()) {
        for (const QString &message : args.errors)
            err << "grassfield-screenshot: " << message << Qt::endl;
        return 2;
    }

    // The backend outlives the engine (declared first, destroyed last): bindings that run while the engine tears the window
    // down still see it.
    ScreenshotApp backend(args.path, args.errors);
    if (!backend.errors().isEmpty()) { // the file passed the arguments but did not open (a decode failure)
        for (const QString &message : backend.errors())
            err << "grassfield-screenshot: " << message << Qt::endl;
        return 2;
    }

    QQmlApplicationEngine engine;
    // ADR-0039 step 17: the window keeps its key look while a shell menu or the Control Center holds the keyboard (keywindow.h).
    new grassfield::apps::KeyWindow(&engine);
    // Installed Grassfield.Ui lives in the system QML directory; QML_IMPORT_PATH adds the repository in dev, searched first.
    engine.addImportPath(QStringLiteral("/usr/lib/qt6/qml"));
    const QStringList devPaths = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
    for (auto it = devPaths.crbegin(); it != devPaths.crend(); ++it)
        engine.addImportPath(*it);
    engine.addImageProvider(QStringLiteral("screenshot"), new ScreenshotImageProvider(&backend));

    QString qmlDir = qEnvironmentVariable("GRASSFIELD_SCREENSHOT_QML");
    if (qmlDir.isEmpty())
        qmlDir = QStringLiteral(GRASSFIELD_SCREENSHOT_QML_DIR);

    // Global menu (T1): the editor exports its menus only while the registrar is there (globalmenu.h).
    engine.setInitialProperties({{QStringLiteral("backend"), QVariant::fromValue(&backend)},
                                 {QStringLiteral("globalMenu"), grassfield::apps::globalMenuAvailable()}});
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(QStringLiteral("Editor.qml"))));
    if (engine.rootObjects().isEmpty())
        return 1;
    // The registrar may appear later or restart: the editor's menus follow it.
    grassfield::apps::followGlobalMenu(engine.rootObjects().constFirst(), "globalMenu");
    return app.exec();
}
