.pragma library

// The capture toolbar's decisions (spec docs/specs/system-dialogs.md "Capture toolbar", ADR-0045 OC-1): its modes in macOS 27's
// order, the mode it opens in, the arrows, the helper's argv for a mode and the options, and the Options menu. Pure functions
// (tests/unit/tst_capturemodel.qml); Capture.qml and CaptureToolbar.qml hold the state and draw it.

// The modes, left to right: the three captures, then the two recordings. `glyph`: the button's symbol (branding/icons).
var MODES = [
    {id: "screen", record: false, glyph: "capture-screen"},
    {id: "window", record: false, glyph: "capture-window"},
    {id: "selection", record: false, glyph: "capture-selection"},
    {id: "recordScreen", record: true, glyph: "record-screen"},
    {id: "recordSelection", record: true, glyph: "record-selection"}
];
// Save to (capture.location; owner 2026-11-07: the Desktop is no default any more): `screenshots` is the Screenshots folder in the
// Pictures folder for a screenshot and the Videos folder for a recording (the default), then the Desktop, the Documents folder, the
// clipboard (screenshots) and Preview (the file kept where `screenshots` puts it, opened in Preview). macOS 27 lists Desktop first
// because it is its default; the default comes first here likewise.
var LOCATIONS = ["screenshots", "desktop", "documents", "clipboard", "preview"];
// A recording is not copied: its Save to lists these, and a stored "clipboard" means the default folder (Videos) for it.
var RECORD_LOCATIONS = ["screenshots", "desktop", "documents", "preview"];
var DEFAULT_LOCATION = "screenshots";
var TIMERS = ["none", "5", "10"];
var OUTPUT_NAME = /^[A-Za-z0-9._-]{1,64}$/;

function known(mode) {
    return MODES.some(m => m.id === mode);
}

function isRecord(mode) {
    return mode === "recordScreen" || mode === "recordSelection";
}

// A mode the toolbar offers now: the recordings only while one can start (the recorder is installed, none is running).
function available(mode, canRecord) {
    return known(mode) && (canRecord || !isRecord(mode));
}

// The modes shown, in order (the recordings' group is not shown without the recorder: OC-0 graceful degradation).
function shown(recorder) {
    return MODES.filter(m => recorder || !m.record);
}

// The mode the toolbar opens in: the one chosen last, else Capture Selected Portion (macOS's first use); a recording that
// cannot start now gives way to Capture Selected Portion.
function startMode(stored, canRecord) {
    return available(stored, canRecord) ? stored : "selection";
}

// Left (-1) and Right (+1): the previous or next mode the toolbar offers, stopping at the ends (macOS's segmented toolbar).
function step(mode, delta, canRecord) {
    const ids = MODES.filter(m => available(m.id, canRecord)).map(m => m.id);
    const at = ids.indexOf(mode);
    if (at < 0)
        return ids.length > 0 ? ids[0] : mode;
    return ids[Math.max(0, Math.min(ids.length - 1, at + (delta < 0 ? -1 : 1)))];
}

// The destination a mode uses for the stored Save to (Settings.captureLocation).
function location(mode, stored) {
    const value = LOCATIONS.indexOf(stored) >= 0 ? stored : DEFAULT_LOCATION;
    return isRecord(mode) && value === "clipboard" ? DEFAULT_LOCATION : value;
}

function timerSeconds(timer) {
    return timer === "5" ? 5 : timer === "10" ? 10 : 0;
}

// "X,Y WxH" in the compositor's logical coordinates, as grim -g and the helper's --geometry take it.
var GEOMETRY = /^-?[0-9]{1,6},-?[0-9]{1,6} [0-9]{1,6}x[0-9]{1,6}$/;

