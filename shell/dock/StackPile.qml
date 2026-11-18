pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Grassfield.Ui
import "Stacks.js" as Stacks

// The tile of a folder stack shown as a stack (macOS "Display as: Stack"): the newest items of the folder piled up, the
// newest on top, the ones behind turned a few degrees. `items` are the folder's newest items, newest first (StackWatch keeps
// them live); the sheets are a model-driven view of them, so a newer item makes a new top sheet. An empty folder shows the
// folder icon instead (`empty`).
Item {
    id: root

    property var items: []
    property int size: Tokens.dockIconSize
    // The folder has no visible item.
    readonly property bool empty: sheets.length === 0
    readonly property real sheet: root.size * Tokens.dockStackPileScale
    readonly property var sheets: Stacks.pileSheets(root.items, Tokens.dockStackPileSheets)
    // The Dock gives the pile the magnified box of its tile: the sheets, laid out for `size`, grow with it like the icons
    // of the other tiles (a transform, so nothing is decoded again while the magnification moves).
    readonly property real zoom: root.width > 0 && root.size > 0 ? root.width / root.size : 1

    Repeater {
        // Back to front.
        model: root.sheets

        delegate: Item {
            id: sheetItem

            required property var modelData

            width: root.sheet
            height: root.sheet
            anchors.centerIn: parent
            anchors.verticalCenterOffset: root.size * root.zoom * (modelData.rank === 0 ? Tokens.dockStackPileLift : 0)
            scale: root.zoom
            rotation: modelData.rank === 0 ? 0 : (modelData.rank === 1 ? -Tokens.dockStackPileTilt : Tokens.dockStackPileTilt)

            Rectangle {
                anchors.fill: parent
                radius: Tokens.radiusControl
                color: Appearance.colors.fieldFill
                // One device pixel at every scale (UI audit 2026-11-05 U37).
                border.width: 1 / Math.max(1, Screen.devicePixelRatio)
                border.color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.materialFillOpacity)
            }

            StackIcon {
                anchors.centerIn: parent
                path: sheetItem.modelData.path
                isDir: sheetItem.modelData.isDir
                size: Math.round(root.sheet * Tokens.dockStackPileIconScale)
            }
        }
    }
}
