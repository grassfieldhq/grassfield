.pragma library
.import "Numbers.js" as Numbers

// Unit conversion (pure, unit-tested): length, mass, temperature, data sizes, speed, area, volume, time, pressure, energy,
// angles, and number bases (hex, bin, oct, dec). No currency (nothing leaves the machine, ADR-0067 D-net).
// Query forms: "10 km in mi", "100f to c", "2 GiB in MB" (separators: in, to, as, ->; in French also en, vers).
// The number is read and the answer written in the session's language (a `locale`: Qt.locale()): "25,5 km en mi" is read
// as 25.5 and answered with a decimal comma and grouping, rounded like Spotlight (4 decimals from 1 up, 4 significant
// digits below 1).

// factor = size of the unit in the category's base unit (m, kg, B). Temperature is special.
const TABLE = [
    {cat: "length", units: [
        ["mm", 0.001, ["millimeter", "millimeters", "millimetre", "millimetres", "millimètre", "millimètres"]],
        ["cm", 0.01, ["centimeter", "centimeters", "centimetre", "centimetres", "centimètre", "centimètres"]],
        ["m", 1, ["meter", "meters", "metre", "metres", "mètre", "mètres"]],
        ["km", 1000, ["kilometer", "kilometers", "kilometre", "kilometres", "kilomètre", "kilomètres"]],
        ["in", 0.0254, ["inch", "inches", "pouce", "pouces"]],
        ["ft", 0.3048, ["foot", "feet", "pied", "pieds"]],
        ["yd", 0.9144, ["yard", "yards"]],
        ["mi", 1609.344, ["mile", "miles"]]
    ]},
    {cat: "mass", units: [
        ["mg", 0.000001, ["milligram", "milligrams", "milligramme", "milligrammes"]],
        ["g", 0.001, ["gram", "grams", "gramme", "grammes"]],
        ["kg", 1, ["kilogram", "kilograms", "kilo", "kilos", "kilogramme", "kilogrammes"]],
        ["t", 1000, ["tonne", "tonnes"]],
        ["oz", 0.028349523125, ["ounce", "ounces", "once", "onces"]],
        ["lb", 0.45359237, ["lbs", "pound", "pounds", "livre", "livres"]]
    ]},
    {cat: "data", units: [
        ["B", 1, ["byte", "bytes", "o", "octet", "octets"]],
        ["KB", 1000, ["kilobyte", "kilobytes", "ko", "kilooctet", "kilooctets"]],
        ["MB", 1e6, ["megabyte", "megabytes", "mo", "megaoctet", "megaoctets", "mégaoctet", "mégaoctets"]],
        ["GB", 1e9, ["gigabyte", "gigabytes", "go", "gigaoctet", "gigaoctets"]],
        ["TB", 1e12, ["terabyte", "terabytes", "teraoctet", "teraoctets", "téraoctet", "téraoctets"]],
        ["KiB", 1024, ["kibibyte", "kibibytes", "kio"]],
        ["MiB", 1048576, ["mebibyte", "mebibytes", "mio"]],
        ["GiB", 1073741824, ["gibibyte", "gibibytes", "gio"]],
        ["TiB", 1099511627776, ["tebibyte", "tebibytes", "tio"]]
    ]},
    {cat: "speed", units: [
        ["m/s", 1, ["mps", "ms-1", "meter/second", "metre/second", "mètre/seconde"]],
        ["km/h", 1 / 3.6, ["kmh", "kph", "kmph", "kilometer/hour", "kilometre/hour", "kilomètre/heure", "kilomètres/heure"]],
        ["mph", 0.44704, ["mi/h", "mile/hour", "miles/hour", "mile/heure", "miles/heure"]],
        ["ft/s", 0.3048, ["fps", "foot/second", "feet/second", "pied/seconde", "pieds/seconde"]],
        ["kn", 1852 / 3600, ["kt", "knot", "knots", "nœud", "nœuds", "noeud", "noeuds"]]
    ]},
    {cat: "area", units: [
        ["mm²", 1e-6, ["mm2"]],
        ["cm²", 1e-4, ["cm2"]],
        ["m²", 1, ["m2", "sqm"]],
        ["km²", 1e6, ["km2", "sqkm"]],
        ["ha", 1e4, ["hectare", "hectares"]],
        ["in²", 0.00064516, ["in2", "sqin"]],
        ["ft²", 0.09290304, ["ft2", "sqft"]],
        ["yd²", 0.83612736, ["yd2", "sqyd"]],
        ["mi²", 2589988.110336, ["mi2", "sqmi"]],
        ["acre", 4046.8564224, ["acres"]]
    ]},
    {cat: "volume", units: [
        ["mL", 0.001, ["cm3", "cm³", "cc", "milliliter", "milliliters", "millilitre", "millilitres"]],
        ["cL", 0.01, ["centiliter", "centiliters", "centilitre", "centilitres"]],
        ["dL", 0.1, ["deciliter", "deciliters", "decilitre", "decilitres", "décilitre", "décilitres"]],
        ["L", 1, ["liter", "liters", "litre", "litres"]],
        ["m³", 1000, ["m3"]],
        ["tsp", 0.00492892159375, ["teaspoon", "teaspoons"]],
        ["tbsp", 0.01478676478125, ["tablespoon", "tablespoons"]],
        ["fl oz", 0.0295735295625, ["floz", "fluidounce", "fluidounces"]],
        ["cup", 0.2365882365, ["cups"]],
        ["pt", 0.473176473, ["pint", "pints", "pinte", "pintes"]],
        ["qt", 0.946352946, ["quart", "quarts"]],
        ["gal", 3.785411784, ["gallon", "gallons"]]
    ]},
    {cat: "time", units: [
        ["ms", 0.001, ["millisecond", "milliseconds", "milliseconde", "millisecondes"]],
        ["s", 1, ["sec", "secs", "second", "seconds", "seconde", "secondes"]],
        ["min", 60, ["mins", "minute", "minutes"]],
        ["h", 3600, ["hr", "hrs", "hour", "hours", "heure", "heures"]],
        ["d", 86400, ["day", "days", "jour", "jours"]],
        ["wk", 604800, ["week", "weeks", "semaine", "semaines"]]
    ]},
    {cat: "pressure", units: [
        ["Pa", 1, ["pascal", "pascals"]],
        ["hPa", 100, ["hectopascal", "hectopascals", "mbar", "millibar", "millibars"]],
        ["kPa", 1000, ["kilopascal", "kilopascals"]],
        ["MPa", 1e6, ["megapascal", "megapascals", "mégapascal", "mégapascals"]],
        ["bar", 1e5, ["bars"]],
        ["atm", 101325, ["atmosphere", "atmospheres", "atmosphère", "atmosphères"]],
        ["psi", 6894.757293168, []],
        ["mmHg", 133.322387415, ["torr"]]
    ]},
    {cat: "energy", units: [
        ["J", 1, ["joule", "joules"]],
        ["kJ", 1000, ["kilojoule", "kilojoules"]],
        ["cal", 4.184, ["calorie", "calories"]],
        ["kcal", 4184, ["kilocalorie", "kilocalories"]],
        ["Wh", 3600, ["watt-hour", "watt-hours", "wattheure", "wattheures"]],
        ["kWh", 3.6e6, ["kilowatt-hour", "kilowatt-hours", "kilowattheure", "kilowattheures"]],
        ["BTU", 1055.05585262, ["btus"]]
    ]},
    {cat: "angle", units: [
        ["°", Math.PI / 180, ["deg", "degree", "degrees", "degré", "degrés", "degre", "degres"]],
        ["rad", 1, ["radian", "radians"]],
        ["grad", Math.PI / 200, ["gon", "gons", "gradian", "gradians"]],
        ["turn", 2 * Math.PI, ["turns", "tour", "tours", "rev"]]
    ]},
    {cat: "temperature", units: [
        ["C", 0, ["celsius", "°c"]],
        ["F", 0, ["fahrenheit", "°f"]],
        ["K", 0, ["kelvin"]]
    ]}
];

