import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Store.js" as Store

// Accent colour (`accent.color`): setting -> accent/accentText in both appearances, live in Appearance, validation,
// contrast of every pair (A2, 4.5:1 for text on the accent fill) and the dependants (icon tint, folder colour, highlight).
TestCase {
    id: testCase
    name: "Accent"

    readonly property var named: ["blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite"]

    function channel(v) {
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    }

    function ratio(a, b) {
        const ca = Qt.color(a), cb = Qt.color(b);
        const la = 0.2126 * channel(ca.r) + 0.7152 * channel(ca.g) + 0.0722 * channel(ca.b);
        const lb = 0.2126 * channel(cb.r) + 0.7152 * channel(cb.g) + 0.0722 * channel(cb.b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    function cleanup() {
        Appearance.accentSetting = "multicolor";
        Appearance.dark = true;
        Appearance.increaseContrast = false;
        Appearance.textScale = 1;
        Appearance.iconTintSetting = "accent";
        Appearance.folderColorSetting = "theme";
    }

    function test_namesAndNormalize() {
        compare(Accent.NAMES.length, 9);
        compare(Accent.NAMES[0], "multicolor");
        compare(Accent.normalize(undefined), "multicolor");
        compare(Accent.normalize("Blue"), "multicolor");
        compare(Accent.normalize("neon"), "multicolor");
        compare(Accent.normalize("blue"), "blue");
        verify(!Accent.validName(7));
    }

    function test_multicolorKeepsGrassfieldGreen() {
        compare(Accent.resolve("multicolor", true, Tokens), null);
        compare(Accent.resolve("bogus", false, Tokens), null);
        compare(Appearance.colors.accent, Tokens.colorDark.accent);
        Appearance.dark = false;
        compare(Appearance.colors.accent, Tokens.colorLight.accent);
    }

    function test_everyAccentResolvesInBothAppearances() {
        for (const n of testCase.named) {
            const d = Accent.resolve(n, true, Tokens), l = Accent.resolve(n, false, Tokens);
            verify(/^#[0-9A-Fa-f]{6}$/.test(d.accent) && /^#[0-9A-Fa-f]{6}$/.test(d.accentText), n + " dark");
            verify(/^#[0-9A-Fa-f]{6}$/.test(l.accent) && /^#[0-9A-Fa-f]{6}$/.test(l.accentText), n + " light");
            verify(d.accent !== Tokens.colorDark.accent, n + " differs from the Grassfield green");
            verify(ratio(d.accentText, d.accent) >= 4.5, n + " dark text on accent " + ratio(d.accentText, d.accent));
            verify(ratio(l.accentText, l.accent) >= 4.5, n + " light text on accent " + ratio(l.accentText, l.accent));
        }
    }

    function test_appearanceFollowsTheSettingLive() {
        Appearance.accentSetting = "blue";
        compare(Appearance.colors.accent, Tokens.colorAccentDark.blue);
        compare(Appearance.colors.accentText, Tokens.colorAccentDark.blueText);
        compare(Appearance.darkColors.accent, Tokens.colorAccentDark.blue);
        compare(Appearance.lightColors.accent, Tokens.colorAccentLight.blue);
        Appearance.dark = false;
        compare(Appearance.colors.accent, Tokens.colorAccentLight.blue);
        compare(Appearance.colors.accentText, Tokens.colorAccentLight.blueText);
        Appearance.accentSetting = "graphite";
        compare(Appearance.colors.accent, Tokens.colorAccentLight.graphite);
        Appearance.accentSetting = "multicolor";
        compare(Appearance.colors.accent, Tokens.colorLight.accent);
        // The other roles never change.
        compare(Appearance.colors.text, Tokens.colorLight.text);
    }

    // macOS keeps white text on its accent fill in both appearances (ADR-0024): a selected row, a default button or a checked
    // box uses the light appearance's accent and text colour in the light appearance and the dark selection shade
    // (color.selectionDark, never darker than the light accent) in the dark one; 4.5:1 for every accent.
    function test_selectionPairPerAppearance() {
        for (const n of ["multicolor"].concat(testCase.named)) {
            Appearance.accentSetting = n;
            const lightFill = n === "multicolor" ? Tokens.colorLight.accent : Tokens.colorAccentLight[n];
            const lightText = n === "multicolor" ? Tokens.colorLight.accentText : Tokens.colorAccentLight[n + "Text"];
            for (const dark of [true, false]) {
                Appearance.dark = dark;
                const fill = dark ? Tokens.colorSelectionDark[n] : lightFill;
                const text = dark ? Tokens.colorSelectionDark[n + "Text"] : lightText;
                compare(Qt.color(Appearance.colors.selection), Qt.color(fill), n + (dark ? " dark" : " light"));
                compare(Qt.color(Appearance.colors.selectionText), Qt.color(text), n + (dark ? " dark" : " light"));
                verify(ratio(Appearance.colors.selectionText, Appearance.colors.selection) >= 4.5, n + " " + ratio(Appearance.colors.selectionText, Appearance.colors.selection));
                verify(Qt.color(Appearance.colors.selection).hslLightness >= Qt.color(lightFill).hslLightness - 0.005, n + " dark selection darker than the light accent");
            }
        }
        // The multicolor green in the dark appearance: the owner's #2E8049 with white text, not the dark text of the bright accent.
        Appearance.accentSetting = "multicolor";
        Appearance.dark = true;
        compare(Qt.color(Appearance.colors.selection), Qt.color("#2e8049"));
        compare(Qt.color(Appearance.colors.selectionText), Qt.color("#ffffff"));
        Appearance.devGlyphMode = "white";
        compare(Qt.color(Appearance.colors.selectionText), Qt.color("#fffffe"));
        Appearance.devGlyphMode = "";
    }

    function test_highlightFollowsTheAccent() {
        compare(Appearance.highlight, Qt.color(Tokens.colorDark.accent));
        Appearance.accentSetting = "pink";
        compare(Appearance.highlight, Qt.color(Tokens.colorAccentDark.pink));
        compare(Appearance.highlightText, Qt.color(Tokens.colorAccentDark.pinkText));
    }

    function test_iconTintAndFolderColourFollow() {
        Appearance.accentSetting = "orange";
        compare(Appearance.iconTint, Qt.color(Tokens.colorAccentDark.orange));
        Appearance.folderColorSetting = "accent";
        compare(Appearance.folderTint, Qt.color(Tokens.colorAccentDark.orange));
        Appearance.accentSetting = "red";
        compare(Appearance.folderTint, Qt.color(Tokens.colorAccentDark.red));
        // A fixed tint is not the accent.
        Appearance.iconTintSetting = "#8e5bea";
        compare(Appearance.iconTint, Qt.color("#8e5bea"));
    }

    // Text and glyphs drawn in the accent colour read `accentInk` (the integrator's review of 5391761): the accent itself, or
    // in the light appearance the darker shade of a light accent (color.accentInkLight: yellow and green).
    function test_accentInkIsTheAccentOrItsDarkerShade() {
        // The palettes are JS objects: their colours are strings, compared as colours.
        function same(a, b, what) {
            verify(Qt.colorEqual(a, b), what + ": " + a + " != " + b);
        }
        Appearance.dark = false;
        Appearance.accentSetting = "multicolor";
        same(Appearance.colors.accentInk, Appearance.colors.accent, "the default: its own accent");
        Appearance.accentSetting = "blue";
        same(Appearance.colors.accentInk, Tokens.colorAccentLight.blue, "light blue: the accent");
        // Pink needs no ink since the search field is a flat grey outside the accent role (ADR-0024 amendment 2026-11-03).
        Appearance.accentSetting = "pink";
        same(Appearance.colors.accentInk, Tokens.colorAccentLight.pink, "light pink: the accent");
        for (const n of ["yellow", "green"]) {
            Appearance.accentSetting = n;
            same(Appearance.colors.accentInk, Tokens.colorAccentInkLight[n], "light " + n + ": its ink");
            verify(!Qt.colorEqual(Appearance.colors.accentInk, Appearance.colors.accent), n);
            same(Appearance.lightColors.accentInk, Tokens.colorAccentInkLight[n], "lightColors " + n);
            same(Appearance.darkColors.accentInk, Tokens.colorAccentDark[n], "dark " + n + ": the accent itself");
        }
        Appearance.dark = true;
        Appearance.accentSetting = "green";
        same(Appearance.colors.accentInk, Tokens.colorAccentDark.green, "dark green");
        Appearance.dark = false;
        Appearance.accentSetting = "multicolor";
        // Pure: a setting resolves without a scene.
        compare(Accent.resolve("yellow", false, Tokens).accentInk, Tokens.colorAccentInkLight.yellow);
        compare(Accent.resolve("yellow", true, Tokens).accentInk, Tokens.colorAccentDark.yellow);
        compare(Accent.resolve("purple", false, Tokens).accentInk, Tokens.colorAccentLight.purple);
        compare(Accent.resolve("multicolor", false, Tokens), null);
    }

    // Accent text on glass reads `accentGlass`: the ink mixed toward the text colour by the glass token. The 18 colours are pinned as
    // literals, computed independently by tests/visual/test_contrast_tokens.py (which pins the same ones and checks the 4.5:1 they
    // buy over the shell's real glass), so a change of either side, of a palette or of a mix token fails here.
    readonly property var glassPinned: ({
        dark: {multicolor: "#cfe5d0", blue: "#d2e1f4", purple: "#e8dcf0", pink: "#f6d7e1", red: "#f7d7d1", orange: "#f7e1c8", yellow: "#f7ecc8", green: "#deedc9", graphite: "#e3e2e0"},
        light: {multicolor: "#1b3728", blue: "#1e3864", purple: "#442a60", pink: "#62243d", red: "#612420", orange: "#503011", yellow: "#473a0e", green: "#2e401e", graphite: "#37383b"}
    })

    function test_accentGlassIsTheInkMixedTowardTheText() {
        // The mix of the two channels spelled out for one case: pure black and white halfway is #808080 (Math.round of 127.5).
        compare(Accent.glassInk("#000000", "#ffffff", 0.5), "#808080");
        compare(Accent.glassInk("#ffffff", "#000000", 0), "#ffffff");
        compare(Accent.glassInk("#0a0a0a", "#0a0a0a", 0.7), "#0a0a0a");
        compare(Accent.glassInk("not a colour", "#ffffff", 0.5), "not a colour");
        compare(Tokens.glassAccentInkMixDark, 0.76);
        compare(Tokens.glassAccentInkMixLight, 0.58);
        for (const dark of [false, true]) {
            const ap = dark ? "dark" : "light";
            for (const n of Accent.NAMES) {
                Appearance.dark = dark;
                Appearance.accentSetting = n;
                const c = Appearance.colors;
                compare(c.accentGlass, glassPinned[ap][n], ap + " " + n);
                verify(!Qt.colorEqual(c.accentGlass, c.accentInk), n + ": the variant is not the raw ink");
            }
        }
        Appearance.dark = false;
        Appearance.accentSetting = "multicolor";
    }

    function test_glyphMaskStillWins() {
        Appearance.accentSetting = "green";
        Appearance.devGlyphMode = "white";
        compare(Appearance.colors.accentText, Qt.color("#fffffe"));
        compare(Appearance.darkColors.accentText, Qt.color("#fffffe"));
        Appearance.devGlyphMode = "";
        compare(Appearance.colors.accentText.toString().toLowerCase(), String(Tokens.colorAccentDark.greenText).toLowerCase());
    }

    // The keyboard focus ring (UX-09, A11Y-08): one colour for every surface, 3:1 or more as a non-text element against the
    // material tint and against that tint over the extreme wallpapers (the tint alpha floor), for every accent in both
    // appearances, the light appearance's yellow and green included (they fall back to the text colour).
    function test_focusRingHolds3to1OnEveryAccentInBothAppearances() {
        function over(fg, a, bg) {
            const f = Qt.color(fg), b = Qt.color(bg);
            return Qt.rgba(f.r * a + b.r * (1 - a), f.g * a + b.g * (1 - a), f.b * a + b.b * (1 - a), 1);
        }
        for (const dark of [true, false]) {
            Appearance.dark = dark;
            for (const n of Accent.NAMES) {
                Appearance.accentSetting = n;
                const ring = Appearance.focusRingColor;
                const tint = Appearance.colors.materialTint;
                const alpha = Tokens.materialTintAlphaClamp;
                for (const wallpaper of ["#000000", "#ffffff", Appearance.colors.materialTint]) {
                    const surface = over(tint, alpha, wallpaper);
                    verify(ratio(ring, surface) >= 3, (dark ? "dark " : "light ") + n + " ring " + ring + " on " + surface + ": " + ratio(ring, surface));
                }
            }
        }
        Appearance.dark = false;
        Appearance.accentSetting = "yellow";
        compare(Appearance.focusRingColor.toString(), Qt.color(Tokens.colorLight.text).toString(), "light yellow: the text colour");
        Appearance.accentSetting = "green";
        compare(Appearance.focusRingColor.toString(), Qt.color(Tokens.colorLight.text).toString(), "light green (ADR-0040 step 1c): the text colour");
        Appearance.accentSetting = "blue";
        compare(Appearance.focusRingColor.toString(), Qt.color(Tokens.colorAccentLight.blue).toString(), "light blue: the accent");
    }

    // A QML colour value (a `color` property or function result, such as Appearance.windowFill) is an object, not a string: the
    // contrast and the focus ring read it like its "#rrggbb" form. The swatch ring of Settings > Appearance relies on it (it fell
    // back to the accent while rgb() parsed strings only: #1F5FCC around the vivid #0167FD disc).
    function test_contrastAndFocusRingAcceptColourValues() {
        const ground = Qt.color(Tokens.colorLight.windowBackground);
        const disc = Qt.color(Tokens.colorSwatch.blue);
        const asString = Accent.contrast(Tokens.colorSwatch.blue, Tokens.colorLight.windowBackground);
        verify(asString > 4, "the blue disc on the light window as strings: " + asString);
        compare(Accent.contrast(disc, ground), asString, "colour values read like their strings");
        compare(Accent.focusRing(disc, ground, Tokens.colorLight.text, Tokens.controlFocusRingMinContrast), disc, "the vivid disc is its own ring");
        const yellow = Qt.color(Tokens.colorSwatch.yellow);
        compare(Accent.focusRing(yellow, ground, Tokens.colorLight.text, Tokens.controlFocusRingMinContrast), Tokens.colorLight.text, "a disc under 3:1 falls back");
    }

    function test_increaseContrastAndTextSizeFollowTheSettings() {
        const base = Tokens.materialBorderOpacity;
        const body = Tokens.typographyBodySize;
        compare(Appearance.colors.textSecondary, Tokens.colorDark.textSecondary);
        Appearance.increaseContrast = true;
        verify(Tokens.materialBorderOpacity > base * 2, "borders are stronger");
        compare(Appearance.colors.textSecondary, Tokens.colorDark.text);
        Appearance.increaseContrast = false;
        compare(Tokens.materialBorderOpacity, base);
        Appearance.textScale = 1.3;
        compare(Tokens.typographyBodySize, Math.round(body * 1.3));
        verify(Tokens.typographyCaptionSize > 11);
        compare(Tokens.typographyMenuSize, 13, "the menu bar and menus keep their size");
        Appearance.textScale = 1;
        compare(Tokens.typographyBodySize, body);
    }

    function test_accessibilityKeysValidate() {
        compare(Store.validate("accessibility.increaseContrast", true), "");
        verify(Store.validate("accessibility.increaseContrast", "yes") !== "");
        compare(Store.validate("accessibility.textSize", 1.2), "");
        verify(Store.validate("accessibility.textSize", 0.5) !== "");
        verify(Store.validate("accessibility.textSize", 2) !== "");
        compare(Store.DEFAULTS["accessibility.textSize"], 1);
    }

    function test_textHighlightColour() {
        // accent.highlight (macOS 27 Text highlight colour): Automatic follows the accent; a name keeps its colour whatever the
        // accent is; anything else reads as Automatic.
        Appearance.dark = false;
        Appearance.accentSetting = "purple";
        Appearance.highlightSetting = "automatic";
        const accent = Qt.color(Appearance.colors.accent).toString();
        compare(Appearance.highlight.toString(), accent);
        compare(Appearance.highlightText.toString(), Qt.color(Appearance.colors.accentText).toString());
        Appearance.highlightSetting = "orange";
        compare(Appearance.highlight.toString(), Qt.color(Tokens.colorAccentLight.orange).toString());
        compare(Appearance.highlightText.toString(), Qt.color(Tokens.colorAccentLight.orangeText).toString());
        compare(Qt.color(Appearance.colors.accent).toString(), accent, "the accent stays");
        Appearance.dark = true;
        compare(Appearance.highlight.toString(), Qt.color(Tokens.colorAccentDark.orange).toString());
        Appearance.highlightSetting = "Orange";
        compare(Appearance.highlight.toString(), Qt.color(Appearance.colors.accent).toString(), "an unknown name is Automatic");
        compare(Accent.normalizeHighlight("multicolor"), "automatic");
        for (const n of ["automatic", "blue", "graphite"])
            compare(Store.validate("accent.highlight", n), "", n);
        for (const n of ["", "Automatic", "multicolor", "#ff0000"])
            verify(Store.validate("accent.highlight", n) !== "", n);
        compare(Store.DEFAULTS["accent.highlight"], "automatic");
        Appearance.highlightSetting = "automatic";
        Appearance.accentSetting = "multicolor";
    }

    function test_settingsValidation() {
        for (const n of Accent.NAMES)
            compare(Store.validate("accent.color", n), "", n);
        verify(Store.validate("accent.color", "Blue") !== "");
        verify(Store.validate("accent.color", "#4fb36b") !== "");
        verify(Store.validate("accent.color", 3) !== "");
        compare(Store.DEFAULTS["accent.color"], "multicolor");
        // Parity: the Settings rule accepts exactly the names of Accent.js.
        for (const n of ["", "multicolour", "Graphite"])
            verify(Store.validate("accent.color", n) !== "", n);
    }
}
