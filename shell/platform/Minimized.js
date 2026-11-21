.pragma library

// Minimized-window bookkeeping (pure, unit-tested). The shell records every window it
// minimized: Hyprland has no minimized state, so the record is the source of truth for the Dock.
// Record: {toplevel, address, appId, title, screen} (`screen`: the display it was minimized from, "" when unknown, e.g. a
// record rebuilt after a shell restart).

// Verbs of the compositor plugin (hl.plugin.grassfield.<verb>); anything else is never put in Lua.
var pluginVerbs = ["hello", "minimize", "restore", "config", "appmenu", "overview", "cursor_refresh", "overview_focus", "tile", "stages", "arrange",
    "tile_popover", "move_to", "group_front", "split", "unsplit"];

function isPluginVerb(verb) {
    return typeof verb === "string" && pluginVerbs.indexOf(verb) >= 0;
}

// Lua function body calling a plugin verb only when the plugin registered it (a missing plugin is a
// no-op), built from already validated pieces. Quickshell sends it as `return hl.dispatch(<body>)`.
function guardedPluginCall(verb, args) {
    if (!isPluginVerb(verb))
        return "";
    return "function() local p = hl.plugin and hl.plugin.grassfield; if p and p." + verb + " then p." + verb + "(" + args.join(", ") + ") end end";
}

// hl.plugin.grassfield.minimize / restore(address, x, y, w, h) (gfc/1, ADR-0007). The address is
// validated hex, the rectangle (layout coordinates, the Dock tile) finite numbers rounded to integers;
// "" when anything is invalid (callers must not dispatch it).
function windowCall(verb, address, rect) {
    const hex = normalizeAddress(address);
    const r = finiteRect(rect);
    if ((verb !== "minimize" && verb !== "restore") || hex === "" || !r)
        return "";
    const args = ["\"0x" + hex + "\""];
    [r.x, r.y, r.w, r.h].forEach(n => args.push(String(Math.round(n))));
    return guardedPluginCall(verb, args);
}

// hl.plugin.grassfield.tile(address, place) (capability "window-tiling", compositor FR49): Window > Move & Resize and
// the tiling keys. The place is one of these names; "" when anything is invalid (callers must not dispatch it).
var tilePlaces = ["left", "right", "top", "bottom", "top-left", "top-right", "bottom-left", "bottom-right", "fill", "center", "previous"];

function tileCall(address, place) {
    const hex = normalizeAddress(address);
    if (hex === "" || typeof place !== "string" || tilePlaces.indexOf(place) < 0)
        return "";
    return guardedPluginCall("tile", ["\"0x" + hex + "\"", "\"" + place + "\""]);
}

// Window > Zoom and the green light clicked under its popover (ADR-0036 D78, capability "zoom-fill"): Zoom is Fill, the
// plugin's zoom toggle (hl.plugin.grassfield.tile(address, "zoom")). Without the capability the caller uses
// fullscreenRequest(address, "maximized"). "" for an invalid address (callers must not dispatch it).
function zoomCall(address) {
    const hex = normalizeAddress(address);
    return hex === "" ? "" : guardedPluginCall("tile", ["\"0x" + hex + "\"", "\"zoom\""]);
}

// The zoom request for `address`: the plugin's Fill toggle when it advertises "zoom-fill" (`canZoomFill`), else Hyprland's
// maximized mode as before (gate C2). "" for an invalid address.
function zoomRequest(address, canZoomFill) {
    return canZoomFill === true ? zoomCall(address) : fullscreenRequest(address, "maximized");
}

// hl.plugin.grassfield.arrange(json) (capability "tiling-arrange", docs/specs/tiling.md TL6): the window takes the first zone of
// the layout, the next windows in stacking order on its output fill the others. The layout is one of these catalogue ids
// (the Arrange rows and their Alt alternates, TL25, TL26); "" when anything is invalid (callers must not dispatch it).
var arrangeLayouts = ["left-right", "right-left", "top-bottom", "bottom-top", "quarters", "left-quarters", "right-quarters", "top-quarters", "bottom-quarters"];

