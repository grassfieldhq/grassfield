import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/screenshot/qml"

// The Screenshot editor window with a mock backend (slices B1 to B8): the picture's zoom and fit, the zoom clamps, the title
// block, Done and Revert, the failure banner, and the editing: the tool group and its keys, Esc's order, the question when the
// window closes with changes, undo and redo, the pointer's conversion to picture pixels at a 1.25 zoom and the overlay's size; and the
// style bar that follows the tool (colour, width, arrow, fill, text, counters, crop), the text editor and the crop overlay.
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
        property var layerModel: shapes
        property var pressArgs: []
        property int undoCalls: 0
        property int redoCalls: 0
        property int deleteCalls: 0
        property int selectNoneCalls: 0
        property var nudges: []
        // Style, text and crop (slices B5, B6, B8).
        property string selectedType: ""
        property string textStyle: "plain"
        property real textSize: 0
        property string textFamily: ""
        property real counterSize: 0
        property real highlightFactor: 0
        property real highlightOpacity: 0
        property bool textEditing: false
        property int textEditId: 0
        property point textEditPos: Qt.point(0, 0)
        property string textEditText: ""
        property rect cropRect: Qt.rect(0, 0, 0, 0)
        property string cropAspect: "free"
        property bool cropChanges: false
        property var cropAspects: ["free", "original", "1:1", "4:3", "3:2", "16:9", "9:16"]
        property var calls: []
        function record(name, arg) {
            calls = calls.concat([[name, arg]]);
        }
        function applyColor(color) {
            record("applyColor", color);
            toolColor = color;
        }
        function applyWidth(width) {
            record("applyWidth", width);
            toolWidth = width;
        }
        function applyFill(fill) {
            record("applyFill", fill);
            toolFill = fill;
        }
        function applyTextStyle(style) {
            record("applyTextStyle", style);
            textStyle = style;
        }
        function applyTextSize(size) {
            record("applyTextSize", size);
            textSize = size;
        }
        function applyCounterSize(size) {
            record("applyCounterSize", size);
            counterSize = size;
        }
        function editSelectedText() {
            record("editSelectedText", 0);
        }
        function commitText(text) {
            record("commitText", text);
            textEditing = false;
        }
        function cancelText() {
            record("cancelText", 0);
            textEditing = false;
        }
        function setCropAspect(name) {
            record("setCropAspect", name);
            cropAspect = name;
        }
        function applyCrop() {
            record("applyCrop", 0);
        }
        function cancelCrop() {
            record("cancelCrop", 0);
            cropChanges = false;
        }
        function rotateLeft() {
            record("rotateLeft", 0);
        }
        function rotateRight() {
            record("rotateRight", 0);
        }
        function flipHorizontal() {
            record("flipHorizontal", 0);
        }
        function flipVertical() {
            record("flipVertical", 0);
        }
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

    // The shapes of the document as the app's LayerModel gives them (src/layermodel.cpp): one rectangle at (100, 50), 300 x 200.
    ListModel {
        id: shapes
        ListElement {
            gKind: "rect"
            gId: 1
            gColor: "#de3651"
            gStroke: 3
            gFill: false
            boxX: 100
            boxY: 50
            boxW: 300
            boxH: 200
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
        backendItem.undoCalls = 0;
        backendItem.redoCalls = 0;
        backendItem.deleteCalls = 0;
        backendItem.selectNoneCalls = 0;
        backendItem.nudges = [];
        backendItem.pressArgs = [];
        backendItem.calls = [];
        backendItem.selectedType = "";
        backendItem.textEditing = false;
        backendItem.cropRect = Qt.rect(0, 0, 0, 0);
        backendItem.cropChanges = false;
        backendItem.toolFill = false;
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

    function test_theToolGroupHasTheToolsAndOneIsOn() {
        const names = ["select", "arrow", "line", "rectangle", "ellipse", "pen", "highlighter", "text", "counter", "crop"];
        for (const name of names) {
            const button = findChild(editor.contentItem, "tool_" + name);
            verify(button, name);
            compare(button.checked, name === "select", name + " at start");
            verify(button.accessibleName !== "", "a name for assistive technology: " + name);
            verify(button.tooltip !== "", "a tooltip: " + name);
        }
        const rect = findChild(editor.contentItem, "tool_rectangle");
        rect.clicked();
        compare(backendItem.tool, "rectangle");
        compare(rect.checked, true);
        compare(findChild(editor.contentItem, "tool_select").checked, false, "one at a time");
        verify(editor.toolbarMin <= Tokens.screenshotWindowWidth, "the toolbar's items fit the window's own width: " + editor.toolbarMin);
        verify(editor.minimumWidth <= Tokens.screenshotWindowWidth);
    }

    function test_theStyleBarFollowsTheToolAndHoldsTheOptions() {
        const bar = findChild(editor.contentItem, "styleBar");
        const arrowStyle = findChild(editor.contentItem, "arrowStyleGroup");
        const fill = findChild(editor.contentItem, "fillGroup");
        const width = findChild(editor.contentItem, "widthChoice");
        compare(bar.visible, false, "Select with nothing selected: nothing to style");
        compare(bar.height, 0);
        compare(arrowStyle.visible, false);
        compare(fill.visible, false);
        backendItem.tool = "arrow";
        compare(bar.visible, true);
        compare(bar.height, Tokens.screenshotStyleBarHeight);
        compare(arrowStyle.visible, true);
        compare(fill.visible, false);
        compare(width.visible, true);
        findChild(editor.contentItem, "arrow_curved").clicked();
        compare(backendItem.arrowStyle, "curved");
        backendItem.tool = "ellipse";
        compare(arrowStyle.visible, false);
        compare(fill.visible, true);
        findChild(editor.contentItem, "fillButton").clicked();
        compare(backendItem.toolFill, true);
        compare(JSON.stringify(backendItem.calls.slice(-1)), JSON.stringify([["applyFill", true]]));
        backendItem.tool = "text";
        compare(fill.visible, false);
        compare(width.visible, false, "a text has no stroke width");
        compare(findChild(editor.contentItem, "textStyleChoice").visible, true);
        compare(findChild(editor.contentItem, "textSizeChoice").visible, true);
        compare(findChild(editor.contentItem, "counterSizeChoice").visible, false);
        backendItem.tool = "counter";
        compare(findChild(editor.contentItem, "counterSizeChoice").visible, true);
        compare(findChild(editor.contentItem, "textStyleChoice").visible, false);
        backendItem.tool = "crop";
        compare(findChild(editor.contentItem, "colorSwatches").visible, false, "a crop has no colour");
        compare(findChild(editor.contentItem, "cropAspect").visible, true);
        // Select styles what is selected.
        backendItem.tool = "select";
        compare(bar.visible, false);
        backendItem.selectedType = "highlighter";
        compare(bar.visible, true);
        compare(width.visible, true);
        compare(arrowStyle.visible, false);
        backendItem.selectedType = "text";
        compare(findChild(editor.contentItem, "textStyleChoice").visible, true);
        backendItem.selectedType = "";
    }

    function test_theSwatchesAndTheWidthsCallTheBackendWithTheTokensValues() {
        backendItem.tool = "pen";
        const green = findChild(editor.contentItem, "swatch_green");
        verify(green);
        verify(green.Accessible.name !== "");
        green.clicked();
        compare(backendItem.toolColor, String(Qt.color(Tokens.colorSwatch.green)), "the swatch is the design token's colour");
        compare(green.current, true);
        compare(findChild(editor.contentItem, "swatch_red").current, false);
        // The widths are the tokens' points times the capture's scale.
        backendItem.captureScale = 1.25;
        const width = findChild(editor.contentItem, "widthChoice");
        width.picked("large");
        fuzzyCompare(backendItem.toolWidth, Tokens.screenshotStrokeWidthThick * 1.25, 1e-9);
        width.picked("small");
        fuzzyCompare(backendItem.toolWidth, Tokens.screenshotStrokeWidthThin * 1.25, 1e-9);
        compare(width.value, "small", "the choice that is nearest to the width in use");
        backendItem.tool = "text";
        findChild(editor.contentItem, "textSizeChoice").picked("large");
        fuzzyCompare(backendItem.textSize, Tokens.screenshotTextSizeLarge * 1.25, 1e-9);
        findChild(editor.contentItem, "textStyleChoice").picked("pill");
        compare(backendItem.textStyle, "pill");
        backendItem.tool = "counter";
        findChild(editor.contentItem, "counterSizeChoice").picked("small");
        fuzzyCompare(backendItem.counterSize, Tokens.screenshotCounterSize * Tokens.screenshotCounterSizeScaleSmall * 1.25, 1e-9);
        backendItem.captureScale = 0;
    }

    function test_theEyedropperIsInTheStyleBarAndTheColourWellShowsTheColour() {
        backendItem.tool = "pen";
        const eyedropper = findChild(editor.contentItem, "tool_eyedropper");
        verify(eyedropper);
        compare(eyedropper.checked, false);
        eyedropper.clicked();
        compare(backendItem.tool, "eyedropper");
        compare(eyedropper.checked, true);
        compare(findChild(editor.contentItem, "colorSwatches").visible, true, "the strip stays while the eyedropper is at hand");
        backendItem.toolColor = "#123456";
        compare(String(findChild(editor.contentItem, "colorWell").color), "#123456");
        compare(findChild(editor.contentItem, "swatch_red").current, false, "a picked colour is none of the swatches");
    }

    function test_theCropControlsCallTheBackend() {
        backendItem.tool = "crop";
        backendItem.cropRect = Qt.rect(0, 0, 2000, 1000);
        const apply = findChild(editor.contentItem, "cropApply");
        const cancel = findChild(editor.contentItem, "cropCancel");
        compare(apply.enabled, false, "nothing to apply while the rectangle is the whole picture");
        compare(cancel.enabled, false);
        backendItem.cropChanges = true;
        compare(apply.enabled, true);
        findChild(editor.contentItem, "cropAspect").picked("16:9");
        compare(backendItem.cropAspect, "16:9");
        for (const name of ["rotateLeft", "rotateRight", "flipHorizontal", "flipVertical"]) {
            const button = findChild(editor.contentItem, "turn_" + name);
            verify(button, name);
            verify(button.accessibleName !== "");
            button.clicked();
        }
        apply.clicked();
        cancel.clicked();
        compare(JSON.stringify(backendItem.calls.map(c => c[0])), JSON.stringify(["setCropAspect", "rotateLeft", "rotateRight", "flipHorizontal", "flipVertical", "applyCrop", "cancelCrop"]));
    }

    function test_theCropOverlayShowsOnlyWithTheToolAndFollowsTheZoom() {
        const overlay = findChild(editor.contentItem, "cropOverlay");
        verify(overlay);
        compare(overlay.visible, false);
        backendItem.cropRect = Qt.rect(100, 50, 300, 200);
        compare(overlay.visible, false, "no rectangle without the tool");
        backendItem.tool = "crop";
        compare(overlay.visible, true);
        const view = editor.zoomView;
        for (const zoom of [1, 1.25, 2.5]) {
            view.setZoom(zoom);
            let found = 0;
            for (const child of overlay.children) {
                // The rectangle's border: a transparent item with the border width.
                if (child.border && child.border.width === Tokens.screenshotCropBorderWidth && String(child.color) === "#00000000") {
                    found++;
                    fuzzyCompare(child.x, 100 * zoom, 1e-6, "at zoom " + zoom);
                    fuzzyCompare(child.width, 300 * zoom, 1e-6);
                }
            }
            compare(found, 1, "the border at zoom " + zoom);
        }
        view.fit();
        // The handles of the selection are not drawn while cropping.
        backendItem.handles = [{x: 100, y: 50}];
        const scene = findChild(editor.contentItem, "shapeScene");
        let handles = 0;
        for (const child of scene.parent.children) {
            if (child !== scene && child.width === Tokens.screenshotHandleSize)
                handles++;
        }
        compare(handles, 0);
        backendItem.handles = [];
        backendItem.cropRect = Qt.rect(0, 0, 0, 0);
    }

    function test_theTextEditorTypesAndReturnPutsTheTextIn() {
        editor.requestActivate();
        const box = findChild(editor.contentItem, "textEditor");
        const input = findChild(editor.contentItem, "textEditInput");
        verify(box);
        compare(box.visible, false);
        backendItem.tool = "text";
        backendItem.textEditPos = Qt.point(100, 40);
        backendItem.textEditText = "";
        backendItem.textEditing = true;
        compare(box.visible, true);
        const view = editor.zoomView;
        fuzzyCompare(box.x + Tokens.spacingXs, 100 * view.viewScale, 1e-6, "at the click, in the picture's scale");
        tryCompare(input, "activeFocus", true);
        // While typing, the tool letters, Delete, the arrows and the undo keys are the text's.
        keyClick(Qt.Key_P);
        keyClick(Qt.Key_Delete);
        compare(backendItem.tool, "text");
        compare(backendItem.deleteCalls, 0);
        compare(input.text, "p");
        keyClick(Qt.Key_Return, Qt.ShiftModifier);
        keyClick(Qt.Key_Q);
        compare(input.text, "p\nq", "Shift+Return starts a new line");
        keyClick(Qt.Key_Return);
        compare(JSON.stringify(backendItem.calls.slice(-1)), JSON.stringify([["commitText", "p\nq"]]));
        compare(box.visible, false);
        compare(backendItem.undoCalls, 0);
    }

    function test_escGivesTheTextUpAndTheCropBeforeAnythingElse() {
        editor.requestActivate();
        backendItem.tool = "text";
        backendItem.textEditing = true;
        const input = findChild(editor.contentItem, "textEditInput");
        tryCompare(input, "activeFocus", true);
        keyClick(Qt.Key_Escape);
        compare(JSON.stringify(backendItem.calls.slice(-1)), JSON.stringify([["cancelText", 0]]));
        compare(backendItem.textEditing, false);

        backendItem.tool = "crop";
        backendItem.cropRect = Qt.rect(0, 0, 500, 500);
        backendItem.cropChanges = true;
        backendItem.selectedId = 4;
        keyClick(Qt.Key_Escape);
        compare(JSON.stringify(backendItem.calls.slice(-1)), JSON.stringify([["cancelCrop", 0]]), "the crop first");
        compare(backendItem.selectedId, 4);
        keyClick(Qt.Key_Return);
        compare(backendItem.calls.slice(-1)[0][0], "applyCrop", "Return applies the crop");
        backendItem.cropRect = Qt.rect(0, 0, 0, 0);
        backendItem.selectedId = 0;
    }

    function test_returnEditsTheSelectedTextAndTheRotateKeysRotate() {
        editor.requestActivate();
        backendItem.selectedType = "text";
        backendItem.selectedId = 3;
        keyClick(Qt.Key_Return);
        compare(backendItem.calls.slice(-1)[0][0], "editSelectedText");
        keyClick(Qt.Key_L, Qt.ControlModifier);
        compare(backendItem.calls.slice(-1)[0][0], "rotateLeft");
        keyClick(Qt.Key_R, Qt.ControlModifier);
        compare(backendItem.calls.slice(-1)[0][0], "rotateRight");
        backendItem.selectedType = "";
        backendItem.selectedId = 0;
    }

    function test_toolLettersSwitchToTheNewTools() {
        editor.requestActivate();
        for (const [key, tool] of [[Qt.Key_P, "pen"], [Qt.Key_H, "highlighter"], [Qt.Key_T, "text"], [Qt.Key_N, "counter"], [Qt.Key_I, "eyedropper"], [Qt.Key_C, "crop"]]) {
            keyClick(key);
            compare(backendItem.tool, tool);
        }
        keyClick(Qt.Key_V);
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

    function test_theShapesAreSceneItemsThatFollowTheZoomAndTheScroll() {
        const view = editor.zoomView;
        const flick = view.flickable;
        const scene = findChild(editor.contentItem, "shapeScene");
        const content = findChild(editor.contentItem, "shapeContent");
        verify(scene);
        verify(content);
        verify(content.children.length >= 1);
        const shape = content.children[0];
        verify(shape.visible);
        compare(scene.clip, true, "clipped to the picture, as the export is");
        compare(scene.width, view.holder.width, "the scene is the picture's size on screen");
        for (const zoom of [1, 1.25, 2.5, 16]) {
            view.setZoom(zoom);
            compare(content.scale, view.viewScale, "scaled by the zoom: nothing is drawn again");
            // The rectangle's corner (100, 50) is at the zoom times it from the picture's own corner, scroll or not.
            const corner = shape.mapToItem(view.holder, 100, 50);
            fuzzyCompare(corner.x, 100 * view.viewScale, 1e-6, "at zoom " + zoom);
            fuzzyCompare(corner.y, 50 * view.viewScale, 1e-6);
            // And in the view: the holder's place in the content, less the scroll.
            const inView = shape.mapToItem(flick, 100, 50);
            fuzzyCompare(inView.x, view.holder.x - flick.contentX + 100 * view.viewScale, 1e-6);
            fuzzyCompare(inView.y, view.holder.y - flick.contentY + 50 * view.viewScale, 1e-6);
            flick.contentX = Math.min(37, Math.max(0, flick.contentWidth - flick.width));
            flick.contentY = Math.min(21, Math.max(0, flick.contentHeight - flick.height));
            const scrolled = shape.mapToItem(flick, 100, 50);
            fuzzyCompare(scrolled.x, view.holder.x - flick.contentX + 100 * view.viewScale, 1e-6, "scrolled, at zoom " + zoom);
            flick.contentX = 0;
            flick.contentY = 0;
        }
        view.fit();
    }

    function test_theHandlesAreAboveTheShapes() {
        backendItem.handles = [{x: 100, y: 50}, {x: 400, y: 250}];
        const scene = findChild(editor.contentItem, "shapeScene");
        const layer = scene.parent;
        let handles = 0;
        for (const child of layer.children) {
            if (child !== scene && child.width === Tokens.screenshotHandleSize) {
                handles++;
                verify(child.z > scene.z, "above the shapes");
            }
        }
        compare(handles, 2);
        backendItem.handles = [];
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
