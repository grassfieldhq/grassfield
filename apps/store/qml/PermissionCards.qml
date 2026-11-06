pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// A Flatpak's product page: what it can reach (ADR-0049, spec SR11), as the macOS 27 App Store lays out its privacy
// section: a heading, one line, then a grid of cards, one per group present (Files and Folders, Network, Camera and Other
// Devices…), each with its glyph, its title and its items in plain words, a short note under a wide grant. Nothing
// granted beyond its window and files: one card that says so. Unread metadata (grants null): nothing, never "nothing".
Column {
    id: root

    // The backend's grants (view::permissions), or null when the metadata could not be read.
    property var grants: null
    property string appName: ""

    readonly property var groups: Store.permissionGroups(root.grants)
    readonly property var cards: root.groups === null ? []
                               : root.groups.length > 0 ? root.groups
                               : [{id: "none", title: qsTr("Only Its Own Window and Files"), icon: "shield",
                                   items: [{text: qsTr("It can reach only its own window, its own folder in ~/.var/app and the files you choose."), note: ""}],
                                   footnote: ""}]

    visible: root.groups !== null
    spacing: Tokens.storeProductLineGap

    SectionHeading {
        width: root.width
        text: qsTr("Permissions")
    }

    Text {
        width: Math.min(root.width, Tokens.storeTextMaxWidth)
        textFormat: Text.PlainText
        text: qsTr("What “%1” can reach beyond its own window and files, as Flatpak grants it.").arg(root.appName)
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeBadgeSize
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }

    // The gap between the line and the cards, as between Information's rows.
    Item {
        width: 1
        height: Tokens.storeInfoRowGap - Tokens.storeProductLineGap
    }

    Grid {
        id: grid
        width: root.width
        columns: Math.max(1, Math.floor((width + columnSpacing) / (Tokens.storePermissionCardMinWidth + columnSpacing)))
        columnSpacing: Tokens.storePermissionCardGap
        rowSpacing: Tokens.storePermissionCardGap
        readonly property real cellWidth: (width - (columns - 1) * columnSpacing) / columns
        // Each card's own height, by index; the cards of one row are as tall as the tallest of them (macOS's cards line up).
        property var heights: []
        function report(index: int, height: real): void {
            if (grid.heights[index] === height)
                return;
            const next = grid.heights.slice();
            next[index] = height;
            grid.heights = next;
        }
        function rowHeight(index: int, own: real): real {
            const first = Math.floor(index / grid.columns) * grid.columns;
            let tallest = own;
            for (let i = first; i < first + grid.columns; i++)
                tallest = Math.max(tallest, grid.heights[i] ?? 0);
            return tallest;
        }

        Repeater {
            model: root.cards

            delegate: Rectangle {
                id: card
                required property var modelData
                required property int index
                width: grid.cellWidth
                implicitHeight: content.implicitHeight + 2 * Tokens.storePermissionCardPadding
                height: grid.rowHeight(card.index, card.implicitHeight)
                onImplicitHeightChanged: grid.report(card.index, card.implicitHeight)
                Component.onCompleted: grid.report(card.index, card.implicitHeight)
                radius: Tokens.storePermissionCardRadius
                color: Appearance.colors.groupFill
                Accessible.role: Accessible.Grouping
                Accessible.name: card.modelData.title

                Column {
                    id: content
                    x: Tokens.storePermissionCardPadding
                    y: Tokens.storePermissionCardPadding
                    width: card.width - 2 * Tokens.storePermissionCardPadding
                    spacing: Tokens.storePermissionItemGap

                    Icon {
                        name: card.modelData.icon
                        size: Tokens.storePermissionIconSize
                        color: Appearance.colors.accentInk
                    }

                    Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: card.modelData.title
                        wrapMode: Text.Wrap
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.storePermissionTitleSize
                        font.weight: Tokens.typographyMenuBoldWeight
                        Accessible.role: Accessible.Heading
                        Accessible.name: text
                    }

                    Repeater {
                        model: card.modelData.items

                        delegate: Column {
                            id: item
                            required property var modelData
                            width: content.width
                            spacing: Tokens.storeInfoLineGap
                            Accessible.role: Accessible.StaticText
                            Accessible.name: item.modelData.note !== "" ? item.modelData.text + ". " + item.modelData.note : item.modelData.text

                            Text {
                                width: parent.width
                                textFormat: Text.PlainText
                                text: item.modelData.text
                                wrapMode: Text.Wrap
                                color: Appearance.colors.text
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.storeInfoValueSize
                                Accessible.ignored: true
                            }

                            Text {
                                width: parent.width
                                visible: item.modelData.note !== ""
                                textFormat: Text.PlainText
                                text: item.modelData.note
                                wrapMode: Text.Wrap
                                color: Appearance.windowSecondary
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.storeInfoLabelSize
                                Accessible.ignored: true
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        visible: card.modelData.footnote !== ""
                        textFormat: Text.PlainText
                        text: card.modelData.footnote
                        wrapMode: Text.Wrap
                        color: Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.storeInfoLabelSize
                        Accessible.role: Accessible.StaticText
                        Accessible.name: text
                    }
                }
            }
        }
    }
}
