.pragma library

// The header of a script command (ADR-0067 D-3, command-palette.md slice X1). Pure: it takes the text a caller already read
// (the first 8 KiB of the file) and returns what the header says, or why it is refused. It reads no file, runs nothing and
// starts nothing; the discovery (X2) reads, the runner (X3) runs, and the approval gate (X7) decides.
//
// Format: comment lines `# @raycast.<key> <value>` or `// @raycast.<key> <value>` (`@grassfield.` is the same key under another
// prefix) in the first 64 lines or 8 KiB. Required: schemaVersion (1), title, mode. Unknown keys are ignored and never
// returned (the format has others); a known key whose value is malformed refuses the whole script, and so does a key given
// twice. No value of the result ever reaches a shell, an argv or a path unchecked: the strings are plain text without
// control, line-separator or bidirectional characters, within a length cap; the icon is a lexical check only (X8 resolves
// it, after approval); the working directory is not resolved here; an argument is a closed set of fields.

const MAX_LINES = 64;
const MAX_BYTES = 8192;
const MAX_LINE = 4096;          // a header line longer than this refuses the script
const MAX_ARGUMENTS = 3;
const MAX_DROPDOWN = 32;
const MIN_REFRESH_SECONDS = 10;
const MAX_REFRESH_SECONDS = 7 * 86400;

const MODES = ["fullOutput", "compact", "silent", "inline"];
const ARGUMENT_TYPES = ["text", "password", "dropdown"];
const ARGUMENT_FIELDS = ["type", "placeholder", "optional", "percentEncoded", "secure", "data"];
const OPTION_FIELDS = ["title", "value"];

// C0, DEL and C1 controls, line and paragraph separators, bidirectional marks, embeddings, overrides and isolates.
const UNSAFE_TEXT = /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\ufeff]/;
const LINE = /^[ \t]*(?:#|\/\/)[ \t]*@(raycast|grassfield)\.([A-Za-z][A-Za-z0-9]{0,31})(?:[ \t]+(.*))?$/;
const ARGUMENT_KEY = /^argument([0-9]+)$/;

function fail(key, reason) {
    return {ok: false, key: key, reason: reason};
}

// The UTF-8 length of a JavaScript string, without allocating a buffer.
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

// A one-line text of 1..max characters (UTF-16 units) after trimming spaces and tabs; "" is returned as null when it is
// out of those bounds or holds an unsafe character.
function plainText(value, max) {
    if (typeof value !== "string")
        return null;
    const t = value.replace(/^[ \t]+|[ \t]+$/g, "");
    if (t.length < 1 || t.length > max || UNSAFE_TEXT.test(t))
        return null;
    return t;
}

// A text that may be empty (a placeholder, a description).
function plainTextOrEmpty(value, max) {
    if (typeof value === "string" && value.replace(/^[ \t]+|[ \t]+$/g, "") === "")
        return "";
    return plainText(value, max);
}

function isBool(v) {
    return v === true || v === false;
}

// `name` of a file in a script folder: a template is skipped by the discovery (X2).
function isTemplateName(name) {
    return typeof name === "string" && name.indexOf(".template.") >= 0;
}

// An icon is an emoji (plain text), a file inside the script's folder (a relative path, checked here only lexically: X8
// resolves it after approval) or the generic glyph. Nothing else: a URL, an absolute path, `~`, a parent step, a hidden or
// odd file name all give the generic glyph, and the script stays listed.
function iconOf(value) {
    const none = reason => ({kind: "none", value: "", rejected: reason});
    if (typeof value !== "string")
        return none("type");
    const t = value.replace(/^[ \t]+|[ \t]+$/g, "");
    if (t === "")
        return none("empty");
    if (UNSAFE_TEXT.test(t))
        return none("characters");
    const points = Array.from(t);
    // An emoji: a few code points, none of them ASCII or Latin-1 text (U+00A9 and U+00AE, the copyright and registered
    // signs, aside), no space.
    if (points.length <= 8 && points.every(p => {
        const c = p.codePointAt(0);
        return c === 0xa9 || c === 0xae || (c >= 0x2000 && !/\s/.test(p));
    }))
        return {kind: "emoji", value: t, rejected: ""};
    if (t.length > 128)
        return none("length");
    if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(t))
        return none("scheme");          // https:// is never fetched (D-net), file: and the rest are no relative path
    if (t[0] === "/" || t[0] === "~" || t.indexOf("\\") >= 0)
        return none("absolute");
    const segments = t.split("/");
    for (const s of segments) {
        if (!/^[A-Za-z0-9_][A-Za-z0-9._ -]{0,63}$/.test(s))
            return none("segment");     // empty, ".", "..", a hidden file, or any character beyond the plain set
    }
    if (!/\.(png|jpe?g|webp|svg)$/i.test(segments[segments.length - 1]))
        return none("extension");
    return {kind: "file", value: t, rejected: ""};
}

