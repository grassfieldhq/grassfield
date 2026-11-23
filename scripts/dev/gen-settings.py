#!/usr/bin/env python3
"""Generate the settings contract files from config/schema/grassfield.schema.json (stdlib only).

The schema is the one source of the settings contract (ADR-0020). Every leaf (a property that is not an object with
`properties`) must carry a `default`. Keys of array items and of additionalProperties objects are not leaves.
Written files:
  config/defaults/grassfield.json        the defaults, nested, in schema order
  ui/Grassfield/Ui/SettingsContract.js   VERSION, DEFAULTS and RULES of the settable keys, validate, normalize, read

A leaf is settable unless its `x-grassfield` annotation says `settable: false` (keys owned by the Dock, `version`).
Its rule comes from the schema (enum, boolean, number and integer bounds) or from the annotation's `rule`: tint,
folderColor, pointerColor, localeName, plainText and nodeName are the schema `pattern`; wallpaperPath, wallpaperOutputs, mainDisplays, notificationApps,
notificationStyles and pathList have hand-written checks in the engine below. Any other leaf without a rule fails.

Usage: gen-settings.py            write the generated files
       gen-settings.py --check    exit 1 when a generated file is stale (no write)
       gen-settings.py --selftest a leaf without a default fails, stale output fails
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "config/schema/grassfield.schema.json"
DEFAULTS = ROOT / "config/defaults/grassfield.json"
CONTRACT = ROOT / "ui/Grassfield/Ui/SettingsContract.js"

PATTERN_RULES = ("tint", "folderColor", "pointerColor", "localeName", "plainText", "nodeName")
# Per-display override lists (DisplayScope): rule type -> (group, fields). The bounds of a field are the key's own rule.
DISPLAY_SCOPES = {
    "dockOutputs": ("DOCK_SCHEMA", "dock", ["size", "position", "magnification", "magnificationEnabled", "autohide"]),
    "menubarOutputs": ("MENUBAR_SCHEMA", "menubar", ["autoHide", "showBackground"]),
    "hotCornersOutputs": ("HOTCORNERS_SCHEMA", "hotCorners", ["topLeft", "topRight", "bottomLeft", "bottomRight"]),
}
CUSTOM_RULES = ("wallpaperPath", "wallpaperOutputs", "dockOutputs", "menubarOutputs", "hotCornersOutputs", "mainDisplays", "notificationApps", "notificationStyles", "pathList")


def is_group(node):
    return node.get("type") == "object" and "properties" in node


def leaves(node, path, errors):
    """[(dotted path, leaf schema)] in schema order; a leaf without `default` is an error."""
    out = []
    for key, child in node["properties"].items():
        where = f"{path}.{key}" if path else key
        if is_group(child):
            out += leaves(child, where, errors)
        elif "default" in child:
            out.append((where, child))
        else:
            errors.append(f"{where}: leaf without a default")
    return out


def defaults_of(node, path, errors):
    """Nested defaults of an object schema."""
    out = {}
    for key, child in node["properties"].items():
        where = f"{path}.{key}" if path else key
        if is_group(child):
            out[key] = defaults_of(child, where, errors)
        elif "default" in child:
            out[key] = child["default"]
        else:
            errors.append(f"{where}: leaf without a default")
    return out


def rule_of(path, leaf, errors):
    name = leaf.get("x-grassfield", {}).get("rule")
    if name in PATTERN_RULES:
        if "pattern" not in leaf:
            errors.append(f"{path}: rule {name} needs a schema pattern")
        return {"type": name, "pattern": leaf.get("pattern", "")}
    if name in CUSTOM_RULES:
        return {"type": name}
    if name:
        errors.append(f"{path}: unknown rule {name!r}")
        return {}
    if "enum" in leaf:
        return {"type": "enum", "values": leaf["enum"]}
    if leaf.get("type") == "boolean":
        return {"type": "boolean"}
    if leaf.get("type") in ("integer", "number"):
        rule = {"type": leaf["type"]}
        if leaf.get("x-grassfield", {}).get("zeroIsExact"):
            rule["zeroIsExact"] = True
        if "minimum" in leaf:
            rule["min"] = leaf["minimum"]
        if "maximum" in leaf:
            rule["max"] = leaf["maximum"]
        return rule
    errors.append(f"{path}: no rule for a {leaf.get('type')} leaf (annotate it with x-grassfield.rule)")
    return {}


def render(schema, errors):
    return json.dumps(defaults_of(schema, "", errors), indent=2, ensure_ascii=False) + "\n"


ENGINE = r'''
function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

// The error message for a value that is not acceptable for the key, or "" when it is. Strict: nothing is repaired.
function validate(path, value) {
    const rule = RULES[path];
    if (!rule)
        return "unknown setting: " + path;
    switch (rule.type) {
    case "enum":
        return rule.values.indexOf(value) >= 0 ? "" : path + ": expected one of " + rule.values.join(", ");
    case "tint":
        return typeof value === "string" && new RegExp(rule.pattern).test(value) ? "" : path + ": expected accent or a #rrggbb colour";
    case "folderColor":
        return typeof value === "string" && new RegExp(rule.pattern).test(value) ? "" : path + ": expected theme, accent or a #rrggbb colour";
    case "pointerColor":
        return typeof value === "string" && new RegExp(rule.pattern).test(value) ? "" : path + ": expected a #rrggbb colour";
    case "localeName":
        return typeof value === "string" && new RegExp(rule.pattern).test(value) ? "" : path + ": expected auto or a locale name such as fr_CH";
    case "plainText":
        return typeof value === "string" && new RegExp(rule.pattern).test(value) ? "" : path + ": expected one line of text without control characters";
    case "nodeName":
        return typeof value === "string" && new RegExp(rule.pattern).test(value) ? "" : path + ": expected \"\" or a PipeWire node name";
    case "wallpaperPath":
        // "" (no path) is valid: the source then reads as the built-in artwork.
        return value === "" || WallpaperConfig.pathProblem(value) === "" ? "" : path + ": expected an absolute path without control characters (at most 4096 bytes)";
    case "wallpaperOutputs": {
        const why = WallpaperConfig.outputsProblem(value);
        return why === "" ? "" : path + ": " + why;
    }
    case "dockOutputs":
    case "menubarOutputs":
    case "hotCornersOutputs": {
        const why = DisplayScope.problem(scopeSchema(rule.type), value);
        return why === "" ? "" : path + ": " + why;
    }
    case "mainDisplays": {
        const why = DisplayRole.problem(value);
        return why === "" ? "" : path + ": " + why;
    }
    case "notificationApps": {
        const why = NotificationPrefs.problem(value);
        return why === "" ? "" : path + ": " + why;
    }
    case "notificationStyles": {
        const why = NotificationPrefs.problemStyles(value);
        return why === "" ? "" : path + ": " + why;
    }
    case "pathList": {
        // Folders kept in the Dock as stacks: absolute paths or ~/ ones, as the Dock reads them (shell/dock/Stacks.js folderList).
        const ok = Array.isArray(value) && value.length <= 12 && value.every(v => typeof v === "string" && v !== "" && v.length <= 4096
            && !/[\u0000-\u001f]/.test(v) && (v.indexOf("/") === 0 || v.indexOf("~/") === 0) && v.split("/").indexOf("..") < 0);
        return ok ? "" : path + ": expected at most 12 absolute paths without control characters";
    }
    case "boolean":
        return typeof value === "boolean" ? "" : path + ": expected true or false";
    case "integer":
        if (typeof value !== "number" || !isFinite(value) || Math.floor(value) !== value)
            return path + ": expected an integer";
        return inRange(rule, value) ? "" : path + ": expected " + rule.min + " to " + rule.max;
    case "number":
        if (typeof value !== "number" || !isFinite(value))
            return path + ": expected a number";
        return inRange(rule, value) ? "" : path + ": expected " + rule.min + " to " + rule.max;
    }
    return "unsupported rule";
}

function inRange(rule, value) {
    return (rule.min === undefined || value >= rule.min) && (rule.max === undefined || value <= rule.max);
}

// The value a reader uses for a stored value (any JSON type): a number is clamped to its range, an integer is rounded
// first, anything else invalid takes the key's default (how macOS reads a defaults value that is out of range: the Dock
// clamps its tile size). A colour is lower case. Any other valid value is returned as it is. A string, a boolean or null
// where a number is expected is never turned into one ("0" and false are not 0: lock.idleMinutes must never read 0 from them).
// A rule with zeroIsExact (lock.idleMinutes, where 0 means "never") fails closed: a value below 0, or one that rounds to 0
// without being exactly 0, is the default, so only an exact 0 reads 0.
function normalize(path, value) {
    const rule = RULES[path];
    if (!rule)
        return undefined;
    // The per-app notification lists keep their good entries and drop the bad or repeated ones (a write is still refused
    // as a whole by validate): the shell and the Settings app read one list.
    if (rule.type === "mainDisplays")
        return DisplayRole.normalize(value);
    if (rule.type === "dockOutputs" || rule.type === "menubarOutputs" || rule.type === "hotCornersOutputs")
        return DisplayScope.normalize(scopeSchema(rule.type), value);
    if (rule.type === "notificationApps")
        return NotificationPrefs.normalize(value);
    if (rule.type === "notificationStyles")
        return NotificationPrefs.normalizeStyles(value);
    if ((rule.type === "number" || rule.type === "integer") && typeof value === "number" && isFinite(value)) {
        if (rule.zeroIsExact && (value < 0 || (value !== 0 && Math.round(value) === 0)))
            return DEFAULTS[path];
        let n = rule.type === "integer" ? Math.round(value) : value;
        if (rule.min !== undefined)
            n = Math.max(rule.min, n);
        if (rule.max !== undefined)
            n = Math.min(rule.max, n);
        return n;
    }
    if (validate(path, value) !== "")
        return DEFAULTS[path];
    return (rule.type === "tint" || rule.type === "folderColor" || rule.type === "pointerColor") ? value.toLowerCase() : value;
}

// The normalised value of a dotted path in parsed data; the default when absent or invalid.
function read(data, path) {
    let node = data;
    for (const part of path.split(".")) {
        if (!isObject(node))
            return DEFAULTS[path];
        node = node[part];
    }
    return normalize(path, node);
}
'''


def render_contract(schema, errors):
    entries = leaves(schema, "", errors)
    settable = [(p, leaf) for p, leaf in entries if leaf.get("x-grassfield", {}).get("settable") is not False]
    version = next((leaf["default"] for p, leaf in entries if p == "version"), 1)
    out = [
        "// Generated by scripts/dev/gen-settings.py from config/schema/grassfield.schema.json (ADR-0020); do not edit.",
        ".pragma library",
        '.import "WallpaperConfig.js" as WallpaperConfig',
        '.import "DisplayRole.js" as DisplayRole',
        '.import "DisplayScope.js" as DisplayScope',
        '.import "NotificationPrefs.js" as NotificationPrefs',
        "",
        "// The contract version of grassfield.json.",
        f"const VERSION = {json.dumps(version)};",
        "",
        "// Default of every settable key, by dotted path (dock.pinned, dock.recent and dock.stackOptions belong to the Dock).",
        "const DEFAULTS = {",
    ]
    out.append(",\n".join(f"    {json.dumps(p)}: {json.dumps(leaf['default'], ensure_ascii=False)}" for p, leaf in settable))
    out += ["};", "",
            "// Default of every leaf of the schema, the keys owned by the Dock included (a reader that puts a key back to its",
            "// default when the file has none).",
            "const ALL_DEFAULTS = {"]
    out.append(",\n".join(f"    {json.dumps(p)}: {json.dumps(leaf['default'], ensure_ascii=False)}" for p, leaf in entries if p != "version"))
    out += ["};", "", "// Rule of every settable key.", "const RULES = {"]
    out.append(",\n".join(f"    {json.dumps(p)}: {json.dumps(rule_of(p, leaf, errors), ensure_ascii=False)}" for p, leaf in settable))
    out += ["};", "", "// The fields of each per-display override list and their rules (the keys' own: DisplayScope.js has no copy of a bound)."]
    for name, (const, group, fields) in DISPLAY_SCOPES.items():
        out.append(f"const {const} = {{")
        out.append(",\n".join(f'    "{f}": RULES["{group}.{f}"]' for f in fields))
        out.append("};")
    out += ["", "function scopeSchema(ruleType) {", "    switch (ruleType) {"]
    for name, (const, group, fields) in DISPLAY_SCOPES.items():
        out += [f'    case "{name}":', f"        return {const};"]
    out += ["    }", "    return null;", "}"]
    return "\n".join(out) + "\n" + ENGINE


def outputs(schema, errors):
    return [(DEFAULTS, render(schema, errors)), (CONTRACT, render_contract(schema, errors))]


def stale(schema, targets=None):
    """Errors for generation problems and for generated files that differ from what the schema produces now."""
    errors = []
    produced = outputs(schema, errors)
    if errors:
        return errors
    for target, text in produced:
        target = pathlib.Path(targets.get(target, target)) if targets else target
        if not target.exists() or target.read_text() != text:
            shown = target.relative_to(ROOT) if target.is_relative_to(ROOT) else target
            errors.append(f"{shown}: stale, run scripts/dev/gen-settings.py")
    return errors


def selftest():
    import tempfile
    failures = []
    if stale(json.loads(SCHEMA.read_text())):
        failures.append("the repository's generated files are not current")
    # A tiny schema of its own: the check never depends on a real key or value of the product schema.
    tiny = {"type": "object", "properties": {"version": {"type": "integer", "default": 1},
                                             "group": {"type": "object", "properties": {"n": {"type": "number", "default": 7, "minimum": 0, "maximum": 9}}}}}
    broken = json.loads(json.dumps(tiny))
    del broken["properties"]["group"]["properties"]["n"]["default"]
    if not stale(broken):
        failures.append("a leaf without a default was accepted")
    unruled = json.loads(json.dumps(tiny))
    unruled["properties"]["group"]["properties"]["list"] = {"type": "array", "default": []}
    if not stale(unruled):
        failures.append("a leaf without a rule was accepted")
    with tempfile.TemporaryDirectory() as tmp:
        fake = {DEFAULTS: pathlib.Path(tmp) / "grassfield.json", CONTRACT: pathlib.Path(tmp) / "SettingsContract.js"}
        for target, text in outputs(tiny, []):
            fake[target].write_text(text)
        if stale(tiny, fake):
            failures.append("fresh output reported stale")
        for target in (DEFAULTS, CONTRACT):
            original = fake[target].read_text()
            fake[target].write_text(original.replace("7", "8"))
            if not stale(tiny, fake):
                failures.append(f"stale {target.name} was accepted")
            fake[target].write_text(original)
    for f in failures:
        print(f"gen-settings selftest: {f}", file=sys.stderr)
    print("gen-settings selftest: " + ("FAILED" if failures else "ok"))
    return 1 if failures else 0


def main(argv):
    if argv == ["--selftest"]:
        return selftest()
    if argv not in ([], ["--check"]):
        print(__doc__, file=sys.stderr)
        return 2
    schema = json.loads(SCHEMA.read_text())
    errors = []
    produced = outputs(schema, errors)
    if not errors and argv == ["--check"]:
        errors = stale(schema)
    for e in errors:
        print(f"gen-settings: {e}", file=sys.stderr)
    if errors:
        return 1
    for target, text in produced:
        if not argv:
            target.write_text(text)
        print(f"gen-settings: {target.relative_to(ROOT)} {'current' if argv else 'written'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
