#include "DBusObjects.h"

#include "Log.h"
#include "Protocol.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusServiceWatcher>
#include <QTimer>

namespace gf::menubridge {

    QString diagnosticsInterfaceXml() {
        return QStringLiteral(R"XML(  <interface name="org.grassfield.MenuBridge1">
    <method name="Version">
      <arg name="version" type="s" direction="out"/>
    </method>
    <method name="Status">
      <arg name="status" type="a{sv}" direction="out"/>
    </method>
  </interface>
)XML");
    }

    QString RegistrarObject::introspect(const QString& /*path*/) const {
        return QStringLiteral(R"XML(  <interface name="com.canonical.AppMenu.Registrar">
    <method name="RegisterWindow"><arg name="windowId" type="u" direction="in"/><arg name="menuObjectPath" type="o" direction="in"/></method>
    <method name="UnregisterWindow"><arg name="windowId" type="u" direction="in"/></method>
    <method name="GetMenuForWindow"><arg name="windowId" type="u" direction="in"/><arg name="service" type="s" direction="out"/><arg name="menuObjectPath" type="o" direction="out"/></method>
    <method name="GetMenus"><arg name="menus" type="a(uso)" direction="out"/></method>
  </interface>
)XML");
    }

    bool answersByDefault(const QString& interface) {
        // Left to QtDBus (cheap, answers without any state): introspection and pings.
        return interface == QLatin1String("org.freedesktop.DBus.Introspectable") || interface == QLatin1String("org.freedesktop.DBus.Peer");
    }

    std::optional<ForeignAnswer> answerForeign(const QString& interface, const QString& member, const QString& signature, const QVariantList& args,
                                               const QString& own) {
        const auto error = [](const char* name, const QString& text) {
            ForeignAnswer a;
            a.error   = QString::fromLatin1(name);
            a.message = text;
            return a;
        };
        if (interface.isEmpty() || interface == own)
            return std::nullopt;
        if (interface == QLatin1String("org.freedesktop.DBus.Properties")) {
            if (member == QLatin1String("GetAll")) {
                if (signature != QLatin1String("s") || args.size() != 1)
                    return error("org.freedesktop.DBus.Error.InvalidArgs", QStringLiteral("GetAll takes (s interface)"));
                if (args.at(0).toString() != own && !args.at(0).toString().isEmpty())
                    return error("org.freedesktop.DBus.Error.UnknownInterface", QStringLiteral("no such interface on this object"));
                ForeignAnswer a;
                a.reply  = true;
                a.values = {QVariant(QVariantMap())}; // a{sv}, empty: this object has no properties
                return a;
            }
            if (member == QLatin1String("Get") || member == QLatin1String("Set")) {
                if (signature != (member == QLatin1String("Get") ? QLatin1String("ss") : QLatin1String("ssv")))
                    return error("org.freedesktop.DBus.Error.InvalidArgs", QStringLiteral("wrong arguments"));
                return error("org.freedesktop.DBus.Error.UnknownProperty", QStringLiteral("this object has no properties"));
            }
            return error("org.freedesktop.DBus.Error.UnknownMethod", QStringLiteral("org.freedesktop.DBus.Properties has Get, Set and GetAll"));
        }
        return error("org.freedesktop.DBus.Error.UnknownInterface", QStringLiteral("no such interface on this object"));
    }

    void sendReply(const QDBusMessage& call, const QDBusConnection& connection, const QVariantList& values) {
        if (call.isReplyRequired())
            connection.send(call.createReply(values));
    }

    void sendError(const QDBusMessage& call, const QDBusConnection& connection, const QString& name, const QString& text) {
        if (call.isReplyRequired())
            connection.send(call.createErrorReply(name, text));
    }

    bool answerForeignCall(const QDBusMessage& call, const QDBusConnection& connection, const QString& own) {
        const auto a = answerForeign(call.interface(), call.member(), call.signature(), call.arguments(), own);
        if (!a)
            return false;
        if (a->reply)
            sendReply(call, connection, a->values);
        else
            sendError(call, connection, a->error, a->message);
        return true;
    }

    RegistrarObject::RegistrarObject(std::function<void()> changed) : m_changed(std::move(changed)) {}

    RegistrarObject::~RegistrarObject() = default;

    void RegistrarObject::setConnection(const QDBusConnection& connection) {
        if (m_watcher)
            return;
        m_watcher = new QDBusServiceWatcher(this);
        m_watcher->setConnection(connection);
        m_watcher->setWatchMode(QDBusServiceWatcher::WatchForUnregistration);
        QObject::connect(m_watcher, &QDBusServiceWatcher::serviceUnregistered, this, [this](const QString& name) { dropSender(name); });
    }

