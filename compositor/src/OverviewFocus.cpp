#include "OverviewFocus.hpp"

#include "DeferredFocus.hpp"
#include "Ipc.hpp"
#include "Plugin.hpp"
#include "Surfaces.hpp"
#include "core/EventThrottle.hpp"

#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include "HyprCompat.hpp"
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <format>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace of = gf::overviewfocus;
namespace df = gf::deferredfocus;

namespace {
    using Clock = std::chrono::steady_clock;

    // A commit listener on a mapped layer surface while a request waits: an Exclusive layer dropping its keyboard
    // interactivity arrives in a commit, and when the chrome that held the keyboard released it first Hyprland changes
    // nothing when the last Exclusive one commits None (no keyboard focus change, no unmap: the shell's chromes stay mapped).
    struct SLayerWatch {
        PHLLSREF            layer;
        CHyprSignalListener commit;
    };

    // When a window last took focus (Hyprland's focus events since the load): the front-most window of a Desktop is the
    // one activated last (macOS), and Hyprland does not raise a floating window on every focus.
    struct SFocusMark {
        PHLWINDOWREF window;
        uint64_t     seq = 0;
    };

    struct SState {
        bool                             ready = false;
        std::optional<of::Request>       pending;  // the request waiting for Hyprland to accept window focus
        Clock::time_point                deadline; // its bound
        gf::deferredFocus::CLater        attempt;  // the next attempt from the event loop (code of this library)
        SP<CEventLoopTimer>              bound;    // fires at the deadline; shared: CEventLoopManager holds a reference too
        std::vector<CHyprSignalListener> listeners;
        std::vector<SLayerWatch>         watches;
        std::vector<SFocusMark>          marks;
        uint64_t                         focusSeq = 0;
        // The namespace of the layer surface that held the keyboard when the request came (the closing chrome, e.g.
        // grassfield-overview; "" when none): its layers never get the keyboard from the dialog hand-over (GF-038).
        std::string closing;
        // The request whose keyboard hand-over was logged: one line per request, never one per attempt (an attempt runs
        // before every key while it waits; review of part B, 2026-10-24).
        uint32_t handOverLogged = 0;
        // handOverKeyboard's lists, kept between attempts: an attempt runs once per loop turn while a request waits (the
        // shell's close animation), and allocated two vectors each time.
        std::vector<PHLLS>              handLayers;
        std::vector<of::ExclusiveLayer> handFacts;
    };

    // Constructed on first use inside a guarded call (R13). Emptied by stop() before dlclose.
    SState& S() {
        static SState s;
        return s;
    }

    uint64_t addressOf(const PHLWINDOW& w) {
        return reinterpret_cast<uintptr_t>(w.get());
    }

    // The address is compared, never dereferenced.
    PHLWINDOW windowByAddress(uint64_t address) {
        if (!Desktop::windowState() || address == 0)
            return nullptr;
        for (const auto& w : Desktop::windowState()->windows()) {
            if (w && addressOf(w) == address)
                return w;
        }
        return nullptr;
    }

    PHLWORKSPACE regularWorkspace(of::WorkspaceId id) {
        if (id <= 0 || !State::workspaceState())
            return nullptr;
        auto ws = gf::compat::workspaceById(id);
        return ws && !gf::compat::isSpecial(ws) ? ws : nullptr;
    }

    // The Desktop is the one its monitor shows.
    bool shown(const PHLWORKSPACE& ws) {
        const auto mon = ws ? ws->m_monitor.lock() : nullptr;
        return mon && mon->m_activeWorkspace == ws;
    }

    // The Desktop shown on Hyprland's focused monitor.
    PHLWORKSPACE focusedMonitorWorkspace() {
        const auto fs  = Desktop::focusState();
        const auto mon = fs ? fs->monitor() : nullptr;
        const auto ws  = mon ? mon->m_activeWorkspace : nullptr;
        return ws && !gf::compat::isSpecial(ws) ? ws : nullptr;
    }

