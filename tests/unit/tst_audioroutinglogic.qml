import QtQuick
import QtTest
import "../../shell/services/AudioRoutingLogic.js" as Logic

// ADR-0047 part A: the automatic output routing state machine (shell/services/AudioRoutingLogic.js).
TestCase {
    id: testCase
    name: "AudioRoutingLogic"

    // PipeWire property maps of typical outputs (node, device).
    readonly property var speakers: Logic.describe({"node.name": "alsa_output.pci-0000_00_1f.3.analog-stereo", "node.description": "Built-in Audio", "device.api": "alsa", "device.bus": "pci", "priority.session": "1000"}, {"device.form-factor": "internal"})
    readonly property var budsNode: ({"node.name": "bluez_output.AA_BB_CC_DD_EE_01.1", "node.description": "Buds", "device.api": "bluez5", "api.bluez5.address": "aa:bb:cc:dd:ee:01", "priority.session": "1010"})
    readonly property var buds: Logic.describe(budsNode, {"device.form-factor": "headphone"})
    readonly property var speakerBt: Logic.describe({"node.name": "bluez_output.AA_BB_CC_DD_EE_02.1", "node.description": "Party Speaker", "device.api": "bluez5"}, {"device.form-factor": "speaker"})
    readonly property var usbHeadset: Logic.describe({"node.name": "alsa_output.usb-Acme_Headset_123-00.analog-stereo", "node.description": "Acme Headset", "device.api": "alsa", "device.bus": "usb", "device.icon-name": "audio-card-analog", "priority.session": "1050"}, {"device.vendor.id": "0x0D8C", "device.product.id": "0x0014", "device.serial": "123", "device.form-factor": "headset", "device.icon-name": "audio-headset"})
    readonly property var usbCard: Logic.describe({"node.name": "alsa_output.usb-Generic_USB_Audio-00.analog-stereo", "node.description": "USB Audio", "device.api": "alsa", "device.bus": "usb"}, {"device.vendor.id": "0x1234", "device.product.id": "0x5678"})
    readonly property var hdmi: Logic.describe({"node.name": "alsa_output.pci-0000_01_00.1.hdmi-stereo", "node.description": "Monitor", "device.api": "alsa", "device.profile.name": "hdmi-stereo"}, null)
    readonly property var airplay: Logic.describe({"node.name": "raop_sink.living-room.local.192.168.1.5.7000", "node.description": "Living Room", "raop.ip": "192.168.1.5"}, null)
    readonly property var virtualSink: Logic.describe({"node.name": "easyeffects_sink", "node.description": "Easy Effects Sink"}, null)

    // A router that started at 0 with the speakers as the default, past its start-up grace.
    function running(extra) {
        const st = Logic.create(null);
        Logic.start(st, [speakers].concat(extra || []), speakers.node, 0);
        return st;
    }

    readonly property int t0: Logic.STARTUP_GRACE_MS + 10000

    function switches(actions) {
        return actions.filter(a => a.type === "switch");
    }

    function notes(actions, event) {
        return actions.filter(a => a.type === "note" && a.event === event);
    }

    // ---- Classification ----

    function test_classification() {
        verify(!speakers.takesSound);
        verify(!speakers.virtual && !speakers.network && !speakers.bluetooth);
        verify(buds.bluetooth && buds.personal && buds.takesSound);
        verify(speakerBt.bluetooth && !speakerBt.personal && speakerBt.takesSound, "any Bluetooth audio takes the sound");
        verify(usbHeadset.personal && usbHeadset.takesSound, "the device's headset icon counts though the node's icon is generic");
        verify(!usbCard.takesSound && !usbCard.personal);
        verify(hdmi.display && !hdmi.takesSound);
        verify(airplay.network && !airplay.takesSound);
        verify(virtualSink.virtual && !virtualSink.takesSound);
        compare(usbHeadset.priority, 1050);
        compare(speakers.name, "Built-in Audio");
    }

    function test_personalFromNodeFormFactor() {
        // WirePlumber 0.5.16 copies device.form-factor to the node: enough without the device.
        const o = Logic.describe({"node.name": "alsa_output.usb-X-00.analog-stereo", "device.api": "alsa", "device.bus": "usb", "device.form-factor": "headphone"}, null);
        verify(o.personal && o.takesSound);
    }

    function test_displayByIconOrDpName() {
        verify(Logic.describe({"node.name": "alsa_output.pci-0000_00_1f.3.hdmi-stereo-extra1", "device.api": "alsa"}, null).display);
        verify(Logic.describe({"node.name": "alsa_output.pci-1.dp-stereo", "device.api": "alsa"}, null).display);
        verify(Logic.describe({"node.name": "alsa_output.x", "device.api": "alsa"}, {"device.icon_name": "video-display"}).display);
        verify(!Logic.describe({"node.name": "alsa_output.x.analog-stereo", "device.api": "alsa"}, null).display);
    }

    function test_networkByPropOrPrefix() {
        verify(Logic.describe({"node.name": "tunnel.host.sink", "device.api": "alsa"}, null).network);
        verify(Logic.describe({"node.name": "x", "node.network": "true"}, null).network);
        verify(Logic.describe({"node.name": "x", "pulse.server.address": "tcp:host"}, null).network);
        verify(!Logic.describe({"node.name": "x", "device.api": "alsa"}, null).network);
    }

    function test_deviceKeys() {
        compare(buds.key, "bluez:AA:BB:CC:DD:EE:01");
        // From the node name when the address property is missing.
        compare(Logic.describe({"node.name": "bluez_output.aa_bb_cc_dd_ee_03.1", "device.api": "bluez5"}, null).key, "bluez:AA:BB:CC:DD:EE:03");
        compare(usbHeadset.key, "usb:0x0d8c:0x0014:123");
        compare(usbCard.key, "usb:0x1234:0x5678");
        // A USB node without its device's ids falls back to its node name (built from the card's udev identity).
        compare(Logic.describe({"node.name": "alsa_output.usb-Y-00.analog-stereo", "device.api": "alsa", "device.bus": "usb"}, null).key, "node:alsa_output.usb-Y-00.analog-stereo");
        compare(speakers.key, "node:alsa_output.pci-0000_00_1f.3.analog-stereo");
        compare(airplay.key, "network:raop_sink.living-room.local.192.168.1.5.7000");
        // Two Bluetooth profiles of one device share the key.
        compare(Logic.describe({"node.name": "bluez_output.AA_BB_CC_DD_EE_01.2", "device.api": "bluez5"}, null).key, buds.key);
    }

    // ---- Start-up grace ----

    function test_presentAtStartChangesNothing() {
        const st = Logic.create(null);
        Logic.start(st, [speakers, buds], speakers.node, 0);
        compare(Logic.nextDeadline(st), null);
        compare(Logic.tick(st, 60000).length, 0);
    }

    function test_arrivalDuringGraceChangesNothing() {
        const st = running();
        const a = Logic.added(st, buds, Logic.STARTUP_GRACE_MS - 1);
        compare(notes(a, "kept").length, 1);
        compare(Logic.nextDeadline(st), null);
        compare(switches(Logic.tick(st, 60000)).length, 0);
    }

    function test_noStartYetIsGrace() {
        const st = Logic.create(null);
        Logic.added(st, buds, 100000);
        compare(Logic.nextDeadline(st), null);
    }

    // ---- Arrivals ----

    function test_headphonesTakeTheSoundAfterSettling() {
        const st = running();
        compare(Logic.added(st, buds, t0).length, 0);
        compare(Logic.nextDeadline(st), t0 + Logic.SETTLE_MS);
        compare(switches(Logic.tick(st, t0 + Logic.SETTLE_MS - 1)).length, 0);
        const s = switches(Logic.tick(st, t0 + Logic.SETTLE_MS));
        compare(s.length, 1);
        compare(s[0].node, buds.node);
        compare(Logic.nextDeadline(st), null);
        // Our own switch reported back is not a person's choice.
        compare(Logic.defaultChanged(st, buds.node, t0 + Logic.SETTLE_MS + 50).length, 0);
        compare(Logic.nextDeadline(st), null);
    }

    function test_bluetoothSpeakerAndUsbHeadsetTakeTheSound() {
        for (const out of [speakerBt, usbHeadset]) {
            const st = running();
            Logic.added(st, out, t0);
            compare(switches(Logic.tick(st, t0 + Logic.SETTLE_MS))[0].node, out.node);
        }
    }

    function test_othersNeverTakeTheSound() {
        for (const out of [usbCard, hdmi, airplay, virtualSink]) {
            const st = running();
            Logic.added(st, out, t0);
            const a = Logic.tick(st, t0 + Logic.MAX_SETTLE_MS);
            compare(switches(a).length, 0, out.node);
        }
        // A network or virtual output is not even an arrival.
        const st = running();
        Logic.added(st, airplay, t0);
        Logic.added(st, virtualSink, t0);
        compare(Logic.nextDeadline(st), null);
        // A display and a USB card are, and are logged as kept.
        Logic.added(st, hdmi, t0);
        compare(notes(Logic.tick(st, t0 + Logic.SETTLE_MS), "kept").length, 1);
    }

    function test_burstSettlesTogetherAndIsCapped() {
        const st = running();
        Logic.added(st, hdmi, t0);
        Logic.added(st, usbCard, t0 + 1500);
        // Both wait for 2 s after the last arrival.
        compare(Logic.nextDeadline(st), t0 + 1500 + Logic.SETTLE_MS);
        // A stream of arrivals cannot postpone past the first's cap.
        let t = t0 + 1500;
        for (let i = 0; i < 10; i++) {
            t += 1500;
            Logic.added(st, Logic.describe({"node.name": "alsa_output.extra" + i + ".analog-stereo", "device.api": "alsa"}, null), t);
        }
        // hdmi's due is capped at its first + 8 s.
        compare(Logic.nextDeadline(st), t0 + Logic.MAX_SETTLE_MS);
    }

    function test_burstChoosesHighestPriorityTaker() {
        const st = running();
        Logic.added(st, buds, t0);
        Logic.added(st, usbHeadset, t0 + 100);
        Logic.added(st, hdmi, t0 + 200);
        const a = Logic.tick(st, t0 + 200 + Logic.SETTLE_MS);
        const s = switches(a);
        compare(s.length, 1);
        compare(s[0].node, usbHeadset.node, "priority 1050 beats 1010");
        compare(notes(a, "kept").length, 2, "the other taker and the display are logged");
    }

    function test_alreadyTheOutput() {
        // WirePlumber restored the device itself before the decision.
        const st = running();
        Logic.added(st, buds, t0);
        compare(Logic.defaultChanged(st, buds.node, t0 + 300).length, 0);
        const a = Logic.tick(st, t0 + Logic.SETTLE_MS);
        compare(switches(a).length, 0);
        compare(notes(a, "kept")[0].reason, "already the output");
    }

    function test_deviceLeavingBeforeDecisionIsDropped() {
        const st = running();
        Logic.added(st, buds, t0);
        Logic.removed(st, buds.node, t0 + 500, "");
        compare(Logic.nextDeadline(st), null);
        compare(Logic.tick(st, t0 + 5000).length, 0);
    }

    function test_profileSwitchIsSameConnection() {
        const st = running();
        Logic.added(st, buds, t0);
        Logic.tick(st, t0 + Logic.SETTLE_MS);
        Logic.defaultChanged(st, buds.node, t0 + Logic.SETTLE_MS + 10);
        // A2DP -> HFP: the node leaves and another of the same device comes back.
        const hfp = Logic.describe({"node.name": "bluez_output.AA_BB_CC_DD_EE_01.2", "device.api": "bluez5"}, {"device.form-factor": "headphone"});
        const t = t0 + 60000;
        Logic.removed(st, buds.node, t, buds.node);
        compare(Logic.added(st, hfp, t + 500).length, 0);
        compare(Logic.nextDeadline(st), null, "not a new arrival");
        // Much later, a real reconnection is one again.
        Logic.removed(st, hfp.node, t + 1000, hfp.node);
        Logic.added(st, buds, t + 1000 + Logic.RECONNECT_MS + 1);
        verify(Logic.nextDeadline(st) !== null);
    }

    function test_secondNodeOfConnectedDevice() {
        const st = running();
        Logic.added(st, buds, t0);
        const other = Logic.describe({"node.name": "bluez_output.AA_BB_CC_DD_EE_01.9", "device.api": "bluez5"}, null);
        Logic.added(st, other, t0 + 100);
        // One pending decision for the device.
        compare(switches(Logic.tick(st, t0 + 100 + Logic.SETTLE_MS)).length, 1);
        // Removing one of its nodes is not the device leaving.
        Logic.removed(st, other.node, t0 + 5000, "");
        verify(st.connected[buds.key] !== undefined);
    }

    function test_updatedRekeysTheConnection() {
        // The node is first seen without its device's properties, then with them.
        const st = running();
        const bare = Logic.describe({"node.name": usbHeadset.node, "device.api": "alsa", "device.bus": "usb"}, null);
        verify(!bare.takesSound);
        Logic.added(st, bare, t0);
        Logic.updated(st, usbHeadset, t0 + 50);
        verify(st.connected[bare.key] === undefined);
        compare(st.connected[usbHeadset.key], t0);
        compare(switches(Logic.tick(st, t0 + Logic.SETTLE_MS))[0].node, usbHeadset.node);
    }

    function test_updatedKeepsUnchangedKeyAndNeverArrives() {
        const st = running();
        Logic.added(st, buds, t0);
        Logic.tick(st, t0 + Logic.SETTLE_MS);
        // The device's properties arrive later: same key, no new decision.
        compare(Logic.updated(st, buds, t0 + 5000).length, 0);
        compare(Logic.nextDeadline(st), null);
        // updated() of an unknown node is an arrival.
        Logic.updated(st, usbHeadset, t0 + 6000);
        verify(Logic.nextDeadline(st) !== null);
    }

    function test_deviceProps() {
        const dump = JSON.stringify([
            {id: 57, type: "PipeWire:Interface:Node", info: {props: {"object.serial": "57"}}},
            {id: 57, type: "PipeWire:Interface:Device", info: {props: {"device.vendor.id": "0x0d8c"}}},
            {id: 12, type: "PipeWire:Interface:Device", info: {props: {"device.vendor.id": "0xffff"}}}
        ]);
        compare(Logic.deviceProps(dump, 57)["device.vendor.id"], "0x0d8c");
        compare(Logic.deviceProps(dump, 99), null);
        compare(Logic.deviceProps("not json", 57), null);
        compare(Logic.deviceProps("{}", 57), null);
        compare(Logic.deviceProps(JSON.stringify([{id: 57, type: "PipeWire:Interface:Device"}]), 57), null);
    }

    // ---- Remembered choices ----

    // Buds connected and auto-selected at t0; returns the time after the switch was reported.
    function connected(st) {
        Logic.added(st, buds, t0);
        Logic.tick(st, t0 + Logic.SETTLE_MS);
        Logic.defaultChanged(st, buds.node, t0 + Logic.SETTLE_MS + 10);
        return t0 + Logic.SETTLE_MS + 10;
    }

    function test_movingAwayIsRemembered() {
        const st = running();
        const t = connected(st) + 20000;
        compare(Logic.defaultChanged(st, speakers.node, t).length, 0);
        compare(Logic.nextDeadline(st), t + Logic.MANUAL_WINDOW_MS);
        const a = Logic.tick(st, t + Logic.MANUAL_WINDOW_MS);
        compare(notes(a, "remembered").length, 1);
        verify(st.dirty);
        compare(st.memory.devices[buds.key].auto, false);
        // Next connection: kept on the speakers.
        Logic.removed(st, buds.node, t + 30000, speakers.node);
        Logic.added(st, buds, t + 60000);
        const b = Logic.tick(st, t + 60000 + Logic.SETTLE_MS);
        compare(switches(b).length, 0);
        compare(notes(b, "kept")[0].reason, "the sound was moved away from it last time");
    }

    function test_unplugIsNotAChoice() {
        const st = running();
        const t = connected(st) + 20000;
        // WirePlumber moves the default when the buds leave (reported before or after the removal).
        Logic.defaultChanged(st, speakers.node, t);
        Logic.removed(st, buds.node, t + 200, buds.node);
        compare(Logic.tick(st, t + Logic.MANUAL_WINDOW_MS).length, 0);
        verify(!st.dirty);
        verify(st.memory.devices[buds.key] === undefined);
    }

    function test_removalWithConfiguredDefaultRecordsTheChoice() {
        // The default change was never reported, but WirePlumber's configured default names the speakers at removal.
        const st = running();
        const t = connected(st) + 20000;
        const a = Logic.removed(st, buds.node, t, speakers.node);
        compare(notes(a, "remembered").length, 1);
        compare(st.memory.devices[buds.key].auto, false);
        // Unknown configured default: nothing learnt.
        const st2 = running();
        const t2 = connected(st2) + 20000;
        compare(Logic.removed(st2, buds.node, t2, "").length, 0);
        verify(st2.memory.devices[buds.key] === undefined);
    }

    function test_wirePlumberRestoreIsNotAChoice() {
        // The buds have the sound; a USB headset the person chose before comes back and WirePlumber restores it at once.
        const st = running();
        const t = connected(st) + 20000;
        Logic.added(st, usbHeadset, t);
        Logic.defaultChanged(st, usbHeadset.node, t + 300);
        compare(Logic.tick(st, t + 300 + Logic.MANUAL_WINDOW_MS).filter(a => a.event === "remembered").length, 0);
        verify(st.memory.devices[buds.key] === undefined);
    }

    // Review of ADR-0047 A (MAJOR 1): earbuds A take the sound, a USB headset B connects and the router switches to it, then
    // A is switched off: WirePlumber's configured default is B because the router wrote it, not because the person chose.
    function test_routerSwitchIsNotAPersonsChoice() {
        const st = running();
        const t = connected(st) + 20000;
        Logic.added(st, usbHeadset, t);
        compare(switches(Logic.tick(st, t + Logic.SETTLE_MS))[0].node, usbHeadset.node);
        compare(Logic.defaultChanged(st, usbHeadset.node, t + Logic.SETTLE_MS + 10).length, 0);
        // Our own switch away from A is not a move away from it (the manual window passes).
        compare(notes(Logic.tick(st, t + Logic.SETTLE_MS + 10 + Logic.MANUAL_WINDOW_MS), "remembered").length, 0);
        // A leaves while the configured default is the router's choice.
        compare(Logic.removed(st, buds.node, t + 30000, usbHeadset.node).length, 0);
        verify(st.memory.devices[buds.key] === undefined, "A still takes the sound next time");
        verify(!st.dirty);
        // A comes back later: it takes the sound again.
        Logic.added(st, buds, t + 90000);
        compare(switches(Logic.tick(st, t + 90000 + Logic.SETTLE_MS))[0].node, buds.node);
    }

    // The same, when A leaves before PipeWire reported the router's switch (the default is still A as far as the router knows).
    function test_routerSwitchNotYetReported() {
        const st = running();
        const t = connected(st) + 20000;
        Logic.added(st, usbHeadset, t);
        compare(switches(Logic.tick(st, t + Logic.SETTLE_MS)).length, 1);
        compare(Logic.removed(st, buds.node, t + Logic.SETTLE_MS + 5, usbHeadset.node).length, 0);
        verify(st.memory.devices[buds.key] === undefined);
    }

    // The router's last switch is forgotten at the person's first default change: a later configured default naming that node
    // again is the person's choice (counter-review NIT: the clearing of `routed` in defaultChanged).
    function test_personsChangeForgetsTheRoutersSwitch() {
        const st = running();
        const t = connected(st) + 20000;
        Logic.added(st, usbHeadset, t);
        compare(switches(Logic.tick(st, t + Logic.SETTLE_MS))[0].node, usbHeadset.node);
        Logic.defaultChanged(st, usbHeadset.node, t + Logic.SETTLE_MS + 10);
        // The person goes back to A, then picks the headset B; A leaves before that change is reported.
        Logic.defaultChanged(st, buds.node, t + 10000);
        Logic.tick(st, t + 10000 + Logic.MANUAL_WINDOW_MS);
        const a = Logic.removed(st, buds.node, t + 20000, usbHeadset.node);
        compare(notes(a, "remembered").length, 1, "the person's choice of B is not the router's old switch");
        compare(st.memory.devices[buds.key].auto, false);
    }

    // Once the person picks another output, the router's choice is no longer what the configured default says.
    function test_personsChoiceAfterRouterSwitchCounts() {
        const st = running();
        const t = connected(st) + 20000;
        Logic.added(st, usbHeadset, t);
        Logic.tick(st, t + Logic.SETTLE_MS);
        Logic.defaultChanged(st, usbHeadset.node, t + Logic.SETTLE_MS + 10);
        // The person picks the speakers, then A leaves with the speakers configured: A was moved away from.
        Logic.defaultChanged(st, speakers.node, t + 10000);
        Logic.tick(st, t + 10000 + Logic.MANUAL_WINDOW_MS);
        compare(st.memory.devices[usbHeadset.key].auto, false, "moving away from the headset is remembered");
        compare(notes(Logic.removed(st, buds.node, t + 20000, speakers.node), "remembered").length, 0,
                "the person moved away from the headset, not from A, which no longer had the sound");
        verify(st.memory.devices[buds.key] === undefined);
    }

    // A device that never had the sound during its connection learns nothing when it leaves (MINOR 2: hadSound).
    function test_deviceThatNeverHadTheSoundLearnsNothing() {
        const st = Logic.create(null);
        Logic.start(st, [speakers, buds], speakers.node, 0);
        compare(Logic.removed(st, buds.node, t0, speakers.node).length, 0);
        verify(st.memory.devices[buds.key] === undefined);
        verify(!st.dirty);
        // Remembered as moved away from, connected, never the default, leaving with itself configured (WirePlumber did not
        // restore it): still remembered.
        const st2 = Logic.create({devices: {"bluez:AA:BB:CC:DD:EE:01": {auto: false, name: "Buds", at: 1}}});
        Logic.start(st2, [speakers], speakers.node, 0);
        Logic.added(st2, buds, t0);
        Logic.tick(st2, t0 + Logic.SETTLE_MS);
        compare(Logic.removed(st2, buds.node, t0 + 5000, buds.node).length, 0);
        compare(st2.memory.devices[buds.key].auto, false);
    }

    // Two takers in a row (MINOR 2: the router's own switch must not start the away check of the device it moved from).
    function test_twoTakersInARow() {
        const st = running();
        const t = connected(st) + 20000;
        Logic.added(st, speakerBt, t);
        compare(switches(Logic.tick(st, t + Logic.SETTLE_MS))[0].node, speakerBt.node);
        Logic.defaultChanged(st, speakerBt.node, t + Logic.SETTLE_MS + 5);
        compare(Logic.nextDeadline(st), null, "no away check after the router's own switch");
        Logic.tick(st, t + 60000);
        verify(st.memory.devices[buds.key] === undefined);
    }

    function test_choosingAgainRestores() {
        const st = Logic.create({devices: {"bluez:AA:BB:CC:DD:EE:01": {auto: false, name: "Buds", at: 1}}});
        Logic.start(st, [speakers], speakers.node, 0);
        Logic.added(st, buds, t0);
        compare(switches(Logic.tick(st, t0 + Logic.SETTLE_MS)).length, 0);
        // The person picks the buds well after they arrived.
        const a = Logic.defaultChanged(st, buds.node, t0 + 10000);
        compare(notes(a, "remembered").length, 1);
        verify(st.memory.devices[buds.key] === undefined);
        verify(st.dirty);
    }

    function test_restoreWithinWindowDoesNotReenable() {
        const st = Logic.create({devices: {"bluez:AA:BB:CC:DD:EE:01": {auto: false, name: "Buds", at: 1}}});
        Logic.start(st, [speakers], speakers.node, 0);
        Logic.added(st, buds, t0);
        compare(Logic.defaultChanged(st, buds.node, t0 + Logic.RESTORE_WINDOW_MS).length, 0);
        compare(st.memory.devices[buds.key].auto, false);
    }

    function test_movingAwayFromNonTakerIsNotRemembered() {
        const st = running([usbCard]);
        Logic.defaultChanged(st, usbCard.node, t0);
        Logic.defaultChanged(st, speakers.node, t0 + 10000);
        compare(Logic.nextDeadline(st), null);
    }

    function test_movedBackWithinWindow() {
        const st = running();
        const t = connected(st) + 20000;
        Logic.defaultChanged(st, speakers.node, t);
        Logic.defaultChanged(st, buds.node, t + 500);
        compare(notes(Logic.tick(st, t + Logic.MANUAL_WINDOW_MS + 500), "remembered").length, 0);
    }

    function test_deadlineIsTheEarliest() {
        const st = running();
        const t = connected(st) + 20000;
        Logic.defaultChanged(st, speakers.node, t);
        Logic.added(st, hdmi, t + 100);
        compare(Logic.nextDeadline(st), t + Logic.MANUAL_WINDOW_MS);
    }

    // ---- Persistence ----

    function test_parseMemory() {
        compare(Object.keys(Logic.parseMemory("").devices).length, 0);
        compare(Object.keys(Logic.parseMemory("{bad").devices).length, 0);
        compare(Object.keys(Logic.parseMemory("[]").devices).length, 0);
        compare(Object.keys(Logic.parseMemory('{"devices": {"bluez:A": {"auto": false}}}').devices).length, 0, "no version");
        const newer = Logic.parseMemory('{"version": 2, "devices": {"bluez:A": {"auto": false}}}');
        verify(newer.readOnly);
        compare(Object.keys(newer.devices).length, 0);
        const m = Logic.parseMemory(JSON.stringify({version: 1, devices: {
            "bluez:AA": {auto: false, name: "Buds", at: 5},
            "usb:1:2": {auto: true, name: "kept out"},
            "weird": {auto: false},
            "node:x": {auto: false, name: 7}
        }}));
        verify(!m.readOnly);
        compare(Object.keys(m.devices).sort(), ["bluez:AA", "node:x"]);
        compare(m.devices["bluez:AA"].name, "Buds");
        compare(m.devices["node:x"].name, "");
    }

    function test_serializeRoundTripAndCap() {
        const devices = {};
        for (let i = 0; i < Logic.MEMORY_LIMIT + 10; i++)
            devices["node:n" + i] = {auto: false, name: "N" + i, at: i};
        const text = Logic.serializeMemory({devices: devices});
        const back = JSON.parse(text);
        compare(back.version, 1);
        compare(Object.keys(back.devices).length, Logic.MEMORY_LIMIT);
        verify(back.devices["node:n0"] === undefined, "the oldest are dropped");
        verify(back.devices["node:n" + (Logic.MEMORY_LIMIT + 9)] !== undefined);
        compare(Object.keys(Logic.parseMemory(text).devices).length, Logic.MEMORY_LIMIT);
    }

    function test_noteLine() {
        compare(Logic.describeNote({event: "switched", name: "Buds", key: "bluez:A0:B1:C2:D3:E4:F5", reason: "r"}),
                "audio routing: switched Buds (bluez:XX:XX:XX:XX:XX:XX): r");
    }

    // rc7 audit R7-SEC-04: the journal never gets a hardware identifier (the key Audio.qml logs through describeNote).
    function test_noteLineCarriesNoHardwareIdentifier() {
        const line = Logic.describeNote({event: "connected", name: "USB Headset", key: "usb:0x0d8c:0x0014:SN-7Y3K9QX2", reason: "r"});
        compare(line, "audio routing: connected USB Headset (usb:0x0d8c:0x0014): r");
        verify(line.indexOf("SN-7Y3K9QX2") < 0);
        compare(Logic.logKey("usb:0x1234:0x5678"), "usb:0x1234:0x5678", "a USB device without a serial keeps its ids");
        compare(Logic.logKey("node:alsa_output.usb-Focusrite_Scarlett_2i2_USB_Y8ABCDE12345-00.HiFi__Line__sink"),
                "node:alsa_output.usb-[usb device]-00.HiFi__Line__sink");
        compare(Logic.logKey("node:alsa_output.pci-0000_00_1f.3.analog-stereo"), "node:alsa_output.pci-0000_00_1f.3.analog-stereo");
        compare(Logic.logKey("network:tunnel.sink"), "network:tunnel.sink");
        // The key the routing keeps is the whole one: two identical headsets stay two devices.
        compare(usbHeadset.key, "usb:0x0d8c:0x0014:123");
    }
}
