.pragma library

// Settings > Displays (ADR-0031): the state the shell publishes, the choices of the pane, and the lines of displays.conf and of a
// trial (the rule of config/hypr/grassfield/displays.lua, checked again in C++ by systemguard.h::isDisplayLine). Pure functions,
// unit-tested (tests/unit/tst_settingsdisplays.qml).

// The scales the resolution choices are made of: Hyprland takes a scale whose logical size is a whole number of pixels.
var SCALES = [1, 1.25, 1.333333, 1.5, 1.6, 1.666667, 1.75, 2, 2.4, 2.5, 3];
// At most this many resolution choices, as macOS ("Larger Text", two between, "Default", "More Space").
var MAX_CHOICES = 5;
// The span of the choices around the default, as macOS's: the most space about 1.25 times the default's room, the largest text
// about 1.3 times the default's size.
var MORE_SPACE_RATIO = 1.25;
var LARGER_TEXT_RATIO = 1.3;
// The narrowest logical width offered (a smaller one leaves no room for the menu bar's items and a window).
var MIN_LOGICAL_WIDTH = 1024;

function num(v) {
    return typeof v === "number" && isFinite(v) ? v : 0;
}

// "2880x1800@120.00Hz" -> {w, h, hz}, or null.
function parseMode(s) {
    const m = /^(\d{1,5})x(\d{1,5})@(\d{1,4}(?:\.\d{1,3})?)(?:Hz)?$/.exec(String(s));
    return m ? {w: parseInt(m[1], 10), h: parseInt(m[2], 10), hz: parseFloat(m[3])} : null;
}

// The state file's text (shell/platform/DisplaysFile.js) -> {monitors, backlight, trial}, or null when it is not one.
function parseState(text) {
    let j;
    try {
        j = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!j || j.v !== 1 || !Array.isArray(j.monitors))
        return null;
    const monitors = j.monitors.filter(m => m && typeof m.name === "string" && m.name !== "" && !m.disabled).map(m => ({
        name: m.name, description: typeof m.description === "string" ? m.description : "", make: String(m.make || ""), model: String(m.model || ""), serial: String(m.serial || ""),
        width: num(m.width), height: num(m.height), refreshRate: num(m.refreshRate), x: num(m.x), y: num(m.y), scale: num(m.scale) || 1,
        transform: num(m.transform), physicalWidth: num(m.physicalWidth), physicalHeight: num(m.physicalHeight),
        modes: (Array.isArray(m.availableModes) ? m.availableModes : []).map(parseMode).filter(x => x !== null)}));
    const light = j.backlight && typeof j.backlight.device === "string" && j.backlight.device !== "" ? {device: j.backlight.device, level: Math.max(0, Math.min(1, num(j.backlight.level)))} : null;
    const trial = j.trial && typeof j.trial.id === "string" ? {id: j.trial.id, state: String(j.trial.state)} : null;
    return {monitors: monitors, backlight: light, trial: trial};
}

// A laptop's own panel (eDP, LVDS, DSI): macOS calls it "Built-in Display".
function isBuiltIn(m) {
    return /^(eDP|LVDS|DSI)-/.test(String(m.name));
}

// The pixels the monitor runs at (its mode, before the scale and the rotation).
function rotated(m) {
    return m.transform % 2 === 1;
}

// The monitor's pixels per inch, from its mode and its physical size; 0 when the size is not known.
function ppi(m) {
    const mmW = m.physicalWidth, mmH = m.physicalHeight;
    if (!(mmW > 0) || !(mmH > 0))
        return 0;
    const inches = Math.sqrt(mmW * mmW + mmH * mmH) / 25.4;
    return Math.sqrt(m.width * m.width + m.height * m.height) / inches;
}

// Hyprland's own default for a panel (its "auto" scale): 2 above 200 pixels per inch, 1.5 above 140, else 1. Without a physical
// size, 1.
function defaultScale(m) {
    const d = ppi(m);
    return d > 200 ? 2 : d > 140 ? 1.5 : 1;
}

function whole(v) {
    return Math.abs(v - Math.round(v)) < 0.01;
}

