# ADR-0019: One run-mode rule (`Mode` in `qs.lib`, `apps/runmode.h` in C++)
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (integrator, under owner delegation D-5); accepted when its first slice merges (M1) · Date: 2026-10-24 ·
Decider: integrator

## Context
Plan: docs/audits/final-1.0/refactor-plan.md §2 (GF-089). Line numbers re-checked on main 370a45f (only docs changed
since 2dfd992, so they hold).
- 23 `GRASSFIELD_*` variables are read in `shell/` and `ui/` through 102 `Quickshell.env(` calls. 29 product QML/JS files
  mention `GRASSFIELD_DEV` without DevGate, 17 of them in code; 9 files use `shell/services/DevGate.js`.
- Five different rules coexist: `DEV==="1"` (`shell/services/Apps.qml:124`, `Audio.qml:55`, `Battery.qml:24`,
  `Power.qml:12`, `shell/widgets/WidgetBase.qml:18`, `shell/platform/MenuBridge.qml:27`, ...);
  `DEV!=="1" || PRIVATE_BUS` (`shell/menubar/TrayHost.qml:17`); `SESSION==="1" && DEV!=="1"`
  (`shell/platform/UpdateNotice.qml:18`); `DEV==="1" && !privateBus` (`shell/services/Media.qml:31`); DevGate inline and
  DevGate.js (`shell/platform/Capabilities.qml:8,81`, `shell/security/lock/Lock.qml:23,72`, `idle/Idle.qml:14,29`,
  `polkit/AuthAgent.qml:12,111`, ...).
- `stateDir` is copied 8 times (`shell/desktop/DesktopFiles.qml:23`, `services/RecentItems.qml:24`,
  `WallpaperState.qml:35`, `Connectivity.qml:159`, `notifications/Notifications.qml:76`, `search/Search.qml:101`,
  `launchpad/AppsController.qml:96`, `widgets/Widgets.qml:30`); the shell UX branch adds a 9th. `configDir` is defined in
  `shell/services/Settings.qml:14` and again in C++ (`apps/settings/src/backend.cpp:51`, `apps/files/src/filesapp.cpp:160`,
  `folderstylestore.cpp:185`, `apps/preview/src/previewapp.cpp:21`).
- The C++ rules differ too: `apps/appscope.h:17` (session && !dev); `apps/files/src/filesapp.h:72`, `placesmodel.cpp:24`,
  `apps/settings/src/systemguard.cpp:13`, `apps/wallpaper-tool/src/main.cpp:385` (`DEV==1` only).
- Open dev hooks that stay active in a real session when `GRASSFIELD_DEV=1` leaks:
  1. the wallpaper helper's localhost URL (`apps/wallpaper-tool/src/main.cpp:385`, checks `DEV==1` only);
  2. the compositor's `testFault` (`compositor/src/Ipc.cpp:150`, reads `GRASSFIELD_DEV` with `std::getenv`);
  3. the opposite failure: the menu bridge refuses a real session where `DEV` leaked
     (`bridges/menu-bridge/src/main.cpp:76-96`: `dev` takes the private-bus branch and refuses the default bus), so
     global menus stop working.

  The plan closes them as follows: the wallpaper helper moves to `apps/runmode.h` in M6 (W2); the bridge predicate and
  `testFault` are fixed in M7 (W4; mandatory by integrator decision 2026-10-24: both are real-session defects).

## Decision
One predicate, read only by `qs.lib` `Mode` (QML) and `apps/runmode.h` (C++):

    dev = GRASSFIELD_DEV == "1" && GRASSFIELD_SESSION != "1"

"dev" means both "test hooks allowed" and "never act on the owner's machine". The bridge and the compositor keep their own
reads (process boundaries; the compositor has no Qt) but use the same predicate. A leaked dev value changes nothing in
a real session. The dev scripts are the only supported way to get a dev session (`devenv.sh` already unsets
`GRASSFIELD_SESSION`).

