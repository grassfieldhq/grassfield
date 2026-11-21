import QtQuick
import Quickshell
import Quickshell.Io
import qs.security.idle

// SS-02 (security-session audit, round 2): the REAL shell/security/idle/LogindSession.qml under Quickshell, offscreen, NOT a
// dev session, with stub busctl, gdbus and setpriv first on PATH (tests/security/logind_session.sh writes them). The probe
// plays Idle: it binds `locked` and `holding` and counts `lockAsked`. Checks: the session found by the scenario's route
// (LOGIND_WANT_PATH); a Lock signal on that path asks for the lock, an Unlock signal and a Lock signal of another session do
// not; LockedHint follows the lock (true once holding, nothing while only locking, false once unlocked; what the stub was
// asked is read by the script). In a dev session (LOGIND_DEV=1) nothing is asked and nothing is found.
// Prints "logind-session: PASS (<n> checks)" or "logind-session: FAIL: <names>" and exits.
ShellRoot {
    id: root

    readonly property string stubs: Quickshell.env("LOGIND_STUBS") || ""
    readonly property string want: Quickshell.env("LOGIND_WANT_PATH") || ""
    readonly property bool devRun: Quickshell.env("LOGIND_DEV") === "1"
    property bool locked: false
    property bool holding: false
    property int asked: 0
    property var failures: []
    property int checks: 0

    function check(name: string, ok: bool): void {
        checks++;
        if (!ok)
            failures.push(name);
    }

    LogindSession {
        id: ls
        locked: root.locked
        holding: root.holding
        onLockAsked: root.asked++
    }

    // Appends one line to the stub gdbus's signal file (it follows the file).
    Process {
        id: emitter
    }
    function emit(lines: var): void {
        emitter.command = ["sh", "-c", "f=$1; shift; printf '%s\\n' \"$@\" >>\"$f\"", "emit", root.stubs + "/signals"].concat(lines);
        emitter.running = true;
    }

    property int step: 0
    property real stepStart: 0
    property real waitUntil: 0
    readonly property var steps: root.devRun ? [
        [() => 1500, 0, ""],
        [() => {
            root.check("dev: no session followed", ls.sessionPath === "");
            return true;
        }, 0, ""]
    ] : [
        [() => ls.sessionPath !== "", 8000, "the session is found"],
        [() => {
            root.check("found by the expected route (" + ls.sessionPath + " by " + ls.foundBy + ")", ls.sessionPath === root.want);
            return true;
        }, 0, ""],
        [() => ls.lockSignals === 0 && root.asked === 0 && ls.hintSent === false, 5000, "LockedHint false while unlocked, at start"],
        [() => {
            root.emit([root.want + ": org.freedesktop.login1.Session.Lock ()"]);
            return true;
        }, 0, ""],
        [() => root.asked === 1, 5000, "a Lock signal of this session asks for the lock"],
        [() => {
            root.locked = true;
            return 1000;
        }, 0, ""],
        [() => {
            root.check("locking: LockedHint unchanged", ls.hintSent === false);
            root.holding = true;
            return true;
        }, 0, ""],
        [() => ls.hintSent === true, 5000, "LockedHint true once the lock holds"],
        [() => {
            root.emit([root.want + ": org.freedesktop.login1.Session.Unlock ()", "/org/freedesktop/login1/session/_999: org.freedesktop.login1.Session.Lock ()"]);
            return 1500;
        }, 0, ""],
        [() => {
            root.check("an Unlock signal, or another session's Lock, asks for nothing", root.asked === 1 && ls.lockSignals === 1);
            root.holding = false;
            root.locked = false;
            return true;
        }, 0, ""],
        [() => ls.hintSent === false, 5000, "LockedHint false once unlocked"]
    ]

    function finish(): void {
        if (root.failures.length === 0) {
            console.log("logind-session: PASS (" + root.checks + " checks)");
            Qt.exit(0);
        } else {
            console.log("logind-session: FAIL: " + root.failures.join("; "));
            Qt.exit(1);
        }
    }

    Timer {
        id: ticker
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            if (root.step >= root.steps.length) {
                ticker.stop();
                root.finish();
                return;
            }
            const s = root.steps[root.step];
            const now = Date.now();
            if (root.waitUntil > 0) {
                if (now < root.waitUntil)
                    return;
                root.waitUntil = 0;
                root.step++;
                root.stepStart = 0;
                return;
            }
            if (root.stepStart === 0)
                root.stepStart = now;
            const done = s[0]();
            if (typeof done === "number") {
                root.waitUntil = now + done;
                return;
            }
            if (done === true) {
                root.step++;
                root.stepStart = 0;
                return;
            }
            if (s[1] > 0 && now - root.stepStart > s[1]) {
                root.failures.push("timed out: " + s[2] + " (" + JSON.stringify({path: ls.sessionPath, by: ls.foundBy, asked: root.asked, signals: ls.lockSignals, hint: ls.hintSent}) + ")");
                ticker.stop();
                root.finish();
            }
        }
    }
}
