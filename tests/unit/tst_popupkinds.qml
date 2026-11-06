import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/services/PopupKinds.js" as PopupKinds

// The popup kinds Popups.open accepts (shell/services/PopupKinds.js): exactly the kinds the Overlay draws, read from its
// Loader's switch the way tests/unit/tst_barbandwiring.qml reads the sources, and Popups.open asks for one. A kind the Overlay
// does not draw would map an empty overlay that takes the keyboard (the retired "about", review of ce69dc6); the refusal
// itself, on the real Popups, is in tests/security/lock_surfaces/shell.qml.
TestCase {
    name: "PopupKinds"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText.replace(/\/\/.*$/gm, "");
    }

    function test_unknownKindsAreRefused() {
        verify(!PopupKinds.known("about"));
        verify(!PopupKinds.known(""));
        verify(!PopupKinds.known("Forcequit"));
        verify(!PopupKinds.known(undefined));
        verify(PopupKinds.known("forcequit"));
        verify(PopupKinds.known("appabout"));
    }

    function test_theListIsTheOverlays() {
        const overlay = source("shell/overlay/Overlay.qml");
        const start = overlay.indexOf("sourceComponent: {");
        verify(start >= 0, "the Overlay's Loader switch");
        const end = overlay.indexOf("return null;", start);
        verify(end > start);
        const drawn = [];
        const pattern = /case "([A-Za-z]+)":/g;
        const body = overlay.slice(start, end);
        for (let m = pattern.exec(body); m !== null; m = pattern.exec(body))
            drawn.push(m[1]);
        drawn.sort();
        compare(drawn, PopupKinds.kinds.slice().sort());
    }

    // ADR-0040 IQ-B1 B (the review of 52b2bec): a notice shows its subject's symbol, the information symbol when the caller
    // gives none; a missing symbol through a string-typed parameter arrives as "undefined" and drew an empty frame.
    function test_aNoticeWithoutASymbolShowsInfo() {
        compare(PopupKinds.noticeSymbol("moon"), "moon");
        compare(PopupKinds.noticeSymbol(undefined), "info");
        compare(PopupKinds.noticeSymbol("undefined"), "info");
        compare(PopupKinds.noticeSymbol(""), "info");
        compare(PopupKinds.noticeSymbol(null), "info");
        const popups = source("shell/services/Popups.qml");
        verify(/function notice\(title: string, message: string, symbol\): void \{\s*openCentered\("notice", \{title: title, message: message, symbol: PopupKinds\.noticeSymbol\(symbol\)\}\);/.test(popups),
               "Popups.notice passes its untyped symbol through PopupKinds.noticeSymbol");
    }

    function test_openAsksForAKnownKind() {
        const popups = source("shell/services/Popups.qml");
        verify(popups.indexOf("if (!PopupKinds.known(popupKind)) {") > popups.indexOf("function open(popupKind"), "Popups.open checks the kind");
    }

    // ADR-0040 ID-21: Log Out, Restart and Shut Down count down and proceed by themselves; Force Quit and Empty Trash never act
    // without a click.
    function test_onlyTheSessionsEndCountsDown() {
        verify(PopupKinds.countsDown("logout"));
        verify(PopupKinds.countsDown("restart"));
        verify(PopupKinds.countsDown("shutdown"));
        verify(!PopupKinds.countsDown("forcequit"));
        verify(!PopupKinds.countsDown("emptytrash"));
        verify(!PopupKinds.countsDown(""));
        verify(!PopupKinds.countsDown(undefined));
    }

    function test_theCountdownSentence() {
        compare(PopupKinds.countdownMessage("restart", 60), "If you do nothing, the computer will restart automatically in 60 seconds.");
        compare(PopupKinds.countdownMessage("shutdown", 2), "If you do nothing, the computer will shut down automatically in 2 seconds.");
        compare(PopupKinds.countdownMessage("logout", 1), "If you do nothing, you will be logged out automatically in 1 second.");
        compare(PopupKinds.countdownMessage("restart", 1), "If you do nothing, the computer will restart automatically in 1 second.");
        compare(PopupKinds.countdownMessage("shutdown", 1), "If you do nothing, the computer will shut down automatically in 1 second.");
        compare(PopupKinds.countdownMessage("forcequit", 60), "");
        for (const action of PopupKinds.countdowns)
            verify(PopupKinds.countdownMessage(action, Tokens.sessionExitCountdownSeconds).indexOf(" " + Tokens.sessionExitCountdownSeconds + " seconds.") > 0, action);
    }

    // The confirmation (it needs Quickshell, so it is read from its source): the countdown is its message for those actions, it
    // starts again for each confirmation and confirms at zero; the System menu and Search give those actions no message of their
    // own (the countdown replaces it).
    function test_theConfirmationCountsDown() {
        const dialog = source("shell/overlay/ConfirmDialog.qml");
        verify(/message: countsDown \? PopupKinds\.countdownMessage\(info\.action, secondsLeft\)/.test(dialog), "the message is the countdown");
        verify(/readonly property bool countsDown: PopupKinds\.countsDown\(info\.action\)/.test(dialog));
        verify(/property int secondsLeft: Tokens\.sessionExitCountdownSeconds/.test(dialog));
        verify(/onInfoChanged: secondsLeft = Tokens\.sessionExitCountdownSeconds/.test(dialog), "each confirmation starts its own count");
        verify(/running: root\.countsDown && root\.secondsLeft > 0/.test(dialog));
        verify(/root\.secondsLeft--;\s*if \(root\.secondsLeft <= 0\)\s*root\.confirm\(\);/.test(dialog), "zero confirms");
        for (const path of ["shell/overlay/SystemMenu.qml", "shell/search/Search.qml"]) {
            const calls = source(path).match(/Popups\.confirm\([^;]*"(logout|restart|shutdown)", \{\}/g) || [];
            compare(calls.length, 3, path + ": Restart, Shut Down and Log Out");
            for (const call of calls)
                verify(/^Popups\.confirm\(qs(?:Tr|Translate)\((?:"(?:SystemMenu|Search)", )?"[^"]*"\)(\.arg\([A-Za-z.]*\))?, "", qs(?:Tr|Translate)\(/.test(call), call);
        }
    }
}