Derived values: `fixtures = dev && VISUAL_FIXTURES == "1"`; `ownBus = !dev || privateBus` (notification server, tray
watcher, media control); `updateNotices = session`.

`shell/lib/` is the new module `qs.lib`, the bottom layer (ADR-0021): `RunMode.js` (pure functions, the only definition
of the rule) and `Mode.qml` (a singleton, the only reader of `GRASSFIELD_*`). `Mode` also provides `configDir`,
`stateDir`, `shellDir` and `devValue(name)`, which returns the variable only when `dev`. The C++ side is the header-only
`apps/runmode.h` next to `apps/appscope.h`: the same rule, `configDir()`, `stateDir()`, `shellIpcArgs()`; used by Files,
Settings, Preview and the wallpaper tool. Parity between QML and C++ comes from shared vectors in
`tests/fixtures/run-mode-vectors.json` (same pattern as `glyph-vectors.json`).

Variable classes:

| Class | Variables | Rule |
|---|---|---|
| Dev plumbing | `DEFER_HOLD` (`1` keeps the deferred surfaces of `shell.qml` unbuilt until `qs ipc call deferred release`; tests/shell/deferred_early.sh, ADR-0056 amendment), `STACK_HELPER` (the Dock stack helper, ADR-0025), `SETTINGS_CMD`, `PREVIEW_CMD`, `FILES_CMD`, `FILES_REMOVABLE_JSON` (the Store's answer to `--removable` as JSON text, for Files' Move to Trash on an application; ADR-0046), `OPEN_POLICY`, `ONLINE_BASE_URL`, `WEATHER_BASE_URL` (the Weather widget's loopback test server, ADR-0045 OC-14), `FIXED_TIME`, `WALLPAPER_FILE`, `DESKTOP_SCREEN`, `DESKTOP_DIR`, `SEARCH_ROOT`, `SEARCH_PLOCATE_DB`, `CURSORS_*`, `PICTURES_DIR`, `MENU_BRIDGE_SOCKET`, `SHELL_DIR` (also `config/hypr/grassfield/bindings.lua`), `TRANSLATIONS_DIR` (C++ loader `ui/i18n/translationloader.h`, since the re-review of 2b8e13a), `LID_LOCK`, `LID_FALLBACK`, `LID_PROC`, `DRM` (`packaging/bin/grassfield-lid`), `LID_TOOL` (the clamshell stand-in; these five and bindings.lua's `SHELL_DIR` since the follow-up of the re-review of bf9e280: a lock request must not be redirected by the session environment), `FILES_PKEXEC` (the recording stand-in for `pkexec` of ADR-0028's privileged path, when that path is built), `UPDATE_FIXTURE` (a JSON answer used instead of the update checker), `POWER_FIXTURE` (Settings: a `power.state` JSON answer used instead of UPower, so the visual tests show Battery or Energy whatever battery the machine has; `tests/visual/energy-pane.sh`), `UPDATE_CHECK_CMD` (the checker to run) and `UPDATE_PKEXEC` (the recording stand-in for `pkexec` of the channel helper, honoured by `grassfield-channel-set`; in a dev session Settings runs none of the update actions, ADR-0033), `UPDATE_RUN_DIR` (the folder whose `software-update-run.json` the shell's Software Update service watches for the end of an Update Now run; unset, `update-run` under the dev state: a dev session never reads or makes the real session's run state, ADR-0033 "Step 4"), `ACTIVITY_DEV_ROOTS` (Activity Monitor's dev guard: pid records of `scripts/dev/pidfile.sh`, separated by ':', whose processes and their descendants a dev session may quit or signal; none named, every action is refused; ADR-0038 AD42), `CAPTURE_HELPER` (the capture helper the capture toolbar runs and the shell's recording stop calls, ADR-0045 OC-1: a fake in the nested checks; unset, a dev session runs no capture and stops nothing; the toolbar's state is then read from `capture-state.json` under `GRASSFIELD_STATE_HOME`) | honoured only when `dev`; inert otherwise |
| Always honoured | `CONFIG_HOME`, `STATE_HOME`, `APPS_TRACE`, `APPS_GTK_USE_PORTAL` (set by `env-grassfield` when the session routes GTK to the portal; `Mode.appsGtkPortal`, ADR-0035 decision 2b-12) | as today |
| Mode inputs | `DEV`, `SESSION`, `VISUAL_FIXTURES`, private bus selection | read only by `Mode` / `runmode.h` |
| Dev plumbing, clipboard history (ADR-0034) | `CLIPBOARD_HELPER` (another clipboard helper binary, or a fake one for the headless Search tests), `CLIPBOARD_DISPLAY` (in a dev session, the absolute path of the only Wayland socket the shell passes to the helper's `--display`: the nested socket set by `scripts/dev/shell-run.sh`) | honoured only when `dev`; inert otherwise. In a dev session without `CLIPBOARD_DISPLAY` no helper starts and nothing is captured. This guard is not the only one: the helper itself never reads `WAYLAND_DISPLAY` and reaches only the socket named by `--display`, so a run where `dev` is false (`GRASSFIELD_SESSION=1`) cannot pick the owner's display by default either; the helper's tests run under `env -i` and pass their fake server's socket |
| Dev plumbing, Grassfield Store (ADR-0037) | `STORE_CATALOG_URL` (the catalog's URL instead of the channel's; `file://` allowed), `STORE_KEYRING` (a test keyring folder: `grassfield.gpg`, `grassfield-trusted`, `grassfield-revoked`), `STORE_FIXTURE` (a folder with fake `bin/pacman` and `bin/gpg`, a pacman keyring to copy under `gnupg/`, fake AppStream data under `swcatalog/` and a `grassfield.conf`; the Store reads nothing of the system's package manager then), `STORE_OFFLINE` (`1`: the Store counts as offline whatever the network says, for the offline captures and tests; step 2; `metered`: online on a metered connection, `0`: online and unmetered, whatever the network says, for the tests of what is asked automatically; step 3b2), `STORE_PKEXEC` (the program run in pkexec's place for the helper's operations; step 3), `STORE_INSTALLER` (the program run in place of Omarchy's commands, Omarchy's terminal launcher included, and of Open's launchers, given the command's name then its arguments; step 3; without these two a dev session runs no operation and opens nothing; with `STORE_FIXTURE`, Omarchy's folder and `grassfield-store-run`'s are the fixture's too, step 3b1), `STORE_CMD` (the Store the launcher runs to hand an app over, ADR-0046: default `.dev/build/grassfield-store`; read by the shell's Apps controller), `STORE_AUR_URL` (the AUR's web service instead of aur.archlinux.org: a `file://` folder whose `info.json` and `search.json` answers the client filters by the names or the term asked, and `pkgbuild/<base>`; step 3b2); read only through `apps/store/src/storeenv.h` and `runmode::devValue` | honoured only when `dev`; inert otherwise: a real session uses the channel's URL, grassfield-keyring's private folder and the system's pacman |

`SHELL_DIR` is the directory of the shell that `qs ipc -p` targets. In dev, an app that must call the shell
(`runmode::shellIpcArgs()`) uses it, or refuses with a clear error when it is not set: a dev session never drives the
installed shell, which may be the owner's real one.

Amendment (slice M2, integrator decision 2026-10-25): a `qs/<module>` directory on `QML_IMPORT_PATH` overrides any
`qs.*` module (M1 review note 5), so the security modules (`shell/security/**`) and the security gates do not read the
rule through `qs.lib` or `Mode`: they import `shell/lib/RunMode.js` by a relative path and call
`RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))` themselves (answer `RunMode.REFUSED`).
That call is the one exception to "only `Mode` reads `GRASSFIELD_*`" in QML; M8's `tests/ci/run_mode.py` must accept
exactly it in the security modules. Non-security modules use `Mode`. `tests/security/ipc_inventory.sh` holds both forms
to the definitions.

Amendment (slice M4, 2026-10-25): the QML half of the enforcement exists as `tests/ci/run_mode.py` (in `check-shell`, selftest in
`just test`). It reads every .qml file outside `shell/lib` from Qt's syntax tree and refuses any string literal that starts with
`GRASSFIELD_` and any `env` call whose name is not one string literal; a .js file that imports Quickshell is refused. The security
exception is by name: `shell/security/**` may spell `GRASSFIELD_DEV`, `GRASSFIELD_SESSION` and (the lock) `GRASSFIELD_DEV_ALLOW_PAM`, and
nothing else (amendment of 2026-11-09, ADR-0041 S3: the secret sheets moved into the security process, which cannot ask `Mode`
either, so `shell/security/host/SheetHost.qml` alone may also spell `GRASSFIELD_PROMPTER_SOCKET`, the dev plumbing value
`Mode.devValue("PROMPTER_SOCKET")` gave the UI before, read behind that file's own `RunMode.dev` gate and ignored by
`Prompter.socketPath` outside a dev session); it goes away when the packaged shell's import path is fixed. `Mode` also offers `stateHome` (the raw
`GRASSFIELD_STATE_HOME`, for Apps and Capabilities) and `appsTrace`. The C++ half (`qEnvironmentVariable("GRASSFIELD_` outside
`apps/runmode.h`) stays with M6/M8.

