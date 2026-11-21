import QtQuick
import QtTest
import "../../shell/services/BrightnessLogic.js" as Logic

// Per-output brightness (ADR-0045 OC-4, shell/services/BrightnessLogic.js): the answer of Omarchy's
// omarchy-brightness-display-ddc, the 5-point key step, which output a key and Quick Settings' slider act on, and the
// one-command-per-output queue (the last value wins, steps add up, a replug waits for the command still running).
TestCase {
    name: "BrightnessLogic"

    function test_names() {
        for (const n of ["eDP-1", "LVDS-1", "DSI-1", "eDP-2"])
            verify(Logic.isBuiltIn(n), n);
        for (const n of ["DP-1", "HDMI-A-1", "edp-1", "eDP", "", "WAYLAND-1"])
            verify(!Logic.isBuiltIn(n), n);
        verify(!Logic.isBuiltIn(undefined));
        for (const n of ["DP-1", "HDMI-A-1", "eDP-1", "DVI-D-2", "DP-10", "Unknown-1", "HEADLESS-2"])
            verify(Logic.isConnector(n), n);
        for (const n of ["", "-x", "--help", "DP-", "DP1", "1-DP", "DP-1 ", "DP-1\n", "../DP-1", "DP/1", "DP-1;rm", "D P-1", "DP-12345",
                         "A".repeat(25) + "-1"])
            verify(!Logic.isConnector(n), JSON.stringify(n));
        verify(!Logic.isConnector(null));
        compare(Logic.builtIn(["DP-1", "eDP-1", "HDMI-A-1"]), "eDP-1");
        compare(Logic.builtIn(["DP-1", "HDMI-A-1"]), "");
        compare(Logic.builtIn(undefined), "");
    }

    // The command prints the level alone on its line, or nothing (exit 1) without DDC/CI.
    function test_parsePercent() {
        compare(Logic.parsePercent("40\n"), 40);
        compare(Logic.parsePercent("0"), 0);
        compare(Logic.parsePercent(" 100 \n"), 100);
        compare(Logic.parsePercent("7"), 7);
        for (const t of ["", "\n", "101", "-5", "40%", "4.5", "40\n41\n", "abc", "1000", "Display not found"])
            compare(Logic.parsePercent(t), -1, JSON.stringify(t));
        compare(Logic.parsePercent(undefined), -1);
        compare(Logic.parsePercent(40), -1);
    }

    // 5 points a press, as the backlight keys (brightnessctl 5%+ / 5%-), within the command's 1..100.
    function test_stepPercent() {
        compare(Logic.stepPercent(40, "up"), 45);
        compare(Logic.stepPercent(40, "down"), 35);
        compare(Logic.stepPercent(98, "up"), 100);
        compare(Logic.stepPercent(100, "up"), 100);
        compare(Logic.stepPercent(3, "down"), 1);
        compare(Logic.stepPercent(0, "down"), 1);
        compare(Logic.stepPercent(0, "up"), 5);
        compare(Logic.stepPercent(40, "mute"), 40);
        compare(Logic.stepPercent(NaN, "up"), 5);
    }

    function test_argv() {
        compare(Logic.argvFor("DP-1", {kind: "query"}), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1"]);
        compare(Logic.argvFor("DP-1", {kind: "set", percent: 40}), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "40%"]);
        compare(Logic.argvFor("DP-1", {kind: "set", percent: 0}), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "1%"]);
        compare(Logic.argvFor("DP-1", {kind: "set", percent: 140}), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "100%"]);
        compare(Logic.argvFor("HDMI-A-1", {kind: "step", steps: 1}), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "HDMI-A-1", "+5%"]);
        compare(Logic.argvFor("HDMI-A-1", {kind: "step", steps: -3}), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "HDMI-A-1", "15%-"]);
        compare(Logic.argvFor("DP-1", {kind: "step", steps: 40}), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "+100%"]);
        compare(Logic.argvFor("DP-1", {kind: "step", steps: 0}), null);
        compare(Logic.argvFor("DP-1", {kind: "set", percent: NaN}), null);
        compare(Logic.argvFor("-x", {kind: "query"}), null);
        compare(Logic.argvFor("DP-1", null), null);
        compare(Logic.argvFor("DP-1", {kind: "rm"}), null);
    }

    function okEntry(level) {
        return Object.assign(Logic.fresh(), {status: "ok", level: level, serial: 1});
    }

    // The first query: probing, then ok with its level, or none (one journal line: `failed`).
    function test_probe() {
        let r = Logic.request(Logic.fresh(), "DP-1", {kind: "query"});
        compare(r.start, ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1"]);
        compare(r.entry.status, "probing");
        verify(r.entry.busy);
        let f = Logic.finished(r.entry, "DP-1", "40\n");
        compare(f.entry.status, "ok");
        compare(f.entry.level, 40);
        verify(!f.entry.busy);
        compare(f.start, null);
        verify(!f.failed);
        f = Logic.finished(r.entry, "DP-1", "");
        compare(f.entry.status, "none");
        verify(f.failed);
        verify(!Logic.answers({"DP-1": f.entry}, "DP-1"));
        // A display that does not answer takes no change.
        const no = Logic.request(f.entry, "DP-1", {kind: "step", steps: 1});
        compare(no.start, null);
        verify(!no.entry.busy);
        compare(no.entry.pending, null);
    }

    // At most one command per output: what comes meanwhile waits; a set replaces what waited (the last value wins).
    function test_coalescingSets() {
        let r = Logic.request(okEntry(40), "DP-1", {kind: "set", percent: 50});
        compare(r.start, ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "50%"]);
        compare(r.entry.level, 50);
        for (const p of [55, 60, 70]) {
            r = Logic.request(r.entry, "DP-1", {kind: "set", percent: p});
            compare(r.start, null, "nothing starts while one runs");
            compare(r.entry.level, p, "the slider shows the value at once");
        }
        compare(r.entry.pending, {kind: "set", percent: 70});
        const f = Logic.finished(r.entry, "DP-1", "50\n");
        compare(f.start, ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "70%"], "only the last value is sent");
        verify(f.entry.busy);
        compare(f.entry.pending, null);
        compare(f.entry.level, 70);
        const g = Logic.finished(f.entry, "DP-1", "70\n");
        compare(g.start, null);
        verify(!g.entry.busy);
        compare(g.entry.level, 70);
    }

    // Key presses add up while a command runs; the printed level corrects the expected one.
    function test_coalescingSteps() {
        let r = Logic.request(okEntry(40), "DP-1", {kind: "step", steps: 1});
        compare(r.start, ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "+5%"]);
        compare(r.entry.level, 45);
        r = Logic.request(r.entry, "DP-1", {kind: "step", steps: 1});
        r = Logic.request(r.entry, "DP-1", {kind: "step", steps: 1});
        compare(r.start, null);
        compare(r.entry.level, 55);
        compare(r.entry.pending, {kind: "step", steps: 2});
        // The display was at 30, not 40 (Settings changed it): the command stepped from its own level.
        const f = Logic.finished(r.entry, "DP-1", "35\n");
        compare(f.start, ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "+10%"]);
        compare(f.entry.level, 45);
        // Up then down while one runs: nothing more to send.
        let u = Logic.request(okEntry(40), "DP-1", {kind: "step", steps: 1});
        u = Logic.request(u.entry, "DP-1", {kind: "step", steps: 1});
        u = Logic.request(u.entry, "DP-1", {kind: "step", steps: -1});
        compare(u.entry.pending, {kind: "step", steps: 0});
        const h = Logic.finished(u.entry, "DP-1", "45\n");
        compare(h.start, null);
        verify(!h.entry.busy);
        compare(h.entry.level, 45);
    }

    // A step after a waiting set moves the set; a set after waiting steps replaces them; a query waits behind a change.
    function test_merge() {
        compare(Logic.merge({kind: "set", percent: 60}, {kind: "step", steps: -1}), {kind: "set", percent: 55});
        compare(Logic.merge({kind: "step", steps: 3}, {kind: "set", percent: 20}), {kind: "set", percent: 20});
        compare(Logic.merge(null, {kind: "query"}), {kind: "query"});
        compare(Logic.merge({kind: "step", steps: 1}, {kind: "query"}), {kind: "step", steps: 1});
        compare(Logic.merge({kind: "query"}, {kind: "step", steps: -2}), {kind: "step", steps: -2});
        compare(Logic.merge({kind: "set", percent: 99}, {kind: "step", steps: 1}), {kind: "set", percent: 100});
    }

    // A write that fails on a display that answered keeps it, up to three in a row; then it is a display without DDC/CI.
    function test_failures() {
        let e = okEntry(40);
        for (let i = 1; i <= 2; i++) {
            const r = Logic.request(e, "DP-1", {kind: "set", percent: 50});
            const f = Logic.finished(r.entry, "DP-1", "");
            compare(f.entry.status, "ok");
            compare(f.entry.failures, i);
            verify(!f.failed);
            e = f.entry;
        }
        const ok = Logic.finished(Logic.request(e, "DP-1", {kind: "set", percent: 50}).entry, "DP-1", "50");
        compare(ok.entry.failures, 0, "an answer resets the count");
        e = okEntry(40);
        let last = null;
        for (let i = 0; i < 3; i++) {
            const r = Logic.request(e, "DP-1", {kind: "step", steps: 1});
            r.entry.pending = {kind: "step", steps: 1};
            last = Logic.finished(r.entry, "DP-1", "");
            e = last.entry;
            if (i < 2)
                compare(last.start, ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "+5%"], "what waited still runs");
        }
        compare(e.status, "none");
        verify(last.failed);
        compare(last.start, null, "nothing more runs on a display that stopped answering");
    }

    // Security review LOW 3: every command runs under coreutils' timeout, which ends the command's whole process group (the bash
    // script and its ddcutil), and the shell's backstop only comes after the bound and its kill. A run that timed out (timeout
    // exits 124 without output) answers as not answered, and what waited for it starts only then: however long it runs, never
    // two commands on one bus.
    function test_bound() {
        compare(Logic.BOUND, ["timeout", "-k", "2", "12"]);
        for (const req of [{kind: "query"}, {kind: "set", percent: 50}, {kind: "step", steps: -1}])
            compare(Logic.argvFor("DP-1", req).slice(0, 5), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc"]);
        verify(Logic.BACKSTOP_MS > (12 + 2) * 1000, "the backstop waits past the bound and its kill");
        let r = Logic.request(okEntry(40), "DP-1", {kind: "set", percent: 50});
        verify(r.start !== null);
        for (let i = 0; i < 5; i++) {
            r = Logic.request(r.entry, "DP-1", {kind: "step", steps: 1});
            compare(r.start, null, "nothing more starts while the first runs");
        }
        verify(r.entry.busy);
        const f = Logic.finished(r.entry, "DP-1", "");
        compare(f.entry.failures, 1);
        compare(f.entry.status, "ok");
        compare(f.start, ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "+25%"], "what waited, once the first has ended");
    }

    // The keys act on the active display when it can be changed; else on the built-in panel's backlight (macOS).
    function test_keyTarget() {
        const ddc = {"DP-1": okEntry(40), "HDMI-A-1": Object.assign(Logic.fresh(), {status: "none"}), "DP-2": Object.assign(Logic.fresh(), {status: "probing"})};
        const names = ["eDP-1", "DP-1", "HDMI-A-1", "DP-2"];
        compare(Logic.keyTarget("DP-1", names, true, ddc), {kind: "ddc", output: "DP-1"});
        compare(Logic.keyTarget("eDP-1", names, true, ddc), {kind: "backlight", output: "eDP-1"});
        compare(Logic.keyTarget("HDMI-A-1", names, true, ddc), {kind: "backlight", output: "eDP-1"}, "no DDC/CI: the built-in panel");
        compare(Logic.keyTarget("DP-2", names, true, ddc), {kind: "backlight", output: "eDP-1"}, "not answered yet");
        compare(Logic.keyTarget("HDMI-A-1", ["DP-1", "HDMI-A-1"], false, ddc), {kind: "none", output: "HDMI-A-1"});
        compare(Logic.keyTarget("DP-1", ["DP-1", "HDMI-A-1"], false, ddc), {kind: "ddc", output: "DP-1"}, "a desktop");
        compare(Logic.keyTarget("DP-3", ["DP-3"], true, {}), {kind: "backlight", output: ""}, "an all-in-one's panel: the active display");
        compare(Logic.keyTarget("", [], false, {}), {kind: "none", output: ""});
        compare(Logic.keyTarget("", ["eDP-1"], true, null), {kind: "backlight", output: "eDP-1"});
        // A built-in name never goes over DDC/CI, whatever an entry says.
        compare(Logic.keyTarget("eDP-1", names, false, {"eDP-1": okEntry(10)}), {kind: "none", output: "eDP-1"});
    }

    // Quick Settings' Display: the built-in display's, else the main display's when it answers.
    function test_sliderTarget() {
        const ddc = {"DP-1": okEntry(40), "DP-2": Object.assign(Logic.fresh(), {status: "none"})};
        compare(Logic.sliderTarget(["eDP-1", "DP-1"], true, ddc, "DP-1"), {kind: "backlight", output: "eDP-1"});
        compare(Logic.sliderTarget(["DP-1", "DP-2"], false, ddc, "DP-1"), {kind: "ddc", output: "DP-1"});
        compare(Logic.sliderTarget(["DP-1", "DP-2"], false, ddc, "DP-2"), {kind: "none", output: ""});
        compare(Logic.sliderTarget(["DP-1"], false, ddc, ""), {kind: "none", output: ""});
        compare(Logic.sliderTarget([], false, {}, undefined), {kind: "none", output: ""});
    }

    // New external outputs are asked once; built-in and odd names never; an output that went away is forgotten (a replug asks
    // again); a new display on a connector whose command still runs waits for it, and that command's answer is not its own.
    function test_sync() {
        let s = Logic.sync({}, ["eDP-1", "DP-1", "HDMI-A-1", "WAYLAND-1", "HEADLESS-2", "-x", "DP-1"], {}, 0);
        compare(s.ask, ["DP-1", "HDMI-A-1"]);
        compare(Object.keys(s.ddc).sort(), ["DP-1", "HDMI-A-1"]);
        compare(s.ddc["DP-1"].serial, 1);
        compare(s.ddc["HDMI-A-1"].serial, 2);
        compare(s.serial, 2);
        verify(Logic.isVirtual("WAYLAND-1") && Logic.isVirtual("HEADLESS-2") && !Logic.isVirtual("DP-1"));
        const kept = Object.assign({}, s.ddc);
        kept["DP-1"] = okEntry(40);
        s = Logic.sync(kept, ["eDP-1", "DP-1"], {}, s.serial);
        compare(s.ask, []);
        compare(s.ddc["DP-1"].level, 40, "a known display keeps its state");
        compare(Object.keys(s.ddc), ["DP-1"]);
        s = Logic.sync({}, ["DP-1"], {"DP-1": true}, 7);
        compare(s.ask, [], "a command of the display before still runs");
        verify(s.ddc["DP-1"].busy);
        compare(s.ddc["DP-1"].pending, {kind: "query"});
        compare(s.ddc["DP-1"].serial, 8);
        const r = Logic.released(s.ddc["DP-1"], "DP-1");
        compare(r.start, ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1"], "its own query runs once the old command ends");
        compare(r.entry.status, "probing");
        verify(r.entry.busy);
        const idle = Logic.released(Object.assign(Logic.fresh(), {busy: true}), "DP-1");
        compare(idle.start, null);
        verify(!idle.entry.busy);
        // An output that went away is forgotten at once (before the command is looked up), so plugging it back asks again.
        const known = {"DP-1": okEntry(40), "DP-2": okEntry(10)};
        compare(Object.keys(Logic.forget(known, ["eDP-1", "DP-2"])), ["DP-2"]);
        compare(Logic.forget(known, ["DP-1", "DP-2"])["DP-1"].level, 40);
        compare(Logic.forget(null, ["DP-1"]), {});
        compare(Logic.forget(known, undefined), {});
    }

    // Owner's report of 2026-11-21: an HP LA2205 on DP-2 does not answer DDC/CI and was asked again at every display change and
    // every restart of the shell (18 "Remote I/O error" lines). A display that did not answer is remembered for the session by
    // its identity and asked again only on a brightness key on it or a new connection 10 minutes or more after it failed.
    function test_identity() {
        compare(Logic.identity("LA2205", "CN12345", "DP-2"), "LA2205|CN12345");
        compare(Logic.identity("DELL P2419H", "", "DP-3"), "DELL P2419H|");
        compare(Logic.identity("", "", "DP-3"), "connector:DP-3");
        compare(Logic.identity("", "", "../x"), "");
        compare(Logic.identity(undefined, null, "DP-1"), "connector:DP-1");
        compare(Logic.identity("A|B\n", "s", "DP-1"), "AB|s", "the separator and control characters are dropped");
        compare(Logic.identity("x".repeat(100), "", "DP-1").length, 65);
    }

    function test_silentFile() {
        compare(Logic.silentPath("/run/user/1000", "abc_123", "wayland-1"), "/run/user/1000/grassfield-ddc-silent-abc_123");
        compare(Logic.silentPath("/run/user/1000", "", "wayland-1"), "/run/user/1000/grassfield-ddc-silent-wayland-1");
        compare(Logic.silentPath("/run/user/1000", "a/../b", ""), "/run/user/1000/grassfield-ddc-silent-a_.._b");
        compare(Logic.silentPath("", "x", ""), "");
        compare(Logic.silentPath("relative", "x", ""), "");
        const map = Logic.rememberSilent({}, "LA2205|", 1000);
        compare(Logic.parseSilent(Logic.formatSilent(map)), map);
        for (const t of ["", "x", "[]", "null", "{\"v\":2,\"silent\":{}}", "{\"v\":1,\"silent\":[]}"])
            compare(Logic.parseSilent(t), {}, t);
        compare(Logic.parseSilent("{\"v\":1,\"silent\":{\"a|\":5,\"b|\":\"x\",\"c|\":-1}}"), {"a|": 5});
    }

    function test_silentWindow() {
        const m = Logic.rememberSilent({}, "LA2205|", 1000000);
        verify(Logic.isSilent(m, "LA2205|", 1000000));
        verify(Logic.isSilent(m, "LA2205|", 1000000 + Logic.REPROBE_AFTER_MS - 1));
        verify(!Logic.isSilent(m, "LA2205|", 1000000 + Logic.REPROBE_AFTER_MS), "a new connection after 10 minutes asks again");
        verify(!Logic.isSilent(m, "LA2205|", 1000000 - 1), "a clock moved back asks again");
        verify(!Logic.isSilent(m, "DELL P2419H|", 1000000));
        verify(!Logic.isSilent(m, "", 1000000));
        compare(Logic.forgetSilent(m, "LA2205|"), {});
        let big = {};
        for (let i = 0; i < Logic.MAX_SILENT + 5; i++)
            big = Logic.rememberSilent(big, "m" + i + "|", i);
        compare(Object.keys(big).length, Logic.MAX_SILENT);
        verify(!Object.prototype.hasOwnProperty.call(big, "m0|"), "the oldest goes first");
        verify(Object.prototype.hasOwnProperty.call(big, "m" + (Logic.MAX_SILENT + 4) + "|"));
    }

    // The owner's displays: DP-2 (HP) silent; the shell restarts, then DP-3 (Dell) is unplugged and plugged back. Only the Dell
    // is asked; the HP reads "none" at once, without a command.
    function test_silentNotAskedAgain() {
        const ids = {"eDP-1": "0x63ED|", "DP-2": "LA2205|", "DP-3": "DELL P2419H|"};
        const silent = Logic.rememberSilent({}, "LA2205|", 5000);
        // A restart: nothing known yet.
        let s = Logic.sync({}, ["eDP-1", "DP-2", "DP-3"], {}, 0);
        compare(s.ask, ["DP-2", "DP-3"]);
        let kept = Logic.skipSilent(s, ids, silent, 6000);
        compare(kept.ask, ["DP-3"]);
        compare(kept.ddc["DP-2"].status, "none");
        verify(!Logic.answers(kept.ddc, "DP-2"));
        compare(kept.ddc["DP-3"].status, "unknown");
        // DP-3 replugged (it went away, then came back): the Dell asked again, the HP still not.
        const gone = Logic.forget(kept.ddc, ["eDP-1", "DP-2"]);
        s = Logic.sync(gone, ["eDP-1", "DP-2", "DP-3"], {}, kept.ddc["DP-3"].serial);
        kept = Logic.skipSilent(s, ids, silent, 7000);
        compare(kept.ask, ["DP-3"]);
        // The HP replugged 10 minutes after it failed: asked again.
        s = Logic.sync({}, ["DP-2"], {}, 0);
        compare(Logic.skipSilent(s, ids, silent, 5000 + Logic.REPROBE_AFTER_MS).ask, ["DP-2"]);
        // Without a memory every new display is asked, as before.
        compare(Logic.skipSilent(Logic.sync({}, ["DP-2"], {}, 0), ids, {}, 6000).ask, ["DP-2"]);
    }

    // A brightness key on a silent display asks it again, at most every KEY_REPROBE_MS, never while a command runs.
    function test_keyReprobe() {
        const none = Object.assign(Logic.fresh(), {status: "none"});
        verify(Logic.keyReprobe(none, "DP-2", 100000, 0));
        verify(Logic.keyReprobe(none, "DP-2", 100000, undefined));
        verify(!Logic.keyReprobe(none, "DP-2", 100000, 100000 - Logic.KEY_REPROBE_MS + 1));
        verify(Logic.keyReprobe(none, "DP-2", 100000, 100000 - Logic.KEY_REPROBE_MS));
        verify(Logic.keyReprobe(none, "DP-2", 100000, 200000), "a clock moved back allows it");
        verify(!Logic.keyReprobe(Object.assign({}, none, {busy: true}), "DP-2", 100000, 0));
        verify(!Logic.keyReprobe(Object.assign(Logic.fresh(), {status: "ok"}), "DP-2", 100000, 0));
        verify(!Logic.keyReprobe(none, "eDP-1", 100000, 0));
        verify(!Logic.keyReprobe(none, "HEADLESS-1", 100000, 0));
        verify(!Logic.keyReprobe(undefined, "DP-2", 100000, 0));
        // The query it starts is allowed on a "none" display; its answer makes it "ok" (the next keys drive it).
        const r = Logic.request(none, "DP-2", {kind: "query"});
        verify(r.start !== null);
        const f = Logic.finished(r.entry, "DP-2", "40\n");
        compare(f.entry.status, "ok");
        compare(f.entry.level, 40);
    }
}
