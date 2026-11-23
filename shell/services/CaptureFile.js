.pragma library

// The capture helper's private state as the shell reads it (packaging/bin/grassfield-capture, ADR-0045 OC-1; spec
// docs/specs/system-dialogs.md "Screen recording" SC16): where the file is, what it says once checked, the seconds left of a
// countdown, the elapsed time of a recording, and where the countdown plate goes. Pure functions (tests/unit/tst_capturefile.qml).
//
// The file is the user's own (0600 in a 0700 folder, written by rename) and still data: every field is checked, a field that
// does not read is dropped, and a file that does not read at all is "idle".

// "starting": a recording's helper has begun (written at once, before anything slow), "selecting": its crosshair shows,
// "shooting": the helper is about to take pixels and waits (1 s at most) for the shell's acknowledgement, "frozen": it holds
// grabbed frames and waits for the choice (ADR-0066 D-1, D-2).
var PHASES = ["idle", "starting", "selecting", "countdown", "recording", "shooting", "frozen"];

// The helper's `seq` (a random 64-bit hex, 16 digits today) and the frozen state's `token` (128 bits, 32 digits): hex only, so
// that nothing but hex ever reaches the acknowledgement file or a helper argument. The `seq` limit keeps the file far under the
// 64 bytes the helper accepts.
var SEQ = /^[0-9A-Fa-f]{1,32}$/;
var TOKEN = /^[0-9A-Fa-f]{1,64}$/;

// Whether the shell must stop the helper now: the session is locked (or locking) and a capture is anything but idle. Asked on
// every change of either, so that a recording that becomes active after the lock (its helper was slow to start, or the shell
// restarted under the lock and reads the state late) is stopped too, not only one running when the lock came (security review
// of OC-1, MEDIUM).
function stopNeeded(locked, phase) {
    return locked === true && PHASES.indexOf(phase) > 0;
}
var OUTPUT_NAME = /^[A-Za-z0-9._-]{1,64}$/;

// $XDG_RUNTIME_DIR/grassfield/capture-state.json, the helper's path; in a dev session with GRASSFIELD_STATE_HOME, a file of the
// dev state instead (a dev shell never reads the real session's, as KeyWindowFile.path). "" when neither is known.
function statePath(stateHome, runtimeDir) {
    if (stateHome)
        return String(stateHome) + "/capture-state.json";
    if (runtimeDir)
        return String(runtimeDir) + "/grassfield/capture-state.json";
    return "";
}

function finite(v) {
    return typeof v === "number" && isFinite(v);
}

// {x, y, w, h} in the compositor's logical coordinates, or null.
function rect(r) {
    if (r === null || typeof r !== "object" || Array.isArray(r))
        return null;
    if (!finite(r.x) || !finite(r.y) || !finite(r.w) || !finite(r.h) || r.w <= 0 || r.h <= 0)
        return null;
    return {x: r.x, y: r.y, w: r.w, h: r.h};
}

// The state read from the file's text: {phase, kind, until, started, rect, output, seq, token}. `until` and `started` are ms since the
// epoch (0 when absent); a countdown without its end and a recording without its start read as idle (nothing to show).
function parse(text) {
    const idle = {phase: "idle", kind: "", until: 0, started: 0, rect: null, output: "", seq: "", token: ""};
    let doc = null;
    try {
        doc = JSON.parse(String(text || ""));
    } catch (e) {
        return idle;
    }
    if (doc === null || typeof doc !== "object" || Array.isArray(doc) || doc.v !== 1 || PHASES.indexOf(doc.phase) < 0)
        return idle;
    const out = {
        phase: doc.phase,
        kind: doc.kind === "shot" || doc.kind === "recording" ? doc.kind : "",
        until: finite(doc.until) && doc.until > 0 ? doc.until : 0,
        started: finite(doc.started) && doc.started > 0 ? doc.started : 0,
        rect: rect(doc.rect),
        output: typeof doc.output === "string" && OUTPUT_NAME.test(doc.output) ? doc.output : "",
        // Only the phase that owns each field carries it. A `shooting` or `frozen` state whose field does not read keeps its
        // phase (the lock must still stop it) and an empty field (it is never acknowledged).
        seq: doc.phase === "shooting" && typeof doc.seq === "string" && SEQ.test(doc.seq) ? doc.seq : "",
        token: doc.phase === "frozen" && typeof doc.token === "string" && TOKEN.test(doc.token) ? doc.token : ""
    };
    if ((out.phase === "countdown" && out.until === 0) || (out.phase === "recording" && out.started === 0))
        return idle;
    return out;
}

// Whether the shell must acknowledge the helper's `shooting` state now: it has a valid `seq`, the thumbnails are hidden (unmapped
// and one frame passed), and this `seq` was not acknowledged yet. Returns the `seq` to write, or "".
function ackNeeded(state, hidden, acked) {
    if (hidden !== true || !state || state.phase !== "shooting" || state.seq === "" || state.seq === acked)
        return "";
    return state.seq;
}

// Whole seconds left of a countdown ending at `until` (5, 4, ... 1), 0 once it is over.
function secondsLeft(now, until) {
    if (!finite(now) || !finite(until) || until <= now)
        return 0;
    return Math.ceil((until - now) / 1000);
}

function pad(n) {
    return n < 10 ? "0" + n : String(n);
}

// The elapsed time of a recording, as the menu bar shows it: m:ss, then h:mm:ss from an hour (never negative: a clock that
// went back shows 0:00).
function elapsed(ms) {
    const s = finite(ms) && ms > 0 ? Math.floor(ms / 1000) : 0;
    const h = Math.floor(s / 3600);
    const m = Math.floor(s % 3600 / 60);
    return (h > 0 ? h + ":" + pad(m) : String(m)) + ":" + pad(s % 60);
}

// The display the countdown plate shows on (`screens`: [{name, x, y, width, height}], logical): the state's display when it
// still exists, else the one holding the centre of the state's area, else "".
function plateScreen(state, screens) {
    const list = Array.isArray(screens) ? screens : [];
    if (state.output !== "" && list.some(s => s.name === state.output))
        return state.output;
    const r = state.rect;
    if (!r)
        return "";
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const hit = list.find(s => cx >= s.x && cx < s.x + s.width && cy >= s.y && cy < s.y + s.height);
    return hit ? hit.name : "";
}

// The plate's centre in that display's own coordinates: the centre of the area when it lies there, else the display's centre.
function plateCentre(state, screen) {
    const r = state.rect;
    if (r && screen) {
        const cx = r.x + r.w / 2 - screen.x;
        const cy = r.y + r.h / 2 - screen.y;
        if (cx >= 0 && cx < screen.width && cy >= 0 && cy < screen.height)
            return {x: cx, y: cy};
    }
    return {x: screen ? screen.width / 2 : 0, y: screen ? screen.height / 2 : 0};
}
