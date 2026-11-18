pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services
import "Layout.js" as Layout
import "../platform/StagesState.js" as StagesState

// Stages strip (docs/specs/stages.md "Shell side"; macOS: a column of recent-app thumbnails on the left edge). The
// compositor plugin owns the model and draws the live thumbnails of the inactive stages into the tiles this file asks for;
// the strip surface (namespace grassfield-stages, Top layer, left edge, keyboard None) is transparent over them and takes the
// pointer: a click brings a stage forward (Shift merges it), a drag moves a stage's window into another stage or into the
// active one. Only the frosted app icon badge and the hover outline are drawn here (blur from the layer rule of that namespace).
// Nothing exists without the plugin's `stages-available`, the user's switch and the plugin's flag (StagesLink.active).
Scope {
    id: root

    readonly property var metrics: ({
            tileWidth: Tokens.stagesTileWidth,
            tileHeight: Tokens.stagesTileHeight,
            tileGap: Tokens.stagesTileGap,
            edgeMargin: Tokens.stagesEdgeMargin,
            maxTiles: Tokens.stagesMaxTiles,
            revealZone: Tokens.stagesRevealZone
        })
    readonly property int durationMs: Appearance.reduceMotion ? 0 : Tokens.motionSlow
    readonly property var curve: Tokens.motionCurveStandard.slice(0, 4)

    // Per output: the pointer revealed the strip while a window overlaps it.
    property var revealed: ({})

    function setRevealed(name: string, value: bool): void {
        if (!!revealed[name] === value)
            return;
        const next = Object.assign({}, revealed);
        next[name] = value;
        revealed = next;
    }

    function insets(): var {
        const dock = Settings.dockFootprint;
        return {left: dock.left, top: Tokens.menubarHeight, bottom: dock.bottom};
    }

    function stripCount(name: string): int {
        return StagesState.stripStages(StagesLink.monitorState(name)).length;
    }

    // Geometry of the strip of a screen (layout coordinates), for the number of strip stages it shows now.
    // A screen being torn down (a display unplugged) reads as null for a moment: it gets an empty geometry, not an error.
    function geometryOf(screen: var): var {
        const scr = screen ? screen : ({name: "", x: 0, y: 0, width: 0, height: 0});
        const ins = insets();
        const availH = scr.height - ins.top - Tokens.stagesEdgeMargin - Math.max(ins.bottom, Tokens.stagesEdgeMargin);
        return Layout.geometry(scr, ins, Layout.tileCount(stripCount(scr.name), availH, metrics), metrics);
    }

    function isShown(screen: var): bool {
        if (!screen)
            return false;
        const mon = StagesLink.monitorState(screen.name);
        return Layout.shown(StagesLink.on, stripCount(screen.name), !!mon && mon.overlap, !!revealed[screen.name]);
    }

    // What the plugin is asked for: one strip per output (all in one request, the update replaces them).
    function stripsRequest(): var {
        const out = [];
        for (let i = 0; i < Quickshell.screens.length; i++) {
            const s = Quickshell.screens[i];
            out.push({monitor: s.name, hidden: !isShown(s), tiles: geometryOf(s).tiles});
        }
        return out;
    }

    // Changes only when something the plugin must know changes (tiles, hidden, timing): events alone never resend.
    readonly property string signature: JSON.stringify([StagesLink.active, root.durationMs, stripsRequest()])
    onSignatureChanged: {
        retries = 0;
        schedule();
    }

    property int retries: 0

    function schedule(): void {
        if (StagesLink.active)
            debounce.restart();
    }

    function send(): void {
        if (!StagesLink.active)
            return;
        StagesLink.send(Layout.onRequest(stripsRequest(), durationMs, curve));
    }

    // Quiet time before sending, which also lets the surface's new input region reach the compositor before `op:on` asks
    // the plugin to check it (docs/specs/stages.md ST17).
    Timer {
        id: debounce
        interval: Tokens.stagesResendDebounceMs
        onTriggered: root.send()
    }

    Timer {
        id: retryTimer
        interval: Tokens.stagesRetryMs
        onTriggered: root.send()
    }

    Connections {
        target: StagesLink

        // After each capabilities event with `stages` and after a plugin reload (contract 7).
        function onResumed(): void {
            root.retries = 0;
            root.schedule();
        }

        // `no-strip` (the surface was not mapped yet) and `interrupted` (it went away or the outputs changed).
        function onResendNeeded(reason: string): void {
            if (root.retries >= Tokens.stagesRetryMax)
                return;
            root.retries++;
            retryTimer.restart();
        }
    }

    Component.onCompleted: schedule()

    Variants {
        model: Quickshell.screens

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData

            readonly property var geo: root.geometryOf(modelData)
            readonly property var monitorState: modelData ? StagesLink.monitorState(modelData.name) : null
            readonly property bool shown: root.isShown(modelData)
            readonly property bool revealedNow: modelData ? !!root.revealed[modelData.name] : false
            // Tile being dragged (-1 none) and the pointer in surface coordinates while it is.
            property int dragSlot: -1
            property point dragPoint: Qt.point(0, 0)
            readonly property var dropOver: dragSlot >= 0 ? Layout.dropTarget(dragPoint.x, dragPoint.y, geo) : ({kind: "none"})

            screen: modelData
            visible: StagesLink.active
            anchors {
                top: true
                left: true
            }
            // qmllint disable unqualified unresolved-type
            margins.top: modelData ? geo.surface.y - modelData.y : 0
            margins.left: modelData ? geo.surface.x - modelData.x : 0
            // qmllint enable unqualified unresolved-type
            implicitWidth: geo.surface.w
            implicitHeight: geo.surface.h
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            mask: shown ? boxRegion : edgeRegion
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.namespace: "grassfield-stages"

            Region {
                id: boxRegion
                item: boxItem
            }

            Region {
                id: edgeRegion
                item: edgeItem
            }

            // The pointer left the revealed strip: it hides again after the grace time; at the left edge it comes back.
            onShownChanged: {
                if (!shown)
                    grace.stop();
            }
            onMonitorStateChanged: {
                if (!monitorState || !monitorState.overlap)
                    root.setRevealed(modelData.name, false);
            }

            Timer {
                id: dwell
                interval: Tokens.stagesRevealDwell
                onTriggered: root.setRevealed(win.modelData.name, true)
            }

            Timer {
                id: grace
                interval: Tokens.stagesHideGrace
                onTriggered: root.setRevealed(win.modelData.name, false)
            }

            Item {
                id: edgeItem
                visible: Layout.edgeActive(StagesLink.on, win.shown)
                x: win.geo.edge.x
                y: win.geo.edge.y
                width: win.geo.edge.w
                height: win.geo.edge.h

                HoverHandler {
                    id: edgeHover
                    onHoveredChanged: {
                        const mon = win.monitorState;
                        if (hovered && mon && mon.overlap && root.stripCount(win.modelData.name) > 0)
                            dwell.restart();
                        else
                            dwell.stop();
                    }
                }
            }

            Item {
                id: boxItem
                x: win.geo.box.x
                y: win.geo.box.y
                width: win.geo.box.w
                height: win.geo.box.h

                HoverHandler {
                    id: boxHover
                    onHoveredChanged: {
                        if (hovered)
                            grace.stop();
                        else if (win.revealedNow && !win.dragging)
                            grace.restart();
                    }
                }
            }

            readonly property bool dragging: dragSlot >= 0
            // A change of the tile count rebuilds every tile: a tile dragged at that moment goes without a release or a
            // cancel, so the drag ends here (else its badge stays and no other drag can start).
            readonly property int tileCount: shown ? geo.tiles.length : 0
            onTileCountChanged: dragSlot = -1

            Repeater {
                model: win.tileCount

                Item {
                    id: tile

                    required property int index
                    readonly property var rect: win.geo.tiles[index]
                    readonly property var stage: StagesState.stageAtSlot(win.monitorState, index)
                    readonly property var apps: Layout.appIds(stage, a => StagesLink.appIdOf(a, Compositor.topologyRevision))
                    readonly property string appId: apps.length > 0 ? apps[0] : ""
                    readonly property var entry: appId !== "" ? Apps.lookup(appId) : null
                    readonly property string appName: appId !== "" ? Apps.nameFor(appId) : qsTr("Stage")
                    readonly property int count: stage ? stage.windows.length : 0
                    readonly property bool dropTarget: win.dropOver.kind === "tile" && win.dropOver.slot === index && win.dragSlot !== index

                    x: rect.x - win.geo.surface.x
                    y: rect.y - win.geo.surface.y
                    width: rect.w
                    height: rect.h
                    visible: stage !== null

                    Accessible.role: Accessible.Button
                    Accessible.name: tile.appName
                    Accessible.description: tile.count === 1 ? qsTr("1 window") : qsTr("%1 windows").arg(tile.count)
                    Accessible.onPressAction: StagesLink.send(Layout.clickRequest(win.monitorState, tile.index, false))

                    // Hover and drop-target outline: the thumbnail itself is the compositor's, so only a ring is drawn, outside
                    // the tile and clear of it by the Overview's gap (UI audit 2026-11-05, LOW: one ring model for the Overview's
                    // windows and Desktops and for Stages).
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -Tokens.stagesRingWidth - Tokens.stagesRingGap
                        radius: Tokens.stagesRingRadius + Tokens.stagesRingWidth + Tokens.stagesRingGap
                        color: "transparent"
                        border.width: Tokens.stagesRingWidth
                        border.color: tile.dropTarget ? Appearance.colors.accent : Appearance.focusRingColor
                        opacity: tile.dropTarget || (area.containsMouse && win.dragSlot < 0) ? 1 : 0

                        Behavior on opacity {
                            NumberAnimation {
                                duration: Appearance.duration(Tokens.motionFast)
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: Appearance.curve
                            }
                        }
                    }

                    // App icon badge at the bottom-left corner (frosted: the layer rule of the namespace blurs it).
                    Material {
                        id: badge
                        // A glyph on a disk: the controls' class (ADR-0039 step 22).
                        glassClass: "controls"
                        x: Tokens.stagesBadgeInset
                        y: parent.height - height - Tokens.stagesBadgeInset
                        width: Tokens.stagesBadgeSize
                        height: Tokens.stagesBadgeSize
                        radius: width / 2
                        shadowEnabled: false
                        opacity: win.dragSlot === tile.index ? Tokens.stagesDragOpacity : 1

                        TintedIcon {
                            anchors.centerIn: parent
                            size: Tokens.stagesBadgeIconSize
                            source: ThemeIcons.appIcon(tile.entry ? tile.entry.icon : "", "application-x-executable")
                            asynchronous: true
                        }
                    }

                    MouseArea {
                        id: area
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        hoverEnabled: true
                        cursorShape: Qt.ArrowCursor
                        property point pressAt: Qt.point(0, 0)

                        onPressed: mouse => pressAt = mapToItem(win.contentItem, mouse.x, mouse.y)
                        onPositionChanged: mouse => {
                            if (!pressed)
                                return;
                            const p = mapToItem(win.contentItem, mouse.x, mouse.y);
                            if (win.dragSlot < 0 && Math.hypot(p.x - pressAt.x, p.y - pressAt.y) >= Tokens.stagesDragThreshold)
                                win.dragSlot = tile.index;
                            if (win.dragSlot === tile.index)
                                win.dragPoint = p;
                        }
                        onReleased: mouse => {
                            if (win.dragSlot === tile.index) {
                                const target = Layout.dropTarget(win.dragPoint.x, win.dragPoint.y, win.geo);
                                win.dragSlot = -1;
                                StagesLink.send(Layout.dropRequest(win.monitorState, tile.index, target));
                            } else if (containsMouse) {
                                StagesLink.send(Layout.clickRequest(win.monitorState, tile.index, (mouse.modifiers & Qt.ShiftModifier) !== 0));
                            }
                        }
                        onCanceled: win.dragSlot = -1
                    }
                }
            }

            // The dragged tile's badge follows the pointer inside the surface (the thumbnail stays where the plugin draws it), with
            // the dragged stage's app icon on it (it was an empty disk; UI audit 2026-11-05, LOW).
            Material {
                id: ghost

                readonly property var apps: Layout.appIds(StagesState.stageAtSlot(win.monitorState, win.dragSlot), a => StagesLink.appIdOf(a, Compositor.topologyRevision))
                readonly property var entry: apps.length > 0 ? Apps.lookup(apps[0]) : null

                glassClass: "controls"
                visible: win.dragSlot >= 0
                x: win.dragPoint.x - width / 2
                y: win.dragPoint.y - height / 2
                width: Tokens.stagesBadgeSize
                height: Tokens.stagesBadgeSize
                radius: width / 2
                shadowEnabled: false
                opacity: Tokens.stagesDragOpacity
                enabled: false

                TintedIcon {
                    anchors.centerIn: parent
                    size: Tokens.stagesBadgeIconSize
                    source: ThemeIcons.appIcon(ghost.entry ? ghost.entry.icon : "", "application-x-executable")
                    asynchronous: true
                }
            }
        }
    }
}
