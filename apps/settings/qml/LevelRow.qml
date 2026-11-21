import QtQuick
import Grassfield.Ui

// A level row laid out as macOS 27's slider rows (docs/audits/settings-parity-2026-10-26.md § Sound, § Displays): the title,
// then a small glyph, the slider and a large glyph. Sound's volumes and Displays' brightness. Writes are coalesced (one command
// per throttle interval while dragging) and go through SystemService, so a dev session suppresses them and the slider snaps back.
SettingsRow {
    id: root

    required property var system
    // The level, 0 to 1, as read.
    property real value: 0
    // The command that sets a level (an argument vector, or null when it cannot be set), what it is called in the log, and the
    // tag its answer comes back with.
    property var command: null
    // Instead of a command: a function that applies a level itself (Sound's Alert volume, a setting) and returns whether it
    // was applied.
    property var apply: null
    property string what: ""
    property string tag: ""
    property bool settable: true
    property string accessibleName: root.title
    // The glyphs at the low and high ends, their sizes (the low one centred where an 18-pt one sits), and the slider's span.
    property string lowGlyph: "speaker"
    property string highGlyph: "volume-3"
    property real lowGlyphSize: Tokens.settingsSliderRowGlyphSize
    property real highGlyphSize: Tokens.settingsSliderRowGlyphSize
    property real sliderX: Tokens.settingsSliderRowSliderX
    property real sliderWidth: Tokens.settingsSliderRowSliderWidth
    // One command at a time (an external display over DDC/CI, whose writes take 50 to 200 ms: ADR-0045 OC-4): the next value
    // waits for the answer of the one running, and only the last value moved to is sent then.
    property bool oneAtATime: false

    // A drag is being applied: the page keeps its older reading out of the slider meanwhile.
    readonly property bool busy: !isNaN(root.pending) || throttle.running || root.running
    property real pending: NaN
    // A command of this row runs (oneAtATime).
    property bool running: false
    // Below the separator.
    readonly property real contentTop: root.Positioner.index > 0 ? 1 : 0
    readonly property real center: root.contentTop + Tokens.settingsSliderRowCenter

    implicitHeight: root.contentTop + Tokens.settingsSliderRowHeight - 1
    labelsOffset: Tokens.settingsSliderRowTitleOffset
    // The slider sits outside the row's slot: the labels and the two glyphs dim with it, once (the slider draws its own
    // disabled look; UI audit 2026-11-05 U18).
    dimmed: Appearance.dimsDisabled(root) || Appearance.dimsDisabled(slider)

    function flush(): void {
        // The running command's answer sends what waits.
        if (root.running)
            return;
        const v = root.pending;
        // The throttle first, so the row stays busy from one write to the next (the page never sees a drag end in between); a
        // command of its own before the write, so an answer that came at once is not missed.
        throttle.start();
        root.pending = NaN;
        // A row that applies its level itself (apply) has no command to wait for.
        if (root.apply !== null) {
            if (root.apply(v) !== true)
                slider.local = NaN;
            return;
        }
        root.running = root.oneAtATime;
        if (!root.command || !root.system.act(root.what, root.command(v), root.tag)) {
            root.running = false;
            slider.local = NaN;
        }
    }

    Connections {
        target: root.system ? root.system.backend : null
        // Only while it waits for an answer: a Backend answer is not handed to every row and sheet of the window (the audit's notes).
        enabled: root.running

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag !== root.tag || !root.running)
                return;
            root.running = false;
            if (!isNaN(root.pending))
                root.flush();
        }
    }

    Icon {
        parent: root
        name: root.lowGlyph
        size: root.lowGlyphSize
        color: Appearance.windowSecondary
        x: Tokens.settingsSliderRowLowGlyphX + (Tokens.settingsSliderRowGlyphSize - width) / 2
        y: root.center - height / 2
        opacity: root.dimmed ? Tokens.materialDisabledOpacity : 1
    }

    Slider {
        id: slider
        parent: root
        x: root.sliderX
        y: root.center - height / 2
        width: root.sliderWidth
        accessibleName: root.accessibleName
        enabled: root.settable && (root.command !== null || root.apply !== null)
        from: 0
        to: 1
        stepSize: 0.05
        value: root.value
        onMoved: v => {
            root.pending = v;
            if (!throttle.running)
                root.flush();
        }
    }

    Icon {
        parent: root
        name: root.highGlyph
        size: root.highGlyphSize
        color: Appearance.windowSecondary
        x: root.width - Tokens.settingsSliderRowHighGlyphInset - width + (root.highGlyphSize - Tokens.settingsSliderRowGlyphSize) / 2
        y: root.center - height / 2
        opacity: root.dimmed ? Tokens.materialDisabledOpacity : 1
    }

    Timer {
        id: throttle
        interval: Tokens.settingsVolumeApplyMs
        onTriggered: {
            if (!isNaN(root.pending))
                root.flush();
        }
    }
}
