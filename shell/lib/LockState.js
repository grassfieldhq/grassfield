.pragma library

// The lock state the security process publishes and the UI reads (ADR-0041 step 1, S2; ADR-0010 "Separate security
// process", risk 2). Pure, shared by both sides through a relative import (no QML import path can replace it, as for
// RunMode.js), unit-tested by tests/security/tst_lockstate.qml with mutants (tests/security/lockstate_mutants.sh).
//
// The channel is one file, $XDG_RUNTIME_DIR/grassfield-lock-state-<compositor instance>, written atomically by the
// security process only:
//   - on every change of what it publishes (the lock's public state, the displays switched off by idle, where the lock's
//     clouds came to rest): the push;
//   - every HEARTBEAT_MS with a new sequence number: the heartbeat, so a push the UI missed is corrected by the next beat.
// The UI watches the file and reads it again at every beat it expects. It never writes it and never answers it: the
// security process reads nothing from the UI through this channel. What the UI derives from it is fail closed
// (uiLocked): no state yet, a state that cannot be read, a beat older than STALE_MS (the process is down, restarting,
// stopped at its start limit or hung), a state other than "unlocked", or the compositor's own lock signal, each reads
// locked. A same-user process can write the file, as it can call any IPC target; the compositor keeps the lock whatever the
// file says (docs/specs/security.md "Lock state across processes").

// One line of JSON, at most this long; anything longer is not a state.
var MAX_BYTES = 4096;
// The security process writes a beat this often (ms).
var HEARTBEAT_MS = 2000;
// No beat for this long (ms): stale, read as locked.
var STALE_MS = 5000;
// At most this many outputs' cloud positions.
var MAX_OUTPUTS = 16;
// The format's version.
var VERSION = 1;

// The file's name for a compositor instance, with the same id as the crash-recovery marker (LockMachine.markerName):
// HYPRLAND_INSTANCE_SIGNATURE, else WAYLAND_DISPLAY, else "default", every other character than [A-Za-z0-9_.-] made "_".
function fileName(instance, display) {
    var id = String(instance || display || "default").replace(/[^A-Za-z0-9_.-]/g, "_");
    return "grassfield-lock-state-" + id;
}

// The full path, or "" without a runtime directory (the UI then reads locked: there is no state to read).
function filePath(runtimeDir, instance, display) {
    var dir = String(runtimeDir || "");
    if (dir === "" || dir.charAt(0) !== "/")
        return "";
    return dir + "/" + fileName(instance, display);
}

// What the security process publishes: "unlocked" (no lock), "locking" (a lock requested, the compositor has not confirmed
// it yet) or "locked" (the compositor confirmed it; also while a password is checked and during the release fade, which
// are still locked).
function publicState(locked, holding) {
    if (locked !== true)
        return "unlocked";
    return holding === true ? "locked" : "locking";
}

// `lock state` (the IPC function of ADR-0010 S3): "unlocked" or "locked" only; "locking" answers "locked".
function ipcState(publicStateValue) {
    return publicStateValue === "unlocked" ? "unlocked" : "locked";
}

function validOutput(name) {
    return typeof name === "string" && name.length > 0 && name.length <= 64 && /^[A-Za-z0-9._-]+$/.test(name);
}

function validMotion(at) {
    return typeof at === "number" && isFinite(at) && at >= 0 && at <= 1e12;
}

// The cloud positions to publish: the valid entries only, at most MAX_OUTPUTS, in key order.
function cleanMotion(motion) {
    var out = {};
    if (motion === null || typeof motion !== "object" || Array.isArray(motion))
        return out;
    var keys = Object.keys(motion).sort();
    var count = 0;
    for (var i = 0; i < keys.length && count < MAX_OUTPUTS; i++) {
        if (validOutput(keys[i]) && validMotion(motion[keys[i]])) {
            out[keys[i]] = motion[keys[i]];
            count++;
        }
    }
    return out;
}

