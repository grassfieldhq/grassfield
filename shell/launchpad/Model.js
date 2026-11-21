.pragma library

// Apps panel model (pure, unit-tested): categories from .desktop Categories=, alphabetical order,
// grid metrics and keyboard navigation, and the hidden-entry list shared with Search.

// ---- categories ----------------------------------------------------------------------

// Chip identifiers in display order. "all" is every app; every app belongs to exactly one of the others.
const CATEGORY_IDS = ["all", "productivity", "creativity", "utilities", "games", "other"];

// freedesktop.org Menu Specification category -> chip. An app takes the first chip, in the order
// games, creativity, productivity, utilities, whose list holds one of its Categories= values (a game
// that also lists Utility stays a game; a graphics tool that also lists Office is creative). Values
// that match nothing (Network, WebBrowser, X-* extensions, Qt, GTK, ...) put the app in "other".
const CATEGORY_MAP = {
    games: ["Game", "ArcadeGame", "BoardGame", "BlocksGame", "CardGame", "LogicGame", "RolePlaying", "Shooter",
        "Simulation", "SportsGame", "StrategyGame", "Emulator", "KidsGame", "ActionGame", "AdventureGame"],
    creativity: ["Graphics", "2DGraphics", "3DGraphics", "VectorGraphics", "RasterGraphics", "Photography", "Scanning",
        "OCR", "AudioVideo", "Audio", "Video", "Music", "Midi", "Mixer", "Sequencer", "Tuner", "Recorder",
        "Player", "AudioVideoEditing", "Publishing"],
    productivity: ["Office", "WordProcessor", "Spreadsheet", "Presentation", "Calendar", "ContactManagement", "Email",
        "Database", "Dictionary", "Chart", "Finance", "FlowChart", "PDA", "ProjectManagement", "Development", "IDE",
        "Debugger", "Building", "GUIDesigner", "RevisionControl", "Translation", "WebDevelopment", "Education",
        "Science", "Math", "Engineering", "Literature", "Languages", "Maps"],
    utilities: ["Utility", "System", "Settings", "DesktopSettings", "HardwareSettings", "PackageManager", "Monitor",
        "Security", "TerminalEmulator", "FileManager", "FileTools", "Filesystem", "Archiving", "Compression",
        "Accessibility", "TextEditor", "TextTools", "Calculator", "Clock", "Core"]
};
const CATEGORY_ORDER = ["games", "creativity", "productivity", "utilities"];

const CATEGORY_LOOKUP = (function () {
    // No prototype: looked up with the Categories= values of any desktop file.
    const out = Object.create(null);
    for (const id of CATEGORY_ORDER) {
        for (const c of CATEGORY_MAP[id])
            out[c] = id;
    }
    return out;
})();

// Chip of an app from its Categories= values (array or ";"-separated string); "other" when none matches.
function categoryOf(categories) {
    const list = typeof categories === "string" ? categories.split(";") : Array.from(categories ?? []);
    const has = name => list.some(v => String(v).trim() === name);
    // A document viewer (Office + Viewer, e.g. a PDF reader that also lists Graphics) is a productivity app.
    if (has("Office") && has("Viewer") && !has("Game"))
        return "productivity";
    let best = "other";
    let bestRank = CATEGORY_ORDER.length;
    for (const raw of list) {
        const id = CATEGORY_LOOKUP[String(raw).trim()];
        if (id === undefined)
            continue;
        const rank = CATEGORY_ORDER.indexOf(id);
        if (rank < bestRank) {
            best = id;
            bestRank = rank;
        }
    }
    return best;
}

// ---- order and filtering -------------------------------------------------------------

// Records ({id, name, ...}) in alphabetical order (case-insensitive, then by id); a new array.
function sortApps(records) {
    const keyed = records.map(r => ({r: r, k: String(r.name ?? "").toLowerCase()}));
    keyed.sort((a, b) => a.k.localeCompare(b.k) || (a.r.id < b.r.id ? -1 : (a.r.id > b.r.id ? 1 : 0)));
    return keyed.map(x => x.r);
}

