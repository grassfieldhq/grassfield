pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TagColors.js" as TagColors

// Sidebar: Favorites (standard folders that exist, then the folders the user added), Locations (system volume, Solid
// volumes with eject, Network when a KIO network worker is installed, Trash) and Tags (the tags in use: a click lists the
// items with that tag in the shown folder and below, a drop tags the dropped items, the context menu removes the tag from
// the sidebar). Items accept drops. Favorites can be edited as in the Finder (FP-27, owner report 2026-11-07): folders
// dragged between its rows are added where the insertion line shows, a folder of the user's own is dragged to another
// place in the list or out of the sidebar (removed), and a folder place's menu (right click, the Menu key) has Remove from
// Sidebar. In an Open or Save panel (the tab's chooser set) it changes nothing: no insertion, no menu, a tag takes no drop.
FocusScope {
    id: root

    required property var app
    // The current BrowserTab.
    property var tab: null

    readonly property var places: root.app.places
    // The tab browses for an Open or Save panel (grassfield-portal, ADR-0035 D-4).
    readonly property bool choosing: !!(root.tab && root.tab.chooser)
    // Counted up when the places change (a saved search added while it is shown), so the current row is looked up again.
    property int placesRevision: 0
    readonly property int currentRow: root.tab && root.placesRevision >= 0 ? root.places.rowForUrl(root.tab.url) : -1

    // The last drop at a gap this sidebar sent (FilesApp.addToSidebar's token): a fallback answer for another window's sidebar
    // is not this one's.
    property int dropSerial: 0
    property string dropToken: ""

    Connections {
        target: root.app
        ignoreUnknownSignals: true
        function onSidebarDropFallback(token: string, urls: var, destination: url): void {
            if (token === "" || token !== root.dropToken || !root.tab)
                return;
            root.dropToken = "";
            root.tab.dropUrls(urls, destination, null);
        }
    }

    Connections {
        target: root.places
        function onModelReset(): void {
            root.placesRevision += 1;
        }
        function onRowsInserted(): void {
            root.placesRevision += 1;
        }
        function onRowsRemoved(): void {
            root.placesRevision += 1;
        }
    }
    property int keyRow: -1
    // Space kept free at the top for the window lights (the toolbar drawn over it, ADR-0015).
    property real topInset: 0

    // Favorites editing. The insertion gap a drag is over, 0..places.pinnedCount (before the user's folder of that position
    // in their list, the last one after them all), -1 for none: a drop there adds the dragged folders (or moves the dragged
    // place) to that position.
    property int insertGap: -1
    readonly property bool editable: !root.choosing && root.tab !== null
    // The private drag key of a sidebar place being moved (Drag.Internal: it never leaves the window).
    readonly property string placeKey: "application/x-grassfield-sidebar-place"

    // The gap of a drag at `y` over a Favorites row `height` tall: its top or bottom quarter is a gap, the rest of the row a
    // drop into it. A standard place's edges all mean "before the user's folders" (gap 0), a saved search's "after them".
    function gapFor(kind: string, section: string, index: int, y: real, height: real, placeOnly: bool): int {
        if (!root.editable || section !== "favorites")
            return -1;
        const top = y < height / 4;
        const bottom = y > height - height / 4;
        if (!top && !bottom && !placeOnly)
            return -1;
        if (kind === "pinned")
            return index - root.places.firstPinnedRow + (bottom || (!top && y >= height / 2) ? 1 : 0);
        if (kind === "savedSearch")
            return root.places.pinnedCount;
        return 0;
    }

    // Where the insertion line of `gap` is drawn: under the row just before the gap (the last standard place for gap 0),
    // in the list's content coordinates; -1 when that row is not made (scrolled away).
    function gapY(gap: int): real {
        const above = list.itemAtIndex(root.places.firstPinnedRow + gap - 1);
        return above ? above.y + above.height : -1;
    }

    // A Favorites folder place's menu (a folder of the user's own, a standard folder, Applications): Open in New Tab and
    // Remove from Sidebar (Files keeps removed standard places hidden; Add to Sidebar of that folder lists it again).
    function openPlaceMenu(entry: PlaceRow, x: real, y: real, keyboard: bool): void {
        if (!root.editable || !entry.removable)
            return;
        root.tab.win.menuLayer.open([{id: "newTab", text: qsTr("Open in New Tab")}, {separator: true},
                                     {id: "unlist", text: qsTr("Remove from Sidebar")}], x, y, id => {
            if (id === "newTab")
                root.tab.win.newTab(entry.url, null);
            else if (id === "unlist")
                root.app.removeFromSidebar(entry.url);
        }, list, keyboard);
    }

    // A place of the user's own being dragged (to another position in Favorites, or out of the sidebar to remove it).
    Item {
        id: placeDrag
        property url url
        property string name
        visible: Drag.active
        z: 20
        width: list.width
        height: Tokens.filesSidebarItemHeight
        Drag.dragType: Drag.Internal
        Drag.keys: [root.placeKey]
        Drag.supportedActions: Qt.MoveAction
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2
        opacity: Tokens.filesHiddenOpacity

        Rectangle {
            anchors.fill: parent
            radius: Tokens.filesSidebarItemRadius
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.filesSidebarSelectionOpacity)
        }

        Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            x: Tokens.spacingSm
            width: parent.width - 2 * Tokens.spacingSm
            text: DisplayName.text(placeDrag.name)
            elide: Text.ElideRight
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }
    }

    // Eject (macOS File > Eject, Cmd+E here Ctrl+E, and Eject in the sidebar item's context menu): the volume of the row the
    // keyboard is on while the sidebar has the focus, else the one whose folder is shown; -1 when that is not an ejectable,
    // idle volume. The toolbar buttons are out of the Tab chain, so this is the keyboard path to the eject button.
    property int ejectRow: -1

    function updateEject(): void {
        const row = list.activeFocus ? root.keyRow : root.currentRow;
        const item = row >= 0 ? list.itemAtIndex(row) as PlaceRow : null;
        root.ejectRow = item && item.ejectable && !item.busy ? row : -1;
    }

    // Unmounts (and ejects) the volume of ejectRow; false when there is none.
    function eject(): bool {
        if (root.ejectRow < 0)
            return false;
        root.places.eject(root.ejectRow);
        return true;
    }

    Component.onCompleted: Qt.callLater(root.updateEject)
    onCurrentRowChanged: Qt.callLater(root.updateEject)
    onKeyRowChanged: Qt.callLater(root.updateEject)

    Accessible.role: Accessible.List
    Accessible.name: qsTr("Sidebar")

    function openRow(row: int, url: url, mounted: bool): void {
        if (!root.tab)
            return;
        if (!mounted)
            root.places.mount(row);
        else
            root.tab.navigate(url, true);
    }

    // A place or a tag row (a tag lists its items in the shown folder and below).
    function openEntry(entry: PlaceRow): void {
        if (entry.kind === "tag") {
            if (root.tab)
                root.tab.showTag(entry.tag);
        } else {
            root.openRow(entry.index, entry.url, entry.mounted);
        }
    }

    // The Tags section's context menu (on a tag or on the header): Remove from Sidebar (a tag only) and, while some tags
    // are removed, Show Hidden Tag > the tags to list again (the way back; the files keep their tags either way).
    function openTagMenu(tag: string, x: real, y: real): void {
        if (!root.tab || root.choosing)
            return;
        const items = [];
        if (tag !== "")
            items.push({id: "forget", text: qsTr("Remove from Sidebar")});
        const hidden = root.app.hiddenTags;
        if (hidden.length > 0) {
            if (items.length > 0)
                items.push({separator: true});
            items.push({id: "showHidden", text: qsTr("Show Hidden Tag"), submenu: hidden.map(t => ({id: "show:" + t, text: root.app.tagName(t)}))});
        }
        if (items.length === 0)
            return;
        root.tab.win.menuLayer.open(items, x, y, id => {
            if (id === "forget")
                root.app.forgetTag(tag);
            else if (id.startsWith("show:"))
                root.app.showTag(id.substring(5));
        }, list, false);
    }

    Connections {
        target: root.places
        function onModelReset(): void {
            Qt.callLater(root.updateEject);
        }
        function onDataChanged(): void {
            Qt.callLater(root.updateEject);
        }
        function onRowsInserted(): void {
            Qt.callLater(root.updateEject);
        }
        function onRowsRemoved(): void {
            Qt.callLater(root.updateEject);
        }
        function onMounted(url: url): void {
            if (root.tab)
                root.tab.navigate(url, true);
        }
    }

    // The window is key (the toolbar's own test); an inactive window greys the sidebar's selection icon (macOS).
    readonly property bool keyLook: Appearance.looksKey(root.Window.window, root.Window.active)

    // The floating panel (macOS 26; ADR-0024 amendment 2026-11-03): inset from the window's left, top and bottom edges, the
    // content straight beside it. The rows keep window coordinates, so the lights (drawn over the panel) sit at the macOS position.
    SidebarPanel {
        id: panel
        anchors {
            fill: parent
            leftMargin: Tokens.windowSidebarPanelInset
            topMargin: Tokens.windowSidebarPanelInset
            bottomMargin: Tokens.windowSidebarPanelInset
        }
    }

    ListView {
        id: list
        anchors.fill: parent
        anchors.topMargin: Math.max(root.topInset, Tokens.windowSidebarPanelInset) + Tokens.spacingSm
        anchors.leftMargin: Tokens.windowSidebarPanelInset + Tokens.filesSidebarInset
        anchors.rightMargin: Tokens.filesSidebarInset
        anchors.bottomMargin: Tokens.windowSidebarPanelInset
        model: root.places
        clip: true
        focus: true
        activeFocusOnTab: true
        keyNavigationEnabled: false
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Sidebar")

        onCountChanged: Qt.callLater(root.updateEject)

        onActiveFocusChanged: {
            if (activeFocus && root.keyRow < 0)
                root.keyRow = Math.max(0, root.currentRow);
            Qt.callLater(root.updateEject);
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Down) {
                root.keyRow = Math.min(list.count - 1, root.keyRow + 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                root.keyRow = Math.max(0, root.keyRow - 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                const item = list.itemAtIndex(root.keyRow) as PlaceRow;
                if (item)
                    root.openEntry(item);
                event.accepted = true;
            } else if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
                // The keyboard's way to a place's menu (Remove from Sidebar, Eject, a tag's).
                const item = list.itemAtIndex(root.keyRow) as PlaceRow;
                if (item) {
                    const p = item.mapToItem(null, item.width / 2, item.height / 2);
                    item.openMenu(p.x, p.y, true);
                }
                event.accepted = true;
            }
        }

        section.property: "section"
        section.delegate: Item {
            id: header
            required property string section
            width: ListView.view.width
            // Recents has no heading.
            height: header.section === "recents" ? 0 : Tokens.filesSidebarHeaderHeight
            visible: header.section !== "recents"
            // The Tags header has a menu (Show Hidden Tag) that a right click opens: the same menu through an accessible
            // action (A11Y-09). The other headers are plain headings.
            Accessible.role: header.section === "tags" && !root.choosing ? Accessible.Button : Accessible.Heading
            Accessible.name: header.section === "favorites" ? qsTr("Favorites") : header.section === "tags" ? (root.choosing ? qsTr("Tags") : qsTr("Tags menu")) : qsTr("Locations")
            Accessible.onPressAction: {
                if (header.section === "tags") {
                    const p = header.mapToItem(null, header.width / 2, header.height / 2);
                    root.openTagMenu("", p.x, p.y);
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                enabled: header.section === "tags" && !root.choosing
                onClicked: event => {
                    const p = mapToItem(null, event.x, event.y);
                    root.openTagMenu("", p.x, p.y);
                }
            }

            Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Tokens.spacingSm
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Tokens.spacingXs
                text: header.section === "favorites" ? qsTr("Favorites") : header.section === "tags" ? qsTr("Tags") : qsTr("Locations")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                font.weight: Tokens.typographyMenuBoldWeight
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }
        }

        delegate: PlaceRow {}

        // The insertion line of a drag over Favorites (the Finder's: in the accent colour, where the folders will go).
        Rectangle {
            parent: list.contentItem
            z: 5
            readonly property real lineY: root.insertGap >= 0 ? root.gapY(root.insertGap) : -1
            visible: lineY >= 0
            x: Tokens.spacingXs
            width: list.width - 2 * Tokens.spacingXs
            height: Tokens.filesDropBorder
            radius: height / 2
            y: lineY - height / 2
            color: Appearance.colors.accent
        }
    }

    component PlaceRow: Item {
        id: entry

        required property int index
        required property string section
        required property string name
        required property url url
        required property string iconName
        required property string kind
        required property bool mounted
        required property bool ejectable
        required property bool busy
        required property string tag
        required property int tagColor
        // A standard folder whose disk does not answer (PlacesModel): listed, dimmed, as the Finder shows a server that went
        // away.
        required property bool unavailable

        readonly property bool current: entry.index === root.currentRow
        readonly property bool keyed: list.activeFocus && entry.index === root.keyRow
        readonly property bool isTag: entry.kind === "tag"
        // A folder of the user's own in Favorites (added with Add to Sidebar or a drag): it moves and drags out.
        readonly property bool pinned: entry.kind === "pinned"
        // A Favorites place that Remove from Sidebar takes away (a folder of the user's own, a standard folder, Applications).
        readonly property bool removable: entry.section === "favorites" && (entry.pinned || entry.kind === "folder" || entry.kind === "applications")
        // The place takes a drop into it (the items move or copy there; a tag tags them).
        readonly property bool takesItems: entry.mounted && entry.kind !== "network" && entry.kind !== "recents" && entry.kind !== "savedSearch" && !(entry.isTag && root.choosing)

        // The row's menu at window coordinates (a right click, the Menu key).
        function openMenu(x: real, y: real, keyboard: bool): void {
            if (entry.isTag) {
                root.openTagMenu(entry.tag, x, y);
            } else if (entry.kind === "savedSearch" && !root.choosing) {
                // A saved search (Place.tag holds its file): Remove from Sidebar keeps it; Move to Trash puts its file in the Trash.
                root.tab.win.menuLayer.open([{id: "open", text: qsTr("Open")}, {separator: true},
                                             {id: "unlist", text: qsTr("Remove from Sidebar")},
                                             {id: "delete", text: qsTr("Move to Trash")}], x, y, id => {
                    if (id === "open")
                        root.openEntry(entry);
                    else if (id === "unlist")
                        root.app.setSavedSearchInSidebar(entry.tag, false);
                    else if (id === "delete")
                        root.app.removeSavedSearch(entry.tag);
                }, list, keyboard);
            } else if (entry.ejectable && !entry.busy) {
                // A removable volume: Eject (the same action as the button on the row).
                root.tab.win.menuLayer.open([{id: "eject", text: qsTr("Eject")}], x, y, id => {
                    if (id === "eject")
                        root.places.eject(entry.index);
                }, list, keyboard);
            } else if (entry.removable) {
                root.openPlaceMenu(entry, x, y, keyboard);
            }
        }

        width: ListView.view.width
        height: Tokens.filesSidebarItemHeight
        opacity: entry.unavailable ? Tokens.materialDisabledOpacity : 1
        Accessible.role: Accessible.ListItem
        Accessible.name: DisplayName.text(entry.name)
        Accessible.selectable: true
        Accessible.selected: entry.current
        Accessible.onPressAction: root.openEntry(entry)

        // The current place: a neutral fill under a bold label (macOS 27 Finder), not the accent.
        Rectangle {
            anchors.fill: parent
            radius: Tokens.filesSidebarItemRadius
            color: entry.current ? Appearance.withAlpha(Appearance.colors.fill, Tokens.filesSidebarSelectionOpacity)
                 : mouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
            border.width: entry.keyed || drop.containsDrag ? Tokens.controlFocusOutline : 0
            border.color: Appearance.focusRingColor
        }

        ThemeIcon {
            id: glyph
            visible: !entry.isTag
            x: Tokens.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            name: entry.iconName
            size: Tokens.filesSidebarIconSize
            // Monochrome in the text colour; the accent only on the selected row of a key window (macOS).
            color: entry.current && root.keyLook ? Appearance.colors.accentInk : Appearance.colors.text
        }

        // A tag: its colour dot, or a hollow ring for a tag without a colour (from another application).
        Rectangle {
            visible: entry.isTag
            anchors.centerIn: glyph
            width: Tokens.filesTagDotSize + Tokens.spacingXs
            height: width
            radius: width / 2
            color: entry.tagColor >= 0 ? TagColors.at(Tokens, entry.tagColor) : "transparent"
            border.width: entry.tagColor >= 0 ? 0 : Tokens.appsBorderWidth * 2
            border.color: Appearance.windowSecondary
        }

        Text {
            textFormat: Text.PlainText
            anchors.left: glyph.right
            anchors.leftMargin: Tokens.spacingSm
            anchors.right: eject.visible ? eject.left : parent.right
            anchors.rightMargin: Tokens.spacingXs
            anchors.verticalCenter: parent.verticalCenter
            text: DisplayName.text(entry.name)
            elide: Text.ElideRight
            color: entry.mounted ? Appearance.colors.text : Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographyMenuWeight
        }

        ToolButton {
            id: eject
            visible: entry.ejectable
            enabled: !entry.busy
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Tokens.filesSidebarItemHeight
            height: Tokens.filesSidebarItemHeight
            accessibleName: qsTr("Eject %1").arg(DisplayName.text(entry.name))
            onClicked: root.places.eject(entry.index)

            ThemeIcon {
                anchors.centerIn: parent
                name: "media-eject-symbolic"
                size: Tokens.filesSidebarEjectSize
                tint: true
            }
        }

        DropArea {
            id: drop
            anchors.fill: parent
            // Network and Recents take no drop (Recents is a list, not a place: Finder; it does not spring open either), nor a
            // tag in a panel, nor a saved search (a list of items from several folders). Every Favorites row takes a drag at
            // its edges, the gaps where folders are added (and a place of the user's own is moved).
            enabled: entry.takesItems || (root.editable && entry.section === "favorites")
            keys: ["text/uri-list", root.placeKey]
            // Into the row (spring-loaded open, a drop moves or copies the items there) or at a gap (the insertion line).
            property bool into: false

            function track(event: var): void {
                const placeOnly = event.keys.indexOf(root.placeKey) >= 0;
                const gap = root.gapFor(entry.kind, entry.section, entry.index, event.y, entry.height, placeOnly);
                root.insertGap = gap;
                const into = gap < 0 && entry.takesItems && !placeOnly;
                if (into === drop.into)
                    return;
                drop.into = into;
                // A place rested on during a drag opens in the tab (spring-loaded); a tag does not.
                if (into && root.tab && !entry.isTag)
                    root.tab.springHover(entry.url);
                else if (!into && root.tab)
                    root.tab.springLeave(entry.url);
            }

            onEntered: event => drop.track(event)
            onPositionChanged: event => drop.track(event)
            onExited: {
                root.insertGap = -1;
                if (drop.into && root.tab)
                    root.tab.springLeave(entry.url);
                drop.into = false;
            }
            onDropped: event => {
                if (event.keys.indexOf(root.placeKey) >= 0) {
                    // A place of the user's own moved to another position in Favorites.
                    const gap = root.insertGap;
                    root.insertGap = -1;
                    if (gap >= 0 && root.tab) {
                        root.app.moveInSidebar(placeDrag.url, gap);
                        // Copy, as every drop of Files answers (tst_filestabs): the place's own drag only asks whether it
                        // was taken, nothing moves on disk.
                        event.accept(Qt.CopyAction);
                    }
                    return;
                }
                if (event.hasUrls && entry.dropItems(event.urls))
                    event.accept(Qt.CopyAction);
            }
        }

        // Items dropped on the row where the drag was last tracked: at a gap they join Favorites there (FilesApp keeps the
        // folders among them), in the middle they go into the place (moved or copied; a tag tags them). False: not taken.
        function dropItems(urls: var): bool {
            const gap = root.insertGap;
            const into = drop.into;
            root.insertGap = -1;
            drop.into = false;
            if (!root.tab)
                return false;
            if (gap >= 0) {
                // Folders join Favorites at the line; items with no folder among them go into this place instead, when it
                // takes items (FilesApp answers with sidebarDropFallback: integrator review, L4).
                root.dropSerial += 1;
                root.dropToken = "sidebar-" + root.dropSerial + "-" + Date.now();
                root.app.addToSidebar(urls, gap, entry.takesItems && !entry.isTag ? entry.url : "", root.dropToken);
                return true;
            }
            if (!into)
                return false;
            // A drop on a tag tags the items (local files only; FilesApp reports the others).
            if (entry.isTag)
                root.app.addTag(urls, entry.tag);
            else
                root.tab.dropUrls(urls, entry.url, null);
            return true;
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            anchors.rightMargin: eject.visible ? eject.width : 0
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            // A folder of the user's own drags (to another position, or out of the sidebar: removed, as in the Finder).
            // The list would take an up or down drag for its own scroll.
            preventStealing: entry.pinned && root.editable
            // Where the press was (the sidebar's coordinates) and whether it became a drag (then it is no click).
            property point pressAt
            property bool dragged: false
            onPressed: event => {
                mouse.dragged = false;
                mouse.pressAt = mouse.mapToItem(root, event.x, event.y);
            }
            // The dragged place follows the pointer once it has moved past the drag threshold (the drag's hot spot is the
            // pointer, so the row under it is where it goes).
            onPositionChanged: event => {
                if (!mouse.pressed || !(mouse.pressedButtons & Qt.LeftButton) || !entry.pinned || !root.editable)
                    return;
                const p = mouse.mapToItem(root, event.x, event.y);
                if (!placeDrag.Drag.active) {
                    if (Math.abs(p.x - mouse.pressAt.x) + Math.abs(p.y - mouse.pressAt.y) < Tokens.filesDragThreshold)
                        return;
                    placeDrag.url = entry.url;
                    placeDrag.name = entry.name;
                    mouse.dragged = true;
                    placeDrag.x = p.x - placeDrag.width / 2;
                    placeDrag.y = p.y - placeDrag.height / 2;
                    placeDrag.Drag.active = true;
                    return;
                }
                placeDrag.x = p.x - placeDrag.width / 2;
                placeDrag.y = p.y - placeDrag.height / 2;
            }
            onReleased: event => {
                if (!placeDrag.Drag.active)
                    return;
                const action = placeDrag.Drag.drop();
                placeDrag.Drag.active = false;
                root.insertGap = -1;
                // Released out of the sidebar: the folder leaves Favorites (the folder itself stays where it is).
                const p = mouse.mapToItem(root, event.x, event.y);
                if (action === Qt.IgnoreAction && (p.x < 0 || p.y < 0 || p.x > root.width || p.y > root.height))
                    root.app.removeFromSidebar(placeDrag.url);
            }
            onCanceled: {
                placeDrag.Drag.active = false;
                root.insertGap = -1;
            }
            onClicked: event => {
                if (mouse.dragged) {
                    mouse.dragged = false;
                    return;
                }
                root.keyRow = entry.index;
                if (event.button === Qt.RightButton) {
                    const p = mouse.mapToItem(null, event.x, event.y);
                    entry.openMenu(p.x, p.y, false);
                    return;
                }
                root.openEntry(entry);
            }
        }
    }
}
