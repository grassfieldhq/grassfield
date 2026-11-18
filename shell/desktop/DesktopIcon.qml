pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import QtQuick.Effects
import Grassfield.Ui
import qs.services
import "IconsLogic.js" as Logic

// One desktop icon: image (theme icon or capped thumbnail), a label wrapped to two lines, the
// selection highlight and the inline rename field. Pointer handling lives here; the grid, the
// selection and the file operations live in DesktopIcons.
Item {
    id: root

    required property string name
    required property bool isDir
    required property string filePath
    // The folder's own colour setting ("" = the global folder colour) and symbol (Customize Folder in Files).
    property string folderColor: ""
    property string folderGlyph: ""
    property bool selected: false
    // The desktop is the key surface (IconsView.isKey): a selection is the accent label only then, the unemphasized grey
    // otherwise (Files' cell.focused; UI audit 2026-11-05 U25).
    property bool key: true
    property bool renaming: false
    // Reason of the last refused rename ("" when none), shown by the field.
    property string renameError: ""
    // Paths carried by a drag started on this icon (the whole selection).
    property var dragPaths: []
    // Names carried with the internal-rearrange marker format (the selection).
    property var dragNames: []

    // The label follows the wallpaper's tone under it, as the menu bar does (ADR-0039 step 25; macOS: dark labels without a
    // halo on a bright wallpaper): black text where the wallpaper under the label is at least menubar.toneLightBelow (the
    // menu bar's dark foreground holds 4.5:1 from there, gate A2's role "desktop label, dark foreground"), else white text
    // with the soft dark halo. The range is the luminance grid's cells under the label (Backdrop, reported with the
    // wallpaper whatever the windows); an unknown wallpaper (a video, no statistics) keeps the white label.
    readonly property string screenName: Screen.name
    property rect labelRect: Qt.rect(0, 0, 0, 0)
    readonly property var labelRange: {
        const whole = Backdrop.wallpapers[root.screenName] ?? null;
        if (!whole)
            return null;
        const grid = Backdrop.grids[root.screenName] ?? null;
        return (grid ? GlassTint.gridRange(grid, root.labelRect, 0) : null) ?? whole;
    }
    // The wallpaper under the label is bright (dark ink there), whatever the selection.
    readonly property bool brightUnder: Logic.darkLabelOver(root.labelRange, Tokens.menubarToneLightBelow)
    // The neutral greys follow the same tone: the dark appearance's (white ink) on a dark wallpaper, the light one's on a bright one.
    readonly property var groundColors: brightUnder ? Appearance.lightColors : Appearance.darkColors
    // Selected on the key desktop: the accent label with its own text colour. Selected elsewhere: the label keeps its ink and
    // halo over a grey pill (macOS greys a selection whose window is not key).
    readonly property bool emphasized: root.selected && root.key
    readonly property bool darkLabel: !root.emphasized && !root.renaming && root.brightUnder

    function measureLabel(): void {
        if (!root.visible || labelBox.width <= 0)
            return;
        const p = labelBox.mapToItem(null, 0, 0);
        root.labelRect = Qt.rect(p.x, p.y, labelBox.width, labelBox.height);
    }

    onXChanged: Qt.callLater(root.measureLabel)
    onYChanged: Qt.callLater(root.measureLabel)
    onVisibleChanged: Qt.callLater(root.measureLabel)
    Component.onCompleted: Qt.callLater(root.measureLabel)

    // Pointer events for the grid.
    signal pressedIcon(int modifiers, bool right)
    // Left click released without a drag.
    signal tappedIcon(int modifiers)
    signal activated
    signal menuRequested(real x, real y)
    signal renameAccepted(string text)
    signal renameCancelled
    // The text of the rename field changed.
    signal renameEdited(string text)
    // The rename field lost the active focus (the keyboard went elsewhere): the grid commits it.
    signal renameFocusLost
    signal dragFinished

    readonly property bool launcher: Logic.isLauncher(name)
    readonly property bool thumbnail: !isDir && Logic.isImage(name)
    readonly property string iconTheme: launcher && info.icon !== "" ? info.icon : Logic.iconName(name, isDir)
    readonly property string label: launcher && info.name !== "" ? info.name : name
    readonly property real iconSize: Tokens.desktopIconSize
    readonly property alias dragActive: drag.active

    width: Tokens.desktopIconCellWidth
    height: Tokens.desktopIconCellHeight
    Accessible.role: Accessible.ListItem
    Accessible.name: DisplayName.text(root.label)
    Accessible.selected: root.selected

    // Name and Icon of a launcher file, shown as text only: nothing is executed.
    QtObject {
        id: info
        property string name: ""
        property string icon: ""
        // The launcher file was read (or could not be): its name and icon are final.
        property bool read: false
    }

    // Shown whole (macOS): invisible until the image is in and a launcher's file was read, so no label stands without
    // its icon and no launcher changes its name once drawn. Latched; Tokens.desktopIconLoadTimeout bounds the wait.
    readonly property var iconItem: iconLoader.item as Item
    readonly property bool imageDone: thumbnail ? (thumb.status === Image.Ready || thumb.status === Image.Error) : (iconItem !== null && (iconItem.status === Image.Ready || iconItem.status === Image.Error))
    readonly property bool whole: imageDone && (!launcher || info.read)
    property bool shown: false
    onWholeChanged: {
        if (whole)
            shown = true;
    }
    opacity: shown ? 1 : 0

    Timer {
        interval: Tokens.desktopIconLoadTimeout
        running: !root.shown
        onTriggered: root.shown = true
    }

    FileView {
        id: launcherFile
        path: root.launcher ? root.filePath : ""
        printErrors: false
        onLoaded: {
            const r = Logic.parseLauncher(launcherFile.text());
            info.name = r.name;
            info.icon = r.icon;
            info.read = true;
        }
        onLoadFailed: info.read = true
    }

    // Icon, with a selection backdrop behind it: a neutral grey, never the accent (Files' icon backdrop: the fill at
    // material.fillOpacity, radius.control; U25), in the wallpaper's tone.
    Rectangle {
        id: tint
        anchors.horizontalCenter: parent.horizontalCenter
        y: Tokens.spacingXs
        width: root.iconSize + 2 * Tokens.spacingXs
        height: root.iconSize + 2 * Tokens.spacingXs
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(root.groundColors.fill, Tokens.materialFillOpacity)
        visible: root.selected
    }

    Item {
        id: iconBox
        anchors.horizontalCenter: parent.horizontalCenter
        y: tint.y + Tokens.spacingXs
        width: root.iconSize
        height: root.iconSize

        // A folder follows the folder colour and shows its symbol (FolderIcon); anything else is a plain icon.
        Loader {
            id: iconLoader
            anchors.fill: parent
            visible: !(root.thumbnail && thumb.status === Image.Ready)
            sourceComponent: root.isDir && !root.launcher ? folderIcon : plainIcon
        }

        Component {
            id: plainIcon

            TintedIcon {
                size: root.iconSize
                source: ThemeIcons.appIcon(root.iconTheme, "text-x-generic")
                asynchronous: true
                // The desktop is drawn over the wallpaper, not over a window material: its icons and labels follow the
                // dark palette whatever the window appearance (like the labels).
                darkAppearance: true
                overWallpaper: true
            }
        }

        Component {
            id: folderIcon

            FolderIcon {
                size: root.iconSize
                source: ThemeIcons.appIcon(root.iconTheme, "text-x-generic")
                asynchronous: true
                folderColor: root.folderColor
                folderGlyph: root.folderGlyph
                darkAppearance: true
                overWallpaper: true
            }
        }

        Image {
            id: thumb
            anchors.fill: parent
            visible: status === Image.Ready
            source: root.thumbnail ? ThemeIcons.fileSource(root.filePath) : ""
            sourceSize.width: Tokens.desktopIconThumbnailMax
            sourceSize.height: Tokens.desktopIconThumbnailMax
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: false
            smooth: true
        }
    }

    // Label.
    Rectangle {
        id: labelBox
        anchors.horizontalCenter: parent.horizontalCenter
        y: tint.y + tint.height + Tokens.spacingXs
        // As wide as the widest line drawn (a wrapped name's pill does not span its unwrapped width).
        width: root.renaming ? root.width - Tokens.spacingXs : Math.min(root.width - Tokens.spacingXs, labelText.contentWidth + 2 * Tokens.spacingXs)
        height: (field.visible ? field.height : labelText.implicitHeight) + Tokens.spacingXs
        // The name's pill has Files' radius (radius.control / 2); the rename field keeps its own.
        radius: root.renaming ? Tokens.desktopIconSelectionRadius : Tokens.radiusControl / 2
        color: root.renaming ? Appearance.withAlpha(Appearance.colors.fieldFill, Tokens.desktopIconRenameFillOpacity)
            : root.emphasized ? Appearance.colors.selection
            : root.selected ? Appearance.withAlpha(root.groundColors.hover, root.brightUnder ? Tokens.windowUnemphasizedSelectionOpacityLight : Tokens.windowUnemphasizedSelectionOpacityDark)
            : "transparent"
        border.width: root.renaming ? Tokens.controlFocusOutline : 0
        border.color: root.renameError !== "" ? Appearance.darkColors.danger : Appearance.colors.accent
        onWidthChanged: Qt.callLater(root.measureLabel)
        onHeightChanged: Qt.callLater(root.measureLabel)
        // Second pass of the drop shadow: the shadow of the text and its own shadow, a denser soft halo (gate A2: white text
        // must stay legible on a white wallpaper). Off on the accent highlight, while renaming, and for a dark label; off on the
        // grey pill too (it would shade the pill: the text's own two passes keep its halo).
        layer.enabled: !root.selected && !root.renaming && !root.darkLabel
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Appearance.darkColors.shadow
            shadowOpacity: Tokens.desktopIconLabelShadowOpacity
            shadowBlur: Tokens.desktopIconLabelShadowBlur
            shadowVerticalOffset: Tokens.desktopIconLabelShadowOffsetY
        }

        // Pass 2 of the drop shadow (pass 1 is the layer of the text itself, pass 3 the layer of labelBox): each pass casts the
        // shadow of the previous result, so the halo gets denser without a harder edge (gate A2 on a white wallpaper).
        Item {
            id: labelFx
            anchors.fill: parent
            visible: !root.renaming
            layer.enabled: !root.emphasized && !root.darkLabel
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: Appearance.darkColors.shadow
                shadowOpacity: Tokens.desktopIconLabelShadowOpacity
                shadowBlur: Tokens.desktopIconLabelShadowBlur
                shadowVerticalOffset: Tokens.desktopIconLabelShadowOffsetY
            }

            FontMetrics {
                id: labelMetrics
                font: labelText.font
            }

            Text {
                id: labelText
                visible: !root.renaming
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Tokens.spacingXs / 2
                width: root.width - 2 * Tokens.spacingXs - Tokens.spacingXs
                horizontalAlignment: Text.AlignHCenter
                // Two lines at most, wrapped at words, a long name cut in the middle of the second line so its extension stays
                // (IconsLogic.labelLines; macOS Finder). Qt's own elide cuts wrapped text only at its end.
                wrapMode: Text.NoWrap
                maximumLineCount: Tokens.desktopIconLabelMaxLines
                text: Logic.labelLines(DisplayName.text(root.label), t => labelMetrics.advanceWidth(t) <= labelText.width, t => labelMetrics.elidedText(t, Qt.ElideMiddle, labelText.width))
                textFormat: Text.PlainText
                // White text with a soft dark drop shadow whatever the appearance (a desktop label sits on the wallpaper, not
                // on material); the selected label on the key desktop is drawn on the selection fill with its text colour (gate A2).
                color: root.emphasized ? Appearance.colors.selectionText : (root.darkLabel ? Appearance.lightColors.barText : Appearance.darkColors.text)
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.desktopIconLabelSize
                font.weight: Tokens.typographyMenuWeight
                // The core of the shadow is a one pixel outline at labelShadowOpacity, softened by the blurred copy below.
                style: root.emphasized || root.darkLabel ? Text.Normal : Text.Outline
                styleColor: Appearance.withAlpha(Appearance.darkColors.shadow, Tokens.desktopIconLabelShadowOpacity)
                layer.enabled: !root.emphasized && !root.darkLabel
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: Appearance.darkColors.shadow
                    shadowOpacity: Tokens.desktopIconLabelShadowOpacity
                    shadowBlur: Tokens.desktopIconLabelShadowBlur
                    shadowVerticalOffset: Tokens.desktopIconLabelShadowOffsetY
                }
            }
        }

        TextInput {
            id: field
            TextCursor {}
            visible: root.renaming
            // Disabled outside a rename: a hidden field can never hold focus or commit.
            enabled: root.renaming
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Tokens.spacingXs / 2
            width: root.width - 3 * Tokens.spacingXs
            horizontalAlignment: TextInput.AlignHCenter
            wrapMode: TextInput.WrapAnywhere
            selectByMouse: true
            color: Appearance.colors.fieldText
            selectionColor: Appearance.highlight
            selectedTextColor: Appearance.highlightText
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.desktopIconLabelSize
            font.weight: Tokens.typographyMenuWeight
            Accessible.name: qsTr("Rename %1").arg(DisplayName.text(root.label))
            onAccepted: if (root.renaming && visible)
                root.renameAccepted(text)
            onTextChanged: if (root.renaming)
                root.renameEdited(text)
            // Return commits here and is consumed, so it cannot reach the grid's own Return handling.
            Keys.onReturnPressed: event => {
                event.accepted = true;
                if (root.renaming && visible)
                    root.renameAccepted(text);
            }
            Keys.onEnterPressed: event => {
                event.accepted = true;
                if (root.renaming && visible)
                    root.renameAccepted(text);
            }
            Keys.onEscapePressed: if (root.renaming)
                root.renameCancelled()
        }
    }

    // Inline reason under the field when a rename was refused (validation or the file system).
    Text {
        visible: root.renaming && root.renameError !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: labelBox.bottom
        anchors.topMargin: Tokens.spacingXs / 2
        width: root.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        color: Appearance.darkColors.danger
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.desktopIconLabelSize
        style: Text.Outline
        styleColor: Appearance.withAlpha(Appearance.darkColors.shadow, Tokens.desktopIconLabelShadowOpacity)
        text: {
            switch (root.renameError) {
            case "empty":
                return qsTr("Name is empty");
            case "slash":
            case "dots":
            case "control":
                return qsTr("Invalid name");
            case "long":
                return qsTr("Name too long");
            case "exists":
                return qsTr("Already exists");
            default:
                return qsTr("Rename failed");
            }
        }
    }

    // Starts editing: the base name (without extension) is selected, as in a file manager.
    function beginRename(): void {
        if (!root.renaming)
            return;
        field.text = root.name;
        field.forceActiveFocus();
        const ext = Logic.splitExt(root.name).ext;
        field.select(0, ext !== "" && !root.isDir ? root.name.length - ext.length : root.name.length);
    }

    onRenamingChanged: {
        if (renaming)
            Qt.callLater(beginRename);
        else
            field.focus = false;
    }

    // Focus leaving the field: the grid commits the rename (renameFocusLost), as macOS does.
    Connections {
        target: field

        function onActiveFocusChanged(): void {
            if (root.renaming && !field.activeFocus)
                root.renameFocusLost();
        }
    }

    // ---- pointer ---------------------------------------------------------------------------------

    // A press selects at once (a drag of an unselected icon moves it alone); a double tap opens.
    TapHandler {
        acceptedButtons: Qt.LeftButton
        enabled: !root.renaming
        onPressedChanged: if (pressed)
            root.pressedIcon(point.modifiers, false)
        // Release without drag: narrows a multi-selection to this icon.
        onTapped: root.tappedIcon(point.modifiers)
        onDoubleTapped: root.activated()
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        onPressedChanged: if (pressed) {
            const p = root.mapToItem(null, point.position.x, point.position.y);
            root.pressedIcon(Qt.NoModifier, true);
            root.menuRequested(p.x, p.y);
        }
    }

    // A real drag-and-drop (wl_data_device): works inside the desktop (rearrange), onto the Dock
    // Trash tile, and into other applications. The marker format tells the desktop it is its own.
    DragHandler {
        id: drag
        target: null
        enabled: !root.renaming
        acceptedButtons: Qt.LeftButton
        dragThreshold: Tokens.desktopIconDragThreshold
        onActiveChanged: {
            if (active) {
                const p = centroid.pressPosition;
                root.dragHotspot = Qt.point(p.x, p.y);
                root.grabToImage(result => {
                    if (drag.active) {
                        root.dragImage = result.url;
                        proxy.Drag.hotSpot = root.dragHotspot;
                        // Made once, when the drag starts: as a binding every icon encoded the whole selection again at
                        // each selection change (every pointer move of a rubber band).
                        proxy.Drag.mimeData = {
                            "text/uri-list": Logic.uriList(root.dragPaths),
                            "application/x-grassfield-desktop-icons": JSON.stringify({names: root.dragNames, anchor: root.name, hx: root.dragHotspot.x, hy: root.dragHotspot.y})
                        };
                        proxy.Drag.active = true;
                    }
                });
            } else {
                proxy.Drag.active = false;
                root.dragFinished();
            }
        }
    }

    property point dragHotspot: Qt.point(0, 0)
    property url dragImage: ""

    // The Drag attached object needs an Item; it carries the mime data.
    Item {
        id: proxy
        width: root.width
        height: root.height
        visible: false
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
        Drag.proposedAction: Qt.MoveAction
        Drag.imageSource: root.dragImage
    }
}
