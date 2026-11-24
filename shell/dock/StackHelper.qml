pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.lib
import "Stacks.js" as Stacks

// One folder kept in the Dock as a stack, served by ONE native helper process (ADR-0025, apps/stack-helper): it lists the folder,
// keeps the window of its first `limit` entries in the stack's order (the order of Files for Name: it is Files' own code), watches
// the folder with inotify and writes the window when it changed. This object starts it, tells it the order and the size of the
// window, and reads its lines (Stacks.parseWindow: a few milliseconds for 300 entries, never a long call). The pile of a tile asks
// for 30 entries, an open popup for 300.
QtObject {
    id: root

    property string folder: ""
    property string sort: "dateAdded"
    property int limit: 30
    // With entries outside the window, a scan is asked for only when fewer than this many are left: the entries between `low` and
    // `limit` are the margin that removals (a download is a temporary name that is renamed) use up at no cost. 0: half of the limit.
    property int low: 0
    // [{name, path, isDir, modified, added, created}] in the stack's order.
    property var entries: []
    // The entries of the folder (exact after a scan of the helper, an estimate between two).
    property int total: 0
    // True while the helper watches the folder; false while the folder is gone or cannot be watched.
    property bool watching: false
    // True once a window has arrived for this folder.
    property bool loaded: false

    // A window arrived (also an unchanged one after a restart): the owner may look at `entries`.
    signal arrived

    // Dev: the helper built by apps/stack-helper/build-direct.sh (GRASSFIELD_STACK_HELPER names another, for tests); the session: the package's.
    readonly property string tool: Mode.dev ? (Mode.devValue("STACK_HELPER") || Quickshell.shellPath("../.dev/build/grassfield-stack-helper")) : "/usr/lib/grassfield/grassfield-stack-helper"

    // True between stopping the helper for another folder and starting it again.
    property bool restarting: false

    function send(line: string): void {
        if (root.process.running)
            root.process.write(line + "\n");
    }

    function relist(): void {
        root.send("RELIST");
    }

    // The window being read (Stacks.windowParser), null when none.
    property var parsing: null

    function slice(): void {
        const parser = root.parsing;
        if (parser === null) {
            root.slicer.stop();
            return;
        }
        if (!parser.step(Tokens.dockStackParseSliceMs)) {
            root.slicer.start();
            return;
        }
        root.slicer.stop();
        root.parsing = null;
        root.total = parser.result.total;
        root.entries = parser.result.entries;
        root.loaded = true;
        root.retryMs = 5000;
        root.warned = false;
        root.arrived();
    }

    readonly property Timer slicer: Timer {
        interval: 1
        repeat: true
        onTriggered: root.slice()
    }

    function reset(): void {
        root.parsing = null;
        root.slicer.stop();
        root.entries = [];
        root.total = 0;
        root.watching = false;
        root.loaded = false;
    }

    // The helper ends when this shell is not its parent any more (apps/stack-helper/src/main.cpp). A `var` property: an object
    // literal bound to Process.environment directly is a QVariantMap where it takes a QVariantHash (qmllint incompatible-type).
    readonly property var helperEnvironment: ({ GRASSFIELD_STACK_HELPER_PARENT: String(Quickshell.processId) })
    readonly property Process process: Process {
        running: root.folder !== "" && !root.restarting
        command: [root.tool, root.folder, root.sort, String(root.limit), String(root.low)]
        stdinEnabled: true
        environment: root.helperEnvironment
        stdout: SplitParser {
            onRead: line => {
                if (line === "A") {
                    root.watching = true;
                } else if (line === "G") {
                    root.parsing = null;
                    root.slicer.stop();
                    root.watching = false;
                    root.entries = [];
                    root.total = 0;
                    root.arrived();
                } else if (line.charAt(0) === "W") {
                    // read in slices of a few milliseconds; a newer window replaces one that is still being read
                    const parser = Stacks.windowParser(line, root.folder);
                    if (parser.valid) {
                        root.parsing = parser;
                        root.slice();
                    }
                }
            }
        }
        // what changed between the command line and the start is told now (the helper ignores what it already has)
        onStarted: {
            root.send("SORT " + root.sort);
            root.send("K " + root.limit + " " + root.low);
        }
        // The helper ended (not found, crashed): looked for again in a few seconds, the pile shows what it had.
        onRunningChanged: if (!running) {
            root.watching = false;
            if (root.folder !== "" && !root.restarting) {
                if (!root.loaded && !root.warned) {
                    root.warned = true;
                    console.warn("StackHelper: " + root.tool + " did not run (not built or not installed?): the stack shows its folder icon; asked for again with a growing pause");
                }
                root.retry.restart();
            }
        }
    }

    function restart(): void {
        root.restarting = true;
        Qt.callLater(() => {
            root.restarting = false;
        });
    }

    // A helper that is not there is asked for again after 5 s, then 10, 20, ... up to 5 minutes (a window arriving resets it), and
    // warned about once.
    property int retryMs: 5000
    property bool warned: false

    readonly property Timer retry: Timer {
        interval: root.retryMs
        onTriggered: {
            if (root.folder !== "" && !root.process.running) {
                root.retryMs = Math.min(root.retryMs * 2, 300000);
                root.restart();
            }
        }
    }

    onSortChanged: root.send("SORT " + root.sort)
    onLimitChanged: root.send("K " + root.limit + " " + root.low)
    onLowChanged: root.send("K " + root.limit + " " + root.low)

    // The helper is bound to the folder it was started for: another folder needs another helper.
    onFolderChanged: {
        root.reset();
        root.restart();
    }
}
