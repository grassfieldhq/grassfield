pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The layers over the picture and the pointer of the tools (slices B3 and B4). It is a child of the view's picture holder, so its
// coordinates are the picture's scaled by `viewScale`. What is drawn is the backend's overlay: the same QPainter drawing as the
// export, rendered at the size on screen, so that what is seen is what Done writes. The selection's handles are drawn here (they
// are not part of the picture). All the editing logic is in the backend (src/toolcontroller.cpp); this item only converts.
Item {
    id: root

    required property var backend
    // Screen points per picture pixel (ZoomView.viewScale).
    required property real viewScale

    readonly property bool drawing: root.backend.tool !== "select"

    anchors.fill: parent

    Image {
        id: overlay
        anchors.fill: parent
        source: root.backend.overlaySource
        // The overlay is rendered at the pixels this item covers (the backend's provider takes the requested size).
        sourceSize: Qt.size(Math.ceil(root.width * Screen.devicePixelRatio), Math.ceil(root.height * Screen.devicePixelRatio))
        asynchronous: false
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
            radius: Tokens.radiusControl
            color: Appearance.colors.windowBackground
            border.width: Tokens.controlBorderWidth
            border.color: Appearance.colors.accent
            Accessible.ignored: true
        }
    }

    MouseArea {
        id: pointer
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        cursorShape: root.drawing ? Qt.CrossCursor : Qt.ArrowCursor
        // A press the backend did not start (select on nothing) lets the pointer go on to the view, which scrolls.
        preventStealing: true

        function shifted(mouse: var): bool {
            return (mouse.modifiers & Qt.ShiftModifier) !== 0;
        }
        onPressed: mouse => {
            const s = root.viewScale;
            root.backend.toolPress(mouse.x / s, mouse.y / s, Tokens.screenshotHitTolerance / s);
        }
        onPositionChanged: mouse => root.backend.toolMove(mouse.x / root.viewScale, mouse.y / root.viewScale, pointer.shifted(mouse))
        onReleased: mouse => root.backend.toolRelease(mouse.x / root.viewScale, mouse.y / root.viewScale, pointer.shifted(mouse))
        onCanceled: root.backend.toolCancel()
    }
}