// {id: [record]} for every chip: "all" holds every record, the others those whose `category` matches.
// `records` must already be sorted; the order is kept.
function groupByCategory(records) {
    const out = {};
    for (const id of CATEGORY_IDS)
        out[id] = [];
    for (const r of records) {
        out.all.push(r);
        out[r.category in out ? r.category : "other"].push(r);
    }
    return out;
}

// Chips shown: "all" always, then every category that has at least one app, in display order.
function visibleCategories(groups) {
    return CATEGORY_IDS.filter(id => id === "all" || (groups[id] ?? []).length > 0);
}

// ---- grid ----------------------------------------------------------------------------

function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v));
}

// Panel size for an output. o: {width, widthMax, edgeMargin, heightFraction, minHeight, topFraction, topOffset,
// bottomClearance}. The panel starts topOffset (the search capsule above it and the gap, macOS 27) below the
// topFraction of the output. The height is a share of the output, at least minHeight, and never reaches into the
// bottom clearance (Dock); a very short output wins over minHeight.
function panelRect(screenW, screenH, o) {
    const w = Math.min(o.width, Math.max(0, screenW - 2 * o.edgeMargin));
    const top = Math.round(screenH * o.topFraction) + (o.topOffset || 0);
    const room = Math.max(0, screenH - top - o.bottomClearance);
    const h = Math.min(room, Math.max(o.minHeight, Math.round(screenH * o.heightFraction)));
    return {x: Math.round((screenW - w) / 2), y: top, w: w, h: h};
}

// Columns for the grid area `innerWidth` wide. o: {columns, minColumns, minCellWidth, cellHeight}.
function grid(innerWidth, o) {
    const cols = clamp(Math.floor(innerWidth / o.minCellWidth), o.minColumns, o.columns);
    return {cols: cols, cellW: innerWidth / cols, cellH: o.cellHeight};
}

// Rows fully or partly shown in a view `height` tall.
function visibleRows(height, cellH) {
    return Math.max(1, Math.floor(height / cellH));
}

// Keyboard selection in the grid (reading order, no pages). Left/Right walk the order, Up/Down move by a
// row and stay put at the first/last row (the caller then moves the focus to the chips, or ignores it),
// PageUp/PageDown move by `pageRows` rows, Home/End jump. Returns the new index.
function step(sel, key, cols, n, pageRows) {
    if (n <= 0)
        return -1;
    if (sel < 0)
        return 0;
    switch (key) {
    case "left":
        return Math.max(0, sel - 1);
    case "right":
        return Math.min(n - 1, sel + 1);
    case "up":
        return sel >= cols ? sel - cols : sel;
    case "down":
        // The last row may be short: Down from above it lands on the last item.
        if (Math.floor(sel / cols) >= Math.floor((n - 1) / cols))
            return sel;
        return Math.min(n - 1, sel + cols);
    case "pageup":
        return Math.max(sel % cols, sel - cols * pageRows);
    case "pagedown": {
        const last = Math.floor((n - 1) / cols);
        const row = Math.min(last, Math.floor(sel / cols) + pageRows);
        return Math.min(n - 1, row * cols + sel % cols);
    }
    case "home":
        return 0;
    case "end":
        return n - 1;
    }
    return sel;
}

// True when Up from `sel` leaves the grid (first row).
function atFirstRow(sel, cols) {
    return sel < cols;
}

// ---- selection and launch ------------------------------------------------------------

// Selected index after the keyboard focus moves to `zone`: the field with a query selects the first result (Return
// launches it); the chips and the field without a query select nothing. The grid is handled by the caller.
function selectionForZone(zone, searching, count) {
    return zone === "search" && searching && count > 0 ? 0 : -1;
}

// Index Return launches, -1 for nothing. Only an item whose selection ring is visible launches: the ring shows
// while the keyboard owns the selection (`keyNav`) or a query is active, and never in the chips zone.
function launchIndex(zone, keyNav, searching, selected, count) {
    if (zone === "chips" || !(keyNav || searching))
        return -1;
    return selected >= 0 && selected < count ? selected : -1;
}

// Index of the item with `id` in `items` ({id, ...}), -1 when it is gone.
function indexOfId(items, id) {
    if (id === "")
        return -1;
    return items.findIndex(i => i.id === id);
}

