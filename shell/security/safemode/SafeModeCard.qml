pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The safe-mode alert (ADR-0041 step 1, S4), the content of SafeModeNotice's window: drawn with Grassfield.Ui and its tokens
// only, in the shape of the UI's alerts (shell/overlay/Dialog.qml, macOS 27: radius.alert, the subject's symbol in a 64 frame
// at the top left, a bold title and the message left-aligned under it, capsule buttons of one width filling the row, stacked
// with the default on top when they do not fit). The symbol is the caution triangle, the subject's symbol (ADR-0040 IQ-B1 B:
// dialogs never show the Grassfield mark). Its text is fixed: nothing it shows comes from a file, a process or another
// application.
//
// It decides nothing: a press of a button (or Return, the default button's key) emits tryAgain() or logOut(), and the
// controller (SafeMode.qml) runs the action only when the notice is on screen and nothing runs already. Esc does nothing:
// the alert has no Cancel (closing it would leave the user with no desktop and no way back), and never logs out.
FocusScope {
    id: root

    // The action under way ("" | "tryAgain" | "logOut") and the one that did not finish ("" | "tryAgain" | "logOutOpen", apps
    // still open | "logOut", the session not ended: SafeModeModel.failureOf), set by the controller.
    property string running: ""
    property string failure: ""
    readonly property bool busy: root.running !== ""

    readonly property string title: qsTr("Grassfield is running in safe mode")
    readonly property string message: qsTr("Its desktop stopped working several times in a row and was turned off. Your open apps keep running.")
    // One line under the message while an action runs, or after one that did not finish.
    readonly property string statusText: {
        if (root.running === "tryAgain")
            return qsTr("Restarting the desktop…");
        if (root.running === "logOut")
            return qsTr("Logging out…");
        if (root.failure === "tryAgain")
            return qsTr("The desktop couldn’t be restarted. Try again, or log out.");
        if (root.failure === "logOutOpen")
            return qsTr("Some apps are still open, so you weren’t logged out. Save your work and quit them, then log out.");
        if (root.failure === "logOut")
            return qsTr("The session couldn’t be ended. Log out again in a moment.");
        return "";
    }

    signal tryAgain
    signal logOut

    // An alert's icon and text sit 24 from its edges, its buttons 16 (Dialog.qml).
    readonly property real pad: Tokens.spacingLg
    readonly property real textInset: Tokens.panelAlertTextInset
    readonly property Item surface: material

    width: Tokens.panelAlertWidth
    height: root.pad + column.implicitHeight + Tokens.spacingLg + buttonRow.height + root.pad
    Accessible.role: Accessible.Dialog
    Accessible.name: root.title
    Accessible.description: root.message

    // The keyboard starts on the default button, and comes back to it after an action that did not finish (a disabled
    // button loses the focus while the action runs).
    function takeFocus(): void {
        if (!root.busy)
            tryAgainButton.forceActiveFocus();
    }
    onBusyChanged: if (!root.busy)
        Qt.callLater(root.takeFocus)

    // Return and Enter are Try Again wherever the focus is in the alert, unless Tab moved it to Log Out (a focused button
    // takes its own activation keys first, as in every Grassfield alert). A Return held down on the alert answers nothing; on
    // a focused button its repeats reach the button, and the controller refuses all but the first (an action under way
    // refuses another; nothing acts in the first SafeModeModel.GUARD_MS after the alert appears). Esc is swallowed.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (!event.isAutoRepeat)
                root.tryAgain();
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape) {
            event.accepted = true;
        }
    }

    Material {
        id: material
        glassClass: "menu"
        anchors.fill: parent
        radius: Tokens.radiusAlert
    }

    Column {
        id: column
        x: root.textInset
        y: root.pad
        width: root.width - 2 * root.textInset
        spacing: Tokens.spacingMd

        Item {
            width: Tokens.panelAlertIconFrame
            height: Tokens.panelAlertIconFrame

            Icon {
                objectName: "safeModeSymbol"
                anchors.centerIn: parent
                size: Tokens.panelAlertIconGlyph
                name: "exclamationmark-triangle"
                // The text colour, as the polkit sheet's lock: the security modules read no accent glass (gate A2's rule).
                color: Appearance.colors.text
                Accessible.ignored: true
            }
        }

        Text {
            objectName: "safeModeTitle"
            textFormat: Text.PlainText
            width: parent.width
            text: root.title
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographyMenuBoldWeight
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Text {
            objectName: "safeModeMessage"
            textFormat: Text.PlainText
            width: parent.width
            text: root.message
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographySmallWeight
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Text {
            objectName: "safeModeStatus"
            textFormat: Text.PlainText
            width: parent.width
            text: root.statusText
            visible: text !== ""
            color: root.failure !== "" && !root.busy ? Appearance.colors.danger : Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }
    }

    // Two capsules of one width filling the row; stacked full width, Try Again on top, when the wider label does not fit in
    // half the row (French). Laid out by hand, as Dialog.qml lays out its buttons.
    Item {
        id: buttonRow

        readonly property real room: root.width - 2 * root.pad
        readonly property real gap: Tokens.controlAlertButtonGap
        readonly property real widest: Math.max(logOutButton.implicitWidth, tryAgainButton.implicitWidth)
        readonly property bool stacked: 2 * buttonRow.widest + buttonRow.gap > buttonRow.room
        readonly property real buttonWidth: buttonRow.stacked ? buttonRow.room : (buttonRow.room - buttonRow.gap) / 2

        x: root.pad
        y: root.pad + column.implicitHeight + Tokens.spacingLg
        width: buttonRow.room
        height: buttonRow.stacked ? 2 * tryAgainButton.height + buttonRow.gap : tryAgainButton.height

        Button {
            id: logOutButton
            objectName: "safeModeLogOut"
            capsule: true
            text: qsTr("Log Out")
            enabled: !root.busy
            width: buttonRow.buttonWidth
            x: 0
            y: buttonRow.stacked ? tryAgainButton.height + buttonRow.gap : 0
            onClicked: root.logOut()
        }

        Button {
            id: tryAgainButton
            objectName: "safeModeTryAgain"
            capsule: true
            primary: true
            text: qsTr("Try Again")
            enabled: !root.busy
            width: buttonRow.buttonWidth
            x: buttonRow.stacked ? 0 : buttonRow.buttonWidth + buttonRow.gap
            y: 0
            onClicked: root.tryAgain()
        }
    }
}
