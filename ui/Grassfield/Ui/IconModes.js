.pragma library

// Icon appearance modes (ADR-0014 phase 1, docs/specs/ui.md "Icon appearance modes"). Pure functions, no I/O, so tests
// can check mode -> effect without a scene. The numbers of each mode are the `iconMode` token group; IconEffect.qml
// hands them to the shader (shaders/icon.frag), which does the per-pixel work.

const MODES = ["default", "dark", "clear", "tinted"];

// "accent" (follow the accent colour) or a six-digit hex colour.
const TINT_PATTERN = /^#[0-9a-fA-F]{6}$/;

function normalizeMode(mode) {
    return MODES.indexOf(mode) >= 0 ? mode : "default";
}

function validTint(setting) {
    return setting === "accent" || (typeof setting === "string" && TINT_PATTERN.test(setting));
}

// The tint colour for a settings value: the hex colour, else (for "accent" or anything invalid) `accent`.
function tintColor(setting, accent) {
    return typeof setting === "string" && TINT_PATTERN.test(setting) ? setting : accent;
}

// The effect of a mode: `enabled` false means the icon is drawn as is (no effect item exists, so no extra render
// pass); `index` is the shader's mode (1 dark, 2 clear, 3 tinted, 0 none); `tint` only matters to "tinted".
function effect(mode, tint) {
    const normalized = normalizeMode(mode);
    return {enabled: normalized !== "default", index: MODES.indexOf(normalized), tint: tint, mode: normalized};
}

// Tone of a tile icon (own-tile rule, R7-REQ-13, A2 rule E; the arithmetic is shaders/icon.frag, TILE TONE). A tile keeps the luminance of its pixels, so
// its edge stands off the material only as far as the icon's own tones do; a full-bleed tile of mid tones over a mid-grey material has none. The tone moves
// the pixels of a tile away from the material, on one side of a pivot, so no pixel moves towards it:
//   +1  the dark appearance: the pixels above `iconModeTileLiftPivot` (0.38, the brightest material of the dark appearance: the material tint at
//       `material.tintAlphaMin` over a white wallpaper) are lifted by the ease-out `iconModeTileLiftExponent` (> 1: v' = P + (1 - P) (1 - (1 - u)^q), u = (v - P) / (1 - P));
//   -1  the light appearance while the material is solid (transparency up to `material.tintClampUntil`, tint opacity at least `tintAlphaClamp`): the pixels
//       below `iconModeTileDarkenPivot` (0.62, the darkest material of the light appearance: the material tint at the clamp over a black wallpaper)
//       are darkened by `iconModeTileDarkenExponent` (> 1);
//    0  over the bare wallpaper (desktop icons: any luminance), and in the light appearance once the wallpaper shows through (its luminance is then
//       the wallpaper's, which may be below the pivot).
function tileToneSide(dark, wallpaper, transparency, t) {
    if (wallpaper)
        return 0;
    if (dark)
        return 1;
    return transparency <= t.materialTintClampUntil ? -1 : 0;
}

// The tone of one linear value `v` (0..1): `side` as above, `pivot` and `exponent` the tokens of that side.
function tileTone(v, side, pivot, exponent) {
    if (side > 0)
        return v <= pivot ? v : pivot + (1 - pivot) * (1 - Math.pow(1 - (v - pivot) / (1 - pivot), exponent));
    if (side < 0)
        return v >= pivot ? v : pivot * Math.pow(v / pivot, exponent);
    return v;
}

// One warning per process (an icon shader that cannot load fails for every icon).
let warned = false;
function warnOnce(message) {
    if (warned)
        return;
    warned = true;
    console.warn("grassfield-ui: " + message);
}
