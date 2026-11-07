# grassfield-compositor spec · compositor-engineer · M0 spike S2 → M1 decorations → M2 minimize → S5 appmenu → M3 overview v2 → desktop focus

Status: titlebars, gfc/1 capabilities, minimize/restore with animation (M2), the `config` verb
(double-click setting), the appmenu protocol server (feature 3, step A of global menus; spike S5), the overview
live transforms (feature 4, Mission Control v2: the plugin side; spike and shell contract in `docs/specs/overview.md`;
R13 fixes 2026-10-18) and the desktop focus policy (feature `desktop-focus`, FR30-FR32, ADR-0012 amendment; v2
`desktop-focus-v2`) implemented; Stages prototype behind a feature flag (features `stages-available` / `stages`,
FR33-FR38, ADR-0013, spec `docs/specs/stages.md`; input guards after the R13 review of 46b3e9b; active window, menus
and focus reasons after the R13 counter-review of 17208af; no focus under an Exclusive layer after the R13 counter-review #3 of e9ebc7f); cursor
refresh for the pointer size (feature `cursor-refresh`, FR39-FR40, ADR-0014); the focus after the Overview closes (feature
`overview-focus`, FR41-FR43, owner decision 2026-10-19 batch 5; its deferred-focus core shared with Stages); click focus
for Hyprland's focused window without the keyboard (FR30 (d)) and the keyboard back after an unlock (FR30 (e)), plugin
0.8.2-clickfocus; the funnel minimize effect (internal name Genie), the shrink effect and the Reduce Motion fade (feature `minimize-effect`,
FR44-FR46, Track B3, owner defect #6), plugin 0.9.0-genie; the macOS 26 titlebar (F2a: 32-px bar, 14-px lights,
hover glyphs, grey lights on inactive windows, square bar/content join, FR3-FR4c), plugin 0.10.0-chrome; window tiling
(feature `window-tiling`, FR47-FR50), plugin 0.11.0-tiling; the pointer focus on a shell layer that maps or takes the
keyboard under a resting pointer (feature `layer-pointer`, FR51-FR52), plugin 0.12.0-pointer; the GF-AUDIT-001
remediation (2026-10-23): restore on the window's own display at its frame (FR15, owner decision D-1), a dialog that opens
during the Overview close gets the keys (overview.md "Close focus", GF-038), the chrome follows the appearance (feature
`appearance`, FR53, UX-06), the tiling preview is the blurred material (FR48, D-8), `CLater` cancels on destruction
(ARCH-21), the rebuild for a new Hyprland (ADR-0009 amendment, GF-033). Plugin 0.13.0-audit. The unified toolbar's
plugin work item (ADR-0015 P1-P7, feature `client-chrome`) and the presented-frame times of gate P3 (FR54, feature
`frame-times`): plugin 0.14.0.
Code: `compositor/`. Build and run: `compositor/README.md`.

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)

- Every standard window has a titlebar strip about 32 pt tall that is part of the window: same corner
  radius as the window at the top, square joint with the content, one continuous outline and shadow.
  macOS 26: titlebar-only windows have a corner radius of about 13 pt, toolbar windows about 26 pt
  (docs/testing/f1-reference-gaps.md, "Window chrome"); macOS 27, the target: one corner for every window, 16.5–16.7 pt
  circle-equivalent at 45° (ADR-0024 C-1).
- Three circular buttons on the left, 14 pt diameter, evenly spaced (9 pt gaps, 23 pt pitch), the first centre
  about 15.6 pt from the window's left and top edges, vertically centered: close, minimize, zoom. Glyphs appear on
  hover; inactive windows show grey buttons.
- The window title is centered on the full titlebar width in semibold system text, never overlapping the
  buttons, truncated with an ellipsis when too long.
- Dragging the titlebar moves the window; double-clicking it performs the user's chosen action (default: Fill, which
  is also what Zoom does since ADR-0036 D78).
- Buttons act on mouse-up over the same button (press, move away, release = cancel).
- Minimize: the window goes into its own tile in the Dock, right of the separator. System Settings > Desktop & Dock
  > "Minimize windows using": "Genie Effect" (the default: the window's bottom is pulled into the tile through a
  curved funnel, its sides pinch toward the tile's width, then the whole window slides down into it, about half a
  second) or "Scale Effect" (the window shrinks uniformly while it moves, accelerating, about a third of a second).
  Clicking the tile plays the effect backwards and makes the window key again. Shift held plays it in slow motion.
  With Reduce Motion the window fades instead of moving. (Grassfield names its own options "Funnel" and "Shrink", FR45.)

## Purpose and non-goals

Purpose (S2): prove that a Hyprland 0.56.2 plugin built against the installed headers can draw and drive
macOS-like titlebars on floating windows, and that the shell can discover the plugin's capabilities over
IPC under Hyprland's Lua config (input for ADR-0007). M2: real minimize with an animation toward the Dock
tile rectangle the shell sends (ADR-0002), and the user's double-click setting.

Window tiling (FR47-FR50 here) grows into layouts, arrangements, tile groups and the green-light popover:
`docs/specs/tiling.md`, ADR-0036 (Proposed, owner brief 2026-10-27, which takes tiled windows out of the non-goals).

Non-goals: the pressed-button state, appearance switching, CSD negotiation; for the overview: the
layout, labels, Desktops bar and input (the shell), transforming popups; for appmenu: reading or
rendering DBusMenu menus (that is `grassfield-menu-bridge` and the shell, step B, ADR-0008), the
`com.canonical.AppMenu.Registrar` service, X11 (XWayland) menus.

## Functional requirements (numbered, testable)

- **FR1** The plugin refuses to hook anything when `__hyprland_api_get_hash()` differs from
  `__hyprland_api_get_client_hash()`, logs the mismatch and shows one notification. The plugin's own notices (this one
  and the failed start) are in the session's language (GF-067; macOS shows system notices in the user's language): a
  compiled table, `core/Notices.hpp`, French or English by gettext's rule: `LANGUAGE`'s first entry unless the locale is
  C or POSIX, then `LC_ALL`, `LC_MESSAGES`, `LANG` (the first set and not empty). The shell can differ: it takes Qt's
  system locale, which still follows `LANGUAGE` under `LANG=C.UTF-8`, where gettext ignores it, so
  `LANGUAGE=fr LANG=C.UTF-8` gives a French shell and English plugin notices (gettext's rule, kept on purpose);
  `tests/NoticesTest.cpp` fails when a notice is missing from the table's list or has no French text. They are Hyprland notifications, shown
  before any gfc/1 channel exists, so gfc/1 is unchanged.
- **FR2** Every mapped floating window (not full screen, `decorate` rule not false, not X11
  override-redirect) gets a titlebar decoration 32 px (logical) tall above its content; tiled and
  full-screen windows get none (zero extents). A full-screen window's titlebar is revealed by the pointer at the top
  edge of its monitor (P6 below, macOS): it is the pointer's way out of full screen.
- **FR3** The titlebar background is the window's own colour (`titlebar.background*`, the window tokens, ADR-0039 Q8) with a
  one-point hairline at its foot (`titlebar.rule*`, the apps' toolbar rule), drawn inside the bar. It uses the window's corner radius and rounding power on its top corners,
  is square at the bottom, and the bar and the content join square (macOS: one shape, no curve where they meet);
  the window border and shadow wrap titlebar + content. Hyprland 0.56.2 rounds the surface's four corners with one
  radius, so under the surface the plugin fills the two cut top corners with the bar colour, then draws the content's
  own texture there, unrounded, clipped to the two corner squares. That texture is drawn only where it maps 1:1 onto
  the surface box (no overview or Stages transform, no buffer transform, no viewport crop, the squares inside the
  texture); otherwise the bar colour stays. Known limits (R13 of F2a, 2026-10-22): XWayland windows keep a thin 1-px
  arc at the join (radius 12 and 26, scale 1 and 2; the patch is drawn, the anti-aliased edge of the rounded surface
  still blends with what is behind it, cause not proven); a translucent window (foot at alpha 0.5) shows lighter
  corner squares and the curve (before F2a: dark squares).
  Radius since ADR-0024 lot 2 (C-1): one radius for every window, 17 at rounding_power 2.6 since the note of 2026-11-04
  (20 before; global `decoration.rounding` and the rules `gf-third-party-rounding` and `gf-client-chrome-info-rounding`),
  replacing 26 for `org.grassfield.*` and 12 otherwise. Hyprland 0.56.2 draws `CWindow::rounding()` = rounding x
  rounding_power / 2 (22.1 pt) times the scale, cut to whole device pixels (27 px at 1.25), at the power 2.6: measured
  16.7 pt circle-equivalent at 45° on GF-REF at 1.25, macOS 27's 16.5–16.7. The bar's top corners, the tiling preview
  and the rim (FR57) take that same int (core `windowCornerPx`): the bar rounded 32.5 px up to 33 before, a corner a
  device pixel rounder than the window's edge; the window shadow is the macOS 27 fit (range 68, render_power 4, black 0.25,
  offset 0 16), rendered as that model within 0.023 on GF-REF at 1.25; the window border is macOS 27's dark contact
  pixel, pushed by the shell with the appearance (ADR-0024 note 2026-11-03; `tests/compositor/window_edge.sh`, with and
  without the plugin: the edge and the shadow are not the plugin's). The dark appearance's light inner rim is the
  plugin's (FR57; Hyprland 0.56.2's inner glow cannot draw it: no window rule, no rim along the rounded corners).
  `tests/compositor/chrome.sh` expects the corner's first fill pixel on the diagonal within 1 px of the drawn corner's
  45-degree point (5 px at rounding 17, scale 1; 6 was measured at 20 on 2026-11-03 with the new edge).
- **FR57** The dark appearance's inner rim (ADR-0024 note 2026-11-03; core `WindowRim.*`, glue `WindowRim.*`): in the dark
  appearance every window whose edges Hyprland draws (mapped and shown, not an X11 window that wants no border,
  `decorate` not false) gets 1 pt of white just inside its frame, 0.10 per point on the key window and 0.08 on the others
  (tokens `window.rimDark*`, macOS 27's Appearance Dark captures), in whole device pixels as Hyprland rounds its border
  (`roundf(scale)`: 1 at 1 and 1.25, 2 at 1.5 and 2) with the same light per point (0.125 in the one device pixel at
  1.25). The frame is the surface and, while it is shown, the plugin's titlebar: the rim runs along the bar's top and
  sides, never under its hairline. One `CBorderPassElement` per window from a decoration on Hyprland's OVER layer (after
  the surface, so over the client's edge pixels; under the window's popups): Hyprland's border shader drawn inside the
  frame, its outer arc the window's own corner (Hyprland 0.56.2's `CWindow::rounding()`, decoration.rounding x
  rounding_power / 2 = 22.1 pt, times the scale and cut, core `windowCornerPx`: 27 px at 1.25, at the rounding power) and
  its inner arc concentric, so the
  rim is continuous round the corners; Hyprland draws a border only on its ring's band, so no offscreen pass. None in the light appearance and none in full screen (macOS); Hyprland's maximized mode and Fill keep
  it, inside the frame (a filled window's margins stay the wallpaper). A change of key window or appearance damages the
  rims concerned (their bands). The rim waits for the shell's first `appearance` push after a load; the unload resets
  the pushed appearance and the rims' globals (Hyprland keeps an unloaded plugin's library mapped, its statics would
  survive a reload), so a plugin reloaded in a session turned light draws no dark rim before the push, and a plugin
  without the shell draws none. Without the plugin there is no rim (C2); the unload damages every rim's band, then
  removes it.
- **FR4** Close, minimize, zoom buttons: 14 px circles, 9 px gaps (23 px pitch), first one 9 px from the left
  edge (centres at x 16, 39, 62), vertically centered (y 16); each is hit inside its circle grown by 1/6 of the
  diameter (2.33 px), and the gaps between the buttons stay drag area; colors from `compositor/src/core/Theme.hpp` (close `#E83A52`, minimize `#E6C619`,
  zoom `#2DC47A` (own values as vivid as the macOS lights, shifted to dE 9 or more from every macOS system colour; ADR-0003, ADR-0024 amendment 2026-11-03); background dark `rgba(40,40,44,1)` / light `rgba(236,236,238,1)`, dark in S2).
- **FR4b** Hover glyphs (macOS): while the pointer is over the group of lights (the box of the three hit circles,
  gaps included) of the topmost window under it, all three lights show their glyph: × close, − minimize, + zoom (the
  zoom action; macOS shows + for zoom and arrows for full screen). Glyph box 0.55 of the diameter (8 px at scale 1,
  centred on whole pixels at every scale), strokes 0.12 of the diameter with round caps, black at 50 % over the
  light; active and inactive windows alike. A window drawn by the overview or Stages, or whose input is blocked,
  shows none. Only the titlebars whose hover state changes are damaged.
- **FR4c** Inactive windows (macOS): the lights of every window but Hyprland's focused one are grey
  (`titlebarPalette().inactiveLight`, own values: dark `#5A5A5E`, light `#D1D1D3`; the light reference samples about
  `#D4D4D4`); with the pointer over the group (FR4b) they take their colours and glyphs. A focus change damages the
  titlebars of the window that lost the focus and of the one that got it.
- **FR5** The title is centered on the bar and kept at least 8 px clear of the buttons (symmetric margins);
  it is limited to the remaining width.
