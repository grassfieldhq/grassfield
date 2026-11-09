.pragma library

// Pure helpers of the idle module (tests/security/tst_idlemodel.qml).

var DEFAULT_MINUTES = 5;
var MAX_MINUTES = 240;
// The screen dims this many seconds before the idle lock (ADR-0010: dim at T-10 s).
var DIM_LEAD_SECONDS = 10;

// lock.idleMinutes (grassfield.json, 0..240, 0 = never) → idle timings. Invalid values fall
// back to the default rather than disabling the lock: only an exact 0 means never. Only a number is a number: false, "0",
// null and [0] convert to 0 in JavaScript and would switch the lock off. The value arrives here already read by the settings
// store through the contract (SettingsContract.normalize, rule zeroIsExact): a value above 240 is 240 there (the lock still
// fires), a fraction is rounded, and a negative number or a fraction that rounds to 0 is 5. This function is a backstop for
// anything else and is stricter on purpose (above 240 or a fraction: the default 5, sooner than the contract's reading); it
// never answers "never" for anything but a number that is exactly 0.
function timings(minutes) {
    var m = minutes;
    if (typeof m !== "number" || !isFinite(m) || m < 0 || m > MAX_MINUTES || Math.floor(m) !== m)
        m = DEFAULT_MINUTES;
    var lockSeconds = m * 60;
    var dimSeconds = Math.max(1, lockSeconds - DIM_LEAD_SECONDS);
    return {
        enabled: m > 0,
        lockSeconds: lockSeconds,
        dimSeconds: dimSeconds,
        lockDelayMs: (lockSeconds - dimSeconds) * 1000
    };
}

// The idle monitor (dim, then lock) is armed: idle locking is on (lock.idleMinutes > 0), the session is not locked, the
// monitor is not being re-armed, and no application holds an org.freedesktop.ScreenSaver idle inhibitor (GF-016,
// reported by the menu bridge; Wayland idle inhibitors are honoured by the compositor's idle-notify protocol). Anything
// but an explicit `true` for the inhibitor counts as not inhibited (fail closed: the idle lock works). A lock request
// (manual, lid, before sleep) never asks this.
function idleArmed(enabled, locked, rearming, busInhibited) {
    return enabled === true && locked !== true && rearming !== true && busInhibited !== true;
}

// Display power-off on the lock screen (D-4, macOS turns the display off soon after locking): seconds without input
// while locked before the displays go off (Hyprland DPMS); any input switches them on again.
var DISPLAY_OFF_SECONDS = 30;

// While a lock is being acquired, "on" is sent again this often, at most this many times: a lost request (a restarted shell,
// a dispatch the compositor refused) must not keep the lock undrawn, hence unconfirmed, until input; a lock that cannot hold
// (no display connected) is not woken all night.
var ACQUIRE_DISPLAYS_ON_MS = 2000;
var ACQUIRE_DISPLAYS_ON_TRIES = 5;

// A resume from sleep lights the lock screen (macOS: waking the computer lights its displays; without input they go off again
// after the lock screen's delay; the owner's rc6 report: "waking from sleep is very slow"). Hyprland keeps the displays off
// across a suspend that started with them off (the automatic sleep always does), and the key that woke the computer is usually
// not delivered as input, so they stayed dark until a second input. Only when this module turned them off (`displayOff`) and
// the session is locked (`locked`, Lock.locked: the lock before sleep is the sleep inhibitor's; a session found unlocked at the
// resume is locked first by afterResume), and no new sleep is under way (`sleeping`, SleepInhibitor.sleeping: a sleep that
// started before the wake was due is not lit; review of c94e3195): display only, exact values only (anything else changes
// nothing).
function wakeAtResume(displayOff, locked, sleeping) {
    return displayOff === true && locked === true && sleeping === false;
}

// How long after logind's PrepareForSleep(false) the lock screen is lit: the outputs are coming back then (a DPMS commit that
// fails is retried only once by Hyprland 0.56.2), so the request waits a moment. A monotonic Timer: the time asleep never counts.
var RESUME_WAKE_MS = 1500;

// Display power-off while the session is unlocked (macOS 27 Lock Screen: Turn display off on battery / on power adapter when
// inactive): the minutes of the power source in use, as seconds; 0 = never. The values arrive read through the contract
// (integers 0..240); anything else is never: turning the displays off is not what keeps the session safe (the lock is, and it
// does not depend on this).
function inactiveDisplayOffSeconds(batteryMinutes, powerMinutes, onBattery) {
    var m = onBattery === true ? batteryMinutes : powerMinutes;
    if (typeof m !== "number" || !isFinite(m) || m <= 0 || m > MAX_MINUTES || Math.floor(m) !== m)
        return 0;
    return m * 60;
}

