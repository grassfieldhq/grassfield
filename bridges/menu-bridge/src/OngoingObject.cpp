#include "OngoingObject.h"

#include "DBusObjects.h"
#include "Log.h"
#include "Protocol.h"

#include <QDBusArgument>
#include <QDBusPendingCallWatcher>
#include <QDBusServiceWatcher>
#include <QDBusUnixFileDescriptor>
#include <QDateTime>
#include <QFile>

#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

namespace gf::menubridge::ongoing {

    namespace {
        const QString kInvalidArgs   = QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs");
        const QString kLimits        = QStringLiteral("org.freedesktop.DBus.Error.LimitsExceeded");
        const QString kDenied        = QStringLiteral("org.freedesktop.DBus.Error.AccessDenied");
        const QString kUnknownMethod = QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod");
        constexpr int kSweepMs       = 30 * 1000;
        constexpr qint64 kIndexMaxAgeMs   = 60 * 1000; // the desktop entries are read again after this long
        // ... or after this long when a look-up missed (an app just installed); refusals are remembered (Admission), so an
        // unverified publisher does not make the bridge read the entries again on each of its calls.
        constexpr qint64 kIndexRetryAgeMs = 30 * 1000;

        QByteArray readAtMost(const QByteArray& path, qsizetype max, bool* exists, bool* unreadable) {
            *exists     = false;
            *unreadable = false;
            const int fd = ::open(path.constData(), O_RDONLY | O_CLOEXEC | O_NOCTTY);
            if (fd < 0) {
                *unreadable = errno != ENOENT;
                return {};
            }
            *exists = true;
            QByteArray out;
            char       buf[4096];
            while (out.size() < max) {
                const ssize_t n = ::read(fd, buf, sizeof(buf));
                if (n <= 0)
                    break;
                out.append(buf, n);
            }
            ::close(fd);
            return out.left(max);
        }

        // The Pid line of /proc/self/fdinfo/<pidfd>: the process the pidfd pins (-1 once it exited), 0 when unreadable.
        qint64 pidOfPidfd(int fd) {
            bool             exists     = false;
            bool             unreadable = false;
            const QByteArray info       = readAtMost(QByteArrayLiteral("/proc/self/fdinfo/") + QByteArray::number(fd), 4096, &exists, &unreadable);
            for (const QByteArray& line : info.split('\n')) {
                if (line.startsWith("Pid:"))
                    return line.mid(4).trimmed().toLongLong();
            }
            return 0;
        }
    } // namespace

    OngoingObject::OngoingObject(Send send) : m_host(std::move(send)) {
        m_clock.start();
        m_sweep.setInterval(kSweepMs);
        QObject::connect(&m_sweep, &QTimer::timeout, this, [this] {
            m_host.expire(nowMs());
            if (!m_host.book().hasEnds())
                m_sweep.stop();
        });
    }

    OngoingObject::~OngoingObject() = default;

    void OngoingObject::setConnection(const QDBusConnection& connection) {
        if (m_watcher)
            return;
        m_bus     = connection;
        m_watcher = new QDBusServiceWatcher(this);
        m_watcher->setConnection(connection);
        m_watcher->setWatchMode(QDBusServiceWatcher::WatchForUnregistration);
        QObject::connect(m_watcher, &QDBusServiceWatcher::serviceUnregistered, this, [this](const QString& name) { dropSender(name); });
    }

    QString OngoingObject::introspect(const QString& /*path*/) const {
        return interfaceXml();
    }

    qint64 OngoingObject::nowMs() const {
        return QDateTime::currentMSecsSinceEpoch();
    }

    void OngoingObject::reply(const QDBusMessage& message, const QVariantList& values) {
        m_bus.send(message.createReply(values));
    }

    void OngoingObject::error(const QDBusMessage& message, const QString& name, const QString& text) {
        m_bus.send(message.createErrorReply(name, text));
    }

