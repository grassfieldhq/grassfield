// SPDX-License-Identifier: MIT
// presentprobe: the presentation-time probe of gate P3 (ADR-0006 as amended: wp_presentation timestamps from a probe client).
//
// A tiny surface that commits a new buffer on every frame callback and asks wp_presentation for the feedback of every commit:
// the time each content update reached the screen, the output's refresh period and its vblank counter (MSC). A client only
// receives the feedback of its own surfaces, so the probe measures the compositor's output, not the shell's surfaces as such:
// every surface of an output is presented in the same frame, so a frame the shell's animation makes the compositor miss is a
// frame the probe misses too. scripts/gates/frame_pacing.py judges the record against the output's own refresh rate.
//
// The surface is a 1x1 overlay layer (wlr-layer-shell) in the top-left corner of the output, almost transparent (alpha 1/255),
// with an empty input region: it never takes a click and is not visible. Without layer-shell, or with --toplevel, it is a
// 64x64 xdg-toplevel (a tiling compositor arranges it as a window: the nested session only).
//
//   presentprobe [--seconds S] [--output NAME] [--toplevel] [--size N] [--real]
//     --seconds S  stop after S seconds (default 30; 0 = until SIGINT or SIGTERM, which also end it cleanly)
//     --output N   the output to put the layer surface on (wl_output.name, e.g. GF-REF or DP-1); default: the compositor's choice
//     --real       allow the owner's own session socket (wayland-1). Without it the probe refuses that socket, as every
//                  dev tool does (tests/tools/framepulse); scripts/gates/frame-pacing.sh --real passes it, run by the owner.
//
// Output (stdout, line-buffered; times in nanoseconds of the presentation clock):
//   # presentprobe 1
//   # clock <clk_id>                       the presentation clock (wp_presentation.clock_id: 1 MONOTONIC, 4 MONOTONIC_RAW)
//   # offset_ns <ns>                       CLOCK_REALTIME minus the presentation clock, sampled at start (and # offset_end_ns)
//   # surface layer|toplevel <W>x<H>
//   # output <name> <refresh_mHz> <W>x<H>   when the surface enters an output (its current mode)
//   p <commit> <present_ns> <refresh_ns> <msc> <flags> <commit_ns> <lag_ms>
//                                          a presented commit: refresh 0 = unknown or variable; flags = kind bits; commit_ns when
//                                          the probe committed it; lag_ms how late the probe handled the frame callback that
//                                          led to it (-1 unknown): the probe's own scheduling, not the compositor's
//   d <commit>                             a discarded commit (superseded before it reached the screen)
//   # end presented <N> discarded <D> commits <C> seconds <S>
// Exit: 0 after a run, 1 no connection or a missing global (wp_presentation, wl_shm, ...), 2 usage or a refused socket.
//
// Build: tests/tools/presentprobe/build.sh [OUTDIR] (wayland-scanner, wayland-protocols, libwayland-client, a C compiler).
#define _GNU_SOURCE
#include "presentation-time-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#define MAX_OUTPUTS 16

struct output {
    struct wl_output* wl;
    char              name[64];
    int32_t           refresh_mhz;
    int32_t           width, height;
};

static struct wl_compositor*         compositor;
static struct wl_shm*                shm;
static struct xdg_wm_base*           wm;
static struct zwlr_layer_shell_v1*   layer_shell;
static struct wp_presentation*       presentation;
static struct output                 outputs[MAX_OUTPUTS];
static int                           n_outputs;
static struct wl_surface*            surface;
static struct wl_buffer*             buffers[2];
static uint32_t*                     pixels[2];
static int                           width = 1, height = 1;
static int                           current;
static int                           configured;
static int                           use_toplevel;
static uint32_t                      clock_id = CLOCK_MONOTONIC;
static int                           have_clock;
static long                          commits, presented, discarded;
static int                           pending_lag_ms = -1; // of the frame callback that led to the next commit

#define MAX_TRACKED 4096
// Per commit, until its feedback arrives: when it was committed and how late the probe handled the callback before it.
static struct {
    int64_t commit_ns;
    int     lag_ms;
} tracked[MAX_TRACKED];
static volatile sig_atomic_t         done;

