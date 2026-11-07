import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/capture/CaptureModel.js" as Model
import "../../shell/store/CaptureLocation.js" as Location

// The capture toolbar's decisions (ADR-0045 OC-1, docs/specs/system-dialogs.md "Capture toolbar"): the modes in macOS 27's
// order, the mode the toolbar opens in, the arrows, the helper's argv for every mode and option, the Options menu's rows and
// checks, and a chosen row as the setting it changes. Save to (capture.location, owner 2026-11-07): the Screenshots folder in
// Pictures (a screenshot) or the Videos folder (a recording) by default, never the Desktop unless chosen.
TestCase {
    name: "CaptureModel"

    readonly property var labels: ({
            saveTo: "Save to", screenshots: "Screenshots", videos: "Videos", desktop: "Desktop", documents: "Documents",
            clipboard: "Clipboard", preview: "Preview", timer: "Timer", none: "None", five: "5 Seconds", ten: "10 Seconds",
            microphone: "Microphone", micNone: "None", micDefault: "Built-in Microphone", options: "Options",
            showPointer: "Show Mouse Pointer"
        })

    function test_modesInOrder() {
        compare(Model.MODES.map(m => m.id), ["screen", "window", "selection", "recordScreen", "recordSelection"]);
        compare(Model.MODES.map(m => m.glyph), ["capture-screen", "capture-window", "capture-selection", "record-screen", "record-selection"]);
        compare(Model.shown(true).length, 5);
        compare(Model.shown(false).map(m => m.id), ["screen", "window", "selection"], "without the recorder, no Record buttons");
        verify(Model.isRecord("recordScreen") && Model.isRecord("recordSelection"));
        verify(!Model.isRecord("selection") && !Model.isRecord(""));
    }

    function test_startMode() {
        compare(Model.startMode("window", true), "window", "the mode chosen last");
        compare(Model.startMode("recordScreen", true), "recordScreen");
        compare(Model.startMode("recordScreen", false), "selection", "a recording that cannot start gives way");
        compare(Model.startMode("video", true), "selection", "an unknown mode: Capture Selected Portion");
        compare(Model.startMode(undefined, true), "selection");
    }

    function test_arrows() {
        compare(Model.step("selection", 1, true), "recordScreen");
        compare(Model.step("selection", -1, true), "window");
        compare(Model.step("screen", -1, true), "screen", "stops at the left end");
        compare(Model.step("recordSelection", 1, true), "recordSelection", "stops at the right end");
        compare(Model.step("selection", 1, false), "selection", "no recording to step to");
        compare(Model.step("recordScreen", 1, false), "screen", "a mode no longer offered: the first one");
    }

    function test_locationPerMode() {
        compare(Model.location("selection", "clipboard"), "clipboard");
        compare(Model.location("recordScreen", "clipboard"), "screenshots", "a movie is not copied: the Videos folder");
        compare(Model.location("recordScreen", "preview"), "preview");
        compare(Model.location("screen", "desktop"), "desktop", "the Desktop when chosen");
        compare(Model.location("screen", "mail"), "screenshots", "an unknown place: the default folder");
        compare(Model.location("screen", undefined), "screenshots");
        compare(Model.timerSeconds("5"), 5);
        compare(Model.timerSeconds("10"), 10);
        compare(Model.timerSeconds("none"), 0);
        compare(Model.timerSeconds(5), 0, "only the stored strings");
    }

    // The Save to in effect (shell/store/CaptureLocation.js, read by SettingsStore): capture.location once it is in the file; without
    // it the older capture.saveTo, whose Documents, Clipboard and Preview were choices and stay, and whose Desktop (its default,
    // written into every file the shell created) cannot be told from a choice and moves to the new default.
    function test_storedLocation() {
        compare(Location.DEFAULT, "screenshots");
        compare(Location.effective(undefined, undefined), "screenshots", "a fresh account");
        compare(Location.effective("desktop", undefined), "desktop", "the Desktop chosen in the new menu stays");
        compare(Location.effective("clipboard", "documents"), "clipboard", "the new key wins");
        compare(Location.effective("mail", "documents"), "screenshots", "a bad new value is the default, not the old key");
        compare(Location.effective(undefined, "documents"), "documents");
        compare(Location.effective(undefined, "clipboard"), "clipboard");
        compare(Location.effective(undefined, "preview"), "preview");
        compare(Location.effective(undefined, "desktop"), "screenshots", "the old implicit default moves");
        compare(Location.effective(undefined, "mail"), "screenshots");
        compare(Location.effective(null, 7), "screenshots");
        compare(Location.effective(undefined, "documents", true), "screenshots", "an unsafe file reads the defaults");
    }

    function test_helperArgs() {
        const plain = {location: "screenshots", timer: "none", microphone: "none", showPointer: false};
        compare(Model.helperArgs("screen", plain, ""), ["screen", "--save", "screenshots"], "the Capture button: every display");
        compare(Model.helperArgs("screen", plain, "DP-1"), ["screen", "--save", "screenshots", "--output", "DP-1"], "a display clicked");
        compare(Model.helperArgs("window", plain, "DP-1"), ["window", "--save", "screenshots"], "no window: the helper's crosshair");
        compare(Model.helperArgs("window", plain, "", "100,50 800x600"), ["window", "--save", "screenshots", "--geometry", "100,50 800x600"]);
        compare(Model.helperArgs("selection", plain, "", "-10,20 300x200"), ["selection", "--save", "screenshots", "--geometry", "-10,20 300x200"]);
        compare(Model.helperArgs("recordSelection", plain, "DP-1", "10,20 300x200"),
            ["record", "selection", "--save", "screenshots", "--geometry", "10,20 300x200"]);
        compare(Model.helperArgs("screen", plain, "", "10,20 300x200"), ["screen", "--save", "screenshots"], "no geometry for a screen");
        compare(Model.helperArgs("selection", plain, "", "10,20 300x200 "), ["selection", "--save", "screenshots"], "a malformed one: none");
        compare(Model.helperArgs("selection", plain, "", "1.5,20 300x200"), ["selection", "--save", "screenshots"]);
        compare(Model.helperArgs("selection", {location: "desktop"}, ""), ["selection", "--save", "desktop"], "the Desktop when chosen");
        compare(Model.helperArgs("selection", {location: "clipboard", timer: "5", microphone: "default", showPointer: true}, "DP-1"),
            ["selection", "--save", "clipboard", "--timer", "5", "--pointer"], "no microphone for a screenshot");
        compare(Model.helperArgs("recordScreen", {location: "documents", timer: "10", microphone: "default", showPointer: true}, "DP-1"),
            ["record", "screen", "--save", "documents", "--timer", "10", "--pointer", "--mic", "--output", "DP-1"]);
        compare(Model.helperArgs("recordSelection", {location: "clipboard", timer: "none", microphone: "none", showPointer: false}, "DP-1"),
            ["record", "selection", "--save", "screenshots"], "the area's display is the crosshair's; a movie goes to the Videos folder");
        compare(Model.helperArgs("recordScreen", plain, "a b"), ["record", "screen", "--save", "screenshots"], "an odd display name is not passed");
        compare(Model.helperArgs("recordScreen", plain, ""), ["record", "screen", "--save", "screenshots"]);
        compare(Model.helperArgs("nope", null, ""), ["selection", "--save", "screenshots"]);
    }

    function ids(rows) {
        return rows.map(r => r.separator ? "-" : (r.header ? "#" + r.text : r.id + (r.checked ? "*" : "")));
    }

    function test_menuForAScreenshot() {
        const rows = Model.menuModel("selection", {location: "documents", timer: "5", microphone: "default", showPointer: false}, labels);
        compare(ids(rows), ["#Save to", "location:screenshots", "location:desktop", "location:documents*", "location:clipboard",
            "location:preview", "-", "#Timer", "timer:none", "timer:5*", "timer:10", "-", "#Options", "showPointer:toggle"]);
        compare(rows[1].text, "Screenshots", "a screenshot's default folder by its name");
        compare(rows[9].text, "5 Seconds");
        verify(rows.filter(r => !r.header && !r.separator).every(r => r.checked !== undefined), "every choice is checkable");
        compare(ids(Model.menuModel("screen", {}, labels)).slice(0, 3), ["#Save to", "location:screenshots*", "location:desktop"],
            "nothing chosen: the Screenshots folder");
    }

    function test_menuForARecording() {
        const rows = Model.menuModel("recordScreen", {location: "clipboard", timer: "nope", microphone: "default", showPointer: true}, labels);
        compare(ids(rows), ["#Save to", "location:screenshots*", "location:desktop", "location:documents", "location:preview", "-",
            "#Timer", "timer:none*", "timer:5", "timer:10", "-", "#Microphone", "microphone:none", "microphone:default*", "-",
            "#Options", "showPointer:toggle*"]);
        compare(rows[1].text, "Videos", "a recording's default folder by its name");
        compare(rows[13].text, "Built-in Microphone", "the default input by its name");
    }

    function test_choice() {
        const o = {location: "screenshots", timer: "none", microphone: "none", showPointer: false};
        compare(Model.choice("location:preview", o), {key: "location", value: "preview"});
        compare(Model.choice("location:desktop", o), {key: "location", value: "desktop"});
        compare(Model.choice("location:screenshots", o), {key: "location", value: "screenshots"});
        compare(Model.choice("timer:10", o), {key: "timer", value: "10"});
        compare(Model.choice("microphone:default", o), {key: "microphone", value: "default"});
        compare(Model.choice("showPointer:toggle", o), {key: "showPointer", value: true});
        compare(Model.choice("showPointer:toggle", {showPointer: true}), {key: "showPointer", value: false});
        compare(Model.choice("location:mail", o), null);
        compare(Model.choice("saveTo:desktop", o), null, "the older key is never written");
        compare(Model.choice("timer:3", o), null);
        compare(Model.choice("mode:screen", o), null, "the menu never changes the mode");
        compare(Model.choice("", o), null);
        compare(Model.choice("location:desktop:x", o), null);
    }

    // ---- the selection frame ----
    readonly property var screen: ({w: 1920, h: 1080})

    function test_defaultAndClamp() {
        compare(Model.defaultFrame(screen), {x: 480, y: 270, w: 960, h: 540}, "centred, half each way");
        compare(Model.clampFrame({x: 1800, y: -40, w: 400, h: 300}, screen, 8), {x: 1520, y: 0, w: 400, h: 300}, "moved back on");
        compare(Model.clampFrame({x: 0, y: 0, w: 5000, h: 2}, screen, 8), {x: 0, y: 0, w: 1920, h: 8}, "the display at most, 8 at least");
        compare(Model.clampFrame({x: 10.4, y: 20.6, w: 300.5, h: 200.2}, screen, 8), {x: 10, y: 21, w: 301, h: 200}, "whole numbers");
        compare(Model.clampFrame(null, screen, 8), Model.defaultFrame(screen));
        compare(Model.clampFrame({x: NaN, y: 0, w: 1, h: 1}, screen, 8), Model.defaultFrame(screen));
    }

    function test_handles() {
        const f = {x: 100, y: 100, w: 200, h: 100};
        compare(Model.handleCentres(f).map(h => h.id), Model.HANDLES);
        compare(Model.handleCentres(f)[4], {id: "bottomRight", x: 300, y: 200});
        compare(Model.hitTest(f, 100, 100, 22), "topLeft");
        compare(Model.hitTest(f, 110, 90, 22), "topLeft", "within half the hit area");
        compare(Model.hitTest(f, 200, 102, 22), "top");
        compare(Model.hitTest(f, 299, 150, 22), "right");
        compare(Model.hitTest(f, 205, 208, 22), "bottom");
        compare(Model.hitTest(f, 150, 200, 22), "outside", "on the bottom edge away from its handle: a new frame");
        compare(Model.hitTest(f, 99, 199, 22), "bottomLeft");
        compare(Model.hitTest(f, 150, 140, 22), "inside");
        compare(Model.hitTest(f, 50, 50, 22), "outside");
        compare(Model.hitTest(f, 400, 150, 22), "outside");
        // A tiny frame: the corners win over the edge middles.
        compare(Model.hitTest({x: 100, y: 100, w: 8, h: 8}, 104, 100, 22), "topLeft");
        compare(Model.cursorFor("topLeft"), "sizeFDiag");
        compare(Model.cursorFor("bottomLeft"), "sizeBDiag");
        compare(Model.cursorFor("left"), "sizeHor");
        compare(Model.cursorFor("bottom"), "sizeVer");
        compare(Model.cursorFor("inside"), "sizeAll");
        compare(Model.cursorFor("outside"), "cross");
    }

    function test_resize() {
        const f = {x: 100, y: 100, w: 200, h: 100};
        compare(Model.resize(f, "bottomRight", 50, 20, screen, 8), {x: 100, y: 100, w: 250, h: 120});
        compare(Model.resize(f, "topLeft", -30, -40, screen, 8), {x: 70, y: 60, w: 230, h: 140});
        compare(Model.resize(f, "right", 10, 999, screen, 8), {x: 100, y: 100, w: 210, h: 100}, "an edge handle moves one edge");
        compare(Model.resize(f, "top", 999, -10, screen, 8), {x: 100, y: 90, w: 200, h: 110});
        compare(Model.resize(f, "left", 300, 0, screen, 8), {x: 300, y: 100, w: 100, h: 100}, "past the opposite edge it turns over");
        compare(Model.resize(f, "bottomRight", -250, -150, screen, 8), {x: 50, y: 50, w: 50, h: 50}, "a corner past both edges");
        compare(Model.resize(f, "right", -197, 0, screen, 8), {x: 100, y: 100, w: 8, h: 100}, "never thinner than the minimum");
        compare(Model.resize(f, "bottomRight", 5000, 5000, screen, 8), {x: 100, y: 100, w: 1820, h: 980}, "kept on the display");
        compare(Model.resize(f, "topLeft", -500, -500, screen, 8), {x: 0, y: 0, w: 300, h: 200});
        compare(Model.resize({x: 1910, y: 0, w: 10, h: 10}, "left", 15, 0, screen, 8), {x: 1912, y: 0, w: 8, h: 10},
            "at the display's edge the minimum keeps inside it");
    }

    function test_moveAndDraw() {
        const f = {x: 100, y: 100, w: 200, h: 100};
        compare(Model.move(f, 30, -20, screen), {x: 130, y: 80, w: 200, h: 100});
        compare(Model.move(f, -500, 5000, screen), {x: 0, y: 980, w: 200, h: 100}, "the frame moves whole and stays on");
        compare(Model.drawn(500, 400, 200, 100, screen, 8), {x: 200, y: 100, w: 300, h: 300}, "any direction");
        compare(Model.drawn(10, 10, -50, 5000, screen, 8), {x: 0, y: 10, w: 10, h: 1070}, "clamped to the display");
        compare(Model.drawn(500, 400, 502, 401, screen, 8), {x: 500, y: 400, w: 8, h: 8}, "a tiny drag: the minimum");
    }

    function test_readoutAndGeometry() {
        compare(Model.readout({x: 0, y: 0, w: 300, h: 200}, 1), "300 × 200");
        compare(Model.readout({x: 0, y: 0, w: 300, h: 201}, 1.25), "375 × 251", "the picture's pixels at the display's scale");
        compare(Model.readout({x: 0, y: 0, w: 300, h: 200}, 0), "300 × 200");
        compare(Model.geometryText({x: 10, y: 20, w: 300, h: 200}, {x: 2560, y: 0}), "2570,20 300x200");
        compare(Model.geometryText({x: 10, y: 20, w: 300, h: 200}, {x: -1920, y: -1080}), "-1910,-1060 300x200");
        verify(Model.GEOMETRY.test(Model.geometryText({x: 10, y: 20, w: 300, h: 200}, {x: -1920, y: 0})));
    }

    // B1: the toolbar's window is 0x0 when the frame is first made; the frame comes from the screen's own size.
    function test_frameFromAWindowStillZero() {
        const b = Model.displayBounds(0, 0, 2304, 1440);
        compare(b, {w: 2304, h: 1440}, "the screen's size while the window has none");
        compare(Model.displayBounds(52, 30, 2304, 1440), {w: 2304, h: 1440}, "never the size the window passes through while it maps");
        compare(Model.displayBounds(1920, 1080, 0, 0), {w: 1920, h: 1080}, "the window's when the screen has none");
        compare(Model.displayBounds(0, 0, 0, 0), {w: 0, h: 0});
        const first = Model.selectionFor("", "DP-1", b, 8);
        compare(first, {x: 576, y: 360, w: 1152, h: 720}, "the first time: centred, not 8x8 at 0,0");
        const last = Model.selectionFor("DP-1=100,50,916,504", "DP-1", b, 8);
        compare(last, {x: 100, y: 50, w: 916, h: 504}, "the last selection comes back");
        // The old order of events: a frame kept while the window is 0x0 must not shrink.
        compare(Model.clampFrame(first, {w: 0, h: 0}, 8), first, "a display of no size leaves the frame as it is");
        compare(Model.clampFrame(last, Model.displayBounds(0, 0, 2304, 1440), 8), last);
    }

    // M1: the readout is the output's real pixels (logical x Hyprland's scale 1.25), never the layer surface's ratio of 2.
    function test_readoutAtScale125() {
        compare(Model.readout({x: 0, y: 0, w: 916, h: 504}, 1.25), "1145 × 630");
        verify(Model.readout({x: 0, y: 0, w: 916, h: 504}, 2) !== "1145 × 630");
    }

    // The highlight follows the window's own superellipse corner (17 at power 2.6: 22.1 along each edge), clockwise.
    function test_windowOutline() {
        const pts = Model.windowOutline(400, 300, 17, 2.6, 12);
        compare(pts.length, 4 * 13);
        fuzzyCompare(pts[0].x, 0, 0.001);
        fuzzyCompare(pts[0].y, 22.1, 0.001);
        fuzzyCompare(pts[12].x, 22.1, 0.001);
        fuzzyCompare(pts[12].y, 0, 0.001);
        fuzzyCompare(pts[13].x, 400 - 22.1, 0.001);
        fuzzyCompare(pts[13].y, 0, 0.001);
        fuzzyCompare(pts[26].x, 400, 0.001);
        fuzzyCompare(pts[39].x, 22.1, 0.001);
        fuzzyCompare(pts[39].y, 300, 0.001);
        const mid = pts[6];
        verify(mid.x > 0 && mid.x < 22.1);
        verify(Math.abs(mid.x - mid.y) < 0.001);
        for (const q of pts)
            verify(q.x >= -0.001 && q.x <= 400.001 && q.y >= -0.001 && q.y <= 300.001);
        compare(Model.windowOutline(10, 10, 17, 2.6, 4).length, 20, "a small window keeps its corners inside");
    }

    function test_lastSelection() {
        const text = Model.withSelection("", "DP-1", {x: 10, y: 20, w: 300, h: 200});
        compare(text, "DP-1=10,20,300,200");
        const two = Model.withSelection(text, "HDMI-A-1", {x: -5, y: 0, w: 64, h: 48});
        compare(two, "DP-1=10,20,300,200;HDMI-A-1=-5,0,64,48");
        compare(Model.withSelection(two, "DP-1", {x: 1, y: 2, w: 3, h: 4}), "HDMI-A-1=-5,0,64,48;DP-1=1,2,3,4", "replaced, moved last");
        compare(Model.selectionFor(two, "DP-1", screen, 8), {x: 10, y: 20, w: 300, h: 200});
        compare(Model.selectionFor(two, "HDMI-A-1", screen, 8), {x: 0, y: 0, w: 64, h: 48}, "brought back on its display");
        compare(Model.selectionFor(two, "eDP-1", screen, 8), Model.defaultFrame(screen), "no frame yet: centred");
        compare(Model.selectionFor("garbage;DP-1=1,2,0,4", "DP-1", screen, 8), Model.defaultFrame(screen), "an empty frame is no frame");
        compare(Model.withSelection(two, "a b", {x: 1, y: 2, w: 3, h: 4}), two, "an odd display name changes nothing");
        compare(Model.withSelection(two, "DP-1", {x: 1, y: 2, w: 0, h: 4}), two, "an empty frame changes nothing");
        let many = "";
        for (let i = 0; i < 20; i++)
            many = Model.withSelection(many, "D-" + i, {x: i, y: 0, w: 10, h: 10});
        const kept = Model.parseSelections(many);
        compare(kept.length, Model.SELECTIONS_MAX, "at most 16 displays, the oldest go");
        compare(kept[0][0], "D-4");
        // What the toolbar writes is what the settings contract accepts (capture.lastSelection's schema pattern).
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/schema/grassfield.schema.json"), false);
        xhr.send();
        const pattern = new RegExp(JSON.parse(xhr.responseText).properties.capture.properties.lastSelection.pattern);
        verify(pattern.test(many) && pattern.test(two) && pattern.test(""), "within the contract");
        verify(!pattern.test("DP-1=1,2,3"), "and the contract refuses what the toolbar would not write");
    }

    // ---- Capture Selected Window ----
    function test_windowAt() {
        const back = {x: 0, y: 0, w: 1000, h: 800, stamp: 10};
        const front = {x: 100, y: 100, w: 200, h: 200, stamp: 50};
        const later = {x: 150, y: 150, w: 200, h: 200, stamp: 0};
        compare(Model.windowAt([back, front], 150, 150), front, "the most recently activated window there");
        compare(Model.windowAt([back, front], 500, 500), back);
        compare(Model.windowAt([back, front], 1500, 500), null, "no window: nothing");
        compare(Model.windowAt([later, {x: 100, y: 100, w: 200, h: 200, stamp: 0}], 160, 160).x, 100, "equal stamps: the later one");
        const full = {x: 0, y: 0, w: 1920, h: 1080, stamp: 30, fullscreen: true};
        compare(Model.windowAt([back, full], 500, 500), full, "a full-screen window hides the windows activated before it");
        compare(Model.windowAt([back, full, front], 150, 150), front, "a window activated after it is over it");
        compare(Model.windowAt([{x: 0, y: 0, w: 0, h: 10, stamp: 99}], 0, 5), null, "an empty window is not there");
        compare(Model.windowAt(null, 0, 0), null);
    }

    function test_clip() {
        compare(Model.clip({x: -50, y: 900, w: 300, h: 400}, screen), {x: 0, y: 900, w: 250, h: 180}, "the part on the display");
        compare(Model.clip({x: 2000, y: 0, w: 100, h: 100}, screen), null);
        compare(Model.clip({x: 10.6, y: 0, w: 100, h: 100}, screen), {x: 11, y: 0, w: 100, h: 100});
    }

    // The capture.* colours are slurp's #rrggbbaa; the frame and the veil draw them in QML, which reads #aarrggbb.
    function test_qtColor() {
        compare(Model.qtColor("#0000002E"), "#2E000000");
        compare(Model.qtColor("#FFFFFFE6"), "#E6FFFFFF");
        compare(Model.qtColor("#123456"), "#123456", "a colour without alpha is left as it is");
        const veil = Qt.color(Model.qtColor(Tokens.captureVeil));
        verify(Math.abs(veil.a - 0x2E / 255) < 0.01 && veil.r === 0, "the veil is a light black, not transparent");
        const border = Qt.color(Model.qtColor(Tokens.captureBorder));
        verify(border.r === 1 && border.g === 1 && border.b === 1 && border.a > 0.85, "the border is near-white, not yellow");
    }
}
