// grassfield-compositor: Hyprland plugin entry points (master-prompt §5.6, R13).
//
// Load ONLY into the nested dev instance (scripts/dev/nested-up.sh). On a Hyprland/plugin ABI
// mismatch the plugin refuses to hook anything and notifies once; the shell then falls back to
// its degraded mode because no `grassfield` capabilities event is ever posted.

#include "AppmenuServer.hpp"
#include "ClientChrome.hpp"
#include "CursorRefresh.hpp"
#include "DesktopFocus.hpp"
#include "FrameProbe.hpp"
#include "Ipc.hpp"
#include "LayerPointer.hpp"
#include "Minimize.hpp"
#include "Overview.hpp"
#include "OverviewFocus.hpp"
#include "Plugin.hpp"
#include "Stages.hpp"
#include "Tiling.hpp"
#include "Titlebar.hpp"
#include "TopClamp.hpp"
#include "ToplevelDrag.hpp"
#include "WindowRim.hpp"
#include "core/Notices.hpp"

#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/helpers/Color.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/plugins/PluginSystem.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

namespace gf {
    SPluginState& state() {
        static SPluginState s;
        return s;
    }

    void forgetRegisteredDecoration(IHyprWindowDecoration* deco) noexcept {
        guarded("forgetRegisteredDecoration", [deco] {
            if (!g_pPluginSystem || !state().handle)
                return;
            if (auto* plugin = g_pPluginSystem->getPluginByHandle(state().handle))
                std::erase(plugin->m_registeredDecorations, deco);
        });
    }
} // namespace gf

namespace {
    using gf::state;

    CGrassfieldTitlebar* titlebarFor(const PHLWINDOW& w) {
        if (!w)
            return nullptr;
        for (auto* deco : state().titlebars) {
            if (deco->window() == w)
                return deco;
        }
        return nullptr;
    }

    bool hasRim(const PHLWINDOW& w) {
        return w && std::ranges::any_of(state().rims, [&w](const CGrassfieldRim* deco) { return deco->window() == w; });
    }

    // Every mapped window gets the plugin's titlebar (shown or not, CGrassfieldTitlebar::shouldShow) and its rim (drawn in
    // the dark appearance only, core/WindowRim.hpp).
    void decorate(const PHLWINDOW& w) {
        if (!w || !w->m_isMapped)
            return;
        if (!titlebarFor(w) && !HyprlandAPI::addWindowDecoration(state().handle, w, makeUnique<CGrassfieldTitlebar>(w)))
            gf::log(Log::WARN, "addWindowDecoration failed for window {:x}", reinterpret_cast<uintptr_t>(w.get()));
        if (!hasRim(w) && !HyprlandAPI::addWindowDecoration(state().handle, w, makeUnique<CGrassfieldRim>(w)))
            gf::log(Log::WARN, "addWindowDecoration (rim) failed for window {:x}", reinterpret_cast<uintptr_t>(w.get()));
    }

    void refreshFor(const PHLWINDOW& w) {
        if (auto* deco = titlebarFor(w))
            deco->refresh();
    }

