pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TagColors.js" as TagColors

// Customize Folder (macOS 26): a colour (Default follows Settings > Appearance > Folder colour, the Accent, the seven
// tag colours, or any #rrggbb) and an optional symbol or emoji drawn on the folder, with a live preview. Done applies
// to every folder in `urls` (FilesApp.applyFolderStyle), Reset goes back to the global colour and no symbol.
Window {
    id: root

    required property var app
    // The folders being customised (local folder URLs) and the name shown in the title.
    required property var urls
    property string folderName: ""
    property string iconName: "folder"

    // The edited look: "" = follows the global colour.
    property string pickedColor: ""
    property string glyph: ""
    property string note: ""
    property string errorText: ""

    readonly property var swatchModel: {
        const out = [
            {color: Tokens.iconModeSampleTop, name: qsTr("Default"), state: root.pickedColor === "" ? 2 : 0},
            {color: Appearance.colors.accent, name: qsTr("Accent"), state: root.pickedColor === "accent" ? 2 : 0}
        ];
        const tags = TagColors.swatches(Tokens, root.app.colorTagNames, []);
        for (const t of tags)
            out.push({color: t.color, name: t.name, state: root.pickedColor.toLowerCase() === String(t.color).toLowerCase() ? 2 : 0});
        return out;
    }
    // Suggestions for the symbol: emoji and plain symbols (one grapheme cluster each).
    readonly property var glyphChoices: ["⭐", "❤️", "🎵", "📷", "🎬", "📄", "💼", "🏠", "🎮", "📚", "🔒", "☁️", "🛠️", "⚙️", "🎨", "✈️", "🧩", "💡", "📦", "🔥", "🌿", "🚀", "✅", "★", "♥\uFE0E", "♪", "✓", "⚑", "☂", "✎"]

    title: qsTr("Customize Folder")
    width: Tokens.filesCustomizeWindowWidth
    height: Tokens.filesCustomizeWindowHeight
    minimumWidth: width
    maximumWidth: width
    minimumHeight: height
    maximumHeight: height
    color: Appearance.windowFill
    visible: true

    onClosing: Qt.callLater(root.destroy)

    // Cmd+W closes the key window (macOS): like Cancel (Escape, below). Only while this window is the key window: Qt
    // also matches it while the browser, its transient parent, has the keyboard.
    Shortcut {
        sequences: [StandardKey.Close]
        enabled: root.app.focusWindow === root
        onActivated: root.close()
    }

    Component.onCompleted: {
        const first = root.urls.length > 0 ? root.app.folderStyleOf(root.urls[0]) : {color: "", glyph: ""};
        root.pickedColor = first.color;
        root.glyph = first.glyph;
        panel.forceActiveFocus();
    }

    function chooseSwatch(index: int): void {
        root.pickedColor = index === 0 ? "" : (index === 1 ? "accent" : String(TagColors.at(Tokens, index - 2)).toLowerCase());
        hexField.text = root.pickedColor.indexOf("#") === 0 ? root.pickedColor : "";
    }

    function finish(reset: bool): void {
        const r = reset ? root.app.resetFolderStyle(root.urls) : root.app.applyFolderStyle(root.urls, root.pickedColor, root.glyph);
        if (!r.ok) {
            root.errorText = r.error;
            return;
        }
        if (r.fellBack) {
            // Kept for this user only: the volume or the folder can't hold it. Say so before closing.
            root.note = qsTr("Saved for your account only: this folder can’t store it.");
            closeTimer.start();
            return;
        }
        root.close();
    }

    Timer {
        id: closeTimer
        interval: Tokens.filesCustomizeNoteMs
        onTriggered: root.close()
    }

    // ADR-0015: the window draws its own chrome (the titlebar style of grassfield-ui); the apps' tagger
    // (apps/windowchrome.h) names its role for the compositor, whose plugin then draws no titlebar on it.
    property string gfChromeRole: "info"

    UnifiedToolbar {
        id: chrome
        width: parent.width
        window: root
        style: "titlebar"
        title: root.title
        doubleClickAction: root.app.titlebarDoubleClick
        canMinimize: root.app.canMinimize
    }

    FocusScope {
        id: panel
        anchors.fill: parent
        anchors.topMargin: chrome.height
        Accessible.role: Accessible.Dialog
        Accessible.name: root.title

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.close();
                event.accepted = true;
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !closeTimer.running) {
                root.finish(false);
                event.accepted = true;
            }
        }

        Column {
            id: content
            x: Tokens.spacingLg
            y: Tokens.spacingLg
            width: parent.width - 2 * Tokens.spacingLg
            spacing: Tokens.spacingMd

            // Preview.
            Item {
                width: parent.width
                height: Tokens.folderIconPickerPreviewSize

                FolderIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    size: Tokens.folderIconPickerPreviewSize
                    source: root.iconName !== "" ? "image://icon/" + root.iconName : ""
                    oversample: Tokens.filesThumbnailOversample
                    folderColor: root.pickedColor
                    folderGlyph: root.glyph
                    solidMaterial: true
                }
            }

            Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
                text: root.folderName
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyTitleSize
                font.weight: Tokens.typographyMenuBoldWeight
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            // Colour.
            Item {
                width: parent.width
                height: swatches.implicitHeight

                Text {
                    textFormat: Text.PlainText
                    width: Tokens.filesInfoLabelWidth
                    y: Tokens.spacingXs
                    horizontalAlignment: Text.AlignRight
                    text: qsTr("Colour:")
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                }

                SwatchRow {
                    id: swatches
                    objectName: "swatches"
                    x: Tokens.filesInfoLabelWidth + Tokens.spacingSm - Tokens.menuItemPadding
                    width: parent.width - x
                    accessibleName: qsTr("Folder colour")
                    caption: root.swatchModel.filter(m => m.state === 2).map(m => m.name).join("")
                    model: root.swatchModel
                    activeFocusOnTab: true
                    onChosen: index => {
                        currentIndex = index;
                        root.chooseSwatch(index);
                    }
                }
            }

            // Custom colour.
            Item {
                width: parent.width
                height: Tokens.toolbarSearchHeight

                Text {
                    textFormat: Text.PlainText
                    width: Tokens.filesInfoLabelWidth
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: qsTr("Custom:")
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                }

                Rectangle {
                    x: Tokens.filesInfoLabelWidth + Tokens.spacingSm
                    width: Tokens.filesCustomizeHexWidth
                    height: parent.height
                    radius: Tokens.radiusControl
                    // The light well of the appearance (ADR-0039 step 23: it was the dark appearance's fill in both), and the
                    // shared focus ring outside it (G7).
                    color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)

                    FocusRing {
                        visible: hexField.activeFocus
                    }

                    TextInput {
                        id: hexField
                        objectName: "hexField"
                        TextCursor {}
                        activeFocusOnTab: true
                        anchors.fill: parent
                        anchors.leftMargin: Tokens.spacingSm
                        anchors.rightMargin: Tokens.spacingSm
                        verticalAlignment: TextInput.AlignVCenter
                        clip: true
                        maximumLength: 7
                        inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhPreferLowercase
                        color: Appearance.colors.text
                        selectionColor: Appearance.highlight
                        selectedTextColor: Appearance.highlightText
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                        Accessible.role: Accessible.EditableText
                        Accessible.name: qsTr("Custom colour (#rrggbb)")
                        text: root.pickedColor.indexOf("#") === 0 ? root.pickedColor : ""
                        // A complete #rrggbb is the colour; anything else leaves the choice as it is.
                        onTextEdited: {
                            const t = text.trim();
                            if (/^#[0-9a-fA-F]{6}$/.test(t))
                                root.pickedColor = t.toLowerCase();
                        }

                        Text {
                            textFormat: Text.PlainText
                            anchors.verticalCenter: parent.verticalCenter
                            visible: hexField.text === ""
                            text: qsTr("#rrggbb")
                            color: Appearance.windowSecondary
                            font: hexField.font
                        }
                    }
                }
            }

            // Symbol.
            Item {
                width: parent.width
                height: glyphGrid.height

                Text {
                    textFormat: Text.PlainText
                    width: Tokens.filesInfoLabelWidth
                    y: Tokens.spacingXs
                    horizontalAlignment: Text.AlignRight
                    text: qsTr("Symbol:")
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                }

                FocusScope {
                    id: glyphGrid
                    objectName: "glyphGrid"
                    x: Tokens.filesInfoLabelWidth + Tokens.spacingSm
                    width: parent.width - x
                    height: grid.height
                    activeFocusOnTab: true
                    property int current: -1
                    // Tab lands on the chosen symbol (else the first) with the focus ring, like the swatches.
                    onActiveFocusChanged: {
                        if (activeFocus && current < 0)
                            current = Math.max(0, root.glyphChoices.indexOf(root.glyph));
                    }
                    readonly property int columns: Tokens.folderIconPickerGlyphColumns
                    Accessible.role: Accessible.Grouping
                    Accessible.name: qsTr("Symbol")
                    Accessible.focusable: true

                    Keys.onPressed: event => {
                        const n = root.glyphChoices.length;
                        let c = glyphGrid.current < 0 ? 0 : glyphGrid.current;
                        if (event.key === Qt.Key_Left)
                            c = Math.max(0, c - 1);
                        else if (event.key === Qt.Key_Right)
                            c = Math.min(n - 1, c + 1);
                        else if (event.key === Qt.Key_Up)
                            c = Math.max(0, c - glyphGrid.columns);
                        else if (event.key === Qt.Key_Down)
                            c = Math.min(n - 1, c + glyphGrid.columns);
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            if (glyphGrid.current >= 0) {
                                root.glyph = root.glyphChoices[glyphGrid.current];
                                glyphField.text = "";
                            }
                            event.accepted = true;
                            return;
                        } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                            root.glyph = "";
                            event.accepted = true;
                            return;
                        } else {
                            return;
                        }
                        glyphGrid.current = c;
                        event.accepted = true;
                    }

                    Grid {
                        id: grid
                        columns: glyphGrid.columns
                        spacing: Tokens.spacingXs

                        Repeater {
                            model: root.glyphChoices

                            delegate: Rectangle {
                                id: cell
                                required property string modelData
                                required property int index
                                readonly property bool chosen: root.glyph === cell.modelData
                                width: Tokens.folderIconPickerCell
                                height: Tokens.folderIconPickerCell
                                radius: Tokens.radiusControl
                                color: cell.chosen ? Appearance.withAlpha(Appearance.colors.accent, Tokens.desktopIconSelectionOpacity) : (cellHover.hovered ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent")
                                border.width: glyphGrid.activeFocus && glyphGrid.current === cell.index ? Tokens.controlFocusOutline : 0
                                border.color: Appearance.focusRingColor
                                Accessible.role: Accessible.RadioButton
                                Accessible.name: cell.modelData
                                Accessible.checked: cell.chosen

                                Text {
                                    textFormat: Text.PlainText
                                    anchors.centerIn: parent
                                    text: cell.modelData
                                    color: Appearance.colors.text
                                    font.pixelSize: Math.round(Tokens.folderIconPickerCell * Tokens.folderIconGlyphScale * 2)
                                }

                                HoverHandler {
                                    id: cellHover
                                }

                                TapHandler {
                                    onTapped: {
                                        // A second click on the chosen symbol takes it off, as a toggle.
                                        root.glyph = cell.chosen ? "" : cell.modelData;
                                        glyphGrid.current = cell.index;
                                        glyphField.text = "";
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Any other emoji or symbol: typed or pasted, the first character counts.
            Item {
                width: parent.width
                height: Tokens.toolbarSearchHeight

                Rectangle {
                    x: Tokens.filesInfoLabelWidth + Tokens.spacingSm
                    width: parent.width - x
                    height: parent.height
                    radius: Tokens.radiusControl
                    // The light well of the appearance (ADR-0039 step 23: it was the dark appearance's fill in both), and the
                    // shared focus ring outside it (G7).
                    color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)

                    FocusRing {
                        visible: glyphField.activeFocus
                    }

                    TextInput {
                        id: glyphField
                        objectName: "glyphField"
                        TextCursor {}
                        activeFocusOnTab: true
                        anchors.fill: parent
                        anchors.leftMargin: Tokens.spacingSm
                        anchors.rightMargin: Tokens.spacingSm
                        verticalAlignment: TextInput.AlignVCenter
                        clip: true
                        maximumLength: 32
                        color: Appearance.colors.text
                        selectionColor: Appearance.highlight
                        selectedTextColor: Appearance.highlightText
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                        Accessible.role: Accessible.EditableText
                        Accessible.name: qsTr("Other symbol or emoji")
                        // The field holds one symbol (one grapheme cluster, the rule Files saves with): what is typed
                        // or pasted is cut to it at once, so the preview is what Done saves.
                        onTextEdited: {
                            const kept = FolderStyle.normalizeGlyph(text);
                            if (text !== kept)
                                text = kept;
                            root.glyph = kept;
                        }

                        Text {
                            textFormat: Text.PlainText
                            anchors.verticalCenter: parent.verticalCenter
                            visible: glyphField.text === ""
                            text: qsTr("Type or paste a symbol")
                            color: Appearance.windowSecondary
                            font: glyphField.font
                        }
                    }
                }
            }

            Text {
                textFormat: Text.PlainText
                visible: root.note !== "" || root.errorText !== ""
                width: parent.width
                text: root.errorText !== "" ? root.errorText : root.note
                wrapMode: Text.Wrap
                color: root.errorText !== "" ? Appearance.colors.danger : Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: root.errorText !== "" ? Accessible.AlertMessage : Accessible.StaticText
                Accessible.name: text
            }

            Row {
                anchors.right: parent.right
                spacing: Tokens.spacingSm

                Button {
                    text: qsTr("Reset")
                    destructive: true
                    onClicked: root.finish(true)
                }

                Button {
                    text: qsTr("Cancel")
                    onClicked: root.close()
                }

                Button {
                    text: qsTr("Done")
                    primary: true
                    onClicked: root.finish(false)
                }
            }
        }
    }
}
