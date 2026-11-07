# Window tiling spec · compositor-engineer (plugin) + shell-engineer (shell) · owner brief 2026-10-27

Status: step 1 merged (PR #18: engine and placement, TL1-TL15); step 2 merged (PR #28: drags, TL16-TL21); step 3 merged
(PR #31: popover, Window menu and keys, TL22-TL26); step 4 is split in three pull requests (ADR-0036 D25): 4a merged
(PR #35: the Layouts section, its number keys and the suggestions, TL27, TL28), 4b merged (PR #38: tile groups, TL29), 4c
merged (PR #42: the shared edge, TL30); step 5 merged (PR #43: Settings > Desktop & Dock > Windows, TL32); step 6 is split
in two, then five (ADR-0036 D40, D40 amended, D63, D70): 6a merged (PR #48: the Split View Desktop, TL33), 6b merged (PR
#56: the separator's reset and the swap), 6c merged (PR #70: full screen's reveal, Dock and green button; windows gathered
after an unplug), 6d merged (PR #78: the Split View rows, the Overview's drop rule), 6e merged (PR #99: the titles hidden
and revealed at the top, the revealed bar's drag). ADR-0036's plan is done (D77): the parity matrix's Later rows stay
recorded for their modules. After the plan, ADR-0036 D78 (owner report on rc1-16) made Zoom Fill: TL35. Below, "Today"
is the state before step 1. A requirement
marked (T<n>) follows the owner decision T<n> of `docs/audits/tiling-2026-10-27/decisions.md`, answered on 2026-10-27
(the recommended option each time). The parity matrix (`docs/audits/tiling-2026-10-27/parity-matrix.md`,
rows M01-M56 and W01-W31) gives the source of each behaviour. UI names follow master-prompt §14: no Apple or Microsoft
feature name.

Today (main 68ee009, plugin 0.14.0): drag tiling for the plugin's titlebar (halves, quarters, fill, blurred preview), the
`tile(address, place)` verb, Window > Fill, Center, Move & Resize (halves, quarters, Return to Previous Size),
Super+Ctrl+arrows and Super+Ctrl+R, three settings. Requirements FR47-FR50 and FR56 of `docs/specs/compositor.md`; this
spec extends them and takes precedence where it is more precise.

## macOS reference behavior (from Apple Help and public captures, described in words; no Apple image committed)
- **Drag.** A window dragged by its title bar tiles when the pointer reaches the left or right edge of the screen (half),
  a corner (quarter) or the menu bar (fill: the whole desktop, the menu bar and the Dock stay). A preview (a rounded
  rectangle with a light outline over the target, inset by the margins) shows the place before the release. Holding ⌥
  while dragging shows the nearest tile at once, anywhere on the screen, and works even with the edge settings off. A
  tiled window dragged away takes back its untiled size under the pointer. A window placed by hand is never "restored".
  Double-clicking a window edge extends that side to the screen edge; ⌥-double-click extends the opposite side too, and on
  a corner fills the screen.
- **Green button.** Resting the pointer on it opens, after about a second, a glass popover under the button, without a
  tail in the owner's captures (gs-068-161, gs-069-175; the public 512 Pixels macOS 27 capture shows a small one, and the
  owner's set is the F1 reference): "Move & Resize" (Left, Right, Top, Bottom), "Fill & Arrange" (Fill, Left & Right,
  Left & Quarters, Quarters), then a "Full Screen ›" row (Entire Screen, Left of Screen, Right of Screen; an icon in front
  of the row in macOS 27), then the "Move to <display>" rows when there are several displays. Each
  layout is a small window glyph; in the arrangements the window's own area is dark and the other windows' areas light.
  Holding ⌥ changes Fill to Center, the halves to quarters and the arrangements to their right-first forms. In full screen
  the popover offers Exit Full Screen. Measured on the owner's captures (macOS 26): 230 × 251 pt, radius 12, 26-pt glyphs
  on a 52-pt pitch.
- **Window menu.** Minimize, Zoom, Fill (⌃🌐F), Center (⌃🌐C), then Move & Resize › with three headed sections, Halves
  (Left, Right, Top, Bottom, ⌃🌐 arrows), Quarters (no keys), Arrange (Left & Right, Right & Left, Top & Bottom, Bottom &
  Top with ⌃⇧🌐 arrows, then Quarters), and Return to Previous Size (⌃🌐R), each item with its glyph; ⌥ turns the Arrange
  items into the "& Quarters" layouts (⌃⌥⇧🌐 arrows). Then Full Screen Tile ›. Arrangements take the window and the next
  windows in stacking order.
- **Resizing.** Two windows tiled side by side share their edge: a small handle in its middle resizes both; the edge
  above or below the handle resizes one. A window tiled next to a resized tiled window takes the space left.
- **Settings** (Desktop & Dock > Windows, macOS 26/27 labels): "Drag windows to left or right edge of screen to tile",
  "Drag windows to menu bar to fill screen", "Hold ⌥ key while dragging windows to tile", "Tiled windows have margins"
  (all on); "Window title bar double-click action": Fill, Zoom, Minimize, No Action (Fill since macOS 15; Zoom before).
- **Edge cases.** A window whose minimum size is larger than its tile overlaps its neighbours; full-screen windows do not
  tile; tiling works inside the current Stage Manager set and on every Space and display; the tile area leaves out the
  visible menu bar and Dock.

## Windows 11 reference (described in words; T1 takes all but the top bar)
- A flyout of layouts (miniature screens) on the Maximize button and on Win+Z, more layouts on large screens (thirds,
  1/4-1/2-1/4) and stacked ones on portrait screens; after a zone is chosen, the other windows are offered as live
  thumbnails in each empty zone (keyboard: arrows, Enter, Esc); windows placed together form a group recalled from the
  taskbar, Task View and Alt+Tab; the edge between snapped windows resizes them together (a bar on hover, always on); a
  bar of layouts at the top of the screen during a drag.

## Purpose and non-goals
Purpose: place windows in tiles, layouts and groups with macOS 27's look and gestures and the Windows 11 features the
owner takes, through the compositor plugin, with nothing lost without it (C2).

Non-goals: Hyprland's tiled layouts (dwindle, SUPER+T) as part of Grassfield's tiles; a custom zone editor; layout
suggestions from app usage history (W05); browser tabs as suggestions (W13); tips (W06); Mission Control on a drag through
the top (M04, Overview) and a Desktop change on a held edge (M05, Desktops); restoring windows when an output comes back
(M55, W17; gate R3); tiling dialogs and sheets (M32); per-window xdg TILED states.

## Terms
- **Work area**: an output's box minus its reserved area (the menu bar's and the Dock's exclusive zones, none when they
  auto-hide), minus the Stages strip column whenever Stages is on, read when a placement is computed (TL1).
- **Zone**: a rectangle of the work area given as fractions; **place**: a named zone (left, top-left, fill, left-third…).
- **Layout**: an ordered set of zones covering the work area (catalogue in tokens); **arrangement**: a layout filled with
  the window that asks and the next windows in stacking order.
- **Tile group**: windows placed together by one arrangement, layout or suggestion (T1d).
- **Box from before**: a window's floating box before its first tiling.
- **Frame**: the surface box plus the titlebar band (32 px above the surface for the plugin's titlebar, none for client
  chrome, ADR-0015).

## Functional requirements (numbered, testable)

### Engine and placement (step 1: `compositor/` and `ui/tokens/` only)
- **TL1** Work area, per output, read at the moment a placement is computed and never followed afterwards: the output's
  box minus Hyprland's reserved area at that moment (`logicalBoxMinusReserved`), minus, whenever Stages is on for that
  output's Desktop, the strip column (from the output's left edge to the right edge of the strip's tiles plus the strip's
  drop margin `kStripDropMargin`, 16 logical px, core/Stages.hpp, as last sent with `op:on`), whether the strip is shown or
  hidden. The strip hides when a window overlaps it
  (stages.md ST12-ST13): following its visibility would let tiles grow over it, which hides it again, and so on. Tiled
  windows are re-placed only when the margins setting changes (TL2) and when their output goes away (TL11). Nothing else
  moves them: a later change of the Dock (size, position, auto-hide, shrink to fit, the Dock moving to another output), of
  the menu bar or of the strip leaves tiles where they are, and the next placement uses the new area. (Hyprland emits no
  event when the reserved area changes: `arrangeLayersForMonitor` calls `invalidateMonitorGeometries`, and
  `monitor.layoutChanged` comes only from output arrangement, mode and rule changes, MonitorLayoutController.cpp:70,
  Monitor.cpp:1399, MonitorRuleManager.cpp:204.) Tiles never extend outside the work area they were placed in.
- **TL2** Margins: with "Tiled windows have margins" on, `tiling.margin` (8) between the work area's edge and each frame,
  and between frames; off, frames touch each other and the work area edges. Changing the setting re-places every tiled
  window on every output (M39). A tiled window that cannot be placed at that moment (in an inactive stage, drawn in the
  strip) keeps its record and is placed again at the next tiling action (`tile`, `arrange`, a drop in a zone) once it
  can be; if the user moves it meanwhile it is Free (ADR-0036 D8). `hyprctl grassfield-tiling` never moves a window.
- **TL3** Frames, not surfaces, fill zones: the surface box is the zone minus the titlebar band. Rounding (review of
  14e807c: Hyprland configures an xdg window with its size truncated to whole logical pixels, `sendConfigure` of
  `realToReportSize`, Window.cpp:1752-1753, so a fractional size loses up to one logical pixel and two neighbours would
  show a slit): every frame edge is an integer in logical pixels, so every size is an integer and the truncation changes
  nothing. Edges also sit on device pixels where a common grid exists: Hyprland keeps an output's scale on steps of 1/120
  with an integer logical size (output/Monitor.cpp:996-1048), so the grid step is `g = 120 / gcd(round(scale × 120),
  120)` logical pixels from the output's logical origin, an integer in both logical and device pixels (1 at scale 1 and
  2, 2 at 1.5 and 2.5, 3 at 1.333…, 4 at 1.25 and 1.75). With `g` up to 4 every edge is on that grid; above 4 (scales
  such as 1.2, 1.6, 1.8, 1.125) edges are whole logical pixels only, and the device position is Hyprland's rounding: a
  one-device-pixel seam or overlap between two neighbours is possible there (known limitation). Snapping: an edge between
  two tiles without margins is one shared value, rounded to the nearest grid line, for both tiles (no slit, no overlap);
  with margins each frame edge is rounded on its own (`b − m/2` and `b + m/2` around the exact boundary `b`), so the
  margin between two tiles is `tiling.margin` exactly when `g` divides it (1, 2, 4) and within `g` of it otherwise. An
  outer edge (the work area's border, plus the margin when margins are on) goes to the nearest grid line inside the work
  area: where the menu bar or the Dock ends off the grid, the outer margin is up to `g − 1` pixels wider (none at `g` =
  1). Unit-tested at scales 1, 1.25, 1.333…, 1.5, 1.6, 2.
- **TL4** Places: left, right, top, bottom, top-left, top-right, bottom-left, bottom-right, fill, center (today); left
  third, middle third, right third, left two thirds, right two thirds, and the quarter columns of the ultra-wide class
  (T1f). Center keeps the window's size (at most `tiling.centerMaxFraction` of the work area) in the middle.
- **TL5** Layout catalogue: token group `tiling.layouts`, zones as fractions, per output class (T1f: small, large,
  ultra-wide, portrait; class from the output's logical width and aspect), generated into the plugin and the shell by
  `ui/tools/gen-tokens.py` (`--check` fails on a stale copy).
- **TL6** Arrangements (M27, M28): Left & Right, Right & Left, Top & Bottom, Bottom & Top, Quarters, and Left, Right, Top,
  Bottom & Quarters, filled with the window that asks first, then the next windows in stacking order that are tileable,
  on the same output, on the same Desktop and, with Stages on, in the active stage. With fewer windows than zones, the
  empty zones stay empty (the window that asks still takes its zone). The windows placed form a tile group (T1d).
- **TL7** A half placed next to a tiled neighbour that already covers part of the other side takes the rest of the work
  area beside it, not an exact half (M44).
- **TL8** Size limits (M46-M48, W27): a window whose minimum is larger than its zone gets its minimum, aligned to the
  zone's edge on the work area's border so it stays on the output; in an arrangement the neighbours shrink to make room
  when their minimum allows, else the frames overlap; the other zones on the window's side of that edge follow it when
  every zone facing them made room (Left & Quarters: the other quarter meets the narrower half, no hole). A maximum smaller than the zone: the window takes its maximum,
  centred in the zone. X11 resize increments round the size down. The minimum used is, for an xdg window, the larger of
  its protocol minimum and a `min_size` window rule (a rule replaces the client's minimum in `CWindow::minSize()`,
  Window.cpp:2885-2889, while Hyprland's commit clamp still applies the protocol minimum, Window.cpp:2741-2747); for an
  X11 window, the rule or its size hints. The engine applies that minimum itself, so the commit clamp never recentres a
  tile. The maximum, likewise, is the smaller of a `max_size` rule and the xdg protocol maximum (the commit clamp applies
  the protocol maximum too). The minimum is never under Hyprland's own floor, `MIN_WINDOW_SIZE` (20 px, what its resizes
  fall back to): an app that states no minimum is not squeezed to a 1 px frame (integrator review of a6d04df).
  Since ADR-0036 D69 (capture defect of 2026-10-30: Quarters at 1440 x 900 with Settings, 420 px tall at least, came out
  with shifted rows) a window is placed only in a zone it fits, its minimum with its titlebar band inside the zone's frame
  as the glyph shows it (a half beside a neighbour: the TL7 frame): the popover and the Window menu grey the places,
  arrangements and Layouts zones it does not fit (`unfitZones`, ADR-0007), `tile`, `arrange` and a pick refuse them, a drag
  shows no preview there (a place on the frame `tile` applies, a half beside a neighbour included: `unfitPlaces`),
  an arrangement's fill gives each remaining zone the topmost window that fits it (a zone no window
  fits stays empty) and the suggestion offers only windows that fit. Fill and Center are always offered. The make-room
  above now serves windows already placed whose work area shrinks (the margins switch, the Dock). The shell as built
  (review of D69): greyed, never hidden, as macOS greys a tile it cannot make. The popover reads the event's lists
  (WindowTiling.parseHover `fit`): a place by `unfitPlaces`, an arrangement by its first zone (the window's own) in
  `unfitZones`, a Layouts zone by itself (TileGlyph `disabledZones`: fainter, no pointer, no press, no number key), a layout
  none of whose zones fits greyed whole; the Window menu reads the reply's per-window lists when it opens (TilingLink
  `unfitZones`, Compositor.fitOf) and greys those Halves, Quarters and Arrange items, their key texts kept; the keys
  themselves reach the plugin, which refuses them.
- **TL9** Not tileable (the menu items and popover glyphs greyed, no drag preview, never a suggestion): windows with a
  parent (dialogs), fixed-size windows (minimum equals maximum on an axis), X11 windows that Hyprland floats by type
  (dialog, splash, toolbar, utility, tooltip, menus, dock, KDE override) or as modal, transient, task dialog or pop-up
  (XWaylandManager.cpp:110-131), X11 override-redirect, Glance (`org.grassfield.Preview.Glance`, the quick look panel),
  pinned, full screen or zoomed, on a special workspace, minimized, in an inactive stage (drawn in the Stages strip),
  closed or unmapped (during a titlebar drag: the plugin then moves it no more, gate C1). Nothing tiles onto an output
  that shows an open special workspace: a drop there only moves the window (TL21, D9).
  The X11 test reads what `shouldBeFloated` reads (the window's type atoms against Hyprland's atom table `HYPRATOMS`,
  looked up by name and never written; modal, transient, parent, role, override-redirect) without calling it: that
  function also sets focus flags on the window.
- **TL10** Tile record: per window, `{zone or place, box, before, group, output}`, where `box` is the frame the plugin
  last gave or saw it take through a user resize and `before` the floating box before its first tiling. It follows the
  state machine below (it replaces FR49's rule "a window moved or resized since its tiling is no longer tiled": a user's
  resize keeps the record, so groups and TL7 keep working). Return to Previous Size puts `before` back (centred on the
  window's output when it lies off every output) and makes the window Free.

| From | Event | To | Record |
|---|---|---|---|
| Free | tile, arrangement, layout, suggestion, a release in a drag zone, an edge double-click (TL20) | Tiled | `before` = the current box; `box` = the placed frame; group per TL6, TL27-TL29 |
| Tiled | tiled again from any source | Tiled | `before` kept; `box` = the new frame; it leaves its group unless the new placement is the same arrangement |
| Tiled | a move passes the drag threshold (the plugin's titlebar drag or Hyprland's move) | Moving | the window takes `before`'s size under the pointer at the same relative place: the plugin's drag moves it (`untileUnderPointer`, today); Hyprland's drag is ended, the box set and the drag begun again from it (`endDragTarget`, `setTargetGeom`, `beginDragTarget`, as ClientChrome.cpp:113-116 does after a zoom), because Hyprland keeps the drag's start position private; it leaves its group |
| Moving | release in a drag zone | Tiled | `before` kept; `box` = the new frame |
| Moving | release elsewhere, or the drag cancelled | Free | forgotten |
| Tiled | Hyprland's resize starts on it (a border with `resize_on_border`, Super+right drag, an app's `xdg_toplevel.resize`, the shared-edge handle) | Resizing | — |
| Resizing | the resize ends (seen after Hyprland ended it, the FR56 pattern) | Tiled | `box` = the new frame; `before` and the group kept; through the handle the neighbours' boxes too (TL30) |
| Tiled | enters full screen or zoom; is minimized or hidden | Suspended | kept |
| Suspended | leaves full screen or zoom | Tiled | `box` re-applied when Hyprland's restore differs |
| Suspended | restored or shown again | Tiled if its zone is free (below) on the output it comes back to, else Free at `before` | — |
| Tiled | the margins setting changes; its output goes away | Tiled | re-placed (TL2, TL11) |
| Tiled | its box differs from `box` when the plugin next reads the record, outside a known drag or resize (an app's own configure of an X11 window, a keyboard move or resize dispatcher, a rule) | Free | forgotten |
| any | the window closes or unmaps; the plugin unloads | — | forgotten |

  Move to Desktop keeps the state (the box does not change). A group lives while it has two members that are Tiled,
  Resizing or Suspended. Step 1 built every row but one; step 2 builds the last (Hyprland's move of a tiled window:
  Moving at its size from before once past the drag threshold, tiled again at a release on the place shown, TL16; in
  step 1 the record ended at the first motion, ADR-0036 D2). The plugin reads the records (and applies the last row) when
  it places a window, answers `hyprctl grassfield-tiling` or the titlebar drag starts.

  A zone is **free** on an output and Desktop when no other window that is Tiled or Resizing there has a frame that
  overlaps the zone's frame by more than 1 logical pixel on both axes (windows that are Free, Moving or Suspended do not
  count). The output a Suspended window comes back to is the one Hyprland restores it on: the output under the middle of
  its restored box, else the focused output. When the output of its record went away while it was Suspended (Hyprland
  moves only mapped, visible windows to the remaining output, state/WorkspacePlacementController.cpp:307-311, so a
  minimized or hidden window keeps a box on the removed output), the zone is taken on the output it comes back to, and
  when that zone is not free the window is Free at `before`, centred on that output when `before` lies off every output
  (as Return to Previous Size).
- **TL11** Output removed: Hyprland moves the windows to another output (it translates them, H22); the plugin then places
  each tiled window into the same zone of the output it landed on and keeps its group. Output added: nothing moves.
- **TL12** Full screen and zoom: Suspended in TL10; on leaving, Hyprland restores the floating box and the plugin
  re-applies `box` if it differs.
- **TL13** Stages (ADR-0013): tiled windows are floating and belong to stages; a stage swap changes no geometry; a drop
  that tiles wins over a drop on the strip (today).
- **TL14** Minimize, hide, Move to Desktop: as TL10 (Suspended, then back to its zone if it is free, else Free at
  `before`, also after its output went away; Move to Desktop keeps the state).
- **TL15** State: the plugin keeps, per output, the tiled windows (address, place or layout zone, group id); a change posts
  the `tiling` notice; `hyprctl grassfield-tiling` returns the state (ADR-0007 rule: no event grows with the windows).

### Drags (step 2)
- **TL16** Every interactive move of a floating window tiles like the plugin's titlebar drag (M01, M17): Hyprland's own
  move started by an app (`xdg_toplevel.move`, client chrome) or by Super+drag is observed on each motion
  (`input.mouse.move` with `dragController()->mode() == move`) and tiled after Hyprland ended the drag (the FR56
  pattern). The same preview is drawn, by the decoration every window carries (hidden for client chrome), under the
  dragged window. A tiled window dragged away by Hyprland's move takes back its size as TL10 says (the drag is ended and
  begun again; whether the restarted move must carry the exclusive device grab of an `xdg_toplevel.move` again,
  Window.cpp:2825-2837, is checked in step 2). At the release a pending tile wins over the top clamp (FR56): the tile's
  frame lies inside the work area, below the menu bar, and the clamp's deferred callback leaves a window the release has
  just tiled alone; without a tile, the clamp applies as today.
  Step 2 as built: the plugin's pointer listener sees each motion of Hyprland's move before Hyprland applies it (the
  `input.mouse.move` event comes first in `CInputManager::mouseMoveUnified`). A tiled window past the drag threshold
  (`kDragThreshold`, 4 px from the press) becomes Moving: its drag is ended, its box set to the size from before at the
  same place of the grip (`unzoomedDragBox`), and the drag begun again with the exclusive device grab the drag had (an
  app's `xdg_toplevel.move` asks for it, `CWindow::onXDGMoveRequest`; read with `exclusiveDeviceGrab()` before the end:
  yes, it is carried). A tiled window released under the threshold goes back to its tile (ADR-0036 D12). The release
  that ends the move records the place shown; once Hyprland ended the drag the window is tiled there (the top clamp's
  pending callback is dropped, `gf::topClamp::skip`), else a Moving window is Free. A window Hyprland itself tiles, lifted
  out of its layout for the drag (`draggingTiled()`), shows no preview (D15). The preview is drawn by the window's own
  titlebar decoration, also when its bar is hidden (client chrome). Not tied to the tiling listeners for the titlebar
  drag; Hyprland's moves need them.
- **TL17** The preview appears after the pointer has rested in a zone for `tiling.previewDelay` (value measured in nested
  against the owner's captures; macOS shows a short delay, U); leaving the zone hides it at once; a release before the
  delay does not tile. With Alt held there is no delay.
  Step 2 as built: one dwell for every drag (core `CDwell`: the place and its output; a change starts over), a timer that
  draws the preview when the pointer rests, Alt read again after each key once Hyprland applied it. `tiling.previewDelay`
  is 250 ms, an estimate until measured in nested (ADR-0036 D11).
  Since the 1.0.0-rc6 report ("the gesture up to fill the screen is very slow"): the menu bar's Fill shows at once when no
  other output lies above that output's top edge (core `showsAtOnce`): the window is held below the menu bar (FR56) and the
  pointer has gone on into the top of the screen, a target and never a way to another display, where macOS shows the fill
  outline as the pointer reaches the menu bar; with an output above, the strip is crossed on the way there and keeps the
  delay, as the side edges do. And the plugin's titlebar drag sets the window under the pointer at once
  (`warpPositionSize` after each step, as Hyprland's own move with `misc:animate_mouse_windowdragging` off, the session's
  value): each step had restarted the 300 ms `windowsMove` animation, so the window trailed the pointer on its way up
  (nested capture: still mid-way 100 ms after a jump of the pointer). The tile at the release keeps its animation.
- **TL18** Alt-drag (M06, setting "Hold Alt key while dragging windows to tile", `windows.tilingOptionDrag`, on): while Alt
  is held during a move, the zone is the nearest half, quarter or fill from the pointer's position in the work area (the
  work area split in thirds across and down: corners give quarters, side thirds halves, the top-middle third fill, the
  centre the half on the pointer's side), whatever the edge and menu-bar settings.
  Step 2 as built: core `placeForAltPointer` and `dragPlace`; the bottom-middle cell gives the half on the pointer's side
  too (ADR-0036 D10); a pointer outside the work area (menu bar, Dock) counts in the nearest cell; the plugin accepts
  `config("tilingOptionDrag", true|false)` (on at load; the Settings switch is step 5).
- **TL19** The plugin's titlebar drag snaps to other windows and to the work area edges as Hyprland's drag does (public
  `performSnap`, `general:snap` values), outside tile zones (M11).
  Step 2 as built: `performSnap` with Hyprland's `general:snap:enabled` read at each step, only while no place is under
  the pointer (shown or still waiting for the delay).
- **TL20** Double-click on a window's resize border (M14-M15): that side extends to the work area edge (with the margin
  when margins are on); with Alt, the opposite side too; on a corner with Alt, the window fills the work area. The window
  is then tiled (it has a box from before).
  Step 2 as built: a left click whose press began one of Hyprland's resizes of a window (its border with
  `resize_on_border`, or the app's own resize handles through `xdg_toplevel.resize`) and whose release comes within the
  drag threshold is a click on its resize border; two on the same sides within the double-click time and distance
  (`CClickTracker`) are a double-click (ADR-0036 D13), acted on once Hyprland ended the second resize. The sides are those
  the press lies beyond (core `sidesAt`; a press in a rounded corner, inside the surface, gives that corner); without Alt
  a corner extends its two sides (D14). Core `extendFrame` moves them to the edges of the whole-area frame (inside the
  margin, on the grid) and keeps the others; limits keep the side that did not move. The record's placement is its
  sides (`sides` in the state reply): a margins change or a removed output moves them to the new area's edges. Alt on a
  corner (all four sides) is Fill. Refused while locked; not for windows that cannot be tiled (TL9).
- **TL21** Unchanged rules: an output edge shared with another output never tiles (the drag moves the window over); the
  corner band is `tiling.cornerBand` (96) along a free side edge; the edge distance is `tiling.edge` (4). Since step 1 a
  window the plugin moves onto another output (its titlebar drag, a tile there) belongs to the Desktop that output shows,
  as after Hyprland's own move; `arrange` first gives each window it names the Desktop of the output it is on (ADR-0036
  D9).
  Since the 1.0.0-rc6 report ("a maximized window moved to a smaller display overflows it"), macOS's rule for a window
  that lands on another display: dropped there by a drag (the titlebar's, from the output under the box at the press;
  Hyprland's move, from the output the move began on) or moved to a Desktop of that output (Hyprland's move to a
  workspace: the Overview, a key), a Free window larger than that output's work area is made to fit it (core
  `fitIntoArea`: at most the area's size on each axis, never under its minimum; on an axis where it was larger it starts at
  the area's start, its titlebar right below the menu bar; on the other it keeps its place, so a window may still hang off
  a side or the bottom), and its titlebar is never left under that output's menu bar (Hyprland keeps such a window inside
  the output, bottom-aligned: measured, the titlebar 21 px under the bar). A tiled window moved to a Desktop of another
  output takes the same tile there (TL11's relayout, as `move_to`). Not a full-screen or zoomed window, a Split View
  member or a window on a Split View Desktop, nor a Stages strip window. One INFO line per window fitted.
  The move-to-a-Desktop fit is for another display only (review of 3ca47a4b; core `fitsOnMove`): the plugin remembers each
  window's last regular Desktop and its output (seeded at load, kept at open and at each move); a move fits only from a
  regular Desktop of another output to a regular Desktop, never to a special workspace nor back from one (minimize, a
  scratchpad), never between two Desktops of one output, and never for a window whose last Desktop is unknown. A window
  larger than its own output's work area keeps its size when it changes Desktop on that output, as on macOS.

### Popover and Window menu (step 3, waits for the merge of PRs #8-#10)
- **TL22** Hover: the pointer resting on the zoom light for `tiling.hoverDelay` (about a second on macOS; measured in
  nested) makes the plugin post `tile-hover` (enter) with the window and the light's rectangle; leaving the light posts
  leave. The shell opens the popover (popup kind `tiling` of `qs.overlay`) below the light, without a tail (owner's
  captures gs-068-161, gs-069-175), shifted sideways or placed above when the output has no room. It closes on Esc, a
  click outside, an action, the window closing or losing its tile eligibility, a capabilities change without the
  feature, and when the pointer has been outside both the light and the popover for `tiling.hoverDelay`.
  Step 3 as built: core `CHoverDwell` (the light under the pointer, its delay, a press ends a hover until the pointer left
  the light) and an event loop timer post `enter` once the delay passed with no button held; the titlebar's light (shown
  or revealed bar, its hit slop) or a Grassfield app's light (TL24); one event channel, the latest state wins. The shell
  (services/TilingHover) opens the popover under the light, the light `tiling.popoverLightInset` in from its left edge
  (D20), above it when the output has no room below; an `enter` never replaces another open popup, an `open` does (D23).
  Never over the lock or another surface (integrator review of 4ead6fb): the plugin counts no light while the session is
  locked, while an Exclusive layer other than the shell's popup layer is mapped (the polkit sheet, Search, Apps, the
  Overview, the switcher, the Notification Center, the Dock's keyboard mode, any third-party one) or while a Top or Overlay
  layer or a layer popup is under the pointer (core `hoverCoverEffect`, D24: under the lock or a foreign Exclusive layer a
  hover that began ends and the light is forgotten, so the hover starts over once the desktop is back; under a layer, the
  shell's open popover included, it ends and the light waits until the pointer has left it, as after a press, so a popover
  closed over the light does not come back by itself). The session lock's own events end the hover too, and the unlock
  looks at the light under the pointer again from the event loop: a pointer resting on a light through the lock gives a
  hover `tiling.hoverDelay` after the unlock, with no pointer motion (integrator nested rerun of 25e757c). The shell
  refuses the popover while locked (first decision), while the polkit sheet, a full-attention surface (FocusReturn's
  holders) or the Dock's keyboard mode is up (`WindowTiling.hoverRefusedBy`), and closes the open popover before opening
  another window's.
  While it is open the overlay holds the pointer, so the plugin's `leave` is ignored: the popover itself closes after
  `tiling.hoverDelay` away from the light and from it, counted only once the overlay saw the pointer. It also closes when
  the window enters or leaves full screen or goes away, and with the feature.
