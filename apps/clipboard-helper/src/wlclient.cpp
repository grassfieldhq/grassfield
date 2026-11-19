#include "wlclient.h"
#include "cliplogic.h"

#include "ext-data-control-v1-client-protocol.h"
#include "hyprland-lock-notify-v1-client-protocol.h"

#include <QAbstractEventDispatcher>
#include <QTimer>
#include <chrono>

#include <cerrno>
#include <cstring>

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <wayland-client.h>

namespace
{
const wl_registry_listener kRegistryListener = {&WaylandClipboard::registryGlobal, &WaylandClipboard::registryRemove};
} // namespace

// The listeners are file-scope objects that need the private static functions: built through these accessors.
struct ListenerTables {
    static const ext_data_control_device_v1_listener device;
    static const ext_data_control_offer_v1_listener offer;
    static const ext_data_control_source_v1_listener source;
    static const hyprland_lock_notification_v1_listener lock;
};

WaylandClipboard::WaylandClipboard(Callbacks callbacks, QObject *parent)
    : QObject(parent)
    , m_callbacks(std::move(callbacks))
{
}

WaylandClipboard::~WaylandClipboard()
{
    for (Offer *o : std::as_const(m_offers)) {
        ext_data_control_offer_v1_destroy(o->proxy);
        delete o;
    }
    m_offers.clear();
    if (m_source)
        ext_data_control_source_v1_destroy(m_source);
    if (m_device)
        ext_data_control_device_v1_destroy(m_device);
    if (m_lockNotification)
        hyprland_lock_notification_v1_destroy(m_lockNotification);
    if (m_lockNotifier)
        hyprland_lock_notifier_v1_destroy(m_lockNotifier);
    if (m_manager)
        ext_data_control_manager_v1_destroy(m_manager);
    if (m_seat)
        wl_seat_destroy(m_seat);
    if (m_registry)
        wl_registry_destroy(m_registry);
    if (m_display) {
        wl_display_flush(m_display);
        wl_display_disconnect(m_display);
    }
}

int WaylandClipboard::connectSocket(const QByteArray &path, QString *error)
{
    if (path.isEmpty() || path.at(0) != '/') {
        *error = QStringLiteral("--display needs an absolute path");
        return -1;
    }
    struct stat st {};
    if (::lstat(path.constData(), &st) != 0 || !S_ISSOCK(st.st_mode) || st.st_uid != ::getuid()) {
        *error = QStringLiteral("--display is not a socket of this user");
        return -1;
    }
    sockaddr_un addr {};
    addr.sun_family = AF_UNIX;
    if (size_t(path.size()) >= sizeof addr.sun_path) {
        *error = QStringLiteral("--display path too long");
        return -1;
    }
    std::memcpy(addr.sun_path, path.constData(), size_t(path.size()));
    const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        *error = QStringLiteral("socket() failed");
        return -1;
    }
    if (::connect(fd, reinterpret_cast<const sockaddr *>(&addr), sizeof addr) != 0) {
        ::close(fd);
        *error = QStringLiteral("cannot connect to --display");
        return -1;
    }
    ucred cred {};
    socklen_t len = sizeof cred;
    if (::getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0 || cred.uid != ::getuid()) {
        ::close(fd);
        *error = QStringLiteral("the --display server is not this user's");
        return -1;
    }
    return fd;
}

bool WaylandClipboard::start(int fd, QString *error)
{
    m_display = wl_display_connect_to_fd(fd);
    if (!m_display) {
        *error = QStringLiteral("wl_display_connect_to_fd failed");
        return false;
    }
    m_registry = wl_display_get_registry(m_display);
    wl_registry_add_listener(m_registry, &kRegistryListener, this);
    if (wl_display_roundtrip(m_display) < 0) {
        *error = QStringLiteral("the compositor did not answer");
        return false;
    }
    if (m_lockNotifier) {
        m_lockNotification = hyprland_lock_notifier_v1_get_lock_notification(m_lockNotifier);
        hyprland_lock_notification_v1_add_listener(m_lockNotification, &ListenerTables::lock, this);
        // A lock that holds now is reported at once (Hyprland's LockNotify onGetNotification): after this roundtrip, no
        // `locked` means unlocked.
        if (wl_display_roundtrip(m_display) < 0) {
            *error = QStringLiteral("the compositor did not answer");
            return false;
        }
    }
    m_notifier = new QSocketNotifier(wl_display_get_fd(m_display), QSocketNotifier::Read, this);
    connect(m_notifier, &QSocketNotifier::activated, this, [this] { readable(); });
    if (auto *dispatcher = QAbstractEventDispatcher::instance())
        connect(dispatcher, &QAbstractEventDispatcher::aboutToBlock, this, [this] {
            if (m_display && !m_failed) {
                wl_display_dispatch_pending(m_display);
                flush();
            }
        });
    return true;
}

