pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Printers > a printer (macOS 27 opens its sheet): its state (and CUPS's message while it is stopped), its location, its kind,
// Resume while it is stopped or refuses jobs, and Remove Printer…, which Main.qml confirms first (RemovePrinterSheet). `printer`
// is PrintersPage.details(); both changes ask for the administrator's password (cups-pk-helper, ADR-0030).
Sheet {
    id: root

    property var printer: null

    signal removeRequested(var printer)
    signal resumeRequested(string name)

    title: root.printer ? root.printer.title : ""
    confirmText: qsTr("Done")
    showCancel: false

    function openFor(printer: var): void {
        root.printer = printer;
        root.open();
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            SettingsGroup {
                SettingsRow {
                    title: qsTr("Status")
                    valueText: root.printer ? (root.printer.message !== "" ? qsTr("%1 — %2", "a printer's state — CUPS's message").arg(root.printer.status).arg(root.printer.message)
                        : root.printer.status) : ""
                }
                SettingsRow {
                    visible: root.printer !== null && root.printer.location !== ""
                    title: qsTr("Location")
                    valueText: root.printer ? root.printer.location : ""
                }
                SettingsRow {
                    title: qsTr("Kind")
                    valueText: root.printer ? root.printer.kind : ""
                }
                SettingsRow {
                    title: qsTr("Queue")
                    valueText: root.printer ? root.printer.name : ""
                }
            }

            Row {
                spacing: Tokens.spacingSm

                Button {
                    push: true
                    visible: root.printer !== null && root.printer.needsResume === true
                    text: qsTr("Resume")
                    onClicked: {
                        root.close();
                        root.resumeRequested(root.printer.name);
                    }
                }

                Button {
                    push: true
                    text: qsTr("Remove Printer…")
                    onClicked: {
                        root.close();
                        root.removeRequested(root.printer);
                    }
                }
            }
        }
    }
}
