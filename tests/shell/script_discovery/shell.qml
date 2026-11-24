pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.search

// Slice X2 on the REAL Scripts component (scripts/dev/test.sh: `qs -p tests/shell/script_discovery`, offscreen; prints
// "script-discovery: PASS" or the failures): the script folders of a scratch home are scanned by script-scan.py (each refusal of
// the file checks has its own proof in tests/shell/script_scan.sh), the headers are parsed, the rows are the entries, the folders
// are watched (a file added or removed shows up without a new scan request), search.showScripts empties the list, a chosen entry
// only asks (runRequested: nothing runs), and Open Scripts Folder makes the default folder 0700. Nothing is run and no
// application is started (the folder opener is replaced).
ShellRoot {
    id: root

    property var failures: []
    property string base: ""
    property string dataHome: "/nonexistent-script-discovery"
    property var asked: []
    property var opened: []
    property string made: ""
    property int step: 0
    property int ticks: 0

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function titles(): string {
        return scripts.entries.map(e => e.title).join("|");
    }

    function problem(path: string): string {
        const p = scripts.listing.problems.find(x => x.path.endsWith(path));
        return p ? p.reason : "";
    }

    Scripts {
        id: scripts
        dataHome: root.dataHome
        home: "/home/nobody"
        opener: argv => root.opened.push(argv.join(" "))
        onRunRequested: (script, args, origin) => root.asked.push({path: script.path, args: args, origin: origin})
    }

    // The scratch home: made by sh, never by the code under test.
    Process {
        id: fixture
        property string phase: "make"
        command: ["sh", "-c", "set -e; b=\"$1\"; rm -rf \"$b\"; mkdir -p -m 700 \"$b/data/grassfield/script-commands\" \"$b/more\"; d=\"$b/data/grassfield/script-commands\"; "
            + "hdr() { printf '#!/bin/sh\\n# @raycast.schemaVersion 1\\n# @raycast.title %s\\n# @raycast.mode silent\\n' \"$1\"; }; "
            + "hdr Good > \"$d/good.sh\"; chmod 700 \"$d/good.sh\"; hdr NoExec > \"$d/noexec.sh\"; chmod 600 \"$d/noexec.sh\"; "
            + "hdr GroupW > \"$d/gw.sh\"; chmod 770 \"$d/gw.sh\"; hdr Tpl > \"$d/x.template.sh\"; chmod 700 \"$d/x.template.sh\"; "
            + "{ hdr Win; echo '# @raycast.platform windows'; } > \"$d/win.sh\"; chmod 700 \"$d/win.sh\"; "
            + "printf '#!/bin/sh\\n# @raycast.schemaVersion 2\\n' > \"$d/bad.sh\"; chmod 700 \"$d/bad.sh\"; "
            + "hdr Extra > \"$b/more/extra.sh\"; chmod 700 \"$b/more/extra.sh\"", "sh", root.base]
        onExited: (code, status) => {
            if (code !== 0) {
                root.failures.push("the scratch home could not be made");
                root.finish();
            } else if (root.step === 0) {
                root.step = 1;
            }
        }
    }

    Process {
        id: mutate
        property int then: 0
        onExited: (code, status) => {
            if (root.step === mutate.then - 1)
                root.step = mutate.then;
        }
    }

    Process {
        id: modeOf
        stdout: StdioCollector {
            onStreamFinished: root.made = text.trim()
        }
    }

    function sh(script: string, next: int): void {
        mutate.command = ["sh", "-c", script, "sh", root.base];
        mutate.then = next;
        mutate.running = true;
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("script-discovery: PASS");
            Qt.exit(0);
        } else {
            console.log("script-discovery: FAIL " + failures.join(", "));
            Qt.exit(1);
        }
    }

    Component.onCompleted: {
        const tmp = Quickshell.env("GRASSFIELD_TEST_TMP") || Quickshell.env("XDG_RUNTIME_DIR");
        if (!tmp) {
            console.log("script-discovery: FAIL no scratch folder (GRASSFIELD_TEST_TMP)");
            Qt.exit(1);
            return;
        }
        base = tmp + "/script-discovery";
        fixture.running = true;
    }

    // One state machine, polled: each step waits for its condition (the scans and the watcher are asynchronous).
    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            root.ticks++;
            if (root.ticks > 400) {
                root.failures.push("timeout in step " + root.step + " (entries: " + root.titles() + ")");
                root.finish();
                return;
            }
            switch (root.step) {
            case 0:
                // Before the fixture: the folder does not exist, only Open Scripts Folder is offered.
                break;
            case 1:
                root.check("a missing default folder lists only Open Scripts Folder [" + root.titles() + "]", root.titles() === "Open Scripts Folder");
                root.dataHome = root.base + "/data";
                root.step = 2;
                break;
            case 2:
                if (root.titles() !== "Good|Open Scripts Folder")
                    break;
                root.check("good.sh is a row", scripts.entries[0].kind === "script" && scripts.entries[0].id.match(/^script\.[0-9a-f]{20}$/) !== null);
                root.check("a non-executable script is not listed (not-executable)", root.problem("noexec.sh") === "not-executable");
                root.check("a group-writable script is not listed (writable)", root.problem("gw.sh") === "writable");
                root.check("a bad header is not listed (header)", root.problem("bad.sh").startsWith("header:schemaVersion"));
                root.check("a template is skipped silently", root.problem("x.template.sh") === "");
                root.check("a windows-only script is hidden silently", root.titles().indexOf("Win") < 0 && root.problem("win.sh") === "");
                root.check("the default folder is first", scripts.folders[0] === root.base + "/data/grassfield/script-commands");
                scripts.folderSettings = [root.base + "/more", "relative/x", "/a/../b", root.base + "/more/", "~/not-there"];
                root.step = 3;
                break;
            case 3:
                if (root.titles() !== "Good|Extra|Open Scripts Folder")
                    break;
                root.check("only valid, distinct folders are read: default, more, ~/not-there [" + scripts.folders.length + "]", scripts.folders.length === 3
                    && scripts.folders[2] === "/home/nobody/not-there");
                root.sh("d=\"$1/data/grassfield/script-commands\"; printf '#!/bin/sh\\n# @raycast.schemaVersion 1\\n# @raycast.title Later\\n# @raycast.mode compact\\n' > \"$d/later.sh\"; chmod 700 \"$d/later.sh\"", 5);
                root.step = 4;
                break;
            case 4:
                break;
            case 5:
                if (root.titles() !== "Good|Later|Extra|Open Scripts Folder")
                    break;
                root.check("a file added later is picked up by the watcher (no scan request)", true);
                root.sh("rm -f \"$1/data/grassfield/script-commands/later.sh\"", 7);
                root.step = 6;
                break;
            case 6:
                break;
            case 7:
                if (root.titles() !== "Good|Extra|Open Scripts Folder")
                    break;
                root.check("a file removed is dropped", true);
                root.sh("chmod 777 \"$1/data/grassfield/script-commands/good.sh\"", 9);
                root.step = 8;
                break;
            case 8:
                break;
            case 9:
                if (root.titles() !== "Extra|Open Scripts Folder")
                    break;
                root.check("a script made group- and world-writable leaves the list at once", root.problem("good.sh") === "writable");
                root.sh("chmod 700 \"$1/data/grassfield/script-commands/good.sh\"", 11);
                root.step = 10;
                break;
            case 10:
                break;
            case 11: {
                if (root.titles() !== "Good|Extra|Open Scripts Folder")
                    break;
                // A chosen entry only asks: nothing runs (the approval gate, X7, is the one that will).
                const e = scripts.entries[0];
                e.run(["a"], "hotkey");
                root.check("run asks (runRequested) with the script, the arguments and the origin", root.asked.length === 1
                    && root.asked[0].path.endsWith("/good.sh") && root.asked[0].args.join() === "a" && root.asked[0].origin === "hotkey");
                scripts.showScripts = false;
                root.check("showScripts off: no entry, no listing", scripts.entries.length === 0 && scripts.listing.scripts.length === 0);
                root.step = 12;
                break;
            }
            case 12:
                scripts.showScripts = true;
                root.step = 13;
                break;
            case 13:
                if (root.titles() !== "Good|Extra|Open Scripts Folder")
                    break;
                root.check("showScripts on again: the rows come back", true);
                // Open Scripts Folder: the default folder is made (0700) and shown.
                scripts.folderSettings = [];
                root.dataHome = root.base + "/data2";
                root.step = 14;
                break;
            case 14:
                if (root.titles() !== "Open Scripts Folder")
                    break;
                scripts.entries[0].run([], "row");
                root.step = 15;
                break;
            case 15:
                if (root.opened.length !== 1)
                    break;
                root.check("Open Scripts Folder opens the default folder [" + root.opened[0] + "]",
                    root.opened[0] === "xdg-open " + root.base + "/data2/grassfield/script-commands");
                modeOf.command = ["stat", "-c", "%a", root.base + "/data2/grassfield/script-commands"];
                modeOf.running = true;
                root.step = 16;
                break;
            case 16:
                if (root.made === "")
                    break;
                root.check("...made 0700 [" + root.made + "]", root.made === "700");
                root.sh("rm -rf \"$1\"", 99);
                root.step = 98;
                break;
            case 98:
                break;
            case 99:
                root.finish();
                break;
            }
        }
    }
}
