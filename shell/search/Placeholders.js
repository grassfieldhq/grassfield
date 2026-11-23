.pragma library
.import "Calc.js" as Calc
.import "Numbers.js" as Numbers

// Dynamic placeholders of Snippets and Links (palette slice T1, spec command-palette.md T4; pure, unit-tested by
// tst_placeholders). A template holds `{name attr="value" | modifier | modifier}` groups; text that is not a known
// placeholder is left exactly as written. Nothing here reads the clipboard, the selection or a file: the caller hands the
// values in `ctx` when the person runs the item.
//
//   {clipboard}  {date}  {time}  {datetime}  {day}  {uuid}  {cursor}  {argument name="q" default="x"}
//   {snippet name="sig"}  {calculator expression="2*3"}
//   {date format="yyyy-MM-dd"}  {date offset="+1d"}  {date locale="fr"}  {clipboard | trim | uppercase}
//
// Left as written, never substituted: {selection} (D-4, later), {browser-tab} (no browser extension). Refused with an
// error: {clipboard offset=n} (it would read the history, which stays in its view).
//
// Provenance (ADR-0067 D-7): every piece of the result says where it came from: "literal" (the template or a snippet
// as written), "clipboard", "selection", "typed" (an {argument} value), "generated" ({date}, {uuid}, {calculator}…).
// `carriesData` is true when a piece comes from the clipboard or the selection, directly or through a {snippet} whose
// text holds {clipboard}. A {snippet} resolves recursively, at most MAX_SNIPPET_DEPTH levels; deeper is an error, and
// an error result always says `carriesData: true` so it can never be taken for a data-free one.
//
// ctx (all optional):
//   now        Date used by the date placeholders (default: the current time)
//   locale     Qt.locale(); picks fr or en for names and default formats
//   argument   the typed value of a bare {argument}
//   arguments  {name: value} for {argument name="…"}
//   clipboard  the clipboard text for {clipboard} ("" when there is none)
//   snippet    function(name) -> text | undefined, or an object {name: text}
//   uuid       function() -> string (default: a version 4 UUID from Math.random)
//   url        true: every substituted piece is percent-encoded (templates of web links); the literal text is not
//
// expand() returns {ok, text, pieces: [{text, source}], carriesData, cursor, error}. `cursor` is the number of characters
// after the first {cursor} (the caret is moved back that many Left keys after the paste), or null. `error` is one of
// "nesting", "clipboard-offset", "too-long", "too-many", "encoding" (the caller words the message).

const MAX_SNIPPET_DEPTH = 3;
const MAX_OUTPUT = 1048576;
const MAX_PLACEHOLDERS = 2000;

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
const DEFAULT_FORMATS = {
    en: {date: "MMM d, yyyy", time: "h:mm a", day: "EEEE"},
    fr: {date: "d MMM yyyy", time: "HH:mm", day: "EEEE"}
};

// ---------- date formatting -------------------------------------------------------------------------------------------

function pad(n, width) {
    let s = String(Math.abs(n));
    while (s.length < width)
        s = "0" + s;
    return s;
}

// Unicode-style pattern: yyyy yy y, MMMM MMM MM M, dd d, EEEE EEE, HH H, hh h, mm m, ss s, a, 'quoted text' ('' = a quote).
// Returns the text or null when the pattern holds a letter it does not know.
function formatDate(date, pattern, lang) {
    const names = {months: MONTHS[lang], days: DAYS[lang]};
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
            out += n >= 4 ? names.months.full[date.getMonth()] : (n === 3 ? names.months.short[date.getMonth()] : pad(date.getMonth() + 1, n));
            break;
        case "d":
            out += pad(date.getDate(), Math.min(n, 2));
            break;
        case "E":
            out += n >= 4 ? names.days.full[date.getDay()] : names.days.short[date.getDay()];
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
        case "a":
            out += date.getHours() < 12 ? "AM" : "PM";
            break;
        default:
            return null;
        }
        i = j;
    }
    return out;
}

// "+1d", "-2M", "+1y -2d +3h": no space between a sign and its number. y year, M month, w week, d day, h hour, m minute, s second.
// Returns a new Date or null when the offset is malformed.
function applyOffset(date, offset) {
    const text = offset.trim();
    if (!/^[+-]\d{1,6}[yMwdhms](?:\s*[+-]\d{1,6}[yMwdhms])*$/.test(text))
        return null;
    const d = new Date(date.getTime());
    const re = /([+-])(\d+)([yMwdhms])/g;
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
        case "w":
            d.setDate(d.getDate() + 7 * n);
            break;
        case "d":
            d.setDate(d.getDate() + n);
            break;
        case "h":
            d.setHours(d.getHours() + n);
            break;
        case "m":
            d.setMinutes(d.getMinutes() + n);
            break;
        case "s":
            d.setSeconds(d.getSeconds() + n);
            break;
        }
    }
    return isNaN(d.getTime()) ? null : d;
}

// ---------- parsing ---------------------------------------------------------------------------------------------------

