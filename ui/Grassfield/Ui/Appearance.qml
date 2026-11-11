pragma Singleton
import QtQuick

// Appearance state shared by every Grassfield surface. The shell (or an app) feeds
// the user-facing settings in; surfaces only read the derived values below.
QtObject {
    // User settings (set by the host).
    property bool dark: true
    // Set by the first icon effect whose shader fails to load: no other icon creates an effect item then (the plain icon is
    // drawn, and Qt logs the failure once, not once per icon).
    property bool iconShaderBroken: false
    property real transparency: Tokens.materialDefaultTransparency
    property bool reduceTransparency: false
    property bool reduceMotion: false
    // Increase Contrast (Settings > Accessibility > Display): stronger borders and separators (the tokens that carry an
    // `increaseContrast` value), secondary text in the primary colour.
    property bool increaseContrast: false
    // Text size multiplier (1 to 1.3, Settings > Accessibility > Display): the tokens marked `textScale` follow it.
    property real textScale: 1
    // An opaque app window (Settings, Files): the window's own background and a lighter secondary text replace the
    // material's tint and the A2-darkened secondary text (those are for text over a blurred wallpaper). The shell never sets it.
    property bool windowSurface: false
    // Icon appearance (ADR-0014): default | dark | clear | tinted, and the tint setting ("accent" or "#rrggbb").
    property string iconMode: "default"
    property string iconTintSetting: "accent"
    // Folder colour (`icons.folderColor`): "theme" (the icon theme's own), "accent" or "#rrggbb".
    property string folderColorSetting: "theme"
    // Accent colour (`accent.color`): "multicolor" (the Grassfield green) | blue | purple | pink | red | orange | yellow | green | graphite.
    property string accentSetting: "multicolor"
    // Text highlight colour (`accent.highlight`): "automatic" (the accent) or an accent name (Accent.highlight).
    property string highlightSetting: "automatic"
    // How menus label keyboard shortcuts: "pc" (the text, "Ctrl+Shift+N") or "mac" (the macOS symbols). Set by the host from
    // `keyboard.shortcutStyle` and the device (MenuShortcut.style).
    property string shortcutStyle: "pc"

    // A sample app icon (an SVG shipped with this module) for the icon appearance previews: it goes through the same
    // TintedIcon pipeline as every icon.
    readonly property url iconSampleSource: Qt.resolvedUrl("samples/icon-sample.svg")

    // Derived values.
    // Tint of the Tinted icon mode: the chosen colour, the accent by default.
    readonly property color iconTint: IconModes.tintColor(iconTintSetting, colors.accent)
    // Colour of folder icons for the global setting (the accent for "accent"); only meaningful when it recolours.
    readonly property color folderTint: FolderStyle.colorOf(folderColorSetting, colors.accent)
    // Reduce Transparency is equivalent to transparency 0 (opaque tinted surfaces).
    readonly property real effectiveTransparency: reduceTransparency ? 0 : clamp01(transparency)
    // Hairline alpha: the light appearance uses a lighter line (F1 gap 18).
    readonly property real separatorOpacity: dark ? Tokens.materialSeparatorOpacity : Tokens.materialSeparatorOpacityLight
    // Control fill alpha (push button, field, segmented track, unchecked box): the light appearance draws a light grey, not a
    // dark well (ADR-0024).
    readonly property real fillOpacity: dark ? Tokens.materialFillOpacity : Tokens.materialFillOpacityLight
    readonly property var colors: devGlyphMode !== "" ? glyphColors(baseColors) : baseColors
    // The palette of the appearance with the chosen accent applied (accent and accentText), live.
    readonly property var baseColors: dark ? accentedDark : accentedLight
    // Both carry `selection` and `selectionText`: the fill and the text of a selected row, a default button or a checked box,
    // white on the accent in both appearances (Accent.selectionPair).
    readonly property var accentedDark: Accent.withSelection(Accent.contrastBoost(Accent.apply(Tokens.colorDark, accentSetting, true, Tokens), increaseContrast), Accent.selectionPair(accentSetting, true, accentedLightBase, Tokens))
    readonly property var accentedLight: Accent.withSelection(Accent.contrastBoost(accentedLightBase, increaseContrast), Accent.selectionPair(accentSetting, false, accentedLightBase, Tokens))
    readonly property var accentedLightBase: Accent.apply(Tokens.colorLight, accentSetting, false, Tokens)
    // The keyboard focus ring: the accent, or the text colour where the accent does not hold 3:1 against the material (Accent.focusRing).
    readonly property color focusRingColor: Accent.focusRing(baseColors.accent, windowSurface ? baseColors.windowBackground : baseColors.materialTint, baseColors.text, Tokens.controlFocusRingMinContrast)
    // Control fills (audit 2026-10-25, priority 6). Dark appearance: the translucent fill of the material, as before. Light
    // appearance (macOS): chips white, secondary push buttons about 6 % grey, wells (the Apps field, Force Quit list, Overview add
    // button) white and translucent, none with a dark stroke.
    readonly property color chipFill: dark ? withAlpha(colors.fill, Tokens.materialFillOpacity) : withAlpha(colors.chipFill, Tokens.materialChipFillOpacityLight)
    readonly property color buttonFill: withAlpha(colors.fill, fillOpacity)
    readonly property color lightWellFill: withAlpha(colors.chipFill, Tokens.materialWellFillOpacityLight)

    // The fill that app windows draw as their own background (Settings, Files: `windowSurface`); the shell's materials, and the
    // menus, sheets, tooltips and combo popups that Grassfield.Ui draws in an app, keep `colors.materialTint` (ADR-0024 lot 1).
    readonly property color windowFill: windowSurface ? colors.windowBackground : colors.materialTint

    // A window that is not key (ADR-0039 step 17, measured on macOS 27): its selection turns neutral (the hover ink at
    // inactiveSelectionOpacity over its background, the label in the text colour), its toolbar title and glyphs dim (the text
    // colour at inactiveTextOpacity). Read with looksKey(item.Window.window, item.Window.active).
    readonly property real inactiveSelectionOpacity: dark ? Tokens.windowInactiveSelectionOpacityDark : Tokens.windowInactiveSelectionOpacityLight
    readonly property real inactiveTextOpacity: dark ? Tokens.windowInactiveTextOpacityDark : Tokens.windowInactiveTextOpacityLight
    // A selected row, cell or icon of a CONTENT view (list, columns, icons, gallery, processes) that is not focused, or whose
    // window is not key: one neutral fill in every app (UI audit 2026-11-05 U16; macOS's unemphasized content selection). The
    // label keeps the text colour. A sidebar keeps inactiveSelectionOpacity.
    readonly property color unemphasizedSelection: withAlpha(colors.hover, dark ? Tokens.windowUnemphasizedSelectionOpacityDark : Tokens.windowUnemphasizedSelectionOpacityLight)
    // The window that keeps its key look while a shell menu or the Control Center holds the keyboard (the integrator's macOS
    // decision on #88, ADR-0039 step 17): the compositor then withdraws the window's activation, but only another window
    // taking the focus makes it inactive. Set by the app from the shell's key-window file (apps/keywindow.h); null otherwise.
    property var heldKeyWindow: null

    // Whether a window draws as key: `active` (its Window.active), or it is the window held above.
    function looksKey(window: var, active: bool): bool {
        return active || (!!window && window === heldKeyWindow);
    }

    // The colour of a glyph by default: inside a ToolButton, its `glyphColor` (the button dims the glyph in its colour), anywhere
    // else the text colour. `item` is the glyph.
    function glyphTint(item: var): color {
        for (let p = item.parent; p; p = p.parent) {
            if (p.glyphColor !== undefined)
                return p.glyphColor;
        }
        return colors.text;
    }

    // Secondary text drawn directly on the opaque window surface or on its group fill (Settings): the lighter app-only grey, as
    // macOS. Text on a field, tab or chip fill keeps `colors.textSecondary`, which holds 4.5:1 on those fills (A2); outside an
    // app window this is textSecondary, and Increase Contrast makes it the primary text colour.
    readonly property color windowSecondary: increaseContrast ? colors.text : (windowSurface ? colors.windowTextSecondary : colors.textSecondary)

    // The dark palette for surfaces that are always dark (Apps), hooked like `colors`.
    readonly property var darkColors: devGlyphMode !== "" ? glyphColors(accentedDark) : accentedDark
    // The light palette for surfaces that are always light (the menu bar's dark foreground over a light wallpaper), hooked like `colors`.
    readonly property var lightColors: devGlyphMode !== "" ? glyphColors(accentedLight) : accentedLight
    // Highlight colour (text selection, Automatic as on macOS): it follows the accent.
    readonly property var highlightPair: Accent.highlight(highlightSetting, dark, colors, Tokens)
    readonly property color highlight: highlightPair.highlight
    readonly property color highlightText: highlightPair.highlightText

    // Dev-only hook for tests/visual (contrast glyph mask; set by the shell's `visual glyphs <mode>` IPC, which is
    // refused outside GRASSFIELD_DEV; always "" in production). Every text and icon colour (text, textSecondary,
    // accentText) is replaced by a marker colour: "hidden" (fully transparent), "white" or "black" (opaque, one
    // unit off pure). withAlpha() leaves a marker colour alone, so label opacity tokens cannot undo it.
    // Material, outlines and shadows around text are unchanged.
    property string devGlyphMode: ""

    readonly property var glyphMarkers: ({hidden: "#00010203", white: "#fffffe", black: "#000001"})

    function glyphColors(base: var): var {
        const c = Object.assign({}, base);
        const m = glyphMarkers[devGlyphMode];
        c.text = m;
        c.textSecondary = m;
        c.accentText = m;
        c.selectionText = m;
        c.fieldText = m;
        c.barText = m;
        c.indicator = m;
        c.destructiveText = m;
        return c;
    }

    function isGlyphMarker(color: color): bool {
        const r = Math.round(color.r * 255);
        const g = Math.round(color.g * 255);
        const b = Math.round(color.b * 255);
        return (r === 1 && g === 2 && b === 3) || (r === 255 && g === 255 && b === 254) || (r === 0 && g === 0 && b === 1);
    }

    // First installed family of the token list (Qt has no per-font fallback list in QML).
    readonly property string fontFamily: Qt.fontFamilies().indexOf(Tokens.typographyFamily) !== -1 ? Tokens.typographyFamily : Tokens.typographyFallbackFamily
    // Inter Display from typography.displayFrom (20) px (ADR-0003 O1, T-1: where the reference's typeface switches to its
    // display cut); the text family below, and when the display cut is not installed.
    readonly property string displayFamily: Qt.fontFamilies().indexOf(Tokens.typographyDisplayFamily) !== -1 ? Tokens.typographyDisplayFamily : fontFamily

    function fontFamilyFor(pixelSize: real): string {
        return pixelSize >= Tokens.typographyDisplayFrom ? displayFamily : fontFamily;
    }
    readonly property var curve: Tokens.motionCurveStandard
    // One curve per role (ADR-0039 step 20): `curve` moves, `curveEnter` arrives, `curveExit` leaves (the compositor's windows
    // and layers on the same curves, looknfeel.lua), `curvePanel` carries a panel or a sheet over motion.panel (Apple's default
    // spring as a stand-in, Q6).
    readonly property var curveEnter: Tokens.motionCurveEnter
    readonly property var curveExit: Tokens.motionCurveExit
    readonly property var curvePanel: Tokens.motionCurvePanel

    // Size-dependent tracking of Inter's "dynamic metrics" (the reference's optical tracking): em = a + b * e^(c * px),
    // returned in pixels for Text.font.letterSpacing. Larger text is set tighter, small text slightly looser.
    function tracking(pixelSize: real): real {
        return (Tokens.typographyTrackingA + Tokens.typographyTrackingB * Math.exp(Tokens.typographyTrackingC * pixelSize)) * pixelSize;
    }

    // Tracking for the family fontFamilyFor picks: Inter Display carries its own display spacing (none added).
    function trackingFor(pixelSize: real): real {
        return pixelSize >= Tokens.typographyDisplayFrom && displayFamily === Tokens.typographyDisplayFamily ? 0 : tracking(pixelSize);
    }

    function clamp01(v: real): real {
        return Math.max(0, Math.min(1, v));
    }

    // Tint opacity of the material: 1 at transparency 0, tintAlphaMin at transparency 1, linear in between, except that the
    // A2 clamp keeps it at or above tintAlphaClamp up to transparency tintClampUntil (the default 0.25 is above it, so the
    // frosted default is unclamped). Past tintClampUntil it falls linearly from the clamp value to tintAlphaMin.
    function tintAlpha(t: real): real {
        const x = clamp01(t);
        const linear = 1 - x * (1 - Tokens.materialTintAlphaMin);
        const until = Tokens.materialTintClampUntil;
        if (x <= until)
            return Math.max(linear, Tokens.materialTintAlphaClamp);
        return Tokens.materialTintAlphaClamp + (Tokens.materialTintAlphaMin - Tokens.materialTintAlphaClamp) * (x - until) / (1 - until);
    }

    // Adaptive glass (ADR-0024 section 2, G-1 to G-3): {output name: {lumMin, lumMax, grid}} for an output that shows the bare
    // desktop (no window on its active workspace) over a wallpaper of known luminance, fed by the shell; `grid` (optional,
    // GlassTint.gridRange) narrows the range to what lies under one surface. On any other output the backdrop is unknown and a
    // class takes the worst case.
    property var backdrops: ({})
    readonly property var glassTargets: ({menu: Tokens.glassMenu, notification: Tokens.glassNotification, controls: Tokens.glassControls, apps: Tokens.glassApps, gallery: Tokens.glassGallery, widgets: Tokens.glassWidgets})

    // Tint alpha of a glass class at transparency t on an output (GlassTint.alpha): the class target at the default slider,
    // raised to keep the text and secondary text of the appearance at 4.5:1 over that output's backdrop, or over the part of it
    // under `rect` (output px; optional) when the output's luminance grid is known.
    function glassAlpha(glassClass: string, t: real, screenName: string, rect: var): real {
        const known = backdrops[screenName] ?? null;
        const under = known && known.grid ? GlassTint.gridRange(known.grid, rect, Tokens.glassBackdropPad) : null;
        return glassAlphaOver(glassClass, t, under ?? known);
    }

    // The effective relative luminance of a nearly clear glass of `alpha` over the backdrop under `rect` (output px) on an output: its tint over the middle of the luminance range the shell
    // measured there (the same grid as glassAlpha), or -1 when the output's backdrop is unknown (a window below, a video): the caller then follows the system appearance (IconModes.surfaceLuma).
    function surfaceLuma(screenName: string, rect: var, alpha: real): real {
        const known = backdrops[screenName] ?? null;
        if (!known)
            return -1;
        const under = known.grid ? GlassTint.gridRange(known.grid, rect, Tokens.glassBackdropPad) : null;
        return surfaceLumaOver(under ?? known, alpha);
    }

    // The same over a luminance range the caller already has ({lumMin, lumMax}, e.g. Backdrop.wallpaperUnder for a surface that always lies on the wallpaper); -1 for null.
    function surfaceLumaOver(range: var, alpha: real): real {
        const tintLuma = GlassTint.luminance(GlassTint.channels(colors.materialTint));
        // An opaque shelf (Reduce Transparency) is its own tint whatever lies behind it.
        if (alpha >= 1)
            return tintLuma;
        if (!range || typeof range.lumMin !== "number" || typeof range.lumMax !== "number")
            return -1;
        return IconModes.surfaceLuma((range.lumMin + range.lumMax) / 2, tintLuma, alpha);
    }

    // The tint alpha a Material draws when a host fixes it (tintAlphaOverride, the Dock's shelf): the override while the surface is not opaque, the slider's own alpha otherwise
    // (Reduce Transparency: opaque), then frosted by Increase Contrast (Material.baseTintAlpha and tintAlpha, for a glass class of ""). `transparency`: Appearance.effectiveTransparency.
    function fixedTintAlpha(override: real, transparency: real): real {
        return frosted(override >= 0 && transparency > 0 ? override : tintAlpha(transparency));
    }

    // Increase Contrast frosts every glass surface (ADR-0024 G-8): a tint alpha raised to glass.contrastFrost.
    function frosted(a: real): real {
        return increaseContrast ? Math.max(Tokens.glassContrastFrost, a) : a;
    }

    // The tint alpha of a small glass piece with no blur under it (a close capsule over a card's corner): its own alpha,
    // opaque when the glass is (Reduce Transparency, or the slider at opaque), frosted by Increase Contrast (ADR-0039 step 22).
    function fixedGlassAlpha(a: real): real {
        return effectiveTransparency <= 0 ? 1 : frosted(a);
    }

    // The same over a backdrop range the host knows ({lumMin, lumMax}; null = the worst case, black to white).
    function glassAlphaOver(glassClass: string, t: real, backdrop: var): real {
        const target = glassTargets[glassClass];
        if (target === undefined)
            return tintAlpha(t);
        return GlassTint.alpha(target, t, Tokens.materialDefaultTransparency, backdrop, colors.materialTint, [colors.text, colors.textSecondary], colors.fill, Tokens.materialFillOpacity, Tokens.glassContrastMargin);
    }

    // Adaptive tone of a glass band over a backdrop range the host measured (ADR-0024 point 3, the menu bar: macOS 26's glass
    // follows what lies behind it, not the system appearance). `darkGlass` is the host's choice of tone (the bar's own: the text
    // tone with the better worst case over the strip, BarTone): dark glass with light text, or light glass with dark text;
    // the alpha is the class tint raised to what keeps that text legible over the range in every state of the bar (rest,
    // the open title's capsule, dimmed). The bar carries primary text and glyphs only, so only the primary text is judged. Returns {dark, alpha, colors}; Reduce Transparency (t <= 0)
    // and an unknown range keep the appearance's own colours and the standard glass alpha.
    function glassBand(glassClass: string, t: real, backdrop: var, darkGlass: bool): var {
        const target = glassTargets[glassClass];
        if (t <= 0 || !backdrop || target === undefined)
            return {dark: dark, alpha: glassAlphaOver(glassClass, t, backdrop), colors: colors};
        const palette = darkGlass ? darkColors : lightColors;
        // The states the band can show (GlassTint.bandAlpha): at rest, under the open title's capsule at its real fill, dimmed.
        const alpha = GlassTint.bandAlpha(target, t, Tokens.materialDefaultTransparency, backdrop, palette.materialTint, palette.text, palette.hover, Tokens.materialHoverOpacity * Tokens.materialHoverActiveFactor, Tokens.menubarInactiveOpacity, 4.5, 3, Tokens.glassContrastMargin);
        return {dark: darkGlass, alpha: alpha, colors: palette};
    }

    // The foreground of the menu bar, {text, hover}: over the band the band's own palette (its tone), or the appearance's when
    // the band has no strip to adapt to; without a band the bar sits on the wallpaper and follows the wallpaper's tone.
    function barForeground(showBackground: bool, band: var, darkTone: bool): var {
        if (!showBackground) {
            const p = darkTone ? lightColors : darkColors;
            return {text: p.barText, hover: p.hover};
        }
        const c = band ? band.colors : colors;
        return {text: c.text, hover: c.hover};
    }

    // The menu bar's band for the strip under it, or null when there is none to judge it on: no range (the artwork, a colour, a
    // bar that overlaps windows or a full-screen window) or Reduce Transparency (the appearance's own opaque material).
    function barBand(range: var, darkGlass: bool): var {
        if (!range || effectiveTransparency <= 0)
            return null;
        return glassBand("menu", effectiveTransparency, range, darkGlass);
    }

    // Compositor blur follows the transparency (GF-125, docs/specs/ui.md "Material blur"): Hyprland carries one blur size and
    // pass count for every surface (ext-background-effect and layer rules take no per-surface strength), so the shell asks
    // for the value of the current transparency. Linear from blurSizeMin (0+) to blurSizeMax (1), 18 at the default 0.25.
    function blurSize(t: real): int {
        return Math.round(Tokens.materialBlurSizeMin + (Tokens.materialBlurSizeMax - Tokens.materialBlurSizeMin) * clamp01(t));
    }

    function blurPasses(t: real): int {
        return clamp01(t) < Tokens.materialBlurPassesFrom ? Tokens.materialBlurPassesLight : Tokens.materialBlurPassesFull;
    }

    // What the compositor is asked for now (Reduce Transparency: opaque surfaces request no blur; the minimum is kept).
    readonly property int compositorBlurSize: blurSize(effectiveTransparency)
    readonly property int compositorBlurPasses: blurPasses(effectiveTransparency)

    // Animation duration: Reduce Motion caps every animation at reducedMax (crossfade).
    function duration(ms: real): real {
        return reduceMotion ? Math.min(ms, Tokens.motionReducedMax) : ms;
    }

    // Accent controls in a window that is not key (UI audit 2026-11-05 U17, macOS 27): inside an app window (windowSurface) an on
    // switch, a checked box or radio button, the default button, a slider's fill and a prominent selected segment draw the accent
    // only while their window looks key; otherwise they turn neutral (inactiveFill, or their plain look). The shell's glass
    // surfaces keep the accent. Read with accentShown(item.Window.window, item.Window.active).
    function accentShown(window: var, active: bool): bool {
        return !windowSurface || looksKey(window, active);
    }
    readonly property real inactiveFillOpacity: dark ? Tokens.controlInactiveFillOpacityDark : Tokens.controlInactiveFillOpacity
    readonly property color inactiveFill: withAlpha(colors.fill, inactiveFillOpacity)

    // One disabled look (UI audit 2026-11-05 U18): a disabled control dims itself (material.disabledOpacity) unless a disabled
    // container around it is drawn dimmed already (an opacity below 1: Settings' blocked pane), so nothing dims twice. Only the
    // disabled ancestors are read, up to the first enabled one.
    function dimsDisabled(item: var): bool {
        if (!item || item.enabled)
            return false;
        for (let p = item.parent; p && !p.enabled; p = p.parent) {
            if (p.opacity < 1)
                return false;
        }
        return true;
    }

    function withAlpha(color: color, alpha: real): color {
        if (devGlyphMode !== "" && isGlyphMarker(color))
            return color;
        return Qt.alpha(color, alpha);
    }
}
