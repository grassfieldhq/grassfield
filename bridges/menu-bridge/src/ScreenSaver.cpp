#include "ScreenSaver.h"

#include "DBusObjects.h"
#include "Log.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusServiceWatcher>
#include <QRandomGenerator>

#include <algorithm>

namespace gf::menubridge::screensaver {

    namespace {
        const QString kLimits       = QStringLiteral("org.freedesktop.DBus.Error.LimitsExceeded");
        const QString kInvalidArgs  = QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs");
        const QString kNotSupported = QStringLiteral("org.freedesktop.DBus.Error.NotSupported");

        // An application name for the log: printable, bounded.
        QString cleanName(const QString& raw) {
            QString out;
            for (const QChar c : raw.left(kMaxText)) {
                if (c.isPrint())
                    out += c;
            }
            out = out.simplified();
            return out.isEmpty() ? QStringLiteral("an application") : out;
        }
    } // namespace

    Book::Taken Book::inhibit(const QString& sender, const QString& application) {
        Taken t;
        const int held = m_perSender.value(sender, 0);
        if (held >= kMaxPerSender || (held == 0 && static_cast<int>(m_perSender.size()) >= kMaxSenders)) {
            t.error = kLimits;
            return t;
        }
        if (m_next == 0)
            m_next = QRandomGenerator::global()->bounded(1u, 0x7fffffffu);
        // Next free non-zero cookie (at most kMaxPerSender * kMaxSenders are in use, so this ends at once in practice).
        while (m_next == 0 || m_entries.contains(m_next))
            ++m_next;
        t.ok     = true;
        t.cookie = m_next++;
        m_entries.insert(t.cookie, Entry{sender, cleanName(application)});
        m_perSender[sender] = held + 1;
        return t;
    }

    bool Book::uninhibit(const QString& sender, quint32 cookie) {
        const auto it = m_entries.constFind(cookie);
        if (it == m_entries.constEnd() || it->sender != sender)
            return false;
        m_entries.erase(it);
        if (--m_perSender[sender] <= 0)
            m_perSender.remove(sender);
        return true;
    }

    bool Book::senderGone(const QString& sender) {
        if (!m_perSender.contains(sender))
            return false;
        for (auto it = m_entries.begin(); it != m_entries.end();) {
            if (it->sender == sender)
                it = m_entries.erase(it);
            else
                ++it;
        }
        m_perSender.remove(sender);
        return true;
    }

    bool Book::holds(const QString& sender) const {
        return m_perSender.contains(sender);
    }

