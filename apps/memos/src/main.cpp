#include <QCommandLineParser>
#include <QDBusConnection>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QLibraryInfo>
#include <QMetaObject>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QSocketNotifier>
#include <QUrl>

#include <csignal>
#include <sys/socket.h>
#include <unistd.h>

#include "globalmenu.h"
#include "hyprframes.h"
#include "keywindow.h"
#include "memosapp.h"
#include "memosinstance.h"
#include "textrender.h"
#include "translationloader.h"
#include "windowchrome.h"

#ifndef GRASSFIELD_MEMOS_QML_DIR
#define GRASSFIELD_MEMOS_QML_DIR "/usr/share/grassfield/memos/qml"
#endif
#ifndef GRASSFIELD_VERSION
#define GRASSFIELD_VERSION "unknown" // the real one comes from VERSION (cmake/GrassfieldVersion.cmake, build-direct.sh)
#endif

namespace {

// SIGTERM (the session's logout, systemd stopping the app's scope) and SIGINT quit through the event loop, so the memos are
// written first (aboutToQuit). The handler only writes one byte to a socket pair (async-signal-safe).
int g_signalPipe[2] = {-1, -1};

void onSignal(int)
{
    const char byte = 1;
    [[maybe_unused]] const ssize_t n = ::write(g_signalPipe[0], &byte, 1);
}

void quitOnSignals(QGuiApplication &app)
{
    if (::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, g_signalPipe) != 0)
        return;
    auto *notifier = new QSocketNotifier(g_signalPipe[1], QSocketNotifier::Read, &app);
    QObject::connect(notifier, &QSocketNotifier::activated, &app, [notifier] {
        char byte;
        [[maybe_unused]] const ssize_t n = ::read(g_signalPipe[1], &byte, 1);
        notifier->setEnabled(false);
        QCoreApplication::quit();
    });
    struct sigaction action = {};
    action.sa_handler = onSignal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    ::sigaction(SIGTERM, &action, nullptr);
    ::sigaction(SIGINT, &action, nullptr);
}

// Sends a memo window's tag again (the memo collapsed or expanded: its tag now names the size the compositor's rule gives the
// window, ADR-0051 D-6): the same request ChromeTagger sends at the window's creation (apps/windowchrome.h).
void sendTagAgain(QWindow *window, const QString &tag)
{
    if (!window || QGuiApplication::platformName() != QLatin1String("wayland"))
        return;
    auto *native = window->nativeInterface<QNativeInterface::Private::QWaylandWindow>();
    if (auto *toplevel = native ? native->surfaceRole<::xdg_toplevel>() : nullptr)
        grassfield::apps::detail::sendTag(toplevel, tag.toUtf8());
}

} // namespace

int main(int argc, char *argv[])
{
    // The Grassfield controls style when it is installed, the Basic style otherwise (as the other apps, GF-085).
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
    // The app's static text is rasterised natively (ADR-0039 Q5, step 19), as every app.
    grassfield::apps::applyTextRenderType();
    // Before any QML: no global menu item may hold Qt's first shortcut id (globalmenu.h).
    grassfield::apps::reserveFirstShortcutId(app);
    // ADR-0015: each memo window draws its own chrome (QML property gfChromeRole, its memo tag), tagged for the compositor.
    new grassfield::apps::ChromeTagger(&app);
    grassfield::i18n::installForApplication(); // English source; fr via grassfield_fr.qm
    app.setApplicationName(QStringLiteral("grassfield-memos"));
    app.setApplicationVersion(QStringLiteral(GRASSFIELD_VERSION));
    app.setOrganizationName(QStringLiteral("Grassfield"));
    app.setDesktopFileName(QStringLiteral("org.grassfield.Memos")); // Wayland app id: org.grassfield.Memos.desktop
    // The app quits when its last memo is closed (Main.qml), not when a window closes.
    app.setQuitOnLastWindowClosed(false);

    QCommandLineParser parser;
    parser.setApplicationDescription(QObject::tr("Keep short notes on the desktop."));
    parser.addHelpOption();
    parser.addVersionOption();
    parser.process(app);

    // One instance (ADR-0051 D-2): a second launch brings the running app's memos forward with its activation token.
    memos::MemosInstance instance;
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (bus.isConnected() && memos::claimOrHandOver(bus, &instance, qEnvironmentVariable("XDG_ACTIVATION_TOKEN")) == memos::Launch::Leave)
        return 0;

    quitOnSignals(app);

    // The backend outlives the engine (declared first, destroyed last).
    memos::MemosApp backend(memos::MemoStore::dataDir(), [] { return memos::currentFrames(); });
    QObject::connect(&backend, &memos::MemosApp::retagRequested, &app, &sendTagAgain);
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &backend, [&backend] { backend.saveNow(); });

    QQmlApplicationEngine engine;
    // ADR-0039 step 17: a memo keeps its key look while a shell menu holds the keyboard (keywindow.h).
    new grassfield::apps::KeyWindow(&engine);
    // Installed Grassfield.Ui lives in the system QML directory; QML_IMPORT_PATH (the tree's ui/ in a dev session) is added
    // after it in reverse, so that its first entry is searched first (as the other apps).
    engine.addImportPath(QStringLiteral("/usr/lib/qt6/qml"));
    const QStringList devPaths = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
    for (auto it = devPaths.crbegin(); it != devPaths.crend(); ++it)
        engine.addImportPath(*it);

    QString qmlDir = qEnvironmentVariable("GRASSFIELD_MEMOS_QML");
    if (qmlDir.isEmpty())
        qmlDir = QStringLiteral(GRASSFIELD_MEMOS_QML_DIR);
    engine.setInitialProperties({{QStringLiteral("backend"), QVariant::fromValue(&backend)},
                                 {QStringLiteral("globalMenu"), grassfield::apps::globalMenuAvailable()}});
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(QStringLiteral("Main.qml"))));
    if (engine.rootObjects().isEmpty())
        return 1;
    QObject *root = engine.rootObjects().constFirst();
    // The registrar may appear later or restart: every memo's menus follow it.
    grassfield::apps::followGlobalMenu(root, "globalMenu");
    QObject::connect(&instance, &memos::MemosInstance::activateRequested, root, [root](const QString &token) {
        // The token for Qt's next activation request (Store's activateWindow), then the memos come forward.
        if (!token.isEmpty())
            qputenv("XDG_ACTIVATION_TOKEN", token.toUtf8());
        QMetaObject::invokeMethod(root, "activate");
    });
    return app.exec();
}
