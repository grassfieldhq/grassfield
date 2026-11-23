.pragma library
.import "Calc.js" as Calc
.import "Numbers.js" as Numbers

// Dynamic placeholders of Snippets and Links (palette slice T1, spec command-palette.md T4; pure, unit-tested by
// tst_placeholders against the examples of https://manual.raycast.com/dynamic-placeholders, [R6]). A template holds
// `{name attr="value" | modifier | modifier}` groups; text that is not a valid placeholder is left exactly as written
// (as [R6]: "if the keyword or modifier is unrecognized" the group is not a placeholder). Nothing here reads the
// clipboard, the selection or a file: the caller hands the values in `ctx` when the person runs the item.
//
//   {clipboard}  {date}  {time}  {datetime}  {day}  {uuid}  {cursor}  {snippet name="sig"}  {calculator}
//   {argument}  {argument name="tone" default="happy" options="happy, sad"}
//   {date format="yyyy-MM-dd"}  {date offset="+2y +5M"}  {date locale="fr-FR"}  {clipboard | trim | uppercase}
//
// Left as written, never substituted: {selection} (D-4, later), {browser-tab} (no browser extension). Refused with an
// error: {clipboard offset=n} (it would read the history, which stays in its view), a second {cursor} ([R6]: a snippet
// can contain only one), a fourth distinct argument ([R6]: at most 3).
//
// Date formats: the letters y M d E H h m s S a Z, 'quoted text' ('' = a quote); case-sensitive; any other letter makes
// the group invalid. Offsets: signed numbers with the units m h d M y (case-sensitive), separated by spaces, no space after
// the sign. Locales: "en" or "fr" with an optional region, written with hyphens ("fr-FR"), and the unicode extension
// "-u-hc-h12|h23" for the clock; any other language is not a valid locale here (documented subset of [R6]).
//
// Arguments ([R6]): every bare {argument} is its own field; placeholders with the same name share a field; a field is
// required unless it has a default; `options` lists the allowed values. {calculator} is a field too: the typed text is
// evaluated by Calc.js. `fields` and `missing` in the result let the caller draw the chips and refuse to run an item whose
// required fields are empty.
//
// Provenance (ADR-0067 D-7): every piece of the result says where it came from: "literal" (the template or a snippet as
// written), "clipboard", "selection", "typed" (a field value), "generated" ({date}, {uuid}…). `carriesData` is true when a
// piece comes from the clipboard or the selection, directly or through a {snippet} whose text holds {clipboard}. A
// {snippet} resolves recursively, at most MAX_SNIPPET_DEPTH levels; deeper is an error, and an error result always says
// `carriesData: true` so it can never be taken for a data-free one.
//
// ctx (all optional):
//   now        Date used by the date placeholders (default: the current time)
//   locale     Qt.locale(); picks fr or en for names and default formats
//   arguments  {id: value}: the value of each field; id is the name, or "#1", "#2", "#3" for unnamed fields in order
//   clipboard  the clipboard text for {clipboard} ("" when there is none)
//   snippet    function(name) -> text | undefined, or an object {name: text}
//   uuid       function() -> string (default: a version 4 UUID from Math.random, upper case as [R6])
//   url        true: the template is a link; every substituted piece, and the whole text of a {snippet}, is percent-encoded
//              (the `raw` modifier does not lift it: ADR-0067 D-7); only the literal text of the template itself is not
//
// expand() returns {ok, text, pieces: [{text, source}], carriesData, cursor, fields: [{id, name, default, options,
// calculator}], missing: [id], error}. `cursor` is the number of characters after the {cursor} (the caret is moved back that
// many Left keys after the paste), or null. `error` is one of "nesting", "clipboard-offset", "cursor", "arguments",
// "too-long", "too-many", "encoding" (the caller words the message).

const MAX_SNIPPET_DEPTH = 3;
const MAX_ARGUMENTS = 3;
const MAX_OUTPUT = 1048576;
const MAX_PLACEHOLDERS = 2000;
const MAX_GROUP = 4096;

