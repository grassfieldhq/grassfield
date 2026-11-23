.pragma library
.import "Numbers.js" as Numbers

// Safe calculator (pure, unit-tested). Own tokenizer and recursive-descent parser: the input is
// never passed to eval, Function or any dynamic lookup. Identifiers resolve through explicit
// switch statements, so names like `constructor` or `__proto__` are plain unknown identifiers.
//
// Grammar: expr = term (("+"|"-") term)* ; term = unary (("*"|"/"|"%") unary)* ;
//          unary = "-" unary | "+" unary | power ; power = atom ("^" unary)? ;
//          atom = number | const | func "(" expr ")" | "(" expr ")" ; postfix "%" after an atom = /100.

const MAX_LENGTH = 200;
const MAX_DEPTH = 250;

function constant(name) {
    switch (name) {
    case "pi":
        return Math.PI;
    case "e":
        return Math.E;
    }
    return undefined;
}

function callFunction(name, x) {
    switch (name) {
    case "sqrt":
        return Math.sqrt(x);
    case "sin":
        return Math.sin(x);
    case "cos":
        return Math.cos(x);
    case "tan":
        return Math.tan(x);
    case "ln":
        return Math.log(x);
    case "log":
        return Math.log10(x);
    }
    return undefined;
}

function isFunctionName(name) {
    return ["sqrt", "sin", "cos", "tan", "ln", "log"].indexOf(name) !== -1;
}

function tokenize(text) {
    const tokens = [];
    let i = 0;
    while (i < text.length) {
        const c = text[i];
        if (c === " " || c === "\t") {
            i++;
        } else if ((c >= "0" && c <= "9") || c === ".") {
            const m = /^(\d+\.?\d*|\.\d+)(e[+-]?\d+)?/.exec(text.slice(i));
            if (!m)
                return null;
            tokens.push({t: "num", v: Number(m[0])});
            i += m[0].length;
        } else if (c >= "a" && c <= "z") {
            let j = i;
            while (j < text.length && text[j] >= "a" && text[j] <= "z")
                j++;
            tokens.push({t: "id", v: text.slice(i, j)});
            i = j;
        } else if ("+-*/%^()".indexOf(c) !== -1) {
            tokens.push({t: c});
            i++;
        } else if (c === "×") {
            tokens.push({t: "*"});
            i++;
        } else if (c === "÷") {
            tokens.push({t: "/"});
            i++;
        } else {
            return null;
        }
    }
    return tokens;
}

// Returns {ok: true, value} or {ok: false}. Never throws.
function evaluate(input) {
    if (typeof input !== "string" || input.length === 0 || input.length > MAX_LENGTH)
        return {ok: false};
    const tokens = tokenize(input.toLowerCase());
    if (!tokens || tokens.length === 0)
        return {ok: false};
    let pos = 0;
    let failed = false;

    function peek() {
        return pos < tokens.length ? tokens[pos].t : "";
    }

    function fail() {
        failed = true;
        return 0;
    }

    function isPostfixPercent() {
        return peek() === "%" && (pos + 1 >= tokens.length || tokens[pos + 1].t === ")");
    }

    function expr(depth) {
        if (depth > MAX_DEPTH)
            return fail();
        let v = term(depth + 1);
        while (!failed && (peek() === "+" || peek() === "-")) {
            const op = tokens[pos++].t;
            const r = term(depth + 1);
            v = op === "+" ? v + r : v - r;
        }
        return v;
    }

    function term(depth) {
        if (depth > MAX_DEPTH)
            return fail();
        let v = unary(depth + 1);
        while (!failed && (peek() === "*" || peek() === "/" || peek() === "%") && !isPostfixPercent()) {
            const op = tokens[pos++].t;
            const r = unary(depth + 1);
            v = op === "*" ? v * r : (op === "/" ? v / r : v % r);
        }
        return v;
    }

    function unary(depth) {
        if (depth > MAX_DEPTH)
            return fail();
        if (peek() === "-") {
            pos++;
            return -unary(depth + 1);
        }
        if (peek() === "+") {
            pos++;
            return unary(depth + 1);
        }
        return power(depth + 1);
    }

    function power(depth) {
        if (depth > MAX_DEPTH)
            return fail();
        const base = atom(depth + 1);
        if (!failed && peek() === "^") {
            pos++;
            return Math.pow(base, unary(depth + 1));
        }
        return base;
    }

    function atom(depth) {
        if (depth > MAX_DEPTH || pos >= tokens.length)
            return fail();
        const tok = tokens[pos++];
        let v = 0;
        if (tok.t === "num") {
            v = tok.v;
        } else if (tok.t === "(") {
            v = expr(depth + 1);
            if (failed || peek() !== ")")
                return fail();
            pos++;
        } else if (tok.t === "id") {
            if (isFunctionName(tok.v)) {
                if (peek() !== "(")
                    return fail();
                pos++;
                const arg = expr(depth + 1);
                if (failed || peek() !== ")")
                    return fail();
                pos++;
                v = callFunction(tok.v, arg);
            } else {
                v = constant(tok.v);
            }
            if (v === undefined)
                return fail();
        } else {
            return fail();
        }
        while (!failed && isPostfixPercent()) {
            pos++;
            v = v / 100;
        }
        return v;
    }

    const value = expr(0);
    if (failed || pos !== tokens.length || typeof value !== "number" || !isFinite(value))
        return {ok: false};
    return {ok: true, value: value};
}

