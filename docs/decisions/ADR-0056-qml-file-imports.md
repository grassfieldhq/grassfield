# ADR-0056: the shell's QML is loaded by file: URLs, so that Qt's disk cache serves it
Status: Proposed (2026-11-09) · Date: 2026-11-09 · Decider: owner · Number: 0056 · Related: R7-REL-01 (gate R1), R7-PRF-05,
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
lines). `scripts/dev/shell-run.sh --migrated` runs the UI from `.dev/migrated/shell` (rebuilt when `shell/` changes); it is not
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
after 10 s the stub runs `kill -ABRT $PPID` through a `Process`: the process dies by a signal, a failed unit (`Result: signal`),
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

D-7 `grassfield-shell.service` restarts after 100 ms (`RestartSec=100ms`). The loop bounds hold: the start limit (10 in 300 s) is
reached by any loop the lifetime model knows (10 x (0.1 + 10) s = 101 s < 300 s, `tests/shell/unit_restart_limits.sh`), and the
failure counter (`grassfield-shell-failed`, third failure within 10 minutes, ADR-0041 step 1a) counts failures, not time, so it
stops a loop of any pace, a faster one sooner. `grassfield-security.service` is unchanged.

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
