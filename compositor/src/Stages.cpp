#include "Stages.hpp"

#include "ClientChrome.hpp"
#include "DeferredFocus.hpp"
#include "Ipc.hpp"
#include "Overview.hpp"
#include "Plugin.hpp"
#include "Surfaces.hpp"
#include "WindowTransform.hpp"
#include "core/EventThrottle.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/rule/Rule.hpp>
#include <hyprland/src/desktop/rule/windowRule/WindowRuleApplicator.hpp>
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/XWaylandManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/InputMethodV2.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/protocols/core/Seat.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/transformer/Transformer.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace st = gf::stages;
namespace tf = gf::transform;

namespace {
    // Layer namespace of the shell's strip surface (Top or Overlay layer, input over the tiles). Thumbnails are drawn only
    // where it covers them: a click on a thumbnail must reach the shell, never a window hidden under the drawing.
    constexpr std::string_view STRIP_NAMESPACE = "grassfield-stages";

    // The plugin's own input block reason: a bit Hyprland 0.56.2 does not use (INPUT_BLOCK_GROUP_INACTIVE 1 << 0,
    // MONOCLE_INACTIVE 1 << 1, BELOW_FULLSCREEN 1 << 2). CWindow::acceptsInput() is false while any reason is set:
    // CViewHitTester::windowAt then skips the window for pointer focus, clicks, titlebar presses and hovers.
    constexpr uint8_t INPUT_BLOCK_STAGES_BIT = 1U << 6;
    const auto        INPUT_BLOCK_STAGES     = static_cast<Desktop::View::eWindowInputBlockReason>(INPUT_BLOCK_STAGES_BIT);

    // Ends animations whose frames stopped (no monitor rendered): checked this long after the expected end.
    constexpr auto WATCHDOG_SLACK = std::chrono::milliseconds(150);

    // An active window closer than this to the strip's tiles counts as overlapping it (the shell then hides the strip).
    constexpr double OVERLAP_MARGIN = 8;

    class CStageTransformer final : public Render::IWindowTransformer {
      public:
        SP<Render::IFramebuffer> transform(SP<Render::IFramebuffer> in) override;
    };

    // A window Stages draws or has drawn: its transformer, input block and animation.
    struct SWin {
        PHLWINDOWREF           window;
        uint64_t               address     = 0;
        CStageTransformer*     transformer = nullptr; // owned by window->m_transformers; compared, never freed here
        bool                   blocked     = false;   // INPUT_BLOCK_STAGES set by this plugin
        bool                   inStrip     = false;   // its target is a strip position (tile or off screen)
        std::optional<st::Box> from;                  // nullopt: its live surface box
        std::optional<st::Box> to;                    // nullopt: its live surface box (shown normally)
        st::Box                rect;                  // where its surface box is drawn at the last tick
        st::Box                damaged;               // last damaged visual box (layout, with every decoration)
        std::optional<st::Box> thumb;                 // its place in its tile when the strip is shown (events)
    };

    struct SStrip {
        std::string          monitor;
        PHLMONITORREF        mon;
        std::vector<st::Box> tiles;
        bool                 hidden  = false;
        bool                 overlap = false;
    };

    struct SSpace {
        st::WorkspaceId       id = 0;
        st::CWorkspaceStages  model;
        uint64_t              lastFocused = 0; // the last window Hyprland focused on this workspace (any window; compared only)
    };

    struct SStagesState {
        bool                             ready   = false;
        bool                             enabled = false; // the feature flag (config stagesEnabled)
        bool                             on      = false; // the shell turned Stages on (op on) and has not turned it off
        st::StageId                      nextId  = 1;
        std::vector<SSpace>              spaces;
        std::vector<SWin>                wins;
        std::vector<SStrip>              strips;
        double                           durationMs = 0; // of swaps (from op on)
        st::Curve                        curve;
        bool                             animating = false;
        uint64_t                         lockStayLogged = 0; // the strip window logged as staying active under the lock
        uint64_t                         generation     = 0;  // of the latest `stages` notice
        std::string                      stateJson;           // the state of that notice (`hyprctl grassfield-stages`)
        bool                             keysOnLayer = false; // the active window was cleared while an Exclusive layer held the keyboard (unload: restoreFocusSurface)
        Time::steady_tp                  start;
        double                           animMs = 0;
        std::vector<CHyprSignalListener> listeners;
        SP<CEventLoopTimer>              watchdog;  // shared: CEventLoopManager holds a strong reference too
        std::optional<uint64_t>          syncLater; // doLater sequence of a pending sync (its callback is code of this library)
        std::optional<st::WorkspaceId>   refocusSpace; // after a close: the active stage of this workspace takes the keyboard
        PHLWINDOWREF                     focusLater;   // the window the latest activate / merge / move request made key
        PHLWINDOWREF                     pendingFront; // a focus Hyprland refused (Exclusive layer, lock): made once that ends
        std::optional<st::WorkspaceId>   pendingSpace; // its Desktop: that Desktop's front window takes it if it went away
        PHLLSREF                         pendingHolder; // the layer surface that held the keyboard when it was deferred
        gf::deferredFocus::CLater        pendingAttempt; // a deferred-focus attempt from the event loop (code of this library)
        st::PressRecord                  press;        // the latest press (pointer button, touch, tablet): which CLICK focus is it
        gf::deferredFocus::CLater        pressEnd;     // ends a press record from the event loop (code of this library)
        std::optional<uint64_t>          pointerLater; // doLater sequence of a pending pointer refresh (code of this library)
        std::optional<uint64_t>          keyFocusLater; // doLater sequence of a pending keyboard focus check (likewise)
        bool                             movingKeyFocus = false; // keepKeyboardFocus is moving the keyboard (its own focus event is not a cause)
        WP<IKeyboard>                    keyDevice;              // Hyprland's keyboard device at the previous key
        bool                             hadKeyDevice = false;
        SP<CEventLoopTimer>              announceTimer;          // waits for the re-created wl_keyboard (removed in stop())
        WP<IKeyboard>                    announceDevice;         // the device that replaced the session's only keyboard
        WP<IKeyboard>                    announcedDevice;        // the device the timer already announced
        std::vector<WP<CWLKeyboardResource>> announceKnown;      // the focused client's wl_keyboards when it appeared
        int                              announceTries = 0;
        bool                             pointerParked  = false; // pointer focus cleared off a blocked window (held button)
        bool                             warnedNoBuffer = false;
        // A window a titlebar drag dropped on the strip (dropOnStrip): drawn from where it was dropped, then put back at its
        // place from before the drag once it is drawn in the strip (sync), invisibly (the strip draws it in a tile).
        struct SDrop {
            PHLWINDOWREF           window;
            uint64_t               address = 0;
            st::Box                from;
            std::optional<st::Box> restore;
        };
        std::optional<SDrop> drop;
    };

    // Constructed on first use inside a guarded call (R13). Emptied by stop() before dlclose.
    SStagesState& S() {
        static SStagesState s;
        return s;
    }

    uint64_t addressOf(const PHLWINDOW& w) {
        return reinterpret_cast<uintptr_t>(w.get());
    }

    // Hyprland's refusal conditions, the keyboard holder, where a press goes and Hyprland's focus reasons: the deferred
    // focus shared with the overview focus (DeferredFocus.*, core/DeferredFocus.*).
    using gf::deferredFocus::causeOf;
    using gf::deferredFocus::exclusiveLayerMapped;
    using gf::deferredFocus::keyboardHolder;
    using gf::deferredFocus::sessionLocked;
    using gf::deferredFocus::windowFocusRefused;

    // The address is compared, never dereferenced.
    PHLWINDOW windowByAddress(uint64_t address) {
        if (!Desktop::windowState())
            return nullptr;
        for (const auto& w : Desktop::windowState()->windows()) {
            if (w && addressOf(w) == address)
                return w;
        }
        return nullptr;
    }

    // Enabled monitors only, here and in shownOn(): Hyprland keeps a disconnected monitor (m_enabled false) in its list for a
    // while, and its strip must go with it (onMonitorsChanged).
    PHLMONITOR monitorByName(std::string_view name) {
        if (!State::monitorState())
            return nullptr;
        for (const auto& m : State::monitorState()->monitors()) {
            if (m && m->m_enabled && m->m_name == name)
                return m;
        }
        return nullptr;
    }

    st::Box monitorBox(const PHLMONITOR& mon) {
        return st::Box{mon->m_position.x, mon->m_position.y, mon->m_size.x, mon->m_size.y};
    }

    // The monitor that shows this workspace as its active workspace, if any.
    PHLMONITOR shownOn(st::WorkspaceId id) {
        if (!State::monitorState())
            return nullptr;
        for (const auto& m : State::monitorState()->monitors()) {
            if (m && m->m_enabled && m->m_activeWorkspace && m->m_activeWorkspace->m_id == id)
                return m;
        }
        return nullptr;
    }

    bool showsFullscreen(const PHLWORKSPACE& ws) {
        const auto& fullscreen = Fullscreen::controller();
        return ws && fullscreen && fullscreen->getFullscreenModes(ws).internal == Fullscreen::FSMODE_FULLSCREEN;
    }

    // Windows Stages manages: mapped, visible, floating (ADR-0002 floating-first; tiled windows are left to the layout),
    // not pinned (drawn on every workspace), on a regular workspace (minimized windows live on special:minimized), not an
    // X11 override-redirect window. A full-screen window keeps its stage (its workspace's strip is then hidden).
    bool manageable(const PHLWINDOW& w) {
        if (!w || !w->m_isMapped || w->isHidden() || !w->m_isFloating || w->m_pinned || !w->m_workspace || w->m_workspace->m_isSpecialWorkspace)
            return false;
        return !(w->m_isX11 && w->isX11OverrideRedirect());
    }

    bool fullscreenNow(const PHLWINDOW& w) {
        const auto& fullscreen = Fullscreen::controller();
        return fullscreen && fullscreen->getFullscreenModes(w).internal == Fullscreen::FSMODE_FULLSCREEN;
    }

    st::WindowInfo infoOf(const PHLWINDOW& w) {
        return st::WindowInfo{.id = addressOf(w), .app = w->m_class};
    }

    SSpace* spaceOf(st::WorkspaceId id) {
        auto& all = S().spaces;
        const auto it = std::ranges::find_if(all, [id](const SSpace& sp) { return sp.id == id; });
        return it == all.end() ? nullptr : &*it;
    }

    SSpace& ensureSpace(st::WorkspaceId id) {
        if (auto* sp = spaceOf(id))
            return *sp;
        S().spaces.push_back(SSpace{.id = id, .model = {}, .lastFocused = 0});
        return S().spaces.back();
    }

    SSpace* spaceHolding(uint64_t address) {
        for (auto& sp : S().spaces) {
            if (sp.model.contains(address))
                return &sp;
        }
        return nullptr;
    }

    SSpace* spaceWithStage(st::StageId stage) {
        for (auto& sp : S().spaces) {
            if (std::ranges::any_of(sp.model.stages(), [stage](const st::Stage& s) { return s.id == stage; }))
                return &sp;
        }
        return nullptr;
    }

    SWin* winOf(uint64_t address) {
        auto&      all = S().wins;
        const auto it  = std::ranges::find_if(all, [address](const SWin& e) { return e.address == address; });
        return it == all.end() ? nullptr : &*it;
    }

    SStrip* stripOn(const PHLMONITOR& mon) {
        auto&      all = S().strips;
        const auto it  = std::ranges::find_if(all, [&mon](const SStrip& s) { return s.mon.lock() == mon; });
        return it == all.end() ? nullptr : &*it;
    }

    PHLLS stripSurfaceOn(const PHLMONITOR& mon) {
        if (!Desktop::layerState() || !mon)
            return nullptr;
        for (const auto& ls : Desktop::layerState()->layers()) {
            if (ls && ls->m_mapped && ls->m_namespace == STRIP_NAMESPACE && ls->m_monitor.lock() == mon)
                return ls;
        }
        return nullptr;
    }

