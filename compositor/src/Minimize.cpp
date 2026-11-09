#include "Minimize.hpp"

#include "CapturePrivacy.hpp"
#include "ClientChrome.hpp"
#include "GenieDraw.hpp"
#include "Ipc.hpp"
#include "Plugin.hpp"
#include "core/Genie.hpp"
#include "core/Protocol.hpp"
#include "core/Theme.hpp"

#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/helpers/MiscFunctions.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/state/WorkspaceQuery.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <format>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace mz = gf::minimize;

namespace {
    // The hidden state. Same name as the shell's fallback (shell/platform/Compositor.qml minimizedWorkspace).
    constexpr std::string_view MINIMIZED_WORKSPACE = "special:minimized";

    // Completes animations whose frames stopped (no monitor rendered): longer than any animation (Genie: 500 ms).
    constexpr auto WATCHDOG_DELAY = std::chrono::milliseconds(600);

    // A Genie element is a custom pass element: if Hyprland never draws one (not one draw after this many were added),
    // Genie is disabled and the Scale effect takes over.
    constexpr uint64_t GENIE_UNDRAWN_LIMIT = 10;

    // Frame timing of an animation on its snapshot's monitor (the plugin's own measure, logged at the end): interval
    // between two frames of that monitor (render.preChecks) and the CPU time of each frame (render.preChecks to the
    // RENDER_POST stage), plus the longest Genie draw (CPU time of its GL calls).
    struct STiming {
        std::optional<Time::steady_tp> lastFrame;
        std::optional<Time::steady_tp> frameStart;
        int                            frames      = 0;
        double                         sumInterval = 0, maxInterval = 0; // ms
        int                            rendered    = 0;
        double                         sumRender = 0, maxRender = 0; // ms
        double                         maxDrawMicros = 0;
    };

    struct SAnimation {
        mz::Kind                     kind   = mz::Kind::Minimize;
        mz::Effect                   effect = mz::Effect::Scale; // what runs (Genie only when it can be drawn)
        PHLWINDOWREF                 window;
        uint64_t                     address = 0;
        SP<Render::IFramebuffer>     snapshot;
        mz::SSnapshotGeometry        geometry; // visible box (titlebar + border + surface) in the snapshot
        mz::Box                      full;     // with every decoration extent (shadow): what gets damaged
        mz::Box                      from;     // Scale: the box at the start and at the end
        mz::Box                      to;
        mz::Box                      tileFit; // where the window ends: its visible box fitted into the Dock tile
        mz::Edge                     edge = mz::Edge::Bottom;
        mz::Box                      region; // Genie: the full box inside the snapshot, what the mesh covers (layout)
        Time::steady_tp              start;
        double                       timeScale = 1.0; // kSlowMotionFactor when Shift was held at the start
        mz::Frame                    frame;
        double                       progress = 0; // Genie: 0 window .. 1 tile
        std::vector<mz::SMeshVertex> mesh;         // Genie: this frame's mesh (layout)
        mz::Box                      damaged;      // last damaged visual box (layout)
        std::vector<mz::Box>         damagedBands; // funnel: the bands damaged last frame (layout), repainted next frame
        uintptr_t                    monitorKey = 0; // the snapshot's monitor (timing only: compared, never dereferenced)
        STiming                      timing;
        bool                         noScreenShare = false; // hidden from captures when it started (SEC-01): its snapshot too
    };

    // Where a window minimized by the plugin was (owner decision D-1): its display and frame, given back by restore().
    struct SWindowPlace {
        PHLWINDOWREF      window;
        mz::SavedPlace    place;
    };

    struct SMinimizeState {
        bool                             ready = false;
        std::vector<SWindowPlace>        places; // one per minimized window; dropped at its restore, close or move elsewhere
        std::vector<SAnimation>          animations;
        std::vector<CHyprSignalListener> listeners;
        SP<CEventLoopTimer>              watchdog;
        // Settings dock.minimizeEffect (fade while Reduce Motion is on), pushed by the shell. Genie is macOS's default.
        mz::Effect effect     = mz::Effect::Genie;
        uint64_t   genieAdded = 0; // Genie elements handed to Hyprland since load
        uintptr_t  renderingKey = 0; // monitor of the latest render.preChecks (frame timing; compared, never dereferenced)
        // The Dock rectangle line of each minimize has a budget of its own (20 at once, then 2 per second; spec FR24):
        // tests read it, and the shared request budget is often spent by titlebar and Stages lines during a soak.
        gf::events::CLogLimiter targetLog{20, std::chrono::milliseconds(500)};
        // The timing line at the end of each animation (same budget, its own).
        gf::events::CLogLimiter timingLog{20, std::chrono::milliseconds(500)};
    };

    // Constructed on first use inside a guarded call (R13). Emptied by stop() before dlclose.
    SMinimizeState& st() {
        static SMinimizeState s;
        return s;
    }

    std::string hexAddress(uint64_t address) {
        return std::format("{:x}", address);
    }

