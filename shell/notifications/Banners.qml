pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.osd
import qs.services
import qs.platform

// Banner stack, top-right under the menu bar, on ONE screen: the main display (MainDisplay,
// ADR-0044; the focused one when none is known). A single window and a single view, so there is exactly one set of
// banner delegates (hover state and expiry belong to the one visible banner). The window is
// mapped only while a banner exists or one is still leaving; banners exist only for the rows that are shown
// (the rest of the queue is just model rows with an empty slot). While the OSD pill is visible the stack sits
// below it, so the two never overlap.
// Nothing pops (UI audit 2026-11-05 U1): the view is not a ListView over the notification model. `rows` mirrors the model
// (see sync) and keeps a banner that left it, flagged `gone`, until its own exit has finished; only then is the row removed,
// at a slot height of 0. A Column stacks the slots, so the heights are the only thing that moves anything: a leaving banner
// slides out to the right while it fades (a swiped banner carries on from where the drag left it) and its slot closes, so
// the banners below rise with it; a new banner's slot opens the same way, so the ones below glide down. No view drops a
// delegate and re-lays out afterwards (the ListView did, one or two frames after the exit: the stack jumped). Under Reduce
// Motion nothing moves: the leaving banner fades where it stands and the gap closes at once, the others jump (ADR-0039
// step 5). The model itself drops a banner at once (timers, hover holds and keys stay exactly as before).
// This file is the window; the stack, its rows and their motion are BannerStack.qml.
// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: win

    // The banners show on the main display (macOS: notifications appear on the display that holds the menu bar and Dock, ADR-0044).
    readonly property string targetName: MainDisplay.screenName !== "" ? MainDisplay.screenName : Compositor.activeScreenName
    readonly property var targetScreen: {
        for (const s of Quickshell.screens) {
            if (s.name === targetName)
                return s;
        }
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }
    readonly property int pad: Tokens.spacingLg
    // Space taken by the OSD pill (plus its gap) while it is on this screen.
    readonly property real osdOffset: Osd.shown && targetScreen !== null && targetScreen.name === Osd.screenName ? Tokens.osdHeight + Tokens.osdGap : 0
    readonly property int bannerCount: Notifications.bannerCount

    screen: targetScreen
    // The Notifications column and Quick Settings replace the banners while they are open (their modules float over the
    // same area, and a banner would show through the gaps between them). The last banner's exit keeps the window up.
    visible: targetScreen !== null && stack.rowCount > 0 && !Notifications.centerOpen && Popups.kind !== "controlcenter"
    anchors {
        top: true
        right: true
    }
    // No layer-shell margins: the offset under the menu bar lives inside the transparent window.
    implicitWidth: Tokens.notificationBannerWidth + 2 * win.pad
    // A fixed height (the screen's): the surface is never resized while banners move, so no frame shows a resized or
    // stale surface (UI audit U1); the input mask and the blur regions follow the cards.
    implicitHeight: win.targetScreen ? win.targetScreen.height : 0
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "grassfield-banners"
    // qmllint disable missing-type
    mask: Region {
        item: stack.inputItem
    }
    BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.visible ? blur : null
    // qmllint enable missing-type

    Region {
        id: blur
        regions: blurRegions.instances
    }

    // One region per drawn card, as explicit rects (BannerStack.cards: why there).
    Variants {
        id: blurRegions
        model: stack.cards

        Region {
            required property var modelData
            x: modelData.blurX
            y: modelData.blurY
            width: modelData.blurW
            height: modelData.blurH
            radius: Tokens.radiusBanner
        }
    }

    BannerStack {
        id: stack
        anchors.fill: parent
        screenWidth: win.targetScreen ? win.targetScreen.width : 0
        osdOffset: win.osdOffset
    }
}
