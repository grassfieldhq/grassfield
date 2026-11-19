#pragma once

// Hostile or broken applications (a huge GetLayout reply costs the bridge several times its size in memory) and the
// state that survives a bridge restart (ADR-0008, docs/specs/menu-bridge.md MB14).
//
// Attribution is correct where possible and never blames an innocent application:
//  - EVERY crash counts toward the degradation budget, blamed or not: kMaxCrashes within any sliding window of
//    kCrashWindowSec make the bridge give up (it stops owning the registrar, the shell shows T0 menus).
//  - A crash is additionally blamed on an identity ONLY when the previous run died with exactly one outbound call in
//    flight, to one identity, and that call was fresh (kFreshCallMs). Anything else (several calls, none, a stale
//    call: the crash came from unsolicited traffic or from someone else's message) is "unattributed": it only
//    counts, it penalises nobody. Blame is a per-identity refusal on top of the count.
//  - An application is identified by what the bridge observed after the pid check: the systemd app scope of the pid
//    (instance suffix stripped, flatpak id included), the resolved /proc/<pid>/exe and, for interpreters, the script.
//    An unreadable exe (non-dumpable process, other user) or an interpreter command line the bridge cannot parse with
//    certainty puts the peer into ONE shared bucket "unknown", which is refused only for kUnknownDenySec and never
//    doubles, so innocents behind it recover. A pid is never a key.
//
// Offences: LayoutFailed (short back-off, 2^n s up to 64 s), Flood (an application that re-announces its menu faster
// than RefetchBudget allows for penalty::kFloodMs: refused kFloodBaseSec, doubling per flood up to kFloodMaxSec, not
// ended by a delivery, not written to the state file), Oversized and Crash (blamed as above): refused for
// 15 min, doubling per strike up to 6 h. A clean exit does not clear the doubling inside the decay window: an entry is
// dropped after 24 h without a new strike. Refused entries are not evicted by idle churn, but at most kMaxRefused are
// kept: past that the refusal closest to its expiry goes (capRefused). Idle entries (not refused) are bounded
// separately (least recently used first out).
//
// The state file `<socket>.state` mirrors whether the bridge is running ("run"), the calls in flight with their age
// ("inflight"), the crash times ("crash") and the refusals ("deny"). It lives in the socket's directory (mode 0700,
// owned by the user): only code running as the same user can write it, which can equally kill the bridge or pass the
// pid check for its own processes. It is written atomically (openat O_EXCL|O_NOFOLLOW temp file + renameat in the
// directory), read without following symlinks, size-bounded and fully validated.

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>

#include <functional>

namespace gf::menubridge {

    namespace penalty {
        inline constexpr int       kMaxIdle        = 128;          // identities remembered without an active refusal (LRU)
        inline constexpr int       kMaxRefused     = 64;           // identities refused right now (never evicted early)
        inline constexpr qint64    kLayoutMaxSec   = 64;           // LayoutFailed back-off cap
        inline constexpr qint64    kDenyBaseSec    = 15 * 60;      // first Oversized/Crash refusal
        inline constexpr qint64    kDenyMaxSec     = 6 * 60 * 60;  // cap of the doubling
        inline constexpr qint64    kUnknownDenySec = 2 * 60;       // the shared "unknown" bucket: short, never doubles
        inline constexpr qint64    kForgiveSec     = 24 * 60 * 60; // no strike for this long: forgotten
        inline constexpr qsizetype kMaxStateBytes  = 128 * 1024;   // larger files are refused
        inline constexpr qsizetype kMaxIdentity    = 512;          // characters of an identity
        // A call is blamed for a crash only while it is younger than this at the last state write (the state is
        // refreshed every kHeartbeatMs while calls are in flight): a slow application's call that happens to be open
        // when someone else's message kills the bridge is not blamed.
        inline constexpr qint64    kFreshCallMs    = 1000;
        inline constexpr int       kHeartbeatMs    = 250;
        // Crashes (blamed or not) that make the bridge give up within any sliding window; times kept in the state file.
        inline constexpr int       kMaxCrashes     = 5;
        inline constexpr qint64    kCrashWindowSec = 60 * 60;
        inline constexpr int       kMaxCrashesKept = 64;
        // An application that kills the bridge with a fresh single call costs one restart: the next run refuses it.
        inline constexpr int       kRestartsBeforeRefusal = 1;
        // Re-reads of a menu (LayoutUpdated / ItemsPropertiesUpdated, AboutToShow's needUpdate) per identity, all its
        // windows together: kRefetchBurst at once, then one per kRefetchRefillMs. A re-read over the budget waits for it.
        inline constexpr int       kRefetchBurst    = 4;
        inline constexpr qint64    kRefetchRefillMs = 1000;
        // Demand over the budget, with no pause of kFloodQuietMs, for kFloodMs: a flood (the menu is dropped, T0 menus).
        inline constexpr qint64    kFloodMs         = 30 * 1000;
        inline constexpr qint64    kFloodQuietMs    = 2000;
        inline constexpr qint64    kFloodBaseSec    = 60;
        inline constexpr qint64    kFloodMaxSec     = 15 * 60;
        inline constexpr int       kRefetchTracked  = 256; // identities with a budget (least recently asked first out)
    } // namespace penalty

    enum class Offence { LayoutFailed, Flood, Oversized, Crash };

    // The re-read budget of every identity (pure; the clock in ms is injected for tests).
    class RefetchBudget {
      public:
        explicit RefetchBudget(std::function<qint64()> clockMs);

        // A re-read wanted now: 0 = go (a token was taken), > 0 = wait this many ms and ask again, -1 = a sustained flood
        // (penalty::kFloodMs over the budget): the caller drops the menu and records Offence::Flood.
        qint64 ask(const QString& id);
        void   forget(const QString& id);
        qsizetype size() const {
            return m_entries.size();
        }

