pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// macOS 27 Battery > Options…: a sheet over the Settings window. Grassfield has the one option it can back: Prevent automatic
// sleeping when the display is off (energy.preventSleep; the shell's idle module, shell/security/idle). Unlike macOS's "on
// power adapter" switch it applies on battery too (integrator decision 2026-11-04: Grassfield never put a computer to sleep by
// itself before, and on by default it keeps it that way); the footnote says so. Wake for network access, Slightly dim the
// display on battery and Optimize video streaming have no counterpart here. Second option (ADR-0048): Slow down apps you can't
// see while on battery (energy.slowHiddenApps, on by default; the shell's AppEnergy and grassfield-energy). The switches write
// at once; Done closes the sheet.
Sheet {
    id: root

    required property var store

    title: qsTr("Options")
    confirmText: qsTr("Done")
    showCancel: false

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            SettingsGroup {
                footnote: qsTr("Applies on battery and on power adapter. The display turns off and the session locks as set in Lock Screen.")

                SettingsRow {
                    title: qsTr("Prevent automatic sleeping when the display is off")
                    Toggle {
                        accessibleName: qsTr("Prevent automatic sleeping when the display is off")
                        checked: root.store.value("energy.preventSleep")
                        onToggled: c => root.store.set("energy.preventSleep", c)
                    }
                }
            }

            SettingsGroup {
                SettingsRow {
                    title: qsTr("Slow down apps you can't see while on battery")
                    subtitle: qsTr("Apps whose windows are covered, minimized or on another desktop get less processor and disk time. The app you are using, and apps that play sound, record, set an alarm or are still working, keep their full speed. Nothing is slowed down on the power adapter.")

                    Toggle {
                        accessibleName: qsTr("Slow down apps you can't see while on battery")
                        checked: root.store.value("energy.slowHiddenApps") === true
                        onToggled: c => root.store.set("energy.slowHiddenApps", c)
                    }
                }
            }
        }
    }
}
