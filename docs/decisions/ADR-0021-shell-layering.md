# ADR-0021: Shell layering (`qs.lib` < platform < store < services < features < shell.qml)
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (integrator, under owner delegation D-5); accepted when its first slice merges (L1) · Date: 2026-10-24 ·
Decider: integrator

## Context
Plan: docs/audits/final-1.0/refactor-plan.md §3 (GF-087), §6 (GF-088 conventions). Lines re-checked on main 370a45f.
A Tarjan scan of `import qs.*` and relative imports finds one strongly connected component of 10 modules: desktop, dock,
launchpad, notifications, osd, overlay.controlcenter, platform, search, services, widgets. Causing edges:
- services to dock: `shell/services/Apps.qml:8`, `RecentItems.qml:7` (DockModel), `Settings.qml:7` (Geometry);
- services to launchpad (`Apps.qml:6`), to search (`RecentItems.qml:6`), to overlay.controlcenter
  (`BluetoothState.qml:6`, `Connectivity.qml:8`);
- platform to services (`Capabilities.qml:8`, `Compositor.qml:9`, `FocusReturn.qml:5`, `MenuBridge.qml:7`);
- desktop and dock (`DesktopFiles.qml:10`, `Dock.qml:13`), search and launchpad (`Search.qml:14`,
  `AppsController.qml:8`), controlcenter to widgets (`NowPlaying.qml:5`).

Other problems: raw Hyprland events outside platform (`shell/overview/Overview.qml:280`,
`shell/desktop/DesktopWidgets.qml:140`); a security module imports a UI module (`shell/security/lock/LockView.qml:6`
imports `qs.desktop` only for `WallpaperArt`, a 16-line wrapper of `GrassfieldArtwork`); IO in `ui/`
(`ui/Grassfield/Ui/FolderStyle.js:72-141`, used only by `DesktopFiles.qml`). With those edges cut the graph is acyclic
(simulated: `platform` imports nothing, `services` imports platform and store only).

God objects (GF-088): `Dock.qml` 2,226 lines, `Compositor.qml` 928 lines, `Notifications.qml` 1,216 lines, FilesApp 1,481
lines.

## Decision
- Layers, low to high: `qs.lib` < `qs.platform` < `qs.store` < `qs.services` < features < `shell.qml`. A module may import
  only a lower layer. `qs.lib` holds pure helpers and `Mode` (ADR-0019) and imports no `qs.*`. `qs.platform` imports lib
  only. Features may import any lower layer; feature-to-feature imports are allowed only while the graph stays acyclic.
  `shell.qml` is the composition root and binds services into platform inputs (existing pattern, `shell/shell.qml:140-152`).
- Raw Hyprland events (`Quickshell.Hyprland`, `rawEvent`) go through platform only. Exception: the security lock and idle
  modules (`Lock.qml:195-578`, `Idle.qml:42`) use it directly so the lock never depends on platform. Security modules may
  import only lib, services and security; `SleepInhibitor.qml:5` (imports `qs.notifications`) stays a marked exception tied
  to GF-050.
- `Grassfield.Ui` keeps the design system plus the contract helpers shared with the apps (`SettingsContract`,
  `WallpaperConfig`, `NotificationPrefs`, `PointerSize`/`PointerColors`, `JsonSafety`, `Persisted`). Shell-only IO and
  format parsing live in `qs.lib`. No `Grassfield.Core` module for 1.0.
- Low-churn technique: a function moves to `lib/`; the old file keeps a one-line forwarder that imports lib (a downward
  edge), so Dock callers and their tests do not change.
- Enforcement: `tests/ci/import_graph.py` (run in `check-shell`) checks the layer rules, the SCC check and the raw-event
  rule. Exceptions exist only as inline markers on the import line: `// layering-exception: GF-087` (temporary; each slice
  removes its own, so there is no shared allowlist) and `// layering-exception: ADR-0021 security` (permanent). L9 makes any
  GF-087 marker fail.
- GF-088 conventions: split by responsibility into files of the same module with typed `required property` links and
  `ComponentBehavior: Bound`; logic stays in pure JS files. The `Compositor` singleton stays a facade with the same API
  (its 17 callers do not change); internals move to instantiated platform components. No UX change. A split that moves
  regions pinned by `tests/security/lock_surfaces.sh` updates its paths and gets a security review.

## macOS reference
Layered frameworks: lower layers (Foundation, platform services) never import application-level UI; apps are composed at
the top and reach the system through one service layer instead of reading raw system events everywhere.

## Alternatives rejected
- A `Grassfield.Core` module: a new module and build entry for what `qs.lib` does inside the shell.
- A shared allowlist file for exceptions: merge conflicts across parallel lanes; inline markers keep ownership local.
- Moving the lock onto platform events: couples the security surface to a feature layer.
- Leaving the cycle and relying on review: the cycle already blocks isolated unit tests and splits.

## Consequences
- `import_graph.py --selftest` (L1) is the gate; qmllint stays at 0 warnings; `qmldir_types.py`, `ipc_inventory.sh` and
  `lock_surfaces.sh` keep moved functions documented and gated.
- Tests per slice: `tst_ccmodel` (L2); `tst_searchranking`, `tst_appssearch`, `tst_appspanel`, `tst_recentitems`,
  `apps_panel_perf` (L3); `tst_dockmodel`, `tst_desktopicons`, `tst_dockgeometry`, `tst_docklaunch`, new
  `tst_desktopentry.qml` (L4); `tst_focusreturn`, `tst_menubridge`, `tst_minimized` (L5); `tst_overviewv2`,
  `lock_surfaces.sh` (L6); `tests/security/*` (L7); `tst_foldercolors`, `folder_styles_apply.sh` (L8); new
  `tests/shell/dock_offscreen/` for the Dock split.
- Nested runs (overview, minimize, genie, tiling) need the owner's go-ahead.
- Slices (plan §3, §6): L1 to L9 (GF-087; L1 first, L9 removes the ratchet); G-D1 to G-D5, G-C1 to G-C5, optional G-N1..3
  (GF-088). Dependencies: M1 (lib exists), M2 (removes the DevGate edge), M3 and M5b.
