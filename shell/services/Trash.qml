pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "AppLaunch.js" as AppLaunch

// Trash state for the Dock: empty or not, from ~/.local/share/Trash/files (in a dev session the isolated
// trash under .dev/apps-home, where the shell's own trash actions put files; ADR-0011).
// Event-driven: `gio monitor` reports changes; a check also runs at start and on demand.
// The only modification is emptyNow(), called after the Dock menu's confirmation.
Singleton {
    id: root

    readonly property string filesPath: {
        if (Apps.devSession)
            return Apps.appsHome + "/data/Trash/files";
        const xdg = Quickshell.env("XDG_DATA_HOME");
        return (xdg ? xdg : Quickshell.env("HOME") + "/.local/share") + "/Trash/files";
    }

    property bool empty: true

    function refresh(): void {
        check.ask();
        if (!monitor.running)
            monitor.running = true;
    }

    // Open the trash in the default file manager (gio resolves trash:/// itself). A dev session never opens
    // trash:///: it is served by the owner's session and would show (and empty) the real trash. It opens the
    // isolated trash folder as a plain directory instead, and the dev open policy starts Grassfield Files on it
    // (Apps.openDetached; never the default handler, ADR-0011).
    function open(): void {
        Apps.openDetached(["gio", "open", Apps.devSession ? root.filesPath : "trash:///"]);
    }

    // Empty Trash (Dock Trash menu; only after its confirmation). The one place that deletes from the trash: a real session asks gio,
    // a dev session removes the contents of the isolated trash only (AppLaunch.emptyTrashArgv, ADR-0011), never the owner's.
    function emptyNow(): void {
        const argv = AppLaunch.emptyTrashArgv(Apps.devSession, Apps.appsHome);
        if (argv === null) {
            console.warn("grassfield-shell: empty trash refused, no isolated trash directory");
            return;
        }
        Quickshell.execDetached(argv);
        Sounds.play("trash-empty");
        refreshTimer.restart();
    }

    // The monitor reports the deletions; this covers a trash directory that did not exist when the monitor started.
    Timer {
        id: refreshTimer
        interval: 800
        onTriggered: root.refresh()
    }

    Component.onCompleted: refresh()

    Process {
        id: check
        // Set when the trash changed while the check was running (starting it then does nothing): run it once more.
        property bool again: false

        function ask(): void {
            if (check.running)
                check.again = true;
            else
                check.running = true;
        }

        command: ["find", root.filesPath, "-mindepth", "1", "-maxdepth", "1", "-print", "-quit"]
        stdout: StdioCollector {
            // A missing directory prints nothing on stdout: that is an empty trash.
            onStreamFinished: root.empty = text.trim() === ""
        }
        onRunningChanged: {
            if (!running && again) {
                again = false;
                running = true;
            }
        }
    }

    Process {
        id: monitor
        // pdeathsig: the monitor dies with the shell even on SIGKILL.
        command: ["setpriv", "--pdeathsig", "KILL", "--", "gio", "monitor", root.filesPath]
        stdout: SplitParser {
            onRead: check.ask()
        }
    }
}
