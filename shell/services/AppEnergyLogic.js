.pragma library

// What the person can see, per window and per process, for the app energy policy (ADR-0048 D-1): pure, no compositor
// access, unit tested in tests/unit/tst_appenergy.qml. AppEnergy.qml feeds it Compositor.energySnapshot() and runs the
// helper packaging/bin/grassfield-energy, which maps processes to app scopes, checks the claims and applies the ladder.
//
// Window: {address, pid, workspaceId, workspaceName, mapped, hidden (Hyprland's), minimized (the shell's record), floating,
// pinned, fullscreen (Hyprland's mode mask: 1 maximized, 2 full screen), x, y, w, h (layout coordinates)}.
// Context: {focused: [addresses] (the focused window, and the window in front of a quick look), shown: [workspace ids each
// display shows], parked: [workspace names that park windows: minimized, hidden, Show Desktop], strip: {address: "visible" |
// "hidden"} (Stages strip windows), awake: everything counts as visible (overview or app switcher open)}.

const FOCUSED = "focused";
const VISIBLE = "visible";
const OCCLUDED = "occluded";
const HIDDEN = "hidden";
const ORDER = [FOCUSED, VISIBLE, OCCLUDED, HIDDEN]; // most awake first

// The picture settles this long after the last change before it is judged (a workspace switch restacks everything).
const settleMs = 250;
// The helper asks to be run again after at most this long while anything is limited, claimed or waiting.
const maxTickMs = 60000;
// A refresh of Hyprland's window data asked because a process was unknown is not asked again sooner than this.
const refreshGapMs = 2000;

function moreAwake(a, b) {
    return ORDER.indexOf(a) < ORDER.indexOf(b) ? a : b;
}

function finite(n) {
    return typeof n === "number" && Number.isFinite(n);
}

// `outer` contains `inner` entirely (both {x, y, w, h}); false when either has no usable geometry.
function covers(outer, inner) {
    if (!outer || !inner || ![outer.x, outer.y, outer.w, outer.h, inner.x, inner.y, inner.w, inner.h].every(finite))
        return false;
    if (outer.w <= 0 || outer.h <= 0 || inner.w <= 0 || inner.h <= 0)
        return false;
    return outer.x <= inner.x && outer.y <= inner.y && outer.x + outer.w >= inner.x + inner.w && outer.y + outer.h >= inner.y + inner.h;
}

function parked(w, ctx) {
    return w.minimized === true || w.mapped === false || w.hidden === true || (ctx.parked || []).indexOf(w.workspaceName) >= 0;
}

// The window known to be above every other window of its workspace (config/hypr/grassfield/stacking.lua raises the window
// that becomes active when it is floating, not full screen, on a workspace that shows no full-screen window), or null.
// Only the focused window qualifies: nothing else's place in the stacking order is known to the shell.
function occluder(windows, ctx) {
    const focused = ctx.focused || [];
    const top = windows.find(w => focused.indexOf(w.address) >= 0 && !parked(w, ctx));
    if (!top || top.floating !== true || (top.fullscreen | 0) >= 2)
        return null;
    if (windows.some(w => w !== top && w.workspaceId === top.workspaceId && !parked(w, ctx) && (w.fullscreen | 0) >= 2))
        return null;
    return top;
}

// The state of one window. `top`: occluder(windows, ctx).
function windowState(w, ctx, top) {
    if ((ctx.focused || []).indexOf(w.address) >= 0)
        return FOCUSED;
    if (ctx.awake === true)
        return VISIBLE;
    if (parked(w, ctx))
        return HIDDEN;
    const strip = ctx.strip ? ctx.strip[w.address] : undefined;
    if (strip === HIDDEN || strip === VISIBLE)
        return strip;
    // Special workspaces other than the parking ones (a scratchpad) may be shown: visible (when unsure, do not limit).
    if (w.workspaceId < 0)
        return VISIBLE;
    if ((ctx.shown || []).indexOf(w.workspaceId) < 0)
        return HIDDEN;
    // One window covers it outright or it is not occluded: regions are never summed.
    if (top && top !== w && w.pinned !== true && w.workspaceId === top.workspaceId && covers(top, w))
        return OCCLUDED;
    return VISIBLE;
}

// {pids: {pid: state} merged per process (most awake), uncertain}. A window whose process is not known yet (Hyprland gives
// the pid after a refresh) makes the picture uncertain when it is focused or visible: then every process counts as visible
// (nothing is limited) until the data is refreshed.
function evaluate(windows, ctx) {
    const list = Array.isArray(windows) ? windows : [];
    const top = occluder(list, ctx);
    const pids = {};
    let uncertain = false;
    for (let i = 0; i < list.length; i++) {
        const w = list[i];
        const state = windowState(w, ctx, top);
        if (!(w.pid > 0)) {
            if (state === FOCUSED || state === VISIBLE)
                uncertain = true;
            continue;
        }
        const key = String(w.pid);
        pids[key] = pids[key] === undefined ? state : moreAwake(pids[key], state);
    }
    if (uncertain) {
        for (const key in pids) {
            if (pids[key] !== FOCUSED)
                pids[key] = VISIBLE;
        }
    }
    return {pids: pids, uncertain: uncertain};
}

