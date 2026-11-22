pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Login Items > +: choose an application to open at login (macOS: an Open panel on /Applications). The applications are the
// desktop entries of the XDG applications folders (General.applications); the field filters them by name. Add (or Return,
// or a double-click) hands the choice back (`chosen`); Cancel and Escape change nothing.
Sheet {
    id: root

    property var apps: []
    property string chosenFile: ""
    readonly property var matches: root.apps.filter(a => root.fieldText.trim() === "" || a.name.toLowerCase().indexOf(root.fieldText.trim().toLowerCase()) >= 0)

    // Another use of the sheet (Desktop & Dock > Default Apps > Other…): its words and where the choice goes, for this opening only;
    // null for Login Items (chosen(app)).
    property var texts: null
    property var answer: null

    signal chosen(var app)

    title: root.texts ? root.texts.title : qsTr("Add a Login Item")
    message: root.texts ? root.texts.message : qsTr("Choose an application to open when you log in.")
    confirmText: root.texts ? root.texts.confirm : qsTr("Add")
    withField: true
    placeholder: qsTr("Search")

    // texts ({title, message, confirm}) and answer (a function of the app chosen): Default Apps' Other…; neither for Login Items.
    function openWith(apps: var, texts: var, answer: var): void {
        root.texts = texts ?? null;
        root.answer = typeof answer === "function" ? answer : null;
        root.apps = apps;
        root.chosenFile = "";
        root.setField("");
        root.open();
    }

    // The arrows move the choice while the field keeps the keyboard (the field does not take Up and Down).
    Keys.onPressed: event => {
        if (event.key !== Qt.Key_Up && event.key !== Qt.Key_Down)
            return;
        const i = root.matches.findIndex(a => a.file === root.chosenFile);
        const next = Math.max(0, Math.min(root.matches.length - 1, i < 0 ? 0 : i + (event.key === Qt.Key_Down ? 1 : -1)));
        if (root.matches.length > 0)
            root.chosenFile = root.matches[next].file;
        event.accepted = true;
    }

    confirmHandler: text => {
        const app = root.matches.find(a => a.file === root.chosenFile) ?? (root.matches.length === 1 ? root.matches[0] : null);
        if (!app)
            return qsTr("Choose an application.");
        if (root.answer)
            root.answer(app);
        else
            root.chosen(app);
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
                    Accessible.name: qsTr("Applications")

                    // The choice stays in view (the arrows move it while the field keeps the keyboard).
                    Connections {
                        target: root
                        function onChosenFileChanged(): void {
                            const i = root.matches.findIndex(a => a.file === root.chosenFile);
                            if (i >= 0)
                                list.positionViewAtIndex(i, ListView.Contain);
                        }
                    }

                    delegate: Item {
                        id: entry
                        required property var modelData
                        width: ListView.view.width
                        height: Tokens.settingsRowHeight
                        readonly property bool selected: entry.modelData.file === root.chosenFile
                        Accessible.role: Accessible.ListItem
                        Accessible.name: entry.modelData.name
                        Accessible.selected: entry.selected

                        Rectangle {
                            anchors.fill: parent
                            visible: entry.selected
                            radius: Tokens.settingsNavTileRadius
                            color: Appearance.colors.selection
                        }
                        AppIcon {
                            x: Tokens.settingsNavTileInset - Tokens.spacingXs
                            anchors.verticalCenter: parent.verticalCenter
                            icon: entry.modelData.icon
                        }
                        Text {
                            textFormat: Text.PlainText
                            x: Tokens.settingsNavLabelInset - Tokens.spacingXs
                            width: parent.width - x - Tokens.settingsRowInset
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: entry.modelData.name
                            color: entry.selected ? Appearance.colors.selectionText : Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.chosenFile = entry.modelData.file
                            onDoubleClicked: {
                                root.chosenFile = entry.modelData.file;
                                root.confirm();
                            }
                        }
                    }

                    Text {
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        visible: list.count === 0
                        text: qsTr("No applications")
                        color: Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                    }
                }
            }
        }
    }
}
