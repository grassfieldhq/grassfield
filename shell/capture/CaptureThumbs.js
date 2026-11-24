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
// the Videos folder; "clipboard" and "preview" keep the default place. A screenshot's default place is also the Pictures folder
// itself: the helper's screenshots() falls back to it when the Screenshots folder is a link, a file or cannot be made.
function foldersFor(location, kind, dirs) {
    if (location === "desktop")
        return [dirs.desktop];
    if (location === "documents")
        return [dirs.documents];
    if (kind === "recording")
        return [dirs.videos];
    return SCREENSHOT_FOLDERS.map(n => dirs.pictures + "/" + n).concat([dirs.pictures]);
}

// Every folder a capture of `kind` may be in: the union over all the Save to locations, since the setting can change while a card
// shows. Exactly what the helper's destination() can produce (the Pictures folder for a screenshot only as its fallback), never
// the home folder, and a file only directly in one of them: the folder a result names is never a file.
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
    return {id: result.id, kind: "text", path: "", folder: "", name: "", pixels: null, text: result.text, qr: result.qr === true, screen: screen, time: result.time};
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

// A length in points snapped to whole device pixels at `scale` (1.25: 216 pt is 270 px, a card never lands on a fractional pixel).
function snap(value, scale) {
    const k = scale > 0 ? scale : 1;
    return Math.round(value * k) / k;
}

// How many lines of recognised text a Capture Text card shows: the text's lines, a long one wrapping at about `charsPerLine`
// characters, at most `maxLines`; none for a QR code (its data is never shown). The card is as tall as these.
function textLineCount(card, m) {
    if (!card || card.qr === true || !card.text)
        return 0;
    const per = Math.max(1, m.charsPerLine || 1);
    let n = 0;
    for (const line of String(card.text).split("\n"))
        n += Math.max(1, Math.ceil(line.length / per));
    return Math.min(Math.max(1, m.maxLines || 1), n);
}

// A card's size, `m` = {width, pictureHeight, inset, minPictureWidth, scale}: the picture fits the card's width (a screenshot's own
// shape, 16:9 for a recording or a size that is not known) and at most `pictureHeight` tall, narrower then (not less than
// `minPictureWidth`), so a tall capture does not fill the corner. {width, height, pictureWidth, pictureHeight} in points, all on
// whole device pixels at `m.scale`. The picture is the card (`inset` 0): no plate around it. A Capture Text card is as tall as its
// title and its first lines (`m.textPad`, `m.titleHeight`, `m.textGap`, `m.lineHeight`, `m.charsPerLine`, `m.maxLines`).
function cardSize(card, m) {
    const sc = m.scale;
    if (card && card.kind === "text") {
        const lines = textLineCount(card, m);
        const body = lines > 0 ? m.textGap + lines * m.lineHeight : 0;
        const h = snap(2 * m.textPad + m.titleHeight + body, sc);
        const w = snap(m.width, sc);
        return {width: w, height: h, pictureWidth: w, pictureHeight: h, lines: lines};
    }
    const inner = m.width - 2 * m.inset;
    const ratio = card && card.kind === "shot" && card.pixels ? card.pixels.h / card.pixels.w : 9 / 16;
    let w = snap(inner, sc);
    let h = snap(inner * ratio, sc);
    if (h > m.pictureHeight) {
        h = snap(m.pictureHeight, sc);
        w = Math.max(snap(m.minPictureWidth, sc), snap(h / ratio, sc));
    }
    h = Math.max(1 / (sc > 0 ? sc : 1), h);
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
        out.unshift({id: mine[i].id, width: size.width, height: size.height, pictureWidth: size.pictureWidth, pictureHeight: size.pictureHeight, lines: size.lines || 0, below: below});
        below += size.height + snap(m.gap, m.scale);
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

// The editor (the Screenshot app, apps/screenshot: `grassfield-screenshot <file>`, a local PNG).
var EDITOR = "grassfield-screenshot";

// What an action runs, as argument vectors (nothing runs through a shell string), or null when it is refused. `script` is
// services/capture-thumb.sh. Actions:
//   verify    the script's check alone (a card is verified before it maps, and again when the pointer reaches it, before a drag)
//   copy      the picture onto the clipboard (a normal copy: the user asked); a recording is not copied
//   trash     gio trash of the path the script checked, never a deletion
//   open      the file in its default application (a recording in Preview); `check` first, then `run`
//   annotate  a PNG screenshot in the Screenshot app, any other file as `open`; `check` first, then `run`
//   reveal    the folder holding it in Files; `check` first, then `run`
// The script takes the action, the kind, the path and every Save to folder, and refuses what is not a regular file (not a link,
// not a folder) directly in one of them. For `check` it prints the path it checked, links resolved: what `opened` turns into the
// command to run, so the file opened is the one checked (a swap after the check is by the same user and remains possible between
// the script's last look and the application's start).
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
    case "annotate":
    case "reveal":
        return {check: guarded("check"), run: opened(action, card, card.path)};
    }
    return null;
}