const CARRIERS = ["clipboard", "selection"];
const PRIORITY = ["literal", "generated", "typed", "selection", "clipboard"];

const MONTHS = {
    en: {full: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
        short: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]},
    fr: {full: ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
        short: ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]}
};
const DAYS = {
    en: {full: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
        short: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]},
    fr: {full: ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"],
        short: ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."]}
};

// The default patterns ([R6]: "1 Jun 2022", "3:05 pm", "1 Jun 2022 at 6:45 pm", "Monday"); the clock follows the locale's
// -u-hc- extension when there is one.
function defaultPattern(kind, lang, hc) {
    const h24 = hc === "h23" || hc === "h24" || (hc === "" && lang === "fr");
    const time = h24 ? "HH:mm" : "h:mm a";
    const at = lang === "fr" ? "'à'" : "'at'";
    switch (kind) {
    case "date":
        return "d MMM yyyy";
    case "time":
        return time;
    case "datetime":
        return "d MMM yyyy " + at + " " + time;
    }
    return "EEEE";
}

// ---------- date formatting -------------------------------------------------------------------------------------------

function pad(n, width) {
    let s = String(Math.abs(n));
    while (s.length < width)
        s = "0" + s;
    return s;
}

function zone(date) {
    const off = -date.getTimezoneOffset();
    return (off < 0 ? "-" : "+") + pad(Math.floor(Math.abs(off) / 60), 2) + pad(Math.abs(off) % 60, 2);
}

// Unicode-style pattern: yyyy yy y, MMMM MMM MM M, dd d, EEEE EEE E, HH H, hh h, mm m, ss s, S SS SSS (fractions of a
// second), a (AM/PM; `lowerAmPm`: am/pm), Z (+0000), 'quoted text' ('' = a quote). Returns the text or null when the pattern
// holds a letter it does not know.
function formatDate(date, pattern, lang, lowerAmPm) {
    let out = "";
    let i = 0;
    while (i < pattern.length) {
        const c = pattern[i];
        if (c === "'") {
            if (pattern[i + 1] === "'") {
                out += "'";
                i += 2;
                continue;
            }
            const end = pattern.indexOf("'", i + 1);
            if (end < 0)
                return null;
            out += pattern.slice(i + 1, end);
            i = end + 1;
            continue;
        }
        if (!/[A-Za-z]/.test(c)) {
            out += c;
            i++;
            continue;
        }
        let j = i;
        while (j < pattern.length && pattern[j] === c)
            j++;
        const n = j - i;
        const h12 = date.getHours() % 12 === 0 ? 12 : date.getHours() % 12;
        switch (c) {
        case "y":
            out += n === 2 ? pad(date.getFullYear() % 100, 2) : pad(date.getFullYear(), n);
            break;
        case "M":
            out += n >= 4 ? MONTHS[lang].full[date.getMonth()] : (n === 3 ? MONTHS[lang].short[date.getMonth()] : pad(date.getMonth() + 1, n));
            break;
        case "d":
            out += pad(date.getDate(), Math.min(n, 2));
            break;
        case "E":
            out += n >= 4 ? DAYS[lang].full[date.getDay()] : DAYS[lang].short[date.getDay()];
            break;
        case "H":
            out += pad(date.getHours(), Math.min(n, 2));
            break;
        case "h":
            out += pad(h12, Math.min(n, 2));
            break;
        case "m":
            out += pad(date.getMinutes(), Math.min(n, 2));
            break;
        case "s":
            out += pad(date.getSeconds(), Math.min(n, 2));
            break;
        case "S":
            out += (pad(date.getMilliseconds(), 3) + "000000").slice(0, Math.min(n, 9));
            break;
        case "a": {
            const t = date.getHours() < 12 ? "AM" : "PM";
            out += lowerAmPm ? t.toLowerCase() : t;
            break;
        }
        case "Z":
            if (n > 3)
                return null;
            out += zone(date);
            break;
        default:
            return null;
        }
        i = j;
    }
    return out;
}

