.pragma library

// The two runtime files of Settings > Displays (ADR-0031). Pure functions, unit-tested (tests/unit/tst_displaysfile.qml); the
// Settings app reads and writes the same files (apps/settings/qml/Displays.js, apps/settings/src/displayfiles.h).
//
//   state  (the shell writes it, Settings reads it)
//     {"v":1,"monitors":[{"name":"eDP-1","description":"BOE 0x0BCA","make":"BOE","model":"0x0BCA","serial":"",
//       "width":2880,"height":1800,"physicalWidth":300,"physicalHeight":190 (mm),"refreshRate":120,"x":0,"y":0,"scale":1.6,
//       "transform":0,"disabled":false,
//       "availableModes":["2880x1800@120.00Hz",...]}],
//      "backlight":{"device":"intel_backlight","level":0.5}|null,
//      "trial":{"id":"a1b2","state":"applying"|"applied"|"kept"|"reverted"}|null}
//   trial  (Settings writes it, the shell and config/hypr/grassfield/displays.lua read it)
//     trial <id> until <unix time>     a change on trial, then the lines of the would-be displays.conf
//     kept <id>                        the user kept it (Settings wrote displays.conf first)
//     revert <id>                      the user asked for the previous settings
//
// Paths: in a dev session $GRASSFIELD_STATE_HOME/displays.json and display-trial.conf (only the nested shell and the nested
// Hyprland read them); otherwise $XDG_RUNTIME_DIR/grassfield-displays.json and grassfield-display-trial.conf (per session,
// gone at logout). "" when the directory is not known.

var VERSION = 1;
// The longest trial: Settings writes a deadline at most this many seconds ahead (apps/settings/src/backend.cpp kMaxTrialSeconds),
// config/hypr/grassfield/displays.lua applies none further ahead. A farther deadline is not a trial Settings wrote: taken back.
var MAX_TRIAL_SECONDS = 60;

function statePath(dev, stateHome, runtimeDir) {
    if (dev)
        return stateHome ? String(stateHome) + "/displays.json" : "";
    return runtimeDir ? String(runtimeDir) + "/grassfield-displays.json" : "";
}

function trialPath(dev, stateHome, runtimeDir) {
    if (dev)
        return stateHome ? String(stateHome) + "/display-trial.conf" : "";
    return runtimeDir ? String(runtimeDir) + "/grassfield-display-trial.conf" : "";
}

function str(v) {
    return typeof v === "string" ? v : "";
}

function num(v) {
    return typeof v === "number" && isFinite(v) ? v : 0;
}

// One monitor of Quickshell's Hyprland module (its lastIpcObject, Hyprland's own `monitors` answer) as the apps read it.
function monitorOf(ipc) {
    const o = ipc && typeof ipc === "object" ? ipc : {};
    return {name: str(o.name), description: str(o.description), make: str(o.make), model: str(o.model), serial: str(o.serial),
        width: num(o.width), height: num(o.height), physicalWidth: num(o.physicalWidth), physicalHeight: num(o.physicalHeight),
        refreshRate: num(o.refreshRate), x: num(o.x), y: num(o.y),
        scale: num(o.scale) || 1, transform: num(o.transform), disabled: o.disabled === true,
        availableModes: Array.isArray(o.availableModes) ? o.availableModes.filter(m => typeof m === "string") : []};
}

// The state file's text. `monitors` are lastIpcObject values (those without a name are left out), `backlight` is
// {device, level} or null, `trial` {id, state} or null.
function payload(monitors, backlight, trial) {
    const list = (Array.isArray(monitors) ? monitors : []).map(monitorOf).filter(m => m.name !== "");
    const light = backlight && str(backlight.device) !== "" ? {device: backlight.device, level: Math.max(0, Math.min(1, num(backlight.level)))} : null;
    const t = trial && /^[A-Za-z0-9]{1,32}$/.test(str(trial.id)) ? {id: trial.id, state: str(trial.state)} : null;
    return JSON.stringify({v: VERSION, monitors: list, backlight: light, trial: t}) + "\n";
}

// Whether `text` is what the state file already holds (`last` is the text last written, "" before any): then it is not written again.
function same(last, text) {
    return typeof last === "string" && last !== "" && last === text;
}

// The first line of a trial file: {state: "trial", id, until (unix seconds)} | {state: "kept"|"revert", id} | null.
function parseTrial(text) {
    const first = String(text).split("\n")[0];
    let m = /^trial ([A-Za-z0-9]{1,32}) until ([0-9]{1,12})$/.exec(first);
    if (m)
        return {state: "trial", id: m[1], until: parseInt(m[2], 10)};
    m = /^(kept|revert) ([A-Za-z0-9]{1,32})$/.exec(first);
    return m ? {state: m[1], id: m[2]} : null;
}

// What the shell does with a trial file's first line, given the trial it runs (its id, or "" for none) and whether the shell
// just started: "apply" (reload into it, start the countdown), "keep" (empty the file, no reload), "revert" (empty the file and
// reload), or "" (nothing: the file is empty, already handled, or not ours).
function action(trial, running, starting, now) {
    if (trial === null)
        return running !== "" ? "revert" : "";
    if (trial.state === "trial") {
        // A trial found when the shell starts was left by a shell that stopped: its countdown is gone, take it back. So is one
        // past its deadline, or with a deadline further ahead than any trial Settings writes.
        if (starting || trial.until <= now || trial.until > now + MAX_TRIAL_SECONDS)
            return "revert";
        return trial.id === running ? "" : "apply";
    }
    if (trial.id !== running)
        return "";
    return trial.state === "kept" ? "keep" : "revert";
}