    bool OngoingObject::handleMessage(const QDBusMessage& message, const QDBusConnection& connection) {
        if (message.type() != QDBusMessage::MethodCallMessage)
            return true;
        if (answersByDefault(message.interface()))
            return false;
        if (answerForeignCall(message, connection, QLatin1String(kInterface)))
            return true; // another interface: answered (never dropped: the caller would wait 25 s)
        const QString sender = message.service();
        if (!sender.startsWith(u':')) {
            error(message, kDenied, QStringLiteral("the caller has no unique name"));
            return true;
        }
        if (message.member() == QLatin1String("Version")) {
            reply(message, {QStringLiteral("%1 ongoing/1").arg(QLatin1String(kBridgeVersion))});
            return true;
        }
        if (message.member() != QLatin1String("Publish") && message.member() != QLatin1String("End")) {
            error(message, kUnknownMethod, QStringLiteral("org.grassfield.Ongoing1 serves Publish, End and Version"));
            return true;
        }
        QHash<QString, bool> tracked; // connection -> verified
        for (auto p = m_peers.cbegin(); p != m_peers.cend(); ++p)
            tracked.insert(p.key(), p->stage == Peer::Stage::Ready);
        const Admission::Result admitted =
            m_admission.admit(sender, message.member(), m_clock.elapsed(), tracked, [this](const QString& s) { return m_host.holds(s); });
        for (const QString& idle : admitted.evicted)
            forgetPeer(idle); // verified, but holding nothing: its place goes to a publisher
        switch (admitted.outcome) {
            case Admission::Outcome::Admit: break;
            case Admission::Outcome::Refused: error(message, kDenied, admitted.message); return true;
            case Admission::Outcome::TooManyConnections:
            case Admission::Outcome::RateLimited: error(message, kLimits, admitted.message); return true;
        }
        auto it = m_peers.find(sender);
        if (it == m_peers.end()) {
            it = m_peers.insert(sender, Peer{});
            it->queued.append(message);
            // Watch first, then ask: a sender that leaves after the question is seen by the watch; one that left before is
            // answered with an error by the bus (the bus handles one connection's messages in order).
            if (m_watcher)
                m_watcher->addWatchedService(sender);
            resolve(sender);
            return true;
        }
        if (it->stage == Peer::Stage::Resolving) {
            if (it->queued.size() >= kMaxQueued)
                error(message, kLimits, QStringLiteral("too many calls before the caller's identity is known"));
            else
                it->queued.append(message);
            return true;
        }
        process(message, it->appId);
        return true;
    }

    void OngoingObject::ensureIndex(bool missed) {
        const bool stale = !m_indexAge.isValid() || m_indexAge.elapsed() > kIndexMaxAgeMs || (missed && m_indexAge.elapsed() > kIndexRetryAgeMs);
        if (!stale)
            return;
        m_index.scan(DesktopIndex::applicationDirs());
        m_indexAge.start();
    }

