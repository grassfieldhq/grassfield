// A fake compositor for the clipboard helper's tests (ADR-0034, tests/shell/clipboard_helper.sh): never the owner's clipboard. It
// listens on the socket path it is given (a file in the test's mktemp -d directory), offers wl_seat, ext_data_control_manager_v1 and
// hyprland_lock_notifier_v1, and is driven through stdin; it reports what clients do on stdout. Built by
// apps/clipboard-helper/build-direct.sh --fake-server.
//
//   fake-clipboard-server --socket <absolute path> [--no-lock-notifier] [--no-data-control]
//
// stdin (one command a line):
//   SELECT <mime>|<data> ...   a new selection made by "another app"; <data>: hex:<bytes in hex> | file:<path> | big:<n> (n bytes)
//                              | hang (the pipe is never written nor closed) | slow:<ms>:<data> (all of <data>, <ms> after the request)
//   CLEAR                      no selection
//   LOCK | UNLOCK              the session lock (sent to every lock notification)
//   PASTE <mime> <out path> [<bytes> <ms>]
//                              asks the client that owns the selection for <mime>, writes what it sends to <out path>; with
//                              <bytes> <ms>, reads at most <bytes> at a time and waits <ms> between reads (a slow reader)
//   STALL <mime>               asks the client that owns the selection for <mime> and never reads it; reports when the client
//                              closes its end
//   FINISH                     sends ext_data_control_device_v1.finished to every device (the client must make a new one)
//   QUIT
// stdout: READY, CLIENT <n>, BIND <global>, DEVICE, DEVICE_GONE, NOTIFIER, RECEIVE <mime>, SELECTION <mime>..., CLEARED, PASTED <mime> <bytes>, FINISHED,
//         STALL_CLOSED <ms>.
#include "ext-data-control-v1-server-protocol.h"
#include "hyprland-lock-notify-v1-server-protocol.h"

#include <wayland-server-core.h>
#include <wayland-server-protocol.h>

