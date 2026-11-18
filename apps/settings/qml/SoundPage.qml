pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Sound as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Sound): Output & Input, an Output / Input
// segmented control over the device table (Name, Type; the default device selected, a click or the arrow keys choose another),
// then the volume of that side (LevelRow) and Mute. PipeWire through `wpctl`: `wpctl status` is read, then `wpctl status -n` once a device
// is new (its node name gives the Type); default device, volume and mute change only through SystemService, so never in a dev
// session. Above it the macOS 27 "Sound Effects" group (ADR-0047 B-4): Alert sound (a pick plays it; the play button beside it
// plays it again), Play sound effects through, Alert volume (the alert plays once the drag rests), and the interface-sound and
// volume-feedback switches, all sound.* settings; previews run pw-play through SystemService (never in a dev session). No
// "Play sound on startup": Grassfield has no start-up sound.
SettingsPage {
    id: root

    required property var backend
    required property var system
    required property var store

    title: qsTr("Sound")

    // PipeWire node id -> node name of the outputs, from `wpctl status -n`.
    property var nodeNames: ({})
    readonly property string alert: root.store.value("sound.alert")
    readonly property real alertVolume: root.store.value("sound.alertVolume")
    readonly property string effectsOutput: root.store.value("sound.effectsOutput")
    // The outputs now: {node, text}, by node name.
    readonly property var outputs: {
        const out = [];
        for (const d of root.audio.sinks) {
            const node = root.nodeNames[d.id];
            if (node !== undefined && SoundEffects.NODE_NAME.test(node) && !out.some(o => o.node === node))
                out.push({node: node, text: d.name});
        }
        return out;
    }
    // "Play sound effects through": the selected output device, then each output; a remembered one that is not connected.
    readonly property var outputChoices: {
        const out = [{id: "", text: qsTr("Selected Sound Output Device")}].concat(root.outputs.map(o => ({id: o.node, text: o.text})));
        if (root.effectsOutput !== "" && !out.some(c => c.id === root.effectsOutput))
            out.push({id: root.effectsOutput, text: qsTr("Device not connected")});
        return out;
    }

    // The alert sound at a level through the chosen output while it is connected (the selected device otherwise).
    function preview(alert: string, level: real): void {
        const node = SoundEffects.target(root.effectsOutput, root.outputs.map(o => o.node));
        root.system.act("sound preview", SoundEffects.previewArgv(alert, level, node), "sound.preview");
    }

    property bool answered: false
    // A reading is on its way (the timer does not ask again meanwhile: a slow service would stack readings until the
    // Backend's queue refuses those of every other pane), and how many readings in a row brought no answer: the first keeps
    // what was read (one timeout must not empty the pane), the second says the service is not there.
    property bool asking: false
    property int misses: 0
    property var audio: ({sinks: [], sources: []})
    // PipeWire node id -> System.audioKind, from `wpctl status -n`.
    property var kinds: ({})
    // The ids the last `wpctl status -n` was asked for: a device whose kind it did not give is not asked about again.
    property var asked: ({})
    property bool naming: false
    // "output" or "input": the segmented control.
    property string side: "output"
    // The device being made the default, until the next reading.
    property int pending: -1

    readonly property var output: System.defaultOf(root.audio.sinks)
    readonly property var input: System.defaultOf(root.audio.sources)
    readonly property var current: root.side === "output" ? root.output : root.input
    readonly property bool available: root.audio.sinks.length > 0 || root.audio.sources.length > 0

    // The device rows, keyed by node id: a refresh updates, inserts and removes rows in place.
    ListModel {
        id: sinkModel
    }

    ListModel {
        id: sourceModel
    }

    function syncRows(): void {
        const rows = list => list.map(d => ({nodeId: d.id, name: d.name, kind: root.kinds[d.id] ?? "", isDefault: d.isDefault}));
        System.syncModel(sinkModel, rows(root.audio.sinks), "nodeId");
        System.syncModel(sourceModel, rows(root.audio.sources), "nodeId");
    }

    onAudioChanged: {
        root.syncRows();
        const ids = root.audio.sinks.concat(root.audio.sources).map(d => d.id);
        if (!root.naming && ids.some(id => root.kinds[id] === undefined && root.asked[id] === undefined)) {
            const asked = {};
            for (const id of ids)
                asked[id] = true;
            root.asked = asked;
            root.naming = true;
            root.system.query(System.QUERY.audioNames, "audio.names");
        }
    }

    onKindsChanged: root.syncRows()
    // A device being chosen belongs to the other side's table.
    onSideChanged: root.pending = -1

    function kindLabel(kind: string): string {
        switch (kind) {
        case "builtin":
            return qsTr("Built-in");
        case "usb":
            return qsTr("USB");
        case "bluetooth":
            return qsTr("Bluetooth");
        case "hdmi":
            return qsTr("HDMI or DisplayPort");
        case "digital":
            return qsTr("Digital");
        case "network":
            return qsTr("Network");
        case "virtual":
            return qsTr("Virtual");
        }
        return "";
    }

    function refresh(): void {
        root.asking = true;
        root.system.query(System.QUERY.audio, "audio.status");
    }

    function choose(nodeId: int): void {
        root.pending = nodeId;
        if (!root.system.act(root.side === "output" ? "output device" : "input device", System.setDefaultDevice(nodeId), "audio.act"))
            root.pending = -1;
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            switch (tag) {
            case "audio.status":
                root.asking = false;
                if (!ok && root.answered && root.misses < 1) {
                    root.misses++;
                    break;
                }
                root.misses = ok ? 0 : root.misses;
                root.answered = true;
                // A drag in progress keeps its own value; the next reading follows.
                if (!volume.busy)
                    root.audio = ok ? System.parseAudio(output) : {sinks: [], sources: []};
                break;
            case "audio.names":
                root.naming = false;
                if (ok) {
                    root.kinds = Object.assign({}, root.kinds, System.audioKinds(output));
                    root.nodeNames = Object.assign({}, root.nodeNames, System.audioNodeNames(output));
                }
                break;
            case "audio.act":
                root.pending = -1;
                root.refresh();
                break;
            }
        }
    }

    Timer {
        interval: Tokens.settingsSystemRefreshMs
        running: true
        repeat: true
        onTriggered: {
            if (!root.asking)
                root.refresh();
        }
    }

    Component.onCompleted: root.refresh()

    SettingsGroup {
        caption: qsTr("Sound Effects")

        SettingsRow {
            title: qsTr("Alert sound")

            ComboBox {
                anchors.verticalCenter: parent.verticalCenter
                inline: true
                accessibleName: qsTr("Alert sound")
                model: [{id: "meadow", text: qsTr("Meadow")}, {id: "dewdrop", text: qsTr("Dewdrop")}, {id: "reed", text: qsTr("Reed")},
                    {id: "lantern", text: qsTr("Lantern")}, {id: "ember", text: qsTr("Ember")}, {id: "thistle", text: qsTr("Thistle")}]
                value: root.alert
                onPicked: id => {
                    root.store.set("sound.alert", id);
                    root.preview(id, root.alertVolume);
                }
            }

            ToolButton {
                anchors.verticalCenter: parent.verticalCenter
                iconName: "media-play"
                accessibleName: qsTr("Play the alert sound")
                onClicked: root.preview(root.alert, root.alertVolume)
            }
        }

        SettingsRow {
            title: qsTr("Play sound effects through")

            ComboBox {
                anchors.verticalCenter: parent.verticalCenter
                inline: true
                accessibleName: qsTr("Play sound effects through")
                model: root.outputChoices
                value: root.effectsOutput
                onPicked: id => root.store.set("sound.effectsOutput", id)
            }
        }

        LevelRow {
            id: alertVolumeRow
            system: root.system
            title: qsTr("Alert volume")
            value: root.alertVolume
            what: "alert volume"
            // The setting, then the alert once the drag rests (macOS plays it at the new volume).
            property real rested: 0
            apply: v => {
                alertVolumeRow.rested = v;
                previewRest.restart();
                return root.store.set("sound.alertVolume", Math.round(v * 100) / 100);
            }
        }

        SettingsRow {
            title: qsTr("Play user interface sound effects")

            Toggle {
                accessibleName: qsTr("Play user interface sound effects")
                checked: root.store.value("sound.uiEffects") === true
                onToggled: c => root.store.set("sound.uiEffects", c)
            }
        }

        SettingsRow {
            title: qsTr("Play feedback when volume is changed")

            Toggle {
                accessibleName: qsTr("Play feedback when volume is changed")
                checked: root.store.value("sound.volumeFeedback") === true
                onToggled: c => root.store.set("sound.volumeFeedback", c)
            }
        }
    }

    Timer {
        id: previewRest
        interval: 400
        onTriggered: root.preview(root.alert, alertVolumeRow.rested)
    }

    SettingsGroup {
        visible: root.answered && !root.available
        footnote: qsTr("Sound is not available: PipeWire did not answer or no audio device was found.")
    }

    SettingsGroup {
        visible: root.available
        caption: qsTr("Output & Input")

        Item {
            width: parent.width
            height: Tokens.controlButtonHeight + 2 * Tokens.settingsRowInset

            SegmentedControl {
                x: Tokens.settingsRowInset
                y: Tokens.settingsRowInset
                width: parent.width - 2 * Tokens.settingsRowInset
                height: Tokens.controlButtonHeight
                fill: true
                prominent: true
                accessibleName: qsTr("Devices")
                model: [{id: "output", text: qsTr("Output")}, {id: "input", text: qsTr("Input")}]
                value: root.side
                onPicked: id => root.side = id
            }
        }

        SoundDeviceTable {
            model: root.side === "output" ? sinkModel : sourceModel
            accessibleName: root.side === "output" ? qsTr("Output devices") : qsTr("Input devices")
            emptyText: root.side === "output" ? qsTr("No output devices found") : qsTr("No input devices found")
            pending: root.pending
            kindLabel: kind => root.kindLabel(kind)
            roundBottom: true
            onChosen: nodeId => root.choose(nodeId)
        }
    }

    SettingsGroup {
        visible: root.available

        LevelRow {
            id: volume
            system: root.system
            title: root.side === "output" ? qsTr("Output volume") : qsTr("Input volume")
            lowGlyph: root.side === "output" ? "speaker" : "microphone"
            highGlyph: root.side === "output" ? "volume-3" : "microphone"
            lowGlyphSize: root.side === "output" ? Tokens.settingsSliderRowGlyphSize : Tokens.settingsSliderRowSmallGlyphSize
            settable: root.current !== null
            value: root.current ? root.current.volume : 0
            what: "volume"
            tag: "audio.act"
            command: v => System.setVolume(root.current ? root.current.id : -1, v)
        }

        SettingsRow {
            title: qsTr("Mute")

            Toggle {
                accessibleName: root.side === "output" ? qsTr("Mute output") : qsTr("Mute input")
                enabled: root.current !== null
                checked: root.current ? root.current.muted : false
                onToggled: c => root.system.act("mute", System.setMute(root.current ? root.current.id : -1, c), "audio.act")
            }
        }
    }

    ErrorNote {
        system: root.system
        tag: "audio.act"
    }

    DevNote {
        system: root.system
    }
}
