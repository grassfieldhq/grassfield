pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// macOS Tahoe Menu Bar > Clock Options…: a sheet over the Settings window. Digital style only (the analog clock is not
// built). Every control writes at once (docs/specs/settings.md); Done closes the sheet.
Sheet {
    id: root

    required property var store

    title: qsTr("Clock Options")
    confirmText: qsTr("Done")
    showCancel: false

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            SettingsGroup {
                caption: qsTr("Date")

                SettingsRow {
                    title: qsTr("Show date")
                    subtitle: qsTr("When Space Allows drops the date when the menu bar is crowded.")
                    ComboBox {
                        accessibleName: qsTr("Show date")
                        model: [{id: "auto", text: qsTr("When Space Allows")}, {id: "always", text: qsTr("Always")}, {id: "never", text: qsTr("Never")}]
                        value: root.store.value("menubar.clockDate")
                        onPicked: id => root.store.set("menubar.clockDate", id)
                    }
                }

                SettingsRow {
                    title: qsTr("Show the day of the week")
                    Toggle {
                        accessibleName: qsTr("Show the day of the week")
                        checked: root.store.value("menubar.clockShowDayOfWeek")
                        onToggled: c => root.store.set("menubar.clockShowDayOfWeek", c)
                    }
                }
            }

            SettingsGroup {
                caption: qsTr("Time")

                SettingsRow {
                    title: qsTr("Time format")
                    subtitle: qsTr("Automatic follows the language and region.")
                    ComboBox {
                        accessibleName: qsTr("Time format")
                        model: [{id: "auto", text: qsTr("Automatic")}, {id: "12", text: qsTr("12-hour")}, {id: "24", text: qsTr("24-hour")}]
                        value: root.store.value("menubar.clockHours")
                        onPicked: id => root.store.set("menubar.clockHours", id)
                    }
                }

                SettingsRow {
                    title: qsTr("Show AM/PM")
                    Toggle {
                        // Only a 12-hour clock has it: the 12-hour format, or Automatic in a region whose short time has AM/PM.
                        enabled: root.store.value("menubar.clockHours") === "12" || (root.store.value("menubar.clockHours") === "auto" && /[aA]/.test(Qt.locale().timeFormat(Locale.ShortFormat).replace(/'[^']*'/g, "")))
                        accessibleName: qsTr("Show AM/PM")
                        checked: root.store.value("menubar.clockShowAmPm")
                        onToggled: c => root.store.set("menubar.clockShowAmPm", c)
                    }
                }

                SettingsRow {
                    title: qsTr("Display the time with seconds")
                    Toggle {
                        accessibleName: qsTr("Display the time with seconds")
                        checked: root.store.value("menubar.clockShowSeconds")
                        onToggled: c => root.store.set("menubar.clockShowSeconds", c)
                    }
                }

                SettingsRow {
                    title: qsTr("Flash the time separators")
                    Toggle {
                        accessibleName: qsTr("Flash the time separators")
                        checked: root.store.value("menubar.clockFlashSeparators")
                        onToggled: c => root.store.set("menubar.clockFlashSeparators", c)
                    }
                }
            }
        }
    }
}
