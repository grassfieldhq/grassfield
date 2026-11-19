#include "Overview.hpp"

#include "FrameProbe.hpp"
#include "Ipc.hpp"
#include "Plugin.hpp"
#include "Surfaces.hpp"
#include "WindowTransform.hpp"
#include "core/EventThrottle.hpp"
#include "core/Minimize.hpp"
#include "core/Motion.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/transformer/Transformer.hpp>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

namespace ov = gf::overview;

namespace {
    // Layer namespace of the shell's overview surface (shell/overview/OverviewWindow.qml). When it goes away (the shell
    // exited or crashed) an open overview closes, so windows never stay transformed without a shell to end it.
    constexpr std::string_view OVERVIEW_LAYER_NAMESPACE = "grassfield-overview";

    // Ends animations whose frames stopped (no monitor rendered): checked this long after the expected end.
    constexpr auto WATCHDOG_SLACK = std::chrono::milliseconds(150);

    // Attached to a transformed window (CWindow::m_transformers, owned by the window). Hyprland calls transform() with
    // a monitor-sized work buffer holding the window's main pass at its real place; it returns the buffer to composite.
    class COverviewTransformer final : public Render::IWindowTransformer {
      public:
        SP<Render::IFramebuffer> transform(SP<Render::IFramebuffer> in) override;
    };

    struct SEntry {
        PHLWINDOWREF          window;
        uint64_t              address = 0;
        PHLMONITORREF         monitor;               // the window's monitor when it entered the overview
        COverviewTransformer* transformer = nullptr; // owned by window->m_transformers; compared, never freed here
        // Where its surface box is drawn, with its own clock: from where it was to its layout rect (to nullopt: its live
        // surface box). A retarget (the shell's on:true again, a close) continues from the box on screen with its velocity
        // and keeps the clock of an unchanged target (core/Motion.hpp).
        gf::motion::Track     track;
        bool                  moving = false;        // its track had not settled at the last step
        ov::Box               rect;                  // layout rect the surface box is fitted into, at the last tick
        ov::Box               damaged;               // last damaged visual box (layout, with every decoration)
        bool                  kept = false;          // retarget bookkeeping
        Time::steady_tp       boxChangedAt{};        // last change of the drawn box while open (resized surface)
    };

    struct SOverviewState {
        bool                             ready = false;
        ov::Phase                        phase = ov::Phase::Closed;
        ov::Reason                       closeReason = ov::Reason::None;
        std::vector<SEntry>              entries;
        double                           durationMs = 0; // of the latest request (a close the plugin starts uses it)
        double                           animEndMs  = 0; // when the last track settles (the watchdog)
        ov::Curve                        curve;
        std::vector<CHyprSignalListener> listeners;
        SP<CEventLoopTimer>              watchdog; // shared: CEventLoopManager holds a strong reference too
        bool                             warnedNoBuffer = false;
    };

    // Constructed on first use inside a guarded call (R13). Emptied by stop() before dlclose.
    SOverviewState& st() {
        static SOverviewState s;
        return s;
    }

    using gf::transform::hasArea;
    using gf::transform::toCBox;

