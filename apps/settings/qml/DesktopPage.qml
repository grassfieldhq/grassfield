pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Dialogs
import Grassfield.Ui

// Settings > Desktop & Dock as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Desktop & Dock): Dock (Size
// and Magnification side by side; the Dock's position, the minimize animation, the title bar's double click and minimizing
// into the app's icon; then how the Dock behaves), the folders kept in the Dock (Grassfield's own), Desktop & Stages,
// Windows, and the Screen Corners… sheet (macOS: Hot Corners…; screenCornersRequested, Main opens it).
SettingsPage {
    id: root

    required property var store

    signal screenCornersRequested

    title: qsTr("Desktop & Dock")

    // Magnification as one slider (macOS 27): Off at its start, then Small (dockMagnificationSmallAt of the knob's travel) to
    // Large, the largest magnification the schema allows. A position between Off and Small goes to the nearer of the two.
    readonly property real magnificationLarge: SettingsContract.RULES["dock.magnification"].max
    readonly property real magnificationPosition: {
        if (!root.store.value("dock.magnificationEnabled"))
            return 0;
        const m = Math.max(Tokens.settingsDockMagnificationSmall, root.store.value("dock.magnification"));
        return Tokens.settingsDockMagnificationSmallAt + (1 - Tokens.settingsDockMagnificationSmallAt) * (m - Tokens.settingsDockMagnificationSmall) / (root.magnificationLarge - Tokens.settingsDockMagnificationSmall);
    }

    function setMagnification(position: real): void {
        const small = Tokens.settingsDockMagnificationSmallAt;
        if (position < small / 2) {
            root.store.set("dock.magnificationEnabled", false);
            return;
        }
        const t = Math.max(0, (position - small) / (1 - small));
        const m = Math.round((Tokens.settingsDockMagnificationSmall + t * (root.magnificationLarge - Tokens.settingsDockMagnificationSmall)) * 100) / 100;
        root.store.setMany({"dock.magnificationEnabled": true, "dock.magnification": m});
    }

    SettingsGroup {
        caption: qsTr("Dock")

        Item {
            width: parent.width
            height: Tokens.settingsDockSlidersHeight

            DockSlider {
                x: Tokens.settingsRowInset
                width: Tokens.settingsDockSizeSliderWidth
                title: qsTr("Size")
                labels: [{text: qsTr("Small"), at: 0}, {text: qsTr("Large"), at: 1}]
                slider.from: Tokens.dockSizeMin
                slider.to: Tokens.dockSizeMax
                slider.stepSize: 1 / (Tokens.dockSizeMax - Tokens.dockSizeMin)
                slider.ticks: 2
                slider.value: root.store.value("dock.size")
                slider.onMoved: v => root.store.set("dock.size", Math.round(v))
            }

            DockSlider {
                x: Tokens.settingsDockMagnificationX
                width: parent.width - x - Tokens.settingsRowInset
                title: qsTr("Magnification")
                labels: [{text: qsTr("Off"), at: 0}, {text: qsTr("Small"), at: Tokens.settingsDockMagnificationSmallAt}, {text: qsTr("Large"), at: 1}]
                slider.from: 0
                slider.to: 1
                slider.stepSize: 0.05
                slider.tickValues: [Tokens.settingsDockMagnificationSmallAt, 1]
                slider.value: root.magnificationPosition
                slider.onMoved: v => root.setMagnification(v)
            }
        }
    }

    SettingsGroup {
        SettingsRow {
            title: qsTr("Dock position on screen")
            ComboBox {
                inline: true
                accessibleName: qsTr("Dock position on screen")
                model: [{id: "left", text: qsTr("Left")}, {id: "bottom", text: qsTr("Bottom")}, {id: "right", text: qsTr("Right")}]
                value: root.store.value("dock.position")
                onPicked: id => root.store.set("dock.position", id)
            }
        }

        SettingsRow {
            title: qsTr("Minimized window animation")
            ComboBox {
                inline: true
                accessibleName: qsTr("Minimized window animation")
                model: [{id: "funnel", text: qsTr("Funnel")}, {id: "shrink", text: qsTr("Shrink")}]
                value: root.store.value("dock.minimizeEffect")
                onPicked: id => root.store.set("dock.minimizeEffect", id)
            }
        }

        SettingsRow {
            title: qsTr("Window title bar double-click action")
            ComboBox {
                inline: true
                accessibleName: qsTr("Window title bar double-click action")
                // Fill (TL32; the default, ADR-0036 D78): the window takes the whole usable area of its display, tiled with
                // the margins, and a second double-click brings back its size. Zoom does the same since D78 (TL35).
                model: [{id: "fill", text: qsTr("Fill")}, {id: "zoom", text: qsTr("Zoom")}, {id: "minimize", text: qsTr("Minimize")}, {id: "none", text: qsTr("No Action")}]
                value: root.store.value("windows.titlebarDoubleClick")
                onPicked: id => root.store.set("windows.titlebarDoubleClick", id)
            }
        }

        SettingsRow {
            title: qsTr("Minimize windows into application icon")
            Toggle {
                accessibleName: qsTr("Minimize windows into application icon")
                checked: root.store.value("dock.minimizeIntoApp")
                onToggled: c => root.store.set("dock.minimizeIntoApp", c)
            }
        }
    }

    SettingsGroup {
        SettingsRow {
            title: qsTr("Automatically hide and show the Dock")
            Toggle {
                accessibleName: qsTr("Automatically hide and show the Dock")
                checked: root.store.value("dock.autohide")
                onToggled: c => root.store.set("dock.autohide", c)
            }
        }

        SettingsRow {
            title: qsTr("Click an open app’s icon to minimize its windows")
            Toggle {
                accessibleName: qsTr("Click an open app’s icon to minimize its windows")
                checked: root.store.value("dock.clickMinimizes")
                onToggled: c => root.store.set("dock.clickMinimizes", c)
            }
        }

        SettingsRow {
            title: qsTr("Animate opening applications")
            Toggle {
                accessibleName: qsTr("Animate opening applications")
                checked: root.store.value("dock.animateOpening")
                onToggled: c => root.store.set("dock.animateOpening", c)
            }
        }

        SettingsRow {
            title: qsTr("Show indicators for open applications")
            Toggle {
                accessibleName: qsTr("Show indicators for open applications")
                checked: root.store.value("dock.showIndicators")
                onToggled: c => root.store.set("dock.showIndicators", c)
            }
        }

        // Whether apps stay in the Dock after they quit (the owner's question, 2026-11-07): the macOS switch, which says so under
        // its title. Off, an app that is not kept in the Dock leaves it when it quits; the Dock follows the switch at once.
        SettingsRow {
            title: qsTr("Show recent apps in Dock")
            subtitle: qsTr("Apps you quit that are not kept in the Dock stay in their own section until newer ones replace them.")
            Toggle {
                accessibleName: qsTr("Show recent apps in Dock")
                checked: root.store.value("dock.showRecents")
                onToggled: c => root.store.set("dock.showRecents", c)
            }
        }

        // Windows' End Task (owner AQ5, ADR-0038 AM63): the Dock menu of a running app gains End Task, its Option + Force Quit.
        SettingsRow {
            title: qsTr("Show End Task in Dock menus")
            Toggle {
                accessibleName: qsTr("Show End Task in Dock menus")
                checked: root.store.value("dock.endTask")
                onToggled: c => root.store.set("dock.endTask", c)
            }
        }
    }

    // Folders kept in the Dock as stacks (dock.folders). Dragging a folder onto the Dock's right section adds one too.
    readonly property var dockFolders: store.value("dock.folders")

    function urlToPath(u: url): string {
        const s = u.toString();
        return s.indexOf("file://") === 0 ? decodeURIComponent(s.substring(7)) : "";
    }

    function addDockFolder(path: string): void {
        if (path === "" || dockFolders.indexOf(path) >= 0 || dockFolders.length >= 12)
            return;
        store.set("dock.folders", dockFolders.concat([path]));
    }

    function openAddFolder(): void {
        addFolderDialog.open();
    }

    function removeDockFolder(path: string): void {
        store.set("dock.folders", dockFolders.filter(f => f !== path));
    }

    FolderDialog {
        id: addFolderDialog
        title: qsTr("Choose a folder for the Dock")
        onAccepted: root.addDockFolder(root.urlToPath(selectedFolder))
    }

    SettingsGroup {
        caption: qsTr("Folders in the Dock")
        footnote: qsTr("A folder in the Dock opens as a stack. You can also drag a folder to the right of the divider in the Dock.")

        Repeater {
            model: root.dockFolders

            delegate: SettingsRow {
                id: folderRow
                required property string modelData
                title: modelData
                Button {
                    push: true
                    text: qsTr("Remove")
                    Accessible.name: qsTr("Remove %1 from the Dock").arg(folderRow.modelData)
                    onClicked: root.removeDockFolder(folderRow.modelData)
                }
            }
        }

        SettingsRow {
            title: qsTr("Add a folder")
            Button {
                push: true
                text: qsTr("Add Folder…")
                onClicked: root.openAddFolder()
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Desktop & Stages")

        SettingsRow {
            title: qsTr("Show items")
            CheckBox {
                text: qsTr("On Desktop")
                accessibleName: qsTr("Show items on the desktop")
                checked: root.store.value("desktop.showIcons")
                onToggled: root.store.set("desktop.showIcons", checked)
            }
        }
    }

    SettingsGroup {
        footnote: qsTr("Needs the Grassfield compositor extension. The Stages switch is also in Quick Settings.")

        SettingsRow {
            title: qsTr("Stages")
            subtitle: qsTr("Keep the windows of one app in the centre and the other recent apps as thumbnails on the left edge.")
            Toggle {
                accessibleName: qsTr("Stages")
                checked: root.store.value("windows.stages")
                onToggled: c => root.store.set("windows.stages", c)
            }
        }
    }

    // TL32: the tiling switches in this order; each reaches the plugin once it offers the feature (Compositor.pushPluginConfig).
    SettingsGroup {
        caption: qsTr("Windows")
        footnote: qsTr("Needs the Grassfield compositor extension.")

        SettingsRow {
            title: qsTr("Drag windows to left or right edge of screen to tile")
            Toggle {
                accessibleName: qsTr("Drag windows to left or right edge of screen to tile")
                checked: root.store.value("windows.tilingEdges")
                onToggled: c => root.store.set("windows.tilingEdges", c)
            }
        }

        SettingsRow {
            title: qsTr("Drag windows to menu bar to fill screen")
            Toggle {
                accessibleName: qsTr("Drag windows to menu bar to fill screen")
                checked: root.store.value("windows.tilingMenuBar")
                onToggled: c => root.store.set("windows.tilingMenuBar", c)
            }
        }

        // The key as the menus name it (keyboard.shortcutStyle, owner decision 2026-10-26): its symbol in the macOS style,
        // the PC key's name otherwise (parity matrix M38).
        SettingsRow {
            id: optionDragRow
            title: Appearance.shortcutStyle === "mac" ? qsTr("Hold ⌥ key while dragging windows to tile") : qsTr("Hold Alt key while dragging windows to tile")
            Toggle {
                accessibleName: optionDragRow.title
                checked: root.store.value("windows.tilingOptionDrag")
                onToggled: c => root.store.set("windows.tilingOptionDrag", c)
            }
        }

        SettingsRow {
            title: qsTr("Tiled windows have margins")
            Toggle {
                accessibleName: qsTr("Tiled windows have margins")
                checked: root.store.value("windows.tilingMargins")
                onToggled: c => root.store.set("windows.tilingMargins", c)
            }
        }

        SettingsRow {
            title: qsTr("Show layouts when hovering over the green button")
            Toggle {
                accessibleName: qsTr("Show layouts when hovering over the green button")
                checked: root.store.value("windows.tilingLayouts")
                onToggled: c => root.store.set("windows.tilingLayouts", c)
            }
        }

        SettingsRow {
            title: qsTr("Suggest windows to fill the rest of a layout")
            Toggle {
                accessibleName: qsTr("Suggest windows to fill the rest of a layout")
                checked: root.store.value("windows.tilingSuggestions")
                onToggled: c => root.store.set("windows.tilingSuggestions", c)
            }
        }

        SettingsRow {
            title: qsTr("Bring tile groups forward together")
            Toggle {
                accessibleName: qsTr("Bring tile groups forward together")
                checked: root.store.value("windows.tilingGroups")
                onToggled: c => root.store.set("windows.tilingGroups", c)
            }
        }

        // ADR-0009 amendment 2026-10-23 (audit GF-033): opt-in; off, a Hyprland update leaves the extension off until the
        // user runs grassfield-compositor-rebuild (the session's notice says so).
        SettingsRow {
            title: qsTr("Rebuild the compositor extension after Hyprland updates")
            subtitle: qsTr("Window titlebars, minimize and global menus need it. After an update of Hyprland, Grassfield builds it again in the background.")
            Toggle {
                accessibleName: qsTr("Rebuild the compositor extension after Hyprland updates")
                checked: root.store.value("windows.rebuildExtension")
                onToggled: c => root.store.set("windows.rebuildExtension", c)
            }
        }
    }

    // macOS 27: the push buttons under the last group, right-aligned (Screen Corners…, macOS's Hot Corners…, opens its sheet).
    Item {
        width: parent.width
        height: screenCornersButton.height

        Button {
            id: screenCornersButton
            anchors.right: parent.right
            push: true
            text: qsTr("Screen Corners…")
            onClicked: root.screenCornersRequested()
        }
    }
}
