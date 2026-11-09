pragma Singleton
import QtQuick

// What the rest of the shell may know about the session lock: `locked` follows LockClient.locked (a Binding in shell.qml),
// the state the security process publishes read fail closed (ADR-0041 step 1, S2: the lock lives in that process, never in
// the UI; no state, a stale beat, a lock being acquired or held, or the compositor's own lock signal each read locked), and
// `requestLock()` asks it to lock (shell.qml hands it to LockClient.request, `lock lock` on the security instance).
// Notifications read `locked` (previews "When Unlocked"); Search, the Grassfield menu and the screen corners call
// `requestLock`. `saverShown` mirrors the screen saver (shell/saver, a Binding in shell.qml) for the polkit agent, which holds
// a request while it shows (ADR-0032); true when it is not would only hold a request. Without the shell's wiring (a test
// harness) the session counts as unlocked, no saver shows and a lock request does nothing.
QtObject {
    id: root

    property bool locked: false
    // The lock is known to be held or being acquired (LockClient.lockConfirmed, a Binding in shell.qml): false while `locked`
    // is true only because the security process's state is missing or stale after an "unlocked" (it is down). True by
    // default, so that a harness that sets `locked` gets every GF-116 refusal.
    property bool lockConfirmed: true
    // A lock is being acquired: the security process asked the compositor and has no confirmation yet (LockClient.lockStarting,
    // a Binding in shell.qml). The screen saver stays up meanwhile, so no desktop flashes before the lock surface.
    property bool lockStarting: false
    property bool saverShown: false
    // An authorization (polkit) request is open (shell/security/polkit AuthAgent.requestActive, set by a Binding in shell.qml).
    // The clipboard history records nothing while it is true and for 2 s after (ADR-0034 Q11): an echo-on answer is copyable.
    property bool authorizing: false
    // The displays are off for inactivity or on the lock screen (shell/security/idle Idle.displayOff, a Binding in shell.qml):
    // the polkit agent lets no device answer a request then (nobody sees its sheet; ADR-0045 OC-6, opus re-review MINOR-2).
    property bool displaysOff: false
    // The polkit sheet or a secret sheet is present, or one of their key sinks still holds the keyboard after a request ended
    // under the user's typing (AuthAgent.queuePresent, SecretAgent.requestActive / sinkingKeys; a Binding in shell.qml): the
    // capture toolbar maps nothing as Exclusive meanwhile, so no rest of a password reaches it (opus re-review MINOR-3).
    property bool securityKeyboard: false
    signal lockRequested(string reason)

    function requestLock(reason: string): void {
        lockRequested(reason);
    }

    // GF-AUDIT-001 GF-116 (DT-08), macOS model: while the session is locked (or locking) nothing but the lock screen
    // opens. Every shell surface asks this before it opens (Search, Apps, Overview, Notification Center, every Popups
    // kind: Control Center, menus, panels; Dock keyboard mode; window commands), whatever asked: a binding, IPC, a screen
    // corner, a gesture. True (and one log line naming the surface) while locked: the caller then stays closed. Each
    // surface also closes itself when `locked` becomes true. Hyprland keeps input and rendering on the lock surfaces
    // anyway (ext-session-lock); this is the shell's own defence, so nothing waits behind the lock either.
    function refuses(surface: string): bool {
        if (!locked)
            return false;
        console.info("grassfield: " + surface + " refused: the session is locked");
        root.lastRefused = surface;
        return true;
    }

    // GF-116 for the paths that lock or end the session (the Grassfield menu and its confirmation, Search with its Lock Screen
    // command, the lock corner): refused only while the lock is confirmed (`lockConfirmed`). While the UI reads locked only
    // because the security process is down, they open, so that a lock request reaches it (LockClient hands it to the stand-in,
    // which starts the unit): a lock request always ends in a locked session (ADR-0041 S2, the opus review of 77a0ceb3,
    // MAJOR-1). Everything else keeps `refuses`.
    function refusesConfirmed(surface: string): bool {
        if (!locked || !lockConfirmed)
            return false;
        return refuses(surface);
    }

    // The surface the last refusal named (tests/shell harnesses check that a call was refused by its own gate).
    property string lastRefused: ""
}
