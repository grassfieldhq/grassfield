# ADR-0011: One app launch path, isolated in dev sessions
Status: Accepted (owner delegation D-5, 2026-10-23; status before acceptance: Proposed (applied provisionally)) · Date: 2026-10-17 · Decider: owner

## Context
The Dock, Apps, Search, the menu bar's app menus, the Dock menu and the desktop each started applications
their own way (`DesktopEntry.execute()`, `Quickshell.execDetached`, `gio open`). In a dev session (nested
Hyprland on the owner's machine, `GRASSFIELD_DEV=1`) an app started by the shell runs with the owner's real
profiles: a reviewer's mis-click started Chromium with the owner's default profile and Nautilus on the real
home folder (the maintainers' project log incident, 2026-10-17). Several modules need the same rule, so it is a cross-module
contract.

## Options
1. **One launch service in `shell/services/Apps.qml`**: `Apps.launch(entry|action)` for desktop entries,
   `Apps.openDetached(argv)` for helpers that open files in an app (`gio open`, `xdg-open`, `gtk-launch`),
   `Apps.openEnvironment()` for `Process` objects. In a dev session they add isolated `XDG_CONFIG_HOME`,
   `XDG_CACHE_HOME`, `XDG_STATE_HOME` (and `XDG_DATA_HOME`) under `.dev/apps-home`; otherwise they call the
   unmodified Quickshell API.
2. Isolate the whole nested session (a separate `HOME` for the nested compositor). Pros: complete.
   Cons: the shell itself must read the repository and `.dev/` paths; Wayland/D-Bus sockets and fonts break in
   subtle ways; diverges further from the real session.
3. Per-module guards. Cons: easy to miss one caller (the review found two).

## Decision (proposed)
Option 1. Every shell module that starts an application or opens a file in one goes through `Apps.launch`,
`Apps.openDetached` or `Apps.openEnvironment`. Direct `Quickshell.execDetached` remains allowed only for
non-app helpers (`cp`, `wl-copy`, `systemctl`, `kill`, `gio trash`) and shell-internal commands.
- Dev detection: `GRASSFIELD_DEV === "1"` only. In a real session the user's environment passes through
  untouched (no variable added or removed).
- Field codes are stripped (`AppLaunch.stripFieldCodes`); `Terminal=true` entries go through `xdg-terminal-exec`,
  as `DesktopEntry.execute()` does.

### Amendment 2026-10-20: one scope per application in a real session
The first real-session run (owner L2) showed every application started from the Dock, Search, Apps, the desktop or
Settings running inside `grassfield-shell.service` (`/proc/<pid>/cgroup`; their output in the shell's journal). A
restart or crash of the shell (`Restart=on-failure`, default `KillMode=control-group`) would close all of them: not the
macOS model, where the Dock quitting never quits an app.
- In a real session (`GRASSFIELD_SESSION=1`, not a dev session) with `uwsm-app` installed (uwsm is a dependency), the
  launch path wraps the argv as `uwsm-app -- <argv>` (`AppLaunch.scopedArgv`, `Apps.scoped`): each application gets
  its own scope in `app-graphical.slice`, as the Omarchy session starts its apps (Omarchy `helpers.lua`). The scope
  runs the command in the launcher's process context, so the environment the shell adds (pointer size) still applies.
- `Apps.launch` no longer falls back to `DesktopEntry.execute()` in a real session (it would bypass the scope); the
  Settings launcher (`SettingsApp`) and the desktop's `gio open` go through `Apps.scoped` too.
- Dev sessions are unchanged (no scope: the nested apps must not appear in the owner's user manager).

## Evidence
- Merge bc382c6: a foot started from the nested Dock had `XDG_CONFIG_HOME=.dev/apps-home/config` (and cache,
  state) in `/proc/<pid>/environ`; reviewer confirmed, and confirmed by code reading that real sessions are
  untouched (`shell/services/Apps.qml`).
- Review gaps (Trash tile, network settings, `XDG_DATA_HOME`) are in the fix pass after that review.

## Consequences
- New launch call sites must use the service; reviewers check `Quickshell.execDetached` additions against the
  allowed list above.
- Dev sessions never share app profiles with the owner; app state for dev runs lives in `.dev/apps-home`.
- The real trash is never reachable from a dev session. The Dock Trash tile opens the isolated folder
  `.dev/apps-home/data/Trash/files` as a plain directory (`gio open <path>`), never `trash:///` (served by the
  owner's gvfsd-trash). Grassfield Files (which inherits `GRASSFIELD_DEV=1`) hides its Trash sidebar entry, does not
  open the KIO `trash:/` listing and makes Empty Trash a no-op in dev (simplest safe option; no isolated Trash
  location in Files). Real sessions keep `trash:///` and the Trash place unchanged.

### Addendum: dev open policy and private bus default (counter-review fix)
The first fix still let a dev session escape: `gio open <isolated trash folder>` runs the default folder handler, which
is Nautilus (`DBusActivatable=true`); GIO starts it over D-Bus, dropping the isolated environment, in the owner's
session, with the owner's real trash in its sidebar. Any D-Bus activatable handler does the same.
- A dev session never asks GIO, xdg-open, `gtk-launch` or `gio launch` to start an application. `Apps.openDetached`
  recognises those helpers (`AppLaunch.openRequest`) and runs `scripts/dev/open-policy.sh` instead: a folder opens in
  Grassfield Files and a file Preview can show (images, PDF, text and code, audio, video) in Grassfield Preview, both by
  direct exec through `isolated.sh` (isolated homes and `GRASSFIELD_DEV=1`); anything else is refused with one line
  (`open refused in dev: <type>`, also in `.dev/open-policy.log`). Real sessions keep `gio open` unchanged.
- Code that runs `gio open` itself in a `Process` (`shell/desktop/DesktopFiles.qml`, which another change owns) gets the
  same policy: `shell-run.sh` puts `scripts/dev/open-shims` (`gio`, `xdg-open`, `gtk-launch`) first on the shell's PATH
  (QProcess resolves a program on its parent's PATH, not on the PATH set in the Process environment); the shim applies
  the policy to `open`/`launch` and runs the real `gio` for the other subcommands.
- The private D-Bus session bus is the default for dev sessions (`nested-up.sh`, `shell-run.sh`; `--session-bus` is
  the opt-out for the rare test that needs the owner's bus). Its dbus-daemon starts with the isolated `XDG_*` homes under
  `.dev/apps-home` and `GRASSFIELD_DEV=1`, so a service the bus activates is isolated too.
- Amendment 2026-10-26 (re-check of 06da80f, MEDIUM-1; owner decision "Bloquer les portails"): the bus's activated
  services also inherit the owner's `XDG_RUNTIME_DIR`, and Qt's gtk3 platform theme asks the desktop portal when the shell
  or an app starts (auto-start on), so xdg-desktop-portal started there, and with it xdg-document-portal, which unmounts the
  owner's `$XDG_RUNTIME_DIR/doc` to mount its own. `shell-run.sh` now writes `org.freedesktop.portal.Desktop` and
  `org.freedesktop.portal.Documents` service files with `Exec=/bin/false` in the bus's data home (`.dev/apps-home/data/
  dbus-1/services`, which wins over the system's), on every run, asks a bus kept from an earlier run to read its service
  folders again (`ReloadConfig`: it watches only the folders that existed when it started), and warns when either portal
  already runs on it. A file in `$XDG_RUNTIME_DIR/dbus-1/services` would win over the block: `shell-run.sh` refuses to
  start the bus when that folder names either portal. Cost: no portal in a dev session (no portal file chooser or screen
  sharing for the apps started there; GTK4 and Chromium read their settings, the window-button layout among them, from
  GSettings instead of the settings portal: `tests/compositor/third_party_chrome.sh` now checks that the portal is refused
  and the layout comes through GSettings). Rejected: a runtime directory of the bus's own (activated services would lose the
  nested Wayland socket, named relative to it, and PipeWire), and only clearing `QT_QPA_PLATFORMTHEME` (another client could
  still start the portal). Checked on a dbus-daemon 1.14 bus started as `shell-run.sh` starts it, with portal services
  planted in `XDG_DATA_DIRS`: neither starts, also on a bus started before the block and reloaded; without the block both
  start. Not verified nested: after `just nested-up` and opening Settings, `busctl --address=$(cat .dev/bus.address) list
  | grep portal` lists nothing.
- Amendment 2026-10-27 (security counter-review of f9e24e1, LOW-2): the block above covered two names, and the bus still read
  the standard session service folders with the owner's `XDG_RUNTIME_DIR`, where this machine also has gvfs
  (`org.gtk.vfs.Daemon`, whose gvfsd-fuse mounts `$XDG_RUNTIME_DIR/gvfs`), gnome-keyring, dconf and some forty others
  activatable. The bus is now an allowlist of none: `scripts/dev/dev-bus.conf`, the session configuration without
  `<standard_session_servicedirs/>` and without its includes (a `session-local.conf` could add a folder), so the only
  activatable name is `org.freedesktop.DBus`; the per-name block, its refusal on `$XDG_RUNTIME_DIR/dbus-1/services` and the
  `ReloadConfig` are gone with it. The dev session needs no activation: the names it uses are owned by what `shell-run.sh`
  starts (the shell, the menu bridge); apps and tests are clients. `shell-run.sh` refuses a bus that lists anything else
  (`scripts/dev/dev-bus-check.sh`, `ListActivatableNames`), such as one kept from an earlier run: `just nested-down`, then
  `just nested-up`. Cost: in a dev session no portal (as before), no dconf writes (reads need none), no gvfs, no keyring,
  no accessibility bus, no permission store (Settings > Privacy & Security shows the bus's reason instead of its lists), no
  input method daemon. `tests/security/dev_bus.sh` starts a bus with that file under `.dev/` (never the owner's bus), with
  service files planted in every folder the standard configuration reads, and checks it lists only itself; controls (the
  standard folders, a service folder, the system's `session.conf`) make the guard fail. Not changed: the other tests that
  start their own `dbus-daemon --session` (`tests/apps/files_*.sh`, `tests/integration/tray_host.sh`, `launcher_entry.sh`,
  `menu_bridge_memory.sh`). Not verified nested.
- `isolated.sh` exports `GRASSFIELD_DEV=1`, so Grassfield Files started through it hides its Trash place, and in a dev
  session also the "Empty Trash" action (no confirmation that does nothing).

### Addendum: native apps, helpers and the start queue
- `apps/appscope.h` is the C++ counterpart of `Apps.scoped` for the Grassfield apps (Files and Glance start Preview,
  Preview starts the full viewer): `startApplication` wraps the command as `uwsm-app -- <program> <args>` in a real
  session (`GRASSFIELD_SESSION=1`, not `GRASSFIELD_DEV=1`, `uwsm-app` on the PATH, found synchronously), so a child does
  not stay in the unit of the app that started it. One copy, shared by the apps.
- `Apps.runHelper(argv)` is for short helpers that are not applications (`gio trash`): never in a scope of their own,
  with the same isolated environment and, in a dev session, the same open policy as `openDetached`.
- Start queue: the detection of `uwsm-app` is asynchronous, so every application start goes through
  `Apps.whenScopeKnown`: it runs at once when the answer is known (always in a dev session), otherwise it is queued
  and released when the probe answers. Quickshell sends no `exited` when a start fails, so the queue is also released
  when the probe's `running` goes back to false without a `started` (logged); the launches then start unscoped rather
  than wait for ever. Glance cancels a start that is still queued (Esc, a second Space).

### Addendum: the crash notice reads the scope name and Reopen uses the same path (2026-10-25)
- `grassfield-crash-watch` (a user service, not a shell module) announces "<App> quit unexpectedly" only for an application
  scope under `app.slice` whose cgroup is gone or empty after a crash (`packaging/bin/grassfield-crash-watch` header). The
  scope name `app-<launcher>-<id>-<random>.scope` is the contract it reads: the Dock starts `uwsm-app -- <Exec argv>`, so `<id>`
  is usually the binary's name; the watcher finds the desktop entry by id, then by Exec binary, TryExec and StartupWMClass.
  The Dock's launch path is unchanged. Later improvement: `uwsm-app -a <desktop id>` would name the scope after the entry.
- Reopen starts the application through this path: `systemd-run --user --collect --quiet -- uwsm-app -- <id>.desktop`. The
  transient unit is outside the watcher's sandbox (`uwsm-app` evals the scope command in its caller's context, which would
  otherwise give the application no network and its seccomp filter); `uwsm-app` then puts the application in its own
  scope. Only a plain `<name>.desktop` id is passed, after `--`. No Reopen without a unique entry or without `uwsm-app`
  (never a launch outside a scope).

### Amendment 2026-11-08: Files opens apps the Gatekeeper way (GF-070 and DT-10 amended)
Context: GF-AUDIT-001 DT-10 / GF-070 (commit e6e75bc3) made Grassfield Files refuse every program, script, AppImage and
Windows or Java type it was asked to open, so that a double-click on a downloaded file never ran code. The owner reported on
2026-11-08 that no AppImage "or others" could be started from Files and that an app delivered as a `.dmg` did nothing: too
strict for a desktop. Neither ADR-0022 (the desktop's file operations) nor ADR-0028 (permission changes) owns the open
policy (it lived in `docs/specs/security.md` alone, `grep GF-070 docs/decisions` finds nothing); this ADR owns the app
launch path the change starts programs through, so the decision is recorded here. Integrator decision under the owner's
standing rule "closest to macOS 27, no technical step for the end user"; it relaxes a security control, so an opus security
review follows.
Decision: copy Gatekeeper, from "never run" to "run after consent".
- Opening a native program or AppImage runs it (`apps/files/src/launchguard.h` `RunProgram`, decided by the ELF header and
  the execute bit, never by the name). It runs through this ADR's path: `grassfield::apps::scopedCommand` (its own
  `uwsm-app` scope in a real session; a program path uwsm would read as a desktop entry, "…/Tool.desktop:run", is refused),
  `posix_spawnp` without a shell, its own session, stdin and stdout on `/dev/null`, the home folder as working folder (as
  the Dock's apps; macOS starts apps in "/") (`apps/files/src/programlaunch.h` `Run`). Its error output is read for one second from
  a datagram socket (closed afterwards: later writes fail without a signal and never block it) so that a start that fails
  gets a plain alert (another computer's program, a missing library, an AppImage without fuse2, a refused start).
- A program that came from the Internet (Chromium's and Firefox's `user.xdg.origin.url` / `user.xdg.referrer.url`; the
  repository had no quarantine mark of its own) runs only after the user said Open in the Files window's sheet, which names
  the host it came from; Return and Esc cancel. After Open, Files writes `user.grassfield.approved` = `1 <inode> <mtime ns>
  <size>` (macOS clears the quarantine): an approved, unchanged file never asks again, a changed one asks again. A program
  without the user's execute bit gets the same sheet and Open sets u+x (only; ADR-0028's unprivileged path, through the
  descriptor that was checked, then verified: a FAT mount that ignores it gets the copy); one on a `noexec` or read-only disk
  is copied to `~/Applications` (macOS: `/Applications`), checked against the approved file, and run from there.
- Files keeps the download marks on what it makes from a downloaded or remote file (the Archive Utility model, reviews of
  0c51550e and 48475cf6). Expand of an archive that carries a download mark completes only if every extracted regular file
  got the archive's marks, fail closed: they are written in the private staging folder before the final rename, on a worker
  thread, through descriptors that follow no link; files and folders whose user bits keep the marks out (files 0100, 0500,
  0555; folders 0100, 0300) are opened up for the moment of the walk and given their mode back; there is no entry cap; one
  file left unmarked, a folder that can't be walked, a tree deeper than 256 folders or a cancel, and nothing is kept and a
  sheet says the archive couldn't be expanded safely (bsdtar keeps the members' execute bits, so an unmarked program would
  run with no sheet). A copy or move from a remote location gets its source address, without credentials, as its
  `user.xdg.origin.url`. Names are judged as the eye reads them (NFKC, combining marks, format, default-ignorable and blank
  characters dropped, dot lookalikes read as "."), and a program whose extension is not plain ASCII is refused as a
  disguise. Open With > Wine, Bottles or Java follows the open rule (root refused, the sheet first when downloaded).
- Scripts open in the default text editor; Open With > Terminal runs an executable one in the session's terminal
  (decision F-7, `xdg-terminal-exec`), after the same sheet when downloaded. Windows and Java programs are explained and
  never run by opening; their own application (Wine, Bottles, java) runs them after "Open with …" in the sheet. A `.dmg` or
  `.pkg` is explained, with Search the Store.
- Unchanged: app launchers (`.desktop`) are refused (a launcher outside an applications folder run after a sheet is a
  follow-up), desktop entries never reach KIO, web links go to the default browser only, KIO never runs an executable
  (`setRunExecutables(false)`), nothing runs from a remote KIO location or the Trash, and Files never runs anything with
  other rights (setuid, setgid, file capabilities; Files as root starts nothing on any path: program, Terminal, Java,
  Wine/Bottles).
- Security rules held by tests: no name trick (program content shown as a document is refused), a symbolic link follows its
  target's trust, the file must be the one the user decided on after the sheet (path, inode, time, size), one journal line
  per decision without file contents. Spec: `docs/specs/security.md` "Files opens apps the Gatekeeper way" and
  `docs/specs/files.md` F7. Tests: `tests/unit/files/tst_launchguard.cpp`, `tst_programlaunch.cpp`, `tst_fileslaunch.cpp`,
  `tests/unit/tst_fileskiosheets.qml`, nested `tests/apps/files_dt10.sh`.
- Limits (said in the spec): the download mark is only as present as the browsers and Files make it; files fetched by other
  tools, extracted by other archive tools or copied from FAT volumes carry none.
