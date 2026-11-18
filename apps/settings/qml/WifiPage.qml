pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Wi-Fi as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Wi-Fi): a header group (the switch, then the
// current network with Details…), Known Network (the saved networks in range, the current one checked) and Other Networks
// (with a spinner while it scans). NetworkManager over D-Bus: read as one JSON state (`wifi.state`; `net.state` once, when
// Details… is asked for), acted on only through SystemService, so never in a dev session. A click joins a network: a known one with its
// profile, an open one at once, a secured one after its password (WifiPasswordSheet, through Main.qml); the (…) menu has
// Connect or Disconnect, Details… and Forget This Network…. A failed action shows its reason under the lists (ErrorNote); a
// NetworkManager that does not answer shows the footnote.
SettingsPage {
    id: root

    required property var backend
    required property var system

    // Main.qml opens the sheets and hands the answers back (join, forget).
    signal passwordRequested(var net)
    signal forgetRequested(var net)
    signal detailsRequested(var net, var device)

    title: qsTr("Wi-Fi")

    // null: unknown or NetworkManager not answering.
    property var radio: null
    property bool answered: false
    // A reading is on its way (the timer does not ask again meanwhile: a slow service would stack readings until the
    // Backend's queue refuses those of every other pane), and how many readings in a row brought no answer: the first keeps
    // what was read (one timeout must not empty the pane), the second says the service is not there.
    property bool asking: false
    property int misses: 0
    property var networks: []
    // SSID hex -> UUID of the first saved profile with that SSID.
    property var known: ({})
    property var device: null
    // The network whose Details… were asked for, until `net.state` answers.
    property var detailsNet: null
    // Key of the network being joined, until the action ends.
    property string pending: ""
    // A scan was asked for a moment ago (the spinner beside Other Networks).
    property bool scanning: false
    // Why a click did nothing (an 802.1X or WEP network).
    property string notice: ""

    readonly property var current: root.networks.find(n => n.active) ?? null
    readonly property bool available: root.radio !== null
    readonly property bool listsShown: root.available && root.radio === true && root.device !== null

    // The rows of the two lists, keyed by SSID + security: a refresh updates, inserts and removes rows in place.
    ListModel {
        id: knownModel
    }
    ListModel {
        id: otherModel
    }

    function setNetworks(list: var): void {
        root.networks = list;
        const sections = System.wifiSections(list, root.known);
        System.syncModel(knownModel, sections.known, "key");
        System.syncModel(otherModel, sections.other, "key");
    }

    function setState(state: var): void {
        root.radio = state ? state.radio : null;
        root.device = state ? state.device : null;
        root.known = state ? state.known : {};
        root.setNetworks(state ? state.networks : []);
        root.answered = true;
    }

    // The row's fields as the plain network object the helpers take.
    function netOf(row: var): var {
        return {key: row.key, hex: row.hex, ssid: row.ssid, label: row.label, strength: row.strength, security: row.security, secured: row.secured,
            enterprise: row.enterprise, active: row.active, valid: row.valid};
    }

    function refresh(): void {
        root.asking = true;
        root.system.queryBus("wifi.state", "wifi.state");
    }

    // Details…: the addresses, band and link rate are read then (`net.state`), and the sheet opens with them.
    function showDetails(net: var): void {
        root.detailsNet = net;
        root.system.queryBus("net.state", "wifi.details");
    }

    function scan(): void {
        // NetworkManager scans on its own too; never in a dev session. Best effort and silent.
        if (root.system.dev || root.radio !== true)
            return;
        if (root.system.act("wifi scan", System.wifiScan(), "wifi.scan")) {
            root.scanning = true;
            scanDone.restart();
        }
    }

    function startJoin(net: var, spec: var): void {
        root.notice = "";
        // Refused while another join still runs (one privileged change at a time): that join keeps its "Connecting…".
        const running = root.pending;
        root.pending = net.key;
        if (!root.system.act("wifi join", spec, "wifi.act"))
            root.pending = running;
    }

    // A click on a row: join it (the current network stays as it is).
    function activate(net: var): void {
        root.notice = "";
        switch (System.wifiClickKind(net, root.known)) {
        case "known":
            root.startJoin(net, System.wifiConnectKnown(root.known[net.hex]));
            break;
        case "open":
            root.startJoin(net, net.valid ? System.wifiConnectOpen(net.ssid) : null);
            break;
        case "password":
            if (net.valid)
                root.passwordRequested(net);
            else
                root.notice = qsTr("“%1” cannot be joined from here: its name is not plain text.").arg(net.label);
            break;
        case "account":
            root.notice = qsTr("“%1” needs a sign-in (802.1X), which Grassfield does not set up yet.").arg(net.label);
            break;
        case "unsupported":
            root.notice = qsTr("“%1” uses WEP, which is not secure: Grassfield does not join it.").arg(net.label);
            break;
        }
    }

    // WifiPasswordSheet's answer.
    function join(net: var, psk: string): void {
        root.startJoin(net, System.wifiConnectSecure(net.ssid, psk));
    }

    function disconnect(): void {
        root.system.act("wifi disconnect", System.wifiDisconnect(root.device ? root.device.name : ""), "wifi.act");
    }

    // ForgetNetworkSheet's answer: the saved profile of that network goes.
    function forget(net: var): void {
        root.system.act("wifi forget", System.wifiForget(root.known[net.hex]), "wifi.act");
    }

    // The (…) menu of a row.
    function menuFor(net: var): var {
        const items = [];
        if (net.active) {
            items.push({id: "disconnect", text: qsTr("Disconnect")});
            items.push({id: "details", text: qsTr("Details…")});
        } else {
            const kind = System.wifiClickKind(net, root.known);
            items.push({id: "connect", text: qsTr("Connect"), enabled: kind === "known" || kind === "open" || kind === "password"});
        }
        if (root.known[net.hex] !== undefined) {
            items.push({separator: true});
            items.push({id: "forget", text: qsTr("Forget This Network…")});
        }
        return items;
    }

    function menuChosen(net: var, id: string): void {
        if (id === "connect")
            root.activate(net);
        else if (id === "disconnect")
            root.disconnect();
        else if (id === "details")
            root.showDetails(net);
        else if (id === "forget")
            root.forgetRequested(net);
    }

    // What assistive technology says after a network's name.
    function subtitleOf(net: var): string {
        if (root.pending === net.key)
            return qsTr("Connecting…");
        if (net.active)
            return qsTr("Connected");
        switch (System.wifiClickKind(net, root.known)) {
        case "known":
            return qsTr("Known network");
        case "account":
            return qsTr("Needs a sign-in");
        case "unsupported":
            return qsTr("WEP, not joined");
        }
        return "";
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            switch (tag) {
            case "wifi.state":
                root.asking = false;
                if (!ok && root.answered && root.misses < 1) {
                    root.misses++;
                    break;
                }
                root.misses = ok ? 0 : root.misses;
                root.setState(ok ? System.parseWifiState(output) : null);
                break;
            case "wifi.details":
                if (root.detailsNet !== null) {
                    // Without an answer the sheet still shows the network and its security.
                    const st = ok ? System.parseNetState(output) : null;
                    const net = root.detailsNet;
                    root.detailsNet = null;
                    root.detailsRequested(net, st ? (st.devices.find(d => d.type === "wifi") ?? null) : null);
                }
                break;
            case "wifi.act":
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

    // macOS keeps scanning while the pane is open.
    Timer {
        interval: Tokens.settingsWifiRescanMs
        running: root.listsShown
        repeat: true
        onTriggered: root.scan()
    }

    Timer {
        id: scanDone
        interval: Tokens.settingsWifiScanMs
        onTriggered: root.scanning = false
    }

    Component.onCompleted: {
        root.refresh();
        // Ask for a fresh scan when the pane opens (the radio is not known yet: NetworkManager ignores a scan with the radio off).
        if (!root.system.dev && root.system.act("wifi scan", System.wifiScan(), "wifi.scan")) {
            root.scanning = true;
            scanDone.restart();
        }
    }

    SettingsGroup {
        footnote: root.answered && !root.available ? qsTr("Wi-Fi is not available: NetworkManager did not answer.")
            : root.available && root.device === null ? qsTr("No Wi-Fi hardware was found.") : ""

        HeaderRow {
            glyph: "wifi-3"
            title: qsTr("Wi-Fi")
            text: qsTr("Connect this computer to the internet without a cable. Turn on Wi-Fi, then choose a network to join.")
            checked: root.radio === true
            switchEnabled: root.available
            onToggled: c => root.system.act("wifi " + (c ? "on" : "off"), System.wifiRadio(c), "wifi.act")
        }

        CurrentNetworkRow {
            visible: root.listsShown && root.current !== null
            name: root.current ? root.current.label : ""
            status: qsTr("Connected")
            secured: root.current ? root.current.secured : false
            strength: root.current ? root.current.strength : 0
            onDetailsRequested: root.showDetails(root.current)
        }
    }

    SettingsGroup {
        visible: root.listsShown && knownModel.count > 0
        caption: knownModel.count === 1 ? qsTr("Known Network") : qsTr("Known Networks")

        Repeater {
            model: knownModel

            delegate: NetworkRow {
                id: knownRow

                required property string key
                required property string hex
                required property string ssid
                required property string label
                required property int strength
                required property string security
                required secured
                required property bool enterprise
                required property bool active
                required property bool valid

                readonly property var net: root.netOf(knownRow)

                title: knownRow.label
                subtitle: root.subtitleOf(knownRow.net)
                leading: System.wifiGlyph(knownRow.strength)
                checked: knownRow.active
                busy: root.pending === knownRow.key
                rowHeight: Tokens.settingsWifiKnownRowHeight
                menuItems: root.menuFor(knownRow.net)
                onActivated: root.activate(knownRow.net)
                onMenuChosen: id => root.menuChosen(knownRow.net, id)
            }
        }
    }

    SettingsGroup {
        visible: root.listsShown
        caption: qsTr("Other Networks")
        busy: root.scanning
        footnote: root.notice

        Repeater {
            model: otherModel

            delegate: NetworkRow {
                id: otherRow

                required property string key
                required property string hex
                required property string ssid
                required property string label
                required property int strength
                required property string security
                required secured
                required property bool enterprise
                required property bool active
                required property bool valid

                readonly property var net: root.netOf(otherRow)

                title: otherRow.label
                subtitle: root.subtitleOf(otherRow.net)
                leading: System.wifiGlyph(otherRow.strength)
                busy: root.pending === otherRow.key
                rowHeight: Tokens.settingsWifiOtherRowHeight
                menuItems: root.menuFor(otherRow.net)
                onActivated: root.activate(otherRow.net)
                onMenuChosen: id => root.menuChosen(otherRow.net, id)
            }
        }

        EmptyListRow {
            visible: otherModel.count === 0
            text: root.scanning ? qsTr("Looking for networks…") : qsTr("No other networks found")
        }
    }

    ErrorNote {
        system: root.system
        tag: "wifi.act"
    }

    DevNote {
        system: root.system
    }
}