// The helper's arguments (packaging/bin/grassfield-capture) for a mode, the options ({location, timer, microphone,
// showPointer}, as the settings store them), a display (`output`: the one clicked in an Entire Screen mode, the toolbar's for
// Record Entire Screen; "" for every display) and the area chosen on the toolbar's surface (`geometry`, GEOMETRY: the frame of a
// Selected Portion mode, the window clicked; "" lets the helper's crosshair choose).
function helperArgs(mode, options, output, geometry) {
    const o = options || {};
    const args = isRecord(mode) ? ["record", mode === "recordScreen" ? "screen" : "selection"]
                                : [known(mode) ? mode : "selection"];
    args.push("--save", location(mode, o.location));
    const seconds = timerSeconds(o.timer);
    if (seconds > 0)
        args.push("--timer", String(seconds));
    if (o.showPointer === true)
        args.push("--pointer");
    if (isRecord(mode) && o.microphone === "default")
        args.push("--mic");
    if ((mode === "recordScreen" || mode === "screen") && typeof output === "string" && OUTPUT_NAME.test(output))
        args.push("--output", output);
    if ((mode === "selection" || mode === "window" || mode === "recordSelection") && typeof geometry === "string"
            && GEOMETRY.test(geometry))
        args.push("--geometry", geometry);
    return args;
}

// ---- the selection frame of the Selected Portion modes (macOS 27: a frame over the dimmed display, eight handles) ----
// A frame is {x, y, w, h} in the display's own logical coordinates, whole numbers; `bounds` is the display's {w, h}.

var HANDLES = ["topLeft", "top", "topRight", "right", "bottomRight", "bottom", "bottomLeft", "left"];
// A first frame (no remembered one for that display): centred, this fraction of the display each way.
var DEFAULT_FRACTION = 0.5;

// The display's logical size for the frame: the screen's own (the toolbar's window covers it exactly), else the window's. The
// window is no source while it maps: it starts at 0x0 and passes through sizes of its own, and a frame clamped to those stays
// small. {w: 0, h: 0} when neither is known.
function displayBounds(winW, winH, screenW, screenH) {
    if (screenW > 0 && screenH > 0)
        return {w: screenW, h: screenH};
    return winW > 0 && winH > 0 ? {w: winW, h: winH} : {w: 0, h: 0};
}

function validRect(r) {
    return r !== null && typeof r === "object" && [r.x, r.y, r.w, r.h].every(v => typeof v === "number" && isFinite(v));
}

function defaultFrame(bounds) {
    const w = Math.max(1, Math.round(bounds.w * DEFAULT_FRACTION));
    const h = Math.max(1, Math.round(bounds.h * DEFAULT_FRACTION));
    return {x: Math.round((bounds.w - w) / 2), y: Math.round((bounds.h - h) / 2), w: w, h: h};
}

// A frame kept on the display: whole numbers, at least `minSize` each way (the display's size at most), moved back inside.
function clampFrame(r, bounds, minSize) {
    // A display of no known size cannot hold a frame: it is left as it is.
    if (!(bounds.w > 0) || !(bounds.h > 0))
        return validRect(r) ? r : {x: 0, y: 0, w: 0, h: 0};
    if (!validRect(r))
        return defaultFrame(bounds);
    const least = Math.min(minSize, bounds.w, bounds.h);
    const w = Math.min(bounds.w, Math.max(least, Math.round(r.w)));
    const h = Math.min(bounds.h, Math.max(least, Math.round(r.h)));
    return {x: Math.min(bounds.w - w, Math.max(0, Math.round(r.x))), y: Math.min(bounds.h - h, Math.max(0, Math.round(r.y))), w: w, h: h};
}

// The centres of the eight handles: the corners and the middles of the edges.
function handleCentres(r) {
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const right = r.x + r.w;
    const bottom = r.y + r.h;
    return [
        {id: "topLeft", x: r.x, y: r.y}, {id: "top", x: cx, y: r.y}, {id: "topRight", x: right, y: r.y},
        {id: "right", x: right, y: cy}, {id: "bottomRight", x: right, y: bottom}, {id: "bottom", x: cx, y: bottom},
        {id: "bottomLeft", x: r.x, y: bottom}, {id: "left", x: r.x, y: cy}
    ];
}

