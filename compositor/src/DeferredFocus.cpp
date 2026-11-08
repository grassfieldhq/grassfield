#include "DeferredFocus.hpp"

#include "Plugin.hpp"
#include "Surfaces.hpp"

#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/ViewHitTester.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>

#include <utility>
#include <vector>

namespace df = gf::deferredfocus;

namespace gf::deferredFocus {

    bool sessionLocked() {
        return !g_pSessionLockManager || g_pSessionLockManager->isSessionLocked(); // undecidable: locked (failures stay locked)
    }

    bool exclusiveLayerMapped() {
        return g_pInputManager && !g_pInputManager->m_exclusiveLSes.empty();
    }

    bool windowFocusRefused() {
        return sessionLocked() || exclusiveLayerMapped();
    }

    bool windowHoldsKeyboard(const PHLWINDOW& w) {
        const auto fs = Desktop::focusState();
        return w && fs && fs->window() == w && gf::surfaces::ownerOf(gf::surfaces::keyboardFocus()).window == w;
    }

    bool focusWindow(const PHLWINDOW& w, Desktop::eFocusReason reason, bool* stateReset) {
        if (stateReset)
            *stateReset = false;
        const auto fs = Desktop::focusState();
        if (!fs || !w || !w->m_isMapped || windowFocusRefused())
            return false;
        if (windowHoldsKeyboard(w))
            return true;
        fs->fullWindowFocus(w, reason);
        if (!windowHoldsKeyboard(w) && fs->window() == w && !windowFocusRefused()) {
            if (stateReset)
                *stateReset = true;
            fs->resetWindowFocus();
            fs->fullWindowFocus(w, reason);
        }
        return windowHoldsKeyboard(w);
    }

    SP<CWLSurfaceResource> keyboardHolder() {
        const auto fs = Desktop::focusState();
        if (auto surface = fs ? fs->surface() : nullptr)
            return surface;
        if (auto surface = gf::surfaces::keyboardFocus())
            return surface;
        if (g_pInputManager) {
            for (const auto& ref : g_pInputManager->m_exclusiveLSes) {
                const auto ls = ref.lock();
                if (ls && ls->m_mapped && ls->resource())
                    return ls->resource();
            }
        }
        return nullptr;
    }

    bool cursorOnExclusiveLayer(const Vector2D& at) {
        if (!g_pInputManager || !Desktop::viewState())
            return false;
        std::vector<PHLLSREF> exclusive = g_pInputManager->m_exclusiveLSes;
        Vector2D              local;
        PHLLS                 found;
        const auto            tester = Desktop::viewState()->hitTest();
        return tester.layerPopupSurfaceAt(at, static_cast<const std::vector<PHLLSREF>*>(&exclusive), &local, &found) || tester.layerSurfaceAt(at, &exclusive, &local, &found);
    }

    PHLLS exclusiveLayerAt(const Vector2D& at) {
        if (!g_pInputManager || !Desktop::viewState())
            return nullptr;
        std::vector<PHLLSREF> exclusive = g_pInputManager->m_exclusiveLSes;
        Vector2D              local;
        PHLLS                 found;
        const auto            tester = Desktop::viewState()->hitTest();
        if (tester.layerPopupSurfaceAt(at, static_cast<const std::vector<PHLLSREF>*>(&exclusive), &local, &found) && found)
            return found;
        found.reset();
        if (tester.layerSurfaceAt(at, &exclusive, &local, &found) && found)
            return found;
        return nullptr;
    }

    df::PressContext pressContext(bool pointer) {
        df::PressContext context{.exclusive = exclusiveLayerMapped(), .onExclusive = true, .under = 0};
        if (pointer && context.exclusive && g_pInputManager && Desktop::viewState()) {
            const auto at       = g_pInputManager->getMouseCoordsInternal();
            context.onExclusive = cursorOnExclusiveLayer(at);
            if (!context.onExclusive) {
                const auto under = Desktop::viewState()->hitTest().windowAt(
                    at, static_cast<uint16_t>(gf::flagsOf(Desktop::View::RESERVED_EXTENTS, Desktop::View::INPUT_EXTENTS, Desktop::View::ALLOW_FLOATING,
                                                          Desktop::View::FOLLOW_MOUSE_CHECK)));
                context.under = under ? reinterpret_cast<uintptr_t>(under.get()) : 0;
            }
        }
        return context;
    }

    df::FocusCause causeOf(Desktop::eFocusReason reason) {
        switch (reason) {
            case Desktop::FOCUS_REASON_UNKNOWN: return df::FocusCause::Unknown;
            case Desktop::FOCUS_REASON_FFM: return df::FocusCause::PointerFollow;
            case Desktop::FOCUS_REASON_KEYBIND: return df::FocusCause::KeyBinding;
            case Desktop::FOCUS_REASON_DISPATCH_FOCUSWINDOW: return df::FocusCause::FocusDispatch;
            case Desktop::FOCUS_REASON_DISPATCH_MOVEWINDOWINTOGROUP: return df::FocusCause::GroupDispatch;
            case Desktop::FOCUS_REASON_CLICK: return df::FocusCause::Click;
            case Desktop::FOCUS_REASON_OTHER: return df::FocusCause::Other;
            case Desktop::FOCUS_REASON_DESKTOP_STATE_CHANGE: return df::FocusCause::Activation;
            case Desktop::FOCUS_REASON_SWITCH_TO_WINDOW_SOFT: return df::FocusCause::SwitchSoft;
            case Desktop::FOCUS_REASON_SWITCH_TO_WINDOW_HARD: return df::FocusCause::SwitchHard;
            case Desktop::FOCUS_REASON_GROUP_CURRENT_WINDOW_CHANGE: return df::FocusCause::GroupCurrentChange;
            case Desktop::FOCUS_REASON_WORKSPACE_CHANGE: return df::FocusCause::WorkspaceChange;
            case Desktop::FOCUS_REASON_TOGGLE_SPECIAL_WORKSPACE: return df::FocusCause::ToggleSpecialWorkspace;
            case Desktop::FOCUS_REASON_UNMAP_WINDOW_TILING: return df::FocusCause::UnmapTiling;
            case Desktop::FOCUS_REASON_UNMAP_WINDOW_FLOATING: return df::FocusCause::UnmapFloating;
            case Desktop::FOCUS_REASON_UNMAP_GROUPED_WINDOW: return df::FocusCause::UnmapGrouped;
            case Desktop::FOCUS_REASON_NEW_WINDOW: return df::FocusCause::NewWindow;
            case Desktop::FOCUS_REASON_GHOSTS: return df::FocusCause::Ghosts;
        }
        return df::FocusCause::Unknown;
    }

    std::optional<uint64_t> SHyprlandLoop::post(const std::function<void()>& fn) {
        if (!g_pEventLoopManager)
            return std::nullopt;
        return g_pEventLoopManager->doLater(fn);
    }

    void SHyprlandLoop::remove(uint64_t seq) {
        if (g_pEventLoopManager)
            g_pEventLoopManager->removeDoLater(seq);
    }

} // namespace gf::deferredFocus
