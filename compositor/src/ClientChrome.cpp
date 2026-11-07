#include "ClientChrome.hpp"

#include "Ipc.hpp"
#include "Plugin.hpp"
#include "Tiling.hpp"
#include "core/ClientChrome.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/protocols/ServerDecorationKDE.hpp>
#include <hyprland/src/protocols/XDGDecoration.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>

#include "Titlebar.hpp"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

// P9: Hyprland 0.56.2 keeps both decoration protocols' objects in private containers (CXDGDecorationProtocol::m_decorations,
// keyed by the xdg_toplevel resource; CServerDecorationKDEProtocol::m_decos) and offers no per-window decoration signal; what
// each client asked for is public in those objects (CXDGDecoration::mostRecentlyRequested, CServerDecorationKDE::
// m_mostRecentlyRequested and m_surf). An explicit instantiation may name a private member ([temp.spec.general]/6), so the two
// containers are reached through member pointers whose types the compiler checks against the installed headers; they are
// only read, on the compositor thread, never kept.
namespace {
    template <typename Tag, typename Tag::type Member>
    struct SExpose {
        friend typename Tag::type memberOf(Tag /*tag*/) {
            return Member;
        }
    };
    struct SXdgDecorations {
        using type = std::unordered_map<wl_resource*, UP<CXDGDecoration>> CXDGDecorationProtocol::*;
        friend type memberOf(SXdgDecorations /*tag*/);
    };
    struct SKdeDecorations {
        using type = std::vector<UP<CServerDecorationKDE>> CServerDecorationKDEProtocol::*;
        friend type memberOf(SKdeDecorations /*tag*/);
    };
    template struct SExpose<SXdgDecorations, &CXDGDecorationProtocol::m_decorations>;
    template struct SExpose<SKdeDecorations, &CServerDecorationKDEProtocol::m_decos>;
} // namespace

namespace gf::chrome {

    namespace {
        // The two listeners of one window's xdg toplevel. Destroying them disconnects them. `caps`: what the window was told
        // (P8); its close and the unload tell it Hyprland's own capabilities again.
        struct SWatch {
            PHLWINDOWREF             window;
            WP<CXDGToplevelResource> toplevel;
            CHyprSignalListener      stateChanged;
            CHyprSignalListener      requestMove;
            CHyprSignalListener      commit; // P9: the surface's commits (a client changes its decoration request with one)
            CapabilityTell           caps;
            bool                     suppressAdded    = false; // D78: the plugin set SUPPRESS_MAXIMIZE on it (only that is cleared)
            bool                     wasFullscreen    = false; // in Hyprland's full screen at the last window.fullscreen
            uint64_t                 leftFullscreenMs = 0;     // when it last left full screen (core maximizeEcho), 0: never
            // P9: the xdg_toplevel resource, found once (the key of Hyprland's xdg-decoration map; only compared, never read),
            // what the client negotiated last, and whether the plugin added the client-chrome tag (only that is removed).
            wl_resource*             toplevelResource = nullptr;
            std::optional<bool>      drawsOwn;
            bool                     tagAdded = false;
        };

        struct SState {
            std::vector<CHyprSignalListener> listeners; // window open / close
            std::vector<SWatch>              watches;
            std::optional<ZoomedPress>       press; // P4: the last press on a zoomed client-chrome window
            bool                             ready = false;
        };

        // Constructed on first use inside a guarded call (R13).
        SState& st() {
            static SState s;
            return s;
        }

        uint64_t addressOf(const PHLWINDOW& w) {
            return reinterpret_cast<uintptr_t>(w.get());
        }

        uint64_t nowMs() {
            return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
        }

        Fullscreen::eFullscreenMode modeOf(const PHLWINDOW& w) {
            const auto& fs = Fullscreen::controller();
            return fs ? fs->getFullscreenModes(w).internal : Fullscreen::FSMODE_NONE;
        }

        SP<CXDGToplevelResource> toplevelOf(const PHLWINDOW& w) {
            if (!w || w->m_isX11)
                return nullptr;
            const auto xdg = w->m_xdgSurface.lock();
            return xdg ? xdg->m_toplevel.lock() : nullptr;
        }

        SWatch* watchOf(const PHLWINDOW& w) {
            for (auto& e : st().watches) {
                if (e.window.lock() == w)
                    return &e;
            }
            return nullptr;
        }

