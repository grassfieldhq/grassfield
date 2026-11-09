#include "CapturePrivacy.hpp"

#include "Plugin.hpp"

#include <hyprland/src/desktop/rule/windowRule/WindowRuleApplicator.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/screenshare/ScreenshareManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace gf::capturePrivacy {

    namespace {
        struct SDisplay {
            PHLMONITORREF           monitor;
            privacy::DisplayCapture capture;
        };

        struct SState {
            std::vector<CHyprSignalListener> listeners;
            std::vector<SDisplay>            displays;
            SP<CEventLoopTimer>              endCheck;        // code of this library: removed in stop()
            bool                             tracked = false; // the listeners are registered
        };

        // Constructed on first use inside a guarded call (R13).
        SState& st() {
            static SState s;
            return s;
        }

        // Hyprland's account of the display's captures (CScreenshareManager::outputCopyFBState, public in 0.56.2): its
        // monitor and region sessions, with their pending frames. Window captures (toplevel export) are not counted: they
        // draw the window alone, without its decorations and without a transformer, and a protected one not at all.
        privacy::CaptureCounts countsOf(const PHLMONITOR& mon) {
            const auto& manager = Screenshare::mgr();
            if (!mon || !manager)
                return {};
            const auto state = manager->outputCopyFBState(mon);
            return privacy::CaptureCounts{.sharingSessions = state.sharingSessions, .pendingFrames = state.pendingFrames};
        }

        // Redraws every display whose capture was in progress at its last frame and has ended (core ended()); render.pre
        // then records it and the content comes back. True while a display capture is still in progress somewhere.
        bool redrawEnded() {
            bool inProgress = false;
            for (const auto& d : st().displays) {
                const auto mon = d.monitor.lock();
                if (!mon)
                    continue;
                const bool now = capturing(mon);
                if (privacy::ended(d.capture, now) && g_pHyprRenderer)
                    g_pHyprRenderer->damageMonitor(mon);
                inProgress = inProgress || now;
            }
            return inProgress;
        }

        // The end check, at most once per privacy::kEndCheck while a display capture is in progress.
        void armEndCheck() {
            auto& s = st();
            if (!s.endCheck || s.endCheck->armed())
                return;
            s.endCheck->updateTimeout(std::chrono::duration_cast<Time::steady_dur>(privacy::kEndCheck));
        }

        // render.pre comes before Hyprland reads the display's damage for the frame (IHyprRenderer::renderMonitor, then
        // beginRender): a whole redraw asked here is this frame's.
        void beforeFrame(const PHLMONITOR& mon) {
            if (!mon || !g_pHyprRenderer)
                return;
            auto& displays = st().displays;
            std::erase_if(displays, [](const SDisplay& d) { return d.monitor.expired(); });
            auto it = std::ranges::find_if(displays, [&mon](const SDisplay& d) { return d.monitor.lock() == mon; });
            if (it == displays.end())
                it = displays.insert(displays.end(), SDisplay{.monitor = mon, .capture = {}});
            const bool now = capturing(mon);
            if (privacy::redrawWhole(it->capture, now))
                g_pHyprRenderer->damageMonitor(mon);
            if (now)
                armEndCheck();
        }

        // The listeners and the end check's timer (their callbacks are code of this library), gone from Hyprland.
        void unregister(SState& s) {
            s.listeners.clear();
            if (s.endCheck) {
                if (g_pEventLoopManager)
                    g_pEventLoopManager->removeTimer(s.endCheck);
                s.endCheck.reset();
            }
        }

        bool registerAll(SState& s) {
            auto& bus = Event::bus();
            if (!bus || !g_pEventLoopManager)
                return false;
            s.endCheck = makeShared<CEventLoopTimer>(
                std::nullopt,
                [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) {
                    guarded("capture privacy end check", [] {
                        if (redrawEnded())
                            armEndCheck();
                    });
                },
                nullptr);
            g_pEventLoopManager->addTimer(s.endCheck);
            s.listeners.push_back(bus->m_events.render.pre.listen([](const PHLMONITOR& mon) { guarded("capture privacy render.pre", [&] { beforeFrame(mon); }); }));
            // A display share's end: Hyprland stops counting a session as sharing 500 ms after its last copied frame, or
            // when it stops, and says so here (CScreenshareSession::screenshareEvents). Only the displays whose capture
            // has ended are redrawn, for render.pre to see it: a window share changes no display (core endChecked), and a
            // display share with a frame still pending is still a capture. A start needs nothing: the frame the client
            // waits for is pending before it is drawn, and render.pre sees that.
            s.listeners.push_back(bus->m_events.screenshare.state.listen([](bool started, uint8_t type, const std::string& /*name*/) {
                if (!privacy::endChecked(started, type == Screenshare::SHARE_WINDOW))
                    return;
                guarded("capture privacy screenshare.state", [] { (void)redrawEnded(); });
            }));
            return true;
        }
    } // namespace

    bool start() {
        auto& s = st();
        return privacy::startOnce(s.tracked, [&s] { unregister(s); }, [&s] { return registerAll(s); });
    }

    void stop() {
        auto& s = st();
        unregister(s);
        s.tracked = false;
        // The displays that showed a capture's look get their content back.
        guarded("capture privacy stop", [] {
            for (const auto& d : st().displays) {
                if (const auto mon = d.monitor.lock(); mon && d.capture.capturing && g_pHyprRenderer)
                    g_pHyprRenderer->damageMonitor(mon);
            }
        });
        s.displays.clear();
    }

    bool protectedWindow(const PHLWINDOW& w) {
        return w && w->m_ruleApplicator && w->m_ruleApplicator->noScreenShare().valueOrDefault();
    }

    bool capturing(const PHLMONITOR& mon) {
        return privacy::capturing(countsOf(mon));
    }

    bool mayDrawContent(bool protectedWindow, const PHLMONITOR& mon) {
        if (!protectedWindow)
            return true;
        bool may = false; // an exception hides the content
        guarded("capture privacy check", [&] { may = mon && privacy::mayDrawContent(true, capturing(mon), st().tracked); });
        return may;
    }

    bool mayDrawContent(const PHLWINDOW& w, const PHLMONITOR& mon) {
        return mayDrawContent(protectedWindow(w), mon);
    }

    std::vector<privacy::Box> subsurfaceBoxes(const PHLWINDOW& w, const privacy::Box& surface) {
        std::vector<privacy::Box> parts;
        if (!w)
            return parts;
        const auto view = w->wlSurface();
        const auto root = view ? view->resource() : nullptr;
        if (!root)
            return parts;
        // The surface's origin: the window's box is its xdg geometry, which starts that far into the surface (client-side
        // shadows). XWayland surfaces have no offset.
        Vector2D origin{surface.x, surface.y};
        if (!w->m_isX11) {
            if (const auto xdg = w->m_xdgSurface.lock())
                origin = origin - xdg->m_current.geometry.pos();
        }
        root->breadthfirst(
            [&parts, &root, origin](const SP<CWLSurfaceResource>& surf, const Vector2D& offset, void* /*data*/) {
                if (!surf || surf == root)
                    return;
                parts.push_back(privacy::Box{origin.x + offset.x, origin.y + offset.y, surf->m_current.size.x, surf->m_current.size.y});
            },
            nullptr);
        return parts;
    }

} // namespace gf::capturePrivacy