    // The strip surface's input region covers the tile (its corners and centre; an infinite region covers everything).
    bool inputCovers(const PHLLS& ls, const st::Box& tile) {
        const auto surface = ls->resource();
        if (!surface)
            return false;
        if (surface->m_current.inputIsInfinite)
            return true;
        const double                  x = tile.x - ls->m_geometry.x, y = tile.y - ls->m_geometry.y;
        const std::array<Vector2D, 5> points{Vector2D{x + 1, y + 1}, Vector2D{x + tile.w - 1, y + 1}, Vector2D{x + 1, y + tile.h - 1}, Vector2D{x + tile.w - 1, y + tile.h - 1},
                                             Vector2D{x + (tile.w / 2), y + (tile.h / 2)}};
        return std::ranges::all_of(points, [&surface](const Vector2D& p) { return surface->m_current.input.containsPoint(p); });
    }

    // ---- events ----

    PHLWINDOW frontOfActive(const SSpace& sp);

    // The event names, per monitor, the front window of the shown Desktop's active stage and its app: the menu bar keeps
    // naming that app while Hyprland has no active window (an Exclusive layer holds the keyboard after a swap, ST24).
    void post(st::Reason reason = st::Reason::None) {
        auto&                         s = S();
        std::vector<st::EventMonitor> monitors;
        if (s.on) {
            for (const auto& strip : s.strips) {
                const auto mon = strip.mon.lock();
                if (!mon || !mon->m_activeWorkspace)
                    continue;
                st::EventMonitor m;
                m.monitor   = strip.monitor;
                m.workspace = mon->m_activeWorkspace->m_id;
                m.hidden    = strip.hidden;
                m.overlap   = strip.overlap;
                if (const auto* sp = spaceOf(m.workspace)) {
                    if (const auto front = frontOfActive(*sp))
                        m.front = st::EventFront{.id = addressOf(front), .app = front->m_class};
                    m.active          = sp->model.active();
                    const auto& order = sp->model.stages();
                    for (size_t k = 0; k < order.size(); ++k) {
                        st::EventStage es;
                        es.id   = order[k].id;
                        es.slot = (k > 0 && k - 1 < strip.tiles.size()) ? static_cast<int>(k - 1) : -1;
                        for (const auto id : order[k].windows) {
                            const auto* e = winOf(id);
                            es.windows.push_back(st::EventWindow{.id = id, .thumb = es.slot >= 0 && e ? e->thumb : std::nullopt});
                        }
                        m.stages.push_back(std::move(es));
                    }
                }
                monitors.push_back(std::move(m));
            }
        }
        // The event is a change notice: the state grows with every window and Hyprland cuts socket2 events at 1024 bytes
        // (gfc::kMaxEventBytes); the shell fetches the state with `hyprctl grassfield-stages` (stateReply).
        ++s.generation;
        s.stateJson = st::stateJson(s.generation, s.on, monitors, reason);
        gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::Stages, .id = 0}, st::noticeJson(s.generation, s.on, reason));
    }

    // ---- drawing ----

    void damage(SWin& e, const PHLWINDOW& w) {
        if (!g_pHyprRenderer)
            return;
        const st::Box box = tf::visualBox(w, e.rect);
        for (const auto& b : gf::overview::damageStep(e.damaged, box))
            g_pHyprRenderer->damageBox(tf::toCBox(b));
        e.damaged = box;
    }

    CStageTransformer* attach(const PHLWINDOW& w) {
        auto  transformer = makeUnique<CStageTransformer>();
        auto* raw         = transformer.get();
        w->m_transformers.emplace_back(std::move(transformer));
        if (g_pHyprRenderer)
            g_pHyprRenderer->damageWindow(w);
        return raw;
    }

    // Back to normal rendering (the transformer leaves the window; a destroyed window took it along).
    void detach(SWin& e) {
        if (g_pHyprRenderer && tf::hasArea(e.damaged))
            g_pHyprRenderer->damageBox(tf::toCBox(e.damaged));
        const auto w = e.window.lock();
        if (w && e.transformer) {
            std::erase_if(w->m_transformers, [&e](const UP<Render::IWindowTransformer>& t) { return t.get() == e.transformer; });
            if (g_pHyprRenderer)
                g_pHyprRenderer->damageWindow(w);
        }
        e.transformer = nullptr;
        e.damaged     = {};
    }

    // True when the window's block changed.
    bool setBlocked(SWin& e, bool blocked) {
        const auto w      = e.window.lock();
        const bool change = w && e.blocked != blocked;
        if (change)
            w->setInputBlocked(INPUT_BLOCK_STAGES, blocked);
        e.blocked = blocked && w;
        return change;
    }

    // Drops an entry now: shown normally, input unblocked.
    void release(SWin& e) {
        setBlocked(e, false);
        detach(e);
    }

    // ---- input on strip windows ----

    bool blockedByStages(const PHLWINDOW& w) {
        if (!w)
            return false;
        const auto* e = winOf(addressOf(w));
        return e && e->blocked;
    }

    // The window Stages blocks that owns this surface (its main surface, a subsurface or one of its popups), if any.
    PHLWINDOW blockedOwner(const SP<CWLSurfaceResource>& surface) {
        if (!surface || S().wins.empty())
            return nullptr;
        const auto owner = gf::surfaces::ownerOf(surface);
        return blockedByStages(owner.window) ? owner.window : nullptr;
    }

    SP<CWLSurfaceResource> pointerFocusSurface() {
        return g_pSeatManager ? g_pSeatManager->m_state.pointerFocus.lock() : nullptr;
    }

    // Hyprland 0.56.2 changes the seat's pointer focus only while a pointer device exists (CSeatManager::setPointerFocus
    // logs "BUG THIS" and returns otherwise; virtual pointers come and go). Without one no pointer event can be delivered
    // either: the guard before the next button or scroll (whose device exists by then) does the refresh.
    bool pointerDevice() {
        return g_pInputManager && g_pSeatManager && !g_pSeatManager->m_mouse.expired();
    }

    // The pointer focus goes to nothing: the blocked window gets wl_pointer.leave, the event being delivered reaches no
    // surface. The next press (or the end of the held buttons) refreshes it.
    void parkPointer() {
        if (!pointerDevice())
            return;
        g_pSeatManager->setPointerFocus(nullptr, {});
        S().pointerParked = true;
    }

    // Hyprland's pointer focus logic runs again at the cursor, as after a pointer motion (CInputManager::
    // simulateMouseMovement, Hyprland 0.56.2): its hit test skips blocked windows, so the surface actually under the cursor
    // gets the pointer. The enter and motion get their own wl_pointer.frame (as CInputManager::onMouseMoved sends one), so
    // a button delivered next arrives in a later frame at the new position. While a button is held Hyprland keeps the
    // pressed surface; if that is a blocked window, the pointer is parked on nothing.
    void refreshPointer() {
        auto& s         = S();
        s.pointerParked = false;
        if (!pointerDevice())
            return;
        g_pInputManager->simulateMouseMovement();
        g_pSeatManager->sendPointerFrame();
        if (blockedOwner(pointerFocusSurface()))
            parkPointer();
    }

    // From Hyprland code paths that tear something down (a layer surface unmapping, a monitor going away) and after a
    // release: the refresh runs from the event loop, outside that code.
    void schedulePointerRefresh() {
        auto& s = S();
        if (s.pointerLater || !g_pEventLoopManager)
            return;
        s.pointerLater = g_pEventLoopManager->doLater([] {
            gf::guarded("stages pointer refresh", [] {
                S().pointerLater.reset();
                refreshPointer();
            });
        });
    }

    // The window may keep or take the keyboard: mapped, not hidden, on a workspace shown on a monitor, taking input. A
    // window Stages blocks counts when the model now puts it in the active stage of a shown workspace (the pending
    // retarget unblocks it) and nothing else blocks it.
    bool mayHoldKeyboard(const PHLWINDOW& w) {
        if (!w || !w->m_isMapped || w->isHidden() || !w->m_workspace || !w->m_workspace->isVisible())
            return false;
        if (!blockedByStages(w))
            return w->acceptsInput();
        const auto* sp = spaceHolding(addressOf(w));
        return sp && sp->model.isActive(addressOf(w)) && shownOn(sp->id) && w->noInputBlockedReasonsBesides(INPUT_BLOCK_STAGES_BIT);
    }

    std::string_view originName(st::FocusOrigin origin) {
        switch (origin) {
            case st::FocusOrigin::UserChoice: return "a user choice";
            case st::FocusOrigin::AfterClose: return "after a close";
            case st::FocusOrigin::Restore: return "restoring a window it focused before";
            case st::FocusOrigin::CursorRefocus: return "its refocus at the cursor, without a press";
            case st::FocusOrigin::Automatic: return "its own pick";
        }
        return "?";
    }

    // ---- Hyprland's active window and popup grabs (R13 counter-review of 17208af) ----

    // Drawn in a strip (input blocked), or about to be at the end of the running retarget.
    bool inStrip(const PHLWINDOW& w) {
        const auto* e = w ? winOf(addressOf(w)) : nullptr;
        return e && e->inStrip;
    }

    SP<CWLSurfaceResource> mainSurfaceOf(const PHLWINDOW& w) {
        const auto hl = w ? w->wlSurface() : nullptr;
        return hl ? hl->resource() : nullptr;
    }

    // A menu of this window closes, as a click outside it would (Hyprland's own path, CInputManager::mouseMoveUnified:
    // CSeatManager::setGrab(nullptr); the popups get xdg_popup.popup_done and Hyprland refocuses). Hyprland 0.56.2's
    // xdg_popup grab holds the popup and its parent's surface (the toplevel for a first menu, CXDGShellProtocol::
    // addOrStartGrab), keeps the keyboard on the toplevel and refuses the keyboard to every other surface while it lasts
    // (CFocusState::rawSurfaceFocus): the window going to the strip would keep the keys. Returns whether a grab ended.
    bool endGrabOf(const PHLWINDOW& w, std::string_view when) {
        if (!g_pSeatManager || !g_pSeatManager->m_seatGrab)
            return false;
        const auto surface = mainSurfaceOf(w);
        if (!surface || !g_pSeatManager->m_seatGrab->accepts(surface))
            return false;
        g_pSeatManager->setGrab(nullptr);
        gf::logRequest(Log::INFO, "stages: the menu (popup grab) of window {:x} closed {}", addressOf(w), when);
        return true;
    }

    // Hyprland's active window goes to nothing and the keyboard holder is not touched: CFocusState::resetWindowFocus (what
    // Hyprland itself does when its focused window unmaps, also while an Exclusive layer holds the keyboard:
    // CWindow::onUnmap), then what Hyprland sends when its focus goes to nothing (CFocusState::rawWindowFocus without a
    // window), without its keyboard change: the window is no longer activated (xdg / X11, as Hyprland deactivates the
    // previous window on a focus change), activewindow / activewindowv2 name no window, and window.active(nullptr) (the
    // foreign-toplevel "activated" state the shell's menu bar follows, the appmenu server). Then what Hyprland rechecks
    // when its focus changes (CFocusState::rawWindowFocus, R13 counter-review #4 of 0.6.3-stages): the window rules that
    // match on focus (Desktop::Rule::RULE_PROP_FOCUS, e.g. an opacity while focused) and the idle inhibitors (an
    // `idle_inhibit focus` window no longer inhibits). No focus request, no monitor, workspace or special workspace change:
    // nothing of Hyprland's focus path runs.
    //
    // The layer surface that holds the keyboard (an Exclusive layer: a dialog, the lock-like overlay) stays Hyprland's focus
    // surface. resetWindowFocus forgets the focus surface with the window, and Hyprland gives the seat's keyboard back to
    // its focus surface when a keyboard device appears (a virtual keyboard per burst of keys, a keyboard plugged in): with
    // nothing there every key went nowhere, the dialog's password field included (stages.sh 8c, 8f, 8g, 8h on 2026-10-23,
    // "layer got 0 of the 2 keys" after a swap under the layer, with only transient keyboard devices in the session).
    void clearActiveWindow(const PHLWINDOW& old) {
        const auto fs = Desktop::focusState();
        if (!fs)
            return;
        const auto holder      = keyboardHolder();
        const auto holderOwner = holder ? gf::surfaces::ownerOf(holder) : gf::surfaces::SOwner{};
        fs->resetWindowFocus();
        if (holderOwner.layer && !holderOwner.window)
            S().keysOnLayer = true; // Hyprland's focus surface is set again on unload (restoreFocusSurface)
        if (holder && holderOwner.layer && !holderOwner.window && fs->surface() != holder)
            // The same surface again, no window. Hyprland 0.56.2 returns from rawSurfaceFocus at once when the seat's
            // keyboard is already on that surface (read from the binary: the comparison at the function's start): then
            // nothing is set again and only the seat keeps the holder; otherwise the holder is the focus surface again.
            fs->rawSurfaceFocus(holder);
        if (old && old->m_isMapped && old->m_workspace) {
            if (old->m_ruleApplicator)
                old->m_ruleApplicator->propertiesChanged(Desktop::Rule::RULE_PROP_FOCUS);
            if (g_pXWaylandManager)
                g_pXWaylandManager->activateWindow(old, false);
            old->updateDecorationValues();
        }
        if (g_pEventManager) {
            g_pEventManager->postEvent(SHyprIPCEvent{.event = "activewindow", .data = ","});
            g_pEventManager->postEvent(SHyprIPCEvent{.event = "activewindowv2", .data = ""});
        }
        if (const auto& bus = Event::bus())
            bus->m_events.window.active.emit(nullptr, Desktop::FOCUS_REASON_OTHER);
        if (g_pInputManager)
            g_pInputManager->recheckIdleInhibitorStatus();
    }

    // A press beside an Exclusive layer (PressScope::UntilFocus) no longer counts: a later swap, the next focus change, or
    // Hyprland's refocus once the last Exclusive layer went away.
    void forgetPressBesideLayer() {
        auto& s = S();
        if (s.press.scope == st::PressScope::UntilFocus)
            s.press = {};
    }

    void forgetPending() {
        auto& s = S();
        s.pendingFront.reset();
        s.pendingSpace.reset();
        s.pendingHolder.reset();
    }

    // A focus Hyprland refuses now (an Exclusive layer, the lock) waits: the window, or the front window of its Desktop's
    // active stage if it went away, takes the focus once the refusal is over (applyPendingFocus), checked again then. The
    // latest request wins, also over a click beside the layer made before it.
    void deferFocus(const PHLWINDOW& w, std::string_view why) {
        auto&       s  = S();
        const auto* sp = spaceHolding(addressOf(w));
        s.pendingFront  = w;
        s.pendingSpace  = sp ? std::optional<st::WorkspaceId>{sp->id} : (w->m_workspace ? std::optional<st::WorkspaceId>{w->m_workspace->m_id} : std::nullopt);
        s.pendingHolder = gf::surfaces::ownerOf(keyboardHolder()).layer;
        forgetPressBesideLayer();
        gf::logRequest(Log::DEBUG, "stages: focus of {:x} ({}) deferred: Hyprland refuses window focus while {}", addressOf(w), why,
                       sessionLocked() ? "the session is locked" : "an Exclusive layer surface is mapped");
    }

    // Focuses `w` (a swap's incoming front window, the keyboard rule's pick) when Hyprland accepts a window focus; while
    // it refuses one (an Exclusive layer is mapped, the session is locked) Hyprland is not asked at all and the focus is
    // deferred. The plugin never works around that refusal (R13 counter-review #3 of e9ebc7f).
    void focusOrDefer(const PHLWINDOW& w, std::string_view why) {
        const auto fs = Desktop::focusState();
        if (!fs || !w || !w->m_isMapped)
            return;
        if (windowFocusRefused()) {
            deferFocus(w, why);
            return;
        }
        forgetPending();
        fs->fullWindowFocus(w, Desktop::FOCUS_REASON_OTHER);
    }

    // The window a deferred focus goes to now: the remembered window while it is mapped and still the front window of its
    // Desktop's active stage, else the front window of that Desktop's active stage (the remembered window closed, was
    // minimized or moved away, or another stage came forward meanwhile), else nothing. `remembered` tells which.
    PHLWINDOW pendingTarget(bool& remembered) {
        const auto& s = S();
        remembered    = false;
        if (!s.pendingSpace)
            return nullptr;
        const auto* sp    = spaceOf(*s.pendingSpace);
        const auto  front = sp ? frontOfActive(*sp) : nullptr;
        auto        w     = s.pendingFront.lock();
        if (w && w == front && w->m_isMapped && !w->isHidden()) {
            remembered = true;
            return w;
        }
        return front && front->m_isMapped && !front->isHidden() ? front : nullptr;
    }

    std::string_view dropReason(const st::PendingFocusState& state) {
        if (!state.remembered && !state.hasFront)
            return "its Desktop has no stage left";
        if (state.focused)
            return "that window already holds the keyboard";
        return "its Desktop is not shown or a special workspace covers it";
    }

    // The deferred focus, once Hyprland accepts window focus again (after Hyprland's own restore: an Exclusive layer that
    // unmapped or dropped its keyboard interactivity, the unlock): the front window of the remembered Desktop's active stage
    // (the remembered window, or the window now in front if it went away: macOS gives the keyboard back to the frontmost
    // app's key window) takes the focus and the keyboard (ST23) when that Desktop is shown and not covered by a special
    // workspace, no Exclusive layer is mapped, the session is not locked and the layer surface that held the keyboard does
    // not keep it. It replaces what Hyprland's refocus after the layer picked (a window or a surface under the cursor, or
    // nothing); a special workspace is never closed and a Desktop never switched after the fact.
    void applyPendingFocus(std::string_view when) {
        auto&      s  = S();
        const auto fs = Desktop::focusState();
        if (!s.pendingSpace || !s.on || !fs) {
            forgetPending();
            return;
        }
        bool        remembered = false;
        const auto  target     = pendingTarget(remembered);
        const auto  lost       = s.pendingFront.lock();
        const auto  owner      = gf::surfaces::ownerOf(gf::surfaces::keyboardFocus());
        const auto  holder     = s.pendingHolder.lock();
        const st::PendingFocusState state{.remembered  = remembered,
                                          .hasFront    = target != nullptr,
                                          .shown       = target && target->m_workspace && target->m_workspace->isVisibleNotCovered(),
                                          .locked      = sessionLocked(),
                                          .exclusive   = exclusiveLayerMapped(),
                                          .holderKeeps = holder && holder->m_mapped && owner.layer == holder,
                                          .focused     = target && fs->window() == target && owner.window == target};
        switch (st::pendingFocusAction(state)) {
            case st::PendingFocusAction::Wait: return;
            case st::PendingFocusAction::Drop:
                gf::logRequest(Log::DEBUG, "stages: deferred focus of {:x} dropped {}: {}", lost ? addressOf(lost) : 0, when, dropReason(state));
                forgetPending();
                return;
            case st::PendingFocusAction::Focus:
            case st::PendingFocusAction::FocusFront:
                forgetPending();
                fs->fullWindowFocus(target, Desktop::FOCUS_REASON_OTHER);
                gf::logRequest(Log::INFO, "stages: deferred focus applied {} (Hyprland accepts window focus again) to {:x}{}: {}", when, addressOf(target),
                               remembered ? "" : ", the front window of its Desktop's active stage now (the remembered window went away or is no longer in front)",
                               fs->window() == target ? "it holds the keyboard" : "refused (no_focus rule or modal child)");
                return;
        }
    }

    // From Hyprland's events (a layer surface unmapped, the keyboard focus changed, the unlock): tried from the event loop,
    // after Hyprland's own handling of that event (its refocus after a layer surface unmaps comes after the closed event).
    void schedulePendingFocus() {
        auto& s = S();
        if (!s.pendingSpace)
            return;
        s.pendingAttempt.schedule([] { gf::guarded("stages deferred focus", [] { applyPendingFocus("after a release"); }); });
    }

    void cancelPendingFocus() {
        S().pendingAttempt.cancel(); // its callback is code of this library
        forgetPending();
    }

    // ---- presses: which CLICK focus is the user's (R13 counter-review #4 of 0.6.3-stages) ----

    // Ends the record from the event loop: after Hyprland handled the press (its refocus at the cursor for that press runs
    // while it handles it), or after Hyprland's refocus once the last Exclusive layer went away (a press beside the layer).
    void schedulePressEnd() {
        S().pressEnd.schedule([] {
            gf::guarded("stages press end", [] {
                auto& s = S();
                // A press beside a layer ends once no Exclusive layer is left: Hyprland's refocus after it has run (and did
                // not focus the window pressed).
                if (s.press.scope == st::PressScope::ThisPress || (s.press.scope == st::PressScope::UntilFocus && !exclusiveLayerMapped()))
                    s.press = {};
            });
        });
    }

    void cancelPress() {
        auto& s = S();
        s.pressEnd.cancel(); // its callback is code of this library
        s.press = {};
    }

    // A press arrives (before Hyprland handles it). `pointer`: a pointer button at the cursor; otherwise a touch or a tablet
    // tool, whose point is not the cursor (they count as presses into an Exclusive layer while one is mapped).
    void recordPress(bool pointer) {
        auto& s = S();
        if (!s.on)
            return;
        s.press = st::recordPress(gf::deferredFocus::pressContext(pointer));
        if (s.press.scope == st::PressScope::ThisPress)
            schedulePressEnd();
        else if (s.press.scope == st::PressScope::UntilFocus)
            gf::logRequest(Log::DEBUG, "stages: press beside the Exclusive layer on window {:x}: it takes the focus if Hyprland refocuses it when the layer goes",
                           s.press.target);
    }

    // Hyprland's active window never stays on a strip window: window key bindings (close, full screen, floating), window
    // dispatchers without an explicit window and the shell's menu bar act on it. `preferred`: the window a request or the
    // keyboard rule named (else the front window of the active stage of the active window's workspace). While Hyprland
    // refuses window focus (an Exclusive layer) the strip window is only cleared (no active window, the keyboard holder
    // untouched) and the front window waits for the layer (deferred focus).
    void keepActiveOffStrip(const PHLWINDOW& preferred, std::string_view when) {
        const auto fs     = Desktop::focusState();
        const auto active = fs ? fs->window() : nullptr;
        if (!active || !inStrip(active))
            return;
        const auto* sp     = spaceHolding(addressOf(active));
        auto        front  = preferred && preferred->m_isMapped ? preferred : (sp ? frontOfActive(*sp) : nullptr);
        front              = inStrip(front) ? nullptr : front;
        const auto  holder = keyboardHolder();
        st::ActiveWindowState state{.hidden        = true,
                                    .locked        = sessionLocked(),
                                    .layerKeyboard = holder && gf::surfaces::ownerOf(holder).layer,
                                    .exclusive     = exclusiveLayerMapped(),
                                    .hasFront      = front != nullptr};
        for (int attempt = 0; attempt < 2; ++attempt) {
            switch (st::activeWindowAction(state)) {
                case st::ActiveWindowAction::None:
                    // Once per window and lock, never per event: this runs before every key and pointer event while it
                    // lasts (review of part B, 2026-10-24; a key path logs nothing at all, core/Quiet.hpp).
                    if (state.locked && S().lockStayLogged != addressOf(active)) {
                        S().lockStayLogged = addressOf(active);
                        gf::logRequest(Log::DEBUG, "stages: strip window {:x} stays Hyprland's active window under the session lock", addressOf(active));
                    }
                    if (!state.locked)
                        S().lockStayLogged = 0;
                    return;
                case st::ActiveWindowAction::FocusFront: {
                    forgetPending();
                    fs->fullWindowFocus(front, Desktop::FOCUS_REASON_OTHER);
                    const auto now = fs->window();
                    if (!inStrip(now)) {
                        gf::logRequest(Log::INFO, "stages: Hyprland's active window moved off strip window {:x} to {:x} with the keyboard ({})", addressOf(active),
                                       now ? addressOf(now) : 0, when);
                        return;
                    }
                    state.hasFront = false; // refused (a no_focus rule, a modal child): asked again without it
                    break;
                }
                case st::ActiveWindowAction::Clear:
                    clearActiveWindow(active);
                    if (front && state.exclusive)
                        deferFocus(front, "replaces a strip window as the active window");
                    gf::logRequest(Log::INFO, "stages: strip window {:x} was Hyprland's active window while {}: no active window, the keyboard holder untouched ({}{})",
                                   addressOf(active), state.exclusive ? "an Exclusive layer surface is mapped" : "a layer surface holds the keyboard", when,
                                   front && state.exclusive ? "; the front window takes the focus when the layer releases the keyboard" : "");
                    return;
                case st::ActiveWindowAction::Unfocus:
                    fs->fullWindowFocus(nullptr, Desktop::FOCUS_REASON_OTHER);
                    gf::logRequest(Log::INFO, "stages: strip window {:x} was Hyprland's active window and no window could replace it: nothing focused ({})", addressOf(active),
                                   when);
                    return;
            }
        }
    }

    void tick();

    void armWatchdog() {
        auto& s = S();
        if (!g_pEventLoopManager)
            return;
        if (!s.watchdog) {
            s.watchdog = makeShared<CEventLoopTimer>(
                std::nullopt,
                [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) {
                    gf::guarded("stages watchdog", [] {
                        tick();
                        const auto& s = S();
                        if (s.animating && s.watchdog)
                            s.watchdog->updateTimeout(WATCHDOG_SLACK);
                    });
                },
                nullptr);
            g_pEventLoopManager->addTimer(s.watchdog);
        }
        s.watchdog->updateTimeout(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::duration<double, std::milli>(s.animMs)) + WATCHDOG_SLACK);
    }

    // One animation step (render.preChecks, where Hyprland ticks its own animations, and the watchdog). At the end, windows
    // shown normally again lose their transformer, and entries of windows Stages no longer manages are dropped.
    void tick() {
        auto& s = S();
        if (!s.animating)
            return;
        const double elapsedMs = std::chrono::duration<double, std::milli>(Time::steadyNow() - s.start).count();
        const double t         = gf::overview::progress(elapsedMs, s.animMs);
        const double e         = gf::overview::eased(s.curve, t);
        for (auto it = s.wins.begin(); it != s.wins.end();) {
            const auto w = it->window.lock();
            if (!w) {
                detach(*it);
                it = s.wins.erase(it);
                continue;
            }
            if (it->transformer) {
                it->rect = gf::overview::interpolate(it->from, it->to, tf::surfaceBox(w), e);
                damage(*it, w);
            }
            ++it;
        }
        if (t < 1.0)
            return;
        s.animating = false;
        for (auto it = s.wins.begin(); it != s.wins.end();) {
            it->from = it->to;
            if (!it->to) {
                detach(*it);
                if (!it->inStrip && !it->blocked) {
                    it = s.wins.erase(it); // shown normally: nothing left to track
                    continue;
                }
            }
            ++it;
        }
    }

    void startAnimation(double durationMs) {
        auto& s     = S();
        s.animating = true;
        s.start     = Time::steadyNow();
        s.animMs    = durationMs;
        for (auto& e : s.wins) {
            if (const auto w = e.window.lock(); w && e.transformer) {
                e.rect = gf::overview::interpolate(e.from, e.to, tf::surfaceBox(w), 0.0);
                damage(e, w);
            }
        }
        if (durationMs <= 0)
            tick(); // no animation (Reduce Motion): the end state now
        else
            armWatchdog();
    }

    // Where a retarget runs: from the event loop or a request (focus changes allowed), or inside one of Hyprland's
    // teardown paths (a layer surface unmapping, monitors changing), where windows only leave strips and nothing is
    // focused.
    enum class EContext : uint8_t { Focus, Teardown };

    // Computes every managed window's target from the model and the strips, then applies it: live windows unblocked
    // first, a menu of a window going to the strip closed, `focus` focused (deferred while Hyprland refuses window focus:
    // an Exclusive layer, the lock), Hyprland's active window kept off strip windows, strip windows blocked and
    // transformed, and one animation from where each window is drawn now. The stacking order is Hyprland's
    // (CWindowState::raise would also allow a window over full-screen ones). Returns whether any window's input block
    // changed: the caller then refreshes the pointer focus (refreshPointer, or schedulePointerRefresh inside Hyprland's
    // teardown paths), so that no pointer focus stays on a blocked window.
    [[nodiscard]] bool retarget(double durationMs, const PHLWINDOW& focus = nullptr, EContext context = EContext::Focus) {
        auto& s = S();
        struct STarget {
            PHLWINDOW              w;
            bool                   inStrip = false;
            std::optional<st::Box> to;
            std::optional<st::Box> thumb;
        };
        std::vector<STarget> targets;
        if (s.on) {
            for (const auto& sp : s.spaces) {
                const auto  mon   = shownOn(sp.id);
                const auto& order = sp.model.stages();
                if (!mon) {
                    // Not shown on any monitor (switched away): its windows stay as they are drawn (Hyprland does not render
                    // them; a switch back, and the workspace slide, find them in place).
                    for (const auto& stage : order) {
                        for (const auto id : stage.windows) {
                            const auto  w = windowByAddress(id);
                            const auto* e = w ? winOf(id) : nullptr;
                            if (w)
                                targets.push_back(e ? STarget{.w = w, .inStrip = e->inStrip, .to = e->to, .thumb = e->thumb} :
                                                      STarget{.w = w, .inStrip = false, .to = std::nullopt, .thumb = std::nullopt});
                        }
                    }
                    continue;
                }
                SStrip*    strip = stripOn(mon);
                const bool fs    = showsFullscreen(mon->m_activeWorkspace);
                for (size_t k = 0; k < order.size(); ++k) {
                    std::vector<PHLWINDOW> ws;
                    std::vector<st::Box>   surfaces;
                    std::vector<double>    bands; // the titlebar band above each thumbnail; none for client chrome (ADR-0015 P3)
                    for (const auto id : order[k].windows) {
                        if (const auto w = windowByAddress(id)) {
                            ws.push_back(w);
                            surfaces.push_back(tf::surfaceBox(w));
                            bands.push_back(gf::chrome::bandOf(w));
                        }
                    }
                    if (!strip || k == 0) { // the active stage, or a workspace whose monitor has no strip: shown normally
                        for (const auto& w : ws)
                            targets.push_back(STarget{.w = w, .inStrip = false, .to = std::nullopt, .thumb = std::nullopt});
                        continue;
                    }
                    const auto drawn = st::stripTargets(k - 1, strip->tiles, strip->hidden, fs, monitorBox(mon), surfaces, bands);
                    for (size_t i = 0; i < ws.size() && i < drawn.size(); ++i)
                        targets.push_back(STarget{.w = ws[i], .inStrip = true, .to = drawn[i].to, .thumb = drawn[i].thumb});
                }
            }
        }

        // Windows no longer targeted (unmanaged, Stages off): back to live.
        for (auto& e : s.wins) {
            const bool targeted = std::ranges::any_of(targets, [&e](const STarget& t) { return addressOf(t.w) == e.address; });
            if (!targeted) {
                e.inStrip = false;
                e.to      = std::nullopt;
                e.thumb   = std::nullopt;
            }
        }
        for (const auto& t : targets) {
            SWin* e = winOf(addressOf(t.w));
            if (!e) {
                if (!t.inStrip)
                    continue; // shown normally and never drawn by Stages: nothing to track
                s.wins.push_back(SWin{.window = t.w, .address = addressOf(t.w), .transformer = nullptr, .blocked = false, .inStrip = false, .from = std::nullopt,
                                      .to = std::nullopt, .rect = {}, .damaged = {}, .thumb = std::nullopt});
                e = &s.wins.back();
            }
            e->inStrip = t.inStrip;
            e->to      = t.to;
            e->thumb   = t.thumb;
        }

        // Unblock first, then focus, then block: blocking a focused window would make Hyprland clear the keyboard focus.
        bool changed = false;
        for (auto& e : s.wins) {
            if (!e.inStrip)
                changed = setBlocked(e, false) || changed;
        }
        if (context == EContext::Focus) {
            for (auto& e : s.wins) {
                const auto w = e.inStrip && !e.blocked ? e.window.lock() : nullptr;
                if (w && endGrabOf(w, "as its window goes to the strip"))
                    break; // one grab at a time (Hyprland has one)
            }
            if (focus && focus->m_isMapped)
                focusOrDefer(focus, "the incoming front window");
            keepActiveOffStrip(focus, "as windows go to the strip");
        }
        for (auto& e : s.wins) {
            if (!e.inStrip)
                continue;
            changed = setBlocked(e, true) || changed;
            if (!e.transformer) {
                if (const auto w = e.window.lock()) {
                    // From where a drag dropped it on the strip, else from its live box.
                    e.from        = s.drop && s.drop->address == e.address ? std::optional<st::Box>{s.drop->from} : std::nullopt;
                    e.transformer = attach(w);
                }
            } else
                e.from = e.rect; // from where it is drawn now
        }
        for (auto& e : s.wins) {
            if (!e.inStrip)
                e.from = e.transformer ? std::optional<st::Box>{e.rect} : std::nullopt;
        }
        startAnimation(durationMs);
        post();
        return changed;
    }

    PHLWINDOW frontOfActive(const SSpace& sp) {
        const auto& order = sp.model.stages();
        return order.empty() || order.front().windows.empty() ? nullptr : windowByAddress(order.front().windows.back());
    }

    // The deferred application of model changes: Hyprland's own events (window mapped, closed, moved, focused; workspace
    // switched) and the shell's activate / merge / move requests. Applied from the event loop, outside Hyprland's map,
    // unmap and focus code, one pending call at a time (coalesced): a Lua dispatch with any number of requests causes at
    // most one focus change, so it cannot flood socket2 with Hyprland's own activewindow events (measured: 1000 activate
    // requests applied one by one posted ~1000 activewindowv2 events in one second and Hyprland dropped the shell's
    // socket2 connection, "Socket2 fd 57 overflowed event queue, removing").
    void sync() {
        auto& s = S();
        s.syncLater.reset();
        const auto refocus   = std::exchange(s.refocusSpace, std::nullopt);
        const auto requested = std::exchange(s.focusLater, PHLWINDOWREF{}).lock();
        if (!s.on) {
            s.drop.reset();
            return;
        }
        // A workspace whose last managed window left (a closed Split View Desktop, a transient named workspace) is forgotten:
        // retarget() walks every space. Here, from the event loop, nothing holds a pointer into the list; adopt() makes it
        // again when a window comes.
        std::erase_if(s.spaces, [](const SSpace& sp) { return sp.model.stages().empty(); });
        PHLWINDOW focus = requested;
        bool      clear = false;
        if (!focus && refocus) {
            // The focused window left the active stage (closed, unmapped, minimized, moved away), or Hyprland focused a strip
            // window without a user choice. Hyprland's pick stands only if that window may hold the keyboard; otherwise the
            // active stage's front window takes it, or nothing does (never a minimized, hidden or strip window: Hyprland
            // cannot pick a blocked successor and leaves the keyboard on the window it moved to special:minimized).
            const auto  current = Desktop::focusState() ? Desktop::focusState()->window() : nullptr;
            const auto* sp      = spaceOf(*refocus);
            const auto  front   = sp ? frontOfActive(*sp) : nullptr;
            switch (st::keyboardAfterLeave(st::KeyboardHolder{.present = current != nullptr, .eligible = mayHoldKeyboard(current)}, front != nullptr)) {
                case st::KeyboardTarget::Keep: break;
                case st::KeyboardTarget::FrontOfActive: focus = front; break;
                case st::KeyboardTarget::Nothing: clear = current != nullptr; break;
            }
        }
        const bool changed = retarget(s.durationMs, focus);
        // A window dropped on the strip is drawn in it now: its real place goes back to where it was before the drag.
        if (auto drop = std::exchange(s.drop, std::nullopt); drop && drop->restore) {
            const auto  w = drop->window.lock();
            const auto* e = w ? winOf(drop->address) : nullptr;
            if (e && e->inStrip && e->transformer && g_layoutManager && w->layoutTarget()) {
                const st::Box& r = *drop->restore;
                g_layoutManager->setTargetGeom(CBox{r.x, r.y, r.w, r.h}, w->layoutTarget());
            }
        }
        if (clear && Desktop::focusState() && !windowFocusRefused()) {
            const auto current = Desktop::focusState()->window();
            if (current && !mayHoldKeyboard(current)) {
                gf::logRequest(Log::DEBUG, "stages: window {:x} may not keep the keyboard and no stage is left: keyboard focus cleared", addressOf(current));
                Desktop::focusState()->fullWindowFocus(nullptr, Desktop::FOCUS_REASON_OTHER);
            }
        }
        if (changed)
            refreshPointer();
    }

    // Applies a pending sync now (the keyboard guard: keys must not wait for the event loop while they would reach a
    // window the pending sync unblocks or takes the keyboard from).
    void flushSync() {
        auto& s = S();
        if (!s.syncLater)
            return;
        if (g_pEventLoopManager)
            g_pEventLoopManager->removeDoLater(*s.syncLater);
        s.syncLater.reset();
        sync();
    }

    // `refocus`: after a close, the active stage of this workspace takes the keyboard unless Hyprland gave it to one of its
    // windows. `focus`: the window a request made key (the latest request wins).
    void scheduleSync(std::optional<st::WorkspaceId> refocus = std::nullopt, const PHLWINDOW& focus = nullptr) {
        auto& s = S();
        if (refocus)
            s.refocusSpace = refocus;
        if (focus)
            s.focusLater = focus;
        if (s.syncLater || !g_pEventLoopManager)
            return;
        s.syncLater = g_pEventLoopManager->doLater([] { gf::guarded("stages sync", [] { sync(); }); });
    }

    // ---- Hyprland events ----

    // The window joins its workspace's stages (a new window, a restored one, one moved in from another workspace).
    void adopt(const PHLWINDOW& w) {
        auto& s = S();
        if (!s.on || !manageable(w))
            return;
        auto& sp = ensureSpace(w->m_workspace->m_id);
        if (!sp.model.add(infoOf(w), s.nextId)) {
            if (!sp.model.contains(addressOf(w)))
                gf::logRequest(Log::INFO, "stages: window {:x} not managed (workspace full: {} windows)", addressOf(w), st::kMaxWindowsPerWorkspace);
            return;
        }
        scheduleSync();
    }

    // The window leaves Stages now (closed, unmapped, moved away, pinned, tiled): shown normally at once. When it held the
    // keyboard, the active stage of its workspace takes it after Hyprland's own refocus (sync).
    void drop(const PHLWINDOW& w) {
        auto&          s       = S();
        const uint64_t address = addressOf(w);
        std::optional<st::WorkspaceId> from;
        for (auto& sp : s.spaces) {
            if (sp.model.remove(address))
                from = sp.id;
        }
        bool changed = from.has_value();
        if (auto* e = winOf(address)) {
            release(*e);
            std::erase_if(s.wins, [address](const SWin& x) { return x.address == address; });
            changed = true;
        }
        if (!changed || !s.on)
            return;
        const bool focused = Desktop::focusState() && Desktop::focusState()->window() == w;
        scheduleSync(focused ? from : std::nullopt);
    }

    // A window's properties changed (floating, pinned, full screen): it joins or leaves Stages accordingly; a strip window
    // made full screen (a dispatch by address) brings its stage forward.
    void reconsider(const PHLWINDOW& w) {
        if (!S().on || !w)
            return;
        const uint64_t address = addressOf(w);
        auto*          sp      = spaceHolding(address);
        if (manageable(w) && !sp)
            adopt(w);
        else if (!manageable(w) && sp)
            drop(w);
        else if (sp && fullscreenNow(w) && !sp->model.isActive(address)) {
            if (const auto stage = sp->model.stageOf(address))
                sp->model.activate(*stage);
            scheduleSync();
        } else
            scheduleSync(); // e.g. full screen on its workspace: its strip goes away while it is shown
    }

    // Hyprland focused a window. A strip window chosen by the user (a key binding, a focus dispatch, the Dock or another
    // activation request, a click) brings its stage forward (macOS: activating an app shows its stage). A strip window
    // Hyprland picked itself is not a choice: after a close (UNMAP_*), when it restores a window it focused before (FFM:
    // an Exclusive layer released the keyboard, which also happens after a swap made while that layer held the keyboard:
    // the swap is kept, never undone; WORKSPACE_CHANGE back to a Desktop's last window; a special workspace closed), or for
    // another reason of its own (a new window mapped, a group change, a plugin; a refocus at the cursor without a press, which
    // Hyprland reports as CLICK). The keyboard then goes to the active stage instead. A window of the active stage comes to
    // its front, except when a deferred focus is about to replace Hyprland's own pick (ST23).
    void onActive(const PHLWINDOW& w, Desktop::eFocusReason reason) {
        auto& s = S();
        if (!s.on)
            return;
        const auto press = s.press;
        forgetPressBesideLayer(); // a click beside an Exclusive layer counts for the next focus change only
        if (!w)
            return;
        const uint64_t address = addressOf(w);
        // The last window Hyprland focused on each workspace (what a WORKSPACE_CHANGE back to it restores).
        auto*      shown   = w->m_workspace ? spaceOf(w->m_workspace->m_id) : nullptr;
        const bool wasLast = shown && shown->lastFocused == address;
        if (shown)
            shown->lastFocused = address;
        const auto cause  = causeOf(reason);
        const auto origin = st::focusOrigin(cause, wasLast, cause == st::FocusCause::Click && st::clickFromPress(press, address));
        // A deferred focus is done once its window is focused, and superseded by another window the user chose. Hyprland's
        // own pick (its refocus at the cursor when the layer went away, a restore) does not supersede it.
        bool keepsPending = false;
        if (s.pendingSpace) {
            bool       remembered = false;
            const auto target     = pendingTarget(remembered);
            if (target == w || st::stripFocusBringsStage(origin)) {
                if (target != w)
                    gf::logRequest(Log::DEBUG, "stages: deferred focus of {:x} dropped: the user chose window {:x}", target ? addressOf(target) : 0, address);
                forgetPending();
            } else {
                keepsPending = true;
                gf::logRequest(Log::DEBUG, "stages: Hyprland focused {:x} ({}): the deferred focus of {:x} stays", address, originName(origin), target ? addressOf(target) : 0);
            }
        }
        auto* sp = spaceHolding(address);
        if (!sp)
            return;
        if (sp->model.isActive(address)) {
            if (!keepsPending && sp->model.raise(address))
                post(); // the front window changed: the event names it
            return;
        }
        if (!st::stripFocusBringsStage(origin)) {
            gf::logRequest(Log::DEBUG, "stages: Hyprland focused strip window {:x} (reason {}: {}): the active stage takes the keyboard", address, static_cast<int>(reason),
                           originName(origin));
            scheduleSync(sp->id);
            return;
        }
        if (const auto stage = sp->model.stageOf(address); stage && sp->model.activate(*stage)) {
            sp->model.raise(address);
            gf::logRequest(Log::INFO, "stages: strip window {:x} focused (reason {}): its stage {} becomes active", address, static_cast<int>(reason), *stage);
            scheduleSync();
        }
    }

    // A strip surface went away (the shell exited or unmapped it): that monitor's windows are shown normally at once.
    void onLayerClosed(const PHLLS& ls) {
        auto& s = S();
        if (!ls || ls->m_namespace != STRIP_NAMESPACE)
            return;
        const auto mon    = ls->m_monitor.lock();
        const auto before = s.strips.size();
        std::erase_if(s.strips, [&mon](const SStrip& strip) { return !strip.mon.lock() || strip.mon.lock() == mon; });
        if (s.strips.size() == before || !s.on)
            return;
        gf::logRequest(Log::INFO, "stages: the shell's strip surface on {} went away: its windows are shown normally", mon ? mon->m_name : std::string{"?"});
        if (retarget(0, nullptr, EContext::Teardown))
            schedulePointerRefresh(); // inside Hyprland's layer unmap: refreshed from the event loop
        post(st::Reason::Interrupted);
    }

    void onMonitorsChanged() {
        auto& s = S();
        if (!s.on)
            return;
        std::erase_if(s.strips, [](const SStrip& strip) { return !strip.mon.lock() || !monitorByName(strip.monitor); });
        if (retarget(0, nullptr, EContext::Teardown)) // tiles may lie outside a moved monitor: the shell sends new strips
            schedulePointerRefresh();
        post(st::Reason::Interrupted);
    }

    // ---- input guards (Hyprland delivers to its current focus without checking input blocks) ----

    // The frontmost mapped layer surface with Exclusive keyboard interactivity in Hyprland's list (core replacesFrontmost:
    // the highest layer, the latest among equals), or null. No allocation: the list is only read.
    PHLLS frontmostExclusiveLayer() {
        PHLLS best;
        if (!g_pInputManager)
            return best;
        for (const auto& ref : g_pInputManager->m_exclusiveLSes) {
            const auto ls = ref.lock();
            if (ls && ls->m_mapped && ls->resource() && gf::surfaces::interactivity(ls) == 1 &&
                st::replacesFrontmost(ls->m_layer, best ? std::optional<uint32_t>{best->m_layer} : std::nullopt))
                best = ls;
        }
        return best;
    }

    bool onExclusiveLayer(const SP<CWLSurfaceResource>& surface) {
        const auto owner = surface ? gf::surfaces::ownerOf(surface) : gf::surfaces::SOwner{};
        return owner.layer && gf::surfaces::interactivity(owner.layer) == 1;
    }

    bool inputMethodGrabsKeyboard() {
        const auto im = g_pInputManager ? g_pInputManager->m_relay.m_inputMethod.lock() : nullptr;
        return im && im->hasGrab();
    }

    // Hyprland's active window may take the keyboard: mapped, not hidden, on a workspace shown, takes input (no input
    // block, Stages' included), not a strip window.
    bool activeWindowTakesKeys(const PHLWINDOW& w) {
        return w && w->m_isMapped && !w->isHidden() && w->m_workspace && w->m_workspace->isVisible() && w->acceptsInput() && !inStrip(w);
    }

    // Before every key, before Hyprland delivers it, and from the event loop after Hyprland changed the keyboard focus, a
    // layer surface mapped or unmapped, or a keyboard device appeared (`keyArriving` false; core keyFocusAction: why, and
    // every condition). The frontmost Exclusive Top or Overlay layer gets the keyboard when the seat's keyboard is elsewhere
    // (on nothing, a window, another surface: a surface that takes the keyboard on demand mapped over the dialog); with no
    // Exclusive layer and a key arriving, Hyprland's active window gets it back when the seat's keyboard is on nothing.
    // Through Hyprland's own CFocusState::rawSurfaceFocus (its focus surface and the seat's keyboard agree afterwards; the
    // seat grab is checked here first, so Hyprland never logs a refusal per key). The event-loop check moves the keyboard
    // before the next key: a key that arrives right after wl_keyboard.enter can be lost by the client (stages.sh 8j: the
    // first key after a banner mapped over the dialog was lost with the check before keys only). Runs while the plugin is
    // loaded only (the listeners go on unload); before a key it allocates nothing and logs nothing (a key path,
    // core/Quiet.hpp): the common case (no Exclusive layer, the seat's keyboard on a surface) returns after two reads.
    bool keepKeyboardFocus(bool keyArriving) {
        const bool exclusive = g_pInputManager && !g_pInputManager->m_exclusiveLSes.empty();
        if (!exclusive)
            S().keysOnLayer = false; // no Exclusive layer left: Hyprland refocused, nothing to set again on unload
        const auto seat = gf::surfaces::keyboardFocus();
        if (!exclusive && seat)
            return false;
        const auto fs = Desktop::focusState();
        if (!fs || !g_pSeatManager)
            return false;
        const auto            grab   = g_pSeatManager->m_seatGrab;
        const auto            target = exclusive ? frontmostExclusiveLayer() : nullptr;
        const auto            layer  = target ? target->resource() : nullptr;
        const auto            window = exclusive ? nullptr : fs->window();
        SP<CWLSurfaceResource> windowSurface;
        if (activeWindowTakesKeys(window)) {
            windowSurface = fs->surface();
            if (!windowSurface || gf::surfaces::ownerOf(windowSurface).window != window)
                windowSurface = mainSurfaceOf(window);
        }
        const st::KeyFocusFacts facts{.locked            = sessionLocked(),
                                      .inputMethodGrab   = inputMethodGrabsKeyboard(),
                                      .exclusive         = exclusive,
                                      .frontmostLevel    = target ? target->m_layer : 0,
                                      .seatOnFrontmost   = layer && seat && gf::surfaces::ownerOf(seat).layer == target,
                                      .grabRejectsLayer  = grab && layer && !grab->accepts(layer),
                                      .seatFocusNone     = !seat,
                                      .activeWindow      = windowSurface != nullptr,
                                      .grabRejectsWindow = grab && windowSurface && !grab->accepts(windowSurface),
                                      .keyArriving       = keyArriving};
        const auto action = st::keyFocusAction(facts);
        if (action == st::KeyFocusAction::None)
            return false;
        auto&      s = S();
        const bool wasMoving = std::exchange(s.movingKeyFocus, true); // Hyprland's focus event for this move is not a new cause
        try {
            if (action == st::KeyFocusAction::ToLayer && layer)
                fs->rawSurfaceFocus(layer);
            else if (action == st::KeyFocusAction::ToWindow && windowSurface)
                fs->rawSurfaceFocus(windowSurface, window);
        } catch (...) {
            s.movingKeyFocus = wasMoving;
            throw; // to the guard of the caller (gf::keyPath or gf::guarded): nothing escapes into Hyprland
        }
        s.movingKeyFocus = wasMoving;
        return true;
    }

    // The previous key's keyboard device went away and the one typing now is the session's only keyboard device: the seat
    // had no keyboard in between, so clients re-created their wl_keyboard (core ReannounceFacts). With another keyboard
    // left (a laptop's own while an external one reconnects) the seat kept its keyboard and nothing is announced. Read
    // only; the device is remembered for the next key (a weak reference: nothing allocated).
    bool keyDeviceReplaced() {
        auto&      s        = S();
        const auto keyboard = g_pSeatManager ? g_pSeatManager->m_keyboard.lock() : nullptr;
        const bool alone    = g_pInputManager && g_pInputManager->m_keyboards.size() == 1;
        const bool replaced = s.hadKeyDevice && s.keyDevice.expired() && keyboard && alone;
        if (keyboard) {
            s.keyDevice    = keyboard;
            s.hadKeyDevice = true;
        }
        return replaced;
    }

    // Before the first key of a keyboard device that replaced the previous one: the surface that holds the keyboard gets
    // wl_keyboard.leave and enter again, to that same surface (core reannounceFocus: why, and when not; while locked only a
    // session-lock surface, CSessionLockManager::isSurfaceSessionLock). Hyprland's focus state is not touched; nothing is
    // allocated or logged.
    void reannounceKeyboardFocus() {
        const auto seat = gf::surfaces::keyboardFocus();
        const auto grab = g_pSeatManager ? g_pSeatManager->m_seatGrab : nullptr;
        const st::ReannounceFacts facts{.replaced         = true,
                                        .locked           = sessionLocked(),
                                        .inputMethodGrab  = inputMethodGrabsKeyboard(),
                                        .seatGrab         = grab != nullptr,
                                        .grabAcceptsFocus = grab && seat && grab->accepts(seat),
                                        .focus            = seat != nullptr,
                                        .focusIsLock      = g_pSessionLockManager && seat && g_pSessionLockManager->isSurfaceSessionLock(seat)};
        if (!g_pSeatManager || !st::reannounceFocus(facts))
            return;
        auto&      s         = S();
        const bool wasMoving = std::exchange(s.movingKeyFocus, true);
        try {
            g_pSeatManager->setKeyboardFocus(nullptr);
            g_pSeatManager->setKeyboardFocus(seat);
        } catch (...) {
            s.movingKeyFocus = wasMoving;
            throw; // to the key path's guard: nothing escapes into Hyprland
        }
        s.movingKeyFocus = wasMoving;
    }

    // The wl_keyboard objects of the client that holds the keyboard (CWLSeatResource::m_keyboards), live ones only.
    // Every wl_seat the client bound (a client may bind it more than once; CSeatManager::seatResourceForClient returns the
    // first only): its live wl_keyboard objects, through libwayland's own list of the client's resources.
    std::vector<WP<CWLKeyboardResource>> focusClientKeyboards() {
        std::vector<WP<CWLKeyboardResource>> out;
        const auto                           seat   = gf::surfaces::keyboardFocus();
        wl_client*                           client = seat ? seat->client() : nullptr;
        if (!client)
            return out;
        wl_client_for_each_resource(
            client,
            [](wl_resource* resource, void* data) -> wl_iterator_result {
                const char* cls = resource ? wl_resource_get_class(resource) : nullptr;
                if (cls && std::string_view{cls} == wl_seat_interface.name) {
                    if (const auto seatResource = CWLSeatResource::fromResource(resource)) {
                        for (const auto& k : seatResource->m_keyboards) {
                            if (!k.expired())
                                static_cast<std::vector<WP<CWLKeyboardResource>>*>(data)->push_back(k);
                        }
                    }
                }
                return WL_ITERATOR_CONTINUE;
            },
            &out);
        return out;
    }

    void stopAnnounce() {
        auto& s = S();
        s.announceDevice.reset();
        s.announceKnown.clear();
        if (s.announceTimer)
            s.announceTimer->updateTimeout(std::nullopt);
    }

    // A keyboard device appeared as the session's only one (core ReannounceFacts): when the seat had no keyboard in
    // between, the client that holds the keyboard re-creates its wl_keyboard once it sees the capability again, a moment
    // later. The announce is made as soon as that new wl_keyboard exists, before the first key (a key that arrives right
    // after wl_keyboard.enter is lost by a Quickshell client: stages.sh 8j and 8k lost the first key of each burst with the
    // announce made in the key path). Checked every 10 ms for at most 500 ms; after that the key path announces it (that
    // key may be lost, the next ones arrive). Allocates when a device appears, never per key.
    constexpr int kAnnounceTries = 50;

    void announceTick() {
        auto&      s      = S();
        const auto device = s.announceDevice.lock();
        if (!device) {
            stopAnnounce();
            return;
        }
        const auto now      = focusClientKeyboards();
        const bool reCreated = std::ranges::any_of(now, [&s](const WP<CWLKeyboardResource>& k) {
            return std::ranges::none_of(s.announceKnown, [&k](const WP<CWLKeyboardResource>& known) { return known.lock() == k.lock(); });
        });
        if (reCreated) {
            s.keyDevice       = device; // its first key is not announced again
            s.hadKeyDevice    = true;
            s.announcedDevice = device;
            stopAnnounce();
            reannounceKeyboardFocus();
            return;
        }
        if (++s.announceTries >= kAnnounceTries) {
            stopAnnounce();
            return;
        }
        s.announceTimer->updateTimeout(std::chrono::milliseconds(10));
    }

    void armAnnounce(const SP<IKeyboard>& keyboard) {
        auto&      s     = S();
        const bool alone = g_pInputManager && g_pInputManager->m_keyboards.size() == 1;
        if (!keyboard || !alone || !g_pEventLoopManager || s.keyDevice.lock() == keyboard)
            return;
        s.announceDevice = keyboard;
        s.announceKnown  = focusClientKeyboards();
        s.announceTries  = 0;
        if (!s.announceTimer) {
            s.announceTimer = makeShared<CEventLoopTimer>(
                std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { gf::guarded("stages keyboard announce", [] { announceTick(); }); }, nullptr);
            g_pEventLoopManager->addTimer(s.announceTimer);
        }
        s.announceTimer->updateTimeout(std::chrono::milliseconds(10));
    }

    // The same check from the event loop, after Hyprland's own handling of the event that may have moved the keyboard (a
    // focus change, a layer surface mapped or unmapped, a keyboard device that appeared). Coalesced; never for the plugin's
    // own move.
    void scheduleKeyFocusCheck() {
        auto& s = S();
        if (s.movingKeyFocus || s.keyFocusLater || !g_pEventLoopManager)
            return;
        s.keyFocusLater = g_pEventLoopManager->doLater([] {
            gf::guarded("stages keyboard focus check", [] {
                S().keyFocusLater.reset();
                keepKeyboardFocus(false);
            });
        });
    }

    // Unload (review of part B, m3): Hyprland's focus surface may still be empty after clearActiveWindow while the seat's
    // keyboard is on an Exclusive layer; without the plugin, a new keyboard device would then get nothing. It is set again
    // to that layer (the seat's keyboard leaves it for an instant: rawSurfaceFocus does nothing while the seat is on it).
    // Never while the session is locked or under a seat grab that rejects it.
    void restoreFocusSurface() {
        auto& s = S();
        if (!s.keysOnLayer)
            return;
        s.keysOnLayer      = false;
        const auto fs      = Desktop::focusState();
        const auto seat    = gf::surfaces::keyboardFocus();
        const auto grab    = g_pSeatManager ? g_pSeatManager->m_seatGrab : nullptr;
        if (!fs || !g_pSeatManager || !seat || fs->surface() || sessionLocked() || !onExclusiveLayer(seat) || (grab && !grab->accepts(seat)))
            return;
        g_pSeatManager->setKeyboardFocus(nullptr);
        fs->rawSurfaceFocus(seat);
    }

    // Before Hyprland delivers a key (and runs its key bindings, which act on its active window): neither the keyboard nor
    // Hyprland's active window may be on a window Stages blocks (a strip window Hyprland focused itself, e.g. a restore
    // while a sync is pending; the active window left behind while the session lock refused every focus). A pending sync
    // is applied first (the window may be about to come forward); the active window then moves off the strip
    // (keepActiveOffStrip); a menu (popup grab) of a strip window closes, as a click outside it would, so that its keys are
    // not lost; if the keyboard is still on a blocked window it goes to the front window of that workspace's active stage,
    // or nowhere.
    // The keyboard focus itself is checked first (keepKeyboardFocus), whether Stages is on or not.
    void beforeKey() {
        auto& s = S();
        // A key arrived: a pending announce stops here (a late one could land between this key's press and release); the
        // key path announces instead, unless the timer already did for this device.
        const auto keyboard = g_pSeatManager ? g_pSeatManager->m_keyboard.lock() : nullptr;
        if (s.announceDevice.lock())
            stopAnnounce();
        const bool replaced = keyDeviceReplaced();
        if (!keepKeyboardFocus(true) && replaced && (!keyboard || s.announcedDevice.lock() != keyboard))
            reannounceKeyboardFocus(); // a fresh enter, unless the keyboard was just moved (that was one); may lose this key
        if (!s.on)
            return;
        if (s.pendingSpace) { // the layer may have released the keyboard before the deferred focus ran
            s.pendingAttempt.cancel();
            applyPendingFocus("before a key");
        }
        if (s.wins.empty())
            return;
        const auto fs = Desktop::focusState();
        if (!blockedOwner(gf::surfaces::keyboardFocus()) && !(fs && inStrip(fs->window())))
            return;
        flushSync();
        keepActiveOffStrip(nullptr, "before a key");
        auto blocked = blockedOwner(gf::surfaces::keyboardFocus());
        if (!blocked || !fs)
            return;
        endGrabOf(blocked, "before a key");
        if (!blockedOwner(gf::surfaces::keyboardFocus()))
            return;
        const auto* sp    = spaceHolding(addressOf(blocked));
        const auto  front = sp ? frontOfActive(*sp) : nullptr;
        if (front && mayHoldKeyboard(front) && !windowFocusRefused())
            fs->fullWindowFocus(front, Desktop::FOCUS_REASON_OTHER);
        if (blockedOwner(gf::surfaces::keyboardFocus())) {
            if (!windowFocusRefused())
                fs->fullWindowFocus(nullptr, Desktop::FOCUS_REASON_OTHER);
            if (blockedOwner(gf::surfaces::keyboardFocus()))
                fs->rawSurfaceFocus(nullptr); // the keyboard leaves the strip window for nothing (never for another surface)
        }
        const auto now = gf::surfaces::ownerOf(gf::surfaces::keyboardFocus()).window;
        gf::logRequest(Log::INFO, "stages: a key arrived while the keyboard was on strip window {:x}: keyboard moved first to {:x} (0: nothing)", addressOf(blocked),
                       now ? addressOf(now) : 0);
    }

    // Before Hyprland delivers a pointer button or scroll to its pointer focus (never cancelled: Hyprland's held-button
    // state must see every press and release).
    void beforePointer(st::PointerEvent event) {
        auto& s = S();
        if (!s.ready || (s.wins.empty() && !s.pointerParked))
            return;
        const auto focus   = pointerFocusSurface();
        const auto blocked = blockedOwner(focus);
        switch (st::beforePointerEvent(event, st::PointerState{.onBlocked = blocked != nullptr, .hasFocus = focus != nullptr, .parked = s.pointerParked})) {
            case st::PointerAction::None: break;
            case st::PointerAction::Refresh:
                refreshPointer();
                if (blocked)
                    gf::logRequest(Log::INFO, "stages: pointer {} while the pointer focus was strip window {:x}: pointer focus refreshed first ({})",
                                   event == st::PointerEvent::Axis ? "scroll" : "press", addressOf(blocked), S().pointerParked ? "parked: a held button" : "under the cursor");
                break;
            case st::PointerAction::Park:
                parkPointer();
                gf::logRequest(Log::INFO, "stages: release while the pointer focus was strip window {:x}: dropped (no surface)", blocked ? addressOf(blocked) : 0);
                break;
        }
        if (event == st::PointerEvent::Release && s.pointerParked)
            schedulePointerRefresh(); // after Hyprland processed the release
    }

    // While windows are drawn in a strip, a frame of this monitor may come from damage at a strip window's real place (its
    // content changed): the thumbnail boxes of this monitor are added to the frame's damage (render.pre, after Hyprland's
    // animation tick, before beginRender reads the damage ring). Frames without damage are not touched. The strip overlap
    // (an active-stage window near the tiles) is checked in the same frame and posted when it changes.
    void onRenderPre(const PHLMONITOR& mon) {
        auto& s = S();
        if (!s.on || !mon || !mon->m_damage.hasChanged())
            return;
        for (auto& e : s.wins) {
            const auto w = e.window.lock();
            if (!w || !e.transformer || w->m_monitor.lock() != mon)
                continue;
            const st::Box box = tf::visualBox(w, e.rect);
            for (const auto& b : gf::overview::damageStep(e.damaged, box))
                mon->m_damage.damage(tf::toCBox(b).translate(-mon->m_position).scale(mon->m_scale).round());
            e.damaged = box;
        }
        SStrip* strip = stripOn(mon);
        if (!strip || !mon->m_activeWorkspace || !Desktop::windowState())
            return;
        const st::Box band    = st::stripBand(strip->tiles, OVERLAP_MARGIN);
        bool          overlap = false;
        for (const auto& w : Desktop::windowState()->windows()) {
            if (!w || !w->m_isMapped || w->isHidden() || w->m_workspace != mon->m_activeWorkspace || !w->acceptsInput())
                continue;
            const st::Box full = tf::fullBox(w);
            if (gf::minimize::intersects(full, band)) {
                overlap = true;
                break;
            }
        }
        if (overlap != strip->overlap) {
            strip->overlap = overlap;
            post();
        }
    }

    // ---- transformer ----

    SP<Render::IFramebuffer> drawStage(const CStageTransformer* self, const SP<Render::IFramebuffer>& in) {
        if (!in || !tf::monitorFrame())
            return in;
        auto&      all = S().wins;
        const auto it  = std::ranges::find_if(all, [self](const SWin& e) { return e.transformer == self; });
        if (it == all.end())
            return in;
        const auto w   = it->window.lock();
        const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!w || !mon)
            return in;
        if (gf::overviewer::transforms(w))
            return in; // the overview draws this window now (its transformer comes after or before this one: both see `in`)
        if (mon != w->m_monitor.lock())
            return tf::drawNothing(in); // a window spanning monitors is shown only in its own monitor's strip
        return tf::drawFitted(w, it->rect, in, S().warnedNoBuffer, it->address);
    }

    SP<Render::IFramebuffer> CStageTransformer::transform(SP<Render::IFramebuffer> in) {
        SP<Render::IFramebuffer> out = in;
        gf::guarded("stages transform", [&] { out = drawStage(this, in); });
        return out;
    }

    // ---- requests ----

    // Stages ends: every window shown normally again (input unblocked at once, transformers detached after the animation).
    void turnOff(double durationMs, st::Reason reason) {
        auto& s = S();
        if (!s.on && s.wins.empty()) {
            post(reason);
            return;
        }
        s.on = false;
        s.spaces.clear();
        s.strips.clear();
        if (s.syncLater && g_pEventLoopManager)
            g_pEventLoopManager->removeDoLater(*s.syncLater);
        s.syncLater.reset();
        s.refocusSpace.reset();
        s.focusLater.reset();
        s.drop.reset();
        cancelPendingFocus();
        cancelPress();
        if (retarget(durationMs)) // nothing is targeted any more: every window animates back to its live box
            refreshPointer();
        post(reason);
    }

    // Stages starts: the windows of every workspace are grouped by app, the focused window's stage active.
    void turnOn() {
        auto& s = S();
        s.on    = true;
        s.spaces.clear();
        if (!Desktop::windowState())
            return;
        const auto focused = Desktop::focusState() ? Desktop::focusState()->window() : nullptr;
        struct SPending {
            st::WorkspaceId              id = 0;
            std::vector<st::WindowInfo> windows;
            uint64_t                     lastFocused = 0; // Hyprland's last focused window of that workspace (read only)
        };
        std::vector<SPending> perSpace;
        for (const auto& w : Desktop::windowState()->windows()) { // bottom to top
            if (!manageable(w))
                continue;
            const auto id = w->m_workspace->m_id;
            auto       it = std::ranges::find_if(perSpace, [id](const SPending& p) { return p.id == id; });
            if (it == perSpace.end()) {
                const auto last = w->m_workspace->m_lastFocusedWindow.lock();
                perSpace.push_back(SPending{.id = id, .windows = {}, .lastFocused = last ? addressOf(last) : 0});
                it = perSpace.end() - 1;
            }
            it->windows.push_back(infoOf(w));
        }
        for (const auto& p : perSpace) {
            auto& sp = ensureSpace(p.id);
            sp.model.reset(p.windows, focused ? std::optional<st::WindowId>{addressOf(focused)} : std::nullopt, s.nextId);
            sp.lastFocused = p.lastFocused;
        }
    }

    // Each strip's monitor exists, has the shell's strip surface (mapped, Top or Overlay layer) and that surface and its
    // input region cover every tile.
    bool stripsCovered(const std::vector<st::Strip>& strips) {
        for (const auto& strip : strips) {
            const auto mon = monitorByName(strip.monitor);
            if (!mon) {
                gf::logRequest(Log::WARN, "stages: rejected: no monitor {}", strip.monitor);
                return false;
            }
            const auto ls = stripSurfaceOn(mon);
            if (!ls) {
                gf::logRequest(Log::WARN, "stages: rejected: no mapped {} surface on {}", STRIP_NAMESPACE, strip.monitor);
                return false;
            }
            const st::Box box{ls->m_geometry.x, ls->m_geometry.y, ls->m_geometry.w, ls->m_geometry.h};
            const bool    layerOk = ls->m_layer >= ZWLR_LAYER_SHELL_V1_LAYER_TOP;
            // The tiles always lie on their monitor; a hidden strip (its thumbnails off the monitor) may keep only its reveal
            // zone as input region (core stripAccepted).
            const bool inside  = st::tilesInMonitor(strip.tiles, monitorBox(mon));
            const bool boxOk   = strip.hidden || st::tilesCovered(strip.tiles, box, monitorBox(mon));
            const bool inputOk = strip.hidden || std::ranges::all_of(strip.tiles, [&ls](const st::Box& t) { return inputCovers(ls, t); });
            if (!st::stripAccepted(strip.hidden, layerOk, inside, boxOk, inputOk)) {
                gf::logRequest(Log::WARN, "stages: rejected: the {} surface on {} (layer {}, box {:.0f},{:.0f} {:.0f}x{:.0f}) must be on the Top or Overlay layer, its tiles on the monitor and, while the strip is shown, under its box and input region",
                               STRIP_NAMESPACE, strip.monitor, ls->m_layer, box.x, box.y, box.w, box.h);
                return false;
            }
        }
        return true;
    }

} // namespace

