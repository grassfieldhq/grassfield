pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Grassfield.Ui
import qs.lib
import "DisplaysFile.js" as DisplaysFile

// Settings > Displays' link to the compositor (ADR-0031). The shell is the only Grassfield process that talks to Hyprland:
// - it publishes the monitors (Hyprland's own `monitors` answer, through Quickshell), the backlight and the trial's state in
//   a runtime file the Settings app reads (DisplaysFile.js has the format and the paths);
// - it runs a trial: when Settings writes the trial file, it asks Hyprland to read its configuration again (the request
//   `reload` through SessionConfig; config/hypr/grassfield/displays.lua applies the trial while it runs), publishes it
//   `applying`, then `applied` once Hyprland answers that very request (it has read the configuration: Settings takes Keep
//   only then), and takes it back after its deadline, on Revert, or when it finds a trial at start: the file is emptied, then
//   the configuration read again.
//   Keep empties the file without a reload and publishes `kept`; Settings then writes displays.conf (a Keep the shell did not
//   take, after its deadline, writes nothing). The countdown is the shell's, so a Settings
//   that crashed or was closed cannot leave a display in a mode nobody confirmed.
// In a dev session the files are under GRASSFIELD_STATE_HOME and the request socket is the nested Hyprland's.
Singleton {
    id: root

    // The backlight ({device, level}) or null; shell.qml binds Brightness into it (ADR-0021: platform imports lib only).
    property var backlight: null

    readonly property string statePath: DisplaysFile.statePath(Mode.dev, Mode.stateHome, Quickshell.env("XDG_RUNTIME_DIR"))
    readonly property string trialPath: DisplaysFile.trialPath(Mode.dev, Mode.stateHome, Quickshell.env("XDG_RUNTIME_DIR"))

    // The trial being run ("" for none) and its last outcome, as published.
    property string running: ""
    property var trialState: null
    // The first look at the trial file since the shell started (a trial found then is taken back).
    property bool starting: true
    property int reloads: 0
    // The ticket of the reload that applies the trial being run (SessionConfig.answered; 0 for none).
    property int applying: 0
    // The monitors (IPC objects) last published with a name.
    property var described: []
    // The last text written: an identical payload is not written again.
    property string written: ""

    function publish(): void {
        const objects = Hyprland.monitors ? Hyprland.monitors.values : [];
        let monitors = objects.map(m => m.lastIpcObject).filter(o => o && o.name);
        // A refresh in flight leaves the objects without their answer: never publish none over the monitors already described.
        // None is published only when Hyprland has no monitor at all, or before any was ever described.
        if (monitors.length === 0 && objects.length > 0 && root.described.length > 0)
            monitors = root.described;
        // `described` is also what the main display's identity reads (services/MainDisplay.qml: make, model and serial), so it is
        // set whether or not there is a file to write.
        root.described = monitors;
        root.checkModeless(monitors);
        if (root.statePath === "")
            return;
        if (stateFile.path !== root.statePath)
            stateFile.path = root.statePath;
        const text = DisplaysFile.payload(monitors, root.backlight, root.trialState);
        // Quickshell reports every `monitors` answer as a change, changed or not (the lock asks every second): write only news.
        if (DisplaysFile.same(root.written, text))
            return;
        root.written = text;
        stateFile.setText(text);
    }

    onBacklightChanged: publishDebounce.restart()

    // ---- A display on without a mode (DisplaysFile.modeless; the owner's rc6 report: external displays black after sleep until
    // unplugged and plugged back). Hyprland gives up on a monitor that answered no video modes (asleep or switched off when it
    // was probed) and nothing fires when it powers on: the configuration is read again, after DisplaysFile.recoveryDelayMs, until
    // every display has a mode (Omarchy's own session does the same with omarchy-hyprland-monitor-watch, which Grassfield's
    // autostart does not run). While locked the lock refreshes the monitors every second, so a display that gets its mode is
    // seen at once. The reloads follow a back-off (DisplaysFile.recoveryDelayMs: 3 s doubled up to a minute, eight of them); after
    // it a reload, which flashes the configuration's blur, window edges, ground, zoom and pointer until the shell's pushes land,
    // is made only where no one sees it (every 10 minutes while the session is locked or the displays are off: `quiet`) and once
    // on each nudge (the session unlocked, the displays back on, a display added or removed): audit SC-05, a display switched off
    // at its button no longer costs a flash a minute all night. Quickshell's plain `monitors`
    // answer lists every enabled output that is not a mirror, whatever its mode (Hyprland 0.56.2 MonitorState); a mirror
    // without a mode is only in `monitors all` and is not recovered here (docs/specs/settings.md Known limitations).
    property var modelessNames: []
    property int recoveryAttempts: 0
    // Nobody can see a reload: the session is locked or the displays are off (shell.qml binds it from LockClient; ADR-0021:
    // platform imports lib only).
    property bool quiet: false
    onQuietChanged: {
        // Unlocked, or the displays back on: the moment someone looks at a display they may just have switched on.
        if (!root.quiet)
            root.nudge("in view again");
        else if (root.modelessNames.length > 0 && !recovery.running)
            root.scheduleRecovery();
    }

    // The next look on the back-off (or, after it, while quiet only).
    function scheduleRecovery(): void {
        const wait = DisplaysFile.recoveryDelayMs(root.recoveryAttempts, root.quiet);
        if (wait <= 0) {
            recovery.stop();
            return;
        }
        recovery.interval = wait;
        recovery.restart();
    }

    // One reload soon past the back-off (DisplaysFile.nudgeDelayMs), when a display is still without a mode.
    function nudge(why: string): void {
        if (root.modelessNames.length === 0)
            return;
        const wait = DisplaysFile.nudgeDelayMs(root.recoveryAttempts);
        if (wait < 0)
            return;
        recovery.interval = wait;
        recovery.restart();
    }

    function checkModeless(monitors: var): void {
        const blank = DisplaysFile.modeless(monitors);
        // The journal hears of a change of state only (on without a mode, a mode again), never of each look or reload: a display
        // switched off at its button can stay without a mode all night.
        if (blank.length === 0) {
            if (root.modelessNames.length > 0)
                console.info("grassfield-shell: displays: " + root.modelessNames.join(", ") + " has a mode again (after " + root.recoveryAttempts + " reloads)");
            root.modelessNames = [];
            root.recoveryAttempts = 0;
            recovery.stop();
            return;
        }
        if (root.modelessNames.join(",") !== blank.join(","))
            console.warn("grassfield-shell: displays: " + blank.join(", ") + " is on without a mode (0x0); the configuration is read again until it has one");
        root.modelessNames = blank;
        if (!recovery.running)
            root.scheduleRecovery();
    }

    Timer {
        id: recovery
        onTriggered: {
            const blank = DisplaysFile.modeless(root.described);
            if (blank.length === 0) {
                root.checkModeless(root.described);
                return;
            }
            // A display trial reads the configuration itself (and takes it back): look again after it.
            if (root.running === "") {
                root.recoveryAttempts++;
                SessionConfig.reloadQuietly("display without a mode", Tokens.materialBlurAnswerMs);
                if (root.recoveryAttempts === DisplaysFile.RECOVERY_ATTEMPTS)
                    console.info("grassfield-shell: displays: " + root.modelessNames.join(", ") + " still without a mode after " + root.recoveryAttempts + " reloads; read again only while locked or the displays are off, and when the session comes back in view");
            }
            root.scheduleRecovery();
        }
    }

    // Hyprland reads its configuration again (the trial applied or taken back): SessionConfig's one request.
    function reload(): int {
        root.reloads++;
        return SessionConfig.reload("display trial", Tokens.settingsDisplayTrialAnswerMs);
    }

    function empty(): void {
        trialFile.setText("");
    }

    function handle(text: string): void {
        const trial = DisplaysFile.parseTrial(text);
        const what = DisplaysFile.action(trial, root.running, root.starting, Math.floor(Date.now() / 1000));
        root.starting = false;
        if (what === "apply") {
            root.running = trial.id;
            root.trialState = {id: trial.id, state: "applying"};
            deadline.interval = DisplaysFile.countdownMs(trial.until, Date.now());
            deadline.restart();
            console.info("grassfield-shell: displays: trial " + trial.id + " applying");
            root.applying = root.reload();
        } else if (what === "keep") {
            deadline.stop();
            root.applying = 0;
            root.trialState = {id: root.running, state: "kept"};
            console.info("grassfield-shell: displays: trial " + root.running + " kept");
            root.running = "";
            root.empty();
        } else if (what === "revert") {
            root.revert(trial ? trial.id : root.running);
        }
        publishDebounce.restart();
    }

    function revert(id: string): void {
        deadline.stop();
        root.applying = 0;
        root.trialState = id !== "" ? {id: id, state: "reverted"} : null;
        console.info("grassfield-shell: displays: trial " + (id !== "" ? id : "(none)") + " taken back");
        root.running = "";
        root.empty();
        root.reload();
        publishDebounce.restart();
    }

    Timer {
        id: deadline
        onTriggered: root.revert(root.running)
    }

    // The monitors change in bursts (a reload, a hot-plug): one write per settle.
    Timer {
        id: publishDebounce
        interval: Tokens.motionFast
        onTriggered: root.publish()
    }

    // Hyprland's answer to `monitors` arrives after the shell started (and after every refresh): each monitor object gets its
    // lastIpcObject then, so a change of it, a monitor added or one removed publishes (debounced).
    Instantiator {
        model: Hyprland.monitors
        onObjectAdded: publishDebounce.restart()
        onObjectRemoved: publishDebounce.restart()

        // The signal only: the value is a whole map converted for every answer, and publish() reads it once per settle.
        delegate: Connections {
            required property HyprlandMonitor modelData

            target: modelData

            function onLastIpcObjectChanged(): void {
                publishDebounce.restart();
            }
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "monitoradded" || event.name === "monitoraddedv2" || event.name === "monitorremoved"
                || event.name === "monitorremovedv2" || event.name === "configreloaded") {
                Hyprland.refreshMonitors();
                publishDebounce.restart();
                if (event.name !== "configreloaded")
                    root.nudge("a display added or removed");
                // A display arriving or leaving, in the journal with its time: what a wake from sleep costs is read from these
                // lines next to the kernel's "PM: suspend exit" and the lock's (the owner's rc6 report: slow wake). The v2
                // event carries the id and the description too: only the connector name is logged (no serial in the journal).
                if (event.name === "monitoraddedv2" || event.name === "monitorremovedv2")
                    console.info("grassfield-shell: displays: " + (event.name === "monitoraddedv2" ? "added " : "removed ") + DisplaysFile.eventOutput(event.data));
            }
        }
    }

    Connections {
        target: SessionConfig

        function onAnswered(ticket: int, ok: bool): void {
            const next = DisplaysFile.answered(root.trialState, root.running, root.applying, ticket, ok);
            if (next === root.trialState)
                return;
            root.applying = 0;
            root.trialState = next;
            console.info("grassfield-shell: displays: trial " + root.running + " applied");
            publishDebounce.restart();
        }
    }

    FileView {
        id: stateFile
        printErrors: false
        atomicWrites: true
        // A failed write is tried again with the next publish, even when the text is the same.
        onSaveFailed: root.written = ""
    }

    FileView {
        id: trialFile
        path: root.trialPath
        printErrors: false
        watchChanges: true
        atomicWrites: true
        // Emptied before the reload is asked for: the write is done when setText returns, so the configuration read again
        // never finds the trial being taken back.
        blockWrites: true
        onFileChanged: reload()
        onLoaded: root.handle(trialFile.text())
        onLoadFailed: root.handle("")
    }

    // No refreshMonitors() here: Quickshell already asks Hyprland for `monitors` when its IPC starts, and a second request
    // while that one is in flight leaves the monitor model empty (Quickshell 0.3.1; found with tests/shell/displays_publish.sh).
    // The Instantiator above publishes when the answer arrives.
    Component.onCompleted: {
        publishDebounce.restart();
    }
}
