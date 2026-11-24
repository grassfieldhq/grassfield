.pragma library
.import Grassfield.Ui as Ui
.import "PlainText.js" as PlainText

// The commands.json v1 format and its validator (ADR-0067 D-8, command-palette.md slice E1a). Pure: no file, no process.
// The shell's CommandStore (E1b) is the one writer of the file; it runs every request, and every read, through here.
//
//   {"v": 1,
//    "quickKeys":    [{"key": "gh", "command": "sys.lock"}],
//    "shortcuts":    [{"slot": "k1", "chord": "Super+Shift+K", "command": "sys.lock"}],
//    "favorites":    ["sys.lock"],
//    "links":        [{"id": "link.<uuid>", "name": "Docs", "target": "https://example.org/?q={argument}",
//                      "openWith": "firefox.desktop", "args": [{"placeholder": "Query", "optional": false}]}],
//    "replacements": [{"id": "text.<uuid>", "replace": "brb", "with": "be right back"}],
//    "aiCommands":   [{"id": "ai.<uuid>", "name": "Summarize", "prompt": "Summarize: {clipboard}"}]}
//
// Every list may be missing (an empty one). A key not listed here, a wrong type, a value out of its bounds, a duplicate id,
// slot, chord or quick key refuses the whole file: the result is {ok: false, path, reason}, never a partly accepted one.
// A successful result holds a new object built from the known fields only (a file can carry no other property into the shell).

const VERSION = 1;
const MAX_BYTES = 1048576;      // the file, in UTF-8 bytes
const MAX_ITEMS = 2000;         // per list
const MAX_ARGS = 3;
const MAX_URL = 2048;           // a longer link could not be shown whole in the approval pane (D-7)
const MAX_PATH = 1024;

const LISTS = ["quickKeys", "shortcuts", "favorites", "links", "replacements", "aiCommands"];
const COMMAND_ID = /^[a-z][a-z0-9.-]{0,63}$/;
const MODIFIERS = ["Super", "Ctrl", "Alt", "Shift"];

// C0, DEL, C1, line and paragraph separators, bidirectional marks, embeddings, overrides, isolates and the byte order mark.
const UNSAFE_LINE = new RegExp("[\\u0000-\\u001f\\u007f-\\u009f\\u061c\\u200e\\u200f\\u2028\\u2029\\u202a-\\u202e\\u2066-\\u2069\\ufeff]");
// The same, allowing a tab and a line feed (a replacement's text and a prompt are several lines).
const UNSAFE_BLOCK = new RegExp("[\\u0000-\\u0008\\u000b-\\u001f\\u007f-\\u009f\\u2028\\u2029\\u202a-\\u202e\\u2066-\\u2069\\ufeff]");
const SPACE_OR_UNSAFE = new RegExp("[\\s\\u0000-\\u001f\\u007f-\\u009f\\u061c\\u200e\\u200f\\u2028\\u2029\\u202a-\\u202e\\u2066-\\u2069\\ufeff]");
// A placeholder as Placeholders.js (T4) spells one: lower-case name, then an optional argument.
const PLACEHOLDER = /\{[a-z][a-zA-Z0-9 :._=-]{0,40}\}/g;

function fail(path, reason) {
    return {ok: false, path: path, reason: reason};
}

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

function utf8Length(s) {
    let n = 0;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c < 0x80)
            n += 1;
        else if (c < 0x800)
            n += 2;
        else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length && s.charCodeAt(i + 1) >= 0xdc00 && s.charCodeAt(i + 1) <= 0xdfff) {
            n += 4;
            i++;
        } else
            n += 3;
    }
    return n;
}

// Every key of `o` is one of `allowed`.
function onlyKeys(o, allowed) {
    return Object.keys(o).every(k => allowed.indexOf(k) >= 0);
}

function line(v, min, max) {
    return PlainText.isLabel(v, min, max) && !UNSAFE_LINE.test(v);
}

// ---- Link targets (D-7) ---------------------------------------------------------------------------------------------

// A path the person's own files live at: absolute or `~/`, no parent step, no placeholder, no control character. Whether it
// exists is checked when the link is created and when it opens, not here.
function checkPath(p) {
    if (typeof p !== "string" || p.length < 1 || p.length > MAX_PATH || UNSAFE_LINE.test(p))
        return false;
    if (p[0] !== "/" && p.slice(0, 2) !== "~/")
        return false;
    if (p.slice(0, 2) === "//")
        return false;                   // "//host/share": a network path to Qt's fromLocalFile (file:////host/share too)
    if (p.indexOf("{") >= 0 || p.indexOf("}") >= 0 || p.indexOf("\\") >= 0)
        return false;
    return !p.split("/").some(s => s === "..");
}