- **FR6** A left press on a button arms it; releasing over the same button activates it: close → close the
  window (Hyprland's close action); zoom → Grassfield's Zoom, which is Fill (ADR-0036 D78, tiling.md TL35: the window
  fills the work area as a tile with the tiling margins, and back to its box from before; Hyprland's full-screen mode
  *maximized* toggled without the `window-tiling` feature); minimize → post
  `minimize-request`; the shell, which owns the Dock tile rectangle, answers with
  `hl.plugin.grassfield.minimize(address, rect)` (FR14), or parks the window on `special:minimized` itself
  when the plugin lacks the `minimize` feature.
- **FR7** A left press elsewhere on the bar focuses and raises the window (without warping the cursor) and
  starts an interactive move that follows the pointer from the press point; release ends it. The move (and
  an armed button, FR6) also ends, where it is, on any new press, and on a pointer motion when Hyprland
  reports no held button or a pointer device present at the press has disappeared: a lost release never
  leaves the window following the pointer.
- **FR8** Two presses on the drag area within 400 ms and 4 px do what Settings say
  (`windows.titlebarDoubleClick`, pushed by the shell, FR16): `fill` (default since ADR-0036 D78; the shell sends
  `zoom` without `tiling-arrange`, D36) and `zoom` → the zoom button's toggle (no move; Zoom is Fill, TL35);
  `minimize` → the minimize button's path (FR6); `none` → nothing (the second press is a single press). Before the
  shell's first push the plugin's own default is `zoom`, the same toggle. A press moves the window only after the pointer travelled more than 4 px
  (`kDragThreshold`); a click never writes the window geometry. A drag that starts on a maximized window
  first leaves the maximized mode and places the restored floating size under the pointer (same horizontal
  fraction of the window, same offset on the titlebar), then follows the pointer (macOS).
- **FR9** At load and on `hl.plugin.grassfield.hello()` the plugin posts the socket2 event
  `grassfield>>{"v":"gfc/1","type":"capabilities","features":[...]}`: `decorations` always; `minimize` only
  when the `minimize`/`restore` Lua functions and the minimize render hooks registered; `config` only when the
  `config` Lua function registered; `appmenu` (FR18), `overview` (FR29), `desktop-focus` + `desktop-focus-v2` (FR31),
  `stages-available` (FR33), `cursor-refresh` (FR40), `overview-focus` (FR43) and `layer-pointer` (FR52) likewise;
  `minimize-effect` (FR45) with `minimize` and `config`; `window-tiling` (FR50) when the `tile` Lua function and `config`
  registered; with it, `tiling-arrange` when `arrange`, `hyprctl grassfield-tiling` and the tiling listeners registered and
  `tile-hover` when `tile_popover` and `move_to` registered (`docs/specs/tiling.md` TL6, TL22-TL26), and with
  `tiling-arrange` `tiling-layouts`, `tiling-groups` (when `group_front` registered), `tiling-shared-edge` and
  `tiling-split` (when `split` and `unsplit` registered; TL27-TL33); `appearance` (FR53) with `config`; `client-chrome` (ADR-0015 P2) when the per-window toplevel listeners
  registered; `frame-times` (FR54) when the presentation listeners and `hyprctl grassfield-frames` registered;
  `keyboard-focus` (FR20) with `appmenu`; `stages` only while its flag is on
  (FR33) (`["decorations","minimize","config","appmenu","overview","desktop-focus","desktop-focus-v2","stages-available","cursor-refresh","overview-focus","minimize-effect","window-tiling","layer-pointer","appearance","client-chrome","frame-times","keyboard-focus"]`
  when everything works and the flag is off).
- **FR10** `hyprctl grassfield` returns the capabilities JSON plus one field, `"version"` (the product version of the plugin, from the VERSION file; GF-013), as its last member. The `capabilities` event is unchanged (no `version`): its wire format is fixed by the unit tests.
- **FR54** Presented-frame times (ADR-0006 gate P3): every output's presented frames (Hyprland's
  `CMonitor::m_events.presented`, the presentation feedback) go into a ring of 1024 CLOCK_MONOTONIC microsecond stamps per
  output (`core/FrameLog.*`, `FrameProbe.*`; a stamp not newer than the last is refused). `hyprctl grassfield-frames`
  (exact, read-only, no argument) returns `{"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[{"name",
  "refreshHz","total","presented":[...],"renders":[[beginUs,cpuUs],...]}],"marks":[{"t","what"}]}` (at most 16 outputs,
  names escaped and cut at 64 bytes). Nothing is recorded unless a measurement asked for it (review of part B,
  2026-10-24: frame times on the lock screen give the typing rhythm away, each key redrawing the password dots):
  `hyprctl grassfield-frames-start` (exact, no argument) records for the next 60 s (`frames::kMaxRecordingMs`; a new one
  extends it) and answers `{"v":"gfc/1","type":"frames-recording","recording":true,"ms":60000}`; while the session is
  locked nothing is recorded, the start is refused (`"recording":false`), what was recorded is dropped and
  `grassfield-frames` answers no monitor. `frame-times` is advertised when both commands registered. One push per presented
  frame on the compositor thread, nothing else. For attribution
  (review 2026-10-24: whose cost were the Overview's missed frames?) each output also keeps the CPU span of every frame
  Hyprland rendered (render.preChecks to RENDER_POST, the plugin's draws included, the GPU's time not; 1024 per output),
  and the Overview marks its phases (`overview-opening`, `overview-open`, `overview-closing`, `overview-closed`; the last
  64, names cut at 32 bytes). `tests/visual/presented-frames.sh` measures real shell animations with it (Overview
  open/close, Launchpad open, Dock magnification) through `tests/visual/frame-stats.py`, each over its animation's own
  window (ADR-0006 amendment 2026-10-24, D-5, macOS model: a static screen owes no frames): from the first frame after the
  request to it + the animation's token duration + one refresh period, or to the Overview's end mark when later
  (`tests/visual/animation-windows.py`); the tail after it is reported, never judged. `tests/visual/frame-attribution.py`
  classes each interval over 1.2 periods, in the animation and in the tail: `compositor` (the compositor's own time for its
  frame was over 0.8 period: the render's CPU plus, before that render, the time the event loop was held or ran the
  plugin's own work, outside any render), `client` (the render began more than 0.5 period after the previous presentation,
  the loop free: nothing new to draw until then), `other`. The loop's records (integrator review of a6d04df: a main-loop
  stall before a render shows only as a late render): while recording, an event-loop timer beats every 1 ms
  (`frames::kBeatUs`: a hold is recorded at most one beat short, so a 12 ms hold before a 3 ms render still reads over the
  budget); a beat more than 1 ms late (`kStallUs`, core `stallOf`) records a stall from its due time to the beat, with the CPU time Hyprland's main thread used since the previous beat (`CLOCK_THREAD_CPUTIME_ID`: little CPU is
  the thread waiting, descheduled under load or blocked; about the stall's length is the compositor working); the plugin
  records its own work outside a render (the shared edge's drag steps, `frameProbe::work`); both 1024 spans, dropped with
  the other records. The reply gains `"loop":{"beats":N,"stalls":[[beginUs,lengthUs,cpuUs],...],
  "work":[[beginUs,lengthUs],...]}` after `marks`; `--gate` fails without beats or without the plugin's work, and with
  `--baseline` compares the gated scenario's compositor-caused long frames per second, per window it resizes (the drag's
  own count: the plugin marks each shared-edge drag's end `edge-drag:F/E`, F of the edge's E windows followed it;
  `--drag-mark`, every drag F = E; `--resizes` for the baseline), with the baseline's (tiling.md TL30: the shared edge against Hyprland's own resize, at most 1.25 times per
  resized window, and at most 1 ms of the plugin's work per frame). The
  attribution lists each
  compositor-caused frame with its render's CPU and the loop's held time before it, split into stalls (with the main
  thread's CPU share in them) and the plugin's work, and sums them per scenario (integrator nested pass of ce82fd3).
- **FR11** No exception escapes into Hyprland; window/monitor pointers are null-checked; no blocking I/O.
- **FR12** `PLUGIN_EXIT` removes all titlebars, Lua functions, the hyprctl command and event listeners,
  and ends a drag in progress. Titlebars of unmapped or hidden windows are destroyed too (Hyprland defers
  their removal), and no pointer to a destroyed titlebar stays in Hyprland's plugin bookkeeping.
- **FR13** Input consistency: the plugin never cancels a pointer button event, so Hyprland's held-button
  state always matches the device and the click after any titlebar gesture reaches the window under the
  pointer. Two exceptions, P6 (the revealed titlebar of a full-screen window) and the shared edge's handle between two tiled
  windows of a group (docs/specs/tiling.md TL30; only where Hyprland's pointer-focus hit test finds no window in front of
  it but the edge's own, no popup: the frontmost window under the pointer gets the click): a press on it and the release
  of that press are cancelled together;
  Hyprland returns before its held-button list for a cancelled event, so the pair leaves it as it was. Such a press is
  taken only when no device holds a button already (the bus event names no device), and a release still owed when the
  button is pressed again was lost and is forgotten. Press ownership: a titlebar consumes a release if and only if a titlebar consumed the matching
  press (per button; a new press of a button supersedes an older one) and Hyprland routes that release to
  a titlebar; elsewhere the release reaches the seat, which drops it for a client that never got the press.
  The release of a press that went to a client is never consumed, even over a titlebar.
- **FR14** `hl.plugin.grassfield.minimize(address, x, y, w, h)`: `address` is a string `0x` + 1–16 hex
  digits of a mapped window, `x, y, w, h` (numbers, layout coordinates) the Dock tile. Everything is
  validated (string and number types read without raising Lua errors, address parsed, never dereferenced but
  compared with the live windows, rectangle finite, 1–1024 px per side and fully inside one monitor); the
  function always returns `hl.dsp.no_op()`. An invalid address is ignored; an invalid rectangle means "no
  animation". The window is snapshotted, moved to `special:minimized` at once (same hidden state as the
  shell's fallback), and its snapshot animates into the tile with the configured effect (FR44-FR46). Scale: it
  shrinks uniformly (aspect ratio kept, centered in the tile) and moves into the tile in 300 ms with an ease-in curve
  (cubic Bézier 0.4, 0, 1, 1), fading out over the last 20 %.
  Then `grassfield>>{"v":"gfc/1","type":"minimized","address":"<hex>"}` is posted (at once without
  animation). A window already on `special:minimized` is left alone.
- **FR15** `hl.plugin.grassfield.restore(address, x, y, w, h)`: same validation. A window on
  `special:minimized` moves back to **the display it was minimized from, on the Desktop that display shows now, at its
  frame** (owner decision D-1 2026-10-23, the macOS model; audit GF-001): never to the display of the Dock that was
  clicked. The plugin records the display (the one under the window's middle, else Hyprland's monitor of the window)
  and the floating box when it minimizes the window (core `planRestore`); the record goes with the restore, the window's
  close and a move of the window off `special:minimized` by any other way, and survives a plugin reload only when the
  library stayed mapped (FR23). A display that moved keeps the frame at the same place relative to it; a display that is
  gone hands the window to the focused one, its frame fitted into the area below the menu bar; without a record (a window
  parked by the shell's fallback) the focused display's Desktop takes it and Hyprland's placement stays. A zoomed or
  full-screen window keeps its state, only its display is chosen. The window is focused and raised at once, and stays
  transparent while its snapshot
  plays the configured effect backwards (Scale: grows from the tile to its box in 300 ms, ease-out, the time-reverse
  of FR14's curve, fading in over the first 20 %); then it is shown and `{"type":"restored"}` is posted. A restore
  during a minimize animation (or a minimize during a restore) completes the running one first; a Scale minimize
  interrupting a restore starts from the restore's current box, a funnel one (either way) from the shape on screen.
- **FR16** `hl.plugin.grassfield.config(key, value)`: allowlist `titlebarDoubleClick` = `zoom` | `minimize` |
  `fill` | `none` (`fill`: tiling.md TL32), `appearance` = `dark` | `light` (FR53), `stagesEnabled` (FR33), `minimizeEffect` = `funnel` | `shrink` | `fade`
  (FR45) and the tiling keys (FR50) (exact strings); anything
  else is rejected (logged, no change); returns `hl.dsp.no_op()`. The shell pushes the settings after each
  capabilities event and whenever Settings change.
- **FR17** Minimize robustness: a window closed during its animation drops the animation (no event); a
  monitor removed or the monitor layout changing completes every animation at once; unloading the plugin
  completes every animation (a restoring window is made visible, minimized windows stay on
  `special:minimized` for the shell's fallback), drops the snapshots and removes the render hooks and timer;
  nothing is drawn while the session is locked (the drawing hook is not emitted then).
- **FR18** Appmenu global: at load the plugin advertises `org_kde_kwin_appmenu_manager` version 2 (KDE's
  protocol, `compositor/protocols/appmenu.xml`; version 2 adds the manager's `release`), created with
  `wl_global_create` on Hyprland's display; feature `appmenu` is advertised only when the global and the Lua
  function `appmenu` both registered. Version 1 clients (Qt 6.11, Chromium 152) work unchanged.
- **FR19** `org_kde_kwin_appmenu.set_address(service_name, object_path)` is untrusted input: accepted only when
  the service is a D-Bus bus name (unique `:1.42` or well-known `org.foo.Bar`: at least 2 non-empty
  dot-separated elements of `[A-Za-z0-9_-]`, well-known elements not starting with a number, at most 255 bytes)
  and the path a D-Bus object path (`/` or `/`-separated non-empty `[A-Za-z0-9_]` elements, no trailing `/`, at
  most 255 bytes). Anything else is ignored (no protocol error, the client stays connected; one log line per
  object). Strings are JSON-escaped anyway.
- **FR20** The plugin keeps, per `wl_surface`, the latest valid address (the latest request on any appmenu
  object of that surface wins; releasing an object drops the registration it made) and maps the surface to
  its toplevel window when that window is mapped (comparing `CWindow::resource()`, nothing the client sent is
  dereferenced). It posts `grassfield>>{"v":"gfc/1","type":"appmenu","address":"<hex>","service":"…",
  "path":"…"}`: when a mapped window's registration changes (an unchanged one is not re-posted), when a window
  is mapped with one, and for every focused window (with empty service and path when it has none), coalesced
  per window (FR24). A registration made before the window is mapped is posted at map. `pid` (additive, ADR-0008) is
  the registering client's pid; for a mapped Wayland window without a registration it is that window's client pid
  (`wl_client_get_credentials`), so that the shell can ask the menu bridge for the menu that process registered with
  `com.canonical.AppMenu.Registrar` (Electron, ADR-0008 amendment 2026-10-25); 0 for an X11/XWayland window (its
  Wayland client is Xwayland) and for a clear. With the appmenu server (feature `keyboard-focus`) the plugin also posts
  `grassfield>>{"v":"gfc/1","type":"keyboard-focus","address":"<hex>"}` each time the seat's keyboard focus enters a
  mapped window (Hyprland's `input.keyboard.focus`; once per entry: the window that has it is announced again only after
  the keyboard went elsewhere, a layer surface or nothing). The menu bar sends a chosen item's action when the item's
  window has the keyboard back after the menu closed (docs/specs/menu-bridge.md MB12: an Electron click handler runs for
  its focused window only).
- **FR21** When an announced registration goes away — the window is unmapped (`window.close`) or destroyed,
  the appmenu object is released or destroyed (client exit), or the surface is destroyed — the plugin posts
  the same event with `"service":"","path":""`. A window mapped again on the same surface is announced again.
- **FR22** `hl.plugin.grassfield.appmenu(address)`: `address` as in FR14; for a mapped window the plugin posts
  its `appmenu` event (registration or empty); an invalid or unknown address posts nothing (logged). Returns
  `hl.dsp.no_op()`. The shell calls it after a restart (or a missed event) for the windows it shows.
- **FR23** Unload never leaves a Wayland object pointing into the unloaded library: at compositor shutdown
  (`g_pCompositor->m_isShuttingDown`) every appmenu resource and the global are destroyed in `PLUGIN_EXIT`;
  on a runtime unload with client objects alive the library pins itself (`dlopen(RTLD_NOLOAD | RTLD_NODELETE)`),
  removes the global (`wl_global_remove`) and keeps those objects inert (requests ignored, destructors honored),
  and the shell receives a clear event for each announced window; with no client object the global is simply
  destroyed. If pinning fails the objects are destroyed (their clients get a protocol error at their next
  request on them; logged as an error).
- **FR55** Key paths log nothing (review of part B, 2026-10-24: a line per key while the session was locked gave a
  password's length and rhythm away in hyprland.log). Every listener of `input.keyboard.key` runs through `gf::keyPath`,
  which opens `core/Quiet.*`'s scope: `gf::log` and `gf::logRequest` write nothing while it is open and do not count what
  they drop (the request budget's "held back" count would count keys). `QuietTest.*` checks the scope and fails on a key
  listener of the plugin's sources without it, or on a hook of Hyprland's key handler. What the key paths start and
  log later logs once per state change, never per event: the Overview's keyboard hand-over once per request, Stages'
  "strip window stays active under the lock" once per window and lock.
- **FR24** No request can flood socket2 (R11). Hyprland disconnects a socket2 subscriber whose event queue
  overflows (`Socket2 fd N overflowed event queue, removing`); Quickshell then gets no Hyprland event until it
  restarts. Every plugin → shell event goes through a throttle (`core/EventThrottle.*`, glue `gf::ipc::postEvent`)
  keyed by (kind, window): `appmenu` per window, `minimize-request` per window, `minimized`/`restored` per window
  (one key: two values of one state), `capabilities` (one key). An event replaces a waiting event of the same key
  (the latest wins); a key posts at once when it has not posted in the last 100 ms, otherwise its latest event is
  posted 100 ms after the previous post by a Hyprland event loop timer (`CEventLoopTimer`; trailing edge: the
  final state of a burst is never dropped). Hard caps: 10 posts per key per second (by construction: two posts of
  one key are ≥ 100 ms apart); all keys together 32 at once, then 50 per second (token bucket; waiting events keep
  their latest-submission order, so a key that keeps changing goes behind keys that changed once). Unload posts
  every waiting event, then removes the timer. Log lines that requests trigger (appmenu bind/create/set_address,
  rejected Lua verb arguments, `config`, titlebar presses and actions from any pointer) share one budget of 20 lines, then 1 per second, and the next written line
  reports how many were held back; set_address is logged at the 1st, 10th, 100th, ... request of an object, never
  per request. One exception with a budget of its own (20 lines, then 2 per second, held-back count appended): the
  Dock rectangle of each minimize ("minimize <hex>: toward the Dock rectangle x,y wxh", 0.6.4-stages), which tests read
  to click the tile the shell named; in a soak the shared budget was spent by titlebar and Stages lines.
- **FR25** `hl.plugin.grassfield.overview(json)`: one Lua string of at most 16 KiB, copied out of Lua with non-raising
  calls, parsed by a strict JSON reader (`core/Overview.*`): an object with `on` (bool) and `durationMs` (integer
  0..2000) required, `windows` (array of at most 64 objects `{"address","x","y","w","h"}`: address as in FR14, finite
  numbers, w and h ≥ 1, no address twice) required when `on` is true, optional `curve` (4 finite numbers, x in [0, 1],
  y in [-1, 2]); unknown keys are skipped, a key given twice, nesting deeper than 16, strings over 256 bytes, NaN /
  Infinity / out-of-range numbers and trailing characters are refused. A refused request changes nothing and posts the
  current state with `"reason":"invalid"`. Always returns `hl.dsp.no_op()`. Log lines go through the request log budget
  (FR24).
- **FR26** For `on:true` each listed window is transformed only if it is mapped, not hidden, not pinned, on the active,
  non-special workspace of its monitor, not full screen and not on a workspace that shows a full-screen window
  (`FSMODE_FULLSCREEN`; maximized is allowed; decision 2026-10-18: on macOS a full-screen app is a Desktop of its own, and
  Hyprland draws only the full-screen window on its workspace) and its rect lies inside that monitor (1 px tolerance);
  other entries are ignored (logged). If windows were listed and none qualifies, nothing changes and the current state is
  posted with `"reason":"no-windows"`. Windows are transformed only while the shell's chrome covers them (R13 fix, relaxed
  2026-10-18): every monitor of the qualifying windows has a mapped layer surface with namespace `grassfield-overview`
  (any keyboard interactivity), and the seat keyboard is on such a surface (or one of its popups) whose interactivity is
  `Exclusive` (the focused output's; with every chrome Exclusive, Hyprland refused to give the keyboard back after the
  close on two outputs); otherwise nothing changes and the current state is posted with `"reason":"no-chrome"`. A
  transformed window gets a
  `Render::IWindowTransformer`; the window's main pass (surface, subsurfaces, decorations) is drawn, live, with its
  surface box fitted (uniform scale, centred) into its rect, decorations scaled with it. The client is never resized
  or configured and its window geometry never changes. Popups are not transformed. Snapshots (close / minimize
  animations) and window captures (`RPT_EXPORT`) show the window untransformed; on another monitor a spanning window
  is not drawn.
- **FR27** Windows animate from their live box to their rect (opening) and back from where they are drawn to their
  live box (closing) over `durationMs` with the cubic-bezier `curve` (default 0.2, 0, 0, 1 = the shell's
  `Tokens.motionCurveStandard`), interpolated every frame by the plugin (no per-frame IPC); `durationMs` 0 jumps to the
  end state. `on:true` while open, opening or closing retargets: listed windows continue from where they are drawn,
  windows no longer listed go back at once. Events (FR24 channel `overview`, one key):
  `{"v":"gfc/1","type":"overview","state":"opening|open|closing|closed","windows":N}` with `"reason"` when a request is
  refused (`invalid`, `no-windows`, `no-chrome`), the plugin unloads (`unavailable`), the overview is interrupted
  (`interrupted`) or a window went full screen while shown (`fullscreen`, state unchanged). A window leaving the
  overview while it is shown posts the current state again with the new count.
  A 150 ms watchdog after the expected end completes an animation when no monitor renders.
- **FR28** Damage: each animation tick (`render.preChecks`) damages every window's previous and new visual box (with
  every decoration extent). While an overview is shown, every frame of a monitor that has damage also redraws that
  monitor's layout boxes (added to its damage ring from `render.pre`); without damage no frame is rendered. The box
  drawn in a frame becomes the window's last damaged box (`core damageStep`, R13 fix): a surface resized while open has
  every box it was drawn in damaged again when it leaves it, and the box damaged at detach is the one drawn last. The
  first frame of each such resize burst is logged at debug level (request log budget).
- **FR29** Failsafes and cleanup: a window that closes, leaves its workspace or becomes pinned leaves the overview at
  once; a window becoming full screen takes every window of its workspace out at once (`fullscreen`). A mapped window
  that takes the keyboard from the chrome with a user or other focus reason, or the keyboard leaving the chrome, starts
  the closing animation (`interrupted`); Hyprland moving focus because a window closed or opened does not (the overview
  stays, the shell retargets; Hyprland 0.56.2 emits `window.active` for the closing window itself, reason "other", while
  it refuses the keyboard to the next window because of the Exclusive chrome: measured). A layer surface with namespace
  `grassfield-overview` closing while windows are shown (opening, open, or an interrupted closing) ends the overview at
  once without animation (`interrupted`); a closing the shell asked for runs to its end. A workspace switch that hides a
  transformed window, a monitor removal or a monitor layout change puts every window back at once (`interrupted`).
  `PLUGIN_EXIT` removes every transformer it attached (none may outlive `dlclose`), damages their boxes and posts
  `closed` with `"reason":"unavailable"` before the event throttle stops. Feature `overview` is advertised only when the
  listeners and the Lua function registered.
- **FR30** Desktop focus policy (feature `desktop-focus`, ADR-0012 amendment; contract `docs/specs/desktop.md`
  "Compositor focus policy"): on a pointer button press (event bus `input.mouse.button`, observed, never cancelled,
  FR13), with the press target = the seat's pointer focus resolved to its window or layer surface (subsurfaces climbed,
  popups to their owner; a Grassfield titlebar under the pointer counts as its window). When that pointer focus is
  missing or stale (no surface, a destroyed surface, or one whose view is unmapped or invisible: Hyprland 0.56.2 updates
  pointer focus on motion only, so a click right after a popup closed still finds the popup), the target is the surface
  under the cursor, looked up in Hyprland's pointer focus order (layer popups, Overlay, Top, windows with their popups,
  surfaces and titlebars, Bottom, Background; a window border outside its titlebar and surface counts as nothing; shell
  integration finding, main 9e76bd7). (a) A press on a normal window while the seat keyboard is on a
  `grassfield-desktop-icons` layer surface (any output) gives that window the keyboard through Hyprland's own click focus
  only (`Desktop::focusState()->fullWindowFocus(w, FOCUS_REASON_CLICK)`, which applies `no_focus`, modal children, the
  lock and Exclusive layers); a refusal leaves the keyboard where it is and is logged once (request log budget). The
  surface focus is never forced (R13 review of 5706cbd: the former `rawSurfaceFocus` fallback could bypass such rules).
  (b) A left press on such a desktop surface gives it the keyboard at once when its committed interactivity is
  `on_demand`, else on its first `on_demand` commit within 1000 ms (`CLayerShellResource` commit listener per desktop
  surface). The waiting grant is dropped by any later press and by any other focus change first: a keyboard focus change
  (`input.keyboard.focus`), a window activation (`window.active`, any reason), a window mapping (`window.open`), a
  workspace switch (`workspace.active`) (R13 review of 5706cbd: a late commit must not take the keyboard from what a key
  binding, a dispatch, a new window or a workspace switch chose). (c) Nothing else: no hover handling, presses on other
  `grassfield-*` layers, on popups, during a keyboard grab, an Exclusive layer or the session lock change nothing.
  (d) Click focus for Hyprland's focused window (real-session bug 2026-10-20, packages 0.4.0-3, plugin 0.8.1-clickfocus):
  a press on the window Hyprland counts as its focused window (`Desktop::focusState()->window()`) while the seat keyboard
  is not on it (its surface, a subsurface or one of its popups) gives it the keyboard, any button, with the same refusal
  rules as (a). Hyprland 0.56.2 refocuses on a click only when the clicked window is not its focused window; after a
  session unlock with the pointer off the windows (desktop, menu bar) it keeps its last window focused while the keyboard
  is on no surface, so a click on that window did nothing (`tests/compositor/click_focus.sh lock`). When Hyprland's focus
  state still names the window's surface, `fullWindowFocus` returns early: the state is reset first
  (`CFocusState::resetWindowFocus`) and the focus made again (`gf::deferredFocus::focusWindow`, shared with the
  titlebar; never while Hyprland refuses window focus). The titlebar's own press focus (FR7) tests the keyboard holder,
  not `isWindowActive`. A grant that does not give the keyboard is logged with the reason the plugin can tell: no keyboard
  device on the seat, window focus refused now (lock or Exclusive layer, the plugin then asks nothing), else Hyprland's
  own rules (`no_focus`, a modal child). (e) The keyboard back after an unlock (macOS model, plugin 0.8.2): on
  `CSessionLockManager::m_events.unlock` a refocus is armed for 1000 ms and tried from the event loop: when no surface
  holds the keyboard, Hyprland's focused window (mapped, visible, on a shown Desktop) gets it through the same shared focus,
  reason `FOCUS_REASON_OTHER`. Never while locked, never past an Exclusive layer, never from a holder: a window or layer
  surface that has the keyboard ends it; the lock surface, still alive a moment after the unlock, is waited out (retried
  every 50 ms: its destruction drops the keyboard without any focus event, measured). A press, a new lock or the end of the
  window cancels it; `stop()` removes its event-loop callback and timer. Hyprland 0.56.2 alone refocuses at the cursor only,
  so with the pointer on the desktop or the menu bar the keys typed after an unlock reached no window.
  Decision logic pure (`core/DesktopFocus.*`: press table, target source, pending grant, unlock step).
- **FR31** `desktop-focus` is advertised only when its listeners registered. `PLUGIN_EXIT` removes the button, layer,
  commit and focus listeners and any pending grant before the other teardown steps; the keyboard stays where it is.
- **FR32** Withdrawal: after every hook is removed, `PLUGIN_EXIT` posts `{"v":"gfc/1","type":"capabilities","features":[]}`
  directly (not throttled), so the shell returns to its fallbacks for every feature.
- **FR33** Stages flag and capabilities (`docs/specs/stages.md` ST1-ST2): `config("stagesEnabled", "true"|"false")`
  (exact strings, off at every load; turning it off ends Stages at once); `stages-available` when the Stages listeners,
  `hl.plugin.grassfield.stages` and `config` registered; `stages` only while the flag is on; a flag change re-posts the
  capabilities.
- **FR34** `hl.plugin.grassfield.stages(json)`: one Lua string of at most 8 KiB, copied out of Lua with non-raising calls,
  parsed by the strict JSON reader (`core/Json.*`, shared with FR25) and validated by `core/Stages.*` (ops `on`, `off`,
  `activate`, `merge`, `move`; limits in the spec's contract item 3); refused while the flag is off (`disabled`), when a
  strip's monitor, surface or input region does not cover its tiles (`no-strip`), when a stage or window does not exist
  (`unknown`), or when invalid (`invalid`). Always returns `hl.dsp.no_op()`; log lines through the request log budget.
- **FR35** Stages model and drawing (ST3-ST16): the model lives in the plugin (per workspace, recency order, grouped by
  window class); windows of strip stages stay mapped at their real places, are drawn live into their tiles by a
  `Render::IWindowTransformer` (drawing shared with the overview, `WindowTransform.*`) and get the plugin's input block
  reason (`CWindow::setInputBlocked`, bit `1 << 6`), so Hyprland's hit test skips them; no client is moved, resized or
  configured; swaps animate over the `durationMs`/`curve` of the latest `op:on`; Hyprland's window, focus, workspace,
  layer and monitor events keep the model in step (applied through one coalesced `doLater` per event loop pass, also for
  activate / merge / move requests: a dispatch causes at most one focus change).
- **FR36** Stages notice and state (ADR-0007 amendment 2026-10-24: Hyprland cuts socket2 events at 1024 bytes): the event
  is a change notice, `{"v":"gfc/1","type":"stages","gen":N,"on":bool}` (FR24 channel `stages`, one key; at most 100
  bytes), and the state of that generation, `{"v":"gfc/1","type":"stages","gen":N,"on":bool,"monitors":[…]}`, is the reply
  of `hyprctl grassfield-stages` (registered with the plugin, removed at unload; `stages-available` needs it). Both carry
  `reason` as in FR34 plus `interrupted` (a strip surface went away or the monitors changed: that monitor's windows are
  shown normally at once) and `unavailable` (unload). Since 0.6.4-stages each monitor also names the front window of the
  shown Desktop's active stage and its app (`"front":{"address","app"}`, additive; app sanitized to valid UTF-8, at most
  256 bytes), re-posted when it changes: the menu bar's source while Hyprland has no active window (ST24).
- **FR37** Stages cleanup: `PLUGIN_EXIT` (and turning Stages off) removes every Stages transformer before `dlclose` and
  lifts every input block, removes the pending `doLater` callbacks (model sync, pointer refresh) and the watchdog timer,
  and posts `on:false`/`unavailable` before the event throttle stops; `start()` resets the flag and the model (the library
  may have stayed mapped since a previous load, FR23).
- **FR38** Stages input guards (ST6, ST9, ST10, ST23; R13 review of 46b3e9b): no pointer, scroll or key event reaches a
  strip window. Whenever a block changes the plugin re-runs Hyprland's pointer focus logic at the cursor
  (`CInputManager::simulateMouseMovement` plus a pointer frame; from the event loop inside layer-unmap and monitor paths;
  skipped while no pointer device exists, since Hyprland then refuses any pointer focus change); its first pointer button
  listener (`main.cpp`, before the titlebar and desktop focus code) and a scroll listener refresh a pointer focus still on
  a strip window, or clear it while a held button pins it there; a key listener applies a pending sync and moves a
  keyboard focus still on a strip window to the active stage's front window, or to nothing. Button events are never
  cancelled. When the focused window leaves the active stage (close, minimize, move) Hyprland's successor keeps the
  keyboard only if it may hold it; otherwise the active stage's front window, else nothing. Hyprland's `FFM` focus of a
  strip window (restoring its last window) does not bring its stage forward. The desktop focus policy counts a pointer
  focus on a window that does not take input as stale. Decision logic pure (`core/Stages.*`: `beforePointerEvent`,
  `keyboardAfterLeave`, `stripFocusBringsStage`; `core/DesktopFocus.*`: `classifyPointerFocus`). A transformed window
  without a free work buffer is drawn as nothing that frame (`WindowTransform.cpp`), never at its real place.
  R13 counter-review of 17208af (ST24, ST6 menus, ST10): Hyprland's active window is never a strip window (checked after
  every retarget and before every key); a menu (popup grab) of a window going to the strip ends as a click outside it
  would (`CSeatManager::setGrab(nullptr)`); only real user focus reasons bring a strip stage forward (reasons mapped one
  to one, `focusOrigin`; `WORKSPACE_CHANGE` is a restore only for the workspace's last focused window). R13
  counter-review #3 of e9ebc7f (ST23, ST24): while Hyprland refuses window focus (an Exclusive layer is mapped, the session
  is locked) the plugin requests none and changes none of Hyprland's lists: a strip window is cleared from Hyprland's
  active window (`CFocusState::resetWindowFocus` plus Hyprland's "no active window" notifications, keyboard holder,
  monitor, Desktop and special workspace untouched) and the incoming front window is focused once the layer released the
  keyboard, checked again then. `resetWindowFocus` also forgets Hyprland's focus surface, which `rawSurfaceFocus` cannot
  set again while the seat's keyboard is on that layer (it returns at once; read from the binary).
  Keyboard focus before every key (integrator decision 2026-10-24, by the macOS model: a modal system prompt always gets
  the keyboard and there is always a key window; wlr-layer-shell: an Exclusive Top or Overlay surface gets every key).
  Hyprland 0.56.2 drops a keyboard focus change while the session has no keyboard device (`CSeatManager::
  setKeyboardFocus`: "BUG THIS: setKeyboardFocus without a valid keyboard set") and gives a keyboard device that appears
  only its own focus surface (`CInputManager::setupKeyboard`), both read from the binary; in a session whose keyboards
  come and go (a keyboard plugged in, a Bluetooth keyboard reconnecting, an on-screen keyboard) every key was lost after
  a swap under a dialog and after it (stages.sh 8c, 8f, 8g, 8h, 8i(e): the three nested runs whose session had no
  keyboard device of its own failed, the thirteen with one passed). So before every key, Stages on or off
  (`keepKeyboardFocus`, core `keyFocusAction`): the frontmost mapped Exclusive layer (Hyprland's list; the highest
  layer, the latest among equals) on Top or Overlay gets the keyboard when the seat's keyboard is not on it or one of its
  popups; with no Exclusive layer, Hyprland's active window (mapped, shown, taking input, not a strip window) gets it back
  when the seat's keyboard is on nothing. The layer rule also runs from the event loop after Hyprland changed the
  keyboard focus, a layer surface mapped, or a keyboard device appeared (its layout set): Hyprland 0.56.2 gives a surface
  that takes the keyboard on demand the keyboard when it maps, even over an Exclusive dialog, and a key that arrives right
  after `wl_keyboard.enter` can be lost by the client, so the keyboard goes back before the next key (stages.sh 8j: with
  the check before keys only, the first key after such a banner mapped was lost). Through Hyprland's own
  `rawSurfaceFocus`; Hyprland's focus event for the plugin's own move is not taken as a new cause. A session whose only
  keyboard device goes and comes back (the nested session when the parent seat had no keyboard: every `keys.sh` burst is
  a new device; a Bluetooth keyboard reconnecting on a desktop): clients re-create their `wl_keyboard` each time, and a
  Quickshell (Qt) client then ignores the keys of the new one (nested 2026-10-24, with the plugin unloaded: a Quickshell
  layer surface and a Quickshell window got the first burst only, foot every burst; after a keyboard leave/enter cycle the
  Quickshell window got the next one). So when a device replaces the previous one while no other keyboard is left, the
  surface that holds the keyboard gets `wl_keyboard.leave` and `enter` again as soon as its client's re-created
  `wl_keyboard` exists (every `wl_seat` the client bound, through libwayland's list of its resources, checked every 10
  ms for at most 500 ms after the device appeared; Qt 6.11 activates a window only after a `wl_display.sync` round trip,
  so a key sent in the same batch as the enter is dropped: an announce made in the key path lost the first key of every
  burst, the integrator's keyboard-less run of 2026-10-24); else, as a fallback, before the device's first key, and
  that key can then be lost (a key stops a pending announce; the fallback is skipped when the timer already announced
  that device); to that same surface
  (`reannounceKeyboardFocus`, core `reannounceFocus`; not under an input method's grab or with the keyboard on nothing;
  unlocked, not under a seat grab; Hyprland's focus state untouched). While locked, or when the lock state is unknown
  (integrator decision 2026-10-24: a lock screen gone deaf after a desktop's only keyboard reconnected at resume is a
  lock-out; "failures stay locked" never allows a deaf password field): only when the surface that holds the keyboard is
  a session-lock surface (`CSessionLockManager::isSurfaceSessionLock`), to that same surface, and only when a seat grab, if
  any, accepts it; the surface that has the keyboard never changes and nothing else is given it
  (`tests/security/lock_keyboard_replaced.sh`). NOT VERIFIED in a session without a keyboard of its own (a nested session
  that came up with no WAYLAND-1 output, so no backend input until the parent presents its window): the announce made
  once the new `wl_keyboard` exists has run only in sessions with a keyboard (no regression there); in the one
  keyboard-less run so far (2f3d408, key-path announce) the first key of every burst was lost. When the fallback runs,
  the first key of the burst can be lost: on the lock screen that is a password without its first character, one wrong
  password attempt. Owner check (L2, real session): with only an external keyboard, lock, unplug and replug the keyboard,
  then type the password; it must unlock at the first attempt. The focus rules above never act while the session is locked or
  its state is unknown (a missing lock manager counts as locked: failures stay locked), never under an input method's
  keyboard grab, never against a seat grab that rejects the surface (checked first: Hyprland would log a refusal per
  key); a Bottom or Background Exclusive layer keeps Hyprland's normal focus, and no window gets the keyboard while an
  Exclusive layer is mapped. Only while the plugin is loaded (the key listener goes with it); nothing allocated, nothing
  logged per key (the common case returns after two reads). On unload, Hyprland's focus surface is set again to the
  Exclusive layer that holds the seat's keyboard after the plugin cleared it (the seat leaves it for an instant), so a new
  keyboard device keeps the keys there without the plugin. stages.sh 8j: a keyboard device that appears under the layer
  after a swap. Decision logic pure: `activeWindowAction`, `pendingFocusAction`, `focusOrigin`, `keyFocusAction`,
  `replacesFrontmost`.
  R13 counter-review #4 of 0.6.3-stages (ST10 clicks, ST23, ST24): Hyprland reports `FOCUS_REASON_CLICK` for every
  refocus at the cursor (`CInputManager::refocus`, also when a layer unmaps with no active window), so a `CLICK` focus
  is a user choice only when a press caused it: the plugin records pointer button presses (its first button listener),
  touch downs and tablet tip/button presses before Hyprland handles them (`recordPress`, `clickFromPress`: a press
  counts while Hyprland handles it; with an Exclusive layer mapped, a press beside every Exclusive layer on a window
  counts for that window's refocus once the layer is gone). Hyprland's own pick while a focus is deferred neither drops
  it nor raises a window of the active stage; the deferred focus goes to the front window of the remembered Desktop's
  active stage (the remembered window, or the one in front now if it went away). Clearing the active window also runs
  `CWindowRuleApplicator::propertiesChanged(RULE_PROP_FOCUS)` and `CInputManager::recheckIdleInhibitorStatus`.
- **FR39** Cursor refresh (Settings › Accessibility › Pointer, ADR-0014; `docs/specs/settings.md` Pointer):
  `hl.plugin.grassfield.cursor_refresh()` (no argument; any argument is ignored and nothing is read from Lua; returns
  `hl.dsp.no_op()`) draws the pointer on screen again at the size Hyprland holds now. The shell calls it after its
  `setcursor <theme> <size>` was answered `ok`: Hyprland 0.56.2's `CCursorManager::changeTheme` loads the theme at the new
  size but leaves the image on screen until a client sets a shape again. The plugin re-applies the image Hyprland shows the
  way `IHyprRenderer::setCursorHidden(false)` does (read from the 0.56.2 binary):
  `IHyprRenderer::setCursorFromName(m_lastCursorData.name, true)` (same name, same shape index, image loaded again from the
  theme at its current size; the pointer position is not touched). Only when the decision (`core/CursorRefresh`, pure) is
  `redraw`: Hyprland renders the pointer (`shouldRenderCursor()`; a forced `setCursorFromName` bypasses Hyprland's hidden
  state, so it is never called while the pointer is hidden), the last image is not a client's own surface
  (`m_lastCursorData.surf` empty: a client surface carries its own image and size, and a client that hid its pointer with
  `wl_pointer.set_cursor` without a surface reads like this on 0.56.2), a named shape is recorded (no guessed default) and
  at least one monitor exists. Otherwise nothing is done (`hidden`, `client-surface`, `no-shape`, `no-output`).
- **FR40** Cursor refresh rate and lifecycle: the first request of a quiet period runs at once; requests within 25 ms of the
  last run are folded into one trailing run when the interval ends (a Hyprland event loop timer), so the last size is
  always drawn and a flood costs at most one run per 25 ms. Log lines through the request log budget: one when the outcome
  or the shape changes and at 1, 10, 100, … runs or folded requests. `cursor-refresh` is advertised when the Lua function
  registered and Hyprland's renderer exists; `PLUGIN_EXIT` removes the timer and the Lua function.
- **FR41** Overview close focus request (`docs/specs/overview.md` "Close focus"): `hl.plugin.grassfield.overview_focus(json)`,
  one Lua string of at most 512 bytes copied out of Lua with non-raising calls, parsed strictly (`core/OverviewFocus`:
  `{"target":"window","address":"0x…"}`, `{"target":"workspace","workspace":N}`, `{"target":"remembered","address":"0x…",
  "workspace":N?}`, `{"target":"none"}`, optional `"id"` 0..2^32-1; addresses 1-16 hex digits, not 0; workspaces 1..2^31-1;
  a field the target does not use, a key given twice or trailing text is refused; unknown keys skipped). A refused payload
  posts outcome `invalid` and changes nothing; a valid one replaces a waiting request and posts `pending`. Request log lines
  share the request log budget.
- **FR42** Overview close focus behaviour: the request waits while Hyprland refuses window focus (its Exclusive-layer list is
  not empty, read only; the shared `deferredfocus::mustWait`), tried from the event loop after every commit of a mapped layer
  surface (commit listeners on each `CLayerShellResource` while a request waits, and on layers that map meanwhile), a layer
  unmap, a keyboard focus change and the session lock, and synchronously before every key; bounded by 1 s (a timer: outcome
  `timeout`). Under the session lock: outcome `refused`, nothing focused. Once Hyprland accepts window focus the target is
  checked again: a named window that is mapped, not hidden, not on a special workspace and on a shown Desktop is focused with
  `CFocusState::fullWindowFocus(w, FOCUS_REASON_DISPATCH_FOCUSWINDOW)` (as `hl.dsp.focus({window = …})` after its Desktop
  switch, without its cursor warp); when Hyprland counts that window focused without the keyboard (its own focus attempt
  under the chrome was refused), `resetWindowFocus()` then the same focus again. A Desktop shown: its front window; not shown:
  `Config::Actions::changeWorkspace(ws)` (exported, the path of `hl.dsp.focus({workspace = …})`; never for the Desktop already
  shown, so `workspace_back_and_forth` cannot apply), then its front window; no window: Hyprland's active window and the
  keyboard cleared (`fullWindowFocus(nullptr)`, then `rawSurfaceFocus(nullptr)` if the keyboard stayed on a released chrome)
  unless an `on_demand` layer holds it, and that monitor focused. Fallback (window gone, minimized, hidden, not shown, Desktop
  missing, focus refused by Hyprland, target `none`): the front window of the remembered Desktop when shown, else of the
  Desktop on Hyprland's focused monitor, else no window. Front window: eligible windows (on the Desktop, mapped, not hidden,
  `acceptsInput()`, not `m_X11ShouldntFocus`) by their last focus since the load (`window.active`), then the stack top down
  (pure `frontOrder`); each candidate Hyprland refuses (a rule) is skipped. A press after the request (pointer button from the
  plugin's first button listener, touch down, tablet tip/button; `deferredfocus::recordPress` on the shared press context)
  beside every Exclusive layer on a window retargets to it; a press while Hyprland accepts window focus, or a `window.active`
  user choice of another window, ends the request (`superseded`). Events: channel `overview-focus` (FR24),
  `{"v":"gfc/1","type":"overview-focus","outcome":"pending|focused|fallback|timeout|refused|superseded|unavailable|invalid",
  "target":"…","id":N}` plus `address`, `workspace`, `reason`. Decision logic pure (`core/OverviewFocus`: `parseRequest`,
  `step`, `judgeWindow`, `plan`, `fallbackSpace`, `frontOrder`, `pressEffect`, `supersedes`, `eventJson`).
- **FR43** Overview close focus lifecycle and sharing: `overview-focus` is advertised when its listeners and the Lua function
  registered. `PLUGIN_EXIT` (before the event throttle stops) ends a waiting request with outcome `unavailable`, removes its
  listeners, commit watches, event-loop callback (`deferredFocus::CLater`) and timer; `start()` resets everything (the library
  may stay mapped, FR23). The deferred-focus core is shared with Stages: `core/DeferredFocus` (focus reasons and origins, press
  records, the refusal gate) and `DeferredFocus.*` (Hyprland's refusal checks, keyboard holder, cursor on an Exclusive layer,
  press context, reason mapping, coalesced event-loop attempt); Stages uses them unchanged (same conditions, order and doLater
  semantics; `gf::stages` keeps aliases).
- **FR44** Funnel effect (setting value `funnel`, the default; internal name Genie: `core/Genie.*`, drawn by
  `GenieDraw.*`; comparable to the macOS genie, with its own mesh, curves and name): the window's visible box goes into its
  visible box fitted into the Dock tile (`fitInside`) in 500 ms. Model in the Dock frame (axis along = toward the Dock
  edge, across = parallel to it): each window row (fraction v) lies between the far edge (window top) and the near edge
  (window bottom); the near edge travels to the tile's far side over the first 50 % (ease-in-out cubic), the far edge
  slides to the tile's near side from 25 % to the end (ease-in quad). A funnel gives each depth its span across: the
  window's span above the window's far edge, the tile's from the tile's near side on, a smoothstep S-curve between;
  spans blend from the window's own span into the funnel over the first 40 % (the sides pinch, then the body slides
  down through the neck). Progress 0 is exactly the window, 1 exactly the target, every point moves monotonically
  (along: toward the Dock; across: toward its end place), rows never cross and never invert. The Dock edge is the side
  of the tile's monitor closest to the tile (bottom today; top, left and right use the same math). The snapshot is drawn
  on a 32 x 96 quad mesh (96 along the curved sides) covering the window's full box (shadow included, clipped to the
  snapshot) with a GLES 3 textured shader, opacity 1 until the last 15 % (minimize) / from the first 15 % (restore).
  A restore is the minimize played backwards (progress 1 -> 0, same curves). The funnel is used only when it can be
  drawn: GL renderer, the custom element drawn (FR46), the snapshot's monitor untransformed, the tile's far side beyond
  the window's far edge (`isGenieGeometry`); otherwise that animation runs the shrink (Scale) effect.
- **FR45** Effect setting (`dock.minimizeEffect`, Settings > Desktop & Dock > "Minimize animation": "Funnel" | "Shrink";
  fr "Animation de réduction": "Entonnoir" | "Rétrécissement"; Grassfield's own wording, not the macOS strings):
  `hl.plugin.grassfield.config("minimizeEffect", "funnel" | "shrink" | "fade")`, accepted only while `minimize` is
  available; the feature `minimize-effect` tells the shell the key exists (older plugins reject it, so the shell sends it
  only then). The shell sends `fade` while `accessibility.reduceMotion` is on (no funnel, no movement, as macOS does with
  Reduce Motion): the snapshot fades out (minimize) or in (restore) at the window's own place in 100 ms
  (`Tokens.motionReducedMax`), linearly. Default before any push: `funnel`. A change applies to the next animation (a
  running one keeps its effect). Shift held on any keyboard (`getModsFromAllKBs() & HL_MODIFIER_SHIFT`) when an
  animation starts plays it 10 times slower (as macOS Shift-click slow motion), for every effect. Dev fault injection:
  `hl.plugin.grassfield.config("testFault", "funnel-shader")` is honoured only in a dev session by the run-mode rule
  (ADR-0019, `core/RunMode.hpp`): Hyprland's environment has `GRASSFIELD_DEV=1` and not `GRASSFIELD_SESSION=1` (the
  nested dev session; the installed session sets `GRASSFIELD_SESSION=1` with `hl.env`, which calls `setenv` in
  Hyprland's own process, so a leaked `GRASSFIELD_DEV=1` opens nothing there; `tests/RunModeTest.cpp` over the shared
  vectors), never advertised; the next funnel draw compiles a broken shader so that FR46's failure path runs
  (`tests/compositor/genie.sh` step 6).
- **FR46** Funnel drawing safety: the element (type `EK_CUSTOM`, pass name `CGrassfieldGenieElement`, `draw()` called by
  Hyprland while it renders the pass, after the windows and before the top layers) scissors every draw to the frame's
  damage (nothing is drawn outside it), saves and restores the GL program, vertex array, array buffer, active texture and
  2D texture bindings around its draw, and goes through Hyprland's cache-aware blend and scissor calls. Its GL objects
  (program, vertex array, vertex and index buffers) are created at the first draw and deleted at unload with Hyprland's EGL
  context current. The funnel is disabled for the plugin's life (one error line) by a shader compile or link failure, a
  GL error raised by a funnel draw (bounded `glGetError`: at most 8 calls drain the flags left by earlier GL work before
  the draw, at most 8 check after it), or 10 funnel elements added without a single `draw()` call; at the next tick
  every running funnel animation continues as a shrink one from the same share of its duration (never as nothing). A
  plugin load forgets an earlier failure. `PLUGIN_EXIT` removes queued funnel elements from Hyprland's render pass
  (`CRenderPass::removeAllOfType` by pass name, `m_renderPass` and the current pass) before anything else: unload never
  runs inside a frame, so the pass is normally empty, and this covers a frame that queued elements without rendering
  them. Each finished animation logs one timing line (own log budget, FR24): effect, duration, frames on the snapshot's
  monitor, frame interval avg / max, CPU time per frame (render.preChecks -> RENDER_POST) avg / max, longest funnel draw
  (CPU), and `speed normal` or `speed slow` (tests separate slow-motion animations by it, never by duration).
- **FR47** Window tiling by dragging (macOS 15+, owner request 2026-10-22): during a titlebar drag (the plugin's own
  move, FR6/FR8) the pointer within `kEdge` (4 px) of a FREE left or right edge of an output tiles the window into that
  half of the output's free area (`logicalBoxMinusReserved`: the menu bar and the Dock left out); also within
  `kCorner` (96 px) of the output's top or bottom, into that quarter; the pointer on the menu bar strip (the output's
  top reserved area) fills the free area. An edge shared with another output never tiles (the drag moves the window
  over). Not for full-screen, maximized, pinned or tiled-by-layout windows. Pure logic `core/Tiling.*`
  (`placeForPointer`, `surfaceFor`), unit tests `TilingDrag.*`, `TilingPlace.*`. Since tiling step 2
  (`docs/specs/tiling.md` TL16-TL20): Hyprland's own move (an app's toolbar drag, Super+drag) tiles the same way, a tiled
  window it drags away takes back its size from before (the drag ended and begun again), Alt held gives the nearest half,
  quarter or fill anywhere (`dragPlace`), the titlebar drag snaps like Hyprland's move away from a place, and a
  double-click on a resize border extends that side (with Alt the opposite one too; Alt on a corner fills).
- **FR48** Preview: while the release would tile, the place's frame (titlebar included) is drawn under the dragged window
  and over the windows behind it (the titlebar decoration's DECORATION_LAYER_UNDER pass) as the **blurred material**
  (owner decision D-8, macOS's frosted pane; audit UX-07 / GF-027): an edge of `kTilePreviewRim` px in the appearance's
  rim colour, and inside it Hyprland's own blur of what is behind (`CRectPassElement` with `blur`, live, not xray: the
  windows behind count) under the appearance's material tint (tokens `titlebar.previewTint*`, `previewRim*`, FR53),
  corners at the window's rounding. Since tiling step 2 the place shows after the pointer rested on it for
  `tiling.previewDelay` (at once with Alt, TL17), and Hyprland's moves draw the same preview through the window's
  decoration, also under a client-chrome window whose bar is hidden. One blurred element, drawn only while a drag has a place; with Hyprland's blur
  disabled in the config the tint is drawn alone. Old and new frames are damaged when the place changes and when the
  gesture ends or is cancelled. Measured by `tests/compositor/tiling.sh` (a pattern window behind the preview keeps under
  30 % of its detail; an alpha-only pane keeps about 55 %).
- **FR49** Placement: the release sets the surface box (`setTargetGeom`) to `surfaceFor(place)`: margins `kMargin` (8)
  around and between the tiles when "Tiled windows have margins" is on, the titlebar (`kTitlebarHeight`) inside the
  frame below the menu bar. The box from before the FIRST tiling is remembered (per window, forgotten when the window
  goes, on unload); a later drag of a tiled window gives that size back under the pointer at the same relative place
  (like the un-zoom, `unzoomedDragBox`). `hl.plugin.grassfield.tile(address, place)` places a window the same way for
  the Window menu (Fill, Center, Move & Resize: halves, quarters) and the keys Super+Ctrl+arrows; place `previous`
  returns to the remembered box (Return to Previous Size, Super+Ctrl+R; centred on the window's output now when the old box lies off every output). The output is the one under the window's middle (Hyprland does not see the plugin's own drags, R13; since tiling step 1 the end of such a drag, and a tile onto another output, give the window the Desktop of the output under its middle, as Hyprland's own move does, tiling.md TL21). Since tiling step 1 (`docs/specs/tiling.md` TL1-TL15) every placement uses the work area read at that moment (Stages strip column left out), edges on the output's device-pixel grid, the window's limits, a half beside a tiled neighbour, and a tile record per window that follows the TL10 state machine (a user resize through Hyprland keeps it; a move, an app's own configure or a keyboard move ends it); `hl.plugin.grassfield.arrange(json)` fills a layout of the catalogue (TL6) and `hyprctl grassfield-tiling` returns the records. Since tiling step 3 (TL22-TL26) the pointer resting on a window's zoom
  light (the titlebar's, or a Grassfield app's own at its token place) for `tiling.hoverDelay` posts `tile-hover` (enter,
  then leave; no light counts while the session is locked, while an Exclusive layer other than the shell's popups is mapped
  or while a Top or Overlay layer covers the pointer), `hl.plugin.grassfield.tile_popover(address)` posts it as `open` for the keyboard, and
  `hl.plugin.grassfield.move_to(address, output)` moves a window onto another output (a tiled one into the same tile
  there; refused while locked). Since tiling step 6a (TL33) `hl.plugin.grassfield.split(address, side)` makes a Split View
  Desktop (the next free workspace id on the window's output, shown; the window in that half of the whole output) and
  `hl.plugin.grassfield.unsplit(address)` sends a member back to the Desktop it came from, into its tile there when its zone
  is free (both refused while locked); the plugin keeps each Split View Desktop's members (whatever their state), fills the
  one left, ends one without a member (at the unlock when locked), and refuses the tiling of a member; the zoom light of a
  member leaves the Split View, and a member's lights are those of full screen (its minimize light grey and inert, ADR-0036
  D56). `split` and a pick into a Split View's other half refuse a window whose minimum size does not fit that half; the
  `tile-hover` event says it (`splittable`, D57) and the state reply lists such windows (`unfit`, D57 amended); a window of
  fixed size posts no `tile-hover` and `tile_popover` is refused for it, the reply listing it (`fixed`, tiling.md TL24,
  ADR-0040 step 1b). Step 6b: a
  double-click on the separator (the shared edge between the two members) puts both back to equal halves (D60); a member
  dragged by its titlebar swaps halves with the other when released over it, else goes back in its half (D59). Step 6c:
  after an output goes away, a floating window left off every output (Hyprland moves only the removed output's Desktops)
  comes back centred on the work area of its Desktop's output at its size (D67; not a full-screen, Stages strip or
  minimized window; one INFO line each), and the revealed titlebar of a full-screen window posts `titlebar-reveal` (P6,
  D65). Step 6d: `unsplit(address[, how])` also takes Make Window Full Screen ("fullscreen": home, then full screen there)
  and Replace Tiled Window ("replace": home without showing it, the other member waiting again with the suggestion of the
  vacated half from that Desktop's windows but the one replaced; refused with one member), feature `tiling-split-rows`
  (D71). Step 6e: a member's titlebar is away and no band is kept above it (D73, feature `tiling-split-titles`); the pointer
  at the top edge over its half reveals that half's bar (P6, per half, the other half's coming across the band, the gap
  between the halves the revealed bar's own, D74), and a left press on the revealed bar away from its lights drags the
  member, hanging below its bar (D75: swap over the other half, else back in its half; another press, a pointer device
  gone, the lock or the unload ends it). A window that leaves a Split View any way gets its titlebar band below the menu
  bar (D73 amended). Untrusted: fixed-size strings, the address
  compared with live windows, the place and the side from fixed lists, the output name checked and compared with the live
  outputs.
- **FR50** Settings (macOS Desktop & Dock > Windows, all on by default; tiling.md TL32): `windows.tilingEdges` ("Drag
  windows to left or right edge of screen to tile"), `windows.tilingMenuBar` ("Drag windows to menu bar to fill screen"),
  `windows.tilingOptionDrag` ("Hold Alt key while dragging windows to tile"), `windows.tilingMargins` ("Tiled windows have
  margins"), pushed with `hl.plugin.grassfield.config("tilingEdges" | "tilingMenuBar" | "tilingOptionDrag" |
  "tilingMargins", "true" | "false")` once the plugin advertises `window-tiling`; `windows.tilingLayouts` ("Show layouts
  when hovering over the green button": off, the hover tracker posts no `enter`; `tile_popover` still posts `open`) with
  `tile-hover`, and `windows.tilingSuggestions` ("Suggest windows to fill the rest of a layout": off, an arrangement keeps
  no suggestion and the pending one is dropped) with `tiling-layouts`; core `tiling::switchOf` maps the keys.
  `windows.tilingGroups` ("Bring tile groups forward together") is the shell's alone (ADR-0036 D38). Without the plugin
  (C2) the shell shows no tiling items and the keys do nothing; drags move windows as Hyprland does.
- **FR56** A window's titlebar never goes under the menu bar (macOS; owner report from the 1.0.0-rc1 real session:
  Chromium dragged up until its tab strip was under the menu bar could not be grabbed again). For floating windows (not
  full screen or zoomed), on every output, with the plugin's titlebar (a 32 px band above the surface) or the app's own
  (client chrome, ADR-0015: no band, the surface top): the frame's top is held at the bottom of the menu bar strip (the
  output's top reserved area) of the output the frame's top edge is on (the one sharing most of its width when the edge
  crosses several; when the edge is on no output, above the outputs or in a gap between them, the nearest output below it
  that shares some of its width; the output under the pointer only when neither exists), so a window can always be
  grabbed again. The top edge decides, not the pointer: a SUPER+drag (`config/hypr/grassfield/bindings.lua`) or a resize
  grips the window anywhere (review of e0a3734: with the output under the pointer, a window sitting correctly on an upper
  output was moved onto the lower one, or cut, at the release). Only the top is held: a window may hang off the sides or
  the bottom. A titlebar drag by the plugin holds it at every step (the window stops at the menu bar while the pointer
  goes on, and follows it again on the way down); a pointer on the menu bar still tiles to fill (FR47). Hyprland's own
  interactive move and resize (an app's `xdg_toplevel.move`/`resize`, a mouse binding) have no hook during the drag: the
  release of the button that ends one (seen before Hyprland handles it) schedules one callback after Hyprland ended the
  drag, which moves the window down (a move) or stops its top edge at the menu bar, the bottom edge kept (a resize that
  moved the top edge: the window's box at the drag's first motion, recorded by the plugin's motion listener, is compared
  with the box at the end; a resize from the bottom or a side edge, or one never seen moving, is left alone). Hyprland's
  drag itself is left alone. Since the 1.0.0-rc6 report ("the window stuck on the menu bar is still there"), the cases
  the drags did not cover, measured in nested: a window moved to a Desktop of another output (the Overview, a key: Hyprland's
  move to a workspace) that does not fit that output's work area keeps it inside the output and bottom-aligned, its
  titlebar under the menu bar (a filled window from a 1440 x 900 output onto a 1536 x 864 one: titlebar top at y 3, menu
  bar bottom 24); it is now made to fit and held below the menu bar once Hyprland placed it (tiling.md TL21); so is a
  window dropped where its tile was refused (the clamp had left it to the tile); and when the shell's menu bar maps on an
  output (the session's start, the shell back after a restart) every window placed while it was away and now under it goes
  below it (`layer.opened` of `grassfield-menubar`, read after events). Not covered: windows placed by keyboard moves or
  resizes (they never reach the clamp), and an X11 app that places itself under the bar after it mapped (placement.lua's
  `fit` holds it at map). Pure:
  `core/TopClamp.*` (`tests/TopClampTest.cpp`); glue `TopClamp.*`; nested `tests/compositor/top_clamp.sh`. Without the
  plugin (C2) nothing holds the top: Hyprland's behaviour.
- **FR51** Pointer focus on the shell's layers (feature `layer-pointer`, plugin 0.12.0-pointer; integrator finding 2026-10-22,
  `docs/specs/menubar.md` "Known limitations": a click with no pointer motion since a bar menu opened reached no surface).
  Cause (Hyprland 0.56.2, measured, and read from the binary): when a layer surface takes the keyboard (`CLayerSurface::onMap`
  for a layer mapped Exclusive, or OnDemand while the pointer is not constrained; `CLayerSurface::onCommit` when a mapped
  layer becomes so) Hyprland releases the held buttons, gives it the keyboard and gives it the pointer focus at once with the
  surface-local position cursor - (layer `m_geometry` + monitor `m_position`). The layer geometry is already in layout
  coordinates, so on an output that is not at the layout origin the monitor offset counts twice: on GF-REF (x = 1440 in the
  nested session) the menu overlay was told the pointer at x - 1440. `CInputManager::mouseMoveUnified` skips the rest of its
  work while the cursor's floored position is unchanged, so until the pointer moved by a whole pixel a click was delivered
  there, outside the overlay. On WAYLAND-1 (at 0,0) the same clicks worked without the plugin (measured). A layer that maps
  without taking the keyboard gets no pointer focus at map (read from the binary, not measured): the surface below keeps it.
  Behaviour: when a layer surface whose namespace is `grassfield-` followed by a non-empty name maps (event bus
  `layer.opened`) or gets the seat keyboard (`input.keyboard.focus` on the layer surface itself, not a popup), the plugin
  re-runs Hyprland's pointer focus logic at the cursor (`CInputManager::simulateMouseMovement`, which shifts Hyprland's last
  floored cursor position by one pixel and runs `mouseMoveUnified`, then `CSeatManager::sendPointerFrame`): the surface
  under the cursor gets `wl_pointer.enter`/`motion` at its right position, exactly what one pixel of motion does (Hyprland's
  rules apply: constraints, the lock, `follow_mouse`, blocked Stages windows). It runs once per burst, from Hyprland's event
  loop (both events come before Hyprland sets the miscomputed focus). While a button is held (a menu opens on the press and
  maps while the button is down; Hyprland keeps the pressed surface) it waits for the release and runs from the event loop
  after Hyprland handled it; without a pointer device it runs before the next press (the plugin's first button listener,
  before Hyprland handles that press; also a press read in the same event loop pass as the map). Other clients' layers and
  every other path are untouched; no event or button is ever cancelled. Unmaps need nothing: `CLayerSurface::onUnmap`
  already calls `simulateMouseMovement` (read from the binary; measured: a click without motion after the menu closed
  reaches the window under the pointer, with and without the plugin). Decision logic pure (`core/LayerPointer.*`:
  `isGrassfieldNamespace`, `CRefreshState`). Only a keyboard that MOVES to a Grassfield layer counts, and what a refresh
  itself causes is never a new reason: Hyprland sets the keyboard focus again on the on-demand layer under the cursor (the
  desktop icons) on every refresh, and counting that looped for ever (stages.sh on 2026-10-23: 10 million refreshes after a
  press on the desktop, the nested compositor stopped answering IPC, its log grew to 3.3 GB). A backstop bounds the
  event loop's refreshes to 20 a second: over it the refresh stays owed and its attempt runs again from an event-loop timer
  when the second is over (`attemptAt` → `Defer`; logged at the 1st, 10th, ... deferral). It is never dropped (a dropped
  refresh left the next press at the stale position, reviewer 2026-10-23), and a press is never deferred (the user's,
  it cannot loop). `beginRefresh`/`endRefresh` wrap Hyprland's code in a scope guard.
- **FR52** `layer-pointer` (no verb; the shell needs no change) is advertised when its two listeners registered, after
  `window-tiling` in the list. `PLUGIN_EXIT` removes the listeners, the scheduled event-loop callback
  (`deferredFocus::CLater`) and the budget timer before `dlclose`; `start()` resets the state (the library may stay mapped, FR23). One DEBUG log
  line at the 1st, 10th, 100th, ... refresh (request log budget, FR24).
- **FR53** The chrome follows the appearance (audit UX-06; feature `appearance`, advertised with `config`): the shell pushes
  `hl.plugin.grassfield.config("appearance", "dark" | "light")` (the appearance it shows, `Appearance.dark`) after each
  capabilities event and when it changes; the plugin draws every titlebar (bar, title, grey lights of inactive windows)
  and the tiling preview (FR48) in that appearance's palette and redraws them at once (the title textures are rebuilt).
  The colours are design tokens: `ui/tokens/tokens.json` group `titlebar` (both appearances), generated by
  `ui/tools/gen-tokens.py` into `compositor/src/core/ThemeTokens.hpp` (`--check` fails on a stale header, run by `just
  check-shell`), read by `core/Theme.hpp titlebarPalette`. Until the shell pushes it the appearance is dark (Grassfield's
  default); an older shell never sends the key, an older plugin rejects it (the shell sends it only with the feature).

## Acceptance criteria (each mapped to a test or scenario; level L0/L1/L2)

| FR | Test / scenario | Level | S2 result |
|---|---|---|---|
| FR1 | Code review of `PLUGIN_INIT`; scripted mismatch test (C2) | L0 / L1 | match path verified (log); mismatch path NOT VERIFIED |
| FR2 | nested: open foot → screenshot | L1 | verified (floating); tiled/full-screen hiding NOT VERIFIED |
| FR3 | unit `ContentCornerPatch.*`; nested `tests/compositor/chrome.sh` (junction count, 4x corner crops) | L0 / L1 | 2026-10-22, Hyprland 0.56.2: pixels of the cut top corners that differ from the content 0 / 0 for foot (radius 12) and Settings (radius 26); before the content-texture corners 21 and 98 per corner (`.dev/chrome/run-20261022-101750` vs `run-20261022-133902`) |
| FR4 | unit `TitlebarLayout.*`, `Theme.*`; nested `tests/compositor/chrome.sh` (lights, bar, corners measured on GF-REF captures) | L0 / L1 | verified; F2a geometry (32-px bar, 14-px lights, 23-px pitch, first centre (16, 16); radius 26 for org.grassfield.* (global decoration.rounding), 12 otherwise (rule gf-third-party-rounding)) 2026-10-22, Hyprland 0.56.2: `chrome.sh` PASS (lights within 0.05 px of their centres, 13.9 px across; 32 rows; getprop rounding 12 / 26; corner insets 4 px (radius 12) and 8 px (radius 26), the titlebar's top corners with them; C2 without the plugin: the same radii) |
| FR4b | unit `ButtonGroup.*`, `GlyphSize.*`, `GlyphMask.*`; nested `tests/compositor/chrome.sh` | L0 / L1 | 2026-10-22: glyphs on all three lights with the pointer between two lights (active window, inactive window, Settings), none with the pointer away |
| FR4c | unit `LightColor.*`; nested `tests/compositor/chrome.sh` | L0 / L1 | 2026-10-22: inactive foot 148 grey px per light and no glyph; coloured with glyphs while the pointer is on its lights; the active windows coloured |
| FR5 | unit `TitlebarLayout.Title*`; screenshot with long and short titles | L0 / L1 | verified |
| FR6 | nested: virtual pointer clicks on close / zoom / minimize; press on close + release elsewhere; `tests/compositor/minimize.sh` | L1 | verified (close closed the window; zoom toggled `fullscreen` 0↔1; cancel kept the window). Minimize (2026-10-17): the button posted `minimize-request`, the shell answered with `hl.plugin.grassfield.minimize`, the window went to `special:minimized` (see FR14) |
| FR7 | nested: virtual pointer drag, window position before/after; abandoned drag (pointer tool exits after `down drag`, its device is destroyed) then move and click elsewhere with a new pointer | L1 | verified: press (500,186) → release (600,286) moved the window (370,200) → (470,300), cursor not warped. Abandoned drag (2026-10-17): before the fix the window followed the unpressed pointer and jumped to the next click; after it the window stays where the drag left it, the next click lands on the desktop, log `titlebar gesture cancelled: no button held or a pointer device went away` |
| FR8 | unit `ClickTracker.*`, `DragThreshold.*`, `UnzoomedDragBox.*`; nested `tests/compositor/zoom_restore.sh`, `tests/compositor/double_click_setting.sh` | L0 / L1 | Setting (2026-10-17, `double_click_setting.sh` PASS): `minimize` → window on `special:minimized`, `none` → geometry and mode unchanged, `zoom` → maximize then restore 700×500 at (610,264). Zoom: verified: `fullscreen` 0 → 1, titlebar kept on the maximized window. Restore by double-click on the maximized bar (2026-10-17): before the fix `fullscreen` 1 → 0 but the window kept the maximized box (1920×980 at the work-area origin) because the first click started a titlebar move whose release wrote the maximized box into the floating geometry (a single click on the maximized bar followed by the zoom button did the same); after the fix (no geometry write below the drag threshold; a drag on a maximized window un-zooms it under the pointer) double-click restores 700×500 at (2050,264), the original place; click + zoom button restores it too; a drag on the maximized bar from 25 % of its width to (1000,400) on GF-REF un-zoomed the window to 700×500 with its surface at (2265,414): pointer at 25 % of the width, 14 px above the surface (on the titlebar); a normal drag moves by exactly (+100,+150). Scenario: `tests/compositor/zoom_restore.sh` |
| FR9 | spike `spikes/s2-ipc/shell.qml` (Quickshell `rawEvent`); unit `Protocol.OnlyRegisteredFeaturesAreAdvertised`; shell log | L0 / L1 | verified for `hello`; 2026-10-17 shell log `compositor plugin present, features: decorations,minimize,config`; load-time event not observable |
| FR10 | `hyprctl grassfield` against the nested instance | L1 | verified: `{"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config"]}` (2026-10-17) |
| FR11 | code review; `clang-tidy` (Q1); C1 soak `tests/compositor/soak.sh` | L0 / L1 | see "Performance (gates affected)" |
| FR12 | `just plugin-unload` (needs `scripts/nestctl`); nested shutdown (SIGTERM → `CCompositor::cleanup` → `unloadAllPlugins` → `PLUGIN_EXIT`, then dlclose, then windows destroyed) with windows on `special:hidden` | L1 | runtime `hyprctl plugin unload` NOT VERIFIED (no `scripts/nestctl`); shutdown with 2 windows on `special:hidden`: log `[grassfield] grassfield-compositor unloaded`, `Hyprland has reached the end.`, no core dump. Hidden (`isHidden()`) / unmapped-window path: code inspection only |
| FR13 | unit `PointerGesture.*`; nested `tests/compositor/input_consistency.sh` (two mouse-reporting foot windows: fast titlebar drag and close-button press moved away on C, then a click inside B) | L0 / L1 | 2026-10-17, 3 rounds (6 gestures): before the fix (releases cancelled on the bus) FAIL, exit 1: all 6 clicks inside B were delivered to C at its edge (`[<0;1;1M`/`m`), B got none; after the fix PASS, exit 0: B got all 6 clicks (`[<0;13;8M`/`m`), C got no button event, 2 seat warnings `sendButton release on a non-pressed button` (the dropped releases). Also after the fix: double-click maximize, zoom-button restore, drag (+140,+150 exact), close press moved away (window kept), close click (closed) |
| FR14 | unit `MinimizeAddress.*`, `MinimizeTarget.*`, `MinimizeGeometry.*`, `MinimizeEasing.*`, `MinimizeFrames.*`, `MinimizeSnapshot.*`; nested `tests/compositor/minimize.sh` | L0 / L1 | 2026-10-17, `minimize.sh 20` PASS exit 0 (run `.dev/minimize/run-20261017-065654`): titlebar button → `minimized` event, window on `special:minimized`, Dock tile appeared (the Trash moved exactly one slot right: 0 px differ; the new slot differs from the Trash by 421/2304 px); move → `minimized` event 368 ms (animated); a capture during the animation shows the window at ≈90 % size moving toward the target (`minimize-frames.png`). Earlier back-to-back captures (`.dev/shots/minimize-burst.png`) show the shrink across 3 frames. Without a valid rectangle (the shell's Dock target outside the current monitor layout after the nested WAYLAND-1 window was resized) the move → event time is ≈0 ms: minimized without animation, as specified |
| FR15 | same | L0 / L1 | same run: click on the Dock tile → `restored` event 395 ms after the move back (animated), window back at 700×500 (610,264) on workspace 2 and focused (`activewindow`); captures during the animation (`restore-frames.png`, `.dev/shots/restore-burst.png`) show it growing from the target. Rapid repetition: 20 minimize + restore rounds, every 4th restore clicked 120 ms after the minimize click: 0 missing events, final geometry unchanged; a second run of 60 rounds on a fresh instance: PASS (22 + 26 of them animated before the nested WAYLAND-1 window was resized, the rest without animation) |
| FR16 | unit `Protocol.ConfigAllowlist`, `tst_minimized` `configCall`; nested `double_click_setting.sh` | L0 / L1 | 2026-10-17 PASS (see FR8). Push after the handshake: before the fix the shell's first push was skipped (`features` is assigned before `pluginPresent`, so `has("config")` was still false); after it the shell logs `compositor setting titlebarDoubleClick = minimize` right before `plugin present` and a fresh plugin honored it |
| FR18 | `hyprctl grassfield`; plugin log; `WAYLAND_DEBUG` of clients (`tests/compositor/appmenu.sh`) | L1 | 2026-10-17 verified: features `["decorations","minimize","config","appmenu"]`; log `appmenu: org_kde_kwin_appmenu_manager version 2 advertised`; Qt and Chromium see `wl_registry.global(69, "org_kde_kwin_appmenu_manager", 2)` and bind version 1; the edge-case client binds version 2 and releases the manager without error |
| FR19 | unit `AppmenuBusName.*`, `AppmenuObjectPath.*`, `AppmenuAddress.*`, `Protocol.AppmenuJson*`; nested `appmenu.sh edge-cases` | L0 / L1 | 2026-10-17 verified: 15 invalid requests (empty, missing parts, space, `..`, leading number, `:1`, Latin-1 byte, relative path, `//`, trailing `/`, `-` in a path, JSON-breaking quotes, 299-byte name and path) ignored, client still connected (roundtrip without error), no event |
| FR20 | unit `AppmenuRegistry.*`; nested `appmenu.sh qt-registrar`, `chromium` | L0 / L1 | 2026-10-17 verified: Qt sent `set_address(":1.1", "/MenuBar/1")`, released it, then `set_address(":1.1", "/MenuBar/2")`, both before map; the plugin posted one event right after `openwindow` with `/MenuBar/2`; Chromium's second window (File > New window clicked through DBusMenu) got its own event (`/com/canonical/menu/3`); focus path verified in run `run-20261017-113205` (`activewindowv2` → appmenu event, empty strings for an unregistered window) |
| FR21 | unit `AppmenuRegistry.*`; nested `appmenu.sh` | L0 / L1 | 2026-10-17 verified: File > Quit through DBusMenu → `closewindow` then the clear event (same address, empty strings); killed apps (all variants) → clear event |
| FR22 | nested `appmenu.sh qt-registrar` (Quickshell `Hyprland.dispatch`, `tests/compositor/appmenu-reemit/`) | L1 | 2026-10-17 verified: three calls (the window, `"0xnot-hex"`, `"0x1"`) → exactly one event, for the window; log `appmenu: rejected: invalid window address`, `appmenu: no mapped window 1 (or appmenu inactive)` |
| FR23 | nested shutdown with live appmenu clients (`scripts/dev/nested-down.sh`); code review | L1 | 2026-10-17 shutdown verified: `appmenu: global and 5 client object(s) destroyed (shutdown)`, `Hyprland has reached the end.`, no core dump; runtime unload NOT VERIFIED (no `scripts/nestctl`) |
| FR24 | unit `TokenBucket.*`, `EventThrottle.*`, `LogLimiter.*`, `LogMilestone.*` (timer simulated, time injected); nested `tests/compositor/event_flood.sh` (`appmenu-client --spam N`: a mapped window, N valid set_address on one object in one burst, last path `/MenuBar/final`; one Lua dispatch with 1000 `hello()` + 1000 `appmenu(<window>)`; after each flood a foot window with its own app id must become the menu bar's window, `qs ipc call menubar bridgeState`) | L0 / L1 | 2026-10-17. Before the fix (plugin at 6791eea, run `.dev/event-flood/run-20261017-174942`, exit 1): 200 requests → 200 `appmenu` events; the Lua flood → 491 `capabilities` + 490 `appmenu` events (and 491 `config` pushes back from the shell), `Socket2 fd 52 overflowed event queue, removing` (the shell) and `fd 87` (the test's socat), the shell's menu bar stuck on an old window, 202 plugin log lines. After (run `.dev/event-flood/run-20261017-185707`, exit 0): 200 requests → 2 events (`/MenuBar/1`, then `/MenuBar/final`), 25000 requests (sent in 83 ms) → 3 events ending with `/MenuBar/final`; Lua flood → 2 `capabilities` + 2 `appmenu`; no overflow line, no shell event socket error, the shell showed each new foot window; 14 plugin log lines for 25200 requests + 2000 Lua calls |
| FR25 | unit `OverviewRequest.*`, `OverviewEvents.Json`; nested `overview.sh` check "invalid" | L0 / L1 | 2026-10-18 verified: 6 malformed payloads (missing fields, bad address, duration 99999, not JSON, 1e999, a number instead of a string) → `"reason":"invalid"`, state unchanged (`closed`), Hyprland alive; one Lua dispatch with 500 open/close pairs → 2 overview events posted, socket2 subscriber still connected, final state `closed`, windows at their place (run `run-20261018-003207`) |
| FR26 | unit `OverviewBounds.*`, `OverviewGeometry.*`; nested `overview.sh` check "sizes", "layout", "live", "invalid" (rect outside the monitor + unknown window → `no-windows`) | L0 / L1 | 2026-10-18 verified (run `.dev/overview/run-20261018-001222`): at/size of 6 windows identical before / during / after; terminal colour at 6/6 rect centres while open (1/6 before); the ticker's rect changed by 2233 px between two open frames, an idle window's by 0 px |
| FR27 | unit `OverviewTiming.*`, `OverviewGeometry.Interpolation*`; nested `overview.sh` check "events", frames during the 900 ms animations | L0 / L1 | 2026-10-18 verified: `opening` (6) → `open` (6), `closing` (6) → `closed` (0); a frame 250 ms into opening differs from before (214400 px) and from open (64237 px) |
| FR28 | nested `overview.sh perf 30` (9 windows) | L1 | 2026-10-18: open idle 0.3 % Hyprland CPU, open with one terminal printing 10 lines/s 6.4 % (3.7 % closed), continuous open/close 12.2 % (docs/specs/overview.md "v2 spike" (d)) |
| FR29 | nested `overview.sh` check "failsafe", "restore", "unload" | L1 | 2026-10-18 verified: fixture surface closed → `closing`/`closed` `interrupted`; after `on:false` the output matched the frame before (0.35 px, menu bar masked); `scripts/nestctl plugin unload` during an open overview: rc 0, Hyprland alive, windows back at their place, `closed`/`unavailable` posted; `plugin load` again → features include `overview` |
| FR26-FR29 (R13 fix) | unit `OverviewEvents.NewReasons`, `OverviewFocus.*`, `OverviewChrome.*`, `OverviewDamage.*`; nested `overview.sh` check (29 checks) | L0 / L1 | 2026-10-18, plugin 0.5.0-df, run `.dev/overview/run-20261018-085303`: **29/29 PASS** (the f12f610 script had 20 checks, not 21). On:true without the chrome → `no-chrome`, no `opening`; chrome mapped with keyboard None → `no-chrome`; closing the active window while open → no `closing`, `open`/6 posted, terminal grey at 6/6 remaining rects; a window going full screen → `open`/0 `fullscreen`, then on:true → `no-windows`; resize while open: damage log `open box height 351, box damaged at the start of the shrink 491` (with the fix reverted, run `run-20261018-084158`: `none`, FAIL; captures show no stale pixels either way); chrome unmapped (process alive) → `closed`/`interrupted` with no `closing`; chrome keyboard → None → `closed`/`interrupted`; process exit → `closed`/`interrupted`; flood and unload with the chrome mapped PASS |
| FR30-FR32 | unit `DesktopFocusPolicy.*`, `DesktopFocusLayers.*`, `DesktopFocusGrant.*`, `Protocol.WithdrawnCapabilitiesHaveNoFeature`; nested `tests/compositor/desktop_focus.sh` (`check`, `baseline`) | L0 / L1 | 2026-10-18, plugin 0.5.0-df, run `.dev/desktop-focus/run-20261018-085225-check`: **21/21 PASS**: last active foot clicked while the desktop holds the keyboard gets the keys; click the desktop then type at once 5/5 to the desktop; hover Dock / menu bar / a window and presses on Dock / menu bar keep the keys on the desktop; last active foot on the other output gets the keys; menu grab untouched (keys to the menu, Esc back to the desktop, outside click swallowed, next click on that foot works); unload while the desktop is focused: rc 0, empty capabilities posted, keys still reach the desktop, a click on another foot works, reload advertises `desktop-focus` and the policy works. All 22 window grants worked with `fullWindowFocus` alone (the `rawSurfaceFocus` fallback was not needed), 0 "NOT granted". `baseline` (plugin unloaded, run `run-20261018-080056-baseline`): the three review defects reproduce (keys typed after clicking the last active foot reach the desktop, also across outputs; 0/5 keys reach the desktop when typed right after its click) |
| FR30 (R13 minors + shell finding, 2026-10-18) | unit `DesktopFocusGrant.*` (focus events cancel or fulfil a waiting grant), `DesktopFocusTarget.*` (stale or missing pointer focus falls back to the surface under the cursor); nested `desktop_focus.sh` cases 7 and 8 (`check`, and `race` / `stale` against any loaded build) | L0 / L1 | Baseline plugin e066a19 (loaded with `nested-up.sh --no-plugin` + `scripts/nestctl plugin load`): `stale` FAIL (`desktopA=pf`: the click on the foot after menu → pointer onto the foot → Esc left the keys on the desktop), `race` 1/4 (run `run-20261018-135258-race`: the late `on_demand` commit took the keyboard from the window a focus dispatch
had just focused, 7a `desktopA=ka`, and from a new window, 7b `desktopA=kn`; 7c PASS. An earlier 7a used ALT+TAB, which is
not bound for the virtual keyboard in nested: foot received `ESC TAB`). Fixed build: `desktop_focus.sh check` **26/26 PASS** (runs `.dev/desktop-focus/run-20261018-121710-check`, `run-20261018-142147-check` on the final 0.6.0-stages build), `race` 4/4 (plugin log `cancelled (keyboard focus moved)`, `cancelled (window opened)`). The `rawSurfaceFocus` fallback is removed; `no_focus` windows are skipped by Hyprland's hit test, so the refusal path is reached only for rules applied while the pointer rests on a window (not exercised) |
| FR30 (d) (real-session click bug, 2026-10-20) | unit `DesktopFocusPolicy.PressOnHyprlandsFocusedWindowWithoutTheKeyboardFocusesIt`, `.HyprlandsFocusedWindowThatHasTheKeyboardOrCannotTakeItIsLeftAlone`, `.HyprlandsFocusedWindowWaitsForLockGrabAndExclusiveLayers`; nested `tests/compositor/click_focus.sh check` (and C2 with the plugin unloaded) | L0 / L1 | 2026-10-20/21, plugin 0.8.1-clickfocus, Hyprland v0.56.2 (efb50993): unit 235/235; `click_focus.sh` clients **14/14** (foot, Qt grassfield-settings, GTK4 nautilus, Chromium and Electron obsidian on Wayland, Chromium on XWayland: content and titlebar) and unlock **6/6** (pointer on the desktop, the bar, the window; content and titlebar; plugin log `press (button 0x110) on window … (pointer focus, Hyprland's focused window) while the keyboard is on none -> keyboard to the window`). Pre-fix build 0.8.0-ovfocus (0a4fb5a, loaded from another path with `scripts/nestctl plugin load`): unlock with the pointer on the desktop or the bar **0/4** (keys lost, A stays Hyprland's active window), the owner's symptom. Regressions: `desktop_focus.sh` 26/26, `window_stacking.sh` PASS. The shell-timing cases (`closed`, `menubar`) depend on how fast the shell's commits land: in a loaded nested session (load 3.5 to 6.7 on 8 CPUs) a closed surface stayed mapped 0.1 to 8 s and some runs lost a case to that |
| FR30 (d)/(e) follow-up (R13 findings on 0f3adf7) | unit `DesktopFocusUnlock.*` (focus when no surface holds the keyboard, never from a holder, wait for the lock surface, never while locked or past an Exclusive layer, armed window); nested `click_focus.sh check` sections `layer` (on-demand layer fixture `tests/compositor/click-focus-fixture`) and `unlock` | L0 / L1 | 2026-10-21, plugin 0.8.2-clickfocus, Hyprland v0.56.2 (efb50993): unit 239/239; `unlock` **15/15** (keys back in A with no click, 0 lost letters, pointer on the desktop, the bar, the window; plugin log `after the unlock the keyboard was on no surface: window … -> keyboard to the window`); merged 0.8.1 (0f3adf7, loaded from another path): keys with no click **0/4** with the pointer off the windows (the click cases pass); `layer` 2/2 on 0.8.2 and 0.8.1, **0/2** on 0.8.0-ovfocus (0a4fb5a). A first 0.8.2 build without the 50 ms retry also failed 0/4: the attempt found the lock surface still holding the keyboard and no focus event followed its destruction |
| FR26 (relaxed chrome rule) | unit `OverviewChrome.*`; nested `overview.sh` two-output case | L0 / L1 | 2026-10-18, plugin 0.6.0-stages, runs `.dev/overview/run-20261018-130541` and `run-20261018-142052` (final build): **32/32 PASS**: chrome Exclusive on GF-REF and None on WAYLAND-1 → opens with 7 windows; a click at the WAYLAND-1 window's real place reaches nothing; after the close the previously active window gets the keys |
| FR33-FR37 | unit `Stages*`, `Protocol.StagesFeaturesFollowAvailabilityAndTheFlag`; nested `tests/compositor/stages.sh` (`check`, `perf`) | L0 / L1 | 2026-10-18, plugin 0.6.0-stages, run `.dev/stages/run-20261018-141943-check`: **40/40 PASS** (detail and CPU table in `docs/specs/stages.md`); plugin 0.6.1-stages run `.dev/stages/run-20261018-200428-check`: **45/45 PASS**; plugin 0.6.2-stages runs `.dev/stages/run-20261019-080913-check` (GF-REF only) and `run-20261019-082610-check` (two outputs): **51/51 PASS**; plugin 0.6.3-stages runs `run-20261019-140152-check` (two outputs) and `run-20261019-131100-check` (GF-REF only): **58/58 PASS** |
| FR38 (R13 review of 46b3e9b) | unit `StagesInput.*` (pointer guard decisions, keyboard after a leave, strip focus origin), `DesktopFocusTarget.PointerFocusOnABlockedWindowIsStale`; nested `stages.sh` 5b (click without motion after a swap), 7b (after a new window), 8b (swap under an Exclusive layer), 12b (minimize the only window of the active stage), 12c (`cycle_next` stays in the active stage); `minimize.sh stages`; `soak.sh 660 stages` | L0 / L1 | 2026-10-18, plugin 0.6.1-stages, Hyprland v0.56.2 (efb50993): stages.sh 45/45, `minimize.sh stages` PASS (O gets the keys after A, alone in the active stage, is minimized), soak PASS; the pre-fix build fbacf15 fails the 5b, 8b and 12b sequences (scratch probe, `docs/specs/stages.md` acceptance) |
| FR38 (R13 counter-review of 17208af) | unit `StagesInput.HyprlandsActiveWindowNeverStaysOnAStripWindow`, `StagesInput.OnlyRealUserFocusIsAChoice`, `StagesInput.ADesktopSwitchRestoringItsLastWindowIsNotAChoice`; nested `stages.sh` 8c (window actions after a swap under an Exclusive layer), 8d (strip menus), 8e (`WORKSPACE_CHANGE`) | L0 / L1 | 2026-10-19, plugin 0.6.2-stages: stages.sh 51/51 (twice); the pre-fix build b7f0c3d fails 8c (both checks) and 8d (the swap check) in the same session (`.dev/stages/run-20261019-081839-check`) |
| FR38 (R13 counter-review #3 of e9ebc7f) | unit `StagesInput.UnderAnExclusiveLayerTheActiveStripWindowIsOnlyCleared`, `StagesInput.ADeferredFocusWaitsForTheLayerAndIsCheckedAgain`, `StagesInput.HyprlandsActiveWindowNeverStaysOnAStripWindow`; nested `stages.sh` 8c (no window or monitor focus under an Exclusive layer, `close()` closes no window), 8f (special workspace), 8g (Desktop not shown), 8h (polkit-like dialog) | L0 / L1 | 2026-10-19, plugin 0.6.3-stages: stages.sh 58/58 on two outputs (three runs) and GF-REF only; the pre-fix build ffdef45 51/58 in the same session (8c, 8f, 8g, 8h first check; `.dev/stages/run-20261019-130127-check`, `run-20261019-130612-check`); `soak.sh 1260 stages` and `soak.sh 1260` PASS |
| FR36, FR38 (R13 counter-review #4 of 0.6.3-stages) | unit `StagesInput.ARefocusAtTheCursorWithoutAPressIsNotAClick`, `APressIsAClickWhileHyprlandHandlesIt`, `APressBesideAnExclusiveLayerChoosesTheWindowPressed`, `ADeferredFocusFallsBackToTheFrontWindowNow`, `StagesEvents.TheFrontWindowAndItsApp`, `ClientTextIsSanitized`; nested `stages.sh` 8i (refocus at the cursor over an unrelated window, the stage's back window, empty desktop; remembered window closed; a click beside the layer or just after it wins; `front` in the event) and 8c (a focus-matched window rule rechecked) | L0 / L1 | 2026-10-19, plugin 0.6.4-stages, Hyprland v0.56.2 (efb50993): stages.sh **66/66** on the headless pair GF-REF + GF-REF2 (`.dev/stages/run-20261019-165827-check`) and on GF-REF only (`run-20261019-170037-check`), WAYLAND-1 disabled; the pre-fix build 3a1a7a8 (0.6.3-stages) **60/66** in the same session (`run-20261019-170310-check`: 8c rule, 8i(a) both checks, 8i(b), 8i(d), 8i(e) just after); after the merge with cursor-refresh (plugin 0.7.1-stages): 66/66 on the pair (`run-20261019-174116-check`) and GF-REF only (`run-20261019-174322-check`); `soak.sh 1260 stages` PASS (735 rounds, 92 minimize/restore pairs through the Dock, Hyprland exit status 0 only at `nested-down.sh`); details in `docs/specs/stages.md` "Fix pass 4" |
| FR39-FR40 | unit `CursorRefresh.*` (12); nested `tests/compositor/cursor_refresh.sh check` / `baseline` / `stress` | L0 / L1 | 2026-10-19, plugin 0.7.0-cursor, Hyprland v0.56.2 (efb50993), theme grassfield-cursors: `check` **PASS** 3 runs (`.dev/cursor-refresh/run-20261019-153210-check` final): a still arrow over the desktop 15×21 → 29×41 → 57×82 → 15×21 px (heights ×1.95 / ×3.9, back to the identical first image, 0 px differ), a still I-beam over foot 10×20 → 20×40 → 38×78 → 10×20, w/h kept (arrow 0.71, I-beam 0.50), `cursorpos` unchanged, image anchored at the hotspot; foot's hide-when-typing pointer stays hidden after a size change and a refresh (plugin outcome `client-surface`), shown again by a motion at the size applied meanwhile; 30 calls at 10/s + a 1000-call flood: 2 runs for the flood, `1/10/100 request(s) folded` logged, same image; unload: features `[]`, the still pointer keeps 24 px; load: grows again. `baseline` on `nested-up.sh --no-plugin` **PASS**: `hyprctl grassfield` "unknown request", 0 `[grassfield]` log lines, shell "ready degraded", every size sent (`pointer /setcursor grassfield-cursors N`), no script error, the still pointer keeps 24 px at 48/96, also after desktop → Dock → desktop, and shows 96 after an I-beam round trip. `stress 880` next to `soak.sh 900`: 7499 calls, 250 size changes, 0 failed (see C1) |
| FR41-FR43 | unit `OverviewFocus*` (request validation, gate, target plan, fallback Desktop, front window order, presses, user focus, events, capability: 11), `DeferredFocus*` (3; the Stages cases run through the aliases); nested `tests/compositor/overview_focus.sh check` / `baseline` / `stress`; `stages.sh`, `overview.sh`, `desktop_focus.sh`, `minimize.sh`, `soak.sh` (C1) | L0 / L1 | 2026-10-19, plugin 0.8.0-ovfocus, Hyprland v0.56.2 (efb50993): `check` **66/66 PASS** on the headless pair GF-REF + GF-REF2, WAYLAND-1 disabled (`.dev/overview-focus/run-20261019-194052-check`, final build; `run-20261019-192909-check`): letters reach exactly the target for the window active at open (three release orders), a window on the other output (chromes mapped or unmapping), the current Desktop, a Desktop on the other output, another Desktop, a closed and a minimized target (fallback), a press beside the remaining chrome, a polkit-like dialog during the close (its field gets the letters, `timeout`; a short one: the target after it), the lock (`refused`, nothing typed, no window focused); invalid payloads, a 300-request flood (one outcome), unload while waiting (`unavailable`, reload advertises the feature). `baseline` (the verb a no-op): old build 0.7.1-stages and `--no-plugin` both **32/44**, safety PASS (`run-20261019-201004-baseline`, `run-20261019-200901-baseline`): the targets on the other output, another Desktop and the press get nothing, keys lost after a closed or minimized target. Regressions on the same builds: `stages.sh` **66/66** (pair, `.dev/stages/run-20261019-193039-check`; final build with GF-REF + WAYLAND-1, `run-20261019-200634-check`), `overview.sh` 32/32, `desktop_focus.sh` 26/26, `minimize.sh` PASS |
| FR17 | nested `minimize.sh` step 4; code review; unload path | L1 | 2026-10-17: a window killed 100 ms into its minimize animation and another killed 100 ms into its restore animation: both gone, the other window unaffected, nested Hyprland alive, no core dump of its PID. Monitor removal and runtime plugin unload mid-animation: NOT VERIFIED (no hotplug in nested; no `scripts/nestctl` for `plugin unload`); shutdown with the plugin loaded: see FR12. Lock screen: code inspection only (RENDER_POST_WINDOWS is not emitted while locked, Hyprland 0.56.2 `renderAllClientsForWorkspace`). Runtime unload mid-animation: verified 2026-10-20 by `tests/compositor/genie.sh` step 5 (FR44-FR46 row) |
| FR44-FR46 | unit `GenieEdge.*`, `GenieGeometry.*` (exact window at 0, exact target at 1, inside the bounds, monotonic, rows never cross, genie not scale midway, only toward the Dock), `GenieMesh.*`, `GenieTiming.*`, `MinimizeEffect.*`; QML `tst_minimized` `configCallMinimizeEffect`; nested `tests/compositor/genie.sh` (shape of captures, timing, unload / load mid-animation), `genie.sh c2` (C2) | L0 / L1 | 2026-10-20, plugin 0.9.0-genie, Hyprland v0.56.2 (efb50993), headless GF-REF 1920x1080@60 on i915, host load 9-18 (other agents' sessions): unit 248/248; `genie.sh` **PASS** (`.dev/genie/run-20261020-163707`): genie minimize 4 of 5 slow-motion captures classified genie (funnel, top 4-7x wider than the neck), restore 4 of 5; scale 0 genie (3 + 5 rectangles); Reduce Motion: every footprint at the window's own box, move -> event 101 / 102 ms; unload 1 s into a slow genie minimize: Hyprland alive, window on `special:minimized`; reload advertises `minimize-effect`; unload 1 s into a slow genie restore: window fully shown at its place; no core dump, 0 exceptions. Timing at normal speed, no capture: genie 10 animations / 310 frames, frame interval mean 16.9 ms, worst 20.2 ms (0 frames over 25 ms), Genie draw CPU 0.35-5.0 ms; scale 6 / 114 frames worst 18.9 ms; fade 6 / 42 worst 19.8 ms. Captures (grim screencopy) stalled the nested compositor for 0.4-3.8 s per capture burst with every effect, hence slow motion for the captures. Two multi-second frames without captures were seen in genie rounds (3.0 s in `run-20261020-162322`, 1 of 10; 2.2 s in `.dev/minimize/run-20261020-171057`, 1 of 20) under that load; cause not isolated. `genie.sh c2 993 1032` **PASS** (`.dev/genie/run-20261020-172150`, `nested-up.sh --no-plugin`): `hyprctl grassfield` "unknown request", shell degraded, SUPER+M parks the window, the Dock tile restores it. `minimize.sh 20`: FAIL twice under load (`run-20261020-171057`: 3 events late beyond 3 s, the shell answering minimize-requests 1.4-1.5 s late; `run-20261020-172302`: the nested shell vanished without a core dump or a log line between 17:24:09 and 17:24:12, next to an i915 GPU hang of another nested Hyprland reported at 17:24:16 ("Resetting rcs0 for preemption time out"), with 6 fence timeouts on this instance); a third and fourth run on 2026-10-20 (Genie and Scale) also failed on late events, and the nested shell vanished once more with Genie. 2026-10-22, after merging main 072824f (minimize.sh rounds wait on the event socket, `MZ_ROUND_MS` 10 s, c7969ff; the shell's hello retries, ff5f888), host load ~7, 0 fence timeouts in the previous 20 min: `tests/compositor/minimize.sh` (20 rounds, Genie default) **PASS** (`.dev/minimize/run-20261022-081719`: 0 missing events, 22 minimized / 21 restored / 23 minimize-request, the shell alive to the end); `genie.sh` **PASS** (`.dev/genie/run-20261022-081918`: genie 4 of 5 captures, restore 4 of 5, scale 0 genie, fade in place, unload / load mid-animation; normal speed: genie 10 animations / 310 frames, interval mean 16.7 ms, worst 17.8 ms, 0 over 25 ms, frame CPU mean 2.23 ms, worst 5.73 ms, Genie draw worst 0.46 ms; scale 6 / 114 frames worst 17.3 ms; fade 6 / 42 worst 16.8 ms); `genie.sh c2 1019 1032` **PASS** (`.dev/genie/run-20261022-082227`). The 500 ms Genie needs no timing change in minimize.sh: its mid-animation click comes 0.12 s after the move, inside both effects. `soak.sh 300`: not run |
| FR47-FR50, tiling.md TL16-TL21 (step 2) | unit `TilingAltDrag.*`, `TilingDwell.*`, `TilingSides.*`, `TilingExtend.*`, `TilingRecord.AnEdgePlacementIsItsOwnPlacement`, `TilingJson.*` (the `sides` field); mutation run over `core/Tiling.cpp` (87 mutations, all killed); nested `tiling.sh` step-2 cases (Hyprland's move of a client-chrome window and Super+drag tile at the release with the preview; a tiled window dragged away by Hyprland's move takes back its size from before under the pointer; Alt-drag in the middle of the screen; the preview delay; a release under the menu bar that tiles is not moved by the top clamp; double-click on a side, Alt-double-click on a corner; unload in the middle of a drag) | L0 / L1 | step 2 branch: unit core suite 430/430 in the cloud container (g++ 13, gtest 1.15.2), clang-tidy 18 clean on core/Tiling.cpp and TilingTest.cpp; the plugin glue is not compiled there (no Hyprland headers); nested cases written, not run |
| FR47-FR50, tiling.md TL1-TL15 (step 1) | unit `TilingGrid.*`, `TilingFit.*`, `TilingNeighbour.*`, `TilingCenter.*`, `TilingCatalogue.*`, `TilingRecord.*`, `TilingArrange.*`, `TilingJson.*`, `Protocol.TilingArrangeComesWithWindowTiling`; mutation run over `core/Tiling.cpp` (51 mutations, all killed), `TilingOutputs.*`; nested `tiling.sh` step-1 cases (state reply, a window dropped on the other output on its Desktop, arrange, invalid, margins, full screen, minimize, zone taken, locked through the foreign locker fixture; gate C1: a window that unmaps alive during the plugin's titlebar drag, `tests/tools/xdgact` on SIGUSR2, focused or not, moving or still, with the plugin's guarded line; `tiling.sh --c1 --plugin PATH` for the A/B against an older build) | L0 / L1 | step 1 branch: unit core suite 421/421 in the cloud container (g++ 13, gtest 1.15.2), clang-tidy 18 clean on core/Tiling.cpp and TilingTest.cpp; opus review of 3831dc0 FAIL fixed, integrator review of 5eeb88e PASS on content (tidy 62 files 0 findings, 418/418 under ASan/UBSan); nested pass of 426a676: `tiling.sh` 13/30 (arrange refused after the plugin's cross-output drag; the test read the free area before the shell reserved it), `stages.sh` 71/71; both fixed on the branch, nested re-run by the integrator |
| FR47-FR50 | unit `TilingDrag.*`, `TilingPlace.*`, `TilingNames.*` (7); QML `tst_appmenumodel` `test_windowMenuTilingItems`, `settings_apply` (tiling keys); nested `tests/compositor/tiling.sh` | L0 / L1 | 2026-10-22, plugin 0.11.0-tiling (integrator): unit 280/280; `tiling.sh` **10/10 PASS** on GF-REF (left edge shared with WAYLAND-1, right edge free): right edge -> 948x926 at 2404,64, drag-out -> 800x500 back, top of the right edge -> 948x443 quarter, shared left edge -> no tiling, menu bar -> 1904x926 at 1448,64, IPC `left` then `previous`, `tilingEdges false` -> no tiling; preview captures viewed (right half, fill); Window > Move & Resize capture viewed. Not run: C2 without the plugin, soak, R13 |
| FR51-FR52 | unit `LayerPointer.*` (9; also under `-fsanitize=address,undefined`); nested `tests/compositor/layer_pointer.sh` (`check`, `--output WAYLAND-1`, `--expect plugin` against an older build and with the plugin unloaded, C2) | L0 / L1 | Final, after the merge with window tiling (plugin 0.12.0-pointer, Hyprland v0.56.2 efb50993, host load 0.8-4.6): unit 290/290 and the ASan/UBSan build 290/290 (0 reports); `layer_pointer.sh check` **PASS** on a fresh instance (`.dev/layer-pointer/run-20261022-231314-check`) and after the soak (`run-20261022-232723-check`); C2 `nested-up.sh --no-plugin`: `hyprctl grassfield` "unknown request", shell "ready degraded", 0 QML errors, `layer_pointer.sh check` PASS with the 3 map cases KNOWN (`run-20261022-232743-check`); regressions PASS: `menubar-macos.sh` 10/10, `click_focus.sh` 43/43, `chrome.sh`, `window_reachable.sh` 12/12, `tiling.sh` 10/10, `soak.sh 600` (C1 below). Before the merge, plugin 0.11.0-pointer (the same code), GF-REF at x = 1440 next to WAYLAND-1 at 0,0, host load ~3: unit 283/283 (ASan/UBSan build 283/283, 0 sanitizer reports); `layer_pointer.sh check` **PASS** on GF-REF (`.dev/layer-pointer/run-20261022-223323-check`): a second click without motion closes the menu opened by a press (same pointer, and a new pointer device sending no motion), and the menu opened by IPC under the still pointer; 1-px control and the click after a menu closed over foot PASS; `--output WAYLAND-1` PASS. Defect shown: the 0.10.0-chrome build (loaded from another path with `scripts/nestctl plugin load`) with `--expect plugin` **FAIL** 3/3 map cases (`run-20261022-223421-check`), the plugin unloaded likewise (`run-20261022-223339-check`); without the plugin the map cases pass on WAYLAND-1 (at the origin) and fail on GF-REF (baseline probes `run-20261022-221741-probe`, `run-20261022-221846-probe`). First fix (map only) left the menu opened by a press failing: diagnostic lines showed the overlay maps while the button is still down with keyboard None and takes the keyboard after the release (`CLayerSurface::onCommit`, same miscomputed position): hence the keyboard trigger and the wait for the release. Runtime unload / load: rc 0 both, Hyprland alive, `layer-pointer` withdrawn and advertised again, check PASS after the reload (`run-20261022-223449-check`) |
| FR53 | unit `Protocol.AppearanceConfigAndFeature`, `Theme.PaletteComesFromTheTokensForBothAppearances`; `gen-tokens.py --check`; QML `tst_minimized` `configCallAppearance`; nested `tests/compositor/chrome.sh` step 3b (light bar, lights, grey inactive, back to dark) | L0 / L1 | unit PASS (2026-10-23, this branch); nested chrome.sh 3b NOT RUN yet (no nested session in the agent sandbox) |
| P9 (1.0.0-rc6 report: two title bars; review of 3ca47a4b: imv and foot csd lost every bar) | unit `ClientChromeDecoration.*` (8); nested `tests/compositor/decorations.sh` (D1-D12) | L0 / L1 | 2026-11-07, Hyprland 0.56.2 (efb50993): unit 543/543, the same under ASan and UBSan; decorations.sh PASS 16/16 at scale 1.25 on the headless GF-REF (foot, foot csd, imv, xdgact server_side, client_side and unbound, a plain Qt window and a plain GTK 3 window keep the plugin's strip; xdgact bound without an object, a Qt frameless window and a GTK 3 header bar are tagged, each decided once at its map in the plugin's log; the capture shows one bar per window; unload removes only the plugin's tag, reload adds it again). The first run's D9 failed on the test: imv, opened at its picture's zoom, covered the measured windows (fixed: imv closed, each window raised) |
| tiling.md TL17, TL21, FR56 (1.0.0-rc6 report: slow fill, overflow on a smaller display, titlebar under the menu bar; review of 3ca47a4b: fit on every Desktop move) | unit `TilingDwell.TheMenuBarFillsAtOnceWhenNothingIsAbove`, `TilingFitIntoArea.*` (4, `OnlyAMoveFromAnotherOutputsDesktopFits` included); nested `tiling.sh` cases menu-bar-at-once and drag-follows, `tests/compositor/display_fit.sh` (F1-F7) | L0 / L1 | 2026-11-07, Hyprland 0.56.2: display_fit.sh `--source WAYLAND-1 --target GF-REF` PASS 7/7 at scale 1.25, GF-REF (1536x864 logical, work area 1536x840) the smaller target (F3: the moved window 1520x792 at 1448,64, the frame of a window filled there); the earlier claim of a 1.25 run with GF-REF the smaller target was wrong (those runs had GF-REF as the source, review of 3ca47a4b); at scale 1 F1-F5 PASS before the review (WAYLAND-1 the target). tiling.sh A/B at scale 1 (GF-REF alone: the owner's screen asleep, no WAYLAND-1), two runs each: this tree 343 and 341 PASS, main f85396e8 347 and 342 PASS; every case that fails on this tree also fails in a main run (the split, popover, hover, covered, fixed-keys and group-front cases, after a shell overlay that Esc does not close), and main fails menu-bar-at-once and drag-follows in both runs, which this tree passes; the fixed-keys cases checked alone on this tree: Super+Alt+F fills and unfills, the zoom light fills. drag-follows capture shows the window under the pointer right after a jump (the measure's first run had a format bug, fixed). Same day: top_clamp.sh PASS 11/11 at 1.25; minimize.sh 5 repeats at 1, this tree and main alike: everything but 2b, which needs a second display |
| FR56 | unit `TopClamp.*` (11: the move and resize rules, the output under the frame's top edge (level outputs above the edge: the one sharing most of its width, review of 9ba1d40), the review cases of e0a3734 on stacked and bottom-aligned outputs: SUPER+drag ending on the lower output, bottom-edge and right-edge resizes, a top-edge resize and a move into the lower output's menu bar); nested `tests/compositor/top_clamp.sh` (P foot titlebar drag, C Chromium tab strip, R bottom-edge resize with the titlebar under the menu bar) | L0 / L1 | unit 393/393 PASS (2026-10-25, branch m7-clamp-fix; clang-tidy clean on the changed files); nested top_clamp.sh after the fix 2026-10-26 PASS, 8/8 (Hyprland 0.56.2 efb50993; P1-P3, R0 height 400 -> 500 with R1 top 24 -> 24 (titlebar at -8, under the 24 px bar, left alone), C0-C2); C1 soak shortened to 300 s PASS (103 rounds, every action effective but restore 7/9, no coredump, no plugin exception; RSS slopes not judged at that length); C2: plugin unloaded, a window still maps, plugin loaded again. These nested runs used the build of the Electron branch, which merges this one. 2026-10-26 after the review of 9ba1d40 (tie rule, keyboard-focus events): unit 394/394, top_clamp.sh 8/8 PASS again |
| FR57 | unit `WindowRim.*` (15: the tokens, the dark appearance only and after the shell's push, none in full screen, the width in whole device pixels and macOS 27's light per point at 1, 1.25, 1.5 and 2, the frame with the titlebar, the snapping, the ring's box and radii, and through Hyprland 0.56.2's border and rounding shader arithmetic: the straight sides' first device pixels, never outside the window's shape, continuous round the arcs); nested `tests/compositor/window_edge.sh` (checks 4 to 6, with and without the plugin), `window_edge.sh c2`, `window_edge.sh cost` | L0 / L1 | 2026-11-03, Hyprland 0.56.2 (efb50993), GF-REF 1920x1080 at 1.25: unit 524/524; `window_edge.sh` PASS with the plugin (200 checks: Settings 66 over 39 on its sides and 65-66 on its arcs, inactive 61 and 60-61; foot's bar top 67 over 40, its sides 63 over 36, no second line under the hairline; Evince, dark theme, 78 over 53; none in light) and without it (no rim, no titlebar); `c2` PASS (unload with two windows open: Hyprland alive, rim and titlebar gone; reload: the shell's push, the rim back at 27 levels; 0 plugin exceptions); `cost 6`: render CPU median 2.17 ms with the rim, 2.13 ms without (p95 2.98 / 2.80 ms), 60 Hz either way; C1 `soak.sh 480` PASS (481 s, 166 rounds, every action type effective, minimize 15/20 and restore 15/15, 0 plugin exceptions, no core dump, the shell kept its PID; RSS slopes not judged at that length) |

## Interfaces / contracts (versions)

`gfc/1` (master-prompt §5.3). Measured transport in S2:

| Direction | Mechanism | Payload |
|---|---|---|
| plugin → shell | Hyprland socket2 event `grassfield` | `{"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config"]}` (FR9) |
| plugin → shell | socket2 event `grassfield` (minimize button, double-click set to minimize) | `{"v":"gfc/1","type":"minimize-request","address":"<hex, no 0x>"}` |
| plugin → shell | socket2 event `grassfield` (end of a minimize / restore) | `{"v":"gfc/1","type":"minimized","address":"<hex>"}`, `{"v":"gfc/1","type":"restored","address":"<hex>"}` |
| shell → plugin | Lua function `hl.plugin.grassfield.hello()` via `Hyprland.dispatch("hl.plugin.grassfield.hello()")` | re-posts capabilities |
| shell → plugin | `hl.plugin.grassfield.minimize("0x<hex>", x, y, w, h)` / `restore(...)` (Dock tile, layout px, integers) | FR14 / FR15 |
| shell → plugin | `hl.plugin.grassfield.config("titlebarDoubleClick", "zoom"\|"minimize"\|"fill"\|"none")` | FR16 |
| shell → plugin | `hl.plugin.grassfield.config("minimizeEffect", "funnel"\|"shrink"\|"fade")` (only with feature `minimize-effect`) | FR45 |
| plugin → shell | socket2 event `grassfield` (appmenu registration of a mapped window changed, window mapped with one, window focused, re-emit) | `{"v":"gfc/1","type":"appmenu","address":"<hex>","service":"<bus name>","path":"<object path>","pid":N}`; `"service":"","path":""` = no `set_address` menu, with the window's Wayland client pid (0: X11/XWayland or a clear) (FR20–FR22) |
| plugin → shell | socket2 event `grassfield` (the seat's keyboard focus entered a mapped window; feature `keyboard-focus`) | `{"v":"gfc/1","type":"keyboard-focus","address":"<hex>"}` (FR20) |
| shell → plugin | `hl.plugin.grassfield.appmenu("0x<hex>")` | re-posts that window's appmenu event (FR22) |
| client → plugin | Wayland global `org_kde_kwin_appmenu_manager` v2 (`create(new_id, wl_surface)`, `release` since 2); `org_kde_kwin_appmenu.set_address(s, s)`, `release` | FR18–FR21 |
| shell → plugin | `hl.plugin.grassfield.overview("<json>")` | `{"on":bool,"durationMs":int,"curve":[x1,y1,x2,y2]?,"windows":[{"address":"0x<hex>","x","y","w","h"}…]}` (FR25-FR27) |
| plugin → shell | socket2 event `grassfield` (overview state) | `{"v":"gfc/1","type":"overview","state":"opening\|open\|closing\|closed","windows":N}` (+ `"reason"`: `invalid`, `no-windows`, `no-chrome`, `unavailable`, `interrupted`, `fullscreen`; FR27) |
| plugin → shell | socket2 event `grassfield` at unload (FR32) | `{"v":"gfc/1","type":"capabilities","features":[]}` |
| plugin (no verb) | feature `desktop-focus` (+ `desktop-focus-v2`): click-to-focus for the layer surface `grassfield-desktop-icons` on pointer presses | FR30; contract `docs/specs/desktop.md` "Compositor focus policy" |
| shell → plugin | `hl.plugin.grassfield.config("stagesEnabled", "true"\|"false")` | FR33 |
| shell → plugin | `hl.plugin.grassfield.stages("<json>")` | `{"op":"on"\|"off"\|"activate"\|"move"\|"merge",…}` (FR34; contract `docs/specs/stages.md`) |
| plugin → shell | socket2 event `grassfield` (Stages change notice) | `{"v":"gfc/1","type":"stages","gen":N,"on":bool}` (+ `"reason"`; FR36) |
| shell → plugin | `hyprctl grassfield-stages` (request socket; StagesLink, on each notice with `on:true`) | the state: `{"v":"gfc/1","type":"stages","gen":N,"on":bool,"monitors":[…]}` (+ `"reason"`; FR36) |
| shell → plugin | `hl.plugin.grassfield.arrange("<json>")` (feature `tiling-arrange`) | `{"layout":"<catalogue id>","windows":["0x<hex>",…],"fill":bool?,"zone":int?,"output":"<name>"?}` (tiling.md TL6, ADR-0007) |
| plugin → shell | socket2 event `grassfield` (tiling change notice) | `{"v":"gfc/1","type":"tiling","gen":N}` (+ `"reason"`) |
| shell → plugin | `hyprctl grassfield-tiling` (request socket) | the state: `{"v":"gfc/1","type":"tiling","gen":N,"outputs":[{"name","area","class","grid","windows":[…]}],"splits":[{"workspace","output","home"}],"unfit":[…],"fixed":[…],"suggestion":…}` (tiling.md TL15, TL28, TL33) |
| shell → plugin | `hl.plugin.grassfield.split("0x<hex>", "left"\|"right")`, `hl.plugin.grassfield.unsplit("0x<hex>")` (feature `tiling-split`) | Full Screen › Left or Right of Screen; Exit Full Screen of a Split View window (tiling.md TL33, ADR-0007); the `tiling` notice follows |
| shell → plugin | `hl.plugin.grassfield.cursor_refresh()` (feature `cursor-refresh`), after the shell's `setcursor <theme> <size>` was answered `ok` | the pointer is drawn again at that size, same shape, same place (FR39-FR40); no event |
| shell → plugin | `hl.plugin.grassfield.overview_focus("<json>")` (feature `overview-focus`) when the Overview starts closing | `{"target":"window"\|"workspace"\|"remembered"\|"none",…}` (FR41; contract `docs/specs/overview.md` "Close focus") |
| plugin → shell | socket2 event `grassfield` (overview focus outcome) | `{"v":"gfc/1","type":"overview-focus","outcome":"…","target":"…","id":N}` (+ `"address"`, `"workspace"`, `"reason"`; FR42) |
| plugin (no verb) | feature `layer-pointer`: the pointer focus is re-run at the cursor after a `grassfield-*` layer surface maps or takes the keyboard | FR51-FR52 |
| query | `hyprctl grassfield` | capabilities JSON |

The shell sends every verb guarded (`local p = hl.plugin and hl.plugin.grassfield; if p and p.<verb> then
p.<verb>(...) end`), built only from validated pieces (`shell/platform/Minimized.js`: verb allowlist, hex
address, finite rounded numbers, config allowlist).

Findings for ADR-0007 (evidence in "Automated tests · Manual verification steps"):

1. Under Hyprland 0.56.2's Lua config, `hyprctl dispatch X` and Quickshell 0.3.1's `Hyprland.dispatch(X)`
   are evaluated as Lua `return hl.dispatch(X)`. A legacy plugin dispatcher name (`grassfield:hello`,
   registered with `HyprlandAPI::addDispatcherV2`) is a Lua syntax error and is unreachable, so the plugin
   no longer registers it.
2. `HyprlandAPI::addLuaFunction(handle, "grassfield", "hello", fn)` exposes `hl.plugin.grassfield.hello()`.
   The function returns `hl.dsp.no_op()` so that `hl.dispatch(hl.plugin.grassfield.hello())` succeeds
   without an error reply.
3. Plugin → shell events posted with `g_pEventManager->postEvent({"grassfield", json})` arrive in
   Quickshell's `Hyprland.rawEvent` with `name == "grassfield"` and `data == json`.

Verbs follow the same pattern: `hl.plugin.grassfield.<verb>(args)`, results as `grassfield` socket2 events.
ADR-0007 lists `restore(address)`; the implemented verb takes the Dock tile too (`restore(address, x, y, w, h)`)
for the reverse animation; `config(key, value)` is new. Both are additions within `gfc/1` (no payload of an
existing message changed); the ADR's verb list should be updated by its owner.

## Appmenu (feature 3, spike S5): mechanism

Feasibility in Hyprland 0.56.2 (headers in `/usr/include/hyprland`, exported symbols of `/usr/bin/Hyprland`):

- `HyprlandAPI` (`src/plugins/PluginAPI.hpp`) has **no protocol or Wayland-global function**. What Hyprland's own
  protocols use is reachable from a plugin, though: `g_pCompositor->m_wlDisplay` (public member), libwayland-server
  (`wl_global_create`, `wl_global_remove`, `wl_global_destroy`, resolved from Hyprland's process), the exported
  `IWaylandProtocol` constructor / destructor / `removeGlobal`, the exported `CWLSurfaceResource::fromResource`,
  and hyprwayland-scanner 0.4.6, which generates the same kind of server wrappers Hyprland compiles
  (`COrgKdeKwinAppmenuManager`, `COrgKdeKwinAppmenu`). So a plugin **can** add a Wayland global. It is internal API
  covered by the same ABI-hash check as the rest of the plugin, not a stable plugin API: re-verify on every
  Hyprland update.
- `IWaylandProtocol` is not used: its bind trampoline is Hyprland's but calls a virtual of the plugin's subclass,
  and its destructor destroys the global at once. Plain libwayland keeps every pointer on the plugin side and lets
  the plugin choose between removing and destroying the global at unload.
- The generated code is compiled as its own object with `-fvisibility=hidden`: its `wl_interface` symbols cannot
  clash with a future Hyprland that would export the same names.
- **Unload hazard.** Every `wl_resource` the plugin creates points into the library (its `wl_interface` tables, the
  request table, the destroy listener); libwayland follows those pointers on each request and when the client
  disconnects, and Hyprland's shutdown order is `unloadAllPlugins` (PLUGIN_EXIT, `dlclose`) first, clients later.
  Destroying a resource the client still holds is no alternative at runtime: libwayland answers the client's next
  request on it with `invalid object` and disconnects the client. Hence FR23: destroy everything at shutdown,
  pin the library (`RTLD_NODELETE`) and keep the objects inert on a runtime unload with live client objects.
  The bind callback of a removed (not destroyed) global stays valid because the library stays mapped. Pinning
  is the technique GStreamer uses for plugins whose registrations cannot be revoked.
- Windows: `window.open` (map: announce a stored registration), `window.close` (unmap: clear),
  `window.destroy` (sweep registered windows that are no longer mapped), `window.active` (focus: post the focused
  window's registration or an empty one). The registrations themselves are pure logic (`core/Appmenu.*`).
- Third-party notice: `compositor/protocols/appmenu.xml` is KDE's protocol description (LGPL-2.1-or-later,
  © 2017 David Edmundson, notice kept in the file); the generated server code is compiled into the MIT plugin,
  as Hyprland (BSD-3-Clause) does with KDE's LGPL-2.1-or-later server-decoration protocol. To list in
  `THIRD_PARTY.md` and to cover in the §14 legal review (ADR-0005). Not a legal conclusion.

## S5 results

2026-10-17, nested Hyprland 0.56.2 with plugin 0.3.0-s5, Qt 6.11.2 (`qt6-base` 6.11.2-3: the Wayland QPA now lives
in qt6-base), Chromium 152.0.7977.82 (`/usr/lib/chromium/chromium` directly, so the owner's `chromium-flags.conf`
is not read; no extra flag), Firefox not installed (not tested; per §2 its Wayland global menu needs
`widget.gtk.global-menu.wayland.enabled`, off by default). Command: `tests/compositor/appmenu.sh <variants>`; each
variant runs on its own private D-Bus bus **without service activation** (no portal or other service can start),
the registrar is `tests/fixtures/fake-registrar`, the Qt app `tests/fixtures/menu-demo`. Runs
`.dev/appmenu/run-20261017-110915` (qt-registrar, PASS, exit 0), `run-20261017-110937` (five Qt variants, exit 0),
`run-20261017-111508` (chromium), `run-20261017-111403` (chromium-no-registrar), `run-20261017-111816`
(edge-cases, PASS), `run-20261017-112009` (qt-no-global).

| Variant | Registrar on the bus | Environment | Client requests (`WAYLAND_DEBUG`) | Menu bar in the window | Plugin event |
|---|---|---|---|---|---|
| qt-registrar | before the app | `QT_QPA_PLATFORMTHEME` unset | bind v1; `create`, `set_address(":1.1", "/MenuBar/1")`, `release`, `create`, `set_address(":1.1", "/MenuBar/2")`, all before map | hidden (DBusMenu bar) | yes, right after `openwindow`; clear after `closewindow` |
| qt-gtk3 | before | `QT_QPA_PLATFORMTHEME=gtk3` | same | hidden | yes |
| qt-portal | before | `QT_QPA_PLATFORMTHEME=xdgdesktopportal` (no portal on the bus) | same | hidden | yes |
| qt-kde | before | `XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6 KDE_FULL_SESSION=true` | same | hidden | yes |
| qt-no-registrar | none | unset | bind v1 only | shown | none |
| qt-late-registrar | 3 s after the app | unset | bind v1 only | shown | none |
| qt-no-global | before | `QT_WAYLAND_DISABLED_INTERFACES=org_kde_kwin_appmenu_manager` | none | **hidden** (no menu anywhere) | none |
| chromium | before | none | bind v1; `create`, `set_address(":1.2", "/com/canonical/menu/1")`; a second window: `/com/canonical/menu/3` | (browser has no menu bar) | yes, per window; clears at exit |
| chromium-no-registrar | none | none | bind v1 only | – | none |

(Menu bar visibility as reported by the app: `QMenuBar::platformMenuBar()` / `isVisible()`; visual NOT verified.)

DBusMenu side (same runs): Qt exports `com.canonical.dbusmenu` at the announced address (introspection lists the
interface; `GetLayout(0, -1, [])` returns File / Edit / View with submenus, mnemonics as `_`, shortcuts, toggle
state); `Event(id, "clicked", <0>, 0)` on File > New and on View > Theme > Dark (after `AboutToShow` on Theme) ran
the app's own actions (action log `file.new`, `view.theme.dark=on`), File > Quit closed the app and the plugin
posted the clear event. Chromium's object has **no introspection data** (empty node) and rejects untyped
arguments (`GetLayout` with `[]` guessed as `av` → `error occurred in GetLayout`); with explicit signatures
(`int32 0`, `int32 -1`, `@as []`) it returns File (New tab, New window, …), Edit, View, History, …, and
`Event(int32 2, "clicked", <int32 0>, uint32 0)` on "New window" opened a second browser window.

Findings:

1. **Qt 6.11 calls `set_address` if and only if `com.canonical.AppMenu.Registrar` is owned on the session bus
   when the menu bar is created** (QtGui creates its `QDBusMenuBar` only then; the check is done once, a registrar
   that appears later changes nothing). The platform theme (generic, gtk3, xdgdesktopportal, KDE) and KDE
   variables do not matter. Qt never calls `RegisterWindow` on Wayland: the registrar only has to exist; the link
   goes through `QWaylandPlatformServices::registerDBusMenuForWindow` → `org_kde_kwin_appmenu`. Service = the app's
   unique bus name, path `/MenuBar/<n>`; Qt recreates the object once while starting (before map).
2. **Chromium 152 behaves the same without any flag**: registrar present → one appmenu object per browser
   window at `/com/canonical/menu/<n>`; no registrar → nothing. Its DBusMenu needs explicit D-Bus signatures.
3. Both clients bind manager version 1; version 2 (manager `release`) is exercised only by the test client.
4. **Registrar without a working appmenu path hides menus**: with the registrar present but no global (or no
   compositor support), Qt hides its in-window menu bar and nothing shows the menu (qt-no-global). Owning the
   registrar is therefore only allowed while the whole chain works (plugin feature `appmenu`, bridge, shell
   menu bar), and never on the owner's bus during development.
5. KDE apps with the KF6 platform theme (plasma-integration) and GTK apps were not tested (not installed / no
   Wayland menu export).

Shutdown with live appmenu clients (FR23, `.dev/s5/shutdown-test.sh`, scratch): two menu-demo instances with
registered menus on a private bus, then `scripts/dev/nested-down.sh` (SIGTERM): the nested log ends with
`appmenu: global and 5 client object(s) destroyed (shutdown)`, `grassfield-compositor unloaded`,
`[PluginSystem] Plugin grassfield-compositor unloaded.`, `Hyprland has reached the end.`; no Hyprland core dump
since the start (`coredumpctl list --since`), no fixture process left. Runtime unload (pinning path): NOT
VERIFIED (no `scripts/nestctl`; `hyprctl plugin unload` is an owner action).

Full matrix on the same instance after the soak (run `.dev/appmenu/run-20261017-113205`, all ten variants,
RESULT PASS, exit 0): same results as the table; the windows took focus this time, so the focus path is
verified too: `openwindow` → appmenu (map) → `activewindowv2` → appmenu (focus, same registration); a window
without a registration gets `activewindowv2` → appmenu with empty strings; no clear is posted for a window that
never had a registration.

Regressions (same plugin build, 2026-10-17): `compositor/build-direct.sh tidy` exit 0, no diagnostic;
`grassfield-compositor-tests` 90/90 PASS (direct and CMake builds); `tests/compositor/input_consistency.sh 3`
PASS exit 0; `tests/compositor/soak.sh 300` PASS exit 0 (178 rounds, 22/22 minimizes animated, RSS 152.0 →
158.8 MB, no core dump, 0 grassfield exceptions); `tests/unit/tst_minimized.qml` 20/20 PASS. The CMake build
(`cmake -S compositor -B .dev/cmake-build -G Ninja`, now that cmake and ninja are installed) builds the plugin
and the tests (exit 0).

## Minimize (M2): mechanism

Chosen in Hyprland 0.56.2 after reading its headers and the v0.56.2 sources of `IHyprRenderer::makeSnapshotFB`,
`renderFadeouts`, `CWindowFadeout`, `CWindow::moveToWorkspace` and `CGlobalWindowController::moveWindowToWorkspace`
(upstream data, cross-checked with the installed headers and exported symbols):

- **Hidden state: `special:minimized`**, the special workspace the shell's fallback already uses
  (`Config::Actions::moveToWorkspace(ws, silent = true, window)`; the workspace is resolved like the Lua
  dispatcher does: `getWorkspaceIDNameFromString`, `State::workspaceState()->query().id()`, `create()` on the
  focused monitor). Consequences: the shell rebuilds its Dock tiles from it after a restart; a plugin unload,
  crash or mismatch leaves windows minimized and restorable by the fallback; a window minimized by the
  fallback is restored by the plugin and the other way round. Hyprland keeps the floating geometry of a window
  on a special workspace (translated when that workspace is on another monitor); the plugin gives the recorded frame
  back exactly (FR15), and the shell's fallback moves the window to the Desktop its own display shows now (D-1).
- **State first, animation second.** Minimize moves the window at once and animates a snapshot; restore moves
  it back at once (focused, transparent through `WINDOW_ALPHA_MOVE_FROM_WORKSPACE`, the alpha Hyprland itself
  animates 0 → 1 when a window arrives on a visible workspace) and shows it when the snapshot has grown back.
  Nothing can act on a half-minimized window, and an interrupted animation never leaves a wrong state.
  Hyprland's own fade-out of a window leaving a visible workspace (`WINDOW_ALPHA_MOVE_TO_WORKSPACE`) and its
  fade-in on arrival are completed at once (`warp()`), as the snapshot replaces them.
- **Animation: a transformed snapshot drawn by a render pass element.** `makeSnapshotFB(window)` (what
  Hyprland uses for its close animation: a monitor-sized framebuffer with the window, its titlebar, border
  and shadow at their place) is drawn with a `CTexPassElement` at the box `core/Minimize.cpp textureBox()`
  computes (Hyprland's `CWindowFadeout::renderBox` math, generalized to another monitor), clipped to the
  window's mapped box, from the `render.stage` event `RENDER_POST_WINDOWS` (after windows, under the top
  layers: the shrinking window passes under the menu bar and into the Dock). Each animation is ticked from
  `render.preChecks` (where Hyprland ticks its own animations), which damages the old and new boxes and so
  schedules the next frames; a 450 ms event-loop timer completes animations if no monitor renders.
- **Rejected: animating the window's own `m_realPosition`/`m_realSize` (`PHLANIMVAR`).** Their begin callback
  calls `sendWindowSize` (v0.56.2 `CWindow` map code), so the client would be configured to every
  intermediate size, the titlebar (fixed height) would not scale, and the layout would fight the animation.
- **Rejected: a custom `Desktop::IFadeout` added to `fadingOutState()`.** It would render in Hyprland's own
  planes, but Hyprland would then hold objects whose vtable lives in the plugin: unloading safely needs
  `clear()` (drops Hyprland's own fadeouts) or relying on `cleanupForMonitor`; the plugin-owned pass element
  keeps every pointer on the plugin side.
- **Genie (Track B3): a custom pass element with its own GLES 3 draw.** Hyprland 0.56.2's `IPassElement` has
  `ePassElementType::EK_CUSTOM` and a virtual `draw()`; the element renderer's `drawCustom` calls it while it renders
  the pass, in order (measured in nested: the element's draw runs every frame of the animation and lands between the
  windows and the top layers, like the Scale `CTexPassElement`). `draw()` uploads this frame's mesh (positions as
  fractions of the element's pixel box, mapped to clip space by `IHyprRenderer::projectBoxToTarget`, the same box
  projection Hyprland gives its textured quads; texture coordinates into the snapshot, sampled top-down) and issues one
  `glDrawElements` per damage rectangle, scissored with `CHyprOpenGLImpl::scissor`. The mesh is computed in `core/`
  at each tick (render.preChecks) in layout coordinates and converted per monitor at `RENDER_POST_WINDOWS`; damage is
  the mesh's box. Rejected: slicing the snapshot into hundreds of `CTexPassElement` strips (one textured rectangle per
  row band: staircase edges, hundreds of draws per frame); a window transformer (`IWindowTransformer`) (it needs the
  window rendered every frame, the window is already on `special:minimized`); drawing at `RENDER_LAST_MOMENT` (above
  the menu bar and the Dock, and outside the pass's damage tracking).

Crash safety: arguments are copied out of Lua with non-raising calls before any C++ work (Lua errors
longjmp); every hook runs in `gf::guarded`; windows are looked up by comparing addresses, held as weak
references, re-checked every tick (closed or unmapped → animation dropped); snapshots are released with
Hyprland's EGL context made current, never while a frame is being built; monitor removal or layout change
completes all animations; `PLUGIN_EXIT` (`minimizer::stop()`) removes listeners, completes animations
(restoring windows visible again), drops snapshots and removes the timer before the Lua functions go.

Pointer input contract with Hyprland (FR13), decided 2026-10-17 after the counter-review finding. The
plugin observes `input.mouse.button` and never cancels it, for presses and releases alike:

- Hyprland 0.56.2 appends a press to `m_currentlyHeldButtons` before dispatching it, so a press the titlebar
  consumes (`onInputOnDeco` returns true) is recorded as held exactly like a client press, and only a
  release that Hyprland processes removes it. While the list is not empty, `mouseMoveUnified` pins pointer
  focus (binary facts under "Dependencies").
- Keeping the press from the client needs nothing more: the titlebar is a decoration outside the client
  surface, so the consumed press never reaches `CSeatManager::sendPointerButton`.
- Keeping the release from the client needs nothing more either: over a titlebar the titlebar consumes it
  (only if a titlebar consumed the press, `CPointerGestureTracker::takeTitlebarRelease`); elsewhere the seat
  sends it only to a pointer resource that got the press (`CWLPointerResource::m_pressedButtons`), so a
  client that gained pointer focus during the drag gets nothing.
- Rejected: cancelling the release only (the previous strategy). Hyprland had recorded the press, so the
  button stayed held and pointer focus stayed pinned to the dragged window: the next click on another window
  went to it. Rejected: cancelling both press and release. Hyprland would then skip its whole button path
  (keybinds such as SUPER+drag on the bar, decoration routing, focus hold during the drag, refocus after the
  release), and the plugin would have to re-implement it; nothing is gained because the default path
  already keeps both events from clients.

## Dependencies (verified versions)

- Hyprland 0.56.2 (commit `efb50993780079460b0cbed1363e2166a2de1d9f`), headers in `/usr/include/hyprland`.
- APIs used (all read from the 0.56.2 headers): `HyprlandAPI::{addWindowDecoration, removeWindowDecoration,
  addLuaFunction, removeLuaFunction, registerHyprCtlCommand, unregisterHyprCtlCommand, addNotification,
  getHyprlandVersion}`, `Event::bus()->m_events.{window.open, window.floating, window.fullscreen,
  window.title, window.updateRules, input.mouse.button}` (observed, never cancelled but for FR13's two exceptions; the deprecated
  `registerCallbackDynamic` is not used), `g_pEventManager->postEvent`, `IHyprWindowDecoration`,
  `g_pDecorationPositioner`, `g_pHyprRenderer->addPassElement` with `CRectPassElement` /
  `CTexPassElement`, `renderText`, `g_layoutManager->setTargetGeom` (move),
  `Desktop::focusState()->fullWindowFocus`, `Fullscreen::controller()->setFullscreenMode`,
  `Config::Actions::{closeWindow, alterZOrder}`, `Event::bus()->m_events.input.mouse.move`,
  `g_pInputManager->{hasHeldButtons(), m_pointers, getMouseCoordsInternal()}`,
  `Pointer::Cursor::overrideController->{setOverride, unsetOverride}` (special-action group: the shared edge's cursor,
  tiling.md TL30), `Desktop::viewState()->hitTest().windowAt(pos, RESERVED_EXTENTS | INPUT_EXTENTS | ALLOW_FLOATING)` and
  `CWindow::hasPopupAt` of every visible window, `CWindow::isX11OverrideRedirect` and `getWindowMainSurfaceBox` (what is in
  front of the shared edge's handle: a popup, an X11 menu), `CWorkspace::isVisible`, `g_pSessionLockManager->m_events.lock` (the lock
  ends its drag), `MIN_WINDOW_SIZE` (macros.hpp: the tiling minimum's floor), `CEventLoopTimer` (the frame probe's loop
  beats, FR54),
  `CWindow::{m_windowDecorations, m_decosToRemove}`, `g_pDecorationPositioner->{uncacheDecoration,
  forceRecalcFor}`, `g_pPluginSystem->getPluginByHandle()->m_registeredDecorations`.
  Minimize (M2, also checked in the exported symbol table): `Event::bus()->m_events.{render.preChecks,
  render.stage (RENDER_POST_WINDOWS), window.close, monitor.removed, monitor.layoutChanged}`,
  `IHyprRenderer::{makeSnapshotFB(PHLWINDOW), damageBox, damageWindow, type(), m_renderData.pMonitor}`,
  `IFramebuffer::getTexture`, `Render::GL::g_pHyprOpenGL->makeEGLCurrent()`,
  `Config::Actions::moveToWorkspace(ws, silent, window)`, `getWorkspaceIDNameFromString`,
  `State::workspaceState()->{query().id().run(), create()}`, `State::monitorState()->monitors()`,
  `Desktop::focusState()->monitor()`, `CWindow::{alpha(WINDOW_ALPHA_MOVE_TO_WORKSPACE |
  WINDOW_ALPHA_MOVE_FROM_WORKSPACE), getWindowMainSurfaceBox, getWindowExtentsUnified, geometricBox(GOAL),
  positionAnimation, sizeAnimation}`, `CEventLoopTimer` with `g_pEventLoopManager->{addTimer, removeTimer}`,
  `Time::steadyNow`. Genie (FR44-FR46): `IPassElement` (`EK_CUSTOM`, `draw()`, `boundingBox`, `opaqueRegion`),
  `IHyprRenderer::{projectBoxToTarget, disableScissor, m_renderData.damage, addPassElement}`,
  `Render::GL::g_pHyprOpenGL->{blend, scissor(const pixman_box32*), makeEGLCurrent}`, `ITexture::{m_texID, bind, unbind,
  setTexParameter}`, `g_pInputManager->getModsFromAllKBs()` with `HL_MODIFIER_SHIFT`, `render.stage` `RENDER_POST`; GLES 3
  (`libGLESv2`, already loaded by Hyprland) for the program, buffers and vertex array. Behavior read from the v0.56.2 sources (data, see "Minimize (M2): mechanism").
  Desktop focus (FR30-FR32) and the overview R13 fixes, read from the 0.56.2 headers: `g_pSeatManager->{m_state.keyboardFocus,
  m_state.pointerFocus, m_seatGrab->m_keyboard}`, `CWLSurfaceResource::m_role` with `SURFACE_ROLE_SUBSURFACE` /
  `CSubsurfaceRole::m_subsurface` / `CWLSubsurfaceResource::m_parent`, `Desktop::View::CWLSurface::fromResource()->view()`,
  `IView::type()`, `CWindow::fromView`, `CLayerSurface::{fromView, m_namespace, m_mapped, m_monitor, m_layerSurface}`,
  `CPopup::{fromView, layerOwner, getT1Owner}`, `CLayerShellResource::{m_current.interactivity, m_events.commit}`,
  `Desktop::layerState()->layers()`, `Desktop::viewState()->hitTest().windowAt`, `Desktop::focusState()->{fullWindowFocus,
  rawSurfaceFocus}`, `g_pInputManager->{m_exclusiveLSes, getMouseCoordsInternal}`,
  `g_pSessionLockManager->isSessionLocked()`, `Event::bus()->m_events.{layer.opened, layer.closed, input.keyboard.focus,
  window.active (with eFocusReason)}`, `Fullscreen::controller()->getFullscreenModes(PHLWORKSPACE)`. Measured in nested
  (not read from sources): Hyprland emits `window.active` for a closing window (reason `FOCUS_REASON_OTHER`) while it
  refuses the keyboard to the next window because of an Exclusive layer ("Refusing a keyboard focus to a window because of
  an exclusive ls"); `fullWindowFocus` moves the keyboard to a window Hyprland already counts as focused when a layer
  surface holds it (22/22 presses in `desktop_focus.sh`).
- Behavior read from the installed 0.56.2 binary (`objdump -d` of the exported symbols; member offsets
  checked with `static_assert(offsetof(...))` against the headers), relied on by FR7, FR12, FR13:
  - `CWindow::updateWindowDecos()` returns at once when `!m_isMapped` or `isHidden()`, so a removal queued by
    `removeWindowDecoration` → `CWindow::removeWindowDeco` (push to `m_decosToRemove`) waits for the window
    to be mapped and visible again.
  - `CPluginSystem::unloadPlugin(plugin, false)` calls `pluginExit` first, then `removeWindowDecoration()` for
    every pointer in a copy of `CPlugin::m_registeredDecorations` (never pruned by Hyprland), then `dlclose`.
    `CCompositor::cleanup()` (normal exit) unloads every plugin this way.
  - `CInputManager::onMouseButton` emits `input.mouse.button` first; a cancelled event returns before
    `m_currentlyHeldButtons` is updated. Otherwise a press is appended to that list *before* it is
    dispatched, so a press a decoration consumes is recorded as held too; a release removes every entry
    of its button, and a release of a button not in the list is dropped. Button events are then
    dispatched by `processMouseDownNormal`: `CKeybindManager::onMouseEvent`, the decorations of
    `windowAt(pos, RESERVED_EXTENTS | INPUT_EXTENTS | ALLOW_FLOATING)` through `CWindow::checkInputOnDecos`
    (box contains point, no popup there), and finally `CSeatManager::sendPointerButton`. After a release
    that empties the list while `m_focusHeldByButtons` is set, pointer focus is recomputed.
  - `CInputManager::mouseMoveUnified`: while `m_currentlyHeldButtons` is not empty (and no drag-and-drop
    runs), pointer focus stays on the current pointer-focus surface whatever is under the pointer
    (`m_focusHeldByButtons`). A stale entry therefore pins pointer focus indefinitely.
  - `CInputManager::releaseAllMouseButtons` sends a release for every held button straight to the seat
    (no `input.mouse.button` event) and empties the list.
  - `CWLPointerResource::sendButton` logs `sendButton release on a non-pressed button` (with its source
    location) and sends nothing when that resource never got the press (`m_pressedButtons`).
  - `CInputManager::destroyPointer` does not release the buttons held by the removed device.
- Measured pitfalls: `Config::Actions::focus()` warps the cursor to the window middle when the pointer is
  on the titlebar (outside the client surface); with it, drags through `CLayoutManager::beginDragTarget` or
  `CKeybindManager::changeMouseBindMode` jumped by (middle − press point). The plugin now focuses through
  `focusState()` and moves the window itself (no snapping); Hyprland's drag path should be re-tested in M1.
- The decoration priority must be above the border's (10005 used): at 10000 the titlebar was placed
  outside the border.
- Appmenu (S5, read from the 0.56.2 headers, exported symbols checked with `nm -D /usr/bin/Hyprland`):
  `g_pCompositor->{m_wlDisplay, m_isShuttingDown}`, libwayland-server 1.26.0 `wl_global_{create, remove,
  destroy}`, `wl_client_get_credentials`, `CWLSurfaceResource::fromResource` and `m_events.destroy`,
  `Desktop::View::IView::resource()`, `Event::bus()->m_events.window.{open, close, destroy, active}`, glibc
  `dladdr`, `dlopen(RTLD_NOW | RTLD_NOLOAD | RTLD_NODELETE)`. Code generator: hyprwayland-scanner 0.4.6
  (`compositor/protocols/appmenu.xml`). Test fixtures: Qt 6.11.2 Widgets/DBus, wayland-scanner 1.26.0, gdbus.
- Overview (M3, read from the 0.56.2 headers; behavior read from the v0.56.2 sources as data, see
  `docs/specs/overview.md` "v2 spike"): `Render::IWindowTransformer` (`transform`), `CWindow::m_transformers`,
  `IHyprRenderer::{m_bRenderingSnapshot, m_renderData.{pMonitor, projectionType, damage}, bindTempFB, draw(CClearPassElement::SClearData),
  draw(CTexPassElement::SRenderData, CRegion), damageBox, damageWindow}`, `Render::RPT_MONITOR`,
  `CMonitor::{resources()->getUnusedWorkBuffer(), m_damage.{hasChanged, damage}, m_transformedSize}` (`resources()` is a
  weak pointer over a unique pointer: never `lock()`ed), `Fullscreen::controller()->getFullscreenModes`,
  `CWorkspace::{m_renderOffset, m_isSpecialWorkspace}`, `CWindow::{m_floatingOffset, m_pinned, getWindowMainSurfaceBox}`,
  `CLayerSurface::m_namespace`, `Event::bus()->m_events.{render.{preChecks, pre}, window.{close, destroy, moveToWorkspace,
  fullscreen, pin, active}, layer.closed, workspace.active, monitor.{removed, layoutChanged}}`.
- Stages (M5 prototype, read from the 0.56.2 headers; exported symbols checked with `nm -D /usr/bin/Hyprland`; behaviour
  read from the v0.56.2 sources as data, see `docs/specs/stages.md` "Spike results"): `CWindow::{setInputBlocked,
  acceptsInput, m_class, m_isFloating, m_pinned, isX11OverrideRedirect}` (`eWindowInputBlockReason` bits 0-2 used by
  Hyprland; the plugin uses `1 << 6`), `CViewHitTester::windowAt` (skips windows that do not accept input),
  `CLayerSurface::{m_layer, m_geometry, resource()}`, `SSurfaceState::{input, inputIsInfinite}`,
  `State::monitorState()->monitors()`, `CEventLoopManager::{doLater, removeDoLater}`, `Event::bus()->m_events.window.{open,
  floating}`. Input guards (FR38, plugin 0.6.1-stages): `CInputManager::simulateMouseMovement` (exported; re-runs
  `mouseMoveUnified` at the cursor), `CSeatManager::{m_state.pointerFocus, m_state.keyboardFocus, m_mouse, m_seatGrab,
  setPointerFocus, sendPointerFrame}` (`setPointerFocus` refuses and logs "BUG THIS" without a pointer device),
  `CWindow::{noInputBlockedReasonsBesides, isHidden}`, `CWorkspace::isVisible`, `CFocusState::{fullWindowFocus,
  rawSurfaceFocus}`, `Event::bus()->m_events.input.{keyboard.key, mouse.axis}` (observed, never cancelled),
  `Desktop::FOCUS_REASON_FFM` (what `CInputManager::refocusLastWindow` uses when a layer releases the keyboard). Plugin
  0.6.3-stages: `CFocusState::resetWindowFocus`, `CHyprXWaylandManager::activateWindow(w, false)`,
  `CWindow::updateDecorationValues`, `CEventManager::postEvent` (`activewindow` / `activewindowv2` with no window),
  `Event::bus()->m_events.window.active.emit(nullptr, …)` (as `CFocusState::rawWindowFocus` does for no window),
  `CWorkspace::isVisibleNotCovered`, `Event::bus()->m_events.input.keyboard.focus`; `CInputManager::m_exclusiveLSes` is
  only read (Hyprland's refusal condition) and `CLayerSurface::onUnmap` emits `layer.closed` before Hyprland's refocus
  (read from the v0.56.2 sources). Desktop focus v2: `CViewHitTester::{layerPopupSurfaceAt, layerSurfaceAt, windowSurfaceAt}`,
  `CMonitor::m_layerSurfaceLayers`, `State::monitorState()->query().vec()`, `IView::aliveAndVisible`. Plugin 0.6.4-stages
  (all exported, checked with `nm -D /usr/bin/Hyprland`): `CWindowRuleApplicator::propertiesChanged` with
  `Desktop::Rule::RULE_PROP_FOCUS`, `CInputManager::{recheckIdleInhibitorStatus, getMouseCoordsInternal}`,
  `CViewHitTester::windowAt` (Hyprland's press hit test flags) and `layerSurfaceAt` / `layerPopupSurfaceAt` on a copy of
  `m_exclusiveLSes`, `Event::bus()->m_events.input.{touch.down, tablet.tip, tablet.button}` (observed, never cancelled);
  read from the v0.56.2 sources: `CInputManager::refocus` is `mouseMoveUnified(…, refocus = true)` and reports
  `FOCUS_REASON_CLICK`; `refocusLastWindow` falls back to it when there is no active window on that monitor; the touch
  down, tablet tip and tablet button handlers emit their bus event before their own `refocus`.
- Cursor refresh (plugin 0.7.0-cursor, read from the 0.56.2 headers `render/Renderer.hpp`, `pointer/cursor/CursorManager.hpp`,
  `pointer/PointerManager.hpp`; exported symbols checked with `nm -D /usr/bin/Hyprland`; behaviour read from the stripped
  binary with `objdump -d`, no source used): `IHyprRenderer::{setCursorFromName(name, force), shouldRenderCursor(),
  m_lastCursorData.{name, surf}}` (public), `Pointer::Cursor::mgr()`, `Pointer::mgr()`, `State::monitorState()->monitors()`,
  `CEventLoopManager::{addTimer, removeTimer}`. `setCursorFromName`: sets `m_cursorHasSurface`; returns when the name is
  unchanged and not forced; assigns the name (self-assignment safe), updates the shape index (timer reset only when it
  changes), resets `surf`; returns when `m_cursorHidden` and not forced; then `CCursorManager::setCursorFromName(name)`
  (theme lookup at the size of the last `changeTheme`). `setCursorHidden(false)`: `surf` → `setCursorSurface(surf, hotspot,
  true)`, else a non-empty name → `setCursorFromName(name, true)`, else `setCursorFromName("left_ptr", true)`.
  `shouldRenderCursor()` = `!m_cursorHidden && m_cursorHasSurface` (both protected).
- Overview close focus (plugin 0.8.0-ovfocus, read from the 0.56.2 headers `desktop/state/FocusState.hpp`,
  `config/shared/actions/ConfigActions.hpp`, `protocols/LayerShell.hpp`, `managers/SessionLockManager.hpp`,
  `state/WorkspaceState.hpp`, `desktop/Workspace.hpp`; exported symbols checked with `nm -D /usr/bin/Hyprland`
  (`Config::Actions::focus`, `Config::Actions::changeWorkspace(PHLWORKSPACE)`); behaviour read from the binary with
  `objdump -d`, no source used): `Config::Actions::focus` runs `changeWorkspace` when needed, then
  `CFocusState::fullWindowFocus(w, FOCUS_REASON_DISPATCH_FOCUSWINDOW = 3)`, then `CWindow::warpCursor`; `changeWorkspace`
  focuses the monitor, `CMonitor::changeWorkspace`, its focus candidate, and may warp the pointer per config. Used:
  `CFocusState::{fullWindowFocus, resetWindowFocus, rawSurfaceFocus, rawMonitorFocus, window, monitor}`,
  `CLayerShellResource::m_events.commit`, `CSessionLockManager::m_events.lock`, `State::workspaceState()->query().id().run()`,
  `CWindow::{acceptsInput, isHidden, m_X11ShouldntFocus}`, `CEventLoopManager::{doLater, removeDoLater, addTimer, removeTimer}`.
  Measured in nested: Hyprland's successor focus of a window closed under the chrome logs "On closed window, new focused
  candidate is …", then "Refusing a keyboard focus to a window because of an exclusive ls", and leaves that window as its
  focused window without the keyboard (a later `fullWindowFocus` of it returns early: hence the state reset); a plugin load
  or unload reloads the config (its monitor rules enable WAYLAND-1 again); a plugin unloaded with appmenu clients alive stays
  mapped and a load of the same path gets the same library (FR23): test a rebuild in a new nested session.
- GCC 16.2.1, C++23. Lua 5.5 headers (Hyprland links `liblua.so.5.5`). GoogleTest 1.18.0 for tests.
- Quickshell 0.3.1 for the IPC spike.

## Degraded behavior (plugin missing, service missing)

- ABI mismatch: no hooks, one notification, no `grassfield` event, `hyprctl grassfield` unknown → the
  shell sees no capabilities and keeps client-side decorations (§5.6).
- Init failure: everything registered so far is torn down, one notification, same fallback.
- Minimize without the `minimize` feature (plugin absent, mismatched, or its hooks failed): the shell parks
  the window on `special:minimized` itself (no animation) and restores it from there; same hidden state, so
  windows minimized either way stay restorable after the plugin comes or goes.
- Funnel unavailable (Vulkan renderer, shader failure, a GL error, custom elements not drawn, transformed monitor, tile
  behind the window): that animation uses the shrink effect, a running one included (FR44, FR46). A plugin without
  `minimize-effect` (older build): the shell sends no `minimizeEffect` and the plugin keeps its own animation.
- Minimize without a Dock (no shell, or no target rectangle): the shell sends an empty rectangle and the
  plugin minimizes/restores without animation; with no shell at all, the minimize button only posts
  `minimize-request` and nothing happens (there would be no way to restore the window).
- Without the `config` feature the double-click always zooms (the plugin's own default; Zoom is Fill with
  `window-tiling`). Without `window-tiling` (or `zoom-fill` for the shell's Window > Zoom) Zoom is Hyprland's
  maximized mode, as before ADR-0036 D78 (gate C2).
- Without the `appmenu` feature (plugin absent, mismatched, or the global failed): no
  `org_kde_kwin_appmenu_manager` global, no `appmenu` events; the shell keeps T0 menus. Whoever owns
  `com.canonical.AppMenu.Registrar` (the bridge, step B) must not own it then: Qt would hide its in-window menu
  bars with nowhere to show them (S5 finding 4).
- Without the `overview` feature (plugin absent, mismatched, or its listeners failed): `hl.plugin.grassfield.overview`
  does not exist and the shell keeps the v1 thumbnails. A refused request (`invalid`, `no-windows`, `no-chrome`) or an
  unload during an overview (`unavailable`) is reported in the `overview` event, so the shell can fall back for that open.
- Without the `desktop-focus` feature (plugin absent, mismatched, its listeners failed, or withdrawn at unload): Hyprland's
  own focus handling only; the shell keeps its kicker surface and pointer-leave drop and no file-changing desktop keys
  (ADR-0012 amendment). The unload posts a capabilities event with no feature (FR32) so the shell switches at once.
  Without `desktop-focus-v2` the shell keeps the file-changing desktop keys off (shell main 23caeab).
- Without `stages-available` (plugin absent, mismatched, its listeners failed): no Stages at all; Quick Settings hides the
  toggle. With it but the flag off: `stages` is not advertised and the verb refuses (`disabled`). A monitor without the
  shell's strip surface: its windows are shown normally.
- Without `cursor-refresh` (plugin absent, mismatched, an older plugin, or withdrawn at unload): the shell still sends
  `setcursor` and sends no refresh (`shell/platform/Pointer.qml` checks the capability; the call is guarded anyway); the
  pointer keeps its previous size until the shape name changes: entering another surface that sets the same shape
  (desktop → Dock, both `default`) is not enough, since `setCursorFromName` returns for an unchanged name. Measured:
  `tests/compositor/cursor_refresh.sh baseline` and the unload step of `check`.
- Without `overview-focus` (plugin absent, mismatched, an older plugin, its listeners failed, or withdrawn at unload): the
  verb does not exist (the shell's guarded call is a no-op) and the shell restores the focus after the Overview itself (checks
  and retries: `FocusReturn.startFallback`, docs/specs/overview.md "Close and keyboard"). An unload while a request waits posts outcome `unavailable` first. Measured:
  `tests/compositor/overview_focus.sh baseline` (an older build, a `--no-plugin` session) and case 14 of `check`.
- Without `layer-pointer` (plugin absent, mismatched, an older plugin, its listeners failed, or unloaded): Hyprland's own
  pointer focus. Every shell surface works; on an output away from the layout origin a click with no pointer motion since a
  menu, Search or another shell layer that takes the keyboard opened is delivered to the wrong place (the bar menu stays
  open) until the pointer moves by one pixel; a real mouse moves, a trackpad tap may not. Measured:
  `tests/compositor/layer_pointer.sh` with the plugin unloaded (map cases KNOWN, the others PASS) and the same with
  `--expect plugin` (FAIL, the defect shown).

## Automated tests · Manual verification steps

Automated (L0): `compositor/build/grassfield-compositor-tests` — protocol JSON (wire format, escaping,
advertised features, config allowlist), button layout, hit-testing, title placement, double-click detection,
drag threshold and un-zoom box, theme values, pointer press ownership and gesture end (`PointerGesture.*`),
minimize logic (`Minimize*`: address parsing, target validation, aspect fit, Bézier easing, frames,
snapshot texture box on the same and on another monitor), appmenu logic (`Appmenu*`: bus name and object path
validation, registrations and their announcements; `Protocol.Appmenu*`: event JSON), event and log rate limits
(`TokenBucket.*`, `EventThrottle.*`, `LogLimiter.*`, `LogMilestone.*`, FR24), overview logic (`Overview*`: payload
parsing and validation, bounds, timing, interpolation, texture box, event JSON, FR25-FR28). Shell side: `tests/unit/tst_minimized.qml`
(request builders, config allowlist, `movewindowv2` parsing). Lint (Q1): `compositor/build-direct.sh tidy`
(`compositor/.clang-tidy`). Soak (C1): `tests/compositor/soak.sh [seconds]` (see `compositor/README.md`).
Nested scenarios: `tests/compositor/minimize.sh [repeats] [stages]` (FR6, FR14–FR17; since 0.6.4-stages it clicks the
Dock tile the shell itself sent with the minimize, read from the plugin's log line "minimize <hex>: toward the Dock
rectangle x,y wxh" (a log budget of its own: 20 at once, then 2 per second) through `scripts/nestctl rollinglog -f`
(line-buffered with `stdbuf -oL`), never a position computed from the Dock layout; the Dock fix
pass 31458f5 (recents, dividers) had made the computed tile drift), `tests/compositor/double_click_setting.sh` (FR8, FR16), `tests/compositor/zoom_restore.sh`
(FR8), `tests/compositor/input_consistency.sh [rounds]` (FR13), `tests/compositor/appmenu.sh [variants]`
(FR18–FR22, spike S5; fixtures `tests/fixtures/{menu-demo, fake-registrar, appmenu-client}`, built by
`tests/fixtures/build.sh`), `tests/compositor/event_flood.sh [requests...]` (FR24; needs grassfield-shell),
`tests/compositor/overview.sh [check | perf [seconds]]` (FR25-FR29; fixture `tests/compositor/overview-fixture`),
`tests/compositor/desktop_focus.sh [check | baseline | race | stale]` (FR30-FR32; fixture `tests/compositor/desktop-focus-fixture`),
`tests/compositor/stages.sh [check | perf [seconds]]` (FR33-FR37; fixture `tests/compositor/stages-fixture`),
`tests/compositor/genie.sh [timing N | c2 [X Y]]` (FR44-FR46: effects, shape of slow-motion captures classified by
`tests/compositor/genie_shape.py`, frame timing verdict with every stall and the host load shown, unload / load mid-animation,
the funnel shader failure through the dev fault injection; `c2`: the fallback without the plugin).
Unit tests `Genie*` and `MinimizeEffect.*` cover the funnel geometry, mesh, timing, the effect allowlist and the dev-only fault key.
Unit tests also cover the desktop focus policy (`DesktopFocus*`: decision table, layer classification, pending grant,
press target source), Stages (`Stages*`: model, request validation, thumbnail geometry, events, flag) and the cursor
refresh (`CursorRefresh.*`: verb and feature names as the shell sends them, advertised list, decision table, log names,
rate gate). Nested: `tests/compositor/cursor_refresh.sh [check | baseline | stress [seconds]]` (FR39-FR40),
`tests/compositor/overview_focus.sh [check | baseline] [--plugin PATH]` (FR41-FR43; fixture
`tests/compositor/overview-focus-fixture`, the foreign locker `tests/security/foreign_locker/ForeignLocker.qml`). Unit tests
also cover the overview focus (`OverviewFocus*`: request validation, gate, target plan, fallback Desktop, front window order,
presses, user focus, events, capability) and the shared deferred focus (`DeferredFocus*`), and the layer pointer focus
(`LayerPointer.*`: namespaces, one refresh per burst, waiting for the release or a pointer device, the press fallback, the
feature). Nested: `tests/compositor/layer_pointer.sh [check | probe] [--output NAME] [--expect plugin | degraded]` (FR51-FR52:
clicks without motion on a bar menu opened by a press, from a new pointer device and by IPC; the 1-px control; a click after
a menu closed over a window; C2 and an older build through `--expect`).

Manual (L1, nested only):

1. Build: `compositor/build-direct.sh`.
2. Start: `scripts/dev/nested-up.sh` (`config/hypr/dev.lua` loads `GRASSFIELD_PLUGIN` at parse time; a load
   from a `hyprland.start` callback would be ignored because Hyprland applies the config's plugin list right
   after parsing; fixed in commit eaa953c, the S2 shim is gone).
3. Log (`$XDG_RUNTIME_DIR/hypr/<nested instance>/hyprland.log`):
   `[grassfield] grassfield-compositor 0.3.0-s5 initialised on Hyprland v0.56.2 (commit …), ABI hash match`.
   Hyprland buffers this log: lines written after start-up can appear only much later.
4. `WAYLAND_DISPLAY=$(cat .dev/nested.wayland) setsid foot >/dev/null 2>&1 &`, then
   `scripts/dev/shot.sh titlebar GF-REF`.
5. IPC: `WAYLAND_DISPLAY=… HYPRLAND_INSTANCE_SIGNATURE=… timeout 10 qs -p spikes/s2-ipc/shell.qml`.
6. Pointer (`tests/tools/vpointer`, coordinates relative to an output): e.g.
   `scripts/dev/pointer.sh output GF-REF abs 960 250 down drag 700 400 up`. Abandoned drag (FR7):
   `scripts/dev/pointer.sh output GF-REF abs 960 250 down drag 800 350` (no `up`), then
   `scripts/dev/pointer.sh output GF-REF abs 1400 700 sleep 200 abs 300 300 click`: the window must not move.

## Performance (gates affected) · Accessibility · i18n

- C1: soak script `tests/compositor/soak.sh` (nested only). 2026-10-17, plugin 0.2.0-m2 (minimize, config,
  drag threshold / un-zoom): `tests/compositor/soak.sh 600` → PASS, exit 0 (600 s, 352 rounds: 352
  short-lived + 352 churn windows, 88 drags, 44 abandoned drags, 88 zoom pairs, 44 cancelled and 44 real close
  clicks, 44 minimize + Dock-restore pairs; nested Hyprland alive, RSS 151.6 → 159.8 MB, flat from round 100
  to the end, no core dump, 0 grassfield exceptions in the flushed log, 210 seat warnings as designed). Most
  soak minimize pairs ran without animation: the Dock rectangle of `Quickshell.screens[0]` (the resizable
  nested WAYLAND-1 window, resized by the owner's session layout during the run) was rejected (90 "no valid
  Dock rectangle" log lines). The animated path ran in `minimize.sh`: 20 + 60 rounds on fresh instances,
  42 animated minimizes and 47 animated restores (move → event ≥ 250 ms), 5 + 15 Dock clicks 120 ms after
  the minimize click (normally during its animation), 2 + 2 windows killed 100 ms after a minimize / restore
  click, PASS, no core dump. Shutdown (SIGTERM) right after a minimize
  click: `[grassfield] grassfield-compositor unloaded`, `Hyprland has reached the end.`, no core dump (that
  minimize had no animation, see above). Earlier, plugin at commit 62bd114 (FR13
  fix, button events never cancelled): `tests/compositor/soak.sh 600` → PASS, exit 0 (600 s, 319 rounds:
  319 short-lived + 319 churn windows, 91 drags, 46 abandoned drags, 92 zoom pairs, 45 cancelled and 45 real
  close clicks; nested Hyprland alive, RSS 150.4 → 165.9 MB, flat over the last 200 rounds, no core dump,
  0 grassfield exceptions). 168 seat warnings `sendButton release on a non-pressed button`: the releases of
  titlebar presses that ended outside a titlebar while a client had pointer focus, dropped by the seat as
  designed (FR13). `tests/compositor/input_consistency.sh 5` right after the soak, same instance → PASS.
  Earlier run (plugin at commit a475092, releases still cancelled on the bus): `soak.sh 1260` → PASS
  (758 rounds, RSS 151.7 → 158.5 MB), but that build had the held-button defect, which the soak does not
  detect. The 1 h and 8 h runs are scheduled: C1 stays NOT VERIFIED until the 8 h run passes. C2 (scripted
  degradation) not run.
  FR24 (event throttle, 2026-10-17): `soak.sh 1200` → PASS (711 rounds, 89 animated minimize pairs, RSS
  152.1 → 159.0 MB, no core dump, 0 grassfield exceptions) on the build before a tidy-only refactor of
  `CEventThrottle::due`/`drain`; on the final build `soak.sh 600` → PASS (354 rounds, 44 animated minimize pairs,
  RSS 152.3 → 160.6 MB, no core dump, 0 exceptions), `minimize.sh` 20 rounds PASS, `input_consistency.sh` PASS,
  `appmenu.sh` PASS, `event_flood.sh` PASS, `tests/integration/global_menus.sh` 26/26 PASS (a first run failed
  1 check: transient shell QML warnings in phase B, which runs without the plugin).
  Plugin 0.5.0-df (desktop focus + overview R13 fixes, 2026-10-18): `soak.sh 660` → PASS, exit 0 (log
  `.dev/soak-20261018-085426.log`: 391 rounds, 97 drags, 49 abandoned, 98 zoom pairs, 49 cancels, 49 closes, 49 minimize
  pairs all animated; RSS 152.3 → 160.6 MB, flat from round 100; no core dump; 0 grassfield exceptions; 224 seat
  warnings as designed); then on a fresh instance `desktop_focus.sh` 21/21, `overview.sh check` 29/29,
  `input_consistency.sh`, `minimize.sh`, `appmenu.sh`, `event_flood.sh` PASS, `tests/integration/global_menus.sh` 30/30
  PASS (phase B without the plugin). C2: `nested-up.sh --no-plugin` → `hyprctl grassfield` unknown, shell log
  "no compositor plugin reply, running in degraded mode".
  Plugin 0.6.0-stages (desktop focus v2, relaxed overview chrome rule, Stages behind its flag, 2026-10-18): `soak.sh 660`
  → PASS, exit 0 (log `.dev/soak-20261018-131749.log`: 390 rounds, 97 drags, 49 abandoned, 98 zoom pairs, 49 cancels, 49
  closes, 48 minimize pairs all animated; RSS 152.4 → 159.4 MB, flat from round 100; no core dump; 0 grassfield
  exceptions; 224 seat warnings as designed; Stages flag off, its default); `desktop_focus.sh` 26/26, `overview.sh check`
  32/32, `stages.sh check` 40/40, `input_consistency.sh`, `minimize.sh`, `appmenu.sh`, `event_flood.sh` PASS,
  `tests/integration/global_menus.sh` 31/31 PASS. C2: `nested-up.sh --no-plugin` → `hyprctl grassfield` "unknown request",
  `hl.plugin.grassfield` is nil (an unguarded call errors; the shell guards every verb), shell log "no compositor plugin
  reply, running in degraded mode".
  Plugin 0.6.1-stages (Stages input guards, R13 review of 46b3e9b, 2026-10-18, Hyprland v0.56.2 commit efb50993):
  `soak.sh 660 stages` → PASS with Stages on (log `.dev/soak-20261018-201156.log`: 372 rounds, 74 moves into new strip
  stages, 52 swaps, 1393 stages events, 46 minimize pairs all animated, 0 Dock clicks skipped and every one on the
  minimized foot tile; RSS 152.5 → 160.8 MB, flat from round 100; no core dump; 0 grassfield exceptions; 226 seat warnings
  as designed); Stages off: `desktop_focus.sh` 26/26, `overview.sh check` 32/32, `input_consistency.sh`, `minimize.sh`,
  `appmenu.sh`, `event_flood.sh` PASS; Stages on: `stages.sh` 45/45, `minimize.sh stages` PASS;
  `tests/integration/global_menus.sh` PASS (41 checks). C2: `nested-up.sh --no-plugin` → `hyprctl grassfield` "unknown
  request", `hl.plugin.grassfield.stages(...)` errors (nil `grassfield`), no `[grassfield]` line in the nested log, shell
  log "no compositor plugin reply, running in degraded mode".
  Plugin 0.6.2-stages (Stages fix pass 2, R13 counter-review of 17208af, 2026-10-19, Hyprland v0.56.2 commit efb50993, host
  loaded by other agents' sessions, load average ~6): `soak.sh 360 stages` → PASS (log `.dev/soak-20261019-083846.log`:
  166 rounds, 33 moves into new strip stages, 23 swaps, 594 stages events, 17 minimize pairs all animated (3 skipped, no
  move seen); RSS 151.4 → 161.0 MB; no core dump; 0 grassfield exceptions; 86 seat warnings as designed). A first
  `soak.sh 360 stages` on another fresh instance ended at round 20 (`.dev/soak-20261019-082810.log`): the nested Hyprland
  vanished without a core dump, a crash report or a log line, a foot of the run was SIGKILLed at the same moment and
  xdg-desktop-portal-hyprland segfaulted on its lost connection; no OOM or systemd-oomd entry in the journal; cause not
  found (not reproduced). Stages on: `stages.sh` 51/51 (two runs, one with GF-REF only, one with GF-REF and WAYLAND-1),
  `minimize.sh stages` PASS; Stages off: `desktop_focus.sh` 26/26, `overview.sh check` 32/32 (a first run 31/32: the
  WAYLAND-1 probe window opened on GF-REF, the rerun passed). C2: `nested-up.sh --no-plugin` → `hyprctl grassfield`
  "unknown request", `hl.plugin.grassfield.stages(...)` errors (nil `grassfield`), 0 `[grassfield]` lines, shell log "no
  compositor plugin reply, running in degraded mode"; under an Exclusive layer `hl.dsp.window.close()` closes Hyprland's
  active window as usual (no Stages, nothing hidden).
  Plugin 0.6.3-stages (Stages fix pass 3, R13 counter-review #3 of e9ebc7f, 2026-10-19, Hyprland v0.56.2 commit
  efb50993, two outputs, host load ~2): `soak.sh 1260 stages` → PASS (log `.dev/soak-20261019-131315.log`: 764 rounds,
  152 moves into new strip stages, 108 swaps, 2579 stages events, 95 minimize pairs all animated, 0 skipped; Hyprland
  alive, RSS 161.0 MB from round 100 to the end; no core dump; 0 grassfield exceptions); `soak.sh 1260` with Stages off →
  PASS (`.dev/soak-20261019-133750.log`: 771 rounds, 96 minimize pairs, RSS 160.7 MB flat, no core dump, 0 exceptions).
  The Stages-on run used the build before the version-string change (code identical); the Stages-off run, the final
  `stages.sh` run and C2 used the 0.6.3-stages build.
  Plugin 0.7.0-cursor (cursor refresh, 2026-10-19, Hyprland v0.56.2 commit efb50993): `soak.sh 900` → PASS, exit 0 (log
  `.dev/soak-20261019-151502.log`: 546 rounds, 137 drags, 69 abandoned, 136 zoom pairs, 68 cancels, 68 closes, 68 minimize
  pairs all animated, 0 skipped; RSS 152.7 → 162.2 MB from round 100 to 500 → 160.8 MB at the end; no core dump; 0 grassfield
  exceptions; 320 seat warnings as designed) with `cursor_refresh.sh stress 880` running at the same time (7499 verb calls
  at 10/s, 250 `pointer.size` changes through the shell, 0 failed calls, `cursor-refresh` still advertised); then on the
  same build `overview.sh` 32/32, `desktop_focus.sh` 26/26, `minimize.sh` PASS, `cursor_refresh.sh check` PASS. C2:
  `nested-up.sh --no-plugin` → `cursor_refresh.sh baseline` PASS (FR39-FR40 row).
  Plugin 0.8.0-ovfocus (overview close focus, 2026-10-19, Hyprland v0.56.2 commit efb50993, GF-REF + WAYLAND-1): `soak.sh 1260`
  → PASS, exit 0 (log `.dev/soak-20261019-194150.log`: 732 rounds, 183 drags, 92 abandoned, 184 zoom pairs, 91 cancels, 91
  closes, 90 minimize pairs all animated, 1 skipped (no move seen); RSS 159.1 MB at rounds 600-700, 157.8 MB at the end; no
  core dump; 0 grassfield exceptions; 418 seat warnings as designed) with `overview_focus.sh stress 1200` running at the same
  time (4239 overview focus requests at ~4/s over the churned windows, 423 invalid, every one answered, `overview-focus` still
  advertised); `stress 180` alone afterwards: 647 requests, 2 floods of 100 each answered with one outcome. 0 i915 fence
  timeout or GPU hang lines in `journalctl -k` during the runs. C2: `nested-up.sh --no-plugin` → `hyprctl grassfield` "unknown
  request", shell "running in degraded mode", `overview_focus.sh baseline` safety PASS (FR41-FR43 row).
  Plugin 0.12.0-pointer (layer pointer focus after the merge with window tiling, 2026-10-22, Hyprland v0.56.2 commit efb50993,
  GF-REF + WAYLAND-1, host load 0.8-4.6): `soak.sh 600` (shortened C1 run) → PASS, exit 0 (log `.dev/soak-20261022-231710.log`:
  351 rounds, 87 drags, 44 abandoned, 88 zoom pairs, 44 cancels, 44 closes, 44 minimize pairs all animated, 0 skipped; RSS
  154.8 MB at the start, 163.1 MB at rounds 100-300, 161.8 MB at the end; no core dump; 0 grassfield exceptions; 201 seat
  warnings as designed); `layer_pointer.sh check` PASS on the same instance right after. C2: FR51-FR52 row. The 1 h and 8 h
  runs were not made for this build.
  **Nested Hyprland losses (C1 investigation).** The reviewer's `soak.sh 1260 stages` on e9ebc7f lost the nested Hyprland
  at round 554 (10:46:19). Findings: its log ends mid-stream with no shutdown line (a SIGTERM stop logs "Hyprland
  received signal 15" and "Hyprland has reached the end", as 60+ other nested logs of that day did), no crash report, no
  core dump, no kernel segfault or OOM line and no systemd-oomd action in the journal (previous boot, from 2026-10-18
  21:00); xdg-desktop-portal-hyprland segfaulted 0.5 s later inside `exit()` on its lost connection (a consequence, seen
  at every loss). Among the nested instances whose logs survived until the 11:31 power loss, five ended this way:
  2026-10-18 22:24 and 22:48 (another worktree, overview work, Stages never turned on), 2026-10-19 07:33 (a 9 s old
  instance, no Stages), 08:28 (fix pass 2's first soak, a foot of the run SIGKILLed at the same moment) and 10:46 (the
  reviewer). Two of five never used Stages, so the losses are not tied to Stages; a loss without any log line, core dump
  or crash report matches a SIGKILL from outside (the crash handler covers SIGSEGV/SIGABRT, SIGTERM is logged, an OOM
  kill is logged by the kernel). The sender of a SIGKILL is not recorded without root tools (audit, BPF): NOT identified.
  This pass ran each soak under a dev-only supervisor (scratch `.dev/fp3/supervise.py`, not tracked: it detaches from the
  agent's tools, makes itself the child subreaper and runs `nested-up.sh`, so Hyprland's wait status is recorded, and
  samples Hyprland every 10 s). Both 1260 s runs kept the nested Hyprland alive; it exited only at `nested-down.sh`,
  "exited with status 0". Samples (Stages on / off): RSS 151.2 → max 166.7 → 152.8 MB / 153.5 → max 166.4 → 152.5 MB after
  the run; fds 120 → max 177 → 141 / 128 → max 149 → 124; sockets back to 27 both times: no growth. The 11:31 stop was
  a power loss of the machine (external, not this pattern).
  Title textures are cached per window and rebuilt only when the title, scale or available width changes;
  drawing adds 6 rect pass elements and 1 texture per decorated window.
- Q1: `compositor/build-direct.sh tidy` must exit 0 with no diagnostics. 2026-10-22, plugin 0.12.0-pointer (merged tree, 47
  translation units; build-direct.sh now lists the tiling sources, which the tiling merge had added to CMake only): exit 0,
  0 diagnostics in the layer-pointer files, 3 `bugprone-unchecked-optional-access` warnings in the window-tiling code
  (`src/Tiling.cpp:159`, `:171`, `tests/TilingTest.cpp:106`), left to that feature's owner.
- Accessibility: titlebar buttons are compositor-drawn and not exposed to assistive technologies; keyboard
  equivalents exist (SUPER+W close, SUPER+ALT+F zoom).
- i18n: no plugin strings are shown except the degradation notifications (English, compositor-side).

## Activation model spike (2026-10-22): no-go on Hyprland 0.56.2

Goal (macOS model, `docs/specs/dock.md` requirement 21): an app may take the focus when its activation follows user input
(a link clicked in one app brings the browser forward); otherwise its Dock icon bounces and the focus stays. Grassfield keeps
`misc.focus_on_activate = true` (every request focuses); `false` would only mark every request urgent. Question: can the
plugin see each request with its origin and token validity and decide per request (focus when the token is valid and recent,
else urgent without focus)? Sources: the installed headers and the 0.56.2 binary (`objdump` of the handlers named below; no
Hyprland source is installed).

What Hyprland 0.56.2 does:

- xdg-activation (`src/protocols/XDGActivation.hpp`): a token's `set_serial`, `set_app_id` and the issued string are stored in
  `CXDGActivationToken` (`m_serial`, `m_appID`, `m_token`: private), the issued tokens in `CXDGActivationProtocol::m_sentTokens`
  (private). The commit handler issues a token for every commit (`CTokenManager::registerNewToken`, `sendDone`) without
  consulting the seat; the `activate` handler only looks the string up in `m_sentTokens` (unknown: "activate event for
  non-existent token"), erases it, resolves the surface to a window (else "non-window or gone surface") and calls
  `CWindow::activate(false)`. The serial is never compared with an input serial and the creating client is never compared
  with the focused one: every issued token is "valid", whoever asked and whenever.
- X11 `_NET_ACTIVE_WINDOW`: the XWM turns it into `CXWaylandSurface::events.activate`, a `CSignalT<>` with no payload (the
  source indication and the timestamp are not passed on), handled by `CWindow::activateX11` (private listener), which
  compares the window's PID with the focused window's (`CWindow::getPID`), asks `CXWaylandSurface::wantsFocus` and ends in
  `CWindow::activate(false)` (calls read from the binary; the branches between them not traced).
- `CWindow::activate(bool force)` (public): in call order in the binary, it checks Hyprland's focused window, posts
  `urgent>>ADDRESS`, emits the event bus `window.urgent` (`Event<PHLWINDOW>`, not cancellable), then reads
  `misc:focus_on_activate` and focuses. The per-window inputs of that decision are public in the headers
  (`CWindowRuleApplicator::focusOnActivate`, `m_suppressedEvents` with `SUPPRESS_ACTIVATE` / `SUPPRESS_ACTIVATE_FOCUSONLY`,
  `m_isUrgent`); how `activate` combines them follows Hyprland's documented rules and was not traced instruction by
  instruction.

What a plugin can see: only `window.urgent` with the window, after the decision inputs are gone (no origin, no token, no
serial, no timestamp), and before the focus. Every request kind looks the same there.

Ways to get the macOS behaviour, and why none is taken:

1. A function hook (`HyprlandAPI::createFunctionHook`) on `CWindow::activate` or on the activate handler (an unnamed lambda):
   patches Hyprland's code at run time, and even then the token's serial and creator are private and unchecked. Excluded
   (no patching of Hyprland).
2. From the `window.urgent` listener, set `SUPPRESS_ACTIVATE_FOCUSONLY` in the window's public `m_suppressedEvents` when the
   request does not "follow user input", and clear it afterwards: the bit is owned by window rules (`suppress_event`), so a
   rule update in between would be lost or clobbered; and "follows user input" could only be guessed from the timing of the
   last key or button press (no token data): a slow browser start would bounce instead of coming forward, a background app
   asking right after a click elsewhere would steal the focus. Not the token rule asked for; not a documented hook.
3. Replace Hyprland's `xdg_activation_v1` global with the plugin's own (as for the appmenu global, FR18) to check serials
   itself: Hyprland's global, token list and the seat's serial history are private, clients bind whichever global they see
   first, and live tokens would break at unload. Invasive, no graceful degradation.

Decision: **no-go**, nothing implemented; `focus_on_activate = true` stays (activation always focuses; urgency without
activation still bounces). Needed upstream for a later attempt: Hyprland validating the token (serial from the focused
client's recent input, as other compositors do) and exposing the result, e.g. a cancellable event bus `window.activate` with
the window, the source (xdg-activation, X11, foreign toplevel) and the validity; the plugin decision would then be a small pure
rule (valid and recent: focus; else `urgent` only) with graceful degradation (no event: Hyprland's behaviour).

## Plugin work item: client chrome (ADR-0015)
Grassfield apps draw their own lights and toolbar (grassfield-ui `WindowControls` / `UnifiedToolbar`) and tag their window
with an xdg-toplevel tag (`browser`, `settings`, `viewer`, `info`; apps/windowchrome.h). The plugin steps aside for those
windows. Full text and rationale: docs/decisions/ADR-0015-unified-toolbar.md, "Implementation: app side ... and the plugin
work item". P1-P7 are implemented (`core/ClientChrome.*`, `ClientChrome.*`, `Titlebar.cpp`, `core/Stages.*`, `Theme.hpp`;
plugin 0.14.0), P8 since GF-056 part 2, P9 (an app whose decoration requests prove a bar of its own) since the 1.0.0-rc6
report; the app side, S1-S3 and H1 were done before. Unit tests: `tests/ClientChromeTest.cpp`.
A window tagged after it mapped (a rule change) loses its strip on `window.updateRules`; its bridges P4 and P5 check the tag
when they run, P8 is re-evaluated there.

| Id | Change | Test |
|---|---|---|
| P1 | `isClientChrome(window)`: the window's Hyprland tags hold `grassfield-client-chrome` (a dynamic tag prints with `*`); `Titlebar::shouldShow()` is false for it; re-evaluated on `window.updateRules`; never `decorate = false` | GTest on the predicate; `client_chrome.sh` assertion 3 |
| P2 | gfc/1 feature `client-chrome` (additive, ADR-0007), advertised only when P1 is registered | `Protocol.*` GTest |
| P3 | Stages band (`core/Stages.cpp:486-489`, `Stages.hpp:49`) uses P1: band 0 for a tagged window | `StagesTest`, `stages.sh` |
| P4 | `requestMove` for tagged windows: a zoomed window restores its remembered box under the pointer at the same grab ratio, then moves (FR8 for the app-drawn row). Done: the press is recorded before Hyprland handles it (the window is still zoomed then); the move request that answers it (same window, button held, within 3 s) leaves the zoom if Hyprland's own handler did not, places the floating size by `titlebar::unzoomedDragBox`, then ends the move Hyprland started and begins one from there (`CLayoutManager::endDragTarget` / `setTargetGeom` / `beginDragTarget`) | `ClientChromeZoomedDrag.*` GTest; `client_chrome.sh` assertion 10 |
| P5 | minimize bridge for tagged windows: `stateChanged` with `requestsMinimize` runs the FR6 path (`minimize-request`, `special:minimized`) | `client_chrome.sh` assertion 5 |
| P6 | the plugin titlebar's green button with Alt held: true full screen (`FSMODE_FULLSCREEN`), glyph = full-screen arrows while Alt is held over the group (REQ-ADR0002-6, plugin part). The way back (review 2026-10-23: no pointer way out of full screen): the pointer within 2 px of the monitor's top edge reveals the window's titlebar, square, over its content, below the shell's menu bar (`grassfield-menubar` layer height on that monitor, at most 64 px; 0 without it); it stays while the pointer is within 8 px below it or a press on it is held, and goes with the full screen. A Split View member's titlebar (tiling step 6e, ADR-0036 D73-D75) is away the same way: the pointer at the top edge over its half reveals that half's bar alone, the other half's comes when the pointer moves across within the bar's band (the revealed bar keeps the gap between the halves), and no other bar comes while a press on a revealed bar is held; a left press away from its lights drags the member, hanging below its bar (swap over the other half, else back in its half). Its zoom light (arrows) leaves full screen, close closes, minimize is grey and inert (macOS). Hyprland 0.56.2 draws no decoration on a full-screen window and places decoration input above the window, outside the monitor, so the revealed bar is drawn at `RENDER_POST_WINDOWS` (under the overlay layers) and its presses are taken on the bus: a press inside it and the release of that press are cancelled together. `CInputManager::onMouseButton` returns right after the bus when an event is cancelled, before it records the button as held or released (read from the binary: the `cancelled` test follows `emitInternal`, the held-button list is touched after it), so the pair leaves Hyprland's held-button state unchanged; a release still owed when the same button is pressed elsewhere was lost and is forgotten (never cancel a release Hyprland expects). The bus event names no device and Hyprland's held buttons are per button, so a press is taken only when no device holds that button already (another device's release of the same button can then never be mistaken for the bar's). What Hyprland holds is known only once the plugin has seen it hold nothing (`core CHeldButtons`): until then no press is taken (a button held when the plugin loaded would otherwise delay its device's release behind a bar press). While the session is locked no light acts, an armed one included, and nothing is logged. Each press over the revealed bar logs one INFO line, with no position: taken (and which light), or left to Hyprland and why; each release of an armed light whether it acted. Never revealed while the session is locked, while the client confines or locks the pointer (`CInputManager::isConstrained`: a game that scrolls at the screen's edge must not meet a working close light), during a move or resize (`CDragStateController::mode`) or a drag and drop, or under a special workspace shown on the monitor; never taking a press under a layer popup or an Overlay layer (review of part B, 2026-10-24). The cheap test (the pointer at the top edge) runs first on every motion. Logic pure (`core/ClientChrome.*`: `nextRevealed`, `lightAvailableInFullscreen`, `CRevealPresses`). Since tiling step 6c (ADR-0036 D65) the plugin posts `titlebar-reveal` {output, revealed} on each change of the outputs with a revealed bar (its reveal, its going away, the window leaving full screen or closing, the unload), and the shell's menu bar there comes into view with it and leaves with it. Not covered: direct scanout of a full-screen window (no composition, so no bar) | `ClientChromeZoomLight.*`, `ClientChromeFullscreenTitlebar.*` GTests; `zoom_restore.sh` cases 6 and 7 (7: a click where the light would be, coming from below, stays the window's; top edge then the light leaves full screen); `fullscreen_reveal.sh` (a mouse-reporting foot gets neither the press nor the release of a click on the bar; minimize inert; an Overlay layer over the lights keeps its press; nothing while locked; the way out) |
| P7 | the light constants come from `window.*` of `ui/tokens/tokens.json` (generated, or a GTest comparing `Theme.hpp` with it) | GTest |
| P8 | minimize capability (GF-056 part 2): GTK4 greys a minimize button the compositor does not offer, and Hyprland 0.56.2 sends every toplevel `wm_capabilities` fullscreen and maximize, once, from `CXDGToplevelResource`'s constructor (read from the binary). A tagged window, while the P5 bridge runs, is sent `wm_capabilities` again with minimize added (`core wmCapabilities`: fullscreen, maximize, minimize; the protocol's enum), then Hyprland's own full configure (`CXDGToplevelResource::setSize` with `m_pendingApply.size`: an `xdg_toplevel.configure` with its current states, then the `xdg_surface.configure`; no early return in the binary). A bare `xdg_surface.configure` is not enough: GTK4 then applied an empty state set (no longer activated or tiled). The toplevel's `wl_resource` is private: found among its client's resources (`wl_client_for_each_resource`, class `xdg_toplevel`, `CXDGToplevelResource::fromResource`); a resource is read with `fromResource` only when it is an `xdg_toplevel` of v5 or later that still has its user data (`core capabilityCandidate`: `fromResource` reads the user data without a check, and it is null while the resource is destroyed). Nothing below xdg_toplevel v5: a window whose resource is not found is remembered as unreachable and never walked again (`core needsTell`). Sent at map (`window.open`) and on `window.updateRules` only when the answer changes; on unload every window told minimize is told Hyprland's own capabilities again (C2: the button greys again), and so is a window told minimize when it unmaps (`window.close`; the event only, its next map carries it in a new configure sequence), so that a toolkit that hides a window and keeps its toplevel cannot keep a minimize button nothing answers after an unload. The click sends `set_minimized`, which P5 routes to the titlebar light's path | `ClientChromeCapabilities.*` GTests (the candidate test, told once, unreachable never again); `third_party_chrome.sh` (Nautilus's own minimize minimizes to the Dock tile and the tile restores it); nested by hand: unload and load with Nautilus open (WAYLAND_DEBUG `wm_capabilities` array[12] / array[8] / array[12], the button enabled / grey / enabled, the window stays active at its size) |
| P9 | the decoration the client negotiated (owner report on 1.0.0-rc6: Telegram and the ArtCraft suite showed two title bars; Google Chrome, not in S1b, too). The protocol is read first, but it tags a window only when it proves the client draws a bar of its own (core `drawsOwnTitlebar`; review of 3ca47a4b, which tagged on any xdg client_side request and on "nothing negotiated", and so took the only bar from imv and from `foot -o csd.preferred=client`): a KDE server-decoration request for client mode (`org_kde_kwin_server_decoration.request_mode` client: GTK 3 and GTK 4 header bars, libadwaita), or a client that bound one of the two decoration managers (`zxdg_decoration_manager_v1`, `org_kde_kwin_server_decoration_manager`) and holds no decoration object of either protocol (Qt's frameless window: Telegram; manager and objects are found once at map by a walk of libwayland's public list of the client's resources, interface names compared, so this does not depend on Hyprland's private containers; a client whose other window is decorated through the protocol keeps the plugin's bar on its frameless one). An xdg-decoration client_side request proves nothing on its own (imv and foot ask for it and draw no bar; Chromium asks for it in both of its title bar modes), nor does a client that bound no manager (a bare client): these keep the plugin's titlebar, as do a server_side request, an xdg mode left to the compositor, KDE server, and a KDE object without a client request. Invariant: no window ends up with neither the client's bar nor the plugin's; when the protocol cannot tell, the plugin's bar stays (a second bar can be fixed by S1b, a missing one cannot be fixed by the user). Chromium, Google Chrome and frameless Electron stay in S1b. Hyprland 0.56.2 answers server_side to every request of both (read from the binary: `xdgModeOnRequestCSD`, `kdeModeOnRequestCSD` return 2) and keeps the client's request in `CXDGDecoration::mostRecentlyRequested` and `CServerDecorationKDE::m_mostRecentlyRequested` (public); the objects themselves sit in private containers (`CXDGDecorationProtocol::m_decorations`, keyed by the `xdg_toplevel` resource; `CServerDecorationKDEProtocol::m_decos`), reached through an explicit instantiation's member pointers (C++ allows naming a private member there; the types are checked against the installed headers at compile time), read on the compositor thread only, never kept. The `xdg_toplevel` resource is found once per window by the P8 walk for any version (core `toplevelCandidate`) and only compared as the map key. Read at map, at a commit of the window's surface that changes its size (an unchanged commit costs one size comparison; xdg-decoration objects must exist before the first buffer, and the GTK 3 header bar's KDE request is there at map, decorations.sh D7; a later switch is read when it commits a new size) and on `window.updateRules`. The plugin's tag is static (a rule evaluation keeps it), added only when no tag is there and the only one it removes (core `tagChange`): when the client asks for server-side decorations again, when the window closes and at unload (C2); S1b's rule tag is never removed. A tagged window's own maximize request is the plugin's whoever suppressed it (S2's rule suppresses every app id outside S1/S1b, so the plugin did not set the flag for Telegram). One DEBUG line per change (request budget). X11 windows keep `_MOTIF_WM_HINTS` through Hyprland (`m_X11DoesntWantBorders`) | `ClientChromeDecoration.*` GTests; nested `decorations.sh` (foot, foot with `csd.preferred=client`, imv, xdgact server_side, xdgact client_side, xdgact binding no manager, a plain Qt window and a plain GTK 3 window keep the strip; xdgact binding the manager without an object, a Qt frameless window and a GTK 3 header bar get the tag; a capture on the headless output: the strip above foot, foot csd and the unbound client, none above the frameless window; unload removes only the plugin's tag, reload adds it again) |
| D78 | Zoom is Fill for client chrome (ADR-0036 D78 amended, ADR-0015 amendment 2026-11-03): while `window-tiling` is advertised a tagged window's own maximize request (`set_maximized` / `unset_maximized`, which Hyprland toggles whatever its value) is the plugin's: `SUPPRESS_MAXIMIZE` set on the window by the plugin only when it was not set (core `ownsMaximize`), again at map, on `window.updateRules` and once the IPC registered, cleared only if the plugin set it, at unmap and at unload (C2: Hyprland's maximized mode again); the `stateChanged` listener (P5's) turns `requestsMaximize` into `gf::tiler::zoom` (Fill and back); a request in full screen is ignored, and one within `kMaximizeEchoMs` (1 s) of leaving full screen is the client's echo, swallowed (core `maximizeEcho`, as Hyprland's `m_suppressNextMaximize`) | `ClientChromeZoom.*` GTests; nested `zoom_fill_apps.sh` (Settings, Files), `client_chrome.sh`, `third_party_chrome.sh` |
| S1 (done) | `config/hypr/grassfield/windows.lua`: `hl.window_rule({ name = "gf-client-chrome", match = { class = "^org\\.grassfield\\.(Files|Settings|Preview|Store|Activity)$", xdg_tag = ".+" }, tag = "+grassfield-client-chrome" })` | `tests/shell/client_chrome_rules.sh`; `just check-config`; `client_chrome.sh` assertion 2 |
| S1b (done, GF-056; the fallback since P9) | `gf-client-chrome-third-party`: the same tag on third-party apps whose own close, minimize and zoom work (Evince, Nautilus, Chromium's browser window, Obsidian, Firefox; ADR-0015 amendment 2026-10-25 thought Hyprland 0.56.2 gave no usable per-window decoration signal, P9 reads it; kept as the fallback for these apps without the plugin's P9 and as their maximize exemption; Nautilus's minimize needs P8), exempt from the maximize suppression (Evince's zoom request was suppressed untagged); the session's GTK button layout is `close,minimize,maximize:` (packaging/dconf) | `tests/shell/client_chrome_rules.sh`; `tests/shell/dconf_profile.sh`; `tests/compositor/third_party_chrome.sh` |
| S2 (done) | `gf-no-maximize-event` matches every class but the S1 list, `gf-no-maximize-event-untagged` every window without an xdg tag: only an S1 window (a client-chrome one) is exempt (Q4: its zoom is honoured; another toolkit's tagged window is not, review 2026-10-23) | `client_chrome_rules.sh`; `client_chrome.sh` assertion 6 |
| S3 (done) | windows of role `info`: `match = { class = "^org\\.grassfield\\.Files$", xdg_tag = "^info$" }, rounding = 12` (titlebar style, Q5) | `client_chrome_rules.sh`; `getprop rounding` |
| H1 (done) | shell: `shell/overview/OverviewWindow.qml` band 0 for tagged windows when `client-chrome` is advertised (`ClientChrome.js`); P3 must use the same tag | `tests/unit/tst_clientchrome.qml` + nested Overview shot |

Degraded behaviour: without the plugin the app's lights and toolbar are drawn all the same (close, drag, zoom through
xdg-toplevel requests; minimize has no effect, spike step 6; a GTK4 app's minimize button is greyed: Hyprland's own
capabilities, no P8). With an older plugin that lacks P1 the strip is drawn above the
app's toolbar (plugin and apps ship from one release). `tests/compositor/client_chrome.sh [--no-plugin]` is the nested
scenario: its header lists which assertion needs which item; assertions 3 (no strip, P1), 5 (minimize bridge, P5), 10
(zoomed drag, P4) and 11 (feature, P2) need this plugin, 9 (unload and reload) is run by hand. P6 is case 6 of
`tests/compositor/zoom_restore.sh` (Alt held with `scripts/dev/keys.sh`). P3 also gives the tiling and restore frames no
band above such a window (`Tiling.cpp`, `Minimize.cpp` restore). P7: `ui/tools/gen-tokens.py` writes the `window` group into
`ThemeTokens.hpp`; the colours come from it and `Theme.hpp` checks the metrics against it at compile time.

## Work item GF-116: no restore and no window focus while the session is locked (open, compositor-engineer)

Found by GF-AUDIT-001 SEC-13 / DT-12 and re-read for wave 3 (security-engineer, 2026-10-24; this item is the plugin part,
the shell part is done: every shell surface refuses while locked, `docs/specs/security.md` "Nothing opens over the lock").
Every plugin focus path asks `gf::deferredFocus` first (`DeferredFocus.cpp` `focusWindow` refuses while
`windowFocusRefused()`; Stages and OverviewFocus gate on `sessionLocked()`), except the minimize restore:
`Minimize.cpp` `restore(address, target)` moves the window back and then calls `Desktop::focusState()->fullWindowFocus(w,
Desktop::FOCUS_REASON_OTHER)` directly (after the `alpha(WINDOW_ALPHA_MOVE_FROM_WORKSPACE)` warp, before
`alterZOrder("top")`). `hl.plugin.grassfield.restore("0x<addr>", …)` is callable by any process of the user through
Hyprland IPC, also while locked. Hyprland 0.56.2's `CFocusState::rawWindowFocus` refuses the keyboard under a session lock,
so no key reaches the window today, but the window is un-minimized behind the lock and the plugin asks for a focus the
rule says it never asks for. macOS: nothing un-minimizes while the screen is locked.

Change (precise):
1. At the top of `restore()`, after the address lookup: `if (gf::deferredFocus::sessionLocked()) { gf::logRequest(Log::INFO,
   "restore {:x}: refused while the session is locked", address); return; }` before `takePlace(w)`: the window stays on
   `special:minimized`, its recorded place is kept, no state is posted (the Dock's tile stays as it is).
2. Defence in depth for the focus line: `if (const auto focus = Desktop::focusState(); focus &&
   !gf::deferredFocus::windowFocusRefused()) focus->fullWindowFocus(w, Desktop::FOCUS_REASON_OTHER);` (Hyprland refuses the
   same cases, so nothing changes while unlocked; under an Exclusive layer the window is raised but not focused, as
   Hyprland already decides).
3. Optional, same rule: `minimize()` refused while locked (the shell's `windows minimize` IPC already refuses).
Tests: a core unit test of the decision if it moves to `core/` (`restoreAllowed(locked)`), and DT-12 in nested (bare):
minimize a test window, `qs ipc -p shell call lock lock`, then `scripts/nestctl dispatch
'hl.plugin.grassfield.restore("0x<addr>",0,0,10,10)'` → Hyprland log `restore …: refused while the session is locked`, the
window still on `special:minimized` (`scripts/nestctl -j clients`), keys typed with `wtype` reach only the lock field.

## Known limitations (honest, user-visible gaps vs macOS)

- Activation (spike above): every activation request focuses its window (`focus_on_activate = true`); macOS lets only an
  activation that follows user input take the focus. Not doable with Hyprland 0.56.2's plugin surface.

- Titlebar join (FR3): a thin 1-px arc remains on XWayland windows and translucent windows show lighter corner squares.
- Titlebar below the menu bar (FR56): during one of Hyprland's own moves (an app's move request, as Chromium's tab strip
  asks, or SUPER+drag) the window passes under the menu bar and is moved down at the release (about 23 px for Chromium's
  strip); macOS holds the title bar below the menu bar for the whole drag. Hyprland 0.56.2 offers no hook during its drag.
  Keyboard moves and resizes are not held.
- One title bar per window (P9): the protocol tells "a bar of its own" only for a GTK header bar (KDE client request) and a
  client that bound a decoration manager without asking for anything (Qt's frameless window). A client that asks xdg
  client_side and draws its own bar, but is in no list (an Electron or SDL app that hides its frame), keeps the plugin's bar
  above its own: two bars, fixed by adding its app id to S1b. Telegram is not in S1b: with its "Use system window frame"
  option it is a plain Qt window that keeps the plugin's bar, so the list would leave it without one. The ArtCraft suite:
  NOT verified (its app ids are unknown here; owner check: `hyprctl clients -j` class while it runs, then S1b if its bar
  doubles). A Qt frameless window meant as a panel gets no plugin titlebar, as on GNOME; it is moved with Super+drag. A KDE
  server-decoration object without a client request is read as server-side (Hyprland keeps 0 for both "never asked" and
  KDE's "none"). An app in S1b that asks for server-side decorations (Firefox with its Title Bar option on) still gets no
  plugin bar. P9 reads two private Hyprland containers: a Hyprland that renames or retypes them fails the plugin's build
  (the member pointers are checked at compile time); one that keeps their types and changes their meaning makes the
  lookups miss, and then GTK header bars get two bars again (Evince, Nautilus are in S1b) while every other window keeps
  the plugin's bar: never none. See ADR-0015's amendment of 2026-11-07.
- Chromium and Google Chrome on Wayland: dragging a tab (also the only one) is Chromium's own drag and drop, which moves a
  window only through the `zcr_extended_drag_v1` protocol Hyprland 0.56.2 lacks; the tab comes off into a new window that
  does not follow the pointer, and nothing tiles (measured in nested with Chromium 155). The empty part of the tab strip asks
  Hyprland's move (`xdg_toplevel.move`) and tiles like any window (TL16; `tiling.sh` case chromium).
- Browsers' traffic lights: Chromium and Google Chrome draw the Grassfield GTK theme's lights only in their GTK appearance
  (Settings > Appearance > Mode: GTK), and never under Omarchy's machine policy BrowserThemeColor, whose colour theme
  replaced the lights in every profile (measured in nested with a mount namespace). The package's `zz-grassfield-gtk.json`
  (`{"BrowserThemeColor": ""}`, in `backup=`) sits next to Omarchy's `color.json` in both policy directories,
  `/etc/chromium/policies/managed` and `/etc/opt/chrome/policies/managed`. Chromium's behaviour, read in its source
  (data; `components/policy/core/common/config_dir_policy_loader.cc`, `policy_map.cc`,
  `chrome/browser/themes/theme_color_policy_handler.cc`): the loader reads the directory's files in lexicographic order and
  merges each into one map, a later file's value replacing an earlier one's at the same level, scope and source (and the
  earlier one kept as a conflict, shown in chrome://policy); the empty string then fails the handler's hex colour check
  (`IDS_POLICY_HEX_COLOR_ERROR`), so the policy sets nothing and the profile's own theme choice applies. Machine-wide: the
  Omarchy session's browsers no longer take Omarchy's colour either (accepted in the review of 3ca47a4b; owner to
  confirm). The GTK appearance itself: a new
  profile's default (`prefs::kSystemTheme`, `ui::GetDefaultSystemTheme()`) is GTK only when
  `base::nix::GetDesktopEnvironment` reads a GNOME-like desktop from `XDG_CURRENT_DESKTOP` (then `DESKTOP_SESSION`,
  `GNOME_DESKTOP_SESSION_ID`, `KDE_FULL_SESSION`); the Grassfield session (Hyprland) reads as OTHER, whose default is the
  Classic appearance. No session-safe switch exists: `initial_preferences` is read only next to the browser's executable
  (a file of the chromium and google-chrome packages, for new profiles only), no policy sets the system theme, and changing
  the desktop variables for the browsers is not done (they also drive xdg-utils, Qt and the browsers' key store choice).
  Owner step, once per profile: Settings > Appearance > Mode: GTK. Firefox: not verified (not installed on the dev
  machine). See config/hypr/grassfield/windows.lua.
- Layer pointer focus (FR51): only the shell's own `grassfield-*` layers are corrected; another client's layer surface that
  takes the keyboard on an output away from the layout origin (a third-party launcher) keeps Hyprland's wrong position until
  the pointer moves. The cause is in Hyprland 0.56.2 (`CLayerSurface::onMap` / `onCommit` add the monitor position to a
  geometry already in layout coordinates); worth reporting upstream. The refresh is one pixel's worth of Hyprland motion
  handling, so with `follow_mouse = 1` (not Grassfield's setting, 2) it could also move the keyboard to a window under the
  pointer, as a real one-pixel motion would.
- Stages (prototype behind a flag): limits and risks in `docs/specs/stages.md` "Known limitations and risks".
- Keyboard-less nested session, open item (8i(e2)): after the layer goes, Hyprland neither refocused the window under the
  pointer nor focused the window clicked just after (u): no focus change was logged for the click, and the keys went to the
  window the deferred focus had chosen (h2). Next: an A/B run of stages.sh 8i(e2) with the plugin unloaded the next time
  a session comes up without its own keyboard, to tell Hyprland's pointer path with transient pointer devices from the
  plugin's focus rules.
- Keyboards that come and go, without the plugin (degraded mode): when the session's only keyboard device goes away and
  another appears (a desktop's Bluetooth keyboard reconnecting; in the nested session every `wtype` burst when the parent
  seat had no keyboard at start), the seat loses its keyboard capability in between and clients re-create their
  `wl_keyboard`; a Quickshell (Qt) client then ignores the keys of the new one until it gets a new `wl_keyboard.leave` and
  `enter`. So every Quickshell surface (the lock screen, the polkit dialog, Search, a Quickshell window) is deaf after
  such a reconnect until the keyboard focus changes. The plugin announces the focus again (above); without it the limit
  stays. Repro (nested, plugin unloaded, `devices` listing no keyboard of the session's own): map a Quickshell layer
  surface with Exclusive keyboard interactivity that logs its keys (`tests/compositor/stages-fixture`, role exclusive), run
  `wtype ab`, `wtype cd`, `wtype ef` one after another: it logs a and b only; foot in its place gets all six. A focus
  cycle while the new device exists (another window focused, then this one) makes it take the next burst. Not
  reproducible through `scripts/nestctl`: Hyprland 0.56.2 keeps a disabled keyboard (`enabled = false`) in the seat's
  capabilities. Upstream: Quickshell (an issue text is in the integrator's report of 2026-10-24; filing is the owner's call).
- Overview close focus (`overview-focus`): the shell sends it on every close (`Overview.closeAnd`) and keeps its own
  checked focus path without the capability. Keys typed before the last chrome released still reach that chrome (lost,
  as in the drop table of `docs/specs/overview.md`). The bound is fixed (1 s): a dialog open longer during the close ends the
  request (`timeout`) and Hyprland's own refocus decides when it closes. The activation order behind the front window starts
  at the plugin load (before it, and after a reload, the stack order is used). A touch or tablet press during the close counts
  as a press into the Exclusive layer (it never retargets). Stages on during a close focus was not exercised in nested.
- Funnel (FR44): the window bends under the menu bar and the Dock (drawn before the top layers, like the shrink
  effect), so its neck disappears behind the Dock's material instead of pouring over the tile, a known difference from
  macOS, deferred (R13 of the funnel, integrator decision): drawing above the Dock means drawing at
  `RENDER_LAST_MOMENT`, after the top and overlay layers, which also runs while the session is locked, so it needs a
  lock guard (nothing of a window may be drawn over the lock screen) and its own damage handling first. The snapshot is
  sampled without colour management (correct on SDR outputs; an HDR output would show the window's colours unconverted
  during the 0.5 s) and without mipmaps (the shrunk end of the funnel can shimmer slightly); each mesh quad is two affine
  triangles (no visible seam at 32 x 96). A rotated or flipped snapshot monitor, a Dock tile behind the window's top
  edge, or the Vulkan renderer use the shrink effect instead.
- The animation shows a snapshot taken at the start: a window that changes while it animates (video) is
  frozen for 300 ms; translucent windows are drawn without their blur during the animation (Hyprland renders
  snapshots without blur).
- The Dock tile rectangle comes from the shell: each per-screen Dock registers a provider
  (`Compositor.registerDock`), minimize targets the tile of the window on the Dock of its own monitor
  (separator + 1 + the window's index in the minimized list), restore the window's current tile on the
  focused monitor's Dock. Rectangles are in global layout coordinates, as the plugin validates them.
- `animations:enabled = false` in the Hyprland config does not disable the minimize animation.
- A restoring window is transparent but still receives input during its 300 ms animation (as during
  Hyprland's own fade-in).
- No hover glyphs (×, −, +), no grey inactive-window buttons, no pressed state.
- Appearance follows the shell's light/dark appearance (FR53); before the shell's first push (a few hundred ms after a load)
  the titlebars are dark.
- Titlebar drags don't snap to screen edges or other windows (SUPER+drag still does).
- Client-side-decorated apps that ignore the server-side decoration request get a second titlebar.
- Long titles are clamped to the available width by Hyprland's text renderer; ellipsis behaviour depends on it.
- The square join (FR3) redraws the content's texture under the surface in the two corner squares. Translucent
  content is drawn twice in the part of each square inside the corner curve (slightly more opaque there); windows
  whose texture does not map 1:1 (viewport crop, buffer transform) or whose corners are subsurfaces keep the
  bar-coloured curve.
- The titlebar sits above the client's requested position, so a centered window's titlebar extends 32 px
  above the centered area.
- Fractional scaling: geometry is scaled by the monitor scale but only scale 1 was tested.
- Runtime unload through `scripts/nestctl` is exercised by `tests/compositor/overview.sh` (unload during an open
  overview) and `tests/compositor/desktop_focus.sh` (unload while the desktop holds the keyboard), each followed by a
  load (Hyprland alive, features back); the appmenu pinning path (FR23) is still not verified with client objects alive,
  so a rebuilt plugin is tested on a fresh nested instance, not by unload + load.
- Desktop focus (FR30): pointer button presses only (touch and tablet taps keep Hyprland's behaviour); a press on a
  window border outside its titlebar and surface is left to Hyprland; keys typed between a desktop click and the shell's
  `on_demand` commit (one frame) go to the previous holder.
- Overview: screen captures showed no stale pixels even with the FR28 fix reverted (most likely a capture repaints the
  whole output; not read from the sources), so the resize case is verified through the plugin's damage log and a unit
  test, not pixels; stale pixels on a real scanout were not observed directly.
- The release of a titlebar press that ends outside a titlebar (a button press moved away, a double-click
  zoom, and most fast drags, because the bar lags the pointer while the window's move animation runs) is
  processed by Hyprland like any release and reaches the seat, which drops it because the client never got
  the press. When a client surface has pointer focus at that moment, Hyprland logs `sendButton release on
  a non-pressed button` (log noise only). Until 2026-10-17 the plugin cancelled these releases on the event
  bus instead; Hyprland then kept the button as held and pinned pointer focus to the dragged window, so
  motion over other windows reached nothing and the next click on another window was delivered to the
  dragged one (counter-review finding, reproduced by `tests/compositor/input_consistency.sh`; an earlier
  version of this section wrongly stated that the next click was correct).
- Appmenu: only Wayland clients that implement `org_kde_kwin_appmenu` (Qt 6.11, Chromium 152) and only when
  `com.canonical.AppMenu.Registrar` is on their bus at start-up; X11 apps, GTK and Electron apps are not covered
  (T0 menus). The plugin only links windows to DBusMenu addresses; reading and showing the menus is step B.
- The plugin library is never unloaded at runtime: its GNU_UNIQUE symbols keep the image mapped after `PLUGIN_EXIT`
  (and appmenu pins it as well when client objects are alive, FR23), so a load of the same path runs the image already
  in memory: a rebuilt plugin runs only after Hyprland restarts (in development: restart the nested session; details in
  compositor/README.md, "Unload"). Appmenu clients' menus are not re-announced by a reloaded plugin until they create
  new appmenu objects.
- Window addresses are reused by Hyprland after a window is destroyed (seen in S5 runs): the shell must apply
  `appmenu` events in order, and a clear always precedes a reuse.
- Hyprland itself never releases the buttons of a removed pointer device: after an abandoned drag (device
  destroyed with the button down) it keeps that button as held until that button's next release, with or
  without the plugin. The plugin only ends its own gesture (FR7).

## Session window behaviour (Lua config, not the plugin)

`config/hypr/grassfield/stacking.lua` and `placement.lua`; nested scenarios `tests/compositor/window_stacking.sh` and
`tests/compositor/window_placement.sh`.

- Stacking: a window that becomes active is raised (`alter_zorder top`) unless it is not floating, full-screen, or on a
  workspace that shows a full-screen window. Hyprland 0.56 already raises a floating window on a pointer press that
  changes focus (measured: press on the back window's visible part raises it, with and without the plugin), but not when
  focus arrives without a press (switcher, Dock, `focus` dispatcher, a program asking for focus): that window stayed behind
  the other one while being active, and a later press did nothing (no focus change, so no raise). The hook covers it.
- Placement: a browser window (class list in `placement.lua`) that opens smaller than 72 % x 82 % of the monitor's usable
  area (output minus the menu bar and Dock) is grown to that size; larger sizes are kept, and the window is centred by
  Hyprland.
- Per-application rules (ADR-0045 OC-12, `config/hypr/grassfield/apps.lua`, loaded by `core.lua` after `privacy.lua` in
  both sessions, optional): the rules of Omarchy 4.0.6's `default/hypr/apps/*.lua` that hold in a floating-first session,
  copied with their match and only the effects kept, each citing its file (pinned in `docs/upstream/omarchy.lock`):
  Battle.net's installer without the window manager's frame (`decorate = false`, no blur, no shadow), DaVinci Resolve's
  menus and dialogs keeping the focus while they show (`stay_focused`, not its main window nor the Project Manager),
  GeForce NOW, Moonlight, RetroArch and Steam keeping the screen awake while full screen (`idle_inhibit = "fullscreen"`,
  which the shell's idle honours), Telegram not taking the focus on a new message (`focus_on_activate = false`; it asks for
  attention instead), Picture-in-Picture (a browser's PiP window: exactly the title "Picture-in-Picture" / "Picture in
  picture", and a class of Omarchy's browser.lua or the Flatpak Firefox; narrowed from Omarchy's unanchored title so that a
  window that only mentions it, Preview showing "Picture-in-Picture.png", is never pinned) pinned above every window on every
  desktop with its proportions kept, and Omarchy's camera overlay (`WebcamOverlay-small|medium|large`) at the
  bottom-right corner, sized from the display's height, pinned, without taking the focus. Left out (the file's header says
  why): float and center (every window), an application's own size (placement), full screen at map, Omarchy's opacity,
  tags, borders and rounding, browser tiling and the special workspace of the screen-sharing indicator, JetBrains'
  `no_follow_mouse` (click-to-focus already), Hermes' HUD, Google Meet's Picture-in-Picture and the PiP's size and corner.
  `tests/shell/app_rules.sh`: the wiring, the effects left out, and each rule against the cited Omarchy file's text.
- **Known limit:** other applications' first windows keep the size they ask for (terminal, Grassfield apps, dialogs,
  panels). Lua cannot tell a dialog, a popup or a utility panel from a main window (no parent or modal field on
  `HL.Window`), so a minimum size for every first window would also enlarge those. Widening the rule needs that signal
  (plugin, or an app class list).
- **Known limits (OC-12):** the rules were not run by Hyprland here (`Hyprland --verify-config` and the nested session are
  the owner's: `just check-config`, then each application by hand). Picture-in-Picture opens where Hyprland centres it,
  not in a corner, and a pinned window is not refitted by `placement.lua`. Omarchy's camera overlay keeps the plugin's
  title bar (32 px above it) and may sit under a wide Dock in its corner. Whether Hyprland's `idle_inhibit = "fullscreen"`
  also counts a zoomed (maximized) window is not verified. Apps Omarchy adds rules for in a later release are not picked
  up (the rules are copied; `just check-upstream` shows the upstream change).
