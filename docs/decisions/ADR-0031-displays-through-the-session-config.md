# ADR-0031: Display changes go through a Grassfield session file, with a revert countdown
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (cloud session, owner brief 2026-10-26: "Écrans : ADR d'abord. Jamais hyprctl sur la session réelle ; une
modification passe par la config de session, avec un compte à rebours de retour en arrière comme sur macOS") · Date: 2026-10-26 ·
Decider: owner (brief), integrator (merge after the review of group 2) · Number: 0031 (it was 0027; the integrator gave
0026 to 0029 to the Files decisions of PR #4, and the Settings polkit ADR became 0030)

## Context
Settings > Displays has been read-only so far (`docs/specs/settings.md` S12): the Settings app sees the outputs only as Qt
screens, it has no link to the compositor, and the monitors are set by the Hyprland Lua configuration, which Grassfield does
not own on that point:
- `config/hypr/session.lua` loads `config/hypr/grassfield/omarchy.lua`, which loads the user's `~/.config/hypr/monitors.lua`
  (an Omarchy template). It is the user's file: Grassfield never writes it.
- Without it, `session.lua` adds `hl.monitor({output = "", mode = "preferred", position = "auto", scale = "auto"})`.

macOS 27 changes the resolution ("Larger Text … More Space"), the refresh rate, the rotation and the arrangement at once, then
asks "Keep these display settings?" and puts the old ones back after 15 seconds without an answer, so a display left black
by a mode it cannot show comes back on its own.

What Grassfield already has:
- The shell is the only Grassfield process that talks to Hyprland. It reads the monitors through Quickshell's Hyprland module
  (`Hyprland.monitors`, each with its `lastIpcObject`: name, description, make, model, serial, size, refresh rate, position,
  scale, transform, available modes) and sends requests on Hyprland's request socket (blur, motion, zoom:
  `shell/platform/Compositor.qml`, `docs/specs/ui.md`). It handles `configreloaded`: what it pushed is sent again after a reload.
- The shell writes a runtime file for the apps, `$XDG_RUNTIME_DIR/grassfield-capabilities.json`
  (`shell/platform/CapabilitiesFile.js`, `apps/chromecaps.h`): per session, gone at logout.
- A config reload is a normal event in a Grassfield session. The compositor extension stays loaded (ADR-0009); the bindings
  take fresh ids (`bindings.lua`); autostart runs only on `hyprland.start`.

## Decision
1. **The choice is a Grassfield file read by the session config.** Settings writes
   `$XDG_CONFIG_HOME/grassfield/displays.conf`. It is data, not code: one line per display, fields separated by tabs.
   ```
   v1<TAB>desc:<description><TAB><W>x<H>@<Hz><TAB><X>x<Y><TAB><scale><TAB><transform>
   ```
   - A display is named by its description (make, model and serial, as Hyprland's `desc:` selector), so the choice follows the
     display from one port or dock to another, as on a Mac.
   - A new module, `config/hypr/grassfield/displays.lua`, reads the file at every parse with `io.open`: no `load`, no `require`,
     no evaluation of its text. Every field is checked against an anchored pattern:
     - the description: 1 to 160 printable characters, no tab;
     - the mode: `^%d+x%d+@%d+%.?%d*$`, both sizes 1 to 16384 and the rate 1 to 1000;
     - the position: two integers between -32768 and 32768;
     - the scale: a number from 0.5 to 4;
     - the transform: 0 to 7.
   - A good line becomes one `hl.monitor({output = "desc:" .. description, mode = …, position = …, scale = …, transform = …})`.
     A bad line is skipped and reported (`grassfield: displays.conf line N: …` in the journal); the others still apply.
   - `session.lua` requires the module (in a `pcall`) after `grassfield.omarchy`, so a display that Settings set takes
     Settings' values, and a display it never touched keeps the user's `monitors.lua`. The nested `dev.lua` requires it too, with
     the dev paths (`GRASSFIELD_CONFIG_HOME`, `GRASSFIELD_STATE_HOME`).
2. **The shell publishes what the displays can do.** It writes `$XDG_RUNTIME_DIR/grassfield-displays.json`
   (`$GRASSFIELD_STATE_HOME/displays.json` in a dev session). The file holds:
   - each monitor's fields from `lastIpcObject`;
   - the backlight of `Brightness.qml`;
   - the state of a trial (below).
   It is written atomically at start, on `monitoradded`, `monitorremoved` and `configreloaded`, and after a trial changes
   state. Settings reads it like the capabilities file and polls it every `settings.systemRefreshMs` while the pane is open.
3. **A change is a trial first.** Settings writes `$XDG_RUNTIME_DIR/grassfield-display-trial.conf`
   (`$GRASSFIELD_STATE_HOME/display-trial.conf` in a dev session):
   - the first line is `trial <id> until <unix time>`, 15 s ahead;
   - then the full set of lines that would be the new `displays.conf`.

   What happens next:
   - `displays.lua` reads the trial after `displays.conf` and applies it in its place while `os.time()` is before `until`.
   - The shell watches the trial file and asks Hyprland to read its configuration again: the request `reload` on the request
     socket, the same channel and the same one-connection-per-request code as the blur push. No `hyprctl` process, no
     `keyword`, and nothing Hyprland would not also do when a configuration file is saved.
   - The shell publishes the trial `applying` when it asks for the reload, and `applied` only when Hyprland answers `ok` to
     that same request: Hyprland answers once it has read its configuration (counter-review of 2026-10-26: the request alone
     does not mean the mode is set). Each request has its own connection and ticket, so the answer to another reload (the
     previous trial taken back, the input files) cannot stand for it; the `configreloaded` event could (it names no
     request). If the answer is not `ok` or does not come within `settings.displayTrialAnswerMs` (3 s: reading the Lua
     configuration may take longer than the 1 s a blur push waits), the trial stays `applying`, Keep stays refused and the
     deadline takes it back. A display can still take a moment to show the new mode after that (the monitor resyncs): no event says
     when it is done.
   - The shell owns the countdown. It survives a Settings that crashed or was closed.
   - Settings shows a sheet: "Keep these display settings?", "The previous settings come back in N seconds.", Revert and Keep.
   - Keep is taken only while the shell has published the trial `applied` (the mode is on screen); pressed earlier (Return
     twice), it is refused and the sheet stays open, saying the new settings are not on screen yet: nothing is held to be sent
     later (counter-review of 2026-10-26). Settings then marks the trial `kept <id>`. The shell stops its countdown, removes the trial file without a second reload (what is on screen stays) and
     publishes `kept`; only then does Settings write the new `displays.conf` (atomically), which the next login reads. A Keep
     the shell does not take (its deadline came first: it publishes `reverted`; or it does not answer within the applied
     time) writes nothing, so a mode nobody confirmed can never reach `displays.conf` (review of 2026-10-26). If that last
     write fails, the session keeps the mode until the next reload or login, and Settings says so.
   - Revert, the deadline, or a trial file the shell finds when it starts: the shell removes the trial file (synchronously,
     before it asks for the reload) and reloads. `displays.lua` no longer applies a trial at its deadline second either.
     `displays.conf` and `monitors.lua` then hold the previous set, whatever it was. No "previous state" is captured, so none
     can be wrong.
   - Logging out during a trial drops the runtime file. The next login reads only `displays.conf`.
4. **Brightness** uses the same command as the shell's `Brightness.qml`: `brightnessctl -q -d <device> set <N>%`. It is an
   action of the Settings allow-list, with the device name and the percentage validated. Neither the shell nor the app runs as
   root: brightnessctl goes through logind's `SetBrightness` or the backlight's udev group.
5. **Dev sessions.** In a dev session, Settings writes the trial and `displays.conf` only under the dev paths. Only the nested
   shell reads those paths, and it reloads only the nested Hyprland, since its request socket is the nested instance's. The
   brightness action is suppressed, as every hardware action is (ADR-0019, `SystemService`).
6. **Not built:** colour profiles, the TV pop-up, automatic brightness without an ambient light sensor, HDR, mirroring (Hyprland
   has a `mirror` rule; the menu that would offer it is left for later), a "main display" (Hyprland has none: every display
   has the menu bar), Advanced… (none of its choices exists here), and Night Shift…: `grassfield-nightshift` drives hyprsunset
   through `hyprctl`, so Settings does not run it; the switch stays in Quick Settings.

## Consequences
- A display change touches no file of the user's. Removing `displays.conf` brings back `monitors.lua` alone.
- A reload re-reads the whole configuration. The shell pushes blur, motion, zoom and the pointer again, as it already does after
  any reload.
- A broken `displays.conf` costs only its own lines. A broken module costs only the displays: the `pcall` reports it, the
  rest of the session loads.
- Settings never talks to Hyprland. The shell gains one reader of a file that another process writes, so the format is checked
  in three places: Settings writes only lines its validator accepts, `displays.lua` applies only lines that match its patterns,
  and the shell reloads only on a trial line it can parse.

## To verify in a nested session (owner checks before merge)
- `reload` on the request socket re-reads `displays.lua` in Hyprland 0.56.2, and a `desc:` rule written after a rule for the
  same display's port name (in `monitors.lua`) is the one that applies. If the port name wins, Settings writes the port name
  instead and the spec says so.
- A mode the display cannot show: the shell's countdown brings the old mode back with the Settings window gone.

## Alternatives rejected
- `hyprctl keyword monitor` (or the same Lua call sent live) from Settings or the shell: the owner's brief rules it out, and the
  configuration and the screen would then disagree until the next reload.
- Writing `~/.config/hypr/monitors.lua`: it is the user's own file.
- A Lua file generated by Settings and `require`d by the session: the compositor would run text written by another program. The
  data file read with patterns cannot run anything.

## Amendment 2026-10-26: the input files apply at once
Settings > Mouse & Trackpad has written `mouse-trackpad.lua` since GF-066, and its choices applied at the next login. Settings >
Keyboard now writes `keyboard.lua` next to it, and Trackpad's More Gestures adds three switches to `mouse-trackpad.lua`. Both
files keep the form of Lua chunks that return plain values, but `config/hypr/grassfield/input.lua` reads them as text and
never runs them (the gestures by `bindings.lua`, through it): only `key = value` pairs with a number, true, false or a plain
double-quoted string count, as for `displays.conf` above (review of 2026-10-26: a chunk run even in an empty environment
could stall Hyprland's configuration with an endless loop). The shell starts with the session config's watchers
(`shell/platform/SessionConfig.qml`, started by `shell.qml`: Quickshell makes a singleton only when first used). Once the
writes settle (`settings.inputReloadMs`), it asks Hyprland to read its configuration again, through the same one request as
a display trial. A choice then applies at once, as on a Mac. No countdown is needed: a pointer or keyboard setting cannot
leave the screen unusable. Keyboard choices stay in the order GF-066 set for the pointer: after Omarchy's defaults, before
the user's own `input.lua`, which still wins. `keyboard.lua` holds only the keys the user changed. With two layouts or more,
`input.lua` sets no xkb group option (amended 2026-11-04): `bindings.lua` binds Ctrl+Space (previous input source) and Ctrl+Option+Space (next) for every keyboard from two layouts on.
