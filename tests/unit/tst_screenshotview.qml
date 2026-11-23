import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/screenshot/qml"

// The Screenshot editor window with a mock backend (slices B1 to B4): the picture's zoom and fit, the zoom clamps, the title
// block, Done and Revert, the failure banner, and the editing: the tool group and its keys, Esc's order, the question when the
// window closes with changes, undo and redo, the pointer's conversion to picture pixels at a 1.25 zoom and the overlay's size.
// The picture itself is not loaded (no image provider here).
TestCase {
    id: testCase
    name: "ScreenshotView"
    when: editor.visible

    QtObject {
        id: backendItem
        property string fileName: "Screenshot 2026-11-22 at 09.12.44.png"
        property int imageWidth: 2000
        property int imageHeight: 1000
        property string imageSource: ""
        property bool dirty: false
        property bool canRevert: false
        property string lastError: ""
        property bool dark: true
        property bool reduceMotion: true
        property bool increaseContrast: false
        property real textScale: 1
        property string accentColor: "multicolor"
        property string accentHighlight: "automatic"
        property string shortcutStyle: "pc"
        property string titlebarDoubleClick: "zoom"
        property bool canMinimize: true
        property int doneCalls: 0
        property int revertCalls: 0
        property bool doneResult: false
        // Editing (slices B3 and B4).
        property string tool: "select"
        property string arrowStyle: "straight"
        property bool toolFill: false
        property real toolWidth: 0
        property string toolColor: ""
        property real captureScale: 0
        property bool canUndo: false
        property bool canRedo: false
        property int selectedId: 0
        property var handles: []
        property string overlaySource: ""
        property var pressArgs: []
        property int undoCalls: 0
        property int redoCalls: 0
        property int deleteCalls: 0
        property int selectNoneCalls: 0
        property var nudges: []
        function done() {
            doneCalls++;
            return doneResult;
        }
        function revert() {
            revertCalls++;
            return true;
        }
        function toolPress(x, y, tolerance) {
            pressArgs = [x, y, tolerance];
            return true;
        }
        function toolMove(x, y, constrain) {
        }
        function toolRelease(x, y, constrain) {
        }
        function toolCancel() {
        }
        function undo() {
            undoCalls++;
        }
        function redo() {
            redoCalls++;
        }
        function deleteSelected() {
            deleteCalls++;
        }
        function selectNone() {
            selectNoneCalls++;
            selectedId = 0;
        }
        function nudgeSelected(dx, dy) {
            nudges = nudges.concat([[dx, dy]]);
        }
    }

    Editor {
        id: editor
        backend: backendItem
        globalMenu: false
    }

    function init() {
        editor.zoomView.fit();
        backendItem.canRevert = false;
        backendItem.lastError = "";
        backendItem.doneCalls = 0;
        backendItem.revertCalls = 0;
        backendItem.dirty = false;
        backendItem.tool = "select";
        backendItem.canUndo = false;
        backendItem.canRedo = false;
        backendItem.selectedId = 0;
        backendItem.captureScale = 0;
        backendItem.overlaySource = "";
        backendItem.undoCalls = 0;
        backendItem.redoCalls = 0;
        backendItem.deleteCalls = 0;
        backendItem.selectNoneCalls = 0;
        backendItem.nudges = [];
        backendItem.pressArgs = [];
        keepSheet().close();
    }

    function keepSheet() {
        return findChild(editor.contentItem, "keepSheet");
    }

    function test_windowFollowsTheTokens() {
        compare(editor.width, Tokens.screenshotWindowWidth);
        compare(editor.height, Tokens.screenshotWindowHeight);
        verify(editor.minimumWidth >= Tokens.screenshotWindowMinWidth);
        compare(editor.minimumHeight, Tokens.screenshotWindowMinHeight);
        compare(editor.gfChromeRole, "editor", "the compositor plugin draws no title bar on it");
    }

    function test_titleIsTheFileName() {
        compare(editor.title, DisplayName.text(backendItem.fileName));
    }

    function test_fitShowsTheWholePictureAndNeverEnlarges() {
        const view = editor.zoomView;
        verify(view.fitMode);
        const expect = Math.min(1, view.width / 2000, view.height / 1000);
        compare(view.fitScale, expect);
        compare(view.viewScale, expect);
        verify(view.fitScale < 1, "a 2000 x 1000 picture is larger than the window");
        compare(view.holder.width, 2000 * expect);
        backendItem.imageWidth = 100;
        backendItem.imageHeight = 80;
        compare(view.fitScale, 1, "a small picture is not enlarged to fit");
        backendItem.imageWidth = 2000;
        backendItem.imageHeight = 1000;
    }

    function test_zoomStepsAndClamps() {
        const view = editor.zoomView;
        view.actualSize();
        compare(view.viewScale, 1);
        compare(view.fitMode, false);
        view.zoomIn();
        fuzzyCompare(view.viewScale, Tokens.screenshotZoomStep, 1e-9);
        view.zoomOut();
        view.zoomOut();
        fuzzyCompare(view.viewScale, 1 / Tokens.screenshotZoomStep, 1e-9);
        for (let i = 0; i < 60; i++)
            view.zoomIn();
        compare(view.viewScale, Tokens.screenshotZoomMax, "the largest zoom");
        for (let i = 0; i < 120; i++)
            view.zoomOut();
        compare(view.viewScale, Tokens.screenshotZoomMin, "the smallest zoom");
        view.fit();
        verify(view.fitMode);
    }

    function test_doubleClickToggle() {
        const view = editor.zoomView;
        view.toggleActualSize();
        compare(view.viewScale, 1, "from fit (smaller than the picture) to actual size");
        view.toggleActualSize();
        verify(view.fitMode, "and back to fit");
    }

    function test_zoomLabelAndSubtitle() {
        const view = editor.zoomView;
        view.actualSize();
        compare(view.zoomLabel, "100%");
        compare(view.Accessible.name, "Picture " + backendItem.fileName + ", 100%");
    }

    function test_revertShowsOnlyWithAnOriginal() {
        const group = findChild(editor.contentItem, "actionsRow");
        verify(group);
        const button = findChild(editor.contentItem, "revertButton");
        verify(button);
        compare(button.parent.parent.visible, false, "nothing to revert on an untouched picture");
        backendItem.canRevert = true;
        compare(button.parent.parent.visible, true);
        button.clicked();
        compare(backendItem.revertCalls, 1);
    }

    function test_doneSavesAndAFailureKeepsTheWindow() {
        const done = findChild(editor.contentItem, "doneButton");
        verify(done);
        compare(done.text, "Done");
        verify(done.primary, "the default action");
        backendItem.doneResult = false;
        done.clicked();
        compare(backendItem.doneCalls, 1);
        verify(editor.visible, "a failed save keeps the window and the edits");
        backendItem.lastError = "the picture file changed since it was opened";
        const failure = findChild(editor.contentItem, "failure");
        verify(failure);
        compare(failure.visible, true);
        verify(failure.Accessible.name.indexOf("changed since it was opened") >= 0);
        backendItem.lastError = "";
        compare(failure.visible, false);
    }

    // ---- editing (slices B3 and B4) ------------------------------------------------------------------------------------------

    function test_theToolGroupHasTheFiveToolsAndOneIsOn() {
        const names = ["select", "arrow", "line", "rectangle", "ellipse"];
        for (const name of names) {
            const button = findChild(editor.contentItem, "tool_" + name);
            verify(button, name);
            compare(button.checked, name === "select", name + " at start");
            verify(button.accessibleName !== "", "a name for assistive technology: " + name);
        }
        const rect = findChild(editor.contentItem, "tool_rectangle");
        rect.clicked();
        compare(backendItem.tool, "rectangle");
        compare(rect.checked, true);
        compare(findChild(editor.contentItem, "tool_select").checked, false, "one at a time");
    }

    function test_theOptionsFollowTheTool() {
        const arrowStyle = findChild(editor.contentItem, "arrowStyleGroup");
        const fill = findChild(editor.contentItem, "fillGroup");
        compare(arrowStyle.visible, false);
        compare(fill.visible, false);
        backendItem.tool = "arrow";
        compare(arrowStyle.visible, true);
        compare(fill.visible, false);
        findChild(editor.contentItem, "arrow_curved").clicked();
        compare(backendItem.arrowStyle, "curved");
        backendItem.tool = "ellipse";
        compare(arrowStyle.visible, false);
        compare(fill.visible, true);
        findChild(editor.contentItem, "fillButton").clicked();
        compare(backendItem.toolFill, true);
        backendItem.toolFill = false;
    }

    function test_toolLettersSwitchTools() {
        editor.requestActivate();
        keyClick(Qt.Key_A);
        compare(backendItem.tool, "arrow");
        keyClick(Qt.Key_R);
        compare(backendItem.tool, "rectangle");
        keyClick(Qt.Key_O);
        compare(backendItem.tool, "ellipse");
        keyClick(Qt.Key_L);
        compare(backendItem.tool, "line");
        keyClick(Qt.Key_V);
        compare(backendItem.tool, "select");
    }

    function test_keysEditTheSelection() {
        editor.requestActivate();
        backendItem.selectedId = 4;
        keyClick(Qt.Key_Left);
        keyClick(Qt.Key_Down, Qt.ShiftModifier);
        compare(JSON.stringify(backendItem.nudges), JSON.stringify([[-1, 0], [0, 10]]), "1 px, and 10 with Shift");
        keyClick(Qt.Key_Delete);
        compare(backendItem.deleteCalls, 1);
        backendItem.selectedId = 0;
        keyClick(Qt.Key_Left);
        compare(backendItem.nudges.length, 2, "nothing selected: the arrow keys do nothing");
    }

    function test_undoAndRedoButtonsFollowTheirState() {
        const undo = findChild(editor.contentItem, "undoButton");
        const redo = findChild(editor.contentItem, "redoButton");
        compare(undo.enabled, false);
        compare(redo.enabled, false);
        backendItem.canUndo = true;
        compare(undo.enabled, true);
        compare(redo.enabled, false);
        undo.clicked();
        compare(backendItem.undoCalls, 1);
        backendItem.canRedo = true;
        compare(redo.enabled, true);
        redo.clicked();
        compare(backendItem.redoCalls, 1);
        editor.requestActivate();
        keyClick(Qt.Key_Z, Qt.ControlModifier);
        compare(backendItem.undoCalls, 2);
        keyClick(Qt.Key_Z, Qt.ControlModifier | Qt.ShiftModifier);
        compare(backendItem.redoCalls, 2);
    }

    function test_escLetsGoOfTheSelectionBeforeClosing() {
        editor.requestActivate();
        backendItem.dirty = true;
        backendItem.selectedId = 2;
        keyClick(Qt.Key_Escape);
        compare(backendItem.selectNoneCalls, 1, "the first Esc deselects");
        compare(keepSheet().shown, false, "and does not close");
        keyClick(Qt.Key_Escape);
        compare(keepSheet().shown, true, "the next one closes, and with changes the window asks");
        verify(editor.visible, "the window stays until the question is answered");
    }

    function test_closingWithChangesAsksAndWithoutDoesNot() {
        backendItem.dirty = true;
        editor.close();
        compare(keepSheet().shown, true);
        verify(editor.visible);
        compare(editor.discarding, false);
        // Done answers the question: it saves (a failed save keeps the window, as before).
        backendItem.doneResult = false;
        keepSheet().accepted();
        compare(backendItem.doneCalls, 1);
        verify(editor.visible, "a failed save keeps the window and the edits");
        keepSheet().close();
        compare(keepSheet().shown, false, "Cancel goes back to the picture");
    }

    function test_theKeysAreHeldWhileTheQuestionIsShown() {
        editor.requestActivate();
        backendItem.dirty = true;
        backendItem.selectedId = 3;
        editor.close();
        compare(keepSheet().shown, true);
        keyClick(Qt.Key_Delete);
        compare(backendItem.deleteCalls, 0, "no shortcut acts behind the sheet");
        keyClick(Qt.Key_A);
        compare(backendItem.tool, "select");
    }

    function test_thePointerIsConvertedToPicturePixelsAtScaleOnePointTwoFive() {
        const view = editor.zoomView;
        view.actualSize();
        view.zoomIn();
        fuzzyCompare(view.viewScale, 1.25, 1e-9);
        view.flickable.contentX = 0;
        view.flickable.contentY = 0;
        const pointer = findChild(editor.contentItem, "annotationPointer");
        verify(pointer);
        mousePress(pointer, 125, 250);
        compare(backendItem.pressArgs.length, 3);
        fuzzyCompare(backendItem.pressArgs[0], 100, 1e-6, "125 points are 100 picture pixels");
        fuzzyCompare(backendItem.pressArgs[1], 200, 1e-6);
        fuzzyCompare(backendItem.pressArgs[2], Tokens.screenshotHitTolerance / 1.25, 1e-6, "the picking reach is in screen points");
        mouseRelease(pointer, 125, 250);
        view.fit();
    }

    function test_theOverlayIsTheViewportNotTheZoomedPicture() {
        const view = editor.zoomView;
        const flick = view.flickable;
        const overlay = findChild(editor.contentItem, "annotationOverlay");
        verify(overlay);
        backendItem.overlaySource = "image://screenshot/overlay/1"; // no provider here: Qt warns, the url is what is checked
        const dpr = Screen.devicePixelRatio;
        const w = Math.round(flick.width * dpr);
        const h = Math.round(flick.height * dpr);
        for (let i = 0; i < 60; i++)
            view.zoomIn();
        compare(view.viewScale, Tokens.screenshotZoomMax, "the largest zoom");
        compare(overlay.sourceSize.width, w, "the view's pixels, not the picture's at 16 times");
        compare(overlay.sourceSize.height, h);
        const parts = String(overlay.source).split("/");
        compare(parts[parts.length - 2], String(w), "the url asks for that size");
        compare(parts[parts.length - 1], String(h));
        // The part of the picture asked for is the viewport's: its width in picture pixels is the view's over the zoom.
        fuzzyCompare(Number(parts[parts.length - 4]), flick.width / 16, 0.01);
        backendItem.overlaySource = "";
        view.fit();
    }

    function test_strokeWidthUsesTheCapturesScaleWhenTheFileHasOne() {
        backendItem.captureScale = 1.25;
        fuzzyCompare(backendItem.toolWidth, Tokens.screenshotStrokeWidth * 1.25, 1e-9, "not the window's integer scale");
        backendItem.captureScale = 2;
        fuzzyCompare(backendItem.toolWidth, Tokens.screenshotStrokeWidth * 2, 1e-9);
        backendItem.captureScale = 0;
        fuzzyCompare(backendItem.toolWidth, Tokens.screenshotStrokeWidth * editor.screen.devicePixelRatio, 1e-9, "unknown: this screen's");
    }

    function test_theTooltipsWriteTheirShortcutInTheDevicesStyle() {
        const undo = findChild(editor.contentItem, "undoButton");
        verify(undo.tooltip.indexOf("Ctrl+Z") >= 0, "pc style: the text");
        Appearance.shortcutStyle = "mac";
        verify(undo.tooltip.indexOf("Ctrl") < 0, "mac style: symbols, not Ctrl");
        verify(undo.tooltip.indexOf("Z") >= 0);
        Appearance.shortcutStyle = "pc";
    }
}
