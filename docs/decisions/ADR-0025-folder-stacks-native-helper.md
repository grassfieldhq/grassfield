# ADR-0025: Folder stacks are indexed by a native helper
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (integrator decision D-5 of counter-review 7, under owner delegation); accepted when it merges after its
counter-review · Date: 2026-10-25 · Decider: integrator

## Context
Requirement 27 of `docs/specs/dock.md` (folder stacks, REQ-DOCK-PAR-d7) needs, per stack folder, the first 30 entries in the
stack's order for the pile (3 shown) and the first 300 for the open popup, kept up to date while the folder changes, on folders of
up to 100,000 names, and with Name in exactly Files' order.

Six rounds built this from `find`, `sort`, `stat`, `inotifywait`, one gawk process, a bash supervisor and JavaScript (ICU reaches
QML only as `localeCompare`, so each name had a hand-made sort key and a list of "known differences" from Files). Counter-review
7 of 401b05f measured what that pipeline cannot do:
- No CPU bound for repeated urgent listings: 300 files dropped every 5.5 s into 60,000 names were a storm each time, Name
  34 to 38 ticks a second (target 3).
- A file that vanishes between `find` and `stat` gave fewer than 30 records and a "complete" window: an empty pile.
- The refill after the shown files were deleted was not urgent: 4.2 s at 5,000 names in Name order, 6.5 to 50.9 s at 100,000.
- The Kind burst failed the cost gate in all six runs; burst latency at 5,000 names was 3.0 to 5.4 s in Name order and 4.9 s in
  Kind (target 2.5 s).
- Endless-stream refreshes in Name order were 27 to 44 s apart (target 15 s); the gap metric skipped the tail.
- The memory baseline was taken after the first Kind listing; against a warm baseline the pile kept 50 MB and the popup 74 MB
  (gate 20).
- The popup (300 entries) on 100,000 names was blank for 25 to 48 s, with GUI waits of 58 to 100 ms (limit 50).
Each fix moved the problem: the order lives in ICU (a C++ library), the listing in `find`, the watch in awk, the glue in
bash and QML, and every boundary costs a process, a copy or a key.

## Decision
ONE native C++/Qt Core process per stack folder, `grassfield-stack-helper` (`apps/stack-helper/`, precedent
`apps/wallpaper-tool`), installed with the other helpers to `/usr/lib/grassfield/`. Arguments: folder, order, K and optionally `low` (the margin: see below). It:
- lists the folder itself: `readdir` then `statx` per entry (dates only for the date orders; `ENOENT` skips the entry and does
  not end the scan), no hidden names, links not followed, the birth time from `statx`; a vanished entry of the window makes the
  scan run again, so a window is never made of files that are gone;
- keeps only the window of the first K entries (30 for the pile, 300 while the popup is open, changed by `K <n>` on stdin) in a
  sorted vector, one comparison for an entry that sorts after it;
- sorts with Files' code: `apps/files/src/filelogic.cpp` `compareEntries`, compiled in as it is, with the `QCollator` that
  `FolderModel` sets up (user locale, numeric, case insensitive, ties by the raw names). Name order is Files' by construction:
  the JS name key, the awk keys and the known-differences list are removed;
- watches with inotify directly (no inotifywait, no gawk): a created or renamed-in name that sorts into the window is inserted
  with one comparison; a removal inside the window, or a change that could push an entry out of it, asks for a re-list in the
  helper, at most one a second, coalesced and paid in CPU time, only when fewer than `low` entries are left (the margin: a
  removal shortens the window, a boundary entry keeps it a correct prefix: round 9, a scan per download cost 7 ticks/s);
  `IN_Q_OVERFLOW` or more than 4,000 changed names in a batch is one re-list; no decision rests on a count of the folder (round
  8: a count that drifted left an empty pile); in the date orders the sub-folders are watched too (a folder's date is its own; a renamed sub-folder keeps its one
  watch, re-filed under its new name whichever name a batch deals with first), and `IN_MODIFY` is coalesced to one look per
  500 ms per folder (a download written in place costs about one window per 500 ms, not ten a second); with more than 1,000
  sub-folders only the first 1,000 (in the order the directory is read) are watched and the folder is scanned again every 60 s,
  so the pile converges (up to a minute late for a change in a sub-folder that is not watched); the
  folder deleted, moved or unmounted is reported (`G`) and re-armed after 2 s growing to 15 s (`A`);
- writes the window on stdout only when it changed and is not stale, at most ten times a second; one line, fields separated by
  US, names escaped (backslash, line break, return, US), so no file name can forge a line;
- dies with the shell (`PR_SET_PDEATHSIG`, and with its stdin) at nice 10.
`StackWatch.qml` is thin: it starts one helper per folder (`StackHelper.qml`), tells it the order and K, and parses one line per
update (`Stacks.windowParser`, in slices of 6 ms: at most 300 records, never a long call).

## macOS reference
Finder keeps one index of the folder for every view (the stack, the window, the Open dialog) and updates it from file-system
events; a stack shows a handful of items taken from it, never a sorted copy of the folder in a UI process.

## Alternatives rejected
- Keep the bash/awk/JS pipeline and tune it (rounds 1 to 6): seven rounds ended with the numbers above; each rule against one
  storm (heuristics, duty cycles, urgent and soft listings) added a case the next round found.
- Run the same pipeline faster with a persistent bash or awk process: the order still lives in ICU, only C++ reaches it
  without a key.
- QML `FolderListModel`: rescans the whole folder on every change (measured in the first review) and has no bounded window.
- Do the indexing in the shell process (a C++ QML plugin): a second language in the shell's address space for untrusted
  folders, a crash or a stall takes the shell down; a separate process is killable and niced.
- Use KIO or Tracker/localsearch: new dependencies, no window selection, no birth time.

## Consequences
- One new binary in `grassfield-desktop`; no new dependency beyond Qt Core (already required). `gawk` leaves the package's
  `depends`. `inotify-tools` is not in its `depends` either (the PKGBUILD comment says why: only
  `shell/launchpad/watch-applications.sh` uses it and it falls back without it).
- Removed: `shell/dock/{list-folder.sh,entry-info.sh,watch-folder.sh,watch-batch.awk,ListingJob.qml}`, the reducer, key and
  comparator code of `Stacks.js`, their tests (`list_folder.sh`, `watch_folder.sh`, the JS parts of `tst_dockstacks.qml`).
- New tests: `tests/unit/stack-helper/tst_stacklogic.cpp` (gtest, ASan build too), `tests/shell/stack_helper.sh` (the process),
  `tests/shell/dock_name_order.sh` (the helper against Files in six locales), `tests/shell/stack_watch_cost.sh` (the measuring
  stick, now counting the helper) with the round-7 cases.
- Dev runs need `apps/stack-helper/build-direct.sh` (like the other helpers); `GRASSFIELD_STACK_HELPER` names another binary for tests.
- A raw name that is not UTF-8 is shown with U+FFFD (as Files shows it) and cannot be opened from the stack by path: unchanged
  from before.
