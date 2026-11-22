import QtQuick
import QtTest
import Grassfield.Ui

// DisplayScope (global value + optional per-display override, owner 2026-11-22): validation, resolution, writes, and the rule
// for values stored before overrides existed.
TestCase {
    name: "DisplayScope"

    readonly property var schema: SettingsContract.DOCK_SCHEMA
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

    // The menu bar and the screen corners use the same model with their own fields.
    function test_menuBarAndCornersSchemas() {
        const bar = SettingsContract.MENUBAR_SCHEMA;
        const corners = SettingsContract.HOTCORNERS_SCHEMA;
        compare(SettingsContract.scopeSchema("menubarOutputs"), bar);
        compare(SettingsContract.scopeSchema("hotCornersOutputs"), corners);
        compare(SettingsContract.scopeSchema("nope"), null);
        const barGlobals = {autoHide: "fullscreen", showBackground: false};
        const list = DisplayScope.withOverride(bar, [], a, {autoHide: "always"});
        compare(DisplayScope.resolve(bar, barGlobals, list, a).autoHide, "always");
        compare(DisplayScope.resolve(bar, barGlobals, list, b).autoHide, "fullscreen");
        compare(DisplayScope.problem(bar, [{display: a, autoHide: "sometimes"}]) !== "", true);
        const cg = {topLeft: "none", topRight: "none", bottomLeft: "none", bottomRight: "none"};
        const cl = DisplayScope.withOverride(corners, [], b, {topLeft: "overview", bottomRight: "lock"});
        compare(DisplayScope.resolve(corners, cg, cl, b).topLeft, "overview");
        compare(DisplayScope.resolve(corners, cg, cl, b).topRight, "none");
        compare(DisplayScope.resolve(corners, cg, cl, a), cg);
        compare(DisplayScope.problem(corners, [{display: a, topLeft: "reboot"}]) !== "", true);
        // A dock field is not a menu bar field.
        compare(DisplayScope.problem(bar, [{display: a, size: 40}]) !== "", true);
    }

    // The bounds are the keys' own: a field's rule in the schema IS the rule of its key, so the two cannot drift apart.
    function test_schemasAreTheKeysOwnRules() {
        compare(schema.size, SettingsContract.RULES["dock.size"]);
        compare(schema.magnification, SettingsContract.RULES["dock.magnification"]);
        compare(SettingsContract.MENUBAR_SCHEMA.autoHide, SettingsContract.RULES["menubar.autoHide"]);
        compare(SettingsContract.HOTCORNERS_SCHEMA.topLeft, SettingsContract.RULES["hotCorners.topLeft"]);
    }

    // Review 2026-11-22: the shell's screens report `serialNumber`, the Settings app's `serial`. Both must make the same identity,
    // or an override Settings writes for a monitor with a serial is silently ignored by the shell.
    function test_oneIdentityForTheShellAndSettings() {
        const shellScreen = {name: "DP-1", model: "U2723QE", serialNumber: "A1"};
        const appScreen = {name: "DP-1", model: "U2723QE", serial: "A1"};
        compare(DisplayScope.identity(shellScreen), {name: "DP-1", model: "U2723QE", serial: "A1"});
        compare(DisplayScope.identity(shellScreen), DisplayScope.identity(appScreen));
        compare(WallpaperConfig.displayKey(DisplayScope.identity(shellScreen)), "s:U2723QE|A1");
        // What Settings writes is found by the shell's screen, also on another connector.
        const list = DisplayScope.withOverride(schema, [], DisplayScope.identity(appScreen), {autohide: true});
        compare(DisplayScope.resolve(schema, globals, list, DisplayScope.identity(shellScreen)).autohide, true);
        compare(DisplayScope.resolve(schema, globals, list, DisplayScope.identity({name: "DP-9", model: "U2723QE", serialNumber: "A1"})).autohide, true);
        // No serial: the connector identifies the display.
        compare(WallpaperConfig.displayKey(DisplayScope.identity({name: "eDP-1", model: "", serialNumber: ""})), "n:eDP-1");
        compare(DisplayScope.identity(null), {name: "", model: "", serial: ""});
    }
}