// What a press at the point takes: a handle (within half of `hit` of its centre, the corners first), "inside" (a move) or
// "outside" (a new frame is drawn).
function hitTest(r, px, py, hit) {
    const half = hit / 2;
    const centres = handleCentres(r);
    for (const id of ["topLeft", "topRight", "bottomRight", "bottomLeft", "top", "right", "bottom", "left"]) {
        const c = centres.find(h => h.id === id);
        if (Math.abs(px - c.x) <= half && Math.abs(py - c.y) <= half)
            return id;
    }
    return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h ? "inside" : "outside";
}

// The pointer shape over a part of the frame (Qt's cursor names, mapped to Qt.CursorShape by the QML).
function cursorFor(part) {
    switch (part) {
    case "topLeft":
    case "bottomRight":
        return "sizeFDiag";
    case "topRight":
    case "bottomLeft":
        return "sizeBDiag";
    case "left":
    case "right":
        return "sizeHor";
    case "top":
    case "bottom":
        return "sizeVer";
    case "inside":
        return "sizeAll";
    }
    return "cross";
}

function clampTo(v, low, high) {
    return Math.min(high, Math.max(low, v));
}

// Two edges at least `least` apart, inside [0, size]: the edge that moved gives way.
function spread(a, b, least, size, aMoved) {
    if (b - a >= least)
        return [a, b];
    if (aMoved)
        return b - least >= 0 ? [b - least, b] : [0, least];
    return a + least <= size ? [a, a + least] : [size - least, size];
}

// A handle dragged by (dx, dy) from the frame at the press: the edges it holds follow the pointer; dragged past the opposite edge
// the frame turns over (macOS); kept on the display and at least `minSize`.
function resize(start, handle, dx, dy, bounds, minSize) {
    const least = Math.min(minSize, bounds.w, bounds.h);
    let left = start.x;
    let top = start.y;
    let right = start.x + start.w;
    let bottom = start.y + start.h;
    const movesLeft = handle === "topLeft" || handle === "left" || handle === "bottomLeft";
    const movesRight = handle === "topRight" || handle === "right" || handle === "bottomRight";
    const movesTop = handle === "topLeft" || handle === "top" || handle === "topRight";
    const movesBottom = handle === "bottomLeft" || handle === "bottom" || handle === "bottomRight";
    if (movesLeft)
        left = clampTo(left + dx, 0, bounds.w);
    if (movesRight)
        right = clampTo(right + dx, 0, bounds.w);
    if (movesTop)
        top = clampTo(top + dy, 0, bounds.h);
    if (movesBottom)
        bottom = clampTo(bottom + dy, 0, bounds.h);
    const xs = spread(Math.min(left, right), Math.max(left, right), least, bounds.w, movesLeft === (left <= right));
    const ys = spread(Math.min(top, bottom), Math.max(top, bottom), least, bounds.h, movesTop === (top <= bottom));
    return {x: Math.round(xs[0]), y: Math.round(ys[0]), w: Math.round(xs[1] - xs[0]), h: Math.round(ys[1] - ys[0])};
}

// The frame dragged from inside by (dx, dy): it moves whole and stays on the display.
function move(start, dx, dy, bounds) {
    return {x: Math.round(clampTo(start.x + dx, 0, bounds.w - start.w)), y: Math.round(clampTo(start.y + dy, 0, bounds.h - start.h)),
        w: start.w, h: start.h};
}

// A new frame drawn from the press (ax, ay) to the pointer (bx, by), on the display, at least `minSize`.
function drawn(ax, ay, bx, by, bounds, minSize) {
    const least = Math.min(minSize, bounds.w, bounds.h);
    const x0 = clampTo(Math.min(ax, bx), 0, bounds.w);
    const x1 = clampTo(Math.max(ax, bx), 0, bounds.w);
    const y0 = clampTo(Math.min(ay, by), 0, bounds.h);
    const y1 = clampTo(Math.max(ay, by), 0, bounds.h);
    const xs = spread(x0, x1, least, bounds.w, bx < ax);
    const ys = spread(y0, y1, least, bounds.h, by < ay);
    return {x: Math.round(xs[0]), y: Math.round(ys[0]), w: Math.round(xs[1] - xs[0]), h: Math.round(ys[1] - ys[0])};
}

