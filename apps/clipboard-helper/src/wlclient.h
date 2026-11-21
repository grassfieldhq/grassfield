// The helper's Wayland side (ADR-0034 §1, §6, §8): one connection to the socket it was given, ext-data-control-v1 for the regular
// selection (the primary selection is never read), hyprland_lock_notifier_v1 for the compositor's lock state. The data-control
// device exists only while capture is on; an offer's data is requested only through receive().
#pragma once

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QObject>
#include <QSocketNotifier>
#include <QString>

#include <functional>

struct wl_display;
struct wl_registry;
struct wl_seat;
struct ext_data_control_manager_v1;
struct ext_data_control_device_v1;
struct ext_data_control_offer_v1;
struct ext_data_control_source_v1;
struct hyprland_lock_notifier_v1;
struct hyprland_lock_notification_v1;

class WaylandClipboard : public QObject
{
public:
    struct Offer {
        ext_data_control_offer_v1 *proxy = nullptr;
        QList<QByteArray> types;
        bool tooMany = false;
    };
    struct Callbacks {
        std::function<void()> lockChanged;
        // A new regular selection. `offer` is null when the selection was cleared; otherwise the callee owns it (release()).
        // `first`: the first selection after the device was created (it may predate a lock or the start: never recorded).
        std::function<void(Offer *offer, bool first)> selection;
        // Our source was asked for `mime`; the callee owns `fd` (write the data, then close it).
        std::function<void(const QByteArray &mime, int fd)> send;
        std::function<void()> sourceCancelled;
        std::function<void(const QString &why)> fatal;
    };

    explicit WaylandClipboard(Callbacks callbacks, QObject *parent = nullptr);
    ~WaylandClipboard() override;

    // Connects to `path` without libwayland's own lookup (which takes WAYLAND_SOCKET first): an absolute path to a socket of
    // this user, connected here, its peer checked to be this user. Returns the descriptor, or -1 and `error`.
    static int connectSocket(const QByteArray &path, QString *error);
    // Takes `fd` (connectSocket's), binds the globals, reads the lock state. False and `error` when the connection fails;
    // supported() says whether the compositor has both protocols.
    bool start(int fd, QString *error);
    bool supported() const { return m_manager && m_lockNotifier && m_seat; }
    bool compositorLocked() const { return m_locked; }
    // The device exists exactly while capture is on. A device the compositor ends (`finished`) is made again after
    // kRecreateMs (its first selection is never recorded, as after any new device); more than kMaxRecreations within
    // kRecreateWindowMs is fatal (B-15: capture never stays off silently).
    void setCapturing(bool on);
    static constexpr int kRecreateMs = 500;
    static constexpr int kMaxRecreations = 5;
    static constexpr qint64 kRecreateWindowMs = 60 * 1000;
    bool capturing() const { return m_device != nullptr; }
    // Requests `mime` of `offer`; returns the read end (non-blocking, close-on-exec) or -1.
    int receive(Offer *offer, const QByteArray &mime);
    void release(Offer *offer);
    // Becomes the selection owner offering `types`. False without a device.
    bool setSelection(const QList<QByteArray> &types);
    bool ownsSelection() const { return m_source != nullptr; }
    void flush();

    // Wayland listener entry points (C callbacks, used by the listener tables in wlclient.cpp).
    static void registryGlobal(void *data, wl_registry *registry, uint32_t name, const char *interface, uint32_t version);
    static void registryRemove(void *data, wl_registry *registry, uint32_t name);
    static void deviceDataOffer(void *data, ext_data_control_device_v1 *device, ext_data_control_offer_v1 *offer);
    static void deviceSelection(void *data, ext_data_control_device_v1 *device, ext_data_control_offer_v1 *offer);
    static void deviceFinished(void *data, ext_data_control_device_v1 *device);
    static void devicePrimary(void *data, ext_data_control_device_v1 *device, ext_data_control_offer_v1 *offer);
    static void offerType(void *data, ext_data_control_offer_v1 *offer, const char *mime);
    static void sourceSend(void *data, ext_data_control_source_v1 *source, const char *mime, int32_t fd);
    static void sourceCancelled(void *data, ext_data_control_source_v1 *source);
    static void lockLocked(void *data, hyprland_lock_notification_v1 *notification);
    static void lockUnlocked(void *data, hyprland_lock_notification_v1 *notification);

private:
    void readable();
    void destroyDevice();
    void fail(const QString &why);

    Callbacks m_callbacks;
    wl_display *m_display = nullptr;
    wl_registry *m_registry = nullptr;
    wl_seat *m_seat = nullptr;
    ext_data_control_manager_v1 *m_manager = nullptr;
    ext_data_control_device_v1 *m_device = nullptr;
    ext_data_control_source_v1 *m_source = nullptr;
    hyprland_lock_notifier_v1 *m_lockNotifier = nullptr;
    hyprland_lock_notification_v1 *m_lockNotification = nullptr;
    QHash<ext_data_control_offer_v1 *, Offer *> m_offers;
    QSocketNotifier *m_notifier = nullptr;
    bool m_locked = false;
    bool m_wantCapture = false;
    QList<qint64> m_recreations; // monotonic ms of the recent re-creations after `finished`
    bool m_firstSelection = false;
    bool m_failed = false;
};
