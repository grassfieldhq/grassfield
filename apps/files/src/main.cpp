#include <QApplication>
#include <QCommandLineParser>
#include <QDir>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QStandardPaths>
#include <QUrl>

#include "translationloader.h"
#include "applicationslogic.h"
#include "filesapp.h"
#include "globalmenu.h"
#include "keywindow.h"
#include "windowchrome.h"
#include "appicons.h"
#include "imageproviders.h"
#include "textrender.h"

#ifndef GRASSFIELD_FILES_QML_DIR
#define GRASSFIELD_FILES_QML_DIR "/usr/share/grassfield/files/qml"
#endif
#ifndef GRASSFIELD_VERSION
#define GRASSFIELD_VERSION "unknown" // the real one comes from VERSION (cmake/GrassfieldVersion.cmake, build-direct.sh)
#endif

int main(int argc, char *argv[])
{
    // The icon decoder child (AppIcons::loadIsolated runs this binary): decode stdin to a PNG on stdout and nothing else.
    if (AppIcons::isDecodeChildInvocation(argc, argv))
        return AppIcons::decodeChildMain(argc, argv);
    // Session start (config/hypr/grassfield/autostart.lua; decision F-19 of docs/specs/files.md): Grassfield's apps become the
    // Grassfield session's defaults for their types where the user's grassfield-mimeapps.list has no entry yet; nothing else
    // runs, no window. Only in that session: elsewhere the name is not in XDG_CURRENT_DESKTOP and nothing is written.
    if (argc == 2 && qstrcmp(argv[1], "--seed-default-apps") == 0) {
        QCoreApplication core(argc, argv);
        if (DefaultApps::grassfieldDesktop(qEnvironmentVariable("XDG_CURRENT_DESKTOP"))) {
            QStringList dirs;
            for (const QString &data : QStandardPaths::standardLocations(QStandardPaths::GenericDataLocation))
                dirs << data + QStringLiteral("/applications");
            // Omarchy's shipped defaults, read as data (an explicit choice of the user's is told from them: seedsAllowed).
            const QString omarchy = qEnvironmentVariableIsEmpty("OMARCHY_PATH") ? QStringLiteral("/usr/share/omarchy") : qEnvironmentVariable("OMARCHY_PATH");
            // Every list the lookup reads after the session's own, in the specification's order ($XDG_CONFIG_HOME,
            // $XDG_CONFIG_DIRS, then the data directories' applications/): a choice in any of them is kept.
            QStringList desktops;
            for (const QString &name : qEnvironmentVariable("XDG_CURRENT_DESKTOP").split(QLatin1Char(':'), Qt::SkipEmptyParts))
                desktops << name.toLower();
            const QStringList lists = DefaultApps::lookupLists(QStandardPaths::standardLocations(QStandardPaths::GenericConfigLocation),
                                                               QStandardPaths::standardLocations(QStandardPaths::GenericDataLocation), desktops);
            DefaultApps::seedSessionDefaults(QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation), dirs, omarchy, lists);
        }
        return 0;
    }
    // QApplication (not QGuiApplication): KIO's widgets library (KDirLister, its job delegate class) expects one; its
    // dialogs are not used (Grassfield's sheets, ADR-0035 D-12 a, src/kioprompts.h).
    QApplication app(argc, argv);
    // The app's static text is rasterised natively (ADR-0039 Q5, step 19): distance-field glyphs carry 8 to 20 % less ink than
    // macOS's, so text read greyer and softer; no app text is scaled or animated (an item that is sets its own renderType).
    grassfield::apps::applyTextRenderType(); // native unless GRASSFIELD_TEXT_RENDER says otherwise (textrender.h)
    // Before any QML: no global menu item may hold Qt's first shortcut id (globalmenu.h).
    grassfield::apps::reserveFirstShortcutId(app);
    // ADR-0015: windows that draw their own chrome (QML property gfChromeRole) are tagged for the compositor plugin.
    new grassfield::apps::ChromeTagger(&app);
    grassfield::i18n::installForApplication(); // English source; fr via grassfield_fr.qm
    app.setApplicationName(QStringLiteral("grassfield-files"));
    app.setApplicationDisplayName(QObject::tr("Files"));
    app.setApplicationVersion(QStringLiteral(GRASSFIELD_VERSION));
    app.setOrganizationName(QStringLiteral("Grassfield"));
    // Wayland app_id: matches org.grassfield.Files.desktop.
    app.setDesktopFileName(QStringLiteral("org.grassfield.Files"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QObject::tr("Browse and manage files"));
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addPositionalArgument(QStringLiteral("locations"), QObject::tr("Folders or URLs to open, one window each."), QStringLiteral("[locations...]"));
    // --info: the Get Info window of each location instead of a browser window (the desktop's Get Info, macOS model).
    const QCommandLineOption infoOption(QStringLiteral("info"), QObject::tr("Show the Get Info window of each location."));
    parser.addOption(infoOption);
    parser.process(app);
    // --info shows its window only once the folder listing ended: KIO jobs hold quit locks, and the last one released with
    // no window open yet would quit the app before the window appears. It quits when its last window closes instead.
    if (parser.isSet(infoOption))
        app.setQuitLockEnabled(false);

    QList<QUrl> urls;
    const QStringList args = parser.positionalArguments();
    for (const QString &arg : args) {
        const QUrl url = QUrl::fromUserInput(arg, QDir::currentPath(), QUrl::AssumeLocalFile);
        if (url.isValid())
            urls << url;
    }

    // The backend outlives the engine (declared first, destroyed last): bindings that run while the engine tears the
    // windows down still see it.
    FilesApp files(urls);

    QQmlApplicationEngine engine;
    // ADR-0039 step 17: the window keeps its key look while a shell menu or the Control Center holds the keyboard (keywindow.h).
    new grassfield::apps::KeyWindow(&engine);
    // Installed Grassfield.Ui lives in the system QML directory; QML_IMPORT_PATH adds the repo in dev.
    engine.addImportPath(QStringLiteral("/usr/lib/qt6/qml"));
    // addImportPath puts a path before the ones searched so far, so the system directory above would shadow the tree's own
    // Grassfield.Ui in a dev session (a new token or Appearance property would not exist): add QML_IMPORT_PATH after it, in
    // reverse so that its first entry is searched first (same as Preview).
    const QStringList devPaths = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
    for (auto it = devPaths.crbegin(); it != devPaths.crend(); ++it)
        engine.addImportPath(*it);
    engine.addImageProvider(QStringLiteral("icon"), new IconProvider);
    engine.addImageProvider(QStringLiteral("appicon"), new AppIconProvider);
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &app, [] {
        AppIconProvider::shutdown();
        // A walk of the applications (a link to / can take seconds) must not overlap Qt's shutdown: waited for, bounded like the decoders.
        ApplicationsLogic::waitForListings(3500);
    });
    engine.addImageProvider(QStringLiteral("thumbnail"), new ThumbnailProvider);

    QString qmlDir = qEnvironmentVariable("GRASSFIELD_FILES_QML");
    if (qmlDir.isEmpty())
        qmlDir = QStringLiteral(GRASSFIELD_FILES_QML_DIR);

    // Global menu (T1): the windows export their menus only while the registrar is there (globalmenu.h).
    engine.setInitialProperties({{QStringLiteral("app"), QVariant::fromValue(&files)},
                                 {QStringLiteral("globalMenu"), grassfield::apps::globalMenuAvailable()},
                                 {QStringLiteral("infoOnly"), parser.isSet(infoOption)}});
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(QStringLiteral("Main.qml"))));
    if (engine.rootObjects().isEmpty())
        return 1;
    // The registrar may appear later (an app started before the bridge) or restart: the menus follow it.
    grassfield::apps::followGlobalMenu(engine.rootObjects().constFirst(), "globalMenu");
    return app.exec();
}
