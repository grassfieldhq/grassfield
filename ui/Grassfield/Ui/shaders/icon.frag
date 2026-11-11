#version 440
// Icon appearance modes (ADR-0014): dark, clear and tinted renderings of an arbitrary theme icon.
// Build: scripts/dev/build-shaders.sh (qsb) -> icon.frag.qsb. Algorithm and limits: docs/specs/ui.md "Icon shader".
//
// One pass, no analysis of the icon (macOS gives every icon that is not made for the mode a system plate; so does this):
//  1. PLATE. Every icon sits on a system plate: a rounded square (squircle proportions) filling the box less an inset, graphite
//     in Dark, glass in Clear (light on a dark material, smoked on a light one or over the bare wallpaper), tinted in Tinted.
//  2. ARTWORK. The icon is drawn scaled down about the centre onto the plate, recoloured by a fixed transform per mode that
//     depends on the pixel alone (so FolderStyle.modeSamples can repeat it exactly):
//       Dark   a little desaturated, then an affine map in linear light from darkArtLift (black, so it separates from the graphite plate) to darkArtScale.
//       Clear  monochrome ink (light on dark, smoked on light) whose opacity follows the lightness of the artwork's luminance.
//       Tinted the lightness of the artwork's luminance mapped onto a two-tone ramp of the tint.
//     Every map is increasing and keeps a minimum slope, so the internal contrast of an icon survives (A2 "internal contrast").
//  TILES. An icon that is already a rounded square covers the plate, so nothing has to separate from it and the maps keep the luminance of
//     every pixel (a contrast ratio between two parts of the icon survives, so does the one against the background; A2 rules I, S, N, E):
//       Dark   no lift (tileDarkArtLift), the same desaturation.
//       Clear  neutral grey at the luminance of the pixel, opaque (a translucent ink would take the backdrop into the contrast).
//       Tinted the tint at the luminance of the pixel: darker than the tint scaled, lighter than the tint mixed toward white.
//  There is no rim, ring or halo (owner decisions 2026-10-23 and 2026-11-10): a mode only changes the colour; nothing is drawn around a tile.
//  TILE TONE. Over a solid window material a tile's tones are moved away from the material by a one-sided map, see below.
// The folder colour (FolderIcon) recolours the artwork only, after the mode transform: the plate stays.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 tint;              // tint colour (Tinted)
    float modeIndex;        // 1 dark, 2 clear, 3 tinted
    float dark;             // 1 in the dark appearance
    float sysPlateInset;    // system plate: inset from the icon box, in box fractions
    float sysPlateRadius;   // corner radius over the plate side
    float sysGlyphScale;    // scale of the artwork sitting on the plate
    float darkPlateLuma;
    float darkArtSaturation;
    float darkArtScale;
    float darkArtLift;
    float tile;               // 1: the icon is its own rounded-square tile (own-tile rule): luminance-preserving maps, see below
    float tileDarkArtLift;
    float tileTintedPlateScaleLight;
    float tileClearPlateAlphaLight;
    float tileClearPlateLightLuma;
    float clearPlateWallpaperLuma;
    float clearPlateLightLuma;
    float clearPlateAlphaDark;
    float clearPlateAlphaWallpaper;
    float overWallpaper;      // 1: drawn over the bare wallpaper (desktop), not over a window material
    float clearPlateAlphaLight;
    float clearInkDark;
    float clearInkLight;
    float clearBackdropDark;
    float clearBackdropLight;
    float clearBackdropMid;
    float clearInkFloor;
    float clearPlateAlphaAccent;
    float accentFill;         // 0: none; 1: over a bright accent fill (selected row), 2: over a dark one
    float tintedPlateScale;
    float tintedPlateMixLight;
    float tintedRampLowDark;
    float tintedRampHighDark;
    float tintedRampLowLight;
    float tintedRampHighLight;
    float tileToneSide;       // tile icon tone, see TILE TONE below: +1 lift the pixels above tileTonePivot, -1 darken those below it, 0 none
    float tileTonePivot;      // linear value the tone leaves alone
    float tileToneExp;        // exponent of the tone: an ease-out lift above the pivot, a power darkening below it (both > 1; 1 = none)
    float bandLiftPivot;      // plain (not own-tile) artwork on a dark Dock glass (IconModes.deepPlate): the tones above this linear value are lifted, see BAND LIFT
    float bandLiftExp;        // exponent of that lift (1 = none)
    float darkPlateLumaOnDarkAccent;  // Dark over a dark accent fill of a selected row: lightness of the plate
    vec4 folderTint;          // folder colour step (FolderIcon): a = 1 when the artwork is recoloured, 0 otherwise
    float folderBrightness;   // MultiEffect arithmetic of the folder colour (FolderEffect, tokens folderIcon*)
    float folderContrast;
    float folderColorization;
    float folderSaturation;
};

