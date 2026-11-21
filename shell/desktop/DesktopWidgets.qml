pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland // layering-exception: GF-087
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services
import qs.widgets
import "../widgets/Placements.js" as Placements

// Desktop widgets (docs/specs/widgets.md): the widgets placed on the desktop of each screen, on a
// layer above the wallpaper and below windows (namespace grassfield-widgets, no exclusive zone).
// Each widget has its OWN small layer surface (its tile plus Tokens.widgetSurfacePad for the shadow),
// so a repaint touches a few hundred px instead of the whole screen. The input mask of a surface is
// the tile; clicks around it reach the layers below. While a tile is dragged its surface grows to the
// whole screen (full-window input region, so the pointer never leaves it) and shrinks again on
// release, when the tile snaps to the nearest free cell and the placement is saved.
// A widget whose tile is fully covered by a window on the visible workspace (fullscreen, maximized or
// tiled over it) has its surface hidden and its widget inactive (no sampling, no timers). While a
// window has focus on a screen the widgets are desaturated and dimmed; clicking a widget makes the
// desktop the active surface again until the focus changes.
Variants {
    model: Quickshell.screens

    Scope {
        id: scope

        required property ShellScreen modelData

        readonly property string screenName: modelData ? modelData.name : ""

        readonly property var grid: Widgets.gridFor(modelData)
        readonly property int cols: grid.cols
        readonly property int rows: grid.rows
        readonly property real pitch: grid.cell + grid.gap
        // Placements of this screen that lie on the grid (the rest are moved by fitScreen below).
        readonly property var mine: Widgets.desktop.filter(e => e.screen === screenName && e.col >= 0 && e.row >= 0 && e.col + Placements.cells(e.size).w <= cols && e.row + Placements.cells(e.size).h <= rows)
        // Windows of the workspace shown on this screen (geometry relative to the screen).
        readonly property var shownWindows: mine.length > 0 ? Compositor.windowsOn(screenName, Compositor.topologyRevision) : []
        readonly property bool windowFocused: Compositor.focusedToplevel !== null && Compositor.focusedScreenName === screenName
        property bool desktopActive: false
        readonly property bool dimmed: windowFocused && !desktopActive
        property real dimAmount: dimmed ? 1 : 0

        // Drag in progress: uid of the widget and the pointer's offset from where the drag began.
        property string dragUid: ""
        property point dragOffset: Qt.point(0, 0)
        // Context menu.
        property var menuEntry: null
        // The entry the menu was last opened for: the menu's bindings run once more when menuEntry is cleared (the popover
        // takes its place, a row was chosen) before the Loader lets the menu go; they read this one, never null.
        property var heldEntry: null
        onMenuEntryChanged: {
            if (menuEntry !== null)
                heldEntry = menuEntry;
        }
        // The Weather widget's Edit Location… popover (ADR-0045 OC-14), in the menu's window where the menu was.
        property var editEntry: null
        readonly property bool overlayOpen: menuEntry !== null || editEntry !== null
        // Key focus returns to the window active when the menu opened (FocusReturn); one name per screen. The menu giving
        // way to the popover keeps it.
        onOverlayOpenChanged: {
            if (overlayOpen)
                FocusReturn.opened("widgets-menu-" + screenName);
            else
                FocusReturn.closed("widgets-menu-" + screenName, true);
        }
        property point menuAt: Qt.point(0, 0)

        // Cell position of an entry in screen px (no drag offset).
        function originOf(entry: var): point {
            return Qt.point(grid.x0 + entry.col * pitch, grid.y0 + entry.row * pitch);
        }

        function sizeOf(entry: var): size {
            const s = Placements.px(entry.size, grid.cell, grid.gap);
            return Qt.size(s.w, s.h);
        }

        // True when one window of the shown workspace contains the whole tile.
        function covered(entry: var): bool {
            const o = originOf(entry);
            const s = sizeOf(entry);
            return Placements.coveredBy({x: o.x, y: o.y, w: s.width, h: s.height}, shownWindows);
        }

        function commitDrag(entry: var, at: point): void {
            const spot = Placements.snap(at.x - grid.x0, at.y - grid.y0, entry.size, grid.cell, grid.gap, grid.cols, grid.rows);
            dragUid = "";
            dragOffset = Qt.point(0, 0);
            Widgets.moveDesktop(entry.uid, spot.col, spot.row, screenName);
        }

        // A click on a widget keeps the desktop active (full color) for a while, as long as the
        // pointer stays over a widget; a window that is already focused sends no event to end it.
        function keepActive(): void {
            desktopActive = true;
            activeTimer.restart();
        }

        function closeMenu(): void {
            menuEntry = null;
            editEntry = null;
        }

        // The session locks: the widget menu (an Overlay layer with the keyboard) closes; none opens while locked
        // (onMenuRequested) (GF-116, review of 1d2c856).
        Connections {
            target: SessionState

            function onLockedChanged(): void {
                if (SessionState.locked)
                    scope.closeMenu();
            }
        }

        function applyMenu(action: string): void {
            const entry = menuEntry;
            if (entry && action === "weather:location") {
                // The popover takes the menu's place; the window keeps the keyboard (set before the menu goes).
                editEntry = entry;
                menuEntry = null;
                return;
            }
            menuEntry = null;
            if (!entry)
                return;
            if (action === "remove")
                Widgets.remove(entry.uid);
            else if (action.startsWith("size:"))
                Widgets.setSize(entry.uid, action.substring(5));
            else if (action.startsWith("move:"))
                Widgets.stepDesktop(entry.uid, action.substring(5), screenName);
        }

        // Off-grid or overlapping placements (screen geometry changed, hand-edited file) move to
        // the nearest free cell.
        onColsChanged: Widgets.fitScreen(screenName)
        onRowsChanged: Widgets.fitScreen(screenName)
        Component.onCompleted: Widgets.fitScreen(screenName)

        Behavior on dimAmount {
            NumberAnimation {
                duration: Appearance.duration(Tokens.widgetDimMs)
            }
        }

        Timer {
            id: activeTimer
            interval: Tokens.widgetActiveMs
            onTriggered: scope.desktopActive = false
        }

        // Window geometry is only read on request: a new, moved or closed window or a workspace
        // switch asks for a re-read (coalesced by Compositor) while this screen has widgets.
        Connections {
            target: Hyprland
            enabled: scope.mine.length > 0

            function onRawEvent(event: HyprlandEvent): void {
                if (event.name === "openwindow" || event.name === "closewindow" || event.name === "movewindowv2" || event.name === "workspacev2" || event.name === "changefloatingmode")
                    Compositor.requestWindowRefresh();
            }
        }

        // Hyprland emits nothing when a floating window is moved or resized, so a hidden widget could
        // stay hidden after the window left. While a widget of this screen is hidden, the pointer
        // moving over the desktop (reported by the surfaces below the windows) asks, debounced, for a
        // re-read of the window geometry.
        readonly property bool anyCovered: mine.some(e => covered(e))

        Connections {
            target: PointerTracker
            enabled: scope.anyCovered

            function onMoved(screen: string): void {
                if (screen === scope.screenName)
                    recheck.restart();
            }
        }

        Timer {
            id: recheck
            interval: 300
            onTriggered: Compositor.requestWindowRefresh()
        }

        Connections {
            target: Compositor

            function onFocusedToplevelChanged(): void {
                scope.desktopActive = false;
            }
        }

        Variants {
            // The uids: Variants keeps a surface for a uid that stays in the list, so a saved
            // placement change does not recreate it.
            model: scope.mine.map(e => e.uid)

            // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
            // qmllint disable uncreatable-type
            PanelWindow {
                // qmllint enable uncreatable-type
                id: win

                required property string modelData

                readonly property var entry: scope.mine.find(e => e.uid === modelData) ?? lastEntry
                property var lastEntry: ({uid: modelData, id: "clock", size: "small", col: 0, row: 0})
                readonly property bool dragging: modelData === scope.dragUid
                readonly property bool isCovered: scope.covered(entry)
                readonly property point origin: scope.originOf(entry)
                readonly property size tileSize: scope.sizeOf(entry)
                readonly property real pad: Tokens.widgetSurfacePad
                // After a drop the tile glides from where it was let go to its snapped cell (audit A-10): the surface stays full
                // screen until it is there. settleT runs from 1 (at the drop point) to 0 (at the cell).
                property point dropAt: Qt.point(0, 0)
                property real settleT: 0
                readonly property bool expanded: dragging || settleAnim.running

                NumberAnimation {
                    id: settleAnim
                    target: win
                    property: "settleT"
                    to: 0
                    duration: Appearance.duration(Tokens.motionFast)
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.curve
                }

                // Lets go of a drag: the tile starts its glide at the drop point, whatever cell the move then stores.
                function settleFrom(at: point): void {
                    win.dropAt = at;
                    win.settleT = 1;
                    settleAnim.restart();
                }

                // Where the tile is drawn, in screen px: under the pointer while dragged, on its way to the cell after the drop.
                readonly property point tileAt: dragging ? Qt.point(origin.x + scope.dragOffset.x, origin.y + scope.dragOffset.y) : Qt.point(origin.x + (dropAt.x - origin.x) * settleT, origin.y + (dropAt.y - origin.y) * settleT)

                screen: scope.modelData
                visible: !isCovered
                // Small surface at the tile; the whole screen while dragging (and while the dropped tile settles).
                anchors {
                    top: true
                    left: true
                    right: win.expanded
                    bottom: win.expanded
                }
                // qmllint disable unqualified unresolved-type
                margins.left: win.expanded ? 0 : win.origin.x - win.pad
                margins.top: win.expanded ? 0 : win.origin.y - win.pad
                // qmllint enable unqualified unresolved-type
                implicitWidth: tileSize.width + 2 * pad
                implicitHeight: tileSize.height + 2 * pad
                exclusionMode: ExclusionMode.Ignore
                color: "transparent"
                WlrLayershell.layer: WlrLayer.Bottom
                // Never takes the keyboard: focus stays with the user's window.
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                WlrLayershell.namespace: "grassfield-widgets"
                // qmllint disable missing-type
                mask: Region {
                    x: win.expanded ? 0 : win.pad
                    y: win.expanded ? 0 : win.pad
                    width: win.expanded ? win.width : win.tileSize.width
                    height: win.expanded ? win.height : win.tileSize.height
                }
                // Real blur behind the frosted tile (master-prompt 5.5, never faked): the tile's own shape is the region, and
                // the namespace is in the layer rule list (config/hypr/grassfield/windows.lua) as the fallback. Reduce
                // Transparency (opaque material) asks for none.
                BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 ? tileBlur : null
                // The tile as drawn: a lifted tile is scaled about its centre (widget.liftScale), and the region follows it so no
                // unblurred rim shows round it (UI audit 2026-11-05, LOW). The tile's parent fills the window: its coordinates
                // are the window's.
                Region {
                    id: tileBlur
                    x: tile.x - tile.width * (tile.scale - 1) / 2
                    y: tile.y - tile.height * (tile.scale - 1) / 2
                    width: tile.width * tile.scale
                    height: tile.height * tile.scale
                    radius: Tokens.widgetRadius * tile.scale
                }
                // qmllint enable missing-type

                // Window origin in screen px, as the pointer and the tile see it. From the size the surface really has, not from the
                // state asked for: the compositor answers a switch between the tile-sized and the full-screen surface a frame or two
                // later, and until then the tile is drawn where it is in the surface that is still shown (audit A-10: it was drawn
                // at screen coordinates in the small surface at a drag's start, at (pad, pad) of the full screen at its end).
                readonly property bool fullSurface: win.width > win.tileSize.width + 2 * win.pad
                readonly property point windowOrigin: fullSurface ? Qt.point(0, 0) : Qt.point(win.origin.x - win.pad, win.origin.y - win.pad)

                Item {
                    anchors.fill: parent
                    layer.enabled: scope.dimAmount > 0
                    layer.effect: MultiEffect {
                        saturation: Tokens.widgetDimSaturation * scope.dimAmount
                        brightness: Tokens.widgetDimBrightness * scope.dimAmount
                    }

                    WidgetHost {
                        id: tile

                        entry: win.entry
                        cell: scope.grid.cell
                        gap: scope.grid.gap
                        active: !win.isCovered
                        x: win.tileAt.x - win.windowOrigin.x
                        y: win.tileAt.y - win.windowOrigin.y
                        // A lifted widget grows a little; under Reduce Motion it does not (ADR-0039 D2, step 25: a scale is
                        // motion; the drag itself follows the pointer).
                        scale: win.dragging && !Appearance.reduceMotion ? Tokens.widgetLiftScale : 1
                        onPressed: scope.keepActive()
                        onMenuRequested: (px, py) => {
                            if (SessionState.refuses("widget menu"))
                                return;
                            const p = tile.mapToItem(null, px, py);
                            scope.menuAt = Qt.point(p.x + win.windowOrigin.x, p.y + win.windowOrigin.y);
                            scope.menuEntry = win.entry;
                        }
                        onHoveredChanged: if (hovered && scope.desktopActive)
                            scope.keepActive()
                        onRemoveRequested: Widgets.remove(win.modelData)

                        Behavior on scale {
                            NumberAnimation {
                                duration: Appearance.duration(Tokens.motionFast)
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: Appearance.curve
                            }
                        }

                        DragHandler {
                            id: drag

                            // Pointer position in screen px at the press, and the surface origin then.
                            property point pressAt: Qt.point(0, 0)

                            target: null
                            acceptedButtons: Qt.LeftButton
                            cursorShape: active ? Qt.ClosedHandCursor : Qt.ArrowCursor
                            onActiveChanged: {
                                if (active) {
                                    pressAt = Qt.point(win.windowOrigin.x + centroid.scenePressPosition.x, win.windowOrigin.y + centroid.scenePressPosition.y);
                                    scope.dragUid = win.modelData;
                                } else if (scope.dragUid === win.modelData) {
                                    const at = Qt.point(win.origin.x + scope.dragOffset.x, win.origin.y + scope.dragOffset.y);
                                    win.settleFrom(at);
                                    scope.commitDrag(win.entry, at);
                                }
                            }
                            onCentroidChanged: {
                                if (active)
                                    scope.dragOffset = Qt.point(win.windowOrigin.x + centroid.scenePosition.x - pressAt.x, win.windowOrigin.y + centroid.scenePosition.y - pressAt.y);
                            }
                        }
                    }
                }
            }
        }

        // Context menu (and the Weather widget's Edit Location… popover in its place): an Overlay window that takes the
        // keyboard while it is open (a Bottom layer cannot), so arrows, typing, Return and Esc work; clicking anywhere else
        // dismisses it.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: menuWin

            screen: scope.modelData
            // Mapped a moment longer than it holds the keyboard: a layer destroyed while Exclusive leaves the compositor
            // with no keyboard focus.
            visible: menuRelease.mapped
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: scope.overlayOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            WlrLayershell.namespace: "grassfield-widgets-menu"
            // The whole surface takes input while the menu is open; nothing once it closed: it stays mapped a moment for
            // the keyboard release, and a click then belongs to the window under it.
            // qmllint disable missing-type
            mask: scope.overlayOpen ? null : menuPassThrough
            // The menu is frosted like every menu: its own blur region while it is open.
            BackgroundEffect.blurRegion: scope.overlayOpen && Appearance.effectiveTransparency > 0 ? menuBlur : null
            // qmllint enable missing-type

            Region {
                id: menuBlur
                item: menuLoader
                // The widget menu's corner, or Edit Location…'s, a popover (radius.popover).
                radius: scope.editEntry !== null ? Tokens.radiusPopover : Tokens.radiusMenu
            }

            Region {
                id: menuPassThrough
            }

            KeyboardRelease {
                id: menuRelease
                shown: scope.overlayOpen
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: scope.closeMenu()
            }

            Loader {
                id: menuLoader
                active: scope.overlayOpen
                x: Math.max(Tokens.spacingSm, Math.min(scope.menuAt.x, menuWin.width - width - Tokens.spacingSm))
                y: Math.max(Tokens.spacingSm, Math.min(scope.menuAt.y, menuWin.height - height - Tokens.spacingSm))
                sourceComponent: scope.editEntry !== null ? locationEditor : widgetMenu
            }

            Component {
                id: widgetMenu

                WidgetMenu {
                    entry: scope.heldEntry
                    moves: scope.heldEntry ? ({
                            left: Widgets.canStepDesktop(scope.heldEntry.uid, "left", scope.screenName),
                            right: Widgets.canStepDesktop(scope.heldEntry.uid, "right", scope.screenName),
                            up: Widgets.canStepDesktop(scope.heldEntry.uid, "up", scope.screenName),
                            down: Widgets.canStepDesktop(scope.heldEntry.uid, "down", scope.screenName)
                        }) : ({})
                    onChoose: action => scope.applyMenu(action)
                    onCloseRequested: scope.closeMenu()
                    Component.onCompleted: forceActiveFocus()
                }
            }

            Component {
                id: locationEditor

                LocationEditor {
                    onClosed: scope.closeMenu()
                    Component.onCompleted: forceActiveFocus()
                }
            }
        }
    }
}
