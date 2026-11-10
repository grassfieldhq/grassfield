# ADR-0056: the shell's QML is loaded by file: URLs, so that Qt's disk cache serves it
Status: Accepted (owner decision of 2026-11-10; applied since #37) · Date: 2026-11-09 · Decider: owner · Number: 0056 · Related: R7-REL-01 (gate R1), R7-PRF-05,
ADR-0021 (layers), ADR-0041 (security process), GF-115 (the shell loads from the system tree only)

## Context

Gate R1 (a shell restart to "started" in 3 s) fails: 33 real restarts on rc1 took 8.8 to 9.5 s; the QML load is the bulk
(`docs/audits/rc7-2026-11-08/09-reliability-audit.md` R7-REL-01).

Measured (2026-11-09, `QT_LOGGING_RULES=qt.qml.diskcache.debug=true`, offscreen proxy of the whole shell tree with the layer-shell
windows replaced by a stand-in, CPU time of the qs process from launch to the `grassfield-shell: started` line; warm = second and
later start with the same cache folder):

- Quickshell loads a config by `qs:@/qs/...` URLs. Qt's disk cache refuses them: every `.qml` and `.js` file logs "No
  pre-compiled unit found", "Error loading ... from disk cache: File has to be a local file" and "Error saving cached version ...
  File has to be a local file". Every file the shell uses is compiled from source at every start.
- The same tree reached by `file:` URLs is cached: 8.29, 8.35, 8.37 s of CPU (`qs:`) against 4.29, 4.37, 4.40 s (`file:`), then
  7.88, 7.97, 8.07 against 4.19, 4.25, 4.29 s in a second series: about -48 %. A cold cache (the first start after an install or an
  upgrade) costs the same as today (8.7 to 9.2 s). Memory is unchanged.

## Options

1. Leave it. R1 fails by a factor of three; nothing else is that large (the biggest surface is under 10 % of the start).
2. `//@ pragma OmarchyLoadPatch`: Omarchy's compatibility patch for Qt 6.11/6.12 (rewrites unversioned `import QtQuick`, scans every
   file); it routes more files through `qs:@`, is Omarchy-only. Rejected.
3. `qmlcachegen` / a compiled QML module in a Qt resource: Quickshell loads a path; a compiled module is a build artifact per Qt
   version, outside the dev loop, a second source of truth for the shell. Rejected.
4. A patch to Quickshell (make `qs:` URLs cacheable): not ours, couples the shell to a build of Quickshell. Rejected for 1.0,
   worth an upstream report.
5. **Load the tree by `file:` URLs** (chosen): every `import qs.<module>` becomes the relative import of that module's directory,
   and each root file becomes a stub that loads the former root by `file:` URL.

## Decision

D-1 `scripts/dev/migrate-qs-imports.py` makes the transformation. It is deterministic and idempotent. The source tree keeps the
`import qs.<module>` form (the layering and security checkers, ADR-0021, read it unchanged, and the open pull requests do not
conflict); the packaged tree is the migrated copy (`packaging/arch/PKGBUILD` runs `--in-place` on the copy it installs).
`just check-quick` runs `--dry-run` (check-migrate): the whole tree must migrate, twice with the same result, so a new file whose
import cannot be migrated fails CI. The QML test layers keep testing the source modules (the files differ only by their import
lines). `scripts/dev/shell-run.sh --migrated` runs the UI from `.dev/migrated/shell`: a link to `.dev/migrated-<stamp>`, the stamp being a hash of the sources and of the script (`scripts/dev/migrated-tree.sh`).
A changed content is built into a fresh directory and the link is swapped by one rename. A tree that has a stamp is never deleted
or rewritten while it is current or the one before it, and a run on the current content changes and prunes nothing. The processes
are STARTED AND ADDRESSED BY THE REAL PATH (`readlink -f .dev/migrated`, in `shell-run.sh`, `nested-up.sh` and the nested security
tests), never through the link: Quickshell keeps the literal path (shellDir, the Path ID, every relative load), so a process
started through the link would load a file it opens late from whatever tree the link points to by then, while one started on tree
A's real path keeps loading from A after a swap to B (tests/shell/migrated_tree.sh runs both). The stamp is computed from a
snapshot of the sources that the tree is then built from, runs are serialised by `flock`, a reused tree is verified again, and a
source with a symlink is refused. The stamp is in `security_sig`, so a changed tree restarts the security process on purpose,
a process that outlives two swaps having lost its tree; it is not
the default yet, because the dev key bindings and the nested security tests address instances by path (`qs ipc -p <repo>/shell`,
`-p <repo>/shell/security.qml`: Quickshell identifies an instance by its config path), so the default flips together with
`config/hypr/grassfield/bindings.lua` and those tests, in a change the compositor and security owners review.

