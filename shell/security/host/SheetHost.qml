pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.security
import qs.security.polkit
import qs.security.secret
import "../../lib/RunMode.js" as RunMode

// The polkit sheet and the secret sheets of the security process (ADR-0041 step 1, S3; ADR-0035 D-9: one queue for every
// secret sheet and the polkit sheet, so they live together, in the polkit agent's process): the session's one polkit
// authentication agent (AuthAgent), the secret sheets fed by grassfield-prompter (SecretAgent: gcr's prompts,
// NetworkManager's secrets, KIO's passwords, Bluetooth pairing) and their one queue (SheetQueue). Created at run time by
// SecurityHost.qml only, never declared (a module that cannot be loaded leaves the lock running); never in the UI.
// The sheets read the session from SheetSession, which the host binds from this process's lock and idle; what the UI knows
// of them is `authorizing` and `securityKeyboard` below, which the host publishes with the lock state (booleans only).
Scope {
    id: root

    // A sheet is open, shown or held (the UI's clipboard history records nothing meanwhile and 2 s after, ADR-0034 Q11; its
    // menus close; its tiling popover waits).
    readonly property bool authorizing: authAgent.requestActive || secretAgent.requestActive
    // A sheet or its key sink may hold the keyboard (the UI's capture toolbar maps nothing as Exclusive meanwhile; opus
    // re-review 2 of the ADR-0045 security fixes, MINOR-3).
    readonly property bool securityKeyboard: authAgent.queuePresent || secretAgent.requestActive || secretAgent.sinkingKeys

    // A dev session (the one dev rule, ADR-0019): only there is the prompter's test socket read (dev plumbing).
    readonly property bool dev: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))

    // The URL of a plain theme icon name for a sheet: the system theme's icon only (Grassfield.I18n, imported by the host
    // before any lookup, keeps Qt's icon search to directories the user cannot change, ui/i18n/iconsearchpaths.h); "" otherwise
    // (the sheet's own icon). The UI's ThemeIcons, which also copies icons found in the user's folders, belongs to the UI and
    // empties a directory of its own: never here.
    function themeIcon(name: string): string {
        const safe = NotificationPrefs.safeIconName(name);
        return safe !== "" && Quickshell.hasThemeIcon(safe) ? Quickshell.iconPath(safe) : "";
    }

    // The one queue of the polkit sheet and the secret sheets (ADR-0035 D-9, master-prompt R12): one sheet on screen at a
    // time, in arrival order; no sheet takes the keyboard from another.
    SheetQueue {
        id: sheetQueue
        polkitPresent: authAgent.queuePresent
    }
    // The session's one polkit authentication agent (ADR-0010; ADR-0041 S3).
    AuthAgent {
        id: authAgent
        queue: sheetQueue
        iconSource: name => root.themeIcon(name)
    }
    // Password prompts of gcr's callers, NetworkManager's secrets, KIO's passwords and Bluetooth pairing through
    // grassfield-prompter (ADR-0035 D-9, D-11, D-12). In a dev session it connects only to the test socket
    // GRASSFIELD_PROMPTER_SOCKET names (ADR-0019 dev plumbing; "" in a real session).
    SecretAgent {
        id: secretAgent
        queue: sheetQueue
        devSocket: root.dev ? (Quickshell.env("GRASSFIELD_PROMPTER_SOCKET") || "") : ""
        shellVersion: versionFile.loaded ? (versionFile.text().trim() || "unknown") : "unknown"
        iconSource: name => root.themeIcon(name)
    }
    // The package's version, for the prompter bridge's log (read as the UI's SystemInfo reads it).
    FileView {
        id: versionFile
        path: Quickshell.shellPath("../VERSION")
        blockLoading: true
        printErrors: false
    }
}
