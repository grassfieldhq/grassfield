# Overview spec (Mission Control equivalent) · shell-engineer + compositor-engineer · M2 (v1), M3 (v2)

UI naming (renamed 2026-10-18, owner decision): internally "Space" (workspace, IPC and code); the user sees "Desktops" and "Desktop N" (fr « Bureaux », « Bureau N »). The desktop icon surface keeps the word "desktop" in prose; "Desktop N" always carries a number.

## macOS reference behavior (described in words)
- Ctrl+Up or a 3/4-finger swipe up zooms out: all windows of the current Desktop spread without overlap,
  scaled, keeping relative positions, with app name labels under hovered windows; the desktop dims slightly.
- A Desktops bar at the top shows thumbnails of each Desktop (labelled "Desktop 1", …) and a "+" to add a Desktop;
  dragging a window onto a Desktop moves it.
- Click a window to focus it and zoom back in; Esc or Ctrl+Up again exits. Animations ~300 ms, spring-like.

## Purpose and non-goals
v1 (M2): shell surface with ScreencopyView thumbnails of toplevels (Quickshell `ScreencopyView` with
Hyprland toplevel capture), layout algorithm, Desktops bar, keyboard nav, drag to Desktop.
v2 (M3): live transforms of real windows by `grassfield-compositor` (`hl.plugin.grassfield.overview(json)`, feature
`overview`) when the capability is present (compositor and shell side shipped 2026-10-18, see "v2 implementation" and
"v2 shell side"). Non-goal: capturing protected surfaces.

## Functional requirements
1. O1 Toggle via IPC `overview toggle` (CTRL+UP) and gesture (owner config, L2). The three-finger swipe up follows the fingers (bindings.lua `tracked.gesture("overview-open", swipe_up)`, shell/platform/shortcuts GestureFollower): the chrome, the backdrop and the thumbnails draw the swipe's progress and complete or go back from where the fingers left it; with live windows (v2) the layout is sent when the swipe completes (the plugin has no request for a given progress, so the real windows animate over its own duration then). The swipe down closes the same way. Reduce Motion: the swipe opens or closes at its end.
2. O2 Layout: non-overlapping grid preserving relative positions, max scale 0.8, min gap 24 px; unit-tested.
3. O3 Thumbnails live-update (Full profile) or snapshot once (Reduced profile).
4. O4 Desktops bar: one tile per workspace on the monitor + "+" creates the next workspace.
5. O5 Drag a window thumbnail onto a Desktop tile → `movetoworkspacesilent`.
6. O6 Keyboard: arrows move selection, Return focuses, Esc exits.
7. O7 Minimized windows appear in a separate strip (M2 with minimize). Done 2026-10-23 (REQ-OVW-O7; owner decision, follow macOS Mission Control and App Exposé: minimized windows sit in a row of smaller tiles below a divider, and a click restores one): see "Minimized windows" below.

## Minimized windows (O7)

