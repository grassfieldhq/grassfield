pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.platform as Platform
import "MemoLogic.js" as MemoLogic

// A memo's menus in the global menu bar (T1: master-prompt 5.7, ADR-0008), exported by Qt through DBusMenu; each memo window
// has its own (MemoWindow.qml creates it only while the registrar is there). macOS structure: File, Edit, Font, Color, then
// the Window menu's own items (Translucent, Collapse) in a Note menu (Stickies' own name for it): the shell owns Window (T0), and a second
// one would show twice (ADR-0051 D-5). Every item runs the same action as the window's keys.
Platform.MenuBar {
    id: bar

    // MemoWindow.qml.
    required property var win
    readonly property var editor: bar.win.editor
    readonly property bool expanded: !bar.win.collapsed

    Platform.Menu {
        title: qsTr("File")

        Platform.MenuItem {
            text: qsTr("New Memo")
            shortcut: "Ctrl+N"
            onTriggered: bar.win.manager.newMemo()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Close")
            shortcut: "Ctrl+W"
            onTriggered: bar.win.requestClose()
        }
    }

    Platform.Menu {
        title: qsTr("Edit")

        Platform.MenuItem {
            text: qsTr("Undo")
            shortcut: StandardKey.Undo
            enabled: bar.expanded && bar.editor.canUndo
            onTriggered: bar.editor.undo()
        }
        Platform.MenuItem {
            text: qsTr("Redo")
            shortcut: StandardKey.Redo
            enabled: bar.expanded && bar.editor.canRedo
            onTriggered: bar.editor.redo()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Cut")
            shortcut: StandardKey.Cut
            enabled: bar.expanded && bar.editor.selectedText !== ""
            onTriggered: bar.editor.cut()
        }
        Platform.MenuItem {
            text: qsTr("Copy")
            shortcut: StandardKey.Copy
            enabled: bar.expanded && bar.editor.selectedText !== ""
            onTriggered: bar.editor.copy()
        }
        // The only paste is plain text (macOS's Paste and Match Style; ADR-0051 D-4).
        Platform.MenuItem {
            text: qsTr("Paste")
            shortcut: StandardKey.Paste
            enabled: bar.expanded
            onTriggered: bar.win.paste()
        }
        Platform.MenuItem {
            text: qsTr("Select All")
            shortcut: StandardKey.SelectAll
            enabled: bar.expanded
            onTriggered: bar.editor.selectAll()
        }
    }

    Platform.Menu {
        title: qsTr("Font")

        Platform.MenuItem {
            text: qsTr("Bold")
            shortcut: "Ctrl+B"
            enabled: bar.expanded
            onTriggered: bar.win.bold()
        }
        Platform.MenuItem {
            text: qsTr("Italic")
            shortcut: "Ctrl+I"
            enabled: bar.expanded
            onTriggered: bar.win.italic()
        }
        Platform.MenuItem {
            text: qsTr("Underline")
            shortcut: "Ctrl+U"
            enabled: bar.expanded
            onTriggered: bar.win.underline()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Bigger")
            shortcut: "Ctrl++"
            enabled: bar.expanded
            onTriggered: bar.win.bigger()
        }
        Platform.MenuItem {
            text: qsTr("Smaller")
            shortcut: "Ctrl+-"
            enabled: bar.expanded
            onTriggered: bar.win.smaller()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Bulleted List")
            shortcut: "Ctrl+Shift+7"
            enabled: bar.expanded
            onTriggered: bar.win.toggleList()
        }
    }

    Platform.Menu {
        title: qsTr("Color")

        Platform.MenuItem {
            text: qsTr("Yellow")
            shortcut: MemoLogic.colorShortcut(0)
            checkable: true
            checked: bar.win.colorName === "yellow"
            onTriggered: {
                checked = Qt.binding(() => bar.win.colorName === "yellow");
                bar.win.setColor("yellow");
            }
        }
        Platform.MenuItem {
            text: qsTr("Blue")
            shortcut: MemoLogic.colorShortcut(1)
            checkable: true
            checked: bar.win.colorName === "blue"
            onTriggered: {
                checked = Qt.binding(() => bar.win.colorName === "blue");
                bar.win.setColor("blue");
            }
        }
        Platform.MenuItem {
            text: qsTr("Green")
            shortcut: MemoLogic.colorShortcut(2)
            checkable: true
            checked: bar.win.colorName === "green"
            onTriggered: {
                checked = Qt.binding(() => bar.win.colorName === "green");
                bar.win.setColor("green");
            }
        }
        Platform.MenuItem {
            text: qsTr("Pink")
            shortcut: MemoLogic.colorShortcut(3)
            checkable: true
            checked: bar.win.colorName === "pink"
            onTriggered: {
                checked = Qt.binding(() => bar.win.colorName === "pink");
                bar.win.setColor("pink");
            }
        }
        Platform.MenuItem {
            text: qsTr("Purple")
            shortcut: MemoLogic.colorShortcut(4)
            checkable: true
            checked: bar.win.colorName === "purple"
            onTriggered: {
                checked = Qt.binding(() => bar.win.colorName === "purple");
                bar.win.setColor("purple");
            }
        }
        Platform.MenuItem {
            text: qsTr("Grey")
            shortcut: MemoLogic.colorShortcut(5)
            checkable: true
            checked: bar.win.colorName === "grey"
            onTriggered: {
                checked = Qt.binding(() => bar.win.colorName === "grey");
                bar.win.setColor("grey");
            }
        }
    }

    Platform.Menu {
        title: qsTr("Note")

        Platform.MenuItem {
            text: qsTr("Translucent")
            shortcut: "Ctrl+Alt+T"
            checkable: true
            checked: bar.win.translucent
            onTriggered: {
                checked = Qt.binding(() => bar.win.translucent);
                bar.win.toggleTranslucent();
            }
        }
        Platform.MenuItem {
            text: bar.win.collapsed ? qsTr("Expand") : qsTr("Collapse")
            shortcut: "Ctrl+Alt+C"
            onTriggered: bar.win.toggleCollapsed()
        }
    }
}
