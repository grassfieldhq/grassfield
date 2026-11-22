pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// A group of the settings that can differ per display, over a DisplayScopeState (macOS-style grouping: the rows that follow the
// display chosen sit in this group, under its caption, and the pop-up that chooses the display is the group's first row; the
// settings that are the same everywhere stay in groups of their own). The rows of the page go in as children, after the pop-up.
// The pop-up row (All Displays, one entry per display, and "Use All Displays" while the chosen display has settings of its own)
// only exists with more than one display.
SettingsGroup {
    id: root

    required property var scope
    // The pop-up's name, "Dock settings for", "Menu Bar settings for", ...
    required property string title
    // The sentence under it, with %1 for the display chosen (translated by the page that owns the strings).
    required property string appliesToOne
    required property string appliesToAll

    SettingsRow {
        visible: root.scope.displayCount > 1
        title: root.title
        subtitle: root.scope.currentDisplay !== null ? root.appliesToOne.arg(root.scope.currentDisplay.label) : root.appliesToAll

        Row {
            spacing: Tokens.spacingSm

            Button {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.scope.hasOverride
                push: true
                text: qsTr("Use All Displays")
                onClicked: root.scope.useAllDisplays()
            }

            ComboBox {
                anchors.verticalCenter: parent.verticalCenter
                inline: true
                accessibleName: root.title
                model: [{id: "all", text: qsTr("All Displays")}].concat(root.scope.displays.map(d => ({id: d.key, text: d.label})))
                value: root.scope.displayId
                onPicked: id => root.scope.displayId = id
            }
        }
    }
}
