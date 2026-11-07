#include "Titlebar.hpp"

#include "ClientChrome.hpp"
#include "DeferredFocus.hpp"
#include "Ipc.hpp"
#include "Plugin.hpp"
#include "Stages.hpp"
#include "Tiling.hpp"
#include "TopClamp.hpp"
#include "core/ClientChrome.hpp"
#include "core/Minimize.hpp"
#include "core/PointerGesture.hpp"
#include "core/Protocol.hpp"
#include "core/Theme.hpp"
#include "core/Tiling.hpp"

#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/ViewHitTester.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/protocols/core/DataDevice.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <drm_fourcc.h>
#include <linux/input-event-codes.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <format>
#include <functional>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace tb    = gf::titlebar;
namespace theme = gf::theme;

namespace {
    // Higher priority = evaluated first by the positioner = closer to the window. Above the border's
    // priority so the border (and its rounded corners) wraps titlebar + content as one window.
    // Measured in S2: at 10000 the bar was placed outside the border.
    constexpr uint32_t DECORATION_PRIORITY = 10005;

    // The single pointer gesture started on a titlebar (there is one seat pointer). Its lifetime and
    // the ownership of pressed buttons are decided by the press tracker (core/PointerGesture.*).
    struct SPointerGrab {
        CGrassfieldTitlebar*      deco = nullptr; // checked against state().titlebars before use
        std::optional<tb::Button> button;         // pressed button, activated on release over the same button
        bool                      dragging = false;
        bool                      moved    = false; // the pointer passed kDragThreshold: the window follows it
        bool                      unzoom   = false; // pressed on a maximized window: un-zoom it when the move starts
        CBox                      zoomedSurface;    // surface box of that maximized window at the press
        bool                      untile   = false; // pressed on a tiled window: its size from before comes back when the move starts
        PHLWINDOWREF              window;   // window being moved (its tiling preview: gf::tiler::previewOf)
        Vector2D                  pressPos; // pointer at press (global logical)
        CBox                      startBox; // window layout box at press
        CBox                      pressBox; // the same, never changed by an un-zoom or un-tile (a drop on the Stages strip gives it back)
        bool                      plainPress = false; // pressed on a window that was neither zoomed nor tiled
        bool                      unmovable  = false; // the window closed or unmapped during the drag (logged once, gate C1)
        bool                      member     = false; // a Split View member (TL33, step 6b): swapped or back in its half at the end
        bool                      revealed   = false; // that member's drag started on its revealed bar (step 6e, D75): its press and
                                                      // release are cancelled on the bus (revealPresses), not tracked by `presses`
        double                    barOffset  = 0.0;   // the revealed bar's top relative to the surface's top once it moves (above it)
        std::vector<WP<IPointer>> devices;  // pointer devices present at the press
    };

    struct SPointerInput {
        SPointerGrab                      grab;
        gf::input::CPointerGestureTracker presses;
        CGrassfieldTitlebar*              hovered = nullptr; // lights under the pointer (glyphs); checked with isLive
        PHLWINDOWREF                      activeWindow;      // last window reported active (its lights are coloured)
        gf::chrome::CRevealPresses        revealPresses;     // presses on a revealed full-screen titlebar (P6)
        gf::chrome::CHeldButtons          heldButtons;       // the buttons Hyprland holds, as the bus shows them (P6)
        CGrassfieldTitlebar*              revealArmed = nullptr; // its light pressed, activated on release over it
        std::optional<tb::Button>         revealLight;
        gf::tiling::CHoverDwell           zoomHover; // TL22: the zoom light under the pointer, a hover after tiling.hoverDelay
        SP<CEventLoopTimer>               zoomTimer; // posts the hover once the delay passed (code of this library: removed at unload)
    };

    bool sessionLocked() {
        return !g_pSessionLockManager || g_pSessionLockManager->isSessionLocked(); // undecidable: locked (failures stay locked)
    }

    // The shell's menu bar (a layer of that namespace on the monitor): a revealed full-screen titlebar starts below it.
    constexpr std::string_view kMenubarNamespace = "grassfield-menubar";
    constexpr double           kMaxMenubarInset  = 64.0; // a larger layer of that name is not a menu bar: the bar stays at the top

    double menubarInset(const PHLMONITOR& mon) {
        if (!mon)
            return 0.0;
        for (const auto& level : mon->m_layerSurfaceLayers) {
            for (const auto& ref : level) {
                const auto ls = ref.lock();
                if (ls && ls->m_mapped && ls->m_namespace == kMenubarNamespace)
                    return ls->m_geometry.h > 0.0 && ls->m_geometry.h <= kMaxMenubarInset ? ls->m_geometry.h : 0.0;
            }
        }
        return 0.0;
    }

    // A surface drawn over a revealed full-screen titlebar takes its own presses: a layer popup (the menu bar's menus) or
    // an Overlay layer (a dialog, the menu bar itself), as Hyprland orders pointer focus (CInputManager::mouseMoveUnified).
    bool overlaySurfaceAt(const Vector2D& pos, const PHLMONITOR& mon) {
        if (!mon || !Desktop::viewState())
            return false;
        Vector2D local;
        PHLLS    layer;
        if (Desktop::viewState()->hitTest().layerPopupSurfaceAt(pos, mon, &local, &layer))
            return true;
        return Desktop::viewState()->hitTest().layerSurfaceAt(pos, &mon->m_layerSurfaceLayers[ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY], &local, &layer) != nullptr;
    }

    // Constructed on first use, inside a guarded call, so a throwing constructor cannot escape (R13).
    SPointerInput& pointerInput() {
        static SPointerInput input;
        return input;
    }

    // ADR-0036 D65: the outputs the shell was last told have a revealed full-screen titlebar (its menu bar comes and goes
    // with it there). Posted on each change, from the decorations' own state.
    std::set<std::string>& postedReveals() {
        static std::set<std::string> outputs;
        return outputs;
    }

