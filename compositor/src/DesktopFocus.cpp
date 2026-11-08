#include "DesktopFocus.hpp"

#include "DeferredFocus.hpp"
#include "Plugin.hpp"
#include "Surfaces.hpp"
#include "Tiling.hpp"
#include "Titlebar.hpp"
#include "core/DesktopFocus.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <linux/input-event-codes.h>

#include <algorithm>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace df = gf::desktopfocus;

namespace {
    struct SDesktopLayer {
        PHLLSREF            layer;
        uint64_t            id = 0; // the layer surface's address: compared, never dereferenced
        CHyprSignalListener commit; // on its CLayerShellResource (interactivity changes arrive in commits)
    };

    struct SDesktopFocusState {
        bool                             ready = false;
        std::vector<CHyprSignalListener> listeners;
        std::vector<SDesktopLayer>       desktops;
        df::CPendingGrant                pending;
        df::CUnlockRefocus               unlock;        // the refocus an unlock armed
        gf::deferredFocus::CLater        unlockAttempt; // its attempt from the event loop (code of this library)
        SP<CEventLoopTimer>              unlockRetry;   // retries while the lock surface holds the keyboard; removed in stop()
    };

    // Constructed on first use inside a guarded call (R13). Emptied by stop() before dlclose.
    SDesktopFocusState& st() {
        static SDesktopFocusState s;
        return s;
    }

    uint64_t idOf(const PHLLS& ls) {
        return reinterpret_cast<uintptr_t>(ls.get());
    }

    std::string monitorName(const PHLLS& ls) {
        const auto mon = ls ? ls->m_monitor.lock() : nullptr;
        return mon ? mon->m_name : std::string{"?"};
    }

    // What a wl_surface is for the policy, with the window or layer surface it belongs to.
    struct SResolved {
        df::SurfaceKind kind = df::SurfaceKind::None;
        PHLWINDOW       window;
        PHLLS           layer;
    };

    SResolved resolve(const SP<CWLSurfaceResource>& surface) {
        if (!surface)
            return {};
        const auto owner = gf::surfaces::ownerOf(surface);
        if (owner.layer)
            return {.kind = df::classifyLayer(owner.layer->m_namespace, owner.popup), .window = nullptr, .layer = owner.layer};
        if (owner.window) {
            if (owner.popup)
                return {.kind = df::SurfaceKind::WindowPopup, .window = owner.window, .layer = nullptr};
            return {.kind = df::SurfaceKind::Window, .window = owner.window, .layer = nullptr};
        }
        return {.kind = df::SurfaceKind::Other, .window = nullptr, .layer = nullptr};
    }

    SP<CWLSurfaceResource> keyboardSurface() {
        return gf::surfaces::keyboardFocus();
    }

    df::Seat seatNow(const SResolved& keyboard) {
        df::Seat seat;
        seat.keyboard     = keyboard.kind;
        seat.keyboardGrab = g_pSeatManager && g_pSeatManager->m_seatGrab && g_pSeatManager->m_seatGrab->m_keyboard;
        seat.exclusiveLayer =
            g_pInputManager && std::ranges::any_of(g_pInputManager->m_exclusiveLSes, [](const PHLLSREF& ls) { return ls && ls->m_mapped; });
        seat.locked = !g_pSessionLockManager || g_pSessionLockManager->isSessionLocked(); // undecidable: locked
        return seat;
    }

    df::Interactivity interactivityOf(const PHLLS& ls) {
        return df::interactivityFromProtocol(gf::surfaces::interactivity(ls));
    }

    bool windowFocusable(const PHLWINDOW& w) {
        return w && w->m_isMapped && !w->isHidden() && !w->m_X11ShouldntFocus;
    }

    // A window whose input is blocked (a Stages strip window, or one of Hyprland's own reasons) is never live: Hyprland's
    // hit test skips it, so it can only be the pointer focus because no pointer motion happened since it was blocked.
    df::PointerFocus pointerFocusState(const SP<CWLSurfaceResource>& surface) {
        if (!surface)
            return df::PointerFocus::None;
        const auto owner = gf::surfaces::ownerOf(surface);
        return df::classifyPointerFocus(true, owner.known, owner.visible, !owner.window || owner.window->acceptsInput());
    }

