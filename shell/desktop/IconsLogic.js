.pragma library

// Desktop icons (pure logic, docs/specs/desktop.md): grid placement, rename validation, positions
// file, names, URI lists, icon names. No QML types, no I/O.
// Grid: slot (col, row); col 0 is the right-most column, col grows to the left, row 0 is the top row.
// New icons fill column-first from the top-right corner (the macOS order).

const VERSION = 1;

// ---- label tone -----------------------------------------------------------------------------------

// A label's ink over the wallpaper under it (ADR-0039 step 25, the menu bar's rule): dark (true) where the darkest of that
// range is at or above `lightBelow` (menubar.toneLightBelow: black text holds 4.5:1 there), white with its halo otherwise,
// and white when the range is unknown ({lumMin, lumMax} or null).
function darkLabelOver(range, lightBelow) {
    return range !== null && range !== undefined && typeof range.lumMin === "number" && range.lumMin >= lightBelow;
}

// The visible label under an icon (macOS: Finder's desktop): two lines at most, wrapped at words, and what does not fit is cut
// in the MIDDLE of the second line, so the end of the name (its extension) stays (Qt's own elide does not cut wrapped text in
// the middle). A first word wider than the label breaks anywhere, as Text.WrapAtWordBoundaryOrAnywhere did. `fits(text)`: the
// text is no wider than the label; `elide(text)`: the text cut in the middle to that width (FontMetrics.elidedText). The same
// rule as the Dock's stack labels (shell/dock/Stacks.js labelLines), for anywhere-breaks. Returns the lines joined by "\n".
function labelLines(name, fits, elide) {
    const text = String(name === undefined || name === null ? "" : name).replace(/\s+/g, " ").trim();
    if (text === "" || fits(text))
        return text;
    const words = text.split(" ");
    let first = "";
    let rest = "";
    if (!fits(words[0])) {
        let n = 1;
        while (n < text.length && fits(text.slice(0, n + 1)))
            n++;
        first = text.slice(0, n);
        rest = text.slice(n).trim();
    } else {
        let used = 1;
        while (used < words.length && fits(words.slice(0, used + 1).join(" ")))
            used++;
        first = words.slice(0, used).join(" ");
        rest = words.slice(used).join(" ");
    }
    return rest === "" ? first : first + "\n" + (fits(rest) ? rest : elide(rest));
}

// ---- grid ---------------------------------------------------------------------------------------

// {cols, rows} that fit in a work area of w x h px.
function gridSize(w, h, cellW, cellH) {
    return {cols: Math.max(1, Math.floor(w / cellW)), rows: Math.max(1, Math.floor(h / cellH))};
}

// Top-left corner (px, relative to the work area) of a slot.
function slotPos(col, row, areaW, cellW, cellH) {
    return {x: areaW - (col + 1) * cellW, y: row * cellH};
}

// Nearest slot for a top-left corner (px), clamped to the grid.
function slotAt(x, y, areaW, cellW, cellH, cols, rows) {
    const col = Math.round((areaW - cellW - x) / cellW);
    const row = Math.round(y / cellH);
    return {col: Math.max(0, Math.min(cols - 1, col)), row: Math.max(0, Math.min(rows - 1, row))};
}

function key(col, row) {
    return col + "," + row;
}

function validSlot(p, cols, rows) {
    return p !== null && typeof p === "object" && Number.isInteger(p.col) && Number.isInteger(p.row)
        && p.col >= 0 && p.row >= 0 && p.col < cols && p.row < rows;
}

// Names sorted case-insensitively (stable, locale independent).
function sortNames(names) {
    return names.slice().sort((a, b) => {
        const x = a.toLowerCase();
        const y = b.toLowerCase();
        return x < y ? -1 : (x > y ? 1 : (a < b ? -1 : (a > b ? 1 : 0)));
    });
}

// First free slot in column-first order from the top-right corner, or null when the grid is full.
function firstFree(taken, cols, rows) {
    for (let c = 0; c < cols; c++) {
        for (let r = 0; r < rows; r++) {
            if (!taken[key(c, r)])
                return {col: c, row: r};
        }
    }
    return null;
}