// The unlocked display-off monitor is armed: a delay is set, it is not being re-armed, and no application holds an idle
// inhibitor (a video plays). While locked it stays armed only when it had already turned the displays off (`offForInactivity`):
// the lock that follows keeps them dark until input, instead of lighting them for its own display-off delay.
function inactiveOffArmed(seconds, locked, offForInactivity, rearming, busInhibited) {
    return seconds > 0 && (locked !== true || offForInactivity === true) && rearming !== true && busInhibited !== true;
}

// When a display that turned off for inactivity locks the session (ADR-0040 IQ-T4 A, lock.requirePasswordAfterDisplayOff):
// 0 at once, a delay in ms, or -1 never. Anything unknown reads as at once (fail closed: the stricter choice).
var REQUIRE_AFTER_DISPLAY_OFF_MS = {immediately: 0, "5s": 5000, "1m": 60000, "5m": 300000, "15m": 900000, "1h": 3600000, never: -1};

function requireAfterDisplayOffMs(choice) {
    return typeof choice === "string" && Object.prototype.hasOwnProperty.call(REQUIRE_AFTER_DISPLAY_OFF_MS, choice) ? REQUIRE_AFTER_DISPLAY_OFF_MS[choice] : 0;
}

// The idle dim stays until the lock it led to holds (ADR-0040 ID-8), at most this long: a lock that never confirms does not
// leave the screen dimmed for ever (the lock itself keeps trying; the dim is display only).
var DIM_UNTIL_LOCK_MAX_MS = 5000;

// The displays are off: the lock screen's monitor is idle, or the unlocked one turned them off (`inactiveOff`), but never
// while a lock is being acquired (locked, not holding yet): the compositor confirms a lock only once it has drawn it on every
// display, and a display that is off draws nothing (review of 6e61829: the sleep inhibitor would wait out its budget and the
// ownership check would not run). Once the lock holds, a session that went dark for inactivity is dark again.
function displaysOff(lockedIdle, inactiveOff, locked, holding) {
    if (lockedIdle === true)
        return true;
    return inactiveOff === true && (locked !== true || holding === true);
}

// ---- Automatic sleep (macOS 27 Energy and Battery > Options: the computer sleeps once the displays are off for
// inactivity, unless "Prevent automatic sleeping when the display is off" is on). The idle lock, the display-off lock and
// the lock screen's display power-off above never read it (timings, idleArmed, inactiveOffArmed, requireAfterDisplayOffMs,
// displaysOff take no part of it). The one lock it can cause is autoSleepAction's "lock": a lock requested before a sleep
// on a session that is not locked yet, which only ever adds a lock (never removes, delays or skips one). The computer is
// only put to sleep by Grassfield while its own lock is confirmed and in the LOCKED state. ----

// Seconds the displays stay off without input before the computer sleeps (macOS sleeps about a minute after the display).
var AUTO_SLEEP_SECONDS = 60;

// A request that did not put the computer to sleep (logind refused it: an application's sleep block inhibitor, a download)
// or a wake without input is tried again this often while the displays stay off: never a tight loop. A monotonic Timer, so
// the time asleep does not count.
var AUTO_SLEEP_RETRY_MS = 300000;

// Automatic sleep is prevented unless energy.preventSleep is exactly false, on battery and on the power adapter alike
// (integrator decision 2026-11-04: Grassfield and Omarchy never suspended a computer by itself, the owner runs long builds
// and agents on battery too, and asked for a way to PREVENT sleep; macOS has no switch for battery). The value arrives read
// through the contract (a boolean, default true); anything else keeps the computer awake: a value that cannot be read gives
// back the behaviour from before the setting, never a sleep.
function sleepPrevented(preventSleep) {
    return preventSleep !== false;
}

// The retry Timer runs: the monitor is armed (displays off for lack of input, not prevented, no ScreenSaver cookie) and a
// lock or a suspend was already asked for in this display-off period. Exact values only.
function autoSleepRetryArmed(armed, asked) {
    return armed === true && asked === true;
}

