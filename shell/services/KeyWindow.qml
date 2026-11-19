pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.lib
import qs.platform
import "KeyWindowFile.js" as KeyWindowFile
import "PopupKinds.js" as PopupKinds

// The window the Grassfield apps draw as key (ADR-0039 step 17; the integrator's macOS decision on #88): the focused window,
// and, while a shell menu or the Control Center holds the keyboard, the window that was key when it opened. Hyprland withdraws
// that window's activation meanwhile (Qt follows it), so the apps read this instead: the shell writes the client of that window
// to a runtime file (KeyWindowFile.js has the format, the location and the rule; apps/keywindow.h reads it). Only another
// window taking the focus makes the window inactive.
Singleton {
    id: root

    // The focused window's client; nobody while the desktop holds the keyboard.
    readonly property var front: DesktopState.holdsKeyboard ? KeyWindowFile.none : KeyWindowFile.client(Compositor.pidOf(Compositor.focusedToplevel), Compositor.focusedAppId)
    // The shell surfaces holding the keyboard (FocusReturn's holders).
    readonly property var holders: Object.keys(FocusReturn.holders)
    // The opener, whether the holders keep the look, and the moment after they closed (KeyWindowFile.start has the rule).
    property var latch: KeyWindowFile.start

    onHoldersChanged: root.latch = KeyWindowFile.holdersChanged(root.latch, root.holders, root.front, Popups.kind, PopupKinds.kinds, PopupKinds.dialogs)
    onFrontChanged: root.latch = KeyWindowFile.frontChanged(root.latch, root.front, false)

    Connections {
        target: Popups

        function onKindChanged(): void {
            root.latch = KeyWindowFile.kindChanged(root.latch, root.holders, Popups.kind, PopupKinds.kinds, PopupKinds.dialogs);
        }
    }

    // The return's bound: focusReturn.menuActionWaitMs, which a menu's chosen item waits for that same return.
    Timer {
        interval: Tokens.focusReturnMenuActionWaitMs
        running: root.latch.returning
        onTriggered: root.latch = KeyWindowFile.frontChanged(root.latch, root.front, true)
    }

    readonly property var key: KeyWindowFile.keyClient({
        locked: FocusReturn.locked,
        holders: root.holders,
        keeps: root.latch.kept,
        front: root.front,
        opener: root.latch.opener,
        returning: root.latch.returning
    })
    readonly property string text: KeyWindowFile.payload(root.key)
    readonly property string path: KeyWindowFile.path(Mode.stateHome, Quickshell.env("XDG_RUNTIME_DIR"))

    // Written once per event-loop turn (a surface opening changes several of the values above in one turn), synchronously
    // (blockWrites): the app reads it before the compositor's deactivation, which waits for the surface to map, reaches it.
    function write(): void {
        if (root.path === "" || !root.folderReady)
            return;
        if (keyFile.path !== root.path)
            keyFile.path = root.path;
        keyFile.setText(root.text);
    }

    onTextChanged: Qt.callLater(root.write)

    FileView {
        id: keyFile
        printErrors: false
        atomicWrites: true
        blockWrites: true
    }

    // $XDG_RUNTIME_DIR/grassfield is made private (0700) before the first write: FileView would make it with the umask's mode
    // if the shell came first. Nothing to make in a dev session.
    readonly property string folder: KeyWindowFile.runtimeFolder(Mode.stateHome, Quickshell.env("XDG_RUNTIME_DIR"))
    property bool folderReady: root.folder === ""
    onFolderReadyChanged: root.write()

    Process {
        id: makeFolder
        command: ["mkdir", "-m", "0700", "-p", root.folder]
        onRunningChanged: {
            if (!running)
                root.folderReady = true;
        }
    }

    Component.onCompleted: {
        if (root.folder !== "")
            makeFolder.running = true;
        root.write();
    }
}
