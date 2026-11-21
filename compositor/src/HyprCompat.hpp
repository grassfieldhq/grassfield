#pragma once

// The one place where the plugin meets the differences between the Hyprland versions it builds against (docs/compat.md):
// 0.56.x (the project's target) and 0.57.x (current Arch, Omarchy). The packages never pin Hyprland and the plugin is rebuilt
// against the installed one (packaging/arch/grassfield-compositor-rebuild), so every source compiles against both. Hyprland
// has no numeric version macro: the 0.57 layout is recognised by its new workspace header (Workspace::CHLWorkspace).
// Everything here maps one API onto the other with the 0.56 behaviour; each 0.57 branch follows what Hyprland 0.57.2 itself
// does where it replaced the 0.56 call (its own sources, read for every mapping). Nothing else in the plugin tests
// GF_HYPRLAND_057: keep the version #ifs in this file.

#if __has_include(<hyprland/src/workspace/HLWorkspace.hpp>)
#define GF_HYPRLAND_057 1
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowEffectsController.hpp>
#include <hyprland/src/desktop/view/window/WindowFullscreenPolicy.hpp>
#include <hyprland/src/desktop/view/window/WindowMetadata.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/input/Keys.hpp>
#include <hyprland/src/ipc/s1/S1.hpp>
#include <hyprland/src/ipc/s2/S2.hpp>
#include <hyprland/src/render/Context.hpp>
#include <hyprland/src/render/WindowRenderPresentation.hpp>
#include <hyprland/src/render/transformer/TransformerList.hpp>
#include <hyprland/src/state/workspace/Resolver.hpp>
#include <hyprland/src/workspace/HLWorkspace.hpp>
#else
#define GF_HYPRLAND_057 0
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/helpers/MiscFunctions.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#endif

#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/ViewHitTester.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/view/Popup.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/helpers/Color.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/output/MonitorResources.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>
#include <hyprland/src/render/pass/ClearPassElement.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/render/transformer/Transformer.hpp>
#include <hyprland/src/state/WorkspaceQuery.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#include <hyprland/src/xwayland/XSurface.hpp>
#include <hyprland/src/xwayland/XWayland.hpp>

#include <algorithm>
#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <ranges>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace gf::compat {

    // ======================================================================================================== hyprctl, socket2

    // hyprctl commands (0.57: IPC::Socket1::SCommand, a handler taking the parsed request). The plugin's commands take no
    // argument and answer the same JSON in both output formats.
    using CtlReply = std::string (*)() noexcept;
#if GF_HYPRLAND_057
    using CtlCommand = IPC::Socket1::SCommand;
    inline CtlCommand ctlCommand(std::string name, CtlReply reply) {
        return CtlCommand{.name    = std::move(name),
                          .match   = IPC::Socket1::COMMAND_MATCH_EXACT,
                          .handler = [reply](const IPC::Socket1::SRequest& /*request*/) { return IPC::Socket1::SResponse{reply()}; }};
    }
#else
    using CtlCommand = SHyprCtlCommand;
    inline CtlCommand ctlCommand(std::string name, CtlReply reply) {
        return CtlCommand{.name = std::move(name), .exact = true, .fn = [reply](eHyprCtlOutputFormat /*format*/, const std::string& /*args*/) { return reply(); }};
    }
