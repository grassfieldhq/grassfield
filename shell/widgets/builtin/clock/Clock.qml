pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Grassfield.Ui
import qs.services
import qs.widgets

// Clock widget: digital time and date (small); analog face drawn in QML plus digital time (medium, large).
WidgetBase {
    id: root

    readonly property bool analog: !isSmall
    readonly property date now: FixedTime.date(clock.date)
    // qsTranslate with this file's context, not qsTr (see Registry.qml: qsTr stayed English in the first moments of a French session).
    readonly property string timeText: Qt.locale().toString(now, Qt.locale().timeFormat(Locale.ShortFormat))
    readonly property string dateText: Qt.locale().toString(now, qsTranslate("Clock", "dddd, MMMM d"))

    WallClock {
        id: clock
        enabled: root.active
        // The seconds hand only exists on the analog face.
        seconds: root.analog
    }

    Accessible.role: Accessible.StaticText
    Accessible.name: qsTranslate("Clock", "Clock, %1, %2").arg(timeText).arg(dateText)

    // Analog face.
    Item {
        id: face

        readonly property real edge: root.isLarge ? Math.min(root.width - 2 * root.padding, root.height * Tokens.widgetClockFaceRatio) : root.height - 2 * root.padding

        visible: root.analog
        x: root.isLarge ? (root.width - width) / 2 : root.padding
        y: root.padding
        width: edge
        height: edge

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            // One device pixel at every scale (UI audit 2026-11-05 U37).
            border.width: 1 / Math.max(1, Screen.devicePixelRatio)
            border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
        }

        Repeater {
            model: 12

            Rectangle {
                id: tick

                required property int index
                readonly property bool major: index % 3 === 0

                x: face.width / 2 - width / 2
                y: Tokens.spacingXs
                width: major ? Tokens.widgetAnalogTickWidth : 1
                height: major ? Tokens.spacingSm : Tokens.spacingXs
                color: major ? Appearance.colors.text : Appearance.colors.textSecondary
                antialiasing: true
                transform: Rotation {
                    origin.x: tick.width / 2
                    origin.y: face.height / 2 - Tokens.spacingXs
                    angle: tick.index * 30
                }
            }
        }

        Hand {
            angle: (root.now.getHours() % 12 + root.now.getMinutes() / 60) * 30
            length: 0.5
        }

        Hand {
            angle: (root.now.getMinutes() + root.now.getSeconds() / 60) * 6
            length: 0.78
        }

        Hand {
            visible: root.analog
            width: 1
            angle: root.now.getSeconds() * 6
            length: 0.85
            tint: Appearance.colors.accent
        }

        Rectangle {
            anchors.centerIn: parent
            width: Tokens.spacingSm
            height: width
            radius: width / 2
            color: Appearance.colors.accent
        }
    }

    // Hour, minute, second hands; a hand is a bar rotated about the face center.
    component Hand: Rectangle {
        id: hand

        property real angle: 0
        property real length: 0.5
        property color tint: Appearance.colors.text

        x: face.width / 2 - width / 2
        y: face.height / 2 - height
        width: Tokens.widgetAnalogHandWidth
        height: face.height / 2 * length
        radius: width / 2
        color: tint
        antialiasing: true
        transform: Rotation {
            origin.x: hand.width / 2
            origin.y: hand.height
            angle: hand.angle
        }
    }

    // Digital readout: below the face (large), right of it (medium), or filling the tile (small).
    Column {
        id: digital

        x: root.isSmall ? root.padding : (root.isLarge ? root.padding : face.x + face.width + root.padding)
        y: root.isLarge ? face.y + face.height + Tokens.spacingSm : (root.isMedium ? (root.height - height) / 2 : root.padding)
        width: root.isMedium ? root.width - x - root.padding : root.width - 2 * root.padding
        spacing: Tokens.spacingXs

        WidgetLabel {
            width: parent.width
            visible: root.isSmall
            text: Qt.locale().toString(root.now, "dddd")
            color: Appearance.colors.accentGlass
            font.weight: Tokens.typographyMenuBoldWeight
        }

        WidgetLabel {
            width: parent.width
            text: root.timeText
            size: root.isSmall ? Tokens.widgetBigSize : Tokens.widgetGlyphSize
            font.weight: Tokens.typographyMenuBoldWeight
            horizontalAlignment: root.isLarge ? Text.AlignHCenter : Text.AlignLeft
            fontSizeMode: Text.Fit
            minimumPixelSize: Tokens.typographyBodySize
        }

        WidgetLabel {
            width: parent.width
            text: root.isSmall ? Qt.locale().toString(root.now, qsTranslate("Clock", "MMMM d")) : root.dateText
            color: Appearance.colors.textSecondary
            horizontalAlignment: root.isLarge ? Text.AlignHCenter : Text.AlignLeft
        }
    }
}
