pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui

// Overview v2 backdrop (docs/specs/overview.md "Shell contract" 2), one per screen: the dim (and the blur, through
// BackgroundEffect) of the wallpaper and the desktop on the Bottom layer, namespace grassfield-overview-backdrop.
// The compositor draws the real windows between the Bottom and the Top layers, so they stay crisp above this dim, and
// the Dock and the menu bar (Top) stay above them. No input: the click on empty space is taken by the chrome surface.
// Mapped when the overview opens (same-layer surfaces stack in mapping order: above the Bottom-layer desktop widgets)
// and unmapped when its fade-out has finished. Reduce Motion: a crossfade of at most motion.reducedMax.
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

        readonly property bool shown: root.controller.open && !root.controller.thumbnailMode
        // 0 = clear, 1 = fully dimmed. While a swipe drives the Overview, the fingers' progress (Overview.gesture).
        property real progress: shown && root.controller.gesture.progress >= 0 ? root.controller.gesture.progress : (shown ? 1 : 0)

        screen: modelData
        visible: shown || progress > 0.001
        mask: Region {}
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-overview-backdrop"
        // qmllint disable missing-type
        // As the v1 overlay: blur only once fully dimmed (the compositor re-blurs the region every frame while the
        // surface animates), dropped when the fade-out starts.
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && shown && progress >= 1 ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: dim
        }

        Behavior on progress {
            NumberAnimation {
                // Each step of a swipe is drawn as it comes; the rest of the way animates from there.
                duration: root.controller.gesture.active ? 0 : Appearance.duration(Tokens.motionSlow)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }
        }

        Rectangle {
            id: dim
            anchors.fill: parent
            color: Appearance.withAlpha(Appearance.colors.shadow, Appearance.effectiveTransparency > 0 ? Tokens.overviewBackdropOpacity : Tokens.overviewBackdropOpacityOpaque)
            opacity: win.progress
        }
    }
}
