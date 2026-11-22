pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Glance: a quick look at the given files in a floating window sized to the content (a normal
// toplevel with app_id org.grassfield.Preview.Glance, floated and centered by a Hyprland window
// rule). Space or Esc closes it, Left/Right move between files, "Open with Preview" starts the
// full viewer. Read only, like the viewer.
Window {
    id: win

    // Set by the launcher (src/main.cpp).
    required property var backend

    property int current: win.backend.startIndex
    readonly property int fileCount: win.backend.files.length
    // "n of N" is shown for files named on the command line (a selection); the folder of one file only has arrows.
    readonly property bool showCount: win.fileCount > 1 && !win.backend.browsing
    readonly property var view: content.view
    // The window is sized for the content of the first file, like a quick look panel: an image at its native size,
    // scaled down to fit Tokens.previewGlanceScreenFraction of its screen; PDF, text, video and audio at their token
    // sizes (capped the same way). The header comes on top of the content. Later files of a multi-file Glance are
    // fitted into that window.
    // The kind and a picture's size only (PreviewApp.inspectFirst): the content itself is inspected on the worker.
    readonly property var firstInfo: win.backend.inspectFirst()
    // The screen the size was computed for, and whether the window may still be refitted (see fitToScreen).
    property string sizedFor: ""
    property bool placing: true

    // Window size for the first file on a screen of sw x sh pixels.
    function sizeFor(sw: real, sh: real): size {
        const maxW = sw * Tokens.previewGlanceScreenFraction;
        const maxH = sh * Tokens.previewGlanceScreenFraction;
        const info = win.firstInfo;
        let c = Qt.size(Tokens.previewGlanceMediaWidth, Tokens.previewGlanceMediaHeight);
        if (info.ok === true) {
            switch (info.kind) {
            case "image": {
                const w = Math.max(1, info.width ?? 1);
                const h = Math.max(1, info.height ?? 1);
                const scale = Math.min(1, maxW / w, maxH / h);
                c = Qt.size(w * scale, h * scale);
                break;
            }
            case "pdf":
                c = Qt.size(Tokens.previewGlancePdfWidth, Tokens.previewGlancePdfHeight);
                break;
            case "text":
                c = Qt.size(Tokens.previewGlanceTextWidth, Tokens.previewGlanceTextHeight);
                break;
            case "video":
                c = Qt.size(Tokens.previewGlanceVideoWidth, Tokens.previewGlanceVideoHeight);
                break;
            }
        }
        // The content sits inside an inset on its three free sides, under the header.
        return Qt.size(Math.round(Math.max(Tokens.previewGlanceMinWidth, Math.min(maxW, c.width) + 2 * Tokens.previewGlanceContentInset)),
                       Math.round(Math.max(Tokens.previewGlanceMinHeight, Math.min(maxH, c.height) + Tokens.previewGlanceHeaderHeight + Tokens.previewGlanceContentInset)));
    }

    // A Wayland client cannot know the output the compositor will map it on: Qt starts with its primary screen and
    // reports the real one once the surface has entered it. The window is sized for the first screen and again, once,
    // for the screen it is really shown on (only while it is being placed: moving it to another output later keeps its
    // size). A floating toplevel does not get its own later buffer size from Hyprland, so the new size is requested as
    // a fixed size (minimum = maximum, which the compositor applies to floating windows, keeping the window centred)
    // and released after Tokens.motionNormal.
    function fitToScreen(): void {
        const s = win.screen;
        if (!win.placing || !s || s.width <= 0 || s.height <= 0 || s.name === win.sizedFor)
            return;
        win.placing = false;
        win.sizedFor = s.name;
        const target = win.sizeFor(s.width, s.height);
        if (target.width === win.width && target.height === win.height)
            return;
        win.unlimitedWidth = win.maximumWidth;
        win.unlimitedHeight = win.maximumHeight;
        win.minimumWidth = target.width;
        win.maximumWidth = target.width;
        win.minimumHeight = target.height;
        win.maximumHeight = target.height;
        win.width = target.width;
        win.height = target.height;
        releaseTimer.restart();
    }

    // Qt's own maximum size (no limit), read by fitToScreen before it fixes the size (it runs once).
    property int unlimitedWidth: 0
    property int unlimitedHeight: 0

    // Lets the user resize the window again once the compositor has applied the size (up to the screen size). Without a
    // screen (the output went away meanwhile) the maximum goes back to Qt's unlimited default rather than the current
    // size, which would leave the window unable to grow.
    Timer {
        id: releaseTimer
        interval: Tokens.motionNormal
        onTriggered: {
            const s = win.screen;
            const known = s !== null && s.width > 0 && s.height > 0;
            win.minimumWidth = Tokens.previewGlanceMinWidth;
            win.minimumHeight = Tokens.previewGlanceMinHeight;
            win.maximumWidth = known ? Math.max(win.width, s.width) : win.unlimitedWidth;
            win.maximumHeight = known ? Math.max(win.height, s.height) : win.unlimitedHeight;
        }
    }

    title: content.info.name ? DisplayName.text(content.info.name) : qsTr("Glance")
    // Initial size: Qt's first screen (the primary output); fitToScreen corrects it after the mapping.
    width: win.sizeFor(Screen.width, Screen.height).width
    height: win.sizeFor(Screen.width, Screen.height).height
    minimumWidth: Tokens.previewGlanceMinWidth
    minimumHeight: Tokens.previewGlanceMinHeight
    visible: true
    color: Appearance.windowFill

    onScreenChanged: win.fitToScreen()
    Component.onCompleted: {
        win.sizedFor = win.screen ? win.screen.name : "";
        placingTimer.start();
    }

    // The compositor reports the output within this time after mapping; later screen changes are moves by the user.
    Timer {
        id: placingTimer
        interval: Tokens.previewGlancePlacementMs
        onTriggered: win.placing = false
    }

    Theme {
        backend: win.backend
    }

    // Previous or next file; no wrap at the ends (the arrow keys of a file manager).
    function go(delta: int): void {
        win.current = Math.max(0, Math.min(win.fileCount - 1, win.current + delta));
    }

    Shortcut {
        sequence: "Space"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "Esc"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "Ctrl+W"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "Ctrl+O"
        onActivated: win.openInPreview()
    }
    Shortcut {
        sequence: "Left"
        enabled: win.fileCount > 1
        onActivated: win.go(-1)
    }
    Shortcut {
        sequence: "Right"
        enabled: win.fileCount > 1
        onActivated: win.go(1)
    }
    Shortcut {
        sequences: ["+", "="]
        enabled: win.view?.canZoom ?? false
        onActivated: win.view.zoomIn()
    }
    Shortcut {
        sequence: "-"
        enabled: win.view?.canZoom ?? false
        onActivated: win.view.zoomOut()
    }
    Shortcut {
        sequence: "0"
        enabled: win.view?.canZoom ?? false
        onActivated: win.view.fit()
    }

    function openInPreview(): void {
        win.backend.openInPreview(win.current);
        Qt.quit();
    }


    // The header is the panel's title bar: its empty space moves the window (owner report on 1.0.0-rc9: the Glance could not
    // be moved, since the window rule gf-glance draws no compositor titlebar on it and nothing here started a move), as
    // a macOS Quick Look panel moves by its title bar. The shared toolbar of the apps gives the drag (the compositor's
    // interactive move) behind every control; the Glance has no lights, so a double-click does nothing (a panel, not a
    // document window: no zoom, no minimize).
    UnifiedToolbar {
        id: header
        objectName: "glanceHeader"
        width: parent.width
        height: Tokens.previewGlanceHeaderHeight
        window: win
        style: "titlebar"
        showControls: false
        showTitle: false
        doubleClickAction: "none"
        accessibleName: qsTr("Glance")

        // Close: a glyph circle at the left (macOS Quick Look), the Space and Esc keys do the same.
        Item {
            id: closeButton
            x: Tokens.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            width: Tokens.previewGlanceGlyphSize
            height: Tokens.previewGlanceGlyphSize
            activeFocusOnTab: false
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Close")
            Accessible.onPressAction: Qt.quit()

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: Appearance.withAlpha(Appearance.colors.fill, closeMouse.containsMouse ? Tokens.materialFillOpacity * Tokens.materialHoverActiveFactor * 2 : Tokens.materialFillOpacity * Tokens.materialHoverActiveFactor)
            }
            Glyph {
                anchors.centerIn: parent
                kind: "close"
                size: parent.width - Tokens.spacingXs
                color: Appearance.windowSecondary
            }
            MouseArea {
                id: closeMouse
                anchors.fill: parent
                anchors.margins: -Tokens.spacingXs
                hoverEnabled: true
                onClicked: Qt.quit()
            }
        }

        Text {
            anchors {
                left: closeButton.right
                leftMargin: Tokens.spacingMd
                right: nav.left
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            elide: Text.ElideMiddle
            textFormat: Text.PlainText
            text: DisplayName.text(content.info.name)
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographyTitleWeight
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        // Previous and next file, with "n of N" for the files of a selection.
        Row {
            id: nav
            anchors {
                right: openButton.left
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            spacing: Tokens.spacingXs
            visible: win.fileCount > 1

            ToolButton {
                capsule: true
                accessibleName: qsTr("Previous")
                enabled: win.current > 0
                activeFocusOnTab: false
                onClicked: win.go(-1)

                Glyph {
                    anchors.centerIn: parent
                    kind: "chevronLeft"
                }
            }
            Text {
                id: counter
                anchors.verticalCenter: parent.verticalCenter
                visible: win.showCount
                textFormat: Text.PlainText
                text: qsTr("%1 of %2").arg(win.current + 1).arg(win.fileCount)
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
            ToolButton {
                capsule: true
                accessibleName: qsTr("Next")
                enabled: win.current < win.fileCount - 1
                activeFocusOnTab: false
                onClicked: win.go(1)

                Glyph {
                    anchors.centerIn: parent
                    kind: "chevronRight"
                }
            }
        }

        Button {
            id: openButton
            objectName: "glanceOpenButton"
            anchors {
                right: parent.right
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            height: Tokens.previewGlanceOpenButtonHeight
            capsule: true
            visible: win.fileCount > 0
            text: qsTr("Open with Preview")
            // Space closes the Glance, never presses this button.
            activeFocusOnTab: false
            onClicked: win.openInPreview()
        }
    }

    Content {
        id: content
        anchors {
            top: header.bottom
            bottom: parent.bottom
            left: parent.left
            right: parent.right
            leftMargin: Tokens.previewGlanceContentInset
            rightMargin: Tokens.previewGlanceContentInset
            bottomMargin: Tokens.previewGlanceContentInset
        }
        backend: win.backend
        fileIndex: win.current
        autoplay: true
    }
}
