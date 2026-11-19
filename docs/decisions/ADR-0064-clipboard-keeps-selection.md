# ADR-0064: The clipboard helper keeps the clipboard it serves when the shell goes
Status: Proposed (audit round 2, fluidity note "helper loss on shell restart") · Date: 2026-11-19 · Decider: owner (via the audit brief)

## Context
grassfield-clipboard-helper (ADR-0034) is one process per shell, a child of Quickshell with PR_SET_PDEATHSIG, in the shell's
systemd unit (grassfield-shell.service, Restart=always). When the user chose an item from the history, the helper owns the
Wayland clipboard. A shell crash or update killed the helper (PDEATHSIG, and the unit's stop kills its whole cgroup), and the
clipboard became empty: on macOS a crash of the Dock or of Spotlight never empties the pasteboard.

## Decision
1. At start the helper leaves the shell's unit for a transient scope of its own, `grassfield-clipboard-helper-<pid>.scope`
   (StartTransientUnit with `PIDs` = its own pid, `CollectMode=inactive-or-failed`, through `busctl --user`). Without a user
   manager or busctl it stays where it is (logged; nothing else changes).
2. When the shell goes (PDEATHSIG with a new parent, its stdin closed, its stdout closed), a helper that does not serve the
   clipboard exits 0 as before. A helper that serves it keeps serving that one item: it drops the history and the
   thumbnails from memory and the runtime directory, writes an index still owed, records nothing, answers no command,
   writes nothing, and exits when another client takes the clipboard (source cancelled), when the compositor connection
   ends (logout), or after 8 h. A SIGTERM that is not the shell's death (logout, a stop) still ends it at once.
3. The new shell starts a new helper; its first selection (the kept item) is never recorded, as after any start.

## Consequences
The clipboard survives a shell restart; at most one extra process per restart, holding one item, until the next copy. The
helper is no longer accounted in the shell unit's MemoryMax (it keeps its own bounds: caps per item, thumbnails in an
rlimited worker). Tests: tests/shell/clipboard_helper.sh section 10d (stdin closed while serving: still pastes, ends when
another app copies, exit 0; a helper serving nothing ends with its shell). Not verified in a real session: the scope move
under the user manager, and a restart of grassfield-shell.service with an item served.
