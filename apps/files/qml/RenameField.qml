import QtQuick
import Grassfield.Ui

// Inline name editor. Opens with the name selected up to its extension (folders: the whole name).
// Commits only on an explicit action, as the Finder (audit F15): Return, Tab, or a click elsewhere in the window (the keyboard
// moves to another item of the window while it is active). Esc cancels. The window losing its activation (another app, a
// shell menu) commits nothing: the field stays, and has the keyboard again when the window comes back. A field taken out of
// the window (its row scrolled out of the view, the folder changed) cancels: a half-typed name is never committed.
Rectangle {
    id: root

    property string originalName: ""
    property int baseLength: originalName.length
    property int horizontalAlignment: TextInput.AlignLeft
    property bool done: false

    signal committed(string name)
    signal canceled

    implicitHeight: input.implicitHeight + 2 * Tokens.spacingXs / 2
    radius: Tokens.radiusControl / 2
    color: Appearance.windowFill
    border.width: Tokens.controlFocusOutline
    border.color: Appearance.focusRingColor

    function finish(commit: bool): void {
        if (root.done)
            return;
        root.done = true;
        if (commit)
            root.committed(input.text);
        else
            root.canceled();
    }

    Timer {
        id: settle
        interval: 0
        onTriggered: {
            if (input.activeFocus || root.done)
                return;
            if (!input.Window.window || !root.visible || root.parent === null)
                root.finish(false); // out of the window
            else if (input.Window.active)
                root.finish(true); // the keyboard went to another item: a click elsewhere
            // else the window was deactivated: nothing ends, the keyboard comes back with it
        }
    }

    TextInput {
        id: input
        TextCursor {}
        anchors.fill: parent
        anchors.leftMargin: Tokens.spacingXs
        anchors.rightMargin: Tokens.spacingXs
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: root.horizontalAlignment
        text: root.originalName
        clip: true
        focus: true
        selectByMouse: true
        color: Appearance.colors.text
        selectionColor: Appearance.highlight
        selectedTextColor: Appearance.highlightText
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.filesIconLabelSize
        Accessible.role: Accessible.EditableText
        Accessible.name: qsTr("Name")

        Component.onCompleted: {
            input.forceActiveFocus();
            input.select(0, Math.min(root.baseLength, input.text.length));
        }
        // Decided a turn later: a field taken out of the window loses the keyboard while it still names the window.
        onActiveFocusChanged: if (!input.activeFocus && !root.done) settle.restart()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.finish(true);
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                root.finish(false);
                event.accepted = true;
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.finish(true);
                event.accepted = true;
            }
        }
    }
}
