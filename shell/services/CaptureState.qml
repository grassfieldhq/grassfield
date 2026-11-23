pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.lib
import "CaptureFile.js" as CaptureFile

// The capture helper as the shell sees it (ADR-0045 OC-1; spec docs/specs/system-dialogs.md "Capture toolbar" and "Screen
// recording"): the helper's private state, watched (a countdown the capture toolbar's plate shows, a recording the menu bar's
// stop item shows), the helper run for the toolbar, and its stop: by the menu bar's item and when the session locks (a recording
// never goes on under the lock; a countdown captures nothing).
//
// The helper (packaging/bin/grassfield-capture) writes $XDG_RUNTIME_DIR/grassfield/capture-state.json by rename; its folder is
// made first (0700, as the helper makes it): a FileView sees no file in a missing folder. A dev session runs no helper unless it
// names one (GRASSFIELD_CAPTURE_HELPER, ADR-0019: a fake in the nested checks) and reads its state from the dev state
// (GRASSFIELD_STATE_HOME), never the real session's.
Singleton {
    id: root

    readonly property string tool: Mode.dev ? Mode.devValue("CAPTURE_HELPER") : "/usr/lib/grassfield/grassfield-capture"
    readonly property string path: CaptureFile.statePath(Mode.stateHome, Quickshell.env("XDG_RUNTIME_DIR"))
    readonly property string folder: root.path !== "" ? root.path.substring(0, root.path.lastIndexOf("/")) : ""

    // The helper's acknowledgement file (ADR-0066 D-1), next to the state: pre-created 0600 in the 0700 folder at start
    // (capture-ack.sh), because a FileView cannot set modes.
    readonly property string ackPath: root.folder !== "" ? root.folder + "/capture-ack" : ""
    // True while no thumbnail card is mapped and one frame has passed since the last one went. The thumbnail layer (slice A2)
    // binds it; until then there are no cards, so it stays true. The acknowledgement waits for it.
    property bool thumbnailsHidden: true
    // The last `seq` acknowledged, so that one `shooting` state is acknowledged once.
    property string ackedSeq: ""

    // The state as read (CaptureFile.parse): phase idle | starting | selecting | countdown | recording | shooting | frozen, and its fields.
    property var state: CaptureFile.parse("")
    readonly property string phase: root.state.phase
    readonly property bool recording: root.phase === "recording"
    // The clock of the countdown and of the elapsed time, a tick a quarter of a second while either shows.
    property real now: Date.now()
    readonly property int secondsLeft: root.phase === "countdown" ? CaptureFile.secondsLeft(root.now, root.state.until) : 0
    readonly property bool countingDown: root.secondsLeft > 0
    readonly property string elapsedText: CaptureFile.elapsed(root.now - root.state.started)
    // gpu-screen-recorder is installed (an Omarchy base package): asked when the toolbar opens, as it is used (OC-0 rule 3).
    property bool recorderAvailable: false

    // Runs the helper with `args`. In a real session it gets a scope of its own (uwsm-app, as the Dock starts apps): a recording
    // must not live in the shell's unit (its CPU and memory limits, its restarts). Nothing runs without a helper (a dev session).
    function run(args: var): void {
        if (root.tool === "") {
            console.info("grassfield: capture not run (dev session without GRASSFIELD_CAPTURE_HELPER): " + args.join(" "));
            return;
        }
        Apps.whenScopeKnown(() => Quickshell.execDetached(Apps.scoped([root.tool].concat(args))));
    }

    // Ends the recording, or the choice or countdown of a capture (the helper's `stop`, which signals only its own processes).
    function stop(): void {
        if (root.tool === "") {
            console.info("grassfield: capture stop not run (dev session without GRASSFIELD_CAPTURE_HELPER)");
            return;
        }
        Quickshell.execDetached([root.tool, "stop"]);
    }

    function probeRecorder(): void {
        if (!probe.running)
            probe.running = true;
    }

    // Nothing is captured behind the lock (macOS): whenever the session is locked and the helper's state is not idle, the helper
    // is stopped: a recording stops, a countdown or a choice captures nothing. Both edges count (CaptureFile.stopNeeded): the lock
    // coming while a capture runs, and a capture becoming active while locked (a helper slow to start after Record, a shell
    // restarted under the lock reading the state late). The helper also refuses to start under the lock and ends a recording when
    // the lock comes on its own (it reads the lock marker), so this does not depend on the shell alone.
    function enforceLock(): void {
        if (CaptureFile.stopNeeded(SessionState.locked, root.phase))
            root.stop();
    }

    onPhaseChanged: root.enforceLock()

    // Writes the acknowledgement of a `shooting` state once the cards are hidden: the `seq` alone, in place (capture-ack.sh keeps
    // the 0600 mode). Only after the preparation ran: the folder and the file exist by then. Asked on every change of what it reads.
    function acknowledge(): void {
        if (prepare.running || root.ackPath === "")
            return;
        const seq = CaptureFile.ackNeeded(root.state, root.thumbnailsHidden, root.ackedSeq);
        if (seq === "")
            return;
        root.ackedSeq = seq;
        Quickshell.execDetached(["sh", Quickshell.shellPath("services/capture-ack.sh"), root.folder, root.ackPath, seq]);
    }

    onStateChanged: root.acknowledge()
    onThumbnailsHiddenChanged: root.acknowledge()

    // The helper's result file (ADR-0066 D-1), read whole each time it is replaced: a picture or recording was saved. The floating
    // thumbnail (CaptureThumbnails) shows it. Only a result written lately counts (a file left from before the shell started is
    // not shown), and each one is announced once by its id (a reload of the same file is no new capture). The paths in it are data:
    // CaptureThumbs decides what may be shown.
    readonly property string resultPath: CaptureFile.resultPath(Mode.stateHome, Quickshell.env("XDG_RUNTIME_DIR"))
    property string lastResultId: ""
    signal resultArrived(var result)

    // Still not idle under the lock (the stop could not reach the helper yet: its state was written before its recorder): asked
    // again until the helper's state says idle.
    Timer {
        interval: 2000
        repeat: true
        running: CaptureFile.stopNeeded(SessionState.locked, root.phase)
        onTriggered: root.stop()
    }

    Connections {
        target: SessionState

        function onLockedChanged(): void {
            root.enforceLock();
        }
    }

    Timer {
        interval: 250
        repeat: true
        triggeredOnStart: true
        running: root.phase === "countdown" || root.phase === "recording"
        onTriggered: root.now = Date.now()
    }

    Process {
        id: probe
        command: ["sh", "-c", "command -v gpu-screen-recorder"]
        stdout: StdioCollector {
            onStreamFinished: root.recorderAvailable = text.trim() !== ""
        }
    }

    Process {
        id: prepare
        running: root.folder !== ""
        command: ["sh", Quickshell.shellPath("services/capture-ack.sh"), root.folder, root.ackPath]
        onRunningChanged: {
            if (!running) {
                stateFile.path = root.path;
                resultFile.path = root.resultPath;
                root.acknowledge();
            }
        }
    }

    FileView {
        id: resultFile
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const result = CaptureFile.parseResult(resultFile.text());
            if (result === null || result.id === root.lastResultId || !CaptureFile.resultFresh(result, Date.now(), Tokens.captureThumbnailFreshMs))
                return;
            root.lastResultId = result.id;
            root.resultArrived(result);
        }
    }

    FileView {
        id: stateFile
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.state = CaptureFile.parse(stateFile.text())
        onLoadFailed: root.state = CaptureFile.parse("")
    }

    Component.onCompleted: root.probeRecorder()
}
