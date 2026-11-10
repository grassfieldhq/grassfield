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

// Tone of a tile icon (own-tile rule, R7-REQ-13, A2 rule E; the arithmetic is shaders/icon.frag, TILE TONE; IconEffect applies it only to icons on a solid window
// material). A tile keeps the luminance of its pixels, so its edge stands off the material only as far as its own tones do. The tone moves the pixels away from the
// material, on one side of a pivot, so no pixel moves towards it:
//   +1  the dark appearance: the pixels above `iconModeTileLiftPivot` (0.38, the brightest material of the dark appearance: the material tint at `material.tintAlphaMin`
//       over a white wallpaper; `iconModeTileLiftPivotDark` 0.55 for Dark, whose rule I floor takes only a lift of its lightest tones) are lifted by an ease-out whose exponent `iconModeTileLiftExponent<Mode>` is chosen per mode;
//   -1  the light appearance while the material is solid (transparency up to `material.tintClampUntil`): the pixels below `iconModeTileDarkenPivot` (0.62, about the
//       darkest solid light material) are darkened by the power `iconModeTileDarkenExponent`;
//   +1  the light appearance once the wallpaper shows through (transparency above `material.tintClampUntil`): the material may be anything from a dark grey to white, so
//       only the brightest tones move: the pixels above `iconModeTileLightLiftPivot` (0.8) are lifted by `iconModeTileLightLiftExponent`; a pixel moves away from every
//       material darker than the pivot, and over a white wallpaper (0.9) only the tones between 0.8 and 0.9, already within 1.2:1 of it, can lose;
//    0  over the bare wallpaper (desktop icons: any luminance).
function tileToneSide(dark, wallpaper, transparency, t) {
    if (wallpaper)
        return 0;
    if (dark)
        return 1;
    return transparency <= t.materialTintClampUntil ? -1 : 1;
}

// Whether an icon is drawn with the "over the bare wallpaper" look (shaders/icon.frag, `wall`): for Clear that is the dark smoked plate with light ink, which holds its own
// luminance on any backdrop (a white wallpaper included); the other modes only force the dark styling. It is the case (1) of the desktop icons (`wallpaper`), (2) of Clear once
// the wallpaper shows through the material (transparency from `iconModeWallpaperLikeTransparency`), except over an accent fill, and (3) of Clear in the DARK appearance on
// a surface that is not a solid window material (the Dock, Launchpad, Search ...: an almost clear glass whose own tint cannot hold a light plate against a white wallpaper;
// the macOS model: Clear icons in the dark appearance are dark smoked glass with light glyphs). A glass plate that is white at 0.22 is for the solid dark window material.
function overWallpaperLook(modeIndex, wallpaper, transparency, dark, solidMaterial, accentFill, t) {
    if (wallpaper)
        return true;
    if (modeIndex !== 2 || accentFill >= 0.5)
        return false;
    return transparency >= t.iconModeWallpaperLikeTransparency || (dark && !solidMaterial);
}

// One warning per process (an icon shader that cannot load fails for every icon).
let warned = false;
function warnOnce(message) {
    if (warned)
        return;
    warned = true;
    console.warn("grassfield-ui: " + message);
}
