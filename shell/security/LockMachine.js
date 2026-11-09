.pragma library

// Lock state machine (ADR-0010) and pure helpers of the lock screen. No Qt or Quickshell types:
// unit-tested offscreen by tests/security/tst_lockmachine.qml.
//
//   unlocked -request-> locking -acquired-> locked -submit-> authenticating
//   authenticating -success-> releasing -released-> unlocked
//   authenticating -failure|error|timeout|abort-> locked
//   locking|locked|authenticating|releasing -lost-> locking   (lock dropped, or the session found unlocked
//                                                              under a lock still reported secure: re-acquire)
//   locked|authenticating -fingerprint-> releasing       (PAM success of omarchy-lock-fingerprint)
//   releasing -request|error|timeout|abort-> locked       (ADR-0040 step 4b: anything during the fade brings the lock back;
//                                                          the PAM success is spent, unlocking needs a new one)
//
// `releasing` (ADR-0040 step 4b, IQ-T2 A): after a PAM success the lock's text and scrim fade out (lock.fadeOutMs) while
// the session is still locked; "released" (the end of that fade) is the only way to "unlocked", and only from
// "releasing", which only a PAM success ("success", "fingerprint") enters. Unknown events and events that do not apply to
// the current state leave the state unchanged (fail closed).

var UNLOCKED = "unlocked";
var LOCKING = "locking";
var LOCKED = "locked";
var AUTHENTICATING = "authenticating";
var RELEASING = "releasing";

var STATES = [UNLOCKED, LOCKING, LOCKED, AUTHENTICATING, RELEASING];
var EVENTS = ["request", "acquired", "lost", "submit", "success", "fingerprint", "failure", "error", "timeout", "abort", "released"];

function next(state, event) {
    if (STATES.indexOf(state) === -1)
        return LOCKING; // corrupted state: never treat it as unlocked
    switch (event) {
    case "request":
        if (state === RELEASING)
            return LOCKED;
        return state === UNLOCKED ? LOCKING : state;
    case "acquired":
        return state === LOCKING ? LOCKED : state;
    case "lost":
        return state === UNLOCKED ? UNLOCKED : LOCKING;
    case "submit":
        return state === LOCKED ? AUTHENTICATING : state;
    case "success":
        return state === AUTHENTICATING ? RELEASING : state;
    case "fingerprint":
        return state === LOCKED || state === AUTHENTICATING ? RELEASING : state;
    case "released":
        return state === RELEASING ? UNLOCKED : state;
    case "failure":
        return state === AUTHENTICATING ? LOCKED : state;
    case "error":
    case "timeout":
    case "abort":
        return state === AUTHENTICATING || state === RELEASING ? LOCKED : state;
    }
    return state;
}

function isLocked(state) {
    return state !== UNLOCKED;
}

// A lock of this shell that the compositor confirmed is held in these states (Lock.holding also needs
// WlSessionLock.secure). Anything else, unknown states included, is not holding: a decision that waits for a held lock
// (the sleep delay) then keeps waiting (fail closed).
function isHolding(state) {
    return state === LOCKED || state === AUTHENTICATING || state === RELEASING;
}