// Free slot nearest to `want` (Manhattan distance, then column-first), or null.
function nearestFree(taken, want, cols, rows) {
    let best = null;
    let bestD = Infinity;
    for (let c = 0; c < cols; c++) {
        for (let r = 0; r < rows; r++) {
            if (taken[key(c, r)])
                continue;
            const d = Math.abs(c - want.col) + Math.abs(r - want.row);
            if (d < bestD) {
                best = {col: c, row: r};
                bestD = d;
            }
        }
    }
    return best;
}

// Slots ({"col,row": true}) whose cell overlaps one of the widget rects ({x, y, w, h} in view px).
// The grid origin is (margin, topInset); slot geometry as in slotPos.
function blockedSlots(widgetRects, margin, topInset, areaW, cellW, cellH, cols, rows) {
    const out = {};
    for (let c = 0; c < cols; c++) {
        for (let r = 0; r < rows; r++) {
            const s = slotPos(c, r, areaW, cellW, cellH);
            const x = margin + s.x;
            const y = topInset + s.y;
            for (const w of widgetRects) {
                if (x < w.x + w.w && x + cellW > w.x && y < w.y + w.h && y + cellH > w.y) {
                    out[key(c, r)] = true;
                    break;
                }
            }
        }
    }
    return out;
}

// Layout for `names`: saved slots are kept when valid and not taken (first name in sort order wins),
// every other name takes the first free slot. Returns {name: {col, row}}; a name that finds no room
// (grid full) is left out.
function layout(names, saved, cols, rows, blocked) {
    const out = {};
    // Blocked slots (under a desktop widget) are never handed out nor kept.
    const taken = Object.assign({}, blocked || {});
    const pending = [];
    const sorted = sortNames(names);
    for (const n of sorted) {
        const p = saved && Object.prototype.hasOwnProperty.call(saved, n) ? saved[n] : null;
        if (validSlot(p, cols, rows) && !taken[key(p.col, p.row)]) {
            out[n] = {col: p.col, row: p.row};
            taken[key(p.col, p.row)] = true;
        } else {
            pending.push(n);
        }
    }
    for (const n of pending) {
        const p = firstFree(taken, cols, rows);
        if (!p)
            break;
        out[n] = p;
        taken[key(p.col, p.row)] = true;
    }
    return out;
}

// Move `moving` (names) by the slot delta of `anchor` going to `want`; every moved icon keeps its
// offset from the anchor. Icons that would leave the grid or hit a non-moving icon go to the nearest
// free slot. Returns a new layout.
function moveGroup(lay, moving, anchor, want, cols, rows) {
    const next = {};
    const taken = {};
    for (const n of Object.keys(lay)) {
        if (moving.indexOf(n) < 0) {
            next[n] = lay[n];
            taken[key(lay[n].col, lay[n].row)] = true;
        }
    }
    if (!lay[anchor])
        return lay;
    const dc = want.col - lay[anchor].col;
    const dr = want.row - lay[anchor].row;
    for (const n of sortNames(moving.filter(m => lay[m]))) {
        const target = {col: lay[n].col + dc, row: lay[n].row + dr};
        const clamped = {col: Math.max(0, Math.min(cols - 1, target.col)), row: Math.max(0, Math.min(rows - 1, target.row))};
        const spot = taken[key(clamped.col, clamped.row)] ? nearestFree(taken, clamped, cols, rows) : clamped;
        const final = spot ? spot : lay[n];
        next[n] = final;
        taken[key(final.col, final.row)] = true;
    }
    return next;
}