Shell side only, no plugin change: the plugin does not transform windows parked on `special:minimized` (see "v2 spike", answer (a)), and the strip does not need it. The strip draws the shell's own record of what it minimized (`Compositor.minimized`, `platform/Minimized.js`; rebuilt from `special:minimized` after a shell restart), on the output that has the Dock (the minimized tiles of the Dock are there).
- Layout (`Layout.stripHeight`, `Layout.stripRects`, pure, `tests/unit/tst_overviewlayout.qml`): a hairline divider at the top of a strip at the bottom of the free area (above the Dock's reserve), then one row of tiles centred, each `overview.minimizedWidth` x `minimizedHeight` (144 x 90), `minimizedGap` 16 apart, narrower with the same aspect when the row would not fit, the window title under each tile (`minimizedLabelHeight`). At most `overview.minimizedMax` 10 tiles show (the newest; `Layout.capStrip`; the rest stay in the Dock), and a minimized window is captured ONCE (a minimized window does not change; the full profile used to stream every one of them live at the window's resolution), with `constraintSize` set to the tile size. Whether `constraintSize` makes the compositor deliver a smaller buffer or only limits the size Quickshell reports is not documented in the type information: `overview status` lists `minimized[].capture` ({source, implicit, constraint} sizes) so a nested run can read it (`tests/visual/overview-minimized.sh` prints it). `capture.constraint` only echoes the value set; the buffer Quickshell really asks the compositor for is seen on the wire: start the nested shell with `WAYLAND_DEBUG=1` in its environment (`WAYLAND_DEBUG=1 just nested-up`, the shell inherits it), open the Overview with one minimized window, and read the shell's log for `create_buffer` lines of the shm pool created right before a `hyprland_toplevel_export_frame_v1` / `zwlr_screencopy_frame_v1` `copy`: `wl_shm_pool@N.create_buffer(new id wl_buffer@M, 0, WIDTH, HEIGHT, STRIDE, FORMAT)`; WIDTH and HEIGHT are the captured texture, to compare with the window's size (`overview status` `minimized[].capture.source`) and the tile's (144 x 90 at most). Not run from the agent sandbox. The strip's height (`tile + label + 2 x minimizedPad`) is taken from the area the open windows are laid out in (`freeArea(strip)`), so the windows never overlap it; with no minimized window the strip does not exist and the layout is unchanged.
- Tile: a plate with the app icon, and in the `full` material profile a live `ScreencopyView` of the window fitted inside it (as the Dock's minimized tile), the title below. Hover and keyboard focus draw the accent outline. Accessible name "<title>, minimized".
- Click, or Return on the focused tile: the Overview closes and then the window is restored to the current Desktop and focused (`Compositor.unminimize`, the call a Dock click makes, after the chromes released the keyboard; `V2.closeTarget` kind `minimized` asks the plugin for no focus of its own). Nothing is restored while the session is locked.
- Keyboard: Down from the last row of windows enters the strip (first tile), Left/Right move along it, Up returns to the windows, Return restores, Tab leaves it for the Desktops bar.
- Status hook: `overview status` lists `minimized` (address, appId, title, window-local `rect`) and `minFocus` per output.
- Tests: nested `tests/visual/overview-minimized.sh` (no strip without minimized windows; two minimized windows give two tiles below every open window; click restores and focuses; the restored window leaves the strip; Down then Return restores); unit tests above. Visual NOT verified when this was written.

## Measuring P3 and S4

- P3 (gate: at least 95 % of frames on time during open and close, Balanced profile): `tests/visual/overview-frames.sh [cycles] [profile]` runs the probe `tests/tools/framepulse` (a window that redraws on every frame callback and prints the interval between two callbacks, wall-clock stamped; it refuses the owner's Wayland socket) in the nested session while the Overview opens and closes `cycles` times with Reduce Motion off; `tests/visual/frame-stats.py` keeps the frames of the 700 ms after each request and prints, per phase, the median, the 95th percentile, the worst interval and the share within 1.2 refresh periods (20 ms at 60 Hz; a dropped frame is two periods): PASS at 95 % or more in the open phase, the close phase and overall (`tests/visual/test_frame_stats.py` checks the statistics on synthetic streams). Frame-callback intervals measure frames the compositor delivered late or dropped, not the shell's own render time; on the nested output they are an indication, the gate is the owner's L2 run (the same script against a nested session on the real machine). What a full probe would still add: the presentation-time protocol (actual photon time), `perf`/`intel_gpu_top`, not installed here.
- S4 (cost of 9 thumbnails per profile): `tests/visual/overview-cost.sh [seconds]` prints the markdown table of the S4 results (shell and nested Hyprland CPU and RSS closed and open for full, balanced and reduced) to paste into this file and into ADR-0006's notes (C-OVW-4: ADR-0006 has no S4 entry yet; the figures live above under "S4 results" until the run is recorded), and fails when balanced costs 5 % or more of a core with the Overview open.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| O2 | layout unit tests (QML TestCase) | L0 |
| O1/O4/O6 | nested scenario with 6 windows + screenshots | L1 |
| P3 | frame timing open/close: `tests/visual/overview-frames.sh` (probe `tests/tools/framepulse`, statistics `frame-stats.py`) | L2† (script run by the owner) |
| S4 spike | ScreencopyView cost of 9 toplevels recorded in ADR-0006 notes: `tests/visual/overview-cost.sh` prints the table | L1 |
| O7 | minimized strip: `tests/visual/overview-minimized.sh`, layout in `tst_overviewlayout.qml` | L0 + L1 |
| v2 spike | live transforms: mechanism, layering, input, CPU, cleanup (`tests/compositor/overview.sh check`, `perf`) | L1 |

## Window items (audit 2026-11-18, A-06, A-11)
- The window items are keyed by address (`ScriptModel`, `objectProp: "address"`): a window opening or closing while Overview is open adds or removes its own item only; the others keep their item, capture and drag in progress and glide to the new layout (the `tx/ty/tw/th` Behaviors); a new window fades in at its place. A drag ends only when the dragged window itself goes.
- Thumbnail mode: the live content of a window is drawn at a fixed size (the larger of the real window and its place in the layout) and scaled to the item, so the zoom changes a scale and the two offscreen layers (mask, clipper) are allocated once; the corner radius is the token as drawn at every scale.
- The window label waits for its rectangle's index in the placement (no TypeError for a binding read between two updates).
Tests: `tests/shell/overview_keyed.sh` (the real Overview offscreen, windows given by the harness).

## Known limitations
- Contrast: the Desktops bar is a Material band (full width, 164 pt with the menu bar, hairline under it) and its names use the
  primary text colour on it, so the old "overview captions" exemption is gone (the window count captions were removed).
- v1 shows thumbnails, not the real windows moving; real-window transforms need the plugin (v2).
- v2 (plugin side): popups are not transformed, full-screen windows are not transformed, fractional scales and
  rotated outputs are not verified (see "Shell contract" item 8).
- Close focus, what is left (R13 follow-up 2026-10-20):
  - Keys typed in the first ~150 ms after Esc can be lost (the chrome still has the keyboard and ignores them while it
    releases it), never delivered to a wrong window (drop table in `overview_two_outputs.sh drop`; from 200 ms none is lost).
  - A click in the first ~250 ms after the close is taken by the chrome: it keeps its input mask for the zoom-out
    (`overview.motion.slow`, 350 ms); measured, clicks up to ~200 ms after the overview reports closed did not reach the window
    under them, from ~250 ms they did. Not changed (the mask follows the animation).
  - Without the plugin (C2) the shell focuses with the Lua dispatch after the release, so there is a gap (the first check is
    60 ms after the attempt, then 120, 240, ... up to the 1 s bound) in which Hyprland's own choice stands. The retry stops
    when the focus holds, a window other than the goal and than the one active before the attempt becomes active (a click, a
    key bind), a Desktop other than the goal is focused, an Exclusive surface opens, the session locks or the bound passes.
    The shell cannot see pointer motion, clicks or keys by themselves: a click on the window that was already active (or on the
    target) cannot be told from nothing, and a late refocus Hyprland makes itself within one check interval reads as the user's
    choice (the retry stops, Hyprland's focus stands). A user focus that lands after the last check (the first one holds)
    is not undone: only retries, never a later correction, follow a check.
  - The same return (the window active when the surface opened) runs for Search, Apps, the app switcher (a cancelled session; a
    commit activates its app), popups and menus, the Notification Center and the desktop widget menu ("Keyboard return of the
    other Exclusive surfaces" below). Not covered: the polkit dialog (`shell/security/`, its own review), the Dock keyboard mode
    and the desktop icons (`on_demand`), which do not unmap while dropping the keyboard.

## v1 implementation (shell/overview/, 2026-10-17)
- `Overview.qml` (controller + IPC `overview toggle|open|close|status`), `OverviewWindow.qml` (one layer-shell
  overlay per output, namespace `grassfield-overview`, starts below the menu bar, keyboard exclusive while open),
  `Layout.js` (pure layout, keyboard neighbor search, input signature; `tests/unit/tst_overviewlayout.qml`).
- Layout: one uniform scale <= 0.8, centers scaled about the group's center, overlaps relaxed apart (min gap 24 px);
  if that does not fit, or row packing gives clearly larger windows (identical stacked windows), rows in reading
  order are used. Window rectangles interpolate from the real rectangle to the layout rectangle (zoom). Reduce
  Motion: no movement, crossfade capped at `motion.reducedMax`.
- Cost bounds: the area comes from the screen geometry (never the unconfigured layer-surface size) and the layout
  is recomputed only when the signature of window ids, rects and area changes. Row packing is a direct
  computation (rows 1..ceil(sqrt n)+1), the relaxed layout a <= 5-step binary search on the scale with <= 12
  relaxation passes. Offscreen: 20 windows ~12 ms, 9 ~6 ms (tests allow 40 ms, best of 20, for host load); in the nested shell one layout
  takes 2-3 ms and open -> fully zoomed is the animation itself (~360 ms). Esc, like every other action, releases
  the keyboard before closing (a Desktop just created with "+" is kept). The action always closes the overlay (try/finally).
- Platform (`shell/platform/Compositor.qml`, new functions only): `spacesOn`, `windowsOn`, `nextSpaceId`,
  `focusSpace`, `moveToSpace` (address validated by `Minimized.moveRequest`, the single validator, Lua `hl.dsp.window.move({... follow = false ...})`),
  `refreshSpaces`, `topologyRevision`/`refreshOnEvents`.
  Since tiling step 6a (`docs/specs/tiling.md` TL33, ADR-0036 D41, D53) `spacesOn` lists a Split View Desktop right after
  the Desktop it came from (`WindowTiling.desktopOrder`, from the plugin's `splits`), the others in id order; it takes no
  number (`WindowTiling.numberDesktops`): the Desktops keep "Desktop N" by their own position, and its tile is named after
  its apps ("%1 and %2", one app's name alone, else Full Screen).
- Desktops bar tiles (v1): "Desktop N", window count and up to 4 app icons; no capture of the workspace (the real
  tile thumbnails need v2). Click a tile: switch and close. "+": focus the next workspace id, Overview stays open.
  macOS details (ADR-0024 lot 5, C-19; docs/audits/visual-tahoe-2026-10-25.md § Overview): N is the tile's position
  (Desktop 1, 2, ... from the left), never the Hyprland workspace id (the Window menu's Move to Desktop numbers them the
  same way); the selection ring is drawn outside the 138 x 90 thumbnail, 1 clear of it (`overview.selectionWidth` 3,
  `ringGap` 1), whose top is `overview.barTopMargin` 21 below the bar; the name is `overview.tileLabelGap` 6 below; the "+"
  button is a bare 30-pt `plus` glyph at rest (macOS 27), a light glass circle under the pointer or the keyboard focus
  (white at `overview.addFillOpacity` 0.5 light / `addFillOpacityDark` 0.18 dark).
- Click a window: focus it and close. The keyboard grab is released before the focus lands (the plugin waits for the last
  Exclusive layer; without it the shell focuses after the release and checks), otherwise Hyprland refocuses the previous
  window (and workspace) when the exclusive layer goes away and undoes the switch.
- Keyboard: arrows (spatial, across outputs; with a window active at open the first arrow moves from it to its neighbour; with none, e.g. the desktop held the keyboard, the first arrow selects the first window in reading order of the laid-out thumbnails on the output, top row first, left to right), Return, Tab/Shift+Tab
  cycle windows -> each Desktop tile -> "+", Esc. Up from the top row of windows enters the Desktops bar.
- Profiles (`material.profile`): full = live `ScreencopyView`; balanced = single frames every
  `overview.balancedIntervalMs` (250 ms; the API has no rate control, so `captureFrame()` on a timer); reduced = one
  snapshot per window when opening.
- v2 branch point: `Overview.thumbnailMode` (`!Capabilities.has("overview")`, always true in v1).
- Backdrop: the wallpaper is a separate layer surface, so the overlay dims and blurs everything below it (real
  windows included, blurred) instead of showing a wallpaper-only backdrop; there is no dim (`overview.backdropOpacity`
  0: macOS 27 does not dim the wallpaper behind the windows; it was 0.45); with Reduce Transparency the dim is
  near-opaque. A wallpaper-only backdrop needs the wallpaper art shared with the overlay (follow-up).
- Blur timing: the compositor re-blurs the full-screen region every frame while the surface animates (nested
  swap up to 1 s). `BackgroundEffect.blurRegion` is set only once the zoom-in has finished and dropped when the
  zoom-out starts; the dim animates on its own. The overlay window is persistent (one per screen, always mapped,
  empty input mask and hidden content between opens). Nested, 3 open/close cycles: max swap 717-1110 ms ->
  107 ms.
- Close without a choice (Esc, backdrop click, IPC close/toggle) releases the keyboard grab, then focuses the window
  that was active when the overview opened (and its Desktop): macOS returns to the window and Desktop you were on when
  you leave Mission Control without choosing. A Desktop created with "+" while open is the exception (the shell switched
  to it; staying there is the choice). See "Close and keyboard" below.

## S4 results (spike: ScreencopyView cost of 9 toplevels)
Nested Hyprland 0.56.2 on the owner's session (parent GPU path, UHD 630; indication only), 9 foot windows (700x500)
on one workspace, output GF-REF 1920x1080, idle terminals, 60 s windows, CPU = % of one core from /proc stat deltas.

| State | grassfield-shell CPU | grassfield-shell RSS | nested Hyprland CPU |
|---|---|---|---|
| Overview closed | 0.1 % | 292 MB | 0.0 % (RSS 167 MB) |
| open, full (live) | 104.8 % | 311 MB | 43.1 % |
| open, balanced (4 fps) | 1.3 % | 307 MB | 0.3 % |
| open, reduced (snapshot) | 0.1 % | 324 MB | 0.1 % |

- Live capture of 9 windows saturates the shell's main thread in this environment (every frame is copied, even
  for idle windows): full is not viable as a default here; the default profile (`balanced`) costs ~1 %.
- Observation (nested only, real session not verified): on the first open after the shell starts, the zoom
  animation progressed only to ~14 % and resumed after an external wake-up (IPC call); later opens reach 100 %
  within ~0.3 s. Needs a check on the real session (P3, L2).

## v2 spike (live transforms in grassfield-compositor, 2026-10-18)
Nested Hyprland 0.56.2 (commit `efb50993780079460b0cbed1363e2166a2de1d9f`) on the owner's session (parent GPU path,
UHD 630; indication only), output GF-REF 1920x1080 scale 1, plugin 0.4.0-ov2 built against `/usr/include/hyprland`.
Hyprland's v0.56.2 sources were read as data (`render/Renderer.cpp` `renderWindow`, `render/ElementRenderer.cpp`
`drawTransformedWindow` and `drawSurface`, `render/pass/Pass.cpp`, `render/OpenGL.cpp`, `output/MonitorResources.cpp`)
and every API used was checked in the installed headers. Runs: `.dev/overview/run-20261018-001222` and
`run-20261018-003207` (check, both PASS; the figures below are from the first), `run-20261018-001341` (perf).

**Mechanism: a `Render::IWindowTransformer` per transformed window** (`CWindow::m_transformers`, public; Hyprland uses
it for its own motion blur and only ever touches its `CMotionBlurTransformer` entries, through `dynamic_cast`).
- With a transformer attached, `renderWindow` records the window's main pass (decorations, surface, subsurfaces) into
  a sub-pass and adds a `CTransformedWindowPassElement`. At draw time Hyprland renders that sub-pass into a cleared
  monitor-sized work buffer, passes it to each transformer's `transform(fb)` and composites the returned buffer over
  the whole output, limited to the frame damage (the element disables pass simplification, so every element gets the
  whole frame damage instead of its own bounding box).
- The plugin's `transform()` draws the received buffer into a second pooled work buffer, scaled and moved so that the
  window's surface box lands on its layout rect (the minimize snapshot math, `core textureBox`), and returns it. The
  decorations (titlebar, border, shadow) scale with the window.
- The client is never resized nor configured: `hyprctl clients` at/size identical before, during and after (check
  "sizes"). Its buffers are sampled every frame: a terminal printing the time every 200 ms changes inside its layout
  rect between two frames while an idle one does not (check "live": 2233 px vs 0 px). Frame callbacks keep flowing
  because the surfaces are drawn in the sub-pass.
- Damage: animation ticks (`render.preChecks`, like Hyprland's own animations) damage each window's previous and new
  visual box, which schedules the next frames. While open, `render.pre` (after Hyprland's animation tick, before
  `beginRender` reads the damage ring) adds the layout boxes of that output to its damage ring whenever the output has
  damage (`m_damage.hasChanged()`), because Hyprland damages a window's real place when its content changes. An idle
  open overview renders no frame at all.
- Since the audit fixes of 2026-11 (WM-02, WM-17 and the design notes): only the layout box of a window whose real place
  the frame's damage touches (or whose drawn box changed) is added; the transform draws into output buffers the plugin
  keeps while windows are transformed and clears only the box it drew there last and the new one, never a whole
  monitor-sized buffer per window (stages.md "Swap animation" has the details, shared in `WindowTransform.cpp`); each
  window has its own track (core `gf::motion`): an `on:true` again while shown moves each window from where it is drawn
  with its velocity and leaves a window whose rect did not change on its clock; a close (`on:false`, or one the plugin
  starts) reverses from the box on screen with its velocity, its duration scaled by the share of the way left (a close
  50 ms into the opening takes about as long as the way travelled, not the whole duration); a Desktop switch while the
  overview is shown closes it with this animation (the windows of the Desktop sliding out go back while it slides)
  instead of ending it in one frame; a window is stepped by the frames of its own monitor (one ticker per monitor).

Rejected:
- **Renderer hints** (`CRendererHintsPassElement` with a translate + scale `SRenderModifData` around a window's elements,
  from `RENDER_PRE_WINDOW` / `RENDER_POST_WINDOW`): `renderModif` moves the drawn boxes but not the damage: surfaces are
  drawn with `damage ∩ windowBox` in unmodified coordinates (`drawSurface`) and scissored with unmodified rects
  (`renderTextureInternal`), and pass simplification uses unmodified bounding boxes and opaque regions. A window moved
  outside its real box is clipped away, and its opaque region still hides what is under its real place.
- **`CWindow` animated variables** (`m_realPosition` / `m_realSize`): they configure the client (`sendWindowSize`), as
  already found for minimize.
- **Function hooks or calling the protected `renderWindow`**: fragile against Hyprland updates and not needed.
- **Capturing a window's elements with `redirectPass` and replaying them after the Overlay layer** (windows above the
  shell's dim): needs a nested pass render on the main framebuffer, damage save/restore and a second software cursor
  draw, popups bypass the redirect, and windows would cover notifications. The layering has a simpler answer (b).
- **`makeSnapshotFB` per window per frame**: a newly allocated monitor-sized framebuffer and a full window render per
  frame; the transformer path renders into Hyprland's pooled work buffers.

Defects found and fixed during the spike (nested only, before any further run):
1. `CMonitor::resources()` is a weak pointer over a unique pointer: `lock()` hits a hyprutils assertion (abort, not an
   exception, so `gf::guarded` cannot catch it) and the nested Hyprland crashed with SIGABRT on the first transformed
   frame. The plugin now checks and dereferences it, as Hyprland's `drawTransformedWindow` does.
2. After rendering the window into the work buffer Hyprland leaves `m_renderData.damage` at the window's box: a clear
   inside `transform()` then cleared only that box, and the previous content of the reused work buffer was composited
   over the output as noise. `transform()` now sets the damage to the whole buffer for its clear and draw and restores
   it afterwards.

Answers:
- **(a) Windows.** The shell lists them; the plugin transforms a window only if it is mapped, not hidden, not pinned,
  on the active, non-special workspace of its monitor (minimized windows on `special:minimized` are excluded) and not
  full screen (`FSMODE_FULLSCREEN`; maximized windows are transformed), and if its rect lies inside that monitor. A
  window that closes, moves to another workspace, becomes full screen or pinned while the overview is shown goes back
  to normal rendering at once. Popups are not transformed (Hyprland: "transformers for now only affect the main pass").
- **(b) Layering.** The windows stay in Hyprland's normal window pass, between the Bottom and the Top layers. Chosen:
  the shell splits its overview in two surfaces: the backdrop (dim, and blur through `BackgroundEffect` if wanted) on
  the **Bottom** layer, above the wallpaper and the desktop icons (Background) and below the windows, and the chrome
  (Desktops bar, labels, selection, input) on the **Overlay** layer with a transparent background. No holes, no second
  animation to keep in step, notifications, OSD and the cursor keep their place, and the Dock (Top) stays above the
  windows as on macOS. Verified with the stand-in `tests/compositor/overview-fixture` (screenshot `open.png` of the
  check run: dimmed wallpaper, crisp windows, labels and Desktops bar on top). Rejected: windows above the Overlay layer
  (see `redirectPass` above); the shell layer on Top with a transparent area (its dim still covers the windows unless
  it punches holes); holes (the shell would have to animate them in step with the plugin's per-frame boxes: one or two
  frames of offset at ~3 px/ms leave a 50-100 px band of dim on moving windows).
- **(c) Input.** With the windows transformed, the fixture's Overlay chrome (whole-surface input, keyboard exclusive)
  received a click at the capture window's real, untransformed place (outside every layout rect), a click on its image
  and a key; the window itself (a foot reporting mouse buttons and typed bytes) received nothing and the active window
  did not change (check "input"). Hyprland's input routing is untouched: real windows keep their real boxes.
- **(d) CPU** (`tests/compositor/overview.sh perf 30`: 9 foot windows 700x500 on GF-REF, 30 s per phase where S4 used
  60 s, % of one core from `/proc/<pid>/stat`):

| Phase | nested Hyprland | grassfield-shell | fixture (v2 chrome stand-in) | Hyprland RSS |
|---|---|---|---|---|
| closed, idle | 0.2 % | 0.5 % | – | 161 MB |
| closed, one terminal printing 10 lines/s | 3.7 % | 0.2 % | – | 161 MB |
| open, idle | 0.3 % | 0.3 % | 0.0 % | 161 MB |
| open, one terminal printing 10 lines/s | 6.4 % | 0.1 % | 0.0 % | 161 MB |
| open/close every 0.5 s (350 ms animations, continuous) | 12.2 % | 0.4 % | 0.0 % | 161 MB |

  v1 live thumbnails of the same 9 windows: shell 104.8 %, nested Hyprland 43.1 % (S4). The grassfield-shell column is
  the running shell with its v1 overview closed: a v2 shell captures nothing and its chrome is static.
- **(e) Animation.** The shell sends `durationMs` (0 = Reduce Motion) and optionally the timing curve (cubic-bezier
  control points, default `Tokens.motionCurveStandard` 0.2, 0, 0, 1); the plugin interpolates every frame, so there is
  no per-frame IPC. A new layout while open continues from where each window is drawn. Hyprland's animation variables
  are not used: they belong to its config animation tree, and per-frame interpolation is already proven by minimize.
- **(f) Exit and cleanup.** `on:false` animates back, then detaches the transformers: the output after matches the
  output before (0.35 px differ, menu bar masked). A plugin unload during an open overview detaches every transformer
  in `PLUGIN_EXIT` (normal rendering on the next frame, windows at their place, Hyprland alive) and posts
  `closed`/`unavailable`; loading the plugin again brings the feature back. Failsafes: the chrome surface (namespace
  `grassfield-overview`) going away, or a window getting the keyboard, closes the overview; a workspace switch closes it with the closing animation (`closing`/`interrupted`,
  then `closed`; since 2026-11, WM-17), a monitor change puts every window back at once. Refused requests change nothing and report the reason, so the shell
  falls back to thumbnails; without the plugin (or with an ABI mismatch) there is no `overview` feature at all.

Result: positive; implemented as below.

## v2 implementation (compositor side, 2026-10-18)
Code: `compositor/src/core/Overview.*` (payload parser and validation, interpolation, event JSON; unit tests
`compositor/tests/OverviewTest.cpp`), `compositor/src/Overview.*` (transformers, damage, failsafes), verb in
`compositor/src/Ipc.cpp`. Plugin requirements: `docs/specs/compositor.md` FR25-FR29. Nested scenario:
`tests/compositor/overview.sh` (`check`, `perf`) with the stand-in `tests/compositor/overview-fixture/shell.qml`.

### Shell contract
1. **Capability.** `Capabilities.has("overview")` selects v2 (`Overview.thumbnailMode` false); otherwise v1.
2. **Surfaces** (per output):
   - backdrop, namespace `grassfield-overview-backdrop`, `WlrLayer.Bottom`, full screen, no input (empty mask), dim
     from tokens (near-opaque with Reduce Transparency), blur through `BackgroundEffect` if wanted (it only blurs the
     wallpaper and the desktop: the windows are above it). Same-layer surfaces stack in mapping order: map it when the
     overview opens so that it is above the desktop widgets (Bottom), or decide that they stay undimmed.
   - chrome, namespace **`grassfield-overview`**, `WlrLayer.Overlay`, transparent background (no dim or blur where
     windows are drawn), Desktops bar, labels, selection, whole-surface input. **Keyboard plan** (`V2.keyboardPlan`):
     while the overview is open (opening/open) **every output's chrome is `Exclusive`**, because while an Exclusive
     layer exists Hyprland sends pointer focus to Exclusive layers only (`CInputManager::mouseMoveUnified`, "forced
     above all"): a `None` chrome would make hover, click, drag, the Desktops tiles and the backdrop click dead on its
     output. Hyprland gives the keyboard to ONE of the chromes; it is **not** reliably the pointer's output (measured on
     GF-REF + WAYLAND-1: the GF-REF chrome had it in 10 of 12 trials with the pointer on WAYLAND-1), so the shell handles
     keys on any chrome and never infers anything from which one holds it. On close see "Close and keyboard" below.
     **Required by the plugin** (relaxed 2026-10-18, main 46b3e9b): an `on:true` that would transform windows is
     refused with reason `no-chrome` unless every monitor of those windows has a mapped chrome surface (any keyboard
     interactivity) and the keyboard is on a chrome surface (or one of its popups) with `Exclusive` interactivity. While
     windows are shown, a chrome unmapping ends the overview at once (`closed`/`interrupted`, no closing animation) and
     the keyboard leaving the chrome ends it (`interrupted`). After sending `on:false` the shell may unmap the chrome or
     drop its keyboard: the closing animation it asked for runs to its end.
3. **Open / update.** Once the chrome holds the keyboard, send `hl.plugin.grassfield.overview("<json>")` through
   `Hyprland.dispatch`, guarded like the other verbs (add `overview` to `isPluginVerb` in `shell/platform/Minimized.js`),
   the JSON built only from validated pieces (hex address, finite rounded numbers) and quoted as a Lua string (escape
   `\` and `"`). Payload:
   `{"on":true,"durationMs":350,"curve":[0.2,0,0,1],"windows":[{"address":"0x…","x":…,"y":…,"w":…,"h":…},…]}`.
   - Rects are layout coordinates (global logical, like `hyprctl clients` at/size) of where the window's **surface box**
     (at/size, without the titlebar) is drawn. The scale is uniform: a rect of another aspect ratio gets the window
     centred in it. The plugin's titlebar (32 px) and shadow are drawn around it, scaled: keep `32 × scale` free above
     each rect and include that band in hit-testing and label placement.
   - Limits (else the request is refused): a JSON object of at most 16 KiB; `on` (bool) and `durationMs` (integer
     0..2000) required; `windows` required when `on` is true, at most 64 entries, unique addresses, finite numbers,
     `w` and `h` ≥ 1; `curve` 4 numbers, x in [0, 1], y in [-1, 2]. Ignored per window (not refused): an unknown or
     ineligible window (see (a)), a rect not inside the window's monitor (1 px tolerance).
   - `on:true` again while open (a window opened or closed, a window dragged to a Desktop) retargets: listed windows
     animate from where they are drawn, windows left out go back to their place at once.
   - Use the same `durationMs` and curve for the shell's own label and chrome animation.
4. **Close.** `{"on":false,"durationMs":350}` (curve optional), before or together with the focus action. The plugin
   also closes on its own when a window chosen by the user takes the keyboard from the chrome (v1 releases the grab,
   then activates the clicked window), when the keyboard leaves the chrome, when the chrome goes away (at once), on a workspace
   switch (animated back, `closing`/`interrupted`; WM-17) and at once on a monitor change. A window closing or opening while open does **not** end the
   overview, also when it was the active window (Hyprland then moves focus; the chrome keeps the keyboard): the window
   leaves the layout, the plugin posts the state with the new count, and the shell retargets with a new `on:true`.
5. **Events** `grassfield>>{"v":"gfc/1","type":"overview","state":"opening|open|closing|closed","windows":N}`, plus
   `"reason":"invalid|no-windows|no-chrome|unavailable|interrupted|fullscreen"` when relevant. They are coalesced
   (latest wins, at most one per 100 ms): treat them as a state, not as a log. `invalid` / `no-windows` / `no-chrome`:
   the request was refused, the state is unchanged: show thumbnails for this open (`no-chrome`: the chrome was not
   mapped, not Exclusive or did not hold the keyboard yet). `unavailable`: the plugin is unloading: thumbnails from now
   on. `interrupted`: the overview ended without the shell's `on:false`: close the chrome. `fullscreen`: a window went
   full screen while shown; the windows of its workspace went back to normal rendering (state unchanged): retarget
   without them or close. `windows` smaller than the number sent: some windows were not eligible (full screen, on a
   workspace showing a full-screen window, pinned, another workspace): leave them out or show thumbnails for them.
6. **Input.** Clicks and keys go to the chrome; the shell maps them through its own rects. Hyprland's real window
   boxes are unchanged during the overview, so activation, drag to a Desktop and close act on the real window as in v1.
7. **Restart.** After each `capabilities` event, if the shell has no overview open, send `{"on":false,"durationMs":0}`
   (idempotent: a closed overview answers `closed`).
8. **Limits to show honestly:** popups (menus) of a window stay at its real place and are not scaled; full-screen
   windows, and the other windows of a workspace that shows a full-screen window, are not transformed (decision
   2026-10-18: on macOS a full-screen app is a Desktop of its own, shown as a Desktops bar tile, and Hyprland draws only the
   full-screen window on such a workspace); Desktops bar tiles of other workspaces still need captures (nothing of another
   workspace is rendered); fractional scales and rotated outputs are not verified.

### Close and keyboard (overview fix pass 2, 2026-10-19)
Review of 5c0aab6 (FAIL): with two outputs the keyboard was lost after a close (Esc and IPC) and Esc focused the wrong
window. Cause: each output's chrome commits its keyboard mode on its own. When the chrome that holds the keyboard commits
`None` first, Hyprland tries `refocusLastWindow`, logs `ignoring, exclusive LS present` (the other chrome is still
Exclusive) and does not try again when the other chrome commits: no surface has the keyboard, while `activewindow` still
names a window. Setting every chrome to `None` in one QML step is therefore not one step for Hyprland. Esc also focused the
Desktop of the output whose chrome received the key instead of the window that was active.

Rule (macOS model): the overview remembers the window that had the keyboard when it opened (`Overview.previous`, address and
Desktop; none when the desktop surface held the keyboard, ADR-0012). Every close goes through `closeAnd(choice)`, which
first works out ONE target (`V2.closeTarget`: a window chosen, a Desktop tile chosen, the Desktop created with "+", the
remembered window, or none) and then:
0. with the plugin capability `overview-focus` sends that target as ONE `overview_focus` request (see "Close focus" below),
   before anything is released; without it the shell focuses after step 3 (below);
1. stage `releasing`: every chrome's keyboard mode is `None` (`V2.keyboardPlan`), keys are no longer handled;
2. wait until **no chrome reports the keyboard** (`Window.active` false on all) and `overview.releaseSettleMs` (0 ms: the next event-loop turn) have
   passed since the last change of that report (`V2.releaseDone`): all chromes have committed, so no Exclusive layer remains;
   `overview.releaseBoundMs` (500 ms) bounds the wait whatever happens (a lost event must not leave the overview open);
3. `on:false`, then the chromes hide. **Without `overview-focus` (C2)** the shell then focuses the target itself
   (`FocusReturn.startFallback`): `FocusReturn.fallbackPlan` keeps a remembered or chosen window that still exists and is not minimized (a
   minimized window never gets focus), a Desktop becomes its front window (`Compositor.frontWindowOn`: focused last; the
   Desktop itself when empty), anything else nothing (Hyprland's choice stands). The focus is the Lua dispatch (`Compositor.focusWindow`: its Desktop first when not the one
   shown), then checked (`FocusReturn.focusHolds`: the active window, or the focused Desktop) after
   `overview.focusRetryMs` (60 ms, doubling at each retry) and retried until it holds or `overview.focusBoundMs` (1 s) has
   passed. Nothing is focused while the session is locked.
Another full-attention surface opening (ExclusiveSurfaces: Apps, Search, the switcher) or the lock closes the overview with
`requestCloseForOther()`: same release, **no request and no focus action**, the keyboard belongs to the opening surface; when
that closes Hyprland returns the keyboard to the window that has it. When the plugin ends the overview itself
(`interrupted`: a Desktop switch, the lock) the same close runs (chromes released in order, request target `workspace` with the
Desktop focused at that moment, so the user's switch is kept when Hyprland refocuses the window that was active at open;
`none` when it is unknown), never `hide()` dropping every chrome at once. A switch of the Desktop of the output that does not
have the monitor focus leaves the focus where it was: that window keeps the keyboard. Keys typed while the release runs (about 100 to
150 ms after Esc) reach the chrome, which ignores them: they are lost, never delivered to another window (drop table below).

Keyboard selection is one value for all outputs (`Overview.selected`, `spaceFocus`, `spaceScreen`), since the keyboard
reaches whichever chrome Hyprland picked: the window that was active at open carries the highlight (`marked`, wherever it
is; App Exposé), nothing is selected yet, and the first arrow key moves from it to its neighbour (`V2.startSelection` finds
the start, `V2.startFromActive` says the first arrow already moves; with no window active at open the first arrow selects
the first window in reading order and stays on it). Later arrows move to the neighbour on that output (`Layout.neighbor`) and, with none that way,
to the window entered on the output lying that way (`V2.adjacentScreen`, `V2.entryWindow`: the same height, the near edge);
up with nothing above enters the Desktops bar of that output.

Two more measured facts. (1) The protocol `activate` does nothing for a window Hyprland still counts as focused, which is
exactly the one the chrome took the keyboard from (A active, pointer and holder chrome on A's output, Esc: keys lost 11 of
12 with `activate`, 12 of 12 recovered by the Lua `hl.dsp.focus({window=...})`), so `Compositor.focusWindow` uses the Lua
focus (`Minimized.focusWindowRequest`). (2) Releasing the holder last removes the `ignoring, exclusive LS present` refusals
(0 in the nested runs; 5 in 20 closes before).

Test setup: `tests/shell/overview_two_outputs.sh` runs on two HEADLESS outputs of the nested compositor (GF-REF 1920x1080
and GF-REF2 1440x900, created and removed through `nestctl`; WAYLAND-1, the nested window tiled by the owner's window
manager, is disabled for the run), so a host resize cannot change the measured geometry; the run is flagged INVALID when
an output size changes. The earlier `backdrop` failure on the second output only ever appeared together with a host resize of
WAYLAND-1 (output shrunk to 461x484 or 941x238: the click point fell off the output); on the headless pair the backdrop
click closes the overview on both outputs in every run.

Drop table (`drop`, one injector process `Esc, -s D, tag, Return`, 10 closes per row, previous window A or B alternating,
pointer alternating between the outputs), by `overview.releaseSettleMs`, plugin runs (the 0 ms value: 5 plugin and 2
`--no-plugin` runs of `all`, each 59/59 PASS on a fresh session):

| D after Esc | 80 ms setting (host pair) | 40 ms | 0 ms (7 runs) |
|---|---|---|---|
| 0 ms | 0/10 | 0/10 | 7-10/10 (9, 10, 9, 7, 10 with the plugin; 9, 8 without) |
| 30 ms | 0/10 | 0/10 | 10/10 |
| 60 ms | 0/10 | 8/10 | 10/10 |
| 100 ms | 6-8/10 | 10/10 | 10/10 |
| 150 ms and later | 3-10/10 | 10/10 | 10/10 |

No key ever reached the wrong window at any setting. With 0 ms the release completes as soon as no chrome reports the
keyboard; the only loss left is for keys sent in the same millisecond as Esc (the 0 ms row), before the chrome has handled
the key at all.

### Close focus (plugin `overview-focus`, owner decision 2026-10-19 batch 5)
Counter-review of the fix pass 2 (FAIL): with two outputs Esc still lost the keyboard (the holder released before the
other chromes' `None` commits landed; Hyprland refuses a refocus while any Exclusive layer exists, "refocusLastWindow:
ignoring, exclusive LS present", and retries nothing when the last one goes), and the protocol `activate` / `focusSpace`
did nothing for the window Hyprland still counts focused and for the current Desktop. Decision: **the shell names the
target, grassfield-compositor makes the focus at the moment the last Exclusive layer is gone**; without the plugin the shell
checks and retries itself (shell side shipped: `Overview.closeAnd`, `FocusReturn.startFallback`, see "Close and keyboard" above).
Plugin side shipped in 0.8.0-ovfocus (`compositor/src/OverviewFocus.*`, `core/OverviewFocus.*`, on the deferred focus shared
with Stages: `DeferredFocus.*`, `core/DeferredFocus.*`; requirements `docs/specs/compositor.md` FR41-FR43).

Shell contract (for the integration):
1. **Capability** `overview-focus` (gfc/1). Without it nothing changes: the shell keeps its own path.
2. **When.** As the close starts (Esc, a window or Desktop chosen, backdrop, IPC close, toggle), before the chromes drop to
   `None`, send once through `Hyprland.dispatch` (guarded like every verb: add `overview_focus` to `Minimized.pluginVerbs`;
   the Lua name has an underscore) `hl.plugin.grassfield.overview_focus("<json>")`, the JSON built from validated pieces:
   - a window chosen: `{"target":"window","address":"0x…"}`;
   - a Desktop tile chosen, or the Desktop created with "+" while open: `{"target":"workspace","workspace":N}`;
   - no choice, a window remembered at open: `{"target":"remembered","address":"0x…","workspace":N}` (its Desktop at open);
   - no choice and nothing remembered (the desktop or nothing had the keyboard): `{"target":"none"}`;
   - optional `"id":N` (0..2^32-1), echoed in the events. At most 512 bytes; a field the target does not use is refused.
   Then release the chromes as now and send `on:false`, but do **not** run the focus action (`Compositor.focusWindow`,
   `focusSpace`, `activate`): the plugin does it. A request closing for another full-attention surface (Apps, Search: the
   keyboard belongs to it) sends nothing.
3. **What the plugin does.** It waits until Hyprland's Exclusive-layer list is empty (every chrome released, no dialog),
   event driven: commits of every mapped layer surface (watched while it waits: a chrome that drops to `None` while another
   one is still Exclusive changes nothing else in Hyprland), unmaps, keyboard focus changes, the lock, and before every key
   (a key typed right after the last release gets the target first). Bounded: 1 s after the request it gives up (outcome
   `timeout`, Hyprland's choice stands). Then, checked again: the session lock (`refused`, nothing focused); the named
   window still exists, is not hidden, not minimized (on a special workspace) and its Desktop is shown → Hyprland's own
   focus (`CFocusState::fullWindowFocus`, reason `DISPATCH_FOCUSWINDOW`, what `hl.dsp.focus({window = …})` runs, without its
   cursor warp), which also gives the keyboard back to the window Hyprland still counts focused; a Desktop shown → its front
   window; a Desktop not shown → Hyprland's own switch (`Config::Actions::changeWorkspace`, what `hl.dsp.focus({workspace =
   …})` runs: the Desktop appears on its own monitor), then its front window; an empty Desktop → no window (Hyprland's active
   window cleared, the keyboard to nothing unless an `on_demand` layer such as the desktop holds it; that monitor focused).
   **Fallback** (the window closed, minimized, hidden or moved to a Desktop not shown, the Desktop gone, Hyprland refused the
   window, or `none`): the front window of the remembered Desktop when it is still shown (macOS: leaving Mission Control
   returns to the Desktop you were on), else of the Desktop shown on Hyprland's focused monitor (Hyprland moves the monitor
   focus to the pointer's output when the focused window closes), else no window. **Front window** = the window of that
   Desktop focused last (Hyprland's focus events since the plugin loaded; macOS: the front-most window is the one activated
   last), then the stack top down; only windows taking input (never a Stages strip window), not hidden, focusable.
   **A dialog that opens during the close** (audit GF-038, A11Y-10; macOS: a modal dialog takes the keys): when the chrome
   that held the keyboard releases it, Hyprland clears the keyboard focus and refuses its own refocus while any Exclusive
   layer is left, and only a pointer motion would give the keyboard to the remaining layer. While the request waits (and at
   its bound), when the keyboard is on nothing (no window, no layer surface that takes it), the plugin gives it to the
   remaining Exclusive layer as that motion would: the one under the cursor, else the newest; never a layer of the
   namespace that held the keyboard when the request came (the closing chromes on the other outputs). Hyprland's own
   surface focus (`CFocusState::rawSurfaceFocus`); no outcome is posted for it (the request still waits, then `focused`
   after a short dialog or `timeout` past the bound).
4. **The user wins.** A press after the request beside every Exclusive layer on a window (Hyprland gives such a press to the
   remaining Exclusive layer and focuses nothing) makes that window the target (`"target":"press"`); a press while Hyprland
   accepts window focus, or a user's focus choice of another window (key binding, dispatch, activation), ends the request
   (`superseded`). A press into a chrome or a dialog changes nothing. A newer request replaces a waiting one.
5. **Events** `grassfield>>{"v":"gfc/1","type":"overview-focus","outcome":"…","target":"window|workspace|remembered|none|press","id":N}`
   plus `"address"` (the window that holds the keyboard), `"workspace"` and `"reason"` when known. Outcomes: `pending`,
   `focused`, `fallback` (reasons `gone`, `minimized`, `hidden`, `not-shown`, `no-workspace`, `none`, `refused-by-hyprland`;
   no address: no window), `timeout` (`exclusive-layer`), `refused` (`locked`), `superseded` (`press`, `user-focus`),
   `unavailable` (`unloading`), `invalid`. Coalesced (channel `overview-focus`, latest wins): a state, not a log.
6. **Without the plugin** (absent, older, unload: capabilities `[]`) the verb does not exist; the guarded call is a no-op and
   the shell checks and retries (`FocusReturn.startFallback`). An unload while a request waits posts `unavailable` first.

Evidence (nested Hyprland v0.56.2 commit efb50993, plugin 0.8.0-ovfocus, headless pair GF-REF 1920x1080 + GF-REF2
1440x900 with WAYLAND-1 disabled, `tests/compositor/overview_focus.sh`, fixture `tests/compositor/overview-focus-fixture`:
one Exclusive Overlay chrome per output, namespace `grassfield-overview`, released holder first / holder last / together,
staying mapped or unmapping): **66/66 PASS** on the final build (`.dev/overview-focus/run-20261019-194052-check`, also
`run-20261019-192909-check`; 53/53 on an earlier script version). Keys (letters only, `scripts/dev/keys.sh`) reached exactly the target in every
case: the window active at open (still Hyprland's focused window) for the three release orders; a window on the other
output (chromes staying mapped or unmapping); the current Desktop; a Desktop shown on the other output; another Desktop
(switched on its monitor); a chosen window closed during the close and a remembered window minimized during the close
(fallback to the front window, the minimized one got nothing and stayed minimized); a press beside the remaining chrome on
the other output's window (that window, target `press`); a polkit-like dialog appearing during the close (its field got the
letters, no window did; outcome `timeout` past the bound; a short dialog: no outcome while it was up, the target after it);
the session lock during the close (`refused`, no `activewindowv2` naming a window while locked, nothing typed). Hyprland
logged its `ignoring, exclusive LS present` refusal about 10 times per run (the refocus it gave up, after which the plugin
focused).
Comparison (`overview_focus.sh baseline`: the verb absent, the guarded call a no-op, nothing emulates the shell's own focus
action): the old build 0.7.1-stages **32/44** (`run-20261019-201004-baseline`) and a `--no-plugin` session (C2) **32/44**
(`run-20261019-200901-baseline`; `hyprctl grassfield` "unknown request", shell log "no compositor plugin reply, running in
degraded mode", safety checks all PASS): the window on the other output, the Desktop on the other output, another Desktop and
the press got nothing (the keys went to the last focused window); after a closed or a minimized target the keys were lost;
the remembered window on the same output and the current Desktop got them (Hyprland's own refocus did it in this fixture).
Under load: `soak.sh 1260` PASS with `overview_focus.sh stress 1200` alongside (4239 requests at ~4/s, 423 invalid, every one
answered; no exception), and `stress 180` alone (647 requests, 2 floods of 100 answered with one outcome each).

### Keyboard return of the other Exclusive surfaces (R13 follow-up, 2026-10-20)
Same class of bug as the Overview's: Search was destroyed while Exclusive (`visible: shown`) and Hyprland then names no
keyboard window although it still reports the previous one active (pointer on another output than the active window: the
typed keys went nowhere). Apps passed because it fades out mapped with its keyboard already `None`. The rule for every
Exclusive shell surface (macOS: Spotlight, Launchpad, menus and the switcher give key focus back to the window that was key):
1. **Release while mapped.** The surface drops to keyboard `None` first and unmaps `focusReturn.releaseHoldMs` (120 ms)
   later (`shell/platform/KeyboardRelease.qml`: `mapped = shown || holding`). Search, Apps (also for Reduce Motion), the app
   switcher (a commit's activation follows the unmap, 120 ms later), the popup host (`grassfield-overlay`), the Notification
   Center and the desktop widget menu use it.
2. **Return to the remembered window** (`shell/platform/FocusReturn.qml`, singleton). Each surface reports `opened(name)`
   and `closed(name, restore)` from its controller; the first to open remembers the active window (`Compositor.activeWindow()`,
   none when the desktop icons hold the keyboard), the decision is taken one event-loop turn after the last holder closed (so
   a hand-over such as Apps -> Search never fights over the focus: only the last close restores). The Overview is a holder
   with `restore=false` (it names its own target). Nothing is requested when the lock is up, no window was remembered, or
   another window is active at the decision (someone chose it); menu items that raise a window call `FocusReturn.skip()`
   (`AppMenus` "window" and "bringAll", `Notifications.focusSender`), and a switcher commit passes `restore=false`.
   With the plugin capability `overview-focus`: ONE `{"target":"remembered","address","workspace"}` request (the plugin
   waits for the last Exclusive layer, and a later user focus supersedes it). Without it (C2): the shell's own focus
   after the hold, check and retry as described under "Close and keyboard" step 3, shared code (`FocusReturn.js`:
   `fallbackPlan`, `focusHolds`, `retryDelay`, `userActed`, `checkOutcome`, `restoreTarget`; unit tests
   `tst_focusreturn.qml`, `tst_overviewv2.qml`). The retry records the active window and Desktop before each attempt and
   stops, at the next check, when another window than the goal and than that one is active, another Desktop than the goal
   is focused, any Exclusive surface is open, the lock is up or the bound (1 s) passed.
Tests: `tests/shell/overview_two_outputs.sh control` (Apps, Search, the switcher, each closed by IPC and by Esc, the pointer
on either output, either window active, no overview: the window active at open holds the keyboard; with the plugin and with
`--no-plugin`), `paths` (the same through the Overview's close paths; the Search skip is gone), `clickwins` (a click on the
other window after the close wins, 10 of 10).

### Two outputs and shared drawing (2026-10-18, plugin 0.6.0-stages)
The chrome rule is relaxed (contract item 2): one Exclusive chrome holding the keyboard, a mapped chrome on every target
monitor. The drawing code moved to `compositor/src/WindowTransform.*` (shared with Stages, unchanged) and the JSON reader to
`compositor/src/core/Json.*`. `tests/compositor/overview.sh check` **32/32 PASS** (runs `.dev/overview/run-20261018-130541`, `run-20261018-142052`),
new two-output case: chrome Exclusive on GF-REF and keyboard None on WAYLAND-1, `on:true` with windows on both outputs
opens with 7 windows; a click at the WAYLAND-1 window's real place reaches nothing while open; after `on:false` and the
chrome dropping its keyboard, the previously active window gets the keys. "No chrome on the second output" cannot be staged
with the shell running (its persistent overview surfaces are mapped on every output between opens): unit
`OverviewChrome.*`.

### R13 fix pass (2026-10-18, plugin 0.5.0-df)
Review of f12f610 (FAIL): major `on:true` accepted without the chrome; minors: active-window close ended the overview,
full-screen windows ignored at workspace level, `render.pre` never updated the last damaged box, check count misstated.
Fixes: chrome requirement and failsafes (contract items 2 and 4), retarget on close (item 4), full-screen decision (items
5 and 8), damage (`core damageStep`: the box drawn in each frame becomes the last damaged box, so a surface resized while
open has every box it was drawn in damaged again, also the box detached at close). Measured: Hyprland 0.56.2 emits
`window.active` for the closing window itself (reason "other") while it refuses the keyboard to the next window because
the chrome is Exclusive: the failsafe now requires a mapped window that took the keyboard away from the chrome.
`tests/compositor/overview.sh check`: **29/29 checks PASS** (the run prints `PASS (n/N checks)`; the f12f610 version had
20 checks, not 21 as reported). Screen captures cannot show stale pixels (a capture with the damage fix reverted showed
none either; captures most likely repaint the whole output): the resize check reads the plugin's damage log instead, and
it fails on the reverted build (`open box height 351, box damaged at the start of the shrink none`) and passes on the fix
(`351 → 491`).

## v2 shell side (shipped 2026-10-18)
Code: `shell/overview/Overview.qml` (controller, conversation with the plugin), `OverviewWindow.qml` (chrome, one per output),
`OverviewBackdrop.qml` (Bottom-layer dim, namespace `grassfield-overview-backdrop`), `V2.js` (event parsing, decisions,
layout coordinates; `tests/unit/tst_overviewv2.qml`), `Minimized.overviewCall` (the one validator/Lua quoter,
`tst_minimized.qml`), `Compositor.overview()`. Tokens: `overview.windowTitlebarHeight` 32 (the plugin's `kTitlebarHeight`), `chromeWaitMs`, `chromeRetryMs`.
- Selection: `thumbnailMode = thumbsThisOpen || !Capabilities.has("overview")`; `thumbsThisOpen` is decided at each open
  (no capability, or a full-screen window on a shown Desktop) and set by a fallback (refusal `invalid`/`no-windows`, `no-chrome`
  after one retry, `unavailable`, `fullscreen`, chrome not holding the keyboard within `chromeWaitMs`). A fallback while
  windows are transformed first sends `{"on":false,"durationMs":0}`.
- Open: every output's chrome is Exclusive (pointer input, see Surfaces); once a chrome is `Window.active`
  the layout of all outputs is sent (surface box = layout rect minus the 28 px band x scale, global coordinates).
  `durationMs` = `motion.slow` (350), 0 with Reduce Motion (the dim then crossfades in at most `motion.reducedMax`).
  A new layout while open (window opened/closed/moved) retargets with a new `on:true`.
- Close: the focus target goes to the plugin first (`overview_focus`, capability `overview-focus`); every chrome drops to
  keyboard None; when no chrome reports the keyboard any more and the settle pause has passed, `on:false` is sent and the
  chromes hide (the plugin lets the asked closing animation finish; without `overview-focus` the shell focuses afterwards
  and checks).
  Esc, a click on a window or on empty space, a Desktop tile, IPC close/toggle all go through it ("Close and keyboard").
- Input is the shell's own: per-window hit areas (surface + band), hover selects and shows the app label, arrows/Tab/Return,
  drag to a Desktop tile (a ghost follows the pointer; the real window stays drawn by the plugin; drop = `moveToSpace`).
- "+": switches to the new Desktop; the plugin ends its overview on a Desktop switch, the shell keeps the chrome open on the
  empty Desktop (no layout is sent for zero windows).
- Restart: after every `capabilities` event with no overview open, `{"on":false,"durationMs":0}` is sent.
- Evidence (nested Hyprland 0.56.2, plugin 0.5.0-df, GF-REF, 6 foot windows + 1 on WAYLAND-1): open via IPC shows real windows
  scaled with live content (`.dev/shots/ov3-hover.png`), `hyprctl clients` at/size identical before/during/after, click on a
  window focuses it and closes, Esc closes, "+" adds Desktop 3, drag to a tile moves the window (ws2 6 -> 7 windows), CPU
  with 6 idle windows: closed Hyprland 0.0 % / shell 0.1 %, open Hyprland 0.4 % / shell 1.2 % (v1 live: 43.1 % / 104.8 %,
  balanced 0.3 % / 1.3 %). `--no-plugin`: thumbnails as before.
- Residual limits: popups (menus) of a window are not scaled; the parts of a window outside its output are not drawn
  (the plugin renders into a monitor-sized buffer); fractional scales and rotated outputs are not verified; when the plugin
  reports fewer windows than sent (ineligible ones) their hit areas still sit at the layout rect; Desktops bar tiles of other
  Desktops have no capture; Ctrl+Up is the owner's binding (not in the dev config: IPC `overview toggle` was used).

## Mission Control finish (B1, 2026-10-20)
- Desktops bar: full-width Material band from the menu bar to 164 pt, thumbnails 138 x 90 centred with the Desktop name under
  each (13 pt), round 32 add button 18 pt from the right edge (tokens `overview.barHeight`, `tileLabelGap`, `addEdgeInset`).
- Defect #10: the window that was active at open carries the accent ring and its name label at once (`OverviewWindow.marked`:
  hover or keys' selection, else the remembered window); Return with nothing chosen activates it.
- Side-by-side sheets against gs-066-145 (local only): geometry of band, thumbnails, names and add button matches within 2 pt.
  Desktop thumbnails still show the app icon, not a capture of the Desktop (needs plugin support, not done).

## Desktop miniatures and backdrop (visual audit 2026-10-25, priority 12)
macOS model: the desktop thumbnails of the band are miniatures of the desktop, not grey tiles with icons, and the wallpaper is not dimmed. Shell side, with the existing capture API: `Compositor.spacesOn` also returns the windows of each Space and the output size; `MiniDesktop.qml` draws up to `overview.miniMaxWindows` of them at their place, scaled (`ScreencopyView` of the window's foreign-toplevel handle, one frame, for the windows of the OTHER desktops), each a plain card with the app icon until its frame is there. The windows of the ACTIVE desktop stay cards with their icons (`MiniDesktop.capture` false): while the Overview is open the compositor plugin lays those windows out, and a frame taken of one came back as plain wallpaper in the nested session (at open and 700 ms later, checked with `tests/visual/scenarios/overview-desktops.sh`); a window of a hidden Space does answer a capture. `overview.backdropOpacity` is 0.1 (was 0.45); Reduce Transparency keeps its opaque dim. Missing: the wallpaper behind the miniature windows. The shell has no still image of the wallpaper (it is procedural, an image or a video), and the capture protocol offers windows and outputs, not the wallpaper layer; the thumbnail therefore shows the tile fill under the windows. A wallpaper still (a frame the wallpaper module writes for the lock screen already exists for images) would need a small service in `shell/desktop`. A window without a frame stays a card with its icon.