function arrangeCall(address, layout) {
    const hex = normalizeAddress(address);
    if (hex === "" || typeof layout !== "string" || arrangeLayouts.indexOf(layout) < 0)
        return "";
    // Only validated pieces: the JSON holds no quote or backslash to escape for Lua but the JSON's own quotes.
    const json = JSON.stringify({layout: layout, windows: ["0x" + hex]});
    return guardedPluginCall("arrange", ["\"" + json.replace(/"/g, "\\\"") + "\""]);
}

// The layouts of the catalogue (the tiling.layout* tokens, compositor core catalogue()): a zone of the Layouts section or a
// pick of the suggestions names one (TL27, TL28).
var catalogueLayouts = arrangeLayouts.concat(["wide-left", "thirds", "wide-center", "four-columns", "stacked-thirds"]);

// hl.plugin.grassfield.arrange(json) with a zone (capability "tiling-layouts", TL27, TL28): the window alone into zone `zone`
// of `layout` (a zone of the Layouts section), or, with `withAddress`, into that zone of the layout of the window
// `withAddress` (a pick of the suggestions: it joins that window's group). "" when anything is invalid.
function zoneCall(address, layout, zone, withAddress) {
    const hex = normalizeAddress(address);
    const other = withAddress === undefined || withAddress === "" ? null : normalizeAddress(withAddress);
    if (hex === "" || other === "" || other === hex || typeof layout !== "string" || catalogueLayouts.indexOf(layout) < 0 || !Number.isInteger(zone) || zone < 0 || zone > 3)
        return "";
    const request = {layout: layout, windows: ["0x" + hex], zone: zone};
    if (other !== null)
        request.with = "0x" + other;
    // Only validated pieces: the JSON holds no quote or backslash to escape for Lua but the JSON's own quotes.
    return guardedPluginCall("arrange", ["\"" + JSON.stringify(request).replace(/"/g, "\\\"") + "\""]);
}

// hl.plugin.grassfield.group_front(address) (capability "tiling-groups", TL29): the window's tile group comes forward (sent
// after the window's activation or restore: Compositor.groupForward). "" when the address is invalid.
function groupFrontCall(address) {
    const hex = normalizeAddress(address);
    return hex === "" ? "" : guardedPluginCall("group_front", ["\"0x" + hex + "\""]);
}

// hl.plugin.grassfield.split(address, side) (capability "tiling-split", docs/specs/tiling.md TL33): Full Screen › Left or Right
// of Screen, the window in that half of a new Split View Desktop. "" when the address or the side ("left" | "right") is invalid.
function splitCall(address, side) {
    const hex = normalizeAddress(address);
    if (hex === "" || (side !== "left" && side !== "right"))
        return "";
    return guardedPluginCall("split", ["\"0x" + hex + "\"", "\"" + side + "\""]);
}

// hl.plugin.grassfield.unsplit(address[, how]) (capability "tiling-split", TL33): a window of a Split View Desktop leaves it.
// `how` (step 6d, capability "tiling-split-rows", ADR-0036 D71): "" or "desktop" Exit Full Screen / Move Window to Desktop (no
// second argument, as before), "fullscreen" Make Window Full Screen, "replace" Replace Tiled Window. "" when the address or
// `how` is invalid.
function unsplitCall(address, how) {
    const hex = normalizeAddress(address);
    const way = how === undefined || how === "desktop" ? "" : how;
    if (hex === "" || (way !== "" && way !== "fullscreen" && way !== "replace"))
        return "";
    return guardedPluginCall("unsplit", way === "" ? ["\"0x" + hex + "\""] : ["\"0x" + hex + "\"", "\"" + way + "\""]);
}

// hl.plugin.grassfield.tile_popover(address) (capability "tile-hover", TL26): the plugin posts the tile-hover "open" event of
// that window, with its zoom light, and the shell opens the tiling popover with the keyboard. "" when the address is invalid.
function tilePopoverCall(address) {
    const hex = normalizeAddress(address);
    return hex === "" ? "" : guardedPluginCall("tile_popover", ["\"0x" + hex + "\""]);
}

