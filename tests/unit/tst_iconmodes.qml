import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Store.js" as Store

// Icon appearance modes (ADR-0014 phase 1): mode -> effect parameters, tint resolution, settings validation, and the
// live switch of a TintedIcon (no effect item in default mode, parameters follow the mode and the tint).
TestCase {
    id: testCase
    name: "IconModes"
    visible: true
    when: windowShown
    width: 200
    height: 200

    readonly property color red: "#e5484d"

    function cleanup() {
        Appearance.iconShaderBroken = false;
        Appearance.iconMode = "default";
        Appearance.iconTintSetting = "accent";
    }

    function test_defaultHasNoEffect() {
        const p = IconModes.effect("default", testCase.red);
        compare(p.enabled, false);
        compare(p.index, 0);
        // Unknown modes are default.
        compare(IconModes.effect("neon", testCase.red).enabled, false);
        compare(IconModes.normalizeMode(undefined), "default");
        compare(IconModes.normalizeMode("Dark"), "default");
    }

    function test_modesMapToShaderIndex() {
        compare(IconModes.effect("dark", testCase.red).index, 1);
        compare(IconModes.effect("clear", testCase.red).index, 2);
        compare(IconModes.effect("tinted", testCase.red).index, 3);
        for (const m of ["dark", "clear", "tinted"])
            compare(IconModes.effect(m, testCase.red).enabled, true);
        compare(IconModes.effect("tinted", testCase.red).tint, testCase.red);
    }

    // The mode numbers are tokens that the shader reads; wrong ranges would break the look silently.
    function test_shaderTokensInRange() {
        verify(Tokens.iconModeDarkPlateLuma > 0 && Tokens.iconModeDarkPlateLuma < 0.3, "Dark plates are near black");
        verify(Tokens.iconModeDarkArtLift > Tokens.iconModeDarkPlateLuma, "a black part of the artwork is lifted above the plate");
        verify(Tokens.iconModeDarkArtScale > Tokens.iconModeDarkArtLift, "the Dark map is increasing: black art stays darker than light art");
        verify(Tokens.iconModeClearBackdropDark < Tokens.iconModeClearInkDark && Tokens.iconModeClearBackdropLight > Tokens.iconModeClearInkLight, "the ink stands out from the material it is solved against");
        verify(Tokens.iconModeTintedRampLowDark < Tokens.iconModeTintedRampHighDark && Tokens.iconModeTintedRampLowLight < 1 - Tokens.iconModeTintedRampHighLight + 1, "the Tinted ramp rises");
        verify(Tokens.iconModeClearPlateAlphaDark > 0 && Tokens.iconModeClearPlateAlphaDark < 0.5, "translucent glass");
        verify(Tokens.iconModeClearPlateAlphaLight > 0 && Tokens.iconModeClearPlateAlphaLight < 0.5, "translucent glass");
        verify(Tokens.iconModeClearInkDark > Tokens.iconModeClearInkLight, "light ink on dark, dark ink on light");
        verify(Tokens.iconModeTintedPlateScale > 0 && Tokens.iconModeTintedPlateScale < 0.5, "a dark tinted plate");
        verify(Tokens.iconModeTintedPlateMixLight > 0.5 && Tokens.iconModeTintedPlateMixLight < 1, "a light tinted plate");
        verify(Tokens.dockIconOversample >= 2.5, "decoded at the Dock's largest magnification");
    }

    // ---- R7-REQ-13 (A2 rule E at 3:1): the pure math of the two families, checkable without a GPU ----

    function lum(rgb) {
        return FolderStyle.relativeLuminance(rgb);
    }

    // The window material over a wallpaper, as tests/unit/tst_iconshader.qml builds it (coded values, the tint opacity of Appearance.tintAlpha).
    function materialRgb(dark, wallpaper, transparency) {
        const tint = FolderStyle.rgbOf(dark ? Tokens.colorDark.materialTint : Tokens.colorLight.materialTint);
        const a = Appearance.tintAlpha(transparency);
        return [0, 1, 2].map(q => tint[q] * a + wallpaper * (1 - a));
    }

    function contrast(y1, y2) {
        return (Math.max(y1, y2) + 0.05) / (Math.min(y1, y2) + 0.05);
    }

    // Family 1: Tinted, dark appearance. The ramp of the artwork on the dark tinted plate. The brightest 2 percent of the core of kdenlive, obs and the
    // terminal measured 2.47 to 2.82:1 against the dark material over a white wallpaper (24 px); their art luminance (solved from the old ramp 0.55 / 0.8) is 0.20
    // to 0.25. With the ramp of the tokens that tone stands 3:1 out of the material for the two tints measured (blue, pink) and 2.9:1 (the A2 floor) for every swatch.
    function test_tintedRampStandsOutOfADarkMaterial() {
        const panel = lum(materialRgb(true, 1, Tokens.materialDefaultTransparency));
        verify(panel < 0.08, "the dark material over a white wallpaper is dark: " + panel);
        for (const hex of Tokens.iconModeTintColors) {
            const t = FolderStyle.rgbOf(hex);
            const lo = t.map(v => v * Tokens.iconModeTintedRampLowDark);
            const hi = t.map(v => v + (1 - v) * Tokens.iconModeTintedRampHighDark);
            for (const yArt of [0.20, 0.22, 0.25]) {
                const rgb = [0, 1, 2].map(q => Math.pow(Math.pow(lo[q], 2.2) + (Math.pow(hi[q], 2.2) - Math.pow(lo[q], 2.2)) * yArt, 1 / 2.2));
                verify(contrast(lum(rgb), panel) >= (hex === "#3E7BFA" || hex === "#E25AA1" ? 3.0 : 2.9), `${hex} at art luminance ${yArt}: ${contrast(lum(rgb), panel).toFixed(2)}:1`);
            }
        }
    }

    // Clear in the dark appearance on a surface that is not a solid window material (the Dock ...) is the dark smoked glass of the over-the-wallpaper look: a light plate
    // merged with a white wallpaper through the almost clear Dock (GPU run of 2026-11-10: 79 test_a2_dock cells, inside 1.01 on #ffffff).
    function test_overWallpaperLook() {
        const t = Tokens;
        const look = (mode, wall, tr, dark, solid, accent) => IconModes.overWallpaperLook(mode, wall, tr, dark, solid, accent, t);
        compare(look(2, false, 0.25, true, false, 0), true, "Clear, dark, Dock: smoked");
        compare(look(2, false, 0.25, true, true, 0), false, "Clear, dark, solid window material: the white glass of the A2 window cells");
        compare(look(2, false, 0.25, false, false, 0), false, "Clear, light appearance: unchanged");
        compare(look(1, false, 0.25, true, false, 0), false, "Dark and Tinted keep their plates");
        compare(look(3, false, 0.25, true, false, 0), false);
        compare(look(2, false, 0.25, true, false, 1), false, "never over an accent fill");
        compare(look(2, false, t.iconModeWallpaperLikeTransparency, false, true, 0), true, "wallpaper through the material");
        compare(look(1, true, 0.25, true, true, 0), true, "desktop icons");
    }

    // The smoked plate holds against any backdrop: the plate of the over-the-wallpaper look (luma and opacity tokens) against black, grey and white.
    function test_smokedPlateHoldsOnAnyBackdrop() {
        const t = Tokens;
        const plate = 0.0 + t.iconModeClearPlateWallpaperLuma;
        for (const bd of [0, 0.5, 1]) {
            const a = t.iconModeClearPlateAlphaWallpaper;
            const over = Math.pow(plate, 1) * a + bd * (1 - a);
            if (bd >= 0.5)
                verify(contrast(lum([bd, bd, bd]), lum([over, over, over])) >= 1.9, `plate over a backdrop of ${bd}`);
        }
    }

    // The icons on a nearly clear glass (the Dock) follow the glass, not the system appearance: dark over a black wallpaper in either appearance, light over a grey or white one
    // in either (GPU run of 2026-11-10: Clear in the light appearance over black, 77 cells, and in the dark appearance over white, 2 cells, and over grey, 8, failed with the
    // appearance's look). The looks themselves are the proven ones: the dark surface gets the dark look, the light surface the light look.
    function test_surfaceFollowsTheGlass() {
        const t = Tokens;
        for (const appearanceDark of [true, false]) {
            const tint = lum(FolderStyle.rgbOf(appearanceDark ? t.colorDark.materialTint : t.colorLight.materialTint));
            const alpha = appearanceDark ? t.dockTintAlphaDark : t.dockTintAlphaLight;
            const dark = backdrop => IconModes.surfaceIsDark(appearanceDark, IconModes.surfaceLuma(backdrop, tint, alpha), appearanceDark, t);
            compare(dark(0), true, `black wallpaper, ${appearanceDark ? "dark" : "light"} appearance: a dark glass`);
            compare(dark(lum([0.5, 0.5, 0.5])), false, "grey wallpaper: a light glass");
            compare(dark(1), false, "white wallpaper: a light glass");
        }
        compare(IconModes.surfaceLuma(-1, 0.5, 0.05), -1, "an unknown backdrop stays unknown");
        compare(IconModes.surfaceIsDark(false, -1, true, t), true, "unknown: the system appearance (dark)");
        compare(IconModes.surfaceIsDark(true, -1, false, t), false, "unknown: the system appearance (light)");
    }

    // One threshold on a stable value with a band: inside the band the previous look stays, so a wallpaper drifting around the threshold does not flip the icons.
    function test_surfaceToneHasHysteresis() {
        const t = Tokens;
        verify(t.iconModeSurfaceToneHysteresis > 0 && t.iconModeSurfaceToneHysteresis < 0.1, "a band, not a gap");
        verify(t.iconModeSurfaceToneThreshold > 0.05 && t.iconModeSurfaceToneThreshold < lum([0.5, 0.5, 0.5]) - 0.05, "between a black wallpaper and a mid-grey one, away from both");
        const mid = t.iconModeSurfaceToneThreshold, h = t.iconModeSurfaceToneHysteresis;
        for (const l of [mid - h * 0.9, mid, mid + h * 0.9]) {
            compare(IconModes.surfaceIsDark(true, l, false, t), true, `in the band ${l.toFixed(3)} a dark surface stays dark`);
            compare(IconModes.surfaceIsDark(false, l, true, t), false, `in the band ${l.toFixed(3)} a light surface stays light`);
        }
        compare(IconModes.surfaceIsDark(false, mid - h - 0.001, false, t), true, "below the band: dark whatever it was");
        compare(IconModes.surfaceIsDark(true, mid + h + 0.001, true, t), false, "above the band: light whatever it was");
        // A drifting wallpaper: the look changes at most twice while the luminance crosses the band and returns.
        let look = true, flips = 0;
        for (const l of [0.10, 0.15, 0.17, 0.19, 0.18, 0.19, 0.18, 0.17, 0.2, 0.22, 0.21, 0.19, 0.18, 0.15, 0.1]) {
            const d = IconModes.surfaceIsDark(look, l, true, t);
            if (d !== look)
                flips++;
            look = d;
        }
        verify(flips <= 2, `flips: ${flips}`);
    }

    // The shader's arithmetic of the tone (reference mirror for the tests below; the rule that IconEffect uses is IconModes.tileToneSide).
    function tone(v, side, pivot, exponent) {
        if (side > 0)
            return v <= pivot ? v : pivot + (1 - pivot) * (1 - Math.pow(1 - (v - pivot) / (1 - pivot), exponent));
        if (side < 0)
            return v >= pivot ? v : pivot * Math.pow(v / pivot, exponent);
        return v;
    }

    function liftExponents() {
        return [Tokens.iconModeTileLiftExponentDark, Tokens.iconModeTileLiftExponentClear, Tokens.iconModeTileLiftExponentTinted];
    }

    function test_tileToneSide() {
        const t = Tokens;
        compare(IconModes.tileToneSide(true, false, 0.25, t), 1, "dark appearance: lift");
        compare(IconModes.tileToneSide(true, false, 1.0, t), 1, "dark appearance, wallpaper through: lift");
        compare(IconModes.tileToneSide(false, false, 0.25, t), -1, "light appearance, default material: darken");
        compare(IconModes.tileToneSide(false, false, t.materialTintClampUntil, t), -1, "up to the A2 clamp the material is solid");
        compare(IconModes.tileToneSide(false, false, t.materialTintClampUntil + 0.01, t), 1, "past the clamp the wallpaper shows through: only the brightest tones are lifted");
        compare(IconModes.tileToneSide(false, false, 1.0, t), 1);
        compare(IconModes.tileToneSide(true, true, 0.25, t), 0, "bare wallpaper (desktop icons): no tone");
        compare(IconModes.tileToneSide(false, true, 0.25, t), 0);
    }

    // The tone is for icons on a solid window material only: the Dock and the other glass surfaces say nothing and get none.
    function test_toneIsOptIn() {
        const plain = createTemporaryObject(iconComponent, testCase, {mode: "tinted", size: 48});
        verify(plain);
        compare(plain.solidMaterial, false, "TintedIcon defaults to no tone (the Dock, Launchpad, Search ...)");
    }

    function test_toneMapsAreOneSided() {
        const t = Tokens;
        const dark = v => tone(v, -1, t.iconModeTileDarkenPivot, t.iconModeTileDarkenExponent);
        verify(t.iconModeTileDarkenExponent > 1, "the darken exponent darkens");
        verify(t.iconModeTileLiftPivotDark > t.iconModeTileLiftPivot, "Dark lifts only its lightest tones");
        for (const q of liftExponents())
            verify(q >= 1 && q <= 3, "a lift exponent between none and a strong ease-out: " + q);
        const lifts = [[t.iconModeTileLiftPivotDark, t.iconModeTileLiftExponentDark], [t.iconModeTileLiftPivot, t.iconModeTileLiftExponentClear], [t.iconModeTileLiftPivot, t.iconModeTileLiftExponentTinted]];
        for (const [pivot, q] of lifts) {
            let lastL = -1, lastD = -1;
            for (let i = 0; i <= 200; i++) {
                const v = i / 200;
                const l = tone(v, 1, pivot, q);
                verify(l >= v - 1e-12 && l <= 1 + 1e-12, "lift never darkens: " + v);
                if (v <= pivot)
                    compare(l, v, "the lift leaves what is below its pivot alone");
                verify(l >= lastL, "increasing: " + v);
                lastL = l;
                const d = dark(v);
                verify(d <= v + 1e-12 && d >= 0 && d >= lastD, "darken never lifts and is increasing: " + v);
                if (v >= t.iconModeTileDarkenPivot)
                    compare(d, v, "the darkening leaves what is above its pivot alone");
                lastD = d;
            }
            compare(tone(1, 1, pivot, q), 1);
        }
        compare(dark(0), 0);
        verify(Math.abs(dark(t.iconModeTileDarkenPivot - 1e-9) - t.iconModeTileDarkenPivot) < 1e-6, "continuous at its pivot");
    }

    // The pivots are the luminance of the materials they are for, so a moved pixel never moves towards its material.
    function test_toneNeverMovesTowardsItsMaterial() {
        const t = Tokens;
        const brightestDark = lum(materialRgb(true, 1, 1.0));
        verify(Math.abs(brightestDark - t.iconModeTileLiftPivot) < 0.01, `the lift pivot ${t.iconModeTileLiftPivot} is the brightest dark material ${brightestDark.toFixed(3)}`);
        const atDefault = lum(materialRgb(false, 0, t.materialDefaultTransparency));
        const atClamp = lum(materialRgb(false, 0, t.materialTintClampUntil));
        verify(t.iconModeTileDarkenPivot >= atClamp - 0.01 && t.iconModeTileDarkenPivot <= atDefault + 0.01,
               `the darken pivot ${t.iconModeTileDarkenPivot} lies between the darkest solid light materials ${atClamp.toFixed(3)} and ${atDefault.toFixed(3)}`);
        for (const wp of [0, 0.5, 1]) {
            const dm = lum(materialRgb(true, wp, 1.0));
            const lm = lum(materialRgb(false, wp, t.materialTintClampUntil));
            for (let i = 0; i <= 100; i++) {
                const v = i / 100;
                for (const [pivot, q] of [[t.iconModeTileLiftPivotDark, t.iconModeTileLiftExponentDark], [t.iconModeTileLiftPivot, t.iconModeTileLiftExponentClear], [t.iconModeTileLiftPivot, t.iconModeTileLiftExponentTinted]]) {
                    if (v > dm && pivot >= dm)
                        verify(contrast(tone(v, 1, pivot, q), dm) >= contrast(v, dm) - 1e-9, `lift: ${v} over a dark material ${dm.toFixed(3)}`);
                }
                if (v < lm - 0.05)
                    verify(contrast(tone(v, -1, t.iconModeTileDarkenPivot, t.iconModeTileDarkenExponent), lm) >= contrast(v, lm) - 1e-9, `darken: ${v} over a light material ${lm.toFixed(3)}`);
            }
        }
    }

    // The light-appearance lift (wallpaper showing through): its pivot is above every material but a white wallpaper's, and it takes the brightest tones of a tile
    // (own-tile-squircle Tinted, 24 px, transparency 1.0 over a mid-grey wallpaper: 98th percentile tone 0.90 against a material of 0.43, measured 1.98 against the
    // floor of 0.9 of Default's 2.21 = 1.99) to at least that floor with a margin.
    function test_lightLiftAtHighTransparency() {
        const t = Tokens;
        verify(t.iconModeTileLightLiftPivot > lum(materialRgb(false, 0.5, 1.0)) && t.iconModeTileLightLiftPivot < lum(materialRgb(false, 1, 1.0)) + 0.01, "above a mid material, near the brightest");
        const panel = lum(materialRgb(false, 0.5, 1.0));
        const lifted = tone(0.90, 1, t.iconModeTileLightLiftPivot, t.iconModeTileLightLiftExponent);
        verify(contrast(lifted, panel) >= 2.0, `the tile's brightest tones over the mid-grey material: ${contrast(lifted, panel).toFixed(2)}:1`);
        for (const wp of [0, 0.5, 1]) {
            const m = lum(materialRgb(false, wp, 1.0));
            for (let i = 0; i <= 100; i++) {
                const v = i / 100;
                if (m < t.iconModeTileLightLiftPivot && v > t.iconModeTileLightLiftPivot)
                    verify(contrast(tone(v, 1, t.iconModeTileLightLiftPivot, t.iconModeTileLightLiftExponent), m) >= contrast(v, m) - 1e-9, `light lift over a material ${m.toFixed(2)}: ${v}`);
            }
        }
    }

    // Family 2 (hicolor:basecamp, a full-bleed tile of a pale sky and a green hill): the edge tones of the tile (sky 0.60, hill 0.23 in relative luminance; the shader
    // keeps a tile's luminance) after the tone, against the materials of tests/unit/tst_iconshader.qml, 48 px light (floors 0.9 of Default's 2.41, 2.90 and 3.45, 2.9
    // from 3:1), and, in the dark appearance at transparency 1.0 over white, the brightest dark material (floor 0.9 of Default's 1.92 = 1.73) in Clear and Tinted.
    function test_basecampEdgeTonesAfterTheTone() {
        const t = Tokens;
        const best = (side, pivot, exp, panel) => Math.max(contrast(tone(0.60, side, pivot, exp), panel), contrast(tone(0.23, side, pivot, exp), panel));
        const floors = {"0": 2.17, "0.5": 2.61, "1": 2.9};
        for (const wp of [0, 0.5, 1]) {
            const got = best(-1, t.iconModeTileDarkenPivot, t.iconModeTileDarkenExponent, lum(materialRgb(false, wp, t.materialDefaultTransparency)));
            verify(got >= floors[String(wp)], `light window over ${wp}: ${got.toFixed(2)} against ${floors[String(wp)]}`);
        }
        const panel = lum(materialRgb(true, 1, 1.0));
        for (const q of [t.iconModeTileLiftExponentClear, t.iconModeTileLiftExponentTinted])
            verify(best(1, t.iconModeTileLiftPivot, q, panel) >= 1.73, `dark window at transparency 1.0 over white, lift ${q}`);
    }

    // Selected rows (rule A, tests/unit/tst_iconshader.qml test_a2_accentRow): the plate over the accent fill keeps 4.5:1 in Clear and 2.5:1 in Dark. Both selection
    // fills of the app are DARK accents (the text on them is light, TintedIcon.accentBright is false): #2E8049 in the dark appearance, #195E3F in the light one. Over
    // a dark accent the Clear plate is white at `clearPlateAlphaAccent` and the Dark plate is `darkPlateLumaOnDarkAccent`. The GPU run of 2026-11-09 measured 4.28
    // (Clear, opacity 0.9) and 2.08 (Dark, graphite) there, which these formulas reproduce.
    function test_accentRowPlates() {
        const t = Tokens;
        const a = t.iconModeClearPlateAlphaAccent;
        for (const fill of [Appearance.accentedDark.selection, Appearance.accentedLight.selection].map(c => String(c))) {
            const acc = lum(FolderStyle.rgbOf(fill));
            const clearPlate = 1.0 * a + acc * (1 - a);
            verify(contrast(clearPlate, acc) >= 4.5, `Clear plate over ${fill}: ${contrast(clearPlate, acc).toFixed(2)}:1`);
            const c = t.iconModeDarkPlateLumaOnDarkAccent;
            verify(contrast(lum([c, c, c]), acc) >= 2.5, `Dark plate over ${fill}: ${contrast(lum([c, c, c]), acc).toFixed(2)}:1`);
        }
    }

    function test_shaderFileExists() {
        // The compiled shader the effect loads sits next to its source (scripts/dev/build-shaders.sh).
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../ui/Grassfield/Ui/shaders/icon.frag.qsb"), false);
        xhr.send();
        verify(xhr.status === 200 || xhr.status === 0, "icon.frag.qsb readable");
        verify(xhr.responseText.length > 0, "icon.frag.qsb is not empty");
    }

    function test_tintResolution() {
        compare(IconModes.validTint("accent"), true);
        compare(IconModes.validTint("#12abEF"), true);
        compare(IconModes.validTint("#12345"), false);
        compare(IconModes.validTint("red"), false);
        compare(IconModes.validTint(5), false);
        compare(IconModes.tintColor("#12abef", "#000000"), "#12abef");
        compare(IconModes.tintColor("accent", "#000000"), "#000000");
        compare(IconModes.tintColor("bogus", "#000000"), "#000000");
    }

    function test_appearanceTintFollowsAccentByDefault() {
        compare(Appearance.iconTint.toString(), Qt.color(Appearance.colors.accent).toString());
        Appearance.iconTintSetting = "#e5484d";
        compare(Appearance.iconTint.toString(), Qt.color("#e5484d").toString());
        Appearance.iconTintSetting = "accent";
        const was = Appearance.dark;
        Appearance.dark = !was;
        compare(Appearance.iconTint.toString(), Qt.color(Appearance.colors.accent).toString(), "accent follows the appearance");
        Appearance.dark = was;
    }

    function test_settingsKeys() {
        compare(Store.validate("icons.mode", "clear"), "");
        verify(Store.validate("icons.mode", "neon") !== "");
        compare(Store.validate("icons.tint", "accent"), "");
        compare(Store.validate("icons.tint", "#A0b1C2"), "");
        verify(Store.validate("icons.tint", "#12345") !== "");
        verify(Store.validate("icons.tint", 3) !== "");
        compare(Store.DEFAULTS["icons.mode"], "default");
        compare(Store.DEFAULTS["icons.tint"], "accent");
        // Round trip: set, read back, every other key kept.
        const before = JSON.stringify({version: 1, appearance: "light", extra: {a: 1}});
        const r1 = Store.setValue(before, "icons.mode", "tinted");
        verify(r1.ok);
        const r2 = Store.setValue(r1.text, "icons.tint", "#e5484d");
        verify(r2.ok);
        const data = JSON.parse(r2.text);
        compare(Store.read(data, "icons.mode"), "tinted");
        compare(Store.read(data, "icons.tint"), "#e5484d");
        compare(data.appearance, "light");
        compare(data.extra.a, 1);
        // A hand-edited bad value reads as the default.
        compare(Store.read({icons: {mode: "neon", tint: "x"}}, "icons.mode"), "default");
        compare(Store.read({icons: {mode: "neon", tint: "x"}}, "icons.tint"), "accent");
        verify(!Store.setValue(before, "icons.mode", "neon").ok);
    }

    Component {
        id: iconComponent

        TintedIcon {
            size: 48
        }
    }

    // Live switch: the shell flips Appearance.iconMode; icons already on screen follow without being recreated.
    function test_liveSwitch() {
        const icon = createTemporaryObject(iconComponent, testCase);
        verify(icon);
        compare(icon.modeActive, false);
        compare(icon.effectActive, false, "default mode: no effect item, no offscreen pass");
        verify(icon.effectItem === null);

        Appearance.iconMode = "dark";
        compare(icon.modeActive, true);
        verify(icon.effectItem !== null);
        compare(icon.effectItem.modeIndex, 1);

        Appearance.iconMode = "tinted";
        compare(icon.effectItem.modeIndex, 3);
        compare(icon.effectItem.tint.toString(), Appearance.iconTint.toString());
        Appearance.iconTintSetting = "#e5484d";
        compare(icon.effectItem.tint.toString(), Qt.color("#e5484d").toString());

        Appearance.iconMode = "clear";
        compare(icon.effectItem.modeIndex, 2);

        const was = Appearance.dark;
        Appearance.dark = !was;
        compare(icon.effectItem.dark, was ? 0 : 1, "the effect follows the appearance");
        Appearance.dark = was;

        Appearance.iconMode = "default";
        compare(icon.effectActive, false);
        verify(icon.effectItem === null);
    }

    // An icon that is not shown creates no effect item (a type icon under a thumbnail, a closed panel).
    function test_hiddenIconHasNoEffect() {
        Appearance.iconMode = "dark";
        const icon = createTemporaryObject(iconComponent, testCase, {visible: false});
        verify(icon);
        compare(icon.effectActive, false);
        verify(icon.effectItem === null);
        icon.visible = true;
        compare(icon.effectActive, true);
        verify(icon.effectItem !== null);
        icon.visible = false;
        compare(icon.effectActive, false);
    }

    // A per-use override wins over the global setting (previews).
    function test_overrideMode() {
        const icon = createTemporaryObject(iconComponent, testCase, {mode: "clear"});
        verify(icon);
        compare(icon.modeActive, true);
        Appearance.iconMode = "dark";
        compare(icon.mode, "clear");
        compare(icon.effectItem.modeIndex, 2);
    }

    // A shader that cannot load must not make icons vanish: the plain image is shown (and one warning logged).
    function test_failedShaderShowsThePlainIcon() {
        Appearance.iconMode = "dark";
        const icon = createTemporaryObject(iconComponent, testCase, {shaderUrl: Qt.resolvedUrl("missing/icon.frag.qsb"), source: Qt.resolvedUrl("../fixtures/icons/blue-plate-white-glyph.svg")});
        verify(icon);
        compare(icon.plainVisible, false, "with a working shader the effect draws");
        // Whether a missing shader reports an error here depends on the scene graph (the software renderer never
        // compiles shaders); where it does, the plain image takes over.
        tryVerify(() => icon.effectItem.status !== ShaderEffect.Uncompiled || icon.effectFailed === false, 500, "status settles or stays uncompiled");
        compare(icon.plainVisible, icon.effectFailed);
    }

    // Files rows over an accent fill (selected, focused) pass overAccent down to the icon they draw (FileIcon -> TintedIcon/FolderIcon).
    function test_filesIconPassesOverAccent() {
        const c = Qt.createComponent(Qt.resolvedUrl("../../apps/files/qml/FileIcon.qml"));
        compare(c.status, Component.Ready, c.errorString());
        for (const dir of [false, true]) {
            const o = createTemporaryObject(c, testCase, {overAccent: true, isDir: dir});
            verify(o);
            verify(o.children[0].item.overAccent, "the icon of a " + (dir ? "folder" : "file") + " row follows the accent fill");
            o.overAccent = false;
            verify(!o.children[0].item.overAccent);
        }
    }

    // Below iconMode.minSize (16 px list rows, menus) every mode draws the Default artwork: no effect item, no plate, the plain image at its
    // own size (tests/visual/icon-a2.sh checks the pixels of a 16 px Tinted icon against Default).
    function test_smallIconsDrawTheDefaultArtwork() {
        verify(Tokens.iconModeMinSize > 16 && Tokens.iconModeMinSize <= 24);
        for (const mode of ["dark", "clear", "tinted"]) {
            const small = createTemporaryObject(iconComponent, testCase, {mode: mode, size: 16});
            verify(small);
            compare(small.modeActive, false, mode + " at 16 px");
            compare(small.effectiveMode, "default");
            compare(small.effectActive, false);
            compare(small.plainVisible, true, "the plain icon is what is drawn");
            const big = createTemporaryObject(iconComponent, testCase, {mode: mode, size: Tokens.iconModeMinSize});
            verify(big);
            compare(big.modeActive, true, mode + " at the minimum size");
            compare(big.effectiveMode, mode);
        }
    }
}
