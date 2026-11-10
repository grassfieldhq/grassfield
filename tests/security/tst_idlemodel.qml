import QtQuick
import QtTest
import "../../shell/security/idle/IdleModel.js" as IdleModel
import "../../shell/security/LockMachine.js" as Machine
import "../../shell/saver/SaverModel.js" as SaverModel

TestCase {
    name: "IdleModel"

    function test_defaultTimings() {
        const t = IdleModel.timings(5);
        verify(t.enabled);
        compare(t.lockSeconds, 300);
        compare(t.dimSeconds, 290);
        compare(t.lockDelayMs, 10000);
    }

    // GF-016: an application's org.freedesktop.ScreenSaver inhibitor holds the idle dim and lock; nothing else changes.
    function test_idleArmed() {
        verify(IdleModel.idleArmed(true, false, false, false));
        verify(!IdleModel.idleArmed(true, false, false, true), "inhibited over D-Bus");
        verify(!IdleModel.idleArmed(false, false, false, false), "idle lock off");
        verify(!IdleModel.idleArmed(true, true, false, false), "already locked");
        verify(!IdleModel.idleArmed(true, false, true, false), "re-arming");
        // Only an explicit true inhibits (a missing or odd value never disarms the idle lock).
        verify(IdleModel.idleArmed(true, false, false, undefined));
        verify(IdleModel.idleArmed(true, false, false, "true"));
        verify(IdleModel.idleArmed(true, false, false, 1));
    }

    function test_zeroDisables() {
        verify(!IdleModel.timings(0).enabled);
    }

    // Omarchy 4.0.6 drift review (docs/specs/security.md "Upstream base"): upstream stopped binding its lock timer's
    // interval to the settings, because a settings change restarted a pending timer and locked early or late. Idle.qml
    // still binds lockTimer.interval, which is safe only while that interval is the same for every enabled setting (a
    // change of lock.idleMinutes then never changes it) and the idle monitor's timeout is never 0 (idle at once).
    function test_lockDelaySameForEverySetting() {
        for (let m = 0; m <= IdleModel.MAX_MINUTES; m++) {
            const t = IdleModel.timings(m);
            verify(t.dimSeconds >= 1, "dimSeconds at " + m + " min: " + t.dimSeconds);
            if (m > 0)
                compare(t.lockDelayMs, IdleModel.DIM_LEAD_SECONDS * 1000, "lockDelayMs at " + m + " min");
        }
    }

    function test_invalidFallsBackToDefault() {
        // false, "0", "", null and [0] are 0 to Number(): they must never switch the lock off.
        const values = [-1, 241, 2.5, NaN, undefined, "x", false, true, "0", "5", "", null, [0], {}, 0.4, 0.49, -0.5, 1e-9, -2147483648, -1e308, Infinity, -Infinity];
        for (let i = 0; i < values.length; i++) {
            const t = IdleModel.timings(values[i]);
            verify(t.enabled, String(values[i]));
            compare(t.lockSeconds, 300, String(values[i]));
        }
    }

    // GF-030: a failing inhibitor or watcher is never given up; after MAX_FAST_FAILURES fast exits in a row the module is
    // degraded (the user is told) and retries slowly; a run of FAST_EXIT_MS resets the count.
    // Review of 2dfd992: whether the child ran FAST_EXIT_MS comes from a Timer (monotonic), never from the wall clock.
    function test_failuresAfterRun() {
        compare(IdleModel.failuresAfterRun(0, false), 1);
        compare(IdleModel.failuresAfterRun(4, false), 5);
        compare(IdleModel.failuresAfterRun(7, true), 0);
        compare(IdleModel.failuresAfterRun(undefined, false), 1);
        compare(IdleModel.failuresAfterRun(-2, false), 1);
        compare(IdleModel.failuresAfterRun(2, undefined), 3, "unknown counts as a failure");
        compare(IdleModel.failuresAfterRun(2, 1), 3, "only true resets");
        compare(IdleModel.failuresAfterRun(2, 60000), 3, "a duration is not an answer");
    }

    // Review of eee45cc: a child without progress within PROGRESS_BUDGET_MS is a failure; the budget leaves room for a
    // slow start but is far below the slow retry period.
    function test_progressBudget() {
        compare(IdleModel.PROGRESS_BUDGET_MS, 35000);
        verify(IdleModel.PROGRESS_BUDGET_MS > 25000, "above sd-bus' and GDBus' 25 s default call timeout");
        verify(IdleModel.PROGRESS_BUDGET_MS > IdleModel.FAST_EXIT_MS);
        verify(IdleModel.PROGRESS_BUDGET_MS < IdleModel.SLOW_RETRY_MS);
        compare(IdleModel.failuresAfterRun(4, false), 5, "a hung child stopped by the budget counts as a failure");
    }

    // Review of 100692f: gdbus' first line comes before the subscription; the owner line comes after it.
    function test_watcherSubscribed() {
        verify(IdleModel.watcherSubscribed("The name org.freedesktop.login1 is owned by :1.5"));
        verify(!IdleModel.watcherSubscribed("Monitoring signals on object /org/freedesktop/login1 owned by org.freedesktop.login1"));
        verify(!IdleModel.watcherSubscribed("The name org.freedesktop.login1 does not have an owner"));
        verify(!IdleModel.watcherSubscribed(""));
        verify(!IdleModel.watcherSubscribed(undefined));
    }

    function test_retryNeverStops() {
        for (let n = 0; n < 50; n++) {
            const delay = IdleModel.retryDelayMs(n);
            verify(delay > 0 && delay <= IdleModel.SLOW_RETRY_MS, "failures " + n);
            compare(delay, n >= IdleModel.MAX_FAST_FAILURES ? IdleModel.SLOW_RETRY_MS : IdleModel.FAST_RETRY_MS, "failures " + n);
            compare(IdleModel.degraded(n), n >= IdleModel.MAX_FAST_FAILURES, "failures " + n);
        }
    }

    // Port of Omarchy's derive_budget_ms: a fifth of logind's window (at least 1 s) kept for logind, capped at 12 s.
    function test_sleepBudget() {
        compare(IdleModel.sleepBudgetMs("t 5000000"), 4000);
        compare(IdleModel.sleepBudgetMs("t 15000000\n"), 12000);
        compare(IdleModel.sleepBudgetMs("t 10000000"), 8000);
        compare(IdleModel.sleepBudgetMs("t 60000000"), IdleModel.BUDGET_CAP_MS);
        compare(IdleModel.sleepBudgetMs("t 1000000"), 0);
        const unreadable = ["", "garbage", "t -5", "t 0", "u 5000000", undefined, null];
        for (let i = 0; i < unreadable.length; i++)
            compare(IdleModel.sleepBudgetMs(unreadable[i]), 4000, String(unreadable[i]));
    }

    function test_displayOffAfterLock() {
        verify(IdleModel.DISPLAY_OFF_SECONDS > 0 && IdleModel.DISPLAY_OFF_SECONDS <= 60);
    }

    // A lost "on" while a lock is being acquired is sent again before the lock before sleep runs out of time.
    function test_acquireDisplaysOnRetry() {
        verify(IdleModel.ACQUIRE_DISPLAYS_ON_MS > 0);
        verify(IdleModel.ACQUIRE_DISPLAYS_ON_MS < IdleModel.sleepBudgetMs(""));
        // A few tries, not one per 2 s all night.
        verify(IdleModel.ACQUIRE_DISPLAYS_ON_TRIES >= 2 && IdleModel.ACQUIRE_DISPLAYS_ON_TRIES <= 10);
    }

    // Settings > Lock Screen: Turn display off on battery / on power adapter when inactive (lock.displayOffBattery/Power).
    function test_inactiveDisplayOff() {
        compare(IdleModel.inactiveDisplayOffSeconds(2, 10, true), 120);
        compare(IdleModel.inactiveDisplayOffSeconds(2, 10, false), 600);
        // Not a known battery reading: the power adapter's delay.
        compare(IdleModel.inactiveDisplayOffSeconds(2, 10, undefined), 600);
        compare(IdleModel.inactiveDisplayOffSeconds(0, 10, true), 0);
        // Anything that is not a whole number of minutes in range is never (the lock does not depend on it).
        const bad = [-1, 0.5, 241, NaN, Infinity, "2", true, null, undefined, [2]];
        for (let i = 0; i < bad.length; i++)
            compare(IdleModel.inactiveDisplayOffSeconds(bad[i], bad[i], true), 0, String(bad[i]));
    }

    function test_inactiveOffArmed() {
        verify(IdleModel.inactiveOffArmed(120, false, false, false, false));
        verify(!IdleModel.inactiveOffArmed(0, false, false, false, false), "never");
        verify(!IdleModel.inactiveOffArmed(120, true, false, false, false), "locked: the lock screen's own delay");
        verify(IdleModel.inactiveOffArmed(120, true, true, false, false), "locked after it turned the displays off: they stay off");
        verify(!IdleModel.inactiveOffArmed(120, false, false, true, false), "re-arming");
        verify(!IdleModel.inactiveOffArmed(120, false, false, false, true), "an application inhibits idle");
        verify(IdleModel.inactiveOffArmed(120, false, false, false, "yes"), "only true inhibits");
    }

    function test_displaysOff() {
        // Unlocked: dark after the inactivity delay.
        verify(!IdleModel.displaysOff(false, false, false, false));
        verify(IdleModel.displaysOff(false, true, false, false));
        // The lock screen's own delay.
        verify(IdleModel.displaysOff(true, false, true, true));
        // A lock being acquired is never kept dark: the compositor must draw it to confirm it (review of 6e61829); once it
        // holds, a session that went dark for inactivity is dark again.
        verify(!IdleModel.displaysOff(false, true, true, false));
        verify(IdleModel.displaysOff(false, true, true, true));
        verify(!IdleModel.displaysOff(undefined, "yes", false, false));
    }

    function test_prepareForSleep() {
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)"), true);
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)"), false);
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.SessionNew ('3', '/x')"), null);
        compare(IdleModel.prepareForSleep("Monitoring signals on object /org/freedesktop/login1"), null);
    }

    // ADR-0040 IQ-T4 A: when a display that turned off for inactivity locks the session.
    function test_requireAfterDisplayOffMs() {
        compare(IdleModel.requireAfterDisplayOffMs("immediately"), 0);
        compare(IdleModel.requireAfterDisplayOffMs("5s"), 5000);
        compare(IdleModel.requireAfterDisplayOffMs("1m"), 60000);
        compare(IdleModel.requireAfterDisplayOffMs("5m"), 300000);
        compare(IdleModel.requireAfterDisplayOffMs("15m"), 900000);
        compare(IdleModel.requireAfterDisplayOffMs("1h"), 3600000);
        compare(IdleModel.requireAfterDisplayOffMs("never"), -1);
        // Anything unknown: at once (the stricter choice).
        for (const v of ["", "2m", "Never", undefined, null, 5, "constructor", "toString"])
            compare(IdleModel.requireAfterDisplayOffMs(v), 0, String(v));
        verify(IdleModel.DIM_UNTIL_LOCK_MAX_MS > 0 && IdleModel.DIM_UNTIL_LOCK_MAX_MS <= 10000);
    }

    // ---- Automatic sleep (macOS 27 Energy / Battery > Options…: Prevent automatic sleeping when the display is off;
    // energy.preventSleep, default true; on battery and on the power adapter alike, integrator decision 2026-11-04). ----

    // Only an exact false lets the computer sleep, on battery as on the power adapter; anything else (the default, a value
    // that cannot be read) keeps it awake, as before the setting.
    function test_sleepPrevented() {
        verify(IdleModel.sleepPrevented(true), "the default: prevented");
        verify(!IdleModel.sleepPrevented(false), "switch off: sleeps");
        for (const v of [undefined, null, "false", 0, "", "no", [], {}])
            verify(IdleModel.sleepPrevented(v), "unreadable value " + JSON.stringify(v) + " keeps the computer awake");
        compare(IdleModel.sleepPrevented.length, 1, "no power source parameter: the switch applies on battery too");
        verify(IdleModel.AUTO_SLEEP_SECONDS >= 30 && IdleModel.AUTO_SLEEP_SECONDS <= 120);
    }

    // Armed only while this module has the displays off for lack of input, sleep is not prevented, and no application holds
    // an org.freedesktop.ScreenSaver inhibitor.
    function test_autoSleepArmed() {
        verify(IdleModel.autoSleepArmed(true, false, false));
        verify(!IdleModel.autoSleepArmed(true, true, false), "prevented");
        verify(!IdleModel.autoSleepArmed(false, false, false), "displays on");
        verify(!IdleModel.autoSleepArmed(true, false, true), "an application inhibits idle over D-Bus");
        // Fail awake: odd values never arm it.
        verify(!IdleModel.autoSleepArmed("true", false, false));
        verify(!IdleModel.autoSleepArmed(true, undefined, false), "an unknown prevention is not 'not prevented'");
        verify(!IdleModel.autoSleepArmed(true, 0, false));
        verify(IdleModel.autoSleepArmed(true, false, undefined), "no inhibitor reported");
    }

    // Grassfield suspends only in LOCKED with the lock secure (confirmed and verified); an exactly UNLOCKED session is locked
    // first; every other state waits. The states are LockMachine.js's own.
    function test_autoSleepAction() {
        compare(Machine.LOCKED, "locked");
        compare(Machine.UNLOCKED, "unlocked");
        compare(IdleModel.autoSleepAction(Machine.LOCKED, true), "suspend");
        compare(IdleModel.autoSleepAction(Machine.UNLOCKED, false), "lock");
        compare(IdleModel.autoSleepAction(Machine.UNLOCKED, true), "lock", "a stale secure never suspends an unlocked session");
        compare(IdleModel.autoSleepAction(Machine.LOCKING, false), "wait", "the compositor has not confirmed the lock yet");
        compare(IdleModel.autoSleepAction(Machine.LOCKED, false), "wait", "confirmed but not verified yet");
        compare(IdleModel.autoSleepAction(Machine.AUTHENTICATING, true), "wait", "a password or a fingerprint is being checked");
        compare(IdleModel.autoSleepAction(undefined, true), "wait");
        compare(IdleModel.autoSleepAction("LOCKED", true), "wait");
        compare(IdleModel.autoSleepAction(Machine.LOCKED, "true"), "wait");
    }

    // Review of 95dab794: a fingerprint success just before the 60 s mark moves the lock to RELEASING (the unlock's fade),
    // where Lock.holding and the secure lock are still true. No suspend may start then, at the decision or at the re-check
    // right before systemctl runs.
    function test_noSuspendDuringTheReleaseFade() {
        verify(Machine.isHolding(Machine.RELEASING), "the old decision's input (holding) was true here");
        compare(IdleModel.autoSleepAction(Machine.RELEASING, true), "wait");
        compare(IdleModel.autoSleepAction(Machine.RELEASING, false), "wait");
        // The whole fingerprint path, state by state: only LOCKED (before the success) suspends.
        const path = [Machine.LOCKED, Machine.AUTHENTICATING, Machine.RELEASING, Machine.UNLOCKED];
        compare(path.map(s => IdleModel.autoSleepAction(s, s !== Machine.UNLOCKED)), ["suspend", "wait", "wait", "lock"]);
    }

    // The idle decisions of a session whose displays went off for inactivity (unlocked) or on the lock screen (locked and
    // secure), with the switch on and off, on battery and on the power adapter: what Idle.qml derives from IdleModel.
    function decisions(prevent, onBattery, state) {
        const locked = state !== Machine.UNLOCKED;
        const t = IdleModel.timings(5);
        const prevented = IdleModel.sleepPrevented(prevent);
        const displaysOff = IdleModel.displaysOff(locked, !locked, locked, locked);
        const armed = IdleModel.autoSleepArmed(displaysOff, prevented, false);
        return {
            lock: {
                idleLock: t.enabled,
                lockSeconds: t.lockSeconds,
                idleArmed: IdleModel.idleArmed(t.enabled, locked, false, false),
                inactiveOffArmed: IdleModel.inactiveOffArmed(IdleModel.inactiveDisplayOffSeconds(2, 10, onBattery), locked, !locked, false, false),
                displayOffLockMs: IdleModel.requireAfterDisplayOffMs("immediately"),
                displaysOff: displaysOff
            },
            sleep: armed ? IdleModel.autoSleepAction(state, locked) : "none"
        };
    }

    // The idle lock, the display-off lock and the displays' power-off are the same whatever the switch says, on battery or
    // not; only the sleep differs. No lock function takes the setting: their arity is what it was before it (a new parameter
    // would have to be passed by Idle.qml, and reviewed).
    function test_lockIndependentOfSleep() {
        for (const onBattery of [false, true]) {
            for (const state of [Machine.UNLOCKED, Machine.LOCKED]) {
                const on = decisions(true, onBattery, state);
                const off = decisions(false, onBattery, state);
                const odd = decisions("x", onBattery, state);
                compare(off.lock, on.lock, "battery " + onBattery + ", " + state);
                compare(odd.lock, on.lock);
                verify(on.lock.idleLock && on.lock.lockSeconds === 300 && on.lock.displayOffLockMs === 0);
                verify(on.lock.displaysOff, "the displays still turn off with prevent-sleep on");
            }
        }
        compare(IdleModel.timings.length, 1);
        compare(IdleModel.idleArmed.length, 4);
        compare(IdleModel.inactiveOffArmed.length, 5);
        compare(IdleModel.inactiveDisplayOffSeconds.length, 3);
        compare(IdleModel.requireAfterDisplayOffMs.length, 1);
        compare(IdleModel.displaysOff.length, 4);
    }

    // The integrator decision of 2026-11-04: prevent-sleep on means no automatic sleep, on battery as on the power adapter;
    // off, an unlocked session is locked first and a locked one sleeps, on battery as on the power adapter.
    function test_idleDecisionsWithPreventSleep() {
        for (const onBattery of [false, true]) {
            const where = onBattery ? "battery" : "power adapter";
            compare(decisions(true, onBattery, Machine.UNLOCKED).sleep, "none", where + ", on, unlocked: no sleep");
            compare(decisions(true, onBattery, Machine.LOCKED).sleep, "none", where + ", on, locked: no suspend");
            compare(decisions(false, onBattery, Machine.UNLOCKED).sleep, "lock", where + ", off, unlocked: the lock first");
            compare(decisions(false, onBattery, Machine.LOCKED).sleep, "suspend", where + ", off, locked: suspend");
            compare(decisions(undefined, onBattery, Machine.LOCKED).sleep, "none", where + ": an unreadable setting keeps the computer awake");
        }
    }

    // The automatic sleep only ever ADDS a lock (review of 95dab794: it is the one path where energy.preventSleep leads to a
    // lock). Its answers are suspend, lock or wait over every state and secure value; "lock" only on an UNLOCKED session.
    function test_autoSleepOnlyAddsLocks() {
        const states = [Machine.UNLOCKED, Machine.LOCKING, Machine.LOCKED, Machine.AUTHENTICATING, Machine.RELEASING, "", undefined, null, "x"];
        for (const s of states) {
            for (const secure of [true, false, undefined, "true"]) {
                const a = IdleModel.autoSleepAction(s, secure);
                verify(["suspend", "lock", "wait"].indexOf(a) >= 0, String(s) + "/" + String(secure) + ": " + a);
                if (a === "lock")
                    compare(s, Machine.UNLOCKED, "a lock is only ever requested on an unlocked session");
            }
        }
        // In Idle.qml, the automatic sleep's block calls no Lock function that could unlock, release, abort or delay a lock,
        // and assigns nothing on Lock: its only Lock calls are lock("sleep") and the two read-only getters.
        const text = source();
        const begin = text.indexOf("// ---- Automatic sleep");
        const end = text.indexOf("SleepInhibitor {", begin);
        verify(begin > 0 && end > begin, "the automatic sleep block");
        const block = text.substring(begin, end);
        const calls = block.match(/Lock\.[A-Za-z]+\s*\(/g) || [];
        const kinds = calls.map(c => c.replace(/\s*\($/, "")).filter((c, i, all) => all.indexOf(c) === i).sort();
        compare(kinds, ["Lock.currentState", "Lock.currentlySecure", "Lock.lock"]);
        compare(block.match(/Lock\.lock\("[^"]*"\)/g) || [], ['Lock.lock("sleep")']);
        verify(!/Lock\.[A-Za-z]+\s*=[^=]/.test(block), "nothing assigned on Lock");
        verify(!/unlock|release\(|interruptRelease|abort\(/.test(block.replace(/\/\/[^\n]*/g, "")), "no unlock, release or abort");
    }

    // Review of 95dab794: a refused suspend (a download's sleep block inhibitor) is asked again while the displays stay off,
    // every AUTO_SLEEP_RETRY_MS, never in a tight loop; input disarms it.
    function test_autoSleepRetry() {
        compare(IdleModel.AUTO_SLEEP_RETRY_MS, 300000, "5 minutes");
        verify(IdleModel.AUTO_SLEEP_RETRY_MS >= 5 * IdleModel.AUTO_SLEEP_SECONDS * 1000, "never a tight loop");
        verify(IdleModel.autoSleepRetryArmed(true, true), "displays off, a request was made: retry");
        verify(!IdleModel.autoSleepRetryArmed(true, false), "nothing asked yet: the first request comes from the monitor");
        verify(!IdleModel.autoSleepRetryArmed(false, true), "input (displays on) or prevented: no retry");
        verify(!IdleModel.autoSleepRetryArmed("true", 1), "exact values only");
        // In Idle.qml: a repeating Timer of that interval, running only while armed and asked; it clears the request and
        // decides again (which re-reads the lock and the setting).
        const text = source();
        verify(/id: autoSleepRetry\s*\n\s*interval: IdleModel\.AUTO_SLEEP_RETRY_MS\s*\n\s*repeat: true\s*\n\s*running: IdleModel\.autoSleepRetryArmed\(root\.autoSleepArmed, root\.autoSleepAsked\)/.test(text));
        verify(/id: autoSleepRetry[\s\S]*?onTriggered: \{\s*root\.autoSleepAsked = false;\s*root\.autoSleepCheck\(\);\s*\}/.test(text));
        compare(text.split("\n").filter(l => l.indexOf("root.autoSleepAsked = false") >= 0).length, 4, "the period change, the retry, a re-check that refused, an unlock");
    }

    // What a change of the lock does to a pending automatic sleep: decide again only once LOCKED and secure; an unlock ends
    // the attempt; anything else, nothing.
    function test_autoSleepOnLockChange() {
        compare(IdleModel.autoSleepOnLockChange(Machine.LOCKED, true), "recheck");
        compare(IdleModel.autoSleepOnLockChange(Machine.UNLOCKED, false), "end");
        compare(IdleModel.autoSleepOnLockChange(Machine.UNLOCKED, true), "end");
        for (const s of [Machine.LOCKING, Machine.AUTHENTICATING, Machine.RELEASING, undefined, "x"])
            compare(IdleModel.autoSleepOnLockChange(s, true), "none", String(s));
        compare(IdleModel.autoSleepOnLockChange(Machine.LOCKED, false), "none", "not secure yet");
        verify(IdleModel.autoSleepDue(true, true, true, false));
        verify(!IdleModel.autoSleepDue(true, true, false, false), "the delay has not passed");
        verify(!IdleModel.autoSleepDue(true, true, true, true), "already asked");
        verify(!IdleModel.autoSleepDue(true, false, true, false), "input or an inhibitor");
        verify(!IdleModel.autoSleepDue(false, true, true, false), "disarmed");
        verify(!IdleModel.autoSleepDue("true", true, true, false), "exact values only");
    }

    // Review of 2a19231d, the exact sequence: prevent-sleep off, the displays off on the lock screen, a fingerprint touch over
    // the due time. The due time comes while AUTHENTICATING (wait), then the unlock ends in UNLOCKED: no lock and no suspend,
    // whatever checks run afterwards (the deferred one, the idle monitor, the retry timer), until a new display-off period.
    // The flags and the decisions are Idle.qml's, driven through IdleModel's own functions.
    function test_unlockOverTheDueTimeEndsTheAttempt() {
        const s = {armed: true, idle: true, waited: false, asked: false, state: Machine.AUTHENTICATING, secure: true, actions: []};
        const check = () => {
            if (!IdleModel.autoSleepDue(s.armed, s.idle, s.waited, s.asked))
                return;
            const a = IdleModel.autoSleepAction(s.state, s.secure);
            if (a === "wait")
                return;
            s.asked = true;
            s.actions.push(a);
        };
        const lockChanged = (state, secure) => {
            s.state = state;
            s.secure = secure;
            const next = IdleModel.autoSleepOnLockChange(state, secure);
            if (next === "end") {
                s.waited = false;
                s.asked = false;
            } else if (next === "recheck") {
                check();
            }
        };
        // The due time is reached while the fingerprint is being checked.
        s.waited = true;
        check();
        compare(s.actions, [], "AUTHENTICATING: wait");
        // The fingerprint succeeds: RELEASING (the fade), then UNLOCKED.
        lockChanged(Machine.RELEASING, true);
        compare(s.actions, []);
        lockChanged(Machine.UNLOCKED, false);
        compare([s.waited, s.asked], [false, false], "the unlock ended the attempt");
        // Every later check, in any order (the deferred one, an idle edge, a retry tick, the monitor timer's), does nothing.
        for (let i = 0; i < 3; i++)
            check();
        compare(s.actions, [], "no lock and no suspend after the unlock");
        // Only a new display-off period (the displays came on with the unlock and went off again: armed again, the delay
        // passed again) can lead anywhere, and then from the state as it is then.
        s.armed = false;
        s.armed = true;
        s.waited = true;
        check();
        compare(s.actions, ["lock"], "a new period on an unlocked session: the lock before sleep, as designed");
        // A lock that settles later decides again: LOCKED and secure, suspend.
        s.asked = false;
        lockChanged(Machine.LOCKING, false);
        lockChanged(Machine.LOCKED, true);
        compare(s.actions, ["lock", "suspend"]);
        // In Idle.qml: both lock signals go through autoSleepLockChanged, which ends the attempt or re-checks, never more.
        const text = source();
        verify(/function onSecureChanged\(\): void \{\s*root\.autoSleepLockChanged\(\);\s*\}/.test(text));
        verify(/function onLockStateChanged\(\): void \{\s*root\.autoSleepLockChanged\(\);\s*\}/.test(text));
        verify(/const next = IdleModel\.autoSleepOnLockChange\(Lock\.currentState\(\), Lock\.currentlySecure\(\)\);\s*if \(next === "end"\) \{\s*root\.autoSleepWaited = false;\s*root\.autoSleepAsked = false;\s*\} else if \(next === "recheck"\) \{\s*Qt\.callLater\(root\.autoSleepCheck\);\s*\}/.test(text));
        compare(text.split("\n").filter(l => l.indexOf("Qt.callLater(root.autoSleepCheck)") >= 0).length, 1, "the only deferred check is the recheck");
        verify(/if \(!sleepMonitor\.enabled \|\| !IdleModel\.autoSleepDue\(root\.autoSleepArmed, sleepMonitor\.isIdle, root\.autoSleepWaited, root\.autoSleepAsked\)\)\s*return;/.test(text));
    }

    // The owner's rc6 report ("waking from sleep is very slow"). macOS: waking the computer lights its displays on the lock
    // screen; without input they go off again after the lock screen's delay. Hyprland keeps the displays off across a suspend
    // that started with them off (the automatic sleep always does), and the key that woke the computer is usually not delivered
    // as input, so they stayed dark until a second input. Only a session that is locked is lit, and only when this module had
    // turned the displays off, and never while a new sleep is under way (review of c94e3195): anything else (unknown values
    // included) changes nothing.
    function test_wakeAtResume() {
        verify(IdleModel.wakeAtResume(true, true, false));
        verify(!IdleModel.wakeAtResume(false, true, false));
        verify(!IdleModel.wakeAtResume(true, false, false));
        verify(!IdleModel.wakeAtResume(true, true, true), "a new sleep under way");
        for (const v of [undefined, null, 1, "true", {}])
            verify(!IdleModel.wakeAtResume(v, true, false) && !IdleModel.wakeAtResume(true, v, false) && !IdleModel.wakeAtResume(true, true, v), String(v));
        // The resume is waited on a little (logind sends PrepareForSleep(false) as the outputs come back): a monotonic Timer.
        verify(IdleModel.RESUME_WAKE_MS >= 500 && IdleModel.RESUME_WAKE_MS <= 3000, String(IdleModel.RESUME_WAKE_MS));
    }

    // Idle.qml: the resume path only starts the lock screen's display-off countdown over (its idle monitor and the unlocked one
    // re-armed); it never locks, unlocks, releases or delays a lock, and it reads the decision afresh when the Timer fires.
    function test_resumeLightsTheLockScreenOnly() {
        const text = source();
        const wake = functionBody(text, "wakeAfterResume");
        verify(wake.length > 0, "wakeAfterResume found");
        verify(/^\s*if \(!IdleModel\.wakeAtResume\(root\.displayOff, Lock\.locked, sleepInhibitor\.sleeping\)\)\s*return;/.test(wake), "the decision, read afresh, the sleep in progress included");
        verify(/root\.rearmingInactive = true;\s*root\.rearmingLocked = true;\s*Qt\.callLater\(root\.armAfterResume\);\s*$/.test(wake), "disarmed, then armed again one turn later");
        verify(!/Lock\.(lock|unlock|release|requestUnlock)\(|autoSleep|systemctl|dispatch/.test(wake), "the resume path only re-arms the monitors");
        // The lock screen's monitor is disarmed while re-arming (the displays come on), then armed again: 30 s from now.
        verify(/enabled: Lock\.holding && root\.displayOffSeconds > 0 && !root\.rearmingLocked/.test(text));
        // The Timer is started by the sleep inhibitor's resume, and nothing else starts it.
        verify(/onResumed: resumeWake\.restart\(\)/.test(text));
        compare(text.split("\n").filter(l => l.indexOf("resumeWake.restart()") >= 0).length, 1);
        verify(/Timer \{\s*id: resumeWake\s*interval: IdleModel\.RESUME_WAKE_MS\s*onTriggered: root\.wakeAfterResume\(\)\s*\}/.test(text));
    }

    // Review of c94e3195: without the re-arm the lock screen's display-off stays disarmed for the rest of the session (lit all
    // night, no automatic sleep). The one place that disarms it is wakeAfterResume, the one that arms it again armAfterResume,
    // which sets both flags back to false and does nothing else; nothing else writes them.
    function test_resumeArmsTheMonitorsAgain() {
        const text = source();
        const arm = functionBody(text, "armAfterResume");
        verify(/^\s*root\.rearmingInactive = false;\s*root\.rearmingLocked = false;\s*$/.test(arm), "armAfterResume: " + arm);
        compare(text.split("\n").filter(l => /\brearmingLocked\s*=/.test(l)).length, 2, "rearmingLocked is written twice: true in wakeAfterResume, false in armAfterResume");
        compare(text.split("\n").filter(l => l.indexOf("Qt.callLater(root.armAfterResume)") >= 0).length, 1);
        verify(/property bool rearmingLocked: false/.test(text));
    }

    // Review of c94e3195: the resume Timer does not outlive a new sleep: it stops when the sleep starts (the sleep inhibitor's
    // `sleeping`), and wakeAfterResume reads `sleeping` too (above).
    function test_resumeTimerStopsWhenSleepStarts() {
        const text = source();
        verify(/Connections \{\s*target: sleepInhibitor\s*function onSleepingChanged\(\): void \{\s*if \(sleepInhibitor\.sleeping\)\s*resumeWake\.stop\(\);\s*\}\s*\}/.test(text));
        // The inhibitor's flag the decision reads is the one beforeSleep sets first and afterResume clears.
        const inhibitor = read("../../shell/security/idle/SleepInhibitor.qml");
        verify(/function beforeSleep\(\): void \{\s*console\.info\([^\n]*\);\s*sleeping = true;/.test(inhibitor));
        verify(/property bool sleeping: false/.test(inhibitor));
    }

    // Review of c94e3195: `resumed` is emitted last in afterResume, after its lock decision (a resume this shell did not lock
    // for locks first), the clock refresh, the end of `sleeping` and the inhibitor taken again; and only there.
    function test_resumedIsEmittedLast() {
        const inhibitor = read("../../shell/security/idle/SleepInhibitor.qml");
        const after = functionBody(inhibitor, "afterResume");
        verify(after.length > 0, "afterResume found");
        verify(/Lock\.lock\("resume"\);[\s\S]*Lock\.resumed\(\);\s*sleeping = false;\s*releaseTimer\.stop\(\);\s*take\(\);\s*root\.resumed\(\);\s*$/.test(after), "afterResume: " + after);
        compare(inhibitor.split("\n").filter(l => l.indexOf("root.resumed()") >= 0).length, 1);
    }

    // The body of `function <name>(): void { ... }` at the Scope's indent (four spaces), or "".
    function functionBody(text, name) {
        const m = new RegExp("\\n    function " + name + "\\(\\): void \\{([\\s\\S]*?)\\n    \\}").exec(text);
        return m ? m[1] : "";
    }

    function read(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(path), false);
        xhr.send();
        verify(xhr.responseText.length > 1000, path + " read (QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    function source() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/security/idle/Idle.qml"), false);
        xhr.send();
        verify(xhr.responseText.length > 1000, "Idle.qml read (QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    // Idle.qml: the idle lock and display-off lock paths never read the sleep setting (a source check); the one lock the
    // automatic sleep can request is pinned by test_autoSleepOnlyAddsLocks.
    function test_idleQmlLockPathsIgnoreSleep() {
        const text = source();
        const lines = text.split("\n");
        const lockLines = lines.filter(l => /IdleModel\.(timings|idleArmed|inactiveOffArmed|inactiveDisplayOffSeconds|requireAfterDisplayOffMs|displaysOff)\(|Lock\.lock\("(idle|display-off)"\)/.test(l));
        verify(lockLines.length >= 6, "found the lock paths: " + lockLines.length);
        for (const l of lockLines)
            verify(!/preventSleep|sleepPrevented|autoSleep/.test(l), "a lock path reads the sleep setting: " + l.trim());
        // The setting is read in exactly two places: the binding and the fresh check before acting.
        compare(lines.filter(l => l.indexOf("Settings.energyPreventSleep") >= 0).length, 2);
        // The suspend is asked for only on the "suspend" answer, re-read right before systemctl, and never in the dev session.
        verify(/if \(root\.devHooks\) \{\s*root\.autoSleepSuppressed\+\+;/.test(text));
        compare(lines.filter(l => l.indexOf("autoSleepRequest.running = true") >= 0).length, 1);
        verify(/if \(IdleModel\.autoSleepAction\(Lock\.currentState\(\), Lock\.currentlySecure\(\)\) !== "suspend"\) \{\s*root\.autoSleepAsked = false;\s*return;\s*\}\s*console\.info\([^\n]*\);\s*autoSleepRequest\.running = true;/.test(text),
               "the state is read again right before systemctl runs");
        verify(!/autoSleepAction\([^)]*holding/.test(text), "the decision never uses the holding binding");
        // logind's own suspend, never with --ignore-inhibitors (-i) and never asking for authorization behind the lock.
        verify(text.indexOf('command: ["systemctl", "--no-ask-password", "suspend"]') >= 0);
        verify(!/systemctl[^\n]*(-i\b|--ignore-inhibitors|--force|-f\b)/.test(text));
    }

    // ADR-0041 S3: the polkit and secret sheets run in the security process and hold a request while the UI's screen saver
    // may show; idle counts the same idle time by the saver's own rule (SaverModel.armed), never by anything the UI says.
    function test_saverRuleIsTheSaversOwn() {
        compare(IdleModel.SAVER_MAX_SECONDS, SaverModel.MAX_SECONDS);
        const seconds = [-60, 0, 1, 60, 300, SaverModel.MAX_SECONDS, SaverModel.MAX_SECONDS + 1, NaN];
        const flags = [true, false, undefined, "true"];
        for (const s of seconds)
            for (const locked of flags)
                for (const inhibited of flags)
                    for (const rearming of flags)
                        compare(IdleModel.saverArmed(s, locked, inhibited, rearming), SaverModel.armed(s, locked, inhibited, rearming),
                                [s, locked, inhibited, rearming].join(" "));
        // The delay: Settings' minutes x 60, as the saver's idleSeconds; anything that is not a number is never.
        compare(IdleModel.saverSeconds(5), 300);
        compare(IdleModel.saverSeconds(0), 0);
        compare(IdleModel.saverSeconds("5"), 0);
        compare(IdleModel.saverSeconds(undefined), 0);
        compare(IdleModel.saverSeconds(Infinity), 0);
        verify(!IdleModel.saverArmed(IdleModel.saverSeconds(undefined), false, false, false), "no delay: never shown");
        // The sheets hold more, never less: the count is off while locked (the lock holds them anyway).
        verify(!IdleModel.saverArmed(300, true, false, false));
    }

    // ADR-0041 S3, the opus review's MINOR-1: the sheets' count is only ever early, never late. Restarted while the user was
    // away (Hyprland starts the new monitor's timer from zero), the process reads the saver possibly shown until the user is
    // seen active, whatever its own monitor says; the UI's `idle inhibit` lease never turns the count off.
    function test_sheetsSaverRestartDuringIdle() {
        // The restart, the user away: the new monitor is not idle yet (its timer started at zero), nothing seen.
        compare(IdleModel.sheetsSaverShown(false, true, false), true, "restarted during idle: possibly shown");
        compare(IdleModel.sheetsSaverShown(false, false, false), true, "not armed (locked, rearming, no delay): still held until seen");
        compare(IdleModel.sheetsSaverShown(undefined, true, false), true, "unknown reads not seen");
        // Seen active: the count decides.
        compare(IdleModel.sheetsSaverShown(true, true, false), false);
        compare(IdleModel.sheetsSaverShown(true, true, true), true);
        compare(IdleModel.sheetsSaverShown(true, false, true), false, "a monitor that is not armed says nothing");
        // The start's words (the opus delta review of S3, LOW): held for the start alone, not for the saver's own count.
        compare(IdleModel.sheetsStarting(false, true, false), true, "restarted, the saver not counted: starting");
        compare(IdleModel.sheetsStarting(false, false, false), true);
        compare(IdleModel.sheetsStarting(undefined, true, false), true, "unknown reads not seen");
        compare(IdleModel.sheetsStarting(false, true, true), false, "the saver's own count holds too: the saver's words");
        compare(IdleModel.sheetsStarting(true, true, false), false, "seen active: never starting again");
        compare(IdleModel.sheetsStarting(true, true, true), false);
        for (const seen of [false, true])
            for (const armed of [false, true])
                for (const idle of [false, true])
                    verify(!IdleModel.sheetsStarting(seen, armed, idle) || IdleModel.sheetsSaverShown(seen, armed, idle), "starting only ever words a hold");
        // The probe: idle (a pause), then active (an input) is activity; active from its start is not; once seen, always.
        compare(IdleModel.sheetsActivitySeen(false, false, true), false, "the probe went idle: nothing seen yet");
        compare(IdleModel.sheetsActivitySeen(false, true, false), true, "an input after the pause");
        compare(IdleModel.sheetsActivitySeen(false, false, false), false, "no pause seen: its own start, not an input");
        compare(IdleModel.sheetsActivitySeen(true, false, true), true, "seen stays seen");
        verify(IdleModel.ACTIVITY_PROBE_SECONDS >= 1 && IdleModel.ACTIVITY_PROBE_SECONDS <= 5);
        // The lease: an application's inhibitor (the UI's lease) never disarms the sheets' count; the saver's own rule does.
        compare(IdleModel.sheetsSaverArmed(300, false, false), true);
        compare(IdleModel.saverArmed(300, false, true, false), false, "the saver's rule with an inhibitor");
        compare(IdleModel.sheetsSaverArmed(300, true, false), false, "locked: the lock holds the sheets anyway");
        compare(IdleModel.sheetsSaverArmed(300, false, true), false, "rearming");
        compare(IdleModel.sheetsSaverArmed(0, false, false), false, "no delay");
    }

    // Idle.qml counts it with IdleMonitors armed by that rule from Settings' delay and this process's lock (never the lease),
    // and the host binds it into the sheets' SheetSession (static: the monitors need a compositor).
    function test_saverCountWiring() {
        const idle = source();
        verify(/readonly property int saverSeconds: devHooks \? 0 : IdleModel\.saverSeconds\(Settings\.screenSaverIdleMinutes\)/.test(idle));
        verify(/enabled: timeout === Math\.max\(1, root\.saverSeconds\) && IdleModel\.sheetsSaverArmed\(root\.saverSeconds, Lock\.locked, root\.rearmingSaver\)\n/.test(idle),
               "armed without the lease (review 1, MINOR-1)");
        verify(/readonly property bool saverShown: IdleModel\.sheetsSaverShown\(root\.activitySeen, saverMonitor\.enabled, saverMonitor\.isIdle\)\n/.test(idle));
        verify(/readonly property bool starting: IdleModel\.sheetsStarting\(root\.activitySeen, saverMonitor\.enabled, saverMonitor\.isIdle\)\n/.test(idle),
               "the start's words from the same inputs (the delta review of S3, LOW)");
        verify(/readonly property bool sleeping: sleepInhibitor\.sleeping\n/.test(idle), "a sleep under way, for the polkit agent's tries (round 2, MINOR-A)");
        // The activity probe: on until activity is seen, any input counts (no inhibitor hides it), its state through the model.
        verify(/id: activityProbe\s+enabled: !root\.activitySeen\s+timeout: IdleModel\.ACTIVITY_PROBE_SECONDS\s+respectInhibitors: false\s/.test(idle));
        verify(/const seen = IdleModel\.sheetsActivitySeen\(root\.activitySeen, root\.activityProbeWasIdle, isIdle\);/.test(idle));
        verify(/^    property bool activitySeen: false$/m.test(idle), "not seen at the start");
        compare((idle.match(/root\.activitySeen = /g) || []).length, 1, "set in one place, true only");
        verify(/root\.activitySeen = true;/.test(idle));
        const saver = read("../../shell/saver/Saver.qml");
        verify(/respectInhibitors: true/.test(saver) && /id: saverMonitor[\s\S]*?respectInhibitors: true/.test(idle), "the same Wayland inhibitors as the saver");
    }
}
