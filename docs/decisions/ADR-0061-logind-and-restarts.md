# ADR-0061: The lock follows logind's Lock signal, sets LockedHint, and keeps its idle count across a restart
Status: Proposed (security-session audit, round 2) · Date: 2026-11-19 · Decider: integrator · Related: ADR-0010, ADR-0041 (step 1, S2), docs/specs/security.md "logind, restarts and refusals"

## Context

The security process listened to logind's manager object only (PrepareForSleep). `loginctl lock-session`, `lock-sessions`
and logind.conf's lock actions (HandleLidSwitch=lock, HandlePowerKey=lock, ...) emit `Session.Lock` on the session's object
and did nothing: the session stayed unlocked (audit SS-02). logind's LockedHint was never set. A restart of the security
process counted idle time from zero (Hyprland starts a new idle notification at zero), so a slow crash loop never idle-locked
(SS-09).

## Decision

1. The security process finds this login's logind session (GetSession(XDG_SESSION_ID), else the user's Display session,
   else GetSessionByPID(compositor pid)) and monitors that object path only. `Session.Lock` locks (`Lock.lock("logind")`).
   `Session.Unlock` is ignored and logged: only a PAM success opens the lock (fail closed; macOS offers no remote unlock).
2. LockedHint is set true when the compositor confirmed the lock and false when the session is unlocked. It is information
   for other tools; nothing in Grassfield reads it.
3. The idle period is recorded per compositor instance in $XDG_RUNTIME_DIR (monotonic /proc/uptime seconds). A restarted
   process locks at once when the recorded period already lasted lock.idleMinutes, or at that period's deadline unless input
   is seen first. It only ever adds a lock.
4. A dev session neither follows logind nor sets LockedHint (its session is the owner's).

## Consequences

- Remote and scripted locks, and logind's own lid and power-key lock actions, work in the Grassfield session.
- A user who returned in the one second of a restart and gave no one-second pause until the inherited deadline is locked
  (a false lock, never a missed one).
- Real-session checks: `loginctl lock-session`, `loginctl show-session -p LockedHint`, a crash just before the idle deadline.
