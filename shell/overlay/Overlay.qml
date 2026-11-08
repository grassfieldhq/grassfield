pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.menubar
import qs.platform
import qs.services
import "../platform/WindowTiling.js" as WindowTiling
import "../services/PopupKinds.js" as PopupKinds

// Host of every popup (menus, status menus, Control Center, dialogs): one transparent
// layer-shell window per screen, mapped only while a popup is open on that screen. It takes
// exclusive keyboard focus, closes on a click outside and hands the menu bar strip to that output's
// bar so the user can switch menus (hover or click, macOS). Content is declared in Popups (kind, anchor, payload).
Variants {
    id: root

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property bool open: Popups.openOn(modelData ? modelData.name : "")
        // A popup is loaded and shown here. Only then does this surface hold the keyboard and take the output's input: whatever
        // leaves `open` true with no popup (a stale value, an unknown kind), the mapped surface lets every key and click through
        // (integrator, from an owner report on #56: the overlay mapped with no popup held Exclusive keyboard focus over the
        // whole output, and the session looked stuck in full screen). The mapping itself follows `open`: tied to the popup's
        // item, the surface mapped while that item was created and resized the window under the popup's x and y bindings (a
        // binding loop, integrator nested pass of 12e3dd3).
        readonly property bool hasPopup: open && holder.item !== null
        // The same, held steady while the Loader swaps one popup for another (Left/Right in a menu: system -> app -> ...). The
        // old item is destroyed before the new one exists, so `hasPopup` is false for that instant, and each change of the
        // keyboard mode or of the input mask is committed to the compositor at once: Exclusive -> None -> Exclusive handed
        // the keys back to the focused window (Hyprland gives the focus back when an Exclusive layer drops to None) and the
        // walk stopped after one step (R7-FUN-08 / GF-002). A kind the Overlay draws keeps the keyboard and the input
        // through the swap; a Loader in error does not (an empty overlay never holds the keys).
        readonly property bool engaged: PopupKinds.holdsKeyboard(open, Popups.kind, holder.status === Loader.Error)

        // A left press on the tiling popover's green light is the light's (ADR-0036 D64): released over it, the light's action
        // runs; released elsewhere, the popover closes. The click-outside area and the menu bar strip share it (in a Split View
        // a member's titlebar starts at the output's top, under the strip: integrator review of 7096305, MAJOR 1).
        property bool pressedOnGreen: false

        function greenPress(x: real, y: real, button: int): bool {
            const popover = holder.item as TilingPopover;
            win.pressedOnGreen = win.hasPopup && popover !== null && button === Qt.LeftButton && popover.onLight(x, y);
            return win.pressedOnGreen;
        }

        function greenRelease(x: real, y: real, alt: bool): void {
            if (!win.pressedOnGreen)
                return;
            win.pressedOnGreen = false;
            const popover = holder.item as TilingPopover;
            if (popover && popover.onLight(x, y))
                popover.greenClick(alt);
            else
                Popups.close();
        }

        function greenCancel(): void {
            if (win.pressedOnGreen)
                Popups.close();
            win.pressedOnGreen = false;
        }

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
        WlrLayershell.keyboardFocus: engaged && !Popups.pointerHeld ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-overlay"
        // The whole output receives input while a popup is open (the bar strip is handed to the bar, below); nothing once
        // it closed: the surface stays mapped a moment for the keyboard release, and a click in that moment belongs to the
        // window under it.
        // qmllint disable missing-type
        mask: win.engaged && !Popups.pointerHeld ? openMask : passThrough
        // Quick Settings is several floating modules: one blur region each. Everything else is one surface.
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.open && !(Popups.kind === "dockstack" && ((holder.item as StackPopup)?.fan ?? false)) ? (Popups.kind === "controlcenter" ? modulesRegion : blurRegion) : null
        // qmllint enable missing-type

        // The whole output, the menu bar strip included: the strip is handed to the bar below (Popups.bars). Leaving it out
        // left a press there with no surface at all when the pointer had not moved since the popup opened (Hyprland takes
        // the pointer from the bar when this Exclusive layer maps and enters it only where it takes input).
        Region {
            id: openMask
            width: win.width
            height: win.height
        }

        Region {
            id: passThrough
        }

        KeyboardRelease {
            id: release
            shown: win.open
        }

        // Whether the compositor gave this window the keyboard (read by the dev hook `menubar keyboardHolder`).
        Item {
            id: keyboardProbe
        }

        Binding {
            target: Popups
            property: "overlayHasKeyboard"
            value: keyboardProbe.Window.active
            when: win.open
        }

        // While mapped or open: `open` is computed again when it disagrees with Popups (a value left stale by a binding loop would keep
        // this surface over every click and key; integrator PASS on 8316ed2).
        Timer {
            interval: 1000
            repeat: true
            running: win.visible || win.open
            onTriggered: {
                if (Popups.verify())
                    Popups.verifyOpen(win.open, win.modelData ? win.modelData.name : "");
                if (win.open && !win.hasPopup)
                    console.warn("grassfield: overlay on \"" + (win.modelData ? win.modelData.name : "") + "\": open with no popup (kind \"" + Popups.kind
                                 + "\"): the keyboard and the output's input are let through");
                // (mapped while `open`: the check runs then; the surface takes nothing without a popup)
            }
        }

        // Closed but still mapped (the hold): a press the compositor delivered before the empty mask landed (late whenever
        // the GUI thread was busy) is swallowed here, never handled by the menu item under it.
        MouseArea {
            anchors.fill: parent
            z: 1000
            visible: !win.hasPopup
            acceptedButtons: Qt.AllButtons
        }

        // Key focus returns to the window active when the popup opened (FocusReturn); one call per window, idempotent.
        Connections {
            target: Popups

            function onActiveChanged(): void {
                if (Popups.active)
                    FocusReturn.opened("popup");
                else
                    FocusReturn.closed("popup", true);
            }
        }

        // Press, drag, release: the bar (or the strip below) holds the pointer while the button is down and reports it
        // (Popups.trackPointer / releasePointer); the open menu highlights the row under it and runs it on release.
        Connections {
            target: Popups

            function onPointerTracked(screen: string, x: real, y: real): void {
                const menu = holder.item as PopupMenu;
                if (win.open && menu && screen === (win.modelData ? win.modelData.name : ""))
                    menu.trackPointer(x, y);
            }

            function onPointerReleased(screen: string, x: real, y: real): void {
                const menu = holder.item as PopupMenu;
                if (win.open && menu && screen === (win.modelData ? win.modelData.name : ""))
                    menu.releasePointer(x, y);
            }
        }

        Region {
            id: modulesRegion
            regions: moduleRegions.instances
        }

        Variants {
            id: moduleRegions
            model: {
                const cc = holder.item as ControlCenter;
                return Popups.kind === "controlcenter" && cc ? cc.surfaces : [];
            }

            Region {
                required property var modelData
                item: modelData
                radius: modelData ? modelData.radius : 0
            }
        }

        Region {
            id: blurRegion
            item: holder
            // A dialog states the corner it draws (an alert's radius.alert, a sheet's radius.sheet: Force Quit, an app's About):
            // the blur takes it, so its corners are the glass's own (ADR-0039 step 4, G2; PopupKinds.blurCorner).
            radius: PopupKinds.blurCorner(Popups.kind, (holder.item as Dialog)?.cornerRadius, Tokens)

            // A menu's open submenu (Move & Resize, an app's own submenus, the tiling popover's Full Screen ›) is blurred too, and
            // its own open submenu.
            Region {
                item: (holder.item as PopupMenu)?.submenuItem ?? (holder.item as TilingPopover)?.submenuItem ?? null
                radius: Tokens.radiusMenu

                Region {
                    item: ((holder.item as PopupMenu)?.submenuItem as PopupMenu)?.submenuItem ?? null
                    radius: Tokens.radiusMenu
                }
            }
        }

        // The pointer anywhere on the output, for a popup that closes when the pointer stays away from it (the tiling popover
        // opened by the hover, TL22). Passive: it takes nothing from the areas below.
        HoverHandler {
            onPointChanged: {
                const popover = holder.item as TilingPopover;
                if (win.open && popover)
                    popover.pointerAt(point.position.x, point.position.y);
            }
        }

        // Click outside closes. Right and middle buttons too. A left click on the tiling popover's green light is the light's
        // (greenPress).
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: mouse => {
                if (!win.greenPress(mouse.x, mouse.y, mouse.button))
                    Popups.close();
            }
            onReleased: mouse => win.greenRelease(mouse.x, mouse.y, (mouse.modifiers & Qt.AltModifier) !== 0)
            onCanceled: win.greenCancel()
        }

        // The menu bar strip while a popup is open: Hyprland sends the pointer to this Exclusive layer, not to the bar under
        // it (a press at the Window title landed here), so the strip goes to that output's bar (Popups.bars) while the bar is
        // in view: moving onto another title or status item switches menus, a click on the open title closes it, a click on
        // another opens it. With the bar away (full screen, a Split View Desktop) the strip is any click outside, the tiling
        // popover's green light included (WindowTiling.stripPress).
        Item {
            id: strip

            readonly property var bar: Popups.bars[(win.modelData ? win.modelData.name : "")] ?? null
            readonly property bool barInView: bar !== null && bar.away !== true

            width: win.width
            height: Tokens.menubarHeight
            visible: win.hasPopup

            HoverHandler {
                onPointChanged: {
                    // The pointer switches menus here: what opens is the pointer's (Popups.openedByPointer).
                    if (hovered && strip.barInView)
                        Popups.withPointer(true, () => strip.bar.trackAt(point.position.x));
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: mouse => {
                    const popover = holder.item as TilingPopover;
                    const onLight = mouse.button === Qt.LeftButton && popover !== null && popover.onLight(mouse.x, mouse.y);
                    switch (WindowTiling.stripPress(strip.barInView, onLight)) {
                    case "bar":
                        Popups.withPointer(true, () => strip.bar.pressAt(mouse.x, mouse.button === Qt.RightButton ? "right" : mouse.button === Qt.MiddleButton ? "middle" : "left"));
                        break;
                    case "green":
                        win.greenPress(mouse.x, mouse.y, mouse.button);
                        break;
                    default:
                        Popups.close();
                    }
                }
                // Held, the pointer stays with this strip when it moves down onto the menu: relay it (press, drag, release).
                onPositionChanged: mouse => {
                    if (pressed && mouse.buttons === Qt.LeftButton && !win.pressedOnGreen)
                        Popups.trackPointer((win.modelData ? win.modelData.name : ""), mouse.x, mouse.y);
                }
                onReleased: mouse => {
                    if (win.pressedOnGreen)
                        win.greenRelease(mouse.x, mouse.y, (mouse.modifiers & Qt.AltModifier) !== 0);
                    else if (mouse.button === Qt.LeftButton)
                        Popups.releasePointer((win.modelData ? win.modelData.name : ""), mouse.x, mouse.y);
                }
                onCanceled: win.greenCancel()
            }
        }

        // Swallows clicks on the popup itself so they do not reach the click-outside area.
        MouseArea {
            x: holder.x
            y: holder.y
            width: holder.width
            height: holder.height
            acceptedButtons: Qt.AllButtons
        }

        Loader {
            id: holder

            readonly property real margin: Tokens.panelPopupMargin
            readonly property bool ccPlaced: Popups.kind === "controlcenter"
            readonly property real wantedX: {
                // Quick Settings keeps the macOS offsets: a fixed inset from the right edge of the screen.
                if (ccPlaced)
                    return win.width - width - Tokens.quicksettingsEdgeMargin;
                switch (Popups.align) {
                case "right":
                    return Popups.anchorX - width;
                case "above":
                    return Popups.anchorX - width / 2;
                case "rightOf":
                    return Popups.anchorX;
                case "leftOf":
                    return Popups.anchorX - width;
                case "center":
                    return (win.width - width) / 2;
                case "zone":
                    return Popups.anchorX + ((Popups.data.width ?? width) - width) / 2;
                }
                return Popups.anchorX;
            }
            readonly property real wantedY: {
                if (ccPlaced)
                    return Tokens.menubarHeight + Tokens.quicksettingsTopGap;
                switch (Popups.align) {
                case "above":
                    return Popups.anchorY - height;
                case "below":
                    // A gap from the light, or above it when the output has no room below (TL22).
                    if (Popups.anchorY + Tokens.spacingXs + height + margin > win.height && Popups.data.flipY !== undefined)
                        return Popups.data.flipY - Tokens.spacingXs - height;
                    return Popups.anchorY + Tokens.spacingXs;
                case "rightOf":
                case "leftOf":
                    return Popups.anchorY - height / 2;
                case "center":
                    return (win.height - height) / 2 - win.height * Tokens.panelDialogRaise;
                case "zone":
                    return Popups.anchorY + ((Popups.data.height ?? height) - height) / 2;
                }
                return Popups.anchorY;
            }

            // On whole device pixels (UI audit 2026-11-05 U36: centring on an anchor and the dialog raise put popups on half
            // pixels at 1.25, their text and rims soft).
            readonly property real dpr: Math.max(1, Screen.devicePixelRatio)

            active: win.open
            x: Math.round(Math.max(margin, Math.min(win.width - width - margin, wantedX)) * dpr) / dpr
            y: Math.round(Math.max(0, Math.min(win.height - height - margin, wantedY)) * dpr) / dpr
            opacity: item ? 1 : 0

            // Menus and the menu bar's popovers appear at once (macOS: no motion on a frequent interaction, audit F6, C-23);
            // centred dialogs (About, Force Quit, confirmations) keep their short fade in.
            Behavior on opacity {
                enabled: Popups.align === "center"

                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            sourceComponent: {
                switch (Popups.kind) {
                case "system":
                    return systemMenu;
                case "app":
                case "appfile":
                case "appwindow":
                    return appMenu;
                case "appbridge":
                    return bridgeMenu;
                case "tray":
                    return trayMenu;
                case "nowplaying":
                    return nowPlayingPopover;
                case "ongoing":
                    return ongoingPopover;
                case "volume":
                    return volumeMenu;
                case "network":
                    return networkMenu;
                case "battery":
                    return batteryMenu;
                case "screenshare":
                    return screenShareMenu;
                case "input":
                    return inputMenu;
                case "controlcenter":
                    return controlCenter;
                case "dock":
                    return dockMenu;
                case "dockstack":
                    return stackPopup;
                case "forcequit":
                    return forceQuit;
                case "sharePicker":
                    return sharePicker;
                case "confirm":
                    return confirmDialog;
                case "appabout":
                    return appAbout;
                case "notice":
                    return noticeDialog;
                case "tiling":
                    return tilingPopover;
                case "tilingSuggest":
                    return tilingSuggestions;
                case "emoji":
                    return emojiPanel;
                }
                return null;
            }

            onLoaded: {
                // A menu's submenus open inside the screen: to the left of the menu when there is no room on the right.
                const menu = item as PopupMenu;
                if (menu)
                    menu.bounds = win.contentItem;
                (item as Item).forceActiveFocus();
            }
        }

        Component {
            id: systemMenu
            SystemMenu {}
        }

        Component {
            id: appMenu
            AppMenu {}
        }

        // An application's own menu (T1/T2, qs.menubar BridgeMenu).
        Component {
            id: bridgeMenu
            BridgeMenu {}
        }

        // A status item's own menu (StatusNotifierItem, DBusMenu).
        Component {
            id: trayMenu
            TrayMenu {}
        }

        // The Now Playing status item's popover: the Quick Settings module on its own.
        Component {
            id: nowPlayingPopover
            NowPlayingPopover {}
        }

        // An ongoing activity's popover (ADR-0052): what an app published, drawn by the shell.
        Component {
            id: ongoingPopover
            OngoingPopover {}
        }

        Component {
            id: volumeMenu
            VolumeMenu {}
        }

        Component {
            id: networkMenu
            NetworkMenu {}
        }

        Component {
            id: batteryMenu
            BatteryMenu {}
        }

        Component {
            id: screenShareMenu
            ScreenShareMenu {}
        }

        Component {
            id: inputMenu
            InputMenu {}
        }

        Component {
            id: controlCenter
            ControlCenter {}
        }

        Component {
            id: dockMenu
            DockMenu {}
        }

        Component {
            id: stackPopup
            StackPopup {}
        }

        Component {
            id: forceQuit
            ForceQuitPanel {}
        }

        Component {
            id: sharePicker
            SharePickerPanel {}
        }

        Component {
            id: confirmDialog
            ConfirmDialog {}
        }

        Component {
            id: appAbout
            AppAboutPanel {}
        }

        Component {
            id: noticeDialog
            NoticeDialog {}
        }

        // The tiling popover of a window's zoom light (docs/specs/tiling.md TL22-TL26).
        Component {
            id: tilingPopover
            TilingPopover {}
        }

        // The tiling suggestions in an empty zone of a layout (docs/specs/tiling.md TL28).
        Component {
            id: tilingSuggestions
            TilingSuggestions {}
        }

        // Emoji & Symbols at the pointer (ADR-0045 OC-3, docs/specs/clipboard.md ES-2).
        Component {
            id: emojiPanel
            EmojiPanel {}
        }
    }
}
