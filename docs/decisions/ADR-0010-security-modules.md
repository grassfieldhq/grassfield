# ADR-0010: Security modules design (lock, polkit, idle)
Status: Accepted (owner delegation D-5, 2026-10-23; status before acceptance: Proposed); the separate security process of the amendment of 2026-10-24 (GF-050) is decided by the owner on 2026-10-29 (ADR-0041 SQ-1 B), its plan carried by ADR-0041 step 1 (amendment of 2026-10-29 below) · Date: 2026-10-17 · Decider: owner · Requires opus reviewer PASS per change (R12)

## Context
D2: grassfield-shell replaces omarchy-shell in the Grassfield session, including lock, polkit agent and
idle. R12 restricts building blocks to Quickshell `WlSessionLock`, `Pam`, `Polkit` and the existing PAM
service `omarchy-lock-password` (verified 2026-10-17: `pam_faillock deny=10 unlock_time=120` → `pam_unix`).
Reference implementations (MIT): `/usr/share/omarchy/shell/plugins/lock/Service.qml` (551 lines),
`plugins/polkit/PolkitAgent.qml` (392), `plugins/services/idle/Service.qml` (361).
Hyprland config sets `misc.allow_session_lock_restore = true` so a restarted shell can re-take a lock
whose client died (Omarchy relies on the same failsafe).

## Decision
**Lock** (`shell/security/lock/`)
- `WlSessionLock` + `PamContext { config: "omarchy-lock-password" }`; fingerprint `PamContext` only if
  `/etc/pam.d/omarchy-lock-fingerprint` exists.
- State machine: `unlocked → locking → locked → authenticating → locked|unlocked`. Only a PAM `success`
  result unlocks. Every error, timeout, crash or missing PAM service keeps or returns to `locked`.
- If the PAM service is missing, refuse to start a lock *only* when it would be unrecoverable: show a
  persistent error; never unlock to "fail open".
- Password lives only in the TextInput and the PAM response; cleared after each attempt and on lock.
- Lock surface shows clock, user avatar/name, password field; no notification content, no window thumbnails (L4).
- Engage from: idle timeout, `SUPER+CTRL+Q`, lid close and before sleep through a logind **delay** inhibitor
  (`org.freedesktop.login1.Manager.Inhibit("sleep", …, "delay")`), released after the lock surface is shown.
- Crash recovery: Hyprland keeps the session locked when the lock client dies (ext-session-lock); the
  systemd/uwsm restart of the shell re-acquires it (`allow_session_lock_restore`). Gate L1.

**Polkit** (`shell/security/polkit/`)
- `Quickshell.Services.Polkit` agent, registered once per session (refuse if another agent owns the session).
- Dialog shows action ID, message, program/command line details provided by polkit, identity selector.
- Never auto-approve; cancel and Escape cancel the request; the password field is cleared on every outcome.

**Idle** (`shell/security/idle/`)
- Quickshell idle notify: dim at T-10 s, lock at T (default 5 min), display off at T+60 s; respects
  `idle-inhibit` from apps (Quickshell IdleInhibitor/compositor protocol) and media playback inhibitors.

**Process**
- Each change: security tests L1–L5 in nested (§10), opus `reviewer` PASS, † items NOT VERIFIED until L2.
- Code adapted from Omarchy keeps the MIT attribution header.

## Consequences
- No PAM files, no setuid, no root services (R12).
- L3 (lock before suspend) can only be verified by the owner in L2.

## Amendment 2026-10-24 (GF-AUDIT-001 wave 3: GF-016, GF-116, GF-050)
**Idle inhibitors over D-Bus (GF-016 residual).** The idle module gains one input: `Idle.busInhibited`, fed in
`shell.qml` from `MenuBridge.screenSaverInhibited`, i.e. the menu bridge's report that applications hold
`org.freedesktop.ScreenSaver` cookies (ADR-0008 amendment of the same date). While it is true the idle monitor is not
armed (`IdleModel.idleArmed`): no dim, no idle lock. Nothing else reads it: `lock lock`, the lid, the lock before sleep, the
display power-off on the lock screen and every unlock path are unchanged, and it cannot unlock or hide anything. It fails
closed: anything but `true` counts as not inhibited, and the shell sets it false whenever no bridge is connected (a bridge
that dies or never starts leaves idle locking on). Accepted risk: a process of the user can keep the idle lock from firing
while it holds a cookie; it could already do so with the Wayland idle-inhibit protocol, and macOS power assertions behave
the same. The building blocks stay WlSessionLock + PamContext + Quickshell Polkit + Quickshell idle; the D-Bus service is
outside the security modules (the bridge), which only report one boolean.

