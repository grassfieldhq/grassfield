pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "SafeModeModel.js" as Model
import "../../lib/RunMode.js" as RunMode

// Safe mode (ADR-0041 step 1, S4; the owner's SQ-1 B: "the UI unit failed, the security process is up", with a way out,
// never a lock-out). Instantiated once, by the security process's host (../host/SecurityHost.qml), never by the UI.
//
// What it does. It looks at the UI's unit every few seconds (`probe`: one short process, a fixed command: whether the loop
// detector's flag $XDG_RUNTIME_DIR/grassfield/shell-safe-mode exists, and systemd's ActiveState, SubState and Result of
// grassfield-shell.service). When the unit is down for good after a loop (SafeModeModel.wanted, two looks in a row), it
// shows one small alert (SafeModeNotice.qml, created only then) saying that the desktop stopped after repeated problems,
// with Try Again and Log Out. Nothing else of the desktop is drawn here: no Dock, menu bar, notification server or request
// socket (the crash of 2026-10-29 lived in those sockets, which this process never opens).
//
// The lock always wins. The notice exists only while the session is unlocked and no polkit or secret sheet of this process is
// open (SafeModeModel.shown, from `locked` and `sheetUp`, which the host binds from this process's own Lock and sheets and
// which read true until bound): it is destroyed the moment a lock is asked for, never drawn under or over the lock, and
// takes no key meant for a sheet. The actions refuse unless the notice is on screen (SafeModeModel.canAct), whatever asks.
// Nothing here locks, unlocks, approves or delays a lock; a failure of anything here leaves the lock as it is.
//
// The actions run fixed commands as the user, never anything read from a file:
// - Try Again: /usr/lib/grassfield/grassfield-shell-failed --try-again (the loop detector's own helper: it clears its ledger
//   and its flag, resets the unit's start limit and starts grassfield-shell.service with `systemctl --user`; the flag comes
//   back if the start fails). A second loop is the detector's to stop again, and the notice comes back; nothing here
//   restarts the shell on its own, so nothing loops.
// - Log Out: /usr/lib/grassfield/grassfield-session-end logout, the Grassfield menu's own path (every app asked to close,
//   none forced).
// A dev session never asks systemd (it would read the owner's own unit), never reads the owner's flag and runs neither
// action: its looks come from `safemode devSet` (SafeModeModel.devLook), and each action logs that it was suppressed.
Scope {
    id: root

    // Bound by the host from this process's lock (any state but unlocked, and the start-up probe of a stranded lock) and
    // sheets (a polkit or secret sheet open, shown or held, or its key sink). True until bound: no notice.
    property bool locked: true
    property bool sheetUp: true

    readonly property bool devHooks: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
    readonly property string markerPath: root.runtimeDir !== "" ? root.runtimeDir + "/grassfield/" + Model.MARKER : ""

    // The looks in a row that said safe mode.
    property int looks: 0
    readonly property bool confirmed: Model.confirmed(root.looks)
    readonly property bool shown: Model.shown(root.confirmed, root.locked, root.sheetUp)
    // The action under way ("" | "tryAgain" | "logOut") and the last one that did not finish.
    property string running: ""
    readonly property bool busy: root.running !== ""
    property string failure: ""
    // A dev session's fake look (`safemode devSet`).
    property bool devWanted: false

    onConfirmedChanged: {
        if (root.confirmed) {
            console.warn("grassfield-safe-mode: the desktop (grassfield-shell.service) stopped after repeated failures; the safe-mode notice shows while the session is unlocked");
        } else {
            root.failure = "";
            console.info("grassfield-safe-mode: the desktop is no longer stopped; no safe-mode notice");
        }
    }
    onShownChanged: console.info("grassfield-safe-mode: notice " + (root.shown ? "shown" : "hidden") + " (locked " + root.locked + ", sheet " + root.sheetUp + ")")

    // ---- The looks ----
    function look(): void {
        if (root.devHooks) {
            root.take(Model.devLook(root.devWanted));
            return;
        }
        if (!probe.running)
            probe.running = true;
    }

    function take(text: string): void {
        root.looks = Model.settle(root.looks, Model.wanted(Model.parseLook(text)));
    }

    // Starts the looks over (after an action, or a dev session's new fake look).
    function lookAgain(): void {
        root.look();
        lookTimer.restart();
    }

    // The flag is tested as a plain file that is not a link (`-f` and `! -L`), never read; the path is the script's argument,
    // never part of its text. Bounded: a look that does not end within 5 s is killed and reads as no answer.
    Process {
        id: probe
        command: ["/usr/bin/timeout", "-k", "1", "5", "/usr/bin/sh", "-c", "if [ -f \"$1\" ] && [ ! -L \"$1\" ]; then echo marker=1; else echo marker=0; fi; exec /usr/bin/systemctl --user show --property=ActiveState --property=SubState --property=Result grassfield-shell.service", "grassfield-safe-mode", root.markerPath]
        stdout: StdioCollector {
            onStreamFinished: root.take(String(text))
        }
    }

    Timer {
        id: lookTimer
        interval: Model.lookInterval(root.looks, root.shown)
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.look()
    }

    // ---- The actions (the notice's buttons, Return, and a dev session's `safemode devPress`) ----
    function refusal(): string {
        if (root.busy)
            return "busy";
        if (!root.confirmed)
            return "not in safe mode";
        if (root.locked)
            return "locked";
        return "a sheet is open";
    }

    function tryAgain(): string {
        if (!Model.canAct(root.shown, root.busy)) {
            console.warn("grassfield-safe-mode: Try Again refused (" + root.refusal() + ")");
            return "refused";
        }
        root.failure = "";
        if (root.devHooks) {
            console.warn("grassfield-safe-mode: dev session, suppressed Try Again (grassfield-shell-failed --try-again)");
            root.devWanted = false;
            root.looks = 0;
            root.lookAgain();
            return "ok";
        }
        console.info("grassfield-safe-mode: Try Again: starting the desktop");
        root.running = "tryAgain";
        tryAgainRun.code = -1;
        tryAgainRun.running = true;
        actionGuard.restart();
        return "ok";
    }

    function logOut(): string {
        if (!Model.canAct(root.shown, root.busy)) {
            console.warn("grassfield-safe-mode: Log Out refused (" + root.refusal() + ")");
            return "refused";
        }
        root.failure = "";
        if (root.devHooks) {
            console.warn("grassfield-safe-mode: dev session, suppressed grassfield-session-end logout");
            return "ok";
        }
        console.info("grassfield-safe-mode: Log Out");
        root.running = "logOut";
        logOutRun.code = -1;
        logOutRun.running = true;
        actionGuard.restart();
        return "ok";
    }

    // An action ended (its process ended, or the guard gave up on it). Try Again that started the desktop: the notice leaves
    // (its flag is gone, so the next looks say no). Anything else: the notice stays, with a line saying what did not finish.
    function finish(action: string, code: int): void {
        if (root.running !== action)
            return;
        actionGuard.stop();
        root.running = "";
        if (code === 0) {
            console.info("grassfield-safe-mode: " + action + " done");
            if (action === "tryAgain") {
                root.looks = 0;
                root.lookAgain();
            }
            return;
        }
        console.warn("grassfield-safe-mode: " + action + " did not finish (exit " + code + ")");
        root.failure = action;
    }

    Process {
        id: tryAgainRun
        property int code: -1
        command: ["/usr/bin/timeout", "-k", "2", "40", "/usr/lib/grassfield/grassfield-shell-failed", "--try-again"]
        onExited: (exitCode, exitStatus) => tryAgainRun.code = exitStatus === 0 ? exitCode : -1
        onRunningChanged: if (!tryAgainRun.running)
            Qt.callLater(() => root.finish("tryAgain", tryAgainRun.code))
    }

    Process {
        id: logOutRun
        property int code: -1
        command: ["/usr/bin/timeout", "-k", "5", "330", "/usr/lib/grassfield/grassfield-session-end", "logout"]
        onExited: (exitCode, exitStatus) => logOutRun.code = exitStatus === 0 ? exitCode : -1
        onRunningChanged: if (!logOutRun.running)
            Qt.callLater(() => root.finish("logOut", logOutRun.code))
    }

    // Both commands are bounded by `timeout`; this ends the wait if a process never reported its end (it could not start).
    Timer {
        id: actionGuard
        interval: 340000
        onTriggered: root.finish(root.running, -1)
    }

    // ---- The notice ----
    // The notice while it exists (null otherwise): for `safemode status` and the offscreen test (tests/security/safe_mode.sh).
    readonly property QtObject noticeItem: notice.item
    LazyLoader {
        id: notice
        active: root.shown
        source: Qt.resolvedUrl("SafeModeNotice.qml")
    }
    Binding {
        target: notice.item
        property: "running"
        value: root.running
        when: notice.item !== null
    }
    Binding {
        target: notice.item
        property: "failure"
        value: root.failure
        when: notice.item !== null
    }
    Connections {
        target: notice.item
        ignoreUnknownSignals: true

        function onTryAgain(): void {
            root.tryAgain();
        }

        function onLogOut(): void {
            root.logOut();
        }
    }

    // On the security instance only. Dev hooks: refused outside a dev session.
    IpcHandler {
        target: "safemode"

        // What the notice decides from (no private state): the looks, whether it is confirmed, on screen and made, the lock
        // and sheet inputs, the action under way and the last one that did not finish. JSON.
        function status(): string {
            if (!root.devHooks)
                return RunMode.REFUSED;
            return JSON.stringify({
                looks: root.looks,
                confirmed: root.confirmed,
                shown: root.shown,
                notice: root.noticeItem !== null,
                locked: root.locked,
                sheetUp: root.sheetUp,
                running: root.running,
                failure: root.failure
            });
        }

        // Fakes the next looks: the UI's unit stopped by the loop detector (true) or running (false).
        function devSet(on: bool): string {
            if (!root.devHooks)
                return RunMode.REFUSED;
            console.warn("grassfield-safe-mode: dev look set to " + (on ? "stopped after a loop" : "running"));
            root.devWanted = on;
            root.lookAgain();
            return on ? "stopped" : "running";
        }

        // A press of the notice's button `tryAgain` or `logOut`, through the same refusals ("ok" or "refused"); in a dev
        // session the actions themselves are suppressed.
        function devPress(button: string): string {
            if (!root.devHooks)
                return RunMode.REFUSED;
            if (button === "tryAgain")
                return root.tryAgain();
            if (button === "logOut")
                return root.logOut();
            return "unknown";
        }
    }
}
