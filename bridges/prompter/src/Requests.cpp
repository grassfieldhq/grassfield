#include "Requests.h"

#include <algorithm>
#include <utility>
#include <vector>

namespace gf::prompter {

    RequestBook::RequestBook(int capacity, int waitingCap, int waitingPerCaller)
        : m_capacity(capacity), m_waitingCap(waitingCap), m_waitingPerCaller(waitingPerCaller) {}

    bool RequestBook::fits(Lane lane, const QString& caller) const {
        if (m_outstanding >= m_capacity)
            return false;
        // The slots kept for the other lanes and not used by them stay free.
        int nm = 0, bt = 0, mine = 0;
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
            if (it->waiting)
                continue;
            nm += it->lane == Lane::Nm ? 1 : 0;
            bt += it->lane == Lane::Bluetooth ? 1 : 0;
            mine += !caller.isEmpty() && it->caller == caller ? 1 : 0;
        }
        int kept = 0;
        if (lane != Lane::Nm)
            kept += std::max(0, kReservedNm - nm);
        if (lane != Lane::Bluetooth)
            kept += std::max(0, kReservedBluetooth - bt);
        if (m_capacity - m_outstanding - 1 < kept)
            return false;
        return mine < kPerCaller;
    }

    QString RequestBook::add(const void* owner, Lane lane, const QString& caller, bool waiting, qint64 deadline) {
        const quint64 n  = m_next++;
        const QString id = QStringLiteral("p%1").arg(n);
        m_entries.insert(id, Entry{owner, n, lane, caller, waiting, waiting ? deadline : 0});
        m_byOwner.insert(owner, id);
        if (!waiting)
            ++m_outstanding;
        return id;
    }

    QString RequestBook::reserve(const void* owner, Lane lane, const QString& caller) {
        if (!owner || m_byOwner.contains(owner) || !fits(lane, caller))
            return {};
        return add(owner, lane, caller, false, 0);
    }

    Admission RequestBook::admit(const void* owner, Lane lane, const QString& caller, qint64 deadline) {
        if (!owner || m_byOwner.contains(owner))
            return {};
        // No waiting request fits a place (release() hands every place that frees to them at once), so a new request that
        // fits takes it without passing any of them.
        if (fits(lane, caller))
            return {add(owner, lane, caller, false, 0), false};
        if (!waits(lane) || waiting() >= m_waitingCap || waitingOf(caller) >= m_waitingPerCaller)
            return {};
        return {add(owner, lane, caller, true, deadline), true};
    }

    const void* RequestBook::owner(const QString& id) const {
        const auto it = m_entries.constFind(id);
        return it == m_entries.constEnd() ? nullptr : it->owner;
    }

    QString RequestBook::idOf(const void* owner) const {
        return m_byOwner.value(owner);
    }

    bool RequestBook::isWaiting(const QString& id) const {
        const auto it = m_entries.constFind(id);
        return it != m_entries.constEnd() && it->waiting;
    }

    int RequestBook::waitingOf(const QString& caller) const {
        int n = 0;
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it)
            n += it->waiting && it->caller == caller ? 1 : 0;
        return n;
    }

    void RequestBook::remove(const QString& id) {
        const auto it = m_entries.find(id);
        if (it == m_entries.end())
            return;
        const QString caller = it->caller;
        if (!it->waiting)
            --m_outstanding;
        m_byOwner.remove(it->owner);
        m_entries.erase(it);
        m_promoted.removeAll(id);
        // A caller's turn is remembered while it has a request here: one that waits again right after its turn (it still
        // holds the place it got) cannot pass the others as if it had never been served.
        bool left = false;
        for (auto e = m_entries.cbegin(); e != m_entries.cend() && !left; ++e)
            left = e->caller == caller;
        if (!left)
            m_served.remove(caller);
    }

    bool RequestBook::release(const QString& id) {
        const auto it = m_entries.constFind(id);
        if (it == m_entries.constEnd())
            return false;
        const bool freed = !it->waiting;
        remove(id);
        if (freed)
            promote();
        return true;
    }

    void RequestBook::promote() {
        while (true) {
            // Among the waiting requests that fit: the caller served least recently (never: 0), then the oldest request.
            QString best;
            quint64 bestServed = 0, bestSerial = 0;
            for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
                if (!it->waiting || !fits(it->lane, it->caller))
                    continue;
                const quint64 served = m_served.value(it->caller, 0);
                if (best.isEmpty() || served < bestServed || (served == bestServed && it->serial < bestSerial)) {
                    best       = it.key();
                    bestServed = served;
                    bestSerial = it->serial;
                }
            }
            if (best.isEmpty())
                return;
            Entry& e   = m_entries[best];
            e.waiting  = false;
            e.deadline = 0;
            ++m_outstanding;
            m_served.insert(e.caller, ++m_turn);
            m_promoted.append(best);
        }
    }

    QStringList RequestBook::takePromoted() {
        return std::exchange(m_promoted, {});
    }

    QStringList RequestBook::expire(qint64 now) {
        QStringList out;
        for (const QString& id : waitingIds()) {
            if (m_entries.value(id).deadline <= now)
                out.append(id);
        }
        for (const QString& id : std::as_const(out))
            remove(id); // a waiting request holds no place: nothing to promote
        return out;
    }

    qint64 RequestBook::nextDeadline() const {
        qint64 next = -1;
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
            if (it->waiting && (next < 0 || it->deadline < next))
                next = it->deadline;
        }
        return next;
    }

    QStringList RequestBook::sorted(bool waitingOnly) const {
        std::vector<std::pair<quint64, QString>> list;
        list.reserve(static_cast<std::size_t>(m_entries.size()));
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
            if (!waitingOnly || it->waiting)
                list.emplace_back(it->serial, it.key());
        }
        std::sort(list.begin(), list.end());
        QStringList out;
        for (const auto& [n, id] : list)
            out.append(id);
        return out;
    }

    QStringList RequestBook::ids() const {
        return sorted(false);
    }

    QStringList RequestBook::waitingIds() const {
        return sorted(true);
    }

} // namespace gf::prompter
