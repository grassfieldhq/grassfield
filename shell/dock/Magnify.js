.pragma library

// Dock magnification math (pure, unit-tested).

// Falloff of the magnification: 1 at the pointer, 0 at and beyond the reach, with a quintic smootherstep
// (zero slope and curvature at both ends, so the effect fades in and out without a visible edge).
function falloff(t) {
    const x = Math.min(1, Math.max(0, t));
    return 1 - x * x * x * (x * (x * 6 - 15) + 10);
}

// Integral of falloff(t) from 0 to t (closed form; 0.5 from t = 1 on).
function falloffIntegral(t) {
    const x = Math.min(1, Math.max(0, t));
    return x - (x * x * x * x * (2.5 - x * (3 - x)));
}

// Scale of an icon whose centre is `distance` px from the pointer: `max` at 0, 1 at and beyond
// radiusIcons * pitch. A max of 1 or less disables magnification.
function scale(distance, pitch, max, radiusIcons) {
    if (max <= 1 || pitch <= 0 || radiusIcons <= 0)
        return 1;
    const reach = radiusIcons * pitch;
    const d = Math.abs(distance);
    if (d >= reach)
        return 1;
    return 1 + (max - 1) * falloff(d / reach);
}

// Integral of (scale(x) - 1) for x from 0 to `distance` (signed: odd in the distance).
function extraIntegral(distance, pitch, max, radiusIcons) {
    if (max <= 1 || pitch <= 0 || radiusIcons <= 0)
        return 0;
    const reach = radiusIcons * pitch;
    const v = (max - 1) * reach * falloffIntegral(Math.abs(distance) / reach);
    return distance < 0 ? -v : v;
}

// Mean scale over the stretch from `from` to `to` (px, relative to the pointer): the curve integrated over it.
function meanScale(from, to, pitch, max, radiusIcons) {
    if (to <= from)
        return scale(from, pitch, max, radiusIcons);
    return 1 + (extraIntegral(to, pitch, max, radiusIcons) - extraIntegral(from, pitch, max, radiusIcons)) / (to - from);
}

// Scales for icons at the given centres (pointwise on the curve); pointerX < 0 (no pointer) gives all 1.
function scales(centers, pointerX, pitch, max, radiusIcons) {
    const out = [];
    for (let i = 0; i < centers.length; i++)
        out.push(pointerX < 0 ? 1 : scale(centers[i] - pointerX, pitch, max, radiusIcons));
    return out;
}

// Target scales of tiles laid out unmagnified at `centers` with `widths` and `spacing`: each tile takes the curve integrated
// over its own slot (the tile plus half the spacing each side). The slots tile the line, so the displacement of every
// neighbour is the integral of the scale curve: tiles never overlap and nothing jumps at a slot boundary. A tile whose
// `fixed[i]` is true (separator) stays at 1.
function slotScales(centers, widths, spacing, fixed, pointerX, pitch, max, radiusIcons) {
    const out = [];
    for (let i = 0; i < centers.length; i++) {
        if (pointerX < 0 || (fixed && fixed[i])) {
            out.push(1);
            continue;
        }
        const half = (widths[i] + spacing) / 2;
        out.push(meanScale(centers[i] - half - pointerX, centers[i] + half - pointerX, pitch, max, radiusIcons));
    }
    return out;
}

// One smoothing step of the displayed scales toward the targets: exponential with time constant `tau` ms, so the feel does
// not depend on the frame rate. `dt` (ms) is capped at `maxDt`: a stalled frame never makes a jump. tau <= 0 snaps.
function step(current, target, dt, tau, maxDt) {
    const k = tau <= 0 ? 1 : 1 - Math.exp(-Math.min(Math.max(dt, 0), maxDt) / tau);
    const out = [];
    for (let i = 0; i < target.length; i++) {
        const c = current && current[i] !== undefined ? current[i] : 1;
        out.push(c + (target[i] - c) * k);
    }
    return out;
}

// True while the displayed scales are within `epsilon` of the targets.
function settled(current, target, epsilon) {
    for (let i = 0; i < target.length; i++) {
        if (Math.abs((current && current[i] !== undefined ? current[i] : 1) - target[i]) > epsilon)
            return false;
    }
    return true;
}

// Left edges of tiles laid out from `left` with `spacing` between them: widths[i] * scales[i] each.
function lefts(widths, scalesList, spacing, left) {
    const out = [];
    let x = left;
    for (let i = 0; i < widths.length; i++) {
        out.push(x);
        x += widths[i] * (scalesList[i] !== undefined ? scalesList[i] : 1) + spacing;
    }
    return out;
}

// Centres of tiles with the given widths, laid out from `left` with `spacing` between them.
function centersFor(widths, spacing, left) {
    const out = [];
    let x = left;
    for (let i = 0; i < widths.length; i++) {
        out.push(x + widths[i] / 2);
        x += widths[i] + spacing;
    }
    return out;
}

// Total width of tiles with the given widths and spacing.
function totalWidth(widths, spacing) {
    let w = 0;
    for (let i = 0; i < widths.length; i++)
        w += widths[i];
    return w + Math.max(0, widths.length - 1) * spacing;
}

// Magnification by transforms (audit, Dock fluidity): the tiles keep their unmagnified layout and each one is moved along the Dock
// by the growth of the tiles before it plus half its own (shifts[i], px), its icon scaled about the middle of its edge. The first
// tile's left edge stays where the unmagnified one is: the shelf, which grows by the total growth (growth()), is drawn from there.
function shifts(widths, scalesList) {
    const out = [];
    let before = 0;
    for (let i = 0; i < widths.length; i++) {
        const grow = widths[i] * ((scalesList[i] !== undefined ? scalesList[i] : 1) - 1);
        out.push(before + grow / 2);
        before += grow;
    }
    return out;
}

// How much longer the tiles are magnified than at rest (px).
function growth(widths, scalesList) {
    let g = 0;
    for (let i = 0; i < widths.length; i++)
        g += widths[i] * ((scalesList[i] !== undefined ? scalesList[i] : 1) - 1);
    return g;
}
