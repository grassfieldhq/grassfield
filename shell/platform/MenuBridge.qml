pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Grassfield.Ui
import qs.services // layering-exception: GF-087
import qs.lib
import "MenuBridge.js" as Logic
import "Ongoing.js" as Ongoing
import "Minimized.js" as Minimized
import "QuickLook.js" as QuickLook

// Global menus of applications (T1/T2, master-prompt §5.7, ADR-0008, docs/specs/menu-bridge.md).
//
// The plugin announces, per window, the DBusMenu (service, path) its client registered through
// org_kde_kwin_appmenu, with the client's pid (gfc/1 `appmenu` events); a Wayland window without one comes with its
// client's pid only, and the bridge serves it a menu that process registered with com.canonical.AppMenu.Registrar
// (Electron, ADR-0008 amendment 2026-10-25). This service keeps that map, connects to
// grassfield-menu-bridge (menu/1 socket), tells it whether the plugin serves appmenu (only then does the bridge own
// com.canonical.AppMenu.Registrar), asks it to open the focused window's menu and exposes the result to the menu
// bar. Without a bridge, a plugin or a menu for the window, `menus` stays empty and the bar keeps its T0 menus.
Singleton {
    id: root

    // Bridge socket. In a dev session only GRASSFIELD_MENU_BRIDGE_SOCKET counts (scripts/dev/shell-run.sh sets it together
    // with the private bus; Mode.devValue is empty anywhere else); in the session the default is
    // $XDG_RUNTIME_DIR/grassfield/menu-bridge.sock, also when a GRASSFIELD_DEV=1 leaked into it (the bridge follows the same rule).
    readonly property string socketPath: {
        const explicit = Mode.devValue("MENU_BRIDGE_SOCKET");
        if (explicit)
            return String(explicit);
        if (Mode.dev)
            return "";
        const runtime = Quickshell.env("XDG_RUNTIME_DIR");
        return runtime ? String(runtime) + "/grassfield/menu-bridge.sock" : "";
    }
    // The plugin serves org_kde_kwin_appmenu: the bridge may own the registrar (apps then hide in-window menus).
    readonly property bool appmenuFeature: Capabilities.has("appmenu")
    readonly property bool connected: socket.connected
    // The bridge owns com.canonical.AppMenu.Registrar (its latest status).
    property bool registrar: false
    property bool helloSent: false

    // Hyprland window address (lowercase hex) -> {service, path, pid}, from the plugin's appmenu events. An entry with an
    // empty service is a Wayland window without a set_address menu: {service: "", path: "", pid} (open-registered).
    property var registrations: ({})
    // Windows whose appmenu event was re-requested from the plugin (once each).
    property var queried: ({})
    // Window whose menus the bar shows: the focused window, kept while a shell popup holds the keyboard focus.
    property string window: ""
    // Window whose menu the bridge was asked to open, and the registration it was opened with.
    property string openedWindow: ""
    property var openedRegistration: null
    // Latest sanitized menu tree of openedWindow ([] until the bridge answers) and its revision.
    property var items: []
    property string itemsWindow: ""
    property int revision: 0
    // Top-level menus of the shown window: [{dbusId, title, enabled}]; [] means "no T1/T2 menu" (T0 stays).
    readonly property var menus: connected && itemsWindow !== "" && itemsWindow === window ? Logic.topLevel(items) : []
    // App id of `window` (the bar shows bridge menus only for the app it names).
    readonly property string windowAppId: {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (Minimized.normalizeAddress(all[i].address) === root.window)
                return all[i].wayland ? all[i].wayland.appId : "";
        }
        return "";
    }
    // Applications' own Dock badge, progress and urgent hint (ADR-0018): lower-case desktop id -> {count?, progress?,
    // urgent}, from the bridge's launcher lines (MenuBridge.js applyLauncher). Empty without a bridge: the Dock then
    // keeps its notification-derived badges.
    property var launcher: ({})
    // A launcher line was applied (msg: the parsed line); the Dock turns urgent into its attention bounce.
    signal launcherUpdate(var msg)
    // Applications hold org.freedesktop.ScreenSaver idle inhibitors (GF-016, the bridge's screensaver lines): the idle
    // module neither dims nor locks on idle while true. False without a bridge (the idle lock always works then).
    property bool screenSaverInhibited: false
    // A bridge that hangs without exiting stops repeating its screensaver line (every 20 s): after this long without one,
    // "inhibited" is dropped (fail closed: idle locking on). A property so that a test can shorten it.
    property int screensaverStaleMs: Logic.limits.screensaverStaleMs

    Timer {
        id: screensaverWatch
        interval: root.screensaverStaleMs
        onTriggered: {
            if (root.screenSaverInhibited)
                console.warn("grassfield: menu bridge: no screensaver heartbeat for " + root.screensaverStaleMs + " ms; idle inhibitors ignored");
            root.screenSaverInhibited = false;
        }
    }

    // Applications' ongoing activities (ADR-0052): Ongoing.js state built from the bridge's ongoing lines, drawn by the menu
    // bar (one item each) and its "ongoing" popover. Empty without a bridge. The bridge sends them redacted (no app, text or
    // button) until this shell reports the session unlocked, and the menu bar redacts them again while locked.
    property var ongoing: Ongoing.empty()
    // One clock for every ongoing time (the menu bar item and the popover): two timers of their own ticked a second apart, so
    // the same timer read two different times (review of the Luma pull request, nested finding 10). It ticks once a second
    // while some activity shows a time that moves.
    property real ongoingNow: Date.now()
    readonly property bool ongoingTicking: Ongoing.ticking(Object.values(root.ongoing.items))
    onOngoingTickingChanged: {
        if (root.ongoingTicking)
            root.ongoingNow = Date.now();
    }
    Timer {
        interval: Tokens.ongoingTickMs
        repeat: true
        running: root.ongoingTicking
        onTriggered: root.ongoingNow = Date.now()
    }
    readonly property bool sessionLocked: SessionState.locked
    onSessionLockedChanged: root.sendLock()

    function sendLock(): void {
        send(Ongoing.lockLine(SessionState.locked));
    }

    // The user chose button `action` of activity `id`: the bridge sends it to the application that published it. False when
    // nothing was sent (locked, no bridge, invalid).
    function ongoingAction(id: string, action: string): bool {
        const line = Ongoing.actionLine(id, action);
        if (SessionState.locked || line === "" || !socket.connected)
            return false;
        send(line);
        return true;
    }

    // Applies one parsed screensaver line (handleLine; tests call it directly).
    function applyScreensaver(msg: var): void {
        root.screenSaverInhibited = msg.inhibited === true;
        screensaverWatch.restart();
    }
    // The open bridge menu popup (BridgeMenu registers itself; read by the menubar test hook), null if none.
    property Item popup: null

    // PopupMenu model of a menu (its children) in the latest tree; `rev` makes bindings follow new revisions.
    function popupModel(dbusId: int, rev: int): var {
        const it = rev >= 0 ? Logic.findItem(root.items, dbusId) : null;
        return it ? Logic.popupModel(it.children) : [];
    }

    function aboutToShow(dbusId: int): void {
        send(Logic.itemLine("about-to-show", root.openedWindow, dbusId));
    }

    // Choosing an item (the caller closed the menu first): its action reaches the application once the item's window has
    // the keyboard back (macOS sends a menu's action after the menu closed). An Electron click handler runs for its focused
    // window only (Electron passes BaseWindow.getFocusedWindow() to it), and no window is focused while the popup holds the
    // keyboard (measured with Obsidian, Electron 43: sent with the popup open, File > New Window did nothing; a fixed
    // 120 ms wait failed 1 run in 3 in a loaded session). So, when the popup held the keyboard (`keyboardHeld`; a press,
    // drag and release leaves it with the window), the line waits for the plugin's keyboard-focus event naming that window
    // (Tokens.focusReturnMenuActionSettleMs more after it, for the application to read its keyboard enter first), and goes
    // anyway Tokens.focusReturnMenuActionWaitMs after this call when no such event comes (a plugin without the
    // keyboard-focus feature, or the keyboard went to another window).
    function activate(dbusId: int, keyboardHeld: bool): void {
        const line = Logic.itemLine("activate", root.openedWindow, dbusId);
        if (line === "")
            return;
        flushActivation(); // a choice still waiting goes first (one choice closes the menu: not expected)
        if (!keyboardHeld) {
            send(line);
            return;
        }
        root.pendingActivation = line;
        root.pendingActivationWindow = root.openedWindow;
        activationFallback.restart();
    }

    // An item's action waiting for its window to get the keyboard back ("" when none), and that window.
    property string pendingActivation: ""
    property string pendingActivationWindow: ""

    function flushActivation(): void {
        activationSettle.stop();
        activationFallback.stop();
        const line = root.pendingActivation;
        root.pendingActivation = "";
        root.pendingActivationWindow = "";
        send(line);
    }

    // The plugin says the keyboard entered `address`: the waiting action of that window goes after the settle time.
    function keyboardEntered(address: string): void {
        if (root.pendingActivation !== "" && address === root.pendingActivationWindow && !activationSettle.running)
            activationSettle.start();
    }

    Timer {
        id: activationSettle
        interval: Tokens.focusReturnMenuActionSettleMs
        onTriggered: root.flushActivation()
    }

    Timer {
        id: activationFallback
        interval: Tokens.focusReturnMenuActionWaitMs
        onTriggered: root.flushActivation()
    }

    function send(line: string): void {
        if (line === "" || !socket.connected)
            return;
        socket.write(line);
        socket.flush();
    }

    function sameRegistration(a: var, b: var): bool {
        return !!a && !!b && a.service === b.service && a.path === b.path && a.pid === b.pid;
    }

    // Makes the bridge's open menu follow `window` and its registration.
    function syncOpen(): void {
        const reg = root.window !== "" ? root.registrations[root.window] : undefined;
        const wanted = reg ? root.window : "";
        if (root.openedWindow !== "" && (root.openedWindow !== wanted || !sameRegistration(root.openedRegistration, reg))) {
            send(Logic.closeLine(root.openedWindow));
            root.openedWindow = "";
            root.openedRegistration = null;
            root.items = [];
            root.itemsWindow = "";
        }
        if (wanted === "" || root.openedWindow !== "" || !socket.connected || !root.helloSent)
            return;
        const line = reg.service === "" ? Logic.openRegisteredLine(wanted, reg.pid) : Logic.openLine(wanted, reg);
        if (line === "")
            return; // e.g. a plugin without the pid field: no T1/T2 menu
        send(line);
        root.openedWindow = wanted;
        root.openedRegistration = reg;
    }

    function setWindow(address: string): void {
        if (address === root.window)
            return;
        root.window = address;
        // A window this shell has not heard about (it started after the window registered): ask the plugin once.
        if (address !== "" && root.registrations[address] === undefined && root.appmenuFeature && !root.queried[address]) {
            root.queried[address] = true;
            const call = Minimized.appmenuCall(address);
            if (call !== "")
                Hyprland.dispatch(call);
        }
        syncOpen();
    }

    // The foreign-toplevel focused window's Hyprland address, once Hyprland's window data maps it. A binding: it
    // follows the list and each window's mapping (`wayland`), which arrive asynchronously after a shell start.
    readonly property string mappedFocus: {
        const focused = Compositor.focusedToplevel;
        const mapped = focused ? Compositor.hyprlandToplevel(focused) : null;
        return mapped ? Minimized.normalizeAddress(mapped.address) : "";
    }

    onMappedFocusChanged: updateFocus()

    // Hyprland address of the focused window. Hyprland's active window is known only after its first focus event,
    // so right after a (shell) start the foreign-toplevel activated state (mappedFocus) stands in for it.
    function focusedAddress(): string {
        const top = Hyprland.activeToplevel;
        const address = top ? Minimized.normalizeAddress(top.address) : "";
        return address !== "" ? address : root.mappedFocus;
    }

    // The app id of the Hyprland window at `address` ("" when Hyprland's window data does not map it yet).
    function appIdAt(address: string): string {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (Minimized.normalizeAddress(all[i].address) === address)
                return all[i].wayland ? all[i].wayland.appId : "";
        }
        return "";
    }

    // The last focused window that was not a quick look (Glance): its menus stay while the quick look has the focus (macOS:
    // Quick Look belongs to the app that opened it).
    property string regularWindow: ""

    function updateFocus(): void {
        let address = focusedAddress();
        if (address !== "") {
            const appId = appIdAt(address);
            if (QuickLook.isQuickLook(appId))
                address = Compositor.quickLookFromDesktop ? "" : root.regularWindow;
            else if (appId !== "")
                root.regularWindow = address;
        }
        // A shell popup (menus) takes the keyboard: the bar keeps showing the app's menus meanwhile.
        if (address !== "" || !Popups.active)
            setWindow(address);
    }

    function handlePluginEvent(data: string): void {
        const entered = Logic.parseKeyboardFocusEvent(data);
        if (entered !== null) {
            keyboardEntered(entered);
            return;
        }
        const ev = Logic.parseAppmenuEvent(data);
        if (!ev)
            return;
        const next = Object.assign({}, root.registrations);
        if (ev.service === "" && ev.pid === 0)
            delete next[ev.address];
        else
            next[ev.address] = {service: ev.service, path: ev.path, pid: ev.pid};
        root.registrations = next;
        if (ev.address === root.window || ev.address === root.openedWindow)
            syncOpen();
    }

    function sendHello(): void {
        send(Logic.helloLine(root.appmenuFeature));
        root.helloSent = true;
        root.sendLock(); // the bridge counts the session locked until told (ADR-0052)
        syncOpen();
    }

    function handleLine(line: string): void {
        const msg = Logic.parseBridgeLine(line);
        if (!msg) {
            console.info("grassfield: menu bridge: ignored a malformed line");
            return;
        }
        switch (msg.type) {
        case "status":
            if (root.registrar !== msg.registrar)
                console.info("grassfield: menu bridge", msg.state, msg.registrar ? "(registrar owned)" : "(registrar not owned)");
            root.registrar = msg.registrar;
            break;
        case "menu":
            if (msg.window === root.openedWindow) {
                root.items = msg.items;
                root.itemsWindow = msg.window;
                root.revision = msg.revision;
            }
            break;
        case "launcher":
            root.launcher = Logic.applyLauncher(root.launcher, msg);
            root.launcherUpdate(msg);
            break;
        case "screensaver":
            root.applyScreensaver(msg);
            break;
        case "ongoing": {
            const item = Ongoing.parse(msg.msg);
            if (item)
                root.ongoing = Ongoing.apply(root.ongoing, item);
            else
                console.info("grassfield: menu bridge: ignored a malformed ongoing activity");
            break;
        }
        case "ongoing-end":
            root.ongoing = Ongoing.end(root.ongoing, msg.id);
            break;
        case "error":
            console.info("grassfield: menu bridge:", msg.code, msg.window, msg.message);
            // The window's menu is unusable (spoofed name, app gone, unreadable, oversized or refused layout, also
            // when the refusal answers a re-read of a menu that was shown): clear it, back to T0 for the window.
            if (msg.window !== "" && msg.window === root.openedWindow && Logic.menuLost(msg.code)) {
                root.items = [];
                root.itemsWindow = "";
            }
            break;
        }
    }

    // After a shell restart the plugin knows registrations the shell missed: ask it to re-post them (FR22).
    function requery(): void {
        if (!root.appmenuFeature)
            return;
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            const call = Minimized.appmenuCall(all[i].address);
            if (call !== "")
                Hyprland.dispatch(call);
        }
        // The focused window may predate the feature (or the list): ask for it too.
        if (root.window !== "" && root.registrations[root.window] === undefined) {
            const call = Minimized.appmenuCall(root.window);
            if (call !== "")
                Hyprland.dispatch(call);
        }
    }

    onAppmenuFeatureChanged: {
        if (socket.connected)
            sendHello();
        if (appmenuFeature)
            requeryTimer.restart();
    }

    Socket {
        id: socket
        path: root.socketPath
        parser: SplitParser {
            onRead: data => root.handleLine(data)
        }
        onConnectedChanged: {
            if (connected) {
                root.helloSent = false;
                root.sendHello();
                return;
            }
            root.helloSent = false;
            root.registrar = false;
            // The bridge is gone: what the applications set is unknown (it is replayed when a bridge connects).
            root.launcher = {};
            // ... and their idle inhibitors no longer count: the idle lock works again (fail closed).
            root.screenSaverInhibited = false;
            screensaverWatch.stop();
            // ... and the activities it relayed are gone with it (their publishers' state is unknown).
            root.ongoing = Ongoing.empty();
            root.openedWindow = "";
            root.openedRegistration = null;
            root.items = [];
            root.itemsWindow = "";
        }
    }

    // Connects once the capabilities handshake settled (the hello must carry the real appmenu state) and retries
    // while the bridge is not there (it starts independently, may restart).
    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: root.socketPath !== "" && Capabilities.settled && !socket.connected
        onTriggered: socket.connected = true
    }

    Timer {
        id: requeryTimer
        interval: 500
        onTriggered: root.requery()
    }

    Connections {
        target: Hyprland

        function onActiveToplevelChanged(): void {
            root.updateFocus();
        }

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "grassfield")
                root.handlePluginEvent(event.data);
        }
    }

    Connections {
        target: Popups

        function onActiveChanged(): void {
            if (!Popups.active)
                root.updateFocus();
        }
    }
    Component.onCompleted: updateFocus()
}
