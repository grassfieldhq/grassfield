pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Grassfield Screenshot: the editor window (ADR-0066 D-3; docs/specs/capture-suite.md §3.3). Slice B1 shows the picture with the
// unified toolbar, zoom and fit; slice B2 adds Done and Revert. The annotation tools come with the next slices; their groups
// go in the toolbar's `leading` and `trailing` rows and over `view.holder`.
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
    readonly property real toolbarRest: leadingGroup.width + (revertGroup.visible ? revertGroup.width : 0) + doneButton.width + 4 * Tokens.spacingMd
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
    // Esc closes. With tools there will be changes to keep or discard (slice B3 asks); until then nothing makes the document dirty.
    Shortcut {
        sequence: "Esc"
        enabled: !editorWin.backend.dirty
        onActivated: editorWin.close()
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

        ToolbarGroup {
            id: leadingGroup
            objectName: "zoomGroup"
            x: toolbar.contentStart
            anchors.verticalCenter: parent.verticalCenter

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

        // The file name and the zoom, in the toolbar's own title place (as Preview's two-line title block).
        Column {
            id: titleBlock
            anchors {
                left: leadingGroup.right
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
    }

    // The toolbar's rule appears once the picture scrolls under it (ADR-0039 D3).
    Rectangle {
        anchors.top: toolbar.bottom
        width: parent.width
        height: 1
        visible: view.scrolled
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
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