// Lowercased alias -> {cat, unit, factor}. Null prototype: arbitrary query text can never hit
// inherited properties.
// The key of a unit name: lowercase, the superscript digits of m², ft³… read as plain digits, a space inside a name dropped
// ("fl oz" = "floz").
function key(name) {
    return name.trim().toLowerCase().replace(/²/g, "2").replace(/³/g, "3").replace(/\s+/g, "");
}

const ALIASES = (function () {
    const map = Object.create(null);
    for (const group of TABLE) {
        for (const u of group.units) {
            const names = [u[0]].concat(u[2]);
            for (const raw of names) {
                const n = key(raw);
                if (!(n in map))
                    map[n] = {cat: group.cat, unit: u[0], factor: u[1]};
            }
        }
    }
    return map;
})();

function lookup(name) {
    const k = key(name);
    return k in ALIASES ? ALIASES[k] : null;
}

function toCelsius(v, unit) {
    switch (unit) {
    case "F":
        return (v - 32) * 5 / 9;
    case "K":
        return v - 273.15;
    }
    return v;
}

function fromCelsius(v, unit) {
    switch (unit) {
    case "F":
        return v * 9 / 5 + 32;
    case "K":
        return v + 273.15;
    }
    return v;
}

function convert(value, from, to) {
    if (from.cat === "temperature")
        return fromCelsius(toCelsius(value, from.unit), to.unit);
    return value * from.factor / to.factor;
}

