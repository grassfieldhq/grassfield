import QtQuick
import QtTest
import "../../shell/menubar/StatusLogic.js" as Logic

// Pure decisions of the menu bar's status area: which tray items get a slot, what a press does (StatusNotifierItem
// semantics), the accessible name, when Now Playing shows, and which items crowding hides.
TestCase {
    name: "StatusLogic"

    function item(over) {
        return Object.assign({id: "app", title: "App", tooltipTitle: "", icon: "image://icon/app", status: 1, hasMenu: true, onlyMenu: false}, over || {});
    }

    function test_traySlots() {
        verify(Logic.trayShown(item()));
        verify(Logic.trayShown(item({status: 2})), "NeedsAttention is shown");
        verify(!Logic.trayShown(item({status: 0})), "Passive is hidden");
        verify(!Logic.trayShown(item({icon: ""})), "no icon: a phantom slot");
        verify(!Logic.trayShown(null));
        verify(!Logic.trayShown(undefined));
        verify(!Logic.trayShown("chrome_status_icon_1"), "an id string is not an item");
    }

    function test_attention() {
        verify(Logic.needsAttention(item({status: 2})));
        verify(!Logic.needsAttention(item()));
        verify(!Logic.needsAttention(null));
    }

    function test_clickSemantics() {
        // Not ItemIsMenu: the primary click is Activate, the menu is the context menu.
        compare(Logic.clickAction(item(), "left"), "activate");
        compare(Logic.clickAction(item(), "right"), "menu");
        compare(Logic.clickAction(item(), "middle"), "secondary");
        // ItemIsMenu: the primary click opens the menu.
        compare(Logic.clickAction(item({onlyMenu: true}), "left"), "menu");
        // ItemIsMenu without a menu: nothing to open, Activate.
        compare(Logic.clickAction(item({onlyMenu: true, hasMenu: false}), "left"), "activate");
        // No menu at all: the context click does nothing.
        compare(Logic.clickAction(item({hasMenu: false}), "right"), "none");
        compare(Logic.clickAction(null, "left"), "none");
    }

    function test_opensMenu() {
        verify(Logic.opensMenu(item()));
        verify(!Logic.opensMenu(item({hasMenu: false})));
        verify(!Logic.opensMenu(null));
    }

    function test_accessibleName() {
        compare(Logic.accessibleName(item({title: " Steam "})), "Steam");
        compare(Logic.accessibleName(item({title: "", tooltipTitle: "Tip"})), "Tip");
        compare(Logic.accessibleName(item({title: "  ", tooltipTitle: "", id: "chrome_status_icon_1"})), "chrome_status_icon_1");
        compare(Logic.accessibleName(null), "");
    }

    function test_nowPlaying() {
        verify(Logic.nowPlayingShown(true, true, true, ""), "playing");
        verify(Logic.nowPlayingShown(true, true, false, "Song"), "paused with a track");
        verify(!Logic.nowPlayingShown(true, true, false, ""), "a player with no track");
        verify(!Logic.nowPlayingShown(true, false, true, "Song"), "no player");
        verify(!Logic.nowPlayingShown(false, true, true, "Song"), "turned off in Settings");
    }

    function keys(hidden) {
        return Object.keys(hidden).sort().join(",");
    }

    function bar(widths) {
        return widths.map((w, i) => ({key: "k" + i, width: w, optional: i < 3}));
    }

    function test_crowdingNothingHiddenWhenItFits() {
        compare(keys(Logic.hiddenItems(100, bar([20, 20, 20, 20, 20]), 0)), "");
        compare(keys(Logic.hiddenItems(120, bar([20, 20, 20, 20, 20]), 4)), "");
    }

    function test_crowdingHidesFromTheLeft() {
        // 100 needed, 80 available: the leftmost optional goes first.
        compare(keys(Logic.hiddenItems(80, bar([20, 20, 20, 20, 20]), 0)), "k0");
        compare(keys(Logic.hiddenItems(60, bar([20, 20, 20, 20, 20]), 0)), "k0,k1");
        compare(keys(Logic.hiddenItems(40, bar([20, 20, 20, 20, 20]), 0)), "k0,k1,k2");
    }

    function test_crowdingNeverHidesMandatory() {
        // Only the two mandatory items remain, they stay even when they do not fit.
        compare(keys(Logic.hiddenItems(10, bar([20, 20, 20, 20, 20]), 0)), "k0,k1,k2");
    }

    function test_crowdingStopsAsSoonAsItFits() {
        // Widths differ: dropping the first (30) is enough for 100 -> 70.
        compare(keys(Logic.hiddenItems(75, bar([30, 10, 10, 25, 25]), 0)), "k0");
    }

    function test_crowdingCountsTheGap() {
        // 5 items of 20 plus a gap of 2 each = 110: 105 available hides one.
        compare(keys(Logic.hiddenItems(105, bar([20, 20, 20, 20, 20]), 2)), "k0");
    }

    function test_crowdingEmpty() {
        compare(keys(Logic.hiddenItems(0, [], 0)), "");
    }

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText.replace(/\/\/.*$/gm, "");
    }

    // The Screen Capture item (menubar.showScreenCapture, owner 2026-11-07), wired as no pure function carries it: an optional
    // status item (crowding hides it first among the optional ones it precedes), shown only when the setting is on, named for
    // assistive technology, and opening the capture toolbar on its own bar's display through shell.qml.
    function test_screenCaptureItemWiring() {
        const bar = source("shell/menubar/MenuBar.qml");
        verify(bar.indexOf('if (Settings.menubarShowScreenCapture)\n                    list.push({key: "capture", width: statusIconWidth, optional: true});') >= 0, "an optional status item");
        verify(bar.indexOf("visible: Settings.menubarShowScreenCapture && !win.hiddenStatus.capture") >= 0, "the setting and crowding");
        verify(bar.indexOf('accessibleName: qsTr("Screen Capture")') >= 0, "its accessible name");
        verify(bar.indexOf('onActivated: root.captureRequested(win.screen ? win.screen.name : "")') >= 0, "its bar's display");
        verify(bar.indexOf("active: root.captureActive") >= 0, "lit while the toolbar is open");
        const shell = source("shell/shell.qml");
        verify(shell.indexOf("captureActive: captureSurface.open") >= 0);
        verify(shell.indexOf("onCaptureRequested: screen => captureSurface.toggleOn(screen)") >= 0);
        const capture = source("shell/capture/Capture.qml");
        verify(capture.indexOf("screenName = ScreenChoice.pick(requestedScreen, Compositor.activeScreenName, Quickshell.screens.map(s => s.name));") >= 0,
            "the named display, else the active one");
        verify(capture.indexOf("requestedScreen = screen;\n        show();\n        requestedScreen = \"\";") >= 0, "through show(), the one opener");
        verify(capture.indexOf('if (SessionState.refuses("capture"))') >= 0, "never over the lock screen");
    }
}
