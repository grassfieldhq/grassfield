pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.platform as Platform

// The editor's menus in the global menu bar (T1: master-prompt 5.7, ADR-0008), exported by Qt through DBusMenu. Editor.qml creates
// it only while the registrar is there, and a fresh one when the registrar restarts (src/main.cpp, apps/globalmenu.h); the
// toolbar stays either way. macOS structure: File, Edit, Tools, View; the app menu and Window are the shell's T0 menus. Edit and
// Tools came with the tools (slices B3 and B4); the later tools add their items. Every item runs the same action as the toolbar and the
// window's shortcuts. A shortcut that an in-window Shortcut also registers is handled once: Qt hands an ambiguous key to one of
// them per press and the window's Shortcut also acts on activatedAmbiguously.
Platform.MenuBar {
    id: bar

    // Editor.qml.
    required property var win

    Platform.Menu {
        title: qsTr("File")

        Platform.MenuItem {
            text: qsTr("Done")
            shortcut: "Ctrl+S"
            onTriggered: bar.win.finish()
        }
        Platform.MenuItem {
            text: qsTr("Revert to Original")
            enabled: bar.win.backend.canRevert
            onTriggered: bar.win.backend.revert()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Close Window")
            shortcut: "Ctrl+W"
            onTriggered: bar.win.close()
        }
    }

    Platform.Menu {
        title: qsTr("Edit")

        Platform.MenuItem {
            text: qsTr("Undo")
            shortcut: "Ctrl+Z"
            enabled: bar.win.backend.canUndo
            onTriggered: bar.win.backend.undo()
        }
        Platform.MenuItem {
            text: qsTr("Redo")
            shortcut: "Ctrl+Shift+Z"
            enabled: bar.win.backend.canRedo
            onTriggered: bar.win.backend.redo()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Delete")
            shortcut: "Backspace"
            enabled: bar.win.backend.selectedId !== 0
            onTriggered: bar.win.backend.deleteSelected()
        }
    }

    Platform.Menu {
        title: qsTr("Tools")

        Platform.MenuItem {
            text: qsTr("Select")
            shortcut: "V"
            checkable: true
            checked: bar.win.backend.tool === "select"
            onTriggered: {
                bar.win.backend.tool = "select";
                // Picking the tool at hand would untick the item and break its binding: the tick follows the tool.
                checked = Qt.binding(() => bar.win.backend.tool === "select");
            }
        }
        Platform.MenuItem {
            text: qsTr("Arrow")
            shortcut: "A"
            checkable: true
            checked: bar.win.backend.tool === "arrow"
            onTriggered: {
                bar.win.backend.tool = "arrow";
                // Picking the tool at hand would untick the item and break its binding: the tick follows the tool.
                checked = Qt.binding(() => bar.win.backend.tool === "arrow");
            }
        }
        Platform.MenuItem {
            text: qsTr("Line")
            shortcut: "L"
            checkable: true
            checked: bar.win.backend.tool === "line"
            onTriggered: {
                bar.win.backend.tool = "line";
                // Picking the tool at hand would untick the item and break its binding: the tick follows the tool.
                checked = Qt.binding(() => bar.win.backend.tool === "line");
            }
        }
        Platform.MenuItem {
            text: qsTr("Rectangle")
            shortcut: "R"
            checkable: true
            checked: bar.win.backend.tool === "rectangle"
            onTriggered: {
                bar.win.backend.tool = "rectangle";
                // Picking the tool at hand would untick the item and break its binding: the tick follows the tool.
                checked = Qt.binding(() => bar.win.backend.tool === "rectangle");
            }
        }
        Platform.MenuItem {
            text: qsTr("Ellipse")
            shortcut: "O"
            checkable: true
            checked: bar.win.backend.tool === "ellipse"
            onTriggered: {
                bar.win.backend.tool = "ellipse";
                // Picking the tool at hand would untick the item and break its binding: the tick follows the tool.
                checked = Qt.binding(() => bar.win.backend.tool === "ellipse");
            }
        }
    }

    Platform.Menu {
        title: qsTr("View")

        Platform.MenuItem {
            text: qsTr("Actual Size")
            shortcut: "Ctrl+0"
            onTriggered: bar.win.zoomView.actualSize()
        }
        Platform.MenuItem {
            text: qsTr("Zoom to Fit")
            shortcut: "Ctrl+9"
            onTriggered: bar.win.zoomView.fit()
        }
        Platform.MenuItem {
            text: qsTr("Zoom In")
            shortcut: "Ctrl++"
            onTriggered: bar.win.zoomView.zoomIn()
        }
        Platform.MenuItem {
            text: qsTr("Zoom Out")
            shortcut: "Ctrl+-"
            onTriggered: bar.win.zoomView.zoomOut()
        }
    }
}
