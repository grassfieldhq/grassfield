pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.services

// The REAL WallClock (shell/services/WallClock.qml), offscreen under qs (scripts/dev/test.sh: `qs -p tests/shell/wall_clock`;
// prints "wall-clock: PASS" or the failures). Review of cf6d3df: a Clock widget is created small (a minute clock) and
// then made medium (seconds); the switch must take the seconds schedule at once, not after the minute clock's next wake.
// - a minute clock waits for its minute or the cap, never less than 1 ms;
// - switching to seconds waits at most a second at once, and `date` then changes every second;
// - disabled: the timer stops; enabled again: it runs and `date` is current.
// - every clock of the process follows ONE timer (WallTicker, audit SC-08): three more minute clocks add no timer and no wake,
//   and they all move together.
ShellRoot {
    id: root

    property var failures: []
    property int dateChanges: 0

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    WallClock {
        id: clock
        onDateChanged: root.dateChanges++
    }

    property int otherChanges: 0
    WallClock {
        id: other1
        enabled: false
        onDateChanged: root.otherChanges++
    }
    WallClock {
        id: other2
        enabled: false
    }
    WallClock {
        id: other3
        enabled: false
    }

    // After every Component.onCompleted (the clock's own refresh among them; their order is not defined).
    Component.onCompleted: Qt.callLater(start)

    function start(): void {
        check("a minute clock runs", WallTicker.timer.running);
        check("a minute clock waits 1 ms or more", WallTicker.timer.interval >= 1);
        check("a minute clock waits at most the cap", WallTicker.timer.interval <= 10000 + 2);
        const before = WallTicker.timer.interval;
        other1.enabled = true;
        other2.enabled = true;
        other3.enabled = true;
        check("four minute clocks hold one timer (holders " + WallTicker.minuteHolders + ")", WallTicker.minuteHolders === 4 && WallTicker.secondHolders === 0);
        check("more minute clocks do not move the wake", Math.abs(WallTicker.timer.interval - before) <= 50);
        clock.seconds = true;
        check("seconds at once (interval " + WallTicker.timer.interval + ")", WallTicker.timer.interval >= 1 && WallTicker.timer.interval <= 1002);
        dateChanges = 0;
        WallTicker.ticks = 0;
        settle.start();
    }

    Timer {
        id: settle
        interval: 2600
        onTriggered: {
            root.check("date changed every second (" + root.dateChanges + " changes in 2.6 s)", root.dateChanges >= 2 && root.dateChanges <= 3);
            root.check("one wake a second for four clocks (" + WallTicker.ticks + " in 2.6 s)", WallTicker.ticks >= 2 && WallTicker.ticks <= 4);
            root.check("the minute clocks did not move with the seconds (" + root.otherChanges + ")", root.otherChanges <= 1);
            other1.enabled = false;
            other2.enabled = false;
            other3.enabled = false;
            clock.enabled = false;
            root.check("disabled: the timer stops", !WallTicker.timer.running && WallTicker.minuteHolders === 0 && WallTicker.secondHolders === 0);
            clock.enabled = true;
            root.check("enabled again: the timer runs", WallTicker.timer.running);
            root.check("enabled again: date is current", Math.abs(Date.now() - clock.date.getTime()) < 1100);
            if (root.failures.length === 0) {
                console.log("wall-clock: PASS");
                Qt.exit(0);
            } else {
                console.log("wall-clock: FAIL " + root.failures.join(", "));
                Qt.exit(1);
            }
        }
    }
}
