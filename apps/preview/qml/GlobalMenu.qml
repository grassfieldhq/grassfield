pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.platform as Platform

// The viewer's menus in the global menu bar (T1: master-prompt 5.7, ADR-0008), exported by Qt through DBusMenu.
// Viewer.qml creates it only while the registrar is there, and a fresh one when the registrar restarts (src/main.cpp,
// apps/globalmenu.h); the toolbar stays either way. macOS structure: File, Edit, View, Go, Tools; the app menu and Window are the shell's T0 menus. Every item runs
// the same action as the toolbar and the window's shortcuts. A shortcut that an in-window Shortcut also registers is
// handled once: Qt hands an ambiguous key to one of them per press and the window's Shortcut also acts on
// activatedAmbiguously.
Platform.MenuBar {
    id: bar

    // Viewer.qml.
    required property var win
    readonly property var view: bar.win.view
    readonly property bool canZoom: bar.view?.canZoom ?? false
    readonly property bool canSearch: bar.view?.canSearch ?? false
    readonly property int page: bar.view?.currentPage ?? 0

    Platform.Menu {
        title: qsTr("File")

        Platform.MenuItem {
            text: qsTr("Close Window")
            shortcut: "Ctrl+W"
            onTriggered: bar.win.close()
        }
    }

    Platform.Menu {
        title: qsTr("Edit")

        // Text files: the selection of the text view; images: the text selected in the picture (Select Text in Images).
        Platform.MenuItem {
            text: qsTr("Copy")
            shortcut: StandardKey.Copy
            enabled: bar.view?.canCopy ?? false
            onTriggered: bar.view.copy()
        }
        Platform.MenuItem {
            text: qsTr("Select All")
            shortcut: StandardKey.SelectAll
            enabled: bar.view?.canSelectAll ?? false
            onTriggered: bar.view.selectAll()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Find…")
            shortcut: "Ctrl+F"
            enabled: bar.canSearch
            onTriggered: bar.win.openSearch()
        }
        Platform.MenuItem {
            text: qsTr("Find Next")
            shortcut: "Ctrl+G"
            enabled: bar.canSearch && bar.win.searchOpen
            onTriggered: bar.view.nextMatch()
        }
        Platform.MenuItem {
            text: qsTr("Find Previous")
            shortcut: "Ctrl+Shift+G"
            enabled: bar.canSearch && bar.win.searchOpen
            onTriggered: bar.view.previousMatch()
        }
    }

    Platform.Menu {
        title: qsTr("View")

        Platform.MenuItem {
            text: bar.win.showSidebar ? qsTr("Hide Thumbnails") : qsTr("Show Thumbnails")
            shortcut: "Ctrl+Alt+2"
            enabled: bar.win.hasSidebar
            onTriggered: bar.win.sidebarOpen = !bar.win.sidebarOpen
        }
        Platform.MenuItem {
            text: bar.win.infoOpen ? qsTr("Hide Info") : qsTr("Show Info")
            shortcut: "Ctrl+I"
            onTriggered: bar.win.infoOpen = !bar.win.infoOpen
        }
        Platform.MenuItem {
            text: bar.view?.showSource === true ? qsTr("Show Formatted Text") : qsTr("Show Markdown Source")
            enabled: bar.view?.canShowSource === true
            onTriggered: bar.view.showSource = !bar.view.showSource
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Actual Size")
            shortcut: "Ctrl+0"
            enabled: bar.canZoom
            onTriggered: bar.view.actualSize()
        }
        Platform.MenuItem {
            text: qsTr("Zoom to Fit")
            shortcut: "Super+9"
            enabled: bar.canZoom
            onTriggered: bar.view.fit()
        }
        Platform.MenuItem {
            text: qsTr("Zoom In")
            shortcut: "Ctrl++"
            enabled: bar.canZoom
            onTriggered: bar.view.zoomIn()
        }
        Platform.MenuItem {
            text: qsTr("Zoom Out")
            shortcut: "Ctrl+-"
            enabled: bar.canZoom
            onTriggered: bar.view.zoomOut()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: bar.win.slideshow ? qsTr("Stop Slideshow") : qsTr("Slideshow")
            shortcut: "Ctrl+Shift+F"
            enabled: bar.win.fileCount > 1
            onTriggered: bar.win.toggleSlideshow()
        }
    }

    Platform.Menu {
        title: qsTr("Go")

        Platform.MenuItem {
            text: qsTr("Previous Page")
            enabled: bar.win.pages > 1 && bar.page > 0
            onTriggered: bar.view.goToPage(bar.page - 1)
        }
        Platform.MenuItem {
            text: qsTr("Next Page")
            enabled: bar.win.pages > 1 && bar.page < bar.win.pages - 1
            onTriggered: bar.view.goToPage(bar.page + 1)
        }
        Platform.MenuItem {
            text: qsTr("First Page")
            enabled: bar.win.pages > 1 && bar.page > 0
            onTriggered: bar.view.goToPage(0)
        }
        Platform.MenuItem {
            text: qsTr("Last Page")
            enabled: bar.win.pages > 1 && bar.page < bar.win.pages - 1
            onTriggered: bar.view.goToPage(bar.win.pages - 1)
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Previous File")
            shortcut: "Left"
            enabled: bar.win.canGoPrevious
            onTriggered: bar.win.go(-1)
        }
        Platform.MenuItem {
            text: qsTr("Next File")
            shortcut: "Right"
            enabled: bar.win.canGoNext
            onTriggered: bar.win.go(1)
        }
    }

    Platform.Menu {
        title: qsTr("Tools")

        Platform.MenuItem {
            text: qsTr("Rotate Left")
            shortcut: "Ctrl+L"
            enabled: bar.view?.canRotate ?? false
            onTriggered: bar.view.rotate(-1)
        }
        Platform.MenuItem {
            text: qsTr("Rotate Right")
            shortcut: "Ctrl+R"
            enabled: bar.view?.canRotate ?? false
            onTriggered: bar.view.rotate(1)
        }
    }
}