    void postReveals() {
        std::set<std::string> now;
        for (auto* deco : gf::state().titlebars) {
            const auto w   = deco->revealed() ? deco->window() : nullptr;
            const auto mon = w ? w->m_monitor.lock() : nullptr;
            if (mon)
                now.insert(mon->m_name);
        }
        auto&      last = postedReveals();
        const auto post = [](const std::string& output, bool revealed) {
            gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::TitlebarReveal, .id = std::hash<std::string>{}(output)},
                               gf::gfc::titlebarRevealJson(output, revealed));
        };
        for (const auto& output : last) {
            if (!now.contains(output))
                post(output, false);
        }
        for (const auto& output : now) {
            if (!last.contains(output))
                post(output, true);
        }
        last = std::move(now);
    }

    bool isLive(const CGrassfieldTitlebar* deco) {
        const auto& all = gf::state().titlebars;
        return deco && std::ranges::find(all, deco) != all.end();
    }

    CHyprColor toColor(const theme::Rgba& c, float alpha = 1.F) {
        return CHyprColor{c.r, c.g, c.b, c.a * alpha};
    }

    void addRect(const CBox& box, const CHyprColor& color, int round, float roundingPower, const CBox& clip = {}) {
        CRectPassElement::SRectData data;
        data.box           = box;
        data.color         = color;
        data.round         = round;
        data.roundingPower = roundingPower;
        data.clipBox       = clip;
        g_pHyprRenderer->addPassElement(makeUnique<CRectPassElement>(data));
    }

    // A rect over Hyprland's blur of what is already drawn behind it (live blur, not xray: the windows behind count), under
    // `tint`: the blurred material (owner decision D-8). Hyprland's own path (CRectPassElement with blur, as its group bars
    // and other decorations use it); with Hyprland's blur disabled in the config it is drawn as the plain tint.
    void addBlurredRect(const CBox& box, const CHyprColor& tint, int round, float roundingPower, float blurAlpha) {
        CRectPassElement::SRectData data;
        data.box           = box;
        data.color         = tint;
        data.round         = round;
        data.roundingPower = roundingPower;
        data.blur          = true;
        data.xray          = false;
        data.blurA         = blurAlpha;
        g_pHyprRenderer->addPassElement(makeUnique<CRectPassElement>(data));
    }

    const char* hitName(tb::HitTarget hit) {
        switch (hit) {
            case tb::HitTarget::None: return "none";
            case tb::HitTarget::Close: return "close";
            case tb::HitTarget::Minimize: return "minimize";
            case tb::HitTarget::Zoom: return "zoom";
            case tb::HitTarget::DragArea: return "drag-area";
        }
        return "?";
    }

    void logIfFailed(std::string_view action, const Config::Actions::ActionResult& result) {
        if (!result)
            gf::logRequest(Log::WARN, "titlebar {} failed: {}", action, result.error().message);
    }

    // The minimize path, shared by the minimize button and a double-click set to "minimize": the shell owns
    // the Dock tile rectangle, so it is asked to minimize (it answers with hl.plugin.grassfield.minimize, or
    // parks the window on special:minimized itself when the plugin lacks the feature). Clicks can come from a
    // virtual pointer at any rate: the request is coalesced per window (spec FR24). A member of a Split View Desktop is not
    // minimized: its minimize light is grey, as in full screen (macOS; ADR-0036 D56).
    void requestMinimize(const PHLWINDOW& w) {
        if (gf::tiler::inSplit(w)) {
            gf::logRequest(Log::DEBUG, "titlebar minimize: refused for a Split View member (D56)");
            return;
        }
        gf::ipc::postMinimizeRequest(reinterpret_cast<uintptr_t>(w.get()));
    }

    // The one zoom toggle, shared by the zoom button (without Alt) and the double-click on the drag area (Zoom or Fill).
    // Zoom is Fill (ADR-0036 D78, gf::tiler::zoom): the window fills the work area as a tile, with the margins, and a second
    // zoom brings back its box from before; Hyprland's maximized mode without window-tiling (gate C2). A window of fixed
    // size is not zoomed (its zoom light is disabled, core lightAvailable; ADR-0040 step 1b's review); a zoomed one still
    // unzooms.
    void toggleZoom(const PHLWINDOW& w) {
        if (gf::tiler::zoom(w, true) == gf::tiling::ZoomStep::Refused && gf::tiler::fixedSize(w))
            gf::logRequest(Log::DEBUG, "titlebar zoom: refused for a window of fixed size");
    }

    // Out of Hyprland's maximized mode only (a drag that starts on a zoomed window), never into Fill.
    void leaveMaximized(const PHLWINDOW& w) {
        auto& fs = Fullscreen::controller();
        if (fs && fs->getFullscreenModes(w).internal == Fullscreen::FSMODE_MAXIMIZED)
            fs->setFullscreenMode(w, Fullscreen::FSMODE_NONE, Fullscreen::FSMODE_NONE, false);
    }

    Fullscreen::eFullscreenMode fullscreenMode(const PHLWINDOW& w) {
        const auto& fs = Fullscreen::controller();
        return fs ? fs->getFullscreenModes(w).internal : Fullscreen::FSMODE_NONE;
    }

    // Alt (Option) held on any keyboard.
    bool altHeld() {
        return g_pInputManager && (g_pInputManager->getModsFromAllKBs() & HL_MODIFIER_ALT) != 0;
    }

    // The zoom light (ADR-0015 P6, REQ-ADR0002-6): zoom (maximized) and back; with Alt held, true full screen (the shell
    // hides the menu bar as in any full screen); a window in full screen leaves it.
    void zoomLight(const PHLWINDOW& w) {
        // A window of a Split View Desktop leaves it, with or without Alt (macOS: its green button exits full screen; tiling.md
        // TL33, ADR-0036 D49): back on its Desktop as an ordinary window, the other filling the Split View Desktop.
        if (gf::tiler::leaveSplit(w)) {
            gf::logRequest(Log::DEBUG, "titlebar zoom of a Split View window -> back to its Desktop");
            return;
        }
        auto& fs = Fullscreen::controller();
        if (!fs)
            return;
        const auto mode = fullscreenMode(w);
        // A window of fixed size: the light is drawn disabled and its click does nothing, Alt included (macOS; ADR-0040 step
        // 1b's review), unless the window is zoomed or in full screen already: then it brings it back.
        if (!gf::chrome::lightAvailable(tb::Button::Zoom, false, gf::tiler::fixedSize(w), mode != Fullscreen::FSMODE_NONE)) {
            gf::logRequest(Log::DEBUG, "titlebar zoom: refused for a window of fixed size");
            return;
        }
        switch (gf::chrome::zoomAction(mode == Fullscreen::FSMODE_MAXIMIZED, mode == Fullscreen::FSMODE_FULLSCREEN, altHeld())) {
            case gf::chrome::ZoomAction::EnterFullscreen:
                gf::logRequest(Log::DEBUG, "titlebar zoom with Alt -> full screen");
                fs->setFullscreenMode(w, Fullscreen::FSMODE_FULLSCREEN, Fullscreen::FSMODE_FULLSCREEN, false);
                break;
            case gf::chrome::ZoomAction::LeaveFullscreen: fs->setFullscreenMode(w, Fullscreen::FSMODE_NONE, Fullscreen::FSMODE_NONE, false); break;
            case gf::chrome::ZoomAction::Zoom:
            case gf::chrome::ZoomAction::Unzoom: toggleZoom(w); break;
        }
    }

    // A move that starts on a maximized window: leave the maximized mode first (the layout gives the window
    // back its floating size), then place that size under the pointer (macOS). Moving the maximized box
    // itself would write it into the floating geometry the zoom toggle restores (FR8 regression, 2026-10-17).
    // Measured in 0.56.2: a floating window's layout box is its surface box, a maximized one's is the work
    // area (decorations included), hence the surface box recorded at the press as the reference.
    void unzoomUnderPointer(SPointerGrab& grab, const PHLWINDOW& w, const SP<Layout::ITarget>& target, const Vector2D& pointer) {
        gf::tiler::leave(w); // a tile kept while zoomed (tiling.md TL12) ends: the window leaves under the pointer
        leaveMaximized(w);
        const CBox  restored = target->position();
        const CBox& zoomed   = grab.zoomedSurface;
        const auto  box      = tb::unzoomedDragBox(tb::Rect{zoomed.x, zoomed.y, zoomed.w, zoomed.h}, restored.w, restored.h, grab.pressPos.x, grab.pressPos.y, pointer.x, pointer.y);
        gf::logRequest(Log::DEBUG, "titlebar drag un-zooms: restored {:.0f}x{:.0f} at {:.0f},{:.0f}", box.w, box.h, box.x, box.y);
        grab.startBox = CBox{box.x, box.y, box.w, box.h};
        grab.pressPos = pointer;
        grab.unzoom   = false;
    }

    // A move that starts on a tiled window gives it back its size from before tiling, under the pointer at the same
    // relative place on the titlebar (macOS), like the un-zoom above. Its tile record is Moving until the release
    // (docs/specs/tiling.md TL10): a release in a drag zone tiles it again with the same box from before, elsewhere it is Free.
    void untileUnderPointer(SPointerGrab& grab, const PHLWINDOW& w, const SP<Layout::ITarget>& target, const Vector2D& pointer) {
        grab.untile        = false;
        const auto before = gf::tiler::beginMove(w);
        if (!before)
            return;
        const CBox tiled = target->position();
        const auto box   = tb::unzoomedDragBox(tb::Rect{tiled.x, tiled.y, tiled.w, tiled.h}, before->w, before->h, grab.pressPos.x, grab.pressPos.y, pointer.x, pointer.y);
        gf::logRequest(Log::DEBUG, "titlebar drag leaves the tile: {:.0f}x{:.0f} at {:.0f},{:.0f}", box.w, box.h, box.x, box.y);
        grab.startBox = CBox{box.x, box.y, box.w, box.h};
        grab.pressPos = pointer;
    }

    // Hyprland's general:snap:enabled, read at each step (a configuration reload may change it).
    bool snapEnabled() {
        const CConfigValue<Config::INTEGER> enabled("general:snap:enabled");
        return enabled.good() && *enabled != 0;
    }

    // Hyprland's misc:animate_mouse_windowdragging (false in the session, config/hypr/grassfield/looknfeel.lua), read at each
    // step: whether a window dragged with the pointer moves through the windowsMove animation or sits under the pointer at once.
    // Bound once (Hyprland's own idiom: the value follows reloads through CConfigValueBase's registry, and its destructor, run
    // when this library is unloaded, takes it out of the registry), so a drag step does no lookup by name.
    bool animateWindowDragging() {
        static const CConfigValue<Config::INTEGER> animate("misc:animate_mouse_windowdragging");
        return animate.good() && *animate != 0;
    }

    // Interactive move driven by the plugin: the window follows the pointer from the press point.
    // S2 history: with CLayoutManager::beginDragTarget and CKeybindManager::changeMouseBindMode the window
    // jumped by (window middle - press point). The cause was most likely Config::Actions::focus() warping
    // the cursor to the window middle before the drag started (found afterwards, now avoided in
    // focusAndRaise). Away from a tiling place the window snaps as in Hyprland's own move (tiling.md TL19).
    // Nothing moves until the pointer has passed kDragThreshold: a click (or the first click of a
    // double-click) never writes the window geometry.
    void updateMove(SPointerGrab& grab) {
        const auto w = grab.window.lock();
        if (!w || !g_layoutManager || !g_pInputManager)
            return;
        const auto target = w->layoutTarget();
        if (!target || !gf::tiler::movable(w)) {
            // Closed or unmapped during the drag: no Desktop, no layout space (gate C1). The line is what tiling.sh's C1 cases
            // look for: the risky state was reached and nothing was moved.
            if (!std::exchange(grab.unmovable, true))
                gf::logRequest(Log::INFO, "titlebar drag: window {:x} closed or unmapped during the drag: not moved (gate C1)",
                               reinterpret_cast<uintptr_t>(w.get()));
            return;
        }
        const Vector2D pointer = g_pInputManager->getMouseCoordsInternal();
        if (!grab.moved && !tb::exceedsDragThreshold(pointer.x - grab.pressPos.x, pointer.y - grab.pressPos.y))
            return;
        grab.moved = true;
        if (grab.unzoom)
            unzoomUnderPointer(grab, w, target, pointer);
        else if (grab.untile)
            untileUnderPointer(grab, w, target, pointer);
        CBox box = grab.startBox;
        box.translate(pointer - grab.pressPos);
        // TL19: away from a tiling place the window snaps to the outputs' edges and to the other windows as Hyprland's own
        // move does (the public CLayoutManager::performSnap with the general:snap values), so every drag behaves alike. A Split
        // View member does not snap: it lands in a half at the release.
        if (!grab.member && !gf::tiler::snapFor(w, pointer) && snapEnabled()) {
            Vector2D pos  = box.pos();
            Vector2D size = box.size();
            g_layoutManager->performSnap(pos, size, target, MBIND_MOVE, -1, grab.startBox.size());
            box = CBox{pos.round(), size};
        }
        // The titlebar stops at the menu bar while the pointer goes on, and follows it again on the way down (macOS). A Split
        // View member is not held there: its half starts at the output's top edge, under the menu bar (no band, D73), and it
        // never goes above where it was (step 6e, D75).
        if (grab.member)
            box.y = std::max(box.y, grab.startBox.y);
        else
            box = gf::topClamp::heldMove(w, box, pointer);
        g_layoutManager->setTargetGeom(box, target);
        // Under the pointer at once, as Hyprland's own move with animate_mouse_windowdragging off (the step of its drag:
        // setTargetGeom, warpPositionSize; the shared edge's drag does the same). Owner report on 1.0.0-rc6 ("the gesture up to
        // fill the screen is very slow"): each motion restarted the 300 ms windowsMove animation, so the window trailed the
        // pointer on its way to the menu bar (nested capture: still mid-way 100 ms after a jump of the pointer). The release's
        // tile is set after this step and keeps its animation.
        if (!animateWindowDragging())
            target->warpPositionSize();
        if (!grab.member) // a Split View member shows no tiling place: it lands in a half (TL33, step 6b)
            gf::tiler::dragMotion(w, pointer); // the place under the pointer, shown after the preview delay (TL17)
    }

    std::vector<WP<IPointer>> pointerDevices() {
        std::vector<WP<IPointer>> devices;
        if (g_pInputManager) {
            for (const auto& device : g_pInputManager->m_pointers)
                devices.emplace_back(device);
        }
        return devices;
    }

    // Every pointer device present at the press still exists. Hyprland 0.56.2 does not release the
    // buttons of a pointer device that goes away (CInputManager::destroyPointer), so a vanished device
    // means the gesture's release may never arrive.
    bool devicesIntact(const std::vector<WP<IPointer>>& devices) {
        if (!g_pInputManager)
            return false;
        const auto& present = g_pInputManager->m_pointers;
        return std::ranges::all_of(devices, [&present](const WP<IPointer>& device) {
            const auto alive = device.lock();
            return alive && std::ranges::find(present, alive) != present.end();
        });
    }

    // Focus without Config::Actions::focus(): that action warps the cursor to the window middle when the
    // pointer is outside the client surface (measured in S2), which breaks clicks and drags on the bar.
    // Whether the window holds the keyboard decides, not whether Hyprland counts it active: after a session
    // unlock with the pointer off the windows, Hyprland still counts its last window active while the keyboard
    // is on no surface (tests/compositor/click_focus.sh).
    void focusAndRaise(const PHLWINDOW& w) {
        if (!gf::deferredFocus::windowHoldsKeyboard(w))
            gf::deferredFocus::focusWindow(w, Desktop::FOCUS_REASON_CLICK);
        logIfFailed("raise", Config::Actions::alterZOrder("top", w));
    }

    // A window drawn where it is, taking input: no overview or Stages transform, no input block. Only such a window
    // shows hover glyphs (a transformed window is drawn away from where the pointer hovers its real lights).
    bool drawnInPlace(const PHLWINDOW& w) {
        return w && w->m_transformers.empty() && !w->isInputBlocked();
    }

    // The titlebar whose lights are under the pointer, on the topmost window there. Plain geometry over Hyprland's window
    // list, walked from the top (the stacking order `hyprctl clients` reports): the first mapped window on a visible
    // workspace whose surface or titlebar contains the pointer decides. Hyprland's hit tester is not used here: calling
    // CViewHitTester::windowAt from this motion listener cost Qt and GTK4 windows their keyboard enter on a titlebar click
    // (tests/compositor/click_focus.sh clients, 2026-10-22: 13/15 with it, 15/15 without).
    CGrassfieldTitlebar* titlebarHoveredAt(const Vector2D& pos) {
        const auto& all = gf::state().titlebars;
        if (all.empty() || !Desktop::windowState())
            return nullptr;
        // A revealed full-screen titlebar is drawn over every window (P6).
        for (auto* deco : all) {
            if (deco->revealed() && deco->barContains(pos))
                return deco->buttonGroupContains(pos) ? deco : nullptr;
        }
        const auto& windows = Desktop::windowState()->windows();
        for (auto it = windows.rbegin(); it != windows.rend(); ++it) {
            const auto& w = *it;
            if (!w || !w->m_isMapped || w->isHidden() || !w->m_workspace || !w->m_workspace->isVisible())
                continue;
            const auto deco  = std::ranges::find_if(all, [&w](const CGrassfieldTitlebar* d) { return d->window() == w; });
            const bool onBar = deco != all.end() && (*deco)->barContains(pos);
            if (!onBar && !w->getWindowMainSurfaceBox().containsPoint(pos))
                continue; // not under the pointer: a window further down may be
            return onBar && drawnInPlace(w) && (*deco)->buttonGroupContains(pos) ? *deco : nullptr;
        }
        return nullptr;
    }

    uint64_t nowMs() {
        return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    }

    uint64_t addressOf(const PHLWINDOW& w) {
        return reinterpret_cast<uintptr_t>(w.get());
    }

    // The topmost window under `pos` whose zoom light contains it (TL22, TL24), and that light. The windows are walked as
    // titlebarHoveredAt walks them (geometry only, from the top); a revealed full-screen bar is over every window. A window of
    // fixed size (gf::tiler::fixedSize) is under the pointer, but none of its lights opens the tiling popover: nothing in it
    // can be tiled, and its zoom light is disabled, drawn so by a Grassfield app and by the plugin's titlebar alike (core
    // lightAvailable; ADR-0040 step 1b: About This Computer's grey zoom light opened the popover, the nested pass of 85c2c10).
    std::optional<std::pair<PHLWINDOW, CBox>> zoomLightAt(const Vector2D& pos) {
        const auto  inLight = [&pos](const CBox& light) {
            CBox hit = light;
            hit.expand(theme::kButtonHitSlop); // the click's own slop (core hitTest)
            return hit.containsPoint(pos);
        };
        for (auto* deco : gf::state().titlebars) {
            if (deco->revealed() && deco->barContains(pos)) {
                const auto w     = deco->window();
                const auto light = w && !gf::tiler::fixedSize(w) ? CGrassfieldTitlebar::zoomLightOf(w) : std::nullopt;
                return light && inLight(*light) ? std::optional{std::pair{w, *light}} : std::nullopt;
            }
        }
        if (!Desktop::windowState())
            return std::nullopt;
        const auto& windows = Desktop::windowState()->windows();
        for (auto it = windows.rbegin(); it != windows.rend(); ++it) {
            const auto& w = *it;
            if (!w || !w->m_isMapped || w->isHidden() || !w->m_workspace || !w->m_workspace->isVisible())
                continue;
            const auto& all   = gf::state().titlebars;
            const auto  deco  = std::ranges::find_if(all, [&w](const CGrassfieldTitlebar* d) { return d->window() == w; });
            const bool  onBar = deco != all.end() && (*deco)->barContains(pos);
            if (!onBar && !w->getWindowMainSurfaceBox().containsPoint(pos))
                continue; // not under the pointer: a window further down may be
            const auto light = drawnInPlace(w) && !gf::tiler::fixedSize(w) ? CGrassfieldTitlebar::zoomLightOf(w) : std::nullopt;
            return light && inLight(*light) ? std::optional{std::pair{w, *light}} : std::nullopt;
        }
        return std::nullopt;
    }

    // Posts what the hover tracker decided (event channel TileHover: the latest state wins).
    void postHover(const gf::tiling::HoverChange& change, const PHLWINDOW& w, const CBox& light) {
        const gf::events::Key key{.channel = gf::events::Channel::TileHover, .id = 0};
        if (change.leave)
            gf::ipc::postEvent(key, gf::tiling::tileHoverJson(*change.leave, gf::tiling::HoverState::Leave));
        if (change.enter && w && gf::state().tilingLayouts) // off (TL32): Super+Ctrl+L and the Window menu still open it
            gf::ipc::postEvent(key, gf::tiling::tileHoverJson(*change.enter, gf::tiling::HoverState::Enter, gf::tiling::Rect{light.x, light.y, light.w, light.h},
                                                              gf::tiler::tileable(w), gf::tiler::splittable(w), gf::tiler::unfitZones(w), gf::tiler::unfitPlaces(w)));
    }

    void armZoomTimer(uint64_t ms);

    // A Top or Overlay layer surface, or a layer popup, is under `pos`: Hyprland's own pointer order puts it above every
    // window (CInputManager::mouseMoveUnified, as DesktopFocus's underCursor reads it), so a light there is covered.
    bool layerUnderPointer(const Vector2D& pos) {
        if (!Desktop::viewState() || !State::monitorState())
            return false;
        const auto mon = State::monitorState()->query().vec(pos).run();
        if (!mon)
            return false;
        Vector2D   local;
        PHLLS      layer;
        const auto tester = Desktop::viewState()->hitTest();
        if (tester.layerPopupSurfaceAt(pos, mon, &local, &layer))
            return true;
        for (const auto level : {ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_LAYER_SHELL_V1_LAYER_TOP}) {
            if (tester.layerSurfaceAt(pos, &mon->m_layerSurfaceLayers[level], &local, &layer))
                return true;
        }
        return false;
    }

    // TL22, TL34 (integrator review of 4ead6fb): nothing of the hover over the lock, under a foreign Exclusive layer or under a
    // layer (core hoverCoverEffect). Read only: Hyprland's lists are never changed.
    gf::tiling::HoverCoverEffect zoomLightsCover(const Vector2D& pos) {
        gf::tiling::HoverCover cover{.locked = gf::deferredFocus::sessionLocked(), .exclusiveNamespaces = {}, .layerUnderPointer = false};
        if (g_pInputManager) {
            for (const auto& ref : g_pInputManager->m_exclusiveLSes) {
                const auto ls = ref.lock();
                if (ls && ls->m_mapped)
                    cover.exclusiveNamespaces.push_back(ls->m_namespace);
            }
        }
        if (gf::tiling::hoverCoverEffect(cover) == gf::tiling::HoverCoverEffect::None)
            cover.layerUnderPointer = layerUnderPointer(pos); // the hit test only when nothing else covers the lights
        return gf::tiling::hoverCoverEffect(cover);
    }

    // TL22: the zoom light under the pointer now (pointer motion, the hover delay's timer, the unlock). No button may be held:
    // a press ends the hover until the pointer leaves the light (CHoverDwell::press). Covered lights (D24): the lock or a
    // foreign Exclusive layer ends the hover and forgets the light, so the hover starts over once the desktop is back; a layer
    // over the light counts as a press, so a popover the user closed over the light does not come back by itself, and the
    // popover's own layer never hands the hover to a light under it.
    void updateZoomHover() {
        auto& input = pointerInput();
        if (!g_pInputManager)
            return;
        const Vector2D pos     = g_pInputManager->getMouseCoordsInternal();
        const auto     now     = nowMs();
        const auto     covered = zoomLightsCover(pos);
        if (covered != gf::tiling::HoverCoverEffect::None) {
            postHover(covered == gf::tiling::HoverCoverEffect::Away ? input.zoomHover.update(std::nullopt, now) : input.zoomHover.press(), nullptr, CBox{});
            if (input.zoomTimer)
                input.zoomTimer->updateTimeout(std::nullopt);
            return;
        }
        const auto at     = g_pInputManager->hasHeldButtons() ? std::nullopt : zoomLightAt(pos);
        const auto w      = at ? at->first : nullptr;
        const auto change = input.zoomHover.update(w ? std::optional{addressOf(w)} : std::nullopt, now);
        postHover(change, w, at ? at->second : CBox{});
        if (const auto wait = input.zoomHover.remaining(now))
            armZoomTimer(*wait);
    }

    void armZoomTimer(uint64_t ms) {
        auto& input = pointerInput();
        if (!g_pEventLoopManager)
            return;
        if (!input.zoomTimer) {
            input.zoomTimer = makeShared<CEventLoopTimer>(
                std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { gf::guarded("titlebar zoom hover", [] { updateZoomHover(); }); }, nullptr);
            g_pEventLoopManager->addTimer(input.zoomTimer);
        }
        input.zoomTimer->updateTimeout(std::chrono::milliseconds(ms));
    }

    // Pointer motion: the glyphs follow the pointer onto and off the lights. Only the titlebars that change are damaged.
    void updateHover() {
        auto& input = pointerInput();
        auto* now   = g_pInputManager ? titlebarHoveredAt(g_pInputManager->getMouseCoordsInternal()) : nullptr;
        auto* was   = input.hovered;
        if (now == was)
            return;
        input.hovered = now;
        if (isLive(was))
            was->damageEntire();
        if (now)
            now->damageEntire();
    }
} // namespace

