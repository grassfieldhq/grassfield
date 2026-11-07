import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/services/BarToneLogic.js" as BarLogic

// Adaptive glass (ADR-0024 section 2, G-1 to G-3; GlassTint.js): a class tint raised to keep text at 4.5:1 over the backdrop,
// the worst case (black to white) when the shell does not know it, the class target over a known bare desktop.
TestCase {
    id: testCase

    name: "GlassTint"
    width: 200
    height: 200
    visible: true
    when: windowShown

    Material {
        id: material
        width: 100
        height: 60
        glassClass: "menu"
    }

    function cleanup() {
        Appearance.backdrops = {};
        Appearance.increaseContrast = false;
        material.backdropRect = Qt.rect(0, 0, 0, 0);
        Appearance.dark = true;
        Appearance.reduceTransparency = false;
        Appearance.transparency = Tokens.materialDefaultTransparency;
    }

    function floorOf(dark, lumMin, lumMax, need) {
        const c = dark ? Tokens.colorDark : Tokens.colorLight;
        return GlassTint.floorAlpha(c.materialTint, [c.text, c.textSecondary], c.fill, Tokens.materialFillOpacity, lumMin, lumMax, need);
    }

    // Today's material over any backdrop: the secondary text is the binding constraint (light 0.79, dark 0.82; light 0.78 with
    // the cool neutrals before the owner's warm ones of 2026-10-30, ADR-0040).
    function test_worstCaseFloors() {
        compare(floorOf(false, 0, 1, 4.5), 0.79);
        compare(floorOf(true, 0, 1, 4.5), 0.82);
    }

    function test_targetAlpha() {
        const d = Tokens.materialDefaultTransparency;
        compare(GlassTint.targetAlpha(0.65, 0, d), 1);
        fuzzyCompare(GlassTint.targetAlpha(0.65, d, d), 0.65, 1e-9);
        fuzzyCompare(GlassTint.targetAlpha(0.65, 1, d), 0, 1e-9);
        verify(GlassTint.targetAlpha(0.65, d / 2, d) > 0.65 && GlassTint.targetAlpha(0.65, d / 2, d) < 1);
    }

    // Independent check of a band (not GlassTint.bandAlpha's own loop): the text's contrast over the tint, at rest, under the
    // open title's capsule at its real fill (BarButton: hover opacity x active factor, in the palette's hover colour) and dimmed
    // (band and text at the inactive opacity), over the greys at both ends of the range.
    function bandStates(c, alpha, range) {
        const ink = GlassTint.channels(c.text);
        const cap = Tokens.materialHoverOpacity * Tokens.materialHoverActiveFactor;
        const r = {rest: 99, capsule: 99, dim: 99};
        // The greys at both ends and the saturated colours that bound them (the same cover as the floor: backdropsOf).
        for (const back of GlassTint.backdropsOf(range.lumMin).concat(GlassTint.backdropsOf(range.lumMax))) {
            const base = GlassTint.over(GlassTint.channels(c.materialTint), alpha, back);
            r.rest = Math.min(r.rest, GlassTint.ratio(ink, base));
            r.capsule = Math.min(r.capsule, GlassTint.ratio(ink, GlassTint.over(GlassTint.channels(c.hover), cap, base)));
            const dimBase = GlassTint.over(GlassTint.channels(c.materialTint), alpha * Tokens.menubarInactiveOpacity, back);
            r.dim = Math.min(r.dim, GlassTint.ratio(GlassTint.over(ink, Tokens.menubarInactiveOpacity, dimBase), dimBase));
        }
        return r;
    }

    function bandOf(range, t) {
        const tone = BarLogic.stripTone(range.lumMin, range.lumMax, "", Tokens.menubarToneNeededContrast, Tokens.menubarToneMargin).tone;
        return Appearance.barBand(range, BarLogic.bandIsDark(tone));
    }

    readonly property var strips: ({owner: {lumMin: 0.0528, lumMax: 0.35}, dark: {lumMin: 0.005, lumMax: 0.02}, light: {lumMin: 0.8, lumMax: 0.95}, mixed: {lumMin: 0.01, lumMax: 0.45}})

    // The tone mapping and the palettes: light text sits on dark glass (the dark palette: its tint and its text), dark text on light
    // glass, whatever the appearance; the colours are the real ones, not only the flag.
    function test_bandTonePalette() {
        compare(BarLogic.bandIsDark("light"), true);
        compare(BarLogic.bandIsDark("dark"), false);
        for (const appearanceDark of [false, true]) {
            Appearance.dark = appearanceDark;
            const dk = Appearance.glassBand("menu", 0.49, strips.dark, true);
            compare(dk.dark, true);
            compare(dk.colors.text, Tokens.colorDark.text);
            compare(dk.colors.materialTint, Tokens.colorDark.materialTint);
            compare(dk.colors.text, "#F8F5F0");
            const lt = Appearance.glassBand("menu", 0.49, strips.light, false);
            compare(lt.dark, false);
            compare(lt.colors.text, Tokens.colorLight.text);
            compare(lt.colors.materialTint, Tokens.colorLight.materialTint);
            compare(lt.colors.text, "#1D1B18");
        }
    }

    // The band keeps its text legible in every state over the strip, with BOTH tones, in both appearances (A2): rest and the open
    // capsule 4.5:1, dimmed 3:1; never below the class target; the floor uses the BAND's palette, not the appearance's.
    function test_bandHoldsA2InEveryState() {
        const rows = [];
        for (const appearanceDark of [false, true]) {
            Appearance.dark = appearanceDark;
            for (const t of [0.1, 0.25, 0.49, 0.6]) {
                for (const name of Object.keys(strips)) {
                    for (const darkGlass of [true, false]) {
                        const b = Appearance.glassBand("menu", t, strips[name], darkGlass);
                        const st = bandStates(b.colors, b.alpha, strips[name]);
                        if (t === 0.25 || t === 0.49)
                            rows.push((appearanceDark ? "dark" : "light") + " appearance t=" + t + " " + name + " " + (darkGlass ? "dark" : "light") + " glass: alpha=" + b.alpha.toFixed(2) + " text=" + b.colors.text + " rest=" + st.rest.toFixed(2) + " capsule=" + st.capsule.toFixed(2) + " dim=" + st.dim.toFixed(2));
                        verify(st.rest >= 4.5, "rest " + name + " " + darkGlass + " " + t);
                        verify(st.capsule >= 4.5, "capsule " + name + " " + darkGlass + " " + t);
                        verify(st.dim >= 3, "dim " + name + " " + darkGlass + " " + t);
                        verify(b.alpha >= GlassTint.targetAlpha(Tokens.glassMenu, t, Tokens.materialDefaultTransparency) - 1e-9);
                    }
                }
            }
        }
        console.info("band table:\n" + rows.join("\n"));
    }

    // Each state is judged on its own (GlassTint.bandAlpha): the open capsule raises the floor by itself (no dimming in play), and
    // the dimmed state does too (no capsule), and the band uses the real fill of BarButton (hover opacity x active factor).
    function test_bandStatesBindOnTheirOwn() {
        const c = Tokens.colorDark;
        const r = strips.owner;
        const a = (cap, dim, dimNeed) => GlassTint.bandAlpha(Tokens.glassMenu, 0.49, Tokens.materialDefaultTransparency, r, c.materialTint, c.text, c.hover, cap, dim, 4.5, dimNeed, Tokens.glassContrastMargin);
        const real = Tokens.materialHoverOpacity * Tokens.materialHoverActiveFactor;
        verify(a(real, 1, 0) > a(0, 1, 0), "the capsule must raise the floor");
        verify(a(0, Tokens.menubarInactiveOpacity, 3) > a(0, 1, 0) || a(0, Tokens.menubarInactiveOpacity, 3) >= a(0, 1, 0), "dimmed");
        verify(a(0, 0.5, 6) > a(0, 1, 0), "the dimmed state must raise the floor when it binds");
        Appearance.dark = false;
        compare(Appearance.glassBand("menu", 0.49, r, true).alpha, a(real, Tokens.menubarInactiveOpacity, 3));
        verify(a(real, 1, 0) > a(0.14, 1, 0), "the real capsule fill is above the 0.14 of the generic floor");
    }

    // The floor is judged with the band's own palette: dark glass over a bright strip needs more than light glass does there.
    function test_bandFloorUsesTheBandPalette() {
        Appearance.dark = false;
        const bright = strips.light;
        const darkGlass = Appearance.glassBand("menu", 0.49, bright, true).alpha;
        const lightGlass = Appearance.glassBand("menu", 0.49, bright, false).alpha;
        verify(darkGlass > lightGlass);
        Appearance.dark = true;
        compare(Appearance.glassBand("menu", 0.49, bright, true).alpha, darkGlass);
        compare(Appearance.glassBand("menu", 0.49, bright, false).alpha, lightGlass);
    }

    // The owner's strip: dark glass, below the 0.79 of the appearance's light glass and the legacy 0.82; the open capsule holds.
    function test_ownerStripBand() {
        Appearance.dark = false;
        const b = bandOf(strips.owner, 0.49);
        compare(b.dark, true);
        compare(b.colors.text, "#F8F5F0");
        verify(b.alpha < 0.79);
        verify(b.alpha < Appearance.tintAlpha(0.49));
        verify(bandStates(b.colors, b.alpha, strips.owner).capsule >= 4.5);
    }

    // Reduce Transparency, an unknown strip: the appearance's own colours (Appearance.barBand, what MenuBar draws).
    function test_barBandOpaqueAndUnknown() {
        for (const appearanceDark of [false, true]) {
            Appearance.dark = appearanceDark;
            Appearance.reduceTransparency = true;
            compare(Appearance.barBand(strips.dark, true), null);
            const r = Appearance.glassBand("menu", 0, strips.dark, true);
            compare(r.alpha, 1);
            compare(r.dark, appearanceDark);
            compare(r.colors, Appearance.colors);
            Appearance.reduceTransparency = false;
            compare(Appearance.barBand(null, true), null);
            const u = Appearance.glassBand("menu", 0.49, null, true);
            compare(u.dark, appearanceDark);
            compare(u.colors, Appearance.colors);
            compare(u.alpha, Appearance.glassAlpha("menu", 0.49, "nowhere"));
            verify(Appearance.barBand(strips.dark, true) !== null);
        }
    }

    // What the bar's logo, titles, status items and clock take (MenuBar's barText and barTint): the band's own text and hover over
    // a band, the appearance's when the band has no strip, the wallpaper's tone without a background.
    function test_barForegroundFollowsTheBand() {
        for (const appearanceDark of [false, true]) {
            Appearance.dark = appearanceDark;
            const darkBand = Appearance.glassBand("menu", 0.49, strips.dark, true);
            const lightBand = Appearance.glassBand("menu", 0.49, strips.light, false);
            compare(Appearance.barForeground(true, darkBand, false).text, Tokens.colorDark.text);
            compare(Appearance.barForeground(true, darkBand, false).hover, Tokens.colorDark.hover);
            compare(Appearance.barForeground(true, lightBand, true).text, Tokens.colorLight.text);
            compare(Appearance.barForeground(true, lightBand, true).hover, Tokens.colorLight.hover);
            // No strip to adapt to: the appearance's own.
            compare(Appearance.barForeground(true, null, true).text, Appearance.colors.text);
            compare(Appearance.barForeground(true, null, false).hover, Appearance.colors.hover);
            // No background: the wallpaper's tone ("dark" tone: black text).
            compare(Appearance.barForeground(false, darkBand, true).text, Tokens.colorLight.barText);
            compare(Appearance.barForeground(false, darkBand, false).text, Tokens.colorDark.barText);
        }
    }

    // A Material's tint colour defaults to the appearance's material tint (every other surface keeps it).
    function test_materialTintColorDefault() {
        for (const appearanceDark of [false, true]) {
            Appearance.dark = appearanceDark;
            compare(String(material.tintColor).toLowerCase(), String(Appearance.colors.materialTint).toLowerCase());
        }
        const m = createTemporaryObject(plainMaterial, testCase);
        m.tintColor = "#112233";
        compare(String(m.tintColor), "#112233");
    }

    Component {
        id: plainMaterial
        Material {
            width: 10
            height: 10
        }
    }

    function test_unknownBackdropTakesTheWorstCase() {
        Appearance.dark = false;
        compare(Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, "nowhere"), 0.79);
        Appearance.dark = true;
        compare(Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, "nowhere"), 0.82);
        compare(Appearance.glassAlpha("menu", 0, "nowhere"), 1);
        compare(Appearance.glassAlpha("menu", 1, "nowhere"), 0.82);
    }

    // A dark wallpaper behind dark-appearance glass: light text holds on its own, the class target applies.
    function test_knownDarkBackdropInTheDarkAppearance() {
        Appearance.dark = true;
        Appearance.backdrops = {"out": {lumMin: 0.01, lumMax: 0.05}};
        fuzzyCompare(Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, "out"), Tokens.glassMenu, 1e-9);
        fuzzyCompare(Appearance.glassAlpha("notification", Tokens.materialDefaultTransparency, "out"), Tokens.glassNotification, 1e-9);
        // A bright wallpaper behind the same glass needs more tint than the target.
        Appearance.backdrops = {"out": {lumMin: 0.6, lumMax: 0.9}};
        verify(Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, "out") > Tokens.glassMenu);
    }

    function test_knownBrightBackdropInTheLightAppearance() {
        Appearance.dark = false;
        Appearance.backdrops = {"out": {lumMin: 0.7, lumMax: 0.9}};
        fuzzyCompare(Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, "out"), Tokens.glassMenu, 1e-9);
    }

    // A 4 x 2 grid over a 400 x 200 output: the left half dark, the right half bright (G-3 per surface).
    readonly property var splitGrid: ({width: 400, height: 200, cols: 4, rows: 2, min: [0.01, 0.01, 0.7, 0.7, 0.01, 0.01, 0.7, 0.7], max: [0.04, 0.05, 0.9, 0.9, 0.04, 0.05, 0.9, 0.9]})

    function test_gridRange() {
        const left = GlassTint.gridRange(splitGrid, Qt.rect(10, 10, 60, 150), 0);
        fuzzyCompare(left.lumMin, 0.01, 1e-9);
        fuzzyCompare(left.lumMax, 0.04, 1e-9);
        // A wider area takes the cells it reaches.
        fuzzyCompare(GlassTint.gridRange(splitGrid, Qt.rect(10, 10, 150, 150), 0).lumMax, 0.05, 1e-9);
        // The blur's reach brings the bright cell beside it in.
        compare(GlassTint.gridRange(splitGrid, Qt.rect(110, 10, 60, 20), 40).lumMax, 0.9);
        // Outside the output: clamped to the edge cells.
        compare(GlassTint.gridRange(splitGrid, Qt.rect(500, -50, 30, 30), 0).lumMin, 0.7);
        // No answer without a grid or an area: the caller keeps the whole output's range.
        compare(GlassTint.gridRange(null, Qt.rect(0, 0, 10, 10), 0), null);
        compare(GlassTint.gridRange(splitGrid, Qt.rect(0, 0, 0, 0), 0), null);
        compare(GlassTint.gridRange({width: 400, height: 200, cols: 4, rows: 2, min: [0], max: [1]}, Qt.rect(0, 0, 10, 10), 0), null);
    }

    // The wallpaper under a surface that always lies on it (the menu bar's band while the bar keeps its strip): the output's
    // wallpaper range narrowed to the cells under the surface, known whatever windows the output shows (owner 2026-11-07: the
    // band was opaque on every display with a window open, translucent on a bare one).
    function test_wallpaperUnder() {
        const range = {lumMin: 0.01, lumMax: 0.9};
        const strip = GlassTint.wallpaperUnder(range, splitGrid, Qt.rect(0, 0, 90, 24), 0);
        fuzzyCompare(strip.lumMin, 0.01, 1e-9);
        fuzzyCompare(strip.lumMax, 0.04, 1e-9);
        compare(GlassTint.wallpaperUnder(range, null, Qt.rect(0, 0, 90, 24), 0), {lumMin: 0.01, lumMax: 0.9}, "no grid: the whole range");
        compare(GlassTint.wallpaperUnder(null, splitGrid, Qt.rect(0, 0, 90, 24), 0), null, "an unknown wallpaper: unknown");
        compare(GlassTint.wallpaperUnder({lumMin: "x", lumMax: 1}, null, Qt.rect(0, 0, 90, 24), 0), null);
        // Over the measured strip the menu glass stays at its class target in the dark appearance, below the worst case.
        Appearance.dark = true;
        fuzzyCompare(Appearance.glassAlphaOver("menu", Tokens.materialDefaultTransparency, strip), Tokens.glassMenu, 1e-9);
        verify(Appearance.glassAlphaOver("menu", Tokens.materialDefaultTransparency, strip) < Appearance.glassAlphaOver("menu", Tokens.materialDefaultTransparency, null));
    }

    function test_gridOf() {
        // 4 x 2 pixels, two cells across: black and white on the left, a mid grey on the right.
        const px = [0, 0, 0, 255, 255, 255, 255, 255, 119, 119, 119, 255, 119, 119, 119, 255, 0, 0, 0, 255, 255, 255, 255, 255, 119, 119, 119, 255, 119, 119, 119, 255];
        const g = GlassTint.gridOf(px, 4, 2, 2, 1, 1920, 1080);
        compare(g.cols, 2);
        compare(g.width, 1920);
        fuzzyCompare(g.min[0], 0, 1e-9);
        fuzzyCompare(g.max[0], 1, 1e-9);
        fuzzyCompare(g.min[1], g.max[1], 1e-9);
        verify(g.min[1] > 0.15 && g.min[1] < 0.2);
    }

    // The glass over the dark half takes the class target; over the bright half it is raised (dark appearance).
    function test_materialUsesTheAreaUnderIt() {
        Appearance.dark = true;
        Appearance.transparency = Tokens.materialDefaultTransparency;
        const backs = {};
        backs[material.screenName] = {lumMin: 0.01, lumMax: 0.9, grid: splitGrid};
        Appearance.backdrops = backs;
        material.backdropRect = Qt.rect(10, 10, 60, 60);
        fuzzyCompare(material.tintAlpha, Tokens.glassMenu, 1e-9);
        material.backdropRect = Qt.rect(330, 10, 60, 60);
        verify(material.tintAlpha > Tokens.glassMenu);
        // Without an area (and in a window smaller than the output) the whole output's range applies.
        material.backdropRect = Qt.rect(0, 0, 0, 0);
        compare(material.tintAlpha, Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, material.screenName, Qt.rect(0, 0, 0, 0)));
    }

    // Text straight on the wallpaper (the Notification Center title): the ink that holds 4.5:1 over the whole range, else
    // none (the caller puts glass behind it).
    function test_inkOn() {
        const inks = [Tokens.colorDark.text, Tokens.colorLight.text];
        compare(GlassTint.inkOn({lumMin: 0.01, lumMax: 0.1}, inks, 4.5), Tokens.colorDark.text);
        compare(GlassTint.inkOn({lumMin: 0.6, lumMax: 0.95}, inks, 4.5), Tokens.colorLight.text);
        compare(GlassTint.inkOn({lumMin: 0.02, lumMax: 0.88}, inks, 4.5), "");
        compare(GlassTint.inkOn(null, inks, 4.5), "");
    }

    // Increase Contrast frosts the glass whatever the backdrop and the class (G-8).
    function test_increaseContrastFrosts() {
        Appearance.dark = true;
        const backs = {};
        backs[material.screenName] = {lumMin: 0.01, lumMax: 0.05};
        Appearance.backdrops = backs;
        Appearance.increaseContrast = true;
        compare(material.tintAlpha, Tokens.glassContrastFrost);
        Appearance.increaseContrast = false;
        fuzzyCompare(material.tintAlpha, Tokens.glassMenu, 1e-9);
    }

    function test_materialFollowsItsClassAndOutput() {
        Appearance.dark = true;
        Appearance.transparency = Tokens.materialDefaultTransparency;
        compare(material.tintAlpha, 0.82);
        const backs = {};
        backs[material.screenName] = {lumMin: 0.01, lumMax: 0.05};
        Appearance.backdrops = backs;
        fuzzyCompare(material.tintAlpha, Tokens.glassMenu, 1e-9);
        material.glassClass = "";
        compare(material.tintAlpha, Appearance.tintAlpha(Tokens.materialDefaultTransparency));
        material.glassClass = "menu";
    }
}
