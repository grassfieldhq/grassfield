#pragma once

// The secret requests outstanding at the shell (ADR-0035 D-9: at most 8), and the applications' requests waiting for one of
// those places (owner decision 2026-11-22, B-05 amended: queued, as the stock gcr prompter and macOS do, instead of being
// cancelled). A request is reserved when a caller performs a prompt and released when the shell answers it, the caller
// withdraws it or the shell goes away; a waiting request holds no place, is never sent to the shell and is released the
// same way, or when its time to wait runs out. Ids are "p<N>", N counting from 1 for the bridge's lifetime and never
// reused (a waiting request takes its number when it arrives), so an answer to a request that is gone can never reach a
// newer one. Pure logic (QtCore only), unit-tested in tests/unit/prompter/.

#include <QHash>
#include <QString>
#include <QStringList>

namespace gf::prompter {

    // Who asks (B-05): the session's own applications (gcr prompts, KIO) share what the system's daemons do not keep for
    // themselves. NetworkManager and BlueZ each keep kReservedNm / kReservedBluetooth of the slots, so one application that
    // opens prompts and leaves them can never make a Wi-Fi password or a pairing answer "no"; one application connection
    // holds at most kPerCaller requests.
    enum class Lane { Keyring, Kio, Nm, Bluetooth };
    inline constexpr int kReservedNm        = 2;
    inline constexpr int kReservedBluetooth = 2;
    inline constexpr int kPerCaller         = 2;

    // The applications' queue (B-05 amended, owner decision 2026-11-22). An application request (lanes Keyring and Kio)
    // past its share waits for a place: at most kWaiting in all and kWaitingPerCaller for one caller (a bus connection;
    // gnome-keyring asks over one connection for every application, so its share of open gcr prompts, 8, fits: 2 shown + 6
    // waiting); beyond either bound it is refused at once (fail closed). A waiting request waits at most kWaitMs (the
    // bridge's longest answer time, NetworkManager's 110 s), then is refused. NetworkManager's and BlueZ's requests never
    // wait: their reserved places are untouched by the queue (a waiting request holds none).
    inline constexpr int kWaiting          = 16;
    inline constexpr int kWaitingPerCaller = 6;
    inline constexpr int kWaitMs           = 110000;
    inline constexpr bool waits(Lane lane) {
        return lane == Lane::Keyring || lane == Lane::Kio;
    }

    // What admit() decided: a place now (id, waiting false), a turn in the queue (id, waiting true), or refused (no id).
    struct Admission {
        QString id;
        bool    waiting = false;
    };

    class RequestBook {
      public:
        explicit RequestBook(int capacity, int waitingCap = kWaiting, int waitingPerCaller = kWaitingPerCaller);

        // A place now for `owner` (one request per owner at a time); empty when `capacity` requests are outstanding, when
        // the slots left are the ones kept for the other lanes, when `caller` (a bus name, empty when not known) already
        // holds kPerCaller requests, or when `owner` already has one. Never waits.
        QString     reserve(const void* owner, Lane lane, const QString& caller = QString());
        // A place now, as reserve(); else, for lanes Keyring and Kio only, a turn in the queue until `deadline` (on the
        // caller's clock, see expire()), unless kWaiting requests wait already or `caller` has kWaitingPerCaller waiting.
        Admission   admit(const void* owner, Lane lane, const QString& caller, qint64 deadline);
        // The owner of `id` (outstanding or waiting), nullptr when the id is not known.
        const void* owner(const QString& id) const;
        // The id of `owner` (outstanding or waiting), empty when it has none.
        QString     idOf(const void* owner) const;
        // False when `id` was not known. A place freed goes at once to the waiting requests that fit (fair order: the
        // caller whose turn is the oldest first, then the oldest request; a caller's turn is its last promotion, or the
        // moment it began to wait when it has none: a new caller ranks after those already waiting), see takePromoted().
        bool        release(const QString& id);
        // True while `id` waits for a place.
        bool        isWaiting(const QString& id) const;
        // The ids given a place since the last call, in the order they got it: the bridge sends them to the shell now.
        QStringList takePromoted();
        bool        hasPromoted() const {
            return !m_promoted.isEmpty();
        }
        // The waiting requests whose deadline is `now` or earlier, removed (oldest first): the bridge refuses them.
        QStringList expire(qint64 now);
        // The earliest deadline of a waiting request, -1 when none waits.
        qint64      nextDeadline() const;

        // Requests holding a place.
        int count() const {
            return m_outstanding;
        }
        // Requests waiting for one.
        int waiting() const {
            return static_cast<int>(m_entries.size()) - m_outstanding;
        }
        int waitingOf(const QString& caller) const;
        int capacity() const {
            return m_capacity;
        }
        // Outstanding and waiting ids, oldest first.
        QStringList ids() const;
        // Waiting ids, oldest first.
        QStringList waitingIds() const;

      private:
        struct Entry {
            const void* owner    = nullptr;
            quint64     serial   = 0;
            Lane        lane     = Lane::Keyring;
            QString     caller;          // empty when not known
            bool        waiting  = false;
            qint64      deadline = 0;    // while waiting
        };

        // A place for a new request of `lane` from `caller` now.
        bool    fits(Lane lane, const QString& caller) const;
        QString add(const void* owner, Lane lane, const QString& caller, bool waiting, qint64 deadline);
        void    remove(const QString& id);
        void    promote();
        QStringList sorted(bool waitingOnly) const;

        int                         m_capacity;
        int                         m_waitingCap;
        int                         m_waitingPerCaller;
        quint64                     m_next        = 1;
        int                         m_outstanding = 0;
        quint64                     m_turn        = 0;
        QHash<QString, Entry>       m_entries;  // id -> request
        QHash<const void*, QString> m_byOwner;
        QHash<QString, quint64>     m_served;   // caller -> its turn (last promotion, or when it began to wait), while it has a request here
        QStringList                 m_promoted; // given a place, not yet taken by the bridge
    };

} // namespace gf::prompter
