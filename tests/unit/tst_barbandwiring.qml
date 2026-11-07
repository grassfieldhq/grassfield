import QtQuick
import QtTest

// The wiring of the menu bar's band that no pure function carries (ADR-0024 point 3, ADR-0016 D1), read from the sources the way
// tests/unit/tst_barhide.qml reads the schema: what the bar draws, and what the shell writes for Settings.
TestCase {
    name: "BarBandWiring"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText.replace(/\/\/.*$/gm, "");
    }

    function has(text, needle, why) {
        verify(text.indexOf(needle) >= 0, why + ": `" + needle + "` missing");
    }

    function test_menuBarDrawsTheBandFromTheStripAndItsTone() {
        const bar = source("shell/menubar/MenuBar.qml");
        // Judged on the wallpaper only when nothing lies under the bar (the full-screen and overlap fallback).
        has(bar, "BarHide.bandOnWallpaper(win.hideMode, win.fullscreen) ? BarTone.rangeOf(win.screen.name) : null", "band range");
        // The tone mapping and Reduce Transparency both live in the tested functions the bar must call.
        has(bar, "Appearance.barBand(bandRange, BarTone.bandDarkOf(win.screen.name))", "band");
        // The text, hover tint and tint of the band are the band's own, not the appearance's.
        has(bar, "Appearance.barForeground(showBackground, band, darkTone)", "foreground");
        has(bar, "barText: foreground.text", "band text");
        has(bar, "barTint: foreground.hover", "band hover");
        // Every text and glyph of the bar takes win.barText (the logo, the app name, the menus, the status items, the clock):
        // none is drawn in the appearance's own colour.
        verify(bar.indexOf("Appearance.colors.text") < 0, "a bar item draws in the appearance's text colour");
        verify((bar.match(/color: win\.barText/g) || []).length >= 10, "the bar's items use win.barText");
        has(bar, "tintColor: win.band ? win.band.colors.materialTint : Appearance.colors.materialTint", "band tint colour");
        has(bar, "tintAlphaOverride: win.bandAlpha", "band alpha");
        has(bar, 'glassClass: "menu"', "glass class");
    }

    // Owner 2026-11-07, "the translucent menu bar is not translucent on every display": without a measured strip the band took
    // Appearance's backdrop of its output, known only while that output shows no window, so every display with a window open drew
    // it at the worst case. The band's backdrop is the wallpaper under the bar whenever the bar keeps its strip, whatever windows
    // lie below it; the bare-desktop rule stays for the glass that can lie over windows.
    function test_bandWithoutAMeasuredStripTakesTheWallpaperUnderTheBar() {
        const bar = source("shell/menubar/MenuBar.qml");
        has(bar, "readonly property var wallpaperStrip: BarHide.bandOnWallpaper(win.hideMode, win.fullscreen) ? Backdrop.wallpaperUnder(win.screen.name, Qt.rect(0, 0, win.width, Tokens.menubarHeight)) : null", "the strip");
        has(bar, 'readonly property real bandAlpha: win.band ? win.band.alpha : (win.wallpaperStrip ? Appearance.glassAlphaOver("menu", Appearance.effectiveTransparency, win.wallpaperStrip) : -1)', "its alpha");
        const backdrop = source("shell/services/Backdrop.qml");
        has(backdrop, "return GlassTint.wallpaperUnder(root.wallpapers[output] ?? null, root.grids[output] ?? null, rect, Tokens.glassBackdropPad);", "the wallpaper, not the bare outputs");
        // The glass that can lie over windows keeps the bare-desktop rule.
        has(backdrop, "const bare = Compositor.bareOutputs;", "known");
    }

    function test_materialTintColorDefaultsToTheAppearance() {
        const m = source("ui/Grassfield/Ui/Material.qml");
        has(m, "property color tintColor: Appearance.colors.materialTint", "tintColor default");
        has(m, "Appearance.withAlpha(root.tintColor, root.tintAlpha)", "the fill uses it");
    }

    function test_theStatusFileCarriesTheBarBlockAndIsAtomic() {
        const w = source("shell/services/WallpaperState.qml");
        has(w, "JSON.stringify({outputs: root.outputs, online: root.online, bar: root.barAssists()}", "bar block");
        has(w, "return BarTone.forcedOutputs()", "bar block source");
        has(w, "function onAssistsChanged()", "rewritten when the assist changes");
        const i = w.indexOf("id: statusWriter");
        verify(i > 0);
        const block = w.substring(i, w.indexOf("}", i));
        has(block, "atomicWrites: true", "status writer");
    }

    function test_anUnmeasuredMediaClearsTheAssistAndTheRange() {
        const t = source("shell/services/BarTone.qml");
        const i = t.indexOf("function reportUnmeasured");
        verify(i > 0);
        const body = t.substring(i, t.indexOf("\n    }", i));
        has(body, "setAssist(output, false)", "reportUnmeasured");
        has(body, "setRange(output, null)", "reportUnmeasured");
        const wp = source("shell/desktop/Wallpaper.qml");
        has(wp, 'source === "none"', "Wallpaper dispatch");
        has(wp, "BarTone.reportUnmeasured(win.modelData.name)", "Wallpaper dispatch");
    }
}