static int64_t clock_ns(clockid_t id) {
    struct timespec ts;
    clock_gettime(id, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

// CLOCK_REALTIME minus the presentation clock: the smallest of a few samples taken back to back (the least disturbed one).
static int64_t realtime_offset(void) {
    int64_t best = 0, best_span = INT64_MAX;
    for (int i = 0; i < 5; i++) {
        int64_t a = clock_ns((clockid_t)clock_id), r = clock_ns(CLOCK_REALTIME), b = clock_ns((clockid_t)clock_id);
        if (b - a < best_span) {
            best_span = b - a;
            best = r - (a + (b - a) / 2);
        }
    }
    return best;
}

static void on_signal(int sig) {
    (void)sig;
    done = 1;
}

// --- wl_output ---------------------------------------------------------------------------------------------------------------
static void output_geometry(void* d, struct wl_output* o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sp, const char* make,
                            const char* model, int32_t tr) {
    (void)d; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)sp; (void)make; (void)model; (void)tr;
}
static void output_mode(void* d, struct wl_output* o, uint32_t flags, int32_t w, int32_t h, int32_t refresh) {
    (void)o;
    struct output* out = d;
    if (flags & WL_OUTPUT_MODE_CURRENT) {
        out->width = w;
        out->height = h;
        out->refresh_mhz = refresh;
    }
}
static void output_done(void* d, struct wl_output* o) { (void)d; (void)o; }
static void output_scale(void* d, struct wl_output* o, int32_t s) { (void)d; (void)o; (void)s; }
static void output_name(void* d, struct wl_output* o, const char* name) {
    (void)o;
    struct output* out = d;
    snprintf(out->name, sizeof out->name, "%s", name);
}
static void output_description(void* d, struct wl_output* o, const char* desc) { (void)d; (void)o; (void)desc; }
static const struct wl_output_listener output_listener = {output_geometry, output_mode, output_done, output_scale, output_name,
                                                          output_description};

// --- registry -------------------------------------------------------------------------------------------------------------
static void ping(void* data, struct xdg_wm_base* base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {ping};

static void clock_event(void* data, struct wp_presentation* p, uint32_t clk) {
    (void)data;
    (void)p;
    clock_id = clk;
    have_clock = 1;
}
static const struct wp_presentation_listener presentation_listener = {clock_event};

static uint32_t min_u(uint32_t a, uint32_t b) { return a < b ? a : b; }

static void registry_global(void* data, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    (void)data;
    if (!strcmp(iface, wl_compositor_interface.name))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, min_u(version, 4));
    else if (!strcmp(iface, wl_shm_interface.name))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, xdg_wm_base_interface.name)) {
        wm = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    } else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name))
        layer_shell = wl_registry_bind(reg, name, &zwlr_layer_shell_v1_interface, min_u(version, 4));
    else if (!strcmp(iface, wp_presentation_interface.name)) {
        presentation = wl_registry_bind(reg, name, &wp_presentation_interface, 1);
        wp_presentation_add_listener(presentation, &presentation_listener, NULL);
    } else if (!strcmp(iface, wl_output_interface.name) && n_outputs < MAX_OUTPUTS) {
        struct output* out = &outputs[n_outputs++];
        out->wl = wl_registry_bind(reg, name, &wl_output_interface, min_u(version, 4));
        snprintf(out->name, sizeof out->name, "output-%d", n_outputs);
        wl_output_add_listener(out->wl, &output_listener, out);
    }
}
static void registry_remove(void* data, struct wl_registry* reg, uint32_t name) {
    (void)data;
    (void)reg;
    (void)name;
}
static const struct wl_registry_listener registry_listener = {registry_global, registry_remove};

