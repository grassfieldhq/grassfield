# ADR-0026: Files window frames: the size by Files, the position and the cascade by the compositor
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (integrator, under owner delegation D-5); part 1 is applied with Files PR 1, part 2 waits for its nested
verification · Date: 2026-10-26 · Decider: integrator

## Context
- Owner goal (2026-10-26, Finder parity, `docs/specs/files.md` FP-1, FP-9, FP-13): "the window remembers its size and its
  position"; a tab dragged out of a window becomes a window; new Finder windows cascade.
- Every browser window opens at `Tokens.filesWindowWidth` x `filesWindowHeight` (`apps/files/qml/BrowserWindow.qml`).
- A Wayland client cannot place its own toplevel: xdg-shell has no position request. Hyprland centres a new floating
  window and `config/hypr/grassfield/placement.lua` fits it under the menu bar; a second Files window opens exactly over
  the first one (Known limitations).
- Grassfield apps already tag their windows for the compositor (ADR-0015: `xdg-toplevel-tag`, role `browser` for the
  Files browser window, `apps/windowchrome.h`), and the compositor already sees every window's frame.
- The plugin is optional at runtime (D3): nothing here may depend on it.

## Options
1. **Size in Files, position in the compositor's placement rules** (`placement.lua`), keyed by the app id and the toplevel
   tag. Files needs no protocol; every Grassfield app with a tag gets the same behaviour.
2. The plugin records and restores frames. Works only with the plugin; the rules already live in `placement.lua`.
3. A session-management protocol (`xdg-session-management`). Not available in Hyprland 0.56.2 (ASSUMPTION: not in its
   protocol list; check in nested), and Files would still need a compositor that honours it.
4. Keep everything as today (centre, fixed size). Rejected: not the Finder.

## Decision (proposed)
Option 1.
1. **Size (Files).** The size of the last browser window that was resized or closed is kept in Files' QSettings
   (`window/width`, `window/height`, clamped to the window minimum). A new window (New Window, a dragged-out tab, Move
   Tab to New Window) opens at that size. Get Info and Customize Folder windows keep their own sizes.
2. **Position and cascade (compositor, `placement.lua`).** For a floating window whose app id and toplevel tag are both set:
   - the first window of that (app id, tag) opens at the frame the last one of them had when it closed in this Hyprland
     session, fitted to the screen it lands on (the `fit` rule);
   - a further window while one of the same pair is mapped opens offset down and to the right from the front one by the
     cascade step (a placement constant measured on the Finder in nested; macOS cascades new Finder windows), wrapping to
     the top-left of the free area when it would leave it;
   - a dragged-out tab opens under the pointer when the compositor knows the pointer position at map time.
   Persistence across logins is added only if Hyprland's Lua can keep a state file (verified in nested first); otherwise
   the memory lasts for the Hyprland session and the spec says so.
3. Files sends nothing about positions, and no protocol is added.

## macOS reference
The Finder reopens a window at its last frame and cascades new windows down and to the right of the front one; a tab
dragged out becomes a window where it is dropped.

## Consequences
- Part 1 ships with Files PR 1 (size, a unit test of the clamp, QSettings keys in `docs/specs/files.md` Interfaces). The
  clamp: `FileLogic::keptWindowSide` / `keepsWindowSize` (200..16384, `tests/unit/files/tst_filelogic.cpp` `WindowSize.*`)
  and the window minimum in `Main.qml` `newWindow` (`tests/unit/tst_filestabs.qml` `test_newWindowSizeIsClampedToTheMinimum`).
- Part 2 needs the nested session (`placement.lua` tests in `tests/shell/` or `tests/compositor/`, `just check-config`);
  until it lands, FP-13 stays "partial" and the limitation "a new window opens over the previous one" stays listed.
- Without the plugin nothing changes: the rules are Hyprland Lua.
