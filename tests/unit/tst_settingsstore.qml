import QtQuick
import QtTest
import "../../apps/settings/qml/Store.js" as Store
import "../../apps/settings/qml/Bindings.js" as Bindings
import "../../apps/settings/qml/SysInfo.js" as SysInfo

// grassfield-settings logic: JSON merge/validation, ConfigStore refusal of malformed files, parsers.
TestCase {
    id: testCase
    name: "SettingsStore"

    Component {
        id: fakeBackend
        QtObject {
            property string configFile: "/fake/grassfield.json"
            property bool exists: true
            property string text: ""
            property int writes: 0
            signal fileChanged(string path)
            function readText(path: string): var {
                return {exists: exists, ok: exists, text: exists ? text : ""};
            }
            function writeText(path: string, t: string): string {
                text = t;
                exists = true;
                writes++;
                return "";
            }
            function watch(path: string): bool {
                return true;
            }
        }
    }

    function makeStore(initial, exists) {
        const backend = createTemporaryObject(fakeBackend, testCase, {text: initial, exists: exists !== false});
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/ConfigStore.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const store = createTemporaryObject(comp, testCase, {backend: backend});
        verify(store);
        return {backend: backend, store: store};
    }

    function readSchema() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/schema/grassfield.schema.json"), false);
        xhr.send();
        return JSON.parse(xhr.responseText);
    }

    // Dotted paths of every scalar leaf in the schema (arrays such as dock.pinned are leaves).
    function schemaLeaves(node, prefix, out) {
        for (const key in node.properties) {
            const child = node.properties[key];
            const path = prefix === "" ? key : prefix + "." + key;
            if (child.type === "object")
                schemaLeaves(child, path, out);
            else
                out[path] = child;
        }
        return out;
    }

    function test_schemaParity() {
        const leaves = schemaLeaves(readSchema(), "", {});
        // Owned by other modules: version is fixed, dock.pinned and dock.recent belong to the Dock.
        delete leaves["version"];
        delete leaves["dock.pinned"];
        delete leaves["dock.recent"];
        compare(Object.keys(Store.RULES).sort(), Object.keys(leaves).sort());
        compare(Object.keys(Store.DEFAULTS).sort(), Object.keys(leaves).sort());
        for (const path in leaves) {
            const s = leaves[path];
            const r = Store.RULES[path];
            if (s.enum)
                compare(r.values, s.enum, path);
            if (s.minimum !== undefined)
                compare(r.min, s.minimum, path);
            if (s.maximum !== undefined)
                compare(r.max, s.maximum, path);
            compare(r.type === "integer" ? "integer" : r.type === "enum" || r.type === "tint" || r.type === "folderColor" || r.type === "pointerColor" || r.type === "localeName" || r.type === "plainText" || r.type === "nodeName" || r.type === "wallpaperPath" ? "string" : r.type === "wallpaperOutputs" || r.type === "mainDisplays" || r.type === "notificationApps" || r.type === "notificationStyles" || r.type === "pathList" ? "array" : r.type, s.type, path);
            // Defaults satisfy their own rule.
            compare(Store.validate(path, Store.DEFAULTS[path]), "", path);
        }
    }

    function test_defaultsMatchDefaultFile() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/defaults/grassfield.json"), false);
        xhr.send();
        const file = JSON.parse(xhr.responseText);
        for (const path in Store.DEFAULTS)
            compare(Store.read(file, path), Store.DEFAULTS[path], path);
    }

    // Settings > Menu Bar: every key of the pane has the default the shell assumes and refuses a wrong value.
    function test_menuBarPaneKeys() {
        const booleans = ["showWifi", "showSound", "showBattery", "showBatteryPercentage", "showFocus", "showNowPlaying", "showSearch",
            "showBackground", "showTrayItems", "clockShowAmPm", "clockFlashSeparators", "clockShowDayOfWeek", "clockShowSeconds",
            "showScreenCapture"];
        for (const k of booleans) {
            const path = "menubar." + k;
            compare(Store.validate(path, true), "", path);
            verify(Store.validate(path, "yes") !== "", path);
        }
        compare(Store.DEFAULTS["menubar.clockShowSeconds"], false);
        compare(Store.DEFAULTS["menubar.showScreenCapture"], false, "the Screen Capture item is off by default");
        compare(Store.DEFAULTS["menubar.clockDate"], "auto");
        compare(Store.DEFAULTS["menubar.recentItems"], 10);
        for (const m of ["auto", "always", "never"])
            compare(Store.validate("menubar.clockDate", m), "");
        verify(Store.validate("menubar.clockDate", "sometimes") !== "");
        compare(Store.validate("menubar.recentItems", 0), "");
        compare(Store.validate("menubar.recentItems", 50), "");
        verify(Store.validate("menubar.recentItems", 51) !== "");
        compare(Store.DEFAULTS["menubar.clockHours"], "auto");
        for (const m of ["auto", "12", "24"])
            compare(Store.validate("menubar.clockHours", m), "");
        verify(Store.validate("menubar.clockHours", "36") !== "");
        compare(Store.DEFAULTS["keyboard.shortcutStyle"], "automatic");
        for (const m of ["automatic", "mac", "pc"])
            compare(Store.validate("keyboard.shortcutStyle", m), "");
        verify(Store.validate("keyboard.shortcutStyle", "windows") !== "");
        compare(Store.DEFAULTS["region.formats"], "auto");
        for (const m of ["auto", "fr_CH", "en_GB", "es_419", "sr_Latn_RS"])
            compare(Store.validate("region.formats", m), "");
        for (const m of ["", "fr", "fr-CH", "fr_CH.UTF-8", "fr_CH\n", "../x", "FR_ch"])
            verify(Store.validate("region.formats", m) !== "");
        compare(Store.DEFAULTS["region.firstDayOfWeek"], "auto");
        compare(Store.validate("region.firstDayOfWeek", "monday"), "");
        verify(Store.validate("region.firstDayOfWeek", "lundi") !== "");
        for (const m of ["always", "desktop", "fullscreen", "never"])
            compare(Store.validate("menubar.autoHide", m), "");
        verify(Store.validate("menubar.autoHide", "sometimes") !== "");
    }

    function test_validateDockFolders() {
        compare(Store.validate("dock.folders", ["~/Downloads", "/srv/x"]), "");
        compare(Store.validate("dock.folders", []), "");
        verify(Store.validate("dock.folders", "~/Downloads") !== "");
        verify(Store.validate("dock.folders", ["relative"]) !== "");
        verify(Store.validate("dock.folders", ["/a/../b"]) !== "");
        verify(Store.validate("dock.folders", [""]) !== "");
        verify(Store.validate("dock.folders", [5]) !== "");
        verify(Store.validate("dock.folders", ["/a\nb"]) !== "");
        verify(Store.validate("dock.folders", Array(13).fill("/a")) !== "");
    }

    function test_validate() {
        compare(Store.validate("material.transparency", 0.5), "");
        verify(Store.validate("material.transparency", 1.5) !== "");
        verify(Store.validate("material.transparency", "0.5") !== "");
        verify(Store.validate("material.transparency", NaN) !== "");
        verify(Store.validate("lock.idleMinutes", 2.5) !== "");
        verify(Store.validate("lock.idleMinutes", 241) !== "");
        compare(Store.validate("lock.idleMinutes", 0), "");
        verify(Store.validate("hotCorners.topLeft", "reboot") !== "");
        verify(Store.validate("dock.autohide", "yes") !== "");
        verify(Store.validate("dock.pinned", ["x"]) !== "", "keys outside RULES are refused");
        verify(Store.validate("bogus.key", 1) !== "");
    }

    // Wallpaper rules (ADR-0016): the Settings store accepts what ui/Grassfield/Ui/WallpaperConfig.js accepts.
    // (Kept here, not in tst_wallpaper: a test file that imports Grassfield.Ui itself makes Store.js resolve a second,
    // possibly older installed copy of the module for its own .import.)
    function test_wallpaperRuleCases() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("fixtures/wallpaper-rules.json"), false);
        xhr.send();
        const cases = JSON.parse(xhr.responseText);
        for (const c of cases.paths) {
            // The store also accepts "" (no path): the other cases are the module's.
            compare(Store.validate("wallpaper.path", c[0]) === "", c[1] === "" || c[0] === "", JSON.stringify(c[0]).substring(0, 60));
        }
        for (const c of cases.outputs)
            compare(Store.validate("wallpaper.outputs", c[0]) === "", c[1], JSON.stringify(c[0]).substring(0, 100));
    }

    function test_setValuesWritesAllKeysAtOnce() {
        const r = Store.setValues('{"version":1,"wallpaper":{"fit":"tile"},"dock":{"autohide":true}}', {"wallpaper.source": "folder", "wallpaper.path": "/p"});
        verify(r.ok, r.error);
        compare(JSON.parse(r.text), {version: 1, wallpaper: {fit: "tile", source: "folder", path: "/p"}, dock: {autohide: true}});
        // One bad value: nothing is written.
        const bad = Store.setValues('{"version":1}', {"wallpaper.source": "folder", "wallpaper.path": "relative"});
        verify(!bad.ok);
        verify(!Store.setValues('{"version":1}', {"wallpaper.nope": 1}).ok);
        compare(JSON.parse(Store.setValues("", {"wallpaper.source": "color", "wallpaper.color": "#112233"}).text), {version: 1, wallpaper: {source: "color", color: "#112233"}});
        verify(!Store.setValues("{", {"wallpaper.source": "color"}).ok, "a malformed file is refused");
    }

    function test_wallpaperRules() {
        compare(Store.validate("wallpaper.source", "folder"), "");
        compare(Store.validate("wallpaper.source", "online"), "");
        verify(Store.validate("wallpaper.source", "apod") !== "");
        compare(Store.validate("wallpaper.online.provider", "commons"), "");
        compare(Store.validate("wallpaper.online.provider", "apod"), "");
        verify(Store.validate("wallpaper.online.provider", "nasa") !== "");
        verify(Store.validate("wallpaper.online.provider", 1) !== "");
        compare(Store.read({wallpaper: {online: {provider: "commons"}}}, "wallpaper.online.provider"), "commons");
        compare(Store.read({wallpaper: {online: "x"}}, "wallpaper.online.provider"), "commons");
        const on = Store.setValues('{"version":1,"wallpaper":{"fit":"tile"}}', {"wallpaper.source": "online", "wallpaper.online.provider": "commons"});
        verify(on.ok, on.error);
        compare(JSON.parse(on.text).wallpaper, {fit: "tile", source: "online", online: {provider: "commons"}});
        compare(Store.validate("wallpaper.path", ""), "");
        compare(Store.validate("wallpaper.path", "/a/b"), "");
        verify(Store.validate("wallpaper.path", "a/b") !== "");
        verify(Store.validate("wallpaper.path", "/a\nb") !== "");
        verify(Store.validate("wallpaper.path", 5) !== "");
        compare(Store.validate("wallpaper.fit", "tile"), "");
        verify(Store.validate("wallpaper.interval", "2s") !== "");
        compare(Store.validate("wallpaper.outputs", []), "");
        verify(Store.validate("wallpaper.outputs", [{}]) !== "");
        compare(Store.validate("wallpaper.shuffle", false), "");
        verify(Store.validate("wallpaper.videoOnBattery", "no") !== "");
        const r = Store.setValue('{"version":1,"wallpaper":{"fit":"tile"}}', "wallpaper.source", "color");
        verify(r.ok, r.error);
        compare(JSON.parse(r.text).wallpaper, {fit: "tile", source: "color"});
    }

    function test_setValuePreservesOtherKeys() {
        const before = {version: 1, appearance: "dark", dock: {pinned: ["foot", "x"], magnification: 1.6}, extra: {a: [1, 2]}};
        const r = Store.setValue(JSON.stringify(before), "dock.autohide", true);
        verify(r.ok, r.error);
        const after = JSON.parse(r.text);
        compare(after.dock.autohide, true);
        compare(after.dock.pinned, ["foot", "x"]);
        compare(after.dock.magnification, 1.6);
        compare(after.extra, {a: [1, 2]});
        compare(after.appearance, "dark");
        verify(r.text.endsWith("\n"));
    }

    function test_setValueCreatesNestedObjects() {
        const r = Store.setValue('{"version":1}', "hotCorners.topRight", "apps");
        verify(r.ok, r.error);
        compare(JSON.parse(r.text), {version: 1, hotCorners: {topRight: "apps"}});
    }

    function test_freshFileGetsVersion() {
        for (const empty of ["", "  \n", null, undefined]) {
            const r = Store.setValue(empty, "appearance", "light");
            verify(r.ok, r.error);
            compare(JSON.parse(r.text), {version: 1, appearance: "light"});
        }
    }

    function test_malformedFileIsRefused() {
        for (const bad of ["{", "[1]", "null", "42", '{"version":1,}', "not json"]) {
            const r = Store.setValue(bad, "appearance", "light");
            verify(!r.ok, bad);
            verify(r.error !== "", bad);
            compare(r.text, "");
        }
        verify(!Store.setValue('{"version":2}', "appearance", "light").ok);
        verify(!Store.setValue('{"appearance":"dark"}', "appearance", "light").ok, "missing version in a non-empty file");
    }

    function test_unsafeFileIsRefused() {
        const cases = [
            '{"version":1,"x":9007199254740993}',
            '{"version":1,"x":-12345678901234567}',
            '{"version":1,"appearance":"dark","appearance":"light"}',
            '{"version":1,"a":{"k":1,"k":2}}',
            '{"version":1,"7":true}',
            '{"version":1,"x":9007199254740993.0}',
            '{"version":1,"x":9.007199254740993e15}',
            '{"version":1,"x":-9007199254740993E0}',
            '{"version":1,"x":90071992547409930e-1}',
            '{"version":1,"__proto__":1,"__proto__":2}',
            '{"version":1,"a":{"__proto__":{},"__proto__":{}}}'
        ];
        for (const bad of cases) {
            const r = Store.setValue(bad, "appearance", "light");
            verify(!r.ok, bad);
            verify(r.error.indexOf("cannot be edited safely") >= 0, bad);
        }
        // Safe look-alikes: big numbers and repeated keys inside strings, same key in sibling objects, 2^53-1.
        for (const good of [
            '{"version":1,"s":"9007199254740993 \\" {\\"k\\":1,\\"k\\":2}"}',
            '{"version":1,"a":{"k":1},"b":{"k":2}}',
            '{"version":1,"x":9007199254740991,"y":1.5e30}',
            '{"version":1,"x":9007199254740991.0,"y":9.007199254740991e15,"z":1e3,"w":0.0}',
            '{"version":1,"__proto__":{"a":1}}',
            '{"version":1,"a":{"__proto__":1},"b":{"__proto__":2}}'
        ])
            verify(Store.setValue(good, "appearance", "light").ok, good);
    }

    function test_invalidValueIsRefused() {
        const r = Store.setValue('{"version":1}', "material.transparency", 7);
        verify(!r.ok);
        compare(r.text, "");
    }

    function test_readClampsAndFallsBackToDefaults() {
        const data = {version: 1, material: {transparency: 9, profile: "full"}, lock: "oops"};
        // An out-of-range number is clamped, as the shell reads it (ADR-0020, tests/fixtures/settings-vectors.json).
        compare(Store.read(data, "material.transparency"), 1);
        compare(Store.read({material: {transparency: "x"}}, "material.transparency"), 0.25);
        compare(Store.read(data, "material.profile"), "full");
        compare(Store.read(data, "lock.idleMinutes"), 5);
        compare(Store.read({}, "hotCorners.topLeft"), "none");
    }

    function test_storeMergesAndWrites() {
        const t = makeStore('{"version":1,"dock":{"pinned":["foot"]},"keep":true}');
        compare(t.store.blocked, false);
        verify(t.store.set("material.transparency", 0.6));
        compare(t.backend.writes, 1);
        compare(t.store.value("material.transparency"), 0.6);
        const written = JSON.parse(t.backend.text);
        compare(written.keep, true);
        compare(written.dock.pinned, ["foot"]);
    }

    function test_storePicksUpExternalChange() {
        const t = makeStore('{"version":1}');
        compare(t.store.value("dock.autohide"), false);
        t.backend.text = '{"version":1,"dock":{"autohide":true}}';
        t.backend.fileChanged("/fake/grassfield.json");
        compare(t.store.value("dock.autohide"), true);
    }

    function test_storeNeverWritesMalformedFile() {
        const bad = '{"version":1,';
        const t = makeStore(bad);
        compare(t.store.blocked, true);
        verify(t.store.error !== "");
        verify(!t.store.set("appearance", "light"));
        compare(t.backend.writes, 0);
        compare(t.backend.text, bad);
        // The user fixes the file: writes work again.
        t.backend.text = '{"version":1}';
        t.backend.fileChanged("/fake/grassfield.json");
        compare(t.store.blocked, false);
        verify(t.store.set("appearance", "light"));
    }

    function test_storeCreatesMissingFile() {
        const t = makeStore("", false);
        compare(t.store.blocked, false);
        compare(t.store.value("appearance"), "dark");
        verify(t.store.set("appearance", "light"));
        compare(JSON.parse(t.backend.text), {version: 1, appearance: "light"});
    }

    function test_bindingsParse() {
        const lua = [
            '-- comment bind("A", "no", x)',
            'bind("SUPER + Q", "Close window", hl.dsp.window.close())',
            'bind("SUPER + W", "Close window", hl.dsp.window.close())',
            'bind("SUPER + W", "Close window", hl.dsp.window.close())',
            'bind("ALT + TAB", "Next window", a)',
            'bind("SUPER + mouse:272", "Move window", b, { mouse = true })',
            'bind("CTRL + code:" .. tostring(space + 9), "Switch to Space " .. space, c)',
            'bind("XF86AudioMute", "Mute", d)',
            'bind("SUPER + CTRL + F", "Say \\"hi\\"", e)',
            'local x = 1'
        ].join("\n");
        const list = Bindings.parse(lua);
        compare(list.length, 6);
        compare(list[0], {keys: "Super + Q", description: "Close window"});
        compare(list[1].keys, "Super + W");
        compare(list[2], {keys: "Alt + Tab", description: "Next window"});
        compare(list[3].keys, "Super + Left Mouse Button");
        compare(list[4], {keys: "XF86AudioMute", description: "Mute"});
        compare(list[5], {keys: "Super + Ctrl + F", description: 'Say "hi"'});
    }

    function test_bindingsParseRealFile() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/hypr/grassfield/bindings.lua"), false);
        xhr.send();
        const list = Bindings.parse(xhr.responseText);
        verify(list.length > 20, "found " + list.length);
        verify(list.some(b => b.keys === "Super + Space" && b.description === "Search"));
        // The app switcher shortcuts are literal bind lines (the Keyboard page shows them); the key above Tab is bound by
        // keycode (AZERTY) and shown under a layout-independent name.
        verify(list.some(b => b.keys === "Super + Tab" && b.description === "Switch application"));
        verify(list.some(b => b.keys === "Super + Shift + Tab" && b.description === "Switch to the previous application"));
        verify(list.some(b => b.keys === "Super + Key above Tab" && b.description === "Next window of the application"));
    }

    // Every literal description and key name of the real bindings file is listed for translation (Keyboard page).
    function test_bindingsTranslatable() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/hypr/grassfield/bindings.lua"), false);
        xhr.send();
        let text = xhr.responseText;
        // The keys forwarded to the application (forwarding.lua) are listed on the same page.
        xhr.open("GET", Qt.resolvedUrl("../../config/hypr/grassfield/forwarding.lua"), false);
        xhr.send();
        text += "\n" + xhr.responseText;
        const list = Bindings.parse(text);
        verify(list.some(b => b.keys === "Alt + Left" && b.description === "Previous word"), "word_key lines are parsed");
        verify(list.some(b => b.keys === "Super + [" && b.description === "Back"));
        verify(list.some(b => b.keys === "Super + Backspace" && b.description === "Delete to the beginning of the line"));
        const names = Object.keys(Bindings.NAMES).map(k => Bindings.NAMES[k]);
        for (const b of list) {
            verify(Bindings.DESCRIPTIONS.indexOf(b.description) >= 0, "not listed in Bindings.DESCRIPTIONS: " + b.description);
            for (const key of b.keys.split(" + ")) {
                const named = names.indexOf(key) >= 0;
                verify(named || /^([A-Z0-9]|F[0-9]+|XF86\w+|code:\d+)$/.test(key), "key without a translatable name: " + key);
            }
        }
        compare(Bindings.translateKeys("Super + Shift + Q", k => k === "Shift" ? "Maj" : k), "Super + Maj + Q");
        // Internal feature names of the file are shown under their UI names (renamed 2026-10-18).
        compare(Bindings.uiName("Next Space"), "Next Desktop");
        compare(Bindings.uiName("Previous Space"), "Previous Desktop");
        compare(Bindings.uiName("Notification Center"), "Notifications");
        compare(Bindings.uiName("Search"), "Search");
    }

    function test_sysInfo() {
        const os = 'NAME="Omarchy"\nVERSION_ID="4.0.4"\nID=omarchy\n';
        compare(SysInfo.osReleaseValue(os, "ID"), "omarchy");
        compare(SysInfo.osLabel(os), "Omarchy 4.0.4");
        compare(SysInfo.osLabel(""), "");
        compare(SysInfo.cpu("processor\t: 0\nmodel name\t: AMD  Ryzen 7\nprocessor\t: 1\nmodel name\t: AMD Ryzen 7\n"), {model: "AMD Ryzen 7", threads: 2});
        compare(SysInfo.cpu(""), {model: "", threads: 0});
        // About This Computer's processor name on one line (integrator nested pass of 85c2c10).
        compare(SysInfo.cpuShortName("11th Gen Intel(R) Core(TM) i7-1165G7 @ 2.80GHz"), "Intel Core i7-1165G7");
        compare(SysInfo.cpuShortName("13th Gen Intel(R) Core(TM) i5-1340P"), "Intel Core i5-1340P");
        compare(SysInfo.cpuShortName("Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz"), "Intel Core i7-8550U");
        compare(SysInfo.cpuShortName("Intel(R) Core(TM) Ultra 7 155H"), "Intel Core Ultra 7 155H");
        compare(SysInfo.cpuShortName("Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz"), "Intel Xeon E5-2680 v4");
        compare(SysInfo.cpuShortName("AMD Ryzen 7 5800H with Radeon Graphics"), "AMD Ryzen 7 5800H");
        compare(SysInfo.cpuShortName("AMD Ryzen 7 PRO 7840U w/ Radeon 780M Graphics"), "AMD Ryzen 7 PRO 7840U");
        compare(SysInfo.cpuShortName("AMD Ryzen 9 7950X 16-Core Processor"), "AMD Ryzen 9 7950X");
        compare(SysInfo.cpuShortName("AMD Phenom(tm) II X4 965 Processor"), "AMD Phenom II X4 965");
        compare(SysInfo.cpuShortName("AMD Ryzen 7 7840U"), "AMD Ryzen 7 7840U", "nothing to drop");
        compare(SysInfo.cpuShortName("  AMD   Ryzen 7  "), "AMD Ryzen 7");
        compare(SysInfo.cpuShortName("CPU"), "CPU", "nothing would be left: the model name");
        compare(SysInfo.memoryBytes("MemTotal:       16384000 kB\nMemFree: 1 kB\n"), 16384000 * 1024);
        compare(SysInfo.memoryBytes(""), 0);
        // The About page formats the bytes with the UI locale: localized digits and binary unit names.
        compare(Qt.locale("fr_FR").formattedDataSize(SysInfo.memoryBytes("MemTotal: 32555000 kB\n"), 1, Locale.DataSizeIecFormat), "31,0 Gio");
        compare(Qt.locale("en_US").formattedDataSize(SysInfo.memoryBytes("MemTotal: 32555000 kB\n"), 1, Locale.DataSizeIecFormat), "31.0 GiB");
        const pci = "00:02.0 VGA compatible controller: Intel Corporation Iris Xe (rev 0c)\n00:1f.3 Audio device: Intel Audio\n01:00.0 3D controller: NVIDIA Corp GA107\n";
        compare(SysInfo.gpus(pci), "Intel Iris Xe; NVIDIA Corp GA107");
        compare(SysInfo.gpus(""), "");
        // The marketing name: the vendor's short name, then the last brackets.
        compare(SysInfo.gpuName("Intel Corporation Raptor Lake-P [Iris Xe Graphics]"), "Intel Iris Xe Graphics");
        compare(SysInfo.gpuName("NVIDIA Corporation AD107M [GeForce RTX 4060 Max-Q / Mobile]"), "NVIDIA GeForce RTX 4060 Max-Q / Mobile");
        compare(SysInfo.gpuName("Advanced Micro Devices, Inc. [AMD/ATI] Phoenix1"), "AMD Phoenix1");
        compare(SysInfo.gpuName("Advanced Micro Devices, Inc. [AMD/ATI] Navi 33 [Radeon RX 7600]"), "AMD Radeon RX 7600");
        compare(SysInfo.gpuName("Some Vendor Chip"), "Some Vendor Chip");
        // The installed memory, as sold, from MemTotal.
        compare(SysInfo.installedGiB(SysInfo.memoryBytes("MemTotal: 32555000 kB\n")), 32);
        compare(SysInfo.installedGiB(15.4 * 1073741824), 16);
        compare(SysInfo.installedGiB(11.6 * 1073741824), 12);
        compare(SysInfo.installedGiB(7.6 * 1073741824), 8);
        compare(SysInfo.installedGiB(0), 0);
        compare(SysInfo.pacmanVersion("hyprland 0.56.2-1\n"), "0.56.2-1");
        compare(SysInfo.pacmanVersion(""), "");
    }
}