        // ADR-0036 D78, ADR-0015 Q4 amended: while the plugin owns a client-chrome window's maximize requests (core
        // ownsMaximize: window-tiling advertised), Hyprland ignores them (SUPPRESS_MAXIMIZE, set here only when it was not set,
        // and cleared only if set here: a session rule's own suppression is never touched). Called at open, on every rule
        // change (the tag may come or go; a rule evaluation may rewrite the window's suppressed events), once the IPC is
        // registered (window-tiling known) and at unload (cleared: C2, Hyprland's own maximize again).
        void syncMaximize(SWatch& e, bool own) {
            const auto w = e.window.lock();
            if (!w)
                return;
            const bool suppressed = (w->m_suppressedEvents & Desktop::View::SUPPRESS_MAXIMIZE) != 0;
            if (own && !suppressed) {
                w->m_suppressedEvents |= Desktop::View::SUPPRESS_MAXIMIZE;
                e.suppressAdded = true;
                logRequest(Log::DEBUG, "client chrome: {:x} maximize requests are the plugin's zoom (D78)", addressOf(w));
            } else if (!own && e.suppressAdded) {
                if (suppressed)
                    w->m_suppressedEvents &= ~static_cast<uint64_t>(Desktop::View::SUPPRESS_MAXIMIZE);
                e.suppressAdded = false;
                logRequest(Log::DEBUG, "client chrome: {:x} maximize requests are Hyprland's again", addressOf(w));
            }
        }

        bool ownsMaximizeOf(const PHLWINDOW& w) {
            return ownsMaximize(st().ready, ipc::tilingAvailable(), isClientChrome(w));
        }

        // D78: the app's own maximize request (its green light, its toolbar double-click; Qt sends unset_maximized, which Hyprland
        // toggles whatever its value) is Grassfield's Zoom, as the plugin's own light: Fill and back (gf::tiler::zoom). Only
        // while the plugin suppressed it for Hyprland; in full screen nothing (its lights are away; Hyprland's would have left
        // full screen for the maximized mode); the echo a client may send right after leaving full screen is swallowed, as
        // Hyprland does (core maximizeEcho).
        // P9: a window the plugin tagged for its negotiation is usually suppressed by the session rule already (gf-no-maximize-event:
        // every app id but the per-app list), so the plugin did not set the flag itself; its zoom light is still the window's only
        // one: the request is the plugin's whenever the plugin owns this window's maximize and Hyprland ignores it.
        void onMaximizeRequest(const PHLWINDOW& w) {
            SWatch* e = watchOf(w);
            if (!e || !ownsMaximizeOf(w) || (w->m_suppressedEvents & Desktop::View::SUPPRESS_MAXIMIZE) == 0)
                return; // Hyprland handled it as before
            if (maximizeEcho(e->leftFullscreenMs, nowMs())) {
                e->leftFullscreenMs = 0;
                logRequest(Log::DEBUG, "client chrome: {:x} maximize request right after full screen: its echo, ignored", addressOf(w));
                return;
            }
            if (modeOf(w) == Fullscreen::FSMODE_FULLSCREEN) {
                logRequest(Log::DEBUG, "client chrome: {:x} maximize request in full screen: ignored", addressOf(w));
                return;
            }
            logRequest(Log::DEBUG, "client chrome: {:x} asks to zoom: {}", addressOf(w), tiling::nameOf(gf::tiler::zoom(w, true)));
        }

        // The full-screen state of a watched window, for the echo above.
        void onFullscreen(const PHLWINDOW& w) {
            SWatch* e = watchOf(w);
            if (!e)
                return;
            const bool now = modeOf(w) == Fullscreen::FSMODE_FULLSCREEN;
            if (e->wasFullscreen && !now)
                e->leftFullscreenMs = nowMs();
            e->wasFullscreen = now;
        }

        // P5: the app asked to be minimized (xdg_toplevel.set_minimized; Hyprland does nothing with it on its own, spike
        // step 5): the minimize path of the titlebar's own light. D78: its maximize request is the plugin's zoom.
        void onStateChanged(const PHLWINDOWREF& ref, const WP<CXDGToplevelResource>& weakTop) {
            const auto w   = ref.lock();
            const auto top = weakTop.lock();
            if (!w || !top || !w->m_isMapped || !isClientChrome(w))
                return;
            if (top->m_state.requestsMaximize.has_value())
                onMaximizeRequest(w);
            if (!top->m_state.requestsMinimize.value_or(false))
                return;
            if (w->m_workspace && w->m_workspace->m_isSpecialWorkspace)
                return; // already parked (special:minimized or a scratchpad): nothing to do
            logRequest(Log::DEBUG, "client chrome: {:x} asks to be minimized", addressOf(w));
            ipc::postMinimizeRequest(addressOf(w));
        }