    // The window or layer surface under the cursor, looked up in the order Hyprland 0.56.2 uses for pointer focus
    // (CInputManager::mouseMoveUnified, source read as data): layer popups, the Overlay and Top layers, windows (their
    // popups, surfaces and Grassfield titlebars), the Bottom and Background layers. A window's border outside its titlebar
    // and surface counts as nothing (left to Hyprland: a press there resizes).
    SResolved underCursor() {
        if (!g_pInputManager || !Desktop::viewState() || !State::monitorState())
            return {};
        const Vector2D pos = g_pInputManager->getMouseCoordsInternal();
        const auto     mon = State::monitorState()->query().vec(pos).run();
        if (!mon)
            return {};
        Vector2D local;
        PHLLS    layer;
        auto     surface = Desktop::viewState()->hitTest().layerPopupSurfaceAt(pos, mon, &local, &layer);
        for (const auto level : {ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_LAYER_SHELL_V1_LAYER_TOP}) {
            if (!surface)
                surface = Desktop::viewState()->hitTest().layerSurfaceAt(pos, &mon->m_layerSurfaceLayers[level], &local, &layer);
        }
        if (surface)
            return resolve(surface);
        constexpr auto props = static_cast<uint16_t>(gf::flagsOf(Desktop::View::RESERVED_EXTENTS, Desktop::View::INPUT_EXTENTS, Desktop::View::ALLOW_FLOATING));
        if (const auto w = Desktop::viewState()->hitTest().windowAt(pos, props)) {
            Vector2D windowLocal;
            if (const auto ws = Desktop::viewState()->hitTest().windowSurfaceAt(pos, w, windowLocal))
                return resolve(ws);
            const bool onBar = std::ranges::any_of(gf::state().titlebars, [&](const CGrassfieldTitlebar* deco) { return deco->window() == w && deco->barContains(pos); });
            return onBar ? SResolved{.kind = df::SurfaceKind::Window, .window = w, .layer = nullptr} : SResolved{};
        }
        for (const auto level : {ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM, ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND}) {
            if (!surface)
                surface = Desktop::viewState()->hitTest().layerSurfaceAt(pos, &mon->m_layerSurfaceLayers[level], &local, &layer);
        }
        return surface ? resolve(surface) : SResolved{};
    }

    // The surface the press lands on: Hyprland's pointer focus (it follows the pointer with follow_mouse 2) when it is a
    // live surface; otherwise (none, or the destroyed or unmapped surface of a popup that closed since the last pointer
    // motion) what lies under the cursor. Over a Grassfield titlebar there is no pointer focus (decorations are not
    // surfaces): the lookup under the cursor then finds the window whose titlebar contains the pointer.
    SResolved pressTarget(df::PointerFocus& focusState) {
        const auto pointer = g_pSeatManager ? g_pSeatManager->m_state.pointerFocus.lock() : nullptr;
        focusState         = pointerFocusState(pointer);
        if (df::pressTargetSource(focusState) == df::TargetSource::PointerFocus)
            return resolve(pointer);
        return underCursor();
    }

    std::string_view pointerFocusName(df::PointerFocus focus) {
        switch (focus) {
            case df::PointerFocus::Live: return "pointer focus";
            case df::PointerFocus::None: return "under the cursor, no pointer focus";
            case df::PointerFocus::Stale: return "under the cursor, stale pointer focus";
        }
        return "?";
    }

    bool keyboardOnWindow(const PHLWINDOW& w) {
        const auto k = resolve(keyboardSurface());
        return k.kind == df::SurfaceKind::Window && k.window == w;
    }

    bool keyboardOnLayer(const PHLLS& ls) {
        const auto k = keyboardSurface();
        return k && ls && k == ls->resource();
    }

