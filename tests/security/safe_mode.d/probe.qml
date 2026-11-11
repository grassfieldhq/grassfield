import QtQuick
import Quickshell
import qs.security.safemode

// ADR-0041 S4, the REAL safe-mode controller (shell/security/safemode/SafeMode.qml and SafeModeModel.js) under Quickshell,
// offscreen, in a dev session (its looks are the fake ones of `safemode devSet`; it never asks systemd and its actions log
// that they were suppressed), with a stand-in notice (no window offscreen). The probe plays the host: it binds the lock and
// the sheets. Checks: the notice exists only after two looks that say safe mode, only while unlocked and no sheet is up;
// the lock (or a sheet) destroys it at once and refuses Try Again and Log Out; it comes back after the unlock; the notice's
// buttons reach the actions; Try Again (dev) ends safe mode; one look is not enough; an action under way refuses another.
// Prints "safe-mode: PASS (<n> checks)" or "safe-mode: FAIL: <names>" and exits.
ShellRoot {
    id: root

    property bool locked: false
    property bool sheetUp: false
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

    function run(): void {
        // Unbound inputs read locked and a sheet up (fail closed): a fresh controller never shows anything.
        check("dev hooks open in this run", sm.devHooks === true);
        check("nothing at start", !sm.confirmed && !sm.shown && sm.noticeItem === null);

        // One look is not enough (a flag at a login before the autostart; a unit passing through failed).
        sm.devWanted = true;
        sm.look();
        check("one look: not confirmed, no notice", !sm.confirmed && sm.noticeItem === null);
        sm.devWanted = false;
        sm.look();
        sm.devWanted = true;
        sm.look();
        check("a look that says no starts the count over", !sm.confirmed && sm.noticeItem === null);
        sm.look();
        check("two looks in a row: confirmed and shown, the notice made", sm.confirmed && sm.shown && sm.noticeItem !== null);
        sm.failure = "logOut";
        check("the notice gets the controller's failure", sm.noticeItem !== null && root.noticeOf().failure === "logOut");
        sm.failure = "";

        // The lock always wins.
        root.locked = true;
        check("locked: the notice is gone at once", !sm.shown && sm.noticeItem === null);
        check("locked: Try Again refused", sm.tryAgain() === "refused");
        check("locked: Log Out refused", sm.logOut() === "refused");
        check("locked: nothing runs, safe mode still known", sm.running === "" && sm.confirmed);
        sm.look();
        check("locked: a new look shows nothing", sm.noticeItem === null);
        root.locked = false;
        check("unlocked: the notice is back", sm.shown && sm.noticeItem !== null);

        // A polkit or secret sheet of the security process: no notice, no action.
        root.sheetUp = true;
        check("a sheet up: the notice is gone", !sm.shown && sm.noticeItem === null);
        check("a sheet up: Try Again refused", sm.tryAgain() === "refused");
        check("a sheet up: Log Out refused", sm.logOut() === "refused");
        root.sheetUp = false;
        check("the sheet gone: the notice is back", sm.shown && sm.noticeItem !== null);

        // An action under way refuses another.
        sm.running = "logOut";
        check("busy: Try Again refused", sm.tryAgain() === "refused");
        check("busy: the notice gets the action under way", root.noticeOf().running === "logOut");
        sm.running = "";

        // The notice's buttons reach the actions. Log Out (dev: suppressed) leaves safe mode as it was.
        root.noticeOf().logOut();
        check("the notice's Log Out reaches the controller (dev: suppressed, nothing runs)", sm.running === "" && sm.shown && sm.noticeItem !== null);
        // Try Again (dev: the fake unit is back) ends safe mode and the notice.
        root.noticeOf().tryAgain();
        check("the notice's Try Again ends safe mode (dev)", !sm.confirmed && !sm.shown && sm.noticeItem === null && !sm.devWanted);
        sm.look();
        check("after Try Again a look shows nothing", sm.noticeItem === null);
        check("Try Again with no notice is refused", sm.tryAgain() === "refused");

        // A second loop brings it back.
        twoLooks(true);
        check("a second loop: the notice again", sm.shown && sm.noticeItem !== null);
        // The desktop back by any other path: the next look ends it.
        twoLooks(false);
        check("the desktop back: the notice is gone", !sm.confirmed && sm.noticeItem === null);

        // Locked before safe mode is confirmed: nothing until the unlock.
        root.locked = true;
        twoLooks(true);
        check("confirmed while locked: no notice", sm.confirmed && sm.noticeItem === null);
        root.locked = false;
        check("then unlocked: the notice", sm.noticeItem !== null);
    }

    Timer {
        running: true
        interval: 200
        onTriggered: {
            // A rule removed (a mutant) can leave the notice missing where the probe uses it: that is a failure, never a hang.
            try {
                root.run();
            } catch (e) {
                root.failures.push("the probe stopped: " + e);
            }
            if (root.failures.length === 0) {
                console.log("safe-mode: PASS (" + root.checks + " checks)");
                Qt.exit(0);
            } else {
                console.log("safe-mode: FAIL: " + root.failures.join("; "));
                Qt.exit(1);
            }
        }
    }
}