**Nothing opens over the lock (GF-116).** Every shell surface refuses to open while `SessionState.locked` and closes when
it becomes true; the polkit sheet is held (not mapped, no keyboard) until the unlock and drops text typed before the lock
(docs/specs/security.md "Nothing opens over the lock"). The plugin's restore path is a compositor work item
(docs/specs/compositor.md "Work item GF-116").

**Separate security process (GF-050): analysed, not done in this slice; adopted as the direction, plan below.**
macOS keeps loginwindow (the lock screen and authorization) apart from the Dock and the menu bar, so a crash of the
desktop UI never takes the lock down. Today one Quickshell process, `grassfield-shell` (`Restart=always`, `RestartSec=1`),
hosts every surface and the lock, polkit agent and idle. When it dies while locked, Hyprland keeps the session locked
(ext-session-lock; its "lockscreen app died" screen) until the restarted shell takes the lock back (L1); when it dies while
unlocked, idle locking and the sleep inhibitor are gone until the restart, and Omarchy's sleep-lock unit covers a sleep
meanwhile (`OnFailure=`, GF-030). So the lock never fails open, but every UI crash costs a lock restart, and the process
that talks to PAM also runs the Dock, Overview, wallpaper, notifications and menus (the audit counted 64 dev-shell core
dumps, all UI).
A minimal `grassfield-security` Quickshell unit (Lock, AuthAgent, Idle and SleepInhibitor only) was evaluated against
this slice's bar ("only if low-risk"). It is not low-risk:
1. the IPC contract moves to another instance: Hyprland bindings, `grassfield-lid`, the `omarchy-shell` stand-in (`lock
   lock`/`lock status`, the D-12 fail-safe), screen corners (`qs ipc --pid <shell>`), the sleep-lock gate and `OnFailure=`
   (both keyed on `grassfield-shell`), packaging (PKGBUILD, another stream's file) and five security tests change at once;
2. the UI needs the lock state across processes (GF-116 refusals, "Show previews: When Unlocked", Overview, Switcher):
   Hyprland emits no lock event, so the security process must push it over Quickshell IPC, and a missed or stale push
   makes the UI refusals fail open (Hyprland still keeps input and rendering on the lock surface);
3. the lock surface draws the wallpaper (`LockView` imports `qs.desktop`), `SleepInhibitor` posts its notice through the
   UI's notification server and `Lock` closes the UI's popups: the module is not yet free of UI imports;
4. a second Qt Quick process costs memory (not measured).
Plan (next security milestone, each step reviewed and gated L1–L5):
- S1: make `shell/security/` free of UI imports: the lock backdrop through a `Grassfield.Ui` type; popups closed by the UI
  on `SessionState.locked` (done by GF-116, so `Lock.lock()`'s `Popups.close()` can go); the sleep notice through the
  notification server's public D-Bus interface;
- S2: `shell/security.qml` (a root next to `shell.qml`, as built at ADR-0041 S1), with Lock, AuthAgent and Idle only, run beside the UI in nested: one session lock
  owner, one polkit agent, memory measured;
- S3: IPC: the same target names on the security instance (`qs ipc -p /usr/share/grassfield/shell/security.qml …`); an action
  `lock state` (`unlocked`|`locked` only) the UI reads at start, plus a push from the security instance on every
  transition into the UI; the UI treats "no answer yet" as locked for its refusals; bindings, lid helper, stand-in and
  tests switch together;
- S4: `grassfield-security.service` (`Restart=always`, `RestartSec=1`, `PartOf=`/`Requisite=graphical-session.target`,
  `OnFailure=omarchy-sleep-lock.service`), the sleep-lock gate keyed on it; `grassfield-shell` keeps `Restart=always`;
- S5: crash-injection test: a crash signal to the UI process while locked (the lock surface never goes away: no
  "lockscreen app died" screen) and while unlocked (the idle lock still fires); DT-01/DT-21 re-run against the security
  process.

## Amendment 2026-10-26 (Settings > Lock Screen, macOS 27)
**Display off while unlocked.** The idle module gains a second idle monitor: after `lock.displayOffBattery` (on battery,
default 2 min) or `lock.displayOffPower` (on the power adapter, default 10 min) without input, the displays turn off (Hyprland
DPMS) while the session stays unlocked; any input turns them on (the compositor also does at a key press or pointer motion).
It respects the same inhibitors as the idle lock (an application holding a ScreenSaver cookie or a Wayland idle inhibitor
keeps the displays on) and reads the power source from UPower (`Battery.onBattery`; unknown reads as the power adapter). It
never locks and never delays the lock: the idle lock still fires at `lock.idleMinutes` from the first monitor, unchanged
(dim at T-10 s, lock at T), and a lock that follows a display-off keeps the displays off until input instead of lighting them
for the lock screen's own delay. A lock being acquired is never kept dark: the displays come on until the compositor
confirms it (`Lock.holding`; it confirms a lock only once it has drawn it on every display), then go dark again if no input
came (review of 6e61829: kept dark, the lock before sleep would wait out its budget and the ownership check would not run).
An unlock without Wayland input (fingerprint) lights a session that went dark for inactivity. A change of power source or of
the setting re-arms the monitor and lights the displays (as a Mac wakes its display when the adapter is plugged in); while
locked it then leaves the dark lock screen to its own 30 s delay. An invalid or 0 value means never (turning the displays off
is not what keeps the session safe). `IdleModel.inactiveDisplayOffSeconds`, `inactiveOffArmed`, `displaysOff`; tests/security/tst_idlemodel.qml. "Off" is
now sent whenever the wanted state is recomputed (the compositor may have switched the displays on by itself, so a remembered
"off" must not suppress the next one); "on" only when this module had them off, or while a lock is being acquired (an
instance restarted with the displays dark believes them on; counter-review of a15c05e): at start, then every 2 s until the
lock holds, at most 5 times (`IdleModel.ACQUIRE_DISPLAYS_ON_MS`, `ACQUIRE_DISPLAYS_ON_TRIES`: a lock that cannot hold, with no
display connected, is not woken all night); only a change of state is logged. The changes of the lock's state are handled later in the turn, once
(`Qt.callLater`), so a lock or an unlock sends no repeated "on". In the nested dev session it is always off (no dev hook: no
test needed one; review of PR #9).

**What the lock surface shows.** `lock.showUser` (default true) hides the account's picture and name (the password field
stays); `lock.showMessage` with `lock.message` shows one line of plain text of the user's (at most 200 UTF-16 code units, no C0 or
C1 control characters, line or paragraph separators, bidirectional overrides or isolates: refused otherwise by the settings
contract, rule `plainText`) above them, at most two lines on screen.
Display only: authentication, the lock state machine and every unlock path are unchanged, and the message is user text from
the user's own configuration (no notification or window content: L4 holds).

## Amendment 2026-10-29 (ADR-0041 SQ-1 B: the separate security process is decided)
The owner chose the separate security process as the answer to ADR-0041's SQ-1 (« Processus sécurité séparé », asked by
the integrator on 2026-10-29): the lock, the polkit agent, idle and the sleep inhibitor always run apart from the UI, and
safe mode is "the UI unit failed, the security process is up". The plan S1-S5 of the amendment of 2026-10-24 is carried
from here by `docs/decisions/ADR-0041-stability.md` step 1, in the integrator's order under the owner's rule: 1a (the
loop detector) first, then the process and its unit with nothing moved yet (S1, which also makes `shell/security/` free
of UI imports and measures the second process's memory and start time), then everything that locks together (S2: the
lock, idle and the sleep inhibitor, every `Lock.lock` caller switched in the same step, `OnFailure=`, the sleep-lock gate
and the stand-in keyed on `grassfield-security.service` from then on; the UI's reading of the lock state fails closed:
the pushed state, or the compositor's own lock signal, or "no state yet", a stale heartbeat or a stopped security unit,
each reads as locked), the polkit agent (S3), and safe mode last (S4). The integrator's review of f018b42 merged the
idle step into the lock's: moving the lock alone left the UI's inhibitor unable to lock while the security process
restarted. Each step is its own pull request under the opus security review, and every intermediate state keeps
"failures stay locked" (R12); ADR-0041 step 1 writes the invariant of each state (who locks, what happens when either
process is down, how sleep behaves). IQ-T5 (ADR-0040) applies to a crash of the security process itself. The risks listed
above (the IPC contract move, the lock state across processes, the UI imports, the memory of a second process) are
answered step by step there; nothing of this ADR's rules changes: `WlSessionLock`, `PamContext("omarchy-lock-password")`
and Quickshell's polkit only, no unlock on a failure.

