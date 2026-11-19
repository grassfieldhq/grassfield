pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// A not-responding mark goes within a second of its stand-in's end (NR3), without a process every 250 ms (audit SC-20: a
// `kill -0` child four times a second for as long as an app stayed marked, hours if ignored). Two stand-ins (sleeping
// processes) are marked on the REAL NotResponding; over 2.5 s nothing ends and nothing is started again (one waiter, no poll);
// the first is killed: its mark goes within a second and the other stays; the second is killed: no mark left. A stand-in
// already gone when marked loses its mark at once. Offscreen (scripts/dev/test.sh). Prints "not-responding-wait: PASS" or the
// failures.
ShellRoot {
    id: root

    property var failures: []
    property int runs0: 0
    property double killedAt: 0
    property int step: 0

    function check(name: string, ok: bool): void {
        if (!ok)
            root.failures.push(name);
    }

    function done(): void {
        standinA.signal(9);
        standinB.signal(9);
        if (root.failures.length === 0) {
            console.log("not-responding-wait: PASS");
            Qt.exit(0);
        } else {
            console.log("not-responding-wait: FAIL " + root.failures.join("; "));
            Qt.exit(1);
        }
    }

    Process {
        id: standinA
        command: ["sleep", "60"]
        running: true
    }
    Process {
        id: standinB
        command: ["sleep", "60"]
        running: true
    }

    Timer {
        interval: 300
        running: true
        onTriggered: {
            if (!standinA.running || !standinB.running) {
                root.failures.push("the stand-ins did not start");
                root.done();
                return;
            }
            NotResponding.marks = [{standin: standinA.processId, pid: 4000001, cls: "a", title: "A"}, {standin: standinB.processId, pid: 4000002, cls: "b", title: "B"}];
            root.runs0 = NotResponding.waiterRuns;
            quiet.start();
        }
    }

    Timer {
        id: quiet
        interval: 2500
        onTriggered: {
            root.check("both marks stay while the stand-ins live", NotResponding.marks.length === 2);
            root.check("one waiter, not started again while nothing ends (" + (NotResponding.waiterRuns - root.runs0) + " starts)", NotResponding.waiterRuns - root.runs0 === 0);
            root.check("waitpid is there (else the 250 ms check would run)", !NotResponding.waiterMissing);
            root.killedAt = Date.now();
            standinA.signal(9);
            watch.start();
        }
    }

    Timer {
        id: watch
        interval: 20
        repeat: true
        onTriggered: {
            const left = Date.now() - root.killedAt;
            if (root.step === 0) {
                if (NotResponding.marks.length === 1 && NotResponding.marks[0].pid === 4000002) {
                    root.check("the first mark went within a second (" + left + " ms)", left <= 1000);
                    root.step = 1;
                    root.killedAt = Date.now();
                    standinB.signal(9);
                } else if (left > 1500) {
                    root.check("the first mark went (marks " + JSON.stringify(NotResponding.marks) + ")", false);
                    watch.stop();
                    root.done();
                }
            } else if (root.step === 1) {
                if (NotResponding.marks.length === 0) {
                    root.check("the second mark went within a second (" + left + " ms)", left <= 1000);
                    root.step = 2;
                    root.killedAt = Date.now();
                    // A stand-in already gone when marked (pid 1 is never a stand-in; a pid past pid_max is no process).
                    NotResponding.marks = [{standin: 4194999, pid: 4000003, cls: "c", title: "C"}];
                } else if (left > 1500) {
                    root.check("the second mark went", false);
                    watch.stop();
                    root.done();
                }
            } else {
                if (NotResponding.marks.length === 0) {
                    root.check("a gone stand-in's mark went at once (" + left + " ms)", left <= 1000);
                    watch.stop();
                    root.done();
                } else if (left > 1500) {
                    root.check("a gone stand-in's mark went", false);
                    watch.stop();
                    root.done();
                }
            }
        }
    }

    Timer {
        interval: 20000
        running: true
        onTriggered: {
            root.failures.push("timeout at step " + root.step);
            root.done();
        }
    }
}
