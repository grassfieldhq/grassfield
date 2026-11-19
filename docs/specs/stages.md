# Stages spec (stage manager equivalent) · compositor-engineer (plugin) + shell-engineer (strip) · M5

UI naming (renamed 2026-10-18, owner decision): "Space" in older notes is shown to the user as "Desktop" (fr « Bureau »).

Status: spike positive; plugin prototype behind a feature flag (plugin 0.7.1-stages, 2026-10-19: fix pass 4 after the R13
counter-review #4 of 0.6.3-stages, tested as 0.6.4-stages and again after the merge with cursor-refresh 0.7.0-cursor;
nested only); shell strip implemented ("Shell side" below; shell code not yet verified in a nested session). Decision: `docs/decisions/ADR-0013-stages.md`. UI name **Stages** (§14);
the Apple name is never used in the UI. Code: `compositor/src/core/Stages.*` (model, validation, geometry, events; unit
tests `compositor/tests/StagesTest.cpp`), `compositor/src/Stages.*` (Hyprland glue), `compositor/src/WindowTransform.*`
(drawing shared with the overview), verb in `compositor/src/Ipc.cpp`. Nested scenario: `tests/compositor/stages.sh`
(`check`, `perf`) with the strip stand-in `tests/compositor/stages-fixture`.

## macOS reference behavior (ASSUMPTION: described from memory; no reference material was checked)
- When turned on, the windows of the current app (its "stage") are centred and usable; every other recent app (or group)
  is a small live thumbnail in a strip on the left edge, one tile per stage; the several windows of one app are stacked in
  its tile, and the app icon is shown with it.
- Clicking a tile swaps that stage with the current one, animated: the current windows shrink into the strip while the
  chosen ones grow back to where they were on the stage.
- Dragging a thumbnail onto the stage adds that window to the current stage; dragging a window from the stage to the strip
  makes it a stage of its own. Stages can be grouped (Shift-click a tile adds its windows to the current stage).
- Opening a window of another app starts a new stage (the previous one goes to the strip); activating an app another way
  (Dock, app switcher) brings its stage forward.
- The strip hides when a window overlaps it and reappears when the pointer reaches that edge.
- Each display and each Desktop has its own stages. Full-screen apps are Desktops of their own.
- Off by default; turned on in Quick Settings (and Settings).

## Purpose and non-goals
Purpose (M5, master-prompt §5.6 item 6, §12): "Stage Manager (plugin layout + shell strip), behind a feature flag",
the highest-risk feature, last. This spike decides where the model lives and how Hyprland 0.56.2 can hide windows while
showing them live in a strip, and delivers a plugin prototype with a precise shell contract.

Non-goals of the prototype (C-STG-1: the shell strip is NOT a non-goal of 1.0, it is in scope and specified in "Shell side" below): persistence of stages across a
plugin or shell restart, the "one window at a time" app mode, showing desktop icons while Stages is on (a shell choice),
tiled windows (ADR-0002: floating-first; windows tiled by Hyprland's layout and pinned windows stay out of Stages; windows
placed in tiles by Grassfield's window tiling stay floating and take part, `docs/specs/tiling.md` TL13), transforming popups, a perspective
tilt of stacked thumbnails (they are stacked flat, 8 px apart).

## Functional requirements
- **ST1** Feature flag: `hl.plugin.grassfield.config("stagesEnabled", "true"|"false")`, validated like
  `titlebarDoubleClick` (exact strings; anything else is rejected and logged, no change). Off at every plugin load.
  Turning it off ends Stages at once (every window shown normally).
- **ST2** Capabilities: `stages-available` whenever the Stages listeners, `hl.plugin.grassfield.stages` and `config`
  registered (the shell shows the Quick Settings toggle); `stages` only while the flag is on (always together with
  `stages-available`). A change of the flag re-posts the capabilities.
- **ST3** `op:on` (flag on, strip surface present, ST17) groups the managed windows of every workspace by app (window
  class): one stage per app; the stage of the focused window (else of the front window) is active; the others form the
  strip, most recent first (by their front-most window in the stacking order). Managed windows: mapped, visible,
  floating, not pinned, on a regular workspace, not X11 override-redirect; at most 64 per workspace (others are shown
  normally).
- **ST4** The active stage's windows are shown and usable at their real places, unchanged.
- **ST5** Every window of a strip stage stays mapped on its workspace at its real place and is drawn, live, into its tile
  (`Render::IWindowTransformer`, as the overview): its surface box fitted with its 32 px titlebar band (uniform scale,
  never enlarged, centred) into its stack position; stacked windows of one stage step 8 px up-left (at most 3 distinct
  positions, the front window bottom-right). Stages beyond the tiles are drawn off the monitor (not visible). No client is
  ever moved, resized or configured. A frame without a free pooled work buffer draws the window as nothing (never at its
  real place).
- **ST6** Strip windows take no input at their real places: the plugin sets its own input block reason
  (`CWindow::setInputBlocked`, bit `1 << 6`), so Hyprland's hit test skips them for pointer focus, clicks, hovers and
  titlebar presses. Keyboard: a strip window focused by a user choice brings its stage forward (ST10). Hyprland 0.56.2
  re-evaluates pointer focus only on pointer motion and delivers buttons, scrolls and keys to its current focus without
  checking input blocks, so the plugin also keeps every event away from a strip window (R13 review of 46b3e9b):
  - whenever a block changes (swap, new window, close, minimize, strip update, Stages off) it re-runs Hyprland's pointer
    focus logic at the cursor (`CInputManager::simulateMouseMovement`, as a pointer motion would), so the surface
    actually under the cursor gets the pointer; inside Hyprland's teardown paths (a layer surface unmapping, monitors
    changing) this runs from the event loop;
  - before a button press, a release or a scroll is delivered (the plugin's first button listener, and a scroll
    listener), a pointer focus still on a strip window or one of its popups is refreshed the same way; while a held
    button pins it there (Hyprland keeps the pressed surface), the pointer focus goes to nothing (the window gets
    `wl_pointer.leave`, the event reaches no surface) and is refreshed after the release. Button events are never
    cancelled: Hyprland's held-button state sees every press and release;
  - before a key is delivered (and before Hyprland runs its key bindings), a pending model change is applied first;
    Hyprland's active window then moves off a strip window (ST24); a menu of a strip window closes (below); a keyboard
    focus still on a strip window then goes to the front window of its workspace's active stage, or to nothing;
  - menus (R13 counter-review of 17208af): Hyprland 0.56.2's `xdg_popup` grab holds the menu and its parent surface,
    keeps the keyboard on the toplevel and refuses the keyboard to every other surface while it lasts
    (`CFocusState::rawSurfaceFocus`). A window going to the strip with a menu open therefore loses that menu first, as a
    click outside it would (Hyprland's own path, `CSeatManager::setGrab(nullptr)`: the app gets `xdg_popup.popup_done`),
    before the incoming front window is focused: no key reaches the strip window and none is lost (macOS: switching
    apps closes the open menu). A menu of a window of the active stage keeps its grab and its keys;
  - touch: a touch down goes through Hyprland's own refocus at the touch point, whose hit test skips strip windows; a
    touch already held when its window goes to the strip keeps its target until it ends;
  - the desktop focus policy counts a pointer focus on a window that does not take input as stale (its press target is
    then the surface under the cursor).
- **ST7** `op:activate` swaps a strip stage with the active one: the outgoing windows animate from their real places to
  their tiles, the incoming ones from their tiles to their real places, other strip stages move between tiles, over the
  `durationMs` and `curve` of the latest `op:on`, interpolated every frame by the plugin; the incoming front window is
  focused. Input of the incoming windows is unblocked before the focus, the outgoing ones blocked after it.
- **ST8** A new window (or one restored or moved in from another workspace) joins the stage holding a window of the same
  app, which becomes active; otherwise it opens a new active stage and the previous active stage leads the strip.
- **ST9** A window that closes, unmaps, moves away, becomes pinned or tiled leaves its stage at once (shown normally); an
  emptied stage disappears; when the active stage empties, the most recent strip stage becomes active. When the window
  that leaves held the keyboard, Hyprland's successor keeps it only if it may hold the keyboard (mapped, not hidden, on a
  workspace shown on a monitor, taking input, or a window of the stage that just became active); otherwise the active
  stage's front window takes it, or, with no stage left on that workspace, nothing does (keyboard focus cleared; the
  desktop policy decides on the next press). The keyboard never stays on a minimized, hidden or strip window (R13 review
  of 46b3e9b: Hyprland cannot pick a blocked successor and left the keyboard on a window it had just moved to
  `special:minimized`).
