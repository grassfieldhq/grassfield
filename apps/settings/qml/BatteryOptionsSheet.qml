pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// macOS 27 Menu Bar > Battery Options…: a sheet over the Settings window with the battery item's options. Every control
// writes at once; Done closes the sheet.
Sheet {
    id: root

    required property var store

    title: qsTr("Battery Options")
    confirmText: qsTr("Done")
    showCancel: false

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            SettingsGroup {
                SettingsRow {
                    title: qsTr("Show Percentage")
                    Toggle {
                        accessibleName: qsTr("Show the battery percentage in the menu bar")
                        checked: root.store.value("menubar.showBatteryPercentage")
                        onToggled: c => root.store.set("menubar.showBatteryPercentage", c)
                    }
                }
            }
        }
    }
}
