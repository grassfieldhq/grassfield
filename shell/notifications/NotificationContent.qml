pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui

// Icon, title, relative time, sanitized body and action buttons of one notification. Used by
// banners and by the Notification Center rows. Pure presentation: actions are reported through
// signals (the host decides what they do).
Item {
    id: root

    // Model row fields (see Notifications.rowOf). live: the sender still holds the notification.
    property string summary: ""
    property string appName: ""
    property int urgency: 1
    property string actionsJson: "[]"
    property bool live: false
    property int maxBodyLines: Tokens.notificationBannerBodyLines
    property string body: ""
    property string timeText: ""
    // The app's icon (the tile at the leading edge, always: UI audit 2026-11-05 U27) and the picture the app attached,
    // shown as a rounded thumbnail at the trailing edge (macOS); "" for none.
    property string iconSource: ""
    property string imageSource: ""
    readonly property bool hasThumbnail: imageSource !== "" && !thumbCanvas.failed
    // "default" is the click action, never a button. Dead and restored entries have none.
    readonly property var buttons: live ? JSON.parse(actionsJson).filter(a => a.id !== "default" && a.id !== "") : []
    property bool moreOpen: false
    // Space kept free at the right of the title row (the Center's remove button).
    property real trailingReserve: 0

    signal actionTriggered(string actionId)
    // The set of focusable action buttons changed (the sender's actions went away, More revealed the rest): the Center's focus
    // resolver (NotificationList.resolveFocus) re-checks where the keyboard focus is.
    signal controlsChanged
    // The Flow of action buttons (null unless the entry is live and has buttons).
    readonly property var actionFlow: actionLoader.item

    // The focusable items of this content in Tab order, usable or not: {role: "action:<id>" or "more", item}.
    function focusItems(): var {
        const out = [];
        const flow = root.actionFlow;
        if (!flow)
            return out;
        for (let i = 0; i < flow.repeater.count; i++) {
            const b = flow.repeater.itemAt(i);
            if (b)
                out.push({role: "action:" + b.modelData.id, item: b});
        }
        out.push({role: "more", item: flow.moreButton});
        return out;
    }

    implicitWidth: Tokens.notificationBannerWidth
    implicitHeight: Math.max(Tokens.notificationBannerIconSize, root.hasThumbnail ? Tokens.notificationThumbnailSize : 0, column.implicitHeight)

    // Icon tile: the app icon, or a bell on a neutral tile.
    Item {
        id: iconTile
        x: Tokens.notificationIconInset
        // Centred on the whole card, as in the reference (also beside a five-line body).
        y: Math.max(0, (root.implicitHeight - height) / 2)
        width: Tokens.notificationBannerIconSize
        height: Tokens.notificationBannerIconSize

        Rectangle {
            anchors.fill: parent
            // An app icon's corner at its size, no longer the Dock's (ADR-0039 step 13, G5).
            radius: Tokens.notificationIconRadius
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            visible: appImage.status !== Image.Ready
        }

        Icon {
            anchors.centerIn: parent
            size: Tokens.menuIconSize + Tokens.notificationIconGlyphExtra
            name: "bell"
            visible: appImage.status !== Image.Ready
        }

        Image {
            id: appImage
            anchors.fill: parent
            source: root.iconSource
            // Images are limited to 256 px (N9).
            sourceSize: Qt.size(Tokens.notificationImageMax, Tokens.notificationImageMax)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
            mipmap: true
        }
    }

    Column {
        id: column
        x: iconTile.x + iconTile.width + Tokens.notificationTextGap
        width: root.width - x - (root.hasThumbnail ? Tokens.notificationThumbnailSize + Tokens.notificationThumbnailGap : 0)
        spacing: Tokens.notificationLineGap

        Item {
            width: parent.width
            height: title.implicitHeight

            // On the title's baseline (LOW, UI audit 2026-11-05: the smaller caption sat above it).
            Text {
                textFormat: Text.PlainText
                id: stamp
                anchors.right: parent.right
                anchors.rightMargin: root.trailingReserve
                anchors.baseline: title.baseline
                text: root.timeText
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                font.weight: Tokens.typographySmallWeight
            }

            Text {
                id: title
                width: parent.width - stamp.implicitWidth - Tokens.spacingSm - root.trailingReserve
                text: root.summary !== "" ? root.summary : root.appName
                textFormat: Text.PlainText
                color: root.urgency === 2 ? Appearance.colors.danger : Appearance.colors.text
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Tokens.typographyMenuBoldWeight
            }
        }

        Text {
            width: parent.width
            visible: text !== ""
            text: root.body
            textFormat: Text.StyledText
            color: Appearance.colors.text
            wrapMode: Text.Wrap
            maximumLineCount: root.maxBodyLines
            elide: Text.ElideRight
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographyMenuWeight
        }

        // No delegate exists unless the notification is live and has buttons: a sender's labels
        // never instantiate for dead, expired or restored entries.
        Loader {
            id: actionLoader
            width: parent.width
            active: root.buttons.length > 0
            visible: active
            sourceComponent: actionRow
            onItemChanged: root.controlsChanged()
        }
    }

    // The attached picture: a rounded thumbnail at the trailing edge, centred on the card as the icon tile (U27). Drawn once
    // into a Canvas the thumbnail's size, cropped and with its rounded corners (audit B-19): the picture an app attaches as
    // image data comes from Quickshell's image provider at the size it was sent (the provider ignores the requested size), up
    // to about 5.7k x 5.7k pixels, and an Image held that whole texture for a 40 px thumbnail, per notification, behind a
    // mask layer (two FBOs). The full picture is only decoded for the draw and let go after it; what stays is the Canvas's
    // own small image.
    Item {
        id: thumbnail
        visible: root.hasThumbnail
        x: root.width - width
        y: Math.max(0, (root.implicitHeight - height) / 2)
        width: Tokens.notificationThumbnailSize
        height: width

        Rectangle {
            anchors.fill: parent
            radius: Tokens.notificationThumbnailRadius
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            visible: !thumbCanvas.drawn
        }

        // Reads the picture's size (never drawn: an invisible Image makes no texture); its source is let go once drawn.
        Image {
            id: thumbImage
            visible: false
            source: thumbCanvas.drawn ? "" : thumbCanvas.wanted
            asynchronous: true
            onStatusChanged: {
                if (status === Image.Ready) {
                    thumbCanvas.natural = Qt.size(implicitWidth, implicitHeight);
                    thumbCanvas.loadImage(thumbCanvas.wanted);
                    // A picture the canvas already holds gives no imageLoaded.
                    if (thumbCanvas.isImageLoaded(thumbCanvas.wanted))
                        thumbCanvas.requestPaint();
                } else if (status === Image.Error)
                    thumbCanvas.failed = true;
            }
        }

        Canvas {
            id: thumbCanvas

            // The picture to draw; `drawnFrom` is the one on the canvas now.
            readonly property string wanted: root.imageSource
            property string drawnFrom: ""
            readonly property bool drawn: drawnFrom !== "" && drawnFrom === wanted
            // The picture's size in pixels (thumbImage's), read before its source is let go.
            property size natural: Qt.size(0, 0)
            // It could not be read (the card then shows no thumbnail).
            property bool failed: false

            anchors.fill: parent
            onWantedChanged: {
                failed = false;
                drawnFrom = "";
                requestPaint();
            }
            onImageLoaded: requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const url = thumbCanvas.wanted;
                if (url === "" || !thumbCanvas.isImageLoaded(url) || natural.width <= 0 || natural.height <= 0)
                    return;
                // Rounded corners, then the picture cropped to fill the square (PreserveAspectCrop).
                const r = Math.min(Tokens.notificationThumbnailRadius, width / 2, height / 2);
                ctx.beginPath();
                ctx.roundedRect(0, 0, width, height, r, r);
                ctx.clip();
                const scale = Math.max(width / natural.width, height / natural.height);
                const w = natural.width * scale;
                const h = natural.height * scale;
                ctx.drawImage(url, (width - w) / 2, (height - h) / 2, w, h);
                thumbCanvas.unloadImage(url);
                thumbCanvas.drawnFrom = url;
                // The full picture is not needed any more (`drawn` lets thumbImage's source go).
            }
        }
    }

    Component {
        id: actionRow

        Flow {
            id: actions
            width: column.width
            spacing: Tokens.spacingSm
            topPadding: Tokens.spacingXs
            readonly property Repeater repeater: rep
            readonly property Item moreButton: more

            // macOS: equal-width capsules spanning the card, 22 tall. More reveals the rest on further rows of the same
            // capsules (LOW, UI audit 2026-11-05: they were squeezed into one row down to "…"); never more than
            // notificationMaxActions + 1 to a row.
            readonly property int shownCount: rep.count + (more.visible ? 1 : 0)
            readonly property int perRow: Math.min(shownCount, Tokens.notificationMaxActions + 1)
            readonly property real equalWidth: perRow > 0 ? (width - (perRow - 1) * spacing) / perRow : width

            Repeater {
                id: rep
                onItemAdded: root.controlsChanged()
                onItemRemoved: root.controlsChanged()
                model: root.buttons.slice(0, root.moreOpen ? root.buttons.length : Tokens.notificationMaxActions)

                delegate: Button {
                    required property var modelData
                    width: actions.equalWidth
                    height: Tokens.notificationActionHeight
                    capsule: true
                    text: modelData.text
                    onClicked: root.actionTriggered(modelData.id)
                }
            }

            Button {
                id: more
                visible: !root.moreOpen && root.buttons.length > Tokens.notificationMaxActions
                onVisibleChanged: root.controlsChanged()
                width: actions.equalWidth
                height: Tokens.notificationActionHeight
                capsule: true
                text: qsTr("More")
                onClicked: root.moreOpen = true
            }
        }
    }
}
