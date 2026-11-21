#include "Launcher.h"

#include <QMetaType>
#include <QSet>
#include <QStringList>

#include <algorithm>
#include <cmath>
#include <utility>

namespace gf::menubridge::launcher {

    namespace {
        constexpr QLatin1String kPrefix("application://");
        constexpr QLatin1String kSuffix(".desktop");

        bool idChar(QChar c) {
            const ushort u = c.unicode();
            return (u >= 'a' && u <= 'z') || (u >= 'A' && u <= 'Z') || (u >= '0' && u <= '9') || u == '.' || u == '_' || u == '-';
        }

        bool isType(const QVariant& v, QMetaType::Type t) {
            return v.typeId() == t;
        }

    } // namespace

    std::optional<QString> appFromUri(const QString& uri) {
        if (!uri.startsWith(kPrefix) || !uri.endsWith(kSuffix) || uri.size() < kPrefix.size() + kSuffix.size())
            return std::nullopt;
        const QString id = uri.mid(kPrefix.size(), uri.size() - kPrefix.size() - kSuffix.size());
        if (id.isEmpty() || id.size() > kMaxIdBytes || !std::all_of(id.cbegin(), id.cend(), idChar))
            return std::nullopt; // the charset is ASCII: characters equal bytes
        return id;
    }

    void Properties::merge(const Properties& later) {
        if (later.count)
            count = later.count;
        if (later.countVisible)
            countVisible = later.countVisible;
        if (later.progress)
            progress = later.progress;
        if (later.progressVisible)
            progressVisible = later.progressVisible;
        if (later.urgent)
            urgent = later.urgent;
    }

    Parsed parse(const QString& uri, const QVariantMap& properties) {
        Parsed out;
        const auto app = appFromUri(uri);
        if (!app)
            return out;
        out.valid = true;
        out.app   = *app;
        if (properties.size() > kMaxProperties) {
            out.dropped = true; // nothing is read from an absurd map
            return out;
        }
        for (auto it = properties.cbegin(); it != properties.cend(); ++it) {
            const QString&  key = it.key();
            const QVariant& v   = it.value();
            if (key == QLatin1String("count")) {
                if (isType(v, QMetaType::LongLong))
                    out.properties.count = std::clamp<qint64>(v.toLongLong(), 0, kMaxCount);
                else
                    out.dropped = true;
            } else if (key == QLatin1String("progress")) {
                if (isType(v, QMetaType::Double) && std::isfinite(v.toDouble()))
                    out.properties.progress = std::clamp(v.toDouble(), 0.0, 1.0);
                else
                    out.dropped = true;
            } else if (key == QLatin1String("count-visible")) {
                if (isType(v, QMetaType::Bool))
                    out.properties.countVisible = v.toBool();
                else
                    out.dropped = true;
            } else if (key == QLatin1String("progress-visible")) {
                if (isType(v, QMetaType::Bool))
                    out.properties.progressVisible = v.toBool();
                else
                    out.dropped = true;
            } else if (key == QLatin1String("urgent")) {
                if (isType(v, QMetaType::Bool))
                    out.properties.urgent = v.toBool();
                else
                    out.dropped = true;
            }
        }
        return out;
    }

    Update Book::apply(const QString& app, Entry& e, const Properties& p) {
        Update u;
        u.app = app;
        if (p.count)
            e.rawCount = p.count;
        if (p.countVisible)
            e.countVisible = *p.countVisible;
        if (p.progress)
            e.rawProgress = p.progress;
        if (p.progressVisible)
            e.progressVisible = *p.progressVisible;
        if (p.count || p.countVisible) {
            if (!e.countVisible)
                u.count = 0;
            else if (e.rawCount)
                u.count = *e.rawCount;
        }
        if (p.progress || p.progressVisible) {
            if (!e.progressVisible)
                u.progress = -1.0;
            else if (e.rawProgress)
                u.progress = *e.rawProgress;
        }
        if (p.urgent) {
            e.urgent = p.urgent;
            u.urgent = p.urgent;
        }
        if (!u.forget())
            e.hasState = true;
        return u;
    }

    bool Book::take(Sender& s, qint64 nowMs) {
        while (!s.times.empty() && s.times.front() <= nowMs - kWindowMs)
            s.times.pop_front();
        if (static_cast<int>(s.times.size()) >= kMaxPerSecond)
            return false;
        s.times.push_back(nowMs);
        return true;
    }

