pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services
import qs.widgets
import "CenterLogic.js" as CenterLogic

// Notifications column (N7, internal Notification Center): the macOS model. No full-height panel:
// a column of floating glass cards as wide as a banner, at the right under the menu bar, opened from the clock or
// by IPC. No title: the cards grouped by app, newest first (the first card of a group carries the app name, its
// count and, on hover or focus, "Show Less" and a round x that grows into a "Clear All" pill; the last visible
// one carries Show All), then the widgets placed there; a footer of an Edit Widgets pill (gallery overlay,
// docs/specs/widgets.md) and a close circle, centred one spacing.lg below the last card. No permanent global Clear All
// (macOS 26 model): a card shows a round x at its top-left corner on hover or focus. A clear takes effect in the
// model at once (history, "No Notifications", persistence); the column only animates it: the removed cards slide out
// to the right while they fade (ListView remove transition) and the cards below glide up, so closing
// the column mid-animation never loses a clear. A card that arrives while the column is open slides in and fades in.
// Reduce Motion: nothing slides, cards only fade (Appearance.duration caps the fade). Every card is its own surface with its own blur region
// (registered by the card, see addSurface). Esc or a click outside the cards closes.
//
// The window exists per screen but its content (a Loader) only while the Center is open on that
// screen, so a closed Center costs nothing. Rows come from the keyed Notifications.centerModel
// (displayed rows only, ordered by group; the first row of a group draws its header), so new notifications never rebuild the list.
// Keyboard: Tab moves between rows and buttons in visual order (tabStep), Return opens the row's default action, Delete or
// Backspace clears the row and moves focus to the next card (the previous one when it was the last); each card's
// x and the group controls are reachable with Tab.
Variants {
    id: root

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property bool open: Notifications.centerOpen && Notifications.centerScreen === (modelData ? modelData.name : "")

        screen: modelData
        // Mapped a moment longer than it holds the keyboard: a layer destroyed while Exclusive leaves the compositor with no
        // keyboard focus.
        visible: release.mapped
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-notification-center"
        // Everything except the menu bar strip receives input while open (the clock toggles the panel); nothing once it
        // closed: the surface stays mapped a moment for the keyboard release, and a click in that moment belongs to the
        // window under it.
        // qmllint disable missing-type
        mask: win.open ? openMask : passThrough
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.open && content.item ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            regions: content.item ? (content.item as CenterContent).regionList : []
        }

        Region {
            id: openMask
            width: win.width
            height: win.height

            Region {
                width: win.width
                height: Tokens.menubarHeight
                intersection: Intersection.Subtract
            }
        }

        Region {
            id: passThrough
        }

        KeyboardRelease {
            id: release
            shown: win.open
        }

        // A popup (menus, Control Center) takes over.
        Connections {
            target: Popups

            function onKindChanged(): void {
                if (Popups.active)
                    Notifications.closeCenter();
            }
        }

        // Every input handler of the center is in CenterContent, unloaded as soon as it closes: a press that reaches the
        // surface during its keyboard release finds nothing to act on, so no swallowing area is needed here (unlike Search,
        // Apps, the Overlay, the switcher and the Overview, whose content stays loaded while they close).
        Loader {
            id: content
            anchors.fill: parent
            active: win.open
            sourceComponent: CenterContent {}
        }

        // Glass pill of the footer.
        component Pill: Item {
            id: pill

            // The CenterContent that owns the blur regions.
            required property var surfaceHost
            property string text: ""
            // The area its glass is judged over (the column at rest): the pill moves with the column's slide, which its
            // Material does not see, so a measured rect would be the one of the column's first, off-screen frame (audit B-13).
            property alias backdropRect: pillSurface.backdropRect

            signal clicked

            implicitWidth: Math.max(Tokens.notificationCenterPillWidth, label.implicitWidth + 2 * Tokens.spacingMd)
            implicitHeight: Tokens.notificationCenterPillHeight
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: pill.text
            Accessible.focusable: true
            // Accessibility press and keys act only while the pill is shown and enabled (R12).
            Accessible.onPressAction: if (pill.visible && pill.enabled)
                pill.clicked()
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (pill.visible && pill.enabled)
                        pill.clicked();
                    event.accepted = true;
                }
            }

            Material {
                id: pillSurface
                glassClass: "notification"
                anchors.fill: parent
                radius: height / 2
                shadowEnabled: false
                Component.onCompleted: pill.surfaceHost.addSurface(pillSurface, false, Math.floor(height / 2), null)
            }

            Text {
                id: label
                anchors.centerIn: parent
                width: Math.min(implicitWidth, parent.width - 2 * Tokens.spacingSm)
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: pill.text
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.notificationPillTextSize
                font.weight: Tokens.typographyMenuWeight
            }

            // The shared ring outside the pill, after a key only (ADR-0039 step 7).
            KeyFocus {
                id: pillFocus
            }

            FocusRing {
                shapeRadius: height / 2
                visible: pillFocus.active
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.ArrowCursor
                onClicked: pill.clicked()
            }
        }

        component CenterContent: Item {
            id: hostItem

            readonly property Item panel: panelItem
            // The column's surface holds the keyboard (the compositor sent it the focus after the Exclusive layer
            // mapped, which is a moment later than the open): reported for the test status line.
            readonly property bool keyboardHeld: Window.active
            // Per output: the name of the output whose content holds it (Notifications.centerKeyboardScreen).
            onKeyboardHeldChanged: hostItem.report(keyboardHeld)
            Component.onDestruction: hostItem.report(false)
            function report(held: bool): void {
                const name = (win.modelData ? win.modelData.name : "");
                if (held)
                    Notifications.centerKeyboardScreen = name;
                else if (Notifications.centerKeyboardScreen === name)
                    Notifications.centerKeyboardScreen = "";
            }
            // One blur region per glass surface (cards, title capsule, widgets, footer).
            readonly property var regionList: regions.instances
            // Slides in from the right edge after creation.
            property bool shown: false
            // Registered glass surfaces: {id, item, clip (inside the list viewport), radius, fader (the card whose
            // opacity the blur follows, or null)}. Destroyed items read as null and are dropped a little after a row
            // left, and when a surface registers. Every record carries a unique id: Variants ignores (and warns
            // about) equal values, which dead records ({item: null, ...}) otherwise are.
            property var surfaces: []
            property int surfaceSeq: 0
            // Anything that moves or resizes a surface without changing its own geometry (list.motionTick counts the
            // frames of a card sliding or of the column reflowing).
            readonly property real tick: list.contentY + list.contentHeight + list.count + list.height + panelItem.x + panelItem.y + list.motionTick + gallery.x + gallery.y + (gallery.item ? 1 : 0)
            // The app the pointer is over (group controls), and how many hover handlers of each app are active.
            property string hoverApp: ""
            property var hoverCounts: ({})

            Timer {
                id: hoverRelease
                interval: Appearance.duration(Tokens.motionFast)
                onTriggered: {
                    if (!CenterLogic.isHovered(hostItem.hoverCounts, hostItem.hoverApp))
                        hostItem.hoverApp = "";
                }
            }

            // Drops the records of destroyed cards (their slide-out has ended).
            Timer {
                id: pruneSurfaces
                interval: 2 * Appearance.duration(Tokens.motionNormal) + 1
                onTriggered: hostItem.surfaces = hostItem.surfaces.filter(r => r.item)
            }

            // A pointer on a card of an app group (the card or the x on its corner), or leaving it (a short grace
            // covers the gap between two cards). Counted per hover handler: the x sticks out of the card, so the pointer
            // can enter the x before it leaves the card or the other way round.
            function hoverCard(app: string, over: bool): void {
                hoverCounts = CenterLogic.hoverStep(hoverCounts, app, over);
                if (over) {
                    hoverRelease.stop();
                    hoverApp = app;
                } else if (hoverApp === app && !CenterLogic.isHovered(hoverCounts, app)) {
                    hoverRelease.restart();
                }
            }

            // Where the list's viewport is in the window, read once per tick for every clipped surface (each region mapped
            // it again, every frame of a motion: audit note on the Center's regions).
            readonly property point viewport: {
                hostItem.tick;
                return list.mapToItem(null, 0, 0);
            }

            function addSurface(item: Item, clip: bool, radius: real, fader: Item): void {
                surfaceSeq++;
                surfaces = surfaces.filter(r => r.item).concat([{id: surfaceSeq, item: item, clip: clip, radius: radius, fader: fader}]);
            }

            // Rectangle of a surface in window coordinates, cut to the list viewport for rows (left and right too: a card
            // sliding out stops at the column edge) and shrunk about its centre as its card fades, so the blur never
            // outlives the glass.
            function rectOf(rec: var): rect {
                const it = rec.item as Item;
                if (!it)
                    return Qt.rect(0, 0, 0, 0);
                // A card that has faded out has no glass left: nothing to map.
                const fade = rec.fader as Item;
                if (fade && fade.opacity <= 0)
                    return Qt.rect(0, 0, 0, 0);
                const p = it.mapToItem(null, 0, 0);
                let left = p.x;
                let right = p.x + it.width;
                let top = p.y;
                let bottom = p.y + it.height;
                if (rec.clip) {
                    const v = hostItem.viewport;
                    left = Math.max(left, v.x);
                    right = Math.min(right, v.x + list.width);
                    top = Math.max(top, v.y);
                    bottom = Math.min(bottom, v.y + list.height);
                }
                const w = Math.max(0, right - left);
                const h = Math.max(0, bottom - top);
                const fader = rec.fader as Item;
                const f = fader ? Math.max(0, Math.min(1, fader.opacity)) : 1;
                return Qt.rect(left + w * (1 - f) / 2, top + h * (1 - f) / 2, w * f, h * f);
            }

            function overSurface(x: real, y: real): bool {
                for (const rec of surfaces) {
                    const r = rectOf(rec);
                    if (x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height)
                        return true;
                }
                return false;
            }

            Component.onCompleted: {
                shown = true;
                panelItem.forceActiveFocus();
                glideStart.restart();
                hostItem.takeGalleryRequest();
            }

            // Edit Widgets… on the desktop (Notifications.openWidgetGallery): the gallery opens with the column.
            function takeGalleryRequest(): void {
                if (!Notifications.galleryWanted)
                    return;
                Notifications.galleryWanted = false;
                panelItem.galleryOpen = true;
            }

            Connections {
                target: Notifications

                function onGalleryWantedChanged(): void {
                    hostItem.takeGalleryRequest();
                }
            }

            // The footer glides with the cards only once the column has slid in: its first layout (the list growing from
            // nothing) is not a motion.
            Timer {
                id: glideStart
                interval: Appearance.duration(Tokens.motionNormal)
                onTriggered: panelItem.glide = true
            }

            Variants {
                id: regions
                model: hostItem.surfaces

                Region {
                    id: region

                    required property var modelData
                    readonly property rect box: {
                        hostItem.tick;
                        return hostItem.rectOf(region.modelData);
                    }

                    x: Math.round(box.x)
                    y: Math.round(box.y)
                    width: Math.round(box.width)
                    height: Math.round(box.height)
                    radius: region.modelData.radius
                }
            }

            // A click outside every card closes; a click on a card or the title capsule does not.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: mouse => {
                    if (!hostItem.overSurface(mouse.x, mouse.y))
                        Notifications.closeCenter();
                }
            }

            FocusScope {
                id: panelItem

                // Widgets: the gallery overlay, the context menu of a placed widget and the Weather widget's Edit Location…
                // popover (ADR-0045 OC-14), which opens where the menu was.
                property bool galleryOpen: false
                property var menuEntry: null
                property var editEntry: null
                property real menuX: 0
                property real menuY: 0
                property Item menuReturn: null
                // Room left of the cards for the x of a card, which sticks out of its top-left corner (the list is that
                // much wider and taller; the cards keep their place).
                readonly property int gutter: Math.ceil(Tokens.notificationCloseSize / 3)

                function openWidgetMenu(tile: Item, x: real, y: real, entry: var): void {
                    const p = tile.mapToItem(panelItem, x, y);
                    menuX = p.x;
                    menuY = p.y;
                    menuReturn = tile;
                    menuEntry = entry;
                }

                function closeWidgetMenu(): void {
                    menuEntry = null;
                    editEntry = null;
                    if (menuReturn)
                        menuReturn.forceActiveFocus();
                    else
                        panelItem.forceActiveFocus();
                }

                function applyWidgetMenu(action: string): void {
                    const entry = menuEntry;
                    if (entry && action === "weather:location") {
                        editEntry = entry;
                        menuEntry = null;
                        return;
                    }
                    menuEntry = null;
                    panelItem.forceActiveFocus();
                    if (!entry)
                        return;
                    if (action === "remove")
                        Widgets.remove(entry.uid);
                    else if (action.startsWith("size:"))
                        Widgets.setSize(entry.uid, action.substring(5));
                    else if (action === "move:up")
                        Widgets.stepCenter(entry.uid, -1);
                    else if (action === "move:down")
                        Widgets.stepCenter(entry.uid, 1);
                }

                // Only the slide animates (macOS: the column comes in from the right edge). The column's place follows
                // the window at once: the window can still be 0 wide when the column is created, and animating x then
                // swept the column across the whole screen from the left (owner, real session 2026-10-22). Under Reduce
                // Motion the column fades in at its place instead (macOS: slides become fades; ADR-0039 step 5).
                property real slideOffset: hostItem.shown || Appearance.reduceMotion ? 0 : width + Tokens.notificationCenterInset
                property bool glide: false
                // The column at rest on the output (the window covers it): every card's glass is judged over this area, wherever
                // the list scrolls it (G-3 per surface).
                readonly property rect restRect: Qt.rect(hostItem.width - width - Tokens.notificationCenterInset, y, width, height)
                x: hostItem.width - width - Tokens.notificationCenterInset + slideOffset
                y: Tokens.menubarHeight + Tokens.notificationCenterInset
                width: Tokens.notificationCenterWidth
                height: hostItem.height - y - Tokens.notificationCenterInset
                Accessible.role: Accessible.Window
                Accessible.name: qsTr("Notifications")
                Keys.onEscapePressed: Notifications.closeCenter()

                // Tab and Shift+Tab reach every card in visual order (ListView.tabStep). A shortcut, because Qt moves the
                // focus along its own chain as soon as the focused item leaves the key unhandled, before any parent
                // sees it. Off while the widget gallery, a widget menu or the location popover has the keyboard.
                Shortcut {
                    sequence: "Tab"
                    enabled: win.open && !panelItem.galleryOpen && panelItem.menuEntry === null && panelItem.editEntry === null
                    onActivated: list.tabStep(true)
                }

                Shortcut {
                    sequences: ["Shift+Tab", "Backtab"]
                    enabled: win.open && !panelItem.galleryOpen && panelItem.menuEntry === null && panelItem.editEntry === null
                    onActivated: list.tabStep(false)
                }

                opacity: hostItem.shown || !Appearance.reduceMotion ? 1 : 0

                Behavior on opacity {
                    enabled: Appearance.reduceMotion
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.motionNormal)
                    }
                }

                // A panel arriving or leaving: the panel motion (Apple's default spring as a stand-in, ADR-0039 Q6, step 20).
                Behavior on slideOffset {
                    enabled: !Appearance.reduceMotion
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.motionPanel)
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.curvePanel
                    }
                }

                // "Notification Center" title row above the cards while there are any (macOS 27, owner decision 2026-10-26), with a
                // round x that clears them all. The title sits straight on the wallpaper in the ink that keeps 4.5:1 over what is
                // under it (GlassTint.inkOn over the output's luminance grid); on a glass plate when that is unknown or mixed (A2).
                Item {
                    id: titleRow

                    readonly property bool shown: list.count > 0
                    readonly property rect area: Qt.rect(panelItem.restRect.x, panelItem.restRect.y, panelItem.width, Tokens.notificationTitleRowHeight)
                    readonly property var known: Appearance.backdrops[Screen.name] ?? null
                    readonly property var range: known ? (known.grid ? (GlassTint.gridRange(known.grid, area, Tokens.glassBackdropPad) ?? known) : known) : null
                    readonly property string ink: GlassTint.inkOn(range, [String(Appearance.darkColors.text), String(Appearance.lightColors.text)], Tokens.menubarToneNeededContrast)
                    readonly property bool plated: ink === ""

                    visible: shown
                    width: parent.width
                    height: shown ? Tokens.notificationTitleRowHeight : 0

                    Material {
                        id: titlePlate
                        glassClass: "notification"
                        x: 0
                        y: titleText.y - Tokens.spacingXs
                        width: titleRow.plated && titleRow.shown ? titleText.implicitWidth + 2 * Tokens.notificationTitlePlatePadding : 0
                        height: titleText.height + 2 * Tokens.spacingXs
                        radius: height / 2
                        shadowEnabled: false
                        visible: width > 0
                        // Over the title row at rest, not where the sliding column was when the plate was made (audit B-13).
                        backdropRect: titleRow.area
                        Component.onCompleted: hostItem.addSurface(titlePlate, false, Math.floor(height / 2), null)
                    }

                    Text {
                        id: titleText
                        x: titleRow.plated ? Tokens.notificationTitlePlatePadding : Tokens.notificationTitleInset
                        y: 0
                        text: qsTr("Notifications")
                        textFormat: Text.PlainText
                        color: titleRow.plated ? Appearance.colors.text : titleRow.ink
                        font.family: Appearance.fontFamilyFor(Tokens.notificationTitleSize)
                        font.pixelSize: Tokens.notificationTitleSize
                        font.weight: Tokens.typographyMenuBoldWeight
                        Accessible.role: Accessible.Heading
                        Accessible.name: text
                    }

                    // Clear All, on the keyboard too: the Tab stop before the cards (NotificationList.headTarget; ADR-0039 step 7).
                    Item {
                        id: clearAllButton
                        x: parent.width - width
                        y: titleText.y + (titleText.height - height) / 2
                        width: Tokens.notificationTitleCloseSize
                        height: width
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTr("Clear All")
                        Accessible.focusable: true
                        Accessible.onPressAction: if (titleRow.shown)
                            Notifications.clearAll()
                        Keys.onPressed: event => {
                            if (ActivationKeys.activation(event.key)) {
                                if (titleRow.shown)
                                    Notifications.clearAll();
                                event.accepted = true;
                            }
                        }

                        FocusGuard {}

                        KeyFocus {
                            id: clearAllFocus
                        }

                        FocusRing {
                            shapeRadius: width / 2
                            visible: clearAllFocus.active
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: Appearance.withAlpha(Appearance.colors.materialTint, Appearance.fixedGlassAlpha(Tokens.notificationCloseTintOpacity))
                            // One device pixel at every scale (UI audit 2026-11-05 U37).
                            border.width: 1 / Math.max(1, Screen.devicePixelRatio)
                            border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity * Tokens.notificationCloseBorderScale)
                        }

                        // Pressed: the shared pressed fill over the disk (LOW, UI audit 2026-11-05).
                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: Appearance.withAlpha(Appearance.colors.hover, Tokens.controlPressedOpacity)
                            visible: clearAllArea.pressed
                        }

                        Icon {
                            anchors.centerIn: parent
                            size: parent.width - Tokens.notificationCloseGlyphInset
                            name: "close-glyph"
                        }

                        MouseArea {
                            id: clearAllArea
                            anchors.fill: parent
                            cursorShape: Qt.ArrowCursor
                            onClicked: Notifications.clearAll()
                        }
                    }
                }

                NotificationList {
                    id: list
                    x: -panelItem.gutter
                    y: titleRow.height - panelItem.gutter
                    width: parent.width + panelItem.gutter
                    host: hostItem
                    panel: panelItem
                    editTarget: editPill
                    closeTarget: closeDisk
                    headTarget: clearAllButton
                    // As tall as its content (the area below the last card is outside the list, so a click there closes);
                    // the footer sits one spacing.lg below it, or at the bottom of the column when the list fills it.
                    bottomReserve: widgetsFooter.height + Tokens.spacingLg
                    height: Math.min(contentHeight + topMargin, Math.max(0, parent.height - y - bottomReserve))
                    footer: widgetsArea
                    onCountChanged: pruneSurfaces.restart()
                }

                // Widgets: the footer of the list, so they scroll with the notifications. Each is a glass tile.
                Component {
                    id: widgetsArea

                    Column {
                        width: list.width
                        leftPadding: panelItem.gutter
                        topPadding: Widgets.center.length > 0 ? Tokens.spacingMd : 0

                        Flow {
                            width: parent.width - panelItem.gutter
                            spacing: Tokens.widgetGap

                            Repeater {
                                model: Widgets.center

                                delegate: WidgetHost {
                                    id: tile

                                    required property var modelData

                                    entry: modelData
                                    cell: (list.width - panelItem.gutter - Tokens.widgetGap) / 2
                                    // The column at rest, wherever the list scrolls the tile (audit B-13, as the cards).
                                    backdropRect: panelItem.restRect
                                    onMenuRequested: (x, y) => panelItem.openWidgetMenu(tile, x, y, modelData)
                                    onRemoveRequested: {
                                        Widgets.remove(modelData.uid);
                                        panelItem.forceActiveFocus();
                                    }
                                    Component.onCompleted: hostItem.addSurface(tile, true, Tokens.widgetRadius, null)
                                    onActiveFocusChanged: {
                                        if (!activeFocus)
                                            return;
                                        const top = tile.mapToItem(list.contentItem, 0, 0).y;
                                        if (top < list.contentY)
                                            list.contentY = top;
                                        else if (top + tile.height > list.contentY + list.height)
                                            list.contentY = top + tile.height - list.height;
                                    }
                                }
                            }
                        }
                    }
                }

                // Footer (macOS model): Edit Widgets and the close circle, centred under the column, one spacing.lg below
                // the last card. No Clear All here: it lives on the group headers.
                Row {
                    id: widgetsFooter
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: Math.min(list.y + list.height + Tokens.spacingLg, parent.height - height)
                    height: Tokens.notificationCenterCloseDisk
                    spacing: Tokens.spacingSm
                    onYChanged: list.bumpTick()

                    // Glides with the cards when the list shrinks or grows (not during the first layout); jumps with them
                    // under Reduce Motion (NotificationList.still).
                    Behavior on y {
                        enabled: panelItem.glide && !Appearance.reduceMotion
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.curve
                        }
                    }

                    Pill {
                        id: editPill
                        surfaceHost: hostItem
                        backdropRect: panelItem.restRect
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Edit Widgets")
                        onClicked: panelItem.galleryOpen = true
                    }

                    Item {
                        id: closeDisk
                        width: Tokens.notificationCenterCloseDisk
                        height: width
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTr("Close")
                        Accessible.focusable: true
                        Accessible.onPressAction: Notifications.closeCenter()
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                Notifications.closeCenter();
                                event.accepted = true;
                            }
                        }

                        Material {
                            id: closeSurface
                            glassClass: "notification"
                            anchors.fill: parent
                            radius: width / 2
                            shadowEnabled: false
                            // The column at rest (audit B-13, as the footer pill).
                            backdropRect: panelItem.restRect
                            Component.onCompleted: hostItem.addSurface(closeSurface, false, Math.floor(width / 2), null)
                        }

                        Icon {
                            anchors.centerIn: parent
                            size: parent.width - Tokens.notificationCloseGlyphInset
                            name: "close-glyph"
                        }

                        // The shared ring outside the disc, after a key only (ADR-0039 step 7).
                        KeyFocus {
                            id: closeDiskFocus
                        }

                        FocusRing {
                            shapeRadius: width / 2
                            visible: closeDiskFocus.active
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.ArrowCursor
                            onClicked: Notifications.closeCenter()
                        }
                    }
                }

                // Widget context menu (sizes, Remove Widget) at the click or the focused tile.
                MouseArea {
                    anchors.fill: parent
                    visible: panelItem.menuEntry !== null || panelItem.editEntry !== null
                    acceptedButtons: Qt.AllButtons
                    onPressed: panelItem.closeWidgetMenu()
                }

                // The Weather widget's Edit Location… where its menu was, on its own blur region.
                Loader {
                    active: panelItem.editEntry !== null
                    x: Math.max(Tokens.spacingSm, Math.min(panelItem.menuX, panelItem.width - width - Tokens.spacingSm))
                    y: Math.max(Tokens.spacingSm, Math.min(panelItem.menuY, panelItem.height - height - Tokens.spacingSm))
                    sourceComponent: LocationEditor {
                        onClosed: panelItem.closeWidgetMenu()
                        Component.onCompleted: {
                            hostItem.addSurface(surface, false, Tokens.radiusPopover, null);
                            forceActiveFocus();
                        }
                    }
                }

                Loader {
                    id: widgetMenu
                    active: panelItem.menuEntry !== null
                    x: Math.max(Tokens.spacingSm, Math.min(panelItem.menuX, panelItem.width - width - Tokens.spacingSm))
                    y: Math.max(Tokens.spacingSm, Math.min(panelItem.menuY, panelItem.height - height - Tokens.spacingSm))
                    sourceComponent: WidgetMenu {
                        entry: panelItem.menuEntry
                        moves: {
                            const at = Widgets.center.findIndex(e => e.uid === panelItem.menuEntry.uid);
                            return {up: at > 0, down: at >= 0 && at < Widgets.center.length - 1};
                        }
                        onChoose: action => panelItem.applyWidgetMenu(action)
                        onCloseRequested: panelItem.closeWidgetMenu()
                        Component.onCompleted: forceActiveFocus()
                    }
                }
            }

            // Widget gallery: a glass panel at the bottom left (macOS), over the desktop and clear of the Dock; its own blur region.
            Loader {
                id: gallery

                readonly property string screenName: win.modelData ? win.modelData.name : ""
                readonly property var dock: Compositor.dockScreenName === "" || Compositor.dockScreenName === screenName ? Settings.dockFootprintFor(screenName, false) : ({
                        left: 0,
                        right: 0,
                        bottom: 0
                    })
                readonly property var rect: CenterLogic.galleryRect(hostItem.width, hostItem.height, {
                    menubar: Tokens.menubarHeight,
                    inset: Tokens.notificationCenterInset,
                    insetLeft: Tokens.widgetGalleryInsetLeft,
                    width: Tokens.widgetGalleryWidth,
                    maxHeight: Tokens.widgetGalleryMaxHeight,
                    fraction: Tokens.widgetGalleryHeightFraction
                }, dock)

                x: rect.x
                y: rect.y
                width: rect.width
                height: rect.height
                active: panelItem.galleryOpen
                sourceComponent: WidgetGallery {
                    screenName: (win.modelData ? win.modelData.name : "")
                    surfaceHost: hostItem
                    onClosed: {
                        panelItem.galleryOpen = false;
                        panelItem.forceActiveFocus();
                    }
                    Component.onCompleted: forceActiveFocus()
                }
            }
        }
    }
}
