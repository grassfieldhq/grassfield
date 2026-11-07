// SPDX-License-Identifier: MIT
// xdgact: a window that activates ITSELF through xdg-activation-v1, for the NESTED dev compositor (tests/shell/show_desktop_nested.sh),
// that unmaps itself without being destroyed (tests/compositor/tiling.sh, gate C1), and that opens a popup over its right edge
// (tests/compositor/tiling.sh, the shared edge's handle behind a popup).
// Never run it against the owner's session: use tests/tools/xdgact/xdgact.sh, which targets only the verified nested socket.
//
// Usage: xdgact APP_ID [MIN_WIDTH | WxH]
// Opens a small toplevel with the app id, prints "mapped" once it is shown, and waits. On SIGUSR1 it asks the compositor for an
// activation token and activates its own surface with it: what an app does to bring its window forward (a real client request,
// handled by Hyprland's CWindow::activate with misc.focus_on_activate), as opposed to the focus dispatcher. Prints "activated" when
// the request is sent. On SIGUSR2 it attaches a null buffer and commits: the toplevel unmaps while every object stays alive (what an
// app that closes to the tray does), and prints "unmapped". On SIGHUP it opens an xdg popup (no grab) on the middle of its right
// edge, extending right, and prints "popup mapped APP_ID"; a pointer button pressed on that popup prints "popup pressed APP_ID". The
// toplevel draws a buffer of the size the compositor configures. Ends on SIGTERM/SIGINT or when the window is closed.
// With MIN_WIDTH the toplevel also asks for that minimum width (xdg_toplevel.set_min_size) and never draws
// narrower, as an app with a wide minimum does (tests/compositor/tiling.sh: a window too wide for half of the output, TL33).
// With WxH the toplevel is of fixed size: its minimum and maximum are both WxH (xdg_toplevel.set_min_size, set_max_size) and it
// always draws that size, whatever the compositor configures, as a window that cannot be resized does (tests/compositor/tiling.sh:
// the plugin's titlebar disables its zoom light and the Zoom and Full Screen keys leave it alone, ADR-0040 step 1b's review).
// Decorations (tests/compositor/decorations.sh): the toplevel asks for server-side decorations through xdg-decoration, as an app
// that draws no title bar of its own does (foot, Qt, SDL); with XDGACT_DECORATION=client it asks for client-side ones (and still
// draws no bar, as foot -o csd.preferred=client under Hyprland's server_side answer); with XDGACT_DECORATION=none it binds the
// manager and makes no decoration object (what Qt does for a frameless window, which decorates itself); with
// XDGACT_DECORATION=unbound it does not bind the manager at all (imv: it draws no bar either).
#define _GNU_SOURCE
#include "xdg-activation-v1-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#define WIDTH 240
#define HEIGHT 140

static struct wl_compositor*       compositor;
static struct wl_shm*              shm;
static struct xdg_wm_base*         wm_base;
static struct xdg_activation_v1*   activation;
static struct zxdg_decoration_manager_v1* decoration_manager;
static struct wl_seat*             seat;
static struct wl_surface*          surface;
static struct xdg_surface*         toplevel_xs;
static struct wl_surface*          popup_surface;
static struct wl_surface*          pointer_focus;
static struct wl_display*          display;
static const char*                 app_id;
static volatile sig_atomic_t       want_activate;
static volatile sig_atomic_t       want_unmap;
static volatile sig_atomic_t       want_popup;
static volatile sig_atomic_t       want_exit;
static int                         closed;
static int                         mapped;
static int                         unmapped;
static int                         popup_mapped;
static int                         cfg_w = WIDTH, cfg_h = HEIGHT; // the size the compositor configured (its default before any)
static int                         min_w = 0;                     // the minimum width asked (0: none)
static int                         fixed_w = 0, fixed_h = 0;      // a window of fixed size: minimum = maximum (0: none)
static int                         buf_w, buf_h;

static void on_signal(int sig) {
    if (sig == SIGUSR1)
        want_activate = 1;
    else if (sig == SIGUSR2)
        want_unmap = 1;
    else if (sig == SIGHUP)
        want_popup = 1;
    else
        want_exit = 1;
}

