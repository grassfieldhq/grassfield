pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "IdleModel.js" as IdleModel
import "../../lib/RunMode.js" as RunMode

// logind's view of this session (SS-02): its Lock signal locks, and its LockedHint follows the lock.
//
// `loginctl lock-session` / `lock-sessions` (an ssh login, a udev or Bluetooth proximity script, a third-party tool) and
// logind.conf's HandleLidSwitch=lock, HandleLidSwitchExternalPower=lock, HandleLidSwitchDocked=lock or HandlePowerKey=lock
// make logind emit org.freedesktop.login1.Session.Lock on the session's object; the PrepareForSleep watcher
// (SleepInhibitor.qml) listens on the manager's object only and never saw it. Here a second `gdbus monitor` listens on this
// session's object only, and a Lock signal asks for the lock (`lockAsked`: Idle.qml calls Lock.lock("logind"), which only
// ever locks). The Unlock signal
// (`loginctl unlock-session`) is logged and ignored: only a PAM success opens the lock (fail closed; macOS has no remote
// unlock either).
//
// Which session is ours (the security process runs in the user manager, outside the login session's scope, so logind's
// "self" session does not name it), tried in this order, each a short busctl call bounded by `timeout`:
//   1. GetSession(XDG_SESSION_ID): uwsm exports the login's session id to the user manager;
//   2. the user's Display session (logind's graphical session of the user: /org/freedesktop/login1/user/self, Display);
//   3. GetSessionByPID(the compositor's pid, from Hyprland's instance lock file): works when the compositor runs in the
//      session's scope (a compositor started without uwsm).
// None found: logged, tried again every IdleModel.SLOW_RETRY_MS. The watcher is restarted after an exit like the
// PrepareForSleep watcher (IdleModel.failuresAfterRun / retryDelayMs); it never gives up.
//
// LockedHint (org.freedesktop.login1.Session.SetLockedHint, allowed to the session's owner without authorization): true once
// the lock holds (the compositor confirmed it), false once the session is unlocked (IdleModel.lockedHint); other tools read
// it (`loginctl show-session -p LockedHint`, idle daemons, remote management). Information only: nothing here reads it back,
// and a failed call changes nothing of the lock.
//
// A dev session follows nothing and sets nothing: its session would be the owner's (the nested compositor runs in it).
// Children run under `setpriv --pdeathsig TERM` (they die with this process).
Scope {
    id: root

    readonly property bool dev: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    // This session's object path ("" until found).
    property string sessionPath: ""
    // How it was found ("XDG_SESSION_ID", "Display", "compositor pid"), for the journal.
    property string foundBy: ""
    // The resolution step being tried (0..2; 3: none left).
    property int step: 0
    property int watcherFailures: 0
    // The LockedHint value logind last accepted (null: none yet).
    property var hintSent: null
    property bool hintFailing: false
    // The lock, bound by Idle.qml from Lock (any state but unlocked; the compositor confirmed it).
    property bool locked: false
    property bool holding: false
    readonly property var hintWanted: IdleModel.lockedHint(root.locked, root.holding)
    readonly property var dieWithShell: ["setpriv", "--pdeathsig", "TERM", "--"]
    readonly property var busctl: ["timeout", "-k", "1", "10", "busctl", "--system", "--timeout=5"]

    // Lock signals seen (for the offscreen test).
    property int lockSignals: 0

    // logind asked this session to lock.
    signal lockAsked

    onHintWantedChanged: root.pushHint()
    onSessionPathChanged: {
        if (root.sessionPath !== "")
            root.pushHint();
    }

    function resolve(): void {
        root.step = 0;
        root.tryStep();
    }

    function tryStep(): void {
        if (root.step === 0) {
            const id = Quickshell.env("XDG_SESSION_ID") || "";
            if (IdleModel.sessionIdValid(id)) {
                root.ask(finderId, ["call", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "GetSession", "s", id]);
                return;
            }
            root.step = 1;
        }
        if (root.step === 1) {
            root.ask(finderDisplay, ["get-property", "org.freedesktop.login1", "/org/freedesktop/login1/user/self", "org.freedesktop.login1.User", "Display"]);
            return;
        }
        if (root.step === 2) {
            const pid = root.compositorPid();
            if (pid > 0) {
                root.ask(finderPid, ["call", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "GetSessionByPID", "u", String(pid)]);
                return;
            }
            root.step = 3;
        }
        console.warn("grassfield-idle: logind session of this login not found (XDG_SESSION_ID, the user's Display session, the compositor's pid): `loginctl lock-session` and logind's lock actions do not reach the lock; trying again in " + IdleModel.SLOW_RETRY_MS / 1000 + " s");
        resolveRetry.restart();
    }

    // One process per route: the next route starts from the previous one's answer, while that process may still be
    // reported running (a Process whose `running` is set again while it runs would ignore it).
    function ask(finder: Process, args: var): void {
        if (finder.running) {
            console.warn("grassfield-idle: a logind session query is still running; tried again later");
            resolveRetry.restart();
            return;
        }
        finder.command = root.busctl.concat(args);
        finder.running = true;
    }

    function found(text: string): void {
        const path = IdleModel.sessionPathFrom(text);
        if (path === "") {
            root.step += 1;
            root.tryStep();
            return;
        }
        root.foundBy = ["XDG_SESSION_ID", "Display", "compositor pid"][root.step] || "";
        console.info("grassfield-idle: logind session " + path + " (by " + root.foundBy + "): its Lock signal locks, LockedHint follows the lock");
        root.sessionPath = path;
        watcher.running = true;
    }

    function compositorPid(): int {
        if (hyprLock.path === "")
            return 0;
        hyprLock.reload();
        hyprLock.waitForJob();
        return IdleModel.compositorPid(hyprLock.text());
    }

    function handleLine(line: string): void {
        if (!watcher.progressed && IdleModel.watcherSubscribed(line)) {
            watcher.progressed = true;
            return;
        }
        const signal = IdleModel.sessionSignal(line, root.sessionPath);
        if (signal === "lock") {
            root.lockSignals += 1;
            console.info("grassfield-idle: logind asks this session to lock (loginctl lock-session, or a lock action of logind.conf)");
            root.lockAsked();
        } else if (signal === "unlock") {
            console.info("grassfield-idle: logind asks this session to unlock; ignored (only a password or a fingerprint opens the lock)");
        }
    }

    function pushHint(): void {
        if (root.dev || root.sessionPath === "" || root.hintWanted === null || hinter.running)
            return;
        if (root.hintWanted === root.hintSent && !root.hintFailing)
            return;
        hinter.value = root.hintWanted;
        hinter.command = root.busctl.concat(["call", "org.freedesktop.login1", root.sessionPath, "org.freedesktop.login1.Session", "SetLockedHint", "b", hinter.value ? "true" : "false"]);
        hinter.running = true;
    }

    Process {
        id: finderId
        stdout: StdioCollector {
            onStreamFinished: root.found(String(text))
        }
    }
    Process {
        id: finderDisplay
        stdout: StdioCollector {
            onStreamFinished: root.found(String(text))
        }
    }
    Process {
        id: finderPid
        stdout: StdioCollector {
            onStreamFinished: root.found(String(text))
        }
    }

    Timer {
        id: resolveRetry
        interval: IdleModel.SLOW_RETRY_MS
        onTriggered: root.resolve()
    }

    Process {
        id: watcher

        property bool ranLong: false
        property bool progressed: false

        command: root.dieWithShell.concat(["gdbus", "monitor", "--system", "--dest", "org.freedesktop.login1", "--object-path", root.sessionPath])
        stdout: SplitParser {
            onRead: line => root.handleLine(line)
        }
        onStarted: {
            ranLong = false;
            progressed = false;
            watcherHealthy.restart();
        }
        onRunningChanged: {
            if (running || root.sessionPath === "")
                return;
            watcherHealthy.stop();
            root.watcherFailures = IdleModel.failuresAfterRun(root.watcherFailures, ranLong);
            ranLong = false;
            watcherRestart.interval = IdleModel.retryDelayMs(root.watcherFailures);
            console.warn("grassfield-idle: logind session watcher exited (" + root.watcherFailures + " early exits in a row); retrying in " + watcherRestart.interval / 1000 + " s");
            watcherRestart.restart();
        }
    }

    Timer {
        id: watcherHealthy
        interval: IdleModel.FAST_EXIT_MS
        onTriggered: {
            if (watcher.running && watcher.progressed) {
                watcher.ranLong = true;
                root.watcherFailures = 0;
            }
        }
    }

    Timer {
        id: watcherRestart
        interval: IdleModel.FAST_RETRY_MS
        onTriggered: watcher.running = root.sessionPath !== ""
    }

    Process {
        id: hinter

        property bool value: false

        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0 && exitStatus === 0) {
                root.hintSent = hinter.value;
                if (root.hintFailing)
                    console.info("grassfield-idle: logind accepts LockedHint again");
                root.hintFailing = false;
            } else {
                if (!root.hintFailing)
                    console.warn("grassfield-idle: logind refused LockedHint=" + hinter.value + " (busctl exit " + exitCode + "); information only, the lock is unaffected; tried again in " + hintRetry.interval / 1000 + " s");
                root.hintFailing = true;
                hintRetry.restart();
            }
        }
        // A change while the call ran is sent once it is over (a failure waits for hintRetry).
        onRunningChanged: {
            if (!hinter.running && !root.hintFailing)
                Qt.callLater(root.pushHint);
        }
    }

    Timer {
        id: hintRetry
        interval: IdleModel.SLOW_RETRY_MS
        onTriggered: root.pushHint()
    }

    // Hyprland's instance lock file: its first line is the compositor's pid (step 3 of the resolution).
    FileView {
        id: hyprLock
        path: {
            const dir = Quickshell.env("XDG_RUNTIME_DIR") || "";
            const sig = Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "";
            return dir !== "" && sig !== "" && /^[A-Za-z0-9_.-]+$/.test(sig) ? dir + "/hypr/" + sig + "/hyprland.lock" : "";
        }
        preload: false
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: {
        if (root.dev) {
            console.info("grassfield-idle: logind session not followed (dev session: it would be the owner's)");
            return;
        }
        root.resolve();
    }
}
