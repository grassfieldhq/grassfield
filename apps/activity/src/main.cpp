#include <QCommandLineParser>
#include <QDBusConnection>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QLibraryInfo>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QUrl>

#include "graphitem.h"
#include "activityapp.h"
#include "globalmenu.h"
#include "iconprovider.h"
#include "runmode.h"
#include "shownwatch.h"
#include "translationloader.h"
#include "keywindow.h"
#include "windowchrome.h"
#include "textrender.h"

#ifndef GRASSFIELD_ACTIVITY_QML_DIR
#define GRASSFIELD_ACTIVITY_QML_DIR "/usr/share/grassfield/activity/qml"
#endif
#ifndef GRASSFIELD_VERSION
#define GRASSFIELD_VERSION "unknown" // the real one comes from VERSION (cmake/GrassfieldVersion.cmake, build-direct.sh)
#endif

int main(int argc, char *argv[])
{
    // The Grassfield controls style when it is installed, the Basic style otherwise (as the Store and Preview, GF-085).
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

    QGuiApplication app(argc, argv);
    // The app's static text is rasterised natively (ADR-0039 Q5, step 19): distance-field glyphs carry 8 to 20 % less ink than
    // macOS's, so text read greyer and softer; no app text is scaled or animated (an item that is sets its own renderType).
    grassfield::apps::applyTextRenderType(); // native unless GRASSFIELD_TEXT_RENDER says otherwise (textrender.h)
    // Before any QML: no global menu item may hold Qt's first shortcut id (globalmenu.h).
    grassfield::apps::reserveFirstShortcutId(app);
    // ADR-0015: the window draws its own chrome (QML property gfChromeRole), tagged for the compositor plugin.
    new grassfield::apps::ChromeTagger(&app);
    grassfield::i18n::installForApplication(); // English source; fr via grassfield_fr.qm
    app.setApplicationName(QStringLiteral("grassfield-activity"));
    app.setApplicationVersion(QStringLiteral(GRASSFIELD_VERSION));
    app.setOrganizationName(QStringLiteral("Grassfield"));
    app.setDesktopFileName(QStringLiteral("org.grassfield.Activity")); // Wayland app_id: org.grassfield.Activity.desktop

    QCommandLineParser parser;
    parser.setApplicationDescription(QObject::tr("See the processes and the resources they use."));
    parser.addHelpOption();
    parser.addVersionOption();
    parser.process(app);

    // AM1: one instance. A second launch brings the running app's window forward with its activation token, and leaves.
    activity::ActivityService service;
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (bus.isConnected()
        && activity::claimOrHandOver(bus, &service, qEnvironmentVariable("XDG_ACTIVATION_TOKEN")) == activity::Launch::Leave)
        return 0;

    // The sampler's options: this machine's; in a dev session GRASSFIELD_PROC_ROOT and GRASSFIELD_SYS_ROOT point it at a
    // fixture tree (AM79, runmode.h devValue); they are ignored outside one.
    activity::raiseFileLimit();
    activity::Options options = activity::defaultOptions();
    if (const QString proc = grassfield::apps::runmode::devValue("PROC_ROOT"); !proc.isEmpty())
        options.procRoot = proc.toStdString();
    if (const QString sys = grassfield::apps::runmode::devValue("SYS_ROOT"); !sys.isEmpty())
        options.sysRoot = sys.toStdString();

    // The backend outlives the engine (declared first, destroyed last).
    activity::ActivityApp backend(options, grassfield::apps::runmode::stateDir() + QStringLiteral("/activity.json"));

    // Graph.qml's drawing (graphitem.h): Grassfield.Activity/GraphItem.
    activity::registerGraphItem();
    QQmlApplicationEngine engine;
    // ADR-0039 step 17: the window keeps its key look while a shell menu or the Control Center holds the keyboard (keywindow.h).
    new grassfield::apps::KeyWindow(&engine);
    // Installed Grassfield.Ui lives in the system QML directory; QML_IMPORT_PATH (the tree's ui/ in a dev session) is added
    // after it in reverse, so that its first entry is searched first (as the Store).
    engine.addImportPath(QStringLiteral("/usr/lib/qt6/qml"));
    const QStringList devPaths = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
    for (auto it = devPaths.crbegin(); it != devPaths.crend(); ++it)
        engine.addImportPath(*it);
    engine.addImageProvider(QStringLiteral("icon"), new activity::IconProvider);

    QString qmlDir = qEnvironmentVariable("GRASSFIELD_ACTIVITY_QML");
    if (qmlDir.isEmpty())
        qmlDir = QStringLiteral(GRASSFIELD_ACTIVITY_QML_DIR);
    engine.setInitialProperties({{QStringLiteral("backend"), QVariant::fromValue(&backend)},
                                 {QStringLiteral("globalMenu"), grassfield::apps::globalMenuAvailable()}});
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(QStringLiteral("Main.qml"))));
    if (engine.rootObjects().isEmpty())
        return 1;
    grassfield::apps::followGlobalMenu(engine.rootObjects().constFirst(), "globalMenu");
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
    if (window) {
        new activity::ShownWatch(window, &backend);
        QObject::connect(&service, &activity::ActivityService::activateRequested, window, [window](const QString &token) {
            activity::activateWindow(window, token, [window] { activity::askShellToReopen(window); });
        });
    }
    return app.exec();
}
