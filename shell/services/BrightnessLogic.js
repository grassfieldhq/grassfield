.pragma library

// Pure logic of per-output brightness (ADR-0045 OC-4): which output a brightness key or Quick Settings' Display slider acts
// on, and the one-command-at-a-time queue of an external display driven over DDC/CI by Omarchy's
// `omarchy-brightness-display-ddc <monitor> [N%|+N%|N%-]` (Brightness.qml runs it; tests/unit/tst_brightnesslogic.qml).
//
// The command, as Omarchy 4.0.6 ships it: with the monitor alone it prints the level as a whole percentage (0 to 100) and
// exits 0, or exits 1 without output when the output has no DDC/CI (no i2c access, no answer); `N%` sets that level and
// `+N%` / `N%-` step from the level it reads first; every form prints the level it set and clamps it to 1..100 (a step of
// exactly 5 below 5 % moves by 1). It caches the output's i2c bus (and, for 10 s, the display's range) under
// $XDG_RUNTIME_DIR/omarchy-brightness-display-ddc, so only the first call after a plug detects the bus (seconds).

var COMMAND = "omarchy-brightness-display-ddc";
// A key press moves the level by 5 points: the existing keys' step (Brightness.adjust(±0.05), brightnessctl 5%+ and 5%-).
var STEP = 5;
// The command's own bounds when it sets a level.
var MIN_SET = 1;
var MAX_SET = 100;
// A write that failed this many times in a row on a display that answered makes it a display without DDC/CI (its keys and
// slider go back to what an uncontrollable display does), until it is plugged again.
var MAX_FAILURES = 3;
// Every command runs bounded by coreutils' timeout: `timeout -k 2 12 omarchy-brightness-display-ddc ...`. The command is a bash
// script whose ddcutil is a child: a signal to the script alone would leave ddcutil talking to the bus while the next command
// starts. timeout runs the command in a process group of its own and signals the whole group, TERM after 12 s, KILL 2 s later,
// so nothing of it outlives the run (security review, LOW 3). It then exits 124 (or 137) without output: not answered. 12 s
// leaves room for the first call after a plug, which detects the bus (seconds with several displays); Settings > Displays
// runs the same bounded form (apps/settings/qml/System.js, systemguard.cpp) inside its Backend's 15 s wait.
var BOUND = ["timeout", "-k", "2", "12"];
// A display that did not answer DDC/CI is remembered for the session by its identity (identity(): the model and serial number
// the compositor reports for it), so that a shell restart or a display change does not ask it again (owner's report of
// 2026-11-21: 18 "Remote I/O error" lines from ddcutil, an HP LA2205 asked again at every display change and every restart).
// It is asked again only when the person asks for it: a brightness key while it is the active display (at most once every
// KEY_REPROBE_MS), or a new connection of it REPROBE_AFTER_MS or more after it last failed. Its one explanatory journal line
// is written once per session.
var REPROBE_AFTER_MS = 10 * 60 * 1000;
var KEY_REPROBE_MS = 30 * 1000;
// At most this many displays are remembered (the oldest failures go first).
var MAX_SILENT = 32;

// The shell's own backstop: a run still going this long after it started (the bound plus the kill delay plus a margin) is
// asked to stop again (TERM to timeout, which passes it to the group); its output stays busy until it has really exited, so
// two commands never share a bus.
var BACKSTOP_MS = 18000;

// A laptop's own panel (eDP, LVDS, DSI), as Omarchy's omarchy-brightness-display and Settings' Displays.isBuiltIn tell it:
// its brightness is the backlight's, never DDC/CI.
function isBuiltIn(name) {
    return typeof name === "string" && /^(eDP|LVDS|DSI)-/.test(name);
}

// A Hyprland output name as the kernel names a connector ("DP-1", "HDMI-A-1", "eDP-1", "DVI-D-2"): a letter, letters and
// hyphens, then "-" and the connector's number. Never an option ("-x"), a path or a space; systemguard.cpp isConnectorName and
// System.js take the same rule.
function isConnector(name) {
    return typeof name === "string" && /^[A-Za-z][A-Za-z-]{0,23}-[0-9]{1,4}$/.test(name);
}

// An output of the compositor's own (a headless output, the window of a nested session): no display behind it to ask.
function isVirtual(name) {
    return typeof name === "string" && /^(HEADLESS|WAYLAND|X11)-/.test(name);
}

// The first built-in output among `names`, "" when none is connected (a desktop, or a laptop with its lid closed).
function builtIn(names) {
    const list = Array.isArray(names) ? names : [];
    for (const n of list) {
        if (isBuiltIn(n))
            return n;
    }
    return "";
}

