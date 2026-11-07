pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// System Settings > Menu Bar as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Menu Bar): the bar's auto-hide,
// background and recent items, then Menu Bar Controls: a list of the controls with a check box (shown in the menu bar), their
// tile and name, and their options (Clock Options…, Battery Options…: sheets that Main opens), then the status items of
// applications. Every control writes one key of the `menubar` group; the shell reads them live (shell/menubar/MenuBar.qml).
SettingsPage {
    id: root

    required property var store
    // Battery is listed on a computer with a battery only (Main reads it from the power state).
    property bool hasBattery: false
    // The backend, to read the shell's status file (wallpaper-state.json, block `bar`: the outputs whose band is on because of the
    // wallpaper, ADR-0016 D1); null in a test.
    property var backend: null
    property bool bandForced: false

    title: qsTr("Menu Bar")

    signal clockOptionsRequested
    signal batteryOptionsRequested

    // One control of the menu bar: its check box (`key`, a boolean of the menubar group; none for the clock, which is always
    // there), its tile and its name, and its options on the right (declared inside).
    component ControlRow: Item {
        id: control

        property string key: ""
        property string title: ""
        property string glyph: ""
        property string tileColor: "graphite"
        default property alias accessory: slot.data

        width: parent ? parent.width : 0
        height: Tokens.settingsMenuBarControlRowHeight
        Accessible.role: Accessible.Grouping
        Accessible.name: control.title

        Rectangle {
            visible: control.Positioner.index > 0
            x: Tokens.settingsRowInset
            width: parent.width - 2 * Tokens.settingsRowInset
            height: Tokens.appsBorderWidth
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }

        CheckBox {
            visible: control.key !== ""
            x: Tokens.settingsMenuBarCheckX
            anchors.verticalCenter: parent.verticalCenter
            accessibleName: qsTr("Show %1 in the menu bar").arg(control.title)
            checked: control.key !== "" && root.store.value(control.key) === true
            onToggled: root.store.set(control.key, checked)
        }

        Rectangle {
            x: Tokens.settingsMenuBarTileX
            anchors.verticalCenter: parent.verticalCenter
            width: Tokens.settingsMenuBarTileSize
            height: width
            radius: Math.round(width * Tokens.settingsNavTileRadius / Tokens.settingsNavTileSize)
            gradient: TileGradient {
                name: control.tileColor
            }

            Icon {
                anchors.centerIn: parent
                name: control.glyph
                size: Math.round(Tokens.settingsMenuBarTileSize * Tokens.settingsNavGlyphSize / Tokens.settingsNavTileSize)
                color: Tokens.settingsSidebarTileGlyph
            }
        }

        Text {
            x: Tokens.settingsMenuBarTitleX
            anchors.verticalCenter: parent.verticalCenter
            width: slot.x - x - Tokens.spacingLg
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: control.title
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Row {
            id: slot
            anchors.right: parent.right
            anchors.rightMargin: Tokens.settingsRowInset
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    function loadBand(): void {
        const f = root.backend ? root.backend.readText(root.backend.wallpaperStatusFile) : null;
        let forced = false;
        if (f && f.exists && f.ok) {
            try {
                const bar = JSON.parse(f.text).bar;
                forced = !!bar && typeof bar === "object" && Object.keys(bar).some(k => bar[k] === true);
            } catch (e) {
                forced = false;
            }
        }
        root.bandForced = forced;
    }

    Connections {
        target: root.backend
        ignoreUnknownSignals: true

        function onFileChanged(p: string): void {
            if (root.backend && p === root.backend.wallpaperStatusFile)
                root.loadBand();
        }
    }

    Component.onCompleted: {
        if (root.backend) {
            root.backend.watch(root.backend.wallpaperStatusFile);
            root.loadBand();
        }
    }

    SettingsGroup {
        // Shown while the wallpaper forces the band, whatever the switch says (macOS turns the background on by itself the same way).
        footnote: root.bandForced && !root.store.value("menubar.showBackground") ? qsTr("The wallpaper is too busy under the menu bar for its text to be read, so a background is shown.") : ""

        SettingsRow {
            title: qsTr("Automatically hide and show the menu bar")
            ComboBox {
                inline: true
                accessibleName: qsTr("Automatically hide and show the menu bar")
                model: [{id: "always", text: qsTr("Always")}, {id: "desktop", text: qsTr("On Desktop Only")}, {id: "fullscreen", text: qsTr("In Full Screen Only")}, {id: "never", text: qsTr("Never")}]
                value: root.store.value("menubar.autoHide")
                onPicked: id => root.store.set("menubar.autoHide", id)
            }
        }

        SettingsRow {
            title: qsTr("Show menu bar background")
            Toggle {
                accessibleName: qsTr("Show menu bar background")
                checked: root.store.value("menubar.showBackground")
                onToggled: c => root.store.set("menubar.showBackground", c)
            }
        }

        SettingsRow {
            title: qsTr("Recent documents and applications")
            ComboBox {
                inline: true
                accessibleName: qsTr("Recent documents and applications")
                // macOS offers None, 5, 10, 15, 20, 30, 50; a stored value outside them (hand-edited file) is shown as it is.
                model: {
                    const steps = [0, 5, 10, 15, 20, 30, 50];
                    const now = Number(root.store.value("menubar.recentItems"));
                    if (Number.isFinite(now) && steps.indexOf(now) < 0)
                        steps.push(now);
                    steps.sort((a, b) => a - b);
                    return steps.map(n => ({id: String(n), text: n === 0 ? qsTr("None") : String(n)}));
                }
                value: String(root.store.value("menubar.recentItems"))
                onPicked: id => root.store.set("menubar.recentItems", parseInt(id))
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Menu Bar Controls")

        ControlRow {
            title: qsTr("Clock")
            glyph: "clock"
            Button {
                push: true
                text: qsTr("Clock Options…")
                onClicked: root.clockOptionsRequested()
            }
        }

        ControlRow {
            key: "menubar.showSearch"
            title: qsTr("Search")
            glyph: "search"
            tileColor: "blue"
        }

        ControlRow {
            key: "menubar.showWifi"
            title: qsTr("Wi-Fi")
            glyph: "wifi-3"
            tileColor: "blue"
        }

        ControlRow {
            visible: root.hasBattery
            key: "menubar.showBattery"
            title: qsTr("Battery")
            glyph: "battery"
            tileColor: "green"
            Button {
                push: true
                text: qsTr("Battery Options…")
                onClicked: root.batteryOptionsRequested()
            }
        }

        // Focus shows while Do Not Disturb is on (macOS: Show When Active), and a click turns it off.
        ControlRow {
            key: "menubar.showFocus"
            title: qsTr("Focus")
            glyph: "moon"
            tileColor: "purple"
        }

        ControlRow {
            key: "menubar.showSound"
            title: qsTr("Sound")
            glyph: "volume-3"
            tileColor: "pink"
        }

        // Shown while a media player has a track; a click opens its controls.
        ControlRow {
            key: "menubar.showNowPlaying"
            title: qsTr("Now Playing")
            glyph: "now-playing"
            tileColor: "red"
        }

        // macOS 26/27 adds its Screen Capture control to the menu bar from here (owner 2026-11-07): off by default; a click on
        // the item opens the capture toolbar, as Shift-Super-5.
        ControlRow {
            key: "menubar.showScreenCapture"
            title: qsTr("Screen Capture")
            glyph: "capture-selection"
            tileColor: "graphite"
        }
    }

    SettingsGroup {
        caption: qsTr("Allow in the Menu Bar")
        footnote: qsTr("Choosing which application may show an item is not available: this switch covers all of them.")

        SettingsRow {
            title: qsTr("Items from applications")
            Toggle {
                accessibleName: qsTr("Show status items of applications in the menu bar")
                checked: root.store.value("menubar.showTrayItems")
                onToggled: c => root.store.set("menubar.showTrayItems", c)
            }
        }
    }
}
