pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui

// Gate A2 for the icon appearance modes (ADR-0014, docs/specs/ui.md "Icon shader"): every mode keeps an icon
// recognisable against what is behind it, in both appearances and at every list/grid size. The real pipeline draws real
// images (own SVG fixtures of tests/fixtures/icons, installed breeze and hicolor icons
// read in place) through TintedIcon and the shader; the rendered pixels are measured.
//
// Scenarios: (a) windows, appearance light/dark x wallpaper black/grey/white under the default material, icon sizes 16,
// 24, 32 and 48; (b) the desktop, icons over the bare wallpaper (black, grey, white and the default wallpaper's sky and
// hill colours), always styled for the wallpaper (darkAppearance) as DesktopIcon does, at 48; (c) the material at transparency 1.0 in
// every mode (floor 2.0), at 16, 24 and 48; (d) Tinted with a bright yellow and a pink tint, over the material and at transparency 1.0;
// (e) the accent fill of a selected row (Search; Force Quit rows are 18 px and never in a mode); (f) the folder model against the rendered pixels, a black folder on
// black, the missing-shader fallback.
// Rules, per icon and mode in dark/clear/tinted:
//   floor(d) = 2.9 (3:1 less a rounding margin) when the default rendering has d >= 3, else 0.9 * d (never more than
//              10 percent worse than default).
//   I (inside)  glyph-vs-plate contrast >= floor(default's), for icons whose default has a glyph (>= 2:1 inside), from 24 px up
//               (at 16 px the edge highlight and the anti-aliasing fill the whole measured ring). Clear
//               and Tinted are monochrome (a glyph differing from its plate only by hue loses that difference), so their
//               floor is min(2, 0.9 * default) instead of 3.
//   E (outside) the best of outline-vs-background, plate-vs-background and glyph-vs-background >= floor(default's): the
//               icon stays visible by its edge or by its glyph. Every icon sits on a system plate, so this holds for every
//               icon except the measured limits below.
//   N (internal contrast) when the default's lightest and darkest pixels in the middle of the artwork differ by 7:1 (3:1) or more, the
//               mode keeps a per-mode tier (Dark 2.3:1 (1.5:1), Tinted 1.9:1 (1.4:1), Clear 1.45:1 (1.25:1)), from 24 px up: a terminal's prompt, a graph on a black plate or a red glyph on a dark one stay readable.
//   S (separation) artwork of nearly one luminance (a pale sky on a green hill) keeps 85 percent of the default's glyph-vs-plate contrast, or 1.5.
// The plate is the median luminance of the ring 4 to 8 px (scaled with the size) inside the edge; the glyph is the 2nd or
// 98th percentile luminance of the core, whichever is farther from the plate; the outline is the 90th percentile of the
// contrast of the pixels of the edge band (the plate's inset, one pixel of antialiasing and one of solid artwork: 3 to 4 px; a maximum would let a few
// pixels carry an invisible edge).
// Contrast is the WCAG ratio of relative luminances. It needs a GPU scene graph (ShaderEffect does not run on the
// software renderer used by the offscreen platform): the test skips there; tests/visual/icon-a2.sh runs it in the
// nested session.
TestCase {
    id: testCase
    name: "IconShaderA2"
    visible: true
    when: windowShown
    width: 1250
    height: 780

    readonly property int cell: 60
    property int iconSize: 48
    readonly property int rowsPerGroup: 12
    readonly property string fixtureDir: Qt.resolvedUrl("../fixtures/icons/")
    readonly property string breezeDir: "file:///usr/share/icons/breeze/apps/48/"
    readonly property var ownNames: ["white-plate-dark-glyph", "blue-plate-white-glyph", "graphite-plate-red-glyph", "white-plate-colour-glyph", "logo-no-plate", "dark-glyph-no-plate", "full-bleed-logo", "dark-plate-light-border", "white-page-document", "same-tone-glyph", "sky-mountain", "light-plate-lighter-glyph", "own-tile-squircle", "own-tile-shadow", "own-circle"]
    // The base theme of the session is Breeze, then Adwaita and hicolor (ADR-0017): Breeze app icons read in place, never copied into the repo
    // (a missing file is skipped). Includes the terminals and monitors (dark plates with a light prompt or a coloured graph) whose internal
    // contrast is at risk, white-plated icons, tile-shaped icons (the plate must not double them) and plain glyphs.
    readonly property var breezeNames: ["utilities-terminal", "utilities-system-monitor", "utilities-energy-monitor", "kcalc", "kate", "okular", "system-file-manager",
        "internet-web-browser", "preferences-system", "office-calendar", "kmail", "help-browser", "systemsettings", "system-software-update", "kphotoalbum",
        "plasma-browser-integration", "system-run", "office-address-book", "photolayoutseditor", "kimagemapeditor"]
    // Installed hicolor/breeze theme icons (read in place, never copied into the repo; a missing file is skipped).
    readonly property var systemIcons: [
        ["hicolor:foot", "hicolor/scalable/apps/foot.svg"], ["hicolor:libreoffice-writer", "hicolor/scalable/apps/libreoffice-writer.svg"],
        ["hicolor:libreoffice-calc", "hicolor/scalable/apps/libreoffice-calc.svg"], ["hicolor:libreoffice-impress", "hicolor/scalable/apps/libreoffice-impress.svg"],
        ["hicolor:btop", "hicolor/scalable/apps/btop.svg"], ["hicolor:mpv", "hicolor/scalable/apps/mpv.svg"],
        ["hicolor:org.gnome.Evince", "hicolor/scalable/apps/org.gnome.Evince.svg"], ["hicolor:org.gnome.Nautilus", "hicolor/scalable/apps/org.gnome.Nautilus.svg"],
        ["hicolor:omacalc", "hicolor/scalable/apps/omacalc.svg"], ["hicolor:kdenlive", "hicolor/scalable/apps/kdenlive.svg"],
        ["hicolor:obs", "hicolor/scalable/apps/com.obsproject.Studio.svg"], ["hicolor:org.gnome.DiskUtility", "hicolor/scalable/apps/org.gnome.DiskUtility.svg"],
        ["hicolor:basecamp", "hicolor/256x256/apps/basecamp.png"], ["breeze:accessories-calculator", "breeze/apps/48/accessories-calculator.svg"], ["breeze:ark", "breeze/apps/48/ark.svg"],
        ["breeze:accessories-text-editor", "breeze/apps/48/accessories-text-editor.svg"]
    ]
    readonly property var modes: ["default", "dark", "clear", "tinted"]
    readonly property var fixtures: {
        const out = [];
        for (const n of ownNames)
            out.push({name: n, url: fixtureDir + n + ".svg"});
        for (const n of breezeNames)
            out.push({name: "breeze48:" + n, url: breezeDir + n + ".svg"});
        for (const e of systemIcons)
            out.push({name: e[0], url: "file:///usr/share/icons/" + e[1]});
        return out;
    }

    property color panelColor: "#202024"
    property bool darkPass: true
    property bool wallpaperPass: false
    // The icons are drawn over the accent fill of a selected row (Search; Force Quit rows are 18 px and never in a mode).
    property bool accentPass: false
    // The Tinted colour of the board.
    property color tintColor: "#3E7BFA"
    // The material at transparency 1.0: the wallpaper shows through, a floor of 2.0 holds (all modes).
    property bool transparentPass: false
    // The icons are on the Dock (a nearly clear glass), not on a solid window material: no tile tone (TintedIcon.solidMaterial).
    property bool dockPass: false
    // The effective luminance of the Dock's glass in the scenario (set once per scenario, so that the inverse pass keeps the icons' look), -1: unknown.
    property real dockLuma: -1

    Item {
        id: board
        width: testCase.width
        height: testCase.height

        Repeater {
            id: slots
            model: testCase.fixtures.length * testCase.modes.length

            delegate: Rectangle {
                id: slot

                required property int index
                readonly property int fixture: Math.floor(slot.index / testCase.modes.length)
                readonly property int modeIndex: slot.index % testCase.modes.length
                property alias icon: tile

                x: (Math.floor(slot.fixture / testCase.rowsPerGroup) * testCase.modes.length + slot.modeIndex) * testCase.cell
                y: (slot.fixture % testCase.rowsPerGroup) * testCase.cell
                width: testCase.cell
                height: testCase.cell
                color: testCase.panelColor

                TintedIcon {
                    id: tile
                    anchors.centerIn: parent
                    size: testCase.iconSize
                    source: testCase.fixtures[slot.fixture].url
                    mode: testCase.modes[slot.modeIndex]
                    tint: testCase.tintColor
                    darkAppearance: testCase.dockPass ? IconModes.surfaceIsDark(testCase.darkPass, testCase.dockLuma, testCase.darkPass, Tokens) : testCase.darkPass
                    overWallpaper: testCase.wallpaperPass
                    overAccent: testCase.accentPass
                    solidMaterial: !testCase.dockPass
                    surfaceLuma: testCase.dockPass ? testCase.dockLuma : -1
                }
            }
        }
    }

    // A shader that failed to load marks the icon effect broken for the whole process (Appearance.iconShaderBroken): not for the next case.
    function cleanup() {
        Appearance.iconShaderBroken = false;
    }

    function channel(v) {
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    }

    function luminance(c) {
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    }

    function ratio(a, b) {
        return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
    }

    function quantile(sorted, q) {
        return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
    }

    // The material colour over a flat wallpaper (sRGB compositing, as Qt does), default transparency.
    function materialOver(appearanceDark, wallpaper, transparency) {
        const tint = Qt.color((appearanceDark ? Tokens.colorDark : Tokens.colorLight).materialTint);
        const a = Appearance.tintAlpha(transparency === undefined ? Tokens.materialDefaultTransparency : transparency);
        const w = Qt.color(wallpaper);
        return Qt.rgba(tint.r * a + w.r * (1 - a), tint.g * a + w.g * (1 - a), tint.b * a + w.b * (1 - a), 1);
    }

    // Contrast metrics of one rendered cell (a grabbed window image), see the pass rule above.
    function measure(img, img2, slot, panel, panel2, artScale) {
        const half = testCase.iconSize / 2;
        const x0 = Math.round(slot.x + testCase.cell / 2 - half);
        const y0 = Math.round(slot.y + testCase.cell / 2 - half);
        const n = testCase.iconSize;
        const lp = luminance(panel);
        const lum = new Array(n * n);
        const mask = new Array(n * n);
        let count = 0;
        for (let y = 0; y < n; y++) {
            for (let x = 0; x < n; x++) {
                const c = img.pixel(x0 + x, y0 + y);
                const c2 = img2.pixel(x0 + x, y0 + y);
                const d = Math.max(Math.abs(c.r - panel.r), Math.abs(c.g - panel.g), Math.abs(c.b - panel.b));
                const d2 = Math.max(Math.abs(c2.r - panel2.r), Math.abs(c2.g - panel2.g), Math.abs(c2.b - panel2.b));
                // The icon's pixels: those that differ from the background in a rendering over it or over its complement
                // (a glass plate equal to the background in one of them is still there in the other).
                const m = d > 0.02 || d2 > 0.02;
                mask[y * n + x] = m;
                lum[y * n + x] = luminance(c);
                if (m)
                    count++;
            }
        }
        if (count < n * n / 20)
            return null;
        const at = (x, y) => x < 0 || y < 0 || x >= n || y >= n ? false : mask[y * n + x];
        const u = n / 48;
        const d2 = Math.max(1, Math.round(2 * u));
        // The outline band holds the edge of the icon: the system plate is inset from the box by iconMode.sysPlateInset, one more pixel is antialiasing, and one
        // pixel of solid artwork is added. A tile icon fills the plate (own-tile rule), so without that pixel the band of a 24 or 32 px icon would be the
        // antialiased fringe alone, whose contrast is that of a half-covered pixel, while Default's tile (inset about 7 percent) always has solid pixels in it.
        // No rim since the owner decision of 2026-10-23: the modes only change the colour.
        const dr = Math.max(2, Math.round(Tokens.iconModeSysPlateInset * n + 1) + 1);
        const d4 = Math.max(2, Math.round(4 * u));
        const d8 = Math.max(3, Math.round(8 * u));
        const ring = [];
        const core = [];
        const rimBand = [];
        for (let y = 0; y < n; y++) {
            for (let x = 0; x < n; x++) {
                if (!mask[y * n + x])
                    continue;
                const e2 = at(x - d2, y) && at(x + d2, y) && at(x, y - d2) && at(x, y + d2);
                const e4 = at(x - d4, y) && at(x + d4, y) && at(x, y - d4) && at(x, y + d4);
                const e8 = at(x - d8, y) && at(x + d8, y) && at(x, y - d8) && at(x, y + d8);
                if (!(at(x - dr, y) && at(x + dr, y) && at(x, y - dr) && at(x, y + dr)))
                    rimBand.push(lum[y * n + x]);
                if (e2 && e4 && !e8)
                    ring.push(lum[y * n + x]);
                if (e8)
                    core.push(lum[y * n + x]);
            }
        }
        if (core.length < 8 || ring.length < 8)
            return null;
        // Internal contrast: the lightest and the darkest pixels of the middle of the artwork (the middle half of the icon in the
        // default rendering, the same part of it once the artwork is scaled onto the system plate): 98th against 2nd percentile.
        const midHalf = 0.25 * n * (artScale === undefined ? 1 : artScale);
        const mid = [];
        for (let y = 0; y < n; y++) {
            for (let x = 0; x < n; x++) {
                if (mask[y * n + x] && Math.abs(x + 0.5 - n / 2) <= midHalf && Math.abs(y + 0.5 - n / 2) <= midHalf)
                    mid.push(lum[y * n + x]);
            }
        }
        mid.sort((a, b) => a - b);
        const internal = mid.length >= 16 ? ratio(quantile(mid, 0.98), quantile(mid, 0.02)) : 1;
        ring.sort((a, b) => a - b);
        core.sort((a, b) => a - b);
        // The plate is what lies just inside the edge; the glyph is the core's extreme farther from it.
        const body = quantile(ring, 0.5);
        const lo = quantile(core, 0.02);
        const hi = quantile(core, 0.98);
        const glyph = ratio(lo, body) >= ratio(hi, body) ? lo : hi;
        // The outline: the 90th percentile of the contrast of the pixels of the edge band (one stroke pixel in two passes,
        // a few bright pixels on an otherwise invisible edge do not).
        const bandRatios = rimBand.map(l => ratio(l, lp)).sort((x, y) => x - y);
        const outlineOverPanel = bandRatios.length > 0 ? quantile(bandRatios, 0.9) : 1;
        const plateOverPanel = ratio(body, lp);
        const glyphOverPanel = ratio(glyph, lp);
        return {
            internal: internal,
            inside: ratio(glyph, body),
            outside: Math.max(plateOverPanel, outlineOverPanel, glyphOverPanel),
            plateOverPanel: plateOverPanel,
            outlineOverPanel: outlineOverPanel,
            glyphOverPanel: glyphOverPanel
        };
    }

    // Remaining limits (tests/fixtures/icons/a2-limits.json, the one source of the table in docs/specs/ui.md; tests/shell/a2_limits_doc.sh checks
    // that the two agree). Each is scoped to one cell: rule, icon, mode, size, appearance, scenario, tint and transparency (the key is the rule
    // and the label of the A2 line), and holds its measured value: the cell fails when it measures more than 0.1 away from it in either direction (a
    // lower value is a regression, a higher one must update the table on purpose), and an exemption whose cell no longer violates its rule is
    // stale and fails too. A key that no measured cell consumed fails (finishRun: a typo, a removed fixture, a size below iconMode.minSize), and
    // test_a2_limitKeysAreWellFormed checks the shape of every key. Below iconMode.minSize no rule applies (the Default artwork is drawn: rule D).
    property var limitTable: null
    property var usedLimitKeys: ({})
    property var scenariosRun: ({})

    function limitOf(key) {
        if (testCase.limitTable === null) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl("../fixtures/icons/a2-limits.json"), false);
            xhr.send();
            const out = {};
            if (xhr.responseText.length > 0) {
                for (const e of JSON.parse(xhr.responseText).limits)
                    out[e.key] = e.value;
            }
            testCase.limitTable = out;
        }
        return testCase.limitTable[key];
    }

    // Per-mode tiers of rule N: [a default pair of 7:1 or more, of 3:1 or more]. Measured lowest values of the strong pairs: Dark 2.54, Tinted
    // 2.18, Clear 1.52; of the weaker: Dark 1.62, Tinted 1.50, Clear 1.31; each tier keeps at least 0.05 below the lowest measured value. Clear is the mode that gives contrast away to show dark glyphs.
    readonly property var internalTiers: ({dark: [2.3, 1.5], tinted: [1.9, 1.4], clear: [1.45, 1.25]})

    readonly property var separationFixtures: ["same-tone-glyph", "sky-mountain", "light-plate-lighter-glyph", "hicolor:basecamp"]

    readonly property int rowIconSize: Math.max(Tokens.iconModeMinSize, Tokens.filesListIconSize)

    // One rule check: `value` is the metric, `violated` whether it is below its floor. A scoped exemption holds the measured value.
    function judge(rule, label, line, value, violated, failures) {
        const key = rule + " " + label;
        const lim = testCase.limitOf(key);
        testCase.usedLimitKeys[key] = true;
        if (lim === undefined) {
            if (violated)
                failures.push(rule + " " + line);
            return;
        }
        if (!violated)
            failures.push("stale exemption " + key + " (the cell holds now: " + value.toFixed(2) + ", exempted at " + lim + ")");
        else if (Math.abs(value - lim) > 0.1)
            failures.push((value < lim ? "regressed " : "improved (update a2-limits.json and ui.md) ") + key + ": measures " + value.toFixed(2) + ", the table holds " + lim + " (more than 0.1 apart)");
    }

    // The keys of the table whose scenario ran in this process and that no measured cell consumed.
    function unusedLimitKeys(failures) {
        testCase.limitOf("");
        for (const key of Object.keys(testCase.limitTable)) {
            if (testCase.usedLimitKeys[key] === true)
                continue;
            for (const sc of Object.keys(testCase.scenariosRun)) {
                if (key.endsWith(" " + sc)) {
                    failures.push("unused limit key (no measured cell matches it): " + key);
                    break;
                }
            }
        }
    }

    readonly property var limitKeyShape: /^[EISN] \S+ (dark|clear|tinted) (\d+)px (dark|light) window (tint #[0-9A-F]{6} )?(transparency 1\.0 )?wallpaper #[0-9a-f]{6}$|^[EISN] \S+ (dark|clear|tinted) 48px desktop wallpaper #[0-9a-f]{6}$/

    function test_a2_limitKeysAreWellFormed() {
        testCase.limitOf("");
        const bad = [];
        for (const key of Object.keys(testCase.limitTable)) {
            const m = testCase.limitKeyShape.exec(key);
            const size = m === null ? 0 : Number(m[2] !== undefined ? m[2] : 48);
            const wall = key.slice(key.lastIndexOf("#"));
            const tint = /tint (#[0-9A-F]{6})/.exec(key);
            if (m === null || size < Tokens.iconModeMinSize || [24, 32, 48].indexOf(size) < 0 || (tint !== null && ["#E6B422", "#E25AA1"].indexOf(tint[1]) < 0)
                    || (key.indexOf("desktop") < 0 && ["#000000", "#808080", "#ffffff"].indexOf(wall) < 0))
                bad.push(key);
        }
        if (bad.length > 0)
            fail("malformed or out-of-scope limit keys: " + bad.join(" | "));
    }

    // Rule D (below iconMode.minSize): the icon of every mode is the Default artwork, pixel for pixel (within the 8 bits of the grab).
    function regionDiff(img, a, b) {
        const n = testCase.iconSize;
        let worst = 0;
        for (let y = 0; y < n; y++) {
            for (let x = 0; x < n; x++) {
                const ca = img.pixel(Math.round(a.x + testCase.cell / 2 - n / 2) + x, Math.round(a.y + testCase.cell / 2 - n / 2) + y);
                const cb = img.pixel(Math.round(b.x + testCase.cell / 2 - n / 2) + x, Math.round(b.y + testCase.cell / 2 - n / 2) + y);
                worst = Math.max(worst, Math.abs(ca.r - cb.r), Math.abs(ca.g - cb.g), Math.abs(ca.b - cb.b));
            }
        }
        return worst;
    }

    // The own-tile rule measures each icon file once (IconShape); an icon is drawn once its scale is known. The board is drawn after that.
    function settleShapes() {
        tryVerify(() => {
            for (let i = 0; i < slots.count; i++) {
                const cell = slots.itemAt(i);
                if (cell !== null && cell.icon.status === Image.Ready && !cell.icon.shapeKnown)
                    return false;
            }
            return true;
        }, 20000, "the icon shapes were not read");
    }

    // One rendering of the whole board over a flat background colour; the icon of every fixture in every mode is
    // measured against it. Returns the number of renderings measured; failures are appended.
    function runScenario(name, dark, background, failures, overWallpaper) {
        testCase.darkPass = dark;
        testCase.wallpaperPass = overWallpaper === true;
        testCase.panelColor = background;
        testCase.scenariosRun[name] = true;
        testCase.settleShapes();
        wait(500);
        waitForRendering(board);
        const img = grabImage(board);
        // The board of this scenario as a picture (every fixture in default, dark, clear and tinted, left to right), for a look.
        if (name.indexOf("48px") === 0 && (name.indexOf("dark window wallpaper #000000") > 0 || name.indexOf("light window wallpaper #ffffff") > 0))
            img.save(Qt.resolvedUrl("../../.dev/shots/a2-board-" + name.replace(/[^a-z0-9]+/gi, "-") + ".png").toString().replace("file://", ""));
        const inverse = Qt.rgba(1 - background.r, 1 - background.g, 1 - background.b, 1);
        testCase.panelColor = inverse;
        wait(300);
        waitForRendering(board);
        const img2 = grabImage(board);
        testCase.panelColor = background;
        // At transparency 1.0 the material is the unblurred wallpaper behind the window: a flat 3:1 is no guarantee over a busy
        // picture, so that scenario holds a floor of 2.0 in every mode.
        const floorOf = v => testCase.transparentPass ? Math.min(2.0, v >= 3 ? 2.9 : 0.9 * v) : (v >= 3 ? 2.9 : 0.9 * v);
        const floorIn = (v, mode) => mode === "dark" ? floorOf(v) : Math.min(2, 0.9 * v);
        let measured = 0;
        for (let f = 0; f < testCase.fixtures.length; f++) {
            const cells = [];
            for (let m = 0; m < testCase.modes.length; m++)
                cells.push(slots.itemAt(f * testCase.modes.length + m));
            // A fixture that is not there (a system icon of a package that is not installed) is a failure of the run, not a cell that is skipped: a gate that
            // skips what it cannot read passes on a machine where it measures nothing.
            if (cells[0] === undefined || cells[0].icon.status !== Image.Ready) {
                failures.push(`${testCase.fixtures[f].name}: the icon could not be read (${testCase.fixtures[f].url}): a missing system icon fails the run`);
                continue;
            }
            // A glyph that is 1.45:1 against its plate in the default rendering (same hue, a little darker) is below legibility
            // below 48 px by its own design: it is tested from 48 px only.
            if (testCase.iconSize < 48 && testCase.fixtures[f].name === "same-tone-glyph")
                continue;
            if (testCase.iconSize < Tokens.iconModeMinSize) {
                for (let m = 1; m < testCase.modes.length; m++) {
                    if (testCase.onlyMode !== "" && testCase.modes[m] !== testCase.onlyMode)
                        continue;
                    const d = testCase.regionDiff(img, cells[0], cells[m]);
                    measured++;
                    console.log(`A2 D ${testCase.fixtures[f].name} ${testCase.modes[m]} ${name}: the Default artwork, largest channel difference ${(d * 255).toFixed(1)}/255`);
                    if (!(d <= 3 / 255)) // not `d > ...`: a NaN must fail too
                        failures.push(`D ${testCase.fixtures[f].name} ${testCase.modes[m]} ${name}: a ${testCase.iconSize} px icon is not the Default artwork (${(d * 255).toFixed(1)}/255 off)`);
                }
                continue;
            }
            const base = measure(img, img2, cells[0], background, inverse, 1);
            if (base === null)
                continue;
            for (let m = 1; m < testCase.modes.length; m++) {
                if (testCase.onlyMode !== "" && testCase.modes[m] !== testCase.onlyMode)
                    continue;
                const r = measure(img, img2, cells[m], background, inverse, cells[m].icon.artScale);
                const label = `${testCase.fixtures[f].name} ${testCase.modes[m]} ${name}`;
                if (r === null) {
                    failures.push(label + ": nothing drawn");
                    continue;
                }
                measured++;
                const line = `${label}: inside ${r.inside.toFixed(2)} (default ${base.inside.toFixed(2)}), internal ${r.internal.toFixed(2)} (default ${base.internal.toFixed(2)}), outside ${r.outside.toFixed(2)} (default ${base.outside.toFixed(2)}; plate ${r.plateOverPanel.toFixed(2)} outline ${r.outlineOverPanel.toFixed(2)} glyph ${r.glyphOverPanel.toFixed(2)})`;
                console.log("A2 " + line);
                const name1 = testCase.fixtures[f].name;
                const mode1 = testCase.modes[m];
                // Every comparison below is written `!(value >= floor)`, never `value < floor`: a NaN or a non-finite measure (an icon not drawn yet) fails instead of passing.
                if (![r.inside, r.internal, r.outside, base.inside, base.internal, base.outside].every(v => isFinite(v)))
                    failures.push(`${label}: a non-finite measure (${line})`);
                testCase.judge("I", label, line, r.inside, base.inside >= 2 && !(r.inside >= floorIn(base.inside, mode1)), failures);
                // Artwork that is only a little different from its plate (a same-hue glyph, a mountain on a sky, a pale gear on a light
                // plate) must not vanish into it in any mode: its glyph-vs-plate contrast keeps 85 percent of the default's, or 1.5.
                testCase.judge("S", label, line, r.inside, testCase.separationFixtures.indexOf(name1) >= 0 && base.inside >= 1.2 && !(r.inside >= Math.min(1.5, 0.85 * base.inside)), failures);
                testCase.judge("E", label, line, r.outside, !(r.outside >= floorOf(base.outside)), failures);
                // N (internal contrast), per-mode tiers (internalTiers): the maps are monotonic with a minimum slope; a dark monochrome glyph must
                // also stand out from the plate, which costs part of the contrast between black and mid-grey art (tests/unit/tst_iconcontrast.qml).
                const tier = testCase.internalTiers[mode1][base.internal >= 7 ? 0 : 1];
                testCase.judge("N", label, line, r.internal, base.internal >= 3 && !(r.internal >= tier), failures);
            }
        }
        return measured;
    }

    // One size of the windows scenarios (both appearances x three wallpapers), or the desktop. Each is a test function of its
    // own so that tests/visual/icon-a2.sh runs them one per process, each under a time limit and retried when the renderer
    // stalls (GPU shared with other nested sessions): a stall costs one case, not the whole run.
    function runSize(size) {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph (ShaderEffect does not run on the software renderer): tests/visual/icon-a2.sh");
        const failures = [];
        let measured = 0;
        testCase.iconSize = size;
        for (const dark of [true, false]) {
            for (const wallpaper of ["#000000", "#808080", "#ffffff"])
                measured += runScenario(`${size}px ${dark ? "dark" : "light"} window wallpaper ${wallpaper}`, dark, materialOver(dark, wallpaper), failures);
        }
        finishRun(measured, failures);
    }

    // The material at transparency 1.0 (Appearance.transparency, the Control Center slider at its end) lets the wallpaper through:
    // the icons must hold over a bright wallpaper in the dark appearance and a dark one in the light appearance, in every mode.
    // `onlyMode`: a scenario that checks one mode only (the tint scenarios are for Tinted).
    property string onlyMode: ""

    function runTransparent(size) {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph: tests/visual/icon-a2.sh");
        const failures = [];
        let measured = 0;
        const saved = Appearance.transparency;
        Appearance.transparency = 1.0;
        testCase.transparentPass = true;
        testCase.iconSize = size;
        for (const dark of [true, false]) {
            for (const wallpaper of ["#000000", "#808080", "#ffffff"])
                measured += runScenario(`${size}px ${dark ? "dark" : "light"} window transparency 1.0 wallpaper ${wallpaper}`, dark, materialOver(dark, wallpaper, 1.0), failures);
        }
        Appearance.transparency = saved;
        testCase.transparentPass = false;
        finishRun(measured, failures);
    }

    // Tinted with other tints (a bright yellow and a pink): the plate and the ramp follow the tint, so the rules hold for any of
    // them, over the window material and at transparency 1.0.
    function runTint(size, color) {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph: tests/visual/icon-a2.sh");
        const failures = [];
        let measured = 0;
        testCase.iconSize = size;
        testCase.tintColor = color;
        testCase.onlyMode = "tinted";
        for (const dark of [true, false]) {
            for (const wallpaper of ["#000000", "#808080", "#ffffff"])
                measured += runScenario(`${size}px ${dark ? "dark" : "light"} window tint ${color} wallpaper ${wallpaper}`, dark, materialOver(dark, wallpaper), failures);
        }
        const saved = Appearance.transparency;
        Appearance.transparency = 1.0;
        testCase.transparentPass = true;
        for (const dark of [true, false]) {
            for (const wallpaper of ["#000000", "#808080", "#ffffff"])
                measured += runScenario(`${size}px ${dark ? "dark" : "light"} window tint ${color} transparency 1.0 wallpaper ${wallpaper}`, dark, materialOver(dark, wallpaper, 1.0), failures);
        }
        Appearance.transparency = saved;
        testCase.transparentPass = false;
        testCase.onlyMode = "";
        testCase.tintColor = "#3E7BFA";
        finishRun(measured, failures);
    }

    function test_a2_tintYellow32() {
        runTint(32, "#E6B422");
    }

    function test_a2_tintPink32() {
        runTint(32, "#E25AA1");
    }

    // The selection fill of a selected row (Files; Force Quit rows are 18 px and never in a mode): the ink follows the row's text colour (TintedIcon.overAccent), so
    // the plate and the ink are the opposite of the fill. The plate pixel (between the rim and the artwork) has at least 4.5:1 against the
    // accent in Clear (the old design measured 2.77:1 on main's 5.61:1 there) and 2.5:1 in Dark and Tinted (their plates are the mode's own).
    function test_a2_accentRow() {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph: tests/visual/icon-a2.sh");
        const failures = [];
        let measured = 0;
        const wasDark = Appearance.dark;
        testCase.accentPass = true;
        testCase.iconSize = 32;
        for (const dark of [true, false]) {
            Appearance.dark = dark;
            const accent = Qt.color(Appearance.colors.selection);
            const name = `32px ${dark ? "dark" : "light"} selection row ${Appearance.colors.selection}`;
            testCase.darkPass = dark;
            testCase.wallpaperPass = false;
            testCase.panelColor = accent;
            testCase.settleShapes();
            wait(500);
            waitForRendering(board);
            const img = grabImage(board);
            img.save(Qt.resolvedUrl("../../.dev/shots/a2-board-accent-row-" + (dark ? "dark" : "light") + ".png").toString().replace("file://", ""));
            const inverse = Qt.rgba(1 - accent.r, 1 - accent.g, 1 - accent.b, 1);
            testCase.panelColor = inverse;
            wait(300);
            waitForRendering(board);
            const img2 = grabImage(board);
            testCase.panelColor = accent;
            for (let f = 0; f < testCase.fixtures.length; f++) {
                for (let m = 1; m < testCase.modes.length; m++) {
                    const cell = slots.itemAt(f * testCase.modes.length + m);
                    if (cell === undefined || cell.icon.status !== Image.Ready)
                        continue;
                    const r = measure(img, img2, cell, accent, inverse);
                    if (r === null)
                        continue;
                    measured++;
                    const label = `${testCase.fixtures[f].name} ${testCase.modes[m]} ${name}`;
                    // The plate itself: a pixel of the plate between its rim and the artwork (3 px inside the icon box, at the middle).
                    const px = Math.round(cell.x + testCase.cell / 2);
                    const py = Math.round(cell.y + (testCase.cell - testCase.iconSize) / 2 + 3);
                    const plateRatio = ratio(luminance(img.pixel(px, py)), luminance(accent));
                    console.log(`A2 ${label}: plate pixel ${plateRatio.toFixed(2)} (outside ${r.outside.toFixed(2)}: plate ${r.plateOverPanel.toFixed(2)} outline ${r.outlineOverPanel.toFixed(2)} glyph ${r.glyphOverPanel.toFixed(2)})`);
                    const floor = testCase.modes[m] === "clear" ? 4.5 : 2.5;
                    if (!(plateRatio >= floor))
                        failures.push(`A ${label}: plate pixel ${plateRatio.toFixed(2)} < ${floor}`);
                }
            }
        }
        Appearance.dark = wasDark;
        testCase.accentPass = false;
        verify(measured > 100, "measured " + measured);
        if (failures.length > 0)
            fail(failures.length + " failures:\n" + failures.join("\n"));
    }

    function test_a2_transparent48() {
        runTransparent(48);
    }

    function test_a2_transparent24() {
        runTransparent(24);
    }

    function test_a2_transparent16() {
        runTransparent(16);
    }

    function finishRun(measured, failures) {
        testCase.unusedLimitKeys(failures);
        verify(measured > (testCase.onlyMode !== "" ? 50 : (testCase.transparentPass ? 150 : 200)), "measured " + measured + " icon renderings");
        if (failures.length > 0)
            fail(failures.length + " failures:\n" + failures.join("\n"));
    }

    function test_a2_size48() {
        runSize(48);
    }

    function test_a2_size32() {
        runSize(32);
    }

    function test_a2_size24() {
        runSize(24);
    }

    function test_a2_size16() {
        runSize(16);
    }

    // The desktop: bare wallpaper, always styled for it (DesktopIcon passes darkAppearance), also when the windows are light.
    // The Dock: a nearly clear glass (Tokens.dockTintAlpha*, 0.05) over the wallpaper. The solid-material tile tone is off here (TintedIcon.solidMaterial
    // false); over a light glass (IconModes.glassToneSide) a tile is darkened as on a light material, and Clear on a mid-tone glass takes the smoked plate at the least ratio
    // (IconModes.smokeAlpha), the surface luminance being fed as TintedIcon.surfaceLuma. 2026-11-10: with the tone on, a tile at Y 0.28 fell from 1.61:1 to 1.01:1 on the Dock (independent review).
    function dockOver(appearanceDark, wallpaper) {
        const tint = Qt.color((appearanceDark ? Tokens.colorDark : Tokens.colorLight).materialTint);
        const a = appearanceDark ? Tokens.dockTintAlphaDark : Tokens.dockTintAlphaLight;
        const w = Qt.color(wallpaper);
        return Qt.rgba(tint.r * a + w.r * (1 - a), tint.g * a + w.g * (1 - a), tint.b * a + w.b * (1 - a), 1);
    }

    function test_a2_dock() {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph: tests/visual/icon-a2.sh");
        const failures = [];
        let measured = 0;
        testCase.iconSize = 48;
        testCase.dockPass = true;
        for (const dark of [true, false]) {
            for (const wallpaper of ["#000000", "#808080", "#ffffff"])
            {
                const panel = dockOver(dark, wallpaper);
                testCase.dockLuma = FolderStyle.relativeLuminance([panel.r, panel.g, panel.b]);
                measured += runScenario(`48px ${dark ? "dark" : "light"} dock wallpaper ${wallpaper}`, dark, panel, failures);
            }
        }
        // The hysteresis band of the dark/light decision (surface luminance 0.07, 0.10, 0.13, review of 398f94d1): grey wallpapers whose glass lands there in each appearance.
        // A dark held decision (the dark pass) and a light one (the light pass) must both read.
        for (const dark of [true, false]) {
            for (const target of [0.07, 0.10, 0.13]) {
                const a = dark ? Tokens.dockTintAlphaDark : Tokens.dockTintAlphaLight;
                const tintLuma = FolderStyle.relativeLuminance(FolderStyle.rgbOf((dark ? Tokens.colorDark : Tokens.colorLight).materialTint));
                const wl = Math.max(0, (target - a * tintLuma) / (1 - a));
                const v = wl <= 0.0031308 ? 12.92 * wl : 1.055 * Math.pow(wl, 1 / 2.4) - 0.055;
                const panel = dockOver(dark, Qt.rgba(v, v, v, 1));
                testCase.dockLuma = FolderStyle.relativeLuminance([panel.r, panel.g, panel.b]);
                measured += runScenario(`48px ${dark ? "dark" : "light"} dock band surface ${target}`, dark, panel, failures);
            }
        }
        testCase.dockPass = false;
        testCase.dockLuma = -1;
        finishRun(measured, failures);
    }

    function test_a2_desktop() {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph: tests/visual/icon-a2.sh");
        const failures = [];
        let measured = 0;
        testCase.iconSize = 48;
        for (const wallpaper of ["#000000", "#808080", "#ffffff", "#1d4a5c", "#3f7d58"])
            measured += runScenario(`48px desktop wallpaper ${wallpaper}`, true, Qt.color(wallpaper), failures, true);
        finishRun(measured, failures);
    }

    // The folder model (FolderStyle.modeSamples, used to engrave a folder symbol) against the rendered pixels: a plate-less
    // folder in every mode, appearance and surface. The box under the symbol is read from the icon drawn in default mode
    // (the raw icon), run through the model and compared with the mean colour of the same box in the mode's rendering
    // (the folder shrinks to the system plate by sysGlyphScale about the centre).
    readonly property var folderUrls: [Qt.resolvedUrl("file:///usr/share/icons/breeze/places/64/folder.svg"),
                                       Qt.resolvedUrl("fixtures/folder-light.svg"), Qt.resolvedUrl("fixtures/folder-dark.svg")]

    Component {
        id: folderCell

        Rectangle {
            id: cell

            required property int fx
            required property string cellMode
            required property url cellSource
            readonly property alias icon: tintedFolder

            x: cell.fx * 120
            y: 560
            width: 112
            height: 112
            color: "#808080"

            TintedIcon {
                id: tintedFolder
                anchors.centerIn: parent
                size: 96
                source: cell.cellSource
                mode: cell.cellMode
                tint: "#3E7BFA"
                darkAppearance: testCase.darkPass
                overWallpaper: testCase.wallpaperPass
                solidMaterial: true
            }
        }
    }

    function boxMean(img, x0, y0, side, scale) {
        const box = FolderStyle.glyphBox(side, Tokens);
        const c = side / 2;
        const sum = [0, 0, 0];
        let n = 0;
        for (let y = Math.floor(box[1]); y < box[3]; y += 2) {
            for (let x = Math.floor(box[0]); x < box[2]; x += 2) {
                // the box position after the scale about the icon centre
                const px = Math.round(x0 + c + (x - c) * scale), py = Math.round(y0 + c + (y - c) * scale);
                const col = img.pixel(px, py);
                sum[0] += col.r;
                sum[1] += col.g;
                sum[2] += col.b;
                n++;
            }
        }
        return [sum[0] / n, sum[1] / n, sum[2] / n];
    }

    function test_folderModelMatchesTheShader() {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph: tests/visual/icon-a2.sh");
        const failures = [];
        let compared = 0;
        const tint = "#3E7BFA";
        board.visible = false;
        for (const url of testCase.folderUrls) {
            for (const dark of [true, false]) {
                for (const wall of [false, true]) {
                    testCase.darkPass = dark;
                    testCase.wallpaperPass = wall;
                    const cells = [];
                    ["default", "dark", "clear", "tinted"].forEach((m, i) => cells.push(createTemporaryObject(folderCell, testCase, {fx: i, cellMode: m, cellSource: url})));
                    tryVerify(() => cells[0].icon.status === Image.Ready || cells[0].icon.status === Image.Error, 3000);
                    if (cells[0].icon.status !== Image.Ready) {
                        cells.forEach(c => c.destroy());
                        continue;
                    }
                    // The first scene of a run draws its icons late (the shader is built on first use): read the pixels once every mode cell shows something other than its grey
                    // background (2026-11-11: the first three cells came back as the bare #808080, "3 folder model differences"), up to five seconds.
                    let img = null;
                    for (let tries = 0; tries < 20; tries++) {
                        wait(tries === 0 ? 400 : 250);
                        img = grabImage(testCase);
                        const drawnAll = [1, 2, 3].every(m => {
                            const c = img.pixel(m * 120 + 56, 560 + 56);
                            return Math.abs(c.r - 0.5) > 0.02 || Math.abs(c.g - 0.5) > 0.02 || Math.abs(c.b - 0.5) > 0.02;
                        });
                        if (drawnAll)
                            break;
                    }
                    const rawBox = FolderStyle.glyphBox(96, Tokens);
                    const raw = [];
                    for (let y = Math.floor(rawBox[1]); y < rawBox[3]; y += 4) {
                        for (let x = Math.floor(rawBox[0]); x < rawBox[2]; x += 4) {
                            const c = img.pixel(8 + x, 560 + 8 + y);
                            raw.push(c.r, c.g, c.b, 1);
                        }
                    }
                    for (let m = 1; m < 4; m++) {
                        const mode = cells[m].cellMode;
                        // The artwork of the mode over the system plate over the cell's grey (#808080).
                        const modelled = FolderStyle.modeSamples(raw, mode, tint, dark || wall, Tokens, wall);
                        const under = FolderStyle.underlay(mode, tint, dark || wall, wall, [0.5, 0.5, 0.5], Tokens);
                        const mean = [0, 0, 0];
                        for (let i = 0; i < modelled.length; i += 4) {
                            const al = modelled[i + 3];
                            for (let q = 0; q < 3; q++)
                                mean[q] += (modelled[i + q] * al + under[q] * (1 - al)) * 4 / modelled.length;
                        }
                        const drawn = testCase.boxMean(img, m * 120 + 8, 560 + 8, 96, Tokens.iconModeSysGlyphScale);
                        const d = Math.max(Math.abs(mean[0] - drawn[0]), Math.abs(mean[1] - drawn[1]), Math.abs(mean[2] - drawn[2]));
                        const label = `${String(url).split("/").pop()} ${mode} ${dark ? "dark" : "light"}${wall ? " wallpaper" : ""}: model ${FolderStyle.hexOf(mean)} drawn ${FolderStyle.hexOf(drawn)} (max channel diff ${(d * 255).toFixed(0)}/255; per channel ${[0, 1, 2].map(q => ((mean[q] - drawn[q]) * 255).toFixed(1)).join(" ")}; shader look: wall=${cells[m].icon.effectItem ? cells[m].icon.effectItem.overWallpaper : "?"} tile=${cells[m].icon.ownTile} tone=${cells[m].icon.effectItem ? cells[m].icon.effectItem.tileToneSide : "?"} transparency=${Appearance.effectiveTransparency.toFixed(2)})`;
                        console.log("A2 folder " + label);
                        compared++;
                        if (!(d <= 4 / 255 + 1e-6))
                            failures.push(label);
                    }
                    cells.forEach(c => c.destroy());
                }
            }
        }
        board.visible = true;
        verify(compared >= 12, "compared " + compared);
        if (failures.length > 0)
            fail(failures.length + " folder model differences over 4/255 (one line, the runner prints only the first): " + failures.join(" | "));
    }

    // A folder of the colour black keeps its system plate and the plate's edge in every icon mode, on a black wallpaper: the
    // folder colour recolours the artwork only (in the shader), not the plate and its rim.
    Component {
        id: blackFolder

        Rectangle {
            id: holder

            required property string holderMode
            readonly property alias folder: blackFolderIcon

            width: 112
            height: 112
            color: "#000000"

            FolderIcon {
                id: blackFolderIcon
                anchors.centerIn: parent
                size: 96
                source: Qt.resolvedUrl("file:///usr/share/icons/breeze/places/64/folder.svg")
                folderColor: "#000000"
                mode: holder.holderMode
                darkAppearance: testCase.darkPass
                overWallpaper: testCase.wallpaperPass
            }
        }
    }

    function test_blackFolderKeepsItsPlateOnBlack() {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph: tests/visual/icon-a2.sh");
        const failures = [];
        board.visible = false;
        for (const dark of [true, false]) {
            for (const wall of [false, true]) {
                testCase.darkPass = dark;
                testCase.wallpaperPass = wall;
                for (const mode of ["dark", "clear", "tinted"]) {
                    const holder = createTemporaryObject(blackFolder, testCase, {holderMode: mode});
                    verify(holder);
                    tryVerify(() => holder.folder.status === Image.Ready || holder.folder.status === Image.Error, 3000);
                    if (holder.folder.status !== Image.Ready) {
                        holder.destroy();
                        board.visible = true;
                        skip("the Breeze folder icon is not installed");
                    }
                    wait(400);
                    const img = grabImage(holder);
                    let lit = 0;
                    for (let y = 0; y < 112; y += 2) {
                        for (let x = 0; x < 112; x += 2) {
                            const c = img.pixel(x, y);
                            if (c.r + c.g + c.b > 0.06)
                                lit++;
                        }
                    }
                    const label = `black folder ${mode} ${dark ? "dark" : "light"}${wall ? " wallpaper" : ""}: ${lit} of 3136 sampled pixels differ from black (the plate, or at least its edge highlight, is there)`;
                    console.log("A2 " + label);
                    if (lit < 60)
                        failures.push(label);
                    holder.destroy();
                }
            }
        }
        board.visible = true;
        if (failures.length > 0)
            fail(failures.join("\n"));
    }

    // A missing shader must not make an icon vanish: the plain image is drawn, at the icon's own size and place.
    function test_missingShaderDrawsThePlainIcon() {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph: tests/visual/icon-a2.sh");
        testCase.iconSize = 48;
        testCase.darkPass = true;
        testCase.panelColor = "#202024";
        const holder = createTemporaryObject(brokenComponent, board);
        verify(holder);
        tryVerify(() => holder.icon.effectFailed, 3000, "the effect reports the missing shader");
        wait(300);
        waitForRendering(board);
        // Geometry: the plain image is the item's size (not the decoded size times the oversample) and anchored at it.
        compare(holder.icon.width, testCase.iconSize);
        compare(holder.icon.paintedWidth, testCase.iconSize);
        verify(holder.icon.plainVisible);
        const img = grabImage(board);
        const inside = (x, y) => {
            const c = img.pixel(holder.x + x, holder.y + y);
            return Math.abs(c.r - 0x20 / 255) > 0.05 || Math.abs(c.b - 0x24 / 255) > 0.05;
        };
        let drawn = 0;
        for (let y = 0; y < testCase.iconSize; y++) {
            for (let x = 0; x < testCase.iconSize; x++) {
                if (inside(x, y))
                    drawn++;
            }
        }
        verify(drawn > testCase.iconSize * testCase.iconSize / 2, "the plain icon is drawn: " + drawn + " pixels");
        // Nothing beyond the item box (a 2x image would spill to the right and below, onto the holder's background).
        let spill = 0;
        for (let k = 0; k < testCase.iconSize * 2 - 2; k++) {
            if (inside(testCase.iconSize + 4, k) || inside(k, testCase.iconSize + 4))
                spill++;
        }
        compare(spill, 0, "no pixels drawn outside the icon box");
    }

    Component {
        id: brokenComponent

        Rectangle {
            property alias icon: broken

            x: 700
            y: 600
            // Twice the icon's size: the pixels beyond the icon's own box are background, so a plain image drawn at 2x shows.
            width: testCase.iconSize * 2
            height: testCase.iconSize * 2
            color: "#202024"

            TintedIcon {
                id: broken
                size: testCase.iconSize
                mode: "dark"
                shaderUrl: Qt.resolvedUrl("missing/icon.frag.qsb")
                source: testCase.fixtureDir + "blue-plate-white-glyph.svg"
            }
        }
    }

    // A selected, focused row of Files (list and columns: selection fill, icons of rowIconSize: Tokens.filesListIconSize, at least iconMode.minSize) draws FileIcon with overAccent:
    // the mean of the top 20 percent of the icon's pixels (a folder and a document) has at least 3:1 (2.5:1 in Dark) against the selection fill in every mode and both appearances (the
    // merge base had 3.77:1 in Clear, the wiring missing gave 2.01:1).
    Component {
        id: accentCell

        Rectangle {
            id: acell

            required property string cellMode
            required property url cellSource
            required property bool cellFolder
            readonly property var inner: cellFolder ? folderPart : filePart

            width: 40
            height: 40
            color: Appearance.colors.selection

            FolderIcon {
                id: folderPart
                anchors.centerIn: parent
                visible: acell.cellFolder
                size: testCase.rowIconSize
                source: acell.cellSource
                mode: acell.cellMode
                darkAppearance: Appearance.dark
                overAccent: true
            }

            TintedIcon {
                id: filePart
                anchors.centerIn: parent
                visible: !acell.cellFolder
                size: testCase.rowIconSize
                source: acell.cellSource
                mode: acell.cellMode
                darkAppearance: Appearance.dark
                overAccent: true
            }
        }
    }

    function test_a2_filesSelectedRow() {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph: tests/visual/icon-a2.sh");
        const failures = [];
        const wasDark = Appearance.dark;
        board.visible = false;
        const sources = [[true, Qt.resolvedUrl("file:///usr/share/icons/breeze/places/64/folder.svg")], [false, testCase.fixtureDir + "white-page-document.svg"],
                         [false, testCase.fixtureDir + "blue-plate-white-glyph.svg"]];
        let measured = 0;
        for (const dark of [true, false]) {
            Appearance.dark = dark;
            for (const mode of ["dark", "clear", "tinted"]) {
                for (const src of sources) {
                    const cell = createTemporaryObject(accentCell, testCase, {cellMode: mode, cellSource: src[1], cellFolder: src[0]});
                    verify(cell);
                    tryVerify(() => cell.inner.status === Image.Ready || cell.inner.status === Image.Error, 3000);
                    if (cell.inner.status !== Image.Ready) {
                        cell.destroy();
                        continue;
                    }
                    const bg = Qt.color(Appearance.colors.selection);
                    // A robust statistic: the mean contrast of the top 20 percent of the icon's own pixels (those that differ from the accent), so
                    // that a stray pixel cannot carry a failing icon. Read once the icon is drawn (the first scene draws late, as in the folder-model
                    // test: at least 20 such pixels), up to five seconds; an icon that never shows fails below (no pixels: not finite).
                    let rs = [];
                    let img = null;
                    for (let tries = 0; tries < 20; tries++) {
                        wait(tries === 0 ? 300 : 250);
                        img = grabImage(cell);
                        rs = [];
                        for (let y = 0; y < 40; y++) {
                            for (let x = 0; x < 40; x++) {
                                const c = img.pixel(x, y);
                                if (Math.max(Math.abs(c.r - bg.r), Math.abs(c.g - bg.g), Math.abs(c.b - bg.b)) > 0.02)
                                    rs.push(ratio(luminance(c), luminance(bg)));
                            }
                        }
                        if (rs.length >= 20)
                            break;
                    }
                    rs.sort((p, q) => q - p);
                    const top = rs.slice(0, Math.max(1, Math.ceil(rs.length * 0.2)));
                    const best = rs.length === 0 ? NaN : top.reduce((p, q) => p + q, 0) / top.length;
                    measured++;
                    const label = `files row ${src[0] ? "folder" : String(src[1]).split("/").pop()} ${mode} ${dark ? "dark" : "light"}: mean of the top 20 percent pixels ${best.toFixed(2)}`;
                    console.log("A2 " + label);
                    // Dark keeps its graphite plate on both fills (2.8:1 against the dark accent of the light appearance): 2.5, as the accent row.
                    if (!(best >= (mode === "dark" ? 2.5 : 3)))
                        failures.push(label);
                    cell.destroy();
                }
            }
        }
        Appearance.dark = wasDark;
        board.visible = true;
        verify(measured >= 12, "measured " + measured);
        if (failures.length > 0)
            fail(failures.length + " failures:\n" + failures.join("\n"));
    }
}
