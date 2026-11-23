pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import "CaptureThumbs.js" as Thumbs

// One floating thumbnail card (CaptureThumbnails owns the stack; spec docs/specs/capture-suite.md § 3.2): a layer surface of its
// own on the display the capture came from, sized to the card with room around it for the glass's shadow, mapped only while the
// controller says the cards may show and the file was confirmed (a regular file in a Save to folder, not a link). It takes no
// keyboard (the window being worked in stays key) and only the card itself takes the pointer. The layer has no_anim in
// windows.lua (a card is unmapped at once when a capture starts, never faded out), and its slide-in is its own.
//
// A press on the picture: a click opens it in Preview, a drag toward the screen edge dismisses it (the card follows the pointer),
// a drag the other way is a drag of the file to another application (text/uri-list, as the desktop icons).
// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: win

    required property var controller
    required property string cardId

    readonly property var card: win.controller.cardById(win.cardId)
    readonly property var entry: win.controller.entries[win.cardId] ?? null
    readonly property string side: win.controller.side
    readonly property bool recording: win.card !== null && win.card.kind === "recording"
    // Capture Text: no file, no picture; a card that says the text was copied, with Close only.
    readonly property bool isText: win.card !== null && win.card.kind === "text"
    readonly property real edge: Tokens.captureThumbnailEdgeMargin
    // The footprint of the Dock on this display: the cards keep clear of it on its edge.
    readonly property var dock: win.screen ? Settings.dockFootprintFor(win.screen.name, false) : ({
            left: 0,
            right: 0,
            bottom: 0
        })
    // The file was confirmed by the script (regular, not a link, in a Save to folder): nothing maps, loads or opens before.
    property bool verified: false
    // The file was confirmed again when the pointer reached the card: a drag out starts only on a confirmed file.
    property bool dragOk: false
    readonly property bool shown: win.controller.mapped && win.verified && win.screen !== null && win.entry !== null

    screen: win.card === null ? null : (Quickshell.screens.find(s => s.name === win.card.screen) ?? null)
    visible: win.shown
    anchors {
        bottom: true
        left: win.side === "left"
        right: win.side === "right"
    }
    // qmllint disable unqualified unresolved-type
    margins.bottom: win.dock.bottom + (win.entry ? win.entry.below : 0)
    margins.left: win.side === "left" ? win.dock.left : 0
    margins.right: win.side === "right" ? win.dock.right : 0
    // qmllint enable unqualified unresolved-type
    implicitWidth: (win.entry ? win.entry.width : 0) + 2 * win.edge
    implicitHeight: (win.entry ? win.entry.height : 0) + 2 * win.edge
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "grassfield-capture-thumbnail"
    // qmllint disable missing-type
    // Only the card takes the pointer; around it the click goes through.
    mask: Region {
        item: plate
    }
    BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.shown ? blur : null
    // qmllint enable missing-type

    Region {
        id: blur
        item: plate
        radius: Tokens.captureThumbnailRadius
    }

    // The file is confirmed before the card maps.
    Component.onCompleted: {
        if (win.isText) {
            win.verified = true;
            return;
        }
        win.controller.verify(win.cardId, ok => {
            if (ok) {
                win.verified = true;
                win.dragOk = true;
            } else {
                win.controller.dismiss(win.cardId);
            }
        });
    }

    // Closes after capture.thumbnailSeconds; hovering, dragging and a hidden card pause it (it starts again from the full time).
    Timer {
        interval: win.controller.seconds * 1000
        running: win.shown && win.controller.seconds > 0 && !hover.hovered && !swipe.active
        onTriggered: win.controller.dismiss(win.cardId)
    }

    // 0 while the card has not come in, 1 once it has: a slide in from the screen edge with a fade, a fade only under Reduce Motion.
    property real arrival: 0
    onShownChanged: {
        if (win.shown) {
            win.arrival = 0;
            arrive.restart();
        }
    }

    NumberAnimation {
        id: arrive
        target: win
        property: "arrival"
        from: 0
        to: 1
        duration: Appearance.duration(Tokens.motionNormal)
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Tokens.motionCurveEnter
    }

    Item {
        id: plate

        readonly property real outward: win.side === "left" ? -1 : 1
        // The slide in, and the swipe toward the edge (the card follows the pointer, only toward it).
        property real swipeOffset: 0

        width: win.entry ? win.entry.width : 0
        height: win.entry ? win.entry.height : 0
        x: win.edge + plate.outward * ((Appearance.reduceMotion ? 0 : (1 - win.arrival) * Tokens.captureThumbnailDismissSlide) + plate.swipeOffset)
        y: win.edge
        opacity: win.arrival * (1 - Math.min(1, Math.abs(plate.swipeOffset) / (2 * Tokens.captureThumbnailDismissDistance)))
        Accessible.role: win.isText ? Accessible.StaticText : Accessible.Button
        Accessible.name: win.isText ? qsTr("Text copied to the clipboard") + (win.card.text !== "" ? ", " + win.card.text : "") : win.recording ? qsTr("Screen recording") : (win.card !== null && win.card.pixels !== null ? qsTr("Screenshot, %1 × %2").arg(win.card.pixels.w).arg(win.card.pixels.h) : qsTr("Screenshot"))
        Accessible.description: win.isText ? "" : qsTr("Opens it in Preview")
        Accessible.onPressAction: {
            if (!win.isText)
                win.controller.act("open", win.cardId);
        }

        // The card's glass: a text-free surface of the menus' class.
        Material {
            glassClass: "menu"
            anchors.fill: parent
            radius: Tokens.captureThumbnailRadius
        }

        Item {
            id: picture

            x: Tokens.captureThumbnailInset
            y: Tokens.captureThumbnailInset
            width: win.entry ? win.entry.pictureWidth : 0
            height: win.entry ? win.entry.pictureHeight : 0

            // The picture, decoded at the size it shows (never the capture's full size: a 4K capture is 33 MB decoded).
            Image {
                id: image

                anchors.fill: parent
                visible: !win.recording && !win.isText && status === Image.Ready
                source: win.verified && !win.recording && !win.isText && win.card !== null ? Thumbs.fileUrl(win.card.path) : ""
                sourceSize: Qt.size(Math.ceil(picture.width * Screen.devicePixelRatio), Math.ceil(picture.height * Screen.devicePixelRatio))
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                smooth: true
                autoTransform: false
            }

            // A recording (its first frame comes with slice A9) and a picture still loading: the glyph of the kind.
            Rectangle {
                anchors.fill: parent
                visible: !image.visible
                color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)

                // Capture Text: what was recognised, a few lines of it, elided.
                Column {
                    visible: win.isText
                    anchors.fill: parent
                    anchors.margins: Tokens.captureThumbnailInset
                    spacing: Tokens.spacingXs

                    Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: qsTr("Text copied to the clipboard")
                        color: Appearance.colors.text
                        elide: Text.ElideRight
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                        font.weight: Tokens.typographyTitleWeight
                    }

                    Text {
                        width: parent.width
                        height: parent.height - y
                        textFormat: Text.PlainText
                        text: win.isText ? win.card.text : ""
                        color: Appearance.colors.textSecondary
                        wrapMode: Text.Wrap
                        elide: Text.ElideRight
                        // As many lines as the card has room for, the last one elided.
                        maximumLineCount: Math.max(1, Math.floor(height / snippetMetrics.height))
                        clip: true
                        FontMetrics {
                            id: snippetMetrics
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                        }
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                    }
                }

                Icon {
                    visible: !win.isText
                    anchors.centerIn: parent
                    name: win.recording ? "film" : "camera"
                    size: Tokens.captureThumbnailButtonSize
                }
            }

            // The corners of the picture are the card's radius less its inset: concentric.
            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: pictureMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
            }
        }

        Rectangle {
            id: pictureMask

            width: picture.width
            height: picture.height
            radius: Tokens.captureThumbnailPictureRadius
            visible: false
            layer.enabled: true
        }

        // Click: open it. Drag toward the edge: dismiss. Drag elsewhere: the file to another application.
        MouseArea {
            id: opener

            anchors.fill: picture
            enabled: !win.isText
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.PointingHandCursor
            onClicked: win.controller.act("open", win.cardId)
        }

        HoverHandler {
            id: hover

            onHoveredChanged: {
                if (hovered && win.verified && !win.isText)
                    win.controller.verify(win.cardId, ok => {
                        win.dragOk = ok;
                        if (!ok)
                            win.controller.dismiss(win.cardId);
                    });
            }
        }

        DragHandler {
            id: swipe

            property string intent: ""

            target: null
            enabled: !win.isText
            acceptedButtons: Qt.LeftButton
            dragThreshold: Tokens.captureThumbnailDragThreshold
            onActiveChanged: {
                if (active) {
                    intent = Thumbs.dragIntent(win.side, translation.x, translation.y);
                    if (intent === "out" && !win.dragOk) {
                        intent = "";
                        return;
                    }
                    if (intent === "out")
                        out.start();
                } else {
                    if (intent === "swipe") {
                        if (Thumbs.dismissed(win.side, plate.swipeOffset * plate.outward, Tokens.captureThumbnailDismissDistance))
                            win.controller.dismiss(win.cardId);
                        plate.swipeOffset = 0;
                    }
                    out.stop();
                    intent = "";
                }
            }
            onTranslationChanged: {
                if (active && intent === "swipe")
                    plate.swipeOffset = Math.max(0, translation.x * plate.outward);
            }
        }

        // The drag of the file to another application (a real drag-and-drop, wl_data_device, as the desktop icons): its URI only.
        Item {
            id: out

            property url dragImage: ""

            width: picture.width
            height: picture.height
            visible: false
            Drag.dragType: Drag.Automatic
            Drag.supportedActions: Qt.CopyAction
            Drag.proposedAction: Qt.CopyAction
            Drag.imageSource: out.dragImage
            Drag.onDragFinished: dropAction => {
                if (dropAction !== Qt.IgnoreAction)
                    win.controller.dismiss(win.cardId);
            }

            function start(): void {
                picture.grabToImage(result => {
                    if (swipe.active && swipe.intent === "out" && win.card !== null) {
                        out.dragImage = result.url;
                        out.Drag.hotSpot = Qt.point(picture.width / 2, picture.height / 2);
                        out.Drag.mimeData = {
                            "text/uri-list": Thumbs.uriList(win.card.path)
                        };
                        out.Drag.active = true;
                    }
                });
            }

            function stop(): void {
                out.Drag.active = false;
            }
        }

        // Close, at the picture's top corner on the screen's inner side.
        Item {
            visible: hover.hovered && !swipe.active
            x: picture.x + Tokens.captureThumbnailInset
            y: picture.y + Tokens.captureThumbnailInset
            width: Tokens.captureThumbnailButtonSize + 2 * Tokens.spacingXs
            height: width

            Material {
                glassClass: "menu"
                anchors.fill: parent
                radius: height / 2
            }

            ToolButton {
                anchors.centerIn: parent
                width: Tokens.captureThumbnailButtonSize
                height: Tokens.captureThumbnailButtonSize
                capsule: true
                buttonSize: Tokens.captureThumbnailButtonSize
                glyphSize: Tokens.captureThumbnailButtonIconSize
                iconName: "xmark-circle-fill"
                accessibleName: qsTr("Close")
                onClicked: win.controller.dismiss(win.cardId)
            }
        }

        // Copy, Show in Files and Move to Trash, in a capsule at the picture's top right.
        Item {
            id: actions

            visible: hover.hovered && !swipe.active && !win.isText
            width: buttons.implicitWidth + 2 * Tokens.spacingXs
            height: Tokens.captureThumbnailButtonSize + 2 * Tokens.spacingXs
            x: picture.x + picture.width - width - Tokens.captureThumbnailInset
            y: picture.y + Tokens.captureThumbnailInset

            Material {
                glassClass: "menu"
                anchors.fill: parent
                radius: height / 2
            }

            Row {
                id: buttons

                anchors.centerIn: parent

                ToolButton {
                    visible: !win.recording
                    width: visible ? Tokens.captureThumbnailButtonSize : 0
                    height: Tokens.captureThumbnailButtonSize
                    capsule: true
                    buttonSize: Tokens.captureThumbnailButtonSize
                    glyphSize: Tokens.captureThumbnailButtonIconSize
                    iconName: "copy"
                    accessibleName: qsTr("Copy")
                    onClicked: win.controller.act("copy", win.cardId)
                }

                ToolButton {
                    width: Tokens.captureThumbnailButtonSize
                    height: Tokens.captureThumbnailButtonSize
                    capsule: true
                    buttonSize: Tokens.captureThumbnailButtonSize
                    glyphSize: Tokens.captureThumbnailButtonIconSize
                    iconName: "folder"
                    accessibleName: qsTr("Show in Files")
                    onClicked: win.controller.act("reveal", win.cardId)
                }

                ToolButton {
                    width: Tokens.captureThumbnailButtonSize
                    height: Tokens.captureThumbnailButtonSize
                    capsule: true
                    buttonSize: Tokens.captureThumbnailButtonSize
                    glyphSize: Tokens.captureThumbnailButtonIconSize
                    iconName: "trash"
                    accessibleName: qsTr("Move to Trash")
                    onClicked: win.controller.act("trash", win.cardId)
                }
            }
        }
    }
}
