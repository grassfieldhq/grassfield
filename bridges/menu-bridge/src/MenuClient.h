#pragma once

// DBusMenu client of one window (com.canonical.dbusmenu at a verified unique bus name and object path).
//
// Chromium exports no introspection data, so every call is built with explicit D-Bus types:
//   GetLayout(int32 0, int32 -1, as [])  ->  (uint32 revision, (ia{sv}av) layout)
//   AboutToShow(int32 id)                ->  bool needUpdate
//   Event(int32 id, "clicked", variant<int32 0>, uint32 timestamp)
// LayoutUpdated and ItemsPropertiesUpdated trigger a (coalesced) new GetLayout. A failed first GetLayout is tried again a
// few times; a menu shown before keeps its last layout when a re-read fails. The menu is dropped when the service leaves
// the bus (NameOwnerChanged). Only ids present in the latest layout are ever sent to the app.

#include "Layout.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusServiceWatcher>
#include <QJsonArray>
#include <QObject>
#include <QString>
#include <QTimer>

#include <functional>

namespace gf::menubridge {

    class MenuClient : public QObject {
        Q_OBJECT

      public:
        MenuClient(const QDBusConnection& bus, QString window, QString service, QString path, QObject* parent = nullptr);
        ~MenuClient() override;

        MenuClient(const MenuClient&)            = delete;
        MenuClient& operator=(const MenuClient&) = delete;

        // Subscribes to the menu's signals and fetches the layout.
        void start();
        // The re-read budget (Penalties.h RefetchBudget, per identity): asked before every re-read a signal or AboutToShow
        // asks for (not the first read or its retries). 0: read now; > 0: ask again in that many ms (the layout keeps its
        // last state meanwhile); < 0: a sustained flood, the menu is given up with the code "flood". Unset: no limit.
        void setRefetchGate(std::function<qint64()> gate) {
            m_gate = std::move(gate);
        }

        // AboutToShow on a submenu of the latest layout (false: unknown id, nothing sent).
        bool aboutToShow(int id);
        // Event "clicked" on an enabled leaf of the latest layout (false: unknown or inactive id, nothing sent).
        bool activate(int id);

        const QString& window() const {
            return m_window;
        }
        const QString& service() const {
            return m_service;
        }
        const QString& path() const {
            return m_path;
        }
        // The latest mapped layout (empty before the first GetLayout reply).
        const QJsonArray& items() const {
            return m_items;
        }
        bool ready() const {
            return m_ready;
        }
        // Calls sent to the application whose reply has not been handled yet.
        int outstanding() const {
            return m_outstanding;
        }

      signals:
        void menuChanged(const QString& window);
        // Every outbound call (GetLayout, AboutToShow, Event) is announced before it is sent and when its reply (or
        // timeout) has been handled: the application's reply is the one thing that can make the bridge allocate, so the
        // bridge records the calls in flight to blame the application if it dies meanwhile.
        void callBegun();
        void callEnded();
        // code: "gone", "layout-failed", "oversized" or "flood". After it the client sends nothing more.
        void failed(const QString& window, const QString& code, const QString& message);

      private slots:
        void onMenuSignal(const QDBusMessage& message);

      private:
        void fetch();
        void scheduleRefetch();
        // m_refetch fired: a re-read if the gate allows it.
        void refetchDue();
        // `retry`: the first read may be tried again (the application did not answer; a malformed answer is final).
        void fail(const QString& code, const QString& why, bool retry);
        void giveUp(const QString& code, const QString& why);
        void handleLayout(const QDBusMessage& reply);
        // Sends `message`, announces it and runs `handler` with the reply.
        void track(const QDBusMessage& message, std::function<void(const QDBusMessage&)> handler);

        QDBusConnection     m_bus;
        QString             m_window;
        QString             m_service;
        QString             m_path;
        QDBusServiceWatcher m_watcher;
        QTimer              m_refetch;
        QTimer              m_retry; // the next read after a failed one (a first read, or a re-read a signal arrived during)
        QJsonArray          m_items;
        ItemIndex           m_index;
        bool                m_ready    = false;
        bool                m_fetching = false;
        bool                m_again    = false;
        bool                m_gone     = false;
        bool                m_stopped  = false; // gave up (failure or oversized layout): no further GetLayout
        int                 m_failures = 0;     // consecutive failed reads (first reads, or re-reads once shown)
        int                 m_outstanding = 0;
        std::function<qint64()> m_gate;
    };

} // namespace gf::menubridge
