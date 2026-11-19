.pragma library

// The shell's key and gesture requests, delivered in-process (ADR "keys reach the shell in-process"): bindings.lua sends
// Hyprland's `event` dispatcher, which writes `custom>>gfkey/1 <target> <function> [argument...]` (or `custom>>gfgesture/1
// <kind> <phase> <progress>`) on socket2; the shell already reads that socket (Quickshell.Hyprland rawEvent). No process is
// started per key, and socket2 keeps the order the keys were pressed in.
//
// Only the requests a binding sends are accepted, with their arguments checked here: the payload comes from a socket any
// process of the user can write to (as `qs ipc` can be called by any of them), so nothing reaches a test hook or a
// function a key does not call. The functions are the IpcHandler ones (same target, same name): the handler that answers
// `qs ipc` answers the key, with its own checks (a locked session refuses, as for any request).

const keyPrefix = "gfkey/1 ";
const gesturePrefix = "gfgesture/1 ";

// target -> function -> the kinds of its arguments, in order: "id" (digits, the switcher's hold id), "word" (letters,
// digits and dashes), "int" (1..99), "screen" (an output name or nothing: always the last, "" when absent).
const requests = {
    switcher: {next: ["id"], previous: ["id"], release: ["id"], quit: [], hide: []},
    windows: {
        tile: ["word"],
        arrange: ["word"],
        nextOutput: ["word"],
        tilePopover: [],
        minimize: [],
        hide: [],
        cycleApp: [],
        showDesktop: []
    },
    search: {toggle: [], clipboard: []},
    emoji: {toggle: []},
    apps: {toggle: [], open: [], close: []},
    overview: {toggle: [], open: [], close: []},
    notifications: {toggleCenter: []},
    capture: {toggle: []},
    menubar: {open: ["word", "screen"], panel: ["word", "screen"]},
    dock: {keyboard: [], toggleAutohide: []},
    zoom: {toggle: [], zoomIn: [], zoomOut: []},
    stages: {activate: ["int"], newStage: []},
    volume: {up: [], down: [], mute: []},
    brightness: {up: [], down: []},
    keyboard: {up: [], down: []}
};

const gestureKinds = ["overview-open", "overview-close", "apps-open", "apps-close"];
const gesturePhases = ["begin", "update", "end", "cancel"];

function argument(kind, text) {
    if (kind === "screen")
        return text === undefined ? "" : (/^[A-Za-z0-9._-]{1,64}$/.test(text) ? text : null);
    if (text === undefined)
        return null;
    if (kind === "id")
        return /^[0-9]{1,16}$/.test(text) ? text : null;
    if (kind === "word")
        return /^[A-Za-z][A-Za-z0-9-]{0,31}$/.test(text) ? text : null;
    if (kind === "int")
        return /^[1-9][0-9]?$/.test(text) ? parseInt(text, 10) : null;
    return null;
}

// A key request: {target, fn, args} or null (another payload, an unknown request, a malformed argument).
function parseKey(data) {
    if (typeof data !== "string" || !data.startsWith(keyPrefix) || data.length > 200)
        return null;
    const words = data.slice(keyPrefix.length).split(" ");
    const target = words[0];
    const fn = words[1];
    const table = Object.prototype.hasOwnProperty.call(requests, target) ? requests[target] : null;
    if (!table || !Object.prototype.hasOwnProperty.call(table, fn))
        return null;
    const kinds = table[fn];
    const given = words.slice(2);
    if (given.length > kinds.length)
        return null;
    const args = [];
    for (let i = 0; i < kinds.length; i++) {
        const value = argument(kinds[i], given[i]);
        if (value === null)
            return null;
        args.push(value);
    }
    return {target: target, fn: fn, args: args};
}

// A gesture step: {kind, phase, progress (0..1), commit} or null. `commit` is set on "end" only: the gesture completes
// (the surface opens or closes) rather than going back.
function parseGesture(data) {
    if (typeof data !== "string" || !data.startsWith(gesturePrefix) || data.length > 100)
        return null;
    const words = data.slice(gesturePrefix.length).split(" ");
    if (gestureKinds.indexOf(words[0]) < 0 || gesturePhases.indexOf(words[1]) < 0)
        return null;
    if (!/^(0|1|0\.[0-9]{1,4})$/.test(words[2] ?? ""))
        return null;
    const extra = words[1] === "end" ? 4 : 3;
    if (words.length !== extra)
        return null;
    if (extra === 4 && words[3] !== "commit" && words[3] !== "back")
        return null;
    return {kind: words[0], phase: words[1], progress: parseFloat(words[2]), commit: extra === 4 && words[3] === "commit"};
}

// The discrete request a finished gesture stands for when nothing follows the gesture's progress: {target, fn} or null
// (gone back, or still running).
function gestureFallback(step) {
    if (!step || step.phase !== "end" || !step.commit)
        return null;
    const parts = step.kind.split("-");
    return {target: parts[0], fn: parts[1]};
}

// The handler that answers `target` among those attached: the first live one whose `enabled` is not false (Quickshell
// keeps one enabled handler per target; shell.qml's early ones hand over to the surface's by `enabled`).
function pick(list) {
    if (!list)
        return null;
    for (let i = 0; i < list.length; i++) {
        const h = list[i];
        if (h && h.enabled !== false)
            return h;
    }
    return null;
}

// `list` without the handlers that are gone (a destroyed QObject reads as null) and without `handler` twice.
function attached(list, handler) {
    const out = (list ?? []).filter(h => h !== null && h !== undefined && h !== handler);
    out.push(handler);
    return out;
}

// What a surface that follows the gesture (Overview: target "overview", Apps: "apps") does with one step, given whether it
// is open and the progress it draws (`current`, 0..1, or -1 when no gesture drives it): null (nothing), or {action,
// progress}: action "show" (open it, from progress 0 when `progress` is 0), "close" (the surface's own close; the drawn
// progress stays where it is and goes on to 0 from there once the surface has closed) or "" (the progress alone), and
// `progress` the value it draws from now on (-1: its own state again, animated from where it is: 1 open, 0 closed).
// The *-close kinds mirror the *-open ones (progress 1 - p). With Reduce Motion nothing follows the fingers: the end
// alone counts, as the discrete gesture did (macOS: the gesture still works, without the zoom).
function followStep(target, open, current, step, reduceMotion) {
    if (!step || typeof step.kind !== "string")
        return null;
    const parts = step.kind.split("-");
    if (parts[0] !== target)
        return null;
    const opening = parts[1] === "open";
    const tracking = current >= 0;
    switch (step.phase) {
    case "begin":
        if (reduceMotion || tracking)
            return null;
        if (opening)
            return open ? null : {action: "show", progress: 0};
        return open ? {action: "", progress: 1} : null;
    case "update":
        if (!tracking)
            return null;
        return {action: "", progress: Math.max(0, Math.min(1, opening ? step.progress : 1 - step.progress))};
    case "end":
        if (step.commit) {
            if (opening)
                return open && !tracking ? null : {action: open ? "" : "show", progress: -1};
            if (open)
                return {action: "close", progress: tracking ? current : -1};
            return tracking ? {action: "", progress: -1} : null;
        }
        break;
    case "cancel":
        break;
    default:
        return null;
    }
    // Gone back (an end without commit, or a cancel): the surface returns to where the gesture found it.
    if (!tracking)
        return null;
    return opening ? {action: "close", progress: current} : {action: "", progress: -1};
}