    void post(ov::Phase phase, size_t windows, ov::Reason reason = ov::Reason::None) {
        gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::Overview, .id = 0}, ov::eventJson(phase, windows, reason));
    }

    // The address is compared, never dereferenced.
    PHLWINDOW windowByAddress(uint64_t address) {
        if (!Desktop::windowState())
            return nullptr;
        for (const auto& w : Desktop::windowState()->windows()) {
            if (w && reinterpret_cast<uintptr_t>(w.get()) == address)
                return w;
        }
        return nullptr;
    }

    // The workspace shows a full-screen window (FSMODE_FULLSCREEN; maximized does not count). On macOS a full-screen app
    // is a Space of its own, and Hyprland draws only the full-screen window there: such a workspace is not overviewed.
    bool showsFullscreen(const PHLWORKSPACE& ws) {
        const auto& fullscreen = Fullscreen::controller();
        return !fullscreen || (ws && fullscreen->getFullscreenModes(ws).internal == Fullscreen::FSMODE_FULLSCREEN);
    }

    // Windows of the current workspace of their monitor, drawn by Hyprland's normal window pass: mapped, visible, not
    // pinned (pinned windows are drawn on every workspace), not on a special workspace (minimized windows live on
    // special:minimized), not full screen and not on a workspace that shows a full-screen window (maximized is fine).
    bool eligible(const PHLWINDOW& w) {
        if (!w || !w->m_isMapped || w->isHidden() || w->m_pinned)
            return false;
        const auto ws  = w->m_workspace;
        const auto mon = w->m_monitor.lock();
        if (!ws || ws->m_isSpecialWorkspace || !mon || mon->m_activeWorkspace != ws)
            return false;
        const auto& fullscreen = Fullscreen::controller();
        return fullscreen && fullscreen->getFullscreenModes(w).internal != Fullscreen::FSMODE_FULLSCREEN && !showsFullscreen(ws);
    }

    bool isChrome(const PHLLS& ls) {
        return ls && ls->m_namespace == OVERVIEW_LAYER_NAMESPACE;
    }

    uint64_t monitorId(const PHLMONITOR& mon) {
        return reinterpret_cast<uintptr_t>(mon.get());
    }

    // The keyboard is on the shell's chrome (the surface, a subsurface or one of its popups).
    bool keyboardOnChrome() {
        return isChrome(gf::surfaces::ownerOf(gf::surfaces::keyboardFocus()).layer);
    }

    std::vector<ov::ChromeSurface> chromeSurfaces() {
        std::vector<ov::ChromeSurface> out;
        if (!Desktop::layerState())
            return out;
        const auto keyboardLayer = gf::surfaces::ownerOf(gf::surfaces::keyboardFocus()).layer;
        for (const auto& ls : Desktop::layerState()->layers()) {
            if (!isChrome(ls))
                continue;
            out.push_back(ov::ChromeSurface{.monitor   = monitorId(ls->m_monitor.lock()),
                                            .mapped    = ls->m_mapped,
                                            .exclusive = gf::surfaces::interactivity(ls) == 1 /* ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE */,
                                            .keyboard  = keyboardLayer == ls});
        }
        return out;
    }

    ov::FocusCause causeOf(Desktop::eFocusReason reason) {
        switch (reason) {
            case Desktop::FOCUS_REASON_UNMAP_WINDOW_TILING:
            case Desktop::FOCUS_REASON_UNMAP_WINDOW_FLOATING:
            case Desktop::FOCUS_REASON_UNMAP_GROUPED_WINDOW: return ov::FocusCause::WindowClosed;
            case Desktop::FOCUS_REASON_NEW_WINDOW: return ov::FocusCause::WindowOpened;
            default: return ov::FocusCause::UserOrOther;
        }
    }

    ov::Box monitorBox(const PHLMONITOR& mon) {
        return ov::Box{mon->m_position.x, mon->m_position.y, mon->m_size.x, mon->m_size.y};
    }

    using gf::transform::surfaceBox;

    // Where the window and its decorations are drawn now (layout).
    ov::Box visualBox(const SEntry& e, const PHLWINDOW& w) {
        return gf::transform::visualBox(w, e.rect);
    }

    // Damages the previous and the current visual box (and so schedules frames on the monitors they touch).
    void damage(SEntry& e, const PHLWINDOW& w) {
        if (!g_pHyprRenderer)
            return;
        const ov::Box box = visualBox(e, w);
        for (const auto& b : ov::damageStep(e.damaged, box))
            g_pHyprRenderer->damageBox(toCBox(b));
        e.damaged = box;
    }

    COverviewTransformer* attach(const PHLWINDOW& w) {
        auto  transformer = makeUnique<COverviewTransformer>();
        auto* raw         = transformer.get();
        gf::transform::use(gf::transform::EUser::Overview); // its output buffers (WindowTransform.cpp)
        w->m_transformers.emplace_back(std::move(transformer));
        if (g_pHyprRenderer)
            g_pHyprRenderer->damageWindow(w);
        return raw;
    }

    // Back to normal rendering: the transformer leaves the window (a destroyed window took it along).
    void detach(SEntry& e) {
        if (g_pHyprRenderer && hasArea(e.damaged))
            g_pHyprRenderer->damageBox(toCBox(e.damaged));
        const auto w = e.window.lock();
        if (w && e.transformer) {
            std::erase_if(w->m_transformers, [&e](const UP<Render::IWindowTransformer>& t) { return t.get() == e.transformer; });
            if (g_pHyprRenderer)
                g_pHyprRenderer->damageWindow(w);
        }
        e.transformer = nullptr;
        e.damaged     = {};
        // The last transformed window of this module: the transforms' own buffers may go (if the other module has none).
        if (std::ranges::none_of(st().entries, [](const auto& x) { return x.transformer != nullptr; }))
            gf::transform::release(gf::transform::EUser::Overview);
    }

    void detachAll() {
        auto entries = std::exchange(st().entries, {});
        for (auto& e : entries)
            detach(e);
    }

    void finishClosed(ov::Reason reason) {
        detachAll();
        st().phase = ov::Phase::Closed;
        gf::guarded("overview mark", [] { gf::frameProbe::mark("overview-closed"); });
        post(ov::Phase::Closed, 0, reason);
    }

    // The animation clock (ms on the steady clock): the tracks' time base.
    double nowMs() {
        return std::chrono::duration<double, std::milli>(Time::steadyNow().time_since_epoch()).count();
    }

    void tick(const PHLMONITOR& mon);

    void armWatchdog() {
        auto& s = st();
        if (!g_pEventLoopManager)
            return;
        if (!s.watchdog) {
            s.watchdog = makeShared<CEventLoopTimer>(
                std::nullopt,
                [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) {
                    gf::guarded("overview watchdog", [] {
                        tick(nullptr);
                        const auto& s = st();
                        if ((s.phase == ov::Phase::Opening || s.phase == ov::Phase::Closing) && s.watchdog)
                            s.watchdog->updateTimeout(WATCHDOG_SLACK);
                    });
                },
                nullptr);
            g_pEventLoopManager->addTimer(s.watchdog);
        }
        const double left = std::max(0.0, s.animEndMs - nowMs());
        s.watchdog->updateTimeout(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::duration<double, std::milli>(left)) + WATCHDOG_SLACK);
    }

    // One animation step of the windows of `mon` (render.preChecks of that monitor, where Hyprland ticks its own animations:
    // each window is stepped by the frames of the monitor that shows it, once per frame cycle) or of every window (`mon`
    // null: the watchdog, a request). A track that settled is stepped once more on any monitor's frame (its final box).
    // Opening becomes Open, Closing becomes Closed, once every track settled. Damage schedules the next frames.
    void tick(const PHLMONITOR& mon) {
        auto& s = st();
        if (s.phase != ov::Phase::Opening && s.phase != ov::Phase::Closing)
            return;
        const double now   = nowMs();
        bool         still = false;
        for (auto it = s.entries.begin(); it != s.entries.end();) {
            const auto w = it->window.lock();
            if (!w) {
                detach(*it);
                it = s.entries.erase(it);
                continue;
            }
            if (!it->moving) {
                ++it;
                continue;
            }
            const bool done = gf::motion::settled(it->track, now);
            if (!done && mon && it->monitor.lock() != mon) {
                still = true;
                ++it;
                continue;
            }
            it->rect = gf::motion::positionAt(it->track, surfaceBox(w), now);
            damage(*it, w);
            it->moving = !done;
            still      = still || !done;
            ++it;
        }
        if (still)
            return;
        if (s.phase == ov::Phase::Opening) {
            s.phase = ov::Phase::Open;
            gf::guarded("overview mark", [] { gf::frameProbe::mark("overview-open"); });
            post(ov::Phase::Open, s.entries.size());
        } else
            finishClosed(s.closeReason);
    }

    // While the overview is shown, a frame of this monitor may come from any damage at a window's real place (its
    // content changed) that Hyprland does not know is drawn elsewhere: that window's layout box is added to the frame's
    // damage before it is computed (render.pre comes after Hyprland's animation tick and before beginRender reads the
    // damage ring). Only the windows whose real place the frame's damage touches, or whose drawn box changed (WM-02): an
    // unrelated change elsewhere no longer repaints every window. Frames without damage are not touched, so an idle overview
    // costs nothing. The box drawn now becomes the last damaged box: a surface resized while open (the box changes without
    // an animation tick) has every box it was drawn in damaged again when it leaves it, so no stale pixels stay behind, also
    // at close. No allocation per window.
    void onRenderPre(const PHLMONITOR& mon) {
        auto& s = st();
        if (s.phase == ov::Phase::Closed || !mon || !mon->m_damage.hasChanged())
            return;
        std::optional<CRegion> frame; // read once, at the first window of this monitor
        for (auto& e : s.entries) {
            if (e.monitor.lock() != mon)
                continue;
            const auto w = e.window.lock();
            if (!w)
                continue;
            if (!frame)
                frame = gf::transform::frameDamage(mon);
            const ov::Box box = visualBox(e, w);
            if (!ov::needsRepaint(e.damaged, box, gf::transform::touches(*frame, mon, gf::transform::realBox(w))))
                continue;
            const auto boxes = ov::damageStep(e.damaged, box);
            for (const auto& b : boxes)
                mon->m_damage.damage(toCBox(b).translate(-mon->m_position).scale(mon->m_scale).round());
            if (s.phase == ov::Phase::Open && boxes.size() == 2) {
                // The drawn box changed without an animation tick (a resized surface): logged at the first frame of each
                // burst only (a client resize animates over many frames).
                const auto now = Time::steadyNow();
                if (now - e.boxChangedAt > std::chrono::milliseconds(250))
                    gf::logRequest(Log::DEBUG, "overview: window {:x} drawn box changed while open: damaged {:.0f},{:.0f} {:.0f}x{:.0f} and {:.0f},{:.0f} {:.0f}x{:.0f}",
                                   e.address, boxes[0].x, boxes[0].y, boxes[0].w, boxes[0].h, boxes[1].x, boxes[1].y, boxes[1].w, boxes[1].h);
                e.boxChangedAt = now;
            }
            e.damaged = box;
        }
    }

    // The tracks were set for `phase`: the first step now (tracks of 0 ms, Reduce Motion, end at once), the watchdog armed
    // for the last end.
    void startAnimation(ov::Phase phase, double durationMs) {
        auto& s      = st();
        s.phase      = phase;
        s.durationMs = durationMs;
        s.animEndMs  = 0;
        for (const auto& e : s.entries) {
            if (e.moving)
                s.animEndMs = std::max(s.animEndMs, gf::motion::endMs(e.track));
        }
        gf::guarded("overview mark", [phase] { gf::frameProbe::mark(phase == ov::Phase::Closing ? "overview-closing" : "overview-opening"); });
        post(phase, s.entries.size(), phase == ov::Phase::Closing ? s.closeReason : ov::Reason::None);
        tick(nullptr);
        if (s.phase == ov::Phase::Opening || s.phase == ov::Phase::Closing)
            armWatchdog();
    }

    // Every window goes back to its live place from where it is drawn, with its velocity (WM-17: a close right after the
    // open reverses at once and takes about as long as the way it travelled, core/Motion.hpp).
    void startClosing(double durationMs, const ov::Curve& curve, ov::Reason reason) {
        auto& s = st();
        if (s.phase == ov::Phase::Closed) {
            post(ov::Phase::Closed, 0, reason);
            return;
        }
        const double now = nowMs();
        for (auto& e : s.entries) {
            if (const auto w = e.window.lock(); w && gf::motion::retarget(e.track, std::nullopt, surfaceBox(w), now, durationMs, curve))
                e.moving = true;
        }
        s.closeReason = reason;
        startAnimation(ov::Phase::Closing, durationMs);
    }

    // A window that closes, unmaps or leaves its workspace goes back to normal rendering at once.
    // The overview stays (the shell retargets); the window count of the current state changed, so it is posted again
    // (coalesced like every overview event).
    void dropWindow(const PHLWINDOW& w) {
        auto&        s       = st();
        auto&        all     = s.entries;
        const size_t before  = all.size();
        for (auto it = all.begin(); it != all.end();) {
            const auto ew = it->window.lock();
            if (!ew || ew == w) {
                detach(*it);
                it = all.erase(it);
            } else
                ++it;
        }
        if (all.size() != before && s.phase != ov::Phase::Closed)
            post(s.phase, all.size());
    }

    bool animatingOrOpen() {
        const auto phase = st().phase;
        return phase == ov::Phase::Opening || phase == ov::Phase::Open;
    }

    // A window went full screen while the overview is shown: Hyprland now draws only that window on its workspace, so
    // every window of that workspace leaves the overview at once (back to normal rendering) and the shell is told with
    // reason "fullscreen" (the state is unchanged; it retargets or closes).
    void onFullscreen(const PHLWINDOW& w) {
        auto& s = st();
        if (s.phase == ov::Phase::Closed || !w)
            return;
        const auto ws = w->m_workspace;
        if (!showsFullscreen(ws)) {
            if (!eligible(w))
                dropWindow(w);
            return;
        }
        size_t dropped = 0;
        for (auto it = s.entries.begin(); it != s.entries.end();) {
            const auto ew = it->window.lock();
            if (!ew || ew->m_workspace == ws) {
                detach(*it);
                it = s.entries.erase(it);
                ++dropped;
            } else
                ++it;
        }
        gf::logRequest(Log::INFO, "overview: window {:x} went full screen: {} window(s) of its workspace left the overview", reinterpret_cast<uintptr_t>(w.get()), dropped);
        post(s.phase, s.entries.size(), ov::Reason::Fullscreen);
    }

    SP<Render::IFramebuffer> drawTransformed(const COverviewTransformer* self, const SP<Render::IFramebuffer>& in) {
        // Only the monitor frame: snapshots (close and minimize animations) and window captures (toplevel export,
        // RPT_EXPORT) show the window as it is.
        if (!in || !gf::transform::monitorFrame())
            return in;
        const auto& all = st().entries;
        const auto  it  = std::ranges::find_if(all, [self](const SEntry& e) { return e.transformer == self; });
        if (it == all.end())
            return in;
        const auto w   = it->window.lock();
        const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!w || !mon)
            return in;
        // A window that spans monitors is shown only in the overview of its own monitor: here it is drawn as nothing.
        if (mon != it->monitor.lock())
            return gf::transform::drawNothing(in);
        return gf::transform::drawFitted(w, it->rect, in, st().warnedNoBuffer, it->address);
    }

    SP<Render::IFramebuffer> COverviewTransformer::transform(SP<Render::IFramebuffer> in) {
        SP<Render::IFramebuffer> out = in;
        gf::guarded("overview transform", [&] { out = drawTransformed(this, in); });
        return out;
    }
} // namespace