    // Hyprland's own click focus, with every rule Hyprland applies (no_focus window rule, a modal child, the session lock,
    // an Exclusive layer, X11 windows that refuse focus); returns whether the window holds the keyboard afterwards.
    // Hyprland's click path skips a window it still counts as focused (ADR-0012 spike row 2), but fullWindowFocus does
    // not: CFocusState::rawWindowFocus returns early only when the requested surface is the focused surface (Hyprland
    // 0.56.2 source, read as data; 22/22 grants in desktop_focus.sh); when Hyprland's focus state still names the window's
    // surface although the keyboard left it, the state is reset first (gf::deferredFocus::focusWindow). The surface focus
    // is never forced (R13 review of 5706cbd): when Hyprland refuses, the keyboard stays where it is.
    bool focusWindow(const PHLWINDOW& w, bool& stateReset) {
        gf::deferredFocus::focusWindow(w, Desktop::FOCUS_REASON_CLICK, &stateReset);
        return keyboardOnWindow(w);
    }

    // The layer surface that holds the keyboard now, as a policy id (nullopt: a window, nothing, or another kind).
    std::optional<uint64_t> keyboardLayerId(const SP<CWLSurfaceResource>& surface) {
        const auto owner = gf::surfaces::ownerOf(surface);
        if (!owner.layer || owner.popup)
            return std::nullopt;
        return idOf(owner.layer);
    }

    // Another path moved the keyboard (or changed what the user expects to type into) while a desktop grant waits: the
    // grant is dropped, so the desktop's late on_demand commit cannot take the keyboard back (R13 review of 5706cbd).
    void onFocusEvent(df::FocusEvent event, std::optional<uint64_t> keyboardLayer) {
        auto&      s       = st();
        const auto armed   = s.pending.surface();
        const auto outcome = s.pending.onFocusEvent(event, keyboardLayer, df::Clock::now());
        if (outcome != df::GrantUpdate::NotArmed && armed)
            gf::logRequest(Log::DEBUG, "desktop-focus: pending grant for desktop {:x} {} ({})", *armed, df::grantUpdateName(outcome), df::focusEventName(event));
    }

    void focusDesktop(const PHLLS& ls, const char* when) {
        const auto focus   = Desktop::focusState();
        const auto surface = ls ? ls->resource() : nullptr;
        if (!focus || !surface || !ls->m_mapped)
            return;
        focus->rawSurfaceFocus(surface, nullptr);
        gf::logRequest(Log::DEBUG, "desktop-focus: desktop {:x} ({}): keyboard to the desktop {} ({})", idOf(ls), monitorName(ls),
                       when, keyboardOnLayer(ls) ? "granted" : "NOT granted");
    }

    // Why a window grant did not give the window the keyboard, as far as the plugin can tell.
    std::string_view refusalReason(bool refusedNow, bool noKeyboard) {
        if (noKeyboard)
            return "not granted: the seat has no keyboard device, so no surface can get the keyboard";
        if (refusedNow)
            return "not asked: window focus is refused now (session lock or Exclusive layer)";
        return "refused by Hyprland (no_focus rule, modal child or another focus rule): the keyboard stays where it is";
    }

    // ---- the keyboard back after an unlock (FR30 (e)) ----

    df::KeyboardHolder holderKind(const SP<CWLSurfaceResource>& surface) {
        if (!surface)
            return df::KeyboardHolder::None;
        const auto owner = gf::surfaces::ownerOf(surface);
        return owner.window || owner.layer ? df::KeyboardHolder::Known : df::KeyboardHolder::Unknown;
    }

    void attemptUnlockRefocus();

    void retryUnlockRefocus(bool again) {
        auto& s = st();
        if (!again) {
            if (s.unlockRetry)
                s.unlockRetry->updateTimeout(std::nullopt);
            return;
        }
        if (!g_pEventLoopManager)
            return;
        if (!s.unlockRetry) {
            s.unlockRetry = makeShared<CEventLoopTimer>(
                std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { gf::guarded("desktop-focus unlock retry", [] { attemptUnlockRefocus(); }); }, nullptr);
            g_pEventLoopManager->addTimer(s.unlockRetry);
        }
        s.unlockRetry->updateTimeout(std::chrono::duration_cast<std::chrono::milliseconds>(df::kUnlockRetryInterval));
    }