    bool RegistrarObject::handleMessage(const QDBusMessage& message, const QDBusConnection& connection) {
        if (message.type() != QDBusMessage::MethodCallMessage)
            return true; // signals and replies are never for this object
        if (answersByDefault(message.interface()))
            return false;
        // Every call gets an answer (a caller waits out D-Bus's 25 s for a dropped one, ADR-0041 I-4).
        if (answerForeignCall(message, connection, QLatin1String(kRegistrarService)))
            return true;
        const QString           sender        = message.service();
        const bool              watchedBefore = m_book.holds(sender);
        const registrar::Answer a             = registrar::handle(m_book, message.member(), message.signature(), message.arguments(), sender);
        const QString key = sender + u' ' + message.member();
        if (!m_logged.contains(key) && m_logged.size() < 256) {
            m_logged.insert(key);
            log(QStringLiteral("registrar: %1 from %2 %3").arg(message.member(), sender, a.kind == registrar::Answer::Kind::Reply ? QStringLiteral("kept") : QStringLiteral("answered %1").arg(a.error)));
        }
        if (a.kind == registrar::Answer::Kind::Reply)
            sendReply(message, connection);
        else
            sendError(message, connection, a.error, a.message);
        // A new sender: watch it, THEN ask its pid (the bus daemon handles one connection's messages in order: either the
        // answer says it is gone, or its later departure is a NameOwnerChanged the watch receives).
        if (a.added && !watchedBefore && m_watcher) {
            m_watcher->addWatchedService(sender);
            askPid(connection, sender);
        }
        // Served once settled (Registrations.h: Electron registers before its menu object answers).
        if (a.added) {
            QTimer::singleShot(registrar::kSettleMs, this, [this, sender, windowId = a.windowId, seq = a.seq] {
                if (m_book.settle(sender, windowId, seq) && m_changed)
                    m_changed();
            });
        }
        if (a.removed && m_changed)
            m_changed();
        return true;
    }

    void RegistrarObject::askPid(const QDBusConnection& connection, const QString& sender) {
        QDBusMessage call = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.DBus"), QStringLiteral("/org/freedesktop/DBus"), QStringLiteral("org.freedesktop.DBus"),
                                                           QStringLiteral("GetConnectionUnixProcessID"));
        call << sender;
        auto* w = new QDBusPendingCallWatcher(connection.asyncCall(call, kPidTimeoutMs), this);
        QObject::connect(w, &QDBusPendingCallWatcher::finished, this, [this, sender](QDBusPendingCallWatcher* reply) {
            reply->deleteLater();
            const QDBusMessage m = reply->reply();
            if (m.type() != QDBusMessage::ReplyMessage || m.arguments().isEmpty()) {
                dropSender(sender); // gone, or no answer: a registration nobody can be tied to a process is useless
                return;
            }
            m_book.setPid(sender, m.arguments().at(0).toLongLong());
            if (m_changed)
                m_changed();
        });
    }

    void RegistrarObject::dropSender(const QString& sender) {
        if (m_watcher)
            m_watcher->removeWatchedService(sender);
        if (m_book.senderGone(sender) && m_changed)
            m_changed();
    }

    void RegistrarObject::clear() {
        if (m_watcher)
            m_watcher->setWatchedServices({});
        m_book.clear();
    }

    QString DiagnosticsObject::introspect(const QString& /*path*/) const {
        return diagnosticsInterfaceXml();
    }

    bool DiagnosticsObject::handleMessage(const QDBusMessage& message, const QDBusConnection& connection) {
        if (message.type() != QDBusMessage::MethodCallMessage)
            return true;
        if (answersByDefault(message.interface()))
            return false;
        if (answerForeignCall(message, connection, QLatin1String(kDiagnosticsService)))
            return true;
        const bool known = message.member() == QLatin1String("Version") || message.member() == QLatin1String("Status");
        if (!known) {
            sendError(message, connection, QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod"), QStringLiteral("org.grassfield.MenuBridge1 has Version and Status"));
            return true;
        }
        if (!message.arguments().isEmpty()) {
            sendError(message, connection, QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs"), QStringLiteral("takes no arguments"));
            return true;
        }
        if (message.member() == QLatin1String("Version"))
            sendReply(message, connection, {QStringLiteral("%1 %2").arg(QLatin1String(kBridgeVersion), QLatin1String(kProtocol))});
        else
            sendReply(message, connection, {QVariant(m_status())});
        return true;
    }

} // namespace gf::menubridge
