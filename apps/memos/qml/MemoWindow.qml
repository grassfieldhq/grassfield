pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "MemoLogic.js" as MemoLogic

// One memo (ADR-0051 D-5, docs/specs/memos.md MM1 to MM10): its strip (close box, first line while collapsed, collapse box),
// its styled text on the coloured paper, the resize grip, the in-memo Delete alert. Every change goes to the backend, which
// saves it after a short pause. Main.qml makes the windows and owns their list.
Window {
    id: memo

    // Set by Main.qml.
    required property var backend
    required property var manager
    required property string memoId
    property string colorName: "yellow"
    property string initialHtml: ""
    property bool collapsed: false
    property bool translucent: false
    // The memo's own height, kept while it is collapsed (the window is then the strip's height).
    property int expandedHeight: Tokens.memosWindowHeight
    // The registrar is there (Main.qml, kept up to date by src/main.cpp): the memo exports its menus.
    property bool globalMenu: false
    // ADR-0015 and ADR-0051 D-6: the window draws its own chrome; its xdg-toplevel tag is its memo tag (memo:<id>...), which
    // the compositor's rules read (no plugin titlebar, the stored position). Set once, before the window maps.
    property string gfChromeRole: ""
    // The Delete alert is up (Close on a memo with text).
    property bool confirmingClose: false
    // Main.qml is deleting it: the close goes through.
    property bool deleting: false
    property string firstLine: ""

    readonly property alias editor: textEdit
    readonly property bool keyLook: Appearance.looksKey(memo, memo.active)
    readonly property color paperColor: MemoLogic.paper(Tokens, memo.colorName)
    readonly property color stripColor: MemoLogic.strip(Tokens, memo.colorName)
    readonly property real paperOpacity: memo.translucent ? Tokens.memosTranslucentOpacity : 1
    // A height change that is the collapse itself, not the user's resize.
    property bool applyingHeight: false
    // The tag with the new size goes out once the window has committed its new constraints (the next frame).
    property bool sizeTagDue: false
    property string tagBeforeResize: ""
    // Set once the window is made: the sizes given at creation are the stored ones, not changes.
    property bool ready: false

    title: MemoLogic.title(memo.firstLine, qsTr("Memo"))
    color: "transparent"
    minimumWidth: Tokens.memosWindowMinWidth
    minimumHeight: memo.collapsed ? Tokens.memosStripHeight : Tokens.memosWindowMinHeight
    // Collapsed, the memo is its strip: it does not grow taller from the edges.
    maximumHeight: memo.collapsed ? Tokens.memosStripHeight : Tokens.memosWindowMaxSide
    visible: true

    onFrameSwapped: {
        if (!memo.sizeTagDue)
            return;
        memo.sizeTagDue = false;
        memo.backend.retag(memo, MemoLogic.sizedTag(memo.tagBeforeResize, memo.width, memo.height));
    }

    function plainText(): string {
        return textEdit.getText(0, textEdit.length);
    }

    function push(changes: var): void {
        memo.backend.update(memo.memoId, changes);
    }

    function setColor(name: string): void {
        const c = MemoLogic.validColor(name);
        if (c === memo.colorName)
            return;
        memo.colorName = c;
        memo.push({color: c});
    }

    function setCollapsed(on: bool): void {
        if (on === memo.collapsed)
            return;
        // The corner the memo has now, read before the change: Hyprland moves a window whose surface changes size.
        memo.tagBeforeResize = memo.backend.freshTagFor(memo.memoId);
        memo.applyingHeight = true;
        memo.collapsed = on;
        memo.height = MemoLogic.windowHeight(on, memo.expandedHeight, Tokens.memosStripHeight, Tokens.memosWindowMinHeight);
        memo.applyingHeight = false;
        // Wayland has no resize request for a floating window: the compositor's rule resizes it to the size on the tag.
        memo.sizeTagDue = true;
        if (!on)
            textEdit.forceActiveFocus();
        memo.push({collapsed: on});
    }

    function toggleCollapsed(): void {
        memo.setCollapsed(!memo.collapsed);
    }

    function toggleTranslucent(): void {
        memo.translucent = !memo.translucent;
        memo.push({translucent: memo.translucent});
    }

    // Close box, File > Close, Ctrl+W, the compositor's close: an empty memo goes at once, one with text asks first.
    function pushText(): void {
        const html = textEdit.text;
        memo.firstLine = memo.backend.firstLine(html);
        memo.push({html: html});
    }

    // The text still in the short pause goes to the backend now (a close, a save, the memo left; review of the memos slice:
    // text typed in the last 300 ms was lost on Quit, SIGTERM and a compositor close).
    function flush(): void {
        if (!textPush.running)
            return;
        textPush.stop();
        memo.pushText();
    }

    function requestClose(): void {
        memo.flush();
        if (!MemoLogic.closeNeedsConfirm(memo.plainText())) {
            memo.manager.deleteMemo(memo);
            return;
        }
        if (memo.collapsed)
            memo.setCollapsed(false);
        memo.confirmingClose = true;
        alert.forceActiveFocus();
    }

    function cancelClose(): void {
        memo.confirmingClose = false;
        textEdit.forceActiveFocus();
    }

    // Every paste is plain text (ADR-0051 D-4): rich text could carry remote images, which Qt Quick would load.
    function pastePlain(text: string): void {
        const end = memo.backend.formatter.insertPlain(textEdit.textDocument, textEdit.selectionStart, textEdit.selectionEnd, text);
        textEdit.cursorPosition = end;
    }

    function paste(): void {
        memo.pastePlain(memo.backend.clipboardText(false));
    }

    function bold(): void {
        memo.backend.formatter.toggleBold(textEdit.textDocument, textEdit.selectionStart, textEdit.selectionEnd);
    }

    function italic(): void {
        memo.backend.formatter.toggleItalic(textEdit.textDocument, textEdit.selectionStart, textEdit.selectionEnd);
    }

    function underline(): void {
        memo.backend.formatter.toggleUnderline(textEdit.textDocument, textEdit.selectionStart, textEdit.selectionEnd);
    }

    function resize(delta: int): void {
        memo.backend.formatter.changeSize(textEdit.textDocument, textEdit.selectionStart, textEdit.selectionEnd, delta, Tokens.memosTextSize,
                                          Tokens.memosTextSizeMin, Tokens.memosTextSizeMax);
    }

    function bigger(): void {
        memo.resize(Tokens.memosTextSizeStep);
    }

    function smaller(): void {
        memo.resize(-Tokens.memosTextSizeStep);
    }

    function toggleList(): void {
        memo.backend.formatter.toggleList(textEdit.textDocument, textEdit.selectionStart, textEdit.selectionEnd);
    }

    // A close the compositor asks for (the Dock's or the app menu's Quit closes every window, a key binding one) keeps the
    // memo: only the close box, Ctrl+W and File > Close delete (ADR-0051 D-5). The window goes; the memo comes back at the
    // next launch or activation.
    onClosing: close => {
        memo.flush();
        if (!memo.deleting)
            memo.manager.windowClosed(memo);
    }

    // A memo the user leaves is written at once (its text and its frame): a session that ends abruptly (the compositor gone,
    // so no Quit) loses nothing typed before the user moved on.
    onActiveChanged: {
        if (memo.active) {
            memo.manager.lastActive = memo;
            return;
        }
        memo.flush();
        memo.backend.saveNow();
    }

    onWidthChanged: {
        if (memo.ready)
            memo.push({width: memo.width});
    }
    onHeightChanged: {
        if (!memo.ready || memo.applyingHeight || !MemoLogic.keepsHeight(memo.collapsed, memo.height, Tokens.memosStripHeight))
            return;
        memo.expandedHeight = memo.height;
        memo.push({height: memo.height});
    }

    Component.onCompleted: {
        textEdit.text = memo.initialHtml;
        memo.firstLine = memo.backend.firstLine(memo.initialHtml);
        memo.ready = true;
        textEdit.forceActiveFocus();
    }

    Theme {
        backend: memo.backend
    }

    // Global menu (T1): its keys repeat the Shortcuts below; each Shortcut acts on activatedAmbiguously too (Preview's rule).
    Loader {
        active: memo.globalMenu
        sourceComponent: GlobalMenu {
            win: memo
        }
    }

    // The text's changes reach the backend after a short pause (the store adds its own debounce before writing).
    Timer {
        id: textPush
        interval: 300
        onTriggered: memo.pushText()
    }

    Shortcut {
        sequence: "Ctrl+N"
        onActivated: memo.manager.newMemo()
        onActivatedAmbiguously: memo.manager.newMemo()
    }
    Shortcut {
        sequence: "Ctrl+W"
        onActivated: memo.requestClose()
        onActivatedAmbiguously: memo.requestClose()
    }
    Shortcut {
        sequence: "Ctrl+Q"
        onActivated: Qt.quit()
        onActivatedAmbiguously: Qt.quit()
    }
    Shortcut {
        sequence: "Ctrl+B"
        enabled: !memo.collapsed
        onActivated: memo.bold()
        onActivatedAmbiguously: memo.bold()
    }
    Shortcut {
        sequence: "Ctrl+I"
        enabled: !memo.collapsed
        onActivated: memo.italic()
        onActivatedAmbiguously: memo.italic()
    }
    Shortcut {
        sequence: "Ctrl+U"
        enabled: !memo.collapsed
        onActivated: memo.underline()
        onActivatedAmbiguously: memo.underline()
    }
    Shortcut {
        sequences: ["Ctrl++", "Ctrl+="]
        enabled: !memo.collapsed
        onActivated: memo.bigger()
        onActivatedAmbiguously: memo.bigger()
    }
    Shortcut {
        sequence: "Ctrl+-"
        enabled: !memo.collapsed
        onActivated: memo.smaller()
        onActivatedAmbiguously: memo.smaller()
    }
    Shortcut {
        sequence: "Ctrl+Shift+7"
        enabled: !memo.collapsed
        onActivated: memo.toggleList()
        onActivatedAmbiguously: memo.toggleList()
    }
    Shortcut {
        sequence: "Ctrl+Alt+T"
        onActivated: memo.toggleTranslucent()
        onActivatedAmbiguously: memo.toggleTranslucent()
    }
    Shortcut {
        sequence: "Ctrl+Alt+C"
        onActivated: memo.toggleCollapsed()
        onActivatedAmbiguously: memo.toggleCollapsed()
    }
    Repeater {
        model: MemoLogic.colors

        Item {
            id: colorKey

            required property int index
            required property string modelData

            Shortcut {
                sequence: MemoLogic.colorShortcut(colorKey.index)
                onActivated: memo.setColor(colorKey.modelData)
                onActivatedAmbiguously: memo.setColor(colorKey.modelData)
            }
        }
    }

    Item {
        id: body
        anchors.fill: parent
        opacity: memo.paperOpacity

        Rectangle {
            anchors.fill: parent
            color: memo.paperColor
        }

        // The strip: drag to move, double-click to collapse; its boxes show while the memo is key or under the pointer.
        Rectangle {
            id: strip
            objectName: "memoStrip"
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
            }
            height: Tokens.memosStripHeight
            color: memo.stripColor

            readonly property bool showBoxes: memo.keyLook || stripHover.hovered

            HoverHandler {
                id: stripHover
            }

            DragHandler {
                target: null
                acceptedButtons: Qt.LeftButton
                onActiveChanged: {
                    if (active)
                        memo.startSystemMove();
                }
            }

            TapHandler {
                acceptedButtons: Qt.LeftButton
                onDoubleTapped: memo.toggleCollapsed()
            }

            MemoBox {
                id: closeBox
                objectName: "memoCloseBox"
                anchors {
                    left: parent.left
                    leftMargin: Tokens.memosBoxInset
                    verticalCenter: parent.verticalCenter
                }
                visible: strip.showBoxes
                accessibleName: qsTr("Close")
                onActivated: memo.requestClose()
            }

            Text {
                objectName: "memoCollapsedLine"
                anchors {
                    left: closeBox.right
                    right: collapseBox.left
                    leftMargin: Tokens.memosBoxInset
                    rightMargin: Tokens.memosBoxInset
                    verticalCenter: parent.verticalCenter
                }
                visible: memo.collapsed
                text: memo.firstLine
                textFormat: Text.PlainText
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                color: Tokens.memosInk
                opacity: Tokens.memosBoxOpacity
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.memosCollapsedTextSize
            }

            MemoBox {
                id: collapseBox
                objectName: "memoCollapseBox"
                anchors {
                    right: parent.right
                    rightMargin: Tokens.memosBoxInset
                    verticalCenter: parent.verticalCenter
                }
                visible: strip.showBoxes
                collapse: true
                accessibleName: memo.collapsed ? qsTr("Expand") : qsTr("Collapse")
                onActivated: memo.toggleCollapsed()
            }
        }

        Flickable {
            id: flick
            anchors {
                left: parent.left
                right: parent.right
                top: strip.bottom
                bottom: parent.bottom
                leftMargin: Tokens.memosTextMargin
                rightMargin: Tokens.memosTextMargin
                topMargin: Tokens.memosTextMargin
                bottomMargin: Tokens.memosTextMargin
            }
            visible: !memo.collapsed
            clip: true
            contentWidth: width
            contentHeight: textEdit.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            function ensureVisible(r: rect): void {
                if (contentY >= r.y)
                    contentY = r.y;
                else if (contentY + height <= r.y + r.height)
                    contentY = r.y + r.height - height;
            }

            TextEdit {
                id: textEdit
                objectName: "memoText"
                width: flick.width
                textFormat: TextEdit.RichText
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                persistentSelection: true
                color: Tokens.memosInk
                selectionColor: Appearance.highlight
                selectedTextColor: Appearance.highlightText
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.memosTextSize
                Accessible.name: qsTr("Memo text")
                onTextChanged: textPush.restart()
                onCursorRectangleChanged: flick.ensureVisible(cursorRectangle)

                // Paste (Ctrl+V, Shift+Insert) is plain text, before the TextEdit's own rich paste.
                Keys.onPressed: event => {
                    if (event.matches(StandardKey.Paste)) {
                        memo.paste();
                        event.accepted = true;
                    }
                }
            }
        }

        // A drop is plain text too, at the place it lands.
        DropArea {
            anchors.fill: flick
            enabled: !memo.collapsed && !memo.confirmingClose
            keys: ["text/plain"]
            onDropped: drop => {
                const p = textEdit.positionAt(drop.x + flick.contentX, drop.y + flick.contentY);
                textEdit.select(p, p);
                memo.pastePlain(drop.text);
                drop.accept(Qt.CopyAction);
            }
        }

        // The middle button pastes the primary selection on Linux: plain text too.
        MouseArea {
            anchors.fill: flick
            enabled: !memo.collapsed
            acceptedButtons: Qt.MiddleButton
            onClicked: mouse => {
                const p = textEdit.positionAt(mouse.x + flick.contentX, mouse.y + flick.contentY);
                textEdit.select(p, p);
                memo.pastePlain(memo.backend.clipboardText(true));
            }
        }

        // The resize grip, bottom right (macOS's notes have one).
        Canvas {
            id: grip
            objectName: "memoGrip"
            anchors {
                right: parent.right
                bottom: parent.bottom
            }
            width: Tokens.memosGripSize
            height: Tokens.memosGripSize
            visible: !memo.collapsed
            opacity: Tokens.memosBoxOpacity
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                ctx.strokeStyle = Tokens.memosInk;
                ctx.lineWidth = Tokens.memosBoxStroke;
                for (let i = 1; i <= 3; i++) {
                    const d = i * Tokens.memosGripLineGap;
                    ctx.beginPath();
                    ctx.moveTo(width - d, height);
                    ctx.lineTo(width, height - d);
                    ctx.stroke();
                }
            }

            DragHandler {
                target: null
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.SizeFDiagCursor
                onActiveChanged: {
                    if (active)
                        memo.startSystemResize(Qt.RightEdge | Qt.BottomEdge);
                }
            }
        }
    }

    // The Delete alert, inside the memo (a memo is too small for a sheet of its own).
    Rectangle {
        id: alert
        objectName: "memoDeleteAlert"
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            bottom: parent.bottom
            topMargin: Tokens.memosStripHeight
        }
        visible: memo.confirmingClose
        color: Appearance.withAlpha(memo.paperColor, Tokens.memosAlertFillOpacity)
        focus: memo.confirmingClose
        Keys.onEscapePressed: memo.cancelClose()
        Keys.onReturnPressed: memo.manager.deleteMemo(memo)
        Keys.onEnterPressed: memo.manager.deleteMemo(memo)

        // The text below is not reachable through the alert.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
        }

        Column {
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                margins: Tokens.memosTextMargin
            }
            spacing: Tokens.spacingSm

            Text {
                width: parent.width
                text: qsTr("Delete this memo?")
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                color: Tokens.memosInk
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Tokens.typographyTitleWeight
            }

            Text {
                width: parent.width
                text: qsTr("Its text can't be recovered.")
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                color: Tokens.memosInk
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Tokens.spacingSm

                Button {
                    objectName: "memoCancelDelete"
                    push: true
                    // The paper is light in both appearances: the label is the memo's ink, not the system's (white in dark).
                    labelColor: Tokens.memosInk
                    fillColor: Appearance.withAlpha(Tokens.memosInk, Tokens.memosAlertButtonFillOpacity)
                    text: qsTr("Cancel")
                    onClicked: memo.cancelClose()
                }

                Button {
                    objectName: "memoConfirmDelete"
                    push: true
                    primary: true
                    text: qsTr("Delete")
                    onClicked: memo.manager.deleteMemo(memo)
                }
            }
        }
    }
}
