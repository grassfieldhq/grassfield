pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.lib
import qs.services // layering-exception: GF-087
import "Minimized.js" as Minimized
import "QuickLook.js" as QuickLook
import "ShowDesktop.js" as ShowDesktop
import "ScreenChoice.js" as ScreenChoice
import "SpaceGeometry.js" as SpaceGeometry
import "showdesktop"
import "StagesFront.js" as StagesFront
import "WindowTiling.js" as WindowTiling

// Compositor state and actions for the shell (master-prompt 5.2: the only place, together
// with Capabilities, that talks to the compositor). Event-driven; never polls hyprctl.
Singleton {
    id: root

    // Live toplevel list (foreign-toplevel protocol: reliable app ids, no title matching).
    readonly property var toplevels: ToplevelManager.toplevels
    readonly property var focusedToplevel: ToplevelManager.activeToplevel
    readonly property string focusedAppId: focusedToplevel ? focusedToplevel.appId : ""

    // Quick Look (Glance, platform/QuickLook.js) belongs to the app that opened it (macOS): while it has the focus the menu
    // bar and the app menus stay with the window that was in front before it. `regularToplevel` is the last focus that was not
    // a quick look. `front` is who was in front before it ("desktop" or "window", QuickLook.frontAfter): a quick look opened from the
    // desktop belongs to the desktop. Anything that acts on the focused window keeps using focusedToplevel.
    readonly property bool quickLookFocused: !!focusedToplevel && QuickLook.isQuickLook(focusedToplevel.appId)
    readonly property bool quickLookOpen: {
        const list = toplevels ? toplevels.values : [];
        return list.some(t => QuickLook.isQuickLook(t.appId));
    }
    property var regularToplevel: null
    property string front: "window"
    // A quick look is open (focused or not, a shell popup may hold the keyboard) and the desktop is what it belongs to.
    readonly property bool quickLookFromDesktop: front === "desktop" && (quickLookFocused || quickLookOpen)
    readonly property var frontToplevel: {
        if (!quickLookFocused)
            return focusedToplevel;
        if (front === "desktop")
            return null;
        const list = toplevels ? toplevels.values : [];
        return regularToplevel && list.indexOf(regularToplevel) >= 0 ? regularToplevel : null;
    }
    readonly property string frontAppId: frontToplevel ? frontToplevel.appId : ""

    // Last Stages state (StagesFront.parse of the reply StagesLink fetched: the `stages` event is only a change notice) or
    // null (Stages off, not active, or its state unknown). Set by applyStagesState only.
    property var stagesState: null
    // Window class the bar names while Hyprland has no active window under Stages (an Exclusive layer holds the keyboard
    // after a swap): the front app of the last Stages state while its window still exists, else "". Display only: no
    // window has the keyboard. Never set with Stages off.
    readonly property string stagesFrontAppId: {
        const live = [];
        const list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < list.length; i++)
            live.push(list[i].address);
        return StagesFront.select(root.stagesState, !!root.focusedToplevel, Capabilities.pluginPresent, root.focusedScreenName, live);
    }

    // StagesLink hands over each Stages state it fetched (`hyprctl grassfield-stages`), "" when there is none.
    function applyStagesState(text: string): void {
        root.stagesState = text === "" ? null : StagesFront.parse(text);
    }

    readonly property var focusedWorkspace: Hyprland.focusedWorkspace
    // Outputs whose active workspace holds no window: glass over them sees only the wallpaper (services/Backdrop.qml, ADR-0024
    // G-3). Empty without Hyprland, and then every glass takes the worst case.
    readonly property var bareOutputs: Hyprland.monitors.values.filter(m => m.activeWorkspace && m.activeWorkspace.toplevels.values.length === 0).map(m => m.name)
    // Output with keyboard/pointer focus ("" when unknown): target of keyboard-driven shell UI.
    readonly property string focusedScreenName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    // Where a surface opens when nobody named an output (SUPER+N, IPC, keyboard): the active display, the first output only as
    // a last resort (ScreenChoice.js). Every such surface uses this one rule.
    readonly property string activeScreenName: ScreenChoice.pick("", focusedScreenName, Quickshell.screens.map(s => s.name))

    // A layer surface with this namespace was unmapped (`closelayer` event). The app switcher activates its target only
    // after its own exclusive surface is gone: Hyprland refuses to focus a window while one exists (FocusState.cpp).
    signal layerClosed(string namespace)

    // Something happened in the session that can take the pointer or the focus away from an interaction in progress (the Dock's
    // drag): a window opened or closed, another window, workspace or monitor became active, a monitor came or went, a layer
    // opened or closed (a surface unmapping hands the pointer back, whatever its client, shell banners included). Over-reporting is intended; `event` is the Hyprland event name.
    signal interrupted(string event)

    // A window asked for attention (Hyprland's `urgent` event, relayed here: only the platform layer reads compositor events).
    // `address` is lower-case hex without 0x. The Dock bounces the app's icon until the app is activated.
    signal attention(string address)

    // An application rang the bell (Hyprland's `bell` event, xdg-system-bell-v1: GTK 4's error bell); `address` is the
    // window's, lower-case hex without 0x, or "" (ADR-0047 B-5). Sounds plays the alert sound.
    signal bell(string address)

    // A window closed (Hyprland's `closewindow`), `address` lower-case hex without 0x. The clipboard history drops a paste
    // aimed at it: a new window can reuse the address (ADR-0034 §4).
    signal windowClosed(string address)

    // Address of a toplevel as Hyprland names it (lower-case hex without 0x), "" when Hyprland does not know it (yet).
    function addressOf(toplevel: var): string {
        const top = hyprlandToplevel(toplevel);
        return top ? Minimized.normalizeAddress(top.address) : "";
    }
    readonly property var interruptingEvents: ["openwindow", "closewindow", "movewindowv2", "activewindowv2", "workspacev2", "createworkspacev2", "destroyworkspacev2", "moveworkspacev2", "activespecialv2", "focusedmonv2", "monitoraddedv2", "monitorremovedv2", "openlayer", "closelayer", "fullscreen"]

    // Windows currently in the hidden-app workspace, as toplevel handles (see hiddenWindows).
    function isHidden(toplevel: var): bool {
        return hiddenWindows(0).some(w => w.toplevel === toplevel);
    }

    // Re-reads Hyprland's window list (pid and other IPC data are only fetched for windows that
    // existed at shell start or on this request). Call before showing data that needs the pid.
    function refreshToplevels(): void {
        Hyprland.refreshToplevels();
    }

    // Hyprland-side object of a foreign-toplevel handle (address, pid, workspace), or null.
    function hyprlandToplevel(toplevel: var): var {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].wayland === toplevel)
                return all[i];
        }
        return null;
    }

    // Client PID of a toplevel (from Hyprland's window data), 0 if unknown. Reactive: bindings
    // re-evaluate when refreshToplevels() delivers new data.
    function pidOf(toplevel: var): int {
        const top = hyprlandToplevel(toplevel);
        const data = top ? top.lastIpcObject : null;
        return data && data.pid ? data.pid : 0;
    }

    // The window of Wayland app id `appClass` whose xdg-toplevel tag (its ADR-0015 role: Hyprland's `xdgTag`) is `tag`, as a
    // toplevel handle, or null. From Hyprland's window data, which a window's opening has re-read (requestWindowRefresh):
    // Settings' About This Computer window (role "info", SettingsApp.openAbout).
    function taggedToplevel(appClass: string, tag: string): var {
        const tops = root.toplevels ? root.toplevels.values : [];
        for (let i = 0; i < tops.length; i++) {
            const top = hyprlandToplevel(tops[i]);
            if (Minimized.hasTag(top ? top.lastIpcObject : null, appClass, tag))
                return tops[i];
        }
        return null;
    }

    // The windows Hyprland reported, as {pid and cls (from its list: 0 and "" until it was read for that window), title (live,
    // from its events), idleInhibit (its list's inhibitingIdle)} (NotResponding, Activity Monitor's projection).
    function knownWindows(): var {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        return all.map(t => {
            const d = t.lastIpcObject;
            return {
                pid: d && d.pid ? d.pid : 0,
                cls: d && d.class ? d.class : "",
                title: t.title ?? "",
                idleInhibit: !!(d && d.inhibitingIdle === true)
            };
        });
    }

    // The toplevel handles Hyprland reported, in knownWindows()' order (AM61: the windows `activity quit` closes).
    function knownToplevels(): var {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        return all.map(t => t.wayland);
    }

    // Activate (focus, un-minimize) a toplevel through the protocol. A window parked by hide()
    // is first moved back to the focused workspace.
    function activate(toplevel: var): void {
        if (!toplevel)
            return;
        // Show Desktop ends: every window goes back first, then the chosen one gets the focus (both requests go through the
        // same dispatch channel, in this order, so the focus is not lost to the windows that are still moving).
        if (root.endShowDesktop()) {
            const chosen = hyprlandToplevel(toplevel);
            if (chosen)
                dispatchRequest(Minimized.focusWindowRequest(chosen.address));
        }
        if (isMinimized(toplevel)) {
            unminimize(toplevel);
            return;
        }
        const top = hyprlandToplevel(toplevel);
        if (top && top.workspace && (top.workspace.name === hiddenWorkspace || top.workspace.name === minimizedWorkspace) && root.focusedWorkspace)
            dispatchRequest(moveRequest(top.address, String(root.focusedWorkspace.id)));
        toplevel.activate();
    }

    // Activate once a shell layer surface is gone. Hyprland refuses to focus a window while an Exclusive layer surface exists
    // (the switcher waits for `closelayer` for the same reason), and a popup menu that is closing still has its surface for a
    // moment: a window chosen from a menu is activated, its tile group coming forward with it (TL29), when the compositor
    // reports `namespace` unmapped, or after Tokens.dockMenuLayerWait if that event never comes. One pending request at a
    // time (the latest wins).
    property var pendingActivation: null

    function activateAfterLayer(toplevel: var, namespace: string): void {
        if (!toplevel)
            return;
        pendingActivation = {toplevel: toplevel, namespace: namespace, members: null};
        layerWaitTimer.restart();
    }

    // The same for the Dock menu's Show Tile Group (showTileGroup): `members` the group's addresses.
    function showTileGroupAfterLayer(toplevel: var, namespace: string, members: var): void {
        if (!toplevel)
            return;
        pendingActivation = {toplevel: toplevel, namespace: namespace, members: members};
        layerWaitTimer.restart();
    }

    function runPendingActivation(): void {
        const p = pendingActivation;
        pendingActivation = null;
        layerWaitTimer.stop();
        // The lock engaged while the menu's surface went away (integrator review of cd74af2): nothing moves behind it.
        if (!p || SessionState.refuses("menu activation"))
            return;
        if (p.members)
            showTileGroup(p.toplevel, p.members);
        else
            activateWithGroup(p.toplevel);
    }

    Timer {
        id: layerWaitTimer
        interval: Tokens.dockMenuLayerWait
        onTriggered: root.runPendingActivation()
    }

    onLayerClosed: namespace => {
        if (pendingActivation && pendingActivation.namespace === namespace)
            runPendingActivation();
    }

    // Name of the special workspace used by hide().
    readonly property string hiddenWorkspace: "special:hidden"

    // Lua request moving a window ("" when the address or workspace is invalid: the single
    // validator lives in Minimized.js, so every caller is protected).
    function moveRequest(address: string, workspace: string): string {
        return Minimized.moveRequest(address, workspace);
    }

    // Dispatches a request built by the validating builders; "" (rejected input) is dropped.
    function dispatchRequest(request: string): bool {
        if (request === "")
            return false;
        Hyprland.dispatch(request);
        return true;
    }

    // Hide (macOS "Hide"): park the window on a special workspace nobody toggles.
    function hide(toplevel: var): void {
        const top = hyprlandToplevel(toplevel);
        if (top)
            dispatchRequest(moveRequest(top.address, hiddenWorkspace));
    }

    // ---- Minimize (ADR-0002, master-prompt 5.6) ----

    // Special workspace used by the fallback minimize (no plugin).
    readonly property string minimizedWorkspace: "special:minimized"
    // Windows minimized by the shell: [{toplevel, address, appId, title}] (see Minimized.js).
    property var minimized: []
    // Per-screen Docks by screen name: each Dock instance registers itself (an object with
    // tileRect(index, adding) -> {x, y, w, h} in global layout coordinates, or null) and unregisters
    // on destruction. There is one visible Dock at a time (macOS: on the output where the pointer last reached its
    // edge): the Dock publishes that output in `dockScreenName`, and a window animates toward that Dock.
    property var dockOwners: ({})
    property string lastDockRectProblem: ""
    property string dockScreenName: ""

    function registerDock(screenName: string, owner: var): void {
        root.dockOwners[screenName] = owner;
    }

    function unregisterDock(screenName: string, owner: var): void {
        if (root.dockOwners[screenName] === owner)
            delete root.dockOwners[screenName];
    }

    // Dock tile rectangle of the minimized slot `index` (on the Dock's screen, else on `screenName`) (`adding`: a tile that does not
    // exist yet, appended before the Trash). Empty ({0,0,0,0}) without a Dock there: the plugin then
    // hides/shows the window without animation.
    // With "minimize into application icon" (dock.minimizeIntoApp) the rectangle is the tile of the window's app.
    // `intoApp`: this window goes into its app's icon whatever the setting says (a minimize from a click on the app's tile).
    function dockRect(screenName: string, index: int, adding: bool, toplevel: var, intoApp: var): var {
        const owner = root.dockOwners[root.dockScreenName] || root.dockOwners[screenName];
        const rect = Minimized.finiteRect(owner ? owner.tileRect(index, adding, toplevel, intoApp === true) : null);
        if (!rect) {
            // The plugin then hides or shows the window without animation: say why (once per reason, not per call).
            const why = !owner ? "no Dock registered for " + (root.dockScreenName || screenName) + " (registered: " + Object.keys(root.dockOwners).join(",") + ")" : "the Dock of " + (root.dockScreenName || screenName) + " has no tile rectangle for slot " + index;
            if (why !== root.lastDockRectProblem) {
                root.lastDockRectProblem = why;
                console.warn("grassfield-shell: dockRect empty: " + why);
            }
        }
        return rect || {x: 0, y: 0, w: 0, h: 0};
    }

    // Name of the monitor a window is on ("" if unknown).
    function windowScreenName(top: var): string {
        return top && top.workspace && top.workspace.monitor ? top.workspace.monitor.name : "";
    }

    // Plugin minimize/restore call (gfc/1, ADR-0007) toward/from a Dock tile. Only validated hex
    // addresses and numbers are interpolated (Minimized.windowCall).
    function pluginWindowCall(verb: string, address: string, rect: var): string {
        return Minimized.windowCall(verb, address, rect);
    }

    // Minimize a window. With the plugin ("minimize" capability) the plugin hides it with an
    // animation toward the Dock; otherwise it is parked on special:minimized. Both use the same
    // hidden state, so the shell records it either way and rebuilds the record from it.
    function minimize(toplevel: var): bool {
        return doMinimize(toplevel, false);
    }

    // A click on an app's Dock tile: the window goes into the app icon, no tile is added, so the Dock does not move under the
    // pointer and the next click on the same spot brings it back. Other minimizes follow dock.minimizeIntoApp.
    function minimizeIntoAppIcon(toplevel: var): bool {
        return doMinimize(toplevel, true);
    }

    // Slot of a record among the minimized tiles the Dock shows (records minimized into the app icon have none).
    function tileSlot(rec: var): int {
        return root.minimized.filter(r => !r.intoApp).indexOf(rec);
    }

    function doMinimize(toplevel: var, intoApp: bool): bool {
        if (!toplevel || Minimized.has(root.minimized, toplevel))
            return false;
        // A window in full screen or a member of a Split View Desktop is not minimized (macOS; ADR-0036 D56, D61): the Window
        // menu greys Minimize, the plugin greys its light, and Super+M or a request does nothing.
        if (toplevel.fullscreen || root.inSplit(toplevel)) {
            console.info("grassfield: minimize refused: a window in full screen or on a Split View Desktop");
            return false;
        }
        const top = hyprlandToplevel(toplevel);
        const address = top ? Minimized.normalizeAddress(top.address) : "";
        if (address === "")
            return false;
        // Rectangle of the tile this window gets (appended after the existing minimized tiles),
        // computed before the list changes.
        const tile = dockRect(windowScreenName(top) || focusedScreenName, root.minimized.filter(r => !r.intoApp).length, true, toplevel, intoApp);
        root.minimized = Minimized.add(root.minimized, {toplevel: toplevel, address: address, appId: toplevel.appId, title: toplevel.title, screen: windowScreenName(top), intoApp: intoApp});
        if (Capabilities.has("minimize"))
            dispatchRequest(pluginWindowCall("minimize", address, tile));
        else
            dispatchRequest(moveRequest(address, minimizedWorkspace));
        return true;
    }

    // Restore a minimized window and focus it: back on the display it was minimized from, on the Desktop that display shows
    // now (owner decision D-1, macOS), never on the display of the Dock that was clicked. The plugin moves, focuses and
    // animates it itself (and gives its frame back); activating it here too would race the plugin (a focus request for a
    // window still on special:minimized opens that workspace).
    function unminimize(toplevel: var): void {
        const rec = root.minimized.find(r => r.toplevel === toplevel);
        if (!rec)
            return;
        // Restoring a window (Dock tile, Overview) is an activation: Show Desktop ends first, as in activate().
        root.endShowDesktop();
        const tile = dockRect(focusedScreenName, tileSlot(rec), false, toplevel, rec.intoApp === true);
        root.minimized = Minimized.remove(root.minimized, toplevel);
        if (Capabilities.has("minimize")) {
            dispatchRequest(pluginWindowCall("restore", rec.address, tile));
            return;
        }
        const monitors = (Hyprland.monitors ? Hyprland.monitors.values : []).map(m => ({name: m.name, workspace: m.activeWorkspace ? m.activeWorkspace.id : 0}));
        const workspace = Minimized.restoreWorkspace(rec.screen || "", monitors, root.focusedWorkspace ? root.focusedWorkspace.id : 0);
        if (workspace !== "")
            dispatchRequest(moveRequest(rec.address, workspace));
        toplevel.activate();
    }

    // ---- Plugin settings (gfc/1 `config`, allowlisted keys in Minimized.js) ----

    // Settings the titlebars honor; pushed after the capabilities handshake (and again on each
    // capabilities event, e.g. a reloaded plugin) and whenever they change. Fill (TL32) needs the plugin's arrangements
    // (feature "tiling-arrange"): without them the double-click zooms, the macOS default (ADR-0036 D36).
    readonly property string titlebarDoubleClick: Minimized.doubleClickAction(Settings.titlebarDoubleClick, Capabilities.has("tiling-arrange"))
    // The minimize animation (Settings dock.minimizeEffect); Reduce Motion replaces it with a quick fade in place, as
    // macOS does. Without the plugin the fallback minimize has no animation at all.
    readonly property string minimizeEffect: Settings.reduceMotion ? "fade" : Settings.dockMinimizeEffect
    // Window tiling (Desktop & Dock > Windows, docs/specs/tiling.md TL32; Settings windows.tiling*): the plugin tiles
    // titlebar drags at the edges, corners and menu bar, with Alt anywhere, with or without margins; it posts the green
    // button's hover and keeps the suggestion after an arrangement only while the switch is on (Minimized.tilingSwitches).
    // Every switch's value: a change pushes them again (the capabilities events push on their own). "Bring tile groups
    // forward together" is the shell's alone (groupForward): the plugin raises a group only when asked (ADR-0036 D38).
    readonly property var tilingConfig: Minimized.tilingConfigPairs(Settings, () => true)
    // "Suggest windows to fill the rest of a layout" (TL32): TilingLink drops a suggestion shown when it turns off.
    readonly property bool suggestionsOn: Settings.windowsTilingSuggestions

    // The appearance the shell shows: the compositor-drawn titlebars follow it (feature "appearance", audit UX-06).
    readonly property string chromeAppearance: Appearance.dark ? "dark" : "light"
    // Stages (Settings windows.stages, ADR-0013, owner decision D-4): the plugin's flag follows the setting while the plugin
    // offers Stages (feature "stages-available"; "stages" is then advertised while the flag is on, and the strip sends its
    // operations with stages() below). Off by default; the flag alone changes nothing on screen until the strip sends op:on.
    // Pushed when the setting changes and when stages-available appears (a plugin load starts with the flag off), not on
    // every capabilities event: the plugin re-posts its capabilities when the flag changes, and a push there would undo a
    // flag set by the nested Stages tests (tests/compositor/stages.sh, soak.sh, minimize.sh stages).
    readonly property string stagesFlag: Settings.windowsStages ? "true" : "false"
    readonly property bool stagesAvailable: Capabilities.has("stages-available")

    function pushStagesFlag(): void {
        if (root.stagesAvailable && dispatchRequest(Minimized.configCall("stagesEnabled", root.stagesFlag)))
            console.info("grassfield: compositor setting stagesEnabled =", root.stagesFlag);
    }

    // Reduce Motion also shortens what Hyprland animates itself: window pop-in and the Spaces slide become crossfades
    // (Minimized.motionCall). Applied whenever it changes, at every shell start (the compositor keeps what the previous shell
    // set), and after a config reload while it is on (the reload restores the config's own animations, which is already
    // right when it is off).
    readonly property bool reduceMotion: Settings.reduceMotion
    onReduceMotionChanged: pushMotion()

    function pushMotion(): void {
        console.info("grassfield-shell: push motion (reduced: " + root.reduceMotion + ")");
        dispatchRequest(Minimized.motionCall(root.reduceMotion));
    }

    // Blur follows the transparency (GF-125): the compositor holds one blur size and pass count for all surfaces, so the
    // shell sends the pair of the current transparency (Appearance.compositorBlur*). Sent at start, on every change
    // (debounced: a slider drag is one request per settle) and after a config reload, which restores the config's own
    // 18 / 3 (right at the default transparency).
    readonly property int blurSize: Appearance.compositorBlurSize
    readonly property int blurPasses: Appearance.compositorBlurPasses
    // A change of the value is a new request: it is tried again even after an error answer (once per change, never in a loop;
    // a config reload does not retry a refused request).
    onBlurSizeChanged: {
        root.blurRejected = false;
        blurDebounce.restart();
    }
    onBlurPassesChanged: {
        root.blurRejected = false;
        blurDebounce.restart();
    }

    // Hyprland answered a push with an error (a Hyprland that does not know the keys): nothing more is sent. The answer comes
    // on the request socket, one connection per push (Hyprland.dispatch does not return it).
    property bool blurRejected: false
    property int blurPushes: 0

    // The window edge follows the appearance (ADR-0039 step 6, C-4; ADR-0024 note 2026-11-03): macOS 27's contact edge is a dark
    // device pixel in both appearances, fainter in the light one (the dark appearance's light inner rim is left to the plugin).
    // Hyprland holds one border colour pair for every window, so the shell sends the pair of the current appearance as it
    // sends the blur: at start, on a change of appearance and after a config reload, which restores the config's own (the
    // dark appearance's, config/hypr/grassfield/looknfeel.lua).
    readonly property string edgeCall: Appearance.dark
        ? Minimized.edgeCall(Tokens.windowEdgeDark, Tokens.windowEdgeActiveOpacityDark, Tokens.windowEdgeInactiveOpacityDark)
        : Minimized.edgeCall(Tokens.windowEdgeLight, Tokens.windowEdgeActiveOpacityLight, Tokens.windowEdgeInactiveOpacityLight)
    onEdgeCallChanged: {
        root.edgeRejected = false;
        edgeDebounce.restart();
    }
    property bool edgeRejected: false
    property int edgePushes: 0

    function pushEdge(): void {
        const path = Hyprland.requestSocketPath || "";
        if (root.edgeRejected || root.edgeCall === "" || path === "")
            return;
        root.edgePushes++;
        console.info("grassfield-shell: push window edge (" + (Appearance.dark ? "dark" : "light") + ")");
        requestSocket.createObject(root, {"path": path, "line": "dispatch " + root.edgeCall, "what": "edge"});
    }

    function pushBlur(): void {
        const call = Minimized.blurCall(root.blurSize, root.blurPasses);
        const path = Hyprland.requestSocketPath || "";
        if (root.blurRejected || call === "" || path === "")
            return;
        root.blurPushes++;
        console.info("grassfield-shell: push blur size " + root.blurSize + " passes " + root.blurPasses);
        requestSocket.createObject(root, {"path": path, "line": "dispatch " + call, "what": "blur"});
    }

    // The session's ground (ADR-0040 ID-2, P-1): the compositor's background colour is the shown wallpaper's ground (the first
    // screen's; Hyprland holds one), sent the same way as the blur: at start, on each change (debounced) and after a config
    // reload (which restores looknfeel.lua's static default, session.ground). An error answer (a Hyprland that cannot set it at
    // run time) stops the pushes until the next change: the static default stays, as ID-2's fallback says.
    // Nothing is pushed before the first screen reported its ground (Ground.known): at a shell restart the compositor keeps
    // the previous run's ground until then, instead of flashing the static default. The colour Hyprland answers "ok" to is
    // recorded (Ground.accepted): the exit cover fades to it.
    readonly property string ground: Ground.current
    readonly property bool groundKnown: Ground.known
    property bool groundRejected: false
    onGroundChanged: {
        root.groundRejected = false;
        if (root.groundKnown)
            groundDebounce.restart();
    }
    onGroundKnownChanged: {
        if (root.groundKnown)
            groundDebounce.restart();
    }
    function pushGround(): void {
        const call = Minimized.groundCall(root.ground);
        const path = Hyprland.requestSocketPath || "";
        if (!root.groundKnown || root.groundRejected || call === "" || path === "")
            return;
        console.info("grassfield-shell: push ground " + root.ground);
        requestSocket.createObject(root, {"path": path, "line": "dispatch " + call, "what": "ground", "value": root.ground});
    }
    Timer {
        id: groundDebounce
        interval: Tokens.motionFast
        onTriggered: root.pushGround()
    }

    // One connection per push: it sends the dispatch and collects the whole answer (it may arrive in pieces) until Hyprland
    // closes the connection; then it is judged once and the socket is destroyed (later: a Socket cannot be destroyed from its
    // own error signal, that signal can fire inside createObject).
    Component {
        id: requestSocket

        Socket {
            id: sock
            property string line: ""
            // What the request sets ("blur", "edge", "ground"), and the ground it sent: a refusal stops the pushes of that one only.
            property string what: "blur"
            property string value: ""
            property string reply: ""
            property bool judged: false

            function finish(): void {
                if (sock.judged)
                    return;
                sock.judged = true;
                sock.answerTimeout.stop();
                const answer = Minimized.blurAnswer(sock.reply);
                if (sock.what === "ground" && answer === "ok") {
                    Ground.accepted = sock.value;
                    WallpaperState.setGround(sock.value);
                }
                if (answer === "rejected") {
                    if (sock.what === "edge" && !root.edgeRejected) {
                        root.edgeRejected = true;
                        console.info("grassfield-shell: Hyprland rejected the window edge request (" + sock.reply.trim() + "); the edge stays as configured until the next change");
                    } else if (sock.what === "ground" && !root.groundRejected) {
                        root.groundRejected = true;
                        console.info("grassfield-shell: Hyprland rejected the ground request (" + sock.reply.trim() + "); the background stays as configured until the next change");
                    } else if (sock.what === "blur" && !root.blurRejected) {
                        root.blurRejected = true;
                        console.info("grassfield-shell: Hyprland rejected the blur request (" + sock.reply.trim() + "); the blur stays as configured until the next change");
                    }
                }
                sock.connected = false;
                Qt.callLater(() => sock.destroy());
            }

            parser: SplitParser {
                // No separator: Hyprland's answer has no newline, take what arrives and add it up.
                splitMarker: ""
                onRead: data => sock.reply += data
            }
            onConnectedChanged: {
                if (connected) {
                    write(sock.line);
                    flush();
                    sock.answerTimeout.start();
                } else {
                    sock.finish();
                }
            }

            // A request nobody answers is judged (as unanswered) after this long.
            readonly property Timer answerTimeout: Timer {
                interval: Tokens.materialBlurAnswerMs
                onTriggered: sock.finish()
            }

            // The error is judged after Quickshell's own error handler has returned: closing the socket from inside the
            // signal let Quickshell 0.3.2 null its socket, then call deleteLater on the null pointer (SIGSEGV at every shell
            // start, the shell restarting in a loop).
            Component.onCompleted: {
                sock.error.connect(() => Qt.callLater(sock.finish));
                sock.connected = true;
            }
        }
    }

    Timer {
        id: blurDebounce
        interval: Tokens.motionFast
        onTriggered: root.pushBlur()
    }

    Timer {
        id: edgeDebounce
        interval: Tokens.motionFast
        onTriggered: root.pushEdge()
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name !== "configreloaded")
                return;
            if (root.reduceMotion)
                root.pushMotion();
            // A reload restores the config's blur and window edge. Neither push emits an event (captured on Hyprland 0.56.2 for
            // the blur), so a reload is always a real one: no echo, no loop (tests/compositor/blur_events.sh).
            root.pushBlur();
            // And the ground (ADR-0040 ID-2): the reload put back the config's static default.
            Ground.accepted = Tokens.sessionGround;
            root.pushGround();
            root.pushEdge();
        }
    }

    onTitlebarDoubleClickChanged: pushPluginConfig()
    onMinimizeEffectChanged: pushPluginConfig()
    onTilingConfigChanged: pushPluginConfig()
    onChromeAppearanceChanged: pushPluginConfig()
    onStagesFlagChanged: pushStagesFlag()
    onStagesAvailableChanged: pushStagesFlag()

    // A Stages operation (docs/specs/stages.md "Shell contract"; Minimized.stagesCall) while the plugin advertises "stages"
    // (the flag is on). False when not sent.
    function stages(request: var): bool {
        if (!Capabilities.has("stages"))
            return false;
        return dispatchRequest(Minimized.stagesCall(request));
    }

    // What the last push sent of the tiling switches, and how many pushes so far: the tiling-switches harness checks that a
    // Settings change reaches the plugin.
    property var tilingSent: []
    property int tilingSendCount: 0

    // The tiling switches the plugin is sent now: those whose feature it advertises (the tiling-switches harness reads it).
    function tilingPushes(): var {
        return Minimized.tilingConfigPairs(Settings, feature => Capabilities.has(feature));
    }

    function pushPluginConfig(): void {
        if (Capabilities.has("config") && dispatchRequest(Minimized.configCall("titlebarDoubleClick", root.titlebarDoubleClick)))
            console.info("grassfield: compositor setting titlebarDoubleClick =", root.titlebarDoubleClick);
        if (Capabilities.has("minimize-effect") && dispatchRequest(Minimized.configCall("minimizeEffect", root.minimizeEffect)))
            console.info("grassfield: compositor setting minimizeEffect =", root.minimizeEffect);
        if (Capabilities.has("appearance") && dispatchRequest(Minimized.configCall("appearance", root.chromeAppearance)))
            console.info("grassfield: compositor setting appearance =", root.chromeAppearance);
        const sent = [];
        for (const [key, value] of root.tilingPushes()) {
            if (dispatchRequest(Minimized.configCall(key, value)))
                sent.push([key, value]);
        }
        root.tilingSent = sent;
        root.tilingSendCount++;
    }

    // Window > Move & Resize and the tiling keys (macOS 15+): the plugin places the window (FR49). Refused while locked (the
    // plugin refuses it too); false without the capability or for a window Hyprland does not know.
    readonly property bool canTile: Capabilities.has("window-tiling")

    function tile(toplevel: var, place: string): bool {
        if (SessionState.refuses("windows tile"))
            return false;
        if (!root.canTile)
            return false;
        return dispatchRequest(Minimized.tileCall(addressOf(toplevel), place));
    }

    // Window > Move & Resize > Arrange and its keys (TL6, TL25, TL26): the window into the first zone of a layout, the next
    // windows of its output in the others. False without the capability.
    readonly property bool canArrange: Capabilities.has("tiling-arrange")

    function arrange(toplevel: var, layout: string): bool {
        if (!root.canArrange)
            return false;
        const address = addressOf(toplevel);
        const sent = dispatchRequest(Minimized.arrangeCall(address, layout));
        if (sent)
            root.askSuggestion(address);
        return sent;
    }

    // The Layouts section and the suggestions (TL27, TL28): a window alone into a zone of a layout, a pick of the suggestions,
    // the plugin's `tiling` notice. False without the capability.
    readonly property bool canLayouts: Capabilities.has("tiling-layouts")

    // The class of an output for its Layouts section (WindowTiling.outputClass from its logical size), "" for no such output.
    function outputClassOf(screenName: string): string {
        const s = Quickshell.screens.find(o => o.name === screenName);
        return s ? WindowTiling.outputClass(s.width, s.height) : "";
    }

    // The plugin's `tiling` change notice (WindowTiling.parseNotice): {gen, reason}.
    signal tilingNotice(var notice)

    // The window whose arrangement the shell asked last, while its suggestion may still come (TL28: only after a layout or an
    // arrangement chosen from the popover, the Window menu or the keys): {address, until} (ms since the epoch), or null.
    property var suggestionAsked: null

    function askSuggestion(address: string): void {
        const on = root.canLayouts && root.suggestionsOn && address !== "";
        root.suggestionAsked = on ? {address: address, until: Date.now() + WindowTiling.suggestionWaitMs} : null;
    }

    // A zone of the Layouts section (TL27): the window alone into zone `zone` of `layout`.
    function placeInZone(toplevel: var, layout: string, zone: int): bool {
        if (!root.canLayouts)
            return false;
        const address = addressOf(toplevel);
        const sent = dispatchRequest(Minimized.zoneCall(address, layout, zone));
        if (sent)
            root.askSuggestion(address);
        return sent;
    }

    // A pick of the suggestions (TL28): the window `address` into zone `zone` of the layout of the window `withAddress`.
    function pickSuggestion(address: string, layout: string, zone: int, withAddress: string): bool {
        if (!root.canLayouts)
            return false;
        const sent = dispatchRequest(Minimized.zoneCall(address, layout, zone, withAddress));
        if (sent)
            root.askSuggestion(Minimized.normalizeAddress(withAddress));
        return sent;
    }

    // ---- the Full Screen tile (docs/specs/tiling.md TL33, macOS Split View; ADR-0036 D40-D47) ----

    // Full Screen › Left or Right of Screen and Exit Full Screen of a window of a Split View Desktop: the plugin's split and
    // unsplit. Nothing without the capability, nothing while locked.
    readonly property bool canSplit: Capabilities.has("tiling-split")
    // Step 6d (ADR-0036 D71): unsplit's Make Window Full Screen and Replace Tiled Window (a plugin before 6d would ignore them).
    readonly property bool canSplitRows: Capabilities.has("tiling-split-rows")
    // Step 6e (ADR-0036 D73): a Split View window's titlebar is away and no strip is kept above it (the Overview's band).
    readonly property bool splitTitlesAway: Capabilities.has("tiling-split-titles")
    // ADR-0036 D47: while Stages shows its strip the plugin refuses Left and Right of Screen; the rows are greyed.
    readonly property bool splitBlocked: root.stagesAvailable && Settings.windowsStages

    // The Split View Desktop `workspaceId` is (TilingLink.splits, from the plugin's reply), or null.
    function splitOf(workspaceId: int): var {
        return WindowTiling.splitOfWorkspace(TilingLink.splits, workspaceId);
    }

    // The window is a member of a Split View Desktop (one of its two windows, whatever its state; another window there is none,
    // ADR-0036 D52).
    function inSplit(toplevel: var): bool {
        const address = addressOf(toplevel);
        return address !== "" && WindowTiling.splitOfWindow(TilingLink.splits, address) !== null;
    }

    // The window fits half of its output (ADR-0036 D57; from the plugin's last reply: not known yet counts as fitting, the plugin
    // still refuses it).
    function fitsHalf(toplevel: var): bool {
        return WindowTiling.fitsHalf(TilingLink.unfit, addressOf(toplevel));
    }

    // The window is of fixed size (ADR-0040 step 1b; from the plugin's last reply: not known yet counts as not, the plugin still
    // opens nothing from its zoom light).
    function fixedSize(toplevel: var): bool {
        return WindowTiling.isFixed(TilingLink.fixed, addressOf(toplevel));
    }

    // The window is filled by Zoom or Fill (ADR-0036 D78; from the plugin's last reply: not known yet counts as not).
    function isFilled(toplevel: var): bool {
        return WindowTiling.isFilled(TilingLink.filled, addressOf(toplevel));
    }

    // The zones and the places the window does not fit, {zones, places} (ADR-0036 D69; from the plugin's last reply: not known
    // yet, nothing is greyed and the plugin still refuses what does not fit).
    function fitOf(toplevel: var): var {
        return WindowTiling.fitOf(TilingLink.unfitZones, addressOf(toplevel));
    }

    // The output shows a Split View Desktop: its menu bar and its Dock hide there and show at their edge, as in full screen.
    function splitShown(screenName: string): bool {
        const mon = monitorByName(screenName);
        return mon && mon.activeWorkspace ? root.splitOf(mon.activeWorkspace.id) !== null : false;
    }

    // Left or Right of Screen (D41-D43): the window in that half of a new Split View Desktop, then the suggestions of the other
    // half (always: the Split View asks for its second window; "Suggest windows to fill the rest of a layout" governs the
    // layouts only). Refused while locked; false without the capability or for an invalid window or side.
    function split(toplevel: var, side: string): bool {
        if (SessionState.refuses("windows split"))
            return false;
        if (!root.canSplit)
            return false;
        const address = addressOf(toplevel);
        const call = Minimized.splitCall(address, side);
        if (call === "")
            return false;
        root.suggestionAsked = root.canLayouts ? {address: address, until: Date.now() + WindowTiling.suggestionWaitMs} : null;
        const sent = dispatchRequest(call);
        if (!sent)
            root.suggestionAsked = null;
        return sent;
    }

    // A window of a Split View Desktop leaves it. Exit Full Screen and Move Window to Desktop (D44, `how` "desktop" or none):
    // back to its Desktop and box, the other window fills alone; Make Window Full Screen ("fullscreen") then full screen there;
    // Replace Tiled Window ("replace": its half waits for the window picked, D71). Refused while locked; false without the
    // capability (the rows' without tiling-split-rows), or for an invalid window or `how`.
    function unsplit(toplevel: var, how: var): bool {
        if (SessionState.refuses("windows unsplit"))
            return false;
        if (!root.canSplit || !WindowTiling.unsplitAllowed(how, root.canSplitRows))
            return false;
        return dispatchRequest(Minimized.unsplitCall(addressOf(toplevel), how));
    }

    // The window's Split View Desktop holds two windows: Replace Tiled Window has a window to keep (D71).
    function splitPair(toplevel: var): bool {
        return WindowTiling.splitPair(TilingLink.splits, addressOf(toplevel));
    }

    // D43: the picker of a Split View Desktop ended without a second window (services/TilingSuggest): the window `address`
    // fills it alone. Refused while locked (the picker's end is acted on again at the unlock); false for a window that is no
    // member of a Split View Desktop.
    function fillAlone(address: string): bool {
        if (SessionState.refuses("windows fill alone"))
            return false;
        const toplevel = toplevelByAddress(address);
        if (!toplevel || !root.inSplit(toplevel))
            return false;
        return root.tile(toplevel, "fill");
    }

    // Tile groups (TL29): a window brought forward from the Dock, its menu, the menu bar's Window menu, the app switcher or
    // the Overview brings its tile group forward; the Dock menu's Show Tile Group; an Overview drop moves the group
    // (TilingLink.groups). Nothing without the capability, nothing while locked.
    readonly property bool canGroups: Capabilities.has("tiling-groups")

    // The tile group of the window `address` (with or without 0x) comes forward: its members on screen on its Desktop in
    // their stacking order, then the window when it is on screen (the plugin's group_front). Sent after the window's
    // activation or restore, through the dispatch channel; the plugin's result does not depend on which reaches it first
    // (a window on a special workspace is not raised, its restore raises it). Only for a window in a group of the last
    // reply (WindowTiling.membersOf); refused while locked (the plugin refuses too). What happened, for the tiling-switches
    // harness: "locked", "off" ("Bring tile groups forward together" is off, TL32: the window comes forward alone), or
    // groupFront's answer.
    function groupForward(address: string): string {
        if (SessionState.refuses("tile group forward"))
            return "locked";
        if (!Settings.windowsTilingGroups)
            return "off";
        return groupFront(address);
    }

    // group_front for a window in a group of the last reply, never while locked: the activation paths through groupForward
    // (the switch), Show Tile Group directly (the user asked for the group, whatever the switch; ADR-0036 D37). "locked",
    // "unavailable" (no tiling-groups), "no group", "sent" or "failed" (the dispatch refused the call).
    function groupFront(address: string): string {
        if (SessionState.refuses("tile group forward"))
            return "locked";
        if (!root.canGroups)
            return "unavailable";
        if (WindowTiling.membersOf(TilingLink.groups, address).length === 0)
            return "no group";
        return dispatchRequest(Minimized.groupFrontCall(address)) ? "sent" : "failed";
    }

    // Activate (activate) a window, its tile group coming forward with it.
    function activateWithGroup(toplevel: var): void {
        if (!toplevel)
            return;
        activate(toplevel);
        groupForward(addressOf(toplevel));
    }

    // Restore a minimized window (unminimize: a Dock tile, the Overview's strip), its tile group coming forward with it.
    function unminimizeWithGroup(toplevel: var): void {
        if (!toplevel)
            return;
        unminimize(toplevel);
        groupForward(addressOf(toplevel));
    }

    // The windows `addresses` (lower-case hex without 0x) as WindowTiling's group functions take them: {address, workspace
    // (Hyprland's id: a special workspace is negative), active (shown), minimized, parked (on no Desktop)}.
    function groupWindowFacts(addresses: var): var {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        const minimized = minimizedAddresses().map(a => Minimized.normalizeAddress(a));
        return all.map(t => {
            const address = Minimized.normalizeAddress(t.address);
            const ws = t.workspace;
            const isMin = minimized.indexOf(address) >= 0;
            return {
                address: address,
                workspace: ws ? ws.id : 0,
                active: !!(ws && ws.active),
                minimized: isMin,
                parked: isMin || !ws || ws.id <= 0
            };
        }).filter(w => addresses.indexOf(w.address) >= 0);
    }

    // The Dock menu's Show Tile Group (TL29, D30): the steps of WindowTiling.tileGroupSteps for the app's window `toplevel`
    // and its group `members`, sent in that order through the dispatch channel (the group's Desktop, the restores, the
    // focus, the group).
    function showTileGroup(toplevel: var, members: var): void {
        const own = addressOf(toplevel);
        if (own === "")
            return;
        root.endShowDesktop();
        const group = members.map(a => Minimized.normalizeAddress(a)).concat([own]);
        for (const step of WindowTiling.tileGroupSteps(own, members, groupWindowFacts(group))) {
            switch (step.op) {
            case "space":
                focusSpace(step.id);
                break;
            case "restore":
                unminimize(toplevelByAddress(step.address));
                break;
            case "move":
                dispatchRequest(moveRequest(step.address, String(step.id))); // hidden with its app: back with the group
                break;
            case "activate":
                activate(toplevel);
                break;
            case "focus":
                dispatchRequest(Minimized.focusWindowRequest(step.address));
                break;
            case "groupFront":
                groupFront(step.address);
                break;
            }
        }
    }

    // The tiling popover of the zoom light (TL22-TL26): the plugin's hover event, its keyboard opening and Move to <display>.
    readonly property bool canTileHover: Capabilities.has("tile-hover")

    // The plugin's tile-hover event (WindowTiling.parseHover): {address, state: "enter" | "leave" | "open", light, tileable}.
    signal tileHover(var hover)

    // The outputs where a full-screen window's titlebar is revealed at the top edge (the plugin's titlebar-reveal event,
    // WindowTiling.revealsAfter; ADR-0036 D65): the menu bar there comes and goes with it. Empty without the plugin.
    property var titlebarReveals: []

    function titlebarRevealedOn(screenName: string): bool {
        return root.titlebarReveals.indexOf(screenName) >= 0;
    }

    // The window Hyprland names `address` (lower-case hex without 0x), as a foreign-toplevel handle, or null.
    function toplevelByAddress(address: string): var {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (Minimized.normalizeAddress(all[i].address) === address)
                return all[i].wayland;
        }
        return null;
    }

    // The screens as WindowTiling takes them ({name, model, x, y, width, height}, logical).
    function screenList(): var {
        return Quickshell.screens.map(s => ({name: s.name, model: s.model, x: s.x, y: s.y, width: s.width, height: s.height}));
    }

    // Where the tiling popover opens for a zoom light (global layout coordinates): WindowTiling.popoverAnchor.
    function popoverAnchor(light: var): var {
        return WindowTiling.popoverAnchor(light, root.screenList());
    }

    // The outputs a window can move to (WindowTiling.otherOutputs: [{name, model, builtIn}]); none without the capability.
    function otherOutputs(toplevel: var): var {
        const top = hyprlandToplevel(toplevel);
        if (!root.canTileHover || !top)
            return [];
        return WindowTiling.otherOutputs(root.screenList(), windowScreenName(top));
    }

    // Super+Ctrl+L (TL26): the plugin answers with the tile-hover "open" event of that window. False when not sent.
    function openTilingPopover(toplevel: var): bool {
        if (!root.canTileHover)
            return false;
        return dispatchRequest(Minimized.tilePopoverCall(addressOf(toplevel)));
    }

    // Move to <display> (TL23): the window onto that output, in the same tile when it is tiled. False when not sent.
    function moveToOutput(toplevel: var, output: string): bool {
        if (!root.canTileHover)
            return false;
        return dispatchRequest(Minimized.moveToCall(addressOf(toplevel), output));
    }

    // Super+Ctrl+Alt+Left/Right (TL26): the window onto the next output that way (WindowTiling.nextOutput).
    function moveToNextOutput(toplevel: var, direction: string): bool {
        const top = hyprlandToplevel(toplevel);
        const next = top ? WindowTiling.nextOutput(root.screenList(), windowScreenName(top), direction) : "";
        return next !== "" && root.moveToOutput(toplevel, next);
    }

    Connections {
        target: Capabilities

        function onFeaturesChanged(): void {
            root.pushPluginConfig();
        }

        function onPluginPresentChanged(): void {
            root.pushPluginConfig();
            if (!Capabilities.pluginPresent)
                root.titlebarReveals = []; // a plugin gone (unloaded, Hyprland restarted) reveals nothing any more
        }
    }

    // The handshake may have completed before this singleton was first used.
    Component.onCompleted: {
        pushPluginConfig();
        pushStagesFlag();
        // Always, whatever the value: Hyprland outlives the shell, so a restarted shell (or one that finds the setting off
        // after a config reset) must not leave the compositor on the reduced animations of the previous run.
        pushMotion();
        // The same for the blur and the window edge: the compositor keeps the values of the previous run.
        pushBlur();
        // And the ground, once known (ADR-0040 ID-2; onGroundKnownChanged otherwise).
        pushGround();
        pushEdge();
    }

    function isMinimized(toplevel: var): bool {
        return Minimized.has(root.minimized, toplevel);
    }

    // Closed windows leave the minimized list.
    Connections {
        target: root.toplevels

        function onValuesChanged(): void {
            if (root.minimized.length > 0)
                root.minimized = Minimized.prune(root.minimized, root.toplevels.values);
        }
    }

    // Rebuilds the minimized list from windows sitting on special:minimized (the shell may have
    // restarted since they were minimized). Window data is re-read first, then merged. A window
    // whose latest move event took it elsewhere is skipped: re-read data can predate that move
    // (fast minimize/restore sequences re-added restored windows before this check).
    function syncMinimized(): void {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        let list = root.minimized;
        for (let i = 0; i < all.length; i++) {
            const top = all[i];
            if (!top.wayland || !top.workspace || top.workspace.name !== minimizedWorkspace)
                continue;
            const address = Minimized.normalizeAddress(top.address);
            if (address === "" || (root.lastWorkspace.has(address) && root.lastWorkspace.get(address) !== minimizedWorkspace))
                continue;
            list = Minimized.add(list, {toplevel: top.wayland, address: address, appId: top.wayland.appId, title: top.wayland.title});
        }
        if (list !== root.minimized)
            root.minimized = list;
    }

    // Latest workspace name per window address, from movewindowv2 events: ordered and
    // authoritative, unlike re-read window data.
    property var lastWorkspace: new Map()

    // A window moved: onto special:minimized (by the plugin, the fallback or anything else) it is
    // recorded; off it (restored by any means) its record goes, so the Dock never shows a stale tile.
    function onWindowMoved(data: string): void {
        const move = Minimized.parseMoveWindowV2(data);
        if (!move)
            return;
        root.lastWorkspace.set(move.address, move.workspace);
        let list = root.minimized;
        if (move.workspace === minimizedWorkspace) {
            const top = (Hyprland.toplevels ? Hyprland.toplevels.values : []).find(t => Minimized.normalizeAddress(t.address) === move.address);
            if (top && top.wayland)
                list = Minimized.add(list, {toplevel: top.wayland, address: move.address, appId: top.wayland.appId, title: top.wayland.title});
            else
                minimizedSyncTimer.restart(); // handle not matched yet: merge once window data arrived
        } else {
            list = list.filter(r => r.address !== move.address);
        }
        if (list.length !== root.minimized.length)
            root.minimized = list;
    }

    // Debounced: re-read window data, then rebuild the list once it has arrived.
    Timer {
        id: minimizedSyncTimer
        interval: 100
        onTriggered: {
            Hyprland.refreshToplevels();
            minimizedMergeTimer.restart();
        }
    }

    Timer {
        id: minimizedMergeTimer
        interval: 200
        onTriggered: root.syncMinimized()
    }

    // First rebuild shortly after the shell starts (Hyprland data has to arrive first).
    Timer {
        running: true
        interval: 600
        onTriggered: minimizedSyncTimer.restart()
    }

    // The titlebar button (plugin) posts a minimize-request event, and so does a tagged window's own minimize button
    // (GF-056 P8); the address is validated. Like the SUPER+M binding, nothing behind the lock moves (GF-116).
    function minimizeByAddress(address: string): void {
        if (SessionState.refuses("windows minimize request"))
            return;
        const wanted = Minimized.normalizeAddress(address);
        if (wanted === "")
            return;
        const top = (Hyprland.toplevels ? Hyprland.toplevels.values : []).find(t => Minimized.normalizeAddress(t.address) === wanted);
        if (top && top.wayland)
            root.minimize(top.wayland);
    }

    function hideApp(appId: string): void {
        toplevelsFor(appId).forEach(t => hide(t));
    }

    // Windows parked on special:hidden by hide(): [{address, toplevel}].
    function hiddenWindows(revision: int): var {
        const out = [];
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].workspace && all[i].workspace.name === hiddenWorkspace)
                out.push({address: all[i].address, toplevel: all[i].wayland});
        }
        return out;
    }

    // "Show All": brings every hidden window back to the focused workspace.
    function showAll(): void {
        if (!root.focusedWorkspace)
            return;
        hiddenWindows(0).forEach(w => dispatchRequest(moveRequest(Minimized.normalizeAddress(w.address), String(root.focusedWorkspace.id))));
    }

    // ---- Show Desktop (macOS F11 / Cmd+F3, GF-106) ----
    //
    // Moves the windows of every display's Space aside (to special:desktop) and hands the keyboard to the desktop icons.
    // Switching Space, opening a window, activating a window (Dock, switcher, an app) or pressing it again ends it: every
    // window goes back to its Space in its tiling order and, for the second press, the window that had the focus gets it again.
    // The record is kept in the state dir, so a restarted shell (or one that crashed) puts the windows back at start.
    // Does nothing with Stages on (a stage cannot be rebuilt window by window, docs/specs/stages.md ST8/ST9), and minimized
    // or hidden windows are left alone.
    //
    // All the decisions are in ShowDesktopFlow.js (a pure reducer) run by ShowDesktopController.qml, which listens to the
    // Hyprland events itself (tests/unit/tst_showdesktopflow.qml, tst_showdesktopreplay.qml, tst_showdesktopglue.qml). This file
    // only tells it how to read the window list and the Spaces, where to send the requests and where the record file is.
    readonly property string desktopStateDir: Mode.stateDir
    readonly property string desktopStatePath: desktopStateDir + "/show-desktop.json"

    function toplevelData(): var {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        return all.map(t => {
            const at = t.lastIpcObject && Array.isArray(t.lastIpcObject.at) ? t.lastIpcObject.at : [0, 0];
            return {
                address: t.address,
                workspace: t.workspace ? t.workspace.id : 0,
                parked: t.workspace ? t.workspace.name === ShowDesktop.PARKING : false,
                x: at[0],
                y: at[1],
                minimized: t.wayland ? isMinimized(t.wayland) : false,
                hidden: t.wayland ? isHidden(t.wayland) : false
            };
        });
    }

    // [{name, workspace}]: the Space each display shows now.
    function shownSpaces(): var {
        const all = Hyprland.monitors ? Hyprland.monitors.values : [];
        return all.filter(m => m.activeWorkspace).map(m => ({name: m.name, workspace: m.activeWorkspace.id}));
    }

    ShowDesktopController {
        id: showDesktopFlow

        eventSource: Hyprland
        readWindows: () => root.toplevelData()
        readShown: () => root.shownSpaces()
        readFocused: () => {
            const focused = root.focusedToplevel ? root.hyprlandToplevel(root.focusedToplevel) : null;
            return focused ? focused.address : "";
        }
        readCurrentWorkspace: () => Hyprland.focusedMonitor && Hyprland.focusedMonitor.activeWorkspace ? Hyprland.focusedMonitor.activeWorkspace.id : 0
        readLoaded: () => !!Hyprland.toplevels && Hyprland.toplevels.values.length > 0
        stages: Settings.windowsStages
        dispatch: request => root.dispatchRequest(request)
        refreshWindows: () => Hyprland.refreshToplevels()
        onPersistRequested: text => {
            if (desktopFile.path !== "")
                desktopFile.setText(text);
        }
        onFocusDesktopRequested: DesktopState.focusRequested()
    }

    // Ends Show Desktop for an activation by the shell itself (activate(), unminimize()): true when it was on.
    function endShowDesktop(): bool {
        return showDesktopFlow.endForActivation();
    }

    // Super+F3.
    function showDesktop(): void {
        showDesktopFlow.press();
    }

    // A display plugged or unplugged: the Spaces the displays show are compared again (a removed display ends Show Desktop).
    Connections {
        target: Quickshell

        function onScreensChanged(): void {
            showDesktopFlow.screensChanged();
        }
    }

    Process {
        id: desktopPrepare
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", root.desktopStateDir, root.desktopStatePath]
        running: true
        onRunningChanged: {
            if (!running)
                desktopFile.path = root.desktopStatePath;
        }
    }

    FileView {
        id: desktopFile
        printErrors: false
        atomicWrites: true
        onLoaded: showDesktopFlow.recordsLoaded(desktopFile.text())
    }

    // "Hide Others": hides every visible window of other apps.
    function hideOthers(appId: string): void {
        const keep = appId.toLowerCase();
        const all = root.toplevels ? root.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].appId.toLowerCase() !== keep && !isMinimized(all[i]))
                hide(all[i]);
        }
    }

    // Number of visible (not minimized, not hidden) windows of other apps.
    function othersCount(appId: string, revision: int): int {
        const keep = appId.toLowerCase();
        const hidden = hiddenWindows(revision).map(w => w.toplevel);
        const all = root.toplevels ? root.toplevels.values : [];
        return all.filter(t => t.appId.toLowerCase() !== keep && !isMinimized(t) && hidden.indexOf(t) < 0).length;
    }

    // Regular workspace id of a toplevel, 0 if unknown (special workspaces report <= 0).
    function spaceOf(toplevel: var): int {
        const top = hyprlandToplevel(toplevel);
        return top && top.workspace && top.workspace.id > 0 ? top.workspace.id : 0;
    }

    // Raise every visible window of an app, the most recent last so that it ends up focused.
    function bringAllToFront(appId: string): void {
        const list = toplevelsFor(appId).filter(t => !isMinimized(t));
        const top = mostRecent(list);
        list.filter(t => t !== top).forEach(t => activate(t));
        if (top)
            activate(top);
    }

    // Zoom is Fill (ADR-0036 D78): with the plugin's "zoom-fill" the plugin's zoom toggle (the window fills its work area as
    // a tile, with the margins, and a second Zoom brings back its box from before); without it the "maximized" fullscreen
    // mode, toggled by a dispatch (the foreign-toplevel `maximized` request is ignored: windows.lua suppresses maximize
    // events). Full screen = fullscreen (ADR-0002), through the foreign-toplevel protocol.
    function toggleZoom(toplevel: var): void {
        const top = hyprlandToplevel(toplevel);
        if (top && dispatchRequest(Minimized.zoomRequest(top.address, Capabilities.has("zoom-fill"))))
            requestWindowRefresh();
    }

    // Zoom state from Hyprland's window data (fullscreen mode 1), reactive on `revision`.
    function isZoomed(toplevel: var, revision: int): bool {
        const top = hyprlandToplevel(toplevel);
        return top ? Minimized.isZoomed(top.lastIpcObject) : false;
    }

    // Window data is only re-read on request. Events that change window state (fullscreen,
    // floating mode, title) request a re-read; requests inside one 50 ms window coalesce into a
    // single refresh (trailing edge, never starved by a burst), then bindings are notified once
    // the data has arrived.
    function requestWindowRefresh(): void {
        if (!windowRefreshTimer.running)
            windowRefreshTimer.start();
    }

    Timer {
        id: windowRefreshTimer
        interval: 50
        onTriggered: {
            Hyprland.refreshToplevels();
            windowNotifyTimer.restart();
        }
    }

    Timer {
        id: windowNotifyTimer
        interval: 100
        onTriggered: root.topologyRevision++
    }

    function toggleFullscreen(toplevel: var): void {
        if (toplevel)
            toplevel.fullscreen = !toplevel.fullscreen;
    }

    // Hyprland-independent entry points for key bindings (SUPER+M, SUPER+H). None acts while the session is locked
    // (GF-116: windows behind the lock are neither moved nor focused).
    IpcHandler {
        target: "windows"

        function minimize(): void {
            if (!SessionState.refuses("windows minimize"))
                root.minimize(root.focusedToplevel);
        }

        // Super+Ctrl+arrows / Super+Ctrl+R (macOS Globe+Ctrl): the focused window to a half, or back to its size.
        function tile(place: string): void {
            if (!SessionState.refuses("windows tile"))
                root.tile(root.focusedToplevel, place);
        }

        // Super+Ctrl+Shift+arrows and Super+Ctrl+Alt+Shift+arrows (TL26): the focused window and the next ones into a layout.
        function arrange(layout: string): void {
            if (!SessionState.refuses("windows arrange"))
                root.arrange(root.focusedToplevel, layout);
        }

        // Super+Ctrl+L (TL26): the tiling popover of the focused window, with the keyboard.
        function tilePopover(): void {
            if (!SessionState.refuses("windows tilePopover"))
                root.openTilingPopover(root.focusedToplevel);
        }

        // Super+Ctrl+Alt+Left/Right (TL26): the focused window onto the next output ("left" or "right").
        function nextOutput(direction: string): void {
            if (!SessionState.refuses("windows nextOutput"))
                root.moveToNextOutput(root.focusedToplevel, direction);
        }

        function hide(): void {
            if (root.focusedAppId !== "" && !SessionState.refuses("windows hide"))
                root.hideApp(root.focusedAppId);
        }

        // SUPER+F3 (macOS Cmd+F3, Fn+F11): Show Desktop.
        function showDesktop(): void {
            root.showDesktop();
        }

        // SUPER+`: next window of the focused app (macOS Cmd+`).
        function cycleApp(): void {
            if (SessionState.refuses("windows cycleApp"))
                return;
            const pool = root.toplevelsFor(root.focusedAppId).filter(t => !root.isMinimized(t));
            if (pool.length > 1)
                root.activate(root.nextAfter(pool, root.focusedToplevel));
        }
    }

    // Ask the client to close this window (xdg close request, not a kill).
    function close(toplevel: var): void {
        if (toplevel)
            toplevel.close();
    }

    // End the compositor session. In Lua mode Quickshell evaluates `hl.dispatch(<request>)`.
    function exitSession(): void {
        Hyprland.dispatch(Hyprland.usingLua ? "hl.dsp.exit()" : "exit");
    }

    // ---- Overview support (spec overview.md): Spaces (workspaces) and window geometry ----

    // Bumped on Hyprland events that change windows or workspaces, so that bindings calling
    // spacesOn()/windowsOn() with it as an argument re-evaluate.
    property int topologyRevision: 0
    // While true, window/workspace events trigger a debounced re-read of Hyprland's data (new
    // windows only carry geometry after a refresh). Overview sets it while open.
    property bool refreshOnEvents: false

    Timer {
        id: refreshTimer
        interval: 60
        onTriggered: root.refreshSpaces()
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "grassfield") {
                const address = Minimized.minimizeRequestAddress(event.data);
                if (address !== "")
                    root.minimizeByAddress(address);
                const hover = WindowTiling.parseHover(event.data);
                if (hover)
                    root.tileHover(hover);
                const notice = WindowTiling.parseNotice(event.data);
                if (notice)
                    root.tilingNotice(notice);
                const reveal = WindowTiling.parseTitlebarReveal(event.data);
                if (reveal)
                    root.titlebarReveals = WindowTiling.revealsAfter(root.titlebarReveals, reveal);
                return;
            }
            if (event.name === "bell") {
                root.bell(Minimized.normalizeAddress(event.data));
                return;
            }
            if (event.name === "urgent") {
                const urgent = Minimized.normalizeAddress(event.data);
                if (urgent !== "")
                    root.attention(urgent);
                return;
            }
            if (root.interruptingEvents.indexOf(event.name) >= 0)
                root.interrupted(event.name);
            if (event.name === "closelayer") {
                root.layerClosed(event.data);
                return;
            }
            if (event.name === "activespecialv2") {
                // "<id>,<name>,<monitor>": the minimized parking workspace must never show as
                // an overlay (a window minimized while it is focused would keep it open).
                if (event.data.split(",")[1] === root.minimizedWorkspace)
                    Hyprland.dispatch("hl.dsp.workspace.toggle_special(\"minimized\")");
                return;
            }
            if (event.name === "windowtitlev2" || event.name === "fullscreen" || event.name === "changefloatingmode" || root.fullscreenRefreshEvents.indexOf(event.name) >= 0) {
                root.requestWindowRefresh();
                if (event.name === "windowtitlev2")
                    return;
            }
            if (event.name === "movewindowv2")
                root.onWindowMoved(event.data);
            else if (event.name === "openwindow")
                minimizedSyncTimer.restart(); // a window may map directly onto special:minimized
            else if (event.name === "closewindow") {
                const closed = Minimized.normalizeAddress(event.data);
                root.lastWorkspace.delete(closed);
                if (closed !== "")
                    root.windowClosed(closed);
            }
            switch (event.name) {
            case "openwindow":
            case "closewindow":
            case "movewindowv2":
            case "workspacev2":
            case "createworkspacev2":
            case "destroyworkspacev2":
            case "moveworkspacev2":
            case "changefloatingmode":
            case "fullscreen":
                root.topologyRevision++;
                if (root.refreshOnEvents)
                    refreshTimer.restart();
            }
        }
    }

    // Re-reads windows and workspaces from Hyprland (call when Overview opens).
    function refreshSpaces(): void {
        Hyprland.refreshWorkspaces();
        Hyprland.refreshToplevels();
    }

    // An output's real scale (Hyprland's monitor scale, 1.25 on the owner's panel); 1 when the output is not known. Quickshell's
    // ShellScreen.devicePixelRatio is the layer surface's integer ratio (2 at 1.25), not the pixels the output makes.
    function outputScale(screenName: string): real {
        const mon = monitorByName(screenName);
        return mon && mon.scale > 0 ? mon.scale : 1;
    }

    function monitorByName(screenName: string): var {
        const all = Hyprland.monitors ? Hyprland.monitors.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].name === screenName)
                return all[i];
        }
        return null;
    }

    // Regular workspaces (id > 0) of an output, ordered by id, each Split View Desktop right after the one it came from:
    // [{id, name, active, windowCount, appIds, windows, screenW, screenH}]. `windows` (bottom to top as Hyprland lists them) are the
    // windowsAcross entries of the Space, `screenW` x `screenH` the output size in logical pixels (SpaceGeometry.js): what a desktop miniature needs.
    function spacesOn(screenName: string, revision: int): var {
        const out = [];
        const mon = monitorByName(screenName);
        const all = Hyprland.workspaces ? Hyprland.workspaces.values : [];
        const wins = windowsAcross(screenName);
        // Window geometry is logical, so is the size it is scaled against (an output at scale 1.5 or 2 reports device pixels).
        const size = SpaceGeometry.logicalSize(Quickshell.screens, screenName, mon);
        for (let i = 0; i < all.length; i++) {
            const ws = all[i];
            if (ws.id <= 0 || !ws.monitor || ws.monitor.name !== screenName)
                continue;
            const appIds = [];
            const inSpace = [];
            let count = 0;
            for (let j = 0; j < wins.length; j++) {
                if (wins[j].workspaceId !== ws.id)
                    continue;
                inSpace.push(wins[j]);
                count++;
                if (appIds.indexOf(wins[j].appId) === -1)
                    appIds.push(wins[j].appId);
            }
            out.push({
                id: ws.id,
                name: ws.name,
                active: mon && mon.activeWorkspace ? mon.activeWorkspace.id === ws.id : false,
                windowCount: count,
                appIds: appIds,
                windows: inSpace,
                screenW: size.w,
                screenH: size.h
            });
        }
        out.sort((a, b) => a.id - b.id);
        // A Split View Desktop after the one it came from (D41), unnumbered: the Desktops keep their numbers (#48 MINOR 7).
        return WindowTiling.numberDesktops(WindowTiling.desktopOrder(out, TilingLink.splits), TilingLink.splits);
    }

    // Mapped windows of an output on any regular workspace, monitor-relative geometry:
    // [{address, toplevel, appId, title, x, y, w, h, workspaceId, fullscreen, tags}]. `toplevel` is the
    // foreign-toplevel handle (null until matched), usable as a capture source.
    function windowsAcross(screenName: string): var {
        const out = [];
        const mon = monitorByName(screenName);
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        if (!mon)
            return out;
        for (let i = 0; i < all.length; i++) {
            const top = all[i];
            const data = top.lastIpcObject;
            if (!data || !data.at || !data.size || !data.workspace || data.workspace.id <= 0 || data.mapped === false || data.hidden === true)
                continue;
            if (data.monitor !== mon.id)
                continue;
            out.push({
                address: top.address,
                toplevel: top.wayland,
                appId: top.wayland ? top.wayland.appId : (data["class"] ? data["class"] : ""),
                title: top.title,
                x: data.at[0] - mon.x,
                y: data.at[1] - mon.y,
                w: data.size[0],
                h: data.size[1],
                workspaceId: data.workspace.id,
                fullscreen: data.fullscreen === 2,
                // Hyprland's window tags (rule-set ones print with a trailing "*"): Overview reads grassfield-client-chrome.
                tags: Array.isArray(data.tags) ? data.tags : []
            });
        }
        return out;
    }

    // Events after which which window is full screen where may have changed (a window opened, closed or moved, another
    // workspace shown): the window data is re-read (coalesced, event-driven) so fullscreenOn stays right.
    readonly property var fullscreenRefreshEvents: ["workspacev2", "openwindow", "closewindow", "movewindowv2"]

    // True when a window of the output's shown workspace is full screen (Hyprland fullscreen mode 2, not Zoom), or the output
    // shows a Split View Desktop (TL33). The menu bar sits above it on the overlay layer and auto-hides. Reactive on `revision`
    // (topologyRevision) and on TilingLink.splits.
    function fullscreenOn(screenName: string, revision: int): bool {
        return windowsOn(screenName, revision).some(w => w.fullscreen) || root.splitShown(screenName);
    }

    // Windows on the output's currently shown workspace.
    function windowsOn(screenName: string, revision: int): var {
        const mon = monitorByName(screenName);
        const activeId = mon && mon.activeWorkspace ? mon.activeWorkspace.id : -1;
        return windowsAcross(screenName).filter(w => w.workspaceId === activeId);
    }

    // hl.plugin.grassfield.overview (feature "overview"): request {on, durationMs, curve?, windows?} in layout
    // coordinates, validated and quoted by Minimized.overviewCall. False when the request is invalid.
    function overview(request: var): bool {
        return dispatchRequest(Minimized.overviewCall(request));
    }

    // Id for a new Space: one past the highest workspace id in use.
    function nextSpaceId(): int {
        let max = 0;
        const all = Hyprland.workspaces ? Hyprland.workspaces.values : [];
        for (let i = 0; i < all.length; i++)
            max = Math.max(max, all[i].id);
        return max + 1;
    }

    function focusSpace(id: int): void {
        if (id > 0)
            dispatchRequest(Minimized.focusRequest(Math.floor(id)));
    }

    // The window with the keyboard now, as {address, workspaceId} (null when none, or when Hyprland's data has no
    // workspace for it yet). Remembered by Overview when it opens.
    function activeWindow(): var {
        const top = hyprlandToplevel(focusedToplevel);
        if (!top || !top.workspace || top.workspace.id <= 0)
            return null;
        return {
            address: top.address,
            workspaceId: top.workspace.id
        };
    }

    // Where a window is now, for FocusReturn: {workspaceId, parked} (parked: minimized, hidden or unmapped), or null when it
    // does not exist.
    function placementOf(address: string): var {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        const hex = Minimized.normalizeAddress(address);
        const top = hex !== "" ? all.find(t => Minimized.normalizeAddress(t.address) === hex) : undefined;
        if (!top)
            return null;
        const data = top.lastIpcObject;
        const name = top.workspace ? top.workspace.name : "";
        return {
            workspaceId: top.workspace ? top.workspace.id : 0,
            parked: name === hiddenWorkspace || name === minimizedWorkspace || minimizedAddresses().some(a => Minimized.normalizeAddress(a) === hex) || !!(data && (data.mapped === false || data.hidden === true))
        };
    }

    // Addresses of the windows that exist now.
    function windowAddresses(): var {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        return all.map(t => t.address);
    }

    // Focuses a window by address, with its Space when that is not the one shown: the Space of the window as it is now.
    // False when the window does not exist (or has no protocol handle yet): nothing changes.
    function focusWindow(address: string): bool {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        // Either form of the address (with or without 0x, any case), as everywhere else here.
        const hex = Minimized.normalizeAddress(address);
        const top = hex !== "" ? all.find(t => Minimized.normalizeAddress(t.address) === hex) : undefined;
        if (!top || !top.wayland)
            return false;
        if (top.workspace && top.workspace.id > 0 && !top.workspace.active)
            focusSpace(top.workspace.id);
        // The Lua focus, not the protocol `activate`: the latter does nothing for a window Hyprland still counts as
        // focused, which is exactly the one a layer surface just took the keyboard from (measured: 11 of 12 lost).
        return dispatchRequest(Minimized.focusWindowRequest(address));
    }

    // hl.plugin.grassfield.overview_focus (feature "overview-focus"): the compositor focuses the target once the last
    // Exclusive layer is gone. False when the request is invalid (nothing is dispatched).
    function overviewFocus(target: var): bool {
        return dispatchRequest(Minimized.overviewFocusCall(target));
    }

    // Addresses of the windows the shell minimized (never given the focus).
    function minimizedAddresses(): var {
        return root.minimized.map(r => r.address);
    }

    // The window of a Desktop focused last, else its first window ("" for an empty Desktop): minimized and unmapped windows
    // never count.
    function frontWindowOn(id: int): string {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        const parked = minimizedAddresses().map(a => Minimized.normalizeAddress(a));
        let best = "";
        let bestStamp = -1;
        for (let i = 0; i < all.length; i++) {
            const top = all[i];
            const data = top.lastIpcObject;
            if (!top.workspace || top.workspace.id !== id || !top.wayland || parked.indexOf(Minimized.normalizeAddress(top.address)) >= 0 || (data && (data.mapped === false || data.hidden === true)))
                continue;
            const stamp = recency.has(top.wayland) ? recency.get(top.wayland) : 0;
            if (stamp > bestStamp) {
                best = top.address;
                bestStamp = stamp;
            }
        }
        return best;
    }

    // Move a window to a Space without following it (the address is validated by moveRequest).
    function moveToSpace(address: string, id: int): bool {
        if (!(id > 0))
            return false;
        return dispatchRequest(moveRequest(address, String(Math.floor(id))));
    }

    // An Overview drop (TL29, D31): the window `address` to Space `id` without following it, with the members of its tile
    // group on its Space (WindowTiling.groupMovers: a minimized or hidden member is on none and stays). False when nothing
    // moved.
    function moveGroupToSpace(address: string, id: int): bool {
        const own = Minimized.normalizeAddress(address);
        const members = root.canGroups ? WindowTiling.membersOf(TilingLink.groups, own) : [];
        const movers = WindowTiling.groupMovers(own, members, groupWindowFacts(members)); // read before the move changes them
        if (!moveToSpace(address, id))
            return false;
        movers.forEach(a => moveToSpace(a, id));
        return true;
    }

    // Move a window (foreign-toplevel handle) to a Space without following it.
    function moveToplevelToSpace(toplevel: var, id: int): bool {
        const top = hyprlandToplevel(toplevel);
        return top ? moveToSpace(top.address, id) : false;
    }

    // Focus recency (most recently activated wins), kept per toplevel handle.
    property var recency: new Map()

    onFocusedToplevelChanged: {
        if (focusedToplevel) {
            recency.set(focusedToplevel, Date.now());
            // The windows that closed are forgotten once they outnumber the ones there are (their handles would be kept
            // for the whole session).
            const live = root.toplevels ? root.toplevels.values : [];
            if (recency.size > 2 * live.length + 8) {
                for (const handle of Array.from(recency.keys())) {
                    if (live.indexOf(handle) < 0)
                        recency.delete(handle);
                }
            }
        }
        noteRegularFocus();
    }

    // The window in front before a quick look (see frontToplevel). Focus passes through "no window" between two windows, so that
    // is not remembered; a window's app id can arrive after it takes the focus, so one without an id yet is not remembered
    // either (it could be the quick look itself) and the id's arrival is looked at too. The quick look test reads the id
    // directly: the quickLookFocused binding may not have caught up yet when this runs.
    function noteRegularFocus(): void {
        if (focusedToplevel && focusedToplevel.appId !== "" && !QuickLook.isQuickLook(focusedToplevel.appId)) {
            regularToplevel = focusedToplevel;
            front = QuickLook.frontAfter(front, {type: "regularFocused"});
        }
    }

    Connections {
        target: DesktopState

        function onHoldsKeyboardChanged(): void {
            if (DesktopState.holdsKeyboard)
                root.front = QuickLook.frontAfter(root.front, {type: "desktopHeld"});
            else
                frontSettle.restart();
        }
    }

    // The desktop let go of the keyboard: once the focus has landed, a regular window with it means the user is back in that window.
    Timer {
        id: frontSettle
        interval: 250
        onTriggered: {
            const t = root.focusedToplevel;
            root.front = QuickLook.frontAfter(root.front, {type: "settled", focusedRegular: !!t && t.appId !== "" && !QuickLook.isQuickLook(t.appId)});
        }
    }

    onFocusedAppIdChanged: noteRegularFocus()

    // Window to raise when an app is clicked: the most recently focused one.
    function mostRecent(list: var): var {
        let best = null;
        let bestStamp = -1;
        for (let i = 0; i < list.length; i++) {
            const stamp = recency.has(list[i]) ? recency.get(list[i]) : 0;
            if (stamp > bestStamp) {
                best = list[i];
                bestStamp = stamp;
            }
        }
        return best;
    }

    // What the Dock needs to plan a click on a running app (dock/Launch.js activationPlan): minimized, on the focused
    // Desktop (a window parked by hide() counts as here: activate() brings it back), and its focus recency.
    function windowInfo(toplevel: var): var {
        const top = hyprlandToplevel(toplevel);
        const parked = top && top.workspace && (top.workspace.name === hiddenWorkspace || top.workspace.name === minimizedWorkspace);
        const here = !top || !top.workspace || !root.focusedWorkspace || parked || top.workspace.id === root.focusedWorkspace.id;
        return {
            "ref": toplevel,
            "minimized": isMinimized(toplevel),
            "here": here,
            "focused": toplevel === root.focusedToplevel,
            "fullscreen": !!toplevel.fullscreen,
            "split": root.inSplit(toplevel),
            "stamp": recency.has(toplevel) ? recency.get(toplevel) : 0
        };
    }

    // Window after `current` in list order (wraps); the first one if current is not in the list.
    function nextAfter(list: var, current: var): var {
        if (list.length === 0)
            return null;
        const at = list.indexOf(current);
        return list[(at + 1) % list.length];
    }

    // What app energy (services/AppEnergy.qml, ADR-0048) needs to know of the windows, as plain data for AppEnergyLogic.js:
    // {windows: [{address, pid, workspaceId, workspaceName, mapped, hidden, minimized, floating, pinned, fullscreen, x, y, w,
    // h}], focused: [addresses], shown: [workspace ids the displays show], parked: [workspace names that park windows]}.
    // Addresses are lower-case hex without 0x; the pid is 0 and the geometry NaN until Hyprland's data was read for the
    // window (requestWindowRefresh). `focused` holds the focused window and the one in front of a quick look.
    function energySnapshot(): var {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        const parkedList = minimizedAddresses().map(a => Minimized.normalizeAddress(a));
        const windows = all.map(t => {
            const d = t.lastIpcObject || {};
            const at = Array.isArray(d.at) ? d.at : [NaN, NaN];
            const size = Array.isArray(d.size) ? d.size : [NaN, NaN];
            const address = Minimized.normalizeAddress(t.address);
            return {
                address: address,
                pid: d.pid > 0 ? d.pid : 0,
                workspaceId: t.workspace ? t.workspace.id : (d.workspace ? d.workspace.id : 0),
                workspaceName: t.workspace ? t.workspace.name : (d.workspace ? d.workspace.name : ""),
                mapped: d.mapped !== false,
                hidden: d.hidden === true,
                minimized: parkedList.indexOf(address) >= 0,
                floating: d.floating === true,
                pinned: d.pinned === true,
                fullscreen: typeof d.fullscreen === "number" ? d.fullscreen : 0,
                x: at[0],
                y: at[1],
                w: size[0],
                h: size[1]
            };
        });
        const focused = [];
        [root.focusedToplevel, root.frontToplevel].forEach(top => {
            const address = top ? addressOf(top) : "";
            if (address !== "" && focused.indexOf(address) < 0)
                focused.push(address);
        });
        const monitors = Hyprland.monitors ? Hyprland.monitors.values : [];
        return {
            windows: windows,
            focused: focused,
            shown: monitors.filter(m => m.activeWorkspace).map(m => m.activeWorkspace.id),
            parked: [minimizedWorkspace, hiddenWorkspace, ShowDesktop.PARKING]
        };
    }

    // Running toplevels belonging to an app id (case-insensitive, as desktop entry ids and
    // Wayland app ids differ in case for some toolkits).
    function toplevelsFor(appId: string): var {
        const wanted = appId.toLowerCase();
        const out = [];
        const all = root.toplevels ? root.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].appId.toLowerCase() === wanted)
                out.push(all[i]);
        }
        return out;
    }
}
