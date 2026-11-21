.pragma library
.import "DockModel.js" as DockModel
.import "Magnify.js" as Magnify

// Dock geometry (pure, unit-tested): the tile size (Settings > Desktop & Dock > Size) and what follows from it.
// `base` is the dock token set {iconSize, padding, indicatorSize, spacing, bottomMargin, separatorHeight, badgeSize,
// radiusIcon}; sizes are px. The tokens describe the default size (base.iconSize); everything that is proportional to
// the tile scales with it, the rest (padding, spacing, indicator, margin) stays.

// A stored size read as a tile size: a whole number of px inside [min, max], `fallback` for anything else.
function clampSize(value, min, max, fallback) {
    const n = Number(value);
    if (typeof value === "boolean" || value === null || value === "" || !isFinite(n))
        return fallback;
    return Math.round(Math.max(min, Math.min(max, n)));
}

// The metrics of a Dock whose tiles are `size` px (the shape DockModel.shelfHeight / reservedHeight take, plus the
// proportional parts). The icon corner radius and the separator follow the tile; the badge grows with it but never
// gets smaller than its token (it holds text).
function metrics(size, base) {
    const k = size / base.iconSize;
    return {
        iconSize: size,
        padding: base.padding,
        indicatorSize: base.indicatorSize,
        spacing: base.spacing,
        bottomMargin: base.bottomMargin,
        separatorHeight: Math.round(base.separatorHeight * k),
        iconRadius: base.radiusIcon * k,
        badgeScale: Math.max(1, k),
        badgeSize: Math.round(base.badgeSize * Math.max(1, k))
    };
}

// Shrink to fit (macOS: when the icons no longer fit along the screen, the whole Dock gets smaller so the shelf stays on
// screen). The tile size to use for `requested` px tiles: the requested size while the shelf fits in `available` px along the
// Dock, else the largest whole size that does, never below `floor`. `tiles` icon tiles, `separators` separators of
// `separatorWidth` px, `spacing` between neighbours, `padding` at each end. Magnified icons overhang the shelf and are not
// counted (macOS does not shrink for them either).
function fitSize(requested, tiles, separators, separatorWidth, spacing, padding, available, floor) {
    if (!(tiles > 0) || !(available > 0))
        return requested;
    const fixed = 2 * padding + separators * separatorWidth + Math.max(0, tiles + separators - 1) * spacing;
    const fit = Math.floor((available - fixed) / tiles);
    return Math.max(Math.min(requested, floor), Math.min(requested, fit));
}

// The widest the shelf gets while magnified (px, padding included): tiles of `size` px (`isSeparator[i]`: a separator, which is
// never magnified) laid out unmagnified, the pointer anywhere along them (every quarter tile, and past both ends), each tile taking
// its slot scale (Magnify.slotScales, as the Dock does). `o` = {separatorWidth, spacing, padding, maxScale, radius}. Without
// magnification (maxScale <= 1) the shelf at rest.
//
// Cost (audit A-05): the growth for one pointer position is not a sum over the tiles. Every icon tile is `size` px wide and its slot
// is one pitch long, so its growth is size / pitch times the integral of (scale - 1) over its slot; the slots of a run of icons
// (between two separators) tile the line, so the run's growth is one closed-form integral over the whole run (Magnify.extraIntegral
// at both ends). A Dock has a handful of runs: one position costs O(runs), not O(tiles).
function magnifiedShelf(size, isSeparator, o) {
    const widths = isSeparator.map(s => s ? o.separatorWidth : size);
    const total = Magnify.totalWidth(widths, o.spacing);
    const rest = total + 2 * o.padding;
    if (!(o.maxScale > 1) || widths.length === 0)
        return rest;
    return rest + magnifiedGrowth(size, isSeparator, o, widths, total);
}

// The runs of icon tiles: [{a, b}] slot extents along a line whose first tile starts at `left`.
function iconRuns(widths, isSeparator, spacing, left) {
    const runs = [];
    let x = left;
    let run = null;
    for (let i = 0; i < widths.length; i++) {
        const a = x - spacing / 2;
        const b = x + widths[i] + spacing / 2;
        if (isSeparator[i]) {
            run = null;
        } else if (run) {
            run.b = b;
        } else {
            run = {a: a, b: b};
            runs.push(run);
        }
        x += widths[i] + spacing;
    }
    return runs;
}

