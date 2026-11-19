#include <QCommandLineParser>
#include <QDBusConnection>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTimer>

#include <cstdio>
#include <unistd.h>
#include <QLibraryInfo>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QUrl>

#include <memory>

#include "globalmenu.h"
#include "screenshotprovider.h"
#include "storebackend.h"
#include "storeinstance.h"
#include "translationloader.h"
#include "keywindow.h"
#include "windowchrome.h"
#include "textrender.h"

#ifndef GRASSFIELD_STORE_QML_DIR
#define GRASSFIELD_STORE_QML_DIR "/usr/share/grassfield/store/qml"
#endif
#ifndef GRASSFIELD_VERSION
#define GRASSFIELD_VERSION "unknown" // the real one comes from VERSION (cmake/GrassfieldVersion.cmake, build-direct.sh)
#endif

int main(int argc, char *argv[])
{
    // The Grassfield controls style for this app only when it is installed, the Basic style otherwise (as Preview, GF-085).
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
    // Icons and screenshots come from third parties: every decoder (QML Image included) is bounded to this much memory.
    QImageReader::setAllocationLimit(128);

    // `--removable` (ADR-0046 D1) answers the launcher and Files once and shows no window: offscreen, whatever the session says.
    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--removable") == 0) {
            qputenv("QT_QPA_PLATFORM", "offscreen");
            qputenv("QT_QPA_PLATFORMTHEME", "none"); // a GTK platform theme would look for a display and fail (exit 1)
        }
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
    app.setApplicationName(QStringLiteral("grassfield-store"));
    app.setApplicationVersion(QStringLiteral(GRASSFIELD_VERSION));
    app.setOrganizationName(QStringLiteral("Grassfield"));
    app.setDesktopFileName(QStringLiteral("org.grassfield.Store")); // Wayland app_id: org.grassfield.Store.desktop

    QCommandLineParser parser;
    parser.setApplicationDescription(QObject::tr("Find, read about and open apps for Grassfield."));
    parser.addHelpOption();
    parser.addVersionOption();
    const QCommandLineOption pageOption(QStringLiteral("page"),
                                        QObject::tr("Open this page first: discover, section:<id>, categories, category:<id>, app:<id>, "
                                                    "search:<words>, installed or updates."),
                                        QStringLiteral("page"));
    parser.addOption(pageOption);
    const QCommandLineOption removableOption(QStringLiteral("removable"),
                                             QObject::tr("Print, as JSON, the installed apps by application entry and whether the Store may uninstall each."));
    parser.addOption(removableOption);
    parser.process(app);

    if (parser.isSet(removableOption)) {
        // One-shot: the read of this computer's apps, printed once it is done; the launcher and Files run it (never two
        // Stores: it takes no bus name, starts no operation and touches no state file).
        grassfield::store::StoreBackend backend;
        // Printed once: the launcher and Files parse the whole output as one JSON document. The plans (a pacman -Rs each) run
        // on the workers (SU-02): the GUI thread stays free, so the watchdog below can always fire.
        bool asked = false;
        QObject::connect(&backend, &grassfield::store::StoreBackend::loadingChanged, &app, [&backend, &app, &asked] {
            if (backend.loading() || asked)
                return;
            asked = true;
            backend.removalByEntryAsync([&app](const QVariantMap &entries) {
                const QJsonObject doc{{QStringLiteral("version"), 1}, {QStringLiteral("entries"), QJsonObject::fromVariantMap(entries)}};
                const QByteArray text = QJsonDocument(doc).toJson(QJsonDocument::Compact) + '\n';
                fwrite(text.constData(), 1, static_cast<size_t>(text.size()), stdout);
                fflush(stdout);
                app.quit();
            });
        });
        QTimer::singleShot(120000, &app, [&app] { app.exit(1); });
        backend.loadOnly();
        const int code = app.exec();
        // A job still running (the watchdog fired): not waited for (SU-07).
        if (!backend.drain(2000))
            _exit(code);
        return code;
    }

    // One Store per user (storeinstance.h): a second launch hands its page and its activation token to the running one and
    // leaves (Files' "Search the Store", a second click on its entry).
    QDBusConnection bus = QDBusConnection::sessionBus();
    grassfield::store::StoreInstance instance;
    if (bus.isConnected()
        && grassfield::store::claimOrHandOver(bus, &instance, grassfield::store::StoreInstance::cleanPage(parser.value(pageOption)),
                                              grassfield::store::StoreInstance::cleanToken(qEnvironmentVariable("XDG_ACTIVATION_TOKEN")))
            == grassfield::store::Launch::Leave)
        return 0;

    // The backend outlives the engine (declared first, destroyed last): bindings that run while the engine tears the
    // window down still see it.
    grassfield::store::StoreBackend backend;

    QQmlApplicationEngine engine;
    // ADR-0039 step 17: the window keeps its key look while a shell menu or the Control Center holds the keyboard (keywindow.h).
    new grassfield::apps::KeyWindow(&engine);
    // Installed Grassfield.Ui lives in the system QML directory; QML_IMPORT_PATH (the tree's ui/ in a dev session) is
    // added after it in reverse, so that its first entry is searched first (as Preview).
    engine.addImportPath(QStringLiteral("/usr/lib/qt6/qml"));
    const QStringList devPaths = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
    for (auto it = devPaths.crbegin(); it != devPaths.crend(); ++it)
        engine.addImportPath(*it);
    engine.addImageProvider(QStringLiteral("screenshot"), new grassfield::store::ScreenshotProvider(backend.screenshotGate()));

    QString qmlDir = qEnvironmentVariable("GRASSFIELD_STORE_QML");
    if (qmlDir.isEmpty())
        qmlDir = QStringLiteral(GRASSFIELD_STORE_QML_DIR);
    engine.setInitialProperties({{QStringLiteral("backend"), QVariant::fromValue(&backend)},
                                 {QStringLiteral("globalMenu"), grassfield::apps::globalMenuAvailable()},
                                 {QStringLiteral("startPage"), parser.value(pageOption)}});
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(QStringLiteral("Main.qml"))));
    if (engine.rootObjects().isEmpty())
        return 1;
    grassfield::apps::followGlobalMenu(engine.rootObjects().constFirst(), "globalMenu");
    // A page another launch asked for: the window goes there (Main.qml openPage checks it) and comes forward.
    QObject::connect(&instance, &grassfield::store::StoreInstance::openRequested, &app, [&engine, &backend](const QString &page, const QString &token) {
        // Asked for again while a quit waits for the running operation (Ctrl+Q, the window closed): the Store stays.
        backend.reopened();
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().value(0));
        if (!window)
            return;
        if (!page.isEmpty())
            QMetaObject::invokeMethod(window, "openPage", Q_ARG(QString, page));
        grassfield::store::activateWindow(window, token);
    });
    // The last window closed while an operation runs: the Store stays until it ends (ADR-0037 f; it holds Omarchy's update
    // lock and keeps the result), then quits.
    app.setQuitOnLastWindowClosed(false);
    QObject::connect(&app, &QGuiApplication::lastWindowClosed, &backend, &grassfield::store::StoreBackend::quitWhenIdle);
    // SU-07: the bus name goes as soon as the Store quits, before its workers are waited for: a launch meanwhile (the Dock,
    // Files' "Search the Store", the launcher's uninstall) takes the name and opens a new Store at once, never handing its
    // page to one that is going away.
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &app, [&bus] {
        if (!bus.isConnected())
            return;
        bus.unregisterService(grassfield::store::StoreInstance::serviceName());
        bus.unregisterObject(grassfield::store::StoreInstance::objectPath());
    });
    // The first load starts once the window has its first frame: the window never waits for pacman or AppStream.
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
    if (window) {
        auto started = std::make_shared<bool>(false);
        QObject::connect(window, &QQuickWindow::frameSwapped, &backend, [&backend, started] {
            if (*started)
                return;
            *started = true;
            backend.start();
        });
    } else {
        backend.start();
    }
    const int code = app.exec();
    // SU-07: the quit is bounded. Every job is told to stop (fetches abort within 0.1 s, children get SIGTERM) and is waited
    // for 5 s at most; one still running then is left behind with the process (_exit: no destructor waits for it). Nothing
    // is lost: store.json and the caches are written whole by rename, and a running operation is the helper's, the terminal's
    // or flatpak's own (flatpak gets SIGTERM with the Store, S25).
    if (!backend.drain(5000)) {
        fflush(stdout);
        fflush(stderr);
        _exit(code);
    }
    return code;
}