// The index of the "}" closing the group that opens at `start`, quotes respected, or -1 (a second "{" before it also means -1:
// the first one is plain text).
function findEnd(s, start) {
    let quote = "";
    for (let i = start + 1; i < s.length; i++) {
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
    let head = parts[0];
    const nameMatch = /^\s*([a-z][a-z-]*)/.exec(head);
    if (!nameMatch)
        return null;
    head = head.slice(nameMatch[0].length);
    const attrs = Object.create(null);
    const re = /^\s+([a-z]+)=("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s"'|]+)/;
    let m;
    while ((m = re.exec(head)) !== null) {
        if (m[1] in attrs)
            return null;
        attrs[m[1]] = unquote(m[2]);
        head = head.slice(m[0].length);
    }
    if (head.trim() !== "")
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
        // The text as it reads inside a JSON string: escaped, without the surrounding quotes.
        return JSON.stringify(text).slice(1, -1);
    }
    return text; // raw: the text as it is
}

// ---------- expansion -------------------------------------------------------------------------------------------------

function languageFor(ctx) {
    return Numbers.languageOf(ctx.locale) === "fr" ? "fr" : "en";
}

function makeUuid() {
    const h = "0123456789abcdef";
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
        if (p.cursor)
            continue;
        best = Math.max(best, PRIORITY.indexOf(p.source));
    }
    return PRIORITY[best];
}

function joinText(pieces) {
    return pieces.filter(p => !p.cursor).map(p => p.text).join("");
}

// Resolves one known placeholder. Returns {pieces} (a substituted value), {literal: true} (leave it as written) or {error}.
function resolve(group, ctx, depth, state) {
    const a = group.attrs;
    const mods = group.modifiers;
    const lang = languageFor(ctx);
    let source = "generated";
    let text = "";
    let inner = null;
    switch (group.name) {
    case "clipboard":
        if ("offset" in a)
            return onlyAttrs(a, ["offset"]) && /^-?\d+$/.test(a.offset) ? {error: "clipboard-offset"} : {literal: true};
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
        if ("locale" in a) {
            const code = a.locale.slice(0, 2).toLowerCase();
            if (!/^[A-Za-z]{2}([_-][A-Za-z]{2})?$/.test(a.locale) || (code !== "fr" && code !== "en"))
                return {literal: true};
            fl = code;
        }
        let when = ctx.now instanceof Date ? ctx.now : new Date();
        if ("offset" in a) {
            when = applyOffset(when, a.offset);
            if (!when)
                return {literal: true};
        }
        const f = DEFAULT_FORMATS[fl];
        let pattern = a.format;
        if (pattern === undefined)
            pattern = group.name === "datetime" ? f.date + " " + f.time : f[group.name];
        const out = formatDate(when, pattern, fl);
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
        if (!onlyAttrs(a, ["name", "default"]))
            return {literal: true};
        let v;
        if ("name" in a) {
            if (ctx.arguments && Object.prototype.hasOwnProperty.call(ctx.arguments, a.name))
                v = ctx.arguments[a.name];
        } else if (typeof ctx.argument === "string") {
            v = ctx.argument;
        }
        source = "typed";
        text = typeof v === "string" ? v : "";
        if (text === "" && "default" in a) {
            text = a["default"];
            source = "literal";
        }
        break;
    }
    case "calculator": {
        if (!onlyAttrs(a, ["expression"]) || !("expression" in a))
            return {literal: true};
        const r = Calc.evaluate(a.expression);
        if (!r.ok)
            return {literal: true};
        text = Calc.format(r.value, ctx.locale);
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
        const sub = mods.length === 0 ? ctx : copyWithoutUrl(ctx);
        inner = run(t, sub, depth + 1, state);
        if (inner.error)
            return {error: inner.error};
        if (mods.length === 0)
            return {pieces: inner.pieces};
        text = joinText(inner.pieces);
        source = strongest(inner.pieces);
        break;
    }
    default:
        return {literal: true};
    }
    for (const m of mods) {
        if (MODIFIERS.indexOf(m) === -1)
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

function copyWithoutUrl(ctx) {
    const c = {};
    for (const k of Object.keys(ctx))
        c[k] = ctx[k];
    c.url = false;
    return c;
}

// Internal: expands a template at a snippet depth; the pieces may hold {cursor: true} markers. Returns {pieces} or {error}.
function run(template, ctx, depth, state) {
    const pieces = [];
    let literal = "";
    const flush = () => {
        if (literal !== "") {
            pieces.push({text: literal, source: "literal"});
            literal = "";
        }
    };
    let i = 0;
    while (i < template.length) {
        const c = template[i];
        if (c !== "{") {
            literal += c;
            i++;
            continue;
        }
        const end = findEnd(template, i);
        const group = end < 0 ? null : parseGroup(template.slice(i + 1, end));
        if (!group) {
            literal += c;
            i++;
            continue;
        }
        if (++state.count > MAX_PLACEHOLDERS)
            return {error: "too-many"};
        let r;
        if (group.name === "cursor") {
            r = group.modifiers.length === 0 && onlyAttrs(group.attrs, []) ? {pieces: [{cursor: true}]} : {literal: true};
        } else {
            r = resolve(group, ctx, depth, state);
        }
        if (r.error)
            return {error: r.error};
        if (r.literal) {
            literal += template.slice(i, end + 1);
        } else {
            flush();
            for (const p of r.pieces) {
                pieces.push(p);
                state.size += p.text ? p.text.length : 0;
            }
            if (state.size > MAX_OUTPUT * 4)
                return {error: "too-long"};
        }
        i = end + 1;
    }
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
    return {ok: false, text: "", pieces: [], carriesData: true, cursor: null, error: error};
}

// The entry point. Never throws.
function expand(template, context) {
    if (typeof template !== "string")
        return failure("too-long");
    const ctx = context && typeof context === "object" ? context : {};
    const state = {count: 0, size: 0};
    let r;
    try {
        r = run(template, ctx, 0, state);
    } catch (e) {
        return failure("encoding");
    }
    if (r.error)
        return failure(r.error);
    // Merge adjacent pieces of one source; locate the first {cursor}.
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
        error: ""
    };
}