    void attemptUnlockRefocus() {
        auto& s = st();
        if (!s.unlock.armed(df::Clock::now())) {
            s.unlock.cancel();
            retryUnlockRefocus(false);
            return;
        }
        const auto      fs = Desktop::focusState();
        const PHLWINDOW w  = fs ? fs->window() : nullptr;
        df::UnlockSeat  seat;
        seat.locked             = gf::deferredFocus::sessionLocked();
        seat.windowFocusRefused = gf::deferredFocus::exclusiveLayerMapped();
        seat.holder             = holderKind(keyboardSurface());
        seat.windowFocusable    = w && windowFocusable(w) && w->m_workspace && w->m_workspace->isVisible();
        const auto step         = df::unlockStep(seat);
        if (step == df::UnlockStep::Wait) {
            retryUnlockRefocus(true); // the lock surface still holds it: again shortly (its destruction sends no event)
            return;
        }
        s.unlock.cancel();
        retryUnlockRefocus(false);
        if (step == df::UnlockStep::Done) {
            gf::logRequest(Log::DEBUG, "desktop-focus: after the unlock: nothing to give back (locked {}, Exclusive layer {}, keyboard on {}, focused window {:x})", seat.locked,
                           seat.windowFocusRefused, seat.holder == df::KeyboardHolder::Known ? "a window or layer surface" : "no surface",
                           reinterpret_cast<uintptr_t>(w.get()));
            return;
        }
        bool       stateReset = false;
        const bool granted    = gf::deferredFocus::focusWindow(w, Desktop::FOCUS_REASON_OTHER, &stateReset);
        gf::logRequest(granted ? Log::DEBUG : Log::INFO, "desktop-focus: after the unlock the keyboard was on no surface: window {:x} (Hyprland's focused window) -> {}{}",
                       reinterpret_cast<uintptr_t>(w.get()), granted ? "keyboard to the window" : "refused by Hyprland (no_focus rule or another focus rule)",
                       stateReset ? " (focus state reset)" : "");
    }

    void scheduleUnlockRefocus() {
        st().unlockAttempt.schedule([] { gf::guarded("desktop-focus unlock refocus", [] { attemptUnlockRefocus(); }); });
    }

    void onPress(const IPointer::SButtonEvent& e) {
        if (e.state != WL_POINTER_BUTTON_STATE_PRESSED)
            return;
        auto& s = st();
        s.pending.cancel(); // any press decides afresh
        s.unlock.cancel();  // after an unlock too: the press is the user's choice
        retryUnlockRefocus(false);

        df::PointerFocus focusState = df::PointerFocus::Live;
        const auto       keyboard   = resolve(keyboardSurface());
        const auto       target     = pressTarget(focusState);
        const df::Seat   seat       = seatNow(keyboard);
        df::Press      press;
        press.target  = target.kind;
        press.primary = e.button == BTN_LEFT;
        if (target.kind == df::SurfaceKind::Window) {
            const auto focus        = Desktop::focusState();
            press.windowFocusable   = windowFocusable(target.window);
            press.targetHasKeyboard = (keyboard.kind == df::SurfaceKind::Window || keyboard.kind == df::SurfaceKind::WindowPopup) && keyboard.window == target.window;
            press.targetIsFocused   = focus && target.window && focus->window() == target.window;
        } else if (target.kind == df::SurfaceKind::Desktop) {
            press.interactivity     = interactivityOf(target.layer);
            press.targetHasKeyboard = keyboard.kind == df::SurfaceKind::Desktop && keyboard.layer == target.layer;
        }

        const auto action = df::onPress(seat, press);
        if (action == df::Action::FocusWindow) {
            // One line per grant, the refusal included (request log budget), with the reason the plugin can tell.
            const bool refusedNow = gf::deferredFocus::windowFocusRefused(); // the plugin then asks nothing
            const bool noKeyboard = !g_pSeatManager || !g_pSeatManager->m_keyboard.lock();
            bool       stateReset = false;
            const bool granted    = focusWindow(target.window, stateReset);
            gf::logRequest(granted ? Log::DEBUG : Log::INFO, "desktop-focus: press (button {:#x}) on window {:x} ({}{}) while the keyboard is on {} -> {}{}", e.button,
                           reinterpret_cast<uintptr_t>(target.window.get()), pointerFocusName(focusState), press.targetIsFocused ? ", Hyprland's focused window" : "",
                           df::kindName(keyboard.kind), granted ? std::string_view{"keyboard to the window"} : refusalReason(refusedNow, noKeyboard),
                           stateReset ? " (Hyprland's focus state still named the window: reset)" : "");
            return;
        }
        if (action != df::Action::None || keyboard.kind == df::SurfaceKind::Desktop)
            gf::logRequest(Log::DEBUG, "desktop-focus: press (button {:#x}) on {} ({}) while the keyboard is on {} -> {}", e.button, df::kindName(target.kind),
                           pointerFocusName(focusState), df::kindName(keyboard.kind), df::actionName(action));
        switch (action) {
            case df::Action::None:
            case df::Action::FocusWindow: break;
            case df::Action::FocusDesktop: focusDesktop(target.layer, "at the press"); break;
            case df::Action::AwaitOnDemand: s.pending.arm(idOf(target.layer), df::Clock::now()); break;
        }
    }

