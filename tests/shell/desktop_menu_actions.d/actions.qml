pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.desktop

// The desktop menu's file actions on a real DesktopFiles (macOS names): Duplicate ("Notes copy.txt"), Make Alias
// ("Notes.txt alias", a link to the item), Compress (one item: "Notes.txt.zip"; several: "Archive.zip" holding them),
// the metadata Clean Up By orders with (stat), and Paste Item: a cut file is moved onto the desktop, then the cut is
// forgotten and the clipboard emptied (wl-copy --clear, recorded by a stand-in) only while it still holds that cut's
// list (stand-in wl-paste: "SAME"; the two earlier cuts expect another list and clear nothing); a copied one is copied; a cut never
// replaces a hidden file of the same name; two cuts of one name in a row both land; "p/q/.." and "p/q/../q" are refused. Printed:
// "desktop-menu-actions: PASS" or the failure.
ShellRoot {
    id: root

    readonly property string dir: Quickshell.env("GRASSFIELD_DESKTOP_DIR")
    readonly property string outside: Quickshell.env("GF_TEST_OUTSIDE")
    readonly property string wlCopyLog: Quickshell.env("GF_TEST_WLCOPY_LOG")
    property bool started: false
    property var meta: null
    property int waited: 0

    DesktopFiles {
        id: files
    }

    Process {
        id: check
        // One line per fact the actions must have produced, read back from the file system.
        command: ["sh", "-c", 'cd "$1" || exit 1; cat "Notes copy.txt"; readlink "Notes.txt alias"; [ -d "Docs copy" ] && echo dir-copied; bsdtar -tf "Notes.txt.zip"; bsdtar -tf "Archive.zip" | sort; cat Moved.txt; [ -e "$2/Moved.txt" ] || echo source-gone; cat Kept.txt; [ -e "$2/Kept.txt" ] && echo source-kept; printf "secret=%s\\n" "$(cat .secret)"; [ -e "$2/.secret" ] && echo secret-source-kept; printf "dups=%s\\n" "$(cat Dup*.txt | sort | tr "\\n" ,)"; [ -d "$2/p/q" ] && [ ! -e p ] && [ ! -e q ] && echo dotdot-refused; [ "$(grep -cx -- --clear "$3")" = 1 ] && echo clipboard-cleared-once', "sh", root.dir, root.outside, root.wlCopyLog]
        stdout: StdioCollector {
            onStreamFinished: root.verify(text)
        }
    }

    function verify(text: string): void {
        const lines = text.trim().split("\n");
        const want = ["hello", root.dir + "/Notes.txt", "dir-copied", "./Notes.txt", "./Docs/", "./Notes.txt", "moved", "source-gone", "kept", "source-kept", "secret=desk",
            "secret-source-kept", "dups=one,two,", "dotdot-refused", "clipboard-cleared-once"];
        const forgotten = !files.clipboardCut && files.clipboardPaths.length === 0;
        const missing = want.filter(w => lines.indexOf(w) < 0);
        if ((missing.length > 0 || !forgotten) && waited < 40) {
            waited++;
            retry.restart();
            return;
        }
        const docs = meta ? meta["Docs"] : null;
        const notes = meta ? meta["Notes.txt"] : null;
        if (missing.length > 0) {
            console.log("desktop-menu-actions: FAIL: missing " + JSON.stringify(missing) + " in " + JSON.stringify(lines));
            Qt.exit(1);
        } else if (!forgotten) {
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
            files.clipboardCut = false;
            files.clipboardPaths = [root.outside + "/Kept.txt"];
            files.paste();
            // Two cuts of one name before the listing catches up: the second takes another name (takenNames).
            files.clipboardCut = true;
            files.clipboardUriText = "OTHER";
            files.clipboardPaths = [root.outside + "/Dup.txt"];
            files.paste();
            files.clipboardCut = true;
            files.clipboardUriText = "OTHER";
            files.clipboardPaths = [root.outside + "/b/Dup.txt"];
            files.paste();
            // A cut where every move fails (a hidden file of that name is there) leaves the clipboard alone.
            files.clipboardCut = true;
            files.clipboardUriText = "SAME";
            files.clipboardPaths = [root.outside + "/.secret"];
            files.paste();
            files.clipboardCut = true;
            files.clipboardUriText = "SAME";
            files.clipboardPaths = [ root.outside + "/p/q/..", root.outside + "/p/q/../q", root.outside + "/Moved.txt"];
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