    void OngoingObject::resolve(const QString& sender) {
        QDBusMessage call = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.DBus"), QStringLiteral("/org/freedesktop/DBus"), QStringLiteral("org.freedesktop.DBus"),
                                                           QStringLiteral("GetConnectionCredentials"));
        call << sender;
        auto* w = new QDBusPendingCallWatcher(m_bus.asyncCall(call, kIdentityTimeoutMs), this);
        QObject::connect(w, &QDBusPendingCallWatcher::finished, this, [this, sender](QDBusPendingCallWatcher* watcher) {
            watcher->deleteLater();
            if (!m_peers.contains(sender))
                return; // left meanwhile
            const QDBusMessage m = watcher->reply();
            if (m.type() != QDBusMessage::ReplyMessage || m.arguments().isEmpty()) {
                resolved(sender, {{}, QStringLiteral("the bus does not know the caller")});
                return;
            }
            const QVariantMap creds = qdbus_cast<QVariantMap>(m.arguments().at(0));
            const QVariant    uidV  = creds.value(QStringLiteral("UnixUserID"));
            const QVariant    pidV  = creds.value(QStringLiteral("ProcessID"));
            if (!uidV.isValid() || !pidV.isValid() || pidV.toLongLong() <= 0) {
                resolved(sender, {{}, QStringLiteral("the bus gives no process for the caller")});
                return;
            }
            ProcReads reads;
            reads.uid = uidV.toUInt();
            reads.pid = pidV.toLongLong();
            // The pidfd, when the bus gives one: read again after the files, it says whether the process is still the same.
            int            pidfd = -1;
            const QVariant fdV   = creds.value(QStringLiteral("ProcessFD"));
            if (fdV.userType() == qMetaTypeId<QDBusUnixFileDescriptor>()) {
                const QDBusUnixFileDescriptor fd = fdV.value<QDBusUnixFileDescriptor>();
                if (fd.isValid())
                    pidfd = ::fcntl(fd.fileDescriptor(), F_DUPFD_CLOEXEC, 0);
            }
            bool             exists     = false;
            bool             unreadable = false;
            const QByteArray proc       = QByteArrayLiteral("/proc/") + QByteArray::number(reads.pid);
            reads.flatpakInfo           = readAtMost(proc + "/root/.flatpak-info", 64 * 1024, &exists, &unreadable);
            reads.flatpak               = exists;
            reads.rootUnreadable        = unreadable;
            reads.cgroup                = QString::fromUtf8(readAtMost(proc + "/cgroup", 8192, &exists, &unreadable));
            if (pidfd >= 0) {
                reads.pidfdPid = pidOfPidfd(pidfd);
                ::close(pidfd);
            }
            ensureIndex(false);
            Verdict v = judgeCaller(reads, ::getuid(), m_index);
            if (v.appId.isEmpty() && readProblem(reads).isEmpty() && reads.uid == ::getuid()) {
                ensureIndex(true); // an application installed since the last read
                v = judgeCaller(reads, ::getuid(), m_index);
            }
            resolved(sender, v);
        });
    }

    void OngoingObject::resolved(const QString& sender, const Verdict& verdict) {
        auto it = m_peers.find(sender);
        if (it == m_peers.end())
            return;
        const QList<QDBusMessage> queued = it->queued;
        if (verdict.appId.isEmpty()) {
            log(QStringLiteral("ongoing: refused %1: %2").arg(sender, verdict.error));
            // Nothing is kept for it but the refusal, answered from memory for kRefusalCacheMs.
            forgetPeer(sender);
            m_admission.refused(sender, verdict.error, m_clock.elapsed());
            for (const QDBusMessage& m : queued)
                error(m, kDenied, verdict.error);
            return;
        }
        it->stage = Peer::Stage::Ready;
        it->appId = verdict.appId;
        it->queued.clear();
        for (const QDBusMessage& m : queued)
            process(m, verdict.appId);
    }

    void OngoingObject::process(const QDBusMessage& message, const QString& appId) {
        const QString      sender = message.service();
        const QVariantList args   = message.arguments();
        if (message.member() == QLatin1String("End")) {
            if (message.signature() != QLatin1String("s") || args.size() != 1) {
                error(message, kInvalidArgs, QStringLiteral("End takes (s id)"));
                return;
            }
            reply(message);
            m_host.end(sender, appId, args.at(0).toString());
            return;
        }
        if (message.signature() != QLatin1String("sa{sv}") || args.size() != 2) {
            error(message, kInvalidArgs, QStringLiteral("Publish takes (s id, a{sv} state)"));
            return;
        }
        const auto input = inputFromDBus(args.at(1));
        if (!input) {
            error(message, kInvalidArgs, QStringLiteral("state must be a{sv}"));
            return;
        }
        const Host::Call c = m_host.publish(sender, appId, args.at(0).toString(), *input, nowMs());
        if (!c.ok) {
            error(message, c.error, c.message);
            return;
        }
        reply(message);
        if (m_host.book().hasEnds() && !m_sweep.isActive())
            m_sweep.start();
    }

    void OngoingObject::forgetPeer(const QString& sender) {
        if (m_watcher)
            m_watcher->removeWatchedService(sender);
        m_peers.remove(sender);
        m_admission.forget(sender);
    }

    void OngoingObject::dropSender(const QString& sender) {
        forgetPeer(sender);
        m_host.senderGone(sender);
    }

    QString OngoingObject::invoke(const QString& key, const QString& action) {
        const Host::Invocation inv = m_host.invoke(key, action);
        if (!inv.error.isEmpty())
            return inv.error;
        QDBusMessage signal = QDBusMessage::createTargetedSignal(inv.owner, QLatin1String(kPath), QLatin1String(kInterface), QStringLiteral("ActionInvoked"));
        signal << inv.localId << action;
        m_bus.send(signal);
        log(QStringLiteral("ongoing: %1 action \"%2\" of %3").arg(inv.appId, action, inv.localId));
        return {};
    }

} // namespace gf::menubridge::ongoing
