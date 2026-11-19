pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Software Update's sheets (docs/specs/updates.md U6, U12, U13, U21): Automatic Updates (the one switch Grassfield honours:
// checking; downloading and installing stay the user's), Beta Updates (Off or Grassfield Beta, a sentence on leaving the
// beta, Turn Off Grassfield Updates…), Grassfield's release notes (More Info…) and the other updates. The changes go through
// SoftwareUpdateState (the channel: grassfield-channel-set and its polkit dialog) and the settings store.
Sheet {
    id: root

    // "automatic", "beta", "notes" or "others".
    property string topic: "automatic"
    required property var updates
    required property var store

    readonly property var view: root.updates.view
    // A beta version is installed (or the version cannot be read): "Off" would follow the empty stable channel, so it is unavailable.
    readonly property bool betaLocked: root.setUp && root.updates.channel === "beta" && !root.updates.stableAllowed
    readonly property bool setUp: root.updates.channel === "stable" || root.updates.channel === "beta"
    readonly property var notes: SoftwareUpdateLogic.notesFor(root.view.grassfield, Qt.uiLanguage !== "" ? Qt.uiLanguage : Qt.locale().name)

    title: {
        switch (root.topic) {
        case "beta":
            return qsTr("Beta Updates");
        case "notes":
            return root.view.grassfield ? qsTr("Grassfield %1").arg(SoftwareUpdateLogic.releaseName(root.view.grassfield.available, root.view.grassfield.installed)) : qsTr("Release Notes");
        case "others":
            return qsTr("Other Updates");
        }
        return qsTr("Automatic Updates");
    }
    message: {
        switch (root.topic) {
        case "beta":
            return qsTr("Grassfield Beta gets the next version of Grassfield before its release. You can turn beta updates off once the release is installed; the version you have is kept until a newer stable version comes out, and an older version is never installed.");
        case "notes":
            return root.notes.length === 0 ? qsTr("Release notes are not available.") : "";
        case "others":
            return qsTr("Omarchy's update installs these packages too.");
        }
        return qsTr("Grassfield checks for updates in the background and tells you when one is found. It never downloads or installs anything by itself: Update Now runs Omarchy's update, which asks before it starts.");
    }
    confirmText: qsTr("Done")
    showCancel: false

    function openFor(topic: string): void {
        root.topic = topic;
        root.open();
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            SettingsGroup {
                visible: root.topic === "automatic"

                SettingsRow {
                    title: qsTr("Check for updates")

                    Toggle {
                        accessibleName: qsTr("Check for updates")
                        checked: root.store.value("updates.automaticCheck") === true
                        onToggled: c => root.store.set("updates.automaticCheck", c)
                    }
                }
            }

            SettingsGroup {
                visible: root.topic === "beta"
                footnote: root.betaLocked ? qsTr("Beta updates stay on while a beta version of Grassfield is installed. You can turn them off once the release is installed.")
                    : root.updates.channel !== "off" && root.updates.channel !== "" ? qsTr("Turning them off removes Grassfield's package repository from the system; nothing installed is removed.") : ""

                SettingsRow {
                    title: qsTr("Beta updates")
                    subtitle: root.updates.waitingForPermission ? qsTr("Waiting for permission…") : root.setUp ? "" : qsTr("Set up Grassfield updates first.")

                    ComboBox {
                        inline: true
                        accessibleName: qsTr("Beta updates")
                        enabled: root.setUp && !root.updates.waitingForPermission && !root.betaLocked
                        model: [{id: "stable", text: qsTr("Off")}, {id: "beta", text: qsTr("Grassfield Beta")}]
                        // The value follows /etc/pacman.d/grassfield.conf (watched): it changes when the change is made (U12).
                        value: root.updates.channel === "beta" ? "beta" : "stable"
                        onPicked: id => {
                            if (id !== value)
                                root.updates.setChannel(id, "beta");
                        }
                    }
                }
                SettingsRow {
                    visible: root.updates.channel !== "off" && root.updates.channel !== ""
                    title: qsTr("Grassfield updates")

                    Button {
                        push: true
                        destructive: true
                        enabled: !root.updates.waitingForPermission
                        text: qsTr("Turn Off Grassfield Updates…")
                        onClicked: root.updates.setChannel("off", "off")
                    }
                }
            }

            // The notes of every release newer than the installed one, newest first (U6): plain text.
            Rectangle {
                visible: root.topic === "notes" && root.notes.length > 0
                width: parent.width
                height: Tokens.settingsPickerListHeight
                // A group of Settings (radius.group, step 13's role; ADR-0039 step 26).
                radius: Tokens.radiusGroup
                color: Appearance.colors.groupFill
                clip: true

                Flickable {
                    id: notesView
                    anchors.fill: parent
                    anchors.margins: Tokens.settingsRowInset
                    contentWidth: width
                    contentHeight: notesColumn.height
                    boundsBehavior: Flickable.StopAtBounds
                    Accessible.role: Accessible.Document
                    Accessible.name: root.title

                    Column {
                        id: notesColumn
                        width: notesView.width
                        spacing: Tokens.spacingMd

                        Repeater {
                            model: root.notes

                            Column {
                                id: release
                                required property var modelData
                                width: notesColumn.width
                                spacing: Tokens.spacingXs

                                Text {
                                    textFormat: Text.PlainText
                                    width: parent.width
                                    text: qsTr("Grassfield %1 (%2)").arg(SoftwareUpdateLogic.displayVersion(release.modelData.version)).arg(release.modelData.date)
                                    color: Appearance.colors.text
                                    font.family: Appearance.fontFamily
                                    font.pixelSize: Tokens.typographyBodySize
                                    font.weight: Tokens.typographyMenuBoldWeight
                                    wrapMode: Text.Wrap
                                }
                                Text {
                                    textFormat: Text.PlainText
                                    width: parent.width
                                    text: release.modelData.text
                                    color: Appearance.colors.text
                                    font.family: Appearance.fontFamily
                                    font.pixelSize: Tokens.typographyBodySize
                                    wrapMode: Text.Wrap
                                }
                            }
                        }
                    }

                    ScrollBar.vertical: ScrollBar {}
                }
            }

            // The other updates, by name: installed -> available.
            Rectangle {
                visible: root.topic === "others"
                width: parent.width
                height: Tokens.settingsPickerListHeight
                // A group of Settings (radius.group, step 13's role; ADR-0039 step 26).
                radius: Tokens.radiusGroup
                color: Appearance.colors.groupFill
                clip: true

                ListView {
                    anchors.fill: parent
                    anchors.margins: Tokens.spacingXs
                    model: root.topic === "others" ? root.view.otherPackages : []
                    boundsBehavior: Flickable.StopAtBounds
                    Accessible.role: Accessible.List
                    Accessible.name: qsTr("Other updates")

                    delegate: SettingsRow {
                        required property var modelData
                        width: ListView.view.width
                        title: String(modelData.name)
                        valueText: qsTr("%1 → %2").arg(String(modelData.installed)).arg(String(modelData.available))
                    }

                    ScrollBar.vertical: ScrollBar {}
                }
            }

            Text {
                textFormat: Text.PlainText
                visible: root.topic === "others" && root.view.otherPackagesTruncated
                width: parent.width
                wrapMode: Text.Wrap
                text: qsTr("The list was too long to show in full.")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }
        }
    }
}