// hl.plugin.grassfield.move_to(address, output) (capability "tile-hover", TL23, TL26): the window onto that output, in the
// same tile when it is tiled. The output name is 1 to 64 characters of [A-Za-z0-9._-] (the plugin's own rule); "" otherwise.
function moveToCall(address, output) {
    const hex = normalizeAddress(address);
    if (hex === "" || typeof output !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(output))
        return "";
    return guardedPluginCall("move_to", ["\"0x" + hex + "\"", "\"" + output + "\""]);
}

// hl.plugin.grassfield.cursor_refresh() (gfc/1 capability "cursor-refresh"): the plugin redraws the cursor with the
// theme and size Hyprland holds now. The plugin registers the capability name with an underscore (a Lua identifier) and
// the call takes no argument (compositor FR39-FR40, measured by tests/compositor/cursor_refresh.sh); guarded, so a
// plugin without it makes this a no-op.
function cursorRefreshCall() {
    return guardedPluginCall("cursor_refresh", []);
}

// hl.plugin.grassfield.appmenu(address): the plugin re-posts that window's gfc/1 appmenu event (FR22). Used after a
// shell restart for the windows that already exist. "" when the address is invalid.
function appmenuCall(address) {
    const hex = normalizeAddress(address);
    return hex === "" ? "" : guardedPluginCall("appmenu", ["\"0x" + hex + "\""]);
}

// hl.plugin.grassfield.overview(json) (gfc/1, docs/specs/overview.md "Shell contract" 3). `request`:
// {on: bool, durationMs: integer 0..2000, curve?: 4 numbers, windows?: [{address, x, y, w, h}]} (layout coordinates).
// The JSON is built from validated pieces only (hex address, finite numbers rounded to integers, w and h >= 1, at
// most 64 windows, unique addresses) and quoted as a Lua string; "" when anything is invalid (callers must not
// dispatch it). A rect outside the monitor or an ineligible window is the plugin's business (ignored there).
function overviewCall(request) {
    if (!request || typeof request.on !== "boolean")
        return "";
    const duration = Number(request.durationMs);
    if (!Number.isFinite(duration) || duration < 0 || duration > 2000)
        return "";
    const body = {on: request.on, durationMs: Math.round(duration)};
    const curve = request.curve;
    if (curve !== undefined && curve !== null) {
        if (!Array.isArray(curve) || curve.length !== 4)
            return "";
        const c = curve.map(Number);
        if (!c.every(n => Number.isFinite(n)) || c[0] < 0 || c[0] > 1 || c[2] < 0 || c[2] > 1 || c[1] < -1 || c[1] > 2 || c[3] < -1 || c[3] > 2)
            return "";
        body.curve = c.map(n => Math.round(n * 1000) / 1000);
    }
    if (request.on) {
        const list = request.windows;
        if (!Array.isArray(list) || list.length === 0 || list.length > 64)
            return "";
        const seen = {};
        body.windows = [];
        for (const w of list) {
            const hex = w ? normalizeAddress(w.address) : "";
            const r = finiteRect(w);
            if (hex === "" || !r || seen[hex])
                return "";
            seen[hex] = true;
            body.windows.push({address: "0x" + hex, x: Math.round(r.x), y: Math.round(r.y), w: Math.max(1, Math.round(r.w)), h: Math.max(1, Math.round(r.h))});
        }
    }
    const json = JSON.stringify(body);
    if (json.length > 16384)
        return "";
    // The JSON text as a Lua string literal: only backslash and double quote need escaping (no control characters).
    const lua = "\"" + json.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\"";
    return guardedPluginCall("overview", [lua]);
}