// The largest growth of the shelf over every pointer position (see magnifiedShelf).
function magnifiedGrowth(size, isSeparator, o, widths, total) {
    const pitch = size + o.spacing;
    const reach = o.radius * pitch;
    // A pointer left of the first tile counts as no pointer in Magnify (negative): the line is shifted so that p stays >= 0.
    const runs = iconRuns(widths, isSeparator, o.spacing, reach);
    if (runs.length === 0)
        return 0;
    const k = size / pitch;
    const growth = p => {
        let g = 0;
        for (let r = 0; r < runs.length; r++) {
            if (runs[r].b <= p - reach || runs[r].a >= p + reach)
                continue;
            g += Magnify.extraIntegral(runs[r].b - p, pitch, o.maxScale, o.radius) - Magnify.extraIntegral(runs[r].a - p, pitch, o.maxScale, o.radius);
        }
        return k * g;
    };
    // Analytic shortcut: the integral of (scale - 1) over the whole line is (maxScale - 1) * reach, so no position grows the shelf by
    // more than k times that; a run at least two reaches long reaches it with the pointer at its middle (the curve is symmetric).
    const bound = k * (o.maxScale - 1) * reach;
    for (let r = 0; r < runs.length; r++) {
        if (runs[r].b - runs[r].a >= 2 * reach)
            return growth((runs[r].a + runs[r].b) / 2);
    }
    // The worst case is the maximum of that smooth curve: a sample every quarter tile finds the hill, a search inside the two
    // steps around the best sample finds its top (no safety margin needed beyond rounding).
    const step = Math.max(0.5, size / 4);
    let best = 0;
    let bestAt = 0;
    for (let p = 0; p <= total + 2 * reach; p += step) {
        const g = growth(p);
        if (g > best) {
            best = g;
            bestAt = p;
        }
    }
    let lo = Math.max(0, bestAt - step);
    let hi = bestAt + step;
    for (let i = 0; i < 24; i++) {
        const m1 = lo + (hi - lo) / 3;
        const m2 = hi - (hi - lo) / 3;
        if (growth(m1) < growth(m2))
            lo = m1;
        else
            hi = m2;
    }
    return Math.min(bound, Math.max(best, growth((lo + hi) / 2)));
}

// The results of fitSizeMagnified, by their inputs (audit A-05: every Dock window, one per output, asks for the same tiles at
// every rebuild and at every pointer move of a separator resize). Shared by every importer (.pragma library), bounded.
var fitCache = new Map();
var fitCacheMax = 64;

// Shrink to fit with magnification (macOS: the Dock never leaves the screen, magnified or not): the largest whole tile size
// not above `requested` whose shelf, at its widest while magnified (magnifiedShelf), fits in `available` px, never below
// `floor` (a requested size under the floor is kept). With no magnification this is fitSize.
function fitSizeMagnified(requested, isSeparator, available, floor, o) {
    if (!(available > 0) || isSeparator.length === 0)
        return requested;
    const key = [requested, available, floor, o.separatorWidth, o.spacing, o.padding, o.maxScale, o.radius, o.slack, isSeparator.map(s => s ? 1 : 0).join("")].join("|");
    const known = fitCache.get(key);
    if (known !== undefined)
        return known;
    const size = fitSizeMagnifiedNow(requested, isSeparator, available, floor, o);
    if (fitCache.size >= fitCacheMax)
        fitCache.clear();
    fitCache.set(key, size);
    return size;
}

function fitSizeMagnifiedNow(requested, isSeparator, available, floor, o) {
    // `o.slack` px stay free beyond the computed worst case (the rounding of the search for the top of the curve), and only while
    // magnification is on: a Dock that does not grow has an exact width, and a shelf that fits exactly is kept as it is.
    const slack = o.maxScale > 1 && o.slack > 0 ? o.slack : 0;
    const fits = size => magnifiedShelf(size, isSeparator, o) + slack <= available;
    if (fits(requested))
        return requested;
    const low = Math.min(requested, floor);
    if (!fits(low))
        return low;
    let lo = low;
    let hi = requested;
    while (hi - lo > 1) {
        const mid = Math.floor((lo + hi) / 2);
        if (fits(mid))
            lo = mid;
        else
            hi = mid;
    }
    return lo;
}

