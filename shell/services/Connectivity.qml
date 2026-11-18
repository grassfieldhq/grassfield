pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Io
import Quickshell.Networking
import Grassfield.Ui
import "Airplane.js" as Airplane
import "../overlay/controlcenter/Model.js" as Model // layering-exception: GF-087

// Connectivity summary for the menu bar (NetworkManager through Quickshell.Networking).
Singleton {
    id: root

    // Visual-test fixture (GRASSFIELD_DEV and GRASSFIELD_VISUAL_FIXTURES): one fake Wi-Fi network, Wi-Fi on.
    readonly property bool fixture: VisualFixtures.active
    readonly property var fixtureNet: ({name: VisualFixtures.network, signalStrength: 0.9, connected: true})

    readonly property bool available: fixture || Networking.backend === NetworkBackendType.NetworkManager
    readonly property var devices: Networking.devices ? Networking.devices.values : []

    // NetworkManager says the network is fully usable (connectivity Full), or says nothing because its connectivity check is
    // off (Unknown) while a link is up, or there is no NetworkManager backend to ask: then there is nothing to wait for and
    // a user of the network just tries (online wallpaper, ADR-0016 step 2). Portal, Limited and None are not usable.
    readonly property bool fullyConnected: {
        if (fixture || !available)
            return true;
        const c = Networking.connectivity;
        return c === NetworkConnectivity.Full || (c === NetworkConnectivity.Unknown && (wiredConnected || wifiConnected !== null));
    }
    readonly property bool wifiEnabled: fixture || Networking.wifiEnabled

    function deviceOfType(type: int): var {
        for (let i = 0; i < devices.length; i++) {
            if (devices[i].type === type)
                return devices[i];
        }
        return null;
    }

    readonly property var wifiDevice: fixture ? ({scannerEnabled: false, networks: null}) : deviceOfType(DeviceType.Wifi)
    readonly property var wiredDevice: fixture ? null : deviceOfType(DeviceType.Wired)
    readonly property bool wiredConnected: wiredDevice !== null && wiredDevice.connected

    // The Wi-Fi network this machine is connected to, or null.
    readonly property var wifiConnected: {
        if (fixture)
            return fixtureNet;
        const nets = wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : [];
        for (let i = 0; i < nets.length; i++) {
            if (nets[i].connected)
                return nets[i];
        }
        return null;
    }

    readonly property string iconName: {
        if (wiredConnected)
            return "network-wired";
        if (!wifiEnabled || wifiDevice === null)
            return "wifi-off";
        if (wifiConnected === null)
            return "wifi-off";
        const s = wifiConnected.signalStrength;
        return s < 0.34 ? "wifi-1" : (s < 0.67 ? "wifi-2" : "wifi-3");
    }

    readonly property string description: {
        if (wiredConnected)
            return qsTr("Wired connection");
        if (!wifiEnabled)
            return qsTr("Wi-Fi is off");
        if (wifiConnected)
            return qsTr("Connected to %1").arg(wifiConnected.name);
        return qsTr("Not connected");
    }

    // Every radio change goes through the dev guard, whoever calls it (menu bar, Control Center).
    function setWifiEnabled(on: bool): void {
        if (guarded("wifi " + (on ? "on" : "off")))
            return;
        Networking.wifiEnabled = on;
    }

    // A GRASSFIELD_DEV session runs on the owner's machine: radio and connection changes are
    // never executed there (the Control Center shows a "dev: not applied" note instead).
    readonly property bool devSession: Mode.dev
    signal devSuppressed(string what)

    function guarded(what: string): bool {
        if (!devSession)
            return false;
        console.info("dev guard: " + what + " suppressed");
        devSuppressed(what);
        return true;
    }

    // Scan results as rows for the Control Center (sorted, deduplicated; see Model.sortNetworks).
    readonly property var networks: {
        if (fixture)
            return [{name: fixtureNet.name, strength: fixtureNet.signalStrength, secured: true, enterprise: false, connected: true, known: true, connecting: false, net: null}];
        const nets = wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : [];
        const rows = [];
        for (let i = 0; i < nets.length; i++) {
            const n = nets[i];
            const sec = n.security;
            rows.push({
                name: n.name,
                strength: n.signalStrength,
                secured: sec !== WifiSecurityType.Open && sec !== WifiSecurityType.Owe,
                enterprise: sec === WifiSecurityType.Wpa2Eap || sec === WifiSecurityType.WpaEap,
                connected: n.connected,
                known: n.known,
                connecting: n.state === ConnectionState.Connecting,
                net: n
            });
        }
        return Model.sortNetworks(rows);
    }

    // scannerEnabled lives on the shared WifiDevice: the Control Center sets it while Wi-Fi is expanded.
    function setScanning(on: bool): void {
        if (wifiDevice)
            wifiDevice.scannerEnabled = on;
    }

    function toggleWifi(on: bool): void {
        setWifiEnabled(on);
    }

    // row: an entry of `networks`. Returns the action (see Model.networkAction); "password" is left to the UI.
    function activate(row: var): string {
        const action = Model.networkAction(row);
        if (action === "disconnect") {
            if (!guarded("wifi disconnect"))
                row.net.disconnect();
        } else if (action === "connect") {
            if (!guarded("wifi connect"))
                row.net.connect();
        } else if (action === "editor") {
            if (!guarded("nm-connection-editor"))
                Apps.openDetached(["nm-connection-editor"]);
        }
        return action;
    }

    // Airplane mode (REQ-QS-CC3): an rfkill soft block of Wi-Fi, Bluetooth and cellular (Rfkill.qml; no root, /dev/rfkill is
    // opened through the session's uaccess ACL). NetworkManager and BlueZ follow the block. When rfkill is not usable
    // (no /dev/rfkill, not writable, no rfkill tool) the state is derived from the services' power switches and
    // switching them is the fallback; `airplaneNote` then says why (shown once per use, and logged).
    // Airplane Mode is its own state (macOS): `airplaneState` {on, restore} is set by setAirplane, persisted in
    // $stateDir/airplane.json and read back at start. On remembers the radios that were on, off restores exactly those; Wi-Fi
    // off alone is not Airplane Mode (Airplane.js).
    property var airplaneState: Airplane.end()
    readonly property bool rfkillMode: Rfkill.known
    readonly property var radiosNow: rfkillMode ? Airplane.radiosFromRfkill(Rfkill.devices) : Airplane.radiosFromServices(wifiDevice !== null ? wifiEnabled : null, BluetoothState.available ? BluetoothState.enabled : null)
    readonly property bool airplane: Airplane.reconcile(airplaneState, radiosNow).on
    readonly property bool airplaneAvailable: rfkillMode || wifiDevice !== null || BluetoothState.available
    readonly property string airplaneFile: stateDir + "/airplane.json"
    readonly property string stateDir: Mode.stateDir

    // Written 0600 in a 0700 directory (the repo convention for state files).
    function saveAirplane(state: var): void {
        airplaneState = state;
        const argv = ["sh", Quickshell.shellPath("services/write-private.sh"), stateDir, airplaneFile, Airplane.serialize(state)];
        // A write still running is left to end (starting it again would do nothing): this one follows it, the last state winning.
        if (airplaneWriter.running) {
            airplaneWriter.next = argv;
            return;
        }
        airplaneWriter.command = argv;
        airplaneWriter.running = true;
    }

    // A persisted "on" that no longer matches the radios is erased, not just hidden: it is checked at start (after the radios were
    // read) and whenever a radio changes, except for a moment after Airplane Mode was just switched on or at start (the
    // radios have not followed yet), and again when that moment ends (a failed block leaves nothing behind).
    property bool airplaneSettling: true
    function settleAirplane(): void {
        if (!airplaneSettling && Airplane.shouldClear(airplaneState, radiosNow))
            saveAirplane(Airplane.end());
    }
    onRadiosNowChanged: settleAirplane()

    Timer {
        id: airplaneSettle
        running: true
        interval: Tokens.quicksettingsAirplaneSettleMs
        onTriggered: {
            root.airplaneSettling = false;
            root.settleAirplane();
        }
    }

    FileView {
        id: airplaneReader
        path: root.airplaneFile
        printErrors: false
        onLoaded: {
            root.airplaneState = Airplane.parse(text());
            root.settleAirplane();
        }
    }

    Process {
        id: airplaneWriter
        // The write asked while one was running (null: none), started when that one is gone.
        property var next: null
        onRunningChanged: {
            if (!running && next !== null) {
                command = next;
                next = null;
                running = true;
            }
        }
    }
    // Why the soft block is not used, "" while it is (or while the probe has not finished).
    readonly property string airplaneNote: Rfkill.probed && !Rfkill.usable ? qsTr("Airplane Mode: %1; using the Wi-Fi and Bluetooth switches").arg(Rfkill.reasonText) : ""
    signal airplaneFallback(string why)

    function setAirplane(on: bool): void {
        if (guarded("airplane mode " + (on ? "on" : "off") + (rfkillMode ? " (rfkill)" : "")))
            return;
        // Turning it on remembers the radios that are on now; turning it off brings back exactly those.
        const radios = radiosNow;
        const restore = on ? [] : Airplane.typesToRestore(airplaneState, radios);
        saveAirplane(on ? Airplane.begin(radios) : Airplane.end());
        airplaneSettling = true;
        airplaneSettle.restart();
        if (rfkillMode) {
            Rfkill.setBlocked(on, restore);
            return;
        }
        if (airplaneNote !== "") {
            console.info("airplane mode: " + airplaneNote);
            airplaneFallback(airplaneNote);
        }
        if (on) {
            if ("wlan" in radios)
                toggleWifi(false);
            if ("bluetooth" in radios)
                BluetoothState.setEnabled(false);
        } else {
            if (restore.indexOf("wlan") >= 0)
                toggleWifi(true);
            if (restore.indexOf("bluetooth") >= 0)
                BluetoothState.setEnabled(true);
        }
    }

    function connectWithPassword(row: var, psk: string): void {
        if (!guarded("wifi connect (password)"))
            row.net.connectWithPsk(psk);
    }
}
