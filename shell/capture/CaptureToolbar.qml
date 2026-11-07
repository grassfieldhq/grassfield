pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services
import "CaptureModel.js" as Model
import "../overview/ClientChrome.js" as ClientChrome
import "../platform/WindowTiling.js" as WindowTiling

// The capture toolbar's window (spec docs/specs/system-dialogs.md "Capture toolbar", ADR-0045 OC-1), one per screen, mapped
// only on the controller's screen while open. As Search, a full-screen transparent overlay that holds the keyboard (exclusive)
// and swallows the clicks around the bar (macOS: the screen is in capture mode while the toolbar shows). macOS 27's layout: a
// floating bar of the macOS 26 glass (the menus' class), centred over the Dock's band, its ends round:
//   Close | Capture Entire Screen, Capture Selected Window, Capture Selected Portion | Record Entire Screen, Record Selected
//   Portion | Options and its chevron, then Capture or Record.
// The modes are the shared ToolButton (capsules, one checked, the neutral selection on glass, a tooltip each), the action the
// shared primary Button, and Options opens the shared PopupMenu (section headers, check marks) above itself, inside this window.
// Without gpu-screen-recorder the recordings' group is not shown (OC-0 rule 3).
// The modes act on this surface as macOS 27's do (the design review of OC-1, H1):
// - Selected Portion: a frame over the dimmed display (capture.frameVeil around it, capture.border on it, eight handles), opened on
//   the display's last frame (capture.lastSelection) or centred; a drag on a handle resizes it, inside moves it, outside draws a
//   new one, with the size readout beside the pointer; Capture/Record and Return act on its geometry.
// - Selected Window: the window under the pointer is tinted with the accent (every display's surface takes input then); a click
//   captures it. Grassfield's cursor theme has no camera pointer: the arrow shows.
// - Entire Screen: a click on a display captures or records that display; Capture keeps every display, Record this one.
// The geometry goes to grassfield-capture (--geometry, --output); its crosshair stays the fallback (Return in Capture Selected
// Window with no window known).
Variants {
    id: root

    required property var controller

    // The display that has held the keyboard since the toolbar opened ("" before the first); see the windows' holdsKeyboard.
    property string holder: ""
    readonly property bool isOpen: controller.open
    onIsOpenChanged: {
        if (!isOpen)
            holder = "";
    }

    model: Quickshell.screens

    // A hairline between two groups of the bar (the toolbar's divider height, the menus' separator colour).
    component Divider: Item {
        implicitWidth: 2 * Tokens.captureToolbarSeparatorGap + Tokens.controlBorderWidth
        implicitHeight: Tokens.captureToolbarButtonHeight
        Accessible.role: Accessible.Separator
        Accessible.ignored: true

        Rectangle {
            anchors.centerIn: parent
            width: Tokens.controlBorderWidth
            height: Tokens.toolbarDividerHeight
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }
    }

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property string name: modelData ? modelData.name : ""
        // The toolbar's display: the bar, the keyboard (exclusive) and the frame of the Selected Portion modes are here.
        readonly property bool shown: root.controller.open && root.controller.screenName === win.name
        // This display's surface takes input: the toolbar's display, and every display in the modes that take a click anywhere
        // (an Entire Screen mode: the display clicked; Capture Selected Window: the window clicked).
        readonly property bool covered: win.shown || root.controller.coversAll
        // The display that holds the keyboard. A layer surface with Exclusive keyboard keeps the pointer on its own display in
        // the compositor: a click on another display never reaches that display's surface. In the modes that take a click on
        // any display (coversAll) the keyboard therefore follows the pointer's display (the focused monitor), so the display the
        // pointer is on is always the one that is Exclusive; otherwise it is the toolbar's.
        readonly property bool wantsKeyboard: win.covered && win.name === (root.controller.coversAll ? Compositor.activeScreenName : root.controller.screenName)
        // What the surface asks the compositor for. Exclusive keyboard is taken when the layer is mapped: a layer that is already
        // mapped and changes to Exclusive is not given the focus (Escape and Return reached nothing on the display the pointer
        // moved to). The hand-over between displays is therefore a new mapping: the old holder drops to None at once, the new
        // one unmaps, then maps again as Exclusive. `root.holder` names the display that held it since the toolbar opened.
        // While a security sheet may hold the keyboard (the polkit sheet or a secret sheet, or its key sink still lingering after
        // a request ended under the user's typing: SessionState.securityKeyboard) nothing here is mapped as Exclusive, neither a
        // hand-over nor the toolbar opening: the surface mapped last with Exclusive takes the keyboard, so the rest of a password
        // would reach the toolbar, where Return captures (opus re-reviews of the ADR-0045 security fixes, MINOR).
        // The hand-over waits for the sheet to go, and then always maps again (a mapped layer turned Exclusive gets no focus).
        property bool holdsKeyboard: false
        property bool remapping: false
        onWantsKeyboardChanged: win.followKeyboard(false)
        readonly property bool sheetOpen: SessionState.securityKeyboard
        onSheetOpenChanged: {
            if (sheetOpen) {
                // A hand-over under way stays unmapped no longer, and maps without the keyboard (keyHandover checks too).
                keyHandover.stop();
                if (win.remapping) {
                    win.remapping = false;
                    win.holdsKeyboard = false;
                }
            } else {
                win.followKeyboard(true);
            }
        }

        // `afterSheet`: a security sheet just went; a display that wants the keyboard and was kept from it takes it now.
        function followKeyboard(afterSheet: bool): void {
            keyHandover.stop();
            win.remapping = false;
            if (!win.wantsKeyboard) {
                win.holdsKeyboard = false;
                return;
            }
            if (win.sheetOpen) {
                win.holdsKeyboard = false;
                return;
            }
            if (afterSheet && win.holdsKeyboard)
                return;
            if (!afterSheet && (root.holder === "" || !win.visible)) {
                win.holdsKeyboard = true;
            } else {
                // Taken over from another display, or after a sheet: unmap, then map as Exclusive.
                win.holdsKeyboard = false;
                win.remapping = true;
                keyHandover.restart();
            }
            root.holder = win.name;
        }
        readonly property bool recordMode: Model.isRecord(root.controller.mode)
        readonly property bool framing: win.shown && (root.controller.mode === "selection" || root.controller.mode === "recordSelection")
        readonly property bool windowMode: win.covered && root.controller.mode === "window"
        // The display's logical size: the window's once mapped, else the screen's (the window is 0x0 when the frame is first made).
        readonly property var bounds: Model.displayBounds(win.width, win.height, win.modelData ? win.modelData.width : 0, win.modelData ? win.modelData.height : 0)
        // The output's real scale (the size readout's pixels), not the layer surface's integer ratio.
        readonly property real outputScale: Compositor.outputScale(win.name)
        // The frame of the Selected Portion modes ({x, y, w, h}, this display's logical coordinates, CaptureModel.js), the part a
        // press took ("" none, a handle, "inside", "outside", "click"), the pointer, and whether a drag is under way.
        property var frame: ({x: 0, y: 0, w: 0, h: 0})
        property string part: ""
        property string hoverPart: "outside"
        property point pointer: Qt.point(0, 0)
        property bool dragging: false
        // Capture Selected Window: the window under the pointer on this display ({x, y, w, h}, clipped to it) or null.
        property var hovered: null

        onFramingChanged: {
            if (framing)
                win.frame = root.controller.frameFor(win.name, win.bounds);
            win.dragging = false;
        }
        onWidthChanged: win.keepFrame()
        onHeightChanged: win.keepFrame()
        onWindowModeChanged: win.hovered = null

        // The display changed size (a new mode or scale): the frame stays on it.
        function keepFrame(): void {
            if (win.framing)
                win.frame = Model.clampFrame(win.frame, win.bounds, Tokens.captureFrameMinSize);
        }

        // The window drawn on top under the point (this display's coordinates), from the platform's window list of the shown
        // Desktop and the order the windows were activated in, clipped to the display; null when none.
        function windowUnder(x: real, y: real): var {
            const list = Compositor.windowsOn(win.name, Compositor.topologyRevision).map(w => {
                // The window as it looks: the plugin's titlebar strip lies above the window's own box (none on a window that
                // draws its own chrome, none without the plugin), and macOS tints and captures the window with its title bar.
                const away = WindowTiling.splitTitleAway(TilingLink.splits, w.address, Compositor.splitTitlesAway);
                const band = Capabilities.pluginPresent && !w.fullscreen ? ClientChrome.band(w, Capabilities.has(ClientChrome.FEATURE), Tokens.windowTitlebarHeight, away) : 0;
                return {
                        x: w.x,
                        y: w.y - band,
                        w: w.w,
                        h: w.h + band,
                        fullscreen: w.fullscreen,
                        stamp: w.toplevel && Compositor.recency.has(w.toplevel) ? Compositor.recency.get(w.toplevel) : 0
                };
            });
            const hit = Model.windowAt(list, x, y);
            return hit ? Model.clip(hit, win.bounds) : null;
        }

        function origin(): var {
            return {x: win.modelData ? win.modelData.x : 0, y: win.modelData ? win.modelData.y : 0};
        }

        // Capture or Record (the button, Return): the frame in the Selected Portion modes, the window under the pointer in
        // Capture Selected Window (none known: the helper's crosshair), every display (Record: this one) in the Entire Screen modes.
        function act(): void {
            const mode = root.controller.mode;
            if (win.framing)
                root.controller.trigger("", Model.geometryText(win.frame, win.origin()));
            else if (mode === "window")
                root.controller.trigger("", win.hovered ? Model.geometryText(win.hovered, win.origin()) : "");
            else
                root.controller.trigger("", "");
        }

        // A click on the display (outside the bar): in an Entire Screen mode it captures or records this display, in Capture
        // Selected Window the window under it (nothing there: nothing happens, as macOS).
        function clickAt(x: real, y: real): void {
            const mode = root.controller.mode;
            if (mode === "screen" || mode === "recordScreen") {
                root.controller.trigger(win.name, "");
            } else if (mode === "window") {
                const hit = win.windowUnder(x, y);
                if (hit)
                    root.controller.trigger("", Model.geometryText(hit, win.origin()));
            }
        }

        function cursorShapeOf(kind: string): int {
            switch (kind) {
            case "sizeFDiag":
                return Qt.SizeFDiagCursor;
            case "sizeBDiag":
                return Qt.SizeBDiagCursor;
            case "sizeHor":
                return Qt.SizeHorCursor;
            case "sizeVer":
                return Qt.SizeVerCursor;
            case "sizeAll":
                return Qt.SizeAllCursor;
            case "cross":
                return Qt.CrossCursor;
            }
            return Qt.ArrowCursor;
        }
        // The Options menu is open, and where it hangs from (its bottom left: over the Options button, above the bar).
        property bool menuOpen: false
        property point menuAt: Qt.point(0, 0)
        readonly property var menuModel: menuOpen ? Model.menuModel(root.controller.mode, root.controller.options, {
            saveTo: qsTr("Save to"),
            // The default places by their folders' names (grassfield-capture makes "Screenshots" in Pictures, translated).
            screenshots: qsTr("Screenshots"),
            videos: qsTr("Videos"),
            desktop: qsTr("Desktop"),
            documents: qsTr("Documents"),
            clipboard: qsTr("Clipboard"),
            preview: qsTr("Preview"),
            timer: qsTr("Timer"),
            none: qsTr("None"),
            five: qsTr("5 Seconds"),
            ten: qsTr("10 Seconds"),
            microphone: qsTr("Microphone"),
            micNone: qsTr("None"),
            // The default input by the name the sound settings give it (macOS lists the inputs by name).
            micDefault: Audio.source ? Audio.describe(Audio.source) : qsTr("Default Input"),
            options: qsTr("Options"),
            showPointer: qsTr("Show Mouse Pointer")
        }) : []
        readonly property var modeNames: ({
                "screen": qsTr("Capture Entire Screen"),
                "window": qsTr("Capture Selected Window"),
                "selection": qsTr("Capture Selected Portion"),
                "recordScreen": qsTr("Record Entire Screen"),
                "recordSelection": qsTr("Record Selected Portion")
            })
        // The neutral selection of an item on glass (macOS 27, ADR-0039 step 12: one role with the switcher's).
        readonly property color selectedFill: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialSelectionOpacity)

        screen: modelData
        // Mapped a moment longer than it holds the keyboard: a layer destroyed while Exclusive leaves the compositor with no
        // keyboard focus. The other displays' surfaces (input only) hold it while the pointer is on them (holdsKeyboard).
        visible: (release.mapped || win.covered) && !win.remapping
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: holdsKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-capture"
        // qmllint disable missing-type
        // The whole display takes input while covered; nothing once closed: the surface stays mapped a moment for the keyboard
        // release, and a click in that moment belongs to the window under it.
        mask: win.covered ? null : passThrough
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.shown ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: bar
            radius: Tokens.captureToolbarHeight / 2

            // Only while the menu is open: a Loader keeps its last size once it unloads.
            Region {
                item: win.menuOpen ? menuLoader : null
                radius: Tokens.radiusMenu
            }

            // The size readout's plate, while it shows.
            Region {
                item: readout.visible ? readout : null
                radius: Tokens.captureReadoutRadius
            }
        }

        Region {
            id: passThrough
        }

        Timer {
            id: keyHandover

            interval: Tokens.focusReturnMenuActionSettleMs
            onTriggered: {
                win.holdsKeyboard = win.wantsKeyboard && !win.sheetOpen;
                win.remapping = false;
            }
        }

        KeyboardRelease {
            id: release
            shown: win.holdsKeyboard
        }

        onHoldsKeyboardChanged: {
            if (holdsKeyboard)
                keys.forceActiveFocus();
        }

        onShownChanged: {
            win.menuOpen = false;
            if (shown)
                keys.forceActiveFocus();
        }

        function openMenu(): void {
            const at = optionsButton.mapToItem(win.contentItem, 0, 0);
            win.menuAt = Qt.point(at.x, bar.y - Tokens.spacingSm);
            win.menuOpen = true;
        }

        function closeMenu(): void {
            if (!win.menuOpen)
                return;
            win.menuOpen = false;
            if (win.shown)
                keys.forceActiveFocus();
        }

        function applyMenu(id: string): void {
            win.closeMenu();
            root.controller.setOption(id);
        }

        // Closed but still mapped (the hold): a press the compositor delivered before the empty mask landed is swallowed here,
        // never handled by what lies under it.
        MouseArea {
            anchors.fill: parent
            z: 1000
            visible: !win.covered
            acceptedButtons: Qt.AllButtons
        }

        // The display around the bar (macOS 27: the screen is in capture mode). In the Selected Portion modes a drag on a
        // handle resizes the frame, inside it moves it, outside it draws a new one; in Capture Selected Window the window under
        // the pointer is highlighted and a click captures it; in an Entire Screen mode a click captures or records this display.
        // Other presses go nowhere.
        MouseArea {
            id: surface

            property point pressedAt: Qt.point(0, 0)
            property var pressedFrame: null

            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: win.covered
            cursorShape: win.framing ? win.cursorShapeOf(Model.cursorFor(win.dragging ? win.part : win.hoverPart)) : Qt.ArrowCursor
            onPressed: mouse => {
                win.part = "";
                if (mouse.button !== Qt.LeftButton)
                    return;
                surface.pressedAt = Qt.point(mouse.x, mouse.y);
                surface.pressedFrame = win.frame;
                win.part = win.framing ? Model.hitTest(win.frame, mouse.x, mouse.y, Tokens.captureHandleHitSize) : "click";
            }
            onPositionChanged: mouse => {
                win.pointer = Qt.point(mouse.x, mouse.y);
                if (!surface.pressed) {
                    if (win.framing)
                        win.hoverPart = Model.hitTest(win.frame, mouse.x, mouse.y, Tokens.captureHandleHitSize);
                    else if (win.windowMode)
                        win.hovered = win.windowUnder(mouse.x, mouse.y);
                    return;
                }
                if (!win.framing || win.part === "" || win.part === "click")
                    return;
                const dx = mouse.x - surface.pressedAt.x;
                const dy = mouse.y - surface.pressedAt.y;
                // A press that has not moved yet is no drag (a click outside the frame leaves it as it is).
                if (!win.dragging && Math.abs(dx) < 2 && Math.abs(dy) < 2)
                    return;
                win.dragging = true;
                if (win.part === "inside")
                    win.frame = Model.move(surface.pressedFrame, dx, dy, win.bounds);
                else if (win.part === "outside")
                    win.frame = Model.drawn(surface.pressedAt.x, surface.pressedAt.y, mouse.x, mouse.y, win.bounds, Tokens.captureFrameMinSize);
                else
                    win.frame = Model.resize(surface.pressedFrame, win.part, dx, dy, win.bounds, Tokens.captureFrameMinSize);
            }
            onReleased: mouse => {
                const part = win.part;
                win.part = "";
                if (win.dragging) {
                    win.dragging = false;
                    root.controller.rememberFrame(win.name, win.frame);
                    win.hoverPart = Model.hitTest(win.frame, mouse.x, mouse.y, Tokens.captureHandleHitSize);
                    return;
                }
                if (part === "click" && mouse.button === Qt.LeftButton)
                    win.clickAt(mouse.x, mouse.y);
            }
            onExited: win.hovered = null
        }

        // Capture Selected Window: the window under the pointer, tinted with the accent (macOS 27), its outline the window's own
        // (Hyprland's superellipse corners, CaptureModel.windowOutline): a circular corner would leave notches at the title bar.
        Shape {
            visible: win.windowMode && win.hovered !== null
            x: win.hovered ? win.hovered.x : 0
            y: win.hovered ? win.hovered.y : 0
            width: win.hovered ? win.hovered.w : 0
            height: win.hovered ? win.hovered.h : 0
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                fillColor: Appearance.withAlpha(Appearance.colors.accent, Tokens.captureWindowHighlightOpacity)
                strokeColor: "transparent"

                PathPolyline {
                    path: win.hovered ? Model.windowOutline(win.hovered.w, win.hovered.h, Tokens.captureWindowHighlightRadius, Tokens.captureWindowHighlightPower, 12).map(q => Qt.point(q.x, q.y)) : []
                }
            }
        }

        // The Selected Portion modes: the display dimmed around the frame (capture.frameVeil), the frame's hairline (capture.border)
        // and its eight handles.
        Item {
            id: frameLayer

            anchors.fill: parent
            visible: win.framing

            Rectangle {
                width: parent.width
                height: win.frame.y
                color: Model.qtColor(Tokens.captureFrameVeil)
            }

            Rectangle {
                y: win.frame.y + win.frame.h
                width: parent.width
                height: parent.height - y
                color: Model.qtColor(Tokens.captureFrameVeil)
            }

            Rectangle {
                y: win.frame.y
                width: win.frame.x
                height: win.frame.h
                color: Model.qtColor(Tokens.captureFrameVeil)
            }

            Rectangle {
                x: win.frame.x + win.frame.w
                y: win.frame.y
                width: parent.width - x
                height: win.frame.h
                color: Model.qtColor(Tokens.captureFrameVeil)
            }

            Rectangle {
                x: win.frame.x
                y: win.frame.y
                width: win.frame.w
                height: win.frame.h
                color: "transparent"
                border.width: Tokens.captureBorderWidth
                border.color: Model.qtColor(Tokens.captureBorder)
            }

            Repeater {
                model: Model.handleCentres(win.frame)

                delegate: Rectangle {
                    required property var modelData

                    x: Math.round(modelData.x - width / 2)
                    y: Math.round(modelData.y - height / 2)
                    width: Tokens.captureHandleSize
                    height: Tokens.captureHandleSize
                    radius: width / 2
                    color: Model.qtColor(Tokens.captureBorder)
                    border.width: Tokens.captureBorderWidth
                    border.color: Model.qtColor(Tokens.captureFrameVeil)
                }
            }

            // The size readout beside the pointer while the frame is drawn, moved or resized: the picture's size in pixels.
            Item {
                id: readout

                visible: win.dragging
                width: readoutText.implicitWidth + 2 * Tokens.captureReadoutPaddingX
                height: readoutText.implicitHeight + 2 * Tokens.captureReadoutPaddingY
                x: Math.min(parent.width - width, win.pointer.x + Tokens.captureReadoutOffset)
                y: Math.min(parent.height - height, win.pointer.y + Tokens.captureReadoutOffset)
                Accessible.role: Accessible.StaticText
                Accessible.name: readoutText.text

                Material {
                    glassClass: "menu"
                    anchors.fill: parent
                    radius: Tokens.captureReadoutRadius
                    shadowEnabled: false
                }

                Text {
                    id: readoutText

                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: Model.readout(win.frame, win.outputScale)
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.captureReadoutTextSize
                    font.features: {"tnum": 1}
                }
            }
        }

        Item {
            id: keys

            focus: true
            Keys.onPressed: event => {
                event.accepted = true;
                switch (event.key) {
                case Qt.Key_Escape:
                    root.controller.hide();
                    break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    win.act();
                    break;
                case Qt.Key_Left:
                    root.controller.step(-1);
                    break;
                case Qt.Key_Right:
                    root.controller.step(1);
                    break;
                default:
                    event.accepted = false;
                }
            }
        }

        // A mode of the toolbar: a capsule with its glyph, checked while it is the mode; a recording mode is disabled while a
        // recording runs (the helper refuses a second one too).
        Component {
            id: modeButton

            ToolButton {
                id: button

                required property var modelData

                width: Tokens.captureToolbarButtonWidth
                height: Tokens.captureToolbarButtonHeight
                capsule: true
                radio: true
                checkable: true
                checked: root.controller.mode === button.modelData.id
                checkedColor: win.selectedFill
                enabled: !button.modelData.record || root.controller.canRecord
                iconName: button.modelData.glyph
                glyphSize: Tokens.captureToolbarIconSize
                accessibleName: win.modeNames[button.modelData.id]
                onClicked: root.controller.choose(button.modelData.id)
            }
        }

        Item {
            id: bar

            visible: win.shown
            width: row.implicitWidth + 2 * Tokens.captureToolbarPadding
            height: Tokens.captureToolbarHeight
            x: Math.round((win.width - width) / 2)
            // Above the Dock's band (where the Dock lies at the bottom), else above the display's bottom edge.
            y: win.height - Settings.dockFootprint.bottom - Tokens.captureToolbarBottomGap - height
            Accessible.role: Accessible.ToolBar
            Accessible.name: qsTr("Screenshot")

            // Swallows presses on the bar itself (between its buttons).
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: win.closeMenu()
            }

            // The bar's glass: a text surface (Options, Capture), the menus' class.
            Material {
                glassClass: "menu"
                anchors.fill: parent
                radius: Tokens.captureToolbarHeight / 2
            }

            Row {
                id: row

                anchors.centerIn: parent

                // Close: a grey filled disc with the cross knocked out (macOS 27), in the secondary text colour.
                ToolButton {
                    width: Tokens.captureToolbarButtonHeight
                    height: Tokens.captureToolbarButtonHeight
                    capsule: true
                    iconName: "xmark-circle-fill"
                    glyphSize: Tokens.captureToolbarCloseIconSize
                    tint: Appearance.colors.textSecondary
                    accessibleName: qsTr("Close")
                    onClicked: root.controller.hide()
                }

                Divider {}

                Row {
                    spacing: Tokens.captureToolbarButtonSpacing

                    Repeater {
                        model: Model.MODES.filter(m => !m.record)
                        delegate: modeButton
                    }
                }

                Divider {
                    visible: root.controller.recorder
                }

                Row {
                    visible: root.controller.recorder
                    spacing: Tokens.captureToolbarButtonSpacing

                    Repeater {
                        model: Model.MODES.filter(m => m.record)
                        delegate: modeButton
                    }
                }

                Divider {}

                ToolButton {
                    id: optionsButton

                    width: optionsLabel.implicitWidth + 2 * Tokens.captureToolbarTextPadding
                    height: Tokens.captureToolbarButtonHeight
                    capsule: true
                    checkedColor: win.selectedFill
                    // Pressed in while its menu is open; its name is its label (no tooltip, as a text button).
                    checked: win.menuOpen
                    accessibleName: qsTr("Options")
                    tooltip: ""
                    onClicked: {
                        if (win.menuOpen)
                            win.closeMenu();
                        else
                            win.openMenu();
                    }

                    Row {
                        id: optionsLabel

                        anchors.centerIn: parent
                        spacing: Tokens.captureToolbarChevronGap

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: qsTr("Options")
                            color: optionsButton.foreground
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            font.letterSpacing: Appearance.tracking(Tokens.typographyBodySize)
                        }

                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "chevron-down"
                            size: Tokens.captureToolbarChevronSize
                        }
                    }
                }

                Item {
                    width: Tokens.captureToolbarSeparatorGap
                    height: Tokens.captureToolbarButtonHeight
                }

                // The action: Capture, or Record in a recording mode (the default button, as macOS draws it).
                Button {
                    anchors.verticalCenter: parent.verticalCenter
                    // As tall as the bar's other controls, a capsule concentric with the bar.
                    height: Tokens.captureToolbarButtonHeight
                    primary: true
                    capsule: true
                    focusPolicy: Qt.NoFocus
                    text: win.recordMode ? qsTr("Record") : qsTr("Capture")
                    enabled: !win.recordMode || root.controller.canRecord
                    onClicked: win.act()
                }
            }
        }

        // The Options menu, inside this window: it already covers the display and holds the keyboard. A press outside the
        // menu closes it and is swallowed.
        MouseArea {
            anchors.fill: parent
            z: 900
            visible: win.menuOpen
            acceptedButtons: Qt.AllButtons
            onPressed: mouse => {
                const menu = menuLoader.item as PopupMenu;
                if (!menu || !menu.containsPoint(mouse.x, mouse.y))
                    win.closeMenu();
            }
        }

        Loader {
            id: menuLoader

            readonly property real menuWidth: (item as Item)?.width ?? 0
            readonly property real menuHeight: (item as Item)?.height ?? 0
            // Above the Options button, its left edge under the button's (kept inside the display).
            readonly property point placed: MenuPlace.place({x: win.menuAt.x, y: win.menuAt.y - menuHeight}, {w: menuWidth, h: menuHeight}, {w: win.width, h: win.height}, Tokens.panelPopupMargin)

            z: 901
            x: placed.x
            y: placed.y
            active: win.menuOpen
            sourceComponent: PopupMenu {
                bounds: win.contentItem
                model: win.menuModel
                accessibleName: qsTr("Options")
                onActivated: item => win.applyMenu(item.id)
                onCloseRequested: win.closeMenu()
            }
            onLoaded: (item as Item).forceActiveFocus()
        }
    }
}
