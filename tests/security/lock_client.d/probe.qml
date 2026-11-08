pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import "lib/LockState.js" as LockState

// ADR-0041 step 1, S2: the UI's reading of the lock state, on the REAL LockClient and SessionState (run offscreen by
// tests/security/lock_client.sh with XDG_RUNTIME_DIR in a scratch directory and no compositor). This probe plays the
// security process: it writes the state file the way LockPublisher does (LockState.format, atomic), and checks what every
// refusal of the UI reads (SessionState.refuses, through the same Binding as shell.qml):
//   none        no state file yet: locked
//   fresh       a beat saying "unlocked": unlocked (the control: the refusals below are not a broken reader)
//   stopped     no new beat for LockState.STALE_MS (a stopped, restarting or hung security process): locked
//   back        beats again: unlocked
//   lost-push   the file still says "unlocked" while the compositor reports a lock (a push the UI missed): locked
//   locking     "locking": locked, lockStarting
//   garbage     a file that does not parse: locked
//   restarted   a new writer whose sequence starts again: a fresh beat, unlocked
//   gone        the file removed: locked
// Prints "lock-client: PASS" or "lock-client: FAIL <checks>" and quits.
ShellRoot {
    id: root

    settings.watchFiles: false

    property var failures: []
    property int seq: 0
    property int writer: 1000
    property bool beating: false
    property string beatState: "unlocked"
    readonly property string path: LockClient.path

    function check(name: string, ok: bool): void {
        if (!ok)
            root.failures.push(name);
    }

    function write(state: string): void {
        root.seq += 1;
        out.setText(LockState.format(state, root.seq, root.writer, false, {}) + "\n");
    }

    function writeRaw(text: string): void {
        out.setText(text);
    }

    // The same wiring as shell.qml.
    Binding {
        target: SessionState
        property: "locked"
        value: LockClient.locked
    }

    FileView {
        id: out
        path: root.path
        preload: false
        blockWrites: true
        atomicWrites: true
        printErrors: false
    }

    Process {
        id: remover
        command: ["rm", "-f", "--", root.path]
    }

    Timer {
        interval: LockState.HEARTBEAT_MS
        repeat: true
        running: root.beating
        onTriggered: root.write(root.beatState)
    }

    // The steps, each at its time (ms from the start); `at` holds the checks of the step before it.
    property var plan: [
        [500, () => {
                root.check("none: no state file reads locked", LockClient.locked && SessionState.refuses("probe-none"));
                root.check("none: path in the scratch runtime directory", root.path.indexOf("/grassfield-lock-state-") > 0);
                root.write("unlocked");
                root.beating = true;
            }],
        [3500, () => {
                root.check("fresh: a beat saying unlocked reads unlocked", !LockClient.locked && !SessionState.refuses("probe-fresh"));
                root.check("fresh: not stale", !LockClient.stale && LockClient.known);
                root.beating = false;
            }],
        [3500 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 1000, () => {
                root.check("stopped: no beat for the stale bound reads locked", LockClient.locked && LockClient.stale && SessionState.refuses("probe-stopped"));
                root.write("unlocked");
                root.beating = true;
            }],
        [3500 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 4000, () => {
                root.check("back: beats again read unlocked", !LockClient.locked);
                LockClient.compositorLocked = true;
            }],
        [3500 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 4500, () => {
                root.check("lost-push: the compositor's lock with the file still unlocked reads locked", LockClient.locked && SessionState.refuses("probe-lost-push"));
                LockClient.compositorLocked = false;
                root.beatState = "locking";
                root.write("locking");
            }],
        [3500 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 7000, () => {
                root.check("locking: reads locked, lock starting", LockClient.locked && LockClient.lockStarting && SessionState.refuses("probe-locking"));
                root.beating = false;
                root.writeRaw("{\"v\":1,\"state\":\"unlocked\",");
            }],
        [3500 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 10000, () => {
                root.check("garbage: a file that does not parse reads locked", LockClient.locked && !LockClient.known);
                // A restarted security process: a new writer whose sequence starts again.
                root.writer = 2000;
                root.seq = 0;
                root.beatState = "unlocked";
                root.write("unlocked");
                root.beating = true;
            }],
        [3500 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 13000, () => {
                root.check("restarted: a new writer's beat reads unlocked", !LockClient.locked && !LockClient.stale);
                root.beating = false;
                remover.running = true;
            }],
        [3500 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 16000, () => {
                root.check("gone: the file removed reads locked", LockClient.locked && !LockClient.known);
                if (root.failures.length === 0)
                    console.info("lock-client: PASS");
                else
                    console.info("lock-client: FAIL " + root.failures.join("; "));
                Qt.quit();
            }]
    ]
    property int step: 0

    Timer {
        id: stepper
        onTriggered: {
            const p = root.plan[root.step];
            p[1]();
            root.step += 1;
            if (root.step < root.plan.length) {
                stepper.interval = root.plan[root.step][0] - p[0];
                stepper.start();
            }
        }
    }

    Component.onCompleted: {
        stepper.interval = root.plan[0][0];
        stepper.start();
    }
}
