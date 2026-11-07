pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "IconSource.js" as IconSource
import "Nav.js" as Nav

// List view: Name, Date Modified, Size and Kind columns; clicking a header sorts by it (again: reverses).
FocusScope {
    id: root
    // A rule or frame: one point (apps.borderWidth, ADR-0039 D5) in whole device pixels, 1 px at 1.25 where 1 pt drew a soft
    // 1.25 px (UI audit 2026-11-05 U37); 1 px at 1x and 2 px at 2x as before.
    readonly property real hairline: Math.max(1, Math.round(Tokens.appsBorderWidth * Screen.devicePixelRatio)) / Math.max(1, Screen.devicePixelRatio)

    required property var tab
    required property var model

    readonly property real nameWidth: Math.max(Tokens.filesListNameMinWidth, list.width - Tokens.filesListDateWidth - Tokens.filesListSizeWidth - Tokens.filesListKindWidth)
    // The columns keep their widths: a list narrower than them (a narrow window, the preview pane) scrolls sideways, the
    // header with it (macOS).
    readonly property real columnsWidth: root.nameWidth + Tokens.filesListDateWidth + Tokens.filesListSizeWidth + Tokens.filesListKindWidth
    readonly property int pageRows: Math.max(1, Math.floor(list.height / Tokens.filesListRowHeight))
    // The rows have moved up under the toolbar (the window draws the toolbar's hairline then, macOS).
    readonly property bool scrolled: list.contentY > list.originY

    // Rubber band (Finder): a drag from the empty space under the rows, or from a row outside its icon and name, selects
    // the rows it covers (with Shift or Cmd, added to the selection there was). Points in list.contentItem coordinates.
    property bool banding: false
    property point bandOrigin
    property point bandEnd
    property var bandBase: []

    function bandPress(item: Item, x: real, y: real, modifiers: int): void {
        root.bandOrigin = item.mapToItem(list.contentItem, x, y);
        root.bandEnd = root.bandOrigin;
        root.bandBase = (modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) ? root.model.selectedUrls() : [];
        root.banding = false;
    }

    function bandMove(item: Item, x: real, y: real): void {
        const p = item.mapToItem(list.contentItem, x, y);
        if (!root.banding && Math.abs(p.x - root.bandOrigin.x) + Math.abs(p.y - root.bandOrigin.y) < Tokens.filesDragThreshold)
            return;
        root.banding = true;
        root.bandEnd = p;
        const groups = root.model.groupBy > 0 ? root.model.groups : [];
        const rows = groups.length > 0 ? Nav.groupedRowsInSpan(root.bandOrigin.y, p.y, Tokens.filesListRowHeight, Tokens.filesListGroupHeight, groups)
                                       : Nav.cellsInRect(0, root.bandOrigin.y, 0, p.y, 1, Tokens.filesListRowHeight, 1, list.count);
        const urls = root.bandBase.slice();
        for (let i = 0; i < rows.length; i++)
            urls.push(root.model.urlAt(rows[i]));
        root.model.selectUrls(urls);
        // Scroll while the band reaches past the edges.
        const inList = item.mapToItem(list, x, y);
        if (inList.y > list.height)
            list.contentY = Math.min(list.contentY + Tokens.spacingSm, Math.max(list.originY, list.contentHeight - list.height + list.originY));
        else if (inList.y < 0)
            list.contentY = Math.max(list.originY, list.contentY - Tokens.spacingSm);
    }

    clip: true
    Accessible.role: Accessible.Table
    Accessible.name: qsTr("Files")

    function applyPrefs(): void {
    }

    function focusView(): void {
        list.forceActiveFocus();
    }

    function rowPosition(model: var, row: int): point {
        if (row < 0)
            return root.mapToItem(null, Tokens.spacingLg, headerRow.height + Tokens.spacingLg);
        return list.mapToItem(null, Tokens.spacingLg * 2, (row + 1) * Tokens.filesListRowHeight - list.contentY + list.originY);
    }

    Connections {
        target: root.model
        ignoreUnknownSignals: true
        function onCurrentRowChanged(): void {
            if (root.model.currentRow >= 0)
                list.positionViewAtIndex(root.model.currentRow, ListView.Contain);
        }
        function onRevealRequested(row: int, rename: bool): void {
            list.positionViewAtIndex(row, ListView.Contain);
            if (rename)
                root.tab.startRename(root.model, row);
        }
    }

    Item {
        id: dragProxy
        visible: false
        width: Tokens.filesListIconSize
        height: Tokens.filesListIconSize
        Drag.dragType: Drag.Automatic
        // No link: Wayland drag and drop has none (a drop proposing it is refused); Files makes an alias itself
        // for Option-Cmd (FilesApp.drop).
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
        Drag.proposedAction: Qt.MoveAction
        Drag.onDragFinished: dropAction => {
            dragProxy.Drag.active = false;
            root.tab.dragFinished(dropAction);
        }
    }

    // Header ------------------------------------------------------------------------------------
    Row {
        id: headerRow
        x: list.x - (list.contentX - list.originX)
        width: list.contentWidth
        height: Tokens.filesListHeaderHeight

        Repeater {
            model: [
                {key: 0, title: qsTr("Name")},
                {key: 2, title: qsTr("Date Modified")},
                {key: 3, title: qsTr("Size")},
                {key: 1, title: qsTr("Kind")}
            ]

            delegate: Item {
                id: column
                required property var modelData
                readonly property bool active: root.tab.sortKey === column.modelData.key

                width: column.modelData.key === 0 ? root.nameWidth : column.modelData.key === 2 ? Tokens.filesListDateWidth : column.modelData.key === 3 ? Tokens.filesListSizeWidth : Tokens.filesListKindWidth
                height: headerRow.height
                activeFocusOnTab: false
                Accessible.role: Accessible.ColumnHeader
                Accessible.name: column.modelData.title
                Accessible.onPressAction: root.tab.sortBy(column.modelData.key, true)

                Rectangle {
                    anchors.fill: parent
                    color: headerMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
                }

                Rectangle {
                    visible: column.modelData.key !== 0
                    width: root.hairline
                    height: parent.height - Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                }

                Text {
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.leftMargin: Tokens.spacingSm
                    anchors.right: arrow.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: column.modelData.title
                    elide: Text.ElideRight
                    color: column.active ? Appearance.colors.text : Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    font.weight: column.active ? Tokens.typographyMenuBoldWeight : Tokens.typographyMenuWeight
                }

                Icon {
                    id: arrow
                    visible: column.active
                    anchors.right: parent.right
                    anchors.rightMargin: Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron-down"
                    size: Tokens.filesChevronSize
                    color: Appearance.windowSecondary
                    rotation: root.tab.sortDescending ? 0 : 180
                }

                MouseArea {
                    id: headerMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.tab.sortBy(column.modelData.key, true)
                }
            }
        }
    }

    Rectangle {
        anchors.top: headerRow.bottom
        width: parent.width
        height: root.hairline
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    // Background --------------------------------------------------------------------------------
    DropArea {
        anchors.fill: list
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
        id: background
        anchors.fill: list
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: mouse => {
            list.forceActiveFocus();
            if (mouse.button === Qt.RightButton) {
                const p = mapToItem(null, mouse.x, mouse.y);
                root.tab.contextMenu(root.model, -1, p.x, p.y, false);
                return;
            }
            root.bandPress(background, mouse.x, mouse.y, mouse.modifiers);
            if (root.bandBase.length === 0)
                root.model.clearSelection();
        }
        onPositionChanged: mouse => {
            if (pressed && mouse.buttons === Qt.LeftButton)
                root.bandMove(background, mouse.x, mouse.y);
        }
        onReleased: root.banding = false
        onCanceled: root.banding = false
    }

    ListView {
        id: list
        anchors.top: headerRow.bottom
        anchors.topMargin: root.hairline
        anchors.left: parent.left
        anchors.right: parent.right
        // The overlay scroll bar floats over the rows (macOS), no lane of its own (UI audit 2026-11-05 U32); the rows keep
        // their inner padding.
        anchors.bottom: parent.bottom
        model: root.model
        clip: true
        contentWidth: Math.max(list.width, root.columnsWidth)
        flickableDirection: Flickable.AutoFlickIfNeeded
        focus: true
        activeFocusOnTab: true
        keyNavigationEnabled: false
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        currentIndex: root.model ? root.model.currentRow : -1
        cacheBuffer: Tokens.filesListRowHeight * 20
        Accessible.role: Accessible.Table
        Accessible.name: qsTr("Files")

        Keys.onPressed: event => root.tab.handleViewKey(event, root.model, key => Nav.listMove(root.model.currentRow, key, list.count, root.pageRows))

        // View > Group By: a header above each group (no capture of the Finder's grouped list: visual NOT verified).
        section.property: root.model && root.model.groupBy > 0 ? "group" : ""
        section.criteria: ViewSection.FullString
        section.delegate: Item {
            id: groupHeader

            required property string section

            width: list.contentWidth
            height: Tokens.filesListGroupHeight
            Accessible.role: Accessible.Heading
            Accessible.name: groupHeader.section

            Text {
                textFormat: Text.PlainText
                x: Tokens.spacingSm + Tokens.spacingXs
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Tokens.spacingXs
                width: parent.width - 2 * x
                text: groupHeader.section
                elide: Text.ElideRight
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Tokens.typographyMenuBoldWeight
            }

            Rectangle {
                anchors.bottom: parent.bottom
                x: Tokens.spacingXs
                width: parent.width - 2 * x
                height: root.hairline
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }
        }

        delegate: FocusScope {
            id: row

            required property int index
            required property string name
            required property url url
            required property string iconName
            required property string emblem
            required property string modifiedText
            required property string sizeText
            required property string kind
            required property bool selected
            required property bool isDir
            required property string folderColor
            required property string folderGlyph
            required property bool hidden
            // Cut and not pasted yet (FilesApp, the clipboard): drawn faded like a hidden item until Paste moves it.
            required property bool cut
            // A file the Open or Save panel cannot take (FolderModel.chooser).
            required property bool dimmed
            required property var tagColors

            readonly property bool renaming: root.tab.isRenaming(root.model, row.url)
            readonly property bool emphasized: row.selected && list.activeFocus
            readonly property color foreground: row.emphasized ? Appearance.colors.selectionText : Appearance.colors.text
            readonly property color secondary: row.emphasized ? Appearance.colors.selectionText : Appearance.windowSecondary

            width: list.contentWidth
            height: Tokens.filesListRowHeight
            opacity: row.dimmed ? Tokens.materialDisabledOpacity : row.hidden || row.cut ? Tokens.filesHiddenOpacity : 1
            Accessible.role: Accessible.Row
            Accessible.name: DisplayName.text(row.name)
            Accessible.description: [row.modifiedText, row.sizeText, row.kind].join(", ")
            Accessible.selectable: true
            Accessible.selected: row.selected
            Accessible.onPressAction: root.tab.activate(row.index, root.model, Qt.NoModifier)

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: Tokens.spacingXs
                anchors.rightMargin: Tokens.spacingXs
                radius: Tokens.radiusControl
                color: row.selected ? (row.emphasized ? Appearance.colors.selection : Appearance.unemphasizedSelection)
                     : row.index % 2 === 1 ? Appearance.withAlpha(Appearance.colors.fill, Tokens.filesStripeOpacity) : "transparent"
                border.width: rowDrop.containsDrag ? Tokens.filesDropBorder : 0
                border.color: Appearance.colors.accent
            }

            FileIcon {
                id: icon
                x: Tokens.spacingSm + Tokens.spacingXs
                anchors.verticalCenter: parent.verticalCenter
                size: Tokens.filesListIconSize
                overAccent: row.emphasized
                iconName: row.iconName
                isDir: row.isDir
                folderColor: row.folderColor
                folderGlyph: row.folderGlyph
                emblem: row.emblem
            }

            Text {
                id: nameText
                textFormat: Text.PlainText
                visible: !row.renaming
                anchors.left: icon.right
                anchors.leftMargin: Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                width: root.nameWidth - icon.x - icon.width - 2 * Tokens.spacingSm - (rowDots.visible ? rowDots.width + Tokens.spacingSm : 0)
                text: DisplayName.text(row.name)
                // Names start at the left edge, also one that starts with a right-to-left letter (Finder; Qt aligns such a
                // text right by itself; integrator nested pass of step 5c, NIT).
                horizontalAlignment: Text.AlignLeft
                elide: Text.ElideMiddle
                color: row.foreground
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            // Colour tags right after the name.
            TagDots {
                id: rowDots
                visible: !row.renaming && rowDots.shown.length > 0
                colors: row.tagColors
                x: nameText.x + nameText.paintedWidth + Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                ringColor: row.emphasized ? Appearance.colors.selection : Appearance.windowFill
            }

            Loader {
                active: row.renaming
                anchors.left: icon.right
                anchors.leftMargin: Tokens.spacingXs
                anchors.verticalCenter: parent.verticalCenter
                width: root.nameWidth - icon.x - icon.width - Tokens.spacingSm
                height: parent.height - Tokens.spacingXs / 2
                sourceComponent: RenameField {
                    originalName: row.name
                    baseLength: root.tab.app.baseNameLength(row.name, row.isDir)
                    onCommitted: name => root.tab.commitRename(name)
                    onCanceled: root.tab.cancelRename()
                }
            }

            Text {
                textFormat: Text.PlainText
                x: root.nameWidth + Tokens.spacingSm
                width: Tokens.filesListDateWidth - 2 * Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                text: row.modifiedText
                elide: Text.ElideRight
                color: row.secondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            Text {
                textFormat: Text.PlainText
                x: root.nameWidth + Tokens.filesListDateWidth + Tokens.spacingSm
                width: Tokens.filesListSizeWidth - 2 * Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: row.sizeText
                elide: Text.ElideRight
                color: row.secondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            Text {
                textFormat: Text.PlainText
                x: root.nameWidth + Tokens.filesListDateWidth + Tokens.filesListSizeWidth + Tokens.spacingSm
                width: Tokens.filesListKindWidth - 2 * Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                text: row.kind
                elide: Text.ElideRight
                color: row.secondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            DropArea {
                id: rowDrop
                anchors.fill: parent
                enabled: row.isDir && !row.selected
                keys: ["text/uri-list"]
                onEntered: root.tab.springHover(row.url)
                onExited: root.tab.springLeave(row.url)
                onDropped: event => {
                    if (event.hasUrls) {
                        root.tab.dropUrls(event.urls, row.url, root.model);
                        event.accept(Qt.CopyAction);
                    }
                }
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                enabled: !row.renaming
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                drag.target: (root.model.isApplications || mouse.bandStart) ? null : dragProxy
                drag.threshold: Tokens.filesDragThreshold
                property bool collapseOnRelease: false
                // Pressed outside the icon and the name: a drag draws a rubber band, a click selects the row.
                property bool bandStart: false
                property int pressModifiers: 0

                onPressed: event => {
                    list.forceActiveFocus();
                    if (event.button === Qt.RightButton) {
                        const p = mouse.mapToItem(null, event.x, event.y);
                        root.tab.contextMenu(root.model, row.index, p.x, p.y, false);
                        return;
                    }
                    const mods = event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier);
                    const nameEnd = rowDots.visible ? rowDots.x + rowDots.width : nameText.x + Math.min(nameText.paintedWidth, nameText.width);
                    mouse.bandStart = event.x > nameEnd + Tokens.spacingSm;
                    if (mouse.bandStart) {
                        mouse.pressModifiers = mods;
                        root.bandPress(mouse, event.x, event.y, mods);
                        return;
                    }
                    collapseOnRelease = row.selected && mods === 0;
                    if (!row.selected || mods !== 0)
                        root.model.select(row.index, mods, true);
                }
                onPositionChanged: event => {
                    if (mouse.bandStart && pressed && event.buttons === Qt.LeftButton)
                        root.bandMove(mouse, event.x, event.y);
                }
                onReleased: event => {
                    if (mouse.bandStart) {
                        if (!root.banding)
                            root.model.select(row.index, mouse.pressModifiers, true);
                        root.banding = false;
                        mouse.bandStart = false;
                        return;
                    }
                    if (collapseOnRelease && !drag.active)
                        root.model.select(row.index, 0, true);
                    collapseOnRelease = false;
                }
                // A band whose row went away (scrolled far past the cache) or whose press was taken ends there.
                onCanceled: mouse.endBand()
                Component.onDestruction: mouse.endBand()
                function endBand(): void {
                    if (!mouse.bandStart)
                        return;
                    mouse.bandStart = false;
                    root.banding = false;
                }
                onDoubleClicked: event => {
                    if (event.button === Qt.LeftButton)
                        root.tab.activate(row.index, root.model, event.modifiers);
                }
                drag.onActiveChanged: {
                    if (drag.active) {
                        collapseOnRelease = false;
                        dragProxy.Drag.mimeData = {"text/uri-list": root.tab.app.uriList(root.model.selectedUrls())};
                        dragProxy.Drag.imageSource = IconSource.url(row.iconName);
                        root.tab.dragStarted();
                        dragProxy.Drag.active = true;
                    }
                }
            }
        }
    }

    Rectangle {
        parent: list.contentItem
        z: 1
        visible: root.banding
        x: Math.min(root.bandOrigin.x, root.bandEnd.x)
        y: Math.min(root.bandOrigin.y, root.bandEnd.y)
        width: Math.abs(root.bandEnd.x - root.bandOrigin.x)
        height: Math.abs(root.bandEnd.y - root.bandOrigin.y)
        color: Appearance.withAlpha(Appearance.colors.accent, Tokens.filesRubberBandOpacity)
        border.width: root.hairline
        border.color: Appearance.colors.accent
    }

    ScrollBar {
        id: scrollBar
        flickable: list
        anchors.right: parent.right
        anchors.top: list.top
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.spacingXs
    }

    Text {
        textFormat: Text.PlainText
        anchors.centerIn: list
        visible: list.count === 0 && root.model && !root.model.loading
        text: root.tab.searchText !== "" || (root.model && root.model.isFileSearch && root.model.error === "") ? qsTr("No Results") : root.model && root.model.error !== "" ? root.model.error : qsTr("This folder is empty.")
        width: list.width - 2 * Tokens.spacingLg
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }
}