#endif

    // A socket2 event (0.57: IPC::Socket2::sock()). Nothing is posted while Hyprland shuts down (no event socket any more).
    inline void postIpcEvent(std::string event, std::string data) {
#if GF_HYPRLAND_057
        if (const auto& sock = IPC::Socket2::sock())
            sock->postEvent(IPC::Socket2::SEvent{.event = std::move(event), .data = std::move(data)});
#else
        if (g_pEventManager)
            g_pEventManager->postEvent(SHyprIPCEvent{.event = std::move(event), .data = std::move(data)});
#endif
    }

    // ================================================================================================================ windows
    // Templates over the pointer kind (PHLWINDOW, a raw CWindow*): `w` is never null here (the callers test it first).

    // The window is mapped (0.57: m_isMapped is private, mapped() returns it).
    template <typename P>
    bool mapped(const P& w) {
#if GF_HYPRLAND_057
        return w->mapped();
#else
        return w->m_isMapped;
#endif
    }

    template <typename P>
    bool isX11(const P& w) {
#if GF_HYPRLAND_057
        return w->backend().isX11();
#else
        return w->m_isX11;
#endif
    }

    // The app id ("class"). 0.57: the metadata the backend reported last.
    template <typename P>
    const std::string& appClass(const P& w) {
#if GF_HYPRLAND_057
        return w->metadata().appID();
#else
        return w->m_class;
#endif
    }

    template <typename P>
    const std::string& title(const P& w) {
#if GF_HYPRLAND_057
        return w->metadata().title();
#else
        return w->m_title;
#endif
    }

    template <typename P>
    bool isFloating(const P& w) {
#if GF_HYPRLAND_057
        return w->isFloating();
#else
        return w->m_isFloating;
#endif
    }

    template <typename P>
    bool pinned(const P& w) {
#if GF_HYPRLAND_057
        return static_cast<bool>(w->m_state & Desktop::View::WINDOW_STATE_PINNED);
#else
        return w->m_pinned;
#endif
    }

    // 0.56 m_X11ShouldntFocus (an X11 menu, an override-redirect window that wants no focus; cleared by an allowsinput rule).
    // 0.57 replaced every test of it with shouldntFocus(), the same conditions read from the backend's traits.
    template <typename P>
    bool shouldntFocus(const P& w) {
#if GF_HYPRLAND_057
        return w->shouldntFocus();
#else
        return w->m_X11ShouldntFocus;
#endif
    }

    // An X11 window Hyprland draws no border around (override-redirect, or one asking for none).
    template <typename P>
    bool x11Borderless(const P& w) {
#if GF_HYPRLAND_057
        const auto traits = w->backend().traits();
        return w->backend().isX11() && (traits.overrideRedirect || traits.suggestsNoBorder);
#else
        return w->m_isX11 && (w->isX11OverrideRedirect() || w->m_X11DoesntWantBorders);
#endif
    }

    template <typename P>
    bool x11OverrideRedirect(const P& w) {
#if GF_HYPRLAND_057
        return w->backend().isX11() && w->backend().traits().overrideRedirect;
#else
        return w->m_isX11 && w->isX11OverrideRedirect();
#endif
    }

    // An X11 modal window (0.56 tested only X11's _NET_WM_STATE_MODAL; 0.57's trait also covers xdg-dialog-v1 modals).
    template <typename P>
    bool isModal(const P& w) {
#if GF_HYPRLAND_057
        return w->backend().isX11() && w->backend().traits().modal;
#else
        return w->isModal();
#endif
    }

    // An X11 window Hyprland floats by kind: transient, with a parent, a dialog or pop-up role, or a floating window type
    // (0.56's CHyprXWaylandManager::shouldBeFloated X11 branch without its size test, read from the XWayland surface). 0.57
    // keeps that surface private to the X11 backend and exposes the whole test as the backend's suggestsFloat trait, which
    // also counts an X11 window of fixed size (min = max size hints): such a window is never tiled there (0.56: refused by
    // its size when tiled).
    template <typename P>
    bool x11FloatsByKind(const P& w) {
#if GF_HYPRLAND_057
        return w->backend().isX11() && w->backend().traits().suggestsFloat;
#else
        const auto xs = w->m_xwaylandSurface.lock();
        if (!xs)
            return true; // nothing to read: never tiled
        if (xs->m_transient || static_cast<bool>(xs->m_parent) || xs->m_role.contains("task_dialog") || xs->m_role.contains("pop-up"))
            return true;
        static constexpr std::array<std::string_view, 10> kTypes{
            "_NET_WM_WINDOW_TYPE_DIALOG",  "_NET_WM_WINDOW_TYPE_SPLASH",     "_NET_WM_WINDOW_TYPE_TOOLBAR", "_NET_WM_WINDOW_TYPE_UTILITY",
            "_NET_WM_WINDOW_TYPE_TOOLTIP", "_NET_WM_WINDOW_TYPE_POPUP_MENU", "_NET_WM_WINDOW_TYPE_DOCK",    "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU",
            "_NET_WM_WINDOW_TYPE_MENU",    "_KDE_NET_WM_WINDOW_TYPE_OVERRIDE"};
        for (const auto name : kTypes) {
            const auto it = HYPRATOMS.find(std::string{name}); // find, never operator[]: Hyprland's table is only read
            if (it != HYPRATOMS.end() && it->second != 0 && std::ranges::find(xs->m_atoms, it->second) != xs->m_atoms.end())
                return true;
        }
        return false;
#endif
    }

    // An X11 window's WM_NORMAL_HINTS (resize increments, base size); null when unknown. 0.57 exposes only the min and max
    // sizes (IWindowBackend::geometryHints): no increments there, so X11 tiles are not snapped to them.
    template <typename P>
    const xcb_size_hints_t* x11SizeHints([[maybe_unused]] const P& w) {
#if GF_HYPRLAND_057
        return nullptr;
#else
        const auto xs = w->m_xwaylandSurface.lock();
        return xs ? xs->m_sizeHints.get() : nullptr;
#endif
    }

    template <typename P>
    PHLWINDOW parentOf(const P& w) {
#if GF_HYPRLAND_057
        return w->backend().parent();
#else
        return w->parent();
#endif
    }

    // xdg-toplevel-tag-v1's tag.
    template <typename P>
    std::optional<std::string> xdgTag(const P& w) {
#if GF_HYPRLAND_057
        return w->backend().metadata().tag;
#else
        return w->xdgTag();
#endif
    }

    // The xdg_surface of a Wayland window (null for X11). 0.57 keeps it inside the backend: it is the role of the window's
    // wl_surface, as it was in 0.56 (CXDGSurfaceRole::m_xdgSurface is what m_xdgSurface pointed at).
    template <typename P>
    SP<CXDGSurfaceResource> xdgSurface(const P& w) {
#if GF_HYPRLAND_057
        if (w->backend().isX11())
            return nullptr;
        const auto surface = w->resource();
        if (!surface || !surface->m_role || surface->m_role->role() != SURFACE_ROLE_XDG_SHELL)
            return nullptr;
        return reinterpretPointerCast<CXDGSurfaceRole>(surface->m_role)->m_xdgSurface.lock();
#else
        return w->m_isX11 ? nullptr : w->m_xdgSurface.lock();
#endif
    }

    // Hyprland ignores the client's maximize requests (0.56 SUPPRESS_MAXIMIZE in m_suppressedEvents, 0.57 the fullscreen
    // policy's request suppression, where the suppress_event rule now writes it).
    template <typename P>
    bool maximizeSuppressed(const P& w) {
#if GF_HYPRLAND_057
        return w->fullscreenPolicy().requestSuppression().maximize;
#else
        return (w->m_suppressedEvents & Desktop::View::SUPPRESS_MAXIMIZE) != 0;
#endif
    }

    template <typename P>
    void setMaximizeSuppressed(const P& w, bool suppressed) {
#if GF_HYPRLAND_057
        auto s     = w->fullscreenPolicy().requestSuppression();
        s.maximize = suppressed;
        w->fullscreenPolicy().setRequestSuppression(s);
#else
        if (suppressed)
            w->m_suppressedEvents |= Desktop::View::SUPPRESS_MAXIMIZE;
        else
            w->m_suppressedEvents &= ~static_cast<uint64_t>(Desktop::View::SUPPRESS_MAXIMIZE);
#endif
    }

    template <typename P>
    Vector2D floatingOffset(const P& w) {
#if GF_HYPRLAND_057
        return w->presentation().floatingOffset();
#else
        return w->m_floatingOffset;
#endif
    }

    template <typename P>
    float rounding(const P& w) {
#if GF_HYPRLAND_057
        return w->presentation().rounding();
#else
        return w->rounding();
#endif
    }

    template <typename P>
    float roundingPower(const P& w) {
#if GF_HYPRLAND_057
        return w->presentation().roundingPower();
#else
        return w->roundingPower();
#endif
    }

    template <typename P>
    PHLANIMVAR<float>& alpha(const P& w, Desktop::View::eWindowAlpha type) {
#if GF_HYPRLAND_057
        return w->presentation().alpha(type);
#else
        return w->alpha(type);
#endif
    }

    // 0.56 updateWindowDecos(); 0.57 presentation().updateDecorations().
    template <typename P>
    void updateDecorations(const P& w) {
#if GF_HYPRLAND_057
        w->presentation().updateDecorations();
#else
        w->updateWindowDecos();
#endif
    }

    // 0.56 updateDecorationValues() (alphas, dim, border of a focus change); 0.57's focus code calls presentation().refreshValues().
    template <typename P>
    void refreshDecorationValues(const P& w) {
#if GF_HYPRLAND_057
        w->presentation().refreshValues();
#else
        w->updateDecorationValues();
#endif
    }

    // Input blocking with a reason bit of the plugin's own (one Hyprland does not use).
    template <typename P>
    void setInputBlocked(const P& w, uint8_t bit, bool blocked) {
#if GF_HYPRLAND_057
        w->setInputBlocked(static_cast<Desktop::View::eFocusBlockReason>(bit), blocked);
#else
        w->setInputBlocked(static_cast<Desktop::View::eWindowInputBlockReason>(bit), blocked);
#endif
    }

    template <typename P>
    bool noInputBlockedReasonsBesides(const P& w, uint8_t bit) {
#if GF_HYPRLAND_057
        return w->noInputBlockedReasonsBesides(Desktop::View::FocusBlockReasons{bit});
#else
        return w->noInputBlockedReasonsBesides(bit);
#endif
    }

    // ---- window decorations (0.57: shared pointers in presentation()) ----

    // A new decoration for HyprlandAPI::addWindowDecoration.
    template <typename T, typename... Args>
    auto makeDecoration(Args&&... args) {
#if GF_HYPRLAND_057
        return SP<IHyprWindowDecoration>{makeShared<T>(std::forward<Args>(args)...)};
#else
        return UP<IHyprWindowDecoration>{makeUnique<T>(std::forward<Args>(args)...)};
#endif
    }

    template <typename P>
    bool ownsDecoration(const P& w, const IHyprWindowDecoration* deco) {
#if GF_HYPRLAND_057
        return w->presentation().containsDecoration(deco);
#else
        return std::ranges::any_of(w->m_windowDecorations, [deco](const UP<IHyprWindowDecoration>& d) { return d.get() == deco; });
#endif
    }

    // Destroys one of `w`'s decorations now, whatever the window's state. 0.56: HyprlandAPI::removeWindowDecoration only
    // queues the removal and CWindow::updateWindowDecos() returns at once for an unmapped or hidden window, so this does what
    // it does for a queued removal without that early return (a decoration surviving dlclose). 0.57's updateDecorations()
    // erases the queued removals before that return: its own removal is immediate.
    inline bool destroyDecorationNow(const PHLWINDOW& w, IHyprWindowDecoration* deco) {
#if GF_HYPRLAND_057
        if (!w->presentation().containsDecoration(deco))
            return false;
        w->presentation().removeDecoration(deco);
        return !w->presentation().containsDecoration(deco);
#else
        auto&      decos = w->m_windowDecorations;
        const auto it    = std::ranges::find_if(decos, [deco](const UP<IHyprWindowDecoration>& d) { return d.get() == deco; });
        if (it == decos.end())
            return false;
        std::erase(w->m_decosToRemove, deco);
        if (g_pDecorationPositioner)
            g_pDecorationPositioner->uncacheDecoration(deco); // pointer comparison only; deco still alive
        UP<IHyprWindowDecoration> owned = std::move(*it);
        decos.erase(it);
        owned.reset(); // its destructor runs here, while this library is still loaded
        if (g_pDecorationPositioner)
            g_pDecorationPositioner->forceRecalcFor(w);
        return true;
#endif
    }

    // ================================================================================================ layers, views, input

    // 0.57: m_mapped is private; mapped() is it with the surface checks 0.56's visible() made (true together in practice).
    template <typename P>
    bool layerMapped(const P& ls) {
#if GF_HYPRLAND_057
        return ls->mapped();
#else
        return ls->m_mapped;
#endif
    }

    // The keyboard interactivity a layer asked for (zwlr_layer_surface_v1, 0: none, 1: exclusive, 2: on demand).
    inline uint32_t keyboardInteractivity(const SP<CLayerShellResource>& resource) {
#if GF_HYPRLAND_057
        return static_cast<uint32_t>(resource->m_current.keyboardInteractivity);
#else
        return static_cast<uint32_t>(resource->m_current.interactivity);
#endif
    }

    // 0.56 IView::aliveAndVisible(): a mapped surface and the view's visible(). 0.57 split visible() into mapped(),
    // focusAvailable() (a hidden window, a popup or subsurface of a window not rendered) and a non-zero alpha, and tests
    // these where 0.56 called aliveAndVisible() (View::getViewsForWorkspace, CWLSurface::small).
    inline bool aliveAndVisible(const SP<Desktop::View::IView>& view) {
#if GF_HYPRLAND_057
        const auto res = view->resource();
        if (!res || !res->m_mapped || !view->mapped() || !view->focusAvailable())
            return false;
        const auto alpha = dynamicPointerCast<Desktop::View::IAlphaModifiable>(view);
        return !alpha || alpha->alphaNonZero();
#else
        return view->aliveAndVisible();
#endif
    }

    // Hyprland's list of mapped layers holding the keyboard exclusively (0.57 renamed it).
    inline const std::vector<PHLLSREF>& exclusiveLayers() {
#if GF_HYPRLAND_057
        return g_pInputManager->m_exclusiveKeyboardLSes;
#else
        return g_pInputManager->m_exclusiveLSes;
#endif
    }

    // The popup of one of `layers` (topmost first) under `pos`, as 0.56's CViewHitTester::layerPopupSurfaceAt over a layer
    // list. 0.57 has only the per-monitor variant; this is its loop over the list, with the layer test 0.57 uses there
    // (mapped() and acceptsInput(), its replacement of aliveAndVisible()).
    inline SP<CWLSurfaceResource> layerPopupSurfaceAt(const Vector2D& pos, const std::vector<PHLLSREF>& layers, Vector2D* surfaceCoords, PHLLS* layerFound) {
#if GF_HYPRLAND_057
        for (const auto& ls : layers | std::views::reverse) {
            if (!ls || !ls->mapped() || !ls->acceptsInput() || !ls->popupHead())
                continue;
            if (const auto at = ls->popupHead()->at(pos, true)) {
                *layerFound    = ls.lock();
                *surfaceCoords = pos - at->coordsGlobal();
                return at->wlSurface()->resource();
            }
        }
        return nullptr;
#else
        if (!Desktop::viewState())
            return nullptr;
        return Desktop::viewState()->hitTest().layerPopupSurfaceAt(pos, &layers, surfaceCoords, layerFound);
#endif
    }

    // Modifier bits, the same values in both (0.56 eKeyboardModifiers, 0.57 Input::eKeyboardModifiers).
