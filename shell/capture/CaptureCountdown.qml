pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import "../services/CaptureFile.js" as CaptureFile

// The capture timer's countdown (spec docs/specs/system-dialogs.md "Capture toolbar" SC12, ADR-0045 OC-1): while the helper
// counts down (CaptureState, its private state), the seconds left on a glass plate centred on what will be captured (the
// display, the window or the area), on that display only. It takes no keyboard (the window being captured stays key) and no
// click; it goes the moment the time is up, without a fade (Hyprland: no_anim on its namespace, windows.lua), and the helper
// waits half a second more before the picture, so the plate is in none.
Variants {
    id: root

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property var area: ({
                name: win.modelData ? win.modelData.name : "",
                x: win.modelData ? win.modelData.x : 0,
                y: win.modelData ? win.modelData.y : 0,
                width: win.modelData ? win.modelData.width : 0,
                height: win.modelData ? win.modelData.height : 0
            })
        readonly property var screens: Quickshell.screens.map(s => ({
                    name: s.name,
                    x: s.x,
                    y: s.y,
                    width: s.width,
                    height: s.height
                }))
        readonly property bool shown: CaptureState.countingDown && CaptureFile.plateScreen(CaptureState.state, win.screens) === win.area.name
        readonly property var centre: CaptureFile.plateCentre(CaptureState.state, win.area)

        screen: modelData
        visible: shown
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-capture-countdown"
        // qmllint disable missing-type
        // Empty input region: clicks go through to what is being captured.
        mask: Region {}
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.shown ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: plate
            radius: Tokens.captureCountdownRadius
        }

        Item {
            id: plate

            width: Tokens.captureCountdownSize
            height: Tokens.captureCountdownSize
            x: Math.round(win.centre.x - width / 2)
            y: Math.round(win.centre.y - height / 2)
            Accessible.role: Accessible.StaticText
            Accessible.name: seconds.text

            // A text surface: the menus' class.
            Material {
                glassClass: "controls"
                anchors.fill: parent
                radius: Tokens.captureCountdownRadius
            }

            Text {
                id: seconds

                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: String(CaptureState.secondsLeft)
                color: Appearance.colors.text
                font.family: Appearance.fontFamilyFor(Tokens.captureCountdownTextSize)
                font.pixelSize: Tokens.captureCountdownTextSize
                font.letterSpacing: Appearance.trackingFor(Tokens.captureCountdownTextSize)
                font.weight: Tokens.typographyTitleWeight
            }
        }
    }
}
