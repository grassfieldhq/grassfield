import QtQuick
import QtTest
import "../../shell/overlay/controlcenter/Model.js" as Model

TestCase {
    name: "ControlCenterModel"

    function net(name, strength, extra) {
        return Object.assign({name: name, strength: strength, secured: true, enterprise: false, connected: false, known: false}, extra || {});
    }

    function test_networksSortedByStrengthConnectedFirst() {
        const out = Model.sortNetworks([net("b", 0.3), net("a", 0.9), net("c", 0.5, {connected: true}), net("d", 0.9)]);
        compare(out.map(n => n.name).join(","), "c,a,d,b");
    }

    function test_networksDedupeAndHidden() {
        const out = Model.sortNetworks([net("x", 0.2), net("x", 0.8), net("", 0.9)]);
        compare(out.length, 1);
        compare(out[0].strength, 0.8);
    }

    function test_connectedDuplicateWins() {
        const out = Model.sortNetworks([net("x", 0.9), net("x", 0.2, {connected: true})]);
        verify(out[0].connected);
    }

    function test_networkActions() {
        compare(Model.networkAction(net("a", 1, {connected: true})), "disconnect");
        compare(Model.networkAction(net("a", 1, {known: true})), "connect");
        compare(Model.networkAction(net("a", 1, {secured: false})), "connect");
        compare(Model.networkAction(net("a", 1)), "password");
        compare(Model.networkAction(net("a", 1, {enterprise: true})), "editor");
    }

    function test_deviceListPairedOnly() {
        const out = Model.sortDevices([
            {name: "Zed", paired: true, connected: false},
            {name: "Unpaired", paired: false, connected: false},
            {name: "Mouse", paired: true, connected: true},
            {name: "Alpha", paired: true, connected: false}
        ]);
        compare(out.map(d => d.name).join(","), "Mouse,Alpha,Zed");
    }

    function test_batteryText() {
        compare(Model.batteryText(-1), "");
        compare(Model.batteryText(0.456), "46%");
    }

    function test_audioRows() {
        const a = {n: "Speakers"}, b = {n: "HDMI"};
        const out = Model.audioRows([a, b], b, n => n.n);
        compare(out[0].label, "HDMI");
        verify(out[0].isDefault);
        verify(!out[1].isDefault);
    }

    function test_stepIndex() {
        compare(Model.stepIndex(-1, 3, 1), 0);
        compare(Model.stepIndex(-1, 3, -1), 2);
        compare(Model.stepIndex(2, 3, 1), 2);
        compare(Model.stepIndex(0, 3, -1), 0);
        compare(Model.stepIndex(0, 0, 1), -1);
    }

    function test_failReasonKey() {
        compare(Model.failReasonKey(1), "noSecrets");
        compare(Model.failReasonKey(2), "disconnected");
        compare(Model.failReasonKey(3), "failed");
        compare(Model.failReasonKey(4), "timeout");
        compare(Model.failReasonKey(5), "lost");
        compare(Model.failReasonKey(0), "unknown");
        compare(Model.failReasonKey(99), "unknown");
    }

    // Grid with a player: Wi-Fi | DND, Bluetooth | Now Playing (2x2 with one transport button), Airplane |, then a slider module.
    readonly property var grid: [
        {x: 0, y: 0, w: 139, h: 63},      // 0 wifi
        {x: 152, y: 0, w: 139, h: 63},    // 1 dnd
        {x: 0, y: 76, w: 139, h: 63},     // 2 bluetooth
        {x: 200, y: 120, w: 40, h: 30},   // 3 transport button (inside the 2x2 at x 152, y 76)
        {x: 0, y: 152, w: 139, h: 63},    // 4 airplane
        {x: 10, y: 228, w: 20, h: 20},    // 5 mute
        {x: 40, y: 228, w: 200, h: 20},   // 6 slider
        {x: 250, y: 228, w: 20, h: 20}    // 7 chevron
    ]

    function test_navTargetVertical() {
        compare(Model.navTarget(grid, 0, 0, 1), 2);
        compare(Model.navTarget(grid, 2, 0, 1), 4);
        compare(Model.navTarget(grid, 1, 0, 1), 3);
        compare(Model.navTarget(grid, 4, 0, 1), 5);
        compare(Model.navTarget(grid, 6, 0, -1), 4);
        compare(Model.navTarget(grid, 0, 0, -1), -1);
        compare(Model.navTarget(grid, 7, 0, 1), -1);
    }

    function test_navTargetHorizontal() {
        compare(Model.navTarget(grid, 0, 1, 0), 1);
        compare(Model.navTarget(grid, 1, -1, 0), 0);
        compare(Model.navTarget(grid, 5, 1, 0), 6);
        compare(Model.navTarget(grid, 6, 1, 0), 7);
        compare(Model.navTarget(grid, 4, 1, 0), -1);
        compare(Model.navTarget(grid, 0, -1, 0), -1);
        compare(Model.navTarget(grid, 99, 1, 0), -1);
    }

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    // Quick Settings opens without building what it does not show (audit note): each detail section (Wi-Fi, Bluetooth, Sound,
    // Appearance) is a Loader active only while it is the opened one, and the whole panel is made once in the background
    // after start (its types compiled before the first click), then let go.
    function test_sectionsBuiltWhenOpened() {
        const cc = source("shell/overlay/ControlCenter.qml");
        for (const pair of [["wifi", "WifiList"], ["bluetooth", "BluetoothList"], ["sound", "SoundList"], ["appearance", "AppearanceSection"]]) {
            const re = new RegExp("Loader \\{\\s*width: parent.width\\s*active: root.expanded === \"" + pair[0] + "\"\\s*visible: active\\s*sourceComponent: " + pair[1] + " \\{\\}");
            verify(re.test(cc), pair[1] + " is made only while open");
        }
        const overlay = source("shell/overlay/Overlay.qml");
        const pre = overlay.substring(overlay.indexOf("id: prewarm\n"));
        verify(pre.indexOf("asynchronous: true") >= 0 && pre.indexOf("sourceComponent: controlCenter") >= 0, "made in the background");
        verify(pre.indexOf("onLoaded: Qt.callLater(() => prewarm.active = false)") >= 0, "and let go");
        verify(/id: prewarmDelay[\s\S]{0,200}win\.modelData === Quickshell\.screens\[0\]/.test(overlay), "once, on the first output");
    }
}