- **ST10** Hyprland focusing a strip window by a user choice brings its stage forward: a key binding (`KEYBIND`), a
  focus dispatch (`DISPATCH_FOCUSWINDOW`, `DISPATCH_MOVEWINDOWINTOGROUP`; Dock, Search, scripts), an activation request
  (`DESKTOP_STATE_CHANGE`: `CWindow::activate`, i.e. xdg-activation and the shell's foreign-toplevel activate), a click
  (`CLICK`, only when a real press caused it, below) or a window switch dispatcher (`SWITCH_TO_WINDOW_SOFT/HARD`:
  `cycle_next`, `focus { last }`). A strip window Hyprland picks itself does not (R13 counter-review of 17208af: every other
  reason used to count as a choice): after a close (`UNMAP_*`), when it restores a window it focused before (`FFM`: an
  Exclusive layer released the keyboard, a popup grab ended; `TOGGLE_SPECIAL_WORKSPACE`; `WORKSPACE_CHANGE` back to a
  Desktop's last focused window), or for another reason of its own (`NEW_WINDOW`, `GROUP_CURRENT_WINDOW_CHANGE`, `OTHER`,
  `UNKNOWN`, `GHOSTS`). The active stage then keeps the keyboard (its front window takes it, ST9).
  **Clicks (R13 counter-review #4 of 0.6.3-stages).** Hyprland 0.56.2 reports `CLICK` for every refocus at the cursor
  (`CInputManager::refocus`): on a press, but also when an Exclusive layer unmaps while there is no active window (which is
  the case after a swap under it, ST24), after the unlock, when a grab ends or a Desktop's last window closes. So a `CLICK`
  focus is a user choice only when a press caused it: the plugin records every pointer button press (its first button
  listener), touch down and tablet tip/button press before Hyprland handles it. With no Exclusive layer mapped, a press
  counts while Hyprland handles it (Hyprland's refocus for it runs then; the record ends from the event loop). While an
  Exclusive layer is mapped Hyprland gives every press to the layer and refuses window focus: a press into the layer (a
  dialog's button, Search) chooses no window; a press beside every Exclusive layer on a window (Hyprland's own hit test at
  the cursor) is the user's click on that window and counts for that window's refocus once the layer is gone (macOS: a
  click outside a panel activates the window clicked), unless a later swap, another focus change or the end of the last
  Exclusive layer came first. A refocus at the cursor without a press is Hyprland's own pick (`FocusOrigin::CursorRefocus`,
  unit tests `StagesInput.ARefocusAtTheCursorWithoutAPressIsNotAClick`, `APressIsAClickWhileHyprlandHandlesIt`,
  `APressBesideAnExclusiveLayerChoosesTheWindowPressed`). `WORKSPACE_CHANGE` is ambiguous in 0.56.2: a focus request for a window
  of a Desktop that is not shown switches to that Desktop first (`CFocusState::rawWindowFocus` makes the requested window
  the Desktop's last focused window, then `CMonitor::changeWorkspace` focuses it with `WORKSPACE_CHANGE`). The plugin
  records the last window Hyprland focused on each workspace (from Hyprland's focus events, read from
  `m_lastFocusedWindow` when Stages turns on): a `WORKSPACE_CHANGE` focus of a strip window that already was that
  workspace's last window is a restore; any other is the redirected request (the Dock activating an app of another
  Desktop) and brings its stage forward. Hyprland's reasons are mapped one to one in the core (`gf::stages::FocusCause`,
  unit test `StagesInput.OnlyRealUserFocusIsAChoice`); a reason added by a Hyprland update is a compiler warning.
  **Window cycling (decision, macOS model).** Hyprland's `cycle_next` (the session binds ALT+TAB to it; the app switcher,
  `docs/specs/switcher.md`, is SUPER+TAB) skips windows that do not take input, so it cycles among the active stage's windows (and
  windows Stages does not manage) and never reaches a strip window. That is the macOS model: Cmd+` cycles the windows of
  the current app, and with Stages the active stage holds the current app's windows; Cmd+Tab switches apps and brings the
  chosen app's stage forward, which is Grassfield's activation path (Dock, Search, the app switcher: they focus the app's
  window, which brings its stage forward as above; the switcher activates once its own exclusive layer surface is gone,
  because Hyprland refuses to focus a window while one exists). A stage-aware ALT+TAB would need either a function hook on
  `CWindowQuery::cycle` (rejected: fragile against Hyprland updates, as in the overview spec) or a plugin verb bound in
  the session config (outside the plugin); the SUPER+TAB switcher covers app switching, SUPER+` the windows of one app.
- **ST11** `op:move` moves a window into a stage of its workspace (on top) or into a new strip stage (`"stage":"new"`;
  refused when the window is already alone); `op:merge` moves every window of a strip stage into the active stage.
  Requests naming an unknown stage or window change nothing (`reason:"unknown"`).
- **ST12** `hidden:true` in a strip slides its thumbnails out to the left of the monitor (animated); `hidden:false` brings
  them back.
- **ST13** The event reports `overlap:true` while a window of the active stage (or any input-accepting window of that
  workspace) intersects the strip band (tiles + 8 px): the shell then hides the strip.
- **ST14** Full screen: while the workspace shows a full-screen window its strip thumbnails are off the monitor; a strip
  window made full screen (dispatch by address) brings its stage forward.
- **ST15** Minimize: a minimized window (on `special:minimized`) leaves its stage; restored, it joins (ST8). The keyboard
  follows ST9: minimizing the only window of the active stage brings the most recent strip stage forward and its front
  window takes the keyboard; nothing is ever typed into the minimized window.
- **ST16** Overview: a window the overview transforms is drawn untransformed by Stages (the overview's transformer takes
  it from its real place); strip windows stay input-blocked under the overview's chrome.
- **ST17** Strip surfaces: a strip is accepted for a monitor only when a mapped layer surface with namespace
  `grassfield-stages` is on that monitor, on the Top or Overlay layer, and its box and its input region (corners and
  centre of each tile) cover every tile; otherwise `op:on` is refused (`reason:"no-strip"`). Thumbnails are thus drawn
  only where the shell takes the clicks: a click on a thumbnail can never reach a window hidden under the drawing.
  A workspace whose monitor has no strip is shown normally (its model is kept).
- **ST18** Failsafes: the strip surface going away (shell exit or unmap) shows that monitor's windows normally at once
  (`reason:"interrupted"`); a monitor removal or layout change drops the strips (`interrupted`); a later `op:on` resumes.
- **ST19** Unload: every window back to normal rendering with its input unblocked, transformers detached before
  `dlclose`, pending callbacks and the watchdog removed, `{"on":false,"reason":"unavailable"}` posted; a reload starts
  with the flag off.
- **ST20** Robustness (R11): the payload is copied out of Lua with non-raising calls and parsed strictly; events go
  through the event throttle (channel `stages`, one key, latest wins); request-triggered log lines share the request log
  budget; activate / merge / move requests change the model at once but are applied once per event loop pass, so a Lua
  dispatch with any number of requests causes at most one focus change (Hyprland's own `activewindow` events are not
  throttled: see "Spike results").
- **ST22** Workspaces: stages are per workspace; a workspace that is not shown on any monitor keeps its windows as they
  are drawn (blocked and in their tiles), so switching back (and Hyprland's workspace slide) finds them in place. On a
  switch to a Desktop with stages the keyboard rule of ST9 applies: Hyprland may focus nothing there (its candidates skip
  blocked windows, and the last focused window may have closed while that Desktop was not shown); the active stage's
  front window then takes the keyboard.
- **ST21** Degradation: without the plugin (or with an ABI mismatch, or with `stages-available` missing) Stages does not
  exist: no verb, no capability, Quick Settings hides the toggle; nothing in the shell depends on it.
- **ST23** Exclusive layer: a swap requested while an Exclusive layer (overview chrome, Search, Quick Settings, the
  polkit dialog) holds the keyboard is applied and kept, and the layer keeps every key. Hyprland refuses every window
  focus while an Exclusive layer is mapped or the session is locked (`CFocusState::rawWindowFocus`); the plugin then
  never asks it for one and never works around the refusal (R13 counter-review #3 of e9ebc7f: setting Hyprland's
  Exclusive-layer list aside for one focus call also disabled the guard for that call's side paths: a special workspace
  closing and a switch to a Desktop not shown focused the window, so the keys typed into the layer reached it). Under the
  layer the model changes, the windows are drawn and blocked as usual, Hyprland's active window is cleared if it would be
  a strip window (ST24) and the incoming front window is remembered (deferred focus). Nothing else changes: no keyboard,
  monitor, Desktop or special-workspace change, no `activewindow` naming a window. When the layer releases the keyboard
  (it unmaps, or drops its keyboard interactivity), Hyprland runs its own refocus first (the closed event comes before
  it, so the plugin tries from the event loop; also after a keyboard focus change, after the unlock and before a key);
  the front window of the remembered Desktop's active stage then takes the focus and the keyboard if that Desktop is
  shown and not covered by a special workspace, no Exclusive layer is mapped, the session is not locked and the layer
  that held the keyboard does not keep it (it dropped to on_demand): it replaces what Hyprland's refocus picked (a window
  or a surface under the cursor, or nothing). That front window is the remembered one, or, when the remembered window
  closed, was minimized or moved away (or another stage came forward) while the layer was up, the window in front of that
  Desktop's active stage now (macOS: the frontmost app's key window gets the keyboard back; R13 counter-review #4 of
  0.6.3-stages: with the remembered window closed and the pointer over empty space the keyboard ended on nothing).
  Hyprland's own pick meanwhile (its refocus at the cursor without a press, a restore of its last window) neither drops
  the deferred focus nor brings that window to the front of its stage (R13 counter-review #4: the refocus at the cursor
  counted as a click, and an unrelated window or the stage's back window under the pointer kept the keyboard).
  Otherwise Hyprland's choice stands: a special workspace stays open and its window keeps the keyboard (the active stage
  takes it when the special workspace closes: ST10 restore + ST9), a Desktop not shown is not switched to (ST22 when it is
  shown again), a Desktop with no stage left gets nothing; a user's focus choice in between (a key binding, a dispatch, a
  real click, also a click beside the layer while it was up: ST10) supersedes it. Decision `gf::stages::pendingFocusAction`,
  unit tests `StagesInput.ADeferredFocusWaitsForTheLayerAndIsCheckedAgain`, `StagesInput.ADeferredFocusFallsBackToTheFrontWindowNow`.
  The swap is never undone silently (R13 review of 46b3e9b). The same holds for every focus the plugin requests under such a layer: a close that empties the active stage;
  a minimize or a move that empties it, a new window that maps while a layer surface holds the keyboard (same code path,
  not exercised in nested).
