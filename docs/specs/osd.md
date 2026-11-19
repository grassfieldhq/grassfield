# OSD spec · shell-engineer · M2

## macOS reference behavior (described in words)
- Older macOS shows a centered-bottom rounded square (about 200 pt) with a large icon and a 16-segment bar.
- Recent macOS (26/27 style) shows a compact pill under the menu bar at the top-right: small icon on the left, a thin level bar
  filling the rest, on the standard material; it appears on a volume or brightness change and fades after about 1.5 s.

## Decision
Grassfield implements the **macOS 26/27 style**: a compact top-right pill under the menu bar, icon plus continuous level bar (no
segments). Reasons: it matches the rest of the M2 notification surfaces (same corner, same material) and needs no extra layout
for tall icons. The centered-bottom square is not implemented.

## Purpose and non-goals
Feedback for output volume/mute and display brightness changes, whoever causes them. Non-goals: microphone, input-source popup,
media-key bindings (the session config binds keys to the IPC targets below), slider interaction (the pill never takes input).

## Functional requirements
1. O1 The OSD shows on a change of the default sink volume or mute (Quickshell Pipewire through `qs.services.Audio`), on a change
   of the backlight (`/sys/class/backlight/<first>/actual_brightness`, watched by FileView plus a 1.5 s poll fallback), and on a
   brightness key that changed an external display over DDC/CI (requirement 10).
2. O2 Layout: pill `osd.width` x `osd.height` (220 x 44) at `menubarHeight + osd.gap` from the top, right aligned, material
   background with compositor blur, `volume-*`/`sun` icon, bar `osd.barHeight` (6) using `text` over a `fill` track; muted shows an
   empty bar and the `volume-mute` icon.
3. O3 It fades in/out (`motion.normal`, capped by Reduce Motion) and hides `osd.hideDelay` (1.6 s) after the last change; a new change
   restarts the timer. Never takes input (empty input region).
4. O4 Changes during the first 1.5 s after start and after a default-sink switch are ignored (initial reads are not user actions).
5. O5 Without a backlight device, brightness never shows and the brightness IPC does nothing (logged "no backlight device"), unless
   the active display is an external display that answers DDC/CI (requirement 10).
6. O6 Real changes by IPC (for key bindings): `volume up|down|mute` runs `wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+` /
   `5%-` / `set-mute ... toggle`, `brightness up|down` runs `brightnessctl -d <dev> set 5%+|-` on the built-in panel, or
   `omarchy-brightness-display-ddc <output> +5%|5%-` on an external display (requirement 10); the OSD is shown afterwards even if
   the value did not change (limits).