// ---- Fingerprint pacing (Lock.qml, only while /etc/pam.d/omarchy-lock-fingerprint exists, SEC8). Ported with Lock.qml's
// fingerprint pacing (whose header declares the fork) from Omarchy v4.5.0 shell/plugins/lock/FingerprintModel.js
// (basecamp/omarchy@ac2690cd7be4f47e4a255f5e2e78d904d436b068), Copyright (c) David Heinemeier Hansson, MIT License (notice:
// packaging/licenses/omarchy-MIT.txt); the file is absent from Omarchy 4.0.6, so its pin belongs to the 4.5.0 lock.
// docs/specs/security.md "Fingerprint pacing". Pacing only: none of this can unlock (only a PAM success of
// omarchy-lock-fingerprint does, LockController.fingerprintSucceeded). ----
// The gap before the next attempt after one that reached the reader (pam_fprintd's instruction came) and ended without a
// match, as before this port.
var FINGERPRINT_RETRY_MS = 1000;
// An attempt that ends this soon after the reader was reached failed on the device (a reader that drops out), not on a
// finger: pam_fprintd waits up to 30 s for one, and three wrong fingers end in MaxTries, which stops the reader.
var FINGERPRINT_FAST_END_MS = 2000;
// Attempts that do not reach the reader wait twice as long each time, up to this: longer than fprintd's 30 s idle exit, so a
// daemon whose device claim wedged (after a suspend: fprintd issue 173) can exit and start clean.
var FINGERPRINT_RETRY_CAP_MS = 40000;
// Misses in a row after which the journal says, once, that the reader is not answering.
var FINGERPRINT_UNAVAILABLE_AFTER = 3;
// An attempt that has not reached the reader this long after it started ends (aborted: never a success) and counts as a
// miss: a claim that never prompts (fprintd stuck before the reader) would otherwise hold the lock's fingerprint until a
// resume or an unlock. Shorter than the 25 s D-Bus method timeout of pam_fprintd's claim, longer than a slow device open
// (Omarchy v4.5.0 REACH_TIMEOUT_MS; opus review of 59a576f1, MINOR 1).
var FINGERPRINT_REACH_TIMEOUT_MS = 20000;

// Misses in a row after an attempt ended: none once the reader was reached and the attempt did not end fast; one more
// otherwise (no instruction from pam_fprintd, a start that failed, an end within FINGERPRINT_FAST_END_MS). A value that is
// not a count reads as none.
function fingerprintMisses(misses, reached, endedFast) {
    if (reached === true && endedFast !== true)
        return 0;
    var n = typeof misses === "number" && isFinite(misses) && misses > 0 ? Math.floor(misses) : 0;
    return Math.min(n, 1000) + 1;
}

// The wait before the next attempt: FINGERPRINT_RETRY_MS after none or one miss, then doubling up to
// FINGERPRINT_RETRY_CAP_MS. A value that is not a count reads as none.
function fingerprintRetryMs(misses) {
    if (!(typeof misses === "number" && isFinite(misses) && misses > 1))
        return FINGERPRINT_RETRY_MS;
    var doublings = Math.min(Math.floor(misses), 16) - 1;
    return Math.min(FINGERPRINT_RETRY_MS * Math.pow(2, doublings), FINGERPRINT_RETRY_CAP_MS);
}

// A resume from sleep offers the reader again (once even with the displays reported off) only to a lock: the fingerprint
// PAM file exists, MaxTries has not spent the reader, and the state is a lock state (locking, locked, authenticating,
// releasing). A resume while unlocked leaves nothing behind for the next lock (opus review of 59a576f1, MINOR 2).
function fingerprintOfferedOnResume(fileAvailable, spent, lockState) {
    return fileAvailable === true && spent !== true && typeof lockState === "string" && STATES.indexOf(lockState) !== -1
        && isLocked(lockState);
}

// Lid closed (Hyprland switch binding `switch:on:Lid Switch` in config/hypr/grassfield/system.lua, which runs
// /usr/lib/grassfield/grassfield-lid closed -> `lock lid`): lock unless a
// physical external display is active, which is clamshell mode, still in use on that display (macOS does not lock or
// sleep then; Omarchy's omarchy-system-lid-close makes the same choice). `names` are the shell's output names
// (Quickshell.screens). External connectors are the DRM names Hyprland gives physical outputs (DP-1, HDMI-A-1,
// DVI-D-1, VGA-1, ...); the built-in panel (eDP, LVDS, DSI), headless and nested outputs (HEADLESS-1, WAYLAND-1, any
// custom name) are not. Anything unreadable locks (fail closed).
var EXTERNAL_OUTPUT = /^(DP|HDMI-[A-Z]|DVI-[A-Z]|VGA|TV|USB)-[0-9]+$/;

function lidShouldLock(names) {
    if (!names || typeof names.length !== "number")
        return true;
    for (var i = 0; i < names.length; i++) {
        if (EXTERNAL_OUTPUT.test(String(names[i])))
            return false;
    }
    return true;
}

// Crash-recovery marker ($XDG_RUNTIME_DIR, one per compositor instance): one line, "<state>" or
// "<state> sleeps=<n>", state "locked" or "unlocked", n the system's count of completed suspends
// (/sys/power/suspend_stats/success) when the line was written (absent when that count was unreadable).
var MARKER_LINE = /^(locked|unlocked)(?: sleeps=([0-9]{1,12}))?$/;

