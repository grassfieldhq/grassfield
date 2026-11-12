# ADR-0041: Stability: every process comes back, the session never unlocks by itself, no update installs an untested combination
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (step 0 of the owner's brief « Stabilité », 2026-10-29; documents only, no code). Six owner questions are
open (SQ-1 to SQ-6); every other choice follows the owner's rule of 2026-10-28 ("the closest to macOS 27, no technical
step for the end user") and is listed in "Decisions taken under the owner's rule" (SD-1 to SD-8), which the owner can
revisit. Revised after the integrator's opus review of 2c0bd74 (FAIL: one MAJOR, eight MINORs, three NITs), answered in
"Review history"; each changed place says "review of 2c0bd74". The owner answered SQ-1 to SQ-6 on 2026-10-29 (asked by
the integrator, recorded in "Owner decisions"): SQ-1 B makes ADR-0010's separate security process the path of step 1;
the other five take the recommended option. · Date: 2026-10-29 · Decider: owner (SQ), integrator (merge; SD under the rule) · Number: 0041 (0040 is the
identity ADR on main b345334; the open pull requests #48 and #49 add none)

This ADR proposes the "Stability" work: what happens when a process of the Grassfield session crashes, hangs, loops or
leaks, and what happens when the system under it moves. Its audit is `docs/audits/stability-2026-10-29/audit.md`
(findings P-1 to P-13, U-1, I-1 to I-7, T-1 to T-10, M-1 to M-11, each with file and line); this ADR cites them by number.
Nothing here is verified at runtime: this container has no Hyprland, no Quickshell and no systemd user session, so every
runtime claim is **NOT VERIFIED** until the integrator's nested pass and the owner's real-session checks named per step.

**The target, in the owner's words.** Grassfield as stable as a Mac: an app that crashes never takes the session down;
the shell or a service that crashes restarts by itself, and when it crashes in a loop the session falls back to a safe
mode **without ever unlocking the screen**; a system update (Arch/Omarchy: Qt, Quickshell, Hyprland) can never install an
incompatible combination; no infinite loop, memory leak or hang lasts.

## Context

### The owner's brief (2026-10-29)
- One pull request per step. Step 0 (this one): the measured inventory of every process, the update compatibility
  matrix, the known incidents as case studies, the tests and their gaps, the macOS model per case, a plan in short steps
  ordered by user impact (each with its proof, its tests and what the integrator checks in nested), and the owner's
  questions with two or three options each. No code.
- Everything that touches `shell/security` (the lock during a crash, the safe mode) goes through the opus security
  review and never unlocks on a failure. No new service and no new dependency without a justification here.
- Coordination: the delay of the red "lock screen died" screen (IQ-T5) belongs to the identity work (ADR-0040); it is
  referenced here, not redone.

### Rules this ADR works under
- master-prompt §3: R1 (evidence before claims), R2 (the agent runs nothing privileged: every unit, hook or package change
  is installed by the owner), R5 (no new service, daemon or dependency without a need in the current milestone: the
  table "New units, packages and dependencies" justifies each one or hands it to the owner), R12 (security modules:
  `WlSessionLock`, `PamContext("omarchy-lock-password")`, Quickshell's polkit only; an opus reviewer PASS and the L1-L5
  gates for every change; a failure leaves the session locked), R13 (the compositor plugin degrades, never blocks).
- Gates touched: R1 (shell crash recovery ≤ 3 s, state restored), L1 (killing the shell while locked leaves the session
  locked), C1-C3 (plugin stability, degradation, upstream), P2 (memory), Q3 (tests), S1 (no prohibited command in scripts).
- Upstream code is data (R4): the Quickshell, Hyprland, systemd and pacman behaviours named here are those the audit
  read in Grassfield's own records; each step re-verifies the ones it relies on.

### What the audit found (the short version)
1. **The crash loop is not handled** (P-2a). `grassfield-shell.service` restarts after 1 s and stops only after 10 starts
   in 30 s; the arithmetic trips the limit only for a shell that dies within 2.0 s of each start (the eleventh start is
   the refused one). The 2026-10-29 loop
   (a crash 5 s after every start) restarted for ever; the owner's recovery was a snapshot. While it loops, a locked
   session stays locked (the compositor keeps the lock; only a PAM success unlocks: fail closed) but cannot be unlocked
   either: the password field exists for a few seconds per cycle. Unlocked, the desktop blinks out every cycle, the polkit
   agent, the idle lock and the sleep inhibitor are absent while the shell is down (Omarchy's sleep-lock unit covers a
   sleep). Nothing tells the user what is happening. There is no safe mode.
2. **An update is checked on one path only** (U-1, section 2 of the audit). Update Now refuses an untested Qt, Quickshell,
   Hyprland, aquamarine or KF6 (ADR-0033 s3.4). `omarchy update` and `pacman -Syu` have only pacman's rules:
   `conflicts=('quickshell=0.3.2')`, found after the incident. Files, Settings, Store, Preview, Activity Monitor and the
   portal link Qt's private API, Quickshell itself imports 61 private Qt symbols (review of 2c0bd74), and the shell runs
   on whatever Quickshell is installed at its next start.
3. **Every other process has a policy, some fail silently** (P-4 to P-13): the bridge backs off and degrades to T0 menus
   after 5 crashes an hour, for the session; the portals are re-activated by D-Bus; crash-watch, battery-watch and
   automount give up after 5 failures in 2 minutes with nothing said; apps crash alone and get "quit unexpectedly" with
   Reopen; the root helpers run once and leave status files.
4. **The compositor is the one process nothing can bring back** (P-1, P-3): a crash in Hyprland, the plugin included,
   ends the session, as a WindowServer crash does on macOS. The plugin's guards, the ABI refusal and the C1-C3 gates are
   the whole defence.
5. **Nothing measures the long run** (T-3, T-7): a real session rose about 6 MB/h at idle with no known cause; at that
   slope the unit's `MemoryHigh` arrives after about 7 days and `MemoryMax` after 17 (a kill and a restart). No fuzzing
   (T-1), no chaos test (T-2), no hang detection (T-6), no gate against the next toolkit (T-5, T-10).
6. **Seven incidents** (I-1 to I-7) teach the same lesson: the damage was bounded by luck or by the owner, not by the
   session: a toolkit update on an unchecked path, a hot reload of a half-written tree, a timer that spun for an hour, a
   portal that waits 25 s for a reason this audit can only hypothesise, a Store that depends on the system's databases,
   a compositor loop that filled a disk, a shell runaway with no cause.

### Coordination with other ADRs (one owner per overlap)
| Overlap | This ADR | The other |
|---|---|---|
| The red "lock screen died" screen's delay during a shell restart | names it; step 1's nested pass records what is drawn, nothing more | ADR-0040 IQ-T5 (owner question) |
| A separate security process (lock, polkit, idle, sleep inhibitor) | step 1 builds it (the owner's SQ-1 B, 2026-10-29): ADR-0041 carries the S1-S4 plan in the integrator's order (the process and its unit first, then the lock with idle and the sleep inhibitor, then polkit, safe mode last), each S-step under the opus security review; ADR-0010 is amended to say so | ADR-0010 "Separate security process", amended 2026-10-29 |
| The compatibility check, the `[grassfield]` repository, the rc-channel watch job | SQ-3 revisits one rejected option (versioned bounds) with a new shape; the check U27, the a2 "Turn Off" path and the watch job stay as they are | ADR-0033 s3.4, a2, f |
| The compositor extension's ABI, rebuild and degraded mode | the ABI rule, the user-only rebuild and the degraded mode unchanged; step 2d reverses one line of ADR-0009's amendment ("With the toggle off the notice gives the command"): the notice gives one action, the toggle stays off by default, and 2d amends ADR-0009 explicitly (review of 5a20d19); SQ-6 adds one rule for the login after a compositor crash | ADR-0009 and its amendment |
| The session configuration under a package upgrade | step 2 adds one guard to the shell's explicit reloads; the watcher stays off | ADR-0001 amendment 2026-10-29 |
| The portals' start-up and the `GTK_USE_PORTAL` loop | step 7 verified the 25 s hypothesis (I-4): refuted (x-d-p-gtk unsets `GTK_USE_PORTAL` itself); the cause was a dropped call in the menu bridge, fixed | ADR-0035 D-4, D-8, 2b-12, 2b-14 |
| The persisted files and their readers | step 5 fuzzes each reader of the ADR-0020 table and adds the bound every reader must keep | ADR-0020 |
| The `/proc` and `/sys` readers of Activity Monitor | step 5 fuzzes them with the fixtures the sampler's tests already hold | ADR-0038 |
| The crash watcher and the "quit unexpectedly" notice | unchanged; SQ-4 adds one action | `docs/compat.md` "What Grassfield provides itself", `tests/shell/crash_watch.sh` |

## Principles
- **SP-1 Fail closed, always.** No step unlocks, weakens a lock, approves an authorization or sleeps unlocked to recover
  from a failure. A recovery that cannot keep the lock does not happen; the compositor's lock is the floor (SEC2, L1).
- **SP-2 An application is never the session.** Every app runs in its own scope; nothing an app does reaches the shell
  but through bounded inputs (ADR-0011, MB14). This holds today and stays a gate of every step.
- **SP-3 Every process comes back, or says so.** A process that restarts says nothing (macOS). One that cannot come back
  says so once, in the user's language, with the one action that helps (Try Again, Log Out, Open Software Update), never
  a command.
- **SP-4 Bounded everything.** Restarts, retries, logs, memory, CPU, timers, reads of a file, waits on a socket: each has
  a limit written next to it and a test that reaches the limit.
- **SP-5 The session is never surprised by a package.** A running session keeps running on what it loaded; a toolkit that
  Grassfield has not been built against never becomes the one the next start uses unless the owner said so (SQ-3).
- **SP-6 No technical step.** The user never types a command, never reads a journal, never edits a file to recover; what
  cannot meet that is a documented known limit, not a hidden one.
- **SP-7 Evidence.** A step is done when its nested test reaches the failure on purpose and the session comes back as
  the row says; "it should" is not a result (R1).

## Decision: the plan

Steps ordered by what the user would otherwise suffer first; each step is one pull request (or two where marked),
reviewed, with its nested pass before merge. Steps 1 and 2 need owner answers (SQ-1 to SQ-3); the rest can start now.
"Integrator, nested" lists what the integrator verifies in a nested session before merging; "Owner, real session" what
only the owner can check (L2); "Review" names the required reviewer.

### Step 1: the loop stops, and the lock lives apart from the UI (P-2a, M-4, M-5, M-9; SQ-1 B, SQ-2 A) — **opus security review on every part**
Goal: a UI that crashes in a loop, at any pace, stops looping within minutes; the lock, the polkit agent, idle and the
sleep inhibitor keep running whatever the UI does; the session stays locked if it was; safe mode is "the UI unit
failed, the security process is up", with a way out (Try Again, Log Out), never a lock-out. Rewritten after the owner's
answers of 2026-10-29 (SQ-1 B: ADR-0010's separate security process now, S1-S4; SQ-2 A): the first version built a safe
configuration of the one shell process. Order and rules set by the integrator under the owner's rule: 1a ships first and
unchanged (independent, it stops a slow loop today); then the security process, its unit first with nothing moved yet
(S1), then everything that locks together (S2: the lock, idle and the sleep inhibitor, with every `Lock.lock` caller
switched in the same step; the integrator's review of f018b42 found that moving the lock alone would leave the UI's
inhibitor and idle unable to lock while the security process restarts), then the polkit agent (S3); safe mode is the
last step (S4). The UI keeps refusing while locked from state it receives, and a missed push can never fail it open
(ADR-0010's risk 2; review of f018b42): the heartbeat carries the state and a sequence number, and `SessionState.locked`
is the pushed state OR the compositor's own lock signal (hyprland-lock-notify-v1, which `shell/services/Clipboard.qml:28`
already ORs in) OR "no state yet" OR a stale heartbeat OR a security unit that is not active and running. The second Qt
Quick process's memory and start time are measured at S1 against the budgets; IQ-T5 (the compositor's lockdead delay,
ADR-0040) still applies to a crash of the security process itself. Each part is its own pull request under the opus
security review (R12), and the invariant of every intermediate state (which process locks, what happens when either is
down, how sleep behaves) is written in the table at the end of this step.
- **1a. The loop detector** (SQ-2 A: 3 failures within 10 minutes; systemd's start limit raised to 10 starts in 5 minutes
  as the backstop). `grassfield-shell.service` gains a second `OnFailure=` unit, `grassfield-shell-failed.service`
  (`Type=oneshot`, a POSIX sh script, standard tools only), which records each failure's monotonic time in
  `$XDG_RUNTIME_DIR/grassfield/shell-failures` (0600), prunes the window and, at the threshold, cancels the pending restart
  (`systemctl --user stop grassfield-shell.service`, which a unit in auto-restart accepts) and writes the safe-mode state
  file the security process reads from S4 on. A logout does not count: the script applies the same "compositor gone"
  test as the sleep-lock gate (`packaging/systemd/sleep-lock-gate`), so the 255 exit of every logout (GF-081) never
  counts as a failure. `OnFailure=omarchy-sleep-lock.service` stays, unchanged. Before S4 ships, what the user sees at
  the threshold is what the start limit gives today, reached now for a slow loop too: the UI stays stopped (no bars,
  the windows over the ground colour), the compositor keeps a lock if there was one (fail closed, out of reach from the
  session), Omarchy's sleep lock stays armed and its stand-in tries the shell once more at sleep time (`reset-failed` +
  start). Unlocked, there is no idle lock and the lock key does nothing (it is `qs ipc` to the shell,
  `bindings.lua:148`): only a sleep or the lid locks, each bringing the shell back through the stand-in; the other exit is
  a TTY (opus security review of b1d826b; `docs/specs/security.md` "Lock coverage" says so). Proof: a nested run where the shell is killed with SIGSEGV
  every 5 s while locked: Hyprland reports `LOCK` on every monitor throughout, nothing typed reaches a probe window, the
  restarts stop after the third failure; the same unlocked; a logout during the window does not count. Tests:
  `tests/shell/unit_restart_limits.sh` gains the lifetime model (it must fail on today's unit, then pass); a logic test
  of the detector on a fake `systemctl` and a fake runtime directory (`tests/shell/shell_failures.sh`);
  `tests/security/sleep_lock_units.sh` for the gate with the stopped unit; the unit-level loop itself (three failures,
  the stop, the state file) under a throwaway systemd user manager in a container, with S1 (the nested dev session runs
  the shell through `scripts/dev/shell-run.sh`, not through the unit, so `reload_locked.sh` cannot produce a unit loop;
  the first version of this step planned a `crash-loop` step there: deferred to that container harness, opus review of
  b1d826b, finding 2). Owner, real session: `kill -SEGV $(systemctl --user show -p MainPID --value
  grassfield-shell.service)` three times within ten minutes while locked: the session stays locked and the restarts stop
  (`scripts/gates/r1-restart.sh --journal` then has its first real restarts, gate R1). Review: opus security (R12).
- **S1. The security process and its unit, nothing moved yet.** `shell/security/` is made free of UI imports (ADR-0010 S1:
  the lock backdrop through a `Grassfield.Ui` type; popups closed by the UI on `SessionState.locked`, so `Lock.lock()`'s
  `Popups.close()` goes; the sleep notice through the notification server's public D-Bus interface), without a
  behaviour change. A second root, `shell/security.qml` (next to `shell.qml`, so `qs.*` resolves from the same directory), and its unit `grassfield-security.service` (`Restart=always`,
  `RestartSec=1`, `StartLimitIntervalSec=300`, `StartLimitBurst=5`, `PartOf=` and `Requisite=graphical-session.target`,
  `ConditionEnvironment=GRASSFIELD_SESSION=1`, the same `UnsetEnvironment=` lines as the shell's, no
  `NoNewPrivileges` for the same reason as the shell's, `MemoryHigh=`/`MemoryMax=`/`CPUQuota=` set from the S1
  measurement) run beside the UI, started by `autostart.lua` before the shell, hosting nothing but the IPC target
  `security state` (answers `starting`) and a heartbeat the UI reads. Measured and recorded against the budgets: the
  process's RSS at idle (gate P2's accounting gains a second process), its start time to the first IPC answer (gate P5:
  the session to a usable menu bar and dock stays ≤ 2 s). Tests: `tests/security/shell_unit_env.sh` and
  `session_services.sh` for the unit; `ipc_inventory.sh` for the new target; `import_graph.py` for the import freedom;
  `scripts/gates/rss.sh --nested` with both processes. Review: opus security.
- **S2. Everything that locks moves together: the lock, idle and the sleep inhibitor.** `Lock`, `LockView`, the
  crash-recovery marker, the stranded-lock takeover, `Idle` (dim, lock, display off) and `SleepInhibitor` with its
  `PrepareForSleep` watcher run in the security process. The IPC targets `lock lock`, `lock lid` and `lock status`
  answer on the security instance (`qs ipc -p /usr/share/grassfield/shell/security.qml`), and every caller of `Lock.lock` or of
  the targets switches in the same pull request: in-process callers become IPC callers (`shell/overlay/SystemMenu.qml:72`,
  `shell/services/SessionState.qml:21` `requestLock`, `shell/shell.qml:88`, `shell/services/Popups.qml`,
  `shell/services/TilingSuggest.qml`), and the external ones change their path (the key bindings in
  `config/hypr/grassfield/bindings.lua`, `grassfield-lid`, the `omarchy-shell` stand-in, the screen corners, the apps'
  `shellIpcArgs()` callers of `lock`, the tests); `Idle.qml:142` and `SleepInhibitor.qml:72, :84` stay in-process because
  they move with the lock (review of f018b42). In the same step `OnFailure=omarchy-sleep-lock.service` moves to
  `grassfield-security.service` (the shell's unit keeps `Restart=always` and 1a's detector, and loses that `OnFailure=`:
  it no longer holds an inhibitor), the sleep-lock gate is keyed on the security unit (`active`/`running` of
  `grassfield-security.service` alone: the UI's state is no longer part of the sleep question), and the stand-in's
  `lock lock` starts the security unit when it is not running. The UI reads `lock state` at start and receives a push on
  every transition; the heartbeat (every 2 s) carries the state and a sequence number, so a lost push is corrected by
  the next heartbeat; `SessionState.locked` is the pushed state OR the compositor's lock signal (hyprland-lock-notify-v1)
  OR no state yet OR a stale heartbeat (no beat for 5 s) OR a security unit that is not active and running: every UI
  refusal (GF-116, "Show previews: When Unlocked", Overview, Switcher, the Dock's reopen) reads locked in each of these
  cases, fail closed. The idle and sleep notices go through the notification server's D-Bus interface (journal only
  while the UI is down). Proof: ADR-0010's crash-injection test moved here: a crash signal to the UI process while
  locked leaves the lock surface in place (no lockdead screen) and nothing typed reaches a window; while unlocked, the
  idle lock still fires and a sleep still locks first; a crash of the security process while locked keeps `LOCK` on
  every monitor until its restart takes the lock back, and a sleep requested while it restarts is delayed by Omarchy's
  unit until the restarted process reports `secure`. Tests: L1-L5 against the security process (`reload_locked.sh`
  every step, `l2_wrong_password.sh`, `lock_privacy.sh`, `lock_surfaces.sh`, `lock_monitor_model.sh`, `marker_read`,
  `reload_order`); `sleep_lock_units.sh` for the gate and the stand-in keyed on the security unit, `tst_idlemodel`,
  `lid.sh`, `screensaver_inhibit.sh`; a UI-side test that every refusal reads locked on no state, a stale heartbeat, a
  lost push with the compositor's signal set, and a stopped security unit (mutants on each); a scan that no `Lock.lock`
  caller is left in the UI tree (`ipc_inventory.sh`). Owner, real session: DT-01 and DT-21 re-run (kill the UI while
  locked, kill the security process while locked), L3 (lock before sleep) and the lid. Review: opus security.
  ADR-0040 step 4a (2026-10-31; opus review of cbd6ef05, MINOR 1 and 2) leaves S2 three things: the lock's backdrop reads
  `wallpaper.json` `shown` through the desktop's `WallpaperState`, which reads the file once and is a desktop store with
  side effects (it starts processes and writes `wallpaper-state.json`): the security process needs its own watched reader
  of `shown` with the pure `WallpaperConfig.lockBackdropOf`. The preloaded stills are decoded at full size, one per output
  (about 33 MB per 4K output, up to Qt's 256 MiB allocation limit for a hostile file): measure them against
  `MemoryHigh=320M`. And the decode: only the JPEG image plugin (PNG is built in) and a file the process opened itself
  (`O_NOFOLLOW`, `fstat`), so that the checked file is the decoded one.
- **S3. The polkit agent moves.** `AuthAgent` and its dialog run in the security process, drawn with `Grassfield.Ui`
  only; exactly one agent in the session (L5: registration, action id and program shown, cancel works, never
  auto-approves); the UI's `polkit status` dev hook moves with it. Tests: `authagent_flows.sh`, `tst_authdialog*`,
  `mutate_authdialog.sh` against the security process. Review: opus security.
- **S4. Safe mode, last.** When 1a's state file says the UI is stopped for a loop, the security process maps one layer
  surface: the Grassfield mark, the sentence "Grassfield is running in safe mode: its desktop stopped working and was
  turned off." and the Grassfield menu with Try Again…, Log Out…, Restart…, Shut Down… (the existing session-end path),
  drawn with `Grassfield.Ui` only, under the lock surface when locked, and only once it has checked that the shell unit
  is really stopped (`systemctl --user show -p ActiveState`): a stale `shell-safe-mode` from an earlier loop, with the
  shell brought back by the stand-in or by hand, shows nothing (opus review of b1d826b). Try Again starts
  `grassfield-shell.service`, empties the failures file and removes `shell-safe-mode`; a second loop returns here. Nothing else: no Dock, desktop, Search, notification server or
  request socket to the plugin (the 2026-10-29 crash lived in those sockets, I-1, which the security process never
  opens). Proof: the 1a nested run, now ending with the safe-mode bar after the third failure, the password unlocking
  at the first attempt, Try Again restoring the desktop; captures (en, fr, light, dark). Tests: the safe-mode surface
  offscreen (`tests/security/safe_mode.d/`), `reload_locked.sh` gains `safe-mode`, `ipc_inventory.sh` for its actions.
  Owner, real session: the 1a kills, then safe mode, the password, Try Again. Review: opus security.
- The invariant of each state (review of f018b42: which process locks, what happens when either is down, how sleep
  behaves). "Down" means not active/running: restarting, failed, or stopped at its limit.

  | From | Who locks | The UI process down | The security process down | Sleep |
  |---|---|---|---|---|
  | today, and after 1a | the UI (`grassfield-shell`) | the compositor keeps an existing lock (lockdead screen, IQ-T5); no idle lock and no inhibitor until the restart or the stop; after 1a's stop, the compositor's lock stays and the session is out of reach from itself | n/a | the UI's inhibitor while it runs; Omarchy's sleep lock (armed by `OnFailure=`, the gate skips it only while the UI runs) asks the stand-in, which starts the UI and asks it to lock; a sleep that cannot lock in logind's window is the known limit |
  | S1 | the UI, unchanged | unchanged | nothing: the security process hosts nothing yet | unchanged |
  | S2 | the security process, and only it: every lock request goes to it over IPC | the lock, idle and the inhibitor keep running; the UI's refusals read locked from the compositor's signal, the pushed state or the absence of a state; nothing about the lock changes | the compositor keeps an existing lock (lockdead screen, IQ-T5); no idle lock and no inhibitor until its restart (1 s) or its stop at the limit; the UI's refusals read locked (the unit is not active/running); Omarchy's sleep lock is armed by the security unit's `OnFailure=` | the security process's inhibitor while it runs; the gate skips Omarchy's unit only while the security unit is active/running; Omarchy's stand-in starts the security unit and asks it to lock; the same known limit when it cannot start in logind's window |
  | S3 | the security process | as S2; an authorization asked while the security process restarts fails, as it does today while the UI restarts | as S2, plus no polkit agent until the restart | as S2 |
  | S4 | the security process | as S2; after 1a's stop the safe-mode notice appears while the session is unlocked and no sheet is up, never under or over the lock (S4 as built) | as S2; the notice is gone with it, and back after the restart if the UI is still stopped | as S2 |

- Known limits (written in the spec): a Quickshell bug that takes the security process down in a loop leaves the
  compositor's lock in place and the session out of reach from itself (the TTY or the power button); a second Qt Quick
  process costs memory (measured at S1, the budget recorded in `docs/testing/gates.md`); until S4 ships, a crash of the
  UI still takes the inhibitor down for the restart's second (Omarchy's sleep lock covers it, as today).
- Integrator, nested: every proof above, step by step; `lock_surfaces.sh`, `ipc_inventory.sh`, `shell_unit_env.sh`,
  `session_services.sh` after each move; what the compositor draws during a security-process restart is recorded for
  IQ-T5.

### Step 1a as built (2026-10-29, after the owner's answers; the branch of the stability lane)
- `packaging/bin/grassfield-shell-failed` (POSIX sh, standard tools) and `packaging/systemd/grassfield-shell-failed.service`
  (`Type=oneshot`, hardened like the session services, `RuntimeDirectory=grassfield` kept): started by `OnFailure=` of
  `grassfield-shell.service` next to Omarchy's sleep lock after every failure; keeps the monotonic time of each failure of
  the last 10 minutes in `$XDG_RUNTIME_DIR/grassfield/shell-failures` (0600) and at the third cancels the pending restart
  (`systemctl --user stop grassfield-shell.service`) and writes `shell-safe-mode` (the state S4 reads); a logout counts
  nothing; what it cannot do (no runtime directory, no clock, an unwritable ledger) is logged and counts nothing, so a
  counter that cannot count never stops the shell. Its one state change is the stop; nothing unlocks, starts or signals.
- `packaging/systemd/session-gone`: the "compositor certainly gone" test extracted from the sleep-lock gate and shared
  with the counter (both run it as `$(dirname "$0")/session-gone`; a missing helper reads as "not gone", the safe side for
  both). The gate's decisions are unchanged (`tests/security/sleep_lock_units.sh` 0 FAIL).
- `grassfield-shell.service`: `StartLimitIntervalSec=300`, `StartLimitBurst=10` (SQ-2 A's backstop: a loop faster than one
  crash every 29 s ends at the limit), `OnFailure=omarchy-sleep-lock.service grassfield-shell-failed.service`.
- Tests: `tests/shell/shell_failures.sh` (logic, 31 cases with stubs: the three failures, the window, the logout, a garbage
  or symlinked ledger, no runtime directory, an unreadable clock, the test variables, the static wiring; three mutants
  each change the decisions); `tests/shell/unit_restart_limits.sh` gains the lifetime model
  (`unit_restart_limits.py`: a loop of one crash every 10 s must end, by the limit or by the counter; the shell's first
  unit fails it, the unit with the counter passes, a limit a 10 s loop reaches passes); `sleep_lock_units.sh` and
  `shell_unit.sh` updated for the two `OnFailure=` units and session-gone. Inventory 571.
- Evidence (this container, no systemd user session): `shell_failures.sh` exit 0 (34 PASS: 31 cases, 3 mutants), `unit_restart_limits.sh` exit 0
  (and the model rejects the old unit from git: exit 1), `sleep_lock_units.sh` exit 0, `shell_unit.sh` exit 0
  (`systemd-analyze verify` NOT VERIFIED here: no runtime directory; its "environment refuses" patterns gain that message),
  `python3 -I tests/ci/inventory.py` ok. NOT VERIFIED: the unit wiring under a real user manager (the integrator's
  `systemd-analyze --user verify` on the packaged units; the owner's L2 kills: `kill -SEGV` the shell three times within
  ten minutes while locked: the session stays locked, the restarts stop, `shell-safe-mode` exists; then
  `systemctl --user start grassfield-shell.service` brings the shell back, and `scripts/gates/r1-restart.sh --journal` reads
  the first real restarts).
- Review: opus security (R12: the counter stops the process that holds the lock; the compositor keeps it). Verdict on
  b1d826b: PASS (nothing can unlock; the stop reaches a unit waiting to restart, so no process gets a signal, and a shell
  already restarted gets SIGTERM, which DT-21 covers; the gate unchanged; 30 mutants, 22 killed by behaviour), with
  fixes before the merge, answered in the commit that follows: the stopped-but-unlocked state written in the security
  spec (no idle lock, the lock key inert, the lid or a sleep brings the shell back), the deferred nested loop proof
  named (the container harness of S1), the unit clears the script's test variables (`UnsetEnvironment=`), the
  sandbox's comment and pin (`ProtectHome=read-only`, AF_UNIX for the manager's socket), the stop's result logged
  after the stop, S4 checks the unit is really stopped before it shows safe mode, and the tests for the real clock,
  `RestartMode=normal`, the exact 600 s boundary, the counter reachable through `OnFailure=` only, a failed stop.
  NOT VERIFIED by the reviewer either (no spare user manager): the owner's L2 list below.
- Owner, real session (L2, from the review of b1d826b): (1) the counter's unit reaches the manager with
  `systemctl --user stop`; (2) `OnFailure=` fires on every crash under systemd 261; (3) three crashes within 10 minutes
  while locked: the session stays locked, the restarts stop, `$XDG_RUNTIME_DIR/grassfield/shell-safe-mode` exists;
  (4) the same while unlocked, then the lid brings the shell back; (5) a logout counts nothing.

### S1 as built, first part (2026-10-30, the branch of the stability lane; the readers of the UI not yet freed)
- `shell/security.qml`: a second root next to `shell.qml` (so `qs.*` resolves from the same directory and the modules
  move later without moving a file), QtQuick + Quickshell + Quickshell.Io only, `settings.watchFiles: false`, one
  `IpcHandler` `security` with `state` (`starting`) and `heartbeat` (the state and a sequence number), the journal line
  "grassfield-security: ready" its start time is measured from; it hosts nothing moved yet, locks nothing, draws nothing.
- `packaging/systemd/grassfield-security.service`: `ExecStart=/usr/bin/qs -n -p /usr/share/grassfield/shell/security.qml`,
  the UI unit's `Environment=` and `UnsetEnvironment=` lines verbatim (a test keeps them identical), `Restart=always`,
  `RestartSec=1`, `StartLimitIntervalSec=300`, `StartLimitBurst=5`, `PartOf=`/`Requisite=graphical-session.target`,
  `ConditionEnvironment=GRASSFIELD_SESSION=1`, no sandbox (the helpers of S2/S3), no `OnFailure=` yet (S2),
  `MemoryHigh=256M`/`MemoryMax=512M`/`CPUQuota=50%` marked provisional until the measurement. `autostart.lua` starts it
  just before the shell with `--no-block`; the PKGBUILD installs the unit (the root ships with the shell tree, the helper
  from `packaging/bin`). `packaging/bin/grassfield-security-status`: read-only, prints the state, the heartbeat and the
  unit's live values; it is the real-session caller of the two IPC functions (the IPC surface table has the row).
- Deferred to S1's second part, which needs a Quickshell to run (none in this container): the UI-import freedom of
  `shell/security/` (ADR-0010 S1: `LockView`'s `qs.desktop` backdrop through a `Grassfield.Ui` type, `Lock.lock()`'s
  `Popups.close()` dropped since GF-116 closes popups on `SessionState.locked`, `SleepInhibitor`'s notice through the
  notification server's D-Bus interface, `AuthAgent`'s and `Idle`'s `qs.services` reads), and the measurement.
- Tests: `tests/security/security_unit.sh` (data: the root's imports, no module instantiated, the handler, the unit's
  lines identical to the UI's, the start limit, the autostart order, the package, the helper, the IPC row; qmllint parses
  the root where installed); `session_services.sh` knows the new unit in the autostart chain; the IPC surface table gains
  the `security` row for `ipc_inventory.sh`; inventory 577.
- Evidence (this container): `security_unit.sh` exit 0; `unit_restart_limits.sh`, `session_services.sh`,
  `sleep_lock_units.sh`, `shell_unit_env.sh` exit 0; `python3 -I tests/ci/inventory.py` ok; `qmllint 6.4` parses
  `shell/security.qml` (only the Quickshell modules are unknown to it). NOT VERIFIED: the process under Quickshell
  (`ipc_inventory.sh` and `import_graph.py` need Qt's `qmldom` and `qmlimportscanner` at their Arch paths: the
  integrator's `just check-quick`), the nested run (`qs -p shell/security.qml` beside the dev shell: one instance each,
  `grassfield-security-status` answers `state=starting`), the measurement (RSS at idle with `scripts/gates/rss.sh --nested
  --pid`, the start time from the unit's "Started" line to "grassfield-security: ready" in the journal), and the real
  session (the unit starts at login before the shell, `systemctl --user status grassfield-security.service` active/running,
  the helper's line).
- Review: opus security (R12: a new process in the lock's future path; at S1 it changes nothing about the lock).
- Merged 2026-10-31 as 6fc2bb2e (#72, the opus security review PASS). The integrator's nested pass: the root runs with its
  own instance ID beside the dev shell, its IPC answers `state` and `heartbeat` only, it takes no surface, no lock and no
  bus name; the lock holds through a `kill -9` of the UI and the UI's restart takes it again; killing the security
  process leaves the UI locked; a duplicate start is refused; 157 MB of RSS at idle.

### S1 as built, second part, first slice (2026-10-31; the four items of #72's merge review)
- `tests/security/security_unit.sh`: the root's check is an allow-list (it instantiates `ShellRoot` and `IpcHandler` only)
  and refuses `Loader`, `LazyLoader`, `Component`, `source:`, `createComponent`, `createQmlObject` and a file import; the
  deny-list let a `FloatingWindow`, a `PopupWindow` or a `Loader` of the lock module through.
- `grassfield-security.service`: `MemoryHigh=320M` and `MemoryMax=640M` from the 157 MB measured (about twice and four
  times: a slow leak reaches the first after days, a runaway one the second, R4); `CPUQuota=150%` as the UI unit's, since
  the 50% of the first version would have throttled the lock's rendering and the PAM exchange from S2. S2 measures again
  with the lock's surfaces and resets the three.
- `grassfield-security-status` passes `--any-display` when `WAYLAND_DISPLAY` is not set (Quickshell 0.3.1: "instances
  will not be filtered by the display connection they were launched on"), so it answers from a TTY; inside the session
  the call is unchanged.
- The paths that still named `shell/security/shell.qml` and `/usr/share/grassfield/security` in this ADR and in ADR-0010
  now name `shell/security.qml` and `/usr/share/grassfield/shell/security.qml`.
- Still deferred (needs a Quickshell): the UI-import freedom of `shell/security/` and the start-time measurement
  (gate P5); the real-session checks of the first part.
- Evidence (this container): `tests/security/security_unit.sh` exit 0 (17 PASS, the allow-list and the TTY check among
  them); `unit_restart_limits.py` on the unit ok; `session_services.sh` 28 PASS; `python3 -I tests/ci/inventory.py` ok
  (596); `git diff --check` clean. NOT VERIFIED: `grassfield-security-status` from a TTY on a machine with the session.
- Review: opus security (the unit's guards and the status helper are in the lock's future path; the allow-list is the
  test that keeps S1's root empty).
- Review round 1 (2026-10-31, the integrator's opus security review of eecf953: FAIL, one major):
  1. Major: the allow-list matched line by line, and Qt accepts what slipped past it: a `FloatingWindow` with its brace
     on the next line or a comment before it, an indented `import Quickshell.Wayland` with a `WlSessionLock`, a
     tab-indented `import qs.security.lock` with `Lock.locked` (a singleton needs no brace); qmllint 6.11.2 accepts them
     all and an offscreen `qml` probe ran them. Now `tests/security/root_check.py` reads the root as the engine does:
     comments (`//`, `/* */`) stripped and string literals blanked by a scanner, the file joined on whitespace, imports
     taken wherever they stand (`^\s*import`) and held to QtQuick, Quickshell and Quickshell.Io, every `Name {` held to
     ShellRoot and IpcHandler, and no `/` or backtick outside comments and strings (a regex literal's `//` would read as
     a comment and hide what follows it; a template string likewise), so the scanner's comment detection is sound. Its
     selftest plants twenty mutants (the review's five, and a regex literal, a template string, a dynamic `import()`, a
     file import, a versioned import hiding another, two windows on one line, a `Component`, `eval`, …) and each must
     be refused while the root passes.
  2. Minor: `Quickshell.execDetached`, `Qt.openUrlExternally`, `Qt.callLater` and `Process {` passed the "no process"
     claim: refused by name, with `createComponent`, `createQmlObject`, `eval`, `Function`, `include`, `XMLHttpRequest`,
     any `Qt.` or `qs.` name, a window, a popup, a socket and the security modules' names (`Lock`, `Idle`,
     `SleepInhibitor`, `AuthAgent`, `Pam…`, `Polkit…`, `Wl…`). At S2 the modules move in through their own files and the
     allow-lists grow with them, each under the same reading.
  3. Nit: the test's header no longer says "provisional".
  4. Notes for S2 (the integrator's, not blocking): above `MemoryHigh` the throttling could delay drawing the lock past
     the sleep delay; repeated kills at `MemoryMax` could use up the start limit (5 in 300 s), after which Hyprland keeps
     the lock with no client (`allow_session_lock_restore = true`: fail locked, the user shut out). Before S2: measure
     again with the lock's surfaces, and decide the start-limit behaviour (R5's rows for the security unit).
  Evidence: `tests/security/security_unit.sh` 39 PASS (the root check, its twenty-one selftest lines); `python3 -I
  tests/ci/inventory.py` ok (596); `git diff --check` clean.
- Review round 2 (2026-10-31, the integrator's opus security re-review of cdc77ef: FAIL, with the integrator's decision):
  the name deny-list could still be bypassed, each bypass run by an offscreen `qml`: a name written as a string
  (`Qt["createQmlObject"](…)`, `Reflect.get(Qt, "createQmlObject")(…)`, `Quickshell["execDetached"](…)`: strings were
  blanked before names were matched), a U+2028 ending a `//` comment for QML's lexer, and Unicode escapes spelling a
  name outside strings; a second `IpcHandler` with a next-line brace, `NumberAnimation on sequence { }` and
  `Quickshell.reload(true)` passed too. **Decision: a static check cannot model all of QML; the real guard is that every
  change to this root gets the opus security review.** So `tests/security/security_unit.sh` pins the reviewed root by
  its SHA-256 (comments included) and fails on any difference with "shell/security.qml changed: security review
  required, then update the pinned hash"; `root_check.py` stays as the bounded, readable second check: the whole file
  ASCII, no backslash, no backtick; outside comments and strings no `/` and no `[`; every identifier one of the
  twenty-seven the root uses today (an allow-list: a window, a loader, a process, `Qt`, `Reflect`, `reload`, an
  animation or a security module is simply not in it); imports and types as before; exactly one `IpcHandler` with
  target `security` and the functions `state` and `heartbeat` only, counted on the joined code. Its selftest plants
  thirty-two mutants (the three bypasses, the second handler, the animation, the reload, a third function, a renamed
  target, CRLF with a hidden window, and the earlier twenty) and the root passes with LF and with CRLF. Evidence:
  `security_unit.sh` 53 PASS; `python3 -I tests/ci/inventory.py` ok; `git diff --check` clean. Rule for every later
  change of the root (S2, S3, S4): the review first, then the new hash in the same pull request.

### S2 as built (2026-11-08, branch feat/safe-mode-s2 from main 8b04383c; everything that locks moves together)
- **What runs where.** The security process (`shell/security.qml`: `ShellRoot`, one `SecurityHost`, the `security` handler)
  hosts `shell/security/host/SecurityHost.qml`: the Translator and the appearance settings the lock follows, `Idle` (dim,
  idle lock, display off, the automatic sleep, and inside it `SleepInhibitor` with its `PrepareForSleep` watcher) and the
  `Lock` singleton (WlSessionLock, `PamContext("omarchy-lock-password")`, the crash-recovery marker, the stranded-lock
  takeover, the ownership check, `LockView`). The UI (`shell/shell.qml`) imports neither `qs.security.lock` nor
  `qs.security.idle` and names no `Lock`, `Idle` or `SleepInhibitor` (`tests/security/security_process_scan.py`, the scan the
  plan asked of `ipc_inventory.sh`, with 21 planted mutants): a crash of the UI cannot touch the lock, and the polkit agent
  and the secret sheets stay in the UI until S3. IPC on the security instance (`qs ipc -p
  /usr/share/grassfield/shell/security.qml`): `lock lock`, `lock lid`, `lock state` (new, `unlocked|locked` only, ADR-0010
  S3), the lock's dev hooks, `idle inhibit` (new) and idle's dev hooks, `security state` (`lock idle`) and `security
  heartbeat` (`<public state> <sequence>`). The root's hash and `root_check.py` follow the rule of round 2 (38 mutants);
  `SecurityHost.qml`, all the root instantiates, is pinned by its own hash (review round 1 below).
- **Free of the UI's world (ADR-0010 S1, deferred from S1's second part).** `LockView` draws the artwork with
  `Grassfield.Ui`'s `GrassfieldArtwork` (no `qs.desktop`); `Lock.lock()` no longer calls `Popups.close()` (the UI closes its
  popups when it reads the session locked, GF-116); the sleep inhibitor's notice goes through the notification server's
  public D-Bus interface (`busctl --user --auto-start=no ... Notify`: no other daemon is ever activated; while the UI is
  down the journal has it; never in a dev session, journal only); ADR-0040 step 4a's first item: the lock reads
  `wallpaper.json` through its own watched, bounded reader (`LockWallpaper.qml`: `head -c` with a timeout, the pure
  `WallpaperConfig.lockBackdropOf`; the desktop's `WallpaperState` starts processes and writes files; found under
  `$XDG_STATE_HOME/grassfield`, since a security module reads no `GRASSFIELD_*` variable but the dev gate's, ADR-0019,
  and the dev session gives the process an `XDG_STATE_HOME` linked to its state); the account picture
  is made by `services/image-copy.py file` into the process's own file (`LockAvatar.qml`; the UI's `ThemeIcons` empties a
  directory the security process must not touch); the ground before the backdrop is `wallpaper.json`'s `ground`; the power
  source is `UPower.onBattery` (the UI's `Battery` runs a power-profile command on every change). The lock and idle name
  only the read-only `qs.services` types `Settings` (no setter is called, so it writes nothing), `VisualFixtures`,
  `FixedTime` and `WallClock` (the scan holds that list). The idle dim's layer surfaces exist only while the screens dim
  (`IdleDim.qml` by a `LazyLoader` source), so the process keeps no window per output the rest of the time.
- **The lock state across processes** (ADR-0010's risk 2; an architecture choice this ADR did not settle, taken under the
  owner's rule: no technical step, nothing for the user to see, the fewest moving parts). One file,
  `$XDG_RUNTIME_DIR/grassfield-lock-state-<compositor instance>` (`shell/lib/LockState.js`, one line of JSON: the public
  state `unlocked|locking|locked`, a sequence number, the writer's process id, whether idle switched the displays off,
  where the lock's clouds came to rest), written atomically by the security process only (`LockPublisher.qml`): on every
  change (the push, written before the compositor is even asked for the lock) and every 2 s (the heartbeat). The UI
  (`shell/services/LockClient.qml`) watches it and reads it every 2 s whatever the watch says, never writes it, and the
  security process reads nothing from the UI on it: no socket (S4's rule for the security process), no process per beat
  (a `qs ipc` per beat would cost idle CPU on both sides). `SessionState.locked`, which every refusal reads, follows
  `LockState.uiLocked`: locked unless a state is known, fresh (a new beat within 5 s, measured by a Timer and checked by a
  synchronous read before deciding), says `unlocked`, and the compositor reports no lock (`Clipboard.helperLocked`,
  hyprland-lock-notify-v1, while the clipboard helper runs). "A security unit that is not active and running" is read
  through the beat: a stopped, restarting, failed or hung process writes none, so the UI reads locked within 5 s; polling
  systemd from the UI would add a process per poll and tell no more (a hung process looks active to systemd). A same-user
  process can write the file, as it can call any IPC target; the compositor keeps the lock whatever the file says
  (`docs/specs/security.md` "Lock state across processes", which also names what a forged `unlocked` reaches before S3:
  the polkit agent's device rule and the secret sheets' hold). The first read of the file is no beat (only a second,
  different write proves a live writer), and `SessionState.lockConfirmed` (`LockState.uiLockConfirmed`: the compositor's
  signal, or a last published `locking`/`locked`, fresh or stale) tells "locked" from "reads locked because the security
  process is down" for the paths that only lock (below).
- **Every caller switched.** In process before, IPC now: the Grassfield menu and Search (`SessionState.requestLock`), the
  screen corners (the `lock` action is now in process too: `SessionState.requestLock("corner")`), all through
  `LockClient.request`, a `qs ipc` to the security root next to the UI's (`Quickshell.shellDir + "/security.qml"`), each try
  bounded at 5 s (`timeout -k 1 5`), retried every 250 ms for 10 s, and in a real session handed once to the stand-in, which
  starts a stopped security unit. External: the lock key (`bindings.lua`'s `security()`: in a real session a request the
  security process does not answer within 5 s goes to the stand-in, as `grassfield-lid`'s does), `grassfield-lid`, the
  stand-in's `lock lock` (starts `grassfield-security.service` when it is not running, restarts one from before S2),
  `grassfield-security-status` (`lock state`); the apps call no lock
  target (`shellIpcArgs()` callers: `dock reopen`, `activity quit`, `update check`). The screen-saver inhibitors the menu
  bridge serves to the UI reach idle as a lease (`idle inhibit 150`, renewed every 60 s while one is held, bounded at 150 s
  by `IdleModel.inhibitLeaseMs`): a UI that crashed during a video keeps the idle lock off for one lease at most.
- **Units.** `OnFailure=omarchy-sleep-lock.service` moved to `grassfield-security.service`; `grassfield-shell.service`
  keeps `Restart=always`, 1a's detector as its only `OnFailure=`; the sleep-lock gate asks `grassfield-security.service`
  alone; the stand-in's `lock lock` starts it. `MemoryHigh=1536M`, `MemoryMax=3G` (the lock's headroom in the UI's unit
  before S2, review round 1 MAJOR-2, until it is measured; memory below), `CPUQuota=150%` unchanged.
- **The start limit and `allow_session_lock_restore` (S1's notes for S2).** Kept at 5 starts in 300 s: a process that
  cannot come up must stop looping. At the limit the compositor keeps the lock with no client (fail locked); what brings it
  back without a technical step: closing and opening the lid or a sleep (the stand-in resets and starts the unit, which
  restores the lock from the marker). In an unlocked session every lock request ends in a locked session (macOS: a lock
  request always locks; review round 1, MAJOR-1): the lock key and the lid hand a request the security process does not
  answer to the stand-in, which resets and starts the unit and asks it to lock; the Grassfield menu (and its Log Out,
  Restart and Shut Down confirmations), Search (its Lock Screen command) and the lock corner stay open while the UI reads
  locked only because the state is missing, unreadable or stale after an `unlocked` (`SessionState.refusesConfirmed`; every
  other surface keeps `refuses`), and `LockClient` hands their request to the stand-in (a real session; a dev session
  retries for 10 s). What is lost meanwhile is the idle lock (no idle module runs) until a request or a sleep starts the
  unit again. On a desktop with no sleep and a session
  locked at the limit, a TTY remains: the known limit of SQ-1 B, now in the spec. A UI that starts and finds no published
  state for 15 s restarts the security unit once (an upgrade from a build before S2 leaves the earlier, empty security
  process running; or it is hung), never in a dev session, never past its start limit; the lock key, the lid and a sleep
  reach the same restart through the stand-in, which restarts a security process that answers `security state` with S1's
  `starting`.
- **Memory (gate P2 counts both processes; S1's note "measure again with the lock's surfaces").** Measured offscreen in
  this container (`qs` with `QT_QPA_PLATFORM=offscreen`, isolated homes and runtime directory, 15 s after start,
  `/proc/<pid>/smaps_rollup`, three runs each): the security root at S1 (main 8b04383c) RSS 64.9-65.1 MB, PSS
  27.2-27.5 MB; at S2 (lock and idle loaded, unlocked) RSS 108.4-117.0 MB (median 110.2), PSS 66.3-75.8 MB (median 68.2):
  about +45 MB RSS, +41 MB PSS, which leaves the UI (no `Lock`, `Idle` or
  `SleepInhibitor` objects, no lock surfaces). The UI root cannot load offscreen (layer-shell windows), so its side, and
  everything drawn (the lock surfaces and the stills, about 33 MB per 4K output), is measured only nested: NOT VERIFIED
  here. Expected nested: 157 + 45 = about 202 MB unlocked, about 268 MB locked on two 4K outputs. RSS misses what the
  cgroup charges (page cache, kernel memory, the surfaces' buffers), so the unit keeps the lock's former headroom,
  `MemoryHigh=1536M`, `MemoryMax=3G`, until the measurements exist (review round 1, MAJOR-2; the throttling above
  `MemoryHigh` could delay drawing the lock past the sleep delay). The integrator's measurement: `scripts/gates/rss.sh
  --nested` (it now counts the security process with the shell), unlocked, then locked, and the owner's `MemoryPeak` after
  a lock and an unlock; the numbers go into `docs/testing/gates.md` "P2 and the security process", and only then is
  `MemoryHigh` lowered (to at least twice the locked peak).
- **ADR-0040 step 4a's three items.** (1) the own reader of `shown`: done. (2) the stills against `MemoryHigh`: the
  arithmetic above, the nested measurement NOT VERIFIED. (3) the decode by the JPEG plugin only, from a file the process
  opened itself: deferred, not built: Qt offers no per-process switch for its image plugins short of replacing the plugin
  path (which the lock's platform plugins need), and a race between the check and the decode needs code running as the
  user, outside the threat model; the still is the cache file of Grassfield's own helper. Recorded as a residual risk.
- **Failure matrix (each case, and where it is tested).**

  | Case | What happens | Offline test | Nested proof (integrator, bare) |
  |---|---|---|---|
  | UI crash or restart, locked | nothing about the lock: the security process keeps its surfaces (no lockdead screen) and the keyboard; the restarted UI reads `locked` from the file at once | `lock_client.sh` (fresh read on start), `security_process_scan.py` (no lock in the UI) | `reload_locked.sh ui-crash` |
  | UI down, unlocked | idle locks, a sleep locks first, the lid and the lock key reach the security process | `sleep_lock_units.sh` (gate and stand-in keyed on the security unit), `lock_request_env.sh` | `reload_locked.sh ui-down-sleep`, `ui-down-idle` |
  | Security process stopped (start limit), unlocked | the UI reads locked but the lock is not confirmed: the lock key (5 s, then the stand-in), the lid (its fallback), a sleep (Omarchy's sleep lock), the Grassfield menu, Search and the lock corner (open while unconfirmed; `LockClient` hands the request to the stand-in) each start the unit, which locks; other surfaces stay refused | `lock_request_env.sh` (the key: fails, hangs, refused; no fallback in a dev session), `lock_client.sh` (`stopped`, `garbage`, a dead writer's file: not confirmed; mutants `confirmed-is-locked`, `confirmed-never`), `lock_surfaces.sh` (the unconfirmed paths open, every other surface refused), `tst_hotcorners.qml`, `tst_popupkinds.qml`, `sleep_lock_units.sh` | owner, real session (a unit at its start limit needs systemd; a dev session has no stand-in: `reload_locked.sh` cannot stop a unit) |
  | Upgrade from a build before S2 | the earlier, empty security process answers `security state` with `starting`: the stand-in restarts it before asking for the lock (the key, the lid, a sleep); the UI's 15 s restart; `post_upgrade` asks for one log-out | `sleep_lock_units.sh` (`starting` restarts, an S2 answer does not), `tests/shell/session_services.sh` (the note from any 1.0.0rc7 build only) | owner, real session |
  | Security process crash, locked | the compositor keeps the lock (lockdead screen, IQ-T5); Restart=always brings it back in about 1 s and it takes the lock back from the marker; the UI reads locked throughout (stale beat or the last `locked`) | `lock_client.sh` (`stopped`), `tst_lockstate.qml`, `lockstate_mutants.sh` | `reload_locked.sh l1 forged-crash graceful-exit foreign-restart` |
  | Security process crash, unlocked | no idle lock and no inhibitor until the restart; Omarchy's sleep lock is armed by `OnFailure=` and its stand-in starts the unit; the UI reads locked (stale) until the first new beat | `sleep_lock_units.sh`, `lock_client.sh` | owner, real session (DT-21 on the security process, L3) |
  | Both down | the compositor keeps any lock; the sleep lock and the stand-in start the security unit for a sleep or the lid; the UI's restart reads the file | the rows above | owner, real session |
  | A missed push | the next beat (2 s, and the UI's own read every 2 s) corrects it; meanwhile the compositor's signal reads locked once the lock is drawn | `tst_lockstate.qml` (`lost push`), `lock_client.sh` (`lost-push`, mutant `compositor-ignored`) | `reload_locked.sh ui-crash` (the restarted UI reads `locked`) |
  | A hung security process | no new beat: the UI reads locked within 5 s; a sleep waits for logind's window (known limit, as today) | `lock_client.sh` (`stopped`), mutant `same-beat-counts` | none |
  | A file that does not parse, or no runtime directory | locked | `tst_lockstate.qml`, `lock_client.sh` (`garbage`, `gone`) | none |
  | A UI started next to a dead writer's `unlocked` | locked: the first read is no beat, and no second write comes; not confirmed (the lock paths open) | `lock_client.sh` (`existing-dead-unlocked`), `tst_lockstate.qml`, mutant `first-read-is-a-beat` | none |
  | A restarted security process with a `locked` marker | its first publication is `locking`, after the marker is restored (never a first `unlocked`) | `dev_gate.sh` (the locked marker) | `reload_locked.sh forged-crash` |
- **Dev session.** `scripts/dev/shell-run.sh` starts the security process beside the UI with the same environment (record
  `.dev/security.pid`, log `.dev/security.log`) when it is not running, and leaves a running one alone, as systemd does;
  `--security` restarts it alone. `nested-down.sh` stops it; `tests/visual/ipc.sh` sends `lock`, `idle` and `security`
  there; `tests/security/pam_audit.sh` counts the security process's instance logs (where the PAM attempts now are) with
  the UI's; the nested scenarios target it (`reload_locked.sh`, `l2_wrong_password.sh`, `lock_privacy.sh`,
  `lock_keyboard_replaced.sh`, `nested_ready.sh`). `scripts/gates/rss.sh --nested` counts it.
- Tests: `tests/security/tst_lockstate.qml` (15 test functions: the refusal truth table, the confirmed lock, the published state
  for every machine state, the file's name, format and reader, the beat, the stale bound, the UI's calls and the lease),
  with 21 mutants (`lockstate_mutants.sh`); `lock_client.sh` (the real `LockClient` and `SessionState` offscreen: no state,
  first read, fresh, stopped, back, lost push, locking, garbage, restarted writer, displays off, gone, and two starts next
  to an existing file; 6 mutants of `LockClient.qml`);
  `security_process_scan.py` (from `security_unit.sh`); `security_unit.sh`, `root_check.py`, `sleep_lock_units.sh`,
  `lock_request_env.sh`, `lock_surfaces.sh`, `ipc_inventory.sh`, `tst_lockbackdrop.qml`, `theme_icon_files.sh`,
  `nested_ready_unit.sh`, `tests/shell/shell_unit.sh`, `lid.sh`, `tst_hotcorners.qml`, `contrast-roles.json` and the nested
  scripts above updated.
- Evidence (this container, 2026-11-08/09, after the machine's reboot): `just check-quick`'s recipes each exit 0 (qmllint 847
  files, 0 warnings; import-graph and run-mode ok once `qs.security.host` and the two variable reads were fixed);
  `scripts/dev/test.sh --layer data` 24 pass, 0 fail, 1 skip; `--layer logic`: see the report of the pull request (its
  first run failed `lid.sh`, fixed, and three timing tests under the parallel load, `capture.sh`, `gates.sh` P1 baseline and
  `hyprland_dialog.sh`, which pass alone); `tests/shell/shell_unit.sh` exit 0; the security QML units (`qmltestrunner` over
  tests/security: 341 cases after `tst_lockbackdrop` was updated), `dev_gate.sh`, `lock_client.sh` (control and 3 mutants),
  `lockstate_mutants.sh` (17), `lock_monitor_model.sh` (socket cases SKIP here), `theme_icon_files.sh`, `security_unit.sh`
  (78 PASS), `sleep_lock_units.sh` (95), `ipc_inventory.sh` (104).
- NOT VERIFIED (no compositor in this container): every nested proof of the matrix; the lock drawn by the security process
  (L1, L4 captures); the memory nested; the start time to "grassfield-security: ready" (P5); the real session (DT-01,
  DT-21 on both processes, L3, the lid, the notice through D-Bus, the 15 s restart after an upgrade).
- Residual risks: the decode hardening of 4a (3); the compositor signal is present only while the clipboard helper runs
  (history off: the UI relies on the push and the beat alone, up to 2 s after a missed push); an upgrade from a build
  before S2 runs the old and the new halves until both restart (the 15 s restart covers the security side; a UI still
  running pre-S2 code keeps its own lock until it restarts: log out to finish, as after any shell upgrade); the security
  process stopped at its start limit on a desktop without sleep needs a TTY (SQ-1 B's known limit).
- Review: opus security (R12), by the integrator.
- Review round 1 (2026-11-09, the integrator's opus security review of 77a0ceb3: FAIL, two majors, five minors, no way to
  unlock found), each fixed in its own commit on the branch:
  - MAJOR-1, a lock request refused while the security process is down: `LockState.uiLockConfirmed` and
    `SessionState.refusesConfirmed` (above); the lock key's fallback to the stand-in in `bindings.lua`; `LockClient`'s
    request bounded at 5 s a try. Refusing stays right for everything that is not a lock request.
  - MAJOR-2, memory: the lock's former headroom (above; `security_unit.sh` holds it at least at the UI unit's).
  - MINOR-1, an upgrade from before S2: the stand-in restarts a security process answering `starting`, which covers the
    lid, the key and a sleep; `post_upgrade` asks for one log-out when the old version is 1.0.0rc7 or earlier (every build
    before S2).
  - MINOR-2: `LockPublisher.start()`, called by `Lock` after the marker and the stranded-lock probe are read, makes the
    first publication explicit; the heartbeat runs only after it.
  - MINOR-3: the first read is no beat (`LockState.isNewBeat`).
  - MINOR-4: the spec names what a forged `unlocked` reaches before S3 (the polkit agent's device rule, the secret
    sheets' hold); it cannot be closed in the UI without trusting the same file, and S3 moves the polkit agent beside the
    lock, where it reads the lock in process.
  - MINOR-5: `lock_client.sh` checks `displaysOff`, `lockConfirmed` and two starts next to an existing file (6 mutants);
    `security_process_scan.py` refuses any write of the state file from the UI.
  - NITs: absolute tool paths in `LockWallpaper.qml` and `LockAvatar.qml`; `SecurityHost.qml` pinned.
  - Evidence (this container, 2026-11-09): the security QML units 342 pass; `lockstate_mutants.sh` 21 caught;
    `lock_client.sh` control, both existing-file starts and 6 mutants; `lock_surfaces.sh` 366 PASS, its runtime harness 57
    checks (and FAIL on `refusesConfirmed` made equal to `refuses`); `lock_request_env.sh` 29; `sleep_lock_units.sh` 99;
    `security_unit.sh` 85; `ipc_inventory.sh` 104; `dev_gate.sh`; `session_services.sh` 57; `shell_unit.sh`;
    `theme_icon_files.sh` 94 (2 SKIP: sockets, offscreen theme folders); `tst_hotcorners` 23, `tst_popupkinds` 12.
  - NOT VERIFIED: the unlocked start-limit path end to end (a unit at its start limit needs systemd: owner, real session:
    stop `grassfield-security.service` past its limit, then the lock key, the menu's Lock Screen, Search's Lock Screen and
    the lock corner each lock); nested, the integrator can check the UI side by killing the dev security process while
    unlocked (`.dev/security.pid`), waiting for "the session reads locked (state unlocked, stale)" in `.dev/shell.log`,
    then opening Search and the Grassfield menu (they open), choosing Lock Screen, and running `scripts/dev/shell-run.sh
    --security` within 10 s (`LockClient` retries): the session locks.
  - Residual: a hung (not crashed) security process while unlocked answers nothing and systemd does not restart it: the
    key's fallback and `LockClient` reach a stand-in that finds the unit active and waits; no lock until it recovers
    (before S2 a hung UI had the same property until step 6a's watchdog; the security process has no watchdog yet).
- The integrator's nested run of e1a3ff4c (2026-11-09, bare, a frozen checkout): `reload_locked.sh` 87 PASS, 1 FAIL
  (ui-crash: "the UI did not exit after SIGSEGV"); `ui-down-idle` 3/3; `lock_privacy.sh` 38/38; `lock_monitor_model.sh`
  18/18; `lock_keyboard_replaced.sh` 4 FAIL (the field not emptied by Escape after a replaced keyboard; nothing reached
  the probe window, the session stayed locked; held until the same test on main is known); `rss.sh --nested` exit 2.
  - ui-crash, cause: Quickshell's crash handler. Measured offscreen on Quickshell 0.3.2 (a scratch config, SIGSEGV 12 s
    after the start): the crashed process stays alive, blocked in its handler while a reporter it forked relaunches the
    shell as its own child ("Quickshell has been restarted"); SIGSEGV within 10 s of the start: "Not restarting", exit
    255. Without the handler (`QS_DISABLE_CRASH_HANDLER=1`, "Crash handling disabled."): the process ends on the signal
    (wait status 139). With the handler, systemd never saw a crash 10 s or more after a start: no restart of its own, no
    `OnFailure=` (the safe-mode counter, Omarchy's sleep lock), the crashed process kept its memory charged to the unit,
    and for the security process a frozen lock client stayed beside its relaunched copy. Decision (macOS: the process
    dies, launchd restarts it, ReportCrash writes the report): both units set `Environment=QS_DISABLE_CRASH_HANDLER=1`,
    and `scripts/dev/shell-run.sh` sets it for both processes, so a crash ends the process on the signal: a failure
    (unlike SIGTERM, which leaves the unit inactive with no `OnFailure=`), so systemd restarts it after `RestartSec=`,
    runs `OnFailure=` and counts it. No core file is kept (the opus delta review of 122f8d67, MAJOR): systemd-coredump
    stores a full core under /var/lib/systemd/coredump, readable by the user through an ACL, and the security process's
    memory may hold the typed password (also the administrator's on Omarchy), the UI's the polkit and secret-sheet
    passwords until S3/S4; a same-user process kept from reading the live memory by Yama could crash the process and read
    the core. Both units set `LimitCORE=0` and the dev launcher `ulimit -c 0`: systemd-coredump then records the crash
    in the journal (signal, PID, unit; `coredumpctl list` shows it without a file or a stack) and stores nothing.
    Nothing of Grassfield reads a core file: `grassfield-crash-watch` follows the journal entries (and gives no notice
    for these units), `grassfield-report` lists `coredumpctl list`, which shows these entries without a file, and the
    1a counter is `OnFailure=`. Quickshell's own report folder (`~/.cache/quickshell/crashes`) is no longer written.
    The limit is exactly 0, the hard one included (never `0:infinity`): with a hard limit above 0 a same-user process
    could raise the soft one with prlimit, crash the process and read the dump (the opus gate of 55bfea41); the tests pin
    the line. Consequence, a decision to revisit: the applications the shell starts (the Dock, Search, Launchpad, through
    `uwsm-app --`, whose scope runs in the shell's process tree) inherit the hard limit of 0. Their crashes still give a
    notice (`grassfield-crash-watch` reads the journal entry) but no core file, a terminal opened from the Dock and what
    it runs included: a privacy gain, and a loss for whoever debugs an application's crash. The alternative is to start
    the applications through the user manager (a transient service or scope created by systemd, outside the shell's tree),
    which gives them the user manager's limits. Tests: `security_unit.sh`, `tests/shell/shell_unit.sh`;
    `reload_locked.sh ui-crash` now passes the step "the UI ended on SIGSEGV" and names the handler if it comes back.
  - `rss.sh --nested` required a running menu bridge, which P2 does not count and a nested session without its build
    does not run: it is now listed when it runs and never required; `--real` finds both Quickshell processes by their
    units' MainPID (it still looked for `qs -n -c grassfield`, a command line gone since GF-115, and missed the security
    process).
- The integrator's nested run of 122f8d67 (2026-11-09, bare, no compositor plugin, load 8 to 15): `reload_locked.sh` 85
  PASS, 3 FAIL; `rss.sh --nested` unlocked 601 MB (PASS, 608), locked 665 MB (FAIL).
  - ui-crash still failed: the UI was alive 5 s after SIGSEGV, with `QS_DISABLE_CRASH_HANDLER=1` in its environment and
    its own Process children (inotifywait, gio monitor) listed. The record names qs itself (`setsid` execs it), and the
    children kept nothing alive: the kernel was writing the UI's core (hundreds of MB) to systemd-coredump, and a process
    ends only once its dump is written. With `ulimit -c 0` (f1b6a852) systemd-coredump stores nothing and the process
    ends at once. The step now checks the UI's core limit (0 0), waits out a dump that is under way (`CoreDumping:` in
    /proc, at most 65 s) and fails if there was one, and replaces the UI when it does not end, so that one failure no
    longer runs the remaining steps without a UI.
  - sleep-desync: the fresh lock after a foreign takeover was confirmed 5054 ms after "taking a fresh lock" in lock-desync
    and not within the 4 s sleep delay in sleep-desync (the e1a3ff4c run: 425 to 441 ms; `reload_locked.sh` now prints
    this time for both steps). Hyprland confirms a lock (`locked`, `WlSessionLock.secure`) once every lock surface has
    drawn a frame, and each surface created LockView at once, so its first frame waited for the view's creation and
    first render. Offscreen (the scratch probe `.dev/lvtime`, load 15): a lock surface with LockView drew its first frame
    after 653 ms cold and 49 to 73 ms warm; with the ground alone, 20 to 42 ms, LockView following at 613 ms cold and 31
    to 75 ms warm. The nested 5 s include what offscreen does not have (the window's graphics context, its effects'
    pipelines, the nested compositor under load), and the UI's core still being processed then (ui-crash above) may have
    loaded the machine: the cause is not isolated (NOT VERIFIED). Change: the surface draws its opaque ground first and
    LockView is incubated after it by an asynchronous Loader (`Lock.qml`), so Hyprland's confirmation waits for that
    frame only; nothing behind the lock shows meanwhile, a key typed before the view exists is dropped, the view takes
    the keyboard focus when it completes. The sleep delay already waits up to what logind allows: `IdleModel.sleepBudgetMs`
    reads `InhibitDelayMaxUSec` (Omarchy's 15 s window gives 12 s, the cap); 4 s is only the fallback when it cannot be
    read, which a dev session always is (no system bus): no change. Test: `tst_lockbackdrop.qml`
    (test_theConfirmationWaitsForTheGroundOnly). The nested time to a confirmed lock with this change: NOT VERIFIED
    (the integrator's next run).

### S3 as built (2026-11-09, branch feat/safe-mode-s3 from main 9c77a4f1; the polkit agent moves, and the secret sheets with it)
- **What moved, and why the secret sheets too.** The session's polkit agent (`AuthAgent`, its sheet `AuthDialog` and model)
  and the secret sheets fed by `grassfield-prompter` (`SecretAgent`: gcr's prompts, NetworkManager's secrets, KIO's
  passwords, Bluetooth pairing), with the one queue they share (`SheetQueue`), run in the security process. The sheets are
  not a choice of this step: ADR-0010's amendment of 2026-10-31 (owner decision Q12) puts every secret sheet and the polkit
  sheet in one queue, a QML object of one process, and ADR-0035 decision 9-7 says it in so many words ("when ADR-0041 S3
  moves the agent to `grassfield-security.service`, the sheets and `--peer-unit` move with it"); S2 as built had kept them in
  the UI "until S3". `grassfield-prompter.service` now accepts a peer of `grassfield-security.service` only (`--peer-unit`,
  and the bridge's default), so the UI's unit is refused. Nothing stayed: the UI (`shell/shell.qml`) imports no security
  module at all and names none of their types.
- **How they are hosted.** `shell/security/host/SheetHost.qml` (the queue, the two agents, the sheets' icon lookup and the
  two booleans the UI may know) is created at run time by `SecurityHost.qml`, at the end of its `Component.onCompleted`,
  never declared, as the lock's `LockStills` (S2): a sheet module that cannot be loaded or created leaves the lock, idle and
  the sleep inhibitor running. Measured offscreen (no window backend there): the root logs "the polkit agent and the secret
  sheets cannot be loaded (... No PanelWindow backend loaded); ... the lock is unaffected", then "grassfield-security:
  ready (hosting lock idle, ...)", and publishes its state; declared, the same failure took the whole root down ("Type AuthAgent unavailable", "Failed to load configuration"): no lock at all. Without
  the sheets no agent registers (polkitd answers "not authorized") and the bridge has no client (it releases its names:
  password prompts fall back to the stock prompters, as with no shell before, system-dialogs.md SC6): a failure denies an
  authorization, never approves one. `security state` answers `lock idle polkit secrets` once the sheets are made, `lock idle`
  otherwise. `SecurityHost.qml` is pinned by its new hash (`security_unit.sh`); `shell/security.qml` is unchanged.
- **What the sheets read (MINOR-4 closed for the lock and the displays).** `shell/security/SheetSession.qml`, a singleton of
  `qs.security` with `locked`, `displaysOff` and `saverShown`, written only by three Bindings of the host: `Lock.locked` (and
  the start-up stranded-lock probe while it runs, `Lock.strandedProbing`: review 1, LOW-4), `Idle.displayOff` and
  `Idle.saverShown`, all of the same process; it fails closed without them (locked, displays off; `tst_sheetsession`). The
  state file is never read there, so a forged `unlocked` reaches only the UI's own refusals now. The screen saver stays
  the UI's (ADR-0032); the security process cannot see it and reads nothing from the UI (S2's rule), so idle counts the
  same idle time by the saver's own rule and the same Wayland inhibitors, early and never late (review 1, MINOR-1: the
  first version could be late): without the applications' ScreenSaver inhibitors, which reach this process only as the
  UI's `idle inhibit` lease (a lost `idle inhibit 0` or a same-user caller kept it for 150 s while the UI's saver showed),
  and possibly shown from the process's start until the user is seen active (an input after a 1 s pause: Hyprland starts
  a new idle notification's timer from zero, so a process restarted while the user was away read "no saver" while the
  UI's saver was on screen). It differs from the saver on the holding side only (`IdleModel.sheetsSaverArmed`,
  `sheetsSaverShown`, `sheetsActivitySeen`; `tst_idlemodel` test_sheetsSaverRestartDuringIdle), and `saver devShow` is the
  UI's alone. Same-user code can still keep the displays on through the lease (they then are on), or restart this process
  (the saver then counts as shown until activity). While it counts as shown for the start alone, `SheetSession.starting`
  (a fourth Binding, from `Idle.starting`) makes a held sheet say the request arrived while Grassfield was starting, not
  that it waited for the screen saver (review 2, LOW; text only).
- **What the UI knows of the sheets.** Two booleans published with the lock state (`LockState.format`, absent from a file of
  a process before S3: read false; any other type: no state): `authorizing` (a sheet open, shown or held) and
  `securityKeyboard` (a sheet or its key sink may hold the keyboard). `LockClient.authorizing` and `securityKeyboard`
  (`LockState.uiSheet`) are the published value of a known, fresh state and true otherwise: `SessionState.authorizing` (the
  clipboard history, ADR-0034 Q11; the tiling popover) and `securityKeyboard` (the capture toolbar) follow them, so a
  stopped security process makes them wait, as it makes everything refuse. The menus close when a sheet is published open in
  a fresh state (`LockState.sheetPublished`), as the agent closed them in process before (`Popups.close()` was the agent's
  one UI call). The push is an inotify watch, milliseconds: a capture-toolbar hand-over in that moment could still map as
  Exclusive over a sheet that just appeared (residual, as narrow as the push).
- **The icon.** The UI's `ThemeIcons` (which copies icons found in the user's folders into a directory it empties at start)
  is the UI's: the sheets show the system theme's icon only (`SheetHost.themeIcon`, the name sanitized by
  `NotificationPrefs.safeIconName`, `Quickshell.hasThemeIcon` over the root-owned search paths `Grassfield.I18n` sets), never
  a copy of a user's icon; a requester whose icon lives only in the user's folders (a flatpak user export) shows the sheet's
  generic icon (`theme_icon_files.sh`: "polkit=none" in every case).
- **Exactly one agent.** One `PolkitAgent` in the tree, in `AuthAgent.qml`, the one file importing
  `Quickshell.Services.Polkit`; one `AuthAgent`, one `SecretAgent` and one `SheetQueue` in `SheetHost.qml`, which only
  `SecurityHost.qml` makes, once, by its URL; none of these types in the UI (`security_process_scan.py`, 53 planted mutants:
  a second agent, a prompter client, a queue or a raw `PolkitAgent` in the UI, a second agent or queue in the sheets, the
  sheets declared or made twice, `SheetSession` bound to anything else, elsewhere or assigned, the sheets reading
  `SessionState` or `LockClient` or importing `qs.services`, ...). polkitd itself refuses a second registration for the
  session. Nested, no agent registers (the owner's agent holds the session, as before S3); the real session's count is L5
  step 1 (`journalctl --user -u grassfield-security`). The `PolkitAgent` sits in a Loader, made again while refused (review
  2, MAJOR-1): Quickshell keeps one agent per process, so a second one made while the first lives never registers.
- **The restart.** While the security process restarts no agent is registered: polkitd answers an authorization asked
  then "not authorized" (no agent), and ends one that was open with the agent's bus name (not authorized or dismissed),
  never approved, as while the UI restarted before S3. On a crash the agent answers nothing (no password goes out,
  `authagent_flows.d` test_35, which shows the QML side only: the agent destroyed with a password half typed sends nothing,
  the agent made again has no request, no sheet and no keys); on a graceful stop Quickshell itself cancels the open request
  before it unregisters (upstream `cancelAllRequests`: dismissed). The polkit module keeps nothing across a restart (no
  file, process, socket or setting: `security_unit.sh`). The secret sheets: the bridge sees its client go and answers its open requests "cancelled"
  (`SecretAgent.dropAll`'s premise), owns gcr's prompter name only while a client is connected (so a gcr prompt in that
  second goes to the stock prompter, as while the UI restarted before S3), and accepts the restarted process's connection
  (its client retries after 1 s). Owner, real session: L5 step 6 (`docs/specs/security.md`).
- **The invariant table** (step 1, row S3) holds as written: the security process locks; with the UI down the sheets keep
  working (their window is the security process's), with the security process down there is no polkit agent and no secret
  sheet until its restart, and sleep is as S2.
- **Units and dev session.** `grassfield-security.service` keeps no `NoNewPrivileges` (polkit-agent-helper-1 is setuid),
  `LimitCORE=0` now also covers the sheets' passwords; the UI's unit keeps no `NoNewPrivileges` because the applications it
  starts inherit it. `scripts/dev/shell-run.sh` restarts the dev security process when `GRASSFIELD_PROMPTER_SOCKET` changes;
  `tests/visual/ipc.sh` sends `polkit` and `secrets` to it. That dev plumbing value, which the UI read with
  `Mode.devValue("PROMPTER_SOCKET")`, is read by `SheetHost.qml` behind its own `RunMode.dev` gate (the security modules
  cannot ask `Mode`): `tests/ci/run_mode.py` allows that one name in that one file (ADR-0019's amendment of 2026-11-09).
- Tests: `authagent_flows.sh` and `secret_sheets.sh` run the agents with `qs.security` and `qs.lib` only (no `qs.services`:
  the security process's world), `SheetSession` set as the host would; `authagent_flows.d` test_35 (the restart);
  `tst_lockstate.qml` (the sheets' fields, `uiSheet`, `sheetPublished`) with 8 more mutants in `lockstate_mutants.sh`;
  `lock_client.sh` (fresh, missing, stale and a dead writer's sheet; 3 more mutants); `tst_idlemodel.qml` (the saver's rule);
  `security_process_scan.py` (53 mutants); `lock_surfaces.sh` (the agent's inputs, the host's Bindings, the published
  keyboard; mutations); `theme_icon_files.sh` (the sheets' icon); `security_unit.sh`, `sleep_lock_units.sh` (an S3 answer
  restarts nothing), `session_services.sh` (the peer unit), `secret_bridge.sh` (the probe sets `SheetSession` as the host);
  nested, `sheets_process.sh` (the `polkit` and `secrets` targets answer on the security instance and not on the UI's, one
  registration attempt per start of the security process, a restart of it leaves the UI alone and attempts once more).
- NOT VERIFIED here: the agent's registration and L5 in a real session (a nested session cannot register an agent: the
  owner's holds the session), the restart's polkitd answers (L5 step 6), the sheets drawn by the security process nested
  (`just shot secret-sheet` and a polkit sheet need the owner's L5 or the dev prompter run of docs/specs/system-dialogs.md
  A-SC7), the security process's memory with the sheets loaded (gate P2).
- Residual risks: the capture toolbar's hand-over in the push's milliseconds (above); a user-folder icon no longer shown on
  a sheet (display only); the saver count's holding-side differences (above); a Quickshell without its polkit service now
  leaves the session without an agent but locked and lockable, where before S2 it took the whole shell down.
- Review: opus security (R12), by the integrator.
- Review round 1 (2026-11-09, the opus security review of 1223adc2: PASS, three MINOR, one LOW, NITs), each fixed on the
  branch:
  - MINOR-1, the sheets' saver input could be late (a restart during idle; the lease): early and never late now (above).
  - MINOR-2, the one-agent scan missed code built from strings: `security_process_scan.py` reads `ui/` too and refuses, in
    the UI tree and Grassfield.Ui, `Qt.createQmlObject`, a Loader/LazyLoader source or a `createComponent` that is not one
    plain string literal (the desktop widgets' `Registry.source(root.widgetId)` alone, while `Registry.source` returns only
    `Qt.resolvedUrl("builtin/....qml")` literals), and any string naming `security/`, `qs.security`,
    Quickshell.Services.Polkit or a security type. The reviewer's M1 and M2 are among the 68 planted mutants.
  - MINOR-3, the agent never asked again: the fix of this round set a new object path while not registered, after 3 s
    doubling to 60 s, never in a dev session (the nested agent must not take the owner's session when the owner's agent
    restarts). That did not ask again: Quickshell 0.3.2's `PolkitAgent` sets its path once and refuses a later one with a
    warning (the delta review's MAJOR-1, below), and its tests passed only because the harness's agent took any path. The
    upgrade note's restart line restarts the UI alone first, then the bridge and the security process
    (`session_services.sh`).
  - LOW-4: the sheets count the start-up probe of a stranded or foreign lock as locked, at most its 20 ticks
    (`Lock.strandedProbing`; the scan's binding table, `lock_surfaces.sh` and its mutations, `security_unit.sh`).
  - NITs: SheetSession's fail-closed defaults tested (`tst_sheetsession.qml`, and the scan with the reviewer's M3); the
    scan's mutant count; the bridge's built-in `--peer-unit` default tested (`prompter_bridge.sh`, a bridge without the
    argument refuses a peer outside grassfield-security.service); `secret_bridge.sh` and `prompter_bridge.sh` exit
    ENVIRONMENT (2) when `/tmp` cannot hold their short socket directory; the restart's wording (above).
  - Residual, not new since S2: a restarted process starts with `displayOff` false while the displays may be dark (the
    saver's hold above covers the sheets until the user is active).
- Review round 2 (2026-11-10, the opus delta review of 655916ba: FAIL on one MAJOR; MINOR-1, MINOR-2, LOW-4, the NITs and
  b84d46e7 passed), each fixed on the branch:
  - MAJOR-1, the retry never registered again: Quickshell's `PolkitAgent::setPath` sets an empty path only ("cannot change
    path after it has been set.", upstream `src/services/polkit/qml.cpp`), and an agent asks polkitd once, when it is made
    (`componentComplete`). `AuthAgent` now holds its `PolkitAgent` in a Loader; while not registered it lets the agent go
    and makes the next one an event-loop turn later (a 0 ms Timer), 3 s doubling to 60 s (`registrationRetryInterval`),
    never in a dev session, never while registered or with a request open. The turn matters: the Loader deletes the old
    agent later, and one made in the same turn finds Quickshell's one agent per process (`PolkitAgentImpl::instance`)
    still held, so it stays inert (measured on 0.3.2.r7: every second try asked nothing). One Loader and Quickshell's
    single instance mean two agents never live at once. Tests: the harness's agent now follows Quickshell (asks only when
    made, its path set once, inert while an earlier one lives: `make_harness.py`); `authagent_flows.d` test_36 to test_39
    (asked again with each wait at least doubled, none made inert, the registered one kept, a dev session asks once, a
    registered agent or an open request never let go, the backoff's values) and ten mutants, the retry of 655916ba by a
    new path and the next agent made in the same turn among them; and on the real Quickshell, offscreen,
    `authagent_registration.sh`: with the system bus pointing nowhere, Quickshell's own "failed to register listener on
    path" lines are one per agent made (6 in 4.5 s at a 100 ms base, 100, 200, 402, 803, 1600 ms apart), none in a dev
    session but the first; `--mutants` catches the 655916ba retry, the same-turn agent and no backoff. Its third phase
    (a private bus with `tests/fixtures/fake-polkit-authority.py` refusing three times: the fourth agent registers, and
    nothing registers or unregisters after it until the end) needs Unix sockets and SKIPs in a sandbox that refuses them:
    NOT VERIFIED on the branch until it is run outside one.
  - LOW (from MINOR-1): a request held only because the security process had just started said "waited while the screen
    saver was on". `Idle.starting` (`IdleModel.sheetsStarting`: not seen active, the saver not counted) is bound into
    `SheetSession.starting` by a fourth Binding of the host; the sheets then say "This request arrived at %1, while
    Grassfield was starting." (en, fr). Text only: what holds a request is still `saverShown`. Tests: `tst_idlemodel`,
    `tst_authdialogmodel`, `tst_secretsheetmodel`, `authagent_flows.d` test_40, `secret_sheets.d` test_11b,
    `tst_sheetsession`, the scan's binding table.
  - NIT, the scan: a Loader or `createComponent` source may be `Qt.resolvedUrl` of one plain literal (the literal is still
    read), and an http or https address in a string names no file of the tree (file: and qrc: addresses are still read);
    five allowed cases planted in the selftest pass, four more mutants (a resolved agent file, a resolved computed file, a
    resolved property, a file: address) and M1, M2 are found.
  - Residual risks, Quickshell's: (1) its registration is asynchronous (the session subject in a thread, then a
    synchronous D-Bus call), and an agent destroyed before that completes leaves the listener calling into a freed object
    (upstream `listener.cpp` keeps `cb`); the retry lets an agent go only a full wait (3 s or more) after making it, while
    the attempt completes in milliseconds (1 to 3 ms here), so only a main loop or thread pool stalled for that long
    could reach it, and the outcome is a crash of the security process (Restart=always; no agent meanwhile, nothing
    approved). (2) That D-Bus call blocks the security process's main thread up to D-Bus's 25 s timeout when polkitd hangs,
    the lock's prompt included; S3 moved the one start-time attempt into this process, and the retry repeats it at most
    once a minute while unregistered (bounded since round 3, below). Upstream fixes to propose: clear the listener's `cb`
    in `~PolkitAgentImpl`, and register asynchronously.
- Review round 3 (2026-11-10, the opus review of 655916ba..c34b4497, the integrator's "round 2": MAJOR-1 confirmed fixed on
  the real Quickshell, every phase of `authagent_registration.sh` included; residuals (1) above and the polkitd restart
  accepted; FAIL on one required MINOR):
  - MINOR-A, the retry could stop the security process while the session was locked, without bound. Quickshell registers
    with a synchronous `polkit_agent_listener_register` on the main thread, so with polkitd hung each attempt blocks for up
    to D-Bus's 25 s. While locked, the lock's surfaces then handle no input for that long, and a long block can overflow
    the Wayland connection's buffer ("lock client died", then a restart). While unlocked, a sleep asked during a block
    waits out logind's delay (InhibitDelayMaxSec; Omarchy skips its own lock before sleep while grassfield-security runs),
    so the computer could go to sleep without the lock and wake on the desktop until the block ended; the idle lock is
    late the same way. The tries are now bounded (`AuthAgent.qml`): none while the session is locked (`SheetSession.locked`:
    the lock's own state and the start-up stranded-lock probe), the displays are off, or a sleep is under way
    (`SheetSession.sleeping`, a fifth Binding of the host from `Idle.sleeping`, PrepareForSleep(true) until the resume);
    a try due then is dropped, and so is an agent due in that turn; at most `registrationTriesMax` (4: 3, 6, 12 and 24 s)
    per unlock period; and none for the rest of the period once an attempt coincided with a stall of the event loop: a
    200 ms beat on a monotonic clock (Quickshell's `ElapsedTimer`; no wall clock in shell/security) watches each attempt
    for 3 s, and a beat later than 1 s stops the tries until the next unlock, logged once. An unlock starts a new period.
    What remains: the one attempt at each start of the security process is made whatever the session's state (S3's
    accepted residual: a hung polkitd then stops this process once, up to 25 s, possibly behind the lock), and at most one
    blocked try per unlock period, while unlocked with the displays on.
  - Upstream proposals (Quickshell): register asynchronously (`polkit_agent_listener_register_with_options` is
    synchronous; its D-Bus call can run in a thread or through the asynchronous GDBus call), and clear the listener's `cb`
    in `~PolkitAgentImpl` (residual (1)). Follow-up of our own: watch `org.freedesktop.PolicyKit1`'s owner and make the
    agent again when polkitd restarts (an agent registered with the previous polkitd believes it still is: the accepted
    polkitd-restart residual, which fails closed).
  - Tests: `authagent_flows.d` test_41 (no try while locked, the displays off or a sleep under way, and again once that
    ends), test_42 (a try due as the session locks is dropped; the next unlock makes it), test_43 (four tries per unlock
    period), test_44 (an attempt that stops the event loop for 1.5 s stops the tries until the next unlock; the harness's
    agent can stand still like Quickshell's call, `mockBlockMs`), test_45 (each attempt is watched, not only the start's),
    21 registration mutants in all; on the real Quickshell,
    `authagent_registration.sh`: "nowhere" now shows the cap (exactly 4 tries in 4.5 s, attempts 101, 201, 402 and 800 ms apart),
    "locked" (the start's attempt alone), "relock" (4 tries, none while locked, 4 more after the unlock), and on the
    private bus "stall" (the fake authority answers the second registration 2 s late: two registrations, the stall
    logged, then none); `--mutants` adds no cap, tries while locked and a stall ignored. The private-bus phases need Unix
    sockets: NOT VERIFIED in the author's sandbox, run bare by the integrator.
  - NIT: a web address (http, https, any case) is refused as a Loader or `createComponent` source, `Qt.resolvedUrl` of
    one included; the exception stays for plain strings (two more mutants, the reviewer's
    `https://example.invalid/security/polkit/AuthAgent.qml` among them).
- Review round 4 (2026-11-11, the opus review of 64847439: PASS, one MINOR and three NITs, fixed before the merge):
  - MINOR-1, the re-arm ran at any fall of `SheetSession.locked`, which also covers the start-up probe of a stranded lock
    (`Lock.locked || Lock.strandedProbing`; Lock starts the probe before the host makes the sheets). When the probe ended
    "unlocked", a stalled start attempt was forgotten and a second blocking try followed about 3 s later (the reviewer's
    qmltestrunner run: "stopped … 1706 ms", then `stalled=false periodTries=0`, then a second registration). Now only a
    real unlock re-arms: the agent counts an unlock only after it saw the session lock while it ran (`sawLock`), so the
    probe's end, which it never saw begin, is none. No sixth host Binding. A session already locked when the agent is made
    is not re-armed at its first unlock either (the tries stay as they were: never more). `authagent_flows.d` test_46 (the
    probe case) and two more mutants (a re-arm at any fall of `locked`, a lock never seen).
  - NIT-1, the scan: strings are read decoded (JavaScript escapes: `"\x68ttps://…"`, `"https://…"`,
    `"secu\x72ity/…"`), and in every file of shell/ and ui/, the security tree included, no import (`import "…"`,
    `.import "…"`) and no literal Loader or `createComponent` source may be anything but a file of this tree: no address
    with a scheme (http, https, data, file, qrc, ...), no absolute path (`/tmp/x.qml`), no relative path out of shell/ and
    ui/. Checked first: the tree uses none; shell/security makes SheetHost.qml and LockStills.qml by `Qt.resolvedUrl` of a
    relative literal. Eleven more mutants, and an allowed case (a UI file spelled with escapes).
  - NIT-2: `authagent_registration.sh` "stall-start": the fake authority answers the START's own registration 2 s late:
    one registration, the stall logged, no try (the reviewer saw it detected at 2017 ms with 0 tries). A private-bus phase:
    run bare by the integrator.
  - NIT-3: the beat Timer's id is `stallBeatTimer` (the function keeps `stallBeat`).

### S4 as built (2026-11-11, branch feat/safe-mode-s4 from main af7ec1a8; safe mode, last; the rc7 audit's R7-REL-03)
- **The gap it closes.** After 1a's stop (three failures of the UI within 10 minutes) the user had no menu bar, Dock,
  notification server or way back but a sleep, the lid or a TTY. S2 and S3 had already moved the lock, idle, the sleep
  inhibitor, the polkit agent and the secret sheets into the security process, so those kept working; what was missing
  was the user-facing part, which this step adds there: a notice with one way forward and one way out.
- **What the user sees** (`shell/security/safemode/`). One small alert, centred by the compositor on the output it maps it on
  (a layer surface with no anchor and no output: the one with the focus), the size of the alert and its shadow, nothing full
  screen and no dim: the caution symbol, "Grassfield is running in safe mode", "The desktop stopped working several times
  in a row and was turned off. Your open apps keep running.", and two capsules, Log Out and Try Again (the default),
  stacked with Try Again on top when the French labels do not fit side by side. Drawn with `Grassfield.Ui` and its tokens
  only, in the shape of the UI's alerts (`shell/overlay/Dialog.qml`: radius.alert, the 64 frame, panel.alertWidth); every
  text fixed and plain (`SafeModeCard.qml`). Return and Enter are Try Again, the default button, wherever the keyboard is;
  Tab and Shift+Tab move the keyboard between the two buttons (a focus ring once Tab was used) and Space presses that one;
  Esc does nothing (no Cancel: closing it would leave no desktop and no way back, and it never logs out); a key held down
  answers nothing, whatever it is (the buttons take no focus, the alert handles every key: review round 2). The keyboard
  starts on Try Again and comes back to it after an action that did not finish. Accessible as a dialog named by its title, described by its message.
  While an action runs both buttons are disabled and a line says "Restarting the desktop…" or "Logging out…"; one that did
  not finish says so ("The desktop couldn’t be restarted. Try again, or log out.", or that some apps are still open). The
  window is on the overlay layer (a full-screen window cannot hide it) and takes the keyboard on demand, as an app's
  alert: the user can click a window to save their work, and click the alert again. English and French in the catalog.
- **When it shows** (`SafeMode.qml`, the pure rules in `SafeModeModel.js`). The security process looks at the UI's unit
  every 5 s (every 2 s while a stop is seen or the notice is up): one short process with a fixed command, bounded at 5 s,
  that tests the loop detector's flag `$XDG_RUNTIME_DIR/grassfield/shell-safe-mode` as a plain file that is not a link
  (never read: the flag is a flag) and prints `systemctl --user show` of `ActiveState`, `SubState` and `Result` of
  `grassfield-shell.service`. Safe mode is the flag with the unit down for good (`inactive` or `failed`, never
  `activating`, which covers the auto-restart wait), or the unit `failed` with `Result=start-limit-hit` with or without the
  flag (ADR-0056 D-10: the counter can miss the last failures of a sub-second loop). A stale flag with the shell brought back
  shows nothing (the opus review of b1d826b), nor does a flag in a linked runtime directory (review round 1, MINOR-3); two
  looks in a row must agree, so a flag left from an earlier loop, read at a
  login before the autostart starts the shell, or a unit passing through `failed` on its way to a restart, shows nothing.
  An answer that cannot be read (a missing line, a token outside systemd's form, CRLF, more than 4 KiB, a look killed at its
  5 s bound) counts for nothing: it never shows the notice on a guess and never hides one already up (logged once).
- **The lock always wins.** The notice exists only while the session is unlocked and no polkit or secret sheet of this
  process is up: its window is made by a LazyLoader active only then (`SafeModeModel.shown`: an exact `false` for both), and
  destroyed the moment either changes. The host (`SecurityHost.qml`, pinned anew) binds the two inputs from this process
  alone: locked is `Lock.locked || Lock.strandedProbing || Lock.publicState !== "unlocked"` (a lock asked for, `locking`,
  already counts, so the notice is gone before the compositor draws the lock; the start-up probe of a stranded or foreign
  lock counts too), a sheet up is the sheets' `authorizing || securityKeyboard` (open, shown or held, or the key sink); both
  read true until bound. Nothing is drawn under the lock (the plan said "under the lock surface": nothing there can take a
  key or show, and the notice comes back at the unlock), nothing takes a key meant for a sheet. Try Again and Log Out refuse
  first unless the notice is on screen and no action runs (`SafeModeModel.canAct`), whatever asks: a button, Return, the
  dev hook. Nothing here locks, unlocks, approves, delays a lock or reads the UI's state file.
- **What the actions run** (fixed commands, as the user, nothing read from a file):
  - Try Again: `timeout -k 2 40 /usr/lib/grassfield/grassfield-shell-failed --try-again`, the loop detector's own helper,
    which gains this verb (never the unit's: its `ExecStart=` has no argument; an unknown argument does nothing, exit 2). The
    flag stays until the shell is confirmed running (review round 1, MINOR-1): it is written when missing (a unit at its start
    limit with no flag), its identity (inode) noted, the ledger cleared (the next loop is counted from zero); then `systemctl
    --user reset-failed grassfield-shell.service` bounded at 5 s (a unit at its start limit refuses a start until then),
    `systemctl --user start grassfield-shell.service` bounded at 20 s (Type=simple: it returns once the shell runs, or fails),
    `systemctl --user is-active grassfield-shell.service` bounded at 5 s; only then is the flag removed, and only if it is still
    the one noted (a flag a new loop wrote meanwhile stays). The steps fit inside the caller's 40 s, every command by absolute
    path; a run killed at any point, a start that fails or a unit not active after it leaves the flag, so the notice stays (with
    its failure line) or comes back. No usable runtime directory (unset, or a link): nothing is done. It never loops: nothing
    restarts the shell on its own; a shell that fails again is the counter's to stop again (three failures, its stop, a new
    flag), and the notice comes back. After a start that worked the notice leaves (the next looks see the flag gone).
  - Log Out: `timeout -k 5 330 /usr/lib/grassfield/grassfield-session-end logout`, the Grassfield menu's own path (every app
    asked to close, none forced; `uwsm stop`). An app that keeps a window open stops it after its 15 s (its exit 3), and the
    notice says so; any other failure (its own, its bound, a process that could not start) says the session could not be
    ended (review round 1, NIT; `SafeModeModel.failureOf`).
- **Deviations from the plan's text** (step 1 S4 and SD-4, written before later owner decisions; taken under the owner's rule
  and the integrator's brief of 2026-11-11, to be confirmed by the reviewer and the owner): (1) one centred alert instead of a
  bar with the Grassfield menu: macOS's "a problem occurred" alerts, and a bar would rebuild a piece of the menu bar in the
  security process; (2) two actions, Try Again and Log Out, where SD-4 listed Restart and Shut Down too: the login screen
  offers both after Log Out, and the power button stays logind's; (3) the caution symbol, not the Grassfield mark: the owner's
  IQ-B1 B (ADR-0040) came after SD-4, dialogs show their subject's symbol (`tests/ci/mark_places.py`); (4) nothing under the
  lock (above). The owner accepted the centred alert on 2026-11-11 and asked for the light appearance before the merge
  (below).
- **Light and dark** (the owner's follow-up of 2026-11-11). Nothing bound the security process's `Appearance.dark`, which
  defaults to true, so since S3 the polkit sheet and the secret sheets drew dark whatever the user chose (in the UI, before S3,
  they followed `Settings.dark`), and the first version of the alert did the same. The host now binds `Appearance.dark` to
  `Settings.dark`, as the UI's root does (`appearance`, "auto" by the local schedule): the alert and both sheets draw from
  the current palette and the glass tint of their appearance, tokens only; gate A2's token calculation asserts their roles
  in both appearances (`tests/visual/contrast-roles.json`, `colors.*` foregrounds). The lock does not follow it: LockView
  draws from `Appearance.darkColors`, gives its password field every colour and no focus ring, and nothing else of the lock
  or idle reads the current palette (`security_unit.sh` holds the binding and these lines), so the lock screen stays the
  dark one of both appearances, as on macOS.
- **Dev session.** The security process of a dev session never asks systemd (it would read the owner's own unit) or reads
  the owner's flag, and runs neither action (each logs "dev session, suppressed ..."). Its looks are faked by the dev hook
  `safemode devSet` (`SafeModeModel.devLook`, read through the same parser and settle), `safemode devPress tryAgain|logOut`
  presses a button through the same refusals, `safemode status` returns what the notice decides from (JSON, no private
  state). The three are refused outside a dev session; no safe-mode function answers IPC in a real session, Try Again and
  Log Out are the notice's buttons only (`docs/specs/security.md` IPC surface; `tests/visual/ipc.sh` sends `safemode` to the
  security instance).
- **Memory and start (gate P2, P5).** Nothing of the notice exists outside safe mode: the controller is a Timer, three
  Process objects that run only when asked, a LazyLoader and an IpcHandler; the window and its alert are made only while the
  notice is on screen and destroyed with it. Not measured (no compositor for the window here; the security root's
  offscreen proxy would run the real inhibitor outside a dev session on this machine): NOT VERIFIED, the integrator's
  `scripts/gates/rss.sh --nested` with the notice shown and not.
- **Tests.** `tests/security/tst_safemode.qml` (the parser, the flag present or absent with every unit state, the settle,
  the lock and sheet truth table with non-boolean inputs, `canAct`, the intervals, the dev looks; the alert offscreen: its
  accessible name, role and buttons, Return and Enter as Try Again, Esc never logging out, the clicks, the busy and failure
  lines, the focus back on Try Again, plain text, the caution symbol; light and dark: every colour from the current palette,
  the glass tint included); `tests/security/safe_mode.sh` (the real controller
  under Quickshell offscreen in a dev session, a stand-in window, the probe binding the lock and the sheets as the host:
  26 checks, and six mutants each caught: shows over the lock, Try Again while locked, Log Out while locked, shows over a
  sheet, not lazy, one look confirms); `security_process_scan.py` (rule 6: one SafeMode in the host bound exactly from its
  lock and sheets, true until bound, no SafeMode or safe-mode import in the UI, no `qs.services` type in safemode/; 13 more
  mutants, 100 in all); `security_unit.sh` (the host and the controller pinned by SHA-256, the lazy notice, the first-statement
  refusals, the three fixed commands and nothing else that starts a process, reads or writes a file or opens a socket, the
  dev gate, the dev-only IPC target, the small Overlay window with the keyboard on demand and no anchor);
  `lock_surfaces.sh` (the notice's rules read from the sources, 12 mutants: shows over the lock in three ways, over a sheet,
  acts off screen, Try Again and Log Out refusals removed or weakened, the notice's button running the helper directly,
  the host's bindings weakened, an exclusive keyboard); `tests/shell/shell_failures.sh` (`--try-again`: the order, the
  reset, the start, the flag back on a failed start, no runtime directory, a linked one, an unknown argument, the
  counter's own path still without start or reset, the unit without argument; two mutants: the flag removed after the
  start, the flag not put back); `tests/security/safe_mode_nested.sh` (nested, bare: below). Inventory 784.
- **Evidence** (this machine, 2026-11-11, the branch's head; GRASSFIELD_SESSION and QT_QPA_PLATFORMTHEME unset in every
  command). `just check-quick` exit 0 (qmllint 858 files, 0 warnings; i18n 4477 messages, 0 unfinished; inventory 784;
  check-contrast 57 tests OK, the alert's text roles registered; check-migrate ok; gitleaks no leaks). The security QML suite
  as `scripts/dev/test.sh` runs it (`qmltestrunner -import ui -import <qs root> -input tests/security`): 373 passed, 0
  failed, gate Q2 clean; `tst_safemode.qml` alone 18. `safe_mode.sh` exit 0 (26 checks; six mutants caught).
  `security_unit.sh` 188 PASS (the scan's selftest, 100 mutants, among them); `lock_surfaces.sh` 396 PASS;
  `ipc_inventory.sh` 104 PASS (177 functions of 38 targets, all documented); `session_services.sh` 58;
  `tests/shell/shell_failures.sh` 48; `sleep_lock_units.sh` 100. Nested, bare, one slot of the integrator's rule (load 2
  to 4): `safe_mode_nested.sh` 27 PASS on a fresh `nested-up` and 27 on a fresh `nested-up --lang fr`; the captures
  `.dev/shots/safe-mode-en.png` and `safe-mode-fr.png` (GF-REF; the French buttons stacked, Réessayer on top) were looked at
  by the author only (F1 not signed off). The first nested run failed one check (the surface still listed 5 s after Try
  Again): the notice had mapped on the nested window's output, which was not drawing (its capture waited too), so the
  surface's fade-out never ended; the test now focuses GF-REF first, and the same check passed in both runs after it.
- **NOT VERIFIED.** The real session (the owner's L2): three `kill -SEGV` of the UI within ten minutes, unlocked, then the
  notice within seconds; locked, the notice only after the unlock, the password unlocking at the first attempt; Try Again
  bringing the desktop back (`grassfield-shell-failed --try-again` against systemd 261: reset-failed, the start, the flag
  gone); Log Out; the parse of systemd 261's `show` output; Hyprland 0.56 giving the on-demand alert the keyboard when it
  maps; the alert at the owner's 1.25 scale and its captures (en, fr; visual NOT verified); gate P2 with the notice.
- **Residual risks.** (1) Same-user code can create or remove the flag, as it can call any IPC target: a flag created while
  the shell is stopped by hand shows the notice (whose actions the user chooses), a flag removed while the unit is stopped
  hides it unless the unit is at its start limit (the user is where 1a left them: the lid, a sleep or a TTY). (2) A stale
  flag with the shell stopped on purpose (`systemctl --user stop`) shows the notice; Try Again then starts it. (3) Log Out
  while an app keeps a window open cannot offer "Log Out Anyway": grassfield-session-end asks through the notification
  server, which is the UI's and is down; the logout stops after 15 s, the notice says to save and quit the apps, then log
  out (macOS offers the forced logout there). (4) One short process every 5 s in the security process for the session's
  life (`timeout`, `sh`, `systemctl show`): small, not measured (gate P1 counts the UI only). (5) The alert sits at the
  output's exact centre (a layer surface the compositor centres), not at panel.dialogRaise above it. (6) The polkit and secret
  sheets change with the appearance too (above): what S3 had lost. (7) Try Again restarts the same desktop (SQ-1 B: safe mode is the UI stopped, not a reduced UI); a second loop comes
  back here. (8) Should Hyprland not give the on-demand alert the keyboard at map, Return and Esc need a click on it first.
- **Review:** opus security (R12), by the integrator.
- **Review round 1** (2026-11-11, the opus security review of a0df9c3e: PASS, no BLOCKER or MAJOR; three MINOR and four NITs,
  fixed on the branch with the light appearance above, for a delta review):
  - MINOR-1, Try Again could leave the flag gone with the shell down: it removed the flag first and its reset had no bound, so
    a run killed by the caller's 40 s (a slow user manager, the security unit restarting) left neither the shell nor the
    flag, and the notice went (the reviewer reproduced it with stubs: exit 124 after 40 s, the flag gone). Now as above: the
    flag kept until the unit is active, every step bounded. `tests/shell/shell_failures.sh`: killed in the reset and in the
    start (the flag stays), a reset that hangs (its own bound, the start goes on), a failed start and a unit not active (the
    same flag stays), no flag (one is written, and removed only after a confirmed start), a new loop's flag (kept); mutants:
    the flag removed first, no active check, no identity check (57 PASS). The scratch copies run a stub systemctl and refuse
    to run if a real one is left.
  - MINOR-2, the displays off: with a non-default "require password after display off", idle turns the displays off while
    the session stays unlocked, and the alert kept the keyboard, so the wake key (Space, Return) could press Try Again or
    Log Out. As the sheets: the alert exists only while the displays are on (the host binds `displaysOff: idle.displayOff`,
    true until bound), and whenever it appears (the unlock, a sheet closing, the displays waking) nothing it is given acts
    for `SafeModeModel.GUARD_MS` (500 ms, the sheets' `heldGuardMs`): `armed` falls at every appearance and only the guard
    Timer sets it. `tst_safemode.qml`, `safe_mode.sh` (the displays off, the wake key's press refused, a press after the
    guard acts; mutants `shows-with-the-displays-off`, `no-guard`), the scan, `lock_surfaces.sh`, `security_unit.sh`.
  - MINOR-3, no test ran the real-session paths: `safe_mode.sh` now runs the look's own shell script, taken from
    SafeMode.qml, against a stub systemctl (a plain file counts; a FIFO, a directory, a link, a dangling link, an empty path,
    a missing file and a file in a linked directory do not), and the controller outside a dev session with its three commands
    pointed at stubs in a copy (`safe_mode.d/probe_real.qml`): the looks, Try Again failing, hanging past the action guard
    (shortened in the copy; the late end then changes nothing) and working, Log Out with apps open and with the session not
    ended. The reviewer's finding that a flag in a linked runtime directory showed the alert while `--try-again` refused it:
    the look now refuses a linked directory too, as the counter and `--try-again` do.
  - NITs: the alert's comment on held keys corrected (a focused button takes its own repeats; the controller refuses all
    but the first); `qs.security.safemode` may be imported by the host only (`security_process_scan.py`, a mutant: idle
    importing it); `grassfield-shell-failed` names systemctl and timeout by absolute path; the Log Out failure text split by
    exit code (above).
- **Review round 2** (2026-11-12, the delta opus review of b67472da: PASS; one MINOR and three NITs, fixed on the branch):
  - MINOR, the lock's palette check was a denylist of Appearance names: it missed others (highlight, buttonFill,
    windowSecondary, inactiveFill, iconTint) and the shared parts whose default colours follow the appearance (an `Icon {}`
    in LockView would draw a dark glyph on the dark lock for a light user, and the test stayed green). Now
    `tests/security/lock_palette.py` (from `security_unit.sh`) is an allowlist over the lock's files, PasswordField and the
    idle dim: Appearance only as darkColors and appearance-free members (motion, fonts, the pure withAlpha), never bare;
    PasswordField's `Appearance.colors` only as the defaults of the five colours LockView sets itself, from darkColors, with
    no focus ring, and its own Icon and FocusRing held to the field's colour and to that switch; Tokens colours only
    colorDark; each file's types as today, so no Icon, Button, Material or FocusRing. Its selftest plants 20 mutants (the
    review's Icon, Button and `Appearance.highlight` in LockView among them).
  - NITs: SafeMode.qml's header says what the code does (the displays, the guard, the flag kept by Try Again); the alert's
    buttons take no focus and the alert handles every key, a held key answering nothing whatever it is (a held Return used
    to press a focused button again once a failed Try Again gave the focus back; `tst_safemode` test_heldKeys); a flag whose
    identity `stat` cannot read stays, as "not the same file", and is said (`tests/shell/shell_failures.sh`, where the
    helper's cases live: a failing stat).
- **Review round 3** (2026-11-12, the opus review of 0edece99: PASS, merged; one MINOR and five NITs, fixed in a follow-up
  pull request, branch fix/safe-mode-s4-hardening):
  - MINOR-1, the palette check read the lock's .qml files only: a `.import Grassfield.Ui as Ui` in LockMachine.js returning
    `Ui.Appearance.colors.text`, used by LockView, passed it and the scan, and an offscreen probe showed the colour following
    the appearance. `lock_palette.py` now checks the closure of the lock's files under their file imports (.js included, and
    `.import` in scripts), the types of this tree they make (GrassfieldArtwork, WallClock, LockController, LockStills made at
    run time) and the script modules of an imported module they use as a qualifier, transitively; a lock script may import no
    module, and Appearance is refused through any qualifier. PasswordField's own Icon and FocusRing are the two parts not
    followed, their colours held by rule 6.
  - NITs: Qt's palette (`palette.windowText`) refused on the lock; createQmlObject, Qt.createComponent (but Lock.qml's one of
    LockStills.qml), a Loader source, setSource() and a Loader's `.source =` refused there, and createQmlObject anywhere in
    the security tree (`security_process_scan.py`); Tokens and Appearance never subscripted, and PasswordField's exception read
    per statement, not per line; the safe-mode alert's keyboard target has the accessible focus and is announced when Tab
    moves it (`Accessible.focused`, `Accessible.announce`), with no key focus; only the bare key acts (Shift for Tab, the
    keypad's Enter), so Ctrl+Space, an input method's switch, never presses Log Out (`tst_safemode` test_modifiers).
    `lock_palette.py`'s selftest plants 34 mutants (14 new, one per finding).
  - Residual, recorded (NIT-6): on the path where `stat` cannot read the flag's identity, Try Again leaves the flag in place
    with the shell running; if the user later stops the shell on purpose (`systemctl --user stop`), the alert appears after
    two looks. Harmless (Try Again then starts it), and the same as residual (2) above.

### Step 2: no untested toolkit reaches the session, on any path (U-1, I-1, M-7) — **opus security review** (2a's helper verbs; nothing else runs as root)
Goal: what Update Now refuses today, every path refuses or at least detects; the user is told what to do in the words
of the session, never in a terminal.
- **2a. The hold** (SQ-3; the owner decides its shape, and it ships only once the `[grassfield]` repository is published,
  ADR-0033 h: before that there is no build to wait for and a hold would refuse every system update with no end; review
  of 2c0bd74, MAJOR 1). With option A: two split packages in `packaging/arch/PKGBUILD`. `grassfield-hold` holds nothing but
  `depends` on the toolkit `BUILD-DEPS` records: `quickshell=<that exact version>`, `qt6-base>=<major.minor>` and
  `qt6-base<<the next minor>`; never `hyprland` (ADR-0009: degraded mode and the rebuild) and never `kcoreaddons` (KF6
  releases monthly with a public ABI; a bound would refuse every release for nothing). `grassfield-unhold` is its empty
  twin: `provides=(grassfield-hold)`, `conflicts=(grassfield-hold)`, no bound. `grassfield-desktop` depends on
  `grassfield-hold`: a fresh install and the next `-Syu` of an existing system both pull the real hold (pacman resolves a
  dependency by its literal package name before it asks about providers), and the twin satisfies the same dependency
  without the bounds, so neither can be removed by mistake and both are reachable. "Allow system updates Grassfield
  hasn't tested…" in Software Update runs a new verb of `grassfield-channel-helper` behind its polkit action, `unhold`:
  one root transaction, `pacman -S --noconfirm --ask 4 grassfield-unhold` (`--ask` is pacman's bitmask that answers its
  conflict question, so the twin replaces the hold in one step; if pacman 7 no longer keeps it, `pacman -Rdd
  grassfield-hold` followed by `pacman -S grassfield-unhold` is the fallback: step 2a's first container test decides),
  and `hold` runs the reverse ("Hold untested system updates again"). Once the toolkit has moved past the bounds, that
  reverse cannot be satisfied (pacman answers "unable to satisfy dependency 'qt6-base<6.12'"; review of 5a20d19): the pane
  then shows "Hold again" greyed with the reason, "Your system already moved past the versions this Grassfield was built
  for; holding comes back with the next Grassfield update", decided by the same comparison as 2b (`pacman -Q` against the
  hold's bounds); the next `grassfield-desktop` build, made against the new toolkit, carries a hold whose bounds match, so
  the button works again after it. pacman then refuses, on every path, any
  transaction that moves `quickshell` or `qt6-base` past the bounds, until the repository ships the build made against
  the new toolkit, which joins the same transaction (ADR-0033 f's watch job, extended from Hyprland's ABI to Qt and
  Quickshell on Omarchy's rc mirror). What the user sees when it refuses: on Update Now, the helper's plan step fails
  before any change; today that step exits 8, "pacman cannot plan this update" (`packaging/pacman/grassfield-update-helper:242-243`),
  which the pane shows as a failed preparation, so step 2a makes the helper read pacman's refusal and, when it names
  `grassfield-hold`, answer exit 6 (`incompatible`, the U27 path): the pane then says "This update needs a newer version of
  Grassfield, which isn't available yet." with "Allow…" one click away. That reading is a root-side change of the helper,
  under the opus security review (review of 5a20d19, finding 4). On `omarchy update` in a terminal, pacman's
  own error names `grassfield-hold` and the bound and Omarchy's script reports a failed update, and the session's next
  scheduled check (ADR-0033 d) raises the same notice with the same action.
- **2b. Detection as the user, on every path.** Nothing runs as root: ADR-0009's amendment says "Nothing in the amended
  design runs as root after the package is installed" (`docs/decisions/ADR-0009-plugin-distribution.md:112`), and the
  first version of this step planned a root alpm hook against it (review of 2c0bd74, finding 6). Instead the shell's
  update checker (ADR-0033 d, already a one-shot child of the shell as the user) watches `/var/lib/pacman/local` (its
  modification time moves at every transaction; readable by every user) and, when it moved, compares `pacman -Q` of the
  tracked packages with `/usr/share/grassfield/BUILD-DEPS`; a difference posts "Log out to finish updating" (the family of
  `shell/shell.qml:267-279`; today only the install scriptlet prints it, to a terminal), Settings' Software Update pane
  shows the same with "Log Out…", and the compositor rebuild's opt-in path reads the same comparison at the next login.
  The shell's explicit reloads of the session configuration (`SessionConfig.qml`, `Displays.qml`) wait while
  `/var/lib/pacman/db.lck` exists, bounded, so a display trial never reloads a half-written tree (I-2's residual).
- **2c. The rc-channel gate** (T-5, T-10). `just release-check` and CI gain a container run of the headless suites, the
  QML lint against the rc channel's Quickshell `qmltypes` and the plugin build against the rc Hyprland headers (the
  existing C3), so an incompatibility is known one Omarchy cycle before stable; the result feeds the watch job's build.
- **2d. The extension notice without a command** (review of 2c0bd74, finding 9). `windows.rebuildExtension` is off by
  default, so two of the degraded notices name `grassfield-compositor-rebuild` as a command to type (`shell/shell.qml:270,
  276`), against SP-6. The notice gains one action, "Update Extension", which runs what the opt-in runs
  (`grassfield-compositor-rebuild --session`, as the user, in the background) and then says "log out and back in"; the
  setting keeps its default. Until 2d ships, this is a known limit under SP-6.
- Proof: `tests/integration/update_helper.sh`'s container with the hold pair installed: an update that moves Quickshell is
  refused by pacman on `pacman -Syu`, on `omarchy update`'s command and on Update Now (the pane's sentence), nothing
  installed; the same transaction with the matching `grassfield-desktop` in a test repository goes through; "Allow…"
  swaps the hold for its twin through polkit (`--ask 4`, or the `-Rdd` fallback) and the update goes through; "Hold
  again" swaps them back; the checker's comparison on a fake `/var/lib/pacman/local` and `BUILD-DEPS` posts the notice
  (offscreen harness); the extension notice's action runs the rebuild (nested).
- Tests: the container cases above, with the helper's reading of a hold refusal (exit 6, `incompatible grassfield-hold`)
  in `tests/integration/update_helper.sh`; `tests/shell/session_services.sh` for the checker's reader;
  `tst_softwareupdate.qml` for the pane's sentences and the greyed "Hold again"; a `tests/ci` check that `BUILD-DEPS`, the hold's `depends` and the s3.4 table name the same
  packages; `tests/shell/compositor_rebuild.sh` for the notice's action.
- Integrator, nested: the notice on a fake `/var/lib/pacman/local`; the reload guard with a fake `db.lck` during a display
  trial; "Update Extension" from the notice.
- Owner, real session: the next Omarchy toolkit move: Update Now says "needs a newer version of Grassfield" (today's
  L2 item of ADR-0033) and `omarchy update` is refused by pacman with the hold's name; after the matching build is
  published both go through, then "Log out to finish updating" appears once.
- Review: opus security for the helper's two verbs (root through polkit, the same rules as `grassfield-channel-helper`);
  the integrator for the rest; two pull requests at least (2b and 2d need no owner answer, 2a waits for SQ-3 and the
  repository).

### Step 2a as built (2026-11-08, branch feat/update-hold; the owner's decision of 2026-11-08, "required before 1.0.0 stable")
The owner activated SQ-3 option A: the repository has been published since rc2, and the rc7 audit rated the missing hold and watch
job as 1.0 blockers (R7-INS-01, R7-INS-02; R7-ARC-01, safe mode, is not part of this step). Built:
- **The pair** (`packaging/arch/PKGBUILD`, two split packages, `arch=any`): `grassfield-hold` is `depends` only, computed in its
  package function from `$srcdir/BUILD-DEPS` by `packaging/arch/hold-bounds.sh` (never typed): `quickshell=<the recorded version
  without its pkgrel>`, `qt6-base>=<major.minor>`, `qt6-base<<next minor>`, an epoch kept; a record that lacks either or cannot be
  read fails the build. The bound is the same rule as U27 (Quickshell's whole version, not its pkgrel; Qt's major.minor), so a
  pkgrel-only rebuild by Omarchy never refuses an update that U27 would let through (decision under the owner's rule: fewer
  refusals with nothing for the user to do). `grassfield-unhold` has `depends=()`, `provides=(grassfield-hold)`,
  `conflicts=(grassfield-hold)`. `grassfield-desktop` depends on `grassfield-hold` (the literal name pacman resolves first). The
  install script's `--uninstall` lists both. `tests/ci/hold_parity.py` checks that BUILD-DEPS, GU_TRACKED, ADR-0033's s3.4 table, U27
  and the hold name the same packages (the hold bounds exactly quickshell and qt6-base, never hyprland or kcoreaddons).
- **The root verbs** (`grassfield-hold-helper hold|unhold`, `gf_hold_swap` in `grassfield-channel.sh`, behind their own polkit
  action `org.grassfield.packages.hold`, `auth_admin` every time, never kept: the opus review found that a package transaction
  under `set-channel`'s kept password broke SU-M1 and ADR-0033's "no other privilege"; the channel helper has no hold verb): the verb picks one
  of two constants, so no package name ever comes from the caller; one transaction `pacman -S --noconfirm --ask 4 --needed --asdeps
  grassfield/<package>=<version>` (the repository is named and the version pinned to the one read; `--asdeps`, so removing
  grassfield-desktop takes the pair along); before it, refusals with nothing changed (no `[grassfield]` section; the package not in
  the synced list; a conflict other than the twin, since `--ask 4` answers every conflict question yes; a `pacman -S --print` plan that is more than that one
  package, which is what refuses a `hold` the installed toolkit no longer satisfies instead of letting pacman fetch other
  versions; `db.lck`); after it, exactly one of the two is installed. The `-Rdd` fallback of 2a is NOT coded: the first container
  case of `tests/integration/update_hold.sh` decides, and a failed swap changes nothing.
After the transaction the installed set must differ by the twin only, or the helper says so loudly.
- **The update helper** reads pacman's refusal of its plan: an error line "required by grassfield-hold" gives exit 6 (`incompatible
  grassfield-hold`, the U27 path) instead of 8, only when pacman failed. With the twin installed, U27 does not compare `qt6-base` and
  `quickshell` (`u27_exempt`; review blocker: Update Now would otherwise refuse after "Allow…" what pacman now lets through).
  Settings shows the existing sentence, plus "Allow…" while held.
- **Settings** (U39): a row "System updates Grassfield hasn't tested" with "Allow…" or "Hold Again" (disabled with the reason when the
  installed toolkit is past the bounds of the installed build), from `grassfield-channel-set hold-state` (read-only), and "Allow…" in the
  refused-update sentence; `grassfield-channel-set` gains `hold`, `unhold`, `hold-state`; the shell's end notice for exit 6 names the way
  out. The scheduled check's own notice for a hold it cannot install past (ADR-0033 d) is NOT built: the pane and the run's notice are
  the paths; on a terminal update pacman's error names the hold.
- **The watch job** (ADR-0033 f, in grassfield-packages; delivered as files under `.dev/update-hold/`, applied by the integrator):
  daily, reads the published channel's packages (the BUILD-DEPS of grassfield-desktop and the ABI stamp of grassfield-compositor; the
  `build-<id>.txt` of build-channel.sh is a CI artifact and is not published), compares Hyprland by its ABI stamp, quickshell and
  qt6-base against the hold's bounds on Omarchy's stable and rc channels, starts `build.yml` with pkgrel + 1 when stable differs, opens
  one issue when only rc differs (build.yml has no rc variant: a person decides), fails when a source cannot be read.
- **Residual risk (R7-INS-03), bounded by the owner on 2026-11-08**: while Grassfield lags, every system update is refused and
  publication waits for the owner's approval. The target is a rebuild published within 7 days of the Omarchy move. The shell records the
  first refused update of a toolkit move (`holdRefusedAt` in its own state file, cleared by an update that goes through); within the 7
  days the pane and the notice say a compatible update is expected soon, from the 7th day on they put "Allow system updates Grassfield
  hasn't tested…" forward (U39). "Allow…" stays one click away in the hold's row throughout. Verified here: the logic and QML tests
  (`tests/shell/update_hold.sh`, `tests/ci/hold_parity.py`, the Settings and guard tests) and a live read-only run of the watch tool.
  NOT VERIFIED: `tests/integration/update_hold.sh` (docker; the `--ask 4` swap and the exit 6 reading against real pacman), the
  workflow on GitHub, polkit and pkexec around the new verbs, a nested capture of the row (visual NOT verified), the opus review.

### Step 2b as built, first slice (2026-10-31, the branch of the stability lane; the toolkit as installed and the log out)
- `grassfield-update-check` lists, before every other step and in every state it answers (repair, not-set-up, failed,
  up-to-date, available, blocking), the toolkit as installed (`toolkit`, U31): each tracked package pacman names
  (`qt6-base`, `quickshell`, `hyprland`, `aquamarine`, `kcoreaddons`, the helper's `GU_TRACKED`) with its version, the
  time pacman installed it (`/var/lib/pacman/local/<name>-<version>/desc`, `%INSTALLDATE%`, readable by every user; a
  name or version outside pacman's grammar is never looked up, a time outside a four-digit year reads as unknown), the
  version this Grassfield was built with (`/usr/share/grassfield/BUILD-DEPS`, the helper's grammar line by line) and
  whether it moved away from that record by U27's rule (the helper's `compare_key`: Quickshell whole, the others
  epoch:major.minor, never the pkgrel; `null` without a record, `true` when the record does not name the package, as the
  helper refuses then: fail safe). `docs/specs/updates.md` U31 and the output contract.
- The shell (`SoftwareUpdateLogic`, pure): a package installed at or after the session's start, or at a time the checker
  could not read (the safe side), means the running session loaded a file that was replaced under it, whatever the
  record says (a pkgrel rebuild replaces the file too). The session's start is Hyprland's, read from
  `HYPRLAND_INSTANCE_SIGNATURE` (`<hash>_<unix seconds>_<n>`), the same across a restart of the shell; the shell's own
  start without a signature. The service sets `toolkitLogout` (due until the session ends; re-read from the file at
  load, so a shell restarted after the upgrade finds it due again) and writes U14's `logoutPending` with its reason
  (`toolkitLogout`) to `software-update.json`; `news()` announces it once per session (the id carries the session's
  start; the `announced` list survives a restart); `shell.qml` posts "Log out to finish updating" with "Some updates
  finish when you log out. Log out and back in to use them." (no package name in a sentence, the integrator's decision:
  macOS never names libraries in an update notice; the journal names them), opening Software Update. The pane's U14 row
  shows as for GF-083's own update, with the subtitle "Some of the update is used only after you log in again." when the
  file says the log out is for the toolkit. A package installed before the session started asks for nothing: the
  session already runs on it. An answer given before the checker ran (`update-running`, `busy`) or by no checker keeps
  the file's list, so the pane's sentence does not fall back meanwhile.
- Which checks see a replaced package: the scheduled ones (U7), the check `omarchy update` asks for at its end (U9) and
  Update Now's own; a `pacman -Syu` typed in a terminal is seen by the next scheduled check or at the next login. Not in
  this slice: the watch of `/var/lib/pacman/local` (the shell has no directory watcher: a user `.path` unit on it,
  `PathModified=`, asking the shell for a check, is the second slice), the bounded wait of `SessionConfig.qml` and
  `Displays.qml` while `db.lck` exists (I-2's residual), and the compositor rebuild's opt-in reading the same list at
  login.
- Tests: `tests/shell/update_check.sh` (no record, all matching, pkgrel and patch levels alone, Qt and Quickshell moved
  with their install times, an epoch, times outside a four-digit year, a garbled record line and a package the record
  does not name read as moved with built null, a package pacman does not list absent, the field in a repair and in a
  failed answer); `tests/fuzz/fuzz_helpers.py` update-check gains a round over the record (present or absent), the
  local database entry and pacman's answers; `tests/unit/tst_softwareupdate.qml`
  `test_aToolkitReplacedUnderTheSessionAsksForALogOutOnce` (the session's start from the signature and without one,
  installed after, before, an unreadable time, a pkgrel rebuild, no list, junk, the crash-restart scenario, once per
  session, the flags and the list kept through an `update-running` answer); `tests/shell/software_update_service.sh`:
  the probe's steps t1-t3 (before the session: nothing; after: announced once as toolkit, the log out written with its
  reason; a later update: nothing more, still due) and `restart.qml` (a shell restarted with the session's signature
  and the stored file finds the log out due again and announces nothing more).
- Review round 1 (2026-10-31, the integrator's opus review of 9043ac4: FAIL, two majors): the French catalog was stale
  for the two new sentences (I1); the session's start was the shell's, so a shell crashed and restarted after the
  upgrade dated the upgrade before its own start and asked for nothing while the compositor kept running on the
  replaced libraries, and its first save erased the row an earlier shell wrote; a stale record would have announced
  again at every later update of a moved package while a pkgrel rebuild set nothing; no probe step drove the toolkit
  path through the service; the notice named libraries. Each is in the design above (the session's start from the
  signature, the log out from install times whatever the record says, once per session, the generic sentences in
  English and French, the probe steps and the restart probe); the nits too (the four-digit year, the file's list kept
  through an `update-running` answer, a record that does not name a package reads as moved).
- Evidence (this container; no Qt, no Quickshell): `tests/shell/update_check.sh` PASS, exit 0 (the lock and waiter
  cases skipped as root); the update-check fuzz round at 5000 and 20 000 iterations, no finding; `helpers_fuzz.sh`
  PASS; `python3 -I scripts/dev/check-i18n.py --no-lupdate` ok (the catalog's two entries were added by hand, next to
  their neighbours: `lupdate` is not installed here); `python3 -I tests/ci/inventory.py` ok; `git diff --check` clean;
  qmllint 6.4 parses the seven QML files, the JS parses. NOT VERIFIED here: `i18n-update.sh --check` (lupdate),
  `tst_softwareupdate.qml` (QtTest), `tests/shell/software_update_service.sh` (offscreen Quickshell: the probe's steps
  t1-t3 and `restart.qml`), the notice and the pane's row (nested), the list on a real system
  (`grassfield-update-check | jq .toolkit`).
- Review round 2 (2026-10-31, the integrator's review of e03013d: FAIL, two new majors): the docs commit of round 1
  had replaced everything between the Step 2b section and "Delivery order" (Steps 3-8 and "Step 5 as built, first
  part" were gone from this file; restored from main, this section inserted before Step 3); the probe's steps t1-t3
  read the state file before the service had saved it (`toolkit` undefined): each step now waits for the saved list to
  carry its answer's install time (and, at t2, the flag). Minor: an unreadable install time counted as "this session"
  at every start, so a pacman database outside its default path asked at every session: the file now records the
  installed versions a log out was asked for on an unreadable time (`toolkitAsked`), and asks again only for another
  version. Nits: the signature's time is clamped to the shell's start (a later one would hide installs); the service
  saves once after adopting the file at load, so a previous session's flag does not stay on disk until the next check;
  GF-083's `logoutPending` and the toolkit's `toolkitLogout` are separate flags in the file, so the pane's title says
  "Log out to finish updating Grassfield" only when Grassfield itself was updated and "Log out to finish updating" when
  only the system libraries were (with the French entries).
- Review round 3 (2026-11-01, the integrator's review of f8b0916: FAIL, one blocker): the probe's step k took its
  baseline of checker runs from a stale reading (the t-steps read the calls log no more, and the first reload after
  them returned the content before their three runs), so k counted their runs as its own; the baseline is now taken
  once two reads of the log agree. Nit: a shell restarted in the same session after a log out asked on an unreadable
  install time dropped the flag (the versions were recorded as asked for): the file's flag, with the announcement
  marked with this session's start, keeps it due (`toolkitDueFromFile`); another session's flag is stale. A Settings
  unit case covers the toolkit-only title. The integrator runs the offscreen and unit suites (none here).
- Review: the checker reads two more world-readable files and runs `pacman -Q` five times more; nothing runs as root;
  nothing under `shell/security/` changes.
- Merged 2026-11-01 as 5eaf9d25 (#77, the integrator's opus review PASS at round 4; the integration branch #90 carried
  it). The integrator ran `software_update_service.sh` outside the sandbox on the merge: exit 0, step k counted 1.

### Step 2b as built, second slice (2026-11-01, the branch of the stability lane; the watch of pacman's database, the lock wait)
- `packaging/systemd/grassfield-pacman-watch.path`: `PathChanged=/var/lib/pacman/local` (the directory changes at every
  transaction, one entry per package created and removed; readable by every user), session-only (`ConditionEnvironment`,
  `PartOf`/`Requisite=graphical-session.target`), a trigger limit of 100 in 60 s (systemd's default of 200 in 2 s would
  put the unit in failed, watching no more, on a long transaction), started by `autostart.lua` with the session's other
  units and installed by the PKGBUILD. It starts `grassfield-pacman-watch.service` (oneshot, hardened as the session's
  other helpers, Quickshell's option variables and the helper's knobs cleared, 20 starts in 60 s), which runs
  `packaging/bin/grassfield-pacman-watch`: a 5 s settle (so one transaction is one or two checks, not hundreds: events
  during a run are kept and start it once more after it), then one `qs ipc -p /usr/share/grassfield/shell call update
  check system`. The shell's `update check` accepts the origin `system` (not a user's check: a toolkit replaced under the
  session is announced as a scheduled check's is); the IPC surface table names the caller. A check that finds pacman
  mid-transaction is followed by the next trigger's. Nothing runs as root (ADR-0009's amendment).
- `shell/platform/SessionConfig.qml`: a reload asked while pacman holds its database lock (`/var/lib/pacman/db.lck`,
  root's and unreadable: it exists whenever the read fails for any reason but "no such file", `FileViewError.FileNotFound`
  as the lock's marker is read) waits, polled every `Tokens.sessionConfigLockPollMs` (500 ms), at most
  `Tokens.sessionConfigLockWaitMs` (10 s, under a display trial's 15 s so the trial's countdown is not what ends the wait),
  then goes ahead anyway with a warning; the requests keep their order and their tickets. I-2's residual: a display trial
  never reloads a half-written Lua tree.
- The compositor rebuild's opt-in at login needs nothing from this slice: `ExtensionStatus` already reads the plugin's
  hello and Hyprland's version at start, and a Hyprland that moved past the plugin's ABI shows as `mismatch` (rebuilt in
  the background when `windows.rebuildExtension` is on, step 2d's notice otherwise).
- Tests: `tests/shell/session_services.sh` (the path unit's watch, trigger limit, session condition, autostart and package
  lines; the service's oneshot, helper, hardening, cleared environment and start limit; the helper's call, no privilege,
  the knobs honoured in a dev session outside the real one and ignored inside it); `tests/shell/displays_trial.sh`
  (`trial.qml` gains the lock wait: a reload asked while the lock file exists waits with its ticket out, goes once the
  file is gone, and Hyprland's answer reaches `answered`; the fake counts ten reloads).
- Evidence (this container; no Quickshell): `tests/shell/session_services.sh` exit 0; `sh -n` on the helper; qmllint 6.4
  parses `SessionConfig.qml`, `SoftwareUpdate.qml` and `Tokens.qml`; `python3 -I tests/ci/inventory.py` ok; `git diff
  --check` clean. NOT VERIFIED here: `displays_trial.sh` (offscreen Quickshell), the units under systemd (the path unit's
  activations through a real transaction, the service's sandbox against `qs ipc`), `ipc_inventory.sh` (Qt's tools).
- Review: the integrator's nested pass (a `pacman -S --noconfirm <small package>` in a terminal: one or two checks in the
  journal, none as root; a display trial while a transaction runs: the reload waits, then goes).
- Review round 1 (2026-11-01, the integrator's opus review of 69757ef: FAIL, five majors): the two tokens were written
  into the generated `Tokens.qml` by hand (now in `ui/tokens/tokens.json`, a `sessionConfig` group, the file
  regenerated); a comment line of the helper held both "qs ipc" and "call must not", which `ipc_inventory.sh` read as
  a caller "must.not" (reworded); `FileView.reload()` reads later even with `blockLoading`, so the first reload after
  pacman took its lock went straight through (`waitForJob()` after `reload()` makes the read the one judged, as the
  display trial's probe reads its files); the helper asked after a fixed 5 s with pacman still running (a terminal
  `pacman -Syu` takes no Omarchy lock), so U31's "Log out to finish updating" could show mid-transaction and a log out
  would stop it: the helper now waits while `/var/lib/pacman/db.lck` exists, at most 30 min (the unit's start timeout
  past it), then settles, then asks once (tested with a fake lock: nothing while it exists, one call once it is gone,
  one call after the bound); the knob test ran the real `qs ipc` with the inherited `GRASSFIELD_SESSION=1`, which on
  the owner's machine would have reached the live shell: it runs with `GRASSFIELD_SESSION` unset for the dev-session
  cases and against a fake `qs` on a private PATH for the real-session case (the fake logs the exact command). Minor: a
  mutant refusing the origin `system` passed every test: `software_update_service.sh` now asks `update check system`
  over IPC (ok, one run) beside `user` (ok) and `bogus` (refused).
- Review round 2 (2026-11-01, opus review of e6f4ddaa: FAIL, one major in a test): `trial.qml` set
  `SessionConfig.pacmanLockPath` in the same handler that asked the lock step's reload, and a `FileView` read in the turn
  of its path change is stale even through `waitForJob()`, so the reload went straight through (step 21 failed inside and
  outside the sandbox, and a mutant without `waitForJob()` was not caught): the seam is set at the probe's first step, many
  turns earlier, and the lock file is written (synchronously) at step 20 before the reload is asked. Nit: the probe's step
  k sent `user` then `system` back to back, and a request made during a run joins it (U4): the probe logs every run that
  ends once it is ready (`ipc-run-done <n>`) and the script sends `system` only after the user run's line.
- Follow-up (2026-11-02, the integrator's note on #93): once the fake Hyprland was reachable (ad044d4d, the sockets under a
  short base), `displays_trial.sh` steps 21 and 24 failed: the probe recorded every `answered()` of `SessionConfig`, so the
  answers to the nine earlier reloads were in the lock step's list (inside the sandbox the fake was never reached and
  nothing was answered, which hid it). The probe records the lock step's own ticket only.

### Step 2d as built (2026-11-01, the branch of the stability lane; the extension notice without a command)
- The two degraded notices shown without the opt-in setting (`stale-manual`: "Grassfield was updated. Click to update
  its compositor extension, then log out and back in. Window titlebars and minimize are unavailable until then.";
  `mismatch-manual`: "It is not built for %1 yet, so window titlebars and minimize are unavailable. Click to build it,
  then log out and back in.") no longer name `grassfield-compositor-rebuild` as a command to type (SP-6): they are
  posted with `Notifications.postInternalAction`, whose click (the banner or the Center's entry, as Software Update's
  notices open the pane) runs `shell.qml`'s `startExtensionRebuild("the notice")`, the same `--session` run the setting
  starts (`grassfield-compositor-rebuild --session`, as the user, in the background, once per shell run; a second click
  or a click while it runs starts nothing), and the result notice then says what is next ("Log out to finish updating"
  with "The compositor extension was updated. Log out and back in to use it.", or "Compositor extension updated" when
  it loaded into the running Hyprland). The setting keeps its default; the `-rebuilding` notices and the plain one
  carry no click. The French entries follow. `ExtensionStatus.manualAction(key)` names the two keys (unit tested).
- Still naming the command, on purpose: the two failure results ("The build tools are missing or another build is
  running. Run grassfield-compositor-rebuild in a terminal to see why.", "The build failed. …"): a diagnosis, not a
  recovery; the journal holds the reason too. A known limit under SP-6 until step 8 (crash reports) gives a place for it.
- Tests: `tests/unit/tst_extensionstatus.qml` `test_theManualNoticesCarryTheRebuildAsTheirClick`. No offscreen test
  drives a click on a shell notice today (the Notifications module's internal actions have none): the nested pass is
  the check (a stale build and the setting off: the notice; a click: `--session` runs, the result notice follows).
- Evidence (this container): qmllint 6.4 parses `shell.qml` and the test; the JS parses; `check-i18n.py --no-lupdate`
  ok (3158 messages, 0 unfinished; the two old entries replaced by hand); `git diff --check` clean. NOT VERIFIED here:
  `i18n-update.sh --check`, `tst_extensionstatus.qml` (QtTest), the click in nested.

### Step 2c as built (2026-11-01, the branch of the stability lane; the rc-channel gate)
- `scripts/gates/rc-toolkit.sh` (`just gate-rc`; T-5, T-10, C3): a throwaway Arch container (`archlinux:base` at the digest
  the integration tests pin, only the script mounted read-only, the report directory mounted; docker's default network)
  set up as an Omarchy machine
  of the channel (`--channel rc`, the default, or `stable`): pacman's configuration in Omarchy 4.0.6's layout, `[omarchy]`
  first (`https://pkgs.omarchy.org/<channel>/$arch`: Omarchy's own builds win, and Quickshell is one of them, `quickshell
  0.3.2.r7.g2b4501a-1` in both channels' databases on 2026-11-01, where Arch's `[extra]` has 0.3.2-1), then `[core]` and
  `[extra]` from the channel's dated Arch mirror (`https://<channel>-mirror.omarchy.org/$repo/os/$arch`, Omarchy's
  `mirrorlist-<channel>`: where Hyprland, Qt and KDE Frameworks come from), packages signed; Omarchy's key from
  keys.openpgp.org, signed locally, then `omarchy-keyring`, as Omarchy's own bootstrap does. `pacman -Syuu` brings the whole
  base to the channel's snapshot (downgrades allowed: the image may be newer than it), then the PKGBUILD's makedepends and
  the desktop package's depends, read from the PKGBUILD itself (version constraints off, Grassfield's own packages out:
  they are built from the tree), so the set never drifts from what such a machine installs. A `git archive HEAD` made on
  the host and handed over in the report directory (package scripts run as root in the container: they never see the
  working tree, its untracked files or its `.dev` logs) runs as an unprivileged user, three steps, each logged and timed: `lint` (`scripts/dev/qmllint.sh`: the tree's QML
  against the installed Quickshell's `qmltypes`, T-10),
  `test` (`scripts/dev/test.sh --layer data,logic,headless`: the offscreen suites on the rc Qt, Quickshell and KDE
  Frameworks, T-5), `plugin` (the compositor plugin and its unit tests with CMake/Ninja against the rc Hyprland headers,
  C3; the ABI stamp in the note). The report (`.dev/rc-toolkit/<timestamp>/`, its files given back to the host's user):
  `result.tsv`, `toolkit.txt` (`pacman -Q` of qt6-base, qt6-declarative, quickshell, hyprland, aquamarine, hyprutils,
  hyprlang, kcoreaddons, kio in the container, and how many Quickshell `qmltypes` the lint saw), `sources.txt` (the package
  file each came from: which repository served it), `snapshot.txt` (the channel's two databases and their dates),
  `stable.txt` (the same packages on the machine that runs the gate, when pacman knows them) and `summary.json`: the record
  the watch job of ADR-0033 f reads (the channel's toolkit, what moved against this machine, the sources, each step's
  result, the verdict). Exit 0 PASS, 1 FAIL,
  2 INCONCLUSIVE (no docker, a failed setup, a wanted step without a result: never a pass). `just release-check --rc` runs
  it as its step 8 on the snapshot (its report beside the run's logs); without `--rc` the summary says the gate did not run.
- Incident I-1 as a regression (step 7's row, the r7 proof as a container case): `tests/shell/hypr_socket_errors.sh` runs the
  real `SessionConfig` offscreen against a fake Hyprland whose request socket is first missing (a connect error), then hangs
  up without an answer, then answers, then stays silent past the answer bound and hangs up late. Every request is judged
  exactly once (`answered(ticket, ok)`: false, false, true, false), nothing twice, and Quickshell exits 0 (a crash is its
  exit code: 139). In the headless layer it runs on every machine with Quickshell; in the gate it runs on the rc channel's
  Quickshell, which is what the 2026-10-29 proof with a 0.3.2.r7 built from source showed by hand.
- Tests: `scripts/gates/rc-toolkit.sh --selftest` (the container's network; the channel's pacman configuration and
  mirrorlist; the dependency
  reader on a fixture PKGBUILD with comments, quotes, constraints and another package's depends; the moved table; the
  verdict's three words and the partial run; the record) from `tests/shell/gates.sh`; `tests/shell/hypr_socket_errors.sh`
  (headless).
- Evidence (this container; no docker daemon, no Quickshell): `tests/shell/gates.sh` exit 0 (the selftest's 16 cases
  among it); `bash -n` on the gate, the release check and the test; `python3 -I tests/ci/inventory.py` ok (605 tests);
  `tests/ci/socket_errors.py` ok; `tests/tools/check-isolation.py` ok; qmllint 6.4 parses `probe.qml`; `git diff --check`
  clean. NOT VERIFIED here: the container run itself (the rc mirror's snapshot, the time it takes, the suites' skips on
  it), `hypr_socket_errors.sh` against a real Quickshell, `release-check --rc`.
- Review: the integrator runs `just gate-rc` once (docker, the network): the three steps and the toolkit table, and
  `tests/shell/hypr_socket_errors.sh` on the installed Quickshell; the watch job (ADR-0033 f) stays disabled until the
  repository is published and reads `summary.json` then.
- Review round 1 (2026-11-02, the integrator's opus review of f6f3361: FAIL on gate S1). MAJOR: gitleaks' generic-api-key
  flagged Omarchy's public fingerprint, held as `OMARCHY_KEY` (f4ecdbc6, line 40): renamed `FPR`, as
  `tests/integration/update_helper.sh` names it, and the committed line listed in `.gitleaksignore` (the file's rule: a
  false positive already committed is listed, a new one fixed in the file). MINOR: `--network host` gave a root container
  the host's localhost services: docker's default network now, the host's only when a proxy listens on this machine's
  loopback (localhost, ::1 or a numeric 127.x address; the run says so); the whole working tree was mounted, readable by
  package scripts running as root: only the script goes in, the snapshot already arrives in the report directory. NIT:
  the selftest counts its own cases (16 now: five for the network rule, one of which caught `127.example.org` taken for
  loopback); `--only`, `--channel` and `--logs` without a value are usage errors (exit 2); the INCONCLUSIVE text says
  rootless podman is not supported.
- Follow-up (2026-11-02, the integrator's note on #104): `hypr_socket_errors.sh` steps 9 and 12 failed and the fake saw no
  connection: the fake waited for the probe's `go` file in the Hyprland instance directory, while the probe writes it to
  `Mode.stateDir` (`GRASSFIELD_STATE_HOME`, the test's `state` folder), so the request socket never came and every reload
  met a connect error. The fake is given that path, and it counts only `reload` requests (a JSON query of Quickshell's
  Hyprland module gets `[]` and is not counted, so it cannot shift the order). The fake alone, driven by a client that
  replays the probe's sequence (no socket before `go`, a JSON query, three reloads), logs "1 hangup;2 answered;3 late".

### Step 3: chaos: every process killed, every return verified; R1 measured (T-2, T-4, M-3)
Goal: the inventory's "how it comes back" column becomes a test, and every silent loss becomes at least a journal line.
- `tests/integration/chaos.sh` (nested, bare): for each row of audit section 1.1 that the nested session can run (the
  shell unlocked and locked, SIGSEGV and SIGKILL, once and in a loop until safe mode; the bridge; both portals mid-request;
  crash-watch, battery-watch, automount; the ANR stand-in; one Grassfield app and one third-party app), kill it and
  check: the unit's state and the time to come back (R1 ≤ 3 s for the shell, from the journal), the lock state
  (`hyprctl -j monitors` `LOCK`) before, during and after, what was replayed (badges and registrations after a bridge
  restart, the notification history after a shell restart, the Open panel's last folder after a portal restart), the
  notice for an app (one, with Reopen) and none for a service, and one journal line per silent loss (`P-8`, `P-9`: the
  unit's own `Restart=` log is enough when it comes back; the start-limit failure must say what stopped).
- Proof: the script's report, one row per process, with the capture of what the user sees at the worst moment.
- Tests: the script itself (inventory layer `nested`), plus a `logic` self-test on fakes; `scripts/gates/r1-restart.sh
  --journal` on the nested unit's journal becomes the R1 verdict.
- Integrator, nested: the whole script on a quiet machine, twice; the R1 figure recorded in `docs/testing/gates.md`.
- Owner, real session: nothing until step 1 ships; then the R1 journal check after their step-1 kills.
- Review: the integrator; security only where the script touches the lock (it reads, never unlocks).

### Step 4: endurance and bounds: the memory slope, descriptors, timers; the plugin's log budget; the guards proven (T-3, T-7, I-6, I-7, M-10, M-11)
Goal: the 6 MB/h is explained or fixed; every resource guard is seen to act; a loop in the compositor cannot fill a disk.
- `tests/shell/endurance.sh` (nested, bare, hours): scripted activity in rounds (Overview open and close, Apps, Search
  typing, notifications in and out, lock and unlock with the dev PAM gate, a display added and removed, an icon-mode
  switch, the DST hour simulated with `TZ` and a fake clock, a sleep simulated through the marker's sleep count),
  sampling every minute RSS and `RssAnon`, the count of `/proc/<pid>/fd`, `Threads`, and the number of live repeating
  QML timers through a dev-only IPC hook (`SEC-04` class dev); verdict by `soak_lib.sh`'s slope function against a
  threshold the owner accepts (proposed: RSS slope ≤ 1 MB/h after the first 30 min, descriptors and timers flat).
- The guards proven: a dev-only hook allocates until `MemoryMax` (the shell is killed, back within 3 s, the lock kept),
  another spins the GUI thread (the compositor's frame time stays within P3 under `CPUQuota`), the bridge's `MemoryMax`
  (already `menu_bridge_memory.sh` case G).
- The compositor: every loop-prone path (layer-pointer refresh, overview retargeting, stages focus) gets the plugin's
  log budget (`compositor/src/core`), with a unit test that a path logging in a loop stops after its budget; the real
  session's Hyprland log state is recorded (`hyprctl getoption debug:disable_logs`, owner) and, if logs are on, the
  session sets the bound Hyprland offers (NOT VERIFIED which option exists in 0.56.2: the step reads the installed
  `hl.meta.lua`).
- Proof: an 8 h endurance report with the four series and the verdict; the guard hooks' three captures; the log-budget
  unit test; if the slope is above the threshold, the allocation site (Qt's own tools, `malloc_info` through a dev
  hook, or the icon-mode and wallpaper paths first, the two known growers) and the fix in its own pull request.
- Tests: the endurance script (nested), the guard hooks' tests (nested), the budget test (compositor gtest).
- Integrator, nested: the 8 h run on a quiet machine; a 1 h run becomes part of `just release-check`.
- Owner, real session: `scripts/gates/rss.sh` over a week of normal use (the existing P2 tool, repeated), to compare
  with the nested slope.
- Review: the integrator; R13 (compositor-engineer) for the plugin changes; security for the dev hooks' gates.

### Step 5: fuzzing of the parsers (T-1)
Goal: no input a process reads from the system, a file or another process can crash or hang it.
- In-tree, no new dependency: a mutation harness (`tests/fuzz/`, gtest for C++, a Python mutator for the scripts' readers,
  a QML harness for the JS readers) that takes each existing corpus and applies random byte and token mutations for a
  budget of iterations under ASan/UBSan (the `--asan` builds exist), with a saved seed so a failure reproduces. Readers,
  in the order of exposure: the plugin's gfc/1 request reader and the shell's event parser (another process of the user
  can send either), the menu bridge's socket and DBusMenu layouts (any app), the ANR stand-in's `anr report`, `qs ipc`
  arguments of every action, `hyprctl -j` consumers (`grassfield-session-end`, `grassfield-lid`, the `omarchy-shell`
  stand-in's `jq` filter, the lock's monitor model), `/proc` and `/sys` readers (Activity Monitor, the crash watcher),
  `.desktop` readers (the Apps model, the crash watcher, `entry-names.sh`, `hidden-entries.sh`), every file of the
  ADR-0020 table (JSON readers; the Lua files Settings writes are checked by `Hyprland --verify-config` on the mutated
  output, so a Settings write can never produce a file the compositor refuses), the Store's catalog, AppStream and pacman
  output readers, the journal JSON of the crash watcher. libFuzzer behind a CMake option, dev only, is a later option
  (clang is already a `just check-tidy` tool; it adds no package).
- Proof: the harness's report per reader (iterations, mutations, 0 crashes, 0 hangs over the bound); every finding fixed
  in its own commit with the reproducing seed as a regression case.
- Tests: the harness runs in `scripts/dev/test.sh`'s sanitized pass with a short budget; `just release-check` runs the
  long budget.
- Integrator, nested: none needed (offscreen); the gfc/1 cases also run against the nested plugin through
  `scripts/nestctl` for the request side.
- Review: the integrator; security for the lock's monitor model and the stand-in (they are security modules' inputs).

### Step 6: hang detection, and the extension after a compositor crash (T-6, M-8, M-10) — SQ-5, SQ-6
- **6a. The liveness probe** (SQ-5, option A): `grassfield-shell-watchdog.timer` and its `.service` (`Type=oneshot`,
  every 30 s): `qs ipc -p /usr/share/grassfield/shell call capabilities status` with a 5 s `timeout`; three misses in
  a row (a state file in the runtime directory) → `systemctl --user kill --signal=SIGKILL grassfield-shell.service`: the
  main process dies by a signal, so the unit fails, `Restart=always` brings it back, `OnFailure=` runs and step 1's
  detector counts it (a hang that repeats ends in safe mode too). A plain `systemctl restart` is a stop, which never
  fails the unit and would never reach safe mode (review of 2c0bd74, finding 3). Hyprland's ANR pings xdg toplevels only;
  the shell's surfaces are layer surfaces and get no ping: nothing else can see a frozen shell. The probe reads, never
  unlocks; a restart while locked keeps the compositor's lock (L1).
- **6b. The extension after a crash** (SQ-6, option A): `compositor.lua` reads, at the first parse, whether a Hyprland
  crash report newer than the last login names `grassfield-compositor` (the report's path and shape are read from the
  installed Hyprland, data; `coredumpctl` is the fallback); if so it loads nothing, writes why in the runtime note, and
  the shell posts "The compositor extension was turned off after a crash" with "Turn On Again" (Settings > Desktop &
  Dock > Windows). One login without the extension, never a silent permanent loss.
- Proof: a dev-only hook blocks the GUI thread 20 s → the probe restarts the shell within 100 s, the lock kept; a
  nested Hyprland crash with the plugin loaded (the C1 soak's own crash classification) → the next nested start loads
  no extension and shows the notice; `abi_mismatch.sh` unchanged.
- Tests: the probe's logic on a fake `qs` and `systemctl`; `tests/shell/compositor_rebuild.sh` gains the crash-report
  case; the hook under `qs` offscreen.
- Integrator, nested: both proofs. Owner, real session: nothing specific.
- Review: security (the probe restarts the process that holds the lock; the dev hook's gate); R13 for `compositor.lua`.

### Step 6a as built (2026-11-02, the branch of the stability lane; the liveness probe)
- `packaging/systemd/grassfield-shell-watchdog.timer`: `OnActiveSec=30s`, `OnUnitActiveSec=30s`, `AccuracySec=1s`
  (systemd's default of a minute would let the probes slide up to a minute late), session-only (`ConditionEnvironment`,
  `PartOf`/`Requisite=graphical-session.target`), started by `autostart.lua` with the session's other units and installed
  by the PKGBUILD. It starts `grassfield-shell-watchdog.service` (oneshot, hardened as the failure counter: AF_UNIX only,
  `ProtectSystem=strict`, `ReadWritePaths=%t`, no network, Quickshell's option variables cleared, the runtime directory
  kept, 45 s start timeout, 128M and 16 tasks for the qs binary it runs), which runs
  `packaging/bin/grassfield-shell-watchdog`.
- The question is the planned one, `capabilities status` on the shell's system path, and nothing in its answer is read:
  any answer, the `refused` the dev gate gives in a real session included, is the GUI thread answering (the IPC handlers
  run there). So the function keeps its dev gate and nothing new is exposed; the IPC surface table names the caller. The
  inventory accepts a session helper asking a dev function (it rejects only an action without a caller, a dev function
  without its gate and a caller of a function that does not exist).
- A miss is a question that ran into its 5 s bound (timeout's 124, or 137 once its KILL followed) and took that long. A
  question that fails at once (no instance yet, a refused connection, a qs killed early by the unit's memory limit) or
  just under the bound with an error is no evidence of a hang and counts nothing. The misses belong to one MainPID (the
  state file `$XDG_RUNTIME_DIR/grassfield/shell-watchdog`, "<pid> <misses>", 0600, replaced by a rename, never written
  through a link): a shell that restarted between two questions or during one starts from zero; an answer forgets them.
  Nothing is asked while the unit is not active/running, nor once the compositor is gone (`session-gone`, as the failure
  counter asks).
- The third miss in a row sends SIGKILL to the hung main process only (`systemctl --user kill --kill-whom=main
  --signal=SIGKILL grassfield-shell.service`, the plan's kill narrowed to the main process): the unit fails, Restart=always
  brings the shell back within a second, OnFailure= arms the sleep lock and runs step 1a's counter (a hang that repeats
  ends in the loop detector's stop); the unit's other processes get the restart's usual SIGTERM. The probe never stops,
  restarts, starts or unlocks anything, and no environment variable moves its bounds.
- Timing: the third miss comes 60 s after the first at the earliest, so a stall shorter than about 65 s is never killed,
  and one longer than about 95 s (the first question up to 30 s after it began, plus 60 s, plus the 5 s bound) always is.
  The plan's proof ("blocks the GUI thread 20 s → restart within 100 s") cannot hold as written: 20 s gives one miss at
  most. The dev hook is `capabilities devBlock <seconds>` (1 to 300, `Mode.dev`, `refused` otherwise): the nested proof is
  `devBlock 120` (the shell restarted within 100 s, the lock kept) and `devBlock 20` (no restart: a long but finite stall
  survives).
- Tests: `tests/shell/shell_watchdog.sh` (logic; the helper's scratch copy against a fake `qs` that answers, hangs, fails at
  once, fails just under the bound, is killed at once or sees a restart during the question, and a fake `systemctl` that
  reports the unit's state and logs every call: alive, two misses kept, an answer forgets them, the third miss kills once
  with the exact command and nothing else, another MainPID starts from zero, a unit not running asks nothing, the session's
  end asks nothing, a link at the state's path is not followed, the file modes; 23 cases, about 45 s);
  `tests/shell/shell_watchdog_hook.sh` (headless: the real `Capabilities` offscreen answers, `devBlock 4` holds the thread
  so a 2 s question times out, then it answers again; outside a dev session `devBlock` is refused at once and `status`
  answers `refused`); `tests/shell/session_services.sh` (the two units, the autostart and PKGBUILD lines).
- Evidence (this container; no Quickshell, no systemd user manager): `shell_watchdog.sh` exit 0 (23 PASS) and five mutants
  of the helper caught (the threshold at 2, no exit-code guard, no elapsed-time guard, no restart check after the
  question, a `systemctl restart` instead of the kill); `session_services.sh` exit 0; `shell_unit.sh` exit 0 (the qs caller
  scan); the IPC inventory's reading of the caller and the row simulated (the helper calls `capabilities status`, the table
  and the handler both name `status, devBlock`); inventory ok; i18n 0 bare literals; isolation ok; qmllint 6.4 parses
  `Capabilities.qml` and the probe; `sh -n`; `git diff --check` clean. NOT VERIFIED here: `shell_watchdog_hook.sh` (no
  Quickshell: SKIP), `ipc_inventory.sh` end to end (Qt's tools), the units under systemd (the timer's cadence, the
  service's sandbox against the qs binary and the user manager), the nested proof.
- Review: opus security (the probe kills the process that holds the lock; the dev hook's gate); the integrator's nested
  pass: `devBlock 120` → a restart within 100 s with the lock kept, `devBlock 20` → none.
- Review round 1 (2026-11-02, PR #106, the integrator's opus review of f01a0b9f with a security lens: FAIL on its new
  test; the probe itself held: only the shell's main process, a kill while locked fails closed, the thresholds, off in dev
  and nested sessions). MAJOR: `shell_watchdog_hook.sh` set `rc` inside a command substitution, so `set -u` stopped it at
  the first check on any machine with Quickshell: the answers go to a file now, `rc` stays in the test's shell (the
  plumbing run against a Quickshell stand-in passes, and fails when the stand-in's hook does not hold the thread; with
  Quickshell itself NOT VERIFIED here). MINOR, load: the 5 s bound includes starting the qs client, so on a loaded machine
  a healthy shell could miss three times and that kill would count toward the loop detector: while `/proc/pressure/cpu`
  `some avg10` is 40 % or more, or memory's 10 % or more, the bound is 20 s (the service's start timeout 45 s). Extended,
  never skipped: a shell spinning in a loop raises the pressure itself on a small machine and must still be found
  (`GRASSFIELD_SHELL_WATCHDOG_PRESSURE` points the tests at fixture files; the unit clears it). NIT: the MainPID is read
  once more right before the kill; a shell that restarted since is not killed. `shell_watchdog.sh` 27 cases; mutants
  caught: no extension, skipping under load, no read before the kill.

### Step 7: the known incidents as regressions, and the two open ones (T-8, I-2, I-3, I-4, I-5)
- A package-upgrade simulation in nested: replace the installed-layout copy of `config/hypr` under a running session
  (unlink and recreate, as pacman does), then reload: no error bar, every bind present (I-2's proof made repeatable).
- `tst_wallclock` gains the spring-forward night (the skipped hour): no freeze, no spin; `wall_clock_only.sh` stays.
- The portal's 25 s (I-4), RESOLVED 2026-11-08 (the paragraph after this one is the original plan, kept for the record).
  Measured: `GTK_USE_PORTAL` was not the cause (x-d-p-gtk 1.15.3 calls `g_unsetenv("GTK_USE_PORTAL")` right before
  `gtk_init`, read in its disassembly; an earlier private-bus run, with no ScreenSaver owner on it,
  was ready in 0.4 s with it set). The cause: x-d-p-gtk's `OrgFreedesktopScreenSaverProxy` (gdbus-codegen) calls
  `org.freedesktop.DBus.Properties.GetAll` on `org.freedesktop.ScreenSaver`, which grassfield-menu-bridge owns
  (since 0c818dc9), and `ScreenSaverObject::handleMessage` dropped every call but Inhibit and UnInhibit without a reply,
  so x-d-p-gtk (and with it the frontend, which waits for its name) waited out D-Bus's 25 s method timeout (live probe:
  `busctl --user --timeout=3 call ... Properties GetAll s org.freedesktop.ScreenSaver` timed out, `Peer.Ping`
  answered). Fix: every virtual object of the bridge answers every method call (empty `GetAll`, `UnknownProperty`,
  `UnknownInterface`, `UnknownMethod`; docs/specs/menu-bridge.md MB14); proof: `tests/unit/menu-bridge/tst_screensaver.cpp`
  and `tests/integration/portal_screensaver.sh` (real frontend, real x-d-p-gtk, the bridge on a private bus). No drop-in
  is shipped. Original plan: the owner runs `systemctl --user show-environment | grep GTK_USE_PORTAL` and
  `journalctl --user -b -u xdg-desktop-portal-gtk -u xdg-desktop-portal -o short-monotonic` (read-only, provided as a
  script `docs/audits/stability-2026-10-29/owner-checks.sh`); if the hypothesis holds (x-d-p-gtk inherits
  `GTK_USE_PORTAL=1` and waits out D-Bus's 25 s method timeout on itself), the fix is one packaged drop-in,
  `xdg-desktop-portal-gtk.service.d/10-grassfield.conf` with `UnsetEnvironment=GTK_USE_PORTAL`, checked by
  `tests/integration/portal_settings.sh` on the private bus with the real x-d-p-gtk; if it does not, the measurement
  says what does.
- The Store's stale-database wording (I-5): the messages asked on PR #36 are settled in that lane; this ADR adds only
  the chaos row (a Store operation in flight when the Store is killed shows its outcome at the next start).
- `tests/ci/socket_errors.py` stays; the r7 proof of I-1 becomes a container case of step 2c (Quickshell from the rc
  mirror).
- Proof, tests, integrator: each item names its own; owner: the portal measurement.
- Review: the integrator; ADR-0035's owner for the drop-in.

### Step 8: crash reports, local only (SQ-4, M-1, M-6)
- With option A: the crash watcher's notice gains a second action, "Show Report", which writes
  `$XDG_STATE_HOME/grassfield/crash-reports/<app>-<time>.txt` (0600; `coredumpctl info` of that dump, the signal, the
  executable, the time, the Grassfield and toolkit versions; never the core itself) and opens it in a Grassfield text
  window of the system dialogs (ADR-0035) with Copy and Close. Nothing is sent anywhere, ever (`PrivateNetwork=yes` stays
  on the watcher); at most 32 reports are kept, the oldest removed.
- Proof: `tests/shell/crash_watch.sh` gains the action and the file; a capture of the window (en, fr).
- Review: the integrator; security for the new window (it shows untrusted text: plain `textFormat`, the existing rule
  of `scripts/dev/check-textformat.py`).

### Step 5 as built, first part (2026-10-29, branch of the stability lane; the readers that need no Qt)
- `compositor/tests/ParserFuzzTest.cpp`: an in-tree mutator (xorshift seed, twelve operations: bit flips, special bytes,
  dictionary tokens, deleted, duplicated and swapped slices, truncation, number extremes, nesting, splices, growth past
  the cap, raw bytes) over every core reader of untrusted text: `overview::parseRequest`, `overviewfocus::parseRequest`,
  `stages::parseRequest`, `tiling::parseArrange`, `minimize::parseAddress`, the config readers (`parseAppearance`,
  `parseDoubleClickAction`, `parseEffect`, `parseStagesEnabled`, `switchOf` + `parseBool`, `parsePlace`, `outputNameOk`,
  `isFunnelShaderFault` outside a dev session), `appmenu::isValidBusName/ObjectPath/Address`, `json::CReader`,
  `gfc::jsonEscape` (a round trip through the reader) and `stages::sanitizedText`. Properties: no crash, two reads agree,
  at most 50 ms per call and 2 ms on average, and on an accepted input every invariant of the header (caps, distinct
  addresses, finite numbers, ranges, name grammars, the catalogue). 2000 iterations per parser in the suite,
  `GF_FUZZ_ITERATIONS` for more, `GF_FUZZ_SEED` for another seed. `compositor/build-direct.sh tests-asan` builds the suite
  with ASan and UBSan without Hyprland's headers (the `tests` mode no longer needs them either); `scripts/dev/test.sh`
  runs that binary when it exists; `scripts/gates/release-check.sh` gains the step `comp-asan` (50 000 iterations).
- `tests/fuzz/mutate.py` (the same mutator in Python, with a self-test), `tests/fuzz/fuzz_helpers.py` and its runner
  `tests/fuzz/helpers_fuzz.sh` (inventory layer `logic`): `grassfield-crash-watch` (the four real journal fixtures with
  mutated text and values, desktop entries, `cgroup.events`, locale names), `grassfield-session-end` (`hyprctl -j
  clients`), `grassfield-battery-watch` (sysfs), the ANR stand-in's client matcher, the `lock status` filter of the
  `omarchy-shell` stand-in and `sleep-lock-gate`; each with its contract and a corpus sanity check (the seeds must be
  accepted or decided as the contract says, so the accepting path is proven to run).
- Findings, each fixed with a deterministic regression case:
  1. `grassfield-crash-watch` `scope_state`: a `cgroup.events` that is not UTF-8 raised `UnicodeDecodeError`, a
     `populated` line without its value raised `IndexError` (seed 1, iterations 1 and 23). The worker thread caught the
     exception, but the candidate then stayed pending and was looked at again every poll, its deadline never reached.
     Now "unknown" (a bounded, replacement-decoded read); cases in `tests/shell/crash_watch.sh`. The kernel never writes
     such a file: a robustness defect, not a user-visible one.
  2. `omarchy-shell lock status`: jq's `index("LOCK")` on a string finds a substring and `.[]` walks an object's values
     like an array's, so a monitor whose `solitaryBlockedBy` were a string such as `"UNLOCKED"`, or an object of
     monitors, read as secure. Hyprland 0.56.2 always answers an array of objects with an array; the filter now requires
     both arrays (fail closed on any other shape); cases in `tests/security/sleep_lock_units.sh`. **The stand-in is the
     sleep-lock fail-safe (D-12, SEC-02): this hunk needs the opus security review before the merge.**
  3. The harness's own first version had three wrong oracles (an address prefix `0X` the parser accepts, a UTF-8 demand
     the JSON reader never promised, a quote check that counted `\"`) and one dangling `string_view`; they are fixed in
     the harness, not in the product, and are named here so a reviewer does not take them for product findings.
- Evidence (Ubuntu 24.04 container, g++ 13.3, gtest 1.14; no Qt, no Quickshell, no Hyprland headers):
  `compositor/build-direct.sh tests` → 468 tests passed (457 before); `tests-asan` → 468 passed; `GF_FUZZ_ITERATIONS=100000`
  on the sanitized binary → 11 fuzz tests passed, 1.1 million inputs, worst call 10.8 ms (`sanitizedText` on 2 KiB),
  15.5 s in all; `tests/fuzz/helpers_fuzz.sh` → PASS at 1500 and at 20 000 iterations (crash-watch 8909 of 20 000
  accepted, session-end 2396, battery 3568, ANR matcher 397, lock status 83 of 4000, sleep-lock gate 2567 of 4000);
  `tests/security/sleep_lock_units.sh` exit 0; `tests/shell/crash_watch.sh` exit 0; `python3 -I tests/ci/inventory.py`
  ok (570 tests). `clang-tidy` could not run here (the container's clang 18 has no `std::expected` with libstdc++ 13);
  the two lints it did report on the test file (an embedded NUL literal, adjacent literals) are fixed. The owner's
  machine runs `just check-tidy`.
- Not in this part (needs Qt or Quickshell offscreen): the shell's QML and JS readers, the bridge, Activity Monitor, the
  Store (`docs/testing/README.md` "Fuzzing" lists them).
- Review round 1 (2026-10-30; the integrator's independent opus security review of 265e6c7: FAIL, two majors, four minors,
  three nits; each answered with a new commit on the same branch):
  1. Major: `jq -e` without `-s` decides on the LAST of several JSON values, so `[unlocked] [locked]` and
     `4294967296[locked]` read as secure (the harness itself finds the second at 10 000 iterations). The filter now
     slurps and demands exactly one value (`jq -e -s 'length == 1 and (.[0] | ...)'`); both inputs, a scalar after a
     locked array and an empty answer are cases of `tests/security/sleep_lock_units.sh` and of the harness's corpus
     checks. The fail-closed claim holds again: anything but one array of objects each listing LOCK is not secure.
  2. Major: a scenario's seed came from `hash(name)`, which is randomised per process and which `python3 -I` cannot pin
     (it ignores PYTHONHASHSEED), so two runs of one seed mutated different inputs (58 and 49 accepted of 300 here with
     the old seed). Now `zlib.crc32(name)`; `helpers_fuzz.sh` ends with two runs of one seed that must print the same
     counts, and `GF_FUZZ_TRACE=1` prints a finding's whole traceback.
  3. Minor: the lock status oracle read a lone surrogate escape where jq 1.7 and 1.8 refuse it (a false finding, fail
     closed). The oracle now answers "either" for a locked shape jq may refuse (a lone surrogate, nesting past jq's 256
     levels) and skips a leading byte order mark as jq does.
  4. Minor: "every reader" claimed too much. `grassfield-update-check` is fuzzed now (checkupdates' and pacman's output,
     vercmp's answer, its failures and last-success files, the release notes, pacman.conf and the repository file, with
     stub children so nothing runs): its reading of `{"first": 1e999}` raised OverflowError (a defect that predates this
     change), and a time the program never wrote (negative, beyond tomorrow, a bool, a string) now starts a fresh
     episode instead of a raise or an unrepresentable `retryAt`; a notes document nested past Python's recursion limit
     is "nested too deep" (a ValueError its caller catches) rather than an uncaught RecursionError. The four name readers
     (`isGrassfieldNamespace`, `classifyLayer`, `splitZone`, `capabilityCandidate`) are fuzzed against their headers.
  5. Minor: `helpers_fuzz.sh` inherited the caller's session (HYPRLAND_INSTANCE_SIGNATURE, D-Bus). It now starts the
     harness without DISPLAY, WAYLAND_DISPLAY, HYPRLAND_INSTANCE_SIGNATURE and the D-Bus addresses, with every home under
     its scratch directory (as `scripts/dev/isolated.sh` starts a client), and the harness drops them itself on a direct
     run: the owner's session is never reachable from a test.
  6. Minor: the 50 ms bound was wall-clock time (18.3 ms seen under ASan on a loaded machine). The bound is CPU time of
     the thread now: 50 ms per call and 2 ms on average, 200 ms and 8 ms under the sanitizers (`__SANITIZE_ADDRESS__`,
     or clang's `__has_feature`).
  7. Nits: the trailing blank line of `docs/testing/README.md` (`git diff --check` clean); the parser without its "a
     window is given twice" check survived 2000 iterations (killed at 8312): the arrange test now copies one quoted
     token over another in one input of four, and that mutant dies at iteration 29; two `scope_state` guards
     covered each other: three cases (a stray byte on a later line, the populated line after a frozen one, a directory
     in the file's place) and four mutants of `scope_state` in `tests/shell/crash_watch.sh` tell each guard apart.
  8. Found by this round's long run (the new seeds mutate other inputs): `grassfield-session-end` matched a window
     address with `^0x[0-9a-fA-F]+$` and `re.match`, and `$` also matches before a trailing newline, so an address
     `0x1\n` from a `hyprctl -j clients` answer went into the Lua close expression (seed 1, iteration 19129 of 20 000).
     Now `fullmatch` on `0x[0-9a-fA-F]{1,16}`; a case in `tests/shell/session_end.sh`. The same slip in
     `grassfield-update-check`'s version and date checks of the notes is fixed the same way (the harness's oracle shared
     the regex, so it is not a harness finding).
- Evidence of the round (same container): `compositor/build-direct.sh tests` and `tests-asan` → 479 tests passed each
  (14 fuzz tests, 11 before); the sanitized fuzz tests at 2000 iterations: worst call 0.33 ms of CPU time
  (`gfc.jsonEscape`; 0.54 ms on a first, loaded run); `tests/fuzz/helpers_fuzz.sh` → PASS at 1500 (update-check 172 of 1500 accepted,
  determinism PASS) and at 20 000 (crash-watch 8801 of 20 000 accepted, session-end 2434, battery 3552, ANR matcher 390, lock status 77 of
  4000, sleep-lock gate 2546 of 4000, update-check 2163); `tests/security/sleep_lock_units.sh` exit 0 (the four new stand-in
  cases pass); `tests/shell/session_end.sh` exit 0 (36 PASS); `tests/shell/crash_watch.sh`: 69 PASS, the four new mutants caught, the one pre-existing timing check
  fails here as on main; `python3 -I tests/ci/inventory.py` ok (576); `git diff --check` clean. Still NOT run here:
  `clang-tidy` (`just check-tidy` on the owner's machine).
- Merged 2026-10-30 as c9058737 (the opus security re-review PASS: 49 edge inputs on the shim, 12 of 12 shim mutants
  killed, 484 tests on the merged tree). The merge review's follow-ups, done in front of S1's pull request:
  1. Minor: `tests/shell/crash_watch.sh`'s `mutate()` passed silently when a mutant's pattern was gone from the helper
     (the Python assert failed, the mutant file was never written, no decision line matched, "caught"): the
     ignore-populated-flag mutant had been stale since 1b359f40. A missing pattern now fails the test, the mutant
     follows the code, and a self-check mutates a pattern that is not there.
  2. Nit: the lock status oracle read the bytes with Python's json, which refuses number tokens jq reads (`nan`, `inf`,
     `+1`, `01`, `.5`, `5.`). The oracle now judges the shape on jq's own reading (`jq -c .`), so every lexical
     difference (surrogates, nesting, the byte order mark, those tokens) is decided as jq decides it, and the "either"
     verdict goes; seven such inputs are corpus checks.
  3. Nit: the `{1,16}` of the address grammar: `tests/shell/session_end.sh` closes a 16-digit address and never
     dispatches a 17-digit one; the harness's contract carries the bound.
  4. Nit: two timing-sensitive cases of `session_end.sh` failed at load 35: the retried-first-query case waits up to
     15 s instead of 3 (the run still ends as soon as the window is gone), and the second-run case waits until the
     holder really has the lock (at most 5 s) instead of sleeping 0.5 s.

### Delivery order and what each step waits for
| Step | Waits for | Pull requests |
|---|---|---|
| 1 | answered (SQ-1 B, SQ-2 A): 1a now; S1 after the merge of step 0; then S2, S3, S4 in that order | 1a; S1; S2; S3; S4 |
| 2 | SQ-3 and the repository's publication (2a); 2b, 2c and 2d can start now | 2a; 2b; 2c; 2d |
| 3 | step 1 for the loop rows; the rest now | 1 |
| 4 | nothing | 1 or 2 (the fix of a found leak apart) |
| 5 | nothing | 1 or 2 |
| 6 | answered (SQ-5 A, SQ-6 A) | 6a, 6b |
| 7 | the owner's portal measurement (7c) | 1 |
| 8 | answered (SQ-4 A) | 1 |

## New units, packages and dependencies (R5)
| Item | Kind | Justification | Decided by |
|---|---|---|---|
| `grassfield-shell-failed.service` | a `Type=oneshot` user unit, a POSIX sh script | systemd counts starts, not failures, and cannot see a lifetime; nothing but the `OnFailure=` path sees each failure as it happens; it runs for a moment, never a daemon | step 1a (SQ-2 sets its numbers) |
| `grassfield-security.service` | a second Quickshell process (the same `qs` binary, the root `shell/security.qml`) and its user unit | the owner's SQ-1 B (ADR-0010's direction, GF-050): the lock, polkit, idle and the inhibitor apart from the UI, as loginwindow is apart from the Dock; its memory and start time measured at S1 against P2 and P5 | SQ-1 B (owner, 2026-10-29) |
| `grassfield-hold` and `grassfield-unhold` | two split packages with `depends`, `provides` and `conflicts` only | the only mechanism pacman offers that refuses on every path and can be undone in one transaction; no code, no service; shipped only once the `[grassfield]` repository is published | SQ-3 |
| the checker's toolkit comparison | no new unit: a read-only step of the shell's existing update checker, as the user | learns on every path that the toolkit moved under the session, with nothing run as root (ADR-0009:112; review of 2c0bd74 dropped the alpm hook of the first version) | step 2b |
| `grassfield-shell-watchdog.timer` | a user timer and a `Type=oneshot` unit | a frozen shell is otherwise invisible; a timer runs no daemon; Quickshell offers no `sd_notify` watchdog (NOT VERIFIED: the step checks `qs --help`) | SQ-5 |
| `tests/fuzz/` | test code, no runtime dependency | ASan/UBSan builds exist; the mutator is in-tree | step 5 |
| No new runtime dependency | — | every program named above is in the session's `depends` already (`systemd`, `pacman`, `polkit`, `coreutils`, `jq` through the stand-in's existing use) | — |

## Owner decisions (2026-10-29, asked by the integrator; recorded from PR #50)
| Question | The owner's choice | Option |
|---|---|---|
| SQ-1 safe mode | « Processus sécurité séparé » | **B**: ADR-0010's separate security process now: the lock, polkit, idle and the sleep inhibitor always run apart from the UI; safe mode is "the UI unit failed, the security process is up" (S1-S4 after the review of f018b42: everything that locks moves together at S2) |
| SQ-2 the loop detector | « 3 plantages en 10 min » | **A** (recommended) |
| SQ-3 an untested toolkit | « Détecter maintenant, bloquer plus tard » | **B now, A after the `[grassfield]` repository is published** (recommended); **A activated by the owner on 2026-11-08**, built in step 2a as built |
| SQ-4 crash reports | « Afficher le rapport » | **A** (recommended) |
| SQ-5 a frozen shell | « Sonde toutes les 30 s » | **A** (recommended) |
| SQ-6 the extension after a compositor crash | « La couper si elle est en cause » | **A** (recommended) |

Integrator decisions under the owner's rule that come with SQ-1 B (the closest to macOS, no technical step for the end
user): step 1 is rewritten around ADR-0010's plan as S1-S4, each S-step its own pull request under the opus security review,
every intermediate state keeping "failures stay locked"; the order is 1a first (independent, it stops a slow loop today),
then the security process (its unit first with nothing moved yet, then the lock with idle and the sleep inhibitor
together and every `Lock.lock` caller switched in the same step, then the polkit agent: the review of f018b42 merged
the idle step into the lock's, since a lock moved alone left the UI's inhibitor unable to lock while the security
process restarts), safe mode last; the UI keeps refusing while locked from state it receives and treats "no state yet",
a stale heartbeat, a stopped security unit or the compositor's own lock signal as locked; the second Qt Quick process's memory and start time are measured at S1 and recorded against the budgets; IQ-T5
(ADR-0040) still applies to a crash of the security process itself; ADR-0010 is amended to carry the decision.

## Owner questions
Answered on 2026-10-29 (above); the options stay as they were asked.


**SQ-1. The shape of safe mode** (step 1; the brief requires one; it reverses nothing decided). Answered: B (owner, 2026-10-29). Both A and B are
security modules under R12; the compositor keeps the lock in every option (SP-1).
| Option | For | Against |
|---|---|---|
| **A. A safe configuration of the same shell tree: `GRASSFIELD_SAFE_MODE=1` loads only the lock, the polkit agent, idle, the sleep inhibitor, plain banners and a one-strip bar (Try Again, Log Out, Restart, Shut Down) (recommended)** | small (one root file, two unit files); the reviewed security modules unchanged; no second process in normal use; the IPC path, the bindings, the lid helper and the stand-in need no change; it avoids the request sockets where the 2026-10-29 crash lived; it is ADR-0010's S2 root in all but name, so it is a step toward B | it shares Quickshell with the full shell: a bug in Quickshell's lock or monitor code crashes it too (the compositor then keeps the lock: fail closed, out of reach); the sleep-lock gate and the stand-in learn a second unit name |
| B. ADR-0010's separate security process now (S1-S5): the lock, polkit, idle and sleep inhibitor always run apart from the UI; safe mode is "the UI unit failed, the security process is up" | the macOS model (loginwindow apart from the Dock): no lock restart on any UI crash, no red screen ever, the crash loop never touches the lock | ADR-0010 rated it not low-risk: the IPC contract moves, the lock state must cross processes (a missed push fails the UI's refusals open), `LockView` still imports UI, a second Qt Quick process's memory is unmeasured; five reviewed steps before any safe mode exists |
| C. No safe mode: raise the start limit so a slow loop stops; the compositor keeps the lock (red screen), Omarchy's sleep-lock covers sleep; the user logs out from a TTY | nothing to build beyond 1a | the brief is not met; a locked session cannot be unlocked by the user: a lock-out that needs a technical step |

**SQ-2. When the loop detector trips** (step 1a). Today: 10 starts in 30 s, which a crash slower than 2.0 s per cycle
never reaches (audit 1.2).
| Option | For | Against |
|---|---|---|
| **A. A failure counter in the `OnFailure=` path: 3 failures within 10 minutes enter safe mode; systemd's start limit raised to 10 starts in 5 minutes as the backstop (recommended)** | counts failures, not starts: a deliberate `systemctl --user restart` never counts; catches a 5 s loop in about 20 s and a 3-minute loop in under 10 minutes; a single crash a day never trips | one more small unit (justified above); two numbers to document |
| B. systemd's start limit alone, raised to 10 starts in 5 minutes; safe mode at the limit | one mechanism, systemd's own | a 25 s loop takes 4.5 minutes to stop, a 40 s loop never; manual restarts count toward it; the limit counts starts of the safe unit too unless split |
| C. Keep 10 in 30 s; safe mode at the limit | nothing changes for fast loops | every loop slower than 2.0 s per cycle, the 2026-10-29 one included, goes on for ever |

**SQ-3. How an untested toolkit is kept out of the session** (step 2a; it revisits ADR-0033 s3.4's rejection of
versioned bounds with a removable shape). "Never" is only reachable with a pacman-level refusal; its price is the lag
between Omarchy moving and Grassfield publishing. Rewritten after the review of 2c0bd74 (MAJOR 1): each option is now
mechanically possible, and a hold before the `[grassfield]` repository publishes (ADR-0033 h) would refuse every system
update with no end, so A waits for the publication and B is the floor under it. The reviewer recommends B now and A after
the publication; so does this ADR.
| Option | For | Against |
|---|---|---|
| **B. Now, and the floor under A: detection on every path. The user-side comparison with `BUILD-DEPS` (step 2b) says "Log out to finish updating" after any transaction that moved the toolkit; Update Now keeps the U27 check; `conflicts` on versions found bad after the fact; no hold before the repository exists (recommended now)** | never blocks a security fix; nothing runs as root; no new package; ships without an owner answer | it detects, it does not prevent: on the terminal path the incident can happen again, and the user learns after the reboot, from a crash-looping shell (safe mode then catches it: step 1) |
| **A. Once the repository is published: the hold pair. `grassfield-hold` (`quickshell` at the exact built version, `qt6-base` at its major.minor; never `hyprland`, never `kcoreaddons`), which `grassfield-desktop` depends on, and its empty twin `grassfield-unhold` (`provides` the same name, `conflicts` with it, no bound); "Allow system updates Grassfield hasn't tested…" swaps them in one root transaction through the channel helper's polkit action, "Hold again" swaps them back; the watch job builds against Omarchy's rc channel ahead of stable (recommended after the publication)** | literally never an incompatible combination, on every path, transactionally (nothing half-installed); the matching Grassfield build joins the same transaction; a non-technical exit and return; the 2026-10-29 incident becomes a refused update with the session's own sentence | while Grassfield lags, every system update, Arch's security fixes included, is refused on every path; `omarchy update` in a terminal shows pacman's dependency error (the session's notice says it plainly); two more packages; depends on the watch job being run (ADR-0033 f, disabled while nothing is published) |
| C. `IgnorePkg` lines for the toolkit written by the channel helper | refuses the toolkit only, the rest of the update goes through | a partial upgrade: Arch does not support it (Qt modules and KF6 libraries move together; a mismatch breaks every Qt app, not only Grassfield's); `omarchy update` prints warnings; rejected unless the owner wants it anyway |

**SQ-4. Crash reports** (step 8). macOS keeps them locally and asks before sending any; Grassfield sends nothing.
| Option | For | Against |
|---|---|---|
| **A. The notice gains "Show Report": the local report (text, never the core) opens in a Grassfield window with Copy; nothing is sent; the notice's body no longer names `coredumpctl list` (the reviewer's note on 2c0bd74) (recommended)** | the macOS "Report…" without the sending; the user can paste it into an issue by hand; small (the watcher already has the dump id); no command in the user's face | one more window to review (untrusted text, plain format) |
| B. A crash reporter window like macOS's (Ignore, Report, Reopen) instead of the notice | the exact model | a window that steals attention for every crash, where macOS users expect it but the brief asked for notices; more UI, same data |
| C. Today: the notice with Reopen, `coredumpctl list` named in its body | nothing to build | the body names a command (a technical step, SP-6) |

**SQ-5. Hang detection for the shell** (step 6a). Nothing sees a frozen shell today; `CPUQuota` only keeps the
compositor usable.
| Option | For | Against |
|---|---|---|
| **A. A liveness probe: a user timer every 30 s asks the shell over IPC with a 5 s timeout; three misses kill it with SIGKILL through systemd, so the unit fails and restarts (the lock kept by the compositor), counted by the loop detector: a hang that repeats ends in safe mode (recommended)** | the only observer that is not the shell; no daemon (a timer); 100 s worst case before a frozen desktop comes back | a false restart if the shell is busy for 15 s (a huge Overview under load): the restart is harmless while unlocked, and a red screen while locked (IQ-T5); one more unit |
| B. The compositor extension pings the shell and restarts it | no timer | nested-only by rule (R13), must degrade: no detection without the extension; a restart from inside the compositor is the wrong place for a security decision |
| C. None | nothing to build | a frozen shell stays frozen until the user logs out from a TTY |

**SQ-6. The compositor extension at the login after a compositor crash** (step 6b). A crash inside Hyprland ends the
session whatever its cause; the question is the next login.
| Option | For | Against |
|---|---|---|
| **A. When the latest Hyprland crash report, newer than the last login, names `grassfield-compositor`, the next login loads no extension and says so once, with "Turn On Again" in Settings (recommended)** | the macOS model for a faulty extension; a repeated compositor crash never repeats; the user keeps a working desktop (degraded mode, C2) | a crash the plugin only witnessed (its frames in a stack it did not cause) also turns it off for one login; reading the report's shape depends on Hyprland (data, re-verified per version) |
| B. Always load it (today) | nothing changes; the C1-C3 gates are the defence | a plugin crash that repeats at every login ends every session until the user finds the setting |
| C. Turn it off after any compositor crash, named or not | simplest rule | most compositor crashes are not the plugin's (`docs/audits/final-1.0/09-reliability-audit.md:36`: 7 Hyprland dumps since 2026-10-20, all from nested sessions, 0 in a real session, none attributed); the user loses titlebars and minimize for no reason |

## Decisions taken under the owner's rule (2026-10-28: the closest to macOS 27, no technical step for the end user)
- **SD-1.** Crash reports stay on the machine; nothing is ever sent, with or without SQ-4. The watcher keeps
  `PrivateNetwork=yes`.
- **SD-2.** A process that restarts says nothing (macOS: the Dock relaunches silently); a process that cannot says so
  once, in the session's words, with one action. The shell and the services stay out of the "quit unexpectedly" notices
  (`packaging/bin/grassfield-crash-watch:9`); safe mode's bar and the journal carry the shell's case.
- **SD-3.** The hold, whatever SQ-3 decides, never constrains `hyprland` (ADR-0009: degraded mode and the rebuild).
- **SD-4.** Safe mode never unlocks by itself, never approves, never sleeps unlocked; its menu offers Try Again, Log Out,
  Restart and Shut Down and nothing else; its sentence is "Grassfield is running in safe mode: its desktop stopped
  working and was turned off." (French in the same pull request). Under SQ-1 B its bar is drawn by the security process
  (step 1, S4), with `Grassfield.Ui` only.
- **SD-5.** The chaos and endurance tests run in nested sessions only; the owner's real session gets a read-only check
  list per step (`docs/audits/stability-2026-10-29/owner-checks.sh` from step 7 on), never a driven test. The owner's own
  checks listed per step (step 1's kill of the shell, run by the owner's hand on the owner's machine) are owner-run
  checks, not driven tests (review of 2c0bd74).
- **SD-6.** Nothing of this ADR runs as root on its own after the package is installed, as ADR-0009's amendment says
  ("Nothing in the amended design runs as root after the package is installed",
  `docs/decisions/ADR-0009-plugin-distribution.md:112`): the toolkit change is detected as the user (2b) and every repair
  runs as the user at the next login or at the user's click. The only root code is what the user starts behind a polkit
  dialog: the existing helpers, which step 2a extends by two verbs (`hold`, `unhold`) and one reading of pacman's refusal,
  each under the opus security review (qualified after the review of 5a20d19).
- **SD-7.** The plan's order is the user's exposure: the loop and the lock first, the update second, the proofs third.
  A step's pull request may land before an earlier step's when it waits on an owner answer.
- **SD-8.** Every step adds its regression test to `tests/inventory.json` under its layer; a nested-only proof is
  marked `runner: bare` and recorded in `docs/testing/gates.md` with its date and commit (gates R1, L1, C2, P2, Q3).

## Consequences
- The session gains a second Quickshell process and its unit (the owner's SQ-1 B), one small oneshot unit and one timer,
  and two split packages once the repository is published, all listed above; no alpm hook, no new dependency, no new
  language.
- `grassfield-shell.service`'s start limit, `OnFailure=` list and the sleep-lock gate change under the security review;
  `tests/security/sleep_lock_units.sh` and `unit_restart_limits.sh` grow with them.
- ADR-0010's direction (a separate security process) becomes the decision: step 1 carries its plan as S1-S4; ADR-0010 is amended
  on 2026-10-29 to say so.
- ADR-0033 gains, if SQ-3 chooses A, an amendment that records the hold next to s3.4 and extends f's watch job.
- Known limits written into the specs: a Quickshell bug that takes the security process down in a loop (SQ-1 B); a compositor crash
  ends the session (P-1); while a hold lags, updates wait (SQ-3 A); a Store install may need a system update first (I-5).

## Evidence (this session, main b345334; read-only)
- `git log --oneline -5` → `b345334 Merge fix/hypr-upgrade-reload …`; `git branch --show-current` → `ccr-8628667e-2tyi1h`.
- The spot checks of `docs/audits/stability-2026-10-29/audit.md` section 6 (unit values, the loop arithmetic, the
  `conflicts` line, the tracked packages, the private Qt users, no fuzz harness, the sanitized builds, the inventory
  counts, the watcher's rules, the `GTK_USE_PORTAL` export, the memory slope, the Store's 404 reading, the incident record).
- No graphical session, no Quickshell, no Hyprland here: every runtime statement above is NOT VERIFIED.

## Review history
- **Integrator's opus review of 2c0bd74 (PR #50): FAIL, one MAJOR, eight MINORs, three NITs.** Holds: nothing unlocks or
  weakens the lock trio, IQ-T5 referenced only, nothing sent off the machine, the new units justified, owner-checks.sh
  read-only; its items 1, 2 and 5 run on the owner's machine (x-d-p-gtk 25.5 s, `GTK_USE_PORTAL=1` in the user manager,
  no drop-in: the evidence supports I-4's hypothesis, which stays NOT VERIFIED until the drop-in is tried, step 7;
  `hyprctl` not run, the owner's Hyprland is off-limits). Answered in the commits that
  follow 2c0bd74:
  - MAJOR 1, SQ-3's premise (a hold the desktop depends on cannot be removed with `-R`; one it does not depend on is never
    installed; a `kcoreaddons` bound refuses every monthly KF6; a hold before the repository publishes blocks every update
    with no end): SQ-3 rewritten with the hold pair (`grassfield-hold` / `grassfield-unhold`, `provides` + `conflicts`,
    swapped by the channel helper), `kcoreaddons` dropped, the hold tied to the publication, B recommended now and A after
    it, what the user sees on each path written (step 2a, audit 2.3).
  - MINOR 2, the start-limit arithmetic (the eleventh start is refused, L ≤ 2.0 s): audit 1.2 and its spot check, this
    ADR's finding 1 and SQ-2, STATE.
  - MINOR 3, a probe using `systemctl restart` never reaches safe mode: the probe kills with SIGKILL through systemd
    (step 6a, SQ-5 A).
  - MINOR 4, the Qt private-API risk (the portal links `GuiPrivate` through `files-core.cmake:48`; Quickshell imports 61
    private symbols): audit 2.2's Qt row and this ADR's finding 2.
  - MINOR 5, the bridge has systemd's default start limit (5 in 10 s): audit P-4.
  - MINOR 6, step 2b's root hook against ADR-0009:112 ("Nothing in the amended design runs as root after the package is
    installed"): the hook is gone; detection runs as the user in the shell's checker (step 2b, SD-6, the R5 table).
  - MINOR 7, "7 nested Hyprland dumps" sourced (`09-reliability-audit.md:36`) in SQ-6 C.
  - MINOR 8, the safe unit's `Restart=`, `OnFailure=` and start limit specified (then step 1b; the owner's SQ-1 B moved
    them to `grassfield-security.service`, step 1 S1 and S4).
  - MINOR 9, the extension notices name a command while `windows.rebuildExtension` is off: step 2d plans the notice's
    action; a known limit under SP-6 until then.
  - NITs: SD-5 and step 1's owner check agree (owner-run checks, not driven tests); STATE's note on #48/#49 says their
    keys (112 and 111 zeros) and that there is no collision; owner-checks.sh prints its "(none)" fallback.
  - The reviewer's opinions on the questions are recorded next to each (SQ-1 A once finding 8 is fixed, SQ-2 A, SQ-3 B now
    and A after the publication, SQ-4 A without `coredumpctl list` in the notice, SQ-5 A once finding 3 is fixed, SQ-6 A).
- **Integrator's re-review of 5a20d19: PASS, with doc MINORs and NITs to fix before the merge.** Every earlier finding
  fixed (MINOR 5 in part). Fixed in the commit that follows 5a20d19: the bridge's default limit can never be reached (at
  most 4 starts fit in 10 s with its growing delays; audit P-4); "Hold again" past the bounds is greyed with its reason
  and comes back with the next build (step 2a); the coordination row says 2d amends ADR-0009's "the notice gives the
  command"; Update Now's plan step exits 8 today, so the helper's reading of a hold refusal (exit 6, the U27 path) is
  named as a root-side change under the opus review (step 2a); M-7's "post-transaction marker" wording; SD-6 qualified
  (two root verbs behind polkit); I-4's evidence "supports" the hypothesis, which stays NOT VERIFIED. The reviewer could
  not run the hold pair's scratch-database check (the project's guard blocks package-install commands even with a
  temporary `--dbpath`): reasoned from libalpm and `vercmp`, `--ask 4` = `ALPM_QUESTION_CONFLICT_PKG`; step 2a's first
  container test decides. The integrator is asking the owner SQ-1 to SQ-6; the answers go on PR #50.
- **The owner's answers (2026-10-29, posted on PR #50 by the integrator):** SQ-1 B, SQ-2 A, SQ-3 B now and A after the
  publication, SQ-4 A, SQ-5 A, SQ-6 A, with the integrator's decisions under the owner's rule for SQ-1 B. Recorded in
  "Owner decisions"; step 1 rewritten around S1-S5 in the integrator's order (1a first, the process and its unit, then
  the lock, polkit, idle and the inhibitor one per step, safe mode last; the UI fails closed on missing or stale state;
  memory and start time measured at S1; IQ-T5 applies to the security process); the delivery table, the R5 table, SD-4
  and the consequences follow; ADR-0010 amended. Next: step 1a, then S1.
- **Integrator's re-review of f018b42 (opus): FAIL, one MAJOR in the step-1 plan (two states that could fail open), one
  NIT.** (a) A lost "locked" push with heartbeats still arriving left the UI's refusals open: the heartbeat now carries
  the state and a sequence number, and `SessionState.locked` is the pushed state OR the compositor's own lock signal
  (hyprland-lock-notify-v1, as `Clipboard.qml:28` already does) OR no state OR a stale heartbeat OR a security unit
  that is not active/running. (b) Between the lock's move and the inhibitor's, the UI's `Idle.qml:142` and
  `SleepInhibitor.qml:72, :84` (and `SystemMenu.qml:72`, `SessionState.requestLock`) still called `Lock.lock` in
  process, `OnFailure=` and the gate stayed keyed on the UI, so a sleep with the security process down went unlocked:
  idle and the inhibitor now move with the lock at S2 and every `Lock.lock` caller switches in that step; `OnFailure=`,
  the gate and the stand-in key on the security unit from S2; the invariant of every state is a table at the end of
  step 1. S-steps renumbered S1-S4 (safe mode S4); ADR-0010's amendment and STATE follow. NIT: the SQ-1 row now carries
  the whole sentence.