// The command's answer: a whole percentage 0..100 alone on its line (surrounding white space allowed), else -1.
function parsePercent(text) {
    if (typeof text !== "string")
        return -1;
    const t = text.trim();
    if (!/^[0-9]{1,3}$/.test(t))
        return -1;
    const n = parseInt(t, 10);
    return n <= 100 ? n : -1;
}

function clampSet(percent) {
    return Math.max(MIN_SET, Math.min(MAX_SET, Math.round(percent)));
}

// The level after one key press: 5 points up or down from `level`, within the command's 1..100. An unknown direction leaves it.
function stepPercent(level, direction) {
    const base = typeof level === "number" && isFinite(level) ? level : 0;
    if (direction === "up")
        return clampSet(base + STEP);
    if (direction === "down")
        return clampSet(base - STEP);
    return base;
}

// What the shell knows of one external display, as a plain object the queue functions copy:
//   status   "unknown" (not asked yet), "probing" (the first query runs), "ok" (it answered), "none" (no DDC/CI)
//   level    its level once what runs and what waits are applied: the last printed one moved by the requests made since
//            (-1 before the first answer)
//   busy     a command for this output runs (never two at once: DDC writes take 50 to 200 ms and the bus serves one)
//   pending  the request that waits for it, or null: {kind: "query"}, {kind: "set", percent} or {kind: "step", steps}
//   failures writes that failed in a row
//   serial   which display on that connector this is (sync numbers them): a command's answer counts only for the display it
//            ran for
function fresh() {
    return {status: "unknown", level: -1, busy: false, pending: null, failures: 0, serial: 0};
}

function answers(ddc, name) {
    return ddc !== null && typeof ddc === "object" && Object.prototype.hasOwnProperty.call(ddc, name) && ddc[name] !== null
        && ddc[name].status === "ok";
}

// The argument vector of a request for output `name` (the command under its bound, BOUND), or null when there is nothing to
// run (a bad name, no net step).
function argvFor(name, request) {
    if (!isConnector(name) || !request)
        return null;
    if (request.kind === "query")
        return BOUND.concat([COMMAND, name]);
    if (request.kind === "set" && typeof request.percent === "number" && isFinite(request.percent))
        return BOUND.concat([COMMAND, name, clampSet(request.percent) + "%"]);
    if (request.kind === "step" && typeof request.steps === "number" && request.steps !== 0) {
        const amount = Math.min(MAX_SET, Math.abs(Math.round(request.steps)) * STEP);
        if (amount === 0)
            return null;
        return BOUND.concat([COMMAND, name, request.steps > 0 ? "+" + amount + "%" : amount + "%-"]);
    }
    return null;
}

// What waits once `request` arrives while a command runs: the last value wins. A level set replaces whatever waited; a step
// moves a waiting level or adds to waiting steps; a query is answered by any waiting change (each one prints the level).
function merge(pending, request) {
    if (request.kind === "query")
        return pending !== null ? pending : request;
    if (request.kind === "set")
        return {kind: "set", percent: clampSet(request.percent)};
    if (pending === null || pending.kind === "query")
        return {kind: "step", steps: request.steps};
    if (pending.kind === "set")
        return {kind: "set", percent: clampSet(pending.percent + STEP * request.steps)};
    return {kind: "step", steps: pending.steps + request.steps};
}

// The level the display will have once `request` is applied to `level` (what the OSD and the slider show at once).
function expected(level, request) {
    if (!request || request.kind === "query")
        return level;
    if (request.kind === "set")
        return clampSet(request.percent);
    return level < 0 ? level : clampSet(level + STEP * request.steps);
}

// Ask for `request` on output `name` (state `entry`). Returns {entry, start}: `start` is the argument vector to run now, or
// null when a command already runs (the request waits, merged: the last value wins) or there is nothing to run. A display that
// does not answer takes no change; a query (a replug) is always allowed.
function request(entry, name, req) {
    const e = Object.assign(fresh(), entry || {});
    if (!req || (req.kind !== "query" && e.status !== "ok"))
        return {entry: e, start: null};
    // `level` already counts what runs and what waits: the new request moves it from there.
    if (req.kind !== "query")
        e.level = expected(e.level, req);
    if (e.busy) {
        e.pending = merge(e.pending, req);
        return {entry: e, start: null};
    }
    const argv = argvFor(name, req);
    if (argv === null)
        return {entry: e, start: null};
    e.busy = true;
    if (e.status === "unknown")
        e.status = "probing";
    return {entry: e, start: argv};
}

