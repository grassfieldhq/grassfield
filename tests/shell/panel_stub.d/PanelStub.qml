import QtQuick
import QtQml
import Quickshell

// Test stand-in of Quickshell's PanelWindow for offscreen runs (no layer-shell backend there): a plain window that takes the
// panel's own properties and is as large as its anchors and its screen make a layer surface. tests/shell/panel_stub.d/stage.sh
// puts it in place of PanelWindow in a staged copy of the module under test; nothing else of the module changes.
FloatingWindow {
    id: stub
    property PanelEdges anchors: PanelEdges {}
    property PanelEdges margins: PanelEdges {}
    property int exclusiveZone: 0
    property int exclusionMode: 0
    property bool focusable: false
    // The size a compositor would configure: the screen's along an axis anchored at both ends, the implicit one otherwise.
    readonly property real stubWidth: screen ? screen.width : 0
    readonly property real stubHeight: screen ? screen.height : 0
    // (A Binding, not a plain binding: the panel's own file sets its implicit size, and this wins over it.)
    Binding {
        stub.implicitWidth: stub.stubWidth
        when: stub.anchors.left === true && stub.anchors.right === true && stub.screen !== null
    }
    Binding {
        stub.implicitHeight: stub.stubHeight
        when: stub.anchors.top === true && stub.anchors.bottom === true && stub.screen !== null
    }
}
