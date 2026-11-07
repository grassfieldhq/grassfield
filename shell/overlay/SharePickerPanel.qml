pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services
import "../services/SharePicker.js" as Logic

// The screen-sharing picker (ADR-0035 D-6, steps 7a and 7b; spec system-dialogs.md SP6, SP7): an app asked to share the
// screen through the portal and the stand-in of xdph's picker asked the shell (SharePicker). Entire Screen shows each display,
// Window each window xdph listed, grouped by app (one that hides itself from capture greyed, never chosen: 7-11), both as live
// thumbnails; Selection an area dragged on a display's live preview (7-10). Nothing is selected at first: Share waits for a
// choice.
// Remember this choice (the portal's restore token) opens unticked (owner decision Q14) and the user may tick it; opening it
// as xdph's --allow-token says (ticked with Omarchy's xdph.conf, so a browser asks once) waits for the owner's agreement to the
// amendment (followAllowToken). Nothing answers keys or clicks until the panel is armed (7-8). The
// picker cannot name the app (xdph does not pass it). Keys: arrows move in the grid, Return shares,
// Esc cancels, Cmd-1, Cmd-2 and Cmd-3 (Super, forwarded as Ctrl) switch the tabs. Captures stop when the panel goes (the Overlay's
// Loader unloads it).
Dialog {
    id: root

    property string tab: "screen"
    // The chosen tile by what it stands for (SharePicker.js keyOf), never by its place: "" for none.
    property string chosen: ""
    // Set once, when the panel opens (the stand-in's options line comes before the list that opens it), then the user's.
    property bool remember: false
    // Owner decision Q14 ("unticked every time") stands until the owner agrees to its amendment (ADR-0035 D-6, proposed
    // 2026-11-07 after the rc6 report: open as xdph's --allow-token says, so a browser asks once). The stand-in passes
    // --allow-token and SharePicker keeps it; only this switch decides whether the box opens ticked.
    readonly property bool followAllowToken: false
    // False until Tokens.panelAlertArmMs after the panel showed, or after the last key pressed meanwhile (the access alert's
    // rule, AccessAlert.qml): keys typed for another window when it appears (Up then Return in a terminal) and clicks choose
    // and share nothing. Esc and Cancel always cancel.
    property bool armed: false
    readonly property var screens: Quickshell.screens
    readonly property var windows: Logic.ordered(SharePicker.windows, appId => Apps.nameFor(appId))
    readonly property var tiles: root.tab === "window" ? root.windows : root.screens
    readonly property int current: Logic.indexOfKey(root.tab, root.tiles, root.chosen)
    // The choice can be shared: a display that is there, a listed window that does not hide from capture, an area inside its
    // display (the service checks the same before it answers).
    readonly property bool hasChoice: Logic.selection(root.tab, root.chosen, false, root.screens.map(s => s.name), SharePicker.windows, SharePicker.sizes(), SharePicker.blockedKnown ? SharePicker.blocked : null) !== "" && (root.tab !== "region" || (regionView.area !== null && regionView.screen !== null && regionView.area.output === regionView.screen.name))
    // The display the Selection tab shows ("" for the first).
    property string regionOutput: ""
    readonly property int columns: Logic.columnsFor(grid.width, Tokens.panelSharePickerTileWidth, Tokens.spacingMd)

    function unarmed(): bool {
        if (root.armed)
            return false;
        arm.restart();
        return true;
    }

    function choose(index: int): void {
        root.chosen = index >= 0 && index < root.tiles.length ? Logic.keyOf(root.tab, root.tiles[index]) : "";
    }

    function shareCurrent(): void {
        if (!root.hasChoice || !root.armed)
            return;
        SharePicker.share(root.tab, root.chosen, root.remember);
    }

    function show(tab: string): void {
        root.tab = tab;
        root.chosen = "";
        if (tab === "region")
            regionView.forceActiveFocus();
        else
            grid.forceActiveFocus();
    }

    // The keys of the grid and of the Selection tab.
    function key(event: var): void {
        if (event.key !== Qt.Key_Escape && root.unarmed()) {
            event.accepted = true;
            return;
        }
        const cmd = (event.modifiers & Qt.ControlModifier) !== 0;
        const keys = {
            [Qt.Key_Left]: "left",
            [Qt.Key_Right]: "right",
            [Qt.Key_Up]: "up",
            [Qt.Key_Down]: "down"
        };
        if (cmd && event.key === Qt.Key_1)
            root.show("screen");
        else if (cmd && event.key === Qt.Key_2)
            root.show("window");
        else if (cmd && event.key === Qt.Key_3)
            root.show("region");
        else if (!cmd && root.tab !== "region" && keys[event.key] !== undefined)
            root.choose(Logic.moved(root.current, keys[event.key], root.tiles.length, root.columns));
        else if (!cmd && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter))
            root.shareCurrent();
        else
            return;
        event.accepted = true;
    }

    title: qsTr("Share Your Screen")
    message: qsTr("An app wants to share your screen. Choose what it can see.")
    sheet: true
    panelWidth: Tokens.panelSharePickerWidth

    onRejected: SharePicker.cancel()
    Component.onCompleted: root.remember = root.followAllowToken && SharePicker.allowToken

    Timer {
        id: arm
        interval: Tokens.panelAlertArmMs
        running: true
        onTriggered: root.armed = true
    }

    content: [
        SegmentedControl {
            width: parent.width
            fill: true
            accessibleName: qsTr("What to share")
            model: [
                {
                    id: "screen",
                    text: qsTr("Entire Screen")
                },
                {
                    id: "window",
                    text: qsTr("Window")
                },
                {
                    id: "region",
                    text: qsTr("Selection")
                }
            ]
            value: root.tab
            onPicked: id => {
                if (root.armed)
                    root.show(id);
            }
        },
        Rectangle {
            width: parent.width
            height: Tokens.panelSharePickerRows * grid.cellHeight + 2 * Tokens.spacingSm
            radius: Tokens.radiusControl
            color: Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity / 2) : Appearance.lightWellFill
            // One device pixel at every scale (UI audit 2026-11-05 U37).
            border.width: 1 / Math.max(1, Screen.devicePixelRatio)
            border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

            // The well keeps its hairline; the shared ring goes round it while the grid or the region has the keyboard
            // (ADR-0039 step 7, as Force Quit's list; the merge of #83 with #88, as #90 resolved it).
            KeyFocus {
                id: gridFocus
                target: grid
            }
            KeyFocus {
                id: regionFocus
                target: regionView
            }
            FocusRing {
                visible: gridFocus.active || regionFocus.active
            }

            GridView {
                id: grid

                visible: root.tab !== "region"
                anchors.fill: parent
                anchors.margins: Tokens.spacingSm
                clip: true
                focus: true
                activeFocusOnTab: true
                cellWidth: width / root.columns
                cellHeight: Tokens.panelSharePickerThumbHeight + Tokens.menuItemHeight + Tokens.spacingSm
                model: root.tiles
                currentIndex: root.current
                Accessible.role: Accessible.List
                Accessible.name: root.tab === "screen" ? qsTr("Displays") : qsTr("Windows")

                Keys.onPressed: event => root.key(event)

                delegate: Item {
                    id: tile

                    required property var modelData
                    required property int index
                    readonly property bool selected: root.current === tile.index
                    readonly property bool isScreen: root.tab !== "window"
                    // A window that hides itself from capture (no_screen_share): greyed, never shared (7-11).
                    readonly property bool blocked: !tile.isScreen && SharePicker.blocked.indexOf(tile.modelData.handle) >= 0
                    readonly property var entry: tile.isScreen ? null : Apps.lookup(tile.modelData.appId)
                    readonly property var source: tile.isScreen ? tile.modelData : (tile.modelData.address !== "" ? Compositor.toplevelByAddress(tile.modelData.address) : null)
                    readonly property string label: tile.isScreen ? tile.modelData.name : (tile.modelData.title !== "" ? tile.modelData.title : Apps.nameFor(tile.modelData.appId))

                    width: grid.cellWidth
                    height: grid.cellHeight
                    Accessible.role: Accessible.ListItem
                    Accessible.name: tile.isScreen ? tile.label : (tile.blocked ? qsTr("%1, %2, can't be shared").arg(Apps.nameFor(tile.modelData.appId)).arg(tile.label) : qsTr("%1, %2").arg(Apps.nameFor(tile.modelData.appId)).arg(tile.label))
                    Accessible.selected: tile.selected
                    Accessible.onPressAction: root.choose(tile.index)

                    Item {
                        id: thumb

                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Tokens.panelSharePickerTileWidth
                        height: Tokens.panelSharePickerThumbHeight
                        opacity: tile.blocked ? Tokens.materialDisabledOpacity : 1

                        // The selected tile: the selection colour around it, as a list's selected row.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -Tokens.controlFocusOutline
                            radius: Tokens.radiusControl + Tokens.controlFocusOutline
                            color: "transparent"
                            border.width: Tokens.controlFocusOutline
                            border.color: Appearance.colors.selection
                            visible: tile.selected
                        }

                        // The display or the window fitted in its box with its own aspect, live. No source (xdph had no
                        // address for the window, or the shell does not know it): the app's icon instead.
                        ScreencopyView {
                            id: view

                            readonly property real ratio: implicitWidth > 0 && implicitHeight > 0 ? implicitWidth / implicitHeight : Tokens.panelSharePickerThumbAspect

                            anchors.centerIn: parent
                            width: ratio >= thumb.width / thumb.height ? thumb.width : thumb.height * ratio
                            height: ratio >= thumb.width / thumb.height ? thumb.width / ratio : thumb.height
                            captureSource: SharePicker.shown ? tile.source : null
                            live: true
                            paintCursor: false
                            visible: tile.source !== null
                        }

                        TintedIcon {
                            anchors.centerIn: parent
                            size: Tokens.panelSharePickerIconSize
                            visible: tile.source === null
                            source: ThemeIcons.appIcon(tile.entry ? tile.entry.icon : (tile.isScreen ? "" : tile.modelData.appId), "application-x-executable")
                            asynchronous: true
                        }
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: thumb.height + Tokens.spacingXs
                        height: Tokens.menuItemHeight
                        spacing: Tokens.spacingXs

                        TintedIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            size: Tokens.menuIconSize
                            visible: !tile.isScreen
                            source: ThemeIcons.appIcon(tile.entry ? tile.entry.icon : (tile.isScreen ? "" : tile.modelData.appId), "application-x-executable")
                            asynchronous: true
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, tile.width - Tokens.menuIconSize - Tokens.spacingXs)
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            text: tile.blocked ? qsTr("This window can't be shared") : tile.label
                            color: tile.blocked ? Appearance.colors.textSecondary : Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyMenuSize
                            font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (!root.armed)
                                return;
                            root.choose(tile.index);
                            grid.forceActiveFocus();
                        }
                        onDoubleClicked: {
                            if (!root.armed)
                                return;
                            root.choose(tile.index);
                            root.shareCurrent();
                        }
                    }
                }
            }

            // Selection: an area dragged on a display's live preview, in that display's logical pixels (7-10).
            FocusScope {
                id: regionView

                readonly property var screen: {
                    for (const s of root.screens) {
                        if (s.name === root.regionOutput)
                            return s;
                    }
                    return root.screens.length > 0 ? root.screens[0] : null;
                }
                // The drag under way, {x1, y1, x2, y2} in the preview's pixels; the chosen area, in the display's.
                property var drag: null
                readonly property var area: Logic.parseRegion(root.chosen)
                readonly property var marked: {
                    const d = regionView.drag;
                    if (d) {
                        // Kept inside the preview, as the area it gives (SharePicker.js regionFor).
                        const cx = v => Math.max(0, Math.min(preview.width, v));
                        const cy = v => Math.max(0, Math.min(preview.height, v));
                        return {
                            x: Math.min(cx(d.x1), cx(d.x2)),
                            y: Math.min(cy(d.y1), cy(d.y2)),
                            w: Math.abs(cx(d.x2) - cx(d.x1)),
                            h: Math.abs(cy(d.y2) - cy(d.y1))
                        };
                    }
                    const a = regionView.area;
                    const s = regionView.screen;
                    if (!a || !s || a.output !== s.name || s.width <= 0 || s.height <= 0)
                        return null;
                    const kx = preview.width / s.width, ky = preview.height / s.height;
                    return {
                        x: a.x * kx,
                        y: a.y * ky,
                        w: a.w * kx,
                        h: a.h * ky
                    };
                }

                visible: root.tab === "region"
                anchors.fill: parent
                anchors.margins: Tokens.spacingSm
                activeFocusOnTab: true
                Accessible.role: Accessible.Pane
                Accessible.name: qsTr("Area to share")
                Keys.onPressed: event => root.key(event)

                SegmentedControl {
                    id: displays
                    width: parent.width
                    fill: true
                    visible: root.screens.length > 1
                    accessibleName: qsTr("Display")
                    model: root.screens.map(s => ({
                                id: s.name,
                                text: s.name
                            }))
                    value: regionView.screen ? regionView.screen.name : ""
                    onPicked: id => {
                        root.regionOutput = id;
                        root.chosen = "";
                    }
                }

                Item {
                    id: stage

                    anchors.top: displays.visible ? displays.bottom : parent.top
                    anchors.topMargin: displays.visible ? Tokens.spacingSm : 0
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: sizeLabel.top

                    ScreencopyView {
                        id: preview

                        readonly property real ratio: regionView.screen && regionView.screen.height > 0 ? regionView.screen.width / regionView.screen.height : Tokens.panelSharePickerThumbAspect

                        anchors.centerIn: parent
                        width: ratio >= stage.width / stage.height ? stage.width : stage.height * ratio
                        height: ratio >= stage.width / stage.height ? stage.width / ratio : stage.height
                        captureSource: SharePicker.shown && root.tab === "region" ? regionView.screen : null
                        live: true
                        paintCursor: false
                    }

                    Rectangle {
                        visible: regionView.marked !== null
                        x: preview.x + (regionView.marked ? regionView.marked.x : 0)
                        y: preview.y + (regionView.marked ? regionView.marked.y : 0)
                        width: regionView.marked ? regionView.marked.w : 0
                        height: regionView.marked ? regionView.marked.h : 0
                        color: Appearance.withAlpha(Appearance.colors.selection, Tokens.materialHoverOpacity)
                        border.width: Tokens.controlFocusOutline
                        border.color: Appearance.colors.selection
                    }

                    MouseArea {
                        anchors.fill: preview
                        onPressed: mouse => {
                            if (!root.armed)
                                return;
                            regionView.forceActiveFocus();
                            regionView.drag = {
                                x1: mouse.x,
                                y1: mouse.y,
                                x2: mouse.x,
                                y2: mouse.y
                            };
                        }
                        onPositionChanged: mouse => {
                            const d = regionView.drag;
                            if (d)
                                regionView.drag = {
                                    x1: d.x1,
                                    y1: d.y1,
                                    x2: mouse.x,
                                    y2: mouse.y
                                };
                        }
                        onReleased: mouse => {
                            const d = regionView.drag;
                            const s = regionView.screen;
                            regionView.drag = null;
                            if (!d || !s)
                                return;
                            const r = Logic.regionFor({
                                x1: d.x1,
                                y1: d.y1,
                                x2: mouse.x,
                                y2: mouse.y
                            }, {
                                width: preview.width,
                                height: preview.height
                            }, {
                                width: s.width,
                                height: s.height
                            }, Tokens.panelSharePickerMinArea);
                            // The display shown stays the one chosen, whatever order the displays come in later.
                            root.regionOutput = s.name;
                            root.chosen = r ? Logic.regionKey(s.name, r) : "";
                        }
                    }
                }

                Text {
                    id: sizeLabel

                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: Tokens.menuItemHeight
                    verticalAlignment: Text.AlignVCenter
                    textFormat: Text.PlainText
                    text: regionView.area ? qsTr("%1 × %2 on %3").arg(regionView.area.w).arg(regionView.area.h).arg(regionView.area.output) : qsTr("Drag over the display to choose the area to share.")
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                }
            }

            Text {
                anchors.centerIn: parent
                visible: root.tiles.length === 0 && root.tab !== "region"
                textFormat: Text.PlainText
                text: root.tab === "screen" ? qsTr("No display can be shared.") : qsTr("No window can be shared.")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        },
        CheckBox {
            objectName: "sharepicker-remember"
            text: qsTr("Remember this choice")
            checked: root.remember
            // A click before the panel is armed changes nothing (7-8): the box shows root.remember again.
            onToggled: {
                if (root.armed)
                    root.remember = checked;
                else
                    checked = Qt.binding(() => root.remember);
            }
        }
    ]

    buttons: [
        Button {
            text: qsTr("Cancel")
            onClicked: SharePicker.cancel()
        },
        Button {
            objectName: "sharepicker-share"
            text: qsTr("Share")
            primary: true
            enabled: root.armed && root.hasChoice
            onClicked: root.shareCurrent()
        }
    ]
}
