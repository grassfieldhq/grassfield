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
// Nothing pops (UI audit 2026-11-05 U1): the model drops a banner at once (timers, hover holds and keys stay exactly
// as before); the view keeps its delegate for the exit, which slides out to the right while it fades (a swiped banner
// carries on from where the drag left it) and closes its gap, so the banners below rise with it; the ones a new banner
// pushes down glide. Under Reduce Motion nothing moves: the leaving banner fades where it stands and the others jump
// (ADR-0039 step 5).
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
    // The close button stands out of the card's top-left corner by a third of its size, on whole device pixels (LOW,
    // UI audit 2026-11-05); the input region takes it in.
    readonly property real closeOverhang: Math.round(Tokens.notificationCloseSize / 3 * stack.dpr) / stack.dpr
    // The cards drawn now, leaving ones included: each has a blur region until its delegate is gone.
    property var cards: []
    readonly property int bannerCount: Notifications.bannerCount

    onBannerCountChanged: settle.restart()

    screen: targetScreen
    // The Notifications column and Quick Settings replace the banners while they are open (their modules float over the
    // same area, and a banner would show through the gaps between them). The last banner's exit keeps the window up.
    visible: targetScreen !== null && (win.bannerCount > 0 || settle.running) && !Notifications.centerOpen && Popups.kind !== "controlcenter"
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
        item: inputArea
    }
    BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.visible ? blur : null
    // qmllint enable missing-type

    Region {
        id: blur
        regions: blurRegions.instances
    }

    Variants {
        id: blurRegions
        model: win.cards

        Region {
            required property Item modelData
            item: modelData
            radius: Tokens.radiusBanner
        }
    }

    // The window's input region: the shown banners (not a leaving one) and their close buttons' overhang.
    Item {
        id: inputArea
        x: stack.x - win.closeOverhang
        y: stack.y - win.closeOverhang
        width: stack.width + win.closeOverhang
        height: stack.stackHeight > 0 ? stack.stackHeight + win.closeOverhang : 0
    }

    // Runs after the banner count changes: it keeps the window up for the last banner's exit.
    Timer {
        id: settle
        interval: Math.max(stack.moveDuration, stack.fadeDuration)
    }

    ListView {
        id: stack

        readonly property real dpr: Math.max(1, Screen.devicePixelRatio)
        readonly property bool still: Appearance.reduceMotion
        readonly property int moveDuration: still ? 0 : Appearance.duration(Tokens.motionNormal)
        readonly property int fadeDuration: Appearance.duration(Tokens.motionNormal)
        // The height of the shown banners (the gap lives under each banner, inside its slot).
        readonly property real stackHeight: Math.max(0, contentHeight - Tokens.notificationBannerGap)

        x: win.pad
        // macOS: banners start where the Notifications column starts.
        y: Tokens.menubarHeight + Tokens.notificationCenterInset + win.osdOffset
        width: Tokens.notificationBannerWidth
        // Tall enough that every row has its delegate (the queued ones are empty slots); input and the window's size
        // follow the banners, not this.
        height: win.targetScreen ? win.targetScreen.height : 0
        interactive: false
        currentIndex: -1
        highlightFollowsCurrentItem: false
        keyNavigationEnabled: false
        model: Notifications.bannerModel

        // The banners make room for the OSD; under Reduce Motion they jump (ADR-0039 step 5).
        Behavior on y {
            enabled: !Appearance.reduceMotion
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionNormal)
                // A move: the move curve (ADR-0039 step 20).
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }
        }

        // The banners a new one pushes down glide to their new place; under Reduce Motion they jump. (A leaving banner
        // closes its own gap: see the delegate's exit.)
        displaced: Transition {
            enabled: !stack.still
            NumberAnimation {
                property: "y"
                duration: stack.moveDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }
        }

        delegate: Item {
            id: slot

            required property int index
            required property string key
            required property int nid
            required property string appName
            required property string appIcon
            required property string image
            required property string summary
            required property string bodyHtml
            required property real time
            required property int urgency
            required property string actionsJson

            // Queued banners (beyond the visible count) are empty slots: no banner, no height; a new banner and the one
            // that moves up from the queue slide in on their own (Banner's entrance). A removed row's index turns -1:
            // the slot keeps what it was, so a shown banner plays its exit and a queued one stays empty.
            property bool queued: true
            readonly property bool shown: !queued
            property bool leaving: false
            // The exit (UI audit 2026-11-05 U1): the card slides out to the right (the card itself moves, so its blur
            // region follows it as on the way in) while the slot fades and its height closes up, so the banners below
            // rise with it. The view holds the removed delegate (delayRemove) until the exit ends: a delegate in a
            // view's remove transition is dropped at the next model change (an arrival, another expiry), which cut
            // the exit short. Under Reduce Motion it fades where it stands, then the gap closes at once.
            property real slide: 0
            property real collapse: 0
            property Item card: null

            width: stack.width
            height: shown && banner.item ? ((banner.item as Item).height + Tokens.notificationBannerGap) * (1 - collapse) : 0
            visible: shown

            onIndexChanged: {
                if (index >= 0)
                    queued = index >= Tokens.notificationBannerMaxVisible;
            }
            Component.onCompleted: queued = index >= Tokens.notificationBannerMaxVisible
            ListView.onRemove: {
                slot.leaving = true;
                if (slot.shown)
                    exit.start();
            }
            Component.onDestruction: win.cards = win.cards.filter(c => c !== slot.card)

            SequentialAnimation {
                id: exit

                PropertyAction {
                    target: slot
                    property: "ListView.delayRemove"
                    value: true
                }

                ParallelAnimation {
                    NumberAnimation {
                        target: slot
                        property: "slide"
                        to: stack.still ? 0 : Tokens.notificationBannerWidth + win.pad
                        duration: stack.moveDuration
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.curve
                    }

                    NumberAnimation {
                        target: slot
                        property: "opacity"
                        to: 0
                        duration: stack.fadeDuration
                    }

                    SequentialAnimation {
                        PauseAnimation {
                            duration: stack.still ? stack.fadeDuration : 0
                        }

                        NumberAnimation {
                            target: slot
                            property: "collapse"
                            to: 1
                            duration: stack.moveDuration
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.curve
                        }
                    }
                }

                PropertyAction {
                    target: slot
                    property: "ListView.delayRemove"
                    value: false
                }
            }

            Loader {
                id: banner
                active: slot.shown
                onLoaded: {
                    slot.card = (item as Banner).cardItem;
                    win.cards = win.cards.concat([slot.card]);
                }
                onActiveChanged: {
                    if (!active && slot.card !== null) {
                        win.cards = win.cards.filter(c => c !== slot.card);
                        slot.card = null;
                    }
                }

                sourceComponent: Banner {
                    // The stack's area on the output (the window is anchored top-right): the backdrop of the glass (G-3).
                    backdropRect: Qt.rect(win.targetScreen ? win.targetScreen.width - win.pad - Tokens.notificationBannerWidth : 0, stack.y, Tokens.notificationBannerWidth, stack.stackHeight)
                    closeOverhang: win.closeOverhang
                    leaving: slot.leaving
                    exitSlide: slot.slide
                    key: slot.key
                    nid: slot.nid
                    appName: slot.appName
                    appIcon: slot.appIcon
                    image: slot.image
                    summary: slot.summary
                    bodyHtml: slot.bodyHtml
                    time: slot.time
                    urgency: slot.urgency
                    actionsJson: slot.actionsJson
                }
            }
        }
    }
}