// [R6]: "+2y +5M", "-3d", "+3h +30m": a sign, a number, a unit (m minutes, h hours, d days, M months, y years; case-sensitive),
// several offsets separated by spaces, no space after the sign. Returns a new Date or null when the offset is malformed.
function applyOffset(date, offset) {
    const text = offset.trim();
    if (!/^[+-]\d{1,6}[yMdhm](?:\s+[+-]\d{1,6}[yMdhm])*$/.test(text))
        return null;
    const d = new Date(date.getTime());
    const re = /([+-])(\d+)([yMdhm])/g;
    let m;
    while ((m = re.exec(text)) !== null) {
        const n = (m[1] === "-" ? -1 : 1) * Number(m[2]);
        switch (m[3]) {
        case "y":
        case "M": {
            const months = m[3] === "y" ? n * 12 : n;
            const day = d.getDate();
            d.setDate(1);
            d.setMonth(d.getMonth() + months);
            const last = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
            d.setDate(Math.min(day, last));
            break;
        }
        case "d":
            d.setDate(d.getDate() + n);
            break;
        case "h":
            d.setHours(d.getHours() + n);
            break;
        case "m":
            d.setMinutes(d.getMinutes() + n);
            break;
        }
    }
    return isNaN(d.getTime()) ? null : d;
}

// {date locale="fr-FR"}, "en-US-u-hc-h23": {lang, hc} or null (hyphens only, a language this shell has names for).
function parseLocale(text) {
    const m = /^(en|fr)(?:-[A-Z]{2})?(?:-u-hc-(h11|h12|h23|h24))?$/.exec(text);
    return m ? {lang: m[1], hc: m[2] || ""} : null;
}

// ---------- parsing ---------------------------------------------------------------------------------------------------

// The index of the "}" closing the group that opens at `start`, quotes respected, or -1: a second "{" outside quotes, no
// closing brace, or a group longer than MAX_GROUP characters (the first brace is then plain text). Each scan stops at the next
// unquoted "{" or after MAX_GROUP characters, so the whole template is read in linear time.
function findEnd(s, start) {
    let quote = "";
    const stop = Math.min(s.length, start + MAX_GROUP);
    for (let i = start + 1; i < stop; i++) {
        const c = s[i];
        if (quote !== "") {
            if (c === "\\")
                i++;
            else if (c === quote)
                quote = "";
        } else if (c === "\"" || c === "'") {
            quote = c;
        } else if (c === "{") {
            return -1;
        } else if (c === "}") {
            return i;
        }
    }
    return -1;
}

function splitPipes(body) {
    const parts = [];
    let quote = "";
    let from = 0;
    for (let i = 0; i < body.length; i++) {
        const c = body[i];
        if (quote !== "") {
            if (c === "\\")
                i++;
            else if (c === quote)
                quote = "";
        } else if (c === "\"" || c === "'") {
            quote = c;
        } else if (c === "|") {
            parts.push(body.slice(from, i));
            from = i + 1;
        }
    }
    parts.push(body.slice(from));
    return parts;
}

function unquote(raw) {
    if (raw[0] === "\"" || raw[0] === "'")
        return raw.slice(1, -1).replace(/\\(.)/g, "$1");
    return raw;
}