CGrassfieldTitlebar::CGrassfieldTitlebar(const PHLWINDOW& window) : IHyprWindowDecoration(window), m_owner(window) {
    gf::state().titlebars.push_back(this);
    m_lastShown = shouldShow();
}

CGrassfieldTitlebar::~CGrassfieldTitlebar() {
    std::erase(gf::state().titlebars, this);
    gf::forgetRegisteredDecoration(this);
    gf::guarded("titlebar destructor", [this] {
        auto& input = pointerInput();
        if (m_revealed)
            postReveals(); // closed while revealed: its output's menu bar no longer follows it
        if (input.hovered == this)
            input.hovered = nullptr;
        if (input.revealArmed == this) {
            input.revealArmed = nullptr;
            input.revealLight.reset();
        }
        if (input.grab.deco == this) {
            // The window is going away: drop the gesture (and redraw where its tiling preview was). The press ownership
            // stays, so the release that will still arrive is not mistaken for a client's (another titlebar under the
            // pointer consumes it; elsewhere the seat drops it, as the client never saw the press).
            if (input.grab.dragging)
                gf::tiler::dragDone();
            if (input.grab.member)
                gf::tiler::memberDragForget(); // reconcile checks its record again (integrator PASS on 12e3dd3, NIT)
            input.grab = {};
            input.presses.dropGesture();
        }
    });
}

