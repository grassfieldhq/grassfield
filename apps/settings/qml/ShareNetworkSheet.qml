pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "NetworkQr.js" as NetworkQr
import "Setups.js" as Setups

// Wi-Fi > the current network's Details > Share Network… (ADR-0045 OC-10): a QR code another device's camera reads to join the
// network, and the network's name; the password is never shown. The code is Omarchy's (`omarchy-network-qr --meta`, a read-only
// query: it reads the secret through NetworkManager's own permission check and encodes it with qrencode), drawn here module by
// module with the tokens, dark on white whatever the appearance (cameras read light-on-dark codes poorly). Omarchy picks the
// device itself; a code made for another network than the one shown is not drawn. The matrix encodes the password: it is
// dropped when the sheet closes. Enterprise networks have no such code (the Details sheet offers none; Omarchy refuses them).
Sheet {
    id: root

    required property var backend

    property var net: null
    property var code: null
    property bool loading: false
    property string error: ""
    readonly property string tag: "wifi.qr"
    readonly property var cells: NetworkQr.runs(root.code)

    title: root.net ? qsTr("Share “%1”").arg(root.net.label) : ""
    message: qsTr("Point the camera of a phone or a tablet at this code to join the network. The code holds the network's password.")
    confirmText: qsTr("Done")
    showCancel: false

    function openFor(net: var): void {
        root.net = net;
        root.code = null;
        root.error = "";
        root.loading = true;
        root.open();
        root.backend.readOnlyQuery(Setups.QUERY.networkQr, root.tag, Tokens.settingsQrQueryMs);
    }

    onShownChanged: {
        if (!root.shown) {
            root.code = null;
            root.loading = false;
        }
    }

    Connections {
        target: root.backend
        // Only while it waits for an answer: a Backend answer is not handed to every row and sheet of the window (the audit's notes).
        enabled: root.shown

        function onFailed(tag: string, reason: string): void {
            if (tag === root.tag)
                root.error = reason;
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag !== root.tag || !root.shown || !root.loading)
                return;
            root.loading = false;
            const code = ok ? NetworkQr.parse(output) : null;
            if (code !== null && !NetworkQr.matches(code, root.net ? root.net.ssid : "")) {
                root.error = qsTr("The code was made for another network.");
                return;
            }
            root.code = code;
            if (code === null && root.error === "")
                root.error = qsTr("Omarchy's answer could not be read.");
        }
    }

    Item {
        id: area
        // A module of the token's size, smaller only for a code wider than the sheet (a long password makes a larger code).
        readonly property int module: root.code ? Math.max(1, Math.min(Tokens.settingsQrModule, Math.floor(area.width / root.code.size))) : Tokens.settingsQrModule
        width: parent.width
        height: card.height

        Rectangle {
            id: card
            visible: root.code !== null
            anchors.horizontalCenter: parent.horizontalCenter
            width: (root.code ? root.code.size : 0) * area.module
            height: width
            radius: Tokens.settingsQrRadius
            color: Tokens.settingsQrLight
            Accessible.role: Accessible.Graphic
            Accessible.name: root.net ? qsTr("QR code to join “%1”").arg(root.net.label) : ""

            Repeater {
                model: root.cells

                Rectangle {
                    required property var modelData
                    x: modelData.x * area.module
                    y: modelData.y * area.module
                    width: modelData.w * area.module
                    height: area.module
                    color: Tokens.settingsQrDark
                    antialiasing: false
                }
            }
        }
    }

    Spinner {
        visible: root.loading
        anchors.horizontalCenter: parent.horizontalCenter
    }

    Text {
        textFormat: Text.PlainText
        visible: root.code !== null
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideMiddle
        text: root.net ? root.net.label : ""
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        font.weight: Tokens.typographyMenuBoldWeight
    }

    Text {
        textFormat: Text.PlainText
        visible: !root.loading && root.code === null && root.error !== ""
        width: parent.width
        wrapMode: Text.Wrap
        text: qsTr("The code cannot be made: %1").arg(root.error)
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
    }
}
