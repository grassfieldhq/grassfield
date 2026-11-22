pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T

// Modal sheet over its window: a title, a message, an optional text field and Cancel / confirm buttons, with more buttons
// at the leading edge when asked (macOS: "Keep Both", "Show Certificate"). Return activates the visible default button: the
// confirm one (red when `destructive`), or Cancel with `returnCancels`; Esc cancels, a click outside the panel is swallowed. Used for Go to Folder, for irreversible actions (Empty Trash) and
// for KIO's questions in Files (apps/files/qml/KioSheets.qml).
// Declare it as a child of the window's content; it fills it. The panel is a QtQuick.Templates Pane on the frosted material.
Item {
    id: root

    property string title: ""
    property string message: ""
    property string confirmText: qsTr("OK")
    property bool destructive: false
    property bool withField: false
    property string placeholder: ""
    // The field hides what is typed (a password); the host may show it again (a "Show password" check box).
    property bool fieldPassword: false
    property string errorText: ""
    // function(text) returning an error message to keep the sheet open, or "" to close it.
    property var confirmHandler: null
    property Item focusBack: null
    // False: only the confirm button (an options sheet whose changes apply at once, macOS "Done").
    property bool showCancel: true
    // The cancel button's text (Displays' countdown sheet says "Revert").
    property string cancelText: qsTr("Cancel")
    // Buttons at the leading edge of the button row, [{id, text}]: a click emits extra(id) and leaves the sheet open (the
    // host closes it, or changes it: "Show Certificate"). Where the row is too narrow they take a row of their own above.
    property var extraButtons: []
    // Return cancels and the cancel button is the default one: for a choice the user should not take by habit (connect
    // to a server whose identity can't be verified; build and install an AUR package).
    property bool returnCancels: false
    // While shown, the keyboard stays in the sheet: whatever takes it elsewhere in the window (a view that focuses itself a
    // moment later) gives it back. For a sheet with no pop-up of its own (Files' KIO questions).
    property bool keepsKeyboard: false
    // False while the confirm button may not act yet (the Store's sheet while it checks a plan): Return does nothing either.
    property bool confirmEnabled: true
    // True while the sheet takes no click and no key (Files' KIO question that just replaced another one: the second click
    // of a double click, or a repeated Return, meant for that one must not answer this one).
    property bool holdInput: false
    // Content between the text and the buttons.
    default property alias body: bodySlot.data
    // A body made the first time the sheet opens, and kept (instead of inline children): a window that declares many sheets
    // does not build every sheet's content at start (Settings declares 34; audit note).
    property Component bodyComponent: null
    readonly property Item bodyItem: bodyLoader.item as Item
    readonly property alias fieldText: field.text
    readonly property bool shown: root.visible

    signal accepted
    signal canceled
    signal extra(string id)

    anchors.fill: parent
    visible: false
    z: 900

    // Motion (owner decision Q6; UI audit 2026-11-05 U6): the panel drops in from above the window on the panel spring
    // (motion.panel, curvePanel) while the dim fades in (motion.fast); what travels is the panel's image, the panel itself
    // stays in its place under it (hidden, not moved), so the keys, the focus and a click reach it as before. Closing, the
    // sheet is hidden at once as before (`visible` and `shown` change exactly as they did) and a still image of it rises out
    // on curveExit while its dim fades.
    // Reduce Motion: no travel, a short crossfade. A sheet opened again while its image leaves (a queued question replacing
    // the answered one) takes its place without either motion.
    readonly property real travel: Appearance.reduceMotion ? 0 : panel.y + panel.height + Tokens.shadowBlur + Tokens.shadowOffsetY
    property Item leaving: null

    function open(): void {
        root.errorText = "";
        const replacing = root.leaving !== null;
        if (root.leaving) {
            root.leaving.destroy();
            root.leaving = null;
        }
        const wasVisible = root.visible;
        // Visible first: a bodyComponent is built now, so the drop-in's travel counts its height.
        root.visible = true;
        if (!wasVisible && !replacing)
            enter.restart();
        if (root.withField) {
            field.forceActiveFocus();
            field.selectAll();
        } else {
            // Not a button the user clicked last time: Return is the default button's, never that one's.
            keySink.forceActiveFocus();
        }
    }

    function setField(text: string): void {
        field.text = text;
    }

    function close(): void {
        // The focus goes back first: hiding may open the window's next sheet (Files' queued KIO question), which then takes it.
        if (root.focusBack)
            root.focusBack.forceActiveFocus();
        if (root.visible)
            root.leave();
        root.visible = false;
    }

    // The leaving image, in the window's content beside the sheet (the hidden sheet draws nothing); it takes no input.
    function leave(): void {
        enter.stop();
        if (!root.parent || root.leaving)
            return;
        root.leaving = leavingComponent.createObject(root.parent, {
            x: root.x,
            y: root.y,
            width: root.width,
            height: root.height,
            z: root.z,
            dimFrom: dim.opacity,
            panelY: panel.y + (enter.running ? entering.shiftY : 0)
        });
    }

    function cancel(): void {
        root.close();
        root.canceled();
    }

    // The sheet's keys: true when it took the key. A key held down (its auto-repeat) answers nothing: Return held past one
    // question must not answer the next one (Grassfield's key repeat starts after 250 ms).
    function handleKey(key: int, autoRepeat: bool): bool {
        if (root.holdInput || autoRepeat)
            return key !== Qt.Key_Tab && key !== Qt.Key_Backtab;
        if (key === Qt.Key_Escape) {
            root.cancel();
            return true;
        }
        if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            if (root.returnCancels)
                root.cancel();
            else
                root.confirm();
            return true;
        }
        return false;
    }

    function reclaimKeyboard(): void {
        if (root.visible && root.keepsKeyboard && !panel.activeFocus && root.Window.active)
            panel.forceActiveFocus();
    }

    function confirm(): void {
        if (!root.confirmEnabled)
            return;
        const cb = root.confirmHandler;
        const error = cb ? cb(field.text) : "";
        // false: the handler answers later (it closes the sheet or sets errorText itself; Activity Monitor's Quit through
        // the shell).
        if (error === false)
            return;
        if (error && error !== "") {
            root.errorText = error;
            return;
        }
        root.close();
        root.accepted();
    }

    Rectangle {
        id: dim
        anchors.fill: parent
        color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.shadowOpacity)

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => wheel.accepted = true
        }
    }

    FocusScope {
        id: panel
        // A sheet never exceeds its window (macOS): it narrows to the window less the side margins, its text wraps; never
        // narrower than its Cancel / confirm pair, which stays whole.
        width: Math.max(Math.min(Tokens.controlSheetWidth, root.width - 2 * Tokens.spacingLg), mainRow.implicitWidth + pane.leftPadding + pane.rightPadding)
        height: pane.implicitHeight
        anchors.horizontalCenter: parent.horizontalCenter
        y: Tokens.spacingLg
        Accessible.role: Accessible.Dialog
        Accessible.name: root.title
        onActiveFocusChanged: {
            if (!panel.activeFocus && root.keepsKeyboard && root.visible)
                Qt.callLater(root.reclaimKeyboard);
        }

        Keys.onPressed: event => event.accepted = root.handleKey(event.key, event.isAutoRepeat)

        // Where the keyboard is when the sheet opens without a field: Return, Esc and the rest reach the panel's handler.
        Item {
            id: keySink
            focus: true
        }

        // Swallows every click while the sheet holds its input (holdInput); above the pane.
        MouseArea {
            anchors.fill: parent
            z: 1
            enabled: root.holdInput
            acceptedButtons: Qt.AllButtons
            hoverEnabled: root.holdInput
        }

        // macOS 27 sheets (Print, Open): the window's corner (radius.sheet), the buttons 20 from the right and bottom edges
        // (panel.sheetPadding, the shell's sheets' too; ADR-0039 step 10).
        T.Pane {
            id: pane
            anchors.fill: parent
            padding: Tokens.panelSheetPadding
            implicitHeight: content.implicitHeight + topPadding + bottomPadding

            // A text surface: the menus' class, as the shell's sheets (ADR-0039 step 22; the apps draw it opaque).
            background: Material {
                glassClass: "menu"
                radius: Tokens.radiusSheet
            }

            contentItem: Column {
                id: content
                spacing: Tokens.spacingMd

                Text {
                    id: titleText
                    textFormat: Text.PlainText
                    width: parent.width
                    text: root.title
                    wrapMode: Text.Wrap
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyTitleSize
                    font.weight: Tokens.typographyMenuBoldWeight
                }

                // The message, the field and the body; they scroll when the sheet would be taller than its window (a
                // long text an application gave), so the buttons stay on screen. Laid out as before when they fit.
                Flickable {
                    id: scroller
                    // What the window leaves for them: its height less the sheet's margins, padding, title, buttons and
                    // error line.
                    readonly property real room: root.height - 2 * Tokens.spacingLg - pane.topPadding - pane.bottomPadding - titleText.height - buttonRow.height - (errorLine.visible ? errorLine.height + content.spacing : 0) - 2 * content.spacing
                    width: parent.width
                    height: Math.max(0, Math.min(middle.implicitHeight, room))
                    contentWidth: width
                    contentHeight: middle.implicitHeight
                    interactive: contentHeight > height
                    clip: interactive
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {}

                    Column {
                        id: middle
                        width: scroller.width
                        spacing: Tokens.spacingMd

                        Text {
                            textFormat: Text.PlainText
                            visible: root.message !== ""
                            width: parent.width
                            text: root.message
                            wrapMode: Text.Wrap
                            color: Appearance.colors.textSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                        }

                        TextField {
                            id: field
                            visible: root.withField
                            width: parent.width
                            focus: root.withField
                            placeholderText: root.placeholder
                            echoMode: root.fieldPassword ? TextInput.Password : TextInput.Normal
                            // A password (Wi-Fi's join): the input method neither learns, stores nor predicts it (GF-118).
                            inputMethodHints: root.fieldPassword ? Qt.ImhSensitiveData | Qt.ImhNoPredictiveText : Qt.ImhNone
                            accessibleName: root.title
                            onTextChanged: root.errorText = ""
                        }

                        Column {
                            id: bodySlot
                            width: parent.width
                            spacing: Tokens.spacingMd

                            // Active from the first show on (it stays loaded once made).
                            Loader {
                                id: bodyLoader
                                width: parent.width
                                active: root.bodyComponent !== null && (root.visible || bodyLoader.status !== Loader.Null)
                                visible: active
                                sourceComponent: root.bodyComponent
                            }
                        }
                    }
                }

                Text {
                    id: errorLine
                    textFormat: Text.PlainText
                    visible: root.errorText !== ""
                    width: parent.width
                    text: root.errorText
                    wrapMode: Text.Wrap
                    color: Appearance.colors.danger
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: root.errorText
                }

                Item {
                    id: buttonRow
                    // The extra buttons on a row of their own when the two groups don't fit side by side.
                    readonly property bool stacked: root.extraButtons.length > 0 && extraRow.implicitWidth + Tokens.spacingLg + mainRow.implicitWidth > width
                    width: parent.width
                    height: buttonRow.stacked ? extraRow.implicitHeight + Tokens.spacingSm + mainRow.implicitHeight : Math.max(extraRow.implicitHeight, mainRow.implicitHeight)

                    Row {
                        id: extraRow
                        anchors.left: parent.left
                        anchors.top: parent.top
                        spacing: Tokens.spacingSm

                        Repeater {
                            model: root.extraButtons

                            Button {
                                required property var modelData
                                sheet: true
                                text: modelData.text
                                // A click leaves the keyboard where it was: Return stays the default button's.
                                focusPolicy: Qt.TabFocus
                                onClicked: root.extra(modelData.id)
                            }
                        }
                    }

                    // Cancel and the default button: one width, the wider label's (macOS 27).
                    Row {
                        id: mainRow
                        readonly property real pairWidth: Math.max(cancelButton.visible ? cancelButton.implicitWidth : 0, confirmButton.implicitWidth)
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        spacing: Tokens.spacingSm

                        Button {
                            id: cancelButton
                            sheet: true
                            width: mainRow.pairWidth
                            visible: root.showCancel
                            text: root.cancelText
                            primary: root.returnCancels
                            focusPolicy: Qt.TabFocus
                            onClicked: root.cancel()
                        }

                        Button {
                            id: confirmButton
                            sheet: true
                            width: mainRow.pairWidth
                            text: root.confirmText
                            focusPolicy: Qt.TabFocus
                            // Return's button is always the visible default: a destructive one is drawn as the red default
                            // (macOS: the action the user asked for, Empty Trash, stays the default and is marked destructive;
                            // UI audit 2026-11-05 U20). A choice not to take by habit sets returnCancels instead.
                            primary: !root.returnCancels
                            destructive: root.destructive
                            enabled: root.confirmEnabled
                            onClicked: root.confirm()
                        }
                    }
                }
            }
        }
    }

    // The panel's image while it drops in, drawn instead of the panel (hideSource), which keeps its place and its input.
    ShaderEffectSource {
        id: entering

        property real shiftY: 0
        // Room for the panel's shadow around its image (Material.shadowMargin).
        readonly property real margin: Tokens.shadowBlur + Tokens.shadowOffsetY

        visible: enter.running
        sourceItem: enter.running ? panel : null
        hideSource: enter.running
        live: true
        sourceRect: Qt.rect(-margin, -margin, panel.width + 2 * margin, panel.height + 2 * margin)
        x: panel.x - margin
        y: panel.y - margin + shiftY
        width: panel.width + 2 * margin
        height: panel.height + 2 * margin
    }

    ParallelAnimation {
        id: enter

        NumberAnimation {
            target: dim
            property: "opacity"
            from: 0
            to: 1
            duration: Appearance.duration(Tokens.motionFast)
        }
        NumberAnimation {
            target: entering
            property: "shiftY"
            from: -root.travel
            to: 0
            duration: Appearance.duration(Tokens.motionPanel)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.curvePanel
        }
        // Under Reduce Motion the panel crossfades instead of travelling.
        NumberAnimation {
            target: entering
            property: "opacity"
            from: Appearance.reduceMotion ? 0 : 1
            to: 1
            duration: Appearance.duration(Tokens.motionFast)
        }
    }

    Component {
        id: leavingComponent

        Item {
            id: leavingItem

            property real dimFrom: 1
            property real panelY: 0
            // Room for the panel's shadow around its image (Material.shadowMargin).
            readonly property real margin: Tokens.shadowBlur + Tokens.shadowOffsetY

            Rectangle {
                id: leavingDim
                anchors.fill: parent
                color: dim.color
                opacity: leavingItem.dimFrom
            }

            ShaderEffectSource {
                id: still
                sourceItem: panel
                live: false
                hideSource: false
                sourceRect: Qt.rect(-leavingItem.margin, -leavingItem.margin, panel.width + 2 * leavingItem.margin, panel.height + 2 * leavingItem.margin)
                x: panel.x - leavingItem.margin
                y: leavingItem.panelY - leavingItem.margin
                width: panel.width + 2 * leavingItem.margin
                height: panel.height + 2 * leavingItem.margin
            }

            ParallelAnimation {
                running: true
                onFinished: {
                    if (root.leaving === leavingItem)
                        root.leaving = null;
                    leavingItem.destroy();
                }

                NumberAnimation {
                    target: leavingDim
                    property: "opacity"
                    to: 0
                    duration: Appearance.duration(Tokens.motionFast)
                }
                NumberAnimation {
                    target: still
                    property: "y"
                    to: leavingItem.panelY - leavingItem.margin - root.travel
                    duration: Appearance.duration(Tokens.motionNormal)
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.curveExit
                }
                NumberAnimation {
                    target: still
                    property: "opacity"
                    to: Appearance.reduceMotion ? 0 : 1
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }
        }
    }
}