        // P4: the app started Hyprland's interactive move from its toolbar. On a zoomed window (the press recorded before
        // Hyprland handled it) the window leaves the zoom at its floating size, under the pointer at the same place in its
        // toolbar row (macOS), and the move restarts from there. Hyprland's own handler may already have left the zoom
        // (it centres the window on the pointer, spike step 3): the move it started is ended and begun again from the
        // place computed here, so the pointer keeps its grip on the row.
        void onRequestMove(const PHLWINDOWREF& ref) {
            auto&      s = st();
            const auto w = ref.lock();
            if (!w || !w->m_isMapped || !isClientChrome(w) || !g_pInputManager || !g_layoutManager)
                return;
            if (!s.press || !moveAnswersPress(s.press, addressOf(w), g_pInputManager->hasHeldButtons(), nowMs()))
                return;
            const ZoomedPress press = *s.press;
            s.press.reset();
            const auto target = w->layoutTarget();
            if (!target)
                return;
            if (modeOf(w) == Fullscreen::FSMODE_MAXIMIZED) {
                if (const auto& fs = Fullscreen::controller())
                    fs->setFullscreenMode(w, Fullscreen::FSMODE_NONE, Fullscreen::FSMODE_NONE, false);
            }
            if (modeOf(w) != Fullscreen::FSMODE_NONE)
                return; // still not floating normally: leave Hyprland's move alone
            const CBox     restored = target->position();
            const Vector2D pointer  = g_pInputManager->getMouseCoordsInternal();
            const auto     box      = unzoomedBox(press, restored.w, restored.h, pointer.x, pointer.y);
            if (const auto& drag = g_layoutManager->dragController(); drag && drag->mode() != MBIND_INVALID)
                g_layoutManager->endDragTarget();
            g_layoutManager->setTargetGeom(CBox{box.x, box.y, box.w, box.h}, target);
            g_layoutManager->beginDragTarget(target, MBIND_MOVE);
            logRequest(Log::DEBUG, "client chrome: {:x} dragged out of its zoom: {:.0f}x{:.0f} at {:.0f},{:.0f}", addressOf(w), box.w, box.h, box.x, box.y);
        }

        // P8: the xdg_toplevel wl_resource of `top`: Hyprland keeps it private, so it is found among its client's resources
        // (libwayland's own list) by its interface and CXDGToplevelResource::fromResource. Only a capabilityCandidate is
        // handed to fromResource (v5 or later, user data still set): nullptr for a toplevel older than v5 or being destroyed.
        // P9 (`anyVersion`): the key of Hyprland's xdg-decoration map, a toplevel of any version (core toplevelCandidate).
        wl_resource* toplevelResource(const SP<CXDGToplevelResource>& top, bool anyVersion = false) {
            const auto xdg     = top ? top->m_owner.lock() : nullptr;
            const auto surface = xdg ? xdg->m_surface.lock() : nullptr;
            wl_client* client  = surface ? surface->client() : nullptr;
            if (!client)
                return nullptr;
            struct SFind {
                CXDGToplevelResource* wanted     = nullptr;
                bool                  anyVersion = false;
                wl_resource*          found      = nullptr;
            } find{.wanted = top.get(), .anyVersion = anyVersion};
            wl_client_for_each_resource(
                client,
                [](wl_resource* resource, void* data) -> wl_iterator_result {
                    auto*       f        = static_cast<SFind*>(data);
                    const char* cls      = resource ? wl_resource_get_class(resource) : nullptr;
                    const bool  userData = resource && wl_resource_get_user_data(resource) != nullptr;
                    if (!cls || !(f->anyVersion ? toplevelCandidate(cls, userData) : capabilityCandidate(cls, wl_resource_get_version(resource), userData)))
                        return WL_ITERATOR_CONTINUE;
                    if (CXDGToplevelResource::fromResource(resource).get() != f->wanted)
                        return WL_ITERATOR_CONTINUE;
                    f->found = resource;
                    return WL_ITERATOR_STOP;
                },
                &find);
            return find.found;
        }