void WaylandClipboard::flush()
{
    if (m_display && !m_failed && wl_display_flush(m_display) < 0 && errno != EAGAIN)
        fail(QStringLiteral("the connection to the compositor failed"));
}

void WaylandClipboard::readable()
{
    if (!m_display || m_failed)
        return;
    if (wl_display_prepare_read(m_display) == 0) {
        if (wl_display_read_events(m_display) < 0) {
            fail(QStringLiteral("the connection to the compositor was lost"));
            return;
        }
    }
    if (wl_display_dispatch_pending(m_display) < 0)
        fail(QStringLiteral("the connection to the compositor was lost"));
    flush();
}

void WaylandClipboard::fail(const QString &why)
{
    if (m_failed)
        return;
    m_failed = true;
    if (m_notifier)
        m_notifier->setEnabled(false);
    if (m_callbacks.fatal)
        m_callbacks.fatal(why);
}

void WaylandClipboard::registryGlobal(void *data, wl_registry *registry, uint32_t name, const char *interface, uint32_t version)
{
    auto *self = static_cast<WaylandClipboard *>(data);
    if (std::strcmp(interface, wl_seat_interface.name) == 0 && !self->m_seat)
        self->m_seat = static_cast<wl_seat *>(wl_registry_bind(registry, name, &wl_seat_interface, 1));
    else if (std::strcmp(interface, ext_data_control_manager_v1_interface.name) == 0 && !self->m_manager)
        self->m_manager = static_cast<ext_data_control_manager_v1 *>(wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface, 1));
    else if (std::strcmp(interface, hyprland_lock_notifier_v1_interface.name) == 0 && !self->m_lockNotifier)
        self->m_lockNotifier = static_cast<hyprland_lock_notifier_v1 *>(wl_registry_bind(registry, name, &hyprland_lock_notifier_v1_interface, 1));
    (void)version;
}

void WaylandClipboard::registryRemove(void *, wl_registry *, uint32_t)
{
}

void WaylandClipboard::setCapturing(bool on)
{
    m_wantCapture = on;
    if (on == capturing() || !supported() || m_failed)
        return;
    if (!on) {
        destroyDevice();
        flush();
        return;
    }
    m_device = ext_data_control_manager_v1_get_data_device(m_manager, m_seat);
    ext_data_control_device_v1_add_listener(m_device, &ListenerTables::device, this);
    m_firstSelection = true;
    flush();
}

void WaylandClipboard::destroyDevice()
{
    if (!m_device)
        return;
    ext_data_control_device_v1_destroy(m_device);
    m_device = nullptr;
    // Offers announced on this device and not yet handed over die with it.
    for (Offer *o : std::as_const(m_offers)) {
        ext_data_control_offer_v1_destroy(o->proxy);
        delete o;
    }
    m_offers.clear();
}

void WaylandClipboard::deviceDataOffer(void *data, ext_data_control_device_v1 *, ext_data_control_offer_v1 *offer)
{
    auto *self = static_cast<WaylandClipboard *>(data);
    auto *o = new Offer;
    o->proxy = offer;
    self->m_offers.insert(offer, o);
    ext_data_control_offer_v1_add_listener(offer, &ListenerTables::offer, o);
}

void WaylandClipboard::offerType(void *data, ext_data_control_offer_v1 *, const char *mime)
{
    auto *o = static_cast<Offer *>(data);
    const QByteArray type(mime);
    if (o->types.size() >= ClipLogic::kMaxTypes || type.size() > ClipLogic::kMaxTypeLength || type.isEmpty())
        o->tooMany = true;
    else
        o->types << type;
}

void WaylandClipboard::deviceSelection(void *data, ext_data_control_device_v1 *, ext_data_control_offer_v1 *offer)
{
    auto *self = static_cast<WaylandClipboard *>(data);
    const bool first = self->m_firstSelection;
    self->m_firstSelection = false;
    Offer *o = offer ? self->m_offers.take(offer) : nullptr;
    if (offer && !o) {
        ext_data_control_offer_v1_destroy(offer);
        return;
    }
    if (self->m_callbacks.selection)
        self->m_callbacks.selection(o, first);
    else if (o)
        self->release(o);
}

