pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"
import "../../apps/files/qml/PanelLogic.js" as PanelLogic

// grassfield-portal's Open and Save panels (apps/files/qml/FilePanel.qml; ADR-0035 D-4, docs/specs/system-dialogs.md section
// 1) offscreen, over a stand-in FilesApp, a stand-in FileChooser (the answers it gets) and a stand-in listing of a small
// tree: what each kind of panel answers, the replace questions, the refusal of a network location, the filters and choices,
// Esc, the panel's menus, and what it remembers. PanelLogic.js's rules first.
TestCase {
    id: test
    name: "FilePanel"
    when: windowShown

    // The tree the stand-in listing shows: folder URL -> [name, isDir].
    readonly property var tree: ({
            "file:///home/u": [["Documents", true], ["notes.txt", false]],
            "file:///home/u/Documents": [["a.txt", false], ["b.png", false], ["Sub", true]],
            "file:///home/u/Documents/Sub": [["x.txt", false]],
            "file:///home/u/My Documents": [["c.txt", false]],
            "grassfield-apps:/": [["Text Editor", false], ["org.gnome.TextEditor", false], ["org.kde.kate", false], ["org.example.Other", false]],
            "smb://server/share": [["remote.txt", false]]
        })

    // The Applications listing still loading when the panel opens (the real one lists on a thread): the test ends it.
    property bool slowApplications: false

    // The tree's entries for a folder URL in either form QML prints it (a typed url parameter prints "My%20Documents", a
    // url from Qt.url() "My Documents").
    function entries(folder: string): var {
        return test.tree[folder] || test.tree[decodeURI(folder)];
    }

    // FolderModel as the panel, BrowserTab and the icon view read it.
    Component {
        id: listingComponent
        ListModel {
            id: listing
            property url url
            property bool loading: false
            property string error: ""
            property real freeSpace: -1
            property bool isTrash: false
            property bool writable: true
            property bool isSearch: false
            property bool isRecents: false
            readonly property bool isApplications: String(listing.url).startsWith("grassfield-apps:")
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
            property var chooser: ({})
            property var expected: []
            property string title: ""
            signal redirected(url url)
            signal revealRequested(int row, bool rename)
            signal selectionChanged

            onUrlChanged: listing.relist()
            onChooserChanged: listing.relist()

            // FolderModel::dimmed: a file the panel cannot take (folders only; else a "*.ext" glob it does not match); in the
            // Applications location, every application but those Choose Application takes (the tree names them by id).
            function dimmedFor(name: string, isDir: bool): bool {
                const c = listing.chooser;
                if (!c || Object.keys(c).length === 0)
                    return false;
                // The URL itself: onUrlChanged runs before the isApplications binding has followed it.
                if (String(listing.url).startsWith("grassfield-apps:"))
                    return !(c.allApplications === true || (c.applications || []).indexOf(name) >= 0);
                if (isDir)
                    return false;
                if (c.foldersOnly)
                    return true;
                const globs = c.globs || [];
                return globs.length > 0 && !globs.some(g => name.toLowerCase().endsWith(g.substring(1).toLowerCase()));
            }
            function relist(): void {
                if (test.slowApplications && String(listing.url).startsWith("grassfield-apps:"))
                    listing.loading = true;
                const keep = listing.selectedUrls().map(String);
                listing.clear();
                const entries = test.entries(String(listing.url)) || [];
                for (const e of entries) {
                    const url = String(listing.url).startsWith("grassfield-apps:") ? "grassfield-app:/" + e[0] : String(listing.url) + "/" + e[0];
                    listing.append({name: e[0], url: url, iconName: "", thumbnail: "", largeThumbnail: "", emblem: "", isDir: e[1], canPreview: false,
                                    hidden: false, dimmed: listing.dimmedFor(e[0], e[1]), tagColors: [], folderColor: "", folderGlyph: "",
                                    selected: keep.indexOf(url) >= 0 && !listing.dimmedFor(e[0], e[1]), modifiedText: "", sizeText: "", kind: "", group: ""});
                }
                listing.countSelected();
            }
            function countSelected(): void {
                let n = 0;
                for (let i = 0; i < listing.count; i++)
                    n += listing.get(i).selected ? 1 : 0;
                listing.selectedCount = n;
                listing.selectionChanged();
            }
            function select(row: int, modifiers: int, pointer: bool): void {
                const single = listing.chooser.single === true;
                // FolderModel::select: a plain click on a panel's dimmed item does nothing.
                const plain = single || !(modifiers & (Qt.ShiftModifier | Qt.ControlModifier));
                if (pointer && plain && Object.keys(listing.chooser).length > 0 && row >= 0 && row < listing.count && listing.get(row).dimmed)
                    return;
                for (let i = 0; i < listing.count; i++) {
                    const on = i === row ? !listing.get(i).dimmed : (!single && (modifiers & Qt.ControlModifier) ? listing.get(i).selected : false);
                    listing.setProperty(i, "selected", on);
                }
                listing.currentRow = row;
                listing.countSelected();
            }
            function selectAll(): void {
            }
            function clearSelection(): void {
                listing.select(-1, 0);
            }
            function selectUrls(urls: var): void {
            }
            function selectedRows(): var {
                const rows = [];
                for (let i = 0; i < listing.count; i++) {
                    if (listing.get(i).selected)
                        rows.push(i);
                }
                return rows;
            }
            function selectedUrls(): var {
                return listing.selectedRows().map(r => listing.get(r).url);
            }
            function isSelected(row: int): bool {
                return row >= 0 && row < listing.count && listing.get(row).selected;
            }
            function findPrefix(prefix: string, from: int): int {
                return -1;
            }
            function rowForUrl(target: url): int {
                for (let i = 0; i < listing.count; i++) {
                    if (String(listing.get(i).url) === String(target))
                        return i;
                }
                return -1;
            }
            function isDirAt(row: int): bool {
                return row >= 0 && row < listing.count && listing.get(row).isDir;
            }
            function nameAt(row: int): string {
                return row >= 0 && row < listing.count ? listing.get(row).name : "";
            }
            function urlAt(row: int): url {
                return row >= 0 && row < listing.count ? listing.get(row).url : "";
            }
            function expect(target: url, rename: bool): void {
                listing.expected = listing.expected.concat([String(target)]);
            }
            // The column view's wish (FolderModel.expectAlone).
            function expectAlone(target: url): void {
            }
            function reload(): void {
            }
            function requestPreview(row: int, large: bool): void {
            }
            function cancelPreview(target: url, large: bool): void {
            }
            function info(row: int): var {
                return {name: "", url: listing.url, isDir: true, kind: "Folder", sizeText: "", where: "/", created: "", modified: "", accessed: ""};
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

    // What the panel, BrowserTab, the sidebar and the views read of FilesApp.
    QtObject {
        id: fakeApp
        property bool dark: false
        property bool reduceMotion: false
        property string accentColor: "multicolor"
        property string accentHighlight: "automatic"
        property string shortcutStyle: "pc"
        property string iconMode: "default"
        property string iconTint: "accent"
        property string folderColor: "theme"
        property string viewMode: "icons"
        property int sortKey: 0
        property bool sortDescending: false
        property int recentsSortKey: 5
        property bool foldersFirst: true
        property bool showHidden: false
        property bool previewPane: false
        property bool galleryInfo: false
        property bool columnPreview: false
        property bool canPaste: false
        property int clipboardCount: 0
        property bool devSession: true
        property int tagRevision: 0
        property int folderStyleRevision: 0
        property var colorTagNames: []
        property var hiddenTags: []
        property var launched: []
        function launchApplication(target: url): void {
            fakeApp.launched = fakeApp.launched.concat([String(target)]);
        }
        // The Store's answer to `--removable` (ADR-0046): nothing here is removable, and nothing is asked.
        property string removableText: ""
        function loadRemovableApplications(): void {
        }
        function uninstallApplication(id: string): void {
        }
        function tagName(tag: string): string {
            return tag;
        }
        property string homePath: "/home/u"
        property var places: places
        property var prompts: null
        property var folderViews: ({})
        property var made: []
        signal prefsChanged
        signal operationFailed(string message)
        function createFolderModel(owner: var): var {
            return listingComponent.createObject(owner);
        }
        function folderView(target: url): var {
            return fakeApp.folderViews[String(target)] || {};
        }
        function setFolderView(target: url, view: var): void {
            const all = Object.assign({}, fakeApp.folderViews);
            all[String(target)] = Object.assign({}, all[String(target)] || {}, view);
            fakeApp.folderViews = all;
        }
        function pathSegments(target: url): var {
            const s = String(target);
            if (s.startsWith("smb:"))
                return [{label: "share", url: target}];
            // FilesApp's one segment for the Applications location.
            if (s.startsWith("grassfield-apps:"))
                return [{label: "Applications", url: target}];
            const parts = s.substring("file://".length).split("/").filter(p => p !== "");
            const out = [];
            let at = "file://";
            for (const p of parts) {
                at += "/" + p;
                out.push({label: p, url: at});
            }
            return out;
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
            return {valid: false};
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
        function tagsUnavailable(urls: var): string {
            return "";
        }
        function folderStyleUnavailable(urls: var): string {
            return "";
        }
        function applicationsFor(urls: var): var {
            return [];
        }
        function applicationsUrl(): url {
            return "grassfield-apps:/";
        }
        function applicationUrl(id: string): url {
            return "grassfield-app:/" + id;
        }
        function applicationId(target: url): string {
            const s = String(target);
            return s.startsWith("grassfield-app:/") ? s.substring("grassfield-app:/".length) : "";
        }
        function baseNameLength(name: string, isDir: bool): int {
            const dot = name.lastIndexOf(".");
            return dot > 0 ? dot : name.length;
        }
        function isValidFileName(name: string): bool {
            return name !== "" && name !== "." && name !== ".." && name.indexOf("/") < 0;
        }
        function resolveLocation(text: string, base: url): url {
            return test.tree[text] ? text : "";
        }
        // FilesApp::locationUrl: the address only, no look at the disk.
        function locationUrl(text: string, base: url): url {
            const t = text.trim();
            if (t === "")
                return "";
            if (t.indexOf(":/") > 0)
                return t;
            if (t.startsWith("/"))
                return "file://" + t;
            return String(base).replace(/\/+$/, "") + "/" + t;
        }
        function uriList(urls: var): string {
            return "";
        }
        function rotatableImages(urls: var): var {
            return [];
        }
        function glance(urls: var): void {
        }
        function makeFolder(directory: url, name: string, done: var): void {
            fakeApp.made = fakeApp.made.concat([String(directory) + "/" + name]);
            done(String(directory) + "/" + name, "");
        }
    }

    // FileChooser (apps/portal/src/filechooser.h) as the panel uses it.
    QtObject {
        id: fakeHost
        property var answers: []
        property var remembered: []
        // URL -> 0 none, 1 file, 2 folder (FileChooser::pathKindOf); the tree's folders are folders. A URL that starts with
        // one of `slow` does not answer (-2), as a hung mount.
        property var kinds: ({})
        property var slow: []
        property int nextToken: 1
        signal probed(int token, var kinds)
        // FilePanels.qml's side of FileChooser.
        signal opened(int id, var request)
        signal closed(int id)
        function memory(appId: string): var {
            return {};
        }
        function present(id: int, window: var): void {
        }
        function fail(id: int): void {
        }
        function answer(id: int, response: int, map: var): void {
            fakeHost.answers = fakeHost.answers.concat([{id: id, response: response, map: map}]);
        }
        function remember(appId: string, entry: var): void {
            fakeHost.remembered = fakeHost.remembered.concat([{appId: appId, entry: entry}]);
        }
        function kindOf(text: string): int {
            const s = String(text);
            if (!s.startsWith("file:"))
                return -1;
            if (fakeHost.slow.some(p => s.startsWith(p)))
                return -2;
            if (test.entries(s))
                return 2;
            return fakeHost.kinds[s] ?? fakeHost.kinds[decodeURI(s)] ?? 0;
        }
        // FileChooser::probe: answered later, never from inside the call.
        function probe(urls: var): int {
            const token = fakeHost.nextToken++;
            const kinds = {};
            for (const u of urls)
                kinds[u] = fakeHost.kindOf(u);
            Qt.callLater(() => fakeHost.probed(token, kinds));
            return token;
        }
        function appName(appId: string): string {
            return "Example";
        }
    }

    // AppChooser (apps/portal/src/appchooser.h) as a Choose Application panel uses it.
    QtObject {
        id: fakeAppHost
        property var answers: []
        // FilePanels.qml's side of AppChooser.
        signal opened(int id, var request)
        signal closed(int id)
        signal applicationsChanged(int id, var applications)
        function present(id: int, window: var): void {
        }
        function fail(id: int): void {
        }
        function answer(id: int, response: int, map: var): void {
            fakeAppHost.answers = fakeAppHost.answers.concat([{id: id, response: response, map: map}]);
        }
    }

    // FilePanels.qml as a panel reads it.
    QtObject {
        id: fakeManager
        property string testAnswer: ""
        property var lastActiveWindow: null
        property var promptWindow: null
        function springStarted(tab: var): void {
        }
        function dragEnded(dropped: bool): void {
        }
    }

    Component {
        id: panelsComponent
        FilePanels {}
    }

    Component {
        id: panelComponent
        FilePanel {
            app: fakeApp
            host: fakeHost
            appHost: fakeAppHost
            manager: fakeManager
            requestId: 7
            places: test.places
        }
    }

    readonly property var places: ({home: "file:///home/u", desktop: "", documents: "file:///home/u/Documents", downloads: ""})

    function request(fields: var): var {
        return Object.assign({kind: "open", appId: "org.example.App", title: "", acceptLabel: "", modal: true, parented: false, multiple: false,
                              directory: false, filters: [], currentFilter: -1, choices: [], currentName: "", files: [], currentFolder: "",
                              currentFile: ""}, fields);
    }

    // A panel for `fields`, shown and active.
    function openPanel(fields: var, extra: var): var {
        fakeHost.answers = [];
        fakeAppHost.answers = [];
        fakeHost.remembered = [];
        fakeHost.kinds = {};
        // What the backend probed before the panel (FileChooser::handle): the folders it may start in.
        const request = test.request(fields);
        const memory = (extra && extra.memory) || {};
        const places = (extra && extra.places) || test.places;
        const kinds = {};
        for (const u of [request.currentFolder, memory.folder || "", places.documents, places.home])
            if (u)
                kinds[u] = fakeHost.kindOf(u);
        request.folderKinds = kinds;
        const panel = createTemporaryObject(panelComponent, test, Object.assign({request: request}, extra || {}));
        verify(panel !== null, "FilePanel");
        panel.show();
        panel.requestActivate();
        tryVerify(() => panel.active, 2000, "the panel is active");
        return panel;
    }

    function findTab(item: var): var {
        if (item instanceof BrowserTab)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const t = test.findTab(item.children[i]);
            if (t)
                return t;
        }
        return null;
    }

    function rowOf(model: var, name: string): int {
        for (let i = 0; i < model.count; i++) {
            if (model.get(i).name === name)
                return i;
        }
        return -1;
    }

    // Every test starts with a disk that answers (a test that fails half-way must not leave a folder hung for the next).
    function cleanup(): void {
        fakeManager.testAnswer = "";
        fakeApp.viewMode = "icons";
        test.slowApplications = false;
        fakeHost.slow = [];
    }

    // PanelLogic.js --------------------------------------------------------------------------------------------------------

    function test_logic_filter_follows_the_request(): void {
        const filters = [{name: "Text", globs: ["*.txt"], mimeTypes: ["text/plain"]}, {name: "Images", globs: [], mimeTypes: ["image/*"]}];
        const f = PanelLogic.filterFor(test.request({filters: filters, currentFilter: 1}), 1);
        compare(f.globs, []);
        compare(f.mimeTypes, ["image/*"]);
        verify(!f.foldersOnly);
        verify(f.single);
        verify(PanelLogic.filterFor(test.request({directory: true}), -1).foldersOnly);
        verify(PanelLogic.filterFor(test.request({kind: "saveFiles"}), -1).foldersOnly);
        verify(!PanelLogic.filterFor(test.request({multiple: true}), -1).single);
        verify(PanelLogic.filterFor(test.request({kind: "save", multiple: true}), -1).single);
    }

    function test_logic_open_action(): void {
        const files = test.request({});
        compare(PanelLogic.openAction(files, [], "file:///d").action, "none");
        compare(PanelLogic.openAction(files, [{url: "file:///d/Sub", isDir: true}], "file:///d"), {action: "enter", url: "file:///d/Sub"});
        compare(PanelLogic.openAction(files, [{url: "file:///d/a", isDir: false}, {url: "file:///d/b", isDir: false}], "file:///d").uris, ["file:///d/a"]);
        compare(PanelLogic.openAction(test.request({multiple: true}), [{url: "file:///d/a", isDir: false}, {url: "file:///d/S", isDir: true}, {url: "file:///d/b", isDir: false}], "file:///d").uris,
                ["file:///d/a", "file:///d/b"]);
        const folders = test.request({directory: true});
        compare(PanelLogic.openAction(folders, [], "file:///d").uris, ["file:///d"]);
        compare(PanelLogic.openAction(folders, [{url: "file:///d/S", isDir: true}], "file:///d").uris, ["file:///d/S"]);
        verify(PanelLogic.openEnabled(folders, 0));
        verify(!PanelLogic.openEnabled(files, 0));
    }

    function test_logic_names_and_folders(): void {
        compare(PanelLogic.nameForFormat("Report.txt", ["*.md"]), "Report.md");
        compare(PanelLogic.nameForFormat("Report", ["*.md"]), "Report");
        compare(PanelLogic.nameForFormat("Report.txt", ["*.[mM][dD]"]), "Report.txt");
        compare(PanelLogic.nameForFormat(".bashrc", ["*.sh"]), ".bashrc");
        compare(PanelLogic.childUrl("file:///d/", "a b#?.txt"), "file:///d/a%20b%23%3F.txt");
        compare(PanelLogic.parentUrl("file:///d/e/f.txt"), "file:///d/e");
        compare(PanelLogic.parentUrl("file:///f.txt"), "file:///");
        verify(PanelLogic.isLocal("file:///d"));
        verify(!PanelLogic.isLocal("smb://host/d"));
        const isFolder = u => u === "file:///home/u" || u === "file:///home/u/Documents";
        const places = {home: "file:///home/u", documents: "file:///home/u/Documents"};
        compare(PanelLogic.startFolder(test.request({currentFolder: "file:///gone"}), {folder: "file:///home/u"}, places, isFolder), "file:///home/u");
        compare(PanelLogic.startFolder(test.request({}), {}, places, isFolder), "file:///home/u/Documents");
        compare(PanelLogic.startFolder(test.request({currentFolder: "file:///home/u"}), {folder: "file:///home/u/Documents"}, places, isFolder), "file:///home/u");
        compare(PanelLogic.choicesAnswer(test.request({choices: [{id: "a", initial: "x"}, {id: "b", initial: "false"}]}), {b: "true"}),
                [{id: "a", value: "x"}, {id: "b", value: "true"}]);
        compare(PanelLogic.clashes(["a", "b"], "file:///d", u => u.endsWith("/b") ? 1 : 0), [{name: "b", folder: false}]);
    }

    // The panel ------------------------------------------------------------------------------------------------------------

    function test_open_takes_a_file_the_filter_allows(): void {
        const panel = test.openPanel({title: "Open Report", currentFolder: "file:///home/u/Documents", currentFilter: 0,
                                      filters: [{name: "Text", globs: ["*.txt"], mimeTypes: []}, {name: "Images", globs: ["*.png"], mimeTypes: []}],
                                      choices: [{id: "ro", label: "Read only", options: [], initial: "true"}]});
        const tab = test.findTab(panel.contentItem);
        verify(tab !== null);
        compare(String(tab.url), "file:///home/u/Documents");
        compare(panel.acceptText, "Open");
        compare(panel.title, "Open Report");
        verify(!panel.acceptEnabled, "nothing selected: Open is disabled");
        compare(tab.folder.chooser.globs, ["*.txt"]);
        // The picture is dimmed and cannot be selected; the text file can.
        const m = tab.folder;
        verify(m.get(test.rowOf(m, "b.png")).dimmed);
        m.select(test.rowOf(m, "b.png"), 0);
        compare(m.selectedCount, 0);
        m.select(test.rowOf(m, "a.txt"), 0);
        verify(panel.acceptEnabled);
        panel.pressDefault();
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].response, 0);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/a.txt"]);
        compare(fakeHost.answers[0].map.choices, [{id: "ro", value: "true"}]);
        compare(fakeHost.answers[0].map.filter, 0);
        // What the application's panel is left with.
        compare(fakeHost.remembered[0].entry.folder, "file:///home/u/Documents");
        compare(fakeHost.remembered[0].entry.view, "icons");
        // Answered once.
        panel.pressDefault();
        compare(fakeHost.answers.length, 1);
    }

    function test_the_format_changes_what_is_dimmed(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents", currentFilter: 0,
                                      filters: [{name: "Text", globs: ["*.txt"], mimeTypes: []}, {name: "Images", globs: ["*.png"], mimeTypes: []}]});
        const tab = test.findTab(panel.contentItem);
        panel.filterIndex = 1;
        compare(tab.folder.chooser.globs, ["*.png"]);
        verify(tab.folder.get(test.rowOf(tab.folder, "a.txt")).dimmed);
        verify(!tab.folder.get(test.rowOf(tab.folder, "b.png")).dimmed);
    }

    function test_a_folder_selected_in_a_file_panel_opens(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        tab.folder.select(test.rowOf(tab.folder, "Sub"), 0);
        panel.pressDefault();
        compare(String(tab.url), "file:///home/u/Documents/Sub");
        compare(fakeHost.answers.length, 0);
    }

    function test_a_folder_panel_chooses_the_shown_or_selected_folder(): void {
        let panel = test.openPanel({directory: true, acceptLabel: "_Choose", currentFolder: "file:///home/u/Documents"});
        let tab = test.findTab(panel.contentItem);
        verify(tab.folder.get(test.rowOf(tab.folder, "a.txt")).dimmed, "files are dimmed");
        verify(panel.acceptEnabled);
        panel.pressDefault();
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents"]);
        panel.destroy();
        panel = test.openPanel({directory: true, currentFolder: "file:///home/u/Documents"});
        tab = test.findTab(panel.contentItem);
        tab.folder.select(test.rowOf(tab.folder, "Sub"), 0);
        panel.pressDefault();
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/Sub"]);
    }

    function test_a_double_click_on_a_file_chooses_it(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents", filters: [{name: "Text", globs: ["*.txt"], mimeTypes: []}], currentFilter: 0});
        const tab = test.findTab(panel.contentItem);
        tab.activate(test.rowOf(tab.folder, "b.png"), tab.folder, 0);
        compare(fakeHost.answers.length, 0, "a dimmed file is not chosen");
        tab.activate(test.rowOf(tab.folder, "Sub"), tab.folder, 0);
        compare(String(tab.url), "file:///home/u/Documents/Sub", "a folder opens");
        tab.activate(test.rowOf(tab.folder, "x.txt"), tab.folder, 0);
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/Sub/x.txt"]);
    }

    // The Applications location (Files' launchers) in a panel: a double-click starts nothing, and there is nothing to choose
    // or to save there.
    function test_the_applications_location_starts_nothing_in_a_panel(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents", directory: true});
        const tab = test.findTab(panel.contentItem);
        verify(panel.acceptEnabled, "a folder panel can choose a folder");
        tab.navigate(Qt.url("grassfield-apps:/"), true);
        verify(tab.isApplications);
        fakeApp.launched = [];
        tab.activate(test.rowOf(tab.folder, "Text Editor"), tab.folder, 0);
        compare(fakeApp.launched.length, 0, "no application started");
        compare(fakeHost.answers.length, 0);
        verify(!panel.acceptEnabled, "nothing to choose in Applications");
        panel.pressDefault();
        compare(fakeHost.answers.length, 0);
    }

    function test_return_in_the_listing_is_the_default_button(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        tab.folder.select(test.rowOf(tab.folder, "a.txt"), 0);
        tab.focusView();
        tryVerify(() => tab.view && tab.view.activeFocus !== undefined);
        keyClick(Qt.Key_Return);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/a.txt"]);
    }

    function test_escape_cancels(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents", currentName: ""});
        keyClick(Qt.Key_Escape);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].response, 1);
        compare(fakeHost.remembered.length, 1, "a cancel keeps the folder too");
    }

    function test_a_network_location_is_refused(): void {
        const panel = test.openPanel({directory: true, currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        tab.navigate("smb://server/share", true);
        panel.pressDefault();
        compare(fakeHost.answers.length, 0);
        verify(panel.sheetShown, "the refusal is a sheet");
        keyClick(Qt.Key_Return);
        tryVerify(() => !panel.sheetShown);
        compare(fakeHost.answers.length, 0);
    }

    function test_save_compact_saves_the_name_in_the_shown_folder(): void {
        const panel = test.openPanel({kind: "save", currentName: "Report.txt", currentFolder: "file:///home/u/Documents", currentFilter: 0,
                                      filters: [{name: "Text", globs: ["*.txt"], mimeTypes: []}, {name: "Markdown", globs: ["*.md"], mimeTypes: []}]});
        verify(!panel.expanded, "compact by default");
        verify(panel.height < Tokens.filesPanelHeight);
        compare(panel.acceptText, "Save");
        // The Format pop-up changes the extension.
        const tab = test.findTab(panel.contentItem);
        panel.filterIndex = 1;
        // The name field is the one TextField of the header.
        let name = null;
        const walk = item => {
            if (item instanceof TextField && !name)
                name = item;
            for (let i = 0; i < item.children.length; i++)
                walk(item.children[i]);
        };
        walk(panel.contentItem);
        verify(name !== null);
        compare(name.text, "Report.txt");
        name.text = PanelLogic.nameForFormat(name.text, ["*.md"]);
        panel.pressDefault();
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/Report.md"]);
        compare(fakeHost.answers[0].map.filter, 1);
        compare(fakeHost.remembered[0].entry.expanded, false);
        verify(String(tab.url) === "file:///home/u/Documents");
    }

    function test_save_expands_and_remembers(): void {
        const panel = test.openPanel({kind: "save", currentName: "a.txt", currentFolder: "file:///home/u/Documents"}, {memory: {expanded: true, view: "list"}});
        verify(panel.expanded);
        const tab = test.findTab(panel.contentItem);
        compare(tab.viewMode, "list");
        tab.setViewMode("columns");
        panel.expanded = false;
        panel.cancel();
        compare(fakeHost.remembered[0].entry.view, "columns");
        compare(fakeHost.remembered[0].entry.expanded, false);
    }

    function test_save_over_a_file_asks_first(): void {
        const panel = test.openPanel({kind: "save", currentName: "a.txt", currentFolder: "file:///home/u/Documents"});
        fakeHost.kinds = {"file:///home/u/Documents/a.txt": 1};
        panel.pressDefault();
        tryVerify(() => panel.sheetShown, 1000, "the replace question");
        compare(fakeHost.answers.length, 0);
        // Return is Cancel (macOS: Replace is never the default here).
        keyClick(Qt.Key_Return);
        tryVerify(() => !panel.sheetShown);
        compare(fakeHost.answers.length, 0);
        panel.pressDefault();
        tryVerify(() => panel.sheetShown);
        const sheet = test.findSheet(panel.contentItem, true);
        verify(sheet !== null);
        sheet.confirm();
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/a.txt"]);
    }

    function test_save_with_a_folders_name_is_refused(): void {
        const panel = test.openPanel({kind: "save", currentName: "Sub", currentFolder: "file:///home/u/Documents"});
        panel.pressDefault();
        tryVerify(() => panel.sheetShown);
        compare(fakeHost.answers.length, 0);
    }

    function test_save_files_asks_about_the_names_that_exist(): void {
        const panel = test.openPanel({kind: "saveFiles", files: ["a.txt", "c.txt"], currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        verify(tab.folder.get(test.rowOf(tab.folder, "a.txt")).dimmed, "a folder panel");
        fakeHost.kinds = {"file:///home/u/Documents/a.txt": 1};
        panel.pressDefault();
        tryVerify(() => panel.sheetShown);
        const sheet = test.findSheet(panel.contentItem, true);
        verify(sheet.title.indexOf("a.txt") >= 0);
        // One name: the message speaks of it, not of them (step 4b's integrator status, MINOR).
        compare(sheet.message, "Replacing it will overwrite its current contents.");
        sheet.confirm();
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/a.txt", "file:///home/u/Documents/c.txt"]);
    }

    function test_save_files_asks_about_several_names_together(): void {
        const panel = test.openPanel({kind: "saveFiles", files: ["a.txt", "b.png", "c.txt"], currentFolder: "file:///home/u/Documents"});
        fakeHost.kinds = {"file:///home/u/Documents/a.txt": 1, "file:///home/u/Documents/b.png": 1};
        panel.pressDefault();
        tryVerify(() => panel.sheetShown);
        const sheet = test.findSheet(panel.contentItem, true);
        compare(sheet.title, "2 items already exist in “Documents”. Do you want to replace them?");
        compare(sheet.message, "a.txt\nb.png\n\nReplacing them will overwrite their current contents.");
    }

    // SaveFiles into a folder that does not answer: the folder is not responding, never a replace question, nothing answered
    // (re-review of 6b26afc, Q22).
    function test_save_files_into_a_folder_that_does_not_answer(): void {
        const panel = test.openPanel({kind: "saveFiles", files: ["a.txt", "c.txt"], currentFolder: "file:///home/u/Documents"});
        fakeHost.kinds = {"file:///home/u/Documents/a.txt": 1};
        fakeHost.slow = ["file:///home/u/Documents/c"];
        panel.pressDefault();
        tryVerify(() => panel.sheetShown);
        const sheet = test.findSheet(panel.contentItem, true);
        compare(sheet.title, "“Documents” isn’t responding.");
        compare(sheet.confirmText, "OK", "a message, not the replace question");
        sheet.confirm();
        tryVerify(() => !panel.sheetShown);
        compare(fakeHost.answers.length, 0);
    }

    function test_the_panels_menus_change_no_file(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        tab.folder.select(test.rowOf(tab.folder, "a.txt"), 0);
        const ids = tab.actionMenu().map(i => i.id).filter(i => i !== undefined);
        for (const forbidden of ["trash", "rename", "copy", "cut", "paste", "duplicate", "info", "openWith", "newTab", "customize"])
            verify(ids.indexOf(forbidden) < 0, forbidden);
        verify(ids.indexOf("glance") >= 0);
        verify(tab.chooserMenu(tab.folder, false).every(i => i.id !== "newFolder"), "no New Folder in a file Open panel");
        verify(!tab.canRename());
        tab.startRename(tab.folder, 0);
        verify(tab.renameModel === null);
    }

    function test_new_folder_in_a_save_panel(): void {
        const panel = test.openPanel({kind: "save", currentName: "a.txt", currentFolder: "file:///home/u/Documents"}, {memory: {expanded: true}});
        const tab = test.findTab(panel.contentItem);
        verify(tab.chooserMenu(tab.folder, false).some(i => i.id === "newFolder"));
        fakeApp.made = [];
        panel.newFolder();
        verify(panel.sheetShown);
        const sheet = test.findSheet(panel.contentItem, true);
        sheet.confirm();
        compare(fakeApp.made, ["file:///home/u/Documents/untitled folder"]);
    }

    // A folder with a space (review of step 4b, BLOCKER 1 and NIT 15): Where lists it once, though the places come encoded and
    // with a trailing "/", and Save answers the name in it (the backend reads the URL as QML prints it).
    function test_where_lists_a_folder_with_a_space_once(): void {
        const panel = test.openPanel({kind: "save", currentName: "new file.txt", currentFolder: "file:///home/u/My Documents"},
                                     {places: {home: "file:///home/u/", desktop: "", documents: "file:///home/u/My%20Documents/", downloads: ""}});
        let where = null;
        const walk = item => {
            if (item instanceof ComboBox && item.accessibleName === "Where" && !where)
                where = item;
            for (let i = 0; i < item.children.length; i++)
                walk(item.children[i]);
        };
        walk(panel.contentItem);
        verify(where !== null, "the Where pop-up");
        const ids = [];
        for (let i = 0; i < where.model.length; i++)
            ids.push(where.model[i].id);
        compare(ids.filter(i => i === "file:///home/u/My Documents").length, 1, ids.join(", "));
        compare(ids.filter(i => i === "file:///home/u").length, 1, ids.join(", "));
        compare(where.value, "file:///home/u/My Documents");
        // A root keeps its "/" (counter-review of step 4b, NIT-1): "sftp://host" is no folder.
        compare(where.key("file:///home/u/"), "file:///home/u");
        compare(where.key("file:///"), "file:///");
        compare(where.key("sftp://host/"), "sftp://host/");
        compare(where.key("sftp://host/srv/"), "sftp://host/srv");
        compare(where.key("network:/"), "network:/");
        panel.pressDefault();
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].map.uris.length, 1);
        compare(decodeURIComponent(fakeHost.answers[0].map.uris[0]), "file:///home/u/My Documents/new file.txt");
    }

    // The panel is a dialog named by its title (spec common rule 4; review of step 4b, MINOR 9), and its sidebar changes no
    // tag: the Tags menu does not open, where Files would offer Show Hidden Tag (MINOR 4).
    function test_the_panel_is_an_accessible_dialog_and_its_sidebar_changes_no_tag(): void {
        const panel = test.openPanel({title: "Import a Picture", currentFolder: "file:///home/u/Documents"});
        let dialog = null;
        let sidebar = null;
        const walk = item => {
            if (!dialog && item.Accessible.role === Accessible.Dialog)
                dialog = item;
            if (!sidebar && item instanceof Sidebar)
                sidebar = item;
            for (let i = 0; i < item.children.length; i++)
                walk(item.children[i]);
        };
        walk(panel.contentItem);
        verify(dialog !== null, "an item with the Dialog role");
        compare(dialog.Accessible.name, "Import a Picture");
        verify(sidebar !== null, "the sidebar");
        verify(sidebar.choosing);
        fakeApp.hiddenTags = ["red"];
        sidebar.openTagMenu("", 10, 10);
        verify(!panel.menuLayer.visible, "no Tags menu in a panel");
        fakeApp.hiddenTags = [];
    }

    // A folder that does not answer (a hung mount; integrator review of bd78424, MAJOR 1): the panel opens in the next folder
    // it may start in, and a Save there says the folder is not responding instead of answering or waiting.
    function test_a_folder_that_does_not_answer_is_passed_over(): void {
        fakeHost.slow = ["file:///home/u/Documents/Sub"];
        const panel = test.openPanel({kind: "save", currentName: "a.txt", currentFolder: "file:///home/u/Documents/Sub"}, {memory: {expanded: true}});
        const tab = test.findTab(panel.contentItem);
        compare(String(tab.url), "file:///home/u/Documents", "the next folder: Documents");
        fakeHost.slow = ["file:///home/u/Documents"];
        panel.pressDefault();
        verify(!panel.acceptEnabled, "one question to the disk at a time");
        tryVerify(() => panel.sheetShown);
        const sheet = test.findSheet(panel.contentItem, true);
        compare(sheet.title, "“Documents” isn’t responding.");
        compare(fakeHost.answers.length, 0);
        fakeHost.slow = [];
    }

    // Go to Folder (Cmd-Shift-G) in the compact Save panel: the sheet opens, and going there expands the panel (macOS;
    // integrator review of bd78424, MINOR 2); a folder that is not there brings the sheet back with the reason.
    function test_go_to_folder_in_the_compact_save_panel(): void {
        const panel = test.openPanel({kind: "save", currentName: "a.txt", currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        verify(!panel.expanded);
        keyClick(Qt.Key_G, Qt.ControlModifier | Qt.ShiftModifier);
        tryVerify(() => panel.sheetShown);
        let sheet = test.findSheet(panel.contentItem, true);
        sheet.setField("Gone");
        sheet.confirm();
        tryVerify(() => test.findSheet(panel.contentItem, true) !== null && test.findSheet(panel.contentItem, true).errorText !== "");
        sheet = test.findSheet(panel.contentItem, true);
        compare(sheet.errorText, "The folder “Gone” can’t be found.");
        verify(!panel.expanded);
        sheet.setField("Sub");
        sheet.confirm();
        tryCompare(tab, "url", Qt.url("file:///home/u/Documents/Sub"));
        verify(panel.expanded, "going to a folder expands the panel");
    }

    // The Save As field (integrator review of bd78424, MINOR 3): the name is selected without its extension, Esc in it
    // cancels the panel, and a name that cannot be a file's is refused with the reason.
    function test_the_save_as_field(): void {
        let panel = test.openPanel({kind: "save", currentName: "Report.final.txt", currentFolder: "file:///home/u/Documents"});
        let name = test.findField(panel.contentItem);
        verify(name !== null);
        tryCompare(name, "activeFocus", true);
        compare(name.selectedText, "Report.final", "the name without its extension");
        name.text = "a/b";
        panel.pressDefault();
        tryVerify(() => panel.sheetShown);
        compare(test.findSheet(panel.contentItem, true).title, "The name “a/b” can’t be used.");
        compare(fakeHost.answers.length, 0);
        test.findSheet(panel.contentItem, true).confirm();
        tryVerify(() => !panel.sheetShown);
        name.forceActiveFocus();
        keyClick(Qt.Key_Escape);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].response, 1, "Esc in the field cancels");
    }

    function test_a_drop_shows_the_item_and_moves_nothing(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u"});
        const tab = test.findTab(panel.contentItem);
        tab.dropUrls(["file:///home/u/Documents/Sub/x.txt"], "file:///home/u", tab.folder);
        compare(String(tab.url), "file:///home/u/Documents/Sub");
        compare(tab.folder.expected, ["file:///home/u/Documents/Sub/x.txt"]);
    }

    function test_slash_in_the_listing_opens_go_to_folder(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        tab.focusView();
        tryVerify(() => tab.view !== null);
        wait(50);
        keyClick("/");
        tryVerify(() => panel.sheetShown);
        const sheet = test.findSheet(panel.contentItem, true);
        compare(sheet.fieldText, "/");
    }

    // The late-focus clock starts at the first frame, not when the window is made visible: a fresh process can take seconds
    // to draw it, and the panel then got the keyboard "late" though it had just appeared (integrator nested pass of
    // f9a25ce, follow-up 2).
    function test_the_late_focus_clock_starts_at_the_first_frame(): void {
        const request = test.request({currentFolder: "file:///home/u/Documents", folderKinds: {"file:///home/u/Documents": 2}});
        const panel = createTemporaryObject(panelComponent, test, {request: request});
        verify(panel !== null);
        panel.visible = true;
        compare(panel.shownAt, 0, "not when made visible");
        verify(waitForRendering(panel.contentItem, 2000));
        tryVerify(() => panel.shownAt > 0, 2000, "at the first frame");
    }

    // A click that brings the panel the keyboard (a click to focus: the compositor delivers the press, then the keyboard)
    // holds nothing, however late: the user is looking at it. Every press in the panel is noted, held or not.
    function test_a_click_to_focus_holds_nothing(): void {
        const request = test.request({currentFolder: "file:///home/u/Documents", folderKinds: {"file:///home/u/Documents": 2}});
        // Shown long ago, a press just now, and not yet active (offscreen Qt activates a window as it shows it).
        const panel = createTemporaryObject(panelComponent, test, {request: request, shownAt: 1, pressedAt: Date.now()});
        verify(panel !== null);
        verify(!panel.everActive);
        panel.show();
        panel.requestActivate();
        // `active` reads true before the activation's handler has run: wait for the handler.
        tryVerify(() => panel.everActive, 2000, "the panel got the keyboard");
        verify(!panel.keysHeld, "the click brought it the keyboard");
        const before = panel.pressedAt;
        wait(5);
        mousePress(panel.contentItem, 10, 10);
        mouseRelease(panel.contentItem, 10, 10);
        verify(panel.pressedAt > before, "the press is noted while nothing is held");
    }

    function test_a_panel_that_gets_the_keyboard_late_waits_for_a_click(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents"}, {shownAt: 1});
        verify(panel.keysHeld);
        keyClick(Qt.Key_Escape);
        wait(50);
        compare(fakeHost.answers.length, 0, "a key does not answer it");
        mousePress(panel.contentItem, 10, 10);
        mouseRelease(panel.contentItem, 10, 10);
        verify(!panel.keysHeld);
    }

    // Choose Application (grassfield-portal's AppChooser; ADR-0035 D-5, step 5b) ------------------------------------------------

    function appRequest(fields: var): var {
        return Object.assign({kind: "application", applications: ["org.gnome.TextEditor"], lastChoice: "org.kde.kate", contentType: "text/plain",
                              filename: "notes.txt", uri: "file:///home/u/notes.txt"}, fields);
    }

    function test_logic_application_filter(): void {
        const recommended = PanelLogic.applicationFilter(["org.gnome.TextEditor"], "org.kde.kate", 0);
        compare(recommended.applications, ["org.gnome.TextEditor", "org.kde.kate"], "the candidates and the last choice");
        verify(!recommended.allApplications);
        verify(recommended.foldersOnly, "no file elsewhere");
        verify(recommended.single);
        compare(PanelLogic.applicationFilter(["a", "b"], "b", 0).applications, ["a", "b"], "the last choice once");
        const all = PanelLogic.applicationFilter(["a"], "", 1);
        verify(all.allApplications);
        compare(all.applications, []);
        // The location lists the candidates and the last choice under both filters, even those the Apps grid hides (imv,
        // NoDisplay=true, the default image viewer the Open With submenu offers).
        compare(recommended.listed, ["org.gnome.TextEditor", "org.kde.kate"]);
        compare(all.listed, ["a"], "All Applications lists them too");
        compare(PanelLogic.applicationFilter(["a"], "imv", 1).listed, ["a", "imv"], "the last choice as well");
    }

    // The macOS panel: an Open panel in the Applications location, the document named over it, "Recommended Applications"
    // enabling the frontend's candidates and its last choice, the others dimmed.
    function test_choose_application_opens_in_applications(): void {
        const panel = test.openPanel(test.appRequest({}));
        const tab = test.findTab(panel.contentItem);
        tryVerify(() => tab.isApplications, 2000, "it opens in Applications");
        compare(panel.title, "Choose Application");
        compare(panel.message, "Choose an application to open the document “notes.txt”.");
        compare(panel.filterIndex, 0, "Recommended Applications");
        compare(panel.formatEntries.length, 2, "the Enable pop-up");
        compare(panel.acceptText, "Open", "Open, never Save (review of step 5b, M1)");
        verify(!panel.canMakeFolder, "no New Folder in Choose Application");
        const m = tab.folder;
        verify(!m.get(test.rowOf(m, "org.gnome.TextEditor")).dimmed, "a candidate");
        verify(!m.get(test.rowOf(m, "org.kde.kate")).dimmed, "the last choice");
        verify(m.get(test.rowOf(m, "org.example.Other")).dimmed, "not recommended");
        verify(!panel.acceptEnabled, "nothing selected yet");
        tryVerify(() => m.expected.indexOf("grassfield-app:/org.kde.kate") >= 0, 2000, "the last choice is selected once listed");
    }

    // Open answers the selected application's desktop id; the panel keeps nothing in FileChooser's memory.
    function test_choose_application_answers_the_id(): void {
        const panel = test.openPanel(test.appRequest({}));
        const tab = test.findTab(panel.contentItem);
        tryVerify(() => tab.isApplications, 2000);
        tab.folder.select(test.rowOf(tab.folder, "org.gnome.TextEditor"), 0);
        verify(panel.acceptEnabled);
        panel.pressDefault();
        compare(fakeAppHost.answers.length, 1);
        compare(fakeAppHost.answers[0].response, 0);
        compare(fakeAppHost.answers[0].map.choice, "org.gnome.TextEditor");
        compare(fakeHost.answers.length, 0, "FileChooser gets no answer");
        compare(fakeHost.remembered.length, 0, "and keeps nothing");
    }

    // "All Applications" enables every one; a double-click chooses it.
    function test_all_applications_and_a_double_click(): void {
        const panel = test.openPanel(test.appRequest({}));
        const tab = test.findTab(panel.contentItem);
        tryVerify(() => tab.isApplications, 2000);
        const m = tab.folder;
        tab.activate(test.rowOf(m, "org.example.Other"), m, 0);
        compare(fakeAppHost.answers.length, 0, "dimmed: nothing chosen");
        panel.filterIndex = 1;
        tryVerify(() => !m.get(test.rowOf(m, "org.example.Other")).dimmed, 2000, "All Applications");
        tab.activate(test.rowOf(m, "org.example.Other"), m, 0);
        compare(fakeAppHost.answers.length, 1);
        compare(fakeAppHost.answers[0].map.choice, "org.example.Other");
    }

    // With no candidate and no last choice, the panel opens on All Applications; UpdateChoices changes the candidates.
    function test_no_candidates_and_new_ones(): void {
        const panel = test.openPanel(test.appRequest({applications: [], lastChoice: ""}));
        compare(panel.filterIndex, 1, "All Applications");
        panel.filterIndex = 0;
        panel.recommended = ["org.example.Other"];
        const tab = test.findTab(panel.contentItem);
        tryVerify(() => tab.isApplications, 2000);
        const m = tab.folder;
        tryVerify(() => !m.get(test.rowOf(m, "org.example.Other")).dimmed, 2000, "the new candidate");
        verify(m.get(test.rowOf(m, "org.gnome.TextEditor")).dimmed);
        compare(panel.message, "Choose an application to open the document “notes.txt”.");
    }

    // Cancel answers AppChooser with response 1; a link (no document name) is named by its address.
    function test_choose_application_cancel_and_a_link(): void {
        const panel = test.openPanel(test.appRequest({filename: "", uri: "magnet:?xt=1"}));
        compare(panel.message, "Choose an application to open “magnet:?xt=1”.");
        panel.cancel();
        compare(fakeAppHost.answers.length, 1);
        compare(fakeAppHost.answers[0].response, 1);
        compare(fakeHost.answers.length, 0);
        compare(fakeHost.remembered.length, 0, "Cancel keeps nothing in FileChooser's memory either");
    }

    // M2 of the review of step 5b: in a Save panel, an application of the Applications location is left alone; its name never
    // replaces the one typed.
    function test_an_application_never_names_a_saved_file(): void {
        const panel = test.openPanel({kind: "save", currentName: "Q3 report.odt", currentFolder: "file:///home/u/Documents"}, {memory: {expanded: true}});
        const tab = test.findTab(panel.contentItem);
        tab.navigate(Qt.url("grassfield-apps:/"), true);
        verify(tab.isApplications);
        tab.activate(test.rowOf(tab.folder, "Text Editor"), tab.folder, 0);
        compare(test.findField(panel.contentItem).text, "Q3 report.odt");
        compare(fakeHost.answers.length, 0);
        compare(fakeApp.launched.length, 0);
    }

    // The Applications listing loads after the panel opened (the real FolderModel lists on a thread): the last choice is
    // selected when it ends (review of step 5b, m7 a).
    // A long name is cut in its middle to fit the line: its extension and the closing quote stay; an address reads decoded
    // (integrator nested pass of f9a25ce, NIT).
    function test_the_message_keeps_the_names_end(): void {
        const long = "a-very-long-document-name-that-goes-on-and-on-".repeat(6) + "end.txt";
        const panel = test.openPanel(test.appRequest({filename: long}));
        compare(panel.message, "Choose an application to open the document “" + long + "”.", "the whole sentence (its accessible name)");
        verify(panel.shownMessage.endsWith("end.txt”."), panel.shownMessage);
        verify(panel.shownMessage.startsWith("Choose an application to open the document “a-very"), panel.shownMessage);
        verify(panel.shownMessage.indexOf("…") > 0, "cut in the middle");
        verify(panel.shownMessage.length < panel.message.length);
        const uri = test.openPanel(test.appRequest({filename: "", uri: "https://example.org/My%20Notes/a%E2%80%AEb.txt"}));
        compare(uri.message, "Choose an application to open “https://example.org/My Notes/a<U+202E>b.txt”.", "decoded, and a bidi control written out");
        const malformed = test.openPanel(test.appRequest({filename: "", uri: "https://example.org/100%"}));
        compare(malformed.message, "Choose an application to open “https://example.org/100%”.", "a malformed escape stays as it is");
    }

    // In the column view, the panel reads the shown column's listing: the click there enables Open, and the last choice is
    // selected in it (integrator nested pass of f9a25ce, follow-up 1: the column view's active column stayed unset when the
    // panel started in its location, so the panel read another listing; Open stayed disabled).
    function test_the_column_view_is_the_panels_listing(): void {
        // Files' own view setting (a Choose Application panel keeps no view of its own).
        fakeApp.viewMode = "columns";
        const panel = test.openPanel(test.appRequest({}));
        const tab = test.findTab(panel.contentItem);
        tryVerify(() => tab.isApplications, 2000);
        compare(tab.viewMode, "columns");
        tryVerify(() => tab.view && tab.view.activeModel !== null, 2000, "the shown column is the active listing");
        verify(tab.activeFolder === tab.view.activeModel, "the panel reads the column");
        const m = tab.activeFolder;
        tryVerify(() => m.expected.indexOf("grassfield-app:/org.kde.kate") >= 0, 2000, "the last choice is selected in the column");
        m.select(test.rowOf(m, "org.gnome.TextEditor"), 0);
        verify(panel.acceptEnabled, "Open");
        panel.pressDefault();
        compare(fakeAppHost.answers.length, 1);
        compare(fakeAppHost.answers[0].map.choice, "org.gnome.TextEditor");
        fakeApp.viewMode = "icons";
    }

    // A view chosen in the panel: the column made for it, already listed, takes the last choice (it never loads, so only
    // the change of listing tells the panel).
    function test_the_last_choice_in_a_view_chosen_in_the_panel(): void {
        const panel = test.openPanel(test.appRequest({}));
        const tab = test.findTab(panel.contentItem);
        tryVerify(() => tab.isApplications, 2000);
        tryVerify(() => tab.folder.expected.indexOf("grassfield-app:/org.kde.kate") >= 0, 2000, "selected in the icon view");
        tab.setViewMode("columns");
        tryVerify(() => tab.view && tab.view.activeModel !== null, 2000, "the column view");
        const m = tab.activeFolder;
        verify(m !== tab.folder, "another listing");
        compare(m.loading, false);
        tryVerify(() => m.expected.indexOf("grassfield-app:/org.kde.kate") >= 0, 2000, "the last choice is selected in the column");
    }

    // In each view, a click and a right-click on a dimmed application keep the application selected (FolderModel::select's
    // pointer; review of step 5c's PR, NIT 3).
    function test_a_click_on_a_dimmed_item_in_each_view(): void {
        const half = {icons: Tokens.filesIconSize / 2, list: Tokens.filesListRowHeight / 2, columns: Tokens.filesColumnRowHeight / 2, gallery: 0};
        for (const mode of ["icons", "list", "columns", "gallery"]) {
            const panel = test.openPanel(test.appRequest({}));
            const tab = test.findTab(panel.contentItem);
            tryVerify(() => tab.isApplications, 2000);
            tab.setViewMode(mode);
            tryVerify(() => tab.view && tab.view.rowPosition && (mode !== "columns" || tab.view.activeModel !== null), 2000, mode);
            const m = tab.activeFolder;
            tryVerify(() => test.rowOf(m, "org.example.Other") >= 0, 2000, mode + ": listed");
            tryVerify(() => tab.view.width > 0 && tab.view.height > 0, 2000, mode + ": laid out");
            verify(waitForRendering(panel.contentItem, 2000));
            const other = test.rowOf(m, "org.example.Other");
            verify(m.get(other).dimmed, mode);
            const click = (row, button) => {
                const p = tab.view.rowPosition(m, row);
                mouseClick(panel.contentItem, p.x, p.y - half[mode], button);
            };
            // The click lands on its row: on an application it may open, it selects it.
            click(test.rowOf(m, "org.kde.kate"), Qt.LeftButton);
            compare(m.selectedRows(), [test.rowOf(m, "org.kde.kate")], mode + ": a click selects");
            m.select(test.rowOf(m, "org.gnome.TextEditor"), 0);
            click(other, Qt.LeftButton);
            compare(m.selectedRows(), [test.rowOf(m, "org.gnome.TextEditor")], mode + ": a click on a dimmed one keeps the selection");
            click(other, Qt.RightButton);
            compare(m.selectedRows(), [test.rowOf(m, "org.gnome.TextEditor")], mode + ": and so does a right-click");
            panel.menuLayer.close();
            m.select(other, 0);
            compare(m.selectedRows(), [], mode + ": a key that lands there selects nothing");
            panel.cancel();
        }
    }

    // The last choice never replaces an application the user selected while the listing loaded.
    function test_the_last_choice_never_over_a_choice(): void {
        test.slowApplications = true;
        const panel = test.openPanel(test.appRequest({}));
        const tab = test.findTab(panel.contentItem);
        tryVerify(() => tab.isApplications, 2000);
        tab.folder.select(test.rowOf(tab.folder, "org.gnome.TextEditor"), 0);
        compare(tab.folder.selectedCount, 1);
        tab.folder.loading = false;
        wait(50);
        compare(tab.folder.expected.length, 0, "the user's choice stays");
    }

    function test_the_last_choice_once_the_listing_has_loaded(): void {
        test.slowApplications = true;
        const panel = test.openPanel(test.appRequest({}));
        const tab = test.findTab(panel.contentItem);
        tryVerify(() => tab.isApplications, 2000);
        wait(50);
        compare(tab.folder.expected.length, 0, "nothing selected while it loads");
        tab.folder.loading = false;
        tryVerify(() => tab.folder.expected.indexOf("grassfield-app:/org.kde.kate") >= 0, 2000);
    }

    // FilePanels.qml with both hosts: their request ids are their own (FileChooser's 1 and AppChooser's 1 are two panels);
    // UpdateChoices reaches the right panel; a Close of one leaves the other (review of step 5b, m7 b and c).
    function test_panels_of_both_hosts(): void {
        const manager = createTemporaryObject(panelsComponent, test, {app: fakeApp, host: fakeHost, appHost: fakeAppHost});
        verify(manager !== null, "FilePanels");
        fakeHost.opened(1, test.request({currentFolder: "file:///home/u/Documents", places: test.places,
                                         folderKinds: {"file:///home/u/Documents": 2}}));
        fakeAppHost.opened(1, test.request(test.appRequest({})));
        const files = manager.panels[manager.key(1, false)];
        const apps = manager.panels[manager.key(1, true)];
        verify(files !== undefined && apps !== undefined && files !== apps, "two panels");
        compare(files.kind, "open");
        compare(apps.kind, "application");
        compare(manager.order, ["1", "app:1"], "the order they opened (an object would list FileChooser's integer key first anyway)");
        fakeHost.opened(2, test.request({currentFolder: "file:///home/u/Documents", places: test.places,
                                         folderKinds: {"file:///home/u/Documents": 2}}));
        compare(manager.order, ["1", "app:1", "2"]);
        fakeHost.closed(2);
        fakeAppHost.applicationsChanged(1, ["org.example.Other"]);
        compare(apps.recommended, ["org.example.Other"]);
        compare(files.recommended, []);
        fakeAppHost.closed(1);
        verify(manager.panels[manager.key(1, true)] === undefined);
        compare(manager.order, ["1"]);
        verify(manager.panels[manager.key(1, false)] === files, "FileChooser's request 1 keeps its panel");
        fakeHost.closed(1);
        compare(Object.keys(manager.panels).length, 0);
    }

    // The integration test's "accept": a Choose Application panel answers once an application is selected (the listing's
    // preselection comes after the first frame).
    function test_the_test_answer_waits_for_a_selection(): void {
        fakeManager.testAnswer = "accept";
        const panel = test.openPanel(test.appRequest({}));
        const tab = test.findTab(panel.contentItem);
        tryVerify(() => tab.isApplications, 2000);
        tryVerify(() => panel.testWaiting, 2000);
        compare(fakeAppHost.answers.length, 0);
        tab.folder.select(test.rowOf(tab.folder, "org.kde.kate"), 0);
        tryVerify(() => fakeAppHost.answers.length === 1, 2000);
        compare(fakeAppHost.answers[0].map.choice, "org.kde.kate");
    }

    // The shown Sheet under `item` (Sheet.shown), or null.
    // The Save As field: the panel's first TextField.
    function findField(item: var): var {
        if (item instanceof TextField)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const f = test.findField(item.children[i]);
            if (f)
                return f;
        }
        return null;
    }

    function findSheet(item: var, shown: bool): var {
        if (item instanceof Sheet && (!shown || item.shown))
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const s = test.findSheet(item.children[i], shown);
            if (s)
                return s;
        }
        return null;
    }
}
