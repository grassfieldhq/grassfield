import QtQuick
import Quickshell
import qs.security.lock

// The REAL LockPublisher (shell/security/lock/LockPublisher.qml) in a process that draws late frames (Stall.qml): the
// harness (tests/security/lock_beat_realtime.sh) reads the state file from outside and measures the real time between beats.
ShellRoot {
    settings.watchFiles: false

    LockPublisher {
        id: publisher
        state: "unlocked"
        Component.onCompleted: publisher.start()
    }

    Stall {}
}
