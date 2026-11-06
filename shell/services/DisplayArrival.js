.pragma library

// A combination of displays never seen before (ADR-0044 amendment A-1, docs/specs/settings.md "Displays"): when the set of
// connected displays changes to one this user has never had, and it has settled (no change for SETTLE_MS), the shell offers
// the arrangement once, with a notice whose click opens Settings > Displays. Pure functions: no I/O, no timers (the caller
// owns them), tested by tests/unit/tst_displayarrival.qml. Inspired by Project Luma's luma-displays "arrival" (Apache-2.0):
// wait for the hot-plug to settle, two displays or more, an arrangement not known yet; no code copied.
//
// A combination is keyed by the sorted identities of its displays (DisplayRole.setOf: make, model and serial, never the
// connector alone), so the same monitors on other ports are the same combination.
//
// The seen-set, `displays-seen.json` in the shell's state folder (mode 0600): {version: 1, seen: [<combination key>...]},
// newest first, at most MAX_SEEN. Untrusted input: anything malformed reads as an empty list.

var VERSION = 1;
var MAX_SEEN = 32;
// Hot-plug is a burst (a dock brings two monitors one after the other, a monitor wakes up in stages): offer only once the
// set has not changed for this long.
var SETTLE_MS = 3000;
var MAX_KEY_CHARS = 16 * 200;

// The key of a combination: its sorted display keys joined by newlines ("" for no display). `set` is DisplayRole.setOf(...).
function comboKey(set) {
    if (!set || typeof set.length !== "number" || set.length === 0)
        return "";
    const keys = [];
    for (let i = 0; i < set.length; i++) {
        if (typeof set[i] !== "string" || set[i] === "" || set[i].indexOf("\n") >= 0)
            return "";
        keys.push(set[i]);
    }
    keys.sort();
    const key = keys.join("\n");
    return key.length <= MAX_KEY_CHARS ? key : "";
}

// The number of displays of a combination key.
function countOf(key) {
    return typeof key === "string" && key !== "" ? key.split("\n").length : 0;
}

function parseSeen(text) {
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return [];
    }
    if (!data || data.version !== VERSION || !Array.isArray(data.seen))
        return [];
    const out = [];
    for (const k of data.seen) {
        if (typeof k === "string" && k !== "" && k.length <= MAX_KEY_CHARS && out.indexOf(k) < 0)
            out.push(k);
        if (out.length >= MAX_SEEN)
            break;
    }
    return out;
}

function serializeSeen(list) {
    return JSON.stringify({version: VERSION, seen: (list || []).slice(0, MAX_SEEN)}, null, 1) + "\n";
}

// `key` first, the others after it, at most MAX_SEEN (the oldest combination is forgotten first).
function remember(list, key) {
    if (typeof key !== "string" || key === "")
        return (list || []).slice(0, MAX_SEEN);
    return [key].concat((list || []).filter(k => k !== key)).slice(0, MAX_SEEN);
}

// A list (or the JSON adapter's list, which is not an Array) as an Array; anything else is empty.
function items(v) {
    if (Array.isArray(v))
        return v;
    if (v === null || typeof v !== "object" || typeof v.length !== "number")
        return [];
    const out = [];
    for (let i = 0; i < Math.min(v.length, 64); i++)
        out.push(v[i]);
    return out;
}

// Known: in the seen-set, or a set the user already chose a main display for (`displays.main`, ADR-0044 D-2: the user has
// been to Displays with exactly these displays).
function isKnown(seen, key, displaysMain) {
    if (key === "")
        return true;
    if (items(seen).indexOf(key) >= 0)
        return true;
    for (const e of items(displaysMain)) {
        if (e && typeof e === "object" && comboKey(items(e.set)) === key)
            return true;
    }
    return false;
}

// Output names of a nested or virtual compositor output (a dev session's own displays): the nested window (WAYLAND-1), a
// headless output, and the project's own reference output (GF-REF, config/hypr/dev.lua).
function isVirtualOutput(name) {
    return typeof name === "string" && /^((WAYLAND|HEADLESS|X11)-[0-9]+|GF-REF)$/.test(name);
}

// Whether this shell may offer at all: a packaged session; or a dev session with its own state folder
// (GRASSFIELD_STATE_HOME) whose displays are all virtual (a nested session). Never a dev shell on the owner's displays, and
// never one that would write the owner's seen-set.
function allowed(session, dev, ownState, names) {
    if (session)
        return true;
    const list = items(names);
    return !!dev && !!ownState && list.length > 0 && list.every(isVirtualOutput);
}

// The settle tracker: the current key and since when it holds. A new key restarts the wait.
function track(state, key, now) {
    if (state && state.key === key)
        return state;
    return {key: key, since: now};
}

function settled(state, now) {
    return !!state && state.key !== "" && now - state.since >= SETTLE_MS;
}

// What to do with a settled combination:
//   "none"      nothing (no display, already known, or this shell may not offer: nothing is written either)
//   "remember"  record it silently: the combination the session started with (the user did not just plug it in), or a single
//               display (nothing to arrange)
//   "wait"      new, but the screen is locked: decide again once it is unlocked
//   "offer"     new: post the notice once and record it
// `c`: {key, startup, known, allowed, locked}.
function decide(c) {
    if (!c || !c.allowed || typeof c.key !== "string" || c.key === "" || c.known)
        return "none";
    if (c.startup || countOf(c.key) < 2)
        return "remember";
    if (c.locked)
        return "wait";
    return "offer";
}