// Arrow-key navigation: from `current` (name or "") towards left|right|up|down. Picks the nearest
// icon in that direction (smallest primary distance, then smallest cross distance); with no current
// icon the first one in column-first order. Returns a name or "" when nothing is there.
function navigate(lay, current, dir) {
    const names = Object.keys(lay);
    if (names.length === 0)
        return "";
    if (!current || !lay[current]) {
        const ordered = names.sort((a, b) => lay[a].col - lay[b].col || lay[a].row - lay[b].row);
        return ordered[0];
    }
    const c = lay[current];
    // Screen direction: left means a higher col.
    const v = {left: [1, 0], right: [-1, 0], up: [0, -1], down: [0, 1]}[dir];
    if (!v)
        return current;
    let best = "";
    let bp = Infinity;
    let bc = Infinity;
    for (const n of names) {
        if (n === current)
            continue;
        const dc = (lay[n].col - c.col) * v[0];
        const dr = (lay[n].row - c.row) * v[1];
        const primary = dc + dr;
        if (primary <= 0)
            continue;
        const cross = v[0] !== 0 ? Math.abs(lay[n].row - c.row) : Math.abs(lay[n].col - c.col);
        if (primary < bp || (primary === bp && cross < bc)) {
            best = n;
            bp = primary;
            bc = cross;
        }
    }
    return best ? best : current;
}

// Names whose rectangle {x, y, w, h} intersects `band`.
function inRect(rects, band) {
    const out = [];
    for (const n of Object.keys(rects)) {
        const r = rects[n];
        if (r.x < band.x + band.w && r.x + r.w > band.x && r.y < band.y + band.h && r.y + r.h > band.y)
            out.push(n);
    }
    return out;
}

// ---- names --------------------------------------------------------------------------------------

function utf8Length(s) {
    let n = 0;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c < 0x80)
            n += 1;
        else if (c < 0x800)
            n += 2;
        else if (c >= 0xd800 && c <= 0xdbff) {
            n += 4;
            i++;
        } else
            n += 3;
    }
    return n;
}

// "" when `next` is a valid new name for `current` among `existing` names; otherwise the reason:
// "empty" | "slash" | "dots" | "control" | "long" | "exists". Renaming to the same name is "same".
function validateName(next, current, existing) {
    if (typeof next !== "string" || next.trim() === "")
        return "empty";
    if (next === current)
        return "same";
    if (next.indexOf("/") >= 0)
        return "slash";
    if (next === "." || next === "..")
        return "dots";
    for (let i = 0; i < next.length; i++) {
        if (next.charCodeAt(i) < 0x20 || next.charCodeAt(i) === 0x7f)
            return "control";
    }
    if (utf8Length(next) > 255)
        return "long";
    if (existing.indexOf(next) >= 0)
        return "exists";
    return "";
}

function splitExt(name) {
    const i = name.lastIndexOf(".");
    return i > 0 ? {base: name.substring(0, i), ext: name.substring(i)} : {base: name, ext: ""};
}

// `name`, or "base 2.ext", "base 3.ext", ... when it is taken. Taken includes a twin of the name that differs only by Unicode
// normalization (NFC "e acute" and NFD "e" + accent): a drop never makes two entries that look alike (GF-105).
function taken(existing, name) {
    if (existing.indexOf(name) >= 0)
        return true;
    const n = name.normalize("NFC");
    return existing.some(e => e.normalize("NFC") === n);
}

function uniqueName(name, existing) {
    if (!taken(existing, name))
        return name;
    const p = splitExt(name);
    for (let i = 2; i < 10000; i++) {
        const candidate = p.base + " " + i + p.ext;
        if (!taken(existing, candidate))
            return candidate;
    }
    return name;
}

// Name of a duplicate (macOS: "Report copy.pdf", then "Report copy 2.pdf"; a folder "Projects copy").
function copyName(name, existing, isDir) {
    const p = isDir ? {base: name, ext: ""} : splitExt(name);
    let candidate = p.base + " copy" + p.ext;
    for (let i = 2; taken(existing, candidate) && i < 10000; i++)
        candidate = p.base + " copy " + i + p.ext;
    return candidate;
}

