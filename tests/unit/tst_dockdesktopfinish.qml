import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/desktop/IconsLogic.js" as Logic
import "../../shell/services/RecentItemsLogic.js" as RecentItems

// The Dock, the desktop and the menu bar (ADR-0039 step 25; audit §3.21). The shell's surfaces load Quickshell, which is not
// here: their pure logic is called, the rest is read in the source. The menu bar's band under Reduce Transparency and Increase
// Contrast waits for #83, which edits MenuBar.qml.
TestCase {
    name: "DockDesktopFinish"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    // The desktop's labels take the menu bar's rule: black where the wallpaper under them is light enough, white with the halo
    // elsewhere and over an unknown wallpaper.
    function test_aLabelFollowsTheWallpaperUnderIt() {
        const below = Tokens.menubarToneLightBelow;
        verify(Logic.darkLabelOver({lumMin: 0.9, lumMax: 1}, below), "a bright wallpaper: dark labels");
        verify(Logic.darkLabelOver({lumMin: below, lumMax: 0.5}, below), "at the threshold: dark");
        verify(!Logic.darkLabelOver({lumMin: 0.1, lumMax: 0.9}, below), "a range that reaches the dark: white with the halo");
        verify(!Logic.darkLabelOver(null, below), "unknown: white");
        verify(!Logic.darkLabelOver({}, below), "no numbers: white");
        const icon = source("shell/desktop/DesktopIcon.qml");
        verify(/darkLabel \? Appearance\.lightColors\.barText : Appearance\.darkColors\.text/.test(icon), "the bar's dark foreground");
        compare(icon.split("!root.darkLabel").length - 1, 3, "the three halo passes go for a dark label");
        verify(icon.indexOf("style: root.emphasized || root.darkLabel ? Text.Normal : Text.Outline") > 0, "and the outline");
        verify(icon.indexOf("Backdrop.grids[root.screenName]") > 0 && icon.indexOf("Backdrop.wallpapers[root.screenName]") > 0,
               "read from the wallpaper's grid, whatever the windows (not the bare-desktop backdrops)");
    }

    function test_menuSectionTitlesAreHeaders() {
        const rows = RecentItems.menu([{id: "a", name: "A"}], [{path: "/x/doc.txt"}], {applications: "Applications", documents: "Documents", clear: "Clear Menu"});
        const headers = rows.filter(r => r.id === "recentHeader");
        compare(headers.length, 2);
        for (const h of headers) {
            verify(h.header === true, "a section title");
            verify(h.enabled === undefined, "not a greyed row");
        }
        verify(source("shell/overlay/DockMenu.qml").indexOf('{id: "recentHeader", text: qsTr("Recent Documents"), header: true}') > 0,
               "the Dock menu's Recent Documents too");
    }

    function test_theDock() {
        const dock = source("shell/dock/Dock.qml");
        const shelf = dock.slice(dock.indexOf("id: shelf"), dock.indexOf("id: shelf") + 2000);
        verify(shelf.indexOf("borderColor") < 0 && shelf.indexOf("borderOpacity") < 0, "the shelf keeps Material's darker outer edge");
        verify(shelf.indexOf("opacity: Appearance.reduceMotion ? AutoHide.ease(win.hideMachine.visible) : 1") > 0, "Reduce Motion: the Dock fades");
        verify(/readonly property real hidden: Appearance\.reduceMotion \? \(win\.hideMachine\.visible > 0 \? 0 : 1\)/.test(shelf), "and stays in place while it shows");
        for (const id of ["collapseAnim", "gapAnim", "poofAnim", "fadeAnim"]) {
            const at = dock.indexOf("id: " + id);
            const block = dock.slice(at, dock.indexOf("}", at));
            verify(block.indexOf("Easing.BezierSpline") > 0 && block.indexOf("Easing.OutQuad") < 0, id + " on a role's curve");
        }
        compare(dock.split("Popups.withPointer(true, ").length - 1, 3, "a click, a hold and a secondary click open as the pointer's");
        verify(source("ui/tokens/tokens.json").indexOf('"rimOpacity": {"value": 0.34, "source": "Dock fidelity pass') < 0, "dock.rimOpacity goes");
    }

    function test_theBarButtonsOneRing() {
        const bar = source("shell/menubar/BarButton.qml");
        compare(bar.indexOf("border.width: root.activeFocus"), -1, "no ring inside the highlight");
        compare(bar.split("FocusRing {").length - 1, 1, "one ring");
        verify(bar.indexOf("visible: barFocus.active") > 0 && bar.indexOf("KeyFocus {") > 0, "for the keyboard only");
    }

    // The menu bar's band under Reduce Transparency and Increase Contrast (ADR-0039 step 25, after #83): shown under both, and
    // never made see-through under Reduce Transparency on a display that is not the active one.
    function test_theMenuBarBandUnderTheSettings() {
        const bar = source("shell/menubar/MenuBar.qml");
        verify(/readonly property bool showBackground: [^\n]*\n\s*\|\| Appearance\.reduceTransparency \|\| Appearance\.increaseContrast/.test(bar),
               "both settings show the band");
        verify(bar.indexOf("opacity: (Appearance.reduceTransparency ? 1 : win.dimOpacity) * win.entrance") > 0, "the opaque band stays opaque when dimmed, and comes in with the bar");
    }

    function test_widgetsDoNotGrowUnderReduceMotion() {
        verify(source("shell/desktop/DesktopWidgets.qml").indexOf("scale: win.dragging && !Appearance.reduceMotion ? Tokens.widgetLiftScale : 1") > 0);
    }
}