// --- presentation feedback -------------------------------------------------------------------------------------------------
static void fb_sync_output(void* data, struct wp_presentation_feedback* f, struct wl_output* o) {
    (void)data;
    (void)f;
    (void)o;
}
static void fb_presented(void* data, struct wp_presentation_feedback* f, uint32_t sec_hi, uint32_t sec_lo, uint32_t nsec,
                         uint32_t refresh, uint32_t seq_hi, uint32_t seq_lo, uint32_t flags) {
    long    commit = (long)(intptr_t)data;
    int64_t t = (int64_t)((((uint64_t)sec_hi << 32) | sec_lo) * 1000000000ull) + nsec;
    uint64_t msc = ((uint64_t)seq_hi << 32) | seq_lo;
    printf("p %ld %lld %u %llu %u %lld %d\n", commit, (long long)t, refresh, (unsigned long long)msc, flags,
           (long long)tracked[commit % MAX_TRACKED].commit_ns, tracked[commit % MAX_TRACKED].lag_ms);
    presented++;
    wp_presentation_feedback_destroy(f);
}
static void fb_discarded(void* data, struct wp_presentation_feedback* f) {
    printf("d %ld\n", (long)(intptr_t)data);
    discarded++;
    wp_presentation_feedback_destroy(f);
}
static const struct wp_presentation_feedback_listener feedback_listener = {fb_sync_output, fb_presented, fb_discarded};

// --- drawing ----------------------------------------------------------------------------------------------------------------
static void draw(void);

// How late the probe itself handled a frame callback, in ms: now minus the callback's timestamp. The protocol leaves the
// timestamp's clock open (Hyprland: CLOCK_MONOTONIC, Weston: the presentation clock), so both are tried and the smallest
// plausible difference wins; -1 when neither fits. A large lag means the probe was not scheduled in time (a loaded CPU), not
// that the compositor was late: frame_pacing.py keeps those frames apart.
static int callback_lag_ms(uint32_t time) {
    const clockid_t clocks[2] = {(clockid_t)clock_id, CLOCK_MONOTONIC};
    int             best = -1;
    for (int i = 0; i < 2; i++) {
        int32_t lag = (int32_t)((uint32_t)(clock_ns(clocks[i]) / 1000000) - time);
        if (lag >= 0 && lag < 10000 && (best < 0 || lag < best))
            best = lag;
    }
    return best;
}

static void frame_done(void* data, struct wl_callback* cb, uint32_t time) {
    (void)data;
    wl_callback_destroy(cb);
    pending_lag_ms = callback_lag_ms(time);
    if (!done)
        draw();
}
static const struct wl_callback_listener frame_listener = {frame_done};

static void draw(void) {
    // Two buffers in turn, each a different colour, so every commit is a real change of content (real damage).
    current ^= 1;
    uint32_t px = use_toplevel ? (0xFF000000u | (uint32_t)((commits * 7) & 0xFF) << 8)
                               : (current ? 0x01010101u : 0x01000000u); // premultiplied ARGB, alpha 1/255: invisible
    for (int i = 0; i < width * height; i++)
        pixels[current][i] = px;
    struct wl_callback* cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    struct wp_presentation_feedback* fb = wp_presentation_feedback(presentation, surface);
    wp_presentation_feedback_add_listener(fb, &feedback_listener, (void*)(intptr_t)commits);
    tracked[commits % MAX_TRACKED].commit_ns = clock_ns((clockid_t)clock_id);
    tracked[commits % MAX_TRACKED].lag_ms = pending_lag_ms;
    commits++;
    wl_surface_attach(surface, buffers[current], 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, width, height);
    wl_surface_commit(surface);
}

static void start_drawing(void) {
    if (!configured) {
        configured = 1;
        draw();
    }
}

static void surface_enter(void* d, struct wl_surface* s, struct wl_output* o) {
    (void)d;
    (void)s;
    for (int i = 0; i < n_outputs; i++)
        if (outputs[i].wl == o)
            printf("# output %s %d %dx%d\n", outputs[i].name, outputs[i].refresh_mhz, outputs[i].width, outputs[i].height);
}
static void surface_leave(void* d, struct wl_surface* s, struct wl_output* o) { (void)d; (void)s; (void)o; }
static const struct wl_surface_listener wl_surface_listener = {.enter = surface_enter, .leave = surface_leave};

