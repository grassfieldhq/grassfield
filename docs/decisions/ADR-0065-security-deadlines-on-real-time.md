# ADR-0065: Security deadlines run on real time, never on a QML Timer
Status: Accepted (owner's diagnostic report of 2026-11-21) · Date: 2026-11-21 · Decider: owner (via the fix brief)

## Context
The owner's journal showed "no beat from the security process for 5 s ... the session reads locked" 30 to 40 s after each
restart of the UI and once while the idle dim faded in, the security process being healthy, and an idle lock announced
"lock in 10 s" that locked after 17 s. A QML `Timer` is synchronized with the animation clock. With the threaded render loop
(every Wayland session) that clock advances by one vsync per frame and never catches up a frame that came late
(QSGDefaultAnimationDriver, VSyncMode; it switches to wall time only after several consecutive very late frames). Measured
offscreen with QSG_RENDER_LOOP=threaded and a GUI thread busy 200 ms every third frame: a 2 s Timer fired every 8.9 s, while
Quickshell's SystemClock (a QTimer) kept its second. The heartbeat that proves the security process alive, the UI's stale
bound and the idle lock's delay were all such Timers.

## Decision
1. Deadlines that carry a security meaning (the lock state's heartbeat, the UI's stale check and its backstop read, the idle
   lock's delay and the display-off lock's delay) run on real time: `shell/security/lock/RealTimer.qml` (monotonic time from
   Quickshell's ElapsedTimer, woken every second by Quickshell's SystemClock; it fires within ±0.5 s of its interval, only
   while its process's event loop runs) or, in LockClient, the same two types directly.
2. Fail closed is unchanged: a hung security process writes no beat, the UI reads locked within 5 to 6 s of real time; a
   process that only draws late frames keeps beating and is never read as stale.
3. Sub-second timers, animations and anything without a security meaning keep QML Timers (their stretching under load is
   harmless and they cost nothing while idle). `qs.lib` (shared by both processes, no UI) may be imported by the security
   modules (tests/security/security_process_scan.py).

## Consequences
One QTimer wake per second per running RealTimer (the beat's always runs in the security process; the UI's check always runs
in the UI). Tests: tests/security/lock_beat_realtime.sh (the real LockPublisher and LockClient in processes that draw late
frames: beat gaps at most 3.5 s, no false stale, stale within 6.5 s of the last beat; before: 8.9 s gaps and no stale within
14 s), tests/security/lock_client.sh (its stale-never mutant now targets the tick). Not verified in a real session: the
owner's exact frame pattern (the idle dim on three outputs, the video wallpaper starting).