// Name of an alias (macOS: "Report.pdf alias", then "Report.pdf alias 2").
function aliasName(name, existing) {
    let candidate = name + " alias";
    for (let i = 2; existing.indexOf(candidate) >= 0 && i < 10000; i++)
        candidate = name + " alias " + i;
    return candidate;
}

// Name of the archive Compress makes (macOS: "Report.pdf.zip" for one item, "Archive.zip" for several, numbered when taken).
function archiveName(names, existing) {
    return uniqueName(names.length === 1 ? names[0] + ".zip" : "Archive.zip", existing);
}

// Clean Up By order: `meta` maps a name to {isDir, size, modified, created} (seconds). Kind: folders first, then by
// extension; size: largest first; dates: newest first (macOS); ties by name.
function orderBy(names, key, meta) {
    const byName = sortNames(names);
    const rank = new Map(byName.map((n, i) => [n, i]));
    const m = n => meta[n] || {};
    const cmp = {
        name: () => 0,
        kind: (a, b) => (m(b).isDir === true) - (m(a).isDir === true) || extension(a).localeCompare(extension(b)),
        size: (a, b) => (m(b).size || 0) - (m(a).size || 0),
        modified: (a, b) => (m(b).modified || 0) - (m(a).modified || 0),
        created: (a, b) => (m(b).created || 0) - (m(a).created || 0)
    }[key];
    if (!cmp)
        return byName;
    return byName.sort((a, b) => cmp(a, b) || rank.get(a) - rank.get(b));
}

// Clean Up: the icons in the order they are seen now (column-first from the top-right), packed into the first slots.
function visualOrder(lay) {
    return Object.keys(lay).sort((a, b) => lay[a].col - lay[b].col || lay[a].row - lay[b].row || (a < b ? -1 : a > b ? 1 : 0));
}

// Tab / Shift+Tab (GF-106): the icon after (before) `current` in visualOrder, wrapping around; the first (last) one when
// nothing is current. "" for an empty desktop.
function cycle(lay, current, backwards) {
    const order = visualOrder(lay);
    if (order.length === 0)
        return "";
    const at = order.indexOf(current);
    if (at < 0)
        return backwards ? order[order.length - 1] : order[0];
    return order[(at + (backwards ? order.length - 1 : 1)) % order.length];
}

// Slots for `ordered` names, one after the other in column-first order, skipping blocked slots (under a widget).
function arrange(ordered, cols, rows, blocked) {
    const out = {};
    const taken = Object.assign({}, blocked || {});
    for (const n of ordered) {
        const p = firstFree(taken, cols, rows);
        if (!p)
            break;
        out[n] = p;
        taken[key(p.col, p.row)] = true;
    }
    return out;
}

// stat -c '%F|%s|%Y|%W|%n' lines -> {name: {isDir, size, modified, created}}. The name comes last, so a "|" in it is
// kept; created falls back to modified when the file system records no birth time (%W is 0).
function parseStat(text) {
    const out = {};
    for (const line of String(text).split("\n")) {
        const f = line.split("|");
        if (f.length < 5)
            continue;
        const name = baseName(f.slice(4).join("|"));
        if (name === "")
            continue;
        const modified = parseInt(f[2], 10) || 0;
        const created = parseInt(f[3], 10);
        out[name] = {
            isDir: f[0] === "directory",
            size: parseInt(f[1], 10) || 0,
            modified: modified,
            created: created > 0 ? created : modified
        };
    }
    return out;
}

// ---- positions file -----------------------------------------------------------------------------

// {ok, positions} from the file text; anything that is not a version 1 file with valid slots gives
// {ok: false, positions: {}} (never throws).
function parse(text) {
    let doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return {ok: false, positions: {}};
    }
    if (doc === null || typeof doc !== "object" || doc.version !== VERSION || doc.positions === null || typeof doc.positions !== "object" || Array.isArray(doc.positions))
        return {ok: false, positions: {}};
    const positions = {};
    for (const n of Object.keys(doc.positions)) {
        const p = doc.positions[n];
        if (p !== null && typeof p === "object" && Number.isInteger(p.col) && Number.isInteger(p.row) && p.col >= 0 && p.row >= 0)
            positions[n] = {col: p.col, row: p.row};
    }
    return {ok: true, positions: positions};
}

