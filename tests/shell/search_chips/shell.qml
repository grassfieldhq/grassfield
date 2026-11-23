pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.search

// F2c fix pass on the REAL Search controller (scripts/dev/test.sh: `qs -p tests/shell/search_chips`, offscreen; prints
// "search-chips: PASS" or the failures). search, services and platform are symlinks to shell/.
// - filesPending is true while a live file search runs (the array is reassigned, a push never notified): the
//   "No Results" notice must not show while the plocate fallback is still running;
// - the filter chips are reachable by keyboard: Shift+Tab moves the ring to the last chip (reverse order),
//   Left/Right move, Space toggles, Esc and Tab past the end leave, typing leaves and is handed back to the field;
// - the keys of the results view (palette P3c): Page Down/Up move between the groups and wrap, Shift+Tab enters the last chip,
//   Tab opens the Actions of the selected row (none for a row without actions), a chosen action runs through the registry;
ShellRoot {
    id: root

    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    Search {
        id: search
    }

    function run(): void {
        // filesPending follows the live searches.
        check("pending starts false", search.filesPending === false);
        search.spawnSearch(1, "zz-no-such-file", "plocate");
        check("pending true while a search runs", search.filesPending === true);
        search.cancelFiles();
        check("pending false once cancelled", search.filesPending === false);

        // Chips: two groups, three chips.
        search.query = "x";
        search.chips = ["apps", "commands", "documents"];
        search.groups = [{id: "apps", items: []}, {id: "commands", items: []}];
        search.items = [{groupId: "apps"}, {groupId: "commands"}];
        search.selected = 0;
        check("chips shown", search.chipsShown);
        search.moveGroup(1);
        check("Page Down to the next group first", search.zone === "field" && search.selected === 1);
        search.moveGroup(1);
        check("Page Down past the last group wraps to the first", search.zone === "field" && search.selected === 0);
        check("Shift+Tab enters the last chip", search.enterChips() && search.zone === "chips" && search.chipIndex === 2);
        check("Right stops at the end", search.chipKey("right") && search.chipIndex === 2);
        check("Left moves", search.chipKey("left") && search.chipIndex === 1);
        check("Home goes to the first", search.chipKey("home") && search.chipIndex === 0);
        check("Tab (next) moves along", search.chipKey("next") && search.chipIndex === 1);
        check("a typed letter leaves and is handed back", !search.chipKey("other") && search.zone === "field");

        // Space asks to toggle (the filter itself is Filters.js + toggleFilter, covered by tst_searchfilters).
        search.zone = "chips";
        search.chipIndex = 1;
        check("Space is consumed by the chips", search.chipKey("activate"));
        search.query = "x";
        search.chips = ["apps", "commands", "documents"];
        search.zone = "chips";
        search.chipIndex = 1;
        check("Esc leaves", search.chipKey("escape") && search.zone === "field");
        search.zone = "chips";
        search.chipIndex = 2;
        check("Tab past the last chip leaves", search.chipKey("next") && search.zone === "field");
        search.query = "x";
        search.chips = ["apps", "commands", "documents"];
        search.groups = [{id: "apps", items: []}, {id: "commands", items: []}];
        search.items = [{groupId: "apps"}, {groupId: "commands"}];
        search.selected = 0;
        search.moveGroup(-1);
        check("Page Up before the first group wraps to the last", search.zone === "field" && search.selected === 1);
        search.chips = ["apps"];
        check("no chips to reach with a single one", !search.enterChips() && search.zone === "field");
        search.chips = ["apps", "commands", "documents"];
        search.enterChips();
        search.hide();
        check("hide leaves the chips", search.zone === "field");

        // Tab: the Actions of the selected row (Actions.js), run on the row they were opened on.
        const ran = [];
        search.items = [
            {kind: "app", key: "app:a", title: "A", groupId: "apps"},
            {kind: "clip", key: "clip:1", title: "C", groupId: "clip"},
            {kind: "command", key: "cmd:x.one", title: "One", groupId: "commands", actions: [
                {id: "more", title: "More", run: () => ran.push("more")},
                {id: "bad id", title: "Bad", run: () => ran.push("bad")}
            ]}
        ];
        search.selected = 1;
        check("a clipboard row has no Actions here", !search.openActions() && !search.actionsOpen);
        search.selected = -1;
        check("no selection, no Actions", !search.openActions());
        search.selected = 2;
        check("a command row opens its Actions", search.openActions() && search.actionsOpen && search.actionsItem.key === "cmd:x.one");
        check("Run first, then the entry's action; the malformed one is left out", search.actionList.map(a => a.id).join() === "run,x:more");
        search.selected = 0;
        check("the Actions stay on the row they opened on", search.actionsItem.key === "cmd:x.one");
        search.closeActions();
        check("closing forgets the row", !search.actionsOpen && search.actionsItem === null && search.actionList.length === 0);
        search.selected = 2;
        search.openActions();
        search.runAction("x:more");
        check("an action of an entry the registry does not hold runs nothing (the gate is Commands.runAction) and the panel closes", ran.length === 0 && !search.actionsOpen);
        search.selected = 2;
        search.openActions();
        search.runAction("x:nope");
        check("an unknown action runs nothing and closes", ran.length === 0 && !search.actionsOpen);
        search.openActions();
        search.setQuery("zzz-new");
        check("a new query closes the Actions", !search.actionsOpen);

        // macOS: an empty field lists nothing (no recent documents); the first keystroke brings the results.
        search.recentList = [{path: "/home/u/report.txt"}, {path: "/home/u/notes.txt"}];
        search.fileHits = [];
        search.query = "";
        search.compute();
        check("empty query lists no group", search.groups.length === 0 && search.items.length === 0);
        search.query = "   ";
        search.compute();
        check("blank query lists no group", search.groups.length === 0);
        search.query = "report";
        search.compute();
        const ids = search.groups.map(g => g.id);
        check("a keystroke brings the matching recent document", ids.indexOf("recent") >= 0 || ids.indexOf("top") >= 0);
        check("non-matching recents stay out", JSON.stringify(search.groups).indexOf("notes.txt") < 0);
        // macOS: no group headers, every row is a result.
        check("rows carry no group header", search.rows.length > 0 && search.rows.every(r => !r.header));

        // Settings > Search > Search Results: a kind of result turned off never shows, the top hit included.
        const groupIds = text => {
            search.query = text;
            search.compute();
            return search.groups.map(g => g.id);
        };
        check("the calculator answers", groupIds("2+3").indexOf("calc") >= 0);
        search.showCalculator = false;
        check("no calculator when off", groupIds("2+3").indexOf("calc") < 0);
        check("commands match", JSON.stringify(groupIds("sleep")).match(/top|commands/) !== null);
        check("...the Sleep command's row", JSON.stringify(search.groups).indexOf("cmd:sys.sleep") >= 0);
        search.showCommands = false;
        groupIds("sleep");
        check("no command when off", JSON.stringify(search.groups).indexOf("cmd:") < 0);
        groupIds("wallpaper");
        check("settings pages match", JSON.stringify(search.groups).indexOf("setting:wallpaper") >= 0);
        search.showSettings = false;
        groupIds("wallpaper");
        check("no settings page when off", JSON.stringify(search.groups).indexOf("setting:wallpaper") < 0);
        search.showRecents = false;
        groupIds("report");
        check("no recent document when off", JSON.stringify(search.groups).indexOf("report.txt") < 0);
        search.fileHits = ["/home/u/report.txt"];
        search.showDocuments = false;
        check("turning documents off drops the file results", search.fileHits.length === 0);
        groupIds("report");
        check("no document when off", JSON.stringify(search.groups).indexOf("report.txt") < 0);
        search.startFiles();
        check("no file search runs when off", search.filesPending === false);

        // Delete Search History: the picks made before it are forgotten.
        search.usage = {"app:a": {count: 3, last: 1000}, "app:b": {count: 1, last: 5000}};
        search.historyResetAt = 2000;
        check("picks before the deletion are forgotten", Object.keys(search.usage).join() === "app:b");
    }

    Timer {
        interval: 200
        running: true
        onTriggered: {
            root.run();
            if (root.failures.length === 0) {
                console.log("search-chips: PASS");
                Qt.exit(0);
            } else {
                console.log("search-chips: FAIL " + root.failures.join(", "));
                Qt.exit(1);
            }
        }
    }
}
