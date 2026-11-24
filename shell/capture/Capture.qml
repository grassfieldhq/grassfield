pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.lib
import qs.platform
import qs.platform.shortcuts
import qs.services
import "../platform/ScreenChoice.js" as ScreenChoice
import "CaptureModel.js" as Model

// The capture toolbar (Shift-Super-5; ADR-0045 OC-1, spec docs/specs/system-dialogs.md "Capture toolbar"): owns its state (open,
// the display, the mode), the Options as the settings keep them (capture.*), the IPC target `capture`, and the run of
// grassfield-capture once the toolbar is gone. CaptureToolbar draws it on its display; CaptureCountdown shows the helper's
// countdown (CaptureState). Mirrors Search: one exclusive-keyboard surface, closed by the other full-attention surfaces
// (ExclusiveSurfaces in shell.qml), never opened while the session is locked and closed when it locks.
Scope {
    id: root

    property bool open: false
    // Key focus returns to the window that was active when this opened (FocusReturn), as on macOS: a window capture then
    // shows it as the key window.
    onOpenChanged: {
        if (open)
            FocusReturn.opened("capture");
        else
            FocusReturn.closed("capture", true);
    }
    // True while the session lock (or its transition) owns the screen: the toolbar neither opens nor stays (shell.qml binds it).
    property bool locked: false
    // True while Overview, Apps, Search or the app switcher is open (shell.qml binds it): the floating thumbnail steps aside.
    property bool attention: false
    onLockedChanged: {
        if (locked)
            hide();
    }
    property string screenName: ""
    // The mode shown (capture.mode once chosen), and whether a recording can start now.
    property string mode: "selection"
    readonly property bool recorder: CaptureState.recorderAvailable
    readonly property bool canRecord: recorder && CaptureState.phase === "idle"
    // The Options as stored (capture.*): what the menu checks and what the helper is given.
    readonly property var options: ({
            location: Settings.captureLocation,
            timer: Settings.captureTimer,
            microphone: Settings.captureMicrophone,
            showPointer: Settings.captureShowPointer,
            showThumbnail: Settings.captureShowThumbnail,
            rememberSelection: Settings.captureRememberSelection,
            hideDesktopIcons: Settings.captureHideDesktopIcons,
            recordDnd: Settings.captureRecordDnd
        })
    // The Entire Screen modes take a click on any display, Capture Selected Window a click on a window of any display: every
    // display's surface takes input then (the bar and the keyboard stay on the toolbar's display). The Selected Portion modes
    // draw their frame on the toolbar's display.
    readonly property bool coversAll: open && (mode === "screen" || mode === "recordScreen" || mode === "window")
    // The helper's arguments waiting for the toolbar's surface to be gone (run by `launch`).
    property var pending: null

    // The display the toolbar is on went away (unplugged): the toolbar closes.
    Connections {
        target: Quickshell

        function onScreensChanged(): void {
            if (root.open && ScreenChoice.gone(root.screenName, Quickshell.screens.map(s => s.name)))
                root.hide();
        }
    }

    // A recording that started meanwhile (Ctrl-Super-Esc is the only other way in): the toolbar leaves a recording mode.
    onCanRecordChanged: {
        if (!canRecord && Model.isRecord(mode))
            mode = "selection";
    }

    // The display the next show() opens on: the menu bar's Screen Capture item names its bar's display (openOn); "" is the
    // active one. show() stays the one place that opens the toolbar, refusing first while locked (tests/security/lock_surfaces.sh).
    property string requestedScreen: ""

    function show(): void {
        // Nothing opens over the lock screen (GF-116): Shift-Super-5, the menu bar item and IPC alike.
        if (SessionState.refuses("capture"))
            return;
        if (Popups.active)
            Popups.close();
        launch.stop();
        pending = null;
        CaptureState.probeRecorder();
        screenName = ScreenChoice.pick(requestedScreen, Compositor.activeScreenName, Quickshell.screens.map(s => s.name));
        mode = Model.startMode(Settings.captureMode, canRecord);
        Compositor.refreshToplevels();
        open = true;
    }

    function hide(): void {
        open = false;
    }

    function toggle(): void {
        if (open)
            hide();
        else
            show();
    }

    // The menu bar's Screen Capture item: the toolbar on that bar's display. It only opens: once open, the toolbar covers the
    // display and takes every click there (an Entire Screen mode captures the display clicked), so the bar never gets a second
    // click; Esc or the toolbar's Close button dismisses it (macOS).
    function openOn(screen: string): void {
        if (open)
            return;
        requestedScreen = screen;
        show();
        requestedScreen = "";
    }

    // A click on a mode, or the arrows: the mode chosen is kept for the next time (capture.mode).
    function choose(id: string): void {
        if (!Model.available(id, canRecord))
            return;
        mode = id;
        Settings.setCaptureOption("mode", id);
    }

    function step(delta: int): void {
        choose(Model.step(mode, delta, canRecord));
    }

    // A row of the Options menu (CaptureModel.menuModel ids): the setting it changes, or Capture Previous Area.
    function setOption(id: string): void {
        const change = Model.choice(id, options);
        if (!change)
            return;
        if (change.action === "previous")
            capturePrevious();
        else
            Settings.setCaptureOption(change.key, change.value);
    }

    // Capture Previous Area (Options, Capture Selected Portion): the toolbar goes and the helper captures the last frame of the
    // display in focus (`selection --previous`), or shows its crosshair when none is stored.
    function capturePrevious(): void {
        if (!open || mode !== "selection" || !Settings.captureRememberSelection)
            return;
        pending = Model.previousArgs(options);
        hide();
        launch.restart();
    }

    // Capture or Record (the button, Return, a click on a display or a window): the toolbar goes first, then the helper runs,
    // so that neither the bar, its frame nor its keyboard is in the picture and the window it captures is key again. `output`:
    // the display to capture or record ("" for every display, the toolbar's for Record Entire Screen); `geometry`: the frame or
    // the window clicked, "X,Y WxH" in the compositor's coordinates ("" lets the helper's crosshair choose: the fallback).
    function trigger(output: string, geometry: string): void {
        if (!open || (Model.isRecord(mode) && !canRecord))
            return;
        pending = Model.helperArgs(mode, options, mode === "recordScreen" && output === "" ? screenName : output, geometry);
        hide();
        launch.restart();
    }

    // The frame a display opens with in the Selected Portion modes (its last one, else centred), and the one to keep for it.
    // Remember Last Selection off: the centred frame, and nothing is kept.
    function frameFor(name: string, bounds: var): var {
        return Model.selectionFor(Settings.captureRememberSelection ? Settings.captureLastSelection : "", name, bounds, Tokens.captureFrameMinSize);
    }

    function rememberFrame(name: string, frame: var): void {
        if (Settings.captureRememberSelection)
            Settings.setCaptureOption("lastSelection", Model.withSelection(Settings.captureLastSelection, name, frame));
    }

    // Hide Desktop Icons: the toolbar is open, or its helper was started a moment ago and has not written its state yet.
    readonly property bool armed: open || launch.running || settle.running
    Binding {
        target: CaptureState
        property: "armed"
        value: root.armed
    }

    // Do Not Disturb while recording (Options > Do Not Disturb): held when a recording starts, the state before it restored when it
    // ends or the option is turned off; a change of Do Not Disturb by the user during the recording releases the hold and the user's
    // choice stands (CaptureModel.dndStep). Notifications.dnd is stored, so the hold is kept in capture-dnd-hold.json (0600, in the
    // state folder, as the other state files): a shell that starts and finds one restores it once the helper's state is read and no
    // recording runs (a log out, a power cut or a crash in a recording would leave Do Not Disturb on for ever).
    property var dndHold: ({held: false, previous: false})
    property bool holdRead: false
    property bool holdDirty: false
    readonly property string holdPath: Mode.stateDir !== "" ? Mode.stateDir + "/capture-dnd-hold.json" : ""

    function syncDnd(): void {
        if (!holdRead || !CaptureState.stateLoaded)
            return;
        const step = Model.dndStep(root.dndHold, CaptureState.recording, Settings.captureRecordDnd, Settings.notificationsDnd);
        const changed = Model.serializeHold(step.held) !== Model.serializeHold(root.dndHold);
        root.dndHold = step.held;
        if (changed)
            saveHold();
        if (step.set !== null)
            Settings.setNotificationsDnd(step.set);
    }

    function takeHold(text: string): void {
        if (holdRead)
            return;
        holdRead = true;
        const read = Model.parseHold(text);
        if (read.held)
            root.dndHold = read;
        syncDnd();
    }

    // The file holds the hold while it is held and is gone otherwise; a second change while one is written is written after it.
    function saveHold(): void {
        if (root.holdPath === "")
            return;
        if (holdWriter.running) {
            root.holdDirty = true;
            return;
        }
        const text = Model.serializeHold(root.dndHold);
        holdWriter.command = text !== "" ? ["sh", Quickshell.shellPath("services/write-private.sh"), Mode.stateDir, root.holdPath, text] : ["rm", "-f", "--", root.holdPath];
        holdWriter.running = true;
    }

    FileView {
        path: root.holdPath
        printErrors: false
        onLoaded: root.takeHold(text())
        onLoadFailed: root.takeHold("")
    }

    Process {
        id: holdWriter
        onRunningChanged: {
            if (!running && root.holdDirty) {
                root.holdDirty = false;
                root.saveHold();
            }
        }
    }

    Connections {
        target: CaptureState

        function onStateLoadedChanged(): void {
            root.syncDnd();
        }
    }

    Connections {
        target: Settings

        function onNotificationsDndChanged(): void {
            root.syncDnd();
        }
    }

    Connections {
        target: CaptureState

        function onRecordingChanged(): void {
            root.syncDnd();
        }
    }

    Connections {
        target: Settings

        function onCaptureRecordDndChanged(): void {
            root.syncDnd();
        }
    }

    // The window list of Capture Selected Window comes from Hyprland's window data, read again when the mode shows (a window
    // moved since the shell last read it).
    onModeChanged: {
        if (open && mode === "window")
            Compositor.refreshToplevels();
    }

    // The surface stays mapped focusReturn.releaseHoldMs after it gives the keyboard back (KeyboardRelease); a moment more lets
    // the window's focus come back (FocusReturn) before the helper's picture or crosshair.
    Timer {
        id: launch
        interval: Tokens.focusReturnReleaseHoldMs + 300
        onTriggered: {
            const args = root.pending;
            root.pending = null;
            if (args && !SessionState.locked) {
                settle.restart();
                CaptureState.run(args);
            }
        }
    }

    // The helper's state is not written yet when it has just started: the desktop icons stay hidden for this long (a phase that is
    // not idle keeps them hidden after it).
    Timer {
        id: settle
        interval: Tokens.captureIconsSettleMs
    }

    IpcHandler {
        target: "capture"
        // A key binding calls it: it answers the key in-process (platform/shortcuts, CIO-01).
        Component.onCompleted: Shortcuts.attach(this)

        // Shift-Super-5 (bindings.lua): opens the toolbar, or closes it.
        function toggle(): void {
            root.toggle();
        }

        function open(): void {
            if (VisualFixtures.dev)
                root.show();
        }

        function close(): void {
            if (VisualFixtures.dev)
                root.hide();
        }

        // JSON of the toolbar's state and of the helper's as the shell reads it (nested checks).
        function status(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return JSON.stringify({
                open: root.open,
                screen: root.screenName,
                mode: root.mode,
                recorder: root.recorder,
                options: root.options,
                phase: CaptureState.phase,
                secondsLeft: CaptureState.secondsLeft,
                elapsed: CaptureState.recording ? CaptureState.elapsedText : ""
            });
        }
    }

    CaptureToolbar {
        controller: root
    }

    CaptureCountdown {}

    // The floating thumbnail (A2, A3): it steps aside for the toolbar and for the other full-attention surfaces (`attention`).
    CaptureThumbnails {
        held: root.open || root.attention
    }
}