function markerLine(state, sleeps) {
    var s = state === "unlocked" ? "unlocked" : "locked"; // anything unknown is written as locked
    return isSleepCount(sleeps) ? s + " sleeps=" + sleeps : s;
}

function isSleepCount(n) {
    return typeof n === "number" && isFinite(n) && n >= 0 && Math.floor(n) === n;
}

// /sys/power/suspend_stats/success as read (text, or undefined when unreadable) -> the count, or -1.
function parseSleepCount(text) {
    var m = String(text === undefined || text === null ? "" : text).match(/^\s*([0-9]{1,12})\s*$/);
    return m ? Number(m[1]) : -1;
}

// The marker as returned by markerRead: null when the file does not exist, else its content. Anything
// but an "unlocked" line means the session was (or may have been) locked: re-lock. That includes an
// empty or unreadable marker and any malformed line.
function markerSaysLocked(text) {
    if (text === null || text === undefined)
        return false; // missing: the first start of this compositor instance
    var m = String(text).trim().match(MARKER_LINE);
    return !(m && m[1] === "unlocked");
}

// The machine slept since an "unlocked" marker was written (GF-AUDIT-001 follow-up N1): the count of
// completed suspends differs from the one the line recorded. A shell that is alive locks before every
// sleep and rewrites the marker when it is unlocked again, so a different count means a sleep happened
// while no shell could lock for it (it had crashed or was restarting, right before or during that sleep):
// the restarted shell locks. False when either count is unknown (an old marker without a count, an
// unreadable sysfs file): no evidence either way.
function sleptSince(markerText, sleepsNow) {
    if (markerText === null || markerText === undefined || !isSleepCount(sleepsNow))
        return false;
    var m = String(markerText).trim().match(MARKER_LINE);
    if (!m || m[2] === undefined)
        return false;
    return Number(m[2]) !== sleepsNow;
}

// Meaning of a marker read, from FileView's result: null when the file does not exist (FileNotFound);
// "" when it exists but could not be read (permission denied, not a file, I/O error), which locks like
// any other content that is not exactly "unlocked"; else the file's text. `failed` must be exactly
// false for the text to be used (fail closed).
function markerRead(missing, failed, text) {
    if (missing === true)
        return null;
    if (failed !== false)
        return "";
    return String(text === undefined || text === null ? "" : text);
}

// Lock to restore when a shell instance starts (crash restart, reload or session start), from
// what it can read synchronously. Fail closed:
//   - intent: the previous instance's lock intent carried over a soft reload (PersistentProperties);
//   - markerAvailable false (XDG_RUNTIME_DIR unset): no marker can prove the session unlocked;
//   - otherwise the marker decides (markerSaysLocked on a markerRead result). A missing marker (null)
//     is the first start of this compositor instance; if it was removed while locked, the compositor
//     still holds the dead client's lock (ext-session-lock) and compositorLockState() finds it;
//   - an "unlocked" marker no longer proves anything when the machine slept since it was written
//     (sleptSince, sleepsNow = the current count of completed suspends, or -1 when unreadable).
function restoreAtStart(intent, markerAvailable, markerText, sleepsNow) {
    return intent === true || markerAvailable !== true || markerSaysLocked(markerText) || sleptSince(markerText, sleepsNow);
}

// Session lock state as reported by Hyprland, from `hyprctl -j monitors` objects
// (Quickshell HyprlandMonitor.lastIpcObject). Hyprland has no lock query, but an active
// ext-session-lock, including one whose client died, puts "LOCK" in solitaryBlockedBy. Hyprland
// stops listing at "WORKSPACE" (monitor without a workspace yet), so such a list proves nothing.
// Returns "locked", "unlocked" or "unknown" (no complete list, e.g. not Hyprland; no monitor at all, e.g. Quickshell's
// monitor model still empty: see monitorQueryAllowed).
function compositorLockState(monitors) {
    var list = monitors || [];
    return compositorLockStateLazy(list.length, function (i) {
        return list[i];
    });
}

