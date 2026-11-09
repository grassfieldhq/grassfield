#pragma once

// gfc/1: the versioned shell <-> grassfield-compositor protocol (master-prompt §5.3, ADR-0007 input).
// Plain C++ with no Hyprland includes, so it is unit-testable (compositor/tests/).
//
// Transport measured in spike S2:
//   plugin -> shell: Hyprland's socket2 event stream. Hyprland formats each event as
//                    "<name>>><data>\n"; the plugin posts name "grassfield" with compact JSON as data.
//   shell -> plugin: Lua functions under hl.plugin.grassfield.*, reached with
//                    `hyprctl dispatch 'hl.plugin.grassfield.<verb>()'` / Hyprland.dispatch(...) in
//                    Quickshell (Hyprland evaluates `return hl.dispatch(<arg>)` under the Lua config).
//   query:           `hyprctl grassfield` returns the capabilities JSON.

#include "Theme.hpp"

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace gf::gfc {

    inline constexpr std::string_view kVersion        = "gfc/1";
    inline constexpr std::string_view kEventName      = "grassfield"; // socket2 event name
    inline constexpr std::string_view kHyprctlCommand = "grassfield"; // `hyprctl grassfield`
    // `hyprctl grassfield-stages`: the full Stages state (the `stages` event is only a change notice, ADR-0007 amendment
    // 2026-10-24).
    inline constexpr std::string_view kHyprctlStagesCommand = "grassfield-stages";
    // Hyprland 0.56.2 cuts the data of a socket2 event at 1024 bytes (CEventManager::formatEvent: the payload view is
    // min(size, 0x400), then "{}>>{}\n"; read from the binary), so every gfc/1 event must stay below it whatever the number
    // of windows or monitors. The request socket (`hyprctl`) has no such limit.
    inline constexpr size_t kMaxEventBytes = 1024;
    inline constexpr std::string_view kLuaNamespace   = "grassfield"; // hl.plugin.grassfield
    inline constexpr std::string_view kLuaHello       = "hello";      // hl.plugin.grassfield.hello(): re-posts capabilities
    inline constexpr std::string_view kLuaMinimize    = "minimize";   // hl.plugin.grassfield.minimize(address, x, y, w, h)
    inline constexpr std::string_view kLuaRestore     = "restore";    // hl.plugin.grassfield.restore(address, x, y, w, h)
    inline constexpr std::string_view kLuaConfig      = "config";     // hl.plugin.grassfield.config(key, value)
    inline constexpr std::string_view kLuaAppmenu     = "appmenu";    // hl.plugin.grassfield.appmenu(address): re-posts its appmenu event
    inline constexpr std::string_view kLuaOverview    = "overview";   // hl.plugin.grassfield.overview(json): live window transforms
    inline constexpr std::string_view kLuaStages      = "stages";     // hl.plugin.grassfield.stages(json): Stages (behind config stagesEnabled)
    inline constexpr std::string_view kLuaCursorRefresh = "cursor_refresh"; // hl.plugin.grassfield.cursor_refresh(): redraw the pointer at its size
    inline constexpr std::string_view kLuaOverviewFocus = "overview_focus"; // hl.plugin.grassfield.overview_focus(json): focus after the Overview closes
    inline constexpr std::string_view kLuaTile = "tile"; // hl.plugin.grassfield.tile(address, place): Window > Move & Resize (core/Tiling.hpp)
    inline constexpr std::string_view kLuaArrange = "arrange"; // hl.plugin.grassfield.arrange(json): a layout of several windows (core/Tiling.hpp)
    // hl.plugin.grassfield.tile_popover(address): the tiling popover with the keyboard (a tile-hover "open" event, tiling.md TL26)
    inline constexpr std::string_view kLuaTilePopover = "tile_popover";
    // hl.plugin.grassfield.move_to(address, output): the window onto another output (Move to <display>, tiling.md TL23, TL26)
    inline constexpr std::string_view kLuaMoveTo = "move_to";
    // hl.plugin.grassfield.group_front(address): the window's tile group comes forward with it (tiling.md TL29)
    inline constexpr std::string_view kLuaGroupFront = "group_front";
    // hl.plugin.grassfield.split(address, side): Full Screen › Left or Right of Screen, a Split View Desktop (tiling.md TL33)
    inline constexpr std::string_view kLuaSplit = "split";
    // hl.plugin.grassfield.unsplit(address): Exit Full Screen of a window of a Split View Desktop (tiling.md TL33)
    inline constexpr std::string_view kLuaUnsplit = "unsplit";
    // hl.plugin.grassfield.window_size(mode): the Full Screen and Zoom keys ("fullscreen" | "maximized", bindings.lua): returns
    // Hyprland's own fullscreen dispatcher, or a no-op for a window of fixed size (ADR-0040 step 1b's review)
    inline constexpr std::string_view kLuaWindowSize = "window_size";
    // `hyprctl grassfield-tiling`: the tiling state (the `tiling` event is only a change notice, ADR-0036).
    inline constexpr std::string_view kHyprctlTilingCommand = "grassfield-tiling";

    // What a shell sends through Hyprland.dispatch() to call a plugin verb.
    std::string luaDispatchRequest(std::string_view verb);

    // Features. Only advertise what really works (R11): decorations whenever the plugin is active, the others
    // only when their entry points (and, for minimize, its render hooks) registered at load.
    inline constexpr std::string_view kFeatureDecorations = "decorations";
    inline constexpr std::string_view kFeatureMinimize    = "minimize";
    inline constexpr std::string_view kFeatureConfig      = "config";
    inline constexpr std::string_view kFeatureAppmenu     = "appmenu"; // org_kde_kwin_appmenu_manager global + appmenu events
    inline constexpr std::string_view kFeatureOverview    = "overview"; // hl.plugin.grassfield.overview + window transformers + overview events
    inline constexpr std::string_view kFeatureDesktopFocus = "desktop-focus"; // click-to-focus policy for the desktop surface (ADR-0012)
    // Same policy, with the press target taken from under the cursor when the pointer focus is stale (a click without
    // motion after a popup closed) and late grants dropped on any other focus change. Always advertised together with
    // desktop-focus; the shell enables its file-changing desktop keys only with this one (shell main 23caeab).
    inline constexpr std::string_view kFeatureDesktopFocusV2 = "desktop-focus-v2";
    // Stages (ADR-0013): "stages-available" when the hooks and hl.plugin.grassfield.stages registered (the shell pushes its
    // setting windows.stages as config stagesEnabled; its Stages toggle and strip are D-4 work); "stages" only while the
    // feature flag config stagesEnabled is true (the shell's strip then sends op:on).
    inline constexpr std::string_view kFeatureStagesAvailable = "stages-available";
    inline constexpr std::string_view kFeatureStages          = "stages";
    // hl.plugin.grassfield.cursor_refresh(): the pointer on screen is drawn again at the size Hyprland holds (after the
    // shell's `setcursor <theme> <size>`), same shape, same place (Settings > Accessibility > Pointer, ADR-0014).
    inline constexpr std::string_view kFeatureCursorRefresh = "cursor-refresh";
    // hl.plugin.grassfield.overview_focus(json): the shell names what gets the keyboard when the Overview closes; the plugin
    // focuses it once no Exclusive layer surface is left (docs/specs/overview.md "Close focus", owner decision batch 5).
    inline constexpr std::string_view kFeatureOverviewFocus = "overview-focus";
    // hl.plugin.grassfield.config("minimizeEffect", "funnel" | "shrink" | "fade") is accepted: the minimize animation follows
    // Settings dock.minimizeEffect ("Minimize animation"), "fade" while Reduce Motion is on. Advertised with
    // minimize and config; a shell pushes the key only when it sees this feature (older plugins reject the key).
    inline constexpr std::string_view kFeatureMinimizeEffect = "minimize-effect";
    // Window tiling (core/Tiling.hpp, FR47-FR50): titlebar drags tile at the free side edges, their corners and the menu
    // bar; hl.plugin.grassfield.tile(address, place) and the config keys tilingEdges / tilingMenuBar / tilingMargins.
    inline constexpr std::string_view kFeatureWindowTiling = "window-tiling";
    // ADR-0036 D78 (tiling.md TL35): Zoom is Fill. tile(address, "zoom") is Grassfield's zoom toggle (Fill, back to the box
    // from before; a window in Hyprland's maximized mode leaves it into Fill, client chrome's own zoom honoured), and the
    // titlebar's zoom light, its double-click and window_size("maximized") (Super+Alt+F) do the same. Always right after
    // window-tiling: the shell's Window > Zoom sends "zoom" only with it (an older plugin rejects the place), Hyprland's
    // maximized mode otherwise.
    inline constexpr std::string_view kFeatureZoomFill = "zoom-fill";
    // No verb: when a layer surface of the shell ("grassfield-*") maps or takes the keyboard, the plugin re-runs Hyprland's
    // pointer focus at the cursor, so a click without motion reaches what is under the pointer (spec FR51-FR52,
    // core/LayerPointer.hpp).
    inline constexpr std::string_view kFeatureLayerPointer = "layer-pointer";
    // hl.plugin.grassfield.config("appearance", "dark" | "light") is accepted: the compositor-drawn chrome (titlebars, the
    // tiling preview) follows the appearance (audit UX-06). Advertised with config; a shell pushes the key only when it sees
    // this feature (older plugins reject the key).
    inline constexpr std::string_view kFeatureAppearance = "appearance";
    // ADR-0015 P2: the plugin steps aside for windows that draw their own chrome (no titlebar on a window tagged
    // grassfield-client-chrome, band 0 in Stages, their minimize light and zoomed drag bridged). The shell's Overview
    // reserves no titlebar band above such a window only while this feature is advertised (shell/overview/ClientChrome.js).
    inline constexpr std::string_view kFeatureClientChrome = "client-chrome";
    // ADR-0006 P3: per-monitor presented-frame timestamps, read with `hyprctl grassfield-frames` (core/FrameLog.hpp).
    inline constexpr std::string_view kFeatureFrameTimes = "frame-times";
    // No verb: `keyboard-focus` events (keyboardFocusJson) each time the seat's keyboard focus enters a mapped window. The
    // menu bar sends a chosen item's action once the window it belongs to has the keyboard back (an Electron click handler
    // runs for its focused window only; docs/specs/menu-bridge.md MB12). Advertised with appmenu.
    inline constexpr std::string_view kFeatureKeyboardFocus = "keyboard-focus";
    // ADR-0036 step 1: hl.plugin.grassfield.arrange(json) (a layout of the catalogue filled with several windows), the
    // `tiling` notice and `hyprctl grassfield-tiling` (the tile records), the thirds as tile() places and
    // config("titlebarDoubleClick", "fill"). Advertised when the verb, the command and the listeners registered.
    inline constexpr std::string_view kFeatureTilingArrange = "tiling-arrange";
    // ADR-0036 step 4a (tiling.md TL27, TL28): arrange takes "with" (a pick of the suggestions joins the group of the window
    // that asked) and the grassfield-tiling reply carries the pending "suggestion". Advertised together with tiling-arrange
    // (the same verb, command and listeners).
    inline constexpr std::string_view kFeatureTilingLayouts = "tiling-layouts";
    // tile-hover events, hl.plugin.grassfield.tile_popover and hl.plugin.grassfield.move_to (tiling.md TL22-TL26): the tiling
    // popover. Only together with window-tiling.
    inline constexpr std::string_view kFeatureTileHover = "tile-hover";
    // ADR-0036 step 4b (tiling.md TL29): hl.plugin.grassfield.group_front, the tile groups the shell brings forward and lists
    // (from the grassfield-tiling reply). Only together with window-tiling and tiling-arrange.
    inline constexpr std::string_view kFeatureTilingGroups = "tiling-groups";
    // ADR-0036 step 4c (tiling.md TL30): the shared edge's handle between windows of a tile group (the plugin's own drag; no
    // verb, no event: the tiling notice says "resized" at its end). Only together with window-tiling and tiling-arrange.
    inline constexpr std::string_view kFeatureTilingSharedEdge = "tiling-shared-edge";
    // ADR-0036 step 6a (tiling.md TL33): hl.plugin.grassfield.split and unsplit, the Split View Desktops (the grassfield-tiling
    // reply lists them in "splits"). Only together with window-tiling and tiling-arrange.
    inline constexpr std::string_view kFeatureTilingSplit = "tiling-split";
    // ADR-0036 step 6d (tiling.md TL33, D71): unsplit's second argument (Make Window Full Screen, Replace Tiled Window). Always
    // right after tiling-split: a plugin before 6d ignores the argument, so the shell offers the rows only with this.
    inline constexpr std::string_view kFeatureTilingSplitRows = "tiling-split-rows";
    // ADR-0036 step 6e (tiling.md TL33, D73): a Split View member's titlebar is away (revealed at the top edge of its half) and
    // no band is kept above it. Always right after tiling-split-rows: the shell's Overview lays a member out without a strip.
    inline constexpr std::string_view kFeatureTilingSplitTitles = "tiling-split-titles";
    // No verb (ADR-0036 amendment 2026-11-08, URR-030): the plugin serves xdg_toplevel_drag_manager_v1, so a browser tab torn
    // off moves with the pointer, drops back into a tab strip and tiles like any dragged window. Informational: the shell needs
    // nothing; advertised while the global is up.
    inline constexpr std::string_view kFeatureToplevelDrag = "toplevel-drag";
    inline constexpr std::string_view kFeatures[]         = {kFeatureDecorations}; // always on

    // The advertised list, in a stable order: decorations, then minimize, config, appmenu, overview, desktop-focus and
    // desktop-focus-v2 (together), stages-available, stages (stages only together with stages-available), cursor-refresh,
    // overview-focus, minimize-effect, window-tiling with zoom-fill, layer-pointer, appearance, client-chrome, frame-times, keyboard-focus,
    // tiling-arrange with tiling-layouts, tile-hover (each only together with window-tiling), tiling-groups,
    // tiling-shared-edge and tiling-split (each only together with tiling-arrange; tiling-split with tiling-split-rows and
    // tiling-split-titles), toplevel-drag.
    std::vector<std::string_view> features(bool minimize, bool config, bool appmenu, bool overview = false, bool desktopFocus = false, bool stagesAvailable = false,
                                           bool stagesEnabled = false, bool cursorRefresh = false, bool overviewFocus = false, bool minimizeEffect = false,
                                           bool windowTiling = false, bool layerPointer = false, bool appearance = false, bool clientChrome = false,
                                           bool frameTimes = false, bool keyboardFocus = false, bool tilingArrange = false, bool tileHover = false,
                                           bool tilingGroups = false, bool sharedEdge = false, bool split = false, bool toplevelDrag = false);

    // Settings the shell pushes with hl.plugin.grassfield.config(key, value). Allowlist: this key, appearance (below),
    // stagesEnabled (core/Stages.hpp), minimizeEffect (core/Minimize.hpp) and the tiling keys (core/Tiling.hpp).
    inline constexpr std::string_view kConfigTitlebarDoubleClick = "titlebarDoubleClick";

    // The appearance the chrome follows (Settings appearance, the effective light/dark the shell shows).
    inline constexpr std::string_view kConfigAppearance = "appearance";

    // nullopt unless key is kConfigAppearance and value is exactly "dark" or "light".
    std::optional<theme::Appearance> parseAppearance(std::string_view key, std::string_view value);

    // What a double-click on a titlebar's drag area does (Settings windows.titlebarDoubleClick).
    enum class DoubleClickAction : uint8_t {
        Zoom,     // the zoom button's toggle (default)
        Minimize, // the minimize button's path (minimize-request)
        None,     // nothing: the second press is handled like a single press
        Fill,     // the window fills the work area as a tile (macOS 26/27 "Fill", Window > Fill; feature tiling-arrange)
    };

    // nullopt unless key is kConfigTitlebarDoubleClick and value is exactly "zoom", "minimize", "none" or "fill".
    std::optional<DoubleClickAction> parseDoubleClickAction(std::string_view key, std::string_view value);

    // JSON string escaping (RFC 8259): quotes, backslash and control characters.
    std::string jsonEscape(std::string_view in);

    // {"v":"gfc/1","type":"capabilities","features":[...]}. At unload the plugin posts it with an empty list: no feature
    // is available any more (the shell goes back to its fallbacks, as without the plugin).
    std::string capabilitiesJson(std::span<const std::string_view> features = kFeatures);

    // The minimize button (or a double-click set to minimize) asks the shell, which owns the Dock tile
    // rectangle, to minimize; the shell answers with hl.plugin.grassfield.minimize(address, x, y, w, h).
    // {"v":"gfc/1","type":"minimize-request","address":"<hex address, no 0x, as in socket2 events>"}
    std::string minimizeRequestJson(std::string_view windowAddress);

    // Posted when a minimize / restore has completed (end of its animation, or at once without one).
    // {"v":"gfc/1","type":"minimized","address":"<hex>"} / {"v":"gfc/1","type":"restored","address":"<hex>"}
    std::string minimizedJson(std::string_view windowAddress);
    std::string restoredJson(std::string_view windowAddress);

    // A window's DBusMenu address, from org_kde_kwin_appmenu.set_address (validated by core/Appmenu); empty
    // service and path when the window has no (more) registration. `pid`: process id of the Wayland client that
    // registered it (additive gfc/1 field; 0 when unknown or cleared; negative values are written as 0).
    // {"v":"gfc/1","type":"appmenu","address":"<hex>","service":"<bus name>","path":"<object path>","pid":N}
    std::string appmenuJson(std::string_view windowAddress, std::string_view service, std::string_view path, int pid);

    // The seat's keyboard focus entered the mapped window `windowAddress` (feature keyboard-focus).
    // {"v":"gfc/1","type":"keyboard-focus","address":"<hex>"}
    std::string keyboardFocusJson(std::string_view windowAddress);

    // The titlebar the plugin draws over a full-screen window on the output `output` was revealed at the top edge or went away
    // (ADR-0015 P6; tiling.md TL33 step 6c, ADR-0036 D65: the menu bar reveals and hides with it). No feature: an older plugin
    // never sends it and the menu bar keeps its own auto-hide.
    // {"v":"gfc/1","type":"titlebar-reveal","output":"<name>","revealed":true}
    std::string titlebarRevealJson(std::string_view output, bool revealed);

    // The line a socket2 subscriber receives for a given payload (without the trailing newline).
    std::string socket2Line(std::string_view json);

} // namespace gf::gfc