// ---- same name, different apps -------------------------------------------------------

// A reverse-DNS desktop entry id names its vendor in the second label (org.gnome.Nautilus -> GNOME); null for any other id.
const VENDOR_NAMES = {gnome: "GNOME", kde: "KDE", xfce: "Xfce", gimp: "GIMP", mozilla: "Mozilla", libreoffice: "LibreOffice"};

function vendorOf(id) {
    const m = /^[a-z]+\.([A-Za-z0-9_-]+)\.[A-Za-z0-9_.-]+$/.exec(String(id).replace(/\.desktop$/, ""));
    if (!m)
        return null;
    const v = m[1];
    // Own names only: the vendor part of an id may be "constructor".
    const known = Object.prototype.hasOwnProperty.call(VENDOR_NAMES, v.toLowerCase()) ? VENDOR_NAMES[v.toLowerCase()] : undefined;
    return known ?? (v.charAt(0).toUpperCase() + v.slice(1));
}

// Two installed apps can carry one Name (Grassfield Files and GNOME Files are both "Files"; macOS has one Finder, UX-11):
// no app is hidden, the names are told apart. Grassfield's own app (id org.grassfield.*) keeps the plain name, as the Finder
// would; every other app of a colliding name gets its vendor ("Files (GNOME)"), else its generic name when that differs,
// else its id. Two of them still equal after that get their ids. Records are {id, name, genericName}; a new array of
// copies, `name` replaced where it collided (`baseName` keeps the entry's own).
function disambiguate(records) {
    const out = records.map(r => Object.assign({}, r, {baseName: r.name}));
    // No prototype: the keys are app names, and an app may be called "Constructor".
    const groups = Object.create(null);
    for (const r of out) {
        const k = String(r.name ?? "").trim().toLowerCase();
        (groups[k] = groups[k] ?? []).push(r);
    }
    for (const k of Object.keys(groups)) {
        const group = groups[k];
        if (k === "" || group.length < 2)
            continue;
        for (const r of group) {
            if (String(r.id).startsWith("org.grassfield."))
                continue;
            const vendor = vendorOf(r.id);
            const generic = String(r.genericName ?? "").trim();
            const qualifier = vendor ?? (generic !== "" && generic.toLowerCase() !== k ? generic : String(r.id).replace(/\.desktop$/, ""));
            r.name = r.baseName + " (" + qualifier + ")";
        }
        const seen = Object.create(null);
        for (const r of group)
            seen[r.name] = (seen[r.name] ?? 0) + 1;
        for (const r of group) {
            if (seen[r.name] > 1)
                r.name = r.baseName + " (" + String(r.id).replace(/\.desktop$/, "") + ")";
        }
    }
    return out;
}

// ---- hidden entries ------------------------------------------------------------------

// Set of hidden desktop entry ids from the output of hidden-entries.sh. Ids are normalized like
// Quickshell's DesktopEntry.id (no ".desktop" suffix, no CR) so a lookup by entry id matches.
function parseHidden(text) {
    const set = {};
    for (const line of String(text).split("\n")) {
        const id = line.replace(/\r$/, "").replace(/\.desktop$/, "");
        if (id !== "")
            set[id] = true;
    }
    return set;
}

function isHidden(set, id) {
    return set[String(id).replace(/\.desktop$/, "")] === true;
}

// What entry-names.sh prints ("id<TAB>Name<TAB>GenericName<TAB>Comment<TAB>Keywords" per line) as a map without a
// prototype: id -> {name, genericName, comment, keywords: [...]}. A line without exactly five fields, an empty id or an
// empty Name is skipped (Quickshell drops an entry without a name: it never gets one here).
function parseLocalized(text) {
    const map = Object.create(null);
    for (const raw of String(text).split("\n")) {
        const fields = raw.replace(/\r$/, "").split("\t");
        if (fields.length !== 5 || fields[0] === "" || fields[1] === "")
            continue;
        map[fields[0]] = {
            name: fields[1],
            genericName: fields[2],
            comment: fields[3],
            keywords: fields[4].split(";").filter(k => k !== "")
        };
    }
    return map;
}
