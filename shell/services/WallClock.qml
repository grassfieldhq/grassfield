import QtQuick
import "WallClock.js" as Tick

// The clock of the menu bar, the Clock and Calendar widgets and the lock screen (macOS: the clock moves on the minute,
// whatever the time zone does). It replaces Quickshell's SystemClock: in 0.3.1 SystemClock computes its next tick from
// local time, so in the repeated hour of a daylight saving fall-back its target lies an hour in the past and it restarts
// a 1 ms timer about 800 times a second until the hour ends (found 2026-10-25; a bare SystemClock under TZ=Europe/Paris
// logs "QTimer::start: negative intervals" 2379 times in 3 s, none under TZ=UTC). Here the next tick comes from epoch
// milliseconds (WallClock.js), which no time zone change moves. `date` changes only when the displayed unit does. Every
// clock of a process follows the one shared timer (WallTicker): it wakes at most every `Tokens.menubarClockMaxWaitMs`
// whatever the number of clocks, so the time is right soon after a wake from sleep, and a new clock is right at once (the
// lock view is created with each lock surface). A disabled clock keeps the date it had and holds no timer.
QtObject {
    id: root

    property bool enabled: true
    // Seconds precision (the analog Clock widget's seconds hand); minutes otherwise.
    property bool seconds: false
    property date date: new Date()
    // The precision this clock holds on the shared timer ("" while disabled).
    property string held: ""

    function refresh(): void {
        // The unit is read here, not from a binding on `seconds`: onSecondsChanged can run before such a binding is
        // re-evaluated (a Clock widget created small and then made medium kept a minute schedule for up to 10 s).
        const want = root.enabled ? (root.seconds ? "second" : "minute") : "";
        if (want !== root.held) {
            const was = root.held;
            root.held = want;
            WallTicker.hold(want);
            WallTicker.release(was);
        } else if (want !== "") {
            WallTicker.refresh();
        }
        if (root.enabled)
            root.take(root.seconds ? WallTicker.second : WallTicker.minute);
    }

    function take(d: date): void {
        const unitMs = root.seconds ? 1000 : 60000;
        if (Tick.unitIndex(d.getTime(), unitMs) !== Tick.unitIndex(root.date.getTime(), unitMs))
            root.date = d;
    }

    onEnabledChanged: refresh()
    onSecondsChanged: refresh()
    Component.onCompleted: refresh()
    Component.onDestruction: {
        if (root.held !== "")
            WallTicker.release(root.held);
        root.held = "";
    }

    // The shared date of the precision held (no Connections object: the lock surfaces use this type, and the lock palette lint
    // allows them only plain objects and timers).
    readonly property date ticked: root.held === "second" ? WallTicker.second : (root.held === "minute" ? WallTicker.minute : root.date)
    onTickedChanged: {
        if (root.held !== "")
            root.take(root.ticked);
    }
}
