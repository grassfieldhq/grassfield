pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui

// The idle dim (SEC7, ADR-0010): one overlay layer surface per output, no input region (pointer motion reaches the compositor
// and counts as activity), no keyboard focus. Created by Idle.qml only while the screens dim and for the fade that follows
// (a LazyLoader by source, ADR-0041 S2: the security process keeps no layer surface per output the rest of the time, and a
// file of the display that fails to load costs the dim, never the lock). Display only: nothing locks, unlocks or waits for it.
Scope {
    id: root

    // Set by Idle.qml once this object exists (from false: the dim fades in).
    property bool dimmed: false

    Variants {
        model: Quickshell.screens

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData

            screen: modelData
            visible: root.dimmed || shade.opacity > 0
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            focusable: false
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "grassfield-idle-dim"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            // qmllint disable missing-type
            mask: Region {}
            // qmllint enable missing-type

            Rectangle {
                id: shade
                anchors.fill: parent
                color: Tokens.colorDark.shadow
                opacity: root.dimmed ? Tokens.idleDimOpacity : 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: Appearance.duration(root.dimmed ? Tokens.idleDimFade : Tokens.motionFast)
                    }
                }
            }
        }
    }
}
