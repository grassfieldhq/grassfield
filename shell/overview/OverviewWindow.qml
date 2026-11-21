pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services
import "ClientChrome.js" as ClientChrome
import "Layout.js" as Layout
import "V2.js" as V2
import "../dock/Geometry.js" as DockGeometry
import "../platform/WindowTiling.js" as WindowTiling

// Overview surface, one per screen: a full-screen layer-shell overlay below the menu bar with a
// Spaces bar on top and the windows of the output's current workspace laid out.
// v1 (thumbnail mode): a dimmed, blurred backdrop and live thumbnails (ScreencopyView of the toplevel).
// v2 (`!controller.thumbnailMode`): this surface is the transparent chrome of the compositor's overview
// (namespace grassfield-overview, Overlay, keyboard Exclusive on every output while open): the dim is OverviewBackdrop on the Bottom
// layer, the real windows are transformed by the compositor, and the per-window items below are only the hit areas
// (surface + titlebar band), the selection outline, the drag ghost and the label anchor.
//
// Spaces tiles (v1): window count and app icons, no capture of the workspace.
// Zoom: thumbnails interpolate from the real window rectangle to the layout rectangle.
// Reduce Motion: geometry does not move, everything crossfades in at most motionReducedMax.
Variants {
    id: root

    required property var controller

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property string screenName: modelData ? modelData.name : ""
        readonly property bool shown: root.controller.open
        readonly property bool v2: !root.controller.thumbnailMode
        // Every chrome is Exclusive while open (Hyprland sends pointer input to Exclusive layers only); when the close
        // starts the non-holders drop to None, then the holder (V2.keyboardPlan). The focus itself comes from the
        // compositor plugin (`overview-focus`) or, without it, from the controller's checked retry.
        readonly property bool holdsKeyboard: root.controller.keyboardPlan[screenName] === "exclusive"

        // 0 = windows at their real place, 1 = fully laid out. While a swipe drives the Overview, the fingers' progress
        // (Overview.gesture, CIO-01).
        property real progress: shown && root.controller.gesture.progress >= 0 ? root.controller.gesture.progress : (shown ? 1 : 0)
        readonly property real zoom: Appearance.reduceMotion ? 1 : progress

        // Windows of the current workspace and the Spaces of this output, kept while the
        // closing animation runs. Reactive on Hyprland data and on window/workspace events.
        readonly property var liveWins: shown ? Compositor.windowsOn(screenName, Compositor.topologyRevision) : null
        readonly property var liveSpaces: shown ? Compositor.spacesOn(screenName, Compositor.topologyRevision) : null
        property var wins: []
        property var spaces: []
        property var winKeys: []
        property var byKey: ({})

        // Selection: window address ("" none, or a window of another output) or, in Spaces mode on this output, the tile
        // index (windows mode = -1). The state lives in the controller (one selection across outputs: the keyboard
        // reaches whichever chrome Hyprland picked, so the keys cannot depend on the output they arrive on).
        readonly property string selected: byKey[root.controller.selected] ? root.controller.selected : ""
        // The window the ring and the name belong to: the selected one (hover, keys) or, until the user has chosen, the window
        // that was active when the overview opened (macOS: the frontmost window is the one the eye lands on).
        readonly property string marked: selected !== "" ? selected : (byKey[root.controller.previousAddress] ? root.controller.previousAddress : "")
        readonly property int spaceFocus: root.controller.spaceScreen === screenName ? root.controller.spaceFocus : -1
        readonly property int minFocus: root.controller.minScreen === screenName ? root.controller.minFocus : -1
        // Drag state.
        property string dragKey: ""
        property point dragPoint: Qt.point(0, 0)
        property int dropIndex: -1

        readonly property real barBottom: Tokens.overviewBarHeight

        // Minimized windows (macOS: a separate row below a divider, smaller than the open windows): the ones the shell
        // minimized, on the output that has the Dock (the tiles of the Dock are there). Kept while the close animation runs.
        readonly property bool hasMinimized: Compositor.dockScreenName === "" || Compositor.dockScreenName === screenName
        readonly property var liveMinimized: shown ? (hasMinimized ? Compositor.minimized : []) : null
        property var minimizedItems: []
        // Test hook data: the capture sizes of the minimized tiles by window address (see statusData).
        property var captureInfo: ({})
        readonly property var tileSpec: ({
                w: Tokens.overviewMinimizedWidth,
                h: Tokens.overviewMinimizedHeight,
                label: Tokens.overviewMinimizedLabelHeight,
                gap: Tokens.overviewMinimizedGap,
                pad: Tokens.overviewMinimizedPad
            })
        readonly property real stripReserve: Layout.stripHeight(minimizedItems.length, tileSpec)
        onLiveMinimizedChanged: {
            if (liveMinimized)
                minimizedItems = Layout.capStrip(liveMinimized, Tokens.overviewMinimizedMax);
        }
        // Free region in this window's coordinates (the overlay starts below the menu bar). Taken
        // from the screen, never from the window size, which is 0 until the compositor configures
        // the layer surface.
        // The Dock's area (when it takes space) is reserved, as is the menu bar's (the surface starts below it).
        // Only the output that has the Dock (it is on one output at a time).
        readonly property var dockInsets: Compositor.dockScreenName === "" || Compositor.dockScreenName === screenName ? DockGeometry.footprint(Settings.dockPosition, Settings.dockMetrics, Settings.dockAutohide) : ({left: 0, right: 0, bottom: 0})
        readonly property int dockReserve: dockInsets.bottom
        readonly property var area: Layout.freeArea({
            w: modelData ? modelData.width : 0,
            h: modelData ? modelData.height : 0
        }, {
            menubar: Tokens.menubarHeight,
            barBottom: barBottom,
            margin: Tokens.overviewAreaMargin,
            label: Tokens.overviewLabelHeight,
            dock: dockReserve,
            dockLeft: dockInsets.left,
            dockRight: dockInsets.right,
            strip: stripReserve
        })
        // The strip's tiles and divider, in this window's coordinates (the window starts below the menu bar).
        readonly property var strip: Layout.stripRects(minimizedItems.length, {
            x: Tokens.overviewAreaMargin + dockInsets.left,
            w: (modelData ? modelData.width : 0) - 2 * Tokens.overviewAreaMargin - dockInsets.left - dockInsets.right,
            bottom: (modelData ? modelData.height : 0) - Tokens.menubarHeight - Tokens.overviewAreaMargin - dockReserve
        }, tileSpec)
        // Layout of `wins`, recomputed only when the inputs change (see relayout()).
        property var placement: ({
                scale: Tokens.overviewMaxScale,
                rects: []
            })
        property string layoutSignature: ""

        // The titlebar band of a window: the plugin's strip, or none for a window that draws its own chrome while the plugin
        // advertises that it steps aside (ClientChrome.js; the tag is Hyprland's, set by the session rule gf-client-chrome),
        // nor for a Split View window whose titlebar the plugin keeps away (tiling step 6e, ADR-0036 D73).
        function bandOf(w: var): real {
            const away = !!w && WindowTiling.splitTitleAway(TilingLink.splits, w.address, Compositor.splitTitlesAway);
            return ClientChrome.band(w, Capabilities.has(ClientChrome.FEATURE), Tokens.overviewWindowTitlebarHeight, away);
        }

        // Window rectangles in this window's coordinates, laid out when the window ids, rects or
        // the area actually changed (toplevel refreshes re-deliver identical data).
        function relayout(): void {
            const a = area;
            if (!(a.w > 1 && a.h > 1))
                return;
            // v2: the layout includes the titlebar band the compositor draws above each window (none above a window that
            // draws its own chrome, ADR-0015).
            const input = wins.map(w => V2.layoutInput(w.address, w.x, w.y - Tokens.menubarHeight, w.w, w.h, v2 ? bandOf(w) : 0));
            const sig = Layout.signature(input, a);
            if (sig === layoutSignature)
                return;
            layoutSignature = sig;
            placement = Layout.layout(input, a, {
                maxScale: Tokens.overviewMaxScale,
                gap: Layout.labelAwareGap(Tokens.overviewMinGap, Tokens.overviewLabelHeight, Tokens.spacingSm)
            });
        }
        onAreaChanged: relayout()
        onV2Changed: {
            layoutSignature = "";
            relayout();
        }
        onPlacementChanged: root.controller.layoutChanged()

        // Where the compositor is asked to draw each window's surface (layout coordinates, Shell contract 3).
        function v2Rects(): var {
            const out = [];
            for (const w of wins) {
                const r = placedMap[w.address];
                if (!r || w.fullscreen)
                    continue;
                const s = V2.surfaceRect(r, w.w, bandOf(w), modelData.x, modelData.y, Tokens.menubarHeight);
                out.push({
                    address: w.address,
                    x: s.x,
                    y: s.y,
                    w: s.w,
                    h: s.h
                });
            }
            return out;
        }
        readonly property var placedMap: {
            const m = {};
            for (const r of placement.rects)
                m[r.id] = r;
            return m;
        }
        readonly property var tiles: spaces.concat([
            {
                plus: true,
                id: 0
            }
        ])
        // The Desktop thumbnails shrink to fit the band (macOS): the centred row keeps a gap clear of the "+" at the right edge
        // (the same room on the left keeps it centred), width, height and gap scaled together (UI audit 2026-11-05 U14).
        readonly property real tileRoom: (modelData ? modelData.width : 0) - 2 * (Tokens.overviewAddSize + Tokens.overviewAddEdgeInset + Tokens.overviewTileGap)
        readonly property real tileFullRow: (tiles.length - 1) * Tokens.overviewTileWidth + Math.max(0, tiles.length - 2) * Tokens.overviewTileGap
        readonly property real tileScale: tileFullRow > tileRoom && tileFullRow > 0 ? Math.max(0, tileRoom) / tileFullRow : 1
        readonly property real tileW: Tokens.overviewTileWidth * tileScale
        readonly property real tileH: Tokens.overviewTileHeight * tileScale
        readonly property real tileGap: Tokens.overviewTileGap * tileScale
        // The wallpaper this output's desktop shows, under every Desktop miniature (U29).
        readonly property var wallpaper: WallpaperState.lockBackdrop(screenName)
        // One device pixel: the borders and rules stay crisp at a fractional scale (UI audit 2026-11-05, LOW).
        readonly property real hairline: 1 / Math.max(1, modelData ? modelData.devicePixelRatio : 1)

        screen: modelData
        // Persistent: created once per screen and kept mapped (transparent, no input) between
        // opens, so opening does not pay for a new surface and its first frame.
        readonly property bool active: shown || progress > 0.001
        visible: true
        // Input only while the stage is "open": from the moment a close starts (the "releasing" stage, which `shown` still
        // counts as open, then the close animation, however long a busy GUI thread stretches them) a click belongs to the
        // window under it, as when any other full-screen surface closed (R13 finding M1 on 0f3adf7).
        readonly property bool takesInput: root.controller.stage === "open"
        mask: takesInput ? null : emptyMask
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        // qmllint disable unqualified unresolved-type
        margins.top: Tokens.menubarHeight
        // qmllint enable unqualified unresolved-type
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: holdsKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-overview"
        // qmllint disable missing-type
        // The full-screen blur is re-computed by the compositor every frame while the surface
        // animates (swap up to 1 s); it is applied only once the zoom-in has finished and dropped
        // when the zoom-out starts. The dim animates on its own meanwhile.
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && shown && progress >= 1 ? (v2 ? bandBlur : blur) : null
        // qmllint enable missing-type

        Region {
            id: emptyMask
        }

        Region {
            id: blur
            item: backdrop
        }

        // v2: the backdrop is its own surface, so the chrome only blurs behind the Desktops band.
        Region {
            id: bandBlur
            item: band
        }

        Behavior on progress {
            NumberAnimation {
                // Each step of a swipe is drawn as it comes; the rest of the way animates from there.
                duration: root.controller.gesture.active ? 0 : Appearance.duration(Tokens.motionSlow)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }
        }

        onLiveWinsChanged: {
            if (!liveWins)
                return;
            wins = liveWins;
            relayout();
            const keys = liveWins.map(w => w.address);
            if (keys.join(",") !== winKeys.join(",")) {
                // The window items are keyed by address (winModel): a window arriving or leaving creates or destroys only its
                // own item, the others glide to their new places. A dragged window that left takes its item and its drag
                // with it (no release or cancel comes): the drag ends here, else hover selection and the title stay off.
                if (dragKey !== "" && keys.indexOf(dragKey) < 0) {
                    dragKey = "";
                    dropIndex = -1;
                }
                winKeys = keys;
            }
            const map = {};
            for (const w of liveWins)
                map[w.address] = w;
            byKey = map;
        }

        onLiveSpacesChanged: {
            if (liveSpaces)
                spaces = liveSpaces;
        }

        onShownChanged: {
            if (shown) {
                dragKey = "";
                keys.forceActiveFocus();
            }
        }

        onHoldsKeyboardChanged: {
            if (holdsKeyboard)
                keys.forceActiveFocus();
        }

        // ---- Actions ----

        // A tile of the minimized strip chosen: the overview closes, then the window is restored and focused.
        function activateMinimized(index: int): void {
            const rec = minimizedItems[index];
            if (rec)
                root.controller.closeAnd({
                    kind: "minimized",
                    toplevel: rec.toplevel
                });
        }

        function activateWindow(key: string): void {
            const info = byKey[key];
            if (info)
                root.controller.closeAnd({
                    kind: "window",
                    address: info.address
                });
            else
                root.controller.closeAnd(null);
        }

        // Esc / backdrop: closes without a choice; the controller returns to the window that was active at open.
        function closeKeepingSpace(): void {
            root.controller.closeAnd(null);
        }

        function switchSpace(id: int): void {
            root.controller.closeAnd({
                kind: "space",
                id: id
            });
        }

        function addSpace(): void {
            // v2: the compositor ends its overview on a Space switch; the chrome stays on the new, empty Space.
            root.controller.switchingSpace = true;
            const id = Compositor.nextSpaceId();
            root.controller.stayOnSpace = id;
            Compositor.focusSpace(id);
        }

        // A Split View Desktop's name (tiling.md TL33): its apps, as macOS names a full-screen space ("Notes and Mail").
        function splitLabel(appIds: var): string {
            const names = (appIds || []).map(id => Apps.nameFor(id));
            if (names.length >= 2)
                return qsTr("%1 and %2").arg(names[0]).arg(names[1]);
            return names.length === 1 ? names[0] : qsTr("Full Screen");
        }

        function activateTile(index: int): void {
            const tile = tiles[index];
            if (!tile)
                return;
            if (tile.plus)
                addSpace();
            else
                switchSpace(tile.id);
        }

        // Tile index under a point in window coordinates, -1 for none.
        function tileIndexAt(point: point): int {
            for (let i = 0; i < tileRepeater.count; i++) {
                const item = tileRepeater.itemAt(i);
                if (!item)
                    continue;
                const p = item.mapFromItem(contentRoot, point.x, point.y);
                if (p.x >= 0 && p.y >= 0 && p.x <= item.width && p.y <= item.height)
                    return i;
            }
            return -1;
        }

        // A drop of window `key` on Desktop tile `index` moves it: not on "+", the Desktop shown, a Split View Desktop, nor for a
        // member of one (WindowTiling.dropAllowed, ADR-0036 D72).
        function dropAllowed(key: string, index: int): bool {
            const info = win.byKey[key];
            const tile = win.tiles[index];
            return !!info && !!tile && !tile.plus && !tile.active && WindowTiling.dropAllowed(TilingLink.splits, info.address, tile.id);
        }

        function dropWindow(key: string, index: int): void {
            if (win.dropAllowed(key, index))
                Compositor.moveGroupToSpace(win.byKey[key].address, win.tiles[index].id); // with its tile group (TL29)
        }

        // Overview.dropProbe's share (a dev-session test hook; the follow-up of #78: the drop rule had no test past
        // WindowTiling.dropAllowed): window `address` dropped on Desktop `spaceId` through this output's own drop path. "" when
        // this output's Overview shows neither; else "moved" or "refused" (dropAllowed), dropWindow having run either way.
        function probeDrop(address: string, spaceId: int): string {
            const key = Object.keys(win.byKey).find(k => WindowTiling.hexAddress(k) === WindowTiling.hexAddress(address)) ?? "";
            const index = win.tiles.findIndex(t => !t.plus && t.id === spaceId);
            if (key === "" || index < 0)
                return "";
            const allowed = win.dropAllowed(key, index);
            win.dropWindow(key, index);
            return allowed ? "moved" : "refused";
        }

        // Used by the controller's arrow-key navigation: the window next to `key` in a direction on this output ("" none).
        function neighborOf(key: string, dir: string): string {
            const rects = placement.rects;
            const at = rects.findIndex(r => r.id === key);
            if (at < 0)
                return "";
            const next = Layout.neighbor(rects, at, dir);
            return next >= 0 ? rects[next].id : "";
        }

        // Size of the laid-out area (the window below the menu bar) and the position (0..1) of a window's centre across
        // `dir`'s axis: what the next output's entry window is chosen from.
        function areaSize(): var {
            return {
                w: Math.max(1, modelData.width),
                h: Math.max(1, modelData.height - Tokens.menubarHeight)
            };
        }

        function crossFraction(key: string, dir: string): real {
            const r = placedMap[key];
            if (!r)
                return 0.5;
            const a = areaSize();
            return (dir === "left" || dir === "right") ? (r.y + r.h / 2) / a.h : (r.x + r.w / 2) / a.w;
        }

        function entryFor(dir: string, crossFrac: real): string {
            return V2.entryWindow(placement.rects, dir, crossFrac, areaSize());
        }

        function activeTileIndex(): int {
            return Math.max(0, spaces.findIndex(s => s.active));
        }

        // Test hook: the Desktop tiles (the Desktops, then "+") as laid out now, in OUTPUT coordinates (the window starts
        // below the menu bar): [{id, plus, active, x, y, w, h}]. Tests click these, never a copy of the layout constants.
        function tileRects(): var {
            const out = [];
            for (let i = 0; i < tileRepeater.count; i++) {
                const item = tileRepeater.itemAt(i) as Item;
                if (!item)
                    continue;
                const p = item.mapToItem(contentRoot, 0, 0);
                const t = tiles[i];
                out.push({
                    id: t.plus ? 0 : t.id,
                    plus: t.plus === true,
                    active: t.active === true,
                    x: Math.round(p.x),
                    y: Math.round(p.y + Tokens.menubarHeight),
                    w: Math.round(item.width),
                    h: Math.round(item.height)
                });
            }
            return out;
        }

        function statusData(): var {
            return {
                name: screenName,
                minimized: minimizedItems.map((m, i) => ({
                            address: m.address,
                            appId: m.appId,
                            title: m.title,
                            capture: captureInfo[m.address] ?? null,
                            rect: strip.rects[i] ? {
                                x: Math.round(strip.rects[i].x),
                                y: Math.round(strip.rects[i].y + Tokens.menubarHeight),
                                w: Math.round(strip.rects[i].w),
                                h: Math.round(strip.rects[i].h)
                            } : null
                        })),
                minFocus: minFocus,
                tileRects: tileRects(),
                v2: v2,
                v2Rects: v2 ? v2Rects() : [],
                width: width,
                height: height,
                progress: progress,
                scale: placement.scale,
                selected: selected,
                marked: marked,
                spaceFocus: spaceFocus,
                windows: wins.map(w => ({
                            address: w.address,
                            appId: w.appId,
                            title: w.title,
                            real: {
                                x: w.x,
                                y: w.y - Tokens.menubarHeight,
                                w: w.w,
                                h: w.h
                            },
                            rect: placedMap[w.address] ? {
                                x: placedMap[w.address].x,
                                y: placedMap[w.address].y,
                                w: placedMap[w.address].w,
                                h: placedMap[w.address].h
                            } : null
                        })),
                spaces: spaces.map(s => ({
                            id: s.id,
                            name: s.name,
                            active: s.active,
                            windowCount: s.windowCount
                        }))
            };
        }

        Item {
            id: contentRoot
            anchors.fill: parent
            visible: win.active
            Accessible.role: Accessible.Pane
            Accessible.name: qsTr("Overview")

            // The chrome holds the keyboard (wl_keyboard enter): the compositor accepts the layout from now on.
            readonly property bool chromeActive: Window.active
            onChromeActiveChanged: root.controller.onChromeChanged(win.screenName, chromeActive)

            // Closing (releasing, then the animation): a press the compositor still delivered here, before the empty mask
            // landed (late whenever the GUI thread was busy), is swallowed, never choosing the thumbnail under it. It never
            // stands between a click and a window: once the empty mask landed no press reaches this surface.
            MouseArea {
                anchors.fill: parent
                z: 1000
                visible: !win.takesInput
                acceptedButtons: Qt.AllButtons
            }

            // Dimmed, blurred backdrop (v1; v2 draws it on its own Bottom-layer surface, this one is transparent but
            // still takes the click). A click on it closes Overview.
            Rectangle {
                id: backdrop
                anchors.fill: parent
                color: win.v2 ? "transparent" : Appearance.withAlpha(Appearance.colors.shadow, Appearance.effectiveTransparency > 0 ? Tokens.overviewBackdropOpacity : Tokens.overviewBackdropOpacityOpaque)
                opacity: win.progress

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onPressed: {
                        win.closeKeepingSpace();
                    }
                }
            }

            // Keyboard: arrows move the selection, Return focuses, Tab cycles the Spaces bar, Esc closes.
            Item {
                id: keys
                focus: true
                Accessible.ignored: true

                Keys.onPressed: event => {
                    // Not open (releasing or closed): run nothing and let the key through.
                    if (!V2.keysEnabled(root.controller.stage)) {
                        event.accepted = false;
                        return;
                    }
                    const c = root.controller;
                    event.accepted = true;
                    switch (event.key) {
                    case Qt.Key_Escape:
                        // Release-then-act as for the other actions: staying on a Space just
                        // created with "+" instead of returning to the previous one.
                        win.closeKeepingSpace();
                        break;
                    case Qt.Key_Return:
                    case Qt.Key_Enter:
                        c.activateSelection();
                        break;
                    case Qt.Key_Tab:
                        c.cycle((event.modifiers & Qt.ShiftModifier) ? -1 : 1);
                        break;
                    case Qt.Key_Backtab:
                        c.cycle(-1);
                        break;
                    case Qt.Key_Left:
                        c.arrow("left");
                        break;
                    case Qt.Key_Right:
                        c.arrow("right");
                        break;
                    case Qt.Key_Down:
                        c.arrow("down");
                        break;
                    case Qt.Key_Up:
                        c.arrow("up");
                        break;
                    default:
                        event.accepted = false;
                    }
                }
            }

            // Desktops bar: a full-width band (macOS: tinted strip across the top, a hairline under it), the Desktop
            // thumbnails centred with their names under them, the round add button 18 from the right edge.
            Item {
                id: bar
                width: win.width
                height: Tokens.overviewBarHeight
                y: Appearance.reduceMotion ? 0 : -(1 - win.progress) * height
                opacity: win.progress
                Accessible.role: Accessible.List
                Accessible.name: qsTr("Desktops")

                // Thumbnails on clear glass (ADR-0024 section 2: the band's class, 0.15; ADR-0039 step 22).
                Material {
                    id: band
                    glassClass: "gallery"
                    anchors.fill: parent
                    radius: 0
                    shadowEnabled: false
                    highlightEnabled: false
                    borderEnabled: false

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: win.hairline
                        color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialSeparatorOpacity)
                    }

                    // The band is not a click-through: a click on it is not "outside the windows".
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.AllButtons
                    }
                }

                Repeater {
                    id: tileRepeater
                    model: win.tiles

                    delegate: Item {
                        id: tile

                        required property var modelData
                        required property int index

                        readonly property bool isPlus: modelData.plus === true
                        readonly property bool dropTarget: win.dragKey !== "" && win.dropIndex === index && win.dropAllowed(win.dragKey, index)
                        readonly property bool focused: win.spaceFocus === index
                        readonly property int count: win.tiles.length - 1
                        readonly property real rowWidth: count * win.tileW + Math.max(0, count - 1) * win.tileGap

                        // Thumbnails centred on the band (shrunk to fit it, win.tileScale); the add button is a round 32 button at
                        // the right edge.
                        width: isPlus ? Tokens.overviewAddSize : win.tileW
                        height: isPlus ? Tokens.overviewAddSize : win.tileH + Tokens.overviewTileLabelGap + Tokens.overviewTileLabelHeight
                        x: isPlus ? win.width - Tokens.overviewAddSize - Tokens.overviewAddEdgeInset : (win.width - rowWidth) / 2 + index * (win.tileW + win.tileGap)
                        y: isPlus ? Tokens.overviewBarTopMargin + (win.tileH - Tokens.overviewAddSize) / 2 : Tokens.overviewBarTopMargin
                        Accessible.role: Accessible.Button
                        // Desktops are numbered by position (macOS), never by the compositor's workspace id; a Split View Desktop
                        // takes no number and is named after its apps (Compositor.spacesOn, tiling.md TL33).
                        readonly property string tileLabel: isPlus ? "" : modelData.split ? win.splitLabel(modelData.appIds) : qsTr("Desktop %1").arg(modelData.number)
                        Accessible.name: isPlus ? qsTr("Add Desktop") : tileLabel
                        Accessible.onPressAction: win.activateTile(index)

                        Rectangle {
                            id: face
                            height: tile.isPlus ? Tokens.overviewAddSize : win.tileH
                            width: tile.isPlus ? Tokens.overviewAddSize : win.tileW
                            radius: tile.isPlus ? height / 2 : Tokens.overviewThumbRadius
                            // The add button is a bare plus at rest (macOS 27), a light glass circle under the pointer; a thumbnail
                            // the material's fill at rest, the neutral selection of an item on glass under the pointer or as a drop
                            // target (which also takes the ring; one role each, ADR-0039 step 12, G6).
                            readonly property bool plusLit: tile.isPlus && (tileMouse.containsMouse || tile.focused)
                            color: tile.isPlus ? (face.plusLit ? Appearance.withAlpha(Appearance.colors.knob, Appearance.dark ? Tokens.overviewAddFillOpacityDark : Tokens.overviewAddFillOpacity) : "transparent")
                                : tile.dropTarget || tileMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialSelectionOpacity)
                                : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                            border.width: tile.isPlus && !face.plusLit ? 0 : win.hairline
                            border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

                            // Selection ring outside the thumbnail (macOS), so the picture keeps its size.
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: -Tokens.overviewSelectionWidth - Tokens.overviewRingGap
                                radius: parent.radius + Tokens.overviewSelectionWidth + Tokens.overviewRingGap
                                color: "transparent"
                                visible: tile.modelData.active || tile.focused || tile.dropTarget
                                border.width: Tokens.overviewSelectionWidth
                                // The focus ring colour, as every ring (ADR-0039 step 7).
                                border.color: Appearance.focusRingColor
                            }

                            // A real miniature of the desktop: its windows at their place, captured (macOS), not a grey tile with icons.
                            MiniDesktop {
                                visible: !tile.isPlus
                                anchors.fill: parent
                                anchors.margins: face.border.width
                                windows: tile.isPlus ? [] : tile.modelData.windows
                                screenW: tile.isPlus ? 0 : tile.modelData.screenW
                                screenH: tile.isPlus ? 0 : tile.modelData.screenH
                                capture: !tile.modelData.active
                                wallpaper: win.wallpaper
                                radius: face.radius - face.border.width
                            }

                            Icon {
                                visible: tile.isPlus
                                anchors.centerIn: parent
                                size: Tokens.overviewAddGlyphSize
                                name: "plus"
                                color: Appearance.colors.text
                            }
                        }

                        Text {
                            visible: !tile.isPlus
                            anchors.top: face.bottom
                            anchors.topMargin: Tokens.overviewTileLabelGap
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            text: tile.tileLabel
                            textFormat: Text.PlainText
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            font.weight: tile.modelData.active ? Tokens.typographyMenuWeight : Tokens.typographySmallWeight
                        }

                        MouseArea {
                            id: tileMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                win.activateTile(tile.index);
                            }
                        }
                    }
                }
            }

            // Window thumbnails (v1) or hit areas of the transformed real windows (v2). Keyed by window address (audit A-06): a
            // window opening or closing while Overview is open adds or removes its own item only; the others keep their item,
            // their capture and a drag in progress, and glide to the new layout (the tx/ty/tw/th Behaviors).
            Repeater {
                model: ScriptModel {
                    id: winModel
                    values: win.winKeys.map(k => ({
                                address: k
                            }))
                    objectProp: "address"
                }

                delegate: Item {
                    id: thumb

                    required property var modelData
                    readonly property string key: modelData.address

                    readonly property var info: win.byKey[key]
                    readonly property var target: win.placedMap[key]
                    readonly property bool valid: info !== undefined && target !== undefined
                    readonly property bool isSelected: win.marked === key && win.spaceFocus < 0 && win.minFocus < 0
                    readonly property bool dragging: win.dragKey === key

                    // Layout rectangle, animated when the layout changes while open.
                    property real tx: target ? target.x : 0
                    property real ty: target ? target.y : 0
                    property real tw: target ? target.w : 1
                    property real th: target ? target.h : 1
                    property real ox: 0
                    property real oy: 0

                    readonly property real realX: info ? info.x : 0
                    readonly property real realY: info ? info.y - Tokens.menubarHeight : 0
                    readonly property real realW: info ? info.w : 1
                    readonly property real realH: info ? info.h : 1

                    readonly property bool v2: win.v2
                    visible: valid
                    // v2: the compositor animates the real window; the item sits at its final rectangle.
                    x: v2 ? tx + ox : realX + (tx - realX) * win.zoom + ox
                    y: v2 ? ty + oy : realY + (ty - realY) * win.zoom + oy
                    width: v2 ? Math.max(1, tw) : Math.max(1, realW + (tw - realW) * win.zoom)
                    height: v2 ? Math.max(1, th) : Math.max(1, realH + (th - realH) * win.zoom)
                    z: dragging ? 100 : (isSelected ? 2 : 1)
                    opacity: (dragging ? Tokens.overviewDragOpacity : 1) * (Appearance.reduceMotion ? win.progress : 1) * appear
                    // A window that opens while Overview is open fades in at its place while the others make room.
                    property real appear: 1
                    Component.onCompleted: {
                        if (win.progress >= 1 && !Appearance.reduceMotion) {
                            appear = 0;
                            appearAnim.start();
                        }
                    }
                    NumberAnimation {
                        id: appearAnim
                        target: thumb
                        property: "appear"
                        to: 1
                        duration: Appearance.duration(Tokens.motionNormal)
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.curveEnter
                    }
                    Accessible.role: Accessible.Button
                    Accessible.name: info ? (info.title !== "" ? info.title : Apps.nameFor(info.appId)) : ""
                    Accessible.onPressAction: win.activateWindow(key)

                    // The tiles re-lay out and settle back after a drag; under Reduce Motion they jump (ADR-0039 step 5).
                    Behavior on tx {
                        enabled: win.progress >= 1 && !Appearance.reduceMotion
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.curve
                        }
                    }
                    Behavior on ty {
                        enabled: win.progress >= 1 && !Appearance.reduceMotion
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.curve
                        }
                    }
                    Behavior on tw {
                        enabled: win.progress >= 1 && !Appearance.reduceMotion
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.curve
                        }
                    }
                    Behavior on th {
                        enabled: win.progress >= 1 && !Appearance.reduceMotion
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.curve
                        }
                    }
                    Behavior on ox {
                        enabled: !thumb.dragging && !Appearance.reduceMotion
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionFast)
                        }
                    }
                    Behavior on oy {
                        enabled: !thumb.dragging && !Appearance.reduceMotion
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionFast)
                        }
                    }

                    // The live content at a fixed size, scaled to the item (audit A-11): the zoom changes the
                    // scale only, so the two offscreen layers (mask, clipper) are allocated once, not on every frame of the open and
                    // close animation. The radius is the token as drawn, whatever the scale.
                    Item {
                        id: content
                        objectName: "thumbContent"
                        visible: !thumb.v2
                        // The larger of the two ends of the zoom (the real window, its place in the layout): scaled down, never up.
                        width: Math.max(1, thumb.tw, thumb.realW)
                        height: Math.max(1, thumb.th, thumb.realH)
                        transform: Scale {
                            xScale: thumb.width / content.width
                            yScale: thumb.height / content.height
                        }

                        // Rounded mask for the live content.
                        Rectangle {
                            id: maskShape
                            anchors.fill: parent
                            radius: Tokens.overviewThumbRadius * content.width / Math.max(1, thumb.width)
                            visible: false
                            layer.enabled: !thumb.v2
                        }

                        Item {
                            id: clipper
                            anchors.fill: parent
                            layer.enabled: !thumb.v2
                            layer.effect: MultiEffect {
                                maskEnabled: true
                                maskSource: maskShape
                            }

                            Rectangle {
                                anchors.fill: parent
                                color: Appearance.withAlpha(Appearance.colors.materialTint, 1)
                            }

                            ScreencopyView {
                                id: view
                                anchors.fill: parent
                                captureSource: thumb.info && !thumb.v2 ? thumb.info.toplevel : null
                                live: root.controller.profile === "full"
                                paintCursor: false
                                // A single frame can only be requested once the capture context knows
                                // the buffer size (sourceSize); earlier calls warn "Cannot capture frame".
                                readonly property bool ready: captureSource !== null && sourceSize.width > 0 && sourceSize.height > 0
                                property bool snapshotTaken: false
                                function snapshot(): void {
                                    if (!live && ready && !snapshotTaken) {
                                        snapshotTaken = true;
                                        captureFrame();
                                    }
                                }
                                onReadyChanged: snapshot()
                                onLiveChanged: snapshot()
                                onCaptureSourceChanged: snapshotTaken = false
                            }
                        }
                    }

                    // Balanced profile: one captured frame every balancedIntervalMs.
                    Timer {
                        interval: Tokens.overviewBalancedIntervalMs
                        repeat: true
                        running: root.controller.profile === "balanced" && win.shown && thumb.visible && view.ready && !thumb.v2
                        onTriggered: {
                            view.captureFrame();
                        }
                    }

                    // v2: the dragged window stays where the compositor draws it; this ghost follows the pointer.
                    Rectangle {
                        anchors.fill: parent
                        radius: Tokens.overviewThumbRadius
                        color: Appearance.withAlpha(Appearance.colors.accent, Tokens.materialFillOpacity)
                        border.width: Tokens.overviewSelectionWidth
                        border.color: Appearance.colors.accent
                        visible: thumb.v2 && thumb.dragging
                    }

                    // Selection / hover outline: one ring outside the window, the Desktop tiles' gap clear of it (UI audit
                    // 2026-11-05, LOW: one ring model for the windows, the Desktops and Stages).
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -Tokens.overviewSelectionWidth - Tokens.overviewRingGap
                        radius: Tokens.overviewThumbRadius + Tokens.overviewSelectionWidth + Tokens.overviewRingGap
                        color: "transparent"
                        border.width: Tokens.overviewSelectionWidth
                        border.color: Appearance.focusRingColor
                        visible: thumb.isSelected
                    }

                    MouseArea {
                        id: thumbMouse
                        property point pressAt: Qt.point(0, 0)
                        property bool moved: false

                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton
                        onEntered: {
                            if (win.dragKey === "")
                                root.controller.hoverSelect(thumb.key);
                        }
                        onPressed: mouse => {
                            pressAt = mapToItem(contentRoot, mouse.x, mouse.y);
                            moved = false;
                        }
                        onPositionChanged: mouse => {
                            if (!pressed)
                                return;
                            const p = mapToItem(contentRoot, mouse.x, mouse.y);
                            const dx = p.x - pressAt.x;
                            const dy = p.y - pressAt.y;
                            if (!moved && Math.hypot(dx, dy) > Tokens.overviewDragThreshold) {
                                moved = true;
                                win.dragKey = thumb.key;
                            }
                            if (moved) {
                                thumb.ox = dx;
                                thumb.oy = dy;
                                win.dragPoint = p;
                                win.dropIndex = win.tileIndexAt(p);
                            }
                        }
                        onReleased: mouse => {
                            if (!moved) {
                                win.activateWindow(thumb.key);
                                return;
                            }
                            const index = win.tileIndexAt(mapToItem(contentRoot, mouse.x, mouse.y));
                            const key = thumb.key;
                            win.dragKey = "";
                            win.dropIndex = -1;
                            thumb.ox = 0;
                            thumb.oy = 0;
                            if (index >= 0)
                                win.dropWindow(key, index);
                        }
                        onCanceled: {
                            win.dragKey = "";
                            win.dropIndex = -1;
                            thumb.ox = 0;
                            thumb.oy = 0;
                        }
                    }
                }
            }

            // Minimized windows: a hairline divider and a row of smaller tiles below the open windows (macOS Mission Control).
            // Clicking one (or Return on it) closes the overview and restores that window.
            Rectangle {
                visible: win.minimizedItems.length > 0
                x: win.strip.rects.length > 0 ? win.strip.rects[0].x : 0
                y: win.strip.dividerY
                width: win.strip.rects.length > 0 ? win.strip.rects[win.strip.rects.length - 1].x + win.strip.rects[win.strip.rects.length - 1].w - x : 0
                height: win.hairline
                opacity: win.progress
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                Accessible.ignored: true
            }

            Repeater {
                    model: win.minimizedItems

                delegate: Item {
                    id: mini

                    required property var modelData
                    required property int index

                    readonly property var box: win.strip.rects[index] ? win.strip.rects[index] : ({x: 0, y: 0, w: 1, h: 1})
                    readonly property var entry: Apps.lookup(modelData.appId)
                    readonly property string name: modelData.title !== "" ? modelData.title : Apps.nameFor(modelData.appId)
                    readonly property bool focused: win.minFocus === index
                    readonly property bool live: root.controller.profile === "full"
                    readonly property var capture: miniView.capture
                    onCaptureChanged: {
                        const all = Object.assign({}, win.captureInfo);
                        all[mini.modelData.address] = capture;
                        win.captureInfo = all;
                    }

                    x: box.x
                    y: box.y
                    width: box.w
                    height: box.h + Tokens.overviewMinimizedLabelHeight
                    opacity: win.progress
                    Accessible.role: Accessible.Button
                    Accessible.name: qsTr("%1, minimized").arg(name)
                    Accessible.onPressAction: win.activateMinimized(index)

                    Rectangle {
                        id: plate
                        width: mini.width
                        height: mini.box.h
                        radius: Tokens.overviewThumbRadius
                        // The panel's fill at rest; the neutral selection of an item on glass under the pointer or the keyboard
                        // (one role each, ADR-0039 step 12, G6).
                        color: mini.focused || miniMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialSelectionOpacity)
                            : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                        border.width: mini.focused || miniMouse.containsMouse ? Tokens.overviewSelectionWidth : win.hairline
                        border.color: mini.focused || miniMouse.containsMouse ? Appearance.focusRingColor : Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

                        ScreencopyView {
                            // Fit inside the plate keeping the aspect ratio; live only in the full profile (a still icon otherwise).
                            readonly property real ratio: implicitWidth > 0 && implicitHeight > 0 ? implicitWidth / implicitHeight : 1
                            readonly property real room: Math.max(1, parent.width - 2 * Tokens.spacingXs)
                            readonly property real roomH: Math.max(1, parent.height - 2 * Tokens.spacingXs)
                            visible: mini.live && hasContent
                            width: ratio >= room / roomH ? room : roomH * ratio
                            height: ratio >= room / roomH ? room / ratio : roomH
                            anchors.centerIn: parent
                            id: miniView
                            // A minimized window does not change: ONE frame is captured, not a live stream (a capture per frame of up to
                            // Tokens.overviewMinimizedMax windows at full resolution was the cost). `constraintSize` is the
                            // tile size for what it limits (the size Quickshell reports for the view; whether the compositor is
                            // asked for a smaller buffer is measured by `overview status` -> minimized[].capture in a nested run).
                            constraintSize: Qt.size(Math.ceil(parent.width), Math.ceil(parent.height))
                            captureSource: mini.live && win.shown ? mini.modelData.toplevel : null
                            live: false
                            paintCursor: false
                            readonly property bool ready: captureSource !== null && sourceSize.width > 0 && sourceSize.height > 0
                            onReadyChanged: if (ready)
                                captureFrame()
                            // Test hook data: what was asked and what came.
                            readonly property var capture: ({
                                    source: [sourceSize.width, sourceSize.height],
                                    implicit: [Math.round(implicitWidth), Math.round(implicitHeight)],
                                    constraint: [Math.round(constraintSize.width), Math.round(constraintSize.height)]
                                })
                        }

                        TintedIcon {
                            anchors.centerIn: parent
                            size: Math.round(parent.height * Tokens.dockMinimizedBadgeScale * 1.5)
                            source: ThemeIcons.appIcon(mini.entry ? mini.entry.icon : mini.modelData.appId, "application-x-executable")
                            asynchronous: true
                        }
                    }

                    Text {
                        anchors.top: plate.bottom
                        anchors.topMargin: Tokens.spacingXs
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        text: mini.name
                        textFormat: Text.PlainText
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                        font.weight: mini.focused ? Tokens.typographyMenuWeight : Tokens.typographySmallWeight
                    }

                    MouseArea {
                        id: miniMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton
                        onClicked: win.activateMinimized(mini.index)
                    }
                }
            }

            // App icon and window title under the selected (hovered) window, the app's name for a window without a title (macOS
            // Mission Control names the hovered window; UI audit 2026-11-05, LOW). Shown only for that window, as macOS.
            // The window's name on a plate: a text surface, the menus' class (ADR-0039 step 22).
            Material {
                id: label
                glassClass: "menu"

                readonly property var info: win.marked !== "" && win.spaceFocus < 0 ? win.byKey[win.marked] : undefined
                readonly property var rect: win.marked !== "" ? win.placedMap[win.marked] : undefined
                readonly property var entry: info ? Apps.lookup(info.appId) : null
                readonly property string appName: info ? Apps.nameFor(info.appId) : ""
                readonly property string title: info && info.title !== "" ? info.title : appName

                visible: info !== undefined && rect !== undefined && box !== null && win.dragKey === ""
                opacity: win.progress >= 1 ? 1 : 0
                radius: Tokens.overviewLabelHeight / 2
                shadowEnabled: false
                width: Math.min(Tokens.overviewLabelMaxWidth, labelRow.implicitWidth + 2 * Tokens.spacingMd)
                height: Tokens.overviewLabelHeight
                // Never over another window's rectangle (Layout.labelRect).
                // The rectangle's index in the placement: placedMap and placement change in one step, but a binding can read one before
                // the other is re-evaluated (-1 then: no label for that turn, not a TypeError).
                readonly property int at: rect ? win.placement.rects.indexOf(rect) : -1
                readonly property var box: at >= 0 ? Layout.labelRect(win.placement.rects, at, width, height, Tokens.spacingSm, {
                    w: win.width,
                    h: win.height
                }) : null
                x: box ? box.x : 0
                y: box ? box.y : 0
                z: 50
                Accessible.role: Accessible.StaticText
                Accessible.name: title

                Behavior on opacity {
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.motionFast)
                    }
                }

                Row {
                    id: labelRow
                    anchors.centerIn: parent
                    spacing: Tokens.spacingSm

                    TintedIcon {
                        size: Tokens.overviewLabelIconSize
                        anchors.verticalCenter: parent.verticalCenter
                        source: ThemeIcons.appIcon(label.entry ? label.entry.icon : "", "application-x-executable")
                        asynchronous: true
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, Tokens.overviewLabelMaxWidth - 2 * Tokens.spacingMd - Tokens.overviewLabelIconSize - Tokens.spacingSm)
                        text: label.title
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                        font.weight: Tokens.typographyMenuWeight
                    }
                }
            }
        }
    }
}
