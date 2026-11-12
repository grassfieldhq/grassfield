import QtQuick
import Quickshell
import Quickshell.Io
import qs.security.safemode

// ADR-0041 S4, the opus review of a0df9c3e, MINOR-3: the controller's real-session paths, NOT a dev session. A copy of
// SafeMode.qml whose three commands point at stubs (tests/security/safe_mode.sh writes them, and refuses to run a copy that
// still names a real systemctl or /usr/lib/grassfield): the look (the probe's own shell script, the flag in this run's
// runtime directory, a stub systemctl answering from a file; what the stubs were asked is read by safe_mode.sh after the run), finish() for every outcome of Try Again and Log Out, and the
// action guard (shortened in the copy) giving up on a process that does not end, a late end then changing nothing. The
// probe plays the host (unlocked, no sheet, the displays on) and drives the stubs through files. Prints
// "safe-mode-real: PASS (<n> checks)" or "safe-mode-real: FAIL: <names>" and exits.
ShellRoot {
    id: root

    readonly property string stubs: Quickshell.env("SAFE_MODE_STUBS") || ""
    readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR") || ""
    property var failures: []
    property int checks: 0

    function check(name: string, ok: bool): void {
        checks++;
        if (!ok)
            failures.push(name);
    }

    SafeMode {
        id: sm
        locked: false
        sheetUp: false
        displaysOff: false
    }

    // Writes one stub control file (or the flag).
    FileView {
        id: writer
        preload: false
        blockWrites: true
        printErrors: false
    }
    function put(path: string, text: string): void {
        writer.path = path;
        writer.setText(text);
    }

    // Waits: each step is [function returning true when done (or a number: wait that many ms), deadline ms, what failed].
    property int step: 0
    property real stepStart: 0
    // The end of a wait step (0: none).
    property real waitUntil: 0
    readonly property var steps: [
        [() => sm.confirmed && sm.armed && sm.noticeItem !== null, 8000, "the flag and an inactive unit, looked at by the real probe: the notice"],
        [() => {
            root.check("not a dev session", sm.devHooks === false);
            root.put(root.stubs + "/helper", "fail\n");
            root.check("Try Again (the helper will fail) starts", sm.tryAgain() === "ok" && sm.running === "tryAgain");
            return true;
        }, 1000, ""],
        [() => sm.running === "", 6000, "a Try Again whose helper fails ends"],
        [() => {
            root.check("a failed Try Again says so, the notice stays", sm.failure === "tryAgain" && sm.shown && sm.noticeItem !== null);
            root.put(root.stubs + "/helper", "slow\n");
            return true;
        }, 1000, ""],
        [() => sm.armed, 2000, "armed again"],
        [() => {
            root.check("Try Again (the helper hangs past the action guard) starts", sm.tryAgain() === "ok" && sm.running === "tryAgain" && sm.failure === "");
            return true;
        }, 1000, ""],
        [() => sm.running === "", 4000, "the action guard gives up on a helper that does not end"],
        [() => {
            root.check("the guard's end reads as a failure", sm.failure === "tryAgain" && sm.confirmed);
            return 3500;
        }, 0, ""],
        [() => {
            root.check("the helper's late end (exit 0) changes nothing", sm.running === "" && sm.failure === "tryAgain" && sm.confirmed);
            root.put(root.stubs + "/helper", "ok\n");
            return true;
        }, 1000, ""],
        [() => sm.armed, 2000, "armed for the Try Again that works"],
        [() => {
            root.check("Try Again (the helper starts the shell) starts", sm.tryAgain() === "ok");
            return true;
        }, 1000, ""],
        [() => sm.running === "" && !sm.confirmed && sm.noticeItem === null, 6000, "a Try Again that worked ends safe mode and the notice"],
        [() => {
            root.check("a Try Again that worked leaves no failure", sm.failure === "");
            // A second loop for Log Out: the flag back, the unit down.
            root.put(root.stubs + "/state", "inactive dead success\n");
            root.put(root.runtime + "/grassfield/shell-safe-mode", "loop 1 3\n");
            root.put(root.stubs + "/logout-rc", "3\n");
            return true;
        }, 1000, ""],
        [() => sm.confirmed && sm.armed, 8000, "the second loop's notice"],
        [() => {
            root.check("Log Out (apps still open) starts", sm.logOut() === "ok" && sm.running === "logOut");
            return true;
        }, 1000, ""],
        [() => sm.running === "", 6000, "a Log Out with apps open ends"],
        [() => {
            root.check("exit 3 of grassfield-session-end: apps still open", sm.failure === "logOutOpen" && sm.shown);
            root.put(root.stubs + "/logout-rc", "4\n");
            root.check("Log Out (the session not ended) starts", sm.logOut() === "ok");
            return true;
        }, 1000, ""],
        [() => sm.running === "", 6000, "a Log Out that cannot end the session ends"],
        [() => {
            root.check("any other exit: the session not ended", sm.failure === "logOut");
            return true;
        }, 1000, ""]
    ]

    function finish(): void {
        if (root.failures.length === 0) {
            console.log("safe-mode-real: PASS (" + root.checks + " checks)");
            Qt.exit(0);
        } else {
            console.log("safe-mode-real: FAIL: " + root.failures.join("; "));
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
            let done;
            try {
                done = s[0]();
            } catch (e) {
                root.failures.push("the probe stopped: " + e);
                ticker.stop();
                root.finish();
                return;
            }
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
                root.failures.push("timed out: " + s[2] + " (" + JSON.stringify({looks: sm.looks, confirmed: sm.confirmed, shown: sm.shown, armed: sm.armed, running: sm.running, failure: sm.failure}) + ")");
                ticker.stop();
                root.finish();
            }
        }
    }
}