    void registerListeners() {
        auto& bus = Event::bus();
        if (!bus)
            throw std::runtime_error("event bus unavailable");

        auto& ev = bus->m_events;
        auto& l  = state().listeners;

        l.push_back(ev.window.open.listen([](const PHLWINDOW& w) { gf::guarded("window.open", [&] { decorate(w); }); }));
        l.push_back(ev.window.floating.listen([](const PHLWINDOW& w) { gf::guarded("window.floating", [&] { refreshFor(w); }); }));
        l.push_back(ev.window.fullscreen.listen([](const PHLWINDOW& w) { gf::guarded("window.fullscreen", [&] { refreshFor(w); }); }));
        l.push_back(ev.window.updateRules.listen([](const PHLWINDOW& w) { gf::guarded("window.updateRules", [&] { refreshFor(w); }); }));
        l.push_back(ev.window.active.listen([](const PHLWINDOW& w, Desktop::eFocusReason /*reason*/) {
            CGrassfieldTitlebar::onActiveWindowChanged(w);
            CGrassfieldRim::onActiveWindowChanged(w);
        }));
        l.push_back(ev.window.title.listen([](const PHLWINDOW& w) {
            gf::guarded("window.title", [&] {
                if (auto* deco = titlebarFor(w))
                    deco->onTitleChanged();
            });
        }));
        l.push_back(ev.input.mouse.move.listen([](Vector2D /*pos*/, Event::SCallbackInfo& /*info*/) {
            // The first motion of one of Hyprland's drags: the window's box before it moved (FR56).
            gf::guarded("top clamp motion", [] { gf::topClamp::beforePointerMotion(); });
            // One of Hyprland's resizes of a tiled window keeps its record (Resizing); one of its moves shows the tiling preview
            // and takes a tiled window out of its tile at its size from before (tiling.md TL10, TL16).
            gf::guarded("tiling motion", [] { gf::tiler::beforePointerMotion(); });
            // A drag of a shared edge's handle holds the pointer (TL30): no titlebar hover or press tracking meanwhile (the
            // press was the plugin's, so Hyprland counts no held button).
            if (!gf::tiler::edgeOwnsPointer())
                CGrassfieldTitlebar::onGlobalMouseMove();
        }));
        // The zoom light's hover starts over across the session lock (tiling.md TL22, D24; integrator nested rerun of 25e757c).
        if (g_pSessionLockManager) {
            l.push_back(g_pSessionLockManager->m_events.lock.listen([] { CGrassfieldTitlebar::onSessionLock(true); }));
            l.push_back(g_pSessionLockManager->m_events.unlock.listen([] { CGrassfieldTitlebar::onSessionLock(false); }));
        }
        // Button events are observed, never cancelled (FR13): Hyprland must process every release to keep
        // its held-button state, which pins pointer focus while a button is down. Stages first: a pointer focus
        // left on a strip window (input blocked, no motion since) moves to the surface under the cursor before
        // anything else sees the press (R13 review of 46b3e9b). Two exceptions: a press on the revealed titlebar of a
        // full-screen window and the release of that press are cancelled together (ADR-0015 P6), and so are a press on a
        // shared edge's handle and its release (tiling.md TL30): Hyprland returns before its held-button state for a
        // cancelled event, so the pair leaves it unchanged.
        l.push_back(ev.input.mouse.button.listen([](IPointer::SButtonEvent e, Event::SCallbackInfo& info) {
            // A shell layer mapped or took the keyboard under the resting pointer and its pointer focus is not refreshed yet
            // (a button was held, no pointer device, or the press came in the same event loop pass): a press is delivered
            // at the right place, a release schedules the refresh after Hyprland handled it (FR51).
            gf::guarded("layer pointer press", [&] { gf::layerPointer::beforePointerButton(e.state == WL_POINTER_BUTTON_STATE_PRESSED); });
            gf::guarded("stages pointer guard", [&] { gf::stager::beforePointerButton(e.state == WL_POINTER_BUTTON_STATE_PRESSED); });
            // A press after an overview focus request wins over the target the shell named (recorded only).
            gf::guarded("overview focus press", [&] { gf::overviewFocus::beforePointerButton(e.state == WL_POINTER_BUTTON_STATE_PRESSED); });
            // A press on a zoomed window that draws its own chrome, recorded while it is still zoomed: the app's move request
            // that may follow takes it out of the zoom under the pointer (ADR-0015 P4).
            gf::guarded("client chrome press", [&] { gf::chrome::beforePointerButton(e.state == WL_POINTER_BUTTON_STATE_PRESSED); });
            // The release that ends one of Hyprland's own moves or resizes (an app's move request, a mouse binding): the
            // window's titlebar is held below the menu bar once Hyprland ended the drag (macOS).
            gf::guarded("top clamp release", [&] { gf::topClamp::beforePointerButton(e.state == WL_POINTER_BUTTON_STATE_PRESSED); });
            // After the top clamp's (its callback runs first): a resize of a tiled window ends with the box it left; a move
            // released over the place shown tiles there (the top clamp skipped); a double-click on a resize border extends the
            // window's sides (tiling.md TL16, TL20). The second exception to FR13: a plain left press on a shared edge's
            // handle and the release of that press are the plugin's drag (TL30), cancelled together like P6's.
            bool edge = false;
            gf::guarded("tiling button", [&] { edge = gf::tiler::beforePointerButton(e.button, e.state == WL_POINTER_BUTTON_STATE_PRESSED, e.timeMs); });
            if (edge) {
                info.cancelled = true;
                return;
            }
            CGrassfieldTitlebar::onGlobalMouseButton(e);
            if (CGrassfieldTitlebar::onRevealedBarButton(e))
                info.cancelled = true;
        }));
        // The revealed titlebar of a full-screen window: Hyprland draws no decoration in full screen (P6).
        l.push_back(ev.render.stage.listen([](eRenderStage stage) {
            if (stage == RENDER_POST_WINDOWS)
                CGrassfieldTitlebar::drawRevealed();
        }));
        // Keys are observed, never cancelled: Alt changes the zoom glyph of the hovered lights (ADR-0015 P6) and the place of a
        // drag (tiling.md TL17, TL18).
        l.push_back(ev.input.keyboard.key.listen([](IKeyboard::SKeyEvent e, Event::SCallbackInfo& info) {
            gf::keyPath("titlebar key", [](const IKeyboard::SKeyEvent& /*e*/, Event::SCallbackInfo& /*info*/) { CGrassfieldTitlebar::onKey(); }, e, info);
            gf::keyPath("tiling key", [](const IKeyboard::SKeyEvent& /*e*/, Event::SCallbackInfo& /*info*/) { gf::tiler::onKey(); }, e, info);
        }));
    }

