#pragma once

// The secret requests outstanding at the shell (ADR-0035 D-9: at most 8; beyond, a request is answered "cancelled").
// A request is reserved when a caller performs a prompt and released when the shell answers it, the caller withdraws
// it or the shell goes away. Ids are "p<N>", N counting from 1 for the bridge's lifetime and never reused, so an answer
// to a request that is gone can never reach a newer one. Pure logic (QtCore only), unit-tested in tests/unit/prompter/.

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

    class RequestBook {
      public:
        explicit RequestBook(int capacity);

        // A new id for `owner` (one request per owner at a time); empty when `capacity` requests are outstanding, when the
        // slots left are the ones kept for the other lanes, when `caller` (a bus name, empty when not known) already holds
        // kPerCaller requests, or when `owner` already has one.
        QString     reserve(const void* owner, Lane lane, const QString& caller = QString());
        // The owner of `id`, nullptr when the id is not outstanding.
        const void* owner(const QString& id) const;
        // The outstanding id of `owner`, empty when it has none.
        QString     idOf(const void* owner) const;
        // False when `id` was not outstanding.
        bool        release(const QString& id);
        int         count() const {
            return static_cast<int>(m_byId.size());
        }
        int capacity() const {
            return m_capacity;
        }
        // Outstanding ids, oldest first.
        QStringList ids() const;

      private:
        int                           m_capacity;
        quint64                       m_next = 1;
        QHash<QString, const void*>   m_byId;
        QHash<const void*, QString>   m_byOwner;
        QHash<QString, quint64>       m_serial; // id -> its number, for ids()
        QHash<QString, Lane>          m_lane;   // id -> its lane
        QHash<QString, QString>       m_caller; // id -> its caller (when known)
    };

} // namespace gf::prompter
