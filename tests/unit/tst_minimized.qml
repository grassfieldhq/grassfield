import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/platform/Minimized.js" as Minimized
import "../../shell/dock/DockModel.js" as DockModel

// Minimized-window state model and the Dock section built from it.
TestCase {
    name: "Minimized"

    function rec(top, appId, address) {
        return {toplevel: top, address: address ? address : "1a", appId: appId, title: "T " + top};
    }

    // Compositor.taggedToplevel's match (SettingsApp.openAbout brings an open About This Computer window forward): the class
    // and the xdg tag of Hyprland's window data, both exact; window data not read yet matches nothing.
    // Audit SC-16: a minimize the compositor refused or dropped (no move to special:minimized seen, the window read elsewhere)
    // loses its record; one seen moving there, or read there, keeps it.
    function test_unconfirmedMinimizesAreDropped() {
        const last = new Map([["a1", "special:minimized"], ["b2", "1"]]);
        const places = {a1: "1", b2: "2", c3: "special:minimized", d4: ""};
        const drops = Minimized.unconfirmedDrops(["a1", "b2", "c3", "d4"], last, a => places[a] || "", "special:minimized");
        compare(drops, ["b2", "d4"]);
        compare(Minimized.unconfirmedDrops([], last, a => "", "special:minimized"), []);
        compare(Minimized.unconfirmedDrops(["e5"], null, a => "special:minimized", "special:minimized"), []);
    }

    function test_hasTag() {
        const about = {class: "org.grassfield.Settings", xdgTag: "info", pid: 7};
        verify(Minimized.hasTag(about, "org.grassfield.Settings", "info"));
        verify(!Minimized.hasTag({class: "org.grassfield.Settings", xdgTag: "settings"}, "org.grassfield.Settings", "info"));
        verify(!Minimized.hasTag({class: "org.grassfield.Files", xdgTag: "info"}, "org.grassfield.Settings", "info"));
        verify(!Minimized.hasTag({class: "org.grassfield.Settings"}, "org.grassfield.Settings", "info"));
        verify(!Minimized.hasTag({}, "org.grassfield.Settings", "info"));
        verify(!Minimized.hasTag(null, "org.grassfield.Settings", "info"));
        verify(!Minimized.hasTag({class: "", xdgTag: ""}, "", ""));
    }

    function test_blurCallIsBuiltFromIntegersInRange() {
        compare(Minimized.blurCall(18, 3), "function() hl.config({ decoration = { blur = { size = 18, passes = 3 } } }) end");
        compare(Minimized.blurCall(0, 3), "");
        compare(Minimized.blurCall(18, 9), "");
        compare(Minimized.blurCall(18.5, 3), "");
        compare(Minimized.blurCall("18) end; os.exit() --", 3), "");
        compare(Minimized.blurCall(NaN, 3), "");
    }

    // The session's ground (ADR-0040 ID-2): only "#rrggbb" is ever interpolated into the Lua call.
    function test_groundCallIsBuiltFromAHexColour() {
        compare(Minimized.groundCall("#2F6D5F"), "function() hl.config({ misc = { background_color = \"rgba(2f6d5fff)\" } }) end");
        for (const bad of ["", "2F6D5F", "#2F6D5", "#2F6D5FFF", "#2F6D5G", "#2F6D5F\") end os.exit() --", null, 0x2F6D5F])
            compare(Minimized.groundCall(bad), "", String(bad));
    }

    // The window edge per appearance (ADR-0039 step 6, C-4; ADR-0024 note 2026-11-03): a dark device pixel in both appearances,
    // fainter in the light one; a value that is not a colour or an alpha sends nothing.
    function test_edgeCallIsBuiltPerAppearance() {
        compare(Minimized.edgeCall(Tokens.windowEdgeLight, Tokens.windowEdgeActiveOpacityLight, Tokens.windowEdgeInactiveOpacityLight),
                "function() hl.config({ general = { col = { active_border = \"rgba(00000020)\", inactive_border = \"rgba(0000001c)\" } } }) end");
        compare(Minimized.edgeCall(Tokens.windowEdgeDark, Tokens.windowEdgeActiveOpacityDark, Tokens.windowEdgeInactiveOpacityDark),
                "function() hl.config({ general = { col = { active_border = \"rgba(00000094)\", inactive_border = \"rgba(00000085)\" } } }) end");
        compare(Minimized.edgeCall("#000", 0.25, 0.13), "");
        compare(Minimized.edgeCall("black", 0.25, 0.13), "");
        compare(Minimized.edgeCall("#000000", 1.5, 0.13), "");
        compare(Minimized.edgeCall("#000000", 0.25, NaN), "");
        compare(Minimized.edgeCall("#000000\"; os.exit() --", 0.25, 0.13), "", "nothing but a colour reaches the Lua string");
    }

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    // A config reload restores the config's border: it must be the dark appearance's pair, which the shell then replaces in
    // the light appearance. Hyprland's inner glow stays at its default (off): with no window rule and no rim along the rounded
    // corners, it lit the client's top row under a third-party window's titlebar (ADR-0024 note 2026-11-03).
    function test_theConfigHoldsTheDarkEdge() {
        const config = source("config/hypr/grassfield/looknfeel.lua");
        const dark = Minimized.edgeCall(Tokens.windowEdgeDark, Tokens.windowEdgeActiveOpacityDark, Tokens.windowEdgeInactiveOpacityDark);
        const active = /active_border = "(rgba\([0-9a-f]{8}\))"/.exec(dark)[1];
        const inactive = /inactive_border = "(rgba\([0-9a-f]{8}\))"/.exec(dark)[1];
        verify(config.indexOf('active_border = "' + active + '"') >= 0, "config active_border " + active);
        verify(config.indexOf('inactive_border = "' + inactive + '"') >= 0, "config inactive_border " + inactive);
        verify(!/glow\s*=\s*\{/.test(config.replace(/--.*$/gm, "")), "the config sets no inner glow");
    }

    // The shell sends the edge of the appearance it shows, at start, on a change (debounced) and after a reload, as the blur
    // (shell/platform/Compositor.qml needs Quickshell: read from its source).
    function test_theShellPushesTheEdgeWithTheAppearance() {
        const compositor = source("shell/platform/Compositor.qml").replace(/\/\/.*$/gm, "");
        verify(/readonly property string edgeCall: Appearance\.dark\s*\?\s*Minimized\.edgeCall\(Tokens\.windowEdgeDark,[^:]*:\s*Minimized\.edgeCall\(Tokens\.windowEdgeLight,/.test(compositor),
               "the call follows Appearance.dark");
        verify(/onEdgeCallChanged: \{[^}]*edgeDebounce\.restart\(\)/.test(compositor), "a change is pushed (debounced)");
        // The singleton's own start (the one that pushes the blur), not a socket's.
        const starts = compositor.split("Component.onCompleted: {").slice(1).map(t => t.slice(0, t.indexOf("}")));
        verify(starts.some(t => /pushBlur\(\);/.test(t) && /pushEdge\(\);/.test(t)), "pushed at start, with the blur");
        const reload = compositor.slice(compositor.indexOf('event.name !== "configreloaded"'));
        verify(/root\.pushEdge\(\);/.test(reload.slice(0, reload.indexOf("\n        }"))), "pushed after a config reload");
    }

    // The answers are captured from Hyprland 0.56.2 (tests/compositor/blur_events.sh, request socket, `dispatch <function>`):
    // "ok" for a valid hl.config call, "error: ...: unknown config key '...'" for an unknown key.
    function test_blurAnswerReadsWhatHyprlandAnswered() {
        compare(Minimized.blurAnswer("ok"), "ok");
        compare(Minimized.blurAnswer("ok\n"), "ok");
        compare(Minimized.blurAnswer("error: =[C]:-1: unknown config key 'decoration.blur.no_such'"), "rejected");
        compare(Minimized.blurAnswer("error: return hl.dispatch(function() hl.config({ decoration = { blur = { no_such_key_gf = 1 } } }) end):1: unknown config key 'decoration.blur.no_such_key_gf'"), "rejected");
        // The answer may arrive in pieces: the shell adds them up before judging (the whole text, not the first chunk).
        compare(Minimized.blurAnswer("er"), "unknown");
        compare(Minimized.blurAnswer("er" + "ror: =[C]:-1: unknown config key 'decoration.blur.x'"), "rejected");
        compare(Minimized.blurAnswer("o"), "unknown");
        compare(Minimized.blurAnswer("o" + "k"), "ok");
        compare(Minimized.blurAnswer(""), "unknown");
        compare(Minimized.blurAnswer("okay then"), "unknown");
        compare(Minimized.blurAnswer(undefined), "unknown");
    }

    function test_windowCallIsBuiltFromValidatedPieces() {
        compare(Minimized.windowCall("minimize", "0x55AB", {x: 2300.4, y: 1010.6, w: 52, h: 52}),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.minimize then p.minimize(\"0x55ab\", 2300, 1011, 52, 52) end end");
        compare(Minimized.windowCall("restore", "55ab", {x: 0, y: 0, w: 0, h: 0}),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.restore then p.restore(\"0x55ab\", 0, 0, 0, 0) end end");
        // Rejected: unknown verb, bad address, missing or non-finite rectangle, injection attempts.
        compare(Minimized.windowCall("hello", "55ab", {x: 0, y: 0, w: 1, h: 1}), "");
        compare(Minimized.windowCall("minimize(1) end; os.exit() --", "55ab", {x: 0, y: 0, w: 1, h: 1}), "");
        compare(Minimized.windowCall("minimize", "55ab\"); os.exit() --", {x: 0, y: 0, w: 1, h: 1}), "");
        compare(Minimized.windowCall("minimize", "55ab", null), "");
        compare(Minimized.windowCall("minimize", "55ab", {x: NaN, y: 0, w: 1, h: 1}), "");
        compare(Minimized.windowCall("minimize", "55ab", {x: "1); os.exit(", y: 0, w: 1, h: 1}), "");
    }

    function test_configCallAllowlist() {
        compare(Minimized.configCall("titlebarDoubleClick", "minimize"),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.config then p.config(\"titlebarDoubleClick\", \"minimize\") end end");
        verify(Minimized.configCall("titlebarDoubleClick", "zoom") !== "");
        verify(Minimized.configCall("titlebarDoubleClick", "none") !== "");
        compare(Minimized.configCall("titlebarDoubleClick", "Zoom"), "");
        compare(Minimized.configCall("titlebarDoubleClick", "zoom\") os.exit() --"), "");
        compare(Minimized.configCall("titlebarDoubleClick", undefined), "");
        compare(Minimized.configCall("titlebarDoubleClick", "dark"), "");
        compare(Minimized.configCall("windowRule", "zoom"), "");
        compare(Minimized.configCall("__proto__", "zoom"), "");
        compare(Minimized.configCall("constructor", "zoom"), "");
    }

    // Settings > Desktop & Dock > Windows (docs/specs/tiling.md TL32): the tiling switches as "true" | "false", Fill as an
    // action of the title bar's double-click.
    function test_configCallTiling() {
        compare(Minimized.configCall("titlebarDoubleClick", "fill"),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.config then p.config(\"titlebarDoubleClick\", \"fill\") end end");
        for (const key of ["tilingEdges", "tilingMenuBar", "tilingOptionDrag", "tilingMargins", "tilingLayouts", "tilingSuggestions"]) {
            compare(Minimized.configCall(key, "false"),
                    "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.config then p.config(\"" + key + "\", \"false\") end end", key);
            verify(Minimized.configCall(key, "true") !== "", key);
            compare(Minimized.configCall(key, false), "", key + ": strings only");
            compare(Minimized.configCall(key, "on"), "", key);
            compare(Minimized.configCall(key, "true\") os.exit() --"), "", key);
        }
        compare(Minimized.configCall("tilingAltDrag", "true"), "", "the plugin's key is tilingOptionDrag");
        compare(Minimized.configCall("tilingGroups", "true"), "", "Bring tile groups forward together is the shell's alone");
    }

    // What the shell pushes (integrator review of 1c08d6b, S5-S7): each switch once the plugin advertises its feature, with
    // the value of its own Settings property; Fill only with the plugin's arrangements (ADR-0036 D36).
    function test_tilingConfigPairs() {
        const settings = {windowsTilingEdges: true, windowsTilingMenuBar: false, windowsTilingOptionDrag: false, windowsTilingMargins: true,
            windowsTilingLayouts: false, windowsTilingSuggestions: true, windowsTilingGroups: false};
        const all = () => true;
        compare(Minimized.tilingConfigPairs(settings, all), [["tilingEdges", "true"], ["tilingMenuBar", "false"], ["tilingOptionDrag", "false"],
            ["tilingMargins", "true"], ["tilingLayouts", "false"], ["tilingSuggestions", "true"]]);
        const only = list => feature => list.indexOf(feature) >= 0;
        compare(Minimized.tilingConfigPairs(settings, only([])), []);
        compare(Minimized.tilingConfigPairs(settings, only(["window-tiling"])).map(p => p[0]), ["tilingEdges", "tilingMenuBar", "tilingOptionDrag", "tilingMargins"]);
        compare(Minimized.tilingConfigPairs(settings, only(["tile-hover"])), [["tilingLayouts", "false"]]);
        compare(Minimized.tilingConfigPairs(settings, only(["tiling-layouts"])), [["tilingSuggestions", "true"]]);
        compare(Minimized.tilingConfigPairs(settings, only(["tiling-groups", "tiling-arrange", "tiling-shared-edge"])), [], "no key rides on these");
        // Each value is its own switch's: every one flipped alone changes only its pair.
        for (const sw of Minimized.tilingSwitches) {
            const flipped = Object.assign({}, settings);
            flipped[sw.setting] = !settings[sw.setting];
            const pairs = Minimized.tilingConfigPairs(flipped, all);
            for (const [key, value] of pairs)
                compare(value, (key === sw.key ? !settings[sw.setting] : settings[Minimized.tilingSwitches.find(s => s.key === key).setting]) ? "true" : "false", sw.key + " flipped: " + key);
        }
        compare(Minimized.tilingConfigPairs({}, all).map(p => p[1]), ["false", "false", "false", "false", "false", "false"], "a missing property is off, never true");
        for (const [key, value] of Minimized.tilingConfigPairs(settings, all))
            verify(Minimized.configCall(key, value) !== "", key + " is in the allowlist");
    }

    function test_doubleClickAction() {
        compare(Minimized.doubleClickAction("fill", true), "fill");
        compare(Minimized.doubleClickAction("fill", false), "zoom", "without the plugin's arrangements Fill zooms");
        compare(Minimized.doubleClickAction("fill", undefined), "zoom");
        for (const action of ["zoom", "minimize", "none"]) {
            compare(Minimized.doubleClickAction(action, true), action);
            compare(Minimized.doubleClickAction(action, false), action);
        }
    }

    // Stages from Settings (owner decision D-4, audit ARCH-05): the flag key and the verb the strip uses.
    function test_stagesFlagAndVerb() {
        compare(Minimized.configCall("stagesEnabled", "true"),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.config then p.config(\"stagesEnabled\", \"true\") end end");
        verify(Minimized.configCall("stagesEnabled", "false") !== "");
        compare(Minimized.configCall("stagesEnabled", "yes"), "");
        compare(Minimized.configCall("stagesEnabled", true), "", "strings only, as the plugin reads them");
        verify(Minimized.isPluginVerb("stages"));
    }

    function test_stagesCallQuotesTheOperationAsALuaString() {
        compare(Minimized.stagesCall({op: "off", durationMs: 0}),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.stages then p.stages(\"{\\\"op\\\":\\\"off\\\",\\\"durationMs\\\":0}\") end end");
        verify(Minimized.stagesCall({op: "activate", stage: 7}) !== "");
        verify(Minimized.stagesCall({op: "move", address: "0x55ab", stage: "new"}) !== "");
        verify(Minimized.stagesCall({op: "on", durationMs: 350, strips: [{monitor: "GF-REF", hidden: false, tiles: [{x: 16, y: 100, w: 188, h: 160}]}]}) !== "");
        // A string that tries to leave the Lua literal stays inside it: the literal, read as Lua reads it (\\ and \"),
        // gives back exactly the JSON of the request, and the call ends where it should.
        const request = {op: "move", address: "\") os.exit() --", stage: "\\\"\n"};
        const sneaky = Minimized.stagesCall(request);
        const head = "if p and p.stages then p.stages(\"";
        const tail = "\") end end";
        verify(sneaky.indexOf(head) > 0 && sneaky.endsWith(tail), sneaky);
        const literal = sneaky.slice(sneaky.indexOf(head) + head.length, sneaky.length - tail.length);
        verify(!/(^|[^\\])"/.test(literal.replace(/\\\\/g, "")), "no unescaped quote inside the literal: " + literal);
        const decoded = literal.replace(/\\(["\\])/g, "$1");
        compare(JSON.stringify(JSON.parse(decoded)), JSON.stringify(request));
        // Rejected: no or unknown op, not an object, too large.
        compare(Minimized.stagesCall({op: "explode"}), "");
        compare(Minimized.stagesCall({}), "");
        compare(Minimized.stagesCall(null), "");
        compare(Minimized.stagesCall("{\"op\":\"off\"}"), "");
        compare(Minimized.stagesCall([{op: "off"}]), "");
        compare(Minimized.stagesCall({op: "on", pad: "x".repeat(9000)}), "");
    }

    // The appearance the compositor-drawn chrome follows (plugin feature "appearance", audit UX-06).
    function test_configCallAppearance() {
        compare(Minimized.configCall("appearance", "light"),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.config then p.config(\"appearance\", \"light\") end end");
        verify(Minimized.configCall("appearance", "dark") !== "");
        compare(Minimized.configCall("appearance", "auto"), "", "the shell sends the appearance it shows, never auto");
        compare(Minimized.configCall("appearance", "Light"), "");
        compare(Minimized.configCall("appearance", "light\") os.exit() --"), "");
        compare(Minimized.configCall("appearance", true), "");
    }

    // Settings dock.minimizeEffect, or "fade" under Reduce Motion (plugin feature "minimize-effect").
    function test_configCallMinimizeEffect() {
        compare(Minimized.configCall("minimizeEffect", "funnel"),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.config then p.config(\"minimizeEffect\", \"funnel\") end end");
        verify(Minimized.configCall("minimizeEffect", "shrink") !== "");
        verify(Minimized.configCall("minimizeEffect", "fade") !== "");
        compare(Minimized.configCall("minimizeEffect", "genie"), "");
        compare(Minimized.configCall("minimizeEffect", "scale"), "");
        compare(Minimized.configCall("minimizeEffect", "Funnel"), "");
        compare(Minimized.configCall("minimizeEffect", "zoom"), "");
        compare(Minimized.configCall("minimizeEffect", "funnel\") os.exit() --"), "");
        compare(Minimized.configCall("minimizeEffect", null), "");
    }

    // ---- overview verb (docs/specs/overview.md "Shell contract" 3) ----

    readonly property string ovHead: "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.overview then p.overview("
    readonly property string ovTail: ") end end"

    // ---- overview_focus verb (docs/specs/overview.md "Close focus") ----

    readonly property string ofHead: "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.overview_focus then p.overview_focus("
    function ofLua(json) { return ofHead + "\"" + json.replace(/"/g, "\\\"") + "\"" + ovTail; }

    function test_overviewFocusCallTargets() {
        compare(Minimized.overviewFocusCall({kind: "window", address: "0x55AB"}), ofLua('{"target":"window","address":"0x55ab"}'));
        compare(Minimized.overviewFocusCall({kind: "workspace", workspace: 3}), ofLua('{"target":"workspace","workspace":3}'));
        compare(Minimized.overviewFocusCall({kind: "remembered", address: "55ab", workspace: 2}), ofLua('{"target":"remembered","address":"0x55ab","workspace":2}'));
        compare(Minimized.overviewFocusCall({kind: "remembered", address: "55ab"}), ofLua('{"target":"remembered","address":"0x55ab"}'));
        compare(Minimized.overviewFocusCall({kind: "none"}), ofLua('{"target":"none"}'));
        compare(Minimized.overviewFocusCall({kind: "none"}, 7), ofLua('{"target":"none","id":7}'));
    }

    function test_overviewFocusCallUsesOnlyTheFieldsOfTheTarget() {
        // A field the plugin refuses for that target is never produced, whatever the input carries.
        compare(Minimized.overviewFocusCall({kind: "window", address: "55ab", workspace: 3}), ofLua('{"target":"window","address":"0x55ab"}'));
        compare(Minimized.overviewFocusCall({kind: "workspace", workspace: 3, address: "55ab"}), ofLua('{"target":"workspace","workspace":3}'));
        compare(Minimized.overviewFocusCall({kind: "none", address: "55ab", workspace: 3}), ofLua('{"target":"none"}'));
    }

    function test_overviewFocusCallRejectsEverythingInvalid() {
        compare(Minimized.overviewFocusCall(null), "");
        compare(Minimized.overviewFocusCall({kind: "skip"}), "");
        compare(Minimized.overviewFocusCall({kind: "window"}), "");
        compare(Minimized.overviewFocusCall({kind: "window", address: "55ab\"); os.exit() --"}), "");
        compare(Minimized.overviewFocusCall({kind: "window", address: ""}), "");
        compare(Minimized.overviewFocusCall({kind: "workspace", workspace: 0}), "");
        compare(Minimized.overviewFocusCall({kind: "workspace", workspace: -1}), "");
        compare(Minimized.overviewFocusCall({kind: "workspace", workspace: "special:minimized"}), "", "never a special workspace");
        compare(Minimized.overviewFocusCall({kind: "workspace", workspace: 1.5}), "");
        compare(Minimized.overviewFocusCall({kind: "remembered", address: "55ab", workspace: "x"}), "");
        compare(Minimized.overviewFocusCall({kind: "none"}, -1), "");
        compare(Minimized.overviewFocusCall({kind: "none"}, 4294967296), "");
        compare(Minimized.overviewFocusCall({kind: "none"}, 1.5), "");
        verify(Minimized.overviewFocusCall({kind: "none"}, 4294967295) !== "");
        verify(Minimized.isPluginVerb("overview_focus"));
    }

    function test_overviewCallOpenIsAValidatedLuaString() {
        const call = Minimized.overviewCall({on: true, durationMs: 350, curve: [0.2, 0, 0, 1], windows: [{address: "0x55AB", x: 10.4, y: 20.6, w: 300.2, h: 200.5}]});
        compare(call, ovHead + "\"{\\\"on\\\":true,\\\"durationMs\\\":350,\\\"curve\\\":[0.2,0,0,1],\\\"windows\\\":[{\\\"address\\\":\\\"0x55ab\\\",\\\"x\\\":10,\\\"y\\\":21,\\\"w\\\":300,\\\"h\\\":201}]}\"" + ovTail);
    }

    function test_overviewCallCloseNeedsNoWindows() {
        compare(Minimized.overviewCall({on: false, durationMs: 0}), ovHead + "\"{\\\"on\\\":false,\\\"durationMs\\\":0}\"" + ovTail);
        verify(Minimized.overviewCall({on: false, durationMs: 350, curve: [0.2, 0, 0, 1]}) !== "");
    }

    function test_overviewCallRejectsEverythingInvalid() {
        const w = [{address: "55ab", x: 0, y: 0, w: 10, h: 10}];
        compare(Minimized.overviewCall(null), "");
        compare(Minimized.overviewCall({on: "yes", durationMs: 0}), "");
        compare(Minimized.overviewCall({durationMs: 0}), "");
        compare(Minimized.overviewCall({on: false}), "");
        compare(Minimized.overviewCall({on: false, durationMs: -1}), "");
        compare(Minimized.overviewCall({on: false, durationMs: 2001}), "");
        compare(Minimized.overviewCall({on: false, durationMs: NaN}), "");
        compare(Minimized.overviewCall({on: true, durationMs: 100}), "", "on:true needs windows");
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: []}), "");
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: [{address: "55ab\"); os.exit() --", x: 0, y: 0, w: 1, h: 1}]}), "");
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: [{address: "55ab", x: NaN, y: 0, w: 1, h: 1}]}), "");
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: [{address: "55ab", x: Infinity, y: 0, w: 1, h: 1}]}), "");
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: [w[0], w[0]]}), "", "duplicate addresses");
        compare(Minimized.overviewCall({on: false, durationMs: 100, curve: [0.2, 0, 0]}), "");
        compare(Minimized.overviewCall({on: false, durationMs: 100, curve: [2, 0, 0, 1]}), "");
        compare(Minimized.overviewCall({on: false, durationMs: 100, curve: [0.2, 3, 0, 1]}), "");
        const many = [];
        for (let i = 0; i < 65; i++)
            many.push({address: (i + 1).toString(16), x: 0, y: 0, w: 1, h: 1});
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: many}), "", "more than 64 windows");
        verify(Minimized.overviewCall({on: true, durationMs: 100, windows: many.slice(0, 64)}) !== "");
    }

    function test_overviewCallClampsTinyRectsToOnePixel() {
        const call = Minimized.overviewCall({on: true, durationMs: 0, windows: [{address: "1", x: 5, y: 6, w: 0.2, h: 0}]});
        verify(call.indexOf("\\\"w\\\":1,\\\"h\\\":1") >= 0, call);
    }

    function test_moveWindowV2Parsing() {
        const m = Minimized.parseMoveWindowV2("55924770ce00,-98,special:minimized");
        compare(m.address, "55924770ce00");
        compare(m.workspace, "special:minimized");
        compare(Minimized.parseMoveWindowV2("55AB,2,2").workspace, "2");
        compare(Minimized.parseMoveWindowV2("55ab,3,name, with, commas").workspace, "name, with, commas");
        compare(Minimized.parseMoveWindowV2("55ab,2"), null);
        compare(Minimized.parseMoveWindowV2("zz,2,2"), null);
        compare(Minimized.parseMoveWindowV2("55ab,2,"), null);
        compare(Minimized.parseMoveWindowV2(""), null);
    }

    function test_pluginEventsOtherThanMinimizeRequestAreIgnored() {
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/1","type":"minimized","address":"55ab"}'), "");
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/1","type":"restored","address":"55ab"}'), "");
    }

    function test_pluginVerbAllowlist() {
        for (const v of ["hello", "minimize", "restore", "config", "appmenu"])
            verify(Minimized.isPluginVerb(v), v);
        verify(Minimized.isPluginVerb("overview"));
        verify(Minimized.isPluginVerb("cursor_refresh"));
        compare(Minimized.cursorRefreshCall(), "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.cursor_refresh then p.cursor_refresh() end end");
        for (const v of ["theme"])
            verify(!Minimized.isPluginVerb(v), v);
        compare(Minimized.guardedPluginCall("theme", []), "");
        compare(Minimized.guardedPluginCall("x end os.exit() --", []), "");
        for (const v of ["", "Minimize", "minimize ", "x end os.execute('id') --", "minimize(1) end; os.exit() --", "constructor", "__proto__", "length"])
            verify(!Minimized.isPluginVerb(v), v);
        verify(!Minimized.isPluginVerb(undefined));
        verify(!Minimized.isPluginVerb(null));
        verify(!Minimized.isPluginVerb(7));
    }

    // Window tiling (docs/specs/tiling.md TL6, TL23, TL26): tile, arrange, tile_popover and move_to are built from validated
    // pieces only; anything else gives "" (never dispatched).
    function test_tilingCallsAreBuiltFromValidatedPieces() {
        for (const v of ["tile", "arrange", "tile_popover", "move_to"])
            verify(Minimized.isPluginVerb(v), v);
        const guard = verb => "function() local p = hl.plugin and hl.plugin.grassfield; if p and p." + verb + " then p." + verb + "(";
        compare(Minimized.tileCall("0x55AB", "top-left"), guard("tile") + "\"0x55ab\", \"top-left\") end end");
        compare(Minimized.arrangeCall("55ab", "left-quarters"), guard("arrange") + "\"{\\\"layout\\\":\\\"left-quarters\\\",\\\"windows\\\":[\\\"0x55ab\\\"]}\") end end");
        compare(Minimized.tilePopoverCall("0x55ab"), guard("tile_popover") + "\"0x55ab\") end end");
        compare(Minimized.moveToCall("55ab", "DP-1"), guard("move_to") + "\"0x55ab\", \"DP-1\") end end");
        compare(Minimized.moveToCall("55ab", "HDMI-A-1.2_x"), guard("move_to") + "\"0x55ab\", \"HDMI-A-1.2_x\") end end");
        // Refused: a layout outside the Arrange rows (the Layouts section comes with step 4), a bad address, an output name the
        // plugin would refuse (and that could break out of the Lua string).
        for (const layout of ["wide-left", "thirds", "LEFT-RIGHT", "", "left-right\") end os.exit() --", null])
            compare(Minimized.arrangeCall("55ab", layout), "", String(layout));
        for (const address of ["", "zz", "0x", "0x12345678901234567", "55ab\"", null])
            compare(Minimized.arrangeCall(address, "quarters") + Minimized.tilePopoverCall(address) + Minimized.moveToCall(address, "DP-1"), "", String(address));
        for (const output of ["", "DP 1", "DP-1\"", "DP-1\\", "é", "a".repeat(65), null, 7])
            compare(Minimized.moveToCall("55ab", output), "", String(output));
        verify(Minimized.moveToCall("55ab", "a".repeat(64)) !== "");
    }

    // TL29 (step 4b): the tile group of a window comes forward.
    function test_groupFrontCallIsBuiltFromAValidatedAddress() {
        verify(Minimized.isPluginVerb("group_front"));
        compare(Minimized.groupFrontCall("0x55AB"), "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.group_front then p.group_front(\"0x55ab\") end end");
        for (const address of ["", "zz", "0x", "55ab\"", null])
            compare(Minimized.groupFrontCall(address), "", String(address));
    }

    // TL33 (step 6a): Full Screen › Left or Right of Screen, and Exit Full Screen of a Split View window.
    function test_splitCallsAreBuiltFromValidatedPieces() {
        for (const v of ["split", "unsplit"])
            verify(Minimized.isPluginVerb(v), v);
        const guard = verb => "function() local p = hl.plugin and hl.plugin.grassfield; if p and p." + verb + " then p." + verb + "(";
        compare(Minimized.splitCall("0x55AB", "left"), guard("split") + "\"0x55ab\", \"left\") end end");
        compare(Minimized.splitCall("55ab", "right"), guard("split") + "\"0x55ab\", \"right\") end end");
        compare(Minimized.unsplitCall("0x55AB"), guard("unsplit") + "\"0x55ab\") end end");
        for (const side of ["", "LEFT", "top", "fill", "left\") end os.exit() --", null, undefined, 0])
            compare(Minimized.splitCall("55ab", side), "", String(side));
        for (const address of ["", "zz", "0x", "0x12345678901234567", "55ab\"", null])
            compare(Minimized.splitCall(address, "left") + Minimized.unsplitCall(address), "", String(address));
    }

    // Step 6d (ADR-0036 D71): how a window leaves its Split View Desktop, the second argument only when it is not "desktop".
    function test_unsplitCallTakesHowAWindowLeaves() {
        const guard = "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.unsplit then p.unsplit(";
        compare(Minimized.unsplitCall("0x55AB", "desktop"), guard + "\"0x55ab\") end end", "Move Window to Desktop: as Exit Full Screen");
        compare(Minimized.unsplitCall("0x55AB", undefined), guard + "\"0x55ab\") end end");
        compare(Minimized.unsplitCall("0x55AB", "fullscreen"), guard + "\"0x55ab\", \"fullscreen\") end end");
        compare(Minimized.unsplitCall("55ab", "replace"), guard + "\"0x55ab\", \"replace\") end end");
        compare(Minimized.unsplitCall("0x55AB", ""), guard + "\"0x55ab\") end end", "empty: as desktop");
        for (const how of ["Desktop", "full screen", "zoom", "replace\") end os.exit() --", null, 0])
            compare(Minimized.unsplitCall("55ab", how), "", String(how));
        compare(Minimized.unsplitCall("zz", "replace"), "", "an invalid address");
    }

    // TL27, TL28 (step 4a): a zone of the Layouts section, and a pick of the suggestions into the layout of another window.
    function test_zoneCallsAreBuiltFromValidatedPieces() {
        const guard = "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.arrange then p.arrange(";
        compare(Minimized.zoneCall("0x55AB", "thirds", 2), guard + "\"{\\\"layout\\\":\\\"thirds\\\",\\\"windows\\\":[\\\"0x55ab\\\"],\\\"zone\\\":2}\") end end");
        compare(Minimized.zoneCall("55ab", "quarters", 0, "0xD1"),
                guard + "\"{\\\"layout\\\":\\\"quarters\\\",\\\"windows\\\":[\\\"0x55ab\\\"],\\\"zone\\\":0,\\\"with\\\":\\\"0xd1\\\"}\") end end");
        compare(Minimized.zoneCall("55ab", "left-right", 1, ""), Minimized.zoneCall("55ab", "left-right", 1), "an empty with is none");
        // Every layout of the catalogue, from the Arrange rows to the large and portrait classes.
        for (const layout of ["left-right", "right-left", "top-bottom", "bottom-top", "quarters", "left-quarters", "right-quarters", "top-quarters", "bottom-quarters",
                 "wide-left", "thirds", "wide-center", "four-columns", "stacked-thirds"])
            verify(Minimized.zoneCall("55ab", layout, 0) !== "", layout);
        // Refused: not a layout, not a zone, a bad address or with, with the window itself.
        for (const layout of ["THIRDS", "", "halves", "thirds\") end os.exit() --", null])
            compare(Minimized.zoneCall("55ab", layout, 0), "", String(layout));
        for (const zone of [-1, 4, 1.5, "1", null, undefined, NaN])
            compare(Minimized.zoneCall("55ab", "quarters", zone), "", String(zone));
        for (const address of ["", "zz", "0x", "55ab\"", null])
            compare(Minimized.zoneCall(address, "quarters", 0) + Minimized.zoneCall("55ab", "quarters", 0, address === "" ? "zz" : address), "", String(address));
        compare(Minimized.zoneCall("55ab", "quarters", 0, "0x55AB"), "", "with the window itself");
    }

    function test_addIsIdempotentAndRemove() {
        let list = Minimized.add([], rec("a", "foot"));
        list = Minimized.add(list, rec("a", "foot"));
        compare(list.length, 1);
        verify(Minimized.has(list, "a"));
        list = Minimized.remove(list, "a");
        compare(list.length, 0);
    }

    function test_pruneDropsClosedWindows() {
        const list = [rec("a", "foot"), rec("b", "foot")];
        compare(Minimized.prune(list, ["b", "c"]).map(r => r.toplevel).join(","), "b");
    }

    function test_forAppIsCaseInsensitive() {
        const list = [rec("a", "Foot"), rec("b", "chromium")];
        compare(Minimized.forApp(list, "foot").length, 1);
    }

    function test_addressValidation() {
        compare(Minimized.normalizeAddress("0x5599AABB"), "5599aabb");
        compare(Minimized.normalizeAddress("5599aabb"), "5599aabb");
        compare(Minimized.normalizeAddress("zz"), "");
        compare(Minimized.normalizeAddress("1; hl.dsp.exit()"), "");
        compare(Minimized.normalizeAddress(""), "");
    }

    function test_minimizeRequestParsing() {
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/1","type":"minimize-request","address":"55AB"}'), "55ab");
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/1","type":"capabilities","address":"55ab"}'), "");
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/2","type":"minimize-request","address":"55ab"}'), "");
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/1","type":"minimize-request","address":"x\\"); hl.dsp.exit() --"}'), "");
        compare(Minimized.minimizeRequestAddress("not json"), "");
    }

    function lookup(id) {
        return id === "foot" ? {id: "foot", name: "Foot", icon: "foot-icon"} : null;
    }

    function test_dockSectionSitsBetweenSeparatorAndTrash() {
        const tiles = DockModel.minimizedItems([rec("a", "foot", "1a"), rec("b", "mystery", "2b")], lookup);
        compare(tiles[0].name, "T a");
        compare(tiles[0].icon, "foot-icon");
        compare(tiles[1].icon, "mystery");
        const items = DockModel.withTail([{kind: "app", key: "foot"}], tiles);
        compare(items.map(i => i.kind).join(","), "app,separator,minimized,minimized,trash");
    }

    function test_noMinimizedKeepsPreviousLayout() {
        compare(DockModel.withTail([]).map(i => i.kind).join(","), "separator,trash");
        compare(DockModel.withTail([], DockModel.minimizedItems([], lookup)).map(i => i.kind).join(","), "separator,trash");
    }

    function test_tileNameFallsBackToAppName() {
        const tiles = DockModel.minimizedItems([{toplevel: "a", address: "1", appId: "foot", title: ""}], lookup);
        compare(tiles[0].name, "Foot");
    }

    // D-1 (macOS; audit GF-001), without the plugin: the Desktop that the display the window was minimized from shows now,
    // never the display of the Dock that was clicked (the focused one).
    function test_restoreWorkspaceIsTheOwnDisplaysCurrentDesktop() {
        const monitors = [{name: "WAYLAND-1", workspace: 1}, {name: "GF-REF", workspace: 4}];
        compare(Minimized.restoreWorkspace("GF-REF", monitors, 1), "4", "its own display, whichever display is focused");
        compare(Minimized.restoreWorkspace("WAYLAND-1", monitors, 4), "1");
        compare(Minimized.restoreWorkspace("DP-9", monitors, 1), "1", "its display is gone: the focused Desktop");
        compare(Minimized.restoreWorkspace("", monitors, 1), "1", "no record (rebuilt after a restart): the focused Desktop");
        compare(Minimized.restoreWorkspace(undefined, monitors, 1), "1");
        compare(Minimized.restoreWorkspace("GF-REF", [{name: "GF-REF", workspace: -98}], 2), "2", "a special workspace is never a Desktop");
        compare(Minimized.restoreWorkspace("GF-REF", [{name: "GF-REF", workspace: "3\", x = 1"}], 2), "2", "only plain ids");
        compare(Minimized.restoreWorkspace("GF-REF", null, 2), "2");
        compare(Minimized.restoreWorkspace("GF-REF", [], 0), "", "nothing valid: nothing to move to");
        compare(Minimized.restoreWorkspace("GF-REF", [null, {name: "GF-REF", workspace: 7}], 0), "7");
    }

    function test_moveRequestValidates() {
        compare(Minimized.moveRequest("0x55AB", "3"), "hl.dsp.window.move({ workspace = \"3\", follow = false, window = \"address:0x55ab\" })");
        compare(Minimized.moveRequest("55ab", "special:minimized").indexOf("special:minimized") > 0, true);
        compare(Minimized.moveRequest("0x1; hl.dsp.exit()", "3"), "");
        compare(Minimized.moveRequest("\"})", "3"), "");
        compare(Minimized.moveRequest("55ab", "3\", x = 1"), "");
        compare(Minimized.moveRequest("55ab", ""), "");
        compare(Minimized.moveRequest("", "3"), "");
        compare(Minimized.moveRequest("55ab", "undefined"), "");
        compare(Minimized.moveRequest("55ab", undefined), "");
        compare(Minimized.moveRequest("55ab", "foo"), "");
        compare(Minimized.moveRequest("55ab", "0"), "");
        compare(Minimized.moveRequest("55ab", 4).indexOf("workspace = \"4\"") > 0, true);
    }

    function test_focusWindowRequestValidates() {
        compare(Minimized.focusWindowRequest("0xAB12"), "hl.dsp.focus({ window = \"address:0xab12\" })");
        compare(Minimized.focusWindowRequest("ab12"), "hl.dsp.focus({ window = \"address:0xab12\" })");
        compare(Minimized.focusWindowRequest("0x1\" }) evil"), "");
        compare(Minimized.focusWindowRequest(""), "");
        compare(Minimized.focusWindowRequest(undefined), "");
    }

    function test_focusRequestValidates() {
        compare(Minimized.focusRequest(3), "hl.dsp.focus({ workspace = \"3\" })");
        compare(Minimized.focusRequest("12"), "hl.dsp.focus({ workspace = \"12\" })");
        compare(Minimized.focusRequest(0), "");
        compare(Minimized.focusRequest(-1), "");
        compare(Minimized.focusRequest(1.5), "");
        compare(Minimized.focusRequest(undefined), "");
        compare(Minimized.focusRequest("3\", x = 1"), "");
    }

    function test_fullscreenRequest() {
        compare(Minimized.fullscreenRequest("0xAB12", "maximized"), "hl.dsp.window.fullscreen({ mode = \"maximized\", window = \"address:0xab12\" })");
        compare(Minimized.fullscreenRequest("0xAB12", "bogus"), "");
        compare(Minimized.fullscreenRequest("zz", "maximized"), "");
    }

    // ADR-0036 D78: Zoom is Fill with the plugin's "zoom-fill" (its tile verb, place "zoom"); Hyprland's maximized mode
    // without it (gate C2). Never "zoom" through the tiling keys' place list.
    function test_zoomRequest() {
        const guard = "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.tile then p.tile(";
        compare(Minimized.zoomCall("0xAB12"), guard + "\"0xab12\", \"zoom\") end end");
        compare(Minimized.zoomRequest("0xAB12", true), guard + "\"0xab12\", \"zoom\") end end");
        compare(Minimized.zoomRequest("0xAB12", false), "hl.dsp.window.fullscreen({ mode = \"maximized\", window = \"address:0xab12\" })");
        compare(Minimized.zoomRequest("0xAB12", undefined), Minimized.fullscreenRequest("0xAB12", "maximized"));
        for (const address of ["", "zz", "0x12345678901234567", "ab12\" end os.exit() --", null])
            compare(Minimized.zoomRequest(address, true) + Minimized.zoomRequest(address, false), "", String(address));
        compare(Minimized.tileCall("0xAB12", "zoom"), "", "the keys' tile places stay the tiling places");
    }

    function test_finiteRect() {
        verify(Minimized.finiteRect({x: 1, y: 2, w: 3, h: 4}) !== null);
        compare(Minimized.finiteRect({x: NaN, y: 2, w: 3, h: 4}), null);
        compare(Minimized.finiteRect({x: 1, y: Infinity, w: 3, h: 4}), null);
        compare(Minimized.finiteRect(null), null);
    }

    // Reduce Motion for Hyprland's own animations (A11Y-06): the normal values are the config's (looknfeel.lua), the reduced
    // ones are crossfades of at most 100 ms (speed 1) and no move animation; nothing outside the fixed table is interpolated.
    function test_motionCallMatchesTheConfigAndReducesToCrossfades() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/hypr/grassfield/looknfeel.lua"), false);
        xhr.send();
        const lua = xhr.responseText;
        for (const l of Minimized.motionLeaves.normal) {
            const style = l.style ? ", style = \"" + l.style + "\"" : "";
            const line = "hl.animation({ leaf = \"" + l.leaf + "\", enabled = true, speed = " + l.speed + ", bezier = \"" + l.bezier + "\"" + style + " })";
            verify(lua.indexOf(line) >= 0, "looknfeel.lua has: " + line);
        }
        const reduced = Minimized.motionCall(true);
        verify(reduced.startsWith("function() pcall(hl.animation, "), reduced);
        verify(reduced.indexOf("leaf = \"windowsIn\", enabled = true, speed = 1, bezier = \"gfStandard\", style = \"popin 100%\"") >= 0);
        verify(reduced.indexOf("leaf = \"workspaces\", enabled = true, speed = 1, bezier = \"gfStandard\", style = \"fade\"") >= 0);
        verify(reduced.indexOf("leaf = \"windowsMove\", enabled = false") >= 0);
        for (const l of Minimized.motionLeaves.reduced)
            verify(l.speed <= 1, l.leaf + " is at most 100 ms");
        compare(Minimized.motionCall(false).indexOf("slide") >= 0, true, "normal restores the Spaces slide");
        compare(Minimized.motionCall(false).indexOf("popin 94%") >= 0, true);
    }

    // GF-064: Reduce Motion also stops the compositor's screen zoom from gliding.
    function test_reduceMotionStopsTheZoomAnimation() {
        verify(Minimized.motionCall(true).indexOf("leaf = \"zoomFactor\", enabled = false") >= 0);
        verify(Minimized.motionCall(false).indexOf("leaf = \"zoomFactor\", enabled = true") >= 0);
    }

    // GF-125: the blur the shell asks for at the default transparency is the one the config ships (a config reload then
    // restores a value that is already right).
    function test_blurAtTheDefaultTransparencyIsTheConfigsOwn() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/hypr/grassfield/looknfeel.lua"), false);
        xhr.send();
        const lua = xhr.responseText;
        const t = Tokens.materialDefaultTransparency;
        verify(new RegExp("blur = \\{[^}]*size = " + Appearance.blurSize(t) + ",").test(lua), "size " + Appearance.blurSize(t));
        verify(new RegExp("blur = \\{[^}]*passes = " + Appearance.blurPasses(t) + ",").test(lua), "passes " + Appearance.blurPasses(t));
    }

    function test_isZoomed() {
        compare(Minimized.isZoomed({fullscreen: 1}), true);
        compare(Minimized.isZoomed({fullscreen: 2}), false);
        compare(Minimized.isZoomed({fullscreen: 0}), false);
        compare(Minimized.isZoomed(null), false);
    }
}
