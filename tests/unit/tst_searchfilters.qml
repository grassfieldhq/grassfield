import QtQuick
import QtTest
import "../../shell/search/Filters.js" as Filters

TestCase {
    name: "SearchFilters"

    readonly property var groups: [
        {id: "calc", title: "Calculator", items: [{kind: "calc", key: "calc"}]},
        {id: "top", title: "Top Hit", items: [{kind: "app", key: "app:a"}]},
        {id: "apps", title: "Applications", items: [{kind: "app", key: "app:b"}, {kind: "app", key: "app:c"}]},
        {id: "commands", title: "Commands", items: [{kind: "command", key: "cmd:sleep"}]},
        {id: "files", title: "Documents", items: [{kind: "file", key: "file:/x"}]},
        {id: "recent", title: "Recent", items: [{kind: "recent", key: "recent:/y"}]}
    ]

    function test_chipsFollowTheResults() {
        compare(Filters.chipsOf(groups), ["apps", "commands", "documents"]);
        compare(Filters.chipsOf([groups[1]]), ["apps"]);
        compare(Filters.chipsOf([groups[0]]), []);
        compare(Filters.chipsOf([]), []);
    }

    function test_applyKeepsTheTopHitAndOrder() {
        const apps = Filters.apply(groups, "apps", "Applications");
        compare(apps.length, 1);
        compare(apps[0].id, "apps");
        compare(apps[0].items.map(i => i.key), ["app:a", "app:b", "app:c"]);
        const docs = Filters.apply(groups, "documents", "Documents");
        compare(docs[0].items.map(i => i.key), ["file:/x", "recent:/y"]);
    }

    function test_applyDropsInlineAnswers() {
        const cmds = Filters.apply(groups, "commands", "Commands");
        compare(cmds.length, 1);
        compare(cmds[0].items.length, 1);
    }

    function test_chipKeysMoveAndToggle() {
        let r = Filters.chipKey("chips", 0, 3, "right");
        compare(r.index, 1);
        compare(Filters.chipKey("chips", 2, 3, "right").index, 2);
        compare(Filters.chipKey("chips", 0, 3, "left").index, 0);
        compare(Filters.chipKey("chips", 1, 3, "end").index, 2);
        compare(Filters.chipKey("chips", 1, 3, "home").index, 0);
        r = Filters.chipKey("chips", 1, 3, "activate");
        verify(r.toggle && r.zone === "chips" && r.index === 1);
        compare(Filters.chipKey("chips", 2, 3, "next").zone, "field");
        compare(Filters.chipKey("chips", 0, 3, "prev").zone, "field");
        compare(Filters.chipKey("chips", 1, 3, "escape").zone, "field");
    }

    function test_chipKeysHandBackOtherKeys() {
        const r = Filters.chipKey("chips", 1, 3, "other");
        verify(!r.handled);
        compare(r.zone, "field");
        verify(!Filters.chipKey("field", -1, 3, "right").handled);
    }

    function test_noFilterIsIdentity() {
        verify(Filters.apply(groups, "", "x") === groups);
        verify(Filters.apply(groups, "nonsense", "x") === groups);
        compare(Filters.apply([groups[0]], "apps", "Applications").length, 0);
    }
}
