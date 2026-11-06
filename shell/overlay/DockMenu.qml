import QtQuick
import QtQuick.Shapes
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.platform
import qs.services
import "../dock/DockModel.js" as DockModel
import "../dock/Launch.js" as Launch
import "../dock/Stacks.js" as Stacks
import "../platform/WindowTiling.js" as WindowTiling
import "../services/AppLaunch.js" as AppLaunch

// Dock item context menu. Payload (Popups.data): key, entry (DesktopEntry or null),
// pinned, fixed (the Files tile), running, windows (toplevel handles). Keep in Dock / Remove from Dock persist to grassfield.json.
PopupMenu {
    id: root

    readonly property var info: Popups.data
    readonly property var entry: info.entry ? info.entry : null
    readonly property var desktopActions: entry && entry.actions ? entry.actions : []
    // Open at Login: whether the autostart file of this app exists (checked once when the menu opens).
    property bool autostart: false
    readonly property string autostartPath: entry ? AppLaunch.autostartFile(AppLaunch.autostartDir(Apps.devSession, Apps.appsHome, Quickshell.env("XDG_CONFIG_HOME"), Quickshell.env("HOME")), entry.id) : ""

    accessibleName: qsTr("Dock item menu")
    currentIndex: -1

    // The app's windows (only the windows of this tile: the same identity rules as the running dot), most recent first.
    readonly property var windowRows: Launch.menuWindows((info.windows ? info.windows : []).map(t => {
        const w = Compositor.windowInfo(t);
        return {ref: t, title: t.title, minimized: w.minimized, stamp: w.stamp};
    }), Tokens.menuWindowTitleMax, Apps.nameFor(appId()), appId())

    // The app's tile groups (TL29): one Show Tile Group row per group that holds one of its windows, after Show All Windows.
    readonly property var tileGroupRows: Compositor.canGroups ? WindowTiling.tileGroupRows(windowRows.map(w => Compositor.addressOf(w.ref)), TilingLink.groups) : []

    // A Show Tile Group row's text: the other members' apps name the group when the app has several.
    function tileGroupText(row: var): string {
        if (tileGroupRows.length < 2)
            return qsTr("Show Tile Group");
        const names = row.members.filter(a => a !== row.own).map(a => {
            const t = Compositor.toplevelByAddress(a);
            return t ? Apps.nameFor(t.appId) : "";
        }).filter((n, i, all) => n !== "" && all.indexOf(n) === i);
        return names.length > 0 ? qsTr("Show Tile Group with %1").arg(names.join(", ")) : qsTr("Show Tile Group");
    }

    // The app's processes that do not respond (NotResponding, ADR-0035 D-3): the menu starts with "Application Not
    // Responding" and offers Force Quit in place of Quit, for those processes only (macOS).
    readonly property var notResponding: NotResponding.markedAmong((info.windows ? info.windows : []).map(t => Compositor.pidOf(t)))
    // The classes Hyprland reports for the app's windows: the confirmation checks that each pid still owns a window of one.
    readonly property var appClasses: (info.windows ? info.windows : []).map(t => {
        const top = Compositor.hyprlandToplevel(t);
        return top && top.lastIpcObject && top.lastIpcObject.class ? top.lastIpcObject.class : "";
    }).filter((c, i, all) => c !== "" && all.indexOf(c) === i)

    readonly property bool isTrash: info.kind === "trash"
    readonly property bool isFolder: info.kind === "folder"
    // The documents this app used (macOS lists them in the app's Dock menu), newest first.
    readonly property var recentDocs: entry && !isTrash && !isFolder && DockModel.opensDocuments(entry) ? RecentItems.documentsFor(entry, Tokens.dockRecentDocsMax) : []

    // Radio rows of the stack menu's submenus: the chosen value is checked.
    function choice(key: string, current: string, rows: var): var {
        return rows.map(r => ({id: "stackOption", key: key, value: r.value, text: r.text, checked: current === r.value}));
    }

    function folderModel(): var {
        return [
            {
                id: "stackSort",
                text: qsTr("Sort by"),
                submenu: choice("sort", info.sort, [
                    {value: "name", text: qsTr("Name")},
                    {value: "dateAdded", text: qsTr("Date Added")},
                    {value: "dateModified", text: qsTr("Date Modified")},
                    {value: "dateCreated", text: qsTr("Date Created")},
                    {value: "kind", text: qsTr("Kind")}
                ])
            },
            {
                id: "stackDisplay",
                text: qsTr("Display as"),
                submenu: choice("display", info.display, [
                    {value: "stack", text: qsTr("Stack")},
                    {value: "folder", text: qsTr("Folder")}
                ])
            },
            {
                id: "stackView",
                text: qsTr("View content as"),
                submenu: choice("view", info.view, [
                    {value: "automatic", text: qsTr("Automatic")},
                    {value: "fan", text: qsTr("Fan")},
                    {value: "grid", text: qsTr("Grid")},
                    {value: "list", text: qsTr("List")}
                ])
            },
            {separator: true},
            {id: "folderRemove", text: qsTr("Remove from Dock")},
            {separator: true},
            {id: "folderOpen", text: qsTr("Open in Files")}
        ];
    }

    model: {
        if (isFolder)
            return folderModel();
        // macOS Trash menu: Open, Empty Trash… (disabled while the Trash is empty).
        if (isTrash)
            return [{id: "trashOpen", text: qsTr("Open")}, {id: "trashEmpty", text: qsTr("Empty Trash…"), enabled: !Trash.empty}];
        const items = [];
        // macOS: an app that does not respond says so first, greyed out.
        if (notResponding.length > 0)
            items.push({id: "notResponding", text: qsTr("Application Not Responding"), enabled: false}, {separator: true});
        // macOS: the app's windows come first (a check on the front window, a mark on minimized ones), then a separator.
        if (windowRows.length > 0) {
            for (const w of windowRows)
                items.push({id: "window", ref: w.ref, text: w.minimized ? qsTr("%1 (minimized)").arg(w.title) : w.title, checked: w.checked});
            items.push({separator: true});
        }
        // macOS: the documents the app used come next, under their own header.
        if (recentDocs.length > 0) {
            // A section title (MenuHeader), not a greyed row (ADR-0039 step 25, the menu grammar of step 8).
            items.push({id: "recentHeader", text: qsTr("Recent Documents"), header: true});
            for (const d of recentDocs)
                items.push({id: "recentDocument", path: d.path, text: DisplayName.text(Stacks.baseName(d.path)), enabled: entry !== null});
            items.push({separator: true});
        }
        items.push(info.running ? {id: "new", text: qsTr("New Window"), enabled: entry !== null} : {id: "open", text: qsTr("Open"), enabled: entry !== null});
        if (desktopActions.length > 0) {
            items.push({separator: true});
            for (let i = 0; i < desktopActions.length; i++)
                items.push({id: "action", index: i, text: desktopActions[i].name});
        }
        items.push({separator: true});
        items.push({
            id: "options",
            text: qsTr("Options"),
            submenu: root.optionItems()
        });
        // The window rows exist only while the app runs (macOS omits them; it never shows them greyed out).
        if (info.running !== true)
            return items;
        items.push({separator: true});
        items.push({id: "showall", text: qsTr("Show All Windows")});
        for (const g of tileGroupRows) {
            const ref = Compositor.toplevelByAddress(g.own);
            if (ref)
                items.push({id: "tileGroup", ref: ref, members: g.members, text: root.tileGroupText(g)});
        }
        // Option (Alt) variants, live while the menu is open (macOS): Hide becomes Hide Others, Quit becomes Force Quit.
        // An app that does not respond offers Force Quit without Option; End Task follows when Settings shows it (AM63).
        for (const id of Launch.quitRows({alt: altHeld, hung: notResponding.length > 0, endTask: Settings.dockEndTask, fixed: info.fixed === true})) {
            if (id === "hideOthers")
                items.push({id: id, text: qsTr("Hide Others"), enabled: Compositor.othersCount(appId(), Compositor.topologyRevision) > 0});
            else if (id === "hide")
                items.push({id: id, text: qsTr("Hide")});
            else if (id === "quit")
                items.push({id: id, text: qsTr("Quit")});
            else if (id === "endtask")
                items.push({id: id, text: qsTr("End Task")});
            else
                items.push({id: id, text: qsTr("Force Quit")});
        }
        return items;
    }

    // Options submenu (macOS): a running app has "Keep in Dock" (checked when kept; unchecking removes it once the app quits);
    // a kept app that is not running has "Remove from Dock" and no "Keep in Dock"; a recent app that is not kept has both
    // (Launch.optionRows); Remove from Dock on a recent forgets it until it is launched and quits again.
    function optionItems(): var {
        const items = [];
        // The fixed Files tile (like the Finder's) is always in the Dock: no Keep or Remove, and no "Show in Files" on Files itself.
        if (info.fixed !== true) {
            const rows = Launch.optionRows({fixed: info.fixed, running: info.running, pinned: info.pinned, recent: info.recent});
            if (rows.keep)
                items.push({id: "keep", text: qsTr("Keep in Dock"), checked: info.pinned === true, enabled: info.pinned === true || entry !== null});
            if (rows.remove)
                items.push({id: "remove", text: qsTr("Remove from Dock")});
        }
        items.push({id: "login", text: qsTr("Open at Login"), checked: autostart, enabled: entry !== null});
        if (info.fixed !== true)
            items.push({id: "reveal", text: qsTr("Show in Files"), enabled: entry !== null});
        return items;
    }

    function lookupFn(id: string): var {
        return Apps.lookup(id);
    }

    function appId(): string {
        const w = info.windows && info.windows.length > 0 ? info.windows[0] : null;
        return w ? w.appId : "";
    }

    onCloseRequested: Popups.close()

    // Tail pointing at the icon (reference: rounded panel with a tail on the shelf side). The Overlay centres the menu on
    // the icon and keeps it Tokens.panelPopupMargin inside the window: the tail follows the icon when that clamps it.
    // Each tail overlaps the menu by one device pixel only, the body's rim it has to cover: it overlapped by a logical
    // pixel (1.25 device pixels at 1.25), a band where the tail's glass lay over the body's and the tint doubled (LOW, UI
    // audit 2026-11-05).
    readonly property real tailSeam: 1 / Math.max(1, Screen.devicePixelRatio)

    Shape {
        visible: Popups.align === "above"
        readonly property real menuX: Math.max(Tokens.panelPopupMargin, Math.min(root.Window.width - root.width - Tokens.panelPopupMargin, Popups.anchorX - root.width / 2))
        readonly property real tipX: Math.max(Tokens.radiusMenu + Tokens.dockMenuTailWidth / 2, Math.min(root.width - Tokens.radiusMenu - Tokens.dockMenuTailWidth / 2, Popups.anchorX - menuX))
        x: tipX - Tokens.dockMenuTailWidth / 2
        y: root.height - root.tailSeam
        width: Tokens.dockMenuTailWidth
        height: Tokens.dockMenuTailHeight + root.tailSeam
        preferredRendererType: Shape.CurveRenderer
        Accessible.ignored: true

        ShapePath {
            strokeWidth: 0
            fillColor: root.glassFill // the menu's own glass (ADR-0039 step 22)
            startX: 0
            startY: 0
            PathLine {
                x: Tokens.dockMenuTailWidth
                y: 0
            }
            PathLine {
                x: Tokens.dockMenuTailWidth / 2
                y: Tokens.dockMenuTailHeight + root.tailSeam
            }
            PathLine {
                x: 0
                y: 0
            }
        }
    }

    // The same tail on the side of the menu that faces a Dock on the left ("rightOf": the menu is right of the shelf, the tail
    // points left) or right edge ("leftOf"). The Overlay centres the menu on the icon along the edge.
    Shape {
        id: sideTail
        readonly property bool facingLeft: Popups.align === "rightOf"
        visible: facingLeft || Popups.align === "leftOf"
        readonly property real menuY: Math.max(0, Math.min(root.Window.height - root.height - Tokens.panelPopupMargin, Popups.anchorY - root.height / 2))
        readonly property real tipY: Math.max(Tokens.radiusMenu + Tokens.dockMenuTailWidth / 2, Math.min(root.height - Tokens.radiusMenu - Tokens.dockMenuTailWidth / 2, Popups.anchorY - menuY))
        x: facingLeft ? -Tokens.dockMenuTailHeight : root.width - root.tailSeam
        y: tipY - Tokens.dockMenuTailWidth / 2
        width: Tokens.dockMenuTailHeight + root.tailSeam
        height: Tokens.dockMenuTailWidth
        preferredRendererType: Shape.CurveRenderer
        Accessible.ignored: true

        ShapePath {
            strokeWidth: 0
            fillColor: root.glassFill // the menu's own glass (ADR-0039 step 22)
            startX: sideTail.facingLeft ? Tokens.dockMenuTailHeight + root.tailSeam : 0
            startY: 0
            PathLine {
                x: sideTail.facingLeft ? Tokens.dockMenuTailHeight + root.tailSeam : 0
                y: Tokens.dockMenuTailWidth
            }
            PathLine {
                x: sideTail.facingLeft ? 0 : Tokens.dockMenuTailHeight + root.tailSeam
                y: Tokens.dockMenuTailWidth / 2
            }
            PathLine {
                x: sideTail.facingLeft ? Tokens.dockMenuTailHeight + root.tailSeam : 0
                y: 0
            }
        }
    }

    Component.onCompleted: {
        if (autostartPath !== "")
            autostartCheck.running = true;
        // Windows opened after the shell started have no process id until Hyprland's list is read again (Force Quit needs it).
        if (info.running === true)
            Compositor.refreshToplevels();
    }

    Process {
        id: autostartCheck
        command: ["test", "-f", root.autostartPath]
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.autostart = code === 0;
        }
    }

    // The autostart file is written or removed (a plain desktop file; the isolated config home in a dev session) and the
    // executable's folder revealed by Apps (Apps.writeAutostart / removeAutostart / revealExecutable): this menu is destroyed
    // by Popups.close() the moment an item is chosen, which would kill a Process it owned before it finished.

    onActivated: item => {
        const data = root.info;
        const appId = root.appId();
        // A window chosen from the list (or a tile group) is the focus the user wants: nothing hands it back to the previous
        // window.
        if (item.id === "window" || item.id === "tileGroup")
            FocusReturn.skip();
        // Force Quit asks first (the same confirmation and kill path as the Grassfield menu's Force Quit…): the confirmation
        // replaces this menu, nothing is killed before its button.
        // Empty Trash asks first, macOS wording, destructive (Cancel has the focus). The Trash it empties is the isolated one in dev.
        if (item.id === "trashEmpty") {
            Popups.confirm(qsTranslate("DockMenu", "Are you sure you want to permanently erase the items in the Trash?"), qsTranslate("DockMenu", "You can’t undo this action."), qsTranslate("DockMenu", "Empty Trash"), "emptytrash", {}, true);
            return;
        }
        if (item.id === "forcequit" || item.id === "forcequitHung" || item.id === "endtask") {
            // Without Option, an app that does not respond: only its processes that do not respond (ADR-0035 decision 3-5).
            // With Option, and End Task (AM63: the same path, nothing new in the kill path): every process of the app.
            const pids = item.id === "forcequitHung" ? root.notResponding : Launch.forceQuitPids(data.windows.map(t => Compositor.pidOf(t)));
            if (pids.length === 0) {
                console.warn("grassfield-shell: force quit refused, no process id for", appId);
                Popups.close();
                return;
            }
            Popups.confirm(qsTranslate("DockMenu", "Force quit “%1”?").arg(Apps.nameFor(appId)), qsTranslate("DockMenu", "Unsaved changes in this application will be lost."), qsTranslate("DockMenu", "Force Quit"), "forcequit", {pid: pids[0], pids: pids, cls: root.appClasses}, true);
            return;
        }
        Popups.close();
        switch (item.id) {
        case "stackOption":
            Settings.setDockStackOptions(Stacks.withOption(Settings.dockStackOptions, data.path, item.key, item.value));
            break;
        case "folderRemove": {
            const home = Quickshell.env("HOME");
            Settings.setDockFolders(Settings.dockFolders.filter(f => Stacks.folderList([f], home, 1)[0] !== data.path));
            break;
        }
        case "folderOpen":
            Apps.openDetached(["gio", "open", data.path]);
            break;
        case "recentDocument":
            // macOS: a recent document opens in the app that used it (its Exec line with the file field code). When that app
            // cannot take the file the failure is shown; another app never opens it instead.
            if (!data.entry || !Apps.openDocument(data.entry, item.path))
                Popups.notice(qsTr("The document can’t be opened"), qsTr("%1 can’t open “%2”.").arg(data.entry && Apps.displayName(data.entry) !== "" ? Apps.displayName(data.entry) : qsTr("This app")).arg(DisplayName.text(Stacks.baseName(item.path))), "document");
            break;
        case "trashOpen":
            Trash.open();
            Trash.refresh();
            break;
        case "window":
            // Restores a minimized window and switches to its Desktop (the same call as a Dock click), its tile group coming
            // forward with it (TL29), once this menu's Exclusive overlay surface is gone: Hyprland refuses to focus a window
            // while it exists.
            Compositor.activateAfterLayer(item.ref, "grassfield-overlay");
            break;
        case "tileGroup":
            // The group's minimized members come back and the group comes forward, the app's window in front (TL29).
            Compositor.showTileGroupAfterLayer(item.ref, "grassfield-overlay", item.members);
            break;
        case "open":
        case "new":
            if (data.entry)
                Apps.launch(data.entry);
            break;
        case "action":
            Apps.launch(data.entry.actions[item.index]);
            break;
        case "remove":
            if (data.pinned)
                Settings.setDockPinned(DockModel.unpinKey(Settings.dockPinned, data.key, root.lookupFn));
            if (data.recent)
                Settings.setDockRecent(Settings.dockRecent.filter(r => r !== data.key));
            break;
        case "keep":
            if (data.pinned)
                Settings.setDockPinned(DockModel.unpinKey(Settings.dockPinned, data.key, root.lookupFn));
            else
                Settings.setDockPinned(DockModel.pin(Settings.dockPinned, data.key));
            break;
        case "login":
            // Refused (nothing written or removed) for an id that is not a plain file name or a hostile command.
            if (root.autostartPath !== "" && root.autostart)
                Apps.removeAutostart(root.autostartPath);
            else if (root.autostartPath !== "" && AppLaunch.autostartText(data.entry) !== "")
                Apps.writeAutostart(root.autostartPath, AppLaunch.autostartText(data.entry));
            break;
        case "reveal":
            Apps.revealExecutable(data.entry.command && data.entry.command.length > 0 ? data.entry.command[0] : "");
            break;
        case "showall":
            if (appId !== "")
                Compositor.bringAllToFront(appId);
            break;
        case "hide":
            if (appId !== "")
                Compositor.hideApp(appId);
            break;
        case "hideOthers":
            if (appId !== "")
                Compositor.hideOthers(appId);
            break;
        case "quit":
            data.windows.forEach(t => Compositor.close(t));
            break;
        }
    }
}