    // minimized / restored: two values of one per-window state, coalesced under one key (spec FR24).
    void postState(mz::Kind kind, uint64_t address) {
        gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::MinimizeState, .id = address},
                           kind == mz::Kind::Minimize ? gf::gfc::minimizedJson(hexAddress(address)) : gf::gfc::restoredJson(hexAddress(address)));
    }

    mz::Box toBox(const CBox& b) {
        return mz::Box{b.x, b.y, b.w, b.h};
    }

    CBox toCBox(const mz::Box& b) {
        return CBox{b.x, b.y, b.w, b.h};
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

    bool onMinimizedWorkspace(const PHLWINDOW& w) {
        return w->m_workspace && w->m_workspace->m_isSpecialWorkspace && w->m_workspace->m_name == MINIMIZED_WORKSPACE;
    }

    // Surface box plus the reserved decoration extents (titlebar, border): what the user sees as the window.
    mz::Box visibleBox(const PHLWINDOW& w) {
        CBox box = w->getWindowMainSurfaceBox();
        box.addExtents(w->getWindowExtentsUnified(Desktop::View::RESERVED_EXTENTS));
        return toBox(box);
    }

    mz::Box fullBox(const PHLWINDOW& w) {
        CBox box = w->getWindowMainSurfaceBox();
        box.addExtents(w->getWindowExtentsUnified(Desktop::View::FULL_EXTENTS | Desktop::View::RESERVED_EXTENTS));
        return toBox(box.expand(2.0));
    }

    // Removes and returns the window's running animation (at most one per window).
    std::optional<SAnimation> takeAnimation(const PHLWINDOW& w) {
        auto&      all = st().animations;
        const auto it  = std::ranges::find_if(all, [&w](const SAnimation& a) { return a.window.lock() == w; });
        if (it == all.end())
            return std::nullopt;
        SAnimation a = std::move(*it);
        all.erase(it);
        return a;
    }

    // Snapshots are GL framebuffers: delete them with Hyprland's context current. Never called while a frame
    // is being built (only from Lua calls, render.preChecks, the watchdog and unload).
    void releaseSnapshot(SP<Render::IFramebuffer>& fb) {
        if (!fb)
            return;
        if (g_pHyprRenderer && g_pHyprRenderer->type() == Render::IHyprRenderer::RT_GL && Render::GL::g_pHyprOpenGL)
            Render::GL::g_pHyprOpenGL->makeEGLCurrent();
        fb.reset();
    }

    SP<Render::IFramebuffer> takeSnapshot(const PHLWINDOW& w) {
        if (!g_pHyprRenderer)
            return nullptr;
        // nullptr when Hyprland would not render the window now (hidden workspace, no monitor).
        auto fb = g_pHyprRenderer->makeSnapshotFB(w);
        if (!fb || !fb->getTexture())
            return nullptr;
        return fb;
    }

    const char* effectName(mz::Effect effect) {
        switch (effect) {
            case mz::Effect::Genie: return "funnel";
            case mz::Effect::Scale: return "shrink";
            case mz::Effect::Fade: return "fade";
        }
        return "?";
    }

    // Where the animation is drawn this frame (layout): the mesh's box for Genie, the mapped full box otherwise.
    mz::Box visualBox(const SAnimation& a) {
        if (a.effect == mz::Effect::Genie) {
            const mz::Box b = mz::meshBounds(a.mesh);
            return mz::Box{b.x - 2.0, b.y - 2.0, b.w + 4.0, b.h + 4.0};
        }
        return mz::mapBox(a.full, a.geometry.visible, a.frame.box);
    }

    void damage(SAnimation& a) {
        if (!g_pHyprRenderer)
            return;
        // The previous frame: the funnel's bands when it drew them, else the box it drew in.
        if (!a.damagedBands.empty()) {
            for (const auto& b : a.damagedBands)
                g_pHyprRenderer->damageBox(toCBox(b));
            a.damagedBands.clear();
        } else if (a.damaged.w > 0 && a.damaged.h > 0)
            g_pHyprRenderer->damageBox(toCBox(a.damaged));
        const mz::Box visual = visualBox(a);
        a.damaged            = visual; // what complete() and cancelFor() repaint
        if (a.effect == mz::Effect::Genie && !a.mesh.empty()) {
            // Band by band (core meshBands): the empty sides of the funnel's neck, and the Dock beside the tile with its
            // blurred material, are not repainted every frame.
            for (const auto& b : mz::meshBands(a.mesh, mz::kGenieAcross, mz::kGenieAlong, mz::kGenieLinesPerDamageBand)) {
                a.damagedBands.push_back(mz::Box{b.x - 2.0, b.y - 2.0, b.w + 4.0, b.h + 4.0});
                g_pHyprRenderer->damageBox(toCBox(a.damagedBands.back()));
            }
            return;
        }
        g_pHyprRenderer->damageBox(toCBox(visual));
    }

    // The window, transparent while its restore animation runs, becomes visible again.
    void showWindow(const PHLWINDOW& w) {
        auto& fadeIn = w->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE);
        if (fadeIn)
            fadeIn->setValueAndWarp(1.F);
        if (g_pHyprRenderer)
            g_pHyprRenderer->damageWindow(w);
    }

    // One line per finished animation with its frame timing (tests and the soak read it; a log budget of its own).
    void logTiming(const SAnimation& a, double elapsedMs) {
        const auto& t = a.timing;
        if (t.frames == 0)
            return;
        const auto held = st().timingLog.admit(gf::events::Clock::now());
        if (!held)
            return;
        // The speed is stated on every line (tests separate slow-motion animations from normal ones by it, never by their
        // duration: a normal animation that stalled lasts as long as a slow one).
        gf::log(Log::INFO,
                "minimize {:x}: {} {} in {:.0f} ms, {} frames, frame interval avg {:.1f} max {:.1f} ms, frame cpu avg {:.2f} max {:.2f} ms, genie draw max {:.0f} us, "
                "speed {}{}",
                a.address, effectName(a.effect), a.kind == mz::Kind::Minimize ? "minimize" : "restore", elapsedMs, t.frames,
                t.frames > 1 ? t.sumInterval / (t.frames - 1) : 0.0, t.maxInterval, t.rendered > 0 ? t.sumRender / t.rendered : 0.0, t.maxRender, t.maxDrawMicros,
                a.timeScale > 1.0 ? "slow" : "normal", *held > 0 ? std::format(" ({} similar line(s) held back)", *held) : std::string{});
    }

    // Ends an animation: final state, snapshot dropped, optional event. `a` is erased by the caller.
    void complete(SAnimation& a, bool postEvent) {
        if (postEvent)
            logTiming(a, std::chrono::duration<double, std::milli>(Time::steadyNow() - a.start).count());
        if (g_pHyprRenderer && a.damaged.w > 0)
            g_pHyprRenderer->damageBox(toCBox(a.damaged));
        const auto w = a.window.lock();
        if (a.kind == mz::Kind::Restore && w)
            showWindow(w);
        releaseSnapshot(a.snapshot);
        if (postEvent && w)
            postState(a.kind, a.address);
    }

    void completeAll(bool postEvents) {
        auto animations = std::exchange(st().animations, {});
        for (auto& a : animations)
            complete(a, postEvents);
    }

    // The window closed (or unmapped) mid-animation: drop the visual, no event.
    void cancelFor(const PHLWINDOW& w) {
        auto& all = st().animations;
        for (auto it = all.begin(); it != all.end();) {
            const auto aw = it->window.lock();
            if (!aw || aw == w) {
                if (g_pHyprRenderer && it->damaged.w > 0)
                    g_pHyprRenderer->damageBox(toCBox(it->damaged));
                releaseSnapshot(it->snapshot);
                it = all.erase(it);
            } else
                ++it;
        }
    }

    // Genie mesh of this frame (layout coordinates).
    void updateMesh(SAnimation& a) {
        const mz::CGenie genie{a.geometry.visible, a.tileFit, a.edge};
        mz::genieMesh(genie, a.geometry.visible, a.region, a.progress, mz::kGenieAcross, mz::kGenieAlong, a.mesh);
    }

    // The frame of `a` after elapsedMs, for its effect.
    void step(SAnimation& a, double elapsedMs) {
        switch (a.effect) {
            case mz::Effect::Genie: {
                const auto g = mz::genieFrameAt(a.kind, elapsedMs);
                a.progress   = g.progress;
                a.frame      = mz::Frame{.box = a.geometry.visible, .alpha = g.alpha, .done = g.done};
                updateMesh(a);
                return;
            }
            case mz::Effect::Fade: a.frame = mz::fadeFrameAt(a.kind, a.geometry.visible, elapsedMs); return;
            case mz::Effect::Scale: a.frame = mz::frameAt(a.kind, a.from, a.to, elapsedMs); return;
        }
    }

    // A running funnel animation goes on as a shrink one from about where it is: the shrink's elapsed time is set to the
    // same share of its own duration as the funnel's progress (minimize: progress, restore: 1 - progress).
    void toShrink(SAnimation& a) {
        const double share = a.kind == mz::Kind::Minimize ? a.progress : 1.0 - a.progress;
        a.effect           = mz::Effect::Scale;
        a.from             = a.kind == mz::Kind::Minimize ? a.geometry.visible : a.tileFit;
        a.to               = a.kind == mz::Kind::Minimize ? a.tileFit : a.geometry.visible;
        a.mesh.clear();
        const double elapsedMs = std::clamp(share, 0.0, 1.0) * mz::durationMs(a.kind) * a.timeScale;
        a.start                = Time::steadyNow() - std::chrono::duration_cast<Time::steady_dur>(std::chrono::duration<double, std::milli>(elapsedMs));
    }

    // FR46: the funnel cannot be drawn any more (shader compile or link failure, a GL error after a draw, Hyprland never
    // drawing the custom elements): every running funnel animation continues as a shrink one, never as nothing.
    void checkFunnelUsable() {
        auto& s = st();
        if (s.genieAdded >= GENIE_UNDRAWN_LIMIT && gf::genie::drawnCount() == 0)
            gf::genie::disable("Hyprland did not draw the custom pass elements");
        if (gf::genie::available())
            return;
        for (auto& a : s.animations) {
            if (a.effect == mz::Effect::Genie)
                toShrink(a);
        }
    }

    // Frame timing on the snapshot's monitor (render.preChecks of that monitor). Hyprland renders one monitor at a time:
    // the RENDER_POST stage that follows belongs to the monitor of the latest render.preChecks.
    void frameStarted(const PHLMONITOR& mon, Time::steady_tp now) {
        const auto key    = reinterpret_cast<uintptr_t>(mon.get());
        st().renderingKey = key;
        for (auto& a : st().animations) {
            if (a.monitorKey != key)
                continue;
            auto& t = a.timing;
            if (t.lastFrame) {
                const double interval = std::chrono::duration<double, std::milli>(now - *t.lastFrame).count();
                t.sumInterval += interval;
                t.maxInterval = std::max(t.maxInterval, interval);
            }
            t.lastFrame  = now;
            t.frameStart = now;
            ++t.frames;
        }
    }

    // RENDER_POST (the frame is rendered, Genie draws included, and submitted): the frame's CPU time since the
    // render.preChecks of its monitor.
    void frameEnded() {
        auto& all = st().animations;
        if (all.empty())
            return;
        const auto   key   = std::exchange(st().renderingKey, 0);
        const auto   now   = Time::steadyNow();
        const double drawn = gf::genie::takeMaxDrawMicros();
        for (auto& a : all) {
            auto& t = a.timing;
            if (a.monitorKey != key || !t.frameStart)
                continue;
            const double ms = std::chrono::duration<double, std::milli>(now - *t.frameStart).count();
            t.frameStart.reset();
            t.sumRender += ms;
            t.maxRender = std::max(t.maxRender, ms);
            ++t.rendered;
            t.maxDrawMicros = std::max(t.maxDrawMicros, drawn);
        }
    }

    // One step of every animation; called before each monitor frame (render.preChecks, like Hyprland's
    // Animation::mgr()->frameTick()) and by the watchdog. Damages the old and new boxes, which also schedules
    // the next frame on the monitors they touch.
    void tick() {
        auto& all = st().animations;
        if (all.empty())
            return;
        checkFunnelUsable();
        const auto now = Time::steadyNow();
        for (auto it = all.begin(); it != all.end();) {
            const auto w = it->window.lock();
            if (!w || !w->m_isMapped) {
                if (g_pHyprRenderer && it->damaged.w > 0)
                    g_pHyprRenderer->damageBox(toCBox(it->damaged));
                releaseSnapshot(it->snapshot);
                it = all.erase(it);
                continue;
            }
            step(*it, std::chrono::duration<double, std::milli>(now - it->start).count() / it->timeScale);
            damage(*it);
            if (it->frame.done) {
                complete(*it, true);
                it = all.erase(it);
            } else
                ++it;
        }
    }

    void armWatchdog() {
        auto& s = st();
        if (!g_pEventLoopManager)
            return;
        if (!s.watchdog) {
            s.watchdog = makeShared<CEventLoopTimer>(
                std::nullopt,
                [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) {
                    gf::guarded("minimize watchdog", [] {
                        tick();
                        if (!st().animations.empty() && st().watchdog)
                            st().watchdog->updateTimeout(WATCHDOG_DELAY);
                    });
                },
                nullptr);
            g_pEventLoopManager->addTimer(s.watchdog);
        }
        s.watchdog->updateTimeout(WATCHDOG_DELAY);
    }

    // Shift held on any keyboard (macOS: Shift-click plays the minimize in slow motion).
    bool shiftHeld() {
        return g_pInputManager && (g_pInputManager->getModsFromAllKBs() & HL_MODIFIER_SHIFT) != 0;
    }

    // `elapsedMs`: where the animation starts, in animation time (an interrupted Genie continues from the shape on
    // screen). Slow motion when Shift is held now.
    void startAnimation(SAnimation&& a, double elapsedMs = 0.0) {
        a.timeScale = shiftHeld() ? mz::kSlowMotionFactor : 1.0;
        (void)gf::genie::takeMaxDrawMicros(); // a draw of an earlier animation is not this one's
        a.start     = Time::steadyNow() - std::chrono::duration_cast<Time::steady_dur>(std::chrono::duration<double, std::milli>(elapsedMs * a.timeScale));
        step(a, elapsedMs);
        damage(a);
        st().animations.push_back(std::move(a));
        armWatchdog();
    }

    // The Genie mesh of `a` on the monitor being rendered: positions in its pixels, texture coordinates in the snapshot.
    // With Hyprland's box projection the snapshot texture is sampled top-down (t = 0 at the monitor's top edge;
    // measured in nested: 1 - t drew the window upside down).
    void drawGenie(const SAnimation& a, const SP<Render::ITexture>& tex, const PHLMONITOR& mon) {
        if (a.mesh.empty())
            return;
        const auto&          g     = a.geometry;
        const mz::Box&       v     = g.visible;
        const double         scale = mon->m_scale;
        gf::genie::SDrawData data;
        data.tex    = tex;
        data.across = mz::kGenieAcross;
        data.along  = mz::kGenieAlong;
        data.alpha  = a.frame.alpha;
        data.vertices.reserve(a.mesh.size() * 4);
        for (const auto& m : a.mesh) {
            const double sx = v.x + (m.u * v.w), sy = v.y + (m.v * v.h); // the source point (layout)
            data.vertices.push_back(static_cast<float>((m.x - mon->m_position.x) * scale));
            data.vertices.push_back(static_cast<float>((m.y - mon->m_position.y) * scale));
            data.vertices.push_back(static_cast<float>(g.texW > 0 ? ((sx - g.monitorX) * g.monitorScale) / g.texW : 0.0));
            data.vertices.push_back(static_cast<float>(g.texH > 0 ? ((sy - g.monitorY) * g.monitorScale) / g.texH : 0.0));
        }
        const mz::Box b    = mz::meshBounds(a.mesh);
        data.logicalBounds = CBox{b.x - mon->m_position.x, b.y - mon->m_position.y, b.w, b.h}.expand(1.0);
        data.pixelBounds   = CBox{data.logicalBounds}.scale(scale).round();
        if (data.pixelBounds.w < 1 || data.pixelBounds.h < 1)
            return;
        ++st().genieAdded;
        g_pHyprRenderer->addPassElement(makeUnique<gf::genie::CGenieElement>(std::move(data)));
    }

    // Draws every animation that touches the monitor being rendered. RENDER_POST_WINDOWS: after the windows,
    // before the top layers (menu bar, Dock); not emitted while the session is locked (no window content on
    // the lock screen).
    void draw() {
        auto& all = st().animations;
        if (all.empty() || !g_pHyprRenderer)
            return;
        const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!mon)
            return;
        const mz::Box monBox{mon->m_position.x, mon->m_position.y, mon->m_size.x, mon->m_size.y};
        for (const auto& a : all) {
            if (!a.snapshot || a.frame.alpha <= 0.F)
                continue;
            // SEC-01: a window hidden from captures is hidden, or transparent, while its snapshot moves, so Hyprland blacks
            // out nothing of it here: while this display is captured its animation is not drawn, on screen too
            // (core/CapturePrivacy.hpp). The window just goes, or comes back at the end.
            if (!gf::capturePrivacy::mayDrawContent(a.noScreenShare || gf::capturePrivacy::protectedWindow(a.window.lock()), mon))
                continue;
            const auto tex = a.snapshot->getTexture();
            if (!tex)
                continue;
            const mz::Box visual = visualBox(a);
            if (!mz::intersects(visual, monBox))
                continue;
            if (a.effect == mz::Effect::Genie) {
                drawGenie(a, tex, mon);
                continue;
            }
            const mz::Box texBox = mz::textureBox(a.geometry, a.frame.box, mon->m_position.x, mon->m_position.y, mon->m_scale);

            CTexPassElement::SRenderData data;
            data.tex          = tex;
            data.box          = toCBox(texBox);
            data.a            = a.frame.alpha;
            data.flipEndFrame = true; // framebuffer texture, as Hyprland draws its fadeouts
            data.clipBox      = toCBox(visual).translate(-mon->m_position).scale(mon->m_scale).round();
            g_pHyprRenderer->addPassElement(makeUnique<CTexPassElement>(std::move(data)));
        }
    }

    PHLWORKSPACE minimizedWorkspace() {
        const auto [id, name, isAutoID] = getWorkspaceIDNameFromString(std::string{MINIMIZED_WORKSPACE});
        if (id == WORKSPACE_INVALID)
            return nullptr;
        auto ws = State::workspaceState()->query().id(id).run();
        if (!ws) {
            const auto mon = Desktop::focusState()->monitor();
            if (mon)
                ws = State::workspaceState()->create(id, mon->m_id, name, false);
        }
        return ws;
    }

    // Moves the window to special:minimized without following it. Hyprland fades a window out in place when it
    // leaves a visible workspace; the snapshot animation replaces that fade, so it is completed at once.
    bool hideOnMinimized(const PHLWINDOW& w) {
        const auto ws = minimizedWorkspace();
        if (!ws) {
            gf::log(Log::WARN, "minimize: cannot resolve {}", MINIMIZED_WORKSPACE);
            return false;
        }
        if (const auto result = Config::Actions::moveToWorkspace(ws, true, w); !result) {
            gf::log(Log::WARN, "minimize: move to {} failed: {}", MINIMIZED_WORKSPACE, result.error().message);
            return false;
        }
        if (auto& fadeOut = w->alpha(Desktop::View::WINDOW_ALPHA_MOVE_TO_WORKSPACE); fadeOut && fadeOut->isBeingAnimated())
            fadeOut->warp();
        return onMinimizedWorkspace(w);
    }

    std::vector<mz::Box> monitorBoxes() {
        std::vector<mz::Box> out;
        if (!State::monitorState())
            return out;
        for (const auto& m : State::monitorState()->monitors()) {
            if (m)
                out.push_back(mz::Box{m->m_position.x, m->m_position.y, m->m_size.x, m->m_size.y});
        }
        return out;
    }

    mz::SSnapshotGeometry snapshotGeometry(const PHLWINDOW& w, const PHLMONITOR& mon) {
        return mz::SSnapshotGeometry{.visible      = visibleBox(w),
                                     .monitorX     = mon->m_position.x,
                                     .monitorY     = mon->m_position.y,
                                     .monitorScale = mon->m_scale,
                                     .texW         = mon->m_transformedSize.x,
                                     .texH         = mon->m_transformedSize.y};
    }

    // The monitor box (layout) that holds the centre of `rect`.
    std::optional<mz::Box> monitorBoxAt(const mz::Box& rect) {
        const double cx = rect.x + (rect.w / 2.0), cy = rect.y + (rect.h / 2.0);
        for (const auto& m : monitorBoxes()) {
            if (cx >= m.x && cx < m.x + m.w && cy >= m.y && cy < m.y + m.h)
                return m;
        }
        return std::nullopt;
    }

    mz::Box intersection(const mz::Box& a, const mz::Box& b) {
        const double x0 = std::max(a.x, b.x), y0 = std::max(a.y, b.y);
        const double x1 = std::min(a.x + a.w, b.x + b.w), y1 = std::min(a.y + a.h, b.y + b.h);
        return x1 > x0 && y1 > y0 ? mz::Box{x0, y0, x1 - x0, y1 - y0} : mz::Box{};
    }

    // The effect an animation runs: the configured one, except that Genie needs the GL drawing, an untransformed
    // snapshot monitor and a Dock tile toward the Dock edge from the window (core isGenieGeometry); Scale otherwise.
    mz::Effect effectFor(const mz::SSnapshotGeometry& geometry, const mz::Box& tile, const mz::Box& tileFit, const PHLMONITOR& mon, mz::Edge& edge) {
        const auto wanted = st().effect;
        if (wanted != mz::Effect::Genie)
            return wanted;
        if (!gf::genie::available() || mon->m_transform != WL_OUTPUT_TRANSFORM_NORMAL)
            return mz::Effect::Scale;
        const auto tileMonitor = monitorBoxAt(tile);
        if (!tileMonitor)
            return mz::Effect::Scale;
        edge = mz::dockEdge(tile, *tileMonitor);
        return mz::isGenieGeometry(geometry.visible, tileFit, edge) ? mz::Effect::Genie : mz::Effect::Scale;
    }

    // ---- D-1: the display and frame a window is restored to ----

    // The display under the middle of `box` (layout). The plugin's own titlebar drags do not update a window's m_monitor
    // (Tiling.cpp): where the user sees the window is what counts.
    PHLMONITOR monitorUnder(const mz::Box& box) {
        if (!State::monitorState())
            return nullptr;
        const Vector2D middle{box.x + (box.w / 2.0), box.y + (box.h / 2.0)};
        for (const auto& m : State::monitorState()->monitors()) {
            if (m && m->m_enabled && m->logicalBox().containsPoint(middle))
                return m;
        }
        return nullptr;
    }

    // A floating window that is not full screen or zoomed: its frame is its own (what tiler::placeable checks too).
    bool keepsFrame(const PHLWINDOW& w) {
        if (!w->m_isFloating || w->m_pinned || !w->layoutTarget())
            return false;
        const auto& fs = Fullscreen::controller();
        return !fs || fs->getFullscreenModes(w).internal == Fullscreen::FSMODE_NONE;
    }

    // Where `w` is now: its display and, when it keeps a frame, its floating box (layout).
    std::optional<mz::SavedPlace> placeOf(const PHLWINDOW& w) {
        auto mon = monitorUnder(visibleBox(w));
        if (!mon)
            mon = w->m_monitor.lock();
        if (!mon)
            return std::nullopt;
        mz::SavedPlace place{.monitor = mon->m_name, .monitorBox = toBox(mon->logicalBox()), .frame = {}, .floating = keepsFrame(w)};
        if (place.floating)
            place.frame = toBox(w->layoutTarget()->position());
        return place;
    }

    void forgetPlace(const PHLWINDOW& w) {
        std::erase_if(st().places, [&w](const SWindowPlace& p) {
            const auto pw = p.window.lock();
            return !pw || pw == w;
        });
    }

    void rememberPlace(const PHLWINDOW& w, mz::SavedPlace&& place) {
        forgetPlace(w);
        st().places.push_back(SWindowPlace{.window = w, .place = std::move(place)});
    }

    std::optional<mz::SavedPlace> takePlace(const PHLWINDOW& w) {
        auto&      all = st().places;
        const auto it  = std::ranges::find_if(all, [&w](const SWindowPlace& p) { return p.window.lock() == w; });
        if (it == all.end())
            return std::nullopt;
        auto place = std::move(it->place);
        all.erase(it);
        return place;
    }

    struct SRestoreTarget {
        PHLMONITOR             monitor; // the display whose current Desktop takes the window
        std::optional<mz::Box> frame;   // the box it gets back (layout)
        bool                   moved = false;
    };

    // core planRestore over the enabled displays (each showing a Desktop); the focused display without a plan.
    // `band`: the titlebar above the window's surface (none for a window that draws its own chrome, ADR-0015).
    SRestoreTarget restoreTarget(const std::optional<mz::SavedPlace>& saved, double band) {
        const auto                    focusMon = Desktop::focusState() ? Desktop::focusState()->monitor() : nullptr;
        std::vector<PHLMONITOR>       mons;
        std::vector<mz::MonitorPlace> places;
        std::optional<size_t>         focused;
        if (State::monitorState()) {
            for (const auto& m : State::monitorState()->monitors()) {
                if (!m || !m->m_enabled || !m->m_activeWorkspace)
                    continue;
                if (m == focusMon)
                    focused = mons.size();
                mons.push_back(m);
                places.push_back(mz::MonitorPlace{.name = m->m_name, .box = toBox(m->logicalBox()), .usable = toBox(m->logicalBoxMinusReserved())});
            }
        }
        const auto     plan = mz::planRestore(saved, places, focused, band);
        SRestoreTarget out;
        out.monitor = plan.monitor && *plan.monitor < mons.size() ? mons[*plan.monitor] : focusMon;
        out.frame   = plan.frame;
        out.moved   = plan.moved;
        return out;
    }

    // A minimize (window -> tile) or restore (tile -> window) animation of `w` toward / from the Dock tile.
    SAnimation makeAnimation(mz::Kind kind, const PHLWINDOW& w, uint64_t address, SP<Render::IFramebuffer>&& snapshot, const mz::SSnapshotGeometry& geometry,
                             const mz::Box& full, const mz::Box& tile, const PHLMONITOR& mon) {
        SAnimation a;
        a.kind     = kind;
        a.window   = w;
        a.address  = address;
        a.snapshot = std::move(snapshot);
        a.geometry = geometry;
        a.full     = full;
        a.tileFit  = mz::fitInside(geometry.visible, tile);
        a.effect   = effectFor(geometry, tile, a.tileFit, mon, a.edge);
        a.from     = kind == mz::Kind::Minimize ? geometry.visible : a.tileFit;
        a.to       = kind == mz::Kind::Minimize ? a.tileFit : geometry.visible;
        // The mesh covers what the snapshot holds of the window (its shadow may leave the monitor).
        const double scale = geometry.monitorScale > 0 ? geometry.monitorScale : 1.0;
        a.region           = intersection(full, mz::Box{geometry.monitorX, geometry.monitorY, geometry.texW / scale, geometry.texH / scale});
        if (a.effect == mz::Effect::Genie && (a.region.w <= 0 || a.region.h <= 0))
            a.effect = mz::Effect::Scale;
        a.monitorKey    = reinterpret_cast<uintptr_t>(mon.get());
        a.noScreenShare = gf::capturePrivacy::protectedWindow(w);
        return a;
    }
} // namespace

