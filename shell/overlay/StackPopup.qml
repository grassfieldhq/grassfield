pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.dock
import qs.services
import "../dock/Stacks.js" as Stacks

// A folder stack of the Dock opened (macOS: click on Downloads): the folder's items as a Fan, a Grid or a List, sorted as the
// stack's options say, and "Open in Files". Payload (Popups.data): path, name, sort, view. Spec: docs/specs/dock.md requirement 25.
//
// Fan: the items rise from the tile along a curve, each with its name beside it, no panel (and no blur region: nothing is
// behind it but the icons). Grid and List: a rounded panel on the frosted material with a tail pointing at the tile (the host
// supplies the blur region). Keyboard: arrows move, Return opens, Esc closes. Items open through the open policy (gio open).
FocusScope {
    id: root

    readonly property var info: Popups.data
    // Folders opened in place (Grid and List: macOS opens a sub-folder inside the stack with a back control): the path of each.
    property var trail: []
    // The name shown for each folder of the trail (a folder whose name is not UTF-8 is entered by its file: URI, F22).
    property var trailNames: []
    readonly property bool nested: trail.length > 0
    readonly property string folderPath: nested ? trail[trail.length - 1] : (info.path ? info.path : "")
    property var entries: []
    property bool loaded: false
    // Index of the item under the keyboard or pointer; entries.length is the "Open in Files" row. -1: none.
    property int currentIndex: -1

    // A sub-folder never opens as a Fan (the back control lives in the panel).
    readonly property string view: {
        const v = Stacks.resolveView(info.view, entries.length, Tokens.dockStackFanMax);
        return nested && v === "fan" ? "grid" : v;
    }
    readonly property bool fan: view === "fan"
    readonly property string align: Popups.align
    readonly property bool vertical: align === "rightOf" || align === "leftOf"

    // Fan: the number of items drawn and the "Open in Files" icon after them.
    readonly property int fanCount: Stacks.fanItems(entries.length, Tokens.dockStackFanMax)
    readonly property int rowCount: view === "list" ? Math.min(entries.length, Tokens.dockStackListMaxRows) : 0
    readonly property int columns: Stacks.gridColumns(entries.length, Tokens.dockStackGridMaxColumns)
    readonly property int gridRows: Math.max(1, Math.min(Tokens.dockStackGridMaxRows, Math.ceil(entries.length / columns)))
    readonly property real iconSize: Tokens.dockStackIconSize
    readonly property string openText: entries.length > fanCount && fan ? qsTr("%1 more in Files").arg(entries.length - fanCount) : qsTr("Open in Files")
    readonly property real labelMax: Tokens.dockStackListWidth
    readonly property var fanSlots: Stacks.fanLayout(fanCount + 1, Tokens.dockStackFanStep, Tokens.dockStackFanBend)

    // Panel (grid, list) size.
    readonly property real panelPad: Tokens.menuPadding + Tokens.spacingXs
    readonly property real footerHeight: Tokens.menuItemHeight + Tokens.spacingXs
    // The back row of a sub-folder, above the items.
    readonly property real headerHeight: nested && !fan ? Tokens.menuItemHeight + Tokens.spacingXs : 0

    activeFocusOnTab: true
    focus: true
    Accessible.role: Accessible.PopupMenu
    Accessible.name: qsTr("%1 stack").arg(DisplayName.text(info.name ? info.name : Stacks.baseName(folderPath)))

    width: {
        if (fan) {
            const side = Math.max(labelMax + Tokens.spacingSm + iconSize / 2, Tokens.dockStackFanBend + iconSize / 2);
            return vertical ? Tokens.dockStackFanStep * fanCount + iconSize + Tokens.spacingSm + labelMax : 2 * side;
        }
        return view === "list" ? Tokens.dockStackListWidth : columns * Tokens.dockStackCellWidth + 2 * panelPad;
    }
    height: {
        if (fan)
            return vertical ? 2 * (Tokens.dockStackFanBend + iconSize / 2) : Tokens.dockStackFanStep * fanCount + iconSize + Tokens.dockMenuTailGap;
        // A list is a menu (ADR-0039 step 8): its rows, then a separator band and the Open in Files row, nothing in between.
        if (view === "list")
            return rowCount * Tokens.menuItemHeight + headerHeight + Tokens.menuSeparatorHeight + Tokens.menuItemHeight + 2 * Tokens.menuPadding;
        return gridRows * Tokens.dockStackCellHeight + footerHeight + headerHeight + 2 * panelPad;
    }

    // Lists `path` (a folder opened in place, or back to the one above).
    function reload(): void {
        entries = [];
        loaded = false;
        currentIndex = -1;
    }

    function enter(path: string, name: string): void {
        trail = trail.concat([path]);
        trailNames = trailNames.concat([name !== "" ? name : Stacks.baseName(path)]);
        reload();
    }

    function back(): void {
        if (!nested)
            return;
        trail = trail.slice(0, -1);
        trailNames = trailNames.slice(0, -1);
        reload();
    }

    function open(index: int): void {
        const e = index >= 0 && index < entries.length ? entries[index] : null;
        // A folder in a Grid or a List opens in place; in a Fan (and "Open in Files") it opens in Files.
        // A name that is not UTF-8 (shown with U+FFFD) is entered and opened by its file: URI, which keeps its bytes (the stack
        // helper and gio decode it, F22).
        if (e && e.isDir && (view === "grid" || view === "list")) {
            // (inside a folder entered by its URI, every entry goes on by its URI)
            const byUri = e.uri && (e.path.indexOf("\ufffd") >= 0 || e.path.startsWith("file://"));
            enter(byUri ? e.uri : e.path, e.name ?? "");
            return;
        }
        const target = e ? (e.uri || e.path) : folderPath;
        Popups.close();
        if (target !== "")
            Apps.openDetached(["gio", "open", target]);
    }

    // The keyboard cursor stays in view (the Grid is virtualized: the cell may not exist yet).
    onCurrentIndexChanged: {
        if (currentIndex >= 0 && currentIndex < entries.length) {
            if (view === "grid")
                gridView.positionViewAtIndex(currentIndex, GridView.Contain);
            else if (view === "list")
                listView.positionViewAtIndex(currentIndex, ListView.Contain);
        }
    }

    function move(key: string): void {
        // The "Open in Files" row counts as one more item at the end.
        const count = entries.length + 1;
        const cols = view === "grid" ? columns : 1;
        currentIndex = Stacks.step(currentIndex, count, fan ? 1 : cols, key);
    }

    Keys.onEscapePressed: Popups.close()
    Keys.onUpPressed: move(fan ? "down" : "up")
    Keys.onDownPressed: move(fan ? "up" : "down")
    // Left in a List and Backspace go back out of a sub-folder (macOS closes the submenu).
    Keys.onLeftPressed: {
        if (nested && view === "list")
            back();
        else
            move("left");
    }
    Keys.onRightPressed: move("right")
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Backspace) {
            back();
            event.accepted = true;
        } else if (event.key === Qt.Key_Home) {
            move("home");
            event.accepted = true;
        } else if (event.key === Qt.Key_End) {
            move("end");
            event.accepted = true;
        }
    }
    Keys.onReturnPressed: open(currentIndex)
    Keys.onEnterPressed: open(currentIndex)
    Keys.onSpacePressed: open(currentIndex)

    // The folder's first Tokens.dockStackItemMax entries in the stack's order, from the native helper (ADR-0025, shell/dock/StackHelper.qml):
    // a new window whenever the folder changes while the popup is open. Another folder (in place, back) restarts the helper.
    StackHelper {
        id: lister
        folder: root.folderPath
        sort: root.info.sort ? root.info.sort : "dateAdded"
        limit: Tokens.dockStackItemMax
        low: Math.round(Tokens.dockStackItemMax * 2 / 3)
        onArrived: {
            if (!loaded)
                return;
            root.entries = entries;
            if (!root.loaded) {
                root.loaded = true;
                reveal.restart();
            }
        }
    }

    // The fan springs out of the tile; the other views fade in with the host. Under Reduce Motion the fan's items stand at
    // their places and only fade in (ADR-0039 step 5).
    property real progress: 0
    readonly property real spread: Appearance.reduceMotion ? 1 : progress

    // The popup's keyboard focus, for the current cell's ring (a press on the popup hands it to the pointer, and so does a
    // click that opened it: Popups.openedByPointer, step 8).
    KeyFocus {
        id: gridFocus
        pointer: Popups.openedByPointer
    }

    NumberAnimation {
        id: reveal
        target: root
        property: "progress"
        from: 0
        to: 1
        duration: Appearance.duration(Tokens.motionNormal)
        // Arriving: the enter curve (ADR-0039 step 20).
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Appearance.curveEnter
    }

    // What the open stack shows is published for the test hooks (IPC target dockstack, which lives in Popups: a handler inside
    // this popup would not exist while it is closed), and the hooks' commands arrive as a signal.
    Binding {
        target: Popups
        property: "stackView"
        value: root.view
    }

    Binding {
        target: Popups
        property: "stackNames"
        value: root.entries.map(e => e.name)
    }

    Binding {
        target: Popups
        property: "stackDepth"
        value: root.trail.length
    }

    Connections {
        target: Popups

        function onStackCommand(command: string, argument: string): void {
            if (command === "back") {
                root.back();
            } else if (command === "enter" && !root.fan) {
                const at = root.entries.findIndex(e => e.name === argument && e.isDir);
                if (at >= 0)
                    root.open(at);
            }
        }
    }

    // ---- Fan ----

    Item {
        id: fanItem
        anchors.fill: parent
        visible: root.fan

        Repeater {
            model: root.fan ? root.fanCount + 1 : 0

            delegate: Item {
                id: slot

                required property int index
                readonly property bool isOpen: index === root.fanCount
                readonly property var entry: isOpen ? null : root.entries[index]
                readonly property var at: root.fanSlots[index] ? root.fanSlots[index] : ({out: 0, side: 0})
                readonly property real out: at.out * root.spread
                readonly property real side: at.side * root.spread
                readonly property bool current: root.currentIndex === (isOpen ? root.entries.length : index)
                // Centre of the icon in the fan's box.
                readonly property real cx: root.align === "above" ? root.width / 2 + side : (root.align === "rightOf" ? root.iconSize / 2 + out : root.width - root.iconSize / 2 - out)
                readonly property real cy: root.align === "above" ? root.height - root.iconSize / 2 - out : root.height / 2 - side
                // Names go on the side away from the bend: left of the icons of a bottom or right Dock, right of those of a left one.
                readonly property bool labelRight: root.align === "rightOf"

                x: cx - root.iconSize / 2
                y: cy - root.iconSize / 2
                width: root.iconSize
                height: root.iconSize
                opacity: root.progress
                Accessible.role: Accessible.Button
                Accessible.name: isOpen ? root.openText : entry ? DisplayName.text(entry.name) : ""
                Accessible.onPressAction: root.open(isOpen ? -1 : index)

                StackIcon {
                    visible: !slot.isOpen
                    anchors.fill: parent
                    path: slot.entry ? slot.entry.path : ""
                    isDir: slot.entry ? slot.entry.isDir : false
                    size: root.iconSize
                }

                TintedIcon {
                    visible: slot.isOpen
                    anchors.fill: parent
                    size: root.iconSize
                    source: slot.isOpen ? Quickshell.iconPath("folder", "") : ""
                    asynchronous: true
                }

                Rectangle {
                    visible: slot.current
                    anchors.fill: parent
                    anchors.margins: -Tokens.spacingXs
                    radius: Tokens.radiusControl
                    color: "transparent"
                    border.width: Tokens.controlFocusOutline
                    border.color: Appearance.focusRingColor
                }

                Tooltip {
                    shown: root.fan && root.progress > 0
                    delay: 0
                    text: slot.isOpen ? root.openText : (slot.entry ? DisplayName.text(slot.entry.name) : "")
                    x: slot.labelRight ? slot.width + Tokens.spacingSm : -width - Tokens.spacingSm
                    y: (slot.height - height) / 2
                    width: Math.min(implicitWidth, root.labelMax)
                }

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Tokens.spacingXs
                    hoverEnabled: true
                    onEntered: root.currentIndex = slot.isOpen ? root.entries.length : slot.index
                    onClicked: root.open(slot.isOpen ? -1 : slot.index)
                }
            }
        }
    }

    // ---- Panel (Grid and List) ----

    Item {
        id: panelHost
        anchors.fill: parent
        visible: !root.fan
        opacity: root.loaded ? 1 : 0

        Material {
            id: panel
            glassClass: "menu"
            anchors.fill: parent
            radius: Tokens.radiusMenu
        }

        // Back row of a sub-folder opened in place: a chevron and the folder's name; a click goes back.
        Item {
            id: backRow
            visible: root.nested && !root.fan
            x: root.view === "list" ? Tokens.menuPadding : root.panelPad
            y: root.view === "list" ? Tokens.menuPadding : root.panelPad
            width: parent.width - 2 * x
            height: Tokens.menuItemHeight
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Back to %1").arg(root.nested && root.trail.length > 1 ? DisplayName.text(root.trailNames[root.trailNames.length - 2]) : DisplayName.text(root.info.name))
            Accessible.onPressAction: root.back()

            // A control: the control fill, the control hover over it (ADR-0039 step 12, G6); concentric with the panel's corner,
            // which it hugs (the corner less its inset, step 13, G5).
            Rectangle {
                anchors.fill: parent
                radius: Tokens.radiusMenu - backRow.x
                color: Appearance.buttonFill

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)
                    visible: backMouse.containsMouse
                }
            }

            Icon {
                id: backGlyph
                x: Tokens.menuItemPadding
                anchors.verticalCenter: parent.verticalCenter
                size: Tokens.menuIconSize
                name: "chevron-right"
                rotation: 180
            }

            Text {
                textFormat: Text.PlainText
                x: backGlyph.x + Tokens.menuIconSize + Tokens.spacingSm
                width: parent.width - x - Tokens.menuItemPadding
                anchors.verticalCenter: parent.verticalCenter
                text: root.nested ? DisplayName.text(root.trailNames[root.trailNames.length - 1] ?? "") : ""
                elide: Text.ElideMiddle
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyMenuSize
                font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                font.weight: Tokens.typographyMenuBoldWeight
            }

            MouseArea {
                id: backMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.back()
            }
        }

        // Grid: virtualized (a GridView creates the cells that are on screen, not up to Tokens.dockStackItemMax of them, each with
        // a preview to decode).
        GridView {
            id: gridView
            visible: root.view === "grid"
            x: root.panelPad
            y: root.panelPad + root.headerHeight
            width: root.columns * Tokens.dockStackCellWidth
            height: root.gridRows * Tokens.dockStackCellHeight
            cellWidth: Tokens.dockStackCellWidth
            cellHeight: Tokens.dockStackCellHeight
            model: root.view === "grid" ? root.entries : []
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: Tokens.dockStackCellHeight
            interactive: contentHeight > height

            delegate: Item {
                id: cell

                required property var modelData
                required property int index
                readonly property bool current: root.currentIndex === index

                width: Tokens.dockStackCellWidth
                height: Tokens.dockStackCellHeight
                Accessible.role: Accessible.Button
                Accessible.name: DisplayName.text(modelData.name)
                Accessible.onPressAction: root.open(index)

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: Tokens.spacingXs / 2
                    radius: Tokens.radiusControl
                    // The neutral selection of an item on glass (one role, ADR-0039 step 12, G6).
                    color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialSelectionOpacity)
                    visible: cell.current

                    // The current cell carries the shared ring while the keys move it (ADR-0039 step 7).
                    FocusRing {
                        visible: gridFocus.active
                    }
                }

                StackIcon {
                    x: (parent.width - width) / 2
                    y: Tokens.spacingSm
                    path: cell.modelData.path
                    isDir: cell.modelData.isDir
                    size: root.iconSize
                }

                FontMetrics {
                    id: labelMetrics
                    font: nameLabel.font
                }

                // Two lines at most, wrapped at words, the end cut in the middle of the second line (Stacks.labelLines): Qt's own
                // elide does not cut wrapped text, and would drop the extension.
                Text {
                    id: nameLabel
                    textFormat: Text.PlainText
                    x: Tokens.spacingXs
                    y: Tokens.spacingSm + root.iconSize + Tokens.spacingXs
                    width: parent.width - 2 * Tokens.spacingXs
                    text: Stacks.labelLines(DisplayName.text(cell.modelData.name), t => labelMetrics.advanceWidth(t) <= nameLabel.width, t => labelMetrics.elidedText(t, Qt.ElideMiddle, nameLabel.width))
                    maximumLineCount: 2
                    wrapMode: Text.NoWrap
                    horizontalAlignment: Text.AlignHCenter
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    font.letterSpacing: Appearance.tracking(Tokens.typographyCaptionSize)
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.currentIndex = cell.index
                    onClicked: root.open(cell.index)
                }
            }
        }

        // List
        ListView {
            id: listView
            visible: root.view === "list"
            x: Tokens.menuPadding
            y: Tokens.menuPadding + root.headerHeight
            width: parent.width - 2 * Tokens.menuPadding
            height: root.rowCount * Tokens.menuItemHeight
            model: root.view === "list" ? root.entries : []
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.currentIndex < root.entries.length ? root.currentIndex : -1
            highlightFollowsCurrentItem: false
            onCurrentIndexChanged: if (currentIndex >= 0)
                positionViewAtIndex(currentIndex, ListView.Contain)

            delegate: Item {
                id: row

                required property var modelData
                required property int index
                readonly property bool current: root.currentIndex === index

                width: ListView.view.width
                height: Tokens.menuItemHeight
                Accessible.role: Accessible.MenuItem
                Accessible.name: DisplayName.text(modelData.name)
                Accessible.onPressAction: root.open(index)

                Rectangle {
                    anchors.fill: parent
                    radius: Tokens.radiusMenu - Tokens.menuPadding
                    color: Appearance.colors.selection
                    visible: row.current
                }

                // A menu row's icon and label (MenuItem: the icon at the inset, the label after it and its gap; ADR-0039 step 8).
                StackIcon {
                    x: Tokens.menuItemPadding
                    anchors.verticalCenter: parent.verticalCenter
                    path: row.modelData.path
                    isDir: row.modelData.isDir
                    size: Tokens.menuIconSize
                }

                Text {
                    textFormat: Text.PlainText
                    x: Tokens.menuItemPadding + Tokens.menuIconSize + Tokens.spacingSm
                    width: parent.width - x - Tokens.menuItemPadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: DisplayName.text(row.modelData.name)
                    elide: Text.ElideMiddle
                    color: row.current ? Appearance.colors.selectionText : Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                    font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                    font.weight: Tokens.typographySmallWeight
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.currentIndex = row.index
                    onClicked: root.open(row.index)
                }
            }
        }

        // The footer: Open in Files (last row, after a separator).
        MenuSeparator {
            x: Tokens.menuPadding
            width: parent.width - 2 * Tokens.menuPadding
            // In a list, the menus' separator band right above the Open in Files row.
            y: root.view === "list" ? openRow.y - height : parent.height - root.footerHeight - root.panelPad - height / 2
        }

        Item {
            id: openRow
            readonly property bool current: root.currentIndex === root.entries.length
            x: root.view === "list" ? Tokens.menuPadding : root.panelPad
            width: parent.width - 2 * x
            height: Tokens.menuItemHeight
            y: parent.height - height - (root.view === "list" ? Tokens.menuPadding : root.panelPad)
            Accessible.role: Accessible.MenuItem
            Accessible.name: root.openText
            Accessible.onPressAction: root.open(-1)

            Rectangle {
                anchors.fill: parent
                // Concentric with the panel's corner, which it hugs (ADR-0039 step 13, G5).
                radius: Tokens.radiusMenu - openRow.x
                color: Appearance.colors.selection
                visible: openRow.current
            }

            Text {
                textFormat: Text.PlainText
                x: Tokens.menuItemPadding
                anchors.verticalCenter: parent.verticalCenter
                text: root.openText
                color: openRow.current ? Appearance.colors.selectionText : Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyMenuSize
                font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                font.weight: Tokens.typographySmallWeight
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.currentIndex = root.entries.length
                onClicked: root.open(-1)
            }
        }

        // Tail pointing at the tile (the same drawing as the Dock menu's).
        Shape {
            visible: root.align === "above"
            readonly property real hostX: Math.max(Tokens.panelPopupMargin, Math.min(root.Window.width - root.width - Tokens.panelPopupMargin, Popups.anchorX - root.width / 2))
            readonly property real tipX: Math.max(Tokens.radiusMenu + Tokens.dockMenuTailWidth / 2, Math.min(root.width - Tokens.radiusMenu - Tokens.dockMenuTailWidth / 2, Popups.anchorX - hostX))
            x: tipX - Tokens.dockMenuTailWidth / 2
            y: root.height - 1
            width: Tokens.dockMenuTailWidth
            height: Tokens.dockMenuTailHeight + 1
            preferredRendererType: Shape.CurveRenderer
            Accessible.ignored: true

            ShapePath {
                strokeWidth: 0
                fillColor: panel.fillColor // the panel's own glass (ADR-0039 step 22)
                startX: 0
                startY: 0
                PathLine {
                    x: Tokens.dockMenuTailWidth
                    y: 0
                }
                PathLine {
                    x: Tokens.dockMenuTailWidth / 2
                    y: Tokens.dockMenuTailHeight + 1
                }
                PathLine {
                    x: 0
                    y: 0
                }
            }
        }
    }

    Behavior on opacity {
        NumberAnimation {
            duration: Appearance.duration(Tokens.motionFast)
        }
    }
}
