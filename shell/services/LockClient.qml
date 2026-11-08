pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import "LockClient.js" as Client
import "../lib/LockState.js" as LockState

// The UI's side of the session lock (ADR-0041 step 1, S2; ADR-0010 "Separate security process", risk 2). The lock, idle and
// the sleep inhibitor run in the security process (shell/security.qml); this singleton is how the UI knows and asks:
//   - it reads the state that process publishes (shell/security/lock/LockPublisher.qml: a file it rewrites on every
//     change and every LockState.HEARTBEAT_MS), through a file watch and a read every POLL_MS whatever the watch says;
//   - `locked` (what SessionState.locked follows, and with it every refusal of the UI) is fail closed
//     (LockState.uiLocked): no state yet, a state that cannot be read, no new beat for LockState.STALE_MS (the security
//     process is down, restarting, stopped at its start limit or hung), a state other than "unlocked", or the compositor's
//     own lock signal (`compositorLocked`: hyprland-lock-notify-v1 as the clipboard helper reads it, set by shell.qml) each
//     read locked. A push the UI missed is corrected by the next beat; until then the compositor's signal holds once the
//     lock is drawn;
//   - `request(reason)` asks the security process to lock (`lock lock` over IPC), retried while it does not answer (it
//     restarts within about a second), and in a real session handed to Grassfield's stand-in once (which starts a stopped
//     security unit, as for Omarchy's sleep lock);
//   - the applications' org.freedesktop.ScreenSaver inhibitors, which the menu bridge serves to the UI, are leased to the
//     security process's idle module (`idle inhibit`), renewed while they last, so that a crash here cannot keep the idle
//     lock off.
// Nothing here locks, unlocks or authenticates; the UI never writes the state file.
Singleton {
    id: root

    readonly property string path: LockState.filePath(Quickshell.env("XDG_RUNTIME_DIR"), Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"), Quickshell.env("WAYLAND_DISPLAY"))
    readonly property string securityRoot: Client.securityRoot(Quickshell.shellDir)
    // The file is read again this often whatever the watch says (a missed change notification never leaves the UI on an old
    // state for longer than one beat; the stale check reads it again before it decides).
    readonly property int pollMs: LockState.HEARTBEAT_MS

    // The last state read that parsed (LockState.parse), or null.
    property var last: null
    // A state was read and parsed, and the file still parses.
    property bool known: false
    // No new beat for LockState.STALE_MS (monotonic: a Timer), or none yet.
    property bool stale: true
    // The compositor reports a session lock (any locker's): set by shell.qml from the clipboard helper's reading of
    // hyprland-lock-notify-v1; false while that helper does not run (the history is off), which leaves the other inputs.
    property bool compositorLocked: false

    readonly property string state: root.known && root.last ? root.last.state : ""
    // What every refusal reads (SessionState.locked follows it, shell.qml).
    readonly property bool locked: LockState.uiLocked(root.known, root.stale, root.state, root.compositorLocked)
    // The lock is being acquired (the screen saver stays up meanwhile).
    readonly property bool lockStarting: LockState.uiLockStarting(root.known, root.stale, root.state)
    // The displays are off (idle, in the security process); without a fresh state, true: the polkit agent then lets no device
    // answer a request nobody might see (ADR-0045 OC-6), the restrictive side.
    readonly property bool displaysOff: !root.known || root.stale || (root.last !== null && root.last.displaysOff === true)
    // Where the lock's clouds came to rest on each output (the desktop draws them there, WallpaperState.setMotion).
    readonly property var motion: root.known && root.last ? root.last.motion : ({})

    onLockedChanged: console.info("grassfield: the session reads " + (root.locked ? "locked" : "unlocked") + " (state " + (root.state || "none") + (root.stale ? ", stale" : "") + (root.compositorLocked ? ", compositor locked" : "") + ")")

    // ---- reading the state ----
    function take(text: string): void {
        const read = LockState.parse(String(text).trim());
        if (!read.ok) {
            if (root.known)
                console.warn("grassfield: the security process's lock state cannot be read (" + (root.path || "no XDG_RUNTIME_DIR") + "): the session reads locked");
            root.known = false;
            return;
        }
        const fresh = LockState.isNewBeat(root.last, read);
        if (fresh && root.last !== null && read.writer !== root.last.writer)
            console.info("grassfield: the security process restarted (writer " + read.writer + ")");
        const restarted = root.last === null || read.writer !== root.last.writer;
        root.last = read;
        root.known = true;
        if (fresh) {
            if (root.stale)
                console.info("grassfield: the security process's lock state is fresh again (" + read.state + ")");
            root.stale = false;
            staleTimer.restart();
        }
        // A new security process has no lease yet: renew it at once if an application holds an inhibitor.
        if (restarted && root.busInhibited)
            root.sendInhibit();
    }

    // Read now (a tmpfs file of one line), blocking: the FileView's handlers below take what it read.
    function readNow(): void {
        if (root.path === "") {
            root.known = false;
            return;
        }
        file.reload();
        file.waitForJob();
    }

    FileView {
        id: file
        path: root.path
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.take(String(text()))
        // A missing or unreadable file: no state (locked).
        onLoadFailed: root.take("")
        onFileChanged: reload()
    }

    Timer {
        interval: root.pollMs
        repeat: true
        running: root.path !== ""
        onTriggered: root.readNow()
    }

    // No new beat for LockState.STALE_MS: read once more before deciding (an event loop that was busy may have queued the
    // change notification behind this Timer), then stale.
    Timer {
        id: staleTimer
        interval: LockState.STALE_MS
        onTriggered: {
            root.readNow();
            if (!staleTimer.running) {
                if (!root.stale)
                    console.warn("grassfield: no beat from the security process for " + LockState.STALE_MS / 1000 + " s (stopped, restarting or hung): the session reads locked");
                root.stale = true;
            }
        }
    }

    // ---- a security process that publishes nothing ----
    // A real session whose security process has published no state NO_STATE_RESTART_MS after this UI started (an upgrade
    // from a build before S2 left the earlier security process running, which hosts no lock; or it is hung) gets one
    // restart of its unit from here, once per start of this UI: the restarted process takes the lock back from the
    // crash-recovery marker if there was one (fail closed: the compositor keeps any lock meanwhile). A unit stopped at its
    // start limit stays stopped (`restart` does not reset it). Never in a dev session (no unit there).
    readonly property int noStateRestartMs: 15000
    property bool everKnown: false
    onKnownChanged: {
        if (root.known)
            root.everKnown = true;
    }

    Timer {
        interval: root.noStateRestartMs
        running: Mode.session && !root.everKnown
        onTriggered: {
            if (root.everKnown)
                return;
            console.warn("grassfield: the security process published no lock state within " + root.noStateRestartMs / 1000 + " s of this shell's start: restarting grassfield-security.service once (the session reads locked meanwhile)");
            Quickshell.execDetached(["systemctl", "--user", "--no-block", "restart", "grassfield-security.service"]);
        }
    }

    // ---- asking for a lock ----
    property bool requesting: false
    property string requestReason: ""
    property real requestStartedAt: 0
    // The stand-in was handed the request once already (a real session).
    property bool handedOver: false

    function request(reason: string): void {
        console.info("grassfield: lock requested (" + reason + "): asking the security process");
        if (root.securityRoot === "") {
            console.warn("grassfield: no security process path: the lock request cannot be sent");
            return;
        }
        if (root.requesting)
            return;
        root.requesting = true;
        root.requestReason = reason;
        root.handedOver = false;
        requestBudget.restart();
        root.sendRequest();
    }

    function sendRequest(): void {
        requestProc.command = Client.command("lock", root.securityRoot, []);
        requestProc.running = true;
    }

    function requestDone(answer: string): void {
        root.requesting = false;
        requestBudget.stop();
        requestRetry.stop();
        console.info("grassfield: lock request (" + root.requestReason + ") answered: " + answer);
    }

    Process {
        id: requestProc
        stdout: StdioCollector {
            id: requestOut
        }
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            const answer = String(requestOut.text).trim();
            if (code === 0 && Client.lockAnswered(answer)) {
                root.requestDone(answer);
                return;
            }
            if (!root.requesting)
                return;
            // A real session: Grassfield's stand-in starts a stopped security unit and asks it to lock (its own 10 s of
            // tries), once; meanwhile the direct tries go on.
            if (Mode.session && !root.handedOver) {
                root.handedOver = true;
                console.warn("grassfield: the security process does not answer; asking Grassfield's stand-in to start it and lock");
                Quickshell.execDetached(["/usr/lib/grassfield/omarchy-shims/omarchy-shell", "lock", "lock"]);
            }
            requestRetry.restart();
        }
    }

    Timer {
        id: requestRetry
        interval: Client.REQUEST_RETRY_MS
        onTriggered: {
            if (root.requesting)
                root.sendRequest();
        }
    }

    Timer {
        id: requestBudget
        interval: Client.REQUEST_BUDGET_MS
        onTriggered: {
            if (!root.requesting)
                return;
            root.requesting = false;
            requestRetry.stop();
            console.warn("grassfield: the security process did not answer the lock request (" + root.requestReason + ") within " + Client.REQUEST_BUDGET_MS / 1000 + " s");
        }
    }

    // ---- the screen saver inhibitors' lease ----
    // An application holds an org.freedesktop.ScreenSaver inhibitor (set by shell.qml from the menu bridge).
    property bool busInhibited: false
    onBusInhibitedChanged: root.sendInhibit()

    function sendInhibit(): void {
        if (root.securityRoot === "")
            return;
        if (inhibitProc.running) {
            inhibitProc.again = true;
            return;
        }
        inhibitProc.command = Client.command("inhibit", root.securityRoot, [Client.inhibitSeconds(root.busInhibited)]);
        inhibitProc.running = true;
    }

    Process {
        id: inhibitProc
        property bool again: false
        onRunningChanged: {
            if (!running && inhibitProc.again) {
                inhibitProc.again = false;
                Qt.callLater(root.sendInhibit);
            }
        }
    }

    Timer {
        interval: Client.INHIBIT_RENEW_MS
        repeat: true
        running: root.busInhibited
        onTriggered: root.sendInhibit()
    }
}
