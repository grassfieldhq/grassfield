pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Network as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Network and VPN): each service a group of its own
// with its state, the connected ones and the Firewall first, the others under Other Services. NetworkManager over D-Bus, read
// only (`net.state`); Wi-Fi opens the Wi-Fi pane, an Ethernet service a sheet with its addresses (NetworkDetailsSheet, through
// Main.qml). The Firewall row shows ufw's or firewalld's state (ufw: its unit and ENABLED= of /etc/ufw/ufw.conf); changing it
// needs root and is not built.
SettingsPage {
    id: root

    required property var backend
    required property var system

    signal openRequested(string id)
    signal detailsRequested(string name, var device)

    title: qsTr("Network")

    property var net: null
    property bool answered: false
    // ufw's own switch (true, false or null when unknown).
    property var ufwEnabled: null

    readonly property bool firewallOn: root.net !== null && root.net.firewall.active && (root.net.firewall.name !== "ufw" || root.ufwEnabled === true)

    ListModel {
        id: activeModel
    }
    ListModel {
        id: otherModel
    }

    // The scalar fields of a service, for the models (the device itself stays in `state`).
    function row(service: var): var {
        return {sid: service.id, kind: service.kind, number: service.number, link: service.status};
    }

    function setState(st: var): void {
        root.net = st;
        root.answered = true;
        const services = System.networkServices(st, null);
        System.syncModel(activeModel, services.active.map(root.row), "sid");
        System.syncModel(otherModel, services.other.map(root.row), "sid");
        if (st && st.firewall.name === "ufw")
            root.ufwEnabled = System.ufwEnabled(root.backend.readText("/etc/ufw/ufw.conf").text);
    }

    function deviceOf(id: string): var {
        return root.net ? (root.net.devices.find(d => d.name === id) ?? null) : null;
    }

    function nameOf(kind: string, number: int): string {
        if (kind === "wifi")
            return qsTr("Wi-Fi");
        return number > 0 ? qsTr("Ethernet %1").arg(number) : qsTr("Ethernet");
    }

    function statusText(status: string): string {
        switch (status) {
        case "connected":
            return qsTr("Connected");
        case "connecting":
            return qsTr("Connecting…");
        case "unplugged":
            return qsTr("Cable unplugged");
        case "off":
            return qsTr("Off");
        }
        return qsTr("Not connected");
    }

    function dotOf(status: string): color {
        return status === "connected" ? Appearance.colors.statusOn : status === "connecting" ? Appearance.colors.statusWarn
            : status === "off" ? Appearance.windowSecondary : Appearance.colors.statusOff;
    }

    function open(id: string, kind: string, number: int): void {
        if (kind === "wifi")
            root.openRequested("wifi");
        else
            root.detailsRequested(root.nameOf(kind, number), root.deviceOf(id));
    }

    function refresh(): void {
        root.system.queryBus("net.state", "net.state");
    }

    Connections {
        target: root.backend
        ignoreUnknownSignals: true

        // A change on the system bus (Backend.busChanged, coalesced there): read again; a reading on its way reads once more after.
        function onBusChanged(what: string): void {
            if (what === "nm") {
                root.refresh();
            }
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "net.state")
                root.setState(ok ? System.parseNetState(output) : null);
        }
    }

    // A poll only while the system bus's change signals are not followed (Backend.followBus: no bus, a test's backend).
    Timer {
        interval: Tokens.settingsSystemRefreshMs
        running: root.backend.busSignals !== true
        repeat: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: {
        if (typeof root.backend.followBus === "function")
            root.backend.followBus("nm");
        root.refresh();
    }

    Repeater {
        model: activeModel

        delegate: ServiceRow {
            id: active
            required property string sid
            required property string kind
            required property int number
            required property string link
            text: root.nameOf(active.kind, active.number)
            glyph: active.kind === "wifi" ? "wifi-3" : "network-wired"
            status: root.statusText(active.link)
            dotColor: root.dotOf(active.link)
            onClicked: root.open(active.sid, active.kind, active.number)
        }
    }

    ServiceRow {
        visible: root.net !== null
        opens: false
        text: qsTr("Firewall")
        glyph: "shield"
        tileColor: "orange"
        status: root.net === null || root.net.firewall.name === "" ? qsTr("Not installed") : root.firewallOn ? qsTr("Active") : qsTr("Inactive")
        dotColor: root.firewallOn ? Appearance.colors.statusOn : Appearance.windowSecondary
    }

    SettingsGroup {
        visible: otherModel.count > 0
        caption: qsTr("Other Services")
        plain: true

        Column {
            width: parent.width
            spacing: Tokens.settingsGroupGap

            Repeater {
                model: otherModel

                delegate: ServiceRow {
                    id: other
                    required property string sid
                    required property string kind
                    required property int number
                    required property string link
                    text: root.nameOf(other.kind, other.number)
                    glyph: other.kind === "wifi" ? "wifi-3" : "network-wired"
                    status: root.statusText(other.link)
                    dotColor: root.dotOf(other.link)
                    onClicked: root.open(other.sid, other.kind, other.number)
                }
            }
        }
    }

    Text {
        textFormat: Text.PlainText
        visible: root.answered && root.net === null
        width: parent.width
        leftPadding: Tokens.settingsRowInset
        wrapMode: Text.Wrap
        text: qsTr("The network is not available: NetworkManager did not answer.")
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
    }
}
