import QtQuick
import QtTest
import "../../shell/dock/DockModel.js" as DockModel
import "../../shell/switcher/SwitcherModel.js" as Model

TestCase {
    name: "SwitcherModel"

    readonly property var entries: ({
        "foot": {id: "foot", name: "Foot", icon: "foot"},
        "chromium": {id: "chromium", name: "Chromium", icon: "chromium"},
        "org.gnome.Nautilus": {id: "org.gnome.Nautilus", name: "Files", icon: "nautilus"}
    })

    function lookup(id) {
        for (const key in entries) {
            if (key.toLowerCase() === id.toLowerCase())
                return entries[key];
        }
        return null;
    }

    function stamps(map) {
        return ref => map[ref] || 0;
    }

    function names(list) {
        return list.map(a => a.name).join(",");
    }

    function test_mruOrderMostRecentFirst() {
        const wins = [{appId: "foot", ref: "f1"}, {appId: "chromium", ref: "c1"}, {appId: "org.gnome.Nautilus", ref: "n1"}];
        const list = Model.apps(DockModel.merge, wins, lookup, stamps({f1: 10, c1: 30, n1: 20}), []);
        compare(names(list), "Chromium,Files,Foot");
    }

    function test_groupingByAppAndAppStampIsItsNewestWindow() {
        const wins = [{appId: "foot", ref: "f1"}, {appId: "Foot", ref: "f2"}, {appId: "chromium", ref: "c1"}];
        const list = Model.apps(DockModel.merge, wins, lookup, stamps({f1: 5, f2: 50, c1: 20}), []);
        compare(names(list), "Foot,Chromium");
        compare(list[0].windows.length, 2);
    }

    function test_neverFocusedKeepWindowOrderAndEmptyAndExcludedAreDropped() {
        const wins = [{appId: "", ref: "x"}, {appId: "quickshell", ref: "q"}, {appId: "chromium", ref: "c"}, {appId: "foot", ref: "f"}];
        const list = Model.apps(DockModel.merge, wins, lookup, stamps({}), ["quickshell"]);
        compare(names(list), "Chromium,Foot");
    }

    function test_refreshKeepsOrderDropsClosedAppendsNew() {
        const a = {key: "a"}, b = {key: "b"}, c = {key: "c"}, d = {key: "d"};
        compare(Model.refresh([a, b, c], [c, d, a]).map(x => x.key).join(""), "acd");
    }

    // Audit A-02: an app id named like a member of Object.prototype is an app like any other.
    function test_prototypeNamesAreOrdinaryApps() {
        for (const id of ["constructor", "__proto__", "toString"]) {
            const list = Model.apps(DockModel.merge, [{appId: id, ref: "w1"}, {appId: "foot", ref: "f1"}], lookup, stamps({w1: 20, f1: 10}), []);
            compare(list.map(a => a.key).join(","), id + ",foot", id);
            const fresh = [{key: id}, {key: "foot"}, {key: "new"}];
            compare(Model.refresh([{key: "foot"}, {key: id}, {key: "gone"}], fresh).map(a => a.key).join(","), "foot," + id + ",new", id);
        }
    }

    function test_quickSwitchGoesToPreviousApp() {
        let r = Model.reduce(Model.idle(), {type: "step", dir: 1, count: 3});
        compare(r.state.phase, "pending");
        compare(r.state.selected, 1);
        r = Model.reduce(r.state, {type: "release"});
        compare(r.action, "commit");
        compare(r.index, 1);
        compare(r.state.phase, "idle");
    }

    function test_shiftTabStartsAtTheLeastRecentApp() {
        compare(Model.reduce(Model.idle(), {type: "step", dir: -1, count: 4}).state.selected, 3);
    }

    function test_noFocusedAppFirstSelectionIsTheMostRecentApp() {
        compare(Model.reduce(Model.idle(), {type: "step", dir: 1, count: 3, current: false}).state.selected, 0);
        compare(Model.reduce(Model.idle(), {type: "step", dir: 1, count: 3, current: true}).state.selected, 1);
        compare(Model.reduce(Model.idle(), {type: "step", dir: -1, count: 3, current: false}).state.selected, 2);
    }

    function test_singleAppAndNoApp() {
        compare(Model.reduce(Model.idle(), {type: "step", dir: 1, count: 1}).state.selected, 0);
        compare(Model.reduce(Model.idle(), {type: "step", dir: 1, count: 0}).state.phase, "idle");
    }

    function test_timerShowsThePanelOnce() {
        let r = Model.reduce(Model.idle(), {type: "step", dir: 1, count: 3});
        r = Model.reduce(r.state, {type: "timer"});
        compare(r.action, "show");
        compare(r.state.phase, "shown");
        compare(Model.reduce(r.state, {type: "timer"}).action, "none");
    }

    function test_secondTabShowsAndMovesAndWraps() {
        let r = Model.reduce(Model.idle(), {type: "step", dir: 1, count: 3});
        r = Model.reduce(r.state, {type: "step", dir: 1, count: 3});
        compare(r.action, "show");
        compare(r.state.selected, 2);
        r = Model.reduce(r.state, {type: "step", dir: 1, count: 3});
        compare(r.action, "none");
        compare(r.state.selected, 0);
        r = Model.reduce(r.state, {type: "step", dir: -1, count: 3});
        compare(r.state.selected, 2);
    }

    function test_cancelAndReleaseWhenIdle() {
        const r = Model.reduce(Model.idle(), {type: "step", dir: 1, count: 3});
        compare(Model.reduce(r.state, {type: "cancel"}).action, "cancel");
        compare(Model.reduce(Model.idle(), {type: "release"}).action, "none");
        compare(Model.reduce(Model.idle(), {type: "cancel"}).action, "none");
    }

    function test_hoverAndClickOnlyWhenShown() {
        let r = Model.reduce(Model.idle(), {type: "step", dir: 1, count: 3});
        compare(Model.reduce(r.state, {type: "hover", index: 2}).state.selected, 1);
        r = Model.reduce(r.state, {type: "timer"});
        r = Model.reduce(r.state, {type: "hover", index: 2});
        compare(r.state.selected, 2);
        r = Model.reduce(r.state, {type: "click", index: 0});
        compare(r.action, "commit");
        compare(r.index, 0);
    }

    function test_countChangeClampsAndEmptyEnds() {
        let r = Model.reduce(Model.idle(), {type: "step", dir: -1, count: 4});
        r = Model.reduce(r.state, {type: "count", count: 2, selected: -1});
        compare(r.state.selected, 1);
        compare(Model.reduce(r.state, {type: "count", count: 0, selected: -1}).action, "cancel");
    }

    function test_gridWrapsRows() {
        compare(JSON.stringify(Model.grid(3, 1000, 134)), '{"columns":3,"rows":1}');
        compare(JSON.stringify(Model.grid(20, 1000, 134)), '{"columns":7,"rows":3}');
        compare(Model.grid(5, 10, 134).columns, 1);
    }
}
