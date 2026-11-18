// SPDX-License-Identifier: MIT
// grassfield-menu-bridge: serves applications' DBusMenu menus to grassfield-shell's menu bar (master-prompt §1.1 D4,
// §5.7 T1/T2, ADR-0008, docs/specs/menu-bridge.md).
//
// Usage: grassfield-menu-bridge [--socket PATH] [--version]
// Environment:
//   GRASSFIELD_SESSION=1             required in the Grassfield session (set by session.lua; the systemd unit checks it)
//   GRASSFIELD_DEV=1                 development run (ADR-0019: only while GRASSFIELD_SESSION is not "1"; a value that
//                                    leaked into the session is ignored): refuses the owner's default session bus
//                                    (/run/user/<uid>/bus) and requires GRASSFIELD_MENU_BRIDGE_SOCKET
//                                    (scripts/dev/shell-run.sh sets both the private bus and the socket)
//   GRASSFIELD_MENU_BRIDGE_SOCKET    socket path of a development run only (ADR-0019 dev plumbing: ignored, and noted,
//                                    in a session); otherwise $XDG_RUNTIME_DIR/grassfield/menu-bridge.sock. --socket
//                                    (an explicit argument, never inherited) is honoured in both
// Exit status: 0 stopped by a signal, 2 environment error, 3 refused by a safety check.

#include "Bridge.h"
#include "DBusObjects.h"
#include "Log.h"
#include "Protocol.h"
#include "Safety.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusError>
#include <QSocketNotifier>
#include <QStringList>

#include <csignal>
#include <cstdio>
#include <sys/signalfd.h>
#include <unistd.h>

using namespace gf::menubridge;

namespace {
    int refuse(const QString& why) {
        log(QStringLiteral("refusing to start: %1").arg(why));
        return 3;
    }

    int envError(const QString& why) {
        log(QStringLiteral("cannot start: %1").arg(why));
        return 2;
    }
} // namespace

