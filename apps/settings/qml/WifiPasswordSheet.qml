pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Wi-Fi > a secured network: its password (macOS asks in a dialog with "Show password"). Join hands the network and the
// password back (`join`) and the field is emptied; Cancel and Escape empty it too, so the password stays nowhere in the window.
// A password NetworkManager would refuse (8 to 63 characters, or 64 hex digits) keeps the sheet open with the reason.
Sheet {
    id: root

    property var net: null
    // "Show password" (the check box of the body, built at the first opening).
    property bool showPassword: false

    signal join(var net, string psk)

    title: root.net ? qsTr("Enter the password for “%1”").arg(root.net.label) : ""
    message: qsTr("This network is secured. Its password is saved on this computer once it is joined.")
    confirmText: qsTr("Join")
    withField: true
    fieldPassword: !root.showPassword
    placeholder: qsTr("Password")

    function openFor(net: var): void {
        root.net = net;
        root.showPassword = false;
        root.setField("");
        root.open();
    }

    confirmHandler: text => {
        if (!System.validPassphrase(text))
            return qsTr("A Wi-Fi password has 8 to 63 characters (letters, digits and symbols), or 64 hexadecimal digits.");
        const net = root.net;
        root.setField("");
        root.join(net, text);
        return "";
    }
    onCanceled: root.setField("")

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            CheckBox {
                id: show
                text: qsTr("Show password")
                onToggled: root.showPassword = show.checked

                Binding {
                    target: show
                    property: "checked"
                    value: root.showPassword
                }
            }
        }
    }
}
