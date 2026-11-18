.pragma library
// Unversioned on purpose (as apps/settings/qml/Store.js): a versioned import directive resolves the installed Grassfield.Ui, not
// the tree's own (QML_IMPORT_PATH), and a function added since is missing there.
.import Grassfield.Ui as Ui

// Notification history model (pure, unit-tested): ADR-0004 limits, persistence format, grouping.
//
// Entry: {key, nid, appName, appIcon, summary, body, time (ms), urgency (0 low, 1 normal, 2 critical),
//         transient, resident, actions: [{id, text}], restored}
// nid is the id of the live notification (-1 when restored from disk: not actionable).

const MAX_ENTRIES = 200;
const MAX_AGE_MS = 7 * 24 * 3600 * 1000;
const FORMAT_VERSION = 1;

// Transient hint, or low urgency without resident: never stored (ADR-0004).
function shouldPersist(entry) {
    if (entry.transient)
        return false;
    if (entry.urgency === 0 && !entry.resident)
        return false;
    return true;
}

// Newest first. Drops entries older than 7 days (relative to now) and anything beyond 200.
function prune(entries, now, maxAgeMs) {
    const maxAge = maxAgeMs > 0 ? maxAgeMs : MAX_AGE_MS;
    const kept = entries.filter(e => typeof e.time === "number" && now - e.time <= maxAge);
    kept.sort((a, b) => b.time - a.time);
    return kept.slice(0, MAX_ENTRIES);
}

// `entries` (newest first, already pruned) with `entry` on top, pruned like prune() but in
// O(dropped): only the tail can fall out. Falls back to prune() when `entry` is not the newest.
function pushNewest(entries, entry, now, maxAgeMs) {
    const maxAge = maxAgeMs > 0 ? maxAgeMs : MAX_AGE_MS;
    if (typeof entry.time !== "number" || (entries.length > 0 && entry.time < entries[0].time))
        return prune([entry].concat(entries), now, maxAgeMs);
    const list = [entry].concat(entries);
    while (list.length > MAX_ENTRIES || (list.length > 0 && now - list[list.length - 1].time > maxAge))
        list.pop();
    return list;
}

// JSON for notifications.json: persistable entries only, actions as labels, no images.
// `opts` (GF-113, all optional): maxAgeMs, how long entries stay on disk (absent: 7 days); keep: false writes no
// entry at all; textKept(appName) returning false drops the title, the body and the action labels of that app's entries
// (previews are Never for it: the text is never shown, so it is not kept at rest either; app name, icon and time stay).
function serialize(entries, now, opts) {
    const o = opts || {};
    const textKept = typeof o.textKept === "function" ? o.textKept : () => true;
    const stored = (o.keep === false ? [] : prune(entries.filter(shouldPersist), now, o.maxAgeMs)).map(e => ({
        key: e.key,
        appName: e.appName,
        appIcon: e.appIcon,
        summary: textKept(e.appName) ? e.summary : "",
        body: textKept(e.appName) ? e.body : "",
        time: e.time,
        urgency: e.urgency,
        actions: textKept(e.appName) ? (e.actions || []).map(a => a.text) : []
    }));
    return JSON.stringify({version: FORMAT_VERSION, notifications: stored}, null, 1) + "\n";
}

// What the file holds (GF-113, review): {status, entries}. "empty": nothing stored yet (a new file). "ok": entries read, in
// the order of prune(). "future": a version newer than this build writes: the file is read only here and is never rewritten,
// so a downgrade cannot destroy it. "corrupt": not JSON, not this format, or a version that never existed: the caller moves it
// aside before it writes a fresh one, so nothing is lost silently.
function inspect(text, now, maxAgeMs) {
    if (typeof text !== "string" || text.trim() === "")
        return {status: "empty", entries: []};
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return {status: "corrupt", entries: []};
    }
    if (!data || typeof data !== "object" || typeof data.version !== "number" || !Number.isInteger(data.version) || data.version < 1)
        return {status: "corrupt", entries: []};
    if (data.version > FORMAT_VERSION)
        return {status: "future", entries: []};
    if (!Array.isArray(data.notifications))
        return {status: "corrupt", entries: []};
    return {status: "ok", entries: parse(text, now, maxAgeMs)};
}

function str(value) {
    return typeof value === "string" ? value : "";
}

// Parses the file. Corrupt or foreign data yields []. Restored entries are non-actionable: their
// actions keep the label only (empty id) and nid is -1.
function parse(text, now, maxAgeMs) {
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return [];
    }
    if (!data || data.version !== FORMAT_VERSION || !Array.isArray(data.notifications))
        return [];
    const entries = [];
    for (const raw of data.notifications) {
        if (!raw || typeof raw.time !== "number")
            continue;
        entries.push({
            key: str(raw.key) !== "" ? str(raw.key) : "restored-" + entries.length,
            nid: -1,
            appName: str(raw.appName),
            appIcon: keptAppIcon(str(raw.appIcon)),
            summary: str(raw.summary),
            body: str(raw.body),
            time: raw.time,
            urgency: raw.urgency === 0 || raw.urgency === 2 ? raw.urgency : 1,
            transient: false,
            resident: false,
            actions: Array.isArray(raw.actions) ? raw.actions.filter(a => typeof a === "string").map(a => ({id: "", text: a})) : [],
            restored: true
        });
    }
    return prune(entries, now, maxAgeMs);
}