- **TL23** Popover content (M19-M21, M23), in this order: "Move & Resize" (Left, Right, Top, Bottom), "Fill & Arrange"
  (Fill, Left & Right, Left & Quarters, Quarters), "Layouts" (T1a, the output's class, T1f), "Full Screen ›" (Entire
  Screen; Left of Screen and Right of Screen from step 6, T4), then one "Move to <output name>" row per other output
  (after Full Screen, as in the owner's captures). With Alt held: Center instead of Fill, the quarters instead of the
  halves, Right & Left and Right & Quarters. In full screen: Exit Full Screen only. Glyphs not available for the window
  (TL9) are greyed.
  Step 3 as built: AppMenuModel `tilingPopover` (shared with the Window menu's rows, glyphs and texts) and
  overlay/TilingPopover (glass `menu`, `tiling.popoverWidth` wide, glyphs `tiling.glyph*` on a `tiling.glyphPitch` pitch,
  the TileGlyph component of Grassfield.Ui). Layouts waits for step 4 (D16); the Full Screen row enters full screen until
  step 6 turns it into Full Screen › (D17; step 6a as built: TL33); the arrangements are greyed without `tiling-arrange`. Move to <display> rows
  name the output as Settings > Displays does (Built-in Display, its model, else its connector) and call `move_to` (D18,
  D22).
- **TL24** Client chrome (M25): on windows tagged `grassfield-client-chrome` whose app is a Grassfield app, the plugin
  hit-tests the zoom light at its token position (ADR-0015 `WindowControls`) to post the same hover; spike first in step 3
  (full-screen and zoomed windows, right-to-left layouts). Third-party client chrome gets no popover.
  Step 3 as built (D23): an `org.grassfield.*` window with the client-chrome tag, not in full screen: its xdg-toplevel tag
  names the row, `info` the titlebar row (`window.titlebarLightInset`), any other role the unified toolbar row
  (`window.unifiedLightCentre`); zoomed windows keep their lights there; Grassfield apps never mirror their lights.
  A window of fixed size (minimum = maximum on both axes, core `fixedSize`; About This Computer, ADR-0040 step 1b) posts
  no `tile-hover` from its zoom light, which its app draws disabled, and `tile_popover` (Super+Ctrl+L) is refused for it:
  nothing opens, on hover or click (integrator nested pass of 85c2c10, scenario 6). The reply lists such windows
  (`fixed`); `tests/compositor/tiling.sh` case `fixed`. Its review: the plugin's own titlebar draws that zoom light
  disabled too (grey, no glyph) and its click, Alt-click and a double-click set to Zoom do nothing, unless the window is
  zoomed or in full screen already (core `lightAvailable`; case `fixed bar`); Super+Alt+F (Zoom) and Super+Ctrl+F (Full
  Screen) leave it alone the same way: `bindings.lua` asks the plugin's `window_size(mode)` at each press, which returns
  Hyprland's own dispatcher or a no-op (core `sizeKeyActs`; Hyprland's dispatcher as before without the plugin;
  `tests/compositor/size_keys.sh`, case `fixed keys`).
- **TL25** Window menu (T0, `AppMenuModel.qml`, M26-M28): Minimize, Zoom, Fill, Center, —, Move & Resize ›, Full Screen
  Tile › (T4), —, Enter Full Screen, —, Move to Desktop ›, —, Bring All to Front, —, the windows. Move & Resize › has the
  headed sections Halves, Quarters, Arrange (with Quarters), then Return to Previous Size; each row has its glyph; Alt
  shows the "& Quarters" alternates in place. Shortcut texts come from the one table that mirrors `bindings.lua`.
  Step 3 as built: Minimize, Zoom, Fill, Center, —, Move & Resize ›, one Move to <display> row per other output (D21), —,
  Enter Full Screen, …; Full Screen Tile › waits for step 6 (D17; step 6a as built: after Enter Full Screen, TL33). PopupMenu gained section headers, glyph rows and Alt
  alternates (`alternate`, also in a submenu opened by the pointer: it follows the Alt of the menu that opened it). Arrange
  needs `tiling-arrange`. A window of fixed size (the reply's `fixed`, read again when the menu opens): Zoom, Enter Full
  Screen, Full Screen Tile and the tiling rows greyed, as macOS greys them for a window that cannot be resized (Unzoom and
  Exit Full Screen stay, ADR-0040 step 1b); the tiling keys refuse it already (TL9: fixed on an axis).
- **TL26** Keyboard (T2 option A as amended by T2a and T2b): Super+Ctrl+arrows always give the half, as on macOS (the same
  key again does nothing); Super+Ctrl+U, I, J, K the top-left, top-right, bottom-left and bottom-right quarters, bound by
  key position (`code:` bindings, as `bindings.lua` does for the key above Tab) so they sit in the same place on AZERTY;
  Super+Ctrl+Return Fill; Super+Ctrl+C Center; Super+Ctrl+R Return to Previous Size; Super+Ctrl+Shift+arrows the four
  arrangements; Super+Ctrl+Alt+Shift+arrows the "& Quarters" layouts; Super+Ctrl+Alt+Left/Right the next output;
  Super+Ctrl+L opens the popover on the focused window with keyboard focus (arrows between glyphs and rows, Return, Esc;
  with Layouts, a number picks a layout and a second number a zone). Super+Z is not used: Super plays Command, so it is
  ⌘Z, Undo.
  Step 3 as built: `bindings.lua` (the descriptions in Settings > Keyboard, translated; Super+Ctrl+L by key position too,
  keycode 46), IPC `windows arrange <layout>`,
  `windows tilePopover`, `windows nextOutput left|right` (D22: by position, wrapping), each refused while locked first.
  The popover's arrows move between glyphs and rows (overlay/TilingNav).
  Step 4a as built (D28): in the Layouts section the arrows also move between the zones of the layouts (a row of layouts is
  one line); a number 1-9 picks a layout of the section, its zones then show their numbers, and a second number places the
  window in that zone; Esc lets go of a picked layout first, then closes the popover. The digits are read by character or,
  for the top row, by key position (`TilingNav.digitOf`), so they work on AZERTY.

### Windows features (step 4; T1 takes TL27-TL30, refuses TL31)
- **TL27** Layouts (T1a, T1f): the popover's Layouts section shows the catalogue of the window's output class as miniature
  screens; hovering a zone highlights it; a click places the window in that zone and, with suggestions on, opens TL28 for
  the other zones; the layout's windows form a group.
  Step 4a as built: AppMenuModel `layoutsSection` (the `tiling.class*` tokens of the class `WindowTiling.outputClass` gives
  the popover's output, the same rule as the plugin's `classify`), after Fill & Arrange, with the plugin's `tiling-layouts`
  only; the layouts drawn at `tiling.layoutGlyphWidth`, four per row, every zone light at rest and the zone under the
  pointer or the keyboard in full (TileGlyph `interactive`, each zone a button named "<layout>, zone <n> of <count>", D28);
  greyed when the window cannot be tiled. A zone click is `arrange` with `zone` (the window alone in that zone; a group forms
  when a suggestion joins it).
- **TL28** Suggestions (T1c, option 2): after a layout or an arrangement chosen from the popover, the Window menu or the
  keys leaves zones empty, the shell shows in each empty zone, one zone at a time, live thumbnails (ScreencopyView) of the
  tileable windows of the same output, Desktop and stage, minimized ones included; a click or Return places the chosen
  window there and moves on to the next empty zone; Esc, a click outside or the window that asked losing its zone ends it.
  Nothing is shown when no window fits. Not after a plain edge drag.
  Step 4a as built (D26, D27): the plugin keeps the suggestion after an `arrange` that left zones of its layout empty (core
  `zonesHeld`, `emptyZones`): the empty zones with their frames in the work area and the windows that can fill them (the
  tileable windows of that output's Desktop in the active stage, top first, then those minimized from that output, the latest
  first; at most `kMaxSuggested` 12; never one already in that layout); the `hyprctl grassfield-tiling` reply carries it as
  `suggestion` while the tile records are still at its generation, so any later change, the asker losing its zone included,
  ends it. The shell (platform/TilingLink) fetches the reply after the `placed` notice of an arrangement it asked itself
  (`Compositor.suggestionAsked`: a zone of the Layouts section, Window > Move & Resize > Arrange and its keys, a pick) and
  shows the suggestion when it belongs to that notice and fills that window's layout; services/TilingSuggest opens popup kind
  `tilingSuggest` (overlay/TilingSuggestions) centred in the first empty zone: menu glass, the windows as live thumbnails
  (ScreencopyView) with the app's icon and the window's title, as large as the zone allows (`WindowTiling.suggestionGrid`,
  at most `tiling.suggestTileWidth`), the arrows (`WindowTiling.gridStep`), Return or a click to pick, Esc, any other key
  (a modifier alone aside) or a click outside to end. A pick is `arrange` with `zone` and `with`: the window joins the asker's group (a new group when it had none); a
  minimized window is restored without the Dock animation, then placed (D27). A refused pick (a zone held meanwhile) changes
  nothing and the suggestion stays. The suggestions are refused over the lock, the polkit sheet, a full-attention surface and
  the Dock's keyboard mode, and never take the place of another popup than the tiling popover.
- **TL29** Tile groups (T1d, option 1): a window brought forward from the Dock, the app switcher or the Overview brings its
  group forward (back to front in the group's stacking order, the chosen window in front); the Dock's app menu lists the
  app's groups ("Show Tile Group"); the Overview moves a group to another Desktop as one; membership follows TL10: a
  window leaves its group when it is dragged away (Moving), tiled elsewhere or becomes Free; a resize keeps it; minimized
  windows stay members; a group of one dissolves.
  Step 4b as built (D29-D31): verb `group_front(address)` (core `groupRaiseOrder`): the members of the window's group that
  are Tiled or being resized on its Desktop are raised in their stacking order, bottom first, then the window itself
  whenever it is on screen, zoomed or full screen included (`alterZOrder("top")`, the same raise as a restore; integrator
  review of cd74af2); a minimized, full-screen, zoomed or hidden member stays; no tile record changes. The shell
  (Compositor `groupForward`, `activateWithGroup`, `unminimizeWithGroup`) sends it after the window's own activation or
  restore, only for a window in a group of the last reply (`WindowTiling.membersOf`) and never while locked, for a Dock
  click (the window that ends focused), a Dock tile of a minimized window, the Dock menu's and the menu bar's window rows,
  the app switcher and the Overview's choice of a window or of a minimized one; the window ends in front whichever request
  the compositor takes first (on a special workspace it is not raised, and its restore raises it). The groups are the
  `group` of each window in the `hyprctl grassfield-tiling` reply (`WindowTiling.parseGroups`, a suspended member
  included), read again by platform/TilingLink after every change of the tile records. The Dock menu lists the app's
  groups after Show All Windows (`WindowTiling.tileGroupRows`): "Show Tile Group", or "Show Tile Group with <the other
  members' apps>" when the app has several; the row (Compositor `showTileGroup`, the steps of
  `WindowTiling.tileGroupSteps`) shows the group's Desktop (the window's, else a member's that is on one), brings the
  window and the group's minimized members back there, focuses the window and brings the group forward, all through the
  dispatch channel in that order, nothing if the lock engaged while the menu closed. An Overview drop (Compositor
  `moveGroupToSpace`, `WindowTiling.groupMovers`) moves the window and the members on its Desktop to the target Desktop,
  where they stay tiled and grouped (TL14). Feature `tiling-groups`, with `tiling-arrange`.
- **TL30** Shared edge (T1e, option 1, M43, W18): between two windows of a group whose frames share an edge (margin
  between them included), the pointer over the middle `tiling.handleLength` of that edge shows a handle (resize cursor);
  dragging it moves the edge for every window of the group along it, within their minimum and maximum; outside the handle
  the edge resizes one window as usual. Spike first: the neighbours follow on each step of Hyprland's resize
  (`CWindow::m_events.resize` or the motion listener, then `setTargetGeom` and a warp), measured for configure storms and
  P3; if live following proves too slow, the neighbours follow at the release and show their app icon on the glass during
  the drag (Windows' placeholder).
  Step 4c as built (D32-D34): the plugin drives the drag itself, Hyprland's resize is not followed (D33). Core
  `sharedEdges` finds, per output Desktop, the edges the Tiled members of a group share: two windows face each other when
  the gap between their facing sides is the margin or less (from -1 to margin + 1 px) and they overlap along it by more
  than 1 px; an edge holds every window of the group on that line, before (left or above) and after it; one handle per
  pair of facing windows, the middle `tiling.handleLength` of the stretch they share, across the gap and at least
  `tiling.handleBand` wide (without margins half in each window). **The frontmost window under the pointer always gets the
  click** (macOS; integrator review of a6d04df): the handle exists only where nothing is in front of it, that is where
  Hyprland's own pointer-focus hit test (its reserved extents, so a titlebar, its border grab areas, xdg popups, a
  full-screen or zoomed window, from the top of the stack) finds no window or one of the edge's own windows, and no popup
  (core `handleClear`). The pointer resting on a handle (no button held, no modifier, the desktop not covered: not
  locked, no foreign Exclusive layer, no layer under the point, no other window, titlebar or popup in front) shows a
  left-right or up-down double arrow (Hyprland's special-action cursor override, above resize_on_border's border icon);
  nothing is drawn (D32). Any popup there counts, whichever window it belongs to: Hyprland's hit test returns the topmost
  window whose box (border grab area included) holds the point before it looks at the popups of the windows below, so the
  plugin checks every visible window's popups (integrator nested pass of 3d56d60); so does an X11 override-redirect window
  (an XWayland app's menu, a tooltip) whose box holds the point, for which that hit test returns the focused window
  (integrator review of 0c4c8f2). Hover reads edges kept from the last look, built again when the book's records, a window's box,
  band or state, the output's Desktop or the margins changed. A plain left press there, with no button held by any device,
  is the plugin's: it and its release are cancelled
  on the bus (compositor.md FR13, as P6), every window of the edge goes Resizing, and the edge follows the pointer along
  its axis (core `dragEdge`: the before windows' far side and the after windows' near side move together, the gap kept,
  the edge on the grid line nearest the pointer and never past any window's minimum or maximum, heights counting the
  titlebar band), each window's surface set and its animation ended at once (`setTargetGeom`, `warpPositionSize`, as a
  step of Hyprland's own resize), at most once per refresh of the output (the motions in between wait for a timer: P3,
  the neighbours configured at most once per refresh); the release, or the lock the moment it engages, ends it: Tiled
  with the new boxes, one `resized` notice, a DEBUG line with the drag's steps, held motions, duration and the plugin's own
  time in it (total and longest step; each step is also a work span of the frame probe, compositor.md FR54). A window
  closed, unmapped or no longer Resizing meanwhile leaves the drag (logged once, no longer set), but its frame from the
  press and its limits still bound the edge (integrator re-review of ce82fd3: else the other side followed the pointer off
  the work area; core `dragEdge` does not move an edge with no window left on one side); Tiled again at its end if its
  record is still Resizing; the others go on (gate C1). Outside the handle Hyprland's resize_on_border resizes one window (TL10: it keeps its record
  and group). During the drag DesktopFocus and the titlebars ignore the pointer. Feature `tiling-shared-edge`, with
  `tiling-arrange`. The spike's measurement (D34, amended by the integrator): tests/visual/presented-frames.sh
  `shared-edge` (two live windows, three glides with the button held) kept 64.9 % and 58.6 % of frames within 20 ms in a
  loaded nested instance, every long frame paced by a client and none by the compositor (render CPU p95 6.1 and 5.3 ms):
  the neighbours stay live (macOS's live resize, each app redrawing at its own pace) and Windows' placeholders are not
  built. The compositor's cost counts its render's CPU and, before the render, the time the event loop was held (the
  frame probe's beats, every 1 ms) or ran the plugin's own work: a stall there shows only as a late render, which read as a
  client's before (integrator review of a6d04df). Measured so, the drag still had compositor-caused long frames at idle (30
  and 43 in two runs), with the plugin's own work at 0.1-0.2 ms per frame: the loop is held 10-18 ms before a late render
  by Hyprland's own handling of the resize. The gate (D34 final, integrator, 2026-10-29): the shared edge's P3 passes when
  (a) the plugin's own work is at most 1 ms in every frame of the drag and (b) its compositor-caused long frames per second
  per resized window are at most 1.25 times those of Hyprland's own resize_on_border drag of one of the same windows with
  the same glide (presented-frames.sh `edge-baseline`); frame-attribution.py `--gate --baseline --drag-mark`, the drag's
  resized windows read from its own frame-probe mark (`edge-drag:F/E` at each drag's end: F of the edge's E windows
  followed; a drag some did not follow fails), which fails without the loop's or the plugin's records, without the
  baseline, when the scenario never ran and when the animation holds no frame; the share on time is information. Nested pass of 3d56d60: the plugin's work at most 0.71 ms in a frame, 5.45/s per resized window
  against Hyprland's own 5.5/s: met; Windows' placeholders are dropped.
- **TL31** Layout bar at the top of the screen during a drag (T1b): not built; the menu bar keeps its macOS role (fill,
  TL21). Kept here so a later change of mind starts from the design: the plugin would hit-test zones the shell publishes
  (as the Stages strip does) and post the hovered zone.

### Settings (step 5, waits for the merge of PRs #8-#10)
- **TL32** Desktop & Dock > Windows, in this order: "Drag windows to left or right edge of screen to tile"
  (`windows.tilingEdges`, on), "Drag windows to menu bar to fill screen" (`windows.tilingMenuBar`, on), "Hold Alt key
  while dragging windows to tile" (`windows.tilingOptionDrag`, on), "Tiled windows have margins" (`windows.tilingMargins`,
  on), then the switches of the features taken with the T3 names: "Show layouts when hovering over the green button"
  (`windows.tilingLayouts`, on), "Suggest windows to fill the rest of a layout" (`windows.tilingSuggestions`, on), "Bring
  tile groups forward together" (`windows.tilingGroups`, on). "Window title bar double-click action" gains Fill (the default
  since ADR-0036 D78, TL35)
  (`windows.titlebarDoubleClick` = `fill`). Each key is pushed with `config(...)` once the plugin advertises its feature;
  without the plugin the rows show the existing footnote and do nothing. The settings contract (ADR-0020) and the schema
  in `config/schema/` gain the keys in the same commit.
  As built (step 5, ADR-0036 D36-D39): the Windows group lists the seven switches in this order, then "Rebuild the
  compositor extension after Hyprland updates", under the footnote "Needs the Grassfield compositor extension."; the Alt
  row names the key as the menus do (`keyboard.shortcutStyle`: "Hold ⌥ key…" in the macOS style); the double-click
  choice is Fill, Zoom, Minimize, No Action (macOS 27's names). The shell pushes `tilingEdges`, `tilingMenuBar`, `tilingOptionDrag` and
  `tilingMargins` with `window-tiling`, `tilingLayouts` with `tile-hover`, `tilingSuggestions` with `tiling-layouts`, and
  `titlebarDoubleClick` = `fill` only with `tiling-arrange` (`zoom` in its place otherwise, D36). Layouts off: the plugin
  posts no hover `enter` and the shell ignores one; `tile_popover` (Super+Ctrl+L, the Window menu) still opens the
  popover with its Layouts section. Suggestions off: the plugin keeps no suggestion after an arrangement and drops the
  pending one (it does not come back when the switch turns on), the shell asks for none, and one shown closes. Tile groups off: the shell's `groupForward` brings the window
  alone; the plugin gets no key (it raises a group only on `group_front`), groups still form, and Show Tile Group still
  brings the group (D37).

### Full Screen tile (step 6, T4)
- **TL33** Full Screen › Left of Screen / Right of Screen: a new Desktop right after the current one, the menu bar and the
  Dock hidden on it, the window in that half and suggestions (TL28) for the other half; a separator between the two that
  resizes both (double-click resets); dragging a window by its title bar to the other side swaps them; the menu bar and
  the Dock show when the pointer reaches their edge; Exit Full Screen of one window returns it to its Desktop and box and
  the other fills the Split View Desktop alone (amended by ADR-0036 D44: macOS 27 returns only the window asked).
  Step 6a as built (ADR-0036 D40-D48): with the plugin's `tiling-split` the popover's Full Screen row is the submenu Full
  Screen › Entire Screen (Hyprland's full screen in place, D45), Left of Screen, Right of Screen, and the Window menu has
  Full Screen Tile › Left of Screen, Right of Screen after Enter Full Screen; the halves are greyed with the tiling items
  (a window that cannot be tiled now, full screen, zoomed) and while Stages is on (D47: the plugin refuses them while its
  strip shows). The plugin's `split(address, side)` makes a Desktop with the next free id on the window's output and shows
  it (D41: the shell lists it right after the Desktop it came from, in the Overview strip and the Move to Desktop rows;
  Hyprland's next and previous Desktop keys and Ctrl+number keep the id order); the window takes that half of the whole
  output, one `tiling.margin` separator between the halves, none at the outer edges, whatever the margins switch says
  (D42, core `splitArea`). The suggestions (TL28) offer the other half with the windows of the Desktop it came from,
  always (D48); a pick joins the window's tile group, so the shared edge (TL30) is the separator that resizes both.
  Dismissed, or nothing to suggest, the window fills the Split View Desktop alone; one of two leaving (closed, minimized,
  moved, sent back) leaves the other filling it; an emptied Split View Desktop ends, and its output goes back to the
  Desktop it came from when it showed it (D43). The menu bar and the Dock hide there as in full screen and show at their
  edge; the wallpaper's video pauses. On a Split View window the popover offers only Exit Full Screen, and the Window menu
  Exit Full Screen without Zoom or tiling items: the plugin's `unsplit(address)` (D44). Its titlebar drag moves nothing
  (D46). The `hyprctl grassfield-tiling` reply lists `"splits":[{"workspace","output","home","windows","waiting"}]`.
  After the integrator review of c7a6b6e (D49-D55): a Split View Desktop has members, the window it was made for and the one
  picked, whatever their state; another window there is an ordinary floating window, no member, and changes nothing (D52;
  once no member is left the Split View ends and that Desktop stays, an ordinary one). The green button of a member, with or
  without Alt, leaves the Split View as Exit Full Screen does (D49). An app's own full screen or a zoom keeps a member and
  its half, the other keeps its own, and the window comes back to its half after; one of Hyprland's moves (Super+drag) puts
  a member back in its half at the release; the tiling keys, Arrange and an edge double-click refuse a member, Fill aside for
  one alone (D50). Its picker ending without a second window in any way (dismissed, refused over another surface, timed out,
  ended by another change) makes the one member fill the Desktop; while locked, at the unlock (D51). Exit Full Screen of a
  window tiled on its Desktop before the split puts it back into that tile when its zone is still free, the picked window's
  too, and a member zoomed or in full screen by a key leaves that first (D54, D50). Nothing of a Split View changes behind
  the lock: the lock ends a pending picker, and the fill of a lone member or the end of an emptied Desktop waits for the
  unlock, when the plugin does it itself; a fill the shell sent and the plugin refused as locked is sent again (D55,
  integrator re-review of e5bd9d2). A Split View Desktop follows its workspace to another output when its output goes
  away. The Overview names it after its apps and gives it no number, the Desktops keep theirs, and the Window menu's Move to
  Desktop lists the Desktops only (D53). After the integrator's nested pass of 1ee992e (D48 amended, D56-D58): the
  popover opens on a member and offers its Exit Full Screen (it closed itself as it opened, leaving the overlay mapped
  with no popup; a popup's close made while it opens now waits for the end of that open, and the popover compares its
  window's state with the one it opened in). A Split View the shell did not start shows its picker too (D48 amended). A
  member is not minimized: its yellow light is grey, as in full screen, the Window menu greys Minimize and Super+M does
  nothing (D56). A window whose minimum size does not fit half of its output is refused up front: Left and Right of Screen
  greyed in the popover (`splittable`) and Full Screen Tile in the Window menu (the reply's `unfit`, read again when the
  menu opens; D57 amended), `split` and a pick into the other half refused, and that half's picker offers only windows that
  fit (D57). Popups and the overlay compute `active` and `open` again, once a second while anything shows, when they
  disagree with the popup's kind (a value a binding loop left stale must never keep the overlay over every click and key). The picker opens with its first window selected (Return takes it), and the window picked has the
  keyboard once the suggestions close (D58). A lone member's fill waits for the end of the event that made it lonely, so
  the shell's own lock, which closes the picker just before its lock state changes, sends it at the unlock.
  Step 6b as built (ADR-0036 D59, D60, D40 amended): a double-click on the separator (the shared edge between the two
  members, core `splitOfEdge`) puts both back to equal halves of the whole output, its press and release the plugin's; an
  ordinary group's shared edge keeps TL30's drag only; the double-click time is the titlebar's (400 ms). A member dragged by
  its titlebar follows the pointer at its size (no un-tile, snap or preview; its record is kept meanwhile, core
  `staleRecord`, and read before anything reconciles at the drop); released over the other half the two swap halves (core `splitDropZone`; each keeps its group
  and its box from before), anywhere else, or when the drag ends without its release, it goes back in its half; it never
  takes another output's Desktop that way; nothing swaps while locked. After #48's merge: the picker no longer reads its
  windows before they exist (a TypeError at each open), the window picked has the keyboard on any output whose Desktop shows
  it, and the tiling popover and the suggestions close with their output instead of moving to another one. After the
  integrator's note from an owner report (D61, D62): the overlay holds the keyboard and takes the output's input only while
  a popup is loaded on it (a stale `open` with no popup lets every key and click through, logged; its mapping follows `open`,
  as tying it to the popup made the window resize under the popup's position: a binding loop), and a
  window in full screen is not minimized (Minimize greyed, Super+M nothing).
  Step 6c as built (ADR-0036 D63-D68): a click on the green light while its tiling popover is open (the popover's overlay
  takes it) runs the light, released over it: a Split View member leaves the Split View, a full-screen window leaves full
  screen, with Alt a window enters it, else Zoom; then the popover closes (shell `WindowTiling.greenAction`); the overlay's menu bar strip passes a press on to the bar
  only while the bar is in view, so a Split View member's light under it is the light's (`WindowTiling.stripPress`). In full
  screen the plugin posts `titlebar-reveal` when the window's titlebar is revealed at the top edge of an output or goes
  away (ADR-0007); the menu bar there is in view while it is revealed and leaves with it, without its hide grace
  (`AutoHide.leaveNow`); an older plugin sends nothing and the bar keeps its own auto-hide. The Dock hides on an output
  that shows a full-screen window (as on a Split View Desktop) and sits on the overlay layer meanwhile, so the pointer at
  its edge brings it back over the window (`DockModel.hides`, `overlayLayer`); its reserved area does not change. After an
  output goes away, a floating window left off every output comes back centred on the work area of its Desktop's output at
  its size, at most the area's (core `strayFrame`, `gatheredFrame`; not a full-screen, Stages strip or minimized window).
  The picker's deadline for the plugin's reply is 6 s (D68); a reply adopts a Split View's picker unless it answers the
  shell's own ask (`WindowTiling.replyPicker`), so an earlier ask still open never hides a new Split View's picker.
  Step 6d as built (ADR-0036 D70-D72): with the plugin's `tiling-split-rows`, a Split View window's tiling popover offers
  Move Window to Desktop (Exit Full Screen's effect, D44), Make Window Full Screen (back home, in full screen there) and
  Replace Tiled Window (only with two members: back home without showing it, the other keeps its half and waits, the picker
  offering the windows of that Desktop but the one replaced); the Window menu adds the last two after Exit Full Screen. All
  through `unsplit(address[, how])` (core `unsplitHow`; `offerWindows` since 6e, its cap counted after the exclusion),
  refused while locked. The Overview takes no window onto a Split View Desktop and drags no member out of one
  (`WindowTiling.dropAllowed`; since 6e checked through the Overview's own path by the development hook `overview
  dropProbe`, D76).
  Step 6e as built (ADR-0036 D73-D76): a member's titlebar is away, whatever its state, and no band is kept above it
  (core `band(clientChrome, splitMember)`): its half is filled from the output's top edge; a window that joins or leaves a
  Split View has its titlebar refreshed (core `splitMembers`, `membersChanged`), and a pick joins the Split View before its
  frame is fitted. The plugin advertises `tiling-split-titles`; with it the Overview lays a member out without a strip
  (`WindowTiling.splitTitleAway`). The pointer at the top edge over a half reveals that half's bar alone, below the menu bar
  and over the window's content (the full-screen path, ADR-0015 P6; core `nextRevealed` with `inSpan`); the menu bar comes
  with it (`titlebar-reveal`); while it is there the pointer moving across within the bar's band brings the other half's
  (`handOver`), the bar revealed owning the gap between the halves until the pointer is over the other half
  (`overOther`, D74 amended); a member covered by its other member (zoomed or in full screen) shows none; while a press
  on a revealed bar lasts no other bar comes. Its lights act as a full-screen window's (green
  leaves the Split View, minimize grey and inert); a left press away from them starts the member's drag (core
  `revealedPress`): once it moves, the window hangs below its bar, which follows the pointer from where it was pressed,
  never higher, without the top clamp (D75 amended);
  released over the other half the two swap (D59), anywhere else, on another press, a pointer device gone or the session
  locked it goes back in its half. The press and its release are cancelled on the bus (Hyprland's held buttons
  untouched). A window that leaves a Split View any way (a key, the unload) gets its frame with its titlebar band below
  the menu bar (`TopClamp belowMenuBar`; a hidden one when it shows, not while locked; D73 amended); the unload puts a
  member dragged by its revealed bar back in its half first.

### Zoom (ADR-0036 D78, after the plan)
- **TL35** Zoom is Fill (owner report on rc1-16: a zoomed foot window sat glued under the menu bar and against the left
  edge, Hyprland's maximized mode at [1, 57] 1534x741 on eDP-1 1920x1080 at scale 1.25, reserved [0, 24, 0, 65], its
  rounded corners against the menu bar). Grassfield's Zoom, from the zoom light without Alt, a titlebar double-click set
  to Fill (the default) or Zoom, Super+Alt+F (`window_size("maximized")`), Window > Zoom and the green light clicked under
  its popover (D64), places the window as Fill (TL4: the work area of TL1 with the margins of TL2, on the grid of TL3), so a
  zoomed window keeps `tiling.margin` from the menu bar, the Dock and the screen's edges while "Tiled windows have margins"
  is on and touches them when it is off, as macOS does. The same Zoom of a window placed as Fill (its record Tiled with
  place `fill`) puts back its box from before (Return to Previous Size, TL10). A window in Hyprland's maximized mode (a
  dispatcher, another client) leaves it into Fill. Client chrome zooms the same way from its own controls (D78 amended,
  ADR-0015 amendment 2026-11-03): while `window-tiling` is advertised its own maximize request (its green light, its
  toolbar double-click) is this Zoom, Hyprland told to ignore it. A window moved to another output since it was filled
  (move_to) unzooms on that output and its Desktop; a window at the Fill frame whose record a plugin reload forgot unzooms to
  the Center place's frame (TL4), Free. The Window menu says Unzoom for a filled window. Unchanged:
  Alt+zoom light is true full screen (ADR-0015 P6); a window in full screen and a Split View member (D50) keep Hyprland's
  maximized toggle; a window that cannot be tiled (TL9: Fill refused) gets Hyprland's maximized mode; a window of fixed size
  that is not zoomed gets nothing (TL24). Without the plugin's `window-tiling` (no plugin, a degraded one) and while the
  session is locked, Zoom is Hyprland's maximized mode as before (C2).
  As built: core `zoomStep` (Fill, Previous, UnzoomToFill, Hyprland, Refused, Unfill; `TilingZoom.*`), glue
  `gf::tiler::zoom` (Tiling.cpp) for the titlebar's light and double-click (Titlebar.cpp `toggleZoom`) and for client
  chrome's own request (ClientChrome.cpp: `SUPPRESS_MAXIMIZE` set by the plugin only, again on every rule change, cleared at
  unload; the xdg `stateChanged` listener; the echo after full screen swallowed, core `maximizeEcho`; `ClientChromeZoom.*`);
  the shell's `WindowTiling.parseFilled` for the Window menu's Unzoom; `window_size("maximized")` zooms the
  focused window itself and returns Hyprland's dispatcher only for the Hyprland step (bindings.lua unchanged); `tile(address,
  "zoom")` with feature `zoom-fill`, always right after `window-tiling` (ADR-0007), which the shell's `Compositor.toggleZoom`
  sends with that feature, Hyprland's maximized dispatcher otherwise (`Minimized.zoomRequest`). Settings:
  `windows.titlebarDoubleClick` defaults to `fill` (schema, contract, defaults); the shell still sends `zoom` without
  `tiling-arrange` (D36) and a stored choice is kept; Fill and Zoom are the same toggle in the plugin. A drag that starts on
  a window in Hyprland's maximized mode still only leaves that mode under the pointer (FR8). Nested:
  `tests/compositor/zoom_fill.sh` (the light with and without margins, the key, Hyprland's maximized mode, the verb, the
  default double-click, Alt+zoom, scale 1.25, move_to, a plugin reload, the plugin unloaded),
  `tests/compositor/zoom_fill_apps.sh` (Settings and Files: their own light, their toolbar double-click with the default and
  with zoom, Window > Zoom, the light under its popover, the plugin unloaded); `zoom_restore.sh`,
  `double_click_setting.sh`, `client_chrome.sh`, `third_party_chrome.sh` and the controls of `tiling.sh` follow it.

### Session lock (every step that adds an entry point)
- **TL34** Nothing of tiling opens or acts over the lock (security.md "Nothing opens over the lock", GF-116): the popover
  (popup kind `tiling`, through `Popups.open`), the suggestions overlay, the Layouts section, the shared-edge handle and
  the new `windows` IPC functions (`arrange`, `tilePopover`, `nextOutput`, beside today's `tile`) ask
  `SessionState.refuses(...)` first; when the lock engages, an open popover or suggestions overlay closes. The plugin's
  hover event changes nothing by itself (the shell refuses the popover). The shared-edge handle (plugin, step 4c) takes
  nothing while the session is locked, a foreign Exclusive layer or a layer covers the point, or any window, titlebar or
  popup other than the edge's own is in front of it (the frontmost window under the pointer gets the click, TL30); the
  lock ends a drag the moment it engages (its cursor goes too; its release stays cancelled), and no input after the lock
  moves a window. `docs/specs/security.md` "Nothing opens over the
  lock" names them as planned; the step that adds an entry point moves it into that list with its code, and into
  `tests/security/lock_surfaces.sh` when it is a surface. Plugin side (step 1, defence in depth): the verbs `tile` and
  `arrange` refuse while the session is locked (notice `reason:"locked"`, nothing moves). Step 6a: `Compositor.split` and `Compositor.unsplit` ask
  `SessionState.refuses` first, and the plugin's `split` and `unsplit` refuse while locked (no Desktop made or shown);
  `Compositor.tile` and `Compositor.fillAlone` refuse first too, and services/TilingSuggest sends no fill while locked
  (integrator review of c7a6b6e, MAJOR 2).

## Appearance (F1 strict, ADR-0024)
- Targets: geometry within ±1 pt of the owner's captures, tints within ±0.1, contrast A2, motion by tokens. Tokens only;
  the geometry constants of today (`kEdge`, `kCorner`, `kMargin`, `kCenterMaxFraction`) move to the token group `tiling`
  in step 1.
- Proposed tokens (values from the owner's captures where measured, else marked estimate until measured in nested):
  `tiling.popoverWidth` 230, `tiling.popoverRadius` 12, `tiling.popoverGlyph` 26, `tiling.popoverGlyphPitch` 52, section
  titles in the menu header style, `tiling.hoverDelay` (estimate 1000 ms), `tiling.previewDelay` (estimate, U),
  `tiling.margin` 8, `tiling.edge` 4, `tiling.cornerBand` 96, `tiling.centerMaxFraction` 0.9, `tiling.handleLength`
  (estimate, U), `tiling.layouts` (TL5).
- Popover: the glass of the "Menus, Search" class (it carries text: the A2 floor applies), rims per ADR-0024, no tail
  (owner's captures), shadow of menus. Glyphs: the outline and the window's own area in the label colour, the other
  windows' areas in the secondary label colour; hover and keyboard focus: the accent fill with white glyphs (ADR-0024
  "white on the accent"); disabled: the tertiary label colour.
- Light and dark appearances: popover, glyphs, suggestions overlay, handle and preview follow `Appearance.dark`; the
  preview keeps its tokens `titlebar.previewTint*` / `previewRim*` (FR48, FR53).
- Preview: the frosted pane of owner decision D-8 (not macOS's outline), corners at the window radius, inset by the
  margins.
- Suggestions overlay: the work area dimmed outside the empty zone, thumbnails fitted in the zone with the window's
  title below, accent focus ring; glass of the "Overview band" class.
- Reduce Transparency: opaque surfaces of the same class. Reduce Motion: window moves are instant (Hyprland `windowsMove`
  off, already pushed by the shell), overlays crossfade within `motion.reducedMax`.

## Motion
- Window moves into tiles: Hyprland's `windowsMove` leaf (today speed 3, curve `gfDecelerate`), values mirrored from the
  motion tokens in `config/hypr/grassfield/looknfeel.lua` and `shell/platform/Minimized.js motionLeaves`; compared with
  the owner's recordings in nested if they exist (U).
- Popover open and close, suggestion steps, handle and preview fades: `motion.fast` / `motion.normal` with
  `motion.curveStandard`. No duration or curve outside the tokens.

## Interfaces / contracts (proposed; payloads fixed in each step and recorded in ADR-0007's contract table then)
- **Plugin verbs (gfc/1, additive):** `tile(address, place)` with the TL4 places, `previous` and `zoom` (TL35, feature
  `zoom-fill`); `arrange(json)`
  `{"layout":"<catalogue id>","windows":["0x…",…],"output":"<name>"?}` (at most 4 windows, 4 KiB); `config` keys
  `tilingOptionDrag`, `tilingLayouts`, `tilingSuggestions`, `tilingGroups` and `titlebarDoubleClick` = `fill`.
- **Plugin events:** `tiling` notice `{gen, reason}` (bounded); `tile-hover` `{address, state: enter|leave|open, x, y, w,
  h, tileable}` (step 3; `open` answers `tile_popover(address)`; `move_to(address, output)` moves a window to another output).
- **Plugin reply:** `hyprctl grassfield-tiling`: per output the work area, the tiled windows (address, place, layout and
  zone or the sides an edge double-click extended, group, box) and, from step 4, a pending suggestion; the windows that do
  not fit half of their output (`unfit`, D57) and the windows of fixed size (`fixed`, TL24).
- **Features:** `window-tiling` (today) plus one per capability (layouts and arrangements, hover, groups, shared edge),
  each advertised only when its listeners and verbs registered.
- **Shell IPC (`qs ipc`, for key bindings):** `windows tile <place>` (today), `windows arrange <layout>`, `windows
  tilePopover`, `windows nextOutput <direction>`; each listed in `docs/specs/security.md` in the step that adds it
  (`tests/security/ipc_inventory.sh`).
- **Settings keys:** TL32, in the settings contract (ADR-0020) and `config/schema/`.

## Dependencies (verified versions)
- Hyprland 0.56.2, commit efb50993: the internals of ADR-0036 and `docs/audits/tiling-2026-10-27/sources.md` (read in the
  sources; re-verify on every Hyprland update, the ABI check refuses a mismatched build).
- Quickshell 0.3.1 (overlay layer surfaces, ScreencopyView for the suggestions) and Qt 6.11.2: the qmltypes are checked in
  steps 3 and 4 on the owner's machine (not available in this container).

## Degraded behavior (plugin missing, unloaded, or a feature missing)
- No plugin: every window stays where it is; no tiling menu items, no popover, no suggestions, no groups, no handle; the
  keys do nothing; Settings shows the tiling rows with the "needs the Grassfield compositor extension" footnote; Hyprland's
  drags move windows as usual (C2).
- Unload during a drag, a popover or suggestions: the plugin removes its listeners, the preview and its timer, posts empty
  capabilities; the shell closes the popover and the overlay; windows keep their boxes; groups are forgotten; a drag of
  Hyprland's in progress goes on as Hyprland's own.
- Tiling listeners missing (tiling-arrange not advertised): the titlebar drag and `tile` still tile; Hyprland's moves
  and the edge double-click move and resize windows as Hyprland does, without tiling.
- A missing feature (older plugin): the shell hides only what that feature serves.

## Automated tests · Manual verification steps
- **Unit (L0, gtest, `compositor/tests/TilingTest.cpp` grown):** work area with menu bar, Dock, Stages strip and margins;
  every place and layout on the four output classes; arrangements with 1 to 4 windows; neighbour-aware halves; minimum,
  maximum (the larger of rule and protocol minimum) and increments; edges snapped to device pixels at scales 1, 1.25, 1.5
  and 2 (shared edges equal, no seam); not-tileable classes; output removal; the tile record's state machine (TL10: every
  transition, a user resize keeping the record and the group); the work area read at placement with Stages on and the
  strip hidden; keys (halves, U I J K quarters, next output); drag zones with and without Alt; the token copies equal
  (`gen-tokens.py --check`).
- **Unit (L0, QML):** `tst_appmenumodel` (the full Window menu, alternates, greying, and the popover model: sections, Alt
  alternates, full screen, outputs), `tst_windowtiling` (the tile-hover parser, the popover's anchor, the outputs and the
  next output), `tst_tilingnav` (the popover's keys), `tst_tileglyph`, `tst_popupmenu` and `tst_menunav` (headers,
  alternates), `tst_minimized` (the verbs' calls); suggestion and group models.
- **Nested (L1, `tests/compositor/tiling.sh` grown; the integrator runs them, never on the owner's session):**
  1. step 1: arrange with 2, 3, 4 windows on GF-REF; a test client with a large minimum; margins toggled re-place; output
     removal with tiled windows; Stages on (area beside the strip); minimize and restore to the zone;
  2. step 2: client-chrome drag (Files, Chromium) tiles with the preview; a tiled client-chrome window dragged away keeps
     its grip under the pointer at its size from before (the restarted Hyprland drag); Super+drag tiles; Alt-drag in the
     middle; double-click on an edge, Alt-double-click on a corner; the preview delay; a release under the menu bar that
     tiles is not moved by the top clamp; unload in the middle of a drag;
  3. step 3: hover opens the popover (captures in both appearances, measured against the owner's gs-068-161, gs-069-175,
     gs-068-149); keyboard Super+Ctrl+L, arrows, Return, Esc; Alt alternates; Move to <output> on two outputs; the Window
     menu capture against gs-020-039; popover, suggestions and keys refused while locked (`lock_surfaces.sh`);
  4. step 4: layouts per class, suggestions with the keyboard, groups from the Dock, the switcher and the Overview, the
     shared-edge handle with live neighbours (frame times, P3);
  5. every step: C2 (`nested-up.sh --no-plugin`), C1 soak with tiling actions in the churn, Reduce Motion, 0 QML errors;
     C3: the plugin builds and passes C1/C2 against the Hyprland of the Omarchy rc channel (CI job of master-prompt §11)
     before that Hyprland reaches stable, the new internals of ADR-0036 re-read on each Hyprland update.
- **Owner (L2):** trackpad drags, a HiDPI or portrait output, the real Dock and switcher.

## Performance (gates affected)
- P3: popover and suggestions open within one frame budget; the shared-edge drag with two live neighbours costs the plugin
  at most 1 ms per frame and causes, per resized window, no more compositor long frames per second than 1.25 times
  Hyprland's own resize of one window (ADR-0036 D34 final: its share of frames on time follows the apps' redraw and is
  reported as information); the neighbours are configured at most once per output refresh.
- C1: the soak gains tiling actions (arrange, drag to edges, popover open and close, shared-edge drags).

## Accessibility
- Gate A1: every action has a Window menu item; the popover and the suggestions are navigable with the keyboard and
  show a visible focus; every glyph has an accessible name ("Left", "Left & Quarters", "Move to <output name>") and role.
- Contrast A2 on the popover text and glyphs in both appearances at every transparency value up to 0.6.

## i18n
- Every string through `qsTr()`, English and French complete (gate I1); the T3 names; output names are shown as the
  system gives them.

## Refusals (with the reason; rows of the parity matrix)
- W05 layout suggestions from usage history, W13 browser tabs, W06 tips, W29 Start-menu pairs, W30 custom zone editor:
  outside both references' core or Windows-only integrations.
- W22 stretch to full height, W24 minimize others: covered by macOS gestures (⌥-double-click, Hide Others).
- M32 tiling dialogs and panels: they belong to their window (Hyprland centres them on it).
- M41 a Quick Settings tiling control: not verified on Apple's pages.
- T1b layout bar at the top of the screen: refused by the owner (the menu bar keeps its macOS role).

## Known limitations (honest, user-visible gaps vs macOS)
- Third-party apps that draw their own title bar (Chromium, GTK header bars, Electron) get no popover on their green
  button; the Window menu, the keys and the drags work for them. Super+Ctrl+L opens their popover at the top-left corner
  of the window's frame.
- While the popover is open the overlay holds the pointer: the window under it gets no hover or click until it closes (as
  under any menu); a click on the zoom light itself then closes the popover instead of zooming.
- Hyprland tells every xdg window it is tiled and maximized (TILED_* and MAXIMIZED states, H21), floating or not; no
  per-window change.
- X11 windows: their minimum comes from size hints and Hyprland's commit clamp does not apply to them.
- No per-move animation curve: every tile move uses the `windowsMove` animation.
- Windows do not return to an output when it is connected again (macOS 27 does).
- At output scales whose 1/120 step has no common grid of at most 4 logical pixels (1.2, 1.6, 1.8, 1.125…), two
  neighbouring tiles may show a one-device-pixel seam or overlap (TL3).
- Tiles do not follow a later change of the work area (the Dock resized, moved or auto-hidden, the menu bar hidden, the
  Stages strip): they keep the box they were given until the next tiling (TL1).
- Windows tiled the Hyprland way (SUPER+T) are outside Grassfield's tiles, groups and popover.
- The Split View (step 6a) has no separator double-click reset, no swap by titlebar drag and no revealed titles yet
  (step 6b); Left and Right of Screen are refused while Stages shows its strip (ADR-0036 D47).
- A Split View Desktop is listed after the Desktop it came from, but Hyprland's next and previous Desktop keys, Ctrl+number
  and the three-finger swipe go by Hyprland's id order (ADR-0036 D41).
- Without the plugin there is no tiling at all, and Zoom is Hyprland's maximized mode: the window fills the work area
  without margins (TL35, C2).
- Without `window-tiling` a client-chrome app's own zoom control is Hyprland's maximized mode, glued to the work area's
  edges, as every Zoom then (ADR-0015 Q4; TL35).
- The suggestions mark the keyboard-current or hovered window with the neutral selection of an item on glass (the hover ink
  at `material.selectionOpacity` 0.25, one role since ADR-0039 step 12): 1.72:1 at worst against the material
  (`tests/visual/test_contrast_tokens.py`; 1.23:1 before), under the 3:1 a state indicator should reach, as macOS 27 draws it
  (its App Switcher: 1.8:1). Listed, not asserted, in `tests/visual/contrast-roles.json`. The popover's glyphs and rows take
  the menus' selection, white on it, and its section titles the menus' header (`MenuHeader`), as this spec asks (ADR-0039
  step 8).
- Timings not published by Apple or Microsoft (hover delay, preview delay, animation curve) are estimates until measured
  in nested against the owner's material.
