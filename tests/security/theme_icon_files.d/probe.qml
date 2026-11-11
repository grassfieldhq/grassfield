pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.I18n
import Grassfield.Ui
import qs.notifications
import qs.services

// Probe of tests/security/theme_icon_files.sh, parts 1 and 2 (integrator decisions after the reviews of 5ee6240 and
// 423766f: Qt never reads a user-writable icon file; the shell only decodes images it produced itself). The script
// planted files for the theme icon name "evil" (PROBE_KIND says which) in the user's icon folders and a regular user icon
// "ctl", then may have set QS_ICON_THEME to a user theme whose index.theme is hostile. As a notification would, the probe
// takes "evil" in as an app icon, asks Qt directly (Quickshell.hasThemeIcon on the GUI thread: Qt must not read the
// user's theme files), waits for ThemeIcons' answer (the PNG it made, or a refusal),
// gives the notification's icon source and the polkit sheet's to Images (the sheets run in the security process since
// ADR-0041 S3 and look a name up by SheetHost.themeIcon: the system theme only, never a copy), then
// loads "ctl" (a private copy too): that Image only becomes Ready when the image loader never stalled, and the probe
// exits only when the GUI thread never blocked. Kind "swap" starts from a regular evil.png, shown as a copy, then makes
// it a FIFO and has a new notification name it: the new copy is refused. Prints one "probe:" line and exits.
ShellRoot {
    id: root

    readonly property string kind: Quickshell.env("PROBE_KIND")
    readonly property string userIcon: Quickshell.env("PROBE_USER_ICON")
    property string phase: "copy"
    property int waited: 0
    property string state: ""
    property string notifSource: ""
    property string polkitSource: ""
    property string before: ""
    property bool has: false

    function stateOf(key: string): string {
        const e = ThemeIcons.copies[key];
        return e === undefined ? "" : e.state;
    }

    Component.onCompleted: {
        root.has = Quickshell.hasThemeIcon("evil");
        Notifications.checkedAppIcon("evil", "Probe");
        ThemeIcons.source("ctl");
        poll.start();
    }

    Process {
        id: swapper
        command: ["sh", "-c", "rm -f \"$1\" && mkfifo \"$1\"", "sh", root.userIcon]
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            Notifications.checkedAppIcon("evil", "Probe"); // a new notification naming it
            root.phase = "copy";
            root.waited = 0;
            poll.start();
        }
    }

    FloatingWindow {
        visible: true
        implicitWidth: 96
        implicitHeight: 32

        Image {
            id: viaNotification
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(256, 256)
        }

        Image {
            id: viaPolkit
            x: 32
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(128, 128)
        }

        Image {
            id: control
            x: 64
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(64, 64)
        }
    }

    Timer {
        id: poll
        interval: 100
        repeat: true
        onTriggered: {
            root.waited += interval;
            if (root.phase === "copy") {
                // A new request keeps the current copy shown until the helper answers: wait for it to be idle too.
                const s = root.stateOf("name:evil");
                const busy = ThemeIcons.queue.length > 0 || ThemeIcons.batch.length > 0 || ThemeIcons.activeRun !== null;
                if ((s === "" || s === "pending" || busy) && root.waited < 15000)
                    return;
                if (root.kind === "swap" && root.before === "") {
                    root.before = s + ":" + (Notifications.iconSource("", "evil") !== "" ? "shown" : "hidden");
                    stop();
                    swapper.running = true;
                    return;
                }
                root.state = s;
                root.notifSource = Notifications.iconSource("", "evil");
                // SheetHost.themeIcon, the same expression (theme_icon_files.sh pins it there).
                const safe = NotificationPrefs.safeIconName("evil");
                root.polkitSource = safe !== "" && Quickshell.hasThemeIcon(safe) ? Quickshell.iconPath(safe) : "";
                viaNotification.source = root.notifSource;
                viaPolkit.source = root.polkitSource;
                root.phase = "control";
                root.waited = 0;
            } else if (root.phase === "control") {
                // At least a second after "evil" was handed to the loader, so a stalled read has started.
                const c = ThemeIcons.source("ctl");
                if ((c === "" || root.waited < 1000) && root.waited < 15000)
                    return;
                control.source = c;
                root.phase = "loaded";
                root.waited = 0;
            } else if (root.phase === "loaded") {
                if (control.status !== Image.Ready && root.waited < 5000)
                    return;
                stop();
                const copy = src => src === "" ? "none" : (src.indexOf("/grassfield-icons-") > 0 ? "copy" : src);
                console.log("probe: kind=" + root.kind + " has=" + root.has + " before=" + root.before + " state=" + root.state + " notif=" + copy(root.notifSource)
                    + " polkit=" + copy(root.polkitSource) + " evil=" + viaNotification.status + " ctl=" + control.status);
                Qt.exit(0);
            }
        }
    }
}
