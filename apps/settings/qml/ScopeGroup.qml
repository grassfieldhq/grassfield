pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The "<pane> settings for" group over a DisplayScopeState: a pop-up with All Displays and one entry per display, the line that
// says which displays a change reaches, and "Use All Displays" while the chosen display has settings of its own. Only with more
// than one display.
SettingsGroup {
    id: root

    required property var scope
    // "Dock settings for", "Menu Bar settings for", ...
    required property string title
    // The settings the pop-up chooses the display of, in the sentence "<settings> apply to %1 only." (translated by the page).
    required property string appliesToOne
    required property string appliesToAll

    visible: root.scope.displayCount > 1

    SettingsRow {
        title: root.title
        subtitle: root.scope.currentDisplay !== null ? root.appliesToOne.arg(root.scope.currentDisplay.label) : root.appliesToAll
        ComboBox {
            inline: true
            accessibleName: root.title
            model: [{id: "all", text: qsTr("All Displays")}].concat(root.scope.displays.map(d => ({id: d.key, text: d.label})))
            value: root.scope.displayId
            onPicked: id => root.scope.displayId = id
        }
    }

    SettingsRow {
        visible: root.scope.hasOverride
        title: qsTr("Use the All Displays settings")
        Button {
            push: true
            text: qsTr("Use All Displays")
            onClicked: root.scope.useAllDisplays()
        }
    }
}
