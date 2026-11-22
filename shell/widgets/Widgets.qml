pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import Grassfield.Ui
import qs.lib
import qs.services
import "Placements.js" as Placements

// Widget placements (widgets/1, docs/specs/widgets.md): where each widget sits, in the Notification
// Center and on the desktop, persisted in Mode.stateDir ($GRASSFIELD_STATE_HOME, else $XDG_STATE_HOME/grassfield)
// as widgets.json (directory 0700, file 0600, written atomically, version 1). Ids that are not in
// the registry, sizes a widget does not offer and entries past the cap are dropped when the file is read
// (and a file over Tokens.widgetMaxFileBytes is rejected); desktop entries that are off the grid or
// overlap are moved to the nearest free cell. A file that
// cannot be parsed is copied to widgets.json.bak before the next write replaces it.
Singleton {
    id: root

    property var placements: Placements.empty()
    readonly property var center: placements.center
    readonly property var desktop: placements.desktop
    property bool loaded: false
    // The shell's one dev rule (qs.lib Mode, ADR-0019, SEC-03): the IPC test hooks below answer only in a dev session.
    readonly property bool devHooks: Mode.dev

    readonly property string stateDir: Mode.stateDir
    readonly property string path: stateDir + "/widgets.json"

    // Battery widget availability: hidden from the gallery on a machine without a battery.
    readonly property var battery: UPower.displayDevice
    readonly property bool hasBattery: battery !== null && battery.isPresent && battery.isLaptopBattery

    function available(id: string): bool {
        return id !== "battery" || hasBattery;
    }

    // The Dock's footprint on the screen (Settings.dockFootprintFor: shelf, indicator row, bottom margin) is reserved even when
    // the Dock autohides, so widgets never sit where it appears; it follows the display's own Dock size and edge.

    // Grid of a screen: {cols, rows, x0, y0, cell, gap} in screen px, below the menu bar and above the Dock.
    function gridFor(screen: var): var {
        // A screen that was just unplugged reads as null while its surfaces go away: an empty grid, never an error.
        if (!screen)
            return {cols: 0, rows: 0, x0: 0, y0: 0, cell: Tokens.widgetCell, gap: Tokens.widgetGap};
        const dock = Settings.dockFootprintFor(screen.name, false);
        const g = Placements.gridFor(screen.width, screen.height, Tokens.widgetCell, Tokens.widgetGap, Tokens.widgetDesktopMargin, Tokens.menubarHeight, dock.bottom, dock.left, dock.right);
        return {
            cols: g.cols,
            rows: g.rows,
            x0: g.x0,
            y0: g.y0,
            cell: Tokens.widgetCell,
            gap: Tokens.widgetGap
        };
    }

    function screenByName(name: string): var {
        for (const s of Quickshell.screens) {
            if (s.name === name)
                return s;
        }
        return null;
    }

    // ---- changes (each one saves) ---------------------------------------------------------------

    function apply(next: var): void {
        placements = next;
        saveTimer.restart();
    }

    function addCenter(id: string, size: string): void {
        if (available(id))
            apply(Placements.addCenter(placements, id, size));
    }

    // Returns false when the desktop of that screen has no room left.
    function addDesktop(id: string, size: string, screenName: string): bool {
        const screen = screenByName(screenName);
        if (!screen || !available(id))
            return false;
        const grid = gridFor(screen);
        const next = Placements.addDesktop(placements, id, size, screenName, grid.cols, grid.rows);
        if (next.desktop.length === placements.desktop.length)
            return false;
        apply(next);
        return true;
    }

    function remove(uid: string): void {
        apply(Placements.remove(placements, uid));
    }

    function setSize(uid: string, size: string): void {
        const entry = placements.desktop.find(e => e.uid === uid);
        const screen = entry ? screenByName(entry.screen) : null;
        const grid = screen ? gridFor(screen) : null;
        apply(Placements.setSize(placements, uid, size, grid));
    }

    function moveDesktop(uid: string, col: int, row: int, screenName: string): void {
        const screen = screenByName(screenName);
        if (!screen)
            return;
        const grid = gridFor(screen);
        apply(Placements.moveDesktop(placements, uid, {
            col: col,
            row: row
        }, grid.cols, grid.rows));
    }

    // Keyboard moves (GF-106; the widget menu): one cell on the desktop, one place in the Notifications panel.
    function canStepDesktop(uid: string, dir: string, screenName: string): bool {
        const screen = screenByName(screenName);
        if (!screen)
            return false;
        const grid = gridFor(screen);
        return Placements.stepSpot(placements, uid, dir, grid.cols, grid.rows) !== null;
    }

    function stepDesktop(uid: string, dir: string, screenName: string): void {
        const screen = screenByName(screenName);
        if (!screen)
            return;
        const grid = gridFor(screen);
        apply(Placements.stepDesktop(placements, uid, dir, grid.cols, grid.rows));
    }

    function stepCenter(uid: string, delta: int): void {
        const at = placements.center.findIndex(e => e.uid === uid);
        if (at >= 0)
            apply(Placements.moveCenter(placements, uid, at + delta));
    }

    // Moves the desktop widgets of a screen onto its grid (off-grid or overlapping ones go to the
    // nearest free cell; none that fits is dropped). Called on load and when the grid changes.
    function fitScreen(screenName: string): void {
        const screen = screenByName(screenName);
        if (!screen || !loaded)
            return;
        const grid = gridFor(screen);
        const r = Placements.fitScreen(placements, screenName, grid.cols, grid.rows);
        if (r.changed)
            apply(r.state);
    }

    // ---- persistence ----------------------------------------------------------------------------

    function load(text: string): void {
        const r = Placements.parse(text, Tokens.widgetMaxEntries, Tokens.widgetMaxFileBytes);
        if (!r.ok) {
            console.warn("widgets: " + path + " is not a version 1 widgets file; keeping a copy as widgets.json.bak and starting empty");
            Quickshell.execDetached(["cp", "-p", path, path + ".bak"]);
        }
        placements = r.ok && text.trim() === "" ? Placements.firstRun() : r.state;
        loaded = true;
        for (const screen of Quickshell.screens)
            fitScreen(screen.name);
    }

    Component.onCompleted: prepare.running = true

    // The directory and the file get restrictive modes before the first write (FileView cannot set
    // modes and its atomic write keeps the mode of an existing target).
    Process {
        id: prepare
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", root.stateDir, root.path]
        onRunningChanged: {
            if (!running)
                file.path = root.path;
        }
    }

    FileView {
        id: file
        printErrors: false
        atomicWrites: true
        onLoaded: root.load(file.text())
        onLoadFailed: {
            root.placements = Placements.firstRun();
            root.loaded = true;
        }
    }

    // Test hooks (tests/visual/widgets-blur.sh). `status` is read-only; the two that change placements are refused outside a
    // nested dev session (GRASSFIELD_DEV=1, never GRASSFIELD_SESSION=1).
    IpcHandler {
        target: "widgets"

        // Test hooks (tests/visual/widgets-blur.sh), refused outside a dev session (SEC-04).
        // JSON [{uid, id, size, x, y, w, h}]: the desktop widgets of `screen` in output pixels.
        function status(screen: string): string {
            if (!root.devHooks)
                return Mode.refused;
            const s = root.screenByName(screen);
            if (!s)
                return "[]";
            const grid = root.gridFor(s);
            return JSON.stringify(root.desktop.filter(e => e.screen === screen).map(e => {
                const size = Placements.px(e.size, grid.cell, grid.gap);
                return {uid: e.uid, id: e.id, size: e.size, x: grid.x0 + e.col * (grid.cell + grid.gap), y: grid.y0 + e.row * (grid.cell + grid.gap), w: size.w, h: size.h};
            }));
        }

        function addDesktop(id: string, size: string, screen: string): string {
            if (!root.devHooks)
                return Mode.refused;
            return root.addDesktop(id, size, screen) ? "added" : "no room";
        }

        function clearDesktop(): string {
            if (!root.devHooks)
                return Mode.refused;
            root.apply(Object.assign({}, root.placements, {desktop: []}));
            return "cleared";
        }
    }

    Timer {
        id: saveTimer
        interval: 300
        onTriggered: {
            if (root.loaded)
                file.setText(Placements.serialize(root.placements));
        }
    }
}
