pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The layers over the picture and the pointer of the tools (slices B3 and B4). It is a child of the view's picture holder, which is
// a child of the Flickable's content item, so everything here scrolls and zooms with the picture and stays aligned with it by
// construction. The shapes are scene items (ShapeScene.qml), clipped to the picture as the export is; the selection's handles are
// above them and are not clipped (a handle at the edge of the picture shows whole), below the scroll bars (they are the Flickable's
// own, above its content). All the editing logic is in the backend (src/toolcontroller.cpp); this item only converts.
Item {
    id: root

    required property var backend
    // Screen points per picture pixel (ZoomView.viewScale).
    required property real viewScale

    readonly property bool drawing: root.backend.tool !== "select"

    // A point of this item (screen points) as a point of the picture (picture pixels).
    function toPicture(x: real, y: real): point {
        return Qt.point(x / root.viewScale, y / root.viewScale);
    }

    anchors.fill: parent

    ShapeScene {
        id: scene
        objectName: "shapeScene"
        anchors.fill: parent
        model: root.backend.layerModel
        viewScale: root.viewScale
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
            z: 1
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
