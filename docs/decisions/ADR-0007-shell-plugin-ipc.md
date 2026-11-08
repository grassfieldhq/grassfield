# ADR-0007: Shell ↔ plugin IPC (`gfc/1`)
Status: Accepted (owner delegation D-5, 2026-10-23; status before acceptance: Proposed (S2 evidence recorded; applied provisionally)) · Date: 2026-10-17 · Decider: owner

## Context
grassfield-shell (Quickshell) must drive `grassfield-compositor` (minimize with target rectangles,
overview transforms, appmenu registrations, capability detection) and receive its events. Constraints:
§5.4 never poll `hyprctl`, never leave IPC sockets open; the shell must work without the plugin (§5.6).
Quickshell 0.3.1 `Quickshell.Hyprland` exposes `Hyprland.dispatch(request)` (Hyprland request socket) and
`Hyprland.rawEvent(event)` (socket2 event stream it already holds open), and a `usingLua` property.
Hyprland 0.56.2 plugin API offers `addDispatcherV2`, `registerHyprCtlCommand`, `addLuaFunction`,
`addEvent` (Lua `hl.on`), and the socket2 event manager.

## Options
1. **Hyprland's own IPC**: shell → plugin through plugin dispatchers (`grassfield:<verb> <args>`);
   plugin → shell through socket2 events (`grassfield>>{json}`); diagnostics via `hyprctl grassfield`.
   Pros: no new socket, reuses connections Quickshell already manages, works under the nested guard rails.
   Cons: dispatcher arguments are a single string; events are broadcast to every socket2 client (no secrets).
2. Plugin-owned Unix socket with JSON lines. Pros: request/response, private. Cons: a second socket to
   secure and version; blocking risks on the compositor thread; more code.
3. D-Bus service inside the compositor process. Cons: event-loop integration in Hyprland, heavier.

## Decision (proposed)
Option 1 adapted to the Lua config, versioned `gfc/1`:
- **Shell → plugin: Lua functions**, registered by the plugin with `HyprlandAPI::addLuaFunction(handle,
  "grassfield", "<verb>", fn)` and reachable as `hl.plugin.grassfield.<verb>(...)`. The shell's platform layer
  sends them through `Hyprland.dispatch(<Lua function body>)` (Quickshell wraps requests as
  `return hl.dispatch(<request>)` when `usingLua` is true), guarded by
  `local p = hl.plugin and hl.plugin.grassfield; if p and p.<verb> then ... end` so a missing plugin is a no-op.
  Each function returns `hl.dsp.no_op()` so the wrapping dispatch does not error.
- **Plugin → shell: socket2 events** `grassfield>>{json}` (`g_pEventManager->postEvent`), received by
  `Hyprland.rawEvent` in `shell/platform/`.
