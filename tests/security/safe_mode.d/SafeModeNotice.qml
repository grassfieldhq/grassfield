import QtQuick
import Quickshell

// Stand-in for shell/security/safemode/SafeModeNotice.qml in tests/security/safe_mode.sh: the same properties and signals,
// no window (offscreen has no layer-shell backend). The probe reads whether the controller made it and emits its signals as
// the alert's buttons would.
Scope {
    property string running: ""
    property string failure: ""

    signal tryAgain
    signal logOut
}
