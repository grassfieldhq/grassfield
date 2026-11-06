import QtQuick
import QtTest
import "../../shell/services/AppEnergyLogic.js" as Logic

// ADR-0048 D-1: what the person can see, per window and per process. The app in front is never anything but focused; a
// window is occluded only when the focused window (the one whose place in the stacking order is known) covers it outright;
// minimized, hidden, parked, unmapped windows, other Desktops and a hidden Stages strip are hidden; when unsure, visible.
TestCase {
    name: "AppEnergy"

    // A floating window on Desktop 1 of 1000 x 800 at (0, 0), mapped, not pinned.
    function win(address, pid, extra) {
        return Object.assign({address: address, pid: pid, workspaceId: 1, workspaceName: "1", mapped: true, hidden: false, minimized: false,
            floating: true, pinned: false, fullscreen: 0, x: 0, y: 0, w: 1000, h: 800}, extra || {});
    }

    function ctx(extra) {
        return Object.assign({focused: [], shown: [1], parked: ["special:minimized", "special:hidden", "special:desktop"],
            strip: {}, awake: false}, extra || {});
    }

    function test_theFocusedWindowIsFocusedWhateverElse() {
        const a = win("a", 10, {minimized: true, workspaceId: 7});
        compare(Logic.windowState(a, ctx({focused: ["a"]}), null), "focused");
        // The window in front of a quick look counts as focused too (both addresses are given).
        compare(Logic.evaluate([win("a", 10), win("q", 11, {x: 100, y: 100, w: 10, h: 10})], ctx({focused: ["a", "q"]})).pids, {"10": "focused", "11": "focused"});
    }

    function test_parkedWindowsAreHidden() {
        const c = ctx({focused: ["z"]});
        compare(Logic.windowState(win("a", 10, {minimized: true}), c, null), "hidden");
        compare(Logic.windowState(win("a", 10, {workspaceId: -98, workspaceName: "special:minimized"}), c, null), "hidden");
        compare(Logic.windowState(win("a", 10, {workspaceId: -97, workspaceName: "special:hidden"}), c, null), "hidden");
        compare(Logic.windowState(win("a", 10, {workspaceId: -96, workspaceName: "special:desktop"}), c, null), "hidden");
        compare(Logic.windowState(win("a", 10, {mapped: false}), c, null), "hidden");
        compare(Logic.windowState(win("a", 10, {hidden: true}), c, null), "hidden");
    }

    function test_otherDesktopsAreHiddenShownOnesVisible() {
        const c = ctx({shown: [1, 4]});
        compare(Logic.windowState(win("a", 10, {workspaceId: 2}), c, null), "hidden");
        compare(Logic.windowState(win("a", 10, {workspaceId: 4}), c, null), "visible");
        compare(Logic.windowState(win("a", 10), c, null), "visible");
    }

    function test_aScratchpadMayBeShownSoItIsVisible() {
        compare(Logic.windowState(win("a", 10, {workspaceId: -90, workspaceName: "special:scratch"}), ctx(), null), "visible");
    }

    function test_awakeMakesEverythingVisibleButTheFocus() {
        const list = [win("f", 1), win("m", 2, {minimized: true}), win("o", 3, {workspaceId: 9})];
        compare(Logic.evaluate(list, ctx({focused: ["f"], awake: true})).pids, {"1": "focused", "2": "visible", "3": "visible"});
    }

    function test_occludedOnlyByOneWindowThatCoversItOutright() {
        const front = win("f", 1, {x: 0, y: 0, w: 1000, h: 800});
        const inside = win("i", 2, {x: 100, y: 100, w: 300, h: 200});
        const edge = win("e", 3, {x: 0, y: 0, w: 1000, h: 800});
        const out = win("o", 4, {x: 900, y: 100, w: 300, h: 200});
        const c = ctx({focused: ["f"]});
        const r = Logic.evaluate([front, inside, edge, out], c).pids;
        compare(r["2"], "occluded");
        compare(r["3"], "occluded", "same rectangle: covered outright");
        compare(r["4"], "visible", "sticks out: visible");
    }

    function test_regionsAreNeverSummed() {
        // Two unfocused windows together cover the third: nothing is known about their order, so it stays visible.
        const left = win("l", 1, {x: 0, y: 0, w: 500, h: 800});
        const right = win("r", 2, {x: 500, y: 0, w: 500, h: 800});
        const under = win("u", 3, {x: 100, y: 100, w: 800, h: 600});
        const focus = win("f", 4, {x: 0, y: 0, w: 500, h: 800});
        compare(Logic.evaluate([focus, right, under], ctx({focused: ["f"]})).pids["3"], "visible");
        compare(Logic.evaluate([left, right, under], ctx({focused: []})).pids["3"], "visible");
    }

    function test_onlyAKnownTopOccludes() {
        const inside = win("i", 2, {x: 100, y: 100, w: 300, h: 200});
        // Not floating (tiled windows do not overlap), full screen, or a full-screen window on the Desktop: no known top.
        compare(Logic.occluder([win("f", 1, {floating: false}), inside], ctx({focused: ["f"]})), null);
        compare(Logic.occluder([win("f", 1, {fullscreen: 2}), inside], ctx({focused: ["f"]})), null);
        compare(Logic.occluder([win("f", 1), inside, win("x", 5, {fullscreen: 3, w: 10, h: 10, x: 2000})], ctx({focused: ["f"]})), null);
        // Zoom (maximized, mode 1) is raised like any window.
        verify(Logic.occluder([win("f", 1, {fullscreen: 1}), inside], ctx({focused: ["f"]})) !== null);
        // A full-screen window on another Desktop does not matter.
        verify(Logic.occluder([win("f", 1), inside, win("x", 5, {fullscreen: 2, workspaceId: 3})], ctx({focused: ["f"]})) !== null);
        // No focused window, or a parked one: no top.
        compare(Logic.occluder([win("f", 1), inside], ctx({focused: []})), null);
        compare(Logic.occluder([win("f", 1, {minimized: true}), inside], ctx({focused: ["f"]})), null);
    }

    function test_pinnedOrOtherDesktopWindowsAreNotOccluded() {
        const front = win("f", 1);
        compare(Logic.evaluate([front, win("p", 2, {pinned: true, x: 10, y: 10, w: 10, h: 10})], ctx({focused: ["f"]})).pids["2"], "visible");
        compare(Logic.evaluate([front, win("d", 3, {workspaceId: 2, x: 10, y: 10, w: 10, h: 10})], ctx({focused: ["f"], shown: [1, 2]})).pids["3"], "visible");
    }

    function test_missingGeometryIsNeverCovered() {
        verify(!Logic.covers({x: 0, y: 0, w: 100, h: 100}, {x: 10, y: 10, w: NaN, h: 5}));
        verify(!Logic.covers({x: 0, y: 0, w: 0, h: 0}, {x: 0, y: 0, w: 0, h: 0}));
        verify(!Logic.covers(null, {x: 0, y: 0, w: 1, h: 1}));
        verify(Logic.covers({x: 0, y: 0, w: 100, h: 100}, {x: 0, y: 0, w: 100, h: 100}));
    }

    function test_stagesStripWindows() {
        const stages = {on: true, monitors: {"DP-1": {monitor: "DP-1", active: 5, hidden: false, stages: [
            {id: 5, slot: -1, windows: [{address: "a"}]},
            {id: 7, slot: 0, windows: [{address: "b"}]},
            {id: 8, slot: -1, windows: [{address: "c"}]}]}, "DP-2": {monitor: "DP-2", active: 1, hidden: true, stages: [
            {id: 1, slot: -1, windows: [{address: "d"}]},
            {id: 2, slot: 0, windows: [{address: "e"}, {address: "f"}]}]}}};
        compare(Logic.stripStates(stages), {b: "visible", c: "hidden", e: "hidden", f: "hidden"});
        compare(Logic.stripStates(null), {});
        compare(Logic.stripStates({on: false, monitors: {}}), {});
        // A strip window drawn in its tile is visible even under the focused window; a hidden strip's is hidden.
        const c = ctx({focused: ["a"], strip: Logic.stripStates(stages)});
        const r = Logic.evaluate([win("a", 1), win("b", 2, {x: 5, y: 5, w: 5, h: 5}), win("c", 3), win("e", 4)], c).pids;
        compare(r, {"1": "focused", "2": "visible", "3": "hidden", "4": "hidden"});
    }

    function test_aProcessIsAsAwakeAsItsMostAwakeWindow() {
        const list = [win("a", 10, {minimized: true}), win("b", 10, {workspaceId: 2}), win("c", 20, {minimized: true}), win("d", 20, {workspaceId: 1})];
        compare(Logic.evaluate(list, ctx()).pids, {"10": "hidden", "20": "visible"});
        // Whatever the order of the windows: the focused one first, then a minimized one of the same process.
        compare(Logic.evaluate([win("f", 30), win("m", 30, {minimized: true})], ctx({focused: ["f"]})).pids, {"30": "focused"});
        compare(Logic.evaluate([win("m", 30, {minimized: true}), win("f", 30)], ctx({focused: ["f"]})).pids, {"30": "focused"});
        compare(Logic.evaluate([win("v", 40), win("h", 40, {workspaceId: 9})], ctx()).pids, {"40": "visible"});
        compare(Logic.moreAwake("hidden", "occluded"), "occluded");
        compare(Logic.moreAwake("focused", "visible"), "focused");
    }

    function test_anUnknownProcessMakesThePictureUncertain() {
        // A new focused window whose pid Hyprland has not given yet: the app's other, hidden window must not be limited.
        const list = [win("new", 0), win("old", 10, {minimized: true}), win("bg", 20, {workspaceId: 3})];
        const r = Logic.evaluate(list, ctx({focused: ["new"]}));
        verify(r.uncertain);
        compare(r.pids, {"10": "visible", "20": "visible"});
        // An unknown process with only hidden windows changes nothing.
        const s = Logic.evaluate([win("x", 0, {minimized: true}), win("y", 30, {minimized: true})], ctx());
        verify(!s.uncertain);
        compare(s.pids, {"30": "hidden"});
    }

    // An occluded picture waits for geometry read within the last refreshGapMs (moves and resizes send no event).
    function test_occlusionNeedsFreshGeometry() {
        verify(Logic.needsFreshGeometry({"1": "occluded"}, 0, 100000));
        verify(!Logic.needsFreshGeometry({"1": "occluded"}, 100000 - Logic.refreshGapMs, 100000));
        verify(Logic.needsFreshGeometry({"1": "focused", "2": "occluded"}, 100000 - Logic.refreshGapMs - 1, 100000));
        verify(!Logic.needsFreshGeometry({"1": "hidden", "2": "visible"}, 0, 100000), "hidden and visible need no geometry");
        verify(!Logic.needsFreshGeometry({}, 0, 100000));
    }

    // Nothing on the power adapter (ADR-0048 D-2): a round only to lift what is still held; without a battery, never.
    function test_roundOnlyOnBatteryOrToLift() {
        verify(Logic.roundWanted(true, false));
        verify(Logic.roundWanted(true, true));
        verify(Logic.roundWanted(false, true), "plugged in with limits held: one round to lift them");
        verify(!Logic.roundWanted(false, false), "on the power adapter, or no battery at all: nothing runs");
    }

    function test_anyLimitable() {
        verify(!Logic.anyLimitable({"1": "focused", "2": "visible"}));
        verify(Logic.anyLimitable({"1": "focused", "2": "occluded"}));
        verify(Logic.anyLimitable({"2": "hidden"}));
        verify(!Logic.anyLimitable({}));
    }

    function test_streamPids() {
        compare(Logic.streamPids([{"pipewire.sec.pid": "42"}, {"pipewire.sec.pid": 42}, {"pipewire.sec.pid": "7"}, {}, null,
            {"pipewire.sec.pid": "-1"}, {"pipewire.sec.pid": "x"}, {"pipewire.sec.pid": "99999999"}]), [7, 42]);
        compare(Logic.streamPids(undefined), []);
    }

    // The client-set process id is not a claim (review finding 3): a stream that names a process of its own choosing
    // protects nothing but what the server saw.
    function test_streamPidsIgnoreTheClientsOwnClaim() {
        compare(Logic.streamPids([{"application.process.id": "1234", "pipewire.sec.pid": "42"}]), [42]);
        compare(Logic.streamPids([{"application.process.id": "1234"}]), []);
    }

    function test_theDigestChangesOnlyWithThePicture() {
        const a = Logic.digest({"20": "hidden", "3": "visible"}, "battery", [5]);
        compare(Logic.digest({"3": "visible", "20": "hidden"}, "battery", [5]), a, "key order does not matter");
        verify(Logic.digest({"3": "visible", "20": "occluded"}, "battery", [5]) !== a);
        verify(Logic.digest({"3": "visible", "20": "hidden"}, "mains", [5]) !== a);
        verify(Logic.digest({"3": "visible", "20": "hidden"}, "battery", []) !== a);
    }

    function test_helperArguments() {
        const base = ["/usr/lib/grassfield/grassfield-energy"];
        compare(Logic.roundArgs(base, {"12": "hidden"}, true, [7, 8]),
            ["/usr/lib/grassfield/grassfield-energy", "round", "--power", "battery", "--windows", "{\"12\":\"hidden\"}", "--media", "7,8"]);
        compare(Logic.roundArgs(base, {}, false, []), ["/usr/lib/grassfield/grassfield-energy", "round", "--power", "mains", "--windows", "{}"]);
        // A dev session: every command is a dry run on the dev state file.
        const dev = ["p", "--dry-run", "--state", "/s/app-energy.json"];
        compare(Logic.wakeArgs(dev, null), ["p", "wake", "--dry-run", "--state", "/s/app-energy.json", "--all"]);
        compare(Logic.wakeArgs(dev, [4, 0, -1, 9]), ["p", "wake", "--dry-run", "--state", "/s/app-energy.json", "--pid", "4", "--pid", "9"]);
        compare(Logic.resetArgs(dev), ["p", "reset", "--dry-run", "--state", "/s/app-energy.json"]);
    }

    function test_nextRun() {
        compare(Logic.nextRunMs("{\"next\": 10, \"limited\": 0}"), 10000);
        compare(Logic.nextRunMs("{\"next\": 0}"), 0);
        compare(Logic.nextRunMs("{\"next\": 600}"), Logic.maxTickMs);
        compare(Logic.nextRunMs("{\"next\": 0.2}"), 1000);
        compare(Logic.nextRunMs("garbage"), Logic.maxTickMs, "unreadable: check again later, never leave a limit unattended");
        compare(Logic.nextRunMs(""), Logic.maxTickMs);
        compare(Logic.nextRunMs("{\"next\": \"x\"}"), Logic.maxTickMs);
    }
}
