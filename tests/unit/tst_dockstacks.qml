import QtQuick
import QtTest
import "../../shell/dock/Stacks.js" as Stacks
import "../../shell/dock/DockModel.js" as DockModel

// Dock folder stacks (REQ-DOCK-PAR-d7): pure logic of shell/dock/Stacks.js and the folder tiles of DockModel.
TestCase {
    name: "DockStacks"

    readonly property string us: "\x1f"

    function test_folderListIsCleanAbsoluteAndDistinct() {
        const list = Stacks.folderList(["~/Downloads", "/home/u/Downloads/", "relative", "/a/../etc", 5, "", "/", "/srv//x/./y", "~"], "/home/u", 12);
        compare(list.join(","), "/home/u/Downloads,/srv/x/y,/home/u");
        compare(Stacks.folderList(null, "/home/u", 12).length, 0);
        compare(Stacks.folderList(["/a", "/b", "/c"], "/h", 2).join(","), "/a,/b");
    }

    function test_optionsDefaultsAndValidation() {
        const d = Stacks.optionsFor({}, "/a");
        compare(d.sort, "dateAdded");
        compare(d.view, "automatic");
        compare(d.display, "stack");
        const o = Stacks.optionsFor({"/a": {sort: "bogus", view: "list", display: 3}}, "/a");
        compare(o.sort, "dateAdded");
        compare(o.view, "list");
        compare(o.display, "stack");
        compare(Stacks.optionsFor(null, "/a").view, "automatic");
    }

    function test_withOptionKeepsOnlyNonDefaults() {
        let all = Stacks.withOption({}, "/a", "view", "grid");
        compare(all["/a"].view, "grid");
        all = Stacks.withOption(all, "/b", "sort", "name");
        compare(Object.keys(all).sort().join(","), "/a,/b");
        all = Stacks.withOption(all, "/a", "view", "automatic");
        compare(Object.keys(all).join(","), "/b");
        // junk: relative keys and unknown values never get stored
        all = Stacks.withOption({"rel": {view: "fan"}}, "/c", "sort", "nonsense");
        compare(Object.keys(all).length, 0);
    }

    // ---- the helper's window line (apps/stack-helper) ----

    function test_unescapeNameUndoesTheHelpersEscapes() {
        compare(Stacks.unescapeName("plain"), "plain");
        compare(Stacks.unescapeName("a\\\\b"), "a\\b");
        compare(Stacks.unescapeName("x\\ny"), "x\ny");
        compare(Stacks.unescapeName("x\\ry\\uz"), "x\ry\x1fz");
    }

    function test_parseWindow() {
        const line = ["W", "7", "120", "2", "one.txt", "0", "10.5", "20.5", "5", "Sub", "1", "1", "2", "3"].join(us);
        const w = Stacks.parseWindow(line, "/home/u/Docs/");
        verify(w !== null);
        compare(w.sequence, 7);
        compare(w.total, 120);
        compare(w.entries.length, 2);
        compare(w.entries[0].path, "/home/u/Docs/one.txt");
        compare(w.entries[0].isDir, false);
        compare(w.entries[0].modified, 10.5);
        compare(w.entries[0].added, 20.5);
        compare(w.entries[0].created, 5);
        compare(w.entries[1].name, "Sub");
        compare(w.entries[1].isDir, true);
    }

    function test_parseWindowRefusesWhatIsNotAWindow() {
        verify(Stacks.parseWindow("A", "/d") === null);
        verify(Stacks.parseWindow("G", "/d") === null);
        verify(Stacks.parseWindow("", "/d") === null);
        verify(Stacks.parseWindow(["W", "1", "5", "2", "only", "0", "1", "1", "1"].join(us), "/d") === null, "fewer fields than announced");
        verify(Stacks.parseWindow(["W", "1", "5", "-1"].join(us), "/d") === null);
        compare(Stacks.parseWindow(["W", "1", "0", "0"].join(us), "/d").entries.length, 0);
    }

    function test_escapesAreReadLeftToRight() {
        // \\n is a backslash and an n, \\\n a backslash and a line break, \n a line break
        compare(Stacks.unescapeName("a\\\\nb"), "a\\nb");
        compare(Stacks.unescapeName("a\\\\\\nb"), "a\\\nb");
        compare(Stacks.unescapeName("\\n\\\\\\r"), "\n\\\r");
        compare(Stacks.unescapeName("\\\\\\\\"), "\\\\");
        compare(Stacks.unescapeName("\\\\u"), "\\u");
        compare(Stacks.unescapeName("\\u"), "\x1f");
    }

    // 300 names of 255 backslashes (510 characters each once escaped) cost about 100 ms to read: the parser works in slices, and
    // no single call of it holds the thread for long
    function test_aHostileWindowIsReadInSlices() {
        const name = "\\\\".repeat(255);
        const fields = ["W", "1", "300", "300"];
        for (let i = 0; i < 300; i++)
            fields.push(name + i, "0", "1", "1", "1");
        const parser = Stacks.windowParser(fields.join(us), "/d");
        verify(parser.valid);
        let longest = 0;
        let calls = 0;
        for (;;) {
            const t0 = Date.now();
            const done = parser.step(6);
            longest = Math.max(longest, Date.now() - t0);
            calls++;
            if (done)
                break;
        }
        compare(parser.result.entries.length, 300);
        compare(parser.result.entries[7].name, "\\".repeat(255) + "7");
        compare(parser.result.total, 300);
        verify(longest < 50, "the longest slice took " + longest + " ms in " + calls + " calls (limit 50; LOAD-SENSITIVE: wall clock)");
    }

    // F22: a byte that is not UTF-8 comes as \xHH: shown as U+FFFD, opened byte for byte through the entry's file: URI.
    function test_aNameThatIsNotUtf8OpensByItsUri() {
        const w = Stacks.parseWindow(["W", "1", "3", "3", "old\\xe9.txt", "0", "0", "0", "0", "a\\\\xe9", "0", "0", "0", "0",
                                      "My File #1.txt", "0", "0", "0", "0"].join(us), "/home/u/Stack");
        compare(w.entries[0].name, "old�.txt");
        compare(w.entries[0].uri, "file:///home/u/Stack/old%E9.txt");
        compare(w.entries[1].name, "a\\xe9", "a real backslash then xe9");
        compare(w.entries[1].uri, "file:///home/u/Stack/a%5Cxe9");
        compare(w.entries[2].uri, "file:///home/u/Stack/My%20File%20%231.txt");
        compare(Stacks.unescapeName("\\xff\\xfe"), "��");
        compare(Stacks.nameUriSegment("a\\nb\\xC3"), "a%0Ab\\xC3".replace("\\xC3", "%5CxC3"), "upper-case hex is no escape of the helper");
        // A stack folder that is itself a URI (a folder entered by its URI) keeps it as it is.
        const nested = Stacks.parseWindow(["W", "1", "1", "1", "x\\xe9", "0", "0", "0", "0"].join(us), "file:///home/u/%E9dir");
        compare(nested.entries[0].uri, "file:///home/u/%E9dir/x%E9");
    }

    function test_aNameWithEscapesKeepsItsBytes() {
        const w = Stacks.parseWindow(["W", "1", "1", "1", "a\\nW\\u1", "0", "0", "0", "0"].join(us), "/d");
        compare(w.entries[0].name, "a\nW\x1f1");
        compare(w.entries[0].path, "/d/a\nW\x1f1");
    }


    function test_automaticViewIsFanThenGrid() {
        compare(Stacks.resolveView("automatic", 3, 9), "fan");
        compare(Stacks.resolveView("automatic", 9, 9), "fan");
        compare(Stacks.resolveView("automatic", 10, 9), "grid");
        compare(Stacks.resolveView("list", 2, 9), "list");
        compare(Stacks.resolveView("grid", 2, 9), "grid");
        compare(Stacks.resolveView(undefined, 2, 9), "fan");
    }

    function test_fanLayout() {
        const l = Stacks.fanLayout(5, 56, 80);
        compare(l.length, 5);
        compare(l[0].out, 0);
        compare(l[0].side, 0);
        compare(l[4].out, 224);
        compare(l[4].side, 80);
        verify(l[2].side < 40, "the curve is quadratic, the middle has drifted less than half");
        compare(Stacks.fanLayout(1, 56, 80)[0].side, 0);
        compare(Stacks.fanLayout(0, 56, 80).length, 0);
    }

    function test_gridColumns() {
        compare(Stacks.gridColumns(1, 5), 1);
        compare(Stacks.gridColumns(10, 5), 4);
        compare(Stacks.gridColumns(100, 5), 5);
        compare(Stacks.gridColumns(0, 5), 1);
    }

    function test_keyStep() {
        compare(Stacks.step(-1, 5, 3, "down"), 0);
        compare(Stacks.step(0, 5, 3, "down"), 3);
        compare(Stacks.step(3, 5, 3, "down"), 3);
        compare(Stacks.step(4, 5, 3, "up"), 1);
        compare(Stacks.step(1, 5, 3, "up"), 1);
        compare(Stacks.step(0, 5, 3, "left"), 0);
        compare(Stacks.step(2, 5, 3, "right"), 3);
        compare(Stacks.step(4, 5, 3, "right"), 4);
        compare(Stacks.step(2, 5, 1, "left"), 2, "a list has no sideways move");
        compare(Stacks.step(2, 5, 1, "end"), 4);
        compare(Stacks.step(2, 5, 1, "home"), 0);
        compare(Stacks.step(0, 0, 1, "down"), -1);
    }

    function test_iconCandidates() {
        compare(Stacks.iconCandidates("image/png", false)[0], "image-png");
        compare(Stacks.iconCandidates("image/png", false)[1], "image-x-generic");
        compare(Stacks.iconCandidates("application/pdf", false)[0], "application-pdf");
        compare(Stacks.iconCandidates("", false)[0], "text-x-generic");
        compare(Stacks.iconCandidates("image/png", true).join(), "folder");
        verify(Stacks.hasPreview("image/jpeg"));
        verify(!Stacks.hasPreview("application/pdf"));
    }

    function test_folderIconAndFileUrl() {
        compare(Stacks.folderIconName("/home/u/Downloads", "/home/u"), "folder-download");
        compare(Stacks.folderIconName("/home/u/work", "/home/u"), "folder");
        compare(Stacks.folderIconName("/srv/Downloads", "/home/u"), "folder");
        compare(Stacks.fileUrl("/a b/c#d.png"), "file:///a%20b/c%23d.png");
        compare(Stacks.baseName("/home/u/Downloads/"), "Downloads");
    }

    function test_folderTilesSitBetweenTheSeparatorAndTheTrash() {
        const folders = DockModel.folderItems(["/home/u/Downloads", "/srv/docs"]);
        compare(folders[0].kind, "folder");
        compare(folders[0].name, "Downloads");
        compare(folders[1].key, "/srv/docs");
        const items = DockModel.withTail([{kind: "app", key: "foot"}], [{kind: "minimized", key: "min:1"}], folders);
        compare(items.map(i => i.kind).join(), "app,separator,folder,folder,minimized,trash");
        compare(DockModel.tileKey(items[2]), "folder:/home/u/Downloads");
        compare(DockModel.withTail([]).map(i => i.kind).join(), "separator,trash");
    }

    function test_keyOfAFolderIsUniqueAmongTiles() {
        const items = DockModel.withTail([], [], DockModel.folderItems(["/a/x", "/b/x"]));
        const keys = items.map(DockModel.tileKey);
        compare(keys.length, new Set(keys).size);
    }

    // ---- adding a folder by dropping it on the Dock ----

    function test_insertFoldersAtASlot() {
        const list = ["/a", "/b", "/c"];
        compare(Stacks.insertFolders(list, ["/x"], 0, "/h", 12).join(), "/x,/a,/b,/c");
        compare(Stacks.insertFolders(list, ["/x"], 2, "/h", 12).join(), "/a,/b,/x,/c");
        compare(Stacks.insertFolders(list, ["/x"], 3, "/h", 12).join(), "/a,/b,/c,/x");
        compare(Stacks.insertFolders(list, ["/x"], 99, "/h", 12).join(), "/a,/b,/c,/x");
        compare(Stacks.insertFolders(list, ["/x"], -4, "/h", 12).join(), "/x,/a,/b,/c");
        compare(Stacks.insertFolders([], ["/x", "/y"], 0, "/h", 12).join(), "/x,/y");
    }

    function test_insertFoldersMovesAnExistingOneAndExpandsHome() {
        compare(Stacks.insertFolders(["/a", "/b", "/c"], ["/a"], 3, "/h", 12).join(), "/b,/c,/a", "moved to the end, not doubled");
        compare(Stacks.insertFolders(["/a", "/b", "/c"], ["/c"], 0, "/h", 12).join(), "/c,/a,/b");
        compare(Stacks.insertFolders(["/a", "/b"], ["/b"], 1, "/h", 12).join(), "/a,/b", "dropped on itself: unchanged");
        compare(Stacks.insertFolders(["~/Downloads"], ["/h/Music"], 1, "/h", 12).join(), "/h/Downloads,/h/Music");
    }

    function test_insertFoldersRefusesJunkAndCaps() {
        compare(Stacks.insertFolders(["/a"], ["rel", "/x/../y", "", 4], 1, "/h", 12).join(), "/a");
        compare(Stacks.insertFolders(["/a", "/b"], ["/x"], 1, "/h", 2).join(), "/a,/x");
        compare(Stacks.insertFolders(null, ["/x"], 0, "/h", 12).join(), "/x");
        compare(Stacks.insertFolders(["/a"], ["/x"], undefined, "/h", 12).join(), "/a,/x");
    }

    function test_folderVerdict() {
        const dir = "inode/directory";
        compare(Stacks.folderVerdict(["/a"], {"/a": dir}), "yes");
        compare(Stacks.folderVerdict(["/a", "/b"], {"/a": dir, "/b": dir}), "yes");
        compare(Stacks.folderVerdict(["/a"], {}), "pending");
        compare(Stacks.folderVerdict(["/a", "/b"], {"/a": dir}), "pending");
        compare(Stacks.folderVerdict(["/a", "/b"], {"/a": "text/plain"}), "no", "a known file is refused at once");
        compare(Stacks.folderVerdict(["/a"], {"/a": "-"}), "no");
        compare(Stacks.folderVerdict([], {}), "no");
        compare(Stacks.folderVerdict(null, null), "no");
    }

    function test_folderSlot() {
        // tiles: 0 files, 1 apps, 2 foot, 3 separator, 4 folder A, 5 folder B, 6 trash
        const centers = [20, 80, 140, 200, 260, 320, 380];
        compare(Stacks.folderSlot(150, centers, 3, 2), -1, "left of the divider: refused");
        compare(Stacks.folderSlot(199, centers, 3, 2), -1);
        compare(Stacks.folderSlot(210, centers, 3, 2), 0, "right of the divider, before folder A");
        compare(Stacks.folderSlot(300, centers, 3, 2), 1, "between A and B");
        compare(Stacks.folderSlot(340, centers, 3, 2), 2, "after B");
        compare(Stacks.folderSlot(900, centers, 3, 2), 2, "over the Trash: last folder slot");
        compare(Stacks.folderSlot(250, centers, 3, 0), 0, "no folder yet");
        compare(Stacks.folderSlot(250, centers, -1, 2), -1, "no divider");
    }

    // ---- the pile on the tile ----

    function test_pileHasTheNewestOnTop() {
        const newest = [{path: "/d/c", isDir: false}, {path: "/d/b", isDir: true}, {path: "/d/a", isDir: false}, {path: "/d/old", isDir: false}];
        const sheets = Stacks.pileSheets(newest, 3);
        compare(sheets.length, 3);
        // back to front: the third, the second, the newest last (on top)
        compare(sheets.map(x => x.path).join(), "/d/a,/d/b,/d/c");
        compare(sheets.map(x => x.rank).join(), "2,1,0");
        compare(sheets[2].rank, 0);
        verify(sheets[1].isDir);
    }

    function test_aNewerItemMakesANewTopSheet() {
        const before = Stacks.pileSheets([{path: "/d/f4"}, {path: "/d/f3"}, {path: "/d/f2"}], 3);
        const after = Stacks.pileSheets([{path: "/d/newest.txt"}, {path: "/d/f4"}, {path: "/d/f3"}], 3);
        compare(before[before.length - 1].path, "/d/f4");
        compare(after[after.length - 1].path, "/d/newest.txt");
        compare(after.map(x => x.path).join(), "/d/f3,/d/f4,/d/newest.txt");
    }

    function test_pileEdgeCases() {
        compare(Stacks.pileSheets([], 3).length, 0);
        compare(Stacks.pileSheets(null, 3).length, 0);
        compare(Stacks.pileSheets([{path: "/a"}, {path: ""}, null, {path: 5}], 3).map(x => x.path).join(), "/a");
        compare(Stacks.pileSheets([{path: "/a"}, {path: "/b"}], 0).length, 0);
        compare(Stacks.pileSheets([{path: "/a"}], 3)[0].rank, 0);
    }
}
