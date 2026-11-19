pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Templates as T

// Horizontal slider with a pill track and a pill knob, on a QtQuick.Templates Control: the host owns the value. value is
// within [from, to]; moved(value) reports a user change.
T.Control {
    id: root

    property real from: 0
    property real to: 1
    property real value: 0
    property real stepSize: 0.05
    property string accessibleName: ""
    // The fill: the selection colour, as a switch that is on, a checked box and a default button (ADR-0039 step 11, D-Q4).
    // The accent only while the window looks key, inside an app window (Appearance.accentShown, UI audit 2026-11-05 U17).
    readonly property bool keyLook: Appearance.accentShown(root.Window.window, root.Window.active)
    // Not key: a neutral grey (Appearance.inactiveFill).
    property color fillColor: root.keyLook ? Appearance.colors.selection : Appearance.inactiveFill
    // The white knob is outlined in the fill's mark colour where it holds under 3:1 on the fill (Accent.knobOutlined).
    readonly property bool knobOutlined: !root.knobless && root.position > 0 && root.keyLook && Accent.knobOutlined(String(Appearance.colors.knob), String(root.fillColor), Tokens.controlKnobMinContrast)
    // Up/Down change the value too. Quick Settings turns this off: there the vertical arrows move focus between
    // modules (macOS model), and a focused slider changes with Left/Right, Home/End only.
    property bool verticalKeys: true
    // Track thickness; Quick Settings passes controlSliderTrackCompact.
    property real trackHeight: Tokens.controlSliderTrack
    // macOS Control Center module slider: no knob, a white fill with a round cap on a darker translucent track (the fill
    // keeps a minimum of one cap so the slider never vanishes); the keyboard ring goes round the track.
    property bool knobless: false
    // A stepped slider (macOS 27 Keyboard's key repeat): this many stops, drawn as dots under the track; a change snaps to the
    // nearest and the keys move from one to the next. 0: continuous.
    property int stops: 0
    // Dots under the track at this many even places without stepping (macOS 27 Appearance's glass slider: one at each end).
    property int ticks: 0
    // Dots under the track at these values instead (macOS 27 Dock Magnification: Small near the start, Large at the end).
    property var tickValues: []

    // Emitted when the user changes the value (not when it is set from outside).
    signal moved(real value)
    // The pointer let go of the slider after a drag or a click (or the press was taken away): a host that throttles its
    // writes (Settings' ConfigStore) writes the last position now.
    signal released

    // `value` stays a pure input (external bindings survive). A user change is held in `local`
    // until the host sets a new value, so an unbound slider still follows the user.
    property real local: NaN
    readonly property real shown: isNaN(local) ? value : local
    // While the pointer holds the slider, a value from the host is a late echo of an earlier position (a sound server's or
    // a backlight's round trip): the fill keeps the user's value, and takes the host's at the release.
    property bool echoed: false
    onValueChanged: {
        if (dragArea.pressed)
            echoed = true;
        else
            local = NaN;
    }

    readonly property real position: to > from ? Math.max(0, Math.min(1, (shown - from) / (to - from))) : 0
    // Where the dots are, 0 to 1 along the knob's travel: the stops, the even ticks or the tick values.
    readonly property var dots: {
        const n = root.stops > 1 ? root.stops : root.ticks;
        if (n > 1)
            return Array.from({length: n}, (_, i) => i / (n - 1));
        return to > from ? root.tickValues.map(v => Math.max(0, Math.min(1, (v - from) / (to - from)))) : [];
    }
    readonly property real knobWidth: knobless ? 0 : Tokens.controlSliderKnobWidth
    // Disabled on its own (UI audit 2026-11-05 U18): the track and the white knob stay (a faded knob would show the fill through
    // it), the fill and the stops dim; inside a disabled container drawn dimmed, the container dims it once already
    // (Appearance.dimsDisabled).
    readonly property bool dimmed: Appearance.dimsDisabled(root)
    readonly property real travel: Math.max(0, width - knobWidth)
    // Device pixels: the stop dots and the knob's hairline land on whole pixels at every scale.
    readonly property real pixelRatio: Math.max(1, Screen.devicePixelRatio)

    implicitWidth: Tokens.controlSliderDefaultWidth
    implicitHeight: Tokens.controlSliderHeight
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.Slider
    Accessible.name: root.accessibleName
    Accessible.focusable: true
    Accessible.onIncreaseAction: if (root.visible && root.enabled)
        root.nudge(1)
    Accessible.onDecreaseAction: if (root.visible && root.enabled)
        root.nudge(-1)

    function clampValue(v: real): real {
        return Math.max(from, Math.min(to, v));
    }

    function commit(v: real): void {
        // A hidden or disabled slider reports nothing, whoever asks.
        if (!root.visible || !root.enabled)
            return;
        const k = root.stops > 1 && to > from ? Math.round((clampValue(v) - from) / (to - from) * (root.stops - 1)) : -1;
        const next = k >= 0 ? from + k * (to - from) / (root.stops - 1) : clampValue(v);
        if (next === shown)
            return;
        local = next;
        moved(next);
    }

    // Drops the held user value: the slider shows `value` again (a host that refused the change calls this).
    function reset(): void {
        local = NaN;
    }

    function nudge(direction: int): void {
        commit(shown + direction * (root.stops > 1 ? 1 / (root.stops - 1) : stepSize) * (to - from));
    }

    Keys.onPressed: event => {
        if (!root.visible || !root.enabled) {
            event.accepted = event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Up || event.key === Qt.Key_Down || event.key === Qt.Key_Home || event.key === Qt.Key_End;
            return;
        }
        if (event.key === Qt.Key_Left || (verticalKeys && event.key === Qt.Key_Down)) {
            nudge(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right || (verticalKeys && event.key === Qt.Key_Up)) {
            nudge(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Home) {
            commit(from);
            event.accepted = true;
        } else if (event.key === Qt.Key_End) {
            commit(to);
            event.accepted = true;
        }
    }

    FocusGuard {}

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: root.trackHeight
        radius: height / 2
        color: root.knobless ? (Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Tokens.quicksettingsSliderTrackOpacityDark) : Appearance.withAlpha(Appearance.colors.shadow, Tokens.quicksettingsSliderTrackOpacity)) : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

        Rectangle {
            // At the start the knob covers the fill; its round end would show a sliver of it (macOS 27 Magnification Off: none).
            visible: root.knobless || root.position > 0
            width: root.knobless ? Math.max(parent.height, root.position * root.travel) : root.knobWidth / 2 + root.position * root.travel
            height: parent.height
            radius: height / 2
            color: root.knobless ? Appearance.colors.knob : root.fillColor
            opacity: root.dimmed ? Tokens.materialDisabledOpacity : 1
        }

        // Increase Contrast outlines the track, as the other controls: drawn after the fill, which would cover an outline of the
        // track itself (a knobless slider at its end shows no track at all).
        Rectangle {
            visible: Appearance.increaseContrast
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.width: Tokens.controlBorderWidth
            border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
        }

        FocusRing {
            shapeRadius: parent.radius
            visible: root.knobless && root.visualFocus
        }
    }

    Repeater {
        model: root.dots

        delegate: Rectangle {
            id: dot
            required property real modelData
            // On whole device pixels: a 2-pt dot at y 16.5 drew blurred (UI audit 2026-11-05, LOW).
            x: Math.round((root.knobWidth / 2 + dot.modelData * root.travel - dot.width / 2) * root.pixelRatio) / root.pixelRatio
            y: Math.round((root.height / 2 + Tokens.controlSliderStopOffset - dot.height / 2) * root.pixelRatio) / root.pixelRatio
            width: Tokens.controlSliderStopSize
            height: dot.width
            radius: dot.width / 2
            color: Appearance.withAlpha(Appearance.colors.text, Tokens.controlSliderStopOpacity)
            opacity: root.dimmed ? Tokens.materialDisabledOpacity : 1
        }
    }

    Rectangle {
        id: knob
        visible: !root.knobless
        width: Tokens.controlSliderKnobWidth
        height: Tokens.controlSliderKnob
        radius: height / 2
        x: root.position * root.travel
        anchors.verticalCenter: parent.verticalCenter
        // Pressed, the knob darkens a step while it is held (macOS): the shadow colour (black in both appearances) over it.
        color: dragArea.pressed && root.enabled ? Qt.tint(Appearance.colors.knob, Appearance.withAlpha(Appearance.colors.shadow, Tokens.materialHoverOpacity)) : Appearance.colors.knob
        // The switch knob's look (UI audit 2026-11-05, LOW: a ring here, a soft shadow there): a soft drop shadow and a
        // device-pixel edge in the shadow colour; the full outline where white holds under 3:1 on the fill, or with Increase
        // Contrast.
        border.width: root.knobOutlined || Appearance.increaseContrast ? Tokens.controlBorderWidth : 1 / root.pixelRatio
        border.color: root.knobOutlined ? Appearance.colors.selectionText : Appearance.withAlpha(Appearance.colors.shadow, Tokens.materialBorderOpacity)

        RectangularShadow {
            anchors.fill: parent
            z: -1
            radius: parent.radius
            blur: Tokens.controlKnobShadowBlur
            offset: Qt.vector2d(0, Tokens.controlKnobShadowOffsetY)
            color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.controlKnobShadowOpacity)
        }

        FocusRing {
            shapeRadius: parent.radius
            visible: root.visualFocus
        }
    }

    MouseArea {
        id: dragArea
        anchors.fill: parent
        cursorShape: Qt.ArrowCursor
        function at(mouseX: real): void {
            root.forceActiveFocus();
            const t = root.travel > 0 ? (mouseX - root.knobWidth / 2) / root.travel : 0;
            root.commit(root.from + Math.max(0, Math.min(1, t)) * (root.to - root.from));
        }
        onPressed: mouse => at(mouse.x)
        onPositionChanged: mouse => {
            if (pressed)
                at(mouse.x);
        }
        // Released or taken away: the host's value shows again when it changed during the hold.
        onPressedChanged: {
            if (!pressed)
                root.released();
            if (!pressed && root.echoed) {
                root.echoed = false;
                root.local = NaN;
            }
        }
    }
}
