pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui

// The glass row's picture of Settings > Appearance (macOS 27, docs/audits/settings-parity-2026-10-26.md § Appearance): the
// Grassfield artwork with three glass controls along its top (a two-button pill, a round button, a search capsule) and a
// caption band along its bottom, then a slider between a clear-glass and a tinted-glass symbol. The controls show the glass
// the shell's surfaces get at `transparency` (material.transparency): the artwork under them really blurred, their tint
// Appearance.tintAlpha of it. The slider runs from clear (left, the most transparent) to tinted (right), as macOS's.
Item {
    id: root

    // material.transparency, 0 (opaque) to 1 (the most transparent).
    property real transparency: Tokens.materialDefaultTransparency

    signal moved(real transparency)
    // The knob was let go: the host writes the last position now.
    signal released

    // The tint of the glass controls' class (glass.controls), as the shell draws them at this transparency over a backdrop it has
    // not measured (the worst case), where it was the single tint every class shared before the classes; opaque under Reduce
    // Transparency (ADR-0039 step 15).
    readonly property real tint: Appearance.glassAlphaOver("controls", Appearance.reduceTransparency ? 0 : root.transparency, null)

    implicitWidth: Tokens.settingsGlassPreviewWidth
    implicitHeight: Tokens.settingsGlassSliderCenter - Tokens.settingsGlassPreviewTop + Tokens.controlSliderKnob

    component Glass: Rectangle {
        radius: height / 2
        color: Appearance.withAlpha(Appearance.colors.materialTint, root.tint)
        border.width: Tokens.appsBorderWidth
        border.color: Appearance.withAlpha(Appearance.colors.materialHighlight, Appearance.dark ? Tokens.materialHighlightOpacity : Tokens.materialHighlightOpacityLight)
    }

    Item {
        id: preview
        width: Tokens.settingsGlassPreviewWidth
        height: Tokens.settingsGlassPreviewHeight
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: previewMask
        }

        GrassfieldArtwork {
            id: artwork
            anchors.fill: parent
        }

        // The artwork blurred, seen only through the controls (a real blur of what lies under them).
        MultiEffect {
            anchors.fill: parent
            source: artwork
            blurEnabled: !Appearance.reduceTransparency
            blur: 1
            blurMax: Tokens.settingsGlassControlHeight
            maskEnabled: true
            maskSource: controlsMask
        }

        Item {
            id: controlsMask
            anchors.fill: parent
            visible: false
            layer.enabled: true

            Rectangle {
                x: pill.x
                y: pill.y
                width: pill.width
                height: pill.height
                radius: height / 2
            }
            Rectangle {
                x: round.x
                y: round.y
                width: round.width
                height: round.height
                radius: height / 2
            }
            Rectangle {
                x: search.x
                y: search.y
                width: search.width
                height: search.height
                radius: height / 2
            }
        }

        Glass {
            id: pill
            x: Tokens.settingsGlassControlInset
            y: Tokens.settingsGlassControlInset
            width: Tokens.settingsGlassControlPillWidth
            height: Tokens.settingsGlassControlHeight

            Row {
                anchors.centerIn: parent
                spacing: Tokens.settingsGlassControlHeight - Tokens.menuIconSize

                Icon {
                    name: "plus"
                    size: Tokens.menuIconSize
                    color: Appearance.colors.text
                }
                Icon {
                    name: "list"
                    size: Tokens.menuIconSize
                    color: Appearance.colors.text
                }
            }
        }

        Glass {
            id: round
            x: pill.x + pill.width + Tokens.settingsGlassControlGap
            y: pill.y
            width: Tokens.settingsGlassControlHeight
            height: Tokens.settingsGlassControlHeight

            Icon {
                anchors.centerIn: parent
                name: "overview"
                size: Tokens.menuIconSize
                color: Appearance.colors.text
            }
        }

        Glass {
            id: search
            x: preview.width - Tokens.settingsGlassControlInset - width
            y: pill.y
            width: Tokens.settingsGlassControlSearchWidth
            height: Tokens.settingsGlassControlHeight

            Row {
                x: Tokens.spacingMd
                anchors.verticalCenter: parent.verticalCenter
                spacing: Tokens.spacingSm

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "search"
                    size: Tokens.menuIconSize
                    color: Appearance.colors.textSecondary
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: qsTr("Search")
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
            }
        }

        // The caption band.
        Rectangle {
            y: preview.height - height
            width: preview.width
            height: Tokens.settingsGlassCaptionHeight
            color: Appearance.withAlpha(Appearance.colors.windowBackground, Tokens.settingsGlassCaptionOpacity)

            Text {
                textFormat: Text.PlainText
                x: Tokens.settingsGlassCaptionX
                y: Tokens.settingsGlassCaptionBaseline - baselineOffset
                width: parent.width - 2 * x
                elide: Text.ElideRight
                text: qsTr("Welcome to Grassfield")
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.settingsGlassCaptionSize
                font.weight: Tokens.typographyMenuBoldWeight
            }
        }
    }

    Rectangle {
        id: previewMask
        visible: false
        layer.enabled: true
        width: preview.width
        height: preview.height
        radius: Tokens.settingsGlassPreviewRadius
    }

    // Clear glass, the slider, tinted glass (the slider's value is 1 - transparency), centred under the picture.
    Item {
        x: Math.round((preview.width - width) / 2 * 2) / 2
        y: Tokens.settingsGlassSliderCenter - Tokens.settingsGlassPreviewTop - height / 2
        width: 2 * (Tokens.settingsGlassSymbolWidth + Tokens.settingsGlassSymbolGap) + Tokens.settingsGlassSliderWidth
        height: Tokens.controlSliderKnob

        Icon {
            id: clearSymbol
            anchors.verticalCenter: parent.verticalCenter
            name: "glass-clear"
            size: Tokens.settingsGlassSymbolWidth
            color: Appearance.windowSecondary
        }

        Slider {
            x: clearSymbol.width + Tokens.settingsGlassSymbolGap
            anchors.verticalCenter: parent.verticalCenter
            width: Tokens.settingsGlassSliderWidth
            accessibleName: qsTr("Transparency")
            from: 0
            to: 1
            stepSize: 0.05
            ticks: 2
            value: 1 - root.transparency
            onMoved: v => root.moved(Math.round((1 - v) * 100) / 100)
            onReleased: root.released()
        }

        Icon {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            name: "glass-tinted"
            size: Tokens.settingsGlassSymbolWidth
            color: Appearance.windowSecondary
        }
    }
}
