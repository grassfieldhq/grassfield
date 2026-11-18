.pragma library

// Pure logic of the Notifications column (unit-tested, tests/unit/tst_notifcenter.qml).

// Key of the card that takes the keyboard focus when the focused card `lost` ({key, app, rank}: its group and its rank from the
// group's top, noted while it was displayed) LEFT the displayed rows (hidden by an arrival pushing it out of a collapsed group,
// by "Show Less" or a collapse, removed by a clear, an expiry or the app, any number of them in one event-loop turn). `oldKeys`
// are the displayed keys in display order as of the last settled state, `rows` the displayed rows NOW ({key, appName}). Only
// `rows` decides what exists; `oldKeys` only gives the visual neighbourhood. In order:
//  1. the card now in the same slot of the same group (same rank, clamped to the group's last displayed card);
//  2. else (the group is gone) the first card after the lost one's old place that is still displayed (the next group);
//  3. else the nearest card before it; else the first row; "" when no card is left.
function focusAfterGone(lost, oldKeys, rows) {
    const group = rows.filter(r => r.appName === lost.app);
    if (group.length > 0)
        return group[Math.min(Math.max(lost.rank, 0), group.length - 1)].key;
    const alive = {};
    rows.forEach(r => alive[r.key] = true);
    const at = oldKeys.indexOf(lost.key);
    if (at >= 0) {
        for (let i = at + 1; i < oldKeys.length; i++) {
            if (alive[oldKeys[i]])
                return oldKeys[i];
        }
        for (let i = at - 1; i >= 0; i--) {
            if (alive[oldKeys[i]])
                return oldKeys[i];
        }
    }
    return rows.length > 0 ? rows[0].key : "";
}

// Pointer-over counts per app: a card, and the x that sticks out of its corner, each count while hovered, so the
// group controls stay while any part of any card of the app is under the pointer, whatever order the enter and
// leave events arrive in. Returns the new counts (never negative); the input is not changed.
function hoverStep(counts, app, over) {
    // No prototype: an app may be named "constructor" or "__proto__".
    const next = Object.assign(Object.create(null), counts);
    next[app] = Math.max(0, (next[app] || 0) + (over ? 1 : -1));
    return next;
}

function isHovered(counts, app) {
    return (counts[app] || 0) > 0;
}

// Where the widget gallery sits on an output of w x h px (macOS: a panel at the bottom left that never covers the Dock). `t` carries
// the tokens {menubar, inset, insetLeft, width, maxHeight, fraction} and `dock` the Dock's footprint {left, right, bottom} on this
// output (zeros when the Dock is on another one). The panel keeps clear of the Dock on whichever edge it is, even while the Dock is
// auto-hidden (it would otherwise be covered the moment the Dock reveals). Returns {x, y, width, height}.
function galleryRect(w, h, t, dock) {
    const height = Math.max(0, Math.min(t.maxHeight, (h - t.menubar - dock.bottom) * t.fraction));
    return {
        x: t.insetLeft + dock.left,
        y: h - height - t.inset - dock.bottom,
        width: t.width,
        height: height
    };
}

// Where Tab goes around the column's head, Clear All (ADR-0039 step 7: the Tab stop before the cards, when it shows and is
// enabled: `headReady`). `at`: "panel" (nothing focused yet), "close" (the title row's close disc), "head" (Clear All),
// "cardsStart" (leaving the first card's region backwards) or "cardsEnd" (leaving the last card's region forwards). Answers
// "head", "firstCard" (the top card; with none, Qt's chain, or the edit button after the head), "close", "edit", or "" for
// Qt's own focus chain.
function headStep(at, forward, headReady) {
    switch (at) {
    case "panel":
        return forward ? (headReady ? "head" : "firstCard") : "close";
    case "close":
        return forward ? (headReady ? "head" : "firstCard") : "";
    case "head":
        return forward ? "firstCard" : "close";
    case "cardsStart":
        return forward ? "" : (headReady ? "head" : "close");
    case "cardsEnd":
        return forward ? "edit" : "";
    }
    return "";
}
