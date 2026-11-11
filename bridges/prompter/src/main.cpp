// SPDX-License-Identifier: MIT
// grassfield-prompter: gcr's system prompter for the Grassfield session; the shell draws the prompts (ADR-0035 D-9, owner
// decision Q1 = S2; docs/specs/system-dialogs.md section 5).
//
// Usage: grassfield-prompter [--peer-unit UNIT] [--socket PATH] [--nm-timeout-ms N] [--bt-timeout-ms N]
//                            [--kio-store-timeout-ms N] [--version]
//   --peer-unit UNIT   the systemd unit whose process may connect as the shell (default grassfield-security.service, the
//                      security process that draws the sheets since ADR-0041 S3); set by
//                      grassfield-prompter.service. Only an argument: no environment variable changes it.
//   --socket PATH      the socket (default $XDG_RUNTIME_DIR/grassfield/prompter.sock); required in a development run
//   --nm-timeout-ms N  development runs only (the tests): how long a NetworkManager request waits for its answer
//                      (default 110000, under NetworkManager's own 120 s)
//   --bt-timeout-ms N  development runs only (the tests): how long a Bluetooth pairing step waits for its answer
//                      (default 55000, under bluetoothd's own 60 s)
//   --kio-store-timeout-ms N  development runs only (the tests): how long a KIO password on its way to the keychain holds
//                      one of the stores' places (default 120000)
// KIO's password server (step 9e) is on the session bus; the Secret Service it remembers passwords in is reached through
// libsecret's own connection to that bus.
// The system bus (the NetworkManager secret agent, step 9c; the BlueZ pairing agent, step 10): in the session always
// unix:path=/run/dbus/system_bus_socket,
// whatever DBUS_SYSTEM_BUS_ADDRESS says; in a development run only DBUS_SYSTEM_BUS_ADDRESS when it is a private test bus
// under GF_TEST_BUS_DIR (none set: no agent). No system bus: no agents, gcr's prompts unchanged; NetworkManager or bluetoothd
// absent from it: that agent registers when it comes.
// Environment:
//   GRASSFIELD_SESSION=1   required in the Grassfield session (the systemd unit checks it too)
//   GRASSFIELD_DEV=1       development run (ADR-0019: only while GRASSFIELD_SESSION is not "1"): only on a private test bus
//                          (GF_TEST_BUS=1 and DBUS_SESSION_BUS_ADDRESS under GF_TEST_BUS_DIR, the rule of the tests' fakes),
//                          never the user's own bus; the shell's cgroup is then matched by its last component only (a
//                          container has no user manager)
// Exit status: 0 stopped by a signal, 1 the bus connection closed, 2 environment error, 3 refused by a safety check.

#include "Bridge.h"
#include "BtPairing.h"
#include "Filter.h"
#include "KioAuth.h"
#include "NmSecrets.h"
#include "Log.h"
#include "Peer.h"
#include "Protocol.h"
#include "runmode.h"
#include "testbus.h"

#include <QAbstractEventDispatcher>
#include <QCoreApplication>
#include <QSocketNotifier>
#include <QStringList>

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <unistd.h>

using namespace gf::prompter;

namespace {
    int refuse(const QString& why) {
        log(QStringLiteral("refusing to start: %1").arg(why));
        return 3;
    }

    int envError(const QString& why) {
        log(QStringLiteral("cannot start: %1").arg(why));
        return 2;
    }

    void onClosed(GDBusConnection* /*bus*/, gboolean /*remotePeerVanished*/, GError* /*error*/, gpointer /*data*/) {
        log(QStringLiteral("the bus connection closed: stopping"));
        QCoreApplication::exit(1);
    }

    // The real system bus's socket (D-Bus specification): the session bridge never takes another from its environment.
    constexpr char kSystemBus[] = "unix:path=/run/dbus/system_bus_socket";

    void onSystemClosed(GDBusConnection* /*bus*/, gboolean /*remotePeerVanished*/, GError* /*error*/, gpointer /*data*/) {
        log(QStringLiteral("the system bus connection closed: NetworkManager and bluetoothd have no agent until the bridge restarts"));
    }

    GDBusConnection* connectBus(const QString& address, GError** error) {
        return g_dbus_connection_new_for_address_sync(
            address.toUtf8().constData(), static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
            nullptr, nullptr, error);
    }

    bool hasOwner(GDBusConnection* bus, const char* name) {
        GVariant* reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                                                      g_variant_new("(s)", name), G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, nullptr);
        gboolean  owned = TRUE; // no answer: assume the worst
        if (reply) {
            g_variant_get(reply, "(b)", &owned);
            g_variant_unref(reply);
        }
        return owned;
    }
} // namespace

