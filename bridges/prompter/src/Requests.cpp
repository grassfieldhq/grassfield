#include "Requests.h"

#include <algorithm>
#include <utility>
#include <vector>

namespace gf::prompter {

    RequestBook::RequestBook(int capacity) : m_capacity(capacity) {}

    QString RequestBook::reserve(const void* owner, Lane lane, const QString& caller) {
        if (!owner || m_byOwner.contains(owner) || m_byId.size() >= m_capacity)
            return {};
        // The slots kept for the other lanes and not used by them stay free.
        int nm = 0, bt = 0, mine = 0;
        for (auto it = m_lane.cbegin(); it != m_lane.cend(); ++it) {
            nm += it.value() == Lane::Nm ? 1 : 0;
            bt += it.value() == Lane::Bluetooth ? 1 : 0;
            mine += !caller.isEmpty() && m_caller.value(it.key()) == caller ? 1 : 0;
        }
        int kept = 0;
        if (lane != Lane::Nm)
            kept += std::max(0, kReservedNm - nm);
        if (lane != Lane::Bluetooth)
            kept += std::max(0, kReservedBluetooth - bt);
        if (m_capacity - static_cast<int>(m_byId.size()) - 1 < kept)
            return {};
        if (mine >= kPerCaller)
            return {};
        const quint64 n  = m_next++;
        const QString id = QStringLiteral("p%1").arg(n);
        m_byId.insert(id, owner);
        m_byOwner.insert(owner, id);
        m_serial.insert(id, n);
        m_lane.insert(id, lane);
        if (!caller.isEmpty())
            m_caller.insert(id, caller);
        return id;
    }

    const void* RequestBook::owner(const QString& id) const {
        return m_byId.value(id, nullptr);
    }

    QString RequestBook::idOf(const void* owner) const {
        return m_byOwner.value(owner);
    }

    bool RequestBook::release(const QString& id) {
        const auto it = m_byId.constFind(id);
        if (it == m_byId.constEnd())
            return false;
        m_byOwner.remove(it.value());
        m_serial.remove(id);
        m_lane.remove(id);
        m_caller.remove(id);
        m_byId.erase(it);
        return true;
    }

    QStringList RequestBook::ids() const {
        std::vector<std::pair<quint64, QString>> sorted;
        sorted.reserve(static_cast<std::size_t>(m_serial.size()));
        for (auto it = m_serial.constBegin(); it != m_serial.constEnd(); ++it)
            sorted.emplace_back(it.value(), it.key());
        std::sort(sorted.begin(), sorted.end());
        QStringList out;
        for (const auto& [n, id] : sorted)
            out.append(id);
        return out;
    }

} // namespace gf::prompter
