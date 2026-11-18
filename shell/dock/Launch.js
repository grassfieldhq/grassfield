.pragma library

// Launch and activation rules of the Dock (pure functions, tested in tests/unit/tst_docklaunch.qml).
//
// Launch state of one tile: idle -> launching (click on an app with no window) -> running (its first window mapped) or
// idle again (timeout, or the tile is gone). The state is the `launching` map: key -> start time (ms); a key that is
// absent is idle.

// State of a tile: "idle", "launching" or "running" (a window exists, whatever the map says).
function stateOf(launching, key, windowCount, now, timeoutMs) {
    if (windowCount > 0)
        return "running";
    const started = launching ? launching[key] : undefined;
    // Not a number: absent, or a key such as "constructor" read from the map's prototype.
    if (typeof started !== "number" || now - started > timeoutMs)
        return "idle";
    return "launching";
}

// A click on a tile with no window. {start, launching}: `start` is false (and the map unchanged) while the tile is
// already launching, so a double click never starts the app twice.
function click(launching, key, now, timeoutMs) {
    if (stateOf(launching, key, 0, now, timeoutMs) === "launching")
        return {start: false, launching: launching};
    const next = Object.assign({}, launching ? launching : {});
    next[key] = now;
    return {start: true, launching: next};
}

// Windows to activate when a running app is clicked, in the order to activate them: the last one ends focused and in
// front. Each window is {ref, minimized, here (on the focused Desktop), stamp (recency, higher is more recent)}.
//   - visible windows on this Desktop: all of them come forward, the most recent last (macOS: every window of the app);
//   - none here: the most recent visible window (the Desktop switches to it);
//   - everything minimized: only the most recent one is restored.
function activationPlan(windows) {
    if (!windows || windows.length === 0)
        return [];
    const byRecency = (a, b) => a.stamp - b.stamp;
    const visible = windows.filter(w => !w.minimized);
    if (visible.length === 0) {
        const last = windows.slice().sort(byRecency).pop();
        return [last.ref];
    }
    const here = visible.filter(w => w.here);
    if (here.length > 0)
        return here.slice().sort(byRecency).map(w => w.ref);
    return [visible.slice().sort(byRecency).pop().ref];
}

// What a click on a running app's tile does. `windows`: {ref, minimized, here, focused (owns the keyboard focus), fullscreen,
// stamp}; `clickMinimizes`: Settings > Desktop & Dock "Click an open app's icon to minimize its windows". Returns
// {action: "minimize" | "restore" | "forward", refs}, refs in the order to act on them (the most recent last).
//   - setting on, the app is frontmost (a visible window of it on this Desktop is focused): minimize every visible window on this
//     Desktop except full-screen ones (none left: forward, nothing is touched);
//   - setting on, nothing of the app shown on this Desktop but some windows minimized: restore all minimized ones, the most recent
//     ends focused (windows on other Desktops are left alone);
//   - full-screen windows and Split View members are never minimized (Compositor.minimize refuses them): forward;
//   - otherwise (setting off, or not frontmost): activationPlan, as macOS.
function clickPlan(windows, clickMinimizes) {
    const all = windows ? windows : [];
    if (clickMinimizes && all.length > 0) {
        const byRecency = (a, b) => a.stamp - b.stamp;
        const frontmost = all.some(w => w.focused && !w.minimized && w.here);
        if (frontmost) {
            const targets = all.filter(w => !w.minimized && w.here && !w.fullscreen && !w.split);
            if (targets.length > 0)
                return {action: "minimize", refs: targets.slice().sort(byRecency).map(w => w.ref)};
        } else if (!all.some(w => !w.minimized && w.here) && all.some(w => w.minimized)) {
            // Nothing of the app is shown on this Desktop: what was minimized comes back and stays here, even when the app has a
            // window on another Desktop (that window is not visited).
            return {action: "restore", refs: all.filter(w => w.minimized).sort(byRecency).map(w => w.ref)};
        }
    }
    return {action: "forward", refs: activationPlan(all)};
}

// Processes to kill for "Force Quit" on an app's tile (Option variant of Quit): the distinct client PIDs of its windows. PIDs that
// are not plain client processes (unknown 0, init 1, negatives, non-integers) are dropped, as Power.forceQuit refuses them.
function forceQuitPids(pids) {
    const out = [];
    for (const p of pids || []) {
        if (Number.isInteger(p) && p > 1 && out.indexOf(p) < 0)
            out.push(p);
    }
    return out;
}

