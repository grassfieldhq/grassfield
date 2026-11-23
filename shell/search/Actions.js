.pragma library

// The Actions panel of Search (ADR-0067 D-1/D-2, docs/specs/command-palette.md §3.2 and §3.3, slices P3a to P3c): which actions a
// row offers and in which order, the filter over them, and the keys of the results view. Pure functions, unit-tested
// (tests/unit/tst_searchactions.qml); Search.qml runs them and owns the translated words (so lupdate finds them), SearchPanel.qml
// shows the list in the `menu` class (PopupMenu).
//
// An action: {id, text, shortcut?, destructive?, enabled?, separator?, run?}. Built-in ids are open, run, copy and reveal (Search.qml
// runs them through `activate`); an action a command entry brings (`entry.actions`) has the id "x:<its id>" and its own `run`.
// A row of the clipboard kind has no entry here: its menu is the CB-8 menu (ClipboardView.menuIds).

// Qt.Key_* and Qt.*Modifier values (a .pragma library sees no QML enums).
var KEY = {
    tab: 0x01000001,
    backtab: 0x01000002,
    pageUp: 0x01000016,
    pageDown: 0x01000017,
    up: 0x01000013,
    down: 0x01000015,
    k: 0x4b
};
var SHIFT = 0x02000000;
var CTRL = 0x04000000;
var ALT = 0x08000000;
var META = 0x10000000;

// The K key's place on the keyboard (its xkb keycode, evdev KEY_K + 8).
var K_SCAN_CODE = 45;

// More actions than this and the panel shows a filter field at its top (spec §3.3: Raycast's searchable panel; macOS 27 shows a
// short list).
var FILTER_ABOVE = 7;

var EXTRA_ID_RE = /^[a-z][a-z0-9.-]{0,63}$/;

// The key of the results view. `opts.cmdK`: whether ⌘K (Super+K, forwarded as Ctrl+K) opens Actions: off until the nested proof of
// P3c shows that the key reaches the layer (spec §3.2). Returns the action:
//   "actions"    Tab (Super+K when proven) opens the Actions of the selected row;
//   "chips"      Shift+Tab moves the focus ring to the filter chips (some injectors deliver it as Tab with Shift held);
//   "groupNext"  Page Down, Ctrl+Down: the first item of the next group;
//   "groupPrev"  Page Up, Ctrl+Up: the first item of the previous group;
//   ""           not a key of this table.
function keyAction(key, modifiers, scanCode, opts) {
    const mods = Number(modifiers) & (SHIFT | CTRL | ALT | META);
    switch (key) {
    case KEY.tab:
        if (mods === 0)
            return "actions";
        return mods === SHIFT ? "chips" : "";
    case KEY.backtab:
        return (mods === 0 || mods === SHIFT) ? "chips" : "";
    case KEY.pageDown:
        return mods === 0 ? "groupNext" : "";
    case KEY.pageUp:
        return mods === 0 ? "groupPrev" : "";
    case KEY.down:
        return mods === CTRL ? "groupNext" : "";
    case KEY.up:
        return mods === CTRL ? "groupPrev" : "";
    }
    if (opts && opts.cmdK === true && (key === KEY.k || Number(scanCode) === K_SCAN_CODE) && (mods === CTRL || mods === META))
        return "actions";
    return "";
}

// A custom action of a command entry is well formed: a valid id, a title, a run function.
function validExtra(a) {
    return !!a && typeof a === "object" && typeof a.id === "string" && EXTRA_ID_RE.test(a.id)
        && typeof a.title === "string" && a.title.trim() !== "" && typeof a.run === "function"
        && (a.shortcut === undefined || typeof a.shortcut === "string");
}

// The actions of a result row, in order: the primary one (Return), the secondary one (Ctrl+Return) when the kind has one, the
// kind's own, then the destructive ones last after a separator (spec §3.3). `t` holds the translated words (open, run, copy,
// reveal). A row with no actions gives []. A malformed or repeated extra action is left out.
function forItem(item, t) {
    if (!item || typeof item !== "object" || !t)
        return [];
    const primary = (id, text) => ({id: id, text: text, shortcut: "Return"});
    let list = [];
    switch (item.kind) {
    case "app":
    case "setting":
        list.push(primary("open", t.open));
        break;
    case "command":
        list.push(primary("run", t.run));
        break;
    case "calc":
        list.push(primary("copy", t.copy));
        break;
    case "file":
    case "recent":
        list.push(primary("open", t.open));
        list.push({id: "reveal", text: t.reveal, shortcut: "Ctrl+Return"});
        break;
    default:
        return [];
    }
    const extras = Array.isArray(item.actions) ? item.actions.filter(validExtra) : [];
    const seen = {};
    const own = [];
    const destructive = [];
    for (const a of extras) {
        if (Object.prototype.hasOwnProperty.call(seen, a.id))
            continue;
        seen[a.id] = true;
        const entry = {id: "x:" + a.id, text: a.title, run: a.run};
        if (a.shortcut !== undefined && a.shortcut !== "")
            entry.shortcut = a.shortcut;
        if (a.destructive === true)
            entry.destructive = true;
        if (a.enabled === false)
            entry.enabled = false;
        (a.destructive === true ? destructive : own).push(entry);
    }
    list = list.concat(own);
    if (destructive.length > 0) {
        list.push({separator: true});
        list = list.concat(destructive);
    }
    return list;
}

// Whether the panel shows a filter field for this list.
function needsFilter(list) {
    return Array.isArray(list) && list.filter(a => !a.separator).length > FILTER_ABOVE;
}

function _fold(s) {
    return String(s).normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
}

// The actions whose text contains the typed words (accents and case ignored); separators drop out while a filter is typed.
// An empty filter keeps the list as it is.
function filter(list, text) {
    const q = _fold(text === undefined || text === null ? "" : text).trim();
    if (q === "")
        return Array.isArray(list) ? list.slice() : [];
    const words = q.split(/\s+/);
    return (Array.isArray(list) ? list : []).filter(a => !a.separator && words.every(w => _fold(a.text).indexOf(w) >= 0));
}

// The action with this id, or null.
function find(list, id) {
    if (!Array.isArray(list))
        return null;
    for (const a of list) {
        if (!a.separator && a.id === id)
            return a;
    }
    return null;
}

// The index of the first selectable action (not a separator or disabled), -1 when none.
function firstSelectable(list) {
    return (Array.isArray(list) ? list : []).findIndex(a => !a.separator && a.enabled !== false);
}

// Next selectable index from `index` in direction dir (+1/-1), wrapping; -1 when none (the filter field's Up and Down).
function step(list, index, dir) {
    const n = Array.isArray(list) ? list.length : 0;
    let i = index;
    for (let k = 0; k < n; k++) {
        i = i < 0 ? (dir > 0 ? 0 : n - 1) : (i + dir + n) % n;
        if (!list[i].separator && list[i].enabled !== false)
            return i;
    }
    return -1;
}