D-2 Singletons stay single. A directory import uses the directory's `qmldir`, whose `singleton` entries are the same files; every
document of the process is then reached by exactly one `file:` URL, and nothing in the process is loaded through `qs:` (the
stub roots hold no `qs.*` import). A tree where one file was reached by both forms would hold two instances of its singletons:
the script refuses an import of `qs` it cannot rewrite and leaves none behind (`--check`), and `tests/shell/migrate_qs_imports.sh`
asserts it for every import.

D-3 The stub root keeps the safety the former root had: `settings.watchFiles: false` (R12), the root's `//@ pragma` lines, the same
file name (the unit's `-p` path is unchanged). A core that did not load must END AS A FAILURE, never with status 0 (the unit's
`Restart=` and `OnFailure=`, the failure counter and safe mode, ADR-0041 step 1a, act on failures only). Quickshell has no exit
with a code from QML (`Qt.quit()` is status 0, `Qt.exit(n)` has no receiver: the qmltypes of Quickshell 0.3.2 name no other), so
after 10 s the stub runs `kill -ABRT <Quickshell.processId>` through a `Process` (`["kill", "-ABRT", String(Quickshell.processId)]`, no shell): the process dies by a signal, a failed unit (`Result: signal`),
with no report run (`QS_DISABLE_CRASH_HANDLER=1`) and no core file (`LimitCORE=0`), the journal records the crash.
`tests/shell/migrate_qs_imports.sh` shows status 134 on a tree with a missing core, and, where a user manager exists, the
failed unit state (`systemd-run --user --wait`).

D-4 The load path is `Quickshell.shellDir` (the system tree, GF-115): no environment variable, no import path.

D-5 UI process only for now. The migration covers `shell.qml`; `security.qml` and the security process stay as they are (loaded by
`qs:`, no stub) until an opus security review of this approach. The modules the security process imports (transitively:
`lib`, `services`, `platform`, `store`, `security`, `security.host`, `security.idle`, `security.lock`) are shared files: in the
packaged copy their imports are relative, which a document loaded through `qs:` resolves through `qs:` as well, so the security
process loads the same files by the same scheme as today and holds its own singletons (checked: `qs -p security.qml` on the
migrated tree logs `grassfield-security: ready (hosting lock idle ...)`). The source of `shell/security/**` is not changed.

