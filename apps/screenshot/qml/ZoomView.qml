pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The picture, fit to the window or at a zoom (slice B1). The picture is `natW` x `natH` device pixels; `imageSource` is what the
// backend serves (image://screenshot/...). Zoom is a property of the view: nothing here ever writes a file. Later slices draw
// the layers and take the tools' pointer events in `pictureHolder`, which has the picture's own coordinates scaled by `viewScale`.
Item {
    id: root

    property url imageSource: ""
    property real natW: 1
    property real natH: 1
    property string pictureName: ""
    // A double click toggles Zoom to Fit and Actual Size (an editor turns it off: its tools take the pointer).
    property bool doubleTapZoom: true

    // Device pixels per logical pixel of this window's screen (1.25 on the owner's panel). The zoom is in DEVICE pixels per picture pixel:
    // 100% shows one picture pixel on one device pixel, so the base picture is never resampled; at 1.25 an 800 px picture is 640
    // logical px wide. A test sets it to prove other scales.
    // The window's own (fractional-scale) ratio, which is what its buffer uses; the screen's may be the rounded-up integer one.
    property real dpr: root.Window.window && root.Window.window.devicePixelRatio > 0 ? root.Window.window.devicePixelRatio : (Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1)
    // Logical pixels per picture pixel: what the picture holder and the layers over it are scaled by.
    readonly property real sceneScale: root.viewScale / root.dpr
    readonly property real fitScale: Math.min(1, Math.min(flick.width * root.dpr / Math.max(1, root.natW), flick.height * root.dpr / Math.max(1, root.natH)))
    property bool fitMode: true
    property real zoom: 1
    readonly property real viewScale: root.fitMode ? root.fitScale : root.zoom
    // The nearest device pixel, as a logical length (a place or a size on the device grid).
    function snap(value: real): real {
        return Math.round(value * root.dpr) / root.dpr;
    }
    readonly property string zoomLabel: Math.round(root.viewScale * 100) + "%"
    // The content has scrolled under the window's toolbar: the toolbar draws its rule (ADR-0039 D3, step 16).
    readonly property bool scrolled: flick.contentY > flick.originY
    readonly property alias holder: pictureHolder
    readonly property alias flickable: flick

    Accessible.role: Accessible.Graphic
    Accessible.name: qsTr("Picture %1, %2").arg(root.pictureName).arg(root.zoomLabel)
    // The double click of the TapHandler below (Zoom to Fit / Actual Size) as an accessible action; the View menu has both.
    Accessible.onPressAction: root.toggleActualSize()

    function toggleActualSize(): void {
        if (root.fitMode && root.fitScale < 1)
            root.actualSize();
        else
            root.fit();
    }
    function clampZoom(value: real): real {
        return Math.max(Tokens.screenshotZoomMin, Math.min(Tokens.screenshotZoomMax, value));
    }
    function setZoom(value: real): void {
        root.zoomAt(value, flick.width / 2, flick.height / 2);
    }
    // Zooms around a point of the view (the pointer, the pinch's centre; the middle for the menu and the buttons): the part of
    // the picture under it stays under it.
    function zoomAt(value: real, px: real, py: real): void {
        const current = root.viewScale;
        const fx = pictureHolder.width > 0 ? (flick.contentX + px - pictureHolder.x) / pictureHolder.width : 0.5;
        const fy = pictureHolder.height > 0 ? (flick.contentY + py - pictureHolder.y) / pictureHolder.height : 0.5;
        root.fitMode = false;
        root.zoom = root.clampZoom(value);
        if (current !== root.zoom) {
            flick.contentX = root.snap(Math.max(0, Math.min(flick.contentWidth - flick.width, pictureHolder.x + fx * pictureHolder.width - px)));
            flick.contentY = root.snap(Math.max(0, Math.min(flick.contentHeight - flick.height, pictureHolder.y + fy * pictureHolder.height - py)));
            flick.returnToBounds();
        }
    }
    function zoomIn(): void {
        root.setZoom(root.viewScale * Tokens.screenshotZoomStep);
    }
    function zoomOut(): void {
        root.setZoom(root.viewScale / Tokens.screenshotZoomStep);
    }
    function fit(): void {
        root.fitMode = true;
    }
    function actualSize(): void {
        root.setZoom(1);
    }

    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: Math.max(width, pictureHolder.width)
        contentHeight: Math.max(height, pictureHolder.height)

        // A zoomed picture shows where it is, as every scrolling view of the apps (ADR-0039 step 16).
        ScrollBar.vertical: ScrollBar {}
        ScrollBar.horizontal: ScrollBar {}

        Item {
            id: pictureHolder
            // Whole device pixels, in size and in place: at 100% every picture pixel is one device pixel.
            width: root.snap(root.natW * root.sceneScale)
            height: root.snap(root.natH * root.sceneScale)
            x: root.snap(Math.max(0, (flick.contentWidth - width) / 2))
            y: root.snap(Math.max(0, (flick.contentHeight - height) / 2))

            Image {
                anchors.fill: parent
                source: root.imageSource
                asynchronous: true
                retainWhileLoading: true
                cache: false
                // Exactly 1:1 is copied as it is; mipmaps only help when the picture is shown smaller.
                mipmap: root.viewScale < 1
                smooth: root.viewScale !== 1
                fillMode: Image.Stretch
            }
        }

        WheelHandler {
            id: wheelZoom
            acceptedModifiers: Qt.ControlModifier
            // Around the pointer, and by the wheel's own amount (a notch is 120): a touchpad sends many small events.
            onWheel: event => {
                if (event.angleDelta.y === 0)
                    return;
                const at = flick.mapFromItem(null, wheelZoom.point.scenePosition.x, wheelZoom.point.scenePosition.y);
                root.zoomAt(root.viewScale * Math.pow(Tokens.screenshotZoomStep, event.angleDelta.y / 120), at.x, at.y);
            }
        }

        // Double click toggles between Zoom to Fit and Actual Size.
        TapHandler {
            acceptedButtons: Qt.LeftButton
            enabled: root.doubleTapZoom
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
}
