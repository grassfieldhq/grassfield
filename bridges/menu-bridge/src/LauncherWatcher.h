#pragma once

// The D-Bus side of LauncherEntry (ADR-0018, Launcher.h): subscribes to
// com.canonical.Unity.LauncherEntry.Update on the bus the bridge runs on, feeds each signal to launcher::Book (pure
// validation, rate limit, coalescing), turns what the Book forwards into menu/1 "launcher" lines, and clears the
// apps of a sender that leaves the bus. A sender is identified like a menu client (pid of its bus name ->
// appIdentity): malformed input is a penalty against that identity, and a refused identity's signals are dropped. Its
// updates wait in the Book until the identity is known (B-17: an application may only set its own badge, Launcher.h).

#include "Launcher.h"
#include "Penalties.h"

#include <QByteArray>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusServiceWatcher>
#include <QElapsedTimer>
#include <QHash>
#include <QList>
#include <QObject>
#include <QTimer>

#include <functional>

namespace gf::menubridge {

    class LauncherWatcher : public QObject {
        Q_OBJECT
      public:
        struct Hooks {
            // True while the identity is refused (its signals are dropped).
            std::function<bool(const QString& identity)> refused;
            // One malformed update from the identity.
            std::function<void(const QString& identity)> strike;
        };

        LauncherWatcher(const QDBusConnection& bus, Hooks hooks, QObject* parent = nullptr);
        ~LauncherWatcher() override;

        void start();
        void stop();
        // The current state of every app, as launcher lines (for a shell that connects later).
        QList<QByteArray> snapshot() const;

      Q_SIGNALS:
        void line(const QByteArray& launcherLine);

      private Q_SLOTS:
        void onUpdate(const QDBusMessage& message);

      private:
        struct Peer {
            QString identity;
            bool    resolved = false;
            bool    toldForeign = false; // one log line for updates of another application's badge
        };

        void forward(const std::vector<launcher::Update>& updates);
        // What the Book said about one of `sender`'s updates (forwarded lines, penalties, the log).
        void handled(const QString& sender, const launcher::Book::Result& r);
        void dropPeer(const QString& sender);
        void resolve(const QString& sender);
        void gone(const QString& sender);
        void flush();
        void malformed(const QString& sender);

        QDBusConnection          m_bus;
        Hooks                    m_hooks;
        QDBusServiceWatcher      m_watcher;
        QTimer                   m_flush;
        QElapsedTimer            m_clock;
        launcher::Book           m_book;
        QHash<QString, Peer>     m_peers;
        bool                     m_started = false;
    };

} // namespace gf::menubridge