        // P8: tells the window its capabilities again (core wmCapabilities) when they change, then a configure, as
        // xdg-shell asks ("when the capabilities change, compositors must send this event again and then send an
        // xdg_surface.configure event"). Nothing for a client older than xdg_toplevel v5 (it never had the event); a
        // window whose resource is not found is remembered as unreachable and never walked again.
        // The configure is Hyprland's own full one (setSize with the size it already asked for: an xdg_toplevel.configure
        // with its current states, then the xdg_surface.configure; read from the 0.56.2 binary, no early return): a bare
        // xdg_surface.configure made GTK4 apply an empty state set (no longer activated or tiled: it drew its shadow
        // margins and looked inactive). `configure` false (a window that is being unmapped): the event only; its next map
        // starts a new configure sequence, which carries it.
        void tellCapabilities(SWatch& e, bool clientChrome, bool bridged, bool configure = true) {
            const bool withMinimize = clientChrome && bridged;
            if (!needsTell(e.caps, withMinimize))
                return;
            const auto   top = e.toplevel.lock();
            wl_resource* res = toplevelResource(top);
            if (!res || !top->m_owner.lock()) {
                e.caps.unreachable = true;
                logRequest(Log::DEBUG, "client chrome: {:x} cannot be told its capabilities (xdg_toplevel older than v5, or going)", addressOf(e.window.lock()));
                return;
            }
            const auto caps = wmCapabilities(clientChrome, bridged);
            wl_array   array;
            wl_array_init(&array);
            for (const uint32_t cap : caps) {
                auto* slot = static_cast<uint32_t*>(wl_array_add(&array, sizeof(uint32_t)));
                if (!slot) {
                    wl_array_release(&array);
                    return;
                }
                *slot = cap;
            }
            wl_resource_post_event(res, 3 /* xdg_toplevel.wm_capabilities */, &array);
            wl_array_release(&array);
            if (configure)
                top->setSize(top->m_pendingApply.size);
            e.caps.minimizeTold = withMinimize;
            logRequest(Log::DEBUG, "client chrome: {:x} told {} capabilities{}", addressOf(e.window.lock()), caps.size(), withMinimize ? " (minimize)" : "");
        }

        // The capabilities of a watched window after an open or a rule change (the tag may come or go), and who owns its
        // maximize requests (D78).
        void syncCapabilities(const PHLWINDOW& w) {
            for (auto& e : st().watches) {
                if (e.window.lock() == w) {
                    tellCapabilities(e, isClientChrome(w), st().ready);
                    syncMaximize(e, ownsMaximizeOf(w));
                }
            }
        }

        // P9: what the window's client negotiated, read from Hyprland's two decoration protocols (their containers through the
        // member pointers at the top of this file). xdg-decoration: the entry keyed by the window's xdg_toplevel resource (the
        // key is compared, never dereferenced). KDE: the object whose surface is the window's.
        DecorationRequest requestOf(const SWatch& e, const PHLWINDOW& w) {
            DecorationRequest r;
            if (PROTO::xdgDecoration && e.toplevelResource) {
                const auto& all = (*PROTO::xdgDecoration).*memberOf(SXdgDecorations{});
                if (const auto it = all.find(e.toplevelResource); it != all.end() && it->second) {
                    r.xdgObject    = true;
                    r.xdgRequested = it->second->mostRecentlyRequested;
                }
            }
            const auto surface = w->resource();
            if (PROTO::serverDecorationKDE && surface) {
                for (const auto& deco : (*PROTO::serverDecorationKDE).*memberOf(SKdeDecorations{})) {
                    if (deco && deco->m_surf == surface) {
                        r.kdeObject    = true;
                        r.kdeRequested = deco->m_mostRecentlyRequested;
                        break;
                    }
                }
            }
            return r;
        }

