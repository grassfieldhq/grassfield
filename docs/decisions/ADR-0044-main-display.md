# ADR-0044: The main display, and the wallpaper per display
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (applied provisionally, owner rule of 2026-10-28: the closest to macOS 27, no technical step for the end
user) · Date: 2026-11-04 · Decider: owner (revisit), integrator (merge) · Number: 0044 (0043 is the public installation script)

## Context

The owner installed rc1-22 on a second machine with several displays and found that "there is no way to choose which
display is the main one" and "no way to set the wallpaper per display".

What the code did on 2026-11-04 (main e8e6856b):
- Menu bar: one per output (`MenuBar.qml`, a `Variants` over `Quickshell.screens`). Unchanged by this ADR (macOS 27 has a
  menu bar on every display).
- Dock: one window per output, one output has the Dock (`Geometry.dockScreen`); it started on the *focused* output at
  login (a race on a second machine) and then followed the pointer's dwell on another output's Dock edge. No setting.
- Desktop icons: the *first* of `Quickshell.screens`. Notification banners: the focused output (`Compositor.activeScreenName`).
  Nothing let the user say which display is "the" display.
- Wallpaper: already per display since ADR-0016 section 8 (`wallpaper.outputs`, identity serial and model else connector; the
  shell resolves `WallpaperConfig.resolve(Settings.wallpaper, output)` per output; Settings > Wallpaper has a "Display" row
  with "All Displays" and each display, shown with more than one output). The row was the first of the options group beside
  the preview, easy to miss; this ADR makes no storage change for it.

## Decision

### D-1 The main display holds the Dock, the desktop icons and the notification banners
macOS: Displays > "Use as" > Main display. The Dock starts on it and moves to it when the main display changes; the pointer
reaching another output's Dock edge still moves the Dock there (macOS does the same with the Dock at the bottom). The desktop
icons and the banners are on it. Menu bars stay on every display. New windows follow the compositor's focus as before
(Hyprland places a window on the focused monitor; this ADR does not change window placement).

### D-2 Storage: `displays.main`, one remembered choice per set of connected displays
A new key of grassfield.json (contract version 1, additive; schema, generated `SettingsContract.js`, defaults):
`displays.main` is a list, newest first, at most 16, of `{set: [<display key>...sorted], main: <display key in set>}`.
- A display key is its identity, `DisplayRole.identity` (`ui/Grassfield/Ui/DisplayRole.js`): `s:<make>|<model>|<serial>` when it
  has a serial, else `m:<make>|<model>|<connector>` (two identical monitors without a serial stay apart), else `n:<connector>`
  for an output with no EDID at all. A connector name alone is never the key of a real monitor. The same panel on another
  port is the same display *when it reports a serial*. The data is Hyprland's `monitors` answer (`make`, `model`, `serial`),
  which the shell already reads (`platform/Displays.qml` `described`) and publishes to Settings in the Displays state file:
  Qt's `QScreen` and Quickshell's `ShellScreen` are not used, because Qt 6.12's `QWaylandScreen` has no serial (it is always
  empty) and no make. A monitor with an EDID without a serial moves its key with its port.
- One entry per set: the choice comes back when the same displays are connected again (laptop alone, laptop at the desk).
- The Settings app writes it through `ConfigStore.set` (the existing store; the contract validates it). The shell reads it
  through `SettingsStore` and resolves it in `shell/services/MainDisplay.qml` from `Quickshell.screens` joined to Hyprland's
  answer, live. `MainDisplay.ready` is false until every output is described (or `Tokens.dockSettleTimeout` has passed), and
  `screenName` is "" until then: the Dock waits for it and for the settings before it latches, so it never takes a fallback
  output that the stored choice would overrule. Changes of the outputs (a hot-plug is a burst) take effect after
  `Tokens.motionSlow`. The dev override `GRASSFIELD_DESKTOP_SCREEN` is read here, once, and is the main display while that
  output exists: the Dock, the desktop icons (`DesktopSurfaces.iconsScreen`) and the banners all read `MainDisplay.screenName`.

### D-3 Resolution and fallback (`DisplayRole.resolve`)
1. The choice made for exactly this set of connected displays.
2. Else the newest choice, for another set, whose display is connected: plugging a display in or out does not move the
   role while the main display is still there.
