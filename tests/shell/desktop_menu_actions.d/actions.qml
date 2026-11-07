pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.desktop

// The desktop menu's file actions on a real DesktopFiles (macOS names): Duplicate ("Notes copy.txt"), Make Alias
// ("Notes.txt alias", a link to the item), Compress (one item: "Notes.txt.zip"; several: "Archive.zip" holding them),
// the metadata Clean Up By orders with (stat), and Paste Item: a cut file is moved onto the desktop and the cut is
// forgotten, a copied one is copied. Printed: "desktop-menu-actions: PASS" or the failure.
ShellRoot {
    id: root

    readonly property string dir: Quickshell.env("GRASSFIELD_DESKTOP_DIR")
    readonly property string outside: Quickshell.env("GF_TEST_OUTSIDE")
    property bool cutForgotten: false
    property bool started: false
    property var meta: null
    property int waited: 0

    DesktopFiles {
        id: files
    }

    Process {
        id: check
        // One line per fact the actions must have produced, read back from the file system.
        command: ["sh", "-c", 'cd "$1" || exit 1; cat "Notes copy.txt"; readlink "Notes.txt alias"; [ -d "Docs copy" ] && echo dir-copied; bsdtar -tf "Notes.txt.zip"; bsdtar -tf "Archive.zip" | sort; cat Moved.txt; [ -e "$2/Moved.txt" ] || echo source-gone; cat Kept.txt; [ -e "$2/Kept.txt" ] && echo source-kept', "sh", root.dir, root.outside]
        stdout: StdioCollector {
            onStreamFinished: root.verify(text)
        }
    }

    function verify(text: string): void {
        const lines = text.trim().split("\n");
        const want = ["hello", root.dir + "/Notes.txt", "dir-copied", "./Notes.txt", "./Docs/", "./Notes.txt", "moved", "source-gone", "kept", "source-kept"];
        const missing = want.filter(w => lines.indexOf(w) < 0);
        if (missing.length > 0 && waited < 40) {
            waited++;
            retry.restart();
            return;
        }
        const docs = meta ? meta["Docs"] : null;
        const notes = meta ? meta["Notes.txt"] : null;
        if (missing.length > 0) {
            console.log("desktop-menu-actions: FAIL: missing " + JSON.stringify(missing) + " in " + JSON.stringify(lines));
            Qt.exit(1);
        } else if (!root.cutForgotten) {
            console.log("desktop-menu-actions: FAIL: the cut was not forgotten after its move");
            Qt.exit(1);
        } else if (!docs || docs.isDir !== true || !notes || notes.size !== 6 || notes.modified <= 0) {
            console.log("desktop-menu-actions: FAIL: metadata " + JSON.stringify(meta));
            Qt.exit(1);
        } else {
            console.log("desktop-menu-actions: PASS");
            Qt.exit(0);
        }
    }

    Timer {
        id: retry
        interval: 100
        onTriggered: check.running = true
    }

    Timer {
        interval: 100
        repeat: true
        running: !root.started
        onTriggered: {
            if (files.dir === "" || files.names.indexOf("Notes.txt") < 0 || files.names.indexOf("Docs") < 0)
                return;
            root.started = true;
            files.duplicate(["Notes.txt", "Docs"]);
            files.makeAlias(["Notes.txt"]);
            files.compress(["Notes.txt"]);
            files.compress(["Notes.txt", "Docs"]);
            files.clipboardPaths = [root.outside + "/Moved.txt"];
            files.clipboardCut = true;
            files.paste();
            root.cutForgotten = !files.clipboardCut && files.clipboardPaths.length === 0;
            files.clipboardPaths = [root.outside + "/Kept.txt"];
            files.paste();
            files.readMeta(m => {
                root.meta = m;
                check.running = true;
            });
        }
    }

    Timer {
        interval: 30000
        running: true
        onTriggered: {
            console.log("desktop-menu-actions: FAIL (timeout)");
            Qt.exit(1);
        }
    }
}
