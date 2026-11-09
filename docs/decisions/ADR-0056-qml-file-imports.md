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
conflict); the packaged tree is the migrated copy (`--out`, run by the package build: not done by this ADR, it is in
`packaging/`). The development launcher (`scripts/dev/shell-run.sh`) and the QML tests keep loading the source tree through
`qs:`: the dev loop does not get the cache until it also runs the migrated copy.

D-2 Singletons stay single. A directory import uses the directory's `qmldir`, whose `singleton` entries are the same files; every
document of the process is then reached by exactly one `file:` URL, and nothing in the process is loaded through `qs:` (the
stub roots hold no `qs.*` import). A tree where one file was reached by both forms would hold two instances of its singletons:
the script refuses an import of `qs` it cannot rewrite and leaves none behind (`--check`), and `tests/shell/migrate_qs_imports.sh`
asserts it for every import. The UI process and the security process each have their own root and their own stub
(`shell.qml`, `security.qml`); they share no instance (they are two processes).

D-3 The stub root keeps the safety the former root had: `settings.watchFiles: false` (R12), the root's `//@ pragma` lines, the same
file name (the units' `-p` paths are unchanged). A core that did not load ends the process after 10 s with an error line
(Quickshell has no non-zero exit from QML); the security owner reviews that behaviour for `security.qml` before it ships.

D-4 The load path is `Quickshell.shellDir` (the system tree, GF-115): no environment variable, no import path.

## Rule for new files
Write `import qs.<module>` exactly as before and nothing else about loading: no `qs:` URL in a string, no second import form in
the same tree, no new root file without a line in the script's roots (every `.qml` at the top of `shell/` is a root).
`Qt.resolvedUrl()` is fine (it follows the document's own URL).

## Consequences
- First start after an install or upgrade is as slow as today (cold cache); later starts save about half the CPU. A warm-up at
  package install is possible and not part of this ADR.
- Not enough alone for R1: `RestartSec=1` and the remaining start still exceed 3 s (see the report).
- Open until measured in a nested session: that windows created under a `LazyLoader` behave as under the root (the proxy has no
  Wayland); that the cache folder is the one Quickshell sets under the unit's `UnsetEnvironment=QML_DISK_CACHE_PATH`.