// The running command of output `name` ended and printed `text`. Returns {entry, start, failed}: `start` is the request that
// waited, now to run (null for none); `failed` is true when the output just became a display without DDC/CI (the caller logs
// it once). The level is the printed one, moved by what still waits.
function finished(entry, name, text) {
    const e = Object.assign(fresh(), entry || {});
    const printed = parsePercent(text);
    let failed = false;
    e.busy = false;
    if (printed >= 0) {
        e.status = "ok";
        e.failures = 0;
        e.level = printed;
    } else if (e.status === "ok") {
        e.failures++;
        if (e.failures >= MAX_FAILURES) {
            e.status = "none";
            failed = true;
        }
    } else {
        e.status = "none";
        failed = true;
    }
    const next = e.pending;
    e.pending = null;
    if (e.status !== "ok" || next === null)
        return {entry: e, start: null, failed: failed};
    e.level = expected(e.level, next);
    const argv = argvFor(name, next);
    if (argv !== null)
        e.busy = true;
    return {entry: e, start: argv, failed: failed};
}

// The command that ended was not this entry's: it ran for the display on that connector before a replug. Nothing is learnt
// from it; what waited runs now. Returns {entry, start}.
function released(entry, name) {
    const e = Object.assign(fresh(), entry || {});
    const next = e.pending;
    e.busy = false;
    e.pending = null;
    if (next === null || (next.kind !== "query" && e.status !== "ok"))
        return {entry: e, start: null};
    const argv = argvFor(name, next);
    if (argv !== null) {
        e.busy = true;
        if (e.status === "unknown")
            e.status = "probing";
    }
    return {entry: e, start: argv};
}

// The output a brightness key acts on, and how. macOS changes the active display (the one with the key window, where the
// pointer last went: Hyprland's focused monitor, Compositor.activeScreenName, where the OSD already shows) when it can, and
// leaves the keys to the built-in panel's backlight when the active display cannot be changed (an external display without
// DDC/CI). `active`: the active output ("" unknown); `names`: the connected outputs; `backlight`: a backlight exists; `ddc`:
// output name -> entry. Returns {kind: "backlight" | "ddc" | "none", output}: `output` is the output changed, where the OSD
// shows ("" for the active display: a backlight without a connected built-in output, an all-in-one's panel).
function keyTarget(active, names, backlight, ddc) {
    const a = typeof active === "string" ? active : "";
    if (a !== "" && !isBuiltIn(a) && answers(ddc, a))
        return {kind: "ddc", output: a};
    if (backlight === true)
        return {kind: "backlight", output: isBuiltIn(a) ? a : builtIn(names)};
    return {kind: "none", output: a};
}

// The output Quick Settings' Display slider drives. macOS Control Center's Display slider is the built-in display's, and on a
// computer without one the main display's: the backlight when there is one, else the main display (ADR-0044) when it answers
// DDC/CI, else none (the module hides). `main`: MainDisplay.screenName ("" unknown).
function sliderTarget(names, backlight, ddc, main) {
    if (backlight === true)
        return {kind: "backlight", output: builtIn(names)};
    const m = typeof main === "string" ? main : "";
    if (m !== "" && !isBuiltIn(m) && answers(ddc, m))
        return {kind: "ddc", output: m};
    return {kind: "none", output: ""};
}

// The entries of the outputs still connected: one that went away is forgotten at once, before anything else is looked up, so a
// display plugged back is a new one whatever happens meanwhile.
function forget(ddc, names) {
    const list = Array.isArray(names) ? names : [];
    const next = {};
    for (const n of Object.keys(ddc || {})) {
        if (list.indexOf(n) >= 0)
            next[n] = ddc[n];
    }
    return next;
}

// The outputs to ask once (connected, external, a connector name, not virtual, never seen) and the entries of outputs that went away
// dropped (a replug asks again: another display may be on that connector). `running`: output name -> true while a command
// still runs for it; a new display on such a connector waits for that command to end (released) before it is asked, so one
// connector never has two commands at once. `serial`: the last number given; each new entry takes the next one. Returns
// {ddc, ask, serial}.
function sync(ddc, names, running, serial) {
    const list = Array.isArray(names) ? names : [];
    const next = {};
    const ask = [];
    let last = typeof serial === "number" && isFinite(serial) ? serial : 0;
    for (const n of list) {
        if (isBuiltIn(n) || isVirtual(n) || !isConnector(n) || Object.prototype.hasOwnProperty.call(next, n))
            continue;
        if (ddc && Object.prototype.hasOwnProperty.call(ddc, n) && ddc[n] !== null) {
            next[n] = ddc[n];
        } else if (running && running[n] === true) {
            next[n] = Object.assign(fresh(), {busy: true, pending: {kind: "query"}, serial: ++last});
        } else {
            next[n] = Object.assign(fresh(), {serial: ++last});
            ask.push(n);
        }
    }
    return {ddc: next, ask: ask, serial: last};
}

