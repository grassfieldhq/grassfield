import QtQuick
import QtTest
import Grassfield.Ui

// DisplayScope (global value + optional per-display override, owner 2026-11-22): validation, resolution, writes, and the rule
// for values stored before overrides existed.
TestCase {
    name: "DisplayScope"

    readonly property var schema: DisplayScope.DOCK_SCHEMA
    readonly property var globals: ({size: 48, position: "bottom", magnification: 1.6, magnificationEnabled: false, autohide: false})
    readonly property var a: ({name: "DP-1", model: "U2723QE", serial: "A1"})
    readonly property var b: ({name: "DP-2", model: "U2723QE", serial: "A2"})
    // The same monitor on another port: identified by model and serial, not by the connector.
    readonly property var aMoved: ({name: "DP-3", model: "U2723QE", serial: "A1"})
    readonly property var panel: ({name: "eDP-1", model: "", serial: ""})

    function test_noOverrideIsTheGlobalValue() {
        compare(DisplayScope.resolve(schema, globals, [], a), globals);
        compare(DisplayScope.resolve(schema, globals, undefined, a), globals);
        compare(DisplayScope.resolve(schema, globals, [], null), globals);
    }

    function test_overrideAppliesToItsDisplayOnly() {
        const list = DisplayScope.withOverride(schema, [], a, {autohide: true, size: 80});
        compare(DisplayScope.resolve(schema, globals, list, a).autohide, true);
        compare(DisplayScope.resolve(schema, globals, list, a).size, 80);
        compare(DisplayScope.resolve(schema, globals, list, a).position, "bottom");
        compare(DisplayScope.resolve(schema, globals, list, b), globals);
        compare(DisplayScope.resolve(schema, globals, list, panel), globals);
        // A display is the same display on another connector.
        compare(DisplayScope.resolve(schema, globals, list, aMoved).size, 80);
        verify(DisplayScope.overridden(schema, list, a, "size"));
        verify(!DisplayScope.overridden(schema, list, a, "position"));
        verify(!DisplayScope.overridden(schema, list, b, "size"));
    }

    function test_writesMergeIntoOneEntryAndClear() {
        let list = DisplayScope.withOverride(schema, [], a, {autohide: true});
        list = DisplayScope.withOverride(schema, list, a, {position: "left"});
        list = DisplayScope.withOverride(schema, list, b, {size: 40});
        compare(list.length, 2);
        compare(list[0], {display: {name: "DP-1", model: "U2723QE", serial: "A1"}, autohide: true, position: "left"});
        list = DisplayScope.withoutOverride(schema, list, a);
        compare(list.length, 1);
        verify(!DisplayScope.hasOverride(schema, list, a));
        verify(DisplayScope.hasOverride(schema, list, b));
        // An override of a display that is not connected stays: nothing here prunes it.
        compare(DisplayScope.resolve(schema, globals, list, b).size, 40);
    }

    function test_theListIsCapped() {
        let list = [];
        for (let i = 0; i < 20; i++)
            list = DisplayScope.withOverride(schema, list, {name: "X-" + i, model: "", serial: ""}, {size: 40});
        compare(list.length, DisplayScope.MAX_OUTPUTS);
    }

    function test_validationRefusesWhatTheSchemaRefuses() {
        compare(DisplayScope.problem(schema, []), "");
        compare(DisplayScope.problem(schema, [{display: a, size: 40, position: "right", magnification: 2, magnificationEnabled: true, autohide: false}]), "");
        verify(DisplayScope.problem(schema, "no") !== "");
        verify(DisplayScope.problem(schema, [{display: a, size: 31}]) !== "");
        verify(DisplayScope.problem(schema, [{display: a, size: 40.5}]) !== "");
        verify(DisplayScope.problem(schema, [{display: a, position: "top"}]) !== "");
        verify(DisplayScope.problem(schema, [{display: a, magnification: 3}]) !== "");
        verify(DisplayScope.problem(schema, [{display: a, autohide: "yes"}]) !== "");
        verify(DisplayScope.problem(schema, [{display: a, colour: "red"}]) !== "");
        verify(DisplayScope.problem(schema, [{size: 40}]) !== "");
        verify(DisplayScope.problem(schema, [{display: a, size: 40}, {display: a, size: 50}]) !== "");
        const many = [];
        for (let i = 0; i < 17; i++)
            many.push({display: {name: "X-" + i, model: "", serial: ""}});
        verify(DisplayScope.problem(schema, many) !== "");
    }

    // A hand-edited or damaged file never breaks the Dock: bad entries are dropped, good ones read.
    function test_readingDropsBadEntries() {
        const raw = [{display: a, size: 80}, {display: b, size: 12}, {display: a, size: 50}, "x", {display: panel, autohide: true, junk: 1}];
        const list = DisplayScope.normalize(schema, raw);
        compare(list.length, 1);
        compare(list[0].size, 80);
        compare(DisplayScope.normalize(schema, 5), []);
    }

    // Migration: before overrides a Dock setting was one global value. That value stays the All Displays value for every display
    // and no entry exists: nothing is converted, so nothing changes for anyone. An entry equal to the global value (a file edited
    // by hand) carries no information and is dropped by dropEqualToGlobal.
    function test_migrationKeepsGlobalValuesAndDropsRedundantEntries() {
        const stored = {size: 64, position: "left", magnification: 1.6, magnificationEnabled: true, autohide: true};
        compare(DisplayScope.resolve(schema, stored, [], a), stored);
        compare(DisplayScope.resolve(schema, stored, [], panel), stored);
        const edited = [{display: a, size: 64, autohide: false}, {display: b, size: 64}];
        const kept = DisplayScope.dropEqualToGlobal(schema, stored, edited);
        compare(kept.length, 1);
        compare(kept[0], {display: a, autohide: false});
    }
}
