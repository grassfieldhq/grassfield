pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui
import qs.services
import qs.overlay.controlcenter

// Now Playing module (CC7, 2x2): artwork, title, artist and transport controls of the active MPRIS
// player. Always shown (macOS: "Not Playing" while idle); the controls are disabled without a player.
Module {
    id: root

    readonly property real pad: Tokens.quicksettingsPadding

    cols: 2
    rows: 2
    Accessible.role: Accessible.Grouping
    Accessible.name: qsTr("Now Playing")

    // A cover art's corner, as macOS 27's Control Center (ADR-0039 step 13, G5): a real mask, as the Overview's thumbnails
    // (UI audit 2026-11-05 U3: clip on a Rectangle clips to its bounding box, the corners stayed square).
    Item {
        id: art
        x: root.pad
        y: root.pad
        width: Tokens.panelCcArtSize
        height: width
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: artMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }

        Rectangle {
            anchors.fill: parent
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        }

        Image {
            anchors.fill: parent
            // Never the player's URL: a PNG the shell made from its file or https resource (ThemeIcons.artSource).
            source: ThemeIcons.artSource(Media.artShown)
            sourceSize: Qt.size(Tokens.panelCcArtSize * 2, Tokens.panelCcArtSize * 2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
        }
    }

    Rectangle {
        id: artMask
        width: art.width
        height: art.height
        radius: Tokens.radiusArtwork
        visible: false
        layer.enabled: true
    }

    // macOS: the artwork and the title open the app that plays; the panel closes.
    function openApp(): void {
        Popups.close();
        Media.openPlayerApp(true);
    }

    MouseArea {
        x: root.pad
        y: art.y
        width: root.width - 2 * root.pad
        height: art.height + titles.height + Tokens.spacingXs
        enabled: Media.available
        cursorShape: Qt.ArrowCursor
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Open the app that is playing")
        Accessible.onPressAction: root.openApp()
        onClicked: root.openApp()
    }

    Column {
        id: titles
        x: root.pad
        y: art.y + art.height + Tokens.spacingXs
        width: root.width - 2 * root.pad

        Label {
            width: parent.width
            text: Media.title !== "" ? Media.title : qsTr("Not playing")
        }

        Caption {
            width: parent.width
            visible: text !== ""
            text: Media.artist
        }
    }

    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.height - height - Tokens.spacingSm
        spacing: Tokens.spacingXs

        Repeater {
            model: [
                {icon: "media-prev", name: qsTr("Previous track"), action: "previous"},
                {icon: Media.playing ? "media-pause" : "media-play", name: Media.playing ? qsTr("Pause") : qsTr("Play"), action: "toggle"},
                {icon: "media-next", name: qsTr("Next track"), action: "next"}
            ]

            delegate: NavItem {
                id: button

                required property var modelData

                // Idle (macOS: "Not Playing"): the module stays, its controls do nothing.
                enabled: Media.available
                opacity: enabled ? 1 : Tokens.materialDisabledOpacity
                width: Tokens.panelCcTransportButton
                height: width
                accessibleName: modelData.name
                ringRadius: width / 2
                onActivated: {
                    if (modelData.action === "toggle")
                        Media.togglePlaying();
                    else if (modelData.action === "next")
                        Media.next();
                    else
                        Media.previous();
                }

                // Pressed: the shared pressed fill on a disk behind the glyph (LOW, UI audit 2026-11-05).
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Appearance.withAlpha(Appearance.colors.hover, Tokens.controlPressedOpacity)
                    visible: press.pressed
                }

                Icon {
                    anchors.centerIn: parent
                    size: Tokens.menuIconSize
                    name: button.modelData.icon
                }

                MouseArea {
                    id: press
                    anchors.fill: parent
                    cursorShape: Qt.ArrowCursor
                    onClicked: {
                        button.forceActiveFocus();
                        button.activated();
                    }
                }
            }
        }
    }
}
