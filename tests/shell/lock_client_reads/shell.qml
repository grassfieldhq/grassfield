pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import "lib/LockState.js" as LockState

// The UI reads the security process's lock state once per beat (audit SC-08, the security fluidity notes): before, a read every
// 2 s on a timer came on top of the watch's read of the same beat (two reads, two parses and a new `last` per beat), and
// `motion` was a new object at every beat (every reader of it woke). This probe plays the security process (a beat every
// LockState.HEARTBEAT_MS, written atomically with the same cloud positions each time) for ~9 s on the REAL LockClient and
// checks: at most one read per beat (and a few for the start); fresh and unlocked; `motion` signalled once (when the positions
// first came), not at every beat; and with the watch silent (no beat written for 3 s, a lost notification) the backstop still
// reads (the fail-closed reading stays). Offscreen (scripts/dev/test.sh). Prints "lock-client-reads: PASS" or the failures.
ShellRoot {
    id: root

    settings.watchFiles: false

    property int seq: 0
    property int beats: 0
    property int reads0: 0
    property int motionChanges: 0
    property var failures: []
    property string phase: "beating"

    function check(name: string, ok: bool): void {
        if (!ok)
            root.failures.push(name);
    }

    function beat(): void {
        root.seq++;
        root.beats++;
        out.setText(LockState.format("unlocked", root.seq, 4242, false, {"GF-1": 1234}, false, false) + "\n");
    }

    Connections {
        target: LockClient
        function onMotionChanged(): void {
            root.motionChanges++;
        }
    }

    FileView {
        id: out
        path: LockClient.path
        atomicWrites: true
        printErrors: false
    }

    Timer {
        id: beater
        interval: LockState.HEARTBEAT_MS
        repeat: true
        triggeredOnStart: true
        running: LockClient.path !== ""
        onTriggered: {
            root.beat();
            // Two beats in: the client is fresh; count from here.
            if (root.seq === 2)
                settle.start();
        }
    }

    Timer {
        id: settle
        interval: 500
        onTriggered: {
            root.reads0 = LockClient.reads;
            root.beats = 0;
            root.motionChanges = 0;
            measure.start();
        }
    }

    Timer {
        id: measure
        interval: 4 * LockState.HEARTBEAT_MS + 300
        onTriggered: {
            const reads = LockClient.reads - root.reads0;
            root.check("fresh and unlocked (known " + LockClient.known + ", stale " + LockClient.stale + ", locked " + LockClient.locked + ")", LockClient.known && !LockClient.stale && !LockClient.locked);
            console.log("lock-client-reads: " + reads + " reads, " + root.beats + " beats, " + root.motionChanges + " motion changes");
            root.check("one read per beat (" + reads + " reads for " + root.beats + " beats)", reads >= root.beats - 1 && reads <= root.beats + 1);
            root.check("motion kept its object (" + root.motionChanges + " changes)", root.motionChanges === 0);
            root.check("motion read", LockClient.motion["GF-1"] === 1234);
            beater.stop();
            root.reads0 = LockClient.reads;
            silent.start();
        }
    }

    // No beat for 3 s: the watch reports nothing, the backstop reads at least once (a beat and a margin).
    Timer {
        id: silent
        interval: 3000
        onTriggered: {
            const reads = LockClient.reads - root.reads0;
            root.check("the backstop reads while the watch is silent (" + reads + " reads)", reads >= 1 && reads <= 2);
            if (root.failures.length === 0) {
                console.log("lock-client-reads: PASS");
                Qt.exit(0);
            } else {
                console.log("lock-client-reads: FAIL " + root.failures.join("; "));
                Qt.exit(1);
            }
        }
    }

    Timer {
        interval: 40000
        running: true
        onTriggered: {
            console.log("lock-client-reads: FAIL timeout (path " + LockClient.path + ", reads " + LockClient.reads + ")");
            Qt.exit(1);
        }
    }
}
