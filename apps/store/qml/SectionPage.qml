pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// Discover and the catalog's other sections (spec SR2, SR4): the section's blocks in order: hero carousels, cards, rows.
// Without the catalog, Discover is the Store's own: one row per category, each with "See All". With nothing to show at all
// (no catalog and no app data from Arch), the page says so and why, with Try Again, as macOS does when its store cannot
// be reached; never a blank page.
ScrollPage {
    id: root

    required property var section
    // Main.qml: still loading (nothing said yet), and the backend's state for the reason.
    property bool loading: false
    property var catalog: ({})
    property var appData: ({})
    property bool online: true

    signal opened(string id)
    signal categoryRequested(string id)
    signal retry
    // Arch's app data could not be downloaded (a package database older than the mirror, most often): Software Update.
    signal softwareUpdateRequested

    title: root.section.builtIn ? qsTr("Discover") : root.section.title
    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    // The blocks keyed by their kind, title and place, kept in step in place (SU-06): a new snapshot of the same section
    // changes what each block shows, never the blocks' items (a carousel keeps its card, a row its delegates).
    function blockKeys(): var {
        return (root.section.blocks || []).map((b, i) => (b.kind || "") + "|" + (b.title || "") + "|" + (b.category || "") + "|" + i);
    }
    onSectionChanged: sectionKeys.sync(root.blockKeys())
    Component.onCompleted: sectionKeys.sync(root.blockKeys())

    KeyedModel {
        id: sectionKeys
    }

    Repeater {
        model: sectionKeys

        delegate: Loader {
            id: block
            required property int index
            readonly property var modelData: (root.section.blocks || [])[block.index] || ({kind: "row", title: "", apps: []})
            width: root.contentWidth
            sourceComponent: modelData.kind === "hero" ? hero : modelData.kind === "cards" ? cards : row

            Component {
                id: hero
                HeroCarousel {
                    cardWidth: root.contentWidth
                    items: block.modelData.items
                    onOpened: id => root.opened(id)
                }
            }

            Component {
                id: cards
                CardShelf {
                    items: block.modelData.items
                    onOpened: id => root.opened(id)
                }
            }

            Component {
                id: row
                Item {
                    implicitHeight: shelf.implicitHeight

                    AppShelf {
                        id: shelf
                        width: parent.width
                        title: block.modelData.title || ""
                        apps: block.modelData.apps
                        onOpened: id => root.opened(id)
                    }

                    LinkText {
                        visible: (block.modelData.category || "") !== ""
                        anchors.right: parent.right
                        y: Math.round((shelf.titleHeight - height) / 2)
                        text: qsTr("See All")
                        target: block.modelData.title || ""
                        onActivated: root.categoryRequested(block.modelData.category)
                    }
                }
            }
        }
    }

    // Nothing to show.
    Column {
        id: unavailable
        visible: !root.loading && (root.section.blocks || []).length === 0
        width: root.contentWidth
        topPadding: Tokens.storeEmptyTop
        spacing: Tokens.storeEmptyGap
        Accessible.role: Accessible.AlertMessage
        Accessible.name: heading.text + " " + reason.text

        Text {
            id: heading
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: qsTr("The Store Isn't Available Right Now")
            wrapMode: Text.Wrap
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyTitleWeight
        }

        Text {
            id: reason
            width: Math.min(parent.width, Tokens.storeTextMaxWidth)
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: Store.unavailableReason(root.catalog, root.appData, root.online)
            wrapMode: Text.Wrap
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Tokens.spacingMd

            Button {
                visible: root.online && root.appData.problem === "download"
                push: true
                text: qsTr("Open Software Update")
                onClicked: root.softwareUpdateRequested()
            }

            Button {
                push: true
                text: qsTr("Try Again")
                onClicked: root.retry()
            }
        }
    }
}
