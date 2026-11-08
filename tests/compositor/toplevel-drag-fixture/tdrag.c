// SPDX-License-Identifier: MIT
// tdrag: a Chromium stand-in for xdg_toplevel_drag_v1 (tests/compositor/toplevel_drag.sh, URR-030, ADR-0036 amendment
// 2026-11-08), for the NESTED dev compositor only: run it through tests/compositor/toplevel-drag-fixture/tdrag.sh, which
// targets the verified nested socket.
//
// Usage: tdrag MODE
// Opens two toplevels titled "gf-tdrag-source" and "gf-tdrag-target" (400x300 each) and prints "ready" once both are mapped.
// A left press on the source starts a drag and drop, as a tab drag does: a wl_data_source offering "application/x-gf-tdrag"
// (action move), an xdg_toplevel_drag_v1 for it, wl_data_device.start_drag with the press's serial; then, by MODE:
//   tear          a new toplevel "gf-tdrag-torn" (320x200) is attached at offset 40,12 before it maps (a torn-off tab)
//   merge         as tear, and the torn window unmaps itself when the drag enters the target (the tab joins its strip),
//                 then is attached again and maps when the drag leaves it (pulled out again)
//   existing      no new window: the source itself is attached (mapped) before start_drag (dragging a window's only tab)
//   attach-twice  as tear, then a second attach while the first toplevel is attached (protocol error toplevel_attached)
//   destroy-early the xdg_toplevel_drag_v1 is destroyed right after start_drag (protocol error ongoing_drag)
//   source-twice  a second xdg_toplevel_drag_v1 for the same source (protocol error invalid_source)
// The target accepts the offer (a drop there is dnd_drop_performed); nothing else does (a release elsewhere: cancelled).
// Prints, one line each: "global xdg_toplevel_drag_manager_v1 V" (or "no xdg_toplevel_drag_manager_v1", exit 4), "drag
// started", "attached torn|source", "mapped torn", "unmapped torn", "enter source|target|torn|other", "leave", "drop target",
// "dnd_drop_performed", "dnd_finished", "cancelled", "drag object destroyed", "protocol error <interface> <code>" (exit 3).
// Ends on SIGTERM/SIGINT.
#define _GNU_SOURCE
#include "xdg-shell-client-protocol.h"
#include "xdg-toplevel-drag-v1-client-protocol.h"

#include <errno.h>
#include <linux/input-event-codes.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

static const char* const kMime = "application/x-gf-tdrag";

struct window {
    const char*          title;
    int                  w, h;
    struct wl_surface*   surface;
    struct xdg_surface*  xs;
    struct xdg_toplevel* top;
    int                  mapped;  // a buffer is attached
    int                  hidden;  // unmapped on purpose (a null buffer); a new configure sequence maps it again
};

static struct wl_display*                   display;
static struct wl_compositor*                compositor;
static struct wl_shm*                       shm;
static struct xdg_wm_base*                  wm_base;
static struct wl_seat*                      seat;
static struct wl_data_device_manager*       ddm;
static struct wl_data_device*               device;
static struct xdg_toplevel_drag_manager_v1* drag_manager;
static uint32_t                             drag_manager_version;
static struct window                        source_win = {.title = "gf-tdrag-source", .w = 400, .h = 300};
static struct window                        target_win = {.title = "gf-tdrag-target", .w = 400, .h = 300};
static struct window                        torn_win   = {.title = "gf-tdrag-torn", .w = 320, .h = 200};
static struct wl_surface*                   pointer_focus;
static struct wl_data_source*               source;
static struct xdg_toplevel_drag_v1*         drag;
static struct wl_data_offer*                offer;
static struct wl_surface*                   dnd_focus;
static const char*                          mode = "tear";
static volatile sig_atomic_t                want_exit;
static int                                  ready_printed;

static void say(const char* fmt, const char* arg) {
    printf(fmt, arg);
    printf("\n");
    fflush(stdout);
}

static void on_signal(int sig) {
    (void)sig;
    want_exit = 1;
}

static const char* name_of(struct wl_surface* s) {
    if (!s)
        return "none";
    if (s == source_win.surface)
        return "source";
    if (s == target_win.surface)
        return "target";
    if (s == torn_win.surface)
        return "torn";
    return "other";
}

