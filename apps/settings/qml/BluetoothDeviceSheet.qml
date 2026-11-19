pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Bluetooth > (i): a paired device (macOS 27 shows its picture, name, battery and options): the address and the battery,
// Connect or Disconnect, and Forget This Device…. The page acts on the choice (`connectRequested`, `forgetRequested`).
Sheet {
    id: root

    property var device: null

    signal connectRequested(var device)
    signal forgetRequested(var device)

    title: root.device ? root.device.name : ""
    confirmText: qsTr("Done")
    showCancel: false

    function openFor(device: var): void {
        root.device = device;
        root.open();
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            SettingsGroup {
                SettingsRow {
                    title: qsTr("Address")
                    valueText: root.device ? root.device.mac : ""
                }
                SettingsRow {
                    visible: root.device !== null && root.device.battery >= 0
                    title: qsTr("Battery")
                    valueText: root.device ? qsTr("%1 %").arg(root.device.battery) : ""
                }
                SettingsRow {
                    title: qsTr("Status")
                    valueText: root.device && root.device.connected ? qsTr("Connected") : qsTr("Not Connected")
                }
            }

            Row {
                spacing: Tokens.spacingSm

                Button {
                    push: true
                    text: root.device && root.device.connected ? qsTr("Disconnect") : qsTr("Connect")
                    onClicked: {
                        root.close();
                        root.connectRequested(root.device);
                    }
                }

                Button {
                    push: true
                    text: qsTr("Forget This Device…")
                    onClicked: {
                        root.close();
                        root.forgetRequested(root.device);
                    }
                }
            }
        }
    }
}
