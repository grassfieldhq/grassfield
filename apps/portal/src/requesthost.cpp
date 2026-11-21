#include "requesthost.h"

#include <KService>
#include <KWindowSystem>

#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QPointer>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QWindow>

#include <limits>
#include <mutex>
#include <thread>
#include <utility>

namespace grassfield::portal {

namespace {
constexpr auto kPath = "/org/freedesktop/portal/desktop";
constexpr auto kRequestInterface = "org.freedesktop.impl.portal.Request";
// A Close to x-d-p-gtk that finds no Request object yet is sent again this often, this many times (closeForwarded).
constexpr int kCloseRetryMs = 100;
constexpr int kCloseTries = 50;
} // namespace

// The worker posts here; ~RequestHost closes it under its lock (no answer reaches a host that went).
struct RequestHost::AppLookups {
    std::mutex lock;
    RequestHost *target = nullptr;
};

struct RequestHost::Request {
    enum class State { Making, Shown, Forwarded };
    int id = 0;
    QString handle;
    QString appId;
    QString parentWindow;
    // The frontend's unique name on the bus (the message's sender).
    QString caller;
    QDBusMessage message;
    State state = State::Making;
    // Closed while forwarded: x-d-p-gtk's answer to a closed dialog is not the user's.
    bool closed = false;
    QTimer deadline;
    QElapsedTimer since;
    QPointer<QWindow> window;
    std::unique_ptr<RequestObject> object;
};

RequestHost::RequestHost(const QDBusConnection &bus, const QString &interface, const Limits &limits, QObject *parent)
    : QObject(parent)
    , m_bus(bus)
    , m_interface(interface)
    , m_limits(limits)
{
    m_idle.setSingleShot(true);
    // Never early (a coarse timer may fire 5% before its time): quiet() compares against the same interval.
    m_idle.setTimerType(Qt::PreciseTimer);
    m_idle.setInterval(m_limits.idleQuitMs);
    connect(&m_idle, &QTimer::timeout, this, &RequestHost::idle);
    m_lookups = std::make_shared<AppLookups>();
    m_lookups->target = this;
    m_callers.setConnection(m_bus);
    m_callers.setWatchMode(QDBusServiceWatcher::WatchForUnregistration);
    connect(&m_callers, &QDBusServiceWatcher::serviceUnregistered, this, &RequestHost::callerGone);
    armIdle();
}

void RequestHost::callerGone(const QString &service)
{
    m_callers.removeWatchedService(service);
    QList<int> ids;
    for (const auto &r : std::as_const(m_requests)) {
        if (r->caller == service)
            ids << r->id;
    }
    if (!ids.isEmpty())
        qWarning("grassfield-portal: the frontend left the bus; its %lld open request(s) end", static_cast<long long>(ids.size()));
    for (int id : std::as_const(ids)) {
        const auto r = m_requests.value(id);
        if (!r)
            continue;
        if (r->state == Request::State::Forwarded) {
            // x-d-p-gtk's dialog goes too; its answer then ends the request (to nobody).
            r->closed = true;
            closeForwarded(id, kCloseTries);
        } else {
            endWithoutAnswer(id);
        }
    }
}

RequestHost::~RequestHost()
{
    {
        std::lock_guard<std::mutex> hold(m_lookups->lock);
        m_lookups->target = nullptr;
    }
    // A process that goes with requests in flight answers them: the frontend never waits on a backend that left.
    const QList<int> ids = m_requests.keys();
    for (int id : ids)
        endWithoutAnswer(id);
}

qint64 RequestHost::quietFor() const
{
    return m_requests.isEmpty() ? m_quiet.elapsed() : 0;
}

bool RequestHost::quiet(const QList<const RequestHost *> &hosts, int ms)
{
    for (const RequestHost *host : hosts)
        if (host->pending() > 0 || host->quietFor() < ms)
            return false;
    return true;
}

QString RequestHost::windowAppId(const QString &appId)
{
    QString id = appId;
    if (id.endsWith(QLatin1String(".desktop")))
        id.chop(8);
    static const QRegularExpression valid(QStringLiteral("^[A-Za-z0-9_-][A-Za-z0-9._-]{0,254}$"));
    return valid.match(id).hasMatch() ? id : QStringLiteral("org.grassfield.Files");
}

QString RequestHost::appName(const QString &appId) const
{
    return m_apps.value(windowAppId(appId)).name;
}

QString RequestHost::appIcon(const QString &appId) const
{
    return m_apps.value(windowAppId(appId)).icon;
}

void RequestHost::lookUpApp(const QString &desktopId)
{
    if (m_apps.contains(desktopId) || m_waitingForApp.contains(desktopId))
        return;
    m_waitingForApp.insert(desktopId, {});
    // KSycoca is per thread: this one maps the database (and rebuilds it when it is stale) on its own, off the GUI thread.
    std::thread([lookups = m_lookups, desktopId] {
        AppInfo info;
        if (const KService::Ptr service = KService::serviceByDesktopName(desktopId)) {
            info.name = service->name();
            info.icon = service->icon();
        }
        std::lock_guard<std::mutex> hold(lookups->lock);
        if (RequestHost *target = lookups->target)
            QMetaObject::invokeMethod(target, [target, desktopId, info] { target->appKnown(desktopId, info); }, Qt::QueuedConnection);
    }).detach();
}

void RequestHost::appKnown(const QString &desktopId, const AppInfo &info)
{
    m_apps.insert(desktopId, info);
    const auto waiting = m_waitingForApp.take(desktopId);
    for (const auto &[id, fn] : waiting) {
        if (isOpen(id))
            fn();
    }
}

void RequestHost::whenAppKnown(int id, std::function<void()> fn)
{
    const auto r = m_requests.value(id);
    if (!r)
        return;
    const QString desktopId = windowAppId(r->appId);
    if (r->appId.isEmpty() || desktopId == QLatin1String("org.grassfield.Files") || m_apps.contains(desktopId)) {
        fn();
        return;
    }
    lookUpApp(desktopId);
    m_waitingForApp[desktopId].append({id, std::move(fn)});
}

void RequestHost::refuse(const QDBusMessage &message, const char *why)
{
    qWarning("grassfield-portal: %s: %s", qPrintable(message.member()), why);
    replyFailed(message, why);
}

void RequestHost::replyFailed(const QDBusMessage &message, const char *why)
{
    if (m_limits.failAsError)
        m_bus.send(message.createErrorReply(QDBusError::Failed, QString::fromUtf8(why)));
    else
        m_bus.send(message.createReply(QVariantList{QVariant::fromValue(uint(2)), QVariantMap()}));
}

void RequestHost::endWithoutAnswer(int id)
{
    const auto r = m_requests.take(id);
    if (!r)
        return;
    replyFailed(r->message, "ended without an answer");
    m_bus.unregisterObject(r->handle);
    ended(id);
    emit closed(id);
    emit pendingChanged();
    armIdle();
}

int RequestHost::begin(const QDBusObjectPath &handle, const QDBusMessage &message, const QString &appId, const QString &parentWindow)
{
    message.setDelayedReply(true);
    const QString path = handle.path();
    if (m_requests.size() >= m_limits.maxPending) {
        refuse(message, "too many requests at once");
        return 0;
    }
    for (const auto &r : std::as_const(m_requests)) {
        if (r->handle == path) {
            refuse(message, "a request with this handle is open");
            return 0;
        }
    }
    auto r = std::make_shared<Request>();
    r->id = m_nextId++;
    r->handle = path;
    r->appId = appId;
    r->parentWindow = parentWindow;
    r->caller = message.service();
    r->message = message;
    r->since.start();
    r->object = std::make_unique<RequestObject>(this, path);
    if (path.isEmpty() || !m_bus.registerObject(path, r->object.get(), QDBusConnection::ExportScriptableSlots)) {
        refuse(message, "cannot export the request object");
        return 0;
    }
    m_requests.insert(r->id, r);
    // The application's entry is read now, off this thread (appName, whenAppKnown).
    if (!appId.isEmpty() && windowAppId(appId) != QLatin1String("org.grassfield.Files"))
        lookUpApp(windowAppId(appId));
    if (!r->caller.isEmpty() && !m_callers.watchedServices().contains(r->caller))
        m_callers.addWatchedService(r->caller);
    m_idle.stop();
    emit pendingChanged();
    return r->id;
}

bool RequestHost::startUi(int id)
{
    const auto r = m_requests.value(id);
    if (!r)
        return false;
    if (m_uiLoader) {
        const auto load = std::exchange(m_uiLoader, nullptr);
        m_uiReady = load();
    }
    if (!m_uiReady) {
        forward(id);
        return false;
    }
    // FC7: no first frame within the deadline, and the call goes to x-d-p-gtk.
    r->deadline.setSingleShot(true);
    r->deadline.setInterval(m_limits.uiDeadlineMs);
    connect(&r->deadline, &QTimer::timeout, this, [this, id] {
        qWarning("grassfield-portal: the panel did not show within %d ms; the request goes to x-d-p-gtk", m_limits.uiDeadlineMs);
        forward(id);
    });
    r->deadline.start();
    return true;
}

bool RequestHost::isMaking(int id) const
{
    const auto r = m_requests.value(id);
    return r && r->state == Request::State::Making;
}

bool RequestHost::isOpen(int id) const
{
    const auto r = m_requests.value(id);
    return r && r->state != Request::State::Forwarded;
}

int RequestHost::requestId(const QString &handle) const
{
    for (const auto &r : std::as_const(m_requests))
        if (r->handle == handle)
            return r->id;
    return 0;
}

void RequestHost::present(int id, QObject *object)
{
    const auto r = m_requests.value(id);
    auto *window = qobject_cast<QWindow *>(object);
    if (!r || r->state != Request::State::Making || r->window)
        return;
    if (!window) {
        fail(id);
        return;
    }
    r->window = window;
    // A request that waited its turn (queue()) has the whole deadline from now.
    if (!r->deadline.isActive())
        r->deadline.start();
    if (auto *quick = qobject_cast<QQuickWindow *>(window)) {
        connect(quick, &QQuickWindow::frameSwapped, this, [this, id] {
            const auto shown = m_requests.value(id);
            if (!shown || shown->state != Request::State::Making)
                return;
            shown->state = Request::State::Shown;
            shown->deadline.stop();
            qInfo("grassfield-portal: panel shown in %lld ms", static_cast<long long>(shown->since.elapsed()));
        });
    }
    // The toplevel takes the application's id when Qt makes it (QWindow::show), and the application's window as its
    // parent through xdg-foreign v2 (KWindowSystem waits for the toplevel). Hyprland then centres the window over that
    // window, and xdg-dialog's modal (the window's modality, set by the QML) dims and blocks it.
    const QString own = QGuiApplication::desktopFileName();
    QGuiApplication::setDesktopFileName(windowAppId(r->appId));
    if (QGuiApplication::platformName() == QLatin1String("wayland") && r->parentWindow.startsWith(QLatin1String("wayland:"))
        && r->parentWindow.size() > 8)
        KWindowSystem::setMainWindow(window, r->parentWindow.mid(8));
    window->show();
    QGuiApplication::setDesktopFileName(own);
}

void RequestHost::reshow(int id)
{
    const auto r = m_requests.value(id);
    if (!r || r->state == Request::State::Forwarded || !r->window)
        return;
    const QString own = QGuiApplication::desktopFileName();
    QGuiApplication::setDesktopFileName(windowAppId(r->appId));
    r->window->show();
    QGuiApplication::setDesktopFileName(own);
}

void RequestHost::fail(int id)
{
    if (!isOpen(id))
        return;
    qWarning("grassfield-portal: the panel could not be made; the request goes to x-d-p-gtk");
    forward(id);
}

void RequestHost::queue(int id)
{
    const auto r = m_requests.value(id);
    if (r && r->state == Request::State::Making && !r->window)
        r->deadline.stop();
}

void RequestHost::close(const QString &handle)
{
    for (const auto &r : std::as_const(m_requests)) {
        if (r->handle != handle)
            continue;
        if (r->state == Request::State::Forwarded) {
            r->closed = true;
            closeForwarded(r->id, kCloseTries);
            return;
        }
        endWithoutAnswer(r->id);
        return;
    }
}

// x-d-p-gtk ends its own dialog; its answer comes back through the forwarded call. GDBus routes a call to an object path as
// soon as it reads it, which can be before x-d-p-gtk's handler of the forwarded call has exported that call's Request
// object (both queued while D-Bus activation starts it): a Close that finds no object is sent again shortly, while the
// request is still forwarded (counter-review of step 4b, NIT-4).
void RequestHost::closeForwarded(int id, int tries)
{
    const auto r = m_requests.value(id);
    if (!r || r->state != Request::State::Forwarded)
        return;
    const QDBusMessage close = QDBusMessage::createMethodCall(m_limits.gtkService, r->handle, QString::fromLatin1(kRequestInterface),
                                                              QStringLiteral("Close"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(close), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id, tries](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusError::ErrorType error = w->error().type();
        if (tries > 1 && (error == QDBusError::UnknownMethod || error == QDBusError::UnknownObject || error == QDBusError::UnknownInterface))
            QTimer::singleShot(kCloseRetryMs, this, [this, id, tries] { closeForwarded(id, tries - 1); });
    });
}

void RequestHost::finish(int id, uint response, const QVariantMap &results)
{
    const auto r = m_requests.take(id);
    if (!r)
        return;
    m_bus.send(r->message.createReply(QVariantList{QVariant::fromValue(response), results}));
    m_bus.unregisterObject(r->handle);
    ended(id);
    emit closed(id);
    emit pendingChanged();
    armIdle();
}

void RequestHost::forward(int id)
{
    const auto r = m_requests.value(id);
    if (!r || r->state == Request::State::Forwarded)
        return;
    if (!forwardable(id)) {
        qWarning("grassfield-portal: the request cannot go to x-d-p-gtk as it came; it ends without an answer");
        endWithoutAnswer(id);
        return;
    }
    r->state = Request::State::Forwarded;
    r->deadline.stop();
    // The window, if any, goes; the same call, with the same handle and options, goes to x-d-p-gtk.
    emit closed(id);
    QDBusMessage call = QDBusMessage::createMethodCall(m_limits.gtkService, QString::fromLatin1(kPath), m_interface, r->message.member());
    call.setArguments(r->message.arguments());
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(call, std::numeric_limits<int>::max()), this);
    forwarded(id);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const auto forwarded = m_requests.take(id);
        if (!forwarded)
            return;
        const QDBusMessage reply = w->reply();
        const QVariantList args = reply.arguments();
        if (forwarded->closed && m_limits.failAsError) {
            // The application or the frontend closed it: x-d-p-gtk's answer (its closed dialog's) is no answer of the user's.
            replyFailed(forwarded->message, "closed");
        } else if (reply.type() == QDBusMessage::ReplyMessage && reply.signature() == QLatin1String("ua{sv}")) {
            const uint response = args.at(0).toUInt();
            m_bus.send(forwarded->message.createReply(QVariantList{QVariant::fromValue(response), relayed(qdbus_cast<QVariantMap>(args.at(1)))}));
        } else {
            qWarning("grassfield-portal: x-d-p-gtk did not answer the forwarded request; it ends with an error");
            replyFailed(forwarded->message, "x-d-p-gtk did not answer");
        }
        m_bus.unregisterObject(forwarded->handle);
        ended(id);
        emit pendingChanged();
        armIdle();
    });
}

void RequestHost::armIdle()
{
    if (!m_requests.isEmpty())
        return;
    m_quiet.start();
    m_idle.start();
}

} // namespace grassfield::portal