PHLWINDOW CGrassfieldTitlebar::window() const {
    return m_owner.lock();
}

bool CGrassfieldTitlebar::titlebarAllowed() const {
    const auto w = window();
    if (!w || !w->m_isMapped || w->isHidden())
        return false;
    if (w->m_isX11 && (w->isX11OverrideRedirect() || w->m_X11DoesntWantBorders))
        return false;
    if (w->m_ruleApplicator && !w->m_ruleApplicator->decorate().valueOrDefault())
        return false;
    return !gf::chrome::isClientChrome(w); // the app draws its own lights and toolbar (ADR-0015 P1)
}

bool CGrassfieldTitlebar::shouldShow() const {
    const auto w = window();
    if (!w || !w->m_isFloating || !titlebarAllowed())
        return false;
    if (const auto& fs = Fullscreen::controller(); fs && fs->getFullscreenModes(w).internal == Fullscreen::FSMODE_FULLSCREEN)
        return false; // away; the pointer at the top edge reveals it (P6, revealable)
    return !gf::tiler::inSplit(w); // a Split View member's too, whatever its state: its half's top edge reveals it (TL33, D73)
}

bool CGrassfieldTitlebar::revealable() const {
    const auto w = window();
    if (!w || !w->m_workspace || !w->m_workspace->isVisible())
        return false;
    const auto& fs = Fullscreen::controller();
    if (!fs || (fs->getFullscreenModes(w).internal != Fullscreen::FSMODE_FULLSCREEN && !gf::tiler::inSplit(w)))
        return false; // in full screen, or a Split View member (step 6e, D74)
    if (sessionLocked())
        return false; // every press is the lock screen's
    // The pointer belongs to the client (review of part B, major 2): a pointer it confines or locks (a game that scrolls at
    // the screen's edge: pushing up there and clicking the corner hit a working close light), a move or resize it started
    // (or a key binding's), a drag and drop.
    if (g_pInputManager && g_pInputManager->isConstrained())
        return false;
    if (g_layoutManager) {
        if (const auto& drag = g_layoutManager->dragController(); drag && drag->mode() != MBIND_INVALID)
            return false;
    }
    if (PROTO::data && PROTO::data->dndActive())
        return false;
    // A special workspace shown on the monitor is drawn above the full-screen window: the bar would be under its windows.
    if (const auto mon = w->m_monitor.lock(); mon && mon->m_activeSpecialWorkspace && mon->m_activeSpecialWorkspace != w->m_workspace)
        return false;
    return drawnInPlace(w) && titlebarAllowed();
}

bool CGrassfieldTitlebar::revealed() const {
    return m_revealed;
}

double CGrassfieldTitlebar::shownBarHeight(const PHLWINDOW& w) {
    if (!w)
        return 0.0;
    for (const auto* deco : gf::state().titlebars) {
        if (deco->window() != w)
            continue;
        if (!deco->shouldShow())
            return 0.0;
        const CBox bar = deco->layoutBox(); // what drawTitlebar draws: nothing until the positioner placed it
        return bar.w > 0 && bar.h > 0 ? bar.h : 0.0;
    }
    return 0.0;
}

std::optional<CBox> CGrassfieldTitlebar::zoomLightOf(const PHLWINDOW& w) {
    if (!w)
        return std::nullopt;
    const auto& all  = gf::state().titlebars;
    const auto  deco = std::ranges::find_if(all, [&w](const CGrassfieldTitlebar* d) { return d->window() == w; });
    if (deco != all.end() && (*deco)->barShown()) {
        const CBox bar   = (*deco)->barBox();
        const auto light = tb::buttonRect(tb::Button::Zoom);
        return CBox{bar.x + light.x, bar.y + light.y, light.w, light.h};
    }
    // TL24: a Grassfield app draws its lights itself at the tokens' places (ADR-0015 WindowControls), not in full screen.
    if (!gf::chrome::isClientChrome(w) || !w->m_class.starts_with("org.grassfield.") || fullscreenMode(w) == Fullscreen::FSMODE_FULLSCREEN)
        return std::nullopt;
    const auto  role    = w->xdgTag();
    const auto  light   = tb::appZoomLight(role && *role == "info");
    const CBox  surface = w->getWindowMainSurfaceBox();
    return CBox{surface.x + light.x, surface.y + light.y, light.w, light.h};
}

void CGrassfieldTitlebar::popoverRequest(std::string_view address) {
    const auto id = gf::minimize::parseAddress(address);
    if (!id || !Desktop::windowState()) {
        gf::logRequest(Log::WARN, "tile_popover: rejected: invalid window address");
        return;
    }
    PHLWINDOW w;
    for (const auto& candidate : Desktop::windowState()->windows()) {
        if (candidate && candidate->m_isMapped && addressOf(candidate) == *id)
            w = candidate;
    }
    if (!w) {
        gf::logRequest(Log::WARN, "tile_popover: no mapped window {:x}", *id);
        return;
    }
    // Its zoom light is disabled: nothing opens from it (ADR-0040 step 1b; Super+Ctrl+L included).
    if (gf::tiler::fixedSize(w)) {
        gf::logRequest(Log::INFO, "tile_popover: refused: window {:x} is of fixed size", *id);
        return;
    }
    // Without a known light: the top-left corner of the frame, where the lights of a third-party title bar usually are.
    const CBox surface = w->getWindowMainSurfaceBox();
    const double band  = gf::chrome::bandOf(w);
    const CBox light   = zoomLightOf(w).value_or(CBox{surface.x, surface.y - band, theme::kTitlebarHeight, theme::kTitlebarHeight});
    gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::TileHover, .id = 0},
                       gf::tiling::tileHoverJson(*id, gf::tiling::HoverState::Open, gf::tiling::Rect{light.x, light.y, light.w, light.h}, gf::tiler::tileable(w),
                                                 gf::tiler::splittable(w), gf::tiler::unfitZones(w), gf::tiler::unfitPlaces(w)));
}

SDecorationPositioningInfo CGrassfieldTitlebar::getPositioningInfo() {
    SDecorationPositioningInfo info;
    info.policy   = DECORATION_POSITION_STICKY;
    info.edges    = DECORATION_EDGE_TOP;
    info.priority = DECORATION_PRIORITY;
    info.reserved = true;
    gf::guarded("titlebar getPositioningInfo", [&] {
        m_lastShown         = shouldShow();
        info.desiredExtents = SBoxExtents{.topLeft = Vector2D{0.0, m_lastShown ? theme::kTitlebarHeight : 0.0}, .bottomRight = Vector2D{0.0, 0.0}};
    });
    return info;
}

void CGrassfieldTitlebar::onPositioningReply(const SDecorationPositioningReply& /*reply*/) {
    // The assigned box is read back from the positioner when needed (layoutBox()).
}

eDecorationType CGrassfieldTitlebar::getDecorationType() {
    return DECORATION_CUSTOM;
}

eDecorationLayer CGrassfieldTitlebar::getDecorationLayer() {
    // Under the window surface: the background also fills the surface's rounded top corners.
    return DECORATION_LAYER_UNDER;
}

uint64_t CGrassfieldTitlebar::getDecorationFlags() {
    return DECORATION_ALLOWS_MOUSE_INPUT | DECORATION_PART_OF_MAIN_WINDOW;
}

std::string CGrassfieldTitlebar::getDisplayName() {
    return "grassfield-titlebar";
}

void CGrassfieldTitlebar::updateWindow(PHLWINDOW /*window*/) {
    gf::guarded("titlebar updateWindow", [this] { refresh(); });
}

void CGrassfieldTitlebar::refresh() {
    const auto w = window();
    if (!w)
        return;
    if (m_revealed && !revealable()) {
        damageRevealed(); // the window left full screen (or its workspace): the revealed bar goes with it
        m_revealed = false;
        postReveals();
    }
    const bool show = shouldShow();
    if (show == m_lastShown)
        return;
    m_lastShown = show;
    if (g_pDecorationPositioner)
        g_pDecorationPositioner->repositionDeco(this);
    w->updateWindowDecos();
    if (g_pHyprRenderer)
        g_pHyprRenderer->damageWindow(w);
}

void CGrassfieldTitlebar::onTitleChanged() {
    if (m_title.text == (window() ? window()->m_title : std::string{}))
        return;
    m_title.texture.reset(); // rebuilt lazily in draw()
    damageEntire();
}

CBox CGrassfieldTitlebar::layoutBox() const {
    if (!g_pDecorationPositioner)
        return {};
    // NOLINTNEXTLINE(cppcoreguidelines-pro-type-const-cast): the positioner API is not const-correct
    return g_pDecorationPositioner->getWindowDecorationBox(const_cast<CGrassfieldTitlebar*>(this));
}

CBox CGrassfieldTitlebar::revealBox() const {
    const auto w   = window();
    const auto mon = w ? w->m_monitor.lock() : nullptr;
    if (!w || !mon)
        return {};
    const CBox surface = w->getWindowMainSurfaceBox(); // the monitor's box in full screen, its half for a Split View member
    // A member dragged by this bar (D75), once it moves: the bar above the window (the window's content below it, as any
    // window dragged by its titlebar; the review of #99: 24 px of content showed above the bar).
    if (const auto& grab = pointerInput().grab; grab.revealed && grab.moved && grab.deco == this)
        return CBox{surface.x, surface.y + grab.barOffset, surface.w, theme::kTitlebarHeight};
    return CBox{surface.x, mon->m_position.y + menubarInset(mon), surface.w, theme::kTitlebarHeight};
}

void CGrassfieldTitlebar::endRevealedDrag(std::optional<Vector2D> at) {
    auto& input = pointerInput();
    if (!input.grab.revealed)
        return;
    auto* deco = isLive(input.grab.deco) ? input.grab.deco : nullptr;
    if (deco)
        deco->damageRevealed(); // where the bar hung above the window
    SPointerGrab grab = std::exchange(input.grab, {});
    gf::tiler::memberDrop(grab.window.lock(), at);
    if (deco)
        deco->damageRevealed(); // where it is again
}

