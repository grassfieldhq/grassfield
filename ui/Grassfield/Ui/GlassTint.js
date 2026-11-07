.pragma library

// Adaptive glass (ADR-0024 section 2, points 1 to 4; G-1, G-2, G-3; owner decision 2026-10-26: the adaptive tint first).
// A surface class has a target tint (the clearer macOS 26 value at the default slider); the tint is raised to the
// smallest alpha that keeps its text at 4.5:1 over the backdrop: over the luminance range the shell measured when the
// output shows the bare desktop, else over any backdrop (black to white: the worst case of today's material). Pure
// functions, no I/O; tests/visual/test_contrast_tokens.py holds the same calculation for gate A2.

// Channels (0..1) of "#rrggbb"/"#aarrggbb" or of a QML color ({r, g, b}).
function channels(c) {
    if (typeof c === "string") {
        const h = c.slice(-6);
        return [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255];
    }
    return [c.r, c.g, c.b];
}

function linear(v) {
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
}

function luminance(rgb) {
    return 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2]);
}

// The sRGB grey (0..1) of a relative luminance.
function greyOf(lum) {
    const l = Math.max(0, Math.min(1, lum));
    return l <= 0.03928 / 12.92 ? l * 12.92 : 1.055 * Math.pow(l, 1 / 2.4) - 0.055;
}

function over(fg, alpha, bg) {
    return [fg[0] * alpha + bg[0] * (1 - alpha), fg[1] * alpha + bg[1] * (1 - alpha), fg[2] * alpha + bg[2] * (1 - alpha)];
}

