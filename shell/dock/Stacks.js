.pragma library

// Dock folder stacks (macOS: a folder kept in the right section of the Dock, e.g. Downloads, opens as a Fan, a Grid or a
// List). Pure functions, tested in tests/unit/tst_dockstacks.qml. Spec: docs/specs/dock.md requirement 25.
//
// Settings: `dock.folders` (paths, "~/" allowed), `dock.stackOptions` ({path: {sort, view, display}}).

var SORTS = ["name", "dateAdded", "dateModified", "dateCreated", "kind"];
var VIEWS = ["automatic", "fan", "grid", "list"];
var DISPLAYS = ["stack", "folder"];

var DEFAULTS = {sort: "dateAdded", view: "automatic", display: "stack"};

function pick(value, allowed, fallback) {
    return typeof value === "string" && allowed.indexOf(value) >= 0 ? value : fallback;
}

function normalizeSort(value) {
    return pick(value, SORTS, DEFAULTS.sort);
}

function normalizeView(value) {
    return pick(value, VIEWS, DEFAULTS.view);
}

function normalizeDisplay(value) {
    return pick(value, DISPLAYS, DEFAULTS.display);
}

// "~" and "~/x" read against `home`; anything else is returned as it is.
function expandHome(path, home) {
    const p = String(path);
    if (p === "~")
        return home;
    return p.startsWith("~/") ? home + p.substring(1) : p;
}

// "/a/b/" and "/a//b" read as "/a/b"; the root stays "/".
function cleanPath(path) {
    const parts = String(path).split("/").filter(s => s !== "" && s !== ".");
    return "/" + parts.join("/");
}

// The folders of the Dock as absolute, clean, distinct paths in their order (a stored value is untrusted): non-strings,
// relative paths and "..", and the root itself are dropped; at most `max`.
function folderList(list, home, max) {
    const out = [];
    const n = list && typeof list.length === "number" ? list.length : 0;
    for (let i = 0; i < n; i++) {
        if (typeof list[i] !== "string" || list[i] === "")
            continue;
        const full = expandHome(list[i], home);
        if (!full.startsWith("/") || full.split("/").indexOf("..") >= 0)
            continue;
        const clean = cleanPath(full);
        if (clean === "/" || out.indexOf(clean) >= 0)
            continue;
        out.push(clean);
        if (out.length >= max)
            break;
    }
    return out;
}

// Options of one folder: its stored entry, each field validated, the macOS defaults for what is missing.
function optionsFor(all, path) {
    const o = all && typeof all === "object" && all[path] && typeof all[path] === "object" ? all[path] : {};
    return {sort: normalizeSort(o.sort), view: normalizeView(o.view), display: normalizeDisplay(o.display)};
}

// The stored options after one field of one folder changed. Entries of unknown fields and values are dropped; a folder whose
// options all equal the defaults has no entry.
function withOption(all, path, key, value) {
    const next = {};
    const source = all && typeof all === "object" ? all : {};
    for (const p of Object.keys(source)) {
        if (typeof p === "string" && p.startsWith("/") && p !== path)
            next[p] = optionsFor(source, p);
    }
    const o = optionsFor(source, path);
    if (key === "sort")
        o.sort = normalizeSort(value);
    else if (key === "view")
        o.view = normalizeView(value);
    else if (key === "display")
        o.display = normalizeDisplay(value);
    next[path] = o;
    for (const p of Object.keys(next)) {
        const v = next[p];
        if (v.sort === DEFAULTS.sort && v.view === DEFAULTS.view && v.display === DEFAULTS.display)
            delete next[p];
    }
    return next;
}

function baseName(path) {
    const parts = String(path).split("/").filter(s => s !== "");
    return parts.length > 0 ? parts[parts.length - 1] : "/";
}

// Icon theme name of a folder tile: the places icons of the XDG user folders, "folder" for the rest.
function folderIconName(path, home) {
    const rel = String(path).startsWith(home + "/") ? String(path).substring(home.length + 1) : "";
    const names = {
        "Downloads": "folder-download",
        "Documents": "folder-documents",
        "Pictures": "folder-pictures",
        "Music": "folder-music",
        "Videos": "folder-videos",
        "Desktop": "user-desktop"
    };
    return names[rel] ? names[rel] : "folder";
}

// ---- The helper's window (apps/stack-helper, shell/dock/StackHelper.qml) ----

// A name as the helper writes it: backslash, line break, return and US are escaped as \\, \n, \r and \u.
function unescapeName(text) {
    if (text.indexOf("\\") < 0)
        return text;
    // Linear, and without a call per escape (300 names of 255 backslashes were 160 to 266 ms with one callback per match): the
    // doubled backslashes become NUL (which no file name holds) by a native regex replace, then the three one-letter escapes
    // are plain replacements, then NUL becomes one backslash (each step one native call on the whole name). Scanning left to right, a doubled backslash is always a pair.
    // A byte that is not part of valid UTF-8 comes as \xHH (F22): it shows as U+FFFD (nameUriSegment keeps the byte).
    return text.replace(/\\\\/g, "\0").replace(/\\n/g, "\n").replace(/\\r/g, "\r").replace(/\\u/g, "\x1f")
        .replace(/\\x[0-9a-f]{2}/g, "\ufffd").replace(/\0/g, "\\");
}