- **ST24** Hyprland's active window (`CFocusState::window()`) is never a strip window (R13 counter-review of 17208af: after
  a swap under an Exclusive layer it stayed on the outgoing window, hidden in the strip; `hl.dsp.window.close()` closed
  it). It is what window key bindings (close, full screen, floating), window dispatchers without an explicit window and
  the shell's menu bar (foreign-toplevel `activated`, the `appmenu` window) act on, and it differs from the keyboard holder
  while a layer surface holds the keyboard. A safety property in the plugin (it holds without the shell), checked after
  every retarget and before every key (key bindings run after the plugin's key listener). When Hyprland's active window is
  (or is about to be blocked as) a strip window:
  - while an Exclusive layer is mapped (Hyprland refuses window focus) it is cleared, nothing is focused: no active
    window, the keyboard holder untouched. `CFocusState::resetWindowFocus` (what Hyprland itself does when its focused
    window unmaps, also under an Exclusive layer: `CWindow::onUnmap`), then what Hyprland sends when its focus goes to
    nothing, without its keyboard change: the window is deactivated (`CHyprXWaylandManager::activateWindow(w, false)`, as
    Hyprland does for the previous window on a focus change), `activewindow` / `activewindowv2` name no window and
    `window.active` is emitted without a window (foreign-toplevel "activated", the appmenu server: the shell's menu bar
    names no app from Hyprland; the Stages state still names the front app, contract item 4); then what Hyprland rechecks
    on a focus change: the window rules matching on focus (`CWindowRuleApplicator::propertiesChanged(RULE_PROP_FOCUS)`, so
    a focus-only opacity or idle-inhibit rule leaves the window) and the idle inhibitors
    (`CInputManager::recheckIdleInhibitorStatus`; R13 counter-review #4 of 0.6.3-stages). No focus request, no monitor,
    Desktop or special-workspace change: nothing of Hyprland's focus path runs (R13 counter-review #3 of e9ebc7f). The front window of its workspace's active stage takes the focus when the
    layer releases the keyboard (ST23). Until then window key bindings and window dispatchers without a window act on
    nothing (`hl.dsp.window.close()` closes no window);
  - otherwise (Hyprland accepts a window focus) the front window of its workspace's active stage replaces it, with the
    keyboard (an on_demand layer such as the desktop loses it, as on any window focus); if no window may replace it
    (a `no_focus` rule, a modal child), there is no active window (behind a layer surface that holds the keyboard:
    cleared as above; else nothing is focused, as Hyprland does itself when its focused window's input gets blocked).
    Decision table: `gf::stages::activeWindowAction`, unit tests `StagesInput.HyprlandsActiveWindowNeverStaysOnAStripWindow`,
    `StagesInput.UnderAnExclusiveLayerTheActiveStripWindowIsOnlyCleared`;
  - the holder is Hyprland's focus surface, else the seat's keyboard focus, else the mapped Exclusive layer (Hyprland
    resets its focus surface when its focused window closes, `CWindow::onUnmap`). Hyprland's lists are only read;
  - under the session lock nothing is changed (the lock is never touched; Hyprland focuses nothing while locked); a focus
    requested meanwhile is deferred; after the unlock (Hyprland refocuses at the cursor only) a retarget runs, moves the
    active window off the strip and the deferred focus is tried. The session lock during a swap was not exercised.

## Acceptance criteria
| ID | Test | Level | Result (2026-10-18, nested Hyprland 0.56.2) |
|---|---|---|---|
| ST1-ST2 | unit `StagesFlag.ConfigAllowlist`, `Protocol.StagesFeaturesFollowAvailabilityAndTheFlag`; nested `stages.sh` checks 1-4 | L0 / L1 | PASS |
| ST3-ST5 | unit `StagesModel.*`, `StagesGeometry.*`; nested: grouping, sizes unchanged, thumbnails in tiles (terminal grey 88 % / 83 % of tiles 0 / 1, 0 % of empty tile 2), live (ticker tile 188 px changed in 0.6 s, idle tile 0 px) | L0 / L1 | PASS |
| ST6 | nested: click at b3's real place (covered by b3 only) → b3 gets nothing; keys go to the active stage | L1 | PASS |
| ST6 input guards (R13 review of 46b3e9b) | unit `StagesInput.*`, `DesktopFocusTarget.PointerFocusOnABlockedWindowIsStale`; nested `stages.sh` 5b: pointer resting on b3 (centre), stage c activated, click without motion → c3 gets it at the centre cell (`[<0;59;19M`), b3 nothing; 7b: pointer resting on b3, a new window of another app opens elsewhere, click without motion → b3 nothing | L0 / L1 | PASS (0.6.1-stages); the pre-fix build fbacf15 fails 5b (the hidden strip window got the click) |
| ST9 / ST15 keyboard after minimize | nested `stages.sh` 12b: e alone in the active stage, minimized → the next stage's front window (b3) is active and gets `m2`, e nothing; `minimize.sh stages` step 1: A alone in the active stage, minimized → O's stage active, O gets `mz` (then 20 minimize/restore rounds, mid-animation closes, all PASS) | L1 | PASS (0.6.1-stages); the pre-fix build types into the minimized window |
| ST10 window cycling | nested `stages.sh` 12c: 4 × `cycle_next` visit 3 distinct windows, all of the active stage; stages unchanged | L1 | PASS |
| ST10 focus reasons (R13 counter-review of 17208af) | unit `StagesInput.OnlyRealUserFocusIsAChoice`, `StagesInput.ADesktopSwitchRestoringItsLastWindowIsNotAChoice`; nested `stages.sh` 8e: a1 then c3 focused, Desktop 9, `hl.dsp.focus({ last = true })` (Hyprland: switch back, focus a1 with `WORKSPACE_CHANGE`) → back on the Desktop, a1 active and its stage forward; Desktop 9 and back → the active stage and window unchanged | L0 / L1 | PASS (0.6.2-stages). A restore of a strip window as a Desktop's last window needs a refused focus (session lock, `no_focus` rule, modal child) to arise: unit test only |
| ST23 Exclusive layer | nested `stages.sh` 8b: an Overlay Exclusive layer (fixture role `exclusive`) holds the keyboard (it got the keys), stage b activated, layer killed → b stays active, b3 gets `k8`, c3 (Hyprland's restored window) nothing | L1 | PASS (0.6.1-stages, 0.6.2-stages); the pre-fix build undid the swap (keys to the restored window) |
| ST24 active window (R13 counter-review of 17208af; R13 counter-review #3 of e9ebc7f) | unit `StagesInput.HyprlandsActiveWindowNeverStaysOnAStripWindow`, `StagesInput.UnderAnExclusiveLayerTheActiveStripWindowIsOnlyCleared`; nested `stages.sh` 8c: g (active, keyboard) and f (tile 0), Exclusive layer holds the keyboard (with two outputs the pointer is first moved to the other output, which Hyprland focuses), f's stage activated → Hyprland has no active window (never g), no `activewindowv2` naming f or g and no `focusedmon` event while the layer is up, the layer gets `uc`, no window a key; `hl.dsp.window.close()` closes no window (f and g mapped); layer killed → f gets `k9`, g nothing | L0 / L1 | PASS (0.6.3-stages, 1 and 2 outputs); the pre-fix build ffdef45 (0.6.2-stages) fails both checks (active window f, 2 `activewindowv2` and 4 `focusedmon` events under the layer: the focused monitor switched to GF-REF and back; `close()` closed f and g got `k9`) |
| ST23 Exclusive layer guard (R13 counter-review #3 of e9ebc7f) | unit `StagesInput.ADeferredFocusWaitsForTheLayerAndIsCheckedAgain`; nested `stages.sh` 8f: a capture window s on special workspace `gf-st` holds the keyboard (b active, c3 in the strip), Exclusive layer up, c's stage activated → the layer gets `vq`, no window gets a key, the special workspace stays open, no window or monitor focus event; layer killed → the special workspace stays open and s (Hyprland's restore) gets `k6`; special workspace closed → c3 gets `k7`, b3 nothing. 8g: b3 holds the keyboard, layer up, Desktop 9 shown under it, the stage of c (Desktop 2, not shown) activated → the Desktop stays 9, no Desktop, window or monitor focus event, the layer gets `wr`, no window a key; after the layer, back on Desktop 2 → c3 gets `k5`. 8h: polkit-like fixture (role `polkit`: full-output Overlay, Exclusive, password field) up, c's stage activated → the field gets all 6 keys of `secret`, no window a key, no active window (never b3), no focus event; Escape → keyboard None, then unmapped → c3 gets `k4` | L0 / L1 | PASS (0.6.3-stages, 1 and 2 outputs); the pre-fix build ffdef45 fails 8f (all three: c3 got `vq` under the layer, the special workspace was closed), 8g (Desktop switched 9 → 2, 4 focus or Desktop events under the layer) and 8h's first check (a window focus event under the dialog); 8h's second check passes on both builds |
| ST10 clicks / ST23 refocus at the cursor (R13 counter-review #4 of 0.6.3-stages) | unit `StagesInput.ARefocusAtTheCursorWithoutAPressIsNotAClick`, `APressIsAClickWhileHyprlandHandlesIt`, `APressBesideAnExclusiveLayerChoosesTheWindowPressed`, `ADeferredFocusFallsBackToTheFrontWindowNow`; nested `stages.sh` 8i, after a swap under an Exclusive layer (the outgoing stage's window was Hyprland's active window, so Hyprland refocuses at the cursor when the layer unmaps): (a) the pointer on an unrelated tiled window u → the swapped-in front window b3 gets `ia`, u nothing; (b) the pointer on the swapped-in stage's back window h1 (1200x900 behind h2 600x400) → h2 gets `ib` and is active, h1 nothing; (c) the pointer on empty desktop → c3 gets `ie`; (d) the remembered front window h2 closed while the layer was up, the pointer on empty desktop → h1 (now in front) gets `if` and is active; (e) a click on u beside the layer while it is up → u gets `ic` after the layer, c3 nothing; a click on u just after the layer (h2 active first) → u gets `id` | L0 / L1 | PASS (0.6.4-stages: headless pair GF-REF + GF-REF2 and GF-REF only); the pre-fix build 3a1a7a8 (0.6.3-stages) fails (a) (u got `ia`: the reviewer's repro), (b) (h1 got `ib`), (d) (no window got `if`, no active window) and the active-window part of (e) just after (h1, under the pointer, was active); (c) and (e) while up pass on both builds |
| ST24 rechecks and the event's front (R13 counter-review #4 of 0.6.3-stages) | unit `StagesEvents.TheFrontWindowAndItsApp`, `StagesEvents.ClientTextIsSanitized`; nested `stages.sh` 8c: a test window rule (opacity 0.5 while focused, classes `gf-stage-[fg]`) → g's opacity 0.5 while active, 1 after the plugin cleared it under the layer; 8i(a): under the layer after the swap Hyprland has no active window and the stages event names `front` b3 / `gf-stage-b` | L0 / L1 | PASS (0.6.4-stages); the pre-fix build keeps g at 0.5 and posts no `front` |
| ST6 menus (R13 counter-review of 17208af) | nested `stages.sh` 8d: an app window with a grabbing menu (fixture role `popup`), active stage: its menu gets the keys; the menu open, stage b activated → the menu closes before any key, `q2` reaches b3 in full, no key line at the app | L1 | PASS (0.6.2-stages); the pre-fix build fails (the menu stayed open, b3 got nothing) |
| ST7 | nested: tile press reaches the strip surface; activate → b active, c to tile 0; frame mid-swap differs from before (58890 px) and after (80955 px); afterwards b3 takes clicks and keys; sizes unchanged | L1 | PASS |
| ST8-ST11 | unit `StagesModel.*`; nested: move, merge, new stage, unknown stage, new window, close (keyboard back to b3), focus by dispatch | L0 / L1 | PASS |
| ST12-ST13 | nested: hidden 0 % grey in tiles, shown 89 %; titlebar drag of b3 over the strip → `overlap` true, dragged back → false | L1 | PASS |
| ST14-ST15 | nested: full screen on and off (strip back); minimize → `special:minimized`, gone from stages; restore → in the active stage | L1 | PASS |
| ST16 | code path (`overviewer::transforms`); no nested check | L0 | NOT VERIFIED in nested |
| ST17-ST18 | unit `StagesGeometry.TilesMustLieInsideTheStripSurfaceAndTheMonitor`; nested: `no-strip` without the surface; strip process exit → `interrupted`, 0 % grey, every window takes input; `op:on` again resumes with its stages | L0 / L1 | PASS |
| ST19 | nested: `scripts/nestctl plugin unload` during Stages → rc 0, Hyprland alive, `unavailable`, no thumbnail, b3 takes clicks, sizes unchanged; reload → `stages-available` without `stages` | L1 | PASS |
| ST20 | unit `StagesRequest.*`; nested: 6 invalid payloads → `invalid`; 1000 activate requests in one dispatch → 1 stages event, 1 `activewindowv2`, no socket2 subscriber dropped | L0 / L1 | PASS |
| ST21 | `nested-up.sh --no-plugin` (no `grassfield` capabilities at all); shell: `tests/unit/tst_stages.qml` (verb and config builders), toggle visible only with `stages-available` (`StagesToggle.visible`, `StagesLink.available`) | L0 / L1 | plugin side by construction; shell side NOT verified nested |
| ST22 | nested: switch to workspace 9 (no stage) and back: the same stage ids, thumbnails in the tiles | L1 | PASS |
| Multi-output | per-workspace model and per-monitor strips; only GF-REF had a strip in the run (WAYLAND-1 had no Stages windows) | L1 | NOT VERIFIED |

Run: `.dev/stages/run-20261018-141943-check` (**40/40 PASS**, plugin 0.6.0-stages, final build); perf
`.dev/stages/run-20261018-125334-perf`. Fix pass (plugin 0.6.1-stages, Hyprland v0.56.2 commit efb50993, 2026-10-18):
`.dev/stages/run-20261018-200428-check` **45/45 PASS**. The same three review sequences in a scratch probe (5b click
without motion after a swap, 8b swap under an Exclusive layer, 12b minimize the only window of the active stage):
fixed build `.dev/discriminate/run-202317` 3/3 PASS; pre-fix build fbacf15 (0.6.0-stages, loaded through
`scripts/nestctl plugin load` in the same nested session) `.dev/discriminate/run-202342` 3/3 FAIL (the strip window got
the click `[<0;84;28M`; after the layer closed the outgoing stage was active again and got `k8`; the minimized window got
`m2`). C1: `soak.sh 660 stages` PASS (below, "Fix pass").
Fix pass 2 (plugin 0.6.2-stages, Hyprland v0.56.2 commit efb50993, 2026-10-19): `.dev/stages/run-20261019-080913-check`
(GF-REF only) and `run-20261019-082610-check` (GF-REF and WAYLAND-1) **51/51 PASS**. The pre-fix build b7f0c3d
(0.6.1-stages, loaded through `scripts/nestctl plugin load` in the same session, the same script pointed at it)
`run-20261019-081839-check` 47/51: 8c FAIL twice (Hyprland's active window was g, in the strip; `hl.dsp.window.close()`
closed g and f survived: the reviewer's sequence), 8d FAIL (the menu stayed open over the swap; b3 got nothing of `q2`),
8e first check FAIL (no active window after `focus { last }`; that run's focus history differs because 8c closed the other
window, so it is not counted as evidence either way).

## Shell ↔ plugin contract (gfc/1, additive; the shell side is "Shell side" below)
1. **Detection.** `Capabilities.has("stages-available")` → show the Stages toggle in Quick Settings (off by default,
   persisted by the shell as Settings `windows.stages`). Without it (no plugin, mismatch, hooks failed, after the unload
   event with an empty list) hide the toggle and the strip. **Done (2026-10-23, owner decision D-4, audit ARCH-05):** the
   setting `windows.stages` (schema, defaults, `Settings.windowsStages`, the Settings app's store rules) and its push
   `hl.plugin.grassfield.config("stagesEnabled", "true"|"false")` from `shell/platform/Compositor.qml` (`pushStagesFlag`:
   when the setting changes and when `stages-available` appears, i.e. at every plugin load, which starts with the flag
   off; not on every capabilities event, because the plugin re-posts them when the flag changes); the verb `stages` is in
   the allowlist of `shell/platform/Minimized.js` and `Compositor.stages(request)` sends one operation (built by
   `Minimized.stagesCall`, only while `stages` is advertised). Still to build (shell): the Quick Settings and Settings
   toggles writing `windows.stages`, and the strip. `Capabilities.has("stages")` → the flag is on: map the strip and send
   `op:on`.
2. **Strip surfaces** (one per output; only outputs with a strip are managed):
   - input surface: namespace **`grassfield-stages`**, `WlrLayer.Top` (or Overlay), anchored to the left edge, keyboard
     `None`, **transparent where the thumbnails are** (the plugin draws them in the window layer, under Top). Its input
     region must cover every tile while the strip is shown (the plugin checks the corners and centre of each tile); when
     the strip is hidden, shrink the input region to a thin edge zone for the hover reveal and send `hidden:true`: for a
     strip sent with `hidden:true` the plugin checks the surface, its layer and that the tiles lie on the monitor, not the
     input region (core `stripAccepted`, `tilesInMonitor`; tile x and y are also bounded at parse, kMaxTileCoord;
     2026-10-23), also for the first `op:on`. Before a reveal (`hidden:false`) grow the input region over the tiles
     first: the reveal is checked like any shown strip (else `no-strip`).
   - optional plates (tile backgrounds, hover highlight): a separate surface on `WlrLayer.Bottom` (below windows, like the
     overview backdrop). App icons and labels may go on the Top surface outside the thumbnail rects.
3. **Turn on / update** (after the strip maps): `hl.plugin.grassfield.stages("<json>")` through `Hyprland.dispatch`,
   guarded like the other verbs (add `stages` to `isPluginVerb`), built only from validated pieces and quoted as a Lua
   string:
   `{"op":"on","durationMs":350,"curve":[0.2,0,0,1],"strips":[{"monitor":"GF-REF","hidden":false,"tiles":[{"x":…,"y":…,"w":…,"h":…},…]}]}`
   - Tiles in layout coordinates (global logical, like `hyprctl clients`), slot 0 first (top). Limits (else
     `reason:"invalid"`): object ≤ 8 KiB; `op` required; `durationMs` integer 0..2000 (required for on; 0 = Reduce
     Motion); `curve` 4 numbers, x in [0,1], y in [-1,2]; at most 8 strips with distinct monitor names
     (`[A-Za-z0-9._-]`, ≤ 64 bytes); 1..8 tiles per strip, sides 16..800 px, finite, not overlapping. Known keys that do
     not belong to the op are refused; unknown keys are skipped.
   - `op:on` again while on updates the strips, timing and `hidden` flags (no regrouping). Send it on every geometry
     change of the strip (output added or moved, Dock or menu bar size) and for the hover reveal (`hidden:false`).
   - `{"op":"off","durationMs":350}` ends Stages (animated back). Turning the flag off also ends it (at once).
4. **Events** (ADR-0007 amendment 2026-10-24: Hyprland cuts socket2 events at 1024 bytes, and this state grows with every
   window): the event is a change notice, `grassfield>>{"v":"gfc/1","type":"stages","gen":N,"on":bool}` plus `"reason"`, and
   the state below, with the same `gen`, is the reply of `hyprctl grassfield-stages` (`shell/platform/StagesLink.qml`, the
   one consumer, reads the event as a notice only and fetches the state on each notice with `on:true` while Stages is
   active; a notice with `on:false` needs no fetch. One fetch at a time, notices during it ask one more; a state older than
   the one shown is dropped; a failed or timed-out (2 s) fetch is retried three times, 200, 400 and 800 ms later, then no
   state is shown and the strip hides rather than show a stale state as current; and whatever the retries, a notice that
   no successful fetch has answered within 3 s also means no state (a stream of notices restarts the retries, never that
   clock), unless a fetch is under way: its answer or its 2-s deadline decides (slow fetches never make the strip
   flicker; at worst 5 s). Pure logic `StagesState.js`, tests `tests/unit/tst_stages.qml`). State: `{"v":"gfc/1","type":"stages","gen":N,"on":bool,"monitors":[{"monitor":"GF-REF","workspace":2,"active":5,"hidden":false,"overlap":false,"front":{"address":"<hex, no 0x>","app":"<class>"},"stages":[{"id":5,"slot":-1,"windows":[{"address":"<hex, no 0x>"}]},{"id":7,"slot":0,"windows":[{"address":"…","x":…,"y":…,"w":…,"h":…}]}]}]}`
   plus `"reason":"invalid|disabled|no-strip|unknown|unavailable|interrupted"`. Notices are coalesced (latest wins) and
   carry no state: each says "fetch the state" (or, with `on:false`, that Stages is off); the fetched reply is the
   state. Per monitor with a strip: the workspace shown there, the active stage id, the stages in recency order (active
   first, `slot` = tile index, −1 for the active stage and for stages beyond the tiles), each stage's windows back to
   front, and for windows in a tile the rect where their **surface box** is drawn (their 32 px titlebar band is drawn
   above it, scaled), always at the shown position (also while `hidden`). `front` (added in 0.6.4-stages, additive;
   absent when the shown Desktop has no stage): the front window of the active stage and its app (the window's class, the
   Wayland app id; client text sanitized to valid UTF-8, at most 256 bytes), re-posted when it changes. It is the window
   that holds the keyboard, or takes it when a layer surface lets go: while an Exclusive layer holds the keyboard after a
   swap Hyprland has **no active window** (ST24: no `activewindow`, no foreign-toplevel `activated`), so the menu bar
   should name `front.app` while Stages is on and Hyprland names no window (macOS keeps naming the frontmost app); the
   Desktop and Search keep their own names when they hold the keyboard. Shell side (menubar.md, `shell/platform/StagesFront.js`, given each fetched state by StagesLink through `Compositor.applyStagesState`: the event carries no `front`): used only while Stages is on (`on:true`), Hyprland names no window and the front window still exists; display only (window commands greyed); cleared by an active window, `on:false`, plugin gone, the state unknown (fetch given up) or the window closing. `disabled`: flag off; `no-strip`: the strip
   surface is missing, not Top/Overlay, or does not cover the tiles with its box and input region; `unknown`: the stage
   or window no longer exists (refresh from the next event); `interrupted`: the strip surface went away or the monitors
   changed: re-send `op:on`; `unavailable`: the plugin unloads (hide the strip).
5. **Clicks and drags** (the shell maps them through its own tiles and the event's rects; windows never get the strip's
   input):
   - click on tile k → `{"op":"activate","stage":<id of the stage with slot k>}`; Shift-click →
     `{"op":"merge","stage":<id>}`;
   - drag a thumbnail (hit-test the tile's windows front to back, i.e. the list reversed) and drop it on the stage area →
     `{"op":"move","address":"0x<hex>","stage":<active id>}`; drop on another tile → that tile's stage id;
   - drag a window of the stage to the strip: **the plugin does it** (2026-10-23; the shell cannot see a titlebar drag).
     A titlebar drag of a window of the active stage released on the strip of its output (left of the tiles' right edge
     plus 16 px, any height; core `inDropZone`, `dropAction`) makes it a stage of its own, as `{"op":"move",…,
     "stage":"new"}` would: drawn into its tile from where it was dropped, its real place back to where it was before
     the drag, the active stage's front window keeping the keyboard, then the usual `stages` event. Not when the release
     tiles the window (window tiling at the screen edge wins), the window is alone in its stage, or it belongs to another
     output's Desktop, or the strip is hidden (the drop target is the visible strip: reveal it at the edge first). The
     shell may still send `move "new"` itself (a context action, a key binding);
   - activating an app from the Dock or Search needs nothing special: Hyprland's focus of a strip window brings its stage
     forward (ST10).
6. **Strip visibility.** Hide the strip (slide out, `hidden:true`, input region to the edge zone) while `overlap` is true;
   reveal it on hover at the left edge (`hidden:false`) and hide it again when the pointer leaves. Prototype limit: a strip
   revealed over an overlapping window draws its thumbnails under that window (Hyprland's stacking order is kept), so
   keep the strip hidden while `overlap` is true unless the user is at the edge.
7. **Restart.** After each capabilities event with `stages`, re-send the flag and `op:on`; the plugin keeps its model
   while it stays loaded (a strip that went away showed the windows normally until then).
8. **Overview.** Include strip windows in the overview layout like any window (they are eligible); clicking one there
   focuses it, which brings its stage forward (ST10).

## Spike results (2026-10-18, nested Hyprland 0.56.2 commit efb50993, GF-REF 1920x1080 scale 1; parent GPU path, indication only)
Sources of Hyprland v0.56.2 read as data (`desktop/state/ViewHitTester.cpp`, `FocusState.cpp`, `view/Window.cpp`,
`render/Renderer.cpp`, `render/ElementRenderer.cpp`, `managers/input/InputManager.cpp`, `desktop/state/WindowState.cpp`,
`output/Monitor.cpp`); every API used was checked in `/usr/include/hyprland` and the exported symbols
(`nm -D /usr/bin/Hyprland`: `CWindow::setInputBlocked`, `CWindow::acceptsInput`, `CEventLoopManager::doLater`).

**Model location: the plugin** (see ADR-0013). Window membership must change synchronously with Hyprland (a window must
not flash in the centre before the shell reassigns it; a closed window's stage must update before Hyprland picks its
successor), the input block is a safety property that must not depend on the shell staying alive, and unload must be able
to undo everything at once. The shell owns the presentation: tile geometry, chrome, hover, drag and drop, the setting.

**Mechanism candidates for the windows of inactive stages:**

| Candidate | Live thumbnail | Input at real place | Client untouched | Verdict |
|---|---|---|---|---|
| Same workspace + `IWindowTransformer` + plugin input block reason | yes (rendered every frame with damage; frame callbacks keep flowing) | blocked: `CViewHitTester::windowAt` skips windows whose `acceptsInput()` is false | yes (never moved, resized or configured) | **chosen** |
| Special workspace (`special:…`) + snapshots | no: Hyprland sends frame callbacks only to views of a monitor's active (special) workspace (`sendFrameEventsToWorkspace`), so parked clients stop presenting; a live thumbnail would need the plugin to render surface trees itself | none (not on a visible workspace) | moved to another workspace (movewindow events, workspace rules, the shell's Dock sees it) | rejected (frozen, more code), but cheapest |
| `CWindow::setHidden` | no: hidden windows are not rendered, so the transformer is never called | none | yes | rejected |
| Real geometry moved off every monitor | no: `shouldRenderWindow` needs the window on a monitor | none | position changes (XWayland clients see it) | rejected |
| Raising strip windows above the active stage (`CWindowState::raise`) | – | – | – | not used: it also sets `m_allowedOverFullscreen` (drawn over full-screen windows) |

**CPU** (`tests/compositor/stages.sh perf 30`: 9 foot windows, 3 apps × 3; % of one core from `/proc/<pid>/stat`, 30 s
per phase; ticker = one terminal printing 10 lines/s; run `.dev/stages/run-20261018-125334-perf`, on the build before the request coalescing and the hidden-workspace fix, which do not change the per-frame work):

| Phase | nested Hyprland | grassfield-shell | Hyprland RSS |
|---|---|---|---|
| Stages off, idle | 0.2 % | 1.0 % | 162 MB |
| Stages off, ticker shown | 3.2 % | 0.1 % | 162 MB |
| Stages on (2 strip stages = 6 windows drawn live in tiles), idle | 0.1 % | 0.2 % | 162 MB |
| Stages on, ticker in a strip tile (live thumbnail) | 4.4 % | 0.1 % | 162 MB |
| Stages on, ticker in the active stage | 4.3 % | 0.1 % | 162 MB |
| Stages on, a swap every second (350 ms animations) | 12.0 % | 2.1 % | 162 MB |
| special workspace alternative: 6 windows parked, idle | 0.1 % | 0.1 % | 162 MB |
| special workspace alternative: ticker parked (not rendered: frozen) | 0.0 % | 0.1 % | 162 MB |

An idle strip costs nothing (no damage, no frame). Live thumbnails cost ~1.2 points of one core per 10 fps content
change in this environment (every frame with damage redraws the 6 transformed windows through Hyprland's work buffers),
the price of liveness the special-workspace alternative avoids by freezing. Swaps cost what the overview's animation
costs (12.2 % for continuous open/close there).

**Swap animation.** One track per window, with its own clock (`durationMs` and curve of the latest `op:on`, core
`gf::motion`, compositor/src/core/Motion.hpp): each window goes from where it is drawn now (its tile, or its live box) to
its target (its new tile, or its live box); windows shown normally again lose their transformer when their own track
ends; a 150 ms watchdog completes the tracks when no monitor renders. Since the audit fixes of 2026-11 (WM-03, WM-16,
WM-01 and the design notes):
- **Retargeting keeps velocity and clocks.** A sync recomputes every target; a window whose target did not change keeps
  its track (its clock and curve go on: a window opening elsewhere 100 ms into a swap no longer stops and restarts every
  thumbnail), and a window whose target changed mid-flight continues from the box on screen with the velocity it has
  there (a cubic Hermite term that carries it and fades out at the end), its duration scaled by the share of the way
  left (at least 30 %). A sync that changed nothing starts no animation and posts nothing: a notice is posted only when
  the state differs from the last one (an `op:on` is always answered). Window events of a window that is neither managed
  nor manageable, on a Desktop without stages, no longer schedule a sync.
- **A Desktop shown for the first time** since Stages turned on has its strip windows drawn in their tiles at once, from
  `workspace.active`, before the first frame of the switch (no animation; macOS shows a Space's strip already staged),
  instead of sliding in at their real places and flying to the strip after the deferred sync.
- **One ticker per monitor.** A window is stepped by the `render.preChecks` of the monitor that draws it, once per frame
  cycle (with two outputs every window was stepped and damaged twice per cycle); a settled track takes its final box on
  any monitor's frame.
- **Damage only what changed.** In `render.pre` a thumbnail is added to a frame's damage only when that frame's damage
  (the monitor's damage ring before the plugin adds to it) touches the window's real place (a commit, a decoration, a
  move: where Hyprland damages it) or its drawn box changed; a blinking cursor in the active stage no longer repaints the
  whole strip. The strip-overlap check runs only when the frame's damage touches the strip band, and computes a window's
  full box only for windows near it. No allocation per window per frame (core `damageStep` returns at most two boxes in
  place).
- **No whole-buffer clear per thumbnail.** The transforms draw into output buffers the plugin keeps while windows are
  transformed (taken from the monitor's pool, at most two per monitor, dropped when the monitor's buffers change and
  released when nothing is transformed); the plugin knows the box it last drew in each, so a frame clears that box and
  the new one, not the whole monitor-sized buffer, and the draw is clipped to the window's fitted box. A thumbnail off
  the monitor (a hidden strip) draws nothing and clears nothing. Hyprland's own work buffer for the window's pass is
  still cleared and rendered by Hyprland every frame (0.56.2 culls no transformed window): what remains is Hyprland's.

**Findings during the prototype runs** (nested, fixed before the final run):
1. A flood of 1000 `activate` requests in one Lua dispatch, applied one by one, made ~1000 real focus changes: Hyprland
   posted 967 `activewindowv2` events within one second and dropped the shell's socket2 connection
   (`Socket2 fd 57 overflowed event queue, removing`); the shell then missed `minimize-request` (`minimize.sh` FAIL).
   Requests are now applied once per event loop pass (ST20): 1 event, 1 `activewindowv2`, no subscriber dropped.
2. A reload after an unload kept the flag on: the library can stay mapped between loads (FR23 pinning), so its
   function-static state survives; `start()` and `stop()` now reset the flag and the model.
3. (self-review, before the final run) A workspace switched away was retargeted as "no strip, shown normally": its strip
   windows would have animated back to their real places during the workspace slide and flown back on return. A
   workspace shown on no monitor now keeps its windows as they are drawn (ST22).

4. (R13 review of 46b3e9b, fixed in 0.6.1-stages) A strip window still got clicks through Hyprland's stale pointer focus
   (pointer focus changes on pointer motion only); minimizing the only window of the active stage left the keyboard on
   the minimized window (Hyprland cannot pick a blocked successor); a swap made under an Exclusive layer was undone when
   the layer closed (Hyprland restored its last window, a strip window by then, with reason `FFM`, which was read as a
   user choice); the no-buffer fallback of the shared transform drew a strip window at its real place. Fixes: ST6 input
   guards, ST9 keyboard rule, ST10 `FFM` not a choice, ST23, ST5 (nothing drawn without a work buffer).
5. (nested harness, found during the fix pass) No pointer or keyboard device persists in the nested session between
   `scripts/dev/pointer.sh` / `keys.sh` runs (each creates and destroys a virtual device): Hyprland then refuses pointer
   focus changes ("BUG THIS: setPointerFocus without a valid mouse set"), so the refresh at swap time is skipped and the
   guard before the next button does the work (seen in a run: "pointer press while the pointer focus was strip window
   …: pointer focus refreshed first"). The guard's enter and motion get their own pointer frame (without it, foot read
   the click at cell 1;1). With a real pointer device the refresh happens at swap time.
6. (R13 counter-review of 17208af, fixed in 0.6.2-stages) A swap made under an Exclusive layer left Hyprland's active
   window on the outgoing window, hidden in the strip: window bindings, window dispatchers without a window and the menu
   bar acted on it (`hl.dsp.window.close()` closed it). A menu of a window going to the strip kept Hyprland's popup grab,
   which refuses the keyboard to the incoming window: the first key cleared the focus and 1-2 keys were lost (the popup
   exception of ST6 never applied: the grab keeps the keyboard on the toplevel). Every focus reason that was not a close
   or `FFM` counted as a user choice. Fixes: ST24, ST6 menus, ST10.
7. (nested harness, found during fix pass 2) The capability churn of finding 5 also loses events on a loaded host: a
   client binds its new `wl_pointer` / `wl_keyboard` only after the seat capability comes back, so the first key of a
   `keys.sh` run can be lost and a click can arrive after an enter at the stale position (-1,-1) (Quickshell then drops
   the press: Dock tiles, the strip stand-in, menus); Hyprland's seat keyboard focus can also lag behind its focus surface
   (each new virtual keyboard gets the focus surface). `stages.sh` waits 150 ms after each new keyboard (`wtype -s`) and
   before motionless clicks, and moves twice before clicks on Quickshell surfaces; `minimize.sh` keeps one waiting
   pointer and one waiting keyboard for the whole run (both capabilities stay, as in a real session).
8. (R13 counter-review #3 of e9ebc7f, fixed in 0.6.3-stages) The 0.6.2 fix made the incoming front window active behind
   an Exclusive layer by setting Hyprland's Exclusive-layer list aside for one `fullWindowFocus` call. Hyprland's guard was
   then off for that call's side paths too: with a special workspace open, `rawWindowFocus` closed it and the nested focus
   gave the window the keyboard (the next keys reached the window, not the layer; Hyprland log "Set keyboard focus to
   surface … [Window x]"); with the window on a Desktop not shown, Hyprland switched Desktops and the keyboard went to the
   window for a moment; the focused monitor switched for a moment; listeners saw a window focus while the layer was up.
   A polkit dialog is such a layer. Fix: the plugin never focuses a window while Hyprland refuses one; it clears a strip
   window from Hyprland's active window and defers the focus until the layer releases the keyboard (ST23, ST24).
9. (R13 counter-review #4 of 0.6.3-stages, fixed in 0.6.4-stages) After a swap under an Exclusive layer Hyprland has no
   active window, so when the layer unmaps `CInputManager::refocusLastWindow` falls back to `refocus()`, a refocus at the
   cursor that Hyprland reports as `FOCUS_REASON_CLICK`; the plugin mapped `CLICK` to a user choice, dropped the deferred
   focus and the window under the pointer kept the keyboard (an unrelated window; or the swapped-in stage's back window,
   which `onActive` also raised to the front). `stages.sh` 8b/8h missed it because the pointer rested on the target. Also:
   with the remembered window closed under the layer and the pointer over empty space, the keyboard ended on nothing;
   clearing the active window skipped Hyprland's focus rechecks (window rules matching on focus, idle inhibitors). Fixes:
   ST10 clicks (a press must cause a `CLICK`), ST23 (Hyprland's own pick neither drops nor raises; fallback to the
   Desktop's front window), ST24 (rechecks), contract item 4 (`front`).

**Fix pass** (2026-10-18, plugin 0.6.1-stages): `tests/compositor/soak.sh 660 stages` → PASS (log
`.dev/soak-20261018-201156.log`: 372 rounds, 74 moves of a window into a new strip stage, 52 tile-0 activations, 1393
stages events, 93 drags, 47 abandoned drags, 94 zoom pairs, 46 cancels, 46 closes, 46 minimize pairs all animated with 0
skipped; RSS 152.5 → 160.8 MB, flat from round 100; no core dump; 0 grassfield exceptions; 226 seat warnings as designed).
Every Dock click of the run landed on the minimized foot window's tile: the tile is clicked only after the window was
seen moving to `special:minimized`, the Dock held one pinned app (foot) and the capture `.dev/soak-dock-1792347116.png`
shows the clicked point (966,1035) on the minimized foot tile, between the separator and the Trash.

**Fix pass 2** (2026-10-19, plugin 0.6.2-stages): `tests/compositor/soak.sh 360 stages` → PASS (log
`.dev/soak-20261019-083846.log`: 166 rounds, 33 moves into new strip stages, 23 swaps, 594 stages events, 17 minimize
pairs all animated; RSS 151.4 → 161.0 MB; no core dump; 0 grassfield exceptions). A first attempt on another instance
ended at round 20 with the nested Hyprland gone without a core dump, crash report or log line (cause not found, see
`docs/specs/compositor.md`). `minimize.sh stages` PASS, `desktop_focus.sh` 26/26, `overview.sh check` 32/32; C2 without
the plugin: no `grassfield` request or verb, the shell in degraded mode.

**Fix pass 3** (2026-10-19, plugin 0.6.3-stages, Hyprland v0.56.2 commit efb50993; R13 counter-review #3 of e9ebc7f):
`stages.sh check` **58/58 PASS** on two outputs (`.dev/stages/run-20261019-125844-check`, `run-20261019-130423-check`,
and on the final 0.6.3-stages build `run-20261019-140152-check`) and with GF-REF only (WAYLAND-1 disabled,
`run-20261019-131100-check`). The pre-fix build ffdef45 (0.6.2-stages, loaded through `scripts/nestctl plugin load` in the
same session, `stages.sh check --plugin <it>`) **51/58** (`run-20261019-130127-check`, `run-20261019-130612-check`): 8c
both, 8f all three (c3 got `vq` typed into the layer, the special workspace was closed), 8g (Desktop switched 9 → 2, 4
focus or Desktop events under the layer), 8h's first check (a window focus under the dialog). `minimize.sh stages` PASS
twice, `desktop_focus.sh` 26/26, `overview.sh check` 32/32. C1: `soak.sh 1260 stages` PASS and `soak.sh 1260` (Stages off)
PASS, each on a fresh supervised instance (see `docs/specs/compositor.md`, "Nested Hyprland losses"). C2 without the
plugin: `hyprctl grassfield` "unknown request", `hl.plugin.grassfield.stages(...)` errors (nil `grassfield`), 0
`[grassfield]` lines, shell "no compositor plugin reply, running in degraded mode".

**Fix pass 4** (2026-10-19, plugin 0.6.4-stages, Hyprland v0.56.2 commit efb50993; R13 counter-review #4 of 0.6.3-stages):
`stages.sh check` **66/66 PASS** on the headless pair GF-REF + GF-REF2 (`.dev/stages/run-20261019-165827-check`) and on
GF-REF only (`run-20261019-170037-check`), WAYLAND-1 disabled in both (as `tests/shell/overview_two_outputs.sh` does: the
nested window is resized and hovered by the owner's session); an earlier run with GF-REF + WAYLAND-1 also 66/66
(`run-20261019-160117-check`, before 8i(b) focused b3 explicitly). The pre-fix build 3a1a7a8 (0.6.3-stages, loaded through
`scripts/nestctl plugin load` in the same session, `stages.sh check --plugin <it>`) **60/66** (`run-20261019-170310-check`):
8c rule (g stays at opacity 0.5), 8i(a) (u, under the pointer, got `ia`: the reviewer's repro; no `front` in the event),
8i(b) (h1, the back window under the pointer, got `ib`), 8i(d) (no window got `if`, no active window), 8i(e) just after
(h1 was active after the layer). `minimize.sh` PASS and `minimize.sh 20 stages` PASS (`.dev/minimize/run-20261019-170851`,
`run-20261019-170925`), `desktop_focus.sh` 26/26, `overview.sh check` 32/32 on the headless pair (it named WAYLAND-1 for its
two-output case and failed with "no WAYLAND-1" there: 29/30, test fixed). C2 without the plugin: `hyprctl grassfield`
"unknown request", "no plugins loaded", `hl.plugin.grassfield.stages(...)` errors (nil `grassfield`), 0 `[grassfield]`
lines, shell "no compositor plugin reply, running in degraded mode". After the merge with main (cursor-refresh,
plugin 0.7.1-stages, features now include `cursor-refresh`): `stages.sh check` **66/66** on the headless pair
(`run-20261019-174116-check`) and on GF-REF only (`run-20261019-174322-check`); `minimize.sh` and `minimize.sh 20 stages`
PASS (`.dev/minimize/run-20261019-174720`, `run-20261019-174756`), each Dock click on the rectangle the shell sent for that
window (the follow log is now line-buffered; the Dock rectangle line has its own log budget, see C1 below).
C1: `soak.sh 1260 stages` on the merged build, GF-REF only, on a fresh instance run under a dev-only supervisor (scratch,
not tracked: child subreaper that runs `nested-up.sh` and records Hyprland's wait status) → **PASS** (log
`.dev/soak-20261019-174857.log`: 735 rounds, 147 moves into new strip stages, 104 swaps, 2651 stages events, 92 minimize
pairs, 92 `minimized` + 92 `restored` events, every Dock click on the rectangle the shell sent, 0 rejected rectangles;
RSS 149.7 → 159.3 MB, sampled max 165.0 MB; fds max 197, 105 before the stop; no core dump; 0 grassfield exceptions);
the nested Hyprland exited only at `nested-down.sh`, wait status 0. An earlier 1260 s run on 0.6.4-stages
(`.dev/soak-20261019-171247.log`, 721 rounds) also PASSed (exit 0 at `nested-down.sh`) but clicked no Dock tile: the
shared request log budget had held back 88 of the 90 Dock rectangle lines (fixed with the line's own budget).
Environment (recorded for the next runs; cause not established, the plugin's drawing is unchanged in this pass and the
kernel logged no such line during pass 3): while three other worktrees' nested sessions ran on the same
Intel UHD GPU, runs with WAYLAND-1 enabled were slow and erratic (hyprctl "IPC didn't respond in time", windows opened on
the wrong output, blank `grim` captures), the kernel logged i915 "Fence expiration time out" for the nested Hyprland from
16:10 (none earlier that day), and one session ended at 16:44:01 with "GPU HANG … in Hyprland[2544045]", context reset,
and Hyprland's assertion `GL_GUILTY_CONTEXT_RESET` (OpenGL.cpp:729, SIGABRT, crash report and core dump present): those
runs are not counted.

**Interactions** (ST13-ST16): minimize, full screen, overlap and desktop focus checked in nested as above; the overview
code path makes strip windows draw from their real places in an open overview (they jump from their tile to the centre
when the overview opens: prototype limit); desktop focus is unaffected (a press on a thumbnail is a press on a
`grassfield-*` layer; strip windows are never press targets because the hit test skips them).

## Known limitations and risks
- Popups of strip windows are not transformed: a menu that holds a popup grab closes when its window goes to the strip
  (ST6), but a popup without a grab (a tooltip) stays drawn at its real place until the app closes it (it takes no input:
  ST6 guards).
- While an Exclusive layer holds the keyboard after a swap, Hyprland has no active window (ST24): window key bindings and
  dispatchers without a window act on nothing until the layer releases the keyboard; the menu bar names the app of the
  Stages state's `front` (contract item 4; shell side: StagesLink fetches the state and hands it to Compositor,
  `shell/platform/StagesFront.js`). The
  plugin reads (never changes) Hyprland's Exclusive-layer list and lock state to know when Hyprland refuses window focus,
  and relies on the order of `CLayerSurface::onUnmap` (the `layer.closed` event before Hyprland's refocus) and on
  `CFocusState::resetWindowFocus`: re-verify `CFocusState::rawWindowFocus`, `CInputManager::{m_exclusiveLSes,
  refocusLastWindow}` and `CLayerSurface::{onUnmap, onCommit}` on every Hyprland update. Under the session lock nothing is
  changed until the unlock (not exercised).
- `WORKSPACE_CHANGE` is classified with the plugin's own record of each workspace's last focused window (ST10); a restore
  of a strip window as a Desktop's last window only arises after a refused focus (session lock, `no_focus` rule, modal
  child) and is covered by unit tests only.
- Shell side (for the strip implementation): the menu bar falls back to the most recent visible window of the app when no
  toplevel is activated (`AppMenus.qml`), which can be a strip window; with Stages on it should prefer the active stage
  (the event's `front`).
- A click beside an Exclusive layer while it is up wins over a swap made before it (ST10 clicks), but Hyprland only
  refocuses at the cursor after the layer when it has no active window; with an active window it restores that one
  (`FFM`) and the click is forgotten, as without Stages. Touch and tablet presses count only without an Exclusive layer.
- Touch: a touch held when its window goes to the strip keeps its target until it ends (ST6); touch is not exercised (no
  touch device in the nested session).
- ALT+TAB (Hyprland's `cycle_next`) does not reach strip stages until the Grassfield app switcher exists (ST10 decision).
- The session lock during a swap is not exercised (ST23 covers Exclusive layers).
- A strip revealed over an overlapping window draws its thumbnails under it (contract item 6).
- The input block uses an unused bit of Hyprland's `eWindowInputBlockReason` (`1 << 6`): internal API, re-verify on every
  Hyprland update (the ABI hash check prevents running against another build).
- Separate Lua dispatches, each activating a stage, cause one focus change each, like Hyprland's own `hl.dsp.focus`.
- No persistence: stages are rebuilt from the windows when Stages turns on; a shell restart shows the windows normally
  until it sends `op:on` again; a plugin reload starts with the flag off.
- Multiple outputs, fractional scales and rotated outputs are not verified; the strip of a monitor whose workspace shows
  a full-screen window is hidden.
- The shell strip, Quick Settings toggle and Settings entry are implemented ("Shell side"); F1 visual fidelity not assessed.

## Shell side (1.0 scope; macOS Stage Manager model; decided 2026-10-23, GF-AUDIT-001 C-STG-1 / C-X-13)

Files: `shell/platform/StagesLink.qml` (capability, setting, events, verb; the only compositor access), `shell/platform/StagesState.js`
(event parser), `shell/platform/Minimized.js` (`stages` verb, `stagesCall` and `Compositor.stages(request)` from the compositor enable path),
`shell/stages/Stages.qml` (strip surface per output), `shell/stages/Layout.js` (geometry, requests), `shell/overlay/controlcenter/StagesToggle.qml`,
`apps/settings/qml/DesktopPage.qml` (Settings > Desktop & Dock > Stages). Tokens: `stages.*`. Tests: `tests/unit/tst_stages.qml`,
`tests/visual/scenarios/stages.sh`.

- **Name.** UI name "Stages" (fr "Stages"); the Apple name appears in no string (`check-i18n`, grep of `shell/ apps/ translations/`).
- **Setting.** `windows.stages` in grassfield.json (schema, defaults `false`, Settings app Store rules). Off by default (C-X-13).
  The Quick Settings tile (2x1 beside Airplane Mode; on its own row while Now Playing takes that slot) and the Settings row exist
  only for the tile: the tile is hidden unless `Capabilities.has("stages-available")`; the Settings app cannot see capabilities, so its
  row is always listed with a footnote that the compositor extension is needed.
- **Flag push.** `Compositor.pushStagesFlag` (compositor enable path, contract 1) sends `config("stagesEnabled", ...)` when the setting changes and when `stages-available` appears, not on every capabilities event. Without `stages-available` nothing is sent (REQ-COMP-DEG-d10); flag off makes the plugin answer `disabled`. The strip sends its operations through `Compositor.stages(request)` (only while `stages` is advertised).
- **Strip.** One surface per output, namespace `grassfield-stages` (layer rule `gf-shell-blur` lists it), Top layer, anchored top-left with
  explicit margins (`ExclusionMode.Ignore`), keyboard `None`, transparent over the plugin's thumbnails. Tiles 160x120, gap 24, centred
  vertically below the menu bar (macOS centres the strip), left of nothing but the Dock when the Dock is on the left (inset =
  `Settings.dockFootprint.left`). Tile count = strip stages, capped by what fits (1..8). Drawn by the shell: a frosted app icon badge at
  the tile's bottom-left (material blurred by the layer rule) and a hover / drop-target outline; never a fake blur.
- **op:on.** One request for all outputs, sent debounced (`stages.resendDebounceMs`) only when tiles, `hidden` or timing change
  (`signature`), after `StagesLink.resumed` (capabilities event with `stages`: contract 7) and again after `no-strip` or `interrupted`
  (at most `stages.retryMax` times, `stages.retryMs` apart). Duration `motion.slow`, curve `motion.curveStandard`; Reduce Motion: 0 ms.
- **Clicks.** Click on a tile: `activate`; Shift-click: `merge`. Drag a tile (threshold `stages.dragThreshold`): the pointer stays with
  the strip surface, so the drop is resolved from surface coordinates: right of the surface = the stage area (`move` of the tile's front
  window into the active stage), on another tile = that tile's stage, anywhere else nothing. The thumbnail cannot follow the pointer
  (the plugin draws it in the window layer): a badge ghost follows it and the target tile gets the outline.
- **Overlap and reveal.** `overlap` true: `hidden:true`, input region shrinks to the thin edge zone (`stages.revealZone`); the pointer
  resting there for `stages.revealDwell` reveals the strip (`hidden:false`); leaving it for `stages.hideGrace` hides it again. With no
  strip stage (only the active one) the strip is hidden (macOS shows no strip then). The input region is never empty while Stages is on.
- **Keyboard and assistive tech.** The strip takes no keyboard (contract). Access without the pointer: the app switcher (SUPER+TAB),
  the Dock and Search focus an app's window, which brings its stage forward (ST10); `qs ipc call stages activate <n>` (n-th strip stage
  of the focused output, for key bindings and scripts) and `qs ipc call stages newStage` (focused window becomes its own stage);
  the Quick Settings tile is a normal keyboard-reachable switch. Tiles expose `Accessible.Button` with the app name and window count
  and a press action. Bindings (`config/hypr/grassfield/bindings.lua`): SUPER+ALT+1..4 = `stages activate n`, SUPER+ALT+S = `stages newStage`; `stages status` and `enable` are dev hooks (IPC inventory, `docs/specs/security.md`).
- **Final contract (plugin 0.13.0-audit).** Tiles are always on the monitor (a hidden strip is checked for surface, layer and tiles on the monitor, not input region); a reveal grows the input region over the tiles at once and sends `op:on` (`hidden:false`) after the debounce, so the plugin never sees a shown strip without its region. A window dragged by its titlebar onto the visible strip becomes its own stage in the plugin; the shell has nothing to do for it. The hidden strip has no drop zone: the edge zone only reveals.
- **Overview (REQ-STG-SC-d8).** The overview lists strip windows like any window (nothing in `shell/overview` excludes them); clicking one
  focuses it, which brings its stage forward (ST10). Not verified nested (ST16).

## Plugin answers to the shell's work items (2026-10-23, plugin 0.13.0-audit)

The shell agent's "Shell side" section (branch of the strip) lists three plugin work items; answers, with unit tests in
`compositor/tests/StagesTest.cpp` (`StagesShellItems.*`):
1. **Drag a window to the strip**: done in the plugin (contract 5 above). The titlebar release calls
   `gf::stager::dropOnStrip` after window tiling; core `inDropZone` (the strip of the release output: left of its tiles'
   right edge plus `kStripDropMargin` 16 px, the whole height) and `dropAction` (Stages on, a strip there, a window of the
   active stage of the Desktop shown there, not alone in it, the release not tiling) decide; the model's
   `moveWindow(window, new)` is what `op move "new"` runs. Log line: `stages: window <hex> dropped on the strip of <output>:
   a stage of its own`. The shell only has to show the target outline if it wants (it sees the result in the next
   `stages` event). NOT VERIFIED nested.
2. **`op:on` with `hidden:true` and only the edge zone as input region**: it was refused (`no-strip`): the input
   coverage was checked whatever `hidden` said. Fixed: a hidden strip is checked for its surface, layer and tiles on the
   monitor, not its input region (core
   `stripAccepted`, contract 2 above); a reveal (`hidden:false`) is checked over every tile, so grow the input region
   first. NOT VERIFIED nested.
3. **Updates with fewer tiles**: smooth. An `op:on` while on replaces the strips and runs one retarget with the
   request's `durationMs` and curve; every window already drawn by Stages animates from where it is drawn at that
   moment (`from = rect`) to its new target, and a stage that loses its tile slides off the monitor to the left (core
   `stripTargets`: beside the last tile, shifted by `hiddenShift`; no `x/y/w/h` for it in the event). An update every
   frame retargets the windows whose tile moved, from the current place with their velocity (the others keep their
   clock): still send it debounced, as the shell does.

### Removed outputs (audit 2026-11-18, A-16)
A Stages window keeps its output's name from creation: the handlers that still run while a removed output destroys it (the strip's reveal and hide) no longer read a null screen.
