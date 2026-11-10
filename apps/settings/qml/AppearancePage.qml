pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TerminalThemes.js" as TerminalThemes

// Settings > Appearance as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Appearance): Light / Dark / Auto
// thumbnails and the glass (Transparency: a preview over the Grassfield artwork and a slider from clear to tinted); Theme:
// the accent colours and the text highlight colour; the icon style (and its tint colour when Tinted) and the folder colour.
// Then Grassfield's own glass effects (material.profile), and Terminal and Developer Apps (ADR-0045 OC-11: Omarchy's theme
// follows the appearance; the shell applies it, services/TerminalTheme.qml). Reduce Transparency and Reduce Motion are in
// Accessibility > Display, as on macOS.
SettingsPage {
    id: root

    required property var store
    // The machine door (SystemService) and its Backend, for the read-only `omarchy-theme-list`; without them (a test of the
    // page alone) the Terminal and Developer Apps group stays hidden.
    property var system: null
    property var backend: null
    // Omarchy's theme names (TerminalThemes.parse); empty while unread, and when Omarchy's command is missing (the group is
    // hidden then, ADR-0045 OC-0.3).
    property var terminalThemes: []

    title: qsTr("Appearance")

    Component.onCompleted: {
        if (root.system !== null)
            root.system.query(["omarchy-theme-list"], "appearance.themes");
    }

    Connections {
        target: root.backend
        enabled: root.backend !== null

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "appearance.themes")
                root.terminalThemes = ok ? TerminalThemes.parse(output, n => SettingsContract.validate("terminal.lightTheme", n) === "") : [];
        }
    }

    readonly property var colorNames: ({
            // The default (stored as "multicolor"): the brand green, named after the product (ADR-0040 step 1c, IQ-B3 A).
            multicolor: qsTr("Grassfield"),
            blue: qsTr("Blue"),
            purple: qsTr("Purple"),
            pink: qsTr("Pink"),
            red: qsTr("Red"),
            orange: qsTr("Orange"),
            yellow: qsTr("Yellow"),
            green: qsTr("Green"),
            graphite: qsTr("Graphite")
        })
    // The palette of the icon tint and folder colours (Tokens.iconModeTintColors), in the same order as these names.
    readonly property var paletteNames: [qsTr("Blue"), qsTr("Purple"), qsTr("Pink"), qsTr("Red"), qsTr("Orange"), qsTr("Yellow"), qsTr("Green"), qsTr("Graphite")]
    readonly property string iconMode: root.store.value("icons.mode")

    // An accent's colour in the current appearance (Grassfield: the brand green).
    function accentOf(name: string): color {
        const r = Accent.resolve(name, Appearance.dark, Tokens);
        return r ? r.accent : (Appearance.dark ? Tokens.colorDark.accent : Tokens.colorLight.accent);
    }

    // The colour of an accent's swatch disc: the vivid color.swatch value (no text sits on a disc; ADR-0024 amendment 2026-11-03);
    // Grassfield is the brand green.
    function swatchOf(name: string): color {
        return Tokens.colorSwatch[name] || root.accentOf(name);
    }

    // The palette entry a stored "#rrggbb" is (its token spelling), or the setting itself.
    function paletteId(setting: string): string {
        const hit = Tokens.iconModeTintColors.find(c => c.toLowerCase() === String(setting).toLowerCase());
        return hit ?? setting;
    }

    function paletteModel(): var {
        return Tokens.iconModeTintColors.map((c, i) => ({id: c, text: root.paletteNames[i], color: c}));
    }

    // A row whose title sits at the top, above taller content placed by the caller from `contentY` (macOS 27: the thumbnails,
    // the glass, the colours, the icon styles). After the first row, the row starts with its separator line.
    component TallRow: Item {
        id: tall

        property string title: ""
        property real rowHeight: 0
        readonly property real contentY: tall.Positioner.index > 0 ? 1 : 0

        width: parent ? parent.width : 0
        height: tall.contentY + tall.rowHeight
        Accessible.role: Accessible.Grouping
        Accessible.name: tall.title

        Rectangle {
            visible: tall.Positioner.index > 0
            x: Tokens.settingsRowInset
            width: parent.width - 2 * Tokens.settingsRowInset
            height: Tokens.appsBorderWidth
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }

        // Where the title ends (its right edge), for content that must not reach it.
        readonly property real titleRight: titleText.x + titleText.width

        Text {
            id: titleText
            textFormat: Text.PlainText
            x: Tokens.settingsRowInset
            y: tall.contentY + Tokens.settingsHeaderRowTitleBaseline - baselineOffset
            text: tall.title
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }
    }

    SettingsGroup {
        TallRow {
            title: qsTr("Appearance")
            rowHeight: Tokens.settingsAppearanceRowHeight

            ChoicePicker {
                anchors.right: parent.right
                anchors.rightMargin: Tokens.settingsAppearanceThumbInset - ringPad
                y: parent.contentY + Tokens.settingsAppearanceThumbTop - ringPad
                accessibleName: qsTr("Appearance")
                model: [{id: "light", text: qsTr("Light")}, {id: "dark", text: qsTr("Dark")}, {id: "auto", text: qsTr("Auto")}]
                value: root.store.value("appearance")
                pictureWidth: Tokens.settingsAppearanceThumbWidth
                pictureHeight: Tokens.settingsAppearanceThumbHeight
                pictureRadius: Tokens.settingsAppearanceThumbRadius
                pitch: Tokens.settingsAppearanceThumbPitch
                ringGap: Tokens.settingsAppearanceThumbRingGap
                captionBaseline: Tokens.settingsAppearanceCaptionBaseline
                picture: Component {
                    AppearanceThumbnail {}
                }
                onPicked: id => root.store.set("appearance", id)
            }
        }

        TallRow {
            title: qsTr("Transparency")
            rowHeight: Tokens.settingsGlassRowHeight

            GlassPreview {
                anchors.right: parent.right
                anchors.rightMargin: Tokens.settingsRowInset
                y: parent.contentY + Tokens.settingsGlassPreviewTop
                transparency: root.store.value("material.transparency")
                onMoved: t => root.store.set("material.transparency", t)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Theme")

        TallRow {
            title: qsTr("Colour")
            rowHeight: Tokens.settingsAccentRowHeight

            AccentPicker {
                anchors.right: parent.right
                anchors.rightMargin: Tokens.settingsRowInset - ringPad
                y: parent.contentY + Tokens.settingsAccentSwatchTop - ringPad
                accessibleName: qsTr("Accent colour")
                model: Accent.NAMES.map(n => ({color: root.swatchOf(n), name: root.colorNames[n]}))
                currentIndex: Accent.NAMES.indexOf(Accent.normalize(root.store.value("accent.color")))
                onChosen: index => root.store.set("accent.color", Accent.NAMES[index])
            }
        }

        SettingsRow {
            title: qsTr("Text highlight colour")

            ColorPopup {
                accessibleName: qsTr("Text highlight colour")
                model: [{id: "automatic", text: qsTr("Automatic"), color: Appearance.colors.accent}].concat(Accent.NAMES.slice(1).map(n => ({id: n, text: root.colorNames[n], color: root.swatchOf(n)})))
                value: Accent.normalizeHighlight(root.store.value("accent.highlight"))
                onPicked: id => root.store.set("accent.highlight", id)
            }
        }
    }

    SettingsGroup {
        TallRow {
            id: iconRow
            title: qsTr("Icon style")
            // macOS: a choice row never overlaps its title. When the choices do not fit beside it they go on their own line
            // under it (and the names wrap under their pictures when even that is tight).
            readonly property real rightMargin: Tokens.settingsIconStyleInset - Tokens.settingsIconStyleSize / 2 - iconPicker.ringPad
            readonly property bool stacked: iconRow.width - iconRow.rightMargin - iconPicker.naturalWidth < iconRow.titleRight + Tokens.spacingMd
            rowHeight: iconRow.stacked ? Tokens.settingsIconStyleStackedTop - iconPicker.ringPad + iconPicker.implicitHeight + Tokens.spacingSm : Tokens.settingsIconStyleRowHeight

            ChoicePicker {
                id: iconPicker
                // Stacked: the first name's left edge (it may reach past its picture) at the row's inset.
                x: iconRow.stacked ? Tokens.settingsRowInset - ringPad + Math.max(0, (captionWidth - pictureWidth) / 2) : iconRow.width - iconRow.rightMargin - implicitWidth
                maxWidth: iconRow.stacked ? iconRow.width - 2 * Tokens.settingsRowInset : 0
                y: parent.contentY + (iconRow.stacked ? Tokens.settingsIconStyleStackedTop : Tokens.settingsIconStyleTop) - ringPad
                accessibleName: qsTr("Icon style")
                model: [{id: "default", text: qsTr("Default")}, {id: "dark", text: qsTr("Dark")}, {id: "clear", text: qsTr("Clear")}, {id: "tinted", text: qsTr("Tinted")}]
                value: root.iconMode
                pictureWidth: Tokens.settingsIconStyleSize
                pictureHeight: Tokens.settingsIconStyleSize
                pictureRadius: Tokens.settingsIconStyleSize * Tokens.iconModePreviewRadius / Tokens.iconModePreviewSize
                pitch: Tokens.settingsIconStylePitch
                ringGap: Tokens.settingsAccentRingGap
                captionBaseline: Tokens.settingsIconStyleCaptionBaseline
                // A real icon through the real pipeline (the same TintedIcon as every app and file icon), in each mode.
                picture: Component {
                    TintedIcon {
                        property string choice: "default"
                        size: Tokens.settingsIconStyleSize
                        source: Appearance.iconSampleSource
                        mode: choice
                        tint: Appearance.iconTint
                        solidMaterial: true
                    }
                }
                onPicked: id => root.store.set("icons.mode", id)
            }
        }

        SettingsRow {
            visible: root.iconMode === "tinted"
            title: qsTr("Tint colour")

            ColorPopup {
                accessibleName: qsTr("Tint colour")
                model: [{id: "accent", text: qsTr("Automatic"), color: Appearance.colors.accent}].concat(root.paletteModel())
                value: root.paletteId(root.store.value("icons.tint"))
                onPicked: id => root.store.set("icons.tint", id)
            }
        }

        SettingsRow {
            title: qsTr("Folder colour")
            // Its separator line, then the row (macOS 27: 2 taller than a plain row).
            height: 1 + Tokens.settingsFolderRowHeight

            ColorPopup {
                accessibleName: qsTr("Folder colour")
                model: [{id: "accent", text: qsTr("Automatic"), color: Appearance.colors.accent}, {id: "theme", text: qsTr("Icon theme"), color: Tokens.iconModeSampleTop}].concat(root.paletteModel())
                value: root.paletteId(root.store.value("icons.folderColor"))
                onPicked: id => root.store.set("icons.folderColor", id)
            }
        }
    }

    SettingsGroup {
        SettingsRow {
            title: qsTr("Glass effects")
            subtitle: qsTr("Full uses live previews, Balanced refreshes them less often, Reduced uses still images.")

            ComboBox {
                inline: true
                accessibleName: qsTr("Glass effects")
                model: [{id: "full", text: qsTr("Full")}, {id: "balanced", text: qsTr("Balanced")}, {id: "reduced", text: qsTr("Reduced")}]
                value: root.store.value("material.profile")
                onPicked: id => root.store.set("material.profile", id)
            }
        }
    }

    // ADR-0045 OC-11: the rows, switch and pop-ups of every other Settings group (OC-0.7: nothing of Omarchy's own UI). The theme
    // pop-ups follow the switch (dimmed while it is off, as macOS dims the rows a switch governs). Omarchy's theme is the
    // Omarchy session's too: the footnote says so.
    SettingsGroup {
        visible: root.terminalThemes.length > 0
        caption: qsTr("Terminal and Developer Apps")
        footnote: qsTr("The Omarchy session uses the same theme and its wallpaper.")

        SettingsRow {
            title: qsTr("Match Appearance")

            Toggle {
                accessibleName: qsTr("Match Appearance")
                checked: root.store.value("terminal.matchAppearance") === true
                onToggled: c => root.store.set("terminal.matchAppearance", c)
            }
        }

        SettingsRow {
            title: qsTr("Light Theme")

            ComboBox {
                inline: true
                enabled: root.store.value("terminal.matchAppearance") === true
                accessibleName: qsTr("Light Theme")
                model: TerminalThemes.choices(root.terminalThemes, root.store.value("terminal.lightTheme"))
                value: root.store.value("terminal.lightTheme")
                onPicked: id => root.store.set("terminal.lightTheme", id)
            }
        }

        SettingsRow {
            title: qsTr("Dark Theme")

            ComboBox {
                inline: true
                enabled: root.store.value("terminal.matchAppearance") === true
                accessibleName: qsTr("Dark Theme")
                model: TerminalThemes.choices(root.terminalThemes, root.store.value("terminal.darkTheme"))
                value: root.store.value("terminal.darkTheme")
                onPicked: id => root.store.set("terminal.darkTheme", id)
            }
        }
    }
}