// {name, attrs: {key: value}, modifiers: [..]} or null when the group is not well formed.
function parseGroup(body) {
    const parts = splitPipes(body);
    const head = parts[0];
    const nameMatch = /^\s*([a-z][a-z-]*)/.exec(head);
    if (!nameMatch)
        return null;
    const attrs = Object.create(null);
    const re = /\s+([a-z]+)=("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s"'|]+)/y;
    re.lastIndex = nameMatch[0].length;
    let m;
    let at = re.lastIndex;
    while ((m = re.exec(head)) !== null) {
        if (m[1] in attrs)
            return null;
        attrs[m[1]] = unquote(m[2]);
        at = re.lastIndex;
    }
    if (head.slice(at).trim() !== "")
        return null;
    const modifiers = [];
    for (const raw of parts.slice(1)) {
        const mod = raw.trim();
        if (!/^[a-z][a-z-]*$/.test(mod))
            return null;
        modifiers.push(mod);
    }
    return {name: nameMatch[1], attrs: attrs, modifiers: modifiers};
}

function onlyAttrs(attrs, allowed) {
    return Object.keys(attrs).every(k => allowed.indexOf(k) !== -1);
}

// ---------- modifiers -------------------------------------------------------------------------------------------------

const MODIFIERS = ["uppercase", "lowercase", "trim", "percent-encode", "json-stringify", "raw"];

function applyModifier(text, mod) {
    switch (mod) {
    case "uppercase":
        return text.toUpperCase();
    case "lowercase":
        return text.toLowerCase();
    case "trim":
        return text.trim();
    case "percent-encode":
        return encodeURIComponent(text);
    case "json-stringify":
        // [R6]: Foo "Bar" -> "Foo \"Bar\"" (the quotes are part of the value).
        return JSON.stringify(text);
    }
    return text; // raw: no change here; in a link the encoding below still applies (ADR-0067 D-7)
}

// ---------- expansion -------------------------------------------------------------------------------------------------

function languageFor(ctx) {
    return Numbers.languageOf(ctx.locale) === "fr" ? "fr" : "en";
}

function makeUuid() {
    const h = "0123456789ABCDEF";
    let s = "";
    for (let i = 0; i < 36; i++) {
        if (i === 8 || i === 13 || i === 18 || i === 23)
            s += "-";
        else if (i === 14)
            s += "4";
        else if (i === 19)
            s += h[8 + Math.floor(Math.random() * 4)];
        else
            s += h[Math.floor(Math.random() * 16)];
    }
    return s;
}

function snippetText(ctx, name) {
    const src = ctx.snippet;
    let t;
    if (typeof src === "function")
        t = src(name);
    else if (src && typeof src === "object" && Object.prototype.hasOwnProperty.call(src, name))
        t = src[name];
    return typeof t === "string" ? t : undefined;
}

function strongest(pieces) {
    let best = 0;
    for (const p of pieces) {
        if (!p.cursor)
            best = Math.max(best, PRIORITY.indexOf(p.source));
    }
    return PRIORITY[best];
}

function joinText(pieces) {
    return pieces.filter(p => !p.cursor).map(p => p.text).join("");
}

function copyWithoutUrl(ctx) {
    const c = {};
    for (const k of Object.keys(ctx))
        c[k] = ctx[k];
    c.url = false;
    return c;
}

// The field of an {argument} or {calculator}: found by id, or created (at most MAX_ARGUMENTS distinct ones). Returns the field
// or null when there are too many.
function fieldFor(state, id, make) {
    for (const f of state.fields) {
        if (f.id === id)
            return f;
    }
    if (state.fields.length >= MAX_ARGUMENTS)
        return null;
    const f = make();
    state.fields.push(f);
    return f;
}

function optionList(text) {
    return text.split(",").map(o => o.trim()).filter(o => o !== "");
}

function fieldValue(ctx, f) {
    const v = ctx.arguments && Object.prototype.hasOwnProperty.call(ctx.arguments, f.id) ? ctx.arguments[f.id] : "";
    return typeof v === "string" ? v : "";
}

// Resolves one known placeholder. Returns {pieces} (a substituted value), {literal: true} (leave it as written) or {error}.
function resolve(group, ctx, depth, state) {
    const a = group.attrs;
    const mods = group.modifiers;
    const lang = languageFor(ctx);
    let source = "generated";
    let text = "";
    for (const m of mods) {
        if (MODIFIERS.indexOf(m) === -1)
            return {literal: true};
    }
    switch (group.name) {
    case "clipboard":
        if ("offset" in a)
            return onlyAttrs(a, ["offset"]) && /^\d+$/.test(a.offset) ? {error: "clipboard-offset"} : {literal: true};
        if (!onlyAttrs(a, []))
            return {literal: true};
        source = "clipboard";
        text = typeof ctx.clipboard === "string" ? ctx.clipboard : "";
        break;
    case "date":
    case "time":
    case "datetime":
    case "day": {
        if (!onlyAttrs(a, ["format", "locale", "offset"]) || ("format" in a && "locale" in a))
            return {literal: true};
        let fl = lang;
        let hc = "";
        if ("locale" in a) {
            const loc = parseLocale(a.locale);
            if (!loc)
                return {literal: true};
            fl = loc.lang;
            hc = loc.hc;
        }
        let when = ctx.now instanceof Date ? ctx.now : new Date();
        if ("offset" in a) {
            when = applyOffset(when, a.offset);
            if (!when)
                return {literal: true};
        }
        const custom = "format" in a;
        const out = formatDate(when, custom ? a.format : defaultPattern(group.name, fl, hc), fl, !custom);
        if (out === null)
            return {literal: true};
        text = out;
        break;
    }
    case "uuid":
        if (!onlyAttrs(a, []))
            return {literal: true};
        text = typeof ctx.uuid === "function" ? String(ctx.uuid()) : makeUuid();
        break;
    case "argument": {
        if (!onlyAttrs(a, ["name", "default", "options"]) || ("name" in a && (a.name === "" || a.name[0] === "#")))
            return {literal: true};
        const id = "name" in a ? a.name : "#" + (++state.unnamed);
        const f = fieldFor(state, id, () => ({id: id, name: "name" in a ? a.name : "", "default": "default" in a ? a["default"] : null,
            options: "options" in a ? optionList(a.options) : [], calculator: false}));
        if (!f)
            return {error: "arguments"};
        let v = fieldValue(ctx, f);
        source = "typed";
        if (f.options.length > 0 && v !== "" && f.options.indexOf(v) === -1)
            v = "";
        if (v === "" && f["default"] !== null) {
            v = f["default"];
            source = "literal";
        }
        if (v === "" && f["default"] === null && state.missing.indexOf(f.id) === -1)
            state.missing.push(f.id);
        text = v;
        break;
    }
    case "calculator": {
        if (!onlyAttrs(a, []))
            return {literal: true};
        const id = "#" + (++state.unnamed);
        const f = fieldFor(state, id, () => ({id: id, name: "", "default": null, options: [], calculator: true}));
        if (!f)
            return {error: "arguments"};
        source = "typed";
        const typed = fieldValue(ctx, f);
        const r = Calc.evaluate(Numbers.normalizeInput(typed, ctx.locale));
        if (r.ok)
            text = Calc.format(r.value, ctx.locale);
        else if (state.missing.indexOf(f.id) === -1)
            state.missing.push(f.id);
        break;
    }
    case "snippet": {
        if (!onlyAttrs(a, ["name"]) || !("name" in a))
            return {literal: true};
        const t = snippetText(ctx, a.name);
        if (t === undefined)
            return {literal: true};
        if (depth >= MAX_SNIPPET_DEPTH)
            return {error: "nesting"};
        const inner = run(t, copyWithoutUrl(ctx), depth + 1, state);
        if (inner.error)
            return {error: inner.error};
        if (mods.length === 0) {
            if (!ctx.url)
                return {pieces: inner.pieces};
            // A link: the snippet's own text goes into the URL like any substituted value, so it is encoded too.
            try {
                return {pieces: inner.pieces.map(p => p.cursor ? p : {text: encodeURIComponent(p.text), source: p.source})};
            } catch (e) {
                return {error: "encoding"};
            }
        }
        text = joinText(inner.pieces);
        source = strongest(inner.pieces);
        break;
    }
    default:
        return {literal: true};
    }
    try {
        for (const m of mods)
            text = applyModifier(text, m);
        if (ctx.url && mods.indexOf("percent-encode") === -1)
            text = encodeURIComponent(text);
    } catch (e) {
        return {error: "encoding"};
    }
    return {pieces: [{text: text, source: source}]};
}

// Internal: expands a template at a snippet depth; the pieces may hold {cursor: true} markers. Returns {pieces} or {error}.
// Plain text is copied in runs (indexOf), never character by character.
function run(template, ctx, depth, state) {
    const pieces = [];
    let literal = "";
    const flush = () => {
        if (literal !== "") {
            pieces.push({text: literal, source: "literal"});
            literal = "";
        }
    };
    // `from` is where the pending plain text starts; a "{" that opens no placeholder stays in it, untouched and uncopied.
    let from = 0;
    let search = 0;
    while (search < template.length) {
        const open = template.indexOf("{", search);
        if (open < 0)
            break;
        const end = findEnd(template, open);
        const group = end < 0 ? null : parseGroup(template.slice(open + 1, end));
        if (!group) {
            search = open + 1;
            continue;
        }
        if (++state.count > MAX_PLACEHOLDERS)
            return {error: "too-many"};
        let r;
        if (group.name === "cursor" && group.modifiers.length === 0 && onlyAttrs(group.attrs, [])) {
            if (++state.cursors > 1)
                return {error: "cursor"};
            r = {pieces: [{cursor: true}]};
        } else if (group.name === "cursor") {
            r = {literal: true};
        } else {
            r = resolve(group, ctx, depth, state);
        }
        if (r.error)
            return {error: r.error};
        if (!r.literal) {
            literal += template.slice(from, open);
            flush();
            from = end + 1;
            for (const p of r.pieces) {
                pieces.push(p);
                state.size += p.text ? p.text.length : 0;
            }
            if (state.size > MAX_OUTPUT * 4)
                return {error: "too-long"};
        }
        search = end + 1;
    }
    literal += template.slice(from);
    flush();
    return {pieces: pieces};
}

// The number of characters (code points: a surrogate pair is one) of a text.
function codePoints(text) {
    let n = 0;
    for (let i = 0; i < text.length; i++) {
        const c = text.charCodeAt(i);
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length) {
            const d = text.charCodeAt(i + 1);
            if (d >= 0xDC00 && d <= 0xDFFF)
                i++;
        }
        n++;
    }
    return n;
}

