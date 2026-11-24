pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The layers over the picture and the pointer of the tools (slices B3 to B8: the crop's rectangle and the text being typed are here). It is a child of the view's picture holder, which is
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
    // The crop rectangle in this item's points (empty without the Crop tool).
    readonly property rect crop: Qt.rect(root.backend.cropRect.x * root.viewScale, root.backend.cropRect.y * root.viewScale,
                                         root.backend.cropRect.width * root.viewScale, root.backend.cropRect.height * root.viewScale)
    readonly property bool cropping: root.backend.tool === "crop" && root.backend.cropRect.width > 0

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
    // By count, so that a drag (the handles move, their number does not) keeps the same items and only their places change.
    Repeater {
        model: root.cropping ? 0 : root.backend.handles.length

        Rectangle {
            required property int index
            readonly property var handle: root.backend.handles[index]
            width: Tokens.screenshotHandleSize
            height: Tokens.screenshotHandleSize
            x: (handle ? handle.x : 0) * root.viewScale - width / 2
            y: (handle ? handle.y : 0) * root.viewScale - height / 2
            z: 1
            radius: Tokens.radiusControl
            color: Appearance.colors.windowBackground
            border.width: Tokens.controlBorderWidth
            border.color: Appearance.colors.accent
            Accessible.ignored: true
        }
    }

    // The Crop tool: the part the crop leaves out is dimmed, the rectangle has a border, eight handles and its size.
    Item {
        id: cropOverlay
        objectName: "cropOverlay"
        anchors.fill: parent
        visible: root.cropping
        z: 2

        readonly property color scrim: Appearance.withAlpha(Appearance.colors.shadow, Tokens.screenshotCropScrimOpacity)

        Rectangle { color: cropOverlay.scrim; x: 0; y: 0; width: parent.width; height: root.crop.y }
        Rectangle { color: cropOverlay.scrim; x: 0; y: root.crop.y + root.crop.height; width: parent.width; height: Math.max(0, parent.height - y) }
        Rectangle { color: cropOverlay.scrim; x: 0; y: root.crop.y; width: root.crop.x; height: root.crop.height }
        Rectangle { color: cropOverlay.scrim; x: root.crop.x + root.crop.width; y: root.crop.y; width: Math.max(0, parent.width - x); height: root.crop.height }

        Rectangle {
            x: root.crop.x
            y: root.crop.y
            width: root.crop.width
            height: root.crop.height
            color: "transparent"
            border.width: Tokens.screenshotCropBorderWidth
            border.color: Appearance.colors.accent
            Accessible.role: Accessible.Graphic
            Accessible.name: qsTr("Crop rectangle, %1 by %2 pixels").arg(Math.round(root.backend.cropRect.width)).arg(Math.round(root.backend.cropRect.height))
        }

        Repeater {
            // The eight handles: corners and middles of the sides.
            model: [[0, 0], [0.5, 0], [1, 0], [1, 0.5], [1, 1], [0.5, 1], [0, 1], [0, 0.5]]

            Rectangle {
                required property var modelData
                width: Tokens.screenshotHandleSize
                height: Tokens.screenshotHandleSize
                x: root.crop.x + root.crop.width * modelData[0] - width / 2
                y: root.crop.y + root.crop.height * modelData[1] - height / 2
                radius: Tokens.radiusControl
                color: Appearance.colors.windowBackground
                border.width: Tokens.controlBorderWidth
                border.color: Appearance.colors.accent
                Accessible.ignored: true
            }
        }

        // The size in pixels, over the rectangle's top left corner (inside the picture when the rectangle is at its edge).
        Rectangle {
            x: Math.min(Math.max(root.crop.x, 0), Math.max(0, cropOverlay.width - width))
            y: root.crop.y >= height + Tokens.spacingXs ? root.crop.y - height - Tokens.spacingXs : root.crop.y + Tokens.spacingXs
            width: sizeText.implicitWidth + 2 * Tokens.spacingSm
            height: sizeText.implicitHeight + Tokens.spacingXs
            radius: Tokens.radiusControl
            color: Appearance.colors.windowBackground
            Accessible.ignored: true

            Text {
                id: sizeText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: qsTr("%1 × %2").arg(Math.round(root.backend.cropRect.width)).arg(Math.round(root.backend.cropRect.height))
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }
        }
    }

    // The Text tool's editor: typed on the picture where the text goes. The text is shown as the layer it will be (the backend previews it
    // through the file's own geometry: size, outline, pill), so the editor's own letters are not drawn, only its caret and selection.
    // Return puts the text in, Shift+Return starts a new line, Esc gives it up, and leaving it (a click elsewhere) puts it in.
    Rectangle {
        id: textEditor
        objectName: "textEditor"
        visible: root.backend.textEditing
        z: 3
        x: root.backend.textEditPos.x * root.viewScale - Tokens.spacingXs
        y: root.backend.textEditPos.y * root.viewScale - Tokens.spacingXs
        width: Math.max(Tokens.screenshotTextEditorMinWidth, edit.contentWidth + 2 * Tokens.spacingXs + edit.cursorRectangle.width)
        height: edit.contentHeight + 2 * Tokens.spacingXs
        radius: Tokens.radiusControl
        color: "transparent"
        border.width: Tokens.controlBorderWidth
        border.color: Appearance.colors.accent

        function commit(): void {
            root.backend.commitText(edit.text);
        }
        onVisibleChanged: {
            if (textEditor.visible) {
                edit.text = root.backend.textEditText;
                edit.forceActiveFocus();
                edit.cursorPosition = edit.length;
            } else {
                // Gone: the keys are the window's again (the tool letters, Delete, the arrows).
                edit.focus = false;
            }
        }

        TextEdit {
            id: edit
            objectName: "textEditInput"
            x: Tokens.spacingXs
            y: Tokens.spacingXs
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.NoWrap
            color: "transparent"
            selectionColor: Appearance.withAlpha(Appearance.colors.selection, Tokens.screenshotTextSelectionOpacity)
            selectedTextColor: "transparent"
            cursorDelegate: Rectangle {
                width: Tokens.controlBorderWidth
                color: Appearance.colors.accent
            }
            font.family: Appearance.fontFamily
            font.weight: Font.Medium
            font.pixelSize: Math.max(1, root.backend.textSize * root.viewScale)
            Accessible.role: Accessible.EditableText
            Accessible.name: qsTr("Text")
            // No more than a text holds; the rest is not typed (nor pasted).
            onTextChanged: {
                if (edit.length > root.backend.textMaxLength)
                    edit.remove(root.backend.textMaxLength, edit.length);
                if (textEditor.visible)
                    root.backend.previewText(edit.text);
            }
            Keys.onPressed: event => {
                if (!textEditor.visible)
                    return;
                if (event.key === Qt.Key_Escape) {
                    root.backend.cancelText();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (event.modifiers & Qt.ShiftModifier)
                        edit.insert(edit.cursorPosition, "\n");
                    else
                        textEditor.commit();
                    event.accepted = true;
                }
            }
            onActiveFocusChanged: {
                if (!edit.activeFocus && textEditor.visible)
                    textEditor.commit();
            }
        }
    }

    MouseArea {
        id: pointer
        objectName: "annotationPointer"
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        cursorShape: root.backend.tool === "text" ? Qt.IBeamCursor : (root.drawing ? Qt.CrossCursor : Qt.ArrowCursor)
        // Every left press is the tools' (the backend decides whether it starts a gesture), so the view does not also scroll by
        // dragging; its wheel and scroll bars still do.
        preventStealing: true

        function shifted(mouse: var): bool {
            return (mouse.modifiers & Qt.ShiftModifier) !== 0;
        }
        onPressed: mouse => {
            // A press elsewhere puts in the text being typed first.
            if (textEditor.visible)
                textEditor.commit();
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