      private:
        struct Entry {
            double  tokens       = penalty::kRefetchBurst;
            qint64  refilledAt   = 0;
            qint64  floodStart   = -1; // first refusal of the current flood, -1 none
            qint64  lastRefusal  = 0;
            quint64 touch        = 0;
        };
        std::function<qint64()> m_clock;
        QHash<QString, Entry>   m_entries;
        quint64                 m_touch = 0;
    };

    // CLOCK_BOOTTIME in seconds (counts across suspend, same value in every bridge run of this boot).
    qint64  nowSec();
    QString bootId();

    // The one shared identity of every peer whose executable cannot be read.
    inline const QString kUnknownIdentity = QStringLiteral("unknown");
    // scriptOf's answer for interpreter options it cannot tell from the script (never a real script: it has a
    // control character, which real ones are stripped of). identityFrom turns it into kUnknownIdentity.
    inline const QString kScriptUnknown = QStringLiteral("\x01");

    // What the bridge can read about a peer process.
    struct PeerFacts {
        QString    cgroup;  // content of /proc/<pid>/cgroup
        QString    exe;     // resolved /proc/<pid>/exe, empty when unreadable
        QByteArray cmdline; // /proc/<pid>/cmdline (NUL separated), empty when unreadable
    };
    // systemd app scope of a /proc/<pid>/cgroup text with the instance stripped ("app-flatpak-org.foo.Bar"), empty
    // when the process is not in an app scope or service.
    QString appScopeOf(const QString& cgroupText);
    // Script path or module of an interpreter's command line ("python3 -I x.py" -> "x.py"), empty otherwise,
    // kScriptUnknown when an option before the script is not known (it may take a value).
    QString scriptOf(const QString& exe, const QByteArray& cmdline);
    // "id:scope=<scope>|exe=<path>|script=<script>" (scope and script only when known), or kUnknownIdentity.
    QString identityFrom(const PeerFacts& facts);
    // Reads /proc/<pid>/{exe,cgroup,cmdline}: never a pid-based key.
    QString appIdentity(qint64 pid);
    // An identity for logs only: systemd's "\x2d" escape shown as '-'. The key itself stays canonical.
    QString displayIdentity(const QString& id);
    // True for strings identityFrom can produce: kUnknownIdentity, or "id:" + a part "exe=/…" (bounded, no control chars).
    bool    validIdentity(const QString& id);

    // A call in flight as written to the state file.
    struct InflightCall {
        QString id;
        int     calls = 1;
        qint64  ageMs = 0; // age of the oldest call of this identity when the state was written
    };

    // What load() found about the previous run.
    struct CrashOutcome {
        bool    crashed = false; // the previous run did not stop cleanly
        QString culprit;         // the identity blamed (a single fresh call in flight), empty when unattributed
        int     crashes = 0;     // crashes (blamed or not) within the window, including this one
    };

    class PenaltyBook {
      public:
        explicit PenaltyBook(std::function<qint64()> clock = nowSec) : m_clock(std::move(clock)) {}

        // False with *why set while the identity is refused.
        bool refused(const QString& id, QString* why);
        void record(const QString& id, Offence what);
        // A menu was delivered: ends a LayoutFailed back-off (long refusals are not touched).
        void delivered(const QString& id);
        // The application left the bus. Does not reset the doubling inside the decay window; only a strike older than
        // kForgiveSec is forgiven.
        void leftCleanly(const QString& id);
        qsizetype size() const {
            return m_entries.size();
        }
        bool has(const QString& id) const {
            return m_entries.contains(id);
        }
        qsizetype refusedCount() const;

        // Crashes within the sliding window (decays), and the verdict "give up".
        int  crashes() const;
        bool degraded() const {
            return crashes() >= penalty::kMaxCrashes;
        }
        void recordCrash();

        // "grassfield-menu-bridge-state 3" text: header, boot id, "run 0|1", the calls in flight, one "crash" per
        // crash in the window and one "deny" per active refusal.
        QByteArray serialize(const QList<InflightCall>& inflight, const QString& boot, bool running) const;
        // Validates `data` and merges it. When the previous run was still "running" it is a crash: blamed on the
        // single fresh call in flight, if there is exactly one; it is counted either way (*out). False
        // (nothing merged, *why set) for a malformed file or one written in another boot.
        bool load(const QByteArray& data, const QString& boot, QString* why, CrashOutcome* out);

      private:
        struct Entry {
            int     layoutFailures = 0;
            int     strikes        = 0;
            int     floods         = 0;
            qint64  floodUntil     = 0;
            qint64  layoutUntil    = 0;
            qint64  denyUntil      = 0;
            qint64  lastStrike     = 0;
            quint64 touch          = 0;
        };
        Entry& entry(const QString& id);
        void   makeRoom();
        void   capRefused(const QString& keep);
        void   strike(const QString& id, Entry& e);

        std::function<qint64()> m_clock;
        QHash<QString, Entry>   m_entries;
        quint64                 m_touch          = 0;
        QList<qint64>           m_crashes;
    };

    // The state file. read: opens with O_NOFOLLOW, requires a regular file owned by this user, at most
    // penalty::kMaxStateBytes. Returns false with *why empty when the file does not exist, and *why set when it was
    // refused. write: temp file created with openat(O_CREAT|O_EXCL|O_NOFOLLOW) in the file's directory, then renameat
    // (replaces a symlink or file at the final name, never follows it).
    bool readStateFile(const QString& path, QByteArray* data, QString* why);
    bool writeStateFile(const QString& path, const QByteArray& data);

} // namespace gf::menubridge