// Braces only as whole placeholders.
function bracesOk(s) {
    return s.replace(PLACEHOLDER, "").search(/[{}]/) < 0;
}

// A mailto address and its query: only the to, cc, bcc, subject and body fields (names compared case-insensitively after
// percent-decoding). Any other field (a file to attach, a header) could make a mail client send a file of the person's, so
// it refuses the link. subject and body may appear once; to, cc and bcc may repeat.
function mailtoOk(rest) {
    if (rest.indexOf("#") >= 0 || rest.indexOf(";") >= 0)
        return false;
    const q = rest.indexOf("?");
    const address = q < 0 ? rest : rest.slice(0, q);
    let decoded;
    try {
        decoded = decodeURIComponent(address);
    } catch (e) {
        return false;
    }
    if (decoded.indexOf("?") >= 0 || decoded.indexOf("&") >= 0 || PlainText.hasHidden(decoded))
        return false;
    if (q < 0)
        return true;
    const seen = Object.create(null);
    for (const field of rest.slice(q + 1).split("&")) {
        const eq = field.indexOf("=");
        if (eq < 1)
            return false;
        let name;
        try {
            name = decodeURIComponent(field.slice(0, eq)).toLowerCase();
        } catch (e) {
            return false;
        }
        if (["to", "cc", "bcc", "subject", "body"].indexOf(name) < 0)
            return false;
        if ((name === "subject" || name === "body") && seen[name])
            return false;
        seen[name] = true;
    }
    return true;
}

