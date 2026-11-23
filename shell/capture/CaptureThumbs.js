.pragma library
.import "../services/CaptureFile.js" as CaptureFile
.import "../store/CaptureLocation.js" as CaptureLocation

// The floating thumbnail's logic (spec docs/specs/capture-suite.md § 3.2, ADR-0066 D-1, D-9; slices A2 and A3). Pure functions
// (tests/unit/tst_capturethumbs.qml): the cards, their stack and layout, and the checks and argument vectors of every action.
//
// A result file is data (the helper's, but also anything that can write the user's runtime folder), so a path in it is never
// trusted for being named there. It is acted on only when it is a direct child of one of the Save-to folders, resolved as the
// helper's destination() resolves them (CaptureLocation.LOCATIONS; the folder a result names is never one of them), has a picture
// or movie extension for its kind and is no hidden name. What a path pure check cannot see (a link, a folder, a folder reached
// through a link) is checked by services/capture-thumb.sh, which every action that reads or removes the file goes through.

// The pictures a screenshot may be (the helper writes PNG today; JPEG and WebP come with slice B19) and the movies a recording may
// be, by extension; the type a copy declares.
var PICTURE_TYPES = {png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp"};
var MOVIE_EXTENSIONS = ["mp4", "mkv", "webm", "mov"];

// The Screenshots folder's names in the Pictures folder: the helper's SCREENSHOTS and every translation in its CATALOG (it keeps
// the one that exists, so changing the language never starts a second folder). A twin of that list.
var SCREENSHOT_FOLDERS = ["Screenshots", "Captures d’écran"];

// eslint-disable-next-line no-control-regex
var CONTROL = /[\u0000-\u001f\u007f]/;
var MAX_PATH = 4096;

// The user's folders as the helper's user_dir() finds them: `text` is the answers of `xdg-user-dir` for DESKTOP, DOCUMENTS,
// PICTURES and VIDEOS, one per line; an answer that is not an absolute path, or is the home folder or the root, is the folder
// of that name in the home folder. A trailing slash is dropped.
function userDirs(text, home) {
    const lines = String(text || "").split("\n");
    const names = ["desktop", "documents", "pictures", "videos"];
    const fallbacks = ["Desktop", "Documents", "Pictures", "Videos"];
    const h = String(home || "").replace(/\/+$/, "");
    const out = {home: h};
    for (let i = 0; i < names.length; i++) {
        let p = String(lines[i] || "").trim().replace(/\/+$/, "");
        if (p === "" || p[0] !== "/" || p === h || CONTROL.test(p))
            p = h + "/" + fallbacks[i];
        out[names[i]] = p;
    }
    return out;
}

// The folders a capture of `kind` goes to for one Save to location (CaptureLocation: screenshots, desktop, documents, clipboard,
// preview), as the helper's destination(save, record) does: a screenshot's default place is the Screenshots folder, a recording's
// the Videos folder; "clipboard" and "preview" keep the default place.
function foldersFor(location, kind, dirs) {
    if (location === "desktop")
        return [dirs.desktop];
    if (location === "documents")
        return [dirs.documents];
    if (kind === "recording")
        return [dirs.videos];
    return SCREENSHOT_FOLDERS.map(n => dirs.pictures + "/" + n);
}

// Every folder a capture of `kind` may be in: the union over all the Save to locations, since the setting can change while a card
// shows. Never the Pictures folder itself, the home folder or the folder a result names.
function roots(kind, dirs) {
    const list = [];
    for (const location of CaptureLocation.LOCATIONS)
        for (const folder of foldersFor(location, kind, dirs))
            if (list.indexOf(folder) < 0)
                list.push(folder);
    return list;
}

function extensionOf(name) {
    const dot = name.lastIndexOf(".");
    return dot > 0 ? name.substring(dot + 1).toLowerCase() : "";
}

// "" when `path` may be shown and acted on, else why not. Text only; the file system's part is capture-thumb.sh's.
function pathProblem(kind, path, dirs) {
    if (kind !== "shot" && kind !== "recording")
        return "not a capture kind";
    if (typeof path !== "string" || path === "" || path.length > MAX_PATH)
        return "not a path";
    if (CONTROL.test(path))
        return "control character";
    if (path[0] !== "/")
        return "not absolute";
    const parts = path.split("/").slice(1);
    // "" (a doubled or trailing slash), "." and ".." make a path that names something other than what it reads as.
    if (parts.some(p => p === "" || p === "." || p === ".."))
        return "not canonical";
    if (parts.length < 2)
        return "no folder";
    const name = parts[parts.length - 1];
    const folder = "/" + parts.slice(0, -1).join("/");
    if (name[0] === ".")
        return "hidden name";
    const ext = extensionOf(name);
    const known = kind === "shot" ? PICTURE_TYPES[ext] !== undefined : MOVIE_EXTENSIONS.indexOf(ext) >= 0;
    if (!known)
        return "not a " + (kind === "shot" ? "picture" : "movie");
    if (roots(kind, dirs).indexOf(folder) < 0)
        return "outside the Save to folders";
    return "";
}

// A Capture Text result: a card without a file (nothing in it is a path), the recognised text for its snippet.
function acceptText(result, screens) {
    const list = Array.isArray(screens) ? screens : [];
    const screen = CaptureFile.plateScreen({output: result.output, rect: result.rect}, list) || (list.length > 0 ? list[0].name : "");
    if (screen === "" || result.paths.length !== 0)
        return null;
    return {id: result.id, kind: "text", path: "", folder: "", name: "", pixels: null, text: result.text, screen: screen, time: result.time};
}

// The card for a result, or null when any of its paths is refused or no display can show it. `screens` is
// [{name, x, y, width, height}] (CaptureFile.plateScreen): the card goes on the display the capture came from, else the first.
function accept(result, dirs, screens) {
    if (!result || !dirs)
        return null;
    if (result.kind === "text")
        return acceptText(result, screens);
    for (const p of result.paths)
        if (pathProblem(result.kind, p, dirs) !== "")
            return null;
    const list = Array.isArray(screens) ? screens : [];
    const screen = CaptureFile.plateScreen({output: result.output, rect: result.rect}, list) || (list.length > 0 ? list[0].name : "");
    if (screen === "")
        return null;
    const path = result.primary;
    return {
        id: result.id,
        kind: result.kind,
        path: path,
        folder: path.substring(0, path.lastIndexOf("/")),
        name: path.substring(path.lastIndexOf("/") + 1),
        pixels: result.pixels,
        screen: screen,
        time: result.time
    };
}

// The stack: newest first. A card of the same id replaces itself; a display keeps at most `max` cards, the oldest leaves.
function push(cards, card, max) {
    const list = [card].concat((cards || []).filter(c => c.id !== card.id));
    const kept = [];
    const per = {};
    for (const c of list) {
        per[c.screen] = (per[c.screen] || 0) + 1;
        if (per[c.screen] <= max)
            kept.push(c);
    }
    return kept;
}

function remove(cards, id) {
    return (cards || []).filter(c => c.id !== id);
}

// A card's size, `m` = {width, pictureHeight, inset, minPictureWidth}: the picture fits the card's width (a screenshot's own shape,
// 16:9 for a recording or a size that is not known) and at most `pictureHeight` tall, narrower then (not less than
// `minPictureWidth`), so a tall capture does not fill the corner. {width, height, pictureWidth, pictureHeight} in points.
function cardSize(card, m) {
    const inner = m.width - 2 * m.inset;
    const ratio = card && card.kind === "shot" && card.pixels ? card.pixels.h / card.pixels.w : 9 / 16;
    let w = inner;
    let h = Math.round(inner * ratio);
    if (h > m.pictureHeight) {
        h = m.pictureHeight;
        w = Math.max(m.minPictureWidth, Math.round(h / ratio));
    }
    h = Math.max(1, h);
    return {width: w + 2 * m.inset, height: h + 2 * m.inset, pictureWidth: w, pictureHeight: h};
}

// Where each card of one display goes, `m` as cardSize plus `gap`: [{id, width, height, pictureWidth, pictureHeight, below}] in
// the stack's order (newest first, on top), `below` the room under the card up to the first card's bottom edge: the cards under it
// and their gaps. The oldest card is at the bottom, a new capture stacks above it (spec § 3.2).
function layout(cards, screenName, m) {
    const mine = (cards || []).filter(c => c.screen === screenName);
    const out = [];
    let below = 0;
    for (let i = mine.length - 1; i >= 0; i--) {
        const size = cardSize(mine[i], m);
        out.unshift({id: mine[i].id, width: size.width, height: size.height, pictureWidth: size.pictureWidth, pictureHeight: size.pictureHeight, below: below});
        below += size.height + m.gap;
    }
    return out;
}

// The text/uri-list of a drag: the file's URI, each part percent-encoded, a line end after it (RFC 2483).
function uriList(path) {
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/") + "\r\n";
}

// The file's URL for an Image (parts percent-encoded: a name with # or ? stays one path).
function fileUrl(path) {
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/");
}

// What a drag that has just passed the threshold, moved by (dx, dy), is: "swipe" (mostly sideways, toward the screen edge: the card
// follows the pointer and dismisses on release) or "out" (anything else: the file is dragged to another application).
function dragIntent(side, dx, dy) {
    const toward = side === "left" ? -dx : dx;
    return toward > 0 && Math.abs(dx) >= Math.abs(dy) ? "swipe" : "out";
}

// What an action runs, as argument vectors (nothing runs through a shell string), or null when it is refused. `script` is
// services/capture-thumb.sh. Actions:
//   verify   the script's check alone (a card is verified before it maps, and again when the pointer reaches it, before a drag)
//   copy     the picture onto the clipboard (a normal copy: the user asked); a recording is not copied
//   trash    gio trash, never a deletion
//   open     the file in its default application (Preview); `check` first, then `run`
//   reveal   the folder holding it in Files; `check` first, then `run`
// The script takes the action, the kind, the path and every Save to folder, and refuses what is not a regular file (not a link,
// not a folder) directly in one of them.
function plan(action, card, dirs, script) {
    if (!card || pathProblem(card.kind, card.path, dirs) !== "")
        return null;
    const folders = roots(card.kind, dirs);
    const guarded = verb => ["sh", script, verb, card.kind, card.path].concat(folders);
    switch (action) {
    case "verify":
        return {check: null, run: guarded("check")};
    case "copy":
        return card.kind === "shot" ? {check: null, run: guarded("copy")} : null;
    case "trash":
        return {check: null, run: guarded("trash")};
    case "open":
        return {check: guarded("check"), run: ["gio", "open", card.path]};
    case "reveal":
        return {check: guarded("check"), run: ["gio", "open", card.folder]};
    }
    return null;
}

// Whether a card dragged by (dx) from where it lay is far enough toward its screen edge to be dismissed on release.
function dismissed(side, dx, distance) {
    return (side === "left" ? -dx : dx) >= distance;
}

// The side the cards are on: capture.thumbnailSide, "right" for anything else.
function sideOf(value) {
    return value === "left" ? "left" : "right";
}

// How many seconds a card stays (capture.thumbnailSeconds, 2 to 30 in the schema); 0 for a value that is not a whole number of
// seconds in that range (the card then stays until it is closed, never closes at once).
function secondsOf(value) {
    return typeof value === "number" && isFinite(value) && Math.floor(value) === value && value >= 2 && value <= 30 ? value : 0;
}

// Whether the cards are hidden (unmapped) now. The capture's own `shooting` phase (a card must never be in a picture), a recording
// and what leads to it (the cards would be recorded), a frozen choice, the lock, and a full-attention surface (`held`).
function hiddenNow(phase, locked, held) {
    return locked === true || held === true || ["shooting", "frozen", "starting", "recording"].indexOf(phase) >= 0;
}