// The same name as the last segment of a file: URI, byte for byte (\xHH becomes %HH): what opens a file whose name is not
// UTF-8 (F22; gio decodes the URI to the name's bytes).
function nameUriSegment(text) {
    const parts = String(text).replace(/\\\\/g, "\0").split(/(\\x[0-9a-f]{2})/);
    return parts.map(p => /^\\x[0-9a-f]{2}$/.test(p) ? "%" + p.substring(2).toUpperCase()
        : encodeURIComponent(p.replace(/\\n/g, "\n").replace(/\\r/g, "\r").replace(/\\u/g, "\x1f").replace(/\0/g, "\\"))).join("");
}

// One "W" line of the helper: the window, the first entries of the folder in the stack's order, fields separated by US:
// W, sequence, total, n, then n times name, isDir (0 or 1), modified, added, created (seconds).
// A parser that works in slices: `valid` says whether the line is one; step(budgetMs) reads entries until the budget is used and says
// whether it is done (a name made of hundreds of escapes costs a third of a millisecond, 300 of them 100 ms: never one long call on
// the GUI thread); `result` is {sequence, total, entries: [{name, path, uri, isDir, modified, added, created}]}.
function windowParser(line, dir) {
    const f = String(line).split("\x1f");
    const n = f[0] === "W" && f.length >= 4 ? parseInt(f[3]) : -1;
    const base = String(dir).replace(/\/+$/, "");
    // A stack whose folder is itself a URI (a folder opened in place by its URI, F22) keeps it as it is.
    const baseUri = base.startsWith("file://") ? base : fileUrl(base);
    const p = {
        valid: n >= 0 && f.length >= 4 + 5 * n,
        index: 0,
        result: {sequence: parseInt(f[1]) || 0, total: parseInt(f[2]) || 0, entries: []},
        step: function (budgetMs) {
            const end = Date.now() + budgetMs;
            while (p.index < n) {
                const at = 4 + 5 * p.index;
                const name = unescapeName(f[at]);
                p.result.entries.push({
                    name: name,
                    path: base + "/" + name,
                    // The entry's file: URI, byte for byte (a name that is not UTF-8 opens through it, F22).
                    uri: baseUri + "/" + nameUriSegment(f[at]),
                    isDir: f[at + 1] === "1",
                    modified: parseFloat(f[at + 2]) || 0,
                    added: parseFloat(f[at + 3]) || 0,
                    created: parseFloat(f[at + 4]) || 0
                });
                p.index++;
                if (p.index < n && Date.now() >= end)
                    return false;
            }
            return true;
        }
    };
    return p;
}

// The whole window at once (tests and small windows); null when the line is not one.
function parseWindow(line, dir) {
    const p = windowParser(line, dir);
    if (!p.valid)
        return null;
    p.step(1e9);
    return p.result;
}

// ---- Views ----

// The view an "Automatic" stack shows (macOS): a Fan while the items fit in it, a Grid beyond that. The others are as chosen.
function resolveView(view, count, fanMax) {
    const v = normalizeView(view);
    if (v !== "automatic")
        return v;
    return count <= fanMax ? "fan" : "grid";
}

// Items a Fan shows (the rest are reached through "Open in Files").
function fanItems(count, fanMax) {
    return Math.max(0, Math.min(count, fanMax));
}

// Where the n icons of a Fan sit. `step` is the distance between two icons along the line away from the Dock and `bend`
// how far the last one has moved sideways; the sideways offset grows with the square of the position (a curve like
// macOS'). Item 0 is the one nearest the Dock. Returns [{out, side}] in px: `out` is the distance from the tile (>= 0),
// `side` the offset along the Dock.
function fanLayout(n, step, bend) {
    const out = [];
    const last = Math.max(1, n - 1);
    for (let i = 0; i < n; i++)
        out.push({out: i * step, side: bend * (i / last) * (i / last)});
    return out;
}

// Columns of a Grid: a square-ish grid, at most `maxColumns`, at least 1.
function gridColumns(count, maxColumns) {
    return Math.max(1, Math.min(maxColumns, Math.ceil(Math.sqrt(Math.max(1, count)))));
}

// Index reached from `index` by a key in a list or grid of `count` items in `columns` columns (columns 1: a list). Up/Down
// move a row, Left/Right an item; Home/End the ends. No wrap. -1 (nothing current) enters at the first item.
function step(index, count, columns, key) {
    if (count <= 0)
        return -1;
    if (index < 0)
        return 0;
    const last = count - 1;
    switch (key) {
    case "left":
        return columns > 1 ? Math.max(0, index - 1) : index;
    case "right":
        return columns > 1 ? Math.min(last, index + 1) : index;
    case "up":
        return index - columns >= 0 ? index - columns : index;
    case "down":
        return index + columns <= last ? index + columns : index;
    case "home":
        return 0;
    case "end":
        return last;
    }
    return index;
}

