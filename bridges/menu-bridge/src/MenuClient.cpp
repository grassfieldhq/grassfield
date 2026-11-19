#include "MenuClient.h"

#include "Log.h"
#include "Memory.h"

#include <QDBusArgument>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>

#include <algorithm>
#include <utility>

namespace gf::menubridge {

    namespace {
        const QString kInterface = QStringLiteral("com.canonical.dbusmenu");
        constexpr int kCallTimeoutMs = 3000;
        // Bursts of LayoutUpdated / ItemsPropertiesUpdated collapse into one GetLayout.
        constexpr int kRefetchDelayMs = 40;
        // A first read that fails is tried again after kRetryDelayMs, doubled each time (0.5, 1, 2 s): an application busy
        // for longer than a call's timeout (Files drawing the Applications location on a loaded machine: GetLayout NoReply)
        // or whose menu object is not exported yet gets its menu once it answers; the fourth failed first read is given up.
        constexpr int kFirstReadTries = 4;
        constexpr int kRetryDelayMs   = 500;
        // A menu shown before keeps its last layout when a re-read fails (macOS keeps a busy application's menus): the bridge
        // does not read it again by itself, the application's next signal does (or one that arrived during the failed read,
        // after kRetryDelayMs), and it is given up only after this many failed re-reads in a row.
        constexpr int kMaxRereadFailures = 3;
    } // namespace

    MenuClient::MenuClient(const QDBusConnection& bus, QString window, QString service, QString path, QObject* parent) :
        QObject(parent), m_bus(bus), m_window(std::move(window)), m_service(std::move(service)), m_path(std::move(path)) {
        m_refetch.setSingleShot(true);
        m_refetch.setInterval(kRefetchDelayMs);
        connect(&m_refetch, &QTimer::timeout, this, &MenuClient::refetchDue);
        m_retry.setSingleShot(true);
        connect(&m_retry, &QTimer::timeout, this, &MenuClient::fetch);

        m_watcher.setConnection(m_bus);
        m_watcher.setWatchMode(QDBusServiceWatcher::WatchForUnregistration);
        m_watcher.addWatchedService(m_service);
        connect(&m_watcher, &QDBusServiceWatcher::serviceUnregistered, this, [this](const QString&) {
            if (m_gone)
                return;
            m_gone = true;
            m_refetch.stop();
            m_retry.stop();
            emit failed(m_window, QStringLiteral("gone"), QStringLiteral("the application left the bus"));
        });
    }

    MenuClient::~MenuClient() {
        m_bus.disconnect(m_service, m_path, kInterface, QStringLiteral("LayoutUpdated"), this, SLOT(onMenuSignal(QDBusMessage)));
        m_bus.disconnect(m_service, m_path, kInterface, QStringLiteral("ItemsPropertiesUpdated"), this, SLOT(onMenuSignal(QDBusMessage)));
    }

    void MenuClient::start() {
        // A slot taking only a QDBusMessage accepts any signature: the signal arguments are not trusted or needed,
        // the layout is re-read instead.
        m_bus.connect(m_service, m_path, kInterface, QStringLiteral("LayoutUpdated"), this, SLOT(onMenuSignal(QDBusMessage)));
        m_bus.connect(m_service, m_path, kInterface, QStringLiteral("ItemsPropertiesUpdated"), this, SLOT(onMenuSignal(QDBusMessage)));
        fetch();
    }

    void MenuClient::onMenuSignal(const QDBusMessage& /*message*/) {
        scheduleRefetch();
    }

    void MenuClient::scheduleRefetch() {
        // Not restarted while pending: a burst of signals less than kRefetchDelayMs apart would otherwise push the
        // refetch back for as long as it lasts. During a burst the layout is read at most every kRefetchDelayMs.
        if (!m_gone && !m_stopped && !m_refetch.isActive())
            m_refetch.start(kRefetchDelayMs);
    }

    void MenuClient::refetchDue() {
        if (m_gone || m_stopped)
            return;
        // The application's re-reads are budgeted per identity (all its windows): a flood of LayoutUpdated costs at most
        // one GetLayout a second once the burst is spent, and a flood that lasts drops the menu (Bridge records it).
        const qint64 wait = m_gate ? m_gate() : 0;
        if (wait < 0) {
            giveUp(QStringLiteral("flood"), QStringLiteral("the application changes its menu continuously"));
            return;
        }
        if (wait > 0) {
            m_refetch.start(static_cast<int>(std::min<qint64>(wait, 60 * 1000)));
            return;
        }
        fetch();
    }

    void MenuClient::fetch() {
        if (m_gone || m_stopped)
            return;
        if (m_fetching) {
            m_again = true;
            return;
        }
        m_fetching = true;
        track(getLayoutCall(m_service, m_path), [this](const QDBusMessage& reply) {
            m_fetching = false;
            if (m_gone || m_stopped)
                return;
            handleLayout(reply);
        });
    }

