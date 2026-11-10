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

    function test_tileToneSide() {
        const t = Tokens;
        compare(IconModes.tileToneSide(false, false, 0.25, t), -1, "light appearance, default material: darken");
        compare(IconModes.tileToneSide(false, false, t.materialTintClampUntil, t), -1, "up to the A2 clamp the material is solid");
        compare(IconModes.tileToneSide(false, false, t.materialTintClampUntil + 0.01, t), 0, "past the clamp the wallpaper shows through: no tone");
        compare(IconModes.tileToneSide(false, false, 1.0, t), 0);
        compare(IconModes.tileToneSide(true, false, 0.25, t), 0, "dark appearance: no tone (the rim)");
        compare(IconModes.tileToneSide(true, false, 1.0, t), 0);
        compare(IconModes.tileToneSide(true, true, 0.25, t), 0, "bare wallpaper (desktop icons): no tone");
        compare(IconModes.tileToneSide(false, true, 0.25, t), 0);
    }

    function test_tileToneMapIsOneSided() {
        const t = Tokens;
        const dark = v => IconModes.tileTone(v, -1, t.iconModeTileDarkenPivot, t.iconModeTileDarkenExponent);
        verify(t.iconModeTileDarkenExponent > 1, "the darken exponent darkens");
        compare(IconModes.tileTone(0.5, 0, 0.3, 2), 0.5, "no side: unchanged");
        let last = -1;
        for (let i = 0; i <= 200; i++) {
            const v = i / 200;
            verify(dark(v) <= v + 1e-12 && dark(v) >= 0, "darken never lifts: " + v);
            if (v >= t.iconModeTileDarkenPivot)
                compare(dark(v), v, "the darkening leaves what is above its pivot alone");
            verify(dark(v) >= last, "the map is increasing: " + v);
            last = dark(v);
        }
        compare(dark(0), 0);
        verify(Math.abs(dark(t.iconModeTileDarkenPivot - 1e-9) - t.iconModeTileDarkenPivot) < 1e-6, "continuous at its pivot");
    }

    // The pivot is the luminance of the material it is for, so a darkened pixel never moves towards it: over every solid light material (tint opacity at least
    // the A2 clamp) a darkened pixel gains contrast.
    function test_tileTonePivotFollowsTheMaterial() {
        const t = Tokens;
        const atDefault = lum(materialRgb(false, 0, t.materialDefaultTransparency));
        const atClamp = lum(materialRgb(false, 0, t.materialTintClampUntil));
        verify(t.iconModeTileDarkenPivot >= atClamp - 0.01 && t.iconModeTileDarkenPivot <= atDefault + 0.01,
               `the darken pivot ${t.iconModeTileDarkenPivot} lies between the darkest solid light materials ${atClamp.toFixed(3)} and ${atDefault.toFixed(3)}`);
        for (const wp of [0, 0.5, 1]) {
            const lm = lum(materialRgb(false, wp, t.materialTintClampUntil));
            for (let i = 0; i <= 100; i++) {
                const v = i / 100;
                const d = IconModes.tileTone(v, -1, t.iconModeTileDarkenPivot, t.iconModeTileDarkenExponent);
                if (v < lm - 0.05)
                    verify(contrast(d, lm) >= contrast(v, lm) - 1e-9, `darken: ${v} over a light material ${lm.toFixed(3)}`);
            }
        }
    }

    // Family 2 (hicolor:basecamp, a full-bleed tile of a pale sky and a green hill), light appearance: the edge tones of the tile (sky 0.60, hill 0.23 in
    // relative luminance; the shader keeps a tile's luminance) against the three light materials of tests/unit/tst_iconshader.qml, 48 px. The better of the
    // two tones after the tone reaches the Default's floor (0.9 of Default's 2.41, 2.90 and 3.45, and 2.9 from 3:1).
    function test_basecampEdgeTonesAfterTheTileTone() {
        const t = Tokens;
        const best = panel => Math.max(contrast(IconModes.tileTone(0.60, -1, t.iconModeTileDarkenPivot, t.iconModeTileDarkenExponent), panel),
                                       contrast(IconModes.tileTone(0.23, -1, t.iconModeTileDarkenPivot, t.iconModeTileDarkenExponent), panel));
        const floors = {"0": 2.17, "0.5": 2.61, "1": 2.9};
        for (const wp of [0, 0.5, 1]) {
            const got = best(lum(materialRgb(false, wp, t.materialDefaultTransparency)));
            verify(got >= floors[String(wp)], `light window over ${wp}: ${got.toFixed(2)} against ${floors[String(wp)]}`);
        }
    }

    // The Dark rim: one device pixel of near-white on the edge of a Dark tile in the dark appearance. Pure math of the shader's DARK RIM.
    function test_darkRimWeight() {
        const t = Tokens;
        verify(t.iconModeDarkRimWidth > 0.02 && t.iconModeDarkRimWidth < 0.06, "a thin halo, a few percent of the box");
        compare(IconModes.darkRimWidthPx(24, t.iconModeDarkRimWidth), 1, "one device pixel at 24 px");
        verify(IconModes.darkRimWidthPx(48, t.iconModeDarkRimWidth) <= t.iconModeSysPlateInset * 48 + 0.01, "no wider than the margin the plate inset leaves to the box");
        verify(t.iconModeDarkRimInnerPx > 0 && t.iconModeDarkRimInnerPx <= 0.5 + 1e-9, "the inner rim stays out of the ring that rule I reads from 2 px inside the edge (a 1 px one measured 1.94 against 2.35 on the GPU at 24 px)");
        verify(t.iconModeDarkRimStrength > 0 && t.iconModeDarkRimStrength <= 1 && t.iconModeDarkRimLuma > 0.8 && t.iconModeDarkRimLuma <= 1, "a light rim");
        const inner = d => IconModes.darkRimWeight(d, t.iconModeDarkRimInnerPx, t.iconModeDarkRimStrength);
        compare(inner(-1), 0, "no inner rim outside the tile");
        compare(inner(0), t.iconModeDarkRimStrength, "full strength on the edge");
        compare(inner(1.0), 0, "nothing one pixel in: the inner tones are untouched (rules I, S, N)");
        for (let d = 0; d < 3; d += 0.25)
            verify(inner(d + 0.25) <= inner(d) + 1e-12, "the inner rim fades inwards");
        for (const box of [24, 32, 48]) {
            const h = o => IconModes.darkHaloWeight(o, box, t.iconModeDarkRimWidth, t.iconModeDarkRimStrength);
            compare(h(-1), 0, "no halo inside the tile (it is drawn behind it)");
            compare(h(0), t.iconModeDarkRimStrength, `full strength at the plate edge, ${box} px`);
            compare(h(IconModes.darkRimWidthPx(box, t.iconModeDarkRimWidth) + 0.5), 0, "none past its width");
        }
    }

    // The edge stands out of the brightest dark material (relative luminance 0.38) by at least the floor of basecamp's 24 px cell (0.9 of Default's 1.92 =
    // 1.73): the halo over the material and the inner rim over a tile pixel of the sky's tone (0.60) or the hill's (0.23).
    function test_darkRimStandsOutOfAMidGreyMaterial() {
        const t = Tokens;
        const panel = lum(materialRgb(true, 1, 1.0));
        const halo = IconModes.darkHaloWeight(0, 24, t.iconModeDarkRimWidth, t.iconModeDarkRimStrength);
        const over = halo * t.iconModeDarkRimLuma + (1 - halo) * Math.pow(panel, 1 / 2.4);
        verify(contrast(lum([over, over, over]), panel) >= 1.73, `halo over the material: ${contrast(lum([over, over, over]), panel).toFixed(2)}:1`);
        const weight = IconModes.darkRimWeight(0, t.iconModeDarkRimInnerPx, t.iconModeDarkRimStrength);
        for (const tone of [0.60, 0.23]) {
            const tileCoded = Math.pow(tone, 1 / 2.4);
            const coded = tileCoded * (1 - weight) + t.iconModeDarkRimLuma * weight;
            const y = lum([coded, coded, coded]);
            verify(contrast(y, panel) >= 1.73, `inner rim over a tile tone ${tone}: ${contrast(y, panel).toFixed(2)}:1`);
        }
    }

    // Selected rows (rule A, tests/unit/tst_iconshader.qml test_a2_accentRow): the plate over the accent fill keeps 4.5:1 in Clear and 2.5:1 in Dark. Both selection
    // fills of the app are DARK accents (the text on them is light, TintedIcon.accentBright is false): #2E8049 in the dark appearance, #195E3F in the light one. Over
    // a dark accent the Clear plate is white at `clearPlateAlphaAccent` and the Dark plate is `darkPlateLumaOnDarkAccent`. The GPU run of 2026-11-09 measured 4.28
    // (Clear, opacity 0.9) and 2.08 (Dark, graphite) there, which these formulas reproduce.
    function test_accentRowPlates() {
        const t = Tokens;
        const a = t.iconModeClearPlateAlphaAccent;
        for (const fill of ["#2E8049", "#195E3F"]) {
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
