.pragma library

// Hot corner actions (pure, unit-tested). Each action is a call into another shell surface
// through `qs ipc`, so the surfaces stay decoupled from the desktop layer.

const ACTIONS = ["none", "overview", "notifications", "apps", "lock"];

// IPC target and function of each action on this shell instance. "lock" is not one: the session lock lives in the security
// process (ADR-0041 S2), and the corner asks it through SessionState.requestLock (in process, then LockClient over IPC).
const IPC = {
    overview: ["overview", "toggle"],
    notifications: ["notifications", "toggleCenter"],
    apps: ["apps", "toggle"]
};

// Action name clamped to the enum; unknown values mean "none".
function normalize(action) {
    return ACTIONS.indexOf(action) >= 0 ? action : "none";
}

// Actions called in-process: "notifications" needs the corner's screen (the IPC handler takes no argument), HotCorners calls
// Notifications.toggleCenter(screen) itself; "lock" goes to SessionState.requestLock("corner"), which LockClient sends to the
// security process (ADR-0041 S2).
function isDirect(action) {
    const name = normalize(action);
    return name === "notifications" || name === "lock";
}

// argv of the IPC call for an action against the shell process `pid`, or null for none and for
// direct actions.
function command(action, pid) {
    const name = normalize(action);
    const target = isDirect(name) ? null : IPC[name];
    return target ? ["qs", "ipc", "--pid", String(pid), "call", target[0], target[1]] : null;
}

// No firing while the session is locked (every target refuses then too) or while the Notification Center that the
// "notifications" action toggles is open. The "lock" action is blocked by the lock only while it is confirmed
// (`lockConfirmed`, SessionState.lockConfirmed; absent means confirmed): while the UI reads locked only because the security
// process is down, the corner still sends its lock request (ADR-0041 S2, the opus review of 77a0ceb3, MAJOR-1).
function isBlocked(action, notificationsOpen, locked, lockConfirmed) {
    if (locked === true && (normalize(action) !== "lock" || lockConfirmed !== false))
        return true;
    return normalize(action) === "notifications" && notificationsOpen === true;
}

// {x, y} of `hyprctl cursorpos -j` (the pointer in layout coordinates), null for anything else.
function cursorPosition(text) {
    let v = null;
    try {
        v = JSON.parse(String(text));
    } catch (e) {
        return null;
    }
    return v && Number.isFinite(v.x) && Number.isFinite(v.y) ? {x: v.x, y: v.y} : null;
}

// Distance of the pointer (layout coordinates) from `corner` of `screen` ({x, y, width, height}): the larger of the two
// axis distances, as PointerTracker positions are measured; Infinity on another screen.
function cornerDistance(corner, screen, px, py) {
    if (!screen || px < screen.x || py < screen.y || px >= screen.x + screen.width || py >= screen.y + screen.height)
        return Infinity;
    const dx = String(corner).endsWith("Left") ? px - screen.x : screen.x + screen.width - 1 - px;
    const dy = String(corner).startsWith("top") ? py - screen.y : screen.y + screen.height - 1 - py;
    return Math.max(dx, dy);
}

// True when `qs ipc show` output lists the target (the Apps surface may not exist yet).
function hasTarget(showOutput, target) {
    const re = new RegExp("^\\s*target " + target.replace(/[^\w.-]/g, "") + "\\s*$", "m");
    return re.test(String(showOutput));
}