// The answer's number in the locale: 4 decimals from 1 up (the integer part is never rounded), 4 significant digits below 1,
// the exponent form beyond 1e15 and under 1e-6; trailing zeros dropped.
function formatNumber(v, locale) {
    if (v === 0)
        return "0";
    const abs = Math.abs(v);
    if (abs >= 1e15 || abs < 1e-6)
        return Numbers.localize(v.toExponential(4).replace(/\.?0+e/, "e"), locale);
    const decimals = abs >= 1 ? 4 : Math.min(10, 3 - Math.floor(Math.log10(abs)));
    return Numbers.localize(Numbers.trimmed(v, decimals), locale);
}

// The words that join the two units: in, to, as and -> everywhere, en and vers in French.
function connectors(locale) {
    return Numbers.languageOf(locale) === "fr" ? "in|to|as|->|en|vers" : "in|to|as|->";
}

// Number bases (palette slice C2): "255 to hex" -> 0xff, "0xff in dec" -> 255, "ff hex to bin" -> 0b11111111, "0b1010 to
// decimal". A whole number is written with its prefix (0x, 0b, 0o) except in decimal. Names: hex/hexadecimal/hexadécimal,
// bin/binary/binaire, oct/octal, dec/decimal/décimal/décimale. Whole numbers only, at most 2^53 - 1.
const BASES = (function () {
    const map = Object.create(null);
    const add = (radix, names) => names.forEach(n => map[n] = radix);
    add(16, ["hex", "hexa", "hexadecimal", "hexadécimal", "hexadecimale", "hexadécimale"]);
    add(2, ["bin", "binary", "binaire"]);
    add(8, ["oct", "octal", "octale"]);
    add(10, ["dec", "decimal", "décimal", "decimale", "décimale"]);
    return map;
})();

const BASE_DIGITS = {2: "[01]+", 8: "[0-7]+", 10: "\\d+", 16: "[0-9a-f]+"};
const BASE_PREFIX = {2: "0b", 8: "0o", 10: "", 16: "0x"};

function baseOf(name) {
    const k = name.trim().toLowerCase();
    return k in BASES ? BASES[k] : 0;
}

function baseAnswer(text, locale) {
    const names = Object.keys(BASES).join("|");
    const m = new RegExp("^\\s*(-?)\\s*(0x[0-9a-f]+|0b[01]+|0o[0-7]+|[0-9a-f]+)\\s*(" + names + ")?\\s+(?:" + connectors(locale)
        + ")\\s+(" + names + ")\\s*$", "i").exec(text);
    if (!m)
        return null;
    let radix = 10;
    let digits = m[2].toLowerCase();
    const prefix = /^0([xbo])/.exec(digits);
    if (prefix) {
        radix = prefix[1] === "x" ? 16 : (prefix[1] === "b" ? 2 : 8);
        digits = digits.slice(2);
        if (m[3] && baseOf(m[3]) !== radix)
            return null;
    } else if (m[3]) {
        radix = baseOf(m[3]);
    }
    if (!new RegExp("^" + BASE_DIGITS[radix] + "$").test(digits))
        return null;
    const target = baseOf(m[4]);
    const n = parseInt(digits, radix);
    if (!Number.isSafeInteger(n))
        return null;
    const v = m[1] === "-" ? -n : n;
    const body = Math.abs(v).toString(target);
    const out = target === 10 ? Numbers.localize(String(Math.abs(v)), locale) : BASE_PREFIX[target] + body;
    const names2 = {2: "bin", 8: "oct", 10: "dec", 16: "hex"};
    return {value: v, from: names2[radix], to: names2[target], text: (v < 0 ? "-" : "") + out};
}

// Returns {value, text, from, to} or null. `locale` (optional): what Qt.locale() is.
function answer(input, locale) {
    if (typeof input !== "string" || input.length > 100)
        return null;
    const text = Numbers.normalizeInput(input, locale);
    const based = baseAnswer(text, locale);
    if (based)
        return based;
    const m = new RegExp("^\\s*(-?(?:\\d+\\.?\\d*|\\.\\d+)(?:e[+-]?\\d+)?)\\s*([^\\s\\d]\\S*)\\s+(?:" + connectors(locale) + ")\\s+(\\S+)\\s*$", "i").exec(text);
    if (!m)
        return null;
    const from = lookup(m[2]);
    const to = lookup(m[3]);
    if (!from || !to || from.cat !== to.cat)
        return null;
    const n = Number(m[1]);
    if (!isFinite(n))
        return null;
    const result = convert(n, from, to);
    if (!isFinite(result))
        return null;
    return {value: result, from: from.unit, to: to.unit, text: formatNumber(result, locale) + " " + to.unit};
}