// The command of an `open`, `annotate` or `reveal` for `path`, the canonical path the script printed (its first line): null when
// that is not an absolute path to a file of the card's own name.
function opened(action, card, output) {
    const path = String(output || "").split("\n")[0];
    if (path === "" || path[0] !== "/" || CONTROL.test(path) || path.substring(path.lastIndexOf("/") + 1) !== card.name)
        return null;
    const folder = path.substring(0, path.lastIndexOf("/"));
    if (folder === "")
        return null;
    if (action === "reveal")
        return ["gio", "open", folder];
    if (action === "annotate" && card.kind === "shot" && extensionOf(card.name) === "png")
        return [EDITOR, path];
    if (action === "open" || action === "annotate")
        return ["gio", "open", path];
    return null;
}

// What a click on a card does: a PNG screenshot opens in the Screenshot app, anything else in its default application.
function clickAction(card) {
    return card && card.kind === "shot" ? "annotate" : "open";
}

// The helper that makes the card's picture (services/image-copy.py `file`, as the lock screen's avatar and the notifications'
// images): the shell decodes only the PNG it made, never the capture file itself. Bounded in time and killed with the shell.
function copyArgv(helper, path, cap, out) {
    return ["/usr/bin/timeout", "-k", "2", "20", "/usr/bin/setpriv", "--pdeathsig", "KILL", "--", "/usr/bin/python3", "-I", helper, "file", path, String(cap), out];
}

// The private folder of the pictures (0700, emptied at start and when the last card leaves: services/capture-thumb-dir.sh), in the
// folder of the helper's private files; "" when that is not an absolute path.
function copyFolder(privateFolder) {
    return privateFolder && String(privateFolder)[0] === "/" && !CONTROL.test(privateFolder) ? String(privateFolder).replace(/\/+$/, "") + "/capture-thumbs" : "";
}

// A picture's path in it: <folder>/<pid>-<n>.png ("" without the folder).
function copyPath(folder, pid, n) {
    return folder && String(folder).endsWith("/capture-thumbs") ? folder + "/" + pid + "-" + n + ".png" : "";
}

// The most a capture file may weigh for its picture to be made: 64 MiB. The largest display picture supported is 8K
// (7680 x 4320, 33 Mpx, under image-copy.py's 50 Mpx limit): raw it is 126 MiB, and a PNG of anything but noise is under half of
// that. The helper reads the file into memory and wraps it for rsvg-convert (a third more), inside its 1 GiB address-space limit.
var COPY_CAP = 64 * 1024 * 1024;

// The least width of a card's picture: the Close disc and the action capsule side by side with an inset around and between them
// (`button` the buttons' size, `pad` the room around a button in its disc or capsule, `inset` the card's inset), so a tall capture
// does not squeeze them over each other or out of the card.
function leastPictureWidth(button, pad, inset) {
    const closeWidth = button + 2 * pad;
    const capsuleWidth = 3 * button + 2 * pad;
    return 3 * inset + closeWidth + capsuleWidth;
}

// Whether a card dragged by (dx) from where it lay is far enough toward its screen edge to be dismissed on release.
function dismissed(side, dx, distance) {
    return (side === "left" ? -dx : dx) >= distance;
}

// The speed of a drag toward the screen edge (points per second, positive toward it) from its samples [{t (ms), x (points, the
// card's offset along the pointer)}], measured over the last `windowMs` before `now`; 0 without two samples in that stretch.
function swipeVelocity(side, samples, now, windowMs) {
    const recent = (samples || []).filter(p => now - p.t <= windowMs);
    if (recent.length < 2)
        return 0;
    const first = recent[0];
    const last = recent[recent.length - 1];
    const dt = last.t - first.t;
    if (dt <= 0)
        return 0;
    return (side === "left" ? first.x - last.x : last.x - first.x) / dt * 1000;
}

// Whether letting go of a swipe dismisses the card (macOS: a flick or a drag far enough toward the edge): it moved `distance`
// toward the edge, or it moved toward it at all and left at `flick` points per second or more.
function swipeDismisses(side, dx, velocity, distance, flick) {
    const toward = side === "left" ? -dx : dx;
    return toward >= distance || (toward > 0 && velocity >= flick);
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

// What is left of a card's time after it ran from `startedAt` to `now` (ms) and was paused: never under 1 ms, so a card that was
// hidden a moment before its time does not close the instant it is shown again. A capture, the lock or a toolbar pauses it.
function remainingAfter(remaining, startedAt, now) {
    return Math.max(1, remaining - Math.max(0, now - startedAt));
}

// Whether a card slides in now: when it is first mapped, never again after being unmapped by a capture, the lock or a toolbar.
function slidesIn(entered, shown) {
    return shown === true && entered !== true;
}

// Whether the cards are hidden (unmapped) now. The capture's own `shooting` phase (a card must never be in a picture), a recording
// and what leads to it (the cards would be recorded), a frozen choice, the lock, and a full-attention surface (`held`).
function hiddenNow(phase, locked, held) {
    return locked === true || held === true || ["shooting", "frozen", "starting", "recording"].indexOf(phase) >= 0;
}