    void MenuClient::handleLayout(const QDBusMessage& reply) {
        if (reply.type() != QDBusMessage::ReplyMessage || reply.signature() != QLatin1String("u(ia{sv}av)") || reply.arguments().size() != 2) {
            const bool error = reply.type() == QDBusMessage::ErrorMessage;
            const QString why = error ? reply.errorName() : QStringLiteral("unexpected reply signature %1").arg(reply.signature());
            log(QStringLiteral("window %1: GetLayout on %2 %3 failed: %4").arg(m_window, m_service, m_path, why));
            // No answer (NoReply, or no menu object yet: an error) may come later; a reply of the wrong shape will not.
            fail(QStringLiteral("layout-failed"), why, error);
            return;
        }
        RawItem      root;
        LayoutBudget readBudget;
        if (!readLayout(qvariant_cast<QDBusArgument>(reply.arguments().at(1)), root, 0, readBudget)) {
            fail(QStringLiteral("layout-failed"), QStringLiteral("malformed layout"), false);
            return;
        }
        if (readBudget.truncated) {
            // More items or levels than any real menu has: the application is not trusted any more, its menu is not
            // shown and no further GetLayout is sent (the bridge remembers the refusal, see PenaltyBook).
            log(QStringLiteral("window %1: menu of %2 has more than %3 items or %4 levels: refused").arg(m_window, m_service).arg(limits::kItems).arg(limits::kDepth));
            m_stopped = true;
            m_refetch.stop();
            m_retry.stop();
            emit failed(m_window, QStringLiteral("oversized"), QStringLiteral("the menu is larger than the supported limits"));
            return;
        }
        m_failures = 0;
        m_retry.stop();
        LayoutBudget mapBudget;
        const QJsonArray items = mapChildren(root, mapBudget);
        // A re-read that changed nothing the shell is given (an application signalling without a change, or a property the
        // mapping does not keep) is not sent again: the shell would parse the whole menu and build its bar anew.
        const bool same = m_ready && items == m_items;
        m_items = items;
        m_index = indexItems(m_items);
        m_ready = true;
        if (!same)
            emit menuChanged(m_window);
        if (std::exchange(m_again, false))
            fetch();
    }

    void MenuClient::fail(const QString& code, const QString& why, bool retry) {
        ++m_failures;
        if (m_ready) {
            // A re-read: the last good layout stays shown; the application's next signal reads it again.
            if (m_failures >= kMaxRereadFailures) {
                giveUp(code, why);
                return;
            }
            // A signal that arrived during the failed read would otherwise be lost with it (the menu changed while the
            // application was busy): that one is read again, later; its failure counts toward the limit above.
            if (std::exchange(m_again, false))
                m_retry.start(kRetryDelayMs);
            return;
        }
        // The first read: tried again later when the application did not answer (it used to fail at once, and a window whose
        // application was busy past the timeout showed the T0 menus until its next focus); never for a malformed answer.
        if (!retry || m_failures >= kFirstReadTries) {
            giveUp(code, why);
            return;
        }
        const int delay = kRetryDelayMs << (m_failures - 1);
        log(QStringLiteral("window %1: reading its menu again in %2 ms (%3 of %4)").arg(m_window).arg(delay).arg(m_failures).arg(kFirstReadTries));
        m_retry.start(delay);
    }

    void MenuClient::giveUp(const QString& code, const QString& why) {
        log(QStringLiteral("window %1: menu given up (%2: %3)").arg(m_window, code, why));
        m_stopped = true;
        m_refetch.stop();
        m_retry.stop();
        emit failed(m_window, code, why);
    }

    void MenuClient::track(const QDBusMessage& message, std::function<void(const QDBusMessage&)> handler) {
        ++m_outstanding;
        emit callBegun();
        auto* watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(message, kCallTimeoutMs), this);
        connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, handler = std::move(handler)](QDBusPendingCallWatcher* w) {
            {
                const QDBusMessage reply = w->reply();
                w->deleteLater();
                handler(reply);
            }
            --m_outstanding;
            emit callEnded();
            trimMemorySoon(); // the reply (possibly tens of MB) is released with the watcher
        });
    }

    bool MenuClient::aboutToShow(int id) {
        if (m_gone || !m_index.submenus.contains(id))
            return false;
        track(aboutToShowCall(m_service, m_path, id), [this](const QDBusMessage& reply) {
            // needUpdate = true: the application changed the submenu; read it again.
            if (reply.type() == QDBusMessage::ReplyMessage && reply.arguments().size() == 1 && reply.arguments().at(0).toBool())
                scheduleRefetch();
        });
        return true;
    }

    bool MenuClient::activate(int id) {
        if (m_gone || !m_index.activatable.contains(id))
            return false;
        track(eventCall(m_service, m_path, id), [this, id](const QDBusMessage& reply) {
            if (reply.type() == QDBusMessage::ErrorMessage)
                log(QStringLiteral("window %1: Event(%2, clicked) failed: %3").arg(m_window).arg(id).arg(reply.errorName()));
        });
        return true;
    }

} // namespace gf::menubridge