static void global_add(void* data, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    (void)data;
    if (strcmp(iface, wl_compositor_interface.name) == 0)
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0 && !seat)
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    else if (strcmp(iface, wl_data_device_manager_interface.name) == 0 && version >= 3)
        ddm = wl_registry_bind(reg, name, &wl_data_device_manager_interface, 3);
    else if (strcmp(iface, xdg_toplevel_drag_manager_v1_interface.name) == 0) {
        drag_manager         = wl_registry_bind(reg, name, &xdg_toplevel_drag_manager_v1_interface, 1);
        drag_manager_version = version;
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

static void buffer_release(void* data, struct wl_buffer* buf) {
    (void)data;
    wl_buffer_destroy(buf);
}
static const struct wl_buffer_listener buffer_listener = {buffer_release};

static struct wl_buffer* make_buffer(int width, int height, uint32_t argb) {
    const int stride = width * 4;
    const int size   = stride * height;
    int       fd     = memfd_create("tdrag", MFD_CLOEXEC);
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

static void print_ready(void) {
    if (!ready_printed && source_win.mapped && target_win.mapped) {
        ready_printed = 1;
        say("%s", "ready");
    }
}

// Each window draws its fixed size at its first configure of a sequence (a hidden one maps again then).
static void surface_configure(void* data, struct xdg_surface* xs, uint32_t serial) {
    struct window* win = data;
    xdg_surface_ack_configure(xs, serial);
    if (win->mapped)
        return;
    const uint32_t colour = win == &torn_win ? 0xffa53a6e : win == &target_win ? 0xff3aa56e : 0xff3a6ea5;
    struct wl_buffer* buf = make_buffer(win->w, win->h, colour);
    if (!buf)
        return;
    wl_surface_attach(win->surface, buf, 0, 0);
    wl_surface_commit(win->surface);
    win->mapped = 1;
    win->hidden = 0;
    if (win == &torn_win)
        say("%s", "mapped torn");
    print_ready();
}
static const struct xdg_surface_listener surface_listener = {surface_configure};

static void toplevel_configure(void* data, struct xdg_toplevel* t, int32_t w, int32_t h, struct wl_array* states) {
    (void)data;
    (void)t;
    (void)w;
    (void)h;
    (void)states;
}
static void toplevel_close(void* data, struct xdg_toplevel* t) {
    (void)data;
    (void)t;
}
static const struct xdg_toplevel_listener toplevel_listener = {.configure = toplevel_configure, .close = toplevel_close};

static void create_window(struct window* win) {
    win->surface = wl_compositor_create_surface(compositor);
    win->xs      = xdg_wm_base_get_xdg_surface(wm_base, win->surface);
    win->top     = xdg_surface_get_toplevel(win->xs);
    xdg_surface_add_listener(win->xs, &surface_listener, win);
    xdg_toplevel_add_listener(win->top, &toplevel_listener, win);
    xdg_toplevel_set_app_id(win->top, win->title);
    xdg_toplevel_set_title(win->top, win->title);
}

// The initial commit of a configure sequence (no buffer): the compositor configures, the configure handler maps it.
static void request_map(struct window* win) {
    wl_surface_commit(win->surface);
}

static void hide(struct window* win) {
    wl_surface_attach(win->surface, NULL, 0, 0);
    wl_surface_commit(win->surface);
    win->mapped = 0;
    win->hidden = 1;
    if (win == &torn_win)
        say("%s", "unmapped torn");
}

// ---- wl_data_source --------------------------------------------------------------------------------------------------

static void end_drag(void) {
    if (drag) {
        xdg_toplevel_drag_v1_destroy(drag); // allowed now: the drag ended
        drag = NULL;
        say("%s", "drag object destroyed");
    }
    if (source) {
        wl_data_source_destroy(source);
        source = NULL;
    }
}

static void source_target(void* data, struct wl_data_source* s, const char* mime) {
    (void)data;
    (void)s;
    (void)mime;
}
static void source_send(void* data, struct wl_data_source* s, const char* mime, int32_t fd) {
    (void)data;
    (void)s;
    (void)mime;
    close(fd);
}
static void source_cancelled(void* data, struct wl_data_source* s) {
    (void)data;
    (void)s;
    say("%s", "cancelled");
    end_drag();
}
static void source_drop_performed(void* data, struct wl_data_source* s) {
    (void)data;
    (void)s;
    say("%s", "dnd_drop_performed");
}
static void source_finished(void* data, struct wl_data_source* s) {
    (void)data;
    (void)s;
    say("%s", "dnd_finished");
    end_drag();
}
static void source_action(void* data, struct wl_data_source* s, uint32_t action) {
    (void)data;
    (void)s;
    (void)action;
}
static const struct wl_data_source_listener source_listener = {
    .target = source_target, .send = source_send, .cancelled = source_cancelled, .dnd_drop_performed = source_drop_performed,
    .dnd_finished = source_finished, .action = source_action};

static void attach_torn(void) {
    xdg_toplevel_drag_v1_attach(drag, torn_win.top, 40, 12);
    say("%s", "attached torn");
    request_map(&torn_win);
}

static void start_drag(uint32_t serial) {
    if (source || !device)
        return;
    source = wl_data_device_manager_create_data_source(ddm);
    wl_data_source_add_listener(source, &source_listener, NULL);
    wl_data_source_offer(source, kMime);
    wl_data_source_set_actions(source, WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE);
    drag = xdg_toplevel_drag_manager_v1_get_xdg_toplevel_drag(drag_manager, source);
    if (strcmp(mode, "source-twice") == 0)
        xdg_toplevel_drag_manager_v1_get_xdg_toplevel_drag(drag_manager, source); // invalid_source
    if (strcmp(mode, "existing") == 0) {
        xdg_toplevel_drag_v1_attach(drag, source_win.top, 0, 0); // the mapped window itself, before start_drag
        say("%s", "attached source");
    }
    wl_data_device_start_drag(device, source, source_win.surface, NULL, serial);
    say("%s", "drag started");
    if (strcmp(mode, "destroy-early") == 0) {
        xdg_toplevel_drag_v1_destroy(drag); // ongoing_drag
        drag = NULL;
        return;
    }
    if (strcmp(mode, "existing") == 0)
        return;
    if (!torn_win.surface)
        create_window(&torn_win);
    attach_torn();
    if (strcmp(mode, "attach-twice") == 0)
        xdg_toplevel_drag_v1_attach(drag, target_win.top, 0, 0); // toplevel_attached
}

// ---- wl_data_device ---------------------------------------------------------------------------------------------------

static void offer_offer(void* data, struct wl_data_offer* o, const char* mime) {
    (void)data;
    (void)o;
    (void)mime;
}
static void offer_source_actions(void* data, struct wl_data_offer* o, uint32_t actions) {
    (void)data;
    (void)o;
    (void)actions;
}
static void offer_action(void* data, struct wl_data_offer* o, uint32_t action) {
    (void)data;
    (void)o;
    (void)action;
}
static const struct wl_data_offer_listener offer_listener = {.offer = offer_offer, .source_actions = offer_source_actions, .action = offer_action};

static void device_data_offer(void* data, struct wl_data_device* d, struct wl_data_offer* o) {
    (void)data;
    (void)d;
    wl_data_offer_add_listener(o, &offer_listener, NULL);
}
static void device_enter(void* data, struct wl_data_device* d, uint32_t serial, struct wl_surface* s, wl_fixed_t x, wl_fixed_t y, struct wl_data_offer* o) {
    (void)data;
    (void)d;
    (void)x;
    (void)y;
    if (offer && offer != o)
        wl_data_offer_destroy(offer);
    offer     = o;
    dnd_focus = s;
    say("enter %s", name_of(s));
    if (!o)
        return;
    if (s == target_win.surface) {
        wl_data_offer_accept(o, serial, kMime);
        wl_data_offer_set_actions(o, WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE, WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE);
        if (strcmp(mode, "merge") == 0 && drag && torn_win.mapped)
            hide(&torn_win); // the tab joins the target's strip: the torn window goes (the compositor detaches it)
    } else {
        wl_data_offer_accept(o, serial, NULL);
        wl_data_offer_set_actions(o, 0, 0);
    }
}
static void device_leave(void* data, struct wl_data_device* d) {
    (void)data;
    (void)d;
    say("%s", "leave");
    if (strcmp(mode, "merge") == 0 && dnd_focus == target_win.surface && drag && torn_win.hidden)
        attach_torn(); // pulled out again: attached again before it maps again
    dnd_focus = NULL;
    if (offer) {
        wl_data_offer_destroy(offer);
        offer = NULL;
    }
}
static void device_motion(void* data, struct wl_data_device* d, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    (void)data;
    (void)d;
    (void)time;
    (void)x;
    (void)y;
}
static void device_drop(void* data, struct wl_data_device* d) {
    (void)data;
    (void)d;
    say("drop %s", name_of(dnd_focus));
    if (offer && dnd_focus == target_win.surface) {
        wl_data_offer_finish(offer);
    }
    if (offer) {
        wl_data_offer_destroy(offer);
        offer = NULL;
    }
}
static void device_selection(void* data, struct wl_data_device* d, struct wl_data_offer* o) {
    (void)data;
    (void)d;
    if (o && o != offer)
        wl_data_offer_destroy(o);
}
static const struct wl_data_device_listener device_listener = {
    .data_offer = device_data_offer, .enter = device_enter, .leave = device_leave, .motion = device_motion, .drop = device_drop, .selection = device_selection};

// ---- wl_pointer -------------------------------------------------------------------------------------------------------

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
    (void)time;
    if (button == BTN_LEFT && state == WL_POINTER_BUTTON_STATE_PRESSED && pointer_focus == source_win.surface)
        start_drag(serial);
}
static void pointer_axis(void* data, struct wl_pointer* p, uint32_t time, uint32_t axis, wl_fixed_t value) {
    (void)data;
    (void)p;
    (void)time;
    (void)axis;
    (void)value;
}
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

static int report_error(void) {
    const struct wl_interface* iface = NULL;
    uint32_t                   id    = 0;
    const uint32_t             code  = wl_display_get_protocol_error(display, &iface, &id);
    if (wl_display_get_error(display) == EPROTO && iface) {
        printf("protocol error %s %u\n", iface->name, code);
        fflush(stdout);
        return 3;
    }
    return 1;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: tdrag tear|merge|existing|attach-twice|destroy-early|source-twice\n");
        return 2;
    }
    mode    = argv[1];
    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "tdrag: no wayland display\n");
        return 1;
    }
    struct sigaction sa = {.sa_handler = on_signal};
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    struct wl_registry* reg = wl_display_get_registry(display);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!compositor || !shm || !wm_base || !seat || !ddm) {
        fprintf(stderr, "tdrag: the compositor lacks wl_compositor, wl_shm, xdg_wm_base, wl_seat or wl_data_device_manager v3\n");
        return 1;
    }
    if (!drag_manager) {
        say("%s", "no xdg_toplevel_drag_manager_v1");
        return 4;
    }
    printf("global xdg_toplevel_drag_manager_v1 %u\n", drag_manager_version);
    fflush(stdout);
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    wl_seat_add_listener(seat, &seat_listener, NULL);
    device = wl_data_device_manager_get_data_device(ddm, seat);
    wl_data_device_add_listener(device, &device_listener, NULL);
    create_window(&source_win);
    create_window(&target_win);
    request_map(&source_win);
    request_map(&target_win);

    int rc = 0;
    while (!want_exit) {
        if (wl_display_flush(display) < 0 && errno != EAGAIN) {
            rc = report_error();
            break;
        }
        struct pollfd pfd = {.fd = wl_display_get_fd(display), .events = POLLIN};
        while (wl_display_prepare_read(display) != 0) {
            if (wl_display_dispatch_pending(display) < 0) {
                rc = report_error();
                goto done;
            }
        }
        wl_display_flush(display);
        int n = poll(&pfd, 1, 50);
        if (n > 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
            wl_display_cancel_read(display);
            rc = report_error();
            break;
        }
        if (n > 0 && (pfd.revents & POLLIN)) {
            if (wl_display_read_events(display) < 0 || wl_display_dispatch_pending(display) < 0) {
                rc = report_error();
                break;
            }
        } else {
            wl_display_cancel_read(display);
        }
        if (n < 0 && errno != EINTR)
            break;
    }
done:
    wl_display_disconnect(display);
    return rc;
}