// Group key: the app name ("" for senders without one; the UI shows a translated label).
function groupName(entry) {
    return entry.appName;
}

// Groups by app, newest group first, items newest first: [{appName, appIcon, latest, items}].
function group(entries) {
    // No prototype: an app may be named "constructor" or "__proto__" (audit B-04).
    const byApp = Object.create(null);
    const order = [];
    const sorted = entries.slice().sort((a, b) => b.time - a.time);
    for (const e of sorted) {
        const name = groupName(e);
        if (!byApp[name]) {
            byApp[name] = {appName: name, appIcon: e.appIcon, latest: e.time, items: []};
            order.push(name);
        }
        byApp[name].items.push(e);
        if (byApp[name].appIcon === "" && e.appIcon !== "")
            byApp[name].appIcon = e.appIcon;
    }
    return order.map(n => byApp[n]);
}

function removeKey(entries, key) {
    return entries.filter(e => e.key !== key);
}

function removeApp(entries, appName) {
    return entries.filter(e => groupName(e) !== appName);
}

// Age as {unit: "now"|"m"|"h"|"d", n}; the UI turns it into translated text.
function relativeParts(time, now) {
    const seconds = Math.max(0, Math.floor((now - time) / 1000));
    if (seconds < 60)
        return {unit: "now", n: 0};
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60)
        return {unit: "m", n: minutes};
    const hours = Math.floor(minutes / 60);
    if (hours < 24)
        return {unit: "h", n: hours};
    return {unit: "d", n: Math.floor(hours / 24)};
}

// Banner timeout in ms (spec N2): critical never expires; expire_timeout 0 never; negative = default.
// expireMs is Quickshell's Notification.expireTimeout, which is in MILLISECONDS (the D-Bus
// expire_timeout unit; verified with `notify-send -t 2000`).
// A positive timeout is never shorter than MIN_BANNER_MS: a banner asked for 1 ms would leave before it has slid in.
const MIN_BANNER_MS = 1500;

function bannerTimeout(urgency, expireMs, defaultMs) {
    if (urgency === 2)
        return 0;
    if (expireMs === 0)
        return 0;
    if (expireMs > 0)
        return Math.max(MIN_BANNER_MS, Math.round(expireMs));
    return defaultMs;
}

// The longest title, app name and action label kept, and the longest body kept (the sanitizer's own limit): a sender may
// send megabytes, and every kept text is laid out, read to assistive technology and written to the history file.
const MAX_LINE = 512;
const MAX_BODY = 4000;

// `text` cut to `max` UTF-16 units, never between the two halves of a surrogate pair. Anything but a string is returned as it is.
function bounded(text, max) {
    if (typeof text !== "string" || text.length <= max)
        return text;
    const last = text.charCodeAt(max - 1);
    return text.slice(0, last >= 0xD800 && last <= 0xDBFF ? max - 1 : max);
}

// Longest image reference considered (a path or URL; Quickshell's own references are far shorter).
const MAX_IMAGE_REF = 4096;

// The images a notification may show (GF-AUDIT-001 GF-114, DT-07; macOS model: a notification shows the app's icon or an
// image the app attached, never a picture fetched from somewhere). Accepted, as given:
//   "file"     a local file: an absolute path ("/…", not "//…"), a file: URL without a host or with "localhost", and
//              Quickshell's image://icon//<absolute path> (an app_icon path);
//   "attached" Quickshell's in-memory copy of the image data the app sent (image://qsimage/…, the image-data hint);
//   "themed"   a theme icon name (Quickshell's image://icon/<name>): `name` is decoded, the caller asks the theme.
// "refused" for everything else: http:, https:, ftp:, data: (also an image-path hint's data URI), qrc:, other image
// providers, relative paths, a file: URL naming another host, a malformed name, an oversized reference, control
// characters. So a notification can never make the shell fetch anything. "none" for an empty or non-string value.
// Returns {kind, source (what to load; "" unless file, attached or themed), name (themed only)}.
function imageRef(image) {
    if (typeof image !== "string" || image === "")
        return {kind: "none", source: "", name: ""};
    const refused = {kind: "refused", source: "", name: ""};
    if (image.length > MAX_IMAGE_REF || /[\u0000-\u001f\u007f]/.test(image))
        return refused;
    if (image.startsWith("/"))
        return image.startsWith("//") ? refused : {kind: "file", source: image, name: ""};
    const lower = image.toLowerCase();
    if (lower.startsWith("image://icon//"))
        return image.length > 14 && image[14] !== "/" ? {kind: "file", source: image, name: ""} : refused;
    if (lower.startsWith("image://qsimage/"))
        return {kind: "attached", source: image, name: ""};
    if (lower.startsWith("image://icon/")) {
        const raw = image.slice(13);
        if (raw === "" || raw.indexOf("?") >= 0 || raw.indexOf("#") >= 0)
            return refused;
        let name = "";
        try {
            name = decodeURIComponent(raw);
        } catch (e) {
            return refused;
        }
        return safeIconName(name) !== "" ? {kind: "themed", source: image, name: name} : refused;
    }
    // file:/path, file:///path, file://localhost/path (case-insensitive scheme and host); never another host.
    if (/^file:(?:\/\/(?:localhost)?)?\/[^/]/i.test(image))
        return {kind: "file", source: image, name: ""};
    return refused;
}