// Positions for files that still exist.
function prune(positions, names) {
    const out = {};
    for (const n of names) {
        if (Object.prototype.hasOwnProperty.call(positions, n))
            out[n] = positions[n];
    }
    return out;
}

function serialize(positions) {
    const sorted = {};
    for (const n of Object.keys(positions).sort())
        sorted[n] = {col: positions[n].col, row: positions[n].row};
    return JSON.stringify({version: VERSION, positions: sorted}, null, 2) + "\n";
}

// A rename keeps the position.
function renamed(positions, from, to) {
    const out = Object.assign({}, positions);
    if (Object.prototype.hasOwnProperty.call(out, from)) {
        out[to] = out[from];
        delete out[from];
    }
    return out;
}

// ---- URI lists ----------------------------------------------------------------------------------

function percentEncodePath(path) {
    return path.split("/").map(s => encodeURIComponent(s).replace(/[!'()*]/g, c => "%" + c.charCodeAt(0).toString(16).toUpperCase())).join("/");
}

// Path part of a file: URL.
function uriPath(path) {
    return percentEncodePath(path);
}

// text/uri-list (CRLF separated) of absolute local paths.
function uriList(paths) {
    return paths.map(p => "file://" + percentEncodePath(p)).join("\r\n") + "\r\n";
}

// Absolute local paths from a text/uri-list body; comments, other schemes, relative and
// non-decodable entries are dropped (a file: URI with a remote host too).
function parseUriList(text) {
    const out = [];
    for (const line of String(text).split(/\r?\n/)) {
        const l = line.trim();
        if (l === "" || l.startsWith("#") || !/^file:\/\//i.test(l))
            continue;
        let rest = l.substring(7);
        if (!rest.startsWith("/")) {
            const slash = rest.indexOf("/");
            const host = slash < 0 ? rest : rest.substring(0, slash);
            if (host !== "localhost")
                continue;
            rest = slash < 0 ? "" : rest.substring(slash);
        }
        let path;
        try {
            path = decodeURIComponent(rest);
        } catch (e) {
            continue;
        }
        if (path.startsWith("/") && path.indexOf("\0") < 0)
            out.push(path);
    }
    return out;
}

// The desktop's clipboard probe (DesktopFiles.qml) prints "cut=1" or "cut=0" on its first line, then the text/uri-list
// body; an output without that line (no uri list on the clipboard) holds no files. `uriText` is the list exactly as
// the clipboard held it, what a later check compares before emptying the clipboard.
function parseClipboardProbe(text) {
    const s = String(text);
    const nl = s.indexOf("\n");
    const head = (nl < 0 ? s : s.substring(0, nl)).trim();
    if (head !== "cut=1" && head !== "cut=0")
        return {cut: false, paths: [], uriText: ""};
    const body = nl < 0 ? "" : s.substring(nl + 1);
    return {cut: head === "cut=1", paths: parseUriList(body), uriText: body};
}

function baseName(path) {
    const p = path.replace(/\/+$/, "");
    return p.substring(p.lastIndexOf("/") + 1);
}

function dirName(path) {
    const p = path.replace(/\/+$/, "");
    const i = p.lastIndexOf("/");
    return i <= 0 ? "/" : p.substring(0, i);
}

// ---- icons --------------------------------------------------------------------------------------

const IMAGE_EXT = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "avif"];

const ICON_BY_EXT = {
    pdf: "application-pdf",
    txt: "text-x-generic", md: "text-x-generic", log: "text-x-generic", json: "text-x-generic",
    zip: "package-x-generic", tar: "package-x-generic", gz: "package-x-generic", xz: "package-x-generic", "7z": "package-x-generic", rar: "package-x-generic",
    mp3: "audio-x-generic", flac: "audio-x-generic", ogg: "audio-x-generic", wav: "audio-x-generic", m4a: "audio-x-generic",
    mp4: "video-x-generic", mkv: "video-x-generic", webm: "video-x-generic", mov: "video-x-generic",
    doc: "x-office-document", docx: "x-office-document", odt: "x-office-document",
    xls: "x-office-spreadsheet", xlsx: "x-office-spreadsheet", ods: "x-office-spreadsheet",
    ppt: "x-office-presentation", pptx: "x-office-presentation", odp: "x-office-presentation",
    sh: "text-x-script", py: "text-x-script", js: "text-x-script", lua: "text-x-script", qml: "text-x-script",
    html: "text-html", htm: "text-html",
    iso: "media-optical", appimage: "application-x-executable"
};

function extension(name) {
    const i = name.lastIndexOf(".");
    return i > 0 ? name.substring(i + 1).toLowerCase() : "";
}

function isImage(name) {
    return IMAGE_EXT.indexOf(extension(name)) >= 0;
}

function isLauncher(name) {
    return extension(name) === "desktop";
}

// Theme icon name for a file; the caller falls back to "text-x-generic" (`unknown`) when the theme lacks it.
function iconName(name, isDir) {
    if (isDir)
        return "folder";
    const ext = extension(name);
    if (isImage(name))
        return "image-x-generic";
    return Object.prototype.hasOwnProperty.call(ICON_BY_EXT, ext) ? ICON_BY_EXT[ext] : "text-x-generic";
}

// Name and Icon of a .desktop file ([Desktop Entry] group, unlocalized keys only). Never executes
// or expands anything: both values are plain text for display.
function parseLauncher(text) {
    let inEntry = false;
    const out = {name: "", icon: ""};
    for (const line of String(text).split(/\r?\n/)) {
        const l = line.trim();
        if (l.startsWith("[")) {
            inEntry = l === "[Desktop Entry]";
            continue;
        }
        if (!inEntry)
            continue;
        if (l.startsWith("Name=") && out.name === "")
            out.name = l.substring(5).trim();
        else if (l.startsWith("Icon=") && out.icon === "")
            out.icon = l.substring(5).trim();
    }
    return out;
}

// Whether the desktop may show its icons: the surface is sized, the settings file was read (the Dock edge and size move the
// grid), the widgets file was read (widgets block slots), the positions file was read and the folder's first complete listing
// is in. Before that nothing is exposed (not a default layout, not an empty or partial folder), so no icon appears and then
// moves or goes. `in` is {width, height, settings, widgets, positions, listed}.
function settledOn(inputs) {
    if (!inputs)
        return false;
    return inputs.width > 0 && inputs.height > 0 && inputs.settings === true && inputs.widgets === true && inputs.positions === true && inputs.listed === true;
}

// Desktop folder: the configured override, else the XDG desktop dir, else ~/Desktop. An XDG answer
// that is empty, "/" or the home directory itself (no desktop folder configured) falls back too.
function desktopDir(override, xdgAnswer, home) {
    const h = cleanPath(home);
    if (override)
        return cleanPath(override);
    const x = cleanPath(String(xdgAnswer || "").trim());
    if (x !== "" && x !== "/" && x !== h && x.startsWith("/"))
        return x;
    return cleanPath(h + "/Desktop");
}

// The lexical clean form of an absolute path, as the folder model spells its rows: single slashes, no "." and no trailing
// slash, ".." resolved (never above the root). A relative or empty path is returned with its slashes collapsed only
// ("" stays ""); the caller refuses it.
function cleanPath(path) {
    const p = String(path || "");
    if (p === "")
        return "";
    const abs = p.startsWith("/");
    const out = [];
    for (const part of p.split("/")) {
        if (part === "" || part === ".")
            continue;
        if (part === "..") {
            if (out.length > 0 && out[out.length - 1] !== "..")
                out.pop();
            else if (!abs)
                out.push(part);
            continue;
        }
        out.push(part);
    }
    return (abs ? "/" : "") + out.join("/");
}
