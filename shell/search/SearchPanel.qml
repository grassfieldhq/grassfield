pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.launchpad // layering-exception: GF-087
import qs.platform
import qs.services
import "Actions.js" as ActionsJs
import "ClipboardView.js" as ClipView

// Search window, one per screen, mapped only on the controller's screen while open. Full-screen
// transparent layer-shell overlay (a click outside closes), keyboard exclusive while open. macOS 27: the query sits in a
// glass capsule; the chips and results come in a panel of the same width under it, shown once there is something to show.
// The Clipboard view (ADR-0034) uses the same capsule and panel: the clipboard symbol and "Clipboard" in the field, the More
// button at its right end, the history's rows (a thumbnail with the source app's badge, the title, the kind and time, the pin
// and copy buttons), the first-use prompt, the row menu and the More menu inside this window, and a preview panel beside it.
Variants {
    id: root

    required property var controller

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property bool shown: root.controller.open && root.controller.screenName === (modelData ? modelData.name : "")
        readonly property real maxResults: height * Tokens.searchMaxHeightFraction - Tokens.searchCapsuleHeight - Tokens.searchCapsuleGap
        readonly property bool clipView: root.controller.clipboardView

        // The open menu: "" none, "row" (a clipboard row's menu), "more" (the More button's); the row it is for; where it opens.
        property string menuKind: ""
        property var menuItem: null
        property point menuAt: Qt.point(0, 0)
        // The Actions panel of the selected row (Tab, P3b): where it hangs (the row's right side) and whether it is placed.
        property point actionsAt: Qt.point(0, 0)
        property bool actionsPlaced: false
        readonly property var menuModel: menuKind === "row" ? rowMenuModel(menuItem) : menuKind === "more" ? moreMenuModel() : []
        // What a row shows in the moment its result is gone and the row not yet removed (Search.setResults).
        readonly property var noResult: ({kind: "", key: "", title: "", subtitle: ""})

        screen: modelData
        // Mapped a moment longer than it holds the keyboard (the fade-out): a layer destroyed while Exclusive leaves the
        // compositor with no keyboard focus.
        visible: release.mapped
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-search"
        // qmllint disable missing-type
        // Everything except the menu bar strip receives input while shown; nothing once it closed: the surface stays mapped
        // a moment for the keyboard release (and the fade), and a click in that moment belongs to the window under it.
        mask: win.shown ? openMask : passThrough
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.shown ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: panel
            radius: Tokens.radiusSearch

            Region {
                item: capsule
                radius: Tokens.searchCapsuleHeight / 2
            }

            Region {
                item: preview.visible ? preview : null
                radius: Tokens.radiusSearch
            }

            // Only while a menu is open: a Loader keeps its last size once it unloads.
            Region {
                item: win.menuKind !== "" ? menuLoader : null
                radius: Tokens.radiusMenu
            }

            // The Actions list's glass (the filter field above it has none).
            Region {
                item: win.actionsPlaced ? actionsLoader.glass : null
                radius: Tokens.radiusMenu
            }
        }

        Region {
            id: openMask
            width: win.width
            height: win.height

            Region {
                width: win.width
                height: Tokens.menubarHeight
                intersection: Intersection.Subtract
            }
        }

        Region {
            id: passThrough
        }

        KeyboardRelease {
            id: release
            shown: win.shown
        }

        // Unmapped after its fade-out: the view it showed resets now, never during the fade (U9).
        Connections {
            target: release

            function onMappedChanged(): void {
                if (!release.mapped)
                    root.controller.released();
            }
        }

        // Closed but still mapped (the hold): a press the compositor delivered before the empty mask landed (late whenever
        // the GUI thread was busy) is swallowed here, never handled by the result under it.
        MouseArea {
            anchors.fill: parent
            z: 1000
            visible: !win.shown
            acceptedButtons: Qt.AllButtons
        }

        onShownChanged: {
            closeMenu();
            if (!shown)
                win.actionsPlaced = false;
            if (shown) {
                field.text = root.controller.query;
                field.forceActiveFocus();
                firstFrame.done = false;
            }
        }

        // The Actions panel opens beside the selected row and closes with the keyboard back in the field.
        Connections {
            target: root.controller

            function onActionsOpenChanged(): void {
                if (root.controller.actionsOpen && win.shown) {
                    win.placeActions();
                } else if (win.actionsPlaced) {
                    win.actionsPlaced = false;
                    if (win.shown)
                        field.forceActiveFocus();
                }
            }
        }

        // The view changed the query (entering or leaving the Clipboard view): the field shows it again.
        Connections {
            target: root.controller

            function onQueryReset(): void {
                if (!win.shown)
                    return;
                field.text = root.controller.query;
                field.forceActiveFocus();
            }
        }

        // Logs open -> first rendered frame once per opening.
        Connections {
            id: firstFrame

            property bool done: true

            target: win.shown ? panel.Window.window : null

            function onFrameSwapped(): void {
                if (done)
                    return;
                done = true;
                console.info("grassfield-shell: search open->visible", Date.now() - root.controller.openStartMs, "ms");
            }
        }

        // ---- the Clipboard view's keys and menus ----

        // An action of ClipboardView.keyAction (the keyboard table of docs/specs/clipboard.md). Returns whether it was handled.
        function clipKey(action: string): bool {
            const c = root.controller;
            if (c.zone === "more") {
                // The focus ring is on the More button: Return, Space and Down open its menu; Tab and Esc go back to the field.
                if (action === "paste" || action === "preview" || action === "down") {
                    openMoreMenu();
                    return true;
                }
                c.zone = "field";
                if (action === "more" || action === "escape")
                    return true;
            }
            if (c.clipPrompt) {
                // The first-use prompt: Return allows (its default button), Backspace and Esc act as in the view.
                if (action === "paste") {
                    c.clipAllow();
                    return true;
                }
                if (action !== "leave" && action !== "escape")
                    return action !== "";
            }
            const item = c.selectedClip();
            switch (action) {
            case "paste":
                c.clipPaste(item, false);
                return true;
            case "pastePlain":
                c.clipPaste(item, true);
                return true;
            case "copy":
                c.clipCopy(item);
                return true;
            case "pin":
                c.clipTogglePin(item);
                return true;
            case "delete":
                c.clipDelete(item);
                return true;
            case "preview":
                c.clipTogglePreview();
                return true;
            case "menu":
                openRowMenuAtSelection();
                return true;
            case "leave":
                c.leaveClipboard();
                return true;
            case "up":
                c.move(-1);
                return true;
            case "down":
                c.move(1);
                return true;
            case "more":
                c.zone = "more";
                return true;
            case "escape":
                if (c.clipPreview)
                    c.closePreview();
                else if (field.text !== "")
                    field.text = "";
                else
                    c.hide();
                return true;
            }
            return false;
        }

        function rowMenuModel(item: var): var {
            if (!item || !item.clip)
                return [];
            const names = {
                "paste": [qsTr("Paste"), "Return"],
                "pastePlain": [qsTr("Paste as Plain Text"), "Shift+Return"],
                "copy": [qsTr("Copy"), "Ctrl+C"],
                "pin": [qsTr("Pin"), "Ctrl+P"],
                "unpin": [qsTr("Unpin"), "Ctrl+P"],
                "delete": [qsTr("Delete Item"), "Ctrl+Backspace"]
            };
            return ClipView.menuIds(item.clip).map(id => id === "-" ? {
                    separator: true
                } : {
                    id: id,
                    text: names[id][0],
                    shortcut: names[id][1],
                    destructive: id === "delete"
                });
        }

        function moreMenuModel(): var {
            return [
                {
                    id: "clear",
                    text: qsTr("Clear History"),
                    enabled: root.controller.items.some(it => it.clip && !it.clip.pinned)
                },
                {
                    separator: true
                },
                {
                    id: "settings",
                    text: qsTr("Settings…")
                }
            ];
        }

        function openRowMenu(item: var, x: real, y: real): void {
            if (!item || !item.clip || root.controller.clipPrompt)
                return;
            root.controller.closePreview();
            win.menuItem = item;
            win.menuAt = Qt.point(x, y);
            win.menuKind = "row";
        }

        // The Menu key and Shift+F10: the selected row's menu, at the row's left under its title.
        function openRowMenuAtSelection(): void {
            const c = root.controller;
            const item = c.selectedClip();
            if (!item)
                return;
            const rowItem = list.itemAtIndex(c.selected);
            const at = rowItem ? rowItem.mapToItem(win.contentItem, Tokens.searchRowTextInset - Tokens.searchRowInset, rowItem.height) : Qt.point(panel.x, panel.y);
            openRowMenu(item, at.x, at.y);
        }

        function openMoreMenu(): void {
            if (!win.clipView)
                return;
            root.controller.zone = "field";
            // Under the capsule, its right edge under the More button's (a pull-down at the right end of a field).
            win.menuItem = null;
            win.menuAt = Qt.point(capsule.x + capsuleButton.x + capsuleButton.width, capsule.y + capsule.height + Tokens.spacingSm);
            win.menuKind = "more";
        }

        // The row's right side, level with its top (the Actions list hangs there, spec §3.3).
        function placeActions(): void {
            const rowItem = list.itemAtIndex(root.controller.selected);
            win.actionsAt = rowItem ? rowItem.mapToItem(win.contentItem, rowItem.width + Tokens.searchClipPreviewGap, 0) : Qt.point(panel.x + panel.width + Tokens.searchClipPreviewGap, panel.y);
            win.actionsPlaced = true;
        }

        function closeMenu(): void {
            if (win.menuKind === "")
                return;
            win.menuKind = "";
            win.menuItem = null;
            if (win.shown)
                field.forceActiveFocus();
        }

        function applyMenu(id: string): void {
            const c = root.controller;
            const item = win.menuItem;
            closeMenu();
            switch (id) {
            case "paste":
                c.clipPaste(item, false);
                return;
            case "pastePlain":
                c.clipPaste(item, true);
                return;
            case "copy":
                c.clipCopy(item);
                return;
            case "pin":
            case "unpin":
                c.clipTogglePin(item);
                return;
            case "delete":
                c.clipDelete(item);
                return;
            case "clear":
                c.clipClearHistory();
                return;
            case "settings":
                c.clipOpenSettings();
                return;
            }
        }

        // "Text · Copied 11:23", or "Copied" for a moment after a copy (CB-8).
        function clipSubtitle(info: var): string {
            if (!info || !info.clip)
                return "";
            if (root.controller.clipCopiedKey === info.key)
                return qsTr("Copied");
            const entry = info.clip;
            let kind;
            switch (ClipView.kindKey(entry)) {
            case "formatted":
                kind = qsTr("Formatted Text");
                break;
            case "image":
                kind = ClipView.imageFormat(entry) !== "" ? qsTr("%1 image").arg(ClipView.imageFormat(entry)) : qsTr("Image");
                break;
            case "files":
                kind = qsTr("Files");
                break;
            case "items":
                // Always two or more files (ClipboardView.kindKey): the plural alone.
                kind = qsTr("%1 Items").arg(entry.files);
                break;
            default:
                kind = qsTr("Text");
            }
            return kind + " · " + clipTime(entry.copiedAt);
        }

        // When the item was copied: the time alone today ("Copied 11:23"), the date and time before (the locale's short formats).
        function clipTime(ms: real): string {
            if (!(ms > 0))
                return qsTr("Copied");
            const at = new Date(ms);
            const now = new Date();
            const loc = Qt.locale();
            if (at.getFullYear() === now.getFullYear() && at.getMonth() === now.getMonth() && at.getDate() === now.getDate())
                return qsTr("Copied %1").arg(at.toLocaleTimeString(loc, Locale.ShortFormat));
            return qsTr("Copied on %1").arg(at.toLocaleString(loc, Locale.ShortFormat));
        }

        // The badge of the app that was frontmost at the copy: its window class, looked up as the Dock does.
        function clipAppIcon(appClass: string): string {
            const entry = Apps.lookup(appClass);
            return ThemeIcons.appIcon(entry ? entry.icon : appClass, "application-x-executable");
        }

        // What the view says instead of rows (CB-7 and the helper's state), "" when it shows rows or the prompt.
        function clipStatusText(): string {
            const c = root.controller;
            if (c.clipPrompt || c.rows.length > 0)
                return "";
            if (Clipboard.state === "unsupported")
                return qsTr("Clipboard history needs a compositor with ext-data-control and lock notifications");
            if (Clipboard.state === "dev-off")
                return qsTr("Clipboard history is off in development (set GRASSFIELD_CLIPBOARD_DISPLAY)");
            if (c.query.trim() !== "")
                return qsTr("No Results for “%1”").arg(c.query.trim());
            return qsTr("No Items");
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: root.controller.hide()
        }

        // The query capsule (macOS 27): its own glass, above the results panel.
        Item {
            id: capsule

            x: (win.width - width) / 2
            y: win.height * Tokens.searchCapsuleTopFraction
            width: Math.min(Tokens.searchCapsuleWidth, win.width - 2 * Tokens.searchEdgeMargin)
            height: Tokens.searchCapsuleHeight
            opacity: win.shown ? 1 : 0
            Accessible.role: Accessible.Pane
            Accessible.name: win.clipView ? qsTr("Clipboard") : qsTr("Search")

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            // Swallows clicks on the capsule itself.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
            }

            Material {
                glassClass: "menu"
                anchors.fill: parent
                radius: height / 2
            }

            Icon {
                id: glass
                x: Tokens.searchCapsuleGlyphInset
                y: (parent.height - height) / 2
                size: Tokens.searchCapsuleGlyph
                // The Clipboard view shows the clipboard symbol in the field (M-3).
                name: win.clipView ? "clipboard" : "search"
                color: Appearance.colors.textSecondary
            }

            TextInput {
                id: field
                TextCursor {}
                x: Tokens.searchCapsuleTextInset
                y: 0
                width: capsule.width - x - Tokens.searchCapsuleGlyphInset - (capsuleButton.visible ? capsuleButton.width + Tokens.spacingSm : 0)
                height: capsule.height
                verticalAlignment: TextInput.AlignVCenter
                color: Appearance.colors.text
                selectionColor: Appearance.highlight
                selectedTextColor: Appearance.highlightText
                font.family: Appearance.fontFamilyFor(Tokens.searchCapsuleTextSize)
                font.pixelSize: Tokens.searchCapsuleTextSize
                clip: true
                focus: true
                // No blinking caret in the visual fixture: a captured frame must not depend on the blink phase.
                cursorVisible: activeFocus && !VisualFixtures.active
                Accessible.role: Accessible.EditableText
                Accessible.name: win.clipView ? qsTr("Clipboard") : qsTr("Search")
                Accessible.description: win.clipView ? qsTr("Type to search the clipboard history") : qsTr("Type to search applications, files, calculations and commands")

                onTextChanged: {
                    if (!win.shown)
                        return;
                    root.controller.keyStartMs = Date.now();
                    root.controller.setQuery(text);
                    root.controller.keyStartMs = 0;
                }

                Keys.onPressed: event => {
                    const c = root.controller;
                    const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
                    // The Clipboard view has its own keys (ClipboardView.keyAction); a key it does not use types into the field.
                    if (c.clipboardView) {
                        const action = ClipView.keyAction(event.key, event.modifiers, field.text === "", field.selectedText !== "");
                        event.accepted = win.clipKey(action);
                        return;
                    }
                    // ⌘4 (Super+4, forwarded as Ctrl+4): the Clipboard view (M-1).
                    if (ClipView.opensView(event.key, event.modifiers, event.nativeScanCode)) {
                        c.enterClipboard();
                        event.accepted = true;
                        return;
                    }
                    event.accepted = true;
                    // The chips hold the keyboard reach (the field keeps the text focus): they take their keys first, and
                    // a key they do not know leaves them and acts on the field as usual.
                    if (c.zone === "chips") {
                        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
                        const actions = {};
                        actions[Qt.Key_Tab] = shift ? "prev" : "next";
                        actions[Qt.Key_Backtab] = "prev";
                        actions[Qt.Key_Left] = "left";
                        actions[Qt.Key_Right] = "right";
                        actions[Qt.Key_Home] = "home";
                        actions[Qt.Key_End] = "end";
                        actions[Qt.Key_Escape] = "escape";
                        actions[Qt.Key_Space] = "activate";
                        actions[Qt.Key_Return] = "activate";
                        actions[Qt.Key_Enter] = "activate";
                        if (c.chipKey(actions[event.key] ?? "other"))
                            return;
                    }
                    // The keys of the results view (Actions.js): Tab opens Actions, Shift+Tab reaches the chips, Page Down and
                    // Page Up (Ctrl+Down, Ctrl+Up) move between the groups.
                    switch (ActionsJs.keyAction(event.key, event.modifiers, event.nativeScanCode)) {
                    case "actions":
                        c.openActions();
                        return;
                    case "chips":
                        c.enterChips();
                        return;
                    case "groupNext":
                        c.moveGroup(1);
                        return;
                    case "groupPrev":
                        c.moveGroup(-1);
                        return;
                    }
                    switch (event.key) {
                    case Qt.Key_Down:
                        c.move(1);
                        break;
                    case Qt.Key_Up:
                        c.move(-1);
                        break;
                    case Qt.Key_Return:
                    case Qt.Key_Enter:
                        c.activateSelected(ctrl);
                        break;
                    case Qt.Key_Escape:
                        if (field.text !== "")
                            field.text = "";
                        else
                            c.hide();
                        break;
                    default:
                        event.accepted = false;
                    }
                }

                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: field.text === "" && field.preeditText === ""
                    text: win.clipView ? qsTr("Clipboard") : qsTr("Search")
                    textFormat: Text.PlainText
                    color: Appearance.colors.textSecondary
                    font: field.font
                }
            }

            // Right of the field: the Clipboard button while the field is empty (M-1), the More button in the Clipboard view
            // (M-8, its menu: Clear History, Settings…).
            Item {
                id: capsuleButton

                readonly property bool more: win.clipView
                readonly property bool focused: more && root.controller.zone === "more"

                x: capsule.width - Tokens.searchCapsuleGlyphInset - width
                y: (capsule.height - height) / 2
                width: Tokens.searchClipMoreSize
                height: Tokens.searchClipMoreSize
                visible: more || field.text === ""
                Accessible.role: Accessible.Button
                Accessible.name: more ? qsTr("More") : qsTr("Clipboard")
                Accessible.focused: focused
                Accessible.onPressAction: if (capsuleButton.visible)
                    capsuleButton.press()

                function press(): void {
                    if (more)
                        win.openMoreMenu();
                    else
                        root.controller.enterClipboard();
                }

                Icon {
                    anchors.centerIn: parent
                    size: Tokens.searchClipMoreSize
                    name: capsuleButton.more ? "ellipsis-circle" : "clipboard"
                    color: buttonMouse.containsMouse ? Appearance.colors.text : Appearance.colors.textSecondary
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -Tokens.controlFocusOutline
                    radius: width / 2
                    visible: capsuleButton.focused
                    color: "transparent"
                    border.width: Tokens.controlFocusOutline
                    border.color: Appearance.focusRingColor
                }

                MouseArea {
                    id: buttonMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton
                    onClicked: capsuleButton.press()
                }
            }
        }

        Item {
            id: panel

            readonly property bool hasResults: root.controller.rows.length > 0
            // Chips need something to choose between; a lone category is the list itself.
            readonly property bool chipsShown: root.controller.chipsShown
            readonly property real chipBlock: chipsShown ? Tokens.searchPanelTop + Tokens.launcherChipHeight + Tokens.searchChipBottom : 0
            // A query nothing answers (file search settled): a centred notice instead of a bare field.
            readonly property bool noResults: !win.clipView && !hasResults && root.controller.query.trim() !== "" && !root.controller.filesPending
            // The Clipboard view without rows: a notice (No Items, No Results, the helper's state) or the first-use prompt.
            readonly property string clipStatus: win.clipView ? win.clipStatusText() : ""
            readonly property bool prompt: win.clipView && root.controller.clipPrompt
            readonly property bool notice: noResults || clipStatus !== ""
            readonly property bool footer: win.clipView && root.controller.clipNotice !== "" && hasResults
            readonly property real listTop: chipBlock + Tokens.spacingSm
            // Nothing to show under the capsule: no panel at all (an empty query without chips or recents).
            readonly property bool used: chipsShown || hasResults || notice || prompt

            x: (win.width - width) / 2
            y: capsule.y + capsule.height + Tokens.searchCapsuleGap
            width: Math.min(Tokens.searchWidth, win.width - 2 * Tokens.searchEdgeMargin)
            // The height the panel glides to (the Behavior below): its glass is judged over the panel at rest, so a keystroke
            // that changes the row count does not measure the backdrop again on every frame of the glide (audit B-03).
            readonly property real restHeight: chipBlock + (hasResults ? Math.min(list.contentHeight + 2 * Tokens.spacingSm, win.maxResults - chipBlock) : 0) + (notice ? Tokens.searchEmptyHeight : 0) + (prompt ? promptBlock.implicitHeight : 0) + (footer ? footerText.height : 0)
            height: restHeight
            visible: used
            opacity: win.shown ? 1 : 0
            Accessible.role: Accessible.Pane
            Accessible.name: win.clipView ? qsTr("Clipboard") : qsTr("Search")

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            // Under Reduce Motion the results take their height at once (ADR-0039 step 5).
            Behavior on height {
                enabled: !Appearance.reduceMotion
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                    // A resize: the move curve (ADR-0039 step 20).
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.curve
                }
            }

            // Swallows clicks on the panel itself.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
            }

            Material {
                glassClass: "menu"
                anchors.fill: parent
                radius: Tokens.radiusSearch
                // The window covers the output, so the panel's own coordinates are the output's.
                backdropRect: Qt.rect(panel.x, panel.y, panel.width, panel.restHeight)
            }

            // Filter chips. The field keeps the text focus; Tab past the last result group (Shift+Tab before the first) moves
            // the focus ring to the chips, Left/Right move along them, Space or Return selects, Esc or Tab leaves.
            Flickable {
                id: chipFlick
                visible: panel.chipsShown
                x: Tokens.searchFieldInset - Tokens.controlFocusOutline
                y: Tokens.searchPanelTop - Tokens.controlFocusOutline
                width: panel.width - 2 * Tokens.searchFieldInset + 2 * Tokens.controlFocusOutline
                // Room around the chips for the focus ring outside them (the row clips).
                height: Tokens.launcherChipHeight + 2 * Tokens.controlFocusOutline
                contentWidth: chipRow.width + 2 * Tokens.controlFocusOutline
                contentHeight: height
                clip: true
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentWidth > width
                Accessible.role: Accessible.Pane
                Accessible.name: qsTr("Filters")

                Row {
                    id: chipRow
                    x: Tokens.controlFocusOutline
                    y: Tokens.controlFocusOutline
                    spacing: Tokens.launcherChipGap

                    Repeater {
                        model: root.controller.chips

                        AppsChip {
                            required property string modelData
                            required property int index

                            label: root.controller.chipLabels[modelData]
                            focused: root.controller.zone === "chips" && root.controller.chipIndex === index
                            active: root.controller.filter === modelData
                            onClicked: {
                                root.controller.leaveChips();
                                root.controller.toggleFilter(modelData);
                            }
                            onFocusedChanged: {
                                if (focused)
                                    chipFlick.contentX = Math.max(0, Math.min(chipFlick.contentWidth - chipFlick.width, x + width / 2 - chipFlick.width / 2));
                            }
                        }
                    }
                }
            }

            Text {
                id: emptyNotice
                visible: panel.notice
                x: Tokens.searchFieldInset
                y: panel.chipBlock
                width: panel.width - 2 * Tokens.searchFieldInset
                height: Tokens.searchEmptyHeight
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: win.clipView ? Text.ElideRight : Text.ElideMiddle
                // The Clipboard view's notices may take two lines; Search's own notice keeps one.
                maximumLineCount: win.clipView ? 2 : 1
                wrapMode: win.clipView ? Text.WordWrap : Text.NoWrap
                textFormat: Text.PlainText
                text: win.clipView ? panel.clipStatus : qsTr("No Results for “%1”").arg(root.controller.query.trim())
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyTitleSize
                font.weight: Tokens.typographySmallWeight
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            // The first visit while the history is off (CB-6, macOS 27's prompt): "Not Now" leaves it off, "Allow" turns it on.
            Column {
                id: promptBlock
                visible: panel.prompt
                x: Tokens.searchClipPromptPadding
                width: panel.width - 2 * Tokens.searchClipPromptPadding
                spacing: Tokens.spacingMd
                topPadding: Tokens.searchClipPromptPadding
                bottomPadding: Tokens.searchClipPromptPadding
                Accessible.role: Accessible.AlertMessage
                Accessible.name: promptTitle.text

                Text {
                    id: promptTitle
                    width: parent.width
                    text: qsTr("Allow results from the clipboard in Search?")
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyTitleSize
                    font.weight: Tokens.typographyMenuWeight
                }

                Text {
                    width: parent.width
                    text: qsTr("Personal and sensitive information may appear in the results. You can change this at any time in Search settings.")
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                Row {
                    anchors.right: parent.right
                    spacing: Tokens.spacingSm

                    Button {
                        text: qsTr("Not Now")
                        focusPolicy: Qt.NoFocus
                        onClicked: root.controller.clipNotNow()
                    }

                    Button {
                        text: qsTr("Allow")
                        primary: true
                        focusPolicy: Qt.NoFocus
                        onClicked: root.controller.clipAllow()
                    }
                }
            }

            ListView {
                id: list
                x: Tokens.searchRowInset
                y: panel.listTop
                width: panel.width - 2 * Tokens.searchRowInset
                height: panel.height - y - Tokens.spacingSm - (panel.footer ? footerText.height : 0)
                visible: panel.hasResults
                clip: true
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                // Keyed rows updated in place (Search.rowModel, audit B-05): a result that stays keeps its delegate while the
                // query changes. One row per result (no group headers): the row index is the result index.
                model: root.controller.rowModel
                currentIndex: root.controller.selected
                onCurrentIndexChanged: {
                    if (currentIndex >= 0)
                        positionViewAtIndex(currentIndex, ListView.Contain);
                }

                // macOS 27: no group headers, 17 / 15 type, text 72 from the panel edge, and a neutral selected row (a light
                // fill, not the accent) concentric with the panel.
                delegate: Item {
                    id: row

                    required property string key
                    required property int itemIndex
                    required property int index

                    readonly property bool selected: itemIndex === root.controller.selected
                    // The result this row shows; a placeholder in the moment the results and the rows are not yet in step.
                    readonly property var info: root.controller.items[itemIndex] ?? win.noResult
                    readonly property var entry: info.kind === "clip" ? info.clip : null
                    // The pin and copy buttons show on the selected or hovered row; a pinned row always shows its filled pin.
                    readonly property bool buttons: entry !== null && (selected || rowMouse.containsMouse)
                    readonly property string subtitle: entry !== null ? win.clipSubtitle(info) : info.subtitle

                    width: list.width
                    height: Tokens.searchRowHeight
                    Accessible.role: Accessible.ListItem
                    Accessible.name: info.title + ", " + row.subtitle + (entry !== null && entry.pinned ? ", " + qsTr("Pinned") : "")
                    Accessible.selected: selected
                    Accessible.onPressAction: root.controller.activate(info, false)

                    Rectangle {
                        visible: row.selected
                        anchors.fill: parent
                        radius: Tokens.searchRowRadius
                        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.searchSelectionFillOpacity)
                    }

                    Item {
                        id: iconBox
                        x: Tokens.searchRowIconInset - Tokens.searchRowInset
                        anchors.verticalCenter: parent.verticalCenter
                        width: Tokens.searchRowIconSize
                        height: Tokens.searchRowIconSize

                        TintedIcon {
                            anchors.fill: parent
                            size: Tokens.searchRowIconSize
                            oversample: Tokens.searchIconOversample
                            visible: row.info.iconSource !== undefined
                            source: row.info.iconSource === undefined ? "" : (row.info.appIcon !== undefined ? ThemeIcons.appIcon(row.info.appIcon, "application-x-executable") : row.info.iconSource)
                            asynchronous: true
                        }

                        Icon {
                            anchors.centerIn: parent
                            visible: row.info.glyph !== undefined
                            size: Tokens.searchRowIconSize * Tokens.searchGlyphScale
                            name: row.info.glyph !== undefined ? row.info.glyph : ""
                            color: Appearance.colors.text
                        }

                        Rectangle {
                            anchors.fill: parent
                            visible: row.info.badge !== undefined
                            radius: Tokens.radiusControl
                            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

                            Text {
                                anchors.centerIn: parent
                                text: row.info.badge !== undefined ? row.info.badge : ""
                                textFormat: Text.PlainText
                                color: Appearance.colors.text
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyTitleSize
                            }
                        }

                        // A clipboard item's thumbnail (M-4): a page with the text, the picture (made by the helper's worker), or
                        // the files' glyph.
                        Rectangle {
                            id: page
                            anchors.centerIn: parent
                            width: Tokens.searchClipPageWidth
                            height: Tokens.searchRowIconSize
                            visible: row.entry !== null && row.entry.kind === "text"
                            radius: Tokens.radiusControl / 2
                            color: Appearance.colors.windowBackground
                            border.width: Tokens.searchClipPageBorder
                            border.color: Appearance.withAlpha(Appearance.colors.text, Tokens.materialFillOpacity)
                            clip: true

                            Text {
                                anchors.fill: parent
                                anchors.margins: Tokens.searchClipPageInset
                                text: row.entry !== null ? row.entry.excerpt : ""
                                textFormat: Text.PlainText
                                wrapMode: Text.WrapAnywhere
                                elide: Text.ElideRight
                                color: Appearance.colors.textSecondary
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.searchClipPageTextSize
                            }
                        }

                        Image {
                            anchors.fill: parent
                            visible: row.entry !== null && row.entry.kind === "image" && row.entry.thumbnail !== ""
                            source: visible ? "file://" + row.entry.thumbnail : ""
                            sourceSize.width: Tokens.searchRowIconSize * Tokens.searchIconOversample
                            sourceSize.height: Tokens.searchRowIconSize * Tokens.searchIconOversample
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            cache: false
                        }

                        Icon {
                            anchors.centerIn: parent
                            visible: row.entry !== null && (row.entry.kind === "files" || (row.entry.kind === "image" && row.entry.thumbnail === ""))
                            size: Tokens.searchRowIconSize * Tokens.searchGlyphScale
                            name: row.entry !== null && row.entry.kind === "files" ? "folder" : "document"
                            color: Appearance.colors.text
                        }

                        // The source app's icon as a badge at the thumbnail's bottom right (M-4; Wayland names no copier: the app
                        // that was frontmost, ADR-0034 §3).
                        TintedIcon {
                            x: parent.width - width + Tokens.searchClipBadgeOverhang
                            y: parent.height - height + Tokens.searchClipBadgeOverhang
                            width: Tokens.searchClipBadgeSize
                            height: Tokens.searchClipBadgeSize
                            size: Tokens.searchClipBadgeSize
                            oversample: Tokens.searchIconOversample
                            visible: row.entry !== null && row.entry.app !== ""
                            source: visible ? win.clipAppIcon(row.entry.app) : ""
                            asynchronous: true
                        }
                    }

                    Column {
                        anchors {
                            left: parent.left
                            leftMargin: Tokens.searchRowTextInset - Tokens.searchRowInset
                            right: parent.right
                            rightMargin: row.entry !== null ? clipButtons.width + Tokens.searchClipButtonInset + Tokens.spacingSm : Tokens.spacingMd
                            verticalCenter: parent.verticalCenter
                        }

                        Text {
                            width: parent.width
                            text: row.info.title
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.searchTitleSize
                            font.letterSpacing: Appearance.tracking(Tokens.searchTitleSize)
                            font.weight: Tokens.typographyMenuWeight
                        }

                        Text {
                            width: parent.width
                            text: row.subtitle
                            textFormat: Text.PlainText
                            elide: Text.ElideMiddle
                            color: Appearance.colors.textSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.searchSubtitleSize
                            font.letterSpacing: Appearance.tracking(Tokens.searchSubtitleSize)
                        }
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        // A secondary click opens a clipboard row's menu; Search's other rows take the primary button only.
                        acceptedButtons: row.entry !== null ? Qt.LeftButton | Qt.RightButton : Qt.LeftButton
                        onPositionChanged: root.controller.selected = row.itemIndex
                        onClicked: mouse => {
                            if (mouse.button === Qt.RightButton) {
                                root.controller.selected = row.itemIndex;
                                const at = row.mapToItem(win.contentItem, mouse.x, mouse.y);
                                win.openRowMenu(row.info, at.x, at.y);
                                return;
                            }
                            root.controller.activate(row.info, false);
                        }
                    }

                    // The pin button (Grassfield: Windows' pin) and the round copy button at the row's right (M-4, M-5).
                    Row {
                        id: clipButtons
                        visible: row.entry !== null
                        anchors.right: parent.right
                        anchors.rightMargin: Tokens.searchClipButtonInset
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Tokens.searchClipButtonGap

                        Repeater {
                            model: ["pin", "copy"]

                            Rectangle {
                                id: clipButton

                                required property string modelData

                                readonly property bool pin: modelData === "pin"
                                readonly property bool pinned: row.entry !== null && row.entry.pinned === true

                                width: Tokens.searchClipButtonSize
                                height: Tokens.searchClipButtonSize
                                radius: width / 2
                                // A pinned row shows its pin even when neither selected nor hovered.
                                opacity: row.buttons || (pin && pinned) ? 1 : 0
                                color: row.buttons ? Appearance.buttonFill : "transparent"
                                Accessible.role: Accessible.Button
                                Accessible.name: pin ? (pinned ? qsTr("Unpin") : qsTr("Pin")) : qsTr("Copy")
                                Accessible.onPressAction: if (clipButton.opacity > 0)
                                    clipButton.press()

                                function press(): void {
                                    if (pin)
                                        root.controller.clipTogglePin(row.info);
                                    else
                                        root.controller.clipCopy(row.info);
                                }

                                Icon {
                                    anchors.centerIn: parent
                                    size: Tokens.searchClipButtonGlyph
                                    name: clipButton.pin ? (clipButton.pinned ? "pin-fill" : "pin") : "copy"
                                    color: Appearance.colors.text
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: clipButton.opacity > 0
                                    acceptedButtons: Qt.LeftButton
                                    onClicked: clipButton.press()
                                }
                            }
                        }
                    }
                }
            }

            // A short notice under the rows ("Pinned items are full", CB-15).
            Text {
                id: footerText
                visible: panel.footer
                x: Tokens.searchFieldInset
                y: panel.height - height - Tokens.spacingSm
                width: panel.width - 2 * Tokens.searchFieldInset
                height: Tokens.searchClipButtonSize
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                textFormat: Text.PlainText
                text: root.controller.clipNotice
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.searchSubtitleSize
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }

        // The item preview (CB-11) beside the results: the plain text (never rendered), a picture of at most 1,024 px made on
        // demand by the helper's worker, or the files' paths. It follows the selection; Space, Ctrl+Y and Esc close it.
        Item {
            id: preview

            readonly property var item: root.controller.clipPreview
            readonly property bool fitsRight: panel.x + panel.width + Tokens.searchClipPreviewGap + width <= win.width - Tokens.searchEdgeMargin

            // It fades out with the panel; the controller drops it once the panel is released (U9).
            visible: item !== null && panel.visible
            opacity: win.shown ? 1 : 0
            x: fitsRight ? panel.x + panel.width + Tokens.searchClipPreviewGap : Math.max(Tokens.searchEdgeMargin, panel.x - Tokens.searchClipPreviewGap - width)
            y: panel.y
            width: Tokens.searchClipPreviewWidth
            height: Math.max(panel.height, Tokens.searchEmptyHeight)
            Accessible.role: Accessible.Pane
            Accessible.name: qsTr("Preview")

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
            }

            Material {
                glassClass: "menu"
                anchors.fill: parent
                radius: Tokens.radiusSearch
            }

            Image {
                anchors.fill: parent
                anchors.margins: Tokens.searchFieldInset
                visible: preview.item !== null && preview.item.kind === "image" && root.controller.clipPreviewPath !== ""
                source: visible ? "file://" + root.controller.clipPreviewPath : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
            }

            Flickable {
                id: previewFlick
                anchors.fill: parent
                anchors.margins: Tokens.searchFieldInset
                visible: preview.item !== null && preview.item.kind !== "image"
                contentWidth: width
                contentHeight: previewText.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Text {
                    id: previewText
                    width: previewFlick.width
                    text: root.controller.clipPreviewText
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.searchClipPreviewTextSize
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }
            }
        }

        // The row menu (secondary click, the Menu key, Shift+F10) and the More menu, inside this window: it already covers the
        // screen and holds the keyboard. A press outside the menu closes it and is swallowed.
        MouseArea {
            anchors.fill: parent
            z: 900
            visible: win.menuKind !== "" || win.actionsPlaced
            acceptedButtons: Qt.AllButtons
            onPressed: mouse => {
                if (win.actionsPlaced) {
                    if (!actionsLoader.contains(actionsLoader.mapFromItem(win.contentItem, mouse.x, mouse.y)))
                        root.controller.closeActions();
                    return;
                }
                const menu = menuLoader.item as PopupMenu;
                if (!menu || !menu.containsPoint(mouse.x, mouse.y))
                    win.closeMenu();
            }
        }

        Loader {
            id: menuLoader

            readonly property real menuWidth: (item as Item)?.width ?? 0
            // The More menu hangs from its right edge (menuAt), a row menu from its top left (the pointer).
            readonly property point placed: MenuPlace.place({x: win.menuKind === "more" ? win.menuAt.x - menuWidth : win.menuAt.x, y: win.menuAt.y}, {w: menuWidth, h: (item as Item)?.height ?? 0}, {w: win.width, h: win.height}, Tokens.panelPopupMargin)

            z: 901
            x: placed.x
            y: placed.y
            active: win.menuKind !== ""
            sourceComponent: PopupMenu {
                bounds: win.contentItem
                model: win.menuModel
                accessibleName: win.menuKind === "more" ? qsTr("More") : qsTr("Clipboard item")
                onActivated: item => win.applyMenu(item.id)
                onCloseRequested: win.closeMenu()
            }
            onLoaded: (item as Item).forceActiveFocus()
        }

        // The Actions list of the selected row (Tab): the `menu` class, with a filter field above it when the row has more than
        // seven actions. The field or the list holds the keyboard; Esc closes, Return runs, Tab closes again.
        Loader {
            id: actionsLoader

            // The list's glass for the blur region (the box sets it on load).
            property Item glass: null
            readonly property point placed: MenuPlace.place(win.actionsAt, {w: width, h: height}, {w: win.width, h: win.height}, Tokens.panelPopupMargin)

            z: 901
            x: placed.x
            y: placed.y
            width: (item as Item)?.width ?? 0
            height: (item as Item)?.height ?? 0
            active: win.actionsPlaced
            onLoaded: (item as Item).forceActiveFocus()

            sourceComponent: FocusScope {
                id: box

                readonly property var all: root.controller.actionList
                readonly property bool filtered: ActionsJs.needsFilter(all)
                readonly property var visibleActions: ActionsJs.filter(all, filterField.text)

                width: menu.width
                height: (filtered ? filterField.height + Tokens.spacingSm : 0) + menu.height

                // Tab leaves as it came: the keys the list and the field do not use end here.
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                        root.controller.closeActions();
                        event.accepted = true;
                    }
                }

                function chooseFirst(): void {
                    menu.currentIndex = ActionsJs.firstSelectable(box.visibleActions);
                }

                onVisibleActionsChanged: Qt.callLater(chooseFirst)
                Component.onCompleted: {
                    actionsLoader.glass = menu;
                    chooseFirst();
                }
                Component.onDestruction: actionsLoader.glass = null

                SearchField {
                    id: filterField
                    width: menu.width
                    visible: box.filtered
                    toolbar: true
                    focus: box.filtered
                    placeholderText: qsTr("Search Actions")
                    Accessible.name: qsTr("Search Actions")
                    Keys.onPressed: event => {
                        switch (event.key) {
                        case Qt.Key_Down:
                            menu.currentIndex = ActionsJs.step(box.visibleActions, menu.currentIndex, 1);
                            event.accepted = true;
                            break;
                        case Qt.Key_Up:
                            menu.currentIndex = ActionsJs.step(box.visibleActions, menu.currentIndex, -1);
                            event.accepted = true;
                            break;
                        case Qt.Key_Return:
                        case Qt.Key_Enter:
                            if (menu.currentIndex >= 0 && menu.currentIndex < box.visibleActions.length)
                                menu.activated(box.visibleActions[menu.currentIndex], false);
                            event.accepted = true;
                            break;
                        }
                    }
                    // Esc clears the typed words first, a second one closes.
                    Keys.onEscapePressed: event => {
                        if (text !== "")
                            clear();
                        else
                            root.controller.closeActions();
                        event.accepted = true;
                    }
                }

                PopupMenu {
                    id: menu
                    y: box.filtered ? filterField.height + Tokens.spacingSm : 0
                    bounds: win.contentItem
                    focus: !box.filtered
                    model: box.visibleActions
                    accessibleName: qsTr("Actions")
                    onActivated: item => root.controller.runAction(item.id)
                    onCloseRequested: root.controller.closeActions()
                }
            }
        }
    }
}
