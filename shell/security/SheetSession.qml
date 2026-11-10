pragma Singleton
import QtQuick

// What the polkit sheet and the secret sheets know about the session (ADR-0041 step 1, S3): read by AuthAgent and SecretAgent
// only, written only by shell/security/host/SecurityHost.qml, in the security process, from that process's own lock and idle
// modules (Bindings): `locked` from Lock.locked and the start-up stranded-lock probe (Lock.strandedProbing), `displaysOff`
// from Idle.displayOff, `saverShown` from Idle.saverShown, `starting` from Idle.starting. The state file the UI reads is never read here, so a forged
// `unlocked` no longer reaches the hold behind the lock or the device rule of ADR-0045 OC-6 (the opus review of 77a0ceb3,
// MINOR-4, closed for the lock and the displays). The screen saver is the UI's: idle counts its idle time itself, early and
// never late (from this process's start until the user is seen active, and without the UI's `idle inhibit` lease, which
// can only keep idle's own timers off: the opus review of S3, MINOR-1). Same-user code can still keep the displays on
// through that lease (they then are on) and can restart this process (the saver then counts as shown until activity).
// tests/security/security_process_scan.py holds the one writer and the UI's absence.
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
    // saverShown is true for this process's start alone (Idle.starting: the user not seen active yet, no saver counted): a
    // request held then says it arrived while Grassfield was starting (the opus delta review of S3, LOW). Text only.
    property bool starting: false
}
