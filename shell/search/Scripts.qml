pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform
import qs.services
import "Scripts.js" as Scripts

// The user's script commands as palette entries (ADR-0067 D-3; docs/specs/command-palette.md slice X2). The folders are the default
// one ($XDG_DATA_HOME/grassfield/script-commands/, made only by "Open Scripts Folder") and Settings > Search > Scripts'
// (search.scriptFolders). script-scan.py judges each file (regular, the user's, not group- or world-writable, executable, at most
// 256 KiB, a link only to such a file; the folder the same); Scripts.js reads the headers (ScriptMeta.js) and builds the entries;
// inotify (watch-scripts.sh) and each opening of Search read the folders again. Nothing here runs a script: an entry's run only
// emits `runRequested`, which the approval gate (X7) will take; until then it is connected to nothing and a script never runs.
// `entries` is a provider for Commands.build.
Scope {
    id: root

    // search.showScripts: off, no entry and no scan.
    property bool showScripts: true
    // search.scriptFolders as saved.
    property var folderSettings: []
    property string home: Quickshell.env("HOME")
    property string dataHome: Apps.dataHome
    // Search is open: the folders are read again (a link's target is not watched).
    property bool open: false
    property string screenName: ""
    // How a folder is shown in the file manager (replaced by the tests: they must start no application).
    property var opener: argv => Apps.openDetached(argv)

    // A script was chosen (the gate decides whether it runs).
    signal runRequested(var script, var args, string origin)

    readonly property var folders: Scripts.folders(folderSettings, home, dataHome)
    readonly property string defaultFolder: folders[0]
    readonly property string scanTool: Quickshell.shellPath("search/script-scan.py")
    readonly property string watchTool: Quickshell.shellPath("search/watch-scripts.sh")

    // The last scan: {scripts, problems}.
    property var listing: ({scripts: [], problems: []})
    property bool scanned: false
    property string problemsKey: ""
    // Folders that existed at the last scan (the watcher covers these).
    property var watched: []

    readonly property var entries: {
        if (!root.showScripts)
            return [];
        const t = {subtitle: qsTr("Script command"), keywordScript: qsTr("script")};
        const refuses = () => SessionState.refuses("search");
        const list = Scripts.entries(root.listing.scripts, t, refuses, (s, a, o) => root.runRequested(s, a, o));
        list.push({id: "script.open-folder", title: qsTr("Open Scripts Folder"), subtitle: qsTr("Script command"),
            keywords: [qsTr("scripts"), qsTr("folder")], keywordsEn: ["scripts folder"], glyph: "folder", kind: "script", provider: "scripts",
            available: true, run: () => {
                if (!refuses())
                    root.openFolder();
            }});
        return list;
    }

    function rescan(): void {
        if (!root.showScripts)
            return;
        if (scan.running) {
            scan.again = true;
            return;
        }
        scan.command = ["python3", "-I", root.scanTool].concat(root.folders);
        scan.running = true;
    }

    // Makes the default folder (0700) when it is not there, then shows it in the file manager.
    function openFolder(): void {
        make.running = true;
    }

    Process {
        id: scan
        property bool again: false
        stdout: StdioCollector {
            onStreamFinished: {
                const report = Scripts.parseScan(text);
                if (report === null) {
                    console.warn("scripts: the folder scan gave no report");
                    return;
                }
                root.listing = Scripts.listing(report);
                root.watched = report.folders.filter(f => f.status !== "missing").map(f => f.path);
                root.scanned = true;
                // Said once per change, with the path quoted (a file name can hold anything).
                const key = JSON.stringify(root.listing.problems);
                if (key !== root.problemsKey) {
                    root.problemsKey = key;
                    for (const p of root.listing.problems)
                        console.info("scripts: not listed:", JSON.stringify(p.path), p.reason);
                }
            }
        }
        onRunningChanged: {
            if (!running && again) {
                again = false;
                root.rescan();
            }
        }
    }

    Process {
        id: make
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 -- \"$1\"", "sh", root.defaultFolder]
        onExited: (code, status) => {
            if (code !== 0)
                return;
            root.rescan();
            root.opener(["xdg-open", root.defaultFolder]);
        }
    }

    // inotify over the folders that exist; started again when that set changes. A watcher that ends by itself (no inotifywait) is
    // not restarted: the folders are read again when Search opens.
    Process {
        id: watcher
        property bool restart: false
        stdout: SplitParser {
            onRead: debounce.restart()
        }
        onRunningChanged: {
            if (!running && restart) {
                restart = false;
                root.syncWatch();
            }
        }
    }

    function syncWatch(): void {
        if (watcher.running) {
            watcher.restart = true;
            watcher.running = false;
            return;
        }
        if (root.showScripts && root.watched.length > 0) {
            watcher.command = ["sh", root.watchTool].concat(root.watched);
            watcher.running = true;
        }
    }

    Timer {
        id: debounce
        interval: 300
        onTriggered: root.rescan()
    }

    property string watchedKey: ""
    onWatchedChanged: {
        const key = JSON.stringify(root.watched);
        if (key === watchedKey)
            return;
        watchedKey = key;
        syncWatch();
    }
    onFoldersChanged: root.rescan()
    onShowScriptsChanged: {
        if (root.showScripts) {
            root.rescan();
        } else {
            root.listing = {scripts: [], problems: []};
            root.watched = [];
            watcher.restart = false;
            watcher.running = false;
        }
    }
    onOpenChanged: {
        if (root.open)
            root.rescan();
    }
    Component.onCompleted: root.rescan()
}
