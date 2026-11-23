import QtQuick
import Grassfield.Ui

// Feeds the shared appearance from the backend (grassfield.json, read only). App windows are opaque
// (master-prompt 5.5): menus drawn with the shared material must not show what is behind them.
Item {
    id: root

    required property var backend

    visible: false

    Binding {
        target: Appearance
        property: "dark"
        value: root.backend.dark
    }

    Binding {
        target: Appearance
        property: "transparency"
        value: 0
    }

    Binding {
        target: Appearance
        property: "reduceMotion"
        value: root.backend.reduceMotion
    }

    // Accessibility > Display, as every app (ADR-0039 Q7): controls outlined, secondary text in the text colour, and the text
    // tokens marked textScale at the chosen size.
    Binding {
        target: Appearance
        property: "increaseContrast"
        value: root.backend.increaseContrast
    }

    Binding {
        target: Appearance
        property: "textScale"
        value: root.backend.textScale
    }

    // The window's own surface and its secondary text grey (ADR-0024: app windows draw the window neutrals, not the shell's
    // material tint; Appearance.windowFill, Appearance.windowSecondary).
    Binding {
        target: Appearance
        property: "windowSurface"
        value: true
    }

    Binding {
        target: Appearance
        property: "accentSetting"
        value: root.backend.accentColor
    }

    Binding {
        target: Appearance
        property: "highlightSetting"
        value: root.backend.accentHighlight
    }

    // Menu shortcuts in the device's style (keyboard.shortcutStyle, owner decision 2026-10-26).
    Binding {
        target: Appearance
        property: "shortcutStyle"
        value: root.backend.shortcutStyle
    }
}
