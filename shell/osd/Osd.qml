pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.platform
import qs.services
import "../services/BrightnessLogic.js" as BrightnessLogic

// On-screen display state (volume, brightness, keyboard backlight and input source). Spec: docs/specs/osd.md.
//
// Shown when the default sink volume/mute or the backlight change (by any program), and by the
// IPC targets osd (tests), volume and brightness (real changes).
Singleton {
    id: root

    property string kind: "volume"
    property real level: 0
    property bool muted: false
    property bool shown: false
    // kind "inputsource": the name of the keyboard layout now active (macOS input source HUD): the pill shows it instead of a bar.
    property string label: ""
    // The output whose brightness the pill shows ("" for the active display): a brightness change shows on the display that
    // changed (ADR-0045 OC-4), everything else on the active display.
    property string output: ""
    // Where the pill shows: `output` while it is connected, else the active display (Compositor.activeScreenName).
    readonly property string screenName: root.output !== "" && Quickshell.screens.some(s => s.name === root.output) ? root.output : Compositor.activeScreenName

    readonly property string iconName: kind === "keyboard" || kind === "inputsource" ? "keyboard" : kind === "brightness" ? "sun" : (muted || level <= 0 ? "volume-mute" : level < 0.34 ? "volume-1" : level < 0.67 ? "volume-2" : "volume-3")

    // Changes before this are start-up noise (initial volume read), not user actions.
    property bool armed: false
    property bool kbdSeen: false
    // The machine's real backlights (the sysfs files) drive the OSD only in a real session. A development or nested session, and
    // the visual fixtures, run on the owner's machine: its backlight changing there is not what the session under test did, and
    // must not draw a pill in a capture or a test. The IPC hooks and the brightness keys still show the OSD (brightnessStep).
    readonly property bool hardwareDrives: !Brightness.devSession && !VisualFixtures.active

    // When the last event was shown (ms since the epoch, 0 before the first): the OSD window is built right after the shell
    // started (shell.qml, ADR-0056 amendment); an event that came while it was loading is shown once it exists.
    // Monotonic (ElapsedTimer), not the wall clock, which can step at login: -1 before the first event.
    property real lastEventMs: -1
    readonly property ElapsedTimer clock: ElapsedTimer {}

    function replay(): void {
        if (lastEventMs >= 0 && clock.elapsedMs() - lastEventMs <= Tokens.deferredRequestMaxAgeMs) {
            shown = true;
            hideTimer.restart();
        }
    }

    function showValue(osdKind: string, osdLevel: real, osdMuted: bool): void {
        // NaN or infinite levels (bad IPC input, sensor glitch) are ignored; the rest is clamped.
        if (!isFinite(osdLevel))
            return;
        showOn("", osdKind, osdLevel, osdMuted);
    }

    // The same on display `name` ("" for the active display), set before the pill shows so it never shows elsewhere first.
    function showOn(name: string, osdKind: string, osdLevel: real, osdMuted: bool): void {
        if (!isFinite(osdLevel))
            return;
        output = name;
        kind = osdKind === "brightness" || osdKind === "keyboard" ? osdKind : "volume";
        level = Math.max(0, Math.min(1, osdLevel));
        muted = osdMuted;
        shown = true;
        lastEventMs = clock.elapsedMs();
        hideTimer.restart();
    }

    // A display's brightness, on that display (`name`; "" for the active display).
    function showBrightnessOf(name: string, osdLevel: real): void {
        showOn(name, "brightness", osdLevel, false);
    }

    // The layout changed (InputSource: only a real change of a keyboard that had another layout, so nothing with a single layout).
    function showInputSource(name: string): void {
        if (name === "")
            return;
        kind = "inputsource";
        label = name;
        level = 0;
        muted = false;
        output = "";
        shown = true;
        lastEventMs = clock.elapsedMs();
        hideTimer.restart();
    }

    function showVolume(): void {
        if (Audio.ready)
            showValue("volume", Audio.volume, Audio.muted);
    }

    // The backlight's level, on the built-in display (the active display when none is connected: an all-in-one's panel).
    function showBrightness(): void {
        if (Brightness.available)
            showBrightnessOf(BrightnessLogic.builtIn(Quickshell.screens.map(s => s.name)), Brightness.level);
    }

    function showKeyboard(): void {
        if (Brightness.kbdAvailable)
            showValue("keyboard", Brightness.kbdLevel, false);
    }

    function hide(): void {
        shown = false;
    }

    // Keyboard backlight keys (macOS: the keyboard brightness HUD). A step is 1/16 of the range, like the
    // 16 notches of the macOS keys, but at least one device step.
    function keyboardStep(direction: string): void {
        if (!Brightness.kbdAvailable) {
            console.info("osd: no keyboard backlight device; keyboard", direction, "ignored");
            return;
        }
        if (direction !== "up" && direction !== "down") {
            console.warn("osd: unknown keyboard command", direction);
            return;
        }
        const step = Math.max(1 / 16, 1 / Brightness.kbdMax);
        const target = Math.max(0, Math.min(1, Brightness.kbdLevel + (direction === "up" ? step : -step)));
        if (!Brightness.setKbdLevel(target))
            showKeyboard();
    }

    // Real volume change through wpctl (Audio.keyStep; refused in a dev session, nothing runs), then show.
    function volumeStep(direction: string): void {
        Audio.keyStep(direction);
        // Volume feedback (sound.volumeFeedback), once the keys rest (ADR-0047 B-5).
        Sounds.volumeKey(direction);
    }

    // The brightness keys act on the active display (ADR-0045 OC-4, BrightnessLogic.keyTarget): an external display that
    // answers DDC/CI steps by 5 points through Omarchy's command, the built-in panel (or a display that cannot be changed, which
    // leaves the keys to the built-in panel as macOS does) through the backlight; the OSD shows that display's level on it.
    function brightnessStep(direction: string): void {
        if (direction !== "up" && direction !== "down") {
            console.warn("osd: unknown brightness command", direction);
            return;
        }
        const target = BrightnessLogic.keyTarget(Compositor.activeScreenName, Quickshell.screens.map(s => s.name), Brightness.available, Brightness.ddc);
        if (target.kind === "ddc") {
            const level = Brightness.stepOutput(target.output, direction);
            if (level >= 0)
                showBrightnessOf(target.output, level);
            return;
        }
        if (target.kind !== "backlight") {
            console.info("osd: no backlight device and", Compositor.activeScreenName || "no display", "has no DDC/CI; brightness", direction, "ignored");
            return;
        }
        // In a dev session adjust() only logs; the OSD still shows the current level.
        if (!Brightness.adjust(direction === "up" ? 0.05 : -0.05))
            showBrightness();
    }

    Timer {
        id: hideTimer
        interval: Tokens.osdHideDelay
        onTriggered: root.shown = false
    }

    Timer {
        id: arm
        interval: 1500
        onTriggered: root.armed = true
    }

    // wpctl returned; PipeWire reports the new state a moment later.
    Timer {
        id: settle
        interval: 120
        onTriggered: root.showVolume()
    }

    Connections {
        target: Audio

        function onKeyFinished(): void {
            settle.restart();
        }

        function onVolumeChanged(): void {
            if (root.armed)
                root.showVolume();
        }

        function onMutedChanged(): void {
            if (root.armed)
                root.showVolume();
        }

        // A new default output starts with its own volume: not a user change.
        function onSinkChanged(): void {
            root.armed = false;
            arm.restart();
        }
    }

    Connections {
        target: Brightness

        function onValueChanged(): void {
            if (Brightness.loaded && root.armed && root.hardwareDrives)
                root.showBrightness();
        }

        // An external display's command answered: a pill showing that display follows its level (the key showed the level
        // expected; the display may have stopped at 1 % or stepped by 1 % near the bottom, as Omarchy's command does).
        function onOutputLevelChanged(name: string): void {
            if (root.shown && root.kind === "brightness" && root.output === name && Brightness.outputAnswers(name))
                root.level = Brightness.outputLevel(name);
        }
    }

    Connections {
        target: Brightness

        // The first value is the initial read, not a user action.
        function onKbdValueChanged(): void {
            if (!root.kbdSeen)
                root.kbdSeen = true;
            else if (root.armed && root.hardwareDrives && Brightness.kbdAvailable)
                root.showKeyboard();
        }
    }

    Connections {
        target: InputSource

        function onLayoutChanged(name: string): void {
            if (root.armed)
                root.showInputSource(name);
        }
    }

    Component.onCompleted: arm.start()

    IpcHandler {
        target: "osd"

        // Test hooks (dev session only, VisualFixtures.dev, SEC-04: no OSD spoofing by another process).
        // qs ipc call osd display <volume|brightness|keyboard> <0..1> <muted>
        function display(kind: string, level: real, muted: bool): void {
            if (VisualFixtures.dev)
                root.showValue(kind, level, muted);
        }

        // Test hook: a compositor layout event, "keyboard,Layout name" (the first one for a keyboard shows nothing, a different
        // layout after it shows the input source HUD).
        function layout(data: string): void {
            if (VisualFixtures.dev)
                InputSource.feed(data);
        }

        // Test hook: "shown|kind|label" (dev session only).
        function state(): string {
            return VisualFixtures.dev ? [root.shown, root.kind, root.label].join("|") : "";
        }

        function hide(): void {
            if (VisualFixtures.dev)
                root.hide();
        }
    }

    IpcHandler {
        target: "volume"

        function up(): void {
            root.volumeStep("up");
        }

        function down(): void {
            root.volumeStep("down");
        }

        function mute(): void {
            root.volumeStep("mute");
        }
    }

    IpcHandler {
        target: "brightness"

        function up(): void {
            root.brightnessStep("up");
        }

        function down(): void {
            root.brightnessStep("down");
        }
    }

    IpcHandler {
        target: "keyboard"

        function up(): void {
            root.keyboardStep("up");
        }

        function down(): void {
            root.keyboardStep("down");
        }
    }
}
