pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import "WallClock.js" as Tick

// The one timer behind every WallClock of a process (audit SC-08: each menu bar, widget, saver and DayPhase had its own, each
// waking at least every Tokens.menubarClockMaxWaitMs). A clock holds the precision it shows ("minute" or "second") while it
// is enabled; the timer runs while one is held: on the next second while a seconds clock is held, else on the next minute,
// never later than the cap (a Timer counts monotonic time, which stops while the machine sleeps: the cap bounds how stale the
// time can be after a wake). `minute` and `second` change exactly when the minute (second) changes, from epoch milliseconds
// (WallClock.js: no time zone change moves them).
Singleton {
    id: root

    property date minute: new Date()
    property date second: new Date()
    property int minuteHolders: 0
    property int secondHolders: 0
    // The timer's wakes (tests).
    property int ticks: 0

    function hold(precision: string): void {
        if (precision === "second")
            root.secondHolders++;
        else if (precision === "minute")
            root.minuteHolders++;
        root.refresh();
    }

    function release(precision: string): void {
        if (precision === "second")
            root.secondHolders = Math.max(0, root.secondHolders - 1);
        else if (precision === "minute")
            root.minuteHolders = Math.max(0, root.minuteHolders - 1);
        root.refresh();
    }

    // The dates brought to now, and the next wake set (a clock made now is right at once).
    function refresh(): void {
        const now = Date.now();
        if (Tick.unitIndex(now, 60000) !== Tick.unitIndex(root.minute.getTime(), 60000))
            root.minute = new Date(now);
        if (Tick.unitIndex(now, 1000) !== Tick.unitIndex(root.second.getTime(), 1000))
            root.second = new Date(now);
        if (root.secondHolders > 0) {
            timer.interval = Tick.msToNext(now, 1000, Tokens.menubarClockMaxWaitMs);
            timer.restart();
        } else if (root.minuteHolders > 0) {
            timer.interval = Tick.msToNext(now, 60000, Tokens.menubarClockMaxWaitMs);
            timer.restart();
        } else {
            timer.stop();
        }
    }

    readonly property Timer timer: Timer {
        repeat: false
        onTriggered: {
            root.ticks++;
            root.refresh();
        }
    }
}
