#pragma once

#include "signalqueue.h"
#include "systembus.h"

#include <QDBusConnection>
#include <QDBusError>
#include <QDBusMessage>
#include <QEventLoop>
#include <QTimer>

#include <memory>
#include <mutex>

namespace grassfield::settings {

// The real caller: blocking calls on a D-Bus connection (the one of SystemBusConnection; the bus is the system bus, which Qt takes from DBUS_SYSTEM_BUS_ADDRESS when it is set: the integration tests point it at
// a private bus).
class QtBusCaller : public BusCaller
{
public:
    explicit QtBusCaller(const QDBusConnection &connection)
        : m_connection(connection)
    {
    }

    // On the thread that made it (the job's): the signal it listened to is let go before its queue goes.
    ~QtBusCaller() override
    {
        if (m_queue)
            m_connection.disconnect(m_service, m_path, m_iface, m_member, m_queue.get(), SLOT(take(QDBusMessage)));
    }

    BusReply call(const QString &service, const QString &path, const QString &iface, const QString &member, const QVariantList &args, int timeoutMs) override
    {
        BusReply out;
        if (!m_connection.isConnected()) {
            out.error = QStringLiteral("org.freedesktop.DBus.Error.NoServer: no connection to the system bus"); // i18n-ignore: an error name, mapped to text by reasonOf
            return out;
        }
        QDBusMessage message = QDBusMessage::createMethodCall(service, path, iface, member);
        message.setArguments(args);
        // The desktop portal is never started from here (systembus.cpp, kDBusName): starting it on a dev session's private bus
        // would start the document portal, which remounts the owner's $XDG_RUNTIME_DIR/doc.
        message.setAutoStartService(service != QLatin1String("org.freedesktop.portal.Desktop"));
        // A call that changes something may wait for the polkit agent (ADR-0045 OC-0.7): systemd asks it only when the message
        // allows it (sd_bus_message_get_allow_interactive_authorization); the other services ask it anyway. A read never does.
        message.setInteractiveAuthorizationAllowed(!isReadOnlyCall(service, iface, member, args));
        const QDBusMessage reply = m_connection.call(message, QDBus::Block, timeoutMs);
        if (reply.type() == QDBusMessage::ErrorMessage) {
            out.error = reply.errorName() + QStringLiteral(": ") + reply.errorMessage();
            return out;
        }
        out.ok = true;
        out.args = reply.arguments();
        return out;
    }

    bool listen(const QString &service, const QString &path, const QString &iface, const QString &member) override
    {
        if (m_queue || !m_connection.isConnected())
            return false;
        auto queue = std::make_unique<SignalQueue>();
        if (!m_connection.connect(service, path, iface, member, queue.get(), SLOT(take(QDBusMessage))))
            return false;
        m_queue = std::move(queue);
        m_service = service;
        m_path = path;
        m_iface = iface;
        m_member = member;
        return true;
    }

    // A local event loop on the job's thread: Qt D-Bus delivers the signals there; the timer or the first signal ends it.
    BusReply nextSignal(int timeoutMs) override
    {
        BusReply out;
        if (m_queue && m_queue->kept.isEmpty()) {
            QEventLoop loop;
            QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
            m_queue->waiting = &loop;
            loop.exec();
            m_queue->waiting = nullptr;
        }
        if (!m_queue || m_queue->kept.isEmpty()) {
            out.error = QStringLiteral("org.freedesktop.DBus.Error.Timeout: no signal"); // i18n-ignore: an error name, mapped to text by reasonOf
            return out;
        }
        out.ok = true;
        out.args = m_queue->kept.takeFirst();
        return out;
    }

private:
    QDBusConnection m_connection;
    std::unique_ptr<SignalQueue> m_queue;
    QString m_service, m_path, m_iface, m_member;
};

// The ONE connection to one bus of the Settings app (made lazily, on a worker thread, never on the GUI thread: a bus that
// stalls during the connect blocks that worker only), shared by every job on that bus and made again when the bus went away. The
// system bus serves Wi-Fi, Bluetooth and the General pane's services; the session bus, the user's own service manager.
class SystemBusConnection
{
public:
    explicit SystemBusConnection(QDBusConnection::BusType type = QDBusConnection::SystemBus,
                                 const QString &name = QStringLiteral("gf-settings-system-bus")) // i18n-ignore: a connection name
        : m_type(type)
        , m_name(name)
    {
    }
    // The connection's name (QDBusConnection(name) reaches it from any thread once caller() made it).
    QString name() const { return m_name; }
    ~SystemBusConnection()
    {
        if (m_made)
            QDBusConnection::disconnectFromBus(m_name);
    }
    std::shared_ptr<BusCaller> caller()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_made) {
            const QDBusConnection existing(m_name);
            if (existing.isConnected())
                return std::make_shared<QtBusCaller>(existing);
            QDBusConnection::disconnectFromBus(m_name);
            m_made = false;
        }
        const QDBusConnection fresh = QDBusConnection::connectToBus(m_type, m_name);
        m_made = true;
        return std::make_shared<QtBusCaller>(fresh);
    }

private:
    std::mutex m_mutex;
    const QDBusConnection::BusType m_type;
    const QString m_name;
    bool m_made = false;
};

} // namespace grassfield::settings
