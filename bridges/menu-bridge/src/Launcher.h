#pragma once

// com.canonical.Unity.LauncherEntry `Update(s app_uri, a{sv} properties)`: badge, progress and urgent hint an
// application sets on its own Dock tile (ADR-0018, docs/specs/menu-bridge.md "LauncherEntry"). Pure logic (QtCore
// only), unit-tested in tests/unit/menu-bridge/. Every client of the bus may emit the signal: nothing is trusted.
//
// Validation:
//  - app_uri is "application://" + an id of 1..kMaxIdBytes bytes of [A-Za-z0-9._-] + ".desktop"; the id (without the
//    suffix) names the app. Anything else is malformed.
//  - count (type x) is clamped to 0..kMaxCount, progress (type d) must be finite and is clamped to 0..1, count-visible,
//    progress-visible and urgent are booleans (b). A property of another type is dropped (the update goes on without
//    it); it counts as malformed input. Unknown properties (quicklist...) are ignored.
//  - count-visible:false is forwarded as count 0, progress-visible:false as progress -1 ("hide").
// Limits: at most kMaxApps apps tracked, at most kMaxPerSecond updates per second per sender (an excess update is not
// forwarded at once: the last properties per app win and go out as soon as the sender's budget allows, "coalescing"),
// and an app's entry is cleared when the sender that last updated it leaves the bus.
// Senders (B-16): at most kMaxSenders; past it a new sender takes the place of a refused one, else of the least recently
// heard sender that holds no app; it is dropped only when every sender holds one. At most kMaxSendersPerIdentity senders
// and kMaxAppsPerIdentity apps per identity (Penalties.h): one process, or copies of one executable, cannot fill the book.
// Whose badge (B-17): a sender the bridge identifies (awaitIdentity, then setIdentity) may only set the badge of its own
// application when its identity is in a systemd app scope (mayUpdate); its updates wait (kMaxEarly, the last per uri)
// until the identity is known. An update for another application is dropped without a penalty (an application started
// from a terminal runs in the terminal's scope).
//
// Forwarded values (Update): nullopt = this update said nothing about it. An Update with every value nullopt means
// "forget this app" (its sender left): the shell falls back to the notification-derived badge.

#include <QHash>
#include <QList>
#include <QString>
#include <QVariantMap>

#include <deque>
#include <optional>
#include <vector>

namespace gf::menubridge::launcher {

    inline constexpr int    kMaxIdBytes    = 255;
    inline constexpr int    kMaxApps       = 64;
    inline constexpr int    kMaxPerSecond  = 20;
    inline constexpr int    kMaxSenders    = 64;
    inline constexpr int    kMaxProperties = 32; // entries of one a{sv} (more is malformed)
    inline constexpr qint64 kMaxCount      = 99999;
    inline constexpr qint64 kWindowMs      = 1000;
    inline constexpr int    kMaxSendersPerIdentity = 8;
    inline constexpr int    kMaxAppsPerIdentity    = 8;
    inline constexpr int    kMaxEarly              = 8; // updates kept per sender until its identity is known

    // B-17: may the identity `identity` (Penalties.h identityFrom) set the badge of desktop id `app`? An identity in a systemd
    // app scope only its own application's: the scope's application id (launcher part and systemd's \xNN escapes undone) or
    // its executable's file name is the desktop id, or the last part of a reverse-DNS id, without regard to case. An identity
    // without a scope (or the shared unknown bucket) may set any: nothing tells which application it is.
    bool mayUpdate(const QString& identity, const QString& app);

    // "application://<id>.desktop" -> id, nullopt when it is not exactly that.
    std::optional<QString> appFromUri(const QString& uri);

    // The properties of one update, as the application sent them (valid types only).
    struct Properties {
        std::optional<qint64> count;
        std::optional<bool>   countVisible;
        std::optional<double> progress;
        std::optional<bool>   progressVisible;
        std::optional<bool>   urgent;