// The target list of ADR-0067 D-7: https and http URLs, mailto addresses, a local path, a file: URL with an empty or localhost
// host (turned into its path). Everything else (javascript:, data:, blob:, any other scheme, smb: sftp: ftp: dav:, a
// relative path) is refused. Returns {ok: true, target, kind} (kind: web, mail, path) with the normalized target, or
// {ok: false, reason}.
function checkTarget(t) {
    if (typeof t !== "string" || t.length < 1 || t.length > MAX_URL)
        return {ok: false, reason: "length"};
    if (UNSAFE_LINE.test(t))
        return {ok: false, reason: "characters"};
    const scheme = /^([A-Za-z][A-Za-z0-9+.-]*):/.exec(t);
    if (!scheme) {
        // A path may hold plain spaces (not at its ends); a URL may not hold any whitespace.
        return checkPath(t) && t === t.replace(/^\s+|\s+$/g, "") ? {ok: true, target: t, kind: "path"} : {ok: false, reason: "not-allowed"};
    }
    if (SPACE_OR_UNSAFE.test(t))
        return {ok: false, reason: "characters"};
    const s = scheme[1].toLowerCase();
    if (s === "http" || s === "https") {
        const m = /^[A-Za-z]+:\/\/([^\/?#]*)(.*)$/.exec(t);
        if (!m)
            return {ok: false, reason: "url"};
        const authority = m[1];
        // No user information, no placeholder and no non-ASCII character in the host (a look-alike name): ASCII host, port.
        if (!/^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?){0,10}(:[0-9]{1,5})?$/.test(authority) && !/^\[[0-9A-Fa-f:.]{2,45}\](:[0-9]{1,5})?$/.test(authority))
            return {ok: false, reason: "host"};
        if (t.indexOf("\\") >= 0 || !bracesOk(m[2]))
            return {ok: false, reason: "url"};
        return {ok: true, target: s + t.slice(scheme[1].length), kind: "web"};
    }
    if (s === "mailto") {
        const rest = t.slice(scheme[0].length);
        if (rest.length < 1 || rest.indexOf("\\") >= 0 || !bracesOk(rest) || !mailtoOk(rest))
            return {ok: false, reason: "url"};
        return {ok: true, target: "mailto:" + rest, kind: "mail"};
    }
    if (s === "file") {
        const m = /^[Ff][Ii][Ll][Ee]:\/\/([^\/]*)(\/[^?#]*)$/.exec(t);
        if (!m || (m[1] !== "" && m[1].toLowerCase() !== "localhost"))
            return {ok: false, reason: "not-allowed"};
        let p;
        try {
            p = decodeURIComponent(m[2]);
        } catch (e) {
            return {ok: false, reason: "url"};
        }
        return checkPath(p) ? {ok: true, target: p, kind: "path"} : {ok: false, reason: "not-allowed"};
    }
    return {ok: false, reason: "not-allowed"};
}

// ---- Items ----------------------------------------------------------------------------------------------------------------

function checkArgs(args, at) {
    if (!Array.isArray(args) || args.length > MAX_ARGS)
        return fail(at, "args");
    const out = [];
    for (let i = 0; i < args.length; i++) {
        const a = args[i];
        if (!isObject(a) || !onlyKeys(a, ["placeholder", "optional"]) || !line(a.placeholder, 1, 64))
            return fail(at + "[" + i + "]", "arg");
        if (a.optional !== undefined && typeof a.optional !== "boolean")
            return fail(at + "[" + i + "].optional", "type");
        out.push({placeholder: a.placeholder, optional: a.optional === true});
    }
    return {ok: true, value: out};
}

function checkId(v, prefix, at) {
    if (typeof v !== "string" || !COMMAND_ID.test(v) || v.indexOf(prefix) !== 0 || v.length === prefix.length)
        return fail(at, "id");
    return null;
}

function checkQuickKey(it, at) {
    if (!isObject(it) || !onlyKeys(it, ["key", "command"]))
        return fail(at, "shape");
    if (typeof it.key !== "string" || !/^[a-z0-9][a-z0-9 ]{0,15}$/.test(it.key) || it.key[it.key.length - 1] === " ")
        return fail(at + ".key", "key");
    if (typeof it.command !== "string" || !COMMAND_ID.test(it.command))
        return fail(at + ".command", "id");
    return {ok: true, value: {key: it.key, command: it.command}};
}

// A chord: one to four distinct modifiers from the fixed list, then a key (`^[A-Za-z0-9_]{1,32}$` or `code:<n>`). These are
// the only chords commands.lua binds (D-2); nothing a title or an id says reaches Hyprland.
function checkChord(c) {
    if (typeof c !== "string" || c.length > 64)
        return false;
    const parts = c.split("+");
    if (parts.length < 2)
        return false;
    const key = parts.pop();
    if (!/^(?:[A-Za-z0-9_]{1,32}|code:[0-9]{1,3})$/.test(key))
        return false;
    const seen = Object.create(null);
    for (const m of parts) {
        if (MODIFIERS.indexOf(m) < 0 || seen[m])
            return false;
        seen[m] = true;
    }
    return true;
}

// The same chord whatever the order of its modifiers and the case: the modifiers sorted, then the key.
function chordKey(c) {
    const parts = c.toLowerCase().split("+");
    const key = parts.pop();
    return parts.sort().join("+") + "+" + key;
}

function checkShortcut(it, at) {
    if (!isObject(it) || !onlyKeys(it, ["slot", "chord", "command"]))
        return fail(at, "shape");
    if (typeof it.slot !== "string" || !/^k([1-9][0-9]?)$/.test(it.slot))
        return fail(at + ".slot", "slot");
    if (!checkChord(it.chord))
        return fail(at + ".chord", "chord");
    if (typeof it.command !== "string" || !COMMAND_ID.test(it.command))
        return fail(at + ".command", "id");
    return {ok: true, value: {slot: it.slot, chord: it.chord, command: it.command}};
}

function checkLink(it, at) {
    if (!isObject(it) || !onlyKeys(it, ["id", "name", "target", "openWith", "args"]))
        return fail(at, "shape");
    const bad = checkId(it.id, "link.", at + ".id");
    if (bad)
        return bad;
    if (!line(it.name, 1, 80))
        return fail(at + ".name", "name");
    let openWith = "";
    if (it.openWith !== undefined) {
        // A desktop id, as a command argument it must not start like an option.
        if (typeof it.openWith !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/.test(it.openWith))
            return fail(at + ".openWith", "openWith");
        openWith = it.openWith;
    }
    let target = "";
    if (it.target === "" && openWith !== "") {
        target = "";                    // an application alone
    } else {
        const t = checkTarget(it.target);
        if (!t.ok)
            return fail(at + ".target", t.reason);
        target = t.target;
    }
    let args = [];
    if (it.args !== undefined) {
        const a = checkArgs(it.args, at + ".args");
        if (!a.ok)
            return a;
        args = a.value;
    }
    const value = {id: it.id, name: it.name, target: target, args: args};
    if (openWith !== "")
        value.openWith = openWith;
    return {ok: true, value: value};
}

function checkReplacement(it, at) {
    if (!isObject(it) || !onlyKeys(it, ["id", "replace", "with"]))
        return fail(at, "shape");
    const bad = checkId(it.id, "text.", at + ".id");
    if (bad)
        return bad;
    if (typeof it.replace !== "string" || it.replace.length < 1 || it.replace.length > 32 || SPACE_OR_UNSAFE.test(it.replace) || PlainText.hasHidden(it.replace))
        return fail(at + ".replace", "replace");
    if (typeof it.with !== "string" || it.with.length < 1 || it.with.length > 16384 || UNSAFE_BLOCK.test(it.with))
        return fail(at + ".with", "with");
    return {ok: true, value: {id: it.id, replace: it.replace, with: it.with}};
}

function checkAiCommand(it, at) {
    if (!isObject(it) || !onlyKeys(it, ["id", "name", "prompt"]))
        return fail(at, "shape");
    const bad = checkId(it.id, "ai.", at + ".id");
    if (bad)
        return bad;
    if (!line(it.name, 1, 80))
        return fail(at + ".name", "name");
    if (typeof it.prompt !== "string" || it.prompt.length < 1 || it.prompt.length > 16384 || UNSAFE_BLOCK.test(it.prompt))
        return fail(at + ".prompt", "prompt");
    return {ok: true, value: {id: it.id, name: it.name, prompt: it.prompt}};
}

const CHECKERS = {
    quickKeys: checkQuickKey,
    shortcuts: checkShortcut,
    links: checkLink,
    replacements: checkReplacement,
    aiCommands: checkAiCommand
};

// One item of a list, as an `addItem`/`updateItem` request would carry it (E1b): {ok: true, value} or {ok: false, path, reason}.
// `list` is one of the list names; a favorite is a command id string.
function validateItem(list, item) {
    if (list === "favorites")
        return typeof item === "string" && COMMAND_ID.test(item) ? {ok: true, value: item} : fail("favorites[0]", "id");
    if (!(list in CHECKERS) || !Object.prototype.hasOwnProperty.call(CHECKERS, list))
        return fail(String(list), "list");
    return CHECKERS[list](item, list + "[0]");
}

function empty() {
    return {v: VERSION, quickKeys: [], shortcuts: [], favorites: [], links: [], replacements: [], aiCommands: []};
}

// A parsed commands.json value. Returns {ok: true, data} with a new, normalized object (every list present), or
// {ok: false, path, reason}.
function validate(value) {
    if (!isObject(value))
        return fail("", "shape");
    if (!onlyKeys(value, ["v"].concat(LISTS)))
        return fail("", "unknown-key");
    if (value.v !== VERSION)
        return fail("v", "version");
    const data = empty();
    const ids = Object.create(null);
    const uniq = {quickKeys: Object.create(null), slots: Object.create(null), chords: Object.create(null), favorites: Object.create(null)};
    for (const list of LISTS) {
        const items = value[list];
        if (items === undefined)
            continue;
        if (!Array.isArray(items))
            return fail(list, "type");
        if (items.length > MAX_ITEMS)
            return fail(list, "too-many");
        for (let i = 0; i < items.length; i++) {
            const at = list + "[" + i + "]";
            let r;
            if (list === "favorites") {
                r = typeof items[i] === "string" && COMMAND_ID.test(items[i]) ? {ok: true, value: items[i]} : fail(at, "id");
            } else {
                r = CHECKERS[list](items[i], at);
            }
            if (!r.ok)
                return r;
            const v = r.value;
            if (list === "favorites") {
                if (uniq.favorites[v])
                    return fail(at, "duplicate");
                uniq.favorites[v] = true;
            } else if (list === "quickKeys") {
                if (uniq.quickKeys[v.key])
                    return fail(at + ".key", "duplicate");
                uniq.quickKeys[v.key] = true;
            } else if (list === "shortcuts") {
                const chord = chordKey(v.chord);
                if (uniq.slots[v.slot])
                    return fail(at + ".slot", "duplicate");
                if (uniq.chords[chord])
                    return fail(at + ".chord", "duplicate");
                uniq.slots[v.slot] = true;
                uniq.chords[chord] = true;
            } else {
                if (ids[v.id])
                    return fail(at + ".id", "duplicate");
                ids[v.id] = true;
            }
            data[list].push(v);
        }
    }
    return {ok: true, data: data};
}

// The file's text: at most 1 MiB, valid JSON that a rewrite keeps exactly (JsonSafety: no duplicate key, no integer beyond
// 2^53), then validate(). Returns the same result shape.
function parseText(text) {
    if (typeof text !== "string")
        return fail("", "text");
    if (utf8Length(text) > MAX_BYTES)
        return fail("", "too-big");
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return fail("", "json");
    }
    if (Ui.JsonSafety.unsafeReason(text) !== "")
        return fail("", "unsafe-json");
    return validate(value);
}

// ---- Requests (E1b: CommandStore, the `search` IPC item functions) ------------------------------------------------------------
// Pure. A request never edits the file by itself: it builds the candidate content, which the store serializes and reads back
// through parseText() above, so a request is judged by exactly the rules a file is (the item checks here only give a precise path).

const MAX_REQUEST = 65536;      // one IPC call, in UTF-8 bytes (ADR-0067 D-8)
const IPC_LISTS = ["links", "replacements", "aiCommands"];     // what the Settings app may change over IPC (never a key binding)
const ID_PREFIX = {links: "link.", replacements: "text.", aiCommands: "ai."};

// The identity of an item inside its list.
function keyOf(list, item) {
    if (list === "favorites")
        return item;
    if (list === "quickKeys")
        return item.key;
    if (list === "shortcuts")
        return item.slot;
    return item.id;
}

function parseJson(text) {
    if (typeof text !== "string")
        return {ok: false, reason: "text"};
    if (utf8Length(text) > MAX_REQUEST)
        return {ok: false, reason: "too-big"};
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return {ok: false, reason: "json"};
    }
    if (Ui.JsonSafety.unsafeReason(text) !== "")
        return {ok: false, reason: "unsafe-json"};
    return {ok: true, value: value};
}

// `{"list": "links", "item": {...}}`, at most 64 KiB, the item checked as the file reader checks one. `lists` are the lists the
// caller may touch (IPC_LISTS for the IPC path). Returns {ok: true, list, item} (the item normalized) or {ok: false, path, reason}.
function parseRequest(text, lists) {
    const j = parseJson(text);
    if (!j.ok)
        return fail("", j.reason);
    if (!isObject(j.value) || !onlyKeys(j.value, ["list", "item"]))
        return fail("", "shape");
    const list = j.value.list;
    if (typeof list !== "string" || (lists || IPC_LISTS).indexOf(list) < 0)
        return fail("list", "list");
    const r = validateItem(list, j.value.item);
    if (!r.ok)
        return r;
    return {ok: true, list: list, item: r.value};
}

function copy(data) {
    return JSON.parse(JSON.stringify(data));
}

// The candidate content after adding (mode "add": the key must be new) or replacing (mode "update": it must exist) an item.
// Returns {ok: true, data} (not yet validated as a whole file) or {ok: false, path, reason}.
function withItem(data, list, item, mode) {
    const next = copy(data);
    const key = keyOf(list, item);
    const at = next[list].findIndex(x => keyOf(list, x) === key);
    if (mode === "add") {
        if (at >= 0)
            return fail(list, "exists");
        next[list].push(item);
    } else {
        if (at < 0)
            return fail(list, "not-found");
        next[list][at] = item;
    }
    return {ok: true, data: next};
}

// The candidate content without the link, replacement or AI command `id`.
function withoutItem(data, id) {
    if (typeof id !== "string" || id.length < 1 || id.length > 128)
        return fail("id", "id");
    const next = copy(data);
    for (const list of IPC_LISTS) {
        if (id.indexOf(ID_PREFIX[list]) !== 0)
            continue;
        const at = next[list].findIndex(x => x.id === id);
        if (at < 0)
            return fail(list, "not-found");
        next[list].splice(at, 1);
        return {ok: true, data: next};
    }
    return fail("id", "id");
}

// The candidate content after importing the file content `incoming` (a validated commands.json): the links, replacements and AI
// commands of the file whose id is not already there are added, the others are skipped (what is there wins). Quick keys,
// keyboard shortcuts and favorites are ignored: a key binding is never imported through this door.
// Returns {ok: true, data, added, skipped, ignored}.
function mergeImport(data, incoming) {
    const next = copy(data);
    const have = Object.create(null);
    for (const list of IPC_LISTS)
        for (const x of next[list])
            have[x.id] = true;
    let added = 0;
    let skipped = 0;
    for (const list of IPC_LISTS) {
        for (const x of incoming[list]) {
            if (have[x.id]) {
                skipped++;
                continue;
            }
            have[x.id] = true;
            next[list].push(copy(x));
            added++;
        }
    }
    const ignored = incoming.quickKeys.length + incoming.shortcuts.length + incoming.favorites.length;
    return {ok: true, data: next, added: added, skipped: skipped, ignored: ignored};
}

// The text the store writes: two-space indent and a final newline. `bytes` is its UTF-8 length.
function serialize(data) {
    const text = JSON.stringify(data, null, 2) + "\n";
    return {text: text, bytes: utf8Length(text)};
}
