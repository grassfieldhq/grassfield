pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.platform as Platform
import Grassfield.Ui

// A browser window's menus in the global menu bar (T1: master-prompt 5.7, ADR-0008), exported by Qt through DBusMenu.
// BrowserWindow.qml creates one per window, only while the registrar is there, and a fresh one when the registrar
// restarts (src/main.cpp, apps/globalmenu.h); the toolbar, context menus and Action menu stay either way. macOS structure: File, Edit, View, Go; the app menu and
// Window are the shell's T0 menus (tab switching is under View). Every item runs the same BrowserTab action as the
// window's own menus and shortcuts. A shortcut that an in-window Shortcut also registers is handled once: Qt hands an
// ambiguous key to one of them per press and the window's Shortcut also acts on activatedAmbiguously.
Platform.MenuBar {
    id: bar

    // BrowserWindow.qml.
    required property var win
    // The items with a key are live only while no window of the browser's own (Get Info, Customize Folder) is the key
    // window: Qt matches their keys there too (BrowserWindow.childIsKey), and Ctrl+W typed in Get Info closed the browser.
    readonly property bool keysHere: bar.win.childIsKey !== true
    readonly property var app: bar.win.app
    readonly property var tab: bar.win.tab
    // The listing the selection actions apply to (the focused column in the column view).
    readonly property var folder: bar.win.folder
    readonly property int count: bar.folder ? bar.folder.selectedCount : 0
    readonly property bool inTrash: bar.folder !== null && bar.folder.isTrash
    readonly property bool inApplications: bar.folder !== null && bar.folder.isApplications === true
    readonly property bool writable: bar.folder !== null && bar.folder.writable
    // Items can be renamed, cut and trashed (BrowserTab.itemsEditable: a writable folder or a tag search).
    readonly property bool editable: bar.folder !== null && !bar.inTrash && (bar.folder.writable || bar.folder.isSearch)
    // Colour tags of the selection, read again on every selection change and every tag write.
    readonly property string tagsReason: {
        void bar.app.tagRevision;
        const f = bar.folder;
        return f && f.selectedCount > 0 ? bar.app.tagsUnavailable(f.selectedUrls()) : "";
    }
    readonly property var tagStates: {
        void bar.app.tagRevision;
        const f = bar.folder;
        return f && f.selectedCount > 0 && bar.tagsReason === "" ? bar.app.colorTagStates(f.selectedUrls()) : [];
    }
    // These read folder.selectedCount themselves: its NOTIFY (selectionChanged) fires on every selection change, while a
    // binding on `count` only re-runs when the number changes (selecting another single item kept the old name and
    // Open With list, and Open With then acted on the new selection: review of 72272e4).
    // Shortened in its middle when long (BrowserWindow.menuName): the menu bar keeps its menus' width.
    readonly property string firstName: bar.folder && bar.folder.selectedCount === 1 ? bar.label(bar.win.menuName(DisplayName.text(bar.folder.nameAt(bar.folder.selectedRows()[0])))) : ""
    // Open With: for a selection of files (re-read when the selection changes), the applications for them and Other…, the
    // Choose Application panel (ADR-0035 5c-1).
    readonly property bool openWithFiles: {
        const f = bar.folder;
        // Not in Applications: an item there is an application (the desktop entry is not a file to open with another one:
        // Kdenlive offered itself for "*.kdenlive" and was started with a grassfield-app: URL).
        if (!f || f.selectedCount === 0 || f.isTrash || f.isApplications)
            return false;
        return f.selectedRows().every(r => !f.isDirAt(r));
    }
    readonly property var openWithApps: {
        const f = bar.folder;
        if (!f || f.selectedCount === 0 || f.isTrash || f.isApplications)
            return [];
        const rows = f.selectedRows();
        if (!rows.every(r => !f.isDirAt(r)))
            return [];
        return bar.app.applicationsFor(f.selectedUrls());
    }

    // What Add to Sidebar would add (BrowserTab.sidebarCandidates), read again on every selection and Favorites change.
    readonly property var sidebarCandidates: {
        void bar.app.places.pinnedCount;
        void bar.app.places.firstPinnedRow;
        const f = bar.folder;
        void (f ? f.selectedCount : 0);
        return bar.tab && bar.tab.sidebarCandidates ? bar.tab.sidebarCandidates() : [];
    }

    // Customize Folder applies to a selection of local folders. Read from folder.selectedCount (its NOTIFY fires on every
    // selection change, also from one item to another one: a binding on `count` does not, and canCustomize() reads no
    // property, so the menu item stayed stale: the bug class above) and from the folder style revision.
    readonly property bool customizeEnabled: {
        void bar.app.folderStyleRevision;
        const f = bar.folder;
        if (!f || f.selectedCount === 0)
            return false;
        return f.selectedRows().every(r => f.isDirAt(r)) && bar.app.folderStyleUnavailable(f.selectedUrls()) === "";
    }

    // View > Sort By and Group By (their check marks follow the shown folder's arrangement; tst_filesglobalmenu reads them).
    readonly property var sortMenu: sortByMenu
    readonly property var groupMenu: groupByMenu
    readonly property var sortKeys: [
        {key: 0, text: qsTr("Name")}, {key: 1, text: qsTr("Kind")}, {key: 7, text: qsTr("Application")},
        {key: 5, text: qsTr("Date Last Opened")}, {key: 2, text: qsTr("Date Modified")}, {key: 4, text: qsTr("Date Created")},
        {key: 3, text: qsTr("Size")}, {key: 6, text: qsTr("Tags")}
    ]
    readonly property var groupKeys: [
        {key: 0, text: qsTr("None")}, {key: 1, text: qsTr("Name")}, {key: 2, text: qsTr("Kind")}, {key: 3, text: qsTr("Application")},
        {key: 4, text: qsTr("Date Last Opened")}, {key: 5, text: qsTr("Date Modified")}, {key: 6, text: qsTr("Date Created")},
        {key: 7, text: qsTr("Size")}, {key: 8, text: qsTr("Tags")}
    ]

    // Menu text from data (file and application names): one line, and a literal & doubled (a single one marks a
    // mnemonic in Qt menus).
    function label(text: string): string {
        return DisplayName.text(text).replace(/&/g, "&&");
    }

    Platform.Menu {
        title: qsTr("File")

        Platform.MenuItem {
            text: qsTr("New Window")
            shortcut: "Ctrl+N"
            enabled: bar.keysHere
            onTriggered: bar.win.manager.newWindow(bar.app.newWindowUrl, null)
        }
        Platform.MenuItem {
            text: qsTr("New Folder")
            shortcut: "Ctrl+Shift+N"
            enabled: bar.keysHere && bar.writable && !bar.inTrash
            onTriggered: bar.tab.newFolder()
        }
        Platform.MenuItem {
            text: bar.count > 1 ? qsTr("New Folder with Selection (%1 Items)").arg(bar.count) : qsTr("New Folder with Selection")
            shortcut: "Ctrl+Meta+N"
            enabled: bar.keysHere && bar.writable && bar.count > 0 && !bar.inTrash && !bar.folder.isSearch
            onTriggered: bar.tab.newFolderWithSelection()
        }
        // A smart folder: an empty search in a new window, its rules added with + (ADR-0027).
        Platform.MenuItem {
            text: qsTr("New Smart Folder")
            shortcut: "Ctrl+Alt+N"
            enabled: bar.keysHere
            onTriggered: bar.win.newSmartFolder()
        }
        Platform.MenuItem {
            text: qsTr("New Tab")
            shortcut: "Ctrl+T"
            enabled: bar.keysHere
            onTriggered: bar.win.newTab(bar.app.newWindowUrl, null)
        }
        Platform.MenuItem {
            text: qsTr("Reopen Closed Tab")
            shortcut: "Ctrl+Alt+Shift+T"
            enabled: bar.keysHere && bar.win.manager.closedTabs.length > 0
            onTriggered: bar.win.manager.reopenClosedTab(bar.win)
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Open")
            shortcut: "Ctrl+O"
            enabled: bar.keysHere && bar.count > 0
            onTriggered: bar.tab.openSelection()
        }
        Platform.Menu {
            id: openWithMenu
            title: qsTr("Open With")
            enabled: bar.openWithFiles

            Instantiator {
                model: bar.openWithApps

                delegate: Platform.MenuItem {
                    required property var modelData

                    text: bar.label(modelData.name)
                    onTriggered: bar.tab.runAction("app:" + modelData.id, bar.folder)
                }

                onObjectAdded: (index, object) => openWithMenu.insertItem(index, object as Platform.MenuItem)
                onObjectRemoved: (index, object) => openWithMenu.removeItem(object as Platform.MenuItem)
            }
            Platform.MenuSeparator {
                visible: bar.openWithApps.length > 0
            }
            Platform.MenuItem {
                text: qsTr("Other…")
                onTriggered: bar.tab.runAction("openWithOther", bar.folder)
            }
        }
        Platform.MenuItem {
            text: bar.win.tabs.length > 1 ? qsTr("Close Tab") : qsTr("Close Window")
            shortcut: "Ctrl+W"
            enabled: bar.keysHere
            onTriggered: bar.win.closeTab(bar.win.currentIndex)
        }
        // With tabs, the window closes with Shift (Finder).
        Platform.MenuItem {
            text: qsTr("Close Window")
            shortcut: "Ctrl+Shift+W"
            enabled: bar.keysHere
            visible: bar.win.tabs.length > 1
            onTriggered: bar.win.close()
        }
        Platform.MenuItem {
            text: qsTr("Close All")
            shortcut: "Ctrl+Alt+W"
            enabled: bar.keysHere
            visible: bar.win.manager.windows.length > 1
            onTriggered: bar.win.manager.closeAllWindows()
        }
        Platform.MenuItem {
            text: qsTr("Eject")
            shortcut: "Ctrl+E"
            enabled: bar.keysHere && bar.win.canEject === true
            onTriggered: bar.win.ejectVolume()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Get Info")
            shortcut: "Ctrl+I"
            enabled: bar.keysHere && bar.tab !== null
            onTriggered: bar.tab.getInfo()
        }
        Platform.MenuItem {
            text: qsTr("Tags…")
            enabled: bar.keysHere && bar.count > 0 && !bar.inTrash && bar.folder !== null && !bar.folder.isApplications
            onTriggered: bar.win.editTags(bar.tab.selection())
        }
        Platform.MenuItem {
            text: qsTr("Customize Folder…")
            enabled: bar.tab !== null && bar.customizeEnabled
            onTriggered: bar.tab.customizeSelection()
        }
        Platform.MenuItem {
            text: bar.count > 1 ? qsTr("Rename %1 Items…").arg(bar.count) : qsTr("Rename")
            shortcut: bar.count > 1 ? "" : "F2"
            enabled: bar.keysHere && bar.count > 0 && bar.editable
            onTriggered: bar.count > 1 ? bar.win.renameItems(bar.tab.selection(), bar.folder) : bar.tab.renameSelection()
        }
        Platform.MenuItem {
            text: bar.count > 1 ? qsTr("Compress %1 Items").arg(bar.count) : bar.count === 1 ? qsTr("Compress “%1”").arg(bar.firstName) : qsTr("Compress")
            enabled: bar.keysHere && bar.count > 0 && !bar.inTrash && bar.folder !== null && !bar.folder.isSearch && String(bar.folder.url).startsWith("file:")
            onTriggered: bar.app.compress(bar.tab.selection(), bar.folder)
        }
        Platform.MenuItem {
            text: qsTr("Duplicate")
            shortcut: "Ctrl+D"
            enabled: bar.keysHere && bar.count > 0 && bar.writable && !bar.inTrash
            onTriggered: bar.tab.duplicateSelection()
        }
        Platform.MenuItem {
            text: qsTr("Make Alias")
            shortcut: "Ctrl+Meta+A"
            enabled: bar.keysHere && bar.count > 0 && bar.writable && !bar.inTrash && String(bar.folder.url).startsWith("file:")
            onTriggered: bar.app.makeAlias(bar.tab.selection(), bar.folder)
        }
        Platform.MenuItem {
            text: qsTr("Show Original")
            shortcut: "Ctrl+R"
            enabled: bar.keysHere && bar.count === 1 && String(bar.app.linkTarget(bar.tab.selection()[0])) !== ""
            onTriggered: bar.tab.showOriginal()
        }
        // The Finder's Add to Sidebar (⌃⌘T): the selected folders, or the shown folder with nothing selected (FP-27).
        Platform.MenuItem {
            text: qsTr("Add to Sidebar")
            shortcut: "Ctrl+Meta+T"
            enabled: bar.keysHere && bar.tab !== null && bar.sidebarCandidates.length > 0
            onTriggered: bar.tab.addToSidebar()
        }
        Platform.MenuItem {
            text: bar.count > 1 ? qsTr("Glance at %1 Items").arg(bar.count) : bar.count === 1 ? qsTr("Glance at “%1”").arg(bar.firstName) : qsTr("Glance")
            // Finder's File > Quick Look (Cmd+Y); Space in the views too.
            shortcut: "Ctrl+Y"
            enabled: bar.keysHere && bar.count > 0 && !bar.inTrash && !bar.inApplications
            onTriggered: bar.tab.glance()
        }
        // The colour tags of the selection (the window's item menu shows them as a row of colour dots).
        Platform.Menu {
            id: tagsMenu
            title: qsTr("Tags")
            enabled: bar.count > 0 && bar.tagsReason === ""

            Instantiator {
                model: bar.app.colorTagNames

                delegate: MenuCheckItem {
                    required property string modelData
                    required property int index

                    text: bar.label(modelData)
                    on: bar.tagStates[index] === 2
                    onChosen: bar.tab.toggleColorTag(index)
                }

                onObjectAdded: (index, object) => tagsMenu.insertItem(index, object as Platform.MenuItem)
                onObjectRemoved: (index, object) => tagsMenu.removeItem(object as Platform.MenuItem)
            }
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: bar.inTrash ? qsTr("Put Back") : qsTr("Move to Trash")
            shortcut: "Ctrl+Backspace"
            // An application of the Applications location the Store may uninstall (ADR-0046): the Store is asked, as the item menu does.
            enabled: bar.keysHere && bar.count > 0 && (bar.inTrash || bar.editable || (bar.inApplications && bar.tab !== null && bar.tab.applicationRemovable()))
            onTriggered: bar.tab.trashSelection()
        }
        // Delete Immediately (⌥⌘⌫, FP-52): any item, confirmed.
        Platform.MenuItem {
            text: qsTr("Delete Immediately…")
            shortcut: "Ctrl+Alt+Backspace"
            enabled: bar.keysHere && bar.count > 0 && (bar.inTrash || bar.editable)
            onTriggered: bar.tab.deleteImmediately()
        }
        // Empty Trash (⇧⌘⌫) from anywhere, the Finder's app-menu item exported here (decision F-10). A dev session never
        // empties a trash (ADR-0011), like the folder menu.
        Platform.MenuItem {
            text: qsTr("Empty Trash…")
            shortcut: "Ctrl+Shift+Backspace"
            visible: !bar.app.devSession
            enabled: bar.keysHere && !bar.app.places.trashEmpty
            onTriggered: bar.tab.emptyTrash()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Find")
            shortcut: "Ctrl+F"
            enabled: bar.keysHere
            onTriggered: bar.win.focusSearch()
        }
    }

    Platform.Menu {
        title: qsTr("Edit")

        Platform.MenuItem {
            text: qsTr("Undo")
            shortcut: "Ctrl+Z"
            enabled: bar.keysHere && bar.app.canUndo
            onTriggered: bar.app.undo()
        }
        Platform.MenuItem {
            text: qsTr("Redo")
            shortcut: "Ctrl+Shift+Z"
            enabled: bar.keysHere && bar.app.canRedo
            onTriggered: bar.app.redo()
        }
        Platform.MenuSeparator {}
        // Cut (owner request 2026-11-07, which wins over the Finder here): the items fade until Paste moves them; Esc or a new
        // Copy cancels.
        Platform.MenuItem {
            text: bar.count > 1 ? qsTr("Cut %1 Items").arg(bar.count) : bar.count === 1 ? qsTr("Cut “%1”").arg(bar.firstName) : qsTr("Cut")
            shortcut: "Ctrl+X"
            enabled: bar.keysHere && bar.count > 0 && bar.editable && !bar.inApplications
            onTriggered: bar.tab.copySelection(true)
        }
        Platform.MenuItem {
            text: bar.count > 1 ? qsTr("Copy %1 Items").arg(bar.count) : bar.count === 1 ? qsTr("Copy “%1”").arg(bar.firstName) : qsTr("Copy")
            shortcut: "Ctrl+C"
            enabled: bar.keysHere && bar.count > 0
            onTriggered: bar.tab.copySelection(false)
        }
        // Finder's Copy as Pathname (⌥⌘C; the Finder shows it while ⌥ is held): the paths as text.
        Platform.MenuItem {
            text: bar.count > 1 ? qsTr("Copy %1 Items as Pathnames").arg(bar.count) : qsTr("Copy as Pathname")
            shortcut: "Ctrl+Alt+C"
            enabled: bar.keysHere && bar.count > 0
            onTriggered: bar.app.copyPaths(bar.tab.selection())
        }
        Platform.MenuItem {
            text: bar.app.clipboardCount > 1 ? qsTr("Paste %1 Items").arg(bar.app.clipboardCount) : qsTr("Paste Item")
            shortcut: "Ctrl+V"
            enabled: bar.keysHere && bar.app.canPaste && bar.writable
            onTriggered: bar.tab.paste()
        }
        // The Finder's Move Item Here (shown there while ⌥ is held; the menu bar has no Option items): the copied items moved here.
        Platform.MenuItem {
            text: bar.app.clipboardCount > 1 ? qsTr("Move %1 Items Here").arg(bar.app.clipboardCount) : qsTr("Move Item Here")
            shortcut: "Ctrl+Alt+V"
            enabled: bar.keysHere && bar.app.canPaste && bar.writable
            onTriggered: bar.tab.moveHere()
        }
        Platform.MenuItem {
            text: qsTr("Select All")
            shortcut: "Ctrl+A"
            enabled: bar.keysHere && bar.folder !== null && bar.folder.count > 0
            onTriggered: bar.folder.selectAll()
        }
    }

    Platform.Menu {
        title: qsTr("View")

        MenuCheckItem {
            text: qsTr("as Icons")
            shortcut: "Super+1"
            enabled: bar.keysHere
            on: bar.tab !== null && bar.tab.viewMode === "icons"
            onChosen: bar.tab.setViewMode("icons")
        }
        MenuCheckItem {
            text: qsTr("as List")
            shortcut: "Super+2"
            enabled: bar.keysHere
            on: bar.tab !== null && bar.tab.viewMode === "list"
            onChosen: bar.tab.setViewMode("list")
        }
        MenuCheckItem {
            text: qsTr("as Columns")
            shortcut: "Super+3"
            enabled: bar.keysHere
            on: bar.tab !== null && bar.tab.viewMode === "columns"
            onChosen: bar.tab.setViewMode("columns")
        }
        MenuCheckItem {
            text: qsTr("as Gallery")
            shortcut: "Super+4"
            enabled: bar.keysHere
            on: bar.tab !== null && bar.tab.viewMode === "gallery"
            onChosen: bar.tab.setViewMode("gallery")
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: bar.app.sidebarShown ? qsTr("Hide Sidebar") : qsTr("Show Sidebar")
            shortcut: "Ctrl+Super+S"
            enabled: bar.keysHere
            onTriggered: bar.app.sidebarShown = !bar.app.sidebarShown
        }
        Platform.MenuItem {
            text: bar.tab !== null && bar.tab.previewShown ? qsTr("Hide Preview") : qsTr("Show Preview")
            shortcut: "Ctrl+Shift+P"
            enabled: bar.keysHere && bar.tab !== null
            onTriggered: bar.tab.togglePreview()
        }
        Platform.MenuSeparator {}
        MenuCheckItem {
            text: qsTr("Use Groups")
            shortcut: "Ctrl+Super+0"
            enabled: bar.keysHere && bar.tab !== null
            on: bar.tab !== null && bar.tab.groupBy > 0
            onChosen: bar.tab.toggleGroups()
        }
        // View > Group By and Sort By in the Finder's order (Date Added has no source on Linux files).
        Platform.Menu {
            id: groupByMenu
            title: qsTr("Group By")

            Instantiator {
                model: bar.groupKeys
                delegate: MenuCheckItem {
                    required property var modelData
                    text: modelData.text
                    on: bar.tab !== null && bar.tab.groupBy === modelData.key
                    onChosen: bar.tab.setGroupBy(modelData.key)
                }
                onObjectAdded: (index, object) => groupByMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => groupByMenu.removeItem(object)
            }
        }
        Platform.Menu {
            id: sortByMenu
            title: qsTr("Sort By")

            Instantiator {
                model: bar.sortKeys
                delegate: MenuCheckItem {
                    required property var modelData
                    text: modelData.text
                    on: bar.tab !== null && bar.tab.sortKey === modelData.key
                    onChosen: bar.tab.sortBy(modelData.key, false)
                }
                onObjectAdded: (index, object) => sortByMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => sortByMenu.removeItem(object)
            }
            Platform.MenuSeparator {}
            MenuCheckItem {
                text: qsTr("Descending")
                on: bar.tab !== null && bar.tab.sortDescending
                onChosen: bar.tab.setSortDescending(!bar.tab.sortDescending)
            }
            MenuCheckItem {
                text: qsTr("Keep Folders on Top")
                on: bar.app.foldersFirst
                onChosen: bar.app.foldersFirst = !bar.app.foldersFirst
            }
        }
        MenuCheckItem {
            text: qsTr("Show Hidden Files")
            shortcut: "Ctrl+Shift+."
            enabled: bar.keysHere
            on: bar.app.showHidden
            onChosen: bar.app.showHidden = !bar.app.showHidden
        }
        Platform.MenuSeparator {}
        // Finder's View > Show/Hide Tab Bar: with more than one tab the bar stays.
        Platform.MenuItem {
            text: bar.win.tabBarVisible ? qsTr("Hide Tab Bar") : qsTr("Show Tab Bar")
            shortcut: "Ctrl+Shift+T"
            enabled: bar.keysHere && bar.win.tabs.length <= 1
            onTriggered: bar.app.tabBarShown = !bar.app.tabBarShown
        }
        Platform.MenuItem {
            text: bar.app.pathBarShown ? qsTr("Hide Path Bar") : qsTr("Show Path Bar")
            shortcut: "Ctrl+Alt+P"
            enabled: bar.keysHere
            onTriggered: bar.app.pathBarShown = !bar.app.pathBarShown
        }
        Platform.MenuItem {
            text: bar.app.statusBarShown ? qsTr("Hide Status Bar") : qsTr("Show Status Bar")
            shortcut: "Ctrl+/"
            enabled: bar.keysHere
            onTriggered: bar.app.statusBarShown = !bar.app.statusBarShown
        }
        Platform.MenuItem {
            text: qsTr("Show Previous Tab")
            shortcut: "Ctrl+Shift+Tab"
            enabled: bar.keysHere && bar.win.tabs.length > 1
            onTriggered: bar.win.selectTab(bar.win.currentIndex - 1)
        }
        Platform.MenuItem {
            text: qsTr("Show Next Tab")
            shortcut: "Ctrl+Tab"
            enabled: bar.keysHere && bar.win.tabs.length > 1
            onTriggered: bar.win.selectTab(bar.win.currentIndex + 1)
        }
        // Finder's Window menu items for tabs (the Window menu is the shell's T0 menu: docs/specs/files.md F-10).
        Platform.MenuItem {
            text: qsTr("Move Tab to New Window")
            enabled: bar.win.tabs.length > 1
            onTriggered: bar.win.manager.moveTabToNewWindow(bar.tab)
        }
        Platform.MenuItem {
            text: qsTr("Merge All Windows")
            enabled: bar.win.manager.windows.length > 1
            onTriggered: bar.win.manager.mergeAllWindows(bar.win)
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Reload")
            shortcut: "Ctrl+R"
            enabled: bar.keysHere && bar.tab !== null
            onTriggered: bar.tab.folder.reload()
        }
    }

    Platform.Menu {
        id: goMenu
        title: qsTr("Go")

        Platform.MenuItem {
            text: qsTr("Back")
            shortcut: "Ctrl+["
            enabled: bar.keysHere && bar.tab !== null && bar.tab.canBack
            onTriggered: bar.tab.back()
        }
        Platform.MenuItem {
            text: qsTr("Forward")
            shortcut: "Ctrl+]"
            enabled: bar.keysHere && bar.tab !== null && bar.tab.canForward
            onTriggered: bar.tab.forward()
        }
        Platform.MenuItem {
            text: qsTr("Enclosing Folder")
            shortcut: "Super+Up"
            enabled: bar.keysHere && bar.tab !== null && bar.tab.segments.length > 1
            onTriggered: bar.tab.up()
        }
        Platform.MenuSeparator {}
        // The sidebar places (Favorites, then Locations), opened like a sidebar click (an unmounted volume is mounted).
        // The sidebar's tags are not places of the Go menu (as on macOS).
        Instantiator {
            model: bar.app.places

            delegate: Platform.MenuItem {
                required property int index
                required property string name
                required property url url
                required property bool mounted
                required property string kind

                visible: kind !== "tag"
                text: bar.label(name)
                shortcut: bar.app.placeShortcut(kind, url)
                enabled: bar.keysHere
                onTriggered: bar.win.openPlace(index, url, mounted)
            }

            // After the four navigation items and their separator.
            onObjectAdded: (index, object) => goMenu.insertItem(index + 4, object as Platform.MenuItem)
            onObjectRemoved: (index, object) => goMenu.removeItem(object as Platform.MenuItem)
        }
        Platform.MenuSeparator {}
        // Recent Folders (Finder): the folders shown last, then Clear Menu.
        Platform.Menu {
            id: recentFoldersMenu
            title: qsTr("Recent Folders")
            enabled: bar.app.recentFolders.length > 0

            Instantiator {
                model: bar.app.recentFolders

                delegate: Platform.MenuItem {
                    required property var modelData

                    readonly property var segments: bar.app.pathSegments(modelData.url)
                    text: bar.label(segments.length > 0 ? segments[segments.length - 1].label : String(modelData.url))
                    onTriggered: bar.tab.navigate(modelData.url, true)
                }

                onObjectAdded: (index, object) => recentFoldersMenu.insertItem(index, object as Platform.MenuItem)
                onObjectRemoved: (index, object) => recentFoldersMenu.removeItem(object as Platform.MenuItem)
            }
            Platform.MenuSeparator {}
            Platform.MenuItem {
                text: qsTr("Clear Menu")
                onTriggered: bar.app.clearRecentFolders()
            }
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Go to Folder…")
            shortcut: "Ctrl+Shift+G"
            enabled: bar.keysHere
            onTriggered: bar.win.goToFolder()
        }
        Platform.MenuItem {
            text: qsTr("Connect to Server…")
            shortcut: "Ctrl+K"
            enabled: bar.keysHere
            onTriggered: bar.win.connectToServer()
        }
    }
}