// The working directory the script asks for: an absolute path or `~`, `~/...`; no parent step, no control character. It
// is returned as written and never resolved or used here.
function directoryOf(value) {
    if (typeof value !== "string")
        return null;
    const t = value.replace(/^[ \t]+|[ \t]+$/g, "");
    if (t.length < 1 || t.length > 512 || UNSAFE_TEXT.test(t))
        return null;
    if (t !== "~" && t[0] !== "/" && t.slice(0, 2) !== "~/")
        return null;
    if (t.split("/").some(s => s === ".."))
        return null;
    return t;
}

// "10s", "5m", "2h", "1d" -> seconds; null when it is not that or out of range.
function refreshOf(value) {
    const m = /^([0-9]{1,6})(s|m|h|d)$/.exec(typeof value === "string" ? value.replace(/^[ \t]+|[ \t]+$/g, "") : "");
    if (!m)
        return null;
    const seconds = parseInt(m[1], 10) * {s: 1, m: 60, h: 3600, d: 86400}[m[2]];
    return seconds >= MIN_REFRESH_SECONDS && seconds <= MAX_REFRESH_SECONDS ? seconds : null;
}

// One `argumentN` value: a JSON object with only the known fields. Returns {ok, argument} or {ok: false, reason}.
function argumentOf(raw) {
    if (typeof raw !== "string" || raw.length < 2 || raw.length > MAX_LINE)
        return {ok: false, reason: "length"};
    let o;
    try {
        o = JSON.parse(raw);
    } catch (e) {
        return {ok: false, reason: "json"};
    }
    if (o === null || typeof o !== "object" || Array.isArray(o))
        return {ok: false, reason: "shape"};
    const keys = Object.keys(o);
    for (const k of keys) {
        if (ARGUMENT_FIELDS.indexOf(k) < 0)
            return {ok: false, reason: "unknown-field"};
    }
    const has = k => Object.prototype.hasOwnProperty.call(o, k);
    if (typeof o.type !== "string" || ARGUMENT_TYPES.indexOf(o.type) < 0)
        return {ok: false, reason: "type"};
    const placeholder = has("placeholder") ? plainTextOrEmpty(o.placeholder, 64) : null;
    if (placeholder === null)
        return {ok: false, reason: "placeholder"};
    for (const k of ["optional", "percentEncoded", "secure"]) {
        if (has(k) && !isBool(o[k]))
            return {ok: false, reason: k};
    }
    let type = o.type;
    if (has("secure")) {
        if (type !== "text")
            return {ok: false, reason: "secure"};
        if (o.secure === true)
            type = "password";              // a text argument marked secure is a password: stdin only, never argv
    }
    if (type === "password" && o.percentEncoded === true)
        return {ok: false, reason: "percentEncoded"};
    let data = [];
    if (o.type === "dropdown") {
        if (!Array.isArray(o.data) || o.data.length < 1 || o.data.length > MAX_DROPDOWN)
            return {ok: false, reason: "data"};
        const seen = Object.create(null);
        for (const item of o.data) {
            if (item === null || typeof item !== "object" || Array.isArray(item))
                return {ok: false, reason: "data"};
            for (const k of Object.keys(item)) {
                if (OPTION_FIELDS.indexOf(k) < 0)
                    return {ok: false, reason: "data"};
            }
            const title = plainText(item.title, 64);
            const value = plainText(item.value, 128);
            if (title === null || value === null || seen[value])
                return {ok: false, reason: "data"};
            seen[value] = true;
            data.push({title: title, value: value});
        }
    } else if (has("data")) {
        return {ok: false, reason: "data"};
    }
    return {
        ok: true,
        argument: {
            type: type,
            placeholder: placeholder,
            optional: o.optional === true,
            percentEncoded: o.percentEncoded === true,
            data: data
        }
    };
}

