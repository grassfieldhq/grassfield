import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/screenshot/qml"

// The Screenshot editor window with a mock backend (slices B1 and B2): the picture's zoom and fit, the zoom clamps, the title
// block, Done and Revert, and the failure banner. The picture itself is not loaded (no image provider here).
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
        function done() {
            doneCalls++;
            return doneResult;
        }
        function revert() {
            revertCalls++;
            return true;
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
}