// A capture.* colour token as QML reads a colour: the tokens are written as slurp takes them, "#rrggbbaa", which Qt would read as
// "#aarrggbb"; this turns it round ("#AARRGGBB"). Anything else is returned as it is.
function qtColor(rgba) {
    const m = /^#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})$/.exec(String(rgba));
    return m ? "#" + m[2] + m[1] : String(rgba);
}

// The size readout while dragging: the picture's size in pixels (the logical size at the display's scale, as grim makes it).
function readout(r, scale) {
    const s = typeof scale === "number" && scale > 0 ? scale : 1;
    return Math.round(r.w * s) + " × " + Math.round(r.h * s);
}

// The frame as the helper's --geometry, in the compositor's coordinates (`origin`: the display's position).
function geometryText(r, origin) {
    return Math.round(origin.x + r.x) + "," + Math.round(origin.y + r.y) + " " + Math.round(r.w) + "x" + Math.round(r.h);
}

// capture.lastSelection: "NAME=x,y,w,h;NAME=..." (the last frame per display, its own coordinates, at most SELECTIONS_MAX).
var SELECTION_ENTRY = /^([A-Za-z0-9._-]{1,64})=(-?[0-9]{1,6}),(-?[0-9]{1,6}),([0-9]{1,6}),([0-9]{1,6})$/;
var SELECTIONS_MAX = 16;

// [[name, frame]] in the stored order (the entries that do not read are dropped).
function parseSelections(text) {
    const out = [];
    for (const part of String(text || "").split(";")) {
        const m = SELECTION_ENTRY.exec(part);
        if (m && Number(m[4]) > 0 && Number(m[5]) > 0 && !out.some(e => e[0] === m[1]))
            out.push([m[1], {x: Number(m[2]), y: Number(m[3]), w: Number(m[4]), h: Number(m[5])}]);
    }
    return out;
}

// The frame a display opens with: its last one, kept on the display, else the centred default.
function selectionFor(text, name, bounds, minSize) {
    const hit = parseSelections(text).find(e => e[0] === name);
    return hit ? clampFrame(hit[1], bounds, minSize) : defaultFrame(bounds);
}

// The stored text with the display's frame replaced (moved last; the oldest entries go beyond SELECTIONS_MAX).
function withSelection(text, name, r) {
    if (!OUTPUT_NAME.test(String(name)) || !validRect(r) || r.w <= 0 || r.h <= 0)
        return String(text || "");
    const kept = parseSelections(text).filter(e => e[0] !== name);
    kept.push([name, r]);
    return kept.slice(-SELECTIONS_MAX).map(e => e[0] + "=" + [e[1].x, e[1].y, e[1].w, e[1].h].map(v => Math.round(v)).join(",")).join(";");
}

// ---- Capture Selected Window ----

// The outline of a window as Hyprland draws it: a rectangle whose corners are superellipses of `power` that reach
// `radius` x `power` / 2 along each edge (decoration.rounding and rounding_power), as the points of a closed polygon, clockwise
// from the top left corner's end on the top edge. A circular corner of the same radius would leave notches.
function windowOutline(w, h, radius, power, steps) {
    const p = power > 0 ? power : 2;
    const n = Math.max(2, Math.round(steps || 12));
    const e = Math.max(0, Math.min(radius * p / 2, w / 2, h / 2));
    const pts = [];
    // Corner centres in drawing order: top left, top right, bottom right, bottom left, with the signs of their curves.
    const corners = [[e, e, -1, -1], [w - e, e, 1, -1], [w - e, h - e, 1, 1], [e, h - e, -1, 1]];
    for (let c = 0; c < 4; c++) {
        const k = corners[c];
        for (let i = 0; i <= n; i++) {
            // The quarter turn runs from the edge before the corner to the edge after it.
            const t = (c % 2 === 0 ? i : (n - i)) / n * Math.PI / 2;
            const dx = Math.pow(Math.cos(t), 2 / p);
            const dy = Math.pow(Math.sin(t), 2 / p);
            pts.push({x: k[0] + k[2] * e * dx, y: k[1] + k[3] * e * dy});
        }
    }
    return pts;
}

