pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.platform
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
            showPointer: Settings.captureShowPointer
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

    // The display the next show() opens on: the menu bar's Screen Capture item names its bar's display (toggleOn); "" is the
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

    // The menu bar's Screen Capture item: the toolbar on that bar's display; again, it closes.
    function toggleOn(screen: string): void {
        if (open) {
            hide();
            return;
        }
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

    // A row of the Options menu (CaptureModel.menuModel ids): the setting it changes.
    function setOption(id: string): void {
        const change = Model.choice(id, options);
        if (change)
            Settings.setCaptureOption(change.key, change.value);
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
    function frameFor(name: string, bounds: var): var {
        return Model.selectionFor(Settings.captureLastSelection, name, bounds, Tokens.captureFrameMinSize);
    }

    function rememberFrame(name: string, frame: var): void {
        Settings.setCaptureOption("lastSelection", Model.withSelection(Settings.captureLastSelection, name, frame));
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
            if (args && !SessionState.locked)
                CaptureState.run(args);
        }
    }

    IpcHandler {
        target: "capture"

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
}