// The countdown of the trial being applied, in ms: never below 0, never longer than the longest trial (action() takes back a
// farther deadline; a Timer's interval is an int).
function countdownMs(until, nowMs) {
    return Math.max(0, Math.min(MAX_TRIAL_SECONDS * 1000, until * 1000 - nowMs));
}

// The trial's state once Hyprland answered a reload (SessionConfig's ticket, and whether it said "ok": it answers once it has
// read its configuration again). Only the answer to the reload that applies the trial the shell runs (`applying` is that
// reload's ticket) makes it "applied" (the mode is set: Keep can be taken); any other answer, a refusal, or no answer leaves it
// as it is (the deadline takes back a trial Hyprland did not apply).
function answered(trialState, running, applying, ticket, ok) {
    if (ok && ticket > 0 && ticket === applying && trialState && running !== "" && trialState.id === running
        && trialState.state === "applying")
        return {id: running, state: "applied"};
    return trialState;
}

// ---- A display without a mode (the owner's rc6 report: external displays black after sleep until unplugged) ----
// A monitor that was asleep or switched off when it was probed answers a partial EDID with no video modes: Hyprland brings it
// up at 0x0 (Hyprland 0.56.2 Monitor.cpp applyMonitorRule: "NO FALLBACK MODES", three retries a second apart, then it gives up)
// and the screen stays black. Powering it on fires no hot-plug, so nothing asks again; a configuration reload makes Hyprland
// apply its rule, and read its modes, once more. Omarchy's own session does exactly that (omarchy-hyprland-monitor-watch and
// omarchy-hyprland-monitor-modeless: an enabled monitor at 0x0, then a reload, with a back-off); Grassfield's session replaced
// Omarchy's autostart and did not.

// The names of the monitors (Hyprland's `monitors` answer, lastIpcObject values) that are enabled without a mode: a width or a
// height of exactly 0. An answer without a name or without numeric sizes (in flight) is not one.
function modeless(monitors) {
    const list = Array.isArray(monitors) ? monitors : [];
    return list.filter(o => o && typeof o === "object" && str(o.name) !== "" && o.disabled !== true && typeof o.width === "number"
        && typeof o.height === "number" && (o.width === 0 || o.height === 0)).map(o => o.name);
}

// The connector name of a `monitoraddedv2` / `monitorremovedv2` event ("<id>,<name>,<description>"), for the journal: only a
// plain connector name (letters, digits, '-', '_', '.', ':', at most 32), never the description (it holds the serial).
function eventOutput(data) {
    const name = String(data === undefined || data === null ? "" : data).split(",")[1] || "";
    return /^[A-Za-z0-9._:-]{1,32}$/.test(name) ? name : "(unnamed)";
}

var RECOVERY_FIRST_MS = 3000;
var RECOVERY_MAX_MS = 60000;
// The reloads on the back-off (3, 6, 12, 24, 48, 60, 60, 60 s: about 4.5 minutes, longer than a display takes to wake and
// answer its modes); after them the reloads stop while someone may be looking (audit SC-05: each reload puts the
// configuration's blur, window edges, ground, zoom and pointer back until the shell's pushes land, a visible flash every
// minute for as long as a display stays switched off at its button, all night).
var RECOVERY_ATTEMPTS = 8;
// After the back-off, while nobody can see a reload (the session locked or the displays off): one reload this often.
var RECOVERY_QUIET_MS = 600000;
// The wait before the reload a nudge asks for (the session unlocked, the displays back on, a display added or removed).
var RECOVERY_NUDGE_MS = 3000;

// The wait before the next look at a display without a mode, after `attempts` reloads: 3 s (Hyprland's own three retries are
// over), doubled after each reload, at most a minute, for RECOVERY_ATTEMPTS reloads. After those: RECOVERY_QUIET_MS while
// `quiet` (locked or displays off: no one sees the flash), else 0 = no reload on a timer; a nudge (nudgeDelayMs) asks for one.
function recoveryDelayMs(attempts, quiet) {
    const n = typeof attempts === "number" && isFinite(attempts) && attempts > 0 ? Math.floor(attempts) : 0;
    if (n >= RECOVERY_ATTEMPTS)
        return quiet === true ? RECOVERY_QUIET_MS : 0;
    return n >= 5 ? RECOVERY_MAX_MS : Math.min(RECOVERY_MAX_MS, RECOVERY_FIRST_MS * Math.pow(2, n));
}

// A nudge: the moment a display switched on at its button is most likely to be noticed (the session unlocked, the displays
// back on from idle, a display added or removed). Past the back-off, one reload RECOVERY_NUDGE_MS later; during it, nothing
// more (its timer already runs): -1.
function nudgeDelayMs(attempts) {
    const n = typeof attempts === "number" && isFinite(attempts) && attempts > 0 ? Math.floor(attempts) : 0;
    return n >= RECOVERY_ATTEMPTS ? RECOVERY_NUDGE_MS : -1;
}
