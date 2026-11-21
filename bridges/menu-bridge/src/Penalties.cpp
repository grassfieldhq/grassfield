#include "Penalties.h"

#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace gf::menubridge {

    namespace {
        constexpr const char* kHeader = "grassfield-menu-bridge-state 3";

        QByteArray encodeIdentity(const QString& id) {
            return id.toUtf8().toPercentEncoding(QByteArrayLiteral("/:"));
        }

        // The identity of a state-file token, empty if the token is not a valid identity.
        QString decodeIdentity(const QByteArray& token) {
            if (token.isEmpty() || token.size() > penalty::kMaxIdentity * 6)
                return {};
            const QString id = QString::fromUtf8(QByteArray::fromPercentEncoding(token));
            return validIdentity(id) ? id : QString();
        }

        bool parseInt(const QByteArray& token, qint64 min, qint64 max, qint64* out) {
            bool         ok = false;
            const qint64 v  = token.toLongLong(&ok);
            if (!ok || v < min || v > max)
                return false;
            *out = v;
            return true;
        }

        bool hasControl(const QString& s) {
            return std::any_of(s.cbegin(), s.cend(), [](QChar c) { return c.unicode() < 0x20 || c.unicode() == 0x7F; });
        }

        QByteArray readProc(qint64 pid, const char* name, qsizetype max) {
            QFile f(QStringLiteral("/proc/%1/%2").arg(pid).arg(QLatin1String(name)));
            if (!f.open(QIODevice::ReadOnly))
                return {};
            return f.read(max);
        }
    } // namespace

    qint64 nowSec() {
        timespec ts{};
        ::clock_gettime(CLOCK_BOOTTIME, &ts);
        return ts.tv_sec;
    }

    QString bootId() {
        QFile f(QStringLiteral("/proc/sys/kernel/random/boot_id"));
        if (!f.open(QIODevice::ReadOnly))
            return QStringLiteral("unknown");
        const QString id = QString::fromLatin1(f.read(64)).trimmed();
        return id.isEmpty() ? QStringLiteral("unknown") : id;
    }

    bool validIdentity(const QString& id) {
        if (id == kUnknownIdentity)
            return true;
        if (!id.startsWith(QLatin1String("id:")) || id.size() > penalty::kMaxIdentity || !id.contains(QLatin1String("exe=/")))
            return false;
        return !hasControl(id);
    }

    QString displayIdentity(const QString& id) {
        // systemd escapes '-' as \x2d in unit names: readable in logs, never in the (canonical) key.
        QString out = id;
        out.replace(QLatin1String("\\x2d"), QLatin1String("-"));
        return out;
    }

    QString appScopeOf(const QString& cgroupText) {
        // cgroup v2 ("0::/path") when present, else the last hierarchy line.
        QString           path;
        const QStringList lines = cgroupText.split(u'\n', Qt::SkipEmptyParts);
        for (const QString& line : lines) {
            const QStringList f = line.split(u':');
            if (f.size() < 3)
                continue;
            path = f.mid(2).join(u':');
            if (f.at(0) == QLatin1String("0"))
                break;
        }
        const QStringList parts = path.split(u'/', Qt::SkipEmptyParts);
        for (qsizetype i = parts.size() - 1; i >= 0; --i) {
            QString unit = parts.at(i);
            if (!unit.startsWith(QLatin1String("app-")) && !unit.startsWith(QLatin1String("app@")))
                continue;
            if (unit.endsWith(QLatin1String(".scope"))) {
                unit.chop(6);
                // app-<launcher>-<appid>-<instance>: the instance is the trailing -<digits> (flatpak, gnome...),
                // -<8 hex digits> (uwsm: app-Hyprland-gtk\x2dlaunch-2616d5ca) or -<32 hex digits> (KIO:
                // app-<name>-<QUuid Id128>.scope). Left in, every relaunch would be a new identity and escape its refusal.
                static const QRegularExpression instance(QStringLiteral("-(?:[0-9]+|[0-9a-f]{8}|[0-9a-f]{32})$"));
                unit.remove(instance);
            } else if (unit.endsWith(QLatin1String(".service"))) {
                unit.chop(8);
                if (const qsizetype at = unit.indexOf(u'@'); at >= 0)
                    unit.truncate(at); // template instance
            } else
                continue;
            if (unit.size() > 200)
                unit.truncate(200);
            // A real unit name has no control character or separator: anything else is not trusted as a scope.
            if (hasControl(unit) || unit.contains(u'|'))
                return {};
            return unit;
        }
        return {};
    }

    QString scriptOf(const QString& exe, const QByteArray& cmdline) {
        const QString                  base = QFileInfo(exe).fileName().toLower();
        static const QRegularExpression interpreters(QStringLiteral("^(python[0-9.]*|perl[0-9.]*|ruby[0-9.]*|node(js)?|bash|sh|dash|zsh|java)$"));
        if (!interpreters.match(base).hasMatch() || cmdline.isEmpty())
            return {};
        const QList<QByteArray> args    = cmdline.left(4096).split('\0');
        bool                    endOpts = false;
        for (qsizetype i = 1; i < args.size(); ++i) {
            const QByteArray& a = args.at(i);
            if (a.isEmpty())
                continue;
            if (!endOpts) {
                if (a == "--" || (a == "-jar" && base == QLatin1String("java"))) {
                    endOpts = true; // what follows is the script (or the jar)
                    continue;
                }
                // Any interpreter option before the script (-c/-e inline code, -m, -W value, --trace-* value, attached or
                // separate values...) goes to the shared bucket: telling an option's value from the script per
                // interpreter version proved error-prone (a value taken for the script hands out another app's identity).
                if (a.startsWith('-'))
                    return kScriptUnknown;
            }
            QString script = QString::fromUtf8(a.left(256));
            for (QChar& ch : script) {
                if (ch.unicode() < 0x20 || ch.unicode() == 0x7F || ch == u'|')
                    ch = u'?';
            }
            return script;
        }
        return {};
    }

    QString identityFrom(const PeerFacts& facts) {
        QString exe = facts.exe;
        if (exe.endsWith(QLatin1String(" (deleted)")))
            exe.chop(10); // the binary was replaced while running (package upgrade): still the same application
        if (!exe.startsWith(u'/'))
            return kUnknownIdentity; // unreadable: the shared bucket, never a per-process key
        QString id = QStringLiteral("id:");
        if (const QString scope = appScopeOf(facts.cgroup); !scope.isEmpty())
            id += QStringLiteral("scope=") + scope + u'|';
        id += QStringLiteral("exe=") + exe;
        const QString script = scriptOf(exe, facts.cmdline);
        if (script == kScriptUnknown)
            return kUnknownIdentity; // options we cannot tell from the script: the shared bucket, never a guess
        if (!script.isEmpty())
            id += QStringLiteral("|script=") + script;
        return validIdentity(id) ? id : kUnknownIdentity;
    }

    QString appIdentity(qint64 pid) {
        PeerFacts        facts;
        char             buf[PATH_MAX + 1];
        const QByteArray link = QByteArrayLiteral("/proc/") + QByteArray::number(pid) + "/exe";
        const ssize_t    n    = ::readlink(link.constData(), buf, PATH_MAX);
        if (n <= 0)
            return kUnknownIdentity; // not readable (non-dumpable process, another user's): the shared bucket
        facts.exe     = QString::fromUtf8(buf, static_cast<qsizetype>(n));
        facts.cgroup  = QString::fromUtf8(readProc(pid, "cgroup", 8192));
        facts.cmdline = readProc(pid, "cmdline", 4096);
        return identityFrom(facts);
    }

    PenaltyBook::Entry& PenaltyBook::entry(const QString& id) {
        auto it = m_entries.find(id);
        if (it == m_entries.end()) {
            makeRoom();
            it = m_entries.insert(id, Entry{});
        }
        it->touch = ++m_touch;
        return *it;
    }

    qsizetype PenaltyBook::refusedCount() const {
        const qint64 now = m_clock();
        qsizetype    n   = 0;
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it)
            n += now < it->denyUntil ? 1 : 0;
        return n;
    }

    // Idle entries (not refused right now) are bounded, least recently used first out. Refused entries are never
    // dropped here: cheap fresh identities cannot push a refusal out before it expires.
    void PenaltyBook::makeRoom() {
        const qint64 now  = m_clock();
        qsizetype    idle = 0;
        QString      victim;
        quint64      victimTouch = 0;
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
            if (now < it->denyUntil)
                continue;
            ++idle;
            if (victim.isEmpty() || it->touch < victimTouch) {
                victim      = it.key();
                victimTouch = it->touch;
            }
        }
        if (idle >= penalty::kMaxIdle && !victim.isEmpty())
            m_entries.remove(victim);
    }

    // The refused set is bounded separately: past kMaxRefused the refusal closest to its expiry (other than `keep`) goes.
    void PenaltyBook::capRefused(const QString& keep) {
        const qint64 now = m_clock();
        while (refusedCount() > penalty::kMaxRefused) {
            QString victim;
            qint64  until = 0;
            for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
                if (now >= it->denyUntil || it.key() == keep)
                    continue;
                if (victim.isEmpty() || it->denyUntil < until) {
                    victim = it.key();
                    until  = it->denyUntil;
                }
            }
            if (victim.isEmpty())
                break;
            m_entries.remove(victim);
        }
    }

    void PenaltyBook::strike(const QString& id, Entry& e) {
        const qint64 now = m_clock();
        e.lastStrike     = now;
        if (id == kUnknownIdentity) {
            // The shared bucket: innocents live behind it. A short refusal that never doubles and is never permanent.
            e.strikes   = 1;
            e.denyUntil = now + penalty::kUnknownDenySec;
            return;
        }
        ++e.strikes;
        qint64 span = penalty::kDenyBaseSec;
        for (int i = 1; i < e.strikes && span < penalty::kDenyMaxSec; ++i)
            span *= 2;
        e.denyUntil = now + std::min(span, penalty::kDenyMaxSec);
    }

    int PenaltyBook::crashes() const {
        const qint64 now = m_clock();
        int          n   = 0;
        for (const qint64 t : m_crashes)
            n += now - t < penalty::kCrashWindowSec ? 1 : 0;
        return n;
    }

    // Every crash counts, blamed or not: rotating copies of a binary cannot crash-loop the bridge without ending in
    // degraded mode. Sliding window: kMaxCrashes within any kCrashWindowSec.
    void PenaltyBook::recordCrash() {
        const qint64 now = m_clock();
        m_crashes.removeIf([now](qint64 t) { return now - t >= penalty::kCrashWindowSec; });
        m_crashes.append(now);
        while (m_crashes.size() > penalty::kMaxCrashesKept)
            m_crashes.removeFirst();
    }

    bool PenaltyBook::refused(const QString& id, QString* why) {
        const auto it = m_entries.find(id);
        if (it == m_entries.end())
            return false;
        const qint64 now = m_clock();
        // Decay: no strike for kForgiveSec after the last refusal ended.
        if (now >= it->denyUntil && now >= it->layoutUntil && now >= it->floodUntil && now - it->lastStrike >= penalty::kForgiveSec) {
            m_entries.erase(it);
            return false;
        }
        it->touch = ++m_touch;
        if (now < it->denyUntil) {
            *why = QStringLiteral("this application's menu was refused (it crashed the bridge or sent an oversized menu), retrying in %1 min").arg((it->denyUntil - now + 59) / 60);
            return true;
        }
        if (now < it->floodUntil) {
            *why = QStringLiteral("this application changed its menu continuously, retrying in %1 s").arg(it->floodUntil - now);
            return true;
        }
        if (now < it->layoutUntil) {
            *why = QStringLiteral("this application's menu failed %1 times, retrying in %2 s").arg(it->layoutFailures).arg(it->layoutUntil - now);
            return true;
        }
        return false;
    }

    void PenaltyBook::record(const QString& id, Offence what) {
        Entry& e = entry(id);
        if (what == Offence::LayoutFailed) {
            ++e.layoutFailures;
            qint64 span = 1;
            for (int i = 0; i < e.layoutFailures && span < penalty::kLayoutMaxSec; ++i)
                span *= 2;
            e.layoutUntil = m_clock() + std::min(span, penalty::kLayoutMaxSec);
            if (e.lastStrike == 0)
                e.lastStrike = m_clock(); // starts the decay clock of an entry without a strike
            return;
        }
        if (what == Offence::Flood) {
            // Doubling per flood, not ended by a delivered menu (it delivers all the time); forgotten with the entry's decay.
            qint64 span = penalty::kFloodBaseSec;
            // The shared "unknown" bucket never doubles (innocents behind it recover, as for its other refusals).
            for (int i = 0; id != kUnknownIdentity && i < e.floods && span < penalty::kFloodMaxSec; ++i)
                span *= 2;
            ++e.floods;
            e.floodUntil = m_clock() + std::min(span, penalty::kFloodMaxSec);
            e.lastStrike = m_clock();
            return;
        }
        strike(id, e);
        capRefused(id);
    }

    void PenaltyBook::delivered(const QString& id) {
        const auto it = m_entries.find(id);
        if (it == m_entries.end())
            return;
        it->layoutFailures = 0;
        it->layoutUntil    = 0;
        if (it->strikes == 0 && it->floods == 0)
            m_entries.erase(it);
    }

    void PenaltyBook::leftCleanly(const QString& id) {
        const auto it = m_entries.find(id);
        if (it == m_entries.end())
            return;
        const qint64 now = m_clock();
        if (now < it->denyUntil)
            return; // refused right now: leaving does not clear anything
        // Inside the decay window a clean exit does not reset the doubling (a free reset for an application that
        // kills the bridge, leaves and comes back). Only the short layout back-off is cleared.
        it->layoutFailures = 0;
        it->layoutUntil    = 0;
        if (now < it->floodUntil)
            return; // a flood's refusal is not ended by leaving either
        if (it->strikes > 0 && now - it->lastStrike >= penalty::kForgiveSec)
            --it->strikes;
        if (it->floods > 0 && now - it->lastStrike >= penalty::kForgiveSec)
            it->floods = 0;
        if (it->strikes == 0 && it->floods == 0)
            m_entries.erase(it);
    }

    RefetchBudget::RefetchBudget(std::function<qint64()> clockMs) : m_clock(std::move(clockMs)) {}

    qint64 RefetchBudget::ask(const QString& id) {
        const qint64 now = m_clock();
        auto         it  = m_entries.find(id);
        if (it == m_entries.end()) {
            if (m_entries.size() >= penalty::kRefetchTracked) {
                // The least recently asked identity goes (it starts again with a full budget if it comes back).
                auto oldest = m_entries.begin();
                for (auto e = m_entries.begin(); e != m_entries.end(); ++e) {
                    if (e->touch < oldest->touch)
                        oldest = e;
                }
                m_entries.erase(oldest);
            }
            Entry fresh;
            fresh.refilledAt = now;
            it               = m_entries.insert(id, fresh);
        }
        Entry& e = it.value();
        e.touch  = ++m_touch;
        if (now > e.refilledAt) {
            e.tokens     = std::min<double>(penalty::kRefetchBurst, e.tokens + double(now - e.refilledAt) / double(penalty::kRefetchRefillMs));
            e.refilledAt = now;
        }
        // A pause in the demand ends a flood: an application that re-reads in bursts (a selection that changes the
        // enabled actions) is throttled, never punished.
        if (e.floodStart >= 0 && now - e.lastRefusal >= penalty::kFloodQuietMs)
            e.floodStart = -1;
        if (e.tokens >= 1.0) {
            e.tokens -= 1.0;
            return 0;
        }
        if (e.floodStart < 0)
            e.floodStart = now;
        e.lastRefusal = now;
        if (now - e.floodStart >= penalty::kFloodMs) {
            e.floodStart = -1;
            return -1;
        }
        const qint64 wait = qint64((1.0 - e.tokens) * double(penalty::kRefetchRefillMs)) + 1;
        return std::clamp<qint64>(wait, 1, penalty::kRefetchRefillMs);
    }

    void RefetchBudget::forget(const QString& id) {
        m_entries.remove(id);
    }

    QByteArray PenaltyBook::serialize(const QList<InflightCall>& inflight, const QString& boot, bool running) const {
        QByteArray out = QByteArray(kHeader) + '\n' + "boot " + boot.toLatin1() + '\n' + (running ? "run 1\n" : "run 0\n");
        for (const InflightCall& c : inflight) {
            if (validIdentity(c.id) && c.calls > 0)
                out += "inflight " + QByteArray::number(c.calls) + ' ' + QByteArray::number(c.ageMs) + ' ' + encodeIdentity(c.id) + '\n';
        }
        for (const qint64 t : m_crashes) {
            if (m_clock() - t < penalty::kCrashWindowSec)
                out += "crash " + QByteArray::number(t) + '\n';
        }
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
            if (it->strikes <= 0)
                continue;
            out += "deny " + QByteArray::number(it->strikes) + ' ' + QByteArray::number(it->denyUntil) + ' ' + QByteArray::number(it->lastStrike) + ' ' + encodeIdentity(it.key()) + '\n';
        }
        return out;
    }

    bool PenaltyBook::load(const QByteArray& data, const QString& boot, QString* why, CrashOutcome* out) {
        if (data.size() > penalty::kMaxStateBytes) {
            *why = QStringLiteral("state file too large");
            return false;
        }
        const QList<QByteArray> lines = data.split('\n');
        if (lines.size() < 2 || lines.at(0) != kHeader) {
            *why = QStringLiteral("unknown header");
            return false;
        }
        if (lines.at(1) != "boot " + boot.toLatin1()) {
            *why = QStringLiteral("written in another boot");
            return false;
        }
        struct Deny {
            QString id;
            int     strikes;
            qint64  until;
            qint64  last;
        };
        QList<Deny>         denies;
        QList<InflightCall> inflight;
        int                 running = -1;
        QList<qint64>       crashTimes;
        const qint64        now = m_clock();
        for (qsizetype i = 2; i < lines.size(); ++i) {
            const QByteArray& line = lines.at(i);
            if (line.isEmpty())
                continue;
            if (denies.size() + inflight.size() >= (penalty::kMaxIdle + penalty::kMaxRefused) * 2) {
                *why = QStringLiteral("too many entries");
                return false;
            }
            const QList<QByteArray> f = line.split(' ');
            qint64                  calls = 0, age = 0;
            if (f.at(0) == "run" && f.size() == 2 && running < 0 && (f.at(1) == "0" || f.at(1) == "1")) {
                running = f.at(1) == "1" ? 1 : 0;
            } else if (f.at(0) == "inflight" && f.size() == 4) {
                const QString id = decodeIdentity(f.at(3));
                if (id.isEmpty() || !parseInt(f.at(1), 1, 10000, &calls) || !parseInt(f.at(2), 0, 24 * 3600 * 1000, &age)) {
                    *why = QStringLiteral("invalid inflight line");
                    return false;
                }
                inflight.append({id, static_cast<int>(calls), age});
            } else if (f.at(0) == "crash" && f.size() == 2) {
                qint64 t = 0;
                if (crashTimes.size() >= penalty::kMaxCrashesKept || !parseInt(f.at(1), 0, now, &t)) {
                    *why = QStringLiteral("invalid crash line");
                    return false;
                }
                crashTimes.append(t);
            } else if (f.at(0) == "deny" && f.size() == 5) {
                qint64        strikes = 0, until = 0, last = 0;
                const QString id = decodeIdentity(f.at(4));
                // Times are boot-relative seconds: not in the future by more than the longest refusal.
                if (id.isEmpty() || !parseInt(f.at(1), 1, 64, &strikes) || !parseInt(f.at(2), 0, now + penalty::kDenyMaxSec, &until) || !parseInt(f.at(3), 0, now, &last)) {
                    *why = QStringLiteral("invalid deny line");
                    return false;
                }
                if (id == kUnknownIdentity)
                    until = std::min(until, now + penalty::kUnknownDenySec); // a forged long refusal of the shared bucket
                denies.append({id, static_cast<int>(strikes), until, last});
            } else {
                *why = QStringLiteral("unknown line");
                return false;
            }
        }
        if (running < 0) {
            *why = QStringLiteral("no run line");
            return false;
        }
        // Everything validated: merge.
        for (const Deny& d : denies) {
            Entry& e     = entry(d.id);
            e.strikes    = d.strikes;
            e.denyUntil  = d.until;
            e.lastStrike = d.last;
            capRefused(d.id);
        }
        for (const qint64 t : crashTimes)
            m_crashes.append(t);
        if (out)
            *out = CrashOutcome{};
        if (running == 1) {
            // The previous run did not stop cleanly: it counts toward the degradation budget whoever is to blame.
            // It is blamed on an identity only when the evidence is unambiguous: exactly one call in flight, to one
            // identity, and a fresh one. Otherwise nobody is blamed.
            int total = 0;
            for (const InflightCall& c : inflight)
                total += c.calls;
            CrashOutcome result;
            result.crashed = true;
            recordCrash();
            if (inflight.size() == 1 && total == 1 && inflight.first().ageMs <= penalty::kFreshCallMs) {
                result.culprit = inflight.first().id;
                record(result.culprit, Offence::Crash);
            }
            result.crashes = crashes();
            if (out)
                *out = result;
        }
        return true;
    }

    bool readStateFile(const QString& path, QByteArray* data, QString* why) {
        why->clear();
        const QByteArray local = QFile::encodeName(path);
        const int        fd    = ::open(local.constData(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY);
        if (fd < 0) {
            if (errno != ENOENT)
                *why = errno == ELOOP ? QStringLiteral("a symlink") : QString::fromLocal8Bit(std::strerror(errno));
            return false;
        }
        struct stat st{};
        if (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != ::getuid() || st.st_size > penalty::kMaxStateBytes) {
            ::close(fd);
            *why = QStringLiteral("not a regular file of this user within %1 bytes").arg(penalty::kMaxStateBytes);
            return false;
        }
        data->clear();
        data->resize(static_cast<qsizetype>(st.st_size));
        qsizetype got = 0;
        while (got < data->size()) {
            const ssize_t n = ::read(fd, data->data() + got, static_cast<size_t>(data->size() - got));
            if (n <= 0)
                break;
            got += n;
        }
        ::close(fd);
        data->resize(got);
        return true;
    }

    bool writeStateFile(const QString& path, const QByteArray& data) {
        // Everything relative to a directory descriptor: the temp file is created with O_EXCL|O_NOFOLLOW (it can
        // neither pre-exist nor be a link), and renameat replaces whatever is at the final name (a symlink included)
        // without following it. There is no window between a check and the write.
        const QFileInfo  info(path);
        const QByteArray dir  = QFile::encodeName(info.absolutePath());
        const QByteArray name = QFile::encodeName(info.fileName());
        if (name.isEmpty() || name.contains('/'))
            return false;
        const int dirFd = ::open(dir.constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (dirFd < 0)
            return false;
        const QByteArray tmp = "." + name + ".tmp." + QByteArray::number(static_cast<qlonglong>(::getpid()));
        int              fd  = ::openat(dirFd, tmp.constData(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0 && errno == EEXIST) {
            ::unlinkat(dirFd, tmp.constData(), 0); // a leftover of an earlier run with the same pid; unlinkat never follows
            fd = ::openat(dirFd, tmp.constData(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        }
        bool ok = fd >= 0;
        if (ok) {
            qsizetype done = 0;
            while (done < data.size()) {
                const ssize_t n = ::write(fd, data.constData() + done, static_cast<size_t>(data.size() - done));
                if (n < 0 && errno == EINTR)
                    continue;
                if (n <= 0) {
                    ok = false;
                    break;
                }
                done += n;
            }
            ::close(fd);
        }
        if (ok)
            ok = ::renameat(dirFd, tmp.constData(), dirFd, name.constData()) == 0;
        if (!ok && fd >= 0)
            ::unlinkat(dirFd, tmp.constData(), 0);
        ::close(dirFd);
        return ok;
    }

} // namespace gf::menubridge
