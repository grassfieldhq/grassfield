import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/services/DisplayArrival.js" as Arrival

// A combination of displays never seen before (ADR-0044 amendment A-1, shell/services/DisplayArrival.js): the combination key,
// the seen-set and its file, the settle wait, the rule that keeps a dev shell off the owner's displays, and the decision.
TestCase {
    name: "DisplayArrival"

    readonly property var laptop: ({name: "eDP-1", make: "BOE", model: "NE135A1M", serial: ""})
    readonly property var desk: ({name: "DP-3", make: "Dell Inc.", model: "U2723QE", serial: "7XK1234"})
    readonly property var tv: ({name: "HDMI-A-1", make: "LG", model: "OLED42", serial: "0x0101"})

    function keyOf(displays) {
        return Arrival.comboKey(DisplayRole.setOf(displays));
    }

    function test_comboKey() {
        const a = keyOf([laptop, desk]);
        // The order the outputs come in does not matter; the identity does, not the connector.
        compare(keyOf([desk, laptop]), a);
        const deskOtherPort = Object.assign({}, desk, {name: "DP-1"});
        compare(keyOf([laptop, deskOtherPort]), a);
        verify(keyOf([laptop, tv]) !== a);
        compare(Arrival.countOf(a), 2);
        compare(Arrival.countOf(keyOf([laptop])), 1);
        compare(Arrival.comboKey([]), "");
        compare(Arrival.comboKey(null), "");
        compare(Arrival.comboKey(["a", 3]), "");
        compare(Arrival.comboKey(["a\nb"]), "");
        compare(Arrival.countOf(""), 0);
    }

    function test_seenSetRoundTripAndBounds() {
        let seen = [];
        for (let i = 0; i < 40; i++)
            seen = Arrival.remember(seen, "s:x|m|" + i);
        compare(seen.length, Arrival.MAX_SEEN);
        compare(seen[0], "s:x|m|39");
        // Remembering again moves it first, without a repeat.
        seen = Arrival.remember(seen, "s:x|m|20");
        compare(seen[0], "s:x|m|20");
        compare(seen.filter(k => k === "s:x|m|20").length, 1);
        compare(Arrival.remember(seen, "").length, seen.length);
        const back = Arrival.parseSeen(Arrival.serializeSeen(seen));
        compare(back, seen);
        // Malformed or foreign: empty.
        compare(Arrival.parseSeen(""), []);
        compare(Arrival.parseSeen("not json"), []);
        compare(Arrival.parseSeen("{\"version\":2,\"seen\":[\"a\"]}"), []);
        compare(Arrival.parseSeen("{\"version\":1,\"seen\":\"a\"}"), []);
        compare(Arrival.parseSeen("{\"version\":1,\"seen\":[\"a\",\"a\",3,\"\",\"b\"]}"), ["a", "b"]);
    }

    function test_known() {
        const key = keyOf([laptop, desk]);
        verify(!Arrival.isKnown([], key, []));
        verify(Arrival.isKnown([key], key, []));
        // A set the user chose a main display for in Displays (displays.main) is known.
        const main = [{set: DisplayRole.setOf([desk, laptop]), main: DisplayRole.identity(desk)}];
        verify(Arrival.isKnown([], key, main));
        verify(!Arrival.isKnown([], keyOf([laptop, tv]), main));
        // Bad stored values are ignored; no combination is always "known" (nothing to offer).
        verify(!Arrival.isKnown(null, key, [null, 3, {set: "x"}]));
        verify(Arrival.isKnown([], "", []));
    }

    function test_settle() {
        let s = Arrival.track(null, "", 0);
        verify(!Arrival.settled(s, 100000));
        s = Arrival.track(s, "k1", 1000);
        verify(!Arrival.settled(s, 1000 + Arrival.SETTLE_MS - 1));
        verify(Arrival.settled(s, 1000 + Arrival.SETTLE_MS));
        // The same key keeps its start; a new key (a burst of hot-plug) restarts the wait.
        compare(Arrival.track(s, "k1", 2500).since, 1000);
        s = Arrival.track(s, "k2", 3500);
        verify(!Arrival.settled(s, 1000 + Arrival.SETTLE_MS));
        verify(Arrival.settled(s, 3500 + Arrival.SETTLE_MS));
        compare(Arrival.SETTLE_MS, 3000);
    }

    // Never in a dev shell on the owner's displays: a packaged session, or a dev session with its own state on virtual outputs.
    function test_allowed() {
        verify(Arrival.allowed(true, false, false, ["eDP-1", "DP-3"]));
        verify(Arrival.allowed(false, true, true, ["WAYLAND-1", "HEADLESS-2"]));
        verify(!Arrival.allowed(false, true, true, ["WAYLAND-1", "DP-3"]));
        verify(!Arrival.allowed(false, true, false, ["WAYLAND-1"]));
        verify(!Arrival.allowed(false, false, true, ["WAYLAND-1"]));
        verify(!Arrival.allowed(false, true, true, []));
        verify(!Arrival.isVirtualOutput("WAYLAND-x"));
        verify(Arrival.isVirtualOutput("X11-1"));
        // The project's own nested outputs: the nested window and the reference output (config/hypr/dev.lua).
        verify(Arrival.allowed(false, true, true, ["WAYLAND-1", "GF-REF"]));
        verify(Arrival.isVirtualOutput("GF-REF"));
        verify(!Arrival.isVirtualOutput("GF-REF-2"));
        verify(!Arrival.isVirtualOutput("xGF-REF"));
    }

    function test_decide() {
        const two = keyOf([laptop, desk]);
        const one = keyOf([laptop]);
        const base = {key: two, startup: false, known: false, allowed: true, locked: false};
        const d = over => Arrival.decide(Object.assign({}, base, over));
        compare(d({}), "offer");
        // Once per combination: a known one gives nothing.
        compare(d({known: true}), "none");
        // The combination the session starts with, and a single display, are recorded without a notice.
        compare(d({startup: true}), "remember");
        compare(d({key: one}), "remember");
        // Locked: wait for the unlock.
        compare(d({locked: true}), "wait");
        // Not allowed: nothing, nothing written.
        compare(d({allowed: false}), "none");
        compare(d({allowed: false, startup: true}), "none");
        compare(d({key: ""}), "none");
        compare(Arrival.decide(null), "none");
    }
}
