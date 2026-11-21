pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Keyboard.js" as Keyboard
import "Setups.js" as Setups

// Privacy & Security > Disk Encryption > Change Password… (ADR-0045 OC-8, OC-0.7), as macOS asks for a password change: the
// current password, the new one, and the new one again; Change Password acts once they are typed and the two new ones match
// (Setups.passwordsReady). UDisks2 changes it on the start-up disk's LUKS device, which it finds itself (systembus.h
// disk.passphrase: the page names no device); it asks polkit first, so Grassfield's polkit sheet may come up over this one.
// The passwords live only in the three fields and in the one request: the request is built when Change Password is
// pressed and the fields are emptied right after, and on Cancel, Esc and success; nothing logs them (Backend.busAct logs the
// action's name only). A wrong current password keeps the sheet open with the service's reason and empty fields; no answer in
// time says the password may have changed (security review of ADR-0045, L-1). The sheet names the keyboard layout the password is
// typed with when the computer starts (the console's, Setups.startupLayout) and warns when the input source in use is another
// (L-2): a password chosen in another layout may not be typeable at start-up.
Sheet {
    id: root

    required property var system
    required property var backend

    readonly property string tag: "disk.act"
    readonly property bool busy: (root.backend.pendingActions ?? {})[root.tag] !== undefined
    // Read when the sheet opens: the start-up layout ({keymap, layout, variant}), the input source in use (the first of
    // Settings > Keyboard's, else the session's), and xkb's names of the layouts.
    property var startup: Setups.startupLayout("")
    property var inUse: null
    property var layoutNames: ({})
    readonly property bool layoutDiffers: Setups.layoutDiffers(root.startup, root.inUse)

    title: qsTr("Change the start-up disk's password")
    message: qsTr("This password unlocks the start-up disk when the computer starts. Other passwords of the disk keep working.")
    confirmText: qsTr("Change Password")
    confirmEnabled: !root.busy && root.form !== null && Setups.passwordsReady(root.form.currentField.text, root.form.newField.text, root.form.verifyField.text)
    holdInput: root.busy
    // The request goes when the button is pressed; the answer closes the sheet or shows why (below).
    confirmHandler: () => {
        const form = root.form;
        if (form === null)
            return false;
        const started = root.system.act("disk password", {op: "disk.passphrase", old: form.currentField.text, new: form.newField.text}, root.tag);
        root.clearFields();
        if (!started)
            return root.system.dev ? qsTr("Not applied in a dev session.") : qsTr("The password cannot be changed now.");
        return false;
    }

    // The three fields, once the sheet was first opened (null before: nothing to clear).
    readonly property Form form: root.bodyItem as Form

    function clearFields(): void {
        if (root.form === null)
            return;
        root.form.currentField.text = "";
        root.form.newField.text = "";
        root.form.verifyField.text = "";
    }

    function openSheet(): void {
        root.clearFields();
        const vconsole = root.backend.readText("/etc/vconsole.conf").text;
        root.startup = Setups.startupLayout(vconsole);
        const chosen = Keyboard.parse(root.backend.readText(root.backend.configFile.replace(/[^/]*$/, "keyboard.lua")).text);
        root.inUse = (chosen.sources ?? Keyboard.sessionSources(vconsole))[0] ?? null;
        root.layoutNames = Keyboard.parseLayouts(root.backend.readText("/usr/share/X11/xkb/rules/base.lst").text).names;
        root.open();
        root.form?.currentField.forceActiveFocus();
    }

    // "French", or "French (fr-latin9)" with the console's own keymap name.
    function startupName(): string {
        const name = Keyboard.sourceName(root.startup, root.layoutNames);
        return root.startup.keymap !== "" && root.startup.keymap !== name ? qsTr("%1 (%2)", "keyboard layout, console keymap").arg(name).arg(root.startup.keymap) : name;
    }

    onCanceled: root.clearFields()
    onShownChanged: {
        if (!root.shown)
            root.clearFields();
    }

    Connections {
        target: root.backend
        // Only while it waits for an answer: a Backend answer is not handed to every row and sheet of the window (the audit's notes).
        enabled: root.shown

        function onFailed(tag: string, reason: string): void {
            if (tag !== root.tag || !root.shown)
                return;
            // No answer in time: UDisks2 may have changed it meanwhile (systembus.cpp passphraseFailure; the jobs' own limit).
            if (reason === qsTranslate("SystemBus", "the disk did not answer in time") || reason === qsTranslate("SystemBus", "timed out"))
                root.errorText = qsTr("The disk didn't answer in time. The password may have changed: try the new one first.");
            else
                root.errorText = reason !== "" ? qsTr("The password was not changed: %1.").arg(reason) : qsTr("The password was not changed.");
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === root.tag && root.shown && ok)
                root.close();
        }
    }

    // The body: the three fields and the notes, built the first time the sheet opens and kept (Sheet.bodyComponent).
    component Form: Column {
        readonly property alias currentField: current
        readonly property alias newField: next
        readonly property alias verifyField: verify

        spacing: Tokens.spacingMd

        TextField {
            id: current
            width: parent.width
            placeholderText: qsTr("Current password")
            echoMode: TextInput.Password
            inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
            accessibleName: qsTr("Current password")
            onTextChanged: root.errorText = ""
        }

        TextField {
            id: next
            width: parent.width
            placeholderText: qsTr("New password")
            echoMode: TextInput.Password
            inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
            accessibleName: qsTr("New password")
        }

        TextField {
            id: verify
            width: parent.width
            placeholderText: qsTr("Verify")
            echoMode: TextInput.Password
            inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
            accessibleName: qsTr("Verify the new password")
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.Wrap
            text: root.layoutDiffers && root.inUse !== null
                ? qsTr("When the computer starts, this password is typed with the start-up keyboard layout, %1, not with %2, the one in use now: choose a password that types the same with both.").arg(root.startupName()).arg(Keyboard.sourceName(root.inUse, root.layoutNames))
                : qsTr("When the computer starts, this password is typed with the start-up keyboard layout, %1.").arg(root.startupName())
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }

        Text {
            textFormat: Text.PlainText
            visible: verify.text !== "" && next.text !== verify.text
            width: parent.width
            wrapMode: Text.Wrap
            text: qsTr("The new passwords do not match.")
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }
    }

    bodyComponent: Component {
        Form {}
    }
}