        bool empty() const {
            return !count && !countVisible && !progress && !progressVisible && !urgent;
        }
        // Later values win.
        void merge(const Properties& later);
    };

    struct Parsed {
        bool       valid = false; // the uri is acceptable
        QString    app;
        Properties properties;
        bool       dropped = false; // a property of a wrong type (or too many properties) was dropped
    };
    Parsed parse(const QString& uri, const QVariantMap& properties);

    // What the shell is told (launcher message of menu/1).
    struct Update {
        QString               app;
        std::optional<qint64> count;    // 0: hide the badge
        std::optional<double> progress; // -1: hide the bar
        std::optional<bool>   urgent;

        bool forget() const {
            return !count && !progress && !urgent;
        }
        bool operator==(const Update&) const = default;
    };

    class Book {
      public:
        struct Result {
            std::vector<Update> forward;           // to send now
            bool                malformed = false; // a penalty for the sender
            bool                throttled = false; // coalesced instead of forwarded at once
            bool                dropped   = false; // not tracked: a limit (apps, senders), a refused sender, another app's badge
            bool                foreign   = false; // dropped: the sender may not set that app's badge (mayUpdate)
            bool                waiting   = false; // kept until the sender's identity is known
            QString             evicted;           // a sender that gave its place to this one (its watch can go)
        };

        // One signal from `sender` (a unique bus name) at `nowMs` (any monotonic clock, in ms).
        Result              submit(const QString& sender, const QString& uri, const QVariantMap& properties, qint64 nowMs);
        // `sender` will be identified (setIdentity): its updates wait until then. A sender never awaited has no identity and
        // no badge restriction (the pure tests, and senders the bridge could not identify).
        // False when there is no room for a new sender (every sender holds an app); *evicted names a sender whose place it took.
        bool                awaitIdentity(const QString& sender, QString* evicted);
        // The identity of `sender` is known: past kMaxSendersPerIdentity it is refused (its updates dropped from now on);
        // otherwise the updates that waited are applied (the result as for submit), or dropped with `applyEarly` false.
        Result              setIdentity(const QString& sender, const QString& identity, qint64 nowMs, bool applyEarly = true);
        // Coalesced updates whose sender has budget again.
        std::vector<Update> flush(qint64 nowMs);
        bool                hasPending() const;
        // The sender left the bus: "forget" updates for the apps it owned.
        std::vector<Update> senderGone(const QString& sender);
        // The current state of every app (for a shell that connects later), sorted by app.
        std::vector<Update> snapshot() const;
        int                 apps() const {
            return static_cast<int>(m_apps.size());
        }
        int                 senders() const {
            return static_cast<int>(m_senders.size());
        }

      private:
        struct Entry {
            QString               owner;
            std::optional<qint64> rawCount;
            bool                  countVisible = true;
            std::optional<double> rawProgress;
            bool                  progressVisible = true;
            std::optional<bool>   urgent;
            bool                  hasState = false; // something was forwarded for this app
            Properties            pending;          // coalesced, not forwarded yet
        };
        struct Early {
            QString     uri;
            QVariantMap properties;
        };
        struct Sender {
            std::deque<qint64> times; // forwarding slots used within the last kWindowMs
            qint64             lastMs   = 0;
            bool               awaiting = false; // identity asked, not known yet
            bool               refused  = false; // over kMaxSendersPerIdentity
            QString            identity;         // empty: none (no restriction)
            QList<Early>       early;            // updates waiting for the identity
        };

        static Update apply(const QString& app, Entry& e, const Properties& p);
        static bool   take(Sender& s, qint64 nowMs);
        Result        handle(const QString& sender, Sender& s, const QString& uri, const QVariantMap& properties, qint64 nowMs);
        int           appsOf(const QString& identity) const;
        // Frees one sender's place (a refused sender, else the least recently heard one holding no app); its name, or empty.
        QString       evictOne();

        QHash<QString, Entry>  m_apps;
        QHash<QString, Sender> m_senders;
    };

} // namespace gf::menubridge::launcher