void CGrassfieldTitlebar::refreshWindow(const PHLWINDOW& w) {
    gf::guarded("titlebar refreshWindow", [&w] {
        for (auto* deco : gf::state().titlebars) {
            if (w && deco->window() == w)
                deco->refresh();
        }
    });
}

CBox CGrassfieldTitlebar::barBox() const {
    return m_revealed ? revealBox() : layoutBox();
}

bool CGrassfieldTitlebar::barShown() const {
    return m_revealed || shouldShow();
}

bool CGrassfieldTitlebar::barContains(const Vector2D& pos) const {
    return barShown() && barBox().containsPoint(pos);
}

bool CGrassfieldTitlebar::buttonGroupContains(const Vector2D& pos) const {
    if (!barShown())
        return false;
    const CBox bar = barBox();
    return tb::overButtonGroup(pos.x - bar.x, pos.y - bar.y, bar.w);
}

void CGrassfieldTitlebar::damageRevealed() {
    if (!m_revealed || !g_pHyprRenderer)
        return;
    CBox box = revealBox();
    g_pHyprRenderer->damageBox(box.expand(2));
}

void CGrassfieldTitlebar::damageEntire() {
    gf::guarded("titlebar damageEntire", [this] {
        const auto w = window();
        if (!w || !g_pHyprRenderer)
            return;
        if (m_revealed) {
            damageRevealed();
            return;
        }
        CBox box = layoutBox();
        box.translate(w->m_floatingOffset);
        g_pHyprRenderer->damageBox(box.expand(2));
    });
}

void CGrassfieldTitlebar::draw(PHLMONITOR monitor, float const& alpha) {
    gf::guarded("titlebar draw", [&] {
        drawPreview(monitor, alpha);
        drawTitlebar(monitor, alpha);
    });
}

// A drag of this window over a tiling place: the place's frame under the window and over the windows behind it (this
// decoration is drawn under the window's surface, after the windows below it), as the blurred material (owner decision D-8,
// macOS's frosted pane): its edge, then a plate of Hyprland's blur of the windows behind under the appearance's tint.
// Cheap: one blurred element, only while a drag shows a place, damage limited to the frame (gf::tiler). Drawn for a window
// whose bar is hidden too: Hyprland's move of a client-chrome window shows the same preview (tiling.md TL16).
void CGrassfieldTitlebar::drawPreview(const PHLMONITOR& monitor, float alpha) {
    const auto w = window();
    if (!w || !monitor || !g_pHyprRenderer)
        return;
    const auto snap = gf::tiler::previewOf(w);
    if (!snap || snap->monitor.lock() != monitor)
        return;
    const float  scale    = monitor->m_scale;
    const double rounding = std::max(0.0, static_cast<double>(w->rounding()));
    const float  power    = w->roundingPower();
    const auto   palette  = theme::titlebarPalette(gf::state().appearance.current);
    const int    roundPx  = tb::windowCornerPx(static_cast<float>(rounding), scale); // the window's own corner, as Hyprland cuts it
    CBox preview = snap->frame;
    preview.translate(-monitor->m_position);
    addRect(preview.scale(scale).round(), toColor(palette.previewRim, alpha), roundPx, power);
    CBox inner = snap->frame;
    inner.translate(-monitor->m_position);
    inner.expand(-theme::kTilePreviewRim);
    addBlurredRect(inner.scale(scale).round(), toColor(palette.previewTint, alpha), std::max(0, roundPx - static_cast<int>(std::round(theme::kTilePreviewRim * scale))),
                   power, alpha);
}

void CGrassfieldTitlebar::drawTitlebar(const PHLMONITOR& monitor, float alpha) {
    const auto w = window();
    if (!w || !monitor || !g_pHyprRenderer || !shouldShow())
        return;

    CBox bar = layoutBox();
    if (bar.w <= 0 || bar.h <= 0)
        return;

    // Follow the window during workspace slides and floating offsets, like Hyprland's own decorations.
    Vector2D offset = w->m_floatingOffset;
    if (w->m_workspace && !w->m_pinned)
        offset = offset + w->m_workspace->m_renderOffset->value();
    bar.translate(offset - monitor->m_position);

    const float  scale    = monitor->m_scale;
    const double rounding = std::max(0.0, static_cast<double>(w->rounding()));
    const float  power    = w->roundingPower();
    const auto   appearance = gf::state().appearance.current; // follows the shell (config "appearance", audit UX-06)
    const auto   palette    = theme::titlebarPalette(appearance);
    const auto   bgColor    = toColor(palette.background, alpha);

    // 1. The bar (a drag's tiling preview is drawn under it, drawPreview): background, lights and their glyphs, title
    //    (drawBar). The pointer is checked again here: the window may have moved or gone under a pointer that has not moved
    //    since.
    const bool hovered = pointerInput().hovered == this && g_pInputManager && drawnInPlace(w) && buttonGroupContains(g_pInputManager->getMouseCoordsInternal());
    drawBar(w, bar, scale, rounding, power, alpha, hovered, gf::tiler::inSplit(w)); // a member's lights are those of full screen (D56)

    // 2. The surface's rounded top corners, under the surface: Hyprland cuts them away with the window's rounding, so the
    //    bar colour fills them, then the content's own pixels are drawn there unrounded (macOS: bar and content are one
    //    shape, square where they meet). Where the content is transparent the bar colour stays. Below the bar: nothing
    //    drawBar draws overlaps them.
    if (rounding > 0) {
        CBox left{bar.x, bar.y + bar.h, rounding, rounding};
        CBox right{bar.x + bar.w - rounding, bar.y + bar.h, rounding, rounding};
        addRect(left.scale(scale).round(), bgColor, 0, power);
        addRect(right.scale(scale).round(), bgColor, 0, power);
        drawContentCorners(w, bar, rounding, scale, alpha);
    }
}

void CGrassfieldTitlebar::drawBar(const PHLWINDOW& w, const CBox& bar, float scale, double rounding, float power, float alpha, bool hovered, bool fullscreen) {
    const auto appearance = gf::state().appearance.current;
    const auto palette    = theme::titlebarPalette(appearance);
    const auto bgColor    = toColor(palette.background, alpha);
    // The window's own corner radius in device pixels, cut as Hyprland cuts the surface's and the border's (not rounded:
    // 32.5 px at 1.25 was a 33-px bar corner on a 32-px edge).
    const int  roundPx    = tb::windowCornerPx(static_cast<float>(rounding), scale);

    // Background with rounded top corners: a rounded rect taller than the bar, clipped to the bar.
    CBox bgBox   = bar;
    bgBox.h     += 2.0 * rounding;
    CBox clipBox = bar;
    addRect(bgBox.scale(scale).round(), bgColor, roundPx, power, clipBox.scale(scale).round());

    // The hairline under the bar, the apps' toolbar rule: the bar is the window's own colour (ADR-0039 Q8, step 21).
    CBox rule{bar.x, bar.y + bar.h - theme::kTitlebarRuleWidth, bar.w, theme::kTitlebarRuleWidth};
    addRect(rule.scale(scale).round(), toColor(palette.rule, alpha), 0, power);

    // Buttons (owner-drawn circles): coloured on the active window, grey on the others; coloured again with their glyphs
    // while the pointer is over the group (macOS). On a full-screen window minimize stays grey (unavailable), and so does the
    // zoom light of a window of fixed size that is neither zoomed nor in full screen (core lightAvailable).
    const bool active = Desktop::focusState() && Desktop::focusState()->window() == w;
    const bool fixed  = gf::tiler::fixedSize(w);
    const bool sized  = fullscreenMode(w) != Fullscreen::FSMODE_NONE;
    for (const auto button : tb::kButtonOrder) {
        const bool available = gf::chrome::lightAvailable(button, fullscreen, fixed, sized);
        const auto r         = tb::buttonRect(button);
        CBox       box{bar.x + r.x, bar.y + r.y, r.w, r.h};
        box.scale(scale).round();
        addRect(box, toColor(tb::lightColor(button, active && available, hovered && available, appearance), alpha), static_cast<int>(std::round(box.w / 2.0)), 2.F);
    }
    if (hovered)
        drawGlyphs(bar, scale, alpha, fullscreen, fixed, sized);

    // Title, centered on the bar, never over the buttons.
    const int maxWidthPx = static_cast<int>(std::floor(tb::maxTitleWidth(bar.w) * scale));
    if (w->m_title.empty() || maxWidthPx <= 0)
        return;

    if (!m_title.texture || m_title.text != w->m_title || m_title.scale != scale || m_title.maxWidthPx != maxWidthPx || m_title.appearance != appearance) {
        m_title.texture    = g_pHyprRenderer->renderText(w->m_title, toColor(palette.title), static_cast<int>(std::round(theme::kTitleFontSizePt * scale)), false,
                                                         theme::kTitleFontFamily, maxWidthPx, theme::kTitleFontWeight);
        m_title.text       = w->m_title;
        m_title.scale      = scale;
        m_title.maxWidthPx = maxWidthPx;
        m_title.appearance = appearance;
    }

    const auto& tex = m_title.texture;
    if (!tex || tex->m_size.x <= 0 || tex->m_size.y <= 0)
        return;

    const double texW      = tex->m_size.x / scale;
    const double texH      = tex->m_size.y / scale;
    const auto   placement = tb::placeTitle(bar.w, texW);
    if (!placement.visible)
        return;

    CTexPassElement::SRenderData data;
    data.tex = tex;
    data.box = CBox{bar.x + placement.x, bar.y + ((bar.h - texH) / 2.0), std::min(texW, placement.maxWidth), texH}.scale(scale).round();
    data.a   = alpha;
    g_pHyprRenderer->addPassElement(makeUnique<CTexPassElement>(data));
}

