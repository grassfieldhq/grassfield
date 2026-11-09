pragma Singleton
import QtQuick

// What the polkit sheet and the secret sheets know about the session (ADR-0041 step 1, S3): read by AuthAgent and SecretAgent
// only, written only by shell/security/host/SecurityHost.qml, in the security process, from that process's own lock and idle
// modules (Bindings): `locked` from Lock.locked, `displaysOff` from Idle.displayOff, `saverShown` from Idle.saverShown. So
// nothing the UI publishes, writes or answers reaches the sheets' rules (the hold behind the lock, the device rule of
// ADR-0045 OC-6): the state file the UI reads is never read here (docs/specs/security.md "Lock state across processes",
// the opus review of 77a0ceb3, MINOR-4). tests/security/security_process_scan.py holds the one writer and the UI's absence.
// Fail closed without the host's Bindings (a harness sets each value itself): the session counts as locked and the
// displays as off, so no sheet is mapped, given the keyboard or answerable by a device.
QtObject {
    // The session lock is requested, being acquired or held (Lock.locked: any state but UNLOCKED).
    property bool locked: true
    // The displays are off: for inactivity while unlocked, or on the lock screen (Idle.displayOff). No device answers a
    // request nobody can see (ADR-0045 OC-6, opus re-review 2, MINOR-2).
    property bool displaysOff: true
    // The UI's screen saver may be on screen (Idle.saverShown: the same idle rule as shell/saver, counted in this process).
    // True only ever holds a request.
    property bool saverShown: false
}
