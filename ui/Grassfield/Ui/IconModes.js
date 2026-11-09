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
// its edge stands off a light material only as far as its own tones do. In the light appearance, while the material is solid (transparency up to
// `material.tintClampUntil`, tint opacity at least `tintAlphaClamp`), the pixels below `iconModeTileDarkenPivot` (0.62, about the darkest solid light material: the
// material tint over a black wallpaper, 0.63 at the default transparency, 0.57 at the clamp) are darkened by the power `iconModeTileDarkenExponent`, so no
// pixel moves towards the material. Side -1; 0 (nothing moves) in the dark appearance (it has the dark rim instead: a lift of the bright tones was tried and
// measured on the GPU to cost rule I and S cells), over the bare wallpaper (desktop icons: any luminance) and once the wallpaper shows through the light material.
function tileToneSide(dark, wallpaper, transparency, t) {
    if (wallpaper || dark)
        return 0;
    return transparency <= t.materialTintClampUntil ? -1 : 0;
}

// The tone of one linear value `v` (0..1): `side` as above, `pivot` and `exponent` the tokens.
function tileTone(v, side, pivot, exponent) {
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

// Dark rim (R7-REQ-13, A2 rule E; the arithmetic is shaders/icon.frag, DARK RIM). A tile icon in the dark appearance (Dark, Clear and Tinted) carries a thin light rim on its
// edge: within `width` device pixels inside the tile's edge (`distance` px, negative outside) the tile's colour is replaced by `strength` of the rim colour.
// Returns the weight of the rim (0..strength) at that distance; the inner tones (rules I, S, N) are never touched.
function darkRimWeight(distance, width, strength) {
    if (distance < -0.5)
        return 0;
    return Math.min(1, Math.max(0, width - distance + 0.5)) * strength;
}