void CGrassfieldTitlebar::drawGlyphs(const CBox& bar, float scale, float alpha, bool fullscreen, bool fixedSize, bool sized) {
    for (size_t i = 0; i < tb::kButtonOrder.size(); ++i) {
        const auto button = tb::kButtonOrder[i];
        if (!gf::chrome::lightAvailable(button, fullscreen, fixedSize, sized))
            continue; // a disabled light shows no glyph (macOS)
        const auto r      = tb::buttonRect(button);
        CBox       box{bar.x + r.x, bar.y + r.y, r.w, r.h};
        box.scale(scale).round(); // the light exactly as drawn above
        const int sizePx = tb::glyphSizePx(static_cast<int>(std::lround(box.w)));
        if (sizePx <= 0)
            continue;

        auto&      glyph  = m_glyphs[i];
        const bool arrows = button == tb::Button::Zoom && gf::chrome::zoomGlyphIsArrows(altHeld(), fullscreen);
        if (!glyph.texture || glyph.sizePx != sizePx || glyph.scale != scale || glyph.arrows != arrows) {
            glyph = {};
            auto pixels = tb::premultipliedBgra(tb::glyphMask(button, sizePx, theme::kGlyphStroke * theme::kButtonDiameter * scale, arrows), theme::kGlyphColor);
            if (pixels.empty())
                continue;
            glyph.texture = g_pHyprRenderer->createTexture(DRM_FORMAT_ARGB8888, pixels.data(), static_cast<uint32_t>(sizePx) * 4U, Vector2D{static_cast<double>(sizePx), static_cast<double>(sizePx)});
            glyph.sizePx  = sizePx;
            glyph.scale   = scale;
            glyph.arrows  = arrows;
        }
        if (!glyph.texture || !glyph.texture->ok())
            continue;

        // glyphSizePx keeps the light's parity: the glyph sits centred on whole pixels.
        CTexPassElement::SRenderData data;
        data.tex = glyph.texture;
        data.box = CBox{box.x + std::floor((box.w - sizePx) / 2.0), box.y + std::floor((box.h - sizePx) / 2.0), static_cast<double>(sizePx), static_cast<double>(sizePx)};
        data.a   = alpha;
        g_pHyprRenderer->addPassElement(makeUnique<CTexPassElement>(data));
    }
}

void CGrassfieldTitlebar::drawContentCorners(const PHLWINDOW& w, const CBox& bar, double rounding, float scale, float alpha) {
    // Only where the surface's texture maps 1:1 onto its box: no overview or Stages transform, no buffer transform, no
    // viewport crop. Elsewhere the bar colour drawn before stays (the former look).
    if (!drawnInPlace(w))
        return;
    const auto view    = w->wlSurface();
    const auto surface = view ? view->resource() : nullptr;
    if (!surface)
        return;
    const auto& state = surface->m_current;
    if (!state.texture || !state.texture->ok() || state.transform != WL_OUTPUT_TRANSFORM_NORMAL || state.viewport.hasSource)
        return;
    // The window's box (right below the bar) is its xdg geometry; the texture starts at the surface's origin, the
    // geometry's offset up-left of it (client-side shadows). XWayland surfaces have no offset.
    Vector2D origin{0.0, 0.0};
    if (!w->m_isX11) {
        const auto xdg = w->m_xdgSurface.lock();
        if (!xdg)
            return;
        origin = xdg->m_current.geometry.pos();
    }
    const tb::Rect texture{.x = bar.x - origin.x, .y = bar.y + bar.h - origin.y, .w = state.size.x, .h = state.size.y};
    const auto     patch = tb::contentCornerPatch(tb::Rect{.x = bar.x, .y = bar.y, .w = bar.w, .h = bar.h}, rounding, texture);
    if (!patch.valid)
        return;

    CBox texBox{texture.x, texture.y, texture.w, texture.h};
    texBox.scale(scale).round();
    for (const auto& square : {patch.left, patch.right}) {
        CBox clip{square.x, square.y, square.w, square.h};
        CTexPassElement::SRenderData data;
        data.tex     = state.texture;
        data.box     = texBox;
        data.clipBox = clip.scale(scale).round();
        data.a       = alpha;
        g_pHyprRenderer->addPassElement(makeUnique<CTexPassElement>(data));
    }
}

void CGrassfieldTitlebar::onActiveWindowChanged(const PHLWINDOW& window) {
    gf::guarded("titlebar onActiveWindowChanged", [&] {
        // Grey or coloured lights: the titlebars of the window that lost the focus and of the one that got it.
        auto&      input    = pointerInput();
        const auto previous = input.activeWindow.lock();
        input.activeWindow  = window;
        for (auto* deco : gf::state().titlebars) {
            const auto w = deco->window();
            if (w && (w == window || w == previous))
                deco->damageEntire();
        }
    });
}

void CGrassfieldTitlebar::onAppearanceChanged() {
    gf::guarded("titlebar onAppearanceChanged", [] {
        for (auto* deco : gf::state().titlebars) {
            deco->m_title.texture.reset(); // the title colour is in its texture: rebuilt on the next draw
            deco->damageEntire();
        }
    });
}

void CGrassfieldTitlebar::onKey() {
    gf::guarded("titlebar onKey", [] {
        // Only the lights under the pointer show glyphs; the frame drawn next reads Alt after Hyprland applied this key.
        if (auto* hovered = pointerInput().hovered; isLive(hovered))
            hovered->damageEntire();
    });
}

bool CGrassfieldTitlebar::onInputOnDeco(const eInputType type, const Vector2D& coords, std::any data) {
    bool consumed = false;
    gf::guarded("titlebar onInputOnDeco", [&] {
        if (type != INPUT_TYPE_BUTTON)
            return;
        const auto* e = std::any_cast<IPointer::SButtonEvent>(&data);
        if (!e)
            return;
        if (e->state == WL_POINTER_BUTTON_STATE_RELEASED) {
            // Only the release of a press a titlebar consumed (offered by onGlobalMouseButton). Hyprland
            // has already cleared its held button when it routes the release here. The release of a
            // press that went to a client is left to Hyprland, which sends it to that client.
            consumed = pointerInput().presses.takeTitlebarRelease(e->button);
            return;
        }
        if (shouldShow())
            consumed = onButtonPress(coords, *e);
    });
    return consumed;
}

bool CGrassfieldTitlebar::onButtonPress(const Vector2D& coords, const IPointer::SButtonEvent& e) {
    const auto w = window();
    if (!w || e.button != BTN_LEFT)
        return false;

    const CBox bar = layoutBox();
    const auto hit = tb::hitTest(coords.x - bar.x, coords.y - bar.y, bar.w);
    gf::logRequest(Log::DEBUG, "titlebar press at {:.1f},{:.1f} bar {:.1f},{:.1f} {:.0f}x{:.0f} -> {}", coords.x, coords.y, bar.x, bar.y, bar.w, bar.h, hitName(hit));
    if (hit == tb::HitTarget::None)
        return false;

    focusAndRaise(w);

    auto& input = pointerInput();
    if (const auto button = tb::buttonForHit(hit)) {
        input.grab         = {};
        input.grab.deco    = this;
        input.grab.button  = button;
        input.grab.devices = pointerDevices();
        input.presses.claim(e.button, true);
        m_clicks.reset();
        return true;
    }

    // A window of a Split View Desktop (tiling.md TL33): no double-click action. Its titlebar drag moves it at its size, and
    // its release over the other half swaps the two windows, anywhere else puts it back in its half (step 6b, ADR-0036 D59).
    // In full screen or zoomed a press focuses and raises it only.
    if (gf::tiler::inSplit(w)) {
        m_clicks.reset();
        const auto target = w->layoutTarget();
        if (!target || fullscreenMode(w) != Fullscreen::FSMODE_NONE) {
            input.presses.claim(e.button, false);
            return true;
        }
        input.grab          = {};
        input.grab.deco     = this;
        input.grab.dragging = true;
        input.grab.member   = true;
        input.grab.window   = w;
        input.grab.pressPos = coords;
        input.grab.startBox = target->position();
        input.grab.pressBox = input.grab.startBox;
        input.grab.devices  = pointerDevices();
        input.presses.claim(e.button, true);
        gf::tiler::memberDragBegin(w);
        return true;
    }

    // Drag area: a double-click does what Settings say (windows.titlebarDoubleClick, pushed by the shell with
    // hl.plugin.grassfield.config): Fill (tiling.md M40, the default since ADR-0036 D78) and Zoom are the zoom button's
    // toggle (Zoom is Fill: the window fills, a second double-click brings back its box from before, as macOS 15+), the
    // minimize button's path, or nothing (the press is then a single press). Otherwise the press starts an interactive move.
    if (m_clicks.press(e.timeMs, coords.x, coords.y)) {
        switch (gf::state().doubleClickAction) {
            case gf::gfc::DoubleClickAction::Fill:
            case gf::gfc::DoubleClickAction::Zoom:
                gf::logRequest(Log::DEBUG, "titlebar double-click -> {}", gf::state().doubleClickAction == gf::gfc::DoubleClickAction::Fill ? "fill" : "toggle zoom");
                toggleZoom(w);
                input.presses.claim(e.button, false); // acts now; its release is still the titlebar's
                return true;
            case gf::gfc::DoubleClickAction::Minimize:
                gf::logRequest(Log::DEBUG, "titlebar double-click -> minimize");
                requestMinimize(w);
                input.presses.claim(e.button, false);
                return true;
            case gf::gfc::DoubleClickAction::None: break;
        }
    }

    const auto mode = fullscreenMode(w);
    if (mode != Fullscreen::FSMODE_NONE && mode != Fullscreen::FSMODE_MAXIMIZED) {
        input.presses.claim(e.button, false); // focus and raise only; the release is still the titlebar's
        return true;
    }

    const auto target = w->layoutTarget();
    if (target) {
        input.grab          = {};
        input.grab.deco     = this;
        input.grab.dragging = true;
        input.grab.unzoom   = mode == Fullscreen::FSMODE_MAXIMIZED;
        if (input.grab.unzoom)
            input.grab.zoomedSurface = w->geometricBox(Desktop::View::IGeometric::GEOMETRIC_GOAL);
        input.grab.untile   = !input.grab.unzoom && gf::tiler::isTiled(w);
        input.grab.window   = w;
        input.grab.pressPos = coords;
        input.grab.startBox = target->position();
        input.grab.pressBox   = input.grab.startBox;
        input.grab.plainPress = !input.grab.unzoom && !input.grab.untile;
        input.grab.devices  = pointerDevices();
    }
    input.presses.claim(e.button, target != nullptr);
    return true;
}

void CGrassfieldTitlebar::activate(tb::Button button) {
    const auto w = window();
    if (!w)
        return;

    switch (button) {
        case tb::Button::Close:
            gf::logRequest(Log::DEBUG, "titlebar close");
            logIfFailed("close", Config::Actions::closeWindow(w));
            break;
        case tb::Button::Zoom: gf::logRequest(Log::DEBUG, "titlebar zoom"); zoomLight(w); break;
        case tb::Button::Minimize: gf::logRequest(Log::DEBUG, "titlebar minimize"); requestMinimize(w); break;
    }
}