// ---- Displays that do not answer DDC/CI, remembered for the session ----

// The identity of a display: "<model>|<serial>" as the compositor reports them (EDID), "connector:<name>" when both are empty
// (nothing better to tell it apart by). Control characters are dropped and each part is cut at 64 characters.
function identity(model, serial, name) {
    const clean = v => String(v === undefined || v === null ? "" : v).replace(/[\u0000-\u001f\u007f|]/g, "").trim().slice(0, 64);
    const m = clean(model), s = clean(serial);
    if (m === "" && s === "")
        return isConnector(name) ? "connector:" + name : "";
    return m + "|" + s;
}

// The file that keeps them across restarts of the shell, per compositor instance, in the session's runtime directory (gone at
// logout): "" without a runtime directory.
function silentPath(runtimeDir, instance, display) {
    const dir = String(runtimeDir || "");
    if (dir === "" || dir.charAt(0) !== "/")
        return "";
    const id = String(instance || display || "default").replace(/[^A-Za-z0-9_.-]/g, "_");
    return dir + "/grassfield-ddc-silent-" + id;
}

// The remembered displays: identity -> {at: wall ms of the last failure}. Anything malformed is dropped.
function parseSilent(text) {
    const out = {};
    let o;
    try {
        o = JSON.parse(String(text || ""));
    } catch (e) {
        return out;
    }
    if (o === null || typeof o !== "object" || Array.isArray(o) || o.v !== 1 || o.silent === null || typeof o.silent !== "object")
        return out;
    for (const k of Object.keys(o.silent)) {
        const at = o.silent[k];
        if (typeof k === "string" && k.length > 0 && k.length <= 160 && typeof at === "number" && isFinite(at) && at >= 0)
            out[k] = at;
    }
    return out;
}

function formatSilent(silent) {
    return JSON.stringify({v: 1, silent: silent || {}});
}

// `id` failed at `now` (wall ms): the map with it, the oldest dropped past MAX_SILENT.
function rememberSilent(silent, id, now) {
    const next = Object.assign({}, silent || {});
    if (typeof id !== "string" || id === "")
        return next;
    next[id] = now;
    const keys = Object.keys(next).sort((a, b) => next[a] - next[b]);
    while (keys.length > MAX_SILENT)
        delete next[keys.shift()];
    return next;
}

function forgetSilent(silent, id) {
    const next = Object.assign({}, silent || {});
    delete next[id];
    return next;
}

// `id` is remembered and its failure is recent enough that a new connection does not ask it again. A failure time in the
// future (the wall clock moved back) does not count as recent: the display is asked.
function isSilent(silent, id, now) {
    if (!silent || typeof id !== "string" || id === "" || !Object.prototype.hasOwnProperty.call(silent, id))
        return false;
    const age = now - silent[id];
    return age >= 0 && age < REPROBE_AFTER_MS;
}

// sync() for displays remembered as silent: the outputs in `s.ask` whose identity (`ids`: output name -> identity) is silent are
// not asked; their entries read "none" at once (no command, no journal line). Returns {ddc, ask}.
function skipSilent(s, ids, silent, now) {
    const ddc = Object.assign({}, s.ddc);
    const ask = [];
    for (const n of s.ask) {
        if (isSilent(silent, ids ? ids[n] : "", now))
            ddc[n] = Object.assign({}, ddc[n], {status: "none"});
        else
            ask.push(n);
    }
    return {ddc: ddc, ask: ask};
}

// A brightness key on output `name` while it reads "none": ask it again (the person asks for it) unless a command runs for it
// or it was asked less than KEY_REPROBE_MS ago (`probedAt`: wall ms of its last query, 0 for none). A clock that moved back
// allows it.
function keyReprobe(entry, name, now, probedAt) {
    if (!entry || entry.status !== "none" || entry.busy === true || isBuiltIn(name) || isVirtual(name) || !isConnector(name))
        return false;
    const age = now - (typeof probedAt === "number" && isFinite(probedAt) ? probedAt : 0);
    return age < 0 || age >= KEY_REPROBE_MS;
}
