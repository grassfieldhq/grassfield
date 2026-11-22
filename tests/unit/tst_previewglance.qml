import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/preview/qml"

// Owner report on 1.0.0-rc9: "the Preview window cannot be moved". The Glance (the quick look panel) had no title bar of its
// own that moved it: the window rule gf-glance draws no compositor titlebar on it, and its header started no move. Its header
// is now the apps' toolbar: a drag on its empty space starts the compositor's move (a stand-in window records it), a drag
// from a control does not, and a double-click does nothing (a panel: no zoom, no minimize). Nested: tests/visual/preview-move.sh.
TestCase {
    id: tc
    name: "PreviewGlance"
    when: glance.visible

    QtObject {
        id: backendItem
        property var files: [
            {name: "a.png", path: "/x/a.png", url: "file:///x/a.png", kind: "image"},
            {name: "b.png", path: "/x/b.png", url: "file:///x/b.png", kind: "image"}
        ]
        property var errors: []
        property bool glance: true
        property bool browsing: false
        property int startIndex: 0
        property bool dark: false
        property bool reduceMotion: true
        property bool increaseContrast: false
        property real textScale: 1
        property string accentColor: "multicolor"
        property string accentHighlight: "blue"
        property string shortcutStyle: "pc"
        property string titlebarDoubleClick: "zoom"
        property bool canMinimize: true
        property bool textInImages: false
        function inspect(i) {
            return {ok: true, kind: "image", name: files[i].name, url: files[i].url, width: 1200, height: 800, frames: 1, animated: false};
        }
        function inspectFirst() {
            return inspect(0);
        }
        function openInPreview(i) {
        }
    }

    // Stand-in for the window the header acts on: the calls a drag or a double-click makes.
    QtObject {
        id: standIn
        property int visibility: 2
        property bool active: true
        property var calls: []
        function startSystemMove() {
            calls.push("move");
        }
        function showMaximized() {
            calls.push("maximize");
        }
        function showNormal() {
            calls.push("normal");
        }
        function showMinimized() {
            calls.push("minimize");
        }
        function showFullScreen() {
            calls.push("fullscreen");
        }
        function close() {
            calls.push("close");
        }
    }

    Glance {
        id: glance
        backend: backendItem
    }

    function header(): var {
        const h = findChild(glance.contentItem, "glanceHeader");
        verify(h !== null, "the Glance header");
        return h;
    }

    function test_theHeaderIsTheWindowsTitleBar() {
        const h = header();
        compare(h.window, glance, "the header moves its own window");
        compare(h.height, Tokens.previewGlanceHeaderHeight);
        compare(h.width, glance.width);
        verify(!h.controls.visible, "no lights on the panel: its close glyph is its own");
    }

    function test_aDragOnTheHeaderMovesTheWindow() {
        const h = header();
        h.window = standIn;
        standIn.calls = [];
        // The middle of the header, on the file name (text takes no press).
        mouseDrag(h, h.width / 2, h.height / 2, 200, 100);
        verify(standIn.calls.indexOf("move") >= 0, "a drag on the header moves the window: " + standIn.calls.join(","));
        h.window = glance;
    }

    function test_aDragFromAControlDoesNotMoveTheWindow() {
        const h = header();
        h.window = standIn;
        standIn.calls = [];
        // The "Open with Preview" button at the right end of the header.
        const button = findChild(h, "glanceOpenButton");
        verify(button !== null && button.visible);
        const p = h.mapFromItem(button, button.width / 2, button.height / 2);
        mouseDrag(h, p.x, p.y, -200, 100);
        compare(standIn.calls.indexOf("move"), -1, "a drag from the button: " + standIn.calls.join(","));
        h.window = glance;
    }

    function test_aDoubleClickDoesNothing() {
        const h = header();
        h.window = standIn;
        standIn.calls = [];
        // Qt's synthetic events carry no real timestamps (TapHandler never counts two taps here, tst_windowcontrols.qml):
        // the toolbar's double-click itself, with the Glance's setting.
        h.doubleClicked();
        compare(standIn.calls.length, 0, "a panel neither zooms nor minimizes: " + standIn.calls.join(","));
        compare(h.lastDoubleClick, "none");
        h.window = glance;
    }
}