// The window drawn on top at the point (output-relative), among `windows` ({x, y, w, h, fullscreen, stamp}, the shown
// Desktop's): the most recently activated one there (Grassfield raises the window it activates), a full-screen window hiding the
// windows activated before it; of equal stamps, the later in the list. null when no window is there.
function windowAt(windows, px, py) {
    let under = (Array.isArray(windows) ? windows : []).map((w, index) => ({w: w, index: index}))
        .filter(e => e.w.w > 0 && e.w.h > 0 && px >= e.w.x && px < e.w.x + e.w.w && py >= e.w.y && py < e.w.y + e.w.h);
    const stamp = e => (typeof e.w.stamp === "number" ? e.w.stamp : 0);
    const later = (a, b) => (stamp(a) !== stamp(b) ? stamp(a) > stamp(b) : a.index > b.index);
    const full = under.filter(e => e.w.fullscreen === true);
    if (full.length > 0) {
        const cover = full.reduce((a, b) => (later(b, a) ? b : a));
        under = under.filter(e => e === cover || later(e, cover));
    }
    if (under.length === 0)
        return null;
    return under.reduce((a, b) => (later(b, a) ? b : a)).w;
}

// The part of a rectangle on the display ({x, y, w, h} output-relative, whole numbers), or null when none is.
function clip(r, bounds) {
    if (!validRect(r))
        return null;
    const x0 = Math.max(0, Math.round(r.x));
    const y0 = Math.max(0, Math.round(r.y));
    const x1 = Math.min(bounds.w, Math.round(r.x + r.w));
    const y1 = Math.min(bounds.h, Math.round(r.y + r.h));
    return x1 > x0 && y1 > y0 ? {x: x0, y: y0, w: x1 - x0, h: y1 - y0} : null;
}

// The Options menu (PopupMenu rows): Save to, Timer, Microphone for a recording, then Options (Show Mouse Pointer), each a
// section with its header and a check on the current choice. `labels` holds the translated texts (the QML's qsTr), by key:
// saveTo screenshots videos desktop documents clipboard preview timer none five ten microphone micNone micDefault options
// showPointer (`screenshots` names a screenshot's default folder, `videos` a recording's: one choice, `location:screenshots`).
function menuModel(mode, options, labels) {
    const o = options || {};
    const l = labels || {};
    const record = isRecord(mode);
    const destination = location(mode, o.location);
    const timer = TIMERS.indexOf(o.timer) >= 0 ? o.timer : "none";
    const rows = [{header: true, text: l.saveTo}];
    for (const id of record ? RECORD_LOCATIONS : LOCATIONS)
        rows.push({id: "location:" + id, text: id === "screenshots" && record ? l.videos : l[id], checked: destination === id});
    rows.push({separator: true}, {header: true, text: l.timer});
    const timerLabels = {"none": l.none, "5": l.five, "10": l.ten};
    for (const id of TIMERS)
        rows.push({id: "timer:" + id, text: timerLabels[id], checked: timer === id});
    if (record) {
        rows.push({separator: true}, {header: true, text: l.microphone});
        rows.push({id: "microphone:none", text: l.micNone, checked: o.microphone !== "default"});
        rows.push({id: "microphone:default", text: l.micDefault, checked: o.microphone === "default"});
    }
    rows.push({separator: true}, {header: true, text: l.options});
    rows.push({id: "showPointer:toggle", text: l.showPointer, checked: o.showPointer === true});
    return rows;
}

// A chosen row as the setting it changes ({key, value} of capture.<key>), or null for a row that changes nothing.
function choice(id, options) {
    const o = options || {};
    const parts = String(id || "").split(":");
    if (parts.length !== 2)
        return null;
    const key = parts[0];
    const value = parts[1];
    if (key === "location" && LOCATIONS.indexOf(value) >= 0)
        return {key: key, value: value};
    if (key === "timer" && TIMERS.indexOf(value) >= 0)
        return {key: key, value: value};
    if (key === "microphone" && (value === "none" || value === "default"))
        return {key: key, value: value};
    if (key === "showPointer" && value === "toggle")
        return {key: key, value: o.showPointer !== true};
    return null;
}
