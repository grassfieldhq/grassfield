pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T
import Grassfield.Ui

// The options strip under the unified toolbar (slices B4 to B8): the style of the tool at hand, or of the selected layer when the
// Select tool is at hand, as the second row of macOS 27's markup toolbar. It shows only what the thing styled has: a colour for
// every drawing tool, a stroke width for the line-like ones, an arrow's style, a shape's fill, a text's style and size, a counter's
// size, and for the Crop tool the aspect presets with rotate, flip, Cancel and Apply. Every control calls the backend, which keeps
// the style of the next layer and edits the selected one in one undo step; this item holds no state of its own.
Item {
    id: root

    required property var backend
    // Device pixels per point of the capture (the capture's own scale, else the screen's): a width or size in points times this.
    required property real unit

    // What the strip styles: the tool, or the selected layer's type for Select.
    readonly property string kind: root.backend.tool !== "select" ? root.backend.tool : root.backend.selectedType
    readonly property bool hasColor: ["arrow", "line", "rectangle", "ellipse", "pen", "highlighter", "text", "counter", "redact", "eyedropper"].indexOf(root.kind) >= 0
    readonly property bool hasWidth: ["arrow", "line", "rectangle", "ellipse", "pen", "highlighter"].indexOf(root.kind) >= 0
    readonly property bool hasArrow: root.kind === "arrow"
    readonly property bool hasFill: root.kind === "rectangle" || root.kind === "ellipse"
    readonly property bool hasText: root.kind === "text"
    readonly property bool hasCounter: root.kind === "counter"
    readonly property bool hasCrop: root.kind === "crop"
    // The region tools (slice B7) say in the strip what they guarantee: Redact is the tool for secrets, Pixelate and Blur are not (ADR-0066 D-9).
    readonly property string regionNote: root.kind === "redact" ? qsTr("Hides what is under it in the saved picture. Use it for secrets.")
        : root.kind === "pixelate" ? qsTr("Hides detail, but short text can still be guessed. Use Redact for secrets.")
        : root.kind === "blur" ? qsTr("For looks only. Does not hide text.")
        : root.kind === "spotlight" ? qsTr("Dims everything outside the box.") : ""
    readonly property bool shown: root.hasColor || root.hasCrop || root.regionNote !== ""

    visible: root.shown
    height: root.shown ? Tokens.screenshotStyleBarHeight : 0
    implicitWidth: row.implicitWidth + 2 * Tokens.spacingLg

    // The colours of the swatches: the accent swatch colours of the design tokens.
    readonly property var swatches: [
        {id: "red", name: qsTr("Red"), color: String(Qt.color(Tokens.colorSwatch.red))},
        {id: "orange", name: qsTr("Orange"), color: String(Qt.color(Tokens.colorSwatch.orange))},
        {id: "yellow", name: qsTr("Yellow"), color: String(Qt.color(Tokens.colorSwatch.yellow))},
        {id: "green", name: qsTr("Green"), color: String(Qt.color(Tokens.colorSwatch.green))},
        {id: "blue", name: qsTr("Blue"), color: String(Qt.color(Tokens.colorSwatch.blue))},
        {id: "purple", name: qsTr("Purple"), color: String(Qt.color(Tokens.colorSwatch.purple))},
        {id: "graphite", name: qsTr("Graphite"), color: String(Qt.color(Tokens.colorSwatch.graphite))}
    ]

    // The choice among three sizes that is nearest to `value` (device pixels), as an id of `ids`.
    function nearest(value: real, points: var, ids: var): string {
        let best = ids[0];
        let distance = Infinity;
        for (let i = 0; i < points.length; i++) {
            const d = Math.abs(value - points[i] * root.unit);
            if (d < distance) {
                distance = d;
                best = ids[i];
            }
        }
        return best;
    }

    readonly property var widthPoints: [Tokens.screenshotStrokeWidthThin, Tokens.screenshotStrokeWidth, Tokens.screenshotStrokeWidthThick]
    readonly property var textPoints: [Tokens.screenshotTextSizeSmall, Tokens.screenshotTextSize, Tokens.screenshotTextSizeLarge]
    readonly property var counterPoints: [Tokens.screenshotCounterSize * Tokens.screenshotCounterSizeScaleSmall, Tokens.screenshotCounterSize,
        Tokens.screenshotCounterSize * Tokens.screenshotCounterSizeScaleLarge]
    readonly property var sizeIds: ["small", "medium", "large"]

    Row {
        id: row
        anchors {
            left: parent.left
            leftMargin: Tokens.spacingLg
            verticalCenter: parent.verticalCenter
        }
        spacing: Tokens.spacingLg

        // ---- colour ----
        Row {
            objectName: "colorSwatches"
            visible: root.hasColor
            anchors.verticalCenter: parent.verticalCenter
            spacing: Tokens.spacingSm

            Repeater {
                model: root.swatches

                T.AbstractButton {
                    id: swatch
                    required property var modelData
                    objectName: "swatch_" + swatch.modelData.id
                    readonly property bool current: root.backend.toolColor.toLowerCase() === swatch.modelData.color.toLowerCase()
                    implicitWidth: Tokens.screenshotSwatchSize + 2 * Tokens.controlFocusOutline
                    implicitHeight: implicitWidth
                    checkable: false
                    hoverEnabled: true
                    focusPolicy: Qt.TabFocus
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: swatch.modelData.name
                    Accessible.checkable: true
                    Accessible.checked: swatch.current
                    Accessible.onPressAction: swatch.click()
                    onClicked: root.backend.applyColor(swatch.modelData.color)

                    background: Item {
                        Rectangle {
                            anchors.centerIn: parent
                            width: Tokens.screenshotSwatchSize
                            height: width
                            radius: width / 2
                            color: swatch.modelData.color
                            border.width: Tokens.appsBorderWidth
                            border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                        }
                        // The chosen colour is ringed outside its disc, as Settings' accent swatches.
                        Rectangle {
                            anchors.centerIn: parent
                            width: Tokens.screenshotSwatchSize + 2 * Tokens.controlFocusOutline
                            height: width
                            radius: width / 2
                            color: "transparent"
                            border.width: Tokens.menuSwatchRing
                            border.color: Appearance.colors.text
                            visible: swatch.current || swatch.hovered
                            opacity: swatch.current ? 1 : Tokens.controlFocusOutlineOpacity
                        }
                        FocusRing {
                            visible: swatch.visualFocus
                            shapeRadius: width / 2
                        }
                    }
                }
            }

            // The colour as it stands (the eyedropper's pick is none of the swatches): a disc beside the swatches.
            Rectangle {
                objectName: "colorWell"
                anchors.verticalCenter: parent.verticalCenter
                width: Tokens.screenshotSwatchSize
                height: width
                radius: width / 2
                color: root.backend.toolColor
                border.width: Tokens.appsBorderWidth
                border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("Current colour %1").arg(root.backend.toolColor)
            }

            ToolButton {
                objectName: "tool_eyedropper"
                anchors.verticalCenter: parent.verticalCenter
                capsule: true
                radio: true
                checkable: true
                checked: root.backend.tool === "eyedropper"
                accessibleName: qsTr("Eyedropper")
                tooltip: qsTr("%1 (%2)").arg(qsTr("Eyedropper")).arg("I")
                onClicked: root.backend.tool = "eyedropper"

                Glyph {
                    anchors.centerIn: parent
                    kind: "eyedropper"
                }
            }
        }

        // ---- stroke width ----
        SegmentedControl {
            objectName: "widthChoice"
            visible: root.hasWidth
            anchors.verticalCenter: parent.verticalCenter
            accessibleName: qsTr("Stroke Width")
            model: [
                {id: "small", text: qsTr("Thin")},
                {id: "medium", text: qsTr("Medium")},
                {id: "large", text: qsTr("Thick")}
            ]
            value: root.nearest(root.backend.toolWidth, root.widthPoints, root.sizeIds)
            onPicked: id => root.backend.applyWidth(root.widthPoints[root.sizeIds.indexOf(id)] * root.unit)
        }

        // ---- the options of the arrow and of a shape ----
        ToolbarGroup {
            objectName: "arrowStyleGroup"
            visible: root.hasArrow
            anchors.verticalCenter: parent.verticalCenter

            Repeater {
                model: [
                    {style: "straight", name: qsTr("Straight Arrow")},
                    {style: "curved", name: qsTr("Curved Arrow")},
                    {style: "double", name: qsTr("Double Arrow")}
                ]

                ToolButton {
                    id: styleButton
                    required property var modelData
                    objectName: "arrow_" + styleButton.modelData.style
                    capsule: true
                    radio: true
                    checkable: true
                    checked: root.backend.arrowStyle === styleButton.modelData.style
                    accessibleName: styleButton.modelData.name
                    onClicked: root.backend.arrowStyle = styleButton.modelData.style

                    Glyph {
                        anchors.centerIn: parent
                        kind: "arrow" + styleButton.modelData.style.charAt(0).toUpperCase() + styleButton.modelData.style.slice(1)
                    }
                }
            }
        }
        ToolbarGroup {
            objectName: "fillGroup"
            visible: root.hasFill
            anchors.verticalCenter: parent.verticalCenter

            ToolButton {
                objectName: "fillButton"
                capsule: true
                checkable: true
                checked: root.backend.toolFill
                accessibleName: qsTr("Filled")
                tooltip: qsTr("Fill the shape")
                onClicked: root.backend.applyFill(!root.backend.toolFill)

                Glyph {
                    anchors.centerIn: parent
                    kind: "fillShape"
                }
            }
        }

        // ---- text ----
        SegmentedControl {
            objectName: "textStyleChoice"
            visible: root.hasText
            anchors.verticalCenter: parent.verticalCenter
            accessibleName: qsTr("Text Style")
            model: [
                {id: "plain", text: qsTr("Plain")},
                {id: "outlined", text: qsTr("Outlined")},
                {id: "pill", text: qsTr("Pill")}
            ]
            value: root.backend.textStyle
            onPicked: id => root.backend.applyTextStyle(id)
        }
        SegmentedControl {
            objectName: "textSizeChoice"
            visible: root.hasText
            anchors.verticalCenter: parent.verticalCenter
            accessibleName: qsTr("Text Size")
            model: [
                {id: "small", text: qsTr("Small")},
                {id: "medium", text: qsTr("Medium")},
                {id: "large", text: qsTr("Large")}
            ]
            value: root.nearest(root.backend.textSize, root.textPoints, root.sizeIds)
            onPicked: id => root.backend.applyTextSize(root.textPoints[root.sizeIds.indexOf(id)] * root.unit)
        }

        // ---- counters ----
        SegmentedControl {
            objectName: "counterSizeChoice"
            visible: root.hasCounter
            anchors.verticalCenter: parent.verticalCenter
            accessibleName: qsTr("Counter Size")
            model: [
                {id: "small", text: qsTr("Small")},
                {id: "medium", text: qsTr("Medium")},
                {id: "large", text: qsTr("Large")}
            ]
            value: root.nearest(root.backend.counterSize, root.counterPoints, root.sizeIds)
            onPicked: id => root.backend.applyCounterSize(root.counterPoints[root.sizeIds.indexOf(id)] * root.unit)
        }

        // ---- crop, rotate, flip ----
        ComboBox {
            objectName: "cropAspect"
            visible: root.hasCrop
            anchors.verticalCenter: parent.verticalCenter
            accessibleName: qsTr("Aspect Ratio")
            minimumWidth: 0
            model: [
                {id: "free", text: qsTr("Free")},
                {id: "original", text: qsTr("Original")},
                {id: "1:1", text: "1:1"},
                {id: "4:3", text: "4:3"},
                {id: "3:2", text: "3:2"},
                {id: "16:9", text: "16:9"},
                {id: "9:16", text: "9:16"}
            ]
            value: root.backend.cropAspect
            onPicked: id => root.backend.setCropAspect(id)
        }
        ToolbarGroup {
            objectName: "turnGroup"
            visible: root.hasCrop
            anchors.verticalCenter: parent.verticalCenter

            Repeater {
                model: [
                    {kind: "rotateLeft", name: qsTr("Rotate Left"), key: "Ctrl+L"},
                    {kind: "rotateRight", name: qsTr("Rotate Right"), key: "Ctrl+R"},
                    {kind: "flipHorizontal", name: qsTr("Flip Horizontal"), key: ""},
                    {kind: "flipVertical", name: qsTr("Flip Vertical"), key: ""}
                ]

                ToolButton {
                    id: turnButton
                    required property var modelData
                    objectName: "turn_" + turnButton.modelData.kind
                    capsule: true
                    accessibleName: turnButton.modelData.name
                    tooltip: turnButton.modelData.key === "" ? turnButton.modelData.name : qsTr("%1 (%2)").arg(turnButton.modelData.name).arg(MenuShortcut.label(turnButton.modelData.key, Appearance.shortcutStyle))
                    // The backend's four invokables are named as the glyphs are.
                    onClicked: root.backend[turnButton.modelData.kind]()

                    Glyph {
                        anchors.centerIn: parent
                        kind: turnButton.modelData.kind
                    }
                }
            }
        }
        Button {
            objectName: "cropCancel"
            visible: root.hasCrop
            anchors.verticalCenter: parent.verticalCenter
            push: true
            enabled: root.backend.cropChanges
            text: qsTr("Cancel")
            Accessible.name: qsTr("Cancel Crop")
            onClicked: root.backend.cancelCrop()
        }
        Button {
            objectName: "cropApply"
            visible: root.hasCrop
            anchors.verticalCenter: parent.verticalCenter
            primary: true
            push: true
            enabled: root.backend.cropChanges
            text: qsTr("Crop")
            Accessible.name: qsTr("Apply Crop")
            onClicked: root.backend.applyCrop()
        }
    }

    // What the region tool does and does not hide: after the controls, cut at the window's edge (the tool's tooltip says it whole).
    Text {
        objectName: "regionNote"
        visible: root.regionNote !== ""
        anchors {
            left: row.right
            leftMargin: Tokens.spacingLg
            right: parent.right
            rightMargin: Tokens.spacingLg
            verticalCenter: parent.verticalCenter
        }
        text: root.regionNote
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        Accessible.role: Accessible.StaticText
        Accessible.name: root.regionNote
    }
}