    // The window whose m_windowDecorations owns `deco` (normally its own window, `hint`; scanned as a fallback).
    PHLWINDOW ownerOf(const IHyprWindowDecoration* deco, const PHLWINDOW& hint) {
        const auto owns = [deco](const PHLWINDOW& w) {
            return w && std::ranges::any_of(w->m_windowDecorations, [deco](const UP<IHyprWindowDecoration>& d) { return d.get() == deco; });
        };
        if (owns(hint))
            return hint;
        for (const auto& w : Desktop::windowState()->windows()) {
            if (owns(w))
                return w;
        }
        return nullptr;
    }

    // Destroys one of the plugin's decorations (a titlebar or a rim) now, whatever its window's state.
    // HyprlandAPI::removeWindowDecoration only queues the removal (CWindow::m_decosToRemove) and runs
    // CWindow::updateWindowDecos(), which in 0.56.2 returns at once for an unmapped or hidden window (it tests m_isMapped,
    // then isHidden(); read from the binary): such a decoration would survive dlclose. This does what updateWindowDecos
    // does for a queued removal (uncache it from the positioner, erase it from m_windowDecorations) without that early
    // return.
    bool destroyNow(IHyprWindowDecoration* deco, const PHLWINDOW& hint) {
        const auto w = ownerOf(deco, hint);
        if (!w)
            return false;
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
    }

    // Removes every decoration of one kind (`live`: state().titlebars or state().rims, which each decoration leaves in its
    // destructor).
    template <typename Deco>
    void removeAll(const std::vector<Deco*>& live, const char* what) {
        // Visible windows: Hyprland's own removal path, which also lays the window out again without the
        // decoration. It destroys the decoration synchronously for a mapped, visible window.
        for (auto* deco : std::vector(live)) { // copy: removal destroys entries
            const auto w = deco->window();
            if (w && w->m_isMapped && !w->isHidden())
                HyprlandAPI::removeWindowDecoration(state().handle, deco);
        }

        // Everything left (unmapped or hidden windows): destroy directly, so that no object of this library
        // outlives dlclose.
        size_t direct = 0;
        for (auto* deco : std::vector(live)) {
            if (destroyNow(deco, deco->window()))
                ++direct;
            else
                gf::log(Log::ERR, "{} {:x} has no owning window; cannot destroy it before unload", what, reinterpret_cast<uintptr_t>(deco));
        }
        if (direct > 0)
            gf::log(Log::INFO, "destroyed {} {}(s) of unmapped or hidden windows directly", direct, what);
    }

    void removeAllTitlebars() {
        CGrassfieldTitlebar::cancelPointerGrab();
        removeAll(state().titlebars, "titlebar");
    }

