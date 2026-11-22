pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui

// ADR-0015 L0: the window lights (WindowControls) and the unified toolbar (UnifiedToolbar) of grassfield-ui.
// Geometry per style from the window.* tokens, every state (active, inactive, hover, pressed, disabled, full screen),
// the xdg-toplevel requests each light makes (a stand-in window records them), Option/Alt = true full screen, the
// double-click setting and the accessibility surface (names, roles, press actions that respect disabled lights).
TestCase {
    id: tc
    name: "WindowControls"
    width: 600
    height: 200
    visible: true
    when: windowShown

    // Stand-in for a QtQuick Window: the same methods and properties WindowActions.js uses, recording each call.
    QtObject {
        id: win
        property int visibility: 2
        property bool active: true
        property var calls: []
        function close() {
            calls.push("close");
        }
        function showMinimized() {
            calls.push("minimize");
        }
        function showMaximized() {
            calls.push("maximize");
        }
        function showNormal() {
            calls.push("normal");
        }
        function showFullScreen() {
            calls.push("fullscreen");
        }
        function startSystemMove() {
            calls.push("move");
        }
    }

    Item {
        id: stage
        anchors.fill: parent
    }

    Component {
        id: controlsComponent
        WindowControls {
            window: win
        }
    }

    Component {
        id: toolbarComponent
        UnifiedToolbar {
            width: 600
            window: win
            title: "A title"
        }
    }

    function init() {
        win.visibility = 2;
        win.active = true;
        win.calls = [];
    }

    function make(component: var, props: var): var {
        const o = component.createObject(stage, props);
        verify(o !== null, component.errorString());
        return o;
    }

    function centre(item: var): var {
        const p = item.mapToItem(null, item.width / 2, item.height / 2);
        return {x: p.x, y: p.y};
    }

    // Tokens: the reference metrics of F1 (52 row, 14 lights, 9 gap, centre 25.75) ----------------------------------

    function test_referenceMetrics() {
        compare(Tokens.windowUnifiedHeight, 52);
        compare(Tokens.windowLightDiameter, 14);
        compare(Tokens.windowLightGap, 9);
        // macOS 27 measures (26.0, 25.5-25.75); 26 keeps the discs on whole pixels (ADR-0024).
        fuzzyCompare(Tokens.windowUnifiedLightCentre, 26, 0.01);
        compare(Tokens.windowTitlebarHeight, Tokens.overviewWindowTitlebarHeight);
        fuzzyCompare(Tokens.windowLightHitSlop, Tokens.windowLightDiameter / 6, 0.01);
    }

    // Geometry per style --------------------------------------------------------------------------------------------

    function test_unifiedGeometry() {
        const c = make(controlsComponent, {style: "unified"});
        compare(c.height, Tokens.windowUnifiedHeight);
        const close = c.closeLight, minimize = c.minimizeLight, zoom = c.zoomLight;
        fuzzyCompare(close.x + close.width / 2, 26, 0.01);
        fuzzyCompare(close.y + close.height / 2, 26, 0.01);
        fuzzyCompare(minimize.x - close.x, 23, 0.01);
        fuzzyCompare(zoom.x - minimize.x, 23, 0.01);
        compare(close.width, 14);
        compare(zoom.y, close.y);
        // The toolbar's content starts after the last light and the least gap.
        fuzzyCompare(c.contentStart, zoom.x + zoom.width + Tokens.windowTitleGap, 0.01);
        c.destroy();
    }

    function test_titlebarGeometry() {
        const c = make(controlsComponent, {style: "titlebar"});
        compare(c.height, Tokens.windowTitlebarHeight);
        fuzzyCompare(c.closeLight.x, 9, 0.01);
        // Centre (16, 16): the plugin's titlebar draws the first light there.
        fuzzyCompare(c.closeLight.x + 7, 16, 0.01);
        fuzzyCompare(c.closeLight.y + 7, 16, 0.01);
        fuzzyCompare(c.minimizeLight.x - c.closeLight.x, 23, 0.01);
        c.destroy();
    }

    function test_lightGeometryFollowsTokens() {
        const c = make(controlsComponent, {style: "unified"});
        const g = c.geometry;
        fuzzyCompare(g.x0 + Tokens.windowLightDiameter / 2, Tokens.windowUnifiedLightCentre, 1e-9);
        fuzzyCompare(g.pitch, Tokens.windowLightDiameter + Tokens.windowLightGap, 1e-9);
        c.destroy();
    }

    // The hit area is larger than the disc by the slop; the gaps between lights are not hit ---------------------------

    function test_hitRadius() {
        const c = make(controlsComponent, {});
        const slop = Tokens.windowLightHitSlop;
        const cp = centre(c.closeLight);
        const mp = centre(c.minimizeLight);
        // Just inside the slop of the close light: acts. In the gap, equidistant: nothing.
        mouseClick(stage, cp.x + 7 + slop - 0.5, cp.y);
        compare(win.calls.length, 1);
        compare(win.calls[0], "close");
        win.calls = [];
        mouseClick(stage, (cp.x + mp.x) / 2, cp.y);
        compare(win.calls.length, 0, "the gap between two lights is drag area, not a light");
        c.destroy();
    }

    // Actions: plain xdg-toplevel requests -----------------------------------------------------------------------------

    function test_closeAndMinimize() {
        const c = make(controlsComponent, {});
        mouseClick(stage, centre(c.closeLight).x, centre(c.closeLight).y);
        mouseClick(stage, centre(c.minimizeLight).x, centre(c.minimizeLight).y);
        compare(win.calls.join(","), "close,minimize");
        c.destroy();
    }

    function test_zoomTogglesMaximized() {
        const c = make(controlsComponent, {});
        // A normal window asks for maximized; a maximized (or, in the Grassfield session, a floating window Qt believes
        // maximized) goes through showNormal(): the compositor toggles on any request.
        c.zoomWindow(false);
        win.visibility = 4;
        c.zoomWindow(false);
        compare(win.calls.join(","), "maximize,normal");
        c.destroy();
    }

    function test_optionClickIsTrueFullScreen() {
        const c = make(controlsComponent, {});
        const p = centre(c.zoomLight);
        mouseClick(stage, p.x, p.y, Qt.LeftButton, Qt.AltModifier);
        compare(win.calls.join(","), "fullscreen");
        win.visibility = 5;
        c.zoomWindow(true);
        compare(win.calls.join(","), "fullscreen,normal", "a second Option-zoom leaves full screen");
        c.destroy();
    }

    function test_handledKeepsTheDefault() {
        const c = make(controlsComponent, {});
        c.closeRequested.connect(() => {
            c.handled = true;
        });
        c.closeWindow();
        compare(win.calls.length, 0);
        c.destroy();
    }

    // States ------------------------------------------------------------------------------------------------------------

    function test_activeInactiveAndHover() {
        const c = make(controlsComponent, {});
        verify(!c.closeLight.grey, "active window: coloured");
        win.active = false;
        verify(c.closeLight.grey, "inactive window: grey");
        verify(c.zoomLight.grey);
        c.hovered = true;
        verify(!c.closeLight.grey, "coloured again while the pointer is over the group");
        c.hovered = false;
        win.active = true;
        c.destroy();
    }

    function test_glyphsShowOnGroupHover() {
        const c = make(controlsComponent, {});
        const glyph = item => item.children.filter(o => o.kind !== undefined)[0];
        verify(!glyph(c.closeLight).visible);
        c.hovered = true;
        verify(glyph(c.closeLight).visible && glyph(c.minimizeLight).visible && glyph(c.zoomLight).visible);
        compare(glyph(c.zoomLight).kind, "plus");
        c.altHeld = true;
        compare(glyph(c.zoomLight).kind, "arrows", "Option held: the zoom light shows the full-screen arrows");
        c.destroy();
    }

    // chrome.sh 4 (nested, 2026-10-23): the app's lights measured 11.7 px across instead of 14. The hairline was the disc's
    // own border: on the GPU a translucent border is drawn instead of the fill there, so the outer pixel showed what is
    // behind the light (the software renderer of this test draws it differently, so the structure is checked: the disc
    // has no border of its own, a transparent ring over it darkens its edge).
    function test_theHairlineDarkensTheEdgeInsteadOfCuttingIt() {
        const c = make(controlsComponent, {});
        const disc = c.closeLight.children.filter(o => o.radius !== undefined && o.border !== undefined)[0];
        verify(disc !== undefined, "the disc");
        compare(disc.width, Tokens.windowLightDiameter, "the disc is the whole light");
        compare(disc.border.width, 0, "the disc draws no border of its own");
        const ring = disc.children.filter(o => o.border !== undefined && o.border.width === 1 && o.color.a === 0)[0];
        verify(ring !== undefined, "a transparent ring over the disc");
        compare(ring.width, disc.width);
        c.destroy();
    }

    function test_disabledLightIsGreyAndInert() {
        const c = make(controlsComponent, {canMinimize: false});
        verify(c.minimizeLight.grey);
        verify(!c.closeLight.grey);
        const p = centre(c.minimizeLight);
        mouseClick(stage, p.x, p.y);
        c.minimizeLight.Accessible.pressAction();
        compare(win.calls.length, 0, "a disabled light never acts, by pointer or by accessibility press");
        c.destroy();
    }

    function test_pressedDarkens() {
        const c = make(controlsComponent, {});
        const p = centre(c.closeLight);
        mousePress(stage, p.x, p.y);
        verify(c.closeLight.pressed);
        mouseRelease(stage, p.x, p.y);
        verify(!c.closeLight.pressed);
        win.calls = [];
        c.destroy();
    }

    function test_fullScreenHidesTheLights() {
        const c = make(controlsComponent, {});
        verify(c.visible);
        compare(c.contentStart > 0, true);
        win.visibility = 5;
        verify(!c.visible);
        compare(c.contentStart, 0);
        compare(c.implicitWidth, 0);
        c.destroy();
    }

    // Accessibility -----------------------------------------------------------------------------------------------------

    function test_accessibleSurface() {
        const c = make(controlsComponent, {});
        compare(c.closeLight.Accessible.role, Accessible.Button);
        compare(c.minimizeLight.Accessible.role, Accessible.Button);
        compare(c.zoomLight.Accessible.role, Accessible.Button);
        compare(c.closeLight.Accessible.name, "Close");
        compare(c.minimizeLight.Accessible.name, "Minimize");
        compare(c.zoomLight.Accessible.name, "Zoom");
        verify(c.closeLight.Accessible.description !== "");
        verify(c.closeLight.Accessible.focusable);
        verify(!c.closeLight.activeFocusOnTab, "not in the Tab chain (macOS); the Window menu is the keyboard route");
        compare(c.Accessible.role, Accessible.Grouping);
        c.closeLight.Accessible.pressAction();
        c.minimizeLight.Accessible.pressAction();
        c.zoomLight.Accessible.pressAction();
        compare(win.calls.join(","), "close,minimize,maximize", "the screen reader's press does what the pointer does");
        c.destroy();
    }

    // The toolbar ---------------------------------------------------------------------------------------------------------

    function test_toolbarHeightsAndRoles() {
        const u = make(toolbarComponent, {});
        compare(u.height, 52);
        compare(u.Accessible.role, Accessible.ToolBar);
        const t = make(toolbarComponent, {style: "titlebar"});
        compare(t.height, Tokens.windowTitlebarHeight);
        u.destroy();
        t.destroy();
    }

    function test_toolbarItemsStartAfterTheLights() {
        const v = make(toolbarComponent, {showControls: false});
        compare(v.contentStart, Tokens.windowItemsInset, "no lights here: the items start at the inset");
        verify(!v.controls.visible);
        v.destroy();
        const w = make(toolbarComponent, {});
        verify(w.contentStart >= w.controls.contentStart);
        verify(w.controls.visible);
        w.destroy();
    }

    function test_doubleClickSetting() {
        const u = make(toolbarComponent, {doubleClickAction: "zoom"});
        u.doubleClicked();
        compare(u.lastDoubleClick, "zoom");
        compare(win.calls.join(","), "maximize");
        win.calls = [];
        u.doubleClickAction = "minimize";
        u.doubleClicked();
        compare(win.calls.join(","), "minimize");
        win.calls = [];
        u.doubleClickAction = "none";
        u.doubleClicked();
        compare(u.lastDoubleClick, "none");
        compare(win.calls.length, 0);
        u.doubleClickAction = "bogus";
        u.doubleClicked();
        compare(u.lastDoubleClick, "zoom", "an unknown value counts as the default, like the plugin");
        win.calls = [];
        u.doubleClickAction = "minimize";
        u.canMinimize = false;
        u.doubleClicked();
        compare(win.calls.length, 0, "minimize that the window cannot honour does nothing");
        u.destroy();
    }

    // Qt's synthetic test events carry no real timestamps, so TapHandler never counts two taps here: the double-tap
    // itself is checked in the nested session (tests/compositor/client_chrome.sh). A single click must do nothing.
    function test_singleClickOnEmptySpaceDoesNothing() {
        const u = make(toolbarComponent, {doubleClickAction: "zoom"});
        mouseClick(u, 400, 26);
        compare(win.calls.length, 0);
        u.destroy();
    }

    // client_chrome.sh 7 (nested, 2026-10-23): a drag that starts on a light moved the window. The press belongs to the
    // lights (macOS): only a drag from empty space starts the compositor's move.
    function test_dragFromEmptySpaceMovesTheWindow() {
        const u = make(toolbarComponent, {});
        mouseDrag(u, 400, 26, 200, 100);
        verify(win.calls.indexOf("move") >= 0, "empty space drags the window: " + win.calls.join(","));
        u.destroy();
    }

    function test_dragFromALightNeverMovesTheWindow() {
        const u = make(toolbarComponent, {});
        for (const light of [u.controls.closeLight, u.controls.minimizeLight, u.controls.zoomLight]) {
            win.calls = [];
            const p = u.mapFromItem(light, light.width / 2, light.height / 2);
            mouseDrag(u, p.x, p.y, 200, 100);
            compare(win.calls.indexOf("move"), -1, "a drag from a light: " + win.calls.join(","));
        }
        u.destroy();
    }

    // A drag that starts on a toolbar control is the control's (macOS: the button tracks the pointer), never a window move
    // that would also cancel its click (Preview's Glance header test, 2026-11-22: Qt's default let the drag area take over).
    Component {
        id: toolbarWithButton
        UnifiedToolbar {
            width: 600
            window: win
            title: "A title"
            trailing: [
                ToolButton {
                    objectName: "trailingButton"
                    capsule: true
                    accessibleName: "Info"
                }
            ]
        }
    }

    function test_dragFromAToolbarButtonNeverMovesTheWindow() {
        const u = make(toolbarWithButton, {});
        const b = findChild(u, "trailingButton");
        verify(b !== null);
        const p = u.mapFromItem(b, b.width / 2, b.height / 2);
        mouseDrag(u, p.x, p.y, -200, 100);
        compare(win.calls.indexOf("move"), -1, "a drag from a button: " + win.calls.join(","));
        win.calls = [];
        mouseDrag(u, 300, 26, 200, 100);
        verify(win.calls.indexOf("move") >= 0, "empty space still moves it: " + win.calls.join(","));
        u.destroy();
    }

    function test_theLightsGroupCoversTheLightsAndTheirSlop() {
        const c = make(controlsComponent, {style: "unified"});
        const g = c.geometry;
        verify(c.overLights(g.x0 + 7, g.y0 + 7), "the close light's centre");
        verify(c.overLights(g.x0 + g.width - 1, g.y0 + 7), "the zoom light's right edge");
        verify(c.overLights(g.x0 + 18, g.y0 + 7), "the gap between two lights");
        verify(!c.overLights(g.x0 + g.width + Tokens.windowLightHitSlop + 1, g.y0 + 7), "right of the group");
        verify(!c.overLights(g.x0 + 7, g.y0 + Tokens.windowLightDiameter + Tokens.windowLightHitSlop + 1), "below the group");
        c.destroy();
    }

    function test_pressOnALightDoesNotReachTheDragArea() {
        const u = make(toolbarComponent, {});
        const p = centre(u.controls.closeLight);
        mouseDoubleClickSequence(stage, p.x, p.y);
        compare(win.calls.indexOf("maximize"), -1, "the lights sit above the drag area");
        u.destroy();
    }

    // ADR-0015 Q4(b): the shell's capabilities file greys the minimize light without the plugin ---------------------

    function test_minimizeAvailableFollowsTheShellsCapabilitiesFile() {
        verify(WindowActions.minimizeAvailable('{"v":1,"pluginPresent":true,"features":["decorations","minimize"]}'));
        verify(!WindowActions.minimizeAvailable('{"v":1,"pluginPresent":false,"features":[]}'), "no plugin: greyed");
        verify(!WindowActions.minimizeAvailable('{"v":1,"pluginPresent":true,"features":["decorations"]}'), "plugin without minimize: greyed");
        // Unknown state (no file, unreadable, another version, wrong types) leaves the light enabled.
        for (const text of ["", "not json", "[]", "null", '{"v":2,"pluginPresent":false}', '{"v":1,"pluginPresent":"no"}', '{"v":1,"pluginPresent":true}'])
            verify(WindowActions.minimizeAvailable(text), "unknown state keeps it enabled: " + text);
    }

    function test_toolbarGreysAndDisablesMinimizeWhenUnavailable() {
        const u = make(toolbarComponent, {canMinimize: false});
        verify(u.controls.minimizeLight.grey);
        verify(!u.controls.minimizeLight.lightEnabled);
        verify(!u.controls.closeLight.grey);
        u.controls.minimizeLight.Accessible.pressAction();
        compare(win.calls.length, 0);
        u.destroy();
    }
}
