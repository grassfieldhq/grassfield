import QtQuick
import Grassfield.Ui

// Context menu of the desktop (macOS model). `choose` carries the action id (an Open With item: "openWith:<entry id>",
// a Clean Up By item: "cleanUpBy:<key>").
// kind "icon", for the selection: Open, Open With ▸, Move to Trash, Get Info, Rename, Compress, Duplicate, Make Alias,
// Glance (our quick preview, Space), Copy.
// kind "desktop", on the empty desktop: New Folder, Paste Item(s) when the clipboard holds files, Get Info (of the
// desktop folder), Change Wallpaper…, Edit Widgets…, Clean Up, Clean Up By ▸.
PopupMenu {
    id: root

    property string kind: "desktop"
    property int count: 1
    // The single selected name ("" for several), for "Compress "name"" as on macOS.
    property string singleName: ""
    // The wallpaper on this screen is the online daily picture: the menu offers its attribution.
    property bool aboutWallpaper: false
    // The icons are on the screen of this menu. Only there are New Folder and Paste (they show their result, and open a rename
    // field, on that screen), Clean Up and Clean Up By offered; another display, or hidden items, offers none of them.
    property bool itemsHere: true
    // Shortcut hints only when the matching desktop keyboard actions are enabled (IconsView.fileKeyActions).
    property bool showKeyHints: false
    // Files on the clipboard (text/uri-list), 0 when none: the desktop menu then offers Paste.
    property int pasteCount: 0
    // Apps that open the selection, the default first: [{id, name}] (empty: no Open With submenu).
    property var openWithApps: []
    signal choose(string action)

    accessibleName: qsTr("Desktop menu")
    // No row highlighted until the pointer or a key selects one (macOS).
    currentIndex: -1

    function iconItems(): var {
        const several = count > 1;
        const items = [
            {
                id: "open",
                text: qsTr("Open"),
                shortcut: showKeyHints ? "Ctrl+O" : ""
            }
        ];
        if (openWithApps.length > 0) {
            items.push({
                id: "openWithMenu",
                text: qsTr("Open With"),
                submenu: openWithApps.map((app, i) => ({
                            id: "openWith:" + app.id,
                            text: i === 0 ? qsTr("%1 (default)").arg(app.name) : app.name
                        }))
            });
        }
        items.push({
            separator: true
        }, {
            id: "trash",
            text: qsTr("Move to Trash"),
            shortcut: showKeyHints ? "Ctrl+Backspace" : "",
            destructive: true
        }, {
            separator: true
        }, {
            id: "getInfo",
            text: qsTr("Get Info"),
            shortcut: showKeyHints ? "Ctrl+I" : ""
        }, {
            id: "rename",
            text: qsTr("Rename"),
            shortcut: showKeyHints ? "Return" : "",
            enabled: !several
        }, {
            id: "compress",
            text: several ? qsTr("Compress %1 Items").arg(count) : qsTr("Compress “%1”"),
            // A long name is drawn shortened in its middle (menu.nameMaxWidth, MenuItem.name): the menu keeps its width.
            name: several ? "" : singleName
        }, {
            id: "duplicate",
            text: qsTr("Duplicate"),
            shortcut: showKeyHints ? "Ctrl+D" : ""
        }, {
            id: "alias",
            text: qsTr("Make Alias")
        }, {
            id: "quickLook",
            text: several ? qsTr("Glance at %1 Items").arg(count) : qsTr("Glance at “%1”"),
            name: several ? "" : singleName,
            shortcut: showKeyHints ? "Space" : ""
        }, {
            separator: true
        }, {
            id: "copy",
            text: several ? qsTr("Copy %1 Items").arg(count) : qsTr("Copy"),
            shortcut: showKeyHints ? "Ctrl+C" : ""
        });
        return items;
    }

    function desktopItems(): var {
        const items = [];
        if (itemsHere) {
            items.push({
                id: "newFolder",
                text: qsTr("New Folder")
            });
        }
        if (itemsHere && pasteCount > 0) {
            items.push({
                id: "paste",
                text: pasteCount > 1 ? qsTr("Paste %1 Items").arg(pasteCount) : qsTr("Paste Item"),
                shortcut: showKeyHints ? "Ctrl+V" : ""
            });
        }
        if (items.length > 0) {
            items.push({
                separator: true
            });
        }
        items.push({
            id: "getInfo",
            text: qsTr("Get Info"),
            shortcut: showKeyHints ? "Ctrl+I" : ""
        }, {
            id: "wallpaper",
            text: qsTr("Change Wallpaper…")
        });
        if (aboutWallpaper) {
            items.push({
                id: "aboutWallpaper",
                text: qsTr("About This Wallpaper")
            });
        }
        items.push({
            id: "editWidgets",
            text: qsTr("Edit Widgets…")
        });
        if (!itemsHere)
            return items;
        items.push({
            separator: true
        }, {
            id: "cleanUp",
            text: qsTr("Clean Up")
        }, {
            id: "cleanUpByMenu",
            text: qsTr("Clean Up By"),
            submenu: [
                {
                    id: "cleanUpBy:name",
                    text: qsTr("Name")
                },
                {
                    id: "cleanUpBy:kind",
                    text: qsTr("Kind")
                },
                {
                    id: "cleanUpBy:modified",
                    text: qsTr("Date Modified")
                },
                {
                    id: "cleanUpBy:created",
                    text: qsTr("Date Created")
                },
                {
                    id: "cleanUpBy:size",
                    text: qsTr("Size")
                }
            ]
        });
        return items;
    }

    model: kind === "icon" ? iconItems() : desktopItems()

    onActivated: item => root.choose(String(item.id))
}
