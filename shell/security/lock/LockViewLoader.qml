import QtQuick
import "../LockMachine.js" as Machine

// The view of one lock surface (LockView), loaded after the surface's first frame (Lock.qml, ADR-0041 S2: Hyprland confirms
// the lock on that frame, the opaque ground, not on the view). Two fallbacks, so that a person is never left without a
// password field (the opus gate of d151cace):
//   - a load that fails is tried once more, synchronously (logged);
//   - a load still under way Machine.VIEW_SYNC_FALLBACK_MS after the surface was created is completed at once: setting
//     `asynchronous` to false finishes an asynchronous load (logged).
// Display only: the view holds no state the lock depends on, and nothing here locks, unlocks or authenticates.
// Tested by tests/security/tst_lockbackdrop.qml (a forced error, a load completed by the fallback).
Loader {
    id: root

    asynchronous: true
    // How long an asynchronous load may take (ms).
    property int fallbackMs: Machine.VIEW_SYNC_FALLBACK_MS
    // The one synchronous retry after an error was made.
    property bool retried: false
    // How many retries ran (at most 1; the test of the guard above, tests/security/tst_lockbackdrop.qml).
    property int retries: 0

    function retry(): void {
        root.retries += 1;
        const view = root.sourceComponent;
        root.asynchronous = false;
        root.sourceComponent = null;
        root.sourceComponent = view;
    }

    onStatusChanged: {
        if (root.status !== Loader.Error || root.retried)
            return;
        root.retried = true;
        console.warn("grassfield-lock: the lock view did not load; trying once more, synchronously");
        // Not from inside the status change itself.
        Qt.callLater(root.retry);
    }

    Timer {
        interval: root.fallbackMs
        running: root.asynchronous && root.status === Loader.Loading
        onTriggered: {
            console.warn("grassfield-lock: the lock view was still loading after " + root.fallbackMs + " ms; completing it now");
            root.asynchronous = false;
        }
    }
}