static void global_add(void* data, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    (void)data;
    (void)version;
    if (strcmp(iface, wl_compositor_interface.name) == 0)
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (strcmp(iface, xdg_activation_v1_interface.name) == 0)
        activation = wl_registry_bind(reg, name, &xdg_activation_v1_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0 && !seat)
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    else if (strcmp(iface, zxdg_decoration_manager_v1_interface.name) == 0) {
        const char* decoration = getenv("XDGACT_DECORATION");
        if (!(decoration && strcmp(decoration, "unbound") == 0))
            decoration_manager = wl_registry_bind(reg, name, &zxdg_decoration_manager_v1_interface, 1);
    }
}
static void global_remove(void* data, struct wl_registry* reg, uint32_t name) {
    (void)data;
    (void)reg;
    (void)name;
}
static const struct wl_registry_listener registry_listener = {global_add, global_remove};

static void ping(void* data, struct xdg_wm_base* base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {ping};

// A buffer the compositor no longer reads is destroyed.
static void buffer_release(void* data, struct wl_buffer* buf) {
    (void)data;
    wl_buffer_destroy(buf);
}
static const struct wl_buffer_listener buffer_listener = {buffer_release};

static struct wl_buffer* make_buffer(int width, int height, uint32_t argb) {
    const int stride = width * 4;
    const int size   = stride * height;
    int       fd     = memfd_create("xdgact", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, size) < 0) {
        if (fd >= 0)
            close(fd);
        return NULL;
    }
    uint32_t* px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) {
        close(fd);
        return NULL;
    }
    for (int i = 0; i < width * height; i++)
        px[i] = argb;
    munmap(px, size);
    struct wl_shm_pool* pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer*   buf  = wl_shm_pool_create_buffer(pool, 0, width, height, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    wl_buffer_add_listener(buf, &buffer_listener, NULL);
    return buf;
}

// The toplevel at the size last configured (its first buffer maps it; never again once it unmapped itself).
static void surface_configure(void* data, struct xdg_surface* xs, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xs, serial);
    if (unmapped || (mapped && buf_w == cfg_w && buf_h == cfg_h))
        return;
    struct wl_buffer* buf = make_buffer(cfg_w, cfg_h, 0xff3a6ea5);
    if (!buf)
        return;
    wl_surface_attach(surface, buf, 0, 0);
    wl_surface_commit(surface);
    buf_w = cfg_w;
    buf_h = cfg_h;
    if (!mapped) {
        mapped = 1;
        printf("mapped\n");
        fflush(stdout);
    }
}
static const struct xdg_surface_listener surface_listener = {surface_configure};

static void toplevel_configure(void* data, struct xdg_toplevel* t, int32_t w, int32_t h, struct wl_array* states) {
    (void)data;
    (void)t;
    (void)states;
    if (fixed_w > 0)
        return; // a window of fixed size draws its size, whatever is configured
    if (w > 0 && h > 0) {
        cfg_w = w < min_w ? min_w : w;
        cfg_h = h;
    }
}
static void toplevel_close(void* data, struct xdg_toplevel* t) {
    (void)data;
    (void)t;
    closed = 1;
}
static void toplevel_bounds(void* data, struct xdg_toplevel* t, int32_t w, int32_t h) {
    (void)data;
    (void)t;
    (void)w;
    (void)h;
}
static void toplevel_caps(void* data, struct xdg_toplevel* t, struct wl_array* caps) {
    (void)data;
    (void)t;
    (void)caps;
}
static const struct xdg_toplevel_listener toplevel_listener = {toplevel_configure, toplevel_close, toplevel_bounds, toplevel_caps};

static void token_done(void* data, struct xdg_activation_token_v1* token, const char* str) {
    (void)data;
    xdg_activation_v1_activate(activation, str, surface);
    xdg_activation_token_v1_destroy(token);
    printf("activated\n");
    fflush(stdout);
}
static const struct xdg_activation_token_v1_listener token_listener = {token_done};

static void popup_surface_configure(void* data, struct xdg_surface* xs, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xs, serial);
    if (popup_mapped)
        return;
    struct wl_buffer* buf = make_buffer(WIDTH, HEIGHT, 0xffa53a6e);
    if (!buf)
        return;
    wl_surface_attach(popup_surface, buf, 0, 0);
    wl_surface_commit(popup_surface);
    popup_mapped = 1;
    printf("popup mapped %s\n", app_id);
    fflush(stdout);
}
static const struct xdg_surface_listener popup_surface_listener = {popup_surface_configure};