3. Else (the main display was unplugged, or never chosen): the built-in panel (connector eDP, LVDS or DSI), else the
   first output.
A bad stored list reads as no choice (the entries that are fine are kept; nothing is rewritten).

### D-4 Settings > Displays: "Use as"
With more than one display, each display's group has a "Use as" pop-up: "Main display" or "Extended display". The main
display offers only "Main display" (it stays main until another display is made main, as in macOS); choosing "Main display"
on another display makes it main. Arrange… draws the main display's tile with the solid menu bar. Mirroring is not offered
(NOT in this step: Hyprland can mirror, the Arrange sheet and the trial lines do not model it).

### D-5 Wallpaper per display
No storage change: `wallpaper.outputs` keeps its shape and the top-level keys remain "All Displays", so an existing single
wallpaper setting needs no migration (a file with no `outputs` shows the same wallpaper on every display until the user
picks per display). The Display pop-up moves to the top of the pane, above the preview, with a line saying whether the
display follows All Displays. Entry point for other surfaces (the desktop's Change Wallpaper…): the Settings command line
`grassfield-settings --section=wallpaper --display=<output name>`, which a second launch hands to the running instance as
the D-Bus `Open("wallpaper@<output name>", token)`; the pane opens on that display (an unknown output is ignored, the pane
then shows All Displays).

Known limit (not changed here): the wallpaper's display identity (`WallpaperConfig.displayKey`) reads Qt's screens, whose serial is
empty under Wayland, so a per-display wallpaper is in effect keyed by the connector name; moving a monitor to another port loses
its wallpaper override until it is set again. Moving it to Hyprland's data is a follow-up.

### D-6 XWayland primary
`xrandr --output <main> --primary` would need `xorg-xrandr` (not installed here, not a Grassfield dependency): not done,
NOT VERIFIED, no new dependency. GTK/Qt/Wayland-native apps are unaffected.

## Consequences
- Contract: `displays.main` (additive). Readers: shell (`MainDisplay`), Settings (Displays). Tests: `tests/unit/tst_displayrole.qml`.
- The dev override `GRASSFIELD_DESKTOP_SCREEN` is folded into `MainDisplay`: the one source for the Dock, the icons and the banners.
- The banners no longer follow the focused output: they stay on the main display (macOS).

## Amendment A-1 2026-11-05: a combination of displays never seen before
Status: Accepted as built (owner ratification of 2026-11-08). Before:
Proposed (2026-11-05), applied provisionally (owner rule of 2026-10-28: decide alone, the recommended option, the
macOS model first). Inspired by Project Luma's luma-displays "arrival" (Apache-2.0: wait for the hot-plug to settle, two
displays or more, an arrangement not known yet); no code copied.

Context: D-2 remembers the main display per set of connected displays, but nothing tells the user that a set they never had
(the laptop at a new desk, a projector) may need arranging: Hyprland places a new monitor to the right at its preferred mode.

Options:
1. Nothing (macOS: plugging a display in extends the desktop; Displays is opened by the user).
2. Open Settings > Displays by itself once the hot-plug has settled (Luma opens its Displays panel once).
3. One notice whose click opens Settings > Displays.

Decision: option 3. macOS opens no window on hot-plug; a window that opens by itself takes the focus from what the user was
doing, and a notice keeps the arrangement one click away without that. Rules (`shell/services/DisplayArrival.js`, pure,
`tests/unit/tst_displayarrival.qml`; wiring `shell/services/DisplayArrival.qml`, posted from `shell/shell.qml` with
`Notifications.postInternalAction`, the click runs `SettingsApp.openSection("displays")`, the way the Software Update notices
open their pane):
- A combination is the sorted set of the connected displays' keys (`DisplayRole.setOf`, D-2: make, model, serial, never the
  connector alone). It is taken only once Hyprland has described every output (`MainDisplay.live.ready`).
- Settled: the set has not changed for 3 s (`SETTLE_MS`; a dock brings its monitors one after the other).
- Offered once per new combination of two displays or more. Known, never offered: a set in the seen-set, or a set the user
  already chose a main display for (`displays.main`). Recorded without a notice: the set the session starts with (the user
  did not just plug it in) and a single display (nothing to arrange).
