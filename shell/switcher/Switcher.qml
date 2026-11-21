pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.platform
import qs.platform.shortcuts
import qs.services
import "../platform/ScreenChoice.js" as ScreenChoice
import "../dock/DockModel.js" as DockModel
import "SwitcherModel.js" as Model

// App switcher controller (spec docs/specs/switcher.md; macOS Cmd+Tab): owns the session (Model.reduce), the app list and
// the IPC target `switcher`. SwitcherWindow renders it on the focused output.
//
// No compositor key map is involved. SUPER+TAB (config/hypr/grassfield/bindings.lua) sends `next <hold id>`; the session
// then holds an exclusive-keyboard layer surface (SwitcherWindow, transparent for the first showDelayMs) which sees the
// Super release itself, and the config's release bind sends `release <hold id>` as a second path. Whatever ends the
// session (release, Esc, click, another surface, session lock) unmaps the surface, and with it the grab.
Scope {
    id: root

    // Session reducer state (SwitcherModel.js): phase idle | pending (surface up, panel not drawn yet) | shown.
    property var session: Model.idle()
    readonly property string phase: session.phase
    readonly property bool shown: session.phase === "shown"
    // The session is running: the surface holds the keyboard (ExclusiveSurfaces closes the other surfaces when it starts).
    readonly property bool active: session.phase !== "idle"
    readonly property bool open: active
    // Key focus returns to the window active when the session started, unless a commit activates an app (FocusReturn).
    onActiveChanged: {
        if (active) {
            FocusReturn.opened("switcher");
        } else {
            // One turn later: a commit sets `target` right after the session state changes.
            Qt.callLater(() => {
                if (!root.active)
                    FocusReturn.closed("switcher", root.target === null);
            });
        }
    }
    readonly property int selected: session.selected
    // Apps in frozen MRU order for this session: {key, name, icon, entry, windows, stamp}.
    property var apps: []
    property string screenName: ""
    // True while the session lock (or its transition) owns the screen: the switcher neither starts nor stays.
    property bool locked: false
    // Hold id (one per physical hold of SUPER, from the compositor config) of the running or last session, and the highest
    // one whose release request has been seen. Orders the `next` and `release` processes, which can arrive either way.
    property real holdId: 0
    property real releasedId: 0
    // The layer surface may be mapped (set at session start, cleared by the compositor's closelayer event).
    property bool surfaceUp: false
    // App chosen by a commit, activated once the surface is gone.
    property var target: null

    // Surfaces of the shell itself are layer surfaces, never toplevels; this only guards against a window of the shell.
    readonly property var excluded: ["grassfield-shell", "quickshell"]
    readonly property string surfaceNamespace: "grassfield-switcher"

    function windowsNow(): var {
        const out = [];
        const tops = Compositor.toplevels ? Compositor.toplevels.values : [];
        for (let i = 0; i < tops.length; i++)
            out.push({appId: tops[i].appId, ref: tops[i]});
        return out;
    }

    function freshApps(): var {
        Apps.revision;
        return Model.apps(DockModel.merge, windowsNow(), Apps.lookup, t => Compositor.recency.has(t) ? Compositor.recency.get(t) : 0, excluded);
    }

    // Is the most recent app the one in front? (Tab then goes to the second app; with nothing focused, to the first.)
    function frontIsFirst(list: var): bool {
        const front = Compositor.focusedToplevel;
        return !!front && list.length > 0 && list[0].windows.indexOf(front) >= 0;
    }

    function apply(result: var): void {
        session = result.state;
        switch (result.action) {
        case "show":
            Popups.close();
            showTimer.stop();
            break;
        case "commit":
            showTimer.stop();
            commit(result.index);
            break;
        case "cancel":
            showTimer.stop();
            break;
        }
    }

    function parseId(id: string): real {
        const n = parseInt(id);
        return isNaN(n) ? 0 : n;
    }

    // dir: +1 (Tab, Right) or -1 (Shift+Tab, Left). Arrows only move a running session. `id`: hold id ("" = none).
    function step(dir: int, arrow: bool, id: string): void {
        if (arrow && session.phase === "idle")
            return;
        const hold = parseId(id);
        if (session.phase === "idle") {
            if (locked)
                return;
            const list = freshApps();
            const first = {type: "step", dir: dir, count: list.length, current: frontIsFirst(list)};
            if (hold > 0 && hold <= releasedId) {
                // A hold that already ended: a late key repeat of a session (ignored), or a quick tap whose release
                // request overtook this one (hold newer than any session: switch at once, no surface, no panel).
                if (hold <= holdId)
                    return;
                const started = Model.reduce(Model.idle(), first);
                holdId = hold;
                if (started.state.phase === "pending") {
                    apps = list;
                    commit(Model.reduce(started.state, {type: "release"}).index);
                }
                return;
            }
            apps = list;
            holdId = hold;
            screenName = targetScreen();
            surfaceUp = true;
            Popups.close();
            apply(Model.reduce(session, first));
            if (session.phase === "pending")
                showTimer.restart();
            else
                surfaceUp = false;
            return;
        }
        if (hold > holdId)
            holdId = hold;
        apply(Model.reduce(session, {type: "step", dir: dir, count: apps.length}));
    }

    // The output of the focused window, else the one with the pointer or keyboard focus.
    function targetScreen(): string {
        let name = Compositor.windowScreenName(Compositor.hyprlandToplevel(Compositor.focusedToplevel));
        if (name === "")
            name = Compositor.focusedScreenName;
        return name !== "" ? name : Compositor.activeScreenName;
    }

    // The screen the session is shown on went away (a display unplugged): the session continues on the active one.
    Connections {
        target: Quickshell

        function onScreensChanged(): void {
            root.screenName = ScreenChoice.replacement(root.screenName, Compositor.focusedScreenName, Quickshell.screens.map(s => s.name));
        }
    }

    // The modifier was released. `id`: hold id from the compositor config, "" from the surface's own key event.
    function release(id: string): void {
        const hold = parseId(id);
        if (hold > 0 && session.phase === "idle") {
            // No session: either before its own `next` request (a quick tap) arrives, or after the session ended
            // (Esc, click); either way that hold has ended, so a late `next` of it must not start a session.
            releasedId = Math.max(releasedId, hold);
            return;
        }
        if (hold > 0 && hold < holdId)
            return;
        releasedId = Math.max(releasedId, hold, holdId);
        apply(Model.reduce(session, {type: "release"}));
    }

    function cancel(): void {
        apply(Model.reduce(session, {type: "cancel"}));
    }

    function hover(index: int): void {
        apply(Model.reduce(session, {type: "hover", index: index}));
    }

    function click(index: int): void {
        apply(Model.reduce(session, {type: "click", index: index}));
    }

    // Q while running: ask every window of the selected app to close (the Dock's Quit path; never a kill).
    function quitSelected(): void {
        const app = apps[selected];
        if (!active || !app)
            return;
        app.windows.forEach(t => Compositor.close(t));
    }

    // H while running: hide the selected app.
    function hideSelected(): void {
        const app = apps[selected];
        if (!active || !app)
            return;
        app.windows.forEach(t => Compositor.hide(t));
    }

    // Raises the app's windows. Hyprland refuses to focus a window while an exclusive layer surface exists, so with the
    // surface up the activation waits for the compositor's closelayer event (layerWait is only the fallback).
    function commit(index: int): void {
        const app = apps[index];
        if (!app)
            return;
        target = app;
        if (surfaceUp)
            layerWait.restart();
        else
            activateTarget();
    }

    // The app's most recent window not minimized (else the most recent one) is raised last, so it ends up focused; the
    // other windows the app has hidden come back with it (macOS: activating a hidden app unhides all its windows).
    // Compositor.activate un-minimizes, brings a hidden window to the focused Space and activates it; Hyprland then
    // switches to the window's Space and, with Stages, brings its stage forward (ST10). The tile group of that window comes
    // forward with it (TL29).
    function activateTarget(): void {
        const app = target;
        target = null;
        layerWait.stop();
        if (!app)
            return;
        const live = app.windows.filter(t => !Compositor.isMinimized(t));
        const pool = live.length > 0 ? live : app.windows;
        const main = Compositor.mostRecent(pool) || pool[0];
        app.windows.filter(t => t !== main && Compositor.isHidden(t)).forEach(t => Compositor.activate(t));
        Compositor.activateWithGroup(main);
    }

    Timer {
        id: showTimer
        interval: Tokens.switcherShowDelayMs
        onTriggered: root.apply(Model.reduce(root.session, {type: "timer"}))
    }

    // closelayer never arrived (event stream trouble): activate anyway.
    Timer {
        id: layerWait
        interval: Tokens.switcherLayerWaitMs
        onTriggered: root.activateTarget()
    }

    onLockedChanged: {
        if (locked)
            cancel();
    }

    Connections {
        target: Compositor

        function onLayerClosed(namespace: string): void {
            if (namespace !== root.surfaceNamespace)
                return;
            if (root.active)
                return;
            root.surfaceUp = false;
            if (root.target)
                root.activateTarget();
        }
    }

    // Apps quit or closed while the session is running.
    Connections {
        target: Compositor.toplevels

        function onValuesChanged(): void {
            if (root.phase === "idle")
                return;
            const current = root.apps[root.selected];
            const next = Model.refresh(root.apps, root.freshApps());
            root.apps = next;
            const index = current ? next.findIndex(a => a.key === current.key) : -1;
            root.apply(Model.reduce(root.session, {type: "count", count: next.length, selected: index}));
        }
    }

    IpcHandler {
        target: "switcher"
        // A key binding calls it: it answers the key in-process (platform/shortcuts, CIO-01).
        Component.onCompleted: Shortcuts.attach(this)

        function next(id: string): void {
            root.step(1, false, id);
        }

        function previous(id: string): void {
            root.step(-1, false, id);
        }

        // Test hooks (dev session only, VisualFixtures.dev, SEC-04): right, left, cancel and status. next, previous,
        // release, quit and hide are the SUPER+TAB / SUPER+Q / SUPER+H bindings.
        function right(): void {
            if (VisualFixtures.dev)
                root.step(1, true, "");
        }

        function left(): void {
            if (VisualFixtures.dev)
                root.step(-1, true, "");
        }

        function release(id: string): void {
            root.release(id);
        }

        function cancel(): void {
            if (VisualFixtures.dev)
                root.cancel();
        }

        function quit(): void {
            root.quitSelected();
        }

        function hide(): void {
            root.hideSelected();
        }

        function status(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return JSON.stringify({phase: root.phase, selected: root.selected, apps: root.apps.map(a => a.key), holdId: root.holdId, releasedId: root.releasedId, surfaceUp: root.surfaceUp});
        }
    }
}