layout(binding = 1) uniform sampler2D iconTexture;

// Lightness of a colour: its relative luminance (linear light, gamma 2.2) encoded again. A pure red is 0.5 (its luminance is 0.21), not
// the 0.21 of a weighted sum of coded values: two colours that differ in luminance keep their difference in every mode.
float lightness(vec3 c) {
    return pow(dot(pow(c, vec3(2.2)), vec3(0.2126, 0.7152, 0.0722)), 1.0 / 2.2);
}

// Linear-light maps (gamma 2.2): the output luminance is an affine function of the input's, so a ratio of two luminances survives
// as well as a floor allows (black art mapped to a floor lo against white mapped to hi: (hi + 0.05) / (lo + 0.05) at most).
vec3 toLinear(vec3 c) {
    return pow(c, vec3(2.2));
}

vec3 fromLinear(vec3 c) {
    return pow(max(c, vec3(0.0)), vec3(1.0 / 2.2));
}

// The exact sRGB transfer, for the maps of tile icons: a map that keeps the relative luminance must keep the one the A2 rules and WCAG measure
// (a gamma of 2.2 differs from it by a few percent in the darks and in saturated colours, enough to cost a contrast ratio at the margin).
vec3 srgbToLinear(vec3 c) {
    return mix(c / 12.92, pow((c + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 linearToSrgb(vec3 c) {
    c = max(c, vec3(0.0));
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - vec3(0.055), step(vec3(0.0031308), c));
}

void main() {
    bool wall = overWallpaper > 0.5;
    bool accent = accentFill > 0.5;
    bool accentBright = accentFill < 1.5;
    bool isDark = dark > 0.5 || wall;

    // The artwork: the icon texture scaled about the centre by sysGlyphScale. Straight (non-premultiplied) colour.
    vec2 uv = vec2(0.5) + (qt_TexCoord0 - vec2(0.5)) / sysGlyphScale;
    bool inBox = uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0;
    vec4 px = texture(iconTexture, clamp(uv, vec2(0.0), vec2(1.0))) * (inBox ? 1.0 : 0.0);
    float a = px.a;
    vec3 c = px.rgb / max(a, 0.0001);
    bool isTile = tile > 0.5;
    vec3 lin = isTile ? srgbToLinear(c) : toLinear(c);
    // TILE TONE (R7-REQ-13, A2 rule E). A tile keeps the luminance of its pixels, so over a solid window material its edge is no better than Default's, and scaling a
    // full-bleed tile onto the plate moves the measured edge onto other art. The tone pushes the pixels AWAY from the material, on one side of a pivot only, so no
    // pixel moves towards it; IconEffect chooses the side (IconModes.tileToneSide, the pure rule that tst_iconmodes checks) and only for icons declared on a solid
    // window material (TintedIcon.solidMaterial: never the Dock, Launchpad or other glass, whose backdrop the pivots do not describe):
    //   +1 dark appearance: the pixels above the brightest dark material (pivot 0.38 in linear light) are lifted, v' = P + (1 - P) (1 - (1 - u)^e), u = (v - P) / (1 - P),
    //      e > 1 (an ease-out: continuous, finite slope; a lift compresses pairs of bright tones, so e stays small, and Dark's pivot is higher, 0.55, so that only its lightest tones move);
    //   -1 light appearance, material solid: the pixels below the darkest material (pivot 0.62) are darkened, v' = P (v / P)^e with e > 1;
    //   +1 light appearance, the wallpaper showing through (any material from dark grey to white): only the brightest tones, above pivot 0.8, are lifted.
    // Per channel (the hue is kept), the same arithmetic for every mode, only the exponent differs.
    if (isTile && tileToneSide > 0.5) {
        vec3 u = clamp((lin - vec3(tileTonePivot)) / (1.0 - tileTonePivot), vec3(0.0), vec3(1.0));
        vec3 up = vec3(tileTonePivot) + (1.0 - tileTonePivot) * (vec3(1.0) - pow(vec3(1.0) - u, vec3(tileToneExp)));
        lin = mix(lin, up, step(vec3(tileTonePivot), lin));
    } else if (isTile && tileToneSide < -0.5) {
        vec3 down = vec3(tileTonePivot) * pow(min(lin / tileTonePivot, vec3(1.0)), vec3(tileToneExp));
        lin = mix(down, lin, step(vec3(tileTonePivot), lin));
    } else if (!isTile && bandLiftExp > 1.0001) {
        // BAND LIFT (R7-REQ-13, A2 rule E, GPU 2026-11-11): on a dark glass the black plate is at its ceiling (about 2.9:1 against a 0.10 surface), so the glyph carries rule E; its bright
        // tones are lifted by the same one-sided ease-out as the tile tone (nothing below the pivot moves; pairs of tones both above it compress), the exponent following the deep
        // plate weight (IconEffect). Measured on the GPU (2026-11-11): rule N fell in 83 band cells (system-run Dark 2.20 to 1.88) and rule I by up to 0.75 (help-browser Tinted,
        // light, 9.91 to 9.16); all still pass.
        vec3 u = clamp((lin - vec3(bandLiftPivot)) / (1.0 - bandLiftPivot), vec3(0.0), vec3(1.0));
        vec3 up = vec3(bandLiftPivot) + (1.0 - bandLiftPivot) * (vec3(1.0) - pow(vec3(1.0) - u, vec3(bandLiftExp)));
        lin = mix(lin, up, step(vec3(bandLiftPivot), lin));
    }
    float Y = dot(lin, vec3(0.2126, 0.7152, 0.0722));   // relative luminance of the artwork pixel

    // Per-mode transform of the artwork: rgb (straight) and the opacity it is drawn with.
    vec3 art;
    float artA = a;
    if (modeIndex < 1.5) {
        // Affine from darkArtLift (black) to darkArtScale (white): monotonic, a minimum slope, black stays darker than light art.
        vec3 d = mix(vec3(Y), lin, darkArtSaturation);
        if (isTile) {
            vec3 lo = srgbToLinear(vec3(tileDarkArtLift));
            art = linearToSrgb(lo + (srgbToLinear(vec3(darkArtScale)) - lo) * d);
        } else {
            vec3 lo = toLinear(vec3(darkArtLift));
            art = fromLinear(lo + (toLinear(vec3(darkArtScale)) - lo) * d);
        }
    } else if (modeIndex < 2.5 && isTile) {
        art = linearToSrgb(vec3(Y));
    } else if (modeIndex < 2.5) {
        // Over an accent fill the ink is the opposite of the fill (light on a bright accent, dark on a dark one).
        bool lightInk = accent ? accentBright : isDark;
        float ink = lightInk ? clearInkDark : clearInkLight;
        art = vec3(ink);
        // The ink opacity is solved so that the colour on screen is affine in linear light between the glass (black art) and the ink
        // (white art), the glass being the plate over an assumed material: the contrast between two parts of the artwork survives.
        float pa = accent ? clearPlateAlphaAccent : (wall ? clearPlateAlphaWallpaper : (isDark ? clearPlateAlphaDark : clearPlateAlphaLight));
        float pg = accent ? (accentBright ? 0.0 : 1.0) : ((isDark && !wall) ? 1.0 : (wall ? clearPlateWallpaperLuma : clearPlateLightLuma));
        float bd = (accent || wall) ? clearBackdropMid : (isDark ? clearBackdropDark : clearBackdropLight);
        float under = pg * pa + (1.0 - pa) * bd;
        float yEff = clearInkFloor + (1.0 - clearInkFloor) * (lightInk ? Y : 1.0 - Y);
        float target = mix(pow(under, 2.2), pow(ink, 2.2), yEff);
        artA = a * clamp((pow(target, 1.0 / 2.2) - under) / (ink - under), 0.0, 1.0);
    } else if (isTile) {
        // The tint at the luminance Y: scaled down below the luminance of the tint, mixed toward white above it.
        vec3 tl = srgbToLinear(tint.rgb);
        float Yt = max(dot(tl, vec3(0.2126, 0.7152, 0.0722)), 0.0001);
        art = Y <= Yt ? linearToSrgb(tl * (Y / Yt)) : linearToSrgb(mix(tl, vec3(1.0), (Y - Yt) / max(1.0 - Yt, 0.0001)));
    } else {
        vec3 t = tint.rgb;
        vec3 lo = isDark ? t * tintedRampLowDark : t * tintedRampLowLight;
        vec3 hi = isDark ? mix(t, vec3(1.0), tintedRampHighDark) : mix(t, vec3(1.0), tintedRampHighLight);
        art = fromLinear(mix(toLinear(lo), toLinear(hi), Y));
    }
    art = clamp(art, 0.0, 1.0);
    if (folderTint.a > 0.5) {
        // The folder colour maps the luminance of the artwork onto the colour (the arithmetic of Qt's MultiEffect, which
        // FolderEffect uses as a layer over the plain icon in default mode). Only the artwork is recoloured.
        vec3 cc = (art - vec3(0.5)) * (1.0 + folderContrast) + vec3(0.5 + folderBrightness);
        float gray = dot(cc, vec3(0.299, 0.587, 0.114));
        vec3 rc = vec3(gray) + (folderTint.rgb * gray * folderColorization + cc * (1.0 - folderColorization) - vec3(gray)) * (1.0 + folderSaturation);
        art = clamp(rc, 0.0, 1.0);
    }
    vec4 artP = vec4(art * artA, artA);

    // The system plate: a rounded square.
    float hs = 0.5 - sysPlateInset;
    float rad = sysPlateRadius * 2.0 * hs;
    vec2 q = abs(qt_TexCoord0 - vec2(0.5)) - vec2(hs - rad);
    float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
    float aa = max(fwidth(sdf), 0.0005);
    float mask = 1.0 - smoothstep(-aa, aa, sdf);
    vec3 plateRgb;
    float plateA;
    if (modeIndex < 1.5) {
        plateRgb = vec3(accent && !accentBright ? darkPlateLumaOnDarkAccent : darkPlateLuma);
        plateA = 1.0;
    } else if (modeIndex < 2.5) {
        // Light glass on a dark material; smoked glass on a light one, and over the bare wallpaper (any brightness).
        plateRgb = accent ? vec3(accentBright ? 0.0 : 1.0) : ((isDark && !wall) ? vec3(1.0) : vec3(wall ? clearPlateWallpaperLuma : clearPlateLightLuma));
        plateA = accent ? clearPlateAlphaAccent : (wall ? clearPlateAlphaWallpaper : (isDark ? clearPlateAlphaDark : clearPlateAlphaLight));
        if (isTile && !isDark && !accent) {
            // Under a tile the plate shows only in the antialiased fringe of its edge: dark in the light appearance, so that the edge keeps its contrast against a light material.
            plateRgb = vec3(tileClearPlateLightLuma);
            plateA = tileClearPlateAlphaLight;
        }
    } else {
        vec3 t = tint.rgb;
        plateRgb = isDark ? t * tintedPlateScale : (isTile ? t * tileTintedPlateScaleLight : mix(t, vec3(1.0), tintedPlateMixLight));
        plateA = 1.0;
    }
    vec4 plateP = vec4(plateRgb * plateA, plateA);
    plateP *= mask;
    vec4 face = artP + plateP * (1.0 - artP.a);
    fragColor = face * qt_Opacity;
}