namespace gf::stager {

    bool start() {
        auto& bus = Event::bus();
        if (!bus || !Fullscreen::controller() || !Desktop::windowState() || !State::monitorState())
            return false;
        // A load starts with the flag off and nothing managed, also when the library stayed mapped since a previous load
        // (FR23 pins it while appmenu clients are alive, so this function-static state can outlive an unload).
        auto& s   = S();
        s.enabled = false;
        s.on      = false;
        s.drop.reset();
        s.spaces.clear();
        s.wins.clear();
        s.strips.clear();
        s.pointerLater.reset();
        s.pointerParked = false;
        s.pendingAttempt.clear();
        forgetPending();
        s.pressEnd.clear();
        s.press         = {};
        auto& ev        = bus->m_events;
        auto& l         = S().listeners;
        // Input guards, observed and never cancelled (FR13): they move a stale focus off a blocked window before Hyprland
        // delivers the event. Pointer buttons are guarded from the plugin's first button listener (main.cpp).
        l.push_back(ev.input.keyboard.key.listen([](IKeyboard::SKeyEvent e, Event::SCallbackInfo& info) {
            gf::keyPath("stages key guard", [](const IKeyboard::SKeyEvent& /*e*/, Event::SCallbackInfo& /*info*/) { beforeKey(); }, e, info);
        }));
        l.push_back(ev.input.mouse.axis.listen(
            [](IPointer::SAxisEvent /*e*/, Event::SCallbackInfo& /*info*/) { gf::guarded("stages scroll guard", [] { beforePointer(st::PointerEvent::Axis); }); }));
        // Presses other than pointer buttons (beforePointerButton): Hyprland refocuses at the touch point / tool on a touch
        // down, a tablet tip down and a tablet button press (reason CLICK, R13 counter-review #4 of 0.6.3-stages).
        l.push_back(ev.input.touch.down.listen([](const ITouch::SDownEvent& /*e*/, Event::SCallbackInfo& /*info*/) { gf::guarded("stages touch press", [] { recordPress(false); }); }));
        l.push_back(ev.input.tablet.tip.listen([](const CTablet::STipEvent& e, Event::SCallbackInfo& /*info*/) {
            gf::guarded("stages tablet tip", [&] {
                if (e.in)
                    recordPress(false);
            });
        }));
        l.push_back(ev.input.tablet.button.listen([](const CTablet::SButtonEvent& e, Event::SCallbackInfo& /*info*/) {
            gf::guarded("stages tablet button", [&] {
                if (e.down)
                    recordPress(false);
            });
        }));
        l.push_back(ev.render.preChecks.listen([](const PHLMONITOR& /*monitor*/) { gf::guarded("stages tick", [] { tick(); }); }));
        l.push_back(ev.render.pre.listen([](const PHLMONITOR& monitor) { gf::guarded("stages render.pre", [&] { onRenderPre(monitor); }); }));
        l.push_back(ev.window.open.listen([](const PHLWINDOW& w) { gf::guarded("stages window.open", [&] { adopt(w); }); }));
        l.push_back(ev.window.close.listen([](const PHLWINDOW& w) { gf::guarded("stages window.close", [&] { drop(w); }); }));
        l.push_back(ev.window.destroy.listen([](const PHLWINDOWREF& /*w*/) {
            gf::guarded("stages window.destroy", [] { std::erase_if(S().wins, [](const SWin& e) { return !e.window.lock(); }); });
        }));
        l.push_back(ev.window.moveToWorkspace.listen([](const PHLWINDOW& w, const PHLWORKSPACE& /*ws*/) {
            gf::guarded("stages window.moveToWorkspace", [&] {
                drop(w);  // out of its old workspace's stages, shown normally
                adopt(w); // into the new workspace's stages (a regular workspace only: minimized windows stay out)
            });
        }));
        l.push_back(ev.window.floating.listen([](const PHLWINDOW& w) { gf::guarded("stages window.floating", [&] { reconsider(w); }); }));
        l.push_back(ev.window.pin.listen([](const PHLWINDOW& w) { gf::guarded("stages window.pin", [&] { reconsider(w); }); }));
        l.push_back(ev.window.fullscreen.listen([](const PHLWINDOW& w) { gf::guarded("stages window.fullscreen", [&] { reconsider(w); }); }));
        l.push_back(ev.window.active.listen([](const PHLWINDOW& w, Desktop::eFocusReason reason) { gf::guarded("stages window.active", [&] { onActive(w, reason); }); }));
        // A Desktop switch: its stages are shown or kept; on a Desktop with stages, the keyboard rule applies (Hyprland
        // may have focused nothing: its candidates skip blocked windows, and the last focused window may have closed
        // while that Desktop was not shown).
        l.push_back(ev.workspace.active.listen([](const PHLWORKSPACE& ws) {
            gf::guarded("stages workspace.active", [&] {
                if (S().on)
                    scheduleSync(ws && spaceOf(ws->m_id) ? std::optional<st::WorkspaceId>{ws->m_id} : std::nullopt);
            });
        }));
        // After an unlock Hyprland refocuses at the cursor only (CSessionLockManager): its active window may still be the
        // window a swap made under the lock sent to the strip (every focus is refused while locked).
        if (g_pSessionLockManager)
            l.push_back(g_pSessionLockManager->m_events.unlock.listen([] {
                gf::guarded("stages unlock", [] {
                    if (S().on) {
                        scheduleSync();
                        schedulePendingFocus(); // a focus deferred under the lock
                    }
                });
            }));
        // A layer surface unmapping (an Exclusive one releases the keyboard; Hyprland refocuses after this event) or the
        // keyboard focus changing (an Exclusive layer dropping its keyboard interactivity): a deferred focus is tried from
        // the event loop, after Hyprland's own handling.
        // A click beside an Exclusive layer counts for Hyprland's refocus once the last such layer is gone, then ends.
        l.push_back(ev.layer.closed.listen([](const PHLLS& ls) {
            gf::guarded("stages layer.closed", [&] {
                onLayerClosed(ls);
                schedulePendingFocus();
                if (S().press.scope == st::PressScope::UntilFocus)
                    schedulePressEnd();
            });
        }));
        // The keyboard focus check (keepKeyboardFocus) also runs from the event loop after these: a layer surface mapped or
        // unmapped, a keyboard device that appeared (its layout set), and every keyboard focus change below.
        l.push_back(ev.layer.opened.listen([](const PHLLS& /*ls*/) { gf::guarded("stages layer.opened", [] { scheduleKeyFocusCheck(); }); }));
        // A keyboard device that appears sets its layout (CInputManager::setupKeyboard -> applyConfigToKeyboard).
        l.push_back(ev.input.keyboard.layout.listen([](const SP<IKeyboard>& keyboard, const std::string& /*layout*/) {
            gf::guarded("stages keyboard.layout", [&] {
                scheduleKeyFocusCheck();
                armAnnounce(keyboard);
            });
        }));
        l.push_back(ev.input.keyboard.focus.listen([](const SP<CWLSurfaceResource>& /*surface*/) {
            gf::guarded("stages keyboard.focus", [] {
                scheduleKeyFocusCheck();
                schedulePendingFocus();
                if (S().press.scope == st::PressScope::UntilFocus)
                    schedulePressEnd();
            });
        }));
        l.push_back(ev.monitor.removed.listen([](const PHLMONITOR& /*monitor*/) { gf::guarded("stages monitor.removed", [] { onMonitorsChanged(); }); }));
        l.push_back(ev.monitor.layoutChanged.listen([] { gf::guarded("stages monitor.layoutChanged", [] { onMonitorsChanged(); }); }));
        S().ready = true;
        return true;
    }