## Amendment 2026-10-31 (ADR-0035 D-9, owner decision Q12: the secret sheets)
In force from the integrator's merge of the step 9a pull request, with the owner's agreement on that step (ADR-0035 D-9:
applied in step 9 only after the integrator's review and the owner's agreement on that step). The text is the owner's
(ADR-0035 "Owner decisions", Q12, 2026-10-27).

**Scope.** The security modules gain the secret sheets fed by `grassfield-prompter` (ADR-0035 D-9, and D-11 for pairing):
gcr system prompts, KIO network passwords, NetworkManager secrets, BlueZ pairing. The building blocks are WlSessionLock,
`PamContext("omarchy-lock-password")`, Quickshell Polkit and these secret sheets, only (the project's working rules, Hard rules).

**Rules** (master-prompt R12, its new bullet):
- the secret sheets of ADR-0035 belong to these modules: everything this ADR requires of them applies (opus reviewer PASS
  for every change, the security tests, failures stay locked);
- one queue holds every secret sheet and the polkit sheet; no sheet takes the keyboard from another;
- a secret sheet never looks like the authorization sheet;
- the requester shown is the one the bridge resolves from D-Bus credentials, never text from the caller.

Nothing else of this ADR changes: no PAM module or PAM service file, no greeter, no setuid code and nothing that runs as
root (the bridge is an unprivileged systemd user unit).

## Amendment 2026-11-04 (automatic sleep; Settings > Energy and Battery > Options…, macOS 27) — Proposed
The owner's report of rc1-22 on a desktop PC: no way to set the power profile, no way to keep the PC from sleeping. Before
this amendment nothing in Grassfield or Omarchy suspended a computer on idle (logind `IdleAction=ignore`; Omarchy's idle
service never suspends): what the owner saw was most likely the displays turning off (`lock.displayOffPower`, 10 minutes)
and the session locking. macOS has both: the display turns off and locks per Lock Screen, and the computer sleeps shortly
after, unless "Prevent automatic sleeping [on power adapter] when the display is off" is on (Energy without a battery,
Battery > Options… with one; on battery a Mac always sleeps; Grassfield differs there, see the integrator decision below).

**Decision (Proposed, applied provisionally until the owner accepts it).** The idle module gains the automatic sleep:
`IdleModel.AUTO_SLEEP_SECONDS` (60) after it turned the displays off for lack of input, with no input and no idle inhibitor
since, the computer sleeps through `systemctl --no-ask-password suspend` (never an authorization prompt), only when
`energy.preventSleep` is false. **Default true** (a deviation from macOS's default, where a desktop sleeps): Grassfield
never put a computer to sleep by itself, the owner's machine runs long jobs, and an unreadable value must give back that
behaviour, not a new one.

**Integrator decision (2026-11-04, a product risk raised by the opus security review of 95dab794).** The first version let
a laptop on battery sleep whatever the switch said (macOS): with the defaults it suspended about 3 minutes after the last
input (display off at 2 minutes, then 60 s), with no way to turn that off, although Grassfield and Omarchy never suspended
before, the owner runs long builds and agents, and the owner asked for a way to PREVENT sleep. So `energy.preventSleep`
applies on battery as well as on the power adapter; the default stays on, so nothing changes after the update; a user who
turns it off gets the macOS behaviour (sleep after the display goes off). Settings: on a laptop, Battery > Options… shows one
switch, "Prevent automatic sleeping when the display is off", with a footnote that it applies on battery and on power
adapter; on a desktop, Energy's switch as before. Tests: battery with the switch on, no suspend; off, suspend
(`tst_idlemodel` `test_idleDecisionsWithPreventSleep`).

**Rules.**
- Locking is never weakened. The idle lock, the display-off lock and the displays' power-off never read
  `energy.preventSleep` (pinned by `tst_idlemodel` `test_lockIndependentOfSleep`). The one lock the setting can lead to is
  the lock before an automatic sleep on a session that is not locked yet (`Lock.lock("sleep")`): it only ever adds a lock,
  never removes, delays or skips one (`test_autoSleepOnlyAddsLocks`). The displays still turn off and the session still
  locks as `lock.*` says.
- Grassfield suspends only in the LOCKED state with its lock secure (`IdleModel.autoSleepAction(Lock.currentState(),
  Lock.currentlySecure())`, read afresh, and read again right before `systemctl` runs; review of 95dab794: the `holding`
  binding included AUTHENTICATING and RELEASING, so a fingerprint success just before the due time could start a suspend
  during the release fade). An exactly UNLOCKED session is locked first, and the sleep waits for the next due time with the
  lock LOCKED and secure; every other state waits; a lock refused (no PAM service) leaves the computer awake and the session
  as it was. So a degraded sleep inhibitor (no logind delay) never makes an automatic sleep unlocked.
- Fail awake: a value that cannot be read, a refused suspend (an application's sleep block inhibitor) or a crashed shell
  leave the computer awake, locked or unlocked exactly as Lock Screen made it. A request that did not end in a sleep is asked
  again every 5 minutes (`IdleModel.AUTO_SLEEP_RETRY_MS`, monotonic) while the displays stay off, so a laptop goes to sleep
  once a download's inhibitor ends (review of 95dab794); never a tight loop; input stops it. The same timer puts the computer
  back to sleep 5 minutes after a wake without input (a timer or the network woke it, the displays stayed off): confirmed by
  the integrator after the delta review of 2a19231d, as macOS goes back to sleep after a dark wake, and it fails closed (the
  session stays LOCKED and secure, which a suspend requires).
- An unlock ends a pending automatic sleep (`IdleModel.autoSleepOnLockChange`): the delay starts over with the next
  display-off, so an unlock never leads to the lock before sleep and never undoes itself (review of 2a19231d: a fingerprint
  touch over the due time answered "wait" while AUTHENTICATING, then "lock" once UNLOCKED; `tst_idlemodel`
  `test_unlockOverTheDueTimeEndsTheAttempt`). A change of the lock decides again only once it is LOCKED and secure.
- Never in the nested dev session (a due suspend is counted and logged, `idle status`); the new dev hook `idle
  devAutoSleep <1..600>` only shortens the delay there.
- Real suspend: NOT VERIFIED until the owner's L2 run (L3†).

## Amendment to ADR-0010 (lock ownership probe rate), security-session audit round 2 · 2026-11-19 · Proposed

The lock's ownership probe asked Hyprland every 100 ms for as long as a lock inherited at start (a crash-restore, a stranded
lock taken over) was held: ten queries a second all night after any restart of the security process. Amended rule
(`LockMachine.probeSuspected`): a lock inherited at start whose lock surface holds the keyboard counts as a suspected
takeover only while the displays are on. While idle has turned them off for lack of input, it is probed every second, the
rate of any held lock; the first input lights them and the 100 ms rate comes back. A lock surface that lost the keyboard (a
sign of a real takeover) keeps 100 ms whatever the displays. Cost of the change: a foreign locker that sat under an inherited
lock and releases while the displays are dark is noticed within about 1 s instead of 0.1 s; no unlock path changes.

Also recorded: the crash-recovery marker stays written BEFORE the lock request (moving it after, as the audit's fluidity note
suggested, would lose the lock when the process crashes while the lock surfaces are created); its cost on that path drops
from two reads and a write to one write.