// The last rows of a running app's Dock menu: Hide and Quit (macOS), with Option Hide Others and Force Quit, and Force Quit
// without Option for an app that does not respond (ADR-0035 decision 3-5). With `endTask` (Settings > Desktop & Dock, owner
// AQ5, ADR-0038 AM63) End Task follows: Windows' name for the Option + Force Quit (every process of the app), absent with
// Option (Force Quit is there already) and on the fixed Files tile. `o`: {alt, hung, endTask, fixed}; the rows' ids.
function quitRows(o) {
    if (o.alt)
        return ["hideOthers", "forcequit"];
    const rows = ["hide", o.hung ? "forcequitHung" : "quit"];
    if (o.endTask && !o.fixed)
        rows.push("endtask");
    return rows;
}

// Window list at the top of an app's Dock menu (macOS): one row per window of the app, the most recent first. Each window is
// {ref, title, minimized, stamp}; a row is {ref, title (whitespace collapsed, elided to `max` characters, the app name when
// empty), minimized, checked}. The check goes to the most recently focused window that is not minimized (macOS: the key window);
// a minimized window never has it. Choosing a row activates that one window (Compositor.activate restores a minimized window
// and switches to its Desktop, the same call as a Dock click).
// The number a window keeps while it lives, per app (appKey -> window ref -> {title, n}): another app's menu never renumbers
// this app's windows. A closed window's entry is dropped on the next call for its app.
const numbers = new Map();

function resetNumbers() {
    numbers.clear();
}

function labelOf(title, n) {
    return n > 1 ? title + " (" + n + ")" : title;
}

function menuWindows(windows, max, appName, appKey) {
    const key = appKey === undefined || appKey === null ? "" : String(appKey);
    if (!numbers.has(key))
        numbers.set(key, new Map());
    const mine = numbers.get(key);
    if (!windows || windows.length === 0) {
        mine.clear();
        return [];
    }
    const elide = t => t.length > max ? t.slice(0, max - 1) + "\u2026" : t;
    const titled = windows.map(w => {
        const t = String(w.title === undefined || w.title === null ? "" : w.title).replace(/\s+/g, " ").trim();
        return {w: w, title: elide(t === "" ? appName : t)};
    });
    // Same visible title (after eliding, so two long titles that differ only past the cut also count): each window gets the
    // smallest number no other window of that title holds and whose label no other window already shows (a window literally
    // titled "foot (2)" keeps that label for itself), and keeps it until its title changes or it closes. Only a title shared
    // by several windows shows a number.
    const live = new Set(titled.map(l => l.w.ref));
    for (const ref of Array.from(mine.keys())) {
        if (!live.has(ref))
            mine.delete(ref);
    }
    const count = Object.create(null);
    for (const l of titled)
        count[l.title] = (count[l.title] || 0) + 1;
    const rawTitles = new Set(titled.map(l => l.title));
    for (const l of titled) {
        const kept = mine.get(l.w.ref);
        if (kept && kept.title === l.title)
            continue;
        const taken = new Set();
        for (const o of titled) {
            const e = mine.get(o.w.ref);
            if (o !== l && e && e.title === l.title)
                taken.add(e.n);
        }
        let n = 1;
        while (taken.has(n) || (n > 1 && count[l.title] > 1 && rawTitles.has(labelOf(l.title, n))))
            n++;
        mine.set(l.w.ref, {title: l.title, n: n});
    }
    const sorted = titled.slice().sort((a, b) => b.w.stamp - a.w.stamp);
    const front = sorted.find(l => !l.w.minimized);
    return sorted.map(l => {
        const n = mine.get(l.w.ref).n;
        return {
            ref: l.w.ref,
            title: count[l.title] > 1 ? labelOf(l.title, n) : l.title,
            minimized: l.w.minimized === true,
            checked: l === front
        };
    });
}

// Which Dock-membership rows the Options submenu of a tile offers (macOS: a running app has Keep in Dock, checked while it is
// kept; an app that is not running and is in the Dock, pinned or in the recent section, has Remove from Dock). A recent app
// that is not kept also has Keep in Dock. The fixed Files tile is always in the Dock: neither row.
// `tile` = {fixed, running, pinned, recent}; returns {keep, remove} booleans.
function optionRows(tile) {
    if (!tile || tile.fixed === true)
        return {keep: false, remove: false};
    const running = tile.running === true;
    const pinned = tile.pinned === true;
    const recent = tile.recent === true;
    return {
        keep: running || !pinned,
        remove: !running && (pinned || recent)
    };
}
