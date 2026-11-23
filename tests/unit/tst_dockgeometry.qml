import QtQuick
import QtTest
import "../../shell/dock/Geometry.js" as Geometry
import "../../shell/dock/DockModel.js" as DockModel
import "../../shell/dock/Magnify.js" as Magnify
import "../../shell/dock/AutoHide.js" as AutoHide

TestCase {
    name: "DockGeometry"

    readonly property var base: ({
            iconSize: 48,
            padding: 10,
            indicatorSize: 4,
            spacing: 4,
            bottomMargin: 6,
            separatorHeight: 49,
            badgeSize: 20,
            radiusIcon: 11
        })

    function test_clampSize() {
        compare(Geometry.clampSize(48, 32, 96, 48), 48);
        compare(Geometry.clampSize(10, 32, 96, 48), 32);
        compare(Geometry.clampSize(500, 32, 96, 48), 96);
        compare(Geometry.clampSize(40.6, 32, 96, 48), 41);
        compare(Geometry.clampSize("64", 32, 96, 48), 64);
        compare(Geometry.clampSize("big", 32, 96, 48), 48);
        compare(Geometry.clampSize(null, 32, 96, 48), 48);
        compare(Geometry.clampSize(undefined, 32, 96, 48), 48);
        compare(Geometry.clampSize(true, 32, 96, 48), 48);
        compare(Geometry.clampSize(NaN, 32, 96, 48), 48);
    }

    function test_defaultSizeKeepsTheTokens() {
        const m = Geometry.metrics(48, base);
        compare(m.iconSize, 48);
        compare(m.separatorHeight, 49);
        compare(m.badgeSize, 20);
        fuzzyCompare(m.iconRadius, 11, 1e-9);
        // No band under the icons (audit 2026-10-25: 76 -> 68): the running dot sits in the bottom padding.
        compare(DockModel.shelfHeight(m), 48 + 20);
        compare(DockModel.reservedHeight(m, false), 68 + 6);
    }

    function test_proportionalPartsFollowTheSize() {
        const big = Geometry.metrics(96, base);
        compare(big.iconSize, 96);
        compare(big.separatorHeight, 98);
        compare(big.badgeSize, 40);
        fuzzyCompare(big.iconRadius, 22, 1e-9);
        // The shelf and its exclusive zone grow by exactly the growth of the tile.
        compare(DockModel.shelfHeight(big) - DockModel.shelfHeight(Geometry.metrics(48, base)), 48);
        compare(DockModel.reservedHeight(big, false) - DockModel.reservedHeight(Geometry.metrics(48, base), false), 48);
        compare(DockModel.reservedHeight(big, true), 0);
    }

    // ---- position on screen ----

    readonly property var m48: Geometry.metrics(48, base)

    function test_normalizeEdge() {
        compare(Geometry.normalizeEdge("left"), "left");
        compare(Geometry.normalizeEdge("right"), "right");
        compare(Geometry.normalizeEdge("bottom"), "bottom");
        compare(Geometry.normalizeEdge("top"), "bottom");
        compare(Geometry.normalizeEdge(undefined), "bottom");
        compare(Geometry.normalizeEdge(3), "bottom");
        verify(Geometry.isVertical("left") && Geometry.isVertical("right") && !Geometry.isVertical("bottom"));
    }

    function test_rectMapsMainAndCrossForEachEdge() {
        // A 300 x 100 window anchored at the bottom, 100 x 300 on a side edge: 10 px off the edge, 40 deep, from 50 for 60.
        const b = Geometry.rect("bottom", 300, 100, 50, 60, 10, 40);
        compare(b.x, 50);
        compare(b.w, 60);
        compare(b.y, 100 - 10 - 40);
        compare(b.h, 40);
        const l = Geometry.rect("left", 100, 300, 50, 60, 10, 40);
        compare(l.y, 50);
        compare(l.h, 60);
        compare(l.x, 10);
        compare(l.w, 40);
        const r = Geometry.rect("right", 100, 300, 50, 60, 10, 40);
        compare(r.y, 50);
        compare(r.h, 60);
        compare(r.x, 100 - 10 - 40);
        compare(r.w, 40);
    }

    function test_crossAndMainOfAPoint() {
        compare(Geometry.crossOf("bottom", 20, 90, 300, 100), 10);
        compare(Geometry.crossOf("left", 12, 90, 100, 300), 12);
        compare(Geometry.crossOf("right", 88, 90, 100, 300), 12);
        compare(Geometry.mainOf("bottom", 20, 90), 20);
        compare(Geometry.mainOf("left", 20, 90), 90);
        compare(Geometry.mainOf("right", 20, 90), 90);
        compare(Geometry.mainSize("bottom", 300, 100), 300);
        compare(Geometry.mainSize("right", 100, 300), 300);
        compare(Geometry.crossSize("bottom", 300, 100), 100);
        compare(Geometry.crossSize("left", 100, 300), 100);
    }

    function test_shelfIsCentredAndSlidesTowardItsEdge() {
        const thick = DockModel.shelfHeight(m48);
        for (const edge of Geometry.EDGES) {
            const w = Geometry.isVertical(edge) ? 200 : 1000;
            const h = Geometry.isVertical(edge) ? 1000 : 200;
            const shown = Geometry.shelfRect(edge, w, h, 400, thick, 6, 0);
            const main0 = Geometry.mainOf(edge, shown.x, shown.y);
            compare(main0, 300, edge);
            compare(Geometry.crossOf(edge, shown.x + (edge === "right" ? shown.w : 0), shown.y + (edge === "bottom" ? shown.h : 0), w, h), 6, edge);
            // Fully hidden (slide = thickness + margin + shadow room): entirely beyond the screen edge.
            const hidden = Geometry.shelfRect(edge, w, h, 400, thick, 6, thick + 6 + 20);
            if (edge === "bottom")
                verify(hidden.y >= h, edge);
            else if (edge === "left")
                verify(hidden.x + hidden.w <= 0, edge);
            else
                verify(hidden.x >= w, edge);
        }
    }

    function test_hitRectIsTheStripWhileAwayAndTheShelfOtherwise() {
        const base = {revealed: false, dragging: false, pointerActive: false, shelfMain0: 300, shelfLength: 400, thickness: 68, margin: 6, overhang: 29, room: 44, zone: 2};
        const strip = Geometry.hitRect("bottom", 1000, 200, base);
        compare(strip.w, 1000);
        compare(strip.h, 2);
        compare(strip.y, 198);
        const side = Geometry.hitRect("left", 200, 1000, base);
        compare(side.h, 1000);
        compare(side.w, 2);
        compare(side.x, 0);
        const rside = Geometry.hitRect("right", 200, 1000, base);
        compare(rside.x, 198);
        const idle = Object.assign({}, base, {revealed: true});
        const shelf = Geometry.hitRect("right", 200, 1000, idle);
        compare(shelf.y, 300);
        compare(shelf.h, 400);
        compare(shelf.w, 68 + 6);
        const hover = Geometry.hitRect("left", 200, 1000, Object.assign({}, idle, {pointerActive: true}));
        compare(hover.w, 68 + 6 + 29 + 44);
        const drag = Geometry.hitRect("left", 200, 1000, Object.assign({}, idle, {dragging: true}));
        compare(drag.w, 200);
    }

    // The whole drawn icon takes the pointer (owner report 2026-10-25): the tile stays iconSize + indicator across, the icon grows
    // beyond it, and the hit box joins both. Tile boxes as Dock.qml sets them (bottom: iconPx x tileCross; side: tileCross x iconPx).
    function test_hitBoxCoversTheWholeMagnifiedIcon() {
        const area = base.indicatorSize + base.spacing;
        const cross = base.iconSize + area;
        const eps = 1e-9;
        for (const scale of [1, 1.6, 2.5]) {
            const px = base.iconSize * scale;
            // Bottom: the icon grows up (negative y in the tile); the tile's own box (dot area below) stays part of it.
            let b = Geometry.hitBox("bottom", base.iconSize, px, area, px, cross);
            let o = Geometry.iconOrigin("bottom", base.iconSize, px, area);
            verify(b.x <= o.x + eps && b.y <= o.y + eps && b.x + b.w >= o.x + px - eps && b.y + b.h >= o.y + px - eps, "bottom " + scale);
            compare(b.x, 0);
            compare(b.w, px);
            compare(b.y, Math.min(0, base.iconSize - px));
            compare(b.y + b.h, cross);
            // Left: the icon grows to the right, beyond the tile.
            b = Geometry.hitBox("left", base.iconSize, px, area, cross, px);
            o = Geometry.iconOrigin("left", base.iconSize, px, area);
            verify(b.x <= o.x + eps && b.y <= o.y + eps && b.x + b.w >= o.x + px - eps && b.y + b.h >= o.y + px - eps, "left " + scale);
            compare(b.x, 0);
            compare(b.y, 0);
            compare(b.h, px);
            compare(b.w, Math.max(cross, area + px));
            // Right: the icon grows to the left.
            b = Geometry.hitBox("right", base.iconSize, px, area, cross, px);
            o = Geometry.iconOrigin("right", base.iconSize, px, area);
            verify(b.x <= o.x + eps && b.y <= o.y + eps && b.x + b.w >= o.x + px - eps && b.y + b.h >= o.y + px - eps, "right " + scale);
            compare(b.x, Math.min(0, base.iconSize - px));
            compare(b.x + b.w, cross);
            compare(b.h, px);
        }
        // Unmagnified, the hit box is the tile: nothing grows.
        const t = Geometry.hitBox("bottom", base.iconSize, base.iconSize, area, base.iconSize, cross);
        compare(t.y, 0);
        compare(t.h, cross);
        // The share of the icon that the tile alone covered (the dead part): 1 - 1/scale.
        const dead = Geometry.hitBox("bottom", base.iconSize, base.iconSize * 2.5, area, base.iconSize * 2.5, cross);
        fuzzyCompare(-dead.y / (base.iconSize * 2.5), 0.6, 1e-9);
    }

    // Where hit boxes share a point the tile drawn on top owns it (higher z, equal z the later tile); touching boxes share none.
    function test_hitOwnerIsTheTileDrawnOnTop() {
        const boxes = [{x: 0, y: 0, w: 100, h: 100, z: 0}, {x: 100, y: 0, w: 100, h: 100, z: 0}, null, {x: 150, y: 0, w: 100, h: 100, z: 0}];
        compare(Geometry.hitOwner(boxes, 50, 50), 0);
        // Touching boxes: 100 belongs to the second only.
        compare(Geometry.hitOwner(boxes, 99.9, 50), 0);
        compare(Geometry.hitOwner(boxes, 100, 50), 1);
        // 160 is in boxes 1 and 3 (the same z): the later one is drawn on top.
        compare(Geometry.hitOwner(boxes, 160, 50), 3);
        // A dragged tile (z 100) wins over a later neighbour.
        boxes[1].z = 100;
        compare(Geometry.hitOwner(boxes, 160, 50), 1);
        compare(Geometry.hitOwner(boxes, 240, 50), 3);
        // Outside every box (or over null): nobody.
        compare(Geometry.hitOwner(boxes, 300, 50), -1);
        compare(Geometry.hitOwner(boxes, 50, 150), -1);
        compare(Geometry.hitOwner([], 1, 1), -1);
        compare(Geometry.hitOwner([null], 1, 1), -1);
    }

    function test_iconAndDotSitOnOppositeSidesOfTheTile() {
        const area = 0;
        // Unmagnified: the icon is at the tile's origin on the outward side of the dot.
        compare(Geometry.iconOrigin("bottom", 48, 48, area).y, 0);
        compare(Geometry.iconOrigin("left", 48, 48, area).x, area);
        compare(Geometry.iconOrigin("right", 48, 48, area).x, 0);
        // Magnified 1.5x: it grows away from the screen edge, its edge-side stays put.
        const bottom = Geometry.iconOrigin("bottom", 48, 72, area);
        compare(bottom.y + 72, 48);
        const right = Geometry.iconOrigin("right", 48, 72, area);
        compare(right.x + 72, 48);
        const left = Geometry.iconOrigin("left", 48, 72, area);
        compare(left.x, area);
        // The dot is on the screen-edge side, spacing away from the icon, and the hover lift is cancelled.
        // It sits in the padding, dock.indicatorGap (3) from the icon: with a 10-pt padding and a 4-pt dot its centre is 5 from the shelf edge.
        const dotB = Geometry.dotOrigin("bottom", 48, 48, 48, 3, 4, 0);
        compare(dotB.y, 51);
        compare(dotB.x, 22);
        compare(dotB.y + 2 - (48 + 10), -5);
        compare(Geometry.dotOrigin("right", 48, 48, 48, 3, 4, 0).x, 51);
        compare(Geometry.dotOrigin("left", 48, 48, 48, 3, 4, 0).x, -7);
        compare(Geometry.dotOrigin("left", 48, 48, 48, 3, 4, 5).x, -12);
        compare(Geometry.dotOrigin("right", 48, 48, 48, 3, 4, 5).x, 56);
        compare(Geometry.dotOrigin("bottom", 48, 48, 48, 3, 4, 5).y, 56);
    }

    function test_tooltipIsOnTheOutwardSideOfTheIcon() {
        const area = 0;
        // Bottom: above the icon, centred (the formula the Dock always used).
        const b = Geometry.tooltipOrigin("bottom", 48, 56, 48, 48, area, 8, 100, 30);
        compare(b.x, -26);
        compare(b.y, 56 - area - 48 - 8 - 30);
        // With the shelf padding the tail tip is `gap` beyond the shelf edge, not beside the icon (audit 2026-10-25: it sat
        // 1.5 inside the shelf): shelf edge = icon top - padding.
        const shelfTop = 56 - 48 - 10;
        compare(Geometry.tooltipOrigin("bottom", 48, 56, 48, 48, area, 8, 100, 30, 10).y + 30, shelfTop - 8);
        // Left: right of the icon, vertically centred on the tile; right: left of it.
        const l = Geometry.tooltipOrigin("left", 56, 48, 48, 48, area, 8, 100, 30);
        compare(l.x, area + 48 + 8);
        compare(l.y, 9);
        verify(l.x > area + 48);
        const r = Geometry.tooltipOrigin("right", 56, 48, 48, 48, area, 8, 100, 30);
        compare(r.x, 48 - 48 - 8 - 100);
        compare(r.y, 9);
        compare(Geometry.tooltipTailSide("left"), "left");
        compare(Geometry.tooltipTailSide("right"), "right");
        compare(Geometry.tooltipTailSide("bottom"), "bottom");
        // A magnified icon pushes the label out with it.
        verify(Geometry.tooltipOrigin("left", 56, 72, 48, 72, area, 8, 100, 30).x > l.x);
        verify(Geometry.tooltipOrigin("right", 56, 72, 48, 72, area, 8, 100, 30).x < r.x);
    }

    function test_iconInsideTheShelfIsTheMinimizeTarget() {
        // The icon of tile n, placed the way the Dock places it (shelf, padding, tile box, icon origin), is the rectangle the
        // compositor animates to.
        const thick = DockModel.shelfHeight(m48);
        const area = 0;
        for (const edge of Geometry.EDGES) {
            const w = Geometry.isVertical(edge) ? 300 : 1000;
            const h = Geometry.isVertical(edge) ? 1000 : 300;
            const shelf = Geometry.shelfRect(edge, w, h, 400, thick, 6, 0);
            const icon = Geometry.iconOrigin(edge, 48, 48, area);
            // The tile row starts `padding` into the shelf and the tile is 150 px along the main axis from there.
            const main = 150;
            const x = shelf.x + base.padding + (Geometry.isVertical(edge) ? 0 : main) + icon.x;
            const y = shelf.y + base.padding + (Geometry.isVertical(edge) ? main : 0) + icon.y;
            const mainCenter = Geometry.mainOf(edge, shelf.x, shelf.y) + base.padding + main + 24;
            const target = Geometry.tileRect(edge, w, h, mainCenter, 48, 6, base.padding, area);
            compare(target.x, x, edge);
            compare(target.y, y, edge);
            compare(target.w, 48);
            compare(target.h, 48);
        }
    }

    function test_menuAnchorIsBesideTheShelfWithRoomForTheTail() {
        const thick = 76;
        const b = Geometry.menuAnchor("bottom", 1920, 1080, 500, thick, 6, 16, 13);
        compare(b.align, "above");
        compare(b.x, 500);
        compare(b.y, 1080 - (6 + 76 + 16 + 13));
        const l = Geometry.menuAnchor("left", 1920, 1080, 400, thick, 6, 16, 13);
        compare(l.align, "rightOf");
        compare(l.x, 6 + 76 + 16 + 13);
        compare(l.y, 400);
        const r = Geometry.menuAnchor("right", 1920, 1080, 400, thick, 6, 16, 13);
        compare(r.align, "leftOf");
        compare(r.x, 1920 - (6 + 76 + 16 + 13));
        compare(r.y, 400);
    }

    function test_dragComponents() {
        compare(Geometry.dragMain("bottom", 7, -30), 7);
        compare(Geometry.dragMain("left", 7, -30), -30);
        compare(Geometry.dragOutward("bottom", 7, -30), 30);
        compare(Geometry.dragOutward("left", 40, 3), 40);
        compare(Geometry.dragOutward("right", -40, 3), 40);
        compare(Geometry.dragOutward("right", 40, 3), -40);
        for (const edge of Geometry.EDGES) {
            const v = Geometry.dragVector(edge, 12, 34);
            compare(Geometry.dragMain(edge, v.x, v.y), 12, edge);
            compare(Geometry.dragOutward(edge, v.x, v.y), 34, edge);
        }
    }

    function test_windowOriginAndDepth() {
        compare(Geometry.windowOrigin("bottom", 1920, 1080, 1920, 300).y, 780);
        compare(Geometry.windowOrigin("left", 1920, 1080, 300, 1044).x, 0);
        compare(Geometry.windowOrigin("left", 1920, 1080, 300, 1044).y, 36);
        compare(Geometry.windowOrigin("right", 1920, 1080, 300, 1044).x, 1620);
        compare(Geometry.depth(76, 6, 29, 168), 279);
        // The label beside a side Dock needs its width, above a bottom Dock its height; the drag room is the floor.
        compare(Geometry.room("bottom", 36, 240, 168), 168);
        compare(Geometry.room("left", 36, 240, 168), 240);
        compare(Geometry.room("right", 36, 100, 168), 168);
    }

    function test_footprintIsOnTheDocksEdgeOnly() {
        const zone = DockModel.reservedHeight(m48, false);
        const left = Geometry.footprint("left", m48, false);
        compare(left.left, zone);
        compare(left.right, 0);
        compare(left.bottom, 0);
        compare(Geometry.footprint("right", m48, false).right, zone);
        compare(Geometry.footprint("bottom", m48, false).bottom, zone);
        const hidden = Geometry.footprint("left", m48, true);
        compare(hidden.left + hidden.right + hidden.bottom, 0);
    }

    // Magnify.js is axis free: a column of tiles with the pointer at the same distance along it scales like a row.
    function test_magnificationAlongAColumnIsTheSameCurve() {
        const widths = [48, 48, 5, 48, 48, 48];
        const flags = [false, false, true, false, false, false];
        const centers = Magnify.centersFor(widths, 4, 100);
        const along = Magnify.slotScales(centers, widths, 4, flags, centers[3] + 5, 52, 1.6, 3);
        const row = Geometry.mainOf("bottom", centers[3] + 5, 777);
        const col = Geometry.mainOf("left", 777, centers[3] + 5);
        compare(row, col);
        const again = Magnify.slotScales(centers, widths, 4, flags, col, 52, 1.6, 3);
        compare(JSON.stringify(again), JSON.stringify(along));
        verify(along[3] > along[4] && along[4] > along[5], JSON.stringify(along));
        compare(Magnify.slotScales(centers, widths, 4, flags, 6000, 52, 1.6, 3)[0], 1);
    }

    // ---- resize by dragging the separator ----

    function test_resizeFollowsTheDragAwayFromTheEdge() {
        // Bottom: up (negative y) grows, down shrinks, twice the distance; along the Dock nothing happens.
        compare(Geometry.resizeSize(48, "bottom", 0, -10, 32, 96), 68);
        compare(Geometry.resizeSize(48, "bottom", 0, 6, 32, 96), 36);
        compare(Geometry.resizeSize(48, "bottom", 300, 0, 32, 96), 48);
        // Left: right grows. Right: left grows.
        compare(Geometry.resizeSize(48, "left", 10, 90, 32, 96), 68);
        compare(Geometry.resizeSize(48, "left", -4, 0, 32, 96), 40);
        compare(Geometry.resizeSize(48, "right", -10, 0, 32, 96), 68);
        compare(Geometry.resizeSize(48, "right", 10, 0, 32, 96), 32);
    }

    function test_resizeIsClampedAndWhole() {
        compare(Geometry.resizeSize(48, "bottom", 0, -500, 32, 96), 96);
        compare(Geometry.resizeSize(48, "bottom", 0, 500, 32, 96), 32);
        compare(Geometry.resizeSize(48, "bottom", 0, -3.3, 32, 96), 55);
        compare(Geometry.resizeSize(48, "bottom", 0, 0, 32, 96), 48);
        // An undefined drag keeps the size it started with.
        compare(Geometry.resizeSize(48, "bottom", NaN, NaN, 32, 96), 48);
    }

    // ---- one Dock across displays ----

    function test_dockScreenIsTheChosenOneWhileItExists() {
        compare(Geometry.dockScreen("DP-2", ["DP-1", "DP-2"], "DP-1"), "DP-2");
        // Chosen output unplugged: the focused one, else the first.
        compare(Geometry.dockScreen("DP-3", ["DP-1", "DP-2"], "DP-2"), "DP-2");
        compare(Geometry.dockScreen("DP-3", ["DP-1", "DP-2"], "HDMI-9"), "DP-1");
        compare(Geometry.dockScreen("", ["DP-1", "DP-2"], ""), "DP-1");
        compare(Geometry.dockScreen("", [], "DP-1"), "");
        // The development override names the start output; it never beats a choice and is ignored when unknown.
        compare(Geometry.dockScreen("", ["DP-1", "DP-2"], "DP-1", "DP-2"), "DP-2");
        compare(Geometry.dockScreen("DP-1", ["DP-1", "DP-2"], "DP-2", "DP-2"), "DP-1");
        compare(Geometry.dockScreen("", ["DP-1", "DP-2"], "DP-1", "HDMI-9"), "DP-1");
    }

    // ADR-0044: the Dock is created before the settings are read and the main display is known. Nothing is latched until both
    // are, so the fallback output never sticks; then it starts on the main display (the preferred output) whatever has focus.
    function test_theSettingLoadedAfterTheDockWasCreatedStillDecides() {
        const names = ["WAYLAND-1", "GF-REF"];
        // Component.onCompleted: settings not loaded, main display unknown (hint "" and focus on the first output).
        compare(Geometry.latchScreenWhen(false, "", names, "WAYLAND-1", ""), "");
        // Settings loaded but the displays are not described yet: still nothing.
        compare(Geometry.latchScreenWhen(false, "", names, "WAYLAND-1", "WAYLAND-1"), "");
        // Both known, the stored main display is GF-REF: it latches there.
        compare(Geometry.latchScreenWhen(true, "", names, "WAYLAND-1", "GF-REF"), "GF-REF");
        // Latched once: a later focus change or main display change does not go through here.
        compare(Geometry.latchScreenWhen(true, "GF-REF", names, "WAYLAND-1", "WAYLAND-1"), "GF-REF");
        // The first layout waits for both (Geometry.settledOn gets settings && main ready).
        verify(!Geometry.settledOn({settings: false, apps: true, screens: names, start: "GF-REF", waited: false}));
        verify(Geometry.settledOn({settings: true, apps: true, screens: names, start: "GF-REF", waited: false}));
    }

    // A focus change latched a fallback output before Hyprland described the outputs; then the main display becomes known while the
    // Dock is not settled: the latch is dropped (not kept, not ignored) and the first layout latches on the main display.
    function test_aMainDisplayKnownBeforeTheDockSettlesDropsAFallbackLatch() {
        const names = ["WAYLAND-1", "GF-REF"];
        let r = Geometry.afterMainChange(false, "WAYLAND-1", "GF-REF");
        compare(r.chosen, "");
        compare(r.move, "");
        compare(Geometry.settleScreen(r.chosen, names, "WAYLAND-1", "GF-REF"), "GF-REF");
        // Settled: the Dock moves, its latch stays until then.
        r = Geometry.afterMainChange(true, "WAYLAND-1", "GF-REF");
        compare(r.chosen, "WAYLAND-1");
        compare(r.move, "GF-REF");
        // No main display: nothing changes either way.
        compare(Geometry.afterMainChange(false, "WAYLAND-1", "").chosen, "WAYLAND-1");
        compare(Geometry.afterMainChange(true, "WAYLAND-1", "").move, "");
    }

    function test_theDockStartsOnTheFocusedOutputAndStaysThere() {
        compare(Geometry.latchScreen("", ["DP-1", "DP-2"], "DP-2"), "DP-2");
        // Focus moving on does not move it; an unknown focus latches nothing.
        compare(Geometry.latchScreen("DP-2", ["DP-1", "DP-2"], "DP-1"), "DP-2");
        compare(Geometry.latchScreen("", ["DP-1", "DP-2"], ""), "");
        compare(Geometry.latchScreen("", ["DP-1", "DP-2"], "DP-7"), "");
        compare(Geometry.latchScreen("", ["DP-1", "DP-2"], "DP-1", "DP-2"), "DP-2");
    }

    function test_theEdgeDwellOfAnotherOutputTakesTheDock() {
        // A machine that starts to reveal on an output without the Dock is the pointer resting on its edge strip.
        verify(Geometry.movesDock(false, "hidden", "revealing"));
        verify(Geometry.movesDock(false, "hiding", "revealing"));
        // Once, not on every frame of the reveal.
        verify(!Geometry.movesDock(false, "revealing", "revealing"));
        // The Dock's own output, and a machine that is not revealing, never move it.
        verify(!Geometry.movesDock(true, "hidden", "revealing"));
        verify(!Geometry.movesDock(false, "hidden", "hidden"));
        verify(!Geometry.movesDock(false, "shown", "hiding"));
        // With the real machine: the pointer on the strip for the dwell, and only then.
        const timing = {hideGrace: 250, hideDuration: 300, revealDwell: 120, revealDuration: 240};
        let m = {state: "hidden", visible: 0, timer: 0};
        let moved = -1;
        for (let t = 0; t < 400 && moved < 0; t += 16) {
            const next = AutoHide.step(m, {pointer: true}, true, timing, 16);
            if (Geometry.movesDock(false, m.state, next.state))
                moved = t;
            m = next;
        }
        verify(moved >= 100 && moved <= 140, "moved at " + moved + " ms");
        // No pointer, no move, however long.
        m = {state: "hidden", visible: 0, timer: 0};
        for (let t = 0; t < 2000; t += 16) {
            const next = AutoHide.step(m, {}, true, timing, 16);
            verify(!Geometry.movesDock(false, m.state, next.state));
            m = next;
        }
    }

    // The owner's report (2026-11-22, 3 displays): the Dock, its auto-hide and its glass were on one display only. With
    // dock.allDisplays (default) every output shows a Dock; off, only the one that has it (macOS).
    function test_hasDockOnEveryOutputWithAllDisplays() {
        verify(Geometry.hasDock(true, false, "DP-1"));
        verify(Geometry.hasDock(true, true, "eDP-1"));
        verify(Geometry.hasDock(false, true, "eDP-1"));
        verify(!Geometry.hasDock(false, false, "DP-1"));
        // A window being destroyed has no output name: no Dock.
        verify(!Geometry.hasDock(true, true, ""));
        // Nothing but true turns it on (a missing value is not "all").
        verify(!Geometry.hasDock(undefined, false, "DP-1"));
        // Auto-hide on an output that has a Dock follows the setting, on every output; a stay-away output always hides.
        verify(!DockModel.hides(false, Geometry.hasDock(true, false, "DP-1"), false, false));
        verify(DockModel.hides(true, Geometry.hasDock(true, false, "DP-1"), false, false));
        verify(DockModel.hides(false, Geometry.hasDock(false, false, "DP-1"), false, false));
        // With a Dock everywhere nothing takes the Dock from another output.
        verify(!Geometry.movesDock(Geometry.hasDock(true, false, "DP-1"), "hidden", "revealing"));
    }

    function test_smallSizeKeepsTheBadgeReadable() {
        const small = Geometry.metrics(32, base);
        compare(small.badgeSize, 20);
        compare(small.badgeScale, 1);
        compare(small.separatorHeight, 33);
        fuzzyCompare(small.iconRadius, 11 * 32 / 48, 1e-9);
    }

    // Shrink to fit (REQ-DOCK-PAR-d8): 12 tiles + 1 separator of 4+4+? px.
    function test_fitSizeKeepsTheRequestedSizeWhenItFits() {
        // 10 tiles of 48: 480 + 9 gaps of 4 + 2 x 10 = 536 px, room for 1920
        compare(Geometry.fitSize(48, 10, 0, 12, 4, 10, 1908, 16), 48);
        // exactly full: 480 + 9 x 4 + 20 = 536
        compare(Geometry.fitSize(48, 10, 0, 12, 4, 10, 536, 16), 48);
    }

    function test_fitSizeShrinksUntilTheShelfFits() {
        // 20 tiles + 1 separator in 800 px: fixed = 20 + 12 + 20 x 4 = 112 -> floor(688 / 20) = 34
        compare(Geometry.fitSize(48, 20, 1, 12, 4, 10, 800, 16), 34);
        const size = Geometry.fitSize(96, 20, 1, 12, 4, 10, 800, 16);
        compare(size, 34);
        verify(size * 20 + 112 <= 800);
        verify((size + 1) * 20 + 112 > 800);
    }

    function test_fitSizeNeverGoesBelowTheFloorOrAboveTheRequest() {
        compare(Geometry.fitSize(48, 200, 1, 12, 4, 10, 800, 16), 16);
        // a requested size under the floor is kept (the user asked for it)
        compare(Geometry.fitSize(12, 200, 1, 12, 4, 10, 800, 16), 12);
        compare(Geometry.fitSize(32, 3, 1, 12, 4, 10, 4000, 16), 32);
    }

    function test_fitSizeIgnoresUnknownRoom() {
        compare(Geometry.fitSize(48, 10, 0, 12, 4, 10, 0, 16), 48);
        compare(Geometry.fitSize(48, 10, 0, 12, 4, 10, NaN, 16), 48);
        compare(Geometry.fitSize(48, 0, 0, 12, 4, 10, 100, 16), 48);
    }

    // ---- the rectangle a minimizing window flies to (Compositor.dockRect -> Dock.tileRect -> minimizedSlotRect) ----

    readonly property var dockItems: [
        {kind: "files"}, {kind: "apps"}, {kind: "app"}, {kind: "app"}, {kind: "separator", divider: true}, {kind: "app"},
        {kind: "separator"}, {kind: "folder"}, {kind: "minimized"}, {kind: "trash"}
    ]

    function slotOptions(extra) {
        return Object.assign({index: 0, adding: false, iconSize: 48, spacing: 4, separatorWidth: 12, edge: "bottom", screenW: 1920, screenH: 1080,
                depth: 140, margin: 6, padding: 10, indicatorArea: 8}, extra);
    }

    function inside(r, w, h) {
        return isFinite(r.x) && isFinite(r.y) && r.w >= 1 && r.h >= 1 && r.x >= 0 && r.y >= 0 && r.x + r.w <= w && r.y + r.h <= h;
    }

    function test_minimizedSlotIsFiniteNotEmptyAndInsideTheOutput() {
        for (const adding of [true, false]) {
            const r = Geometry.minimizedSlotRect(dockItems, slotOptions({adding: adding}));
            verify(r !== null);
            verify(inside(r, 1920, 1080), JSON.stringify(r));
            compare(r.w, 48);
            compare(r.h, 48);
        }
    }

    function test_minimizedSlotIsAfterTheFolderStacksAndBeforeTheTrash() {
        // adding: a new tile inserted where the Trash was pushed to the right
        const first = Geometry.minimizedSlotRect(dockItems, slotOptions({adding: true, index: 1}));
        const none = Geometry.minimizedSlotRect(dockItems.filter(it => it.kind !== "folder"), slotOptions({adding: true, index: 1}));
        verify(first !== null && none !== null);
        // with a folder stack the slot is one tile (pitch) further along than without
        verify(Math.abs((first.x - none.x) - 0) < 60);
        const a = Geometry.minimizedSlotRect(dockItems, slotOptions({adding: false, index: 0}));
        const b = Geometry.minimizedSlotRect(dockItems, slotOptions({adding: true, index: 1}));
        verify(b.x > a.x, "the next minimized slot is to the right");
    }

    function test_minimizedSlotDoesNotNeedAWindowAndNeverLeavesTheOutput() {
        // Tiny and huge outputs, and a Dock far wider than the output: always inside, never NaN.
        for (const s of [{w: 320, h: 240}, {w: 1280, h: 720}, {w: 3840, h: 2160}]) {
            for (const edge of ["bottom", "left", "right"]) {
                const r = Geometry.minimizedSlotRect(dockItems, slotOptions({edge: edge, screenW: s.w, screenH: s.h, adding: true}));
                verify(r !== null, edge);
                verify(inside(r, s.w, s.h), edge + " " + s.w + "x" + s.h + " " + JSON.stringify(r));
            }
        }
    }

    function test_minimizedSlotRefusesWhatItCannotAnswer() {
        compare(Geometry.minimizedSlotRect([], slotOptions({})), null);
        compare(Geometry.minimizedSlotRect([{kind: "app"}, {kind: "trash"}], slotOptions({})), null, "no divider");
        compare(Geometry.minimizedSlotRect(dockItems, slotOptions({index: -1})), null);
        compare(Geometry.minimizedSlotRect(dockItems, slotOptions({iconSize: 0})), null);
        compare(Geometry.minimizedSlotRect(dockItems, slotOptions({screenW: 0})), null);
        compare(Geometry.minimizedSlotRect(dockItems, slotOptions({index: 40})), null, "a slot that does not exist");
    }

    function test_clampInto() {
        const box = {x: 0, y: 0, w: 100, h: 50};
        compare(Geometry.clampInto({x: -5, y: 60, w: 10, h: 10}, box), {x: 0, y: 40, w: 10, h: 10});
        compare(Geometry.clampInto({x: 95, y: 5, w: 10, h: 10}, box), {x: 90, y: 5, w: 10, h: 10});
        compare(Geometry.clampInto({x: 3, y: 4, w: 10, h: 10}, box), {x: 3, y: 4, w: 10, h: 10});
    }

    // The shelf the Dock lays out (icons, separators, gaps between all tiles, padding at both ends) never exceeds the room once
    // the size was reduced below the request, for every count the Dock can have (nested finding: 32 tiles on 1920 px).
    function test_fitSizeShelfNeverExceedsTheRoom() {
        for (let tiles = 1; tiles <= 60; tiles++) {
            for (const seps of [0, 1, 2]) {
                for (const room of [800, 1280, 1920, 2560]) {
                    const available = room - 12;
                    const size = Geometry.fitSize(96, tiles, seps, 9, 4, 10, available, 16);
                    const shelf = tiles * size + seps * 9 + (tiles + seps - 1) * 4 + 20;
                    if (size > 16)
                        verify(shelf <= available, tiles + " tiles, " + seps + " separators, " + room + " px: size " + size + " shelf " + shelf);
                }
            }
        }
        // 32 tiles of the nested run: 30 icons and 2 separators on 1920 px
        const size = Geometry.fitSize(96, 30, 2, 9, 4, 10, 1908, 16);
        verify(30 * size + 18 + 31 * 4 + 20 <= 1908);
        verify(size >= 50);
    }

    // ---- the magnified Dock stays inside the output (post-merge review: 1990 px on 1920 at 1.6) ----

    function kindsOf(tiles, seps) {
        const out = [];
        for (let i = 0; i < tiles; i++)
            out.push(false);
        for (let i = 0; i < seps; i++)
            out.splice(Math.floor((i + 1) * tiles / (seps + 1)), 0, true);
        return out;
    }

    function magOptions(maxScale) {
        return {separatorWidth: 9, spacing: 4, padding: 10, maxScale: maxScale, radius: 3};
    }

    // The slack is for the rounding of the magnified worst case only: with magnification off a shelf that fits exactly stays at the
    // size asked for (the review: 472 configurations lost a pixel to a slack that has no reason to be there).
    function test_noSlackWithoutMagnification() {
        for (const tiles of [3, 7, 12]) {
            const kinds = kindsOf(tiles, 1);
            const o = Object.assign(magOptions(1), {slack: 2});
            const exact = Geometry.magnifiedShelf(96, kinds, o);
            compare(Geometry.fitSizeMagnified(96, kinds, exact, 16, o), 96, tiles + " tiles in exactly their width");
            compare(Geometry.fitSizeMagnified(96, kinds, exact, 16, Object.assign(magOptions(1), {slack: 0})), 96);
            // one pixel less still shrinks, by one size step
            verify(Geometry.fitSizeMagnified(96, kinds, exact - 1, 16, o) < 96);
            // magnified, the slack stays: a shelf that would fit to the pixel keeps 2 px free
            const m = Object.assign(magOptions(1.6), {slack: 2});
            const widest = Geometry.magnifiedShelf(96, kinds, m);
            verify(Geometry.fitSizeMagnified(96, kinds, widest + 1, 16, m) < 96, tiles + " tiles magnified");
        }
    }

    function test_magnifiedShelfGrowsWithMagnification() {
        const kinds = kindsOf(31, 1);
        const rest = Geometry.magnifiedShelf(48, kinds, magOptions(1));
        compare(rest, 31 * 48 + 9 + 31 * 4 + 20);
        const m16 = Geometry.magnifiedShelf(48, kinds, magOptions(1.6));
        const m20 = Geometry.magnifiedShelf(48, kinds, magOptions(2.0));
        verify(m16 > rest + 30, "1.6 grows the shelf: " + m16 + " vs " + rest);
        verify(m20 > m16, "2.0 grows it more: " + m20);
        // the growth is about (m - 1) x radius x size, as the spec says for the budget
        verify(Math.abs((m16 - rest) - 0.6 * 3 * 48) < 0.25 * 0.6 * 3 * 48, "growth " + (m16 - rest));
    }

    function test_fitSizeMagnifiedKeepsTheMagnifiedShelfInsideTheRoom() {
        for (const m of [1, 1.6, 2.5]) {
            for (const tiles of [10, 31, 55]) {
                for (const requested of [48, 96]) {
                    for (const room of [1280, 1920, 2560]) {
                        const kinds = kindsOf(tiles, 1);
                        const size = Geometry.fitSizeMagnified(requested, kinds, room - 12, 16, magOptions(m));
                        verify(size <= requested && size >= Math.min(requested, 16));
                        if (size > 16 && size < requested) {
                            const shelf = Geometry.magnifiedShelf(size, kinds, magOptions(m));
                            verify(shelf <= room - 12, "m " + m + ", " + tiles + " tiles, " + requested + " px, room " + room + ": size " + size + " shelf " + shelf);
                            // and it is the largest: one more would not fit
                            verify(Geometry.magnifiedShelf(size + 1, kinds, magOptions(m)) > room - 12, "not the largest: " + size);
                        }
                        if (size === requested)
                            verify(Geometry.magnifiedShelf(size, kinds, magOptions(m)) <= room - 12 || size <= 16);
                    }
                }
            }
        }
    }

    function test_fitSizeMagnifiedWithoutMagnificationIsFitSize() {
        for (const tiles of [10, 31, 45]) {
            const kinds = kindsOf(tiles, 1);
            compare(Geometry.fitSizeMagnified(96, kinds, 1908, 16, magOptions(1)), Geometry.fitSize(96, tiles, 1, 9, 4, 10, 1908, 16));
        }
    }

    function test_nestedFullDockMagnifiedFits() {
        // 31 icons and a separator on 1920 px, magnification 1.6 (the review's case)
        const kinds = kindsOf(31, 1);
        const size = Geometry.fitSizeMagnified(64, kinds, 1908, 16, magOptions(1.6));
        verify(size < 64);
        verify(Geometry.magnifiedShelf(64, kinds, magOptions(1.6)) > 1908, "the request alone would overflow");
        verify(Geometry.magnifiedShelf(size, kinds, magOptions(1.6)) <= 1908);
    }

    // The widest the shelf gets, found by brute force (the pointer at every px, Magnify.slotScales as the Dock does), against the
    // size fitSizeMagnified chose: never over the room (the review found 19 of 19,200 configurations over by up to 4.64 px).
    function bruteWidest(size, kinds, o) {
        const widths = kinds.map(k => k ? o.separatorWidth : size);
        const total = Magnify.totalWidth(widths, o.spacing);
        const pitch = size + o.spacing;
        const reach = o.radius * pitch;
        const centers = Magnify.centersFor(widths, o.spacing, reach);
        let worst = total + 2 * o.padding;
        for (let p = 0; p <= total + 2 * reach; p += 1) {
            const sc = Magnify.slotScales(centers, widths, o.spacing, kinds, p, pitch, o.maxScale, o.radius);
            const w = Magnify.totalWidth(widths.map((x, i) => x * sc[i]), o.spacing) + 2 * o.padding;
            if (w > worst)
                worst = w;
        }
        return worst;
    }

    function test_noConfigurationExceedsTheRoomByBruteForce() {
        let checked = 0;
        for (const m of [1.2, 1.6, 2.0, 2.5]) {
            for (const tiles of [12, 29, 40]) {
                for (const room of [1280, 1920]) {
                    const kinds = kindsOf(tiles, 1);
                    const available = room - 12;
                    const size = Geometry.fitSizeMagnified(96, kinds, available, 16, magOptions(m));
                    if (size <= 16)
                        continue;
                    const widest = bruteWidest(size, kinds, magOptions(m));
                    verify(widest <= available, "m " + m + ", " + tiles + " tiles, room " + room + ": size " + size + " widest " + widest + " over " + (widest - available));
                    checked++;
                }
            }
        }
        verify(checked >= 10);
    }

    // The exact worst case (no fixed slack): side Docks and small outputs had configurations over the room by up to 1.98 px with a
    // half-tile sampling, and 2 px of slack made 7,212 Docks shrink for nothing. Against a brute force at 1 px: never over the room,
    // and the size chosen is the largest within 1 px of the room (no shrink for nothing).
    function test_theWorstCaseIsExact() {
        let checked = 0;
        for (const m of [1.2, 1.6, 2.0, 2.5]) {
            for (const tiles of [2, 3, 6, 9]) {
                for (const seps of [0, 1]) {
                    for (const available of [564, 720, 1000]) {
                        const kinds = kindsOf(tiles, seps);
                        const o = Object.assign(magOptions(m), {slack: 0.25});
                        const size = Geometry.fitSizeMagnified(96, kinds, available, 16, o);
                        if (size <= 16)
                            continue;
                        const widest = bruteWidest(size, kinds, magOptions(m));
                        verify(widest <= available, "m " + m + ", " + tiles + " tiles + " + seps + " separators, room " + available + ": size " + size + " widest " + widest);
                        if (size < 96)
                            verify(bruteWidest(size + 1, kinds, magOptions(m)) > available - 1, "shrunk for nothing: size " + size + " in " + available + ", the next size has " + bruteWidest(size + 1, kinds, magOptions(m)));
                        checked++;
                    }
                }
            }
        }
        verify(checked >= 40, "checked " + checked);
        // the reviewers' cases: 3 tiles + 1 separator at 2.5 in 720 px, at 2 in 564 px
        for (const c of [{m: 2.5, room: 720}, {m: 2, room: 564}]) {
            const kinds = kindsOf(3, 1);
            const size = Geometry.fitSizeMagnified(96, kinds, c.room, 16, Object.assign(magOptions(c.m), {slack: 0.25}));
            verify(bruteWidest(size, kinds, magOptions(c.m)) <= c.room, "m " + c.m + " room " + c.room + " size " + size);
        }
    }

    // Startup: the Dock window stays unmapped until the settings, the apps and the Dock's output are final, so it is drawn once.
    function test_settledOnWaitsForEveryInput() {
        const one = {settings: true, apps: true, screens: ["DP-1"], start: ""};
        const two = {settings: true, apps: true, screens: ["DP-1", "DP-2"], start: "DP-2"};
        verify(Geometry.settledOn(one), "one output needs no focus information");
        verify(Geometry.settledOn(two));
        verify(!Geometry.settledOn(Object.assign({}, one, {settings: false})), "settings file not read yet (default edge and size)");
        verify(!Geometry.settledOn(Object.assign({}, one, {apps: false})), "desktop entries not loaded (pinned icons)");
        verify(!Geometry.settledOn(Object.assign({}, one, {screens: []})), "no output yet");
        verify(!Geometry.settledOn(Object.assign({}, two, {start: ""})), "two outputs and no focused one: the Dock would start on the wrong side");
        verify(!Geometry.settledOn(null));
        verify(!Geometry.settledOn({}));
        // The fallback timer stands in for the apps model and the focused output, never for the settings file or the outputs.
        verify(Geometry.settledOn(Object.assign({}, two, {start: "", apps: false, waited: true})), "waited: the Dock appears");
        verify(!Geometry.settledOn(Object.assign({}, one, {settings: false, waited: true})), "the settings file is always waited for");
        verify(!Geometry.settledOn(Object.assign({}, one, {screens: [], waited: true})), "no output, no Dock");
        verify(!Geometry.settledOn(Object.assign({}, two, {start: "", waited: false})));
    }

    // The fallback latch: no focused output when the Dock settles (timer ran out): it stays on the output it is on, and a focus
    // event arriving later does not move it.
    function test_settleScreenLatchesTheFallbackOutput() {
        const names = ["DP-1", "DP-2"];
        compare(Geometry.settleScreen("", names, "", ""), "DP-1", "no focus: the output it is on");
        compare(Geometry.dockScreen(Geometry.settleScreen("", names, "", ""), names, "DP-2", ""), "DP-1", "late focus does not move it");
        compare(Geometry.settleScreen("", names, "DP-2", ""), "DP-2", "focus known: the focused output");
        compare(Geometry.settleScreen("DP-2", names, "DP-1", ""), "DP-2", "an earlier choice is kept");
        compare(Geometry.settleScreen("", [], "", ""), "", "no output, nothing to latch");
        compare(Geometry.settleScreen("", names, "", "DP-2"), "DP-2", "the dev start hint");
    }

    // The latched start output and the settled gate together: focus arriving late does not move a Dock that already settled.
    function test_startScreenKnownOnlyOnceFocusArrives() {
        compare(Geometry.startScreen(["DP-1", "DP-2"], "", ""), "");
        compare(Geometry.startScreen(["DP-1", "DP-2"], "DP-2", ""), "DP-2");
        compare(Geometry.startScreen(["DP-1", "DP-2"], "HDMI-9", ""), "");
    }

    // Startup with auto-hide on: the machine of a window starts hidden and stays out of sight; one that started shown (the old
    // initial state) is visible for its whole grace and slides away in front of the user.
    function test_initialMachineHidesFromTheStart() {
        const timing = {hideGrace: 450, hideDuration: 250, revealDwell: 120, revealDuration: 200};
        let m = AutoHide.initial(true);
        compare(m.state, "hidden");
        compare(m.visible, 0);
        let shownMs = 0;
        for (let t = 0; t < 2000; t += 16) {
            m = AutoHide.step(m, {}, true, timing, 16);
            if (m.visible > 0)
                shownMs += 16;
        }
        compare(shownMs, 0, "a hidden start never draws the Dock");
        let old = AutoHide.create();
        let oldMs = 0;
        for (let t = 0; t < 2000; t += 16) {
            old = AutoHide.step(old, {}, true, timing, 16);
            if (old.visible > 0)
                oldMs += 16;
        }
        verify(oldMs > 400, "the shown start is what the fix replaces (" + oldMs + " ms)");
        compare(AutoHide.initial(false).state, "shown");
        compare(AutoHide.initial(false).visible, 1);
    }

    // The reveal waits for the surface to have the shape of the settled edge (the real surfaces: a bottom Dock is as wide as the
    // output, a side one as tall as the output less the menu bar's reserved strip, 1044 on 1080 as in the metrics test above).
    function test_placedNeedsTheShapeOfTheEdge() {
        verify(Geometry.placed("bottom", 1920, 190, 190));
        verify(Geometry.placed("left", 300, 1044, 300), "a side surface is shorter than the output");
        verify(Geometry.placed("right", 300, 1044, 300));
        verify(Geometry.placed("right", 300.4, 1044, 300), "rounding");
        verify(!Geometry.placed("left", 1920, 190, 190), "still the bottom-edge surface after the edge became left");
        verify(!Geometry.placed("bottom", 300, 1044, 300), "still the left-edge surface after the edge became bottom");
        verify(!Geometry.placed("bottom", 0, 0, 190), "not configured yet");
        verify(!Geometry.placed("bottom", 1920, 190, 0));
        verify(!Geometry.placed("left", 300, 200, 300), "not longer than across");
    }
}
