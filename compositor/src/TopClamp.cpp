#include "TopClamp.hpp"

#include "ClientChrome.hpp"
#include "DeferredFocus.hpp"
#include "Plugin.hpp"
#include "core/TopClamp.hpp"

#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

namespace gf::topClamp {

    namespace {
        // A release that ended one of Hyprland's drags, waiting for Hyprland to end it.
        struct SPending {
            PHLWINDOWREF                  window;
            bool                          resize = false;
            std::optional<topclamp::Rect> before; // the surface box when the drag was first seen moving
        };

        // The window one of Hyprland's drags holds, and its surface box at the first motion of the drag (Hyprland keeps
        // the box the drag began with to itself: CDragStateController::m_beginDragPositionXY is private). At worst one
        // motion step after the drag began: a resize from the bottom or a side edge never moves the top at any step.
        struct SSeen {
            PHLWINDOWREF   window;
            topclamp::Rect box;
        };

        struct SState {
            bool                    ready = false;
            std::optional<SSeen>    seen;
            std::optional<SPending> pending;
            deferredFocus::CLater   later; // its callback is code of this library: cancelled in stop()
        };

        // Constructed on first use inside a guarded call (R13).
        SState& st() {
            static SState s;
            return s;
        }

        topclamp::Rect toRect(const CBox& b) {
            return topclamp::Rect{b.x, b.y, b.w, b.h};
        }

        CBox toCBox(const topclamp::Rect& r) {
            return CBox{r.x, r.y, r.w, r.h};
        }

        // A floating window with its own frame: not full screen or zoomed (those cover the menu bar on purpose).
        bool holdable(const PHLWINDOW& w) {
            if (!w || !w->m_isMapped || !w->m_isFloating || !w->layoutTarget())
                return false;
            const auto& fs = Fullscreen::controller();
            return !fs || fs->getFullscreenModes(w).internal == Fullscreen::FSMODE_NONE;
        }

        // Every enabled output with the bottom of its menu bar strip (its top reserved area). Hyprland keeps a disconnected
        // monitor (m_enabled false) in its list for a while: no menu bar there to hold a window under.
        std::vector<topclamp::Output> outputs() {
            std::vector<topclamp::Output> out;
            const auto&                   state = State::monitorState();
            if (!state)
                return out;
            for (const auto& m : state->monitors()) {
                if (!m || !m->m_enabled)
                    continue;
                const CBox box = m->logicalBox();
                out.push_back(topclamp::Output{toRect(box), box.y + m->m_reservedArea.top()});
            }
            return out;
        }

        bool hyprlandDrag(eMouseBindMode mode) {
            return mode == MBIND_MOVE || mode == MBIND_RESIZE || mode == MBIND_RESIZE_BLOCK_RATIO || mode == MBIND_RESIZE_FORCE_RATIO;
        }

        // After Hyprland handled the release: its drag is over, the window keeps its titlebar below the menu bar.
        void afterHyprlandDrag() {
            auto&      s       = st();
            const auto pending = std::exchange(s.pending, std::nullopt);
            if (!pending || !s.ready || !g_layoutManager || !g_pInputManager)
                return;
            if (const auto& drag = g_layoutManager->dragController(); drag && drag->mode() != MBIND_INVALID)
                return; // still dragging (the release was of another button)
            const auto w = pending->window.lock();
            if (!holdable(w))
                return;
            const auto     target  = w->layoutTarget();
            const Vector2D pointer = g_pInputManager->getMouseCoordsInternal();
            // No band above a window that draws its own chrome (ADR-0015).
            const auto next = topclamp::afterDrag(pending->before, toRect(target->position()), pending->resize, gf::chrome::bandOf(w), topclamp::Point{pointer.x, pointer.y}, outputs());
            if (!next)
                return;
            const CBox box = toCBox(*next);
            g_layoutManager->setTargetGeom(box, target);
            logRequest(Log::DEBUG, "top clamp {:x}: {} ended under the menu bar, now at {:.0f},{:.0f} {:.0f}x{:.0f}", reinterpret_cast<uintptr_t>(w.get()),
                       pending->resize ? "resize" : "move", box.x, box.y, box.w, box.h);
        }
    } // namespace

    bool start() {
        auto& s = st();
        s.later.clear(); // a previous stop() cancelled it (the library may have stayed mapped)
        s.pending.reset();
        s.seen.reset();
        s.ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.ready = false;
        s.later.cancel();
        s.pending.reset();
        s.seen.reset();
    }

    CBox heldMove(const PHLWINDOW& w, const CBox& surface, const Vector2D& pointer) {
        if (!st().ready || !holdable(w))
            return surface;
        return toCBox(topclamp::heldMove(toRect(surface), gf::chrome::bandOf(w), topclamp::Point{pointer.x, pointer.y}, outputs()));
    }

    CBox belowMenuBar(const PHLWINDOW& w, const CBox& surface, double band) {
        if (!holdable(w))
            return surface;
        return toCBox(topclamp::heldMove(toRect(surface), band, topclamp::Point{surface.x + (surface.w / 2.0), surface.y}, outputs()));
    }

    void beforePointerMotion() {
        auto& s = st();
        if (!s.ready || !g_layoutManager)
            return;
        const auto& drag = g_layoutManager->dragController();
        if (!drag || !hyprlandDrag(drag->mode())) {
            s.seen.reset(); // no drag (one that ended without a release seen here is forgotten too)
            return;
        }
        const auto target = drag->target();
        const auto w      = target ? target->window() : nullptr;
        if (!holdable(w) || (s.seen && s.seen->window.lock() == w))
            return;
        s.seen = SSeen{.window = w, .box = toRect(target->position())};
    }

    void beforePointerButton(bool pressed) {
        auto& s = st();
        if (!s.ready || !g_layoutManager)
            return;
        const auto& drag     = g_layoutManager->dragController();
        const bool  dragging = drag && hyprlandDrag(drag->mode());
        if (pressed) {
            if (!dragging)
                s.seen.reset(); // a press that may begin a drag: its first motion records the box
            return;
        }
        if (!dragging)
            return;
        const auto target = drag->target();
        const auto w      = target ? target->window() : nullptr;
        if (!holdable(w))
            return;
        // Kept for the whole drag (a release of another button may come first): forgotten at the next motion or press
        // without a drag.
        std::optional<topclamp::Rect> before;
        if (s.seen && s.seen->window.lock() == w)
            before = s.seen->box;
        s.pending = SPending{.window = w, .resize = drag->mode() != MBIND_MOVE, .before = before};
        s.later.schedule([] { gf::guarded("top clamp after a drag", [] { afterHyprlandDrag(); }); });
    }

    void skip(const PHLWINDOW& w) {
        auto& s = st();
        if (w && s.pending && s.pending->window.lock() == w)
            s.pending.reset(); // its scheduled callback finds nothing to do
    }

} // namespace gf::topClamp
