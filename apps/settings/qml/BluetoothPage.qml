pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Bluetooth as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Bluetooth): a header group (the switch, then
// the computer's Bluetooth name), My Devices (the paired devices: a click connects or disconnects, (i) opens the device's sheet
// with Forget This Device…) and Nearby Devices (found while the pane is open: Connect pairs, trusts and connects; Settings
// registers no pairing agent, so a device that needs a PIN says so). BlueZ over D-Bus: one read-only state (`bt.state`), every
// action through SystemService, so never in a dev session (and no discovery there).
SettingsPage {
    id: root

    required property var backend
    required property var system

    // Main.qml opens the sheets and hands the answers back (connectDevice, forget).
    signal infoRequested(var device)
    signal forgetRequested(var device)

    title: qsTr("Bluetooth")

    property bool answered: false
    // A reading is on its way (the timer does not ask again meanwhile: a slow service would stack readings until the
    // Backend's queue refuses those of every other pane), and how many readings in a row brought no answer: the first keeps
    // what was read (one timeout must not empty the pane), the second says the service is not there.
    property bool asking: false
    property int misses: 0
    property var controller: ({present: false, powered: false, discovering: false, alias: ""})
    property var devices: []
    property var nearby: []
    // MAC address being connected, disconnected or paired, until the action ends.
    property string pending: ""
    // This pane started a discovery (it stops it when it closes).
    property bool searching: false

    readonly property bool on: root.controller.present && root.controller.powered

    // The rows of the lists, keyed by MAC address: a refresh updates, inserts and removes rows in place.
    ListModel {
        id: deviceModel
    }
    ListModel {
        id: nearbyModel
    }

    onDevicesChanged: System.syncModel(deviceModel, root.devices, "mac")
    onNearbyChanged: System.syncModel(nearbyModel, root.nearby, "mac")
    onOnChanged: root.discover(root.on)

    function refresh(): void {
        root.asking = true;
        root.system.queryBus("bt.state", "bt.state");
    }

    function discover(on: bool): void {
        // The service can go first when the window closes: BlueZ then ends the discovery with the connection.
        if (!root.system || typeof root.system.act !== "function" || root.system.dev || on === root.searching)
            return;
        if (root.system.act(on ? "bluetooth search" : "bluetooth stop searching", System.btDiscover(on), "bt.discover"))
            root.searching = on;
    }

    function deviceOf(mac: string): var {
        return root.devices.find(d => d.mac === mac) ?? null;
    }

    // A paired device: connect it, or disconnect it.
    function connectDevice(dev: var): void {
        root.pending = dev.mac;
        if (!root.system.act("bluetooth " + (dev.connected ? "disconnect" : "connect"), System.btConnect(dev.mac, !dev.connected), "bt.act"))
            root.pending = "";
    }

    // A nearby device: pair, trust and connect it.
    function pair(mac: string): void {
        root.pending = mac;
        if (!root.system.act("bluetooth pair", System.btPair(mac), "bt.act"))
            root.pending = "";
    }

    // ForgetDeviceSheet's answer.
    function forget(dev: var): void {
        root.system.act("bluetooth forget", System.btForget(dev.mac), "bt.act");
    }

    function statusOf(dev: var): string {
        if (root.pending === dev.mac)
            return dev.connected ? qsTr("Disconnecting…") : qsTr("Connecting…");
        return dev.connected ? qsTr("Connected") : qsTr("Not Connected");
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            switch (tag) {
            case "bt.state":
                {
                    root.asking = false;
                    if (!ok && root.answered && root.misses < 1) {
                        root.misses++;
                        break;
                    }
                    root.misses = ok ? 0 : root.misses;
                    const state = ok ? System.parseBtState(output) : null;
                    root.controller = state ? {present: state.present, powered: state.powered, discovering: state.discovering, alias: state.alias}
                                            : {present: false, powered: false, discovering: false, alias: ""};
                    root.devices = state ? state.devices : [];
                    root.nearby = state ? state.nearby : [];
                    root.answered = true;
                    // A search that did not start is asked for again, unless the adapter is searching already.
                    if (root.on && !root.searching && !root.controller.discovering)
                        root.discover(true);
                }
                break;
            case "bt.discover":
                // The search did not start: the pane is not searching, and the next reading asks again.
                if (!ok)
                    root.searching = false;
                break;
            case "bt.act":
                root.pending = "";
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
    Component.onDestruction: root.discover(false)

    SettingsGroup {
        footnote: root.answered && !root.controller.present ? qsTr("Bluetooth is not available: no adapter was found or the Bluetooth service is not running.") : ""

        HeaderRow {
            glyph: "bluetooth"
            title: qsTr("Bluetooth")
            text: qsTr("Connect accessories such as headphones, keyboards, mice and game controllers to this computer.")
            textSize: Tokens.settingsBtHeaderTextSize
            textLineHeight: Tokens.settingsBtHeaderTextLineHeight
            textBaseline: Tokens.settingsBtHeaderTextBaseline
            textBottom: Tokens.settingsBtHeaderBottom
            checked: root.controller.powered
            switchEnabled: root.controller.present
            onToggled: c => root.system.act("bluetooth " + (c ? "on" : "off"), System.btPower(c), "bt.act")
        }

        // The computer's Bluetooth name (macOS: "This Mac is discoverable as …").
        Item {
            id: note
            visible: root.on && root.controller.alias !== ""
            readonly property real contentTop: 1
            width: parent.width
            height: Math.round(noteText.y + noteText.baselineOffset + (noteText.lineCount - 1) * Tokens.settingsNoteLineHeight + Tokens.settingsNoteBottom)
            Accessible.role: Accessible.StaticText
            Accessible.name: noteText.text

            Rectangle {
                x: Tokens.settingsRowInset
                width: parent.width - 2 * Tokens.settingsRowInset
                height: Tokens.appsBorderWidth
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }

            Text {
                id: noteText
                textFormat: Text.PlainText
                x: Tokens.settingsRowInset
                y: note.contentTop + Tokens.settingsNoteBaseline - baselineOffset
                width: parent.width - 2 * Tokens.settingsRowInset
                wrapMode: Text.Wrap
                lineHeightMode: Text.FixedHeight
                lineHeight: Tokens.settingsNoteLineHeight
                text: qsTr("Other devices see this computer as “%1”.").arg(root.controller.alias)
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }
    }

    SettingsGroup {
        visible: root.on
        caption: qsTr("My Devices")

        Repeater {
            model: deviceModel

            delegate: BluetoothDeviceRow {
                id: row

                required property string mac
                required property string name
                required property bool connected
                required property string icon
                required battery

                readonly property var dev: ({mac: row.mac, name: row.name, connected: row.connected, icon: row.icon, battery: row.battery})

                title: row.name
                status: root.statusOf(row.dev)
                glyph: System.btGlyph(row.icon)
                onActivated: root.connectDevice(row.dev)
                onInfoRequested: root.infoRequested(row.dev)
            }
        }

        EmptyListRow {
            visible: deviceModel.count === 0
            text: qsTr("No paired devices")
        }
    }

    SettingsGroup {
        visible: root.on
        caption: qsTr("Nearby Devices")
        busy: root.controller.discovering

        Repeater {
            model: nearbyModel

            delegate: BluetoothDeviceRow {
                id: near

                required property string mac
                required property string name
                required property string icon

                nearby: true
                title: near.name
                glyph: System.btGlyph(near.icon)
                busy: root.pending === near.mac
                onConnectRequested: root.pair(near.mac)
            }
        }

        Item {
            visible: nearbyModel.count === 0
            width: parent.width
            height: Tokens.settingsEmptyListHeight
            Accessible.role: Accessible.StaticText
            Accessible.name: searchingText.text

            Text {
                id: searchingText
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: root.controller.discovering ? qsTr("Searching…") : qsTr("No devices found")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }
    }

    ErrorNote {
        system: root.system
        tag: "bt.act"
    }

    DevNote {
        system: root.system
    }
}
