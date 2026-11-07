# Security modules spec (lock, polkit, idle) · security-engineer · M2

Design: ADR-0010. Rules: master-prompt R12, §5.9. Gates: §10 L1–L5.

## macOS reference behavior (described in words)
- Lock screen: the wallpaper, sharp (ADR-0040 IQ-W4 A; ASSUMPTION from memory), large clock and date at the top center, user avatar (circle) and name near
  the bottom center, a rounded password field with a return arrow; wrong password → the field shakes.
  "Cancel"/"Switch user" are not shown for a single user.
- Authorization dialog: a compact sheet raised above the centre (`panel.dialogRaise`, fading in; its width, radius and title
  stay distinct from the secret sheets, R12 / ADR-0035 9-18) with a lock icon, "<App> wants to make changes.", the
  user name field prefilled, password field, Cancel / Allow (default) buttons.

## Functional requirements
1. SEC1 Lock engages via IPC `lock lock`, idle timeout, lid close (`lock lid`, also when logind does not suspend;
   not in clamshell mode), and before sleep (logind delay inhibitor).
2. SEC2 Only PAM success (`omarchy-lock-password`) unlocks; errors/timeouts/crashes/graceful exits stay locked.
3. SEC3 Password cleared from the field and memory after each attempt; field disabled while authenticating.
4. SEC4 Lock surface on every monitor; input never reaches other clients (ext-session-lock).
5. SEC5 Lock screen shows clock, date, avatar (`~/.face` or AccountsService icon, only as a PNG the shell made from it:
   security-images.md) and name — no notification content, no thumbnails.
6. SEC6 Polkit agent: exactly one; shows message, action ID and the requesting program as far as polkit tells it
   (see "Polkit details"); Cancel/Esc cancel; never auto-approve.
7. SEC7 Idle: dim → lock → displays off on the idle lock screen (DPMS); respects Wayland idle inhibitors.
8. SEC8 Fingerprint only if `/etc/pam.d/omarchy-lock-fingerprint` exists; offered at a pace that never keeps the reader busy
   for nothing, never while the displays are off ("Fingerprint pacing").
9. SEC9 Lock coverage never disappears silently: the shell restarts after any exit while the session runs, Omarchy's
   sleep-lock is skipped only while the shell runs, and a failing sleep inhibitor or watcher is reported to the user
   and retried for as long as the shell runs (GF-030, D-12).
10. SEC10 Dev and test switches (dev hooks, PAM suppression, no inhibitor) exist only in a dev session: one gate,
    `GRASSFIELD_DEV=1` and no `GRASSFIELD_SESSION=1` (SEC-03); IPC test hooks and private state are refused in a real
    session (SEC-04).
11. SEC11 Password-manager windows are hidden from screen sharing and screencopy as in the Omarchy session (SEC-01).

## Acceptance criteria (gates)
| Gate | Test | Level |
|---|---|---|
| L1 | lock in nested, `kill -9` the shell → nested stays locked (screenshot), restart shell → lock re-acquired; soft reload with the marker removed or forged → still locked; a foreign locker taking over and releasing the lock → locked again by Grassfield; a graceful exit while locked (SIGTERM, `qs kill`) → still locked (`graceful-exit`, DT-21); nothing typed reaches a window (`tests/security/reload_locked.sh`, bare, outside the sandbox; `just test-security-nested`) | L1, then L2† |
| L2 | `tests/security/l2_wrong_password.sh` (nested, real PAM through the opt-in `GRASSFIELD_DEV_ALLOW_PAM=1`, owner decision D-10): 3 random wrong passwords → each "Incorrect password", still locked (Hyprland `LOCK`), field empty, nothing reached the probe window. **Never more than 3 wrong attempts per run, never the right password, Return pressed at most 3 times**; a second run within 15 min is refused (faillock deny=10 shared with sudo) | L1 (owner runs it), then L2† |
| L3 | lock shown before sleep | L2† owner |
| L4 | `tests/security/lock_privacy.sh` (nested): notifications with a marker image and a window filled with the marker colour, then lock and try to open every surface over it → no marker pixel in captures of both outputs (positive control before locking); `screenshare`: a Bitwarden-class window is black in a capture (DT-05) | L1 |
| L5 | owner procedure "L5 polkit (owner, real session)" below: `pkcheck … --allow-user-interaction` (runs nothing as root) → dialog with message, action, icon; Esc/Cancel → exit 3; wrong password → "Incorrect password", no approval | L2† owner (a nested shell cannot register an agent) |

## Dev gate (GF-AUDIT-001 SEC-03)
One rule for every dev/test switch of the shell (ADR-0019): `shell/lib/RunMode.js` `dev(GRASSFIELD_DEV, GRASSFIELD_SESSION)`
is true only for `GRASSFIELD_DEV` exactly `1` AND `GRASSFIELD_SESSION` not `1`. How it is read (slice M2, integrator
decision; `shell/services/DevGate.js`, which delegated to it since M1, is gone):
- **the security modules** (`shell/security/**`) import `RunMode.js` by a relative path (`import "../../lib/RunMode.js" as
  RunMode`) and call `RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))` themselves;
  they never use the `qs.lib` module or its `Mode` singleton, because a `qs/lib` directory on `QML_IMPORT_PATH` overrides
  any `qs.*` module (M1 review note 5), while a relative import cannot be replaced by any import path; a refused hook
  answers `RunMode.REFUSED`;
- **every other module** asks `qs.lib` `Mode` (`Mode.dev`, `Mode.fixtures`, `Mode.devValue(name)`, `Mode.stateDir`,
  `Mode.refused`), which `shell/lib/Mode.qml` defines from the same `RunMode.js`.