D-6 Two invisible surfaces are built right after "started" (`LazyLoader { activeAsync: true }` in `shell.qml`): the capture toolbar
and the exit cover. Nothing asks for them at login; a capture key pressed in the first tick does nothing, the exit cover's IPC
target exists a tick after the first frame. The saver stays (its state is pinned by `tests/security/lock_surfaces.sh`), and Search,
Apps, Overview and the Switcher stay (P4, A10).
**[Amended 2026-11-10: Search, Apps, Overview, the OSD window and the switcher's window are now built right after "started" too; see the amendment at the end.]**

D-7 `grassfield-shell.service` restarts after 100 ms (`RestartSec=100ms`). The loop bounds hold: the start limit (10 in 300 s) is
reached by any loop the lifetime model knows (10 x (0.1 + 10) s = 101 s < 300 s, `tests/shell/unit_restart_limits.sh`), and the
failure counter (`grassfield-shell-failed`, third failure within 10 minutes, ADR-0041 step 1a) counts failures, not time, so it
stops a loop of any pace, a faster one sooner. `grassfield-security.service` is unchanged.

D-8 The shipped tree is the source apart from its import lines, and a check says so. `migrate-qs-imports.py --verify SRC TREE` compares
every file line by line (an `.qml` file may differ only in the `import qs.*` lines of its header; `shell-core.qml` is `shell.qml`
without the watchFiles line, ShellRoot as Scope; the stub is the generated one; nothing else is new; every other file is byte for
byte equal). `just check-quick` runs it on a migrated copy (`check-migrate`, which also runs qmllint on that copy), the PKGBUILD
runs it on the package, and `tests/shell/migrate_qs_imports.sh` plants mutants in the migrated tree (a lock check dropped from
the capture toolbar in the package only, an extra file, a changed stub, an added line) that it must catch. Only the import header
is read and rewritten: a template string or a block comment below it that contains `import qs.x` is left alone. The script is
pinned by its SHA-256 in `tests/security/security_unit.sh` like `SecurityHost.qml`: a change of it needs the security review,
because the UI process hosts the polkit agent and the secret sheets until S3 moves them and runs what it produces. The same
file pins the CI step (`scripts/dev/check-migrate.sh`) and the two PKGBUILD lines that migrate and verify the package. The
verification also holds independently of the header parser: no `.qml` file of the package but a kept root has a line that
imports `qs` (so a file reverted to the source, or one the parser stopped short of, fails), a kept root (`security.qml`) must be
byte-equal to its source (D-5), and the package holds no symlink.

D-9 What runs. The UI process, which until S3 hosts the polkit agent and the secret sheets, now runs compiled code read back
from `~/.cache/quickshell/qmlcache` (Qt's disk cache, validated by the Qt version and by a checksum of the source's content, which
Qt 6.12 compares even when the modification time and size are the same) instead of compiling the package's source at every start. That is acceptable because the cache is written and read by
the same user's process, in a directory only that user can write: a process that can alter it can already alter the user's
session (it can start the shell with its own tree, replace a user unit, preload code); the cache adds no privilege boundary that
the migration crosses. The package itself is the reviewed artefact (D-8), and the unit already clears `QML_DISK_CACHE_PATH`
(UnsetEnvironment=), so the folder is Quickshell's own, not an inherited one. The security process is not migrated (D-5) and
compiles its source at every start as before.

D-10 A known limit of the failure counter, for S4. `grassfield-shell-failed.service` does not count a failure that arrives while its own
job is still running (systemd merges a start request for a unit that is already starting or running): with RestartSec=100ms, a loop
of sub-second crashes can reach the start limit (10 starts in 300 s) and end in "failed" without the third counted failure having
been written, so `shell-safe-mode` may not exist when the unit has stopped for good. Safe mode (S4) therefore must not rely on the
state file alone: it must also read the unit's own state (`systemctl --user show -p ActiveState,Result,NRestarts
grassfield-shell.service`: failed with Result=start-limit-hit is a safe-mode condition too).

## Rule for new files
Write `import qs.<module>` exactly as before and nothing else about loading: no `qs:` URL in a string, no second import form in
the same tree, no new root file without a line in the script's roots (every `.qml` at the top of `shell/` is a root).
`Qt.resolvedUrl()` is fine (it follows the document's own URL).

## Consequences
- First start after an install or upgrade is as slow as today (cold cache); later starts save about half the CPU. A warm-up at
  package install is possible and not part of this ADR.
- Not proven for R1 until measured: the proxy start is 8.0 s CPU before and 3.5 s after the cache, the two surfaces and a restart
  delay of 100 ms (see the report for the nested commands).
- Open until measured in a nested session: that windows created under a `LazyLoader` behave as under the root (the proxy has no
  Wayland); that the cache folder is the one Quickshell sets under the unit's `UnsetEnvironment=QML_DISK_CACHE_PATH`.

## Amendment 2026-11-10 (integrator, delegated decision; owner informed)

Changes D-6 only (the sentence "Search, Apps, Overview and the Switcher stay (P4, A10)" no longer holds for Search, Apps and Overview; the
Switcher itself, whose IPC target and key handling stay, and the Saver stay as D-6 says). Nothing else of this ADR changes.

What changed. `Search`, `Overview`, `AppsController` (Apps), `OsdWindow` and `SwitcherWindow` are built by `LazyLoader { activeAsync: true }`
right after "started", not before it. Measured by marking each root child of `shell.qml` (nested, load 3 to 5, warm cache, `MARK` objects
dropped afterwards): the finalisation of their windows and content was Apps 280 ms, SwitcherWindow 140, Search 103, Overview 71, OsdWindow 47 (about
0.65 s of a 2.66 s start). The cache itself already saves about 2.6 s (no-cache median 5.4 s against 2.8 s); the C++ plugins cost under 0.1 s
together; surfaces deferred by `LazyLoader { active: false }` alone or by URL (`source`) gave nothing measurable, the saving is in not
instantiating their windows before the first frame. "started" means what it did (the root's `Component.onCompleted`).

No request is lost. A request that reaches the shell before a surface is built is remembered and performed when it exists:
- `early` in `shell.qml` keeps one pending request per surface, the last winning (a toggle flips the wanted state, open and close set
  it: open then close ends closed; a Clipboard-view request is kept as such; a Search open keeps its text) and drops it if it is older than
  `Tokens.deferredRequestMaxAgeMs` (5 s). The surface's own checks apply when it is performed (a locked session refuses, as for any request).
- The IPC targets `search`, `apps` and `overview` answer from the start: until a surface is built, a forwarding `IpcHandler` in
  `shell.qml` (same names and dev gates for the test hooks) takes the request; the surface's own handler is switched on right after the
  forwarding one is off (`ipcEnabled`, in `Search.qml`, `Overview.qml`, `AppsController.qml`), so a target never has two handlers (Quickshell
  warns and uses one). Key bindings, hot corners and gestures reach the shell by these targets.
- The menu bar's search button and the Dock's apps button ask `early` while the surface is null.
- The OSD window shows the last OSD event received before it was built (`Osd.replay`, bounded by the same age).
- The app switcher's window is a view of the controller's state (`switcher.active`): built late, it shows what is active.
- In practice a request made in the first seconds waits in the IPC socket until the main thread is free, which is after the surfaces are
  built (the nested measurement: a first `apps open` was answered 2.2 s after "started", after "surface built apps"); `early` covers the
  requests that are served between two incubation steps and every non-IPC caller.
- Test: `tests/shell/deferred_early.sh` (nested layer) restarts the nested shell with `GRASSFIELD_DEFER_HOLD=1` (dev session only, ADR-0019
  table; holds the loaders until `qs ipc call deferred release`), sends requests while the surfaces do not exist, releases and reads the
  surfaces back: Search open with its text, Apps open, two early toggles ending closed, open then close ending closed; and that the log
  has no handler conflict. With `early.deliver` neutered the first case fails (checked).

Gain, same nested commands as the original measurement (launch = the "Launching config" log line; strict alternation, one sample per
switch of the file set, 9 each, 1-minute load 7.0 to 9.4, other lanes running, so above the load of 6 asked for; the order of the pairs is
the order of the table):

| sample | origin/main (s) | load | this change (s) | load |
|---|---|---|---|---|
| 1 | 3.56 | 7.14 | 2.59 | 7.44 |
| 2 | 3.32 | 8.10 | 2.49 | 7.85 |
| 3 | 3.03 | 7.71 | 2.80 | 7.33 |
| 4 | 4.31 | 7.04 | 2.83 | 8.36 |
| 5 | 3.90 | 8.02 | 3.37 | 7.99 |
| 6 | 2.93 | 8.97 | 3.08 | 9.30 |
| 7 | 3.90 | 9.06 | 2.93 | 9.06 |
| 8 | 4.08 | 8.98 | 3.28 | 9.43 |
| 9 | 4.07 | 9.28 | 3.14 | 9.37 |
| median | 3.90 | | 2.93 | |

(Earlier runs at load 4.2 to 7.2: 2.84 s against 2.31 s median, 9 each.) From the process start the median is 3.41 s here
(origin/main 4.36 s); process start to the "Launching config" line is about 0.45 s.

Follow-up, not done here: `AppsController.rebuildApps` (the Launchpad's list, 75 apps) runs as one 321 ms step on the main thread about
4 s after "started", when the apps list becomes ready (a stutter after the start, not part of R1). It wants to be incremental or built
on first use; the surfaces' windows could also be built one per frame.

Consequences. A request in the first second after "started" still takes effect (delayed until the surface exists); a request older than
5 s when the surface appears is dropped. Open until measured on the real session: the first-frame behaviour of windows built after the
first frame (the nested proxy has no real display), and the "usable" time (the nested entrance waits for icons, so it does not discriminate).
