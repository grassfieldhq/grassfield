# ADR-0062: A login session that dies at once falls back to the other session, once per streak
Status: Proposed (security-session audit, round 2, SS-11) · Date: 2026-11-19 · Decider: integrator · Related: GF-015, owner decision D-2, ADR-0042

## Context

Omarchy's SDDM theme has no session picker and always starts "Grassfield (uwsm)", which runs `grassfield-login`. When the
chosen session starts and dies at once (a broken configuration, a compositor that cannot start), the user was back at the
login screen with no way in but a TTY and `grassfield-login set omarchy`.

## Decision

1. `grassfield-login` runs the session as its child (no exec; TERM, HUP and INT are passed on) and records, per session, the
   consecutive exits within 20 s of the start (`~/.local/state/grassfield/login-quick-exits`, monotonic clock).
2. After two such exits in a row of the chosen session, the next login starts the other session once and says so in the
   journal. That login sets the chosen session's count to one: the following login tries the chosen session again, and one
   more quick exit falls back again. The user's choice is never changed by this.
3. A session that lived longer than 20 s clears its own count; `grassfield-login set` clears both.

## Consequences

- A broken session alternates with the working one instead of locking the user out; a repaired one is used again at once.
- Two deliberate log-outs within 20 s of logging in send one later login to the other session; the next goes back.
- Nothing loops by itself: each start is a login, or SDDM's one autologin per boot.