void CGrassfieldTitlebar::onGlobalMouseButton(const IPointer::SButtonEvent& e) {
    gf::guarded("titlebar onGlobalMouseButton", [&] {
        auto& input = pointerInput();
        if (e.state == WL_POINTER_BUTTON_STATE_PRESSED) {
            // TL22: a press ends the zoom light's hover (its click zooms the window) until the pointer leaves the light.
            postHover(input.zoomHover.press(), nullptr, CBox{});
            if (input.zoomTimer)
                input.zoomTimer->updateTimeout(std::nullopt);
            // A press while a gesture is active: its release was lost (e.g. the pressing device went away)
            // or another button was pressed. End the gesture where it is; this press goes wherever
            // Hyprland sends it, and its release with it.
            if (input.presses.onPress(e.button)) {
                gf::logRequest(Log::DEBUG, "titlebar gesture cancelled by a new press (button {:#x})", e.button);
                if (input.grab.dragging)
                    gf::tiler::dragDone(); // no preview, no tile
                if (input.grab.member) {
                    gf::tiler::memberDrop(input.grab.window.lock(), std::nullopt); // back in its half
                } else {
                    gf::tiler::endMove(input.grab.window.lock()); // a tiled window dragged away is Free
                    if (input.grab.moved)
                        gf::tiler::followOutput(input.grab.window.lock());
                }
                input.grab = {};
            }
            // A press during a member's drag by its revealed bar (D75: its press was cancelled, `presses` never saw it): the
            // drag ends there, the window back in its half; this press goes on (to the revealed bar's listener next, or
            // wherever Hyprland sends it).
            if (input.grab.revealed) {
                gf::logRequest(Log::INFO, "revealed titlebar: a Split View window's drag ended by another press: back in its half");
                endRevealedDrag(std::nullopt);
            }
            return;
        }

        // The release is never cancelled. Hyprland 0.56.2 records every press as held, also one a titlebar
        // consumes (CInputManager::onMouseButton adds the button to m_currentlyHeldButtons before
        // processMouseDownNormal offers the press to the decorations), and while a button is held it keeps
        // pointer focus on the surface that has it. A cancelled release returns before the button is
        // removed: pointer focus then stayed on the dragged window, and the next click on another window
        // went to it. Processed normally, an owned release is consumed by a titlebar under the pointer
        // (onInputOnDeco); elsewhere it reaches the seat, which drops it for a client that never got the
        // press (CWLPointerResource::sendButton).
        const auto release = input.presses.onRelease(e.button);
        if (!release.owned || !release.endsGesture)
            return; // a client's press (or an immediate action): nothing to finish here

        SPointerGrab grab = std::exchange(input.grab, {});
        if (grab.dragging)
            updateMove(grab); // final position at the release point (none for a click)
        // A Split View member (TL33, step 6b): over the other half the two swap halves, anywhere else it goes back in its half;
        // it never takes another output's Desktop nor a tiling place.
        if (grab.member) {
            const auto at = grab.moved && g_pInputManager ? std::optional<Vector2D>{g_pInputManager->getMouseCoordsInternal()} : std::optional<Vector2D>{};
            gf::tiler::memberDrop(grab.window.lock(), at); // a click: nothing to place (back in its half: where it is)
            return;
        }
        // Released over the place shown (after the preview delay, TL17): the window takes it (FR47); the preview goes.
        // Released elsewhere, or before the place showed, a tiled window dragged away is Free (tiling.md TL10).
        const auto snap = grab.dragging && grab.moved ? gf::tiler::previewOf(grab.window.lock()) : std::nullopt;
        if (grab.dragging)
            gf::tiler::dragDone();
        if (snap) {
            if (const auto w = grab.window.lock())
                gf::tiler::tile(w, snap->place, snap->monitor.lock());
        }
        gf::tiler::endMove(grab.window.lock()); // no-op unless the window is still Moving
        // Dropped on another output: the window takes that output's Desktop, as after Hyprland's own move (R13), and fits its
        // work area when it is larger (owner report on 1.0.0-rc6; a tile placed by the release is left alone).
        if (grab.dragging && grab.moved) {
            gf::tiler::followOutput(grab.window.lock());
            if (!snap)
                gf::tiler::fitAfterDrop(grab.window.lock(), grab.pressBox);
        }
        // Released on the Stages strip (macOS: a window dragged onto the strip becomes a stage of its own): the plugin does
        // what the shell's op move "new" does; the shell cannot see a titlebar drag (stages.md, Shell side work item 1).
        if (grab.dragging && grab.moved && g_pInputManager) {
            if (const auto w = grab.window.lock()) {
                const auto at = g_pInputManager->getMouseCoordsInternal();
                const auto& p = grab.pressBox;
                gf::stager::dropOnStrip(w, at.x, at.y, snap.has_value(),
                                        grab.plainPress ? std::optional<gf::stages::Box>{gf::stages::Box{p.x, p.y, p.w, p.h}} : std::nullopt);
            }
        }

        if (grab.button && isLive(grab.deco) && g_pInputManager) {
            const auto pos = g_pInputManager->getMouseCoordsInternal();
            const CBox bar = grab.deco->layoutBox();
            if (tb::buttonForHit(tb::hitTest(pos.x - bar.x, pos.y - bar.y, bar.w)) == grab.button)
                grab.deco->activate(*grab.button);
        }
    });
}

void CGrassfieldTitlebar::onGlobalMouseMove() {
    gf::guarded("titlebar reveal", [] { updateReveal(); }); // before the hover: a bar just revealed shows its glyphs
    gf::guarded("titlebar hover", [] { updateHover(); });
    gf::guarded("titlebar zoom hover", [] { updateZoomHover(); });
    gf::guarded("titlebar onGlobalMouseMove", [] {
        auto& input = pointerInput();
        // A member's drag by its revealed bar (D75): its press and release are cancelled, so Hyprland holds no button for it;
        // it lasts while that release is owed. A pointer device gone may never send it: the drag ends, back in its half, and
        // the release is no longer waited for (one that still comes reaches Hyprland, which holds no such button).
        if (input.grab.revealed) {
            const bool intact = devicesIntact(input.grab.devices);
            if (!intact || !input.revealPresses.pressing()) {
                gf::logRequest(Log::INFO, "revealed titlebar: a Split View window's drag cancelled ({}): back in its half",
                               intact ? "its press is over" : "a pointer device went away");
                if (!intact)
                    input.revealPresses.reset();
                endRevealedDrag(std::nullopt);
                return;
            }
            auto* deco = isLive(input.grab.deco) ? input.grab.deco : nullptr;
            if (deco)
                deco->damageRevealed(); // where its bar was: the bar moves with the window
            updateMove(input.grab);
            if (deco)
                deco->damageRevealed();
            return;
        }
        if (!input.presses.gestureButton())
            return;
        // Hyprland's held-button state and the pointer devices tell whether the gesture's button can
        // still be down; if not, its release will never arrive and the gesture must not stick.
        const bool held = g_pInputManager && g_pInputManager->hasHeldButtons();
        if (input.presses.onMotion(held, devicesIntact(input.grab.devices))) {
            gf::logRequest(Log::DEBUG, "titlebar gesture cancelled: no button held or a pointer device went away");
            if (input.grab.dragging)
                gf::tiler::dragDone();
            if (input.grab.member) {
                gf::tiler::memberDrop(input.grab.window.lock(), std::nullopt); // back in its half
            } else {
                gf::tiler::endMove(input.grab.window.lock());
                if (input.grab.moved)
                    gf::tiler::followOutput(input.grab.window.lock());
            }
            input.grab = {};
            return;
        }
        if (input.grab.dragging)
            updateMove(input.grab);
    });
}

bool CGrassfieldTitlebar::pointerCovered(const Vector2D& pos) {
    return zoomLightsCover(pos) != gf::tiling::HoverCoverEffect::None;
}

void CGrassfieldTitlebar::onSessionLock(bool locked) {
    gf::guarded("titlebar session lock", [locked] {
        auto& input = pointerInput();
        // A member's drag by its revealed bar ends at the lock (D75): back in its half, nothing moves behind the lock screen.
        // Its release, still owed, is cancelled when it comes (revealPresses), as its press was.
        if (locked && input.grab.revealed)
            endRevealedDrag(std::nullopt);
        postHover(input.zoomHover.update(std::nullopt, nowMs()), nullptr, CBox{});
        if (!locked)
            armZoomTimer(0);
        else if (input.zoomTimer)
            input.zoomTimer->updateTimeout(std::nullopt);
    });
}

void CGrassfieldTitlebar::cancelPointerGrab() {
    gf::guarded("titlebar cancelPointerGrab", [] {
        auto& input        = pointerInput();
        if (input.grab.dragging)
            gf::tiler::dragDone();
        if (input.grab.member)
            gf::tiler::memberDrop(input.grab.window.lock(), std::nullopt); // a Split View member: back in its half
        else
            gf::tiler::endMove(input.grab.window.lock());
        input.grab         = {};
        input.hovered      = nullptr;
        input.activeWindow = {};
        input.presses.reset();
        // A release still owed reaches Hyprland, which has no such button held and returns (read from the binary).
        input.revealPresses.reset();
        input.heldButtons.reset();
        input.revealArmed = nullptr;
        input.revealLight.reset();
        input.zoomHover.reset(); // the shell drops the popover with the feature (unload) or on its own close rules
        if (input.zoomTimer) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(input.zoomTimer); // its callback is code of this library
            input.zoomTimer.reset();
        }
        for (auto* deco : gf::state().titlebars) {
            deco->damageRevealed();
            deco->m_revealed = false;
        }
        postReveals(); // the shell's menu bars no longer follow a revealed titlebar
    });
}

