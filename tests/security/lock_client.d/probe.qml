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
//   none        no state file yet: locked, displays read off, the lock not confirmed (a lock request still goes out)
//   first       the first write read: no beat yet (only a second write proves a live writer): still locked
//   fresh       a beat saying "unlocked": unlocked, displays on (the control: the refusals below are not a broken reader)
//   stopped     no new beat for LockState.STALE_MS (a stopped, restarting or hung security process): locked, displays read
//               off, the lock not confirmed (SessionState.refusesConfirmed lets the lock paths through)
//   back        beats again: unlocked
//   lost-push   the file still says "unlocked" while the compositor reports a lock (a push the UI missed): locked, confirmed
//   locking     "locking": locked, lockStarting, confirmed (the lock paths refused too)
//   garbage     a file that does not parse: locked, not confirmed
//   restarted   a new writer whose sequence starts again: a fresh beat, unlocked
//   dark        a fresh beat with the displays off: displays off, unlocked
//   gone        the file removed: locked
// With LOCK_CLIENT_MODE set, the harness wrote a state file before this UI started and nothing writes it again:
//   existing-locked         a "locked" line: locked and confirmed at once, and it stays so
//   existing-dead-unlocked  an "unlocked" line of a writer that is gone: locked (stale, no beat ever) and not confirmed,
//                           for longer than LockState.STALE_MS (the opus review of 77a0ceb3, MINOR-3)
// Prints "lock-client: PASS" or "lock-client: FAIL <checks>" and quits.
ShellRoot {
    id: root

    settings.watchFiles: false

    property var failures: []
    property int seq: 0
    property int writer: 1000
    property bool beating: false
    property string beatState: "unlocked"
    property bool beatDark: false
    readonly property string mode: Quickshell.env("LOCK_CLIENT_MODE") ?? ""
    readonly property string path: LockClient.path

    function check(name: string, ok: bool): void {
        if (!ok)
            root.failures.push(name);
    }

    function write(state: string): void {
        root.seq += 1;
        out.setText(LockState.format(state, root.seq, root.writer, root.beatDark, {}) + "\n");
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
    Binding {
        target: SessionState
        property: "lockConfirmed"
        value: LockClient.lockConfirmed
    }

    // The lock paths (the Grassfield menu, Search, the lock corner) stay open exactly when the UI reads locked without a
    // confirmed lock.
    function lockPathsOpen(): bool {
        return !SessionState.refusesConfirmed("probe-lock-path");
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
    readonly property var controlPlan: [
        [500, () => {
                root.check("none: no state file reads locked", LockClient.locked && SessionState.refuses("probe-none"));
                root.check("none: path in the scratch runtime directory", root.path.indexOf("/grassfield-lock-state-") > 0);
                root.check("none: the displays read off (the polkit agent's restrictive side)", LockClient.displaysOff);
                root.check("none: the lock is not confirmed, the lock paths stay open", !LockClient.lockConfirmed && root.lockPathsOpen());
                root.write("unlocked");
            }],
        [1500, () => {
                root.check("first: the first write read is no beat (still locked, stale)", LockClient.known && LockClient.stale && LockClient.locked);
                root.beating = true;
            }],
        [5000, () => {
                root.check("fresh: a beat saying unlocked reads unlocked", !LockClient.locked && !SessionState.refuses("probe-fresh"));
                root.check("fresh: not stale", !LockClient.stale && LockClient.known);
                root.check("fresh: the displays read on", !LockClient.displaysOff);
                root.check("fresh: the lock paths open", root.lockPathsOpen() && !LockClient.lockConfirmed);
                root.beating = false;
            }],
        [5000 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 1000, () => {
                root.check("stopped: no beat for the stale bound reads locked", LockClient.locked && LockClient.stale && SessionState.refuses("probe-stopped"));
                root.check("stopped: the displays read off", LockClient.displaysOff);
                root.check("stopped after an unlocked: the lock is not confirmed, the lock paths stay open (a lock request reaches the stand-in)", !LockClient.lockConfirmed && root.lockPathsOpen());
                root.write("unlocked");
                root.beating = true;
            }],
        [5000 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 4000, () => {
                root.check("back: beats again read unlocked", !LockClient.locked);
                LockClient.compositorLocked = true;
            }],
        [5000 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 4500, () => {
                root.check("lost-push: the compositor's lock with the file still unlocked reads locked", LockClient.locked && SessionState.refuses("probe-lost-push"));
                root.check("lost-push: the compositor's lock confirms it, the lock paths are refused", LockClient.lockConfirmed && !root.lockPathsOpen());
                LockClient.compositorLocked = false;
                root.beatState = "locking";
                root.write("locking");
            }],
        [5000 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 7000, () => {
                root.check("locking: reads locked, lock starting", LockClient.locked && LockClient.lockStarting && SessionState.refuses("probe-locking"));
                root.check("locking: confirmed, the lock paths are refused", LockClient.lockConfirmed && !root.lockPathsOpen());
                root.beating = false;
                root.writeRaw("{\"v\":1,\"state\":\"unlocked\",");
            }],
        [5000 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 10000, () => {
                root.check("garbage: a file that does not parse reads locked", LockClient.locked && !LockClient.known);
                root.check("garbage: not confirmed, the lock paths stay open", !LockClient.lockConfirmed && root.lockPathsOpen());
                // A restarted security process: a new writer whose sequence starts again.
                root.writer = 2000;
                root.seq = 0;
                root.beatState = "unlocked";
                root.write("unlocked");
                root.beating = true;
            }],
        [5000 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 13000, () => {
                root.check("restarted: a new writer's beat reads unlocked", !LockClient.locked && !LockClient.stale);
                root.beatDark = true;
                root.write("unlocked");
            }],
        [5000 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 14500, () => {
                root.check("dark: a fresh beat with the displays off reads displays off", LockClient.displaysOff && !LockClient.locked);
                root.beatDark = false;
                root.beating = false;
                remover.running = true;
            }],
        [5000 + LockState.STALE_MS + LockState.HEARTBEAT_MS + 17500, () => {
                root.check("gone: the file removed reads locked", LockClient.locked && !LockClient.known);
                root.finish();
            }]
    ]
    readonly property var existingLockedPlan: [
        [800, () => {
                root.check("existing locked: a locked file read at the start reads locked and confirmed", LockClient.known && LockClient.locked && LockClient.lockConfirmed && !root.lockPathsOpen());
            }],
        [LockState.STALE_MS + 2500, () => {
                root.check("existing locked: still locked and confirmed once stale (no writer)", LockClient.stale && LockClient.locked && LockClient.lockConfirmed && LockClient.displaysOff);
                root.finish();
            }]
    ]
    readonly property var existingDeadUnlockedPlan: [
        [800, () => {
                root.check("dead writer's unlocked: read at the start, no beat: locked", LockClient.known && LockClient.stale && LockClient.locked && SessionState.refuses("probe-dead"));
                root.check("dead writer's unlocked: not confirmed, the lock paths stay open", !LockClient.lockConfirmed && root.lockPathsOpen());
            }],
        [LockState.STALE_MS + 2500, () => {
                root.check("dead writer's unlocked: still locked past the stale bound (never one fresh read)", LockClient.stale && LockClient.locked && LockClient.displaysOff);
                root.finish();
            }]
    ]
    readonly property var plan: root.mode === "existing-locked" ? root.existingLockedPlan : root.mode === "existing-dead-unlocked" ? root.existingDeadUnlockedPlan : root.controlPlan

    function finish(): void {
        if (root.failures.length === 0)
            console.info("lock-client: PASS");
        else
            console.info("lock-client: FAIL " + root.failures.join("; "));
        Qt.quit();
    }

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