// ---- Position on screen (Settings > Position on screen: Left / Bottom / Right) ----
//
// The Dock lives in a transparent layer window anchored to its screen edge. Everything is written along two axes:
//   main  = along the Dock (x for a Dock at the bottom, y for one on the left or right edge), first tile at 0
//   cross = away from the screen edge (0 at the edge, the shelf is `margin` px off it, icons grow to larger values)
// and `rect()` turns main/cross boxes into window coordinates, so the shelf, the hit area, a tile target and a tooltip
// are one formula for the three edges. Magnify.js (scales, slots) and AutoHide.js (state machine) work on a coordinate
// along the main axis and a visible fraction: they are the same for every edge, only the pointer coordinate they get is
// `mainOf(edge, x, y)`.

var EDGES = ["left", "bottom", "right"];

// A stored value read as an edge: anything that is not left/right is the default, bottom.
function normalizeEdge(value) {
    return value === "left" || value === "right" ? value : "bottom";
}

function isVertical(edge) {
    return edge === "left" || edge === "right";
}

// Unit vector away from the screen edge: where icons grow, bounce and where labels and menus go.
function outward(edge) {
    if (edge === "left")
        return {x: 1, y: 0};
    if (edge === "right")
        return {x: -1, y: 0};
    return {x: 0, y: -1};
}

// Extent of a window (w x h) along the main axis and across it.
function mainSize(edge, w, h) {
    return isVertical(edge) ? h : w;
}

function crossSize(edge, w, h) {
    return isVertical(edge) ? w : h;
}

// Coordinate along the main axis of a point (x, y) of the window.
function mainOf(edge, x, y) {
    return isVertical(edge) ? y : x;
}

// Distance from the screen edge of a point (x, y) of a w x h window.
function crossOf(edge, x, y, w, h) {
    if (edge === "left")
        return x;
    if (edge === "right")
        return w - x;
    return h - y;
}

// Box [main0, main0 + mainLen] x [cross0, cross0 + crossLen] (cross0: distance of its side nearest to the screen edge,
// may be negative: a shelf slid out of sight) as a rectangle {x, y, w, h} of a w x h window anchored on `edge`.
function rect(edge, w, h, main0, mainLen, cross0, crossLen) {
    if (edge === "left")
        return {x: cross0, y: main0, w: crossLen, h: mainLen};
    if (edge === "right")
        return {x: w - cross0 - crossLen, y: main0, w: crossLen, h: mainLen};
    return {x: main0, y: h - cross0 - crossLen, w: mainLen, h: crossLen};
}

// Top-left corner of the window in screen coordinates. A vertical window is anchored top and bottom and the compositor
// may leave a bar above it, so it is placed from the bottom of the screen (nothing reserves room there).
function windowOrigin(edge, screenW, screenH, w, h) {
    return {x: edge === "right" ? screenW - w : 0, y: screenH - h};
}

// Room the window keeps beside the shelf for a label or a dragged icon (px): the label above a Dock at the bottom needs
// its own height, the label beside a Dock on a side edge its width.
function room(edge, tooltipArea, tooltipSideArea, dragArea) {
    return Math.max(isVertical(edge) ? tooltipSideArea : tooltipArea, dragArea);
}

// Window extent across the Dock: shelf, margin, the growth of magnified icons and the room beside it.
function depth(thickness, margin, overhang, roomPx) {
    return thickness + margin + overhang + roomPx;
}

// Shelf box in the window: centred along the main axis, `margin` off the edge, slid toward the edge by `slide` px
// (autohide).
function shelfRect(edge, w, h, length, thickness, margin, slide) {
    return rect(edge, w, h, (mainSize(edge, w, h) - length) / 2, length, margin - slide, thickness);
}

