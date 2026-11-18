import QtQuick
import QtTest
import "../../shell/security"

// LockController with a mock PAM backend: only a PAM success unlocks; failures, errors,
// timeouts, aborts and a lost lock keep the session locked; the password never outlives an attempt.
TestCase {
    id: test

    name: "LockController"

    // PamContext stand-in. Like the real one, the prompt arrives as a message after start():
    // tests deliver it with prompt() (PamContext.pamMessage → controller.pamMessage).
    component MockPam: QtObject {
        property bool startResult: true
        property int starts: 0
        property int aborts: 0
        property var responses: []

        function start(): bool {
            starts += 1;
            return startResult;
        }

        function respond(response: string): void {
            responses = responses.concat([response]);
        }

        function abort(): void {
            aborts += 1;
        }
    }

    Component {
        id: pamComponent
        MockPam {}
    }

    Component {
        id: controllerComponent
        LockController {
            authTimeout: 100
        }
    }

    Component {
        id: spyComponent
        SignalSpy {}
    }

    property var pam: null
    property var ctl: null
    property var unlockSpy: null
    property var failedSpy: null
    property var clearSpy: null

    function prompt() {
        ctl.pamMessage("Password: ", false, true);
    }

    function init() {
        pam = createTemporaryObject(pamComponent, test);
        ctl = createTemporaryObject(controllerComponent, test, {pam: pam});
        unlockSpy = createTemporaryObject(spyComponent, test, {target: ctl, signalName: "unlockRequested"});
        failedSpy = createTemporaryObject(spyComponent, test, {target: ctl, signalName: "failed"});
        clearSpy = createTemporaryObject(spyComponent, test, {target: ctl, signalName: "clearRequested"});
        ctl.requestLock();
        ctl.lockAcquired();
        compare(ctl.lockState, "locked");
    }

    function test_successUnlocks() {
        verify(ctl.submit("hunter2"));
        compare(ctl.lockState, "authenticating");
        verify(ctl.holdsSecret); // until PAM asks
        prompt();
        compare(pam.responses, ["hunter2"]);
        verify(!ctl.holdsSecret);
        ctl.pamCompleted("success");
        compare(ctl.lockState, "unlocked");
        compare(unlockSpy.count, 1);
        compare(failedSpy.count, 0);
    }

    // ADR-0040 step 4b (IQ-T2 A): with a release fade, a PAM success leads to "releasing" (still locked, the field
    // cleared, nothing unlocked), and only the end of the fade unlocks.
    function test_successReleasesAfterTheFade() {
        ctl.releaseMs = 80;
        ctl.submit("hunter2");
        prompt();
        ctl.pamCompleted("success");
        compare(ctl.lockState, "releasing");
        verify(ctl.locked && ctl.releasing && !ctl.canSubmit);
        compare(unlockSpy.count, 0);
        verify(!ctl.holdsSecret);
        // Nothing can be submitted during the fade.
        verify(!ctl.submit("again"));
        compare(pam.starts, 1);
        tryCompare(ctl, "lockState", "unlocked", 1000);
        compare(unlockSpy.count, 1);
    }

    // Anything during the fade brings the lock back; the PAM success is spent (review invariant of ADR-0040 section 4).
    function test_aLockRequestDuringTheFadeKeepsTheLock() {
        ctl.releaseMs = 80;
        ctl.submit("pw");
        prompt();
        ctl.pamCompleted("success");
        compare(ctl.lockState, "releasing");
        verify(ctl.interruptRelease());
        compare(ctl.lockState, "locked");
        wait(200);
        compare(ctl.lockState, "locked", "the timer of the spent release unlocks nothing");
        compare(unlockSpy.count, 0);
        // A new PAM success is needed.
        verify(ctl.submit("pw2"));
        prompt();
        ctl.pamCompleted("success");
        tryCompare(ctl, "lockState", "unlocked", 1000);
        compare(unlockSpy.count, 1);
    }

    // Opus review of f66cf08e (MINOR 1): Lock.lock() abandons a check in flight (controller.abort): a success that arrives
    // after the lock request unlocks nothing, and no failure is counted or shaken.
    function test_aLockRequestAbandonsACheckInFlight() {
        ctl.releaseMs = 80;
        ctl.submit("pw");
        prompt();
        compare(ctl.lockState, "authenticating");
        ctl.abort();
        compare(ctl.lockState, "locked");
        compare(pam.aborts, 1);
        compare(failedSpy.count, 0);
        compare(ctl.failedAttempts, 0);
        ctl.pamCompleted("success");
        compare(ctl.lockState, "locked", "a late success is ignored");
        wait(200);
        compare(unlockSpy.count, 0);
    }

    function test_aLostLockDuringTheFadeReacquires() {
        ctl.releaseMs = 80;
        ctl.submit("pw");
        prompt();
        ctl.pamCompleted("success");
        ctl.lockLost();
        compare(ctl.lockState, "locking");
        wait(200);
        compare(ctl.lockState, "locking");
        compare(unlockSpy.count, 0);
        // A late "released" is ignored outside the fade: no unlock either (the integrator's review of e067f26f, mutant M4).
        ctl.released();
        compare(ctl.lockState, "locking");
        compare(unlockSpy.count, 0);
        verify(!ctl.interruptRelease(), "nothing to interrupt");
    }

    function test_fingerprintReleasesAfterTheFade() {
        ctl.releaseMs = 80;
        ctl.fingerprintSucceeded();
        compare(ctl.lockState, "releasing");
        compare(unlockSpy.count, 0);
        tryCompare(ctl, "lockState", "unlocked", 1000);
        compare(unlockSpy.count, 1);
    }

    function test_wrongPasswordStaysLocked() {
        const clears = clearSpy.count;
        ctl.submit("wrong");
        prompt();
        ctl.pamCompleted("failed");
        compare(ctl.lockState, "locked");
        compare(unlockSpy.count, 0);
        compare(failedSpy.count, 1);
        compare(ctl.failedAttempts, 1);
        compare(ctl.message, "Incorrect password");
        verify(!ctl.holdsSecret);
        verify(clearSpy.count > clears);
    }

    // Defence in depth (R12 review #3 MAJOR): in a dev/test session without the opt-in, a submit never reaches PAM,
    // the field is cleared and the session stays LOCKED. This is what stops a stray nested key from counting a
    // faillock failure against the real account.
    function test_devPamSuppressedNeverCallsPam() {
        ctl.pamSuppressed = true;
        const clears = clearSpy.count;
        verify(ctl.submit("anything")); // consumed
        compare(pam.starts, 0); // PAM never started
        compare(ctl.lockState, "locked"); // never enters authenticating
        verify(!ctl.authenticating);
        verify(!ctl.holdsSecret); // no secret retained
        compare(unlockSpy.count, 0); // never unlocks
        compare(failedSpy.count, 0); // not counted as a failure
        compare(ctl.failedAttempts, 0);
        verify(clearSpy.count > clears); // field cleared
        // A later real attempt (opt-in) still works through the normal path.
        ctl.pamSuppressed = false;
        verify(ctl.submit("pw"));
        compare(ctl.lockState, "authenticating");
        compare(pam.starts, 1);
    }

    function test_typingClearsTheErrorOnly() {
        ctl.submit("wrong");
        prompt();
        ctl.pamCompleted("failed");
        compare(ctl.message, "Incorrect password");
        ctl.clearMessage();
        compare(ctl.message, "");
        compare(ctl.lockState, "locked");
        compare(ctl.failedAttempts, 1);
    }

    function test_errorsStayLocked() {
        const outcomes = ["error", "maxtries", "something-unexpected"];
        for (let i = 0; i < outcomes.length; i++) {
            ctl.submit("pw" + i);
            prompt();
            ctl.pamCompleted(outcomes[i]);
            compare(ctl.lockState, "locked", outcomes[i]);
            verify(!ctl.holdsSecret, outcomes[i]);
        }
        ctl.submit("pw");
        ctl.pamError();
        compare(ctl.lockState, "locked");
        verify(!ctl.holdsSecret);
        compare(unlockSpy.count, 0);
    }

    function test_pamStartFailureStaysLocked() {
        pam.startResult = false;
        verify(ctl.submit("pw"));
        compare(ctl.lockState, "locked");
        compare(ctl.message, "Authentication error");
        verify(!ctl.holdsSecret);
        compare(unlockSpy.count, 0);
    }

    function test_timeoutStaysLockedAndIgnoresLateSuccess() {
        ctl.submit("pw"); // PAM never prompts
        verify(ctl.holdsSecret);
        tryCompare(ctl, "lockState", "locked", 1000);
        compare(pam.aborts, 1);
        verify(!ctl.holdsSecret);
        compare(ctl.message, "Authentication timed out");
        ctl.pamCompleted("success"); // stale result after the timeout
        compare(ctl.lockState, "locked");
        compare(unlockSpy.count, 0);
    }

    function test_abortStaysLocked() {
        ctl.submit("pw");
        ctl.abort();
        compare(ctl.lockState, "locked");
        compare(pam.aborts, 1);
        verify(!ctl.holdsSecret);
        compare(unlockSpy.count, 0);
        compare(failedSpy.count, 0);
    }

    function test_lostLockDuringAuthenticationNeverUnlocks() {
        ctl.submit("pw");
        ctl.lockLost();
        compare(ctl.lockState, "locking");
        verify(!ctl.holdsSecret);
        ctl.pamCompleted("success");
        compare(ctl.lockState, "locking");
        compare(unlockSpy.count, 0);
        verify(!ctl.submit("pw")); // no attempt before the lock is confirmed again
    }

    function test_onlyOnePromptIsAnswered() {
        ctl.submit("pw");
        prompt();
        compare(pam.responses.length, 1);
        prompt(); // PAM asks a second time
        compare(pam.responses.length, 1);
        compare(pam.aborts, 1);
        compare(ctl.lockState, "locked");
    }

    // Regression (nested L2, 2026-10-17): PamContext.responseRequired stays true after respond(),
    // so prompts are counted per message; informational messages are not prompts.
    function test_infoMessagesAreNotPrompts() {
        ctl.submit("pw");
        ctl.pamMessage("Checking", false, false);
        compare(pam.responses.length, 0);
        verify(ctl.holdsSecret);
        prompt();
        compare(pam.responses, ["pw"]);
        verify(!ctl.holdsSecret);
        ctl.pamMessage("info", false, false);
        compare(pam.aborts, 0);
        compare(ctl.lockState, "authenticating");
        ctl.pamCompleted("failed");
        compare(ctl.lockState, "locked");
    }

    function test_promptOutsideAuthenticationIsIgnored() {
        prompt();
        compare(pam.responses.length, 0);
        compare(ctl.lockState, "locked");
    }

    function test_pamErrorMessageIsShown() {
        ctl.submit("pw");
        ctl.pamMessage("The account is locked due to 10 failed logins.", true, false);
        ctl.pamCompleted("failed");
        compare(ctl.message, "The account is locked due to 10 failed logins.");
    }

    function test_noAttemptWhenNotLockedOrEmpty() {
        verify(!ctl.submit(""));
        compare(pam.starts, 0);
        const fresh = createTemporaryObject(controllerComponent, test, {pam: pam});
        verify(!fresh.submit("pw")); // unlocked
        fresh.requestLock();
        verify(!fresh.submit("pw")); // locking, not confirmed
        compare(pam.starts, 0);
    }

    function test_missingPamServiceBlocksAttempts() {
        ctl.pamAvailable = false;
        verify(!ctl.submit("pw"));
        compare(pam.starts, 0);
        compare(ctl.lockState, "locked");
    }

    // SS-01: while the computer is being put to sleep nothing opens the lock: no password is handed to PAM and a
    // fingerprint match is ignored; both work again once the flag is cleared.
    function test_sleepPendingRefusesEveryUnlock() {
        ctl.sleepPending = true;
        verify(!ctl.submit("pw"));
        compare(pam.starts, 0);
        ctl.fingerprintSucceeded();
        compare(ctl.lockState, "locked");
        compare(unlockSpy.count, 0);
        ctl.sleepPending = false;
        verify(ctl.submit("pw"));
        compare(pam.starts, 1);
    }

    function test_fingerprintSuccess() {
        ctl.fingerprintSucceeded();
        compare(ctl.lockState, "unlocked");
        compare(unlockSpy.count, 1);
        const fresh = createTemporaryObject(controllerComponent, test, {pam: pam});
        fresh.requestLock();
        fresh.fingerprintSucceeded(); // not confirmed locked yet: ignored
        compare(fresh.lockState, "locking");
    }

    function test_relockAfterUnlock() {
        ctl.submit("pw");
        prompt();
        ctl.pamCompleted("success");
        ctl.requestLock();
        compare(ctl.lockState, "locking");
        compare(ctl.failedAttempts, 0);
    }
}
