pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services
import qs.widgets
import "../../Calendar.js" as CalendarMath

// Calendar widget: today's date (small); month grid with today highlighted, first weekday from Settings > General >
// Language & Region (region.firstDayOfWeek, else the formats') (medium: beside the date, large: full width).
WidgetBase {
    id: root

    readonly property date now: FixedTime.date(clock.date)
    // The formats (region.formats) are Qt.locale() once the Translator applied them; reading the key here re-evaluates the
    // binding when they change.
    readonly property int firstDay: CalendarMath.firstDay(Settings.regionFirstDayOfWeek, Settings.regionFormats !== "auto" ? Qt.locale(Settings.regionFormats).firstDayOfWeek : Qt.locale().firstDayOfWeek)
    readonly property var weeks: CalendarMath.monthGrid(now.getFullYear(), now.getMonth(), firstDay)
    readonly property var order: CalendarMath.weekdayOrder(firstDay)
    readonly property string monthText: Qt.locale().toString(now, "MMMM yyyy")

    WallClock {
        id: clock
        enabled: root.active
    }

    Accessible.role: Accessible.StaticText
    Accessible.name: qsTr("Calendar, %1").arg(Qt.locale().toString(now, Qt.locale().dateFormat(Locale.LongFormat)))

    // Small and medium: the day.
    Column {
        visible: !root.isLarge
        x: root.padding
        y: root.padding
        width: root.isMedium ? Math.min(root.width * Tokens.widgetDateColumnRatio, Tokens.widgetCell - root.padding) : root.width - 2 * root.padding
        spacing: Tokens.spacingXs

        WidgetLabel {
            width: parent.width
            text: Qt.locale().toString(root.now, "dddd")
            color: Appearance.colors.accentGlass
            font.weight: Tokens.typographyMenuBoldWeight
        }

        WidgetLabel {
            width: parent.width
            text: String(root.now.getDate())
            size: Tokens.widgetBigSize
            font.weight: Tokens.typographyMenuBoldWeight
        }

        WidgetLabel {
            width: parent.width
            text: Qt.locale().toString(root.now, "MMMM")
            color: Appearance.colors.textSecondary
        }
    }

    // Medium and large: the month.
    Item {
        id: month

        visible: !root.isSmall
        x: root.isLarge ? root.padding : root.width * Tokens.widgetDateColumnRatio + root.padding
        y: root.padding
        width: root.width - x - root.padding
        height: root.height - 2 * root.padding

        WidgetLabel {
            id: title
            visible: root.isLarge
            width: parent.width
            text: root.monthText
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyMenuBoldWeight
        }

        Grid {
            id: grid

            readonly property real cellW: width / 7
            readonly property real cellH: height / 7

            y: title.visible ? title.height + Tokens.spacingSm : 0
            width: parent.width
            height: parent.height - y
            columns: 7

            Repeater {
                model: root.order

                WidgetLabel {
                    required property int modelData

                    width: grid.cellW
                    height: grid.cellH
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: Qt.locale().dayName(modelData, Locale.NarrowFormat)
                    color: Appearance.colors.textSecondary
                    font.pixelSize: Tokens.typographyCaptionSize
                }
            }

            Repeater {
                // 6 week rows at most; missing rows stay empty so that the grid keeps its height.
                model: root.weeks.reduce((all, week) => all.concat(week), [])

                Item {
                    id: day

                    required property var modelData
                    readonly property bool today: modelData.inMonth && modelData.day === root.now.getDate()

                    width: grid.cellW
                    height: grid.cellH

                    Rectangle {
                        anchors.centerIn: parent
                        width: Math.min(parent.width, parent.height)
                        height: width
                        radius: width / 2
                        visible: day.today
                        color: Appearance.colors.selection
                    }

                    WidgetLabel {
                        anchors.fill: parent
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        text: String(day.modelData.day)
                        font.pixelSize: Tokens.typographyCaptionSize
                        font.weight: day.today ? Tokens.typographyMenuBoldWeight : Tokens.typographyMenuWeight
                        color: day.today ? Appearance.colors.selectionText : (day.modelData.inMonth ? Appearance.colors.text : Appearance.withAlpha(Appearance.colors.textSecondary, Tokens.materialDisabledOpacity))
                    }
                }
            }
        }
    }
}