int main(int argc, char** argv) {
    // Termination signals are read from a signalfd in the event loop (clean release of the bus names and the
    // socket). They are blocked before any thread exists (QtDBus starts one) so every thread inherits the mask.
    sigset_t blocked;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGTERM);
    sigaddset(&blocked, SIGINT);
    sigaddset(&blocked, SIGHUP);
    pthread_sigmask(SIG_BLOCK, &blocked, nullptr);
    const int signalFd = signalfd(-1, &blocked, SFD_CLOEXEC | SFD_NONBLOCK);
    // Without the signalfd nothing would ever read them: unblocked again, so a stop ends the process at once and not
    // after the unit's TimeoutStopSec with SIGKILL.
    if (signalFd < 0)
        pthread_sigmask(SIG_UNBLOCK, &blocked, nullptr);

    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("grassfield-menu-bridge"));
    QCoreApplication::setApplicationVersion(QLatin1String(kBridgeVersion));

    QString           socketArgument;
    const QStringList args = QCoreApplication::arguments();
    for (qsizetype i = 1; i < args.size(); ++i) {
        if (args.at(i) == QLatin1String("--version")) {
            std::printf("grassfield-menu-bridge %s (%s)\n", kBridgeVersion, kProtocol);
            return 0;
        }
        if (args.at(i) == QLatin1String("--socket") && i + 1 < args.size()) {
            socketArgument = args.at(++i);
            continue;
        }
        std::fprintf(stderr, "usage: grassfield-menu-bridge [--socket PATH] [--version]\n");
        return 2;
    }

    const QByteArray devValue     = qgetenv("GRASSFIELD_DEV");
    const QByteArray sessionValue = qgetenv("GRASSFIELD_SESSION");
    const bool       dev          = devRun(devValue, sessionValue);
    const bool       session      = sessionRun(sessionValue);
    if (session && devValue == "1")
        log(QStringLiteral("GRASSFIELD_DEV=1 ignored: this is a Grassfield session (GRASSFIELD_SESSION=1)"));
    // ADR-0019: the socket variable is development plumbing, honoured only in a development run (a value that leaked into
    // the session would move the bridge away from the socket the shell connects to).
    const QString socketVariable = qEnvironmentVariable("GRASSFIELD_MENU_BRIDGE_SOCKET");
    if (!dev && !socketVariable.isEmpty())
        log(QStringLiteral("GRASSFIELD_MENU_BRIDGE_SOCKET ignored: development plumbing, honoured only in a development run (ADR-0019)"));
    const QString socketOverride = !socketArgument.isEmpty() ? socketArgument : (dev ? socketVariable : QString());
    if (!dev && !session)
        return refuse(QStringLiteral("not in a Grassfield session (GRASSFIELD_SESSION=1) and not a development run (GRASSFIELD_DEV=1)"));
    if (dev) {
        if (isDefaultSessionBus(qEnvironmentVariable("DBUS_SESSION_BUS_ADDRESS"), ::getuid()))
            return refuse(QStringLiteral("GRASSFIELD_DEV=1 and the session bus is the owner's default bus; use the nested shell's private bus (.dev/bus.address)"));
        if (socketOverride.isEmpty())
            return refuse(QStringLiteral("GRASSFIELD_DEV=1 needs GRASSFIELD_MENU_BRIDGE_SOCKET (or --socket) under .dev/"));
    }

    const QString path = socketPath(socketOverride, qEnvironmentVariable("XDG_RUNTIME_DIR"));
    if (path.isEmpty())
        return envError(QStringLiteral("no socket path (XDG_RUNTIME_DIR unset or a relative GRASSFIELD_MENU_BRIDGE_SOCKET)"));

    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected() || !bus.interface())
        return envError(QStringLiteral("no D-Bus session bus: %1").arg(bus.lastError().message()));
    // A real session bus has the systemd user manager on it; a private development bus never does.
    if (dev && bus.interface()->isServiceRegistered(QStringLiteral("org.freedesktop.systemd1")).value())
        return refuse(QStringLiteral("GRASSFIELD_DEV=1 and org.freedesktop.systemd1 is on this bus: not a private development bus"));

    Bridge            bridge(bus, path);
    DiagnosticsObject diagnostics([&bridge] { return bridge.status(); });
    if (!bus.registerVirtualObject(QLatin1String(kDiagnosticsPath), &diagnostics, QDBusConnection::SingleNode))
        return envError(QStringLiteral("cannot export %1").arg(QLatin1String(kDiagnosticsPath)));
    const auto owned = bus.interface()->registerService(QLatin1String(kDiagnosticsService), QDBusConnectionInterface::DontQueueService, QDBusConnectionInterface::DontAllowReplacement);
    if (!owned.isValid() || owned.value() != QDBusConnectionInterface::ServiceRegistered)
        return envError(QStringLiteral("%1 is already owned on this bus (another bridge?)").arg(QLatin1String(kDiagnosticsService)));

    QString error;
    if (!bridge.listen(&error)) {
        bus.interface()->unregisterService(QLatin1String(kDiagnosticsService));
        return envError(error);
    }

    if (signalFd >= 0) {
        auto* notifier = new QSocketNotifier(signalFd, QSocketNotifier::Read, &app);
        QObject::connect(notifier, &QSocketNotifier::activated, &app, [signalFd] {
            signalfd_siginfo info{};
            if (::read(signalFd, &info, sizeof(info)) == static_cast<ssize_t>(sizeof(info)))
                log(QStringLiteral("signal %1: stopping").arg(info.ssi_signo));
            QCoreApplication::quit();
        });
    }
    log(QStringLiteral("%1 %2 on %3 (%4)").arg(QLatin1String(kBridgeVersion), QLatin1String(kProtocol), bus.baseService(), dev ? QStringLiteral("development, private bus") : QStringLiteral("session")));

    const int rc = QCoreApplication::exec();
    bridge.stop();
    bus.unregisterObject(QLatin1String(kDiagnosticsPath));
    bus.interface()->unregisterService(QLatin1String(kDiagnosticsService));
    if (signalFd >= 0)
        ::close(signalFd);
    return rc;
}