function ratio(a, b) {
    const la = luminance(a);
    const lb = luminance(b);
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

// Backdrop colours of relative luminance `lum` that bound what the tint over them can become: the grey, and the vertices of
// the colours of that luminance in linear light (two channels at 0 or 1, the third solving the luminance), so a saturated
// backdrop (pure red is 0.21 like a mid grey, but blends much darker) is covered, not only its grey.
const WEIGHTS = [0.2126, 0.7152, 0.0722];

function backdropsOf(lum) {
    const l = Math.max(0, Math.min(1, lum));
    const g = greyOf(l);
    const out = [[g, g, g]];
    for (let c = 0; c < 3; c++) {
        const others = [0, 1, 2].filter(k => k !== c);
        for (let bits = 0; bits < 4; bits++) {
            const x = [0, 0, 0];
            x[others[0]] = bits & 1;
            x[others[1]] = (bits >> 1) & 1;
            const rest = l - WEIGHTS[others[0]] * x[others[0]] - WEIGHTS[others[1]] * x[others[1]];
            const free = rest / WEIGHTS[c];
            if (free < -1e-9 || free > 1 + 1e-9)
                continue;
            x[c] = Math.max(0, Math.min(1, free));
            out.push(x.map(greyOf));
        }
    }
    return out;
}

// The smallest tint alpha (steps of 0.01) that keeps every text colour at `need` over a backdrop of relative luminance
// lumMin and lumMax, with and without the fill overlay of a tile or field (fill at fillAlpha over the tint). Contrast moves
// monotonically with the backdrop's luminance between the two, so the two ends (each with its bounding colours) cover the
// range.
function floorAlpha(tint, texts, fill, fillAlpha, lumMin, lumMax, need) {
    const t = channels(tint);
    const f = channels(fill);
    const ink = texts.map(channels);
    const backs = backdropsOf(lumMin).concat(backdropsOf(lumMax));
    for (let i = 0; i <= 100; i++) {
        const a = i / 100;
        let ok = true;
        for (let b = 0; b < backs.length && ok; b++) {
            const base = over(t, a, backs[b]);
            const filled = over(f, fillAlpha, base);
            for (let k = 0; k < ink.length && ok; k++)
                ok = ratio(ink[k], base) >= need && ratio(ink[k], filled) >= need;
        }
        if (ok)
            return a;
    }
    return 1;
}

// The class tint at slider value t (0 = opaque, as Reduce Transparency; `defaultT` = the class target; 1 = clear): linear
// from 1 to the target up to the default, then from the target to 0 (G-2: the dead zone of the one-tint curve goes).
function targetAlpha(target, t, defaultT) {
    const x = Math.max(0, Math.min(1, t));
    if (x <= defaultT)
        return 1 - (1 - target) * x / defaultT;
    return target * (1 - (x - defaultT) / (1 - defaultT));
}

// The luminance range of the backdrop under one surface (G-3 per surface): the cells of the output's luminance grid that
// `rect` (output px: x, y, width, height) touches, grown by `pad` px for the blur's reach. `grid` = {width, height, cols, rows,
// min, max}: the output's size in px it was sampled for and, row-major, each cell's lowest and highest luminance of what the
// output shows, sampled small (the glass blurs its backdrop far more than a cell). null when the grid or the rect cannot
// answer (the caller keeps the whole output's range).
function gridRange(grid, rect, pad) {
    if (!grid || !(grid.cols > 0) || !(grid.rows > 0) || !(grid.width > 0) || !(grid.height > 0) || !grid.min || !grid.max)
        return null;
    if (!rect || !(rect.width > 0) || !(rect.height > 0) || grid.min.length !== grid.cols * grid.rows || grid.max.length !== grid.min.length)
        return null;
    const cw = grid.width / grid.cols;
    const ch = grid.height / grid.rows;
    const clampCell = (v, n) => Math.max(0, Math.min(n - 1, v));
    const c0 = clampCell(Math.floor((rect.x - pad) / cw), grid.cols);
    const c1 = clampCell(Math.floor((rect.x + rect.width + pad) / cw), grid.cols);
    const r0 = clampCell(Math.floor((rect.y - pad) / ch), grid.rows);
    const r1 = clampCell(Math.floor((rect.y + rect.height + pad) / ch), grid.rows);
    let lo = 1;
    let hi = 0;
    for (let r = r0; r <= r1; r++) {
        for (let c = c0; c <= c1; c++) {
            const i = r * grid.cols + c;
            lo = Math.min(lo, grid.min[i]);
            hi = Math.max(hi, grid.max[i]);
        }
    }
    return lo <= hi ? {lumMin: lo, lumMax: hi} : null;
}

// The luminance range of the wallpaper under a surface that always lies on the wallpaper, whatever windows its output shows
// below it (the menu bar's band while the bar keeps its strip: no window is ever under it): the output's wallpaper range
// (`range`, {lumMin, lumMax}) narrowed to the cells of the wallpaper's luminance grid under `rect` (gridRange). null when the
// wallpaper's range is unknown (a video, a picture without statistics): the caller takes the worst case then.
function wallpaperUnder(range, grid, rect, pad) {
    if (!range || typeof range.lumMin !== "number" || typeof range.lumMax !== "number")
        return null;
    return gridRange(grid, rect, pad) ?? {lumMin: range.lumMin, lumMax: range.lumMax};
}

// The luminance grid of RGBA pixels (`data`, `w` x `h`, 0..255, as Context2D getImageData gives) cut into `cols` x `rows`
// cells: each cell's lowest and highest pixel luminance. `outW` x `outH` is the output size the pixels stand for.
function gridOf(data, w, h, cols, rows, outW, outH) {
    const min = new Array(cols * rows).fill(1);
    const max = new Array(cols * rows).fill(0);
    for (let y = 0; y < h; y++) {
        const r = Math.min(rows - 1, Math.floor(y * rows / h));
        for (let x = 0; x < w; x++) {
            const c = Math.min(cols - 1, Math.floor(x * cols / w));
            const k = (y * w + x) * 4;
            const l = luminance([data[k] / 255, data[k + 1] / 255, data[k + 2] / 255]);
            const i = r * cols + c;
            if (l < min[i])
                min[i] = l;
            if (l > max[i])
                max[i] = l;
        }
    }
    return {width: outW, height: outH, cols: cols, rows: rows, min: min, max: max};
}

// Text straight on the wallpaper (no glass): the first of `inks` ("#rrggbb") that keeps `need` against every backdrop of the
// luminance range (its bounding colours, backdropsOf), or "" when none does or the range is unknown (the caller puts glass
// behind the text then).
function inkOn(range, inks, need) {
    if (!range || typeof range.lumMin !== "number" || typeof range.lumMax !== "number")
        return "";
    const backs = backdropsOf(range.lumMin).concat(backdropsOf(range.lumMax));
    for (let i = 0; i < inks.length; i++) {
        const ink = channels(inks[i]);
        if (backs.every(b => ratio(ink, b) >= need))
            return inks[i];
    }
    return "";
}

// The tint of a class: `backdrop` is {lumMin, lumMax} when the shell knows what lies behind the surface, null otherwise.
// `margin` is added to 4.5 over a measured backdrop (a picture's percentiles, the blur's own lift); none for the worst case,
// which is exact (black and white bound every backdrop).
function alpha(target, t, defaultT, backdrop, tint, texts, fill, fillAlpha, margin) {
    if (t <= 0)
        return 1;
    const known = backdrop !== null && backdrop !== undefined && typeof backdrop.lumMin === "number" && typeof backdrop.lumMax === "number";
    const floor = known ? floorAlpha(tint, texts, fill, fillAlpha, backdrop.lumMin, backdrop.lumMax, 4.5 + margin)
                        : floorAlpha(tint, texts, fill, fillAlpha, 0, 1, 4.5);
    return Math.max(floor, targetAlpha(target, t, defaultT));
}

// The tint of the menu bar's band over a strip whose luminance range is known (ADR-0024 point 3): the class tint raised to the
// smallest alpha that keeps the bar's text legible in every state the band can show, over each end of the range (and the colours
// that bound it, backdropsOf): at rest (4.5:1 plus `margin`), under the open title's capsule (`hover` at `capsuleAlpha`, the
// real fill of BarButton: 4.5:1 plus `margin`), and dimmed on a display that is not the active one (band and text both at
// `dim` opacity: `dimNeed`, the 3:1 of the glyph rule). Never below the class target; opaque at slider 0.
function bandAlpha(target, t, defaultT, range, tint, text, hover, capsuleAlpha, dim, need, dimNeed, margin) {
    if (t <= 0)
        return 1;
    const floor = targetAlpha(target, t, defaultT);
    const tc = channels(tint);
    const ink = channels(text);
    const cap = channels(hover);
    const backs = backdropsOf(range.lumMin).concat(backdropsOf(range.lumMax));
    for (let i = Math.max(0, Math.floor(floor * 100 - 1e-9)); i <= 100; i++) {
        const a = i / 100;
        if (a < floor - 1e-9)
            continue;
        let ok = true;
        for (let b = 0; b < backs.length && ok; b++) {
            const base = over(tc, a, backs[b]);
            ok = ratio(ink, base) >= need + margin && ratio(ink, over(cap, capsuleAlpha, base)) >= need + margin;
            const dimBase = over(tc, a * dim, backs[b]);
            ok = ok && ratio(over(ink, dim, dimBase), dimBase) >= dimNeed;
        }
        if (ok)
            return a;
    }
    return 1;
}