static void popup_configure(void* data, struct xdg_popup* p, int32_t x, int32_t y, int32_t w, int32_t h) {
    (void)data;
    (void)p;
    (void)x;
    (void)y;
    (void)w;
    (void)h;
}
static void popup_done(void* data, struct xdg_popup* p) {
    (void)data;
    (void)p;
    printf("popup done %s\n", app_id);
    fflush(stdout);
}
static const struct xdg_popup_listener popup_listener = {.configure = popup_configure, .popup_done = popup_done}; // xdg_wm_base v1: no repositioned

// A popup without a grab on the middle of the toplevel's right edge, extending right.
static void open_popup(void) {
    if (popup_surface || unmapped)
        return;
    struct xdg_positioner* pos = xdg_wm_base_create_positioner(wm_base);
    xdg_positioner_set_size(pos, WIDTH, HEIGHT);
    xdg_positioner_set_anchor_rect(pos, 0, 0, buf_w > 0 ? buf_w : WIDTH, buf_h > 0 ? buf_h : HEIGHT);
    xdg_positioner_set_anchor(pos, XDG_POSITIONER_ANCHOR_RIGHT);
    xdg_positioner_set_gravity(pos, XDG_POSITIONER_GRAVITY_RIGHT);
    popup_surface             = wl_compositor_create_surface(compositor);
    struct xdg_surface* pxs   = xdg_wm_base_get_xdg_surface(wm_base, popup_surface);
    struct xdg_popup*   popup = xdg_surface_get_popup(pxs, toplevel_xs, pos);
    xdg_positioner_destroy(pos);
    xdg_surface_add_listener(pxs, &popup_surface_listener, NULL);
    xdg_popup_add_listener(popup, &popup_listener, NULL);
    wl_surface_commit(popup_surface);
}

static void pointer_enter(void* data, struct wl_pointer* p, uint32_t serial, struct wl_surface* s, wl_fixed_t x, wl_fixed_t y) {
    (void)data;
    (void)p;
    (void)serial;
    (void)x;
    (void)y;
    pointer_focus = s;
}
static void pointer_leave(void* data, struct wl_pointer* p, uint32_t serial, struct wl_surface* s) {
    (void)data;
    (void)p;
    (void)serial;
    if (pointer_focus == s)
        pointer_focus = NULL;
}
static void pointer_motion(void* data, struct wl_pointer* p, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    (void)data;
    (void)p;
    (void)time;
    (void)x;
    (void)y;
}
static void pointer_button(void* data, struct wl_pointer* p, uint32_t serial, uint32_t time, uint32_t button, uint32_t state) {
    (void)data;
    (void)p;
    (void)serial;
    (void)time;
    (void)button;
    if (state == WL_POINTER_BUTTON_STATE_PRESSED && popup_surface && pointer_focus == popup_surface) {
        printf("popup pressed %s\n", app_id);
        fflush(stdout);
    }
}
static void pointer_axis(void* data, struct wl_pointer* p, uint32_t time, uint32_t axis, wl_fixed_t value) {
    (void)data;
    (void)p;
    (void)time;
    (void)axis;
    (void)value;
}
// wl_seat version 1: wl_pointer version 1 sends only these.
static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter, .leave = pointer_leave, .motion = pointer_motion, .button = pointer_button, .axis = pointer_axis};

static void seat_capabilities(void* data, struct wl_seat* s, uint32_t caps) {
    (void)data;
    static struct wl_pointer* pointer;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
        pointer = wl_seat_get_pointer(s);
        wl_pointer_add_listener(pointer, &pointer_listener, NULL);
    }
}
static const struct wl_seat_listener seat_listener = {.capabilities = seat_capabilities};

static void request_activation(const char* app_id) {
    struct xdg_activation_token_v1* token = xdg_activation_v1_get_activation_token(activation);
    xdg_activation_token_v1_add_listener(token, &token_listener, NULL);
    xdg_activation_token_v1_set_app_id(token, app_id);
    xdg_activation_token_v1_set_surface(token, surface);
    xdg_activation_token_v1_commit(token);
}