int main(int argc, char** argv) {
    // Passwords pass through this process: no core file, no ptrace by the user's other processes (the unit also sets
    // LimitCORE=0 and MemorySwapMax=0). Its own /proc/self stays readable (the pidfds' fdinfo).
    ::prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
    // GDBus and Qt print messages with their arguments under these: never here (the unit unsets them too). GDBus reads
    // G_DBUS_DEBUG when the first connection is made, below.
    ::unsetenv("G_DBUS_DEBUG");
    ::unsetenv("QDBUS_DEBUG");
    ::unsetenv("G_MESSAGES_DEBUG");

    // Termination signals are read from a signalfd in the event loop; blocked before any thread exists.
    sigset_t blocked;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGTERM);
    sigaddset(&blocked, SIGINT);
    sigaddset(&blocked, SIGHUP);
    pthread_sigmask(SIG_BLOCK, &blocked, nullptr);
    const int signalFd = signalfd(-1, &blocked, SFD_CLOEXEC | SFD_NONBLOCK);

    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("grassfield-prompter"));
    QCoreApplication::setApplicationVersion(QLatin1String(kBridgeVersion));
    // A caller can make libgcr warn (GLib's G_DEBUG=fatal-warnings would turn that into an exit): only errors are fatal.
    g_log_set_always_fatal(G_LOG_LEVEL_ERROR);

    QString           socketArgument;
    QString           peerUnit    = QStringLiteral("grassfield-security.service");
    int               nmTimeoutMs = 0; // 0: the default
    int               btTimeoutMs = 0; // 0: the default
    int               storeTimeoutMs = 0; // 0: the default
    const QStringList args     = QCoreApplication::arguments();
    for (qsizetype i = 1; i < args.size(); ++i) {
        if (args.at(i) == QLatin1String("--version")) {
            std::printf("grassfield-prompter %s (%s)\n", kBridgeVersion, kProtocol);
            return 0;
        }
        if (args.at(i) == QLatin1String("--socket") && i + 1 < args.size()) {
            socketArgument = args.at(++i);
            continue;
        }
        if (args.at(i) == QLatin1String("--peer-unit") && i + 1 < args.size()) {
            peerUnit = args.at(++i);
            continue;
        }
        if (args.at(i) == QLatin1String("--nm-timeout-ms") && i + 1 < args.size()) {
            bool ok     = false;
            nmTimeoutMs = args.at(++i).toInt(&ok);
            if (!ok || nmTimeoutMs < 100 || nmTimeoutMs > nm::kAnswerTimeoutMs) {
                std::fprintf(stderr, "grassfield-prompter: --nm-timeout-ms takes 100 to %d\n", nm::kAnswerTimeoutMs);
                return 2;
            }
            continue;
        }
        if (args.at(i) == QLatin1String("--bt-timeout-ms") && i + 1 < args.size()) {
            bool ok     = false;
            btTimeoutMs = args.at(++i).toInt(&ok);
            if (!ok || btTimeoutMs < 100 || btTimeoutMs > bt::kAnswerTimeoutMs) {
                std::fprintf(stderr, "grassfield-prompter: --bt-timeout-ms takes 100 to %d\n", bt::kAnswerTimeoutMs);
                return 2;
            }
            continue;
        }
        if (args.at(i) == QLatin1String("--kio-store-timeout-ms") && i + 1 < args.size()) {
            bool ok        = false;
            storeTimeoutMs = args.at(++i).toInt(&ok);
            if (!ok || storeTimeoutMs < 100 || storeTimeoutMs > KioServer::kStoreTimeoutMs) {
                std::fprintf(stderr, "grassfield-prompter: --kio-store-timeout-ms takes 100 to %d\n", KioServer::kStoreTimeoutMs);
                return 2;
            }
            continue;
        }
        std::fprintf(stderr, "usage: grassfield-prompter [--peer-unit UNIT] [--socket PATH] [--nm-timeout-ms N] [--bt-timeout-ms N] [--kio-store-timeout-ms N] [--version]\n");
        return 2;
    }

    const bool dev     = grassfield::apps::runmode::dev();
    const bool session = grassfield::apps::runmode::session();
    if (!dev && !session)
        return refuse(QStringLiteral("not in a Grassfield session (GRASSFIELD_SESSION=1) and not a development run (GRASSFIELD_DEV=1)"));
    const QString address = qEnvironmentVariable("DBUS_SESSION_BUS_ADDRESS");
    if (dev) {
        // Never the user's own bus: the real gcr clients and the real secrets are there.
        if (qgetenv("GF_TEST_BUS") != "1" || !grassfield::apps::isPrivateTestBus(address, qEnvironmentVariable("GF_TEST_BUS_DIR")))
            return refuse(QStringLiteral("a development run needs a private test bus (GF_TEST_BUS=1, DBUS_SESSION_BUS_ADDRESS under GF_TEST_BUS_DIR)"));
        if (socketArgument.isEmpty())
            return refuse(QStringLiteral("a development run needs --socket"));
    }
    if (!validPeerUnit(peerUnit, dev))
        return refuse(QStringLiteral("--peer-unit %1 is not a systemd service name").arg(peerUnit));
    if (nmTimeoutMs && !dev)
        return refuse(QStringLiteral("--nm-timeout-ms is for development runs only"));
    if (btTimeoutMs && !dev)
        return refuse(QStringLiteral("--bt-timeout-ms is for development runs only"));
    if (storeTimeoutMs && !dev)
        return refuse(QStringLiteral("--kio-store-timeout-ms is for development runs only"));
    // The system bus of the NetworkManager and BlueZ agents: the real one in the session, only a private test bus in a
    // development run.
    QString systemAddress;
    if (dev) {
        systemAddress = qEnvironmentVariable("DBUS_SYSTEM_BUS_ADDRESS");
        if (!systemAddress.isEmpty() && !grassfield::apps::isPrivateTestBus(systemAddress, qEnvironmentVariable("GF_TEST_BUS_DIR")))
            return refuse(QStringLiteral("a development run takes DBUS_SYSTEM_BUS_ADDRESS only for a private test bus under GF_TEST_BUS_DIR"));
    } else {
        systemAddress = QLatin1String(kSystemBus);
    }

    // libgcr runs its callbacks in GLib's main context, which Qt's GLib event dispatcher runs (QT_NO_GLIB turns it off).
    if (!QAbstractEventDispatcher::instance() || !QAbstractEventDispatcher::instance()->inherits("QEventDispatcherGlib"))
        return envError(QStringLiteral("Qt is not running GLib's event loop (QT_NO_GLIB set?)"));

    const QString path = socketPath(socketArgument, qEnvironmentVariable("XDG_RUNTIME_DIR"));
    if (path.isEmpty())
        return envError(QStringLiteral("no socket path (XDG_RUNTIME_DIR unset, or a relative --socket)"));

    GError* error   = nullptr;
    gchar*  busAddr = address.isEmpty() ? g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, nullptr, &error) : g_strdup(address.toUtf8().constData());
    GDBusConnection* bus = busAddr ? g_dbus_connection_new_for_address_sync(
                                         busAddr, static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
                                         nullptr, nullptr, &error)
                                   : nullptr;
    g_free(busAddr);
    if (!bus) {
        const QString why = QString::fromUtf8(error ? error->message : "unknown error");
        g_clear_error(&error);
        return envError(QStringLiteral("no D-Bus session bus: %1").arg(why));
    }
    g_dbus_connection_set_exit_on_close(bus, FALSE);
    g_signal_connect(bus, "closed", G_CALLBACK(onClosed), nullptr);
    // A real session bus has the systemd user manager on it; a private test bus never does.
    if (dev && hasOwner(bus, "org.freedesktop.systemd1")) {
        g_object_unref(bus);
        return refuse(QStringLiteral("a development run found org.freedesktop.systemd1 on its bus: not a private test bus"));
    }

    GDBusConnection* systemBus = nullptr;
    if (!systemAddress.isEmpty()) {
        systemBus = connectBus(systemAddress, &error);
        if (!systemBus) {
            log(QStringLiteral("no system bus (%1): no NetworkManager secret agent, no Bluetooth pairing agent").arg(QString::fromUtf8(error ? error->message : "unknown error")));
            g_clear_error(&error);
        } else if (dev && hasOwner(systemBus, "org.freedesktop.systemd1")) {
            g_object_unref(systemBus);
            g_object_unref(bus);
            return refuse(QStringLiteral("a development run found org.freedesktop.systemd1 on its system bus: not a private test bus"));
        } else {
            g_dbus_connection_set_exit_on_close(systemBus, FALSE);
            g_signal_connect(systemBus, "closed", G_CALLBACK(onSystemClosed), nullptr);
        }
    } else {
        log(QStringLiteral("a development run without DBUS_SYSTEM_BUS_ADDRESS: no NetworkManager secret agent, no Bluetooth pairing agent"));
    }

    Bridge::Options options;
    options.socketPath         = path;
    options.peerUnit           = peerUnit;
    options.requireUserManager = !dev;
    options.uid                = ::getuid();
    options.systemBus          = systemBus;
    // Where gnome-keyring keeps its keyrings (GLib's user data directory, as gnome-keyring finds it): the KIO server reads
    // only whether the default one has a password (step 9e).
    options.keyringDirectory = kio::keyringDirectory(qEnvironmentVariable("XDG_DATA_HOME"), QString::fromUtf8(g_get_home_dir()));
    if (nmTimeoutMs)
        options.nmTimeoutMs = nmTimeoutMs;
    if (btTimeoutMs)
        options.btTimeoutMs = btTimeoutMs;
    options.kioStoreTimeoutMs = storeTimeoutMs;
    int rc = 0;
    {
        Bridge  bridge(bus, options);
        QString startError;
        if (!bridge.start(&startError)) {
            if (systemBus)
                g_object_unref(systemBus);
            g_object_unref(bus);
            return envError(startError);
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
        log(QStringLiteral("%1 %2 on %3 (%4)")
                .arg(QLatin1String(kBridgeVersion), QLatin1String(kProtocol), QString::fromUtf8(g_dbus_connection_get_unique_name(bus)),
                     dev ? QStringLiteral("development, private test bus") : QStringLiteral("session")));
        rc = QCoreApplication::exec();
        bridge.stop();
    }
    if (signalFd >= 0)
        ::close(signalFd);
    if (systemBus)
        g_object_unref(systemBus);
    g_object_unref(bus);
    return rc;
}
