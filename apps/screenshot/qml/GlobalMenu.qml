pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.platform as Platform

// The editor's menus in the global menu bar (T1: master-prompt 5.7, ADR-0008), exported by Qt through DBusMenu. Editor.qml creates
// it only while the registrar is there, and a fresh one when the registrar restarts (src/main.cpp, apps/globalmenu.h); the
// toolbar stays either way. macOS structure: File, Edit, View, Tools; the app menu and Window are the shell's T0 menus. Edit and
// Tools come with the tools (slice B3 on): an empty menu would be noise. Every item runs the same action as the toolbar and the
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
