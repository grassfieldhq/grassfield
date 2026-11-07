pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import qs.lib
import Quickshell.Io
import Grassfield.Ui
import qs.services
import qs.store
import "IconsLogic.js" as Logic
import "../dock/DockModel.js" as DockModel // layering-exception: GF-087

// The desktop folder as a model (one instance, owned by DesktopIcons), the persisted icon slots, and every file operation of the desktop
// icons (docs/specs/desktop.md). Nothing here touches a file unless a function below is called by an
// explicit user action; every operation is one argv (gio / cp / wl-copy), never a shell string.
// Folder: $GRASSFIELD_DESKTOP_DIR, else (dev) <state>/desktop-sandbox so a dev shell never reads the
// real desktop, else `xdg-user-dir DESKTOP`, else ~/Desktop.
// Slots: desktop-icons.json in $GRASSFIELD_STATE_HOME (dev) or $XDG_STATE_HOME/grassfield, mode 0600
// in a 0700 directory, written atomically, keyed by file name; names that no longer exist are pruned.
Scope {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string stateDir: Mode.stateDir
    readonly property string positionsPath: stateDir + "/desktop-icons.json"

    // Resolved desktop folder ("" until known).
    property string dir: ""
    // [{name, path, isDir}] in name order, "" entries never.
    property var entries: []
    readonly property var names: entries.map(e => e.name)
    // {name: {col, row}}; the view assigns slots, the singleton persists them.
    property var positions: ({})
    property bool positionsLoaded: false
    // The first complete listing of the resolved folder is in `entries` (never true for the placeholder folder or a listing
    // still running); false again while the folder changes.
    property bool entriesListed: false
    onDirChanged: entriesListed = false
    // A name to select and rename as soon as it shows up (after New Folder).
    property string pendingRename: ""
    // Names with an operation in flight: never pruned meanwhile.
    property var busy: []
    // New Folder passes over at most this many names that turn out to exist.
    readonly property int newFolderRetries: 3
    property var releasing: []
    // Last failed operation, for the view (empty when fine).
    property string lastError: ""

    signal renameWanted(string name)
    // New Folder could not create the folder (no rename will follow).
    signal newFolderFailed
    // An accepted rename that the file system refused (the view shows it inline).
    signal renameFailed(string name, string reason)

    // ---- desktop folder ------------------------------------------------------------------------

    function resolve(): void {
        const override = Mode.devValue("DESKTOP_DIR");
        if (override) {
            dir = Logic.desktopDir(override, "", home);
            return;
        }
        if (Mode.dev) {
            // Never the real desktop in a development session.
            dir = stateDir + "/desktop-sandbox";
            return;
        }
        xdg.running = true;
    }

    function path(name: string): string {
        return dir + "/" + name;
    }

    // ---- operations (explicit user actions only) -------------------------------------------------

    // `env`: extra environment of the process (the isolated app homes of a dev session for "open").
    function run(argv: var, label: string, done: var, env: var): void {
        const p = runner.createObject(root, {
            command: argv,
            label: label,
            done: done ? done : null,
            environment: env ? env : ({})
        });
        p.running = true;
    }

    function markBusy(name: string): void {
        busy = busy.concat([name]);
    }

    // The name stays protected from pruning until the folder model has had time to report the file.
    function unmarkBusy(name: string): void {
        releasing = releasing.concat([name]);
        releaseTimer.restart();
    }

    // Move files to the trash (gio trash). `paths` are absolute. In a dev session the trash is the isolated one
    // under .dev/apps-home (XDG_DATA_HOME of Apps.openEnvironment()), never the owner's (ADR-0011).
    function trash(paths: var): void {
        const list = paths.filter(p => typeof p === "string" && p.startsWith("/"));
        if (list.length === 0)
            return;
        run(["gio", "trash", "--"].concat(list), "trash", () => {
            Trash.refresh();
        }, Apps.openEnvironment());
    }

    // Returns "" when started, else the validation reason (see IconsLogic.validateName).
    function rename(name: string, next: string): string {
        const why = Logic.validateName(next, name, names);
        if (why !== "")
            return why;
        positions = Logic.renamed(positions, name, next);
        scheduleSave();
        markBusy(next);
        // gio move (not gio rename) so that a name starting with "-" is not an option.
        run(["gio", "move", "--no-target-directory", "--", path(name), path(next)], "rename", ok => {
            if (!ok) {
                positions = Logic.renamed(positions, next, name);
                lastError = qsTr("Could not rename \"%1\".").arg(name);
                renameFailed(name, lastError);
            }
            unmarkBusy(next);
            scheduleSave();
        });
        return "";
    }

    // Create "untitled folder" (numbered when taken) and ask the view to rename it. The listing can lag behind the
    // folder (a second New Folder before the first is listed, a folder made elsewhere): names still busy count as
    // taken, and a name that turns out to exist is passed over for the next number (bounded).
    function newFolder(): void {
        createFolder(names.concat(busy), 0);
    }

    function createFolder(taken: var, attempt: int): void {
        const name = Logic.uniqueName(qsTr("untitled folder"), taken);
        pendingRename = name;
        markBusy(name);
        run(["gio", "mkdir", "-p", path(name)], "mkdir", ok => {
            unmarkBusy(name);
            if (ok)
                return;
            if (attempt < root.newFolderRetries) {
                createFolder(taken.concat([name]), attempt + 1);
                return;
            }
            pendingRename = "";
            newFolderFailed();
        });
    }

    // Copy (or move, with `move`) files into the desktop folder under unclaimed names; never overwrites. A name is
    // unclaimed when neither a listed item nor a copy or move still running holds it (takenNames); a hidden file the
    // listing does not show makes the command fail instead (cp --no-clobber, mv --update=none-fail), and the source
    // stays. `onMoved(name)` runs for each move that succeeded. Returns the names the files will have.
    function importPaths(paths: var, move: bool, onMoved: var): var {
        const taken = takenNames();
        const added = [];
        for (const raw of paths) {
            if (typeof raw !== "string")
                continue;
            // An absolute path without "." or ".." segments (a clipboard's "/a/b/.." would move a into the desktop's
            // parent), trailing slashes dropped.
            const src = raw.replace(/\/+$/, "");
            if (!src.startsWith("/") || src.split("/").some(part => part === "." || part === ".."))
                continue;
            if (Logic.dirName(src) === dir)
                continue;
            if (src === dir || dir.startsWith(src + "/"))
                continue;
            const name = Logic.uniqueName(Logic.baseName(src), taken);
            taken.push(name);
            added.push(name);
            markBusy(name);
            const dest = path(name);
            // mv moves folders across file systems and, with --update=none-fail and --no-target-directory, never replaces
            // an existing name nor moves into a folder of that name (gio move does both); cp -a copies folders.
            const argv = move ? ["mv", "--update=none-fail", "--no-target-directory", "--", src, dest] : ["cp", "-a", "--no-clobber", "--no-target-directory", "--", src, dest];
            run(argv, move ? "move" : "copy", ok => {
                unmarkBusy(name);
                if (ok && onMoved)
                    onMoved(name);
            });
        }
        return added;
    }

    // Open a file with its default application. A .desktop file is never executed: it opens as text in
    // the default text editor (the GNOME trust model needs metadata::trusted, not implemented in v1).
    function open(name: string): void {
        const p = path(name);
        if (Logic.isLauncher(name)) {
            openAsText(p);
            return;
        }
        Apps.whenScopeKnown(() => root.run(Apps.scoped(Apps.folderAware(["gio", "open", p])), "open", null, Apps.openEnvironment()));
    }

    function openAsText(p: string): void {
        textEditor.target = p;
        textEditor.running = true;
    }

    // Copy file URIs to the clipboard (text/uri-list).
    function copy(paths: var): void {
        if (paths.length === 0)
            return;
        run(["wl-copy", "--type", "text/uri-list", Logic.uriList(paths)], "copy to clipboard", null);
    }

    // Files on the clipboard (local paths of a text/uri-list), read when the desktop menu opens (refreshClipboard).
    property var clipboardPaths: []
    // The clipboard's files were cut (Files' Cut, or another file manager's): Paste moves them (IconsLogic.parseClipboardProbe).
    property bool clipboardCut: false
    // The clipboard's uri list as it was read (IconsLogic.parseClipboardProbe): emptied after a move only if unchanged.
    property string clipboardUriText: ""
    // Ctrl+V: paste as soon as the clipboard has been read.
    property bool pasteAfterRead: false

    function refreshClipboard(): void {
        if (clipboardProbe.running)
            return;
        clipboardProbe.running = true;
    }

    function pasteFromClipboard(): void {
        pasteAfterRead = true;
        refreshClipboard();
    }

    // Paste Item(s): copies of the clipboard's files on the desktop, under unclaimed names (never overwrites); an item
    // that already lives on the desktop gets a "copy" next to it, as on macOS. Cut items are moved here instead, as
    // Files' Paste moves them, and the cut is forgotten once one of them has moved; the clipboard is emptied then only if
    // it still holds that very list (anything copied while a slow move ran stays). An item already on the desktop stays
    // where it is; a cut where nothing moved keeps the clipboard.
    function paste(): var {
        if (clipboardCut) {
            let forgotten = false;
            const expected = clipboardUriText;
            return importPaths(clipboardPaths, true, () => {
                if (forgotten)
                    return;
                forgotten = true;
                clipboardCut = false;
                clipboardPaths = [];
                clipboardUriText = "";
                if (expected !== "")
                    clipboardCheck.createObject(root, {expected: expected}).running = true;
            });
        }
        const here = clipboardPaths.filter(p => Logic.dirName(p) === dir).map(p => Logic.baseName(p)).filter(n => names.indexOf(n) >= 0);
        return importPaths(clipboardPaths, false, null).concat(duplicate(here));
    }

    // Get Info: Grassfield Files' Get Info window of each path (macOS model). A dev session runs the dev build
    // (GRASSFIELD_FILES_CMD) with the isolated environment.
    function showInfo(paths: var): void {
        const list = paths.filter(p => typeof p === "string" && p.startsWith("/"));
        if (list.length === 0)
            return;
        const cmd = (Mode.devValue("FILES_CMD") || "grassfield-files").split(" ").filter(w => w !== "");
        const argv = cmd.concat(["--info", "--"]).concat(list);
        Apps.whenScopeKnown(() => Quickshell.execDetached({
                "command": Apps.scoped(argv),
                "environment": Apps.launchEnvironment()
            }));
    }

    // The names a new item may not take: listed ones and those of operations still in flight.
    function takenNames(): var {
        return names.concat(busy);
    }

    function isDir(name: string): bool {
        return entries.some(e => e.name === name && e.isDir);
    }

    // Duplicate: "Report copy.pdf" next to each item (cp -a, never overwrites).
    function duplicate(itemNames: var): var {
        const taken = takenNames();
        const added = [];
        for (const name of itemNames) {
            const copy = Logic.copyName(name, taken, isDir(name));
            taken.push(copy);
            added.push(copy);
            markBusy(copy);
            run(["cp", "-a", "--no-clobber", "--no-target-directory", "--", path(name), path(copy)], "duplicate", () => unmarkBusy(copy));
        }
        return added;
    }

    // Make Alias: "Report.pdf alias", a symbolic link to the item (the Linux counterpart of a Finder alias).
    function makeAlias(itemNames: var): var {
        const taken = takenNames();
        const added = [];
        for (const name of itemNames) {
            const alias = Logic.aliasName(name, taken);
            taken.push(alias);
            added.push(alias);
            markBusy(alias);
            run(["ln", "-s", "--", path(name), path(alias)], "make alias", () => unmarkBusy(alias));
        }
        return added;
    }

    // Compress: one zip archive of the items ("Report.pdf.zip", or "Archive.zip" for several), as macOS does. Names are
    // given as ./name so that none is read as an option.
    function compress(itemNames: var): string {
        if (itemNames.length === 0)
            return "";
        const archive = Logic.archiveName(itemNames, takenNames());
        markBusy(archive);
        run(["bsdtar", "-a", "-cf", path(archive), "-C", dir].concat(itemNames.map(n => "./" + n)), "compress", () => unmarkBusy(archive));
        return archive;
    }

    // Clean Up By: the metadata of every item ({name: {isDir, size, modified, created}}), then `done(meta)`.
    property var statDone: null

    function readMeta(done: var): void {
        if (statProbe.running || dir === "")
            return;
        statDone = done;
        statProbe.command = ["stat", "-c", "%F|%s|%Y|%W|%n", "--"].concat(names.map(n => path(n)));
        statProbe.running = true;
    }

    // Open With ▸ of the selection: the apps that open every selected item, the default handler first (read when the
    // icon menu opens). `openWithResolved` keeps the real types for the launch. One lookup at a time: a newer selection
    // waits (only the latest) and an older answer is dropped, never shown for another selection.
    property var openWithApps: []
    property var openWithPaths: []
    property var openWithResolved: ({})
    property var openWithPending: null

    function resolveOpenWith(paths: var): void {
        openWithApps = [];
        openWithPaths = [];
        if (paths.length === 0 || paths.length > 32)
            return;
        if (typeProbe.running || defaultProbe.running) {
            openWithPending = paths.slice();
            return;
        }
        startOpenWith(paths);
    }

    function startOpenWith(paths: var): void {
        openWithPaths = paths.slice();
        openWithResolved = {};
        typeProbe.command = ["timeout", "10", "sh", Quickshell.shellPath("dock/file-types.sh")].concat(openWithPaths);
        typeProbe.running = true;
    }

    // The lookup of openWithPaths ended (defaultId: the default handler's entry id, "" when unknown); a newer request
    // made meanwhile replaces it.
    function finishOpenWith(defaultId: string): void {
        if (openWithPending !== null) {
            const next = openWithPending;
            openWithPending = null;
            startOpenWith(next);
            return;
        }
        openWithApps = Apps.appsFor(openWithPaths, openWithResolved, defaultId);
    }

    // Opens `paths` with the app chosen in Open With ▸ (the Dock's launch path: field codes, isolated environment). Only
    // the selection the list was made for: anything else would open files the user did not pick.
    function openWith(appId: string, paths: var): void {
        const entry = Apps.lookup(appId);
        if (!entry || paths.join("\n") !== openWithPaths.join("\n"))
            return;
        Apps.openWith(entry, paths, openWithResolved);
    }

    Process {
        id: typeProbe
        stdout: StdioCollector {
            onStreamFinished: {
                if (root.openWithPending !== null) {
                    root.finishOpenWith("");
                    return;
                }
                root.openWithResolved = DockModel.parseResolved(root.openWithPaths, text);
                const first = root.openWithResolved[root.openWithPaths[0]];
                if (first && first !== "-") {
                    defaultProbe.command = ["xdg-mime", "query", "default", first];
                    defaultProbe.running = true;
                } else {
                    root.finishOpenWith("");
                }
            }
        }
    }

    Process {
        id: defaultProbe
        stdout: StdioCollector {
            onStreamFinished: root.finishOpenWith(text.trim().replace(/\.desktop$/, ""))
        }
    }

    Process {
        id: clipboardProbe
        // Only a text/uri-list offer is read; anything else (text, images) leaves Paste out. The first line says whether
        // the files were cut: KDE's application/x-kde-cutselection is "1", or GNOME's x-special/gnome-copied-files
        // starts with "cut" (Files writes both next to the list, as Dolphin and Nautilus write theirs).
        command: ["sh", "-c", "t=$(wl-paste --list-types 2>/dev/null) || exit 0\n"
            + "printf '%s\\n' \"$t\" | grep -qx text/uri-list || exit 0\n"
            + "cut=0\n"
            + "if printf '%s\\n' \"$t\" | grep -qx application/x-kde-cutselection; then\n"
            + "  [ \"$(wl-paste --no-newline --type application/x-kde-cutselection 2>/dev/null)\" = 1 ] && cut=1\n"
            + "elif printf '%s\\n' \"$t\" | grep -qx x-special/gnome-copied-files; then\n"
            + "  [ \"$(wl-paste --no-newline --type x-special/gnome-copied-files 2>/dev/null | head -n 1)\" = cut ] && cut=1\n"
            + "fi\n"
            + "echo cut=$cut\n"
            + "wl-paste --no-newline --type text/uri-list 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const probe = Logic.parseClipboardProbe(text);
                root.clipboardPaths = probe.paths;
                root.clipboardCut = probe.cut && probe.paths.length > 0;
                root.clipboardUriText = probe.uriText;
                if (root.pasteAfterRead) {
                    root.pasteAfterRead = false;
                    root.paste();
                }
            }
        }
    }

    Process {
        id: statProbe
        stdout: StdioCollector {
            onStreamFinished: {
                const done = root.statDone;
                root.statDone = null;
                if (done)
                    done(Logic.parseStat(text));
            }
        }
    }

    // ---- positions -------------------------------------------------------------------------------

    function setPositions(next: var): void {
        positions = next;
        scheduleSave();
    }

    function scheduleSave(): void {
        saveTimer.restart();
    }

    function rebuild(): void {
        if (model.status !== FolderListModel.Ready) {
            return;
        }
        const list = [];
        // The model starts on the process's working directory (often $HOME) before its folder is set: a row whose parent is not
        // the desktop folder belongs to that stale listing and is never shown (nor is the listing taken as complete).
        let stale = dir === "" || String(model.folder) !== String(Qt.url(folderUrl));
        for (let i = 0; i < model.count && !stale; i++) {
            if (Logic.dirName(String(model.get(i, "filePath"))) !== dir)
                stale = true;
        }
        if (stale) {
            entriesListed = false;
            return;
        }
        for (let i = 0; i < model.count; i++) {
            const name = String(model.get(i, "fileName"));
            if (name !== "" && name.indexOf("/") < 0)
                list.push({
                    name: name,
                    path: path(name),
                    isDir: model.get(i, "fileIsDir") === true
                });
        }
        entries = list;
        entriesListed = true;
        // Names that are not in a complete listing of the real folder are not "gone": nothing is pruned before it.
        if (positionsLoaded) {
            const keep = Logic.prune(positions, names.concat(busy));
            if (Object.keys(keep).length !== Object.keys(positions).length) {
                positions = keep;
                scheduleSave();
            }
        }
        if (pendingRename !== "" && names.indexOf(pendingRename) >= 0) {
            const n = pendingRename;
            pendingRename = "";
            renameWanted(n);
        }
    }

    Component.onCompleted: {
        resolve();
        prepare.running = true;
    }

    readonly property string folderUrl: root.dir !== "" ? "file://" + Logic.uriPath(root.dir) : "file:///grassfield-desktop-unresolved"

    FolderListModel {
        id: model
        folder: root.folderUrl
        showDirs: true
        showFiles: true
        showHidden: false
        showDotAndDotDot: false
        showOnlyReadable: false
        sortField: FolderListModel.Name
        onCountChanged: refresh.restart()
        onStatusChanged: refresh.restart()
        onRowsInserted: refresh.restart()
        onRowsRemoved: refresh.restart()
        onDataChanged: refresh.restart()
        onModelReset: refresh.restart()
    }

    Timer {
        id: releaseTimer
        interval: 1000
        onTriggered: {
            const next = root.busy.slice();
            for (const n of root.releasing) {
                const i = next.indexOf(n);
                if (i >= 0)
                    next.splice(i, 1);
            }
            root.releasing = [];
            root.busy = next;
            root.rebuild();
        }
    }

    Timer {
        id: refresh
        interval: 60
        onTriggered: root.rebuild()
    }

    // ---- folder looks (Customize Folder in Files; docs/specs/files.md) ------------------------------------

    // {path: {color, glyph}} from the attribute user.grassfield.folder of the desktop's folders (read with getfattr, one
    // process for all of them; without it the folders just show the global colour), and from the per-user fallback
    // store folder-styles.json next to grassfield.json (FileView; its serial also moves on every attribute write by
    // Files, so one watch covers both).
    property var folderAttributes: ({})
    property var folderStore: ({})
    readonly property string configDir: Mode.configDir

    // The look of a desktop item by name ({color, glyph}, empty fields for files and folders without one).
    function folderStyle(name: string): var {
        return FolderStyle.lookup(path(name), folderStore, folderAttributes);
    }

    onEntriesChanged: styleRefresh.restart()

    Timer {
        id: styleRefresh
        interval: 150
        onTriggered: {
            const paths = root.entries.filter(e => e.isDir).map(e => root.path(e.name));
            if (paths.length === 0) {
                root.folderAttributes = ({});
                return;
            }
            if (attributes.running)
                styleRefresh.restart();
            else {
                attributes.command = ["getfattr", "-h", "-d", "-e", "hex", "-m", "^user\\.grassfield\\.folder$", "--absolute-names", "--"].concat(paths);
                attributes.running = true;
            }
        }
    }

    Process {
        id: attributes
        stdout: StdioCollector {
            onStreamFinished: root.folderAttributes = FolderStyle.parseGetfattr(text)
        }
        stderr: StdioCollector {}
    }

    // The config directory may not exist yet on a fresh account; the watch needs it (WatchedDir).
    WatchedDir {
        id: configWatch
        path: root.configDir
    }

    FileView {
        id: styleStore
        path: configWatch.ready ? root.configDir + "/folder-styles.json" : ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const r = FolderStyle.parseStore(styleStore.text());
            root.folderStore = r.folders;
            // A write by Files (attribute or store): read the attributes of the shown folders again.
            styleRefresh.restart();
        }
        onLoadFailed: root.folderStore = ({})
    }

    Process {
        id: xdg
        command: ["xdg-user-dir", "DESKTOP"]
        stdout: StdioCollector {
            onStreamFinished: root.dir = Logic.desktopDir("", text, root.home)
        }
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            // qmllint enable signal-handler-parameters
            if (exitCode !== 0 && root.dir === "")
                root.dir = Logic.desktopDir("", "", root.home);
        }
    }

    // Open a text file in the default text editor: look the application up (gio mime), then gtk-launch.
    Process {
        id: textEditor
        property string target: ""
        command: ["gio", "mime", "text/plain"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = /Default application for .*?:\s*(\S+\.desktop)/.exec(text);
                if (m && textEditor.target !== "")
                    Apps.openDetached(["gtk-launch", m[1].replace(/\.desktop$/, ""), textEditor.target]);
            }
        }
    }

    // After a cut's move: the clipboard's uri list read again; emptied only when it is still the cut's own list.
    Component {
        id: clipboardCheck

        Process {
            id: check
            property string expected: ""
            command: ["wl-paste", "--no-newline", "--type", "text/uri-list"]
            stdout: StdioCollector {
                onStreamFinished: {
                    if (check.expected !== "" && text === check.expected)
                        root.run(["wl-copy", "--clear"], "clear the clipboard after a move", null);
                    check.destroy();
                }
            }
        }
    }

    Component {
        id: runner

        Process {
            id: proc
            property string label: ""
            property var done: null
            stderr: StdioCollector {
                id: err
            }
            // qmllint disable signal-handler-parameters
            onExited: exitCode => {
                // qmllint enable signal-handler-parameters
                const ok = exitCode === 0;
                if (!ok) {
                    console.warn("desktop icons: " + proc.label + " failed (" + exitCode + "): " + err.text.trim());
                    root.lastError = proc.label;
                }
                if (proc.done)
                    proc.done(ok);
                proc.destroy();
            }
        }
    }

    // ---- positions file --------------------------------------------------------------------------

    // Directory 0700, file 0600 before the first write (FileView cannot set modes).
    Process {
        id: prepare
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", root.stateDir, root.positionsPath]
        onRunningChanged: {
            if (!running)
                file.path = root.positionsPath;
        }
    }

    FileView {
        id: file
        printErrors: false
        atomicWrites: true
        onLoaded: {
            const r = Logic.parse(file.text());
            if (!r.ok && file.text().trim() !== "") {
                console.warn("desktop icons: " + root.positionsPath + " is not a version 1 file; keeping a copy as .bak and starting empty");
                Quickshell.execDetached(["cp", "-p", root.positionsPath, root.positionsPath + ".bak"]);
            }
            root.positions = r.positions;
            root.positionsLoaded = true;
            root.rebuild();
        }
        onLoadFailed: {
            root.positionsLoaded = true;
            root.rebuild();
        }
    }

    Timer {
        id: saveTimer
        interval: Tokens.desktopIconSaveMs
        onTriggered: {
            if (root.positionsLoaded)
                file.setText(Logic.serialize(root.positions));
        }
    }
}
