.pragma library
.import "WallpaperConfig.js" as WallpaperConfig

// One model for a setting that can differ per display: a global value (the key itself, "All Displays") and an optional
// per-display override stored next to it. Shared by the Settings app (what it writes), the shell (what each display reads)
// and the tests; pure functions, no I/O. The wallpaper's `wallpaper.outputs` (URR-015, URR-034) is the same model; this is
// the generic form used by the Dock (`dock.outputs`), the menu bar and the screen corners.
//
// Stored: a list of at most MAX_OUTPUTS entries `{display: {name, model, serial}, <field>: value, ...}`. A display is
// identified like the wallpaper does (WallpaperConfig.displayKey: model and serial, else the connector). A field that an
// entry does not have follows the global value. An override of a display that is not connected stays stored.
// `schema` is a map field -> rule; a rule is {type: "integer"|"number", min, max}, {type: "boolean"} or {type: "enum", values}:
// the rules of the keys themselves, taken from the generated SettingsContract (DOCK_SCHEMA, MENUBAR_SCHEMA, HOTCORNERS_SCHEMA).

const MAX_OUTPUTS = 16;

// The identity of a display as the stored lists name it ({name, model, serial}, WallpaperConfig.displayKey). One function for
// the shell (a Quickshell screen, which has `serialNumber`) and the Settings app (the backend's screens, which have `serial`), so
// both build the same key from the same monitor. A display that reports no serial is identified by its connector, so an
// override of such a display follows the connector (the port), not the monitor.
function identity(screen) {
    const s = screen || {};
    return {name: s.name || "", model: s.model || "", serial: s.serialNumber || s.serial || ""};
}

function isPlainObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

function asArray(v, cap) {
    return WallpaperConfig.asArray(v, cap);
}

function fieldProblem(rule, value) {
    switch (rule.type) {
    case "boolean":
        return typeof value === "boolean";
    case "enum":
        return typeof value === "string" && rule.values.indexOf(value) >= 0;
    case "integer":
        return typeof value === "number" && isFinite(value) && Math.floor(value) === value && value >= rule.min && value <= rule.max;
    case "number":
        return typeof value === "number" && isFinite(value) && value >= rule.min && value <= rule.max;
    }
    return false;
}

function entryProblem(schema, entry) {
    if (!isPlainObject(entry))
        return "not-an-object";
    for (const key of Object.keys(entry)) {
        if (key !== "display" && !(key in schema))
            return "unknown key " + key;
    }
    if (!WallpaperConfig.validDisplay(entry.display))
        return "display";
    for (const key of Object.keys(schema)) {
        if (key in entry && !fieldProblem(schema[key], entry[key]))
            return key;
    }
    return "";
}

// "" when `raw` is a valid list (at most MAX_OUTPUTS valid entries, no display twice), else the reason.
function problem(schema, raw) {
    const list = asArray(raw, MAX_OUTPUTS + 1);
    if (list === null)
        return "not-an-array";
    if (list.length > MAX_OUTPUTS || (list.realLength || 0) > MAX_OUTPUTS)
        return "too-many";
    const seen = {};
    for (let i = 0; i < list.length; i++) {
        const why = entryProblem(schema, list[i]);
        if (why !== "")
            return "entry " + i + ": " + why;
        const k = WallpaperConfig.displayKey(list[i].display);
        if (seen[k])
            return "entry " + i + ": duplicate display";
        seen[k] = true;
    }
    return "";
}

function clean(schema, entry) {
    const out = {display: {name: entry.display.name, model: entry.display.model, serial: entry.display.serial}};
    for (const key of Object.keys(schema)) {
        if (key in entry)
            out[key] = entry[key];
    }
    return out;
}

// The valid entries of what is stored (a bad entry or a repeated display is dropped, the list is capped); what a reader uses.
function normalize(schema, raw) {
    const list = asArray(raw, MAX_OUTPUTS);
    if (list === null)
        return [];
    const out = [];
    for (const e of list) {
        if (entryProblem(schema, e) !== "")
            continue;
        if (out.some(o => WallpaperConfig.sameDisplay(o.display, e.display)))
            continue;
        out.push(clean(schema, e));
    }
    return out;
}

function entryOf(schema, raw, display) {
    return normalize(schema, raw).find(e => WallpaperConfig.sameDisplay(e.display, display)) || null;
}

// The values that apply to `display`: `globals` ({field: value}) with the display's own fields over them.
function resolve(schema, globals, raw, display) {
    const out = Object.assign({}, globals);
    const entry = display ? entryOf(schema, raw, display) : null;
    if (entry) {
        for (const key of Object.keys(schema)) {
            if (key in entry)
                out[key] = entry[key];
        }
    }
    return out;
}

// True when `display` has its own value for `field`.
function overridden(schema, raw, display, field) {
    const e = display ? entryOf(schema, raw, display) : null;
    return e !== null && field in e;
}

// True when `display` has an entry of any field.
function hasOverride(schema, raw, display) {
    return display ? entryOf(schema, raw, display) !== null : false;
}

// The stored list with `fields` set on the display's entry (an entry is created when there is none). A full list refuses a new
// display and returns the list unchanged.
function withOverride(schema, raw, display, fields) {
    const base = normalize(schema, raw);
    const next = [];
    let found = false;
    for (const e of base) {
        if (WallpaperConfig.sameDisplay(e.display, display)) {
            found = true;
            next.push(clean(schema, Object.assign({}, e, fields, {display: e.display})));
        } else {
            next.push(e);
        }
    }
    if (!found) {
        if (next.length >= MAX_OUTPUTS)
            return base;
        next.push(clean(schema, Object.assign({}, fields, {display: {name: display.name || "", model: display.model || "", serial: display.serial || ""}})));
    }
    return next;
}

// The stored list without the display's entry: it follows All Displays again for every field.
function withoutOverride(schema, raw, display) {
    return normalize(schema, raw).filter(e => !WallpaperConfig.sameDisplay(e.display, display));
}
