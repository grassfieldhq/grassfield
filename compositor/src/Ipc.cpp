#include "Ipc.hpp"

#include "AppmenuServer.hpp"
#include "ClientChrome.hpp"
#include "CursorRefresh.hpp"
#include "DesktopFocus.hpp"
#include "FrameProbe.hpp"
#include "GenieDraw.hpp"
#include "LayerPointer.hpp"
#include "Minimize.hpp"
#include "Overview.hpp"
#include "OverviewFocus.hpp"
#include "Plugin.hpp"
#include "Stages.hpp"
#include "Tiling.hpp"
#include "Titlebar.hpp"
#include "ToplevelDrag.hpp"
#include "WindowRim.hpp"
#include "core/Minimize.hpp"
#include "core/Overview.hpp"
#include "core/OverviewFocus.hpp"
#include "core/Protocol.hpp"
#include "core/RunMode.hpp"
#include "core/FrameLog.hpp"
#include "core/Stages.hpp"

#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>

#include <lua.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace gf::ipc {

    namespace {
        struct SEvents {
            events::CEventThrottle           throttle;
            SP<CEventLoopTimer>              timer;    // shared: CEventLoopManager holds a strong reference too (stopEvents removes it before dlclose)
            std::optional<events::TimePoint> armedFor; // when the timer fires, if armed
            bool                             running       = false;
            uint64_t                         seenCoalesced = 0;
        };

        // Constructed on first use inside a guarded call (R13); stopEvents() removes the timer before dlclose.
        SEvents& evs() {
            static SEvents s;
            return s;
        }

        void postNow(const std::string& json) {
            if (!g_pEventManager)
                return; // shutting down: nobody listens
            g_pEventManager->postEvent(SHyprIPCEvent{.event = std::string{gfc::kEventName}, .data = json});
        }

        void postAll(const std::vector<std::string>& payloads) {
            for (const auto& p : payloads)
                postNow(p);
        }

        // One line per power of ten (1, 10, 100, ...): a flood shows in the log without flooding it.
        void noteCoalesced() {
            auto&          s = evs();
            const uint64_t c = s.throttle.coalesced();
            if (c == s.seenCoalesced)
                return;
            s.seenCoalesced = c;
            if (events::isLogMilestone(c))
                log(Log::INFO, "events: {} superseded by a newer event of the same window before posting (coalesced, at most one per window per 100 ms)", c);
        }

        void schedule(events::TimePoint now);

        void onTimer() {
            guarded("event throttle timer", [] {
                auto& s = evs();
                s.armedFor.reset(); // CEventLoopTimer::call() disarms the timer before calling back
                if (!s.running)
                    return;
                const auto now = events::Clock::now();
                postAll(s.throttle.due(now));
                schedule(now);
            });
        }

        // Arms the timer for the next waiting event (only when that is earlier than what it is armed for).
        void schedule(events::TimePoint now) {
            auto&      s    = evs();
            const auto next = s.throttle.nextDue(now);
            if (!next || (s.armedFor && *s.armedFor <= *next))
                return;
            if (!g_pEventLoopManager) {
                postAll(s.throttle.drain()); // no event loop (should not happen): no coalescing, nothing lost
                return;
            }
            if (!s.timer) {
                s.timer = makeShared<CEventLoopTimer>(std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { onTimer(); }, nullptr);
                g_pEventLoopManager->addTimer(s.timer);
            }
            s.timer->updateTimeout(std::max<events::Duration>(*next - now, std::chrono::milliseconds(1)));
            s.armedFor = *next;
        }
    } // namespace

    void postEvent(events::Key key, std::string json) {
        auto& s = evs();
        if (!s.running) {
            postNow(json); // before startEvents() or while unloading: no timer may be created
            return;
        }
        const auto now = events::Clock::now();
        postAll(s.throttle.submit(key, std::move(json), now));
        noteCoalesced();
        schedule(now);
    }

    void startEvents() {
        evs().running = true;
    }

    void stopEvents() {
        auto& s   = evs();
        s.running = false;
        if (s.timer) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.timer);
            s.timer.reset();
        }
        s.armedFor.reset();
        postAll(s.throttle.drain()); // the final state of every key still reaches the shell
    }

    bool minimizeAvailable() {
        const auto& s = state();
        return s.luaMinimizeRegistered && s.luaRestoreRegistered && minimizer::ready();
    }

    namespace {
        // A dev session by the run-mode rule (ADR-0019, core/RunMode.hpp): scripts/dev/nested-up.sh exports
        // GRASSFIELD_DEV=1 to the nested Hyprland, whose config never sets GRASSFIELD_SESSION; the installed session
        // sets GRASSFIELD_SESSION=1 (session.lua, hl.env: Hyprland's own environment), so a GRASSFIELD_DEV=1 that
        // leaked into it opens no dev hook. Read at each call (only the rare testFault request asks): hl.env can change
        // Hyprland's environment on a config reload.
        bool devSession() {
            // NOLINTNEXTLINE(concurrency-mt-unsafe): compositor thread only, as hl.env's setenv
            return runmode::dev(std::getenv("GRASSFIELD_DEV"), std::getenv("GRASSFIELD_SESSION"));
        }
    } // namespace

    bool minimizeEffectAvailable() {
        return minimizeAvailable() && state().luaConfigRegistered;
    }

    bool appmenuAvailable() {
        return state().luaAppmenuRegistered && appmenuServer::ready();
    }

    bool overviewAvailable() {
        return state().luaOverviewRegistered && overviewer::ready();
    }

    bool stagesAvailable() {
        return state().luaStagesRegistered && state().luaConfigRegistered && state().hyprctlStagesCommand != nullptr && stager::ready();
    }

    bool cursorRefreshAvailable() {
        return state().luaCursorRefreshRegistered && cursorRefresh::ready();
    }

    bool overviewFocusAvailable() {
        return state().luaOverviewFocusRegistered && overviewFocus::ready();
    }

    bool tilingAvailable() {
        return state().luaTileRegistered && state().luaConfigRegistered;
    }

    bool tilingArrangeAvailable() {
        return tilingAvailable() && state().luaArrangeRegistered && state().hyprctlTilingCommand != nullptr && tiler::ready();
    }

    bool tileHoverAvailable() {
        return tilingAvailable() && state().luaTilePopoverRegistered && state().luaMoveToRegistered;
    }

    bool tilingGroupsAvailable() {
        return tilingArrangeAvailable() && state().luaGroupFrontRegistered;
    }

    bool tilingSplitAvailable() {
        return tilingArrangeAvailable() && state().luaSplitRegistered && state().luaUnsplitRegistered;
    }

    bool sharedEdgeAvailable() {
        return tilingArrangeAvailable(); // the pointer listeners are the plugin's own (main.cpp), the drag the tile records'
    }

    namespace {
        std::string currentCapabilities() {
            const auto features = gfc::features(minimizeAvailable(), state().luaConfigRegistered, appmenuAvailable(), overviewAvailable(), desktopFocus::ready(),
                                                stagesAvailable(), stager::enabled(), cursorRefreshAvailable(), overviewFocusAvailable(), minimizeEffectAvailable(),
                                                tilingAvailable(), layerPointer::ready(), state().luaConfigRegistered, chrome::ready(),
                                                frameProbe::ready() && state().hyprctlFramesCommand != nullptr && state().hyprctlFramesStartCommand != nullptr,
                                                appmenuAvailable(), tilingArrangeAvailable(), tileHoverAvailable(), tilingGroupsAvailable(),
                                                sharedEdgeAvailable(), tilingSplitAvailable(), toplevelDrag::ready());
            return gfc::capabilitiesJson(features);
        }
    } // namespace

    void postCapabilities() {
        postEvent(events::Key{.channel = events::Channel::Capabilities, .id = 0}, currentCapabilities());
    }

    void postMinimizeRequest(uint64_t address) {
        postEvent(events::Key{.channel = events::Channel::MinimizeRequest, .id = address}, gfc::minimizeRequestJson(std::format("{:x}", address)));
    }

    void postWithdrawn() {
        postNow(gfc::capabilitiesJson({}));
    }

    namespace {
        // Lua C functions report errors with longjmp, so their own frames hold only trivially destructible
        // values: the arguments are copied into these plain structs with non-raising Lua calls (lua_type,
        // lua_tolstring on strings, lua_tonumberx), and all C++ work runs in separate noexcept functions that
        // have returned before any further Lua call.
        template <size_t N>
        struct SLuaString {
            std::array<char, N> text{};
            size_t              size = 0;
            bool                ok   = false;

            std::string_view    view() const {
                return {text.data(), size};
            }
        };

        template <size_t N>
        SLuaString<N> readString(lua_State* L, int idx) {
            SLuaString<N> out;
            if (lua_type(L, idx) != LUA_TSTRING)
                return out;
            size_t      len = 0;
            const char* s   = lua_tolstring(L, idx, &len);
            if (!s || len >= N)
                return out;
            std::memcpy(out.text.data(), s, len);
            out.size = len;
            out.ok   = true;
            return out;
        }

        struct SWindowCall {
            SLuaString<24>        address;     // "0x" + 16 hex digits fits
            std::array<double, 4> rect{};      // x, y, w, h (layout coordinates)
            bool                  rectOk = false;
        };

        SWindowCall readWindowCall(lua_State* L) {
            SWindowCall call;
            call.address = readString<24>(L, 1);
            call.rectOk  = true;
            for (int i = 0; i < 4; ++i) {
                int isNumber = 0;
                if (lua_type(L, 2 + i) != LUA_TNUMBER) {
                    call.rectOk = false;
                    break;
                }
                call.rect[static_cast<size_t>(i)] = lua_tonumberx(L, 2 + i, &isNumber);
                if (!isNumber) {
                    call.rectOk = false;
                    break;
                }
            }
            return call;
        }

        void windowCallNoThrow(const SWindowCall& call, bool isMinimize) noexcept {
            guarded(isMinimize ? "hl.plugin.grassfield.minimize" : "hl.plugin.grassfield.restore", [&] {
                const auto address = call.address.ok ? minimize::parseAddress(call.address.view()) : std::nullopt;
                if (!address) {
                    logRequest(Log::WARN, "{}: rejected: invalid window address", isMinimize ? "minimize" : "restore");
                    return;
                }
                std::optional<minimize::Box> target;
                if (call.rectOk)
                    target = minimizer::validTarget(minimize::Box{call.rect[0], call.rect[1], call.rect[2], call.rect[3]});
                if (!target)
                    logRequest(Log::INFO, "{} {:x}: no valid Dock rectangle, no animation", isMinimize ? "minimize" : "restore", *address);
                if (isMinimize)
                    minimizer::minimize(*address, target);
                else
                    minimizer::restore(*address, target);
            });
        }

        void configNoThrow(const SLuaString<64>& key, const SLuaString<16>& value) noexcept {
            guarded("hl.plugin.grassfield.config", [&] {
                if (key.ok && value.ok && key.view() == gf::stages::kConfigStagesEnabled) {
                    const auto on = gf::stages::parseStagesEnabled(key.view(), value.view());
                    if (!on || !stagesAvailable()) {
                        logRequest(Log::WARN, "config: rejected ({} = true|false, and only while Stages is available)", gf::stages::kConfigStagesEnabled);
                        return;
                    }
                    const bool changed = stager::enabled() != *on;
                    stager::setEnabled(*on);
                    logRequest(Log::INFO, "config: {} = {}", gf::stages::kConfigStagesEnabled, value.view());
                    if (changed)
                        postCapabilities(); // "stages" appears or goes away
                    return;
                }
                // Dev fault injection: only in a dev session, never advertised (core/Minimize.hpp kConfigTestFault).
                if (key.ok && value.ok && minimize::isFunnelShaderFault(key.view(), value.view(), devSession())) {
                    genie::injectShaderFault();
                    logRequest(Log::WARN, "config: {} = {} (dev fault injection)", minimize::kConfigTestFault, value.view());
                    return;
                }
                if (key.ok && value.ok && key.view() == minimize::kConfigMinimizeEffect) {
                    const auto effect = minimize::parseEffect(key.view(), value.view());
                    if (!effect || !minimizeEffectAvailable()) {
                        logRequest(Log::WARN, "config: rejected ({} = funnel|shrink|fade, and only while minimize is available)", minimize::kConfigMinimizeEffect);
                        return;
                    }
                    minimizer::setEffect(*effect);
                    logRequest(Log::INFO, "config: {} = {}", minimize::kConfigMinimizeEffect, value.view());
                    return;
                }
                // The appearance the chrome follows (audit UX-06): every titlebar is drawn again in its palette, every rim comes
                // (dark) or goes (light).
                if (key.ok && value.ok && key.view() == gfc::kConfigAppearance) {
                    const auto appearance = gfc::parseAppearance(key.view(), value.view());
                    if (!appearance) {
                        logRequest(Log::WARN, "config: rejected ({} = dark|light)", gfc::kConfigAppearance);
                        return;
                    }
                    const bool changed = state().appearance.push(*appearance);
                    logRequest(Log::INFO, "config: {} = {}", gfc::kConfigAppearance, value.view());
                    if (changed) {
                        CGrassfieldTitlebar::onAppearanceChanged();
                        CGrassfieldRim::onAppearanceChanged(); // the dark appearance's inner rim comes or goes
                    }
                    return;
                }
                // Window tiling (core/Tiling.hpp): the switches of Desktop & Dock > Windows (tiling.md TL32).
                if (const auto sw = key.ok && value.ok ? tiling::switchOf(key.view()) : std::nullopt) {
                    const auto on = tiling::parseBool(value.view());
                    if (!on) {
                        logRequest(Log::WARN, "config: rejected ({} = true|false)", key.view());
                        return;
                    }
                    logRequest(Log::INFO, "config: {} = {}", key.view(), value.view());
                    switch (*sw) {
                        case tiling::Switch::Edges: state().tilingDrag.edges = *on; break;
                        case tiling::Switch::MenuBar: state().tilingDrag.menuBar = *on; break;
                        case tiling::Switch::AltDrag: state().tilingDrag.altDrag = *on; break;
                        case tiling::Switch::Margins:
                            if (state().tilingMargins != *on) {
                                state().tilingMargins = *on;
                                tiler::marginsChanged(); // every tiled window placed again (tiling.md TL2)
                            }
                            break;
                        case tiling::Switch::Layouts: state().tilingLayouts = *on; break;
                        case tiling::Switch::Suggestions:
                            state().tilingSuggestions = *on;
                            if (!*on)
                                tiler::suggestionsOff(); // the pending one ends with the switch (TL32)
                            break;
                    }
                    return;
                }
                const auto action = key.ok && value.ok ? gfc::parseDoubleClickAction(key.view(), value.view()) : std::nullopt;
                if (!action) {
                    logRequest(Log::WARN, "config: rejected (only {} = zoom|minimize|none|fill, {} = dark|light, {} = true|false, {} = funnel|shrink|fade and the tiling keys are accepted)",
                               gfc::kConfigTitlebarDoubleClick, gfc::kConfigAppearance, gf::stages::kConfigStagesEnabled, minimize::kConfigMinimizeEffect);
                    return;
                }
                state().doubleClickAction = *action;
                logRequest(Log::INFO, "config: {} = {}", gfc::kConfigTitlebarDoubleClick, value.view());
            });
        }

        void helloNoThrow() noexcept {
            guarded("hl.plugin.grassfield.hello", [] { postCapabilities(); });
        }

        void appmenuNoThrow(const SLuaString<24>& address) noexcept {
            guarded("hl.plugin.grassfield.appmenu", [&] {
                const auto window = address.ok ? minimize::parseAddress(address.view()) : std::nullopt;
                if (!window) {
                    logRequest(Log::WARN, "appmenu: rejected: invalid window address");
                    return;
                }
                if (!appmenuServer::announce(*window))
                    logRequest(Log::WARN, "appmenu: no mapped window {:x} (or appmenu inactive)", *window);
            });
        }

        // The payload is copied out of Lua like every argument (fixed-size, trivially destructible); one byte more than
        // the limit so that an oversized payload is recognized as such.
        using SOverviewPayload = SLuaString<gf::overview::kMaxPayloadBytes + 1>;

        void overviewNoThrow(const SOverviewPayload& payload) noexcept {
            guarded("hl.plugin.grassfield.overview", [&] {
                if (!payload.ok) {
                    logRequest(Log::WARN, "overview: rejected: the argument must be a JSON string of at most {} bytes", gf::overview::kMaxPayloadBytes);
                    overviewer::refuse(gf::overview::Reason::Invalid);
                    return;
                }
                const auto request = gf::overview::parseRequest(payload.view());
                if (!request) {
                    logRequest(Log::WARN, "overview: rejected: {}", request.error());
                    overviewer::refuse(gf::overview::Reason::Invalid);
                    return;
                }
                overviewer::request(*request);
            });
        }

        // Copied out of Lua like the overview payload (fixed-size, trivially destructible), one byte over the limit.
        using SStagesPayload = SLuaString<gf::stages::kMaxPayloadBytes + 1>;

        void stagesNoThrow(const SStagesPayload& payload) noexcept {
            guarded("hl.plugin.grassfield.stages", [&] {
                if (!payload.ok) {
                    logRequest(Log::WARN, "stages: rejected: the argument must be a JSON string of at most {} bytes", gf::stages::kMaxPayloadBytes);
                    stager::refuse(gf::stages::Reason::Invalid);
                    return;
                }
                const auto request = gf::stages::parseRequest(payload.view());
                if (!request) {
                    logRequest(Log::WARN, "stages: rejected: {}", request.error());
                    stager::refuse(gf::stages::Reason::Invalid);
                    return;
                }
                stager::request(*request);
            });
        }

        // Copied out of Lua like the overview payload (fixed-size, trivially destructible), one byte over the limit.
        using SOverviewFocusPayload = SLuaString<gf::overviewfocus::kMaxPayloadBytes + 1>;

        void overviewFocusNoThrow(const SOverviewFocusPayload& payload) noexcept {
            guarded("hl.plugin.grassfield.overview_focus", [&] {
                if (!payload.ok) {
                    logRequest(Log::WARN, "overview focus: rejected: the argument must be a JSON string of at most {} bytes", gf::overviewfocus::kMaxPayloadBytes);
                    overviewFocus::refuse();
                    return;
                }
                const auto request = gf::overviewfocus::parseRequest(payload.view());
                if (!request) {
                    logRequest(Log::WARN, "overview focus: rejected: {}", request.error());
                    overviewFocus::refuse();
                    return;
                }
                overviewFocus::request(*request);
            });
        }

        void cursorRefreshNoThrow() noexcept {
            guarded("hl.plugin.grassfield.cursor_refresh", [] { cursorRefresh::request(); });
        }

        // Pushes the result of hl.dsp.no_op() so that `hl.dispatch(hl.plugin.grassfield.hello())` (what
        // `hyprctl dispatch` / Quickshell's Hyprland.dispatch() evaluate under the Lua config) succeeds.
        // Pushes nothing if the dispatcher can't be obtained. Only trivially destructible values live in
        // this frame, because Lua reports errors with longjmp.
        int pushNoOpDispatcher(lua_State* L) {
            const int top = lua_gettop(L);

            const int hlType = lua_getglobal(L, "hl");
            if (hlType != LUA_TTABLE && hlType != LUA_TUSERDATA) {
                lua_settop(L, top);
                return 0;
            }
            const int dspType = lua_getfield(L, -1, "dsp");
            if (dspType != LUA_TTABLE && dspType != LUA_TUSERDATA) {
                lua_settop(L, top);
                return 0;
            }
            if (lua_getfield(L, -1, "no_op") != LUA_TFUNCTION) {
                lua_settop(L, top);
                return 0;
            }
            if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
                lua_settop(L, top);
                return 0;
            }

            lua_replace(L, top + 1); // result replaces `hl`
            lua_settop(L, top + 1);
            return 1;
        }

        // Pushes the result of hl.dsp.window.fullscreen({ mode = <mode> }): Hyprland's own dispatcher, the one the Full Screen and
        // Zoom keys of bindings.lua dispatched before window_size. Pushes nothing if it can't be obtained (bindings.lua then falls
        // back to that dispatcher itself). Only trivially destructible values live in this frame (Lua reports errors with
        // longjmp).
        int pushFullscreenDispatcher(lua_State* L, const char* mode) {
            const int top = lua_gettop(L);

            const int hlType = lua_getglobal(L, "hl");
            if (hlType != LUA_TTABLE && hlType != LUA_TUSERDATA) {
                lua_settop(L, top);
                return 0;
            }
            const int dspType = lua_getfield(L, -1, "dsp");
            if (dspType != LUA_TTABLE && dspType != LUA_TUSERDATA) {
                lua_settop(L, top);
                return 0;
            }
            const int windowType = lua_getfield(L, -1, "window");
            if (windowType != LUA_TTABLE && windowType != LUA_TUSERDATA) {
                lua_settop(L, top);
                return 0;
            }
            if (lua_getfield(L, -1, "fullscreen") != LUA_TFUNCTION) {
                lua_settop(L, top);
                return 0;
            }
            lua_createtable(L, 0, 1);
            lua_pushstring(L, mode);
            lua_setfield(L, -2, "mode");
            if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
                lua_settop(L, top);
                return 0;
            }

            lua_replace(L, top + 1); // result replaces `hl`
            lua_settop(L, top + 1);
            return 1;
        }

        int luaHello(lua_State* L) {
            helloNoThrow();
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.minimize(address, x, y, w, h): address "0x<hex>" of a mapped window; the rect is
        // the Dock tile (layout coordinates) the window shrinks into. Untrusted: validated, never interpolated.
        int luaMinimize(lua_State* L) {
            const SWindowCall call = readWindowCall(L);
            windowCallNoThrow(call, true);
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.restore(address, x, y, w, h): the rect is the Dock tile it grows from.
        int luaRestore(lua_State* L) {
            const SWindowCall call = readWindowCall(L);
            windowCallNoThrow(call, false);
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.config(key, value): allowlisted settings only.
        int luaConfig(lua_State* L) {
            const auto key   = readString<64>(L, 1);
            const auto value = readString<16>(L, 2);
            configNoThrow(key, value);
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.tile(address, place): Window > Move & Resize (core/Tiling.hpp names, or "previous").
        // Untrusted: both strings are copied out of Lua with fixed limits; the address is compared with the live windows.
        int luaTile(lua_State* L) {
            const auto address = readString<24>(L, 1);
            const auto place   = readString<24>(L, 2); // "right-two-thirds" is 16 characters
            guarded("hl.plugin.grassfield.tile", [&] {
                if (!address.ok || !place.ok) {
                    logRequest(Log::WARN, "tile: rejected: invalid arguments");
                    return;
                }
                tiler::tileRequest(address.view(), place.view());
            });
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.window_size(mode): the Full Screen and Zoom keys (bindings.lua; ADR-0040 step 1b's review: they
        // zoomed About This Computer, whose Window menu greys Zoom and Enter Full Screen). Returns Hyprland's own
        // hl.dsp.window.fullscreen({ mode = mode }), or a no-op when the focused window is of fixed size and not in that mode
        // (tiler::sizeKeyActs). Zoom is Fill (ADR-0036 D78): for "maximized" the plugin zooms the focused window itself
        // (tiler::zoomFocused: Fill, its box from before, out of Hyprland's maximized mode into Fill) and returns the no-op;
        // Hyprland's dispatcher only when the zoom stays Hyprland's (no window-tiling, client chrome's own zoom, full
        // screen). Untrusted: the mode is copied with a fixed limit and parsed strictly; anything else is a no-op.
        int luaWindowSize(lua_State* L) {
            const auto mode = readString<16>(L, 1);
            bool       act  = false;
            bool       zoom = false;
            guarded("hl.plugin.grassfield.window_size", [&] {
                const auto parsed = mode.ok ? tiling::parseSizeMode(mode.view()) : std::nullopt;
                if (!parsed) {
                    logRequest(Log::WARN, "window_size: rejected: the mode must be \"fullscreen\" or \"maximized\"");
                    return;
                }
                zoom = *parsed == tiling::SizeMode::Maximized;
                act  = tiler::sizeKeyActs(*parsed);
                if (act && zoom)
                    act = tiler::zoomFocused() == tiling::ZoomStep::Hyprland;
            });
            return act ? pushFullscreenDispatcher(L, zoom ? "maximized" : "fullscreen") : pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.arrange(json): a layout of the catalogue filled with windows (docs/specs/tiling.md TL6).
        // Untrusted: copied out of Lua with a fixed limit, parsed strictly (core/Tiling.hpp parseArrange), the windows and
        // the output compared with the live ones.
        int luaArrange(lua_State* L) {
            const auto payload = readString<tiling::kMaxArrangeBytes + 1>(L, 1);
            guarded("hl.plugin.grassfield.arrange", [&] {
                if (!payload.ok) {
                    logRequest(Log::WARN, "arrange: rejected: not a string of at most {} bytes", tiling::kMaxArrangeBytes);
                    tiler::arrangeRequest(""); // posts the refusal (reason invalid)
                    return;
                }
                tiler::arrangeRequest(payload.view());
            });
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.tile_popover(address): the tiling popover of that window, opened from the keyboard (TL26).
        // Untrusted: copied out of Lua with a fixed limit; the address is compared with the live windows.
        int luaTilePopover(lua_State* L) {
            const auto address = readString<24>(L, 1);
            guarded("hl.plugin.grassfield.tile_popover", [&] {
                if (!address.ok) {
                    logRequest(Log::WARN, "tile_popover: rejected: invalid arguments");
                    return;
                }
                CGrassfieldTitlebar::popoverRequest(address.view());
            });
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.move_to(address, output): Window > Move to <display> and the next-display keys (TL23, TL26).
        // Untrusted: both strings are copied out of Lua with fixed limits; the output name is checked (core outputNameOk) and
        // compared with the live outputs, the address with the live windows.
        int luaMoveTo(lua_State* L) {
            const auto address = readString<24>(L, 1);
            const auto output  = readString<tiling::kMaxOutputName + 1>(L, 2);
            guarded("hl.plugin.grassfield.move_to", [&] {
                if (!address.ok || !output.ok) {
                    logRequest(Log::WARN, "move_to: rejected: invalid arguments");
                    tiler::moveToRequest("", ""); // posts the refusal (reason invalid, or locked)
                    return;
                }
                tiler::moveToRequest(address.view(), output.view());
            });
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.group_front(address): the window's tile group comes forward with it (TL29: a window brought
        // forward from the Dock, the app switcher or the Overview). Untrusted: the address is compared with the live windows.
        int luaGroupFront(lua_State* L) {
            const auto address = readString<24>(L, 1);
            guarded("hl.plugin.grassfield.group_front", [&] {
                if (!address.ok) {
                    logRequest(Log::WARN, "group_front: rejected: invalid arguments");
                    tiler::groupFrontRequest(""); // posts the refusal (reason invalid, or locked)
                    return;
                }
                tiler::groupFrontRequest(address.view());
            });
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.split(address, side): Full Screen › Left or Right of Screen, a Split View Desktop (tiling.md TL33).
        // Untrusted: the address is compared with the live windows, the side with "left" and "right".
        int luaSplit(lua_State* L) {
            const auto address = readString<24>(L, 1);
            const auto side    = readString<8>(L, 2);
            guarded("hl.plugin.grassfield.split", [&] {
                if (!address.ok || !side.ok) {
                    logRequest(Log::WARN, "split: rejected: invalid arguments");
                    tiler::splitRequest("", ""); // posts the refusal (reason invalid, or locked)
                    return;
                }
                tiler::splitRequest(address.view(), side.view());
            });
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.unsplit(address[, how]): a window leaves its Split View Desktop (TL33): Move Window to Desktop
        // ("desktop", or no second argument: Exit Full Screen, D44), Make Window Full Screen ("fullscreen") or Replace Tiled
        // Window ("replace"; step 6d, ADR-0036 D71). Untrusted: the address is compared with the live windows, `how` with
        // those three words.
        int luaUnsplit(lua_State* L) {
            const auto address = readString<24>(L, 1);
            const bool hasHow  = !lua_isnoneornil(L, 2);
            const auto how     = readString<16>(L, 2);
            guarded("hl.plugin.grassfield.unsplit", [&] {
                if (!address.ok || (hasHow && !how.ok)) {
                    logRequest(Log::WARN, "unsplit: rejected: invalid arguments");
                    tiler::unsplitRequest(""); // no window: posts the refusal (reason invalid, or locked)
                    return;
                }
                tiler::unsplitRequest(address.view(), hasHow ? how.view() : std::string_view{});
            });
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.appmenu(address): re-posts the appmenu event of a mapped window (the shell calls it
        // after a restart). Untrusted: the address is parsed and compared with the live windows.
        int luaAppmenu(lua_State* L) {
            const auto address = readString<24>(L, 1);
            appmenuNoThrow(address);
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.overview(json): live window transforms (docs/specs/overview.md "v2"). Untrusted: parsed
        // and validated strictly (core/Overview.*), windows compared with the live ones, rects checked against monitors.
        int luaOverview(lua_State* L) {
            const auto payload = readString<gf::overview::kMaxPayloadBytes + 1>(L, 1);
            overviewNoThrow(payload);
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.stages(json): Stages (docs/specs/stages.md "Shell contract"), only while the feature flag is
        // on. Untrusted: parsed and validated strictly (core/Stages.*), monitors, windows and stages compared with the live
        // ones, tiles checked against the shell's strip surface.
        int luaStages(lua_State* L) {
            const auto payload = readString<gf::stages::kMaxPayloadBytes + 1>(L, 1);
            stagesNoThrow(payload);
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.cursor_refresh(): the pointer on screen is drawn again at the size Hyprland holds now (the
        // shell calls it after its `setcursor <theme> <size>` was answered "ok"); same shape, same place. No argument
        // (any is ignored, nothing is read from Lua); rate-limited in core/CursorRefresh (FR39-FR40).
        int luaCursorRefresh(lua_State* L) {
            cursorRefreshNoThrow();
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.overview_focus(json): what gets the keyboard when the Overview closes (docs/specs/overview.md
        // "Close focus"). Untrusted: parsed and validated strictly (core/OverviewFocus.*), the window and the Desktop
        // compared with the live ones when the focus is made.
        int luaOverviewFocus(lua_State* L) {
            const auto payload = readString<gf::overviewfocus::kMaxPayloadBytes + 1>(L, 1);
            overviewFocusNoThrow(payload);
            return pushNoOpDispatcher(L);
        }

        std::string hyprctlGrassfield(eHyprCtlOutputFormat /*format*/, const std::string& /*args*/) noexcept {
            // Same JSON for both output formats: the payload is already machine-readable.
            std::string out;
            // The reply (not the event) also names the plugin version, so About, pacman -Qi, the plugin and the bridge compare (GF-013).
            if (!guarded("hyprctl grassfield", [&] { out = currentCapabilities(); out.insert(out.size() - 1, std::string{R"(,"version":")"} + kPluginVersion + '"'); }))
                out = R"({"v":"gfc/1","type":"error"})";
            return out;
        }

        // `hyprctl grassfield-frames`: the presented-frame timestamps of every monitor (ADR-0006 P3, core/FrameLog.hpp).
        // Read-only, no argument; the same JSON for both output formats.
        std::string hyprctlFrames(eHyprCtlOutputFormat /*format*/, const std::string& /*args*/) noexcept {
            std::string out;
            if (!guarded("hyprctl grassfield-frames", [&] { out = frameProbe::json(); }))
                out = R"({"v":"gfc/1","type":"error"})";
            return out;
        }

        // `hyprctl grassfield-frames-start`: the frames of the next 60 s are recorded (nothing is otherwise, never while the
        // session is locked); the measurement tools send it (tests/visual/presented-frames.sh).
        std::string hyprctlFramesStart(eHyprCtlOutputFormat /*format*/, const std::string& /*args*/) noexcept {
            std::string out;
            if (!guarded("hyprctl grassfield-frames-start", [&] { out = frameProbe::startRecording(); }))
                out = R"({"v":"gfc/1","type":"error"})";
            return out;
        }

        // `hyprctl grassfield-stages`: the Stages state of the latest `stages` notice (the event carries no state: Hyprland
        // cuts socket2 events at 1024 bytes). Read-only, no argument; the same JSON for both output formats.
        std::string hyprctlStages(eHyprCtlOutputFormat /*format*/, const std::string& /*args*/) noexcept {
            std::string out;
            if (!guarded("hyprctl grassfield-stages", [&] { out = stager::stateReply(); }))
                out = R"({"v":"gfc/1","type":"error"})";
            return out;
        }

        // `hyprctl grassfield-tiling`: the tiled windows per output (the `tiling` event is a change notice only). Read-only,
        // no argument; the same JSON for both output formats.
        std::string hyprctlTiling(eHyprCtlOutputFormat /*format*/, const std::string& /*args*/) noexcept {
            std::string out;
            if (!guarded("hyprctl grassfield-tiling", [&] { out = tiler::stateReply(); }))
                out = R"({"v":"gfc/1","type":"error"})";
            return out;
        }

        bool addLua(std::string_view name, PLUGIN_LUA_FN fn) {
            const bool ok = HyprlandAPI::addLuaFunction(state().handle, std::string{gfc::kLuaNamespace}, std::string{name}, fn);
            if (!ok)
                log(Log::ERR, "addLuaFunction({}.{}) failed", gfc::kLuaNamespace, name);
            return ok;
        }

        void removeLua(bool& registered, std::string_view name) {
            if (!registered)
                return;
            HyprlandAPI::removeLuaFunction(state().handle, std::string{gfc::kLuaNamespace}, std::string{name});
            registered = false;
        }

    } // namespace

    bool registerAll() {
        auto& s = state();

        // No HyprlandAPI::addDispatcherV2: with Hyprland's Lua config, `hyprctl dispatch X` (and
        // Quickshell's Hyprland.dispatch) evaluate `return hl.dispatch(X)`, so a legacy plugin
        // dispatcher name such as "grassfield:hello" is a Lua syntax error and can never be reached
        // (measured in spike S2, see docs/specs/compositor.md). Lua functions are the entry points.
        s.luaHelloRegistered    = addLua(gfc::kLuaHello, luaHello);
        s.luaMinimizeRegistered = addLua(gfc::kLuaMinimize, luaMinimize);
        s.luaRestoreRegistered  = addLua(gfc::kLuaRestore, luaRestore);
        s.luaConfigRegistered   = addLua(gfc::kLuaConfig, luaConfig);
        s.luaAppmenuRegistered  = appmenuServer::ready() && addLua(gfc::kLuaAppmenu, luaAppmenu); // only with the global
        s.luaOverviewRegistered = overviewer::ready() && addLua(gfc::kLuaOverview, luaOverview);  // only with the render hooks
        s.luaStagesRegistered   = stager::ready() && addLua(gfc::kLuaStages, luaStages);          // only with its listeners
        s.luaCursorRefreshRegistered = cursorRefresh::ready() && addLua(gfc::kLuaCursorRefresh, luaCursorRefresh); // only with a renderer
        s.luaOverviewFocusRegistered = overviewFocus::ready() && addLua(gfc::kLuaOverviewFocus, luaOverviewFocus);   // only with its listeners
        s.luaTileRegistered          = addLua(gfc::kLuaTile, luaTile);
        s.luaArrangeRegistered       = tiler::ready() && addLua(gfc::kLuaArrange, luaArrange); // only with its listeners
        s.luaTilePopoverRegistered   = addLua(gfc::kLuaTilePopover, luaTilePopover);
        s.luaMoveToRegistered        = addLua(gfc::kLuaMoveTo, luaMoveTo);
        s.luaGroupFrontRegistered    = tiler::ready() && addLua(gfc::kLuaGroupFront, luaGroupFront); // only with the tile records
        s.luaSplitRegistered         = tiler::ready() && addLua(gfc::kLuaSplit, luaSplit);           // only with the tile records
        s.luaUnsplitRegistered       = tiler::ready() && addLua(gfc::kLuaUnsplit, luaUnsplit);
        s.luaWindowSizeRegistered    = addLua(gfc::kLuaWindowSize, luaWindowSize); // without it bindings.lua uses Hyprland's own
        bool ok                = s.luaHelloRegistered && s.luaMinimizeRegistered && s.luaRestoreRegistered && s.luaConfigRegistered;

        s.hyprctlCommand = HyprlandAPI::registerHyprCtlCommand(s.handle, SHyprCtlCommand{.name = std::string{gfc::kHyprctlCommand}, .exact = true, .fn = hyprctlGrassfield});
        if (!s.hyprctlCommand) {
            log(Log::ERR, "registerHyprCtlCommand({}) failed", gfc::kHyprctlCommand);
            ok = false;
        }
        // Stages needs its state command: without it neither stages-available nor stages is advertised.
        if (stager::ready()) {
            s.hyprctlStagesCommand = HyprlandAPI::registerHyprCtlCommand(s.handle, SHyprCtlCommand{.name = std::string{gfc::kHyprctlStagesCommand}, .exact = true, .fn = hyprctlStages});
            if (!s.hyprctlStagesCommand)
                log(Log::WARN, "registerHyprCtlCommand({}) failed; Stages not advertised", gfc::kHyprctlStagesCommand);
        }
        // Tiling arrangements need the state command: without it tiling-arrange is not advertised (tile still works).
        if (tiler::ready()) {
            s.hyprctlTilingCommand = HyprlandAPI::registerHyprCtlCommand(s.handle, SHyprCtlCommand{.name = std::string{gfc::kHyprctlTilingCommand}, .exact = true, .fn = hyprctlTiling});
            if (!s.hyprctlTilingCommand)
                log(Log::WARN, "registerHyprCtlCommand({}) failed; tiling-arrange not advertised", gfc::kHyprctlTilingCommand);
        }
        // Optional: without it frame-times is not advertised, nothing else changes.
        if (frameProbe::ready()) {
            s.hyprctlFramesCommand = HyprlandAPI::registerHyprCtlCommand(s.handle, SHyprCtlCommand{.name = std::string{frames::kHyprctlCommand}, .exact = true, .fn = hyprctlFrames});
            if (!s.hyprctlFramesCommand)
                log(Log::WARN, "registerHyprCtlCommand({}) failed; frame-times not advertised", frames::kHyprctlCommand);
            s.hyprctlFramesStartCommand =
                HyprlandAPI::registerHyprCtlCommand(s.handle, SHyprCtlCommand{.name = std::string{frames::kHyprctlStartCommand}, .exact = true, .fn = hyprctlFramesStart});
            if (!s.hyprctlFramesStartCommand)
                log(Log::WARN, "registerHyprCtlCommand({}) failed; frame-times not advertised", frames::kHyprctlStartCommand);
        }

        return ok;
    }

    void unregisterAll() {
        auto& s = state();
        removeLua(s.luaHelloRegistered, gfc::kLuaHello);
        removeLua(s.luaMinimizeRegistered, gfc::kLuaMinimize);
        removeLua(s.luaRestoreRegistered, gfc::kLuaRestore);
        removeLua(s.luaConfigRegistered, gfc::kLuaConfig);
        removeLua(s.luaAppmenuRegistered, gfc::kLuaAppmenu);
        removeLua(s.luaOverviewRegistered, gfc::kLuaOverview);
        removeLua(s.luaStagesRegistered, gfc::kLuaStages);
        removeLua(s.luaCursorRefreshRegistered, gfc::kLuaCursorRefresh);
        removeLua(s.luaOverviewFocusRegistered, gfc::kLuaOverviewFocus);
        removeLua(s.luaTileRegistered, gfc::kLuaTile);
        removeLua(s.luaArrangeRegistered, gfc::kLuaArrange);
        removeLua(s.luaTilePopoverRegistered, gfc::kLuaTilePopover);
        removeLua(s.luaMoveToRegistered, gfc::kLuaMoveTo);
        removeLua(s.luaGroupFrontRegistered, gfc::kLuaGroupFront);
        removeLua(s.luaSplitRegistered, gfc::kLuaSplit);
        removeLua(s.luaUnsplitRegistered, gfc::kLuaUnsplit);
        removeLua(s.luaWindowSizeRegistered, gfc::kLuaWindowSize);
        if (s.hyprctlCommand) {
            HyprlandAPI::unregisterHyprCtlCommand(s.handle, s.hyprctlCommand);
            s.hyprctlCommand.reset();
        }
        if (s.hyprctlStagesCommand) {
            HyprlandAPI::unregisterHyprCtlCommand(s.handle, s.hyprctlStagesCommand);
            s.hyprctlStagesCommand.reset();
        }
        if (s.hyprctlTilingCommand) {
            HyprlandAPI::unregisterHyprCtlCommand(s.handle, s.hyprctlTilingCommand);
            s.hyprctlTilingCommand.reset();
        }
        if (s.hyprctlFramesStartCommand) {
            HyprlandAPI::unregisterHyprCtlCommand(s.handle, s.hyprctlFramesStartCommand);
            s.hyprctlFramesStartCommand.reset();
        }
        if (s.hyprctlFramesCommand) {
            HyprlandAPI::unregisterHyprCtlCommand(s.handle, s.hyprctlFramesCommand);
            s.hyprctlFramesCommand.reset();
        }
    }

} // namespace gf::ipc