namespace gf::minimizer {

    bool start() {
        auto& bus = Event::bus();
        if (!bus)
            return false;
        auto& ev = bus->m_events;
        auto& l  = st().listeners;
        l.push_back(ev.render.preChecks.listen([](const PHLMONITOR& monitor) {
            gf::guarded("minimize tick", [&] {
                if (monitor)
                    frameStarted(monitor, Time::steadyNow());
                tick();
            });
        }));
        l.push_back(ev.render.stage.listen([](eRenderStage stage) {
            if (stage == RENDER_POST_WINDOWS)
                gf::guarded("minimize draw", [] { draw(); });
            else if (stage == RENDER_POST)
                gf::guarded("minimize frame timing", [] { frameEnded(); });
        }));
        l.push_back(ev.window.close.listen([](const PHLWINDOW& w) {
            gf::guarded("minimize window.close", [&] {
                cancelFor(w);
                forgetPlace(w);
            });
        }));
        // A minimized window that leaves special:minimized by another way than restore() (a dispatch, the shell's fallback)
        // drops its recorded place: a later restore must not use a stale one.
        l.push_back(ev.window.moveToWorkspace.listen([](const PHLWINDOW& w, const PHLWORKSPACE& ws) {
            gf::guarded("minimize window.moveToWorkspace", [&] {
                if (w && !(ws && ws->m_isSpecialWorkspace && ws->m_name == MINIMIZED_WORKSPACE))
                    forgetPlace(w);
            });
        }));
        // Monitor changes: positions and scales captured with the snapshots are stale; finish at once.
        l.push_back(ev.monitor.removed.listen([](const PHLMONITOR& /*monitor*/) { gf::guarded("minimize monitor.removed", [] { completeAll(true); }); }));
        l.push_back(ev.monitor.layoutChanged.listen([] { gf::guarded("minimize monitor.layoutChanged", [] { completeAll(true); }); }));
        // A library pinned at an earlier unload (FR23) keeps its statics: a load starts the funnel afresh.
        gf::genie::reset();
        st().genieAdded = 0;
        // Places recorded before an unload survive it when the library stayed mapped (FR23): they hold no code of this
        // library. A window that left special:minimized meanwhile (no listener while unloaded) drops its place.
        std::erase_if(st().places, [](const SWindowPlace& p) {
            const auto w = p.window.lock();
            return !w || !onMinimizedWorkspace(w);
        });
        st().ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.ready = false;
        s.listeners.clear();
        // Funnel elements still queued in a render pass would be destroyed (and drawn) after dlclose with their vtable gone:
        // remove them (CRenderPass::removeAllOfType compares IPassElement::passName). Unload never runs inside a frame, so
        // the pass is normally empty; this covers a frame that queued them and did not render them.
        if (g_pHyprRenderer) {
            g_pHyprRenderer->m_renderPass.removeAllOfType(gf::genie::kPassName);
            if (auto& current = g_pHyprRenderer->currentPass(); &current != &g_pHyprRenderer->m_renderPass)
                current.removeAllOfType(gf::genie::kPassName);
        }
        completeAll(false); // the recorded places stay (plain data and Hyprland's weak references): see start()
        if (s.watchdog) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.watchdog);
            s.watchdog.reset();
        }
        gf::genie::release(); // GL objects deleted with Hyprland's context current, before dlclose
    }

    bool ready() {
        return st().ready;
    }

    void setEffect(mz::Effect effect) {
        st().effect = effect;
    }

    mz::Effect effect() {
        return st().effect;
    }

    std::optional<mz::Box> validTarget(const mz::Box& rect) {
        const auto monitors = monitorBoxes();
        if (!mz::isValidTarget(rect, monitors))
            return std::nullopt;
        return rect;
    }

    void minimize(uint64_t address, std::optional<mz::Box> target) {
        const auto w = windowByAddress(address);
        if (!w || !w->m_isMapped) {
            gf::logRequest(Log::WARN, "minimize: no mapped window {:x}", address);
            return;
        }
        if (onMinimizedWorkspace(w)) {
            gf::logRequest(Log::DEBUG, "minimize: window {:x} is already minimized", address);
            return;
        }
        // The Dock tile the shell computed for this window (layout coordinates). Tests read it from Hyprland's log
        // (tests/compositor/minimize.sh, soak.sh: `hyprctl rollinglog -f`) to click that tile: keep the wording.
        if (target) {
            if (const auto held = st().targetLog.admit(gf::events::Clock::now()))
                gf::log(Log::INFO, "minimize {:x}: toward the Dock rectangle {:.0f},{:.0f} {:.0f}x{:.0f}{}", address, target->x, target->y, target->w, target->h,
                        *held > 0 ? std::format(" ({} similar line(s) held back)", *held) : std::string{});
        }

        // A restore still animating: the new animation starts where that one is (Scale: its box; Genie: its shape).
        std::optional<mz::Box> from;
        std::optional<double>  genieProgress;
        if (auto running = takeAnimation(w)) {
            if (running->kind == mz::Kind::Restore && running->effect == mz::Effect::Genie)
                genieProgress = running->progress;
            else if (running->kind == mz::Kind::Restore)
                from = running->frame.box;
            complete(*running, true);
        }

        SP<Render::IFramebuffer> snapshot;
        mz::SSnapshotGeometry    geometry;
        mz::Box                  full;
        const auto               mon = w->m_monitor.lock();
        if (target && mon) {
            snapshot = takeSnapshot(w);
            geometry = snapshotGeometry(w, mon);
            full     = fullBox(w);
        }
        auto place = placeOf(w); // before the move: the display and frame the restore gives back (D-1)

        if (!hideOnMinimized(w)) {
            releaseSnapshot(snapshot);
            return;
        }
        if (place)
            rememberPlace(w, std::move(*place));
        if (!snapshot || !target) { // no snapshot without a target: no animation
            releaseSnapshot(snapshot);
            postState(mz::Kind::Minimize, address);
            return;
        }
        auto   a       = makeAnimation(mz::Kind::Minimize, w, address, std::move(snapshot), geometry, full, *target, mon);
        double elapsed = 0.0;
        if (a.effect == mz::Effect::Genie && genieProgress)
            elapsed = mz::genieElapsedFor(mz::Kind::Minimize, *genieProgress);
        else if (a.effect == mz::Effect::Scale && from)
            a.from = *from;
        startAnimation(std::move(a), elapsed);
    }

    std::vector<uint64_t> minimizedFrom(std::string_view monitor) {
        std::vector<uint64_t> out;
        const auto&           all = st().places;
        for (auto it = all.rbegin(); it != all.rend(); ++it) {
            const auto w = it->window.lock();
            if (w && w->m_isMapped && onMinimizedWorkspace(w) && it->place.monitor == monitor)
                out.push_back(reinterpret_cast<uintptr_t>(w.get()));
        }
        return out;
    }

    void restore(uint64_t address, std::optional<mz::Box> target) {
        const auto w = windowByAddress(address);
        if (!w || !w->m_isMapped) {
            gf::logRequest(Log::WARN, "restore: no mapped window {:x}", address);
            return;
        }
        // A Genie minimize still animating: the restore plays it backwards from the shape on screen.
        std::optional<double> genieProgress;
        if (auto running = takeAnimation(w)) {
            if (running->kind == mz::Kind::Minimize && running->effect == mz::Effect::Genie)
                genieProgress = running->progress;
            complete(*running, true);
        }
        if (!onMinimizedWorkspace(w)) {
            gf::logRequest(Log::DEBUG, "restore: window {:x} is not minimized", address);
            return;
        }

        // D-1 (macOS): back on the display it was minimized from, on the Desktop that display shows now, at its frame; never
        // on the display of the Dock that was clicked (that click focused it).
        const auto saved = takePlace(w);
        const auto place = restoreTarget(saved, gf::chrome::bandOf(w));
        const auto ws    = place.monitor ? place.monitor->m_activeWorkspace : nullptr;
        if (!ws) {
            gf::log(Log::WARN, "restore: no active workspace");
            return;
        }
        if (const auto result = Config::Actions::moveToWorkspace(ws, true, w); !result || onMinimizedWorkspace(w)) {
            gf::log(Log::WARN, "restore: move of {:x} to workspace {} failed", address, ws->m_name);
            return;
        }
        if (place.frame && keepsFrame(w) && g_layoutManager)
            g_layoutManager->setTargetGeom(toCBox(*place.frame), w->layoutTarget());
        gf::logRequest(Log::INFO, "restore {:x}: on {} (Desktop {}){}", address, place.monitor->m_name, ws->m_name,
                       !saved ? ", no recorded place: the focused display" : place.moved ? ", its display is gone: the focused display" : "");

        // Hyprland fades a window in when it arrives on a visible workspace and may move it there with an
        // animation: settle both so the snapshot shows the window at its place, fully opaque.
        w->positionAnimation()->warp();
        w->sizeAnimation()->warp();
        auto& fadeIn = w->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE);
        if (fadeIn && fadeIn->isBeingAnimated())
            fadeIn->warp();

        if (const auto focus = Desktop::focusState(); focus)
            focus->fullWindowFocus(w, Desktop::FOCUS_REASON_OTHER);
        if (const auto result = Config::Actions::alterZOrder("top", w); !result)
            gf::log(Log::WARN, "restore: raise failed: {}", result.error().message);

        const auto mon      = w->m_monitor.lock();
        auto       snapshot = target && mon ? takeSnapshot(w) : nullptr;
        if (!snapshot || !target) {
            releaseSnapshot(snapshot);
            postState(mz::Kind::Restore, address);
            return;
        }

        // Transparent until the snapshot has grown back to its place (showWindow in complete()).
        if (fadeIn)
            fadeIn->setValueAndWarp(0.F);
        if (g_pHyprRenderer)
            g_pHyprRenderer->damageWindow(w);

        auto   a       = makeAnimation(mz::Kind::Restore, w, address, std::move(snapshot), snapshotGeometry(w, mon), fullBox(w), *target, mon);
        double elapsed = 0.0;
        if (a.effect == mz::Effect::Genie && genieProgress)
            elapsed = mz::genieElapsedFor(mz::Kind::Restore, *genieProgress);
        startAnimation(std::move(a), elapsed);
    }

} // namespace gf::minimizer