// The file's text: one line of JSON. `writer` is the writing process's id (Quickshell.processId), so that a restarted
// process whose sequence starts again counts as a new beat.
function format(state, seq, writer, displaysOff, motion) {
    return JSON.stringify({
        v: VERSION,
        state: state,
        seq: seq,
        writer: writer,
        displaysOff: displaysOff === true,
        motion: cleanMotion(motion)
    });
}

function isCount(n) {
    return typeof n === "number" && isFinite(n) && Math.floor(n) === n && n >= 0 && n <= 9007199254740991;
}

// The file's text read back: {ok: true, state, seq, writer, displaysOff, motion}, or {ok: false} for anything else (empty,
// too long, not one JSON object, an unknown version or state, a sequence or writer that is not a whole number, a field
// of the wrong type). An unknown motion entry is dropped, never the state.
function parse(text) {
    var bad = {ok: false};
    var s = String(text === undefined || text === null ? "" : text);
    if (s.length === 0 || s.length > MAX_BYTES)
        return bad;
    var o;
    try {
        o = JSON.parse(s);
    } catch (e) {
        return bad;
    }
    if (o === null || typeof o !== "object" || Array.isArray(o))
        return bad;
    if (o.v !== VERSION)
        return bad;
    if (o.state !== "unlocked" && o.state !== "locking" && o.state !== "locked")
        return bad;
    if (!isCount(o.seq) || !isCount(o.writer))
        return bad;
    if (typeof o.displaysOff !== "boolean")
        return bad;
    return {ok: true, state: o.state, seq: o.seq, writer: o.writer, displaysOff: o.displaysOff, motion: cleanMotion(o.motion)};
}

// A read is a new beat when its writer or its sequence differs from the last one taken. The first read is never one: a file
// may be the last line of a writer that is dead or hung, so only a second, different write proves a live writer (the opus
// review of 77a0ceb3, MINOR-3: a UI started next to a dead writer's "unlocked" read unlocked for up to 5 s). The UI reads
// locked until then, at most one beat at its start.
function isNewBeat(last, read) {
    if (read === null || read === undefined || read.ok !== true)
        return false;
    if (last === null || last === undefined || last.ok !== true)
        return false;
    return read.writer !== last.writer || read.seq !== last.seq;
}

// Stale: no new beat for STALE_MS. `sinceBeatMs` is measured on a monotonic clock (a Timer), never the wall clock; a
// negative or unknown value is stale.
function isStale(sinceBeatMs) {
    return !(typeof sinceBeatMs === "number" && isFinite(sinceBeatMs) && sinceBeatMs >= 0 && sinceBeatMs < STALE_MS);
}

// What every refusal of the UI reads (GF-116, "Show previews: When Unlocked", Overview, Switcher, the Dock's reopen):
// locked unless a state is known, fresh, says "unlocked", and the compositor does not report a lock.
function uiLocked(known, stale, state, compositorLocked) {
    if (known !== true || stale !== false)
        return true;
    if (compositorLocked === true)
        return true;
    return state !== "unlocked";
}

// The lock is known to be held or being acquired: the compositor reports a lock, or the last state the security process
// published (fresh or stale) says "locking" or "locked". False while the UI reads locked only because the state is missing,
// unreadable, or stale after an "unlocked": the security process stopped beating while the session was unlocked (or has not
// published yet). Then a lock request must still reach it, through the stand-in that starts it (ADR-0041 S2, the opus review
// of 77a0ceb3 MAJOR-1: "a lock request always ends in a locked session"): the paths that only lock or end the session are
// refused only while this is true (SessionState.refusesConfirmed).
function uiLockConfirmed(known, state, compositorLocked) {
    if (compositorLocked === true)
        return true;
    return known === true && (state === "locking" || state === "locked");
}

// The lock is being acquired (the UI's screen saver stays up meanwhile, so no desktop flashes before the lock surface).
function uiLockStarting(known, stale, state) {
    return known === true && stale === false && state === "locking";
}
