#include "FrameProbe.hpp"

#include "Plugin.hpp"
#include "core/FrameLog.hpp"

#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <algorithm>
#include <chrono>
#include <ctime>
#include <format>
#include <memory>
#include <vector>

namespace gf::frameProbe {

    namespace {
        // The ring before the listener that writes into it: members are destroyed in reverse order, so the listener goes
        // first.
        struct SMonitor {
            PHLMONITORREF                      monitor;
            std::unique_ptr<frames::CRing>     ring    = std::make_unique<frames::CRing>();
            std::unique_ptr<frames::CSpanRing> renders = std::make_unique<frames::CSpanRing>();
            CHyprSignalListener                presented;
        };

        struct SState {
            std::vector<CHyprSignalListener> listeners; // monitors added / removed, render begin and end
            std::vector<SMonitor>            monitors;
            frames::CMarkRing                marks;
            frames::CStallRing               stalls; // the event loop's late beats (core stallOf)
            frames::CSpanRing                work;   // the plugin's own work outside a render (work())
            uint64_t                         beats   = 0;
            uint64_t                         beatDue = 0; // when the armed beat is due (0: none armed)
            uint64_t                         beatCpu = 0; // the main thread's CPU time at the previous beat
            SP<CEventLoopTimer>              beatTimer;   // code of this library: removed in stop()
            frames::CRecording               recording;    // off until a start request, at most kMaxRecordingMs
            bool                             holdsRecords = false; // something was recorded since the last drop
            PHLMONITORREF                    rendering;    // the monitor of the latest render.preChecks
            uint64_t                         renderBegin = 0;
            bool                             inRender    = false;
            bool                             ready       = false;
        };

        // Constructed on first use inside a guarded call (R13).
        SState& st() {
            static SState s;
            return s;
        }

        uint64_t microseconds(const Time::steady_tp& tp) {
            return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(tp.time_since_epoch()).count());
        }

        bool sessionLocked() {
            return !g_pSessionLockManager || g_pSessionLockManager->isSessionLocked(); // undecidable: locked (failures stay locked)
        }

        // Forgets every record (the session locked; unload).
        void dropRecords() {
            auto& s = st();
            for (auto& e : s.monitors) {
                if (e.ring)
                    e.ring->clear();
                if (e.renders)
                    e.renders->clear();
            }
            s.marks.clear();
            s.stalls.clear();
            s.work.clear();
            s.beats        = 0;
            s.holdsRecords = false;
        }

        // Whether a record may be written now: a measurement asked for it in the last kMaxRecordingMs and the session is
        // not locked. A lock stops the recording and drops what it held (the password dots redraw on every key).
        bool recordingNow() {
            auto& s = st();
            if (sessionLocked()) {
                s.recording.stop();
                if (s.holdsRecords)
                    dropRecords();
                return false;
            }
            if (!s.recording.active(microseconds(Time::steadyNow()) / 1000))
                return false;
            s.holdsRecords = true;
            return true;
        }