    std::optional<of::WorkspaceId> idOf(const PHLWORKSPACE& ws) {
        return ws ? std::optional<of::WorkspaceId>{gf::compat::workspaceId(ws)} : std::nullopt;
    }

    // ---- events ----

    void post(of::Outcome outcome, const of::Request& r, const PHLWINDOW& w = nullptr, std::optional<of::WorkspaceId> workspace = std::nullopt,
              std::string_view reason = "") {
        const of::Event event{.outcome   = outcome,
                              .target    = r.target,
                              .id        = r.id,
                              .window    = w ? std::optional<of::WindowId>{addressOf(w)} : std::nullopt,
                              .workspace = workspace,
                              .reason    = reason};
        gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::OverviewFocus, .id = 0}, of::eventJson(event));
    }

    // ---- the waiting request ----

    void scheduleAttempt();
    void attempt(std::string_view when);

    // Every layer surface while a request waits (also one that is not mapped yet when Hyprland reports it opened): its
    // commits are cheap to watch, and one that turns Exclusive or drops it arrives in a commit.
    void watch(const PHLLS& ls) {
        auto& s = S();
        if (!ls)
            return;
        if (std::ranges::any_of(s.watches, [&ls](const SLayerWatch& w) { return w.layer.lock() == ls; }))
            return;
        const auto resource = ls->m_layerSurface.lock();
        if (!resource)
            return;
        s.watches.push_back(SLayerWatch{.layer  = ls,
                                        .commit = resource->m_events.commit.listen([] { gf::guarded("overview focus layer commit", [] { scheduleAttempt(); }); })});
    }

    void watchLayers() {
        if (!Desktop::layerState())
            return;
        for (const auto& ls : Desktop::layerState()->layers())
            watch(ls);
    }

    void armBound() {
        auto& s = S();
        if (!g_pEventLoopManager)
            return;
        if (!s.bound) {
            s.bound = makeShared<CEventLoopTimer>(
                std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { gf::guarded("overview focus bound", [] { attempt("at the bound"); }); }, nullptr);
            g_pEventLoopManager->addTimer(s.bound);
        }
        // A little past the deadline, so that the attempt it schedules sees the bound passed.
        s.bound->updateTimeout(std::chrono::duration_cast<std::chrono::milliseconds>(of::kBound) + std::chrono::milliseconds(5));
    }

    // The request is over (applied, refused, timed out, superseded): nothing more is watched.
    void endPending() {
        auto& s = S();
        s.pending.reset();
        s.closing.clear();
        s.attempt.cancel(); // its callback is code of this library
        s.watches.clear();  // the commit listeners (their callbacks are code of this library)
        if (s.bound)
            s.bound->updateTimeout(std::nullopt);
    }

    // "window 55aa01", "Desktop 3", "remembered 55aa01 (Desktop 2)", "none" (log lines).
    std::string describe(const of::Request& r) {
        switch (r.target) {
            case of::Target::Window:
            case of::Target::Press: return std::format("{} {:x}", of::targetName(r.target), r.window);
            case of::Target::Workspace: return std::format("Desktop {}", r.workspace);
            case of::Target::Remembered: return r.workspace > 0 ? std::format("remembered {:x} (Desktop {})", r.window, r.workspace) : std::format("remembered {:x}", r.window);
            case of::Target::None: return "none";
        }
        return "none";
    }

    void finish(of::Outcome outcome, const of::Request& r, const PHLWINDOW& w, std::optional<of::WorkspaceId> workspace, std::string_view reason, std::string_view when) {
        gf::logRequest(Log::INFO, "overview focus: request {} ({}) {} {}: {}{}{}", r.id, describe(r), of::outcomeName(outcome), when,
                       w ? std::format("window {:x} holds the keyboard", addressOf(w)) : std::string{"no window holds the keyboard"},
                       workspace ? std::format(" (Desktop {})", *workspace) : std::string{}, reason.empty() ? std::string{} : std::format(", reason {}", reason));
        post(outcome, r, w, workspace, reason);
    }

    // ---- focusing ----

    // Hyprland's own window focus: CFocusState::fullWindowFocus, what hl.dsp.focus({ window = … }) runs once the window's
    // Desktop is shown (Config::Actions::focus, read from the 0.56.2 binary: fullWindowFocus with
    // FOCUS_REASON_DISPATCH_FOCUSWINDOW, then a cursor warp, which is not done here: the pointer stays where the user left
    // it), through the shared gf::deferredFocus::focusWindow. It also gives the keyboard back to the window Hyprland still
    // counts focused: its own focus of it under the Exclusive layer (the successor of a window closed under the chrome: "On
    // closed window, new focused candidate is …", then "Refusing a keyboard focus to a window because of an exclusive ls")
    // set its focus state and was refused the keyboard, so fullWindowFocus returns early (measured:
    // tests/compositor/overview_focus.sh case 8); the shared helper resets the state and focuses again. True when the window
    // holds the keyboard afterwards: Hyprland may refuse it (a no_focus rule, a modal child).
    bool focusWindow(const PHLWINDOW& w, Desktop::eFocusReason reason) {
        const auto fs = Desktop::focusState();
        if (!fs || !w || !gf::compat::mapped(w))
            return false;
        bool       stateReset = false;
        const bool held       = gf::deferredFocus::focusWindow(w, reason, &stateReset);
        if (stateReset)
            gf::logRequest(Log::DEBUG, "overview focus: Hyprland counted window {:x} focused without the keyboard: focus state reset, focused again", addressOf(w));
        if (!held) {
            const auto now   = fs->window();
            const auto owner = gf::surfaces::ownerOf(gf::surfaces::keyboardFocus());
            gf::logRequest(Log::DEBUG, "overview focus: Hyprland did not give window {:x} the keyboard (its focused window {:x}, keyboard on window {:x} / layer {})", addressOf(w),
                           now ? addressOf(now) : 0, owner.window ? addressOf(owner.window) : 0, owner.layer ? owner.layer->m_namespace : std::string{"-"});
        }
        return held;
    }

    // The windows to try for the front window of a Desktop, in order (core frontOrder over Hyprland's stacking order).
    std::vector<PHLWINDOW> frontCandidates(const PHLWORKSPACE& ws) {
        std::vector<PHLWINDOW> out;
        if (!ws || !Desktop::windowState())
            return out;
        std::vector<of::Candidate> candidates;
        std::vector<PHLWINDOW>     windows;
        for (const auto& w : Desktop::windowState()->windows()) { // bottom to top
            if (!w)
                continue;
            const auto mark = std::ranges::find_if(S().marks, [&w](const SFocusMark& m) { return m.window.lock() == w; });
            candidates.push_back(of::Candidate{.id          = addressOf(w),
                                               .onWorkspace = w->m_workspace == ws,
                                               .mapped      = gf::compat::mapped(w),
                                               .hidden      = w->isHidden(),
                                               .takesInput  = w->acceptsInput(),
                                               .focusable   = !gf::compat::shouldntFocus(w),
                                               .focusSeq    = mark == S().marks.end() ? 0 : mark->seq});
            windows.push_back(w);
        }
        for (const auto id : of::frontOrder(candidates)) {
            const auto it = std::ranges::find_if(windows, [id](const PHLWINDOW& w) { return addressOf(w) == id; });
            if (it != windows.end())
                out.push_back(*it);
        }
        return out;
    }

    // A layer surface that takes the keyboard (on_demand: the desktop surface after a press, a surface the user opened)
    // holds it. A released chrome (keyboard None) that Hyprland left the keyboard on does not count: its keys go nowhere.
    bool layerKeepsKeyboard() {
        const auto owner = gf::surfaces::ownerOf(gf::surfaces::keyboardFocus());
        return owner.layer && gf::compat::layerMapped(owner.layer) && gf::surfaces::interactivity(owner.layer) != 0;
    }

    // No window gets the keyboard on that Desktop (the desktop; macOS: no app window is key): Hyprland's active window is
    // cleared and the keyboard goes to nothing (Hyprland's own path, as when its focused window's input is blocked), unless
    // a layer surface that takes the keyboard holds it; the Desktop's monitor becomes the focused one.
    void focusNoWindow(const PHLWORKSPACE& ws) {
        const auto fs = Desktop::focusState();
        if (!fs)
            return;
        if (!layerKeepsKeyboard()) {
            if (fs->window() || gf::surfaces::keyboardFocus())
                fs->fullWindowFocus(nullptr, Desktop::FOCUS_REASON_OTHER);
            if (gf::surfaces::keyboardFocus() && !layerKeepsKeyboard())
                fs->rawSurfaceFocus(nullptr); // the keyboard leaves a released chrome or a window for nothing
        }
        if (const auto mon = ws ? ws->m_monitor.lock() : nullptr; mon && fs->monitor() != mon)
            fs->rawMonitorFocus(mon);
    }

    // The front window of `ws` takes the keyboard, else no window does. Returns the window focused.
    PHLWINDOW focusFront(const PHLWORKSPACE& ws) {
        for (const auto& w : frontCandidates(ws)) {
            if (focusWindow(w, Desktop::FOCUS_REASON_OTHER))
                return w;
        }
        focusNoWindow(ws);
        return nullptr;
    }

    void applyFallback(const of::Request& r, std::string_view why, std::string_view when) {
        const auto remembered = r.target == of::Target::Remembered ? regularWorkspace(r.workspace) : nullptr;
        const auto ws         = of::fallbackSpace(r.target, shown(remembered)) == of::FallbackSpace::Remembered ? remembered : focusedMonitorWorkspace();
        const auto w          = focusFront(ws);
        finish(of::Outcome::Fallback, r, w, w && w->m_workspace ? idOf(w->m_workspace) : idOf(ws), why, when);
    }

    // Hyprland accepts window focus now: the target is checked again and focused (ST23-like: nothing was asked of Hyprland
    // while it refused).
    void apply(const of::Request& r, std::string_view when) {
        const bool namesWindow = r.target == of::Target::Window || r.target == of::Target::Remembered || r.target == of::Target::Press;
        const auto target      = namesWindow ? windowByAddress(r.window) : nullptr;
        const auto targetSpace = target ? target->m_workspace : nullptr;
        const of::WindowFacts window{.exists    = target && gf::compat::mapped(target),
                                     .hidden    = target && target->isHidden(),
                                     .minimized = target && (!targetSpace || gf::compat::isSpecial(targetSpace)),
                                     .shown     = shown(targetSpace)};
        const auto space = r.target == of::Target::Workspace ? regularWorkspace(r.workspace) : nullptr;
        const auto plan  = of::plan(r.target, of::judgeWindow(window), of::WorkspaceFacts{.exists = space != nullptr, .shown = shown(space)});
        switch (plan.plan) {
            case of::Plan::FocusWindow:
                if (focusWindow(target, Desktop::FOCUS_REASON_DISPATCH_FOCUSWINDOW)) {
                    finish(of::Outcome::Focused, r, target, idOf(targetSpace), "", when);
                    return;
                }
                applyFallback(r, "refused-by-hyprland", when); // a no_focus rule, a modal child
                return;
            case of::Plan::SwitchThenFront: {
                // Hyprland's own Desktop switch (what hl.dsp.focus({ workspace = … }) runs; only for a Desktop that is not
                // shown, so workspace_back_and_forth never applies), then the front window as for a shown Desktop.
                const auto result = Config::Actions::changeWorkspace(space);
                if (!result)
                    gf::logRequest(Log::WARN, "overview focus: switching to Desktop {} failed: {}", gf::compat::workspaceId(space), result.error().message);
                [[fallthrough]];
            }
            case of::Plan::Front: {
                const auto w = focusFront(space);
                finish(of::Outcome::Focused, r, w, idOf(space), w ? "" : "no-window", when);
                return;
            }
            case of::Plan::Fallback: applyFallback(r, plan.why, when); return;
        }
    }

    // GF-038: a dialog (an Exclusive layer surface of another namespace than the closing one) that opened during the close
    // gets the keyboard when the keyboard is on nothing, as a pointer motion would give it (core keyboardHandOver). Hyprland's
    // Exclusive-layer list is only read; the focus goes through Hyprland's own surface focus.
    void handOverKeyboard(std::string_view when) {
        const auto fs = Desktop::focusState();
        if (!fs || !g_pInputManager || gf::deferredFocus::sessionLocked())
            return;
        const auto owner = gf::surfaces::ownerOf(gf::surfaces::keyboardFocus());
        if ((owner.window && gf::compat::mapped(owner.window)) || layerKeepsKeyboard())
            return; // a window, or a layer surface that takes the keyboard, holds it
        auto& layers = S().handLayers;
        auto& facts  = S().handFacts;
        layers.clear();
        facts.clear();
        // The strong references to the layers go when this returns (the capacity stays): nothing keeps a surface alive.
        struct SDropRefs {
            explicit SDropRefs(std::vector<PHLLS>& r, std::vector<of::ExclusiveLayer>& f) : refs(r), facts(f) {}
            std::vector<PHLLS>&              refs;
            std::vector<of::ExclusiveLayer>& facts; // their namespaces are views into those layers
            ~SDropRefs() {
                refs.clear();
                facts.clear();
            }
            SDropRefs(const SDropRefs&)            = delete;
            SDropRefs& operator=(const SDropRefs&) = delete;
            SDropRefs(SDropRefs&&)                 = delete;
            SDropRefs& operator=(SDropRefs&&)      = delete;
        } dropRefs{layers, facts};
        for (const auto& ref : gf::compat::exclusiveLayers()) {
            const auto ls = ref.lock();
            if (!ls)
                continue;
            layers.push_back(ls);
            facts.push_back(of::ExclusiveLayer{.ns = ls->m_namespace, .mapped = gf::compat::layerMapped(ls), .exclusive = gf::surfaces::interactivity(ls) == 1, .underCursor = false});
        }
        auto pick = of::keyboardHandOver(facts, S().closing, false);
        if (!pick)
            return; // only the closing surface's layers (the common case): no hit test
        // A dialog is there: the one under the cursor, as a pointer motion would choose.
        const auto under = gf::deferredFocus::exclusiveLayerAt(g_pInputManager->getMouseCoordsInternal());
        for (size_t i = 0; i < facts.size(); ++i)
            facts[i].underCursor = layers[i] == under;
        pick = of::keyboardHandOver(facts, S().closing, false);
        if (!pick || *pick >= layers.size())
            return;
        const auto& ls      = layers[*pick];
        const auto  surface = ls->resource();
        if (!surface)
            return;
        fs->rawSurfaceFocus(surface);
        const bool     held = gf::surfaces::keyboardFocus() == surface;
        const auto&    req  = S().pending;
        const uint32_t id   = req ? req->id : 0;
        if (id != 0 && S().handOverLogged == id)
            return;
        S().handOverLogged = id;
        gf::logRequest(held ? Log::INFO : Log::WARN, "overview focus: request {}: the keyboard was on nothing: {} the layer {} that opened during the close ({})", id,
                       held ? "given to" : "Hyprland did not give it to", ls->m_namespace, when);
    }

    // One check of the waiting request: from the event loop after a layer surface change, a keyboard focus change, the lock
    // or the bound, or before a key.
    void attempt(std::string_view when) {
        auto& s = S();
        if (!s.pending)
            return;
        std::erase_if(s.watches, [](const SLayerWatch& w) { return !w.layer.lock(); });
        const of::Gate gate{.locked = gf::deferredFocus::sessionLocked(), .exclusive = gf::deferredFocus::exclusiveLayerMapped(), .expired = Clock::now() >= s.deadline};
        const auto     r = *s.pending;
        switch (of::step(gate)) {
            case of::Step::Wait: handOverKeyboard(when); return;
            case of::Step::Refuse:
                endPending();
                finish(of::Outcome::Refused, r, nullptr, std::nullopt, "locked", when);
                return;
            case of::Step::Timeout:
                handOverKeyboard(when); // before the request ends: a dialog that stays past the bound keeps the keys
                endPending();
                finish(of::Outcome::Timeout, r, nullptr, std::nullopt, "exclusive-layer", when);
                return;
            case of::Step::Apply:
                endPending(); // before focusing: Hyprland's focus events then see no waiting request
                apply(r, when);
                return;
        }
    }

    void scheduleAttempt() {
        auto& s = S();
        if (!s.pending)
            return;
        s.attempt.schedule([] { gf::guarded("overview focus attempt", [] { attempt("after a layer, keyboard or lock change"); }); });
    }

    // A press (pointer button, touch down, tablet tip or button) after the request, before Hyprland handles it.
    void onPress(bool pointer) {
        auto& s = S();
        if (!s.pending)
            return;
        const auto press = df::recordPress(gf::deferredFocus::pressContext(pointer));
        switch (of::pressEffect(press)) {
            case of::PressEffect::None: return;
            case of::PressEffect::Supersede: {
                const auto r = *s.pending;
                endPending();
                finish(of::Outcome::Superseded, r, nullptr, std::nullopt, "press", "on a press (Hyprland's click focus decides)");
                return;
            }
            case of::PressEffect::Retarget:
                gf::logRequest(Log::INFO, "overview focus: request {}: a press beside the Exclusive layers on window {:x}: it takes the focus instead of {}", s.pending->id,
                               press.target, describe(*s.pending));
                s.pending->target    = of::Target::Press;
                s.pending->window    = press.target;
                s.pending->workspace = 0;
                return;
        }
    }

    // Hyprland focused a window while a request waits (possible only while it accepts window focus, before the attempt
    // ran): a user choice of another window ends the request.
    void onActive(const PHLWINDOW& w, Desktop::eFocusReason reason) {
        auto& s = S();
        if (w) {
            std::erase_if(s.marks, [&w](const SFocusMark& m) { return !m.window.lock() || m.window.lock() == w; });
            s.marks.push_back(SFocusMark{.window = w, .seq = ++s.focusSeq});
        }
        if (!s.pending || !w)
            return;
        const bool namesWindow = s.pending->target == of::Target::Window || s.pending->target == of::Target::Remembered || s.pending->target == of::Target::Press;
        // A press is handled when it arrives (onPress): a CLICK focus is never counted again here. WORKSPACE_CHANGE counts
        // as Hyprland's restore of that Desktop's last window.
        const auto origin = df::focusOrigin(gf::deferredFocus::causeOf(reason), true, false);
        if (!of::supersedes(origin, namesWindow && addressOf(w) == s.pending->window))
            return;
        const auto r = *s.pending;
        endPending();
        finish(of::Outcome::Superseded, r, w, idOf(w->m_workspace), "user-focus", "when the user chose another window");
    }

} // namespace