    namespace {
        // systemd's unit-name escapes ("\x2d" for '-').
        QString unescapeUnit(const QString& text) {
            QString out;
            out.reserve(text.size());
            for (qsizetype i = 0; i < text.size(); ++i) {
                if (text.at(i) == u'\\' && i + 3 < text.size() && text.at(i + 1) == u'x') {
                    bool       ok = false;
                    const uint v  = text.mid(i + 2, 2).toUInt(&ok, 16);
                    if (ok && v > 0x20 && v < 0x7F) {
                        out += QChar(v);
                        i += 3;
                        continue;
                    }
                }
                out += text.at(i);
            }
            return out;
        }

        QString normalized(QString id) {
            id = id.toLower();
            if (id.endsWith(QLatin1String(".desktop")))
                id.chop(8);
            return id;
        }

        QString lastPart(const QString& id) {
            return id.section(u'.', -1);
        }

        bool sameApp(const QString& candidate, const QString& app) {
            const QString a = normalized(candidate);
            const QString b = normalized(app);
            return !a.isEmpty() && (a == b || lastPart(a) == lastPart(b));
        }
    } // namespace

    bool mayUpdate(const QString& identity, const QString& app) {
        if (!identity.startsWith(QLatin1String("id:")))
            return true; // the shared unknown bucket, or no identity: nothing tells which application it is
        QString scope, exe;
        for (const QString& part : identity.mid(3).split(u'|')) {
            if (part.startsWith(QLatin1String("scope=")))
                scope = part.mid(6);
            else if (part.startsWith(QLatin1String("exe=")))
                exe = part.mid(4);
        }
        if (!scope.startsWith(QLatin1String("app-")))
            return true; // not in an application's scope (a session service, a script of the session)
        // app-<launcher>-<application id> or app-<application id>: the separators are plain '-', the id's own are escaped
        // (\x2d) by systemd-conforming launchers; both readings are tried.
        const QString rest = scope.mid(4);
        QStringList   candidates{unescapeUnit(rest)};
        if (const qsizetype dash = rest.indexOf(u'-'); dash > 0)
            candidates << unescapeUnit(rest.mid(dash + 1));
        if (!exe.isEmpty())
            candidates << exe.section(u'/', -1);
        return std::any_of(candidates.cbegin(), candidates.cend(), [&](const QString& c) { return sameApp(c, app); });
    }

    int Book::appsOf(const QString& identity) const {
        int n = 0;
        for (const Entry& e : m_apps) {
            const auto sit = m_senders.constFind(e.owner);
            if (sit != m_senders.cend() && sit->identity == identity)
                ++n;
        }
        return n;
    }

    QString Book::evictOne() {
        QString victim;
        int     victimRank = 3;
        qint64  victimMs   = 0;
        QSet<QString> owners;
        for (const Entry& e : std::as_const(m_apps))
            owners.insert(e.owner);
        for (auto it = m_senders.cbegin(); it != m_senders.cend(); ++it) {
            // Refused senders first, then senders holding no app; never one that holds an app's state.
            const int rank = it->refused ? 0 : !owners.contains(it.key()) ? 1 : 2;
            if (rank == 2)
                continue;
            if (rank < victimRank || (rank == victimRank && it->lastMs < victimMs)) {
                victim     = it.key();
                victimRank = rank;
                victimMs   = it->lastMs;
            }
        }
        if (!victim.isEmpty())
            m_senders.remove(victim);
        return victim;
    }

    bool Book::awaitIdentity(const QString& sender, QString* evicted) {
        evicted->clear();
        auto it = m_senders.find(sender);
        if (it == m_senders.end()) {
            if (static_cast<int>(m_senders.size()) >= kMaxSenders) {
                *evicted = evictOne();
                if (evicted->isEmpty())
                    return false;
            }
            it = m_senders.insert(sender, Sender{});
        }
        if (it->identity.isEmpty())
            it->awaiting = true;
        return true;
    }

    Book::Result Book::setIdentity(const QString& sender, const QString& identity, qint64 nowMs, bool applyEarly) {
        Result r;
        auto   it = m_senders.find(sender);
        if (it == m_senders.end())
            return r;
        it->awaiting = false;
        it->identity = identity;
        int same     = 0;
        for (auto o = m_senders.cbegin(); o != m_senders.cend(); ++o)
            same += o.key() != sender && !o->refused && o->identity == identity ? 1 : 0;
        if (same >= kMaxSendersPerIdentity) {
            it->refused = true;
            it->early.clear();
            r.dropped = true;
            return r;
        }
        const QList<Early> early = std::exchange(it->early, {});
        if (!applyEarly)
            return r;
        for (const Early& e : early) {
            const Result one = handle(sender, it.value(), e.uri, e.properties, nowMs);
            r.forward.insert(r.forward.end(), one.forward.begin(), one.forward.end());
            r.malformed = r.malformed || one.malformed;
            r.throttled = r.throttled || one.throttled;
            r.dropped   = r.dropped || one.dropped;
            r.foreign   = r.foreign || one.foreign;
        }
        return r;
    }