    void stop() {
        auto& s = S();
        s.ready = false;
        s.listeners.clear();
        if (s.syncLater && g_pEventLoopManager)
            g_pEventLoopManager->removeDoLater(*s.syncLater); // its callback is code of this library
        s.syncLater.reset();
        if (s.pointerLater && g_pEventLoopManager)
            g_pEventLoopManager->removeDoLater(*s.pointerLater); // likewise
        s.pointerLater.reset();
        if (s.keyFocusLater && g_pEventLoopManager)
            g_pEventLoopManager->removeDoLater(*s.keyFocusLater); // likewise
        s.keyFocusLater.reset();
        if (s.announceTimer && g_pEventLoopManager)
            g_pEventLoopManager->removeTimer(s.announceTimer); // its callback is code of this library
        s.announceTimer.reset();
        s.announceDevice.reset();
        s.announcedDevice.reset();
        s.announceKnown.clear();
        s.refocusSpace.reset();
        restoreFocusSurface();
        s.focusLater.reset();
        s.drop.reset();
        cancelPendingFocus();
        cancelPress();
        const bool wasOn = s.on || !s.wins.empty();
        s.on             = false;
        s.enabled        = false;
        s.animating      = false;
        for (auto& e : s.wins)
            release(e); // no transformer of this library may outlive dlclose; no window may stay blocked
        s.wins.clear();
        if (std::exchange(s.pointerParked, false) && g_pInputManager)
            g_pInputManager->simulateMouseMovement(); // a parked pointer finds the surface under the cursor again
        s.spaces.clear();
        s.strips.clear();
        if (s.watchdog) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.watchdog);
            s.watchdog.reset();
        }
        if (wasOn)
            post(st::Reason::Unavailable);
    }

    std::string stateReply() {
        const auto& s = S();
        return s.stateJson.empty() ? st::stateJson(0, false, {}) : s.stateJson;
    }

    bool ready() {
        return S().ready;
    }

    std::optional<double> stripColumnRight(const PHLMONITOR& monitor) {
        const auto& s = S();
        if (!s.ready || !s.on || !monitor)
            return std::nullopt;
        for (const auto& strip : s.strips) {
            if (strip.mon.lock() != monitor || strip.tiles.empty())
                continue;
            double right = strip.tiles.front().x + strip.tiles.front().w;
            for (const auto& t : strip.tiles)
                right = std::max(right, t.x + t.w);
            return right + st::kStripDropMargin;
        }
        return std::nullopt;
    }

    bool inStripStage(const PHLWINDOW& w) {
        return S().ready && inStrip(w);
    }

    void beforePointerButton(bool pressed) {
        if (pressed)
            recordPress(true); // which CLICK focus Hyprland reports next is this press (R13 counter-review #4 of 0.6.3-stages)
        beforePointer(pressed ? st::PointerEvent::Press : st::PointerEvent::Release);
    }

    bool enabled() {
        return S().enabled;
    }

    void setEnabled(bool on) {
        auto& s = S();
        if (s.enabled == on)
            return;
        s.enabled = on;
        if (!on && (s.on || !s.wins.empty()))
            turnOff(0, st::Reason::Disabled);
    }

    void refuse(st::Reason reason) {
        post(reason);
    }

    bool dropOnStrip(const PHLWINDOW& w, double x, double y, bool tiling, std::optional<st::Box> before) {
        auto& s = S();
        if (!s.ready || !s.on || !w || !State::monitorState())
            return false;
        PHLMONITOR mon;
        for (const auto& m : State::monitorState()->monitors()) {
            if (m && m->m_enabled && m->logicalBox().containsPoint(Vector2D{x, y})) {
                mon = m;
                break;
            }
        }
        const SStrip*  strip   = mon ? stripOn(mon) : nullptr;
        const uint64_t address = addressOf(w);
        SSpace*        sp      = spaceHolding(address);
        const bool     shown   = sp && mon && shownOn(sp->id) == mon;
        const auto&    stages  = shown ? sp->model.stages() : std::vector<st::Stage>{};
        const st::DropFacts facts{.on       = true,
                                  .hasStrip = strip != nullptr,
                                  .hidden   = strip && strip->hidden,
                                  .inZone   = strip && st::inDropZone(x, y, strip->tiles, monitorBox(mon)),
                                  .managed  = shown,
                                  .active   = shown && sp->model.isActive(address),
                                  .alone    = !stages.empty() && stages.front().windows.size() == 1,
                                  .tiling   = tiling};
        if (st::dropAction(facts) != st::DropAction::NewStage || !sp->model.moveWindow(address, std::nullopt, s.nextId))
            return false;
        s.drop = SStagesState::SDrop{.window = w, .address = address, .from = tf::surfaceBox(w), .restore = before};
        gf::logRequest(Log::INFO, "stages: window {:x} dropped on the strip of {}: a stage of its own", address, mon->m_name);
        scheduleSync(std::nullopt, frontOfActive(*sp)); // out of the active stage: its front window keeps or takes the keyboard
        return true;
    }

    void request(const st::Request& r) {
        auto& s = S();
        if (!s.ready) {
            post(st::Reason::Unavailable);
            return;
        }
        if (r.op == st::Op::Off) {
            turnOff(r.durationMs, st::Reason::None);
            return;
        }
        if (!s.enabled) {
            gf::logRequest(Log::WARN, "stages: rejected: the feature flag is off (config {} = true first)", st::kConfigStagesEnabled);
            refuse(st::Reason::Disabled);
            return;
        }
        switch (r.op) {
            case st::Op::On: {
                if (!stripsCovered(r.strips)) {
                    refuse(st::Reason::NoStrip);
                    return;
                }
                std::vector<SStrip> strips;
                for (const auto& strip : r.strips) {
                    const auto mon     = monitorByName(strip.monitor);
                    const auto* before = stripOn(mon);
                    strips.push_back(SStrip{.monitor = strip.monitor, .mon = mon, .tiles = strip.tiles, .hidden = strip.hidden, .overlap = before && before->overlap});
                }
                s.strips     = std::move(strips);
                s.durationMs = r.durationMs;
                s.curve      = r.curve;
                const bool starting = !s.on;
                if (starting)
                    turnOn();
                gf::logRequest(Log::INFO, "stages: {} with {} strip(s), {:.0f} ms", starting ? "on" : "strips updated", s.strips.size(), r.durationMs);
                if (retarget(r.durationMs))
                    refreshPointer();
                return;
            }
            case st::Op::Activate:
            case st::Op::Merge: {
                auto* sp = s.on ? spaceWithStage(r.stage) : nullptr;
                const bool ok = sp && (r.op == st::Op::Activate ? sp->model.activate(r.stage) : sp->model.merge(r.stage));
                if (!ok) {
                    gf::logRequest(Log::INFO, "stages: {} {}: no such strip stage", r.op == st::Op::Activate ? "activate" : "merge", r.stage);
                    refuse(st::Reason::Unknown);
                    return;
                }
                scheduleSync(std::nullopt, frontOfActive(*sp)); // applied once per event loop pass (coalesced)
                return;
            }
            case st::Op::Move: {
                auto* sp = s.on ? spaceHolding(r.window) : nullptr;
                if (!sp || (!r.newStage && !std::ranges::any_of(sp->model.stages(), [&r](const st::Stage& x) { return x.id == r.stage; }))) {
                    gf::logRequest(Log::INFO, "stages: move {:x}: unknown window or stage (stages are per workspace)", r.window);
                    refuse(st::Reason::Unknown);
                    return;
                }
                const bool wasActive = sp->model.isActive(r.window);
                if (!sp->model.moveWindow(r.window, r.newStage ? std::nullopt : std::optional<st::StageId>{r.stage}, s.nextId)) {
                    refuse(st::Reason::Unknown);
                    return;
                }
                const bool nowActive = sp->model.isActive(r.window);
                // Onto the stage: that window becomes key. Out of the stage: the stage's front window keeps or takes the keyboard.
                scheduleSync(std::nullopt, nowActive ? windowByAddress(r.window) : (wasActive ? frontOfActive(*sp) : nullptr));
                return;
            }
            case st::Op::Off: break;
        }
    }

} // namespace gf::stager
