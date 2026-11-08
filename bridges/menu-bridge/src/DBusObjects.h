#pragma once

// D-Bus objects exported by grassfield-menu-bridge.
//
// Registrar (com.canonical.AppMenu.Registrar at /com/canonical/AppMenu/Registrar): it EXISTS while the whole
// global-menu chain works, because Qt and Chromium export their menus (and announce them through
// org_kde_kwin_appmenu) only when this name is owned; Qt and Chromium never call it on Wayland (spike S5). Electron
// does (ADR-0008 amendment 2026-10-25): its registrations are kept per sender (Registrations.h) and served to the
// windows of the sender's process:
//   RegisterWindow(u, o), UnregisterWindow(u) -> () kept / forgotten (LimitsExceeded past the caps)
//   GetMenuForWindow(u)                      -> com.canonical.AppMenu.Registrar.Error.NotFound
//   GetMenus()                               -> org.freedesktop.DBus.Error.NotSupported
// Every method call gets a reply unless it asked for none (NoReplyExpected): an unknown member is UnknownMethod, an
// unknown interface UnknownInterface, and org.freedesktop.DBus.Properties is answered for an object with no properties
// (answerForeign below). A caller that waits for an answer (a codegen proxy's GetAll, xdg-desktop-portal-gtk's, ADR-0041
// I-4) must never wait out D-Bus's 25 s method timeout on a call dropped here. A sender that registers is watched; its pid is asked from the bus daemon once
// (its departure, or no answer, drops its registrations).
//
// Diagnostics (org.grassfield.MenuBridge1 at /org/grassfield/MenuBridge1, XML in bridges/menu-bridge/dbus/):
//   Version() -> s      "<bridge version> menu/1"
//   Status()  -> a{sv}  {"state": s, "registrar": b, "degraded": b, "shell": b, "menus": u}

#include "Registrations.h"

#include <QDBusConnection>
#include <QDBusVirtualObject>
#include <QSet>
#include <QString>
#include <QVariantMap>

#include <functional>
#include <optional>

class QDBusServiceWatcher;

namespace gf::menubridge {

    inline constexpr char kRegistrarService[]   = "com.canonical.AppMenu.Registrar";
    inline constexpr char kRegistrarPath[]      = "/com/canonical/AppMenu/Registrar";
    inline constexpr char kDiagnosticsService[] = "org.grassfield.MenuBridge1";
    inline constexpr char kDiagnosticsPath[]    = "/org/grassfield/MenuBridge1";

    // True for the interfaces QtDBus answers on its own (introspection, peer ping).
    bool answersByDefault(const QString& interface);

    // What to answer a call that is not for the object's own interface `own` (an empty interface counts as `own`: libdbus
    // allows it). The objects here have no properties: org.freedesktop.DBus.Properties.GetAll gives an empty a{sv} for `own`
    // (UnknownInterface for another interface), Get and Set give UnknownProperty, a wrong signature InvalidArgs, any other
    // Properties member UnknownMethod; every other interface is UnknownInterface. Pure; nullopt = the call is for `own`.
    struct ForeignAnswer {
        bool         reply = false; // true: a reply with `values`; false: the error `error`
        QVariantList values;
        QString      error;
        QString      message;
    };
    std::optional<ForeignAnswer> answerForeign(const QString& interface, const QString& member, const QString& signature, const QVariantList& args,
                                               const QString& own);

    // Sends the answer to a method call, except when the caller asked for none (NoReplyExpected).
    void sendReply(const QDBusMessage& call, const QDBusConnection& connection, const QVariantList& values = {});
    void sendError(const QDBusMessage& call, const QDBusConnection& connection, const QString& name, const QString& text);

    // answerForeign + send: true when the call was not for `own` and has been answered.
    bool answerForeignCall(const QDBusMessage& call, const QDBusConnection& connection, const QString& own);

    // The <interface> element of org.grassfield.MenuBridge1, identical to the one in
    // bridges/menu-bridge/dbus/org.grassfield.MenuBridge1.xml (checked by a unit test).
    QString diagnosticsInterfaceXml();

    class RegistrarObject : public QDBusVirtualObject {
      public:
        // `changed` runs after every change of the book that can matter to a waiting or open window: a registration
        // settled (registrar::kSettleMs after it was kept) or forgotten, a sender's pid learnt, a sender gone.
        explicit RegistrarObject(std::function<void()> changed = {});
        ~RegistrarObject() override;

        RegistrarObject(const RegistrarObject&)            = delete;
        RegistrarObject& operator=(const RegistrarObject&) = delete;

        // Attaches the sender watcher and the pid queries to `connection` (call once, before the object is registered).
        void    setConnection(const QDBusConnection& connection);
        QString introspect(const QString& path) const override;
        bool    handleMessage(const QDBusMessage& message, const QDBusConnection& connection) override;

        const registrar::Book& book() const {
            return m_book;
        }
        // Forgets every registration (the registrar name was released: applications register again when it returns).
        void clear();

      private:
        static constexpr int kPidTimeoutMs = 2000;
        // Asks the bus daemon for `sender`'s process (after its watch was added: a sender that left before is answered
        // with an error and dropped, a later departure reaches the watch).
        void askPid(const QDBusConnection& connection, const QString& sender);
        void dropSender(const QString& sender);

        registrar::Book       m_book;
        std::function<void()> m_changed;
        QDBusServiceWatcher*  m_watcher = nullptr;
        QSet<QString>         m_logged; // "<sender> <member>": one log line each
    };

    class DiagnosticsObject : public QDBusVirtualObject {
      public:
        explicit DiagnosticsObject(std::function<QVariantMap()> status) : m_status(std::move(status)) {}

        QString introspect(const QString& path) const override;
        bool    handleMessage(const QDBusMessage& message, const QDBusConnection& connection) override;

      private:
        std::function<QVariantMap()> m_status;
    };

} // namespace gf::menubridge
