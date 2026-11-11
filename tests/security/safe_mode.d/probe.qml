import QtQuick
import Quickshell
import qs.security.safemode

// ADR-0041 S4, the REAL safe-mode controller (shell/security/safemode/SafeMode.qml and SafeModeModel.js) under Quickshell,
// offscreen, in a dev session (its looks are the fake ones of `safemode devSet`; it never asks systemd and its actions log
// that they were suppressed), with a stand-in notice (no window offscreen). The probe plays the host: it binds the lock, the
// sheets and the displays. Checks: the notice exists only after two looks that say safe mode, only while unlocked, with no
// sheet up and the displays on; the lock, a sheet or the displays going off destroy it at once and refuse Try Again and Log
// Out; it comes back after; a press within the guard after it appears is refused (the wake key, a repeated Return: the opus
// review of a0df9c3e, MINOR-2), one after it acts; the notice's buttons reach the actions; Try Again ends safe mode; an
// action under way refuses another. Steps run in order, some after a wait. Prints "safe-mode: PASS (<n> checks)" or
// "safe-mode: FAIL: <names>" and exits.
ShellRoot {
    id: root

    property bool locked: false
    property bool sheetUp: false
    property bool displaysOff: false
    property var failures: []
    property int checks: 0

    function check(name: string, ok: bool): void {
        checks++;
        if (!ok)
            failures.push(name);
    }

    SafeMode {
        id: sm
        locked: root.locked
        sheetUp: root.sheetUp
        displaysOff: root.displaysOff
    }

    // The notice while it exists, untyped (its properties are the stand-in's).
    function noticeOf(): var {
        return sm.noticeItem;
    }

    function twoLooks(on: bool): void {
        sm.devWanted = on;
        sm.look();
        sm.look();
    }

    // Past the guard after the notice appeared.
    readonly property int settle: 700

    // [function, wait in ms before the next one]
    readonly property var steps: [
        [() => {
            root.check("dev hooks open in this run", sm.devHooks === true);
            root.check("nothing at start", !sm.confirmed && !sm.shown && sm.noticeItem === null);
            // One look is not enough (a flag at a login before the autostart; a unit passing through failed).
            sm.devWanted = true;
            sm.look();
            root.check("one look: not confirmed, no notice", !sm.confirmed && sm.noticeItem === null);
            sm.devWanted = false;
            sm.look();
            sm.devWanted = true;
            sm.look();
            root.check("a look that says no starts the count over", !sm.confirmed && sm.noticeItem === null);
            sm.look();
            root.check("two looks in a row: confirmed and shown, the notice made", sm.confirmed && sm.shown && sm.noticeItem !== null);
            // The guard (MINOR-2): a press at once after the notice appears is refused.
            root.check("in the guard: not armed", sm.armed === false);
            root.check("in the guard: Try Again refused", sm.tryAgain() === "refused");
            root.check("in the guard: Log Out refused", sm.logOut() === "refused");
        }, root.settle],
        [() => {
            root.check("after the guard: armed", sm.armed === true);
            sm.failure = "logOut";
            root.check("the notice gets the controller's failure", sm.noticeItem !== null && root.noticeOf().failure === "logOut");
            sm.failure = "";
            // The lock always wins.
            root.locked = true;
            root.check("locked: the notice is gone at once, disarmed", !sm.shown && sm.noticeItem === null && !sm.armed);
            root.check("locked: Try Again refused", sm.tryAgain() === "refused");
            root.check("locked: Log Out refused", sm.logOut() === "refused");
            root.check("locked: nothing runs, safe mode still known", sm.running === "" && sm.confirmed);
            sm.look();
            root.check("locked: a new look shows nothing", sm.noticeItem === null);
            root.locked = false;
            root.check("unlocked: the notice is back", sm.shown && sm.noticeItem !== null);
            root.check("unlocked: a press at once is refused (a repeated Return of the password)", sm.tryAgain() === "refused");
        }, root.settle],
        [() => {
            // A polkit or secret sheet of the security process: no notice, no action.
            root.sheetUp = true;
            root.check("a sheet up: the notice is gone", !sm.shown && sm.noticeItem === null);
            root.check("a sheet up: Try Again refused", sm.tryAgain() === "refused");
            root.check("a sheet up: Log Out refused", sm.logOut() === "refused");
            root.sheetUp = false;
            root.check("the sheet gone: the notice is back", sm.shown && sm.noticeItem !== null);
        }, root.settle],
        [() => {
            // The displays off while unlocked (MINOR-2): no notice, no action; the wake key finds none, and the notice that
            // comes back takes no press at once.
            root.displaysOff = true;
            root.check("the displays off: the notice is gone", !sm.shown && sm.noticeItem === null);
            root.check("the displays off: Try Again refused", sm.tryAgain() === "refused");
            root.check("the displays off: Log Out refused", sm.logOut() === "refused");
            root.displaysOff = false;
            root.check("the displays on: the notice is back", sm.shown && sm.noticeItem !== null);
            root.check("the displays on: the wake key's press is refused", sm.tryAgain() === "refused" && sm.logOut() === "refused");
        }, root.settle],
        [() => {
            // An action under way refuses another.
            sm.running = "logOut";
            root.check("busy: Try Again refused", sm.tryAgain() === "refused");
            root.check("busy: the notice gets the action under way", root.noticeOf().running === "logOut");
            sm.running = "";
            // The notice's buttons reach the actions. Log Out (dev: suppressed) leaves safe mode as it was.
            root.noticeOf().logOut();
            root.check("the notice's Log Out reaches the controller (dev: suppressed, nothing runs)", sm.running === "" && sm.shown && sm.noticeItem !== null);
            // Try Again (dev: the fake unit is back) ends safe mode and the notice.
            root.noticeOf().tryAgain();
            root.check("the notice's Try Again ends safe mode (dev)", !sm.confirmed && !sm.shown && sm.noticeItem === null && !sm.devWanted);
            sm.look();
            root.check("after Try Again a look shows nothing", sm.noticeItem === null);
            root.check("Try Again with no notice is refused", sm.tryAgain() === "refused");
            // A second loop brings it back.
            root.twoLooks(true);
            root.check("a second loop: the notice again", sm.shown && sm.noticeItem !== null);
            // The desktop back by any other path: the next look ends it.
            root.twoLooks(false);
            root.check("the desktop back: the notice is gone", !sm.confirmed && sm.noticeItem === null);
            // Locked before safe mode is confirmed: nothing until the unlock.
            root.locked = true;
            root.twoLooks(true);
            root.check("confirmed while locked: no notice", sm.confirmed && sm.noticeItem === null);
            root.locked = false;
            root.check("then unlocked: the notice", sm.noticeItem !== null);
        }, 0]
    ]
    property int step: 0

    function finish(): void {
        if (root.failures.length === 0) {
            console.log("safe-mode: PASS (" + root.checks + " checks)");
            Qt.exit(0);
        } else {
            console.log("safe-mode: FAIL: " + root.failures.join("; "));
            Qt.exit(1);
        }
    }

    Timer {
        id: stepper
        interval: 200
        running: true
        onTriggered: {
            const s = root.steps[root.step];
            // A rule removed (a mutant) can leave the notice missing where the probe uses it: that is a failure, never a hang.
            try {
                s[0]();
            } catch (e) {
                root.failures.push("the probe stopped: " + e);
                root.finish();
                return;
            }
            root.step++;
            if (root.step >= root.steps.length) {
                root.finish();
                return;
            }
            stepper.interval = Math.max(1, s[1]);
            stepper.restart();
        }
    }
}