void WaylandClipboard::devicePrimary(void *data, ext_data_control_device_v1 *, ext_data_control_offer_v1 *offer)
{
    auto *self = static_cast<WaylandClipboard *>(data);
    if (!offer)
        return;
    Offer *o = self->m_offers.take(offer);
    ext_data_control_offer_v1_destroy(offer); // never read
    delete o;
}

void WaylandClipboard::deviceFinished(void *data, ext_data_control_device_v1 *)
{
    auto *self = static_cast<WaylandClipboard *>(data);
    self->destroyDevice();
    self->flush();
    if (!self->m_wantCapture || self->m_failed)
        return;
    // Made again (B-15), unless the compositor keeps ending it: then the helper stops and says why.
    const qint64 now = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    self->m_recreations.removeIf([now](qint64 t) { return now - t > kRecreateWindowMs; });
    if (self->m_recreations.size() >= kMaxRecreations) {
        self->fail(QStringLiteral("the compositor keeps ending the clipboard device"));
        return;
    }
    self->m_recreations << now;
    QTimer::singleShot(kRecreateMs, self, [self] {
        if (self->m_wantCapture && !self->capturing())
            self->setCapturing(true);
    });
}

int WaylandClipboard::receive(Offer *offer, const QByteArray &mime)
{
    if (!offer || m_failed)
        return -1;
    int fds[2];
    if (::pipe2(fds, O_CLOEXEC) != 0)
        return -1;
    // Only our end is non-blocking: the source app gets a blocking write end, as every app expects (a non-blocking one made a
    // writer give up on a full pipe, and the copy looked complete at 64 KiB).
    ::fcntl(fds[0], F_SETFL, ::fcntl(fds[0], F_GETFL) | O_NONBLOCK);
    ext_data_control_offer_v1_receive(offer->proxy, mime.constData(), fds[1]);
    flush();
    ::close(fds[1]);
    return fds[0];
}

void WaylandClipboard::release(Offer *offer)
{
    if (!offer)
        return;
    ext_data_control_offer_v1_destroy(offer->proxy);
    delete offer;
    flush();
}

bool WaylandClipboard::setSelection(const QList<QByteArray> &types)
{
    if (!m_device || m_failed)
        return false;
    ext_data_control_source_v1 *source = ext_data_control_manager_v1_create_data_source(m_manager);
    for (const QByteArray &t : types)
        ext_data_control_source_v1_offer(source, t.constData());
    ext_data_control_source_v1_add_listener(source, &ListenerTables::source, this);
    ext_data_control_device_v1_set_selection(m_device, source);
    if (m_source)
        ext_data_control_source_v1_destroy(m_source); // replaced: no longer the selection
    m_source = source;
    flush();
    return true;
}

void WaylandClipboard::sourceSend(void *data, ext_data_control_source_v1 *source, const char *mime, int32_t fd)
{
    auto *self = static_cast<WaylandClipboard *>(data);
    if (source != self->m_source || !self->m_callbacks.send) {
        ::close(fd);
        return;
    }
    self->m_callbacks.send(QByteArray(mime), fd);
}

void WaylandClipboard::sourceCancelled(void *data, ext_data_control_source_v1 *source)
{
    auto *self = static_cast<WaylandClipboard *>(data);
    ext_data_control_source_v1_destroy(source);
    if (source == self->m_source) {
        self->m_source = nullptr;
        if (self->m_callbacks.sourceCancelled)
            self->m_callbacks.sourceCancelled();
    }
}

void WaylandClipboard::lockLocked(void *data, hyprland_lock_notification_v1 *)
{
    auto *self = static_cast<WaylandClipboard *>(data);
    self->m_locked = true;
    if (self->m_callbacks.lockChanged)
        self->m_callbacks.lockChanged();
}

void WaylandClipboard::lockUnlocked(void *data, hyprland_lock_notification_v1 *)
{
    auto *self = static_cast<WaylandClipboard *>(data);
    self->m_locked = false;
    if (self->m_callbacks.lockChanged)
        self->m_callbacks.lockChanged();
}

const ext_data_control_device_v1_listener ListenerTables::device = {
    &WaylandClipboard::deviceDataOffer, &WaylandClipboard::deviceSelection, &WaylandClipboard::deviceFinished,
    &WaylandClipboard::devicePrimary};
const ext_data_control_offer_v1_listener ListenerTables::offer = {&WaylandClipboard::offerType};
const ext_data_control_source_v1_listener ListenerTables::source = {&WaylandClipboard::sourceSend, &WaylandClipboard::sourceCancelled};
const hyprland_lock_notification_v1_listener ListenerTables::lock = {&WaylandClipboard::lockLocked, &WaylandClipboard::lockUnlocked};
