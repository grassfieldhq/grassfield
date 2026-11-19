pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Input Sources > +: choose an xkb layout or variant (Keyboard.parseLayouts of base.lst, by name); the field filters them. Add (or
// Return, or a double-click) hands the choice back (`chosen`); the ones already in use are left out.
Sheet {
    id: root

    property var layouts: ({names: {}, all: []})
    property var used: []
    property int chosen: -1
    readonly property string filter: root.fieldText.trim().toLowerCase()
    readonly property var matches: root.layouts.all.filter(l => !root.used.some(u => u.layout === l.layout && u.variant === l.variant)
        && (root.filter === "" || l.name.toLowerCase().indexOf(root.filter) >= 0 || l.layout === root.filter))

    signal picked(var source)

    title: qsTr("Add an Input Source")
    message: qsTr("Choose a keyboard layout.")
    confirmText: qsTr("Add")
    withField: true
    placeholder: qsTr("Search")

    function openWith(layouts: var, used: var): void {
        root.layouts = layouts;
        root.used = used;
        root.chosen = -1;
        root.setField("");
        root.open();
    }

    onFilterChanged: root.chosen = -1

    // The arrows move the choice while the field keeps the keyboard.
    Keys.onPressed: event => {
        if (event.key !== Qt.Key_Up && event.key !== Qt.Key_Down)
            return;
        const next = Math.max(0, Math.min(root.matches.length - 1, root.chosen < 0 ? 0 : root.chosen + (event.key === Qt.Key_Down ? 1 : -1)));
        if (root.matches.length > 0)
            root.chosen = next;
        event.accepted = true;
    }

    confirmHandler: text => {
        const l = root.chosen >= 0 ? root.matches[root.chosen] : (root.matches.length === 1 ? root.matches[0] : null);
        if (!l)
            return qsTr("Choose a keyboard layout.");
        root.picked({layout: l.layout, variant: l.variant});
        return "";
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            Rectangle {
                width: parent.width
                height: Tokens.settingsPickerListHeight
                radius: Tokens.radiusGroup
                color: Appearance.colors.groupFill
                clip: true

                ListView {
                    id: list
                    anchors.fill: parent
                    anchors.margins: Tokens.spacingXs
                    model: root.matches
                    boundsBehavior: Flickable.StopAtBounds
                    Accessible.role: Accessible.List
                    Accessible.name: qsTr("Keyboard layouts")

                    // The choice stays in view (the arrows move it while the field keeps the keyboard).
                    Connections {
                        target: root
                        function onChosenChanged(): void {
                            if (root.chosen >= 0)
                                list.positionViewAtIndex(root.chosen, ListView.Contain);
                        }
                    }

                    delegate: Item {
                        id: entry
                        required property var modelData
                        required property int index
                        readonly property bool isChosen: entry.index === root.chosen
                        width: ListView.view.width
                        height: Tokens.settingsRowHeight
                        Accessible.role: Accessible.ListItem
                        Accessible.name: entry.modelData.name
                        Accessible.selected: entry.isChosen

                        Rectangle {
                            anchors.fill: parent
                            visible: entry.isChosen
                            radius: Tokens.settingsNavTileRadius
                            color: Appearance.colors.selection
                        }

                        Text {
                            textFormat: Text.PlainText
                            x: Tokens.settingsRowInset
                            width: parent.width - 2 * Tokens.settingsRowInset
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: entry.modelData.name
                            color: entry.isChosen ? Appearance.colors.selectionText : Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.chosen = entry.index
                            onDoubleClicked: {
                                root.chosen = entry.index;
                                root.confirm();
                            }
                        }
                    }

                    Text {
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        visible: list.count === 0
                        text: qsTr("No layouts")
                        color: Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                    }
                }
            }
        }
    }
}