// The input area of the window (mask): the whole strip of `zone` px along the edge while the Dock is away, otherwise the
// shelf's length and, across, the shelf (plus the room for magnified icons and labels while the pointer is on it, or
// the whole window while a tile is dragged). `s` = {revealed, dragging, pointerActive, shelfMain0, shelfLength, thickness,
// margin, overhang, room, zone}.
function hitRect(edge, w, h, s) {
    if (!s.revealed)
        return rect(edge, w, h, 0, mainSize(edge, w, h), 0, s.zone);
    const cross = s.dragging ? crossSize(edge, w, h) : s.pointerActive ? s.thickness + s.margin + s.overhang + s.room : s.thickness + s.margin;
    return rect(edge, w, h, s.shelfMain0, s.shelfLength, 0, cross);
}

// Where the icon of a tile sits in the tile's own box. The tile is iconSize + indicatorArea across (the running dot on
// the screen-edge side, then the icon) and iconPx along; a magnified icon (iconPx > iconSize) grows away from the edge.
function iconOrigin(edge, iconSize, iconPx, indicatorArea) {
    if (edge === "left")
        return {x: indicatorArea, y: 0};
    if (edge === "right")
        return {x: iconSize - iconPx, y: 0};
    return {x: 0, y: iconSize - iconPx};
}

// The box of the tile that takes the pointer (press, hover, drag, drop, menu), in the tile's own coordinates: the tile's box
// (`tileW` x `tileH`) joined with the drawn icon (`iconPx` square at iconOrigin). A magnified icon grows beyond the tile
// across the Dock (away from the screen edge; the tile does not grow, so the Grid that lays tiles out stays put), and the
// whole of it is clickable (macOS). Along the Dock it is the tile's own extent. {x, y, w, h}.
function hitBox(edge, iconSize, iconPx, indicatorArea, tileW, tileH) {
    const o = iconOrigin(edge, iconSize, iconPx, indicatorArea);
    const x0 = Math.min(0, o.x);
    const y0 = Math.min(0, o.y);
    return {x: x0, y: y0, w: Math.max(tileW, o.x + iconPx) - x0, h: Math.max(tileH, o.y + iconPx) - y0};
}

// The tile that owns the point (x, y): of the hit boxes holding it, the one drawn on top (highest `z`, equal z: the later
// tile, as Qt stacks siblings). `boxes`: one {x, y, w, h, z} per tile in a common space, null for a tile that cannot be
// pressed. -1 when no box holds the point. Boxes are half-open (x <= px < x + w), so two that touch share no point.
// Magnification by transforms (audit, Dock fluidity): a tile keeps its unmagnified box (iconSize along the Dock) and its icon is
// drawn scaled about the middle of its screen-side edge, so the grown icon (iconPx) is centred on the tile along the Dock and grows
// away from the screen edge. The grown icon's top-left in the tile, the point the scale is taken about (in the unscaled icon, which
// sits at iconOrigin(edge, iconSize, iconSize, indicatorArea)), and the box that takes the pointer: the tile and the grown icon.
function grownIconOrigin(edge, iconSize, iconPx, indicatorArea) {
    const o = iconOrigin(edge, iconSize, iconPx, indicatorArea);
    const along = (iconSize - iconPx) / 2;
    return isVertical(edge) ? {x: o.x, y: along} : {x: along, y: o.y};
}
function scaleOrigin(edge, iconSize) {
    if (edge === "left")
        return {x: 0, y: iconSize / 2};
    if (edge === "right")
        return {x: iconSize, y: iconSize / 2};
    return {x: iconSize / 2, y: iconSize};
}
function grownHitBox(edge, iconSize, iconPx, indicatorArea, tileW, tileH) {
    const o = grownIconOrigin(edge, iconSize, iconPx, indicatorArea);
    const x0 = Math.min(0, o.x);
    const y0 = Math.min(0, o.y);
    return {x: x0, y: y0, w: Math.max(tileW, o.x + iconPx) - x0, h: Math.max(tileH, o.y + iconPx) - y0};
}

// A length rounded up to whole steps of `step` px (the blur region follows a moving shelf by steps, exact at rest).
function quantiseUp(length, step) {
    if (!(step > 0))
        return length;
    return Math.ceil(length / step - 1e-9) * step;
}

// The step of that blur region: an eighth of a tile pitch, never under one px.
function regionStep(pitch) {
    return Math.max(1, Math.round(pitch / 8));
}

