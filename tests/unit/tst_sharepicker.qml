import QtQuick
import QtTest
import "../../shell/services/SharePicker.js" as Logic

// ADR-0035 D-6, step 7a: the screen-sharing picker's decisions. The shell takes only the stand-in's form of request, reads
// only that request's window list, and answers only a listed choice in xdph's grammar; the panel's keys move in the grid.
TestCase {
    name: "SharePicker"

    readonly property string run: "/run/user/1000"
    readonly property string id: "0123456789abcdef0123456789abcdef"
    readonly property string sock: "/run/user/1000/grassfield/picker/fedcba9876543210fedcba9876543210.sock"

    function test_onlyTheStandInsFormOfRequest() {
        verify(Logic.validRequest(id, sock, run));
        verify(Logic.validRequest(id, sock, run + "/"), "a runtime directory with a trailing slash");
        verify(!Logic.validRequest(id.slice(1), sock, run), "an id shorter than 128 bits");
        verify(!Logic.validRequest(id.toUpperCase(), sock, run), "an id in upper case");
        verify(!Logic.validRequest(id + "0", sock, run), "a longer id");
        verify(!Logic.validRequest("-" + id.slice(1), sock, run), "an id that starts as an option");
        verify(!Logic.validRequest(id, "/tmp/grassfield/picker/fedcba9876543210fedcba9876543210.sock", run), "another directory");
        verify(!Logic.validRequest(id, run + "/grassfield/picker/../picker/fedcba9876543210fedcba9876543210.sock", run), "a path with ..");
        verify(!Logic.validRequest(id, run + "/grassfield/picker/x/fedcba9876543210fedcba9876543210.sock", run), "a subdirectory");
        verify(!Logic.validRequest(id, run + "/grassfield/picker/fedcba9876543210fedcba9876543210.socket", run), "another suffix");
        verify(!Logic.validRequest(id, run + "/grassfield/picker/.sock", run), "no name");
        verify(!Logic.validRequest(id, sock, ""), "no runtime directory");
        verify(!Logic.validRequest(id, "grassfield/picker/fedcba9876543210fedcba9876543210.sock", "grassfield"), "a relative runtime directory");
        verify(!Logic.validRequest(undefined, sock, run));
        verify(!Logic.validRequest(id, null, run));
    }

    function test_theWindowListOfThatRequestOnly() {
        const line = id + " list " + JSON.stringify([
            {handle: "123456", class: "org.gnome.TextEditor", title: "notes.txt", address: "0x55d48e82834e"},
            {handle: "4294967295", class: "firefox", title: "A page", address: ""}
        ]);
        compare(Logic.parseList(line, id), [
            {handle: "123456", appId: "org.gnome.TextEditor", title: "notes.txt", address: "55d48e82834e"},
            {handle: "4294967295", appId: "firefox", title: "A page", address: ""}
        ], "the address as Compositor.toplevelByAddress takes it: lower-case hex without 0x");
        compare(Logic.parseList(line, "f" + id.slice(1)), null, "another request's list");
        compare(Logic.parseList(id + " wait", id), null);
        compare(Logic.parseList(id + " list {", id), null, "not JSON");
        compare(Logic.parseList(id + " list {}", id), null, "not a list");
        compare(Logic.parseList(id + " list []", id), []);
    }

    // The stand-in's options line, sent before the list (bug report on rc6: a browser asked twice): `<id> options {json}`,
    // allowToken true only when xdph passed --allow-token. Another request's line, or anything else, is no options line.
    function test_theOptionsOfThatRequestOnly() {
        compare(Logic.parseOptions(id + " options {\"allowToken\":true}", id), {allowToken: true});
        compare(Logic.parseOptions(id + " options {\"allowToken\":false}", id), {allowToken: false});
        compare(Logic.parseOptions(id + " options {}", id), {allowToken: false}, "nothing said: no token by default");
        compare(Logic.parseOptions(id + " options {\"allowToken\":\"true\"}", id), {allowToken: false}, "only true allows the token");
        compare(Logic.parseOptions(id + " options {\"allowToken\":1}", id), {allowToken: false}, "only true allows the token");
        compare(Logic.parseOptions("f" + id.slice(1) + " options {\"allowToken\":true}", id), null, "another request's options");
        compare(Logic.parseOptions(id + " options [true]", id), null, "not an object");
        compare(Logic.parseOptions(id + " options {", id), null, "not JSON");
        compare(Logic.parseOptions(id + " options null", id), null, "null");
        compare(Logic.parseOptions(id + " list []", id), null, "the list is no options line");
        compare(Logic.parseList(id + " options {\"allowToken\":true}", id), null, "nor is the options line a list");
        compare(Logic.parseOptions(undefined, id), null);
    }

    function test_aWindowThatDoesNotReadIsLeftOut() {
        const listed = Logic.parseList(id + " list " + JSON.stringify([
            {handle: "4294967296", class: "a", title: "past 32 bits", address: ""},
            {handle: "12x", class: "a", title: "not a number", address: ""},
            {handle: 12, class: "a", title: "a number, not text", address: ""},
            {handle: "-1", class: "a", title: "negative", address: ""},
            null, "text",
            {handle: "7", class: 3, title: {}, address: "55d4"},
            {handle: "7", class: "dup", title: "the same handle again", address: ""},
            {handle: "8", class: "x".repeat(300), title: "y".repeat(300), address: "0x" + "f".repeat(17)}
        ]), id);
        compare(listed.map(w => w.handle), ["7", "8"]);
        compare(listed[0], {handle: "7", appId: "", title: "", address: ""}, "a class or title that is not text, an address without 0x");
        compare(listed[1].appId.length, 256, "an app id capped");
        compare(listed[1].title.length, 256, "a title capped");
        compare(listed[1].address, "", "an address past 64 bits");
        const many = [];
        for (let i = 0; i < 300; i++)
            many.push({handle: String(i), class: "a", title: "", address: ""});
        compare(Logic.parseList(id + " list " + JSON.stringify(many), id).length, 256, "at most 256 windows");
    }

    function test_windowsGroupedByAppThenTitle() {
        const names = {"org.gnome.TextEditor": "Text Editor", firefox: "Firefox", foot: "Foot"};
        const w = (h, a, t) => ({handle: h, appId: a, title: t, address: ""});
        compare(Logic.ordered([w("1", "org.gnome.TextEditor", "b"), w("2", "foot", "~"), w("3", "firefox", "z"), w("4", "org.gnome.TextEditor", "a")],
            id => names[id]).map(x => x.handle), ["3", "2", "4", "1"]);
    }

    function test_theAnswerIsAListedChoiceInXdphsGrammar() {
        const windows = [{handle: "123456", appId: "a", title: "", address: ""}];
        compare(Logic.selection("screen", "DP-1", false, ["DP-1", "HDMI-A-1"], windows), "/screen:DP-1");
        compare(Logic.selection("screen", "HDMI-A-1", true, ["DP-1", "HDMI-A-1"], windows), "r/screen:HDMI-A-1", "Remember this choice: the r flag");
        compare(Logic.selection("window", "123456", false, [], windows, {}, []), "/window:123456");
        compare(Logic.selection("window", "123456", true, [], windows, {}, []), "r/window:123456");
        compare(Logic.selection("window", "123456", false, [], windows, {}, null), "", "no window before Hyprland has said which hide from capture");
        compare(Logic.selection("screen", "DP-2", false, ["DP-1"], windows), "", "a display that is not there");
        compare(Logic.selection("screen", "DP-1\n/window:1", false, ["DP-1\n/window:1"], windows), "", "a name with a line break");
        compare(Logic.selection("window", "999", false, [], windows, {}, []), "", "a window xdph did not list");
        compare(Logic.selection("region", "DP-1@0,0,1,1", false, ["DP-1"], windows), "", "an area without its display's size");
        compare(Logic.selection("screen", "DP-1", "yes", ["DP-1"], windows), "/screen:DP-1", "only true ticks Remember");
    }

    // Step 7b, Selection (7-10): an area dragged on a display's preview, in that display's logical pixels, inside it, at
    // least panel.sharePickerMinArea either way; the answer xdph reads.
    function test_anAreaDraggedOnThePreview() {
        const preview = {width: 400, height: 225}, display = {width: 1920, height: 1080};
        compare(Logic.regionFor({x1: 10, y1: 10, x2: 110, y2: 60}, preview, display, 16), {x: 48, y: 48, w: 480, h: 240});
        compare(Logic.regionFor({x1: 110, y1: 60, x2: 10, y2: 10}, preview, display, 16), {x: 48, y: 48, w: 480, h: 240}, "dragged up and left");
        compare(Logic.regionFor({x1: 110, y1: 60, x2: -50, y2: 900}, preview, display, 16), {x: 0, y: 288, w: 528, h: 792}, "kept inside the preview");
        compare(Logic.regionFor({x1: 0, y1: 0, x2: 400, y2: 225}, preview, display, 16), {x: 0, y: 0, w: 1920, h: 1080}, "the whole display");
        compare(Logic.regionFor({x1: 10, y1: 10, x2: 12, y2: 12}, preview, display, 16), null, "a click is no area");
        compare(Logic.regionFor({x1: 10, y1: 10, x2: 300, y2: 13}, preview, display, 16), null, "too thin");
        compare(Logic.regionFor(null, preview, display, 16), null);
        compare(Logic.regionFor({x1: 0, y1: 0, x2: 10, y2: 10}, {width: 0, height: 0}, display, 1), null, "no preview yet");
        compare(Logic.regionKey("DP-1", {x: 48, y: 48, w: 480, h: 240}), "DP-1@48,48,480,240");
        compare(Logic.parseRegion("DP-1@48,48,480,240"), {output: "DP-1", x: 48, y: 48, w: 480, h: 240});
        compare(Logic.parseRegion("DP-1@48,48,0,240"), null, "an empty area");
        compare(Logic.parseRegion("DP-1@-1,48,10,10"), null);
        compare(Logic.parseRegion("DP 1@1,1,10,10"), null);
        compare(Logic.parseRegion("DP-1@1,1,10,10\n"), null);
        const sizes = {"DP-1": {width: 1920, height: 1080}};
        compare(Logic.selection("region", "DP-1@1872,1032,48,48", true, ["DP-1"], [], sizes), "r/region:DP-1@1872,1032,48,48", "at the display's corner");
        compare(Logic.selection("region", "DP-1@1873,1032,48,48", false, ["DP-1"], [], sizes), "", "past the display's width");
        compare(Logic.selection("region", "DP-1@0,1033,48,48", false, ["DP-1"], [], sizes), "", "past its height");
        compare(Logic.selection("region", "DP-2@0,0,48,48", false, ["DP-1"], [], {"DP-2": {width: 100, height: 100}}), "", "a display that is not there");
        compare(Logic.selection("region", "DP-1", false, ["DP-1"], [], sizes), "", "a display, not an area");
    }

    // Step 7b (7-11): a window that hides itself from capture is greyed and never answered; Hyprland's getprop answers, one
    // line per window asked, after its address, in any order; matched by address.
    function test_aWindowThatHidesFromCaptureIsNeverShared() {
        const windows = [{handle: "1", appId: "a", title: "", address: "55aa"}, {handle: "2", appId: "b", title: "", address: ""},
            {handle: "3", appId: "c", title: "", address: "55bb"}, {handle: "4", appId: "d", title: "", address: "55cc"}];
        compare(Logic.blockedHandles(windows, '55cc window not found\n55bb {"no_screen_share": true}\n55aa {"no_screen_share": false}\n'), ["3"],
            "in any order");
        compare(Logic.blockedHandles(windows, '55aa {"no_screen_share": true}\n'), ["1"], "the rest not answered: not hidden");
        compare(Logic.blockedHandles(windows, '55aa {"no_screen_share": "true"}\n55bb {"no_screen_share": 1}\n'), [], "only the boolean true");
        compare(Logic.blockedHandles(windows, '99ff {"no_screen_share": true}\n'), [], "an answer for another request's window marks none");
        compare(Logic.blockedHandles(windows, '{"no_screen_share": true}\n'), [], "an answer without its address marks none");
        compare(Logic.blockedHandles(windows, ""), []);
        compare(Logic.selection("window", "3", false, [], windows, {}, ["3"]), "", "a hidden window is not answered");
        compare(Logic.selection("window", "1", false, [], windows, {}, ["3"]), "/window:1");
    }

    // Step 7b (7-9), the indicator: xdph's streams among PipeWire's nodes (video nodes named after xdph's program: PipeWire
    // takes node.name from the program, the stream's own name stays in media.name), and what each shares.
    function test_theIndicatorFollowsXdphsStreams() {
        compare(Logic.sharingStreams([{id: 5, name: "xdg-desktop-portal-hyprland", video: true}, {id: 6, name: "alsa_output.pci", video: false},
            {id: 7, name: "xdg-desktop-portal-hyprland", video: false}, {id: 8, name: "xdph-streaming-ab12", video: true},
            {id: 9, name: "chromium", video: true}, {id: 10}, null]), [5]);
        compare(Logic.sharingStreams(undefined), []);
        const screen = {kind: "screen", value: "DP-1", title: ""}, win = {kind: "window", value: "777", title: "A page"};
        let r = Logic.streamLabels({}, [5], [{at: 1000, what: screen}], 3000, 3000);
        compare(r.labels, {"5": screen}, "one new stream, one choice waiting: that choice");
        compare(r.pending, []);
        r = Logic.streamLabels(r.labels, [5, 6], [{at: 3500, what: win}], 4000, 3000);
        compare(r.labels, {"5": screen, "6": win}, "a stream keeps its label; the next one new takes the next choice");
        r = Logic.streamLabels(r.labels, [6], [], 5000, 3000);
        compare(r.labels, {"6": win}, "a stream that ends takes its label away");
        r = Logic.streamLabels({}, [7], [{at: 0, what: screen}], 3001, 3000);
        compare(r.labels, {"7": null}, "a choice older than the window (SharePicker: 3 s) names nothing: a share restored with a token");
        compare(r.pending, []);
        r = Logic.streamLabels({}, [7], [{at: 0, what: screen}], 3000, 3000);
        compare(r.labels, {"7": screen}, "a choice answered just within the window still names its stream");
        r = Logic.streamLabels({}, [8], [{at: 1000, what: screen}, {at: 2000, what: win}], 3000, 3000);
        compare(r.labels, {"8": null}, "two choices waiting for one stream: no guess");
        compare(r.pending.length, 2);
        r = Logic.streamLabels({}, [8, 9], [{at: 1000, what: screen}], 3000, 3000);
        compare(r.labels, {"8": null, "9": null}, "two new streams for one choice: no guess");
    }

    // The selection is what a tile stands for: when the tiles are listed again in another order (a display plugged in, app
    // names that arrive and sort the windows again) it stays on that display or window, and clears when it is gone.
    function test_theSelectionFollowsItsTileNotItsPlace() {
        const screens = [{name: "DP-1"}, {name: "HDMI-A-1"}];
        compare(Logic.keyOf("screen", screens[1]), "HDMI-A-1");
        compare(Logic.indexOfKey("screen", [{name: "eDP-1"}, {name: "DP-1"}, {name: "HDMI-A-1"}], "HDMI-A-1"), 2, "a display plugged in before it");
        compare(Logic.indexOfKey("screen", [{name: "DP-1"}], "HDMI-A-1"), -1, "the display unplugged: nothing selected");
        const w = (h, a) => ({handle: h, appId: a, title: "", address: ""});
        compare(Logic.keyOf("window", w("777", "firefox")), "777");
        compare(Logic.indexOfKey("window", [w("123", "b"), w("777", "a")], "777"), 1);
        compare(Logic.indexOfKey("window", [w("777", "a"), w("123", "b")], "777"), 0, "sorted again: the same window");
        compare(Logic.indexOfKey("window", [w("123", "b")], "777"), -1, "the window closed: nothing selected");
        compare(Logic.indexOfKey("window", [w("123", "b")], ""), -1, "nothing chosen");
        compare(Logic.indexOfKey("screen", [{name: "777"}], "777"), 0);
        compare(Logic.indexOfKey("window", [{name: "777"}], "777"), -1, "a key of the other tab names nothing");
        compare(Logic.keyOf("screen", null), "");
        compare(Logic.keyOf("region", {name: "DP-1"}), "DP-1", "Selection's display chooser keeps the display's name");
    }

    function test_theArrowsMoveInTheGrid() {
        // Seven tiles, three to a row.
        compare(Logic.moved(-1, "right", 7, 3), 0, "nothing selected: the first tile");
        compare(Logic.moved(0, "right", 7, 3), 1);
        compare(Logic.moved(0, "left", 7, 3), 0, "nothing before the first");
        compare(Logic.moved(1, "down", 7, 3), 4);
        compare(Logic.moved(4, "down", 7, 3), 4, "no tile below");
        compare(Logic.moved(3, "down", 7, 3), 6);
        compare(Logic.moved(4, "up", 7, 3), 1);
        compare(Logic.moved(1, "up", 7, 3), 1);
        compare(Logic.moved(6, "right", 7, 3), 6);
        compare(Logic.moved(9, "left", 7, 3), 0, "a selection past the tiles starts again");
        compare(Logic.moved(0, "down", 0, 3), -1, "no tile");
        compare(Logic.moved(0, "down", 2, 0), 1, "at least one column");
    }

    function test_columnsThatFit() {
        compare(Logic.columnsFor(564, 176, 12), 3);
        compare(Logic.columnsFor(551, 176, 12), 2);
        compare(Logic.columnsFor(100, 176, 12), 1, "at least one");
    }
}