// hl.plugin.grassfield.overview_focus(json) (gfc/1 capability "overview-focus", docs/specs/overview.md "Close focus"):
// `target` is {kind: "window", address} | {kind: "workspace", workspace} | {kind: "remembered", address, workspace?} |
// {kind: "none"}; `id` (optional) 0..2^32-1 is echoed in the plugin's events. Built from validated pieces (hex address,
// positive integer Desktop ids only: never a special workspace) and quoted as a Lua string; "" when anything is invalid
// (callers must not dispatch it). A field the target does not use is never produced.
function overviewFocusCall(target, id) {
    if (!target)
        return "";
    const body = {};
    switch (target.kind) {
    case "window":
    case "remembered": {
        const hex = normalizeAddress(target.address);
        if (hex === "")
            return "";
        body.target = target.kind;
        body.address = "0x" + hex;
        if (target.kind === "remembered" && target.workspace !== undefined && target.workspace !== null) {
            if (!/^[1-9][0-9]{0,8}$/.test(String(target.workspace)))
                return "";
            body.workspace = Number(target.workspace);
        }
        break;
    }
    case "workspace":
        if (!/^[1-9][0-9]{0,8}$/.test(String(target.workspace)))
            return "";
        body.target = "workspace";
        body.workspace = Number(target.workspace);
        break;
    case "none":
        body.target = "none";
        break;
    default:
        return "";
    }
    if (id !== undefined && id !== null) {
        const n = Number(id);
        if (!Number.isInteger(n) || n < 0 || n > 4294967295)
            return "";
        body.id = n;
    }
    const json = JSON.stringify(body);
    if (json.length > 512)
        return "";
    return guardedPluginCall("overview_focus", ["\"" + json.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\""]);
}

// Reduce Motion for the animations Hyprland itself runs (A11Y-06; the shell cannot draw them): window opening and closing
// (pop-in) and the Spaces slide become quick crossfades of at most 100 ms (speed 1 = 100 ms), window moves stop animating.
// `normal` mirrors config/hypr/grassfield/looknfeel.lua (tests/unit/tst_minimized.qml checks the two agree); the call is a
// Lua function sent through the same guarded channel as the plugin verbs, with `pcall` around each leaf so that a Hyprland
// without the call (or a changed config API) does nothing. Nothing in it comes from outside.
var motionLeaves = {
    normal: [
        {leaf: "windowsIn", speed: 2, bezier: "gfDecelerate", style: "popin 94%"},
        {leaf: "windowsOut", speed: 1.2, bezier: "gfAccelerate", style: "popin 96%"},
        {leaf: "windowsMove", speed: 3, bezier: "gfDecelerate"},
        {leaf: "zoomFactor", speed: 3, bezier: "gfDecelerate"},
        {leaf: "workspaces", speed: 4, bezier: "gfDecelerate", style: "slide"}
    ],
    reduced: [
        {leaf: "windowsIn", speed: 1, bezier: "gfStandard", style: "popin 100%"},
        {leaf: "windowsOut", speed: 1, bezier: "gfStandard", style: "popin 100%"},
        {leaf: "windowsMove", speed: 1, bezier: "gfStandard", enabled: false},
        // Screen zoom (Settings > Accessibility > Zoom) jumps to its level instead of gliding.
        {leaf: "zoomFactor", speed: 1, bezier: "gfStandard", enabled: false},
        {leaf: "workspaces", speed: 1, bezier: "gfStandard", style: "fade"}
    ]
};

function motionCall(reduced) {
    const leaves = reduced ? motionLeaves.reduced : motionLeaves.normal;
    const calls = leaves.map(l => "pcall(hl.animation, { leaf = \"" + l.leaf + "\", enabled = " + (l.enabled === false ? "false" : "true")
        + ", speed = " + l.speed + ", bezier = \"" + l.bezier + "\"" + (l.style ? ", style = \"" + l.style + "\"" : "") + " })");
    return "function() " + calls.join("; ") + " end";
}

// Compositor blur size and passes (GF-125, docs/specs/ui.md "Material blur"): one value for every surface, chosen by the
// shell from the transparency. Core Hyprland config, no plugin needed. Captured from Hyprland 0.56.2 (nested,
// tests/compositor/blur_events.sh): the request socket answers a dispatch with "ok", or with "error: ...: unknown config key
// '...'" when hl.config does not know a key (also when the call is wrapped in pcall); Hyprland emits NO socket2 event for a
// push, and exactly one "configreloaded" for a config reload (the push that follows it emits none). blurAnswer() reads that
// answer. "" for anything but integers in range (callers must not dispatch it).
var blurLimits = {sizeMin: 1, sizeMax: 64, passesMin: 1, passesMax: 6};

function blurCall(size, passes) {
    const ok = (v, lo, hi) => typeof v === "number" && isFinite(v) && Math.floor(v) === v && v >= lo && v <= hi;
    if (!ok(size, blurLimits.sizeMin, blurLimits.sizeMax) || !ok(passes, blurLimits.passesMin, blurLimits.passesMax))
        return "";
    return "function() hl.config({ decoration = { blur = { size = " + size + ", passes = " + passes + " } } }) end";
}