// Stages strip windows (StagesLink.state, StagesState.parse): {address: "visible" | "hidden"}. A strip tile draws its windows
// live (visible); a hidden strip, or a stage beyond the tiles, hides them. The active stage's windows are not listed.
function stripStates(stages) {
    const out = {};
    if (!stages || stages.on !== true || !stages.monitors)
        return out;
    for (const name in stages.monitors) {
        const m = stages.monitors[name];
        const list = m && Array.isArray(m.stages) ? m.stages : [];
        for (let i = 0; i < list.length; i++) {
            const s = list[i];
            if (s.id === m.active)
                continue;
            const state = m.hidden === true || !(s.slot >= 0) ? HIDDEN : VISIBLE;
            (s.windows || []).forEach(w => out[w.address] = state);
        }
    }
    return out;
}

// Processes with a PipeWire stream (the `properties` maps of the stream nodes): playing or recording (a claim, D-3). The
// process is the one the PipeWire server saw on the other end of the socket (`pipewire.sec.pid`): `application.process.id`
// is set by the client, so one app could name another's process and keep it from being slowed (security review of the Luma
// pull request, finding 3). A stream without the server's pid names no process.
function streamPids(propertyMaps) {
    const out = [];
    (propertyMaps || []).forEach(p => {
        const n = p ? parseInt(p["pipewire.sec.pid"], 10) : NaN;
        if (n > 0 && n < 4194304 && out.indexOf(n) < 0)
            out.push(n);
    });
    return out.sort((a, b) => a - b);
}

// The picture the helper acts on, as one string: a round runs only when it changed (or when the helper asked to run again).
function digest(pids, power, media) {
    const keys = Object.keys(pids || {}).sort((a, b) => a - b);
    return JSON.stringify([power, keys.map(k => [k, pids[k]]), media || []]);
}

// Whether the helper may run at all: on battery, or on the power adapter only to lift what is still held (`engaged`: the last
// round left limits or asked to run again). A computer without a battery is never on battery: it never limits (ADR-0048 D-2).
function roundWanted(onBattery, engaged) {
    return onBattery === true || engaged === true;
}

// An occluded state rests on Hyprland's last read of the windows' geometry, and a move or a resize sends no event: before a
// picture with an occluded process is acted on, the data must have been read again within refreshGapMs (`refreshedAt`, ms).
function needsFreshGeometry(pids, refreshedAt, now) {
    for (const key in pids || {}) {
        if (pids[key] === OCCLUDED)
            return !(now - refreshedAt <= refreshGapMs);
    }
    return false;
}

// True when some process is not focused or visible: only then can anything be limited.
function anyLimitable(pids) {
    for (const key in pids || {}) {
        if (pids[key] === OCCLUDED || pids[key] === HIDDEN)
            return true;
    }
    return false;
}

// The helper's argv for a round. `base`: the program and the options every command takes (--dry-run, --state).
function roundArgs(base, pids, onBattery, media) {
    const args = base.slice(0, 1).concat(["round"]).concat(base.slice(1));
    args.push("--power", onBattery ? "battery" : "mains", "--windows", JSON.stringify(pids || {}));
    if (media && media.length > 0)
        args.push("--media", media.join(","));
    return args;
}

function wakeArgs(base, pids) {
    const args = base.slice(0, 1).concat(["wake"]).concat(base.slice(1));
    if (pids === null) {
        args.push("--all");
    } else {
        pids.filter(p => p > 0).forEach(p => args.push("--pid", String(p)));
    }
    return args;
}

function resetArgs(base) {
    return base.slice(0, 1).concat(["reset"]).concat(base.slice(1));
}

// The helper's answer to a round: milliseconds until it wants to run again (0: not needed), bounded by maxTickMs; a reply
// that cannot be read asks again at maxTickMs (when unsure, keep checking rather than leave a limit unattended).
function nextRunMs(text) {
    let reply = null;
    try {
        reply = JSON.parse(String(text).trim().split("\n").pop());
    } catch (e) {
        return maxTickMs;
    }
    if (!reply || typeof reply.next !== "number" || !Number.isFinite(reply.next))
        return maxTickMs;
    return reply.next <= 0 ? 0 : Math.min(maxTickMs, Math.max(1000, Math.round(reply.next * 1000)));
}