// The automatic sleep monitor is armed: this module turned the displays off for lack of input (the unlocked display-off
// monitor or the lock screen's), sleep is not prevented, and no application holds an org.freedesktop.ScreenSaver inhibitor
// (Wayland idle inhibitors: the monitor respects them). Anything but these exact values disarms it (fail awake).
function autoSleepArmed(displaysOff, prevented, busInhibited) {
    return displaysOff === true && prevented === false && busInhibited !== true;
}

// What a due automatic sleep does, from the lock's state machine state (LockMachine.js, read afresh: Lock.currentState())
// and Lock.currentlySecure() (confirmed by the compositor and verified): "suspend" only in LOCKED with the lock secure;
// "lock" only when the session is exactly UNLOCKED (the lock first; the sleep waits for the next due time, after it holds);
// "wait" in every other case: LOCKING, AUTHENTICATING (a password or a fingerprint being checked), RELEASING (the unlock's
// fade: a fingerprint success just before the due time must not start a sleep), LOCKED but not secure yet, or a state it
// does not know. Never "suspend" on an unlocked, unconfirmed or opening session (review of 95dab794: `holding` alone
// includes AUTHENTICATING and RELEASING and skips the verification).
function autoSleepAction(state, secure) {
    if (state === "locked" && secure === true)
        return "suspend";
    if (state === "unlocked")
        return "lock";
    return "wait";
}

// An automatic sleep is due: the monitor is armed, no input and no idle inhibitor for the delay (`idle`), the delay passed
// since the displays went off (`waited`), and nothing was asked for yet in this attempt. Exact values only.
function autoSleepDue(armed, idle, waited, asked) {
    return armed === true && idle === true && waited === true && asked !== true;
}

// What a change of the lock (its state or its secure flag) does to a pending automatic sleep: "recheck" only once the
// lock is LOCKED and secure (a lock that settled after the due time); "end" when the session is UNLOCKED (the user is back:
// an unlock ends that attempt, so it can never lead to the lock-first path and undo the unlock; review of 2a19231d: a
// fingerprint touch over the due time answered "wait", then "lock" once UNLOCKED); "none" otherwise (LOCKING,
// AUTHENTICATING, RELEASING, LOCKED not secure yet, a state it does not know).
function autoSleepOnLockChange(state, secure) {
    if (state === "locked" && secure === true)
        return "recheck";
    if (state === "unlocked")
        return "end";
    return "none";
}

// Sleep inhibitor and PrepareForSleep watcher restarts (GF-030: never given up silently). A child that exits within
// FAST_EXIT_MS of its start is a failure; MAX_FAST_FAILURES in a row make the module "degraded" (a notice tells the user)
// and the child is then retried every SLOW_RETRY_MS instead of every FAST_RETRY_MS, for as long as the shell runs.
var FAST_EXIT_MS = 2000;
var MAX_FAST_FAILURES = 5;
var FAST_RETRY_MS = 5000;
var SLOW_RETRY_MS = 60000;
// A child must show progress within PROGRESS_BUDGET_MS of its start (the inhibitor: the line its command prints once
// systemd-inhibit holds the lock; the watcher: watcherSubscribed). One that runs without it is hung: it is stopped and
// counted as a failure (review of eee45cc: a hung child counted as healthy, so the user was never told that the screen
// may not lock before sleep). 35 s: above sd-bus' and GDBus' default method call timeout (25 s), so a slow but healthy
// logind (systemd-inhibit's Inhibit call, gdbus' GetNameOwner) is waited for rather than killed on every retry (review of
// 100692f); a hung child still costs only the sleep delay, the lock arms anyway.
var PROGRESS_BUDGET_MS = 35000;

// The PrepareForSleep watcher is subscribed: `gdbus monitor --dest org.freedesktop.login1` prints this line from its
// name watcher, which GLib starts after it sent the signal subscription (AddMatch); the bus answers one connection's
// messages in order, so once the owner is known the match is in place. Its first line ("Monitoring signals ...") is
// printed before subscribing and proves nothing (review of 100692f). From GLib's gdbus-tool source order; not observed
// at runtime here (no system bus in the sandbox).
function watcherSubscribed(line) {
    return typeof line === "string" && line.indexOf("The name org.freedesktop.login1 is owned by ") === 0;
}

// Consecutive fast failures after a child exited: `ranLong` is true only when it ran at least FAST_EXIT_MS AND showed
// progress (SleepInhibitor times that with Timers, a monotonic clock: review of 2dfd992, a wall-clock step forward made an
// early exit look long and hid the failure; review of eee45cc, a hung child looked healthy). Anything else (false, unknown,
// a child that never started or never progressed) counts as a failure.
function failuresAfterRun(failures, ranLong) {
    var n = Number(failures);
    if (!isFinite(n) || n < 0)
        n = 0;
    return ranLong === true ? 0 : n + 1;
}