function failure(error) {
    return {ok: false, text: "", pieces: [], carriesData: true, cursor: null, fields: [], missing: [], error: error};
}

// The entry point. Never throws.
function expand(template, context) {
    if (typeof template !== "string")
        return failure("too-long");
    const ctx = context && typeof context === "object" ? context : {};
    const state = {count: 0, size: 0, cursors: 0, unnamed: 0, fields: [], missing: []};
    let r;
    try {
        r = run(template, ctx, 0, state);
    } catch (e) {
        return failure("encoding");
    }
    if (r.error)
        return failure(r.error);
    // Merge adjacent pieces of one source; locate the {cursor}.
    const pieces = [];
    let cursorAt = -1;
    let length = 0;
    for (const p of r.pieces) {
        if (p.cursor) {
            if (cursorAt < 0)
                cursorAt = length;
            continue;
        }
        if (p.text === "")
            continue;
        const last = pieces.length > 0 ? pieces[pieces.length - 1] : null;
        if (last && last.source === p.source)
            last.text += p.text;
        else
            pieces.push({text: p.text, source: p.source});
        length += p.text.length;
    }
    const text = pieces.map(p => p.text).join("");
    if (text.length > MAX_OUTPUT)
        return failure("too-long");
    return {
        ok: true,
        text: text,
        pieces: pieces,
        // From the unfiltered pieces: an empty clipboard still marks the result.
        carriesData: r.pieces.some(p => !p.cursor && CARRIERS.indexOf(p.source) !== -1),
        cursor: cursorAt < 0 ? null : codePoints(text.slice(cursorAt)),
        fields: state.fields,
        missing: state.missing,
        error: ""
    };
}