namespace gf::overviewFocus {

    bool start() {
        auto& bus = Event::bus();
        if (!bus || !Desktop::windowState() || !Desktop::layerState())
            return false;
        // A load starts with nothing waiting, also when the library stayed mapped since a previous load (FR23).
        auto& s = S();
        s.pending.reset();
        s.attempt.clear();
        s.watches.clear();
        s.bound.reset();
        s.marks.clear();
        s.focusSeq = 0;
        if (const auto fs = Desktop::focusState(); fs && fs->window())
            s.marks.push_back(SFocusMark{.window = fs->window(), .seq = ++s.focusSeq});
        auto& ev = bus->m_events;
        auto& l  = s.listeners;
        // Before a key is delivered: the last Exclusive layer may have gone in this same dispatch, before the attempt ran.
        l.push_back(ev.input.keyboard.key.listen([](IKeyboard::SKeyEvent e, Event::SCallbackInfo& info) {
            gf::keyPath("overview focus key", [](const IKeyboard::SKeyEvent& /*e*/, Event::SCallbackInfo& /*info*/) { attempt("before a key"); }, e, info);
        }));
        l.push_back(ev.input.touch.down.listen([](const ITouch::SDownEvent& /*e*/, Event::SCallbackInfo& /*info*/) { gf::guarded("overview focus touch", [] { onPress(false); }); }));
        l.push_back(ev.input.tablet.tip.listen([](const CTablet::STipEvent& e, Event::SCallbackInfo& /*info*/) {
            gf::guarded("overview focus tablet tip", [&] {
                if (e.in)
                    onPress(false);
            });
        }));
        l.push_back(ev.input.tablet.button.listen([](const CTablet::SButtonEvent& e, Event::SCallbackInfo& /*info*/) {
            gf::guarded("overview focus tablet button", [&] {
                if (e.down)
                    onPress(false);
            });
        }));
        // A layer surface mapping (a dialog during the close: still waiting, its commits are watched) or unmapping, and the
        // keyboard focus changing: tried from the event loop, after Hyprland's own handling.
        l.push_back(ev.layer.opened.listen([](const PHLLS& ls) {
            gf::guarded("overview focus layer.opened", [&] {
                if (!S().pending)
                    return;
                watch(ls);
                scheduleAttempt();
            });
        }));
        l.push_back(ev.layer.closed.listen([](const PHLLS& /*ls*/) { gf::guarded("overview focus layer.closed", [] { scheduleAttempt(); }); }));
        l.push_back(ev.input.keyboard.focus.listen([](const SP<CWLSurfaceResource>& /*surface*/) { gf::guarded("overview focus keyboard.focus", [] { scheduleAttempt(); }); }));
        l.push_back(ev.window.active.listen([](const PHLWINDOW& w, Desktop::eFocusReason reason) { gf::guarded("overview focus window.active", [&] { onActive(w, reason); }); }));
        if (g_pSessionLockManager)
            l.push_back(g_pSessionLockManager->m_events.lock.listen([] { gf::guarded("overview focus lock", [] { scheduleAttempt(); }); }));
        s.ready = true;
        return true;
    }