    // The rims go with the plugin (gate C2): where each was is drawn again first, so that none stays on screen.
    void removeAllRims() {
        for (auto* deco : state().rims)
            deco->damageEntire();
        removeAll(state().rims, "rim");
    }

    void teardown() {
        auto& s = state();
        // Each step on its own: a failure in one must not skip the others (a Lua function registered
        // after unload would point into the unloaded library).
        const auto step = [](const char* what, auto&& fn) {
            try {
                fn();
            } catch (const std::exception& e) {
                gf::log(Log::ERR, "teardown: {} failed: {}", what, e.what());
            } catch (...) {
                gf::log(Log::ERR, "teardown: {} failed with an unknown exception", what);
            }
        };
        step("listeners", [&] { s.listeners.clear(); });
        step("top clamp", [] { gf::topClamp::stop(); });     // the clamp scheduled after a drag removed (its callback is in this library)
        step("client chrome", [] { gf::chrome::stop(); });   // per-window toplevel listeners removed
        step("frame probe", [] { gf::frameProbe::stop(); }); // presentation listeners removed
        step("desktop focus", [] { gf::desktopFocus::stop(); }); // no press or commit may reach the policy any more
        step("minimizer", [] { gf::minimizer::stop(); }); // before the Lua entry points go: animations complete, snapshots dropped
        step("overview", [] { gf::overviewer::stop(); });   // every window back to normal rendering, transformers detached
        step("stages", [] { gf::stager::stop(); });          // strip windows shown normally, input unblocked, transformers detached
        step("overview focus", [] { gf::overviewFocus::stop(); }); // a waiting request ends "unavailable"; watches and timer removed
        step("toplevel drag", [] { gf::toplevelDrag::stop(); });   // before tiling: its preview goes; logger, listeners and global removed
        step("tiling", [] { gf::tiler::stop(); });                 // records forgotten, its callback removed, "unavailable" posted
        step("cursor refresh", [] { gf::cursorRefresh::stop(); }); // trailing-refresh timer removed (its callback is in this library)
        step("layer pointer", [] { gf::layerPointer::stop(); });   // layer listener and event-loop callback removed
        step("appmenu", [] { gf::appmenuServer::stop(); }); // no wl_resource may point into this library after dlclose
        step("events", [] { gf::ipc::stopEvents(); });      // after the appmenu clears: waiting events posted, timer removed
        step("ipc", [] { gf::ipc::unregisterAll(); });
        step("rims", [] { removeAllRims(); }); // before the titlebars: a rim's frame (its damage) still has the bar's band
        step("titlebars", [] { removeAllTitlebars(); });
        // Hyprland keeps an unloaded plugin's library mapped ("this library stays in memory"): a reload finds these
        // statics as they were. The appearance (and whether the shell has said it) and the rims' globals start over, so a
        // reload in a session turned light draws no dark rim before the shell's push (FR57, gate C2).
        step("appearance", [&s] { s.appearance.reset(); });
        step("rim globals", [] { CGrassfieldRim::resetGlobals(); });
        step("withdraw", [] { gf::ipc::postWithdrawn(); }); // last: the shell drops every feature and uses its fallbacks
        s.active = false;
    }

    void notify(const std::string& text, const CHyprColor& color, float timeMs = 8000.F) {
        if (state().handle)
            HyprlandAPI::addNotification(state().handle, text, color, timeMs);
    }

