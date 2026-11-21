import QtQuick
import Quickshell

// A timer on real time, for the deadlines that must hold whatever the scene graph does: the lock state's heartbeat and its
// stale check (ADR-0041 S2), the idle lock's delay. A QML Timer is synchronized with the animation clock: with the threaded
// render loop (every Wayland session) that clock advances by one vsync per frame and never catches up a frame that came late,
// so a Timer falls behind wall time whenever its process misses frames. Measured offscreen with QSG_RENDER_LOOP=threaded and a
// GUI thread busy 200 ms every third frame: a 2 s Timer fired every 8.9 s (tests/security/lock_beat_realtime.sh). On the owner's
// machine (2026-11-21) the idle lock announced "lock in 10 s" came after 17 s, and the security process's 2 s beat missed the
// UI's 5 s bound while that process drew the idle dim.
// This one counts monotonic time (Quickshell's ElapsedTimer: QElapsedTimer) and is only woken by a short Timer (WAKE_MS): a
// late wake-up delays a deadline by about one stretched wake-up, never by the whole interval's stretch. Quickshell's
// SystemClock would wake it on the event loop's own QTimer, but it schedules from local time and spins during the repeated hour
// of a daylight saving fall-back (tests/shell/wall_clock_only.sh), so it is not used here. It fires only while the event loop
// of its process runs (a hung process fires nothing, which is what the fail-closed readers rely on).
Scope {
    id: root

    property int interval: 1000
    property bool repeat: false
    property bool running: false
    // Monotonic milliseconds since the last start (or the last trigger of a repeating timer); 0 while stopped.
    readonly property real elapsedMs: root.running ? root.lastElapsed : 0
    property real lastElapsed: 0

    signal triggered

    function start(): void {
        if (root.running)
            return;
        since.restart();
        root.lastElapsed = 0;
        root.running = true;
    }

    function stop(): void {
        root.running = false;
    }

    function restart(): void {
        since.restart();
        root.lastElapsed = 0;
        root.running = true;
    }

    // A start through the property (running: true, a binding) counts from then.
    onRunningChanged: {
        if (root.running) {
            since.restart();
            root.lastElapsed = 0;
        }
    }

    function tick(): void {
        if (!root.running)
            return;
        const elapsed = since.elapsedMs();
        root.lastElapsed = elapsed;
        // Half a wake-up of tolerance: this fires within ±WAKE_MS/2 of the interval while frames come on time.
        if (elapsed + root.wakeMs / 2 < Math.max(root.wakeMs, root.interval))
            return;
        if (root.repeat) {
            since.restart();
            root.lastElapsed = 0;
        } else {
            root.running = false;
        }
        root.triggered();
    }

    ElapsedTimer {
        id: since
    }

    // Wake-up period. Short, so that the Timer's stretch under late frames (the reason for this type) costs at most about one
    // stretched period on a deadline.
    readonly property int wakeMs: 250

    Timer {
        interval: root.wakeMs
        repeat: true
        running: root.running
        onTriggered: root.tick()
    }
}
