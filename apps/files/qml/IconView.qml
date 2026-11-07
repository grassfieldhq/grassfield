pragma ComponentBehavior: Bound
import QtQuick
import QtQml.Models
import Grassfield.Ui
import "IconSource.js" as IconSource
import "Nav.js" as Nav

// Icon view: a grid of thumbnails or type icons with names below. Click selects (Shift extends,
// Ctrl toggles), double click opens, drag on empty space draws a selection rectangle, items drag
// out as text/uri-list, folders and the background accept drops. With View > Group By, each group is one row under its
// header, scrolled sideways, and Show All lays the group out in full (Finder).
FocusScope {
    id: root
    // A rule or frame: one point (apps.borderWidth, ADR-0039 D5) in whole device pixels, 1 px at 1.25 where 1 pt drew a soft
    // 1.25 px (UI audit 2026-11-05 U37); 1 px at 1x and 2 px at 2x as before.
    readonly property real hairline: Math.max(1, Math.round(Tokens.appsBorderWidth * Screen.devicePixelRatio)) / Math.max(1, Screen.devicePixelRatio)

    required property var tab
    required property var model

    readonly property int columns: Math.max(1, Math.floor(grid.width / Tokens.filesIconCellWidth))
    readonly property real cellWidth: Math.floor(grid.width / root.columns)
    readonly property int pageRows: Math.max(1, Math.floor(grid.height / grid.cellHeight))
    readonly property bool grouped: root.model !== null && root.model.groupBy > 0
    readonly property var groups: root.grouped ? root.model.groups : []
    // Groups shown in full (Show All), by title; forgotten with the folder.
    property var expanded: ({})
    // How far each one-line group is scrolled sideways, by title (written in place: nothing binds to it).
    property var rowScroll: ({})
    // The groups as Nav.groupedIconMove sees them: a collapsed group is one line of all its items.
    readonly property var navGroups: root.groups.map(g => ({first: g.first, count: g.count, columns: root.expanded[g.title] === true ? root.columns : g.count}))
    // The top of each group in the grouped layout, then its whole height.
    readonly property var groupTops: Nav.groupedIconTops(root.navGroups, Tokens.filesIconGroupHeight, Tokens.filesIconCellHeight)
    // The flickable that holds the items now.
    readonly property Flickable flick: root.grouped ? groupedView : grid
    // The content has moved up under the toolbar (the window draws the toolbar's hairline then, macOS).
    readonly property bool scrolled: root.flick.contentY > root.flick.originY

    Accessible.role: Accessible.List
    Accessible.name: qsTr("Files")

    function applyPrefs(): void {
    }

    function focusView(): void {
        root.flick.forceActiveFocus();
    }

    function setExpanded(title: string, on: bool): void {
        const next = Object.assign({}, root.expanded);
        next[title] = on;
        root.expanded = next;
    }

    // Where `row` sits in the grouped layout (Nav.groupedIconCell), null for none.
    function groupedCell(row: int): var {
        return Nav.groupedIconCell(row, root.cellWidth, Tokens.filesIconCellHeight, Tokens.filesIconGroupHeight, root.navGroups);
    }

    // Scrolls `row` into view, as little as it takes (in the grouped layout: down the page, then along its group's line;
    // a cell of a group's first line comes with the group's header).
    function reveal(row: int): void {
        if (!root.grouped) {
            grid.positionViewAtIndex(row, GridView.Contain);
            return;
        }
        const cell = root.groupedCell(row);
        if (cell === null)
            return;
        const top = cell.line === 0 ? cell.y - Tokens.filesIconGroupHeight : cell.y;
        const bottom = cell.y + Tokens.filesIconCellHeight;
        const y = Math.min(top, Math.max(groupedView.contentY, bottom - groupedView.height));
        groupedView.contentY = Math.max(0, Math.min(y, groupedView.contentHeight - groupedView.height));
        const section = sections.itemAt(cell.group);
        if (section && !section.full)
            section.revealX(cell.x);
    }

    // The sideways scroll of the one-line groups, for Nav.groupedIconCells.
    function bandGroups(): var {
        return root.navGroups.map((g, i) => {
            const section = sections.itemAt(i);
            return {first: g.first, count: g.count, columns: g.columns, scrollX: section && !section.full ? section.scroll : 0};
        });
    }

    // FolderModel.groups into groupsModel, changed in place: a section keeps its cells and its scroll while it stays.
    function syncGroups(): void {
        const groups = root.groups;
        for (let i = 0; i < groups.length; i++) {
            const g = {title: groups[i].title, first: groups[i].first, itemCount: groups[i].count};
            if (i >= groupsModel.count) {
                groupsModel.append(g);
                continue;
            }
            const old = groupsModel.get(i);
            if (old.title !== g.title || old.first !== g.first || old.itemCount !== g.itemCount)
                groupsModel.set(i, g);
        }
        if (groupsModel.count > groups.length)
            groupsModel.remove(groups.length, groupsModel.count - groups.length);
        for (let i = 0; i < sections.count; i++)
            sections.itemAt(i).refresh();
        // A shorter page: the scroll stays within it (once the layout has followed).
        Qt.callLater(() => groupedView.contentY = Math.max(0, Math.min(groupedView.contentY, groupedView.contentHeight - groupedView.height)));
    }

    onGroupsChanged: root.syncGroups()

    // Window coordinates of a row (keyboard context menu).
    function rowPosition(model: var, row: int): point {
        if (row < 0)
            return root.mapToItem(null, Tokens.spacingLg, Tokens.spacingLg);
        if (root.grouped) {
            const cell = root.groupedCell(row);
            if (cell === null)
                return root.mapToItem(null, Tokens.spacingLg, Tokens.spacingLg);
            const section = sections.itemAt(cell.group);
            const scroll = section && !section.full ? section.scroll : 0;
            return groupedView.contentItem.mapToItem(null, cell.x - scroll + root.cellWidth / 2, cell.y + Tokens.filesIconSize);
        }
        const col = row % root.columns;
        const r = Math.floor(row / root.columns);
        return grid.mapToItem(null, (col + 0.5) * grid.cellWidth, r * grid.cellHeight - grid.contentY + grid.originY + Tokens.filesIconSize);
    }

    Connections {
        target: root.model
        ignoreUnknownSignals: true
        function onCurrentRowChanged(): void {
            if (root.model.currentRow >= 0)
                root.reveal(root.model.currentRow);
        }
        function onRevealRequested(row: int, rename: bool): void {
            root.reveal(row);
            if (rename)
                root.tab.startRename(root.model, row);
        }
        // Another folder opens at its top, every line at its start.
        function onUrlChanged(): void {
            root.expanded = {};
            root.rowScroll = {};
            groupedView.contentY = 0;
            for (let i = 0; i < sections.count; i++)
                sections.itemAt(i).setScroll(0);
        }
    }

    // Drag source shared by all cells (the system drag starts when Drag.active turns true).
    Item {
        id: dragProxy
        width: Tokens.filesIconSize
        height: Tokens.filesIconSize
        visible: false
        Drag.dragType: Drag.Automatic
        // No link: Wayland drag and drop has none (a drop proposing it is refused); Files makes an alias itself
        // for Option-Cmd (FilesApp.drop).
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
        Drag.proposedAction: Qt.MoveAction
        Drag.hotSpot.x: Tokens.filesIconSize / 2
        Drag.hotSpot.y: Tokens.filesIconSize / 2
        Drag.onDragFinished: dropAction => {
            dragProxy.Drag.active = false;
            root.tab.dragFinished(dropAction);
        }
    }

    function startDrag(iconName: string, thumbnail: string): void {
        dragProxy.Drag.mimeData = {"text/uri-list": root.tab.app.uriList(root.model.selectedUrls())};
        dragProxy.Drag.imageSource = thumbnail !== "" ? thumbnail : IconSource.url(iconName);
        root.tab.dragStarted();
        dragProxy.Drag.active = true;
    }

    // Background: empty-space clicks, rubber band selection, context menu and drops into this folder.
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
        id: background
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property point origin
        property bool banding: false
        property var baseSelection: []

        onPressed: mouse => {
            root.focusView();
            if (mouse.button === Qt.RightButton) {
                const p = background.mapToItem(null, mouse.x, mouse.y);
                root.tab.contextMenu(root.model, -1, p.x, p.y, false);
                return;
            }
            const f = root.flick;
            origin = Qt.point(mouse.x - f.x, mouse.y - f.y + f.contentY - f.originY);
            baseSelection = (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) ? root.model.selectedUrls() : [];
            if (baseSelection.length === 0)
                root.model.clearSelection();
            banding = false;
        }
        onPositionChanged: mouse => {
            if (!pressed || mouse.buttons !== Qt.LeftButton)
                return;
            const f = root.flick;
            const y = mouse.y - f.y + f.contentY - f.originY;
            const x = mouse.x - f.x;
            if (!banding && Math.abs(x - origin.x) + Math.abs(y - origin.y) < Tokens.filesDragThreshold)
                return;
            banding = true;
            band.x = f.x + Math.min(x, origin.x);
            band.width = Math.abs(x - origin.x);
            band.contentTop = Math.min(y, origin.y);
            band.height = Math.abs(y - origin.y);
            const rows = root.grouped ? Nav.groupedIconCells(origin.x, origin.y, x, y, root.cellWidth, Tokens.filesIconCellHeight, Tokens.filesIconGroupHeight, root.bandGroups())
                                      : Nav.cellsInRect(origin.x, origin.y, x, y, grid.cellWidth, grid.cellHeight, root.columns, grid.count);
            const urls = baseSelection.slice();
            for (let i = 0; i < rows.length; i++)
                urls.push(root.model.urlAt(rows[i]));
            root.model.selectUrls(urls);
            // Scroll while the band reaches past the edges.
            if (mouse.y > f.y + f.height)
                f.contentY = Math.min(f.contentY + Tokens.spacingSm, Math.max(f.originY, f.contentHeight - f.height + f.originY));
            else if (mouse.y < f.y)
                f.contentY = Math.max(f.originY, f.contentY - Tokens.spacingSm);
        }
        onReleased: banding = false
        onCanceled: banding = false
    }

    GridView {
        id: grid
        anchors.fill: parent
        anchors.margins: Tokens.spacingSm
        // The overlay scroll bar floats over the icons (macOS), no lane of its own (UI audit 2026-11-05 U32).
        visible: !root.grouped
        cellWidth: root.cellWidth
        cellHeight: Tokens.filesIconCellHeight
        model: root.grouped ? null : root.model
        clip: true
        focus: !root.grouped
        activeFocusOnTab: !root.grouped
        keyNavigationEnabled: false
        // Mouse drags select and drag files instead of flicking; the wheel still scrolls.
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: Tokens.filesIconCellHeight * 2
        currentIndex: root.model && !root.grouped ? root.model.currentRow : -1
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Files")

        Keys.onPressed: event => root.tab.handleViewKey(event, root.model, key => Nav.gridMove(root.model.currentRow, key, root.columns, grid.count, root.pageRows))

        delegate: IconCell {}
    }

    // FolderModel.groups as the sections show them (root.syncGroups).
    ListModel {
        id: groupsModel
    }

    // Grouped layout: one section per group, its items in one line or, after Show All, in full. The sections are all made
    // (a folder has few groups) and placed from root.groupTops; only the cells near the view are.
    Flickable {
        id: groupedView
        anchors.fill: grid
        visible: root.grouped
        contentWidth: width
        contentHeight: root.groupTops[root.groupTops.length - 1]
        clip: true
        focus: root.grouped
        activeFocusOnTab: root.grouped
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Files")

        Keys.onPressed: event => root.tab.handleViewKey(event, root.model, key => Nav.groupedIconMove(root.model.currentRow, key, root.navGroups))

        Repeater {
            id: sections
            model: groupsModel

            delegate: Item {
                id: section

                required property int index
                required property string title
                required property int first
                required property int itemCount

                readonly property bool full: root.expanded[section.title] === true
                readonly property bool overflows: section.itemCount * root.cellWidth > groupedView.width
                // The page in view, in this section's coordinates, widened by the margin the flat grid makes cells ahead in.
                readonly property real viewTop: groupedView.contentY - section.y - grid.cacheBuffer
                readonly property real viewBottom: groupedView.contentY - section.y + groupedView.height + grid.cacheBuffer
                // Not before the view has its size: a line laid out at a zero cell width makes every cell of its group.
                readonly property bool near: root.cellWidth > 0 && section.viewBottom > 0 && section.viewTop < section.height
                // How far the one line is scrolled sideways.
                property real scroll: 0

                y: root.groupTops[section.index] ?? 0
                width: groupedView.width
                height: Tokens.filesIconGroupHeight + (section.full ? Math.ceil(section.itemCount / root.columns) : 1) * Tokens.filesIconCellHeight
                Accessible.role: Accessible.Grouping
                Accessible.name: section.title

                function setScroll(x: real): void {
                    section.scroll = Math.max(0, Math.min(x, section.itemCount * root.cellWidth - groupedView.width));
                    root.rowScroll[section.title] = section.scroll;
                    section.place();
                }

                // Asks the section's views (while they exist: `content`) to take the place this section says, or its rows again.
                signal placeRequested
                signal syncRequested

                function place(): void {
                    section.placeRequested();
                }

                function revealX(x: real): void {
                    if (x < section.scroll)
                        section.setScroll(x);
                    else if (x + root.cellWidth > section.scroll + groupedView.width)
                        section.setScroll(x + root.cellWidth - groupedView.width);
                }

                function syncRange(): void {
                    section.syncRequested();
                }

                // The title shown when the scroll was last placed: a group that moved to this place brings its own scroll.
                property string placedTitle: ""

                // After the groups changed (all of this section's roles set): its rows, then its scroll.
                function refresh(): void {
                    section.syncRange();
                    if (section.placedTitle !== section.title) {
                        section.placedTitle = section.title;
                        section.setScroll(root.rowScroll[section.title] ?? 0);
                    } else {
                        section.setScroll(section.scroll);
                    }
                }

                onWidthChanged: section.setScroll(section.scroll)
                Component.onCompleted: section.refresh()

                // The header, the DelegateModel of the group's rows and its views exist only while the section is near the
                // view: a folder grouped by name can have thousands of groups, and every DelegateModel follows every change
                // of the listing (a thumbnail, a selection). Measured offscreen with 5,000 items in 2,500 groups: making the
                // view 6.1 s and 3.6 ms per changed row with one per group (docs/specs/files.md "Views and selection").
                Loader {
                    id: content
                    width: section.width
                    height: section.height
                    active: section.near
                    sourceComponent: Item {
                        id: body

                        // The inner views at the place the section says: a view given its model again, or whose model was
                        // reset (a new sort), starts at its beginning.
                        function place(): void {
                            sectionRow.contentX = sectionRow.originX + section.scroll;
                            sectionGrid.contentY = sectionGrid.originY + sectionGrid.shownTop - Tokens.filesIconGroupHeight;
                        }

                        // The range group holds this group's rows of the listing; it is set again only when it no longer holds
                        // exactly those rows (a group that kept its place keeps its cells).
                        function syncRange(): void {
                            const n = rangeGroup.count;
                            if (n === section.itemCount && (n === 0 || (rangeGroup.get(0).itemsIndex === section.first && rangeGroup.get(n - 1).itemsIndex === section.first + n - 1)))
                                return;
                            if (n > 0)
                                rangeGroup.remove(0, n);
                            if (section.first + section.itemCount <= range.items.count)
                                range.items.addGroups(section.first, section.itemCount, ["range"]);
                        }

                        Connections {
                            target: section
                            function onPlaceRequested(): void {
                                body.place();
                            }
                            function onSyncRequested(): void {
                                body.syncRange();
                            }
                        }

                        Component.onCompleted: {
                            body.syncRange();
                            body.place();
                        }

                        Text {
                            textFormat: Text.PlainText
                            x: Tokens.spacingSm
                            anchors.verticalCenter: header.verticalCenter
                            // Up to "Show All" when it shows, else the row's width (UI audit 2026-11-05, LOW).
                            width: (showAll.visible ? showAll.x : parent.width) - x - Tokens.spacingSm
                            text: section.title
                            elide: Text.ElideRight
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            font.weight: Tokens.typographyMenuBoldWeight
                            Accessible.role: Accessible.Heading
                            Accessible.name: text
                        }

                        Item {
                            id: header
                            width: parent.width
                            height: Tokens.filesIconGroupHeight
                        }

                        Text {
                            id: showAll
                            textFormat: Text.PlainText
                            anchors.right: parent.right
                            anchors.rightMargin: Tokens.spacingSm
                            anchors.verticalCenter: header.verticalCenter
                            visible: section.overflows || section.full
                            text: section.full ? qsTr("Show Less") : qsTr("Show All")
                            color: Appearance.colors.accentInk
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            Accessible.role: Accessible.Button
                            Accessible.name: text
                            Accessible.onPressAction: root.setExpanded(section.title, !section.full)

                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -Tokens.spacingXs
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.setExpanded(section.title, !section.full)
                            }
                        }

                        DelegateModel {
                            id: range
                            model: root.model
                            groups: [
                                DelegateModelGroup {
                                    id: rangeGroup
                                    name: "range"
                                    includeByDefault: false
                                    // A reset of the listing (every new sort) empties it: filled again at once (the groups keep their
                                    // rows across a sort), and the views put back where they were.
                                    onCountChanged: {
                                        if (rangeGroup.count === 0 && section.itemCount > 0)
                                            Qt.callLater(() => section?.syncRange());
                                        Qt.callLater(() => section?.place());
                                    }
                                }
                            ]
                            filterOnGroup: "range"
                            delegate: IconCell {
                                row: DelegateModel.itemsIndex
                            }
                        }

                        ListView {
                            id: sectionRow
                            y: Tokens.filesIconGroupHeight
                            width: parent.width
                            height: Tokens.filesIconCellHeight
                            visible: !section.full
                            orientation: ListView.Horizontal
                            model: !section.full && section.near ? range : null
                            clip: true
                            interactive: false
                            acceptedButtons: Qt.NoButton
                            boundsBehavior: Flickable.StopAtBounds
                            onModelChanged: Qt.callLater(() => section?.place())

                            // A sideways wheel or trackpad swipe scrolls the line; a vertical one is left to the page.
                            WheelHandler {
                                orientation: Qt.Horizontal
                                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                onWheel: event => {
                                    // A wheel notch is 120 eighths of a degree (Qt): one item per notch.
                                    const dx = event.pixelDelta.x !== 0 ? event.pixelDelta.x : event.angleDelta.x / 120 * root.cellWidth;
                                    if (dx === 0) {
                                        event.accepted = false;
                                        return;
                                    }
                                    section.setScroll(section.scroll - dx);
                                }
                            }
                        }

                        // Shown in full: only the lines near the view are a part of the grid (a group of thousands makes the cells of
                        // one page).
                        GridView {
                            id: sectionGrid
                            readonly property real shownTop: Math.max(Tokens.filesIconGroupHeight, Math.min(section.height, section.viewTop))
                            readonly property real shownBottom: Math.max(sectionGrid.shownTop, Math.min(section.height, section.viewBottom))
                            y: sectionGrid.shownTop
                            width: parent.width
                            height: sectionGrid.shownBottom - sectionGrid.shownTop
                            visible: section.full
                            cellWidth: root.cellWidth
                            cellHeight: Tokens.filesIconCellHeight
                            model: section.full && section.near ? range : null
                            interactive: false
                            acceptedButtons: Qt.NoButton
                            cacheBuffer: 0
                            // Placed by section.place (a binding would be left behind when the view moves itself on a new model).
                            onShownTopChanged: section.place()
                            onModelChanged: Qt.callLater(() => section?.place())
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        id: band
        property real contentTop: 0
        visible: background.banding
        y: root.flick.y + contentTop - root.flick.contentY + root.flick.originY
        color: Appearance.withAlpha(Appearance.colors.accent, Tokens.filesRubberBandOpacity)
        border.width: root.hairline
        border.color: Appearance.colors.accent
    }

    ScrollBar {
        id: scrollBar
        flickable: root.flick
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.spacingXs
    }

    Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: root.model !== null && root.model.count === 0 && !root.model.loading
        text: root.tab.searchText !== "" || (root.model && root.model.isFileSearch && root.model.error === "") ? qsTr("No Results") : root.model && root.model.error !== "" ? root.model.error : qsTr("This folder is empty.")
        width: parent.width - 2 * Tokens.spacingLg
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    // One item: icon or thumbnail, name, tag dots, inline rename, drop target and drag source.
    component IconCell: FocusScope {
        id: cell

        required property int index
        // The item's row in the listing (the grouped rows give it: their own index counts within the group).
        property int row: cell.index
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

        readonly property bool renaming: root.tab.isRenaming(root.model, cell.url)
        readonly property bool focused: root.activeFocus
        // Room taken by the tag dots left of the name.
        readonly property real dotsRoom: dots.visible ? dots.width + Tokens.spacingXs : 0

        width: root.cellWidth
        height: Tokens.filesIconCellHeight
        opacity: cell.dimmed ? Tokens.materialDisabledOpacity : cell.hidden || cell.cut ? Tokens.filesHiddenOpacity : 1
        Accessible.role: Accessible.ListItem
        Accessible.name: DisplayName.text(cell.name)
        Accessible.selectable: true
        Accessible.selected: cell.selected
        Accessible.onPressAction: root.tab.activate(cell.row, root.model, Qt.NoModifier)

        Component.onCompleted: if (cell.canPreview) root.model.requestPreview(cell.row)
        onCanPreviewChanged: if (cell.canPreview) root.model.requestPreview(cell.row)
        // Scrolled away before its thumbnail was started: drop the request.
        Component.onDestruction: if (root.model) root.model.cancelPreview(cell.url)

        Rectangle {
            id: backdrop
            anchors.horizontalCenter: icon.horizontalCenter
            anchors.verticalCenter: icon.verticalCenter
            width: Tokens.filesIconSize + 2 * Tokens.filesIconBackdropPadding
            height: width
            radius: Tokens.radiusControl
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            visible: cell.selected || drop.containsDrag
            border.width: drop.containsDrag ? Tokens.filesDropBorder : 0
            border.color: Appearance.colors.accent
        }

        FileIcon {
            id: icon
            anchors.horizontalCenter: parent.horizontalCenter
            y: Tokens.spacingSm
            size: Tokens.filesIconSize
            iconName: cell.iconName
            isDir: cell.isDir
            folderColor: cell.folderColor
            folderGlyph: cell.folderGlyph
            thumbnail: cell.thumbnail
            emblem: cell.emblem
        }

        Rectangle {
            id: nameBox
            visible: cell.selected && !cell.renaming
            anchors.horizontalCenter: label.horizontalCenter
            y: label.y - Tokens.spacingXs / 2
            width: Math.min(label.paintedWidth + 2 * Tokens.spacingXs, cell.width - Tokens.spacingXs)
            height: label.paintedHeight + Tokens.spacingXs
            radius: Tokens.radiusControl / 2
            color: cell.focused ? Appearance.colors.selection : Appearance.unemphasizedSelection
        }

        // Colour tags: dots before the first line of the name; dots and name are centred together.
        TagDots {
            id: dots
            visible: !cell.renaming && dots.shown.length > 0
            colors: cell.tagColors
            x: label.x + (label.width - label.paintedWidth) / 2 - width - Tokens.spacingXs
            y: label.y + (label.paintedHeight / Math.max(1, label.lineCount) - height) / 2
        }

        Text {
            id: label
            textFormat: Text.PlainText
            visible: !cell.renaming
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.horizontalCenterOffset: cell.dotsRoom / 2
            anchors.top: icon.bottom
            anchors.topMargin: Tokens.spacingXs + Tokens.spacingXs / 2
            width: cell.width - 2 * Tokens.spacingXs - cell.dotsRoom
            horizontalAlignment: Text.AlignHCenter
            text: DisplayName.text(cell.name)
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            maximumLineCount: Tokens.filesIconLabelLines
            elide: Text.ElideRight
            color: cell.selected && cell.focused ? Appearance.colors.selectionText : Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.filesIconLabelSize
        }

        Loader {
            active: cell.renaming
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: icon.bottom
            anchors.topMargin: Tokens.spacingXs
            width: cell.width - Tokens.spacingXs
            sourceComponent: RenameField {
                originalName: cell.name
                baseLength: root.tab.app.baseNameLength(cell.name, cell.isDir)
                horizontalAlignment: TextInput.AlignHCenter
                onCommitted: name => root.tab.commitRename(name)
                onCanceled: root.tab.cancelRename()
            }
        }

        DropArea {
            id: drop
            // Over the icon and the name, like the clicks: the rest of the cell drops into the shown folder.
            x: mouse.x
            y: mouse.y
            width: mouse.width
            height: mouse.height
            enabled: cell.isDir && !cell.selected
            keys: ["text/uri-list"]
            onEntered: root.tab.springHover(cell.url)
            onExited: root.tab.springLeave(cell.url)
            onDropped: event => {
                if (event.hasUrls) {
                    root.tab.dropUrls(event.urls, cell.url, root.model);
                    event.accept(Qt.CopyAction);
                }
            }
        }

        MouseArea {
            id: mouse
            // The icon and the name (with its tag dots) take the clicks; the rest of the cell is the background, where a drag
            // draws a selection rectangle (Finder).
            x: Math.min(backdrop.x, nameBox.x - cell.dotsRoom)
            y: backdrop.y
            width: Math.max(backdrop.x + backdrop.width, nameBox.x + nameBox.width) - x
            height: nameBox.y + nameBox.height - y
            enabled: !cell.renaming
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            drag.target: root.model.isApplications ? null : dragProxy
            drag.threshold: Tokens.filesDragThreshold
            property bool collapseOnRelease: false

            onPressed: event => {
                root.focusView();
                if (event.button === Qt.RightButton) {
                    const p = mouse.mapToItem(null, event.x, event.y);
                    root.tab.contextMenu(root.model, cell.row, p.x, p.y, false);
                    return;
                }
                const mods = event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier);
                collapseOnRelease = cell.selected && mods === 0;
                if (!cell.selected || mods !== 0)
                    root.model.select(cell.row, mods, true);
            }
            onReleased: {
                if (collapseOnRelease && !drag.active)
                    root.model.select(cell.row, 0, true);
                collapseOnRelease = false;
            }
            onDoubleClicked: event => {
                if (event.button === Qt.LeftButton)
                    root.tab.activate(cell.row, root.model, event.modifiers);
            }
            drag.onActiveChanged: {
                if (drag.active) {
                    collapseOnRelease = false;
                    root.startDrag(cell.iconName, cell.thumbnail);
                }
            }
        }
    }
}