// The widest the shelf gets under the pointer (magnifiedShelf), by its inputs: the input region takes it at once when the pointer
// arrives, instead of following the shelf frame by frame (audit, Dock fluidity).
var widestCache = new Map();
function widestShelf(size, isSeparator, o) {
    const key = [size, o.separatorWidth, o.spacing, o.padding, o.maxScale, o.radius, isSeparator.map(s => s ? 1 : 0).join("")].join("|");
    const known = widestCache.get(key);
    if (known !== undefined)
        return known;
    const w = magnifiedShelf(size, isSeparator, o);
    if (widestCache.size >= fitCacheMax)
        widestCache.clear();
    widestCache.set(key, w);
    return w;
}

function hitOwner(boxes, x, y) {
    let best = -1;
    for (let i = 0; i < boxes.length; i++) {
        const b = boxes[i];
        if (!b || x < b.x || x >= b.x + b.w || y < b.y || y >= b.y + b.h)
            continue;
        if (best < 0 || (b.z || 0) >= (boxes[best].z || 0))
            best = i;
    }
    return best;
}

// The running dot in the tile's box, in the shelf padding on the screen-edge side of the icon, `spacing` (dock.indicatorGap)
// from it. `lift` is how far the tile has moved away from the edge (hover rise): the dot stays on the shelf.
function dotOrigin(edge, tileW, tileH, iconSize, spacing, dotSize, lift) {
    if (edge === "left")
        return {x: -spacing - dotSize - lift, y: (tileH - dotSize) / 2};
    if (edge === "right")
        return {x: iconSize + spacing + lift, y: (tileH - dotSize) / 2};
    return {x: (tileW - dotSize) / 2, y: iconSize + spacing + lift};
}

// The label of a tile, in the tile's box: above the icon (bottom), beside it on the side away from the screen edge.
// `ttW` x `ttH` is the label (its tail included), `gap` the room between its tip and the shelf edge (macOS: the tip is about 8
// beyond the shelf, not beside the icon). `padding` (the shelf padding, 0 when omitted) puts the shelf edge beyond the icon; a
// magnified icon that reaches past the shelf pushes the label out with it.
function tooltipOrigin(edge, tileW, tileH, iconSize, iconPx, indicatorArea, gap, ttW, ttH, padding) {
    const reach = Math.max(iconPx, iconSize + (padding || 0));
    if (edge === "left")
        return {x: indicatorArea + reach + gap, y: (tileH - ttH) / 2};
    if (edge === "right")
        return {x: iconSize - reach - gap - ttW, y: (tileH - ttH) / 2};
    return {x: (tileW - ttW) / 2, y: tileH - indicatorArea - reach - gap - ttH};
}

// Which side of the label the tail is on: the one toward the tile.
function tooltipTailSide(edge) {
    return edge === "left" ? "left" : edge === "right" ? "right" : "bottom";
}

// Rectangle (window coordinates) of the unmagnified icon of the tile centred at `mainCenter` on the main axis: the target
// of the minimize animation. `margin`/`padding` as in the metrics, `indicatorArea` = indicator + spacing.
function tileRect(edge, w, h, mainCenter, iconSize, margin, padding, indicatorArea) {
    return rect(edge, w, h, mainCenter - iconSize / 2, iconSize, margin + padding + indicatorArea, iconSize);
}

// The rectangle, in the output's own coordinates, of the unmagnified icon of minimized slot `index` (0 = the first minimized
// tile, after the divider and the folder stacks): where a window minimized into the Dock lands (`adding`: the tile does not
// exist yet and is inserted before the Trash) or leaves from. Pure: it depends on the tiles, not on any window. `items` are
// the Dock items ({kind, divider}), `o` = {index, adding, iconSize, spacing, separatorWidth, edge, screenW, screenH, depth,
// margin, padding, indicatorArea}. null when there is no divider, the slot does not exist or the numbers are not usable.
function minimizedSlotRect(items, o) {
    const list = Array.from(items || []);
    const sep = list.findIndex(it => it.kind === "separator" && !it.divider);
    if (sep < 0 || !(o.index >= 0) || !(o.iconSize > 0) || !(o.screenW > 0) || !(o.screenH > 0))
        return null;
    const widths = list.map(it => it.kind === "separator" ? o.separatorWidth : o.iconSize);
    const first = sep + 1 + list.filter(it => it.kind === "folder").length;
    if (o.adding)
        widths.splice(first + o.index, 0, o.iconSize);
    const room = mainSize(o.edge, o.screenW, o.screenH);
    const slot = Magnify.centersFor(widths, o.spacing, (room - Magnify.totalWidth(widths, o.spacing)) / 2)[first + o.index];
    if (slot === undefined || !isFinite(slot))
        return null;
    const vertical = isVertical(o.edge);
    const winW = vertical ? o.depth : o.screenW;
    const winH = vertical ? o.screenH : o.depth;
    const r = tileRect(o.edge, winW, winH, slot, o.iconSize, o.margin, o.padding, o.indicatorArea);
    const origin = windowOrigin(o.edge, o.screenW, o.screenH, winW, winH);
    return clampInto({x: origin.x + r.x, y: origin.y + r.y, w: r.w, h: r.h}, {x: 0, y: 0, w: o.screenW, h: o.screenH});
}

