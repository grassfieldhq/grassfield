pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.dock
import qs.platform
import qs.services

// The real Dock (shell/dock/Dock.qml, staged by tests/shell/dock_transform.sh with a PanelWindow stand-in), offscreen, magnified
// by its own test pointer while every frame of the magnification is sampled (audit, Dock fluidity; A-05, A-08):
//   - the tiles' layout never changes: the Grid's children keep their places and their unmagnified size on every frame;
//   - the icons are drawn where the earlier layout-driven magnification drew them (the magnified widths laid out from the shelf's
//     left, the icon grown away from the screen edge and lifted by its share of the growth): the transforms change nothing seen;
//   - the input region is one rectangle for the whole hover (no input region per frame), and holds the drawn shelf;
//   - the blur region follows the moving shelf by whole steps (fewer updates than frames), never shorter than the shelf, and is
//     the shelf exactly once the scales have settled;
//   - a tile carries its own kind's items only (one icon per tile, not five TintedIcons and a capture each).
// Prints "dock-transform: PASS" or the failures.
ShellRoot {
    id: root

    property var win: null
    property var failures: []
    property var frames: []
    property bool done: false

    function check(name: string, ok: bool): void {
        if (!ok)
            root.failures.push(name);
    }

    Dock {
        id: dock
    }

    function find(item: Item, test: var, out: var): var {
        for (const c of item.children) {
            if (test(c))
                out.push(c);
            root.find(c, test, out);
        }
        return out;
    }
    function gridOf(w: var): Item {
        const g = root.find(w.contentItem, c => c.columns !== undefined && c.rows !== undefined && c.flow !== undefined, []);
        return g.length > 0 ? g[0] : null;
    }

    function finish(): void {
        if (root.done)
            return;
        root.done = true;
        console.log(root.failures.length === 0 ? "dock-transform: PASS (" + root.frames.length + " frames, " + dock.items.length + " tiles)" : "dock-transform: FAIL " + root.failures.join("; "));
        Qt.quit();
    }

    Timer {
        interval: 60000
        running: true
        onTriggered: {
            root.check("finished in time", false);
            root.finish();
        }
    }

    // Start once the Dock is revealed with its tiles.
    Timer {
        id: start
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            const owners = Object.keys(Compositor.dockOwners);
            const w = owners.length > 0 ? Compositor.dockOwners[owners[0]] : null;
            if (!w || !w.reveal || !w.isDockScreen || dock.items.length < 4 || root.gridOf(w) === null)
                return;
            running = false;
            root.win = w;
            Settings.setDockMagnification(2, true);
            root.restXs = root.gridOf(root.win).children.filter(c => c.width > 0).map(c => c.x + "/" + c.width).join(",");
            // The pointer over the middle of the second tile.
            dock.testPointerX = w.baseCenters[1];
            sampler.running = true;
        }
    }
    property string restXs: ""

    FrameAnimation {
        id: sampler
        onTriggered: {
            const w = root.win;
            const hit = w.mask && w.mask.item ? w.mask.item : null;
            root.frames.push({
                xs: root.gridOf(root.win).children.filter(c => c.width > 0).map(c => c.x + "/" + c.width).join(","),
                hit: hit ? [hit.x, hit.y, hit.width, hit.height].join(",") : "none",
                hitMain: hit ? hit.x : 0,
                hitLen: hit ? hit.width : 0,
                shelf: w.shelfWidth,
                blur: w.blurLength,
                moving: w.magnifyMoving
            });
            if (root.frames.length > 3 && !w.magnifyMoving && w.pointerActive) {
                running = false;
                root.judge();
            }
        }
    }

    function judge(): void {
        const w = root.win;
        const f = root.frames;
        root.check("the magnification ran (" + f.length + " frames)", f.length >= 4 && f.some(x => x.moving));
        root.check("no layout: the tiles keep their places and sizes on every frame", f.every(x => x.xs === root.restXs));
        const hits = new Set(f.map(x => x.hit));
        root.check("one input region for the whole hover (" + hits.size + ")", hits.size === 1);
        const shelfLeft = (w.mainTotal - w.shelfWidth) / 2;
        root.check("the input region holds the drawn shelf", f.every(x => x.hitLen + 0.01 >= x.shelf) && f[f.length - 1].hitMain <= shelfLeft + 0.01);
        const shelves = new Set(f.map(x => x.shelf));
        const blurs = new Set(f.map(x => x.blur));
        root.check("the blur region moves by steps (" + blurs.size + " updates for " + shelves.size + " shelf lengths)", blurs.size < shelves.size);
        root.check("the blur region never shorter than the shelf", f.every(x => x.blur + 0.01 >= x.shelf));
        root.check("the blur region is the shelf once settled", Math.abs(w.blurLength - w.shelfWidth) < 0.01);
        // What is seen: the icons where a layout of the magnified widths puts them.
        const scales = w.scaleList;
        const widths = w.widths;
        // The magnified widths laid out from the shelf's left edge (what the layout-driven magnification drew).
        const lefts = [];
        let along = shelfLeft + Tokens.dockPadding;
        for (let i = 0; i < widths.length; i++) {
            lefts.push(along);
            along += widths[i] * scales[i] + Tokens.dockSpacing;
        }
        const restBottom = w.height - Tokens.dockBottomMargin - Tokens.dockPadding - w.indicatorArea;
        for (let i = 0; i < dock.items.length; i++) {
            if (dock.items[i].kind === "separator")
                continue;
            const r = w.tileIconRect(i).split(" ").map(Number);
            const px = Number(w.iconSize * scales[i]);
            const lift = w.iconSize * (scales[i] - 1) * Tokens.dockMagnificationLift;
            const x = Number(w.origin.x + lefts[i]);
            root.check("icon " + i + " drawn at " + r.join(" ") + ", want x " + x.toFixed(1) + " size " + px.toFixed(1), Math.abs(r[0] - x) <= 1 && Math.abs(r[2] - px) <= 1);
            root.check("icon " + i + " grows from the shelf (bottom " + (r[1] + r[3]) + ", want " + (w.origin.y + restBottom - lift).toFixed(1) + ")", Math.abs(r[1] + r[3] - (w.origin.y + restBottom - lift)) <= 1.5);
        }
        root.check("the pointer's tile is magnified", scales[1] > 1.5);
        // One kind per tile: no tile holds more than one themed icon, and only a minimized tile holds a capture.
        const tiles = root.gridOf(root.win).children.filter(c => c.width > 0);
        for (const t of tiles) {
            const icons = root.find(t, c => c.oversample !== undefined && c.modeActive !== undefined, []);
            root.check("one icon item in a " + t.modelData.kind + " tile (" + icons.length + ")", icons.length <= 1);
            const captures = root.find(t, c => c.captureSource !== undefined, []);
            root.check("no capture in a " + t.modelData.kind + " tile", captures.length === 0);
        }
        root.finish();
    }
}
