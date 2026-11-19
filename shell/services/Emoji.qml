pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import qs.platform
import qs.platform.shortcuts
import "EmojiLogic.js" as Logic

// Emoji & Symbols (ADR-0045 OC-3; docs/specs/clipboard.md "Emoji & Symbols", ES-1 to ES-9): Ctrl+Super+Space (bindings.lua, IPC
// `emoji toggle`) opens macOS 27's compact Character Viewer as a popover of the Overlay (popup kind "emoji",
// shell/overlay/EmojiPanel.qml) at the pointer, on the output under it. This service holds what the panel shows (Omarchy's own
// list, read at run time and never copied; Recently Used, kept private on the disk) and does what a choice asks: the panel
// closes, FocusReturn gives the keyboard back to the window that was active when it opened, and once that window is active
// again Omarchy's omarchy-menu-emoji-insert copies the glyph (sensitive: the clipboard history does not record it) and sends
// Shift+Insert; wtype types it when Omarchy's command is missing; without either one journal line says so (ADR-0045 OC-0.3).
// The decisions are EmojiLogic.js's, unit-tested (tests/unit/tst_emoji.qml).
Singleton {
    id: root

    // "idle" (not read yet), "loading", "ready", "missing" (no usable list: the panel says "Emoji list not available").
    property string state: "idle"
    // Omarchy's entries [{e, k}] and their categories [{id, start, end}] (EmojiLogic.categories).
    property var list: []
    property var groups: []
    // Recently Used, newest first (at most EmojiLogic.RECENTS_MAX).
    property var recents: []
    property bool recentsRead: false
    property bool recentsDirty: false
    // The panel is the Overlay's popup now.
    readonly property bool open: Popups.kind === "emoji"
    // The panel is asked for and the pointer's place is awaited (ES-1).
    property bool placing: false
    // The list is wanted (the first opening reads it; nothing is read before).
    property bool wanted: false

    readonly property string omarchyDir: Logic.omarchyPath(Quickshell.env("OMARCHY_PATH"))
    readonly property string dataPath: root.omarchyDir + "/shell/plugins/emojis/emojis.json"
    readonly property string insertPath: root.omarchyDir + "/bin/omarchy-menu-emoji-insert"
    readonly property string recentsPath: Mode.stateDir + "/emoji-recents.json"

    // The window the panel opened over (lower-case hex, "" for none: the desktop or nothing) and whether Hyprland closed it since:
    // a new window can take its address, so a closed one never gets the glyph.
    property string target: ""
    property bool targetClosed: false
    // The glyph waiting for its window, {emoji, target, closed}; the deadline passed; the last insertion's outcome (dev status).
    property var pendingInsert: null
    property bool insertExpired: false
    property string lastInsert: ""

    // The sections' titles (macOS's names, ADR-0045 OC-0.5): shown over the grid and in the category bar's tooltips, and searched.
    readonly property var titles: ({
            recents: qsTr("Recently Used"),
            smileys: qsTr("Smileys & People"),
            animals: qsTr("Animals & Nature"),
            food: qsTr("Food & Drink"),
            activity: qsTr("Activity"),
            travel: qsTr("Travel & Places"),
            objects: qsTr("Objects"),
            symbols: qsTr("Symbols"),
            flags: qsTr("Flags"),
            all: qsTr("All")
        })

    // ---- Opening and closing (ES-1) ----

    function toggle(): void {
        if (root.open || root.placing) {
            root.placing = false;
            cursorLate.stop();
            if (root.open)
                Popups.close();
            return;
        }
        // Nothing opens over the lock screen (GF-116).
        if (SessionState.refuses("emoji"))
            return;
        root.load();
        root.placing = true;
        cursorLate.restart();
        if (!cursorQuery.running)
            cursorQuery.running = true;
    }

    // The pointer's place came (`p` {x, y} in layout coordinates, null when unknown): the panel opens under it on its output,
    // else centred on the active display. The window it opens over is remembered now, as FocusReturn remembers it.
    function place(p: var): void {
        if (!root.placing)
            return;
        root.placing = false;
        cursorLate.stop();
        if (SessionState.locked)
            return;
        root.cancelInsert("the panel opened again");
        root.target = root.currentTarget();
        root.targetClosed = false;
        const screens = Quickshell.screens.map(s => ({name: s.name, x: s.x, y: s.y, width: s.width, height: s.height}));
        const at = p ? Logic.pointerOn(screens, p.x, p.y) : null;
        if (at)
            Popups.open("emoji", at.name, at.x, at.y, "below", {flipY: at.y});
        else
            Popups.openCentered("emoji", {}, "");
    }

    // The window a choice goes to: the one FocusReturn will give the keyboard back to when another full-attention surface holds
    // it already (a menu the panel replaces), else the active window; never the desktop.
    function currentTarget(): string {
        if (FocusReturn.anyOpen())
            return FocusReturn.previous ? Logic.addressHex(FocusReturn.previous.address) : "";
        if (DesktopState.holdsKeyboard)
            return "";
        const active = Compositor.activeWindow();
        return active ? Logic.addressHex(active.address) : "";
    }

    Process {
        id: cursorQuery
        command: ["hyprctl", "cursorpos", "-j"]
        stdout: StdioCollector {
            onStreamFinished: root.place(Logic.cursorPosition(text))
        }
    }

    // No answer from Hyprland in time: the panel opens all the same, centred.
    Timer {
        id: cursorLate
        interval: 500
        onTriggered: root.place(null)
    }

    // ---- Omarchy's list (ES-3, ES-4) ----

    function load(): void {
        root.wanted = true;
        if (root.state === "ready" || root.state === "loading")
            return;
        const again = root.state === "missing";
        root.state = "loading";
        if (again)
            dataFile.reload();
    }

    function takeData(text: string): void {
        const parsed = Logic.parse(text);
        root.list = parsed;
        root.groups = Logic.categories(parsed);
        root.state = parsed.length > 0 ? "ready" : "missing";
        if (parsed.length === 0)
            console.info("grassfield: Emoji & Symbols: no emoji list at", root.dataPath);
        else if (root.groups.length === 1 && root.groups[0].id === "all")
            console.info("grassfield: Emoji & Symbols: the list's groups are not where they were, one group shown (" + parsed.length + " emoji)");
    }

    FileView {
        id: dataFile
        path: root.wanted ? root.dataPath : ""
        printErrors: false
        onLoaded: root.takeData(dataFile.text())
        onLoadFailed: root.takeData("")
    }

    // ---- Recently Used (ES-8) ----

    function takeRecents(text: string): void {
        if (root.recentsRead)
            return;
        root.recentsRead = true;
        // A choice made before the file was read goes first (it is newer).
        let merged = Logic.parseRecents(text);
        const chosen = root.recents;
        for (let i = chosen.length - 1; i >= 0; i--)
            merged = Logic.addRecent(merged, chosen[i]);
        root.recents = merged;
        if (chosen.length > 0)
            root.saveRecents();
    }

    function saveRecents(): void {
        if (!root.recentsRead)
            return;
        if (recentsWriter.running) {
            root.recentsDirty = true;
            return;
        }
        recentsWriter.command = ["sh", Quickshell.shellPath("services/write-private.sh"), Mode.stateDir, root.recentsPath, Logic.serializeRecents(root.recents)];
        recentsWriter.running = true;
    }

    FileView {
        id: recentsFile
        path: root.recentsPath
        printErrors: false
        onLoaded: root.takeRecents(recentsFile.text())
        onLoadFailed: root.takeRecents("")
    }

    // 0600 in a 0700 directory, atomically (the state files' convention, write-private.sh); a second change while it writes is
    // written after it.
    Process {
        id: recentsWriter
        onRunningChanged: {
            if (!running && root.recentsDirty) {
                root.recentsDirty = false;
                root.saveRecents();
            }
        }
    }

    // ---- A choice (ES-7) ----

    // `emoji` chosen in the panel (a click, Return): it goes first in Recently Used, the panel closes, and the glyph is inserted
    // once the window the panel opened over is active again.
    function choose(emoji: string): void {
        if (!root.open || !Logic.isGlyph(emoji))
            return;
        root.recents = Logic.addRecent(root.recents, emoji);
        root.saveRecents();
        const target = root.targetClosed ? "" : root.target;
        Popups.close();
        if (target === "") {
            root.lastInsert = "no window";
            console.info("grassfield: emoji not inserted: no window was active when the panel opened");
            return;
        }
        root.pendingInsert = {
            emoji: emoji,
            target: target,
            closed: false
        };
        root.insertExpired = false;
        insertDeadline.restart();
        insertWatch.restart();
    }

    function cancelInsert(why: string): void {
        insertWatch.stop();
        insertDeadline.stop();
        if (root.pendingInsert !== null && why !== "") {
            root.lastInsert = why;
            console.info("grassfield: emoji not inserted:", why);
        }
        root.pendingInsert = null;
    }

    function insertTick(): void {
        const p = root.pendingInsert;
        if (p === null) {
            insertWatch.stop();
            return;
        }
        const active = Compositor.activeWindow();
        const step = Logic.insertStep({
            locked: SessionState.locked,
            rememberedAddress: p.target,
            activeAddress: active ? active.address : "",
            closedSinceOpen: p.closed,
            otherSurfaceOpen: FocusReturn.anyOpen(),
            expired: root.insertExpired
        });
        if (step === "wait")
            return;
        if (step !== "send") {
            root.cancelInsert(step);
            return;
        }
        root.pendingInsert = null;
        insertWatch.stop();
        insertDeadline.stop();
        if (inserter.running) {
            root.lastInsert = "busy";
            console.info("grassfield: emoji not inserted: the previous insertion is still running");
            return;
        }
        const command = Logic.insertCommand(p.emoji, root.insertPath, Quickshell.shellPath("services/emoji-insert.sh"));
        if (command.length === 0)
            return;
        inserter.command = command;
        inserter.running = true;
    }

    // Checks every INSERT_POLL_MS whether the window is active again (FocusReturn's request lands after the overlay let go).
    Timer {
        id: insertWatch
        interval: Logic.INSERT_POLL_MS
        repeat: true
        onTriggered: root.insertTick()
    }

    // INSERT_WAIT_MS after the choice: one last check drops it.
    Timer {
        id: insertDeadline
        interval: Logic.INSERT_WAIT_MS
        onTriggered: {
            root.insertExpired = true;
            root.insertTick();
        }
    }

    // emoji-insert.sh: Omarchy's command, else wtype, else nothing (it prints which; the glyph is an argument, never script text).
    Process {
        id: inserter
        stdout: StdioCollector {
            onStreamFinished: {
                const how = text.trim();
                root.lastInsert = how !== "" ? how : "sent";
                if (how === "missing")
                    console.warn("grassfield: emoji not inserted: neither omarchy-menu-emoji-insert nor wtype is installed");
                else
                    console.info("grassfield: emoji inserted through", how !== "" ? how : "an unknown command");
            }
        }
    }

    Connections {
        target: Compositor

        function onWindowClosed(address: string): void {
            if (address === root.target)
                root.targetClosed = true;
            const p = root.pendingInsert;
            if (p !== null && address === p.target)
                root.pendingInsert = Object.assign({}, p, {
                    closed: true
                });
        }
    }

    // The session locks: a panel being placed does not open, a glyph waiting for its window is dropped (Popups closes the panel).
    Connections {
        target: SessionState

        function onLockedChanged(): void {
            if (!SessionState.locked)
                return;
            root.placing = false;
            cursorLate.stop();
            root.cancelInsert("locked");
        }
    }

    // qs ipc call emoji <toggle|status>. toggle is Ctrl+Super+Space (bindings.lua); status is a test hook, refused outside a dev
    // session (it would tell another process what the user inserted).
    IpcHandler {
        target: "emoji"
        // A key binding calls it: it answers the key in-process (platform/shortcuts, CIO-01).
        Component.onCompleted: Shortcuts.attach(this)

        function toggle(): void {
            root.toggle();
        }

        function status(): string {
            if (!Mode.dev)
                return Mode.refused;
            return JSON.stringify({
                state: root.state,
                open: root.open,
                entries: root.list.length,
                groups: root.groups.map(g => g.id + ":" + (g.end - g.start)),
                recents: root.recents.length,
                target: root.target !== "",
                pending: root.pendingInsert !== null,
                last: root.lastInsert
            });
        }
    }
}
