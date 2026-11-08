#pragma once

// com.canonical.AppMenu.Registrar registrations (ADR-0008 amendment 2026-10-25, docs/specs/menu-bridge.md MB2, MB17).
//
// Electron exports its menu (libdbusmenu-glib) when the compositor advertises org_kde_kwin_appmenu_manager, but announces
// it with RegisterWindow(u windowId, o "/com/canonical/menu/<windowId hex>") on window Show (UnregisterWindow on Hide),
// never with org_kde_kwin_appmenu.set_address. On Wayland windowId is Electron's per-process window counter (1, 2, ...),
// which nothing outside the process can map to a window. So a registration is kept for its SENDER (a unique bus name);
// the bridge serves it to the Wayland windows of the sender's process (the plugin reports each window's client pid), the
// latest registration of that process winning. X11 clients may register too: they are kept like any sender and never
// served (the plugin reports no pid for X11/XWayland windows).
//
// Electron registers a window before its DBusMenu object answers (measured in the nested session: Obsidian's second
// window, GetLayout right after RegisterWindow -> org.freedesktop.DBus.Error.UnknownMethod, which counts as a layout
// failure and backs the application off; the same call seconds later -> the layout). So a registration is served only once
// settled: the registrar object settles it kSettleMs after it arrived. kSettleMs is an estimate and the only wait: nothing
// is retried in a loop. A menu object still not answering after it gets the ordinary layout failure path (MB14,
// Penalties.h): the window shows T0 menus, the application is refused for 2 s (doubling on each repeat, at most 64 s, and
// ended by the next menu it delivers), and its menus come back at the window's next open once that back-off is over.
//
// Book and handle() are pure (QtCore and QtDBus types only), unit-tested in tests/unit/menu-bridge/tst_menubridge.cpp.

#include <QHash>
#include <QList>
#include <QString>
#include <QVariantList>

#include <optional>

namespace gf::menubridge::registrar {

    inline constexpr int kMaxPerSender = 16;  // registrations one connection may hold
    inline constexpr int kMaxTotal     = 128; // registrations in all (no eviction: past it, LimitsExceeded)
    inline constexpr int kSettleMs     = 300; // estimate: a registration is served this long after it arrived

    struct Registration {
        QString sender;        // unique bus name of the registering connection
        quint32 windowId = 0;  // the application's own window id (meaningless outside its process on Wayland)
        QString path;          // its DBusMenu object path
        quint64 seq     = 0;   // order of registration (higher: newer)
        bool    settled = false; // served from now on (settle())
    };

    class Book {
      public:
        // Keeps (sender, windowId) -> path, not settled yet; the same pair is replaced and becomes the newest. Returns the
        // registration's seq (> 0), 0 past the caps.
        quint64                     add(const QString& sender, quint32 windowId, const QString& path);
        // Settles (sender, windowId) if it is still the registration numbered `seq`; true when that changed something.
        bool                        settle(const QString& sender, quint32 windowId, quint64 seq);
        // Removes (sender, windowId); true when it was kept.
        bool                        remove(const QString& sender, quint32 windowId);
        // Removes every registration of `sender` (it left the bus) and its pid; true when it held any.
        bool                        senderGone(const QString& sender);
        // The sender's process, once the bus daemon told it (> 0).
        void                        setPid(const QString& sender, qint64 pid);
        qint64                      pidOf(const QString& sender) const; // 0 when not known
        bool                        holds(const QString& sender) const;
        // The newest settled registration of a sender whose process is `pid` (> 0), if any.
        std::optional<Registration> latestFor(qint64 pid) const;
        int                         count() const {
            return static_cast<int>(m_entries.size());
        }
        void clear();

      private:
        QList<Registration>    m_entries;
        QHash<QString, qint64> m_pids;
        quint64                m_seq = 0;
    };

    // What to do with one call on the registrar object.
    struct Answer {
        enum class Kind {
            Reply, // an empty reply (RegisterWindow, UnregisterWindow done)
            Error, // an error reply
        };
        Kind    kind = Kind::Error;
        QString error;
        QString message;
        bool    added   = false; // a registration was kept (a new sender is watched and its pid asked; settle it later)
        bool    removed = false; // a registration went away
        quint32 windowId = 0;    // the registration kept (added): what to settle
        quint64 seq      = 0;
    };

    // Pure: RegisterWindow(uo) -> () kept (LimitsExceeded past the caps, InvalidArgs for a bad path or signature),
    // UnregisterWindow(u) -> (), GetMenuForWindow(u) -> NotFound (nobody can look a registration up), GetMenus() ->
    // NotSupported, any other member: UnknownMethod. `sender` must be a unique name (a well-known one: InvalidArgs).
    Answer handle(Book& book, const QString& member, const QString& signature, const QVariantList& args, const QString& sender);

} // namespace gf::menubridge::registrar
