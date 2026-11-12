.pragma library

// Safe mode's decisions (ADR-0041 step 1, S4), pure: every function takes plain values and nothing else, so the rules are
// unit-tested without a shell (tests/security/tst_safemode.qml). SafeMode.qml feeds them what it looked at and what the
// security process knows of its own lock and sheets.
//
// What safe mode is (the owner's SQ-1 B): the UI unit (grassfield-shell.service) is down for good after a crash loop while
// the security process is up. The loop detector (packaging/bin/grassfield-shell-failed, step 1a) stops the unit at the
// third failure within 10 minutes and leaves a flag, $XDG_RUNTIME_DIR/grassfield/shell-safe-mode. The flag is read as a
// flag only: whether it exists, never what it holds. A flag alone is not enough (the opus review of b1d826b): the unit must
// really be down, neither running nor on its way to a restart, so that a flag left from an earlier loop, with the shell
// brought back by hand, shows nothing. And the unit failed at its own start limit is safe mode with no flag (ADR-0056 D-10:
// the detector does not count a failure that arrives while its own job still runs, so a sub-second loop can end at
// systemd's limit before the third failure is written).

// The loop detector's flag, in $XDG_RUNTIME_DIR/grassfield (packaging/bin/grassfield-shell-failed).
var MARKER = "shell-safe-mode";
// How often the security process looks at the shell's unit while nothing is seen, and while a stop is seen or the notice
// is up (it leaves soon after the desktop is back). One look is one short process (SafeMode.qml `probe`).
var LOOK_IDLE_MS = 5000;
var LOOK_WATCH_MS = 2000;
// Looks in a row that must say "safe mode" before the notice shows: a flag left from an earlier loop, read at a login before
// the session's autostart has started the shell, or a unit passing through "failed" on its way to a restart, shows nothing.
var SETTLE_LOOKS = 2;
// After the notice appears (at the unlock, when a sheet closes, when the displays wake), a key or a click acts only this
// long after: the key that woke the displays, a Return that ended the password or a repeat of it never presses a button
// (the polkit and secret sheets' held guard, AuthDialogModel.heldGuardMs; the opus review of a0df9c3e, MINOR-2).
var GUARD_MS = 500;
// An action whose process never reported its end (it could not start) is given up after this long; both commands are
// bounded below it by `timeout` (SafeMode.qml).
var ACTION_GUARD_MS = 340000;
// systemd's unit states and results are lower-case words with dashes ("inactive", "auto-restart", "start-limit-hit").
var TOKEN = /^[a-z][a-z-]{0,31}$/;

// One look (SafeMode.qml `probe`): a line "marker=0" or "marker=1", then systemctl's "ActiveState=", "SubState=" and
// "Result=" lines, in any order. {ok, marker, active, sub, result}; ok is false unless every line was there once, well
// formed. An answer that cannot be read counts for nothing (`next`): it never shows the notice on a guess, and never hides
// one already up (a systemctl slowed past its bound by a loaded machine must not make the alert blink).
function parseLook(text) {
    const out = {ok: false, marker: false, active: "", sub: "", result: ""};
    if (typeof text !== "string" || text.length > 4096)
        return out;
    const seen = {};
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line === "")
            continue;
        const eq = line.indexOf("=");
        if (eq <= 0)
            return out;
        const key = line.slice(0, eq);
        const value = line.slice(eq + 1);
        if (seen[key] === true)
            return out;
        seen[key] = true;
        if (key === "marker") {
            if (value !== "0" && value !== "1")
                return out;
            out.marker = value === "1";
        } else if (key === "ActiveState" || key === "SubState" || key === "Result") {
            if (!TOKEN.test(value))
                return out;
            if (key === "ActiveState")
                out.active = value;
            else if (key === "SubState")
                out.sub = value;
            else
                out.result = value;
        } else {
            return out;
        }
    }
    out.ok = seen.marker === true && seen.ActiveState === true && seen.SubState === true && seen.Result === true;
    return out;
}

// The unit is down for good: neither running nor starting, stopping or waiting to restart ("activating" covers the
// auto-restart wait).
function stopped(look) {
    return !!look && look.ok === true && (look.active === "inactive" || look.active === "failed");
}

// This look says safe mode: the unit down with the loop detector's flag, or failed at its own start limit (ADR-0056 D-10).
function wanted(look) {
    return stopped(look) && (look.marker === true || (look.active === "failed" && look.result === "start-limit-hit"));
}

// The looks in a row that said safe mode, after one more look (capped at SETTLE_LOOKS).
function settle(count, wantedNow) {
    if (wantedNow !== true)
        return 0;
    const before = typeof count === "number" && count > 0 ? Math.floor(count) : 0;
    return Math.min(before + 1, SETTLE_LOOKS);
}

// The count after one more look: a readable look counts or starts the count over; one that cannot be read leaves it as it
// was.
function next(count, look) {
    if (!look || look.ok !== true)
        return typeof count === "number" && count > 0 ? Math.min(Math.floor(count), SETTLE_LOOKS) : 0;
    return settle(count, wanted(look));
}

function confirmed(count) {
    return typeof count === "number" && count >= SETTLE_LOOKS;
}

// The notice is on screen, and only then exists: safe mode confirmed, the session unlocked (not locked, not asked to lock,
// not probing a stranded lock at start), no polkit or secret sheet of this process open, shown or held, and the displays on
// (idle can turn them off while unlocked; the wake key must find no notice: the opus review of a0df9c3e, MINOR-2). Anything
// but exactly false for `locked`, `sheetUp` or `displaysOff` keeps it off (fail closed).
function shown(isConfirmed, locked, sheetUp, displaysOff) {
    return isConfirmed === true && locked === false && sheetUp === false && displaysOff === false;
}

// An action (Try Again, Log Out) may start: the notice is on screen, has been for GUARD_MS (`armed`), and no action is under
// way.
function canAct(isShown, busy, armed) {
    return isShown === true && busy === false && armed === true;
}

// What an action that did not finish says (SafeModeCard): Try Again, any failure; Log Out, apps still open (exit 3 of
// grassfield-session-end: the windows did not all close, or the list could not be read) or the session not ended (anything
// else: the logout's own failure, its bound, a process that could not start). "" for a success.
function failureOf(action, code) {
    if (code === 0)
        return "";
    if (action === "logOut")
        return code === 3 ? "logOutOpen" : "logOut";
    return "tryAgain";
}

// The delay before the next look.
function lookInterval(count, isShown) {
    return (typeof count === "number" && count > 0) || isShown === true ? LOOK_WATCH_MS : LOOK_IDLE_MS;
}

// The look a dev session fakes (SafeMode.qml `safemode devSet`): the security process of a dev session never asks systemd
// (it would read the owner's own unit) and never reads the owner's flag.
function devLook(on) {
    return on === true ? "marker=1\nActiveState=inactive\nSubState=dead\nResult=success\n" : "marker=0\nActiveState=active\nSubState=running\nResult=success\n";
}
