pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The layers over the picture and the pointer of the tools (slices B3 and B4). It is a child of the view's picture holder, so its
// coordinates are the picture's scaled by `viewScale`. What is drawn is the backend's overlay: the same QPainter drawing as the
// export (so that what is seen is what Done writes), but only the part of the picture the view shows, at the view's own device
// pixels: the overlay's size is the viewport's, never the zoomed picture's (a 4K capture at 16 times would be gigabytes). It is
// asked again when the view scrolls, zooms or the layers change. The selection's handles are drawn here (they are not part of the
// picture). All the editing logic is in the backend (src/toolcontroller.cpp); this item only converts.
Item {
    id: root

    required property var backend
    // The view's Flickable: the viewport the overlay covers.
    required property Flickable flick
    // Screen points per picture pixel (ZoomView.viewScale).
    required property real viewScale

    readonly property bool drawing: root.backend.tool !== "select"
    readonly property real dpr: Screen.devicePixelRatio
    // The viewport in picture pixels, and in device pixels (what the overlay is rendered at).
    readonly property real regionX: (root.flick.contentX - root.parent.x) / root.viewScale
    readonly property real regionY: (root.flick.contentY - root.parent.y) / root.viewScale
    readonly property real regionW: root.flick.width / root.viewScale
    readonly property real regionH: root.flick.height / root.viewScale
    readonly property size overlayPixels: Qt.size(Math.max(1, Math.round(root.flick.width * root.dpr)), Math.max(1, Math.round(root.flick.height * root.dpr)))
    readonly property string overlayUrl: root.backend.overlaySource === "" ? "" : root.backend.overlaySource + "/" + root.regionX.toFixed(3) + "/" + root.regionY.toFixed(3) + "/" + root.regionW.toFixed(3) + "/" + root.regionH.toFixed(3) + "/" + root.overlayPixels.width + "/" + root.overlayPixels.height

    // A point of this item (screen points) as a point of the picture (picture pixels).
    function toPicture(x: real, y: real): point {
        return Qt.point(x / root.viewScale, y / root.viewScale);
    }

    anchors.fill: parent

    // The overlay covers the viewport, not the picture: a child of the Flickable itself, so that it does not scroll with the content.
    Image {
        id: overlay
        objectName: "annotationOverlay"
        parent: root.flick
        z: 1
        anchors.fill: parent
        source: root.overlayUrl
        sourceSize: root.overlayPixels
        asynchronous: true
        retainWhileLoading: true
        cache: false
        smooth: true
        fillMode: Image.Stretch
        // Not part of what a screen reader describes: the picture's own item names it.
        Accessible.ignored: true
    }

    // The selected layer's handles.
    Repeater {
        model: root.backend.handles

        Rectangle {
            required property var modelData
            width: Tokens.screenshotHandleSize
            height: Tokens.screenshotHandleSize
            x: modelData.x * root.viewScale - width / 2
            y: modelData.y * root.viewScale - height / 2
            z: 2
            radius: Tokens.radiusControl
            color: Appearance.colors.windowBackground
            border.width: Tokens.controlBorderWidth
            border.color: Appearance.colors.accent
            Accessible.ignored: true
        }
    }

    MouseArea {
        id: pointer
        objectName: "annotationPointer"
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        cursorShape: root.drawing ? Qt.CrossCursor : Qt.ArrowCursor
        // Every left press is the tools' (the backend decides whether it starts a gesture), so the view does not also scroll by
        // dragging; its wheel and scroll bars still do.
        preventStealing: true

        function shifted(mouse: var): bool {
            return (mouse.modifiers & Qt.ShiftModifier) !== 0;
        }
        onPressed: mouse => {
            const p = root.toPicture(mouse.x, mouse.y);
            root.backend.toolPress(p.x, p.y, Tokens.screenshotHitTolerance / root.viewScale);
        }
        onPositionChanged: mouse => {
            const p = root.toPicture(mouse.x, mouse.y);
            root.backend.toolMove(p.x, p.y, pointer.shifted(mouse));
        }
        onReleased: mouse => {
            const p = root.toPicture(mouse.x, mouse.y);
            root.backend.toolRelease(p.x, p.y, pointer.shifted(mouse));
        }
        onCanceled: root.backend.toolCancel()
    }
}
