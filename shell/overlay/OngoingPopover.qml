pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.platform
import qs.services
import qs.overlay.controlcenter
import "../platform/Ongoing.js" as Ongoing

// An ongoing activity's popover (popup kind "ongoing", ADR-0052 D6), under its menu bar item: the publishing app's icon and
// name (the desktop entry the bridge verified, never anything the app drew), the title and subtitle it published (plain
// text), its progress bar or its time, and at most three buttons the shell draws with the app's labels. A button sends its
// action to the app and closes the popover. Locked (the bar is not shown then; a defence in depth): "In Progress", the kind's
// symbol and the progress only. Closes when the activity ends.
FocusScope {
    id: root

    readonly property string activityId: Popups.data.id !== undefined ? String(Popups.data.id) : ""
    readonly property var item: Ongoing.view(Ongoing.find(MenuBridge.ongoing, root.activityId), SessionState.locked)
    readonly property bool alive: root.item !== null
    readonly property bool redacted: root.alive && root.item.redacted
    readonly property var entry: root.alive && root.item.app !== "" ? Apps.lookup(root.item.app) : null
    readonly property string appName: root.alive && root.item.app !== "" ? Apps.nameFor(root.item.app) : ""
    readonly property real pad: Tokens.quicksettingsPadding
    // A timer's time is the menu bar's own (one clock, MenuBridge.ongoingNow).
    readonly property var shown: root.alive ? Ongoing.compact(root.item, MenuBridge.ongoingNow) : ({kind: "none"})

    width: Tokens.ongoingPopoverWidth
    height: column.implicitHeight + 2 * root.pad
    Accessible.role: Accessible.Window
    Accessible.name: root.redacted || !root.alive ? qsTr("In Progress") : root.item.title

    Keys.onEscapePressed: Popups.close()
    // Left/Right: the previous or next status menu, as Now Playing.
    Keys.onLeftPressed: Popups.stepMenu(-1)
    Keys.onRightPressed: Popups.stepMenu(1)
    onAliveChanged: {
        if (!root.alive)
            Qt.callLater(Popups.close);
    }

    Material {
        anchors.fill: parent
        glassClass: "menu"
        radius: Tokens.radiusMenu
    }

    Column {
        id: column
        x: root.pad
        y: root.pad
        width: root.width - 2 * root.pad
        spacing: Tokens.spacingSm

        Row {
            width: parent.width
            spacing: Tokens.spacingSm

            // The app's own icon (resolved by the shell from the verified desktop id); the kind's symbol when redacted.
            TintedIcon {
                visible: !root.redacted
                size: Tokens.ongoingAppIconSize
                anchors.verticalCenter: parent.verticalCenter
                source: root.redacted ? "" : ThemeIcons.appIcon(root.entry ? root.entry.icon : (root.alive ? root.item.app : ""), "application-x-executable")
                asynchronous: true
            }

            Icon {
                visible: root.redacted
                size: Tokens.ongoingAppIconSize
                anchors.verticalCenter: parent.verticalCenter
                color: Appearance.colors.text
                name: root.alive ? Ongoing.symbolOf(root.item.kind) : ""
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Tokens.ongoingAppIconSize - Tokens.spacingSm

                Caption {
                    width: parent.width
                    visible: text !== ""
                    text: root.redacted ? "" : root.appName
                }

                Label {
                    width: parent.width
                    text: root.redacted || !root.alive ? qsTr("In Progress") : root.item.title
                }
            }
        }

        Caption {
            width: parent.width
            visible: text !== ""
            wrapMode: Text.Wrap
            maximumLineCount: 2
            text: root.redacted || !root.alive ? "" : root.item.subtitle
        }

        // A time (countdown or elapsed) in tabular digits, as the bar's item.
        Label {
            visible: root.shown.kind === "time"
            text: root.shown.kind === "time" ? root.shown.text : ""
            font.pixelSize: Tokens.typographyTitleSize
            font.features: {
                "tnum": 1
            }
        }

        // The progress: a bar with its fill, or the sweep while the app gives no amount (a timer has none).
        Row {
            width: parent.width
            spacing: Tokens.spacingSm
            visible: root.alive && root.shown.kind !== "time"

            ProgressBar {
                id: bar
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - (percent.visible ? percent.width + Tokens.spacingSm : 0)
                from: 0
                to: 1
                value: root.alive && root.item.progress !== null ? root.item.progress : 0
                indeterminate: root.alive && root.item.progress === null
                accessibleName: root.redacted || !root.alive ? qsTr("In Progress") : root.item.title
            }

            Caption {
                id: percent
                anchors.verticalCenter: parent.verticalCenter
                visible: root.shown.kind === "percent"
                text: root.shown.kind === "percent" ? qsTr("%1%").arg(root.shown.value) : ""
                font.features: {
                    "tnum": 1
                }
            }
        }

        // The app's buttons (at most three), in the order it gave them, right-aligned as a macOS popover's.
        Row {
            anchors.right: parent.right
            spacing: Tokens.spacingSm
            visible: root.alive && root.item.actions.length > 0

            Repeater {
                model: root.alive ? root.item.actions : []

                delegate: Button {
                    required property var modelData

                    push: true
                    text: modelData.label
                    onClicked: {
                        MenuBridge.ongoingAction(root.activityId, modelData.id);
                        Popups.close();
                    }
                }
            }
        }
    }
}
