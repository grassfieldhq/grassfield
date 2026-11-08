# ADR-0022: The desktop's file operations are Files operations
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (integrator, under owner delegation D-5); accepted when its first slice merges (D5-1); marked Accepted
by D5-4 · Date: 2026-10-24 · Decider: integrator

## Context
Plan: docs/audits/final-1.0/refactor-plan.md §7 (GF-090 D5), §12 item 6. Lines re-checked on main 370a45f.
- The desktop runs `gio trash` / `move` / `mkdir`, `cp -a` and `wl-copy` itself (`shell/desktop/DesktopFiles.qml:105,119,142,
  173,199,257`; line 105 is `run(["gio", "trash", "--"]...`).
- Files does the same work with KIO jobs, `FileUndoManager` and KIO's conflict delegate
  (`apps/files/src/filesapp.cpp:54-58,109,533-722`; the delegate is attached in `attachDelegate`, automatic error dialogs
  are off and the app reports errors itself).
- Precedent for delegating: the desktop's Get Info runs `grassfield-files --info` (`apps/files/src/main.cpp:36-43`).
- Two implementations mean two conflict behaviours, two error paths and no shared progress.

## Decision
- The shell delegates trash, move, copy, duplicate, new folder and rename of desktop items to one-shot
  `grassfield-files` operations. The shell never moves or copies files itself. It keeps only read paths (FolderListModel,
  `getfattr` looks) and the clipboard.
- One-shot means one process per operation; no D-Bus service and no resident process. Output is an exit code plus one JSON
  line. In dev the operations are refused outside the sandbox (`runmode::dev`, ADR-0019), and the shell reaches the binary
  through `GRASSFIELD_FILES_CMD` via `Mode.devValue`.
- Conflict UI (integrator decision, plan §12 item 6): Finder's sheet ("An item named X already exists in this location",
  Keep Both / Stop / Replace, Apply to All), drawn by Files in its own style. KIO stays the engine (its
  `AskUserActionInterface`); KIO's widget dialog is never shown to the user. A non-interactive flag turns a conflict into
  an error exit (tests, scripts).
- Desktop Undo stays unavailable (not a regression). It would need a resident Files and a future ADR.
- `FileOperations` is extracted from `FilesApp` first, with no behaviour change (this is also GF-088's FilesApp split).

## macOS reference
Finder owns the desktop's items: trashing, renaming, copying and moving on the desktop are Finder operations, with
Finder's conflict sheet and progress.

## Alternatives rejected
- Keep `gio`/`cp` in the shell: duplicate semantics, different conflict handling, no progress.
- A resident Files daemon with D-Bus: a new service; only needed for desktop Undo, deferred.
- KIO's stock conflict dialog: not Finder's sheet (the owner-delegated decision requires the Finder model).
- A shared C++ library linked into the shell: Quickshell has no such path for 1.0.

## Consequences
- Tests: new `tests/apps/files_ops.sh` (non-interactive flag makes a conflict an error exit) and `tst_fileoperations.cpp`;
  existing Files gtests, `files_sandbox.sh`, `files_dt10.sh`, `desktop_menu_actions.sh`, `desktop_new_folder.sh`,
  `desktop_rename_focus`; nested `desktop-menus.sh` (ask the owner).
- After D5-4 no `gio`, `cp` or `sh -c` path remains in `DesktopFiles.qml`; that slice adds a grep guard.
- Slices (plan §7): D5-1 (extract FileOperations; needs M6 and C5), D5-2 (one-shot CLI), D5-3 (the desktop uses it; needs
  D5-2, L4 and L8), D5-4 (remove the old paths, mark this ADR Accepted). Waves 6 and 7.