// `rect` {x, y, w, h} moved (never resized) to lie inside `box` {x, y, w, h}; a rect larger than the box is left at the box's
// origin. The compositor plugin refuses a minimize target that is not wholly inside one output (no animation then), so the
// Dock never hands it a rectangle that sticks out, whatever size its window had when the question came.
function clampInto(rect, box) {
    const x = Math.max(box.x, Math.min(rect.x, box.x + box.w - rect.w));
    const y = Math.max(box.y, Math.min(rect.y, box.y + box.h - rect.h));
    return {x: x, y: y, w: rect.w, h: rect.h};
}

// Where the Dock menu of a tile opens (screen coordinates; `center` is the tile centre along the main axis in screen
// coordinates): above a Dock at the bottom (centred on the tile, its bottom edge at y), beside a Dock on a side edge
// (centred on the tile, its near edge at x), `gap` + `tailHeight` away from the shelf for the menu's tail.
// The alignment names are Popups.align values.
function menuAnchor(edge, screenW, screenH, center, thickness, margin, gap, tailHeight) {
    const off = margin + thickness + gap + tailHeight;
    if (edge === "left")
        return {x: off, y: center, align: "rightOf"};
    if (edge === "right")
        return {x: screenW - off, y: center, align: "leftOf"};
    return {x: center, y: screenH - off, align: "above"};
}

// Components of a drag offset (screen dx, dy): along the Dock, and away from the screen edge (positive = out).
function dragMain(edge, dx, dy) {
    return isVertical(edge) ? dy : dx;
}

function dragOutward(edge, dx, dy) {
    const o = outward(edge);
    return o.x * dx + o.y * dy;
}

// The drag offset (screen dx, dy) with `main` along the Dock and `cross` away from the screen edge.
function dragVector(edge, main, cross) {
    const o = outward(edge);
    return isVertical(edge) ? {x: o.x * cross, y: main} : {x: main, y: o.y * cross};
}

// Insets {left, right, bottom} the Dock takes from a screen (its exclusive zone, 0 while auto-hidden): what the desktop
// icon grid, the widgets, Overview and the Apps panel keep clear.
function footprint(edge, m, autohide) {
    const zone = DockModel.reservedHeight(m, autohide);
    return {left: edge === "left" ? zone : 0, right: edge === "right" ? zone : 0, bottom: edge === "bottom" ? zone : 0};
}

// ---- Resize by dragging the separator (macOS) ----

// The tile size while the separator is dragged by (tx, ty) from where it was pressed (a Dock of `start` px tiles). Dragging
// away from the screen edge makes the Dock larger and toward it smaller; movement along the Dock does nothing. The
// separator sits in the middle of the shelf, which grows by the change of the tile on its outward side only, so the size
// changes by twice the pointer's distance to keep the separator under the pointer. Clamped to [min, max], whole px.
function resizeSize(start, edge, tx, ty, min, max) {
    return clampSize(start + 2 * dragOutward(edge, tx, ty), min, max, start);
}

// ---- One Dock across displays (macOS: the Dock is on the display where the pointer last reached its edge) ----