## macOS reference
A debug default never changes a shipped app's behaviour unless the developer build reads it; there is no "developer
mode" that disables Quick Settings toggles, power actions or global menus. The real session simply works.

## Alternatives rejected
- Keep per-file rules and document them: five rules already diverge and two dev hooks are open; not auditable.
- Only fix the open hooks: leaves the 102 reads and the C++ rule copies to drift again.
- A shared C++/QML library for the rule: needs a new module and build coupling; shared vectors give parity at lower cost.

## Consequences
- A leaked `GRASSFIELD_DEV=1` no longer turns off toggles, power actions, the tray, update notices or global menus.
- Enforcement: `tests/ci/run_mode.py --selftest` (M8, in `check-contracts`): no `Quickshell.env("GRASSFIELD_` outside
  `shell/lib/Mode.qml`, no `qEnvironmentVariable("GRASSFIELD_` outside `apps/runmode.h`, except the documented exceptions
  (bridge, compositor, Lua, units). `ipc_inventory.sh` accepts `Mode.dev` / `Mode.fixtures` as exact gates (M2, security
  review; a look-alike mutant must fail).
- Parity: `tests/unit/tst_runmode.qml` and `tests/unit/files/tst_runmode.cpp` against the shared vectors. Existing:
  `tst_devgate.qml`, `dev_gate.sh`, `audio_dev_guard.sh` (new case "leaked dev in a real session acts"),
  `settings_system_guard.sh` and a wallpaper-tool test (localhost URL refused when `SESSION=1`).
- Slices (plan §2): M1 (qs.lib, Mode, vectors), M2 (gate flip, security), M3 (services), M4 (platform, menubar),
  M5a/M5b (desktop, widgets, notifications, search, overview), M6 (C++ runmode.h), M7 (bridge and testFault),
  M8 (enforcement).
- Verified in M7 (Hyprland 0.56.2 binary, the `hl.env` binding in `Config::Lua::Bindings::Internal::registerConfigRuleBindings`):
  `hl.env(name, value[, dbus])` calls `setenv(name, value, 1)` in Hyprland's own process. On the first parse always; on a
  config reload only when the variable is unset or its value differs. So `session.lua`'s `hl.env("GRASSFIELD_SESSION", "1")`
  is in the environment the plugin reads with `getenv` (and children inherit it), before the plugin is loaded (it comes
  first in `session.lua`). The plugin reads the two variables at each `testFault` request, not once, so a reload that
  changes them counts. The nested session (`dev.lua`, `devenv.sh` unsets `GRASSFIELD_SESSION`) has no `GRASSFIELD_SESSION`.
