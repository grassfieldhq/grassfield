pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TextInImages.js" as TextInImages

// Image view: fit or zoomed, rotation by quarter turns (view only, the file is never written),
// pages of multi-page TIFF through the image provider, animation (GIF, WebP) through AnimatedImage.
// Select Text in Images (ADR-0045 OC-2, docs/specs/preview.md P13): the text a still image holds can be selected and copied
// (TextLayer over the picture, Copy and Select All of the Edit menu, Ctrl+C and Ctrl+A, the context menu's Copy Text and
// Select All Text), and each QR code it holds gives a chip at the bottom right (CodeChip). Content.qml reads them
// (ImageText) and passes them here.
Item {
    id: root

    property var info: ({})
    property int fileIndex: 0
    // PreviewApp (copyText, openLink), the text read in the picture and its QR codes (set by Content.qml).
    property var backend: null
    property var textPage: TextInImages.emptyPage()
    property var codes: []

    // Common view interface (see Content.qml).
    readonly property bool canZoom: true
    readonly property bool canRotate: true
    readonly property bool canSearch: false
    readonly property string zoomLabel: Math.round(root.viewScale * 100) + "%"
    readonly property int pageCount: root.info.animated ? 1 : (root.info.frames ?? 1)
    property int currentPage: 0
    property int turns: 0
    property bool fitMode: true
    property real zoom: 1
    // An animated image under Reduce Motion waits on its first frame with a play control, as macOS does with "Auto-play
    // animated images" off: Reduce Motion is for the chrome, the content is the viewer's to play (ADR-0039 step 6; the
    // integrator's call on #74). The viewer's own play lasts until the setting changes.
    readonly property bool animated: root.info.animated ?? false
    property bool playRequested: false
    readonly property bool waiting: root.animated && Appearance.reduceMotion && !root.playRequested

    onInfoChanged: root.playRequested = false

    // Edit menu (GlobalMenu.qml) and the context menu: the selected text of the picture.
    readonly property bool canCopy: textLayer.hasSelection
    readonly property bool canSelectAll: textLayer.hasText

    function copy(): void {
        const text = textLayer.selectedText();
        if (text !== "" && root.backend)
            root.backend.copyText(text, false);
    }
    function selectAll(): void {
        textLayer.selectAll();
    }

    readonly property bool swapped: root.turns % 2 !== 0
    readonly property real natW: root.info.width ?? 1
    readonly property real natH: root.info.height ?? 1
    readonly property real dispW: root.swapped ? root.natH : root.natW
    readonly property real dispH: root.swapped ? root.natW : root.natH
    readonly property real fitScale: Math.min(1, Math.min(flick.width / root.dispW, flick.height / root.dispH))
    readonly property real viewScale: root.fitMode ? root.fitScale : root.zoom

    Accessible.role: Accessible.Graphic
    Accessible.name: qsTr("Image %1").arg(root.info.name ?? "")
    // The double click of the TapHandler below (Zoom to Fit / Actual Size) as an accessible action (A11Y-09); the View menu
    // has the same two commands.
    Accessible.onPressAction: root.toggleActualSize()

    function toggleActualSize(): void {
        if (root.fitMode && root.fitScale < 1)
            root.actualSize();
        else
            root.fit();
    }

    function setZoom(value: real): void {
        root.zoomAt(value, flick.width / 2, flick.height / 2);
    }
    // Zooms around a point of the view (the pointer, the pinch's centre; the middle for the menu and the buttons): the part
    // of the picture under it stays under it, where the picture used to grow from its top left corner.
    function zoomAt(value: real, px: real, py: real): void {
        const current = root.viewScale;
        const fx = holder.width > 0 ? (flick.contentX + px - holder.x) / holder.width : 0.5;
        const fy = holder.height > 0 ? (flick.contentY + py - holder.y) / holder.height : 0.5;
        root.fitMode = false;
        root.zoom = Math.max(Tokens.previewZoomMin, Math.min(Tokens.previewZoomMax, value));
        if (current !== root.zoom) {
            flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, holder.x + fx * holder.width - px));
            flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, holder.y + fy * holder.height - py));
            flick.returnToBounds();
        }
    }
    function zoomIn(): void {
        root.setZoom(root.viewScale * Tokens.previewZoomStep);
    }
    function zoomOut(): void {
        root.setZoom(root.viewScale / Tokens.previewZoomStep);
    }
    function fit(): void {
        root.fitMode = true;
    }
    function actualSize(): void {
        root.setZoom(1);
    }
    function rotate(direction: int): void {
        root.turns = ((root.turns + direction) % 4 + 4) % 4;
    }
    function goToPage(page: int): void {
        root.currentPage = Math.max(0, Math.min(root.pageCount - 1, page));
    }

    // The content has scrolled under the window's toolbar: the toolbar draws its rule (ADR-0039 D3, step 16).
    readonly property bool scrolled: flick.contentY > flick.originY

    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: Math.max(width, holder.width)
        contentHeight: Math.max(height, holder.height)

        // A zoomed picture shows where it is, as every scrolling view of the apps (ADR-0039 step 16).
        ScrollBar.vertical: ScrollBar {}
        ScrollBar.horizontal: ScrollBar {}

        Item {
            id: holder
            width: root.dispW * root.viewScale
            height: root.dispH * root.viewScale
            x: Math.max(0, (flick.contentWidth - width) / 2)
            y: Math.max(0, (flick.contentHeight - height) / 2)

            Image {
                anchors.centerIn: parent
                width: root.natW * root.viewScale
                height: root.natH * root.viewScale
                rotation: root.turns * 90
                visible: !(root.info.animated ?? false)
                // Keyed by the file's token, not its index: the folder listing moves the opened file to another index, and
                // the same URL keeps the picture already decoded.
                source: root.info.url && !root.info.animated && root.info.token !== undefined ? "image://preview/" + root.currentPage + "/" + root.info.token : ""
                asynchronous: true
                retainWhileLoading: true
                cache: false
                mipmap: true
                smooth: true
                fillMode: Image.Stretch
            }

            // The words of the picture, laid over it with its size, centre and rotation (its coordinates are the picture's).
            TextLayer {
                id: textLayer
                objectName: "textLayer"
                anchors.centerIn: parent
                width: root.natW * root.viewScale
                height: root.natH * root.viewScale
                rotation: root.turns * 90
                visible: !root.animated
                page: root.textPage
                onContextMenuRequested: (x, y) => {
                    const p = textLayer.mapToItem(root, x, y);
                    root.openTextMenu(p.x, p.y);
                }
            }

            AnimatedImage {
                id: animatedImage
                anchors.centerIn: parent
                width: root.natW * root.viewScale
                height: root.natH * root.viewScale
                rotation: root.turns * 90
                visible: root.info.animated ?? false
                source: root.info.url && root.info.animated ? root.info.url : ""
                playing: visible && !root.waiting
                cache: false
                smooth: true
                fillMode: Image.Stretch
            }
        }

        WheelHandler {
            id: wheelZoom
            acceptedModifiers: Qt.ControlModifier
            // Around the pointer, and by the wheel's own amount (a notch is 120): a high-resolution wheel or a touchpad
            // sends many small events, which were a full step each.
            onWheel: event => {
                if (event.angleDelta.y === 0)
                    return;
                const at = flick.mapFromItem(null, wheelZoom.point.scenePosition.x, wheelZoom.point.scenePosition.y);
                root.zoomAt(root.viewScale * Math.pow(Tokens.previewZoomStep, event.angleDelta.y / 120), at.x, at.y);
            }
        }

        // Double click toggles between Zoom to Fit and Actual Size (macOS Preview).
        TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: root.toggleActualSize()
        }

        PinchHandler {
            id: pinchZoom
            target: null
            // Around the fingers' centre.
            onScaleChanged: delta => {
                const at = flick.mapFromItem(null, pinchZoom.centroid.scenePosition.x, pinchZoom.centroid.scenePosition.y);
                root.zoomAt(root.viewScale * delta, at.x, at.y);
            }
        }
    }

    // Copy (Ctrl+C; Super+C reaches a window as Ctrl+C, Omarchy's universal copy) and Select All (Ctrl+A). The viewer's Edit
    // menu has the same keys: each acts on activatedAmbiguously too (GlobalMenu.qml); a Glance has no menu.
    Shortcut {
        sequences: [StandardKey.Copy]
        enabled: root.canCopy
        onActivated: root.copy()
        onActivatedAmbiguously: root.copy()
    }
    Shortcut {
        sequences: [StandardKey.SelectAll]
        enabled: root.canSelectAll
        onActivated: root.selectAll()
        onActivatedAmbiguously: root.selectAll()
    }

    function openTextMenu(x: real, y: real): void {
        textMenu.items = [
            {id: "copy", text: qsTr("Copy Text"), enabled: root.canCopy},
            {id: "selectAll", text: qsTr("Select All Text"), enabled: root.canSelectAll}
        ];
        textMenu.openAt(x, y);
    }

    // The picture's context menu (the app windows' one menu host, ADR-0039 step 24).
    MenuPopup {
        id: textMenu
        objectName: "textMenu"
        accessibleName: qsTr("Text in image")
        focusBack: root
        // Opened at the pointer, kept inside the window near its edges.
        margins: Tokens.spacingSm
        onChosen: id => {
            if (id === "copy")
                root.copy();
            else if (id === "selectAll")
                root.selectAll();
        }
    }

    // The QR codes of the picture: one glass chip each at the bottom right, as macOS's data detector buttons, in the order
    // zbarimg found them.
    Column {
        id: chips
        objectName: "codeChips"
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.spacingLg
        spacing: Tokens.spacingSm
        visible: !root.animated && root.codes.length > 0

        Repeater {
            model: root.codes

            CodeChip {
                required property var modelData
                required property int index
                anchors.right: parent ? parent.right : undefined
                code: modelData
                number: root.codes.length > 1 ? index + 1 : 0
                onOpenRequested: link => {
                    if (root.backend)
                        root.backend.openLink(link);
                }
                onCopyRequested: text => {
                    if (root.backend)
                        root.backend.copyText(text, true);
                }
            }
        }
    }

    // Turning Reduce Motion on puts an animated image back on its first frame; either change ends the viewer's own play.
    Connections {
        target: Appearance

        function onReduceMotionChanged(): void {
            root.playRequested = false;
            if (Appearance.reduceMotion)
                animatedImage.currentFrame = 0;
        }
    }

    // Play and pause an animated image while Reduce Motion holds it (a glass capsule as the toolbar's).
    Item {
        id: playControl
        objectName: "animatedPlayControl"
        visible: root.animated && Appearance.reduceMotion
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Tokens.spacingLg
        width: Tokens.toolbarCapsule
        height: Tokens.toolbarCapsule

        Material {
            anchors.fill: parent
            radius: height / 2
        }

        ToolButton {
            anchors.centerIn: parent
            capsule: true
            accessibleName: root.playRequested ? qsTr("Pause") : qsTr("Play")
            onClicked: root.playRequested = !root.playRequested

            Glyph {
                anchors.centerIn: parent
                kind: root.playRequested ? "pause" : "play"
            }
        }
    }
}