- **Diagnostics**: `hyprctl grassfield` (read-only JSON: the capabilities event plus a trailing `"version"` member, the plugin's product version; the event itself is unchanged).
- Handshake: the shell calls `hl.plugin.grassfield.hello()` at startup; the plugin answers (and emits at load)
  `{"v":"gfc/1","type":"capabilities","features":[...]}`. No reply within 1500 ms → degraded mode (§5.6).
- Verbs implemented (2026-10-17): `hello()`, `minimize(address, x, y, w, h)`, `restore(address, x, y, w, h)`
  (target rect = the Dock tile in layout coordinates), `config(key, value)` (allowlist: `titlebarDoubleClick` ∈
  zoom|minimize|none), `appmenu(address)` (re-posts that window's registration), `overview(json)` (2026-10-18,
  additive: one JSON string `{"on":bool,"durationMs":int,"curve":[x1,y1,x2,y2]?,"windows":[{"address","x","y","w","h"}…]}`
  in layout coordinates, at most 64 windows and 16 KiB, validated strictly by the plugin; live window transforms for
  Mission Control v2, contract in `docs/specs/overview.md` "Shell contract"), `stages(json)` (2026-10-18, additive, only
  while the flag `config("stagesEnabled", "true")` is on: ops `on` / `off` / `activate` / `move` / `merge`, at most 8 KiB,
  validated strictly; contract in `docs/specs/stages.md`, ADR-0013). `config` allowlist: `titlebarDoubleClick` ∈
  zoom|minimize|none, `stagesEnabled` ∈ true|false (off at every load). Planned: `theme(json)`. Events:
  `capabilities` (features: `decorations`, `minimize`, `config`, `appmenu`, `overview`, `desktop-focus`, `desktop-focus-v2`,
  `stages-available`, `stages`), `stages` `{on, monitors:[{monitor, workspace, active, hidden, overlap, stages:[{id, slot,
  windows:[{address, x?, y?, w?, h?}]}]}], reason?}` (coalesced state), `minimize-request`,
  `minimized`, `restored`, `appmenu` `{address, service, path, pid}` (additive field `pid` = the Wayland client's pid
  from `wl_client_get_credentials`; the menu bridge checks it against `GetConnectionUnixProcessID(service)` to stop one
  app pointing its window at another app's menu; without a registration, the mapped Wayland window's client pid, 0 for
  X11/XWayland windows and clears: the bridge serves such a window a menu its process registered with
  `com.canonical.AppMenu.Registrar`, ADR-0008 amendment 2026-10-25), `overview` `{state: opening|open|closing|closed, windows, reason?}`
  (`reason`: `invalid` / `no-windows` / `no-chrome` for a refused request, which changes nothing; `unavailable` at unload;
  `interrupted` when the overview ended without the shell's request; `fullscreen` when a window went full screen while
  shown and its workspace's windows left the overview, the state otherwise unchanged).
- Feature `desktop-focus` (2026-10-18, additive, no verb): the plugin enforces click-to-focus for the shell's desktop
  surface (namespace `grassfield-desktop-icons`) on pointer presses (ADR-0012 amendment); contract in
  `docs/specs/desktop.md` "Compositor focus policy". Advertised only when its listeners registered.
- Feature `desktop-focus-v2` (2026-10-18, additive, always together with `desktop-focus`): the same policy with the press
  target taken from under the cursor when the pointer focus is stale (a click without motion after a popup closed), late
  desktop grants dropped on any other focus change, and the window grant through Hyprland's focus rules only. The shell
  enables its file-changing desktop keys only with `desktop-focus-v2` (shell main 23caeab).
- Overview chrome rule (2026-10-18, relaxed): `overview` `on:true` needs a mapped `grassfield-overview` surface on every
  target monitor and the keyboard on one of them with Exclusive interactivity (the focused output's); the others may be
  keyboard None (`no-chrome` otherwise). Earlier every chrome had to be Exclusive, which made Hyprland refuse to give the
  keyboard back after the close on two outputs.
- Feature `stages-available` / `stages` (2026-10-18, additive, ADR-0013): `stages-available` when the Stages listeners
  and verb registered (the shell pushes its setting `windows.stages` as the flag, see below); `stages` only while the flag
  is on.
- Withdrawal at unload (2026-10-18, additive): `PLUGIN_EXIT` posts `{"v":"gfc/1","type":"capabilities","features":[]}`
  after removing every hook, so the shell drops each feature and returns to its fallbacks (desktop focus workarounds,
  minimize parking, T0 menus, thumbnails). The shell must treat every capabilities event as the current truth.
- Delivery (2026-10-17, after the global menus review: an unbounded `appmenu` stream overflowed the shell's socket2
  connection and Hyprland dropped it): every plugin → shell event goes through `compositor/src/core/EventThrottle`,
  keyed by window (`minimized`/`restored` share one key, as do an appmenu clear and set), latest value wins, at most
  one post per key per 100 ms with an event-loop timer posting the final state after a burst; global cap 32 events
  burst, then 50/s; `overview` and `stages` have one key each (the latest state wins). Events are coalesced, never required one by one: the shell rebuilds minimize state from
  `movewindowv2` and can ask for a window's registration again with `appmenu(address)`. Client-triggerable log lines
  share one budget, titlebar pointer actions included.
- Feature `window-tiling` and verb `tile(address, place)` (2026-10-22, additive, docs/specs/compositor.md FR47-FR50):
  `place` ∈ left|right|top|bottom|top-left|top-right|bottom-left|bottom-right|fill|center|previous (fixed list, the
  address compared with the live windows); the window is placed in the free area of the output under its middle.
  `config` allowlist gains `tilingEdges`, `tilingMenuBar`, `tilingMargins` ∈ true|false (all true at load). The feature
  is advertised only when the `tile` and `config` verbs registered. (Other verbs added since 2026-10-18 and not listed
  above: `cursor_refresh()`, `overview_focus(json)`, `config("minimizeEffect", …)`; see their specs.)
- Feature `appearance` (2026-10-23, additive, audit UX-06, docs/specs/compositor.md FR53): `config` allowlist gains
  `appearance` ∈ dark|light (dark at load); the compositor-drawn titlebars and the tiling preview follow it. Advertised
  with `config`; the shell sends the key only when it sees the feature.
- Stages from Settings (2026-10-23, additive, owner decision D-4, audit ARCH-05): the shell's verb allowlist gains
  `stages`; the shell persists the setting `windows.stages` (off by default) and pushes `config("stagesEnabled", …)` when
  that setting changes and when `stages-available` appears (every plugin load starts with the flag off), not after every
  capabilities event (the plugin re-posts its capabilities when the flag changes; a push then would undo a flag set by
  another caller). `Compositor.stages(request)` sends one operation while `stages` is advertised. Until the shell's strip
  exists nothing sends `op:on`, so the flag alone changes nothing on screen (docs/specs/stages.md "Shell contract" item 1).
- Window tiling, step 1 (2026-10-27, additive, ADR-0036, docs/specs/tiling.md TL1-TL15): `tile` places gain
  left-third|middle-third|right-third|left-two-thirds|right-two-thirds; verb `arrange(json)`
  `{"layout":"<catalogue id>","windows":["0x…",…],"fill":bool?,"zone":int?,"output":"<name>"?}` (at most 4 KiB, 4
  distinct windows, at most the layout's zone count; `zone` 0-based with exactly one window and `fill` false or absent; ids of the
  token catalogue `tiling.layout*`), windows[i] takes zone i and, with `fill` (default true), the next tileable windows in
  stacking order on that output and Desktop (and active stage) fill the rest; the windows placed form a tile group.
  Event `tiling`, a change notice `{"v":"gfc/1","type":"tiling","gen":N}` plus `reason` (at most 79 bytes: a 20-digit
  `gen` and `unavailable`); the state is the reply of `hyprctl grassfield-tiling` (per output: work area, class, grid
  step, tiled windows with state, place or layout and zone, group, box). The reply moves no window (it only drops the
  records of closed windows and of windows moved by other means). Feature `tiling-arrange`, advertised with `window-tiling` only when the verb, the command
  and the tiling listeners registered. `config("titlebarDoubleClick", "fill")` joins the allowlist (the shell sends it in
  step 5). A refused `arrange` posts the notice with `reason:"invalid"` and changes nothing; `tile` and `arrange` are
  refused while the session is locked (`reason:"locked"`, TL34).
- Window tiling, step 2 (2026-10-27, additive, ADR-0036, docs/specs/tiling.md TL16-TL20): no new event, verb or feature.
  The `config` allowlist gains `tilingOptionDrag` ∈ true|false (true at load: with Alt held a drag tiles into the nearest
  half, quarter or fill, TL18). Each window of the `hyprctl grassfield-tiling` reply gains `sides`: the sides a double-click
  on its resize border extended ("top", "bottom", "left", "right" joined by "-" in that order, e.g. "top-left"; "" for a
  place or a layout zone, TL20). Drags by Hyprland's own move (an app's toolbar, Super+drag) post the same notices as the
  plugin's titlebar drag (`moved` when a tiled window leaves its tile, `placed` at a release that tiles).
- Window tiling, step 3 (2026-10-28, additive, ADR-0036, docs/specs/tiling.md TL22-TL26): event `tile-hover`
  `{"v":"gfc/1","type":"tile-hover","address":"<hex>","state":"enter|leave|open"}`; `enter` (the pointer rested
  `tiling.hoverDelay` on a window's zoom light, no button held) and `open` (verb `tile_popover`) add the light's rect
  `x y w h` (global layout coordinates, one decimal) and `tileable` (the window can be tiled now: the popover greys its
  tiles otherwise); `leave` follows an `enter` when the pointer leaves the light or a button is pressed. One zoom light at
  a time (throttle channel `TileHover`, the latest state wins). Verb `tile_popover(address)` posts `open` for that window
  (the zoom light of its titlebar, or of a Grassfield app's own chrome, else the top-left corner of its frame). Verb
  `move_to(address, output)` moves a window onto another output: a tiled one into the same place, layout zone or extended
  sides there, any other to the same relative place with its size (capped at that output's work area); it takes that
  output's Desktop. A refused `move_to` posts the `tiling` notice with `reason:"invalid"` (unknown or same output, a window
  that cannot move) or `reason:"locked"`; a move posts `placed` (tiled) or `forgotten` (a record ended). Feature
  `tile-hover`, advertised with `window-tiling` only when both verbs registered.
- Window tiling, step 4a (2026-10-28, additive, ADR-0036, docs/specs/tiling.md TL27-TL28): `arrange` takes `"with":"0x<hex>"`
  together with `"zone"` and one window: a pick of the suggestions. `with` must be tiled in that layout on the output's
  current Desktop and the zone must not be held by it or by a member of its group in that layout; the window joins its
  group (a new one when it had none). A window minimized by the plugin from that output may be picked: it is restored
  without the Dock animation, then placed. The `hyprctl grassfield-tiling` reply gains `suggestion`, `null` or
  `{"gen":N,"address":"<hex>","layout":"<id>","output":"<name>","zones":[{"zone":i,"x":…,"y":…,"w":…,"h":…}],
  "windows":["<hex>",…]}`: after an `arrange` that left zones of its layout empty, the empty zones in zone order with
  their frames in the work area, and the windows that can fill them (the tileable windows of that output's Desktop in the
  active stage, top first, then the windows minimized from that output, the latest first; at most 12; never one already
  in that layout). It is published while the tile records are still those of `gen` (the generation of the `placed`
  notice that announced it): any later change ends it. Feature `tiling-layouts`, advertised together with
  `tiling-arrange`.
- Window tiling, step 4b (2026-10-28, additive, ADR-0036, docs/specs/tiling.md TL29): verb `group_front(address)`: the
  members of the window's tile group on screen on its Desktop (Tiled or being resized; not minimized, full screen, zoomed
  or hidden) come forward in their stacking order, above every other window, then the window itself when it is on screen,
  whatever its state (zoomed or full screen included; integrator review of cd74af2); the shell sends it after it
  activates or restores the window (a window brought forward from the Dock, its menu, the menu bar's Window menu, the app
  switcher or the Overview), only for a window in a group, so the window ends in front whichever of the two reaches the
  compositor first (a window on a special workspace is not raised: its restore raises it). It
  changes no tile record and posts no notice; a window without a group changes nothing. Refused while the session is
  locked (`tiling` notice `reason:"locked"`) and for an unknown window (`reason:"invalid"`). The groups themselves are the
  `group` of each window in the `hyprctl grassfield-tiling` reply (step 1). Feature `tiling-groups`, advertised with
  `tiling-arrange` when the verb registered.
- Window tiling, step 4c (2026-10-28, additive, ADR-0036, docs/specs/tiling.md TL30): feature `tiling-shared-edge`,
  advertised with `tiling-arrange`: the plugin's own drag of a shared edge's handle between windows of a tile group. No
  verb and no event are added: the drag is the plugin's from the press to the release (both cancelled on the bus, as the
  revealed titlebar's, ADR-0015 P6), the windows along the edge are `Resizing` meanwhile, and its end posts the `tiling`
  notice `reason:"resized"` once. Nothing of it while the session is locked.
- Window tiling, step 5 (2026-10-29, additive, ADR-0036 D36-D38, docs/specs/tiling.md TL32): no new event, verb or
  feature. The `config` allowlist gains `tilingLayouts` ∈ true|false (true at load; false: the hover tracker posts no
  `tile-hover` `enter`, `tile_popover` still posts `open`; the shell sends it with `tile-hover`) and `tilingSuggestions` ∈
  true|false (true at load; false: an `arrange` keeps no suggestion, the pending one is dropped, and the `hyprctl
  grassfield-tiling` reply has `"suggestion":null`; sent with `tiling-layouts`). A plugin built before step 5 rejects both
  keys (a WARN line for each, two per push); the shell's own gates keep the behaviour right (ADR-0036 D39). The shell now sends `tilingOptionDrag` (with `window-tiling`) and
  `titlebarDoubleClick` = `fill` (only with `tiling-arrange`, `zoom` otherwise). "Bring tile groups forward together" adds
  no key: the plugin raises a group only on `group_front`.
- Window tiling, step 6a (2026-10-29, additive, ADR-0036 D40-D47, docs/specs/tiling.md TL33): verbs `split(address, side)`
  and `unsplit(address)`, feature `tiling-split` (advertised with `tiling-arrange` when both registered). `split` (Full
  Screen › Left or Right of Screen, `side` ∈ left|right) makes a Split View Desktop: a new Desktop with the next free id on
  the window's output, shown, the window in that half of the whole output (the menu bar, the Dock and the Stages strip are
  not reserved there; one separator of the tiling margin between the halves), tiled in the `left-right` layout; the
  `hyprctl grassfield-tiling` reply's `suggestion` then offers the other half with the windows of the Desktop it came from
  (always, whatever `tilingSuggestions` says); a pick is an `arrange` with `zone` and `with` as in step 4a and joins the
  window's tile group. No suggestion, or a window left alone once the other left, and it fills the Desktop. `unsplit`
  (a Split View window's Exit Full Screen) sends that window back to the Desktop it came from at its box from before,
  shown; the other fills the Split View Desktop alone; one left empty ends, and goes back to the Desktop it came from when
  it was shown. Refused while the session is locked (`tiling` notice `reason:"locked"`) and for an unknown window, a
  window that cannot be tiled now, one not on the Desktop its output shows or already on a Split View Desktop, a side
  other than left or right, a window of no Split View Desktop (`unsplit`) or while the Stages strip shows on that output
  (`reason:"invalid"`). The reply gains `"splits":[{"workspace":N,"output":"<name>","home":N,"windows":["<hex>",…],
  "waiting":bool}]` (always present, empty without a Split View Desktop): its members (the window it was made for and the
  one picked, whatever their state; another window on that Desktop is none) and whether its one member still waits for
  its second window. The shell lists each right after the Desktop it came from, unnumbered, hides the menu bar and the Dock
  on it, sends `unsplit` for the Exit Full Screen of a member, and `tile(address, "fill")` for a member still waiting once
  its picker is no longer pending (dismissed, refused, timed out). `tile` (except that Fill of a lone member) and
  `arrange` refuse a member (`reason:"invalid"`), and `tile(…, "previous")` does nothing for one: its Desktop places it
  (integrator review of c7a6b6e). The `tile-hover` event's `enter` and `open` add `splittable` (the window can be tiled
  now and fits either half of its output's Split View Desktop, its minimum size with its titlebar band: the popover greys
  Left and Right of Screen otherwise); `split`, and a pick into the other half of a Split View Desktop, refuse a window
  that does not fit its half (`reason:"invalid"`), and the suggestion of that half offers only windows that fit
  (integrator nested pass of 1ee992e, MAJOR C; ADR-0036 D57). The reply gains `"unfit":["<hex>",…]` (always present): the
  windows that can be tiled now and do not fit half of their output; the shell reads it again when the Window menu opens
  and greys its Full Screen Tile for those (integrator PASS on 8316ed2, for later).
- Window tiling, step 6c (2026-10-30, additive, ADR-0036 D64-D68, docs/specs/tiling.md TL33): event
  `{"type":"titlebar-reveal","output":"<name>","revealed":bool}`: the titlebar the plugin draws over a full-screen window
  (ADR-0015 P6) was revealed at the top edge of that output, or went away (the pointer left it, the window left full
  screen or closed, the plugin unloads); posted on each change of the set of outputs with a revealed titlebar, coalesced
  per output (the latest wins). The shell's menu bar on that output then stays in view while it is revealed and leaves with
  it (macOS: the menu bar and the toolbar come and go together). No feature and no verb: an older plugin never sends it
  and the menu bar keeps its own auto-hide; the shell forgets every output when the plugin goes away. Nothing is
  revealed while the session is locked (`revealable()`), so no `true` is posted then. No new verb or reply field:
  the Split View, the green light under an open popover (the shell runs `unsplit` or its own full-screen and Zoom
  requests) and the gathering of windows left off every output after an unplug (the plugin's own move) use what exists.
- Window tiling, D57's model for every place and arrangement (2026-10-30, additive, ADR-0036 D69; capture defect: Quarters
  at 1440 x 900 with a window 420 px tall at least came out with shifted rows). The `tile-hover` event's `enter` and `open`
  add `"unfitZones":["x,y,w,h",…]` (always present, `[]` when the window fits everything): the zones of the places and of
  the layout catalogue, by their twelfths as the shell's glyph tokens hold them, that the window's minimum (titlebar band
  included) does not fit on its output's Desktop; at most every offered zone, under the 1024-byte cut. The reply gains
  `"unfitZones":[{"address":"<hex>","zones":["x,y,w,h",…]},…]` (always present): the same for each window that can be tiled
  now and does not fit some zone (the Window menu reads it again when it opens, as `unfit`). `tile` refuses a place whose
  zone (or TL7 frame beside a neighbour) the window does not fit, and `arrange` a given window that does not fit its zone
  (`reason:"invalid"`, nothing moves); the fill of an arrangement gives each remaining zone the topmost window that fits it,
  and a zone no window fits stays empty; the suggestion offers only windows that fit its zone; a drag shows no preview over a
  place the window does not fit. Fill and Center are always offered. The shell greys the places, arrangements and Layouts
  zones whose zone is listed (the item's zone: a place's, an arrangement's first, a Layouts zone itself).
  The review of D69 (MINOR 1): a half beside a tiled neighbour is placed on the rest of the area beside it (TL7), narrower
  than its zone, so the places are listed apart: the event's `enter` and `open` add `"unfitPlaces":["<place>",…]` (always
  present; the core place names, never fill or center) and each reply object gains `"places":[…]`, each place checked on the
  frame `tile` applies. The shell greys a place by `unfitPlaces` and an arrangement or a Layouts zone by `unfitZones`.
- The Full Screen and Zoom keys (2026-10-30, additive, ADR-0040 step 1b's review): verb `window_size(mode)`, mode
  `"fullscreen"` or `"maximized"` (strict). It returns Hyprland's own `hl.dsp.window.fullscreen({ mode = mode })`, or
  `hl.dsp.no_op()` when the focused window is of fixed size (minimum = maximum, the reply's `fixed`) and not in that mode:
  the Window menu greys Zoom and Enter Full Screen for such a window, and Unzoom and Exit Full Screen still act.
  `config/hypr/grassfield/bindings.lua` calls it at each press of Super+Ctrl+F and Super+Alt+F and dispatches the result;
  without the verb (no plugin, an older one), when it fails or returns nothing, Hyprland's dispatcher as before (C2). Not a
  shell verb (the shell does not call it); no feature: the binding tests the verb itself.
- Window tiling, step 6d (2026-10-31, additive, ADR-0036 D70-D72, docs/specs/tiling.md TL33): `unsplit(address[, how])`
  takes an optional second argument, `how` ∈ desktop|fullscreen|replace (no argument, or `desktop`: Exit Full Screen as
  before, the popover's Move Window to Desktop). `fullscreen` (Make Window Full Screen) sends the window back to its home
  Desktop as before and puts it in full screen there. `replace` (Replace Tiled Window) moves it to its home Desktop without
  showing it: the Split View Desktop stays shown, its other member keeps its half and waits again, and the `hyprctl
  grassfield-tiling` reply's `suggestion` offers that half with the windows of the home Desktop but the one replaced (none:
  the other fills alone, D43); refused (`reason:"invalid"`) for a Split View with one member. Any other `how`:
  `reason:"invalid"`; refused while locked (`reason:"locked"`) as every `unsplit`. A plugin before 6d takes one argument and
  ignores a second, so a 6d plugin advertises feature `tiling-split-rows`, always right after `tiling-split`, and the shell
  offers the rows (and sends the argument) only with it.
- Window tiling, step 6e (2026-11-01, additive, ADR-0036 D73-D76, docs/specs/tiling.md TL33): a Split View member's
  titlebar is away and no band is kept above it (its half is filled from the output's top edge); the pointer at the top
  edge over its half reveals it as a full-screen window's is (the `titlebar-reveal` event carries it, unchanged), and its
  revealed bar takes the member's drag as well as its lights (the plugin's own input). A plugin before 6e still draws the
  strip above a member, so a 6e plugin advertises feature `tiling-split-titles`, always right after `tiling-split-rows`,
  and the shell's Overview lays a member out without a strip only with it. No new verb, event field or reply field.
- Zoom is Fill (2026-11-02, additive, ADR-0036 D78, docs/specs/tiling.md TL35): `tile(address, place)` also takes `place`
  = `zoom`, Grassfield's zoom toggle (the window fills its work area as a tile with the margins; a filled window goes back
  to its box from before; a window in Hyprland's maximized mode leaves it into Fill, unless it is client chrome, whose own
  maximize is only taken out). The plugin's zoom light, its titlebar double-click and `window_size("maximized")` do the
  same, with no new argument. A plugin before D78 rejects the place, so a D78 plugin advertises feature `zoom-fill`,
  always right after `window-tiling`, and the shell's Window > Zoom (and the green light clicked under its popover, D64)
  sends `zoom` only with it, Hyprland's maximized dispatcher otherwise. No new verb, event field or reply field.
- Toplevel drag (2026-11-08, additive, ADR-0036 amendment 2026-11-08, docs/specs/compositor.md FR58, URR-030): the plugin
  serves the Wayland global `xdg_toplevel_drag_manager_v1` and advertises feature `toplevel-drag` while it is up, last in
  the list. Informational: the shell needs nothing and sends nothing for it. No new verb, event field or reply field.
- The shell only calls verbs listed in `shell/platform/Minimized.js` `isPluginVerb`.
- All arguments are validated by the plugin (untrusted). Payloads never carry window contents.
- Unknown `v` major → the shell treats the plugin as absent.

## Contract table (`gfc/1`, machine-checked)

The block below is the contract of record for event types, their fields, closed value sets, features and verbs; the
prose above gives the reasons. `tests/ci/gfc_parity.py` (`just check-contracts`) fails when it differs from
`compositor/src` (the JSON builders and `core/Protocol.hpp`) or when the shell reads something the plugin never sends.
Every event also carries `v` and `type`. Nested fields are flattened. `version` is only in the `hyprctl grassfield` reply;
`error` is that reply's failure form. `stages` lists the fields of the event (a change notice: `gen`, `on`, `reason`) and
of the `hyprctl grassfield-stages` reply (the state: the same plus `monitors` and below); `frames` and `frames-recording`
are the replies of `hyprctl grassfield-frames` / `grassfield-frames-start`, never events. Change the block in the same
commit as the code.

```gfc1
event capabilities: features version
event minimize-request: address
event minimized: address
event restored: address
event appmenu: address service path pid
event keyboard-focus: address
event overview: state windows reason
event overview-focus: outcome target id address workspace reason
event stages: gen on reason
event tiling: gen reason
event tile-hover: address state x y w h tileable splittable unfitZones unfitPlaces
event titlebar-reveal: output revealed
event frames: clock marks monitors name presented refreshHz renders t total unit what loop beats stalls work
event frames-recording: ms recording
event error:
reply grassfield-stages: gen on reason monitors monitor workspace active hidden overlap front address app stages id slot windows x y w h
reply grassfield-tiling: gen outputs name area x y w h class grid windows address state place layout zone sides group splits workspace home waiting unfit fixed unfitZones places suggestion output zones
enum overview.state: opening open closing closed
enum overview.reason: invalid no-windows no-chrome unavailable interrupted fullscreen
enum overview-focus.outcome: pending focused fallback timeout refused superseded unavailable invalid
enum overview-focus.target: window workspace remembered none press
enum overview-focus.reason: gone hidden minimized not-shown no-workspace none no-window locked exclusive-layer press user-focus unloading invalid refused-by-hyprland
enum stages.reason: invalid disabled no-strip unknown unavailable interrupted
enum tiling.reason: placed moved resized suspended restored forgotten relaid invalid locked unavailable
enum tile-hover.state: enter leave open
feature decorations minimize config appmenu overview desktop-focus desktop-focus-v2 stages-available stages
feature cursor-refresh overview-focus minimize-effect window-tiling layer-pointer appearance client-chrome frame-times
feature keyboard-focus tiling-arrange tiling-layouts tile-hover tiling-groups tiling-shared-edge tiling-split tiling-split-rows
feature tiling-split-titles zoom-fill toplevel-drag
verb hello minimize restore config appmenu overview stages cursor_refresh overview_focus tile arrange tile_popover move_to group_front split unsplit window_size
```

## Evidence
Spike S2 (2026-10-17, nested Hyprland 0.56.2, Quickshell 0.3.1):
- `Hyprland.dispatch("grassfield:hello")` with an `addDispatcherV2` dispatcher FAILS under the Lua config:
  Quickshell sends `return hl.dispatch(grassfield:hello)` → Lua error "function arguments expected".
- `hl.plugin.grassfield.hello()` registered with `addLuaFunction` WORKS; Quickshell received
  `rawEvent grassfield>>{"v":"gfc/1","type":"capabilities","features":["decorations"]}`.
- `hyprctl grassfield` returns the capabilities JSON plus a trailing `"version"` member (the event is unchanged).

## Amendment 2026-10-24: events stay under Hyprland's 1024-byte socket2 limit; the Stages state is a request
Found in the integrator's nested run on main 8b0db19: 22 `stages` events cut at exactly 1024 bytes of data (17 bytes of
timestamp, `grassfield>>`, then 1024 bytes of JSON), so the test's jq and the shell's strip got broken JSON with about ten
windows under Stages. Hyprland 0.56.2 cuts every socket2 event's data at 1024 bytes: `CEventManager::formatEvent` passes
`min(data.size(), 0x400)` bytes to `std::format("{}>>{}\n")` and turns newlines into spaces (read from the binary). The
request socket has no such limit (a `hyprctl` reply is written whole).
- Every gfc/1 event has a bounded size under that limit (gtest `Protocol.EveryEventStaysUnderHyprlandsSocket2Limit`, at the
  worst case): capabilities (every feature) about 300 bytes; minimize-request, minimized, restored 70; appmenu 609 (service
  and path are validated to at most 255 bytes of characters that need no escaping); overview 103; overview-focus 192
  (reason `refused-by-hyprland`, the longest).
- `stages` grew with every window (about 25 bytes per window, 70 with a tile rect, plus the app name of each monitor's
  front window): the event is now a change notice, `{"v":"gfc/1","type":"stages","gen":N,"on":bool}` plus `reason` (at
  most 90 bytes), and the state, with exactly the former payload plus `gen`, is the reply of `hyprctl grassfield-stages`
  (the state of the latest notice; table line `reply grassfield-stages`). `gen` grows with every notice. The shell
  (StagesLink, the one consumer; it hands each state to Compositor for the menu bar) reads the event as a notice only,
  fetches only while Stages is active, one fetch at a time (notices during a fetch ask one more), applies a state only
  when it is complete and not older than the one shown, retries a failed or timed-out fetch (2 s) three times (200, 400,
  800 ms) and then shows no state (the strip hides rather than show a stale state as current); a notice no successful
  fetch has answered within 3 s also means no state, however many notices keep coming (a fetch under way is waited for,
  up to its 2-s deadline).
- Exception to the first Consequence below (decided by the integrator under owner delegation D-5, review of
  6b3a31f..bbcc769): this is a breaking change of the `stages` event and it stays `gfc/1`, because a session loads a
  plugin only next to the shell of its own Grassfield version (re-review of c3cb01b; the ABI stamp alone did not ensure
  it, it names the Hyprland build only):
  - the packages: `grassfield-compositor` depends on exactly `grassfield-desktop=$pkgver-$pkgrel` (one-way: pacman
    refuses to upgrade the desktop alone while the compositor needs the old version, and upgrading the compositor pulls
    the desktop of its version; the desktop does not depend on the plugin and runs without it, C2).
    `scripts/dev/check-version.sh` fails when the compositor package's final depends lacks that pin;
  - the builds: every stamp has a second line, `source <pkgver-pkgrel>`, the Grassfield version the plugin was built from
    (the PKGBUILD writes it for the packaged build, `grassfield-compositor-rebuild` for the user's). The session loader
    (`config/hypr/grassfield/compositor.lua`) and the rebuild's `--vetted` load a build only when its stamp names the
    running Hyprland's ABI and the installed sources' VERSION (`/usr/src/grassfield-compositor/VERSION`, same package):
    a build in the user's cache made from older sources is stale even for the right Hyprland, `--status` says
    `state=mismatch` / `reason=stale-build`, the shell shows its one degraded notice and, with the opt-in setting,
    rebuilds it (`--session`); otherwise nothing is loaded (C2). Tests: `tests/shell/compositor_rebuild.sh`.
  One mixed pair remains by design: a package upgrade during a session (GF-083, "Log out to finish updating") leaves the
  plugin loaded at login in Hyprland until the next login, so a shell that restarts meanwhile (a crash, a `uwsm`
  restart) is the new version next to the old plugin. Otherwise a mixed pair needs a forced install or a plugin loaded by
  hand. Every mixed pair degrades without broken JSON: a shell from before this amendment finds no monitors in the notice and shows no strip; a
  shell from after it with an older plugin gets `unknown request` from `hyprctl grassfield-stages` and shows no strip.
  `stages-available` is advertised only when `hyprctl grassfield-stages` is registered.

## Consequences
- Breaking payload changes bump `gfc/N` and need a new ADR.
- No event may grow with the number of windows or monitors: a payload that can grow is a `hyprctl` reply announced by a
  small event (amendment 2026-10-24).
- Depends on Quickshell keeping the `usingLua` dispatch wrapping; re-verify on every Quickshell minor update.