void CGrassfieldTitlebar::updateReveal() {
    if (!g_pInputManager)
        return;
    const Vector2D pos      = g_pInputManager->getMouseCoordsInternal();
    const bool     pressing = pointerInput().revealPresses.pressing();
    bool           changed  = false;
    // The monitors with a bar revealed before this motion: there the other half's bar comes across the band (D74).
    std::vector<PHLMONITOR> withBar;
    for (const auto* deco : gf::state().titlebars) {
        const auto w = deco->m_revealed ? deco->window() : nullptr;
        if (const auto mon = w ? w->m_monitor.lock() : nullptr)
            withBar.push_back(mon);
    }
    // The Split View members on visible Desktops, read once and only when a bar may change (not on every motion): their
    // halves (the pointer over the other half hands the bar over, D74) and which of them are zoomed or in full screen (they
    // cover the other member, whose bar then never comes).
    struct SMember {
        const CGrassfieldTitlebar*  deco = nullptr;
        PHLWORKSPACE                workspace;
        Fullscreen::eFullscreenMode mode  = Fullscreen::FSMODE_NONE;
        double                      left  = 0.0;
        double                      right = 0.0;
    };
    std::optional<std::vector<SMember>> members;
    const auto                          halves = [&members]() -> const std::vector<SMember>& {
        if (!members) {
            members.emplace();
            for (const auto* d : gf::state().titlebars) {
                const auto mw = d->window();
                if (!mw || !mw->m_isMapped || !mw->m_workspace || !mw->m_workspace->isVisible() || !gf::tiler::inSplit(mw))
                    continue;
                const CBox surface = mw->getWindowMainSurfaceBox();
                members->push_back(SMember{.deco = d, .workspace = mw->m_workspace, .mode = fullscreenMode(mw), .left = surface.x, .right = surface.x + surface.w});
            }
        }
        return *members;
    };
    for (auto* deco : gf::state().titlebars) {
        gf::chrome::RevealInput in;
        const auto              w   = deco->window();
        const auto              mon = w ? w->m_monitor.lock() : nullptr;
        if (mon) {
            in.onMonitor = pos.x >= mon->m_position.x && pos.x < mon->m_position.x + mon->m_size.x && pos.y >= mon->m_position.y && pos.y < mon->m_position.y + mon->m_size.y;
            in.pointerY  = pos.y - mon->m_position.y;
            in.handOver  = !deco->m_revealed && std::ranges::find(withBar, mon) != withBar.end();
        }
        // The cheap test first, on every pointer motion: away and the pointer not at its monitor's top edge (nor in the band
        // of another bar revealed there), nothing changes.
        if (!deco->m_revealed && (!in.onMonitor || (in.pointerY > gf::chrome::kRevealEdge && !in.handOver)))
            continue;
        in.revealable = deco->revealable();
        if (!in.revealable && !deco->m_revealed)
            continue;
        // A Split View member's bar is its half's alone (D74), and stays across the gap until the pointer is over the other
        // half; a full-screen window's spans its monitor. A member covered by its other member (zoomed or in full screen)
        // shows none.
        if (const auto mode = w ? fullscreenMode(w) : Fullscreen::FSMODE_NONE; in.revealable && mode != Fullscreen::FSMODE_FULLSCREEN && gf::tiler::inSplit(w)) {
            const CBox surface = w->getWindowMainSurfaceBox();
            in.inSpan          = pos.x >= surface.x && pos.x < surface.x + surface.w;
            if (mode == Fullscreen::FSMODE_NONE) {
                for (const auto& other : halves()) {
                    if (other.deco == deco || other.workspace != w->m_workspace)
                        continue;
                    if (other.mode != Fullscreen::FSMODE_NONE)
                        in.revealable = false;
                    else if (pos.x >= other.left && pos.x < other.right)
                        in.overOther = true;
                }
            }
        }
        in.barTop       = menubarInset(mon);
        in.pressing     = pressing;
        const bool next = gf::chrome::nextRevealed(deco->m_revealed, in);
        if (next == deco->m_revealed)
            continue;
        deco->damageRevealed(); // where it was
        deco->m_revealed = next;
        deco->damageRevealed(); // where it is
        changed = true;
        if (!sessionLocked()) {
            // Which half's bar, numbered (tests/compositor/tiling.sh split-titles waits for a number past the one it read in
            // Hyprland's in-memory log before the motion: the log file is buffered, the review of #99).
            static uint64_t splitReveals = 0;
            if (gf::tiler::inSplit(w))
                gf::logRequest(Log::DEBUG, "titlebar of Split View window {:x} {} (reveal {})", addressOf(w), next ? "revealed" : "away", ++splitReveals);
            else
                gf::logRequest(Log::DEBUG, "titlebar of a full-screen window {}", next ? "revealed" : "away");
        }
    }
    if (changed)
        postReveals();
}

void CGrassfieldTitlebar::drawRevealed() {
    gf::guarded("titlebar drawRevealed", [] {
        if (!g_pHyprRenderer)
            return;
        const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!mon)
            return;
        for (auto* deco : gf::state().titlebars) {
            if (!deco->m_revealed)
                continue;
            const auto w = deco->window();
            if (!w || w->m_monitor.lock() != mon || !deco->revealable())
                continue;
            CBox bar = deco->revealBox();
            if (bar.w <= 0 || bar.h <= 0)
                continue;
            bar.translate(-mon->m_position);
            const bool hovered = pointerInput().hovered == deco && g_pInputManager && deco->buttonGroupContains(g_pInputManager->getMouseCoordsInternal());
            deco->drawBar(w, bar, mon->m_scale, 0.0, w->roundingPower(), 1.F, hovered, true); // square: it spans the monitor
        }
    });
}

bool CGrassfieldTitlebar::onRevealedBarButton(const IPointer::SButtonEvent& e) {
    bool cancel = false;
    gf::guarded("titlebar revealed bar button", [&] {
        auto&      input  = pointerInput();
        const bool locked = sessionLocked();
        if (locked) {
            // A light armed before the lock never acts (review of part B, 2026-10-24).
            input.revealArmed = nullptr;
            input.revealLight.reset();
        }
        if (e.state == WL_POINTER_BUTTON_STATE_RELEASED) {
            if (!input.revealPresses.takeRelease(e.button))
                return; // a release Hyprland expects
            cancel           = true;
            auto*      armed = std::exchange(input.revealArmed, nullptr);
            const auto light = std::exchange(input.revealLight, std::nullopt);
            if (e.button == BTN_LEFT && light && isLive(armed) && armed->m_revealed && armed->revealable() && g_pInputManager) {
                const auto pos    = g_pInputManager->getMouseCoordsInternal();
                const CBox bar    = armed->revealBox();
                const bool overIt = tb::buttonForHit(tb::hitTest(pos.x - bar.x, pos.y - bar.y, bar.w)) == light;
                gf::logRequest(Log::INFO, "revealed titlebar: release {}", overIt ? "on the light: it acts" : "away from the light: nothing");
                if (overIt)
                    armed->activate(*light);
            } else if (light && !locked)
                gf::logRequest(Log::INFO, "revealed titlebar: release of an armed light with the bar gone: nothing");
            // A member's drag by this bar (D75) ends at the release of its button: over the other half the two swap halves
            // (memberDrop), anywhere else or without a move it goes back in its half.
            if (input.grab.revealed && e.button == BTN_LEFT) {
                if (isLive(input.grab.deco))
                    input.grab.deco->damageRevealed(); // where the bar was at the last motion
                updateMove(input.grab);                // its final place at the release point
                const bool moved = input.grab.moved;
                const auto at    = moved ? std::optional<Vector2D>{g_pInputManager ? g_pInputManager->getMouseCoordsInternal() : input.grab.pressPos} : std::nullopt;
                gf::logRequest(Log::INFO, "revealed titlebar: a Split View window's drag released {}", moved ? "after a move" : "without a move");
                endRevealedDrag(at);
            }
            updateReveal(); // the pointer may have left the bar during the press
            return;
        }
        if (!g_pInputManager)
            return;
        const auto           pos     = g_pInputManager->getMouseCoordsInternal();
        auto&                held    = input.heldButtons;
        const bool           none    = !g_pInputManager->hasHeldButtons();
        CGrassfieldTitlebar* deco    = nullptr;
        const char*          refused = nullptr;
        for (auto* d : gf::state().titlebars) {
            if (!d->m_revealed || !d->revealBox().containsPoint(pos))
                continue;
            const auto w = d->window();
            if (!w || !d->revealable())
                refused = "the window cannot show it now";
            else if (overlaySurfaceAt(pos, w->m_monitor.lock()))
                refused = "a layer popup or an Overlay layer is over it";
            // Hyprland's held buttons are per button and the bus event names no device (IPointer::SButtonEvent): a press of a
            // button another device already holds goes to Hyprland, so that the other device's release is never mistaken
            // for the bar's (review of part B: B holds LEFT, A presses LEFT on the bar); so does any press until the plugin
            // has seen Hyprland hold nothing (core CHeldButtons).
            else if (!held.mayTake(e.button, none))
                refused = held.known() ? "that button is already held" : "the held buttons are not known yet";
            else
                deco = d;
            break;
        }
        // One line per press over the revealed bar (never a key, never while locked, never a position): what it did and
        // why (tests/compositor/fullscreen_reveal.sh prints them).
        if (refused && !locked)
            gf::logRequest(Log::INFO, "revealed titlebar: a press left to Hyprland: {} (Hyprland {})", refused, none ? "holds no button" : "holds some button");
        if (deco)
            cancel = true; // first: whatever follows, the press never reaches Hyprland without its release owed
        input.revealPresses.onPress(e.button, deco != nullptr);
        if (!deco)
            return;
        input.revealArmed = nullptr;
        input.revealLight.reset();
        const auto w = deco->window();
        if (e.button != BTN_LEFT || !w)
            return; // other buttons do nothing on the bar
        const CBox bar = deco->revealBox();
        const auto hit = tb::hitTest(pos.x - bar.x, pos.y - bar.y, bar.w);
        gf::logRequest(Log::INFO, "revealed titlebar: a press taken -> {}", hitName(hit));
        focusAndRaise(w);
        const auto target        = w->layoutTarget();
        const bool memberInPlace = target && gf::tiler::inSplit(w) && fullscreenMode(w) == Fullscreen::FSMODE_NONE;
        switch (gf::chrome::revealedPress(hit, memberInPlace)) {
            case gf::chrome::RevealedPress::ArmLight:
                input.revealArmed = deco;
                input.revealLight = tb::buttonForHit(hit);
                break;
            case gf::chrome::RevealedPress::MemberDrag: {
                // TL33, step 6e (D75, D59): the window follows the pointer with its bar until the release (or another press).
                // Once it moves, its surface hangs below the bar, which stays under the pointer where it was pressed: the
                // move starts from the box whose top is the bar's bottom (updateMove never takes it higher).
                input.grab           = {};
                input.grab.deco      = deco;
                input.grab.dragging  = true;
                input.grab.member    = true;
                input.grab.revealed  = true;
                input.grab.barOffset = -theme::kTitlebarHeight;
                input.grab.window    = w;
                input.grab.pressPos  = pos;
                input.grab.startBox  = target->position();
                input.grab.pressBox  = input.grab.startBox;
                input.grab.startBox.y = bar.y + theme::kTitlebarHeight;
                input.grab.devices   = pointerDevices();
                gf::tiler::memberDragBegin(w);
                gf::logRequest(Log::INFO, "revealed titlebar: a Split View window's drag begins");
                break;
            }
            case gf::chrome::RevealedPress::Nothing: break;
        }
    });
    // What Hyprland holds from here on: a press it processes adds its button, a release it processes removes it (its list
    // removes every entry of that button).
    gf::guarded("titlebar held buttons", [&] {
        if (!cancel)
            pointerInput().heldButtons.observe(e.button, e.state == WL_POINTER_BUTTON_STATE_PRESSED);
    });
    return cancel;
}
