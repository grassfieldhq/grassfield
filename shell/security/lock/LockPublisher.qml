pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "../../lib/LockState.js" as LockState

// The lock state the UI reads (ADR-0041 step 1, S2; ADR-0010 risk 2: "a missed or stale push makes the UI refusals fail
// open"): one file, $XDG_RUNTIME_DIR/grassfield-lock-state-<compositor instance> (LockState.filePath), rewritten atomically
// on every change of what is published (the push: the lock's public state, the displays idle switched off, where the lock's
// clouds came to rest) and every LockState.HEARTBEAT_MS with a new sequence number (the heartbeat: a push the UI missed is
// corrected by the next beat, and a process that stopped writing reads as stale, hence locked, within LockState.STALE_MS).
// Only this process writes it; nothing is read back from the UI. A write that fails is logged once and retried by the
// next beat: the lock itself never depends on it (the UI reads "locked" from a missing or stale state, fail closed).
// Never private state: no name, no message, no attempt count.
Scope {
    id: root

    // What to publish (bound by Lock.qml).
    property string state: "locking"
    property bool displaysOff: false
    property var motion: ({})

    readonly property string path: LockState.filePath(Quickshell.env("XDG_RUNTIME_DIR"), Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"), Quickshell.env("WAYLAND_DISPLAY"))
    // One more for every write (push or beat), from 1; the writer's process id tells a restarted process apart.
    property int sequence: 0
    readonly property int writer: Quickshell.processId
    // The last write failed (logged once until a write succeeds again).
    property bool failing: false
    // Set at start, before the first write: where the clouds rested in the state the previous instance of this process
    // published (a restart keeps the desktop's and the lock's clouds together). null when there was none.
    property var previousMotion: null

    // Set by start(): the bindings above change during the creation of Lock.qml, before the restore has decided the state.
    property bool ready: false

    function publish(why: string): void {
        if (!root.ready)
            return;
        if (root.path === "") {
            if (!root.failing)
                console.warn("grassfield-lock: XDG_RUNTIME_DIR unset: the lock state cannot be published; the UI reads the session as locked");
            root.failing = true;
            return;
        }
        root.sequence += 1;
        const text = LockState.format(root.state, root.sequence, root.writer, root.displaysOff, root.motion) + "\n";
        file.setText(text);
        if (why !== "beat")
            console.info("grassfield-lock: published " + root.state + " (" + why + ", beat " + root.sequence + ")");
    }

    onStateChanged: root.publish("state")
    onDisplaysOffChanged: root.publish("displays")
    onMotionChanged: root.publish("clouds")

    FileView {
        id: file
        path: root.path
        preload: false
        blockWrites: true
        atomicWrites: true
        printErrors: false
        onSaved: {
            if (root.failing)
                console.info("grassfield-lock: the lock state is published again");
            root.failing = false;
        }
        onSaveFailed: error => {
            if (!root.failing)
                console.warn("grassfield-lock: the lock state could not be published (" + FileViewError.toString(error) + "); retried with every beat; the UI reads the session as locked once it is stale");
            root.failing = true;
        }
    }

    // The previous instance's last state (a restart of this process), read once while this object is created, before the
    // first write: only its cloud positions are taken (Lock.qml), never its lock state (the lock decides from the
    // crash-recovery marker and the compositor).
    FileView {
        id: previous
        path: root.path
        blockLoading: true
        printErrors: false
        onLoaded: {
            const last = LockState.parse(String(text()).trim());
            root.previousMotion = last.ok ? last.motion : null;
        }
    }

    Timer {
        interval: LockState.HEARTBEAT_MS
        repeat: true
        running: root.ready
        onTriggered: root.publish("beat")
    }

    // Started by Lock.qml at the end of its own Component.onCompleted, after the crash-recovery restore (the order of
    // onCompleted handlers is unspecified in Qt: the opus review of 77a0ceb3, MINOR-2). Nothing is written before.
    function start(): void {
        if (root.ready)
            return;
        root.ready = true;
        root.publish("start");
    }
}
