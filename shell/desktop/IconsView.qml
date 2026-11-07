pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.widgets
import "../widgets/Placements.js" as Placements
import qs.services
import qs.notifications
import "IconsLogic.js" as Logic

// Desktop icons (docs/specs/desktop.md): the files of the desktop folder as a grid of icons on the
// wallpaper surface, so a click between icons simply lands on the wallpaper and the widgets (a
// layer above) keep their own input. Selection, rubber band, keyboard navigation, inline rename,
// context menus, drops from applications and drags out. Files are only touched by the explicit
// actions of this item, through files.
FocusScope {
    id: root

    // Screen and window of the hosting surface (the context menu is a PopupWindow anchored to it).
    required property ShellScreen screen
    required property var hostWindow
    // The desktop folder, shared by the views of every screen (DesktopIcons.qml).
    required property DesktopFiles files
    // This screen shows the icons (the primary screen, Show Desktop Items on). Another screen only has the empty-desktop
    // menu and the rubber band: no icon, no slot, nothing to arrange.
    property bool iconsHere: true
    // The desktop surface holds the keyboard (KeyboardFocus.js "held"): the desktop keyboard actions below
    // (arrows, Return, Ctrl+O, Ctrl+Backspace, Ctrl+A, Space, Esc) run only then.
    property bool keysActive: false
    // The desktop is the key surface (it holds the keyboard or its menu, or a press on it is getting the keyboard): a selection
    // is drawn emphasized (the accent label) only then, grey otherwise, as Files' views (UI audit 2026-11-05 U25).
    property bool isKey: false
    // An icon drag (real drag-and-drop) is in progress.
    property bool dragging: false

    // Selected names ({name: true}) and the keyboard cursor.
    property var selected: ({})
    property string current: ""
    property string renaming: ""
    // The text typed in the rename field so far.
    property string renameDraft: ""
    property string renameError: ""
    // Rubber band in item coordinates, or null.
    property var band: null
    property var bandBase: ({})
    // Context menu: kind "icon" | "desktop", position in window coordinates.
    property string menuKind: ""
    property point menuAt: Qt.point(0, 0)
    // "About This Wallpaper" (the online daily picture's attribution, or a shipped photograph's) is open: a card anchored where
    // the menu was.
    property bool aboutOpen: false

    readonly property real margin: Tokens.desktopIconMargin
    readonly property real topInset: Tokens.menubarHeight + margin
    // The Dock sits on one edge (bottom, left or right): keep the grid clear of it.
    readonly property real bottomInset: margin + Settings.dockFootprint.bottom
    readonly property real leftInset: margin + Settings.dockFootprint.left
    readonly property real areaW: Math.max(0, width - leftInset - margin - Settings.dockFootprint.right)
    readonly property real areaH: Math.max(0, height - topInset - bottomInset)
    readonly property var grid: Logic.gridSize(areaW, areaH, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight)
    // Nothing is exposed before every input of the first layout is final (Logic.settledOn): no default layout that then moves,
    // no partial or placeholder listing that then goes.
    readonly property bool ready: files.dir !== "" && Logic.settledOn({
        width: width,
        height: height,
        settings: Settings.loaded,
        widgets: Widgets.loaded,
        positions: files.positionsLoaded,
        listed: files.entriesListed
    })
    // Widgets of this screen are never overlapped: slots under a widget tile are not available to
    // icons (widgets win; the icons move to the next free slot).
    readonly property var widgetRects: {
        if (!screen) // the display was just unplugged; its surface is going away
            return [];
        const g = Widgets.gridFor(screen);
        const out = [];
        for (const e of Widgets.desktop) {
            if (e.screen !== screen.name)
                continue;
            const s = Placements.px(e.size, g.cell, g.gap);
            out.push({
                x: g.x0 + e.col * (g.cell + g.gap),
                y: g.y0 + e.row * (g.cell + g.gap),
                w: s.w,
                h: s.h
            });
        }
        return out;
    }
    readonly property var blocked: Logic.blockedSlots(widgetRects, leftInset, topInset, areaW, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight, grid.cols, grid.rows)
    readonly property var lay: ready && iconsHere ? Logic.layout(files.names, files.positions, grid.cols, grid.rows, blocked) : ({})
    readonly property var shown: files.entries.filter(e => lay[e.name] !== undefined)
    readonly property var selectedNames: Object.keys(selected).filter(n => selected[n] === true && lay[n] !== undefined)
    readonly property var selectedPaths: selectedNames.map(n => files.path(n))

    // Keyboard focus events for the host's state machine (KeyboardFocus.js): {type: "menuOpened"},
    // {type: "menuClosed", how: "esc" | "item"}.
    signal focusEvent(var event)

    // Dedicated key sink: the focus item of this scope whenever no rename field is open, so that a
    // finished rename can never hand focus back to its (hidden) field. (No keyboard reaches it in
    // safe mode.)
    Item {
        id: keySink
        focus: true
        activeFocusOnTab: false
    }

    // The key sink becomes the scope's focus item: at a user press on the desktop and at the end of a
    // rename or menu.
    function restoreFocus(): void {
        keySink.forceActiveFocus();
    }

    activeFocusOnTab: false
    Accessible.role: Accessible.List
    Accessible.name: qsTr("Desktop")

    // ---- the entrance (ADR-0040 step 6, ID-20): the icons appear with the menu bar and the Dock, in one fade, once their
    // first layout is final (`ready`) ----
    // Taken once, at creation (the screen is gone when a removed output destroys the view).
    property string entranceKey: ""
    property real entrance: Entrance.revealed ? 1 : 0
    Behavior on entrance {
        NumberAnimation {
            duration: Appearance.duration(Tokens.sessionRevealMs)
        }
    }
    opacity: entrance
    // Final: the first layout is, or the icons are turned off in Settings (nothing to wait for).
    readonly property bool entranceFinal: ready || (Settings.loaded && MainDisplay.ready && !iconsHere)
    onEntranceFinalChanged: {
        if (entranceFinal && root.entranceKey !== "")
            Entrance.ready(root.entranceKey);
    }
    Component.onCompleted: {
        root.entranceKey = "icons:" + (screen ? screen.name : "");
        Entrance.expect(root.entranceKey);
        if (entranceFinal)
            Entrance.ready(root.entranceKey);
    }
    Component.onDestruction: {
        if (!Entrance.revealed)
            Entrance.forget(root.entranceKey);
    }

    // No pointer input before the entrance: the icons are not visible yet (opacity does not stop clicks or drags).
    MouseArea {
        anchors.fill: parent
        z: 1000
        enabled: !Entrance.revealed
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onWheel: wheel => wheel.accepted = true
    }

    // Persist the slots handed out to icons that had none (new files, a smaller grid).
    onLayChanged: syncTimer.restart()

    Timer {
        id: syncTimer
        interval: 0
        onTriggered: {
            if (!root.ready)
                return;
            const pos = files.positions;
            let changed = false;
            for (const n of Object.keys(root.lay)) {
                const p = pos[n];
                if (!p || p.col !== root.lay[n].col || p.row !== root.lay[n].row)
                    changed = true;
            }
            if (changed)
                files.setPositions(Object.assign({}, pos, root.lay));
        }
    }

    // Cell of an icon; empty for a name without a slot (a delegate can be re-evaluated while a rename
    // swaps the old name for the new one in the folder model).
    function rectOf(name: string): rect {
        if (lay[name] === undefined)
            return Qt.rect(0, 0, 0, 0);
        const s = Logic.slotPos(lay[name].col, lay[name].row, areaW, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight);
        // On whole device pixels: the icons and labels stay crisp at a fractional scale (UI audit 2026-11-05, LOW).
        const dpr = Math.max(1, Screen.devicePixelRatio);
        return Qt.rect(Math.round((leftInset + s.x) * dpr) / dpr, Math.round((topInset + s.y) * dpr) / dpr, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight);
    }

    function iconAt(x: real, y: real): string {
        for (const n of Object.keys(lay)) {
            const r = rectOf(n);
            if (x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height)
                return n;
        }
        return "";
    }

    function selectOnly(name: string): void {
        const next = {};
        if (name !== "")
            next[name] = true;
        selected = next;
        current = name;
    }

    function clearSelection(): void {
        selected = ({});
        current = "";
    }

    function endRename(): void {
        renaming = "";
        renameError = "";
        renameDraft = "";
        restoreFocus();
    }

    // Commits the rename field. A refused name keeps the field open with the reason, unless `endOnError`
    // (the field lost the keyboard and cannot stay open): then the rename is cancelled.
    function commitRename(name: string, text: string, endOnError: bool): void {
        if (root.renaming !== name)
            return;
        const why = files.rename(name, text);
        if (why === "" || why === "same") {
            root.endRename();
            root.selectOnly(why === "" ? text : name);
        } else if (endOnError) {
            root.endRename();
        } else {
            root.renameError = why;
        }
    }

    // The rename field lost the keyboard (a click elsewhere, the pointer left for a window): commit what was typed,
    // as macOS does. Deferred one turn so that a rename ended by the same event is not committed twice.
    function renameFocusLost(name: string): void {
        Qt.callLater(() => {
            if (root.renaming === name)
                root.commitRename(name, root.renameDraft, true);
        });
    }

    // Opens the rename field of one icon.
    function beginRename(name: string): void {
        if (name === "" || lay[name] === undefined)
            return;
        selectOnly(name);
        renameError = "";
        renameDraft = name;
        renaming = name;
    }

    function openNames(names: var): void {
        for (const n of names)
            files.open(n);
    }

    // Context menu: a PopupWindow anchored to the desktop surface with a grab (ADR-0012). The compositor
    // dismisses it on a click elsewhere and swallows that click.
    readonly property bool menuOpen: menuKind !== ""

    function openMenu(kind: string, x: real, y: real): void {
        // Nothing opens over the lock screen (GF-116).
        if (SessionState.refuses("desktop menu"))
            return;
        menuAt = Qt.point(x, y);
        // What the menu offers beyond the fixed items is read now: the clipboard's files (Paste) or the apps that open
        // the selection (Open With ▸); the rows appear as soon as the answer is in.
        if (kind === "desktop")
            files.refreshClipboard();
        else
            files.resolveOpenWith(selectedPaths);
        menuKind = kind;
        menuPopup.visible = true;
        focusEvent({
            type: "menuOpened"
        });
    }

    // Closes the menu on the user's action ("esc" or "item"): the keyboard is back on the desktop.
    function closeMenu(how: string): void {
        if (!menuOpen)
            return;
        menuKind = "";
        menuPopup.visible = false;
        focusEvent({
            type: "menuClosed",
            how: how
        });
    }

    // The attribution card: like the menu, a PopupWindow with a grab; the keyboard state machine sees it as a menu.
    function openAbout(): void {
        if (SessionState.refuses("desktop attribution card"))
            return;
        aboutOpen = true;
        aboutPopup.visible = true;
        focusEvent({
            type: "menuOpened"
        });
    }

    function closeAbout(how: string): void {
        if (!aboutOpen)
            return;
        aboutOpen = false;
        aboutPopup.visible = false;
        focusEvent({
            type: "menuClosed",
            how: how
        });
    }

    // The session locks: the context menu and the attribution card close, and the desktop lets the keyboard go ("outside",
    // as a dismissal by a click elsewhere) (GF-116, review of 1d2c856).
    Connections {
        target: SessionState

        function onLockedChanged(): void {
            if (!SessionState.locked)
                return;
            root.closeMenu("outside");
            root.closeAbout("outside");
        }
    }

    function applyMenu(action: string): void {
        const names = selectedNames;
        const paths = selectedPaths;
        const kind = menuKind;
        closeMenu("item");
        if (kind === "desktop") {
            if (action === "newFolder")
                files.newFolder();
            else if (action === "paste")
                files.paste();
            else if (action === "getInfo")
                files.showInfo([files.dir]);
            else if (action === "wallpaper")
                // SINGLE CALL SITE for "Change Wallpaper…" on a display: Settings opens Wallpaper on `root.screen.name`, the
                // output the right click happened on (`--section=wallpaper --display=<output>`, ADR-0044 D-5).
                SettingsApp.openSection("wallpaper", root.screen ? root.screen.name : "");
            else if (action === "editWidgets")
                Notifications.openWidgetGallery(root.screen ? root.screen.name : "");
            else if (action.startsWith("cleanUp") && !root.ready)
                return;
            else if (action === "cleanUp")
                files.setPositions(Logic.arrange(Logic.visualOrder(lay), grid.cols, grid.rows, blocked));
            else if (action.startsWith("cleanUpBy:"))
                cleanUpBy(action.substring(10));
            else if (action === "aboutWallpaper")
                openAbout();
            return;
        }
        if (action === "rename" && names.length === 1)
            beginRename(names[0]);
        else if (action === "open")
            openNames(names);
        else if (action.startsWith("openWith:"))
            files.openWith(action.substring(9), paths);
        else if (action === "getInfo")
            files.showInfo(paths);
        else if (action === "compress")
            files.compress(names);
        else if (action === "duplicate")
            files.duplicate(names);
        else if (action === "alias")
            files.makeAlias(names);
        else if (action === "quickLook")
            GlanceApp.toggle(paths);
        else if (action === "copy")
            files.copy(paths);
        else if (action === "trash")
            files.trash(paths);
    }

    // Clean Up By: every icon in the chosen order (name, kind, size, dates), packed from the top-right corner.
    function cleanUpBy(key: string): void {
        files.readMeta(meta => files.setPositions(Logic.arrange(Logic.orderBy(files.names, key, meta), grid.cols, grid.rows, blocked)));
    }

    // A press elsewhere ends the rename: it commits (macOS). The press goes on with its own action.
    function commitRenameOnPress(): void {
        if (renaming !== "")
            commitRename(renaming, renameDraft, true);
    }

    // Select by press: Ctrl toggles, Shift adds, otherwise the icon alone (kept as is when it is
    // already part of the selection, so that a drag carries the whole selection).
    function press(name: string, modifiers: int, right: bool): void {
        root.restoreFocus();
        commitRenameOnPress();
        if (modifiers & Qt.ControlModifier) {
            const next = Object.assign({}, selected);
            if (next[name])
                delete next[name];
            else
                next[name] = true;
            selected = next;
            current = name;
        } else if (modifiers & Qt.ShiftModifier) {
            selected = Object.assign({}, selected, {
                [name]: true
            });
            current = name;
        } else if (!selected[name]) {
            selectOnly(name);
        } else {
            current = name;
        }
    }

    // A click (release without drag) on an icon: without Ctrl or Shift it leaves that icon alone
    // selected, also when it was part of a larger selection (kept on press for a group drag).
    function tap(name: string, modifiers: int): void {
        if (!(modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) && lay[name] !== undefined)
            selectOnly(name);
    }

    function rects(): var {
        const out = {};
        for (const n of Object.keys(lay)) {
            const r = rectOf(n);
            out[n] = {
                x: r.x,
                y: r.y,
                w: r.width,
                h: r.height
            };
        }
        return out;
    }

    function updateBand(x: real, y: real, x0: real, y0: real): void {
        const b = {
            x: Math.min(x, x0),
            y: Math.min(y, y0),
            w: Math.abs(x - x0),
            h: Math.abs(y - y0)
        };
        band = b;
        const next = Object.assign({}, bandBase);
        for (const n of Logic.inRect(rects(), b))
            next[n] = true;
        selected = next;
    }

    // A drop on the desktop. Internal drags (marker format) rearrange; everything else is copied in.
    function dropped(drop: var): void {
        const dir = files.dir;
        if (drop.formats.indexOf("application/x-grassfield-desktop-icons") >= 0) {
            let m = null;
            try {
                m = JSON.parse(drop.getDataAsString("application/x-grassfield-desktop-icons"));
            } catch (e) {
                m = null;
            }
            if (m && Array.isArray(m.names) && typeof m.anchor === "string" && lay[m.anchor] !== undefined) {
                const want = Logic.slotAt(drop.x - m.hx - leftInset, drop.y - m.hy - topInset, areaW, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight, grid.cols, grid.rows);
                const names = m.names.filter(n => typeof n === "string" && lay[n] !== undefined);
                files.setPositions(Object.assign({}, files.positions, Logic.moveGroup(lay, names, m.anchor, want, grid.cols, grid.rows)));
                drop.accept(Qt.MoveAction);
                return;
            }
        }
        if (!drop.hasUrls) {
            drop.accept(Qt.IgnoreAction);
            return;
        }
        const paths = Logic.parseUriList(drop.getDataAsString("text/uri-list"));
        drop.accept(Qt.CopyAction);
        if (paths.length === 0 || dir === "")
            return;
        const want = Logic.slotAt(drop.x - Tokens.desktopIconCellWidth / 2 - leftInset, drop.y - Tokens.desktopIconCellHeight / 2 - topInset, areaW, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight, grid.cols, grid.rows);
        const added = files.importPaths(paths, false, null);
        // Reserve slots for the new names next to the drop point.
        const taken = {};
        for (const n of Object.keys(lay))
            taken[Logic.key(lay[n].col, lay[n].row)] = true;
        const pos = Object.assign({}, files.positions);
        for (const n of added) {
            const spot = Logic.nearestFree(taken, want, grid.cols, grid.rows);
            if (!spot)
                break;
            pos[n] = spot;
            taken[Logic.key(spot.col, spot.row)] = true;
        }
        files.setPositions(pos);
    }

    // ---- keyboard --------------------------------------------------------------------------------

    // Active only while the desktop surface holds the keyboard (keysActive).
    // Keyboard actions that change or open files (Return/F2 rename, Ctrl+O, Ctrl+Backspace, and as on macOS Ctrl+I Get
    // Info, Ctrl+D Duplicate, Ctrl+C Copy, Ctrl+V Paste) are on only while the
    // compositor enforces the desktop focus policy (ADR-0012, "desktop-focus-v2" capability), set by the host: without
    // it the desktop can keep the keyboard after a click on Hyprland's active window, which the shell cannot observe.
    // Arrows, Ctrl+A, Space (Glance) and Esc only change the selection or a preview.
    property bool fileKeyActions: false
    Keys.enabled: root.keysActive
    Keys.onPressed: event => {
        if (root.renaming !== "")
            return;
        const ctrl = (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0;
        let dir = "";
        switch (event.key) {
        case Qt.Key_Left:
            dir = "left";
            break;
        case Qt.Key_Right:
            dir = "right";
            break;
        case Qt.Key_Up:
            dir = "up";
            break;
        case Qt.Key_Down:
            dir = "down";
            break;
        }
        if (dir !== "") {
            root.selectOnly(Logic.navigate(root.lay, root.current, dir));
            event.accepted = true;
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            // Tab and Shift+Tab walk through the icons (macOS), so the keyboard alone reaches every one.
            root.selectOnly(Logic.cycle(root.lay, root.current, event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) !== 0));
            event.accepted = true;
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !ctrl && root.fileKeyActions) {
            // Return renames the selected file (macOS); opening is Ctrl+O or a double click.
            if (root.selectedNames.length === 1)
                root.beginRename(root.selectedNames[0]);
            event.accepted = true;
        } else if (ctrl && event.key === Qt.Key_O && root.fileKeyActions) {
            root.openNames(root.selectedNames);
            event.accepted = true;
        } else if (event.key === Qt.Key_Space && !ctrl) {
            // Glance at the selected files (Space again closes it; folders are skipped by Glance itself).
            if (root.selectedPaths.length > 0)
                GlanceApp.toggle(root.selectedPaths);
            event.accepted = true;
        } else if (event.key === Qt.Key_F2 && root.fileKeyActions) {
            if (root.selectedNames.length === 1)
                root.beginRename(root.selectedNames[0]);
            event.accepted = true;
        } else if (ctrl && event.key === Qt.Key_I && root.fileKeyActions) {
            // Get Info of the selection, or of the desktop folder when nothing is selected (macOS).
            files.showInfo(root.selectedPaths.length > 0 ? root.selectedPaths : [files.dir]);
            event.accepted = true;
        } else if (ctrl && event.key === Qt.Key_D && root.fileKeyActions) {
            if (root.selectedNames.length > 0)
                files.duplicate(root.selectedNames);
            event.accepted = true;
        } else if (ctrl && event.key === Qt.Key_C && root.fileKeyActions) {
            if (root.selectedPaths.length > 0)
                files.copy(root.selectedPaths);
            event.accepted = true;
        } else if (ctrl && event.key === Qt.Key_V && root.fileKeyActions) {
            files.pasteFromClipboard();
            event.accepted = true;
        } else if (ctrl && event.key === Qt.Key_Backspace && root.fileKeyActions) {
            if (root.selectedPaths.length > 0)
                files.trash(root.selectedPaths);
            event.accepted = true;
        } else if (ctrl && event.key === Qt.Key_A) {
            const all = {};
            for (const n of Object.keys(root.lay))
                all[n] = true;
            root.selected = all;
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape) {
            // Esc closes Glance first (as Quick Look); the next one clears the selection.
            if (GlanceApp.open)
                GlanceApp.close();
            else
                root.clearSelection();
            event.accepted = true;
        }
    }

    Connections {
        target: root.files

        // New Folder (a user action) opens the rename field of the folder it created.
        function onRenameWanted(name: string): void {
            Qt.callLater(() => root.beginRename(name));
        }

        // The file system refused an accepted rename: reopen the field with the reason inline.
        function onRenameFailed(name: string, reason: string): void {
            root.beginRename(name);
            root.renameError = "failed";
        }
    }

    // ---- empty space: rubber band, focus, context menu ---------------------------------------------

    MouseArea {
        id: background
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property real x0: 0
        property real y0: 0
        property bool banding: false

        onPressed: mouse => {
            if (root.iconAt(mouse.x, mouse.y) !== "") {
                mouse.accepted = false;
                return;
            }
            root.restoreFocus();
            root.commitRenameOnPress();
            if (mouse.button === Qt.RightButton) {
                root.clearSelection();
                root.openMenu("desktop", mouse.x, mouse.y);
                return;
            }
            x0 = mouse.x;
            y0 = mouse.y;
            banding = false;
            root.bandBase = (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) ? root.selected : ({});
            if (!(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)))
                root.clearSelection();
        }
        onPositionChanged: mouse => {
            if (!pressed || mouse.buttons !== Qt.LeftButton)
                return;
            if (!banding && Math.abs(mouse.x - x0) + Math.abs(mouse.y - y0) < Tokens.desktopIconDragThreshold)
                return;
            banding = true;
            root.updateBand(Math.max(0, Math.min(root.width, mouse.x)), Math.max(0, Math.min(root.height, mouse.y)), x0, y0);
        }
        onReleased: {
            banding = false;
            root.band = null;
        }
        onCanceled: {
            banding = false;
            root.band = null;
        }
    }

    DropArea {
        anchors.fill: parent
        enabled: root.iconsHere
        keys: ["text/uri-list", "application/x-grassfield-desktop-icons"]
        onDropped: drop => root.dropped(drop)
    }

    // ---- icons -------------------------------------------------------------------------------------

    Repeater {
        model: ScriptModel {
            values: root.shown
            objectProp: "name"
        }

        delegate: DesktopIcon {
            id: icon

            required property var modelData

            name: modelData.name
            isDir: modelData.isDir
            filePath: modelData.path
            folderColor: root.files.folderStyle(modelData.name).color
            folderGlyph: root.files.folderStyle(modelData.name).glyph
            x: root.rectOf(modelData.name).x
            y: root.rectOf(modelData.name).y
            selected: root.selected[modelData.name] === true
            key: root.isKey
            renaming: root.renaming === modelData.name
            renameError: root.renameError
            dragPaths: root.selectedPaths
            dragNames: root.selectedNames
            onPressedIcon: (modifiers, right) => root.press(modelData.name, modifiers, right)
            onTappedIcon: modifiers => root.tap(modelData.name, modifiers)
            onDragActiveChanged: root.dragging = icon.dragActive
            onActivated: root.openNames([modelData.name])
            onMenuRequested: (px, py) => root.openMenu("icon", px, py)
            onRenameEdited: text => root.renameDraft = text
            onRenameAccepted: text => root.commitRename(modelData.name, text, false)
            onRenameCancelled: root.endRename()
            onRenameFocusLost: root.renameFocusLost(modelData.name)
        }
    }

    // Rubber band.
    Rectangle {
        visible: root.band !== null
        x: root.band ? root.band.x : 0
        y: root.band ? root.band.y : 0
        width: root.band ? root.band.w : 0
        height: root.band ? root.band.h : 0
        radius: Tokens.desktopIconSelectionRadius / 2
        color: Appearance.withAlpha(Appearance.colors.accent, Tokens.desktopIconRubberBandOpacity)
        // One device pixel (UI audit 2026-11-05, LOW).
        border.width: 1 / Math.max(1, Screen.devicePixelRatio)
        border.color: Appearance.withAlpha(Appearance.colors.accent, Tokens.desktopIconSelectionOpacity)
    }

    // Context menu: a PopupWindow with a grab, anchored to the desktop surface. It draws above windows and gets
    // the keyboard; Esc and an item hand it back to the desktop, a click elsewhere dismisses it (swallowed).
    // qmllint disable uncreatable-type
    PopupWindow {
        // qmllint enable uncreatable-type
        id: menuPopup

        // The popup covers the whole desktop surface and never resizes or repositions: the menu is placed inside it by
        // MenuPlace.place (pure) and a submenu opens inside it too (PopupMenu.bounds), so nothing the compositor does to fit
        // a growing popup (flip, slide) can move the menu once it is open (macOS: a context menu never moves).
        // qmllint disable missing-type incompatible-type
        anchor.window: root.hostWindow
        anchor.rect: Qt.rect(0, 0, root.hostWindow.width, root.hostWindow.height)
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Right
        anchor.adjustment: PopupAdjustment.None
        // qmllint enable missing-type incompatible-type
        implicitWidth: Math.max(1, root.hostWindow.width)
        implicitHeight: Math.max(1, root.hostWindow.height)
        color: "transparent"
        grabFocus: true
        // qmllint disable missing-type incompatible-type
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && visible ? menuBlur : null
        // qmllint enable missing-type incompatible-type

        // Dismissed by the compositor (a click elsewhere): the grab ended, the click was swallowed.
        onVisibleChanged: {
            if (visible) {
                (menuLoader.item as Item)?.forceActiveFocus();
                return;
            }
            if (root.menuOpen) {
                root.menuKind = "";
                root.focusEvent({
                    type: "menuClosed",
                    how: "outside"
                });
            }
        }

        Region {
            id: menuBlur
            item: menuLoader
            radius: Tokens.radiusMenu

            Region {
                item: (menuLoader.item as PopupMenu)?.submenuItem ?? null
                radius: Tokens.radiusMenu
            }
        }

        // A click anywhere outside the menu and its open submenu dismisses it, and is swallowed (the compositor did this
        // when the popup was only as large as the menu; the popup now covers the screen, so the shell does).
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: mouse => {
                const menu = menuLoader.item as PopupMenu;
                if (!menu || !menu.containsPoint(mouse.x, mouse.y))
                    menuPopup.visible = false;
            }
        }

        Loader {
            id: menuLoader
            // Where the menu opens: right of and below the pointer, flipped or slid to stay on the screen (MenuPlace.place). It
            // reads the menu's own size only, never an open submenu's.
            readonly property point placed: MenuPlace.place({x: root.menuAt.x, y: root.menuAt.y}, {w: (item as Item)?.width ?? 0, h: (item as Item)?.height ?? 0}, {w: menuPopup.width, h: menuPopup.height}, Tokens.panelPopupMargin)
            x: placed.x
            y: placed.y
            active: root.menuKind !== ""
            sourceComponent: IconMenu {
                bounds: menuPopup.contentItem
                kind: root.menuKind
                showKeyHints: root.fileKeyActions
                itemsHere: root.iconsHere
                aboutWallpaper: root.screen !== null && WallpaperState.aboutEntry(root.screen.name) !== null
                count: root.selectedNames.length
                singleName: root.selectedNames.length === 1 ? root.selectedNames[0] : ""
                pasteCount: root.files.clipboardPaths.length
                openWithApps: root.files.openWithApps
                onChoose: action => root.applyMenu(action)
                onCloseRequested: root.closeMenu("esc")
            }
            onLoaded: (item as Item).forceActiveFocus()
        }
    }

    // "About This Wallpaper": the attribution card. Esc, Return, Space and Close dismiss it; a click elsewhere too (swallowed).
    // qmllint disable uncreatable-type
    PopupWindow {
        // qmllint enable uncreatable-type
        id: aboutPopup

        // qmllint disable missing-type incompatible-type
        anchor.window: root.hostWindow
        anchor.rect: Qt.rect(root.menuAt.x, root.menuAt.y, 1, 1)
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Right
        anchor.adjustment: PopupAdjustment.All
        // qmllint enable missing-type incompatible-type
        implicitWidth: (aboutLoader.item as Item)?.width ?? 1
        implicitHeight: (aboutLoader.item as Item)?.height ?? 1
        color: "transparent"
        grabFocus: true
        // qmllint disable missing-type incompatible-type
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && visible ? aboutBlur : null
        // qmllint enable missing-type incompatible-type

        onVisibleChanged: {
            if (visible) {
                (aboutLoader.item as Item)?.forceActiveFocus();
                return;
            }
            if (root.aboutOpen) {
                root.aboutOpen = false;
                root.focusEvent({
                    type: "menuClosed",
                    how: "outside"
                });
            }
        }

        Region {
            id: aboutBlur
            item: aboutLoader
            radius: Tokens.radiusMenu
        }

        Loader {
            id: aboutLoader
            active: root.aboutOpen
            sourceComponent: AttributionCard {
                entry: (root.screen && WallpaperState.aboutEntry(root.screen.name)) || ({})
                onCloseRequested: root.closeAbout("esc")
            }
            onLoaded: (item as Item).forceActiveFocus()
        }
    }
}
