import QtQuick
import QtTest
import "../../shell/search/Commands.js" as Commands
import "../../shell/search/BuiltinCommands.js" as Builtin

// The built-in commands of Search (ADR-0067 slices S1, S3, S6): each id reaches the function the UI already calls, titles
// follow the state, a command is offered only when its service is, and nothing runs while the session is locked.
TestCase {
    name: "SearchBuiltin"

    property var calls: []
    property bool locked: false

    function rec(name) {
        return (...a) => calls.push([name].concat(a).join(":"));
    }

    readonly property var places: ({left: "Left", right: "Right", top: "Top", bottom: "Bottom", "top-left": "Top Left", "top-right": "Top Right",
            "bottom-left": "Bottom Left", "bottom-right": "Bottom Right", fill: "Fill", center: "Center", previous: "Return to Previous Size"})
    readonly property var layouts: ({"left-right": "Left & Right", "right-left": "Right & Left", "top-bottom": "Top & Bottom", "bottom-top": "Bottom & Top",
            quarters: "Quarters", "left-quarters": "Left & Quarters", "right-quarters": "Right & Quarters", "top-quarters": "Top & Quarters",
            "bottom-quarters": "Bottom & Quarters"})

    function words(extra) {
        const t = {subtitleSystem: "System command", subtitleWindow: "Window", appearance: "Toggle Appearance", appearanceWords: ["theme"],
            appearanceDark: "Dark", appearanceLight: "Light", trashEmpty: "Empty Trash", trashEmptyWords: [], trashOpen: "Open Trash", trashOpenWords: [],
            showDesktop: "Show Desktop", showDesktopWords: [], volumeUp: "Volume Up", volumeUpWords: [], volumeDown: "Volume Down", volumeDownWords: [],
            mute: "Mute", unmute: "Unmute", muteWords: [], stateMuted: "Muted", stateNotMuted: "Sound on", play: "Play", pause: "Pause", playWords: [],
            statePlaying: "Playing", statePaused: "Paused", nextTrack: "Next Track", nextTrackWords: [], previousTrack: "Previous Track", previousTrackWords: [],
            tileWord: "window", tileFmt: "Move Window: %1", arrangeFmt: "Arrange Windows: %1", places: places, layouts: layouts,
            nextDisplay: "Move Window to Next Display", previousDisplay: "Move Window to Previous Display", displayWords: ["monitor"],
            minimize: "Minimize Window", minimizeWords: [], enterFullscreen: "Enter Full Screen", exitFullscreen: "Exit Full Screen", fullscreenWords: [],
            stateOn: "On", stateOff: "Off", stateOnUntil: "On until %1", wifiTurnOn: "Turn Wi-Fi On", wifiTurnOff: "Turn Wi-Fi Off", wifiWords: ["wifi"],
            bluetoothTurnOn: "Turn Bluetooth On", bluetoothTurnOff: "Turn Bluetooth Off", bluetoothWords: [],
            airplaneTurnOn: "Turn Airplane Mode On", airplaneTurnOff: "Turn Airplane Mode Off", airplaneWords: [],
            dndTurnOn: "Turn Do Not Disturb On", dndTurnOff: "Turn Do Not Disturb Off", dndHour: "Do Not Disturb for 1 Hour",
            dndTomorrow: "Do Not Disturb Until Tomorrow", dndWords: ["focus"], nightLightTurnOn: "Turn Night Light On",
            nightLightTurnOff: "Turn Night Light Off", nightLightWords: []};
        return Object.assign(t, extra || {});
    }

    function sysState(extra) {
        return Object.assign({dark: true, trashEmpty: false, audioReady: true, muted: false, mediaAvailable: true, playing: false}, extra || {});
    }

    function sysAct() {
        return {appearance: rec("appearance"), emptyTrash: rec("ask-empty-trash"), openTrash: rec("openTrash"), showDesktop: rec("showDesktop"),
            volume: rec("volume"), media: rec("media")};
    }

    function ctx(extra) {
        return Object.assign({hasTarget: true, canTile: true, canArrange: true, canMoveOutput: true, canMinimize: true, fullscreen: false}, extra || {});
    }

    function winAct() {
        return {tile: rec("tile"), arrange: rec("arrange"), nextOutput: rec("nextOutput"), minimize: rec("minimize"), fullscreen: rec("fullscreen")};
    }

    function togState(extra) {
        const base = {wifi: {available: true, on: true}, bluetooth: {available: true, on: false}, airplane: {available: true, on: false},
            dnd: {available: true, on: false, until: 0, untilText: ""}, nightLight: {available: true, on: false}};
        return Object.assign(base, extra || {});
    }

    function togAct() {
        return {wifi: rec("wifi"), bluetooth: rec("bluetooth"), airplane: rec("airplane"), dnd: rec("dnd"), dndFor: rec("dndFor"), nightLight: rec("nightLight")};
    }

    function refuses() {
        return locked;
    }

    function reg(list) {
        const r = Commands.build([list]);
        compare(r.errors, []);
        return r;
    }

    function runId(r, id) {
        return Commands.run(r, id, [], "row");
    }

    function init() {
        calls = [];
        locked = false;
    }

    // ---- S1 ----

    function test_systemEachIdCallsItsFunction() {
        const r = reg(Builtin.systemCommands(words(), sysState(), sysAct(), refuses));
        const want = {"sys.appearance": "appearance:false", "sys.trash.empty": "ask-empty-trash", "sys.trash.open": "openTrash", "sys.desktop": "showDesktop",
            "sys.volume.up": "volume:up", "sys.volume.down": "volume:down", "sys.volume.mute": "volume:mute", "sys.media.toggle": "media:toggle",
            "sys.media.next": "media:next", "sys.media.previous": "media:previous"};
        for (const id of Object.keys(want)) {
            calls = [];
            verify(runId(r, id), id);
            compare(calls, [want[id]], id);
        }
    }

    function test_appearanceTogglesFromState() {
        const r = reg(Builtin.systemCommands(words(), sysState({dark: false}), sysAct(), refuses));
        runId(r, "sys.appearance");
        compare(calls, ["appearance:true"]);
        compare(Commands.find(r, "sys.appearance").subtitle, "Light");
    }

    function test_emptyTrashOnlyWhenNotEmptyAndAsks() {
        const r = reg(Builtin.systemCommands(words(), sysState({trashEmpty: true}), sysAct(), refuses));
        verify(!runId(r, "sys.trash.empty"));
        compare(calls, []);
        compare(Commands.match(r, "empty trash").length, 0);
        // The act is the confirmation request, never the deletion: the deletion is Power.run("emptytrash") after the answer.
        const r2 = reg(Builtin.systemCommands(words(), sysState(), sysAct(), refuses));
        runId(r2, "sys.trash.empty");
        compare(calls, ["ask-empty-trash"]);
    }

    function test_audioAndMediaNeedTheirService() {
        const r = reg(Builtin.systemCommands(words(), sysState({audioReady: false, mediaAvailable: false}), sysAct(), refuses));
        for (const id of ["sys.volume.up", "sys.volume.down", "sys.volume.mute", "sys.media.toggle", "sys.media.next", "sys.media.previous"])
            verify(!runId(r, id), id);
        compare(calls, []);
    }

    function test_muteAndPlayTitlesFollowState() {
        const r = reg(Builtin.systemCommands(words(), sysState({muted: true, playing: true}), sysAct(), refuses));
        compare(Commands.find(r, "sys.volume.mute").title, "Unmute");
        compare(Commands.find(r, "sys.volume.mute").subtitle, "Muted");
        compare(Commands.find(r, "sys.media.toggle").title, "Pause");
        const r2 = reg(Builtin.systemCommands(words(), sysState(), sysAct(), refuses));
        compare(Commands.find(r2, "sys.volume.mute").title, "Mute");
        compare(Commands.find(r2, "sys.media.toggle").title, "Play");
    }

    function test_nothingRunsWhileLocked() {
        locked = true;
        const r = reg(Builtin.systemCommands(words(), sysState(), sysAct(), refuses)
            .concat(Builtin.windowCommands(words(), ctx(), winAct(), refuses))
            .concat(Builtin.toggleCommands(words(), togState(), togAct(), refuses)));
        for (const e of r.entries)
            runId(r, e.id);
        compare(calls, []);
        locked = false;
        runId(r, "set.wifi");
        compare(calls, ["wifi:false"]);
    }

    // ---- S3 ----

    function test_placesMapToTileArgs() {
        const r = reg(Builtin.windowCommands(words(), ctx(), winAct(), refuses));
        for (const place of Object.keys(places)) {
            calls = [];
            verify(runId(r, "win.tile." + place), place);
            compare(calls, ["tile:" + place]);
        }
        for (const layout of Object.keys(layouts)) {
            calls = [];
            verify(runId(r, "win.arrange." + layout), layout);
            compare(calls, ["arrange:" + layout]);
        }
        calls = [];
        runId(r, "win.display.next");
        runId(r, "win.display.previous");
        runId(r, "win.minimize");
        runId(r, "win.fullscreen");
        compare(calls, ["nextOutput:right", "nextOutput:left", "minimize", "fullscreen"]);
        compare(Commands.find(r, "win.tile.left").title, "Move Window: Left");
        compare(Commands.find(r, "win.tile.previous").title, "Return to Previous Size");
    }

    function test_windowCommandsGreyedWithoutFeatures() {
        let r = reg(Builtin.windowCommands(words(), ctx({canTile: false, canArrange: false, canMoveOutput: false, canMinimize: false}), winAct(), refuses));
        verify(!runId(r, "win.tile.left"));
        verify(!runId(r, "win.arrange.quarters"));
        verify(!runId(r, "win.display.next"));
        verify(!runId(r, "win.minimize"));
        compare(calls, []);
        verify(runId(r, "win.fullscreen"));   // needs no plugin feature
        compare(Commands.find(r, "win.fullscreen").title, "Enter Full Screen");
        r = reg(Builtin.windowCommands(words(), ctx({fullscreen: true}), winAct(), refuses));
        compare(Commands.find(r, "win.fullscreen").title, "Exit Full Screen");
    }

    function test_windowCommandsDroppedWithoutTarget() {
        const r = reg(Builtin.windowCommands(words(), ctx({hasTarget: false}), winAct(), refuses));
        for (const e of r.entries)
            verify(!runId(r, e.id), e.id);
        compare(calls, []);
        compare(Commands.match(r, "window").length, 0);
    }

    // ---- S6 ----

    function test_togglesTitlesFollowState() {
        let r = reg(Builtin.toggleCommands(words(), togState(), togAct(), refuses));
        compare(Commands.find(r, "set.wifi").title, "Turn Wi-Fi Off");
        compare(Commands.find(r, "set.wifi").subtitle, "On");
        compare(Commands.find(r, "set.bluetooth").title, "Turn Bluetooth On");
        compare(Commands.find(r, "set.bluetooth").subtitle, "Off");
        compare(Commands.find(r, "set.airplane").title, "Turn Airplane Mode On");
        compare(Commands.find(r, "set.dnd").title, "Turn Do Not Disturb On");
        compare(Commands.find(r, "set.nightlight").title, "Turn Night Light On");
        r = reg(Builtin.toggleCommands(words(), togState({wifi: {available: true, on: false}, nightLight: {available: true, on: true}}), togAct(), refuses));
        compare(Commands.find(r, "set.wifi").title, "Turn Wi-Fi On");
        compare(Commands.find(r, "set.nightlight").title, "Turn Night Light Off");
        compare(Commands.match(r, "wifi")[0].cmd.id, "set.wifi");
    }

    function test_togglesCallTheControlCenterFunctionsWithTheOppositeState() {
        const r = reg(Builtin.toggleCommands(words(), togState(), togAct(), refuses));
        for (const id of ["set.wifi", "set.bluetooth", "set.airplane", "set.dnd", "set.dnd.hour", "set.dnd.tomorrow", "set.nightlight"])
            runId(r, id);
        compare(calls, ["wifi:false", "bluetooth:true", "airplane:true", "dnd:true", "dndFor:hour", "dndFor:tomorrow", "nightLight:true"]);
    }

    function test_togglesNeedTheirService() {
        const none = {available: false, on: false};
        const r = reg(Builtin.toggleCommands(words(), togState({wifi: none, bluetooth: none, airplane: none, nightLight: none}), togAct(), refuses));
        for (const id of ["set.wifi", "set.bluetooth", "set.airplane", "set.nightlight"])
            verify(!runId(r, id), id);
        compare(Commands.match(r, "bluetooth").length, 0);
        verify(runId(r, "set.dnd"));
    }

    function test_dndForOffersOnlyWhenOffAndShowsTheDeadline() {
        const on = {available: true, on: true, until: 1, untilText: "3:00 PM"};
        const r = reg(Builtin.toggleCommands(words(), togState({dnd: on}), togAct(), refuses));
        verify(!runId(r, "set.dnd.hour"));
        verify(!runId(r, "set.dnd.tomorrow"));
        compare(Commands.find(r, "set.dnd").title, "Turn Do Not Disturb Off");
        compare(Commands.find(r, "set.dnd").subtitle, "On until 3:00 PM");
    }

    function test_dndDeadlineAndExpiry() {
        const now = new Date(2026, 10, 23, 22, 30, 0).getTime();
        compare(Builtin.dndDeadline("hour", now), now + 3600000);
        compare(Builtin.dndDeadline("tomorrow", now), new Date(2026, 10, 24, 8, 0, 0).getTime());
        // Past midnight "tomorrow" is the next day's morning, still after now.
        const late = new Date(2026, 10, 24, 0, 5, 0).getTime();
        compare(Builtin.dndDeadline("tomorrow", late), new Date(2026, 10, 25, 8, 0, 0).getTime());
        compare(Builtin.dndDeadline("never", now), 0);
        const until = now + 3600000;
        compare(Builtin.dndStep(0, true, now), "none");
        compare(Builtin.dndStep(until, true, now), "wait");
        compare(Builtin.dndStep(until, true, until), "expire");
        compare(Builtin.dndStep(until, true, until + 5 * 3600000), "expire");   // a resume long after the deadline
        compare(Builtin.dndStep(until, false, now), "clear");                  // turned off by hand: the deadline is forgotten
    }

    function test_allIdsAreValidAndDistinct() {
        const all = Builtin.systemCommands(words(), sysState(), sysAct(), refuses)
            .concat(Builtin.windowCommands(words(), ctx(), winAct(), refuses))
            .concat(Builtin.toggleCommands(words(), togState(), togAct(), refuses));
        const r = Commands.build([all]);
        compare(r.errors, []);
        compare(r.entries.length, all.length);
        // Not colliding with the five system commands of Commands.systemCommands.
        for (const e of all)
            verify(!/^sys\.(lock|sleep|restart|shutdown|logout)$/.test(e.id), e.id);
    }
}