    Book::Result Book::submit(const QString& sender, const QString& uri, const QVariantMap& properties, qint64 nowMs) {
        Result r;
        auto   sit = m_senders.find(sender);
        if (sit == m_senders.end()) {
            if (static_cast<int>(m_senders.size()) >= kMaxSenders) {
                r.evicted = evictOne();
                if (r.evicted.isEmpty()) {
                    r.dropped = true;
                    return r;
                }
            }
            sit = m_senders.insert(sender, Sender{});
        }
        Sender& s = sit.value();
        s.lastMs  = nowMs;
        if (s.refused) {
            r.dropped = true;
            return r;
        }
        if (s.awaiting) {
            // Kept until the identity is known: the last update per uri, at most kMaxEarly of them.
            s.early.removeIf([&](const Early& e) { return e.uri == uri; });
            if (s.early.size() >= kMaxEarly) {
                r.dropped = true;
                return r;
            }
            s.early.append(Early{uri, properties});
            r.waiting = true;
            return r;
        }
        const QString evicted = r.evicted;
        r                     = handle(sender, s, uri, properties, nowMs);
        r.evicted             = evicted;
        return r;
    }

    Book::Result Book::handle(const QString& sender, Sender& s, const QString& uri, const QVariantMap& properties, qint64 nowMs) {
        Result       r;
        const Parsed p      = parse(uri, properties);
        const bool   budget = take(s, nowMs);
        if (!budget) {
            r.throttled = true;
            if (!p.valid || p.properties.empty())
                return r;
        } else if (!p.valid) {
            r.malformed = true;
            return r;
        } else {
            r.malformed = p.dropped;
        }
        if (!s.identity.isEmpty() && !mayUpdate(s.identity, p.app)) {
            r.dropped = true;
            r.foreign = true;
            return r;
        }

        auto it = m_apps.find(p.app);
        if (it == m_apps.end()) {
            if (static_cast<int>(m_apps.size()) >= kMaxApps || (!s.identity.isEmpty() && appsOf(s.identity) >= kMaxAppsPerIdentity)) {
                r.dropped = true;
                return r;
            }
            it = m_apps.insert(p.app, Entry{});
        }
        Entry& e = it.value();
        e.owner  = sender;
        if (!budget) {
            e.pending.merge(p.properties); // the last properties per app win
            return r;
        }
        Properties props = e.pending;
        props.merge(p.properties);
        e.pending = {};
        const Update u = apply(p.app, e, props);
        if (!u.forget())
            r.forward.push_back(u);
        if (!e.hasState && e.pending.empty())
            m_apps.erase(it);
        return r;
    }

    std::vector<Update> Book::flush(qint64 nowMs) {
        std::vector<Update> out;
        QStringList         apps = m_apps.keys();
        apps.sort();
        for (const QString& app : apps) {
            Entry& e = m_apps[app];
            if (e.pending.empty())
                continue;
            auto sit = m_senders.find(e.owner);
            if (sit == m_senders.end() || !take(sit.value(), nowMs))
                continue;
            const Properties props = e.pending;
            e.pending              = {};
            const Update u         = apply(app, e, props);
            if (!u.forget())
                out.push_back(u);
            if (!e.hasState)
                m_apps.remove(app);
        }
        return out;
    }

    bool Book::hasPending() const {
        return std::any_of(m_apps.cbegin(), m_apps.cend(), [](const Entry& e) { return !e.pending.empty(); });
    }

    std::vector<Update> Book::senderGone(const QString& sender) {
        std::vector<Update> out;
        m_senders.remove(sender);
        QStringList apps = m_apps.keys();
        apps.sort();
        for (const QString& app : apps) {
            const Entry& e = m_apps[app];
            if (e.owner != sender)
                continue;
            if (e.hasState) {
                Update u;
                u.app = app;
                out.push_back(u); // every value empty: forget
            }
            m_apps.remove(app);
        }
        return out;
    }

    std::vector<Update> Book::snapshot() const {
        std::vector<Update> out;
        QStringList         apps = m_apps.keys();
        apps.sort();
        for (const QString& app : apps) {
            const Entry& e = m_apps.value(app);
            if (!e.hasState)
                continue;
            Update u;
            u.app = app;
            if (!e.countVisible)
                u.count = 0;
            else if (e.rawCount)
                u.count = *e.rawCount;
            if (!e.progressVisible)
                u.progress = -1.0;
            else if (e.rawProgress)
                u.progress = *e.rawProgress;
            u.urgent = e.urgent;
            if (!u.forget())
                out.push_back(u);
        }
        return out;
    }

} // namespace gf::menubridge::launcher