// Below this density a display is not "Retina" and always offers its native resolution (scale 1) as More Space. macOS's model:
// its Retina displays start well above it (MacBooks about 220 ppi and more, the 27" Studio Display 218), a third-party 4K 27"
// (163 ppi) runs scaled with More Space at about 3008 x 1692 (not its native 3840 x 2160, which needs "Show all resolutions"),
// and a display below about 150 ppi (a 1440p 27" at 109, a 15.6" 1080p laptop panel at 141 to 144) runs at its native
// resolution. Hyprland's own 1.5 default starts at 140 ppi, so the panels between 140 and 150 (the owner's laptop) are the ones
// that lost 100 % to the span alone (review of e0a6e922: deciding by default scale gave native to everything up to 200 ppi).
var NATIVE_MAX_PPI = 150;

// The resolution choices of a monitor, largest text first: [{scale, width, height (logical), isDefault}]. The scales whose
// logical size is whole and at least MIN_LOGICAL_WIDTH wide, within the span around the default; the default and the monitor's own
// scale always in, and the native resolution (scale 1) too on a display below NATIVE_MAX_PPI (macOS's More Space on a display
// that is not Retina is its native resolution; the span alone stopped at the default / MORE_SPACE_RATIO, 1.2 on a 15.6" 1080p
// panel, so 100 % could not be chosen there: the owner's rc6 report); at most MAX_CHOICES, the ends, the default and the scale
// in use kept, then the scales closest to the default.
function scaleChoices(m) {
    const def = defaultScale(m);
    const density = ppi(m);
    const fits = s => whole(m.width / s) && whole(m.height / s) && Math.round(m.width / s) >= MIN_LOGICAL_WIDTH;
    let list = SCALES.filter(s => s >= 1 && s >= def / MORE_SPACE_RATIO - 1e-6 && s <= def * LARGER_TEXT_RATIO + 1e-6 && fits(s));
    const always = density > 0 && density < NATIVE_MAX_PPI && fits(1) ? [def, m.scale, 1] : [def, m.scale];
    for (const s of always) {
        if (!list.some(x => Math.abs(x - s) < 1e-3))
            list.push(s);
    }
    list.sort((a, b) => b - a);
    if (list.length > MAX_CHOICES) {
        // The listed value of a scale (Hyprland reports 1.3333333 where the list has 1.333333).
        const listed = s => list.find(x => Math.abs(x - s) < 1e-3) ?? s;
        const keep = [list[0], list[list.length - 1], listed(def), listed(m.scale)];
        const rest = list.filter(s => keep.indexOf(s) < 0).sort((a, b) => Math.abs(a - def) - Math.abs(b - def));
        for (const s of rest) {
            if (keep.filter((v, i) => keep.indexOf(v) === i).length >= MAX_CHOICES)
                break;
            keep.push(s);
        }
        list = list.filter(s => keep.indexOf(s) >= 0);
    }
    return list.map(s => ({scale: s, width: Math.round(m.width / s), height: Math.round(m.height / s), isDefault: Math.abs(s - def) < 1e-3}));
}

// The index of the choice nearest to the monitor's scale.
function currentChoice(choices, scale) {
    let best = -1, d = Infinity;
    for (let i = 0; i < choices.length; i++) {
        const di = Math.abs(choices[i].scale - scale);
        if (di < d) {
            d = di;
            best = i;
        }
    }
    return best;
}

// The refresh rates of the monitor's current resolution, highest first, as whole or two-decimal numbers.
function refreshRates(m) {
    const seen = {};
    const out = [];
    for (const mode of m.modes) {
        const key = mode.hz.toFixed(2);
        if (mode.w === m.width && mode.h === m.height && !seen[key]) {
            seen[key] = true;
            out.push(mode.hz);
        }
    }
    return out.sort((a, b) => b - a);
}

// "120 Hz", "59.94 Hz": the number in the language's format ("59,94 Hz" in French); `locale` defaults to the UI's.
function hzLabel(hz, locale) {
    const r = Math.round(hz);
    const whole = Math.abs(hz - r) < 0.05;
    return qsTr("%1 Hz").arg((locale || Qt.locale()).toString(whole ? r : hz, "f", whole ? 0 : 2));
}

