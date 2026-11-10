pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland // layering-exception: GF-087
import Grassfield.Ui
import qs.platform
import qs.services
import "V2.js" as V2

// Overview controller (spec docs/specs/overview.md): owns the open state, the IPC target and, with the compositor
// capability `overview` (v2), the conversation with grassfield-compositor; OverviewWindow renders it (one chrome
// overlay per screen) and OverviewBackdrop dims the desktop (Bottom layer, v2 only).
//
// v1 draws thumbnails of the windows (ScreencopyView). v2 lets the compositor transform the real windows live
// (Shell contract in the spec): the chrome is mapped and holds the keyboard (Exclusive) first, then the layout is sent
// with `overview(json)`; the plugin's events say what happened. Refused request, plugin loss, a full-screen window or
// no capability: thumbnails for that open (`thumbnailMode`, the one branch point).
Scope {
    id: root

    // Single lifecycle value (V2.keyboardPlan / V2.keysEnabled): "closed" | "open" | "releasing". `open` and
    // `releasing` derive from it, so no state between releasing and closed can read as open.
    property string stage: "closed"
    readonly property bool open: stage !== "closed"
    // The window that had the keyboard when the overview opened ({address, workspaceId}, null for none, or when the
    // desktop had it): a close without a chosen window returns to it (macOS: leaving Mission Control without choosing
    // brings back the window and the Desktop you were on).
    property var previous: null
    readonly property string previousAddress: previous && previous.address ? previous.address : ""
    // A Desktop created with "+" while open (the shell switched to it): closing without a choice stays there.
    property int stayOnSpace: 0

    // v2 branch point: false while the compositor transforms the real windows. Thumbnails when the plugin has no
    // `overview` feature (now or at the time of this open), or when this open fell back (refusal, full-screen window,
    // chrome not holding the keyboard in time).
    property bool thumbsThisOpen: !Capabilities.has("overview")
    readonly property bool thumbnailMode: thumbsThisOpen || !Capabilities.has("overview")
    // Plugin side state seen through its events: idle | opening | open | closing.
    property string phase: "idle"
    // The layout was sent (on:true) and no close was sent since: the windows may be transformed.
    property bool live: false
    // A chrome surface holds the keyboard (reported by OverviewWindow); the plugin refuses on:true without it.
    property var chromeActive: ({})
    readonly property bool chromeHeld: Object.keys(chromeActive).some(k => chromeActive[k])
    // The shell itself switched Space while open ("+"): the plugin ends the overview then, the chrome stays.
    property bool switchingSpace: false
    property int retries: 0
    readonly property int durationMs: Appearance.reduceMotion ? 0 : Tokens.motionSlow
    // Settings material.profile: full | balanced | reduced.
    readonly property string profile: Settings.materialProfile
    // full: live capture. balanced: ScreencopyView has no rate control, so single frames are
    // requested every overviewBalancedIntervalMs. reduced: one snapshot per window when opening.

    Binding {
        target: Compositor
        property: "refreshOnEvents"
        value: root.open
    }

    // The session lock owns the screen and the keyboard (set from shell.qml): nothing is focused by the shell, and an
    // open overview closes without a request.
    property bool locked: false
    onLockedChanged: {
        if (locked)
            requestCloseForOther();
    }

    // Selection, one for all outputs (OverviewWindow reads it): a window address ("" none) and, with the keyboard in the
    // Spaces bar of the output `spaceScreen`, the tile index (-1 while the windows have it).
    property string selected: ""
    property int spaceFocus: -1
    property string spaceScreen: ""
    // Keyboard in the minimized strip of the output `minScreen`: the tile index (-1 while the windows have it).
    property int minFocus: -1
    property string minScreen: ""
    // The minimized window to restore once the overview has closed (a click or Return on a tile of the strip).
    property var restoreAfter: null

    function show(): void {
        // Nothing opens over the lock screen (GF-116): CTRL+UP, a screen corner, the swipe and IPC alike.
        if (open || SessionState.refuses("overview"))
            return;
        if (locked) {
            console.info("grassfield: overview refused: the session is locked");
            return;
        }
        FocusReturn.cancelFallback();
        previous = DesktopState.holdsKeyboard ? null : Compositor.activeWindow();
        selected = "";
        spaceFocus = -1;
        spaceScreen = "";
        minFocus = -1;
        minScreen = "";
        restoreAfter = null;
        stayOnSpace = 0;
        Compositor.refreshSpaces();
        phase = "idle";
        live = false;
        retries = 0;
        switchingSpace = false;
        // A full-screen window on a shown Space cannot be transformed (and stops the others of its Space being
        // transformed): thumbnails for this open.
        thumbsThisOpen = !Capabilities.has("overview") || fullscreenShown();
        stage = "open";
        if (!thumbsThisOpen)
            chromeWait.restart();
    }

    function hide(): void {
        closeV2();
        chromeWait.stop();
        retryTimer.stop();
        releaseTimer.stop();
        releaseBound.stop();
        testReleaseHold.stop();
        keepScreen = "";
        pending = null;
        stage = "closed";
    }

    function fullscreenShown(): bool {
        for (let i = 0; i < Quickshell.screens.length; i++) {
            const list = Compositor.windowsOn(Quickshell.screens[i].name, Compositor.topologyRevision);
            if (list.some(w => w.fullscreen))
                return true;
        }
        return false;
    }

    // ---- v2: the conversation with grassfield-compositor ----

    function curve(): var {
        return Tokens.motionCurveStandard.slice(0, 4);
    }

    // Layout rectangles (layout coordinates) of every output's windows, from the shell's own layout.
    function layoutWindows(): var {
        const out = [];
        const all = windows.instances;
        for (let i = 0; i < all.length; i++)
            all[i].v2Rects().forEach(r => out.push(r));
        return out;
    }

    // Sends the layout (open, or retarget while open). Only once a chrome holds the keyboard.
    function sendLayout(): void {
        if (!open || thumbnailMode || releasing || !chromeHeld || closing)
            return;
        const list = layoutWindows();
        if (list.length === 0)
            return;
        live = Compositor.overview({
            on: true,
            durationMs: durationMs,
            curve: curve(),
            windows: list
        });
        chromeWait.stop();
    }

    // The layout changed while open (window opened, closed, moved to a Space): the plugin continues from where each
    // window is drawn.
    function layoutChanged(): void {
        if (open && live)
            Qt.callLater(sendLayout);
    }

    property bool closing: false

    // on:false: the plugin animates back; the chrome may unmap right after.
    function closeV2(): void {
        if (closing || !live)
            return;
        closing = true;
        Compositor.overview({
            on: false,
            durationMs: durationMs,
            curve: curve()
        });
        live = false;
    }

    function fallbackToThumbnails(): void {
        chromeWait.stop();
        if (live) {
            // Windows may be transformed: put them back at once, then thumbnails.
            Compositor.overview({
                on: false,
                durationMs: 0
            });
            live = false;
        }
        thumbsThisOpen = true;
    }

    function onChromeChanged(screenName: string, active: bool): void {
        const next = Object.assign({}, chromeActive);
        next[screenName] = active;
        chromeActive = next;
    }

    onChromeHeldChanged: {
        if (chromeHeld && open && !thumbnailMode && !live)
            sendLayout();
        // The keyboard moved between chromes while releasing: wait again for the ones still to commit.
        if (releasing) {
            releaseSettled = false;
            releaseTimer.restart();
        }
    }
    onOpenChanged: {
        if (open) {
            closing = false;
            FocusReturn.opened("overview");
        } else {
            // The Overview names its own focus target (closeAnd), so the shared return has nothing to add.
            FocusReturn.closed("overview", false);
        }
    }

    Binding {
        target: FocusReturn
        property: "locked"
        value: root.locked
    }

    // The chrome did not get the keyboard in time: the plugin would refuse, show thumbnails.
    Timer {
        id: chromeWait
        interval: Tokens.overviewChromeWaitMs
        onTriggered: {
            if (root.open && !root.live && !root.thumbnailMode)
                root.fallbackToThumbnails();
        }
    }

    // One retry of a request refused with no-chrome (another output's Exclusive commit may lag).
    Timer {
        id: retryTimer
        interval: Tokens.overviewChromeRetryMs
        onTriggered: root.sendLayout()
    }

    function onPluginEvent(event: var): void {
        const d = V2.decide(phase, open, event);
        phase = d.phase;
        if (d.retry) {
            if (retries < 1) {
                retries++;
                live = false;
                retryTimer.restart();
            } else {
                fallbackToThumbnails();
            }
        }
        if (d.fallback)
            fallbackToThumbnails();
        // Ended without the shell's on:false. After "+" the shell switched Space itself: the chrome stays.
        if (d.close && !switchingSpace) {
            live = false;
            closing = true;
            // The plugin ended the overview itself (a Desktop switch, the lock): the same close as every other, so the
            // chromes release their keyboard in order and the focus request goes out, naming the Desktop focused now (a
            // user's switch must survive Hyprland refocusing the window that was active at open). When the release is
            // already running (the keyboard leaving the chrome ends the plugin's overview too) that close is carried on.
            if (stage === "open")
                closeAnd({
                    kind: "ended",
                    workspace: Compositor.focusedWorkspace ? Compositor.focusedWorkspace.id : 0
                });
        } else if (d.close) {
            live = false;
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name !== "grassfield")
                return;
            const parsed = V2.parseEvent(event.data);
            if (parsed)
                root.onPluginEvent(parsed);
        }
    }

    // Restart (Shell contract 7): after every capabilities event, with no overview open, make sure the plugin has none
    // either (idempotent: a closed overview answers `closed`).
    Connections {
        target: Capabilities

        function onFeaturesChanged(): void {
            root.resetPluginOverview();
        }
    }

    function resetPluginOverview(): void {
        if (!root.open && Capabilities.has("overview"))
            Compositor.overview({
                on: false,
                durationMs: 0
            });
    }

    // Built after "started" (shell.qml, ADR-0056 amendment), this surface can miss the capabilities event that announced the
    // plugin: the same reset runs once on arrival (idempotent).
    Component.onCompleted: root.resetPluginOverview()

    // True between releasing the exclusive keyboard grab and the pending action.
    readonly property bool releasing: stage === "releasing"
    // Output whose chrome is kept Exclusive during the first part of the release (the holder, released last).
    property string keepScreen: ""
    // Keyboard mode of every output's chrome (V2.keyboardPlan): all Exclusive while open; releasing: all None but the
    // holder, then all None.
    readonly property var keyboardPlan: V2.keyboardPlan(Quickshell.screens.map(s => s.name), stage, keepScreen)
    // The focus target of the close in progress (V2.closeTarget) and whether the plugin was given it.
    property var pending: null
    property bool focusViaPlugin: false

    // Close Overview, then focus something (docs/specs/overview.md "Close focus"). `choice` is what the user did (see
    // V2.closeTarget): a window, a Desktop, nothing (null: Esc, toggle, backdrop), or "ended" / "other" (the plugin ended
    // the overview; another surface takes the keyboard). The target is worked out once, at the start:
    //  - with the plugin capability `overview-focus` ONE request goes out now, before the chromes drop to None; the
    //    compositor waits for the last Exclusive layer and focuses (no shell focus action, no race with the layers);
    //  - without it the shell focuses after the chromes are released and checks the result (retryFocus).
    // Each output's chrome commits its keyboard mode on its own, so the order is: every chrome but the holder drops to
    // None; after the settle pause the holder drops too; the close waits until no chrome reports the keyboard and the
    // settle pause has passed again (V2.releaseDone, bounded by releaseBound); then on:false is sent and the chromes hide.
    property bool releaseSettled: false

    function closeAnd(choice: var): void {
        if (stage !== "open")
            return;
        restoreAfter = choice && choice.kind === "minimized" ? choice.toplevel : null;
        const target = V2.closeTarget(choice, previous, stayOnSpace);
        focusViaPlugin = target.kind !== "skip" && !locked && Capabilities.has("overview-focus") && Compositor.overviewFocus(target);
        // A window chosen brings its tile group forward (TL29), sent after its focus request as from the other entry points.
        if (target.kind === "window" && !locked)
            Compositor.groupForward(target.address);
        pending = target;
        releaseSettled = false;
        keepScreen = holderScreen();
        stage = "releasing";
        releaseTimer.restart();
        releaseBound.restart();
        testReleaseHoldMs = testReleaseHoldNext; // dev hook, armed for this close only
        testReleaseHoldNext = 0;
    }

    // Output of the chrome that holds the keyboard ("" for none).
    function holderScreen(): string {
        return Object.keys(chromeActive).find(k => chromeActive[k]) || "";
    }

    function tryFinishRelease(forced: bool): void {
        if (testReleaseHold.running)
            return;
        if (releasing && testReleaseHoldMs > 0 && (forced || !chromeHeld)) {
            // Dev hook: the release would end now; it stays in its "releasing" stage that much longer.
            testReleaseHold.interval = testReleaseHoldMs;
            testReleaseHoldMs = 0;
            testReleaseHold.restart();
            return;
        }
        if (releasing && V2.releaseDone(chromeHeld, releaseSettled, forced))
            finishRelease();
    }

    function finishRelease(): void {
        releaseTimer.stop();
        releaseBound.stop();
        keepScreen = "";
        const target = pending;
        const viaPlugin = focusViaPlugin;
        try {
            closeV2();
        } finally {
            hide();
        }
        if (!viaPlugin && !locked)
            FocusReturn.startFallback(target, 0);
        // A minimized window chosen in the strip comes back to the current Desktop and takes the focus, its tile group coming
        // forward with it (the same call as a click on its Dock tile), once the chromes have let go of the keyboard.
        const restore = restoreAfter;
        restoreAfter = null;
        if (restore && !locked)
            Compositor.unminimizeWithGroup(restore);
    }

    // Without the plugin capability the focus, check and retry run in FocusReturn.startFallback (shared with the Exclusive
    // surfaces; it stops when the user acted or another surface opened).

    // ---- Selection (one for all outputs) ----

    function windowOf(address: string): var {
        return windows.instances.find(w => w.winKeys.indexOf(address) >= 0) ?? null;
    }

    function hoverSelect(address: string): void {
        spaceFocus = -1;
        minFocus = -1;
        selected = address;
    }

    // Arrow keys. Nothing selected: the window that was active at open (macOS), wherever it is. Otherwise the neighbour
    // on that output, else the window entered on the output lying that way; up with nothing above enters the Desktops bar.
    function arrow(dir: string): void {
        const all = windows.instances;
        if (minFocus >= 0) {
            // In the minimized strip: Left and Right move along it, Up returns to the windows.
            const owner = all.find(w => w.screenName === minScreen);
            if (dir === "up" || !owner) {
                minFocus = -1;
            } else if (dir === "left" || dir === "right") {
                minFocus = Math.max(0, Math.min(minFocus + (dir === "left" ? -1 : 1), owner.minimizedItems.length - 1));
            }
            return;
        }
        if (spaceFocus >= 0) {
            const owner = all.find(w => w.screenName === spaceScreen);
            if (dir === "down") {
                spaceFocus = -1;
            } else if ((dir === "left" || dir === "right") && owner) {
                spaceFocus = Math.max(0, Math.min(spaceFocus + (dir === "left" ? -1 : 1), owner.tiles.length - 1));
            }
            return;
        }
        // Nothing selected: with a window active at open the ring is on it, so the first arrow starts from it and
        // moves to its neighbour (macOS); selecting that same window would change nothing visible. With no active
        // window (the desktop held the keyboard) there is no ring: the first arrow selects the first window in
        // reading order and stays on it.
        if (selected === "") {
            const screens = all.map(w => ({
                        name: w.screenName,
                        addresses: w.winKeys,
                        rects: w.placement.rects
                    }));
            const start = V2.startSelection(previous, screens);
            if (start === "" || !windowOf(start))
                return;
            selected = start;
            if (!V2.startFromActive(previous, screens))
                return;
        }
        const owner = windowOf(selected);
        if (!owner)
            return;
        const next = owner.neighborOf(selected, dir);
        if (next !== "") {
            selected = next;
            return;
        }
        // Down from the last row: the minimized strip of that output (macOS: the windows below the divider).
        if (dir === "down" && owner.minimizedItems.length > 0) {
            minScreen = owner.screenName;
            minFocus = 0;
            return;
        }
        if (dir === "up") {
            if (owner.tiles.length > 0) {
                spaceScreen = owner.screenName;
                spaceFocus = owner.activeTileIndex();
            }
            return;
        }
        const toName = V2.adjacentScreen(all.map(w => ({
                    name: w.screenName,
                    x: w.modelData.x,
                    y: w.modelData.y,
                    w: w.modelData.width,
                    h: w.modelData.height
                })), owner.screenName, dir);
        const dest = toName === "" ? null : all.find(w => w.screenName === toName);
        const entry = dest ? dest.entryFor(dir, owner.crossFraction(selected, dir)) : "";
        if (entry !== "")
            selected = entry;
    }

    // Tab order: windows (-1), then each Desktop tile of the output holding the selection, then back to the windows.
    function cycle(step: int): void {
        minFocus = -1;
        const owner = spaceFocus >= 0 ? windows.instances.find(w => w.screenName === spaceScreen) : (windowOf(selected) ?? windows.instances[0]);
        if (!owner)
            return;
        let next = spaceFocus + step;
        if (next >= owner.tiles.length || next < -1)
            next = step > 0 ? -1 : owner.tiles.length - 1;
        spaceScreen = owner.screenName;
        spaceFocus = next;
    }

    function activateSelection(): void {
        if (minFocus >= 0) {
            const owner = windows.instances.find(w => w.screenName === minScreen);
            if (owner) {
                owner.activateMinimized(minFocus);
                return;
            }
        }
        if (spaceFocus >= 0) {
            const owner = windows.instances.find(w => w.screenName === spaceScreen);
            if (owner) {
                owner.activateTile(spaceFocus);
                return;
            }
        } else {
            // Nothing chosen yet: Return takes the window the ring shows, the one active at open.
            const key = selected !== "" ? selected : previousAddress;
            const owner = key !== "" ? windowOf(key) : null;
            if (owner) {
                owner.activateWindow(key);
                return;
            }
        }
        // Nothing the ring could show (no window was active at open, or it is gone, or the Desktops bar owner is gone):
        // Return closes, as Esc does (macOS: Return with nothing chosen leaves Mission Control). Before this it did
        // nothing, and the next Return was the one that closed.
        closeAnd(null);
    }

    Timer {
        id: releaseTimer
        interval: Tokens.overviewReleaseSettleMs
        onTriggered: {
            if (root.keepScreen !== "") {
                // The other chromes have committed: release the holder, then wait for it.
                root.keepScreen = "";
                root.releaseSettled = false;
                releaseTimer.restart();
                return;
            }
            root.releaseSettled = true;
            root.tryFinishRelease(false);
        }
    }

    Timer {
        id: releaseBound
        interval: Tokens.overviewReleaseBoundMs
        onTriggered: root.tryFinishRelease(true)
    }

    // Dev-only test hook (holdNextRelease): the next close, when its release would end (the chromes let go of the keyboard,
    // or the bound), stays "releasing" this much longer, then finishes as the bound would. 0: no hold (always, outside a
    // nested dev session).
    property int testReleaseHoldNext: 0
    property int testReleaseHoldMs: 0

    Timer {
        id: testReleaseHold
        onTriggered: root.tryFinishRelease(true)
    }

    // Close because another full-attention surface opened (ExclusiveSurfaces): the keyboard belongs to that surface, so
    // nothing is focused here.
    function requestCloseForOther(): void {
        if (stage === "open")
            closeAnd({
                kind: "other"
            });
    }

    // Close from outside (IPC, shortcut): same path as Esc, the keyboard is released before the close completes.
    function requestClose(): void {
        if (stage === "open")
            closeAnd(null);
    }

    function toggle(): void {
        if (open)
            requestClose();
        else
            show();
    }

    // IPC: qs ipc call overview <toggle|open|close|status>. CTRL+UP calls toggle().
    // False while shell.qml's `early` handler answers for this target (a surface built by its LazyLoader, ADR-0056
    // amendment): two handlers for one target warn and only one is used, so the loader switches them over in order.
    property bool ipcEnabled: true

    IpcHandler {
        target: "overview"
        enabled: root.ipcEnabled

        function toggle(): void {
            root.toggle();
        }

        function open(): void {
            root.show();
        }

        function close(): void {
            root.requestClose();
        }

        // Dev-only test hook (GRASSFIELD_DEV=1 in a nested dev session; tests/compositor/click_focus.sh): the next close stays
        // in its "releasing" stage at least `ms` (1 to 10000), so that a click during the release can be tested. Refused
        // otherwise.
        function holdNextRelease(ms: int): string {
            if (!VisualFixtures.dev || ms < 1 || ms > 10000)
                return "refused";
            root.testReleaseHoldNext = ms;
            return "held";
        }

        // Test hook (dev session only, VisualFixtures.dev, SEC-04; tiling step 6e, the follow-up of #78): window `address`
        // dropped on Desktop `spaceId` by the open Overview's own drop path (OverviewWindow.dropWindow, ADR-0036 D72): "moved",
        // "refused", or "absent" when no output's Overview shows both.
        function dropProbe(address: string, spaceId: int): string {
            if (!VisualFixtures.dev)
                return "refused";
            const all = windows.instances;
            for (let i = 0; i < all.length; i++) {
                const result = all[i].probeDrop(address, spaceId);
                if (result !== "")
                    return result;
            }
            return "absent";
        }

        // Test hook (dev session only, VisualFixtures.dev, SEC-04): JSON {open, stage, thumbnailMode, profile,
        // screens: [{name, windows: [{address, appId, title, real, rect}], spaces, selected}]}. Rects are window-local pixels.
        function status(): string {
            if (!VisualFixtures.dev)
                return "refused";
            const screens = [];
            const all = windows.instances;
            for (let i = 0; i < all.length; i++)
                screens.push(all[i].statusData());
            return JSON.stringify({
                open: root.open,
                stage: root.stage,
                thumbnailMode: root.thumbnailMode,
                phase: root.phase,
                live: root.live,
                chromeHeld: root.chromeHeld,
                profile: root.profile,
                screens: screens
            });
        }
    }

    OverviewBackdrop {
        controller: root
    }

    OverviewWindow {
        id: windows
        controller: root
    }
}
