#include "LauncherWatcher.h"

#include "Log.h"
#include "Protocol.h"

#include <QDBusArgument>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>

#include <algorithm>
#include <utility>

namespace gf::menubridge {

    namespace {
        constexpr char kInterface[]       = "com.canonical.Unity.LauncherEntry";
        constexpr char kMember[]          = "Update";
        constexpr int  kFlushMs           = 50;
        constexpr int  kDBusTimeoutMs     = 2000;
    } // namespace

    LauncherWatcher::LauncherWatcher(const QDBusConnection& bus, Hooks hooks, QObject* parent)
        : QObject(parent), m_bus(bus), m_hooks(std::move(hooks)), m_watcher(this) {
        m_watcher.setConnection(m_bus);
        m_watcher.setWatchMode(QDBusServiceWatcher::WatchForUnregistration);
        connect(&m_watcher, &QDBusServiceWatcher::serviceUnregistered, this, [this](const QString& name) { gone(name); });
        m_flush.setInterval(kFlushMs);
        connect(&m_flush, &QTimer::timeout, this, [this] { flush(); });
        m_clock.start();
    }

    LauncherWatcher::~LauncherWatcher() {
        stop();
    }

    void LauncherWatcher::start() {
        if (m_started)
            return;
        m_started = m_bus.connect(QString(), QString(), QLatin1String(kInterface), QLatin1String(kMember), this, SLOT(onUpdate(QDBusMessage)));
        if (!m_started)
            log(QStringLiteral("cannot subscribe to %1.%2: application badges are not served").arg(QLatin1String(kInterface), QLatin1String(kMember)));
    }

    void LauncherWatcher::stop() {
        if (m_started)
            m_bus.disconnect(QString(), QString(), QLatin1String(kInterface), QLatin1String(kMember), this, SLOT(onUpdate(QDBusMessage)));
        m_started = false;
        m_flush.stop();
    }

    QList<QByteArray> LauncherWatcher::snapshot() const {
        QList<QByteArray> out;
        for (const launcher::Update& u : m_book.snapshot())
            out.append(launcherMessage(u.app, u.count, u.progress, u.urgent));
        return out;
    }

    void LauncherWatcher::forward(const std::vector<launcher::Update>& updates) {
        for (const launcher::Update& u : updates)
            Q_EMIT line(launcherMessage(u.app, u.count, u.progress, u.urgent));
    }

    void LauncherWatcher::malformed(const QString& sender) {
        const Peer peer = m_peers.value(sender);
        if (peer.resolved && m_hooks.strike)
            m_hooks.strike(peer.identity);
    }

    void LauncherWatcher::handled(const QString& sender, const launcher::Book::Result& r) {
        if (r.malformed)
            malformed(sender); // also a signal of the wrong signature: its uri is empty, so the Book calls it malformed
        if (r.foreign) {
            auto it = m_peers.find(sender);
            if (it != m_peers.end() && !std::exchange(it->toldForeign, true))
                log(QStringLiteral("LauncherEntry: \"%1\" may only set its own application's badge: an update for another one was dropped").arg(displayIdentity(it->identity)));
        }
        forward(r.forward);
        if (m_book.hasPending() && !m_flush.isActive())
            m_flush.start();
    }

    void LauncherWatcher::resolve(const QString& sender) {
        QDBusMessage call = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.DBus"), QStringLiteral("/org/freedesktop/DBus"), QStringLiteral("org.freedesktop.DBus"),
                                                           QStringLiteral("GetConnectionUnixProcessID"));
        call << sender;
        auto* w = new QDBusPendingCallWatcher(m_bus.asyncCall(call, kDBusTimeoutMs), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [this, sender](QDBusPendingCallWatcher* reply) {
            reply->deleteLater();
            auto it = m_peers.find(sender);
            if (it == m_peers.end())
                return;
            const QDBusMessage msg = reply->reply();
            if (msg.type() != QDBusMessage::ReplyMessage || msg.arguments().isEmpty()) {
                // The sender left before we could look at it (or the bus does not know it).
                gone(sender);
                return;
            }
            it->identity      = appIdentity(msg.arguments().at(0).toLongLong());
            it->resolved      = true;
            const bool refused = m_hooks.refused && m_hooks.refused(it->identity);
            handled(sender, m_book.setIdentity(sender, it->identity, m_clock.elapsed(), !refused));
        });
    }

    void LauncherWatcher::dropPeer(const QString& sender) {
        m_peers.remove(sender);
        m_watcher.removeWatchedService(sender);
    }

    void LauncherWatcher::gone(const QString& sender) {
        if (!m_peers.contains(sender))
            return;
        dropPeer(sender);
        forward(m_book.senderGone(sender));
        if (!m_book.hasPending())
            m_flush.stop();
    }

    void LauncherWatcher::flush() {
        forward(m_book.flush(m_clock.elapsed()));
        if (!m_book.hasPending())
            m_flush.stop();
    }

    void LauncherWatcher::onUpdate(const QDBusMessage& message) {
        if (message.type() != QDBusMessage::SignalMessage)
            return;
        const QString sender = message.service();
        if (sender.isEmpty() || !sender.startsWith(u':'))
            return;
        // Unknown sender: it takes a place in the Book (a refused or idle sender may give up its own, B-16), is watched (its
        // apps are cleared when it leaves) and identified; its updates wait in the Book until then (B-17).
        if (!m_peers.contains(sender)) {
            QString evicted;
            if (!m_book.awaitIdentity(sender, &evicted))
                return;
            if (!evicted.isEmpty())
                dropPeer(evicted);
            m_peers.insert(sender, Peer{});
            m_watcher.addWatchedService(sender);
            resolve(sender);
        }
        const Peer& peer = m_peers.value(sender);
        if (peer.resolved && m_hooks.refused && m_hooks.refused(peer.identity))
            return;

        QString     uri;
        QVariantMap props;
        bool        wellFormed = message.signature() == QLatin1String("sa{sv}") && message.arguments().size() == 2 && message.arguments().at(0).typeId() == QMetaType::QString;
        if (wellFormed) {
            uri   = message.arguments().at(0).toString();
            props = qdbus_cast<QVariantMap>(message.arguments().at(1));
        }
        const launcher::Book::Result r = m_book.submit(sender, wellFormed ? uri : QString(), props, m_clock.elapsed());
        if (!r.evicted.isEmpty())
            dropPeer(r.evicted);
        handled(sender, r);
    }

} // namespace gf::menubridge
