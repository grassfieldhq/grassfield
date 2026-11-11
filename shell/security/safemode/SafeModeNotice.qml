pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui

// The safe-mode notice's window (ADR-0041 step 1, S4): one small layer surface the size of the alert (SafeModeCard.qml) and
// its shadow, no dim and nothing full screen. With no anchor the compositor centres it on the output it puts it on, the one
// with the focus (wlr-layer-shell: no output given). Created by SafeMode.qml only while the notice is on screen (a LazyLoader
// by source: the security process keeps no window the rest of the time, and a window that fails to load costs the notice,
// never the lock); destroyed as soon as the session locks or a polkit or secret sheet of this process opens, so it never
// covers the lock or takes a key meant for a sheet. Overlay, so a full-screen window cannot hide it; the keyboard on demand,
// as an app's alert: it has the keys when it appears and gives them up when the user clicks a window to save their work.
Scope {
    id: root

    // Bound by SafeMode.qml once this object exists.
    property string running: ""
    property string failure: ""

    signal tryAgain
    signal logOut

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        // Room for the alert's shadow (Material.shadowMargin) around it.
        readonly property int margin: Tokens.shadowBlur + Tokens.shadowOffsetY

        implicitWidth: card.width + 2 * win.margin
        implicitHeight: card.height + 2 * win.margin
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "grassfield-safe-mode"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        // qmllint disable missing-type
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 ? blurRegion : null
        mask: Region {
            item: card
        }
        // qmllint enable missing-type

        Region {
            id: blurRegion
            item: card
            radius: Tokens.radiusAlert
        }

        SafeModeCard {
            id: card
            x: win.margin
            y: win.margin
            focus: true
            running: root.running
            failure: root.failure
            onTryAgain: root.tryAgain()
            onLogOut: root.logOut()
            Component.onCompleted: card.takeFocus()
        }
    }
}