int main(int argc, char** argv) {
    if (argc != 2 && argc != 3) {
        fprintf(stderr, "usage: xdgact APP_ID [MIN_WIDTH | WxH]\n");
        return 2;
    }
    if (argc == 3 && strchr(argv[2], 'x')) {
        char* end = NULL;
        long  w   = strtol(argv[2], &end, 10);
        long  h   = end && *end == 'x' ? strtol(end + 1, &end, 10) : 0;
        if (!end || *end != '\0' || w < 1 || w > 16384 || h < 1 || h > 16384) {
            fprintf(stderr, "xdgact: WxH must be two sizes of 1-16384\n");
            return 2;
        }
        fixed_w = (int)w;
        fixed_h = (int)h;
        cfg_w   = fixed_w;
        cfg_h   = fixed_h;
    } else if (argc == 3) {
        char* end = NULL;
        long  v   = strtol(argv[2], &end, 10);
        if (!end || *end != '\0' || v < 1 || v > 16384) {
            fprintf(stderr, "xdgact: MIN_WIDTH must be 1-16384\n");
            return 2;
        }
        min_w = (int)v;
        if (cfg_w < min_w)
            cfg_w = min_w;
    }
    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "xdgact: no wayland display\n");
        return 1;
    }
    struct sigaction sa = {.sa_handler = on_signal};
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    struct wl_registry* reg = wl_display_get_registry(display);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!compositor || !shm || !wm_base || !activation) {
        fprintf(stderr, "xdgact: the compositor lacks wl_compositor, wl_shm, xdg_wm_base or xdg_activation_v1\n");
        return 1;
    }
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    if (seat)
        wl_seat_add_listener(seat, &seat_listener, NULL);
    app_id                   = argv[1];
    surface                  = wl_compositor_create_surface(compositor);
    toplevel_xs              = xdg_wm_base_get_xdg_surface(wm_base, surface);
    struct xdg_toplevel* top = xdg_surface_get_toplevel(toplevel_xs);
    xdg_surface_add_listener(toplevel_xs, &surface_listener, NULL);
    xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(top, argv[1]);
    xdg_toplevel_set_title(top, argv[1]);
    if (min_w > 0)
        xdg_toplevel_set_min_size(top, min_w, 0);
    if (fixed_w > 0) {
        xdg_toplevel_set_min_size(top, fixed_w, fixed_h);
        xdg_toplevel_set_max_size(top, fixed_w, fixed_h);
    }
    const char* decoration = getenv("XDGACT_DECORATION");
    if (decoration_manager && !(decoration && strcmp(decoration, "none") == 0)) {
        struct zxdg_toplevel_decoration_v1* deco = zxdg_decoration_manager_v1_get_toplevel_decoration(decoration_manager, top);
        const int client = decoration && strcmp(decoration, "client") == 0;
        zxdg_toplevel_decoration_v1_set_mode(deco, client ? ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE : ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    }
    wl_surface_commit(surface);

    while (!want_exit && !closed) {
        wl_display_flush(display);
        if (want_activate) {
            want_activate = 0;
            request_activation(argv[1]);
            continue;
        }
        if (want_popup) {
            want_popup = 0;
            open_popup();
            continue;
        }
        if (want_unmap) {
            want_unmap = 0;
            unmapped   = 1;
            wl_surface_attach(surface, NULL, 0, 0);
            wl_surface_commit(surface);
            printf("unmapped\n");
            fflush(stdout);
            continue;
        }
        struct pollfd pfd = {.fd = wl_display_get_fd(display), .events = POLLIN};
        while (wl_display_prepare_read(display) != 0) {
            if (wl_display_dispatch_pending(display) < 0)
                goto done;
        }
        if (wl_display_flush(display) < 0 && errno != EAGAIN) {
            wl_display_cancel_read(display);
            break;   // the compositor is gone
        }
        int n = poll(&pfd, 1, 50);
        if (n > 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
            wl_display_cancel_read(display);
            break;   // the compositor hung up: end, do not spin
        }
        if (n > 0 && (pfd.revents & POLLIN)) {
            if (wl_display_read_events(display) < 0 || wl_display_dispatch_pending(display) < 0)
                break;
        } else {
            wl_display_cancel_read(display);
        }
        if (n < 0 && errno != EINTR)
            break;
    }
done:
    wl_display_disconnect(display);
    return 0;
}