#if GF_HYPRLAND_057
    inline constexpr uint32_t kModShift = std::to_underlying(Input::HL_MODIFIER_SHIFT);
    inline constexpr uint32_t kModCtrl  = std::to_underlying(Input::HL_MODIFIER_CTRL);
    inline constexpr uint32_t kModAlt   = std::to_underlying(Input::HL_MODIFIER_ALT);
    inline constexpr uint32_t kModMeta  = std::to_underlying(Input::HL_MODIFIER_META);
#else
    inline constexpr uint32_t kModShift = HL_MODIFIER_SHIFT;
    inline constexpr uint32_t kModCtrl  = HL_MODIFIER_CTRL;
    inline constexpr uint32_t kModAlt   = HL_MODIFIER_ALT;
    inline constexpr uint32_t kModMeta  = HL_MODIFIER_META;
#endif

    // The modifiers held on every keyboard (0 without an input manager).
    inline uint32_t heldModifiers() {
        if (!g_pInputManager)
            return 0;
#if GF_HYPRLAND_057
        return static_cast<uint32_t>(g_pInputManager->getModsFromAllKBs());
#else
        return g_pInputManager->getModsFromAllKBs();
#endif
    }

    // 0.57 made the focus reasons bits and splits a click into CLICK_DOWN and CLICK_UP (both with the CLICK bit): those are
    // the 0.56 CLICK.
    inline Desktop::eFocusReason baseFocusReason(Desktop::eFocusReason reason) {
#if GF_HYPRLAND_057
        if ((static_cast<uint32_t>(reason) & static_cast<uint32_t>(Desktop::FOCUS_REASON_CLICK)) != 0)
            return Desktop::FOCUS_REASON_CLICK;
#endif
        return reason;
    }

    // ============================================================================================================= workspaces
    // The plugin names a workspace by a 64-bit id, as 0.56 did (positive: a numbered Desktop). 0.57 numbers only the
    // numbered workspaces; a named or special one (no number any more) gets a negative id made from its address, stable
    // while it lives, as 0.56 gave such workspaces negative ids.

    template <typename P>
    int64_t workspaceId(const P& ws) {
#if GF_HYPRLAND_057
        if (const auto n = ws->numberedID())
            return static_cast<int64_t>(*n);
        return -1 - static_cast<int64_t>(std::hash<std::string>{}(ws->addressableName()) & 0x3fffffffffffULL);
#else
        return ws->m_id;
#endif
    }

    template <typename P>
    bool isSpecial(const P& ws) {
#if GF_HYPRLAND_057
        return ws->type() == ::Workspace::eWorkspaceType::SPECIAL;
#else
        return ws->m_isSpecialWorkspace;
#endif
    }

    // The name Hyprland addresses it by ("1", "special:minimized"): 0.56 m_name, 0.57 addressableName().
    template <typename P>
    const std::string& workspaceName(const P& ws) {
#if GF_HYPRLAND_057
        return ws->addressableName();
#else
        return ws->m_name;
#endif
    }

    template <typename P>
    bool workspaceVisible(const P& ws) {
#if GF_HYPRLAND_057
        return ws->visible();
#else
        return ws->isVisible();
#endif
    }

    template <typename P>
    PHLWINDOW lastFocusedWindow(const P& ws) {
#if GF_HYPRLAND_057
        return ws->getLastFocusedWindow();
#else
        return ws->m_lastFocusedWindow.lock();
#endif
    }

    template <typename P>
    SP<Layout::CSpace> spaceOf(const P& ws) {
#if GF_HYPRLAND_057
        return ws->space();
#else
        return ws->m_space;
#endif
    }

    // The live workspace with this id (workspaceId), or null.
    inline PHLWORKSPACE workspaceById(int64_t id) {
        if (!State::workspaceState())
            return nullptr;
#if GF_HYPRLAND_057
        if (id > 0 && id <= static_cast<int64_t>(UINT32_MAX))
            return State::workspaceState()->query().numbered(::Workspace::SWorkspaceNumberedID{static_cast<::Workspace::WorkspaceIDContainer>(id)}).run();
        for (const auto& ws : State::workspaceState()->workspacesCopy()) {
            if (ws && workspaceId(ws) == id)
                return ws;
        }
        return nullptr;
#else
        return State::workspaceState()->query().id(id).run();
#endif
    }

    // A new numbered workspace (a Desktop) on `monitor`; null when Hyprland makes none.
    inline PHLWORKSPACE createNumberedWorkspace(int64_t id, const PHLMONITOR& monitor) {
        if (!State::workspaceState() || !monitor)
            return nullptr;
#if GF_HYPRLAND_057
        if (id <= 0 || id > static_cast<int64_t>(UINT32_MAX))
            return nullptr;
        return State::workspaceState()->createNumbered(::Workspace::SWorkspaceNumberedID{static_cast<::Workspace::WorkspaceIDContainer>(id)}, monitor);
#else
        return State::workspaceState()->create(id, monitor->m_id);
#endif
    }

    // The workspace named by `selector` ("special:minimized"), created on `monitor` (not empty) when it does not exist and a
    // monitor is given. 0.56: getWorkspaceIDNameFromString, a query by id, create(id, monitor, name); 0.57: the resolver's
    // target for the same string, find(), create().
    inline PHLWORKSPACE findOrCreateWorkspace(const std::string& selector, const PHLMONITOR& monitor) {
        if (!State::workspaceState())
            return nullptr;
#if GF_HYPRLAND_057
        const auto& resolver = State::Workspace::resolver();
        if (!resolver)
            return nullptr;
        const auto target = resolver->getWorkspaceTargetFromString(selector);
        if (!target.valid())
            return nullptr;
        auto ws = State::workspaceState()->find(target);
        if (!ws && monitor)
            ws = State::workspaceState()->create(target, monitor, false);
        return ws;
#else
        const auto [id, name, isAutoID] = getWorkspaceIDNameFromString(selector);
        if (id == WORKSPACE_INVALID)
            return nullptr;
        auto ws = State::workspaceState()->query().id(id).run();
        if (!ws && monitor)
            ws = State::workspaceState()->create(id, monitor->m_id, name, false);
        return ws;
#endif
    }

    // ============================================================================================================== rendering
    // 0.57 passes an explicit render context (Render::CRenderContext) where 0.56 kept the render state in the renderer
    // (m_renderData, m_renderPass, m_bRenderingSnapshot). The plugin passes a RenderContext everywhere; in 0.56 it is an empty
    // tag and every call reads the renderer's state as before.

