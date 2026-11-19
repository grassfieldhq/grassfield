import QtQuick
import QtTest
import "../../shell/security/LockMachine.js" as Machine

// Lock state machine (ADR-0010): only a PAM success reaches "unlocked".
TestCase {
    name: "LockMachine"

    function test_happyPath() {
        let s = Machine.UNLOCKED;
        s = Machine.next(s, "request");
        compare(s, "locking");
        s = Machine.next(s, "acquired");
        compare(s, "locked");
        s = Machine.next(s, "submit");
        compare(s, "authenticating");
        s = Machine.next(s, "success");
        // ADR-0040 step 4b: the lock's content fades out first, the session still locked.
        compare(s, "releasing");
        verify(Machine.isLocked(s));
        s = Machine.next(s, "released");
        compare(s, "unlocked");
    }

    function test_failuresReturnToLocked() {
        const events = ["failure", "error", "timeout", "abort"];
        for (let i = 0; i < events.length; i++)
            compare(Machine.next("authenticating", events[i]), "locked", events[i]);
    }

    // Exhaustive: from any locked state, only "released" from "releasing" unlocks, and only a PAM success
    // ("success" while authenticating, "fingerprint" while locked or authenticating) enters "releasing" (ADR-0040 step 4b).
    function test_onlyPamSuccessUnlocks() {
        const lockedStates = ["locking", "locked", "authenticating", "releasing"];
        for (let i = 0; i < lockedStates.length; i++) {
            for (let j = 0; j < Machine.EVENTS.length; j++) {
                const event = Machine.EVENTS[j];
                const after = Machine.next(lockedStates[i], event);
                if (after === "unlocked")
                    verify(event === "released" && lockedStates[i] === "releasing", lockedStates[i] + " + " + event);
                if (after === "releasing" && lockedStates[i] !== "releasing")
                    verify(event === "success" && lockedStates[i] === "authenticating" || event === "fingerprint" && (lockedStates[i] === "locked" || lockedStates[i] === "authenticating"), lockedStates[i] + " + " + event);
            }
        }
        // Two steps from any locked state: never unlocked without a PAM success first.
        for (const st of ["locking", "locked"])
            for (const a of Machine.EVENTS)
                for (const b of Machine.EVENTS)
                    if (Machine.next(Machine.next(st, a), b) === "unlocked")
                        verify(a === "fingerprint" && b === "released" && st === "locked", st + " + " + a + " + " + b);
    }

    // ADR-0040 step 4b: anything during the fade brings the lock back, and the PAM success is spent.
    function test_releasingIsInterrupted() {
        compare(Machine.next("releasing", "request"), "locked");
        compare(Machine.next("releasing", "lost"), "locking");
        for (const e of ["error", "timeout", "abort"])
            compare(Machine.next("releasing", e), "locked", e);
        // A new password is needed: nothing but "released" leaves releasing towards unlocked, and from locked a new submit.
        compare(Machine.next("releasing", "submit"), "releasing");
        compare(Machine.next("releasing", "success"), "releasing");
        compare(Machine.next("locked", "released"), "locked");
        compare(Machine.next("authenticating", "released"), "authenticating");
        compare(Machine.next("unlocked", "released"), "unlocked");
        compare(Machine.next("locking", "released"), "locking");
    }

    function test_successOutsideAuthenticationIsIgnored() {
        compare(Machine.next("locked", "success"), "locked");
        compare(Machine.next("locking", "success"), "locking");
        compare(Machine.next("locking", "fingerprint"), "locking");
    }

    function test_unknownEventsAndStatesFailClosed() {
        compare(Machine.next("locked", "bogus"), "locked");
        compare(Machine.next("authenticating", ""), "authenticating");
        compare(Machine.next("garbage", "success"), "locking");
        compare(Machine.next(undefined, "request"), "locking");
    }

    function test_lostLockIsReacquired() {
        compare(Machine.next("locked", "lost"), "locking");
        compare(Machine.next("authenticating", "lost"), "locking");
        compare(Machine.next("releasing", "lost"), "locking");
        compare(Machine.next("unlocked", "lost"), "unlocked");
    }

    function test_submitOnlyWhenLocked() {
        compare(Machine.next("locking", "submit"), "locking");
        compare(Machine.next("unlocked", "submit"), "unlocked");
        compare(Machine.next("authenticating", "submit"), "authenticating");
    }

    function test_marker() {
        verify(Machine.markerSaysLocked("locked\n"));
        verify(Machine.markerSaysLocked("garbage"));
        verify(!Machine.markerSaysLocked("unlocked\n"));
        verify(!Machine.markerSaysLocked("  unlocked  "));
        verify(Machine.markerSaysLocked("unlocked locked"));
        // Existing but empty or unreadable (markerRead gives ""): not exactly "unlocked" -> lock.
        verify(Machine.markerSaysLocked(""));
        // Missing (markerRead gives null): the first start of this compositor instance.
        verify(!Machine.markerSaysLocked(null));
        verify(!Machine.markerSaysLocked(undefined));
        compare(Machine.markerName("abc_123_4", "wayland-1"), "grassfield-lock-abc_123_4");
        compare(Machine.markerName("", "/run/user/1000/wayland-1"), "grassfield-lock-_run_user_1000_wayland-1");
        compare(Machine.markerName("", ""), "grassfield-lock-default");
    }

    // Follow-up N1: the marker records the kernel's count of completed suspends; a restarted shell locks when the
    // machine slept since an "unlocked" line was written (a crash or restart right before or during that sleep).
    function test_markerWithSleepCount() {
        compare(Machine.markerLine("unlocked", 12), "unlocked sleeps=12");
        compare(Machine.markerLine("locked", 0), "locked sleeps=0");
        compare(Machine.markerLine("unlocked", -1), "unlocked");
        compare(Machine.markerLine("locked", NaN), "locked");
        compare(Machine.markerLine("garbage", 3), "locked sleeps=3", "anything unknown is written as locked");
        compare(Machine.parseSleepCount("7\n"), 7);
        compare(Machine.parseSleepCount(" 0 "), 0);
        const bad = ["", "x", "-1", "1.5", "12 13", undefined, null];
        for (let i = 0; i < bad.length; i++)
            compare(Machine.parseSleepCount(bad[i]), -1, String(bad[i]));
        verify(!Machine.markerSaysLocked("unlocked sleeps=12\n"));
        verify(Machine.markerSaysLocked("locked sleeps=12\n"));
        verify(Machine.markerSaysLocked("unlocked sleeps=\n"));
        verify(Machine.markerSaysLocked("unlocked sleeps=-1"));
        verify(Machine.markerSaysLocked("unlocked sleeps=12 extra"));
        // Slept since the unlocked line: lock. Same count, unknown counts, an old line without a count: no evidence.
        verify(Machine.sleptSince("unlocked sleeps=12\n", 13));
        verify(!Machine.sleptSince("unlocked sleeps=12\n", 12));
        verify(!Machine.sleptSince("unlocked sleeps=12\n", -1));
        verify(!Machine.sleptSince("unlocked sleeps=12\n", undefined));
        verify(!Machine.sleptSince("unlocked\n", 13));
        verify(!Machine.sleptSince(null, 13));
        verify(Machine.restoreAtStart(false, true, "unlocked sleeps=12\n", 13));
        verify(Machine.restoreAtStart(false, true, "unlocked sleeps=12\n", 11), "a lower count (reboot of the counter) is a difference too");
        verify(!Machine.restoreAtStart(false, true, "unlocked sleeps=12\n", 12));
        verify(!Machine.restoreAtStart(false, true, "unlocked sleeps=12\n", -1));
        verify(Machine.restoreAtStart(false, true, "locked sleeps=12\n", 12));
        verify(!Machine.restoreAtStart(false, true, null, 13), "fresh session (no marker): unlocked");
    }

    // Start/reload decision (R12 review blocker): fail closed; only a proven unlock starts unlocked.
    function test_restoreAtStart() {
        // Soft reload while locked: the carried intent wins over a missing or forged marker.
        verify(Machine.restoreAtStart(true, true, ""));
        verify(Machine.restoreAtStart(true, true, "unlocked\n"));
        verify(Machine.restoreAtStart(true, false, ""));
        // Crash restart: the marker decides.
        verify(Machine.restoreAtStart(false, true, "locked\n"));
        verify(Machine.restoreAtStart(false, true, "garbage"));
        // No XDG_RUNTIME_DIR: nothing can prove the session unlocked.
        verify(Machine.restoreAtStart(false, false, ""));
        verify(Machine.restoreAtStart(false, undefined, "unlocked\n"));
        // Unreadable marker (mode 000, a directory, I/O error): proves nothing -> lock (R12 re-review).
        verify(Machine.restoreAtStart(false, true, Machine.markerRead(false, true, "")));
        verify(Machine.restoreAtStart(false, true, ""));
        // After an explicit unlock (intent cleared, marker "unlocked") and on a fresh session.
        verify(!Machine.restoreAtStart(false, true, "unlocked\n"));
        verify(!Machine.restoreAtStart(false, true, Machine.markerRead(true, true, "")));
        verify(!Machine.restoreAtStart(false, true, null));
        verify(!Machine.restoreAtStart(undefined, true, undefined));
    }

    // FileView result -> marker content: only FileNotFound is "missing"; any other failure is "".
    function test_markerRead() {
        compare(Machine.markerRead(true, true, ""), null);
        compare(Machine.markerRead(false, false, "unlocked\n"), "unlocked\n");
        compare(Machine.markerRead(false, false, "locked\n"), "locked\n");
        // Permission denied / not a file / unknown error: the text is never trusted.
        compare(Machine.markerRead(false, true, ""), "");
        compare(Machine.markerRead(false, true, "unlocked\n"), "");
        compare(Machine.markerRead(false, undefined, "unlocked\n"), "");
        compare(Machine.markerRead(undefined, undefined, "unlocked\n"), "");
        compare(Machine.markerRead(false, false, null), "");
        verify(Machine.markerSaysLocked(Machine.markerRead(false, true, "unlocked\n")));
        verify(!Machine.markerSaysLocked(Machine.markerRead(false, false, "unlocked\n")));
        verify(!Machine.markerSaysLocked(Machine.markerRead(true, true, "")));
    }

    // Lock watchdog (R12 re-review): a session found unlocked under a lock still reported secure is
    // re-locked after a confirming answer; a locked session (ours or a foreign locker's) is left alone.
    function test_ownershipAction() {
        compare(Machine.ownershipAction("locked", 0), "ok");
        compare(Machine.ownershipAction("locked", 5), "ok");
        compare(Machine.ownershipAction("unlocked", 0), "confirm");
        compare(Machine.ownershipAction("unlocked", 1), "relock");
        compare(Machine.ownershipAction("unlocked", 3), "relock");
        compare(Machine.ownershipAction("unknown", 0), "unknown");
        compare(Machine.ownershipAction("unknown", 2), "unknown");
        compare(Machine.ownershipAction(undefined, 1), "unknown");
        // Never "relock" without an "unlocked" answer; never anything that unlocks.
        const states = ["locked", "unlocked", "unknown", "", null];
        for (let i = 0; i < states.length; i++) {
            for (let n = 0; n < 3; n++) {
                const a = Machine.ownershipAction(states[i], n);
                verify(["ok", "unknown", "confirm", "relock"].indexOf(a) !== -1, a);
                if (a === "relock")
                    verify(states[i] === "unlocked" && n >= 1, states[i] + " " + n);
            }
        }
        // Answers as Hyprland 0.56 gives them, before and after a foreign locker released the session.
        compare(Machine.ownershipAction(Machine.compositorLockState([{solitaryBlockedBy: ["LOCK", "WINDOWED", "CANDIDATE"]}]), 0), "ok");
        compare(Machine.ownershipAction(Machine.compositorLockState([{solitaryBlockedBy: ["WINDOWED", "CANDIDATE"]}]), 1), "relock");
    }

    // Suspected takeover (R12 review #3): the probe runs every 100 ms while no lock surface of this
    // shell has the keyboard or the lock was inherited at start; 1 s only when both are known false.
    function test_takeoverSuspected() {
        compare(Machine.takeoverSuspected(true, false), false);
        verify(Machine.takeoverSuspected(false, false));
        verify(Machine.takeoverSuspected(true, true));
        verify(Machine.takeoverSuspected(false, true));
        // Unknown inputs never slow the probe down.
        verify(Machine.takeoverSuspected(undefined, false));
        verify(Machine.takeoverSuspected(true, undefined));
        verify(Machine.takeoverSuspected(1, false));
        verify(Machine.takeoverSuspected(null, null));
        compare(Machine.probeInterval(false), 1000);
        compare(Machine.probeInterval(true), 100);
        compare(Machine.probeInterval(undefined), 100);
        compare(Machine.probeInterval(0), 100);
        verify(Machine.PROBE_SUSPECTED_MS < Machine.PROBE_INTERVAL_MS);
        verify(Machine.PROBE_SUSPECTED_MS <= 100);
        // The rate's suspicion (security-session audit, fluidity): a lock inherited at start with the keyboard counts while
        // the displays are on only; a lost keyboard always counts; anything odd counts.
        verify(Machine.probeSuspected(true, true, false));
        compare(Machine.probeSuspected(true, true, true), false);
        verify(Machine.probeSuspected(false, true, true), "the keyboard lost: a real sign");
        verify(Machine.probeSuspected(false, false, true));
        compare(Machine.probeSuspected(true, false, false), false);
        compare(Machine.probeSuspected(true, false, true), false);
        verify(Machine.probeSuspected(true, true, "true"), "exact values only");
        verify(Machine.probeSuspected(true, undefined, true));
    }

    // Hyprland 0.56 `hyprctl -j monitors` shapes (verified in nested: LOCK stays after the lock
    // client is killed).
    function test_compositorLockState() {
        compare(Machine.compositorLockState([{name: "A", solitaryBlockedBy: ["LOCK", "WINDOWED", "CANDIDATE"]}]), "locked");
        compare(Machine.compositorLockState([{solitaryBlockedBy: ["WORKSPACE"]}, {solitaryBlockedBy: ["WINDOWED", "LOCK"]}]), "locked");
        compare(Machine.compositorLockState([{solitaryBlockedBy: ["WINDOWED", "CANDIDATE"]}]), "unlocked");
        // A monitor without a workspace stops the list before LOCK: proves nothing.
        compare(Machine.compositorLockState([{solitaryBlockedBy: ["WORKSPACE"]}]), "unknown");
        compare(Machine.compositorLockState([{solitaryBlockedBy: ["WORKSPACE"]}, {solitaryBlockedBy: []}]), "unlocked");
        compare(Machine.compositorLockState([]), "unknown");
        compare(Machine.compositorLockState(undefined), "unknown");
        compare(Machine.compositorLockState([null, {}, {solitaryBlockedBy: "LOCK"}]), "unknown");
    }

    // Lazy reading (R12 counter-review: per-probe garbage of the 100 ms check): same answers as compositorLockState for
    // every shape, and while locked only the first monitor's IPC object is read.
    function test_compositorLockStateLazy() {
        const shapes = [
            [{solitaryBlockedBy: ["LOCK", "WINDOWED", "CANDIDATE"]}],
            [{solitaryBlockedBy: ["WORKSPACE"]}, {solitaryBlockedBy: ["WINDOWED", "LOCK"]}],
            [{solitaryBlockedBy: ["WINDOWED", "CANDIDATE"]}],
            [{solitaryBlockedBy: ["WORKSPACE"]}],
            [{solitaryBlockedBy: ["WORKSPACE"]}, {solitaryBlockedBy: []}],
            [],
            [null, {}, {solitaryBlockedBy: "LOCK"}],
            [{solitaryBlockedBy: ["WINDOWED"]}, {solitaryBlockedBy: ["LOCK"]}],
            [{solitaryBlockedBy: ["LOCK"]}, {solitaryBlockedBy: ["WINDOWED"]}]
        ];
        for (let k = 0; k < shapes.length; k++) {
            const list = shapes[k];
            compare(Machine.compositorLockStateLazy(list.length, i => list[i]), Machine.compositorLockState(list), JSON.stringify(list));
        }
        // Locked on the first monitor: the second is never read.
        let reads = [];
        const locked = [{solitaryBlockedBy: ["LOCK"]}, {solitaryBlockedBy: ["LOCK"]}];
        compare(Machine.compositorLockStateLazy(2, i => { reads.push(i); return locked[i]; }), "locked");
        compare(reads, [0]);
        // Unlocked: every monitor is read (a later LOCK would still win), each once, in order.
        reads = [];
        const unlocked = [{solitaryBlockedBy: ["WINDOWED"]}, {solitaryBlockedBy: ["CANDIDATE"]}];
        compare(Machine.compositorLockStateLazy(2, i => { reads.push(i); return unlocked[i]; }), "unlocked");
        compare(reads, [0, 1]);
        // Bad counts read nothing and prove nothing.
        compare(Machine.compositorLockStateLazy(undefined, i => locked[i]), "unknown");
        compare(Machine.compositorLockStateLazy(0, i => locked[i]), "unknown");
    }

    // Review of the lock's monitor queries (Quickshell 0.3.1, read in its source): a query from QML never creates a monitor
    // object and, sent before Hyprland answered Quickshell's own first query, leaves Hyprland.monitors empty until a monitor
    // event. The lock sends none while the model is empty (Lock.qml requestMonitors); an empty model is an unknown lock
    // state, never "unlocked": no relock, no "nothing stranded", WlSessionLock keeps the session locked (fail closed).
    function test_monitorQueryAllowed() {
        compare(Machine.monitorQueryAllowed(0), false);
        compare(Machine.monitorQueryAllowed(1), true);
        compare(Machine.monitorQueryAllowed(2), true);
        // Anything that is not a positive count is an empty model: no query.
        const empty = [undefined, null, NaN, -1, 0.5, "2", true, [1], {}];
        for (let i = 0; i < empty.length; i++)
            compare(Machine.monitorQueryAllowed(empty[i]), false, String(empty[i]));
        // The state an empty model gives, whatever its (absent) monitors would say.
        const unlocked = () => ({solitaryBlockedBy: ["WINDOWED"]});
        compare(Machine.compositorLockStateLazy(0, unlocked), "unknown");
        compare(Machine.compositorLockState([]), "unknown");
        compare(Machine.ownershipAction(Machine.compositorLockStateLazy(0, unlocked), 0), "unknown");
        compare(Machine.ownershipAction(Machine.compositorLockStateLazy(0, unlocked), 1), "unknown");
    }

    function test_displayNameAndInitials() {
        const passwd = "root:x:0:0::/root:/bin/bash\nada:x:1000:1000:Ada Lovelace,,,:/home/ada:/bin/bash\nbob:x:1001:1001::/home/bob:/bin/sh\n";
        compare(Machine.displayName(passwd, "ada"), "Ada Lovelace");
        compare(Machine.displayName(passwd, "bob"), "bob");
        compare(Machine.displayName(passwd, "eve"), "eve");
        compare(Machine.initials("Ada Lovelace"), "AL");
        compare(Machine.initials("alex"), "A");
        compare(Machine.initials("  "), "");
    }

    // Review of 423766f: the account picture is only ever a PNG the shell made (ThemeIcons), ~/.face first.
    function test_avatarSource() {
        const made = {"/home/a/.face": "file:///run/x/1.png", "/var/lib/AccountsService/icons/a": "file:///run/x/2.png"};
        let states = {};
        const asked = [];
        const source = p => {
            asked.push(p);
            return states[p] === "ok" ? made[p] : "";
        };
        const state = p => states[p] || "";
        compare(Machine.avatarSource("/home/a/.face", "/var/lib/AccountsService/icons/a", source, state), "", "nothing made yet: the initials");
        compare(asked, ["/home/a/.face"], "the AccountsService picture is not asked while ~/.face is pending");
        states = {"/home/a/.face": "ok"};
        compare(Machine.avatarSource("/home/a/.face", "/var/lib/AccountsService/icons/a", source, state), "file:///run/x/1.png");
        states = {"/home/a/.face": "no", "/var/lib/AccountsService/icons/a": "ok"};
        compare(Machine.avatarSource("/home/a/.face", "/var/lib/AccountsService/icons/a", source, state), "file:///run/x/2.png", "~/.face refused: AccountsService");
        states = {"/home/a/.face": "no", "/var/lib/AccountsService/icons/a": "no"};
        compare(Machine.avatarSource("/home/a/.face", "/var/lib/AccountsService/icons/a", source, state), "", "both refused: the initials");
        states = {"/var/lib/AccountsService/icons/a": "ok"};
        compare(Machine.avatarSource("", "/var/lib/AccountsService/icons/a", source, state), "file:///run/x/2.png", "no HOME");
        compare(Machine.avatarSource("", "", source, state), "");
        compare(Machine.accountsIconPath("ada"), "/var/lib/AccountsService/icons/ada");
        ["", "../root", ".hidden", "a/b", "a\nb", null, undefined, "x".repeat(65)].forEach(u => compare(Machine.accountsIconPath(u), "", "refused: " + u));
    }

    function test_capsLockInference() {
        compare(Machine.capsLockFromKey("A", false), true);
        compare(Machine.capsLockFromKey("a", false), false);
        compare(Machine.capsLockFromKey("a", true), true);
        compare(Machine.capsLockFromKey("A", true), false);
        compare(Machine.capsLockFromKey("1", false), null);
        compare(Machine.capsLockFromKey("", false), null);
    }

    function test_clockFormat() {
        compare(Machine.clockFormat("h:mm AP"), "h:mm");
        compare(Machine.clockFormat("HH:mm"), "H:mm");
    }

    // UI audit 2026-11-05 U24: the month first where the region writes it first, else the pattern as translated.
    function test_datePattern() {
        compare(Machine.datePattern("dddd d MMMM", "M/d/yy"), "dddd, MMMM d");
        compare(Machine.datePattern("dddd d MMMM", "dd/MM/yyyy"), "dddd d MMMM");
        compare(Machine.datePattern("dddd d MMMM", "yyyy-MM-dd"), "dddd, MMMM d");
        compare(Machine.datePattern("dddd d MMMM", "'d' M/d"), "dddd, MMMM d");
        compare(Machine.datePattern("dddd d MMMM", ""), "dddd d MMMM");
        compare(Machine.datePattern("dddd d MMMM", undefined), "dddd d MMMM");
        // A translated pattern of another shape is left alone.
        compare(Machine.datePattern("dddd, d. MMMM", "M/d/yy"), "dddd, d. MMMM");
    }

    // Lock.currentlySecure() (Omarchy 4.0.6 port): only locked/authenticating hold a lock; anything else waits.
    function test_isHolding() {
        verify(Machine.isHolding("locked"));
        verify(Machine.isHolding("authenticating"));
        verify(Machine.isHolding("releasing"));
        const others = ["unlocked", "locking", "", "LOCKED", undefined, null, "garbage"];
        for (let i = 0; i < others.length; i++)
            verify(!Machine.isHolding(others[i]), String(others[i]));
    }

    // Fingerprint pacing (port of Omarchy v4.5.0 FingerprintModel.js, docs/specs/security.md "Fingerprint pacing"): an
    // attempt that reached the reader and did not end fast clears the misses; anything else is one more miss.
    function test_fingerprintMisses() {
        compare(Machine.fingerprintMisses(0, true, false), 0, "reached, ended normally");
        compare(Machine.fingerprintMisses(5, true, false), 0, "a reached attempt is the recovery");
        compare(Machine.fingerprintMisses(5, true, undefined), 0, "no fast-end flag: not fast");
        compare(Machine.fingerprintMisses(0, false, false), 1, "never reached");
        compare(Machine.fingerprintMisses(2, false, false), 3);
        compare(Machine.fingerprintMisses(0, true, true), 1, "reached, then failed on the device at once");
        compare(Machine.fingerprintMisses(4, true, true), 5);
        compare(Machine.fingerprintMisses(0, "yes", false), 1, "only true means reached");
        const junk = [undefined, null, NaN, -3, Infinity, "2", {}];
        for (let i = 0; i < junk.length; i++)
            compare(Machine.fingerprintMisses(junk[i], false, false), 1, "junk count " + String(junk[i]) + " reads as none");
        compare(Machine.fingerprintMisses(2.7, false, false), 3, "a fractional count is floored");
        compare(Machine.fingerprintMisses(1e9, false, false), 1001, "the count stays bounded");
    }

    // The gap before the next attempt: 1 s (as before the port) after none or one miss, then doubling to the 40 s cap,
    // which is longer than fprintd's 30 s idle exit (a wedged claim can clear).
    function test_fingerprintRetryMs() {
        compare(Machine.FINGERPRINT_RETRY_MS, 1000);
        compare(Machine.FINGERPRINT_FAST_END_MS, 2000);
        compare(Machine.FINGERPRINT_RETRY_CAP_MS, 40000);
        compare(Machine.FINGERPRINT_UNAVAILABLE_AFTER, 3);
        verify(Machine.FINGERPRINT_RETRY_CAP_MS > 30000, "longer than fprintd's idle exit");
        // Fractional counts are floored, never below the plain gap (0.5 must not give 500 ms).
        const expected = [[0, 1000], [0.5, 1000], [1, 1000], [1.5, 1000], [2, 2000], [2.9, 2000], [3, 4000], [4, 8000], [5, 16000], [6, 32000], [7, 40000], [8, 40000], [50, 40000], [1e9, 40000]];
        for (let i = 0; i < expected.length; i++)
            compare(Machine.fingerprintRetryMs(expected[i][0]), expected[i][1], "misses " + expected[i][0]);
        const junk = [undefined, null, NaN, -1, Infinity, "7", {}];
        for (let i = 0; i < junk.length; i++)
            compare(Machine.fingerprintRetryMs(junk[i]), 1000, "junk count " + String(junk[i]) + " reads as none");
        // Never shorter than the plain gap, never longer than the cap, never shrinking as misses grow.
        let previous = 0;
        for (let m = 0; m <= 40; m++) {
            const ms = Machine.fingerprintRetryMs(m);
            verify(ms >= Machine.FINGERPRINT_RETRY_MS && ms <= Machine.FINGERPRINT_RETRY_CAP_MS && ms >= previous, "misses " + m + ": " + ms);
            previous = ms;
        }
    }

    // Opus review of 59a576f1, MINOR 1: an attempt still unreached after 20 s ends (a claim that never prompts) and is a miss,
    // so the backoff paces the next one; 20 s is above the fast-end window and below the 25 s D-Bus method timeout of the claim.
    function test_fingerprintReachTimeout() {
        compare(Machine.FINGERPRINT_REACH_TIMEOUT_MS, 20000);
        verify(Machine.FINGERPRINT_REACH_TIMEOUT_MS > Machine.FINGERPRINT_FAST_END_MS);
        verify(Machine.FINGERPRINT_REACH_TIMEOUT_MS < 25000, "ends before the D-Bus claim timeout");
        // A timed-out attempt never reached the reader: it is a miss whatever the fast-end window says.
        compare(Machine.fingerprintMisses(0, false, false), 1);
        compare(Machine.fingerprintMisses(0, false, true), 1);
        // Claims that keep timing out reach the cap: one attempt per 20 s + 40 s at most.
        let misses = 0;
        for (let i = 0; i < 10; i++)
            misses = Machine.fingerprintMisses(misses, false, false);
        compare(Machine.fingerprintRetryMs(misses), Machine.FINGERPRINT_RETRY_CAP_MS);
    }

    // Opus review of 59a576f1, MINOR 2: a resume offers the reader again only to a lock (any lock state), with the PAM file,
    // and not after MaxTries; a resume while unlocked leaves no pass for the next lock (one attempt with the displays off).
    function test_fingerprintOfferedOnResume() {
        const lockStates = ["locking", "locked", "authenticating", "releasing"];
        for (let i = 0; i < lockStates.length; i++)
            verify(Machine.fingerprintOfferedOnResume(true, false, lockStates[i]), lockStates[i]);
        verify(!Machine.fingerprintOfferedOnResume(true, false, "unlocked"), "a resume while unlocked offers nothing");
        verify(!Machine.fingerprintOfferedOnResume(false, false, "locked"), "no fingerprint PAM file");
        verify(!Machine.fingerprintOfferedOnResume(true, true, "locked"), "MaxTries spent the reader");
        verify(!Machine.fingerprintOfferedOnResume("yes", false, "locked"), "only true means the file exists");
        const junk = [undefined, null, "", "LOCKED", "open", 3, {}];
        for (let i = 0; i < junk.length; i++)
            verify(!Machine.fingerprintOfferedOnResume(true, false, junk[i]), "unknown state " + String(junk[i]));
    }

    // D-4: the lid locks unless a physical external display is active (clamshell, macOS); unreadable input locks.
    function test_lidShouldLock() {
        verify(Machine.lidShouldLock(["eDP-1"]));
        verify(Machine.lidShouldLock([]));
        verify(Machine.lidShouldLock(["eDP-1", "HEADLESS-1"]), "a headless output is not a display in use");
        verify(Machine.lidShouldLock(["WAYLAND-1", "GF-REF"]), "nested outputs are not external displays");
        verify(Machine.lidShouldLock(["LVDS-1", "DSI-1"]));
        verify(Machine.lidShouldLock(["eDP-1", "DPX-1", "HDMI-1", "dp-1", "DP-"]), "not a DRM connector name");
        verify(Machine.lidShouldLock(undefined));
        verify(Machine.lidShouldLock(null));
        verify(Machine.lidShouldLock("DP-1"), "a string is not a list of names");
        const docked = [["eDP-1", "DP-1"], ["DP-3"], ["eDP-1", "HDMI-A-1"], ["eDP-1", "DVI-D-2"], ["VGA-1"], ["eDP-1", "USB-1"]];
        for (let i = 0; i < docked.length; i++)
            verify(!Machine.lidShouldLock(docked[i]), docked[i].join(","));
    }
}
