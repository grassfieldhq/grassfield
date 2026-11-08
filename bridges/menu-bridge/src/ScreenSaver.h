#pragma once

// org.freedesktop.ScreenSaver idle inhibitors (GF-AUDIT-001 GF-016 residual; ADR-0008 and ADR-0010 amendments
// 2026-10-24). Quickshell 0.3.1 cannot own a D-Bus name or serve methods, so this bridge, already a session-bus service,
// serves the two calls applications make while they play video or present (VLC, Chromium and Electron apps, Steam, the
// GTK portal's Inhibit backend): Inhibit(application, reason) -> cookie and UnInhibit(cookie). It keeps the cookies per
// sender (a cookie is released only by the connection that took it, or when that connection leaves the bus) and tells
// grassfield-shell ONE boolean (menu/1 "screensaver" line): while it is true the shell's idle module neither dims nor
// locks on idle (macOS: a power assertion such as "prevent display sleep" while a video plays). Nothing else is served:
// Lock, SetActive, GetActive, SimulateUserActivity and the other methods of the interface answer NotSupported (a member
// the interface does not have: UnknownMethod; every other call is answered too, DBusObjects.h); a manual lock, the lid, the lock
// before sleep and the display power-off on the lock screen are never affected. A bridge that dies drops the boolean
// in the shell (its socket closes): idle locking works again (fail closed).
//
// Book and handle() are pure (QtCore only), unit-tested in tests/unit/menu-bridge/tst_screensaver.cpp.

#include <QDBusVirtualObject>
#include <QHash>
#include <QString>
#include <QStringList>
#include <QVariantList>

#include <functional>

class QDBusServiceWatcher;

namespace gf::menubridge::screensaver {

    inline constexpr char kService[]    = "org.freedesktop.ScreenSaver";
    inline constexpr char kInterface[]  = "org.freedesktop.ScreenSaver";
    inline constexpr char kPath[]       = "/org/freedesktop/ScreenSaver";
    inline constexpr char kLegacyPath[] = "/ScreenSaver"; // the path KDE and many applications use
    inline constexpr int  kMaxPerSender = 16;              // cookies one connection may hold
    inline constexpr int  kMaxSenders   = 64;              // connections holding cookies
    inline constexpr int  kMaxText      = 64;              // characters of an application name kept (logs only)
    // The screensaver line is repeated this often while a shell is connected; the shell drops "inhibited" after three
    // missed beats (shell/platform/MenuBridge.js limits.screensaverStaleMs), so a hung bridge cannot hold the idle lock off.
    inline constexpr int  kHeartbeatMs  = 20000;

    // Cookies by sender. Every change of active() is reported by the caller.
    class Book {
      public:
        struct Taken {
            bool    ok     = false;
            quint32 cookie = 0;
            QString error; // D-Bus error name when !ok
        };

        // A new cookie for `sender` (a unique bus name). Refused past the per-sender or sender caps.
        Taken   inhibit(const QString& sender, const QString& application);
        // Releases `cookie` if `sender` holds it; true when it did. Another sender's cookie is left alone.
        bool    uninhibit(const QString& sender, quint32 cookie);
        // Releases every cookie of `sender` (it left the bus); true when it held any.
        bool    senderGone(const QString& sender);
        bool    holds(const QString& sender) const;

        bool    active() const {
            return !m_entries.isEmpty();
        }
        int     count() const {
            return static_cast<int>(m_entries.size());
        }
        // Distinct application names holding cookies, sorted (for the log line on a change).
        QStringList applications() const;

      private:
        struct Entry {
            QString sender;
            QString application;
        };
        QHash<quint32, Entry> m_entries;
        QHash<QString, int>   m_perSender;
        quint32               m_next = 0; // 0: not seeded yet
    };

    // What to do with one call on the org.freedesktop.ScreenSaver interface.
    struct Answer {
        enum class Kind {
            Reply, // send a reply with `values`
            Error, // send an error reply
        };
        Kind         kind = Kind::Error;
        QVariantList values;
        QString      error;
        QString      message;
        bool         changed = false; // the book's active() may have changed (report it)
    };

    // Pure: Inhibit(ss) -> u, UnInhibit(u) -> (), the other ScreenSaver methods NotSupported, any other member UnknownMethod, a wrong signature InvalidArgs, a sender
    // without a unique name AccessDenied.
    Answer handle(Book& book, const QString& member, const QString& signature, const QVariantList& args, const QString& sender);

    // The <interface> element served for introspection (the two methods only).
    QString interfaceXml();

    // The D-Bus object (both paths). `changed(active, count, applications)` runs after every change of active() and when
    // the set of applications changes while active.
    class ScreenSaverObject : public QDBusVirtualObject {
      public:
        using Changed = std::function<void(bool active, int count, const QStringList& applications)>;

        explicit ScreenSaverObject(Changed changed);
        ~ScreenSaverObject() override;

        // Attaches the sender watcher to `connection` (call once, before the object is registered).
        void    setConnection(const QDBusConnection& connection);
        QString introspect(const QString& path) const override;
        bool    handleMessage(const QDBusMessage& message, const QDBusConnection& connection) override;

        const Book& book() const {
            return m_book;
        }

      private:
        static constexpr int kConfirmTimeoutMs = 2000;

        void report();
        // Asks the bus whether `sender` still owns its unique name (after its watch was added); drops it when not.
        void confirmPresent(const QDBusConnection& connection, const QString& sender);
        void dropSender(const QString& sender);

        Book                 m_book;
        Changed              m_changed;
        QDBusServiceWatcher* m_watcher = nullptr;
        QStringList          m_reported; // applications at the last report
        bool                 m_reportedActive = false;
    };

} // namespace gf::menubridge::screensaver