The predicate is unchanged: `tst_devgate` compares the gate with the pre-ADR predicate on 225 pairs of raw values, and
the migration was checked old against new (main's gate, the real modules) in 98 environments. The packaged session config sets
`GRASSFIELD_SESSION=1` (`config/hypr/session.lua`); the nested dev session never does (`scripts/dev/devenv.sh` unsets an
inherited one). A `GRASSFIELD_DEV=1` that leaks into a real session (environment.d, a uwsm env file, an import into the
user manager) therefore changes nothing: no dev hook answers, PAM is not suppressed (the lock can be opened), the sleep
inhibitor is taken, and the lock logs once "GRASSFIELD_DEV=1 ignored in a real session". Users: `Lock.devHooks`
(`lock status|devReload|devPauseOwnershipCheck|devForgeUnlockedAnswer|devLockView`, PAM suppression), `Idle.devHooks`
(`idle status|devSleep|devDisplayOff|devAutoSleep`, the display power-off default, no automatic sleep), `SleepInhibitor.dev` (no inhibitor in dev),
`polkit status`, and, outside the security modules, `Mode.dev` (`VisualFixtures.dev` is exactly `Mode.dev`,
`VisualFixtures.active` exactly `Mode.fixtures`), which every other IPC test hook checks (BarTone, Capabilities,
Widgets). Tests: `tests/security/tst_devgate.qml` (the gate as the security modules import it, 225 pairs against the
pre-ADR predicate), `tests/security/dev_gate.sh` (the real Lock singleton offscreen in five environments, including
`GRASSFIELD_SESSION=1` with a leaked `GRASSFIELD_DEV=1` and `GRASSFIELD_DEV_ALLOW_PAM=1`: every hook `refused`, PAM not
suppressed; `Mode.dev`, `VisualFixtures.dev` and `Widgets.devHooks` agree with the lock's gate in each; mutation: a gate
on `GRASSFIELD_DEV` alone fails it), `tests/security/ipc_inventory.sh` (the exact gates per class and per module kind,
the definitions in `RunMode.js`, `Mode.qml` and `VisualFixtures.qml`, no security module on `qs.lib`, `Mode` or a
non-relative `RunMode`, no `GRASSFIELD_DEV` read outside the gate call; its selftest: look-alike gates, a security
module on `Mode` or a local `RunMode.js`, wrong definitions in `Mode.qml` and `RunMode.js` each fail).
`ipc_inventory.sh` is a lint on the source text, comments and string contents blanked first (re-review of 2b8e13a):
`RunMode` appears only as `RunMode.<function>(...)` or a read of `RunMode.<variable>` (never bare, so no alias, no
`Object.defineProperty`/`assign` on it, no `(RunMode).x`, no spread, never `X.RunMode`; never an assignment, update,
destructuring or for-of target), `RunMode.js` is imported only by QML files and only under the name `RunMode`
(re-reviews of bf9e280 and f03d65a: `import ".../RunMode.js" as RM` then `RM.dev = ...` turned every dev hook on in a
simulated real session), read by Qt's own parsers (`qmldom` syntax trees and `qmlimportscanner`, through
`tests/ci/import_graph.py`), with import paths resolved as the engine resolves them and any `\` or `%` in them refused,
and no qmldir or second file stands in for it, `Mode.qml` or `VisualFixtures.qml`, `Quickshell` is
never written to or passed bare (`target: Quickshell` excepted), `RunMode.js` never rebinds an export or reaches its
own scope indirectly, no module uses `eval`, `Function`, `with`, escaped identifiers, `constructor`, `__proto__`,
`Qt.include` or `Qt.createQmlObject` or declares its own `Mode`/`RunMode`, a hook body that binds a gate name itself
counts as ungated,
a gate call in a security module stands only on a readonly property line or an `if (!...)` line, and Lock.qml's
leaked-value warning line is exempt only when its exact warning follows. It lists the files of shell/ from disk, hidden
ones included, and refuses any hidden path under shell/ or ui/ (re-review of e45bdf3: a glob skipped
`shell/widgets/.Evil.qml`, which a `Loader { source: ".Evil.qml" }` loaded and which turned the dev hooks on);
`tests/ci/import_graph.py` refuses them in the tracked tree and the PKGBUILD refuses them in the package. Its header
lists what it does not see: what a guard protects; a write by a name it does not model; QML outside shell/ (a shell
import that lands there is refused); a directory link under shell/ (none exists). Not done, measured: freezing `RunMode.js` (`Object.freeze(this)`
or non-writable properties in the `.pragma library` file) does not stop a write through an importer's alias, which
changes `RunMode.dev` for every importer (qs 0.3 offscreen, all three variants); the runtime is not tamper-evident, and
code that runs as the user is out of scope (next section).

## Where the shell's code comes from (GF-115, review of 360d6fa)
**Out of scope**, as for Omarchy: processes that run as the user. They can set the session's environment and run code
in it. Examples:
- `LD_PRELOAD`;
- `GTK3_MODULES`, or `GTK_PATH` with `GTK_MODULES`, once the gtk3 platform theme Omarchy's environment selects runs
  `gtk_init`;
- a planted compiled-QML cache (its location follows `XDG_CACHE_HOME`);
- a user drop-in for the unit (`~/.config/systemd/user/grassfield-shell.service.d/`);
- ptrace.

**In scope**: leaked developer search paths and accidental overrides that would replace or disable the shell's QML,
for example a `QML_IMPORT_PATH` left in the session by a development setup, or a stray Quickshell option variable.
macOS loads the lock screen only from the system, so the packaged shell does not take its code locations from the
environment:
- `packaging/systemd/grassfield-shell.service` starts `/usr/bin/qs -n -p /usr/share/grassfield/shell`. Never `-c`,
  which would also search `$XDG_CONFIG_HOME/quickshell` (GF-115).
- `UnsetEnvironment=` clears the following. systemd applies it last, over `Environment=` and the manager's environment:
  - the QML and Qt plugin search paths (`QML_IMPORT_PATH`, `QML2_IMPORT_PATH`, `QML_PLUGIN_PATH`,
    `QML_DISK_CACHE_PATH`, `QT_PLUGIN_PATH`, `QT_QPA_PLATFORM_PLUGIN_PATH`). A `qs/security/lock` directory on
    `QML_IMPORT_PATH` had replaced the whole lock screen.
  - every variable `qs --help` maps to an option (`QS_CONFIG_PATH`, `QS_CONFIG_NAME`, `QS_MANIFEST` today). The
    packaged command line needs none of them, and a stray `QS_MANIFEST` or `QS_CONFIG_NAME` made `qs -n -p` exit 108,
    so the session had no lock and no polkit agent, and the sleep-lock stand-in could not start the shell either.
  - as cheap extensions: `GTK_MODULES`, `GTK3_MODULES`, `GTK_PATH`, `GIO_EXTRA_MODULES` (GSettings loaded native code
    from it in the reviewer's probe of bf9e280), `QT_VULKAN_LIB` and `QSG_RHI_BACKEND` (the Vulkan library override
    matters only with `QSG_RHI_BACKEND=vulkan`; the shell runs on Qt's default backend). The shell needs none of them.
  - The list is not a native-loader boundary: the EGL, GBM, Mesa and Vulkan driver variables (for example
    `__EGL_VENDOR_LIBRARY_DIRS`, `LIBGL_DRIVERS_PATH`, `GBM_BACKENDS_PATH`, `VK_ICD_FILENAMES`, `VK_ADD_LAYER_PATH`)
    and `LD_LIBRARY_PATH` still reach qs, and some GPU setups need them. Whoever can set them already runs code as the
    user (out of scope, above); the list only keeps a leaked developer setting from replacing the shell's QML.
- The same variables made every `qs <subcommand> -p` exit 108, `qs ipc` included (re-review of bf9e280, M1), so a lock
  request could be defeated by the session's environment. Every installed caller of the lock clears them before it
  asks: the lock key and every other shell request of `config/hypr/grassfield/bindings.lua` (`env -u ... qs ipc`),
  the lid (`packaging/bin/grassfield-lid`) and the sleep-lock fallback (`packaging/shims/omarchy-shell`), both with
  `unset`. `tests/security/lock_request_env.sh` sets every option variable `qs --help` lists and checks that each
  caller still sends its request and that qs receives none of them; its control shows that qs's own option parsing
  refuses the request (exit 108) when the variables reach it.
- Nor can a test hook redirect a lock request (follow-up of the re-review of bf9e280). The callers' hooks are ADR-0019
  dev plumbing, honoured only in a dev session (`GRASSFIELD_DEV` exactly `1` and `GRASSFIELD_SESSION` not `1`):
  `GRASSFIELD_LID_LOCK`, `GRASSFIELD_LID_FALLBACK`, `GRASSFIELD_DRM` (a fake connected display skipped the fallback)
  and `GRASSFIELD_LID_PROC` in `grassfield-lid`, `GRASSFIELD_LID_TOOL` in the clamshell stand-in, and
  `GRASSFIELD_SHELL_DIR` in `bindings.lua` and in `packaging/session-bin/hyprland-dialog` (ADR-0035 D-3; checked by
  `tests/shell/hyprland_dialog.sh`). `config/hypr/session.lua` takes its modules from its own directory and
  the stand-ins from `/usr/lib/grassfield/omarchy-shims`, never from `GRASSFIELD_CONFIG_DIR` or `GRASSFIELD_SHIM_DIR`
  (another config could drop the lock key and the lid lock; another shim directory would hand Omarchy's sleep-lock
  Omarchy's own `omarchy-shell`). `lock_request_env.sh` sets hostile values in a real session (with a leaked
  `GRASSFIELD_DEV=1`, and without any run-mode variable) and checks that the installed shell is asked and no hostile
  command runs; in a dev session each hook is honoured (the controls). Not covered: a session whose own identity
  variables (`WAYLAND_DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE`, `XDG_RUNTIME_DIR`) are wrong, and `PATH`, which is
  code running as the user; the idle lock's timing comes from the user's own settings (`GRASSFIELD_CONFIG_HOME` is
  always honoured, ADR-0019), which the user may set to never lock.
- Grassfield's QML modules and Qt plugins then come from Qt's built-in locations (`/usr/lib/qt6/qml`,
  `/usr/lib/qt6/plugins`), and nothing is set in their place.
- `scripts/dev/shell-run.sh --unit-env` applies the same list, read from the unit file. Its own `QML_IMPORT_PATH` is
  then only the tree's module roots, standing in for the packaged import path.

Tests:
- **`tests/security/shell_unit_env.sh`** (data layer) checks:
  - the list, with the option variables read from the installed `qs --help`, so a new Quickshell option cannot be
    missed silently;
  - that no packaged drop-in resets it, and that `ExecStart` is the system tree.

  Its selftest fails on 11 mutations, a new option variable included.
- **`tests/security/unit_env_paths.sh`** (offscreen, the real modules) shows that each of these is real in a control
  run and gone once the unit's environment is applied:
  - a hostile `qs/security/lock` on `QML_IMPORT_PATH`, and separately on `QML2_IMPORT_PATH`, replaces the lock;
  - `QS_MANIFEST` stops the packaged command line (exit 108). With the unit's environment, it starts under each
    option variable and under all of them;
  - a native module named by `GTK3_MODULES`, or by `GTK_PATH` with `GTK_MODULES`, is loaded by the gtk3 platform
    theme.

Translations: `ui/i18n/translationloader.h` honours `GRASSFIELD_TRANSLATIONS_DIR` (ADR-0019 dev plumbing) only in a dev
session (the predicate written out until `apps/runmode.h` reaches main). Outside dev, the lock's and the polkit sheet's
strings come only from `/usr/share/grassfield/translations`. `tests/security/translations_dir.sh` checks this with a
hostile catalog: it is read in dev (the control), and ignored in a real session with a leaked `GRASSFIELD_DEV=1`,
without the variables, and for a near-miss value.

Not verified here: a full start of the shell under Omarchy's `QT_QPA_PLATFORMTHEME=gtk3` with the new list needs a
display. Offscreen, gtk3 exits 1 for lack of one, with or without the list.

## IPC surface (GF-AUDIT-001 SEC-04)
Quickshell's `IpcHandler` functions can be called by any process of the user (`qs ipc`, socket under
`$XDG_RUNTIME_DIR`; Flatpak sandboxes cannot reach it). Classes: **action** = called by Grassfield's own bindings,
gestures, screen corners or session helpers (`config/hypr/grassfield/bindings.lua`, `shell/desktop/HotCornerActions.js`,
`packaging/bin`, `packaging/shims`, `packaging/session-bin`) or by a Grassfield app through `apps/runmode.h`
`shellIpcArgs()` (`apps/*/src`), available in a real session, never returns private state;
**dev** = test hook, refused outside a dev session (the dev rule: the relative `RunMode.dev` call in the security modules,
`Mode.dev` or `VisualFixtures.dev` elsewhere; void functions do nothing, others answer `refused`); **fixtures** = dev
session AND `GRASSFIELD_VISUAL_FIXTURES=1` (`Mode.fixtures`, `VisualFixtures.active`). No function unlocks, runs a command, opens a URL, reads notification content or
approves polkit, except `update check`, which starts Grassfield's own update checker (ADR-0033 d: a one-shot child
of the shell, as the user, read-only towards pacman) and returns nothing it found. `tests/security/ipc_inventory.sh` fails when a function is missing from this table or the table names
one that does not exist, when an action has no real-session caller or is gated, and when a dev or fixtures function
does not check its gate.

<!-- ipc-inventory:begin -->
| Target | Functions | Class | Caller, or why it is gated |
|---|---|---|---|
| lock | lock | action | SUPER+CTRL+Q, screen corner, Grassfield menu (in process). Only ever locks |
| lock | lid | action | lid switch: `config/hypr/grassfield/system.lua` → `/usr/lib/grassfield/grassfield-lid closed` (D-4). Only ever locks; `docked` in clamshell mode |
| lock | status, devReload, devPauseOwnershipCheck, devForgeUnlockedAnswer, devLockView | dev | `reload_locked.sh`, `l2_wrong_password.sh`; the pause widens the foreign-release window |
| idle | status, devSleep, devDisplayOff, devAutoSleep | dev | `reload_locked.sh`, `lock_privacy.sh`; `devAutoSleep` shortens the automatic sleep delay (the dev session never suspends) |
| saver | status, devDelay, devShow | dev | the screen saver's nested checks (ADR-0032): `devDelay` arms it after a test's delay, `devShow` shows it at once (refused while locked); off in a dev session otherwise |
| polkit | status | dev | registration state (the journal has it in a real session) |
| secrets | state | dev | the secret sheets' state (ADR-0035 D-9, step 9b): the bridge connection, the name's state, counts of the shown, held, waiting and lingering requests; never a requester or a text (`tests/security/secret_bridge.sh`) |
| search | toggle | action | SUPER+SPACE |
| search | clipboard | action | SUPER+CTRL+V (Search in its Clipboard view, ADR-0034; again closes it; refused while locked through `show()`) |
| search | open, close, query, status | dev | `status` returns what the user types; `query`/`open` inject a query |
| search | filter | fixtures | visual tests |
| clipboard | status | dev | returns the clipboard history's items: titles and excerpts are what the user copied (ADR-0034); a real session's helper is reached by no IPC function |
| emoji | toggle | action | SUPER+CTRL+SPACE (Emoji & Symbols, ADR-0045 OC-3; docs/specs/clipboard.md ES-1): opens the panel at the pointer (it asks Hyprland where the pointer is, `hyprctl cursorpos -j`, read only) or closes it; refused while locked through `SessionState.refuses`. It inserts nothing: only a choice in the panel does, into the window that was active when it opened |
| emoji | status | dev | the panel's state, counts and the last insertion's outcome (how many recents, whether a glyph waits: it tells what the user inserted) |
| anr | report | action | `packaging/session-bin/hyprland-dialog`, the stand-in Hyprland runs as its "not responding" dialog (ADR-0035 D-3). Only marks an app in Force Quit and its Dock menu ("(Not Responding)"); kills nothing, answers `ok` or `refused` (the reason goes to the journal only); refuses another compositor's report, a pid of 1 or below, and a window two processes share |
| anr | status | dev | returns the marked apps' window titles |
| activity | quit | action | Activity Monitor's Quit of a process that owns windows (`apps/activity/src/actions.cpp`, through `shellIpcArgs()`; ADR-0038 AM52, AM61): closes the windows whose client is that pid, as the Dock's Quit (an xdg close: the app may ask to save); answers `ok`, `no-windows` (the app then sends SIGTERM itself) or `refused` (a pid of 1 or below); never kills, reads no title; a shell reaches its own compositor's windows only (a nested session's, the nested ones) |
| picker | request | action | `packaging/session-bin/hyprland-share-picker`, the stand-in xdph runs as its screen-sharing picker (ADR-0035 D-6). Answers `accepted`, `busy` (one picker at a time), `locked` (refused while the session is locked, owner decision Q15) or `refused` (an id or socket not of the stand-in's form: a 128-bit hex id, a 128-bit hex name in `$XDG_RUNTIME_DIR/grassfield/picker/`); accepted, the shell connects to that socket only, shows the panel once the stand-in's window list has come, and answers one choice or a cancel there. The stand-in checks the answer again before xdph reads it (a listed window, a display Hyprland lists) |
| picker | status, choose | dev | `status` returns the open request and xdph's window titles; `choose` answers the open panel as the user would (`tests/shell/share_picker_ipc.sh`) |
| update | check | action | `packaging/shims/omarchy-shell` (Omarchy's update status from inside `omarchy update`, ADR-0033 U9: origin `omarchy`); Grassfield Settings and Grassfield Store (origin `user`: "Check Now", opening the pane); `packaging/bin/grassfield-pacman-watch` from `grassfield-pacman-watch.service`, started by its path unit when pacman's local database changed (ADR-0041 U31: origin `system`, announced as a scheduled check is). Runs Grassfield's own checker once (a running check is joined, never a second one), answers `ok`, or `refused` for another origin; returns nothing it found (the result goes to `software-update.json`, ADR-0020) |
| apps | toggle, open, close | action | XF86LaunchA, screen corner, 4-finger pinch |
| apps | status | dev | returns the typed query |
| apps | edit, removable, ask | dev | test hooks of deleting apps (ADR-0046): `edit` makes the icons jiggle, `removable <json>` gives the Store's answer instead of asking it, `ask <id>` is the badge's click: for a removable app it hands the app to the Store (`grassfield-store --page=uninstall:<entry>`, which opens the Store's own alert; the launcher shows none); refused outside a dev session; none removes anything (only Delete in the Store's alert does) |
| overview | toggle, open, close | action | CTRL+UP, screen corner, 3-finger swipe |
| overview | holdNextRelease, status, dropProbe | dev | `status` lists window titles and app ids; `dropProbe` (tiling step 6e, the follow-up of #78) runs the Overview's own drop of a window on a Desktop (ADR-0036 D72) and answers moved, refused or absent |
| backdrop | status | dev | returns the wallpaper paths and the luminance grids of the glass backdrop (ADR-0024 G-3 tests) |
| switcher | next, previous, release, quit, hide | action | SUPER+TAB, SUPER+SHIFT+TAB, SUPER release, SUPER+Q, SUPER+H while the switcher is up |
| switcher | right, left, cancel, status | dev | tests (arrows and Esc reach the switcher through its keyboard grab) |
| capture | toggle | action | SUPER+SHIFT+5 (`config/hypr/grassfield/bindings.lua`): opens or closes the capture toolbar (ADR-0045 OC-1); refused while locked (`SessionState.refuses`); starts no capture by itself: only the toolbar's own action runs `grassfield-capture`, after the user chose it |
| capture | open, close, status | dev | the toolbar's nested checks; `status` returns the toolbar's mode and options and the capture helper's phase, never a file name |
| windows | minimize, tile, arrange, tilePopover, nextOutput, hide, cycleApp, showDesktop | action | SUPER+M, SUPER+CTRL+arrows/R/U/I/J/K/RETURN/C, SUPER+CTRL+SHIFT+arrows and SUPER+CTRL+ALT+SHIFT+arrows (`arrange`: a layout of the catalogue), SUPER+CTRL+L (`tilePopover`: the tiling popover of the focused window), SUPER+CTRL+ALT+LEFT/RIGHT (`nextOutput`: the focused window onto the next output), SUPER+H, SUPER+`, SUPER+F3 (Show Desktop: moves windows aside and back, never launches or reads anything); the tiling functions move only the focused window and the next ones of its output, through the plugin's validated verbs (docs/specs/tiling.md TL26) |
| zoom | toggle, zoomIn, zoomOut | action | SUPER+ALT+8, SUPER+ALT+= and SUPER+ALT+- (`config/hypr/grassfield/bindings.lua`); change `accessibility.zoom` and `zoomLevel` only |
| notifications | toggleCenter | action | SUPER+N, screen corner (in process) |
| notifications | dnd, status | dev | `dnd` would let another process silence notices (security notices too) |
| notifications | invoke, clearAll, dismissAll | fixtures | runs another app's action / removes history |
| menubar | open, panel | action | CTRL+F2, SUPER+ALT+ESCAPE |
| menubar | close, openKind, keyboardWait, statusState, autohide, bridgeState, shown, band | dev | `bridgeState` returns the focused app's menu titles; `shown` the app the bar names and its app-menu count; `band` an output's band state (shown, blurred, the wallpaper luminance range under it, its tint alpha: no content) |
| widgets | status, addDesktop, clearDesktop | dev | `tests/visual/widgets-blur.sh`; `addDesktop`/`clearDesktop` change the saved placements |
| controlcenter | transparency, appearance, reduceTransparency, reduceMotion | dev | persisted settings changes |
| controlcenter | state | dev | `tests/visual/flow-quicksettings.sh`, `flow-settings.sh`: what the shell applies (appearance, transparency, DND, Night Shift availability); read-only |
| controlcenter | volume, brightness, volumeLevel, brightnessLevel | dev | `tests/shell/cc_sliders_ipc.sh` (REQ-QS-CC5/CC6); in a real session the acceptance uses the sliders themselves |
| dock | keyboard, toggleAutohide | action | CTRL+F3, SUPER+ALT+D |
| dock | reopen | action | a running single-instance app launched again while its window is off screen: Activity Monitor (`qs ipc -p <shell> call dock reopen org.grassfield.Activity`, apps/runmode.h shellIpcArgs; ADR-0038 AD34), Settings (`... dock reopen org.grassfield.Settings`, apps/settings/src/settingsinstance.h; ADR-0040 step 1b) and Grassfield Store (`... dock reopen org.grassfield.Store`, apps/store/src/storeinstance.h; ADR-0037 SD35). Brings that app's windows forward as a click on its tile does (a minimized one back, `Launch.activationPlan`); launches, closes and reads nothing; an id with no window in the Dock does nothing; refused while locked |
| dock | hover, unhover, reveal, menu | dev | UI automation for tests |
| dock | pinned, dragstate, forceinterrupt, forcehold, noactivate, holdmenu, popup, tiles, hidestate, screen, targetrect, autohide, size, position, sizenow, fitsize, magnify, click, centre, iconrect, stack, addfolder | fixtures | visual tests; `click` launches an app; `iconrect` reads the drawn icon rectangle; `noactivate` makes a Dock activation do nothing (click tests); `addfolder` changes `dock.folders` |
| dockstack | state, depth, enter, back | fixtures | visual tests of the open folder stack (it lists a folder's file names) |
| osd | display, hide, layout, state | dev | OSD spoofing (`layout` feeds a keyboard layout event) |
| volume | up, down, mute | action | volume keys |
| brightness | up, down | action | brightness keys |
| keyboard | up, down | action | keyboard backlight keys (XF86KbdBrightnessUp/Down) |
| capabilities | status, devBlock | dev | visual tests wait on `status`; `packaging/bin/grassfield-shell-watchdog` asks `status` as the shell's liveness question (ADR-0041 step 6a) and reads no answer: any answer, this `refused` of a real session included, is the GUI thread answering, so the gate stays and nothing is returned to it. `devBlock` holds the GUI thread 1 to 300 s (the probe's nested proof) |
| session | cover, lift | action | `packaging/bin/grassfield-session-end` once every window has gone (ADR-0040 ID-10): `cover` brings up the exit cover, one opaque fade to the ground over every output (it answers the fade's length and lifts itself after `session.exitCoverHoldMs`), `lift` takes it down when the session could not be ended. Neither ends the session; another process of the user can hide the desktop for that long at most |
| session | state | dev | the exit cover's nested check (`shown` or `hidden`) |
| security | state, heartbeat | action | the security process's own target (`shell/security.qml`, ADR-0041 step 1 S1, a second `qs` instance at `/usr/share/grassfield/shell/security.qml`): what it hosts (`starting` at S1) and a sequence number; read by `packaging/bin/grassfield-security-status` and the S1 measurements; never private state, nothing locks or unlocks |
| stages | activate, newStage | action | SUPER+ALT+1..4 (the n-th recent stage forward), SUPER+ALT+S (focused window to a stage of its own); they do nothing while Stages is off |
| stages | status, enable | dev | `tests/visual/scenarios/stages.sh`; `enable` changes the persisted setting |
| bartone | status | dev | visual tests |
| wallpaper | loadDelay, fadeLength, progress, onlineClock, onlineStatus, videoIdle, videoBattery, videoStatus, set, status, phase | dev | wallpaper tests (`set` also needs the fixtures to show; `phase` shows a phase of the day, ADR-0040 IQ-W1 C) |
| visual | glyphs | dev | contrast run |
<!-- ipc-inventory:end -->

### Private sockets of the security modules (not Quickshell IPC)
Grassfield processes that serve the security modules over a Unix socket of their own, outside `qs ipc` (ADR-0035
"Consequences": every such socket is listed here in the step that adds it).

| Socket | Server | Who may connect | What it carries |
|---|---|---|---|
| `$XDG_RUNTIME_DIR/grassfield/prompter.sock` (directory 0700, socket 0600) | `grassfield-prompter` (ADR-0035 D-9, step 9a; `grassfield-prompter.service`) | one peer at a time, running as the user, whose cgroup is the unit of the bridge's `--peer-unit` (`grassfield-shell.service`, only slices above it up to the user's manager), read through `SO_PEERPIDFD` (a peer without a pidfd is refused, except on a kernel without `SO_PEERPIDFD`); a refused peer gets `refused` and is closed, the refusals logged once per 10 s | `prompter/1` (docs/specs/system-dialogs.md section 5): the bridge sends the requests of gcr callers (with the requester it resolved from their bus credentials) and, from step 9c, NetworkManager's (kind `nm`, only for calls from the owner of `org.freedesktop.NetworkManager`) and, from step 9e, KIO's (kind `kio`, with the requester resolved from the caller's credentials) and, from step 10, bluetoothd's pairing steps (kind `bluetooth`, only for calls from the owner of `org.bluez`, and `progress` for a code shown), and their withdrawals; the shell sends its hello and its answers, a password once per answer. Nothing it accepts runs a command, unlocks, or reaches polkit; a wrong or unattributable line cancels requests, never invents an answer. The shell's client (`shell/security/secret/PrompterClient.qml`, step 9b) connects in a real session to this socket only, and in a dev session only to the test socket that `GRASSFIELD_PROMPTER_SOCKET` names (ADR-0019 dev plumbing, passed by `shell.qml`; ignored in a real session); it reads the bridge strictly and closes the connection on any line it does not expect |

### D-Bus objects of the security modules' processes (not Quickshell IPC)
What the processes serving the secret sheets export on a message bus (ADR-0035 "Consequences": listed in the step that adds
each one).

| Bus, name, object | Process | Who is answered | What it does |
|---|---|---|---|
| session bus, `org.gnome.keyring.SystemPrompter` (owned only while the shell is connected and has said hello), `/org/gnome/keyring/Prompter`, `org.gnome.keyring.internal.Prompter` | `grassfield-prompter` (step 9a) | any gcr client of the session (gcr's protocol has no authorization: name ownership is the whole of it, ADR-0035 D-9); at most 8 open prompts per connection, 64 in all | libgcr's `GcrSystemPrompter` (mode MULTIPLE): each prompt is identified from its caller's pidfd and handed to the shell; a password goes back through gcr's `sx-aes-1` exchange |
| session bus, `org.kde.kpasswdserver6` (requested with flags 0 only while a shell that draws kind `kio` is connected; queued behind a kiod6 that holds it; released 1 s after the shell goes, every open request answered first, unless kiod6 runs without it: then kept, and taken by a bridge that finds it so, until kiod6 leaves), `/modules/kpasswdserver`, `org.kde.KPasswdServer` (exported for the bridge's life) | `grassfield-prompter` (step 9e; ADR-0035 D-12 b, decisions 9-36 to 9-50) | any KIO client of the session (KIO's protocol has no authorization; who asks is resolved from the caller's pidfd, KIO's worker shown as `kio` only while it maps nothing but trusted code); at most 8 open requests per connection, 32 in all; AuthInfo bounded (InvalidArgs beyond) | `checkAuthInfoAsync`, `queryAuthInfoAsync` (the server sheet in the shell, held), `addAuthInfo` (answered at once; stored in the Secret Service through libsecret's asynchronous calls only when keepPassword says the user chose Remember), `removeAuthInfo` (the session cache only); each result a signal addressed to the caller's unique name, never broadcast; a call while no shell draws `kio`: answered as if nothing were known; the LEGACY `ay` methods not served |
| system bus, no well-known name (the bridge's unique name), `/org/freedesktop/NetworkManager/SecretAgent`, `org.freedesktop.NetworkManager.SecretAgent` (exported for the bridge's life; registered with NetworkManager as `org.grassfield.prompter` only while a shell that draws kind `nm` is connected) | `grassfield-prompter` (step 9c; the system bus is `/run/dbus/system_bus_socket` in the session, whatever the environment says; a development run only a private test bus) | only the current owner of `org.freedesktop.NetworkManager`, asked from the bus at each call (anyone else: `PermissionDenied`, nothing shown); the system bus's policy already lets only root send this interface | `GetSecrets` for Wi-Fi secrets (WPA/WPA2, WPA3, WEP, WPA2 Enterprise) when interaction is allowed, through the shell's sheet; `CancelGetSecrets`; `SaveSecrets` refused (nothing stored); `DeleteSecrets` answered; VPN and everything else `NoSecrets` (ADR-0035 9-27 to 9-35) |
| system bus, no well-known name (the bridge's unique name), `/org/grassfield/prompter/BluetoothAgent`, `org.bluez.Agent1` (exported for the bridge's life; registered with bluetoothd as a `KeyboardDisplay` agent, and asked to be its default, only while a shell that draws kind `bluetooth` is connected) | `grassfield-prompter` (step 10; ADR-0035 D-11, decisions 10-1 to 10-14; the same system bus as the NetworkManager agent) | only the current owner of `org.bluez`, asked from the bus at each call (anyone else: `org.bluez.Error.Rejected`, nothing shown); the system bus's policy already lets only root send this interface | `RequestPinCode`, `RequestPasskey`, `RequestConfirmation`, `RequestAuthorization`, `AuthorizeService` through the shell's pairing sheet (held until a click; never answered yes without it); `DisplayPinCode` and `DisplayPasskey` shown with Cancel alone, one at a time, until the device is paired, disconnects or is removed (Cancel asks bluetoothd to `CancelPairing` the device); `Cancel` withdraws the call awaiting a reply; `Release` (bluetoothd stopping) answered; every argument checked first (a device path of bluetoothd's form, a passkey of at most 999999, a PIN of 1 to 16 letters and digits, a canonical UUID) |

`grassfield-askpass` (step 9c), udiskie's password command, exports nothing: it is a gcr client of the session bus and writes
the passphrase on its standard output to udiskie, its parent (never to a terminal).

## Lock coverage: restart, Omarchy's sleep-lock, failing inhibitor (GF-030, D-12)
macOS model: the screen always locks before sleep, and the lock never silently goes away.
- `grassfield-shell.service`: `Restart=always` (was `on-failure`: systemd does not restart a unit that exits 0 or is
  stopped by SIGTERM/SIGINT/SIGHUP/SIGPIPE), `RestartSec=1`, start limit 10 starts in 5 minutes (ADR-0041 step 1a: the
  backstop of a crash loop; the first limit, 10 in 30 s, needed a crash within 2 s of each start and never tripped the
  loop of 2026-10-29, a crash 5 s after every start). The loop detector `grassfield-shell-failed.service`, started by
  `OnFailure=` after every failure next to Omarchy's sleep lock, counts the failures of the last 10 minutes
  (`$XDG_RUNTIME_DIR/grassfield/shell-failures`) and at the third cancels the pending restart (`systemctl --user stop`)
  and writes `$XDG_RUNTIME_DIR/grassfield/shell-safe-mode`, the state the security process of ADR-0041 step 1 reads from
  S4 on; a logout counts nothing (`session-gone`, the test the gate uses); a counter that cannot count (no runtime
  directory, no clock, an unwritable ledger) counts nothing and the restarts go on. The stop never unlocks: the
  compositor keeps the lock (below, "Lock survival"), and until S4 ships a stopped UI is what the start limit gave. Locked:
  the session stays locked and out of reach from itself (a lid close or a sleep brings the shell back through the
  stand-in, which asks it to lock; otherwise a TTY). Unlocked: no idle lock, and the lock key does nothing (SUPER+CTRL+Q
  is `qs ipc` to the shell, `config/hypr/grassfield/bindings.lua:148`); only a sleep or the lid locks, because Omarchy's
  sleep lock stays armed and its stand-in, like `grassfield-lid`'s fallback, starts the shell again and asks it to lock.
  Acceptable until S4 (the old start limit gave the same state; opus security review of b1d826b), written here so that
  nobody takes a stopped shell for a locked one. A frozen shell (its GUI thread blocked, the process alive) fails nothing
  by itself: `grassfield-shell-watchdog.timer` (ADR-0041 step 6a) asks it `capabilities status` every 30 s and, after three
  questions in a row of one MainPID left unanswered for 5 s (20 s while the kernel's pressure files show a loaded machine),
  sends that process SIGKILL (`systemctl --user kill
  --kill-whom=main`), so the unit fails and the path above applies: the restart, the sleep lock armed, the counter (a hang
  that repeats ends in its stop). The probe never stops or unlocks; the compositor keeps a lock across the restart.
  `tests/shell/shell_watchdog.sh`. Tests: `tests/shell/shell_failures.sh` (the decisions, with mutants), `tests/shell/unit_restart_limits.sh` (the lifetime
  model: a 10 s loop must end), `tests/security/sleep_lock_units.sh`. A stop through systemd is never restarted (systemd
  semantics): logout stops `graphical-session.target`,
  which stops the shell (`PartOf=`), and `Requisite=graphical-session.target` refuses a restart once the target is gone,
  so a real logout is not fought. `systemctl --user stop grassfield-shell` stays a deliberate stop.
- Omarchy's `omarchy-sleep-lock.service` (a logind delay inhibitor and a `PrepareForSleep` monitor; before sleep its
  `omarchy-system-sleep-lock` asks "the shell" to lock with `omarchy-shell lock lock` and polls `omarchy-shell lock
  status` until `secure`, within logind's window, else it reports "Screen did not lock before suspend"):
  - the drop-in `10-grassfield.conf` no longer disables it unconditionally (`ConditionEnvironment=!GRASSFIELD_SESSION=1`):
    its `ExecCondition=/usr/lib/grassfield/sleep-lock-gate` skips it in the Grassfield session only while
    grassfield-shell is up (`ActiveState=active` and `SubState=running`). `activating` is not enough (follow-up N1): it
    covers the auto-restart wait after a crash and the shell's start-up, when no Grassfield inhibitor exists. A unit
    skipped by `ExecCondition=` is not failed and not restarted (systemd.service(5)); Omarchy's unit exits after each
    sleep and is started again (`Restart=always`), so a running copy disarms itself after its next sleep once the shell
    is up.
  - When it runs: at session start it starts with `graphical-session.target`, usually before grassfield-shell, and keeps
    running until its first sleep; `OnFailure=omarchy-sleep-lock.service` starts it after EVERY crash of
    grassfield-shell, not only at the start limit (systemd 254+ `RestartMode=normal`, the default: the unit passes through
    `failed` before each restart; a clean exit, SIGTERM or `qs kill`, ends `inactive` and does not trigger it).
  - Logout (GF-081): `qs` exits 255 when the compositor goes away first, so every logout also fails the unit (255 stays a
    failure: it is also the exit code of a config error). The gate therefore skips only when the session's own compositor
    is certainly gone: its Wayland socket or its own Hyprland instance directory (never "some instance directory": stale
    ones accumulate) is absent with a searchable parent and a well-formed path. Anything undecidable (unreadable runtime
    directory, an over-long or odd name, a missing variable) arms the lock. The remaining race is on the safe side: if
    the compositor has not yet removed its socket, a logout arms the lock, which is harmless. The session target is not
    used: it still reads inactive when this unit starts at login. Test: `tests/security/sleep_lock_units.sh`.
  - It never talks to Omarchy's shell: in this session `/usr/lib/grassfield/omarchy-shims` is first in PATH, and its
    `omarchy-shell` stand-in answers `lock lock` by starting grassfield-shell again when it is not running
    (`reset-failed`, then a start) and asking it to lock (`qs ipc -p /usr/share/grassfield/shell call lock lock`: WlSessionLock +
    PamContext, no other locker), and `lock status` with `secure` = Hyprland lists `LOCK` on every monitor, `requested` =
    grassfield-shell's crash-recovery marker says `locked`. Every other call fails as Omarchy's wrapper does without its
    shell; nothing unlocks. Its clamshell step (`omarchy-hyprland-monitor-clamshell`, also called by Omarchy's wake
    script) reaches a second stand-in that runs `grassfield-lid reconcile`, so Omarchy's panel switching never fights
    Grassfield's (follow-up N4).
  - grassfield-shell never stops Omarchy's unit (it could be in the middle of a sleep it is delaying). Both running is
    harmless: Omarchy's script only asks grassfield-shell to lock and sees Hyprland's `LOCK`, without the 12 s delay or the
    false notice the drop-in was made for.
  - In the Omarchy session the gate always lets it run, exactly as Omarchy ships it.
  Checked by `tests/security/sleep_lock_units.sh` (the gate for every ActiveState/SubState, the unit and drop-in lines,
  both stand-ins against stubs, the package path) and `scripts/dev/omarchy-compat.sh` (Omarchy's script still uses the
  `lock lock` / `lock status` contract and calls the clamshell helper by name). Runtime NOT VERIFIED until the owner
  check below.
- The restart path re-locks after a sleep no shell locked for (follow-up N1; a crash or restart right before or during
  a sleep, when no inhibitor delayed it):
  - the crash-recovery marker records the kernel's count of completed suspends (`/sys/power/suspend_stats/success`,
    world-readable): `unlocked sleeps=<n>`. A starting shell that reads an `unlocked` line with another count than the
    current one locks (`LockMachine.sleptSince`, `restoreAtStart`; log "the machine slept while no shell could lock").
    A live shell locks before every sleep and rewrites the marker when it is unlocked, so a different count only means a
    sleep that happened without a shell. Unknown counts (an old line without a count, an unreadable sysfs file) prove
    nothing either way: no lock. Tests: `tst_lockmachine` `test_markerWithSleepCount`; `dev_gate.sh` starts the real Lock
    singleton offscreen on a marker with the previous count (locks), the current count and no count (both unlocked).
  - a shell whose `PrepareForSleep` watcher sees the resume (`false`) without having seen the matching `true` (it started,
    or its watcher came back, after the sleep began) locks at once (`SleepInhibitor.afterResume`, reason `resume`).
- The lid (`grassfield-lid closed`, follow-up N3): when `lock lid` gets no answer (shell down or starting) and no external
  display is connected, the `omarchy-shell` stand-in is run in the background (restart + lock), so a lid close with
  `HandleLidSwitch=ignore` or `lock` (no suspend, nothing else would lock) still locks; with an external display
  connected (clamshell) nothing is locked, as before. `tests/shell/lid.sh`.
- Known limit (owner): when grassfield-shell cannot start at all (a broken install), the fail-safe cannot lock either:
  Omarchy's script waits logind's window, reports that the screen did not lock (no notification server runs then: the
  journal has it) and the machine sleeps unlocked; a shell that starts later locks at once (the count rule above).
  A crash and a sleep within a few hundred ms (before Omarchy's unit holds its inhibitor) also sleep without a lock; the
  restarted shell then locks on resume, before any input. There is no second locker on purpose (security rules:
  WlSessionLock + PamContext in grassfield-shell only). Refusing sleep instead (a logind `block` inhibitor) was rejected:
  a closed laptop would then stay awake in a bag. A deliberate `systemctl --user stop grassfield-shell` is not a failure
  and does not start the fail-safe.
- Sleep inhibitor and `PrepareForSleep` watcher (`SleepInhibitor.qml`): never given up. An exit within 2 s of the start
  counts as a failure; after 5 in a row the module is "degraded": the user gets a notice in Notifications ("The screen
  may not lock before sleep", with the lock shortcut; Do Not Disturb silences its banner, the entry stays in the
  Notification Center), the journal says why, and the child is retried every 60 s instead of every 5 s. A run of 2 s
  resets the count and withdraws the notice. Whether a run lasted 2 s is timed by a Timer (`inhibitorHealthy`,
  `watcherHealthy`: a monotonic clock), never by `Date.now()` (review of 2dfd992: a wall-clock step forward made an early
  exit look long and hid the failure); a child that never started counts as a failure. A run counts only with progress
  (review of eee45cc: a hung child looked healthy): the inhibitor's command is `sh -c 'echo held; exec cat'`, which
  systemd-inhibit starts only once it holds the lock, so "held" proves it; the watcher's progress is gdbus' "The name
  org.freedesktop.login1 is owned by" line (`IdleModel.watcherSubscribed`): GLib prints it from the name watcher it
  starts after sending the signal subscription, and the bus answers a connection in order, so the match is then in
  place; gdbus' first line comes before subscribing and proves nothing (review of 100692f; from GLib's source order).
  A child without progress within 35 s (above the 25 s default D-Bus call timeout of sd-bus and GDBus, so a slow but
  healthy logind is not killed on every retry; `IdleModel.PROGRESS_BUDGET_MS`,
  `inhibitorProgress`, `watcherProgress` Timers) is stopped and counted as a failure, so a hung child leads to the
  degraded notice too. Pure logic in `IdleModel.js` (`failuresAfterRun`, `retryDelayMs`, `degraded`), unit-tested in
  `tst_idlemodel.qml`; the wiring is checked by `tests/security/lock_surfaces.sh` (with mutants). Real-session
  behaviour of the progress lines: NOT VERIFIED here (no system bus in the sandbox; L2).
- No wall clock in `shell/security`: every delay is a Qt Timer. The lock ownership check skips Hyprland answers for
  500 ms after the compositor confirmed the lock (`Lock.qml` `secureGrace`, single-shot Timer; with `Date.now()` a clock
  step back turned the check off for as long as the step, review of 2dfd992); a Timer that is not running means no
  window, so the check stays on. The only `Date` left is the arrival time the held polkit sheet prints (`new Date()`,
  display only). `tests/security/lock_surfaces.sh` fails on any `Date.now`, `getTime`, `performance.now` or other
  `new Date(` in shell/security (comments excluded), with mutants.
- Sleep delay budget: the release timer was 4 s, below logind windows of 15 s that Omarchy ships
  (`InhibitDelayMaxSec=15`, because a lid close that reconfigures displays can take longer to lock). It is now derived
  from logind's `InhibitDelayMaxUSec` (`busctl get-property`, read once at start): window minus a fifth (at least 1 s),
  capped at 12 s, 4 s when unreadable (port of Omarchy's `omarchy-system-sleep-lock` `derive_budget_ms`, MIT). The delay
  still ends at once on a confirmed lock.

Owner check (real session, L2-12 addition): `systemctl --user kill -s SIGTERM grassfield-shell.service; sleep 3;
systemctl --user is-active grassfield-shell.service` → `active`; `systemctl --user show -P ActiveState
omarchy-sleep-lock.service` → `inactive`; `systemd-inhibit --list | grep -c Grassfield` → `1`, and no `Omarchy` line.
Fail-safe (owner, L2†, from a TTY or a terminal you can leave): `systemctl --user stop grassfield-shell.service;
systemctl --user start omarchy-sleep-lock.service` (stands in for the start-limit failure), then `systemctl suspend`
and wake: the Grassfield lock screen is shown before any content, and `journalctl --user -u omarchy-sleep-lock -b`
has no "suspending without a secure lock" line.

## Graceful exit while locked (SEC-18 / GF-029, DT-21)
Read in the sources (Quickshell v0.3.1, `quickshell-mirror/quickshell@v0.3.1`; Hyprland v0.56.2,
`hyprwm/Hyprland@v0.56.2`):
- `qs kill` sends an IPC kill: `IpcKillCommand::exec` → `EngineGeneration::quit()` → `destroy()`: the root object is
  deleted, then the JS engine is interrupted (`setInterrupted(true)`) and deleted. The Lock singleton is owned by the
  engine (registered in `SingletonRegistry`, no parent), so it is destroyed with JS interrupted: no binding of
  `Lock.qml` can run and set `WlSessionLock.locked = false` during teardown.
- `WlSessionLock` has no destructor that unlocks; its `SessionLockManager` child deletes the `QSWaylandSessionLock`,
  whose destructor sends `ext_session_lock_v1.destroy`, NOT `unlock_and_destroy` ("This will intentionally lock the
  session if the lock is destroyed without calling unlock", `src/wayland/session_lock/lock.cpp`).
- Hyprland 0.56.2 handles `destroy` like a dead client: `CSessionLock` is destroyed, the manager drops its lock state
  (lock surfaces gone, the "lockscreen app died" screen), and `PROTO::sessionLock->m_locked` stays true: only
  `unlock_and_destroy` sets it false (`src/protocols/SessionLock.cpp`). The session stays locked.
- SIGTERM: Quickshell installs crash handlers for SIGSEGV/SIGABRT/SIGFPE/SIGILL/SIGBUS/SIGTRAP only
  (`src/crash/handler.cpp`); SIGTERM's default action ends the process at once, which Hyprland sees as a dead client.
- Either way the restarted shell (`Restart=always`) finds the marker `locked` and takes the lock back.
Expected: locked in both cases. NOT VERIFIED at runtime until the nested `graceful-exit` step of
`tests/security/reload_locked.sh` runs (bare, outside the sandbox): (a) `kill -TERM`, (b) `qs kill --pid`; after each,
Hyprland lists `LOCK` on every monitor and nothing typed reaches the probe window; then the restarted shell reports
`locked`. No code change was needed for this item; if the step ever shows an unlock, the shell must refuse IPC kill
while locked (not possible in Quickshell 0.3.1) or the unit must restart it before input arrives.

## Nothing opens over the lock (GF-116, DT-08, DT-12)
macOS model: while the screen is locked only the lock screen exists; Spotlight, Mission Control, Launchpad, Control
Center, Notification Center, menus and the Dock do not open, and nothing waits behind the lock to appear at the unlock
except an authorization request. Hyprland already keeps rendering and the keyboard on the ext-session-lock surfaces; the
shell no longer relies on that alone:
- One predicate, `SessionState.refuses(surface)` (`shell/services/SessionState.qml`): true while `SessionState.locked`
  (bound in `shell.qml` to `Lock.locked`, i.e. locking, locked or authenticating; unknown states count as locked), with one
  log line `grassfield: <surface> refused: the session is locked`. Each entry point asks it first: `Popups.open` (every
  popup kind: Control Center, menu-bar menus, tray, Dock menus and stacks, About, Force Quit, confirm and notice sheets;
  `toggle`, `openCentered`, `confirm` and `notice` go through `open`), `Search.show`, `AppsController.show`,
  `Overview.show` (also its own `locked`), `Notifications.toggleCenter` / `openWidgetGallery`, `Dock.enterKeyboardMode`,
  the desktop's context menu and attribution card (`IconsView.openMenu` / `openAbout`), the widget menu (an Overlay
  layer with the keyboard, `DesktopWidgets` `onMenuRequested`; review of 1d2c856), and the window commands of IPC target
  `windows` (minimize, tile, arrange, tilePopover, nextOutput, hide, cycleApp). The Switcher already refused
  (`Switcher.step`). Bindings, IPC calls, screen corners and gestures all end in these entry points, so all are refused.
  Built in tiling step 3 (ADR-0036, `docs/specs/tiling.md` TL22-TL26, TL34): the tiling popover is popup kind `tiling`,
  opened only through `Popups.open` (services/TilingHover, on the plugin's `tile-hover` event or Super+Ctrl+L), and the
  `windows` functions `arrange`, `tilePopover` and `nextOutput` refuse first; the popover closes with every popup when the
  lock engages. Built in tiling step 4a (TL27, TL28): the Layouts section is part of the popover; the suggestions are popup
  kind `tilingSuggest`, opened only through `Popups.open` by services/TilingSuggest, whose `show` asks
  `SessionState.refuses("tiling suggestions")` first, then refuses them over the polkit sheet, a full-attention surface and
  the Dock's keyboard mode (`TilingHover.refusedBy`) and in place of any popup but the tiling popover; they close with every
  popup when the lock engages (and the suggestion is dropped: nothing reopens it after the unlock). Built in tiling step 4c
  (TL30): the shared-edge handle draws no surface; the plugin shows its cursor and takes its press only when the session
  is not locked, no foreign Exclusive layer or layer covers the point and no other window, titlebar or popup is in front
  of it (Hyprland's own pointer-focus hit test: the frontmost window under the pointer gets the click), and a drag in
  progress ends the moment the lock engages (Hyprland's session-lock event: the windows keep the boxes the motions before
  the lock reached, the handle's cursor goes, the release it owes is still cancelled); no input after the lock moves a
  window. The frame probe's loop records (the event loop's stalls and the plugin's own drag work, compositor.md FR54) follow
  its other records: kept only while a measurement records, never while locked, dropped when the lock engages.
  Built in tiling step 1 (plugin, defence in depth behind the shell's refusal): `hl.plugin.grassfield.tile` and
  `hl.plugin.grassfield.arrange` refuse while the session is locked (`tiling` notice with `reason:"locked"`, no window
  moves). Tiling step 2 adds no IPC function: the drags it tiles (Hyprland's own move, an app's toolbar or
  Super+drag) and the double-click on a resize border are pointer gestures Hyprland does not start on a locked session; the
  plugin checks the lock again when it would tile after such a release and then moves nothing. Tiling step 3:
  `hl.plugin.grassfield.move_to` refuses while the session is locked (`tiling` notice with `reason:"locked"`, no window
  moves); the `tile-hover` event and `hl.plugin.grassfield.tile_popover` (which only posts that event) change nothing by
  themselves: the shell refuses the popover (`TilingHover.show` asks `SessionState.refuses` first, and refuses it over the
  polkit sheet, a full-attention surface and the Dock's keyboard mode), and the plugin posts no hover while the session is
  locked, while another Exclusive layer than the shell's popups is mapped or while a layer covers the light (integrator
  review of 4ead6fb). Tiling step 4a: `arrange` with `zone` and `with` (a zone of the Layouts section, a pick of the
  suggestions) is refused while locked like every `arrange`; the suggestion in the `hyprctl grassfield-tiling` reply is read
  only by the shell after its own arrangement, and lists window addresses only (no titles, no contents). Tiling step 4b
  (TL29): `hl.plugin.grassfield.group_front` refuses while the session is locked (`tiling` notice with
  `reason:"locked"`, no window is raised) and for an unknown window (`reason:"invalid"`); it only changes the stacking
  order of windows already on screen (no move, no focus, no tile record). The shell sends it only through
  `Compositor.groupForward`, which asks `SessionState.refuses` first, from entry points the lock already refuses (a Dock
  click or tile, a Dock menu row, the app switcher, the Overview's choice, the menu bar's Window menu); a Dock menu row or
  Show Tile Group runs once the menu's surface is gone (`Compositor.runPendingActivation`), which refuses too when the lock
  engaged meanwhile (no Desktop switch, no restore: a restore is not refused while locked, GF-116; integrator review of
  cd74af2). lock_surfaces.sh checks these refusals and that every entry point goes through them, each with a mutation.
  No IPC function or popup kind is added; the groups the shell reads from the `hyprctl grassfield-tiling` reply are window
  addresses and group numbers only. Tiling step 6a (TL33, the Split View Desktop): `hl.plugin.grassfield.split` (Full
  Screen › Left or Right of Screen: a new Desktop shown, the window in its half) and `hl.plugin.grassfield.unsplit` (a
  Split View window's Exit Full Screen: back to its home Desktop) refuse while the session is locked (`tiling` notice with
  `reason:"locked"`, no Desktop is made or shown, no window moves) and for an unknown window, a side other than left or
  right, a window of no Split View Desktop or while the Stages strip shows (`reason:"invalid"`). The shell sends them only
  through `Compositor.split` and `Compositor.unsplit`, which ask `SessionState.refuses` first (the popover's Full Screen
  submenu and the Window menu, both refused surfaces while locked). A Split View whose picker ended without a second window
  fills through `Compositor.fillAlone` and `Compositor.tile`, which both ask `SessionState.refuses` first (integrator
  review of c7a6b6e, MAJOR 2: `tile` did not), and services/TilingSuggest computes no window to fill while locked (it
  sends the fill at the unlock). What the plugin does on its own after a member left (the other fills, an empty Split View
  Desktop shown goes back home) moves only windows of that Desktop and shows no new surface, and none of it happens behind
  the lock screen: the lock ends a pending picker, and the fill of a lone member or the end of an emptied Split View
  Desktop waits for the unlock (integrator re-review of e5bd9d2). The Split View Desktops the shell reads from the
  `hyprctl grassfield-tiling` reply are Desktop ids, output names and window addresses only. lock_surfaces.sh checks the
  four refusals and the fill path, each with a mutation; tests/shell/split_view checks them on the real singletons.
  Tiling step 6c (ADR-0036 D64-D68) adds no IPC function, verb or popup kind. The plugin's `titlebar-reveal` event carries
  an output name and a boolean only, and is never posted `true` while the session is locked (a full-screen titlebar is
  not revealed then); the shell only keeps the menu bar of that output in view with it. A click on the green light under the
  tiling popover runs `Compositor.unsplit` (which asks `SessionState.refuses` first) or Hyprland's own full-screen and Zoom
  requests, from the popover, a surface the lock closes and refuses. The plugin's gathering of a window left off every
  output after an unplug moves only that window, shows no surface, and waits for the unlock when the session is locked (as
  a Split View's settling, D55).
  Tiling step 6d (ADR-0036 D71, D72) adds no verb, event or popup kind: `hl.plugin.grassfield.unsplit` takes an optional
  second argument (desktop|fullscreen|replace, anything else `reason:"invalid"`), refused while the session is locked like
  every `unsplit` (`reason:"locked"`). The shell sends it only through `Compositor.unsplit`, which asks
  `SessionState.refuses` first, from the tiling popover and the Window menu (refused surfaces while locked). Replace Tiled
  Window's picker is the Split View picker of step 6a (its suggestion lists window addresses only). The Overview's drop rule
  only refuses drops.
  Tiling step 6e (ADR-0036 D73-D76) adds no verb, event field or popup kind: the feature `tiling-split-titles` only tells the
  shell's Overview to lay a Split View member out without a strip. A member's hidden titlebar is revealed and takes presses
  by the full-screen path (P6): never while the session is locked (`revealable()`), never under a layer popup or an Overlay
  layer, never a press of a button another device holds; its press and release are cancelled together. A member's drag by
  its revealed bar ends the moment the lock engages (the member back in its half; its release, still owed, stays
  cancelled and swaps nothing), and on another press or a pointer device gone. A window that leaves a Split View is placed
  below the menu bar only once the session is unlocked (D73 amended, review of #99). The development hook `overview dropProbe`
  (D76, the table above) answers "refused" outside development and only ever refuses or performs the Overview's own drop.
- When the lock engages each open surface closes: Popups, Search (its query is dropped), Apps, the Notification Center,
  the Overview (through its keyboard release), the Switcher, Dock keyboard mode, the desktop menu and card (the desktop
  lets the keyboard go), the widget menu. `Lock.lock()` also closes popups first.
- Polkit: a request that arrives while locked waits (macOS shows the authorization sheet after the unlock): the sheet is
  neither mapped nor given the keyboard until `SessionState.locked` is false; text typed into an open sheet is dropped when
  the lock hides it. Nothing is answered meanwhile (polkit keeps the request pending; Cancel/Esc work once shown).
  A held request (it arrived, or was open, while locked, or arrived within 1 s after an unlock,
  `AuthDialogModel.heldAfterUnlockMs`, review of d8e654c) appears WITHOUT the keyboard (review of 1d2c856: keys typed right
  after the unlock, the end of the lock password or a Return, landed in its field): it says
  "This request arrived at <time>, while the screen was locked. Click the sheet to answer it.", its field is empty, and
  it takes the keyboard only after a click on the sheet that comes at least 500 ms (`AuthDialogModel.heldGuardMs`) after
  it appeared (the click goes on to what it hit: the field, Cancel, Allow). Both delays are timed by Timers in the model
  (`noteUnlock`, `noteShown`; a monotonic clock), never by `Date.now()` (review of 6e24d36: a wall-clock step would stretch
  or end a hold); a click before the sheet was ever noted as shown does not count. polkit gives no program name to the agent
  (only the message, which names the program for pkexec). The screen saver holds a request the same way (ADR-0032, owner
  decision 2026-10-26: over the opaque saver an unheld sheet looked like the lock's prompt and took the keys at once): one
  that arrives while `SessionState.saverShown` (a mirror of the saver, set in shell.qml), or is open when the saver comes up
  (its field emptied), is held and says "…and waited while the screen saver was on"; while the saver shows a press (any
  button) or the wheel on the sheet goes nowhere (the waking input), and when the saver ends the click guard starts over
  (`noteUncovered`), so no click in the next 500 ms gives the sheet the keyboard, whichever of the press and the saver's end
  comes first (such a click still reaches the control it hits, as after an unlock: Cancel at worst; Allow with an empty
  field does nothing). The saver keeps the keyboard meanwhile (the held sheet takes none). Fail mode: a wrong
  `saverShown` never releases a hold; a wrong false (the Binding lost) brings back a sheet that takes the keyboard over the
  saver, a wrong true holds every request and swallows every press on the sheet until the requester gives up (only the
  shell.qml Binding writes it; `lock_surfaces.sh` checks that it is the only writer in shell/, apps/ and ui/: no
  assignment, no other Binding or object property, no other quoted name). Two requests close together (reviews of f513b3b and
  b5d7657): Quickshell 0.3.1 never queues; a request that arrives while one is open replaces it at once (the flow
  switches without `active` changing; the replaced one is abandoned, never answered, which fails closed), and one that
  arrives after the previous ended passes through no request. Both are held, "…right after another one": the replacing
  one with its field emptied and its guard started over, and, if the user was typing into the sheet, with the keyboard
  kept on a key sink, so the rest of a password and its Return reach neither field nor the window underneath; the next
  one within 1 s (`AuthDialogModel.afterRequest`) like one after an unlock. Whether a request is in the sheet is a flag
  (`flowShown`), never the previous flow read back (a reference to a destroyed flow reads null; review of
  9ad4307..b38618f); should Quickshell destroy the abandoned flow before it hands over the next one, the model's flow
  goes through null, the open request ends there, under the user's typing, so the sink lingers (below), and the next one
  is held as one right after another and keeps the sink (`authagent_flows.sh` test_01b). A replacement
  behind the lock or the saver keeps saying why it waited. The sink (checks of 38dbfe8 and c1ca44f): while it has the keys the sheet's field and identity
  rows are disabled (`AuthDialog.inputEnabled`; its `focusField` does nothing then) and any focus the sheet gets goes back
  to the sink (a press on one of its controls within the guard, the sheet focusing its field when it loads or after a
  failure, which a same-user process can cause by killing the helper, or the window activated with the sheet's scope
  focused, which is how a focus given while the window has no keyboard arrives), so no key reaches the held request's
  field until a click past the guard; Esc on it cancels the held request (fails closed). A request that ends while the
  sink has the keys (its requester gave up, or the request it replaced completed and Quickshell ended the current one),
  or that ends unanswered while the sheet has the keyboard (security counter-review of f9e24e1, LOW-1: its requester gave
  up, timed out or was destroyed while the user typed its password into its own field, and the rest of the password went to
  the window underneath), leaves the window mapped with the keyboard on the sink, until no key came for 1 s, at most 3 s
  (`sinkLingerMaxMs`), or a click, the lock or the saver; one that arrives meanwhile is held and keeps the sink.
  "Unanswered": the user neither sent a password nor cancelled since polkit last asked (`AuthDialogModel.answered`: set by
  `submit` and `cancel`, cleared by a failure, a new prompt or a new request, never when the request ends, so the agent
  still reads it then); a request the user answered gives the keyboard back at once, as on macOS (a first Esc in a field with
  text only empties it: not an answer). The linger is perceivable (LOW-3): where the sheet was, a card of the sheet's
  material says "Request cancelled" and "What you type is ignored for a moment." (fixed, translated text, nothing of the
  requester's; no control, no focus: a press on it reaches the backdrop, which ends the linger, and the keys stay on the
  sink; blurred like the sheet), only while the sink lingers (not over a held request's sheet). The window's `visible`
  and `takesKeys` read the base state only (`requestOpen`, `locked`, the hold, `sinkingKeys`), and `arrive` starts the
  linger from it too: through an intermediate binding (`shown`, `lingering`) a change could be read before that binding saw
  it, so the window went unmapped for a moment (a hidden PanelWindow is destroyed and made again, the compositor giving the
  keyboard to the window underneath until the new surface maps) or the linger's timers never started. `requestOpen` is the
  agent's own record of the request in the sheet, written only by `arrive` and never the model's `active`: at an end
  `arrive` first reads whether the window had the keyboard, sets the sink, then lets `requestOpen` go, and changes the hold
  after it (at an arrival it sets the hold before `requestOpen`), so the window never unmaps nor asks for the keyboard for
  a held request on the way, whichever binding sees the end first (in this Qt the agent's handler runs first, so the
  harness cannot tell the two apart: `lock_surfaces.sh` pins both). Upstream (for the upstream researcher; read in the
  0.3.1 sources, not run):
  the replaced request's flow and `AuthRequest` are overwritten without being deleted or answered (agentimpl.cpp
  initiateAuthentication), so they leak with the first helper session alive and its client waiting; a later cancel of it
  only logs a warning. Its completion can still end the current request (`isCompletedChanged` stays connected to
  `finishAuthenticationRequest`), which the linger above covers. Queuing a new request instead of replacing the open one
  upstream would remove the lever. Tests: `tst_authdialogmodel` `test_heldGuard` (with `noteUncovered`),
  `test_heldJustAfterUnlock` (real timers), `tst_authdialog` `test_11_heldNotice`, `test_heldJustAfterAnotherRequest`;
  `tests/security/authagent_flows.sh` (the real AuthAgent.qml with its Quickshell types replaced, `make_harness.py`: every
  flow order Quickshell produces, every way the focus can move while the sink holds, the linger and what ends it, with real
  key and mouse events; with `--panel`, in `FakePanel.qml`, a window made again each time it is shown and given the keyboard
  only once mapped, beside a window underneath, the end of a request under the user's typing in every order, the flow
  destroyed included (`window.qml` test_04: nothing typed after it reaches the window underneath, the window is never made
  again, the keys go there again after the linger; it fails on f9e24e1); `--mutants` brings back each defect the reviews
  found and checks it is caught: 26 mutants);
  `tests/security/lock_surfaces.sh` (wiring, the saver's Binding and that it is the only writer of `saverShown`, one place
  that gives the keyboard and three that take it
  back, three that set the hold, the stacking of the sheet and its two guards, each hold Timer used only in its own
  functions, the key sink, `typing` read first (with the end under the user's typing), the six places that release the sink,
  the places that focus the field and the sheet's disabled input, the linger's timers and its start, `visible` and
  `takesKeys` from the base state (`requestOpen`, written only by `arrive`, in its order), `answered` set and cleared only
  where it may be, the ended notice (only while lingering, fixed plain text, no input or focus), no `Date` in the hold
  functions, 57 polkit mutations). Seen on screen: NOT VERIFIED (L5; the ended notice too).
- Not refused, on purpose: the lock itself (`lock lock`, `lock lid`), volume/brightness keys and their OSD (macOS changes
  volume on the lock screen; the OSD is under the lock surface), notifications arriving (banners are under the lock surface;
  previews follow "Show previews").
- Plugin restore path (DT-12): `hl.plugin.grassfield.restore` still un-minimizes behind the lock and asks for a focus
  Hyprland refuses; the fix is a plugin work item, `docs/specs/compositor.md` "Work item GF-116".
- Fail mode: if the shell's `SessionState` wiring were missing, surfaces would open under the lock surface (Hyprland still
  shows only the lock and keeps the keyboard there); no path of this change can unlock or hide the lock.
Tests: `tests/security/lock_surfaces/shell.qml` (headless, the real Search, Apps, Notifications, Overview and Popups:
control open while unlocked, the tiling popover's own guard (refused over Search, Apps, the polkit sheet and the Dock's
keyboard mode, another window's popover closed first) and of the suggestions (refused in place of another popup and over
the same surfaces), all close at the lock, 19 popup kinds and every entry point refused
while locked, open again
after; mutants removing a refusal fail it), `tests/security/lock_surfaces.sh` (static: wiring, first-decision refusals,
close-on-lock, IPC routes, screen corners, the polkit sheet; mutation self-test). Nested (bare, outside the sandbox):
`tests/security/lock_privacy.sh` step `privacy` tries every surface over the lock and checks the captures (DT-08).

## Files never runs what it opens (GF-070, SEC-12, DT-10)
macOS model (Gatekeeper): double-clicking a downloaded app, script or launcher does not run it; macOS says it was not
opened, and only a deliberate "Open Anyway" in System Settings runs it. Grassfield Files decides itself, before KIO
(`KIO::OpenUrlJob::setRunExecutables(false)` documents executables but not every `.desktop` case; KIO's source is not on
the host): `apps/files/src/launchguard.{h,cpp}` `LaunchGuard::verdict(inspect(url))` for every item `FilesApp::open`
gets (double-click, File > Open, Ctrl+Down, the context menu; Return renames), before the scripted-test switch:
- A desktop entry (named `*.desktop` / `*.kdelnk` / `.directory`, or of type `application/x-desktop`) is never handed to
  KIO, with or without the permission bit, wherever it is (review of a5646b8: KIO downloads a `Type=Link` target and runs
  the handler of the type the server announces, or the application in `X-KDE-LastOpenedWith`; the reviewer ran an
  attacker-chosen handler on a downloaded `.msi`). A web link (exactly one `Type=Link` and one http(s) `URL` with a host,
  like a `.webloc`) opens ITS ADDRESS in the user's default web browser (`x-scheme-handler/http(s)` preferred
  application, `ApplicationLauncherJob` with the URL), nothing else; with no default browser it is refused. Any other
  entry is refused, "app launcher": `Type=Application`, `Service`, a missing or unknown Type, an unreadable file, a link to
  a file or another scheme, and an ambiguous entry (a repeated `Type` or `URL`, also across repeated groups, or `URL` with
  `URL[$e]`: KConfig keeps the last value; or longer than the 64 KiB read).
- Refused, "program or script": an executable regular file whose type is a program or script (shared-mime-info:
  `application/x-executable` and its sub-classes, scripts included; `x-pie-executable`; `x-sharedlib`), or that starts
  with `#!` or the ELF magic; and, even without the permission bit, types whose handler runs them (by type and by name):
  Windows programs and scripts (`.exe`, `.com`, `.scr`, `.cpl`, `.msi`, `.lnk`, `.bat`, `.cmd`, `.ps1`, `.vbs`, `.vbe`,
  `.wsf`, `.hta`), registry files (`.reg`), Java archives and Web Start files (`.jar`, `.jnlp`), AppImages.
- Remote items (a share, sftp, the Trash): desktop entries and the names above are refused (KIO downloads a remote file
  and runs the handler of its type); everything else goes to KIO as before.
- Opened as before: folders, documents (also with the permission bit: every file of a FAT/NTFS volume has it), scripts
  without the permission bit (text, in their editor, as KIO and macOS do).
- The user sees one banner: "“t.desktop” was not opened: it is an app launcher, and Files never starts apps from a folder.
  Open apps from the Dock, Apps or Search." (programs: "… To run it on purpose, use a terminal."); the journal gets
  `grassfield-files: open refused (<kind>)`. No "Open Anyway" in Files, on purpose: Grassfield has no signed-app notion to
  base it on, apps start from the Dock, Apps and Search, and a program the user trusts runs from a terminal. "Open With"
  is unchanged: it opens the item WITH the chosen app (a launcher in a text editor), it never runs the item.
- The Applications location (`grassfield-apps:/`, macOS: Finder's Applications) is the one place where Files starts an
  application, and it is not an exception to the rule above: its items are not files and have no path. They are the virtual
  urls `grassfield-app:/<id>` of the apps the shell's Apps grid lists (`ApplicationsLogic`); double-click, Ctrl+O/File > Open and Ctrl+Down call `FilesApp::launchApplication` instead of `FilesApp::open` (`BrowserTab.activate`/`openSelection`), so
  no `.desktop` file of a folder is ever handed to KIO and `LaunchGuard` is not bypassed for one. The id must resolve to an
  INSTALLED service in KDE's database (`KService::serviceByStorageId`); the process is started the way the shell's
  Apps grid starts an entry (`Apps.launchNow`): the service's `Exec=` split and stripped of its field codes
  (`ApplicationsLogic::launchCommand`, no URL argument, no shell), behind `xdg-terminal-exec` for `Terminal=true` (KIO's job
  would ask KDE's terminal setting, konsole, absent on Omarchy), under `uwsm-app` in a real session (`apps/appscope.h`); an
  entry with no `Exec=` is left to `KIO::ApplicationLauncherJob`. The list itself is built on a worker thread, every
  `.desktop` is opened without blocking and only if it is a regular file, and at most 5000 folders are walked. `GRASSFIELD_FILES_NO_LAUNCH` blocks it. Open With
  is not offered for these items and `FilesApp::openWith`/`applicationsFor` refuse them (a desktop entry is not a file to
  open with another app: Kdenlive was offered for `*.kdenlive`). An absolute `Icon=` of an entry is read only if it is a
  regular file within 8 MiB under the shell's allowed roots, read from the descriptor that was checked (`ApplicationsLogic::
  readIconFile`; a FIFO hung the GUI thread), and then decoded by `AppIcons` (`apps/files/src/appicons.h`) on a worker
  thread of the image://appicon provider (the theme provider image://icon stays synchronous: Qt calls an asynchronous one off the GUI thread and QIcon is not thread-safe), never on the GUI thread: only PNG (magic bytes; the header size must be within 1024 x 1024
  before the pixels are decoded; a 64 MiB allocation limit) and SVG (UTF-8, at most 512 KiB, 64 levels, 64 `<use>`, and
  nothing that names another file: no DTD, entity, processing instruction, script, foreignObject, `<image>`/`<feImage>` at all (QtSvg opens even `#name` as a file relative to the cwd), a `<use>` of an element that holds a `<use>`, `href` other than `#id`
  (a data: image included), `xml:base`, CSS `url()` other than `#id`, at-rule or escape). Every other Qt image plugin (PDF,
  TIFF, ICNS, JPEG, ...) is refused; the shell's out-of-process `image-copy.py` is not available to Files. Qt 6.11's SVG
  reader follows `<image href>` to any file and has no option against it (probed with `QtSvg::Options`: a href to a FIFO
  blocks with every option), so the document is checked before Qt sees it. A refused icon shows the generic application
  icon. The decode itself runs OUT OF PROCESS (`AppIcons::loadIsolated`): the checked bytes go to a child of the Files binary
  (`grassfield-files --decode-icon <w> <h>`, stdin to a PNG on stdout) with RLIMIT_AS 3 GiB, RLIMIT_CPU 10 s, no core file and
  PDEATHSIG; the parent only decodes the PNG its child made. A decode that has not ended after 3 s is killed (generic icon, not
  tried again in the run) so a slow icon cannot starve the others; `aboutToQuit` kills every child and waits at most 3.5 s
  for the 3 workers (a start's 2 s plus the 1 s after the kill), and joins the Applications listing thread within the same
  bound. An `atexit` hook does the same for an exit that skips `aboutToQuit`; it is registered again after the first decoder
  starts, so it runs before the statics a decode creates. That narrows the exit race without removing it; Files never calls
  `exit()`, so a normal quit goes through `aboutToQuit` (an in-process decode crashed Files at exit, SIGSEGV in QtSvg, round 4
  review). SVG work is bounded too: at most 5000 elements, and no `url()` inside a `<marker>` or `<pattern>`
  (a marker using a marker took 7.5 s at 300 x 300 vertices and over 2 minutes at 3000 x 3000). Limits that are NOT static: other
  multipliers pass the allowlist (a mask under 60 `<use>`, filters, deep gradients); only the child's 3 s deadline, 10 s CPU limit
  and memory limit bound them, by design. The child reads the icon to EOF (up to the 4 MiB cap), so icons over the 64 KiB
  pipe size decode; `tst_imageproviders.cpp` writes a 270 KB PNG and a 100 KB SVG in pieces. Of the 31518 SVG icons
  installed here the rule accepts 28128, the same as before; none of them has a `<marker>` element (the 25 marker icons of the
  review were not found under /usr/share/icons). Tests: `tst_imageproviders.cpp` (deadline, no starvation, shutdown kills the
  children, quit during a decode in a child process: normal exit code, no signal, with and without `shutdown()`),
  `tests/unit/files/tst_appicons.cpp` (FIFO named by hostile SVGs in 14 spellings, a PDF named .png, JPEG/GIF,
  an 8100 x 8100 PNG, a header claiming 20000 x 20000, valid PNG and SVG). Copy puts the entry's file on the clipboard; Cut, Rename, Trash, Paste into it and drops are refused
  with the permission message.
- The desktop already never runs `.desktop` files (`DesktopFiles.qml`, DT-11). The shell's `gio open` / `xdg-open` paths
  (Search results, Dock stacks) hand files to their MIME handler; not changed here.
Tests: `tests/unit/files/tst_launchguard.cpp` (verdicts; DT-10 on real files: `t.desktop` executable and not,
`Invoice.pdf.desktop`, web links to the browser only (the review's `.msi` link with `X-KDE-LastOpenedWith` included),
repeated keys, an oversized entry, `.directory`, file links, an unreadable entry, scripts with and without the bit, a
copied `/usr/bin/true` and a symlink to it, `.exe`, `.jar`, AppImage without +x, `.ps1`, `.vbs`, `.reg`, `.jnlp`, a
folder; remote items by name), nested `tests/apps/files_dt10.sh` (bare: pass 1 with the launch switch
on, four "open refused" and nothing reaching the launch path; pass 2 without it, the marker the launchers would create
never appears).

## Upstream base (GF-031)
Forks reviewed against Omarchy **v4.0.6** = `basecamp/omarchy@237f1b4071a0bff2296c6d740ba2b9fd695ebfa0`, the installed
package since 2026-11-03 (4.0.6-1; previously 4.0.4 = `c668141e9c42b13c80c9ca4ea108e11708c5e8a5`), and against
**v4.5.0** = `basecamp/omarchy@ac2690cd7be4f47e4a255f5e2e78d904d436b068` (tag v4.5.0, 2026-11-05; the minimum stays 4.0.6:
every fork works with both):
- v4.0.6 `currentlyLocked()` ("A property binding that missed a change notification once reported locked after an
  unlock, and a lock request before suspend then took that for done and never locked the session"): **ported** as
  `Lock.currentlyLocked()` / `Lock.currentlySecure()` (state machine storage via `LockController.currentState()`,
  `WlSessionLock.secure` read at the decision, the `verified` flag). Used by `lock()`, `restore()`, `checkStranded()` and
  the before-sleep release in `SleepInhibitor` (was the `Lock.secure` binding).
- v4.0.5 (`94a8fbc2d67eec5673c7f16b8c5e8a9c8452ffdc`) stranded-lock check skips the takeover while any other
  `quickshell|qs|hyprlock` process of the user runs (`omarchy-hyprland-session-lock-stranded "$PPID"`): **not ported**.
  Omarchy's problem is a shell that takes a live lock over and then strands it on exit; here a takeover only ever keeps
  the session locked, the ownership check re-locks after the foreign release (`foreign-restart`, ≤ 150 ms), and an exit
  is followed by a restart that restores from the marker. The process test would also block the recovery of a dead
  client's lock whenever another Quickshell instance of the user runs (the nested dev session always has one).
- Polkit: v4.0.5/4.0.6 changes are `Commons.Color` renames (Qt 6.12) only; identity selection, cancellation and the
  agent registration are unchanged; nothing to port.
- Idle (corrected by the re-pin below): v4.0.6 makes a timeout of 0 mean "action disabled" (`IdleModel.firstIdleTimeout`,
  the monitor's timeout at least 1 s), ends a running cycle when both timeouts become 0, and sets the lock timer's
  interval once per cycle instead of binding it ("a bound interval would restart a pending timer from the moment
  shell.json changes, locking early or late"). **Not applicable**: Grassfield has one timeout (`lock.idleMinutes`, 0 =
  never: `timings().enabled` false disarms the monitor, whose `onEnabledChanged` runs `update()` and stops the lock
  timer), the monitor's timeout is at least 1 s, and the bound `lockTimer.interval` is `DIM_LEAD_SECONDS` for every
  enabled setting, so a settings change never changes a pending lock timer (pinned by `tst_idlemodel.qml`
  `test_lockDelaySameForEverySetting`). A timeout change re-arms the monitor (see `rearming` in `Idle.qml`), which
  restarts the idle count: the lock comes the new timeout after the change rather than after the last input (later by the
  time already idle), and only when the setting changes without input (changing it in Settings is input).
- **4.0.4 → 4.0.6 re-pin (2026-11-03, the owner's machine on omarchy 4.0.6-1)**: the five drifted files are
  byte-identical to `237f1b40` (sha256 of the installed file = the upstream file at that revision; the 4.0.4 pins =
  `c668141e`). `plugins/lock/Service.qml`: the `currentlyLocked()` port and the stranded-lock decision above stand; its
  other changes are the `Commons.Color` qualifier and `isLocked()`/`status()` IPC reading `currentlyLocked()` (Grassfield
  has no `isLocked` IPC; `status` is a dev hook); PAM service, fingerprint and the auth flow unchanged.
  `plugins/services/idle/Service.qml`, `plugins/polkit/PolkitAgent.qml`: as above. `default/pacman/pacman-stable.conf`:
  `[omarchy]` moved first; `grassfield-channel.sh` already appends `[grassfield]` after the last repository (ADR-0033
  a.1). `bin/omarchy-update-keyring`: `pacman -Sy --needed archlinux-keyring` instead of a forced reinstall; the trusted
  Omarchy fingerprint `40DFB630FF42BCFFB047046CF0134EE680CAC571` and the keyserver trust step are unchanged;
  `grassfield-update-helper` already uses `--needed` and the same `GU_OMARCHY_FPR`. No security module change.
- **4.0.6 → 4.5.0 review (2026-11-05, `ac2690cd`; the four pinned files differ, `omarchy-hyprland-session-locked` is
  byte-identical)**. Classification for the forks and for the stand-ins Grassfield puts on PATH:
  - `shell/plugins/lock/Service.qml` → `Lock.qml`: **PORT, in part**: the fingerprint pacing ("Fingerprint pacing" below).
    Unchanged: the PAM services (`omarchy-lock-password`, `omarchy-lock-fingerprint`) and the `lock` IPC contract (`lock`
    answers `ok`, `missing-pam` or `failed`; `status` keeps `secure` and `requested` and adds `fingerprintUnavailable`, which no
    Grassfield caller reads). NONE: `IpcHandler` → `ShellIpc` (an `IpcHandler` that also answers on Omarchy's own socket,
    used only by Omarchy's `omarchy-shell` wrapper, which the Grassfield stand-in shadows), i18n and right-to-left mirroring
    (the Grassfield lock view is its own), the video wallpaper poster and the wallpaper pre-decode (the Grassfield backdrop
    is `LockStills`, ADR-0040 step 4a), the blank run-up after a resume (Omarchy's lock blanks after 5 s; Grassfield's
    display power-off is Idle's 30 s monitor). Not ported: the fprintd probe (`fprintd-list` at start and after a failed
    start, `FingerprintModel.classifyProbe`): a process the security singleton would start, beyond its building blocks; the
    backoff does its job here (no enrolment, no daemon or no reader: one attempt every 40 s at most) beside SEC8's PAM file
    test, and Grassfield has no fingerprint indicator for it to feed. The 20 s reach timeout is ported too (opus review of
    59a576f1, MINOR 1: without it a claim that never prompts kept the lock's fingerprint until a resume or an unlock). Not
    ported: the input nudge (a wake offers the reader at once), the wall-clock sleep detection (no wall clock in shell/security: logind's
    PrepareForSleep through `SleepInhibitor.afterResume`), retries after MaxTries (Grassfield keeps the reader off until
    LOCKED anew: the password after repeated wrong fingers, the macOS model), and the "fingerprint unavailable" notice on the
    lock screen (a UI addition, proposed separately).
  - `shell/plugins/services/idle/Service.qml` → `Idle.qml`: NONE (`IpcHandler` → `ShellIpc`, the `qs.Commons` import).
  - `shell/plugins/polkit/PolkitAgent.qml` → `AuthAgent.qml`: NONE (i18n, `PolkitModel.authorizationLabel(message, tr)`,
    right-to-left mirroring, `Style.duration` for the shake); identity selection, cancellation, the agent registration and
    the `/etc/pam.d/polkit-1` reading are unchanged.
  - `bin/omarchy-system-sleep-lock` → `IdleModel.js` budget, `omarchy-shell` stand-in: NONE: the failure notification's text
    goes through `omarchy-i18n` (new in 4.5); `derive_budget_ms`, `lock lock` (with `missing-pam`) and `lock status`
    (`.secure`, `.requested`) are unchanged.
  - Elsewhere (the 4.5 tree searched for lock, idle, sleep, suspend, polkit, pam, fprint and `ShellIpc`): `omarchy-apply-lock`
    writes the same two PAM files; it now keeps `omarchy-lock-fingerprint` when `fprintd-list` fails (it removes it only on
    a definitive "no fingers enrolled"), and installs with it a system-sleep hook that restarts fprintd after a resume
    (`default/systemd/system-sleep/fprintd-resume`, fprintd issue 173) and a 3 s stop timeout for fprintd; the pacing works
    with or without them (4.0.6 has neither: the 40 s cap lets fprintd exit). The fingerprint and FIDO2 setups now write
    `include system-auth` into `/etc/pam.d/polkit-1` ("Omarchy's setups and `pam_faillock`"). `omarchy-shell` calls of 4.5:
    `omarchy-system-lock` (`lock lock`, byte-identical script), `omarchy-restart-shell` (`lock status`/`lock lock`, reading
    `.secure`/`.requested`; Grassfield ships its own stand-in), `omarchy-apply-lock` (`lock status`, only for a confirmation
    line), the new `omarchy-debug-idle` (`idle status`, which the stand-in fails as Omarchy's wrapper does without its shell,
    and `lock status`): no verb the stand-in has to add. `omarchy-update-status` now sends only `omarchy.system-update
    clear` (forwarded as before). The new `omarchy-system-lid-inhibit` (logind's lid inhibitor while a USB-C or
    Unknown-connector display is in use) runs from Omarchy's lid binding and monitor watcher, which the Grassfield session
    does not load: a closed laptop on such a display can still suspend there, locked first (SleepInhibitor); outside the
    security modules.
- Pinned (GF-031 drift check): `docs/upstream/omarchy.lock` holds the sha256 of every upstream file a fork derives from
  (`plugins/lock/Service.qml` → `Lock.qml`, `plugins/services/idle/Service.qml` → `Idle.qml`,
  `plugins/polkit/PolkitAgent.qml` → `AuthAgent.qml`, `bin/omarchy-system-sleep-lock` → `IdleModel.js` budget and the
  `omarchy-shell` stand-in, `bin/omarchy-hyprland-session-locked` → the stranded-lock signal), the installed package
  (4.0.6-1) and the reviewed upstream revisions. `scripts/dev/upstream-drift.sh` (`just check-upstream`, part of
  `just check`) fails when the installed Omarchy changed or removed one of them, naming the forks to review; without
  Omarchy it says SKIP. It also fails, Omarchy or not, when a pinned fork is gone or no longer names its upstream file, and
  when a source file says "adapted from Omarchy" without being pinned, and on any read error (an unreadable fork or file of
  the scanned tree, a file that cannot be hashed). No environment variable changes what it checks (`just check` runs it
  bare); the fixture paths of its test are options (`--omarchy`, `--lock`, `--root`, `--package`; review of 395715e). After
  the review (port or reject, recorded in this section): `scripts/dev/upstream-drift.sh --update` re-pins. Test: `tests/security/upstream_drift.sh` (fixture trees:
  unchanged, edited, removed, no Omarchy, `--update`, malformed lock, lost attribution, unpinned fork; the real lock
  against the installed Omarchy).

## Fingerprint pacing (SEC8; Omarchy v4.5.0 review)
Only while `/etc/pam.d/omarchy-lock-fingerprint` exists. `Lock.qml` offers the reader through
`PamContext("omarchy-lock-fingerprint")` while LOCKED and secure; only its `PamResult.Success` unlocks
(`controller.fingerprintSucceeded`, then the release fade). The pacing decides when an attempt starts, never whether the
session unlocks, and reads nothing of the conversation but whether a line is an error (nothing of it is shown or logged).
Adapted from Omarchy v4.5.0 (`shell/plugins/lock/Service.qml`, `shell/plugins/lock/FingerprintModel.js`, MIT; constants and
backoff in `LockMachine.js`):
- Reached or missed: pam_fprintd's instruction (the first line that is not an error) means the reader was reached. An
  attempt that ends without a match and without MaxTries (no finger within pam_fprintd's 30 s, a device error) is followed
  by the next after 1 s, as before, when the reader was reached and the end did not come within 2 s of the instruction (the
  `fingerprintFastEnd` Timer). Anything else is a miss (no instruction, a start that failed, a fast end), and from the second
  miss in a row the gap doubles: 2, 4, 8, 16, 32, then 40 s (`LockMachine.fingerprintRetryMs`), longer than fprintd's 30 s
  idle exit, so a daemon whose claim wedged can exit and come back clean. Before: an attempt every second for as long as the
  lock lasted, which kept fprintd busy all night with no enrolled finger, no reader or a wedged claim. The journal says once
  when three misses in a row are reached and once when the reader answers again.
- Reach timeout (opus review of 59a576f1, MINOR 1): an attempt that has not reached the reader 20 s after it started
  (`LockMachine.FINGERPRINT_REACH_TIMEOUT_MS`, the `fingerprintReach` Timer: shorter than the 25 s D-Bus method timeout of
  pam_fprintd's claim, longer than a slow device open) is aborted (never a success) and counts as a miss
  (`fingerprintReachTimedOut`). Without it, a claim that never prompts held the lock's fingerprint until a resume or an
  unlock (the password still worked).
- Displays off (Idle's `displayOff`, mirrored in `Lock.displaysOff`): no new attempt, so the reader is not held awake all
  night; an attempt already running ends under pam_fprintd's own timeout. The displays coming back on (input on the lock
  screen) offer the reader at once.
- Resume (logind's PrepareForSleep(false): `SleepInhibitor.afterResume` → `Lock.resumed()`): the misses are forgotten, an
  attempt open across the sleep is aborted (fprintd may have been restarted by Omarchy 4.5's resume hook, or its claim be
  stale; an abort never unlocks), and the reader is offered again after 1 s, once even with the displays still reported off
  (the panel may light without input). Only to a lock (`LockMachine.fingerprintOfferedOnResume`: the PAM file, not after
  MaxTries, a lock state): a resume while unlocked leaves no pass behind, so the next lock never starts an attempt with the
  displays off (opus review of 59a576f1, MINOR 2); the unlock also clears it.
- MaxTries (pam_fprintd's wrong fingers): the reader stays off until the lock is LOCKED anew (a password attempt that
  failed, a new lock) or the session unlocks; neither a wake nor a resume brings it back (as before the pacing: the
  password is needed, the macOS model).
- Timers only (no wall clock in shell/security); the sleep is logind's signal, where Omarchy looks for wall-clock gaps.
Polkit: with the reader free more often (displays off, the longer gaps), a request that arrives while locked reaches it
sooner; the rule "No device answers a request the user cannot see and answer" refuses it as soon as its PAM talks, as
before (fail closed). The other way round (opus review of 59a576f1): any process of the user can ask polkit again and again
while the session is locked; each request's pam_fprintd takes the reader, so the lock's attempts in between fail to claim it
(misses) and its fingerprint backs off to one attempt every 40 s. That denies the fingerprint only: the password still
unlocks, nothing is approved (each request is refused as soon as its PAM talks), and a resume or an unlock resets the
misses. Tests: `tst_lockmachine.qml` test_fingerprintMisses, test_fingerprintRetryMs, test_fingerprintReachTimeout,
test_fingerprintOfferedOnResume (eight mutants of the helpers caught); `lock_surfaces.sh` "fingerprint" checks (the one
unlock path, the start guard, one settle per attempt, the reach timeout, the reader reached only on a line that is not an
error, nothing of the conversation read but that or logged, the pacing never unlocks, the pause and the wake, the resume to
a lock only, MaxTries, the reset on unlock), with 25 mutations. NOT VERIFIED: a real reader
(the development machine has neither `/etc/pam.d/omarchy-lock-fingerprint` nor fprintd), a real 4.5 session, a suspend and
resume with a reader; `Lock.qml` cannot run offscreen (WlSessionLock), and the nested gates were not run for this change.

## Screen-share protection (SEC-01 / GF-028)
`config/hypr/grassfield/privacy.lua`, required by `core.lua` (real and nested session): reads Omarchy's own
`default/hypr/apps/*.lua` in an empty Lua environment where `o.window` records only rules with `no_screen_share = true`
(with their match) and every other `o.*`/`hl.*` call does nothing; `os`, `io`, `require` and the rest are absent, so
nothing else of those files runs or applies. Each recorded match becomes `hl.window_rule({ name = "gf-no-screen-share-N",
match = …, no_screen_share = true })`. With Omarchy 4.0.4/4.0.6: 1Password, Bitwarden and the Bitwarden Chromium extension
window. A later Omarchy addition is picked up without a Grassfield change. The three built-in matches are always added
(duplicates dropped), so a rule file that stops early or disappears never leaves a password manager unprotected; when
nothing at all is read, Hyprland's log says so. Tests: `tests/security/screenshare_rules.sh` (at least one rule per
Omarchy `no_screen_share` rule; fixture tree with a new app, a table match, an `os.execute`/`io.open` file whose calls
never run; a `1password.lua` that stops before its rule still leaves 1Password protected; nothing readable;
wiring; mutation "keep every rule" fails it), `Hyprland --verify-config` in `just check` (a misspelt key fails it), and
nested `lock_privacy.sh screenshare` (DT-05: a window with app_id `Bitwarden` is black in a `grim` capture; NOT
VERIFIED until run). The same file hides the shell's secret sheets and its authorization sheet: layer rules
`gf-no-screen-share-secret` (`^grassfield-secret$`) and `gf-no-screen-share-polkit` (`^grassfield-polkit$`), `no_screen_share`
(ADR-0035 D-9, step 9b, decision 9-22; `screenshare_rules.sh` checks both regexes against the namespaces the agents set, with
a mutation). Both layers cover the output, so a capture is black while either sheet is up (nested capture NOT VERIFIED).
Known limitation, screen recordings (ADR-0045 OC-1; opus security review of e3542510, MINOR-4): `grassfield-capture record`
runs gpu-screen-recorder with `-w <display>` or `-w WxH+X+Y`, the arguments of Omarchy's `omarchy-capture-screenrecording`,
whose own comment calls both the "kms backend"; `/usr/bin/gsr-kms-server` carries `cap_sys_admin=ep` (getcap). KMS capture
reads the display's framebuffer through DRM, not Hyprland's screencopy or toplevel export, so Hyprland's `no_screen_share`
rules are not consulted: a screen recording shows whatever is on screen, password manager windows and the authorization and
secret sheets included (a password typed in a sheet stays dots; a password a password manager reveals does not). Screenshots
(grim, screencopy), screen sharing through the portal and other apps' captures keep them black. What it means for the user:
while the menu bar shows the recording item, do not open a password manager or answer a sheet unless it may be in the
recording. The shell and the helper stop a recording when the session locks (OC-1). Possible fix, not done:
gpu-screen-recorder's portal backend (`-w portal`, which Omarchy keeps off by default for EGL failures) goes through
Hyprland and would honour the rules. Reasoned from the sources, not run here (a recording would capture the owner's live
screen): NOT VERIFIED.

## Lid, display power-off, screensaver inhibitors (D-4)
- **The order of idle, the screen saver and display-off (ADR-0040 step 5; ID-8, IQ-T4 A, IQ-T5 A).** The idle lock is
  requested at once, as before; the dim stays until that lock holds (`Idle.dimUntilLock`, at most
  `IdleModel.DIM_UNTIL_LOCK_MAX_MS`), and the lock's content starts at the dim's level (`Lock.fromDim`: a shadow layer at
  `idle.dimOpacity` over the wallpaper gives way to the scrim and the text as they fade in); a request that fails lifts the
  dim at once and is logged. A screen saver on screen when a lock starts stays until the lock holds
  (`Saver.lockStarting && wasShown`, at most `SaverModel.UNTIL_LOCK_MAX_MS`), then it is under the lock surfaces. A display
  that turns off for inactivity locks the session (`lock.requirePasswordAfterDisplayOff`, `IdleModel.requireAfterDisplayOffMs`,
  anything unknown is "immediately"): at once, the displays staying on until the lock holds (`IdleModel.displaysOff`, so the
  lock is drawn just before they go off), or after the delay without input, or never; `lock.idleMinutes` stays the
  ceiling. A lock request of any reason also abandons a password check in flight (`controller.abort()`: PAM aborted, back to
  `locked`, no failure counted; opus review of f66cf08e, MINOR 1), so a check submitted just before the lid closes cannot
  unlock after the sleep request. IQ-T5 A: `misc.lockdead_screen_delay = 5000` (`looknfeel.lua`): while a restarted shell
  takes its lock back (about 1 to 2 s) the compositor keeps the session locked and draws black; the red "lock screen died"
  screen comes only after 5 s. NOT VERIFIED (nested): the order on screen, a lock at display-off on a real display, only
  black during the delay (`reload_locked.sh`).
- Lid: one binding, `switch:on:Lid Switch` in `config/hypr/grassfield/system.lua` (real session only, `locked = true`) →
  `/usr/lib/grassfield/grassfield-lid closed`, which first sends `qs ipc -p /usr/share/grassfield/shell call lock lid` on every close
  (it decides nothing about locking; it only switches the laptop panel off and on for clamshell mode,
  `tests/shell/lid.sh`). `Lock.lockOnLid()` locks at
  once, whether or not logind suspends (`HandleLidSwitchExternalPower=ignore`, a docked lid, a failed suspend), except
  in clamshell mode: a physical external output is active (`LockMachine.lidShouldLock`: `DP-n`, `HDMI-X-n`, `DVI-X-n`,
  `VGA-n`, `TV-n`, `USB-n`; the built-in panel, headless and nested outputs do not count), as macOS and Omarchy's
  `omarchy-system-lid-close` do. When logind suspends, the lock is already on its way before `PrepareForSleep`.
  Hardware lid NOT VERIFIED (L2†; nested: `qs ipc call lock lid` locks, outputs WAYLAND-1 and GF-REF are not external).
- Display power-off: `Idle.qml` watches input while the lock is secured (`Lock.holding`: confirmed by the compositor,
  never while it is still being acquired; `IdleMonitor`, `respectInhibitors: false`) and after
  `IdleModel.DISPLAY_OFF_SECONDS` (30 s) without input switches the displays off through Hyprland
  (`hl.dsp.dpms({ action = "disable" })`); input or the unlock switches them on. `misc.key_press_enables_dpms` and
  `mouse_move_enables_dpms` (`looknfeel.lua`, Omarchy's values) let Hyprland itself wake the displays, so a shell that
  dies meanwhile cannot leave the screen dark. Off in the nested dev session unless `idle devDisplayOff <s>` sets it
  (`lock_privacy.sh display-off`). NOT VERIFIED on hardware (L2†).
- Display power-off while unlocked (2026-10-26, Settings > Lock Screen; ADR-0010 amendment of that date): a second
  `IdleMonitor` (`respectInhibitors: true`, armed only while unlocked and no ScreenSaver cookie is held,
  `IdleModel.inactiveOffArmed`) switches the displays off after `lock.displayOffBattery` / `lock.displayOffPower` minutes
  without input (the power source from UPower; 0 = never) and does not lock. The idle lock is untouched. A lock that follows
  lights the displays until it holds (the compositor confirms a lock only once it has drawn it; "on" is sent while a lock is
  being acquired even if this instance believes them on, as after a shell restart: at start, then every 2 s until it holds, at most 5 times), then they go dark again
  until input (the monitor stays armed while it is idle, `offForInactivity`); any input, an unlock without input (fingerprint)
  or a change of power source switches them on. Always off in the nested dev session (no dev hook: nothing needed one). NOT VERIFIED on hardware or in nested here
  (no compositor in the cloud container; L2†).
- Automatic sleep (2026-11-04, Settings > Energy without a battery, Battery > Options… with one; macOS 27): before this,
  nothing in Grassfield or Omarchy suspended a computer on idle (logind `IdleAction=ignore`, Omarchy's idle service never
  suspends), so a computer never slept by itself. Now `IdleModel.AUTO_SLEEP_SECONDS` (60 s) after this module turned the
  displays off for lack of input (either monitor above) the computer sleeps, through `systemctl --no-ask-password suspend` (logind, never an authorization prompt behind the lock; an
  application's sleep block inhibitor refuses it, and the lock before sleep runs as for any sleep):
  - only when `energy.preventSleep` is false, on battery and on the power adapter alike ("Prevent automatic sleeping when
    the display is off"; integrator decision 2026-11-04: macOS always sleeps on battery, but Grassfield and Omarchy never
    suspended a computer by itself and the owner runs long builds and agents on battery). Default true, and anything but an
    exact false reads as true (`IdleModel.sleepPrevented`): a value that cannot be read gives back the old behaviour (no
    sleep by itself), never a sleep;
  - only while the displays are off by this module, no input and no Wayland idle inhibitor for the delay (a third
    `IdleMonitor`, `respectInhibitors: true`, enabled only then, with a monotonic `Timer` for the delay itself), and no
    ScreenSaver cookie held (`IdleModel.autoSleepArmed`);
  - only in the LOCKED state with the lock secure (`IdleModel.autoSleepAction(Lock.currentState(),
    Lock.currentlySecure())`, both read afresh: `suspend` in LOCKED and secure, `lock` in exactly UNLOCKED, `wait` in
    LOCKING, AUTHENTICATING, RELEASING, LOCKED but not verified yet, or an unknown state), read once more right before
    `systemctl` runs (review of 95dab794: `Lock.holding` included AUTHENTICATING and RELEASING and skipped the verification,
    so a fingerprint success just before the due time could start a suspend during the release fade; `tst_idlemodel`
    `test_noSuspendDuringTheReleaseFade`). A lock that settles LOCKED and secure after the due time decides again; an unlock (UNLOCKED) ends the attempt, so a fingerprint touch over the due time can never lead to the lock-first path and undo the unlock (review of 2a19231d, `IdleModel.autoSleepOnLockChange`, `test_unlockOverTheDueTimeEndsTheAttempt`). An unlocked
    session (Require password after the display turns off later than the sleep, or Never) is locked first
    (`Lock.lock("sleep")`, which lights the displays until the lock holds), and the next due time suspends: Grassfield never
    puts an unlocked, unconfirmed or opening session to sleep, even with a degraded sleep inhibitor;
  - a request that did not end in a sleep (logind refused it: a download's sleep block inhibitor; a refused lock; a wake
    without input) is asked again every `IdleModel.AUTO_SLEEP_RETRY_MS` (5 minutes, monotonic, so the time asleep does not
    count) while the displays stay off (review of 95dab794: a laptop otherwise stayed awake all night once the download
    ended); never a tight loop, and input (the displays come on) stops it (`test_autoSleepRetry`);
  - the idle lock, the display-off lock and the displays' power-off never read `energy.preventSleep` (`timings`,
    `idleArmed`, `inactiveOffArmed`, `requireAfterDisplayOffMs`, `displaysOff` do not take it; `test_lockIndependentOfSleep`).
    The one lock the setting can lead to is the lock before an automatic sleep on a session that is not locked yet, which
    only ever adds a lock: never removes, delays or skips one (`test_autoSleepOnlyAddsLocks`: the automatic sleep's code
    calls `Lock.lock("sleep")` and two read-only getters, nothing else on Lock). The displays still turn off and the session
    still locks as Lock Screen says, whatever the switch says;
  - never in the nested dev session (`RunMode.dev`): a due suspend is counted (`idle status` `autoSleepSuppressed`) and
    logged, never run; `idle devAutoSleep <1..600>` shortens the delay for a nested test.
  Real suspend NOT VERIFIED (L2†, owner).
- The lock surface (2026-10-26): `lock.showUser` false hides the picture and the name, `lock.showMessage` shows
  `lock.message` (plain text, one line stored, at most two lines drawn) above them. Display only.
- `org.freedesktop.ScreenSaver` inhibitors (GF-016 residual, done 2026-10-24; ADR-0008 and ADR-0010 amendments):
  Quickshell 0.3.1 cannot own a D-Bus name or serve methods (verified in its qmltypes: no D-Bus server type, only the
  DBusMenu client, the StatusNotifier, MPRIS and Notifications services and the Wayland `IdleInhibitor`), so the menu
  bridge serves `Inhibit`/`UnInhibit` (only those; `Lock`, `SetActive`… answer NotSupported), keeps cookies per sender
  (released by their owner or when it leaves the bus; 16 per sender, 64 senders) and sends the shell one boolean
  (`docs/specs/menu-bridge.md` MB16). `Idle.busInhibited` (from `MenuBridge.screenSaverInhibited`) then disarms the idle
  dim and idle lock only (`IdleModel.idleArmed`), as a macOS power assertion does while a video plays; a manual lock, the
  lid, the lock before sleep and the display power-off on the lock screen are unaffected. Fail closed: no bridge, a dead
  bridge, a hung bridge (the line is repeated every 20 s; 60 s without one drops "inhibited", `tests/shell/menubridge_heartbeat`),
  a client that left before the bridge watched it (watch, then `NameHasOwner`) or anything but an explicit `true` leaves
  idle locking on. Wayland-native players (mpv, Firefox, Chromium on
  Wayland) keep using the idle-inhibit protocol that `IdleMonitor { respectInhibitors: true }` honours (DT-16). Tests:
  `tests/unit/menu-bridge/tst_screensaver.cpp`, `tests/security/tst_idlemodel.qml` `test_idleArmed`,
  `tests/unit/tst_menubridge.qml` `test_screensaverLines`; `tests/integration/screensaver_inhibit.sh` (bare, private bus)
  NOT VERIFIED here (needs Unix sockets). Nested check (bare): with the nested session up, `gdbus call --address $(cat
  .dev/bus.address) …` cannot hold a cookie (it disconnects at once); use the integration test, then `qs ipc -p shell
  call idle status` shows `busInhibited`.

## Polkit details (SEC-07, D-4)
Software Update's two actions (ADR-0033 c and "Step 3"), `org.grassfield.packages.set-channel` and
`org.grassfield.packages.update-system` (Update Now, owner decision SU-M1: an administrator's password every time), are shown
as polkit gives them: their own message and "Action: <id>"; the sheet reads nothing from them. The update helper's
arguments (an operation id, migration names) say nothing a person needs to decide on.
Grassfield Store's action (ADR-0037 b.1, SD2, SD17): for `org.grassfield.store.manage-packages` only, the sheet reads polkit's
message, which polkitd expands with the helper's argument vector as pkexec reports it (`$(command_line)`), by one strict
pattern (`AuthDialogModel.storeRequestOf`: the policy's English or French message, `/usr/lib/grassfield/grassfield-store-helper`,
`install` or `remove`, a 32-digit operation id, 1 to 64 package names of ADR-0037 e.5, nothing else). It then says
"Install xterm, gimp" (or "Remove …") in place of the message, and adds "Program: <the helper's path>" under "Action: <id>";
a message that does not match, or the same message for another action, is shown as polkit gives it, one capped line. The
names come from polkit, never from the program that asked. Every name is shown, none elided (the password is never asked
for a package the user cannot see): past `storeLines` (8) the message scrolls inside a bounded area (wheel, drag, its scroll
bar; Tab reaches it, then the arrow keys, Page Up/Down, Home and End), so the action line and the buttons stay in the sheet;
the area takes no focus while AuthAgent keeps the keys. Unit-tested (`tst_authdialogmodel` test_storeRequestInPlainWords:
15 messages that must not be read, the other action; `tst_authdialog` test_12_storeRequestNamesPackagesAndProgram and
test_13_storeRequestNamesEveryPackage: 64 names of 128 characters, the helper's most).

Grassfield Store's session-bus name (ADR-0037 SD35, step 4): one Store per user, as Settings and Activity Monitor. The running
Store owns `org.grassfield.Store` (`.Dev` and a digest of the state directory in a dev or isolated run), object
/org/grassfield/Store, one scriptable method `Open(s page, s token)`: a second launch hands it its `--page` (printable, at most
512 characters) and its xdg-activation token (printable ASCII, at most 256) and leaves. The window checks the page again
(Main.qml's openPage: a section, a category, an app, a search, Installed, Updates, or `type:<type>` for a well-formed media
type, or `uninstall:<application entry>`); anything else keeps the page shown. It opens a page and brings the window forward,
nothing else: no plan, no install, no removal, no update (each still needs its own button and, for the system's packages, the
helper's password). `uninstall:<entry>` (the launcher's delete badge, Files' Move to Trash; ADR-0046 D1) is the same: it only
OPENS the Store's own confirmation, "Delete “App”?" with the app's Store name, icon and the packages `-Rns` takes, Cancel the
default; no path of a hand-over calls `uninstall`, so any session-bus peer, a Flatpak included, can ask and nothing is removed
until the user presses Delete in the Store (tst_storeoperations test_handOverOnlyOpensTheAlert).

Quickshell 0.3.1 `AuthFlow` (`/usr/lib/qt6/qml/Quickshell/Services/Polkit/quickshell-service-polkit.qmltypes`) exposes
`message`, `iconName`, `actionId`, `cookie`, `identities`, `selectedIdentity`, `isResponseRequired`, `inputPrompt`,
`responseVisible`, `supplementaryMessage`, `supplementaryIsError`, `isCompleted`, `isSuccessful`, `isCancelled`,
`failed`, and no subject, process id, command line or `details`. The sheet shows everything that identifies the
request: the message (polkit's text; for `pkexec` it names the program and its arguments), "Action: <id>", the
identity, and now the action's `iconName` (from the root-installed `.policy` file) with the lock as a badge, macOS style.
That icon describes the action, not the program that asked: polkit does not tell the agent which process requested it
through this API (`AuthDialogModel.iconName`: plain theme names only, by the one rule notification icons use,
`NotificationPrefs.safeIconName`, review of 2dfd992; `AuthAgent` shows it through `ThemeIcons.source`: the system
theme's icon (Qt searches only directories the user cannot change, `ui/i18n/iconsearchpaths.h`) or a PNG the shell made
from a user icon of that name (see security-images.md, `tests/security/theme_icon_files.sh`); else the lock alone; the Image
loads asynchronously, review of 100692f). Unit-tested (`tst_authdialogmodel` `test_iconNameIsAPlainThemeName`, `tst_authdialog`
`test_10_programIconWithLockBadge`); visual NOT verified (a nested shell cannot register an agent: L5).

**One queue with the secret sheets (ADR-0035 D-9, step 9b, decision 9-15).** The polkit sheet and the secret sheets of
`shell/security/secret` share one queue (`shell/security/SheetQueue.qml`, made by `shell.qml`): one sheet on screen at a time,
in arrival order. While a secret sheet came first, the polkit agent hands its model no request (`AuthAgent.waiting`, the gated
`flow`): nothing of it is mapped, focused or held, and nothing is answered meanwhile. When the secret sheet is gone, the queue
tells the polkit model a sheet ended before it hands the request over, so the request arrives held ("right after another
one"), without the keyboard until a click past the guard. The polkit sheet keeps its place while it is present, its linger
included (`AuthAgent.queuePresent`), so a secret sheet never shows over it. A polkit request is never refused by the secret
sheets' bound of 8. The agent's window rules are unchanged (`tests/security/authagent_flows.sh`, `lock_surfaces.sh`);
`tests/security/secret_sheets.sh` runs both agents and the queue together with real keys.

**The capture toolbar never takes the keyboard from a sheet (opus re-review of the ADR-0045 security fixes, MINOR).** The
capture toolbar (ADR-0045 OC-1) is an Overlay layer with Exclusive keyboard, handed between displays by mapping the new
holder again (a layer mapped as Exclusive takes the keyboard; one turned Exclusive while mapped does not). Over an open
polkit or secret sheet such a mapping would take the keyboard from the sheet and send the rest of a password to the toolbar.
While `SessionState.securityKeyboard` (the polkit sheet or a secret sheet is present, or one of their key sinks still holds
the keyboard after a request ended under the user's typing: `AuthAgent.queuePresent || SecretAgent.requestActive ||
SecretAgent.sinkingKeys`, shell.qml's Binding; opus re-review 2, MINOR-3) the toolbar makes nothing Exclusive: no hand-over,
no remapping, and a toolbar opened then maps without the keyboard; a hand-over under way when a sheet opens maps without it;
once the sheet is gone the display that wants the keyboard maps again as Exclusive (`CaptureToolbar.qml` `sheetOpen`,
`followKeyboard`). `lock_surfaces.sh` pins it with mutations (QML with PanelWindow cannot run offscreen). The key sinks'
linger (at most 3 s) is covered, so the rest of a password never reaches the toolbar, where Return captures. Nested: NOT
VERIFIED.

**A device before the password (ADR-0045 OC-6, security review of the Settings setups, 2026-11-04).** Once Omarchy's
fingerprint or security key setup ran, `/etc/pam.d/polkit-1` starts with `pam_fprintd` (behind Omarchy's lid-closed gate) or
`pam_u2f` (`cue`), each `sufficient`, before `pam_unix`. Every rule below assumes that the device module announces itself
before it waits: pam_fprintd always does, pam_u2f only with `cue` (Omarchy sets it); a silent device module would defeat
them (see the residual of the next paragraph). polkit-agent-helper-1 then sends the module's lines as information or error
(`AuthFlow.supplementaryMessage`, `supplementaryIsError`: "Place your right index finger on the fingerprint reader", "Failed
to match fingerprint", "Please touch the FIDO authenticator.") and asks nothing until the module gives up (a match ends the
request: polkit allows; a timeout, too many failed matches, no reader or a closed lid lead to `pam_unix`'s password prompt).
While PAM has said something and asks nothing (`AuthDialogModel.awaitingDevice`: a flow, no response required, no answer
sent, a non-empty message), the sheet's password field takes no key (`enabled: inputEnabled && !awaitingDevice`), the line
above it says "Follow the instruction below, or wait for the password field.", and the module's own line is the feedback
under the field; when the prompt comes the field takes the keyboard back (`onAwaitingDeviceChanged` → `focusField`, which
still respects `inputEnabled` and AuthAgent's key sink). A bare "nothing asked" never disables the field: keys typed before
`pam_unix`'s first prompt are kept, so a fast typist's password is not cut short (a short one is a wrong one, which
pam_faillock counts). The last line is never cleared when the prompt arrives: pam_faillock's "account is locked" notice
comes the same way and stays readable, except after a failed attempt of the same request, where our own "Incorrect password.
Try again." comes back with the prompt and replaces it (open, final counter-review of ADR-0045 LOW-A, older than this
change: clearing `priv.error` when PAM sends a new non-empty message would keep the notice, once Quickshell 0.3.x's AuthFlow
is confirmed not to set `supplementaryMessage` itself on a failure; stock Omarchy sets pam_faillock's preauth `silent`, so
no notice is sent there). While a device is awaited the feedback line is PAM's own line, never the previous round's
"Incorrect password. Try again." (that message comes back with the next prompt; counter-review, LOW-2). Cancel works
throughout; nothing is ever approved on its own, and the one answer given on its own is a refusal: a request the user cannot
see and answer is cancelled once PAM talks without asking (next paragraph). Unit-tested (`tst_authdialogmodel`
test_awaitingDeviceOnlyWhilePamTalksAndAsksNothing, test_aLockedAccountNoticeStaysUnderThePrompt,
test_theNextRoundsDeviceInstructionIsShownNotTheOldError; `tst_authdialog` test_14_awaitingADeviceTheFieldWaits;
`mutate_authdialog.sh` D2, D3). The lock screen shows nothing of `omarchy-lock-fingerprint`'s conversation (it runs beside
the password and unlocks on a match). With a real reader and key: NOT VERIFIED here, and the nested security gates L1 to L5
were not run for this change (no nested session in the cloud session that made it). The field's fourth focus site
(`onAwaitingDeviceChanged`) gives the focus only when PAM's prompt came (`!awaitingDevice && responseRequired`, never when
the request ends) and through `focusField`, so never while the input is disabled; a focus given inside the agent's window
reaches the keyboard only while that window holds it (shown and not held, or held and clicked past its guard).
`lock_surfaces.sh` pins the site by its guard and the field's `enabled`, with mutations.

**No device answers a request the user cannot see and answer (ADR-0045 OC-6, opus security review of e3542510, MAJOR-2).**
macOS model: an authorization asked for while the screen is locked is shown after the unlock and never answered by the
unlock gesture. Quickshell (0.3.2, revision 2b4501a, read in its sources: `flow.cpp`, `agentimpl.cpp`) starts PAM the moment
polkit asks, whether or not a sheet shows the request: `PolkitAgentImpl::initiateAuthentication` activates the request at
once, `AuthFlow`'s constructor calls `setupSession()`, which runs polkit-agent-helper-1 (`polkit_agent_session_initiate`),
and a failed attempt starts it again; the QML API (`quickshell-service-polkit.qmltypes`) has no method to start, defer or
pause it, only `submit`, `cancelAuthenticationRequest` and `selectedIdentity` (which restarts it). On success the helper
reports to polkitd itself, so the agent cannot veto a match afterwards. With `pam_fprintd` or `pam_u2f` first in
`/etc/pam.d/polkit-1`, a request held behind the lock, the screen saver or another sheet would hold the reader (a request
open when the lock comes, or one that takes the reader while the lock's own attempt is not running: its retry gap, `Lock.qml`
`fingerprintRetry`, 1 s and up to 40 s while the reader is not reached, and the whole time the displays are off, "Fingerprint
pacing"), and the touch meant for the lock screen (or for the request before) would approve it unseen. So the
polkit model refuses the request Quickshell has open (`AuthDialogModel.request`, bound by the agent to `agent.flow`, also
while the sheet is handed nothing because a secret sheet came first) as soon as PAM talks without asking (`pamTalks`: no
response required and a non-empty line, a device's instruction or any other line, when in doubt no; Quickshell keeps the
last line until another comes) while it is not answerable (`refusesUnseen: !answerable && pamTalks(request)` →
`cancelAuthenticationRequest()`, polkit's "cancelled": the requester is told no, which fails closed). The cancel runs from
the event loop (`Qt.callLater(refuseUnseen)`, which checks again), never inside the binding's own change: Quickshell ends
the request inside the cancel, which changes what the binding reads; done inline, QML reported a binding loop and could keep
the binding stale, leaving the next request unguarded (found by `flows.qml` test_27, whose mock ends the request inside the
cancel as Quickshell does). `answerable` (default false) is the agent's rule: its sheet is on screen in front, that is not
locked, no screen saver, the displays on (`SessionState.displaysOff`, a Binding in shell.qml from `Idle.displayOff`: off for
inactivity while unlocked counts too, a reader in the power button pressed to wake the screen must not answer a sheet nobody
sees; opus re-review 2, MINOR-2), not waiting behind another sheet, in the sheet (`requestOpen`), and not held unless it is
held as "right after another one" or the user clicked past its guard (`!heldByLock || userFocused || heldWhy === "queued"`).
For a request held right after another one the click hold does not count (integrator decision after the opus re-review, the
macOS model, which accepts a touch on the authorization it shows): it keeps stray clicks and keys out of a sheet the user
sees, and a touch on the reader can then only be meant for that sheet. A request held for another reason (just after an
unlock, or after the lock or the saver) is not answerable until clicked (opus re-review 2, MINOR-1): a finger left on the
reader after unlocking would answer it, and the lock marker, readable by the user's processes, tells any of them when to
ask. Settings' Remote Login asks twice in a row (systemd `EnableUnitFiles`, then `StartUnit`) and Add Printer up to three
times (cups-pk-helper `PrinterAdd`, `PrinterSetEnabled`, `PrinterSetAcceptJobs`), each request held as "right after another
one": each is answered by a touch. An answer already sent shields nothing (a stack with `pam_unix` before a device module
goes on to the reader after a wrong password, in the same round). PAM asking for a password ends nothing: that request waits
behind the lock and is shown, held, after the unlock, as before. What the user sees: the requesting app reports that the
authorization was cancelled, as after Cancel (polkit reports it dismissed); the app can ask again once the user is at the
sheet. With a fingerprint stack this refuses every request that arrives locked, under the saver or behind a secret sheet,
because PAM reaches the reader within moments. Replaced requests (opus re-review, MAJOR-1): Quickshell's agent replaces an
open request instead of queuing it (`initiateAuthentication` pushes, then activates when the queue holds one, which it does
again after the first activation popped it) and leaves the replaced flow running with its helper, so its PAM could hold the
reader with no sheet left, for up to pam_fprintd's 30 s, keeping the lock screen's own fingerprint check from it, and the
next touch meant to unlock would approve it. The model remembers the request it saw last (`priv.seen`); a change to another
request while the previous one has not completed records the previous one (`priv.replaced`, every one still running). As
soon as one of them talks without asking (`replacedTalks`, at once if it already did), `refuseReplaced` (from the event
loop) refuses the request open now first, then every replaced one: refusing a replaced one first would complete it, and its
completion is still connected to agentimpl's `finishAuthenticationRequest`, which would end the current request unanswered
(its requester never answered). Both requesters are told no (fail closed). A replaced request that asks for a password is
left as Quickshell leaves it (nobody can type into it; its requester waits until it gives up, as before). Tests:
`tst_authdialogmodel` test_unansweredRequestRefusedWhenPamTalks, test_passwordPromptWaitsForTheUser,
test_refusedWhenItStopsBeingAnswerable; `tst_authdialog` test_15 and test_16 (`mutate_authdialog.sh` G1 to G9);
`authagent_flows.d/flows.qml` test_20 to test_34 with the real agent (the lock coming while the reader waits, a request
arriving locked, a password prompt waiting behind the lock, the saver, held just after an unlock (refused until clicked) or
right after another request (answered by the reader), Remote Login's two and Add Printer's three requests in a row each
answered by the reader, a request waiting behind a secret sheet, the request ended inside the cancel with the next one still
guarded, the reviewer's probe (locked, A, B replaces A, A then waits for the reader: B then A refused), a request replaced
while it awaited the reader, a replaced one asking for a password left, the refusals with Quickshell's end, the displays
turning off, a request held after the lock reaching the reader, a request held right after another one under the saver;
`authagent_flows.sh --mutants`: twelve mutants for this guard); `lock_surfaces.sh` pins the model's guard and the agent's
binding, with mutations. Residual (open): (1) the window between pam_fprintd starting its scan (`VerifyStart`) and the agent
receiving its "Place your finger" line is a few milliseconds of IPC; a finger already resting on the reader and matched
within it, or within the one event-loop turn before the cancel runs, would still approve; (2) a replaced request is refused
only once its PAM talks, so the same window applies to it; two overlapping requests with a device stack are both refused,
and a replaced one at a password prompt still leaks as upstream leaves it (fix upstream: queue for real); (3) both rules
assume that a device module announces itself before it waits: pam_fprintd always does (its "Place your finger" line comes
with the scan, and it has no silent mode), pam_u2f only with `cue`, which Omarchy's setup sets
(`omarchy-setup-security-fido2`). A module that waits for a device without a word (pam_u2f without `cue`, another device
module) defeats both the refusal and the replaced-request rule, since PAM then never talks without asking; such a line in
`/etc/pam.d/polkit-1` is outside what this agent can guard. Real reader and key: NOT VERIFIED.

**Omarchy's setups and `pam_faillock` (ADR-0045 OC-6, opus security review of e3542510, MINOR-5).** Read in Omarchy 4.0.6
(`/usr/share/omarchy/bin/omarchy-setup-security-fingerprint`, `omarchy-setup-security-fido2`): when `/etc/pam.d/polkit-1`
does not exist, each setup writes one of its own: the device line (`pam_fprintd` behind the lid gate, or `pam_u2f cue`), then
`auth required pam_unix.so` and `pam_unix` for account, password and session, with no `system-auth`. On this machine there is
no `/etc/pam.d/polkit-1`; polkit's stack is the vendor file `/usr/lib/pam.d/polkit-1` (`include system-auth`, which has
`pam_faillock preauth silent deny=10 unlock_time=120`, `authfail`, `authsucc`). A file in `/etc/pam.d` takes precedence over
the vendor one, so after either setup polkit loses `pam_faillock` (no 10-failure lockout on the authorization sheet, while
sudo and the lock screen keep it), `pam_systemd_home` (a systemd-homed user can no longer authorize) and `pam_env`.
`omarchy-remove-security-fingerprint` and `omarchy-remove-security-fido2` delete only their own lines and leave the file: the
loss outlives "Remove…". Grassfield writes no PAM file (OC-0.4); Settings' setup sheets for the fingerprint and the security
key say before the terminal opens that the administrator prompts' own rules may be replaced and no longer pause after repeated
wrong passwords. The owner's fix, if wanted: in `/etc/pam.d/polkit-1`, replace `auth required pam_unix.so` and the three
other `pam_unix` lines with the `include system-auth` lines of the vendor file (keeping the device lines first), or delete
the file after "Remove…". Reported upstream: not yet (owner's call). Omarchy 4.5.0's fingerprint and FIDO2 setups write
`include system-auth` for auth, account, password and session after the device line (still first, `sufficient`), so a
`/etc/pam.d/polkit-1` they create keeps `pam_faillock`; a file written by 4.0.6's setups keeps the loss until it is fixed as
above ("Upstream base", 4.5.0 review). The device-first assumptions of the two paragraphs above hold for both.

## L5 polkit (owner, real session)
Never `pkexec` a real program for this test; `pkcheck` only asks polkit whether this terminal's shell may run the action
and runs nothing as root. In a terminal of the Grassfield session:
1. `journalctl --user -u grassfield-shell -b -o cat | grep -c 'authentication agent registered'` → `1`.
2. `pkcheck --action-id org.freedesktop.policykit.exec --process $$ --allow-user-interaction; echo "exit $?"`. The
   Grassfield sheet appears over a dimmed screen: the message, "Action: org.freedesktop.policykit.exec", "User: <you>",
   a password field and Cancel / Allow. Press Esc → the sheet closes, `exit 3` (dismissed), nothing approved.
3. Run step 2 again; type one wrong password, Return → the sheet shakes, "Incorrect password. Try again.", the field
   is empty, nothing approved; then Cancel → `exit 3`. (One wrong attempt counts once in faillock, shared with sudo.)
4. Optional, only if the owner wants the success path: step 2 with the right password → `exit 0`; polkit may then keep
   the authorization for this shell for a few minutes (`auth_admin_keep`): close that terminal afterwards.
5. Clicking outside the sheet never cancels or approves; `journalctl --user -u grassfield-shell -b -o cat | grep -i
   polkit` shows no password and no "approved" line.
PASS: 1–3 (and 5) as described. FAIL: any approval without the right password, a second agent, or the sheet missing.

## Lock survival (crash, reload) — fail closed
Found in R12 review: a Quickshell soft reload while locked unlocked the session when the marker was missing or not
exactly `locked`. Quickshell 0.3.1 `WlSessionLock::onReload` hands the previous instance's lock to the new
`WlSessionLock` and releases it (`realizeLockTarget` → `unlock()`) if the new `locked` is false at that moment; a
`sessionLock.locked` check in `Component.onCompleted` cannot see the handed-over lock (no manager yet).

A starting instance (session start, crash restart, soft reload) locks when ANY of these says so; only a PAM success
(`release()`) clears the carried intent and writes `unlocked`:
1. Carried intent: `PersistentProperties { reloadableId: "grassfield-lock-intent" }` (true while
   locking/locked/authenticating; the restored old value never downgrades a lock taken in `Component.onCompleted`:
   `intent = intent || controller.locked`) is declared before `WlSessionLock` in `Lock.qml`. Quickshell reloads a Singleton's
   children in declaration order (`ReloadPropagator::onReload`), so the old value is restored, and
   `WlSessionLock { locked: persist.intent || controller.locked }` re-evaluated, before `WlSessionLock::onReload`:
   the handed-over lock is kept, with no unlocked window (the new `WlSessionLock` has no Wayland lock object until its
   own reload). Verified offscreen by `tests/security/reload_order` (order, binding value, negative control,
   `Lock.qml` structure) and in nested by `reload_locked.sh` (marker removed / forged `unlocked` + reload → locked).
2. Marker, read in `Component.onCompleted` (runs before the reload pass): anything but an `unlocked` line (`unlocked`
   or `unlocked sleeps=<n>`) → lock, including an empty or unreadable marker (mode 000, a directory, I/O error) and a
   malformed line; an `unlocked sleeps=<n>` line whose count differs from the kernel's current count of completed
   suspends → lock too (the machine slept while no shell could lock, see "Lock coverage"). Only a missing file (FileView
   `FileNotFound`) counts as missing (`LockMachine.markerRead`; `tests/security/marker_read` uses the real FileView).
3. `XDG_RUNTIME_DIR` unset: no marker can prove the session unlocked → lock at start; the lock surface shows
   "Crash recovery unavailable: the lock state could not be saved." (also shown when a marker write fails; logged).
4. Stranded lock: until this instance first locks (at most 20 Hyprland monitor queries in 10 s, through
   Quickshell.Hyprland, no `hyprctl`), "LOCK" in any monitor's `solitaryBlockedBy` (the signal Omarchy's
   `omarchy-hyprland-session-locked` uses; Hyprland has no lock query) means a lock this instance did not take: a
   crashed instance whose marker was missing or forged, or a live foreign locker (Hyprland cannot tell them apart).
   It is taken over. Only ever locks. Verified in nested: forged `unlocked` + `kill -9` → restarted shell reports
   `locked` (before: `unlocked` behind Hyprland's "lockscreen app died" screen). A live foreign locker's later release
   is handled by "Lock ownership" below.
   Monitor model (review of the lock's monitor queries, Quickshell v0.3.1 source read as data): the QML
   `Hyprland.refreshMonitors()` is `refreshMonitors(false)`, which updates existing monitor objects and never creates
   one; sent before Hyprland answered Quickshell's own first query (`j/status`, whose answer starts its
   `refreshMonitors(true)`), it makes Quickshell drop that query as a duplicate, and `Hyprland.monitors` stays empty
   until a monitor event. Every lock query therefore goes through `Lock.requestMonitors()`, which sends none while the
   model is empty (`LockMachine.monitorQueryAllowed`) and logs that once (cleared when a monitor appears). An empty
   model is an unknown state (never `unlocked`): the check asks again on the next tick, and if the 20 ticks run out the
   marker decides (no takeover, fail closed as before) until monitors appear: a check that has not decided
   (`strandedUndecided`: no `locked` or `unlocked` answer yet, this shell not locked) runs once more when the model
   fills (`monitorsAdded`), so a dead client's stranded lock is taken over as soon as Quickshell's first answer arrives,
   however late (opus review of 94ab527, MINOR-1; before, an answer after the 10 s left the session behind Hyprland's
   "lockscreen app died" screen, locked but out of reach). That run only ever takes the lock over. Any lock of this
   shell (`lock()`) ends the undecided state for good, so the check never reads cached answers that show this shell's
   own lock (re-review of 1449bf3, MINOR-A: after an unlock, a stale LOCK read on a monitor plugged in would have
   re-locked the session). Residual: before this shell first locks, an undecided check re-run on a monitor plugged in
   reads the other monitors' cached answers; if a foreign locker's lock showed there and was released since, it is
   "taken over" again, i.e. an unwanted lock, never an unlock. The only other
   `Hyprland.refreshMonitors()` in the shell is Displays' handler of Hyprland events, which cannot run before
   Quickshell's first answer (Quickshell connects its event socket in that answer's callback). Tests:
   `tst_lockmachine` `test_monitorQueryAllowed`, `tests/security/lock_surfaces.sh` (the guarded call, its callers, the
   re-run on the filling, every `refreshMonitors` of shell/ and ui/ but Displays' event handler, with mutants),
   `tests/security/lock_monitor_model.sh` (the real Lock offscreen: with no Hyprland socket, Quickshell's own query is
   the only one, 20 before the fix; against a fake Hyprland that answers `j/status` after 1.2 s, the model fills and a
   stranded lock is taken over, while the code before the fix leaves the model empty; with the answer after 12.5 s,
   the takeover follows the check's "unknown" end, and none without the re-run; the fake needs Unix sockets).

A fresh session (marker absent, no carried intent, compositor not locked) starts unlocked. A removed or forged marker
cannot expose a locked session: when a lock client dies, Hyprland keeps the session locked (ext-session-lock; no input
reaches clients, verified by L1) and rule 4 takes that lock over.

## Lock ownership and foreign lockers — fail closed
Found in the R12 re-review, verified in nested (Hyprland 0.56.2, `misc.allow_session_lock_restore = true`):
- Hyprland hands a LIVE session lock to the next client that asks, at once, and sends the previous holder nothing
  (no `finished`): both clients' `WlSessionLock` report `locked` and `secure`.
- When either client then releases its lock (`unlock_and_destroy`), Hyprland unlocks the session, although the other
  client still holds a lock object that reports `secure` and gets no event either.
- Hyprland emits no IPC event for session lock or unlock (socket2 during a foreign release: no event at all).

Before the fix, a shell whose lock was taken over (or that had taken over a live foreign lock) kept reporting `locked`
after the release while input reached windows; `lock lock` answered `already-locked`, idle/sleep locks were no-ops and
the sleep delay was released on the stale `secure`.

Behavior now (`Lock.qml`, `LockMachine.ownershipAction`):
1. While this shell holds a lock the compositor confirmed (`locked`/`authenticating`/`releasing`, `WlSessionLock.secure`), it asks
   Hyprland for the real session lock state (`ownershipProbe`: one `Hyprland.refreshMonitors()` request through
   Quickshell.Hyprland, no `hyprctl` process, never while unlocked or locking) once per second, and every 100 ms while
   a takeover is suspected (`LockMachine.takeoverSuspected`, R12 review #3): no lock surface of this shell has the
   keyboard (another client's lock surface took it, or a window did after an unlock under this lock), or the lock was
   requested by a restore at start (it may be a live foreign locker's lock taken over, whose release sends no event).
   The restore ("inherited lock") suspicion ends only with `relock()` (the foreign release happened) or `release()`;
   keyboard focus proves nothing: a foreign locker taken over at start sits UNDER this lock and its release unlocks
   the session while a Grassfield surface keeps the keyboard (R12 counter-review of 620f08c, which ended it on focus
   and brought back the ~1 s window; `foreign-restart` now asserts release → fresh lock ≤ 150 ms). So a
   crash-recovery lock keeps the 100 ms check for its whole life. Memory (`probe-memory`, 10 min each, nested): no leak,
   but each answer's JS garbage made a GC sawtooth (the 452 → 477 MB rise the review saw): before, RSS 434–464 MB,
   garbage 6.5 MB/min, post-collection floor +1.5 MB; after reading monitor maps lazily (`compositorLockStateLazy`:
   one map per answer while locked instead of all), RSS 428–452 MB, garbage 4.5 MB/min (finer sampling), floor
   −4.4 MB. The remaining per-answer cost is one `lastIpcObject` conversion, the only source of the lock state that
   Quickshell.Hyprland offers.
   Also at once when a lock surface loses keyboard focus, and on every monitor answer anyone requested. Suspicion only
   ever speeds the check up; it never unlocks. No query is sent while Quickshell's monitor model is empty (see "Lock
   survival" rule 4): until it fills, nothing is verified (`verify()` leaves `secure` false, so the sleep delay waits as
   it did for a missing answer), relocked or taken over, and WlSessionLock keeps the session locked. The answer
   watcher (`monitorAnswers`) follows the live model: a monitor object created later (the model filling after the lock
   was taken, an output plugged in) gets its delegate at once, and while holding a fresh answer is asked for at once
   (`monitorsAdded`), because Quickshell fills a new monitor before it adds it to the model, so the answer that created
   it reaches no delegate. Cost of the 100 ms check (nested, `probe-cost`, three runs): +1.2 to
   +1.9 % CPU in the shell (0.8–1.0 → 2.0–2.7 %), Hyprland +0 to +0.6 % (0.3–0.4 → 0.3–0.9 %).
2. An answer reporting the session unlocked is confirmed by a second, fresh answer (answers in the first 500 ms after
   the lock was confirmed are ignored), then the shell takes a fresh lock: `lockLost()` (→ `locking`, PAM aborted,
   secret dropped), the stale lock object is released (the session is already unlocked) and a new lock is requested in
   the same event-loop turn. The carried intent and the marker stay `locked`. This `relock()` is not atomic (the release
   can reach Hyprland before the new request): its only caller is `checkOwnership()` on a confirmed answer
   (`tests/security/reload_order` checks it).
3. `lock()` while locked re-verifies (`verify()`) and answers `already-locked`; it never relocks on an earlier answer
   alone. Before R12 review #3 it relocked at once when one earlier answer said unlocked: on a stale answer the release
   unlocked a really locked session until the new lock arrived (forced baseline: keys reached a window in 12 of 12
   runs). A session found unlocked gets its fresh lock once the next answer confirms it (Quickshell has no synchronous
   Hyprland query; nested: within a few ms).
4. `Lock.secure` = holding AND (just acquired, or Hyprland reported the session locked since the last `verify()`).
   The sleep path calls `lock("sleep")`, which clears it until a fresh answer, so the sleep delay ends only on a
   confirmed lock, after the fresh lock when the session was found unlocked (`sleep-desync` step).
5. Policy for a live foreign locker (e.g. hyprlock): never adopted as Grassfield's own lock and never fought.
   - Present when the shell starts: taken over (rule 4, needed for a dead client's lock); when it releases, the
     session is re-locked by Grassfield.
   - Takes over a live Grassfield lock: left alone (coexist); the session is locked, so `lock status` stays `locked`.
     When it releases, Grassfield takes a fresh lock at once.
   - Only a Grassfield PAM success clears Grassfield's intent, so a user who unlocks a foreign locker then sees the
     Grassfield lock screen and authenticates again (fail closed).

Verified in nested by `tests/security/reload_locked.sh` steps `foreign-takeover`, `foreign-restart`, `lock-desync`
(the desync held on purpose with the dev hook `lock devPauseOwnershipCheck` as a positive control, then `lock lock`)
and `sleep-desync` (dev hook `idle devSleep`), with the fixture `tests/security/foreign_locker/ForeignLocker.qml`
(a Quickshell ext-session-lock client released over its IPC, which logs the epoch ms of its release). Forced races
(R12 review #3): `relock-confirm` (one stale "unlocked" answer forged by the dev hook `lock devForgeUnlockedAnswer`
while the session is locked, then `lock lock` while keys are typed every 4 ms: 12 runs, no relock, nothing reached the
probe window; the same step on the previous code relocked in 12 of 12 runs and keys reached the window in 12 of 12),
`foreign-gap` (foreign takeover then release while keys are typed: release → fresh lock request 9–101 ms over 15 runs
in three sessions, previously 250–1123 ms) and `probe-cost`. Keys typed after the fresh lock never reached the probe
window. The default step order runs the forced races right after `lock`: the crash steps restart the shell, which can
change the window Hyprland refocuses, and the in-window key count needs it to be the probe window.

File watching is disabled in `shell.qml` (`settings.watchFiles: false`, re-applied after every reload since
Quickshell resets it), so only an explicit `Quickshell.reload()` reloads the shell (none in production code; the dev
hook `lock devReload` needs a dev session, see "Dev gate"). Development restarts the shell with `scripts/dev/shell-run.sh`.

## Test safety: never submit to PAM in nested
A password submitted on the lock screen is checked against the owner's real account (`omarchy-lock-password`), and a
wrong one counts a `faillock` failure shared with sudo (deny=10 → a 120 s lockout). The nested lock tests must never
cause one. R12 review #3 found 22 real submits in the logs of this tree's nested shells (2026-10-18). Root cause
(counter-review): another worktree's test (`tests/shell/overview_two_outputs.sh`, typing a tag plus Return through the
old `keys.sh`, which trusted `.dev/nested.wayland`) typed into these lock sessions after the `wayland-2` socket name
was reused; main's `dev_nested_target` guard (verified nested target for keys/pointer/shot/ipc) closes that path.
Independent guards here:
- The shell suppresses PAM in dev (see "Dev PAM suppression"): without `GRASSFIELD_DEV_ALLOW_PAM=1`, a submit is
  swallowed and logged, never reaching PAM, and the lock shows "dev: password checks disabled".
- `tests/security/reload_locked.sh` types only through `type_letters <delay> <word>`, `bg_type <word>` (fixed,
  validated arguments: `[a-z0-9]` words, a numeric delay; no option passes through) and `press_key Escape`. It
  sources `tests/security/pam_audit.sh` (read-only; finds this tree's instances by the `Launching config` line of each
  Quickshell `log.log`, since `instance.lock` is not text and `.dev/shell.log` is overwritten on restart) and, against
  a baseline taken when the run starts, scans EVERY instance log of this tree for `authenticating (submit)` (a real PAM
  call) and `dev: PAM submit suppressed` before the run and after every step; on the first new one it stops the nested
  session (`nested-down.sh`) and exits 4, loudly. The `pam-audit` step reports the run's attempts (must be 0).
  `tests/security/pam_audit.sh` alone lists every instance with an attempt (run on the 2026-10-18 logs: 20 instances,
  22 submits).
Only wrong attempts are ever used for the L2 failure path, and only by the owner with `GRASSFIELD_DEV_ALLOW_PAM=1`
(at most 3 per run; faillock deny=10).

## The lock's backdrop and data (ADR-0040 step 4a, ID-7, ID-2, ID-15; ADR-0016 section 6, W8)
Display only: nothing below can lock, unlock, delay engaging the lock or keep it from failing closed.
- **Backdrop.** The wallpaper each output shows, sharp (IQ-W4 A): the desktop records it in `wallpaper.json` `shown`
  (`WallpaperState.setShown`); `WallpaperState.lockBackdrop(output)` (`WallpaperConfig.lockBackdropOf`) gives the lock a
  picture only as a plain cache name (`<32 hex>.jpg|png`) directly in the prepared or the video folder (a video's poster),
  else the colour, else the artwork and variant the output draws (the artwork is also every picture's fallback).
  `LockStill.qml` (one per output, in `LockStills.qml`, which `Lock.qml` creates at run time, last, never as a declared
  child: a display file that fails to load costs the backdrop and the picture, never the lock) decides it while the
  session is unlocked, when the wallpaper changes: a picture is checked again by absolute path and argument vector
  (`/usr/bin/realpath -m -- <prepared> <video> <file>`: the file's real path must be a plain cache name directly in one of
  the two folders' real paths; `/usr/bin/stat --printf %f|%s --`: the raw mode, which no locale translates, a regular file
  of at most `wallpaper.lockStillMaxBytes`), one process per step and request, an answer of a superseded request dropped, then
  decoded by a hidden `Image` (`cache: true`, no `sourceSize`: the helper wrote it at the output's physical size, and a
  `sourceSize` would key Qt's pixmap cache on each window's scale; Qt's image allocation limit bounds a file that is not
  what it should be; Qt's `@2x` lookup is off for the shell, `QT_HIGHDPI_DISABLE_2X_IMAGE_LOADING=1` in its unit, so the
  decoded path is the checked one). Any failure (gone, outside the cache, too large, not decodable,
  `wallpaper.toolTimeoutMs` without an answer) gives the artwork, logged. No user original and no video decoder enters the
  module. Known limit (opus review of cbd6ef05, MINOR 1): a process of the same user writing the 0700 cache can still swap
  the file between the check and the decode, or give another image format under the cache name; bounded by the size cap,
  Qt's allocation limit and the timeout, and the lock itself is unaffected; ADR-0041 S2 narrows it.
- **Taken once.** A lock surface (`LockView`) adopts its output's backdrop when it is created, or when it is first decided
  (a hotplugged output, a wallpaper that changed just before the lock), at most `wallpaper.firstShowTimeoutMs` later, then
  the artwork; until then the surface's own colour shows: the output's ground (`Ground.of`, ID-2, ID-15), under the scrim
  and the text, which are there at once. Its `Image` asks for the url `LockStill` decoded, with the same options, so the
  pixmap cache gives it already decoded. The account's full name and picture are taken at creation too: the picture only
  when `Lock.qml`'s `avatarPreload` (the shell's PNG copy of at most 256 x 256, same options) has decoded it, else the
  initials. Once the lock shows nothing on it changes but the clock, which `SleepInhibitor.afterResume` refreshes
  (`Lock.resumed`, T-14), and the moving artwork's clouds (below).
- **The moving artwork** (ADR-0040 step 9, as the integrator decided in the review of e067f26f, after P1 measured 3.70 %
  with the clouds moving on the desktop): with `wallpaper.moving`, the Grassfield artwork's clouds move on the lock screen
  only, as macOS's moving wallpapers do; the desktop draws them still. `LockView` takes the setting once, at creation, and
  where the desktop's clouds rest until they first move (a surface whose output is known only after its creation starts
  from that output's clouds) (`WallpaperState.motionOf`, through `LockStills` and `Lock.qml`'s `moving` and `motionOf`:
  display data, without the stills off and from 0); they move by the artwork's own `wallpaper.movingFrameMs` Timer while the
  backdrop is the artwork, not while releasing, not under Reduce Motion and not while `motionHeld`: `Lock.qml` holds them
  while the displays are off (`Lock.displaysOff`, which Idle sets from its own `displayOff` in a change handler outside
  `setDisplays`) and once the controller is unlocked, should a surface outlive the unlock (opus review of bdc11b2d). When the release fade starts they slow down
  linearly to a stop within it (`Easing.OutQuad` over `Appearance.duration(lock.fadeOutMs)`, the controller's `releaseMs`,
  from the running speed: `WallpaperConfig.lockMotionRest`, half the fade further on), and the view sets `motionRest`, which
  `Lock.qml` hands to the desktop at once (`restMotion`, in a `try`; `WallpaperState.setMotion`), so the desktop under the
  lock is the frame the lock comes to rest on. Nothing waits for it: the release stays the controller's timer, the view
  emits no new signal and calls nothing; a lock request during the fade stops the slow-down and lets them move on from
  there. Not on the lock path (`tst_lockbackdrop.qml`: `lock()`, `engage()`, `release()`, `restore()` read none of it).
- **Scrim** (IQ-W4 A): see "Lock screen contrast" above; A2 holds per band by the same argument as before: every text line
  lies on `lock.dimOpacity`.
- Tests: `tst_wallpaper.qml` (`lockBackdropOf`, `withShown`; `motionIn`, `withMotion`, `lockMotionRest`), `tst_lockbackdrop.qml`
  (`test_theCloudsMoveOnTheLockOnly`), `test_contrast_tokens.py` (the model matches the scrim's lines,
  the clear band below the text bands), `lock_surfaces.sh` (the clock's one refresh), `tst_wallpaper.qml`
  (`lockStillReal`, `lockStillStatOk`). The pixmap cache hit was checked offscreen on Qt 6.10 by the reviewer. NOT VERIFIED
  (no Quickshell or nested session here; required before the merge): the real `Lock.qml` loading
  (`tests/security/lock_monitor_model.sh`, `dev_gate.sh`, `reload_locked.sh`), L1 to L5, a hotplugged output while
  locked, the clock after a real sleep, the A2 lock run over the new backdrops (`tests/visual/contrast.sh --surfaces lock`).

## Known limitations
- Successful-unlock tests need the owner's password: the agent only verifies failure paths (L2 owner check).
- L3 cannot be verified in nested.
- VERIFIED 2026-10-17 (nested): polkit agents register per logind session. The nested shell shares the owner's
  session, where omarchy-shell already owns the agent, so registration in nested fails with "An authentication
  agent already exists for the given subject" (confirmed). The module logs it once, shows no dialog and approves
  nothing. L5 functional checks move to L2 (owner); L1 covers the refusal path and unit tests of the dialog model.
- Nested runs must not take a real logind sleep inhibitor (it would delay the owner's real suspend): the
  inhibitor code path is disabled in a dev session (Dev gate) and verified in L2.
- Lock restore on Hyprland 0.56.2 (`misc.allow_session_lock_restore = true`, needed for crash recovery) does NOT wait
  for a live locker to exit: any client of the session can take a live lock over at once and, by releasing it, unlock
  the session (a Hyprland behavior no shell can prevent). Grassfield re-locks when the next ownership check sees the
  session unlocked: about 0.1 s later while a takeover is suspected (measured 9–101 ms from the release to the fresh
  lock request, `foreign-gap` and `foreign-restart`), up to ~1 s otherwise, during which the session is unlocked and
  `lock status` may still say `locked`. When Grassfield holds the lock, keyboard focus stays on its lock surface
  until something refocuses; when a foreign locker held it, Hyprland refocuses a window at once and keys typed within
  that ~0.1 s reach it (`foreign-gap`, keys forced with a 4 ms key delay: 3–18 bytes per run, previously 16–49 with the 1 s
  check; at human typing speed about one key). The fresh lock itself is not atomic when the stale lock object is the
  one Hyprland uses (release, then new request). Not done, on purpose: retaking the lock as soon as a foreign locker
  takes it over (it would fight the foreign locker, policy rule 5; its own release unlocks the session for an instant;
  the final relock still releases a lock Hyprland uses). Closing this window needs a compositor-side lock/unlock event
  (e.g. from `grassfield-compositor`) or `allow_session_lock_restore = false` (which breaks crash recovery):
  owner/compositor decision.
- Every lock check (the ownership timer, the keyboard-focus event, monitor answers) runs on the shell's event loop, so a
  foreign release is noticed only when that loop is free. A restarted shell's start-up holds it: in the integrator's run
  of 2026-11-04 every locked restart logged nothing for 1.2–2.1 s after its entrance, and a foreign locker that released
  ~1.5 s after the restarted shell took its lock over left the session unlocked until the fresh lock was requested
  1350 ms (1616 ms on main) after the release, with the 100 ms check in force throughout (not the 1 s one: the "every
  1000 ms" line logged at that relock came from `relock()` clearing the suspicion before the lock was lost, fixed).
  Needs a live foreign lock client at a shell restart and its release, normally the user authenticating to it, within
  those seconds. `foreign-restart` releases once the restarted shell's entrance is logged and its IPC, served on the same
  loop, answered within 500 ms five times in a row (≤ 150 ms still asserted); the slowest answer it saw (the hold's
  width) must stay ≤ 3 s (`HOLD_MAX_MS`; load-sensitive: SKIP above the core count), so the gap cannot widen unnoticed.
  Narrowing it needs a lighter start-up while locked (the entrance's first frames); Quickshell offers no check off the
  event loop.
- Keyboards that come and go (2026-10-24): when the session's only keyboard device goes away and another appears (a
  desktop's Bluetooth keyboard reconnecting at resume, on the lock screen), Quickshell ignores the keys of its re-created
  `wl_keyboard` until it gets a new `wl_keyboard.leave` and `enter`: the lock's password field (and the polkit dialog) is
  deaf, the session stays locked (fail closed, but a lock-out). grassfield-compositor announces the focus again once the
  client's new `wl_keyboard` exists, to the same session-lock surface only, also while locked (integrator decision
  2026-10-24; docs/specs/compositor.md "Keyboard focus before every key"); without the plugin the limit stays. NOT
  VERIFIED in a session without a keyboard of its own (no WAYLAND-1 output in nested: no backend input): the fix has run
  only in sessions with a keyboard. Its fallback announces before the first key of the new device, and that key can be
  lost (Qt 6.11 activates the window only after a `wl_display.sync` round trip): on the lock screen, a password without
  its first character, so one wrong password attempt. Owner check (L2, real session): with only an external keyboard,
  lock, unplug and replug the keyboard, then type the password; it must unlock at the first attempt.
  `tests/security/lock_keyboard_replaced.sh` (nested, bare) checks it in a session with no keyboard of its own and SKIPs
  otherwise: the condition depends on the parent seat at nested start and cannot be produced through scripts/nestctl.
- A foreign locker that takes over a live Grassfield lock and then dies (no release) leaves the session locked behind
  Hyprland's "lockscreen app died" screen (fail closed); Grassfield's own lock object is no longer used, so the session
  can only be unlocked after the shell restarts (its crash recovery takes the dead lock over).

## The security process (ADR-0041 step 1; the owner's SQ-1 B, ADR-0010 "Separate security process")
macOS keeps loginwindow (the lock screen and authorization) apart from the Dock and the menu bar; Grassfield moves its
security modules into a second Quickshell process, `grassfield-security.service` (`qs -n -p
/usr/share/grassfield/shell/security.qml`, a root of its own next to the UI's `shell.qml`, so `qs.*` resolves from the
same directory and the modules move without moving a file), one step at a time under the opus review:
- **S1 (built):** the process and its unit run beside the UI and host nothing moved yet. `shell/security.qml` imports
  QtQuick, Quickshell and Quickshell.Io only, never reloads on a file change, and answers one IPC target, `security`
  (`state`: what it hosts, `starting` at S1; `heartbeat`: the state and a sequence number), which
  `packaging/bin/grassfield-security-status` reads. The unit clears the same environment as the UI's (GF-115),
  `Restart=always`, `RestartSec=1`, a start limit of 5 starts in 300 s, `PartOf=`/`Requisite=graphical-session.target`,
  session-only, no `NoNewPrivileges` (the helpers of S2 and S3), memory guards from the nested measurement (157 MB of
  RSS at idle, the integrator's pass of #72: `MemoryHigh=320M`, `MemoryMax=640M`; S2 measures again with the lock's
  surfaces) and `CPUQuota=150%` as the UI unit's (a quota below a whole core would throttle the lock's rendering); the
  start time to the "grassfield-security: ready" line against gate P5 is still to be measured. The status helper takes
  `--any-display` when `WAYLAND_DISPLAY` is not set, so it answers from a TTY too.
  `autostart.lua` starts it just before the shell without waiting for it. Every security module stays in the UI: nothing
  about the lock, the polkit agent, idle or sleep changes at S1. Tests: `tests/security/security_unit.sh` (static),
  `ipc_inventory.sh` (the target and its caller), `unit_restart_limits.sh`, `session_services.sh`.
- **S2:** the lock, idle and the sleep inhibitor move together, every `Lock.lock` caller switches to the security instance,
  `OnFailure=omarchy-sleep-lock.service` and the sleep-lock gate key on the security unit, the UI reads the lock state
  fail closed (the pushed state OR the compositor's own lock signal OR no state, a stale heartbeat or a stopped security
  unit). **S3:** the polkit agent. **S4:** safe mode. The invariant of each state (who locks, either process down, sleep)
  is the table at the end of ADR-0041 step 1.

## Implementation (M2)
| Path | Role |
|---|---|
| `shell/security/LockMachine.js` | Pure state machine `next(state, event)` and helpers (marker, holding, lid decision, initials, Caps Lock inference, clock pattern) |
| `shell/lib/RunMode.js` | The one dev rule (`dev(GRASSFIELD_DEV, GRASSFIELD_SESSION)`, `REFUSED`), imported by the security modules through a relative path, see "Dev gate" |
| `shell/security/LockController.qml` | Auth controller over an injected PAM backend: one prompt answered, 30 s timeout, secret dropped on every outcome |
| `shell/security/PasswordField.qml` | Shared password entry (Password echo, sensitive-data hints, plain-text placeholder, return arrow) |
| `shell/security/lock/Lock.qml` | Singleton: `WlSessionLock`, `PamContext` (password; fingerprint only if its PAM file exists, paced: "Fingerprint pacing"), crash marker, IPC `lock` |
| `shell/security/lock/LockView.qml` | Lock surface (display only): the output's wallpaper, sharp (the still LockStill decoded, else its colour or `WallpaperArt`), the banded scrim, date and clock, avatar/initials, name, dark frosted field, one hint line (gate A2, see Decisions); backdrop, name and picture taken once (ADR-0040 step 4a) |
| `shell/security/lock/LockStill.qml` | Per output (display only): the lock's backdrop decided while unlocked from `WallpaperState.lockBackdrop`; a picture checked (`/usr/bin/realpath -m`: a plain cache name in the real prepared or video folder; `/usr/bin/stat %f`: a regular file of at most `wallpaper.lockStillMaxBytes`) and decoded into Qt's pixmap cache before any lock (ADR-0040 ID-7, ADR-0016 W8) |
| `shell/security/lock/LockStills.qml` | The display data the lock surfaces take (one LockStill per output, the account picture decoded ahead), created by `Lock.qml` at run time so that it can never keep the lock from loading |
| `shell/security/polkit/` | `AuthAgent` (PolkitAgent + overlay window, IPC `polkit status`), `AuthDialog`, `AuthDialogModel` |
| `shell/security/idle/` | `Idle` (IdleMonitor, dim layer, idle lock, display power-off on the lock screen, IPC `idle`), `SleepInhibitor` (delay inhibitor, PrepareForSleep watcher, retry and notice, logind budget), `IdleModel.js` |
| `config/hypr/grassfield/privacy.lua` | Omarchy's `no_screen_share` rules read from Omarchy's own files (SEC-01) |
| `packaging/systemd/sleep-lock-gate` | `ExecCondition` of Omarchy's sleep-lock unit (D-12), installed to `/usr/lib/grassfield/` |
| `tests/security/tst_devgate.qml`, `dev_gate.sh` | Dev gate: predicate; real Lock singleton offscreen in five environments |
| `tests/security/ipc_inventory.sh` | IPC surface = the table above; every action has a real-session caller, every hook its gate |
| `tests/security/screenshare_rules.sh` | SEC-01 rule set against Omarchy's, fixture tree, built-in matches always applied, wiring |
| `tests/security/sleep_lock_units.sh` | GF-030/D-12: gate script per state, unit and drop-in lines, package path |
| `tests/security/lock_privacy.sh` | Nested L4 (no notification or window content on the lock), DT-05 screen share, D-4 lid lock and display off; reads GF-REF, so it restarts a shell that lacks `GRASSFIELD_DESKTOP_SCREEN=GF-REF` before its setup (the banners follow the main display, ADR-0044) |
| `tests/security/l2_wrong_password.sh` | Nested L2 with real PAM (opt-in), 3 random wrong passwords, Return ≤ 3, one run per 15 min |
| `tests/security/reload_order/` | Offscreen `qs` test of the Quickshell reload contract the lock relies on (run by `scripts/dev/test.sh`) |
| `tests/security/marker_read/` | Offscreen `qs` test: marker reads through the real FileView (missing, `unlocked`, empty, mode 000, directory) |
| `tests/security/foreign_locker/` | Nested fixture: a foreign ext-session-lock client (Quickshell), released over IPC `foreign unlock`; refuses to lock without `GRASSFIELD_FOREIGN_LOCKER=1` or on the owner's instance (`.dev/main.instance`) |
| `tests/security/reload_locked.sh` | Nested scenario: reload with marker missing/forged, `kill -9` (L1), forged marker + crash, graceful exit (SIGTERM, `qs kill`: DT-21), file watcher off, foreign locker takeover/restart (release → fresh lock ≤ 150 ms), `lock lock` and before-sleep during a desync, forced races `relock-confirm` and `foreign-gap`, `probe-cost`, `pam-audit`; `probe-memory` (10 min, explicit) |
| `tests/security/pam_audit.sh` | Read-only PAM attempt audit over every Quickshell instance log of this tree (sourced by `reload_locked.sh`) |
| `tests/security/nested_ready.sh`, `nested_ready_unit.sh` | Readiness wait of `reload_locked.sh` and `lock_privacy.sh` (bounded, `READY_SECONDS`, default 60): GF-REF listed and a lock state from the shell, before any step and after each shell restart; an empty answer is never a state, a timeout FAILs. Offline test with stub `hyprctl` and `qs` |

IPC (all on the shell instance; classes in "IPC surface"): `lock lock` → `ok` / `already-locked` / `refused: missing-pam`
(when already locked, the session lock is re-verified, see "Lock ownership"); `lock lid` → the same or `docked`. Dev
hooks, only in a dev session (else `refused`): `lock status` → `unlocked|locking|locked|authenticating|releasing`;
`lock devReload` → `reloading` (soft reload), `lock devPauseOwnershipCheck` → `paused` (periodic ownership check off
for 10 s), `lock devForgeUnlockedAnswer` → `forged` | `not-holding` (counts one "unlocked" answer Hyprland never gave,
as a stale answer would; only a confirmed relock can follow), `lock devLockView` → JSON {state, field: empty|filled,
message, failedAttempts, pamSuppressed} (never the text or its length), `idle devSleep before|after` → `ok`
(before-sleep / after-resume path without logind; no inhibitor in dev), `idle devDisplayOff <0..600>` → `ok`, `idle devAutoSleep <1..600>` → `ok`,
`idle status` → JSON, `polkit status` → `registered|unregistered`.

States: `unlocked -request-> locking -acquired(secure)-> locked -submit-> authenticating -success-> releasing
-released-> unlocked`; `failure|error|timeout|abort` → `locked`; a lock dropped by the compositor, or a session found
unlocked under a lock still reported secure (foreign takeover + release) → `locking` (fresh lock, re-requested every
500 ms); fingerprint success enters `releasing` from `locked`. `releasing` (ADR-0040 step 4b, IQ-T2 A): the lock's scrim
and text fade out over `lock.fadeOutMs` while the session is still locked (it counts as holding: the ownership check,
`secure` and the sleep delay work as in `locked`); `released`, sent only by the controller's own Timer armed by the PAM
success (never by the view's animation), unlocks; a lock request (any reason, `Lock.lock` → `interruptRelease`), an abort
or an error during it → `locked`, a lost lock → `locking`, and the PAM success is spent: unlocking needs a new one. No
input during `releasing` (the field is disabled, `canSubmit` false). The content fades in over `lock.fadeInMs` once a
surface shows; the field takes input from the first frame (opacity stops no input). Reduce Motion caps both
(`Appearance.duration`). Unknown states/events never unlock (exhaustive test, and every two-event path from `locking`
or `locked`).

Decisions:
- Crash recovery marker: `$XDG_RUNTIME_DIR/grassfield-lock-<HYPRLAND_INSTANCE_SIGNATURE>` holds `locked`/`unlocked`,
  followed by ` sleeps=<n>` (the kernel's count of completed suspends) when it is readable
  (atomic, blocking write before the lock is requested, after unlock; re-read before and after each write, so a
  stale cache or a failed write is detected). See "Lock survival" for how a starting shell uses it.
- `PamContext.user` is left unset: PAM authenticates the uid running the shell, not `$USER`.
- Prompts are counted per `pamMessage` (one answer, a second prompt aborts): `responseRequired` stays true after
  `respond()` until PAM's next message (found in nested L2).
- Missing `/etc/pam.d/omarchy-lock-password`: new locks are refused (`refused: missing-pam`, logged); a lock being
  restored proceeds with a persistent "Authentication service unavailable" message (never fail open).
- Dev PAM suppression (defence in depth, R12 review #3 MAJOR): in a dev session (Dev gate) the lock never
  hands a password to PAM unless `GRASSFIELD_DEV_ALLOW_PAM=1` is also set (the opt-in for the L2 failure-path test).
  `Lock.qml` sets `LockController.pamSuppressed` from these at start; a suppressed `submit()` logs
  `grassfield-lock: dev: PAM submit suppressed`, clears the field and stays LOCKED (fail closed, never unlocks); the
  lock's notice line shows "dev: password checks disabled" so a dev value leaking into a real session is obvious. This
  stops a stray key that reaches the lock field in a nested test from counting a `faillock` failure against the
  owner's real account (faillock is shared with sudo). Real sessions (`GRASSFIELD_SESSION=1`, whatever
  `GRASSFIELD_DEV` says) are unchanged: `pamSuppressed` is false and authentication is normal. Unit-tested both ways (`tst_lockcontroller.qml`), structure
  checked by `tests/security/reload_order`.
- Lock before sleep: Quickshell 0.3.1 has no D-Bus/logind API, so `systemd-inhibit --what=sleep --mode=delay … sh -c
  'echo held; exec cat'`
  (stdin pipe: the inhibitor dies with the shell) plus `gdbus monitor` on `/org/freedesktop/login1` for
  `PrepareForSleep`. Both run under `setpriv --pdeathsig TERM --` (util-linux), so a shell crash (even SIGKILL) leaves
  no orphan (verified in nested: `kill -9` of the shell → its `gdbus monitor` child is gone). Released once
  `Lock.currentlySecure()` holds (a confirmed lock, re-verified with Hyprland when it was already held; see "Lock
  ownership"; read afresh, Omarchy 4.0.6 fix), or when logind's budget runs out (see "Lock coverage"); re-taken on
  resume. Skipped in a dev session (log `grassfield-idle: inhibitor skipped (dev)`). Lid close also locks by itself
  (`lock lid`, see D-4 above), before logind's `PrepareForSleep`.
- Idle: `IdleMonitor { respectInhibitors: true }`, dim at T−10 s, lock at T; Quickshell 0.3.1 keeps the timeout an
  `IdleMonitor` was enabled with, so the monitor is re-enabled on every timeout change (verified in nested).
- Lock screen contrast (gate A2, both appearances, any wallpaper): as on macOS, white text (dark palette, both appearances)
  with a soft shadow over the wallpaper (sharp since ADR-0040 step 4a) darkened by a shadow-colour scrim (`lock.dimOpacity` 0.6
  under the date and clock band and under the account column; `lock.scrimClearOpacity` 0.25 between them, where no text
  lies, the `lock.scrimFeather` ramps on the clear side of each band edge, the edges bound to the two columns' geometry, so
  every text line lies on 0.6 at every text scale; the whole surface at 0.6 when there is no room), and a dark frosted
  password field (shadow colour at `lock.fieldFillOpacity` 0.45, `textSecondary` placeholder centred in the field; no focus
  ring: the field always holds the keyboard on the lock and its blinking caret is the cue, as macOS (UI audit 2026-11-05
  U23); the SDDM greeter still draws a white ring at `lock.focusRingOpacity`). The scrim alone carries the contrast (the shadow is decoration). Minimum over 9 worst-case
  wallpaper colours (`tests/visual/test_contrast_tokens.py`, "lock ..." roles): text 5.27, initials 3.41 (large), placeholder
  8.59, dots and caret 10.75, return arrow 3.12 hovered, the greeter's focus ring 3.51, selected dots 6.31 on the selection band, which is
  4.46 against the field; rendered at rest by `tests/visual/contrast.sh`
  (surface `lock`). Display only: no binding of the field's geometry, focus or input depends on these tokens or on an effect
  (the field has no layer); a missing colour, scrim or shadow token only loses that colour or the shadow. Checked in nested
  (2026-10-18) with the seven lock display tokens deleted from `Tokens.qml` in a throwaway copy of the tree (in `$TMPDIR`: a copy
  under the worktree's `.dev/` exceeds the 108-byte Unix socket path limit of `shell-run.sh`): the lock was acquired
  (`locking -> locked`), the scrim fell back to opaque black (opacity binding failed, default 1), the field fill, focus ring
  and avatar disc became transparent, the shadow used MultiEffect defaults, and the field showed its placeholder and blinking
  caret (focused). The palette is read through `Appearance.darkColors` (= `Tokens.colorDark`
  outside dev) so that the dev-only glyph mask of the contrast run recolours it, and in dev the backdrop draws the contrast run's
  wallpaper override (`VisualFixtures.wallpaperFile`, always empty outside dev).
- Password selection (R12 review #3, A2 residual): macOS shows a selection in a password field (the secure field allows
  selecting the bullets; only copy and cut are disabled), drawn in the accent/highlight colour like any text selection, so
  the selection stays visible. `PasswordField` draws it as every other field of the shell does: the accent behind
  `accentText` dots (the lock passes its dark palette's `accent`/`accentText`; the polkit field uses the same defaults).
  Before: white dots on the white focus-ring band, 1.7–2.1:1. Seen in nested (`.dev/shots/lock-selection.png`, letters typed
  and Ctrl+A, never submitted).
- Password fields (GF-118): the lock and the polkit sheet share `PasswordField.qml`; the Wi-Fi password field of Quick
  Settings (`WifiList.qml`) is the only other one. Each sets `inputMethodHints` `ImhSensitiveData | ImhNoPredictiveText |
  ImhNoAutoUppercase` (and `ImhHiddenText` while masked), as macOS secure fields do: an input method (fcitx5 autostarts
  on Omarchy) neither predicts, autocorrects nor learns the text. `tests/security/password_hints.sh` finds every QML
  field whose `echoMode` can be `TextInput.Password` and fails when its own block lacks the first two hints.
- Untrusted strings (PAM messages, polkit message/action ID/prompt/identities, user name) use `Text.PlainText`.
  Polkit strings are also flattened to one line by `AuthDialogModel.plainLine` (C0/C1 controls and line separators →
  space, bidi overrides/isolates/marks removed, length capped: message 400, others 200) and capped in rendered lines
  by `AuthDialog` (message 4, action ID and feedback 2, elided; at most 4 identity rows, more scroll), so the sheet has
  a bounded height and the real action line and Cancel/Allow always stay visible (unit test: 5000-character
  multi-line message).

`grassfield.json`: `lock.idleMinutes` (integer 0–240, default 5, 0 = never) is read through `Settings.lockIdleMinutes`
(the settings contract, `SettingsContract.normalize`). Fail closed: only an exact 0 means never. A value above 240 is
clamped to 240 (a bounded choice, like the longest "require password" delay of macOS: the lock still fires); a value below
0, a fraction that rounds to 0 (0.4), and anything that is not a number (false, "0", null, [0]) is invalid and reads as the
default 5. The shell and the Settings app read the same (`tests/fixtures/settings-vectors.json`, run through the real store
by `tests/shell/settings_vectors`), and so does a RUNNING shell after the file is edited: the store reads the last parse of
the file text, not the JSON adapter, which keeps an old value that loosely equals the new one (0 and false, 10 and "10", 1
and true; `tests/shell/settings_reload` rewrites the file under one live store). The same holds when the file is deleted
(a fresh start without a file: the document is empty, lock.idleMinutes reads 5, writes are allowed again) or emptied, and for
what the shell writes: a change made after any of these builds the file from the file on disk, or from the schema defaults
when there is none, plus the shell's own pending change, never from the JSON adapter's retained values (which once wrote the
deleted file's `"idleMinutes": 0` back). The one exception to "a running shell reads what a restart reads" is a malformed
file: the cosmetic keys keep their last good values until the file is fixed (a restart would show the defaults), but the lock
timing fails closed: `lock.*` reads the default 5 at once, as a restart does, and nothing is written while the file is
malformed. Known limit (pre-existing): there is no lock between the fresh read of the file and its atomic replacement, so an
external edit made in that instant can be lost. The file is never read without a bound: both reads (the load and the fresh
read before a write) are one script that reports a file as read only when the read ended without error and returned exactly
the size the file had (a read cut after 5 s, a failing `head`, a file swapped under the read is "incomplete": malformed, never
an empty file, whose defaults a write would put over the user's settings), and that opens only a regular file of at most 1 MiB (a symlink to /dev/zero, a FIFO, a
directory, a 300 MB file are read as malformed without being opened or read: `tests/shell/settings_bounds` measures the
shell's peak memory, +3 MB for each of them where the unbounded read cost 3.7 GB), cuts a read after 5 s, and reads a file
that is not readable (chmod 000) as malformed too: `lock.*` reads 5, the cosmetic keys keep their last good values, nothing
is written. A symlinked `grassfield.json` is followed (its target is read and replaced, the link stays) and a replacement
of the link by a regular file is noticed within 10 s. A failed write keeps its change pending and is retried; a file that could not be used is marked unread (its
signature never equals the one of a usable file) and the poll (a stat every 10 s) reads it again in full at once when its
signature changed, so a repaired or removed file is noticed without a watch event, and a change that waited is written then.
While its signature stays the same the full re-read backs off (10 s, 20 s, 40 s, ... capped at 5 min, `badRetryCap`; it starts
over when the signature changes or a read succeeds), so a permanently unusable file (over 1 MiB, a FIFO) costs one bounded read
per 5 min instead of one per 10 s (`tests/shell/settings_backoff`: 61 full reads over 6 s at a 100 ms poll before, 11 after).
Trade-off: a repair that changes no signature and raises no watch event (a recovered reader, a `head` that stalled or failed) is
noticed within 5 min, not 10 s; `lock.*` stays at its closed default until then. The write keeps the mode of the file it replaces (0666 minus the umask for a new one), syncs the
temporary file before the rename, and refuses a target that became a directory. Both unusable-file paths (the load and the read before a write) mark the file as unread, so
the poll reads it again whichever read found it unusable, and a change made while the file was unusable is written once the file
is removed. The read holds the text (at most 1 MiB) in a shell variable and creates no temporary file, so a full or unwritable
`$TMPDIR` cannot make every read incomplete. Behaviour change: a `grassfield.json` the user cannot write (mode 0444) is never
written, because the mode is kept and the temporary file cannot be filled: the change stays pending, is retried at the 60 s
backoff, and one warning is logged. `IdleModel.timings` is a stricter backstop: anything that is not a number,
above 240 or not whole reads 5, and only a number that is exactly 0 is never.

Known gaps: polkit `details` (program, command line, process) are not exposed by Quickshell 0.3.1 `AuthFlow`; pkexec
puts the program in `message`, which is shown, and the action's icon is shown (see "Polkit details"). Caps Lock is
inferred from typed letters (no lock-key state in Quickshell). D-Bus `org.freedesktop.ScreenSaver` inhibitors are served
by the menu bridge and hold the idle lock only (see D-4); the GTK/KDE portal `Inhibit` reaches them only when its backend
forwards to that interface (not verified). Display power-off on the
lock screen is done (30 s), not yet seen on hardware (L2†). When grassfield-shell has failed for good, the fail-safe
restarts it before sleep; a shell that cannot start at all leaves the machine to sleep unlocked (no second locker, by
the security rules; see "Lock coverage").
The marker file of a dead compositor instance stays in `$XDG_RUNTIME_DIR` until logout (a few bytes).
Lock screen contrast: the lock's error, notice, Caps Lock, typed-dots, return-arrow and focus-ring states are proven by the
token calculation only (the contrast run's nested capture is at rest: nothing is typed into the nested lock there; the
selection was only looked at, in one nested capture). The date (22 px, weight 600) is treated as normal text (4.5:1), not
large text.
`Quickshell.reload(true)` (hard reload, never called by Grassfield) while locked makes Quickshell abort
(`qFatal`: the old instance still holds the lock): the compositor keeps the session locked and the restarted shell
re-acquires it (fail closed, not graceful). The stranded-lock check cannot tell a crashed instance's lock from a live
foreign locker (e.g. hyprlock) started before the shell: Hyprland hands the live lock over at once, and the foreign
locker's later release is followed by a fresh Grassfield lock (see "Lock ownership" and Known limitations).