// Icon theme names to try for an entry, most specific first: the MIME type as an icon name ("image/png" is "image-png"),
// then its generic family ("image-x-generic"), then a plain file. Folders: "folder".
function iconCandidates(mime, isDir) {
    if (isDir)
        return ["folder"];
    const out = [];
    const m = String(mime || "");
    if (m.indexOf("/") > 0) {
        out.push(m.replace("/", "-"));
        const family = m.substring(0, m.indexOf("/"));
        if (["audio", "image", "video", "text", "font"].indexOf(family) >= 0)
            out.push(family + "-x-generic");
        if (m.indexOf("zip") >= 0 || m.indexOf("tar") >= 0 || m.indexOf("compress") >= 0)
            out.push("package-x-generic");
    }
    out.push("text-x-generic");
    out.push("application-x-generic");
    return out;
}

// Image types that have a real preview (drawn from the file itself, like macOS' thumbnails in a stack).
function hasPreview(mime) {
    return ["image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp", "image/svg+xml"].indexOf(String(mime)) >= 0;
}

// file:// URL of a local path for an Image source.
function fileUrl(path) {
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/");
}

// ---- Adding a folder by dropping it on the Dock (macOS: drag a folder to the right section of the Dock) ----

// The folders after `add` (clean absolute paths, or ~/ ones) were dropped at slot `index` of the current list (0: first,
// list.length: last). A folder that already is in the Dock moves to the slot instead of being added twice. At most `max`.
function insertFolders(list, add, index, home, max) {
    const current = folderList(list, home, 1000);
    const incoming = folderList(add, home, 1000);
    const rest = current.filter(p => incoming.indexOf(p) < 0);
    const at = Math.max(0, Math.min(Number.isInteger(index) ? index : current.length, current.length));
    const before = current.slice(0, at).filter(p => incoming.indexOf(p) < 0).length;
    return rest.slice(0, before).concat(incoming, rest.slice(before)).slice(0, max);
}

// Whether dragged `paths` can be added: "yes" when every one is known to be a folder, "no" when one is known not to be (a
// file, an unreadable path) or there is nothing, "pending" while some type is not looked up yet. `resolved` maps a path to its
// type (dock/file-types.sh: inode/directory for a folder).
function folderVerdict(paths, resolved) {
    const list = Array.from(paths || []);
    if (list.length === 0)
        return "no";
    let pending = false;
    for (const p of list) {
        const t = resolved ? resolved[p] : undefined;
        if (t === undefined)
            pending = true;
        else if (t !== "inode/directory")
            return "no";
    }
    return pending ? "pending" : "yes";
}

// The slot a folder dropped at `main` (a coordinate along the Dock) would take: the number of folder tiles whose centre lies
// before it, or -1 when the pointer is left of the divider (the folders live in the right section). `centers` are the tile
// centres of the unmagnified layout, `separator` the index of the divider tile (-1 none), `count` the folder tiles after it.
function folderSlot(main, centers, separator, count) {
    if (!(separator >= 0) || centers[separator] === undefined || main < centers[separator])
        return -1;
    let k = 0;
    for (let i = separator + 1; i <= separator + count; i++) {
        if (centers[i] !== undefined && centers[i] < main)
            k++;
    }
    return k;
}

// ---- The pile on a stack tile (macOS "Display as: Stack": the newest items piled up, the newest on top) ----

// The sheets of the pile, back to front, from the folder's newest items (newest first, as the listing gives them): at most
// `max` of them, each {path, isDir, rank} with rank 0 the newest (the top sheet). A different newest item makes a different
// top sheet: the result is a pure function of `newest`, so a view bound to it follows the folder.
function pileSheets(newest, max) {
    const list = Array.from(newest || []).filter(e => e && typeof e.path === "string" && e.path !== "").slice(0, Math.max(0, max));
    const out = [];
    for (let i = list.length - 1; i >= 0; i--)
        out.push({path: list[i].path, isDir: list[i].isDir === true, rank: i});
    return out;
}

// The visible label of a Grid cell (macOS stack labels): the name wraps at word boundaries onto two lines at most, and what does
// not fit is cut in the MIDDLE of the second line, so the end of the name (its extension) stays. A name whose first word is
// wider than the cell is one line cut in the middle. `fits(text)`: the text is no wider than the cell; `elide(text)`: the text
// cut in the middle to the cell's width (the font metrics' elidedText). Returns the lines joined by "\n".
function labelLines(name, fits, elide) {
    const text = String(name === undefined || name === null ? "" : name).replace(/\s+/g, " ").trim();
    if (text === "" || fits(text))
        return text;
    const words = text.split(" ");
    if (!fits(words[0]))
        return elide(text);
    let used = 1;
    while (used < words.length && fits(words.slice(0, used + 1).join(" ")))
        used++;
    const first = words.slice(0, used).join(" ");
    const rest = words.slice(used).join(" ");
    return rest === "" ? first : first + "\n" + (fits(rest) ? rest : elide(rest));
}
