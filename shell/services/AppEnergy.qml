pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.lib
import qs.platform
import "AppEnergyLogic.js" as Logic

// Apps the person cannot see get less CPU and I/O; the app in front never (ADR-0048; Settings > Battery > Options…,
// energy.slowHiddenApps, on by default). This file only gathers the picture and runs the helper: what each window and
// process counts as is AppEnergyLogic.js, the claims and the limits are packaging/bin/grassfield-energy (an argv, never a
// service). Event-driven: the picture is judged 250 ms after the last change and the helper runs when it changed, or when
// the helper asked to run again (an app waiting for its delay, or limits held: at most every 60 s). Nothing runs while every
// app is in sight and nothing is held.
// Dev sessions (Mode.dev): the nested session's windows belong to processes in the owner's own scopes, so every command is
// a dry run on a state file under the dev state directory (decided and recorded, never applied).
Singleton {
    id: root

    readonly property bool enabled: Settings.energySlowHiddenApps
    readonly property bool onBattery: Battery.onBattery
    // The person is looking for an app (overview or app switcher open; shell.qml binds it): everything counts as visible.
    property bool awake: false

    readonly property string program: Mode.dev ? Quickshell.shellPath("../packaging/bin/grassfield-energy") : "/usr/lib/grassfield/grassfield-energy"
    readonly property var base: Mode.dev ? [program, "--dry-run", "--state", Mode.stateDir + "/app-energy.json"] : [program]

    // The PipeWire streams and the processes behind them (playing or recording: never limited). The stream nodes are bound
    // so that their properties (pipewire.sec.pid, set by the PipeWire server) are known.
    readonly property var streams: (Pipewire.nodes ? Pipewire.nodes.values : []).filter(n => n.isStream)
    readonly property var mediaPids: Logic.streamPids(streams.map(n => n.properties))

    // The last picture sent ({pid: state}), its digest, and what the helper said: limits held or a run asked for.
    property var sent: ({})
    property string lastDigest: ""
    property bool engaged: false
    // The start's reset (crash recovery) has finished: rounds may run.
    property bool resetDone: false
    // The helper asked to run again: the next judgement runs a round even with an unchanged picture.
    property bool roundDue: false
    property bool roundAgain: false
    // Wakes asked while one runs: process ids, or null for all (merged; a null wins).
    property var wakeQueue: []
    property bool wakeAllQueued: false
    property double lastRefreshAt: 0
    // When Hyprland's window data (geometry) was last asked to be read again (needsFreshGeometry).
    property double geometryAt: 0

    // Judge the picture now and run a round when it changed (or one is due).
    function judge(): void {
        if (!root.resetDone || !root.enabled)
            return;
        // On the power adapter nothing is limited (ADR-0048 D-2): a round runs only to lift what is still held.
        if (!Logic.roundWanted(root.onBattery, root.engaged)) {
            root.lastDigest = "";
            return;
        }
        if (roundProc.running) {
            root.roundAgain = true;
            return;
        }
        const snap = Compositor.energySnapshot();
        const result = Logic.evaluate(snap.windows, {
            focused: snap.focused,
            shown: snap.shown,
            parked: snap.parked,
            strip: Logic.stripStates(StagesLink.state),
            awake: root.awake
        });
        if (result.uncertain && Date.now() - root.lastRefreshAt > Logic.refreshGapMs) {
            root.lastRefreshAt = Date.now();
            Compositor.requestWindowRefresh();
        }
        // An occluded window is judged on fresh geometry (no event tells a move or a resize): read it again first; its
        // arrival (topologyRevision) judges the picture again.
        if (Logic.needsFreshGeometry(result.pids, root.geometryAt, Date.now())) {
            root.geometryAt = Date.now();
            Compositor.requestWindowRefresh();
            return;
        }
        const digest = Logic.digest(result.pids, root.onBattery ? "battery" : "mains", root.mediaPids);
        const due = root.roundDue;
        root.roundDue = false;
        if (digest === root.lastDigest && !due)
            return;
        root.lastDigest = digest;
        root.sent = result.pids;
        // Nothing can be limited and nothing is held: the helper has nothing to do.
        if (!root.engaged && !Logic.anyLimitable(result.pids))
            return;
        roundProc.command = Logic.roundArgs(root.base, result.pids, root.onBattery, root.mediaPids);
        roundProc.running = true;
    }

    // Lift the limits of these processes' apps at once (no debounce); null: every app. Only when something may be held.
    function wake(pids: var): void {
        if (!root.resetDone || !root.engaged)
            return;
        if (pids === null) {
            root.wakeAllQueued = true;
        } else {
            // A process last seen focused or visible is in no limited app (an app takes its most awake window).
            const wanted = pids.filter(p => p > 0 && root.sent[String(p)] !== "focused" && root.sent[String(p)] !== "visible");
            if (wanted.length === 0)
                return;
            root.wakeQueue = root.wakeQueue.concat(wanted);
        }
        root.startWake();
    }

    // The Dock activates an app: its windows' processes are woken before they come forward.
    function wakeToplevels(toplevels: var): void {
        root.wake((toplevels || []).filter(t => !!t).map(t => Compositor.pidOf(t)));
    }

    function startWake(): void {
        if (wakeProc.running || (!root.wakeAllQueued && root.wakeQueue.length === 0))
            return;
        wakeProc.command = Logic.wakeArgs(root.base, root.wakeAllQueued ? null : root.wakeQueue);
        root.wakeAllQueued = false;
        root.wakeQueue = [];
        wakeProc.running = true;
    }

    function resetAll(): void {
        root.engaged = false;
        root.lastDigest = "";
        root.sent = ({});
        tick.stop();
        if (!resetProc.running)
            resetProc.running = true;
    }

    PwObjectTracker {
        objects: root.streams
    }

    Process {
        id: resetProc

        command: Logic.resetArgs(root.base)
        onRunningChanged: {
            if (running)
                return;
            root.resetDone = true;
            settle.restart();
        }
    }

    Process {
        id: roundProc

        stdout: StdioCollector {
            onStreamFinished: {
                // Turned off while this round ran (it may have taken the helper's lock after the reset): reset again.
                if (!root.enabled) {
                    root.resetAll();
                    return;
                }
                const next = Logic.nextRunMs(text);
                root.engaged = next > 0;
                if (next > 0) {
                    tick.interval = next;
                    tick.restart();
                } else {
                    tick.stop();
                }
            }
        }
        onRunningChanged: {
            if (!running && root.roundAgain) {
                root.roundAgain = false;
                settle.restart();
            }
        }
    }

    Process {
        id: wakeProc

        onRunningChanged: {
            if (!running)
                root.startWake();
        }
    }

    // The picture settles before it is judged.
    Timer {
        id: settle

        interval: Logic.settleMs
        onTriggered: root.judge()
    }

    // The helper asked to run again: fresh window data first (geometry has no event), then a round.
    Timer {
        id: tick

        onTriggered: {
            root.roundDue = true;
            root.geometryAt = Date.now();
            Compositor.requestWindowRefresh();
            settle.restart();
        }
    }

    Connections {
        target: Compositor

        function onFocusedToplevelChanged(): void {
            if (Compositor.focusedToplevel)
                root.wake([Compositor.pidOf(Compositor.focusedToplevel)]);
            settle.restart();
        }

        function onTopologyRevisionChanged(): void {
            settle.restart();
        }

        function onMinimizedChanged(): void {
            settle.restart();
        }

        function onAttention(address: string): void {
            const w = Compositor.energySnapshot().windows.find(x => x.address === address);
            if (w)
                root.wake([w.pid]);
        }
    }

    Connections {
        target: StagesLink

        function onStateChanged(): void {
            settle.restart();
        }
    }

    onAwakeChanged: {
        if (awake)
            root.wake(null);
        settle.restart();
    }

    onOnBatteryChanged: {
        // Back on the power adapter: everything is lifted now, and nothing more is limited until it is unplugged.
        if (!onBattery)
            root.wake(null);
        settle.restart();
    }

    onEnabledChanged: {
        if (enabled)
            settle.restart();
        else
            root.resetAll();
    }

    onMediaPidsChanged: settle.restart()

    // Crash recovery: whatever an earlier shell left applied is lifted before anything is judged.
    Component.onCompleted: resetProc.running = true

    // A clean exit leaves nothing behind (a crash: grassfield-shell.service runs the reset in ExecStopPost).
    Component.onDestruction: {
        if (root.engaged)
            Quickshell.execDetached(Logic.resetArgs(root.base));
    }
}