        // P9: a window whose client draws its own title bar (core drawsOwnTitlebar) carries the client-chrome tag, so that the
        // plugin's titlebar steps aside (P1) and the shell's Overview and Stages leave no band above it, whatever its app id; the
        // per-app session rule stays as the fallback. The tag the plugin adds is static (a rule evaluation keeps it) and is the
        // only one it ever removes: when the client asks for server-side decorations again, when the window closes and at the
        // unload. X11 windows are left to their own hints (titlebarAllowed reads _MOTIF_WM_HINTS through Hyprland).
        // `bridged`: the minimize bridge runs (true from watch(), which start() calls before it is ready).
        void syncDecoration(SWatch& e, bool bridged) {
            const auto w   = e.window.lock();
            const auto top = e.toplevel.lock();
            if (!w || !top || !w->m_isMapped || w->m_isX11 || !w->m_ruleApplicator)
                return;
            const auto request = requestOf(e, w);
            const bool drawsOwn = drawsOwnTitlebar(request);
            auto&      tags     = w->m_ruleApplicator->m_tagKeeper;
            const bool tagged   = hasClientChromeTag(tags.getTags());
            e.tagAdded          = e.tagAdded && tagged; // a tag someone else removed is not the plugin's any more
            const auto change   = tagChange(drawsOwn, tagged, e.tagAdded);
            const bool changed  = !e.drawsOwn || *e.drawsOwn != drawsOwn;
            e.drawsOwn          = drawsOwn;
            if (changed)
                logRequest(Log::DEBUG, "client chrome: {:x} negotiated xdg {} {} kde {} {}: {}", addressOf(w), request.xdgObject ? "object" : "none",
                           request.xdgRequested, request.kdeObject ? "object" : "none", request.kdeRequested,
                           drawsOwn ? "draws its own title bar" : "server-side title bar");
            if (change == TagChange::None)
                return;
            if (change == TagChange::Add) {
                tags.applyTag("+" + std::string{kTag}, false);
                e.tagAdded = hasClientChromeTag(tags.getTags());
            } else {
                tags.applyTag("-" + std::string{kTag}, false);
                e.tagAdded = false;
            }
            CGrassfieldTitlebar::refreshWindow(w); // P1: the bar steps aside, or comes back
            tellCapabilities(e, isClientChrome(w), bridged);
            syncMaximize(e, ownsMaximizeOf(w));
        }

        SWatch* watchOfRef(const PHLWINDOWREF& ref) {
            const auto w = ref.lock();
            return w ? watchOf(w) : nullptr;
        }

        void watch(const PHLWINDOW& w) {
            auto& s = st();
            std::erase_if(s.watches, [](const SWatch& e) { return e.window.expired() || e.toplevel.expired(); });
            const auto top = toplevelOf(w);
            if (!top || std::ranges::any_of(s.watches, [&w](const SWatch& e) { return e.window.lock() == w; }))
                return;
            const bool  fullscreen = modeOf(w) == Fullscreen::FSMODE_FULLSCREEN;
            SWatch      e;
            PHLWINDOWREF ref = w;
            WP<CXDGToplevelResource> weakTop = top;
            e.window       = ref;
            e.toplevel     = weakTop;
            e.stateChanged = top->m_events.stateChanged.listen([ref, weakTop] { guarded("client chrome stateChanged", [&] { onStateChanged(ref, weakTop); }); });
            e.requestMove  = top->m_events.requestMove.listen([ref](const SXDGToplevelMoveRequest& /*request*/) { guarded("client chrome requestMove", [&] { onRequestMove(ref); }); });
            e.wasFullscreen = fullscreen;
            // P9: the decoration request is read again at each commit (a client that switches between its own title bar and the
            // system's, Firefox's "Title Bar" or Chromium's "Use system title bar and borders", commits after its request).
            e.toplevelResource = toplevelResource(top, true);
            if (const auto surface = w->resource())
                e.commit = surface->m_events.commit.listen([ref] {
                    guarded("client chrome commit", [&] {
                        if (auto* mine = watchOfRef(ref))
                            syncDecoration(*mine, st().ready);
                    });
                });
            s.watches.push_back(std::move(e));
            syncDecoration(s.watches.back(), true);
            tellCapabilities(s.watches.back(), isClientChrome(w), true);
            syncMaximize(s.watches.back(), ownsMaximizeOf(w));
        }

        // window.close comes with the unmap. A toolkit that hides a window may keep its xdg_toplevel and map it again
        // later: one told minimize is told Hyprland's own capabilities first (the event only, see tellCapabilities), so
        // that an unload while it is hidden cannot leave it a minimize button nothing answers. Its next map watches it
        // again and tells it minimize again while the plugin runs. A toplevel already destroyed is not found: nothing sent
        // (Evince, Nautilus, Chromium and Obsidian destroy theirs before window.close: nested 2026-10-25).
        // P9: the client-chrome tag the plugin added goes (a window closing, the unload); a session rule's stays.
        void dropTag(SWatch& e) {
            const auto w = e.window.lock();
            if (!std::exchange(e.tagAdded, false) || !w || !w->m_ruleApplicator)
                return;
            w->m_ruleApplicator->m_tagKeeper.applyTag("-" + std::string{kTag}, false);
        }