#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace
{
struct Part {
    std::string mime;
    std::string data;
    bool hang = false;
    int delayMs = 0;
};

struct Source {
    wl_resource *resource = nullptr;
    std::vector<std::string> mimes;
};

struct State {
    wl_display *display = nullptr;
    std::vector<wl_resource *> devices;
    std::vector<wl_resource *> notifications;
    std::vector<Part> testParts; // a selection made by the test ("another app")
    Source *clientSource = nullptr; // a selection made by a client
    bool hasSelection = false;
    unsigned generation = 0;
    bool locked = false;
    int clients = 0;
    std::vector<int> hung;
    std::string stdinBuffer;
};

State g;

void say(const std::string &line)
{
    std::fputs((line + "\n").c_str(), stdout);
    std::fflush(stdout);
}

struct OfferData {
    unsigned generation;
};

void writeAll(int fd, std::string data, int delayMs)
{
    std::thread([fd, data = std::move(data), delayMs] {
        if (delayMs > 0)
            std::this_thread::sleep_for(std::chrono::milliseconds(delayMs));
        size_t done = 0;
        while (done < data.size()) {
            const ssize_t n = ::write(fd, data.data() + done, data.size() - done);
            if (n <= 0)
                break;
            done += size_t(n);
        }
        ::close(fd);
    }).detach();
}

// --- offers ---------------------------------------------------------------------------------------------------------------

void offerReceive(wl_client *, wl_resource *resource, const char *mime, int32_t fd)
{
    auto *data = static_cast<OfferData *>(wl_resource_get_user_data(resource));
    if (!data || data->generation != g.generation || !g.hasSelection) {
        ::close(fd);
        return;
    }
    if (g.clientSource) {
        ext_data_control_source_v1_send_send(g.clientSource->resource, mime, fd);
        ::close(fd);
        return;
    }
    say(std::string("RECEIVE ") + mime);
    for (const Part &p : g.testParts) {
        if (p.mime != mime)
            continue;
        if (p.hang) {
            g.hung.push_back(fd);
            return;
        }
        writeAll(fd, p.data, p.delayMs);
        return;
    }
    ::close(fd);
}

void offerDestroy(wl_client *, wl_resource *resource)
{
    wl_resource_destroy(resource);
}

const struct ext_data_control_offer_v1_interface kOffer = {offerReceive, offerDestroy};

void offerFree(wl_resource *resource)
{
    delete static_cast<OfferData *>(wl_resource_get_user_data(resource));
}

std::vector<std::string> selectionMimes()
{
    std::vector<std::string> out;
    if (g.clientSource)
        return g.clientSource->mimes;
    for (const Part &p : g.testParts)
        out.push_back(p.mime);
    return out;
}

void sendSelection(wl_resource *device)
{
    if (!g.hasSelection) {
        ext_data_control_device_v1_send_selection(device, nullptr);
        return;
    }
    wl_client *client = wl_resource_get_client(device);
    wl_resource *offer = wl_resource_create(client, &ext_data_control_offer_v1_interface, wl_resource_get_version(device), 0);
    wl_resource_set_implementation(offer, &kOffer, new OfferData{g.generation}, offerFree);
    ext_data_control_device_v1_send_data_offer(device, offer);
    for (const std::string &m : selectionMimes())
        ext_data_control_offer_v1_send_offer(offer, m.c_str());
    ext_data_control_device_v1_send_selection(device, offer);
}

void broadcastSelection()
{
    for (wl_resource *d : g.devices)
        sendSelection(d);
}

void dropClientSource(bool cancel)
{
    if (!g.clientSource)
        return;
    if (cancel && g.clientSource->resource)
        ext_data_control_source_v1_send_cancelled(g.clientSource->resource);
    g.clientSource = nullptr;
}

// --- sources --------------------------------------------------------------------------------------------------------------

void sourceOffer(wl_client *, wl_resource *resource, const char *mime)
{
    static_cast<Source *>(wl_resource_get_user_data(resource))->mimes.push_back(mime);
}

void sourceDestroy(wl_client *, wl_resource *resource)
{
    wl_resource_destroy(resource);
}

const struct ext_data_control_source_v1_interface kSource = {sourceOffer, sourceDestroy};

void sourceFree(wl_resource *resource)
{
    auto *s = static_cast<Source *>(wl_resource_get_user_data(resource));
    if (g.clientSource == s) {
        g.clientSource = nullptr;
        g.hasSelection = false;
        ++g.generation;
        say("CLEARED");
        broadcastSelection();
    }
    delete s;
}

// --- devices --------------------------------------------------------------------------------------------------------------

void deviceSetSelection(wl_client *, wl_resource *, wl_resource *source)
{
    Source *s = source ? static_cast<Source *>(wl_resource_get_user_data(source)) : nullptr;
    if (s != g.clientSource)
        dropClientSource(true);
    g.testParts.clear();
    ++g.generation;
    if (!s) {
        g.hasSelection = false;
        say("CLEARED");
        broadcastSelection();
        return;
    }
    g.clientSource = s;
    g.hasSelection = true;
    std::string line = "SELECTION";
    for (const std::string &m : s->mimes)
        line += " " + m;
    say(line);
    broadcastSelection();
}

void deviceSetPrimary(wl_client *, wl_resource *, wl_resource *)
{
}

void deviceDestroy(wl_client *, wl_resource *resource)
{
    wl_resource_destroy(resource);
}

const struct ext_data_control_device_v1_interface kDevice = {deviceSetSelection, deviceDestroy, deviceSetPrimary};

void deviceFree(wl_resource *resource)
{
    g.devices.erase(std::remove(g.devices.begin(), g.devices.end(), resource), g.devices.end());
    say("DEVICE_GONE");
}

// --- manager --------------------------------------------------------------------------------------------------------------

void managerCreateSource(wl_client *client, wl_resource *manager, uint32_t id)
{
    wl_resource *r = wl_resource_create(client, &ext_data_control_source_v1_interface, wl_resource_get_version(manager), id);
    auto *s = new Source;
    s->resource = r;
    wl_resource_set_implementation(r, &kSource, s, sourceFree);
}

void managerGetDevice(wl_client *client, wl_resource *manager, uint32_t id, wl_resource *)
{
    wl_resource *r = wl_resource_create(client, &ext_data_control_device_v1_interface, wl_resource_get_version(manager), id);
    wl_resource_set_implementation(r, &kDevice, nullptr, deviceFree);
    g.devices.push_back(r);
    say("DEVICE");
    sendSelection(r); // the current selection at once, as Hyprland does
}

void managerDestroy(wl_client *, wl_resource *resource)
{
    wl_resource_destroy(resource);
}

const struct ext_data_control_manager_v1_interface kManager = {managerCreateSource, managerGetDevice, managerDestroy};

void bindManager(wl_client *client, void *, uint32_t version, uint32_t id)
{
    wl_resource *r = wl_resource_create(client, &ext_data_control_manager_v1_interface, int(std::min<uint32_t>(version, 1)), id);
    wl_resource_set_implementation(r, &kManager, nullptr, nullptr);
    say("BIND data-control");
}

// --- lock notifier --------------------------------------------------------------------------------------------------------

void notificationDestroy(wl_client *, wl_resource *resource)
{
    wl_resource_destroy(resource);
}

const struct hyprland_lock_notification_v1_interface kNotification = {notificationDestroy};

void notificationFree(wl_resource *resource)
{
    g.notifications.erase(std::remove(g.notifications.begin(), g.notifications.end(), resource), g.notifications.end());
}

void notifierGet(wl_client *client, wl_resource *notifier, uint32_t id)
{
    wl_resource *r = wl_resource_create(client, &hyprland_lock_notification_v1_interface, wl_resource_get_version(notifier), id);
    wl_resource_set_implementation(r, &kNotification, nullptr, notificationFree);
    g.notifications.push_back(r);
    say("NOTIFIER");
    if (g.locked)
        hyprland_lock_notification_v1_send_locked(r); // already locked: at once
}

void notifierDestroy(wl_client *, wl_resource *resource)
{
    wl_resource_destroy(resource);
}

const struct hyprland_lock_notifier_v1_interface kNotifier = {notifierDestroy, notifierGet};

void bindNotifier(wl_client *client, void *, uint32_t version, uint32_t id)
{
    wl_resource *r = wl_resource_create(client, &hyprland_lock_notifier_v1_interface, int(std::min<uint32_t>(version, 1)), id);
    wl_resource_set_implementation(r, &kNotifier, nullptr, nullptr);
    say("BIND lock-notifier");
}

// --- seat -----------------------------------------------------------------------------------------------------------------

void seatGet(wl_client *client, wl_resource *seat, uint32_t id, const wl_interface *iface)
{
    wl_resource *r = wl_resource_create(client, iface, wl_resource_get_version(seat), id);
    wl_resource_set_implementation(r, nullptr, nullptr, nullptr);
}

void seatPointer(wl_client *c, wl_resource *s, uint32_t id)
{
    seatGet(c, s, id, &wl_pointer_interface);
}

void seatKeyboard(wl_client *c, wl_resource *s, uint32_t id)
{
    seatGet(c, s, id, &wl_keyboard_interface);
}

void seatTouch(wl_client *c, wl_resource *s, uint32_t id)
{
    seatGet(c, s, id, &wl_touch_interface);
}

void seatRelease(wl_client *, wl_resource *resource)
{
    wl_resource_destroy(resource);
}

const struct wl_seat_interface kSeat = {seatPointer, seatKeyboard, seatTouch, seatRelease};

void bindSeat(wl_client *client, void *, uint32_t version, uint32_t id)
{
    wl_resource *r = wl_resource_create(client, &wl_seat_interface, int(std::min<uint32_t>(version, 1)), id);
    wl_resource_set_implementation(r, &kSeat, nullptr, nullptr);
    wl_seat_send_capabilities(r, 0);
    say("BIND seat");
}

// --- control --------------------------------------------------------------------------------------------------------------

bool parseData(const std::string &spec, Part *part)
{
    if (spec == "hang") {
        part->hang = true;
        return true;
    }
    if (spec.rfind("slow:", 0) == 0) {
        const size_t colon = spec.find(':', 5);
        if (colon == std::string::npos)
            return false;
        part->delayMs = std::atoi(spec.substr(5, colon - 5).c_str());
        return parseData(spec.substr(colon + 1), part);
    }
    if (spec.rfind("hex:", 0) == 0) {
        const std::string hex = spec.substr(4);
        if (hex.size() % 2)
            return false;
        for (size_t i = 0; i < hex.size(); i += 2)
            part->data.push_back(char(std::strtol(hex.substr(i, 2).c_str(), nullptr, 16)));
        return true;
    }
    if (spec.rfind("file:", 0) == 0) {
        std::ifstream in(spec.substr(5), std::ios::binary);
        std::ostringstream ss;
        ss << in.rdbuf();
        part->data = ss.str();
        return bool(in) || in.eof();
    }
    if (spec.rfind("big:", 0) == 0) {
        part->data.assign(size_t(std::strtoull(spec.substr(4).c_str(), nullptr, 10)), 'a');
        return true;
    }
    return false;
}

void paste(const std::string &mime, const std::string &out, size_t chunk, int delayMs)
{
    if (!g.clientSource) {
        say("PASTED - 0");
        return;
    }
    int fds[2];
    if (::pipe2(fds, O_CLOEXEC) != 0)
        return;
    ext_data_control_source_v1_send_send(g.clientSource->resource, mime.c_str(), fds[1]);
    wl_display_flush_clients(g.display);
    ::close(fds[1]);
    // Read in a thread, report from the main loop: the client answers while this loop runs.
    const int rfd = fds[0];
    std::thread([rfd, mime, out, chunk, delayMs] {
        std::string data;
        char buf[65536];
        const size_t step = chunk > 0 && chunk < sizeof buf ? chunk : sizeof buf;
        for (;;) {
            pollfd p{rfd, POLLIN, 0};
            if (::poll(&p, 1, 5000) <= 0)
                break;
            const ssize_t n = ::read(rfd, buf, step);
            if (n <= 0)
                break;
            data.append(buf, size_t(n));
            if (delayMs > 0)
                std::this_thread::sleep_for(std::chrono::milliseconds(delayMs));
        }
        ::close(rfd);
        std::ofstream(out, std::ios::binary) << data;
        say("PASTED " + mime + " " + std::to_string(data.size()));
    }).detach();
}

void stall(const std::string &mime)
{
    if (!g.clientSource)
        return;
    int fds[2];
    if (::pipe2(fds, O_CLOEXEC) != 0)
        return;
    ext_data_control_source_v1_send_send(g.clientSource->resource, mime.c_str(), fds[1]);
    wl_display_flush_clients(g.display);
    ::close(fds[1]);
    // Never reads: the pipe fills and the client's writer waits; the read end reports POLLHUP once the client closes its end.
    const int rfd = fds[0];
    std::thread([rfd] {
        const auto start = std::chrono::steady_clock::now();
        pollfd p{rfd, 0, 0};
        const int r = ::poll(&p, 1, 10000);
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
        ::close(rfd);
        say(r > 0 && (p.revents & POLLHUP) ? "STALL_CLOSED " + std::to_string(ms) : std::string("STALL_OPEN"));
    }).detach();
}

void command(const std::string &line)
{
    std::istringstream in(line);
    std::string verb;
    in >> verb;
    if (verb == "SELECT") {
        std::vector<Part> parts;
        std::string spec;
        while (in >> spec) {
            const size_t bar = spec.find('|');
            Part p;
            if (bar == std::string::npos || !parseData(spec.substr(bar + 1), &p)) {
                say("BAD " + spec);
                return;
            }
            p.mime = spec.substr(0, bar);
            parts.push_back(p);
        }
        dropClientSource(true);
        g.testParts = parts;
        g.hasSelection = true;
        ++g.generation;
        broadcastSelection();
    } else if (verb == "CLEAR") {
        dropClientSource(true);
        g.testParts.clear();
        g.hasSelection = false;
        ++g.generation;
        broadcastSelection();
    } else if (verb == "LOCK" || verb == "UNLOCK") {
        const bool lock = verb == "LOCK";
        if (lock != g.locked) {
            g.locked = lock;
            for (wl_resource *n : g.notifications) {
                if (lock)
                    hyprland_lock_notification_v1_send_locked(n);
                else
                    hyprland_lock_notification_v1_send_unlocked(n);
            }
        }
        say(lock ? "LOCKED" : "UNLOCKED");
    } else if (verb == "PASTE") {
        std::string mime, out;
        size_t chunk = 0;
        int delayMs = 0;
        in >> mime >> out;
        if (!(in >> chunk >> delayMs)) {
            chunk = 0;
            delayMs = 0;
        }
        paste(mime, out, chunk, delayMs);
    } else if (verb == "STALL") {
        std::string mime;
        in >> mime;
        stall(mime);
    } else if (verb == "FINISH") {
        // The compositor ends every data-control device (ext_data_control_device_v1.finished): a client must make a new one.
        for (wl_resource *d : g.devices)
            ext_data_control_device_v1_send_finished(d);
        say("FINISHED");
    } else if (verb == "QUIT") {
        wl_display_terminate(g.display);
    }
    wl_display_flush_clients(g.display);
}

int stdinReadable(int fd, uint32_t, void *)
{
    char buf[4096];
    const ssize_t n = ::read(fd, buf, sizeof buf);
    if (n <= 0) {
        wl_display_terminate(g.display);
        return 0;
    }
    g.stdinBuffer.append(buf, size_t(n));
    size_t nl;
    while ((nl = g.stdinBuffer.find('\n')) != std::string::npos) {
        const std::string line = g.stdinBuffer.substr(0, nl);
        g.stdinBuffer.erase(0, nl + 1);
        command(line);
    }
    return 0;
}

void clientCreated(wl_listener *, void *)
{
    say("CLIENT " + std::to_string(++g.clients));
}

wl_listener g_clientListener{{}, clientCreated};
} // namespace