namespace gf::overviewer {

    bool start() {
        auto& bus = Event::bus();
        if (!bus || !Fullscreen::controller())
            return false;
        auto& ev = bus->m_events;
        auto& l  = st().listeners;
        l.push_back(ev.render.preChecks.listen([](const PHLMONITOR& monitor) { gf::guarded("overview tick", [&] { tick(monitor); }); }));
        l.push_back(ev.render.pre.listen([](const PHLMONITOR& monitor) { gf::guarded("overview damage", [&] { onRenderPre(monitor); }); }));
        l.push_back(ev.window.close.listen([](const PHLWINDOW& w) { gf::guarded("overview window.close", [&] { dropWindow(w); }); }));
        l.push_back(ev.window.destroy.listen([](const PHLWINDOWREF& /*w*/) { gf::guarded("overview window.destroy", [] { dropWindow(nullptr); }); }));
        l.push_back(ev.window.moveToWorkspace.listen([](const PHLWINDOW& w, const PHLWORKSPACE& /*ws*/) { gf::guarded("overview window.moveToWorkspace", [&] { dropWindow(w); }); }));
        // A window that becomes pinned is drawn by other render paths: back to normal at once. A window that becomes full
        // screen takes its whole workspace out of the overview (onFullscreen).
        l.push_back(ev.window.pin.listen([](const PHLWINDOW& w) {
            gf::guarded("overview window.pin", [&] {
                if (w && !eligible(w))
                    dropWindow(w);
            });
        }));
        l.push_back(ev.window.fullscreen.listen([](const PHLWINDOW& w) { gf::guarded("overview window.fullscreen", [&] { onFullscreen(w); }); }));
        // Failsafes: a window chosen by the user getting focus ends the overview (macOS: the clicked window becomes key and
        // the overview zooms back); Hyprland moving focus because a window closed or opened does not (the shell retargets).
        // Hyprland 0.56.2 also emits this for a window that is closing, with reason "other", while it refuses the keyboard
        // to the next window because the chrome is Exclusive (measured): only a mapped window that took the keyboard away
        // from the chrome counts.
        l.push_back(ev.window.active.listen([](const PHLWINDOW& w, Desktop::eFocusReason reason) {
            gf::guarded("overview window.active", [&] {
                if (!w || !animatingOrOpen())
                    return;
                const bool ends = w->m_isMapped && !keyboardOnChrome() && ov::focusEndsOverview(causeOf(reason));
                gf::logRequest(Log::DEBUG, "overview: window {:x} focused (reason {}): {}", reinterpret_cast<uintptr_t>(w.get()), static_cast<int>(reason),
                               ends ? "the overview ends" : "the overview stays");
                if (ends)
                    startClosing(st().durationMs, st().curve, ov::Reason::Interrupted);
            });
        }));
        // The keyboard leaving the shell's chrome (to a window, another surface or nothing) ends it too: the overview is
        // shown only while the chrome holds the keyboard.
        l.push_back(ev.input.keyboard.focus.listen([](const SP<CWLSurfaceResource>& surface) {
            gf::guarded("overview keyboard.focus", [&] {
                if (!animatingOrOpen() || isChrome(gf::surfaces::ownerOf(surface).layer))
                    return;
                gf::logRequest(Log::INFO, "overview: the keyboard left the shell's chrome: the overview ends");
                startClosing(st().durationMs, st().curve, ov::Reason::Interrupted);
            });
        }));
        // The chrome going away while windows are shown elsewhere ends the overview at once (no closing animation: nothing
        // covers the windows' real places any more), also when the keyboard leaving it just started an interrupted closing.
        // A closing animation the shell asked for (on:false) runs to its end.
        l.push_back(ev.layer.closed.listen([](const PHLLS& ls) {
            gf::guarded("overview layer.closed", [&] {
                const auto& s = st();
                if (!isChrome(ls) || !(animatingOrOpen() || (s.phase == ov::Phase::Closing && s.closeReason != ov::Reason::None)))
                    return;
                gf::logRequest(Log::INFO, "overview: the shell's chrome went away: the overview ends at once");
                finishClosed(ov::Reason::Interrupted);
            });
        }));
        l.push_back(ev.workspace.active.listen([](const PHLWORKSPACE& /*ws*/) {
            gf::guarded("overview workspace.active", [] {
                const auto& s = st();
                if (s.phase == ov::Phase::Closed)
                    return;
                const bool moved = std::ranges::any_of(s.entries, [](const SEntry& e) {
                    const auto w   = e.window.lock();
                    const auto mon = e.monitor.lock();
                    return !w || !mon || mon->m_activeWorkspace != w->m_workspace;
                });
                // WM-17: the windows go back to their places with the closing animation (those of the Desktop sliding out
                // go back while it slides; macOS zooms out of Mission Control into the chosen Space), never in one frame.
                if (moved && animatingOrOpen())
                    startClosing(s.durationMs, s.curve, ov::Reason::Interrupted);
            });
        }));
        l.push_back(ev.monitor.removed.listen([](const PHLMONITOR& /*monitor*/) {
            gf::guarded("overview monitor.removed", [] {
                if (st().phase != ov::Phase::Closed)
                    finishClosed(ov::Reason::Interrupted);
            });
        }));
        l.push_back(ev.monitor.layoutChanged.listen([] {
            gf::guarded("overview monitor.layoutChanged", [] {
                if (st().phase != ov::Phase::Closed)
                    finishClosed(ov::Reason::Interrupted);
            });
        }));
        st().ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.ready = false;
        s.listeners.clear();
        if (s.phase != ov::Phase::Closed)
            finishClosed(ov::Reason::Unavailable); // no transformer of this library may outlive dlclose
        if (s.watchdog) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.watchdog);
            s.watchdog.reset();
        }
    }

    bool ready() {
        return st().ready;
    }

    bool transforms(const PHLWINDOW& window) {
        const auto& s = st();
        return window && s.phase != ov::Phase::Closed &&
            std::ranges::any_of(s.entries, [&window](const SEntry& e) { return e.transformer && e.window.lock() == window; });
    }

    void refuse(ov::Reason reason) {
        const auto& s = st();
        post(s.phase, s.entries.size(), reason);
    }

    void request(const ov::Request& r) {
        auto& s = st();
        if (!s.ready) {
            post(ov::Phase::Closed, 0, ov::Reason::Unavailable);
            return;
        }
        if (!r.on) {
            startClosing(r.durationMs, r.curve, ov::Reason::None);
            return;
        }

        std::vector<SEntry> next;
        const double        now = nowMs();
        for (auto& old : s.entries)
            old.kept = false;
        for (const auto& target : r.windows) {
            const auto w = windowByAddress(target.address);
            if (!eligible(w)) {
                gf::logRequest(Log::INFO, "overview: window {:x} skipped (unknown, unmapped, hidden, pinned, full screen or not on its monitor's workspace)",
                               target.address);
                continue;
            }
            const auto mon = w->m_monitor.lock();
            if (!ov::insideMonitor(target.rect, monitorBox(mon))) {
                gf::logRequest(Log::INFO, "overview: window {:x} skipped: rect {:.0f},{:.0f} {:.0f}x{:.0f} not inside its monitor {}", target.address, target.rect.x,
                               target.rect.y, target.rect.w, target.rect.h, mon->m_name);
                continue;
            }
            SEntry e{.window       = w,
                     .address      = target.address,
                     .monitor      = mon,
                     .transformer  = nullptr,
                     .track        = gf::motion::start(std::nullopt, target.rect, now, r.durationMs, r.curve),
                     .moving       = true,
                     .rect         = {},
                     .damaged      = {},
                     .kept         = false,
                     .boxChangedAt = {}};
            // A window already in the overview continues from where it is drawn now, with its velocity; its clock goes on
            // when its rect did not change (core/Motion.hpp).
            const auto old = std::ranges::find_if(s.entries, [&w](const SEntry& o) { return !o.kept && o.window.lock() == w; });
            if (old != s.entries.end()) {
                e.track       = old->track;
                e.moving      = gf::motion::retarget(e.track, target.rect, surfaceBox(w), now, r.durationMs, r.curve) || old->moving;
                e.rect        = old->rect;
                e.transformer = old->transformer;
                e.damaged     = old->damaged;
                old->kept     = true;
            }
            next.push_back(e);
        }
        if (!r.windows.empty() && next.empty()) {
            gf::logRequest(Log::WARN, "overview: rejected: none of the {} listed window(s) can be transformed", r.windows.size());
            refuse(ov::Reason::NoWindows);
            return;
        }
        // Input safety does not depend on the shell's good behaviour: windows are drawn away from their real places only
        // while the shell's chrome covers every monitor involved (mapped) and one Exclusive chrome holds the keyboard (R13
        // review of f12f610; relaxed from "every chrome Exclusive" after the shell integration review, main 23caeab).
        std::vector<uint64_t> monitors;
        for (const auto& e : next) {
            const uint64_t id = monitorId(e.monitor.lock());
            if (std::ranges::find(monitors, id) == monitors.end())
                monitors.push_back(id);
        }
        if (!next.empty() && !ov::chromeCovers(monitors, chromeSurfaces())) {
            gf::logRequest(Log::WARN, "overview: rejected: the shell's chrome (layer {}) must be mapped on each window's monitor, and one of them must hold the keyboard (Exclusive)",
                           OVERVIEW_LAYER_NAMESPACE);
            refuse(ov::Reason::NoChrome);
            return;
        }
        for (auto& old : s.entries) {
            if (!old.kept)
                detach(old); // left the layout: back to its place at once
        }
        for (auto& e : next) {
            if (!e.transformer)
                e.transformer = attach(e.window.lock());
        }
        s.entries     = std::move(next);
        s.closeReason = ov::Reason::None;
        gf::logRequest(Log::INFO, "overview: {} window(s), {:.0f} ms", s.entries.size(), r.durationMs);
        s.curve       = r.curve;
        startAnimation(ov::Phase::Opening, r.durationMs);
    }

} // namespace gf::overviewer