function scaleText(s) {
    return String(Math.round(s * 1e6) / 1e6);
}

function rateText(hz) {
    return hz.toFixed(2);
}

// The description the line names, or "" when the display cannot be named that way (no description, a control character, too
// long): such a display is shown but not changed.
function descOf(m) {
    const d = String(m.description);
    // Its length in UTF-8 bytes: each %XX of the URI encoding is one byte.
    const bytes = encodeURIComponent(d).replace(/%[0-9A-F]{2}/g, "x").length;
    return d !== "" && !/[\x00-\x1f\x7f]/.test(d) && bytes <= 160 ? d : "";
}

// One line of displays.conf for a monitor with some fields changed ({scale, hz, x, y, transform}), or "" when the display
// cannot be named.
function lineFor(m, change) {
    const c = change || {};
    const desc = descOf(m);
    if (desc === "")
        return "";
    const hz = c.hz !== undefined ? c.hz : m.refreshRate;
    const x = c.x !== undefined ? c.x : m.x, y = c.y !== undefined ? c.y : m.y;
    const scale = c.scale !== undefined ? c.scale : m.scale;
    const transform = c.transform !== undefined ? c.transform : m.transform;
    return ["v1", "desc:" + desc, m.width + "x" + m.height + "@" + rateText(hz), Math.round(x) + "x" + Math.round(y), scaleText(scale), String(transform)].join("\t");
}

// The description a line names ("" when it is not a line).
function descOfLine(line) {
    const f = String(line).split("\t");
    return f.length === 6 && f[1].indexOf("desc:") === 0 ? f[1].slice(5) : "";
}

// The lines of a trial: the kept lines of the other displays, then the new lines (one per changed display).
function mergeLines(kept, fresh) {
    const changed = {};
    for (const l of fresh)
        changed[descOfLine(l)] = true;
    return kept.filter(l => !changed[descOfLine(l)]).concat(fresh);
}

// A trial id: 8 letters and digits.
function trialId(random) {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    let id = "";
    for (let i = 0; i < 8; i++)
        id += chars[Math.floor(random() * chars.length) % chars.length];
    return id;
}

// The logical size of a monitor in the layout (its pixels over its scale, turned with its rotation).
function logicalSize(m) {
    // Hyprland reports a scale to two decimals (1.67 for 1.666667): the listed scale it stands for gives the true size, or a
    // neighbour placed by it would sit a few pixels under the display.
    const scale = SCALES.find(s => Math.abs(s - m.scale) < 0.006) ?? m.scale;
    const w = Math.round(m.width / scale), h = Math.round(m.height / scale);
    return rotated(m) ? {w: h, h: w} : {w: w, h: h};
}

// Arrangement: the monitor `moved` dropped at (x, y) in layout pixels, snapped against `other` so that the two touch along a whole
// edge side (left, right, above or below, whichever is nearest), the free coordinate clamped so that they overlap. Returns {x, y}.
function snapBeside(moved, x, y, other) {
    const a = logicalSize(moved), b = logicalSize(other);
    const cx = x + a.w / 2, cy = y + a.h / 2, ox = other.x + b.w / 2, oy = other.y + b.h / 2;
    const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
    if (Math.abs(cx - ox) / (a.w + b.w) >= Math.abs(cy - oy) / (a.h + b.h)) {
        const nx = cx < ox ? other.x - a.w : other.x + b.w;
        return {x: Math.round(nx), y: Math.round(clamp(y, other.y - a.h + 1, other.y + b.h - 1))};
    }
    const ny = cy < oy ? other.y - a.h : other.y + b.h;
    return {x: Math.round(clamp(x, other.x - a.w + 1, other.x + b.w - 1)), y: Math.round(ny)};
}

// Whether two placed rectangles ({x, y, w, h}) cover a common area, and whether they touch along an edge (at least one pixel
// of it shared; a corner is not enough: the pointer cannot cross there).
function overlaps(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

function touches(a, b) {
    const shareY = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y), shareX = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
    return ((a.x + a.w === b.x || b.x + b.w === a.x) && shareY > 0) || ((a.y + a.h === b.y || b.y + b.h === a.y) && shareX > 0);
}

