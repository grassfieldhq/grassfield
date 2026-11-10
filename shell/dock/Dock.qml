pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import QtQuick.Effects
import Quickshell
import qs.lib
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.notifications
import qs.platform
import qs.services
import "DockModel.js" as DockModel
import "Launch.js" as Launch
import "../desktop/IconsLogic.js" as Icons // layering-exception: GF-087
import "AutoHide.js" as AutoHide
import "Attention.js" as Attention
import "Magnify.js" as Magnify
import "Geometry.js" as Geometry
import "Stacks.js" as Stacks
import "TileGraph.js" as TileGraph

// Bottom dock, one per screen: pinned apps (Settings) and running apps (foreign-toplevel app ids
// mapped to desktop entries), a separator and the Trash. Click launches, focuses the most recent
// window or cycles windows; right click opens the item menu. Magnification and autohide follow
// Settings (dock.magnification, dock.autohide) and Reduce Motion.
Scope {
    id: root

    // [{kind, key, name, icon, entry, windows, pinned}], rebuilt when apps/toplevels/pins change.
    property var items: []

    // The first tile is "Apps" (macOS 26: Launchpad became Apps and keeps its Dock tile). The shell root opens the panel.
    signal appsRequested
    // Tiles are a keyed list model updated by diffing (DockModel.diffKeys) so a delegate survives a rebuild and its animations
    // (glide, launch bounce and landing) keep running. A delegate reads its item from itemByKey by its key.
    property var itemByKey: ({})
    property var tileKeys: []
    ListModel {
        id: tileModel
    }

    function applyOps(ops: var): void {
        for (const o of ops) {
            if (o.op === "remove") {
                tileModel.remove(o.at);
                tileKeys.splice(o.at, 1);
            } else if (o.op === "insert") {
                tileModel.insert(o.at, {tileId: o.key});
                tileKeys.splice(o.at, 0, o.key);
            } else {
                tileModel.move(o.from, o.to, 1);
                tileKeys.splice(o.to, 0, tileKeys.splice(o.from, 1)[0]);
            }
        }
    }

    // Replaces the items: rows that went away are removed first (no delegate looks up a missing key), then the items are
    // published, then rows are inserted and moved.
    function setItems(next: var): void {
        const ops = DockModel.diffKeys(tileKeys, next.map(DockModel.tileKey));
        applyOps(ops.filter(o => o.op === "remove"));
        const map = {};
        next.forEach(it => {
            map[DockModel.tileKey(it)] = it;
        });
        itemByKey = map;
        items = next;
        applyOps(ops.filter(o => o.op !== "remove"));
    }
    // Resize by dragging the separator (macOS): the size while the drag runs (-1 when none). The Dock follows it live; the setting is
    // written once, when the button is released.
    property real liveSize: -1
    readonly property int sizeNow: liveSize >= 0 ? Math.round(liveSize) : Settings.dockSize

    // One Dock across displays (macOS: the Dock is on the display where the pointer last reached its edge, and moves there). Every
    // output keeps its Dock window, but only the one of `dockScreen` is shown and takes the exclusive zone; the others are, in
    // effect, an auto-hidden Dock that never shows on its own: the 2 px strip at the Dock's edge is their only input, and the
    // pointer resting on it for Tokens.dockRevealDwell makes that output the Dock's (`moveDockTo`). It starts on the focused output.
    property string chosenScreen: ""
    // The Dock starts on the main display (macOS: Displays > Use as > Main display holds the Dock, ADR-0044), and
    // moves there when the main display changes (a choice in Settings, the main display unplugged or plugged back); from then on
    // the pointer reaching another output's Dock edge moves it, as before.
    readonly property string startHint: MainDisplay.screenName

    Connections {
        target: MainDisplay

        function onScreenNameChanged(): void {
            const r = Geometry.afterMainChange(root.settled, root.chosenScreen, MainDisplay.screenName);
            root.chosenScreen = r.chosen;
            if (r.move !== "")
                root.moveDockTo(r.move);
        }
    }
    readonly property var screenNames: Quickshell.screens.map(s => s.name)
    readonly property string dockScreen: Geometry.dockScreen(chosenScreen, screenNames, Compositor.focusedScreenName, startHint)

    function moveDockTo(name: string): void {
        if (name === "" || name === dockScreen)
            return;
        if (VisualFixtures.active)
            console.info("dock-screen: move", dockScreen, "->", name, Date.now());
        chosenScreen = name;
    }

    // The output the Dock is on is also the one the minimize animation, Overview and the others look at.
    Binding {
        target: Compositor
        property: "dockScreenName"
        value: root.dockScreen
    }

    // Test hooks (IPC): a pointer position along the Dock (x at the bottom, y on a side edge, in the Dock window) forcing magnification, and a forced reveal.
    property real testPointerX: -1
    property bool testReveal: false
    // Keyboard navigation mode: the dock takes exclusive keyboard focus until Esc, an
    // activation, or pointer use; then the layer releases focus and the compositor restores the app.
    property bool keyboardMode: false
    // Output whose Dock has the keyboard (the Dock's output when the mode was entered).
    property string keyboardScreen: ""

    // Enter keyboard mode and focus the first tile.
    function enterKeyboardMode(): void {
        // The Dock never takes the keyboard over the lock screen (GF-116).
        if (SessionState.refuses("dock keyboard"))
            return;
        // Not on a Dock that is not revealed yet (invisible: it would take the keyboard for nothing).
        if (!windows.instances.some(w => w.screenName === root.dockScreen && w.reveal))
            return;
        keyboardScreen = dockScreen;
        keyboardMode = true;
        Qt.callLater(() => {
            const all = windows.instances;
            let bar = null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === root.keyboardScreen)
                    bar = all[i];
            }
            if (bar)
                bar.focusFirstTile();
        });
    }

    // Tiles launched from the Dock that have no window yet (they bounce): key -> start time (ms).
    property var launching: ({})

    // Time of the last launch click (ms); with the visual fixtures the bounce curve is logged against it (tests/visual/dock-launch.sh).
    property real launchClickedAt: 0

    // Attention (macOS: an app that needs attention bounces its icon until it is activated; Attention.js, pure): window addresses
    // that sent Hyprland's `urgent` event and have not been satisfied, the tiles they belong to, and the moment an auto-hidden
    // Dock comes out (a token duration after a new request).
    property var attention: ({})
    property real attentionAt: 0
    property bool attentionReveal: false
    readonly property var attentionKeys: Attention.tileKeys(attention, attentionGroups())
    // The apps' own launcher state (MenuBridge) with the count the shell sets itself: Software Update's releases on
    // Grassfield Settings (ADR-0033 U18; ADR-0018: an app's own count wins over its notifications').
    readonly property string settingsId: "org.grassfield.settings"
    readonly property var launcherState: DockModel.withCount(MenuBridge.launcher, settingsId, SoftwareUpdate.count)

    // One entry per app tile: its key and the addresses of its windows.
    function attentionGroups(): var {
        return items.filter(it => it.kind === "app" || it.kind === "files").map(it => ({key: it.key, addresses: it.windows.map(t => Compositor.addressOf(t))}));
    }

    function liveAddresses(): var {
        const tops = Compositor.toplevels ? Compositor.toplevels.values : [];
        return tops.map(t => Compositor.addressOf(t));
    }

    // An app is activated or a window went away: the bounce stops.
    function settleAttention(): void {
        if (Object.keys(attention).length === 0)
            return;
        const focusedAddress = Compositor.focusedToplevel ? Compositor.addressOf(Compositor.focusedToplevel) : "";
        const live = liveAddresses();
        const next = Attention.settle(attention, attentionGroups(), focusedAddress, live);
        if (next !== attention) {
            attention = next;
            // Nothing asks for attention any more: an auto-hidden Dock that was out for it goes back at once.
            if (Object.keys(next).length === 0) {
                attentionReveal = false;
                attentionRevealTimer.stop();
            }
            if (VisualFixtures.active)
                console.info("dock-attention: settled", Object.keys(next).length, Date.now());
        }
    }

    function requestAttention(address: string): void {
        const next = Attention.request(attention, address, Compositor.focusedToplevel ? Compositor.addressOf(Compositor.focusedToplevel) : "");
        if (VisualFixtures.active)
            console.info("dock-attention: urgent", address, next !== attention ? "bounce" : "ignored", Date.now());
        if (next === attention)
            return;
        attention = next;
        attentionAt = Date.now();
        attentionReveal = true;
        attentionRevealTimer.restart();
    }

    // An application set (or cleared) the urgent hint itself (LauncherEntry, ADR-0018): the same attention state, for the windows of its tile.
    function setAppAttention(app: string, urgent: bool): void {
        const focusedAddress = Compositor.focusedToplevel ? Compositor.addressOf(Compositor.focusedToplevel) : "";
        const next = urgent ? Attention.requestApp(attention, attentionGroups(), app, focusedAddress) : Attention.clearApp(attention, attentionGroups(), app);
        if (VisualFixtures.active)
            console.info("dock-attention: launcher", app, urgent ? (next !== attention ? "bounce" : "ignored") : "clear", Date.now());
        if (next === attention)
            return;
        attention = next;
        if (urgent) {
            attentionAt = Date.now();
            attentionReveal = true;
            attentionRevealTimer.restart();
        } else if (Object.keys(next).length === 0) {
            attentionReveal = false;
            attentionRevealTimer.stop();
        }
    }

    Connections {
        target: MenuBridge

        function onLauncherUpdate(msg: var): void {
            // urgent true/false sets/clears it; a line with nothing in it (the app's process left the bus) clears it.
            if (msg.urgent === true)
                root.setAppAttention(msg.app, true);
            else if (msg.urgent === false || (msg.count === null && msg.progress === null))
                root.setAppAttention(msg.app, false);
        }
    }

    Timer {
        id: attentionRevealTimer
        interval: Tokens.dockAttentionReveal
        onTriggered: root.attentionReveal = false
    }

    // Keys of the listed apps that had a window at the previous rebuild (null: no rebuild yet).
    property var previousRunning: null

    // Persists the recent apps list only when it differs from the stored one.
    function writeRecents(list: var): void {
        const current = Settings.dockRecent;
        if (list.length !== current.length || list.some((k, i) => k !== current[i]))
            Settings.setDockRecent(list);
    }

    // A tile is being dragged on some screen: the tiles are not rebuilt until the release (a rebuild destroys the dragged
    // delegate and its drag handler, and the drop would never be finished). The latest state is applied right after.
    property bool rebuildPending: false

    function dragInProgress(): bool {
        return windows.instances.some(w => w.dragFrom >= 0);
    }

    function rebuild(): void {
        if (dragInProgress()) {
            rebuildPending = true;
            return;
        }
        rebuildPending = false;
        const running = [];
        const tops = Compositor.toplevels ? Compositor.toplevels.values : [];
        for (let i = 0; i < tops.length; i++)
            running.push({appId: tops[i].appId, ref: tops[i]});
        // Files is the fixed first tile: out of the pinned list and the recents, its windows ride on the fixed tile.
        const split = DockModel.splitFiles(DockModel.merge(DockModel.withoutFiles(Settings.dockPinned), running, Apps.lookup), Apps.lookup);
        const apps = split.rest;
        // Apps that were running and quit while not kept in the Dock become "recent" (DockModel.recentsAfter: a pure
        // function of the previous and current running sets, written only when the list really changes).
        const runningKeys = apps.filter(a => a.windows.length > 0 && a.entry && Apps.isListed(a.entry)).map(a => a.key);
        // Not before the desktop entries and the hidden-entry list are loaded (DockModel.recentsStep).
        const ready = Apps.hiddenReady && DesktopEntries.applications.values.length > 0;
        const pinnedKeys = apps.filter(a => a.pinned).map(a => a.key);
        const step = DockModel.recentsStep(ready, Settings.dockRecent, previousRunning, runningKeys, pinnedKeys, Tokens.dockRecentMax);
        previousRunning = step.previous;
        if (ready && Settings.dockShowRecents)
            writeRecents(step.recent);
        const shown = ready && Settings.dockShowRecents ? DockModel.withRecents(apps, Settings.dockRecent, Apps.lookup, Tokens.dockRecentMax, e => Apps.isListed(e) && !DockModel.isFilesId(e.id)) : apps;
        const tail = Settings.dockMinimizeIntoApp ? [] : DockModel.minimizedItems(Compositor.minimized.filter(r => !r.intoApp), Apps.lookup);
        const all = windows.instances;
        all.forEach(w => w.captureLayout());
        const folders = DockModel.folderItems(Stacks.folderList(Settings.dockFolders, Quickshell.env("HOME"), Tokens.dockStackMax));
        setItems(DockModel.withFixed(split.files, DockModel.withTail(shown, tail, folders)));
        all.forEach(w => w.playLayout());
        pruneLaunching();
        settleAttention();
    }

    function pruneLaunching(): void {
        const keys = Object.keys(launching);
        if (keys.length === 0)
            return;
        const kept = DockModel.bounceKeys(launching, items, Date.now(), Tokens.dockLaunchTimeout);
        if (Object.keys(kept).length !== keys.length)
            launching = kept;
    }

    // Starts an app tile: the launch bounce runs until a window appears (or the timeout), and an app that is not kept
    // in the Dock is remembered as a recent application.
    function launchItem(item: var): void {
        if (!item.entry) {
            // Files without its desktop entry (not installed): its home folder through the open policy.
            if (item.kind === "files")
                Apps.openDetached(["gio", "open", Quickshell.env("HOME")]);
            return;
        }
        // A second click while the tile bounces does nothing (no double launch).
        const click = Launch.click(launching, item.key, Date.now(), Tokens.dockLaunchTimeout);
        if (!click.start)
            return;
        launchClickedAt = Date.now();
        Apps.launch(item.entry);
        launching = click.launching;
        launchTimer.restart();
        if (!item.pinned && Settings.dockShowRecents && Apps.isListed(item.entry))
            writeRecents(DockModel.pushRecent(Settings.dockRecent, item.key, Tokens.dockRecentMax));
    }

    // Removes a tile from the Dock (drag out): unpins it and forgets it as a recent app. A running app is removable too
    // (macOS): it is no longer kept, its tile stays with its running dot until it quits. True when the Dock changed (the pin or
    // the recent entry went); the caller plays the puff only when the tile is gone, that is when it has no window.
    function removeItem(item: var): bool {
        if (item.kind !== "app")
            return false;
        if (item.pinned)
            Settings.setDockPinned(DockModel.unpinKey(Settings.dockPinned, item.key, Apps.lookup));
        if (item.recent)
            Settings.setDockRecent(Settings.dockRecent.filter(r => !DockModel.sameApp(r, item.key, Apps.lookup)));
        return item.pinned === true || item.recent === true;
    }

    Timer {
        id: launchTimer
        interval: Tokens.dockLaunchTimeout
        onTriggered: root.pruneLaunching()
    }

    // `pointer`: a click (the only activation that minimizes, dock.clickMinimizes); keys and accessibility presses bring forward.
    function activateItem(item: var, pointer: var): void {
        keyboardMode = false;
        // Fixtures only (dock noactivate): a click is logged ("dock-launch: tapped") but nothing starts, opens or comes forward.
        if (VisualFixtures.active && root.testNoActivate)
            return;
        if (item.kind === "apps") {
            root.appsRequested();
            return;
        }
        if (item.kind === "trash") {
            Trash.open();
            Trash.refresh();
            return;
        }
        // The app's CPU and I/O limits (ADR-0048) are lifted before its windows come forward.
        if (item.kind === "minimized")
            AppEnergy.wakeToplevels([item.toplevel]);
        else if (item.kind !== "folder" && Array.isArray(item.windows) && item.windows.length > 0)
            AppEnergy.wakeToplevels(item.windows);
        if (item.kind === "minimized") {
            Compositor.unminimizeWithGroup(item.toplevel); // its tile group comes forward with it (TL29)
            return;
        }
        if (item.kind === "folder") {
            root.openStackOf(item);
            return;
        }
        if (item.windows.length === 0) {
            root.launchItem(item);
            return;
        }
        root.clickRunning(item.windows, pointer === true);
    }

    // A click on a running app's tile. With dock.clickMinimizes the frontmost app's visible windows minimize (each into its own
    // tile or the app icon, Compositor.minimize) and an all-minimized app comes back whole; otherwise bringForward (macOS).
    function clickRunning(windows: var, pointer: bool): void {
        const plan = Launch.clickPlan(windows.map(t => Compositor.windowInfo(t)), pointer && Settings.dockClickMinimizes);
        if (plan.action === "minimize") {
            let done = 0;
            for (const top of plan.refs) {
                if (Compositor.minimizeIntoAppIcon(top))
                    done++;
            }
            if (done === 0)
                root.bringForward(windows); // every minimize was refused: a click never does nothing
        } else if (plan.action === "restore") {
            for (const top of plan.refs)
                Compositor.activate(top);
            Compositor.groupForward(Compositor.addressOf(plan.refs[plan.refs.length - 1]));
        } else {
            root.bringForward(windows);
        }
    }

    // macOS: every window of the app comes forward, the most recent one ends focused; with everything minimized, the most
    // recent one is restored (Launch.activationPlan). A click on the focused app does not cycle its windows. The tile group
    // of the window that ends focused comes forward with it (TL29).
    function bringForward(windows: var): void {
        const plan = Launch.activationPlan(windows.map(t => Compositor.windowInfo(t)));
        for (const top of plan)
            Compositor.activate(top);
        if (plan.length > 0)
            Compositor.groupForward(Compositor.addressOf(plan[plan.length - 1]));
    }

    // The newest items of every folder shown as a stack (StackWatch: one watcher per folder for the whole Dock, not one per
    // output), by folder path, for the pile on its tile.
    property var pileItems: ({})

    function setPile(path: string, newest: var): void {
        const next = Object.assign({}, pileItems);
        next[path] = newest;
        pileItems = next;
    }

    Instantiator {
        model: root.items.filter(it => it.kind === "folder" && Stacks.optionsFor(Settings.dockStackOptions, it.path).display === "stack").map(it => it.path)

        delegate: StackWatch {
            id: watch

            required property string modelData

            folder: modelData
            sort: Stacks.optionsFor(Settings.dockStackOptions, modelData).sort
            onNewestChanged: root.setPile(modelData, newest)
        }
    }

    // Opens the stack of a folder tile on the Dock's output (macOS: a click on Downloads).
    function openStackOf(item: var): void {
        const all = windows.instances;
        const index = items.indexOf(item);
        let target = null;
        for (let i = 0; i < all.length; i++) {
            if (all[i].screen.name === dockScreen)
                target = all[i];
        }
        if (!target && all.length > 0)
            target = all[0];
        if (target && index >= 0)
            target.openStack(index);
    }

    Component.onCompleted: {
        // The entrance waits for the Dock's first layout (ADR-0040 step 6).
        Entrance.expect("dock");
        rebuild();
        latchStartScreen();
        if (inputsFinal)
            settle();
    }

    // Startup (Geometry.settledOn): the Dock windows stay unmapped until the settings, the apps model and the Dock's output
    // are final, so the Dock is drawn once, at its place, and no layout animation plays for the first fill. Latched: it never
    // goes back (a later change of position or size is the user's and animates as before).
    property bool settled: false
    readonly property bool inputsFinal: Geometry.settledOn({
        settings: Settings.loaded && MainDisplay.ready,
        apps: Apps.hiddenReady,
        screens: screenNames,
        start: Geometry.startScreen(screenNames, Compositor.focusedScreenName, startHint),
        waited: waited
    })
    // The fallback timer ran out: the Dock no longer waits for the apps model or the focused output (the settings file it always does).
    property bool waited: false
    onInputsFinalChanged: {
        if (inputsFinal)
            settle();
    }

    function settle(): void {
        if (settled)
            return;
        settleTimer.stop();
        try {
            // The fallback (no focused output ever reported): the Dock stays on the output it is on, whatever focus does later.
            chosenScreen = Geometry.settleScreen(chosenScreen, screenNames, Compositor.focusedScreenName, startHint);
            rebuild();
        } catch (e) {
            console.warn("grassfield-shell: Dock first layout failed:", e);
        } finally {
            // Whatever happened, the Dock appears. Every window starts from the state it will rest in (hidden when it hides,
            // shown otherwise): a machine that began shown would slide out in front of the user.
            windows.instances.forEach(w => w.resetHide());
            settled = true;
            // No window shows the Dock (no output has it): nothing to wait for.
            if (!windows.instances.some(w => w.isDockScreen))
                Entrance.ready("dock");
        }
    }

    // Nothing waited for ever: a compositor without focus events, an account without desktop entries.
    Timer {
        id: settleTimer
        interval: Tokens.dockSettleTimeout
        running: !root.settled
        onTriggered: root.waited = true
    }

    // The Dock starts on the focused output and stays where it is until the pointer moves it (focus changes do not).
    function latchStartScreen(): void {
        chosenScreen = Geometry.latchScreenWhen(Settings.loaded && MainDisplay.ready, chosenScreen, screenNames, Compositor.focusedScreenName, startHint);
    }

    // Drag-out removal follows "cancel on interruption": anything that can take the pointer or the focus during a tile drag marks the
    // drag interrupted (win.dragInterrupted), and an interrupted drag never removes its tile (it glides back). Events only. The
    // Dock's own drag feedback (Remove label, puff, tooltip) is inside its window and reports none of these.
    // Counts every interruption event, drag or not: a press records it when the button goes down, and a drag that would start later in the
    // same press is refused (drag-refused) when the count changed since.
    property int dragInterruptions: 0

    function interruptDrag(): void {
        dragInterruptions++;
        const all = windows.instances;
        for (let i = 0; i < all.length; i++) {
            if (all[i].dragFrom >= 0)
                all[i].dragInterrupted = true;
        }
    }

    // CLICK CANCELLATION, its own short list (not the drag-out list above: that one over-cancels on purpose, owner batch 7, and a window
    // retitling every few milliseconds must not eat Dock clicks). A press on a tile is taken away from the Dock, and its release never
    // clicks, only when:
    //   1. a shell surface opens over the Dock (Search, Overview, Apps, the switcher, a Dock or menu-bar menu, Notification Center,
    //      Control Center): FocusReturn.surfaceOpened, and Popups.kind switching to a popup;
    //   2. the session locks (FocusReturn.lockedChanged);
    //   3. Qt cancels the grab or the pointer leaves the tile's handler (TapHandler.canceled / a cancelled grab, in the delegate).
    // Window titles, focus changes and windows closing are NOT in the list (a window OPENING ends a held press in Qt, see lastWindowEvent).
    // A tile records clickCancels when its button goes down and refuses its tap when the value changed.
    property int clickCancels: 0

    // Time (ms) of the last window OPENING (an insertion into the window list; a closing never ends a press). Qt ends a held press with a synthesized release, and a
    // tap, when a window opens (nested probe: pressed, toplevels-changed, 35 ms later tap + release with grab state 8, no hover or cancel
    // event, nothing that tells it from a real release). A press that began before such an event and whose tap comes within
    // Tokens.dockClickWindowGuard of it is refused: it was not finished by the user. A real click that coincides with a window opening
    // within that time is lost and costs one repeated click.
    property real lastWindowEvent: 0

    // Fixtures only (IPC dock forcehold): every press on an app tile counts as having opened the hold menu at once (no popup), so a test
    // gets "menu first, then the drag of the same press" deterministically instead of racing a hook against the 550 ms timer.
    property bool forceHoldMenu: false

    // Fixtures only (IPC dock forceinterrupt): every press on an app tile is interrupted (one interruption event, no popup, no menu) the
    // moment it goes down, so a test reaches "interrupted before the drag starts" without racing a real surface against the drag.
    property bool forceInterrupt: false
    // Fixtures only: activateItem does nothing (the nested click test must not start apps or open stacks).
    property bool testNoActivate: false

    function cancelClicks(): void {
        clickCancels++;
        if (VisualFixtures.active)
            console.info("dock-launch: click-cancel", Date.now());
    }

    onKeyboardModeChanged: interruptDrag()

    // A shell full-attention surface opened (Search, Apps, switcher, popup host, Notification Center, widget menu, Overview).
    Connections {
        target: FocusReturn

        function onSurfaceOpened(name: string): void {
            root.interruptDrag();
            root.cancelClicks();
        }

        function onSurfaceClosed(name: string): void {
            root.interruptDrag();
        }

        // The session lock.
        function onLockedChanged(): void {
            root.interruptDrag();
            root.cancelClicks();
        }
    }

    // The session locks: keyboard mode ends (GF-116).
    Connections {
        target: SessionState

        function onLockedChanged(): void {
            if (SessionState.locked)
                root.keyboardMode = false;
        }
    }

    // Any shell popup (Dock menu, menu-bar menus, Control Center, ...) opening, switching or closing.
    Connections {
        target: Popups

        function onKindChanged(): void {
            root.interruptDrag();
            if (Popups.kind !== "")
                root.cancelClicks();
        }
    }

    // Windows, workspaces, monitors and layers of the session (Hyprland events, relayed by the platform layer).
    Connections {
        target: Compositor

        function onInterrupted(event: string): void {
            root.interruptDrag();
        }

        function onFocusedToplevelChanged(): void {
            root.interruptDrag();
            root.settleAttention();
        }

        function onAttention(address: string): void {
            root.requestAttention(address);
        }

        function onFocusedScreenNameChanged(): void {
            root.interruptDrag();
            root.latchStartScreen();
        }
    }

    Connections {
        target: Quickshell

        function onScreensChanged(): void {
            root.interruptDrag();
        }
    }

    Connections {
        target: Compositor.toplevels

        function onValuesChanged(): void {
            root.interruptDrag();
            root.rebuild();
        }

        // Only a window OPENING makes Qt end a held press (nested probe); a window closing never did (3 of 3 clicks tapped).
        function onObjectInsertedPost(object: var, index: int): void {
            root.lastWindowEvent = Date.now();
            if (VisualFixtures.active)
                console.info("dock-launch: toplevel-inserted", Date.now());
        }
    }

    Connections {
        target: Compositor

        function onMinimizedChanged(): void {
            root.rebuild();
        }
    }

    Connections {
        target: Apps

        // The hidden-entry list has (re)loaded.
        function onListChanged(): void {
            root.rebuild();
        }
    }

    Connections {
        target: DesktopEntries

        function onApplicationsChanged(): void {
            root.rebuild();
        }
    }

    Connections {
        target: Settings

        function onDockPinnedChanged(): void {
            root.rebuild();
        }

        function onDockRecentChanged(): void {
            root.rebuild();
        }

        function onDockFoldersChanged(): void {
            root.rebuild();
        }

        function onDockShowRecentsChanged(): void {
            root.rebuild();
        }

        function onDockMinimizeIntoAppChanged(): void {
            root.rebuild();
        }
    }

    // Test hooks: qs ipc call dock <hover|unhover|reveal|autohide|magnify|click|keyboard|menu|pinned|tiles|centre|popup|holdmenu|forcehold|forceinterrupt>. autohide, magnify, click
    // and pinned (read-only) act only with the visual fixtures (dev, --visual-fixtures); elsewhere they are inert. `reopen`
    // is no test hook: apps call it.
    IpcHandler {
        target: "dock"

        // A running app launched again asks for its windows (macOS: launching a running app brings it forward, a minimized
        // window back): what a click on its tile does (bringForward). Called by the app itself, `qs ipc -p <shell> call dock
        // reopen <desktop id>` (apps/runmode.h shellIpcArgs), when its window is not on screen; xdg-activation alone
        // switches to another Desktop but leaves a window on special:minimized (ADR-0038 AD34; Activity Monitor). An app
        // the Dock has no window for is left alone; nothing while the session is locked.
        function reopen(appId: string): void {
            if (SessionState.refuses("dock reopen"))
                return;
            const windows = DockModel.windowsOf(root.items, appId);
            if (windows.length > 0)
                root.bringForward(windows);
        }

        // The kept apps (JSON list) from the live settings: the drag stress test asserts it never changes.
        function pinned(): string {
            if (!VisualFixtures.active)
                return "[]";
            return JSON.stringify(Settings.dockPinned);
        }

        function noactivate(on: bool): void {
            if (VisualFixtures.active)
                root.testNoActivate = on;
        }

        function forceinterrupt(on: bool): void {
            if (VisualFixtures.active)
                root.forceInterrupt = on;
        }

        // Fixtures only: while on, every press on an app tile is marked as having opened the hold menu at the moment it goes down.
        function forcehold(on: bool): void {
            if (VisualFixtures.active)
                root.forceHoldMenu = on;
        }

        // The press held on tile `index` becomes a hold menu without a popup (fixtures only): the press is marked as having opened the menu
        // and the interruption a popup opening causes is recorded, in this order, before any drag of the press starts. A real hold menu
        // takes the pointer and usually ends the press; only a stalled GUI thread lets the drag of the same press follow (reviewer: menu
        // +6569 ms, drag +27 ms later), and that order cannot be forced from outside, so the hook forces the state it leaves behind.
        function holdmenu(index: int, screen: string): void {
            if (!VisualFixtures.active)
                return;
            const all = windows.instances;
            let win = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    win = all[i];
            }
            if (win)
                win.markHoldMenu(index);
        }

        // Kind of the open shell popup ("" when none; fixtures only): tests close menus before a part.
        function popup(): string {
            return VisualFixtures.active ? Popups.kind : "";
        }

        // Keys of the tiles in order (JSON list), the index `click` takes (fixtures only).
        function tiles(): string {
            if (!VisualFixtures.active)
                return "[]";
            return JSON.stringify(root.items.map(i => i.key !== undefined ? i.key : i.kind));
        }

        // hover, unhover, reveal and menu: dev session only (VisualFixtures.dev, SEC-04).
        function hover(x: real): void {
            if (VisualFixtures.dev)
                root.testPointerX = x;
        }

        function unhover(): void {
            if (VisualFixtures.dev)
                root.testPointerX = -1;
        }

        // Auto-hide machine state and visible fraction "state visible" (fixtures only).
        function hidestate(screen: string): string {
            if (!VisualFixtures.active)
                return "";
            const all = windows.instances;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    return all[i].hideMachine.state + " " + all[i].hideMachine.visible.toFixed(3);
            }
            return "";
        }

        // The tile drag state of `screen` as JSON (fixtures only; no tile names): {dragging, from, slot, out, removable,
        // interrupted}. `out` is the drag past the removal distance (the "Remove" label shows when `out && removable`).
        // tests/visual/contrast.sh reads it instead of looking for the label's pixels (GF-061).
        function dragstate(screen: string): string {
            if (!VisualFixtures.active)
                return "";
            const all = windows.instances;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    return JSON.stringify({dragging: all[i].dragFrom >= 0, from: all[i].dragFrom, slot: all[i].dragSlot, out: all[i].dragOut,
                        removable: all[i].dragRemovable, interrupted: all[i].dragInterrupted});
            }
            return "";
        }

        function reveal(on: bool): void {
            if (VisualFixtures.dev)
                root.testReveal = on;
        }

        // Output that has the Dock (fixtures only).
        function screen(): string {
            return VisualFixtures.active ? root.dockScreen : "";
        }

        // Where the next minimized window of `screen` would go: the rectangle Compositor.dockRect hands the plugin (global layout
        // coordinates, JSON; fixtures only).
        function targetrect(screen: string): string {
            return VisualFixtures.active ? JSON.stringify(Compositor.dockRect(screen, Compositor.minimized.length, true, null)) : "";
        }

        // Option-Command-D (macOS): turns Dock hiding on or off. The integrator binds a key to it (config/hypr); not fixtures-gated.
        function toggleAutohide(): void {
            Settings.setDockAutohide(!Settings.dockAutohide);
        }

        function autohide(on: bool): void {
            if (!VisualFixtures.active)
                return;
            Settings.setDockAutohide(on);
        }

        // Tile size and screen edge through the settings (fixtures only), like autohide and magnify.
        function size(px: int): void {
            if (VisualFixtures.active)
                Settings.setDockSize(px);
        }

        function position(edge: string): void {
            if (VisualFixtures.active)
                Settings.setDockPosition(edge);
        }

        // Tile size now, "liveSize" included (fixtures only).
        function sizenow(): string {
            return VisualFixtures.active ? String(root.sizeNow) : "";
        }

        function magnify(factor: real, enabled: bool): void {
            if (!VisualFixtures.active)
                return;
            Settings.setDockMagnification(factor, enabled);
        }

        // Same code path as a click on item `index`.
        function click(index: int): void {
            if (VisualFixtures.active && root.items[index])
                root.activateItem(root.items[index], true);
        }

        // Centre "x y" of tile `index` on `screen` in output coordinates (fixtures only; the magnification must be off).
        function centre(index: int, screen: string): string {
            if (!VisualFixtures.active)
                return "";
            const all = windows.instances;
            let win = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    win = all[i];
            }
            return win ? win.tileCentre(index) : "";
        }

        // "x y w h" of the drawn icon of tile `index` on `screen`, output coordinates (fixtures only).
        function iconrect(index: int, screen: string): string {
            if (!VisualFixtures.active)
                return "";
            const all = windows.instances;
            let win = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    win = all[i];
            }
            return win ? win.tileIconRect(index) : "";
        }

        function keyboard(): void {
            root.enterKeyboardMode();
        }

        // Tile size on `screen` after shrink to fit (Geometry.fitSize), px; compare with `sizenow` (fixtures only).
        function fitsize(screen: string): string {
            if (!VisualFixtures.active)
                return "";
            const all = windows.instances;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    return String(all[i].iconSize);
            }
            return "";
        }

        // Adds `path` to the Dock's folders at slot `slot` as a drop would (fixtures only; real drags: tests/visual/dock-drops.sh style).
        function addfolder(path: string, slot: int): void {
            if (VisualFixtures.active)
                Settings.setDockFolders(Stacks.insertFolders(Settings.dockFolders, [path], slot, Quickshell.env("HOME"), Tokens.dockStackMax));
        }

        // Opens the stack of tile `index` (a folder) on `screen` (same code path as a click; fixtures only).
        function stack(index: int, screen: string): void {
            if (!VisualFixtures.active)
                return;
            const all = windows.instances;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    all[i].openStack(index);
            }
        }

        function menu(index: int, screen: string): void {
            if (!VisualFixtures.dev)
                return;
            const all = windows.instances;
            let win = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    win = all[i];
            }
            if (win)
                win.openMenu(index);
        }
    }

    Variants {
        id: windows

        model: Quickshell.screens

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData

            // Gate P5: the first frame of this Dock counts toward "grassfield-shell: usable" (platform/Usable.qml).
            UsableProbe {
                kind: "dock"
                screenName: win.modelData ? win.modelData.name : ""
                active: win.reveal
            }

            // Tile size (Settings > Size) shrunk to fit the screen along the Dock (Geometry.fitSize, macOS): everything below follows
            // it (Geometry.metrics). The setting itself is never changed.
            readonly property int iconSize: Geometry.fitSizeMagnified(root.sizeNow, root.items.map(it => it.kind === "separator"), mainTotal - 2 * Tokens.dockFitMargin, Tokens.dockFitMin, {
                    separatorWidth: separatorWidth,
                    spacing: Tokens.dockSpacing,
                    padding: Tokens.dockPadding,
                    maxScale: maxScale,
                    radius: Tokens.dockMagnificationRadius,
                    slack: Tokens.dockFitSlack
                })
            // The window is as deep as the largest Dock needs, whatever the size now: resizing never reconfigures the layer surface
            // (the pointer's coordinates in it stay put while the separator is dragged). It is transparent and takes input only where the mask says.
            readonly property var largest: Geometry.metrics(Tokens.dockSizeMax, {
                iconSize: Tokens.dockIconSize,
                padding: Tokens.dockPadding,
                indicatorSize: Tokens.dockIndicatorSize,
                spacing: Tokens.dockSpacing,
                bottomMargin: Tokens.dockBottomMargin,
                separatorHeight: Tokens.dockSeparatorHeight,
                badgeSize: Tokens.dockBadgeSize,
                radiusIcon: Tokens.radiusDockIcon
            })
            // The separator is being dragged (resize).
            property bool resizing: false
            readonly property int separatorWidth: Tokens.dockSeparatorSpace
            readonly property real maxScale: Settings.dockMagnificationEnabled ? Settings.dockMagnification : 1
            readonly property real pitch: iconSize + Tokens.dockSpacing
            readonly property var dockMetrics: Geometry.metrics(iconSize, {
                iconSize: Tokens.dockIconSize,
                padding: Tokens.dockPadding,
                indicatorSize: Tokens.dockIndicatorSize,
                spacing: Tokens.dockSpacing,
                bottomMargin: Tokens.dockBottomMargin,
                separatorHeight: Tokens.dockSeparatorHeight,
                badgeSize: Tokens.dockBadgeSize,
                radiusIcon: Tokens.radiusDockIcon
            })
            readonly property int indicatorArea: Tokens.dockIndicatorArea
            readonly property int shelfHeight: DockModel.shelfHeight(dockMetrics)
            readonly property real overhang: Math.ceil((maxScale - 1) * iconSize)
            readonly property int tooltipArea: Tokens.dockTooltipArea
            // Position on screen (Settings > Position on screen): the window is anchored to this edge. "main" is the direction along
            // the Dock, "cross" the one away from the screen edge (Geometry.js: one formula for the three edges).
            readonly property string edge: Settings.dockPosition
            readonly property bool vertical: Geometry.isVertical(edge)
            readonly property var outDir: Geometry.outward(edge)
            // Extent of the window along the Dock (the screen's width or height) and of a tile across it.
            readonly property real mainTotal: Geometry.mainSize(edge, width, height)
            readonly property real tileCross: iconSize + indicatorArea
            // Room kept beside the shelf for a label (above a bottom Dock, beside a side one) and for a dragged icon.
            readonly property real tipRoom: vertical ? Tokens.dockTooltipSideArea : tooltipArea
            readonly property real roomPx: Geometry.room(edge, tooltipArea, Tokens.dockTooltipSideArea, Tokens.dockDragArea)
            // Top-left of this window in screen coordinates (the input of the pointer tracker and of the test hooks).
            readonly property var origin: Geometry.windowOrigin(edge, screen.width, screen.height, width, height)
            // Drag to reorder or remove: the dragged tile (index in items, -1 none), its offset from the press, the slot
            // it would take, and whether releasing it now removes it from the Dock.
            property int dragFrom: -1
            property real dragDx: 0
            property real dragDy: 0
            onDragFromChanged: if (dragFrom < 0 && root.rebuildPending)
                root.rebuild()
            // Item indices of the app tiles; the drag slots and the reorder work on positions in this list (the recent
            // applications divider sits between app tiles).
            readonly property var appItems: DockModel.appIndices(root.items)
            readonly property int dragFromApp: dragFrom < 0 ? -1 : appItems.indexOf(dragFrom)
            readonly property int dragSlot: dragFrom < 0 ? -1 : DockModel.dropSlot(baseCenters, appItems, baseCenters[dragFrom] + Geometry.dragMain(edge, dragDx, dragDy))
            // How far away from the screen edge (above a bottom Dock) its press point a tile must be to leave the Dock (outside the
            // drop zone: the shelf and the room around it).
            readonly property real dragOutReach: Tokens.dockPadding + iconSize / 2 + Tokens.dockDragOutDistance
            readonly property bool dragOut: dragFrom >= 0 && Geometry.dragOutward(edge, dragDx, dragDy) > dragOutReach
            // Set ONLY by the drag handler when the pointer button is really released (exclusive grab ended by a release event)
            // away from the drop zone. Every other end of a drag (cancelled or stolen grab) leaves it false.
            property bool releasedOutside: false
            // Set by root.interruptDrag() and by a cancelled or stolen grab, cleared when a drag ends: something took the pointer or the
            // focus during the drag (a shell surface, a popup, the lock, a window, workspace or monitor event, Esc in keyboard mode). Qt
            // then ends the drag with a synthesized release that looks real, so an interrupted drag changes no pins (no removal, no
            // reorder): the tile glides back. A press that was already interrupted when the drag would start does not start it at all.
            property bool dragInterrupted: false
            readonly property bool dragRemovable: dragFrom >= 0 && DockModel.removable(root.items[dragFrom])
            property real poofX: 0
            property real poofY: 0
            property real poofProgress: 1

            // A tile is removed only when ALL hold: releasedOutside was set by a positive release event outside the Dock's drop zone,
            // the live drag offset agrees, the item can be removed and the drag was not interrupted. A release inside the shelf never
            // removes (macOS).
            function finishDrag(tileItem: Item): void {
                const from = dragFrom;
                const all = root.items;
                const item = all[from];
                const out = releasedOutside && !dragInterrupted && dragOut && dragRemovable;
                const dragOutNotReleased = !out && dragOut && dragRemovable;
                const interrupted = dragInterrupted;
                const slot = dragSlot;
                const fromApp = dragFromApp;
                releasedOutside = false;
                dragInterrupted = false;
                // mapToItem already includes the tile's drag translation (its Translate transform): adding dragDx/dragDy put the puff off the window.
                const centre = tileItem.mapToItem(area, tileItem.iconPos.x + tileItem.iconPx / 2, tileItem.iconPos.y + tileItem.iconPx / 2);
                const cx = centre.x;
                const cy = centre.y;
                const dx = dragDx;
                const dy = dragDy;
                // The tiles keep their dragged / displaced places until the rebuild: it animates from there.
                layoutBefore = tileXs();
                dragSnap = true;
                collapseAnim.stop();
                dragCollapse = 0;
                dragFrom = -1;
                dragDx = 0;
                dragDy = 0;
                if (!item)
                    return;
                if (out) {
                    // The rebuild that follows the unpin keeps the layout of the release (as for a tile that goes away).
                    holdLayout = true;
                    holdTimer.restart();
                    const removed = root.removeItem(item);
                    if (removed && item.windows.length === 0) {
                        win.poof(cx, cy);
                        Sounds.play("dock-remove");
                    } else {
                        // A running app (macOS): no puff, the icon slides back into the Dock, now not kept. The rebuild already
                        // glides it along the Dock; only the cross-axis offset of the drop is added.
                        tileItem.glideFrom(win.vertical ? dx : tileItem.glide, win.vertical ? tileItem.glideY : dy);
                    }
                    return;
                }
                if (dragOutNotReleased || interrupted) {
                    // Dragged out but not released out there, or interrupted by anything: no pin changes (no removal, no reorder), the
                    // tile glides back to its slot.
                    tileItem.glideFrom(dx, dy);
                    return;
                }
                const r = DockModel.reorder(all, fromApp, slot);
                if (r.changed) {
                    holdLayout = true;
                    holdTimer.restart();
                    Settings.setDockPinned(r.pinned);
                } else {
                    tileItem.glideFrom(dx, dy);
                }
            }

            Timer {
                id: holdTimer
                interval: Tokens.motionNormal
                onTriggered: win.holdLayout = false
            }

            // A tile dragged out of the Dock (it would be removed) closes its gap in the shelf, and reopens when dragged back.
            property real dragCollapse: 0
            property bool dragSnap: false
            readonly property bool dragCollapsing: dragFrom >= 0 && dragOut && dragRemovable
            onDragCollapsingChanged: {
                if (dragFrom < 0)
                    return;
                collapseAnim.stop();
                collapseAnim.to = dragCollapsing ? 1 : 0;
                collapseAnim.start();
            }

            // Sizes and places that change in place: the move curve (ADR-0039 step 25, the roles of step 20).
            NumberAnimation {
                id: collapseAnim
                target: win
                property: "dragCollapse"
                duration: Appearance.duration(Tokens.motionFast)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }

            // A folder dragged over the shelf (macOS: dropped in the right section it becomes a stack): the slot it would take
            // among the folder tiles (-1 none), and the gap that opens there (0..1, animated).
            property int folderDropIndex: -1
            property int folderDropLast: 0
            property real gapGrow: 0
            readonly property int separatorAt: root.items.findIndex(it => it.kind === "separator" && !it.divider)
            readonly property int folderCount: root.items.filter(it => it.kind === "folder").length
            onFolderDropIndexChanged: {
                if (folderDropIndex >= 0)
                    folderDropLast = folderDropIndex;
                gapAnim.stop();
                gapAnim.to = folderDropIndex >= 0 ? 1 : 0;
                gapAnim.start();
            }

            NumberAnimation {
                id: gapAnim
                target: win
                property: "gapGrow"
                duration: Appearance.duration(Tokens.motionFast)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }

            // Layout transition (DockModel.layoutTransition): position along the Dock of every tile (window coordinates) before a rebuild.
            property var layoutBefore: ({})

            function tileXs(): var {
                const out = {};
                for (let i = 0; i < tileRepeater.count; i++) {
                    const t = tileRepeater.itemAt(i) as Item;
                    if (t) {
                        const at = t.mapToItem(area, 0, 0);
                        out[t.tileId] = win.vertical ? at.y : at.x;
                    }
                }
                return out;
            }

            // Set by finishDrag: the positions captured when the tile was released (with the drag and make-room offsets still
            // applied) are the ones the next rebuild animates from.
            property bool holdLayout: false

            function captureLayout(): void {
                if (!holdLayout)
                    layoutBefore = tileXs();
            }

            // After the tiles were rebuilt: tiles that moved glide from their old place (an app that quit moves into the
            // recents section instead of jumping), new tiles fade in. Skipped with Reduce Motion and while a tile is dragged.
            function playLayout(): void {
                holdLayout = false;
                // The first fill is not a change: nothing glides or fades in before the Dock is settled.
                if (!reveal || Appearance.reduceMotion || dragFrom >= 0)
                    return;
                tiles.forceLayout();
                const after = tileXs();
                const plan = DockModel.layoutTransition(layoutBefore, after, 1);
                for (let i = 0; i < tileRepeater.count; i++) {
                    const t = tileRepeater.itemAt(i) as Item;
                    if (!t)
                        continue;
                    const key = t.tileId;
                    if (plan.slide[key] !== undefined)
                        t.glideFrom(win.vertical ? 0 : plan.slide[key], win.vertical ? plan.slide[key] : 0);
                    else if (plan.enter.indexOf(key) >= 0)
                        t.fadeIn();
                }
            }

            // Removal puff (own drawing, no artwork): a ring of fading circles around (x, y).
            function poof(x: real, y: real): void {
                poofX = x;
                poofY = y;
                poofAnim.restart();
            }

            NumberAnimation {
                id: poofAnim
                target: win
                property: "poofProgress"
                from: 0
                to: 1
                duration: Appearance.duration(Tokens.dockPoofDuration)
                // Leaving: the exit curve (ADR-0039 step 25).
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curveExit
            }
            // This output has the Dock (modelData is null while the window is destroyed: the name is kept in screenName).
            readonly property bool isDockScreen: screenName !== "" && screenName === root.dockScreen
            // A Dock that moved here comes out of its edge strip: until it has slid in, the machine runs even with auto-hide off.
            property bool revealPending: false
            // A full-screen window or a Split View Desktop is shown on this output (docs/specs/tiling.md TL33, ADR-0036 D66).
            readonly property bool fullscreen: Compositor.fullscreenOn(screenName, Compositor.topologyRevision)
            // Auto-hide as the machine sees it (DockModel.hides): the setting, any output that does not have the Dock (it stays
            // away), a Dock that just moved here, or full screen there (the Dock shows when the pointer reaches its edge).
            readonly property bool autohide: DockModel.hides(Settings.dockAutohide, isDockScreen, revealPending, fullscreen)
            // Layout from the unmagnified geometry (stable under the pointer), then scaled.
            readonly property var widths: root.items.map(it => it.kind === "separator" ? separatorWidth : iconSize)
            readonly property real baseTotal: Magnify.totalWidth(widths, Tokens.dockSpacing)
            readonly property var baseCenters: Magnify.centersFor(widths, Tokens.dockSpacing, (mainTotal - baseTotal) / 2)

            readonly property bool pointerActive: areaHover.hovered || (isDockScreen && root.testPointerX >= 0)
            // The pointer along the Dock (x for a bottom Dock, y for a side one; the test hook gives it directly).
            readonly property real pointerX: root.testPointerX >= 0 ? root.testPointerX : Geometry.mainOf(edge, areaHover.point.position.x, areaHover.point.position.y)
            // Magnification: the target scales of the pointer (all 1 without it) and the displayed ones, which follow them
            // with a frame-rate independent exponential smoothing (Magnify.step; Reduce Motion snaps).
            readonly property var separatorFlags: root.items.map(it => it.kind === "separator")
            readonly property var targetScales: pointerActive ? Magnify.slotScales(baseCenters, widths, Tokens.dockSpacing, separatorFlags, pointerX, pitch, maxScale, Tokens.dockMagnificationRadius) : widths.map(() => 1)
            property var smoothScales: []
            readonly property var scaleList: widths.map((w, i) => smoothScales[i] !== undefined ? smoothScales[i] : 1)
            // What the icons stand on (R7-REQ-13, ADR-0014): the Dock's glass is almost clear, so its tone is the wallpaper's under the shelf, not the system appearance's.
            // The shelf's strip on the output (output px, centred along the edge), the effective luminance of the glass over the wallpaper there, and the held decision with a
            // hysteresis band (IconModes.surfaceIsDark): over black the light-appearance Dock is dark, over white the dark-appearance Dock is light, and the icons are drawn for that.
            readonly property rect shelfStrip: {
                const t = shelfHeight + Tokens.dockBottomMargin;
                const w = win.screen ? win.screen.width : 0, h = win.screen ? win.screen.height : 0;
                switch (edge) {
                case "left":
                    return Qt.rect(0, (h - shelfWidth) / 2, t, shelfWidth);
                case "right":
                    return Qt.rect(w - t, (h - shelfWidth) / 2, t, shelfWidth);
                case "top":
                    return Qt.rect((w - shelfWidth) / 2, 0, shelfWidth, t);
                default:
                    return Qt.rect((w - shelfWidth) / 2, h - t, shelfWidth, t);
                }
            }
            readonly property real surfaceLuma: Appearance.surfaceLuma(win.screen ? win.screen.name : "", win.shelfStrip, Appearance.dark ? Tokens.dockTintAlphaDark : Tokens.dockTintAlphaLight)
            property bool iconDark: IconModes.surfaceIsDark(Appearance.dark, win.surfaceLuma, Appearance.dark, Tokens)
            function refreshIconDark(): void {
                const d = IconModes.surfaceIsDark(win.iconDark, win.surfaceLuma, Appearance.dark, Tokens);
                if (d !== win.iconDark)
                    win.iconDark = d;
            }
            onSurfaceLumaChanged: win.refreshIconDark()
            Connections {
                target: Appearance
                function onDarkChanged(): void {
                    win.refreshIconDark();
                }
            }
            readonly property real shelfWidth: Magnify.totalWidth(widths.map((w, i) => w * scaleList[i]), Tokens.dockSpacing) + 2 * Tokens.dockPadding - dragCollapse * pitch + gapGrow * pitch

            // Autohide state machine (AutoHide.js, table in docs/specs/dock.md): inhibitors keep the shelf shown.
            property int pressedTile: -1
            property var hideMachine: AutoHide.create()
            onHideMachineChanged: {
                if (revealPending && hideMachine.state === "shown")
                    revealPending = false;
            }
            // Only the pointer on the edge strip can bring the Dock to another output: the other inhibitors belong to the Dock's output.
            readonly property var hideInhibitors: ({
                    pointer: pointerActive,
                    drag: isDockScreen && dragFrom >= 0,
                    popup: isDockScreen && (Popups.kind === "dock" || Popups.kind === "dockstack"),
                    hold: isDockScreen && (pressedTile >= 0 || resizing),
                    keyboard: isDockScreen && root.keyboardMode,
                    forced: isDockScreen && root.testReveal,
                    attention: isDockScreen && root.attentionReveal
                })
            readonly property var hideTiming: ({
                    hideGrace: Tokens.dockHideGrace,
                    hideDuration: Appearance.duration(Tokens.dockHideDuration),
                    revealDwell: Tokens.dockRevealDwell,
                    revealDuration: Appearance.duration(Tokens.dockRevealDuration)
                })
            // The input area is the shelf unless the machine is fully hidden (then only the edge strip takes input).
            readonly property bool revealed: !autohide || hideMachine.state !== "hidden" || AutoHide.forcing(hideInhibitors)
            // Tooltips: after one was shown, the next icon labels at once for a while.
            property bool tipsWarm: false

            function focusFirstTile(): void {
                for (let i = 0; i < tileRepeater.count; i++) {
                    const t = tileRepeater.itemAt(i) as Item;
                    if (t && t.activeFocusOnTab) {
                        t.forceActiveFocus();
                        return;
                    }
                }
            }

            // Test hook (IPC dock holdmenu): the pressed tile `index` counts as having opened the hold menu.
            function markHoldMenu(index: int): void {
                const t = tileRepeater.itemAt(index);
                if (!t)
                    return;
                t.menuByHold = true;
                root.interruptDrag();
                console.info("dock-launch: menu-by-hold (forced)", Date.now());
            }

            // The tile that owns a press at `scenePos`: of the tiles whose hit box holds it, the one drawn on top (Geometry.hitOwner:
            // z, then the later one). -1 when none does. Tiles overlap only while one is dragged or making room.
            function tileOwningPress(scenePos: point): int {
                const boxes = [];
                for (let i = 0; i < tileRepeater.count; i++) {
                    const t = tileRepeater.itemAt(i) as Item;
                    const h = t && !t.isSeparator && t.visible ? t.pressBox : null;
                    if (!h) {
                        boxes.push(null);
                        continue;
                    }
                    const o = h.mapToItem(null, 0, 0);
                    boxes.push({x: o.x, y: o.y, w: h.width, h: h.height, z: t.z});
                }
                return Geometry.hitOwner(boxes, scenePos.x, scenePos.y);
            }

            // "x y" of the icon centre of tile `index`, in output coordinates (test hook).
            function tileCentre(index: int): string {
                const t = tileRepeater.itemAt(index);
                if (!t)
                    return "";
                // The separator is narrower than an icon: its middle along the Dock, the icons' middle across it.
                const along = t.isSeparator;
                const p = t.mapToItem(null, along && !win.vertical ? t.width / 2 : t.iconPos.x + t.iconPx / 2, along && win.vertical ? t.height / 2 : t.iconPos.y + t.iconPx / 2);
                return Math.round(origin.x + p.x) + " " + Math.round(origin.y + p.y);
            }

            // "x y w h" of the icon of tile `index` as drawn (magnification, hover rise and drag included), in output coordinates (test hook).
            function tileIconRect(index: int): string {
                const t = tileRepeater.itemAt(index);
                if (!t || t.isSeparator)
                    return "";
                const p = t.mapToItem(null, t.iconPos.x, t.iconPos.y);
                return Math.round(origin.x + p.x) + " " + Math.round(origin.y + p.y) + " " + Math.round(t.iconPx) + " " + Math.round(t.iconPx);
            }

            // Where a popup of tile `index` opens (the Dock menu's anchor).
            function popupAnchor(index: int): var {
                const t = tileRepeater.itemAt(index);
                const c = t.mapToItem(null, t.width / 2, t.height / 2);
                const centre = win.vertical ? win.origin.y + c.y : win.origin.x + c.x;
                return Geometry.menuAnchor(win.edge, win.screen.width, win.screen.height, centre, shelfHeight, Tokens.dockBottomMargin, Tokens.dockMenuTailGap, Tokens.dockMenuTailHeight);
            }

            // The stack of a folder tile (Fan, Grid or List: Stacks.js); toggles when it is already open.
            function openStack(index: int): void {
                root.keyboardMode = false;
                const item = root.items[index];
                if (!item || item.kind !== "folder")
                    return;
                const at = popupAnchor(index);
                const o = Stacks.optionsFor(Settings.dockStackOptions, item.path);
                Popups.toggle("dockstack", win.screen.name, at.x, at.y, at.align, {path: item.path, name: item.name, sort: o.sort, view: o.view});
            }

            function openMenu(index: int): void {
                root.keyboardMode = false;
                const item = root.items[index];
                if (!item || (item.kind !== "app" && item.kind !== "files" && item.kind !== "trash" && item.kind !== "folder"))
                    return;
                const t = tileRepeater.itemAt(index);
                // Centre of the tile along the Dock in screen coordinates; the menu opens above a bottom Dock and beside a side one.
                const c = t.mapToItem(null, t.width / 2, t.height / 2);
                const centre = win.vertical ? win.origin.y + c.y : win.origin.x + c.x;
                const at = Geometry.menuAnchor(win.edge, win.screen.width, win.screen.height, centre, shelfHeight, Tokens.dockBottomMargin, Tokens.dockMenuTailGap, Tokens.dockMenuTailHeight);
                if (item.kind === "folder") {
                    // macOS stack menu: Sort by, Display as, View content as, Options, Open.
                    const o = Stacks.optionsFor(Settings.dockStackOptions, item.path);
                    Popups.open("dock", win.screen.name, at.x, at.y, at.align, {kind: "folder", key: item.key, path: item.path, name: item.name, sort: o.sort, view: o.view, display: o.display, windows: [], running: false});
                    return;
                }
                if (item.kind === "trash") {
                    // macOS Trash menu: Open, Empty Trash…
                    Trash.refresh();
                    Popups.open("dock", win.screen.name, at.x, at.y, at.align, {kind: "trash", key: "trash", windows: [], running: false});
                    return;
                }
                Popups.open("dock", win.screen.name, at.x, at.y, at.align, {
                    key: item.key,
                    entry: item.entry,
                    pinned: item.pinned,
                    recent: item.recent === true,
                    running: item.windows.length > 0,
                    fixed: item.fixed === true,
                    windows: item.windows
                });
            }

            screen: modelData
            // Mapped at once, invisible: its first scene-graph pass and surface mapping run beside the settings read. Until
            // `reveal` nothing of it is drawn (content at opacity 0, no blur), takes input (empty mask) or reserves room
            // (exclusive zone 0); at `reveal` all of that switches in one frame.
            // Revealed once the first layout is final (root.settled) and the surface has the size of the settled edge (`placed`:
            // the compositor answers an anchor change with a new size a frame or two later); the timer lets go of `placed`.
            readonly property bool placed: screen !== null && Geometry.placed(edge, width, height, depth)
            property bool placedGivenUp: false
            // And the session's entrance (ADR-0040 step 6, ID-20): with the menu bar and the desktop icons, in their one fade.
            readonly property bool revealWanted: root.settled && (placed || placedGivenUp) && Entrance.revealed
            // Latched: a later change of the Dock's edge (Settings) re-places the surface but never hides the Dock.
            property bool reveal: false
            onRevealWantedChanged: {
                if (revealWanted)
                    reveal = true;
            }
            Timer {
                interval: Tokens.dockSettleTimeout
                running: root.settled && !win.reveal && !win.placedGivenUp
                onTriggered: win.placedGivenUp = true
            }
            // The Dock's own window says the Dock is ready once it is settled AND placed (review of 3a5e1b80), so the entrance
            // never fades the menu bar and the icons in before it.
            readonly property bool entranceReady: root.settled && (placed || placedGivenUp)
            onEntranceReadyChanged: {
                if (entranceReady && isDockScreen)
                    Entrance.ready("dock");
            }
            onIsDockScreenChanged: {
                if (entranceReady && isDockScreen)
                    Entrance.ready("dock");
            }
            anchors {
                bottom: true
                left: win.edge !== "right"
                right: win.edge !== "left"
                top: win.vertical
            }
            // Across the Dock: shelf, margin, the growth of magnified icons and the room for a label or a dragged icon.
            readonly property real depth: Geometry.depth(DockModel.shelfHeight(largest), Tokens.dockBottomMargin, Math.ceil((maxScale - 1) * Tokens.dockSizeMax), roomPx)
            implicitWidth: vertical ? depth : 0
            implicitHeight: vertical ? 0 : depth
            // Only the Dock's output reserves room, and not while auto-hide is on.
            exclusiveZone: reveal && isDockScreen ? DockModel.reservedHeight(dockMetrics, Settings.dockAutohide) : 0
            color: "transparent"
            focusable: true
            WlrLayershell.layer: DockModel.overlayLayer(win.fullscreen) ? WlrLayer.Overlay : WlrLayer.Top
            WlrLayershell.keyboardFocus: root.keyboardMode && win.screen && win.screen.name === root.keyboardScreen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            WlrLayershell.namespace: "grassfield-dock"
            // Only the dock itself (or the reveal strip while hidden) takes input.
            // qmllint disable missing-type
            mask: win.reveal ? hitMask : emptyMask
            BackgroundEffect.blurRegion: win.reveal && shelf.blurActive ? blurRegion : null
            // qmllint enable missing-type

            Region {
                id: hitMask
                item: hitItem
            }

            // Nothing takes input before the reveal (an empty region).
            Region {
                id: emptyMask
            }

            Region {
                id: blurRegion
                item: shelf
                radius: shelf.radius
            }

            // Rectangle (global layout coordinates) of the minimized tile `index` (0 = first right of the
            // separator): where that window lands (minimize, `adding`: the tile does not exist yet and is
            // appended before the Trash) or leaves from (restore). Called by Compositor for this screen.
            function tileRect(index: int, adding: bool, toplevel: var, intoApp: bool): var {
                const sep = root.items.findIndex(it => it.kind === "separator" && !it.divider);
                const mon = Compositor.monitorByName(win.screen.name);
                if ((Settings.dockMinimizeIntoApp || intoApp) && toplevel && mon) {
                    // Minimize into the application icon: the window goes to (and comes from) its app's tile.
                    const at = root.items.findIndex(it => (it.kind === "app" || it.kind === "files") && it.windows.indexOf(toplevel) >= 0);
                    if (at >= 0)
                        return globalTileRect(mon, Magnify.centersFor(widths, Tokens.dockSpacing, (Geometry.mainSize(edge, screen.width, screen.height) - Magnify.totalWidth(widths, Tokens.dockSpacing)) / 2)[at]);
                }
                if (sep < 0 || !mon || index < 0) {
                    console.warn("grassfield-shell: Dock tileRect refused on", win.screen.name, "(divider at", sep, ", monitor", mon ? mon.name : "unknown to Hyprland", ", slot", index + ")");
                    return null;
                }
                // Pure (Geometry.minimizedSlotRect, tests/unit/tst_dockgeometry.qml): from the output's size, not the window's, which
                // may not have its size yet when the compositor asks; wholly inside this output, which the plugin requires.
                const r = Geometry.minimizedSlotRect(root.items, {
                    index: index,
                    adding: adding,
                    iconSize: iconSize,
                    spacing: Tokens.dockSpacing,
                    separatorWidth: separatorWidth,
                    edge: edge,
                    screenW: screen.width,
                    screenH: screen.height,
                    depth: depth,
                    margin: Tokens.dockBottomMargin,
                    padding: Tokens.dockPadding,
                    indicatorArea: indicatorArea
                });
                return r ? {x: mon.x + r.x, y: mon.y + r.y, w: r.w, h: r.h} : null;
            }

            // The unmagnified icon of the tile whose centre is `mainCenter` along the Dock, in global layout coordinates (the monitor `mon`).
            function globalTileRect(mon: var, mainCenter: real): var {
                const sw = screen.width;
                const sh = screen.height;
                const winW = vertical ? depth : sw;
                const winH = vertical ? sh : depth;
                const r = Geometry.tileRect(edge, winW, winH, mainCenter, iconSize, Tokens.dockBottomMargin, Tokens.dockPadding, indicatorArea);
                const o = Geometry.windowOrigin(edge, sw, sh, winW, winH);
                const c = Geometry.clampInto({x: o.x + r.x, y: o.y + r.y, w: r.w, h: r.h}, {x: 0, y: 0, w: sw, h: sh});
                return {x: mon.x + c.x, y: mon.y + c.y, w: c.w, h: c.h};
            }

            // modelData is already null when a removed screen destroys this window: keep the name.
            property string screenName: ""
            Component.onCompleted: {
                screenName = win.modelData.name;
                if (revealWanted)
                    reveal = true;
                Compositor.registerDock(screenName, win);
                // An output that does not have the Dock starts with it slid out of sight.
                if (!isDockScreen)
                    hideMachine = AutoHide.initial(true);
            }

            // At the first settled layout: the machine starts where it will rest (AutoHide.initial).
            function resetHide(): void {
                hideMachine = AutoHide.initial(autohide);
            }
            Component.onDestruction: {
                Compositor.unregisterDock(screenName, win);
                if (win.reveal && win.isDockScreen)
                    Journal.hidden("dock", screenName);
            }
            onRevealChanged: {
                if (reveal && isDockScreen)
                    Journal.shown("dock", screenName);
            }

            onPointerActiveChanged: {
                if (pointerActive)
                    Trash.refresh();
            }

            // Frame clock of the magnification: runs only until the displayed scales reach their targets.
            FrameAnimation {
                running: !Magnify.settled(win.smoothScales, win.targetScales, 0.0005)
                onTriggered: {
                    let next = Magnify.step(win.smoothScales, win.targetScales, frameTime * 1000, Appearance.reduceMotion ? 0 : Tokens.dockMagnificationTau, Tokens.dockMagnificationMaxDt);
                    if (Magnify.settled(next, win.targetScales, 0.0005))
                        next = win.targetScales.slice();
                    win.smoothScales = next;
                }
            }

            // Frame clock of the auto-hide machine: stops while nothing can change (hidden and idle, or shown and held).
            FrameAnimation {
                running: AutoHide.active(win.hideMachine, win.hideInhibitors, win.autohide)
                onTriggered: {
                    const next = AutoHide.step(win.hideMachine, win.hideInhibitors, win.autohide, win.hideTiming, Math.min(frameTime * 1000, 100));
                    // The pointer stayed on the edge strip of an output without the Dock for the dwell: the Dock comes here.
                    if (Geometry.movesDock(win.isDockScreen, win.hideMachine.state, next.state)) {
                        win.revealPending = true;
                        root.moveDockTo(win.screenName);
                    }
                    win.hideMachine = next;
                }
            }

            Timer {
                id: tipsWarmTimer
                interval: Tokens.dockTooltipWarm
                onTriggered: win.tipsWarm = false
            }

            Item {
                id: area
                anchors.fill: parent
                // Nothing is drawn before the reveal; at it the Dock appears whole, in the entrance's one fade (session.revealMs,
                // ADR-0040 ID-20; Reduce Motion caps it), with the menu bar and the desktop icons.
                opacity: win.reveal ? 1 : 0
                Behavior on opacity {
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.sessionRevealMs)
                    }
                }

                HoverHandler {
                    id: areaHover
                    // Using the pointer leaves keyboard mode (focus returns to the app).
                    onPointChanged: {
                        if (hovered)
                            PointerTracker.report(win.screen.name, win.origin.x + point.position.x, win.origin.y + point.position.y);
                        if (hovered && root.keyboardMode)
                            root.keyboardMode = false;
                    }
                }

                // Input area: the shelf (plus magnified icons and tooltips while hovered), or the
                // bottom strip while the dock is hidden.
                Item {
                    id: hitItem
                    readonly property var r: Geometry.hitRect(win.edge, win.width, win.height, {
                        revealed: win.revealed,
                        dragging: win.dragFrom >= 0 || win.resizing,
                        pointerActive: win.pointerActive,
                        shelfMain0: Geometry.mainOf(win.edge, shelf.x, shelf.y),
                        shelfLength: win.shelfWidth,
                        thickness: win.shelfHeight,
                        margin: Tokens.dockBottomMargin,
                        overhang: win.overhang,
                        room: win.tipRoom,
                        zone: Tokens.dockRevealZone
                    })
                    x: r.x
                    y: r.y
                    width: r.w
                    height: r.h
                }

                // Removal puff.
                Item {
                    id: poofLayer
                    visible: win.poofProgress < 1
                    z: 50

                    Repeater {
                        model: 7

                        delegate: Rectangle {
                            id: puff

                            required property int index
                            readonly property real angle: index === 6 ? 0 : index * Math.PI / 3
                            readonly property real reach: index === 6 ? 0 : win.poofProgress * Tokens.dockPoofSize / 2
                            width: Tokens.dockPoofSize * (index === 6 ? Tokens.dockPoofCoreScale : Tokens.dockPoofPuffScale) * (Tokens.dockPoofGrowFrom + win.poofProgress)
                            height: width
                            radius: width / 2
                            x: win.poofX + Math.cos(angle) * reach - width / 2
                            y: win.poofY + Math.sin(angle) * reach - height / 2
                            color: Appearance.withAlpha(Appearance.colors.materialHighlight, Tokens.dockPoofOpacity * (1 - win.poofProgress))
                        }
                    }
                }

                Material {
                    id: shelf
                    // Centred along the Dock, a margin off the screen edge, slid toward the edge while the Dock hides (any edge).
                    // Under Reduce Motion the Dock fades where it stands instead of sliding (ADR-0039 D2, step 25): in place while
                    // any of it shows, out of the window once hidden (its blur region and input with it).
                    readonly property real hidden: Appearance.reduceMotion ? (win.hideMachine.visible > 0 ? 0 : 1) : 1 - AutoHide.ease(win.hideMachine.visible)
                    readonly property var r: Geometry.shelfRect(win.edge, win.width, win.height, win.shelfWidth, win.shelfHeight, Tokens.dockBottomMargin, shelf.hidden * (win.shelfHeight + Tokens.dockBottomMargin + shadowMargin))
                    x: r.x
                    y: r.y
                    width: r.w
                    height: r.h
                    opacity: Appearance.reduceMotion ? AutoHide.ease(win.hideMachine.visible) : 1
                    radius: Tokens.radiusDock
                    tintAlphaOverride: Appearance.dark ? Tokens.dockTintAlphaDark : Tokens.dockTintAlphaLight
                    // The glass edge of every surface (ADR-0024 section 2.5, ADR-0039 step 25): Material's darker outer edge,
                    // then the bright inner rim; the shelf's light outer rim (dock.rimOpacity) goes.
                    highlightOpacity: Tokens.dockHighlightOpacity

                    // Folders dragged from Files, the desktop or anywhere that offers text/uri-list: dropped in the right section
                    // (after the divider) they are kept in the Dock as stacks, at the slot where the gap opened. Under the tiles:
                    // apps and the Trash take their own drops first.
                    DropArea {
                        id: folderDrop
                        anchors.fill: parent
                        keys: ["text/uri-list"]
                        property var paths: []
                        readonly property string verdict: paths.length === 0 ? "unknown" : Stacks.folderVerdict(paths, Apps.hoverTypes)
                        function slotAt(drag: var): int {
                            const main = win.vertical ? shelf.y + drag.y : shelf.x + drag.x;
                            return Stacks.folderSlot(main, win.baseCenters, win.separatorAt, win.folderCount);
                        }
                        function read(drag: var): void {
                            if (paths.length > 0)
                                return;
                            const found = Icons.parseUriList(drag.getDataAsString("text/uri-list"));
                            if (found.length === 0)
                                return;
                            paths = found;
                            Apps.hoverFolders(found);
                        }
                        function track(drag: var): void {
                            read(drag);
                            const slot = slotAt(drag);
                            const ok = slot >= 0 && verdict !== "no";
                            drag.accepted = ok;
                            win.folderDropIndex = ok ? slot : -1;
                        }
                        onEntered: drag => {
                            paths = [];
                            track(drag);
                        }
                        onPositionChanged: drag => track(drag)
                        onExited: {
                            paths = [];
                            win.folderDropIndex = -1;
                            Apps.hoverLeave();
                        }
                        onDropped: drop => {
                            const found = Icons.parseUriList(drop.getDataAsString("text/uri-list"));
                            const slot = slotAt(drop);
                            paths = [];
                            win.folderDropIndex = -1;
                            if (found.length === 0 || slot < 0) {
                                drop.accepted = false;
                                return;
                            }
                            drop.accept(Qt.LinkAction);
                            // The real types decide (a folder may carry an extension, a file may not): only folders are added.
                            Apps.dirsOf(found, resolved => {
                                const dirs = found.filter(p => resolved[p] === "inode/directory");
                                if (dirs.length > 0)
                                    Settings.setDockFolders(Stacks.insertFolders(Settings.dockFolders, dirs, slot, Quickshell.env("HOME"), Tokens.dockStackMax));
                            });
                        }
                    }

                    // A row of tiles, or a column (first tile on top) on a side edge.
                    Grid {
                        id: tiles
                        x: Tokens.dockPadding
                        y: Tokens.dockPadding
                        spacing: Tokens.dockSpacing
                        columns: win.vertical ? 1 : Math.max(1, tileRepeater.count)

                        Repeater {
                            id: tileRepeater
                            model: tileModel

                            delegate: Item {
                                id: tile

                                required property string tileId
                                required property int index
                                readonly property var modelData: root.itemByKey[tileId] !== undefined ? root.itemByKey[tileId] : ({kind: "", windows: []})

                                readonly property real tileScale: win.scaleList[index] !== undefined ? win.scaleList[index] : 1
                                readonly property bool isFiles: modelData.kind === "files"
                                readonly property bool isApp: modelData.kind === "app" || isFiles
                                readonly property bool isTrash: modelData.kind === "trash"
                                readonly property bool isAppsTile: modelData.kind === "apps"
                                readonly property bool isSeparator: modelData.kind === "separator"
                                readonly property bool isMinimized: modelData.kind === "minimized"
                                readonly property bool isFolder: modelData.kind === "folder"
                                readonly property var folderOptions: isFolder ? Stacks.optionsFor(Settings.dockStackOptions, modelData.path) : ({sort: "dateAdded", view: "automatic", display: "stack"})
                                readonly property bool running: isApp && modelData.windows.length > 0
                                // An app's name in the shell's language (Apps.displayName), whatever DockModel copied.
                                readonly property string label: isTrash ? qsTr("Trash") : isAppsTile ? qsTr("Apps") : isApp && modelData.entry ? DisplayName.text(Apps.displayName(modelData.entry)) : (isApp || isMinimized || isFolder ? DisplayName.text(modelData.name) : "")
                                readonly property real iconPx: win.iconSize * tileScale
                                // The icon's place in the tile (it grows away from the screen edge) and the way out (bounce, hover rise).
                                readonly property var iconPos: Geometry.iconOrigin(win.edge, win.iconSize, iconPx, win.indicatorArea)
                                readonly property bool dragging: win.dragFrom === index
                                readonly property Item pressBox: hit
                                // The button is held on an app tile: the icon darkens slightly (macOS).
                                readonly property bool pressedDown: isApp && leftTap.pressed && ownsPress && !dragging
                                property bool tipSuppressed: false
                                // The hovered state outlives the pointer by Tokens.dockHoverHold, so the label does not flicker
                                // when the pointer crosses the gap between two icons.
                                property bool hoverHeld: false
                                // A magnified icon rises by a small part of its growth (the running dot stays on the shelf).
                                readonly property real hoverLift: win.iconSize * (tileScale - 1) * Tokens.dockMagnificationLift
                                // The Dock menu was opened by holding the button: the release is not a click.
                                property bool menuByHold: false
                                // root.clickCancels when the button went down, and whether Qt cancelled the press (the tap is refused then).
                                property int pressMark: 0
                                property bool pressCancelled: false
                                property real pressTime: 0
                                // This tile owns the press that is down (win.tileOwningPress): where two hit boxes share a point only the tile drawn on top acts.
                                property bool ownsPress: true
                                // root.dragInterruptions when the button went down (a drag of this press is refused when it changed).
                                property int dragMark: 0
                                readonly property bool bouncing: isApp && !running && root.launching[modelData.key] !== undefined && !Appearance.reduceMotion && Settings.dockAnimateOpening
                                // An app asking for attention: its icon hops again and again until the app is activated. With Reduce Motion
                                // it does not move: a static accent plate shows it instead.
                                readonly property bool attentive: isApp && running && root.attentionKeys.indexOf(modelData.key) >= 0
                                readonly property bool attentionHops: attentive && !Appearance.reduceMotion
                                // The count the app set itself (LauncherEntry) wins over the notifications' while it is known; 0 hides it.
                                readonly property int badge: isApp ? DockModel.tileBadge(Notifications.history, modelData, root.launcherState) : 0
                                // Settings' badge counts Software Update's releases, not notifications (its accessible name says so).
                                readonly property bool updatesBadge: isApp && SoftwareUpdate.count > 0 && DockModel.isApp(modelData, root.settingsId)
                                // Progress the app set on its tile: 0..1, -1 for no bar.
                                readonly property real progress: isApp ? DockModel.tileProgress(root.launcherState, modelData) : -1
                                // Neighbours of a dragged tile make room along the Dock (or close the gap while it is dragged out).
                                readonly property real shiftMain: {
                                    // A folder is dragged over the shelf: the tiles from the slot on make room for it (macOS).
                                    if (win.dragFrom < 0 && (win.folderDropIndex >= 0 || win.gapGrow > 0))
                                        return index >= win.separatorAt + 1 + win.folderDropLast ? win.gapGrow * win.pitch : 0;
                                    if (win.dragFrom < 0 || index === win.dragFrom)
                                        return 0;
                                    if (win.dragCollapsing)
                                        return index > win.dragFrom ? -win.pitch : 0;
                                    const from = win.dragFromApp;
                                    const at = win.appItems.indexOf(index);
                                    if (from < 0 || at === from || !isApp || isFiles)
                                        return 0;
                                    const slot = win.dragSlot;
                                    if (from < slot && at > from && at <= slot)
                                        return -win.pitch;
                                    if (slot < from && at >= slot && at < from)
                                        return win.pitch;
                                    return 0;
                                }

                                // Layout transition: offset (screen x, y) gliding to 0, and the fade-in of a new tile.
                                property real glide: 0
                                property real glideY: 0
                                // The make-room offset animates while a tile is dragged; it snaps at the release, together
                                // with the layout change.
                                property real shiftAnim: shiftMain
                                Behavior on shiftAnim {
                                    enabled: win.reveal && !tile.dragging && !win.dragSnap
                                    NumberAnimation {
                                        duration: Appearance.duration(Tokens.motionFast)
                                        easing.type: Easing.BezierSpline
                                        easing.bezierCurve: Appearance.curve
                                    }
                                }
                                function glideFrom(dx: real, dy: real): void {
                                    glide = dx;
                                    glideY = dy;
                                    glideAnim.restart();
                                    glideYAnim.restart();
                                }
                                function fadeIn(): void {
                                    opacity = 0;
                                    fadeAnim.restart();
                                }

                                NumberAnimation {
                                    id: glideAnim
                                    target: tile
                                    property: "glide"
                                    to: 0
                                    duration: Appearance.duration(Tokens.motionNormal)
                                    easing.type: Easing.BezierSpline
                                    easing.bezierCurve: Appearance.curve
                                }

                                NumberAnimation {
                                    id: glideYAnim
                                    target: tile
                                    property: "glideY"
                                    to: 0
                                    duration: Appearance.duration(Tokens.motionNormal)
                                    easing.type: Easing.BezierSpline
                                    easing.bezierCurve: Appearance.curve
                                }

                                NumberAnimation {
                                    id: fadeAnim
                                    target: tile
                                    property: "opacity"
                                    to: 1
                                    duration: Appearance.duration(Tokens.motionNormal)
                                    // Arriving: the enter curve (ADR-0039 step 25).
                                    easing.type: Easing.BezierSpline
                                    easing.bezierCurve: Appearance.curveEnter
                                }

                                width: win.vertical ? win.tileCross : (isSeparator ? win.separatorWidth : iconPx)
                                height: win.vertical ? (isSeparator ? win.separatorWidth : iconPx) : win.tileCross
                                z: dragging ? 100 : 0
                                // The shelf closes a gap around its centre: the dragged tile compensates to stay under the pointer. A hovered
                                // icon rises away from the screen edge by hoverLift.
                                readonly property real collapseShift: -win.dragCollapse * win.pitch / 2
                                transform: Translate {
                                    x: tile.dragging ? win.dragDx + (win.vertical ? 0 : tile.collapseShift) : tile.glide + (win.vertical ? 0 : tile.shiftAnim) + win.outDir.x * tile.hoverLift
                                    y: tile.dragging ? win.dragDy + (win.vertical ? tile.collapseShift : 0) : tile.glideY + (win.vertical ? tile.shiftAnim : 0) + win.outDir.y * tile.hoverLift
                                }
                                activeFocusOnTab: !isSeparator
                                Accessible.role: isSeparator ? Accessible.Separator : Accessible.Button
                                Accessible.name: isAppsTile ? qsTr("Apps") : isFolder ? qsTr("%1, folder stack").arg(label) : isTrash ? (Trash.empty ? qsTr("Trash, empty") : qsTr("Trash, contains items")) : (isMinimized ? qsTr("%1, minimized").arg(label) : ((running ? qsTr("%1, running").arg(label) : label) + (badge > 0 ? (updatesBadge ? (badge === 1 ? qsTr(", 1 update") : qsTr(", %1 updates").arg(badge)) : (badge === 1 ? qsTr(", 1 notification") : qsTr(", %1 notifications").arg(badge))) : "") + (attentive ? qsTr(", needs attention") : "")))
                                Accessible.focusable: !isSeparator
                                Accessible.ignored: isSeparator
                                Accessible.onPressAction: root.activateItem(modelData)
                                Keys.onReturnPressed: root.activateItem(modelData)
                                Keys.onEnterPressed: root.activateItem(modelData)
                                Keys.onSpacePressed: root.activateItem(modelData)
                                Keys.onEscapePressed: root.keyboardMode = false
                                Keys.onLeftPressed: (tile.nextItemInFocusChain(false) as Item).forceActiveFocus()
                                Keys.onRightPressed: (tile.nextItemInFocusChain(true) as Item).forceActiveFocus()
                                Keys.onUpPressed: (tile.nextItemInFocusChain(false) as Item).forceActiveFocus()
                                Keys.onDownPressed: (tile.nextItemInFocusChain(true) as Item).forceActiveFocus()
                                Keys.onMenuPressed: win.openMenu(index)

                                // What a pointer can press, hover, drag, drop on and open the menu from: the drawn icon, not only the tile's own box. The icon
                                // grows outside the tile (the tile keeps iconSize + indicator across so the Grid does not move) and a handler is
                                // scoped to its parent: left on the tile, the part of a magnified icon beyond it was dead (owner report
                                // 2026-10-25, "I click an open app in the Dock and nothing happens"). Along the Dock the box is the tile's own
                                // extent, so neighbours share no point at rest; the tile drawn on top (win.tileOwningPress) owns one they share.
                                Item {
                                    id: hit
                                    readonly property var box: Geometry.hitBox(win.edge, win.iconSize, tile.iconPx, win.indicatorArea, tile.width, tile.height)
                                    visible: !tile.isSeparator
                                    x: box.x
                                    y: box.y
                                    width: box.w
                                    height: box.h
                                }

                                // Separator hairline.
                                Rectangle {
                                    visible: tile.isSeparator
                                    // Across a bottom Dock the hairline is vertical, along a side Dock horizontal; centred on the icons.
                                    width: win.vertical ? win.dockMetrics.separatorHeight : Tokens.dockSeparatorWidth
                                    height: win.vertical ? Tokens.dockSeparatorWidth : win.dockMetrics.separatorHeight
                                    x: win.vertical ? (win.edge === "left" ? win.indicatorArea : 0) + (win.iconSize - width) / 2 : (tile.width - width) / 2
                                    y: win.vertical ? (tile.height - height) / 2 : (win.iconSize - height) / 2
                                    color: Appearance.withAlpha(Appearance.colors.separator, Tokens.dockSeparatorOpacity)
                                }

                                // Resize (macOS): the separator is a handle. The pointer shows the resize cursor over it (across the Dock, along
                                // the direction it moves) and dragging away from the screen edge makes the Dock larger, live; the setting is
                                // written on release. The shelf grows by the change of the tile, so its middle (the separator) follows the
                                // pointer when the size changes by twice the pointer's distance.
                                HoverHandler {
                                    enabled: tile.isSeparator
                                    cursorShape: win.vertical ? Qt.SizeHorCursor : Qt.SizeVerCursor
                                }

                                DragHandler {
                                    id: resizeDrag
                                    enabled: tile.isSeparator
                                    target: null
                                    cursorShape: win.vertical ? Qt.SizeHorCursor : Qt.SizeVerCursor
                                    property real startSize: 0
                                    onActiveChanged: {
                                        if (VisualFixtures.active)
                                            console.info("dock-resize: active", active, win.iconSize, Date.now());
                                        if (active) {
                                            startSize = win.iconSize;
                                            win.resizing = true;
                                            root.liveSize = win.iconSize;
                                        } else if (win.resizing) {
                                            win.resizing = false;
                                            if (root.liveSize >= 0)
                                                Settings.setDockSize(root.liveSize);
                                            root.liveSize = -1;
                                        }
                                    }
                                    onTranslationChanged: {
                                        if (active)
                                            root.liveSize = Geometry.resizeSize(startSize, win.edge, translation.x, translation.y, Tokens.dockSizeMin, Tokens.dockSizeMax);
                                    }
                                }

                                // Attention with Reduce Motion: a static accent plate behind the icon (no hop).
                                Rectangle {
                                    visible: tile.attentive && Appearance.reduceMotion
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                    radius: win.dockMetrics.iconRadius * tile.tileScale
                                    color: Appearance.withAlpha(Appearance.colors.accent, Tokens.dockAttentionHighlightOpacity)
                                }

                                // Application icon, growing upward from the shelf.
                                TintedIcon {
                                    id: appIcon
                                    darkAppearance: win.iconDark
                                    visible: tile.isApp
                                    size: win.iconSize
                                    // Default mode is decoded as before; an effect mode decodes at the largest magnification so the
                                    // fixed-size texture is never upscaled.
                                    oversample: appIcon.modeActive ? Tokens.dockIconOversample : appIcon.defaultOversample
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                    source: tile.isApp ? ThemeIcons.appIcon(tile.modelData.icon, "application-x-executable") : ""
                                    asynchronous: true

                                    // Held button: darker by Tokens.dockPressDim (an offscreen layer only while pressed).
                                    layer.enabled: tile.pressedDown
                                    layer.effect: MultiEffect {
                                        brightness: -Tokens.dockPressDim
                                    }

                                    // Launch bounce: hops until the app has a window (or the launch timeout).
                                    property real lift: 0
                                    onLiftChanged: {
                                        if (VisualFixtures.active && root.launchClickedAt > 0 && tile.bouncing)
                                            console.info("dock-launch: lift", Date.now() - root.launchClickedAt, Math.round(lift * 10) / 10);
                                        if (VisualFixtures.active && root.attentionAt > 0 && tile.attentionHops)
                                            console.info("dock-attention: lift", Date.now() - root.attentionAt, Math.round(lift * 10) / 10);
                                    }
                                    transform: Translate {
                                        x: win.outDir.x * appIcon.lift
                                        y: win.outDir.y * appIcon.lift
                                    }

                                    // Attention: the launch hop repeated, one every Tokens.dockAttentionPeriod, until the app is activated.
                                    SequentialAnimation {
                                        running: tile.attentionHops
                                        loops: Animation.Infinite
                                        onRunningChanged: {
                                            if (running)
                                                landAnim.stop();
                                            else if (appIcon.lift > 0)
                                                landAnim.restart();
                                        }

                                        NumberAnimation {
                                            target: appIcon
                                            property: "lift"
                                            to: tile.iconPx * Tokens.dockAttentionHeightScale
                                            duration: Tokens.dockBounceDuration / 2
                                            easing.type: Easing.OutQuad
                                        }
                                        NumberAnimation {
                                            target: appIcon
                                            property: "lift"
                                            to: 0
                                            duration: Tokens.dockBounceDuration / 2
                                            easing.type: Easing.InQuad
                                        }
                                        PauseAnimation {
                                            duration: Math.max(0, Tokens.dockAttentionPeriod - Tokens.dockBounceDuration)
                                        }
                                    }

                                    SequentialAnimation {
                                        running: tile.bouncing
                                        loops: Animation.Infinite
                                        // The hop ends by landing (a few small rebounds), not by snapping back.
                                        onRunningChanged: {
                                            if (running)
                                                landAnim.stop();
                                            else if (appIcon.lift > 0)
                                                landAnim.restart();
                                        }

                                        NumberAnimation {
                                            target: appIcon
                                            property: "lift"
                                            to: tile.iconPx * Tokens.dockBounceHeightScale
                                            duration: Tokens.dockBounceDuration / 2
                                            easing.type: Easing.OutQuad
                                        }
                                        NumberAnimation {
                                            target: appIcon
                                            property: "lift"
                                            to: 0
                                            duration: Tokens.dockBounceDuration / 2
                                            easing.type: Easing.InQuad
                                        }
                                    }

                                    NumberAnimation {
                                        id: landAnim
                                        target: appIcon
                                        property: "lift"
                                        to: 0
                                        duration: Appearance.duration(Tokens.motionNormal)
                                        easing.type: Easing.OutBounce
                                    }
                                }

                                // Progress an application set on its tile (LauncherEntry): a thin bar near the bottom of the icon, like
                                // macOS' progress on a Dock tile. It hops with the icon, the way the icon hops (away from the screen
                                // edge: sideways on a side Dock; it rose on every edge, UI audit 2026-11-05 LOW).
                                Rectangle {
                                    id: progressTrack
                                    objectName: "dockProgress"
                                    visible: tile.progress >= 0
                                    transform: Translate {
                                        x: win.outDir.x * appIcon.lift
                                        y: win.outDir.y * appIcon.lift
                                    }
                                    height: Tokens.dockProgressHeight
                                    radius: height / 2
                                    anchors.left: appIcon.left
                                    anchors.right: appIcon.right
                                    anchors.bottom: appIcon.bottom
                                    anchors.leftMargin: Tokens.dockProgressInset
                                    anchors.rightMargin: Tokens.dockProgressInset
                                    anchors.bottomMargin: Tokens.dockProgressBottomOffset
                                    color: Appearance.withAlpha(Appearance.colors.fill, Tokens.dockProgressTrackOpacity)

                                    Rectangle {
                                        width: Math.max(0, tile.progress) * parent.width
                                        height: parent.height
                                        radius: parent.radius
                                        color: Appearance.colors.accent
                                    }
                                }

                                // Notification badge (counts from the notification history). Not a child of the icon: the press-dim layer
                                // would clip the part that overhangs the icon. It hops with the icon, and grows with it under
                                // magnification (macOS; it kept its size on a magnified icon, UI audit 2026-11-05 LOW).
                                Rectangle {
                                    visible: tile.badge > 0
                                    transform: Translate {
                                        x: win.outDir.x * appIcon.lift
                                        y: win.outDir.y * appIcon.lift
                                    }
                                    height: win.dockMetrics.badgeSize * tile.tileScale
                                    width: Math.max(height, badgeLabel.implicitWidth + Tokens.spacingSm * tile.tileScale)
                                    radius: height / 2
                                    color: Appearance.colors.destructive
                                    anchors.right: appIcon.right
                                    anchors.top: appIcon.top
                                    anchors.rightMargin: -Tokens.dockBadgeOverhang * tile.tileScale
                                    anchors.topMargin: -Tokens.dockBadgeOverhang * tile.tileScale

                                    Text {
                                        id: badgeLabel
                                        textFormat: Text.PlainText
                                        anchors.centerIn: parent
                                        text: DockModel.badgeText(tile.badge)
                                        color: Appearance.colors.destructiveText
                                        font.family: Appearance.fontFamily
                                        font.pixelSize: Tokens.typographyCaptionSize * win.dockMetrics.badgeScale * tile.tileScale
                                        font.weight: Tokens.typographyMenuBoldWeight
                                    }
                                }

                                // Minimized window: live thumbnail with the app icon badge in the
                                // `full` material profile, the app icon alone otherwise.
                                Item {
                                    id: minimizedTile
                                    visible: tile.isMinimized
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y

                                    readonly property bool live: Settings.materialProfile === "full"
                                    readonly property string iconSource: tile.isMinimized ? ThemeIcons.appIcon(tile.modelData.icon, "application-x-executable") : ""

                                    Rectangle {
                                        visible: minimizedTile.live
                                        anchors.fill: parent
                                        radius: win.dockMetrics.iconRadius * tile.tileScale
                                        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                                        clip: true

                                        ScreencopyView {
                                            id: thumb
                                            // Fit inside the tile keeping the aspect ratio.
                                            readonly property real ratio: implicitWidth > 0 && implicitHeight > 0 ? implicitWidth / implicitHeight : 1
                                            width: ratio >= 1 ? parent.width : parent.height * ratio
                                            height: ratio >= 1 ? parent.width / ratio : parent.height
                                            anchors.centerIn: parent
                                            captureSource: minimizedTile.live && tile.isMinimized ? tile.modelData.toplevel : null
                                            live: true
                                            paintCursor: false
                                        }
                                    }

                                    TintedIcon {
                                        id: minimizedIcon
                                    darkAppearance: win.iconDark
                                        // The drawn nominal size (the badge is a fraction of the tile when the thumbnail shows), so that
                                        // the minimum size of the icon modes applies to what is on screen.
                                        size: minimizedTile.live ? Math.round(win.iconSize * Tokens.dockMinimizedBadgeScale) : win.iconSize
                                        // The same decode as the tile's icon: an effect mode decodes at the largest magnification.
                                        oversample: minimizedIcon.modeActive ? Tokens.dockIconOversample : minimizedIcon.defaultOversample
                                        width: minimizedTile.live ? Math.round(parent.width * Tokens.dockMinimizedBadgeScale) : parent.width
                                        height: width
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        source: minimizedTile.iconSource
                                        asynchronous: true
                                    }
                                }

                                // Folder stack (macOS: Downloads and other folders right of the divider): the newest items piled up
                                // ("Display as: Stack", live), or the folder icon of the icon theme ("Folder", and an empty folder).
                                StackPile {
                                    id: pile
                                    visible: tile.isFolder && tile.folderOptions.display === "stack" && !empty
                                    items: tile.isFolder && tile.folderOptions.display === "stack" ? (root.pileItems[tile.modelData.path] ?? []) : []
                                    size: win.iconSize
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                }

                                TintedIcon {
                                    id: folderThemed
                                    darkAppearance: win.iconDark
                                    visible: tile.isFolder && !(tile.folderOptions.display === "stack" && !pile.empty)
                                    size: win.iconSize
                                    oversample: folderThemed.modeActive ? Tokens.dockIconOversample : folderThemed.defaultOversample
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                    source: tile.isFolder ? Quickshell.iconPath(Stacks.folderIconName(tile.modelData.path, Quickshell.env("HOME")), "folder") : ""
                                    asynchronous: true
                                }

                                // Trash: the icon theme's user-trash / user-trash-full (never hand-drawn), in the user's icon
                                // mode; a symbolic glyph on a rounded tile when the theme has neither.
                                TintedIcon {
                                    id: trashThemed
                                    darkAppearance: win.iconDark
                                    readonly property string themed: Quickshell.iconPath(Trash.empty ? "user-trash" : "user-trash-full", true)
                                    visible: tile.isTrash && themed !== ""
                                    size: win.iconSize
                                    oversample: trashThemed.modeActive ? Tokens.dockIconOversample : trashThemed.defaultOversample
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                    source: tile.isTrash ? themed : ""
                                    asynchronous: true
                                }

                                Rectangle {
                                    id: trashIcon
                                    visible: tile.isTrash && trashThemed.themed === ""
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    radius: win.dockMetrics.iconRadius * tile.tileScale
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                    color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

                                    Icon {
                                        anchors.centerIn: parent
                                        size: Math.round(tile.iconPx * Tokens.dockTrashIconScale)
                                        name: Trash.empty ? "trash" : "trash-full"
                                    }
                                }

                                // Apps: org.grassfield.Apps, Grassfield's own drawing (ADR-0040 IQ-B5 C; grassfield-desktop installs it
                                // in hicolor, which every icon theme falls back to), in the user's icon mode; a rounded tile with our
                                // own grid glyph when no theme has it (a dev session without the package).
                                TintedIcon {
                                    id: appsThemed
                                    darkAppearance: win.iconDark
                                    readonly property string themed: Quickshell.iconPath("org.grassfield.Apps", true)
                                    visible: tile.isAppsTile && themed !== ""
                                    size: win.iconSize
                                    oversample: appsThemed.modeActive ? Tokens.dockIconOversample : appsThemed.defaultOversample
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                    source: tile.isAppsTile ? themed : ""
                                    asynchronous: true
                                }

                                Rectangle {
                                    id: appsTileIcon
                                    visible: tile.isAppsTile && appsThemed.themed === ""
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    radius: win.dockMetrics.iconRadius * tile.tileScale
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                    color: Appearance.colors.selection

                                    Icon {
                                        anchors.centerIn: parent
                                        size: Math.round(tile.iconPx * Tokens.dockTrashIconScale)
                                        name: "apps"
                                        color: Appearance.colors.selectionText
                                    }
                                }

                                // Activity Monitor's live graph over its tile (ADR-0038 AM62), moving with the icon's hops.
                                TileGraphView {
                                    graph: tile.isApp && tile.running && String(tile.modelData.key).toLowerCase() === "org.grassfield.activity" ? TileGraph.parse(ActivityLink.tileText, ActivityLink.tilePids) : null
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                    radius: win.dockMetrics.iconRadius * tile.tileScale
                                    transform: Translate {
                                        x: win.outDir.x * appIcon.lift
                                        y: win.outDir.y * appIcon.lift
                                    }
                                }

                                // Keyboard focus ring.
                                Rectangle {
                                    visible: tile.activeFocus && root.keyboardMode && !tile.isSeparator
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                    radius: win.dockMetrics.iconRadius * tile.tileScale
                                    color: "transparent"
                                    border.width: Tokens.controlFocusOutline
                                    border.color: Appearance.focusRingColor
                                }

                                // Running indicator, ringed by a halo of the opposite colour: it reads over any backdrop on the clear
                                // shelf (ADR-0024 G-7: black under a white dot in dark, white under a black dot in light).
                                Rectangle {
                                    visible: tile.running && Settings.dockShowIndicators
                                    width: Tokens.dockIndicatorSize + 2 * Tokens.dockDotHalo
                                    height: width
                                    radius: width / 2
                                    color: Appearance.withAlpha(Appearance.dark ? Appearance.colors.shadow : Appearance.colors.knob, Tokens.dockDotHaloOpacity)
                                    readonly property var dot: Geometry.dotOrigin(win.edge, tile.width, tile.height, win.iconSize, Tokens.dockIndicatorGap, Tokens.dockIndicatorSize, tile.hoverLift)
                                    x: dot.x - Tokens.dockDotHalo
                                    y: dot.y - Tokens.dockDotHalo

                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: Tokens.dockIndicatorSize
                                        height: width
                                        radius: width / 2
                                        color: Appearance.colors.indicator
                                    }
                                }

                                Tooltip {
                                    id: tooltip
                                    z: 10
                                    tail: true
                                    tailSide: Geometry.tooltipTailSide(win.edge)
                                    text: tile.dragging ? qsTr("Remove") : tile.label
                                    delay: (tile.dragging || (tile.activeFocus && root.keyboardMode) || win.tipsWarm) ? 0 : Tokens.dockTooltipDelay
                                    // One turn of the event loop later: `delay` reads tipsWarm and visibleNow reads delay, so setting it from this
                                    // handler is a binding loop (Qt warned each time a label showed).
                                    onVisibleNowChanged: Qt.callLater(() => {
                                        if (tooltip.visibleNow) {
                                            win.tipsWarm = true;
                                            tipsWarmTimer.stop();
                                        } else {
                                            tipsWarmTimer.restart();
                                        }
                                    })
                                    shown: tile.dragging ? (win.dragOut && win.dragRemovable) : (tile.label !== "" && (tile.hoverHeld || (tile.activeFocus && root.keyboardMode)) && !tile.tipSuppressed && !Popups.active && win.dragFrom < 0)
                                    readonly property var at: Geometry.tooltipOrigin(win.edge, tile.width, tile.height, win.iconSize, tile.iconPx, win.indicatorArea, Tokens.dockTooltipGap, width, height, Tokens.dockPadding)
                                    x: at.x
                                    y: at.y
                                }

                                HoverHandler {
                                    id: tileHover
                                    parent: hit
                                    onHoveredChanged: {
                                        if (VisualFixtures.active && leftTap.pressed)
                                            console.info("dock-launch: hover-while-pressed", hovered, Date.now());
                                        if (hovered) {
                                            hoverHoldTimer.stop();
                                            tile.hoverHeld = true;
                                        } else {
                                            hoverHoldTimer.restart();
                                            tile.tipSuppressed = false;
                                        }
                                    }
                                    enabled: !tile.isSeparator
                                    cursorShape: Qt.ArrowCursor
                                }

                                Timer {
                                    id: hoverHoldTimer
                                    interval: Tokens.dockHoverHold
                                    onTriggered: tile.hoverHeld = false
                                }

                                // Files dropped on the Trash tile (from the desktop icons or any
                                // application offering text/uri-list) are moved to the trash.
                                DropArea {
                                    id: trashDrop
                                    x: hit.x
                                    y: hit.y
                                    width: hit.width
                                    height: hit.height
                                    enabled: tile.isTrash
                                    keys: ["text/uri-list"]
                                    onDropped: drop => {
                                        drop.accept(Qt.MoveAction);
                                        const paths = Icons.parseUriList(drop.getDataAsString("text/uri-list"));
                                        if (paths.length > 0)
                                            Apps.runHelper(["gio", "trash", "--"].concat(paths)); // isolated trash in dev (ADR-0011)
                                    }
                                }

                                // Drop highlight on the Trash tile.
                                Rectangle {
                                    visible: tile.isTrash && trashDrop.containsDrag
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                    radius: win.dockMetrics.iconRadius * tile.tileScale
                                    color: Appearance.withAlpha(Appearance.colors.accent, Tokens.desktopIconSelectionOpacity)
                                }

                                // Files dropped on an app tile are opened with that app.
                                DropArea {
                                    id: appDrop
                                    x: hit.x
                                    y: hit.y
                                    width: hit.width
                                    height: hit.height
                                    enabled: tile.isApp && !!tile.modelData.entry
                                    keys: ["text/uri-list"]
                                    // The tile highlights and accepts only a document its app can open (file field code
                                    // in Exec and a matching MimeType). The real type of every path (a folder may carry an extension)
                                    // is looked up while hovering (Apps.hoverEnter, cached for the drag): until it is known the tile
                                    // accepts without highlighting, once known a refused file is refused at the DnD level too (the source
                                    // gets a cancel). A source that hands its URI list over only at the drop leaves the verdict unknown.
                                    property var paths: []
                                    readonly property string verdict: paths.length === 0 ? "unknown" : Apps.hoverVerdict(tile.modelData.entry, paths)
                                    readonly property bool acceptable: verdict === "yes" || verdict === "unknown"
                                    function read(drag: var): void {
                                        if (paths.length > 0)
                                            return;
                                        const found = Icons.parseUriList(drag.getDataAsString("text/uri-list"));
                                        if (found.length === 0)
                                            return;
                                        paths = found;
                                        Apps.hoverEnter(tile.modelData.entry, found);
                                    }
                                    onEntered: drag => {
                                        paths = [];
                                        read(drag);
                                        drag.accepted = verdict !== "no";
                                    }
                                    onPositionChanged: drag => {
                                        read(drag);
                                        drag.accepted = verdict !== "no";
                                    }
                                    onExited: {
                                        paths = [];
                                        Apps.hoverLeave();
                                    }
                                    onDropped: drop => {
                                        const found = Icons.parseUriList(drop.getDataAsString("text/uri-list"));
                                        paths = [];
                                        if (found.length > 0 && Apps.dropOnApp(tile.modelData.entry, found))
                                            drop.accept(Qt.CopyAction);
                                        else
                                            drop.accepted = false;
                                    }
                                }

                                Rectangle {
                                    visible: tile.isApp && appDrop.containsDrag && appDrop.acceptable && appDrop.verdict !== "pending"
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    x: tile.iconPos.x
                                    y: tile.iconPos.y
                                    radius: win.dockMetrics.iconRadius * tile.tileScale
                                    color: Appearance.withAlpha(Appearance.colors.accent, Tokens.dockDropHighlightOpacity)
                                }

                                // Drag to reorder; dragged far above the shelf it leaves the Dock (poof).
                                DragHandler {
                                    id: dragHandler
                                    parent: hit
                                    enabled: tile.isApp && !tile.isFiles
                                    target: null
                                    cursorShape: Qt.ClosedHandCursor
                                    // The one positive release signal: the exclusive grab ends with a Released event point (state 8,
                                    // QEventPoint::Released). A cancelled or stolen grab, or an `active` change alone, is not a release
                                    // and marks the drag interrupted. When something takes the pointer during the drag Qt ends it with
                                    // a synthesized release that looks real: only win.dragInterrupted (events) tells it apart.
                                    onGrabChanged: (transition, point) => {
                                        if (win.dragFrom !== tile.index)
                                            return;
                                        if (transition === PointerDevice.UngrabExclusive && point.state === 8)
                                            win.releasedOutside = Geometry.dragOutward(win.edge, point.scenePosition.x - point.scenePressPosition.x, point.scenePosition.y - point.scenePressPosition.y) > win.dragOutReach;
                                        else if (transition === PointerDevice.CancelGrabExclusive || transition === PointerDevice.UngrabExclusive)
                                            win.dragInterrupted = true;
                                    }
                                    onActiveChanged: {
                                        if (active) {
                                            // A press that is already interrupted (it opened the hold menu, or a surface, popup, window or focus
                                            // event came since the button went down) does not become a drag: nothing moves, no gap opens, the
                                            // tooltip stays, the release changes no pin. The decision is taken here, from per-press state
                                            // (tile.menuByHold, root.dragInterruptions against the mark taken at the press), not from an enabled
                                            // flag or from leftTap.pressed: the tap handler cancels at the drag threshold, which would
                                            // re-enable a handler guarded by it within the same event. win.dragFrom stays -1.
                                            if (!tile.ownsPress) {
                                                if (VisualFixtures.active)
                                                    console.info("dock-launch: drag-refused", "not-owner", Date.now());
                                                return;
                                            }
                                            if (tile.menuByHold || root.dragInterruptions !== tile.dragMark) {
                                                if (VisualFixtures.active)
                                                    console.info("dock-launch: drag-refused", tile.menuByHold ? "hold-menu" : "interrupted", Date.now());
                                                return;
                                            }
                                            win.releasedOutside = false;
                                            win.dragInterrupted = false;
                                            if (VisualFixtures.active)
                                                console.info("dock-launch: drag-start", Date.now());
                                            win.dragSnap = false;
                                            win.dragFrom = tile.index;
                                            win.dragDx = 0;
                                            win.dragDy = 0;
                                        } else if (win.dragFrom === tile.index) {
                                            // One turn of the event loop later: the grab transition can be reported after the deactivation.
                                            const idx = tile.index;
                                            Qt.callLater(() => {
                                                if (win.dragFrom === idx)
                                                    win.finishDrag(tile);
                                            });
                                        }
                                    }
                                    onTranslationChanged: {
                                        if (active && win.dragFrom === tile.index) {
                                            // Never beyond the point where the "Remove" label would leave the window (away from the screen edge).
                                            const room = Geometry.crossSize(win.edge, win.width, win.height) - Tokens.dockBottomMargin - Tokens.dockPadding - win.indicatorArea - Math.max(tile.iconPx, win.iconSize + Tokens.dockPadding) - Tokens.dockTooltipGap - (win.vertical ? tooltip.width : tooltip.height);
                                            const drag = Geometry.dragVector(win.edge, Geometry.dragMain(win.edge, translation.x, translation.y), Math.min(Geometry.dragOutward(win.edge, translation.x, translation.y), room));
                                            win.dragDx = drag.x;
                                            win.dragDy = drag.y;
                                        }
                                    }
                                }

                                TapHandler {
                                    id: leftTap
                                    parent: hit
                                    enabled: !tile.isSeparator
                                    acceptedButtons: Qt.LeftButton
                                    // macOS: a press held past Tokens.dockMenuHold opens the Dock menu and its release launches nothing; a
                                    // shorter press is a click; a press that turns into a drag is a drag (the drag cancels this handler).
                                    // Only a tile with a Dock menu (apps and Files, the same as a right click) takes the hold; the others
                                    // (Apps, Trash, minimized windows) keep the click on release however long the button is held, as before.
                                    longPressThreshold: tile.isApp ? Tokens.dockMenuHold / 1000 : Tokens.dockClickHoldLimit
                                    // The label goes away on the press and stays away until the pointer leaves the tile.
                                    onPressedChanged: {
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: pressed", pressed, Date.now());
                                        // Auto-hide inhibitor: a press (and hold) in progress on this tile.
                                        win.pressedTile = pressed ? tile.index : (win.pressedTile === tile.index ? -1 : win.pressedTile);
                                        if (pressed) {
                                            tile.ownsPress = win.tileOwningPress(leftTap.point.scenePosition) === tile.index;
                                            tile.tipSuppressed = true;
                                            tile.menuByHold = false;
                                            tile.pressMark = root.clickCancels;
                                            tile.pressCancelled = false;
                                            tile.pressTime = Date.now();
                                            tile.dragMark = root.dragInterruptions;
                                            if (root.forceHoldMenu && tile.isApp)
                                                win.markHoldMenu(tile.index);
                                            if (root.forceInterrupt && tile.isApp)
                                                root.interruptDrag();
                                        }
                                    }
                                    onCanceled: {
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: canceled", Date.now());
                                        tile.pressCancelled = true;
                                    }
                                    onGrabChanged: (transition, point) => {
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: grab", transition, point.state, Date.now());
                                        if (transition === PointerDevice.CancelGrabExclusive || transition === PointerDevice.CancelGrabPassive)
                                            tile.pressCancelled = true;
                                    }
                                    onLongPressed: if (tile.isApp && tile.ownsPress) {
                                        tile.menuByHold = true;
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: menu-by-hold", Date.now());
                                        Popups.withPointer(true, () => win.openMenu(tile.index));
                                    }
                                    onTapped: {
                                        if (tile.menuByHold || !tile.ownsPress)
                                            return;
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: tapped", tile.modelData.key !== undefined ? tile.modelData.key : tile.modelData.kind, Date.now());
                                        // Press taken away from the Dock (a shell surface or popup opened, the lock, or Qt cancelled it; see root.clickCancels): nothing happens.
                                        if (root.clickCancels !== tile.pressMark || tile.pressCancelled) {
                                            if (VisualFixtures.active)
                                                console.info("dock-launch: tap-refused-interrupted", Date.now());
                                            return;
                                        }
                                        // A window OPENED during the press and the release follows it at once: Qt ended the press.
                                        if (root.lastWindowEvent >= tile.pressTime && Date.now() - root.lastWindowEvent < Tokens.dockClickWindowGuard) {
                                            if (VisualFixtures.active)
                                                console.info("dock-launch: tap-refused-window-event", Date.now());
                                            return;
                                        }
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: tap", Date.now(), "tile", tile.tileId);
                                        // A click: a stack or menu it opens shows its ring only after a key (ADR-0039 steps 8 and 25).
                                        Popups.withPointer(true, () => root.activateItem(tile.modelData, true));
                                    }
                                }

                                TapHandler {
                                    parent: hit
                                    enabled: tile.isApp || tile.isTrash || tile.isFolder
                                    acceptedButtons: Qt.RightButton
                                    // macOS: a secondary click opens the Dock menu on the press, however long the button is held.
                                    onPressedChanged: if (pressed && win.tileOwningPress(point.scenePosition) === tile.index) {
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: menu-by-right-press", Date.now());
                                        Popups.withPointer(true, () => win.openMenu(tile.index));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