#if GF_HYPRLAND_057
    using RenderContext = Render::CRenderContext;
    // The renderer's own context, for code that runs outside a render callback (a context-less stage, an unload).
    inline RenderContext& rendererContext() {
        return g_pHyprRenderer->context();
    }
    inline Render::SRenderData& renderData(RenderContext& ctx) {
        return ctx.m_data;
    }
    inline bool renderingSnapshot(RenderContext& ctx) {
        return ctx.m_renderingSnapshot;
    }
    inline void addPassElement(RenderContext& ctx, UP<IPassElement>&& element) {
        Render::IHyprRenderer::addPassElement(ctx, std::move(element));
    }
    template <typename Data>
    void draw(RenderContext& ctx, const Data& data, const CRegion& damage = {}) {
        g_pHyprRenderer->draw(ctx, data, damage);
    }
    inline Mat3x3 projectBoxToTarget(RenderContext& ctx, const CBox& box, std::optional<eTransform> transform = std::nullopt) {
        return g_pHyprRenderer->projectBoxToTarget(ctx, box, transform);
    }
    inline void scissor(RenderContext& ctx, const pixman_box32_t* rect) {
        Render::GL::g_pHyprOpenGL->scissor(ctx, rect);
    }
    // Hyprland's premultiplied blend; 0.57 caches the blend function, so it is set through it.
    inline void blendPremultiplied() {
        Render::GL::g_pHyprOpenGL->blendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    }