    // A commit of a desktop layer surface: if a press armed it and it is on_demand now, it gets the keyboard (the shell
    // switched None -> OnDemand on that press; Hyprland itself would wait for the next pointer motion).
    void onDesktopCommit(const PHLLS& ls) {
        auto& s = st();
        if (!ls || !s.pending.surface() || *s.pending.surface() != idOf(ls))
            return;
        if (!s.pending.onCommit(idOf(ls), interactivityOf(ls), df::Clock::now()))
            return;
        const auto keyboard = resolve(keyboardSurface());
        if (!ls->m_mapped || !df::mayGrantDesktop(seatNow(keyboard), keyboardOnLayer(ls)))
            return;
        focusDesktop(ls, "after its on_demand commit");
    }

    // The tracked desktop layer of `id` (SDesktopLayer::id), null when it is gone or no longer tracked.
    PHLLS layerOf(uint64_t id) {
        for (const auto& d : st().desktops) {
            if (d.id == id)
                return d.layer.lock();
        }
        return nullptr;
    }

    void attach(const PHLLS& ls) {
        auto& s = st();
        std::erase_if(s.desktops, [](const SDesktopLayer& d) { return !d.layer; }); // gone surfaces
        if (!ls || ls->m_namespace != df::kDesktopNamespace)
            return;
        if (std::ranges::any_of(s.desktops, [&ls](const SDesktopLayer& d) { return d.layer.lock() == ls; }))
            return;
        const auto resource = ls->m_layerSurface.lock();
        if (!resource)
            return;
        // The listener holds the layer's id only and finds its entry by it (layerOf). A closure holding a weak pointer of the
        // layer released that copy at the end of the listen() statement while `ls` was still used below:
        // clang-analyzer-cplusplus.NewDelete (clang-tidy 23, rc7 Q1) followed the release into a use after free. It was none
        // (`ls`, the event's shared pointer, keeps the layer alive for the whole call), but a closure without a counted
        // pointer leaves nothing to follow. Two entries never share an id: gone layers are dropped above, before this one.
        const uint64_t id = idOf(ls);
        SDesktopLayer  d;
        d.layer  = ls;
        d.id     = id;
        d.commit = resource->m_events.commit.listen([id] { gf::guarded("desktop-focus commit", [id] { onDesktopCommit(layerOf(id)); }); });
        s.desktops.push_back(std::move(d));
        gf::logRequest(Log::INFO, "desktop-focus: desktop surface {:x} on {} tracked", id, monitorName(ls));
    }