    // A notice in the session's language (GF-067: core/Notices.hpp, French or English in gettext's order).
    void notify(gf::notices::Notice notice, const CHyprColor& color, float timeMs = 8000.F) {
        // NOLINTNEXTLINE(concurrency-mt-unsafe): read once on Hyprland's main thread, nothing in the plugin sets the environment
        const auto lang =
            gf::notices::languageFrom(std::getenv("LANGUAGE"), std::getenv("LC_ALL"), std::getenv("LC_MESSAGES"), std::getenv("LANG"));
        notify(std::string{gf::notices::text(notice, lang)}, color, timeMs);
    }
} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    auto& s  = state();
    s.handle = handle;

    PLUGIN_DESCRIPTION_INFO info{.name = gf::kPluginName, .description = "Grassfield titlebars, minimize, appmenu, overview, overview focus, desktop focus, Stages, cursor refresh, layer pointer focus and shell IPC (gfc/1)", .author = "Grassfield", .version = gf::kPluginVersion};

    const std::string serverHash = __hyprland_api_get_hash();
    const std::string clientHash = __hyprland_api_get_client_hash();
    if (serverHash != clientHash) {
        // Refuse cleanly: nothing is hooked, so the session keeps Hyprland's defaults (C2).
        gf::log(Log::ERR, "ABI mismatch: Hyprland {} vs plugin built for {}; plugin inactive", serverHash, clientHash);
        // The degraded-mode notice (audit GF-033): what is off and how to get it back. The session normally never loads a
        // build stamped for another Hyprland (ADR-0009 "Amendment 2026-10-23", config/hypr/grassfield/compositor.lua);
        // this shows when one is loaded anyway (by hand, or a stamp that lies).
        notify(gf::notices::Notice::AbiMismatch, CHyprColor{1.F, 0.35F, 0.3F, 1.F}, 30000.F);
        info.description += " [inactive: Hyprland version mismatch]";
        return info;
    }

    const bool ok = gf::guarded("PLUGIN_INIT", [&] {
        gf::ipc::startEvents(); // before anything can post (spec FR24)
        registerListeners();
        if (!gf::minimizer::start())
            gf::log(Log::WARN, "minimize render hooks failed to register; minimize not advertised");
        // Optional feature: a failure here only drops overview from the capabilities (the shell keeps thumbnails).
        bool overviewOk = false;
        gf::guarded("overview start", [&] { overviewOk = gf::overviewer::start(); });
        if (!overviewOk) {
            gf::guarded("overview rollback", [] { gf::overviewer::stop(); });
            gf::log(Log::WARN, "overview hooks failed to register; overview not advertised");
        }
        // Optional feature: a failure here only drops appmenu from the capabilities (the shell keeps T0 menus).
        bool appmenuOk = false;
        gf::guarded("appmenu start", [&] { appmenuOk = gf::appmenuServer::start(); });
        if (!appmenuOk) {
            gf::guarded("appmenu rollback", [] { gf::appmenuServer::stop(); });
            gf::log(Log::WARN, "appmenu global failed to start; appmenu not advertised");
        }
        // Optional feature: without it the shell keeps its own desktop focus workarounds and no file-changing desktop keys.
        bool desktopFocusOk = false;
        gf::guarded("desktop focus start", [&] { desktopFocusOk = gf::desktopFocus::start(); });
        if (!desktopFocusOk) {
            gf::guarded("desktop focus rollback", [] { gf::desktopFocus::stop(); });
            gf::log(Log::WARN, "desktop focus listeners failed to register; desktop-focus not advertised");
        }
        // Optional feature behind a flag (off at load; the shell pushes Settings windows.stages): without it the shell sends
        // no Stages flag and no Stages operation.
        bool stagesOk = false;
        gf::guarded("stages start", [&] { stagesOk = gf::stager::start(); });
        if (!stagesOk) {
            gf::guarded("stages rollback", [] { gf::stager::stop(); });
            gf::log(Log::WARN, "stages listeners failed to register; stages-available not advertised");
        }
        // Optional feature: without it the shell restores the focus after the Overview itself (checks and retries).
        bool overviewFocusOk = false;
        gf::guarded("overview focus start", [&] { overviewFocusOk = gf::overviewFocus::start(); });
        if (!overviewFocusOk) {
            gf::guarded("overview focus rollback", [] { gf::overviewFocus::stop(); });
            gf::log(Log::WARN, "overview focus listeners failed to register; overview-focus not advertised");
        }
        // Optional feature: without it the shell sends no refresh and a new pointer size shows at the next shape change.
        bool cursorRefreshOk = false;
        gf::guarded("cursor refresh start", [&] { cursorRefreshOk = gf::cursorRefresh::start(); });
        if (!cursorRefreshOk) {
            gf::guarded("cursor refresh rollback", [] { gf::cursorRefresh::stop(); });
            gf::log(Log::WARN, "no renderer for the cursor refresh; cursor-refresh not advertised");
        }
        // Optional feature: without it a click without motion after a shell layer mapped may miss it (Hyprland 0.56.2, FR51).
        bool layerPointerOk = false;
        gf::guarded("layer pointer start", [&] { layerPointerOk = gf::layerPointer::start(); });
        if (!layerPointerOk) {
            gf::guarded("layer pointer rollback", [] { gf::layerPointer::stop(); });
            gf::log(Log::WARN, "layer pointer listener failed to register; layer-pointer not advertised");
        }
        // Optional feature: without it windows that draw their own chrome still get no titlebar (P1 needs no listener), but
        // their minimize light and zoomed drag are not bridged and client-chrome is not advertised (the shell's Overview
        // then keeps the titlebar band above them).
        bool clientChromeOk = false;
        gf::guarded("client chrome start", [&] { clientChromeOk = gf::chrome::start(); });
        if (!clientChromeOk) {
            gf::guarded("client chrome rollback", [] { gf::chrome::stop(); });
            gf::log(Log::WARN, "client chrome listeners failed to register; client-chrome not advertised");
        }
        // Optional feature (ADR-0006 P3): presented-frame timestamps; without it frame-times is not advertised.
        bool frameProbeOk = false;
        gf::guarded("frame probe start", [&] { frameProbeOk = gf::frameProbe::start(); });
        if (!frameProbeOk) {
            gf::guarded("frame probe rollback", [] { gf::frameProbe::stop(); });
            gf::log(Log::WARN, "frame probe listeners failed to register; frame-times not advertised");
        }
        // The titlebar never goes under the menu bar (macOS): the plugin's own titlebar drags and the end of Hyprland's drags.
        gf::guarded("top clamp start", [] { gf::topClamp::start(); });
        // Optional feature: without its listeners the tile records only follow the windows' boxes and tiling-arrange is not
        // advertised (tile and the titlebar drag still tile). Before registerAll: arrange registers only when this is ready.
        bool tilingOk = false;
        gf::guarded("tiling start", [&] { tilingOk = gf::tiler::start(); });
        if (!tilingOk) {
            gf::guarded("tiling rollback", [] { gf::tiler::stop(); });
            gf::log(Log::WARN, "tiling listeners failed to register; tiling-arrange not advertised");
        }
        // Optional feature (ADR-0036 amendment 2026-11-08, URR-030): without it no xdg_toplevel_drag_manager_v1 is advertised and a
        // browser tab torn off stays where it came off, as before.
        bool toplevelDragOk = false;
        gf::guarded("toplevel drag start", [&] { toplevelDragOk = gf::toplevelDrag::start(); });
        if (!toplevelDragOk) {
            gf::guarded("toplevel drag rollback", [] { gf::toplevelDrag::stop(); });
            gf::log(Log::WARN, "toplevel drag global failed to start; toplevel-drag not advertised");
        }
        if (!gf::ipc::registerAll())
            gf::log(Log::WARN, "some IPC entry points failed to register");
        // ADR-0036 D78: window-tiling is known now; client-chrome windows' own maximize becomes the plugin's Zoom (Fill).
        gf::guarded("client chrome maximize", [] { gf::chrome::syncMaximizeAll(); });

        for (const auto& w : Desktop::windowState()->windows())
            decorate(w);

        s.active = true;

        const auto version = HyprlandAPI::getHyprlandVersion(handle);
        gf::log(Log::INFO, "{} {} initialised on Hyprland {} (commit {}), ABI hash match", gf::kPluginName, gf::kPluginVersion, version.tag, version.hash);

        gf::ipc::postCapabilities();
    });

    if (!ok) {
        gf::guarded("PLUGIN_INIT rollback", [] { teardown(); });
        notify(gf::notices::Notice::InitFailed, CHyprColor{1.F, 0.35F, 0.3F, 1.F});
        info.description += " [inactive: init failed]";
    }

    return info;
}

APICALL EXPORT void PLUGIN_EXIT() {
    gf::guarded("PLUGIN_EXIT", [] {
        if (state().active)
            teardown();
        gf::log(Log::INFO, "{} unloaded", gf::kPluginName);
    });
}