// Same result as compositorLockState, reading monitor i's IPC object only when needed (get(i), called at most once per
// monitor, in order). Each read of Quickshell's HyprlandMonitor.lastIpcObject converts a whole monitor map to JS, which
// the 100 ms ownership check did twice per answer (the garbage made the shell's RSS climb ~5 MB/min between
// collections). A monitor listing LOCK settles the answer (the session lock is global), so in the steady locked state
// only the first monitor is read. Any other answer still reads every monitor, exactly as before.
function compositorLockStateLazy(count, get) {
    var readable = false;
    var n = typeof count === "number" ? count : 0;
    for (var i = 0; i < n; i++) {
        var object = get(i);
        var blockers = object ? object.solitaryBlockedBy : undefined;
        if (!blockers || typeof blockers === "string" || typeof blockers.length !== "number")
            continue;
        var lock = false;
        var workspace = false;
        for (var j = 0; j < blockers.length; j++) {
            var name = String(blockers[j]);
            if (name === "LOCK")
                lock = true;
            else if (name === "WORKSPACE")
                workspace = true;
        }
        if (lock)
            return "locked";
        if (!workspace)
            readable = true;
    }
    return readable ? "unlocked" : "unknown";
}

// Whether the lock may ask Hyprland for its monitors (Lock.qml requestMonitors, the lock's only Hyprland.refreshMonitors()
// call), from the number of monitor objects in Quickshell's model (Hyprland.monitors). The QML call is Quickshell 0.3.1's
// refreshMonitors(false): it updates the monitor objects that exist and never creates one. Sent before Hyprland answered
// Quickshell's own first query (`j/status`, whose answer starts Quickshell's refreshMonitors(true)), it makes Quickshell drop
// that query as a duplicate; its own answer then creates nothing, and the model stays EMPTY until a monitor event
// (configreloaded, monitoraddedv2, ...): no lock check (stranded lock, ownership, verify) would ever get an answer again. With
// no monitor object there is nothing such a query could update, so none is sent; the answer that fills the model is
// Quickshell's own, and until then the compositor lock state is unknown (never "unlocked"). Anything but a positive count
// is empty.
function monitorQueryAllowed(count) {
    return typeof count === "number" && count >= 1;
}

// Lock watchdog decision while this shell holds a lock the compositor confirmed (locked or
// authenticating, WlSessionLock secure), from a fresh compositorLockState() answer and the number of
// consecutive "unlocked" answers just before it. Hyprland 0.56 with misc.allow_session_lock_restore
// hands a live session lock to the next client that asks and tells the previous holder nothing; when
// either client then releases it, the session is unlocked although the other one's lock object still
// reports secure. Returns:
//   "ok"      the compositor reports the session locked (by this shell, or by a foreign locker that
//             took it over: coexist, the session is locked);
//   "unknown" no complete monitor list (not Hyprland, outputs coming up): rely on WlSessionLock;
//   "confirm" first "unlocked" answer: ask once more, so that an answer to a request sent before this
//             lock existed can never trigger a re-lock;
//   "relock"  confirmed unlocked: drop the stale lock object and take a fresh lock (fail closed).
function ownershipAction(compositorState, unlockedBefore) {
    if (compositorState === "locked")
        return "ok";
    if (compositorState !== "unlocked")
        return "unknown";
    return unlockedBefore >= 1 ? "relock" : "confirm";
}

// Lock ownership probe intervals (ms) while this shell holds a lock on Hyprland (Lock.qml ownershipProbe): one
// monitor query per tick. The interval bounds how long the session can stay unlocked after another client releases
// a lock it took over, so it is short while such a release is possible.
var PROBE_INTERVAL_MS = 1000;
var PROBE_SUSPECTED_MS = 100;

// The lock surface's view loads after the surface's first frame (LockViewLoader.qml, ADR-0041 S2); a load still under way
// this long after the surface was created is completed at once, so that a person is never left without a password field
// (the opus gate of d151cace). Offscreen the view loads in 31 to 75 ms warm and about 0.6 s cold.
var VIEW_SYNC_FALLBACK_MS = 3000;

