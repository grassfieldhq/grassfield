pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Dialogs
import Grassfield.Ui

// Settings > Wallpaper > Screen Saver… (macOS 27 opens the screen saver as a sheet from Wallpaper; ADR-0032): the owner's four
// savers as pictures (screensaver.kind), when it starts (screensaver.idleMinutes; Never by default), the slideshow's folder
// (screensaver.folder, the Pictures folder when empty), and macOS's note when the session locks or the display turns off
// before the saver would start, with Lock Screen Settings… (lockScreenRequested). Every control writes at once; Done closes.
Sheet {
    id: root

    required property var store
    // The display-off delay on battery counts only on a computer with a battery (Main reads it from the power state).
    property bool hasBattery: false

    signal lockScreenRequested

    title: qsTr("Screen Saver")
    confirmText: qsTr("Done")
    showCancel: false

    readonly property int minutes: root.store.value("screensaver.idleMinutes")
    readonly property string folder: root.store.value("screensaver.folder")

    // "For 2 minutes", "For 1 hour" (macOS's names for the screen saver's delay); 0 is Never.
    function forText(m: int): string {
        if (m === 0)
            return qsTr("Never");
        if (m % 60 === 0)
            return m === 60 ? qsTr("For 1 hour") : qsTr("For %1 hours").arg(m / 60);
        return m === 1 ? qsTr("For 1 minute") : qsTr("For %1 minutes").arg(m);
    }

    // The pop-up's choices; a hand-edited delay outside them is shown as it is.
    readonly property var minuteChoices: {
        const all = [0, 1, 2, 5, 10, 20, 30, 60];
        if (all.indexOf(root.minutes) < 0)
            all.push(root.minutes);
        all.sort((a, b) => a === 0 ? -1 : b === 0 ? 1 : a - b);
        return all.map(m => ({id: String(m), text: root.forText(m)}));
    }

    // macOS's note: the screen saver would never be seen because the session locks, or the display turns off, first.
    readonly property string timingNote: {
        if (root.minutes <= 0)
            return "";
        const lock = root.store.value("lock.idleMinutes");
        if (lock > 0 && lock <= root.minutes)
            return qsTr("The session locks before the screen saver starts. You can change the timing in Lock Screen settings.");
        const off = [root.store.value("lock.displayOffPower")].concat(root.hasBattery ? [root.store.value("lock.displayOffBattery")] : []);
        if (off.some(m => m > 0 && m <= root.minutes))
            return qsTr("The display turns off before the screen saver starts. You can change the timing in Lock Screen settings.");
        return "";
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            ChoicePicker {
                anchors.horizontalCenter: parent.horizontalCenter
                accessibleName: qsTr("Screen saver")
                model: [{id: "artwork", text: qsTr("Grassfield")}, {id: "wallpaperClock", text: qsTr("Wallpaper")}, {id: "slideshow", text: qsTr("Slideshow")}, {id: "clock", text: qsTr("Clock")}, {id: "moving", text: qsTr("Clouds")}]
                value: root.store.value("screensaver.kind")
                pictureWidth: Tokens.settingsAppearanceThumbWidth
                pictureHeight: Tokens.settingsAppearanceThumbHeight
                pictureRadius: Tokens.settingsAppearanceThumbRadius
                pitch: Tokens.settingsAppearanceThumbPitch
                ringGap: Tokens.settingsAppearanceThumbRingGap
                captionBaseline: Tokens.settingsAppearanceCaptionBaseline
                picture: Component {
                    SaverThumbnail {}
                }
                onPicked: id => root.store.set("screensaver.kind", id)
            }

            SettingsGroup {
                SettingsRow {
                    title: qsTr("Start screen saver when inactive")
                    ComboBox {
                        inline: true
                        accessibleName: qsTr("Start screen saver when inactive")
                        model: root.minuteChoices
                        value: String(root.minutes)
                        onPicked: id => root.store.set("screensaver.idleMinutes", Number(id))
                    }
                }

                // The slideshow's pictures: the folder's name, and Choose… for another one.
                SettingsRow {
                    visible: root.store.value("screensaver.kind") === "slideshow"
                    title: qsTr("Pictures")
                    Row {
                        spacing: Tokens.settingsAccessoryGap

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: root.folder === "" ? qsTr("Pictures folder") : root.folder.substring(root.folder.lastIndexOf("/") + 1)
                            color: Appearance.windowSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                        }

                        Button {
                            anchors.verticalCenter: parent.verticalCenter
                            push: true
                            text: qsTr("Choose…")
                            Accessible.name: qsTr("Choose the slideshow's folder")
                            onClicked: folderDialog.open()
                        }
                    }
                }
            }

            Text {
                visible: root.timingNote !== ""
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: root.timingNote
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }

            Button {
                visible: root.timingNote !== ""
                anchors.right: parent.right
                push: true
                text: qsTr("Lock Screen Settings…")
                onClicked: root.lockScreenRequested()
            }

            // A Qt Quick dialog: with the session's GTK platform theme it is the native chooser (as Wallpaper's). Esc changes nothing.
            FolderDialog {
                id: folderDialog
                title: qsTr("Choose a folder of pictures")
                onAccepted: {
                    const s = selectedFolder.toString();
                    const path = s.indexOf("file://") === 0 ? decodeURIComponent(s.substring(7)) : "";
                    if (path !== "")
                        root.store.set("screensaver.folder", path);
                }
            }
        }
    }
}
