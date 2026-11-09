#include "CapturePrivacy.hpp"

#include "Plugin.hpp"
#include "core/CapturePrivacy.hpp"

#include <hyprland/src/desktop/rule/windowRule/WindowRuleApplicator.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/screenshare/ScreenshareManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
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

        void redrawAll() {
            if (!g_pHyprRenderer || !State::monitorState())
                return;
            for (const auto& m : State::monitorState()->monitors())
                g_pHyprRenderer->damageMonitor(m);
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
            if (privacy::redrawWhole(it->capture, capturing(mon)))
                g_pHyprRenderer->damageMonitor(mon);
        }
    } // namespace

    bool start() {
        auto& s = st();
        if (s.tracked)
            return true;
        auto& bus = Event::bus();
        if (!bus)
            return false;
        s.listeners.push_back(bus->m_events.render.pre.listen([](const PHLMONITOR& mon) { guarded("capture privacy render.pre", [&] { beforeFrame(mon); }); }));
        // A capture's end: Hyprland stops counting a session as sharing 500 ms after its last copied frame, or when it
        // stops, and says so here (CScreenshareSession::screenshareEvents). Nothing else may redraw the displays then, so
        // they are redrawn here for render.pre to see the change. A start needs none: the frame the client waits for is
        // pending before it is drawn, and render.pre sees that.
        s.listeners.push_back(bus->m_events.screenshare.state.listen([](bool started, uint8_t /*type*/, const std::string& /*name*/) {
            if (!started)
                guarded("capture privacy screenshare.state", [] { redrawAll(); });
        }));
        s.tracked = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.listeners.clear();
        s.displays.clear();
        s.tracked = false;
        guarded("capture privacy stop", [] { redrawAll(); });
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

} // namespace gf::capturePrivacy
