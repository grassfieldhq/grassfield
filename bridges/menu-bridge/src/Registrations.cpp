#include "Registrations.h"

#include "Protocol.h"

#include <QDBusObjectPath>

#include <algorithm>

namespace gf::menubridge::registrar {

    namespace {
        Answer error(const char* name, const QString& message) {
            Answer a;
            a.kind    = Answer::Kind::Error;
            a.error   = QLatin1String(name);
            a.message = message;
            return a;
        }
    } // namespace

    quint64 Book::add(const QString& sender, quint32 windowId, const QString& path) {
        const auto same = std::ranges::find_if(m_entries, [&](const Registration& r) { return r.sender == sender && r.windowId == windowId; });
        if (same != m_entries.end()) {
            same->path    = path;
            same->seq     = ++m_seq;
            same->settled = false;
            return same->seq;
        }
        const auto mine = std::ranges::count_if(m_entries, [&](const Registration& r) { return r.sender == sender; });
        if (mine >= kMaxPerSender || m_entries.size() >= kMaxTotal)
            return 0;
        m_entries.append(Registration{.sender = sender, .windowId = windowId, .path = path, .seq = ++m_seq});
        return m_seq;
    }

    bool Book::settle(const QString& sender, quint32 windowId, quint64 seq) {
        const auto it = std::ranges::find_if(m_entries, [&](const Registration& r) { return r.sender == sender && r.windowId == windowId && r.seq == seq; });
        if (it == m_entries.end() || it->settled)
            return false;
        it->settled = true;
        return true;
    }

    bool Book::remove(const QString& sender, quint32 windowId) {
        return m_entries.removeIf([&](const Registration& r) { return r.sender == sender && r.windowId == windowId; }) > 0;
    }

    bool Book::senderGone(const QString& sender) {
        m_pids.remove(sender);
        return m_entries.removeIf([&](const Registration& r) { return r.sender == sender; }) > 0;
    }

    void Book::setPid(const QString& sender, qint64 pid) {
        if (pid > 0 && holds(sender))
            m_pids.insert(sender, pid);
    }

    qint64 Book::pidOf(const QString& sender) const {
        return m_pids.value(sender, 0);
    }

    bool Book::holds(const QString& sender) const {
        return std::ranges::any_of(m_entries, [&](const Registration& r) { return r.sender == sender; });
    }

    std::optional<Registration> Book::latestFor(qint64 pid) const {
        if (pid <= 0)
            return std::nullopt;
        std::optional<Registration> best;
        for (const Registration& r : m_entries) {
            if (r.settled && m_pids.value(r.sender, 0) == pid && (!best || r.seq > best->seq))
                best = r;
        }
        return best;
    }

    void Book::clear() {
        m_entries.clear();
        m_pids.clear();
    }

    Answer handle(Book& book, const QString& member, const QString& signature, const QVariantList& args, const QString& sender) {
        if (member == QLatin1String("RegisterWindow")) {
            if (signature != QLatin1String("uo") || args.size() != 2 || !sender.startsWith(u':'))
                return error("org.freedesktop.DBus.Error.InvalidArgs", QStringLiteral("RegisterWindow takes (u windowId, o menuObjectPath)"));
            const quint32 windowId = args.at(0).toUInt();
            const QString path     = args.at(1).value<QDBusObjectPath>().path();
            if (!isValidObjectPath(path))
                return error("org.freedesktop.DBus.Error.InvalidArgs", QStringLiteral("not a valid menu object path"));
            const quint64 seq = book.add(sender, windowId, path);
            if (seq == 0)
                return error("org.freedesktop.DBus.Error.LimitsExceeded", QStringLiteral("too many menus are registered"));
            Answer a;
            a.kind     = Answer::Kind::Reply;
            a.added    = true;
            a.windowId = windowId;
            a.seq      = seq;
            return a;
        }
        if (member == QLatin1String("UnregisterWindow")) {
            if (signature != QLatin1String("u") || args.size() != 1 || !sender.startsWith(u':'))
                return error("org.freedesktop.DBus.Error.InvalidArgs", QStringLiteral("UnregisterWindow takes (u windowId)"));
            Answer a;
            a.kind    = Answer::Kind::Reply;
            a.removed = book.remove(sender, args.at(0).toUInt());
            return a;
        }
        if (member == QLatin1String("GetMenuForWindow"))
            return error("com.canonical.AppMenu.Registrar.Error.NotFound", QStringLiteral("menus are linked to windows by their process; nothing can be looked up"));
        if (member == QLatin1String("GetMenus"))
            return error("org.freedesktop.DBus.Error.NotSupported", QStringLiteral("GetMenus is not implemented"));
        return error("org.freedesktop.DBus.Error.UnknownMethod", QStringLiteral("not a registrar method"));
    }

} // namespace gf::menubridge::registrar
