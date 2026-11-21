pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui

// Desktop & Dock > Screen Corners… (macOS: Hot Corners…, a sheet with a picture of the screen and a pop-up at each of its
// corners; no macOS 27 capture of it, docs/audits/settings-parity-2026-10-26.md § Desktop & Dock). Each pop-up writes its
// hotCorners key at once; Done closes the sheet.
Sheet {
    id: root

    required property var store

    title: qsTr("Screen Corners")
    confirmText: qsTr("Done")
    showCancel: false

    readonly property var actions: [
        {id: "none", text: qsTr("None")},
        {id: "overview", text: qsTr("Overview")},
        {id: "notifications", text: qsTr("Notifications")},
        {id: "apps", text: qsTr("Apps")},
        {id: "lock", text: qsTr("Lock Screen")}
    ]

    component Corner: ComboBox {
        property string key: ""
        model: root.actions
        value: root.store.value("hotCorners." + key)
        onPicked: id => root.store.set("hotCorners." + key, id)
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            Item {
                width: parent.width
                height: topLeft.height + Tokens.spacingSm + picture.height + Tokens.spacingSm + bottomLeft.height

                Corner {
                    id: topLeft
                    key: "topLeft"
                    accessibleName: qsTr("Top left corner")
                }

                Corner {
                    anchors.right: parent.right
                    key: "topRight"
                    accessibleName: qsTr("Top right corner")
                }

                // The screen: the Grassfield artwork in a rounded frame.
                Item {
                    id: picture
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: topLeft.height + Tokens.spacingSm
                    width: Tokens.settingsScreenCornersPictureWidth
                    height: Tokens.settingsScreenCornersPictureHeight
                    Accessible.ignored: true
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: pictureMask
                    }

                    GrassfieldArtwork {
                        anchors.fill: parent
                    }
                }

                Rectangle {
                    id: pictureMask
                    visible: false
                    layer.enabled: true
                    width: picture.width
                    height: picture.height
                    radius: Tokens.settingsScreenCornersPictureRadius
                }

                Corner {
                    id: bottomLeft
                    y: picture.y + picture.height + Tokens.spacingSm
                    key: "bottomLeft"
                    accessibleName: qsTr("Bottom left corner")
                }

                Corner {
                    anchors.right: parent.right
                    y: bottomLeft.y
                    key: "bottomRight"
                    accessibleName: qsTr("Bottom right corner")
                }
            }
        }
    }
}
