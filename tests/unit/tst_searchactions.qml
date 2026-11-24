import QtQuick
import QtTest
import "../../shell/search/Actions.js" as Actions

// The Actions panel of Search (ADR-0067 P3a): the actions per kind, their order, destructive last, the filter over them and the key
// map of the results view (Tab, Shift+Tab, Page Down/Up, Ctrl+Down/Up, ⌘K behind its switch), AZERTY places included.
TestCase {
    name: "SearchActions"

    readonly property var words: ({open: "Open", run: "Run", copy: "Copy", reveal: "Show in Files"})

    function ids(list) {
        return list.map(a => a.separator ? "-" : a.id).join(" ");
    }

    function extra(id, title, more) {
        return Object.assign({id: id, title: title, run: () => {}}, more || {});
    }

    function test_constants() {
        compare(Actions.KEY.tab, Qt.Key_Tab);
        compare(Actions.KEY.backtab, Qt.Key_Backtab);
        compare(Actions.KEY.pageUp, Qt.Key_PageUp);
        compare(Actions.KEY.pageDown, Qt.Key_PageDown);
        compare(Actions.KEY.up, Qt.Key_Up);
        compare(Actions.KEY.down, Qt.Key_Down);
        compare(Actions.KEY.k, Qt.Key_K);
        compare(Actions.SHIFT, Qt.ShiftModifier);
        compare(Actions.CTRL, Qt.ControlModifier);
        compare(Actions.ALT, Qt.AltModifier);
        compare(Actions.META, Qt.MetaModifier);
    }

    function test_perKind() {
        compare(ids(Actions.forItem({kind: "app"}, words)), "open");
        compare(ids(Actions.forItem({kind: "setting"}, words)), "open");
        compare(ids(Actions.forItem({kind: "command"}, words)), "run");
        compare(ids(Actions.forItem({kind: "calc"}, words)), "copy");
        compare(ids(Actions.forItem({kind: "file"}, words)), "open reveal");
        compare(ids(Actions.forItem({kind: "recent"}, words)), "open reveal");
        // The clipboard rows keep the CB-8 menu; an unknown kind and a bad item have none.
        compare(Actions.forItem({kind: "clip"}, words).length, 0);
        compare(Actions.forItem({kind: "weird"}, words).length, 0);
        compare(Actions.forItem(null, words).length, 0);
        compare(Actions.forItem({kind: "app"}, null).length, 0);
    }

    function test_primaryAndSecondaryShortcuts() {
        const f = Actions.forItem({kind: "file"}, words);
        compare(f[0].shortcut, "Return");
        compare(f[0].text, "Open");
        compare(f[1].shortcut, "Ctrl+Return");
        compare(f[1].text, "Show in Files");
        verify(f.every(a => a.destructive !== true));
    }

    function test_extrasAfterThePrimaryDestructiveLast() {
        const item = {kind: "command", actions: [
                extra("remove", "Remove", {destructive: true}),
                extra("edit", "Edit", {shortcut: "Ctrl+E"}),
                extra("again", "Again")
            ]};
        const list = Actions.forItem(item, words);
        compare(ids(list), "run x:edit x:again - x:remove");
        verify(list[1].shortcut === "Ctrl+E");
        verify(list[1].shortcut !== undefined && list[2].shortcut === undefined);
        verify(list[4].destructive === true);
        verify(typeof list[1].run === "function");
    }

    function test_onlyDestructiveExtrasStillSeparated() {
        const list = Actions.forItem({kind: "command", actions: [extra("rm", "Delete", {destructive: true})]}, words);
        compare(ids(list), "run - x:rm");
    }

    function test_malformedExtrasLeftOut() {
        const item = {kind: "command", actions: [
                extra("Bad Id", "x"), extra("ok", ""), {id: "norun", title: "No run"}, null, 5,
                extra("a", "A"), extra("a", "A twice"), extra("sc", "S", {shortcut: 3})
            ]};
        compare(ids(Actions.forItem(item, words)), "run x:a");
        compare(Actions.forItem({kind: "command", actions: "nope"}, words).length, 1);
    }

    function test_extrasOnlyOnTheirKindsList() {
        // A custom action never replaces a built-in id: it is namespaced.
        const list = Actions.forItem({kind: "command", actions: [extra("run", "Run again")]}, words);
        compare(ids(list), "run x:run");
    }

    function test_filterField() {
        const many = [];
        for (let i = 0; i < 8; i++)
            many.push(extra("a" + i, "Action " + i));
        const list = Actions.forItem({kind: "command", actions: many.slice(0, 6)}, words);
        compare(list.length, 7);
        verify(!Actions.needsFilter(list), "seven actions: no filter");
        verify(Actions.needsFilter(Actions.forItem({kind: "command", actions: many}, words)), "eight: a filter field");
        verify(!Actions.needsFilter(null));
        // A separator is not an action.
        verify(!Actions.needsFilter(Actions.forItem({kind: "command", actions: many.slice(0, 5).concat([extra("d", "D", {destructive: true})])}, words)));
    }

    function test_filterText() {
        const list = Actions.forItem({kind: "file", actions: [extra("cp", "Copy Path"), extra("tr", "Déplacer à la corbeille", {destructive: true})]}, words);
        compare(Actions.filter(list, "").length, list.length, "no text keeps the list, separators too");
        compare(ids(Actions.filter(list, "show")), "reveal");
        compare(ids(Actions.filter(list, "COPY path")), "x:cp");
        compare(ids(Actions.filter(list, "path copy")), "x:cp", "words in any order");
        compare(ids(Actions.filter(list, "deplacer")), "x:tr", "accents ignored");
        compare(Actions.filter(list, "zzz").length, 0);
        compare(Actions.filter(null, "a").length, 0);
        verify(Actions.filter(list, "o").every(a => !a.separator), "separators drop out while filtering");
    }

    function test_findAndStep() {
        const list = Actions.forItem({kind: "command", actions: [extra("a", "A", {enabled: false}), extra("b", "B"), extra("rm", "R", {destructive: true})]}, words);
        // run, x:a (disabled), x:b, separator, x:rm
        compare(Actions.find(list, "x:b").text, "B");
        compare(Actions.find(list, "nope"), null);
        compare(Actions.find(null, "run"), null);
        compare(Actions.firstSelectable(list), 0);
        compare(Actions.firstSelectable([{separator: true}]), -1);
        compare(Actions.step(list, -1, 1), 0);
        compare(Actions.step(list, 0, 1), 2, "a disabled row is skipped");
        compare(Actions.step(list, 2, 1), 4, "a separator is skipped");
        compare(Actions.step(list, 4, 1), 0, "wraps");
        compare(Actions.step(list, 0, -1), 4);
        compare(Actions.step(list, -1, -1), 4);
        compare(Actions.step([], 0, 1), -1);
    }

    // ---- the key map ----

    function test_tabOpensActions() {
        compare(Actions.keyAction(Qt.Key_Tab, 0, 23), "actions");
        compare(Actions.keyAction(Qt.Key_Tab, Qt.KeypadModifier, 23), "actions", "a keypad flag is no modifier of ours");
    }

    function test_shiftTabReachesTheChips() {
        compare(Actions.keyAction(Qt.Key_Backtab, Qt.ShiftModifier, 23), "chips");
        compare(Actions.keyAction(Qt.Key_Backtab, 0, 23), "chips");
        compare(Actions.keyAction(Qt.Key_Tab, Qt.ShiftModifier, 23), "chips", "wtype sends Shift+Tab as Tab with Shift");
        compare(Actions.keyAction(Qt.Key_Tab, Qt.ControlModifier, 23), "", "Ctrl+Tab is not ours");
        compare(Actions.keyAction(Qt.Key_Tab, Qt.AltModifier, 23), "");
    }

    function test_groupKeys() {
        compare(Actions.keyAction(Qt.Key_PageDown, 0, 117), "groupNext");
        compare(Actions.keyAction(Qt.Key_PageUp, 0, 112), "groupPrev");
        compare(Actions.keyAction(Qt.Key_Down, Qt.ControlModifier, 116), "groupNext");
        compare(Actions.keyAction(Qt.Key_Up, Qt.ControlModifier, 111), "groupPrev");
        compare(Actions.keyAction(Qt.Key_Down, 0, 116), "", "plain Down is the row move");
        compare(Actions.keyAction(Qt.Key_Up, 0, 111), "");
        compare(Actions.keyAction(Qt.Key_PageDown, Qt.ShiftModifier, 117), "");
        compare(Actions.keyAction(Qt.Key_Down, Qt.ControlModifier | Qt.ShiftModifier, 116), "");
    }

    function test_commandKSwitch() {
        // Off until the nested proof (P3c): neither Ctrl+K nor Super+K opens Actions.
        compare(Actions.keyAction(Qt.Key_K, Qt.ControlModifier, 45), "");
        compare(Actions.keyAction(Qt.Key_K, Qt.MetaModifier, 45, {}), "");
        compare(Actions.keyAction(Qt.Key_K, Qt.ControlModifier, 45, {cmdK: false}), "");
        // On: ⌘K (Super+K, or Ctrl+K forwarded), by symbol or by place.
        const on = {cmdK: true};
        compare(Actions.keyAction(Qt.Key_K, Qt.ControlModifier, 45, on), "actions");
        compare(Actions.keyAction(Qt.Key_K, Qt.MetaModifier, 45, on), "actions");
        compare(Actions.keyAction(Qt.Key_K, 0, 45, on), "", "a typed k");
        compare(Actions.keyAction(Qt.Key_K, Qt.ControlModifier | Qt.ShiftModifier, 45, on), "");
        // Another layout types another symbol at K's place (Dvorak: its keycode 45 is "t"): the place still counts, as for ⌘4.
        compare(Actions.keyAction(Qt.Key_T, Qt.ControlModifier, 45, on), "actions");
        compare(Actions.keyAction(Qt.Key_T, Qt.ControlModifier, 28, on), "", "Ctrl+T elsewhere");
    }

    function test_azertyPlaces() {
        // The keys of the table sit in the same place on AZERTY and QWERTY (Tab, Page, arrows): the scan code never changes them.
        for (const code of [23, 0, 99]) {
            compare(Actions.keyAction(Qt.Key_Tab, 0, code), "actions");
            compare(Actions.keyAction(Qt.Key_PageDown, 0, code), "groupNext");
        }
        // AZERTY: the number row types symbols; none of them is a key of this table, Ctrl+4 included (⌘4 is the Clipboard view's).
        compare(Actions.keyAction(Qt.Key_Apostrophe, Qt.ControlModifier, 13, {cmdK: true}), "");
        compare(Actions.keyAction(Qt.Key_4, Qt.ControlModifier, 13, {cmdK: true}), "");
    }

    function test_otherKeys() {
        compare(Actions.keyAction(Qt.Key_A, 0, 38), "");
        compare(Actions.keyAction(Qt.Key_Return, 0, 36), "");
        compare(Actions.keyAction(Qt.Key_Escape, 0, 9), "");
    }
}
