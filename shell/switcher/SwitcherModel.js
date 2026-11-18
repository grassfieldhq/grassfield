.pragma library

// App switcher model (pure, unit-tested; spec docs/specs/switcher.md).
//
// Apps are the Dock's app identity (shell/dock/DockModel.js merge) ordered by recency, most recently used first.
// The session is a small reducer: state {phase, selected, count} + event -> {state, action}.
//   phase:  "idle" | "pending" (modifier held, panel not shown yet) | "shown"
//   action: "none" | "show" | "commit" | "cancel"

// Apps in MRU order. `windows`: [{appId, ref}] (one per toplevel), `lookup`: desktop entry resolution,
// `recency`: function(ref) -> stamp (ms, 0 = never focused), `excluded`: lowercased app ids that never appear.
// Result items: {key, name, icon, entry, windows: [ref...], stamp}. Ties keep window list order (stable).
function apps(dockMerge, windows, lookup, recency, excluded) {
    const skip = excluded ? excluded : [];
    const running = (windows ? windows : []).filter(w => w.appId && skip.indexOf(String(w.appId).toLowerCase()) < 0);
    const list = dockMerge([], running, lookup);
    for (let i = 0; i < list.length; i++) {
        let best = 0;
        for (let j = 0; j < list[i].windows.length; j++)
            best = Math.max(best, recency(list[i].windows[j]) || 0);
        list[i].stamp = best;
        list[i].order = i;
    }
    list.sort((a, b) => b.stamp - a.stamp || a.order - b.order);
    return list;
}

// Keeps the frozen order of `current` for apps still present, drops closed ones, appends new apps at the end.
function refresh(current, fresh) {
    // No prototype: the keys are app ids, a client's strings ("constructor").
    const byKey = Object.create(null);
    fresh.forEach(a => byKey[a.key] = a);
    const kept = current.filter(a => byKey[a.key] !== undefined).map(a => byKey[a.key]);
    const have = Object.create(null);
    kept.forEach(a => have[a.key] = true);
    return kept.concat(fresh.filter(a => !have[a.key]));
}

function wrap(index, count) {
    return count <= 0 ? -1 : ((index % count) + count) % count;
}

function idle() {
    return {phase: "idle", selected: -1, count: 0};
}

// First selection of a session: Tab goes to the previous app (index 1) when the most recent app is the focused one
// (`current`), else to the most recent one (index 0: nothing is in front, e.g. an empty desktop); Shift+Tab to the least recent.
function firstSelection(count, dir, current) {
    if (count <= 0)
        return -1;
    return dir < 0 ? count - 1 : (current ? Math.min(1, count - 1) : 0);
}

// event: {type: "step", dir: +1|-1, count, current?: bool (default true)} | {type: "timer"} | {type: "release"} | {type: "cancel"} | {type: "hover", index}
//        | {type: "click", index} | {type: "count", count, selected}
function reduce(state, ev) {
    switch (ev.type) {
    case "step":
        if (state.phase === "idle") {
            if (ev.count <= 0)
                return {state: idle(), action: "none"};
            return {state: {phase: "pending", selected: firstSelection(ev.count, ev.dir, ev.current !== false), count: ev.count}, action: "none"};
        }
        // A second press shows the panel and moves on.
        return {state: {phase: "shown", selected: wrap(state.selected + (ev.dir < 0 ? -1 : 1), state.count), count: state.count},
            action: state.phase === "pending" ? "show" : "none"};
    case "timer":
        return state.phase === "pending" ? {state: {phase: "shown", selected: state.selected, count: state.count}, action: "show"} : {state: state, action: "none"};
    case "release":
        if (state.phase === "idle")
            return {state: state, action: "none"};
        return {state: idle(), action: "commit", index: state.selected};
    case "cancel":
        if (state.phase === "idle")
            return {state: state, action: "none"};
        return {state: idle(), action: "cancel"};
    case "hover":
        if (state.phase !== "shown" || ev.index < 0 || ev.index >= state.count)
            return {state: state, action: "none"};
        return {state: {phase: "shown", selected: ev.index, count: state.count}, action: "none"};
    case "click":
        if (state.phase !== "shown" || ev.index < 0 || ev.index >= state.count)
            return {state: state, action: "none"};
        return {state: idle(), action: "commit", index: ev.index};
    case "count":
        // The app list changed (an app quit or closed): clamp the selection; nothing left ends the session.
        if (state.phase === "idle")
            return {state: state, action: "none"};
        if (ev.count <= 0)
            return {state: idle(), action: "cancel"};
        return {state: {phase: state.phase, selected: ev.selected >= 0 ? Math.min(ev.selected, ev.count - 1) : Math.min(state.selected, ev.count - 1), count: ev.count}, action: "none"};
    }
    return {state: state, action: "none"};
}

// Panel layout: tiles per row and rows for `count` apps in `avail` pt of width.
function grid(count, avail, pitch) {
    const fit = Math.max(1, Math.floor(avail / pitch));
    const columns = Math.max(1, Math.min(count, fit));
    return {columns: columns, rows: Math.max(1, Math.ceil(count / columns))};
}