// A plain icon-theme name (review of 6e24d36; macOS model: a notification shows its app's icon, never a file the sender
// names). Qt resolves a name through the theme AND its fallback directories (/usr/share/pixmaps): a name like
// "../../../dir/evil" reached any file, a FIFO included, which stalled the one image loader. "" for anything else: the
// generic notification icon is shown. The rule itself is NotificationPrefs.safeIconName (Grassfield.Ui), the one test
// shared with the previews-hidden icon rule (NotificationPrefs.appIconShown). Without it (a Grassfield.Ui that lacks the
// function), no name: the generic icon, never an unchecked name and never a throw at intake.
function safeIconName(name) {
    try {
        return Ui.NotificationPrefs.safeIconName(name);
    } catch (e) {
        return "";
    }
}

// An app_icon as kept (intake, history load): a path or file: URL that localPathOf accepts (shown only as a private
// copy), else a safeIconName, else "".
function keptAppIcon(icon) {
    if (typeof icon !== "string" || icon === "")
        return "";
    if (icon.startsWith("/") || icon.toLowerCase().startsWith("file:"))
        return localPathOf(icon) !== "" ? icon : "";
    return safeIconName(icon);
}

// Largest local image file a notification may show (review of 8b2a710: only regular files, bounded). Shown files are COPIED
// into the shell's private directory first (Notifications.requestCopy), so this also bounds that directory.
const MAX_IMAGE_FILE_BYTES = 8 * 1024 * 1024;

// A plain absolute path the copy helper may read: "/" then segments, no "//", no "." or ".." segment, no control
// character, and none of "?", "#", "%" (review of beebaff: in a URL Qt reads them as query, fragment and escapes, so the
// checked file and the loaded file could differ; the copy design never hands the path to Qt, but such names are refused
// all the same).
function plainPath(path) {
    if (typeof path !== "string" || !path.startsWith("/") || path.length > 4096)
        return false;
    if (/[\u0000-\u001f\u007f?#%]/.test(path) || path.indexOf("//") >= 0)
        return false;
    const parts = path.split("/").slice(1);
    return parts.every(seg => seg !== "." && seg !== "..") && parts[parts.length - 1] !== "";
}

// The local path a "file" image reference (imageRef) or an app icon path names: "/abs" as given, Quickshell's
// image://icon//abs -> "/abs", a file: URL without query or fragment, decoded. "" unless the result is a plainPath. The
// shell never loads that path: it shows a PNG made by a helper that opened it safely, checked the opened descriptor is a
// regular file of at most MAX_IMAGE_FILE_BYTES and re-encoded it (Notifications.requestCopy; a FIFO or a device would
// block the one image loader for good, a file swapped after a check would be another file, and an SVG may name others).
function localPathOf(source) {
    if (typeof source !== "string" || source === "")
        return "";
    let path = "";
    if (source.startsWith("/")) {
        path = source;
    } else if (source.toLowerCase().startsWith("image://icon//")) {
        path = source.slice(13);
    } else {
        const m = /^file:(?:\/\/(?:localhost)?)?(\/[^/?#][^?#]*)$/i.exec(source);
        if (!m)
            return "";
        try {
            path = decodeURIComponent(m[1]);
        } catch (e) {
            return "";
        }
    }
    return plainPath(path) ? path : "";
}

// The file: URL of private copy number `n` of sender number `sender` ("<n>.<sender>.png", a PNG the shell made) in
// directory `dir` (an absolute path), every segment percent-encoded: what the Image loads names exactly that file. "" when
// the directory is not a plain absolute path, `n` is not a positive integer or `sender` not a non-negative one.
function copySource(dir, n, sender) {
    if (!plainPath(dir) || !Number.isInteger(n) || n <= 0 || !Number.isInteger(sender) || sender < 0)
        return "";
    return "file://" + (dir + "/" + n + "." + sender + ".png").split("/").map(encodeURIComponent).join("/");
}

// The URL scheme of a refused image, for a log line that never repeats the reference itself ("" when there is none).
function imageScheme(image) {
    const m = /^([A-Za-z][A-Za-z0-9+.-]{0,15}):/.exec(typeof image === "string" ? image : "");
    return m ? m[1].toLowerCase() : "";
}