// True when the input is more than a bare number or a bare word (an operator, a function call, a constant in a
// calculation). A word alone is no calculation, even the name of a constant: "pi" or "e" typed on the way to an app
// must not put a Calculator row before it.
function isExpression(input) {
    if (/^\s*[\d.]+(e[+-]?\d+)?\s*$/i.test(input))
        return false;
    if (/^\s*[a-z]+\s*$/i.test(input))
        return false;
    return /[a-z+\-*/%^()×÷]/i.test(input);
}

// Display text: 12 significant digits, no trailing zeros, written in the locale (a decimal comma and grouping in French,
// "19 560"); the exponent form beyond 1e15 and under 1e-9. Without a locale: plain.
function format(value, locale) {
    if (value === 0)
        return "0";
    const abs = Math.abs(value);
    if (abs >= 1e15 || abs < 1e-9)
        return Numbers.localize(value.toExponential(8).replace(/\.?0+e/, "e"), locale);
    const rounded = Number(value.toPrecision(12));
    if (rounded === 0)
        return "0";
    const digits = Math.max(0, 11 - Math.floor(Math.log10(Math.abs(rounded))));
    return Numbers.localize(Numbers.trimmed(rounded, Math.min(20, digits)), locale);
}

// Percentage phrasings (palette slice C1), read before the plain grammar: "15% of 85" -> 12.75, "200 + 10%" -> 220 (the
// percentage of the left side added), "200 - 10%" -> 180, "20% off 50" -> 40. In French also "15 % de 85", "20 % de remise sur 50"
// (réduction, rabais), "15 pour cent de 85". The base (y) is any expression the grammar accepts; the percentage (x) is a
// plain number. Returns the value or null when the text is none of these phrasings or its base does not evaluate.
const NUM = "(\\d+\\.?\\d*|\\.\\d+)";
const PCT = "\\s*(?:%|percent|pour\\s*cent|pourcent)";

function evaluateBase(text) {
    const r = evaluate(text);
    return r.ok ? r.value : null;
}

function percentPhrase(input, locale) {
    if (typeof input !== "string" || input.length === 0 || input.length > MAX_LENGTH)
        return null;
    const text = input.toLowerCase().trim();
    const fr = Numbers.languageOf(locale) === "fr";
    let m = new RegExp("^" + NUM + PCT + "\\s+(?:(?:of" + (fr ? "|de|du|des" : "") + ")\\s+" + (fr ? "|d'\\s*" : "") + ")(.+)$").exec(text);
    if (m) {
        const y = evaluateBase(m[2]);
        if (y !== null)
            return Number(m[1]) / 100 * y;
    }
    const off = "off" + (fr ? "|de\\s+(?:remise|r[ée]duction|rabais)\\s+sur|(?:remise|r[ée]duction|rabais)\\s+de" : "");
    m = new RegExp("^" + NUM + PCT + "\\s+(?:" + off + ")\\s+(.+)$").exec(text);
    if (m) {
        const y = evaluateBase(m[2]);
        return y === null ? null : y * (1 - Number(m[1]) / 100);
    }
    m = new RegExp("^(.+?)\\s*([+-])\\s*" + NUM + PCT + "$").exec(text);
    if (m) {
        const y = evaluateBase(m[1]);
        if (y === null)
            return null;
        const x = Number(m[3]) / 100;
        return m[2] === "+" ? y * (1 + x) : y * (1 - x);
    }
    return null;
}

// Provider entry point: {text, value} or null. `locale` (optional, Qt.locale()): numbers are read and written the way the
// language does ("1,5 * 2" in French, "19 560").
function answer(input, locale) {
    if (typeof input !== "string")
        return null;
    const text = Numbers.normalizeInput(input, locale);
    const phrased = percentPhrase(text, locale);
    if (phrased !== null && isFinite(phrased))
        return {value: phrased, text: format(phrased, locale)};
    if (!isExpression(text))
        return null;
    const r = evaluate(text);
    return r.ok ? {value: r.value, text: format(r.value, locale)} : null;
}
