pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Wi-Fi > Details… and Network > an Ethernet service: a connection as NetworkManager has it (macOS 27 shows a sheet with its
// addresses): for Wi-Fi the band, the link rate and the security, for Ethernet the speed; then the IPv4 address, subnet mask
// and router, the name servers, the IPv6 address and the hardware address, read-only, and for a Wi-Fi network Forget This
// Network… and, for the one this computer is on, Share Network… (a QR code, ShareNetworkSheet.qml, ADR-0045 OC-10). `device`
// is a device of `net.state` (System.parseNetState); `net` the Wi-Fi network (null for Ethernet).
Sheet {
    id: root

    property var net: null
    property var device: null
    // The sheet's title for a service that is not a Wi-Fi network ("Ethernet").
    property string serviceName: ""
    // Omarchy's omarchy-network-qr is installed (Main asks when the sheet opens): Share Network… is offered.
    property bool canShare: false

    signal forgetRequested(var net)
    signal shareRequested(var net)

    readonly property string ip4: root.device && root.device.ip4.length > 0 ? root.device.ip4[0] : ""
    readonly property string ip6: root.device && root.device.ip6.length > 0 ? root.device.ip6[0] : ""

    title: root.net ? root.net.label : root.serviceName
    confirmText: qsTr("OK")
    showCancel: false

    function openFor(net: var, device: var): void {
        root.net = net;
        root.device = device;
        root.serviceName = "";
        root.open();
    }

    function openForService(name: string, device: var): void {
        root.net = null;
        root.device = device;
        root.serviceName = name;
        root.open();
    }

    // "a.b.c.d/n" or "a::b/n" without its prefix length.
    function address(withPrefix: string): string {
        return withPrefix.split("/")[0];
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            SettingsGroup {
                Repeater {
                    model: [
                        {title: qsTr("Wi-Fi band"), value: root.net && root.device ? System.wifiBand(root.device.frequency) : ""},
                        {title: qsTr("Link rate"), value: root.net && root.device && root.device.bitrate > 0 ? qsTr("%1 Mbit/s").arg(Math.round(root.device.bitrate / 1000)) : ""},
                        {title: qsTr("Speed"), value: !root.net && root.device && root.device.speed > 0 ? qsTr("%1 Mbit/s").arg(root.device.speed) : ""},
                        {title: qsTr("Security"), value: root.net ? (root.net.security !== "" ? root.net.security : qsTr("None")) : ""},
                        {title: qsTr("IP address"), value: root.address(root.ip4)},
                        {title: qsTr("Subnet mask"), value: root.ip4 !== "" ? System.subnetMask(root.ip4.split("/")[1]) : ""},
                        {title: qsTr("Router"), value: root.device ? root.device.router : ""},
                        {title: qsTr("DNS servers"), value: root.device ? root.device.dns.join(", ") : ""},
                        {title: qsTr("IPv6 address"), value: root.address(root.ip6)},
                        {title: qsTr("MAC address"), value: root.device ? root.device.mac : ""}
                    ].filter(r => r.value !== "")

                    SettingsRow {
                        required property var modelData
                        title: modelData.title
                        valueText: modelData.value
                    }
                }

                SettingsRow {
                    visible: root.ip4 === "" && root.ip6 === ""
                    title: qsTr("No address: not connected")
                }
            }

            Row {
                spacing: Tokens.settingsAccessoryGap

                Button {
                    visible: root.net !== null
                    push: true
                    text: qsTr("Forget This Network…")
                    onClicked: {
                        root.close();
                        root.forgetRequested(root.net);
                    }
                }

                // ADR-0045 OC-10: the network this computer is on, shared by a QR code (Omarchy's omarchy-network-qr); never for an
                // enterprise (802.1X) network, whose account a code cannot hold (Omarchy refuses them too).
                Button {
                    visible: root.net !== null && root.net.active === true && root.net.enterprise !== true && root.canShare
                    push: true
                    text: qsTr("Share Network…")
                    onClicked: {
                        root.close();
                        root.shareRequested(root.net);
                    }
                }
            }
        }
    }
}
