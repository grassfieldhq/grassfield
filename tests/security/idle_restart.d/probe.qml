import QtQuick
import Quickshell
import qs.security.idle
import qs.security.lock

// SS-09 (security-session audit, round 2): the REAL Idle (shell/security/idle/Idle.qml, with the REAL Lock singleton) started
// next to the idle record a previous security process left (tests/security/idle_restart.sh writes it). Runs for
// IDLE_RESTART_SECONDS, then prints "idle-restart: done <lock state>" and exits; the script reads the journal lines (the
// lock request, "due in", nothing) and the record afterwards. A dev session: the sleep inhibitor is not taken, logind is not
// followed; no PAM file here, so a lock request is refused by Lock and logged, which is what the script looks for.
ShellRoot {
    id: root

    settings.watchFiles: false

    Idle {
        id: idle
    }

    Timer {
        interval: Number(Quickshell.env("IDLE_RESTART_SECONDS") || "9") * 1000
        running: true
        onTriggered: {
            console.log("idle-restart: done " + Lock.lockState + " decided " + idle.inheritedDecided);
            Qt.exit(0);
        }
    }
}
