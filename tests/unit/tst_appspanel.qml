import QtQuick
import QtTest
import "../../shell/launchpad/Model.js" as Model
import "../../shell/search/Ranking.js" as Ranking

// Apps panel model (docs/specs/apps.md): category mapping, alphabetical order, panel and grid metrics,
// keyboard navigation in the grid, filtering and the hidden-entry list.
TestCase {
    name: "AppsPanel"

    readonly property var opts: ({width: 844, edgeMargin: 24, heightFraction: 0.62, minHeight: 320, topFraction: 0.18, bottomClearance: 96})
    readonly property var gopts: ({columns: 7, minColumns: 3, minCellWidth: 80, cellHeight: 102})

    function rec(id, name, categories, extra) {
        return Object.assign({id: id, name: name, genericName: "", comment: "", keywords: [], category: Model.categoryOf(categories)}, extra ?? {});
    }

    // ---- categories -------------------------------------------------------------------------

    // UX-11: Grassfield Files and GNOME Files are both "Files": one keeps the plain name (the native app, as the Finder), the
    // other is told apart, nothing is hidden and an app with a name of its own is untouched.
    function test_sameNameIsToldApart() {
        const recs = [
            {id: "org.gnome.Nautilus", name: "Files", genericName: "File Manager"},
            {id: "org.grassfield.Files", name: "Files", genericName: "File Manager"},
            {id: "foot", name: "Foot", genericName: "Terminal"}
        ];
        const out = Model.disambiguate(recs);
        compare(out.length, 3);
        compare(out[0].name, "Files (GNOME)");
        compare(out[0].baseName, "Files");
        compare(out[1].name, "Files");
        compare(out[2].name, "Foot");
        compare(recs[0].name, "Files", "the input is not changed");
        // No native app: both are qualified; a plain id falls back to the generic name, then to the id.
        const two = Model.disambiguate([{id: "a.desktop", name: "Notes", genericName: "Text Editor"}, {id: "b", name: "notes", genericName: "Notes"}]);
        compare(two[0].name, "Notes (Text Editor)");
        compare(two[1].name, "notes (b)");
        // Still equal after the qualifier: the ids decide.
        const same = Model.disambiguate([{id: "org.x.App", name: "App"}, {id: "com.x.App", name: "App"}]);
        compare(same[0].name === same[1].name, false);
        compare(Model.vendorOf("org.kde.dolphin"), "KDE");
        compare(Model.vendorOf("firefox"), null);
        compare(Model.disambiguate([]).length, 0);
        // Audit A-03: an app may be called like a member of Object.prototype ("Constructor" is a real title).
        const odd = Model.disambiguate([{id: "steam_1", name: "Constructor"}, {id: "x", name: "__proto__"}, {id: "y", name: "toString"}, {id: "z", name: "tostring"}]);
        compare(odd.map(r => r.name).join("|"), "Constructor|__proto__|toString (y)|tostring (z)");
        compare(Model.categoryOf("constructor;toString"), "other");
    }

    function test_categoryMapping() {
        compare(Model.categoryOf(["Game", "ArcadeGame"]), "games");
        compare(Model.categoryOf(["Graphics", "2DGraphics", "RasterGraphics"]), "creativity");
        compare(Model.categoryOf(["AudioVideo", "Player", "Video"]), "creativity");
        compare(Model.categoryOf(["Office", "Spreadsheet"]), "productivity");
        compare(Model.categoryOf(["Development", "IDE"]), "productivity");
        compare(Model.categoryOf(["System", "TerminalEmulator"]), "utilities");
        compare(Model.categoryOf(["Utility", "TextEditor"]), "utilities");
        compare(Model.categoryOf(["Network", "WebBrowser"]), "other");
    }

    function test_categoryPriorityAndFallback() {
        // The first chip in the order games, creativity, productivity, utilities wins.
        compare(Model.categoryOf(["Utility", "Game"]), "games");
        compare(Model.categoryOf(["Office", "Graphics"]), "creativity");
        compare(Model.categoryOf(["System", "Office"]), "productivity");
        // Unknown, extension and empty values fall back to "other"; accepts a ";"-separated string.
        compare(Model.categoryOf(["X-GNOME-Foo", "Qt", ""]), "other");
        compare(Model.categoryOf([]), "other");
        compare(Model.categoryOf(undefined), "other");
        compare(Model.categoryOf("GTK;Game;"), "games");
        compare(Model.categoryOf(["game"]), "other");
    }

    function test_everyMappedCategoryBelongsToOneChip() {
        const seen = {};
        for (const id of Model.CATEGORY_ORDER) {
            for (const c of Model.CATEGORY_MAP[id]) {
                verify(seen[c] === undefined, c + " listed twice");
                seen[c] = id;
            }
        }
        for (const id of Model.CATEGORY_ORDER)
            verify(Model.CATEGORY_IDS.indexOf(id) > 0);
    }

    // ---- order, groups ----------------------------------------------------------------------

    function test_alphabeticalOrder() {
        const sorted = Model.sortApps([rec("c", "charlie"), rec("b2", "Bravo"), rec("a", "alpha"), rec("b1", "bravo"), rec("e", "Écho")]);
        compare(sorted.map(r => r.id), ["a", "b1", "b2", "c", "e"]);
        compare(Model.sortApps([]).length, 0);
    }

    function test_groupsAndChips() {
        const recs = Model.sortApps([rec("a", "Alpha", ["Game"]), rec("b", "Bravo", ["Office"]), rec("c", "Charlie", ["Network"]), rec("d", "Delta", ["Game"])]);
        const g = Model.groupByCategory(recs);
        compare(g.all.map(r => r.id), ["a", "b", "c", "d"]);
        compare(g.games.map(r => r.id), ["a", "d"]);
        compare(g.productivity.map(r => r.id), ["b"]);
        compare(g.other.map(r => r.id), ["c"]);
        compare(g.creativity.length, 0);
        // Empty chips are hidden, "all" always shown, display order kept.
        compare(Model.visibleCategories(g), ["all", "productivity", "games", "other"]);
        compare(Model.visibleCategories(Model.groupByCategory([])), ["all"]);
    }

    // ---- panel and grid ---------------------------------------------------------------------

    function test_panelAt1080() {
        const p = Model.panelRect(1920, 1080, opts);
        compare(p.w, 844);
        compare(p.x, 538);
        compare(p.y, 194);
        compare(p.h, 670);
        verify(p.y + p.h <= 1080 - opts.bottomClearance);
    }

    // macOS 27: the search capsule and its gap sit above the panel, which starts that much lower.
    function test_panelUnderTheCapsule() {
        const p = Model.panelRect(1920, 1080, Object.assign({}, opts, {topOffset: 96}));
        compare(p.y, 194 + 96);
        verify(p.y + p.h <= 1080 - opts.bottomClearance);
    }

    function test_panelOnSmallOutputs() {
        // 1366x768 and 1024x600: the share of the height fits; 800x480: the Dock clearance wins over the minimum.
        const a = Model.panelRect(1366, 768, opts);
        compare(a.w, 844);
        compare(a.h, 476);
        const b = Model.panelRect(1024, 600, opts);
        compare(b.y, 108);
        compare(b.h, 372);
        const d = Model.panelRect(800, 480, opts);
        compare(d.h, 480 - 86 - 96);
        verify(d.y + d.h <= 480 - opts.bottomClearance);
        // Narrow output: the panel shrinks to the edge margins and stays centred.
        const c = Model.panelRect(640, 480, opts);
        compare(c.w, 640 - 48);
        compare(c.x, 24);
        verify(c.h > 0);
    }

    function test_gridColumns() {
        const g = Model.grid(804, gopts);
        compare(g.cols, 7);
        fuzzyCompare(g.cellW, 804 / 7, 1e-9);
        compare(g.cellH, 102);
        compare(Model.grid(500, gopts).cols, 6);
        compare(Model.grid(240, gopts).cols, 3);
        compare(Model.grid(100, gopts).cols, 3);
        compare(Model.grid(4000, gopts).cols, 7);
    }

    function test_visibleRows() {
        compare(Model.visibleRows(560, 102), 5);
        compare(Model.visibleRows(50, 102), 1);
    }

    // ---- keyboard navigation ----------------------------------------------------------------

    function test_stepBasics() {
        // 20 items, 7 columns: rows of 7, 7 and 6.
        compare(Model.step(-1, "down", 7, 20, 4), 0);
        compare(Model.step(0, "left", 7, 20, 4), 0);
        compare(Model.step(0, "right", 7, 20, 4), 1);
        compare(Model.step(6, "right", 7, 20, 4), 7);
        compare(Model.step(7, "left", 7, 20, 4), 6);
        compare(Model.step(19, "right", 7, 20, 4), 19);
        compare(Model.step(3, "down", 7, 20, 4), 10);
        compare(Model.step(10, "up", 7, 20, 4), 3);
        compare(Model.step(3, "up", 7, 20, 4), 3);
        compare(Model.step(5, "home", 7, 20, 4), 0);
        compare(Model.step(5, "end", 7, 20, 4), 19);
        compare(Model.step(5, "bogus", 7, 20, 4), 5);
        compare(Model.step(0, "down", 7, 0, 4), -1);
    }

    function test_stepShortLastRow() {
        // Down from the middle row to a short last row lands on the last item; from the last row it stays.
        compare(Model.step(13, "down", 7, 17, 4), 16);
        compare(Model.step(16, "down", 7, 17, 4), 16);
        compare(Model.step(10, "down", 7, 17, 4), 16);
    }

    function test_stepPages() {
        compare(Model.step(1, "pagedown", 7, 100, 5), 36);
        compare(Model.step(96, "pagedown", 7, 100, 5), 99);
        compare(Model.step(36, "pageup", 7, 100, 5), 1);
        compare(Model.step(10, "pageup", 7, 100, 5), 3);
    }

    function test_firstRow() {
        verify(Model.atFirstRow(0, 7));
        verify(Model.atFirstRow(6, 7));
        verify(!Model.atFirstRow(7, 7));
    }

    // ---- selection and launch (the ring rule) ------------------------------------------------

    function test_returnLaunchesOnlyAVisibleSelection() {
        // Repro of the review: Utilities chip, Down, Right x6, Up, Up leaves the grid for the field with selected = 6
        // and no ring: Return must not launch it.
        compare(Model.launchIndex("search", false, false, 6, 20), -1);
        // The grid with the keyboard owning the selection launches it.
        compare(Model.launchIndex("grid", true, false, 6, 20), 6);
        // A query makes the ring visible everywhere but in the chips (where Return selects the chip).
        compare(Model.launchIndex("search", false, true, 0, 20), 0);
        compare(Model.launchIndex("chips", false, true, 0, 20), -1);
        compare(Model.launchIndex("chips", true, false, 3, 20), -1);
        // Nothing selected, or out of range: nothing.
        compare(Model.launchIndex("search", false, true, -1, 20), -1);
        compare(Model.launchIndex("grid", true, false, 20, 20), -1);
        compare(Model.launchIndex("grid", true, false, 0, 0), -1);
    }

    function test_leavingTheGridDropsTheSelectionExceptTheFirstResult() {
        // The field with a query selects the first result (Return launches it), without a query nothing.
        compare(Model.selectionForZone("search", true, 5), 0);
        compare(Model.selectionForZone("search", true, 0), -1);
        compare(Model.selectionForZone("search", false, 5), -1);
        compare(Model.selectionForZone("chips", true, 5), -1);
        compare(Model.selectionForZone("chips", false, 5), -1);
    }

    function test_selectionFollowsItsAppWhenTheListChanges() {
        const items = [{id: "a"}, {id: "b"}, {id: "c"}];
        compare(Model.indexOfId(items, "b"), 1);
        // An app inserted before it moves its index, the selection follows the app.
        compare(Model.indexOfId([{id: "x"}].concat(items), "b"), 2);
        // The app is gone: nothing is selected.
        compare(Model.indexOfId([{id: "a"}, {id: "c"}], "b"), -1);
        compare(Model.indexOfId(items, ""), -1);
    }

    function test_documentViewerIsProductivity() {
        // Evince: Office + Viewer + Graphics must not land in Creativity.
        compare(Model.categoryOf(["GNOME", "GTK", "Office", "Viewer", "Graphics", "2DGraphics", "VectorGraphics"]), "productivity");
        // An image viewer (no Office) stays in Creativity, a game is still a game.
        compare(Model.categoryOf(["Graphics", "2DGraphics", "Viewer"]), "creativity");
        compare(Model.categoryOf(["Game", "Office", "Viewer"]), "games");
    }

    // ---- filtering --------------------------------------------------------------------------

    function test_searchSpansEveryCategory() {
        const recs = Model.sortApps([rec("g.desktop", "Terminal Quest", ["Game"]), rec("t.desktop", "Terminal", ["System", "TerminalEmulator"]),
            rec("o.desktop", "Office", ["Office"]), rec("w.desktop", "Web", ["Network"])]);
        const ranked = Ranking.rank(recs, "termin", Ranking.newUsage(), 0).map(r => r.app.id);
        compare(ranked.length, 2);
        compare(ranked[0], "t.desktop");
        verify(ranked.indexOf("g.desktop") >= 0);
        compare(Ranking.rank(recs, "  ", Ranking.newUsage(), 0).length, 0);
        compare(Ranking.rank(recs, "zzzzq", Ranking.newUsage(), 0).length, 0);
    }

    // ---- hidden entries (Apps service, Search) ---------------------------------------------

    function test_hiddenIdsMatchEntryIds() {
        // hidden-entries.sh prints ids without the suffix; tolerate a suffix or CRLF anyway.
        const set = Model.parseHidden("rvhide-kde\nsub-nested.desktop\r\n\nplain\n");
        verify(Model.isHidden(set, "rvhide-kde"));
        verify(Model.isHidden(set, "rvhide-kde.desktop"));
        verify(Model.isHidden(set, "sub-nested"));
        verify(Model.isHidden(set, "plain"));
        verify(!Model.isHidden(set, "rvhide"));
        verify(!Model.isHidden(Model.parseHidden(""), "plain"));
    }

    function test_localizedEntries() {
        // entry-names.sh: id, Name, GenericName, Comment, Keywords; a malformed line or an empty name is skipped.
        const map = Model.parseLocalized("org.grassfield.Files\tFichiers\tGestionnaire de fichiers\tParcourir\tdossier;disque;\r\n"
            + "constructor\tConstructeur\t\t\t\n" + "short\tUn\tdeux\n" + "\tSans id\t\t\t\n" + "noname\t\tx\ty\tz\n\n");
        compare(map["org.grassfield.Files"], {name: "Fichiers", genericName: "Gestionnaire de fichiers", comment: "Parcourir", keywords: ["dossier", "disque"]});
        compare(map["constructor"].name, "Constructeur", "an id named like an object's own property");
        verify(map["short"] === undefined);
        verify(map[""] === undefined);
        verify(map["noname"] === undefined);
        compare(Object.keys(Model.parseLocalized("")).length, 0);
    }
}