// Delay before the next restart of a child after `failures` consecutive fast failures.
function retryDelayMs(failures) {
    return Number(failures) >= MAX_FAST_FAILURES ? SLOW_RETRY_MS : FAST_RETRY_MS;
}

function degraded(failures) {
    return Number(failures) >= MAX_FAST_FAILURES;
}

// How long the sleep delay may wait for a confirmed lock, from logind's InhibitDelayMaxUSec as printed by
// `busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager InhibitDelayMaxUSec`
// ("t 15000000"). logind suspends when its window expires, locked or not: keep a fifth of the window (at least 1 s) for
// logind to act on the release, and cap at 12 s so that a raised window cannot strand a closed laptop in a bag (port
// of Omarchy's omarchy-system-sleep-lock derive_budget_ms, MIT). Unreadable: logind's default window, 5 s -> 4 s.
// Omarchy ships InhibitDelayMaxSec=15 because a lid close that reconfigures displays can take longer than 4 s to lock.
var BUDGET_CAP_MS = 12000;

function sleepBudgetMs(busctlOutput) {
    var m = String(busctlOutput || "").match(/^\s*t\s+([0-9]+)\s*$/);
    var windowMs = m ? Math.floor(Number(m[1]) / 1000) : 0;
    if (!isFinite(windowMs) || windowMs <= 0)
        windowMs = 5000;
    var budget = windowMs - Math.max(Math.floor(windowMs / 5), 1000);
    return Math.max(0, Math.min(budget, BUDGET_CAP_MS));
}

// One line of `gdbus monitor --system --dest org.freedesktop.login1 --object-path
// /org/freedesktop/login1`. Returns true (about to sleep), false (resumed) or null.
function prepareForSleep(line) {
    var m = String(line || "").match(/org\.freedesktop\.login1\.Manager\.PrepareForSleep \((true|false),?\)/);
    return m ? m[1] === "true" : null;
}

// ---- The applications' org.freedesktop.ScreenSaver inhibitors, leased by the UI (ADR-0041 step 1, S2) ----
// The menu bridge serves those inhibitors to the UI process; the idle module runs in the security process. The UI renews a
// lease every INHIBIT_RENEW_MS while an application holds one (`idle inhibit <seconds>`), and the lease ends by itself
// INHIBIT_MAX_SECONDS at most after the last renewal: a UI that stopped or crashed while a video played keeps the idle lock
// off for one lease at most, never for good.
var INHIBIT_RENEW_MS = 60000;
var INHIBIT_MAX_SECONDS = 150;

// The lease in ms for `idle inhibit <seconds>`: 0 (ends it) for 0, a negative value or anything that is not a whole number;
// otherwise bounded by INHIBIT_MAX_SECONDS.
function inhibitLeaseMs(seconds) {
    if (typeof seconds !== "number" || !isFinite(seconds) || Math.floor(seconds) !== seconds || seconds <= 0)
        return 0;
    return Math.min(seconds, INHIBIT_MAX_SECONDS) * 1000;
}

// ---- The UI's screen saver, as the security process counts it (ADR-0041 step 1, S3) ----
// The screen saver is the UI's (shell/saver, ADR-0032): after screensaver.idleMinutes without input while the session is
// unlocked, no application inhibits idle and the monitor is not being re-armed. The polkit sheet and the secret sheets run
// in the security process and hold a request while it may show; that process counts the same idle time by the same rule
// (shell/saver/SaverModel.js `armed`; tests/security/tst_idlemodel.qml compares the two), so it reads nothing from the UI.
var SAVER_MAX_SECONDS = 240 * 60;

// The saver's delay in seconds for screensaver.idleMinutes (Settings normalizes it; as the saver, minutes x 60): 0 (never)
// for anything that is not a finite number.
function saverSeconds(minutes) {
    return typeof minutes === "number" && isFinite(minutes) ? minutes * 60 : 0;
}

// The saver's monitor counts (SaverModel.armed's rule).
function saverArmed(seconds, locked, busInhibited, rearming) {
    return seconds > 0 && seconds <= SAVER_MAX_SECONDS && locked !== true && busInhibited !== true && rearming !== true;
}