// The session's ground (ADR-0040 ID-2): the compositor's background colour, sent as one Lua call like the blur. "" for anything
// but "#rrggbb" (the value is interpolated into the Lua expression).
function groundCall(hex) {
    if (typeof hex !== "string" || !/^#[0-9a-fA-F]{6}$/.test(hex))
        return "";
    return "function() hl.config({ misc = { background_color = \"rgba(" + hex.substring(1).toLowerCase() + "ff)\" } }) end";
}

// The window edge of an appearance (ADR-0039 step 6, C-4): Hyprland's border colours, the active and an inactive window's,
// as one Lua call for the request socket. colour "#rrggbb", alphas from 0 to 1; "" when one is not.
function edgeCall(colour, active, inactive) {
    const alpha = a => typeof a === "number" && isFinite(a) && a >= 0 && a <= 1;
    if (typeof colour !== "string" || !/^#[0-9A-Fa-f]{6}$/.test(colour) || !alpha(active) || !alpha(inactive))
        return "";
    const rgba = a => "rgba(" + colour.slice(1).toLowerCase() + ("0" + Math.round(a * 255).toString(16)).slice(-2) + ")";
    return "function() hl.config({ general = { col = { active_border = \"" + rgba(active) + "\", inactive_border = \"" + rgba(inactive) + "\" } } }) end";
}

// Settings the plugin accepts through hl.plugin.grassfield.config(key, value): key -> allowed values.
// minimizeEffect: Settings dock.minimizeEffect (funnel | shrink), or "fade" while Reduce Motion is on (feature
// "minimize-effect"; older plugins reject the key, so the shell sends it only when the feature is advertised).
// The tiling keys: tilingSwitches below (docs/specs/tiling.md TL32). titlebarDoubleClick "fill": doubleClickAction.
// appearance: the appearance the shell shows (feature "appearance"): the compositor-drawn titlebars follow it (audit UX-06).
// stagesEnabled: Settings windows.stages (feature "stages-available"; ADR-0013, owner decision D-4).
var pluginConfig = {
    titlebarDoubleClick: ["zoom", "minimize", "fill", "none"],
    minimizeEffect: ["funnel", "shrink", "fade"],
    tilingEdges: ["true", "false"],
    tilingMenuBar: ["true", "false"],
    tilingOptionDrag: ["true", "false"],
    tilingMargins: ["true", "false"],
    tilingLayouts: ["true", "false"],
    tilingSuggestions: ["true", "false"],
    appearance: ["dark", "light"],
    stagesEnabled: ["true", "false"]
};

// hl.plugin.grassfield.stages(json) (gfc/1 capability "stages", docs/specs/stages.md "Shell contract" 3 and 5), for the
// Stages strip: `request` is the operation object ({op: "on", durationMs, curve?, strips: [...]}, {op: "off", durationMs},
// {op: "activate" | "merge", stage}, {op: "move", address, stage}). Only the op is checked here (one of these five) and
// the size (at most 8 KiB, the plugin's limit); the plugin validates every field strictly (untrusted input there). The JSON
// is quoted as a Lua string (JSON.stringify escapes control characters; backslash and double quote are escaped for Lua).
// "" when anything is invalid (callers must not dispatch it).
var stagesOps = ["on", "off", "activate", "move", "merge"];

function stagesCall(request) {
    if (!request || typeof request !== "object" || Array.isArray(request) || stagesOps.indexOf(request.op) < 0)
        return "";
    let json = "";
    try {
        json = JSON.stringify(request);
    } catch (e) {
        return "";
    }
    if (typeof json !== "string" || json.length > 8192)
        return "";
    return guardedPluginCall("stages", ["\"" + json.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\""]);
}

// The switches of Desktop & Dock > Windows the plugin takes (docs/specs/tiling.md TL32), in the Settings order: the config
// key, the feature the plugin advertises when it accepts it, and the Settings property it carries. "Bring tile groups
// forward together" is the shell's alone (Compositor.groupForward, ADR-0036 D38).
var tilingSwitches = [
    {key: "tilingEdges", feature: "window-tiling", setting: "windowsTilingEdges"},
    {key: "tilingMenuBar", feature: "window-tiling", setting: "windowsTilingMenuBar"},
    {key: "tilingOptionDrag", feature: "window-tiling", setting: "windowsTilingOptionDrag"},
    {key: "tilingMargins", feature: "window-tiling", setting: "windowsTilingMargins"},
    {key: "tilingLayouts", feature: "tile-hover", setting: "windowsTilingLayouts"},
    {key: "tilingSuggestions", feature: "tiling-layouts", setting: "windowsTilingSuggestions"}
];

// The [key, value] pairs to push for `settings` (the Settings singleton, or any object with its windowsTiling* properties):
// each switch whose feature `has(feature)` says the plugin advertises, as "true" | "false".
function tilingConfigPairs(settings, has) {
    return tilingSwitches.filter(s => has(s.feature)).map(s => [s.key, settings[s.setting] === true ? "true" : "false"]);
}

// The double-click action the plugin is sent for the setting `action`: Fill needs the plugin's arrangements (feature
// "tiling-arrange"); without them the double-click zooms, the action's default (ADR-0036 D36).
function doubleClickAction(action, canArrange) {
    return action === "fill" && canArrange !== true ? "zoom" : action;
}

function configCall(key, value) {
    if (typeof key !== "string" || !Object.prototype.hasOwnProperty.call(pluginConfig, key))
        return "";
    if (typeof value !== "string" || pluginConfig[key].indexOf(value) < 0)
        return "";
    return guardedPluginCall("config", ["\"" + key + "\"", "\"" + value + "\""]);
}

// Validated lowercase hex of a Hyprland window address ("0x" prefix optional), "" if invalid.
function normalizeAddress(address) {
    const m = /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(String(address));
    return m ? m[1].toLowerCase() : "";
}

// Lua requests built from validated pieces only (untrusted data is never interpolated). ""
// means the input was rejected: callers must not dispatch it.

// Hyprland workspace specifier the shell uses: a positive integer id or "special:<name>".
// Arbitrary names (e.g. "undefined" from a missing value) are rejected.
function validWorkspace(workspace) {
    return /^(?:[1-9][0-9]{0,8}|special:[A-Za-z0-9_-]{1,64})$/.test(String(workspace));
}

// The Desktop a window restored WITHOUT the plugin goes to (owner decision D-1, the macOS model; audit GF-001): the one the
// display it was minimized from (`screen`, recorded at the minimize) shows now; else (no record, display gone) the focused
// Desktop. `monitors`: [{name, workspace}] with the id of the Desktop each display shows. "" when neither is valid. The
// plugin, when present, does this itself (and gives the frame back).
function restoreWorkspace(screen, monitors, focusedWorkspace) {
    if (typeof screen === "string" && screen !== "" && Array.isArray(monitors)) {
        const m = monitors.find(x => x && x.name === screen);
        if (m && /^[1-9][0-9]{0,8}$/.test(String(m.workspace)))
            return String(m.workspace);
    }
    return /^[1-9][0-9]{0,8}$/.test(String(focusedWorkspace)) ? String(focusedWorkspace) : "";
}

function moveRequest(address, workspace) {
    const hex = normalizeAddress(address);
    const ws = String(workspace);
    if (hex === "" || !validWorkspace(ws))
        return "";
    return "hl.dsp.window.move({ workspace = \"" + ws + "\", follow = false, window = \"address:0x" + hex + "\" })";
}

// Focus of a regular workspace by id (positive integer), "" if invalid.
function focusRequest(id) {
    const ws = String(id);
    if (!/^[1-9][0-9]{0,8}$/.test(ws))
        return "";
    return "hl.dsp.focus({ workspace = \"" + ws + "\" })";
}

// Focus of a window by address (keyboard included), "" if invalid. Unlike the protocol `activate`, this gives the keyboard
// back to a window Hyprland still counts as focused after a layer surface held the keyboard.
function focusWindowRequest(address) {
    const hex = normalizeAddress(address);
    if (hex === "")
        return "";
    return "hl.dsp.focus({ window = \"address:0x" + hex + "\" })";
}

// Fullscreen state change of a window; mode "maximized" is Zoom, "fullscreen" is full screen.
function fullscreenRequest(address, mode) {
    const hex = normalizeAddress(address);
    if (hex === "" || (mode !== "maximized" && mode !== "fullscreen"))
        return "";
    return "hl.dsp.window.fullscreen({ mode = \"" + mode + "\", window = \"address:0x" + hex + "\" })";
}

// {x, y, w, h} as finite numbers, or null.
function finiteRect(rect) {
    if (!rect)
        return null;
    const out = [rect.x, rect.y, rect.w, rect.h].map(Number);
    return out.every(n => Number.isFinite(n)) ? {x: out[0], y: out[1], w: out[2], h: out[3]} : null;
}

// Hyprland window data `fullscreen` field: 0 none, 1 maximized (Zoom), 2 fullscreen.
function isZoomed(data) {
    return !!data && data.fullscreen === 1;
}

// Hyprland window data of the window of Wayland app id `appClass` whose xdg-toplevel tag (its ADR-0015 role) is `tag`:
// Compositor.taggedToplevel, for Settings' About This Computer window (class org.grassfield.Settings, role "info").
function hasTag(data, appClass, tag) {
    return !!data && appClass !== "" && tag !== "" && data.class === appClass && data.xdgTag === tag;
}

function has(list, toplevel) {
    return list.some(r => r.toplevel === toplevel);
}

// New list with the record appended (a window is recorded once).
function add(list, record) {
    return has(list, record.toplevel) ? list : list.concat([record]);
}

function remove(list, toplevel) {
    return list.filter(r => r.toplevel !== toplevel);
}

// Drops records whose window no longer exists. `live` is an array of toplevel handles.
function prune(list, live) {
    return list.filter(r => live.indexOf(r.toplevel) >= 0);
}

// Windows of an app (case-insensitive app id) that are minimized.
function forApp(list, appId) {
    const wanted = String(appId).toLowerCase();
    return list.filter(r => String(r.appId).toLowerCase() === wanted);
}

// A minimize the shell recorded and asked for, checked once the request had time to land (audit SC-16): the plugin and the
// fallback move the window to special:minimized at once, and that move is seen (`lastWorkspace`: the latest movewindowv2
// workspace name per address) or read again (`placeOf(address)`: the workspace name of the window data read again, "" when
// unknown). A window seen or read on special:minimized was minimized; any other place, or none known, means the request was
// refused or dropped (a locked session, a window the plugin does not know): its record goes, so the Dock never keeps a tile for a
// window still on screen. The addresses whose record goes.
function unconfirmedDrops(addresses, lastWorkspace, placeOf, minimizedWorkspace) {
    const out = [];
    for (const address of addresses || []) {
        if (lastWorkspace && lastWorkspace.get(address) === minimizedWorkspace)
            continue;
        if (placeOf(address) === minimizedWorkspace)
            continue;
        out.push(address);
    }
    return out;
}

// Parses Hyprland's `movewindowv2` event data "<address>,<workspace id>,<workspace name>" (the
// name may itself contain commas): {address (validated hex), workspace (name)} or null.
function parseMoveWindowV2(data) {
    const text = String(data);
    const first = text.indexOf(",");
    const second = first < 0 ? -1 : text.indexOf(",", first + 1);
    if (second < 0)
        return null;
    const address = normalizeAddress(text.slice(0, first));
    const workspace = text.slice(second + 1);
    return address !== "" && workspace !== "" ? {address: address, workspace: workspace} : null;
}

// Parses a `grassfield` raw event payload; returns the validated address of a minimize-request, or "".
function minimizeRequestAddress(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return "";
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "minimize-request" || typeof msg.address !== "string")
        return "";
    return normalizeAddress(msg.address);
}

// The answer of the request socket to the blur push: "ok", "rejected" (an error answer: the shell stops pushing, the config's
// own 18 / 3 stays) or "unknown" (nothing readable).
function blurAnswer(reply) {
    if (typeof reply !== "string")
        return "unknown";
    const text = reply.trim();
    if (text === "ok")
        return "ok";
    return /^error\b/i.test(text) ? "rejected" : "unknown";
}
