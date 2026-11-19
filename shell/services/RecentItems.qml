pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Io
import "RecentItemsLogic.js" as Logic
import "../search/Files.js" as Files // layering-exception: GF-087
import "../dock/DockModel.js" as DockModel // layering-exception: GF-087

// Recent Items of the Grassfield menu (macOS Apple menu > Recent Items): the applications the shell launched (every
// launch goes through Apps.launch: Dock, Apps, Search, menus) and the recently used documents (recently-used.xbel, read
// only: other applications share it). Clear Menu empties the applications and hides the documents used before it,
// without touching that file. State: $GRASSFIELD_STATE_HOME or $XDG_STATE_HOME/grassfield/recent-items.json (0600).
Singleton {
    id: root

    // Settings > Menu Bar > Recent items (macOS: Recent documents, applications, and servers); 0 hides the submenu.
    readonly property int max: Settings.menubarRecentItems
    readonly property string home: Quickshell.env("HOME")
    // Documents outside this root ($HOME; in a dev session never $HOME, see Apps.searchRoot) are not listed.
    readonly property string filesRoot: Apps.searchRoot
    // Dev session: the dev apps-home, never the owner's recent files.
    readonly property string dataHome: Apps.dataHome
    readonly property string stateDir: Mode.stateDir
    readonly property string statePath: stateDir + "/recent-items.json"

    property var state: ({apps: [], clearedAt: 0})
    property var documentList: []
    // The state file was read (or could not be). Launches made before that wait in `early` ({id, at}): written at once they
    // would replace the file with that one launch, and the read would then put the old list back in memory.
    property bool stateRead: false
    property var early: []

    function stateLoaded(state: var): void {
        root.state = state;
        if (root.stateRead)
            return;
        root.stateRead = true;
        const waited = root.early;
        root.early = [];
        for (const l of waited)
            root.state = Logic.withLaunch(root.state, l.id, l.at, 50);
        if (waited.length > 0)
            root.save();
    }

    readonly property var applications: {
        void Apps.revision;
        // Named in the shell's language (Apps.displayName).
        return Logic.applications(root.state, root.max, id => {
            const entry = Apps.lookup(id);
            return entry ? {name: Apps.displayName(entry)} : null;
        });
    }
    readonly property var documents: Logic.documents(root.documentList, root.state, root.max)

    // The documents `entry` (a desktop entry) opened, for its Dock menu (RecentItemsLogic.documentsForApp).
    function documentsFor(entry: var, max: int): var {
        if (!entry)
            return [];
        root.freshDocuments();
        const args = DockModel.entryArgs(entry);
        return Logic.documentsForApp(root.documentList, {name: entry.name ? String(entry.name) : "", cmd: args.length > 0 ? String(args[0]) : ""}, root.state, max);
    }

    // The submenu rows of the Grassfield menu (PopupMenu model).
    function menu(): var {
        root.freshDocuments();
        return Logic.menu(root.applications, root.documents, {
            applications: qsTr("Applications"),
            documents: qsTr("Documents"),
            clear: qsTr("Clear Menu")
        });
    }

    function clear(): void {
        root.state = Logic.cleared(root.state, Date.now());
        save();
    }

    function save(): void {
        if (stateFile.path !== "")
            stateFile.setText(JSON.stringify(root.state));
    }

    Connections {
        target: Apps

        function onLaunched(appId: string): void {
            if (!root.stateRead) {
                root.early = root.early.concat([{id: appId, at: Date.now()}]);
                return;
            }
            root.state = Logic.withLaunch(root.state, appId, Date.now(), 50);
            root.save();
        }
    }

    Process {
        id: prepare
        running: true
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", root.stateDir, root.statePath]
        onRunningChanged: {
            if (!running)
                stateFile.path = root.statePath;
        }
    }

    FileView {
        id: stateFile
        printErrors: false
        atomicWrites: true
        onLoaded: {
            try {
                root.stateLoaded(Logic.normalize(JSON.parse(stateFile.text() || "{}")));
            } catch (e) {
                root.stateLoaded(Logic.normalize(null));
            }
        }
        // An unreadable file: the launches go on from what is in memory.
        onLoadFailed: root.stateLoaded(root.state)
    }

    // The documents (recently-used.xbel: GTK applications rewrite it at every file they open, and it can hold hundreds of KB) are
    // read and parsed only when they are needed: a change marks them stale (audit fluidity note: the whole file was read and
    // parsed with regular expressions on the GUI thread at every rewrite). They are read once the changes have settled
    // (xbelSettle), or at once when a menu that lists them opens (menu(), documentsFor()).
    property bool documentsStale: true
    // The parses made (tests).
    property int documentParses: 0

    function freshDocuments(): void {
        if (!root.documentsStale)
            return;
        xbelSettle.stop();
        recentFile.reload();
        recentFile.waitForJob();
    }

    FileView {
        id: recentFile
        path: root.dataHome + "/recently-used.xbel"
        preload: false
        printErrors: false
        watchChanges: true
        onFileChanged: {
            root.documentsStale = true;
            xbelSettle.restart();
        }
        onLoaded: {
            root.documentsStale = false;
            root.documentParses++;
            root.documentList = Files.parseXbel(recentFile.text(), root.filesRoot);
        }
        // No file (no application recorded a document yet): no documents.
        onLoadFailed: {
            root.documentsStale = false;
            root.documentList = [];
        }
    }

    Timer {
        id: xbelSettle
        interval: 2000
        running: true
        onTriggered: {
            if (root.documentsStale)
                recentFile.reload();
        }
    }
}
