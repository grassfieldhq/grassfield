pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Printers > Add Printer…: the printers on the network that print without a driver (IPP Everywhere, AirPrint), as cupsd and
// DNS-SD find them (PrintersPage.found, read again while the sheet is open). Add (or a double-click) hands the choice back
// (`picked`); the page then asks cups-pk-helper, which asks for the administrator's password (ADR-0030).
Sheet {
    id: root

    property var found: []
    property bool answered: false
    property int chosen: -1

    signal picked(var printer)

    title: qsTr("Add Printer")
    message: qsTr("Printers on your network that print without a driver are listed. Adding one asks for an administrator's password.")
    confirmText: qsTr("Add")

    function openWith(): void {
        root.chosen = -1;
        root.open();
    }

    // The list changes as printers come and go: the choice follows its printer, or is dropped.
    property string chosenName: ""
    onFoundChanged: root.chosen = root.found.findIndex(p => p.name === root.chosenName)
    onChosenChanged: root.chosenName = root.chosen >= 0 && root.chosen < root.found.length ? root.found[root.chosen].name : ""

    Keys.onPressed: event => {
        if (event.key !== Qt.Key_Up && event.key !== Qt.Key_Down)
            return;
        if (root.found.length > 0)
            root.chosen = Math.max(0, Math.min(root.found.length - 1, root.chosen < 0 ? 0 : root.chosen + (event.key === Qt.Key_Down ? 1 : -1)));
        event.accepted = true;
    }

    confirmHandler: text => {
        const p = root.chosen >= 0 ? root.found[root.chosen] : (root.found.length === 1 ? root.found[0] : null);
        if (!p)
            return qsTr("Choose a printer.");
        root.picked(p);
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
                    model: root.found
                    boundsBehavior: Flickable.StopAtBounds
                    Accessible.role: Accessible.List
                    Accessible.name: qsTr("Printers found")

                    delegate: Item {
                        id: entry
                        required property var modelData
                        required property int index
                        readonly property bool isChosen: entry.index === root.chosen
                        width: ListView.view.width
                        height: Tokens.settingsRowHeight
                        Accessible.role: Accessible.ListItem
                        Accessible.name: label.text
                        Accessible.selected: entry.isChosen

                        Rectangle {
                            anchors.fill: parent
                            visible: entry.isChosen
                            radius: Tokens.settingsNavTileRadius
                            color: Appearance.colors.selection
                        }

                        Text {
                            id: label
                            textFormat: Text.PlainText
                            x: Tokens.settingsRowInset
                            width: parent.width - 2 * Tokens.settingsRowInset
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: entry.modelData.name.replace(/_+/g, " ")
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

                    Row {
                        anchors.centerIn: parent
                        visible: list.count === 0
                        spacing: Tokens.spacingSm

                        Spinner {
                            visible: !root.answered
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            textFormat: Text.PlainText
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.answered ? qsTr("No printers were found on your network.") : qsTr("Looking for printers…")
                            color: Appearance.windowSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                        }
                    }
                }
            }
        }
    }
}
