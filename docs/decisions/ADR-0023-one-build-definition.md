# ADR-0023: One build definition (top-level CMake; `build-direct.sh` as wrappers)
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (integrator, under owner delegation D-5); accepted when its first slice merges (D2-1) · Date: 2026-10-24 ·
Decider: integrator

## Context
Plan: docs/audits/final-1.0/refactor-plan.md §7 (GF-090 D2), §12 item 8.
- Seven `build-direct.sh` scripts (372 lines) duplicate the CMake source lists of their projects (for example
  `apps/files/build-direct.sh` and `apps/files/CMakeLists.txt`).
- About 30 scripts and tests call them with options (`--tests`, `--asan`, `--install-paths`, and the compositor's
  `plugin|tests|compdb|tidy`), so their CLI is a stable entry point.
- The PKGBUILD (`packaging/arch/PKGBUILD`) builds each project separately.
- Every C++ slice of the refactor (M6, M7, C5, D5-*, D7) edits source lists; doing D2 earlier would force repeated rework.

## Decision
- CMake is the only build definition. Two new top-level files, no new directory: `CMakeLists.txt` and
  `CMakePresets.json` (presets: dev, asan, release, tests).
- The `build-direct.sh` scripts become thin wrappers with the same CLI and one source list per target.
- The PKGBUILD keeps its per-project builds.
- Timing: done last (W7), after every C++ slice. If it slips past the 1.0 candidate it moves to 1.0.x and the move is
  recorded then (plan §12 item 8). Deferring costs little.

## macOS reference
One project definition (Xcode project and schemes) drives every build configuration; command-line `xcodebuild` is a thin
entry point onto it.

## Alternatives rejected
- Keep seven scripts with duplicated lists: drift between CMake and the scripts.
- Replace the scripts by presets only: breaks about 30 callers.
- A different top-level build system (meson or similar): a new dependency that needs owner approval.
- Do it early: churn on every C++ slice.

## Consequences
- Tests: `just test` (all gtest suites), full `just check` (tidy compdb), `just release-check` (bare), `just coverage`,
  qmllint (i18n), nested-up. Risk is medium-high: every gtest suite and the tidy compdb go through the wrappers.
- The two top-level files are the only structural addition and the reason for this ADR (the project's working rules: no new directory or
  abstraction without need).
- Slices (plan §7): D2-1 (top-level CMake and presets, no script changes), D2-2 (wrappers). Wave 7.
