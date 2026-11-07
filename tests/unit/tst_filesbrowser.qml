pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"

// The real Files windows offscreen (Main.qml, BrowserWindow.qml, BrowserTab.qml, InfoWindow.qml, CustomizeFolderWindow.qml,
// GlobalMenu.qml) over a stand-in FilesApp.
// - The window the browser opens for itself (Get Info, Customize Folder) is the key window once it opens: Ctrl+W closes it
//   alone and the browser window stays with its tab (macOS: Cmd+W closes the key window only), with and without the
//   global menu, whose items carry the same keys. Meanwhile none of the browser's keys is live (BrowserWindow.childIsKey).
//   The other way round, the browser the key window with such a window open: its keys act on the browser only.
// - A tab keeps the view a drag started from until the drag has ended (BrowserTab.dragView): the view chosen meanwhile
//   applies once the drag's own handlers have returned.
TestCase {
    id: test
    name: "FilesBrowser"
    when: windowShown

    // FolderModel as the window, the tab and the icon view read it (an empty listing of `url`).
    Component {
        id: folderComponent
        ListModel {
            id: folder
            property url url
            property bool loading: false
            property string error: ""
            property real freeSpace: -1
            property bool isTrash: false
            // The Applications location: the rows are applications, opened by launchApplication.
            property bool isApplications: false
            // FolderModel.chooser: what a panel can take (FilePanel's tab sets it).
            property var chooser: ({})
            property var selected: []
            property bool writable: true
            property bool isSearch: false
            property bool searchLimited: false
            property string filterText: ""
            property int groupBy: 0
            property var groups: []
            property int sortKey: 0
            property bool sortDescending: false
            property bool foldersFirst: true
            property bool showHidden: false
            property int previewSize: 0
            property int largePreviewSize: 0
            property int currentRow: -1
            property int selectedCount: 0
            signal redirected(url url)
            function selectedRows(): var {
                return folder.selected;
            }
            function selectedUrls(): var {
                return folder.selected.map(r => folder.urlAt(r));
            }
            function isSelected(row: int): bool {
                return false;
            }
            function select(row: int, modifiers: int): void {
            }
            function selectAll(): void {
            }
            function clearSelection(): void {
            }
            function selectUrls(urls: var): void {
            }
            function findPrefix(prefix: string, from: int): int {
                return -1;
            }
            function rowForUrl(target: url): int {
                return -1;
            }
            // The rows that are folders.
            property var dirRows: []
            function isDirAt(row: int): bool {
                return folder.dirRows.indexOf(row) >= 0;
            }
            function nameAt(row: int): string {
                return folder.isApplications ? "App " + row : "";
            }
            function urlAt(row: int): url {
                return folder.isApplications ? "grassfield-app:/app" + row : folder.url;
            }
            function expect(target: url, rename: bool): void {
            }
            function expectAlone(target: url): void {
            }
            function reload(): void {
            }
            function requestPreview(row: int, large: bool): void {
            }
            function cancelPreview(target: url, large: bool): void {
            }
            // Get Info of the listed folder itself (row -1), as FolderModel.info() gives it.
            function info(row: int): var {
                return {
                    name: "sandbox", url: folder.url, isDir: true, kind: "Folder", sizeText: "", bytes: 0, where: "/", created: "",
                    modified: "", accessed: "", linkDest: "", owner: "", group: "", permissions: "", writable: true, readable: true,
                    iconName: "folder", thumbnail: ""
                };
            }
        }
    }

    ListModel {
        id: places
        property bool trashEmpty: true
        signal mounted(url url)
        function rowForUrl(target: url): int {
            return -1;
        }
        function eject(row: int): void {
        }
        function mount(row: int): void {
        }
    }

    // What Main.qml and the windows read of FilesApp.
    QtObject {
        id: fakeApp
        // Add to Sidebar (FP-27): what was added, and what the sidebar lists.
        property var sidebarAdded: []
        property var inSidebarUrls: []
        function addToSidebar(urls: var, position: int): void {
            fakeApp.sidebarAdded = fakeApp.sidebarAdded.concat([{urls: urls.map(u => String(u)), position: position}]);
        }
        function inSidebar(target: url): bool {
            return fakeApp.inSidebarUrls.indexOf(String(target)) >= 0;
        }
        property bool dark: false
        property bool reduceMotion: false
        property string accentColor: "multicolor"
        property string shortcutStyle: "pc"
        property string iconMode: "default"
        property string iconTint: "accent"
        property string folderColor: "theme"
        property int windowWidth: 0
        property int windowHeight: 0
        property url newWindowUrl: "file:///sandbox"
        property var initialUrls: []
        property int processId: 4242
        property string viewMode: "icons"
        property int sortKey: 0
        property bool sortDescending: false
        property int recentsSortKey: 5
        property bool foldersFirst: true
        property bool showHidden: false
        property bool sidebarShown: true
        property bool tabBarShown: false
        property bool pathBarShown: false
        property bool statusBarShown: false
        property bool previewPane: false
        property bool galleryInfo: false
        property bool columnPreview: false
        property string titlebarDoubleClick: "zoom"
        property bool canMinimize: true
        property string activity: ""
        property int activityPercent: -1
        property bool canUndo: false
        property bool canRedo: false
        property bool canPaste: false
        // Cut (decision F-18): what reached the clipboard, whether a cut waits for its paste, and Esc's cancels.
        property var clipboardWrites: []
        property bool cutPending: false
        property int cutsCancelled: 0
        function copyToClipboard(urls: var, cut: bool): void {
            fakeApp.clipboardWrites = fakeApp.clipboardWrites.concat([{urls: urls.map(u => String(u)), cut: cut}]);
        }
        function cancelCut(): void {
            fakeApp.cutsCancelled += 1;
            fakeApp.cutPending = false;
        }
        property int clipboardCount: 0
        // Move Item Here and Empty Trash (decision F-6, FP-51): what was asked.
        property var movedHere: []
        property int emptied: 0
        function moveHere(destination: url, folder: var): void {
            fakeApp.movedHere = fakeApp.movedHere.concat([String(destination)]);
        }
        function emptyTrash(): void {
            fakeApp.emptied++;
        }
        // Delete Immediately (FP-52): what was really deleted.
        property var deleted: []
        function deletePermanently(urls: var): void {
            fakeApp.deleted = fakeApp.deleted.concat([urls.map(u => String(u))]);
        }
        property bool devSession: true
        property int tagRevision: 0
        property int folderStyleRevision: 0
        property var colorTagNames: []
        property var hiddenTags: []
        property string homePath: "/sandbox"
        property var places: places
        property var prompts: fakePrompts
        // FilesApp.focusWindow is QGuiApplication::focusWindow(), which QML cannot read: the test sets it wherever it moves
        // the keyboard (test.giveKeys), as the compositor and Qt do in the app.
        property var focusWindow: null
        // The views each folder was given (FilesApp.setFolderView), by url.
        property var folderViews: ({})
        signal prefsChanged
        signal operationFailed(string message)
        // FilesApp's: a drag from another application left a window (Main.qml outsideDrags).
        signal outsideDragEnded(var window, bool dropped)
        function createFolderModel(owner: var): var {
            return folderComponent.createObject(owner);
        }
        function folderView(target: url): var {
            const stored = fakeApp.folderViews[String(target)];
            return stored ? stored : {};
        }
        function setFolderView(target: url, view: var): void {
            const all = Object.assign({}, fakeApp.folderViews);
            all[String(target)] = Object.assign({}, all[String(target)] || {}, view);
            fakeApp.folderViews = all;
        }
        function pathSegments(target: url): var {
            return [{label: "sandbox", url: target}];
        }
        function sameUrl(a: url, b: url): bool {
            return String(a) === String(b);
        }
        // Search, the Go menu and the file commands (ADR-0027, FP-75..FP-79): nothing searched or remembered here.
        property var savedSearches: []
        property var recentFolders: []
        signal folderCompletions(string text, var matches)
        function isFileSearch(target: url): bool {
            return String(target).startsWith("grassfield-search:");
        }
        function searchQuery(target: url): var {
            const t = String(target);
            if (!t.startsWith("grassfield-search:"))
                return {valid: false};
            return {valid: true, text: decodeURIComponent(t.substring(t.indexOf("q=") + 2)), folder: "", criteria: []};
        }
        function searchUrl(query: var): url {
            return "grassfield-search:/?q=" + encodeURIComponent(query.text || "");
        }
        function noteFolder(target: url): void {
        }
        function completeFolder(text: string, base: url): void {
        }
        function completedText(text: string, base: url, match: string): string {
            return text;
        }
        function standardFolder(which: string): url {
            return "";
        }
        function placeShortcut(kind: string, target: url): string {
            return "";
        }
        function linkTarget(target: url): url {
            return "";
        }
        function isRecents(target: url): bool {
            return false;
        }
        function defaultDescending(key: int): bool {
            return false;
        }
        function isDirectChild(parent: url, child: url): bool {
            return false;
        }
        function formatSize(bytes: real): string {
            return String(bytes);
        }
        function rememberWindowSize(width: int, height: int): void {
        }
        function reparent(object: var, parent: var): void {
        }
        function tagsUnavailable(urls: var): string {
            return "";
        }
        function colorTagStates(urls: var): var {
            return [];
        }
        function tagNamesOf(target: url): var {
            return [];
        }
        function folderStyleOf(target: url): var {
            return {color: "", glyph: ""};
        }
        function folderStyleUnavailable(urls: var): string {
            return "";
        }
        function applyFolderStyle(urls: var, color: string, glyph: string): void {
        }
        // Get Info's Sharing & Permissions (ADR-0028): nothing to edit here.
        signal permissionsChanged(url url)
        function permissionsOf(target: url): var {
            return {valid: false};
        }
        property var jobs: []
        function mimeTypeOf(target: url): string {
            return "text/plain";
        }
        function defaultApplication(mimeType: string): string {
            return "";
        }
        function setDefaultApplication(mimeType: string, storageId: string): bool {
            return true;
        }
        function directorySize(target: url, done: var): void {
        }
        // Applications that open the selection (Open With's list).
        property var openWithApps: []
        function applicationsFor(urls: var): var {
            return fakeApp.openWithApps;
        }
        // What opened what (BrowserTab.activate and openSelection): applications start, files open.
        property var launched: []
        property var opened: []
        function launchApplication(target: url): void {
            fakeApp.launched = fakeApp.launched.concat([String(target)]);
        }
        // The Store's answer to `--removable` (JSON text) and what Files asked it to uninstall (ADR-0046).
        // FilesApp.trash: the Applications location refuses it with the permission message (nothing is trashed).
        property var trashRefused: []
        function trash(urls: var): void {
            fakeApp.trashRefused = fakeApp.trashRefused.concat(urls.map(u => String(u)));
        }
        property string removableText: ""
        property int removableLoads: 0
        property var uninstalled: []
        function loadRemovableApplications(): void {
            fakeApp.removableLoads++;
        }
        function uninstallApplication(id: string): void {
            fakeApp.uninstalled = fakeApp.uninstalled.concat([id]);
        }
        function open(urls: var): void {
            fakeApp.opened = fakeApp.opened.concat(urls.map(u => String(u)));
        }
        // Open With > Other… (FilesApp.chooseApplication) and the panels it asks for (FilesApp.applicationChooser, as
        // ApplicationChooser: closed once answered).
        property var chosen: []
        function chooseApplication(urls: var): void {
            fakeApp.chosen = fakeApp.chosen.concat([urls.map(u => String(u))]);
        }
        // Share > Send with LocalSend… (ADR-0045 OC-13): whether LocalSend is installed, and the vectors sent.
        property bool localSendInstalled: true
        property var localSent: []
        function localSendAvailable(): bool {
            return fakeApp.localSendInstalled;
        }
        function sendWithLocalSend(argv: var): void {
            fakeApp.localSent = fakeApp.localSent.concat([argv]);
        }
        property QtObject applicationChooser: QtObject {
            id: fakeChooser
            signal opened(int id, var request)
            signal closed(int id)
            property var answers: []
            function answer(id: int, response: int, answer: var): void {
                fakeChooser.answers = fakeChooser.answers.concat([[id, response, answer.choice ?? ""]]);
                fakeChooser.closed(id);
            }
        }
        function applicationsUrl(): url {
            return "grassfield-apps:/";
        }
        function applicationUrl(id: string): url {
            return "grassfield-app:/" + id;
        }
        function applicationId(target: url): string {
            const s = String(target);
            return s.startsWith("grassfield-app:/") ? s.substring(16) : "";
        }
        function baseNameLength(name: string, isDir: bool): int {
            return name.length;
        }
        function uriList(urls: var): string {
            return "";
        }
    }

    // FilesApp.prompts (src/kioprompts.h): KIO's question on screen, and the replies.
    QtObject {
        id: fakePrompts
        property var current: ({})
        property var replies: []
        function reply(id: int, answer: var): void {
            fakePrompts.replies = fakePrompts.replies.concat([{
                    id: id,
                    button: answer.button
                }]);
            fakePrompts.current = ({});
        }
    }

    Component {
        id: filesComponent
        Main {
            app: fakeApp
        }
    }

    Component {
        id: signalSpy
        SignalSpy {}
    }

    // The one browser window Main opens at start, shown and active.
    function openFiles(globalMenu: bool): var {
        const files = createTemporaryObject(filesComponent, test, {globalMenu: globalMenu});
        verify(files !== null, "Main.qml");
        tryCompare(files.windows, "length", 1);
        const browser = files.windows[0];
        test.giveKeys(browser);
        compare(browser.tabs.length, 1);
        return files;
    }

    // Gives `w` the keyboard (offscreen Qt moves the focus window on requestActivate) and tells the stand-in FilesApp.
    // `active` alone proves nothing: Qt reports a window and its transient children active together.
    function giveKeys(w: var): void {
        w.requestActivate();
        tryVerify(() => w.active, 2000, "the window is active");
        wait(50);
        fakeApp.focusWindow = w;
    }

    // A key as a user types it, into the window that has the keyboard. Not keyClick: QTest sends a click's release to the
    // window its press went to, and a press that closes and deletes that window leaves the release a deleted target.
    function type(key: int, modifiers: int): void {
        keyPress(key, modifiers);
        keyRelease(key, modifiers);
    }

    // The window the browser opened last (Get Info, Customize Folder), once it is the key window.
    function newOwnWindow(browser: var, before: int): var {
        tryVerify(() => browser.ownWindows.length === before + 1, 2000, "the browser opened a window of its own");
        const w = browser.ownWindows[before];
        verify(w.transientParent === browser, "a transient child of the browser");
        // A new window takes the keyboard (the compositor gives it the focus).
        test.giveKeys(w);
        return w;
    }

    // The browser window's own Shortcuts.
    function browserShortcuts(browser: var): var {
        const list = [];
        for (let i = 0; i < browser.data.length; i++) {
            if (browser.data[i] instanceof Shortcut)
                list.push(browser.data[i]);
        }
        return list;
    }

    // The items of the browser's global menu (GlobalMenu.qml) that carry a key; [] without the global menu.
    function menuKeyItems(browser: var): var {
        const list = [];
        const walk = menu => {
            for (let i = 0; i < menu.items.length; i++) {
                const item = menu.items[i];
                if (item.subMenu)
                    walk(item.subMenu);
                else if (item.shortcut !== undefined && String(item.shortcut) !== "")
                    list.push(item);
            }
        };
        for (let i = 0; i < browser.data.length; i++) {
            const loader = browser.data[i];
            if (loader instanceof Loader && loader.item instanceof GlobalMenu) {
                for (let m = 0; m < loader.item.menus.length; m++)
                    walk(loader.item.menus[m]);
            }
        }
        return list;
    }

    // `on`: the browser's keys that depend on nothing else (Ctrl+N, Ctrl+T, Ctrl+W, Ctrl+F: Shortcuts and menu items) are
    // live; otherwise none of its keys is.
    function verifyBrowserKeys(browser: var, globalMenu: bool, on: bool, what: string): void {
        const shortcuts = test.browserShortcuts(browser);
        verify(shortcuts.length >= 40, what + ": the browser's Shortcuts are found (" + shortcuts.length + ")");
        const items = test.menuKeyItems(browser);
        if (globalMenu)
            verify(items.length >= 30, what + ": the global menu's keyed items are found (" + items.length + ")");
        else
            compare(items.length, 0, what + ": no global menu");
        if (on) {
            for (const key of ["Ctrl+N", "Ctrl+T", "Ctrl+W", "Ctrl+F"]) {
                const own = shortcuts.filter(s => s.sequence === key);
                compare(own.length, 1, what + ": the browser's " + key);
                verify(own[0].enabled, what + ": the browser's " + key + " is live");
                const item = items.filter(i => String(i.shortcut) === key);
                compare(item.length, globalMenu ? 1 : 0, what + ": the menu item of " + key);
                verify(item.every(i => i.enabled), what + ": the menu item of " + key + " is live");
            }
            return;
        }
        const live = shortcuts.filter(s => s.enabled).map(s => s.sequence !== "" ? s.sequence : String(s.sequences));
        compare(live, [], what + ": no Shortcut of the browser is live");
        const liveItems = items.filter(i => i.enabled).map(i => String(i.shortcut));
        compare(liveItems, [], what + ": no keyed item of the global menu is live");
    }

    // Opening in the Applications location starts the application (double-click, File > Open, Ctrl+Down) and never hands the
    // virtual url to FilesApp.open; in a folder of files nothing is launched.
    // Search as you type (ADR-0027): the search location comes once typing rests, a refinement replaces it in the history,
    // and emptying the field goes back to the folder the search started from.
    function test_searchAsYouType() {
        const files = test.openFiles(false);
        const tab = files.windows[0].tab;
        const start = String(tab.url);
        const depth = tab.history.length;
        tab.setSearch("aq");
        compare(String(tab.url), start, "nothing until typing rests");
        tryCompare(tab, "fileSearch", true, 2000);
        compare(tab.searchText, "aq");
        compare(String(tab.searchOrigin), start, "the folder it started from");
        compare(tab.history.length, depth + 1, "one entry for the search");
        tab.setSearch("aqua");
        tryVerify(() => String(tab.url).endsWith("q=aqua"), 2000, "refined in place");
        compare(tab.history.length, depth + 1, "no new entry per refinement");
        compare(tab.searchText, "aqua", "the field keeps what was typed");
        tab.setSearch("");
        compare(String(tab.url), start, "emptied: back to the folder");
        verify(!tab.fileSearch);
        compare(tab.history.length, depth, "the search left the history");
        compare(tab.searchText, "");
    }

    // UI audit 2026-11-05 U11: in a narrow window an open search never covers back and forward; Tags and Action yield first.
    function test_narrowSearchKeepsBackAndForward() {
        const files = test.openFiles(false);
        const browser = files.windows[0];
        const tab = browser.tab;
        const find = (item, pred) => {
            if (pred(item))
                return item;
            for (const c of item.children) {
                const r = find(c, pred);
                if (r)
                    return r;
            }
            return null;
        };
        const field = find(browser.contentItem, i => i.expandedWidth !== undefined && i.tab !== undefined);
        const nav = find(browser.contentItem, i => i.Accessible.name === "Navigation" && i.tab !== undefined);
        verify(field && nav);
        browser.width = Tokens.filesWindowMinWidth;
        tab.setSearch("aq");
        tryCompare(tab, "fileSearch", true, 2000);
        tryVerify(() => field.expanded);
        verify(!browser.toolbarTagsShown, "Tags and Action yield first");
        verify(field.width >= Tokens.filesSearchMinWidth);
        const navRight = nav.mapToItem(browser.contentItem, nav.width, 0).x;
        verify(field.mapToItem(browser.contentItem, 0, 0).x >= navRight, "the field starts right of back and forward");
        verify(field.mapToItem(browser.contentItem, field.width, 0).x <= browser.width, "and ends inside the window");
        browser.width = Tokens.filesWindowWidth;
        tryVerify(() => browser.toolbarTagsShown, 1000, "wide: Tags and Action back");
        tab.setSearch("");
    }

    // Cut (owner request 2026-11-07, decision F-18, over the Finder's F-6): Cut before Copy in the item menu, Ctrl+X, and Esc
    // cancels a cut not pasted yet before it clears the selection. The Finder's way stays: in the folder's menu Paste turns
    // into Move Item Here while Alt is held (its Option alternate). Empty Trash is never offered in a dev session (ADR-0011),
    // whatever asks for it.
    function test_cutAndMoveItemHere() {
        const files = test.openFiles(false);
        const tab = files.windows[0].tab;
        const folder = tab.folder;
        folder.selected = [0];
        folder.selectedCount = 1;
        const items = tab.itemMenu(folder);
        const ids = items.map(i => i.id ?? "-");
        const cut = items.find(i => i.id === "cut");
        verify(cut !== undefined, "Cut for files");
        compare(cut.shortcut, "Ctrl+X");
        verify(cut.enabled, "in a writable folder");
        compare(ids.indexOf("copy"), ids.indexOf("cut") + 1, "right before Copy");
        fakeApp.clipboardWrites = [];
        tab.runAction("cut", folder);
        compare(fakeApp.clipboardWrites, [{urls: [String(folder.urlAt(0))], cut: true}]);
        keyClick(Qt.Key_X, Qt.ControlModifier);
        compare(fakeApp.clipboardWrites.length, 2, "Ctrl+X cuts");
        verify(fakeApp.clipboardWrites[1].cut);
        // Esc cancels the cut first.
        fakeApp.cutPending = true;
        fakeApp.cutsCancelled = 0;
        tab.focusView();
        keyClick(Qt.Key_Escape);
        compare(fakeApp.cutsCancelled, 1, "Esc cancels the cut");
        const copy = items.find(i => i.id === "copy");
        compare(copy.alternate.id, "copyPath", "Copy as Pathname is Copy's Alt alternate (the Finder's Option item)");
        verify(!items.some(i => i.id === "copyPath"), "not a row of its own");
        fakeApp.canPaste = true;
        fakeApp.clipboardCount = 2;
        const background = tab.backgroundMenu(folder);
        verify(!background.some(i => i.id === "moveHere"), "Move Item Here is no row of its own");
        const paste = background.find(i => i.id === "paste");
        compare(paste.text, "Paste 2 Items");
        const move = paste.alternate;
        verify(move !== undefined, "Move Item Here is Paste's Alt alternate (the Finder's Option item)");
        compare(move.id, "moveHere");
        compare(move.text, "Move 2 Items Here");
        compare(move.shortcut, "Ctrl+Alt+V");
        fakeApp.movedHere = [];
        tab.runAction("moveHere", folder);
        compare(fakeApp.movedHere, [String(folder.url)]);
        fakeApp.canPaste = false;
        fakeApp.clipboardCount = 0;
        folder.selected = [];

        verify(fakeApp.devSession);
        fakeApp.emptied = 0;
        tab.emptyTrash();
        compare(fakeApp.emptied, 0, "a dev session never empties a trash");
    }

    // Delete Immediately (⌥⌘⌫, FP-52) asks first, in a destructive sheet that says it can't be undone, and deletes only on the
    // answer (review of PR #98, mutant M7: the deletion without the question).
    function test_deleteImmediatelyAsksBeforeDeleting() {
        const files = test.openFiles(false);
        const browser = files.windows[0];
        const tab = browser.tab;
        const folder = tab.folder;
        fakeApp.deleted = [];
        folder.selected = [0, 1];
        tab.deleteImmediately();
        compare(fakeApp.deleted, [], "nothing is deleted before the answer");
        const sheet = test.shownSheet(browser.contentItem);
        verify(sheet !== null, "a sheet asks");
        verify(sheet.destructive, "a destructive sheet");
        verify(sheet.message.indexOf("immediately") >= 0, sheet.message);
        verify(sheet.message.indexOf("can’t undo") >= 0, "it says it cannot be undone: " + sheet.message);
        sheet.cancel();
        compare(fakeApp.deleted, [], "Cancel deletes nothing");
        tab.deleteImmediately();
        const again = test.shownSheet(browser.contentItem);
        verify(again !== null);
        compare(fakeApp.deleted, []);
        again.confirm();
        compare(fakeApp.deleted.length, 1, "the answer deletes");
        compare(fakeApp.deleted[0].length, 2, "the selection, once");
        // Nothing selected: nothing asked, nothing deleted.
        folder.selected = [];
        tab.deleteImmediately();
        compare(test.shownSheet(browser.contentItem), null);
        compare(fakeApp.deleted.length, 1);
    }

    function shownSheet(item: var): var {
        if (item instanceof Sheet && item.shown)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const found = test.shownSheet(item.children[i]);
            if (found)
                return found;
        }
        return null;
    }

    function test_applicationsLaunchAndFilesOpen() {
        const files = test.openFiles(false);
        const tab = files.windows[0].tab;
        const folder = tab.folder;
        fakeApp.launched = [];
        fakeApp.opened = [];
        folder.isApplications = true;
        tab.activate(2, folder, 0);
        compare(fakeApp.launched, ["grassfield-app:/app2"], "a double-click starts the application");
        compare(fakeApp.opened, [], "never opened as a file");
        folder.selected = [0, 1];
        tab.openSelection();
        compare(fakeApp.launched, ["grassfield-app:/app2", "grassfield-app:/app0", "grassfield-app:/app1"], "File > Open starts each");
        compare(fakeApp.opened, []);
        folder.selected = [];
        for (let i = 0; i < 12; i++)
            folder.selected = folder.selected.concat([i]);
        fakeApp.launched = [];
        tab.openSelection();
        compare(fakeApp.launched.length, 10, "at most ten at once");
        folder.isApplications = false;
        folder.selected = [3];
        fakeApp.launched = [];
        tab.openSelection();
        compare(fakeApp.launched, [], "a folder of files launches nothing");
        compare(fakeApp.opened, [String(folder.url)], "the file is opened");
    }

    // Move to Trash on an application (ADR-0046; Finder: moving an app out of Applications uninstalls it): dimmed until the
    // Store says it may remove that app, then Files only hands the app to the Store (its own alert is the one confirmation:
    // Files shows none and removes nothing itself).
    function test_applicationsMoveToTrashUninstalls() {
        const files = test.openFiles(false);
        const win = files.windows[0];
        const tab = win.tab;
        const folder = tab.folder;
        folder.isApplications = true;
        folder.selected = [0];
        folder.selectedCount = 1;
        fakeApp.removableText = "";
        fakeApp.uninstalled = [];
        const trash = () => tab.itemMenu(folder).find(i => i.id === "trash");
        compare(trash().enabled, false, "the Store has not answered: nothing is offered");
        tab.trashSelection();
        compare(fakeApp.uninstalled, [], "nothing is handed over while the Store has not said so");
        fakeApp.removableText = JSON.stringify({version: 1, entries: {"app0.desktop": {app: "x", name: "App 0", block: ""},
                                                                     "app1.desktop": {app: "y", name: "App 1", block: "omarchy"}}});
        compare(trash().enabled, true, "the Store may remove it");
        tab.trashSelection();
        compare(test.shownSheet(win.contentItem), null, "Files shows no alert of its own");
        compare(fakeApp.uninstalled, ["app0"], "the Store is asked for that application, and only asked");
        // An app the Store refuses (Omarchy's own), several, or none selected: dimmed and nothing handed over.
        folder.selected = [1];
        compare(trash().enabled, false, "part of Omarchy");
        tab.trashSelection();
        compare(fakeApp.uninstalled, ["app0"]);
        folder.selected = [0, 1];
        folder.selectedCount = 2;
        compare(trash().enabled, false, "several apps at once are not offered");
        folder.selected = [];
        folder.selectedCount = 0;
        folder.isApplications = false;
    }

    // Open With (ADR-0035 5c-1): Finder's submenu, the type's applications then Other…, which asks for the Choose Application
    // panel; with no application for the type, Other… alone. Not for a folder.
    function test_openWithOther() {
        const files = test.openFiles(false);
        const tab = files.windows[0].tab;
        const folder = tab.folder;
        folder.isApplications = false;
        folder.selected = [0];
        const openWith = tab.itemMenu(folder).find(i => i.id === "openWith");
        verify(openWith.enabled !== false, "Open With for a file");
        compare(openWith.submenu.map(i => i.id ?? (i.separator ? "-" : "")), ["openWithOther"], "no application for the type: Other… alone");
        compare(openWith.submenu[0].text, "Other…");
        fakeApp.chosen = [];
        tab.runAction("openWithOther", folder);
        compare(fakeApp.chosen, [[String(folder.url)]], "the selection's Choose Application");
        fakeApp.openWithApps = [{id: "org.example.Editor.desktop", name: "Editor"}];
        const listed = tab.itemMenu(folder).find(i => i.id === "openWith");
        compare(listed.submenu.map(i => i.id ?? (i.separator ? "-" : "")), ["app:org.example.Editor.desktop", "-", "openWithOther"], "the type's applications, then Other…");
        fakeApp.openWithApps = [];
        folder.selected = [];
    }

    // Share > Send with LocalSend… (ADR-0045 OC-13): with LocalSend installed the item menu has Share… (after Copy, where
    // Finder 13 and later puts it), which opens the toolbar Share button's menu where the item menu was; its first item sends
    // the local selection with Omarchy's invocation; the Applications location sends nothing; without LocalSend there is no
    // Share at all.
    function test_shareSendsWithLocalSend() {
        const files = test.openFiles(false);
        const browser = files.windows[0];
        const tab = browser.tab;
        const folder = tab.folder;
        folder.isApplications = false;
        folder.selected = [0];
        fakeApp.localSendInstalled = true;
        // A real session first: the stand-in is a development session by default.
        fakeApp.devSession = false;
        const items = tab.itemMenu(folder);
        const ids = items.map(i => i.id ?? "-");
        const share = items.find(i => i.id === "share");
        verify(share !== undefined, "Share…");
        verify(ids.indexOf("share") === ids.indexOf("copy") + 1, "right after Copy (and its Alt alternate, Copy as Pathname)");
        compare(share.text, "Share…");
        compare(share.submenu, undefined, "no submenu: it opens the Share menu");
        const menu = tab.shareMenu(folder);
        compare(menu[0].id, "localsend", "LocalSend first");
        compare(menu[0].text, "Send with LocalSend…");
        verify(menu[0].enabled, "enabled for a local file");
        // The item menu at a point, then Share… from it: the Share menu opens at the same point, its choice sends.
        tab.contextMenu(folder, 0, 120, 90, false);
        verify(browser.menuLayer.visible, "the item menu is open");
        const handler = browser.menuLayer.handler;
        browser.menuLayer.close();
        handler("share");
        verify(browser.menuLayer.visible, "Share… opens the Share menu");
        compare(browser.menuLayer.anchorX, 120, "where the item menu was");
        compare(browser.menuLayer.anchorY, 90);
        fakeApp.localSent = [];
        const shareHandler = browser.menuLayer.handler;
        browser.menuLayer.close();
        shareHandler("localsend");
        compare(fakeApp.localSent.length, 1, "one send");
        compare(fakeApp.localSent[0], ["systemd-run", "--user", "--quiet", "--collect", "localsend", "--headless", "send", "/sandbox"]);
        verify(browser.shareShown, "the toolbar's Share button shows");
        folder.isApplications = true;
        compare(tab.shareMenu(folder)[0].enabled, false, "dimmed in Applications");
        fakeApp.localSent = [];
        tab.runAction("localsend", folder);
        compare(fakeApp.localSent, [], "nothing sent from Applications");
        folder.isApplications = false;
        // A development session (security review LOW 2): the item is there, dimmed; a send is refused in the banner and
        // FilesApp is never asked (systemd-run --user would open LocalSend on the owner's real desktop).
        fakeApp.devSession = true;
        compare(tab.shareMenu(folder)[0].enabled, false, "dimmed in a development session");
        verify(tab.itemMenu(folder).find(i => i.id === "share") !== undefined, "Share… still shown");
        browser.bannerText = "";
        tab.runAction("localsend", folder);
        compare(fakeApp.localSent, [], "nothing sent from a development session");
        verify(browser.bannerText.indexOf("development session") >= 0, browser.bannerText);
        fakeApp.localSendInstalled = false;
        verify(tab.itemMenu(folder).find(i => i.id === "share") === undefined, "nothing to share with: no Share");
        compare(tab.shareMenu(folder), [], "and an empty Share menu");
        fakeApp.localSendInstalled = true;
        folder.selected = [];
    }

    // Files' own Choose Application panel (ADR-0035 5c-1, 5c-2): modal over the window the user worked in, never answered
    // by itself; Cancel answers 1 and the panel goes, and the window it was over gets back what follows (errors, KIO's
    // questions). A request that ends (its job went) takes its panel away.
    function test_chooseApplicationPanel() {
        const files = test.openFiles(false);
        const browser = files.windows[0];
        fakeChooser.answers = [];
        const request = {
            kind: "application",
            appId: "",
            title: "",
            acceptLabel: "",
            modal: true,
            parented: true,
            multiple: false,
            directory: false,
            filters: [],
            currentFilter: -1,
            choices: [],
            currentName: "",
            files: [],
            currentFolder: "",
            applications: ["app1"],
            lastChoice: "",
            filename: "notes.txt",
            uri: "",
            count: 1
        };
        fakeChooser.opened(7, request);
        const entry = files.applicationPanels[7];
        verify(entry !== undefined, "a panel for the request");
        const panel = entry.panel;
        compare(entry.over, browser);
        verify(panel.transientParent === browser, "over the browser window");
        compare(panel.modality, Qt.WindowModal);
        compare(panel.title, "Choose Application");
        compare(panel.message, "Choose an application to open the document “notes.txt”.");
        tryVerify(() => panel.visible, 1000);
        verify(waitForRendering(panel.contentItem, 2000));
        wait(100);
        compare(fakeChooser.answers, [], "Files' panels have no test answer: nothing answered by itself");
        test.giveKeys(panel);
        compare(files.lastActiveWindow, panel);
        panel.cancel();
        compare(fakeChooser.answers, [[7, 1, ""]]);
        compare(files.applicationPanels[7], undefined, "the panel went");
        compare(files.lastActiveWindow, browser, "errors show in the window it was over");

        // While a panel is the window worked in, an error shows in the window under it (review of step 5c, MINOR 1).
        fakeChooser.opened(9, request);
        const over = files.applicationPanels[9].panel;
        tryVerify(() => over.visible, 1000);
        test.giveKeys(over);
        compare(files.lastActiveWindow, over);
        // The keyboard given back to the browser window goes on to the panel over it (integrator nested pass of step 5c, NIT).
        test.giveKeys(browser);
        tryCompare(files, "lastActiveWindow", over, 2000, "the panel has the keyboard again");
        browser.bannerText = "";
        fakeApp.operationFailed("The application is no longer installed.");
        compare(browser.bannerText, "The application is no longer installed.");
        // The same with another application's window in front: the browser window is no longer active (while the panel
        // was, Qt counted it active as the panel's transient parent), and the panel stays the window worked in.
        const elsewhere = createTemporaryQmlObject("import QtQuick; Window { width: 120; height: 80; visible: true }", test);
        test.giveKeys(elsewhere);
        verify(!browser.active, "the browser window is not active");
        compare(files.lastActiveWindow, over);
        browser.bannerText = "";
        fakeApp.operationFailed("The document could not be opened.");
        compare(browser.bannerText, "The document could not be opened.");
        elsewhere.visible = false;
        // A panel asked for while a panel is the window worked in opens over the browser window under it.
        fakeChooser.opened(12, request);
        compare(files.applicationPanels[12].over, browser);
        fakeChooser.closed(12);
        test.giveKeys(over);
        // KIO's question asked meanwhile shows in the panel; when the panel goes, it moves to the window under it.
        fakePrompts.current = {
            id: 21,
            kind: "notice",
            title: "A notice",
            text: "Shown in the panel"
        };
        compare(files.promptWindow, over);
        fakeChooser.closed(9);
        compare(files.promptWindow, browser, "the question moves to the window under the panel");
        fakePrompts.current = ({});
        files.placePrompt();

        fakeChooser.opened(8, Object.assign({}, request, {
            filename: "",
            count: 3
        }));
        compare(files.applicationPanels[8].panel.message, "Choose an application to open the 3 selected documents.");
        fakeChooser.closed(8);
        compare(files.applicationPanels[8], undefined, "its request ended: the panel went");
        compare(fakeChooser.answers.length, 1);

        // A window that closes cancels the panels over it (Close All); with no browser window, nothing is asked.
        fakeChooser.opened(10, request);
        verify(files.applicationPanels[10] !== undefined);
        browser.close();
        tryCompare(files.windows, "length", 0);
        compare(fakeChooser.answers[fakeChooser.answers.length - 1], [10, 1, ""], "cancelled with its window");
        compare(files.applicationPanels[10], undefined);
        fakeChooser.opened(11, request);
        compare(fakeChooser.answers[fakeChooser.answers.length - 1], [11, 1, ""], "no window: Cancel");
        compare(files.applicationPanels[11], undefined);
    }

    function test_closeInfoKeepsTheBrowser_data() {
        return [
            {tag: "without the global menu, Ctrl+W", globalMenu: false, key: Qt.Key_W, modifiers: Qt.ControlModifier},
            {tag: "without the global menu, Escape", globalMenu: false, key: Qt.Key_Escape, modifiers: Qt.NoModifier},
            {tag: "with the global menu, Ctrl+W", globalMenu: true, key: Qt.Key_W, modifiers: Qt.ControlModifier},
            {tag: "with the global menu, Escape", globalMenu: true, key: Qt.Key_Escape, modifiers: Qt.NoModifier}
        ];
    }

    // Get Info opened with Ctrl+I (BrowserTab.getInfo -> BrowserWindow.showInfo) is the key window: Ctrl+W (or Escape)
    // closes it alone; the browser window stays open with its tab, and its keys are live again.
    function test_closeInfoKeepsTheBrowser(data) {
        const files = test.openFiles(data.globalMenu);
        const browser = files.windows[0];
        test.verifyBrowserKeys(browser, data.globalMenu, true, "the browser is the key window");
        test.type(Qt.Key_I, Qt.ControlModifier);
        const info = test.newOwnWindow(browser, 0);
        verify(info instanceof InfoWindow);
        verify(browser.childIsKey);
        test.verifyBrowserKeys(browser, data.globalMenu, false, "Get Info is the key window");
        const closed = signalSpy.createObject(test, {target: info, signalName: "closing"});
        test.type(data.key, data.modifiers);
        compare(closed.count, 1, "the key closes Get Info");
        tryCompare(browser.ownWindows, "length", 0);
        wait(50);
        compare(files.windows.length, 1, "the browser window is still open");
        verify(files.windows[0] === browser);
        verify(browser.visible, "and shown");
        compare(browser.tabs.length, 1, "with its tab");
        compare(files.closedTabs.length, 0, "no tab was closed");
        verify(!browser.childIsKey);
        test.verifyBrowserKeys(browser, data.globalMenu, true, "Get Info closed");
        // The browser's own Ctrl+W, once it has the keyboard again: its only tab closes the window. (Not with the global
        // menu: a Qt.labs.platform item with a key, destroyed with its window, can leave a dangling entry in Qt's shortcut
        // map that a later press of that key in this process reaches.)
        if (data.globalMenu)
            return;
        test.giveKeys(browser);
        test.type(Qt.Key_W, Qt.ControlModifier);
        tryCompare(files.windows, "length", 0, 2000, "the browser's Ctrl+W closes the browser");
    }

    function test_browserKeysWhileGetInfoIsOpen_data() {
        return [
            {tag: "without the global menu", globalMenu: false},
            {tag: "with the global menu", globalMenu: true}
        ];
    }

    // Get Info open, the browser the key window again: the browser's keys are its own (Qt reports Get Info active too, as a
    // transient child of the key window). Escape leaves Get Info open, Ctrl+T opens tabs, every Ctrl+W closes a browser
    // tab (none goes to Get Info), the menu items are live; back in Get Info, Ctrl+W closes it alone.
    function test_browserKeysWhileGetInfoIsOpen(data) {
        const files = test.openFiles(data.globalMenu);
        const browser = files.windows[0];
        test.type(Qt.Key_I, Qt.ControlModifier);
        const info = test.newOwnWindow(browser, 0);
        const closed = signalSpy.createObject(test, {target: info, signalName: "closing"});
        test.giveKeys(browser);
        verify(info.active, "Qt still reports Get Info active (its transient parent has the keyboard)");
        verify(!browser.childIsKey, "the browser is the key window");
        test.verifyBrowserKeys(browser, data.globalMenu, true, "the browser is the key window, Get Info open");
        test.type(Qt.Key_Escape, Qt.NoModifier);
        compare(closed.count, 0, "Escape typed in the browser leaves Get Info open");
        test.type(Qt.Key_T, Qt.ControlModifier);
        test.type(Qt.Key_T, Qt.ControlModifier);
        tryCompare(browser.tabs, "length", 3, 2000, "Ctrl+T opens a tab each time");
        test.type(Qt.Key_W, Qt.ControlModifier);
        test.type(Qt.Key_W, Qt.ControlModifier);
        tryCompare(browser.tabs, "length", 1, 2000, "each Ctrl+W closes a tab of the browser");
        compare(closed.count, 0, "Get Info is still open");
        compare(browser.ownWindows.length, 1);
        compare(files.windows.length, 1);
        // Back in Get Info: Ctrl+W closes it alone.
        test.giveKeys(info);
        verify(browser.childIsKey);
        test.type(Qt.Key_W, Qt.ControlModifier);
        compare(closed.count, 1, "Ctrl+W typed in Get Info closes it");
        compare(browser.tabs.length, 1, "the browser keeps its tab");
        compare(files.windows.length, 1);
    }

    // The same for Customize Folder: Ctrl+W typed in the browser closes a browser tab, typed in Customize Folder that window.
    function test_browserKeysWhileCustomizeIsOpen() {
        const files = test.openFiles(false);
        const browser = files.windows[0];
        browser.customizeFolders(["file:///sandbox/Folder"], "Folder", "folder");
        const customize = test.newOwnWindow(browser, 0);
        const closed = signalSpy.createObject(test, {target: customize, signalName: "closing"});
        test.giveKeys(browser);
        test.verifyBrowserKeys(browser, false, true, "the browser is the key window, Customize Folder open");
        test.type(Qt.Key_T, Qt.ControlModifier);
        test.type(Qt.Key_T, Qt.ControlModifier);
        tryCompare(browser.tabs, "length", 3, 2000, "Ctrl+T opens a tab each time");
        // Two presses: Qt hands an ambiguous key to each matching Shortcut in turn, so one live Shortcut of Customize Folder
        // would take every second press.
        test.type(Qt.Key_W, Qt.ControlModifier);
        test.type(Qt.Key_W, Qt.ControlModifier);
        tryCompare(browser.tabs, "length", 1, 2000, "each Ctrl+W closes a tab of the browser");
        compare(closed.count, 0, "Customize Folder is still open");
        test.giveKeys(customize);
        test.type(Qt.Key_W, Qt.ControlModifier);
        compare(closed.count, 1, "Ctrl+W typed in Customize Folder closes it");
        compare(browser.tabs.length, 1);
        compare(files.windows.length, 1);
    }

    // Customize Folder (a window of the browser too): Ctrl+W closes it alone.
    function test_closeCustomizeKeepsTheBrowser() {
        const files = test.openFiles(false);
        const browser = files.windows[0];
        browser.customizeFolders(["file:///sandbox/Folder"], "Folder", "folder");
        const customize = test.newOwnWindow(browser, 0);
        verify(customize instanceof CustomizeFolderWindow);
        test.verifyBrowserKeys(browser, false, false, "Customize Folder is the key window");
        const closed = signalSpy.createObject(test, {target: customize, signalName: "closing"});
        test.type(Qt.Key_W, Qt.ControlModifier);
        compare(closed.count, 1, "Ctrl+W closes Customize Folder");
        tryCompare(browser.ownWindows, "length", 0);
        wait(50);
        compare(files.windows.length, 1, "the browser window is still open");
        compare(browser.tabs.length, 1, "with its tab");
        test.verifyBrowserKeys(browser, false, true, "Customize Folder closed");
    }

    // Every overlay of the window stacks above the floating sidebar (z 1) and the lights' toolbar (z 2), which are siblings of
    // theirs: the KIO sheet's wrapper (its sheet and blocker only order inside it), the window's own sheets with their
    // blockers, Go to Folder and the menu layer. What lives inside the content item (views, banners, rename editors, the
    // preview pane) is below the sidebar by design: it never reaches the panel. Drags are the system's (no QML ghost).
    function test_overlaysStackAboveTheFloatingSidebar() {
        const files = test.openFiles(false);
        const browser = files.windows[0];
        const root = browser.contentItem;
        let sidebar = null, toolbar = null;
        const overlays = [];
        for (let i = 0; i < root.children.length; i++) {
            const c = root.children[i];
            if (c instanceof Sidebar)
                sidebar = c;
            else if (c.contentStart !== undefined && c.controls !== undefined && c.showControls === true && c.showTitle === false)
                toolbar = c;
            else if (c instanceof KioSheets || c instanceof Sheet || c instanceof GoToFolderPanel || c instanceof MenuLayer)
                overlays.push(c);
        }
        verify(sidebar !== null, "the sidebar");
        verify(toolbar !== null, "the lights' toolbar");
        verify(overlays.some(o => o instanceof KioSheets), "the KIO sheets' wrapper is a child of the window");
        verify(overlays.filter(o => o instanceof Sheet).length >= 4, "the window's sheets");
        verify(toolbar.z > sidebar.z, "the lights over the panel");
        for (const o of overlays)
            verify(o.z > toolbar.z, String(o) + " z " + o.z + " must be above the toolbar " + toolbar.z + " and the sidebar " + sidebar.z);
        // The KIO sheet's own modal blocker is inside its wrapper, so the wrapper's z decides.
        const kio = overlays.find(o => o instanceof KioSheets);
        verify(kio.z > sidebar.z && kio.z >= overlays.filter(o => o instanceof Sheet)[0].z, "the KIO sheet stacks with the other sheets");
    }

    // The sheet of `browser`'s KioSheets (KIO's questions).
    function kioSheet(browser: var): var {
        const walk = item => {
            if (item instanceof KioSheets) {
                for (let i = 0; i < item.children.length; i++) {
                    if (item.children[i] instanceof Sheet)
                        return item.children[i];
                }
            }
            for (let i = 0; i < item.children.length; i++) {
                const found = walk(item.children[i]);
                if (found)
                    return found;
            }
            return null;
        };
        return walk(browser.contentItem);
    }

    // KIO's question (Main.qml placePrompt, KioSheets.qml) shows in the window the user last worked in, stays there when
    // another window becomes the key window, and moves to another window when its own closes; Return answers it there.
    function test_kioQuestionWindow() {
        fakePrompts.current = ({});
        fakePrompts.replies = [];
        const files = test.openFiles(false);
        const first = files.windows[0];
        const second = files.newWindow("file:///sandbox", null);
        tryCompare(files.windows, "length", 2);
        test.giveKeys(second);
        compare(files.lastActiveWindow, second);

        fakePrompts.current = {
            id: 5,
            kind: "notice",
            title: "“Tool” wasn’t opened.",
            text: "Files doesn’t run programs."
        };
        compare(files.promptWindow, second, "the window last worked in");
        tryVerify(() => test.kioSheet(second).visible, 1000, "its sheet shows the question");
        verify(!test.kioSheet(first).visible, "the other window shows nothing");
        compare(test.kioSheet(second).title, "“Tool” wasn’t opened.");

        test.giveKeys(first);
        compare(files.promptWindow, second, "the question stays where it is");
        verify(!test.kioSheet(first).visible);

        second.close();
        tryCompare(files.windows, "length", 1);
        compare(files.promptWindow, first, "its window closed: the question moves");
        tryVerify(() => test.kioSheet(first).visible, 1000);
        tryVerify(() => !test.kioSheet(first).holdInput, 2000);
        test.giveKeys(first);
        verify(waitForPolish(first, 1000));
        test.type(Qt.Key_Return, Qt.NoModifier);
        compare(fakePrompts.replies, [{id: 5, button: "ok"}]);
        verify(!test.kioSheet(first).visible);
        compare(files.promptWindow, null);
    }

    // With no browser window left, a question gets its safe answer at once ("stop": Stop, Cancel, Don't Delete).
    function test_kioQuestionWithNoWindow() {
        fakePrompts.current = ({});
        fakePrompts.replies = [];
        const files = test.openFiles(false);
        files.windows[0].close();
        tryCompare(files.windows, "length", 0);
        fakePrompts.current = {
            id: 9,
            kind: "conflict",
            name: "a.txt",
            folder: "dest",
            mode: "copy",
            merge: false,
            replace: true,
            keepBoth: true,
            skip: false,
            applyToAll: false
        };
        compare(fakePrompts.replies, [{id: 9, button: "stop"}]);
        compare(files.promptWindow, null);
    }

    // One sheet at a time in a window (AppKit queues them): KIO's question waits while Go to Folder is open, out of sight and
    // out of the keyboard's reach, and shows once it closes.
    function test_kioQuestionWaitsForTheWindowsSheet() {
        fakePrompts.current = ({});
        fakePrompts.replies = [];
        const files = test.openFiles(false);
        const browser = files.windows[0];
        browser.goToFolder();
        verify(waitForPolish(browser, 1000));
        fakePrompts.current = {
            id: 6,
            kind: "notice",
            title: "“Tool” wasn’t opened.",
            text: "Files doesn’t run programs."
        };
        compare(files.promptWindow, browser);
        wait(50);
        verify(!test.kioSheet(browser).visible, "behind Go to Folder: not shown");
        compare(fakePrompts.replies, []);
        // Esc closes Go to Folder (the keyboard is still its own), then the question shows.
        test.type(Qt.Key_Escape, Qt.NoModifier);
        tryVerify(() => test.kioSheet(browser).visible, 1000, "Go to Folder closed: the question shows");
        tryVerify(() => !test.kioSheet(browser).holdInput, 2000);
        verify(waitForPolish(browser, 1000));
        test.type(Qt.Key_Return, Qt.NoModifier);
        compare(fakePrompts.replies, [{id: 6, button: "ok"}]);
    }

    // A menu open by the keyboard holds the question too (AppKit holds sheets during menu tracking): Return and Esc stay
    // the menu's. Once the question shows, a view that takes the keyboard a moment later gives it back to the sheet.
    function test_kioQuestionWaitsForTheMenu() {
        fakePrompts.current = ({});
        fakePrompts.replies = [];
        const files = test.openFiles(false);
        const browser = files.windows[0];
        let chosen = "";
        browser.menuLayer.open([{id: "one", text: "One"}, {id: "two", text: "Two"}], 20, 20, id => chosen = id, browser.tab.view, true);
        verify(browser.menuLayer.visible);
        fakePrompts.current = {
            id: 7,
            kind: "notice",
            title: "“Tool” wasn’t opened.",
            text: "Files doesn’t run programs."
        };
        wait(50);
        verify(!test.kioSheet(browser).visible, "behind the menu: not shown");
        test.type(Qt.Key_Escape, Qt.NoModifier);
        verify(!browser.menuLayer.visible, "Esc closed the menu");
        compare(fakePrompts.replies, [], "Esc was the menu's");
        tryVerify(() => test.kioSheet(browser).visible, 1000, "the menu closed: the question shows");
        tryVerify(() => !test.kioSheet(browser).holdInput, 2000);
        // The view takes the keyboard after the sheet opened (BrowserTab.focusView, queued by a navigation): the sheet
        // takes it back.
        browser.tab.focusView();
        wait(50);
        verify(waitForPolish(browser, 1000));
        test.type(Qt.Key_Return, Qt.NoModifier);
        compare(fakePrompts.replies, [{id: 7, button: "ok"}]);
        compare(chosen, "");
    }

    // BrowserTab.dragView: while a system drag started from the tab's view runs, that view stays (Qt Quick uses the item
    // that started the drag after QDrag::exec returns); a view chosen meanwhile applies once the drag has ended and its
    // own handlers have returned (Qt.callLater from dragFinished).
    function test_dragKeepsItsView() {
        const files = test.openFiles(false);
        const tab = files.windows[0].tab;
        compare(tab.viewMode, "icons");
        tryVerify(() => tab.view !== null && String(tab.view).startsWith("IconView"), 2000, "the icon view");
        const started = tab.view;
        tab.dragStarted();
        tab.setViewMode("list");
        compare(tab.viewMode, "list", "the tab's mode follows the choice");
        verify(tab.view === started, "the icon view stays while the drag runs");
        wait(50);
        verify(tab.view === started, "and after the event loop ran");
        tab.dragFinished(Qt.CopyAction);
        verify(tab.view === started, "the drag's own handler returns before the view goes");
        tryVerify(() => tab.view !== started && String(tab.view).startsWith("FileList"), 2000, "then the list view applies");
        // Without a drag, a choice applies at once.
        tab.setViewMode("icons");
        verify(String(tab.view).startsWith("IconView"), "no drag: the view follows at once");
    }

    // Add to Sidebar (FP-27; owner report 2026-11-07, "there is no way to pin a folder in the sidebar"): the item menu of
    // folders and File > Add to Sidebar (Ctrl+Super+T) add the selected folders, or the shown folder when nothing is selected;
    // the item is dimmed when they are all in the sidebar already, and a file has none.
    function test_addToSidebar() {
        const files = test.openFiles(false);
        const tab = files.windows[0].tab;
        const folder = tab.folder;
        fakeApp.sidebarAdded = [];
        fakeApp.inSidebarUrls = [];
        folder.dirRows = [0];
        folder.selected = [0];
        folder.selectedCount = 1;
        let items = tab.itemMenu(folder);
        const add = items.find(i => i.id === "addToSidebar");
        verify(add !== undefined, "Add to Sidebar in a folder's menu");
        verify(add.enabled);
        compare(add.shortcut, "Ctrl+Super+T");
        tab.runAction("addToSidebar", folder);
        compare(fakeApp.sidebarAdded, [{urls: [String(folder.urlAt(0))], position: -1}]);
        fakeApp.inSidebarUrls = [String(folder.urlAt(0))];
        items = tab.itemMenu(folder);
        verify(!items.find(i => i.id === "addToSidebar").enabled, "dimmed: already in the sidebar");
        folder.dirRows = [];
        items = tab.itemMenu(folder);
        verify(!items.some(i => i.id === "addToSidebar"), "a file has no Add to Sidebar");
        // Nothing selected: the shown folder, from the keyboard.
        folder.selected = [];
        folder.selectedCount = 0;
        fakeApp.inSidebarUrls = [];
        fakeApp.sidebarAdded = [];
        keyClick(Qt.Key_T, Qt.ControlModifier | Qt.MetaModifier);
        compare(fakeApp.sidebarAdded, [{urls: [String(tab.url)], position: -1}]);
    }
}