    void detach(const PHLLS& ls) {
        auto& s = st();
        if (!ls)
            return;
        const uint64_t id = idOf(ls);
        if (s.pending.surface() == id)
            s.pending.cancel();
        std::erase_if(s.desktops, [id](const SDesktopLayer& d) { return !d.layer || d.id == id; });
    }
} // namespace

namespace gf::desktopFocus {

    bool start() {
        auto& bus = Event::bus();
        if (!bus || !g_pSeatManager || !g_pInputManager || !Desktop::layerState())
            return false;
        auto& ev = bus->m_events;
        auto& l  = st().listeners;
        // Observed, never cancelled (FR13).
        // A press on a shared edge's handle is the tiling's drag (cancelled by the plugin's first listener, tiling.md TL30):
        // the desktop under the margin is not the target.
        l.push_back(ev.input.mouse.button.listen([](IPointer::SButtonEvent e, Event::SCallbackInfo& /*info*/) {
            gf::guarded("desktop-focus press", [&] {
                if (!gf::tiler::edgeOwnsPointer())
                    onPress(e);
            });
        }));
        l.push_back(ev.layer.opened.listen([](const PHLLS& ls) { gf::guarded("desktop-focus layer.opened", [&] { attach(ls); }); }));
        l.push_back(ev.layer.closed.listen([](const PHLLS& ls) { gf::guarded("desktop-focus layer.closed", [&] { detach(ls); }); }));
        // Any other path that moves the keyboard drops a waiting desktop grant (key bindings and dispatches, activation
        // requests, a new window, a workspace switch, Hyprland's refocus after a close). The plugin's own grants run after
        // the grant was consumed (or cancelled by the press), so they find nothing waiting.
        l.push_back(ev.input.keyboard.focus.listen([](const SP<CWLSurfaceResource>& surface) {
            gf::guarded("desktop-focus keyboard.focus", [&] {
                onFocusEvent(df::FocusEvent::KeyboardFocus, keyboardLayerId(surface));
                if (st().unlock.armed(df::Clock::now()))
                    scheduleUnlockRefocus(); // the lock surface let go of the keyboard, or something else took it
            });
        }));
        // After an unlock Hyprland refocuses at the cursor only (CSessionLockManager): with the pointer off the windows the
        // keyboard stays on no surface. Tried from the event loop, after Hyprland's own handling (precedent: Stages).
        if (g_pSessionLockManager)
            l.push_back(g_pSessionLockManager->m_events.unlock.listen([] {
                gf::guarded("desktop-focus unlock", [] {
                    st().unlock.arm(df::Clock::now());
                    scheduleUnlockRefocus();
                });
            }));
        l.push_back(ev.window.active.listen([](const PHLWINDOW& /*w*/, Desktop::eFocusReason /*reason*/) {
            gf::guarded("desktop-focus window.active", [] { onFocusEvent(df::FocusEvent::WindowActivated, std::nullopt); });
        }));
        l.push_back(ev.window.open.listen([](const PHLWINDOW& /*w*/) { gf::guarded("desktop-focus window.open", [] { onFocusEvent(df::FocusEvent::WindowOpened, std::nullopt); }); }));
        l.push_back(ev.workspace.active.listen([](const PHLWORKSPACE& /*ws*/) {
            gf::guarded("desktop-focus workspace.active", [] { onFocusEvent(df::FocusEvent::WorkspaceChanged, std::nullopt); });
        }));
        for (const auto& ls : Desktop::layerState()->layers()) {
            if (ls && ls->m_mapped)
                attach(ls);
        }
        st().unlockAttempt.clear(); // a start after a previous stop (which cancelled it)
        st().ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.ready = false;
        s.pending.cancel();
        s.unlock.cancel();
        s.unlockAttempt.cancel(); // its callback is code of this library
        if (s.unlockRetry) {      // so is the timer's
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.unlockRetry);
            s.unlockRetry.reset();
        }
        s.listeners.clear();
        s.desktops.clear(); // drops the commit listeners (their callbacks are code of this library)
    }

    bool ready() {
        return st().ready;
    }

} // namespace gf::desktopFocus