7. O7 In a `GRASSFIELD_DEV=1` session brightness is never changed (the nested shell controls the owner's hardware): the IPC only logs and
   shows the current level. No display is asked over DDC/CI there either (logged once at start), nor under the visual fixtures.
   Volume changes are real (5 % steps; tests restore the value).

8. O8 Keyboard backlight HUD (macOS: the keyboard brightness HUD; REQ-OSD-NG-d1a, master prompt 5.2 "volume/brightness/keyboard OSD"; owner decision 2026-10-23, follow macOS): the same pill as volume and brightness (`kind` `keyboard`, the `keyboard` glyph and the continuous bar), shown on a change of `/sys/class/leds/*kbd_backlight/brightness` (`Brightness.kbdValue`, watched by FileView; the first value read after start is not a change; O4 applies) and by the IPC target `keyboard up|down` (a step is 1/16 of the range, the 16 notches of the macOS keys, at least one device step; `brightnessctl -d <device> set <n>` through `Brightness.setKbdLevel`, which in a `GRASSFIELD_DEV=1` session only logs, so the OSD then shows the current level, as O7). Without a keyboard backlight device the IPC logs "no keyboard backlight device" and nothing shows (O5). `osd display keyboard <0..1> false` shows it for tests. Accessible name "Keyboard brightness N%" (fr « Luminosité du clavier N % »). The input-source popup is requirement 9. Test: `tests/shell/osd_keyboard.sh` (offscreen, dev session, shims that fail if `brightnessctl` runs).

9. O9 Input source HUD (macOS: the input source name appears when the keyboard layout changes; owner decision 2026-10-23): the same pill, `kind` `inputsource`, the `keyboard` glyph and the layout name (elided, `Osd.label`) in place of the bar, shown for `osd.hideDelay` when the compositor reports a layout change. `platform/InputSource.qml` listens to Hyprland's `activelayout>>keyboard,layout` event (event-driven; the only code that talks to the compositor) and `InputSource.js` decides (`tests/unit/tst_inputsource.qml`): the first layout seen on a keyboard is remembered without a HUD, so a session with one configured layout never shows anything (nothing says how many layouts exist, a change is the signal); a different layout on the same keyboard shows it; keyboards are independent; malformed events and names over 128 characters are ignored; an event whose layout has no readable name (Hyprland reports `error` for a virtual keyboard that brings its own keymap, such as wtype) is ignored too, the input source being the system's and not a virtual keyboard's (macOS). The name is shown in the shell's language: Hyprland sends the English xkb description ("English (US)"), `platform/layout-names.py LANGUAGE NAME...` reads xkeyboard-config's own gettext catalog (`xkeyboard-config-2`, then `xkeyboard-config`) with Python's gettext module (no generated locale needed) and prints the translated name, the English one when there is none; `InputSource.qml` runs it once per name and language (English: no helper), and Settings reads the same catalogs the same way. Tests: `tests/shell/input_source_names.sh`. O4 applies (nothing in the first 1.5 s). Accessible name "Input source <name>" (fr « Source de saisie : <name> »). Hooks (dev session only): `osd layout "<keyboard>,<name>"` feeds an event, `osd state` prints `shown|kind|label`. Tests: `tests/shell/osd_keyboard.sh` (logic, offscreen) and nested `tests/visual/osd-inputsource.sh` (HUD and its absence, capture).

10. O10 Per-display brightness (ADR-0045 OC-4). The brightness keys act on the active display (`Compositor.activeScreenName`: Hyprland's
   focused monitor, which follows the keyboard focus and the pointer, the display the OSD already showed on; macOS changes the
   display with the key window), decided by `services/BrightnessLogic.js` `keyTarget`: an external display that answers DDC/CI is
   stepped by 5 points (the backlight keys' step) through Omarchy's `omarchy-brightness-display-ddc <output> +5%|5%-`; the built-in
   panel (`eDP-`, `LVDS-`, `DSI-`) through the backlight as before; an external display that does not answer leaves the keys to the
   built-in panel's backlight (macOS keeps driving the built-in display when the other has no brightness control); with neither,
   nothing happens (logged). The pill shows the changed display's level on that display (`Osd.output`, `Osd.screenName`: the display
   changed while it is connected, else the active display; the banners make room for it there), the same pill as every other kind
   (no new look, ADR-0045 OC-0.7): a backlight change shows on the built-in display (the active display when none is connected, an
   all-in-one's panel); a DDC/CI key shows the level expected at once, and the command's printed answer corrects it.
   `Brightness.qml` asks each connected external output its level once when it appears (the command with the output alone; the
   compositor's own `HEADLESS-`/`WAYLAND-`/`X11-` outputs are never asked), runs at most one command per output at a time (what comes
   meanwhile waits, merged: a set replaces what waited, key steps add up; DDC writes take 50 to 200 ms), and runs it as an argument
   vector, never through a shell, bounded by coreutils' `timeout -k 2 12` (the script's ddcutil is a child: `timeout` runs the command
   in a process group of its own and ends the whole group, TERM after 12 s, KILL 2 s later; a TERM to the script alone would leave
   ddcutil on the bus; security review LOW 3), after `command -v` found both (checked again whenever the outputs change). A key steps from the
   display's own level (the command reads it first), so a change made elsewhere (Settings, the display's buttons) is never stepped
   over. An output that did not answer its first query, or whose writes failed three times in a row, is a display without DDC/CI until
   it is plugged again: one journal line names it and what it needs. A missing command: one journal line, every external display keeps
   its own brightness. A run that its bound ended (exit 124) counts as not answered. The output's queue is released only once the
   process has really ended, never at a deadline: a run still going 18 s after its start (past the bound and its kill) gets a TERM
   again (to `timeout`, which passes it to the group) and is still waited for, so two commands never share a bus. Tests:
   `tests/unit/tst_brightnesslogic.qml` (the command's answer, the step, which display a key acts on, the queue, the bound).

### Surface (audit 2026-11-18)
The pill's layer surface stays mapped on the display the OSD shows on, empty and without input while the pill is hidden (blur region off), so a key press after a hide only fades the pill in instead of mapping a surface and waiting for its first frame. It is unmapped while hidden on an output that shows a full-screen window: a mapped overlay surface, even an empty one, would keep the compositor from scanning that window out directly.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| O1/O2 | `qs ipc call osd display volume 0.6 false` then `scripts/dev/shot.sh osd-volume WAYLAND-1`: pill with icon and 60 % bar | L1 |
| O6 | `wpctl get-volume`, `qs ipc call volume up`, `wpctl get-volume` = +0.05, OSD visible; `volume down` restores | L1 |
| O7 | `qs ipc call brightness up` in nested: log "dev session, not changing the backlight", `actual_brightness` unchanged, OSD shows | L1 |
| O5 | on a machine without backlight, `brightness up` logs "no backlight device" | L1 (not run here: the dev machine has intel_backlight) |
| O10 | `tests/unit/tst_brightnesslogic.qml`: the key's display and step, the queue (one command per output, the last value wins) | L0 |
| O10 | real session, external display with DDC/CI: pointer on it, brightness up: `omarchy-brightness-display-ddc <output>` reads 5 more, the pill on that display; pointer on the laptop panel: the backlight moves, the pill there | L2 (owner, real hardware) |

## Interfaces / contracts
IPC targets (Quickshell IPC, `qs -p <shell> ipc call ...`): `osd display <volume|brightness|keyboard> <0..1> <muted>` and `osd hide` (tests; the
function is not called `show` because `qs ipc` reserves that word), `volume up|down|mute`, `brightness up|down`, `keyboard up|down` (backlight; bind the keyboard-backlight keys of the session config to it).
Tokens: `osd.*` (width, height, iconSize, barHeight, gap, hideDelay). Services: `qs.services.Brightness` (device, level, available;
external displays: `ddc`, `outputAnswers(name)`, `outputLevel(name)`, `stepOutput(name, direction)`, `setOutputLevel(name, level)`,
signal `outputLevelChanged(name)`).
Window: layer-shell Overlay, namespace `grassfield-osd`, one display only: `Osd.screenName`, the display whose brightness changed while
it is connected, else the active display (`Compositor.activeScreenName`: the focused output, the first as a last resort; macOS).

## Dependencies (verified versions)
Quickshell 0.3.1 (`Quickshell.Services.Pipewire`, `Quickshell.Io`), `wpctl` and `brightnessctl` in `/usr/bin` (verified present),
Qt 6.11.2. External displays: Omarchy's `omarchy-brightness-display-ddc` (Omarchy 4.0.6; `ddcutil` behind it, an Omarchy base
package), found on PATH at use time; without it, no external display is controlled (one journal line).

