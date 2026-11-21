import QtQuick
import Quickshell

// A timer on real time, for the deadlines that must hold whatever the scene graph does: the lock state's heartbeat and its
// stale check (ADR-0041 S2), the idle lock's delay. A QML Timer is synchronized with the animation clock: with the threaded
// render loop (every Wayland session) that clock advances by one vsync per frame and never catches up a frame that came late,
// so a Timer falls behind wall time whenever its process misses frames. Measured offscreen with QSG_RENDER_LOOP=threaded and a
// GUI thread busy 200 ms every third frame: a 2 s Timer fired every 8.9 s (tests/security/lock_beat_realtime.sh). On the owner's
// machine (2026-11-21) the idle lock announced "lock in 10 s" came after 17 s, and the security process's 2 s beat missed the
// UI's 5 s bound while that process drew the idle dim.
// This one counts monotonic time (Quickshell's ElapsedTimer: QElapsedTimer) and is woken by Quickshell's SystemClock (a QTimer
// on the event loop, at every second): it fires within half a second of `interval`, and only while the event loop of its
// process runs (a hung process fires nothing, which is what the fail-closed readers rely on). Resolution: one second, so
// `interval` is meant in seconds (at least 1000 ms).
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
        // Half a tick of tolerance: the clock wakes at every second, so this fires within ±500 ms of the interval.
        if (elapsed + 500 < Math.max(1000, root.interval))
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

    SystemClock {
        enabled: root.running
        precision: SystemClock.Seconds
        onDateChanged: root.tick()
    }
}