    QStringList Book::applications() const {
        QStringList out;
        for (const Entry& e : m_entries) {
            if (!out.contains(e.application))
                out << e.application;
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    Answer handle(Book& book, const QString& member, const QString& signature, const QVariantList& args, const QString& sender) {
        Answer a;
        if (!sender.startsWith(u':')) { // answered, never dropped: the caller would wait out D-Bus's 25 s (ADR-0041 I-4)
            a.error   = QStringLiteral("org.freedesktop.DBus.Error.AccessDenied");
            a.message = QStringLiteral("the caller has no unique name");
            return a;
        }
        if (member == QLatin1String("Inhibit")) {
            if (signature != QLatin1String("ss") || args.size() != 2) {
                a.error   = kInvalidArgs;
                a.message = QStringLiteral("Inhibit takes (s application, s reason)");
                return a;
            }
            const Book::Taken t = book.inhibit(sender, args.at(0).toString());
            if (!t.ok) {
                a.error   = t.error;
                a.message = QStringLiteral("too many inhibitors");
                return a;
            }
            a.kind    = Answer::Kind::Reply;
            a.values  = {QVariant::fromValue(t.cookie)};
            a.changed = true; // the application list changed, perhaps active() too
            return a;
        }
        if (member == QLatin1String("UnInhibit")) {
            if (signature != QLatin1String("u") || args.size() != 1) {
                a.error   = kInvalidArgs;
                a.message = QStringLiteral("UnInhibit takes (u cookie)");
                return a;
            }
            // An unknown cookie, or another connection's, is answered like a valid one (nothing to learn from it).
            a.kind    = Answer::Kind::Reply;
            a.changed = book.uninhibit(sender, args.at(0).toUInt());
            return a;
        }
        for (const char* known : {"Lock", "SetActive", "GetActive", "GetActiveTime", "GetSessionIdleTime", "SimulateUserActivity", "Throttle", "UnThrottle"}) {
            if (member == QLatin1String(known)) {
                a.error   = kNotSupported;
                a.message = QStringLiteral("only Inhibit and UnInhibit are served (Grassfield's lock is not controlled over D-Bus)");
                return a;
            }
        }
        a.error   = QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod");
        a.message = QStringLiteral("org.freedesktop.ScreenSaver has no such method");
        return a;
    }

    QString interfaceXml() {
        return QStringLiteral(R"XML(  <interface name="org.freedesktop.ScreenSaver">
    <method name="Inhibit"><arg name="application_name" type="s" direction="in"/><arg name="reason_for_inhibit" type="s" direction="in"/><arg name="cookie" type="u" direction="out"/></method>
    <method name="UnInhibit"><arg name="cookie" type="u" direction="in"/></method>
  </interface>
)XML");
    }

    ScreenSaverObject::ScreenSaverObject(Changed changed) : m_changed(std::move(changed)) {}

    ScreenSaverObject::~ScreenSaverObject() = default;

    void ScreenSaverObject::setConnection(const QDBusConnection& connection) {
        if (m_watcher)
            return;
        m_watcher = new QDBusServiceWatcher(this);
        m_watcher->setConnection(connection);
        m_watcher->setWatchMode(QDBusServiceWatcher::WatchForUnregistration);
        QObject::connect(m_watcher, &QDBusServiceWatcher::serviceUnregistered, this, [this](const QString& name) { dropSender(name); });
    }

    QString ScreenSaverObject::introspect(const QString& /*path*/) const {
        return interfaceXml();
    }

    bool ScreenSaverObject::handleMessage(const QDBusMessage& message, const QDBusConnection& connection) {
        if (message.type() != QDBusMessage::MethodCallMessage)
            return true; // signals and replies are never for this object
        if (answersByDefault(message.interface()))
            return false;
        // Calls without an interface are taken as this interface's (libdbus allows it). Every other call is answered too: a
        // proxy that asks Properties.GetAll waits out D-Bus's 25 s on a dropped call (ADR-0041 I-4).
        if (answerForeignCall(message, connection, QLatin1String(kInterface)))
            return true;
        const QString sender = message.service();
        const bool   watchedBefore = m_book.holds(sender);
        const Answer a             = handle(m_book, message.member(), message.signature(), message.arguments(), sender);
        // A new holder: watch it, THEN ask the bus whether it is still there. A sender that left before the watch existed
        // never sends a NameOwnerChanged this bridge could see (review of 4b8592d: cookies of clients that sent Inhibit
        // and exited at once were kept for the whole session, holding the idle lock off). The bus daemon handles one
        // connection's messages in order, so the AddMatch of the watch precedes the NameHasOwner: either the answer
        // says the name is gone, or the name's later departure is a NameOwnerChanged the watch receives.
        if (m_watcher && !watchedBefore && m_book.holds(sender)) {
            m_watcher->addWatchedService(sender);
            confirmPresent(connection, sender);
        }
        if (a.kind == Answer::Kind::Reply)
            sendReply(message, connection, a.values);
        else
            sendError(message, connection, a.error, a.message);
        if (a.changed)
            report();
        return true;
    }

    void ScreenSaverObject::confirmPresent(const QDBusConnection& connection, const QString& sender) {
        QDBusMessage call = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.DBus"), QStringLiteral("/org/freedesktop/DBus"), QStringLiteral("org.freedesktop.DBus"),
                                                           QStringLiteral("NameHasOwner"));
        call << sender;
        auto* w = new QDBusPendingCallWatcher(connection.asyncCall(call, kConfirmTimeoutMs), this);
        QObject::connect(w, &QDBusPendingCallWatcher::finished, this, [this, sender](QDBusPendingCallWatcher* reply) {
            reply->deleteLater();
            const QDBusMessage m       = reply->reply();
            const bool         present = m.type() == QDBusMessage::ReplyMessage && !m.arguments().isEmpty() && m.arguments().at(0).toBool();
            // Gone, or no answer (fail closed: an inhibitor nobody can be shown to hold is dropped; idle locking stays on).
            if (!present)
                dropSender(sender);
        });
    }

    void ScreenSaverObject::dropSender(const QString& sender) {
        if (m_watcher)
            m_watcher->removeWatchedService(sender);
        if (m_book.senderGone(sender))
            report();
    }

    void ScreenSaverObject::report() {
        const bool        active = m_book.active();
        const QStringList apps   = m_book.applications();
        if (active == m_reportedActive && apps == m_reported)
            return;
        m_reportedActive = active;
        m_reported       = apps;
        if (m_changed)
            m_changed(active, m_book.count(), apps);
    }

} // namespace gf::menubridge::screensaver