## Degraded behavior
No PipeWire sink: volume OSD never shows, `volume` IPC commands run `wpctl` which fails silently. No backlight or `brightnessctl`
missing: see O5; brightness changes by other programs are still shown when the sysfs file exists. An external display without DDC/CI,
without i2c access, or no `omarchy-brightness-display-ddc`: its keys fall back to the built-in backlight, or do nothing (O10, one
journal line).

## Automated tests · manual verification
Per-display brightness: `tests/unit/tst_brightnesslogic.qml` (O10). Otherwise tokens (`tst_tokens`) and the L1 steps above. Evidence: `.dev/shots/osd-volume.png`,
`osd-volume-real.png`, `osd-brightness.png` (not committed).

## Performance · Accessibility · i18n
Idle cost: one 1.5 s file read while a backlight exists; one DDC/CI query per external display when it appears, nothing while idle. The pill exposes `Accessible.ProgressBar` with name "Volume N%" /
"Brightness N%" (translated through `qsTr`). Reduce Motion shortens the fades, and the level jumps instead of gliding (ADR-0039 step 5).

## Known limitations
- Top-right pill only, on the active display (the focused output, not the first one); every screen-less surface (Notification Center, Search, Apps, switcher, centred popups, banners, OSD) opens by that one rule.
- Brightness is not changed in the dev session, so only the display path is verified there.
- No microphone OSD (the keyboard backlight HUD is requirement 8, the input source HUD 9: it shows names as the compositor reports them, not flags or abbreviations, and a real layout switch cannot be made in the nested session, which has one layout); no segmented/centered style. The keyboard HUD is not verified on hardware (the dev machine has no `kbd_backlight` LED): the logic is tested with a faked device, the look is the volume pill's.
- Volume cannot exceed 100 % (`-l 1`).
- Hardware keys are bound in `config/hypr/grassfield/bindings.lua` (`XF86MonBrightnessUp|Down` call the `brightness` IPC target).
- External displays (O10, ADR-0045 OC-4) need DDC/CI on in the display's own menu, the `i2c-dev` kernel module loaded and read-write
  access to `/dev/i2c-*` for the user (ddcutil's udev rule or the `i2c` group): Omarchy installs `ddcutil` but neither is checked here.
  Some displays have no DDC/CI at all (many TVs, some docks and adapters, most USB-C hubs drop it), and then the keys fall back to
  the built-in backlight. Slow displays take up to about a second per write: the level moves late, the pill shows the expected level
  at once. The first query after a plug detects the display's bus (seconds with several displays), so a key pressed right after a plug
  drives the built-in backlight. A level changed with the display's own buttons is not seen until the next key (DDC/CI has no change
  event; nothing polls). Near the bottom Omarchy's command steps by 1 % instead of 5 % (`+5%` below 5 %) and never goes below 1 %.
  Settings and the keys are two writers to one display: a key pressed during a Settings drag may be lost on the bus (the next one
  works). Not verified on hardware from the cloud session that built it (no display, no i2c).
