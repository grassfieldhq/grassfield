pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import Grassfield.Ui

// Grassfield Screenshot: the editor window (ADR-0066 D-3; docs/specs/capture-suite.md §3.3). Slice B1 shows the picture with the
// unified toolbar, zoom and fit; slice B2 adds Done and Revert; B3 the layers over the picture (select, move, resize), undo and
// redo and the question when closing with changes; B4 the arrow, line, rectangle and ellipse tools. The later tools add their
// buttons to the tool group and their options to the style group.
Window {
    id: editorWin

    // Set by the launcher (src/main.cpp).
    required property var backend
    // The registrar is there (kept up to date by src/main.cpp): the window exports its menus to the global menu bar.
    required property bool globalMenu

    // Drawn as key (ADR-0039 step 17): active, or held while a shell menu or the Control Center is open (Appearance.looksKey).
    readonly property bool keyLook: Appearance.looksKey(editorWin, editorWin.active)
    // ADR-0015: the window draws its own chrome (the unified toolbar below); the apps' tagger (apps/windowchrome.h) names its
    // role for the compositor, whose plugin then draws no titlebar on it.
    property string gfChromeRole: "editor"
    // The picture's view, for the global menu (GlobalMenu.qml).
    readonly property var zoomView: view

    // The toolbar's items, never overlapping: its inset, the lights, the groups and their margins.
    readonly property real toolbarRest: leadingRow.width + undoGroup.width + (revertGroup.visible ? revertGroup.width : 0) + doneButton.width + 6 * Tokens.spacingMd

    // Set when the changes are given up (Don't Save): the window then closes without asking.
    property bool discarding: false
    readonly property real toolbarMin: Math.max(toolbar.contentStart, Tokens.windowItemsInset) + editorWin.toolbarRest

    title: editorWin.backend.fileName !== "" ? DisplayName.text(editorWin.backend.fileName) : qsTr("Screenshot")
    width: Tokens.screenshotWindowWidth
    height: Tokens.screenshotWindowHeight
    minimumWidth: Math.max(Tokens.screenshotWindowMinWidth, Math.ceil(editorWin.toolbarMin))
    minimumHeight: Tokens.screenshotWindowMinHeight
    visible: true
    color: Appearance.windowFill

    Theme {
        backend: editorWin.backend
    }

    // Done: saves and closes; a failure keeps the window (and the edits) and says why.
    function finish(): void {
        if (editorWin.backend.done())
            editorWin.close();
    }

    // Closing with changes asks first (macOS: Save, Don't Save, Cancel); a window with none closes at once.
    onClosing: close => {
        if (editorWin.backend.dirty && !editorWin.discarding) {
            close.accepted = false;
            keepSheet.open();
        }
    }

    // New shapes are drawn as wide on the picture as on the screen the window is on: a capture at 1.25 has 1.25 times the pixels.
    Binding {
        target: editorWin.backend
        property: "toolWidth"
        value: Tokens.screenshotStrokeWidth * editorWin.screen.devicePixelRatio
    }
    // The colour of new shapes (the style group of slice B5 offers more).
    Binding {
        target: editorWin.backend
        property: "toolColor"
        value: String(Qt.color(Tokens.colorSwatch.red))
    }

    // Global menu (T1). Its shortcuts repeat the ones below: every Shortcut whose key is also a menu shortcut acts on
    // activatedAmbiguously too (Qt hands such a key to one of the two per press, see GlobalMenu.qml).
    Loader {
        active: editorWin.globalMenu
        sourceComponent: GlobalMenu {
            win: editorWin
        }
    }

    Shortcut {
        sequence: "Ctrl+W"
        onActivated: editorWin.close()
        onActivatedAmbiguously: editorWin.close()
    }
    Shortcut {
        sequence: "Ctrl+Q"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "Ctrl+S"
        onActivated: editorWin.finish()
        onActivatedAmbiguously: editorWin.finish()
    }
    Shortcut {
        sequences: ["+", "=", "Ctrl++", "Ctrl+="]
        onActivated: view.zoomIn()
        onActivatedAmbiguously: view.zoomIn()
    }
    Shortcut {
        sequences: ["-", "Ctrl+-"]
        onActivated: view.zoomOut()
        onActivatedAmbiguously: view.zoomOut()
    }
    Shortcut {
        sequences: ["0", "Ctrl+0"]
        onActivated: view.actualSize()
        onActivatedAmbiguously: view.actualSize()
    }
    Shortcut {
        sequence: "Ctrl+9"
        onActivated: view.fit()
        onActivatedAmbiguously: view.fit()
    }
    // Esc lets go of the selection, then closes (and with changes, asks: onClosing).
    Shortcut {
        sequence: "Esc"
        enabled: !keepSheet.shown
        onActivated: {
            if (editorWin.backend.selectedId !== 0)
                editorWin.backend.selectNone();
            else
                editorWin.close();
        }
    }
    Shortcut {
        sequence: "Ctrl+Z"
        enabled: !keepSheet.shown
        onActivated: editorWin.backend.undo()
        onActivatedAmbiguously: editorWin.backend.undo()
    }
    Shortcut {
        sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]
        enabled: !keepSheet.shown
        onActivated: editorWin.backend.redo()
        onActivatedAmbiguously: editorWin.backend.redo()
    }
    Shortcut {
        sequences: ["Delete", "Backspace"]
        enabled: !keepSheet.shown
        onActivated: editorWin.backend.deleteSelected()
        onActivatedAmbiguously: editorWin.backend.deleteSelected()
    }
    // The arrow keys move the selection by 1 pixel, 10 with Shift (as the pins).
    Shortcut {
        sequence: "Left"
        enabled: editorWin.backend.selectedId !== 0 && !keepSheet.shown
        onActivated: editorWin.backend.nudgeSelected(-1, 0)
    }
    Shortcut {
        sequence: "Right"
        enabled: editorWin.backend.selectedId !== 0 && !keepSheet.shown
        onActivated: editorWin.backend.nudgeSelected(1, 0)
    }
    Shortcut {
        sequence: "Up"
        enabled: editorWin.backend.selectedId !== 0 && !keepSheet.shown
        onActivated: editorWin.backend.nudgeSelected(0, -1)
    }
    Shortcut {
        sequence: "Down"
        enabled: editorWin.backend.selectedId !== 0 && !keepSheet.shown
        onActivated: editorWin.backend.nudgeSelected(0, 1)
    }
    Shortcut {
        sequence: "Shift+Left"
        enabled: editorWin.backend.selectedId !== 0 && !keepSheet.shown
        onActivated: editorWin.backend.nudgeSelected(-10, 0)
    }
    Shortcut {
        sequence: "Shift+Right"
        enabled: editorWin.backend.selectedId !== 0 && !keepSheet.shown
        onActivated: editorWin.backend.nudgeSelected(10, 0)
    }
    Shortcut {
        sequence: "Shift+Up"
        enabled: editorWin.backend.selectedId !== 0 && !keepSheet.shown
        onActivated: editorWin.backend.nudgeSelected(0, -10)
    }
    Shortcut {
        sequence: "Shift+Down"
        enabled: editorWin.backend.selectedId !== 0 && !keepSheet.shown
        onActivated: editorWin.backend.nudgeSelected(0, 10)
    }
    // Tool letters.
    Instantiator {
        model: [
            {key: "V", tool: "select"},
            {key: "A", tool: "arrow"},
            {key: "L", tool: "line"},
            {key: "R", tool: "rectangle"},
            {key: "O", tool: "ellipse"}
        ]
        delegate: Shortcut {
            required property var modelData
            sequence: modelData.key
            enabled: !keepSheet.shown
            onActivated: editorWin.backend.tool = modelData.tool
            onActivatedAmbiguously: editorWin.backend.tool = modelData.tool
        }
    }

    // ---- toolbar ---------------------------------------------------------------------------------

    // The unified toolbar of grassfield-ui (ADR-0015): the lights, the file name and the tools; the zoom group leads, Revert and the
    // primary button Done trail (macOS 27 places the default action last, on the right).
    UnifiedToolbar {
        id: toolbar
        z: 2
        width: parent.width
        height: Tokens.screenshotToolbarHeight
        window: editorWin
        title: editorWin.title
        showTitle: false
        doubleClickAction: editorWin.backend.titlebarDoubleClick
        canMinimize: editorWin.backend.canMinimize

        // Zoom, the tools and the options of the tool at hand, left to right.
        Row {
            id: leadingRow
            objectName: "leadingRow"
            x: Math.max(toolbar.contentStart, Tokens.windowItemsInset)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Tokens.spacingMd

            ToolbarGroup {
                objectName: "zoomGroup"

                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Zoom Out")
                    onClicked: view.zoomOut()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "zoomOut"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Zoom to Fit")
                    onClicked: view.fit()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "fit"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Zoom In")
                    onClicked: view.zoomIn()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "zoomIn"
                    }
                }
            }

            // The tools: one is on at a time.
            ToolbarGroup {
                id: toolGroup
                objectName: "toolGroup"

                Repeater {
                    model: [
                        {tool: "select", name: qsTr("Select"), key: "V"},
                        {tool: "arrow", name: qsTr("Arrow"), key: "A"},
                        {tool: "line", name: qsTr("Line"), key: "L"},
                        {tool: "rectangle", name: qsTr("Rectangle"), key: "R"},
                        {tool: "ellipse", name: qsTr("Ellipse"), key: "O"}
                    ]

                    ToolButton {
                        id: toolButton
                        required property var modelData
                        objectName: "tool_" + toolButton.modelData.tool
                        capsule: true
                        radio: true
                        checkable: true
                        checked: editorWin.backend.tool === toolButton.modelData.tool
                        accessibleName: toolButton.modelData.name
                        tooltip: qsTr("%1 (%2)").arg(toolButton.modelData.name).arg(toolButton.modelData.key)
                        onClicked: editorWin.backend.tool = toolButton.modelData.tool

                        Glyph {
                            anchors.centerIn: parent
                            kind: toolButton.modelData.tool
                        }
                    }
                }
            }

            // The options of the tool: the arrow's style, a shape's fill.
            ToolbarGroup {
                objectName: "arrowStyleGroup"
                visible: editorWin.backend.tool === "arrow"

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
                        checked: editorWin.backend.arrowStyle === styleButton.modelData.style
                        accessibleName: styleButton.modelData.name
                        onClicked: editorWin.backend.arrowStyle = styleButton.modelData.style

                        Glyph {
                            anchors.centerIn: parent
                            kind: "arrow" + styleButton.modelData.style.charAt(0).toUpperCase() + styleButton.modelData.style.slice(1)
                        }
                    }
                }
            }
            ToolbarGroup {
                objectName: "fillGroup"
                visible: editorWin.backend.tool === "rectangle" || editorWin.backend.tool === "ellipse"

                ToolButton {
                    objectName: "fillButton"
                    capsule: true
                    checkable: true
                    checked: editorWin.backend.toolFill
                    accessibleName: qsTr("Filled")
                    tooltip: qsTr("Fill the shape")
                    onClicked: editorWin.backend.toolFill = !editorWin.backend.toolFill

                    Glyph {
                        anchors.centerIn: parent
                        kind: "fillShape"
                    }
                }
            }
        }

        // The file name and the zoom, in the toolbar's own title place (as Preview's two-line title block).
        Column {
            id: titleBlock
            anchors {
                left: leadingRow.right
                leftMargin: Tokens.spacingMd
                right: actions.left
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            visible: width > 0

            Text {
                width: parent.width
                elide: Text.ElideMiddle
                textFormat: Text.PlainText
                text: editorWin.title
                // Dimmed while the window is not key (macOS 27; ADR-0039 step 17).
                color: editorWin.keyLook ? Appearance.colors.text : Appearance.withAlpha(Appearance.colors.text, Appearance.inactiveTextOpacity)
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Tokens.typographyTitleWeight
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: qsTr("%1 × %2 pixels, %3").arg(editorWin.backend.imageWidth).arg(editorWin.backend.imageHeight).arg(view.zoomLabel)
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }

        Row {
            id: actions
            objectName: "actionsRow"
            anchors {
                right: parent.right
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            spacing: Tokens.spacingMd

            ToolbarGroup {
                id: undoGroup
                objectName: "undoGroup"

                ToolButton {
                    objectName: "undoButton"
                    capsule: true
                    enabled: editorWin.backend.canUndo
                    accessibleName: qsTr("Undo")
                    tooltip: qsTr("Undo (Ctrl+Z)")
                    onClicked: editorWin.backend.undo()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "undo"
                    }
                }
                ToolButton {
                    objectName: "redoButton"
                    capsule: true
                    enabled: editorWin.backend.canRedo
                    accessibleName: qsTr("Redo")
                    tooltip: qsTr("Redo (Ctrl+Shift+Z)")
                    onClicked: editorWin.backend.redo()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "redo"
                    }
                }
            }

            ToolbarGroup {
                id: revertGroup
                visible: editorWin.backend.canRevert

                ToolButton {
                    objectName: "revertButton"
                    capsule: true
                    text: qsTr("Revert")
                    accessibleName: qsTr("Revert to the original")
                    tooltip: qsTr("Put the picture back as it was captured")
                    onClicked: editorWin.backend.revert()
                }
            }

            // As tall as the capsule beside it, so that the button sits on the row's middle (a Row ignores anchors).
            Item {
                width: doneButton.width
                height: Tokens.toolbarCapsule

                Button {
                    id: doneButton
                    objectName: "doneButton"
                    anchors.centerIn: parent
                    primary: true
                    push: true
                    text: qsTr("Done")
                    Accessible.name: qsTr("Done")
                    onClicked: editorWin.finish()
                }
            }
        }
    }

    // ---- the picture ------------------------------------------------------------------------------

    ZoomView {
        id: view
        objectName: "zoomView"
        anchors.fill: parent
        anchors.topMargin: toolbar.height
        imageSource: editorWin.backend.imageSource
        natW: editorWin.backend.imageWidth
        natH: editorWin.backend.imageHeight
        pictureName: editorWin.backend.fileName
        // A double click belongs to the tools now (a shape is drawn by dragging); View > Actual Size and Zoom to Fit remain.
        doubleTapZoom: false

        AnnotationLayer {
            parent: view.holder
            backend: editorWin.backend
            viewScale: view.viewScale
        }
    }

    // The toolbar's rule appears once the picture scrolls under it (ADR-0039 D3).
    Rectangle {
        anchors.top: toolbar.bottom
        width: parent.width
        height: 1
        visible: view.scrolled
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    // The question when the window closes with changes: Done keeps them, Don't Save gives them up, Cancel goes back to the picture.
    Sheet {
        id: keepSheet
        objectName: "keepSheet"
        title: qsTr("Do you want to keep the changes to “%1”?").arg(editorWin.title)
        message: qsTr("Your changes are lost if you do not keep them.")
        confirmText: qsTr("Done")
        extraButtons: [{id: "discard", text: qsTr("Don’t Save")}]
        onAccepted: editorWin.finish()
        onExtra: id => {
            if (id === "discard") {
                keepSheet.close();
                editorWin.discarding = true;
                editorWin.close();
            }
        }
    }

    // The last failure of Done or Revert: the window stays and the file keeps its old bytes whole.
    Rectangle {
        id: failure
        objectName: "failure"
        visible: editorWin.backend.lastError !== ""
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: Tokens.spacingLg
        }
        width: Math.min(parent.width - 2 * Tokens.spacingLg, failureText.implicitWidth + 2 * Tokens.spacingLg)
        height: failureText.implicitHeight + 2 * Tokens.spacingMd
        radius: Tokens.radiusControl
        color: Appearance.colors.destructive
        Accessible.role: Accessible.AlertMessage
        Accessible.name: failureText.text

        Text {
            id: failureText
            anchors.centerIn: parent
            width: parent.width - 2 * Tokens.spacingLg
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: qsTr("Could not finish: %1").arg(editorWin.backend.lastError)
            color: Appearance.colors.destructiveText
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }
    }
}
