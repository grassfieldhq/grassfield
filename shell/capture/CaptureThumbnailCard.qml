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
// windows.lua: a card is unmapped at once when a capture starts, the lock comes or a toolbar opens (the helper's acknowledgement
// depends on it) and keeps its state across that (no slide-in again, its timer paused and then resumed). Its slide-in and its
// slide-out toward the screen edge (timeout, Close, a swipe, an action) are its own, a fade only under Reduce Motion.
//
// The card is the picture itself (macOS 27: no plate around it): a rounded clip, a device-pixel rim and a shadow; only the
// Capture Text card has a glass of its own, as tall as its first lines. Every size is on whole device pixels (CaptureThumbs.cardSize).
// The picture is a PNG the shell made from the capture (CaptureThumbnails.makeCopy), never the capture file itself.
// A press on the picture: a click opens a screenshot in the Screenshot app (a recording in Preview), a drag toward the screen edge
// follows the pointer and, on release, dismisses it when it went far enough or was a flick (CaptureThumbs.swipeDismisses), a drag
// the other way is a drag of the file to another application (text/uri-list, as the desktop icons).
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
    // A text card from a QR code says so (the data is never shown).
    readonly property bool isQr: win.isText && win.card.qr === true
    readonly property string textTitle: win.isQr ? qsTr("QR code copied to the clipboard") : qsTr("Text copied to the clipboard")
    // On its way out (the controller marks it) and the slide-out's progress.
    readonly property bool leaving: win.controller.leaving[win.cardId] === true
    property real departure: 0
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
    // The picture is made, or refused (the glyph shows instead): a card with none to make is ready at once.
    readonly property bool pictureReady: (win.isText && win.controller.textLines[win.cardId] !== undefined) || win.recording || ["ok", "no"].indexOf(win.controller.copyState(win.cardId)) >= 0
    // Whether the card is mapped. The screen is read from the model (card.screen), not from `win.screen`: the window's own screen
    // is bound to the card and is set again when the window is created, which made this binding depend on its own change.
    readonly property bool shown: win.controller.mapped && win.verified && win.pictureReady && win.card !== null && win.entry !== null && win.onScreen
    readonly property bool onScreen: win.card !== null && Quickshell.screens.some(s => s.name === win.card.screen)

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
    // Whole points around the card: the card sits `edge` from the screen edge and the Dock, on a device pixel.
    implicitWidth: Math.ceil(win.entry ? win.entry.width : 0) + 2 * win.edge
    implicitHeight: Math.ceil(win.entry ? win.entry.height : 0) + 2 * win.edge
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
    // Blurred behind whatever translucent surface shows (the text card, a recording's placeholder, a picture loading or refused);
    // only a fully opaque picture has none.
    BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.shown && Thumbs.blurWanted(win.isText, image.visible) ? blur : null
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
                win.controller.makeCopy(win.cardId);
            } else {
                win.controller.remove(win.cardId);
            }
        });
    }

    // Closes after capture.thumbnailSeconds. Not hidden by a capture, the lock or a toolbar, not hovered, not dragged and not leaving:
    // it is paused otherwise and goes on with what was left (hiding keeps the time; the pointer leaving gives the full time again).
    property real remaining: win.controller.seconds * 1000
    property real startedAt: 0
    Timer {
        id: closing

        interval: Math.max(1, win.remaining)
        running: win.shown && win.controller.seconds > 0 && !hover.hovered && !swipe.active && !win.leaving
        onRunningChanged: {
            if (running)
                win.startedAt = Date.now();
            else
                win.remaining = Thumbs.remainingAfter(win.remaining, win.startedAt, Date.now());
        }
        onTriggered: win.controller.dismiss(win.cardId)
    }

    // 0 while the card has not come in, 1 once it has: a slide in from the screen edge with a fade, a fade only under Reduce Motion.
    // Once only: a card mapped again after a capture, the lock or a toolbar is already in.
    property real arrival: 0
    property bool entered: false
    onShownChanged: {
        if (Thumbs.slidesIn(win.entered, win.shown)) {
            win.entered = true;
            win.arrival = 0;
            arrive.restart();
        }
        // A card that is leaving and is hidden goes at once: its slide-out has nothing to show.
        if (!win.shown && win.leaving)
            win.removeLater();
    }

    // Removes the card once the change that asked for it has finished notifying (it changes `cards`, which this card's own bindings
    // read); the controller and the id are taken now, the card may be gone by then.
    function removeLater(): void {
        const owner = win.controller;
        const id = win.cardId;
        Qt.callLater(() => owner.remove(id));
    }

    onLeavingChanged: {
        if (!win.leaving)
            return;
        if (win.shown)
            leave.restart();
        else
            win.removeLater();
    }

    // The slide out toward the screen edge, with a fade; then the card is removed.
    NumberAnimation {
        id: leave
        target: win
        property: "departure"
        from: 0
        to: 1
        duration: Appearance.duration(Tokens.motionNormal)
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Tokens.motionCurveExit
        onFinished: win.controller.remove(win.cardId)
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
        // A length in points on a whole device pixel.
        function snapped(v: real): real {
            const k = Math.max(1, Screen.devicePixelRatio);
            return Math.round(v * k) / k;
        }
        // The slide in, and the swipe toward the edge (the card follows the pointer, only toward it).
        property real swipeOffset: 0

        width: win.entry ? win.entry.width : 0
        height: win.entry ? win.entry.height : 0
        // Snapped to device pixels once the card is in; the slide-in and the swipe are free.
        readonly property real restX: plate.snapped(win.side === "left" ? win.edge : win.width - win.edge - plate.width)
        x: restX + plate.outward * ((Appearance.reduceMotion ? 0 : (1 - win.arrival) * Tokens.captureThumbnailDismissSlide + win.departure * plate.width) + plate.swipeOffset)
        y: plate.snapped(win.height - win.edge - plate.height)
        opacity: win.arrival * (1 - win.departure) * (1 - Math.min(1, Math.abs(plate.swipeOffset) / (2 * Tokens.captureThumbnailDismissDistance)))
        Accessible.role: win.isText ? Accessible.StaticText : Accessible.Button
        Accessible.name: win.isText ? win.textTitle + (win.card !== null && win.card.text !== "" ? ", " + win.card.text : "") : win.recording ? qsTr("Screen recording") : (win.card !== null && win.card.pixels !== null ? qsTr("Screenshot, %1 × %2").arg(win.card.pixels.w).arg(win.card.pixels.h) : qsTr("Screenshot"))
        Accessible.description: win.isText ? "" : (win.recording ? qsTr("Opens it in Preview") : qsTr("Opens it for editing"))
        Accessible.onPressAction: {
            if (!win.isText)
                win.controller.act(Thumbs.clickAction(win.card), win.cardId);
        }

        // The shadow of the picture (outside its shape), and the glass of a Capture Text card (a text surface: the menus' class). The
        // picture covers it: its rim is drawn over the picture below.
        Material {
            id: material

            glassClass: "menu"
            anchors.fill: parent
            radius: Tokens.captureThumbnailRadius
            highlightEnabled: win.isText
            borderEnabled: win.isText
        }

        Item {
            id: picture

            width: plate.width
            height: plate.height
            visible: !win.isText

            // The picture, decoded at the size it shows (never the capture's full size: a 4K capture is 33 MB decoded).
            Image {
                id: image

                anchors.fill: parent
                visible: !win.recording && !win.isText && status === Image.Ready
                // The PNG the shell made, never the capture file: no decoder of the shell touches that.
                source: win.verified && !win.recording && !win.isText ? win.controller.copyUrl(win.cardId) : ""
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

                Icon {
                    anchors.centerIn: parent
                    name: win.recording ? "film" : "camera"
                    size: Tokens.captureThumbnailButtonSize
                }
            }

            // The picture's rounded clip: the card's corner.
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
            radius: Tokens.captureThumbnailRadius
            visible: false
            layer.enabled: true
        }

        // The picture's rim, one device pixel wide at every scale (ADR-0024): the dark edge on its outline and the light specular
        // line just inside it, over the picture.
        Rectangle {
            visible: !win.isText
            anchors.fill: parent
            radius: Tokens.captureThumbnailRadius
            color: "transparent"
            border.width: material.hairline
            border.color: Appearance.withAlpha(material.borderColor, material.borderOpacity)
        }

        Rectangle {
            visible: !win.isText
            anchors.fill: parent
            anchors.margins: material.hairline
            radius: Math.max(0, Tokens.captureThumbnailRadius - material.hairline)
            color: "transparent"
            border.width: material.hairline
            border.color: Appearance.withAlpha(Appearance.colors.materialHighlight, material.highlightOpacity / 2)
        }

        // Measures the recognised text the way the card shows it (it wraps by words, so only a Text knows the lines): the lines it
        // takes, at most the token's, are what the controller sizes the card by. Not shown.
        Text {
            id: measure

            visible: false
            width: Tokens.captureThumbnailWidth - 2 * win.controller.textPad
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            maximumLineCount: Tokens.captureThumbnailTextLines
            text: win.isText && win.card !== null && !win.isQr ? win.card.text : ""
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            onLineCountChanged: win.controller.setTextLines(win.cardId, measure.lineCount)
            Component.onCompleted: if (win.isText)
                win.controller.setTextLines(win.cardId, measure.lineCount)
        }

        // Capture Text: the title and the first lines of what was recognised, in a card as tall as they are.
        Column {
            visible: win.isText
            x: win.controller.textPad
            y: win.controller.textPad
            width: plate.width - 2 * win.controller.textPad
            spacing: Tokens.spacingXs

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: win.textTitle
                color: Appearance.colors.text
                elide: Text.ElideRight
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Tokens.typographyTitleWeight
            }

            Text {
                visible: text !== ""
                width: parent.width
                textFormat: Text.PlainText
                text: win.isText && win.card !== null && !win.isQr ? win.card.text : ""
                color: Appearance.colors.textSecondary
                wrapMode: Text.Wrap
                elide: Text.ElideRight
                maximumLineCount: win.entry ? Math.max(1, win.entry.lines) : 1
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }

        // Click: open it. Drag toward the edge: dismiss. Drag elsewhere: the file to another application.
        MouseArea {
            id: opener

            anchors.fill: picture
            enabled: !win.isText
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.PointingHandCursor
            onClicked: win.controller.act(Thumbs.clickAction(win.card), win.cardId)
        }

        HoverHandler {
            id: hover

            onHoveredChanged: {
                if (!hovered)
                    win.remaining = win.controller.seconds * 1000;
                if (hovered && win.verified && !win.isText)
                    win.controller.verify(win.cardId, ok => {
                        win.dragOk = ok;
                        if (!ok)
                            win.controller.remove(win.cardId);
                    });
            }
        }

        DragHandler {
            id: swipe

            property string intent: ""
            // Where the card was pulled to, and how fast toward the edge at the last move: kept here because the handler's translation
            // is reset to zero as the press ends, before (or while) `active` goes false, so the release cannot read it.
            property real pulled: 0
            property real speed: 0

            target: null
            enabled: !win.isText
            acceptedButtons: Qt.LeftButton
            dragThreshold: Tokens.captureThumbnailDragThreshold
            // The press is a drag from the moment `active` is true. Its direction is that of the whole press-to-now vector once the
            // pointer is a drag threshold away (never of the first pixels of a move), read at the first move after activation.
            onActiveChanged: {
                if (active) {
                    intent = "";
                    pulled = 0;
                    speed = 0;
                } else {
                    if (intent === "swipe") {
                        if (Thumbs.swipeDismisses(win.side, pulled, speed, Tokens.captureThumbnailDismissDistance, Tokens.captureThumbnailFlickVelocity))
                            win.controller.dismiss(win.cardId);
                        else
                            plate.swipeOffset = 0;
                    }
                    out.stop();
                    intent = "";
                }
            }
            onTranslationChanged: {
                // The reset at the end of the press is not a move.
                if (!active || (translation.x === 0 && translation.y === 0))
                    return;
                if (intent === "") {
                    intent = Thumbs.intentAt(win.side, centroid.scenePosition.x - centroid.scenePressPosition.x, centroid.scenePosition.y - centroid.scenePressPosition.y, Tokens.captureThumbnailDragThreshold);
                    if (intent === "")
                        return;
                    if (intent === "out" && !win.dragOk) {
                        intent = "none";
                        return;
                    }
                    if (intent === "out")
                        out.start();
                }
                if (intent !== "swipe")
                    return;
                pulled = translation.x;
                speed = Thumbs.towardVelocity(win.side, centroid.velocity.x);
                plate.swipeOffset = Math.max(0, pulled * plate.outward);
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

        // Close, at the picture's top corner on the screen's inner side (toward the middle of the display); the actions are on the
        // outer side. The picture is never narrower than the two side by side (CaptureThumbs.leastPictureWidth).
        Item {
            visible: hover.hovered && !swipe.active
            x: win.side === "right" ? Tokens.captureThumbnailInset : picture.width - width - Tokens.captureThumbnailInset
            y: Tokens.captureThumbnailInset
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

        // Copy, Show in Files and Move to Trash, in a capsule at the picture's top corner on the screen's outer side.
        Item {
            id: actions

            visible: hover.hovered && !swipe.active && !win.isText
            width: buttons.implicitWidth + 2 * Tokens.spacingXs
            height: Tokens.captureThumbnailButtonSize + 2 * Tokens.spacingXs
            x: win.side === "right" ? picture.width - width - Tokens.captureThumbnailInset : Tokens.captureThumbnailInset
            y: Tokens.captureThumbnailInset

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