#else
    struct RenderContext {};
    inline RenderContext& rendererContext() {
        static RenderContext ctx;
        return ctx;
    }
    inline Render::SRenderData& renderData(RenderContext& /*ctx*/) {
        return g_pHyprRenderer->m_renderData;
    }
    inline bool renderingSnapshot(RenderContext& /*ctx*/) {
        return g_pHyprRenderer->m_bRenderingSnapshot;
    }
    inline void addPassElement(RenderContext& /*ctx*/, UP<IPassElement>&& element) {
        g_pHyprRenderer->addPassElement(std::move(element));
    }
    template <typename Data>
    void draw(RenderContext& /*ctx*/, const Data& data, const CRegion& damage = {}) {
        g_pHyprRenderer->draw(data, damage);
    }
    inline Mat3x3 projectBoxToTarget(RenderContext& /*ctx*/, const CBox& box, std::optional<eTransform> transform = std::nullopt) {
        return g_pHyprRenderer->projectBoxToTarget(box, transform);
    }
    inline void scissor(RenderContext& /*ctx*/, const pixman_box32_t* rect) {
        Render::GL::g_pHyprOpenGL->scissor(rect);
    }
    inline void blendPremultiplied() {
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    }
#endif

    // The context of the draw in progress: set by the adapters below (a decoration's or a pass element's draw, a
    // transformer, a render stage listener) for everything they call, so that the plugin's drawing helpers need no context
    // parameter; the renderer's own outside them.
    inline RenderContext*& currentContextSlot() {
        static RenderContext* ctx = nullptr;
        return ctx;
    }
    inline RenderContext& currentContext() {
        auto* ctx = currentContextSlot();
        return ctx ? *ctx : rendererContext();
    }
    class CCurrentContext {
      public:
        explicit CCurrentContext(RenderContext& ctx) : m_previous(currentContextSlot()) {
            currentContextSlot() = &ctx;
        }
        ~CCurrentContext() {
            currentContextSlot() = m_previous;
        }
        CCurrentContext(const CCurrentContext&)            = delete;
        CCurrentContext& operator=(const CCurrentContext&) = delete;
        CCurrentContext(CCurrentContext&&)                 = delete;
        CCurrentContext& operator=(CCurrentContext&&)      = delete;

      private:
        RenderContext* m_previous;
    };

    // The monitor being rendered.
    inline PHLMONITOR renderMonitor(RenderContext& ctx = currentContext()) {
        return renderData(ctx).pMonitor.lock();
    }

    // Queues a pass element in the current draw.
    inline void addPassElement(UP<IPassElement>&& element) {
        addPassElement(currentContext(), std::move(element));
    }

    // A snapshot's texture (a framebuffer's, upside down in 0.56: flipEndFrame, as Hyprland drew its fadeouts). 0.57 draws
    // its fadeouts' snapshot textures without any flag (the field is gone).
    inline void markFramebufferTexture([[maybe_unused]] CTexPassElement::SRenderData& data) {
#if !GF_HYPRLAND_057
        data.flipEndFrame = true;
#endif
    }

    // Removes the plugin's queued pass elements of one kind (passName) from the render passes (an unload).
    inline void removeQueuedPassElements(const std::string& passName) {
        if (!g_pHyprRenderer)
            return;
#if GF_HYPRLAND_057
        auto& ctx = g_pHyprRenderer->context();
        ctx.m_pass.removeAllOfType(passName);
        if (ctx.m_currentPass && ctx.m_currentPass != &ctx.m_pass)
            ctx.m_currentPass->removeAllOfType(passName);
#else
        g_pHyprRenderer->m_renderPass.removeAllOfType(passName);
        if (auto& current = g_pHyprRenderer->currentPass(); &current != &g_pHyprRenderer->m_renderPass)
            current.removeAllOfType(passName);
#endif
    }

    // A render stage listener: fn(stage, ctx), ctx null where 0.57 has no context (RENDER_PRE, RENDER_POST); the current
    // context while fn runs.
    template <typename Fn>
    CHyprSignalListener onRenderStage(Fn fn) {
#if GF_HYPRLAND_057
        return Event::bus()->m_events.render.stage.listen([fn](const Event::SRenderStageEvent& e) {
            if (!e.context) {
                fn(e.stage, static_cast<RenderContext*>(nullptr));
                return;
            }
            const CCurrentContext current{e.context->get()};
            fn(e.stage, &e.context->get());
        });
#else
        return Event::bus()->m_events.render.stage.listen([fn](eRenderStage stage) { fn(stage, &rendererContext()); });
#endif
    }

    // Draws into `fb` (a buffer covering the monitor being rendered, Hyprland's own work buffers' size) with `damage` as the
    // render damage, and puts back the target, the damage and (0.57) the projection afterwards. 0.56: the monitor projection
    // the renderer has during a frame; 0.57: a transformer runs with the window's canvas projection, so the monitor's pixel
    // space is set (RPT_EXPORT over the buffer's size, as Hyprland's own transformers draw).
    class CCanvasScope {
      public:
        CCanvasScope(RenderContext& ctx, const SP<Render::IFramebuffer>& fb, const CRegion& damage) :
#if GF_HYPRLAND_057
            m_bindings(g_pHyprRenderer->glBackend()), m_state(ctx.saveDrawState()) {
            g_pHyprRenderer->bindFB(ctx, fb);
            ctx.m_data.damage = damage;
            ctx.m_data.fbSize = fb->m_size;
            g_pHyprRenderer->setProjectionType(ctx, Render::RPT_EXPORT);
        }
#else
            m_saved(g_pHyprRenderer->m_renderData.damage.copy()) {
            (void)ctx;
            g_pHyprRenderer->m_renderData.damage = damage;
            m_guard                               = g_pHyprRenderer->bindTempFB(fb);
        }
        ~CCanvasScope() {
            m_guard.reset();
            g_pHyprRenderer->m_renderData.damage = m_saved;
        }
#endif
        CCanvasScope(const CCanvasScope&)            = delete;
        CCanvasScope& operator=(const CCanvasScope&) = delete;
        CCanvasScope(CCanvasScope&&)                 = delete;
        CCanvasScope& operator=(CCanvasScope&&)      = delete;

      private:
#if GF_HYPRLAND_057
        Render::GL::CFramebufferBindingGuard m_bindings;
        Render::CRenderDataScope             m_state;
#else
        CRegion                           m_saved;
        UP<Hyprutils::Utils::CScopeGuard> m_guard;
#endif
    };

    // ---- pass elements: the plugin's own draws (0.57 passes the context to every method) ----
    class CPassElementBase : public IPassElement {
      public:
        virtual void                drawGf()        = 0; // with the current context
        virtual std::optional<CBox> boundingBoxGf() = 0;

#if GF_HYPRLAND_057
        std::vector<UP<IPassElement>> draw(Render::CRenderContext& ctx) override {
            const CCurrentContext current{ctx};
            drawGf();
            return {};
        }
        bool needsLiveBlur(Render::CRenderContext& /*ctx*/) override {
            return false;
        }
        bool needsPrecomputeBlur(Render::CRenderContext& /*ctx*/) override {
            return false;
        }
        std::optional<CBox> boundingBox(Render::CRenderContext& /*ctx*/) override {
            return boundingBoxGf();
        }
        CRegion opaqueRegion(Render::CRenderContext& /*ctx*/) override {
            return {};
        }
#else
        std::vector<UP<IPassElement>> draw() override {
            drawGf();
            return {};
        }
        bool needsLiveBlur() override {
            return false;
        }
        bool needsPrecomputeBlur() override {
            return false;
        }
        std::optional<CBox> boundingBox() override {
            return boundingBoxGf();
        }
        CRegion opaqueRegion() override {
            return {};
        }
#endif
    };

    // ---- window decorations: draw() got the context and the window's render presentation in 0.57 ----
    class CDecorationBase : public IHyprWindowDecoration {
      public:
        explicit CDecorationBase(PHLWINDOW w) : IHyprWindowDecoration(std::move(w)) {}
        virtual void drawGf(PHLMONITOR monitor, float alpha) = 0; // with the current context

#if GF_HYPRLAND_057
        void draw(Render::CRenderContext& ctx, PHLMONITOR monitor, float const& alpha, const Render::SWindowRenderPresentation& /*presentation*/) override {
            const CCurrentContext current{ctx};
            drawGf(std::move(monitor), alpha);
        }
#else
        void draw(PHLMONITOR monitor, float const& alpha) override {
            drawGf(std::move(monitor), alpha);
        }
#endif
    };

    // ---- window transformers ----
    // The plugin's transformers draw a window, given as the pixels Hyprland rendered of it, elsewhere on its monitor.
    // 0.56: the input is a monitor-sized buffer with the window at its real place and the output another monitor-sized one.
    // 0.57: the input is a canvas around the window (`box`: the monitor pixels it covers), the output a buffer with the
    // monitor pixels it covers, and Hyprland clips and damages the result with transformedExtents().
    struct STransformInput {
        RenderContext*           ctx = nullptr;
        SP<Render::IFramebuffer> fb;
        CBox                     box; // monitor pixels (before the monitor's transform) that `fb` covers
        PHLMONITOR               monitor;
    };
    struct STransformOutput {
        SP<Render::IFramebuffer> fb; // null: nothing is drawn for the window (0.57; 0.56 never returns null)
        CBox                     box;
    };

    // The pixels of `monitor`'s frame (its work buffers' size).
    inline CBox monitorPixels(const PHLMONITOR& monitor) {
        return CBox{0, 0, monitor->m_transformedSize.x, monitor->m_transformedSize.y};
    }

    // `fb` is still one of `monitor`'s work buffers (its size, format and colour description): not after a mode, format or
    // colour change. 0.56 compares with the monitor's blur buffer, made with the pool's parameters; 0.57 shrinks that buffer
    // to 1x1 while blur is off (CMonitorResources::refreshBlurFB), so the size is the monitor's frame there and the format and
    // description still the blur buffer's (made, and updated, with the pool's).
    inline bool workBufferFits(const SP<Render::IFramebuffer>& fb, const PHLMONITOR& monitor) {
        const auto resources = monitor->resources();
        if (!resources || resources.expired() || !resources->m_blurFB)
            return false;
        const auto& ref = resources->m_blurFB;
#if GF_HYPRLAND_057
        return fb->m_size == monitor->m_transformedSize && fb->m_drmFormat == ref->m_drmFormat && fb->imageDescription() == ref->imageDescription();
#else
        return fb->m_size == ref->m_size && fb->m_drmFormat == ref->m_drmFormat && fb->imageDescription() == ref->imageDescription();
#endif
    }

    class CTransformerBase : public Render::IWindowTransformer {
      public:
        // Draws `in`; may return `in` itself (0.56: drawn as it is).
        virtual STransformOutput transformGf(const STransformInput& in) = 0;
        // Where the output can draw, monitor-local logical, for the window's own monitor (`currentBox`: the window's box there).
        virtual CBox extentsGf(const CBox& currentBox) const = 0;

        // Detached: Hyprland drops it (0.57 removes inactive transformers; 0.56 erases it at once).
        void deactivate() {
            m_active = false;
        }

#if GF_HYPRLAND_057
        Render::SWindowTransformBuffer transform(Render::CRenderContext& ctx, const Render::SWindowTransformBuffer& in, const Render::SWindowTransformContext& context) override {
            if (!m_active || context.standalone || context.renderingSnapshot || !in.framebuffer)
                return in;
            const CCurrentContext current{ctx};
            const auto            out = transformGf(STransformInput{.ctx = &ctx, .fb = in.framebuffer, .box = in.box, .monitor = context.monitor.lock()});
            if (!out.fb)
                return Render::SWindowTransformBuffer{.framebuffer = nullptr, .box = {}, .success = false};
            return Render::SWindowTransformBuffer{.framebuffer = out.fb, .box = out.box, .success = true};
        }
        bool active() const override {
            return m_active;
        }
        CBox transformedExtents(const CBox& currentBox) const override {
            return m_active ? extentsGf(currentBox) : currentBox;
        }
#else
        SP<Render::IFramebuffer> transform(SP<Render::IFramebuffer> in) override {
            if (!in || !g_pHyprRenderer)
                return in;
            const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
            const auto out = transformGf(STransformInput{.ctx = &rendererContext(), .fb = in, .box = mon ? monitorPixels(mon) : CBox{}, .monitor = mon});
            return out.fb ? out.fb : in;
        }
#endif

      private:
        bool m_active = true;
    };

    // The window is drawn by Hyprland's normal path for a monitor frame: not a snapshot, not a capture (0.56: the projection
    // of a monitor frame; 0.57 calls transformers only for those, CTransformerBase::transform).
    inline bool monitorFrame([[maybe_unused]] RenderContext& ctx) {
#if GF_HYPRLAND_057
        return g_pHyprRenderer != nullptr;
#else
        return g_pHyprRenderer && !g_pHyprRenderer->m_bRenderingSnapshot && g_pHyprRenderer->m_renderData.projectionType == Render::RPT_MONITOR;
#endif
    }

    // Attaches a new transformer of type T (a CTransformerBase) to `w`; owned by the window.
    template <typename T>
    T* attachTransformer(const PHLWINDOW& w) {
#if GF_HYPRLAND_057
        return w->effects().transformers()->template emplace<T>();
#else
        auto transformer = makeUnique<T>();
        T*   raw         = transformer.get();
        w->m_transformers.emplace_back(std::move(transformer));
        return raw;
#endif
    }

    inline void detachTransformer(const PHLWINDOW& w, CTransformerBase* transformer) {
        transformer->deactivate();
#if GF_HYPRLAND_057
        w->effects().transformers()->removeInactive();
#else
        std::erase_if(w->m_transformers, [transformer](const UP<Render::IWindowTransformer>& t) { return t.get() == transformer; });
#endif
    }

    // The window has a transformer (the plugin's or Hyprland's own).
    template <typename P>
    bool hasTransformers(const P& w) {
#if GF_HYPRLAND_057
        return w->effects().hasActiveTransformers();
#else
        return !w->m_transformers.empty();
#endif
    }

    // A transformer's fallback when it has no buffer to draw into: 0.56 clears the bound buffer (the window's) whole and
    // returns it; 0.57 draws nothing.
    inline STransformOutput drawNothingFallback(RenderContext& ctx, const STransformInput& in) {
#if GF_HYPRLAND_057
        (void)ctx;
        (void)in;
        return {};
#else
        const auto mon = renderMonitor(ctx);
        if (!mon)
            return {.fb = in.fb, .box = in.box};
        const CRegion whole{CBox{0, 0, mon->m_transformedSize.x, mon->m_transformedSize.y}};
        const CRegion saved                  = g_pHyprRenderer->m_renderData.damage.copy();
        g_pHyprRenderer->m_renderData.damage = whole;
        g_pHyprRenderer->draw(CClearPassElement::SClearData{CHyprColor(0, 0, 0, 0)});
        g_pHyprRenderer->m_renderData.damage = saved;
        return {.fb = in.fb, .box = in.box};
#endif
    }

} // namespace gf::compat
