import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/menubar/ClockFormat.js" as Clock

// Values of the visual audit 2026-10-25 (docs/audits/visual-tahoe-2026-10-25.md, "Priorities" 1-7): the measured macOS
// numbers the tokens now carry, and the geometry derived from them. A change here is a design decision, not a refactor.
TestCase {
    name: "VisualAudit"

    // Priority 1: the plain menu text inset is menu padding + item padding (the audit measured 16, there were 37 to 38).
    function test_menuTextInsetWithoutSlot() {
        const inset = Tokens.menuPadding + Tokens.menuItemPadding;
        verify(inset >= 15 && inset <= 16);
        verify(inset + Tokens.menuIconSize + Tokens.spacingSm >= 37);
    }

    // Priority 2: Search rows; since the owner's decision of 2026-10-26 the macOS 27 layout (docs/audits/ui-finesse-2026-10-25/
    // f1-macos27.md § Search): 63-pt rows in a results panel under the search capsule, the text 80 in.
    function test_searchRowMetrics() {
        compare(Tokens.searchTitleSize, 17);
        compare(Tokens.searchSubtitleSize, 15);
        compare(Tokens.searchRowTextInset, 80);
        compare(Tokens.searchRowRadius, 18);
        compare(Tokens.searchRowInset, 12);
        compare(Tokens.searchRowHeight, 63);
        // Two lines of the row type fit the row.
        verify(Tokens.searchTitleSize * 1.2 + Tokens.searchSubtitleSize * 1.2 < Tokens.searchRowHeight);
        // The icon ends before the text starts, with a gap.
        const iconEnd = Tokens.searchRowIconInset + Tokens.searchRowIconSize;
        verify(Tokens.searchRowTextInset - iconEnd >= Tokens.spacingMd);
        // The query starts after the glyph of the capsule.
        verify(Tokens.searchCapsuleTextInset >= Tokens.searchCapsuleGlyphInset + Tokens.searchCapsuleGlyph);
    }

    // Priority 3: notifications. Cards 6 apart, banners start at the column's top, equal 22-pt capsules.
    function test_notificationMetrics() {
        compare(Tokens.notificationBannerGap, 6);
        compare(Tokens.notificationActionHeight, 22);
        verify(Tokens.notificationCenterInset >= Tokens.notificationBannerGap);
    }

    // Priority 5: Dock. No band under the icons, the dot inside the padding with its centre 6 above the shelf edge (macOS 27,
    // docs/audits/ui-finesse-2026-10-25/f1-macos27.md § Dock; macOS 26 read 5).
    function test_dockMetrics() {
        compare(Tokens.dockIndicatorArea, 0);
        verify(Tokens.dockIndicatorGap >= 0 && Tokens.dockIndicatorGap + Tokens.dockIndicatorSize <= Tokens.dockPadding);
        compare(Tokens.dockPadding - Tokens.dockIndicatorGap - Tokens.dockIndicatorSize / 2, 6);
        verify(Tokens.dockSeparatorSpace > 2 * Tokens.dockSpacing + Tokens.dockSeparatorWidth);
        verify(Tokens.dockSeparatorOpacity >= 0.25);
        // The room above the shelf holds the label (24 + 7 tail) and the 8-pt gap to the shelf.
        verify(Tokens.dockTooltipArea >= 24 + 7 + Tokens.dockTooltipGap);
    }

    // Priority 6: light controls on light glass. White chips and wells, a 6 % grey secondary button, and the dark appearance
    // keeps the material fill.
    function test_lightControlFills() {
        const dark = Appearance.dark;
        Appearance.dark = false;
        // White chips: the warm white #FDFCF9 since the owner's warm neutrals of 2026-10-30 (ADR-0040).
        compare(Appearance.chipFill.r, Qt.color(Tokens.colorLight.chipFill).r);
        fuzzyCompare(Appearance.chipFill.r, 1, 0.01);
        fuzzyCompare(Appearance.chipFill.a, Tokens.materialChipFillOpacityLight, 0.01);
        fuzzyCompare(Appearance.buttonFill.a, Tokens.materialFillOpacityLight, 0.01);
        verify(Appearance.buttonFill.r < 0.1);
        fuzzyCompare(Appearance.lightWellFill.a, Tokens.materialWellFillOpacityLight, 0.01);
        verify(Tokens.materialFillOpacityLight <= 0.08);
        Appearance.dark = true;
        fuzzyCompare(Appearance.chipFill.a, Tokens.materialFillOpacity, 0.01);
        fuzzyCompare(Appearance.buttonFill.a, Tokens.materialFillOpacity, 0.01);
        Appearance.dark = dark;
    }

    // Priority 8: Quick Settings. The glyph in a disk is about 20 (macOS), a 1x1 module is a circle one cell wide.
    function test_quickSettingsMetrics() {
        compare(Tokens.quicksettingsDiskGlyph, 20);
        verify(Tokens.quicksettingsDiskGlyph < Tokens.quicksettingsIconDisk);
        // A circle module (cols 1, rows 1) is rounded to a full circle by Module's radius rule (height <= cell).
        verify(Tokens.quicksettingsCell > 0);
    }

    // Priority 9: Apps; since the owner's decision of 2026-10-26 the macOS 27 layout (docs/audits/ui-finesse-2026-10-25/
    // f1-macos27.md § Apps): a 520 x 85 search capsule 11 above the panel, the panel starts with 26-pt chips 20 below its top,
    // the first icon row about 34 under the chips.
    function test_appsHeaderMetrics() {
        compare(Tokens.searchCapsuleWidth, 520);
        compare(Tokens.searchCapsuleHeight, 85);
        compare(Tokens.searchCapsuleGap, 11);
        compare(Tokens.launcherChipsTop, 20);
        compare(Tokens.launcherChipHeight, 26);
        // The gap to the grid and the grid's own top margin (spacing.sm): about 34 to the first icon.
        const toIcons = Tokens.launcherGridGap + Tokens.spacingSm;
        verify(toIcons >= 30 && toIcons <= 42, String(toIcons));
    }

    // Priority 10, ADR-0024 lot 1: the Settings sidebar is a floating panel since the 2026-11-03 amendment (10 pt inset for the selection, 32-pt rows, 20-pt tiles); Files rows 32.
    function test_sidebarMetrics() {
        compare(Tokens.settingsSidebarInset, 10);
        compare(Tokens.settingsSidebarItemHeight, 32);
        compare(Tokens.settingsSidebarIconSize, 20);
        verify(Tokens.settingsSidebarGlyphSize < Tokens.settingsSidebarIconSize);
        compare(Tokens.filesSidebarItemHeight, 32);
        verify(Tokens.settingsSidebarItemRadius > Tokens.radiusControl);
    }

    // Priority 11: toolbar capsules are 36 pt; two 34-pt buttons make the 72-pt back/forward capsule.
    function test_toolbarCapsules() {
        compare(Tokens.toolbarCapsule, 36);
        compare(2 * Tokens.toolbarGroupButton + Tokens.spacingXs, 72);
        verify(Tokens.filesSearchWidth >= 180);
    }

    // Priority 12: Overview. The wallpaper is not dimmed (macOS 27, docs/audits/ui-finesse-2026-10-25/f1-macos27.md § Mission
    // Control; macOS 26 read about 0.1), a desktop is a miniature of its windows.
    function test_overviewMetrics() {
        compare(Tokens.overviewBackdropOpacity, 0);
        // Reduce Transparency keeps its opaque dim.
        verify(Tokens.overviewBackdropOpacityOpaque > 0.8);
        verify(Tokens.overviewMiniMaxWindows >= 4);
        verify(Tokens.overviewMiniIconScale > 0 && Tokens.overviewMiniIconScale < 1);
    }

    function readFile(url) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", url, false);
        xhr.send();
        return xhr.responseText;
    }

    // Priority 7: menu bar. 16-pt glyphs with heavier strokes (our own SVGs, icons-bar/ copies of branding/icons/symbolic with
    // only the stroke changed), a wider Wi-Fi glyph, a floating capsule, desktop icons 10 from the edge.
    function test_menuBarMetrics() {
        compare(Tokens.menubarIconSize, 16);
        // The app name starts at 55 and the mark is centred at 27 (macOS): inset + icon + two paddings.
        compare(Tokens.menubarInsetLeft + Tokens.menubarIconSize + 2 * Tokens.menubarItemPadding, 55);
        compare(Tokens.menubarInsetLeft + Tokens.menubarIconSize / 2, 27);
        // The speaker is drawn larger than the others: ink 12-13.5 tall (the drawing is 15/24 of the box).
        const speakerInk = Tokens.menubarIconSize * Tokens.menubarVolumeIconScale * 15 / 24;
        verify(speakerInk >= 12 && speakerInk <= 13.5, String(speakerInk));
        verify(Tokens.menubarIconSize * Tokens.menubarWifiIconScale * 19 / 24 >= 16);
        verify(Tokens.menubarHoverInsetTop >= 1 && Tokens.menubarHoverInsetBottom >= 1);
        compare(Tokens.desktopIconMargin, 10);
    }

    function test_barGlyphsAreTheSameDrawingsWithAHeavierStroke() {
        const names = ["grassfield-logo", "wifi-1", "wifi-2", "wifi-3", "wifi-off", "network-wired", "volume-1", "volume-2", "volume-3", "volume-mute",
            "battery", "battery-charging", "search", "now-playing", "moon", "control-center", "record-stop", "capture-selection"];
        for (const n of names) {
            const base = readFile(Qt.resolvedUrl("../../ui/Grassfield/Ui/icons/" + n + ".svg"));
            const bar = readFile(Qt.resolvedUrl("../../ui/Grassfield/Ui/icons-bar/" + n + ".svg"));
            verify(base.length > 0, n);
            // The symbol set is drawn at stroke 2 (ADR-0003 as amended by ADR-0024 lot 3d), the bar copies at 2.4.
            compare(bar, base.replace(/stroke-width="2"/g, 'stroke-width="2.4"'), n);
        }
    }

    Component {
        id: markImage

        Image {
            sourceSize: Qt.size(96, 96)
        }
    }

    // The Grassfield mark's two files (branding/LICENSES.md, ADR-0040 "Brand"): grassfield-logo is the 16-24 px optical
    // version every place in the UI draws; grassfield-logo-full is the full mark for 32 px and more (the brand kit, the
    // website, future large About surfaces). Nothing in the shell draws the full mark today (IQ-B1 B: dialogs show their
    // subject's symbol), so this is the test that keeps it loadable: both decode with Qt's SVG reader, on the 24 grid, and
    // stay two different drawings.
    function test_markFilesLoad() {
        const dir = "../../ui/Grassfield/Ui/icons/";
        for (const n of ["grassfield-logo", "grassfield-logo-full"]) {
            const img = createTemporaryObject(markImage, null, {source: Qt.resolvedUrl(dir + n + ".svg")});
            verify(img, n);
            tryVerify(() => img.status === Image.Ready || img.status === Image.Error, 3000, n);
            compare(img.status, Image.Ready, n);
            compare(img.implicitWidth, 96, n);
            compare(img.implicitHeight, 96, n);
            verify(readFile(Qt.resolvedUrl(dir + n + ".svg")).indexOf('viewBox="0 0 24 24"') >= 0, n);
        }
        verify(readFile(Qt.resolvedUrl(dir + "grassfield-logo.svg")) !== readFile(Qt.resolvedUrl(dir + "grassfield-logo-full.svg")));
    }

    function test_menuBarClockGap() {
        verify(Tokens.menubarClockGap.length >= 2);
        compare(Clock.join("Sat Oct 17", "09:41", Tokens.menubarClockGap), "Sat Oct 17" + Tokens.menubarClockGap + "09:41");
    }

    // WCAG relative luminance and contrast of two "#rrggbb" colours.
    function lum(hex) {
        const ch = k => {
            const v = parseInt(hex.substr(1 + 2 * k, 2), 16) / 255;
            return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        };
        return 0.2126 * ch(0) + 0.7152 * ch(1) + 0.0722 * ch(2);
    }

    function ratio(a, b) {
        const la = lum(a), lb = lum(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    // Priority 4: opaque windows. White window, an app-only lighter secondary text that still holds 4.5:1 on it (A2 for
    // windows; the material's textSecondary stays for the shell surfaces).
    function test_windowSurfaceColours() {
        // The warm white (the owner's warm neutrals of 2026-10-30, ADR-0040; #FFFFFF before).
        compare(Tokens.colorLight.windowBackground, "#FDFCF9");
        for (const palette of [Tokens.colorLight, Tokens.colorDark]) {
            verify(ratio(palette.windowTextSecondary, palette.windowBackground) >= 4.5, palette.windowTextSecondary);
            verify(ratio(palette.text, palette.windowBackground) >= 7);
        }
        // Lighter than the material's secondary text, which is darker for A2 on the blurred wallpaper (light appearance).
        verify(lum(Tokens.colorLight.windowTextSecondary) > lum(Tokens.colorLight.textSecondary));
    }

    // Dark appearance: the window secondary text is the owner's answer to ADR-0039 Q3 (#A1A1A6, warm as every neutral since
    // ADR-0040: #A4A19C), a step below the material's textSecondary, which read like the titles on the window; the window
    // itself is the neutral grey of ADR-0024 lot 1.
    function test_darkWindowValues() {
        compare(Tokens.colorDark.windowTextSecondary, "#A4A19C");
        verify(lum(Tokens.colorDark.windowTextSecondary) < lum(Tokens.colorDark.textSecondary), "a step below the material's");
        // #292929 warmed (the owner's warm neutrals of 2026-10-30, ADR-0040; the same lightness).
        compare(Tokens.colorDark.windowBackground, "#2B2925");
    }

    // Search rows follow Accessibility > Text Size like every other text.
    function test_searchTextFollowsTheTextSize() {
        const saved = Appearance.textScale;
        Appearance.textScale = 1;
        compare(Tokens.searchTitleSize, 17);
        compare(Tokens.searchSubtitleSize, 15);
        Appearance.textScale = 1.3;
        compare(Tokens.searchTitleSize, 22);
        compare(Tokens.searchSubtitleSize, 20);
        verify((Tokens.searchTitleSize + Tokens.searchSubtitleSize) * 1.2 < Tokens.searchRowHeight);
        Appearance.textScale = saved;
    }

    // The window surface switch changes the window's own roles only: the popup material (menus, sheets, tooltips, combo popups) in
    // Settings and Files is the one on main, `materialTint`, in both appearances (ADR-0024 lot 1).
    function test_windowSurfaceSwitch() {
        const saved = Appearance.windowSurface;
        const dark = Appearance.dark;
        for (const isDark of [false, true]) {
            Appearance.dark = isDark;
            const pal = isDark ? Tokens.colorDark : Tokens.colorLight;
            Appearance.windowSurface = false;
            compare(String(Appearance.colors.materialTint).toLowerCase(), pal.materialTint.toLowerCase());
            compare(String(Appearance.windowFill).toLowerCase(), pal.materialTint.toLowerCase());
            compare(String(Appearance.windowSecondary).toLowerCase(), pal.textSecondary.toLowerCase());
            Appearance.windowSurface = true;
            compare(String(Appearance.colors.materialTint).toLowerCase(), pal.materialTint.toLowerCase(), "popup material unchanged in an app window");
            compare(String(Appearance.windowFill).toLowerCase(), pal.windowBackground.toLowerCase());
            compare(String(Appearance.windowSecondary).toLowerCase(), pal.windowTextSecondary.toLowerCase());
            compare(String(Appearance.colors.textSecondary).toLowerCase(), pal.textSecondary.toLowerCase());
        }
        Appearance.windowSurface = saved;
        Appearance.dark = dark;
    }

    // Settings pane geometry (ADR-0024 lot 1: groups 468 wide, 20 margins, 10 apart, rows 38).
    function test_settingsMetrics() {
        compare(Tokens.settingsContentMaxWidth, 468);
        compare(Tokens.settingsContentMargin, 20);
        compare(Tokens.settingsGroupGap, 10);
        compare(Tokens.settingsRowHeight, 38);
    }
}