- Locked: the offer waits and is decided again at the unlock (if the set is still connected); nothing appears over the lock.
- Dev sessions: offered only by a dev shell with its own state folder (`GRASSFIELD_STATE_HOME`) whose outputs are all virtual
  (`WAYLAND-n`, `HEADLESS-n`, `X11-n`: a nested session). A dev shell on the owner's displays neither offers nor writes.
- Storage: `displays-seen.json` in the shell's state folder (`$GRASSFIELD_STATE_HOME` or `$XDG_STATE_HOME/grassfield`),
  `{version: 1, seen: [<combination key>...]}`, newest first, at most 32, file 0600, folder 0700. Malformed reads as empty
  (every set is then new once more, and the session's own set is recorded silently first). The keys hold the displays' make,
  model and serial, as `displays.main` does; nothing leaves the machine.

UI: title "New display arrangement", body "These displays are connected together for the first time. Open Displays Settings
to arrange them and choose the main display." The click opens the pane. Not done: a separate "Displays Settings…" button on
the notice (the shell's own notices have no buttons today: their buttons render only for a sender's live notification;
adding them is a change to the notification module, left for later).

Failure modes: Hyprland never describes an output (the set is never taken: nothing is offered); a burst longer than 3 s with
a pause (two notices are impossible for one set, at worst the intermediate set is offered once); Settings not installed
(SettingsApp's "not installed" notice).

NOT VERIFIED (no compositor here): hot-plug in a nested session (`hyprctl output create headless` through `scripts/nestctl`),
the notice's look, the click opening Displays. Owner L2: plug a monitor never used with this laptop, wait 3 s, see one notice;
unplug and plug again, no notice; lock, plug a new one, unlock, see it then.

## Amendment A-2 2026-11-07: "Use as" on every display, the menu bar in Arrange
Status: Accepted as built (owner ratification of 2026-11-08). Before:
Proposed (2026-11-07), applied provisionally (owner rule of 2026-10-28: decide alone, the closest to macOS 27).

Context: the owner (rc6, desktop PC with several displays) reported "there is no way to set the main display". The storage, the
resolution and the shell side worked (`tests/unit/tst_displayrole.qml`, `tst_settingsdisplays.qml` test_page_mainDisplay), but the
control was hard to reach: the page shows the first display, which is the main one when nothing was chosen (D-3: no built-in
panel on a desktop, so the first output); D-4 gave the main display's "Use as" pop-up a single item, "Main display", so the role
could not be moved from the display shown, and the row sat in the third group, after the resolution choices and the
brightness, where nothing said that the band's pictures are buttons. Arrange… drew the main display's menu bar but did not let
it move.

Decision (macOS 27 Displays):
- "Use as" is the first row of the selected display's settings, in a group of its own right under the band.
- Every display's pop-up offers "Main display" and "Extended display" (in that order, macOS's), the main one too. "Extended
  display" on the main display hands the role to another display: the built-in panel when it is another display, else the first
  other display in the compositor's order (`DisplayRole.successor`); with one display there is no row (as before).
- The band says "Main display" under the main display's name when several are connected (a caption in the secondary colour,
  `Tokens.settingsDisplayRoleBaseline`): the role is visible before any click.
- Arrange…: the main display's tile keeps the solid menu bar, and that bar can be dragged (a 12-pt strip along the tile's top,
  `Tokens.settingsDisplayMenuBarGrab`) onto another display's tile; on Done that display becomes main (`ArrangeSheet.mainChosen`),
  with the moved displays tried as before; Cancel drops it. The sheet's message says so. The keyboard path stays the pop-up.
- The choice still applies at once (no trial: nothing about the picture changes) and is stored per set of connected displays (D-2).

Not changed: mirroring (D-4), the XWayland primary output (D-6), window placement (D-1).

Tests: `tests/unit/tst_displayrole.qml` test_successorOfTheMainDisplay, `tests/unit/tst_settingsdisplays.qml`
test_page_useAsOnEveryDisplay (fails on rc6: the main display offered one choice and the row came after the resolution) and
test_arrangeMovesTheMenuBar. NOT VERIFIED on the owner's displays: Settings > Displays with two or more monitors, the pop-up on
the main display, the band's caption, dragging the menu bar in Arrange…, the Dock and the desktop icons moving.
