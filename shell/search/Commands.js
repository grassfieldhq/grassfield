.pragma library
.import "Ranking.js" as Ranking

// The command catalogue of Search (ADR-0067 D-2, docs/specs/command-palette.md N2). Pure: no QML, no service. Providers
// (Search.qml for the system commands; later windows, settings, scripts, links, snippets, menus) hand over entries whose
// titles and keywords are already translated; `build` validates them and refuses a duplicate id; `match` ranks them like the
// five fixed rows were ranked before the registry; `run` calls the entry's own `run`, which is the function the UI already calls.
//
// Entry: {id, title, subtitle, keywords[], keywordsEn[], glyph, kind, provider, args[], actions[], available, run}
// - id: ^[a-z][a-z0-9.-]{0,63}$ (`sys.lock`); ids of menu items are ephemeral and never stored.
// - keywords: words in the shell's language; keywordsEn: English words kept besides them (optional).
// - available: a boolean or a function returning one (default: available); an unavailable entry is never offered or run.
// - run(args, origin): the action; origin is "row", "quickkey", "hotkey", "ipc" or "refresh".

const ID_RE = /^[a-z][a-z0-9.-]{0,63}$/;
const KINDS = ["system", "window", "setting", "script", "link", "text", "menu"];
const MIN_SCORE = 50;
const KEYWORD_WEIGHT = 0.8;

function validId(id) {
    return typeof id === "string" && ID_RE.test(id);
}

function _strings(list) {
    return list === undefined || (Array.isArray(list) && list.every(w => typeof w === "string"));
}

// "" when the entry is well formed, else the reason (for the log and the tests).
function validate(entry) {
    if (!entry || typeof entry !== "object")
        return "not an object";
    if (!validId(entry.id))
        return "bad id";
    if (typeof entry.title !== "string" || entry.title.trim() === "")
        return "empty title";
    if (!_strings(entry.keywords) || !_strings(entry.keywordsEn))
        return "keywords must be strings";
    if (entry.kind !== undefined && KINDS.indexOf(entry.kind) < 0)
        return "unknown kind";
    if (entry.args !== undefined && !Array.isArray(entry.args))
        return "args must be a list";
    if (entry.actions !== undefined && !Array.isArray(entry.actions))
        return "actions must be a list";
    if (typeof entry.run !== "function")
        return "run must be a function";
    if (entry.available !== undefined && typeof entry.available !== "function" && typeof entry.available !== "boolean")
        return "available must be a boolean or a function";
    return "";
}

// providers: a list of arrays of entries (or of functions returning one). Returns {entries, byId, errors}: an invalid
// entry, or an id already taken (the first wins), is left out and told in `errors` as "<id>: <reason>".
function build(providers) {
    const entries = [];
    const byId = {};
    const errors = [];
    for (const p of providers) {
        const list = typeof p === "function" ? p() : p;
        for (const e of list || []) {
            const why = validate(e);
            if (why !== "") {
                errors.push((e && e.id !== undefined ? e.id : "?") + ": " + why);
                continue;
            }
            if (Object.prototype.hasOwnProperty.call(byId, e.id)) {
                errors.push(e.id + ": duplicate id");
                continue;
            }
            byId[e.id] = e;
            entries.push(e);
        }
    }
    return {entries: entries, byId: byId, errors: errors};
}

function isAvailable(entry) {
    if (entry.available === undefined)
        return true;
    return typeof entry.available === "function" ? entry.available() === true : entry.available === true;
}

function find(registry, id) {
    return typeof id === "string" && Object.prototype.hasOwnProperty.call(registry.byId, id) ? registry.byId[id] : null;
}

// Title, then keywords at 80 %; below 50 nothing (the former commandScore). q is the normalized query.
function score(entry, q) {
    let s = Ranking.textScore(Ranking.norm(entry.title), q);
    for (const w of (entry.keywords || []).concat(entry.keywordsEn || []))
        s = Math.max(s, Ranking.textScore(Ranking.norm(w), q) * KEYWORD_WEIGHT);
    return s >= MIN_SCORE ? s : 0;
}

// Available entries matching the query, best first (stable for equal scores): [{cmd, score}].
function match(registry, query) {
    const q = Ranking.norm(query);
    const hits = [];
    for (const e of registry.entries) {
        if (!isAvailable(e))
            continue;
        const s = score(e, q);
        if (s > 0)
            hits.push({cmd: e, score: s});
    }
    hits.sort((a, b) => b.score - a.score);
    return hits;
}

// The system provider: the five commands Search always had, in their old order. `t` holds the translated words (Search.qml
// owns the qsTr calls so lupdate finds them), `act` the function each command calls today, `lockOn` whether Lock Screen is
// offered. Ids are stable; the glyphs are branding/icons/symbolic names.
function systemCommands(t, act, lockOn) {
    const mk = (id, title, words, glyph, run, available) => ({id: id, title: title, subtitle: t.subtitle, keywords: words, glyph: glyph,
        kind: "system", provider: "system", available: available !== false, run: run});
    return [
        mk("sys.lock", t.lock, [t.lockWord], "lock", act.lock, lockOn),
        mk("sys.sleep", t.sleep, [t.sleepWord], "moon", act.sleep),
        mk("sys.restart", t.restart, [t.restartWord], "power", act.restart),
        mk("sys.shutdown", t.shutdown, [t.shutdownWord, t.shutdownWord2], "power", act.shutdown),
        mk("sys.logout", t.logout, [t.logoutWord, t.logoutWord2], "person", act.logout)
    ];
}

// The one place a command runs. Returns whether it ran; an unknown or unavailable id does nothing.
function run(registry, id, args, origin) {
    const e = find(registry, id);
    if (!e || !isAvailable(e))
        return false;
    e.run(args || [], origin || "row");
    return true;
}
