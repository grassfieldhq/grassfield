import QtQuick
import Grassfield.Ui

// Accessibility > Display (macOS: Display, Text, then Pointer): Increase contrast and Reduce transparency, Text size, and
// the pointer's size and colours with Reset Colour. All live in the shell. Reduce transparency is the same key as in
// Appearance (one setting, two places, as the Quick Settings Appearance section shows it too). The colours are stored
// (pointer.outlineColor, pointer.fillColor); the shell regenerates the cursor theme for them and reports how that went in
// pointer-theme.json (docs/specs/settings.md, Pointer).
SettingsPage {
    id: root

    required property var store
    readonly property string outlineColor: root.store.value("pointer.outlineColor").toLowerCase()
    readonly property string fillColor: root.store.value("pointer.fillColor").toLowerCase()
    readonly property bool customColors: !PointerColors.isDefault(root.outlineColor, root.fillColor)
    readonly property var presets: [
        {color: Tokens.settingsColorSquareWhite, name: qsTr("White")},
        {color: Tokens.settingsColorSquareBlack, name: qsTr("Black")},
        {color: Tokens.iconModeTintColors[0], name: qsTr("Blue")},
        {color: Tokens.iconModeTintColors[1], name: qsTr("Purple")},
        {color: Tokens.iconModeTintColors[2], name: qsTr("Pink")},
        {color: Tokens.iconModeTintColors[3], name: qsTr("Red")},
        {color: Tokens.iconModeTintColors[4], name: qsTr("Orange")},
        {color: Tokens.iconModeTintColors[5], name: qsTr("Yellow")},
        {color: Tokens.iconModeTintColors[6], name: qsTr("Green")}
    ]

    PointerThemeStatus {
        id: themeStatus
        backend: root.store.backend
        configPath: root.store.path
        outline: root.outlineColor
        fill: root.fillColor
    }

    title: qsTr("Display")

    // Why the colours could not be applied, in the user's language; the tool's own message (English, technical) follows
    // on a line of its own.
    function failureText(): string {
        const code = themeStatus.code;
        let sentence = qsTr("The pointer colours could not be applied. The pointer is unchanged.");
        if (code === "builder")
            sentence = qsTr("The pointer colours could not be applied: the cursor builder is not installed. The pointer is unchanged.");
        else if (code === "folder")
            sentence = qsTr("The pointer colours could not be applied: there is no folder for the custom pointer theme. The pointer is unchanged.");
        else if (/^tool:[A-Za-z0-9_-]+$/.test(code))
            sentence = qsTr("The pointer colours could not be applied: %1 is not installed. The pointer is unchanged.").arg(code.substring(5));
        return themeStatus.reason !== "" ? sentence + "\n" + qsTr("Details: %1").arg(themeStatus.reason) : sentence;
    }

    SettingsGroup {
        caption: qsTr("Display")
        footnote: qsTr("Increase contrast draws borders and separators stronger and secondary text in the primary colour.")

        SettingsRow {
            title: qsTr("Increase contrast")
            subtitle: qsTr("Stronger borders and separators, full-strength text.")
            Toggle {
                accessibleName: qsTr("Increase contrast")
                checked: root.store.value("accessibility.increaseContrast")
                onToggled: c => root.store.set("accessibility.increaseContrast", c)
            }
        }

        SettingsRow {
            title: qsTr("Reduce transparency")
            subtitle: qsTr("Opaque surfaces instead of translucent ones.")
            Toggle {
                accessibleName: qsTr("Reduce transparency")
                checked: root.store.value("accessibility.reduceTransparency")
                onToggled: c => root.store.set("accessibility.reduceTransparency", c)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Text")
        footnote: qsTr("Text size scales the text of the shell's panels and of Settings; the menu bar and menus keep their size.")

        SettingsRow {
            title: qsTr("Text size")
            SegmentedControl {
                accessibleName: qsTr("Text size")
                model: [{id: "1", text: qsTr("100%")}, {id: "1.1", text: qsTr("110%")}, {id: "1.2", text: qsTr("120%")}, {id: "1.3", text: qsTr("130%")}]
                value: String(root.store.value("accessibility.textSize"))
                onPicked: id => root.store.set("accessibility.textSize", Number(id))
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Pointer")
        footnote: themeStatus.result === "failed" ? root.failureText()
            : themeStatus.result === "building" && root.customColors ? qsTr("Applying the new pointer colours…")
            : qsTr("The pointer changes as you drag, and apps that use the system pointer follow it. Without the Grassfield compositor extension the pointer changes the next time it changes shape. Apps that draw their own pointer keep the previous size and colours until you quit and reopen them.")

        SettingsRow {
            title: qsTr("Pointer size")
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Normal")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }
            Slider {
                id: size
                width: Tokens.controlSliderDefaultWidth
                accessibleName: qsTr("Pointer size")
                from: PointerSize.MIN
                to: PointerSize.MAX
                stepSize: PointerSize.STEP / (PointerSize.MAX - PointerSize.MIN)
                value: root.store.value("pointer.size")
                // The knob shows the snapped size at once; the store is written a few times a second while it is dragged.
                onMoved: v => {
                    const snapped = PointerSize.snap(v);
                    root.store.setSoon("pointer.size", snapped);
                    size.local = snapped;
                }
                onReleased: root.store.flush()
            }
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Large")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }
        }

        SettingsRow {
            title: qsTr("Pointer outline colour")
            ColorWell {
                anchors.verticalCenter: parent.verticalCenter
                accessibleName: qsTr("Pointer outline colour")
                color: root.outlineColor
                presets: root.presets
                onEdited: c => root.store.set("pointer.outlineColor", c)
            }
        }

        SettingsRow {
            title: qsTr("Pointer fill colour")
            ColorWell {
                anchors.verticalCenter: parent.verticalCenter
                accessibleName: qsTr("Pointer fill colour")
                color: root.fillColor
                presets: root.presets
                onEdited: c => root.store.set("pointer.fillColor", c)
            }
        }

        SettingsRow {
            title: ""
            // One preview of the pointer in the chosen colours (the pointer is one thing, as in macOS).
            PointerPreview {
                anchors.verticalCenter: parent.verticalCenter
                outlineColor: root.outlineColor
                fillColor: root.fillColor
            }
            Button {
                text: qsTr("Reset Colour")
                enabled: root.customColors
                onClicked: {
                    root.store.set("pointer.outlineColor", PointerColors.DEFAULT_OUTLINE);
                    root.store.set("pointer.fillColor", PointerColors.DEFAULT_FILL);
                }
            }
        }
    }
}
