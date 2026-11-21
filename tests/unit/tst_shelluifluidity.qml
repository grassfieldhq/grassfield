import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/dock/Geometry.js" as Geometry
import "../../shell/dock/Magnify.js" as Magnify
import "../../shell/dock/DockModel.js" as DockModel
import "../../shell/desktop/IconsLogic.js" as Icons
import "../../shell/desktop/HotCornerActions.js" as Corners
import "../../shell/menubar/ClockFormat.js" as ClockFormat

// The pure parts of the shell-ui fixes of the second audit round: Dock shrink to fit (A-05), the Dock's magnification by transforms,
// a Dock reorder on the pins as stored now (A-09), the desktop icons' stored slots (A-19), the hot corners in process (A-20) and
// the clock's crowding width (A-21). The QML behaviour is in tests/shell/dock_transform.sh, overview_keyed.sh, wallpaper_retarget.sh.
TestCase {
    name: "ShellUiFluidity"

    function opts(m) {
        return {separatorWidth: 12, spacing: 4, padding: 8, maxScale: m, radius: 2.5, slack: 2};
    }

    // The earlier search: every tile's slot integral at every sampled pointer position (the reference).
    function referenceShelf(size, isSeparator, o) {
        const widths = isSeparator.map(s => s ? o.separatorWidth : size);
        const total = Magnify.totalWidth(widths, o.spacing);
        const rest = total + 2 * o.padding;
        if (!(o.maxScale > 1))
            return rest;
        const pitch = size + o.spacing;
        const reach = o.radius * pitch;
        const centers = Magnify.centersFor(widths, o.spacing, reach);
        const growth = p => {
            let g = 0;
            for (let i = 0; i < widths.length; i++) {
                const half = (widths[i] + o.spacing) / 2;
                if (!isSeparator[i])
                    g += widths[i] * (Magnify.meanScale(centers[i] - half - p, centers[i] + half - p, pitch, o.maxScale, o.radius) - 1);
            }
            return g;
        };
        let best = 0;
        for (let p = 0; p <= total + 2 * reach; p += 0.5)
            best = Math.max(best, growth(p));
        return rest + best;
    }

    function test_widestShelfMatchesTheReference() {
        for (const n of [1, 3, 6, 12, 25]) {
            for (const seps of [[], [n - 2], [1, 3]]) {
                const kinds = [];
                for (let i = 0; i < n; i++)
                    kinds.push(seps.indexOf(i) >= 0);
                for (const m of [1, 1.5, 2]) {
                    const a = Geometry.magnifiedShelf(48, kinds, opts(m));
                    const b = referenceShelf(48, kinds, opts(m));
                    verify(Math.abs(a - b) < 0.05, n + " tiles, x" + m + ": " + a + " vs " + b);
                }
            }
        }
    }

    // A-05: a full Dock on a narrow screen: the shrink to fit costs microseconds, not milliseconds per window and per rebuild.
    function test_shrinkToFitIsCheap() {
        const kinds = [];
        for (let i = 0; i < 40; i++)
            kinds.push(i === 30);
        const t0 = Date.now();
        for (let k = 0; k < 20; k++) {
            Geometry.fitCache.clear();
            Geometry.fitSizeMagnified(128, kinds, 1920, 16, opts(2));
        }
        const each = (Date.now() - t0) / 20;
        verify(each < 5, "uncached shrink to fit of 40 tiles: " + each + " ms");
        const size = Geometry.fitSizeMagnified(128, kinds, 1920, 16, opts(2));
        verify(Geometry.magnifiedShelf(size, kinds, opts(2)) + 2 <= 1920 && Geometry.magnifiedShelf(size + 1, kinds, opts(2)) + 2 > 1920);
        compare(Geometry.fitSizeMagnified(128, kinds, 1920, 16, opts(2)), size, "the same answer from the cache");
    }

    // Transforms draw what the layout drew: tile i moved by shifts[i] from its unmagnified place is centred where the magnified
    // layout (from the same left edge) centres it, and the shelf grows by growth().
    function test_shiftsReproduceTheMagnifiedLayout() {
        const widths = [48, 48, 9, 48, 48, 48];
        const scales = [1.2, 1.9, 1, 1.6, 1.1, 1];
        const left = 100;
        const base = Magnify.centersFor(widths, 4, left);
        const lefts = Magnify.lefts(widths, scales, 4, left);
        const s = Magnify.shifts(widths, scales);
        for (let i = 0; i < widths.length; i++)
            verify(Math.abs(base[i] + s[i] - (lefts[i] + widths[i] * scales[i] / 2)) < 1e-9, "tile " + i);
        const scaledTotal = Magnify.totalWidth(widths.map((w, i) => w * scales[i]), 4);
        verify(Math.abs(Magnify.totalWidth(widths, 4) + Magnify.growth(widths, scales) - scaledTotal) < 1e-9);
    }

    // The icon scaled about its pivot covers the grown icon's rectangle, on every edge; the pointer box holds it.
    function test_scalePivotGrowsAwayFromTheEdge() {
        for (const edge of ["bottom", "left", "right"]) {
            const size = 48, s = 1.75, area = 10;
            const o = Geometry.iconOrigin(edge, size, size, area);
            const p = Geometry.scaleOrigin(edge, size);
            const x = o.x + p.x - p.x * s, y = o.y + p.y - p.y * s;
            const g = Geometry.grownIconOrigin(edge, size, size * s, area);
            verify(Math.abs(x - g.x) < 1e-9 && Math.abs(y - g.y) < 1e-9, edge);
            const tileW = Geometry.isVertical(edge) ? size + area : size, tileH = Geometry.isVertical(edge) ? size : size + area;
            const b = Geometry.grownHitBox(edge, size, size * s, area, tileW, tileH);
            verify(b.x <= g.x && b.y <= g.y && b.x + b.w >= g.x + size * s && b.y + b.h >= g.y + size * s, edge + " box");
        }
    }

    function test_blurRegionSteps() {
        compare(Geometry.quantiseUp(300, 8), 304);
        compare(Geometry.quantiseUp(304, 8), 304);
        compare(Geometry.quantiseUp(300.5, 0), 300.5);
        compare(Geometry.regionStep(52), 7);
    }

    function lookup(id) {
        return ["foot", "chromium", "org.gnome.Nautilus", "kate"].indexOf(id) >= 0 ? {id: id, name: id, icon: id} : null;
    }

    // A-09: the tiles were built before a pin change made meanwhile (the rebuild waits for the drag): the drop moves one app in
    // the pins as they are now, and neither brings back an app unpinned meanwhile nor drops one pinned meanwhile.
    function test_reorderUsesThePinsAsStoredNow() {
        const stale = DockModel.withTail(DockModel.merge(["foot", "chromium", "kate"], [], lookup));
        const r = DockModel.reorder(stale, 1, 0, ["foot", "chromium"], lookup);
        verify(r.changed);
        compare(r.pinned.join(","), "chromium,foot", "kate was unpinned meanwhile");
        const r2 = DockModel.reorder(stale, 1, 0, ["foot", "chromium", "kate", "org.gnome.Nautilus"], lookup);
        compare(r2.pinned.join(","), "chromium,foot,kate,org.gnome.Nautilus", "Files pinned meanwhile");
    }

    // A-19: only names without a stored slot are stored; a stored slot outside the grid now stays stored.
    function test_onlyNewSlotsAreStored() {
        const saved = {a: {col: 0, row: 0}, far: {col: 9, row: 9}, junk: {col: "x"}};
        const lay = Icons.layout(["a", "far", "junk", "new"], saved, 2, 2, {});
        const add = Icons.newSlots(lay, saved);
        compare(Object.keys(add).sort().join(","), "junk,new");
        const merged = Icons.merged(saved, add);
        compare(merged.far.col, 9, "the out-of-grid slot is kept for the larger grid");
        compare(Object.keys(Icons.pick(lay, ["a", "nope"])).join(","), "a");
    }

    // A-20: the corners' requests go in process, as the keys' do.
    function test_cornerRequestsInProcess() {
        compare(JSON.stringify(Corners.request("overview")), JSON.stringify({target: "overview", fn: "toggle", args: []}));
        compare(JSON.stringify(Corners.request("apps")), JSON.stringify({target: "apps", fn: "toggle", args: []}));
        compare(Corners.request("lock"), null);
        compare(Corners.request("notifications"), null);
        compare(Corners.request("bogus"), null);
    }

    // A-21: the crowding's clock text does not change from one second to the next.
    function test_clockLayoutTextIgnoresTheTick() {
        compare(ClockFormat.layoutText("Mon 26 Oct 10:41:07"), ClockFormat.layoutText("Mon 26 Oct 10:41:08"));
        compare(ClockFormat.layoutText("Mon 26 Oct 10:41:59"), ClockFormat.layoutText("Mon 26 Oct 10:42:00"));
        verify(ClockFormat.layoutText("Mon 26 Oct") !== ClockFormat.layoutText("Tue 27 Oct"));
    }
}
