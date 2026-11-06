pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui
import qs.services
import qs.widgets

// Now Playing widget: the active MPRIS player's track (small: art and title; medium: art, title,
// artist and transport). Says "Not Playing" when no player runs or nothing is loaded. Transport
// buttons act on the owner's real player, so a development session (GRASSFIELD_DEV=1) disables them.
WidgetBase {
    id: root

    readonly property bool hasTrack: Media.available && Media.title !== ""
    readonly property bool transportEnabled: Media.available && !devSession

    Accessible.role: Accessible.StaticText
    Accessible.name: hasTrack ? qsTr("Now Playing, %1, %2").arg(Media.title).arg(Media.artist) : qsTr("Not Playing")

    function transport(action: string): void {
        if (!transportEnabled) {
            console.info("widgets: now playing transport suppressed in a development session");
            return;
        }
        if (action === "toggle")
            Media.togglePlaying();
        else if (action === "next")
            Media.next();
        else
            Media.previous();
    }

    // A cover art's corner, concentric with the tile (ADR-0039 step 13, G5): a real mask, as the Overview's thumbnails
    // (UI audit 2026-11-05 U3: clip on a Rectangle clips to its bounding box, the corners stayed square).
    Item {
        id: art

        readonly property real edge: root.isSmall ? Tokens.widgetBigSize : root.height - 2 * root.padding

        x: root.padding
        y: root.padding
        width: edge
        height: edge
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
            source: root.hasTrack ? ThemeIcons.artSource(Media.artShown) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: status === Image.Ready
            sourceSize: Qt.size(art.width * 2, art.height * 2)
        }

        Icon {
            anchors.centerIn: parent
            size: parent.width / 2
            name: "media-play"
            color: Appearance.colors.textSecondary
            visible: !root.hasTrack
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

    // macOS: the artwork and the title open the app that plays (not while the widgets are being edited).
    MouseArea {
        x: art.x
        y: art.y
        width: root.isSmall ? art.width : text.x + text.width - art.x
        height: root.isSmall ? text.y + text.height - art.y : art.height
        enabled: root.transportEnabled && root.hasTrack
        cursorShape: Qt.ArrowCursor
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Open the app that is playing")
        Accessible.onPressAction: Media.openPlayerApp(false)
        onClicked: Media.openPlayerApp(false)
    }

    Column {
        id: text

        x: root.isSmall ? root.padding : art.x + art.width + root.padding
        y: root.isSmall ? art.y + art.height + Tokens.spacingSm : root.padding
        width: root.width - x - root.padding
        spacing: Tokens.spacingXs

        WidgetLabel {
            width: parent.width
            text: root.hasTrack ? Media.title : qsTr("Not Playing")
            font.weight: Tokens.typographyMenuBoldWeight
            font.pixelSize: root.isSmall ? Tokens.typographyBodySize : Tokens.typographyTitleSize
            color: root.hasTrack ? Appearance.colors.text : Appearance.colors.textSecondary
            wrapMode: root.isSmall ? Text.Wrap : Text.NoWrap
            maximumLineCount: root.isSmall ? 2 : 1
        }

        WidgetLabel {
            width: parent.width
            visible: root.hasTrack && Media.artist !== ""
            text: Media.artist
            color: Appearance.colors.textSecondary
        }
    }

    Row {
        id: buttons

        visible: !root.isSmall
        x: text.x
        y: root.height - height - root.padding
        spacing: Tokens.spacingMd
        opacity: root.transportEnabled ? 1 : Tokens.materialDisabledOpacity

        Repeater {
            model: [
                {
                    icon: "media-prev",
                    name: qsTr("Previous track"),
                    action: "previous"
                },
                {
                    icon: Media.playing ? "media-pause" : "media-play",
                    name: Media.playing ? qsTr("Pause") : qsTr("Play"),
                    action: "toggle"
                },
                {
                    icon: "media-next",
                    name: qsTr("Next track"),
                    action: "next"
                }
            ]

            delegate: Item {
                id: button

                required property var modelData

                width: Tokens.panelWidgetTransportButton
                height: width
                activeFocusOnTab: root.transportEnabled
                Accessible.role: Accessible.Button
                Accessible.name: modelData.name
                Accessible.focusable: true
                Accessible.onPressAction: root.transport(modelData.action)

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return) {
                        root.transport(button.modelData.action);
                        event.accepted = true;
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                }

                // Pressed: the shared pressed fill over the disk (LOW, UI audit 2026-11-05).
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Appearance.withAlpha(Appearance.colors.hover, Tokens.controlPressedOpacity)
                    visible: press.pressed
                }

                // The shared ring outside the button, after a key only (ADR-0039 step 7).
                KeyFocus {
                    id: buttonFocus
                }

                FocusRing {
                    shapeRadius: width / 2
                    visible: buttonFocus.active
                }

                Icon {
                    anchors.centerIn: parent
                    size: Tokens.menuIconSize
                    name: button.modelData.icon
                }

                MouseArea {
                    id: press
                    anchors.fill: parent
                    enabled: root.transportEnabled
                    cursorShape: Qt.ArrowCursor
                    onClicked: root.transport(button.modelData.action)
                }
            }
        }
    }
}