// The output the Dock starts on: the focused one. `preferred` is the dev override (the primary output named by
// GRASSFIELD_DESKTOP_SCREEN, which only a development session sets: a nested session has two outputs and which one is focused
// when the shell starts is a race); "" without a start output (nothing is focused yet).
function startScreen(names, focused, preferred) {
    if (preferred && names.indexOf(preferred) >= 0)
        return preferred;
    return names.indexOf(focused) >= 0 ? focused : "";
}

// The output that has the Dock: the chosen one while it still exists, else the start output, else the first.
function dockScreen(chosen, names, focused, preferred) {
    if (names.indexOf(chosen) >= 0)
        return chosen;
    const start = startScreen(names, focused, preferred);
    if (start !== "")
        return start;
    return names.length > 0 ? names[0] : "";
}

// The chosen output once the Dock has no choice yet: it starts on the start output (and stays there when focus moves on).
function latchScreen(chosen, names, focused, preferred) {
    return chosen === "" ? startScreen(names, focused, preferred) : chosen;
}

// latchScreen once the start output is final: `ready` is false until the settings are read and the main display is known
// (Settings.loaded and MainDisplay.ready), and nothing is latched before that, so the Dock never takes the fallback output
// that a stored main display would overrule a moment later (ADR-0044; the Dock was created before the settings loaded).
function latchScreenWhen(ready, chosen, names, focused, preferred) {
    return ready === true ? latchScreen(chosen, names, focused, preferred) : chosen;
}

// The main display changed to `main` (ADR-0044). Once the Dock is settled it moves there ({move: main}). Before that, whatever it
// had latched (a focus change latched a fallback output before Hyprland described the outputs) is dropped, so that the first
// layout latches on the new main display: {chosen: ""}. No main display (""): nothing changes.
function afterMainChange(settled, chosen, main) {
    if (!main)
        return {chosen: chosen, move: ""};
    return settled === true ? {chosen: chosen, move: main} : {chosen: "", move: ""};
}

// The output the Dock latches on at the first settled layout: the start output, else (no focused output was ever reported: a
// compositor without focus events, the fallback timer ran out) the output it is on, so that a focus event arriving later does
// not move a Dock that is already drawn.
function settleScreen(chosen, names, focused, preferred) {
    const latched = latchScreen(chosen, names, focused, preferred);
    return latched !== "" ? latched : dockScreen("", names, focused, preferred);
}

// Whether the output of a Dock window takes the Dock from the one that has it: an output without the Dock acts as an
// auto-hidden Dock that stays away, and its machine starting to reveal (AutoHide.js: the pointer rested on the edge
// strip for the reveal dwell) is the pointer having reached the Dock's edge there.
function movesDock(isDockScreen, previousState, nextState) {
    return !isDockScreen && previousState !== "revealing" && nextState === "revealing";
}

// ---- Startup: the Dock appears once, in its final place (the owner's report of 2026-10-29) ----

// Whether every input of the Dock's first layout is final: the settings file was read (edge, size, magnification, pinned
// apps), the apps model is ready (the icons of the pinned apps), and the output that has the Dock is known (with several
// outputs, the focused one; `start` is startScreen()). Until then the window stays unmapped, so nothing is drawn at a default
// edge or size and then moved. The settings file is always waited for (its read ends in `loaded` whatever the file is, and is
// bounded); `waited` (the fallback timer ran out) stands in for the other two, which a compositor without focus events or an
// empty apps model may never give. `inputs` is {settings, apps, screens, start, waited}.
function settledOn(inputs) {
    if (!inputs || inputs.settings !== true)
        return false;
    const n = inputs.screens ? inputs.screens.length : 0;
    if (n === 0)
        return false;
    if (inputs.waited === true)
        return true;
    return inputs.apps === true && (n === 1 || String(inputs.start || "") !== "");
}

// Whether a Dock surface has the shape of its edge: across the Dock `depth`, and along it longer than across (a side surface
// is as tall as the output less the menu bar's reserved strip, a bottom one as wide as the output: only the orientation is
// checked along). Until then an anchor change (the settled edge) has not been answered by the compositor and the Dock would
// be drawn in a surface of the old edge.
function placed(edge, width, height, depth) {
    if (!(depth > 0) || !(width > 0) || !(height > 0))
        return false;
    const near = (a, b) => Math.abs(a - b) < 1;
    return isVertical(edge) ? (near(width, depth) && height > width) : (near(height, depth) && width > height);
}
