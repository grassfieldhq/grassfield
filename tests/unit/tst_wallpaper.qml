import QtQuick
import QtTest
import Grassfield.Ui

// Wallpaper settings and rules (ADR-0016, ui/Grassfield/Ui/WallpaperConfig.js): validation, defaults, display matching,
// per-display resolution, the carousel order, the pause policy, the helper's argument vectors and the failure ids.
// Schema parity lives in tst_settingsstore.
TestCase {
    name: "Wallpaper"

    readonly property var panel: ({name: "eDP-1", model: "LGD", serial: "123"})
    readonly property var panelMoved: ({name: "DP-3", model: "LGD", serial: "123"})
    readonly property var other: ({name: "HDMI-A-1", model: "", serial: ""})

    // The module, the schema and the default file agree (Store.js's literals are checked against the schema by
    // tst_settingsstore).
    function test_schemaParity() {
        function read(rel) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl(rel), false);
            xhr.send();
            return JSON.parse(xhr.responseText);
        }
        const props = read("../../config/schema/grassfield.schema.json").properties.wallpaper.properties;
        compare(props.source.enum, WallpaperConfig.SOURCES);
        compare(props.fit.enum, WallpaperConfig.FITS);
        compare(props.interval.enum, WallpaperConfig.INTERVAL_NAMES);
        compare(props.artwork.enum, WallpaperConfig.ARTWORKS);
        compare(props.artworkVariant.enum, WallpaperConfig.ARTWORK_VARIANTS);
        compare(Object.keys(props).sort(), Object.keys(WallpaperConfig.WALLPAPER_DEFAULTS).sort());
        compare(Object.keys(props.outputs.items.properties).sort(), ["color", "display", "fit", "interval", "path", "shuffle", "source"]);
        compare(read("../../config/defaults/grassfield.json").wallpaper, WallpaperConfig.WALLPAPER_DEFAULTS);
    }

    function test_defaults() {
        const n = WallpaperConfig.normalize(undefined);
        compare(n.source, "builtin");
        compare(n.path, "");
        compare(n.color, "#000000");
        compare(n.fit, "fill");
        compare(n.interval, "1h");
        compare(n.shuffle, true);
        compare(n.videoOnBattery, false);
        compare(n.online, {provider: "commons"});
        compare(n.outputs, []);
        for (const raw of [null, 5, "x", [], true])
            compare(WallpaperConfig.normalize(raw), n, String(raw));
    }

    function test_invalidFieldsReadAsDefaults() {
        const n = WallpaperConfig.normalize({source: "apod", path: "rel/x.jpg", color: "red", fit: 3, interval: "2s", shuffle: "yes", videoOnBattery: 1, online: {provider: "nasa"}, outputs: "x"});
        compare(n.source, "builtin");
        compare(n.path, "");
        compare(n.color, "#000000");
        compare(n.fit, "fill");
        compare(n.interval, "1h");
        compare(n.shuffle, true);
        compare(n.videoOnBattery, false);
        compare(n.online, {provider: "commons"});
        compare(n.outputs, []);
    }

    function test_sourceNeedsPath() {
        compare(WallpaperConfig.normalize({source: "file"}).source, "builtin");
        compare(WallpaperConfig.normalize({source: "folder", path: "relative"}).source, "builtin");
        compare(WallpaperConfig.normalize({source: "video", path: ""}).source, "builtin");
        compare(WallpaperConfig.normalize({source: "file", path: "/a/b.jpg"}).source, "file");
        compare(WallpaperConfig.normalize({source: "color", color: "#ABCDEF"}).color, "#abcdef");
        compare(WallpaperConfig.normalize({source: "color"}).source, "color", "colour needs no path");
    }

    function test_videoFit() {
        compare(WallpaperConfig.normalize({source: "video", path: "/v.mp4", fit: "tile"}).fit, "fill");
        compare(WallpaperConfig.normalize({source: "video", path: "/v.mp4", fit: "fit"}).fit, "fit");
        compare(WallpaperConfig.normalize({source: "file", path: "/v.jpg", fit: "tile"}).fit, "tile");
    }

    function test_pathRules() {
        compare(WallpaperConfig.pathProblem("/home/u/a.jpg"), "");
        compare(WallpaperConfig.pathProblem("/home/u/é ü 日本.jpg"), "");
        compare(WallpaperConfig.pathProblem(""), "empty");
        compare(WallpaperConfig.pathProblem("a.jpg"), "not-absolute");
        compare(WallpaperConfig.pathProblem("-rf"), "not-absolute");
        compare(WallpaperConfig.pathProblem(5), "not-a-string");
        compare(WallpaperConfig.pathProblem(null), "not-a-string");
        compare(WallpaperConfig.pathProblem("/a\nb"), "control-characters");
        compare(WallpaperConfig.pathProblem("/a\u0000b"), "control-characters");
        compare(WallpaperConfig.pathProblem("/a\u007fb"), "control-characters");
        compare(WallpaperConfig.pathProblem("/a‮b"), "control-characters", "bidi override");
        compare(WallpaperConfig.pathProblem("/" + "a".repeat(4095)), "");
        compare(WallpaperConfig.pathProblem("/" + "a".repeat(4096)), "too-long");
        // The limit is in bytes, not characters.
        compare(WallpaperConfig.pathProblem("/" + "é".repeat(2048)), "too-long");
        compare(WallpaperConfig.pathProblem("/" + "é".repeat(2047)), "");
        compare(WallpaperConfig.pathProblem("/" + "😀".repeat(1025)), "too-long");
    }

    function test_colorRules() {
        verify(WallpaperConfig.validColor("#a1B2c3"));
        verify(!WallpaperConfig.validColor("#a1b2c"));
        verify(!WallpaperConfig.validColor("a1b2c3"));
        verify(!WallpaperConfig.validColor("#a1b2c3 "));
        verify(!WallpaperConfig.validColor(0xa1b2c3));
    }

    function test_outputsValidation() {
        compare(WallpaperConfig.outputsProblem([]), "");
        compare(WallpaperConfig.outputsProblem([{display: panel, fit: "tile"}]), "");
        verify(WallpaperConfig.outputsProblem("x") !== "");
        verify(WallpaperConfig.outputsProblem([{}]) !== "", "display is required");
        verify(WallpaperConfig.outputsProblem([{display: {name: "", model: "m", serial: ""}}]) !== "", "no identity");
        verify(WallpaperConfig.outputsProblem([{display: panel, bogus: 1}]) !== "");
        verify(WallpaperConfig.outputsProblem([{display: {name: "a", model: "", serial: "", extra: 1}}]) !== "");
        verify(WallpaperConfig.outputsProblem([{display: panel, fit: "zoom"}]) !== "");
        verify(WallpaperConfig.outputsProblem([{display: panel, path: "rel"}]) !== "");
        verify(WallpaperConfig.outputsProblem([{display: panel, shuffle: "no"}]) !== "");
        verify(WallpaperConfig.outputsProblem([{display: panel}, {display: panelMoved}]) !== "", "same display twice");
        const many = [];
        for (let i = 0; i < 17; i++)
            many.push({display: {name: "o" + i, model: "", serial: ""}});
        compare(WallpaperConfig.outputsProblem(many.slice(0, 16)), "");
        compare(WallpaperConfig.outputsProblem(many), "too-many");
    }

    // The JSON adapter hands out a QVariantList as a sequence that is not an Array (review finding: the shell dropped
    // wallpaper.outputs). A stand-in with a length and indices; the real adapter path is in tests/shell/settings_roundtrip.
    function makeSeq(items) {
        // A prototype of its own, like the adapter's sequence: not Object.prototype, not Array.prototype.
        const o = Object.create({});
        o.length = items.length;
        for (let i = 0; i < items.length; i++)
            o[i] = items[i];
        return o;
    }

    function test_arrayLikeOutputs() {
        const like = makeSeq([{display: panel, fit: "tile"}, {display: other, source: "color"}]);
        verify(!Array.isArray(like));
        compare(WallpaperConfig.outputsProblem(like), "");
        compare(WallpaperConfig.normalizeOutputs(like).length, 2);
        const cfg = {source: "folder", path: "/pics", outputs: like};
        compare(WallpaperConfig.resolve(cfg, panelMoved).fit, "tile");
        compare(WallpaperConfig.resolve(cfg, other).source, "color");
        compare(WallpaperConfig.normalize(cfg).outputs.length, 2);
        const huge = makeSeq([]);
        huge.length = 1e9;
        compare(WallpaperConfig.outputsProblem(huge), "too-many");
        compare(WallpaperConfig.normalizeOutputs(huge).length, 0, "a hostile length reads at most a bounded number of items");
        const negative = makeSeq([]);
        negative.length = -1;
        compare(WallpaperConfig.outputsProblem(negative), "not-an-array");
        const fractional = makeSeq([]);
        fractional.length = 1.5;
        compare(WallpaperConfig.outputsProblem(fractional), "not-an-array");
        compare(WallpaperConfig.outputsProblem(makeSeq([{}])), "entry 0: display");
    }

    // A JSON object is not a list, whatever keys it has (the schema says array): {"length": 1, "0": {...}} reads as none.
    function test_aPlainObjectWithALengthIsNotAList() {
        const hostile = {length: 1, 0: {display: panel, fit: "tile"}};
        compare(WallpaperConfig.outputsProblem(hostile), "not-an-array");
        compare(WallpaperConfig.normalizeOutputs(hostile).length, 0);
        compare(WallpaperConfig.normalize({source: "color", outputs: hostile}).outputs.length, 0);
        compare(WallpaperConfig.outputsProblem({}), "not-an-array");
        compare(WallpaperConfig.outputsProblem(Object.create(null)), "not-an-array");
        compare(WallpaperConfig.outputsProblem("abc"), "not-an-array");
        compare(WallpaperConfig.outputsProblem(7), "not-an-array");
    }

    function test_normalizeOutputsDropsBadEntries() {
        const many = [];
        for (let i = 0; i < 20; i++)
            many.push({display: {name: "o" + i, model: "", serial: ""}, extra: "dropped?"});
        compare(WallpaperConfig.normalizeOutputs(many).length, 0, "entries with unknown keys are dropped");
        const good = [];
        for (let i = 0; i < 20; i++)
            good.push({display: {name: "o" + i, model: "", serial: ""}});
        compare(WallpaperConfig.normalizeOutputs(good).length, 16, "capped at 16");
        const mixed = [{display: panel, fit: "tile", bogus: 1}, {display: panel, fit: "fit"}, {display: other, source: "color"}, 7, null];
        const out = WallpaperConfig.normalizeOutputs(mixed);
        compare(out.length, 2, "the first is invalid (unknown key); the second and the third are kept; 7 and null are dropped");
        compare(out[0].display.name, "eDP-1");
        compare(out[0].fit, "fit");
    }

    function test_displayIdentity() {
        verify(WallpaperConfig.sameDisplay(panel, panelMoved), "model and serial win over the connector");
        verify(!WallpaperConfig.sameDisplay(panel, {name: "eDP-1", model: "LGD", serial: "999"}));
        verify(WallpaperConfig.sameDisplay(other, {name: "HDMI-A-1", model: "X", serial: ""}), "no serial: the connector name");
        verify(!WallpaperConfig.sameDisplay(other, {name: "HDMI-A-2", model: "", serial: ""}));
    }

    function test_resolve() {
        const cfg = {source: "folder", path: "/pics", fit: "fit", interval: "5m", outputs: [{display: panel, source: "color", color: "#112233"}, {display: other, fit: "tile", shuffle: false}]};
        const all = WallpaperConfig.resolve(cfg, {name: "Z", model: "", serial: ""});
        compare(all.source, "folder");
        compare(all.fit, "fit");
        verify(!("outputs" in all));
        const p = WallpaperConfig.resolve(cfg, panelMoved);
        compare(p.source, "color");
        compare(p.color, "#112233");
        compare(p.fit, "fit", "omitted fields come from the top level");
        const o = WallpaperConfig.resolve(cfg, other);
        compare(o.source, "folder");
        compare(o.fit, "tile");
        compare(o.shuffle, false);
        // An override can make a source without a path fall back to the artwork.
        const f = WallpaperConfig.resolve({outputs: [{display: panel, source: "file"}]}, panel);
        compare(f.source, "builtin");
    }

    function test_withOutput() {
        let list = WallpaperConfig.withOutput([], panel, {fit: "tile"});
        compare(list.length, 1);
        compare(list[0].fit, "tile");
        list = WallpaperConfig.withOutput(list, panelMoved, {color: "#010203"});
        compare(list.length, 1, "same display: replaced, not added");
        compare(list[0].fit, "tile");
        compare(list[0].color, "#010203");
        list = WallpaperConfig.withOutput(list, other, {source: "color"});
        compare(list.length, 2);
        list = WallpaperConfig.withOutput(list, panel, null);
        compare(list.length, 1);
        compare(list[0].display.name, "HDMI-A-1");
        const full = [];
        for (let i = 0; i < 16; i++)
            full.push({display: {name: "o" + i, model: "", serial: ""}});
        compare(WallpaperConfig.withOutput(full, {name: "new", model: "", serial: ""}, {fit: "fit"}).length, 16, "overflow leaves the list as it was");
        // The result always validates.
        compare(WallpaperConfig.outputsProblem(list), "");
    }

    function test_intervals() {
        compare(WallpaperConfig.intervalMs("login"), 0);
        compare(WallpaperConfig.intervalMs("5s"), 5000);
        compare(WallpaperConfig.intervalMs("1m"), 60000);
        compare(WallpaperConfig.intervalMs("1h"), 3600000);
        compare(WallpaperConfig.intervalMs("1d"), 86400000);
        compare(WallpaperConfig.intervalMs("bogus"), 3600000, "unknown reads as the default");
        compare(WallpaperConfig.INTERVAL_NAMES.length, 8);
        for (const name of WallpaperConfig.INTERVAL_NAMES)
            verify(name in WallpaperConfig.INTERVALS, name);
    }

    function names(n) {
        const l = [];
        for (let i = 0; i < n; i++)
            l.push("/p/" + (i < 10 ? "0" : "") + i + ".jpg");
        return l;
    }

    function test_orderWithoutShuffleIsByName() {
        const files = ["/p/b.jpg", "/p/a.jpg", "/p/C.jpg"];
        compare(WallpaperConfig.cycleOrder(files, false, 7), ["/p/C.jpg", "/p/a.jpg", "/p/b.jpg"]);
        compare(files[0], "/p/b.jpg", "the input is not modified");
    }

    function test_shuffleIsStableForASeedAndAPermutation() {
        const files = names(12);
        const a = WallpaperConfig.cycleOrder(files, true, 42);
        const b = WallpaperConfig.cycleOrder(files.slice().reverse(), true, 42);
        compare(a, b, "the same seed gives the same order whatever the listing order");
        compare(a.slice().sort(), files, "a permutation");
        verify(JSON.stringify(a) !== JSON.stringify(WallpaperConfig.cycleOrder(files, true, 43)), "another seed, another order");
        verify(JSON.stringify(a) !== JSON.stringify(files), "actually shuffled");
    }

    function test_advanceNoRepeatUntilAllShown() {
        const files = names(7);
        let state = {seed: 5, index: 0, last: ""};
        let seen = [];
        let lastFile = "";
        for (let cycle = 0; cycle < 4; cycle++) {
            seen = [];
            for (let i = 0; i < files.length; i++) {
                const r = WallpaperConfig.advance(files, true, state, null);
                verify(seen.indexOf(r.file) < 0, "no repeat inside a cycle: " + r.file);
                verify(r.file !== lastFile || i > 0 || files.length < 2, "no repeat across the cycle border");
                seen.push(r.file);
                lastFile = r.file;
                state = r.state;
            }
            compare(seen.slice().sort(), files);
        }
    }

    function test_advanceDeterministicAfterRestart() {
        const files = names(9);
        let state = {seed: 3, index: 0, last: ""};
        const first = [];
        for (let i = 0; i < 4; i++) {
            const r = WallpaperConfig.advance(files, true, state, null);
            first.push(r.file);
            state = r.state;
        }
        // A restart restores {seed, index, last} from the state file and continues the same cycle.
        const saved = JSON.parse(JSON.stringify(state));
        const cont = WallpaperConfig.advance(files, true, saved, null).file;
        const full = WallpaperConfig.cycleOrder(files, true, 3, "");
        compare(first, full.slice(0, 4));
        compare(cont, full[4]);
    }

    // Review finding: "login" advanced on every restart of the shell. It advances only for a new login.
    function test_keepPictureAfterARestart() {
        const files = ["/p/a.jpg", "/p/b.jpg"];
        const now = 1000000;
        // Timed interval: kept until it elapsed.
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: now - 1000}, 3600000, now, "", files, null), "/p/b.jpg");
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: now - 3600001}, 3600000, now, "", files, null), "");
        // Login: kept for the same login (compositor instance), advanced for another one or an unknown one.
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: 1, loginKey: "inst-1"}, 0, now, "inst-1", files, null), "/p/b.jpg", "a shell restart in the same login");
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: 1, loginKey: "inst-1"}, 0, now, "inst-2", files, null), "", "a new login");
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: 1, loginKey: "inst-1"}, 0, now, "", files, null), "", "unknown login key");
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: 1}, 0, now, "inst-1", files, null), "", "no key stored");
        // Never kept: vanished, failed this session, no state.
        compare(WallpaperConfig.keepPicture({last: "/p/gone.jpg", changedAt: now}, 3600000, now, "", files, null), "");
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: now}, 3600000, now, "", files, {"/p/b.jpg": true}), "");
        compare(WallpaperConfig.keepPicture(null, 3600000, now, "", files, null), "");
        compare(WallpaperConfig.keepPicture({last: 5, changedAt: now}, 3600000, now, "", files, null), "");
    }

    function test_prepareArgsKeepFiles() {
        const args = WallpaperConfig.prepareArgs("h", "/a.jpg", 10, 10, "fill", "#000000", "/o", 24, 1000, ["/o/x.jpg", "rel.jpg", "/o/y\nz.jpg", "/o/y.jpg"]);
        compare(args, ["h", "prepare", "--size", "10x10", "--fit", "fill", "--color", "#000000", "--out", "/o", "--strip-rows", "24", "--cache-max-bytes", "1000", "--keep", "/o/x.jpg", "--keep", "/o/y.jpg", "--", "/a.jpg"]);
    }

    function test_advanceSkipsBadAndHandlesEmpty() {
        const files = ["/p/a.jpg", "/p/b.jpg", "/p/c.jpg"];
        const bad = {"/p/b.jpg": true};
        let state = {seed: 1, index: 0, last: ""};
        const seen = [];
        for (let i = 0; i < 4; i++) {
            const r = WallpaperConfig.advance(files, false, state, bad);
            seen.push(r.file);
            state = r.state;
        }
        compare(seen, ["/p/a.jpg", "/p/c.jpg", "/p/a.jpg", "/p/c.jpg"]);
        compare(WallpaperConfig.advance(files, false, state, {"/p/a.jpg": true, "/p/b.jpg": true, "/p/c.jpg": true}).file, "", "every file failed");
        compare(WallpaperConfig.advance([], true, undefined, null).file, "");
        // A garbage state reads as a fresh one.
        compare(WallpaperConfig.advance(files, false, {seed: "x", index: null, last: 5}, null).file, "/p/a.jpg");
    }

    function test_advanceNewFilesJoinNextCycle() {
        let files = ["/p/a.jpg", "/p/b.jpg"];
        let state = {seed: 1, index: 0, last: ""};
        let r = WallpaperConfig.advance(files, false, state, null);
        compare(r.file, "/p/a.jpg");
        files = ["/p/a.jpg", "/p/aa.jpg", "/p/b.jpg"];
        r = WallpaperConfig.advance(files, false, r.state, null);
        compare(r.file, "/p/aa.jpg", "name order: a new file sorts into place (shuffle off)");
    }

    function test_playbackState() {
        const base = {locked: false, fullscreen: false, idle: false, onBattery: false, videoOnBattery: false, reduceMotion: false, profile: "balanced"};
        function st(over) {
            return WallpaperConfig.playbackState(Object.assign({}, base, over)).state;
        }
        compare(st({}), "play");
        compare(st({locked: true}), "pause");
        compare(st({fullscreen: true}), "pause");
        compare(st({idle: true}), "settle");
        compare(st({idle: true, reduceMotion: true}), "pause", "Reduce Motion pauses at once");
        compare(st({reduceMotion: true}), "pause");
        compare(st({profile: "reduced"}), "pause");
        compare(st({profile: "full"}), "play");
        compare(st({onBattery: true}), "pause");
        compare(st({onBattery: true, videoOnBattery: true}), "play");
        compare(st({onBattery: false, videoOnBattery: true}), "play");
        compare(st({onBattery: true, idle: true}), "pause", "battery wins over idle settle");
        compare(st({locked: true, idle: true, fullscreen: true}), "pause");
        compare(WallpaperConfig.playbackState(Object.assign({}, base, {locked: true})).reason, "locked");
        compare(WallpaperConfig.playbackState(base).reason, "");
    }

    function test_argumentVectorsHaveNoInjection() {
        const ok = WallpaperConfig.prepareArgs("/usr/lib/grassfield/grassfield-wallpaper", "/home/u/p.jpg", 1920, 1080, "fill", "#AABBCC", "/c/out");
        compare(ok, ["/usr/lib/grassfield/grassfield-wallpaper", "prepare", "--size", "1920x1080", "--fit", "fill", "--color", "#aabbcc", "--out", "/c/out", "--", "/home/u/p.jpg"]);
        // The source comes after "--": whatever it looks like, it is a path.
        compare(WallpaperConfig.prepareArgs("h", "/--size=1x1", 10, 10, "fill", "#000000", "/o")[11], "/--size=1x1");
        // Not a valid input, so no process: a path starting with "-", a relative path, a newline, a bad fit or colour.
        compare(WallpaperConfig.prepareArgs("h", "-rf", 10, 10, "fill", "#000000", "/o"), null);
        compare(WallpaperConfig.prepareArgs("h", "rel.jpg", 10, 10, "fill", "#000000", "/o"), null);
        compare(WallpaperConfig.prepareArgs("h", "/a\nb.jpg", 10, 10, "fill", "#000000", "/o"), null);
        compare(WallpaperConfig.prepareArgs("h", "/a.jpg", 10, 10, "zoom", "#000000", "/o"), null);
        compare(WallpaperConfig.prepareArgs("h", "/a.jpg", 10, 10, "fill", "black", "/o"), null);
        compare(WallpaperConfig.prepareArgs("h", "/a.jpg", 10, 10, "fill", "#000000", "-o"), null);
        // Sizes are clamped.
        compare(WallpaperConfig.sizeArg(0, -5), "1x1");
        compare(WallpaperConfig.sizeArg(1e9, 100000), "16384x16384");
        compare(WallpaperConfig.sizeArg(1919.6, 1080.2), "1920x1080");
        compare(WallpaperConfig.thumbArgs("h", "/a.jpg", 5000, "/o"), ["h", "thumb", "--width", "1024", "--out", "/o", "--", "/a.jpg"]);
        compare(WallpaperConfig.thumbArgs("h", "-a.jpg", 320, "/o"), null);
        compare(WallpaperConfig.listArgs("h", "/pics", 10000), ["h", "list", "--max", "10000", "--", "/pics"]);
        compare(WallpaperConfig.listArgs("h", "pics", 10000), null);
    }

    function test_failureIds() {
        compare(WallpaperConfig.reasonOf(0), "");
        compare(WallpaperConfig.reasonOf(3), "not-found");
        compare(WallpaperConfig.reasonOf(4), "not-regular");
        compare(WallpaperConfig.reasonOf(5), "too-large");
        compare(WallpaperConfig.reasonOf(6), "too-large");
        compare(WallpaperConfig.reasonOf(7), "unreadable");
        compare(WallpaperConfig.reasonOf(8), "unsupported");
        compare(WallpaperConfig.reasonOf(9), "timeout");
        compare(WallpaperConfig.reasonOf(127), "helper-missing");
        compare(WallpaperConfig.reasonOf(139), "failed", "a crash of the helper (SIGSEGV)");
        compare(WallpaperConfig.reasonOf(-1), "failed");
    }

    // Cases both implementations (this module and apps/settings/qml/Store.js, tst_settingsstore) must answer alike.
    function test_sharedRuleCases() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("fixtures/wallpaper-rules.json"), false);
        xhr.send();
        const cases = JSON.parse(xhr.responseText);
        verify(cases.paths.length > 10);
        for (const c of cases.paths)
            compare(WallpaperConfig.pathProblem(c[0]), c[1], JSON.stringify(c[0]).substring(0, 60));
        for (const c of cases.outputs)
            compare(WallpaperConfig.outputsProblem(c[0]) === "", c[1], JSON.stringify(c[0]).substring(0, 100));
    }

    function test_devGuard() {
        const repo = "/w/repo";
        compare(WallpaperConfig.sourceProblem("/w/repo/.dev/wallpapers/a.jpg", true, repo), "");
        compare(WallpaperConfig.sourceProblem("/w/repo/.dev", true, repo), "");
        compare(WallpaperConfig.sourceProblem("/home/u/Pictures/a.jpg", true, repo), "outside-dev");
        compare(WallpaperConfig.sourceProblem("/w/repo/.dev/../secret.jpg", true, repo), "outside-dev", "dot-dot is resolved first");
        compare(WallpaperConfig.sourceProblem("/w/repo/.devious/a.jpg", true, repo), "outside-dev", "a sibling with the same prefix");
        compare(WallpaperConfig.sourceProblem("/w/repo/.dev//wallpapers/./a.jpg", true, repo), "");
        compare(WallpaperConfig.sourceProblem("/home/u/Pictures/a.jpg", false, repo), "", "outside dev every absolute path is allowed");
        compare(WallpaperConfig.sourceProblem("rel.jpg", false, repo), "not-absolute");
        compare(WallpaperConfig.normalizePath("/a/b/../c//d/."), "/a/c/d");
        compare(WallpaperConfig.normalizePath("/.."), "/");
        compare(WallpaperConfig.normalizePath("a"), "");
        verify(WallpaperConfig.isUnder("/a/b", "/a"));
        verify(!WallpaperConfig.isUnder("/ab", "/a"));
    }

    function test_environmentPaths() {
        const dev = {dev: true, repoRoot: "/w/repo", home: "/home/u", xdgCache: "", picturesDir: ""};
        compare(WallpaperConfig.toolPath(dev), "/w/repo/.dev/build/grassfield-wallpaper");
        compare(WallpaperConfig.cacheRoot(dev), "/w/repo/.dev/cache/wallpapers");
        compare(WallpaperConfig.picturesRoot(dev), "/w/repo/.dev/wallpapers");
        const prod = {dev: false, repoRoot: "/w/repo", home: "/home/u", xdgCache: "", picturesDir: ""};
        compare(WallpaperConfig.toolPath(prod), "/usr/lib/grassfield/grassfield-wallpaper");
        compare(WallpaperConfig.cacheRoot(prod), "/home/u/.cache/grassfield/wallpapers");
        compare(WallpaperConfig.cacheRoot(Object.assign({}, prod, {xdgCache: "/x/cache"})), "/x/cache/grassfield/wallpapers");
        compare(WallpaperConfig.picturesRoot(Object.assign({}, prod, {picturesDir: "/home/u/Bilder"})), "/home/u/Bilder");
    }

    function test_toolLocale() {
        const none = {lcAll: "", lcCtype: "", lang: ""};
        compare(WallpaperConfig.toolEnvironment(none).LC_ALL, "C.UTF-8");
        compare(WallpaperConfig.toolEnvironment({lcAll: "", lcCtype: "", lang: "C"}).LC_ALL, "C.UTF-8");
        compare(WallpaperConfig.toolEnvironment({lcAll: "C", lcCtype: "", lang: "fr_FR.UTF-8"}).LC_ALL, "C.UTF-8");
        compare(Object.keys(WallpaperConfig.toolEnvironment({lcAll: "", lcCtype: "", lang: "fr_FR.UTF-8"})).length, 0);
        compare(Object.keys(WallpaperConfig.toolEnvironment({lcAll: "en_US.utf8", lcCtype: "", lang: "C"})).length, 0);
    }

    function test_stripContrast() {
        const black = WallpaperConfig.stripContrast(0, 0);
        fuzzyCompare(black.white, 21, 1e-9);
        const white = WallpaperConfig.stripContrast(1, 1);
        fuzzyCompare(white.black, 21, 1e-9);
        // A split strip: white text is limited by its lightest part, black text by its darkest part.
        const split = WallpaperConfig.stripContrast(0, 1);
        fuzzyCompare(split.white, 1, 1e-9);
        fuzzyCompare(split.black, 1, 1e-9);
        // The crossover of the two tones is around 0.179.
        const mid = WallpaperConfig.stripContrast(0.179, 0.179);
        verify(Math.abs(mid.white - mid.black) < 0.05);
    }

    // ---- online daily pictures (ADR-0016 step 2) ----

    function test_onlineSource() {
        compare(WallpaperConfig.normalize({source: "online"}).source, "online", "needs no path");
        compare(WallpaperConfig.normalize({source: "online", online: {provider: "commons"}}).online, {provider: "commons"});
        compare(WallpaperConfig.normalize({source: "online", online: "x"}).online, {provider: "commons"});
        compare(WallpaperConfig.normalize({source: "online", online: {provider: "apod"}}).online, {provider: "apod"});
        compare(WallpaperConfig.normalize({source: "online", online: {provider: "nasa"}}).online, {provider: "commons"}, "an unknown provider reads as the default");
        compare(WallpaperConfig.resolve({source: "online"}, panel).source, "online");
        compare(WallpaperConfig.resolve({source: "online"}, panel).provider, "commons");
        // Off by default, and a display can opt out or in on its own.
        compare(WallpaperConfig.normalize(undefined).source, "builtin");
        verify(!WallpaperConfig.onlineWanted(undefined));
        verify(!WallpaperConfig.onlineWanted({source: "folder", path: "/p"}));
        verify(WallpaperConfig.onlineWanted({source: "online"}));
        verify(WallpaperConfig.onlineWanted({source: "builtin", outputs: [{display: panel, source: "online"}]}));
        verify(WallpaperConfig.onlineWanted({source: "online", outputs: [{display: panel, source: "builtin"}]}), "other displays may still use it");
        compare(WallpaperConfig.resolve({source: "online", outputs: [{display: panel, source: "file", path: "/a.jpg"}]}, panel).source, "file");
        compare(WallpaperConfig.outputsProblem([{display: panel, source: "online"}]), "");
    }

    function test_onlineHelperArguments() {
        const out = "/home/u/.cache/grassfield/wallpapers/online/commons";
        compare(WallpaperConfig.fetchArgs("/usr/lib/grassfield/grassfield-wallpaper", "commons", "2026-10-22", out, "fr", ""), ["/usr/lib/grassfield/grassfield-wallpaper", "fetch", "commons", "--date", "2026-10-22", "--out", out, "--lang", "fr"]);
        compare(WallpaperConfig.fetchArgs("/h", "commons", "2026-10-22", out, "en", "http://127.0.0.1:8123").slice(-2), ["--base-url", "http://127.0.0.1:8123"]);
        compare(WallpaperConfig.fetchArgs("/h", "apod", "2026-10-22", out, "en", "").slice(0, 3), ["/h", "fetch", "apod"]);
        compare(WallpaperConfig.fetchArgs("/h", "nasa", "2026-10-22", out, "en", ""), null);
        compare(WallpaperConfig.fetchArgs("/h", "commons", "2026-10-22x", out, "en", ""), null);
        compare(WallpaperConfig.fetchArgs("/h", "commons", "--out", out, "en", ""), null);
        compare(WallpaperConfig.fetchArgs("/h", "commons", "2026-10-22", "relative", "en", ""), null);
        compare(WallpaperConfig.fetchArgs("/h", "commons", "2026-10-22", out, "de; rm", ""), null);
        compare(WallpaperConfig.latestArgs("/h", "commons", out), ["/h", "latest", "commons", "--out", out]);
        compare(WallpaperConfig.latestArgs("/h", "commons", "x"), null);
        compare(WallpaperConfig.reasonOf(11), "network");
        compare(WallpaperConfig.reasonOf(12), "skipped");
        compare(WallpaperConfig.reasonOf(13), "bad-response");
        verify(WallpaperConfig.onlineSkips(12));
        verify(WallpaperConfig.onlineSkips(5));
        verify(!WallpaperConfig.onlineSkips(11));
        verify(!WallpaperConfig.onlineSkips(9));
    }

    function test_onlineDates() {
        const t = Date.UTC(2026, 9, 22, 0, 9, 59);
        compare(WallpaperConfig.onlineDate(t), "2026-10-21", "before 00:10 UTC the day before");
        compare(WallpaperConfig.onlineDate(t + 1000), "2026-10-22", "from 00:10 UTC");
        compare(WallpaperConfig.onlineDate(Date.UTC(2026, 9, 22, 23, 59, 59)), "2026-10-22");
        compare(WallpaperConfig.onlineDate(Date.UTC(2027, 0, 1, 0, 5)), "2026-12-31", "across a year");
        verify(isNaN(WallpaperConfig.utcDayStart("2026-02-30")));
        verify(isNaN(WallpaperConfig.utcDayStart("x")));
    }

    function test_onlineScheduleFirstFetchIsImmediate() {
        const now = Date.UTC(2026, 9, 22, 3, 0);
        // Nothing cached and the day's slot (00:10 + rand * 6 h) is later: still due at once.
        const s = WallpaperConfig.onlineSchedule({}, now, false, 0.99);
        verify(s.due);
        compare(s.date, "2026-10-22");
        // A picture is cached: wait for the slot.
        const w = WallpaperConfig.onlineSchedule({}, now, true, 0.99);
        verify(!w.due);
        compare(w.at, Date.UTC(2026, 9, 22, 0, 10) + Math.floor(0.99 * 6 * 3600000));
        verify(w.at > now);
        const d = WallpaperConfig.onlineSchedule({}, now, true, 0.0);
        verify(d.due, "slot at 00:10 has passed at 03:00");
        compare(d.at, Date.UTC(2026, 9, 22, 0, 10));
    }

    function test_onlineSlotIsStableForTheDay() {
        const now = Date.UTC(2026, 9, 22, 9, 0);
        const a = WallpaperConfig.onlineSchedule({}, now, true, 0.5);
        // Persisted, then evaluated again with another random number: the slot does not move.
        const b = WallpaperConfig.onlineSchedule(a.state, now + 60000, true, 0.01);
        compare(b.at, a.at);
        // The next day picks a new one.
        const c = WallpaperConfig.onlineSchedule(a.state, Date.UTC(2026, 9, 23, 1, 0), true, 0.25);
        compare(c.date, "2026-10-23");
        compare(c.at, Date.UTC(2026, 9, 23, 0, 10) + Math.floor(0.25 * 6 * 3600000));
        // The window is 00:10 to 06:10 UTC.
        for (const r of [0, 0.3, 0.7, 0.999999, 1, 5, -1])
            verify(WallpaperConfig.onlineSchedule({}, Date.UTC(2026, 9, 22, 12), true, r).at <= Date.UTC(2026, 9, 22, 6, 10));
    }

    function test_onlineOneSuccessfulFetchPerDay() {
        const now = Date.UTC(2026, 9, 22, 9, 0);
        const st = WallpaperConfig.onlineAfter({}, now, "2026-10-22", "ok");
        const s = WallpaperConfig.onlineSchedule(st, now + 3600000, true, 0.0);
        verify(!s.due);
        compare(s.at, Date.UTC(2026, 9, 23, 0, 10), "looks again when the next day starts");
        // A skip (licence) ends the day too.
        verify(!WallpaperConfig.onlineSchedule(WallpaperConfig.onlineAfter({}, now, "2026-10-22", "skipped"), now, true, 0).due);
        // The next day it is due again once its slot has come.
        verify(WallpaperConfig.onlineSchedule(st, Date.UTC(2026, 9, 23, 7, 0), true, 0.0).due);
    }

    function test_onlineBackoff() {
        const t0 = Date.UTC(2026, 9, 22, 9, 0);
        let st = WallpaperConfig.onlineAfter({}, t0, "2026-10-22", "network");
        compare(st.failures, 1);
        compare(st.retryAt, t0 + 3600000, "1 h after the first failure");
        verify(!WallpaperConfig.onlineSchedule(st, t0 + 3599000, true, 0).due);
        verify(WallpaperConfig.onlineSchedule(st, t0 + 3600000, true, 0).due);
        const t1 = t0 + 3600000;
        st = WallpaperConfig.onlineAfter(st, t1, "2026-10-22", "network");
        compare(st.failures, 2);
        compare(st.retryAt, t1 + 3 * 3600000, "3 h after the second");
        verify(!WallpaperConfig.onlineSchedule(st, t1 + 3 * 3600000 - 1000, true, 0).due);
        const t2 = t1 + 3 * 3600000;
        st = WallpaperConfig.onlineAfter(st, t2, "2026-10-22", "network");
        compare(st.failures, 3);
        // Then the next day: not due for the rest of today, whatever the clock says.
        const s = WallpaperConfig.onlineSchedule(st, t2 + 5 * 3600000, true, 0);
        verify(!s.due);
        compare(s.at, Date.UTC(2026, 9, 23, 0, 10));
        // The next day starts with a clean slate.
        verify(WallpaperConfig.onlineSchedule(st, Date.UTC(2026, 9, 23, 7, 0), true, 0).due);
        // Success resets everything.
        const ok = WallpaperConfig.onlineAfter(st, t2, "2026-10-22", "ok");
        compare(ok.failures, 0);
        compare(ok.retryAt, 0);
        // Nothing cached does not bypass the backoff.
        verify(!WallpaperConfig.onlineSchedule(WallpaperConfig.onlineAfter({}, t0, "2026-10-22", "network"), t0 + 60000, false, 0.5).due);
    }

    function test_onlineStateFromAnything() {
        for (const raw of [null, 5, "x", [], {failures: "many", done: 7, retryAt: -1, slotAt: "x", failDate: "2026-99-99"}]) {
            const st = WallpaperConfig.onlineStateOf(raw);
            compare(st.done, "");
            compare(st.failures, 0);
            compare(st.retryAt, 0);
            compare(st.failDate, "");
        }
        compare(WallpaperConfig.onlineStateOf({failures: 99}).failures, 3);
        compare(WallpaperConfig.onlineStateOf({done: "2026-10-22"}).done, "2026-10-22");
    }

    function test_attributionLinks() {
        // Only an https address opens, and only a clean one.
        compare(WallpaperConfig.linkOf("https://creativecommons.org/licenses/by-sa/4.0"), "https://creativecommons.org/licenses/by-sa/4.0");
        for (const bad of ["", null, 5, "http://creativecommons.org/x", "javascript:alert(1)", "file:///etc/passwd", "-x", "https://", "https:///x", "https://a b/c", "https://a/b\nc", "https://a/b" + String.fromCharCode(0x202e) + "c", "https://a/" + String.fromCharCode(0x3164), "ftp://a/b"])
            compare(WallpaperConfig.linkOf(bad), "", String(bad));
        compare(WallpaperConfig.linkOf("https://a.org/" + "x".repeat(2100)), "");
    }

    function test_displayAddress() {
        compare(WallpaperConfig.displayUrl("https://commons.wikimedia.org/wiki/File%3AMount_Fuji%2C_%E5%AF%8C%E5%A3%AB.jpg"), "commons.wikimedia.org/wiki/File:Mount_Fuji,_" + String.fromCharCode(0x5bcc, 0x58eb) + ".jpg");
        compare(WallpaperConfig.displayUrl("https://a.org/x%20y"), "a.org/x y");
        compare(WallpaperConfig.displayUrl("https://commons.wikimedia.org/wiki/File:A.jpg"), "commons.wikimedia.org/wiki/File:A.jpg");
        // A bad escape, or one that would hide or reorder text, stays as written.
        compare(WallpaperConfig.displayUrl("https://a.org/%E0%A4%A"), "a.org/%E0%A4%A");
        compare(WallpaperConfig.displayUrl("https://a.org/x%0Ay"), "a.org/x%0Ay");
        compare(WallpaperConfig.displayUrl("https://a.org/x%E2%80%AEy"), "a.org/x%E2%80%AEy");
        compare(WallpaperConfig.displayUrl("https://a.org/x%E3%85%A4y"), "a.org/x%E3%85%A4y");
        compare(WallpaperConfig.displayUrl(undefined), "");
    }

    // ---- APOD, the aspect rule, video (ADR-0016 W7 and step 2) ----

    function test_apodProvider() {
        compare(WallpaperConfig.ONLINE_PROVIDERS, ["commons", "apod"]);
        // The APOD day flips at 05:10 UTC (midnight US Eastern whatever the summer time), Commons at 00:10 UTC.
        compare(WallpaperConfig.onlineDate(Date.UTC(2026, 9, 22, 5, 9), "apod"), "2026-10-21");
        compare(WallpaperConfig.onlineDate(Date.UTC(2026, 9, 22, 5, 10), "apod"), "2026-10-22");
        compare(WallpaperConfig.onlineDate(Date.UTC(2026, 9, 22, 0, 10), "commons"), "2026-10-22");
        compare(WallpaperConfig.onlineDate(Date.UTC(2026, 9, 22, 0, 10)), "2026-10-22", "no provider: Commons");
        compare(WallpaperConfig.onlineDate(Date.UTC(2026, 9, 22, 0, 10), "nasa"), "2026-10-22", "unknown: Commons");
        // The day's random slot lies within six hours after the flip.
        const now = Date.UTC(2026, 9, 22, 12);
        const s = WallpaperConfig.onlineSchedule({}, now, true, 0.0, "apod");
        compare(s.date, "2026-10-22");
        compare(s.state.slotAt, Date.UTC(2026, 9, 22, 5, 10));
        compare(s.state.provider, "apod");
        verify(WallpaperConfig.onlineSchedule({}, now, true, 0.999, "apod").state.slotAt <= Date.UTC(2026, 9, 22, 11, 10));
    }

    function test_eachProviderKeepsItsOwnAccounting() {
        const now = Date.UTC(2026, 9, 22, 12);
        let st = WallpaperConfig.onlineAfter({}, now, "2026-10-22", "ok", "commons");
        compare(st.provider, "commons");
        verify(!WallpaperConfig.onlineSchedule(st, now, true, 0, "commons").due, "Commons is done for the day");
        // Switching to APOD: a day done for Commons says nothing about APOD, and nothing cached means fetch at once.
        const a = WallpaperConfig.onlineSchedule(st, now, false, 0.9, "apod");
        verify(a.due);
        compare(a.state.provider, "apod");
        compare(a.state.done, "");
        // A state written before there were two providers belongs to Commons.
        const old = {done: "2026-10-22", failures: 0};
        verify(!WallpaperConfig.onlineSchedule(old, now, true, 0, "commons").due);
        verify(WallpaperConfig.onlineSchedule(old, now, false, 0, "apod").due);
        compare(WallpaperConfig.onlineStateOf({provider: "nasa"}).provider, "");
    }

    function test_onlineAspectRule() {
        // Within 35 % of the output's aspect: Fill. Panoramas and portraits: Fit on the picture's mean colour.
        compare(WallpaperConfig.onlineFit(1600, 1000, 1920, 1080, "#102030"), {fit: "fill", color: "#102030"});
        compare(WallpaperConfig.onlineFit(1920, 1080, 1920, 1080, "#FFFFFF").fit, "fill");
        compare(WallpaperConfig.onlineFit(1920, 1080, 1920, 1080, "#FFFFFF").color, "#ffffff");
        compare(WallpaperConfig.onlineFit(4000, 1000, 1920, 1080, "#102030").fit, "fit", "a panorama");
        compare(WallpaperConfig.onlineFit(1000, 1500, 1920, 1080, "#102030").fit, "fit", "a portrait");
        // The limits: 1.35 times and 0.65 times the output's aspect are still Fill, a hair beyond is Fit.
        const out = 1000 / 500;
        compare(WallpaperConfig.onlineFit(out * 1.35 * 1000, 1000, 1000, 500, "#000000").fit, "fill");
        compare(WallpaperConfig.onlineFit(out * 1.36 * 1000, 1000, 1000, 500, "#000000").fit, "fit");
        compare(WallpaperConfig.onlineFit(out * 0.65 * 1000, 1000, 1000, 500, "#000000").fit, "fill");
        compare(WallpaperConfig.onlineFit(out * 0.64 * 1000, 1000, 1000, 500, "#000000").fit, "fit");
        // Anything unreadable is Fill on black.
        compare(WallpaperConfig.onlineFit(0, 0, 1920, 1080, "red"), {fit: "fill", color: "#000000"});
        compare(WallpaperConfig.onlineFit(1600, 1000, 1920, 1080, undefined).color, "#000000");
    }

    function test_videoHelperArguments() {
        compare(WallpaperConfig.probeArgs("/h", "/v/a.mp4"), ["/h", "probe", "--", "/v/a.mp4"]);
        compare(WallpaperConfig.probeArgs("/h", "rel.mp4"), null);
        compare(WallpaperConfig.probeArgs("/h", "/v/a\nb.mp4"), null);
        const out = "/home/u/.cache/grassfield/wallpapers/video";
        const a = WallpaperConfig.transcodeArgs("/h", "/v/-evil.mp4", 1920, 1080, "fit", "#AABBCC", out, 24, 536870912, ["/c/k.mp4"], 600, 536870912);
        compare(a.slice(0, 2), ["/h", "transcode"]);
        compare(a.slice(-2), ["--", "/v/-evil.mp4"], "a path can never be read as an option");
        compare(a[a.indexOf("--size") + 1], "1920x1080");
        compare(a[a.indexOf("--color") + 1], "#aabbcc");
        compare(a[a.indexOf("--keep") + 1], "/c/k.mp4");
        compare(a[a.indexOf("--max-seconds") + 1], "600");
        compare(WallpaperConfig.transcodeArgs("/h", "/v/a.mp4", 1920, 1080, "zoom", "#000000", out, 24, 0, [], 0, 0), null);
        compare(WallpaperConfig.transcodeArgs("/h", "/v/a.mp4", 1920, 1080, "fill", "red", out, 24, 0, [], 0, 0), null);
        compare(WallpaperConfig.transcodeArgs("/h", "/v/a.mp4", 1920, 1080, "fill", "#000000", "relative", 24, 0, [], 0, 0), null);
        compare(WallpaperConfig.transcodeArgs("/h", "/v/a.mp4", 99999, 1080, "fill", "#000000", out, 0, 0, [], 9999, 0).slice(3, 4), ["16384x1080"]);
        verify(WallpaperConfig.VIDEO_SUFFIXES.indexOf("mp4") >= 0);
    }

    function test_transcodeOutput() {
        const t = WallpaperConfig.transcodeOutput('{"progress":0.25}\n{"progress":0.5}\nnot json\n{"ok":true,"code":0,"file":"/c/p.jpg"}\n');
        compare(t.progress, 0.5);
        compare(t.result.file, "/c/p.jpg");
        const partial = WallpaperConfig.transcodeOutput('{"progress":0.3}\n{"progre');
        compare(partial.progress, 0.3);
        compare(partial.result, null);
        compare(WallpaperConfig.transcodeOutput("").result, null);
        compare(WallpaperConfig.transcodeOutput('{"progress":7}').progress, -1, "out of range");
        compare(WallpaperConfig.transcodeOutput('[1,2]\n"x"\n').result, null);
        compare(WallpaperConfig.transcodeOutput('{"ok":false,"code":14,"reason":"video too long"}').result.code, 14);
    }

    function test_videoFailureReasons() {
        compare(WallpaperConfig.reasonOf(14), "video-too-long");
        compare(WallpaperConfig.reasonOf(15), "transcode-failed");
        compare(WallpaperConfig.reasonOf(16), "ffmpeg-missing");
        compare(WallpaperConfig.reasonOf(17), "cancelled");
        compare(WallpaperConfig.EXIT.VIDEO_TOO_LONG, 14);
    }

    function test_videoCrashMarker() {
        compare(WallpaperConfig.videoMarkerOf({path: "/v/a.mp4", at: 5}), {path: "/v/a.mp4", at: 5});
        compare(WallpaperConfig.videoMarkerOf({path: "/v/a.mp4"}).at, 0);
        for (const bad of [null, 5, "x", [], {}, {path: "rel"}, {path: 3}, {path: "/v/a\nb"}])
            compare(WallpaperConfig.videoMarkerOf(bad), null, JSON.stringify(bad));
        verify(WallpaperConfig.videoBlocked("/v/a.mp4", "/v/a.mp4"));
        verify(!WallpaperConfig.videoBlocked("/v/a.mp4", "/v/b.mp4"));
        verify(!WallpaperConfig.videoBlocked("", ""));
        verify(!WallpaperConfig.videoBlocked(undefined, "/v/a.mp4"));
    }

    function test_playbackInputsFeedThePolicy() {
        const cfg = {videoOnBattery: false};
        const play = WallpaperConfig.playbackInputs(false, false, false, false, cfg, false, "full");
        compare(WallpaperConfig.playbackState(play).state, "play");
        compare(WallpaperConfig.playbackState(WallpaperConfig.playbackInputs(true, false, false, false, cfg, false, "full")).reason, "locked");
        compare(WallpaperConfig.playbackState(WallpaperConfig.playbackInputs(false, true, false, false, cfg, false, "full")).reason, "fullscreen");
        compare(WallpaperConfig.playbackState(WallpaperConfig.playbackInputs(false, false, false, true, cfg, false, "full")).reason, "battery");
        compare(WallpaperConfig.playbackState(WallpaperConfig.playbackInputs(false, false, false, true, {videoOnBattery: true}, false, "full")).state, "play");
        compare(WallpaperConfig.playbackState(WallpaperConfig.playbackInputs(false, false, true, false, cfg, false, "full")).state, "settle");
        compare(WallpaperConfig.playbackState(WallpaperConfig.playbackInputs(false, false, false, false, cfg, true, "full")).reason, "reduce-motion");
        compare(WallpaperConfig.playbackState(WallpaperConfig.playbackInputs(false, false, false, false, cfg, false, "reduced")).reason, "reduced-profile");
        compare(WallpaperConfig.playbackState(WallpaperConfig.playbackInputs(false, false, false, false, undefined, false, "full")).state, "play");
    }

    function test_videoMarkersAndBlockedLists() {
        // One marker (older files) or a list of them; invalid ones are dropped; at most 16.
        compare(WallpaperConfig.videoMarkersOf({path: "/v/a.mp4", at: 1}), [{path: "/v/a.mp4", at: 1}]);
        compare(WallpaperConfig.videoMarkersOf([{path: "/v/a.mp4", at: 1}, {path: "rel"}, 5, {path: "/v/b.mp4"}]), [{path: "/v/a.mp4", at: 1}, {path: "/v/b.mp4", at: 0}]);
        compare(WallpaperConfig.videoMarkersOf(null), []);
        compare(WallpaperConfig.videoMarkersOf("x"), []);
        compare(WallpaperConfig.videoMarkersOf(Array.from({length: 40}, (_, i) => ({path: "/v/" + i + ".mp4"}))).length, 16);
        compare(WallpaperConfig.videoBlockedPaths("/v/a.mp4"), ["/v/a.mp4"]);
        compare(WallpaperConfig.videoBlockedPaths(["/v/a.mp4", "rel", 3, "/v/b\nc"]), ["/v/a.mp4"]);
        compare(WallpaperConfig.videoBlockedPaths(undefined), []);
        verify(WallpaperConfig.videoBlocked(["/v/a.mp4", "/v/b.mp4"], "/v/b.mp4"));
        verify(!WallpaperConfig.videoBlocked(["/v/a.mp4"], "/v/b.mp4"));
        verify(!WallpaperConfig.videoBlocked([], "/v/a.mp4"));
        verify(WallpaperConfig.videoBlocked("/v/a.mp4", "/v/a.mp4"));
    }

    function test_cancelRestoresPerDisplay() {
        const A = "n:eDP-1";
        const B = "n:HDMI-A-1";
        let m = {};
        // "All Displays" showed a picture; a video is chosen: Cancel puts the picture back.
        m = WallpaperConfig.rememberPrevious(m, "all", {source: "file", path: "/p/a.jpg", overridden: false}, "/v/x.mp4");
        // Display A had its own folder; display B had none.
        m = WallpaperConfig.rememberPrevious(m, A, {source: "folder", path: "/p/dir", overridden: true}, "/v/y.mp4");
        m = WallpaperConfig.rememberPrevious(m, B, {source: "file", path: "/p/inherited.jpg", overridden: false}, "/v/z.mp4");
        // The picker is on B when Cancel is pressed: B follows All Displays again; A's and All's entries are untouched.
        let plan = WallpaperConfig.cancelPlan(m, B, true, true, "video", "/v/z.mp4");
        compare(plan.action, "follow-all");
        compare(Object.keys(plan.map).sort(), ["all", A].sort());
        compare(plan.map[A], {source: "folder", path: "/p/dir", overridden: true});
        m = plan.map;
        // Cancel for A restores its own wallpaper, not what the others had.
        plan = WallpaperConfig.cancelPlan(m, A, true, true, "video", "/v/y.mp4");
        compare(plan.action, "restore");
        compare(plan.scope, "display");
        compare(plan.fields, {source: "folder", path: "/p/dir"});
        compare(Object.keys(plan.map), ["all"]);
        m = plan.map;
        // Cancel for All Displays (not a display): the picture, at the top level.
        plan = WallpaperConfig.cancelPlan(m, "all", false, false, "video", "/v/x.mp4");
        compare(plan.action, "restore");
        compare(plan.scope, "all");
        compare(plan.fields, {source: "file", path: "/p/a.jpg"});
        compare(Object.keys(plan.map), []);
        // Nothing recorded for the display, and nothing for All: a display has nothing to undo; All Displays gets the artwork.
        compare(WallpaperConfig.cancelPlan(plan.map, A, true, true, "video", "/v/y.mp4").action, "none");
        compare(WallpaperConfig.cancelPlan(plan.map, "all", false, false, "video", "/v/x.mp4").action, "artwork");
        // The video chosen again records nothing (the previous entry stays), and a missing map is harmless.
        const again = WallpaperConfig.rememberPrevious({all: {source: "file", path: "/p/a.jpg", overridden: false}}, "all", {source: "video", path: "/v/x.mp4", overridden: false}, "/v/x.mp4");
        compare(again.all.path, "/p/a.jpg");
        compare(WallpaperConfig.cancelPlan(null, "all", false, false, "video", "/v/x.mp4").action, "artwork");
    }

    // The video was chosen under All Displays; the picker is then moved to display A, which follows All Displays (it shows the
    // inherited video and its progress), and Cancel is pressed: it undoes the choice for All Displays and creates no override for A.
    function test_cancelOnAFollowingDisplayActsOnAllDisplays() {
        const A = "n:eDP-1";
        const B = "n:HDMI-A-1";
        let m = WallpaperConfig.rememberPrevious({}, "all", {source: "file", path: "/p/a.jpg", overridden: false}, "/v/x.mp4");
        const plan = WallpaperConfig.cancelPlan(m, A, true, false, "video", "/v/x.mp4");
        compare(plan.action, "restore");
        compare(plan.scope, "all");
        compare(plan.fields, {source: "file", path: "/p/a.jpg"});
        compare(Object.keys(plan.map), [], "the All Displays entry is used up");
        // A display with an override of its own and no entry of its own does not borrow the All Displays entry.
        const own = WallpaperConfig.cancelPlan(m, B, true, true, "video", "/v/x.mp4");
        compare(own.action, "none");
        compare(Object.keys(own.map), ["all"], "All's entry is untouched");
        // After the plan was used, another Cancel on A finds nothing: no artwork override is created for A.
        compare(WallpaperConfig.cancelPlan(plan.map, A, true, false, "video", "/v/x.mp4").action, "none");
    }

    // Review 5, blocking: display A had its own picture, a video was chosen on A (an entry for A), A went back to following All
    // Displays ("Use the All Displays Wallpaper"), a video X was chosen under All Displays, and Cancel is pressed with the picker on A.
    // Cancel acts on the All Displays choice; no override is created for A, whether the stale entry of A was forgotten or not.
    function test_cancelNeverCreatesAnOverrideForADisplayThatFollowsAll() {
        const A = "n:eDP-1";
        let m = WallpaperConfig.rememberPrevious({}, A, {source: "file", path: "/p/own.jpg", overridden: true}, "/v/y.mp4");
        m = WallpaperConfig.rememberPrevious(m, "all", {source: "file", path: "/p/a.jpg", overridden: false}, "/v/x.mp4");
        // The page forgets the entry of A when A goes back to following All; the plan does not depend on it.
        for (const map of [WallpaperConfig.forgetPrevious(m, A), m]) {
            const plan = WallpaperConfig.cancelPlan(map, A, true, false, "video", "/v/x.mp4");
            compare(plan.action, "restore");
            compare(plan.scope, "all");
            compare(plan.fields, {source: "file", path: "/p/a.jpg"});
            compare(plan.map, {}, "the stale entry of A and the All entry are both gone");
        }
        // The variant: A had no picture of its own before (the stale entry says "not overridden"): the same, not a silent no-op.
        let v = WallpaperConfig.rememberPrevious({}, A, {source: "file", path: "/p/inherited.jpg", overridden: false}, "/v/y.mp4");
        v = WallpaperConfig.rememberPrevious(v, "all", {source: "folder", path: "/p/dir", overridden: false}, "/v/x.mp4");
        const plan2 = WallpaperConfig.cancelPlan(v, A, true, false, "video", "/v/x.mp4");
        compare(plan2.action, "restore");
        compare(plan2.scope, "all");
        compare(plan2.fields, {source: "folder", path: "/p/dir"});
        // A stale entry and no All Displays entry: nothing to undo for a display that follows All, and the stale entry is dropped.
        const only = WallpaperConfig.cancelPlan(WallpaperConfig.rememberPrevious({}, A, {source: "file", path: "/p/own.jpg", overridden: true}, "/v/y.mp4"), A, true, false, "video", "/v/x.mp4");
        compare(only.action, "none");
        compare(only.map, {});
        // Nothing to restore for All Displays (the video chosen again): the artwork, in the All Displays scope, never on the display.
        const art = WallpaperConfig.cancelPlan({all: {source: "video", path: "/v/x.mp4", overridden: false}}, A, true, false, "video", "/v/x.mp4");
        compare(art.action, "artwork");
        compare(art.scope, "all");
        // forgetPrevious touches one key only and tolerates a missing map.
        compare(Object.keys(WallpaperConfig.forgetPrevious({all: {}, [A]: {}}, A)), ["all"]);
        compare(WallpaperConfig.forgetPrevious(null, A), {});
    }

    // Review 6: an entry that only sets Fit is not a wallpaper of its own, and Cancel never drops what the display set besides.
    function test_aFitOnlyEntryIsNotAnOverrideAndSurvivesCancel() {
        const A = {name: "eDP-1", model: "", serial: ""};
        const key = WallpaperConfig.displayKey(A);
        const fitOnly = [{display: A, fit: "fit"}];
        verify(!WallpaperConfig.sourceOverridden(fitOnly, A));
        verify(!WallpaperConfig.sourceOverridden([{display: A, color: "#112233", interval: "5m", shuffle: false}], A));
        verify(WallpaperConfig.sourceOverridden([{display: A, source: "color", color: "#112233"}], A));
        verify(WallpaperConfig.sourceOverridden([{display: A, source: "file", path: "/p/a.jpg"}], A));
        verify(WallpaperConfig.sourceOverridden([{display: A, path: "/p/a.jpg"}], A));
        verify(!WallpaperConfig.sourceOverridden([], A));
        verify(!WallpaperConfig.sourceOverridden(fitOnly, {name: "HDMI-A-1", model: "", serial: ""}), "another display");
        // Cancel for A while All Displays' video prepares: it acts on the All Displays choice (the display follows All).
        const m = WallpaperConfig.rememberPrevious({}, "all", {source: "file", path: "/p/a.jpg", overridden: false}, "/v/x.mp4");
        const plan = WallpaperConfig.cancelPlan(m, key, true, WallpaperConfig.sourceOverridden(fitOnly, A), "video", "/v/x.mp4");
        compare(plan.action, "restore");
        compare(plan.scope, "all");
        // A video chosen on A (A had only Fit before) then Cancel: its source and path go, its Fit stays.
        const own = [{display: A, fit: "fit", source: "video", path: "/v/y.mp4"}];
        const kept = WallpaperConfig.withoutSource(own, A);
        compare(kept.length, 1);
        compare(kept[0], {display: A, fit: "fit"});
        // An entry with nothing else is removed; other displays' entries and a missing list are untouched.
        const B = {name: "HDMI-A-1", model: "", serial: ""};
        const both = WallpaperConfig.withoutSource([{display: A, source: "video", path: "/v/y.mp4"}, {display: B, source: "color", color: "#000000"}], A);
        compare(both.length, 1);
        compare(both[0].display, B);
        compare(both[0].source, "color");
        compare(WallpaperConfig.withoutSource(null, A), []);
    }

    // ADR-0040 step 2c: the shipped photographs' list. An entry of the wrong shape is left out, never shown half, and an id
    // is a plain name: it becomes a file name in the folder.
    function photoEntry(over) {
        return Object.assign({id: "golden-mist", name: {en: "Golden Mist", fr: "Brume dorée"}, author: "A", credit: "© A, CC BY 4.0 <https://creativecommons.org/licenses/by/4.0>, via Wikimedia Commons",
            licenseShort: "CC BY 4.0", licenseUrl: "https://creativecommons.org/licenses/by/4.0/", sourceUrl: "https://commons.wikimedia.org/wiki/File:X.jpg",
            file: "Mist v1.2 over the field.JPEG"}, over || {});
    }

    function test_photosParse() {
        const dir = "/usr/share/grassfield/wallpapers/photos";
        const one = WallpaperConfig.parsePhotos(JSON.stringify({photos: [photoEntry()]}), dir);
        compare(one.length, 1);
        compare(one[0].path, dir + "/golden-mist.jpg");
        compare(WallpaperConfig.parsePhotos(JSON.stringify({photos: [photoEntry()]}), dir + "/")[0].path, dir + "/golden-mist.jpg");
        compare(WallpaperConfig.photoName(one[0], "fr_FR"), "Brume dorée");
        compare(WallpaperConfig.photoName(one[0], "fr"), "Brume dorée");
        compare(WallpaperConfig.photoName(one[0], "en_US"), "Golden Mist");
        compare(WallpaperConfig.photoName(one[0], "fy_NL"), "Golden Mist");
        compare(WallpaperConfig.photoAt(one, dir + "/golden-mist.jpg").id, "golden-mist");
        compare(WallpaperConfig.photoAt(one, dir + "/other.jpg"), null);
        // As its licence asks to be credited (the integrator's review of e067f26f): the work's own title (its file name without
        // the extension), the author's line with its copyright notice (the licence's address is the Licence row's link), and
        // Grassfield's changes; no author field, so the row reads Credit.
        compare(one[0].title, "Mist v1.2 over the field");
        const about = WallpaperConfig.photoAbout(one[0], "fr_FR");
        compare(about.title, "Mist v1.2 over the field");
        compare(about.credit, "© A, CC BY 4.0, via Wikimedia Commons");
        compare(about.author, undefined);
        compare(about.modified, true);
        compare(about.licenseUrl, "https://creativecommons.org/licenses/by/4.0/");
        compare(WallpaperConfig.photoAbout(null, "en"), null);
        compare(WallpaperConfig.photoCredit("A <https://x.org/a>, B <http://y.org/b>, C"), "A, B, C");
        compare(WallpaperConfig.photoCredit("A <not a link>"), "A <not a link>");
        compare(WallpaperConfig.photoCredit(undefined), "");
        for (const [file, title] of [["a.jpg", "a"], ["a.png", "a"], ["a.tif", "a"], ["a.b.webp", "a.b"], ["no extension", "no extension"], ["a.svg", "a.svg"]])
            compare(WallpaperConfig.parsePhotos(JSON.stringify({photos: [photoEntry({file: file})]}), dir)[0].title, title, file);
        for (const text of ["", "{", "[]", "null", JSON.stringify({photos: {}}), JSON.stringify({photos: [null, 3, "x"]})])
            compare(WallpaperConfig.parsePhotos(text, dir), [], text);
        compare(WallpaperConfig.parsePhotos(JSON.stringify({photos: [photoEntry()]}), "relative/dir"), []);
        const bad = [{id: "../etc/passwd"}, {id: "a/b"}, {id: "Golden"}, {id: ""}, {id: 3}, {name: {en: "x"}}, {name: {en: "x\u202ey", fr: "y"}},
            {author: ""}, {credit: undefined}, {licenseUrl: "http://creativecommons.org/"}, {sourceUrl: "file:///etc/passwd"},
            {licenseShort: "x".repeat(600)}, {file: ""}, {file: undefined}, {file: "a\u202eb.jpg"}];
        for (const over of bad)
            compare(WallpaperConfig.parsePhotos(JSON.stringify({photos: [photoEntry(over)]}), dir), [], JSON.stringify(over));
        // Each id once: the second is left out.
        compare(WallpaperConfig.parsePhotos(JSON.stringify({photos: [photoEntry(), photoEntry({author: "B"})]}), dir).map(p => p.author), ["A"]);
        // At most 64.
        const many = [];
        for (let i = 0; i < 80; i++)
            many.push(photoEntry({id: "p" + i}));
        compare(WallpaperConfig.parsePhotos(JSON.stringify({photos: many}), dir).length, 64);
    }

    // The desktop's About This Wallpaper (ADR-0040 step 2c): the online picture's attribution or the shown photograph's, only
    // while that output shows it, ready.
    function test_aboutEntryOf() {
        const dir = "/usr/share/grassfield/wallpapers/photos";
        const photos = WallpaperConfig.parsePhotos(JSON.stringify({photos: [photoEntry()]}), dir);
        const online = {entry: {title: "Day", author: "B", sourceUrl: "https://commons.wikimedia.org/wiki/File:D.jpg"}};
        compare(WallpaperConfig.aboutEntryOf({source: "online", state: "ready"}, online, photos, "en_US").title, "Day");
        compare(WallpaperConfig.aboutEntryOf({source: "online", state: "waiting"}, online, photos, "en_US"), null);
        compare(WallpaperConfig.aboutEntryOf({source: "online", state: "ready"}, {}, photos, "en_US"), null);
        const shown = WallpaperConfig.aboutEntryOf({source: "file", state: "ready", path: dir + "/golden-mist.jpg"}, online, photos, "fr_FR");
        compare(shown.title, "Mist v1.2 over the field");
        compare(shown.credit, "© A, CC BY 4.0, via Wikimedia Commons");
        compare(shown.modified, true);
        compare(shown.licenseShort, "CC BY 4.0");
        compare(shown.sourceUrl, "https://commons.wikimedia.org/wiki/File:X.jpg");
        compare(WallpaperConfig.aboutEntryOf({source: "file", state: "preparing", path: dir + "/golden-mist.jpg"}, online, photos, "en"), null);
        compare(WallpaperConfig.aboutEntryOf({source: "file", state: "ready", path: "/home/a/Pictures/golden-mist.jpg"}, online, photos, "en"), null);
        compare(WallpaperConfig.aboutEntryOf({source: "folder", state: "ready", path: dir}, online, photos, "en"), null);
        compare(WallpaperConfig.aboutEntryOf({source: "builtin", state: "builtin"}, online, photos, "en"), null);
        compare(WallpaperConfig.aboutEntryOf(undefined, online, photos, "en"), null);
        compare(WallpaperConfig.aboutEntryOf({source: "file", state: "ready", path: dir + "/golden-mist.jpg"}, online, [], "en"), null);
    }

    // The desktop uses that one rule for its menu item and its card, and the shell reads the shipped list (shell/ needs
    // Quickshell: read from the sources).
    function test_aboutEntryWiring() {
        function read(rel) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl("../../" + rel), false);
            xhr.send();
            return xhr.responseText.replace(/\/\/.*$/gm, "");
        }
        // The card labels a photograph's row Credit and adds Grassfield's changes.
        const card = read("shell/desktop/AttributionCard.qml");
        verify(/\{label: root\.entry\.author \? root\.authorLabel : root\.creditLabel, value: root\.entry\.author \|\| root\.entry\.credit \|\| ""/.test(card));
        verify(/\{label: root\.changesLabel, value: root\.entry\.modified === true \? root\.changesText : ""/.test(card));
        const icons = read("shell/desktop/IconsView.qml");
        verify(/aboutWallpaper: root\.screen !== null && WallpaperState\.aboutEntry\(root\.screen\.name\) !== null/.test(icons), "the menu item for either attribution");
        verify(/AttributionCard \{\s*entry: \(root\.screen && WallpaperState\.aboutEntry\(root\.screen\.name\)\)/.test(icons), "the card shows the same entry");
        const state = read("shell/services/WallpaperState.qml");
        verify(/WallpaperConfig\.aboutEntryOf\(outputs\[output\], online, photos, Qt\.locale\(\)\.name\)/.test(state));
        verify(/onLoaded: root\.photos = WallpaperConfig\.parsePhotos\(text\(\), root\.photosDir\)/.test(state), "the list read as Settings reads it");
        verify(/photosDir: dev \? repoRoot \+ "\/\.dev\/photos" : "\/usr\/share\/grassfield\/wallpapers\/photos"/.test(state), "the folders of scripts/dev/photos.sh and of the package");
    }

    // ADR-0040 step 9, as the integrator decided in the review of e067f26f: the clouds move on the lock screen only; the desktop
    // draws them still where the last lock left them.
    function test_lockMotion() {
        // Where they rest per output: 0 for anything not a finite number of at least 0.
        compare(WallpaperConfig.motionIn({"DP-1": 1500}, "DP-1"), 1500);
        compare(WallpaperConfig.motionIn({"DP-1": 1500}, "HDMI-A-1"), 0);
        for (const bad of [-1, NaN, Infinity, "1500", null, undefined, {}])
            compare(WallpaperConfig.motionIn({"DP-1": bad}, "DP-1"), 0, String(bad));
        for (const map of [null, undefined, [], "x", 3])
            compare(WallpaperConfig.motionIn(map, "DP-1"), 0);
        for (const inherited of ["__proto__", "constructor", "toString"])
            compare(WallpaperConfig.motionIn({}, inherited), 0, inherited);
        // A new map; the old one unchanged; nothing taken that is not valid.
        const a = {"DP-1": 10};
        const b = WallpaperConfig.withMotion(a, "HDMI-A-1", 250);
        compare(JSON.stringify(b), JSON.stringify({"DP-1": 10, "HDMI-A-1": 250}));
        compare(JSON.stringify(a), JSON.stringify({"DP-1": 10}));
        for (const [o, at] of [["", 5], ["DP-1", -5], ["DP-1", NaN], ["DP-1", Infinity], [null, 5], ["DP-1", "5"]])
            compare(WallpaperConfig.withMotion(a, o, at), a, String(o) + " " + String(at));
        compare(JSON.stringify(WallpaperConfig.withMotion(null, "DP-1", 0)), JSON.stringify({"DP-1": 0}));
        // The rest: half the fade further on while moving (linear slow-down from the running speed); else where they are.
        compare(WallpaperConfig.lockMotionRest(1000, true, 200), 1100);
        compare(WallpaperConfig.lockMotionRest(1000, false, 200), 1000);
        compare(WallpaperConfig.lockMotionRest(1000, true, 0), 1000, "Reduce Motion: no fade, no motion");
        compare(WallpaperConfig.lockMotionRest(-3, true, 200), 100);
        compare(WallpaperConfig.lockMotionRest(NaN, false, 200), 0);
        compare(WallpaperConfig.lockMotionRest(1000, "yes", 200), 1000);
        compare(WallpaperConfig.lockMotionRest(1000, true, NaN), 1000);
    }

    // The desktop never runs the motion: no Timer plays it (the slot sets no `playing`), the idle monitor is a video's only, and
    // the clouds are drawn where WallpaperState says the last lock left them.
    function test_theDesktopDrawsTheCloudsStill() {
        function read(rel) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl("../../" + rel), false);
            xhr.send();
            verify(xhr.responseText.length > 0, rel);
            return xhr.responseText.replace(/\/\/.*$/gm, "");
        }
        const slot = read("shell/desktop/WallpaperSlot.qml");
        verify(!/playing:/.test(slot), "the slot never plays the artwork");
        verify(/WallpaperArt \{[^}]*moving: root\.moving\s*motionMs: root\.motionMs/.test(slot));
        const wall = read("shell/desktop/Wallpaper.qml");
        verify(!/movingWanted/.test(wall));
        verify(/IdleMonitor \{\s*id: idleMonitor\s*enabled: win\.videoWanted\n/.test(wall), "the idle monitor for a video only");
        compare((wall.match(/motionMs: WallpaperState\.motionOf\(win\.modelData \? win\.modelData\.name : ""\)/g) || []).length, 3, "every slot (the third takes a change that arrives during a fade)");
        const state = read("shell/services/WallpaperState.qml");
        verify(/readonly property bool moving: WallpaperConfig\.normalize\(Settings\.wallpaper\)\.moving/.test(state));
        verify(/function motionOf\(output: string\): real \{\s*return WallpaperConfig\.motionIn\(root\.motion, output\);/.test(state));
        verify(/root\.motion = WallpaperConfig\.withMotion\(root\.motion, output, at\);/.test(state));
        // The artwork's Timer is the only thing that advances it, and only while playing.
        const art = read("ui/Grassfield/Ui/GrassfieldArtwork.qml");
        verify(/running: root\.movingOn && root\.playing/.test(art));
        compare((art.match(/root\.motionMs \+=/g) || []).length, 1);
    }

    // The list the package installs: every photograph reads, sixteen of them (the owner's call of 2026-10-31).
    function test_photosShippedList() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../packaging/arch/wallpaper-photos.json"), false);
        xhr.send();
        const photos = WallpaperConfig.parsePhotos(xhr.responseText, "/usr/share/grassfield/wallpapers/photos");
        compare(photos.length, 16);
        compare(photos.length, JSON.parse(xhr.responseText).photos.length, "no entry is left out");
        // Each one's About This Wallpaper: its own title, a credit naming its author and licence, and the changes.
        for (const p of photos) {
            const a = WallpaperConfig.photoAbout(p, "fr_FR");
            verify(a.title !== "" && a.title !== p.name.en && a.title !== p.name.fr, p.id);
            verify(a.credit.indexOf(p.author) >= 0, p.id + ": " + a.credit);
            verify(!/<https?:/.test(a.credit), p.id);
            if (p.licenseShort.indexOf("CC BY") === 0)
                verify(a.credit.indexOf(p.licenseShort) >= 0, p.id + ": " + a.credit);
            compare(a.modified, true);
        }
        // The copyright notice the author asked for stays (Argenberg's).
        compare(WallpaperConfig.photoAbout(photos.find(p => p.id === "mountain-pasture"), "en").credit.indexOf("© Vyacheslav Argenberg, CC BY 4.0"), 0);
    }

    // ADR-0040 step 2: the artwork and its variant (wallpaper.artwork, wallpaper.artworkVariant).
    function test_artworkKeys() {
        const d = WallpaperConfig.normalize({});
        compare(d.artwork, "grassfield");
        compare(d.artworkVariant, "timeOfDay");
        compare(WallpaperConfig.normalize({artwork: "meadow", artworkVariant: "dark"}).artwork, "meadow");
        compare(WallpaperConfig.normalize({artwork: "meadow", artworkVariant: "dark"}).artworkVariant, "dark");
        compare(WallpaperConfig.normalize({artwork: "Meadow", artworkVariant: 3}).artwork, "grassfield");
        compare(WallpaperConfig.normalize({artwork: "Meadow", artworkVariant: 3}).artworkVariant, "timeOfDay");
    }

    // The desktop reads the resolved settings (WallpaperFeed.cfg): the artwork and its variant must reach every display (a
    // resolve() that dropped them drew the Grassfield hills whatever was chosen).
    function test_resolveCarriesTheArtwork() {
        const cfg = {source: "builtin", artwork: "ridgeline", artworkVariant: "dark", outputs: [{display: {name: "eDP-1", model: "", serial: ""}, color: "#102030"}]};
        for (const d of [panel, other]) {
            const r = WallpaperConfig.resolve(cfg, d);
            compare(r.artwork, "ridgeline", d.name);
            compare(r.artworkVariant, "dark", d.name);
        }
        compare(WallpaperConfig.resolve({}, panel).artwork, "grassfield");
        // ADR-0040 step 9: the moving artwork, off by default, for every display.
        compare(WallpaperConfig.resolve({}, panel).moving, false);
        compare(WallpaperConfig.resolve({moving: true}, other).moving, true);
        compare(WallpaperConfig.normalize({moving: "yes"}).moving, false);
        compare(WallpaperConfig.resolve({}, panel).artworkVariant, "timeOfDay");
    }

    function test_artworkVariant() {
        const v = WallpaperConfig.artworkVariantFor;
        // Time of Day: the phase in the appearance's set; the Evening until the phase is known.
        compare(v("grassfield", "timeOfDay", false, "dawn"), "dawn.light");
        compare(v("grassfield", "timeOfDay", true, "night"), "night.dark");
        compare(v("grassfield", "timeOfDay", true, ""), "evening.dark");
        compare(v("grassfield", "timeOfDay", false, "noon"), "evening.light");
        // Automatic: Day in the light appearance, Evening in the dark one; Light and Dark whatever the appearance.
        compare(v("grassfield", "automatic", false, "night"), "day.light");
        compare(v("grassfield", "automatic", true, "day"), "evening.dark");
        compare(v("grassfield", "light", true, "night"), "day.light");
        compare(v("grassfield", "dark", false, "day"), "evening.dark");
        // The other artworks follow the appearance; Time of Day reads as Automatic.
        compare(v("meadow", "timeOfDay", true, "day"), "dark");
        compare(v("rows", "automatic", false, ""), "light");
        compare(v("ridgeline", "light", true, ""), "light");
        compare(v("ridgeline", "dark", false, ""), "dark");
        // An unknown choice reads as the default (Time of Day).
        compare(v("grassfield", "sometimes", false, "day"), "day.light");
    }

    // ---- the first frame and the ground (ADR-0040 step 3, ID-2 and ID-3) ----
    readonly property string prep: "/home/u/.cache/grassfield/wallpapers/prepared"
    readonly property var stripStats: ({all: {mean: 0.4, p5: 0.1, p95: 0.7}})

    function test_stillOfReadsOnlyTheHelpersOwnPictures() {
        const name = "0123456789abcdef0123456789abcdef.jpg";
        const good = {shown: {"eDP-1": {kind: "picture", file: prep + "/" + name, strip: stripStats, image: {mean: 0.3, p5: 0.1, p95: 0.6}, mean: "#336699"}}};
        const s = WallpaperConfig.stillOf(good, "eDP-1", prep);
        compare(s.file, prep + "/" + name);
        compare(s.strip.all.mean, 0.4);
        compare(s.image.p95, 0.6);
        compare(s.mean, "#336699");
        // The prepared folder may carry a trailing slash.
        compare(WallpaperConfig.stillOf(good, "eDP-1", prep + "/").file, prep + "/" + name);
        // Another output, nothing shown, nothing stored: null.
        compare(WallpaperConfig.stillOf(good, "DP-3", prep), null);
        compare(WallpaperConfig.stillOf({}, "eDP-1", prep), null);
        compare(WallpaperConfig.stillOf(null, "eDP-1", prep), null);
        compare(WallpaperConfig.stillOf({shown: []}, "0", prep), null);
        // Anything that is not a cache name directly in the prepared folder is never decoded (ADR-0016).
        for (const f of [prep + "/sub/" + name, prep + "/../" + name, "/etc/passwd", prep + "/" + name + ".png", prep + "/0123456789ABCDEF0123456789ABCDEF.jpg", prep + "/x.jpg", "/tmp/" + name, prep + name, 12])
            compare(WallpaperConfig.stillOf({shown: {o: {kind: "picture", file: f}}}, "o", prep), null, String(f));
        // Not a picture, or a video's poster: no still (the poster lives in the video cache; the desktop waits for the feed).
        compare(WallpaperConfig.stillOf({shown: {o: {kind: "art", file: prep + "/" + name}}}, "o", prep), null);
        compare(WallpaperConfig.stillOf({shown: {o: {kind: "picture", video: true, file: prep + "/" + name}}}, "o", prep), null);
        // No usable prepared folder: nothing is read.
        compare(WallpaperConfig.stillOf(good, "eDP-1", ""), null);
        compare(WallpaperConfig.stillOf(good, "eDP-1", "relative/prepared"), null);
        // Statistics of another shape are dropped, the picture stays.
        const odd = WallpaperConfig.stillOf({shown: {o: {kind: "picture", file: prep + "/" + name, strip: {all: {mean: "x"}}, image: [1], mean: "red"}}}, "o", prep);
        compare(odd.strip, null);
        compare(odd.image, null);
        compare(odd.mean, "");
        // An inherited key is not a stored output.
        compare(WallpaperConfig.stillOf({shown: {}}, "constructor", prep), null);
    }

    function test_withShownRecordsWhatIsOnScreen() {
        const url = "file://" + prep + "/0123456789abcdef0123456789abcdef.jpg";
        const pic = {kind: "picture", color: "", url: url, strip: stripStats, image: null, mean: "#112233", video: ""};
        const art = {artwork: "meadow", variant: "dark"};
        const saved = {displays: {k: {seed: 1}}};
        const a = WallpaperConfig.withShown(saved, "eDP-1", pic, art);
        compare(a.displays, saved.displays, "the carousel is kept");
        compare(a.shown["eDP-1"], {kind: "picture", artwork: "meadow", variant: "dark", file: prep + "/0123456789abcdef0123456789abcdef.jpg", video: false, strip: stripStats, image: null, mean: "#112233"});
        verify(saved.shown === undefined, "a new object: the stored state is not changed in place");
        // What is written reads back.
        compare(WallpaperConfig.stillOf(a, "eDP-1", prep).file, prep + "/0123456789abcdef0123456789abcdef.jpg");
        // The artwork and a colour replace the picture; a video keeps its poster, marked.
        compare(WallpaperConfig.withShown(a, "eDP-1", {kind: "art", artwork: "rows", variant: "light"}, art).shown["eDP-1"], {kind: "art", artwork: "rows", variant: "light"});
        compare(WallpaperConfig.withShown(a, "eDP-1", {kind: "color", color: "#102030"}, art).shown["eDP-1"], {kind: "color", artwork: "meadow", variant: "dark", color: "#102030"});
        compare(WallpaperConfig.withShown(a, "eDP-1", Object.assign({}, pic, {video: "file:///v.mp4"}), art).shown["eDP-1"].video, true);
        // Nothing usable: the record goes.
        verify(!("eDP-1" in WallpaperConfig.withShown(a, "eDP-1", null, art).shown));
        verify(!("eDP-1" in WallpaperConfig.withShown(a, "eDP-1", {kind: "color", color: "red"}, art).shown));
        // At most 16 outputs, the newest kept (a rewrite moves an output to the end).
        let many = {};
        for (let i = 0; i < 20; i++)
            many = WallpaperConfig.withShown(many, "out-" + i, pic, art);
        compare(Object.keys(many.shown).length, 16);
        verify("out-19" in many.shown && !("out-3" in many.shown));
        many = WallpaperConfig.withShown(many, "out-4", pic, art);
        many = WallpaperConfig.withShown(many, "out-20", pic, art);
        verify("out-4" in many.shown && !("out-5" in many.shown));
    }

    // ADR-0040 step 4a (ID-7): what the lock draws, from the same record.
    function test_lockBackdropOf() {
        const vid = "/home/u/.cache/grassfield/wallpapers/video";
        const name = "0123456789abcdef0123456789abcdef.jpg";
        const of = r => WallpaperConfig.lockBackdropOf({shown: {o: r}}, "o", prep, vid);
        compare(of({kind: "picture", file: prep + "/" + name, artwork: "rows", variant: "light"}), {kind: "picture", file: prep + "/" + name, color: "", artwork: "rows", variant: "light"});
        // A video's poster is in the video cache.
        compare(of({kind: "picture", video: true, file: vid + "/" + name}).file, vid + "/" + name);
        // Any other file: the artwork (the lock never decodes it).
        for (const f of ["/etc/passwd", prep + "/../" + name, vid + "/sub/" + name, "/tmp/" + name, prep + "/" + name + ".gif", null])
            compare(of({kind: "picture", file: f}), {kind: "art", file: "", color: "", artwork: "grassfield", variant: "evening.dark"}, String(f));
        compare(of({kind: "color", color: "#ABCDEF"}).color, "#ABCDEF");
        compare(of({kind: "color", color: "#ABCDEF"}).kind, "color");
        compare(of({kind: "color", color: "url(x)"}).kind, "art");
        // Unknown names read as the default artwork.
        compare(of({kind: "art", artwork: "nope", variant: "noon.light"}), {kind: "art", file: "", color: "", artwork: "grassfield", variant: "evening.dark"});
        compare(of({kind: "art", artwork: "grassfield", variant: "night.dark"}).variant, "night.dark");
        // Never shown: null (the lock waits for it, bounded).
        compare(WallpaperConfig.lockBackdropOf({shown: {}}, "o", prep, vid), null);
        compare(WallpaperConfig.lockBackdropOf(undefined, "o", prep, vid), null);
    }

    // The lock's checks of a still (ADR-0040 step 4a; review of cbd6ef05: the real folders, a mode no locale translates).
    function test_lockStillChecks() {
        const vid = "/home/u/.cache/grassfield/wallpapers/video";
        const name = "0123456789abcdef0123456789abcdef.jpg";
        const real = (a, b, f) => WallpaperConfig.lockStillReal(a + "\n" + b + "\n" + f + "\n");
        compare(real(prep, vid, prep + "/" + name), prep + "/" + name);
        compare(real(prep, vid, vid + "/" + name), vid + "/" + name);
        // The folders as realpath printed them (a cache reached through a symbolic link): the file is checked against those.
        compare(real("/data/cache/prepared", vid, "/data/cache/prepared/" + name), "/data/cache/prepared/" + name);
        for (const f of ["/etc/passwd", prep + "/sub/" + name, "/tmp/" + name, prep + "/" + name + ".svg", prep + "/x.jpg"])
            compare(real(prep, vid, f), "", f);
        // Anything but three lines (realpath failed, a newline in a path) is refused.
        compare(WallpaperConfig.lockStillReal(prep + "\n" + prep + "/" + name + "\n"), "");
        compare(WallpaperConfig.lockStillReal(prep + "\n" + vid + "\n" + prep + "/" + name + "\nx\n"), "");
        compare(WallpaperConfig.lockStillReal(""), "");
        compare(WallpaperConfig.lockStillReal(undefined), "");
        // stat --printf %f|%s: a regular file (0x8000) of 1 to max bytes.
        const max = 64 * 1024 * 1024;
        verify(WallpaperConfig.lockStillStatOk("81a4|123456", max));
        verify(WallpaperConfig.lockStillStatOk("8180|" + max + "\n", max));
        for (const t of ["41ed|4096", "a1ff|12", "11b6|0", "61b0|0", "81a4|0", "81a4|" + (max + 1), "regular file|12", "fichier|12", "81a4", "", "81a4|12|x", "zz|12"])
            verify(!WallpaperConfig.lockStillStatOk(t, max), t);
    }

    function test_groundOf() {
        compare(WallpaperConfig.groundOf({kind: "picture", mean: "#a0b0c0"}, "#2F6D5F", "#000000"), "#A0B0C0");
        compare(WallpaperConfig.groundOf({kind: "color", color: "#ff8800"}, "#2F6D5F", "#000000"), "#FF8800");
        compare(WallpaperConfig.groundOf({kind: "art"}, "#2f6d5f", "#000000"), "#2F6D5F");
        // Nothing usable: the static default.
        compare(WallpaperConfig.groundOf({kind: "picture", mean: ""}, "#2F6D5F", "#000001"), "#000001");
        compare(WallpaperConfig.groundOf({kind: "color", color: "red"}, "#2F6D5F", "#000001"), "#000001");
        compare(WallpaperConfig.groundOf({kind: "art"}, "", "#000001"), "#000001");
        compare(WallpaperConfig.groundOf(null, "#2F6D5F", "#000001"), "#000001");
    }

    // Review of 4457edc1 (M1): a phase or an appearance known before the feed's first result never chooses the first frame.
    function test_firstFrameChoice() {
        const c = WallpaperConfig.firstFrameChoice;
        // Before wallpaper.json was read: nothing (the stored still is not known yet).
        compare(c(false, false, false), "wait");
        compare(c(true, false, true), "wait");
        // The stored still until the feed's first result, which then decides.
        compare(c(false, true, true), "still");
        compare(c(true, true, true), "feed");
        compare(c(true, true, false), "feed");
        // No still and no result yet: the window stays unmapped (bounded by the timeout).
        compare(c(false, true, false), "wait");
        // The window's wiring: only the feed marks its first result; a phase or appearance event goes through the choice.
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/desktop/Wallpaper.qml"), false);
        xhr.send();
        const w = xhr.responseText;
        compare((w.match(/win\.feedSeen = true;/g) || []).length, 1);
        // ... and not the signal the feed emits when it is created (its placeholder artwork, rc1-16: the default artwork was
        // the first frame): only after the first request.
        verify(/onDisplayChanged: \{(\s*\/\/[^\n]*)*\s*if \(!feed\.appliedOnce\)\s*return;\s*win\.feedSeen = true;\s*win\.show\(/.test(w));
        verify(/if \(!win\.firstReady\) \{\s*win\.begin\(\);\s*return;\s*\}/.test(w), "show() before the first frame only asks the choice");
        // After the first frame too: a phase or an appearance acts on the artwork only once the feed has given its first result
        // (counter-review of c5d43be4: a mapped still was cut to the placeholder artwork).
        compare((w.match(/feed\.display\.kind === "art"/g) || []).length, 3);
        compare((w.match(/win\.artLive && feed\.display\.kind === "art"/g) || []).length, 3);
        verify(/readonly property bool artLive: win\.feedSeen \|\| win\.fallbackArt/.test(w), "a fallback artwork follows the phase too");
        compare((w.match(/win\.fallbackArt = true;/g) || []).length, 2);
    }

    function test_groundFor() {
        compare(WallpaperConfig.groundFor({a: "#102030"}, "a", "#000000"), "#102030");
        compare(WallpaperConfig.groundFor({a: "#102030"}, "b", "#000000"), "#000000");
        compare(WallpaperConfig.groundFor({a: "red"}, "a", "#000000"), "#000000");
        compare(WallpaperConfig.groundFor({}, "constructor", "#000000"), "#000000");
        compare(WallpaperConfig.groundFor(null, "a", ""), "");
    }

    // wallpaper.json keeps every part: the carousel, the last wallpaper shown, the video markers.
    function test_stateTextKeepsEveryPart() {
        const shown = {o: {kind: "art", artwork: "rows", variant: "dark"}};
        let saved = {displays: {k: {seed: 1}}, shown: shown};
        saved = WallpaperConfig.withCarousel(saved, "k2", {seed: 2});
        compare(saved.shown, shown, "a carousel step keeps the record");
        compare(saved.displays.k2.seed, 2);
        const o = JSON.parse(WallpaperConfig.stateText(saved, {"eDP-1": "/v.mp4", "DP-1": "/v.mp4"}, ["/b.mp4"], 42));
        compare(o.displays.k.seed, 1);
        compare(o.shown, shown);
        compare(o.videoStarting, [{path: "/v.mp4", at: 42}]);
        compare(o.videoBlocked, ["/b.mp4"]);
        // The empty parts are left out.
        compare(JSON.parse(WallpaperConfig.stateText({displays: {}}, {}, [], 1)), {displays: {}});
        compare(JSON.parse(WallpaperConfig.stateText(null, null, null, 1)), {displays: {}});
    }

    // Defect of rc1-16: a flat green screen, then the default artwork, then the configured wallpaper. The feed answered from the
    // default settings before grassfield.json was read (the default artwork became the first frame), a stored still of another
    // wallpaper showed first, and the first-frame bound painted the default artwork while a picture was still being prepared.
    function test_noDefaultOrOtherWallpaperBeforeTheConfiguredOne() {
        function text(rel) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl(rel), false);
            xhr.send();
            verify(xhr.responseText.length > 0, rel);
            return xhr.responseText;
        }
        // The feed waits for the settings (read, or their bound).
        const f = text("../../shell/desktop/WallpaperFeed.qml");
        verify(/readonly property bool ready: [^\n]*Entrance\.settingsFinal/.test(f), "the feed waits for the settings");
        // A still belongs to the setting it was shown for.
        const name = "0123456789abcdef0123456789abcdef.jpg";
        const pic = {kind: "picture", color: "", url: "file://" + prep + "/" + name, strip: stripStats, image: null, mean: "#112233", video: ""};
        const file = {source: "file", path: "/usr/share/grassfield/wallpapers/photos/valley-fog.jpg"};
        const key = WallpaperConfig.sourceKey(file);
        const rec = WallpaperConfig.withShown({}, "o", pic, {artwork: "grassfield", variant: "evening.dark", src: key});
        const still = WallpaperConfig.stillOf(rec, "o", prep);
        compare(still.src, key);
        verify(WallpaperConfig.stillMatches(still, key));
        verify(!WallpaperConfig.stillMatches(still, WallpaperConfig.sourceKey({source: "file", path: "/other.jpg"})), "another file");
        verify(!WallpaperConfig.stillMatches(still, WallpaperConfig.sourceKey({source: "video", path: file.path})), "another source");
        verify(!WallpaperConfig.stillMatches(still, WallpaperConfig.sourceKey({source: "builtin", path: file.path})), "the artwork");
        const old = WallpaperConfig.stillOf(WallpaperConfig.withShown({}, "o", pic, {}), "o", prep);
        verify(!WallpaperConfig.stillMatches(old, key), "a record without its setting never matches");
        verify(!WallpaperConfig.stillMatches(null, key));
        const w = text("../../shell/desktop/Wallpaper.qml");
        verify(/Entrance\.settingsFinal \? WallpaperState\.stillOf\(/.test(w) && /WallpaperConfig\.stillMatches\(st, WallpaperConfig\.sourceKey\(feed\.cfg\)\)/.test(w), "only the matching still, once the settings are read");
        verify(/src: WallpaperConfig\.sourceKey\(feed\.cfg\)/.test(w), "the record keeps its setting");
        // The bound does not paint the default artwork while the chosen picture or video is being prepared.
        verify(/WallpaperConfig\.firstFrameStep\("bound", feed\.status, feed\.appliedOnce, win\.firstReady\) === "fallback"/.test(w) && /WallpaperConfig\.firstFrameStep\("status", /.test(w), "the window asks the step");
        // On the bound nothing paints the artwork unless the source failed: the timer neither paints nor releases the bars.
        const timer = /id: firstTimer[\s\S]*?\n            \}\n/.exec(w)[0];
        verify(!/showFirst\(/.test(timer) && !/Entrance\./.test(timer) && (timer.match(/artFallback\(/g) || []).length === 1, "the bound neither paints nor releases the bars (P-3); artFallback only on a failed source");
        verify(/if \(WallpaperConfig\.firstFrameStep\("bound"[^\n]*\) === "fallback"\) \{\s*win\.artFallback\(/.test(timer), "the one artFallback call is behind the failure step");
        // Two outputs never transcode at once (one failed with "write"): they take turns through WallpaperState.transcodeOwner.
        verify(/WallpaperState\.transcodeOwner !== "" && WallpaperState\.transcodeOwner !== root\.outputName/.test(f) && /releaseTranscode\(\);\s*transcoded\(/.test(f), "the transcode takes turns");
        // A file wallpaper prepares: an omitted typed argument arrives as "undefined" (invalid-path, the artwork for good).
        verify(/function startPrepare\(path: string, fit: var, color: var\)/.test(f), "startPrepare takes untyped fit and color");
        verify(/typeof fit === "string" && fit !== "" \? fit : cfg\.fit/.test(f) && /typeof color === "string" && color !== "" \? color : cfg\.color/.test(f));
        // The compositor's ground at the session's start is the last picture's mean, the default's green only without one.
        const lua = text("../../config/hypr/grassfield/looknfeel.lua");
        verify(/wallpaper\.json/.test(lua) && /"ground"%s\*:/.test(lua) && !/io\.open\(home/.test(lua), "the ground key, read behind test -f (tests/shell/session_ground.sh runs it)");
    }

    // The behaviour (pure part of the window's first frame): every phase of a wallpaper that is loading is "wait" on the bound
    // (the entrance goes on over the ground), never "fallback"; only a failed source gives the artwork. The compositor's ground is
    // kept in wallpaper.json.
    function test_firstFrameStepNeverPaintsTheArtworkForALoadingWallpaper() {
        const step = WallpaperConfig.firstFrameStep;
        // The phases: the feed not started, a folder list or a prepare running, a transcode, the online entry not loaded
        // ("builtin"/"waiting" before an answer), a ready feed whose picture is still decoding, a cached video's poster loading.
        for (const status of ["builtin", "color", "preparing", "ready", "waiting"]) {
            for (const applied of [false, true]) {
                compare(step("bound", status, applied, false), "wait", status + " applied " + applied);
                compare(step("status", status, applied, false), "none", status + " applied " + applied);
            }
        }
        // A failure (an error, a missing file, a failed transcode): the artwork, on the status and on the bound.
        compare(step("status", "error", true, false), "fallback");
        compare(step("bound", "error", true, false), "fallback");
        compare(step("status", "error", false, false), "none", "an error before any request is not a source's");
        // Once the first frame is there nothing happens.
        for (const status of ["error", "ready", "preparing"])
            for (const when of ["bound", "status"])
                compare(step(when, status, true, true), "none");
        // The ground the compositor accepted is kept (upper case, valid only), nothing else changes.
        const saved = {displays: {}, shown: {o: {kind: "art"}}, ground: "#a5937f"};
        compare(JSON.parse(WallpaperConfig.stateText(saved, {}, [], 1)).ground, "#A5937F");
        compare(JSON.parse(WallpaperConfig.stateText({displays: {}, ground: "red"}, {}, [], 1)).ground, undefined);
        compare(JSON.parse(WallpaperConfig.stateText(WallpaperConfig.withShown(saved, "p", {kind: "color", color: "#112233"}, {}), {}, [], 1)).ground, "#A5937F", "withShown keeps it");
    }

    // The window needs Quickshell, so its contract is read from the sources (ADR-0040 ID-3, ID-4, ID-16): it maps only with
    // its first frame, bounded by the token; the compositor adds no fade; the journal lines are logged.
    // A file wallpaper prepares when its caller gives only the path (WallpaperFeed.qml's file, folder and keep callers): an
    // omitted argument of a typed `string` parameter arrives as the text "undefined", which no fit accepts (the owner's
    // rc1-18: every photograph said "This path can't be used").
    function test_aFileWallpaperPreparesWithOnlyItsPath() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/desktop/WallpaperFeed.qml"), false);
        xhr.send();
        const f = xhr.responseText;
        verify(f.length > 0);
        verify(/function startPrepare\(path: string, fit: var, color: var\)/.test(f), "startPrepare takes untyped fit and color");
        verify(/typeof fit === "string" && fit !== "" \? fit : cfg\.fit/.test(f) && /typeof color === "string" && color !== "" \? color : cfg\.color/.test(f),
               "an omitted fit or colour falls back to the settings' own");
        verify(/startPrepare\(c\.path\);/.test(f), "the file caller gives only the path");
    }

    function test_aFailureSetsItsReasonBeforeItsStatus() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/desktop/WallpaperFeed.qml"), false);
        xhr.send();
        const f = xhr.responseText;
        const body = f.slice(f.indexOf("function fail(why: string)"));
        verify(body.length > 0, "fail() exists");
        const r = body.indexOf("reason = why;");
        const st = body.indexOf('status = "error";');
        verify(r > 0 && st > 0 && r < st, "the desktop reads the reason when the status turns to error");
    }

    function test_theWindowMapsOnceWithItsFirstFrame() {
        function text(rel) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl(rel), false);
            xhr.send();
            verify(xhr.responseText.length > 0, rel);
            return xhr.responseText;
        }
        const w = text("../../shell/desktop/Wallpaper.qml");
        verify(/visible: win\.firstReady/.test(w));
        verify(/interval: Tokens\.wallpaperFirstShowTimeoutMs/.test(w));
        compare(Tokens.wallpaperFirstShowTimeoutMs, 1500);
        verify(/color: Ground\.of\(/.test(w), "the ground under the wallpaper");
        verify(/Journal\.shown\("wallpaper"/.test(w) && /Journal\.hidden\("wallpaper"/.test(w));
        verify(/WallpaperState\.setShown\(/.test(w) && /WallpaperState\.stillOf\(/.test(w));
        const lua = text("../../config/hypr/grassfield/windows.lua");
        const noAnim = (lua.match(/^hl\.layer_rule\(\{.*no_anim = true.*\}\)$/gm) || []).map(r => /namespace = "([^"]+)"/.exec(r)[1]);
        verify(noAnim.some(p => new RegExp(p).test("grassfield-wallpaper")), "a no_anim layer rule matches the wallpaper");
    }
}
