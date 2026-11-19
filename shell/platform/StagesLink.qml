pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.platform.shortcuts
import qs.services // layering-exception: GF-087
import "Minimized.js" as Minimized
import "StagesState.js" as StagesState

// The shell's side of the compositor plugin's Stages (docs/specs/stages.md "Shell contract"): capability, the user's
// setting, the plugin's change notices, the state they announce (`grassfield-stages`, asked on Hyprland's request socket in
// process: HyprQuery, what `hyprctl grassfield-stages` asks without a process per notice) and the `stages` verb. Only
// this file (with Compositor and Capabilities) talks to the compositor; the strip surfaces (shell/stages) read it, and
// Compositor gets each state for the menu bar (applyStagesState). Event-driven; without the plugin or without
// `stages-available` nothing here is ever active, fetched or sent.
Singleton {
    id: root

    // The plugin offers Stages (the Quick Settings toggle and the Settings entry exist only then).
    readonly property bool available: Capabilities.has("stages-available")
    // The user's setting (windows.stages, off by default).
    readonly property bool enabled: Settings.windowsStages
    // The plugin's flag is on (`stages` capability): the strips may be mapped and `op:on` sent.
    readonly property bool flagOn: Capabilities.has("stages")
    readonly property bool active: available && enabled && flagOn

    // Last state (StagesState.parse of `hyprctl grassfield-stages`, or the off state of a notice) or null: none yet, Stages
    // not active, or the state could not be fetched (the strip hides rather than show a stale state as current).
    property var state: null
    // The fetch of the state (StagesState.newFetch); StagesState decides, this file runs it.
    property var fetch: StagesState.newFetch()
    // The running fetch's reply is still wanted (false once it timed out: a stopped fetch's late output is dropped).
    property bool awaiting: false
    // A fetch was asked while the previous request was still out: start it when that one ends.
    property bool startPending: false
    // The request out (a HyprQuery) or null; the fetches started (tests).
    property var query: null
    property int queries: 0
    readonly property bool on: state !== null && state.on
    // Last refusal or end reason of an event ("" none): invalid | disabled | no-strip | unknown | unavailable | interrupted.
    property string reason: ""

    // A refusal or interruption that asks the strip to send `op:on` again (`no-strip`, `interrupted`).
    signal resendNeeded(string reason)
    // The capabilities say Stages is on (also after each reload of the plugin): send `op:on` again.
    signal resumed

    function monitorState(name: string): var {
        return state && state.monitors[name] ? state.monitors[name] : null;
    }

    // What a step of the fetch needs to know: may Stages run, what is shown, the time.
    function context(): var {
        return {active: root.active, shown: root.state, now: Date.now()};
    }

    // Applies a step of the fetch (StagesState.onNotice/onReply/onTimeout/onRetry/onTick). `text`: the reply the step
    // parsed ("" for the others); Compositor gets it with each new state, nothing when the state is off or unknown.
    function step(out: var, text: string): void {
        root.fetch = out.fetch;
        if (out.state !== undefined) {
            root.state = out.state;
            Compositor.applyStagesState(out.state && out.state.on ? text : "");
        }
        if (out.retryMs > 0) {
            retryTimer.interval = out.retryMs;
            retryTimer.restart();
        }
        if (out.staleMs > 0) {
            staleTimer.interval = out.staleMs;
            staleTimer.restart();
        } else {
            staleTimer.stop();
        }
        if (out.start)
            root.startFetch();
    }

    function startFetch(): void {
        retryTimer.stop();
        root.awaiting = true;
        fetchDeadline.restart();
        if (root.query !== null)
            root.startPending = true;
        else
            root.startQuery();
    }

    function startQuery(): void {
        root.queries++;
        const path = Hyprland.requestSocketPath || "";
        if (path === "")
            return; // nothing to ask: the deadline fails the fetch (as a hyprctl that could not start)
        const q = hyprQuery.createObject(root, {path: path, line: "grassfield-stages", answerMs: StagesState.fetchDeadlineMs});
        root.query = q;
        q.answered.connect((text, ok) => {
            if (root.query !== q)
                return; // the fetch ended meanwhile
            root.query = null;
            if (root.startPending) {
                root.startPending = false;
                root.startQuery();
                return;
            }
            if (!root.awaiting)
                return;
            root.awaiting = false;
            fetchDeadline.stop();
            root.step(StagesState.onReply(root.fetch, text, root.context()), text);
        });
    }

    Component {
        id: hyprQuery
        HyprQuery {}
    }

    // Stages is no longer active: no state, no fetch, nothing pending (a fetch still running ends unheard).
    function reset(): void {
        retryTimer.stop();
        staleTimer.stop();
        fetchDeadline.stop();
        root.awaiting = false;
        root.startPending = false;
        root.query = null;
        root.fetch = StagesState.newFetch();
        root.state = null;
        Compositor.applyStagesState("");
    }

    // Sends an operation through Compositor.stages (the plugin validates every field); false (nothing sent) when Stages is not
    // active or the request is not one of its operations.
    function send(request: var): bool {
        if (!root.active)
            return false;
        return Compositor.stages(request);
    }

    // Window class of a Hyprland window address (lower-case hex, no 0x), "" when unknown. `revision` makes bindings
    // re-evaluate (Compositor.topologyRevision).
    function appIdOf(address: string, revision: int): string {
        const wanted = Minimized.normalizeAddress(address);
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            const top = all[i];
            if (Minimized.normalizeAddress(top.address) !== wanted)
                continue;
            if (top.wayland && top.wayland.appId !== "")
                return top.wayland.appId;
            const data = top.lastIpcObject;
            return data && data["class"] ? data["class"] : "";
        }
        return "";
    }

    onActiveChanged: {
        if (active)
            resumed();
        else
            reset();
    }

    Connections {
        target: Capabilities

        // A capabilities event with `stages` (plugin reloaded, flag pushed): the strip sends `op:on` again (contract 7).
        function onFeaturesChanged(): void {
            if (root.active)
                root.resumed();
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name !== "grassfield")
                return;
            // The event is only a change notice (Hyprland cuts socket2 events at 1024 bytes): the state is fetched.
            const notice = StagesState.parseNotice(event.data);
            if (!notice)
                return;
            root.reason = notice.reason;
            root.step(StagesState.onNotice(root.fetch, notice, root.context()), "");
            if (notice.reason === "no-strip" || notice.reason === "interrupted")
                root.resendNeeded(notice.reason);
        }
    }

    // A fetch that has not answered in this time failed (also covers no Hyprland to ask). One request at a time; its reply, a
    // failure or this deadline ends the fetch.
    Timer {
        id: fetchDeadline

        interval: StagesState.fetchDeadlineMs
        onTriggered: {
            if (!root.awaiting)
                return;
            root.awaiting = false;
            root.startPending = false;
            root.query = null;
            root.step(StagesState.onTimeout(root.fetch, root.context()), "");
        }
    }

    Timer {
        id: retryTimer

        onTriggered: root.step(StagesState.onRetry(root.fetch, root.context()), "")
    }

    // The time bound on a state no successful fetch has confirmed since a newer notice (StagesState.staleAfterMs).
    Timer {
        id: staleTimer

        onTriggered: root.step(StagesState.onTick(root.fetch, root.context()), "")
    }

    // Test hook (tests/visual waits on it): `qs ipc call stages status` is "unavailable" without `stages-available`,
    // else "off" | "ready" with the number of strip stages per monitor.
    IpcHandler {
        target: "stages"
        // A key binding calls it: it answers the key in-process (platform/shortcuts, CIO-01).
        Component.onCompleted: Shortcuts.attach(this)

        function status(): string {
            if (!VisualFixtures.dev)
                return "refused";
            if (!root.available)
                return "unavailable";
            if (!root.on)
                return root.enabled ? "waiting" : "off";
            const names = Object.keys(root.state.monitors);
            return "ready " + names.map(n => n + "=" + StagesState.stripStages(root.state.monitors[n]).length).join(",");
        }

        // Keyboard and scripting access (the strip itself takes no keyboard): the n-th strip stage (1 = most recent) of the
        // focused output comes forward, as a click on its tile.
        function activate(position: int): string {
            const mon = root.monitorState(Compositor.focusedScreenName);
            const stage = mon ? StagesState.stripStages(mon)[position - 1] : undefined;
            return stage && root.send({op: "activate", stage: stage.id}) ? "ok" : "refused";
        }

        // The focused window becomes a stage of its own (macOS: drag it to the strip).
        function newStage(): string {
            const w = Compositor.activeWindow();
            return w && root.send({op: "move", address: "0x" + Minimized.normalizeAddress(w.address), stage: "new"}) ? "ok" : "refused";
        }

        function enable(on: bool): string {
            if (!VisualFixtures.dev)
                return "refused";
            Settings.setStagesEnabled(on);
            return "ok";
        }
    }
}
