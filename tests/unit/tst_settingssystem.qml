import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/System.js" as System
import "../../apps/settings/qml" as SettingsQml

// Settings system sections (Wi-Fi, Bluetooth, Sound, Displays): the parsers of the D-Bus states and of wpctl's output, the
// D-Bus action maps and wpctl argument vectors, arrangement, and the dev guard of SystemService (an action never reaches the
// backend with GRASSFIELD_DEV=1).
TestCase {
    id: testCase
    name: "SettingsSystem"
    width: 700
    height: 900
    // Shown, so that a sheet is visible once it opens.
    visible: true
    when: windowShown

    Component {
        id: modelComp
        ListModel {}
    }

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property var queries: []
            property var actions: []
            property var busQueries: []
            property var busActions: []
            // Files readText answers with (the Network pane reads /etc/ufw/ufw.conf).
            property var files: ({})
            signal finished(string tag, bool ok, string output)
            function readText(path: string): var {
                return {exists: files[path] !== undefined, ok: true, text: files[path] ?? ""};
            }
            signal failed(string tag, string reason)
            function query(argv: var, tag: string): void {
                queries.push(argv);
            }
            function act(what: string, argv: var, tag: string): bool {
                actions.push({what: what, argv: argv});
                return true;
            }
            function busQuery(what: string, tag: string): void {
                busQueries.push({what: what, tag: tag});
            }
            function busAct(what: string, op: var, tag: string): bool {
                busActions.push({what: what, op: op});
                return true;
            }
        }
    }

    function makeService(dev) {
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: dev});
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/SystemService.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const service = createTemporaryObject(comp, testCase, {backend: backend});
        verify(service);
        return {backend: backend, service: service};
    }

    readonly property string uuidA: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"

    // ---- guard ----

    function test_devGuardSuppressesEveryAction() {
        const t = makeService(true);
        verify(t.service.dev);
        const actions = [
            ["wifi off", System.wifiRadio(false)],
            ["wifi connect", System.wifiConnectKnown(uuidA)],
            ["wifi connect", System.wifiConnectOpen("Cafe")],
            ["wifi disconnect", System.wifiDisconnect("wlo1")],
            ["wifi scan", System.wifiScan()],
            ["bluetooth off", System.btPower(false)],
            ["bluetooth connect", System.btConnect("AA:BB:CC:DD:EE:FF", true)],
            ["output device", System.setDefaultDevice(52)],
            ["volume", System.setVolume(52, 0.5)],
            ["mute", System.setMute(52, true)]
        ];
        for (const a of actions) {
            verify(a[1] !== null, a[0]);
            compare(t.service.act(a[0], a[1], "x"), false, a[0]);
        }
        compare(t.backend.actions.length, 0);
        compare(t.backend.busActions.length, 0);
        verify(t.service.suppressedNote);
    }

    function test_realSessionPassesActionsThrough() {
        const t = makeService(false);
        verify(!t.service.dev);
        // Wi-Fi and Bluetooth go to the D-Bus door as maps, Sound to the wpctl door as an argv.
        compare(t.service.act("wifi off", System.wifiRadio(false), "x"), true);
        compare(t.backend.busActions.length, 1);
        compare(t.backend.busActions[0].op, {op: "wifi.radio", on: false});
        compare(t.backend.actions.length, 0);
        compare(t.service.act("mute", System.setMute(52, true), "x"), true);
        compare(t.backend.actions.length, 1);
        compare(t.backend.actions[0].argv, ["wpctl", "set-mute", "52", "1"]);
        verify(!t.service.suppressedNote);
    }

    function test_invalidActionNeverRuns() {
        const t = makeService(false);
        compare(t.service.act("x", null, "x"), false);
        compare(t.backend.actions.length + t.backend.busActions.length, 0);
    }

    function test_queriesPass() {
        const t = makeService(true);
        t.service.queryBus("wifi.state", "wifi.state");
        compare(t.backend.busQueries.length, 1);
        t.service.query(System.QUERY.audio, "audio.status");
        compare(t.backend.queries.length, 1);
        // No command is left that reads the network or Bluetooth: Sound's two are all.
        compare(Object.keys(System.QUERY), ["audio", "audioNames"]);
        compare(System.QUERY.audioNames, ["wpctl", "status", "-n"]);
    }

    // ---- actions ----

    function test_actionsRejectInvalidValues() {
        compare(System.wifiConnectKnown("-x"), null);
        compare(System.wifiConnectKnown("Home"), null);
        compare(System.wifiConnectOpen(""), null);
        compare(System.wifiConnectOpen("a\nb"), null);
        compare(System.wifiConnectOpen("-flag"), null);
        compare(System.wifiConnectOpen("x".repeat(33)), null);
        compare(System.wifiDisconnect("wlo1; reboot"), null);
        compare(System.wifiDisconnect("-h"), null);
        compare(System.btConnect("not-a-mac", true), null);
        compare(System.btConnect("AA:BB:CC:DD:EE:FF; ls", true), null);
        compare(System.setDefaultDevice("52"), null);
        compare(System.setDefaultDevice(-1), null);
        compare(System.setVolume(52, NaN), null);
        compare(System.setMute(1.5, true), null);
    }

    function test_actionShapes() {
        compare(System.wifiRadio(true), {op: "wifi.radio", on: true});
        compare(System.wifiRadio("yes"), {op: "wifi.radio", on: false});
        compare(System.wifiConnectKnown(uuidA), {op: "wifi.connectKnown", uuid: uuidA});
        compare(System.wifiConnectOpen("Cafe"), {op: "wifi.connectOpen", hex: "43616665"});
        compare(System.wifiConnectOpen("x".repeat(32)).hex.length, 64);
        compare(System.wifiDisconnect("wlo1"), {op: "wifi.disconnect"});
        compare(System.wifiScan(), {op: "wifi.scan"});
        compare(System.btPower(false), {op: "bt.power", on: false});
        compare(System.btConnect("aa:bb:cc:dd:ee:ff", false), {op: "bt.connect", mac: "AA:BB:CC:DD:EE:FF", connect: false});
        compare(System.setVolume(52, 1.7), ["wpctl", "set-volume", "52", "1.00"]);
        compare(System.setVolume(52, -1), ["wpctl", "set-volume", "52", "0.00"]);
        compare(System.setMute(52, false), ["wpctl", "set-mute", "52", "0"]);
        compare(System.setDefaultDevice(52), ["wpctl", "set-default", "52"]);
    }

    // ---- Wi-Fi ----

    // The `wifi.state` JSON the Backend answers with (src/systembus.cpp wifiState): SSID bytes as hex, NetworkManager's flags.
    function ap(hex, strength, flags, wpa, rsn, active) {
        return {hex: hex, strength: strength, flags: flags, wpa: wpa, rsn: rsn, active: active === true};
    }

    function wifiJson(aps, profiles, radio, device) {
        return JSON.stringify({radio: radio !== false, device: device === undefined ? {name: "wlo1", connected: true} : device, aps: aps, profiles: profiles ?? []});
    }

    readonly property var homeAp: ap("486F6D653A203547", 72, 1, 0, 0x188, true)

    function test_wifiSecurityLabels() {
        compare(System.wifiSecurity(0, 0, 0), "");
        compare(System.wifiSecurity(1, 0, 0), "WEP");
        compare(System.wifiSecurity(1, 0x100, 0), "WPA1");
        compare(System.wifiSecurity(1, 0, 0x188), "WPA2");          // PSK
        compare(System.wifiSecurity(1, 0, 0x500), "WPA3 WPA2");     // SAE and PSK (transition)
        compare(System.wifiSecurity(1, 0, 0x400), "WPA3");
        compare(System.wifiSecurity(1, 0, 0x200), "802.1X");
        compare(System.wifiSecurity(1, 0, 0x300), "WPA2 802.1X");
        compare(System.wifiSecurity(0, 0, 0x800), "OWE");
        compare(System.wifiSecurity(1, 0, 0x1), "WPA");            // encrypted, key management unknown: still secured
        compare(System.wifiSecurity(0, 0, 0x1000), "");            // OWE transition: the open side, no credentials
        compare(System.wifiSecurity(1, 0, 0x1000), "");            // ... also with the privacy flag set
        compare(System.wifiSecurity(1, 0, 0x1008), "WPA");         // a cipher next to it: secured, as the join rule says
        compare(System.wifiSecurity(1, 0, 0), "WEP");              // privacy flag and nothing else
    }

    function test_wifiState() {
        const aps = [homeAp, ap("486F6D653A203547", 40, 1, 0, 0x188), ap("43616665", 55, 0, 0, 0), ap("4F6666696365", 90, 1, 0, 0x300), ap("", 30, 1, 0, 0x188), ap("5765616B", 12, 1, 0, 0x400)];
        const st = System.parseWifiState(wifiJson(aps, [{uuid: uuidA, hex: "486f6d653a203547"}, {uuid: "11111111-2222-3333-4444-555555555555", hex: "486F6D653A203547"}]));
        compare(st.radio, true);
        compare(st.device, {name: "wlo1", connected: true});
        const list = st.networks;
        compare(list.map(n => n.ssid), ["Home: 5G", "Office", "Cafe", "Weak"]);
        compare(list[0].active, true);
        compare(list[0].strength, 72);
        compare(list[0].key, "486F6D653A203547|WPA2");
        compare(list[1].enterprise, true);
        compare(list[2].secured, false);
        compare(list[3].secured, true);
        verify(list[0].valid);
        // The first saved profile of an SSID is the one a click on the network uses.
        compare(st.known["486F6D653A203547"], uuidA);
    }

    function test_wifiEnhancedOpenNeedsNoPassword() {
        // OWE (Enhanced Open) joins without a password, like an open network: no lock, click kind "open"; OWE with SAE or PSK is secured.
        const list = System.parseWifiState(wifiJson([ap("4F7765", 50, 1, 0, 0x888), ap("4F7765", 20, 1, 0, 0xC88), ap("4D6978", 40, 1, 0, 0xD88)])).networks;
        const owe = list.find(n => n.ssid === "Owe" && n.security === "OWE");
        verify(owe !== undefined);
        compare(owe.secured, false);
        compare(owe.enterprise, false);
        compare(System.wifiClickKind({hex: owe.hex, active: false, secured: owe.secured}, {}), "open");
        compare(list.find(n => n.ssid === "Owe" && n.security !== "OWE").secured, true);
        compare(list.find(n => n.ssid === "Mix").secured, true);
    }

    function test_wifiOweTransitionIsOpen() {
        const list = System.parseWifiState(wifiJson([ap("4F7765", 50, 0, 0, 0x1000), ap("4F776D", 40, 1, 0, 0x1000)])).networks;
        compare(list.length, 2);
        for (const n of list) {
            compare(n.secured, false);
            compare(System.wifiClickKind({hex: n.hex, active: false, secured: n.secured}, {}), "open");
        }
    }

    function test_wifiDuplicateKeepsStrongest() {
        const list = System.parseWifiState(wifiJson([ap("4E6574", 30, 1, 0, 0x188), ap("4E6574", 80, 1, 0, 0x188)])).networks;
        compare(list.length, 1);
        compare(list[0].strength, 80);
        // Same name, other security: another row, another stable id.
        compare(System.parseWifiState(wifiJson([ap("4E6574", 30, 1, 0, 0x188), ap("4E6574", 80, 0, 0, 0)])).networks.length, 2);
        // The connected access point wins over a stronger one of the same network.
        const active = System.parseWifiState(wifiJson([ap("4E6574", 30, 1, 0, 0x188, true), ap("4E6574", 80, 1, 0, 0x188)])).networks;
        compare(active.length, 1);
        compare(active[0].active, true);
    }

    // A network name may hold any byte: newline, colon, backslash. It is only ever read from hex, so it can neither
    // add a row nor shift a field.
    function test_wifiHostileName() {
        // "a\nb:c\\d" then a decoy that would be a second row if the name were printed raw.
        const list = System.parseWifiState(wifiJson([ap("610A623A635C64", 50, 1, 0, 0x188), ap("4F6666696365", 10, 0, 0, 0)])).networks;
        compare(list.length, 2);
        compare(list[0].ssid, "a\nb:c\\d");
        compare(list[0].label, "a\uFFFDb:c\\d");
        compare(list[0].valid, false);
        compare(list[0].strength, 50);
        compare(list[0].secured, true);
        compare(list[1].ssid, "Office");
        compare(System.parseWifiState(wifiJson([ap("ZZ", 50, 1, 0, 0x188)])).networks.length, 0);
        compare(System.parseWifiState(wifiJson([ap("4", 50, 1, 0, 0x188)])).networks.length, 0);
        // Invalid UTF-8 shows as replacement characters and can never be passed on.
        const bad = System.parseWifiState(wifiJson([ap("FF4142", 50, 1, 0, 0x188)])).networks;
        compare(bad[0].ssid, "\uFFFDAB");
        compare(bad[0].valid, false);
        compare(System.wifiConnectOpen(bad[0].ssid), null);
        compare(System.hexToText("E282AC").text, "€");
        compare(System.hexToText("F09F9882").text, "😂");
        compare(System.hexToText("C0AF").valid, false);
        compare(System.textToHex("a\nb:c\\d€"), "610A623A635C64E282AC");
    }

    function test_wifiStateGarbageAndRadio() {
        compare(System.parseWifiState(""), null);
        compare(System.parseWifiState("not json"), null);
        compare(System.parseWifiState("[]"), null);
        compare(System.parseWifiState('{"radio": "yes", "aps": [], "profiles": []}'), null);
        compare(System.parseWifiState('{"radio": true}'), null);
        // Entries that are not what they should be are skipped, never thrown on.
        const st = System.parseWifiState('{"radio": false, "device": null, "aps": [null, 5, {"hex": 7}, {"hex": "4E6574", "strength": 999, "flags": 0, "wpa": 0, "rsn": 0}], "profiles": [null, {"uuid": "x", "hex": "AA"}, {"uuid": "' + uuidA + '", "hex": "4E6574"}]}');
        compare(st.radio, false);
        compare(st.device, null);
        compare(st.networks.length, 1);
        compare(st.networks[0].strength, 100);
        compare(st.known, {"4E6574": uuidA});
    }

    function test_wifiClickKind() {
        // The known networks match by the profile's SSID, whatever the profile is called.
        const known = {};
        known[System.textToHex("Home")] = uuidA;
        const home = System.parseWifiState(wifiJson([ap(System.textToHex("Home"), 50, 1, 0, 0x188)])).networks[0];
        compare(System.wifiClickKind(home, known), "known");
        compare(System.wifiClickKind({hex: System.textToHex("Home"), active: true, secured: true}, known), "current");
        compare(System.wifiClickKind({hex: "43616665", active: false, secured: false}, known), "open");
        compare(System.wifiClickKind({hex: "4F74686572", active: false, secured: true, security: "WPA2", enterprise: false}, known), "password");
        compare(System.wifiGlyph(90), "wifi-3");
        compare(System.wifiGlyph(40), "wifi-2");
        compare(System.wifiGlyph(5), "wifi-1");
    }

    // ---- Bluetooth ----

    function test_bluetooth() {
        const st = System.parseBtState('{"present": true, "powered": true, "devices": [{"mac": "11:22:33:44:55:66", "name": "Headphones", "connected": false}, {"mac": "77:88:99:aa:bb:cc", "name": "Zed", "connected": true}, {"mac": "bad", "name": "x", "connected": true}, {"mac": "AA:AA:AA:AA:AA:AA", "name": "  ", "connected": false}]}');
        compare(st.present, true);
        compare(st.powered, true);
        // Connected first, then by name; a bad address is dropped; no name shows the address.
        compare(st.devices.map(d => d.name), ["Zed", "AA:AA:AA:AA:AA:AA", "Headphones"]);
        compare(st.devices[0].mac, "77:88:99:AA:BB:CC");
        compare(st.devices[0].connected, true);
        // An adapter that is not there is never "powered".
        compare(System.parseBtState('{"present": false, "powered": true, "devices": []}').powered, false);
        compare(System.parseBtState(""), null);
        compare(System.parseBtState("{}"), null);
        compare(System.parseBtState('{"present": true, "powered": true}'), null);
    }

    // ---- Sound ----

    readonly property string wpctlStatus: "PipeWire 'pipewire-0' [1.2.7, user@host, cpu:0/0]\n" + " └─ Clients:\n" + "        33. WirePlumber                         [1.2.7, user@host, pid:1]\n" + "\n" + "Audio\n" + " ├─ Devices:\n" + " │      47. Built-in Audio                      [alsa]\n" + " │\n" + " ├─ Sinks:\n" + " │  *   52. Built-in Audio Analog Stereo        [vol: 0.40]\n" + " │      55. HDMI [Main]                         [vol: 1.00 MUTED]\n" + " │\n" + " ├─ Sink endpoints:\n" + " │\n" + " ├─ Sources:\n" + " │  *   53. Built-in Audio Analog Stereo        [vol: 1.00]\n" + " │\n" + " └─ Streams:\n" + "        60. Firefox\n" + "             62. output_FL > Built-in:playback_FL   [active]\n" + "\n" + "Video\n" + " ├─ Devices:\n" + " ├─ Sources:\n" + " │      70. Camera                              [v4l2]\n" + "\n" + "Settings\n" + " └─ Default Configured Devices:\n"

    function test_audioStatus() {
        const a = System.parseAudio(wpctlStatus);
        compare(a.sinks.length, 2);
        compare(a.sources.length, 1);
        compare(a.sinks[0], {id: 52, name: "Built-in Audio Analog Stereo", isDefault: true, volume: 0.4, muted: false});
        compare(a.sinks[1].name, "HDMI [Main]");
        compare(a.sinks[1].muted, true);
        compare(a.sinks[1].isDefault, false);
        compare(System.defaultOf(a.sources).id, 53);
        compare(System.defaultOf([]), null);
        compare(System.percent(0.405), 41);
        compare(System.volumeGlyph(0.5, true), "volume-mute");
        compare(System.volumeGlyph(0.5, false), "volume-2");
    }

    function test_audioKinds() {
        compare(System.audioKind("alsa_output.pci-0000_00_1f.3.analog-stereo"), "builtin");
        compare(System.audioKind("alsa_input.pci-0000_00_1f.3.analog-stereo"), "builtin");
        compare(System.audioKind("alsa_output.platform-sound.HiFi__Speaker__sink"), "builtin");
        compare(System.audioKind("alsa_output.pci-0000_01_00.1.hdmi-stereo-extra1"), "hdmi");
        compare(System.audioKind("alsa_output.pci-0000_00_1f.3.iec958-stereo"), "digital");
        compare(System.audioKind("alsa_output.usb-Focusrite_Scarlett_2i2-00.analog-stereo"), "usb");
        compare(System.audioKind("bluez_output.3C_52_82_10_00_02.1"), "bluetooth");
        compare(System.audioKind("bluez_input.3C:52:82:10:00:02"), "bluetooth");
        compare(System.audioKind("raop_sink.kitchen.local.192.168.1.20.7000"), "network");
        compare(System.audioKind("tunnel.host.alsa_output.pci"), "network");
        compare(System.audioKind("effect_output.noise_suppression"), "virtual");
        compare(System.audioKind("auto_null"), "virtual");
        compare(System.audioKind(""), "virtual");
        // `wpctl status -n` lists node names where `wpctl status` lists descriptions.
        compare(System.audioKinds(wpctlStatus.replace("Built-in Audio Analog Stereo        [vol: 0.40]", "alsa_output.pci-0000_00_1f.3.analog-stereo [vol: 0.40]")
            .replace("HDMI [Main]                         [vol: 1.00 MUTED]", "alsa_output.pci-0000_00_1f.3.hdmi-stereo [vol: 1.00 MUTED]")),
            {"52": "builtin", "55": "hdmi", "53": "virtual"});
    }

    function test_audioGarbage() {
        const a = System.parseAudio("Could not connect to PipeWire\n");
        compare(a.sinks.length + a.sources.length, 0);
    }

    // ---- Stable-id models: a refresh updates rows in place ----

    function keysOf(model) {
        const out = [];
        for (let i = 0; i < model.count; i++)
            out.push(model.get(i).k);
        return out;
    }

    function test_syncModelDiff() {
        const m = createTemporaryObject(modelComp, testCase);
        const item = (k, v) => ({k: k, v: v});
        let created = 0;
        let removed = 0;
        let moved = 0;
        m.rowsInserted.connect(() => created++);
        m.rowsRemoved.connect(() => removed++);
        m.rowsMoved.connect(() => moved++);
        System.syncModel(m, [item("a", 1), item("b", 2), item("c", 3)], "k");
        compare(keysOf(m), ["a", "b", "c"]);
        compare(created, 3);
        // Same keys, one value changed: nothing inserted, removed or moved, one field updated.
        System.syncModel(m, [item("a", 1), item("b", 20), item("c", 3)], "k");
        compare(created, 3);
        compare(removed, 0);
        compare(moved, 0);
        compare(m.get(1).v, 20);
        // Removal in the middle and an addition at the end.
        System.syncModel(m, [item("a", 1), item("c", 3), item("d", 4)], "k");
        compare(keysOf(m), ["a", "c", "d"]);
        compare(removed, 1);
        compare(created, 4);
        // Reordering moves rows, never recreates them.
        System.syncModel(m, [item("d", 4), item("a", 1), item("c", 3)], "k");
        compare(keysOf(m), ["d", "a", "c"]);
        compare(created, 4);
        compare(removed, 1);
        // Insertion before kept rows.
        System.syncModel(m, [item("z", 0), item("d", 4), item("a", 1), item("c", 3)], "k");
        compare(keysOf(m), ["z", "d", "a", "c"]);
        System.syncModel(m, [], "k");
        compare(m.count, 0);
    }

    function test_syncModelAnyOrderReachesTarget() {
        const m = createTemporaryObject(modelComp, testCase);
        const all = ["a", "b", "c", "d", "e"];
        let seed = 7;
        const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
        for (let round = 0; round < 60; round++) {
            const target = all.filter(() => rnd() < 0.6).sort(() => rnd() - 0.5);
            System.syncModel(m, target.map(k => ({k: k, v: round})), "k");
            compare(keysOf(m), target);
        }
    }

    function rowsOf(item, out) {
        for (const c of item.children) {
            if ((c.leading !== undefined || c.glyph !== undefined) && c.activated !== undefined)
                out.push(c);
            rowsOf(c, out);
        }
        return out;
    }

    function rowByTitle(page, title) {
        return rowsOf(page, []).find(r => r.title === title) ?? null;
    }

    function openPage(file, t) {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/" + file));
        compare(comp.status, Component.Ready, comp.errorString());
        const props = {backend: t.backend, system: t.service, width: 700, height: 900};
        // The pages that also write settings (Sound's effects) get a stand-in for the ConfigStore.
        if (file === "SoundPage.qml") {
            t.store = createTemporaryObject(fakeStore, testCase);
            props.store = t.store;
        }
        const page = createTemporaryObject(comp, testCase, props);
        verify(page);
        return page;
    }

    // ConfigStore's value(key) and set(key, value), on the generated contract's defaults; `sets` records the writes.
    Component {
        id: fakeStore
        QtObject {
            property var data: ({})
            property int revision: 0
            property var sets: []
            function value(key: string): var {
                void revision;
                return data[key] !== undefined ? data[key] : SettingsContract.DEFAULTS[key];
            }
            function set(key: string, v: var): bool {
                if (SettingsContract.validate(key, v) !== "")
                    return false;
                const d = Object.assign({}, data);
                d[key] = v;
                data = d;
                sets.push({key: key, value: v});
                revision++;
                return true;
            }
        }
    }

    function test_wifiRefreshKeepsRowsAndFocus() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        t.backend.finished("wifi.state", true, wifiJson([ap("486F6D65", 50, 1, 0, 0x188), ap("43616665", 60, 0, 0, 0), ap("4F6666696365", 40, 1, 0, 0x188)]));
        const home = rowByTitle(page, "Home");
        const cafe = rowByTitle(page, "Cafe");
        verify(home && cafe && rowByTitle(page, "Office"));
        cafe.forceActiveFocus();
        verify(cafe.activeFocus);
        // The next reading: Cafe is now first and stronger, Office is gone, "Zed" appeared, Home changed.
        t.backend.finished("wifi.state", true, wifiJson([ap("43616665", 90, 0, 0, 0), ap("486F6D65", 55, 1, 0, 0x188), ap("5A6564", 30, 0, 0, 0)]));
        verify(rowByTitle(page, "Cafe") === cafe, "the focused row was rebuilt");
        verify(rowByTitle(page, "Home") === home, "a kept row was rebuilt");
        verify(cafe.activeFocus, "focus lost on refresh");
        compare(cafe.leading, "wifi-3");
        compare(home.leading, "wifi-2");
        compare(rowByTitle(page, "Office"), null);
        verify(rowByTitle(page, "Zed") !== null);
        // An unchanged reading changes nothing.
        t.backend.finished("wifi.state", true, wifiJson([ap("43616665", 90, 0, 0, 0), ap("486F6D65", 55, 1, 0, 0x188), ap("5A6564", 30, 0, 0, 0)]));
        verify(cafe.activeFocus);
        compare(rowsOf(page, []).length, 3);
    }

    function test_wifiAsksOneStateOverDBus() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        verify(t.backend.busQueries.length >= 1);
        compare(t.backend.busQueries[0], {what: "wifi.state", tag: "wifi.state"});
        compare(t.backend.queries.length, 0, "no command is run to read the network");
        verify(page);
    }

    function test_wifiKnownByProfileSsid() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        t.backend.finished("wifi.state", true, wifiJson([ap("486F6D65", 50, 1, 0, 0x188)]));
        compare(System.wifiClickKind(page.networks[0], page.known), "password");
        // A saved profile named "Maison" whose SSID is Home: the same state, now with the profile.
        t.backend.finished("wifi.state", true, wifiJson([ap("486F6D65", 50, 1, 0, 0x188)], [{uuid: uuidA, hex: "486F6D65"}]));
        compare(System.wifiClickKind(page.networks[0], page.known), "known");
        compare(page.subtitleOf(page.networks[0]), "Known network");
    }

    function test_wifiNetworkManagerNotAnswering() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        t.backend.finished("wifi.state", true, wifiJson([ap("486F6D65", 50, 1, 0, 0x188)]));
        verify(page.available);
        // One reading without an answer (a timeout) keeps what was read; the second says so.
        t.backend.finished("wifi.state", false, "");
        verify(page.available);
        compare(page.networks.length, 1);
        t.backend.finished("wifi.state", false, "");
        verify(!page.available);
        verify(page.answered);
        compare(page.networks.length, 0);
        compare(page.radio, null);
    }

    function test_wifiClickActsThroughDBus() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        t.backend.finished("wifi.state", true, wifiJson([ap("486F6D65", 50, 1, 0, 0x188), ap("43616665", 60, 0, 0, 0), ap("4F6666696365", 40, 1, 0, 0x188, true)], [{uuid: uuidA, hex: "486F6D65"}]));
        page.activate(page.networks.find(n => n.ssid === "Home"));
        page.activate(page.networks.find(n => n.ssid === "Cafe"));
        // A click on the current network changes nothing (macOS); Disconnect is in its (…) menu.
        page.activate(page.networks.find(n => n.ssid === "Office"));
        page.menuChosen(page.networks.find(n => n.ssid === "Office"), "disconnect");
        // Opening the pane asks for a fresh scan first (never in a dev session); then one action per click.
        compare(t.backend.busActions.map(a => a.op), [{op: "wifi.scan"}, {op: "wifi.connectKnown", uuid: uuidA}, {op: "wifi.connectOpen", hex: "43616665"}, {op: "wifi.disconnect"}]);
        compare(t.backend.actions.length, 0);
    }

    function test_wifiSecuredNetworkAsksForItsPasswordAndJoinsWithIt() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        const asked = [];
        page.passwordRequested.connect(net => asked.push(net.ssid));
        t.backend.finished("wifi.state", true, wifiJson([ap("486F6D65", 50, 1, 0, 0x188), ap("436F7270", 40, 1, 0, 0x288), ap("4F6C64", 30, 1, 0, 0)]));
        page.activate(page.networks.find(n => n.ssid === "Home"));
        compare(asked, ["Home"]);
        // The sheet's answer: one wifi.connectSecure with the SSID's bytes and the password, the row busy until it ends.
        page.join(page.networks.find(n => n.ssid === "Home"), "correct horse");
        compare(t.backend.busActions[t.backend.busActions.length - 1].op, {op: "wifi.connectSecure", hex: "486F6D65", psk: "correct horse"});
        compare(page.pending, page.networks.find(n => n.ssid === "Home").key);
        t.backend.finished("wifi.act", true, "");
        compare(page.pending, "");
        // A password NetworkManager would refuse never leaves the page.
        const before = t.backend.busActions.length;
        page.join(page.networks.find(n => n.ssid === "Home"), "short");
        compare(t.backend.busActions.length, before);
        // 802.1X (a sign-in) and WEP: no sheet, a line that says why.
        page.activate(page.networks.find(n => n.ssid === "Corp"));
        verify(page.notice.indexOf("802.1X") >= 0, page.notice);
        page.activate(page.networks.find(n => n.ssid === "Old"));
        verify(page.notice.indexOf("WEP") >= 0, page.notice);
        compare(asked, ["Home"]);
        compare(t.backend.busActions.length, before);
    }

    function test_wifiListsKnownAndOtherNetworksWithTheirMenus() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        t.backend.finished("wifi.state", true, wifiJson([ap("486F6D65", 50, 1, 0, 0x188, true), ap("43616665", 60, 0, 0, 0), ap("576F726B", 40, 1, 0, 0x188)],
                                                       [{uuid: uuidA, hex: "486F6D65"}, {uuid: "1a2b3c4d-5e6f-4a1b-9c2d-3e4f5a6b7c8d", hex: "576F726B"}]));
        // Known Network: the current one first, checked; Other Networks: the rest.
        const home = rowByTitle(page, "Home");
        verify(home && home.checked);
        compare(home.rowHeight, Tokens.settingsWifiKnownRowHeight);
        compare(rowByTitle(page, "Cafe").rowHeight, Tokens.settingsWifiOtherRowHeight);
        verify(!rowByTitle(page, "Work").checked);
        compare(rowByTitle(page, "Work").rowHeight, Tokens.settingsWifiKnownRowHeight);
        // The (…) menus: the current network can be disconnected, shown and forgotten; a known one joined or forgotten; an
        // unknown one only joined.
        compare(home.menuItems.filter(i => !i.separator).map(i => i.id), ["disconnect", "details", "forget"]);
        compare(rowByTitle(page, "Work").menuItems.filter(i => !i.separator).map(i => i.id), ["connect", "forget"]);
        compare(rowByTitle(page, "Cafe").menuItems.map(i => i.id), ["connect"]);
        // Forget This Network…: Main.qml asks first; the answer forgets the profile of that SSID.
        const forget = [];
        page.forgetRequested.connect(net => forget.push(net.ssid));
        page.menuChosen(page.networks.find(n => n.ssid === "Work"), "forget");
        compare(forget, ["Work"]);
        page.forget(page.networks.find(n => n.ssid === "Work"));
        compare(t.backend.busActions[t.backend.busActions.length - 1].op, {op: "wifi.forget", uuid: "1a2b3c4d-5e6f-4a1b-9c2d-3e4f5a6b7c8d"});
        // Details… reads net.state once (not on every refresh) and hands its Wi-Fi device to the sheet.
        const details = [];
        page.detailsRequested.connect((net, dev) => details.push([net.ssid, dev ? dev.ip4[0] : null]));
        compare(t.backend.busQueries.filter(q => q.what === "net.state").length, 0);
        page.menuChosen(page.networks.find(n => n.ssid === "Home"), "details");
        compare(t.backend.busQueries[t.backend.busQueries.length - 1], {what: "net.state", tag: "wifi.details"});
        compare(details.length, 0);
        t.backend.finished("wifi.details", true, JSON.stringify({devices: [{name: "wlo1", type: "wifi", state: "connected", ip4: ["10.0.0.5/24"]}], vpns: []}));
        compare(details, [["Home", "10.0.0.5/24"]]);
        // A late or repeated answer opens nothing more; a failed read still opens the sheet, without addresses.
        t.backend.finished("wifi.details", true, "{}");
        compare(details.length, 1);
        page.menuChosen(page.networks.find(n => n.ssid === "Home"), "details");
        t.backend.finished("wifi.details", false, "");
        compare(details, [["Home", "10.0.0.5/24"], ["Home", null]]);
    }

    Component {
        id: passwordHost
        Item {
            width: 700
            height: 600
            property alias sheet: sheet
            SettingsQml.WifiPasswordSheet {
                id: sheet
            }
        }
    }

    function test_wifiPasswordSheetKeepsThePasswordNowhere() {
        const host = createTemporaryObject(passwordHost, testCase);
        verify(host);
        const sheet = host.sheet;
        const joined = [];
        sheet.join.connect((net, psk) => joined.push([net.ssid, psk]));
        sheet.openFor({ssid: "Home", label: "Home"});
        verify(sheet.shown);
        verify(sheet.fieldPassword, "the password is hidden while it is typed");
        // A password NetworkManager would refuse keeps the sheet open with the reason.
        sheet.setField("short");
        sheet.confirm();
        verify(sheet.shown);
        verify(sheet.errorText !== "");
        compare(joined.length, 0);
        // Join hands it back once and empties the field.
        sheet.setField("correct horse");
        sheet.confirm();
        verify(!sheet.shown);
        compare(joined, [["Home", "correct horse"]]);
        compare(sheet.fieldText, "");
        // Cancel empties it too.
        sheet.openFor({ssid: "Home", label: "Home"});
        sheet.setField("half typed");
        sheet.cancel();
        compare(sheet.fieldText, "");
        compare(joined.length, 1);
    }

    function test_wifiOffShowsTheHeaderOnly() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        t.backend.finished("wifi.state", true, wifiJson([], [], false));
        verify(page.available);
        verify(!page.listsShown);
        compare(rowsOf(page, []).length, 0);
        // No Wi-Fi device at all: the header says so.
        t.backend.finished("wifi.state", true, wifiJson([], [], true, null));
        verify(!page.listsShown);
    }

    function test_wifiSectionsPassphraseBandAndMask() {
        const known = {"486F6D65": uuidA};
        const nets = [{hex: "486F6D65", active: false}, {hex: "43616665", active: true}, {hex: "5A6564", active: false}];
        const s = System.wifiSections(nets, known);
        compare(s.known.map(n => n.hex), ["486F6D65", "43616665"]);
        compare(s.other.map(n => n.hex), ["5A6564"]);
        verify(System.validPassphrase("12345678"));
        verify(System.validPassphrase("~".repeat(63)));
        verify(System.validPassphrase("a".repeat(64)));
        verify(!System.validPassphrase("1234567"));
        verify(!System.validPassphrase("g".repeat(64)));
        verify(!System.validPassphrase("a".repeat(65)));
        verify(!System.validPassphrase("caf\u00e9 au lait"));
        verify(!System.validPassphrase("line\nbreak"));
        verify(!System.validPassphrase(12345678));
        compare(System.wifiConnectSecure("Home", "correct horse"), {op: "wifi.connectSecure", hex: "486F6D65", psk: "correct horse"});
        compare(System.wifiConnectSecure("Home", "short"), null);
        compare(System.wifiConnectSecure("bad\nname", "correct horse"), null);
        compare(System.wifiForget(uuidA), {op: "wifi.forget", uuid: uuidA});
        compare(System.wifiForget("nope"), null);
        compare(System.vpnConnect(uuidA, true), {op: "vpn.connect", uuid: uuidA, on: true});
        compare(System.vpnConnect("nope", true), null);
        const en = Qt.locale("en_US");
        compare(System.wifiBand(2437, en), "2.4 GHz");
        compare(System.wifiBand(5180, en), "5 GHz");
        compare(System.wifiBand(5955, en), "6 GHz");
        compare(System.wifiBand(0, en), "");
        compare(System.wifiBand(2437, Qt.locale("fr_FR")), "2,4 GHz", "the language's decimal separator");
        compare(System.wifiBand(2437), System.wifiBand(2437, Qt.locale()));
        compare(System.subnetMask(24), "255.255.255.0");
        compare(System.subnetMask(20), "255.255.240.0");
        compare(System.subnetMask(0), "0.0.0.0");
        compare(System.subnetMask(32), "255.255.255.255");
        compare(System.subnetMask(33), "");
        // The click kinds of the secured networks: a password (WPA), a sign-in (802.1X only), WEP.
        compare(System.wifiClickKind({hex: "41", active: false, secured: true, security: "WPA3 WPA2", enterprise: false}, {}), "password");
        compare(System.wifiClickKind({hex: "41", active: false, secured: true, security: "802.1X", enterprise: true}, {}), "account");
        compare(System.wifiClickKind({hex: "41", active: false, secured: true, security: "WEP", enterprise: false}, {}), "unsupported");
    }

    function netJson(devices, vpns, firewall) {
        return JSON.stringify({devices: devices, vpns: vpns ?? [], firewall: firewall ?? {name: "", active: false}});
    }

    function test_networkServicesAndFirewall() {
        const st = System.parseNetState(netJson([{name: "wlo1", type: "wifi", state: "connected"}, {name: "enp1", type: "ethernet", state: "unavailable"},
                                                 {name: "enp2", type: "ethernet", state: "disconnected"}, {name: "enp3", type: "ethernet", state: "connecting"}],
                                                [], {name: "ufw", active: true}));
        const s = System.networkServices(st, null);
        // Connected and connecting first, the rest under Other Services; several Ethernet devices are numbered.
        compare(s.active.map(x => [x.id, x.status, x.number]), [["wlo1", "connected", 0], ["enp3", "connecting", 3]]);
        compare(s.other.map(x => [x.id, x.status, x.number]), [["enp1", "unplugged", 1], ["enp2", "notConnected", 2]]);
        // The Wi-Fi radio off: the Wi-Fi service is Off, under Other Services.
        compare(System.networkServices(System.parseNetState(netJson([{name: "wlo1", type: "wifi", state: "unavailable"}])), null).other[0].status, "off");
        compare(System.networkServices(null, null), {active: [], other: []});
        compare(st.firewall, {name: "ufw", active: true});
        compare(System.parseNetState(netJson([], [], {name: "iptables", active: true})).firewall, {name: "", active: false});
        compare(System.parseNetState(JSON.stringify({devices: [], vpns: []})).firewall, {name: "", active: false});
        // ufw's own switch.
        compare(System.ufwEnabled("# comment\nENABLED=yes\nLOGLEVEL=low\n"), true);
        compare(System.ufwEnabled("ENABLED=no"), false);
        compare(System.ufwEnabled("ENABLED=\"yes\""), true);
        compare(System.ufwEnabled("#ENABLED=yes"), null);
        compare(System.ufwEnabled(""), null);
    }

    function test_networkPageListsServicesAndOpensThem() {
        const t = makeService(false);
        const page = openPage("NetworkPage.qml", t);
        compare(t.backend.busQueries[0], {what: "net.state", tag: "net.state"});
        t.backend.finished("net.state", true, netJson([{name: "wlo1", type: "wifi", state: "connected"}, {name: "enp1", type: "ethernet", state: "unavailable", ip4: []}],
                                                      [], {name: "firewalld", active: true}));
        verify(page.firewallOn, "an active firewalld unit is on");
        const opened = [], details = [];
        page.openRequested.connect(id => opened.push(id));
        page.detailsRequested.connect((name, dev) => details.push([name, dev.name]));
        page.open("wlo1", "wifi", 0);
        page.open("enp1", "ethernet", 0);
        compare(opened, ["wifi"]);
        compare(details, [["Ethernet", "enp1"]]);
        compare(page.statusText("unplugged"), "Cable unplugged");
        // ufw: its unit is active either way, ENABLED= decides; no file (or no such line): unknown, so not shown as on.
        t.backend.finished("net.state", true, netJson([], [], {name: "ufw", active: true}));
        compare(page.ufwEnabled, null);
        verify(!page.firewallOn);
        t.backend.files = {"/etc/ufw/ufw.conf": "ENABLED=yes\n"};
        t.backend.finished("net.state", true, netJson([], [], {name: "ufw", active: true}));
        verify(page.firewallOn);
        t.backend.files = {"/etc/ufw/ufw.conf": "ENABLED=no\n"};
        t.backend.finished("net.state", true, netJson([], [], {name: "ufw", active: true}));
        verify(!page.firewallOn);
        compare(t.backend.actions.length + t.backend.busActions.length, 0, "the Network pane changes nothing");
    }

    function test_vpnPageSwitchesThroughDBus() {
        const t = makeService(false);
        const page = openPage("VpnPage.qml", t);
        compare(t.backend.busQueries[0], {what: "net.state", tag: "vpn.state"});
        t.backend.finished("vpn.state", true, netJson([], [{uuid: uuidA, name: "Office", kind: "vpn", state: "disconnected"}]));
        verify(page.available);
        // The kind and the state in one translatable sentence.
        const row = findChild(page, "", i => i.title === "Office" && i.subtitle !== undefined);
        compare(row.subtitle, "VPN · Not connected");
        page.toggle(uuidA, true);
        compare(t.backend.busActions[t.backend.busActions.length - 1].op, {op: "vpn.connect", uuid: uuidA, on: true});
        compare(page.pending, uuidA);
        compare(row.subtitle, "VPN · Changing…");
        t.backend.finished("vpn.act", true, "");
        compare(page.pending, "");
        // NetworkManager not answering: the empty group says so.
        t.backend.finished("vpn.state", false, "");
        verify(!page.available);
        verify(page.answered);
    }

    function test_netStateParser() {
        const st = System.parseNetState(JSON.stringify({
            devices: [{name: "enp3s0", type: "ethernet", state: "connected", mac: "AA:BB:CC:DD:EE:FF", connection: "Wired", uuid: uuidA,
                       ip4: ["192.168.1.2/24", 5], router: "192.168.1.1", dns: ["1.1.1.1"], ip6: [], bitrate: 0},
                      {name: "wlo1", type: "wifi", state: "bogus", ssid: "486F6D65", frequency: 5180, bitrate: 866000},
                      {name: "lo", type: "loopback"}, null, {type: "wifi"}],
            vpns: [{uuid: uuidA, name: "Zed", kind: "wireguard", state: "connected"}, {uuid: "x", name: "bad"}, {uuid: "1a2b3c4d-5e6f-4a1b-9c2d-3e4f5a6b7c8d", name: "Alpha", kind: "openvpn", state: "connecting"}]
        }));
        compare(st.devices.length, 2);
        compare(st.devices[0].ip4, ["192.168.1.2/24"]);
        compare(st.devices[0].router, "192.168.1.1");
        compare(st.devices[1].state, "unavailable");
        compare(st.devices[1].ssid, "Home");
        compare(st.devices[1].dns, []);
        // Sorted by name; an unknown kind is a plain VPN; a bad uuid is dropped.
        compare(st.vpns.map(v => v.name), ["Alpha", "Zed"]);
        compare(st.vpns[0].kind, "vpn");
        compare(st.vpns[1].kind, "wireguard");
        compare(System.parseNetState("{}"), null);
        compare(System.parseNetState("nope"), null);
    }

    function test_actionFailureShowsReason() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        t.backend.finished("wifi.state", true, wifiJson([]));
        t.backend.failed("wifi.act", "Connection activation failed: Secrets were required");
        compare(t.service.errors["wifi.act"], "Connection activation failed: Secrets were required");
        // The next action clears it; a success clears it too.
        t.service.act("wifi on", System.wifiRadio(true), "wifi.act");
        compare(t.service.errors["wifi.act"], undefined);
        t.backend.failed("wifi.act", "");
        compare(t.service.errors["wifi.act"], "-");
        t.backend.finished("wifi.act", true, "");
        compare(t.service.errors["wifi.act"], undefined);
        // A failed query is not an action error.
        t.backend.failed("wifi.state", "boom");
        compare(t.service.errors["wifi.state"], undefined);
        verify(page);
    }

    function test_bluetoothRefreshKeepsRows() {
        const t = makeService(false);
        const page = openPage("BluetoothPage.qml", t);
        const state = connected => JSON.stringify({present: true, powered: true, devices: [{mac: "11:22:33:44:55:66", name: "Headphones", connected: false}, {mac: "77:88:99:AA:BB:CC", name: "Zed", connected: connected}]});
        t.backend.finished("bt.state", true, state(false));
        const zed = rowByTitle(page, "Zed");
        verify(zed && rowByTitle(page, "Headphones"));
        zed.forceActiveFocus();
        verify(zed.activeFocus);
        t.backend.finished("bt.state", true, state(true));
        verify(rowByTitle(page, "Zed") === zed, "row rebuilt");
        verify(zed.activeFocus, "focus lost on refresh");
        compare(zed.status, "Connected");
        compare(rowsOf(page, []).length, 2);
        compare(t.backend.queries.length, 0, "no command is run to read Bluetooth");
        verify(t.backend.busQueries.some(q => q.what === "bt.state"));
    }

    function test_bluetoothNearbyDevicesArePairedAndPairedOnesForgotten() {
        const t = makeService(false);
        const page = openPage("BluetoothPage.qml", t);
        t.backend.finished("bt.state", true, JSON.stringify({present: true, powered: true, discovering: true, alias: "gf-ref",
            devices: [{mac: "77:88:99:AA:BB:CC", name: "Zed", connected: false, icon: "input-mouse", battery: 40}],
            nearby: [{mac: "33:33:33:33:33:33", name: "Keyboard K3", icon: "input-keyboard", rssi: -48}, {mac: "44:44:44:44:44:44", name: "Far", icon: "", rssi: -90}]}));
        verify(page.searching);
        compare(page.nearby.map(n => n.name), ["Keyboard K3", "Far"]);
        page.pair("33:33:33:33:33:33");
        compare(t.backend.busActions[t.backend.busActions.length - 1].op, {op: "bt.pair", mac: "33:33:33:33:33:33"});
        compare(page.pending, "33:33:33:33:33:33");
        t.backend.finished("bt.act", true, "");
        compare(page.pending, "");
        // (i) and Forget This Device…: Main.qml asks first, the answer removes the device.
        const info = [];
        page.infoRequested.connect(d => info.push(d.mac));
        rowByTitle(page, "Zed").infoRequested();
        compare(info, ["77:88:99:AA:BB:CC"]);
        page.forget(page.devices[0]);
        compare(t.backend.busActions[t.backend.busActions.length - 1].op, {op: "bt.forget", mac: "77:88:99:AA:BB:CC"});
        // The radio off stops the search; so does leaving the pane.
        t.backend.finished("bt.state", true, JSON.stringify({present: true, powered: false, devices: []}));
        verify(!page.searching);
        compare(t.backend.busActions[t.backend.busActions.length - 1].op, {op: "bt.discover", on: false});
        t.backend.finished("bt.state", true, JSON.stringify({present: true, powered: true, devices: []}));
        verify(page.searching);
        page.destroy();
        wait(0);
        compare(t.backend.busActions[t.backend.busActions.length - 1].op, {op: "bt.discover", on: false});
        // The device glyphs.
        compare(System.btGlyph("audio-headset"), "headphones");
        compare(System.btGlyph("input-keyboard"), "keyboard");
        compare(System.btGlyph("phone"), "phone");
        compare(System.btGlyph("weird"), "bluetooth");
        compare(System.btPair("nope"), null);
        compare(System.btForget("11:22:33:44:55"), null);
    }

    function test_bluetoothDevSessionNeverSearches() {
        const t = makeService(true);
        const page = openPage("BluetoothPage.qml", t);
        t.backend.finished("bt.state", true, JSON.stringify({present: true, powered: true, devices: []}));
        verify(!page.searching);
        compare(t.backend.busActions.length, 0);
    }

    function test_bluetoothActsThroughDBusAndFailuresAreShown() {
        const t = makeService(false);
        const page = openPage("BluetoothPage.qml", t);
        t.backend.finished("bt.state", true, JSON.stringify({present: true, powered: true, devices: [{mac: "77:88:99:AA:BB:CC", name: "Zed", connected: true}]}));
        page.connectDevice(page.devices[0]);
        // With the radio on, the pane looks for nearby devices first (never in a dev session).
        compare(t.backend.busActions.map(a => a.op), [{op: "bt.discover", on: true}, {op: "bt.connect", mac: "77:88:99:AA:BB:CC", connect: false}]);
        compare(page.pending, "77:88:99:AA:BB:CC");
        t.backend.failed("bt.act", "Software caused connection abort");
        t.backend.finished("bt.act", false, "");
        compare(page.pending, "");
        compare(t.service.errors["bt.act"], "Software caused connection abort");
        // No adapter, or no BlueZ: the page says so, at the second reading without an answer (the first keeps what was read).
        t.backend.finished("bt.state", false, "");
        compare(page.controller.present, true);
        t.backend.finished("bt.state", false, "");
        verify(page.answered);
        // A search that failed to start is not held as started: the next reading asks again.
        t.backend.finished("bt.state", true, JSON.stringify({present: true, powered: true, devices: []}));
        compare(page.searching, true);
        t.backend.finished("bt.discover", false, "");
        compare(page.searching, false);
        t.backend.finished("bt.state", true, JSON.stringify({present: true, powered: true, devices: []}));
        compare(page.searching, true);
        t.backend.finished("bt.state", false, "");
        t.backend.finished("bt.state", false, "");
        compare(page.controller.present, false);
        compare(page.devices.length, 0);
    }

    // The device rows of the Sound table (SoundDeviceTable delegates).
    function soundRows(item, out) {
        for (const c of item.children) {
            if (c.nodeId !== undefined && c.kind !== undefined)
                out.push(c);
            soundRows(c, out);
        }
        return out;
    }

    function soundRow(page, name) {
        return soundRows(page, []).find(r => r.name === name) ?? null;
    }

    function soundTable(page) {
        return findChild(page, "", t => t.chosen !== undefined && t.kindLabel !== undefined);
    }

    function findChild(item, unused, pred) {
        for (const c of item.children) {
            if (pred(c))
                return c;
            const found = findChild(c, unused, pred);
            if (found)
                return found;
        }
        return null;
    }

    readonly property string wpctlNames: wpctlStatus.replace("Built-in Audio Analog Stereo        [vol: 0.40]", "alsa_output.pci-0000_00_1f.3.analog-stereo [vol: 0.40]")
        .replace("HDMI [Main]                         [vol: 1.00 MUTED]", "alsa_output.pci-0000_00_1f.3.hdmi-stereo [vol: 1.00 MUTED]")
        .replace("Built-in Audio Analog Stereo        [vol: 1.00]", "alsa_input.pci-0000_00_1f.3.analog-stereo [vol: 1.00]")

    function test_soundTableKindsAndRefreshKeepsRows() {
        const t = makeService(false);
        const page = openPage("SoundPage.qml", t);
        t.backend.finished("audio.status", true, wpctlStatus);
        // New devices: their node names are asked for once, and give the Type column.
        compare(t.backend.queries.filter(q => q.length === 3 && q[2] === "-n").length, 1);
        const hdmi = soundRow(page, "HDMI [Main]");
        const builtin = soundRow(page, "Built-in Audio Analog Stereo");
        verify(hdmi && builtin);
        compare(hdmi.kind, "");
        t.backend.finished("audio.names", true, wpctlNames);
        compare(hdmi.kind, "hdmi");
        compare(builtin.kind, "builtin");
        compare(soundTable(page).kindLabel(hdmi.kind), "HDMI or DisplayPort");
        verify(builtin.selected);
        verify(!hdmi.selected);
        // Volume moved, HDMI became the default: the same rows, no new name query (the devices are known).
        t.backend.finished("audio.status", true, wpctlStatus.replace("[vol: 0.40]", "[vol: 0.30]").replace(" │      55. HDMI [Main]                         [vol: 1.00 MUTED]", " │  *   55. HDMI [Main]                         [vol: 1.00 MUTED]").replace(" │  *   52.", " │      52."));
        verify(soundRow(page, "HDMI [Main]") === hdmi, "row rebuilt");
        verify(hdmi.selected);
        verify(!builtin.selected);
        compare(t.backend.queries.filter(q => q.length === 3).length, 1);
        // A device whose kind the names did not give is not asked about again.
        t.backend.finished("audio.status", true, wpctlStatus.replace(" │      55. HDMI", " │      57. Dock Speakers                       [vol: 0.50]\n │      55. HDMI"));
        compare(t.backend.queries.filter(q => q.length === 3).length, 2);
        t.backend.finished("audio.names", true, wpctlNames);
        t.backend.finished("audio.status", true, wpctlStatus.replace(" │      55. HDMI", " │      57. Dock Speakers                       [vol: 0.50]\n │      55. HDMI"));
        compare(t.backend.queries.filter(q => q.length === 3).length, 2);
        compare(soundRow(page, "Dock Speakers").kind, "");
    }

    function test_soundTableChoosesByClickAndKeys() {
        const t = makeService(false);
        const page = openPage("SoundPage.qml", t);
        t.backend.finished("audio.status", true, wpctlStatus);
        const table = soundTable(page);
        const hdmi = soundRow(page, "HDMI [Main]");
        // The groups are laid out (the page's column positions them before the next frame).
        tryVerify(() => page.contentItem.children[0].height > 0);
        // The table is below the Sound Effects group: scrolled into view first.
        tryVerify(() => hdmi.mapToItem(page.contentItem, 0, 0).y > page.contentItem.children[0].children[0].height);
        page.contentY = Math.max(0, hdmi.mapToItem(page.contentItem, 0, 0).y - 100);
        mouseClick(hdmi);
        verify(table.activeFocus, "a click focuses the table");
        compare(t.backend.actions.length, 1);
        compare(t.backend.actions[0].argv, ["wpctl", "set-default", "55"]);
        // Chosen: selected at once, and in the accent while the table has the focus.
        verify(hdmi.selected);
        verify(hdmi.emphasized);
        t.backend.finished("audio.act", true, "");
        verify(!hdmi.selected, "back to what PipeWire says until it answers");
        // Up from the default (the first row) goes nowhere; Down chooses the next row; End the last.
        keyClick(Qt.Key_Up);
        compare(t.backend.actions.length, 1);
        keyClick(Qt.Key_Down);
        compare(t.backend.actions.length, 2);
        compare(t.backend.actions[1].argv, ["wpctl", "set-default", "55"]);
        // Choosing the selected row does nothing.
        keyClick(Qt.Key_End);
        compare(t.backend.actions.length, 2);
        // Input: the sources, their volume and mute.
        page.side = "input";
        compare(soundRows(page, []).map(r => r.name), ["Built-in Audio Analog Stereo"]);
        verify(soundRows(page, [])[0].selected);
        compare(page.current.id, 53);
        compare(table.accessibleName, "Input devices");
    }

    // ---- Sound Effects (ADR-0047 B-4) ----

    function controlNamed(page, name) {
        return findChild(page, "", c => c.accessibleName === name && c.visible !== false);
    }

    function test_soundEffectsAlertPickPlaysAndPersists() {
        const t = makeService(false);
        const page = openPage("SoundPage.qml", t);
        const picker = controlNamed(page, "Alert sound");
        verify(picker);
        compare(picker.model.map(m => m.id), SoundEffects.ALERTS);
        compare(picker.value, "meadow");
        picker.picked("lantern");
        compare(t.store.sets[0], {key: "sound.alert", value: "lantern"});
        compare(picker.value, "lantern");
        compare(t.backend.actions.length, 1);
        compare(t.backend.actions[0].what, "sound preview");
        compare(t.backend.actions[0].argv, ["pw-play", "--media-role", "Notification", "--volume", "0.422", "--", "/usr/share/sounds/grassfield/stereo/grassfield-alert-lantern.wav"]);
        // The play button plays it again.
        controlNamed(page, "Play the alert sound").clicked();
        compare(t.backend.actions.length, 2);
        compare(t.backend.actions[1].argv, t.backend.actions[0].argv);
    }

    function test_soundEffectsOutputChoices() {
        const t = makeService(false);
        const page = openPage("SoundPage.qml", t);
        const picker = controlNamed(page, "Play sound effects through");
        compare(picker.model.map(m => m.id), [""], "the selected device only until the outputs are known");
        t.backend.finished("audio.status", true, wpctlStatus);
        t.backend.finished("audio.names", true, wpctlNames);
        compare(picker.model.map(m => m.id), ["", "alsa_output.pci-0000_00_1f.3.analog-stereo", "alsa_output.pci-0000_00_1f.3.hdmi-stereo"]);
        compare(picker.model[0].text, "Selected Sound Output Device");
        compare(picker.model[2].text, "HDMI [Main]");
        picker.picked("alsa_output.pci-0000_00_1f.3.hdmi-stereo");
        compare(t.store.value("sound.effectsOutput"), "alsa_output.pci-0000_00_1f.3.hdmi-stereo");
        // The preview goes through the chosen output while it is connected.
        controlNamed(page, "Play the alert sound").clicked();
        compare(t.backend.actions[0].argv.slice(5, 7), ["--target", "alsa_output.pci-0000_00_1f.3.hdmi-stereo"]);
        // A remembered output that is not connected: listed as such, and the preview uses the selected device.
        t.store.set("sound.effectsOutput", "bluez_output.AA_BB_CC_DD_EE_FF.1");
        compare(picker.model[picker.model.length - 1], {id: "bluez_output.AA_BB_CC_DD_EE_FF.1", text: "Device not connected"});
        compare(picker.value, "bluez_output.AA_BB_CC_DD_EE_FF.1");
        controlNamed(page, "Play the alert sound").clicked();
        verify(t.backend.actions[1].argv.indexOf("--target") < 0);
    }

    function test_soundEffectsAlertVolumeAndSwitches() {
        const t = makeService(false);
        const page = openPage("SoundPage.qml", t);
        const row = findChild(page, "", c => c.title === "Alert volume" && c.apply !== undefined);
        verify(row);
        compare(row.value, 0.75);
        verify(row.apply(0.5));
        compare(t.store.value("sound.alertVolume"), 0.5);
        compare(row.value, 0.5);
        // The alert plays once the drag rests, at the new volume.
        compare(t.backend.actions.length, 0);
        tryCompare(t.backend.actions, "length", 1);
        compare(t.backend.actions[0].argv[4], "0.125");
        const ui = controlNamed(page, "Play user interface sound effects");
        const feedback = controlNamed(page, "Play feedback when volume is changed");
        verify(ui.checked);
        verify(!feedback.checked, "off by default, as macOS");
        ui.toggled(false);
        feedback.toggled(true);
        compare(t.store.value("sound.uiEffects"), false);
        compare(t.store.value("sound.volumeFeedback"), true);
        verify(!ui.checked);
        verify(feedback.checked);
    }

    function test_soundEffectsPreviewSuppressedInDev() {
        const t = makeService(true);
        const page = openPage("SoundPage.qml", t);
        controlNamed(page, "Alert sound").picked("reed");
        controlNamed(page, "Play the alert sound").clicked();
        compare(t.backend.actions.length, 0);
        verify(t.service.suppressedNote);
        // The choice itself is a setting: it is kept.
        compare(t.store.value("sound.alert"), "reed");
    }

    function test_soundDevSessionChoosesNothing() {
        const t = makeService(true);
        const page = openPage("SoundPage.qml", t);
        t.backend.finished("audio.status", true, wpctlStatus);
        tryVerify(() => page.contentItem.children[0].height > 0);
        tryVerify(() => soundRow(page, "HDMI [Main]").mapToItem(page.contentItem, 0, 0).y > page.contentItem.children[0].children[0].height);
        page.contentY = Math.max(0, soundRow(page, "HDMI [Main]").mapToItem(page.contentItem, 0, 0).y - 100);
        mouseClick(soundRow(page, "HDMI [Main]"));
        compare(t.backend.actions.length, 0);
        compare(page.pending, -1);
        verify(soundRow(page, "Built-in Audio Analog Stereo").selected);
    }

    // ---- the focus ring of the list rows and their buttons: the keyboard's focus only ----

    Component {
        id: ringHost
        Column {
            width: 600
            property alias network: network
            property alias device: device
            property alias info: info
            property alias more: more
            SettingsQml.NetworkRow {
                id: network
                title: "Home"
                menuItems: [{id: "forget", text: "Forget"}]
            }
            SettingsQml.BluetoothDeviceRow {
                id: device
                title: "Keyboard"
            }
            SettingsQml.InfoButton {
                id: info
            }
            SettingsQml.MoreButton {
                id: more
                items: [{id: "forget", text: "Forget"}]
            }
        }
    }

    // The ring a row or a button draws for its focus (a FocusRing, or the row's own outline).
    function ringOf(item) {
        for (const c of item.children) {
            if (c.border !== undefined && c.border.color === Appearance.focusRingColor && c.color.a === 0)
                return c;
            if (c.shapeRadius !== undefined)
                return c;
        }
        return null;
    }

    function test_focusRingFollowsTheKeyboardOnly() {
        const host = createTemporaryObject(ringHost, testCase);
        for (const item of [host.network, host.device, host.info]) {
            const ring = ringOf(item);
            verify(ring, item.toString());
            // A click focuses it without the ring (a control's visualFocus).
            mouseClick(item, 5, item.height / 2);
            verify(item.activeFocus, item.toString());
            verify(!item.visualFocus, item.toString());
            verify(!ring.visible, item.toString());
            // Tab away and back: the keyboard's focus shows it.
            item.focus = false;
            testCase.forceActiveFocus();
            verify(!item.activeFocus);
            item.forceActiveFocus(Qt.TabFocusReason);
            verify(item.visualFocus, item.toString());
            verify(ring.visible, item.toString());
            // A click on the focused item takes it away again.
            mouseClick(item, 5, item.height / 2);
            verify(!ring.visible, item.toString());
            testCase.forceActiveFocus();
        }
        // The (…) button: its menu takes the keyboard and hands it back as the menu was opened.
        const more = host.more;
        const ring = ringOf(more);
        mouseClick(more);
        tryVerify(() => !more.activeFocus, 1000, "the menu holds the keyboard");
        keyClick(Qt.Key_Escape);
        tryVerify(() => more.activeFocus);
        verify(!ring.visible, "opened by a click: no ring after the menu");
        testCase.forceActiveFocus();
        more.forceActiveFocus(Qt.TabFocusReason);
        verify(ring.visible);
        keyClick(Qt.Key_Space);
        tryVerify(() => !more.activeFocus, 1000, "the menu holds the keyboard");
        keyClick(Qt.Key_Escape);
        tryVerify(() => more.activeFocus);
        verify(ring.visible, "opened from the keyboard: the ring is back");
    }
}
