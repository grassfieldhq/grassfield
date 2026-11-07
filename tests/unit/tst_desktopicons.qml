import QtQuick
import QtTest
import "../../shell/desktop/IconsLogic.js" as Logic
import "../../shell/desktop/DesktopSurfaces.js" as Surfaces
import "../../shell/services/DesktopHolders.js" as Holders

// Desktop icons logic: grid placement (top-right, column-first), moves, navigation, rename
// validation, positions persistence and pruning, URI lists, launcher parsing, folder resolution.
TestCase {
    id: testCase
    name: "DesktopIcons"

    // GF-106: Tab and Shift+Tab walk through the icons in their visual order and wrap around.
    function test_tabCyclesThroughTheIcons() {
        const lay = {a: {col: 0, row: 0}, b: {col: 0, row: 1}, c: {col: 1, row: 0}};
        compare(Logic.cycle(lay, "", false), "a");
        compare(Logic.cycle(lay, "", true), "c");
        compare(Logic.cycle(lay, "a", false), "b");
        compare(Logic.cycle(lay, "b", false), "c");
        compare(Logic.cycle(lay, "c", false), "a");
        compare(Logic.cycle(lay, "a", true), "c");
        compare(Logic.cycle(lay, "gone", false), "a");
        compare(Logic.cycle({}, "", false), "");
    }

    // UI audit 2026-11-05 (LOW): two lines at most, wrapped at words, a long name cut in the middle of the second line so the
    // extension stays; a first word wider than the label breaks anywhere. A 12-character label and a middle cut keeping 5 + 6.
    function test_labelLinesKeepTheExtension() {
        const fits = t => t.length <= 12;
        const elide = t => t.length <= 12 ? t : t.slice(0, 5) + "…" + t.slice(t.length - 6);
        compare(Logic.labelLines("short.txt", fits, elide), "short.txt");
        compare(Logic.labelLines("Project plan.odt", fits, elide), "Project\nplan.odt");
        compare(Logic.labelLines("My Holiday Photos 2026 final version.jpeg", fits, elide), "My Holiday\nPhoto…n.jpeg");
        compare(Logic.labelLines("AVeryLongFileNameWithoutSpaces.pdf", fits, elide), "AVeryLongFil\neName…es.pdf");
        compare(Logic.labelLines("", fits, elide), "");
    }

    // GF-105: a drop never creates an NFC/NFD twin on the desktop.
    function test_uniqueNameTreatsATwinAsTaken() {
        const nfc = "R\u00e9sum\u00e9.txt";
        const nfd = "Re\u0301sume\u0301.txt";
        compare(Logic.uniqueName(nfd, [nfc]), "Re\u0301sume\u0301 2.txt");
        compare(Logic.uniqueName(nfc, [nfd, "R\u00e9sum\u00e9 2.txt"]), "R\u00e9sum\u00e9 3.txt");
        compare(Logic.uniqueName("other.txt", [nfc]), "other.txt");
        compare(Logic.copyName(nfd, [nfc.replace(".txt", " copy.txt")], false), "Re\u0301sume\u0301 copy 2.txt");
    }

    // Desktop icons always snap to the grid (macOS Sort By > Snap to Grid, on at first start here with no way to turn it
    // off): a drop at any pixel lands on a whole cell, and an occupied cell gives the nearest free one.
    function test_dropSnapsToTheNearestFreeCell() {
        const w = 1000, cw = 100, ch = 100, cols = 10, rows = 5;
        for (const [x, y] of [[3, 3], [431, 277], [999, 499], [512.5, 150.2]]) {
            const s = Logic.slotAt(x, y, w, cw, ch, cols, rows);
            verify(Number.isInteger(s.col) && Number.isInteger(s.row), "whole cell for " + x + "," + y);
            verify(s.col >= 0 && s.col < cols && s.row >= 0 && s.row < rows);
        }
        // Dropped a little off the cell: the same cell wins.
        compare(Logic.slotAt(620, 110, w, cw, ch, cols, rows), Logic.slotAt(650, 140, w, cw, ch, cols, rows));
        // The wanted cell is taken: the nearest free cell, never the same one.
        const taken = {};
        taken[Logic.key(4, 2)] = true;
        const spot = Logic.nearestFree(taken, {col: 4, row: 2}, cols, rows);
        verify(spot !== null && !(spot.col === 4 && spot.row === 2));
        compare(Math.abs(spot.col - 4) + Math.abs(spot.row - 2), 1);
    }

    // Which screens carry what: every screen has the desktop surface, the icons are on one (the named one, else the first).
    function test_iconsAreOnOneScreen() {
        compare(Surfaces.iconsScreen("", ["A", "B"]), "A");
        compare(Surfaces.iconsScreen("B", ["A", "B"]), "B");
        compare(Surfaces.iconsScreen("", []), "");
        compare(Surfaces.iconsScreen("", null), "");
        // A screen the shell cannot name yet is never the one, whatever is asked.
        compare(Surfaces.iconsHere("", Surfaces.iconsScreen("", [""]), true), false);
        const names = ["A", "B", "C"];
        const main = Surfaces.iconsScreen("", names);
        compare(names.filter(n => Surfaces.iconsHere(n, main, true)), ["A"]);
        // Show Desktop Items off: the surface stays (the menu), no screen shows icons.
        compare(names.filter(n => Surfaces.iconsHere(n, main, false)), []);
        compare(Surfaces.iconsHere("A", main, undefined), false);
        // A display plugged in later is not the icons' screen, and the first one going away moves the choice.
        compare(Surfaces.iconsHere("D", main, true), false);
        compare(Surfaces.iconsScreen("", ["B", "C"]), "B");
    }

    // Several desktop surfaces report the keyboard: a focus-out on A does not clear B whose menu is open.
    function test_holdsKeyboardIsPerSurface() {
        let h = {};
        compare(Holders.any(h), false);
        h = Holders.updated(h, "A", true);
        h = Holders.updated(h, "B", true); // B: menuOpened
        compare(Holders.any(h), true);
        h = Holders.updated(h, "A", false); // A: focus out
        compare(Holders.any(h), true, "B still holds it");
        h = Holders.updated(h, "A", false);
        compare(Holders.any(h), true, "a second release of A changes nothing");
        h = Holders.updated(h, "B", false);
        compare(Holders.any(h), false);
        // An output removed while holding gives its share back.
        h = Holders.updated(Holders.updated({}, "A", true), "A", false);
        compare(Holders.any(h), false);
        compare(Holders.any(null), false);
        compare(Holders.any(Holders.updated(undefined, "A", true)), true);
    }

    function test_gridSize() {
        compare(Logic.gridSize(1000, 500, 100, 100).cols, 10);
        compare(Logic.gridSize(1000, 500, 100, 100).rows, 5);
        compare(Logic.gridSize(10, 10, 100, 100).cols, 1);
    }

    function test_layoutFillsTopRightColumnFirst() {
        const lay = Logic.layout(["c", "a", "b", "d"], {}, 3, 2);
        compare(lay.a, {col: 0, row: 0});
        compare(lay.b, {col: 0, row: 1});
        compare(lay.c, {col: 1, row: 0});
        compare(lay.d, {col: 1, row: 1});
    }

    function test_layoutSortIsCaseInsensitive() {
        const lay = Logic.layout(["b", "A", "c"], {}, 3, 3);
        compare(lay.A, {col: 0, row: 0});
        compare(lay.b, {col: 0, row: 1});
        compare(lay.c, {col: 0, row: 2});
    }

    function test_layoutKeepsSavedAndFillsAround() {
        const lay = Logic.layout(["a", "b", "c"], {b: {col: 0, row: 0}}, 2, 2);
        compare(lay.b, {col: 0, row: 0});
        compare(lay.a, {col: 0, row: 1});
        compare(lay.c, {col: 1, row: 0});
    }

    function test_layoutRejectsInvalidAndDuplicateSlots() {
        const saved = {a: {col: 9, row: 0}, b: {col: 0, row: 0}, c: {col: 0, row: 0}, d: {col: -1, row: 0}, e: "x"};
        const lay = Logic.layout(["a", "b", "c", "d", "e"], saved, 2, 3);
        compare(lay.b, {col: 0, row: 0});
        const seen = {};
        for (const n of Object.keys(lay)) {
            verify(!seen[lay[n].col + "," + lay[n].row], "slot reused by " + n);
            seen[lay[n].col + "," + lay[n].row] = true;
        }
        compare(Object.keys(lay).length, 5);
    }

    function test_layoutFullGridDropsTheOverflow() {
        const lay = Logic.layout(["a", "b", "c"], {}, 1, 2);
        compare(Object.keys(lay).length, 2);
        verify(lay.c === undefined);
    }

    function test_blockedSlotsFollowWidgetRects() {
        // 2 cols x 2 rows of 100x100 cells, grid origin (10, 20), areaW 200: col 0 is the right column.
        const b = Logic.blockedSlots([{x: 110, y: 20, w: 100, h: 50}], 10, 20, 200, 100, 100, 2, 2);
        compare(Object.keys(b).sort(), ["0,0"]);
        const two = Logic.blockedSlots([{x: 50, y: 60, w: 100, h: 100}], 10, 20, 200, 100, 100, 2, 2);
        compare(Object.keys(two).sort(), ["0,0", "0,1", "1,0", "1,1"]);
        compare(Object.keys(Logic.blockedSlots([], 10, 20, 200, 100, 100, 2, 2)).length, 0);
    }

    function test_layoutAvoidsBlockedSlots() {
        const blocked = {"0,0": true};
        const lay = Logic.layout(["a", "b"], {a: {col: 0, row: 0}}, 2, 2, blocked);
        verify(!(lay.a.col === 0 && lay.a.row === 0));
        verify(!(lay.b.col === 0 && lay.b.row === 0));
        compare(Object.keys(lay).length, 2);
    }

    function test_slotMath() {
        // Area 1000 wide, cells 100x100: col 0 is the right-most.
        compare(Logic.slotPos(0, 0, 1000, 100, 100), {x: 900, y: 0});
        compare(Logic.slotPos(2, 3, 1000, 100, 100), {x: 700, y: 300});
        compare(Logic.slotAt(905, 10, 1000, 100, 100, 10, 5), {col: 0, row: 0});
        compare(Logic.slotAt(690, 290, 1000, 100, 100, 10, 5), {col: 2, row: 3});
        compare(Logic.slotAt(-500, 9999, 1000, 100, 100, 10, 5), {col: 9, row: 4});
    }

    function test_moveGroupShiftsAndAvoidsOthers() {
        const lay = {a: {col: 0, row: 0}, b: {col: 0, row: 1}, c: {col: 2, row: 2}};
        const next = Logic.moveGroup(lay, ["a", "b"], "a", {col: 1, row: 0}, 3, 3);
        compare(next.a, {col: 1, row: 0});
        compare(next.b, {col: 1, row: 1});
        compare(next.c, {col: 2, row: 2});
        // Onto an occupied slot: nearest free one.
        const hit = Logic.moveGroup(lay, ["a"], "a", {col: 2, row: 2}, 3, 3);
        verify(hit.a.col !== 2 || hit.a.row !== 2);
        compare(hit.c, {col: 2, row: 2});
    }

    function test_navigate() {
        const lay = {a: {col: 0, row: 0}, b: {col: 0, row: 1}, c: {col: 1, row: 0}};
        compare(Logic.navigate(lay, "", "down"), "a");
        compare(Logic.navigate(lay, "a", "down"), "b");
        compare(Logic.navigate(lay, "a", "left"), "c");
        compare(Logic.navigate(lay, "c", "right"), "a");
        compare(Logic.navigate(lay, "a", "up"), "a");
        compare(Logic.navigate({}, "", "down"), "");
    }

    function test_rubberBandHits() {
        const rects = {a: {x: 0, y: 0, w: 10, h: 10}, b: {x: 50, y: 50, w: 10, h: 10}};
        compare(Logic.inRect(rects, {x: 5, y: 5, w: 10, h: 10}), ["a"]);
        compare(Logic.inRect(rects, {x: 0, y: 0, w: 100, h: 100}).sort(), ["a", "b"]);
        compare(Logic.inRect(rects, {x: 20, y: 20, w: 5, h: 5}), []);
    }

    function test_renameValidation() {
        const existing = ["a.txt", "b.txt"];
        compare(Logic.validateName("c.txt", "a.txt", existing), "");
        compare(Logic.validateName("", "a.txt", existing), "empty");
        compare(Logic.validateName("   ", "a.txt", existing), "empty");
        compare(Logic.validateName("a/b", "a.txt", existing), "slash");
        compare(Logic.validateName("..", "a.txt", existing), "dots");
        compare(Logic.validateName(".", "a.txt", existing), "dots");
        compare(Logic.validateName("b.txt", "a.txt", existing), "exists");
        compare(Logic.validateName("a.txt", "a.txt", existing), "same");
        compare(Logic.validateName("x\ny", "a.txt", existing), "control");
        compare(Logic.validateName("x".repeat(256), "a.txt", existing), "long");
        compare(Logic.validateName("x".repeat(255), "a.txt", existing), "");
        // 4-byte characters count by bytes.
        compare(Logic.validateName("\u{1F600}".repeat(64), "a.txt", existing), "long");
        compare(Logic.validateName(".hidden", "a.txt", existing), "");
    }

    function test_uniqueName() {
        compare(Logic.uniqueName("a.txt", []), "a.txt");
        compare(Logic.uniqueName("a.txt", ["a.txt"]), "a 2.txt");
        compare(Logic.uniqueName("a.txt", ["a.txt", "a 2.txt"]), "a 3.txt");
        compare(Logic.uniqueName("folder", ["folder"]), "folder 2");
        compare(Logic.uniqueName(".bashrc", [".bashrc"]), ".bashrc 2");
    }

    function test_positionsRoundTripAndPrune() {
        const pos = {"b.txt": {col: 1, row: 2}, "a.txt": {col: 0, row: 0}, "gone.txt": {col: 3, row: 3}};
        const text = Logic.serialize(pos);
        const r = Logic.parse(text);
        verify(r.ok);
        compare(r.positions, pos);
        compare(JSON.parse(text).version, 1);
        compare(Object.keys(JSON.parse(text).positions), ["a.txt", "b.txt", "gone.txt"]);
        compare(Logic.prune(pos, ["a.txt", "b.txt", "new.txt"]), {"a.txt": {col: 0, row: 0}, "b.txt": {col: 1, row: 2}});
        compare(Logic.prune(pos, []), {});
    }

    function test_parseRejectsBadFiles() {
        verify(!Logic.parse("").ok);
        verify(!Logic.parse("not json").ok);
        verify(!Logic.parse("[]").ok);
        verify(!Logic.parse('{"version":2,"positions":{}}').ok);
        verify(!Logic.parse('{"version":1,"positions":[]}').ok);
        const r = Logic.parse('{"version":1,"positions":{"a":{"col":1,"row":1},"b":{"col":-1,"row":0},"c":{"col":1.5,"row":0},"d":null,"e":"x"}}');
        verify(r.ok);
        compare(Object.keys(r.positions), ["a"]);
    }

    function test_renameKeepsPosition() {
        const out = Logic.renamed({a: {col: 1, row: 1}, b: {col: 0, row: 0}}, "a", "z");
        compare(out, {z: {col: 1, row: 1}, b: {col: 0, row: 0}});
        compare(Logic.renamed({b: {col: 0, row: 0}}, "a", "z"), {b: {col: 0, row: 0}});
    }

    function test_uriListRoundTrip() {
        const paths = ["/home/u/Desktop/a b.txt", "/home/u/Desktop/é#?%.png", "/x/(y)!'*"];
        const text = Logic.uriList(paths);
        verify(text.indexOf("a%20b.txt") > 0);
        verify(text.endsWith("\r\n"));
        compare(Logic.parseUriList(text), paths);
    }

    function test_parseUriListFilters() {
        const text = "# comment\r\nfile:///a/b\r\nhttp://example.com/x\r\nfile://localhost/c/d\r\nfile://remote/e\r\nrelative\r\nfile:///bad%ZZ\r\n\r\n";
        compare(Logic.parseUriList(text), ["/a/b", "/c/d"]);
    }

    function test_parseClipboardProbe() {
        compare(Logic.parseClipboardProbe("cut=1\nfile:///a/b\r\nfile:///c%20d\r\n"), {cut: true, paths: ["/a/b", "/c d"], uriText: "file:///a/b\r\nfile:///c%20d\r\n"});
        compare(Logic.parseClipboardProbe("cut=0\nfile:///a/b\r\n"), {cut: false, paths: ["/a/b"], uriText: "file:///a/b\r\n"});
        // No uri list on the clipboard: the probe prints nothing.
        compare(Logic.parseClipboardProbe(""), {cut: false, paths: [], uriText: ""});
        // Without the probe's first line nothing is trusted, and a bare uri list is not read as a cut.
        compare(Logic.parseClipboardProbe("file:///a/b\r\n"), {cut: false, paths: [], uriText: ""});
        compare(Logic.parseClipboardProbe("cut=yes\nfile:///a/b"), {cut: false, paths: [], uriText: ""});
        compare(Logic.parseClipboardProbe("cut=1"), {cut: true, paths: [], uriText: ""});
    }

    function test_baseAndDirName() {
        compare(Logic.baseName("/a/b/c.txt"), "c.txt");
        compare(Logic.baseName("/a/b/"), "b");
        compare(Logic.dirName("/a/b/c.txt"), "/a/b");
        compare(Logic.dirName("/a"), "/");
    }

    function test_icons() {
        compare(Logic.iconName("x", true), "folder");
        compare(Logic.iconName("a.PNG", false), "image-x-generic");
        compare(Logic.iconName("a.pdf", false), "application-pdf");
        compare(Logic.iconName("noext", false), "text-x-generic");
        verify(Logic.isImage("a.JPG"));
        verify(!Logic.isImage("a.txt"));
        verify(Logic.isLauncher("Foo.desktop"));
        verify(!Logic.isLauncher(".desktop"));
    }

    function test_parseLauncherIsPlainText() {
        const r = Logic.parseLauncher("[Desktop Action x]\nName=Wrong\n[Desktop Entry]\nName=Foo $(rm -rf)\nName[fr]=Truc\nIcon=foo-icon\nExec=evil\n");
        compare(r.name, "Foo $(rm -rf)");
        compare(r.icon, "foo-icon");
        compare(Logic.parseLauncher("garbage"), {name: "", icon: ""});
    }

    // The folder model spells its rows with single slashes and no "." or "..": the desktop folder must be spelled the same way
    // or the listing is taken for a stale one (HOME=/home/u/ makes xdg-user-dir print /home/u//Desktop).
    function test_desktopDirIsCleaned() {
        compare(Logic.desktopDir("", "/home/u//Desktop", "/home/u/"), "/home/u/Desktop");
        compare(Logic.desktopDir("", "/home/u/./Desktop/", "/home/u"), "/home/u/Desktop");
        compare(Logic.desktopDir("", "/home/u/x/../Desktop", "/home/u"), "/home/u/Desktop");
        compare(Logic.desktopDir("/tmp//sb/./a/../b/", "", "/home/u"), "/tmp/sb/b");
        compare(Logic.desktopDir("", "", "/home/u/"), "/home/u/Desktop");
        compare(Logic.desktopDir("", "/home/u//", "/home/u"), "/home/u/Desktop");
        compare(Logic.desktopDir("", "/home/u/.", "/home/u"), "/home/u/Desktop");
        compare(Logic.desktopDir("", "/../..", "/home/u"), "/home/u/Desktop");
        compare(Logic.desktopDir("//", "", "/home/u"), "/");
        compare(Logic.cleanPath("/a/b/../../.."), "/");
        compare(Logic.cleanPath(""), "");
        // The model's row path is the folder plus the name: the parent check uses the same spelling.
        const dir = Logic.desktopDir("", "/home/u//Desktop", "/home/u/");
        compare(Logic.dirName(dir + "/a.txt"), dir);
    }

    function test_desktopDir() {
        compare(Logic.desktopDir("/tmp/sb/", "/home/u/Bureau", "/home/u"), "/tmp/sb");
        compare(Logic.desktopDir("", "/home/u/Bureau\n", "/home/u"), "/home/u/Bureau");
        // XDG answers that mean "no desktop folder": ~/Desktop.
        compare(Logic.desktopDir("", "/home/u/", "/home/u"), "/home/u/Desktop");
        compare(Logic.desktopDir("", "", "/home/u"), "/home/u/Desktop");
        compare(Logic.desktopDir("", "relative", "/home/u"), "/home/u/Desktop");
    }

    // Desktop menu (macOS names): Duplicate, Make Alias, Compress.
    function test_copyAliasAndArchiveNames() {
        compare(Logic.copyName("Report.pdf", ["Report.pdf"], false), "Report copy.pdf");
        compare(Logic.copyName("Report.pdf", ["Report.pdf", "Report copy.pdf"], false), "Report copy 2.pdf");
        compare(Logic.copyName("Projects.v2", ["Projects.v2"], true), "Projects.v2 copy");
        compare(Logic.aliasName("Report.pdf", []), "Report.pdf alias");
        compare(Logic.aliasName("Report.pdf", ["Report.pdf alias"]), "Report.pdf alias 2");
        compare(Logic.archiveName(["Report.pdf"], []), "Report.pdf.zip");
        compare(Logic.archiveName(["a", "b"], []), "Archive.zip");
        compare(Logic.archiveName(["a", "b"], ["Archive.zip"]), "Archive 2.zip");
    }

    function test_cleanUpByOrders() {
        const meta = {
            "b.txt": {isDir: false, size: 10, modified: 300, created: 100},
            "A.pdf": {isDir: false, size: 99, modified: 100, created: 300},
            "Docs": {isDir: true, size: 0, modified: 200, created: 200}
        };
        const names = ["b.txt", "A.pdf", "Docs"];
        compare(Logic.orderBy(names, "name", meta), ["A.pdf", "b.txt", "Docs"]);
        compare(Logic.orderBy(names, "kind", meta), ["Docs", "A.pdf", "b.txt"]);
        compare(Logic.orderBy(names, "size", meta), ["A.pdf", "b.txt", "Docs"]);
        compare(Logic.orderBy(names, "modified", meta), ["b.txt", "Docs", "A.pdf"]);
        compare(Logic.orderBy(names, "created", meta), ["A.pdf", "Docs", "b.txt"]);
        // An unknown key falls back to the name order; missing metadata sorts as zero.
        compare(Logic.orderBy(names, "colour", meta), ["A.pdf", "b.txt", "Docs"]);
        compare(Logic.orderBy(["x", "y"], "size", {}), ["x", "y"]);
    }

    function test_cleanUpPacksInVisualOrder() {
        // Two icons in column 2 and one in column 0 row 1: Clean Up keeps that order and packs them from the corner.
        const lay = {c: {col: 2, row: 0}, a: {col: 0, row: 1}, b: {col: 2, row: 1}};
        compare(Logic.visualOrder(lay), ["a", "c", "b"]);
        const packed = Logic.arrange(Logic.visualOrder(lay), 3, 2, {});
        compare(packed.a, {col: 0, row: 0});
        compare(packed.c, {col: 0, row: 1});
        compare(packed.b, {col: 1, row: 0});
        // A blocked slot (under a widget) is skipped.
        const around = Logic.arrange(["a", "b"], 3, 2, {[Logic.key(0, 0)]: true});
        compare(around.a, {col: 0, row: 1});
        compare(around.b, {col: 1, row: 0});
    }

    function test_parseStat() {
        const m = Logic.parseStat("directory|4096|200|150|/d/Docs\nregular file|12|300|0|/d/a|b.txt\n\ngarbage");
        compare(m["Docs"], {isDir: true, size: 4096, modified: 200, created: 150});
        // A "|" in the name is kept; no birth time: created falls back to modified.
        compare(m["a|b.txt"], {isDir: false, size: 12, modified: 300, created: 300});
        compare(Object.keys(m).length, 2);
    }

    // Startup: the desktop exposes nothing before every input of its first layout is final (no default layout that then
    // moves, no placeholder or partial listing that then goes).
    function test_settledOnWaitsForEveryInput() {
        const all = {width: 1920, height: 1080, settings: true, widgets: true, positions: true, listed: true};
        verify(Logic.settledOn(all));
        for (const k of Object.keys(all)) {
            const o = Object.assign({}, all);
            o[k] = typeof all[k] === "number" ? 0 : false;
            verify(!Logic.settledOn(o), "not settled without " + k);
        }
        verify(!Logic.settledOn(null));
        verify(!Logic.settledOn({}));
        // A truthy but not true value (a pending object, a string) does not count as loaded.
        verify(!Logic.settledOn(Object.assign({}, all, {settings: "yes"})));
    }
}
