pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "IconSource.js" as IconSource
import "Nav.js" as Nav

// Gallery view: a large preview of the current item (its KIO thumbnail at the gallery size, the icon-size thumbnail
// or the type icon until then) above a horizontal strip of thumbnails, and the preview pane on the right (PreviewPane).
// Left/Right move along the strip, Space opens Glance, Return renames, Cmd+O opens. In the strip a click selects (Shift extends, Ctrl
// toggles), a double click opens, items drag out as text/uri-list and folders accept drops.
FocusScope {
    id: root
    // A rule or frame: one point (apps.borderWidth, ADR-0039 D5) in whole device pixels, 1 px at 1.25 where 1 pt drew a soft
    // 1.25 px (UI audit 2026-11-05 U37); 1 px at 1x and 2 px at 2x as before.
    readonly property real hairline: Math.max(1, Math.round(Tokens.appsBorderWidth * Screen.devicePixelRatio)) / Math.max(1, Screen.devicePixelRatio)

    required property var tab
    required property var model

    readonly property bool showInfo: root.tab.app.galleryInfo
    readonly property int pageItems: Math.max(1, Math.floor(strip.width / Tokens.filesGalleryStripCellWidth))
    // Bumped by every change of the listing (dates, names, tags) so the info panel reads the current item again.
    property int revision: 0
    readonly property var info: {
        void root.revision;
        const m = root.model;
        return m && m.currentRow >= 0 ? m.info(m.currentRow) : null;
    }

    Accessible.role: Accessible.List
    Accessible.name: qsTr("Gallery")

    function applyPrefs(): void {
    }

    function focusView(): void {
        strip.forceActiveFocus();
    }

    // Window coordinates of a row's thumbnail (keyboard context menu).
    function rowPosition(model: var, row: int): point {
        if (row < 0)
            return root.mapToItem(null, Tokens.spacingLg, Tokens.spacingLg);
        return strip.mapToItem(null, (row + 0.5) * Tokens.filesGalleryStripCellWidth - strip.contentX + strip.originX, strip.height / 2);
    }

    // The gallery always shows an item: the first one once the folder is listed, when none is current.
    function ensureCurrent(): void {
        const m = root.model;
        if (!m || m.currentRow >= 0)
            return;
        const row = Nav.galleryInitialRow(m.currentRow, m.count);
        if (row >= 0)
            m.select(row, 0);
    }

    Component.onCompleted: Qt.callLater(root.ensureCurrent)

    Connections {
        target: root.model
        ignoreUnknownSignals: true
        function onCountChanged(): void {
            root.ensureCurrent();
        }
        function onRevealRequested(row: int, rename: bool): void {
            strip.positionViewAtIndex(row, ListView.Contain);
            if (rename)
                root.tab.startRename(root.model, row);
        }
        function onDataChanged(): void {
            root.revision++;
        }
    }

    // Drag source shared by the strip's cells (the system drag starts when Drag.active turns true).
    Item {
        id: dragProxy
        width: Tokens.filesGalleryStripIconSize
        height: Tokens.filesGalleryStripIconSize
        visible: false
        Drag.dragType: Drag.Automatic
        // No link: Wayland drag and drop has none (a drop proposing it is refused); Files makes an alias itself
        // for Option-Cmd (FilesApp.drop).
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
        Drag.proposedAction: Qt.MoveAction
        Drag.hotSpot.x: Tokens.filesGalleryStripIconSize / 2
        Drag.hotSpot.y: Tokens.filesGalleryStripIconSize / 2
        Drag.onDragFinished: dropAction => {
            dragProxy.Drag.active = false;
            root.tab.dragFinished(dropAction);
        }
    }

    // Background: drops into this folder and the folder's context menu.
    DropArea {
        anchors.fill: parent
        keys: ["text/uri-list"]
        // Recents is a list, not a place (Finder): the drag is refused there and shows it.
        onEntered: event => event.accepted = !root.tab.app.isRecents(root.model.url)
        onDropped: drop => {
            if (drop.hasUrls) {
                root.tab.dropUrls(drop.urls, root.model.url, root.model);
                drop.accept(Qt.CopyAction);
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: mouse => {
            strip.forceActiveFocus();
            if (mouse.button === Qt.RightButton) {
                const p = mapToItem(null, mouse.x, mouse.y);
                root.tab.contextMenu(root.model, -1, p.x, p.y, false);
            }
        }
    }

    // Large preview ------------------------------------------------------------------------------
    // One page per item, the current one in view: each page asks for its large thumbnail when it is created and drops
    // the request when it goes away, so the neighbours kept by cacheBuffer are ready before the arrows reach them.
    ListView {
        id: pager
        width: parent.width - (root.showInfo ? Tokens.filesPreviewPaneWidth : 0)
        height: parent.height - Tokens.filesGalleryStripHeight
        orientation: ListView.Horizontal
        model: root.model
        clip: true
        interactive: false
        keyNavigationEnabled: false
        activeFocusOnTab: false
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: 0
        preferredHighlightEnd: pager.width
        // The preview changes in place, as on macOS (no slide).
        highlightMoveDuration: 0
        currentIndex: root.model ? root.model.currentRow : -1
        cacheBuffer: Math.max(0, pager.width)
        Accessible.ignored: true

        delegate: Item {
            id: page

            required property int index
            required property string name
            required property url url
            required property string iconName
            required property string thumbnail
            required property string largeThumbnail
            required property string emblem
            required property bool canPreview
            required property bool isDir
            required property string folderColor
            required property string folderGlyph

            readonly property bool renaming: root.tab.isRenaming(root.model, page.url)
            readonly property real boxWidth: Math.max(0, page.width - 2 * Tokens.filesGalleryPreviewMargin)
            readonly property real boxHeight: Math.max(0, page.height - 2 * Tokens.filesGalleryPreviewMargin - caption.height - Tokens.spacingSm)

            width: pager.width
            height: pager.height
            Accessible.role: Accessible.Graphic
            Accessible.name: DisplayName.text(page.name)

            Component.onCompleted: if (page.canPreview) root.model.requestPreview(page.index, true)
            onCanPreviewChanged: if (page.canPreview) root.model.requestPreview(page.index, true)
            Component.onDestruction: if (root.model) root.model.cancelPreview(page.url, true)

            Item {
                id: box
                x: Tokens.filesGalleryPreviewMargin
                y: Tokens.filesGalleryPreviewMargin
                width: page.boxWidth
                height: page.boxHeight

                // The gallery-size thumbnail, never enlarged beyond its own pixels.
                Image {
                    id: large
                    anchors.centerIn: parent
                    width: Math.min(box.width, implicitWidth)
                    height: Math.min(box.height, implicitHeight)
                    source: page.largeThumbnail
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                    mipmap: true
                    visible: status === Image.Ready
                }

                // Until then the icon-size thumbnail, then the type icon.
                FileIcon {
                    anchors.centerIn: parent
                    visible: large.status !== Image.Ready
                    size: Math.max(Tokens.filesIconSize, Math.min(Tokens.filesGalleryIconSize, box.width, box.height))
                    iconName: page.iconName
                    isDir: page.isDir
                    folderColor: page.folderColor
                    folderGlyph: page.folderGlyph
                    thumbnail: page.thumbnail
                    emblem: page.emblem
                }
            }

            Item {
                id: caption
                anchors.horizontalCenter: parent.horizontalCenter
                y: box.y + box.height + Tokens.spacingSm
                width: page.boxWidth
                height: Math.max(captionText.implicitHeight, Tokens.filesListRowHeight)

                Text {
                    id: captionText
                    textFormat: Text.PlainText
                    visible: !page.renaming
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: DisplayName.text(page.name)
                    elide: Text.ElideMiddle
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                    font.weight: Tokens.typographyMenuBoldWeight
                }

                Loader {
                    active: page.renaming
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(parent.width, Tokens.filesColumnWidth)
                    height: parent.height
                    sourceComponent: RenameField {
                        originalName: page.name
                        baseLength: root.tab.app.baseNameLength(page.name, page.isDir)
                        horizontalAlignment: TextInput.AlignHCenter
                        onCommitted: name => root.tab.commitRename(name)
                        onCanceled: root.tab.cancelRename()
                    }
                }
            }

            MouseArea {
                anchors.fill: box
                enabled: !page.renaming
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: event => {
                    strip.forceActiveFocus();
                    if (event.button === Qt.RightButton) {
                        const p = mapToItem(null, event.x, event.y);
                        root.tab.contextMenu(root.model, page.index, p.x, p.y, false);
                    }
                }
                onDoubleClicked: event => {
                    if (event.button === Qt.LeftButton)
                        root.tab.activate(page.index, root.model, event.modifiers);
                }
            }
        }
    }

    // Thumbnail strip ----------------------------------------------------------------------------
    Rectangle {
        y: pager.height
        width: pager.width
        height: root.hairline
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    ListView {
        id: strip
        y: pager.height + root.hairline
        width: pager.width
        height: Tokens.filesGalleryStripHeight - root.hairline
        orientation: ListView.Horizontal
        model: root.model
        clip: true
        focus: true
        activeFocusOnTab: true
        keyNavigationEnabled: false
        // Mouse drags select and drag files instead of flicking; the wheel still scrolls.
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        currentIndex: root.model ? root.model.currentRow : -1
        // The current thumbnail stays near the middle while the arrows move along the strip.
        highlightRangeMode: ListView.ApplyRange
        preferredHighlightBegin: Math.max(0, (strip.width - Tokens.filesGalleryStripCellWidth) / 2)
        preferredHighlightEnd: Math.max(0, (strip.width + Tokens.filesGalleryStripCellWidth) / 2)
        highlightMoveDuration: Appearance.reduceMotion ? 0 : Tokens.motionFast
        // A short strip is centred, as on macOS.
        leftMargin: Math.max(0, (strip.width - strip.count * Tokens.filesGalleryStripCellWidth) / 2)
        cacheBuffer: Tokens.filesGalleryStripCellWidth * 4
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Gallery")

        Keys.onPressed: event => root.tab.handleViewKey(event, root.model, key => Nav.stripMove(root.model.currentRow, key, strip.count, root.pageItems))

        // The keyboard's focus (not a click's) rings the selected thumbnail.
        KeyFocus {
            id: stripKeyFocus
            target: strip
        }

        delegate: FocusScope {
            id: cell

            required property int index
            required property string name
            required property url url
            required property string iconName
            required property string thumbnail
            required property string emblem
            required property bool selected
            required property bool isDir
            required property string folderColor
            required property string folderGlyph
            required property bool canPreview
            required property bool hidden
            // Cut and not pasted yet (FilesApp, the clipboard): drawn faded like a hidden item until Paste moves it.
            required property bool cut
            // A file the Open or Save panel cannot take (FolderModel.chooser).
            required property bool dimmed
            required property var tagColors

            width: Tokens.filesGalleryStripCellWidth
            height: strip.height
            opacity: cell.dimmed ? Tokens.materialDisabledOpacity : cell.hidden || cell.cut ? Tokens.filesHiddenOpacity : 1
            Accessible.role: Accessible.ListItem
            Accessible.name: DisplayName.text(cell.name)
            Accessible.selectable: true
            Accessible.selected: cell.selected
            Accessible.onPressAction: root.tab.activate(cell.index, root.model, Qt.NoModifier)

            Component.onCompleted: if (cell.canPreview) root.model.requestPreview(cell.index)
            onCanPreviewChanged: if (cell.canPreview) root.model.requestPreview(cell.index)
            Component.onDestruction: if (root.model) root.model.cancelPreview(cell.url)

            Rectangle {
                anchors.centerIn: parent
                width: Tokens.filesGalleryStripIconSize + 2 * Tokens.filesIconBackdropPadding
                height: width
                radius: Tokens.radiusControl
                // Selected: a fill as every content view, the accent while the strip has the focus, the shared unemphasized
                // grey otherwise (UI audit 2026-11-05 U16, LOW); a ring only for the keyboard's focus.
                color: cell.selected && strip.activeFocus ? Appearance.colors.selection
                    : cell.selected ? Appearance.unemphasizedSelection : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                visible: cell.selected || drop.containsDrag
                border.width: drop.containsDrag ? Tokens.filesDropBorder : cell.selected && stripKeyFocus.active ? Tokens.controlFocusOutline : 0
                border.color: drop.containsDrag ? Appearance.colors.accent : Appearance.focusRingColor
            }

            FileIcon {
                id: stripIcon
                anchors.centerIn: parent
                size: Tokens.filesGalleryStripIconSize
                iconName: cell.iconName
                isDir: cell.isDir
                folderColor: cell.folderColor
                folderGlyph: cell.folderGlyph
                thumbnail: cell.thumbnail
                emblem: cell.emblem
            }

            // Colour tags at the thumbnail's bottom right corner.
            TagDots {
                colors: cell.tagColors
                anchors.right: stripIcon.right
                anchors.bottom: stripIcon.bottom
            }

            DropArea {
                id: drop
                anchors.fill: parent
                enabled: cell.isDir && !cell.selected
                keys: ["text/uri-list"]
                onDropped: event => {
                    if (event.hasUrls) {
                        root.tab.dropUrls(event.urls, cell.url, root.model);
                        event.accept(Qt.CopyAction);
                    }
                }
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                drag.target: root.model.isApplications ? null : dragProxy
                drag.threshold: Tokens.filesDragThreshold
                property bool collapseOnRelease: false

                onPressed: event => {
                    strip.forceActiveFocus();
                    if (event.button === Qt.RightButton) {
                        const p = mouse.mapToItem(null, event.x, event.y);
                        root.tab.contextMenu(root.model, cell.index, p.x, p.y, false);
                        return;
                    }
                    const mods = event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier);
                    mouse.collapseOnRelease = cell.selected && mods === 0;
                    if (!cell.selected || mods !== 0)
                        root.model.select(cell.index, mods, true);
                }
                // A formal parameter: an injected `mouse` (the event) would hide the MouseArea's id.
                onReleased: () => {
                    if (mouse.collapseOnRelease && !mouse.drag.active)
                        root.model.select(cell.index, 0, true);
                    mouse.collapseOnRelease = false;
                }
                onDoubleClicked: event => {
                    if (event.button === Qt.LeftButton)
                        root.tab.activate(cell.index, root.model, event.modifiers);
                }
                drag.onActiveChanged: {
                    if (mouse.drag.active) {
                        mouse.collapseOnRelease = false;
                        dragProxy.Drag.mimeData = {"text/uri-list": root.tab.app.uriList(root.model.selectedUrls())};
                        dragProxy.Drag.imageSource = cell.thumbnail !== "" ? cell.thumbnail : IconSource.url(cell.iconName);
                        root.tab.dragStarted();
                        dragProxy.Drag.active = true;
                    }
                }
            }
        }
    }

    // Preview pane (View > Show Preview, the gallery's own setting): the shared pane with a small preview beside the name,
    // the view's own preview being the large one.
    Loader {
        id: infoPanel
        active: root.showInfo
        x: pager.width
        height: parent.height
        sourceComponent: PreviewPane {
            topExtension: root.tab.win ? root.tab.win.previewExtension : 0
            tab: root.tab
            model: root.model
            large: false
        }
    }

    Text {
        textFormat: Text.PlainText
        x: 0
        y: 0
        width: pager.width
        height: pager.height
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        visible: strip.count === 0 && root.model && !root.model.loading
        text: root.tab.searchText !== "" || (root.model && root.model.isFileSearch && root.model.error === "") ? qsTr("No Results") : root.model && root.model.error !== "" ? root.model.error : qsTr("This folder is empty.")
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }
}
