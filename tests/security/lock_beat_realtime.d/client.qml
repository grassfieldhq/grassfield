import QtQuick
import Quickshell
import qs.services

// The REAL LockClient (shell/services/LockClient.qml) in a process that draws late frames (Stall.qml). The harness
// (tests/security/lock_beat_realtime.sh) writes beats from outside, then stops; this prints every change of `stale` with the
// wall time (ms since the epoch) at which this process saw it.
ShellRoot {
    settings.watchFiles: false

    Connections {
        target: LockClient
        function onStaleChanged(): void {
            console.log("lock-beat: stale " + LockClient.stale + " at " + Date.now());
        }
    }

    Stall {}
}