int main(int argc, char **argv)
{
    std::string path;
    bool lockNotifier = true, dataControl = true;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--socket" && i + 1 < argc)
            path = argv[++i];
        else if (a == "--no-lock-notifier")
            lockNotifier = false;
        else if (a == "--no-data-control")
            dataControl = false;
    }
    if (path.empty() || path[0] != '/') {
        std::fprintf(stderr, "usage: fake-clipboard-server --socket <absolute path>\n");
        return 2;
    }
    ::signal(SIGPIPE, SIG_IGN);
    g.display = wl_display_create();
    const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, path.c_str(), sizeof addr.sun_path - 1);
    ::unlink(path.c_str());
    if (::bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof addr) != 0 || ::listen(fd, 16) != 0
        || wl_display_add_socket_fd(g.display, fd) != 0) {
        std::fprintf(stderr, "fake-clipboard-server: cannot listen on %s\n", path.c_str());
        return 1;
    }
    wl_display_add_client_created_listener(g.display, &g_clientListener);
    wl_global_create(g.display, &wl_seat_interface, 1, nullptr, bindSeat);
    if (dataControl)
        wl_global_create(g.display, &ext_data_control_manager_v1_interface, 1, nullptr, bindManager);
    if (lockNotifier)
        wl_global_create(g.display, &hyprland_lock_notifier_v1_interface, 1, nullptr, bindNotifier);
    wl_event_loop_add_fd(wl_display_get_event_loop(g.display), 0, WL_EVENT_READABLE, stdinReadable, nullptr);
    say("READY");
    wl_display_run(g.display);
    for (const int h : g.hung)
        ::close(h);
    wl_display_destroy_clients(g.display);
    wl_display_destroy(g.display);
    ::unlink(path.c_str());
    return 0;
}
