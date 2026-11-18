import QtQuick
import "LockMachine.js" as Machine

// Authentication controller of the lock screen (ADR-0010). Owns the state machine and the PAM
// conversation; knows nothing about Wayland, so tests drive it with a mock PAM backend
// (tests/security/tst_lockcontroller.qml). The Lock singleton wires it to WlSessionLock and a
// real PamContext.
//
// Secret handling: the password arrives through submit(), is held in `priv.pending` only until
// PAM asks for it (one prompt is answered, never more), and is dropped after respond() and on
// every outcome. JavaScript strings are immutable, so "dropped" means no reference is kept.
QtObject {
    id: root

    // PAM backend: start(): bool, respond(string), abort(). Its messages arrive via pamMessage().
    property var pam: null
    // A conversation still running after this many ms is aborted; the session stays locked.
    property int authTimeout: 30000
    // False when /etc/pam.d/omarchy-lock-password is missing: no attempt is possible and the
    // session stays locked (never fail open).
    property bool pamAvailable: true
    // Defence in depth for dev/test sessions (set by Lock.qml from GRASSFIELD_DEV without
    // GRASSFIELD_DEV_ALLOW_PAM): a submitted password is NEVER handed to PAM, so a stray key that
    // reaches the lock field in a nested test can never count a failure against the real account
    // (faillock). The field is cleared and the session stays LOCKED (fail closed). Always false in a
    // real session, so authentication is unchanged there.
    property bool pamSuppressed: false
    // Set by Lock.qml while the computer is being put to sleep (SS-01, SleepInhibitor): no attempt starts and a fingerprint
    // match unlocks nothing, so the lock taken for the sleep cannot be opened before the computer sleeps. Only ever refuses.
    property bool sleepPending: false
    // ADR-0040 step 4b (IQ-T2 A): after a PAM success the lock's content fades out over this many ms while the session is
    // still locked (state "releasing"); only then is unlockRequested emitted. 0: at once. A lock request, a lost lock or
    // an abort during it brings the lock back, and the PAM success is spent (a new one is needed).
    property int releaseMs: 0

    readonly property string lockState: priv.state
    readonly property bool locked: priv.state !== Machine.UNLOCKED
    readonly property bool authenticating: priv.state === Machine.AUTHENTICATING
    readonly property bool releasing: priv.state === Machine.RELEASING
    readonly property bool canSubmit: priv.state === Machine.LOCKED && pamAvailable
    // True only while a submitted password waits for PAM's prompt (tests assert it drops).
    readonly property bool holdsSecret: priv.pending.length > 0
    // User-facing result of the last attempt (plain text).
    readonly property string message: priv.message
    readonly property int failedAttempts: priv.failures

    // Release the session lock: emitted once, after a PAM success and the release fade only.
    signal unlockRequested
    // An attempt failed (wrong password, PAM error, timeout): shake the field.
    signal failed
    // Every password field must be emptied (after each attempt, on lock and on unlock).
    signal clearRequested

    component Private: QtObject {
        property string state: Machine.UNLOCKED
        property string pending: ""
        property string pamError: ""
        property string message: ""
        property int failures: 0
    }

    readonly property Private priv: Private {}

    property Timer timer: Timer {
        interval: root.authTimeout
        onTriggered: root.timedOut()
    }

    // The end of the release fade: a Timer (monotonic), never the view's animation, so a fade that does not run cannot hold
    // the unlock back for ever, and nothing but this timer, armed by a PAM success, completes it.
    property Timer releaseTimer: Timer {
        interval: Math.max(0, root.releaseMs)
        onTriggered: root.released()
    }

    // The state machine's state, read from its storage and not through a binding: decisions (lock requested before
    // sleep, restore, stranded check) use it so that a binding that missed a change notification can never make a lock
    // request look done (Omarchy 4.0.6 fix, see Lock.currentlyLocked()).
    function currentState(): string {
        return priv.state;
    }

    function dispatch(event: string): string {
        const before = priv.state;
        const after = Machine.next(before, event);
        if (after !== before) {
            // Logged first: the assignment runs every binding and handler that depends on the state.
            console.info("grassfield-lock: " + before + " -> " + after + " (" + event + ")");
            priv.state = after;
        }
        return after;
    }

    function requestLock(): void {
        if (dispatch("request") === Machine.LOCKING) {
            priv.message = "";
            clearRequested();
        }
    }

    // A lock request during the release fade (ADR-0040 step 4b): the content comes back, the session stays locked, and the
    // spent PAM success unlocks nothing. Returns whether a release was interrupted.
    function interruptRelease(): bool {
        if (priv.state !== Machine.RELEASING)
            return false;
        releaseTimer.stop();
        dispatch("request");
        priv.message = "";
        clearRequested();
        return true;
    }

    function released(): void {
        if (priv.state !== Machine.RELEASING)
            return;
        if (dispatch("released") === Machine.UNLOCKED)
            unlocked();
    }

    function beginRelease(): void {
        if (root.releaseMs <= 0) {
            released();
            return;
        }
        releaseTimer.restart();
    }

    function lockAcquired(): void {
        dispatch("acquired");
    }

    // The compositor no longer holds our lock (denied or dropped). Keep the intent: re-acquire.
    function lockLost(): void {
        if (priv.state === Machine.AUTHENTICATING) {
            abortPam();
            timer.stop();
            priv.pending = "";
        }
        // A release in progress is spent (ADR-0040 step 4b): re-acquire, a new PAM success will be needed.
        releaseTimer.stop();
        dispatch("lost");
    }

    function submit(password: string): bool {
        if (!canSubmit || sleepPending || password.length === 0)
            return false;
        if (pamSuppressed) {
            // Dev/test only: swallow the attempt without touching PAM; stay locked (fail closed).
            console.warn("grassfield-lock: dev: PAM submit suppressed (set GRASSFIELD_DEV_ALLOW_PAM=1 to allow the L2 failure-path test)");
            priv.pending = "";
            priv.message = "";
            clearRequested();
            return true;
        }
        dispatch("submit");
        priv.message = "";
        priv.pamError = "";
        priv.pending = password;
        timer.restart();
        let started = false;
        try {
            started = pam !== null && pam.start() === true;
        } catch (e) {
            started = false;
        }
        if (!started)
            finish("error", "error");
        return true;
    }

    // One call per PAM message (PamContext.pamMessage, emitted after its properties update).
    // Prompts are counted per message, not from responseRequired: that property stays true
    // until PAM's next message, so it cannot tell a new prompt from the one just answered.
    function pamMessage(text: string, isError: bool, responseRequired: bool): void {
        if (priv.state !== Machine.AUTHENTICATING)
            return;
        if (isError)
            priv.pamError = text;
        if (!responseRequired)
            return;
        if (priv.pending.length === 0) {
            // A second prompt: only one answer is ever given. Give up and stay locked.
            abortPam();
            finish("error", "error");
            return;
        }
        const secret = priv.pending;
        priv.pending = "";
        pam.respond(secret);
    }

    // result: "success" | "failed" | "maxtries" | "error" (mapped from PamResult by the shell).
    function pamCompleted(result: string): void {
        if (priv.state !== Machine.AUTHENTICATING)
            return; // stale result (timed out, aborted, or lock lost): ignored
        if (result === "success")
            finish("success", result);
        else if (result === "failed" || result === "maxtries")
            finish("failure", result);
        else
            finish("error", "error");
    }

    function pamError(): void {
        if (priv.state === Machine.AUTHENTICATING)
            finish("error", "error");
    }

    function timedOut(): void {
        if (priv.state !== Machine.AUTHENTICATING)
            return;
        abortPam();
        finish("timeout", "timeout");
    }

    function abort(): void {
        if (priv.state !== Machine.AUTHENTICATING)
            return;
        abortPam();
        finish("abort", "abort");
    }

    // PAM success of the fingerprint service (only started when its PAM file exists).
    function fingerprintSucceeded(): void {
        if (priv.state !== Machine.LOCKED && priv.state !== Machine.AUTHENTICATING)
            return;
        // The computer is going to sleep (SS-01): a finger on the reader after the lock before sleep opens nothing.
        if (sleepPending)
            return;
        if (priv.state === Machine.AUTHENTICATING)
            abortPam();
        timer.stop();
        priv.pending = "";
        if (dispatch("fingerprint") === Machine.RELEASING) {
            priv.failures = 0;
            priv.message = "";
            priv.pamError = "";
            clearRequested();
            beginRelease();
        }
    }

    // The user is typing again: drop the last error (never while an attempt is running).
    function clearMessage(): void {
        if (priv.state === Machine.LOCKED)
            priv.message = "";
    }

    function abortPam(): void {
        try {
            if (pam)
                pam.abort();
        } catch (e) {
            console.warn("grassfield-lock: PAM abort failed");
        }
    }

    function finish(event: string, detail: string): void {
        timer.stop();
        priv.pending = "";
        const state = dispatch(event);
        clearRequested();
        if (state === Machine.RELEASING) {
            priv.failures = 0;
            priv.message = "";
            priv.pamError = "";
            beginRelease();
            return;
        }
        if (event === "failure")
            priv.failures += 1;
        priv.message = messageFor(detail);
        priv.pamError = "";
        if (event !== "abort")
            failed();
    }

    function unlocked(): void {
        priv.failures = 0;
        priv.message = "";
        priv.pamError = "";
        clearRequested();
        unlockRequested();
    }

    function messageFor(detail: string): string {
        if (priv.pamError !== "")
            return priv.pamError;
        switch (detail) {
        case "failed":
            return qsTr("Incorrect password");
        case "maxtries":
            return qsTr("Too many attempts. Try again later.");
        case "timeout":
            return qsTr("Authentication timed out");
        case "abort":
            return "";
        }
        return qsTr("Authentication error");
    }
}
