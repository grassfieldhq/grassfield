pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Bindings.js" as Bindings

// Keyboard > Keyboard Shortcuts…: the Grassfield shortcuts, read-only, from the bindings file (macOS shows its shortcuts in a sheet
// too; Grassfield's are defined in the session configuration, not edited here).
Sheet {
    id: root

    property var shortcuts: []
    property string file: ""

    title: qsTr("Keyboard Shortcuts")
    message: root.shortcuts.length > 0 ? qsTr("Shortcuts are read-only here. They are defined in %1.").arg(root.file)
        : qsTr("The shortcuts file could not be read: %1").arg(root.file)
    confirmText: qsTr("Done")
    showCancel: false

    function openWith(list: var, file: string): void {
        root.shortcuts = list;
        root.file = file;
        root.open();
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            Rectangle {
                visible: root.shortcuts.length > 0
                width: parent.width
                height: Tokens.settingsPickerListHeight
                radius: Tokens.radiusGroup
                color: Appearance.colors.groupFill
                clip: true

                ListView {
                    anchors.fill: parent
                    model: root.shortcuts
                    boundsBehavior: Flickable.StopAtBounds
                    Accessible.role: Accessible.List
                    Accessible.name: root.title

                    delegate: SettingsRow {
                        required property var modelData
                        width: ListView.view.width
                        // The file's English description and key names, translated (Bindings.js lists them).
                        title: qsTranslate("Bindings", Bindings.uiName(modelData.description))
                        valueText: Bindings.translateKeys(modelData.keys, k => qsTranslate("Bindings", k))
                    }
                }
            }
        }
    }
}
