pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Battery > (i): Battery Health (the capacity left of the design capacity and the charge cycles) or Charging (UPower's charge
// limit where the battery has one: `limitRequested(on)`, the page acts on it).
Sheet {
    id: root

    // "health" or "charging".
    property string topic: "health"
    // Power.parseState's object.
    property var power: null

    signal limitRequested(bool on)

    title: root.topic === "health" ? qsTr("Battery Health") : qsTr("Charging")
    message: root.topic === "health" ? qsTr("Batteries hold less charge as they age. The maximum capacity is measured against the battery's design capacity.")
        : root.power && root.power.limitSupported ? qsTr("Stopping the charge before the battery is full helps it last longer when the computer stays on its power adapter.")
        : qsTr("This battery does not offer a charge limit.")
    confirmText: qsTr("Done")
    showCancel: false

    function openFor(topic: string, power: var): void {
        root.topic = topic;
        root.power = power;
        root.open();
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            SettingsGroup {
                visible: root.topic === "health"

                SettingsRow {
                    title: qsTr("Maximum capacity")
                    valueText: root.power && root.power.capacity > 0 ? qsTr("%1 %").arg(Math.round(root.power.capacity)) : qsTr("Unknown")
                }
                SettingsRow {
                    visible: root.power !== null && root.power.cycles >= 0
                    title: qsTr("Cycle count")
                    valueText: root.power ? String(root.power.cycles) : ""
                }
            }

            SettingsGroup {
                visible: root.topic === "charging" && root.power !== null && root.power.limitSupported

                SettingsRow {
                    title: root.power && root.power.limitEnd > 0 ? qsTr("Limit charging to %1 %").arg(root.power.limitEnd) : qsTr("Limit charging")
                    Toggle {
                        accessibleName: qsTr("Limit charging")
                        checked: root.power ? root.power.limitEnabled : false
                        onToggled: c => root.limitRequested(c)
                    }
                }
            }
        }
    }
}