        void forget(const PHLWINDOW& w) {
            for (auto& e : st().watches) {
                if (e.caps.minimizeTold && e.window.lock() == w)
                    tellCapabilities(e, false, false, false);
                if (e.window.lock() == w) {
                    syncMaximize(e, false); // a toolkit that maps the window again starts from Hyprland's own state
                    dropTag(e);             // and from its own negotiation (P9)
                }
            }
            std::erase_if(st().watches, [&w](const SWatch& e) {
                const auto mine = e.window.lock();
                return !mine || mine == w || e.toplevel.expired();
            });
        }

        // The topmost mapped window on a visible workspace whose surface box contains `pos` (the stacking order Hyprland
        // keeps); null when the pointer is on no window.
        PHLWINDOW windowUnder(const Vector2D& pos) {
            if (!Desktop::windowState())
                return nullptr;
            const auto& windows = Desktop::windowState()->windows();
            for (auto it = windows.rbegin(); it != windows.rend(); ++it) {
                const auto& w = *it;
                if (!w || !w->m_isMapped || w->isHidden() || !w->m_workspace || !w->m_workspace->isVisible())
                    continue;
                if (w->getWindowMainSurfaceBox().containsPoint(pos))
                    return w;
            }
            return nullptr;
        }
    } // namespace

    bool isClientChrome(const PHLWINDOW& w) {
        return w && w->m_ruleApplicator && hasClientChromeTag(w->m_ruleApplicator->m_tagKeeper.getTags());
    }

    double bandOf(const PHLWINDOW& w) {
        return band(isClientChrome(w), gf::tiler::inSplit(w)); // a Split View member's bar is away (TL33, step 6e)
    }

    bool start() {
        auto& s = st();
        if (s.ready)
            return true;
        auto& bus = Event::bus();
        if (!bus)
            return false;
        auto& ev = bus->m_events.window;
        s.listeners.push_back(ev.open.listen([](const PHLWINDOW& w) { guarded("client chrome window.open", [&] { watch(w); }); }));
        s.listeners.push_back(ev.close.listen([](const PHLWINDOW& w) { guarded("client chrome window.close", [&] { forget(w); }); }));
        // The tag is a dynamic effect of the session rules: a rule change can make a window client chrome or not (P8).
        s.listeners.push_back(ev.updateRules.listen([](const PHLWINDOW& w) {
            guarded("client chrome window.updateRules", [&] {
                if (auto* e = watchOf(w))
                    syncDecoration(*e, st().ready); // P9: a rule change may have taken the session rule's tag away
                syncCapabilities(w);
            });
        }));
        s.listeners.push_back(ev.fullscreen.listen([](const PHLWINDOW& w) { guarded("client chrome window.fullscreen", [&] { onFullscreen(w); }); }));
        if (Desktop::windowState()) {
            for (const auto& w : Desktop::windowState()->windows()) {
                if (w && w->m_isMapped)
                    watch(w);
            }
        }
        s.ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        // P8: every window told minimize is told Hyprland's own capabilities again before the bridge goes (C2: without the
        // plugin a client sees what Hyprland offers, and its minimize button greys again).
        for (auto& e : s.watches) {
            if (e.caps.minimizeTold)
                guarded("client chrome capabilities on stop", [&] { tellCapabilities(e, false, false); });
            guarded("client chrome maximize on stop", [&] { syncMaximize(e, false); }); // D78: Hyprland's own maximize again (C2)
            guarded("client chrome tag on stop", [&] { dropTag(e); });                 // P9: only a session rule's tag stays (C2)
        }
        s.watches.clear();
        s.listeners.clear();
        s.press.reset();
        s.ready = false;
    }

    bool ready() {
        return st().ready;
    }

    void syncMaximizeAll() {
        for (auto& e : st().watches) {
            if (const auto w = e.window.lock())
                syncMaximize(e, ownsMaximizeOf(w));
        }
    }

    void beforePointerButton(bool pressed) {
        auto& s = st();
        if (!s.ready)
            return;
        if (!pressed) {
            s.press.reset();
            return;
        }
        s.press.reset();
        if (!g_pInputManager)
            return;
        const Vector2D pos = g_pInputManager->getMouseCoordsInternal();
        const auto     w   = windowUnder(pos);
        if (!w || !isClientChrome(w) || modeOf(w) != Fullscreen::FSMODE_MAXIMIZED)
            return;
        const CBox zoomed = w->geometricBox(Desktop::View::IGeometric::GEOMETRIC_GOAL);
        s.press           = ZoomedPress{.window = addressOf(w), .zoomed = titlebar::Rect{zoomed.x, zoomed.y, zoomed.w, zoomed.h}, .x = pos.x, .y = pos.y, .timeMs = nowMs()};
    }

} // namespace gf::chrome
