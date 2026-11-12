.pragma library

// Accent colour (`accent.color`, docs/specs/ui.md "Accent colour"). Pure functions, no I/O: the palettes come from the
// `color.accentDark` / `color.accentLight` token groups, passed in as `tokens` (the Tokens singleton or any object with the
// same fields), so tests can check setting -> colours without a scene.

// "multicolor" is the default, named "Grassfield" in Settings (ADR-0040 step 1c; the stored value keeps its name), and keeps
// the Grassfield green of the `accent` / `accentText` roles; the others have their own light and dark values (roles `<name>`
// and `<name>Text` of the token groups). Order = order of the swatches.
const NAMES = ["multicolor", "blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite"];

function validName(setting) {
    return typeof setting === "string" && NAMES.indexOf(setting) >= 0;
}

function normalize(setting) {
    return validName(setting) ? setting : "multicolor";
}

// {accent, accentText, accentInk} for a setting in the dark or the light appearance, or null when the palette's own roles
// apply (multicolor, or anything invalid: a hand-edited value reads as the default). accentInk: the colour of text and glyphs
// drawn in the accent colour (a link-like label, a checkmark, a sidebar glyph); the accent itself, or in the light appearance
// the darker shade a light accent has in `color.accentInkLight` (yellow, green: 4.5:1 on an app window; pink since the 2026-11-03 sidebar needs none, as macOS draws
// a light accent's text darker; the integrator's review of 5391761, ADR-0040 step 1c).
function resolve(setting, dark, tokens) {
    const name = normalize(setting);
    if (name === "multicolor")
        return null;
    const group = dark ? tokens.colorAccentDark : tokens.colorAccentLight;
    const ink = dark ? undefined : (tokens.colorAccentInkLight || {})[name];
    return {accent: group[name], accentText: group[name + "Text"], accentInk: ink || group[name]};
}

// Accent text on glass (`accentGlass`): the accent ink mixed toward the palette's text colour by `mix` (sRGB, rounded to a channel
// value), so that it holds 4.5:1 over the material's tint floor on every wallpaper (A2); macOS draws accent text on vibrancy with
// a legibility-adjusted accent, never the raw one. "#rrggbb"; the ink itself when a colour cannot be read.
function glassInk(ink, text, mix) {
    const a = rgb(ink);
    const b = rgb(text);
    if (!a || !b)
        return ink;
    const h = i => {
        const v = Math.round((a[i] + (b[i] - a[i]) * mix) * 255);
        return (v < 16 ? "0" : "") + v.toString(16);
    };
    return "#" + h(0) + h(1) + h(2);
}

// A copy of palette `base` with the accent applied (`accentInk` the palette's own accent for the default; `accentGlass` its
// legibility-adjusted variant for text on glass). The highlight colour (text selection, Automatic) is the accent.
function apply(base, setting, dark, tokens) {
    const c = Object.assign({}, base);
    const a = resolve(setting, dark, tokens);
    if (a) {
        c.accent = a.accent;
        c.accentText = a.accentText;
        c.accentInk = a.accentInk;
    } else {
        c.accentInk = c.accent;
    }
    c.accentGlass = glassInk(c.accentInk, c.text, dark ? tokens.glassAccentInkMixDark : tokens.glassAccentInkMixLight);
    return c;
}

// Text highlight colour (`accent.highlight`, macOS 27 Appearance > Text highlight colour): the fill of selected text in fields
// and editors and the text on it. "automatic" follows the accent (`palette`, with the accent applied); a name uses that accent
// colour and its text colour in this appearance, whatever the accent is; anything else reads as "automatic".
const HIGHLIGHTS = ["automatic", "blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite"];

function normalizeHighlight(setting) {
    return typeof setting === "string" && HIGHLIGHTS.indexOf(setting) >= 0 ? setting : "automatic";
}

function highlight(setting, dark, palette, tokens) {
    const name = normalizeHighlight(setting);
    if (name === "automatic")
        return {highlight: palette.accent, highlightText: palette.accentText};
    const group = dark ? tokens.colorAccentDark : tokens.colorAccentLight;
    return {highlight: group[name], highlightText: group[name + "Text"]};
}

// Selection: macOS draws white text on its accent fill in both appearances (a selected row, a default button, a checked box).
// The dark palette's accent is bright for glyphs, rings and indicators and holds 4.5:1 only with dark text, so a fill that
// carries text or a mark has its own pair (ADR-0024 section 1): the light appearance's accent and text colour in the light
// appearance; in the dark one a lighter shade of it that keeps white at 4.85:1 or more (`color.selectionDark`: the
// Grassfield green #2E8049, the owner's pick of 2026-10-26, and one shade per accent; yellow and green, light accents with
// dark text, keep their light pair). `light` is the light palette with the same accent applied.
function selectionPair(setting, dark, light, tokens) {
    if (!dark)
        return {selection: light.accent, selectionText: light.accentText};
    const name = normalize(setting);
    return {selection: tokens.colorSelectionDark[name], selectionText: tokens.colorSelectionDark[name + "Text"]};
}

function withSelection(palette, pair) {
    const c = Object.assign({}, palette);
    c.selection = pair.selection;
    c.selectionText = pair.selectionText;
    return c;
}

// ---- Focus ring colour and Increase Contrast ----

// Channels (0..1) of a "#rrggbb" or "#aarrggbb" string, or of a QML colour value (a `color` property or function result is
// an object with r, g and b, not a string); null for anything else.
function rgb(hex) {
    if (hex !== null && typeof hex === "object" && typeof hex.r === "number" && typeof hex.g === "number" && typeof hex.b === "number")
        return [hex.r, hex.g, hex.b];
    if (typeof hex !== "string" || !/^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(hex))
        return null;
    const h = hex.slice(-6);
    return [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255];
}

function luminance(c) {
    const f = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
}

// WCAG 2.x contrast ratio of two "#rrggbb" colours; 1 when either is not one.
function contrast(a, b) {
    const ca = rgb(a);
    const cb = rgb(b);
    if (!ca || !cb)
        return 1;
    const la = luminance(ca);
    const lb = luminance(cb);
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

// The keyboard focus ring colour (one ring for every surface): the accent when it holds `minContrast` against the surface
// tint, else the text colour (the light appearance's yellow and green accents are under 3:1 against its material; every other
// accent in both appearances passes), so the ring is a non-text element of 3:1 or more (WCAG 1.4.11) on every accent.
function focusRing(accent, tint, text, minContrast) {
    return contrast(accent, tint) >= minContrast ? accent : text;
}

// The white knob of a switch or a slider on its "on" fill, the selection colour (ADR-0039 step 11, D-Q4: switches, slider
// fills, check boxes and default buttons share one fill, as macOS 27 draws them): outlined in the fill's mark colour where
// white holds under `minContrast` there (the yellow and green fills, which keep dark marks: 2.02:1 and 2.52:1), so that its
// edge reaches it (the mark colour holds 4.5:1 or more against its own fill).
function knobOutlined(knob, fill, minContrast) {
    return contrast(knob, fill) < minContrast;
}

// Increase Contrast (macOS Accessibility > Display): the secondary text colour is the primary one; the borders, separators and
// fills are drawn stronger by the tokens that carry an `increaseContrast` value.
function contrastBoost(palette, on) {
    if (!on)
        return palette;
    const c = Object.assign({}, palette);
    c.textSecondary = c.text;
    return c;
}