        // The CPU time this thread (Hyprland's main thread: the beats and the renders run on it) has used, in microseconds.
        uint64_t threadCpuUs() {
            timespec ts{};
            if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0)
                return 0;
            return static_cast<uint64_t>(ts.tv_sec) * 1'000'000 + static_cast<uint64_t>(ts.tv_nsec) / 1'000;
        }

        // A beat of the event loop while recording (frames::kBeatUs): a late one records the stall it shows, with the main
        // thread's CPU time since the previous beat (core stallOf); the beats stop with the recording (its end, the lock:
        // nothing is recorded then).
        void beat() {
            auto& s = st();
            if (!s.ready || !s.beatTimer || !recordingNow()) {
                s.beatDue = 0;
                return; // not armed again
            }
            const uint64_t now = microseconds(Time::steadyNow());
            const uint64_t cpu = threadCpuUs();
            if (s.beatDue != 0) {
                if (const auto stall = frames::stallOf(s.beatDue, now, cpu >= s.beatCpu ? cpu - s.beatCpu : 0))
                    s.stalls.push(*stall);
                ++s.beats;
            }
            s.beatDue = now + frames::kBeatUs;
            s.beatCpu = cpu;
            s.beatTimer->updateTimeout(std::chrono::microseconds(frames::kBeatUs));
        }

        void armBeat() {
            auto& s = st();
            if (!g_pEventLoopManager)
                return;
            if (!s.beatTimer) {
                s.beatTimer = makeShared<CEventLoopTimer>(
                    std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { guarded("frame probe beat", [] { beat(); }); }, nullptr);
                g_pEventLoopManager->addTimer(s.beatTimer);
            }
            s.beatDue = microseconds(Time::steadyNow()) + frames::kBeatUs;
            s.beatCpu = threadCpuUs();
            s.beatTimer->updateTimeout(std::chrono::microseconds(frames::kBeatUs));
        }

        void attach(const PHLMONITOR& m) {
            auto& s = st();
            std::erase_if(s.monitors, [](const SMonitor& e) { return e.monitor.expired(); });
            if (!m || std::ranges::any_of(s.monitors, [&m](const SMonitor& e) { return e.monitor.lock() == m; }))
                return;
            SMonitor       e;
            PHLMONITORREF  ref  = m;
            frames::CRing* ring = e.ring.get(); // owned by the entry; the listener dies with it
            e.monitor           = ref;
            e.presented         = m->m_events.presented.listen([ring](const Time::steady_tp& when) {
                guarded("frame probe presented", [&] {
                    if (recordingNow())
                        ring->push(microseconds(when));
                });
            });
            s.monitors.push_back(std::move(e));
        }

        void detach(const PHLMONITOR& m) {
            std::erase_if(st().monitors, [&m](const SMonitor& e) {
                const auto mine = e.monitor.lock();
                return !mine || mine == m;
            });
        }

        // render.preChecks: a frame of `m` may be rendered now (Hyprland skips it when nothing is damaged; then no
        // RENDER_POST follows and the next preChecks starts over).
        void renderBegins(const PHLMONITOR& m) {
            auto& s = st();
            if (!recordingNow()) {
                s.inRender = false;
                return;
            }
            s.rendering   = m;
            s.renderBegin = microseconds(Time::steadyNow());
            s.inRender    = m != nullptr;
        }

        // RENDER_POST: the frame begun at the latest preChecks is rendered and submitted.
        void renderEnds() {
            auto& s = st();
            if (!s.inRender)
                return;
            s.inRender     = false;
            const auto mon = s.rendering.lock();
            if (!mon)
                return;
            const uint64_t now = microseconds(Time::steadyNow());
            for (auto& e : s.monitors) {
                if (e.renders && e.monitor.lock() == mon) {
                    e.renders->push(frames::RenderSpan{.beginUs = s.renderBegin, .cpuUs = now >= s.renderBegin ? now - s.renderBegin : 0});
                    return;
                }
            }
        }
    } // namespace

    bool start() {
        auto& s = st();
        if (s.ready)
            return true;
        auto& bus = Event::bus();
        if (!bus)
            return false;
        auto& ev = bus->m_events.monitor;
        s.listeners.push_back(ev.added.listen([](const PHLMONITOR& m) { guarded("frame probe monitor.added", [&] { attach(m); }); }));
        s.listeners.push_back(ev.removed.listen([](const PHLMONITOR& m) { guarded("frame probe monitor.removed", [&] { detach(m); }); }));
        s.listeners.push_back(ev.destroyMon.listen([](const PHLMONITOR& m) { guarded("frame probe monitor.destroy", [&] { detach(m); }); }));
        auto& render = bus->m_events.render;
        s.listeners.push_back(render.preChecks.listen([](const PHLMONITOR& m) { guarded("frame probe render begin", [&] { renderBegins(m); }); }));
        s.listeners.push_back(gf::compat::onRenderStage([](eRenderStage stage, gf::compat::RenderContext* /*ctx*/) {
            if (stage == RENDER_POST)
                guarded("frame probe render end", [] { renderEnds(); });
        }));
        if (State::monitorState()) {
            for (const auto& m : State::monitorState()->monitors())
                attach(m);
        }
        s.ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.recording.stop();
        s.holdsRecords = false;
        if (s.beatTimer) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.beatTimer);
            s.beatTimer.reset();
        }
        s.beatDue = 0;
        s.beats   = 0;
        s.stalls.clear();
        s.work.clear();
        s.monitors.clear(); // the presented listeners first: they point into the rings
        s.listeners.clear();
        s.marks     = {};
        s.rendering = {};
        s.inRender  = false;
        s.ready     = false;
    }

    bool ready() {
        return st().ready;
    }

    std::string startRecording() {
        auto& s = st();
        if (!s.ready || sessionLocked())
            return R"({"v":"gfc/1","type":"frames-recording","recording":false})";
        const uint64_t nowMs = microseconds(Time::steadyNow()) / 1000;
        s.recording.start(nowMs);
        armBeat();
        return std::format(R"({{"v":"gfc/1","type":"frames-recording","recording":true,"ms":{}}})", frames::kMaxRecordingMs);
    }

    std::string json() {
        if (sessionLocked()) {
            st().recording.stop();
            dropRecords();
            return frames::framesJson({});
        }
        std::vector<frames::MonitorFrames> out;
        for (const auto& e : st().monitors) {
            const auto m = e.monitor.lock();
            if (!m || !e.ring)
                continue;
            out.push_back(frames::MonitorFrames{.name        = m->m_name,
                                                .refreshHz   = m->m_refreshRate,
                                                .total       = e.ring->total(),
                                                .presentedUs = e.ring->snapshot(),
                                                .renders     = e.renders ? e.renders->snapshot() : std::vector<frames::RenderSpan>{}});
        }
        const auto                marks = st().marks.snapshot();
        const frames::LoopRecords loop{.beats = st().beats, .stalls = st().stalls.snapshot(), .work = st().work.snapshot()};
        return frames::framesJson(out, marks, loop);
    }

    uint64_t nowUs() {
        return microseconds(Time::steadyNow());
    }

    void work(uint64_t beginUs) {
        auto& s = st();
        if (!s.ready || !recordingNow())
            return;
        const uint64_t now = microseconds(Time::steadyNow());
        s.work.push(frames::RenderSpan{.beginUs = beginUs, .cpuUs = now >= beginUs ? now - beginUs : 0});
    }

    void mark(std::string_view what) {
        auto& s = st();
        if (s.ready && recordingNow())
            s.marks.push(microseconds(Time::steadyNow()), what);
    }

} // namespace gf::frameProbe
