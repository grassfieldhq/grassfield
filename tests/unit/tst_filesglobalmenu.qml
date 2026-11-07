pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../apps/files/qml"

// The global menu's Customize Folder item follows the selection (apps/files/qml/GlobalMenu.qml customizeEnabled): going
// from one file to one folder (the number of selected items stays 1) must enable it. The old binding depended on `count`
// and an untracked function and stayed stale. The tab and window items (docs/specs/files.md "Tabs and windows") follow
// the window, its tabs and the closed-tab stack; Sort By shows the shown folder's own arrangement.
TestCase {
    id: test
    name: "FilesGlobalMenu"
    when: windowShown

    QtObject {
        id: folderItem
        property int selectedCount: 0
        property var dirs: ({})
        property var rows: []
        signal selectionChanged
        function selectedRows(): var {
            return folderItem.rows;
        }
        function isDirAt(row: int): bool {
            return folderItem.dirs[row] === true;
        }
        function selectedUrls(): var {
            return folderItem.rows.map(r => "file:///sandbox/item" + r);
        }
        function nameAt(row: int): string {
            return "item" + row;
        }
        property bool isTrash: false
        property bool isApplications: false
        property bool writable: true
        property bool isSearch: false
    }

    QtObject {
        id: fakeApp
        property int folderStyleRevision: 0
        property int tagRevision: 0
        // Everything the menu binds to, so that a real binding error is never hidden among fixture warnings (GF-073).
        property bool canUndo: false
        property bool canRedo: false
        property bool canPaste: false
        property bool galleryInfo: false
        property bool sortDescending: false
        property bool foldersFirst: true
        property bool showHidden: false
        property bool devSession: false
        property bool tabBarShown: false
        property bool sidebarShown: true
        property bool pathBarShown: false
        property bool statusBarShown: false
        property url newWindowUrl: "file:///sandbox"
        property var places: ({trashEmpty: true})
        function folderStyleUnavailable(urls: var): string {
            return "";
        }
        function tagsUnavailable(urls: var): string {
            return "";
        }
        function colorTagStates(urls: var): var {
            return [];
        }
        // The Go menu (FP-75): no recent folder, no shortcut of its own; no alias selected.
        property var recentFolders: []
        function placeShortcut(kind: string, target: url): string {
            return "";
        }
        function linkTarget(target: url): url {
            return "";
        }
        // Applications that could open the files: always one, so that only the menu's own rule can empty the list.
        function applicationsFor(urls: var): var {
            return [{storageId: "editor", name: "Editor"}];
        }
    }

    QtObject {
        id: fakeManager
        property var closedTabs: []
        property var windows: [fakeWin]
        property int reopened: 0
        property int merged: 0
        function reopenClosedTab(win: var): void {
            fakeManager.reopened++;
        }
        function mergeAllWindows(win: var): void {
            fakeManager.merged++;
        }
    }

    QtObject {
        id: fakeWin
        property var app: fakeApp
        property var manager: fakeManager
        property bool tabBarVisible: false
        property var tab: ({canBack: false, canForward: false, segments: [], sortKey: 2, sortDescending: true, groupBy: 8, selection: () => []})
        property var folder: folderItem
        property var tabs: []
        property int currentIndex: 0
        property bool canEject: false
        property int ejected: 0
        function ejectVolume(): bool {
            fakeWin.ejected++;
            return true;
        }
        // BrowserWindow.menuName: the name shortened in its middle (here: a marker).
        function menuName(name: string): string {
            return "<" + name + ">";
        }
    }

    Component {
        id: menuComponent

        GlobalMenu {
            win: fakeWin
        }
    }

    function select(rows, dirs) {
        // The model changes the rows first, then the count (NOTIFY), like FolderModel.
        folderItem.dirs = dirs;
        folderItem.rows = rows;
        folderItem.selectedCount = rows.length;
        folderItem.selectionChanged();
    }

    function test_customizeFollowsTheSelection() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        compare(bar.customizeEnabled, false, "nothing selected");
        select([0], {0: false});
        compare(bar.customizeEnabled, false, "one file");
        // One file -> one folder: selectedCount stays 1.
        folderItem.dirs = {1: true};
        folderItem.rows = [1];
        folderItem.selectedCount = 0;
        folderItem.selectedCount = 1;
        compare(bar.customizeEnabled, true, "one folder");
        select([2, 3], {2: true, 3: false});
        compare(bar.customizeEnabled, false, "a folder and a file");
        select([2, 4], {2: true, 4: true});
        compare(bar.customizeEnabled, true, "two folders");
        select([], {});
        compare(bar.customizeEnabled, false, "nothing again");
    }

    // The Applications location: the items are applications, not files. Open With offers nothing (a desktop entry is not a file to
    // open with another application) and Glance is off, in a folder of files both are there.
    function test_applicationsOffersNoOpenWithAndNoGlance() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        select([0], {0: false});
        compare(bar.inApplications, false);
        compare(bar.openWithApps.length, 1, "a file of a folder has Open With");
        folderItem.isApplications = true;
        compare(bar.inApplications, true);
        compare(bar.openWithApps.length, 0, "no Open With in Applications");
        const glance = findItem(bar, "Glance");
        verify(glance !== null, "the Glance item is found");
        compare(glance.enabled, false, "no Glance in Applications");
        folderItem.isApplications = false;
        compare(glance.enabled, true, "Glance in a folder of files");
    }

    // Open With > Other… (ADR-0035 5c-1): for files, whatever the applications for them; it asks the tab for the Choose
    // Application panel. Not for a folder, not in Applications.
    function test_openWithOther() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        select([0], {0: false});
        compare(bar.openWithFiles, true, "a file");
        const other = findAny(bar, "Other…");
        verify(other !== null, "Open With has Other…");
        // The type's applications, a separator, Other….
        const menu = findMenu(bar, "Open With");
        verify(menu !== null, "the Open With menu");
        compare(Array.from(menu.items).filter(i => i.visible).map(i => i.separator ? "-" : i.text), ["Editor", "-", "Other…"]);
        const asked = [];
        const tab = fakeWin.tab;
        fakeWin.tab = Object.assign({}, tab, {
            runAction: (id, f) => asked.push(id)
        });
        other.triggered();
        fakeWin.tab = tab;
        compare(asked, ["openWithOther"]);
        select([0], {0: true});
        compare(bar.openWithFiles, false, "a folder");
        select([0], {0: false});
        folderItem.isApplications = true;
        compare(bar.openWithFiles, false, "Applications");
        folderItem.isApplications = false;
        folderItem.isTrash = true;
        compare(bar.openWithFiles, false, "the Trash");
        folderItem.isTrash = false;
        select([], {});
        compare(bar.openWithFiles, false, "nothing selected");
    }

    // The menu titled `title` below `item`.
    function findMenu(item: var, title: string): var {
        const stack = [item];
        const seen = [];
        while (stack.length > 0 && seen.length < 2000) {
            const it = stack.pop();
            if (it === null || it === undefined || seen.indexOf(it) >= 0)
                continue;
            seen.push(it);
            if (it.title === title && it.items !== undefined)
                return it;
            for (const list of [it.menus, it.items, it.data]) {
                if (list !== undefined && list !== null && list.length !== undefined) {
                    for (let i = 0; i < list.length; i++)
                        stack.push(list[i]);
                }
            }
            if (it.subMenu !== undefined)
                stack.push(it.subMenu);
        }
        return null;
    }

    // Any menu item (with or without a shortcut) whose text is `text`, below `item`, submenus included.
    function findAny(item: var, text: string): var {
        const stack = [item];
        const seen = [];
        while (stack.length > 0 && seen.length < 2000) {
            const it = stack.pop();
            if (it === null || it === undefined || seen.indexOf(it) >= 0)
                continue;
            seen.push(it);
            if (it.text === text && it.triggered !== undefined)
                return it;
            for (const list of [it.menus, it.items, it.data]) {
                if (list !== undefined && list !== null && list.length !== undefined) {
                    for (let i = 0; i < list.length; i++)
                        stack.push(list[i]);
                }
            }
            if (it.subMenu !== undefined)
                stack.push(it.subMenu);
        }
        return null;
    }

    // The menu item whose text starts with `prefix`, below `item`: through the menus' `menus` and `items` (the items hold their
    // menu, so every object is visited once).
    function findItem(item: var, prefix: string): var {
        const stack = [item];
        const seen = [];
        while (stack.length > 0 && seen.length < 2000) {
            const it = stack.pop();
            if (it === null || it === undefined || seen.indexOf(it) >= 0)
                continue;
            seen.push(it);
            if (it.shortcut !== undefined && it.text !== undefined && String(it.text).startsWith(prefix))
                return it;
            for (const list of [it.menus, it.items]) {
                if (list !== undefined && list !== null && list.length !== undefined) {
                    for (let i = 0; i < list.length; i++)
                        stack.push(list[i]);
                }
            }
        }
        return null;
    }

    // File > Eject (Ctrl+E) follows the window's canEject and ejects through the window: the keyboard path to the sidebar's
    // eject button, which is out of the Tab chain.
    function test_fileMenuHasEject() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        let item = null;
        const file = bar.menus[0];
        for (let i = 0; i < file.items.length; i++) {
            if (file.items[i].text === "Eject")
                item = file.items[i];
        }
        verify(item !== null, "File has an Eject item");
        compare(item.shortcut.toString(), "Ctrl+E");
        compare(item.enabled, false, "nothing to eject");
        fakeWin.canEject = true;
        compare(item.enabled, true);
        item.triggered();
        compare(fakeWin.ejected, 1);
        fakeWin.canEject = false;
    }

    function item(menu: var, text: string): var {
        for (let i = 0; i < menu.items.length; i++) {
            if (menu.items[i].text === text)
                return menu.items[i];
        }
        return null;
    }

    function test_tabAndWindowItems() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        const file = bar.menus[0];
        const view = bar.menus[2];
        const reopen = test.item(file, "Reopen Closed Tab");
        verify(reopen !== null);
        compare(reopen.shortcut.toString(), "Ctrl+Alt+Shift+T");
        compare(reopen.enabled, false, "no closed tab");
        fakeManager.closedTabs = [{url: "file:///sandbox/a"}];
        compare(reopen.enabled, true);
        reopen.triggered();
        compare(fakeManager.reopened, 1);
        fakeManager.closedTabs = [];

        const bar1 = test.item(view, "Show Tab Bar");
        verify(bar1 !== null, "Show Tab Bar while the bar is hidden");
        compare(bar1.shortcut.toString(), "Ctrl+Shift+T");
        fakeWin.tabBarVisible = true;
        verify(test.item(view, "Hide Tab Bar") !== null, "Hide Tab Bar while it shows");
        fakeWin.tabBarVisible = false;

        const merge = test.item(view, "Merge All Windows");
        verify(merge !== null);
        compare(merge.enabled, false, "one window");
        fakeManager.windows = [fakeWin, fakeApp];
        compare(merge.enabled, true);
        merge.triggered();
        compare(fakeManager.merged, 1);
        fakeManager.windows = [fakeWin];
        compare(test.item(view, "Move Tab to New Window").enabled, false, "one tab");
        compare(test.item(file, "Close Window").visible, true, "one tab: Close Window is the Cmd-W item");
    }

    // View > Show/Hide Sidebar, Path Bar and Status Bar (decision F-11: the bars hidden, the sidebar shown by default).
    function test_barItems() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        const view = bar.menus[2];
        const sidebar = test.item(view, "Hide Sidebar");
        verify(sidebar !== null);
        compare(sidebar.shortcut.toString(), "Ctrl+Super+S");
        sidebar.triggered();
        compare(fakeApp.sidebarShown, false);
        verify(test.item(view, "Show Sidebar") !== null);
        fakeApp.sidebarShown = true;

        const path = test.item(view, "Show Path Bar");
        verify(path !== null);
        compare(path.shortcut.toString(), "Ctrl+Alt+P");
        path.triggered();
        compare(fakeApp.pathBarShown, true);
        verify(test.item(view, "Hide Path Bar") !== null);
        fakeApp.pathBarShown = false;

        const status = test.item(view, "Show Status Bar");
        verify(status !== null);
        compare(status.shortcut.toString(), "Ctrl+/");
        status.triggered();
        compare(fakeApp.statusBarShown, true);
        fakeApp.statusBarShown = false;
    }

    // Use Groups and Group By check the tab's grouping (the shown folder's own); Sort By lists the Finder's keys.
    function test_groupByFollowsTheTab() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        const view = bar.menus[2];
        const use = test.item(view, "Use Groups");
        verify(use !== null);
        compare(use.shortcut.toString(), "Ctrl+Super+0");
        compare(use.checked, true, "the tab groups");
        const group = bar.groupMenu;
        const titles = [];
        let checked = "";
        for (let i = 0; i < group.items.length; i++) {
            titles.push(group.items[i].text);
            if (group.items[i].checked)
                checked = group.items[i].text;
        }
        compare(titles, ["None", "Name", "Kind", "Application", "Date Last Opened", "Date Modified", "Date Created", "Size", "Tags"]);
        compare(checked, "Tags");
        const sorts = [];
        for (let i = 0; i < bar.sortMenu.items.length; i++)
            sorts.push(bar.sortMenu.items[i].text);
        compare(sorts.slice(0, 8), ["Name", "Kind", "Application", "Date Last Opened", "Date Modified", "Date Created", "Size", "Tags"]);
    }

    // Sort By checks the tab's arrangement (the shown folder's own), not a global setting.
    function test_sortByFollowsTheTab() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        const sort = bar.sortMenu;
        verify(sort !== null);
        let checked = [];
        for (let i = 0; i < sort.items.length; i++) {
            if (sort.items[i].checked)
                checked.push(sort.items[i].text);
        }
        compare(checked.indexOf("Date Modified") >= 0, true, "the tab sorts by date");
        compare(checked.indexOf("Descending") >= 0, true, "descending");
        compare(checked.indexOf("Name") >= 0, false);
    }

    // An item's name in a label (Edit > Copy “name”, File > Compress “name”) goes through the window's menuName, which shortens
    // a long one in its middle: the menu bar draws the label it is sent as it is (owner report 2026-11-07).
    function test_theNameInALabelIsTheShortenedOne() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        select([3], {});
        compare(bar.firstName, "<item3>");
        select([1, 2], {});
        compare(bar.firstName, "");
        select([], {});
    }
}