// A takeover is suspected, i.e. another client may hold or have held the session lock, so that its release can unlock
// the session under this shell's lock, while
//   - no lock surface of this shell has the keyboard (another client's lock surface took it, or the session was
//     unlocked under this lock and a window took it), or
//   - the lock this shell holds was requested at start or after a reload ("restore"): it may be a lock this shell
//     took over from a live foreign locker, whose release unlocks the session without any event.
// Anything but exact booleans counts as suspected: probing faster never unlocks anything (fail closed).
function takeoverSuspected(surfaceFocused, inheritedLock) {
    return !(surfaceFocused === true && inheritedLock === false);
}

function probeInterval(suspected) {
    return suspected === false ? PROBE_INTERVAL_MS : PROBE_SUSPECTED_MS;
}

// File name of the marker; the instance id is reduced to safe file-name characters.
function markerName(instance, display) {
    var id = String(instance || display || "default").replace(/[^A-Za-z0-9_.-]/g, "_");
    return "grassfield-lock-" + id;
}

// Display name of `user` from /etc/passwd text (GECOS full name), else the login name.
function displayName(passwd, user) {
    var lines = String(passwd || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var f = lines[i].split(":");
        if (f.length >= 5 && f[0] === user) {
            var full = f[4].split(",")[0].trim();
            return full !== "" ? full : user;
        }
    }
    return String(user || "");
}

// The AccountsService picture of login `user`: "" unless `user` is a plain login name (no "/", no leading ".").
function accountsIconPath(user) {
    var name = String(user || "");
    return /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$/.test(name) ? "/var/lib/AccountsService/icons/" + name : "";
}

// The lock screen's account picture (review of 423766f: never a file where it lies, only a PNG the shell made from it).
// `source(path)` gives the URL of that PNG ("" until made or when refused) and `state(path)` says "pending", "ok", "no" or
// "" (never asked): ThemeIcons.fileSource and ThemeIcons.fileState. ~/.face first; once it is refused (missing, not a
// regular file, not an image), the AccountsService picture; else "" (the initials).
function avatarSource(facePath, accountsPath, source, state) {
    var face = facePath ? source(facePath) : "";
    if (face !== "" || (facePath && state(facePath) !== "no"))
        return face;
    return accountsPath ? source(accountsPath) : "";
}

// Up to two initials for the avatar placeholder.
function initials(name) {
    var parts = String(name || "").trim().split(/\s+/).filter(function (p) {
        return p.length > 0;
    });
    if (parts.length === 0)
        return "";
    var first = parts[0].charAt(0);
    var last = parts.length > 1 ? parts[parts.length - 1].charAt(0) : "";
    return (first + last).toUpperCase();
}

// Caps Lock inferred from a typed character (Quickshell 0.3.1 exposes no lock-key state):
// a cased letter that disagrees with Shift means Caps Lock is on. Returns true, false, or null
// when the character tells nothing (digits, symbols, uncased scripts).
function capsLockFromKey(text, shift) {
    var c = String(text || "");
    if (c.length !== 1 || c.toUpperCase() === c.toLowerCase())
        return null;
    var upper = c === c.toUpperCase();
    return upper !== !!shift;
}

// Lock-screen clock pattern: hours and minutes without AM/PM, in the locale's 12/24 h style.
function clockFormat(localeTimeFormat) {
    return /a/i.test(String(localeTimeFormat || "")) ? "h:mm" : "H:mm";
}

// Lock-screen date pattern in the region's order (UI audit 2026-11-05 U24): `pattern` is the translated "dddd d MMMM";
// where the region writes the month first (the first unquoted d or M of its short date format, "M/d/yy" in the US), it
// becomes "dddd, MMMM d" ("Wednesday, November 5"); a day-first region ("dd/MM/yyyy": the UK, France) and a translated
// pattern of another shape are left alone. The menu bar's rule (shell/menubar/ClockFormat.js monthFirst and orderDate),
// repeated here: a security module imports only lib, services and security modules (tests/ci/import_graph.py).
function datePattern(pattern, localeShortDate) {
    var p = String(pattern);
    var bare = String(localeShortDate || "").replace(/'[^']*'/g, "");
    var m = bare.indexOf("M");
    var d = bare.indexOf("d");
    if (m < 0 || (d >= 0 && d < m))
        return p;
    return p.replace(/^(d{4}) (d{1,2}) (M{3,4})$/, "$1, $3 $2");
}
