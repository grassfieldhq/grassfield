.pragma library

// Do Not Disturb for a while ("for 1 hour", "until tomorrow"; docs/specs/command-palette.md B7). Pure: no QML, no clock, no file.
// Notifications.qml keeps the deadline (ms since the epoch, 0 none) in $stateDir/dnd-until.json beside the DND switch, so a shell
// restart keeps it: at start the deadline is read back, a deadline in the past turns Do Not Disturb off, one in the future is armed.

// The moment (ms) a Do Not Disturb asked at `nowMs` ends: "hour" is `forMs` on, "tomorrow" is tomorrow at local hour `tomorrowHour`
// (macOS: until tomorrow morning). 0 for any other kind.
function deadline(kind, nowMs, forMs, tomorrowHour) {
    if (kind === "hour")
        return nowMs + forMs;
    if (kind === "tomorrow") {
        const d = new Date(nowMs);
        return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, tomorrowHour, 0, 0, 0).getTime();
    }
    return 0;
}

// What to do at `nowMs` with the deadline `until` (0 none) when Do Not Disturb is `dndOn`: "none" (nothing armed), "clear" (it was
// turned off another way: forget the deadline), "expire" (turn it off now, then forget), "wait".
function step(until, dndOn, nowMs) {
    if (!(until > 0))
        return "none";
    if (!dndOn)
        return "clear";
    return nowMs >= until ? "expire" : "wait";
}

// The wait before the next check: the time left, at most `checkMs` (a timer does not count the time asleep), at least a second.
function nextCheckMs(until, nowMs, checkMs) {
    return Math.max(1000, Math.min(checkMs, until - nowMs));
}

function serialize(until) {
    return JSON.stringify({until: until > 0 ? Math.round(until) : 0});
}

// The deadline of a file's text: 0 for anything that is not a positive finite number (a damaged file means no deadline).
function parse(text) {
    try {
        const o = JSON.parse(text);
        const n = o && typeof o === "object" ? o.until : 0;
        return typeof n === "number" && isFinite(n) && n > 0 ? Math.round(n) : 0;
    } catch (e) {
        return 0;
    }
}