    void stop() {
        auto& s = S();
        s.ready = false;
        s.listeners.clear();
        if (s.pending) {
            const auto r = *s.pending;
            endPending();
            finish(of::Outcome::Unavailable, r, nullptr, std::nullopt, "unloading", "at unload");
        }
        s.attempt.cancel();
        s.watches.clear();
        s.marks.clear();
        if (s.bound) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.bound);
            s.bound.reset();
        }
    }

    bool ready() {
        return S().ready;
    }

    void request(const of::Request& r) {
        auto& s = S();
        if (!s.ready) {
            post(of::Outcome::Unavailable, r, nullptr, std::nullopt, "unloading");
            return;
        }
        const auto replaced = s.pending ? std::format(", replaces request {}", s.pending->id) : std::string{};
        if (!s.pending)
            watchLayers();
        // The surface that is closing: the layer surface holding the keyboard now (a replacing request keeps the one known).
        if (const auto holder = gf::surfaces::ownerOf(gf::deferredFocus::keyboardHolder()); holder.layer)
            s.closing = holder.layer->m_namespace;
        else if (!s.pending)
            s.closing.clear();
        s.pending  = r;
        s.deadline = Clock::now() + of::kBound;
        armBound();
        gf::logRequest(Log::INFO, "overview focus: request {} ({}){}: made once Hyprland accepts window focus (at most {} ms)", r.id, describe(r), replaced, of::kBound.count());
        post(of::Outcome::Pending, r);
        scheduleAttempt();
    }

    void refuse() {
        post(of::Outcome::Invalid, of::Request{}, nullptr, std::nullopt, "invalid");
    }

    void beforePointerButton(bool pressed) {
        if (pressed)
            onPress(true);
    }

} // namespace gf::overviewFocus