// The place nearest to where `r` is at which it touches one of `placed` along an edge and covers none of them. Tried: each
// side of each placed rectangle, the free coordinate where `r` is (kept on the shared edge) or lined up with an edge of a
// placed one. One always fits (beside the outermost rectangle, lined up with it).
function nearestFree(r, placed) {
    let best = null, d = Infinity;
    const consider = (x, y) => {
        const c = {x: x, y: y, w: r.w, h: r.h};
        const di = Math.hypot(x - r.x, y - r.y);
        if (di < d && !placed.some(q => overlaps(c, q))) {
            d = di;
            best = {x: x, y: y};
        }
    };
    const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
    for (const p of placed) {
        const ys = [clamp(r.y, p.y - r.h + 1, p.y + p.h - 1)], xs = [clamp(r.x, p.x - r.w + 1, p.x + p.w - 1)];
        for (const q of placed) {
            for (const y of [q.y, q.y + q.h, q.y - r.h, q.y + q.h - r.h]) {
                if (y >= p.y - r.h + 1 && y <= p.y + p.h - 1)
                    ys.push(y);
            }
            for (const x of [q.x, q.x + q.w, q.x - r.w, q.x + q.w - r.w]) {
                if (x >= p.x - r.w + 1 && x <= p.x + p.w - 1)
                    xs.push(x);
            }
        }
        for (const y of ys) {
            consider(p.x - r.w, y);
            consider(p.x + p.w, y);
        }
        for (const x of xs) {
            consider(x, p.y - r.h);
            consider(x, p.y + p.h);
        }
    }
    return best ?? {x: r.x, y: r.y};
}

// A layout that works: no display covers another and every display is reached from every other across shared edges (a
// display left apart cannot be reached by the pointer, and Hyprland refuses overlapping ones). `monitors` are placed monitors
// (x, y, and the mode, scale and rotation they will have); `anchor` names the display the user just placed or resized, which
// stays where it is. The others stay too when they can; one that is covered or cut off goes to the nearest place that
// touches the displays already settled, the nearest one first. Returns name -> {x, y} for every monitor.
function settle(monitors, anchor) {
    const rects = monitors.map(m => {
        const s = logicalSize(m);
        return {name: m.name, x: Math.round(m.x), y: Math.round(m.y), w: s.w, h: s.h};
    });
    const out = {};
    const placed = [];
    let rest = rects.slice();
    const take = (r, at) => {
        r.x = at.x;
        r.y = at.y;
        placed.push(r);
        out[r.name] = {x: r.x, y: r.y};
        rest = rest.filter(o => o !== r);
    };
    const first = rects.find(r => r.name === anchor) ?? rects[0];
    if (first)
        take(first, first);
    while (rest.length > 0) {
        // One that already fits where it is, or else the one nearest to a settled display, moved.
        const fits = rest.find(r => placed.some(q => touches(r, q)) && !placed.some(q => overlaps(r, q)));
        if (fits) {
            take(fits, fits);
            continue;
        }
        let next = null, at = null, d = Infinity;
        for (const r of rest) {
            const c = nearestFree(r, placed);
            const di = Math.hypot(c.x - r.x, c.y - r.y);
            if (di < d) {
                d = di;
                next = r;
                at = c;
            }
        }
        take(next, at);
    }
    return out;
}

// The layout after the display `name` takes `change` ({scale} or {transform}): its logical size changes, so the displays
// past its right or bottom edge follow that edge (they stay on the side they were), and settle() mends what is left. Without
// this a display with a kept position ends up under the resized one, or apart from it. Returns name -> {x, y}.
function resized(monitors, name, change) {
    const m = monitors.find(o => o.name === name);
    if (!m)
        return settle(monitors, name);
    const next = Object.assign({}, m, change);
    const before = logicalSize(m), after = logicalSize(next);
    return settle(monitors.map(o => o === m ? next : Object.assign({}, o, {
        x: o.x >= m.x + before.w ? o.x + after.w - before.w : o.x,
        y: o.y >= m.y + before.h ? o.y + after.h - before.h : o.y})), name);
}