static void layer_configure(void* d, struct zwlr_layer_surface_v1* l, uint32_t serial, uint32_t w, uint32_t h) {
    (void)d;
    (void)w;
    (void)h;
    zwlr_layer_surface_v1_ack_configure(l, serial);
    start_drawing();
}
static void layer_closed(void* d, struct zwlr_layer_surface_v1* l) {
    (void)d;
    (void)l;
    done = 1;
}
static const struct zwlr_layer_surface_v1_listener layer_listener = {layer_configure, layer_closed};

static void xdg_configure(void* data, struct xdg_surface* xs, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xs, serial);
    start_drawing();
}
static const struct xdg_surface_listener xdg_listener = {xdg_configure};
static void top_configure(void* d, struct xdg_toplevel* t, int32_t w, int32_t h, struct wl_array* s) {
    (void)d; (void)t; (void)w; (void)h; (void)s;
}
static void top_close(void* d, struct xdg_toplevel* t) {
    (void)d;
    (void)t;
    done = 1;
}
static const struct xdg_toplevel_listener top_listener = {.configure = top_configure, .close = top_close};

static int usage(void) {
    fprintf(stderr, "usage: presentprobe [--seconds S] [--output NAME] [--toplevel] [--size N] [--real]\n");
    return 2;
}

int main(int argc, char** argv) {
    double      seconds = 30;
    const char* want_output = NULL;
    int         real = 0, size = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
            char* end;
            seconds = strtod(argv[++i], &end);
            if (*end || seconds < 0)
                return usage();
        } else if (!strcmp(argv[i], "--output") && i + 1 < argc)
            want_output = argv[++i];
        else if (!strcmp(argv[i], "--size") && i + 1 < argc) {
            size = atoi(argv[++i]);
            if (size < 1 || size > 256)
                return usage();
        } else if (!strcmp(argv[i], "--toplevel"))
            use_toplevel = 1;
        else if (!strcmp(argv[i], "--real"))
            real = 1;
        else
            return usage();
    }
    const char* display = getenv("WAYLAND_DISPLAY");
    if (!display || !*display) {
        fprintf(stderr, "presentprobe: WAYLAND_DISPLAY is not set\n");
        return 2;
    }
    // The owner's session is wayland-1: a dev tool never starts a client there unless the owner asks (--real).
    if (!real && (!strcmp(display, "wayland-1") || !strcmp(display, "/run/user/1000/wayland-1"))) {
        fprintf(stderr, "presentprobe: refusing the owner's Wayland socket (wayland-1) without --real\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal; // no SA_RESTART: poll() returns EINTR and the loop ends
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    struct wl_display* dpy = wl_display_connect(NULL);
    if (!dpy) {
        fprintf(stderr, "presentprobe: cannot connect to %s\n", display);
        return 1;
    }
    struct wl_registry* reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);
    wl_display_roundtrip(dpy); // the clock id, the outputs' names and modes
    if (!compositor || !shm || !presentation || (!layer_shell && !wm)) {
        fprintf(stderr, "presentprobe: missing global:%s%s%s%s\n", compositor ? "" : " wl_compositor", shm ? "" : " wl_shm",
                presentation ? "" : " wp_presentation", (layer_shell || wm) ? "" : " zwlr_layer_shell_v1/xdg_wm_base");
        return 1;
    }
    if (!layer_shell)
        use_toplevel = 1;
    if (use_toplevel && !wm) {
        fprintf(stderr, "presentprobe: --toplevel needs xdg_wm_base\n");
        return 1;
    }
    struct wl_output* target = NULL;
    if (want_output) {
        for (int i = 0; i < n_outputs; i++)
            if (!strcmp(outputs[i].name, want_output))
                target = outputs[i].wl;
        if (!target) {
            fprintf(stderr, "presentprobe: no output named %s (", want_output);
            for (int i = 0; i < n_outputs; i++)
                fprintf(stderr, "%s%s", i ? " " : "", outputs[i].name);
            fprintf(stderr, ")\n");
            return 1;
        }
    }
    width = height = size ? size : (use_toplevel ? 64 : 1);

    const int stride = width * 4, bytes = stride * height;
    int       fd = memfd_create("presentprobe", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, 2 * bytes) < 0) {
        perror("presentprobe: shm");
        return 1;
    }
    void* map = mmap(NULL, 2 * bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        perror("presentprobe: mmap");
        return 1;
    }
    struct wl_shm_pool* pool = wl_shm_create_pool(shm, fd, 2 * bytes);
    for (int i = 0; i < 2; i++) {
        pixels[i] = (uint32_t*)((char*)map + i * bytes);
        buffers[i] = wl_shm_pool_create_buffer(pool, i * bytes, width, height, stride,
                                               use_toplevel ? WL_SHM_FORMAT_XRGB8888 : WL_SHM_FORMAT_ARGB8888);
    }
    wl_shm_pool_destroy(pool);
    close(fd);

    printf("# presentprobe 1\n# clock %u%s\n", clock_id, have_clock ? "" : " (assumed: no clock_id event)");
    printf("# offset_ns %lld\n", (long long)realtime_offset());
    printf("# surface %s %dx%d\n", use_toplevel ? "toplevel" : "layer", width, height);

    surface = wl_compositor_create_surface(compositor);
    wl_surface_add_listener(surface, &wl_surface_listener, NULL);
    if (use_toplevel) {
        struct xdg_surface* xs = xdg_wm_base_get_xdg_surface(wm, surface);
        xdg_surface_add_listener(xs, &xdg_listener, NULL);
        struct xdg_toplevel* top = xdg_surface_get_toplevel(xs);
        xdg_toplevel_add_listener(top, &top_listener, NULL);
        xdg_toplevel_set_title(top, "presentprobe");
        xdg_toplevel_set_app_id(top, "gf-presentprobe");
    } else {
        struct wl_region* none = wl_compositor_create_region(compositor);
        wl_surface_set_input_region(surface, none); // clicks go through
        wl_region_destroy(none);
        struct zwlr_layer_surface_v1* ls = zwlr_layer_shell_v1_get_layer_surface(layer_shell, surface, target,
                                                                                 ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "grassfield-presentprobe");
        zwlr_layer_surface_v1_add_listener(ls, &layer_listener, NULL);
        zwlr_layer_surface_v1_set_size(ls, (uint32_t)width, (uint32_t)height);
        zwlr_layer_surface_v1_set_anchor(ls, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
        zwlr_layer_surface_v1_set_exclusive_zone(ls, -1);
    }
    wl_surface_commit(surface);

    const int64_t start = clock_ns(CLOCK_MONOTONIC), limit = (int64_t)(seconds * 1e9);
    const int     fd_dpy = wl_display_get_fd(dpy);
    while (!done) {
        while (wl_display_prepare_read(dpy) != 0)
            wl_display_dispatch_pending(dpy);
        if (wl_display_flush(dpy) < 0 && errno != EAGAIN) {
            wl_display_cancel_read(dpy);
            break;
        }
        struct pollfd pfd = {fd_dpy, POLLIN, 0};
        int           r = poll(&pfd, 1, 100);
        if (r > 0) {
            if (wl_display_read_events(dpy) < 0)
                break;
        } else
            wl_display_cancel_read(dpy);
        if (wl_display_dispatch_pending(dpy) < 0)
            break;
        if (limit > 0 && clock_ns(CLOCK_MONOTONIC) - start >= limit)
            done = 1;
    }
    // The feedback of the last commits arrives one or two frames later: collect it for up to 100 ms.
    const int64_t drain = clock_ns(CLOCK_MONOTONIC) + 100000000;
    while (presented + discarded < commits && clock_ns(CLOCK_MONOTONIC) < drain) {
        wl_display_flush(dpy);
        struct pollfd pfd = {fd_dpy, POLLIN, 0};
        if (poll(&pfd, 1, 20) > 0 && wl_display_dispatch(dpy) < 0)
            break;
        wl_display_dispatch_pending(dpy);
    }
    printf("# offset_end_ns %lld\n", (long long)realtime_offset());
    printf("# end presented %ld discarded %ld commits %ld seconds %.3f\n", presented, discarded, commits,
           (clock_ns(CLOCK_MONOTONIC) - start) / 1e9);
    wl_display_disconnect(dpy);
    return 0;
}
