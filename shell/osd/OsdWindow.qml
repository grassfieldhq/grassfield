pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform

// Volume/brightness OSD: a compact pill under the menu bar at the top-right (icon + level bar),
// on the active display (Compositor.activeScreenName), a brightness change on the display that changed (Osd.screenName).
// Never takes input.
Variants {
    id: root

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        // The OSD shows on the active display (macOS), like Banners offsets for it; a brightness change shows on the display that
        // changed (Osd.screenName, ADR-0045 OC-4), which is the active one but for the built-in panel driven from another.
        readonly property bool primary: modelData !== null && modelData.name === Osd.screenName
        readonly property int pad: Tokens.spacingLg

        // The pill is in view (shown, or fading out).
        readonly property bool showing: Osd.shown || pill.opacity > 0
        // A full-screen window on this output: a mapped overlay surface, even an empty one, would keep the compositor from
        // scanning the window out directly (games, video), so the idle surface is unmapped there.
        readonly property bool fullscreenHere: modelData !== null && Compositor.fullscreenOn(modelData.name, Compositor.topologyRevision)

        screen: modelData
        // Mapped for good on the display the OSD shows on, empty and without input while hidden: the first key press after a
        // hide only fades the pill in, it no longer maps a surface and waits for its first frame (as Overview's surface).
        visible: primary && (showing || !fullscreenHere)
        anchors {
            top: true
            right: true
        }
        implicitWidth: Tokens.osdWidth + 2 * win.pad
        implicitHeight: pill.y + pill.height + win.pad
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-osd"
        // qmllint disable missing-type
        // Empty input region: clicks go through.
        mask: Region {}
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.visible && win.showing ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: pill
            radius: pill.height / 2
        }

        Item {
            id: pill
            x: win.pad
            y: Tokens.menubarHeight + Tokens.osdGap
            width: Tokens.osdWidth
            height: Tokens.osdHeight
            opacity: Osd.shown ? 1 : 0
            Accessible.role: Accessible.ProgressBar
            Accessible.name: Osd.kind === "inputsource" ? qsTr("Input source %1").arg(Osd.label) : Osd.kind === "keyboard" ? qsTr("Keyboard brightness %1%").arg(Math.round(Osd.level * 100)) : Osd.kind === "brightness" ? qsTr("Brightness %1%").arg(Math.round(Osd.level * 100)) : qsTr("Volume %1%").arg(Math.round(Osd.level * 100))

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionNormal)
                }
            }

            Material {
                glassClass: "controls"
                anchors.fill: parent
                radius: pill.height / 2
            }

            Icon {
                id: glyph
                x: Tokens.spacingLg
                anchors.verticalCenter: parent.verticalCenter
                size: Tokens.osdIconSize
                name: Osd.iconName
            }

            Text {
                id: sourceName
                visible: Osd.kind === "inputsource"
                textFormat: Text.PlainText
                anchors {
                    left: glyph.right
                    leftMargin: Tokens.spacingMd
                    right: parent.right
                    rightMargin: Tokens.spacingLg
                    verticalCenter: parent.verticalCenter
                }
                text: Osd.label
                elide: Text.ElideRight
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyMenuSize
                font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                font.weight: Tokens.typographyMenuBoldWeight
            }

            Rectangle {
                id: track
                visible: Osd.kind !== "inputsource"
                anchors {
                    left: glyph.right
                    leftMargin: Tokens.spacingMd
                    right: parent.right
                    rightMargin: Tokens.spacingLg
                    verticalCenter: parent.verticalCenter
                }
                height: Tokens.osdBarHeight
                radius: height / 2
                color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2)

                Rectangle {
                    id: level

                    // The kind the bar shows now: when another kind arrives (volume after brightness), the bar takes the new
                    // level at once instead of sliding from the previous kind's (LOW, UI audit 2026-11-05). Osd sets the
                    // kind before the level; the Behavior is enabled again once that level is in.
                    property bool steady: true
                    readonly property string kind: Osd.kind

                    width: track.width * (Osd.muted ? 0 : Osd.level)
                    height: parent.height
                    radius: parent.radius
                    color: Appearance.colors.text

                    onKindChanged: {
                        level.steady = false;
                        Qt.callLater(() => level.steady = true);
                    }

                    // Under Reduce Motion the level jumps; the OSD itself still fades in and out (ADR-0039 step 5).
                    Behavior on width {
                        enabled: !Appearance.reduceMotion && level.steady
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionFast)
                        }
                    }
                }
            }
        }
    }
}
