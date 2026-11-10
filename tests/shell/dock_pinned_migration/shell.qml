pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.store

// The Dock's default pins and their migration (ADR-0055 D-7), through the real SettingsStore reading real files: no stored list,
// and the two default lists of the earlier releases (["foot","chromium","org.gnome.Nautilus"], then
// ["chromium","foot","org.grassfield.Settings"]), read as the current default (Sanaga, Notes, Terminal, Settings); a list that is a
// variation of one of them, a list the user made, and an emptied list are the user's and stay as they are. Nothing is written back.
// The file is rewritten under ONE live store, step by step. Offscreen (scripts/dev/test.sh: `qs -p tests/shell/dock_pinned_migration`).
// Prints "dock-pinned-migration: PASS" or the failing step.
ShellRoot {
    id: root

    readonly property string base: (Quickshell.env("GRASSFIELD_TEST_TMP") || "/tmp") + "/gf-pinned-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)
    readonly property var current: ["sanaga", "grassfield-notes", "foot", "org.grassfield.Settings"]

    // text of the file, then the dock.pinned the store must read
    readonly property var steps: [
        {text: '{"version":1}', want: root.current},
        {text: '{"version":1,"dock":{"pinned":["foot","chromium","org.gnome.Nautilus"]}}', want: root.current},
        {text: '{"version":1,"dock":{"pinned":["chromium","foot","org.grassfield.Settings"]}}', want: root.current},
        {text: '{"version":1,"dock":{"pinned":["chromium","foot","org.grassfield.Settings","kate"]}}', want: ["chromium", "foot", "org.grassfield.Settings", "kate"]},
        {text: '{"version":1,"dock":{"pinned":["foot","chromium","org.gnome.Nautilus","kate"]}}', want: ["foot", "chromium", "org.gnome.Nautilus", "kate"]},
        {text: '{"version":1,"dock":{"pinned":["foot","chromium"]}}', want: ["foot", "chromium"]},
        {text: '{"version":1,"dock":{"pinned":["org.grassfield.Settings","foot","chromium"]}}', want: ["org.grassfield.Settings", "foot", "chromium"]},
        {text: '{"version":1,"dock":{"pinned":[]}}', want: []},
        {text: '{"version":1,"dock":{"pinned":["sanaga","grassfield-notes","foot","org.grassfield.Settings"]}}', want: root.current}
    ]

    property int step: -1
    property int tries: 0
    property bool finished: false

    function finish(ok: bool, message: string): void {
        if (root.finished)
            return;
        root.finished = true;
        console.log(ok ? "dock-pinned-migration: PASS (" + root.steps.length + " files)" : "dock-pinned-migration: FAIL " + message);
        cleanup.running = true;
    }

    function next(): void {
        root.step++;
        root.tries = 0;
        if (root.step >= root.steps.length) {
            root.finish(true, "");
            return;
        }
        write.command = ["sh", "-c", 'printf "%s" "$2" > "$1.tmp" && mv "$1.tmp" "$1"', "sh", root.base + "/grassfield.json", root.steps[root.step].text];
        write.running = true;
    }

    Process {
        id: prepare
        command: ["sh", "-c", 'mkdir -p "$1" && printf "%s" "$2" > "$1/grassfield.json"', "sh", root.base, '{"version":1}']
        running: true
        onRunningChanged: {
            if (!running)
                store.configDir = root.base;
        }
    }

    SettingsStore {
        id: store
        saveDelay: 10
        pollInterval: 300 // the file is looked at often: a file watch may lag under load
        onLoadedFile: {
            if (root.step < 0)
                root.next();
        }
    }

    Process {
        id: write
    }

    // Each step: poll until the store reads what a fresh start would, or give up after 15 s.
    Timer {
        interval: 100
        running: root.step >= 0 && !root.finished
        repeat: true
        onTriggered: {
            if (write.running)
                return;
            const want = root.steps[root.step].want;
            if (JSON.stringify(store.dockPinned) === JSON.stringify(want)) {
                root.next();
                return;
            }
            if (++root.tries > 150)
                root.finish(false, "step " + root.step + " (" + root.steps[root.step].text + "): read " + JSON.stringify(store.dockPinned) + ", wanted " + JSON.stringify(want));
        }
    }

    Process {
        id: cleanup
        command: ["rm", "-rf", root.base]
        onRunningChanged: {
            if (!running)
                Qt.exit(root.finished && root.step >= root.steps.length ? 0 : 1);
        }
    }

    Timer {
        interval: 110000
        running: true
        onTriggered: root.finish(false, "timeout at step " + root.step)
    }
}