// Parse the header of a script's text. Returns
//   {ok: true, hidden, meta: {title, mode, packageName, description, author, authorURL, icon, iconDark, currentDirectoryPath,
//                             needsConfirmation, refreshSeconds, arguments: [{type, placeholder, optional, percentEncoded, data}]}}
//   {ok: false, key, reason}      the script is not listed
// `hidden` is true when the script's `platform` lists only windows (it is parsed, not shown).
function parse(text) {
    if (typeof text !== "string")
        return fail("", "text");
    const found = Object.create(null);
    const order = [];
    let bytes = 0;
    const lines = text.split("\n", MAX_LINES);
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i];
        if (line.length > 0 && line[line.length - 1] === "\r")
            line = line.slice(0, -1);
        bytes += utf8Length(line) + 1;
        if (bytes > MAX_BYTES)
            break;                      // the rest is beyond the 8 KiB the header may use
        if (line.indexOf("@") < 0)
            continue;
        const m = LINE.exec(line);
        if (!m)
            continue;
        if (line.length > MAX_LINE)
            return fail(m[2], "line-length");
        const key = m[2];
        if (key in found)
            return fail(key, "duplicate");
        found[key] = m[3] === undefined ? "" : m[3];
        order.push(key);
    }

    const get = k => (k in found ? found[k] : undefined);
    const version = get("schemaVersion");
    if (version === undefined)
        return fail("schemaVersion", "missing");
    if (version.replace(/[ \t]+$/, "") !== "1")
        return fail("schemaVersion", "unsupported");
    const title = get("title") === undefined ? undefined : plainText(get("title"), 80);
    if (title === undefined)
        return fail("title", "missing");
    if (title === null)
        return fail("title", "invalid");
    const modeRaw = get("mode") === undefined ? undefined : get("mode").replace(/^[ \t]+|[ \t]+$/g, "");
    if (modeRaw === undefined)
        return fail("mode", "missing");
    if (MODES.indexOf(modeRaw) < 0)
        return fail("mode", "invalid");

    const meta = {
        title: title,
        mode: modeRaw,
        packageName: "",
        description: "",
        author: "",
        authorURL: "",
        icon: {kind: "none", value: "", rejected: ""},
        iconDark: {kind: "none", value: "", rejected: ""},
        currentDirectoryPath: "",
        needsConfirmation: false,
        refreshSeconds: 0,
        arguments: []
    };
    const texts = [["packageName", 64], ["description", 256], ["author", 64]];
    for (const [k, max] of texts) {
        if (get(k) === undefined)
            continue;
        const v = plainTextOrEmpty(get(k), max);
        if (v === null)
            return fail(k, "invalid");
        meta[k] = v;
    }
    if (get("authorURL") !== undefined) {
        const u = plainText(get("authorURL"), 256);
        if (u === null || !/^https?:\/\/[^\s]+$/.test(u))
            return fail("authorURL", "invalid");
        meta.authorURL = u;             // shown as text; opening it is a link's business (D-7), not this parser's
    }
    if (get("icon") !== undefined)
        meta.icon = iconOf(get("icon"));
    if (get("iconDark") !== undefined)
        meta.iconDark = iconOf(get("iconDark"));
    if (get("currentDirectoryPath") !== undefined) {
        const d = directoryOf(get("currentDirectoryPath"));
        if (d === null)
            return fail("currentDirectoryPath", "invalid");
        meta.currentDirectoryPath = d;
    }
    if (get("needsConfirmation") !== undefined) {
        const v = get("needsConfirmation").replace(/^[ \t]+|[ \t]+$/g, "");
        if (v !== "true" && v !== "false")
            return fail("needsConfirmation", "invalid");
        meta.needsConfirmation = v === "true";
    }
    if (get("refreshTime") !== undefined) {
        const s = refreshOf(get("refreshTime"));
        if (s === null)
            return fail("refreshTime", "invalid");
        if (meta.mode === "inline")
            meta.refreshSeconds = s;    // only an inline script refreshes
    }

    // Arguments: argument1..3 in order, no gap; any other number refuses.
    const numbers = [];
    for (const k of order) {
        const m = ARGUMENT_KEY.exec(k);
        if (!m)
            continue;
        const n = m[1].length > 3 ? -1 : parseInt(m[1], 10);
        if (n < 1 || n > MAX_ARGUMENTS || String(n) !== m[1])
            return fail(k, "too-many");
        numbers.push(n);
    }
    numbers.sort();
    for (let i = 0; i < numbers.length; i++) {
        if (numbers[i] !== i + 1)
            return fail("argument" + numbers[i], "gap");
        const r = argumentOf(get("argument" + numbers[i]));
        if (!r.ok)
            return fail("argument" + numbers[i], r.reason);
        meta.arguments.push(r.argument);
    }

    let hidden = false;
    if (get("platform") !== undefined) {
        const names = get("platform").toLowerCase().split(/[ \t,]+/).filter(s => s !== "");
        if (names.length > 8 || names.some(n => !/^[a-z0-9_-]{1,16}$/.test(n)))
            return fail("platform", "invalid");
        hidden = names.length > 0 && names.every(n => n === "windows");
    }
    return {ok: true, hidden: hidden, meta: meta};
}
