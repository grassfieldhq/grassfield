import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/security/safemode/SafeModeModel.js" as Model
import "../../shell/security/safemode" as SafeMode

// ADR-0041 step 1, S4: safe mode's state logic (SafeModeModel.js) and the alert's keys (SafeModeCard.qml), offscreen. The
// controller itself (SafeMode.qml, its LazyLoader and its actions) runs under Quickshell in tests/security/safe_mode.sh; the
// host's wiring is pinned by tests/security/security_unit.sh, lock_surfaces.sh and security_process_scan.py.
Item {
    id: top
    width: 600
    height: 600

    readonly property string stoppedAfterLoop: "marker=1\nActiveState=inactive\nSubState=dead\nResult=success\n"
    readonly property string running: "marker=0\nActiveState=active\nSubState=running\nResult=success\n"

    function look(marker, active, sub, result) {
        return "marker=" + marker + "\nActiveState=" + active + "\nSubState=" + sub + "\nResult=" + result + "\n";
    }

    Component {
        id: cardComponent
        SafeMode.SafeModeCard {}
    }

    SignalSpy {
        id: tryAgainSpy
        signalName: "tryAgain"
    }
    SignalSpy {
        id: logOutSpy
        signalName: "logOut"
    }

    TestCase {
        name: "SafeModeModel"

        function test_parseLook() {
            const l = Model.parseLook(top.stoppedAfterLoop);
            verify(l.ok);
            compare(l.marker, true);
            compare(l.active, "inactive");
            compare(l.sub, "dead");
            compare(l.result, "success");
            // systemctl's order is not ours: any order reads the same.
            verify(Model.parseLook("ActiveState=failed\nResult=start-limit-hit\nSubState=failed\nmarker=0\n").ok);
            verify(Model.parseLook("marker=0\nActiveState=active\nSubState=running\nResult=success").ok, "no final newline");
        }

        // What cannot be read is no safe mode (never a guess).
        function test_parseLookRefusesWhatItCannotRead() {
            const bad = ["", "garbage", "marker=1\n", "marker=2\nActiveState=inactive\nSubState=dead\nResult=success\n",
                "marker=1\nActiveState=Inactive\nSubState=dead\nResult=success\n",
                "marker=1\nActiveState=inactive\nSubState=dead\nResult=success\nActiveState=active\n",
                "marker=1\nActiveState=inactive\nSubState=dead\nResult=success\nExecStart=/bin/sh\n",
                "marker=1\nActiveState=in active\nSubState=dead\nResult=success\n",
                "marker=1\r\nActiveState=inactive\r\nSubState=dead\r\nResult=success\r\n",
                "=1\nActiveState=inactive\nSubState=dead\nResult=success\n",
                "marker=1\nActiveState=inactive\nSubState=dead\nResult=" + "x".repeat(40) + "\n",
                "marker=1\nActiveState=inactive\nSubState=dead\nResult=success\n" + "#".repeat(5000)];
            for (let i = 0; i < bad.length; i++) {
                const l = Model.parseLook(bad[i]);
                verify(!l.ok, "refused: " + JSON.stringify(bad[i]).slice(0, 80));
                verify(!Model.wanted(l), "no safe mode from it");
            }
            verify(!Model.parseLook(undefined).ok);
            verify(!Model.parseLook(null).ok);
            verify(!Model.parseLook(42).ok);
        }

        // The flag present or absent, the unit down or not: safe mode only with the flag and the unit down for good, or at
        // the unit's own start limit (ADR-0056 D-10) with or without the flag.
        function test_wanted() {
            verify(Model.wanted(Model.parseLook(top.look(1, "inactive", "dead", "success"))), "flag, stopped by the counter");
            verify(Model.wanted(Model.parseLook(top.look(1, "failed", "failed", "signal"))), "flag, failed");
            verify(Model.wanted(Model.parseLook(top.look(0, "failed", "failed", "start-limit-hit"))), "no flag, at the start limit");
            verify(Model.wanted(Model.parseLook(top.look(1, "failed", "failed", "start-limit-hit"))), "flag, at the start limit");
            verify(!Model.wanted(Model.parseLook(top.look(0, "inactive", "dead", "success"))), "no flag: a stop by hand, or before the autostart");
            verify(!Model.wanted(Model.parseLook(top.look(0, "failed", "failed", "signal"))), "no flag, a failure on its way to a restart");
            verify(!Model.wanted(Model.parseLook(top.look(1, "active", "running", "success"))), "a stale flag, the shell back");
            verify(!Model.wanted(Model.parseLook(top.look(1, "activating", "auto-restart", "signal"))), "a stale flag, a restart under way");
            verify(!Model.wanted(Model.parseLook(top.look(1, "activating", "start", "success"))), "a stale flag, the shell starting");
            verify(!Model.wanted(Model.parseLook(top.look(1, "deactivating", "stop-sigterm", "success"))), "stopping");
            verify(!Model.wanted(Model.parseLook(top.look(1, "reloading", "reload", "success"))));
            verify(!Model.wanted({ok: false, marker: true, active: "inactive", sub: "dead", result: "success"}), "not ok");
            verify(!Model.wanted(null));
            verify(!Model.wanted(undefined));
            verify(Model.stopped(Model.parseLook(top.look(0, "inactive", "dead", "success"))));
            verify(!Model.stopped(Model.parseLook(top.look(0, "activating", "auto-restart", "success"))));
        }

        // Two looks in a row: a flag read once at a login before the autostart, or a unit passing through "failed", shows
        // nothing.
        function test_settle() {
            compare(Model.SETTLE_LOOKS, 2);
            let n = Model.settle(0, true);
            compare(n, 1);
            verify(!Model.confirmed(n), "one look is not enough");
            n = Model.settle(n, true);
            verify(Model.confirmed(n));
            n = Model.settle(n, true);
            compare(n, Model.SETTLE_LOOKS, "capped");
            compare(Model.settle(n, false), 0, "one look that says no ends it");
            compare(Model.settle(1, false), 0);
            compare(Model.settle(-3, true), 1);
            compare(Model.settle(undefined, true), 1);
            compare(Model.settle(1, "true"), 0, "only an exact true counts");
            verify(!Model.confirmed(undefined));
            verify(!Model.confirmed("2"));
        }

        // The lock always wins: on screen only when confirmed, unlocked, no sheet and the displays on (the opus review of
        // a0df9c3e, MINOR-2); anything but an exact false keeps it off.
        function test_shown() {
            verify(Model.shown(true, false, false, false));
            verify(!Model.shown(true, true, false, false), "locked: never over (or under) the lock");
            verify(!Model.shown(true, false, true, false), "a polkit or secret sheet open");
            verify(!Model.shown(true, false, false, true), "the displays off: the wake key finds no notice");
            verify(!Model.shown(true, true, true, true));
            verify(!Model.shown(false, false, false, false), "not in safe mode");
            const notFalse = [undefined, null, 0, "", "false", 1, true];
            for (let i = 0; i < notFalse.length; i++) {
                verify(!Model.shown(true, notFalse[i], false, false), "locked " + JSON.stringify(notFalse[i]));
                verify(!Model.shown(true, false, notFalse[i], false), "sheetUp " + JSON.stringify(notFalse[i]));
                verify(!Model.shown(true, false, false, notFalse[i]), "displaysOff " + JSON.stringify(notFalse[i]));
            }
            verify(!Model.shown(true, false, false), "a missing input keeps it off");
            verify(!Model.shown("true", false, false, false));
            verify(!Model.shown(1, false, false, false));
        }

        // Try Again and Log Out run only from a notice on screen for GUARD_MS, one at a time: never while locked, over a sheet
        // or with the displays off (the notice is not shown then), never in the guard after it appears, never twice.
        function test_canAct() {
            verify(Model.canAct(true, false, true));
            verify(!Model.canAct(true, true, true), "an action under way");
            verify(!Model.canAct(true, false, false), "in the guard after the notice appeared (the wake key, a repeated Return)");
            verify(!Model.canAct(false, false, true), "not on screen (locked, a sheet, the displays off, or no safe mode)");
            verify(!Model.canAct(Model.shown(true, true, false, false), false, true), "Try Again while locked");
            verify(!Model.canAct(Model.shown(true, false, true, false), false, true), "Try Again over a sheet");
            verify(!Model.canAct(Model.shown(true, false, false, true), false, true), "Try Again with the displays off");
            verify(!Model.canAct(undefined, false, true));
            verify(!Model.canAct(true, undefined, true));
            verify(!Model.canAct(true, false, undefined));
            verify(!Model.canAct(true, false, "true"));
            compare(Model.GUARD_MS, 500, "the sheets' held guard (AuthDialogModel.heldGuardMs)");
        }

        // What an action that did not finish says (NIT: the Log Out text for apps still open only on grassfield-session-end's
        // exit 3).
        function test_failureOf() {
            compare(Model.failureOf("tryAgain", 0), "");
            compare(Model.failureOf("logOut", 0), "");
            compare(Model.failureOf("tryAgain", 1), "tryAgain");
            compare(Model.failureOf("tryAgain", 124), "tryAgain", "its bound");
            compare(Model.failureOf("tryAgain", -1), "tryAgain", "could not start, or the guard gave up");
            compare(Model.failureOf("logOut", 3), "logOutOpen", "apps still open, or their list unreadable");
            compare(Model.failureOf("logOut", 4), "logOut", "the session could not be ended");
            compare(Model.failureOf("logOut", 124), "logOut");
            compare(Model.failureOf("logOut", -1), "logOut");
            verify(Model.ACTION_GUARD_MS > 330000, "above the Log Out command's own bound (330 s + 5)");
        }

        // A look that cannot be read changes nothing: no notice on a guess, none hidden either.
        function test_next() {
            const yes = Model.parseLook(top.stoppedAfterLoop);
            const no = Model.parseLook(top.running);
            const unread = Model.parseLook("garbage");
            compare(Model.next(0, yes), 1);
            compare(Model.next(1, yes), 2);
            compare(Model.next(2, no), 0, "a readable no starts over");
            compare(Model.next(0, unread), 0, "never shows on a guess");
            compare(Model.next(1, unread), 1, "keeps the count");
            compare(Model.next(2, unread), 2, "never hides an alert already up");
            verify(Model.confirmed(Model.next(Model.next(Model.next(0, yes), unread), yes)), "an unreadable look between two that agree");
            compare(Model.next(7, unread), Model.SETTLE_LOOKS, "capped");
            compare(Model.next(undefined, unread), 0);
            compare(Model.next(1, null), 1);
        }

        function test_lookInterval() {
            compare(Model.lookInterval(0, false), Model.LOOK_IDLE_MS);
            compare(Model.lookInterval(1, false), Model.LOOK_WATCH_MS);
            compare(Model.lookInterval(0, true), Model.LOOK_WATCH_MS);
            verify(Model.LOOK_WATCH_MS < Model.LOOK_IDLE_MS);
            verify(Model.LOOK_IDLE_MS <= 5000, "the notice comes within seconds of the stop");
        }

        // A dev session's fake looks read as the real ones.
        function test_devLook() {
            verify(Model.wanted(Model.parseLook(Model.devLook(true))));
            verify(!Model.wanted(Model.parseLook(Model.devLook(false))));
            verify(Model.parseLook(Model.devLook(false)).ok);
            verify(!Model.wanted(Model.parseLook(Model.devLook("true"))));
            compare(Model.MARKER, "shell-safe-mode", "the loop detector's file (packaging/bin/grassfield-shell-failed)");
        }
    }

    TestCase {
        name: "SafeModeCard"
        when: windowShown

        function make() {
            const card = createTemporaryObject(cardComponent, top);
            verify(card !== null);
            tryAgainSpy.target = card;
            logOutSpy.target = card;
            tryAgainSpy.clear();
            logOutSpy.clear();
            card.forceActiveFocus();
            card.takeFocus();
            return card;
        }

        function findChild(item, name) {
            if (!item)
                return null;
            if (item.objectName === name)
                return item;
            const kids = item.children;
            for (let i = 0; i < kids.length; i++) {
                const f = findChild(kids[i], name);
                if (f)
                    return f;
            }
            return null;
        }

        function test_accessible() {
            const card = make();
            compare(card.Accessible.role, Accessible.Dialog);
            compare(card.Accessible.name, "Grassfield is running in safe mode");
            verify(card.Accessible.description.indexOf("stopped working") >= 0);
            compare(findChild(card, "safeModeTryAgain").Accessible.name, "Try Again");
            compare(findChild(card, "safeModeLogOut").Accessible.name, "Log Out");
            compare(findChild(card, "safeModeSymbol").name, "exclamationmark-triangle", "the subject's symbol, never the Grassfield mark");
        }

        // Return (and Enter) is Try Again, the default button, wherever the keyboard is; Tab moves it between the buttons and
        // Space presses that one; Esc does nothing, never logs out.
        function test_keys() {
            const card = make();
            verify(card.activeFocus && card.keyTarget === 1, "the keyboard starts on the alert, its target the default button");
            keyClick(Qt.Key_Return);
            compare(tryAgainSpy.count, 1);
            keyClick(Qt.Key_Enter);
            compare(tryAgainSpy.count, 2);
            keyClick(Qt.Key_Escape);
            compare(tryAgainSpy.count, 2);
            compare(logOutSpy.count, 0, "Esc never logs out");
            keyClick(Qt.Key_Space);
            compare(tryAgainSpy.count, 3, "Space presses the target, Try Again at first");
            keyClick(Qt.Key_Tab);
            compare(card.keyTarget, 0, "Tab moves the keyboard to Log Out");
            verify(card.activeFocus, "the alert keeps the keyboard (the buttons take none)");
            keyClick(Qt.Key_Return);
            compare(tryAgainSpy.count, 4, "Return stays Try Again with Log Out as the target (the default button's key)");
            compare(logOutSpy.count, 0);
            keyClick(Qt.Key_Space);
            compare(logOutSpy.count, 1, "Space presses Log Out once it is the target");
            keyClick(Qt.Key_Backtab);
            compare(card.keyTarget, 1, "Shift+Tab moves it back");
        }

        // A key held down answers nothing, whatever it is and wherever the keyboard is (the delta opus review of b67472da,
        // NIT: a held Return on a focused button pressed it again once a failed Try Again gave the focus back). Its repeats
        // are taken (they reach nothing else) and act on nothing.
        function test_heldKeys() {
            const card = make();
            verify(card.handleKey(Qt.Key_Return, true), "a repeat is taken");
            verify(card.handleKey(Qt.Key_Enter, true));
            verify(card.handleKey(Qt.Key_Space, true));
            compare(tryAgainSpy.count, 0, "no repeat presses Try Again");
            verify(card.handleKey(Qt.Key_Tab, true));
            compare(card.keyTarget, 1, "a repeated Tab moves nothing");
            verify(card.handleKey(Qt.Key_Tab, false));
            compare(card.keyTarget, 0);
            verify(card.handleKey(Qt.Key_Space, true));
            verify(card.handleKey(Qt.Key_Return, true));
            compare(logOutSpy.count, 0, "no repeat presses Log Out");
            compare(tryAgainSpy.count, 0);
            // A failed Try Again gives the keyboard back to Try Again; a Return still held then repeats and acts on nothing.
            card.running = "tryAgain";
            card.running = "";
            card.failure = "tryAgain";
            tryVerify(() => card.activeFocus && card.keyTarget === 1, 1000, "the keyboard back on the alert, Try Again its target");
            verify(card.handleKey(Qt.Key_Return, true));
            compare(tryAgainSpy.count, 0, "the held Return does not start it again");
            verify(!card.handleKey(Qt.Key_A, false), "other keys go by");
            // The buttons take no focus, so no button can take a key (or its repeats) before the alert.
            compare(findChild(card, "safeModeTryAgain").focusPolicy, Qt.NoFocus);
            compare(findChild(card, "safeModeLogOut").focusPolicy, Qt.NoFocus);
        }

        // The buttons: a click on each emits its own intent and nothing else, and leaves the keyboard on the alert.
        function test_buttons() {
            const card = make();
            mouseClick(findChild(card, "safeModeLogOut"));
            compare(logOutSpy.count, 1);
            compare(tryAgainSpy.count, 0);
            verify(card.activeFocus, "a click leaves the keyboard on the alert");
            mouseClick(findChild(card, "safeModeTryAgain"));
            compare(tryAgainSpy.count, 1);
            compare(logOutSpy.count, 1);
        }

        // While an action runs both buttons are disabled and a line says what happens; after one that did not finish, a line
        // says so and the keyboard is back on Try Again.
        function test_busyAndFailure() {
            const card = make();
            const status = findChild(card, "safeModeStatus");
            verify(!status.visible);
            card.running = "tryAgain";
            verify(card.busy);
            verify(!findChild(card, "safeModeTryAgain").enabled);
            verify(!findChild(card, "safeModeLogOut").enabled);
            compare(status.text, "Restarting the desktop…");
            mouseClick(findChild(card, "safeModeLogOut"));
            compare(logOutSpy.count, 0, "a disabled button does nothing");
            card.running = "";
            card.failure = "tryAgain";
            verify(status.visible);
            verify(status.text.indexOf("couldn’t be restarted") >= 0);
            tryVerify(() => card.activeFocus && card.keyTarget === 1, 1000, "the keyboard back on Try Again");
            card.failure = "";
            card.running = "logOut";
            compare(status.text, "Logging out…");
            card.running = "";
            card.failure = "logOutOpen";
            verify(status.text.indexOf("weren’t logged out") >= 0);
            card.failure = "logOut";
            verify(status.text.indexOf("couldn’t be ended") >= 0);
        }

        // Light and dark (ADR-0041 S4): the alert draws from the current palette, the one the security host binds from the
        // user's appearance (Appearance.dark <- Settings.dark): its text, symbol, status lines and glass tint.
        function test_appearance() {
            const before = Appearance.dark;
            verify(String(Appearance.lightColors.text) !== String(Appearance.darkColors.text), "the two palettes differ");
            for (const dark of [false, true]) {
                Appearance.dark = dark;
                const palette = dark ? Appearance.darkColors : Appearance.lightColors;
                const which = dark ? "dark" : "light";
                const card = make();
                verify(Qt.colorEqual(findChild(card, "safeModeTitle").color, palette.text), which + ": the title" + " (" + findChild(card, "safeModeTitle").color + ")");
                verify(Qt.colorEqual(findChild(card, "safeModeMessage").color, palette.text), which + ": the message" + " (" + findChild(card, "safeModeMessage").color + ")");
                verify(Qt.colorEqual(findChild(card, "safeModeSymbol").color, palette.text), which + ": the symbol" + " (" + findChild(card, "safeModeSymbol").color + ")");
                verify(Qt.colorEqual(card.surface.tintColor, palette.materialTint), which + ": the glass tint" + " (" + card.surface.tintColor + ")");
                card.running = "tryAgain";
                verify(Qt.colorEqual(findChild(card, "safeModeStatus").color, palette.textSecondary), which + ": the line of an action under way" + " (" + findChild(card, "safeModeStatus").color + ")");
                card.running = "";
                card.failure = "tryAgain";
                verify(Qt.colorEqual(findChild(card, "safeModeStatus").color, palette.danger), which + ": the line of an action that did not finish" + " (" + findChild(card, "safeModeStatus").color + ")");
            }
            Appearance.dark = before;
        }

        // Fixed text: nothing it shows comes from a file or a process; the size comes from the tokens.
        function test_shape() {
            const card = make();
            compare(card.width, 260, "panel.alertWidth");
            verify(card.height > 0);
            const title = findChild(card, "safeModeTitle");
            compare(title.textFormat, Text.PlainText);
            compare(findChild(card, "safeModeMessage").textFormat, Text.PlainText);
        }
    }
}
