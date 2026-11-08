.pragma library
.import "../platform/QuickLook.js" as QuickLook

// Dock model (pure, unit-tested): merges pinned apps with running apps.
//
// pinned:   array of desktop entry ids (order is the user's order)
// running:  array of {appId, ref} (one per window; ref is the toplevel handle)
// lookup:   function(id) -> {id, name, icon, ...} or null (desktop entry resolution)
//
// Result items: {kind: "app", key, name, icon, entry, windows: [ref...], pinned}
//               {kind: "separator"} and {kind: "trash"} are appended by withTail().

function merge(pinned, running, lookup) {
    const list = [];
    const byKey = {};
    const pins = pinned ? pinned : [];
    for (let i = 0; i < pins.length; i++) {
        const entry = lookup(pins[i]);
        if (!entry || byKey[entry.id] !== undefined)
            continue;
        byKey[entry.id] = list.length;
        list.push({kind: "app", key: entry.id, name: entry.name, icon: entry.icon, entry: entry, windows: [], pinned: true});
    }
    for (let j = 0; j < running.length; j++) {
        const win = running[j];
        // A Quick Look window (Glance) is the opening app's, never a tile of its own (macOS), nor an app of the switcher.
        if (!win.appId || QuickLook.isQuickLook(win.appId))
            continue;
        const entry = lookup(win.appId);
        const key = entry ? entry.id : win.appId;
        if (byKey[key] === undefined) {
            byKey[key] = list.length;
            list.push({kind: "app", key: key, name: entry ? entry.name : win.appId, icon: entry ? entry.icon : win.appId,
                entry: entry, windows: [], pinned: false});
        }
        list[byKey[key]].windows.push(win.ref);
    }
    return list;
}

// Minimized windows as tiles: {kind: "minimized", key, name, icon, appId, toplevel}.
// records: [{toplevel, address, appId, title}] (platform/Minimized.js); lookup resolves desktop entries.
function minimizedItems(records, lookup) {
    return (records ? records : []).map(r => {
        const entry = lookup(r.appId);
        const app = entry ? entry.name : r.appId;
        return {
            kind: "minimized",
            key: "min:" + r.address,
            name: r.title ? r.title : app,
            appName: app,
            icon: entry ? entry.icon : r.appId,
            appId: r.appId,
            toplevel: r.toplevel
        };
    });
}

// Folder stacks as tiles: {kind: "folder", key: path, name, path}. `paths` are clean absolute paths (Stacks.folderList).
function folderItems(paths) {
    return (paths ? paths : []).map(p => ({kind: "folder", key: p, name: p.replace(/\/+$/, "").replace(/^.*\//, "") || "/", path: p}));
}

// Apps, a separator, the folder stacks (macOS: right section, left of the minimized windows), minimized windows, then the trash.
function withTail(apps, minimized, folders) {
    return apps.concat([{kind: "separator"}], folders ? folders : [], minimized ? minimized : [], [{kind: "trash"}]);
}

// The fixed first tile, "Apps" (macOS 26: Launchpad became Apps and keeps its Dock tile). Not an app: never pinned,
// dragged, removed or counted by the drag and reorder logic (they filter on kind "app").
function withApps(items) {
    return [{kind: "apps", key: "grid"}].concat(items);
}

// ---- The fixed Files tile (macOS: the Finder is always the first tile and cannot be removed) ----

// Desktop entry id of Grassfield Files.
const FILES_ID = "org.grassfield.Files";

// Default pinned list of the first releases: it reads as the current default (the shell store applies the same rule).
const OLD_DEFAULT_PINNED = ["foot", "chromium", "org.gnome.Nautilus"];
const DEFAULT_PINNED = ["chromium", "foot", "org.grassfield.Settings"];

// Pinned list as the Dock reads it: the old default list becomes the new default, any other list is left as it is.
function migratePinned(pinned) {
    const list = pinned ? pinned : [];
    return list.length === OLD_DEFAULT_PINNED.length && list.every((id, i) => id === OLD_DEFAULT_PINNED[i]) ? DEFAULT_PINNED.slice() : list;
}

// True for the id of Grassfield Files, with or without the ".desktop" suffix and whatever its case: ids compare as the entry
// lookup and windowsOf compare them, so a stored "ORG.grassfield.Files" is the fixed tile, never a second one (review of
// PR #53).
function isFilesId(id) {
    const s = String(id === undefined || id === null ? "" : id).replace(/\.desktop$/i, "");
    return s.toLowerCase() === FILES_ID.toLowerCase();
}

// The pinned list without Files: its tile is fixed, a stored id would only make a second tile.
function withoutFiles(pinned) {
    return (pinned ? pinned : []).filter(id => !isFilesId(id));
}

// Splits the merged apps into the fixed Files tile and the rest. The tile is {kind: "files", key: "files", name, icon,
// entry, windows, pinned: true, fixed: true}: it carries the windows of Files (the running dot, minimize into the tile,
// Show All Windows), always draws our own icon (an installed older desktop entry may still name a generic one) and exists even when the desktop entry is missing (entry null: a click then opens the home folder
// through the open policy). `lookup` resolves desktop entries.
function splitFiles(apps, lookup) {
    const entry = lookup ? lookup(FILES_ID) : null;
    const rest = [];
    let windows = [];
    for (const a of apps) {
        if (a.kind === "app" && (isFilesId(a.key) || (a.entry && isFilesId(a.entry.id)))) {
            windows = windows.concat(a.windows);
            continue;
        }
        rest.push(a);
    }
    const files = {kind: "files", key: "files", name: entry && entry.name ? entry.name : "Files",
        icon: "org.grassfield.Files", entry: entry ? entry : null, windows: windows, pinned: true, fixed: true};
    return {files: files, rest: rest};
}

// The windows of an app's tile, found by the app's desktop id (the fixed Files tile by Files' id), [] when the Dock has no
// tile for it: what `qs ipc call dock reopen <id>` brings forward when a running app is launched again (ADR-0038 AD34). Ids
// compare without case and without ".desktop", as the entry lookup does.
function windowsOf(items, appId) {
    const norm = id => String(id === undefined || id === null ? "" : id).replace(/\.desktop$/i, "").toLowerCase();
    const want = norm(appId);
    if (want === "")
        return [];
    for (const it of items ? items : []) {
        if (it.kind === "files" && want === norm(FILES_ID))
            return it.windows;
        if (it.kind === "app" && (norm(it.key) === want || (it.entry && norm(it.entry.id) === want)))
            return it.windows;
    }
    return [];
}

// The two fixed tiles, Files then Apps, before everything else.
function withFixed(files, items) {
    return [files, {kind: "apps", key: "grid"}].concat(items);
}

// One spelling of a desktop id for pin, match and remove: without ".desktop", case-folded (the entry lookup and windowsOf
// compare the same way), so "Foot", "foot.desktop" and "foot" are one app whichever of them the file or the tile holds.
function normId(id) {
    return String(id === undefined || id === null ? "" : id).replace(/\.desktop$/i, "").toLowerCase();
}

// The resolved desktop entry id of a stored or tile id, null when nothing resolves. An app is identified by it: the lookup matches
// exactly, then without case (it does not strip ".desktop"), so a stored "foot.desktop" is tried as written and then without the suffix.
function resolvedId(id, lookup) {
    if (!lookup || id === undefined || id === null || id === "")
        return null;
    const entry = lookup(id) || lookup(String(id).replace(/\.desktop$/i, ""));
    return entry && entry.id ? entry.id : null;
}

// True when two ids are the same app: the same resolved entry id (two installed entries that differ only by case stay distinct), or,
// when neither resolves to any entry, the same spelling after normId (cleanup of ids that make no tile: removal only; `strict` compares
// the exact spelling, as pin and cleanPinned do, so such an id never refuses a pin).
function sameApp(a, b, lookup, strict) {
    const ra = resolvedId(a, lookup);
    const rb = resolvedId(b, lookup);
    if (ra !== null && rb !== null)
        return ra === rb;
    if (ra !== null || rb !== null)
        return false;
    return strict === true ? a === b : normId(a) === normId(b);
}

// The stored list cleaned: an id that resolves only in its normalised form is rewritten to the resolved id, then the apps that appear
// twice keep their first place. An id that resolves to nothing stays as it is.
function cleanPinned(pinned, lookup) {
    const out = [];
    for (const p of (pinned ? pinned : [])) {
        const r = resolvedId(p, lookup);
        const id = r !== null ? r : p;
        if (!out.some(q => sameApp(q, id, lookup, true)))
            out.push(id);
    }
    return out;
}

function pin(pinned, id, lookup) {
    const list = cleanPinned(pinned, lookup);
    const r = resolvedId(id, lookup);
    return list.some(p => sameApp(p, id, lookup, true)) ? list : list.concat([r !== null ? r : id]);
}

function unpin(pinned, id) {
    const want = normId(id);
    return (pinned ? pinned : []).filter(p => normId(p) !== want);
}

// Unpin by resolved key: drops every pinned id that is the same app as the key (same resolved entry id), so the pin goes whatever
// spelling the file holds. An emptied list stays empty: nothing here re-seeds the defaults (see migratePinned).
function unpinKey(pinned, key, lookup) {
    return (pinned ? pinned : []).filter(p => !sameApp(p, key, lookup));
}

// Whether a tile can be dragged out of the Dock (macOS): an app kept in the Dock or listed as recent, running or not. A running
// app that is removed keeps its tile (not kept any more) until it quits. Files, Apps, folders, minimized windows and the Trash
// are fixed.
function removable(item) {
    return !!item && item.kind === "app" && item.fixed !== true && (item.pinned === true || item.recent === true);
}

// Dock geometry, the single formula shared by the Dock and by whoever reserves its area (Overview).
// `t` = {iconSize, padding, indicatorSize, spacing, bottomMargin} (the dock tokens).
// macOS: no band under the icons; the running dot sits in the bottom padding (Geometry.dotOrigin).
function shelfHeight(t) {
    return t.iconSize + 2 * t.padding;
}

// Height the Dock takes from the bottom of the output when it is not auto-hidden (its exclusive zone).
function reservedHeight(t, autohide) {
    return autohide ? 0 : shelfHeight(t) + t.bottomMargin;
}

// Whether the Dock hides on an output (the auto-hide machine runs there): the setting (`setting`), an output that does not
// have the Dock (`dockScreen` false: it stays away), a Dock that just moved there (`pending`, until it slid in), or a
// full-screen window or Split View Desktop shown there (`fullscreen`, Compositor.fullscreenOn; ADR-0036 D66, macOS: the Dock
// hides in full screen and comes back at its edge).
function hides(setting, dockScreen, pending, fullscreen) {
    return !!(setting || !dockScreen || pending || fullscreen);
}

// The Dock sits on the overlay layer while a full-screen window is on its output (Hyprland draws full-screen windows above the
// top layer: its edge strip would get no pointer and the shelf would slide in under the window), the top layer otherwise.
function overlayLayer(fullscreen) {
    return !!fullscreen;
}

// ---- Dock fidelity pass ----

// Notification badge of an app tile: the number of notifications (Notifications.history entries, {appName}) whose app
// name is the tile's name or desktop entry id (case-insensitive). Read-only; 0 for tiles that are not apps.
function badgeCount(history, item) {
    if (!item || item.kind !== "app")
        return 0;
    const names = [String(item.name || "").toLowerCase(), String(item.key || "").toLowerCase()].filter(n => n !== "");
    let n = 0;
    for (const e of (history ? history : [])) {
        if (e && names.indexOf(String(e.appName || "").toLowerCase()) >= 0)
            n++;
    }
    return n;
}

// The launcher state (MenuBridge.applyLauncher: lower-case desktop id -> {count?, progress?, urgent}) of an app tile,
// matched on the tile's key or desktop entry id; undefined when the app never set anything.
function launcherOf(launcher, item) {
    if (!launcher || !item || item.kind !== "app")
        return undefined;
    const ids = [String(item.key || "").toLowerCase(), String(item.entry && item.entry.id || "").toLowerCase()];
    for (const id of ids) {
        if (id !== "" && launcher[id] !== undefined)
            return launcher[id];
    }
    return undefined;
}

// The launcher state with a count the shell sets for an app (Software Update's releases on Grassfield Settings, ADR-0033
// U18): above 0 it is that app's own count, kept over what the app set; 0 leaves the state as it is. `id` lower case.
function withCount(launcher, id, count) {
    if (!(count > 0))
        return launcher;
    const out = Object.assign({}, launcher || {});
    out[id] = Object.assign({urgent: false}, out[id] || {}, {count: count});
    return out;
}

// Whether a tile is this app (its tile key or desktop entry id, whatever the case).
function isApp(item, id) {
    return !!item && item.kind === "app" && [String(item.key || "").toLowerCase(), String(item.entry && item.entry.id || "").toLowerCase()].indexOf(id) >= 0;
}

// Badge of an app tile: the count the app set itself when it did (macOS: the app is authoritative, 0 hides the badge),
// else the number of its notifications.
function tileBadge(history, item, launcher) {
    const own = launcherOf(launcher, item);
    if (own && Number.isInteger(own.count))
        return own.count;
    return badgeCount(history, item);
}

// Progress an app set on its tile: 0..1, or -1 for no bar.
function tileProgress(launcher, item) {
    const own = launcherOf(launcher, item);
    return own && typeof own.progress === "number" && own.progress >= 0 && own.progress <= 1 ? own.progress : -1;
}

// Badge text: "" for none, the number up to 99, then "99+".
function badgeText(count) {
    return count <= 0 ? "" : (count > 99 ? "99+" : String(count));
}

// Recently launched apps, newest first, without duplicates, at most `max`.
function pushRecent(recent, id, max) {
    const list = [id].concat((recent ? recent : []).filter(r => r !== id));
    return list.slice(0, max);
}

// Recent applications update (idempotent): the apps that were running (`previous`, keys) and are not any more (`now`,
// keys) and that are not kept in the Dock (`pinned`, keys) go to the front of `recent`, newest first, at most `max`.
// A function of the two running sets and the old list only: an app that is still running is never added (it shows as a
// running tile), so the cap evicting a key can not make it "new" again, and an unchanged running set returns `recent`.
function recentsAfter(recent, previous, now, pinned, max) {
    const nowSet = {};
    (now ? now : []).forEach(k => {
        nowSet[k] = true;
    });
    const kept = {};
    (pinned ? pinned : []).forEach(k => {
        kept[k] = true;
    });
    let list = (recent ? recent : []).slice(0, max);
    for (const key of (previous ? previous : [])) {
        if (nowSet[key] || kept[key])
            continue;
        list = pushRecent(list, key, max);
    }
    return list;
}

// One rebuild step of the recent list: until the desktop entries and the hidden-entry list (OnlyShowIn / NotShowIn) are
// loaded (`ready` false) nothing is evaluated, because an app that looks listed now may turn out hidden (or unresolved) a
// moment later and would then count as "quit". Returns {recent, previous}: the list to keep and the running set to
// remember (null while not ready: the first ready rebuild only records the running set, like a shell restart).
function recentsStep(ready, recent, previous, now, pinned, max) {
    if (!ready)
        return {recent: recent ? recent : [], previous: null};
    return {recent: recentsAfter(recent, previous, now, pinned, max), previous: now};
}

// Recent apps that are neither pinned nor running, resolved through `lookup`, appended to the app list
// ({kind: "app", recent: true, windows: [], pinned: false}). `apps` is the result of merge(). `listed` (optional) is a
// predicate on the desktop entry: NoDisplay / hidden entries are never shown as recents.
function withRecents(apps, recent, lookup, max, listed) {
    const have = {};
    apps.forEach(a => {
        have[a.key] = true;
    });
    const out = apps.slice();
    let added = 0;
    for (const id of (recent ? recent : [])) {
        if (added >= max)
            break;
        const entry = lookup(id);
        if (!entry || have[entry.id] || (listed && !listed(entry)))
            continue;
        have[entry.id] = true;
        // macOS: the recent applications are their own section, set off by a divider.
        if (added === 0)
            out.push({kind: "separator", divider: true});
        added++;
        out.push({kind: "app", key: entry.id, name: entry.name, icon: entry.icon, entry: entry, windows: [], pinned: false, recent: true});
    }
    return out;
}

// Drag to reorder: move the app tile `from` to slot `to` (indices in the app list, the first items of `items`).
// Returns {changed, pinned}: the new pinned key list. An unpinned app (running or recent) dropped before a pinned
// one becomes pinned there; dropped after every pinned app it stays as it is (its place follows the launch order).
function reorder(items, from, to) {
    const apps = items.filter(it => it.kind === "app");
    if (from < 0 || from >= apps.length)
        return {changed: false, pinned: apps.filter(a => a.pinned).map(a => a.key)};
    const dest = Math.max(0, Math.min(apps.length - 1, to));
    const moved = apps[from];
    const order = apps.slice();
    order.splice(from, 1);
    order.splice(dest, 0, moved);
    const pinnedBefore = apps.filter(a => a.pinned).map(a => a.key);
    let becomesPinned = moved.pinned;
    if (!moved.pinned) {
        for (let i = dest + 1; i < order.length; i++) {
            if (order[i].pinned)
                becomesPinned = true;
        }
    }
    const pinned = order.filter(a => a.key === moved.key ? becomesPinned : a.pinned).map(a => a.key);
    return {changed: pinned.join("\n") !== pinnedBefore.join("\n"), pinned: pinned};
}

// Item indices of the app tiles (the recent applications divider sits between app tiles).
function appIndices(items) {
    const out = [];
    items.forEach((it, i) => {
        if (it.kind === "app")
            out.push(i);
    });
    return out;
}

// Slot a dragged tile would take: the position in the app list (items at `indices`) whose tile center is nearest to x.
function dropSlot(centers, indices, x) {
    let best = 0;
    let dist = Infinity;
    for (let i = 0; i < indices.length && indices[i] < centers.length; i++) {
        const d = Math.abs(centers[indices[i]] - x);
        if (d < dist) {
            dist = d;
            best = i;
        }
    }
    return best;
}

// A dragged tile that left the shelf by more than `threshold` px (above its top edge) is dropped out of the Dock.
function draggedOut(y, threshold) {
    return y < -threshold;
}

// ---- Files dropped on an app tile ----
// macOS model: a tile accepts a drop only when the app can open that kind of document. Here: the Exec line has a file field
// code (%f %F %u %U, Desktop Entry spec) AND the entry's MimeType matches the type of every dropped file (an entry without
// MimeType accepts nothing).

// Parsed output of dock/mime-data.sh: {entries: {id: [mime]}, suffix: {".ext": [mime]}, names: {"name": [mime]},
// parents: {mime: [mime]}, aliases: {alias: mime}, ready}.
function parseMimeData(text) {
    const out = {entries: {}, suffix: {}, names: {}, parents: {}, aliases: {}, ready: false};
    for (const raw of String(text || "").split("\n")) {
        const f = raw.replace(/\r$/, "").split("\t");
        if (f[0] === "E" && f.length >= 3) {
            out.entries[f[1]] = f[2].split(";").filter(m => m !== "");
        } else if (f[0] === "G" && f.length >= 2) {
            const g = f[1].split(":");
            if (g.length < 3 || g.indexOf("cs", 3) >= 0)
                continue;
            const glob = g[2];
            if (glob.startsWith("*.") && !/[*?\[]/.test(glob.substring(1))) {
                const k = glob.substring(1).toLowerCase();
                (out.suffix[k] = out.suffix[k] || []).push(g[1]);
            } else if (!/[*?\[]/.test(glob)) {
                const k = glob.toLowerCase();
                (out.names[k] = out.names[k] || []).push(g[1]);
            }
        } else if (f[0] === "S" && f.length >= 2) {
            const p = f[1].split(/\s+/);
            if (p.length === 2)
                (out.parents[p[0]] = out.parents[p[0]] || []).push(p[1]);
        } else if (f[0] === "A" && f.length >= 2) {
            const p = f[1].split(/\s+/);
            if (p.length === 2) {
                out.aliases[p[0]] = p[1];
                (out.aliases["<" + p[1]] = out.aliases["<" + p[1]] || []).push(p[0]);
            }
        }
    }
    out.ready = Object.keys(out.suffix).length > 0;
    return out;
}

// MIME types of a file name (by name only, longest matching extension first): the matched types, their parents
// (subclasses; text/* is a subclass of text/plain) and aliases. [] when the name matches no pattern.
function mimeTypesOf(path, data, resolved) {
    const name = String(path).replace(/\/+$/, "").replace(/^.*\//, "").toLowerCase();
    let found = data.names[name] ? data.names[name] : [];
    for (let i = 1; found.length === 0 && i < name.length; i++) {
        if (name[i] === "." && data.suffix[name.substring(i)])
            found = data.suffix[name.substring(i)];
    }
    // A folder is a folder whatever its name ("Photos.png"); for other paths the real type found at drop time
    // (extensionless files, magic) is used only when the name tells nothing.
    if (resolved && typeof resolved[path] === "string" && resolved[path] !== "" && resolved[path] !== "-") {
        if (resolved[path] === "inode/directory" || found.length === 0)
            found = [resolved[path]];
    }
    const all = {};
    const queue = found.slice();
    while (queue.length > 0) {
        const m = queue.shift();
        if (all[m])
            continue;
        all[m] = true;
        (data.parents[m] ? data.parents[m] : []).forEach(x => queue.push(x));
        if (m.startsWith("text/") && m !== "text/plain")
            queue.push("text/plain");
        // Alias -> canonical name, and canonical -> its aliases ("<name" keys).
        if (typeof data.aliases[m] === "string")
            queue.push(data.aliases[m]);
        (data.aliases["<" + m] ? data.aliases["<" + m] : []).forEach(x => queue.push(x));
    }
    return Object.keys(all);
}

// argv of a desktop entry's raw Exec string (Quickshell's `DesktopEntry.execString`), field codes kept: Quickshell's own
// `command` has them stripped, so it cannot say whether the app takes files. Quoting like GLib's Exec parsing: whitespace
// separates arguments, single quotes are literal, double quotes allow \" \` \$ \\, a backslash outside quotes escapes the next
// character. [] for an empty string or an unterminated quote.
function execArgs(execString) {
    const s = String(execString === undefined || execString === null ? "" : execString);
    const out = [];
    let cur = "";
    let started = false;
    let i = 0;
    while (i < s.length) {
        const c = s[i];
        if (c === "'") {
            const end = s.indexOf("'", i + 1);
            if (end < 0)
                return [];
            cur += s.substring(i + 1, end);
            started = true;
            i = end + 1;
        } else if (c === '"') {
            started = true;
            i++;
            let closed = false;
            while (i < s.length) {
                if (s[i] === '"') {
                    closed = true;
                    i++;
                    break;
                }
                if (s[i] === "\\" && i + 1 < s.length && '"`$\\'.indexOf(s[i + 1]) >= 0) {
                    cur += s[i + 1];
                    i += 2;
                } else {
                    cur += s[i];
                    i++;
                }
            }
            if (!closed)
                return [];
        } else if (c === "\\" && i + 1 < s.length) {
            cur += s[i + 1];
            started = true;
            i += 2;
        } else if (c === " " || c === "\t" || c === "\n") {
            if (started)
                out.push(cur);
            cur = "";
            started = false;
            i++;
        } else {
            cur += c;
            started = true;
            i++;
        }
    }
    if (started)
        out.push(cur);
    return out;
}

// argv of an entry with its field codes: from the raw Exec string when the entry has one (Quickshell's DesktopEntry), else
// from `command` (plain objects, tests).
function entryArgs(entry) {
    if (!entry)
        return [];
    return typeof entry.execString === "string" ? execArgs(entry.execString) : Array.from(entry.command || []);
}

// Whether the app of `entry` opens documents at all (macOS lists recent documents only for such apps): its Exec line has a file
// field code (%f %F %u %U).
function opensDocuments(entry) {
    return !!entry && hasFileCode(entryArgs(entry));
}

function hasFileCode(command) {
    return Array.from(command || []).some(a => /%[fFuU]/.test(String(a).replace(/%%/g, "")));
}

// The tile of `entry` ({id, command}) accepts the dropped `paths`: file field code in Exec and, for every file, a MimeType
// of the entry that equals one of the file's types (or matches "type/*").
// `resolved` (optional) maps a path to its real type (dock/file-types.sh). `lenient` (hovering): a path whose type the name
// does not tell (folder, extensionless file) is let through, the drop resolves it and decides.
function acceptsFiles(entry, paths, data, resolved, lenient) {
    if (!entry || !data || !data.ready || !paths || paths.length === 0 || !hasFileCode(entryArgs(entry)))
        return false;
    const declared = data.entries[entry.id];
    if (!declared || declared.length === 0)
        return false;
    return paths.every(p => {
        const types = mimeTypesOf(p, data, resolved);
        if (lenient && types.length === 0)
            return true;
        return types.some(t => declared.some(d => d === t || (d.endsWith("/*") && t.startsWith(d.substring(0, d.length - 1)))));
    });
}

// Verdict of a tile for the hovered or dropped `paths` while their real types (`resolved`, a partial {path: type} map: a
// folder may carry an extension) are being looked up: "no" when the entry can not open a path whose type is known (or
// can open nothing), "pending" when every known path is fine but some are not resolved yet, "yes" when all are fine.
function dropVerdict(entry, paths, data, resolved) {
    if (!entry || !data || !data.ready || !paths || paths.length === 0 || !hasFileCode(entryArgs(entry)))
        return "no";
    const declared = data.entries[entry.id];
    if (!declared || declared.length === 0)
        return "no";
    let pending = false;
    for (const p of paths) {
        if (!resolved || resolved[p] === undefined) {
            pending = true;
            continue;
        }
        const types = mimeTypesOf(p, data, resolved);
        if (!types.some(t => declared.some(d => d === t || (d.endsWith("/*") && t.startsWith(d.substring(0, d.length - 1))))))
            return "no";
    }
    return pending ? "pending" : "yes";
}

// Paths whose real type is not known yet (not in `resolved`).
function unknownPaths(paths, resolved) {
    return Array.from(paths || []).filter(p => !resolved || resolved[p] === undefined);
}

// Paths whose type the file name does not tell (no glob matches: folders, extensionless files): their real type is
// resolved at drop time. [] when the name decides every path.
function unresolvedPaths(paths, data) {
    return Array.from(paths || []).filter(p => data && mimeTypesOf(p, data).length === 0);
}

// {path: type} from the lines printed by dock/file-types.sh for `paths` (same order).
function parseResolved(paths, text) {
    const lines = String(text || "").split("\n");
    const out = {};
    Array.from(paths || []).forEach((p, i) => {
        out[p] = (lines[i] || "-").trim();
    });
    return out;
}

// file:// URI of a local path (%u %U get URIs, %f %F paths).
function fileUri(path) {
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/");
}

// Commands that open `files` (local paths) with an entry command, field codes substituted per the Desktop Entry spec:
// %F %U expand to all files in one command; %f %u (single) give one command per file; other codes are dropped and "%%" is a
// literal percent. [] when the command has no file field code (nothing is ever appended to the command line).
function commandsForFiles(command, files) {
    const list = Array.from(files || []).map(String);
    const args = Array.from(command || []).map(String);
    if (list.length === 0 || !hasFileCode(args))
        return [];
    const build = group => {
        const out = [];
        for (const a of args) {
            if (a === "%F" || a === "%U") {
                group.forEach(f => out.push(a === "%U" ? fileUri(f) : f));
            } else if (/^%[a-zA-Z]$/.test(a) && "fFuU".indexOf(a[1]) < 0) {
                continue;
            } else {
                out.push(a.replace(/%(.)/g, (m, c) => c === "%" ? "%" : (c === "f" || c === "F" ? group[0] : (c === "u" || c === "U" ? fileUri(group[0]) : ""))));
            }
        }
        return out;
    };
    const multi = args.some(a => a === "%F" || a === "%U");
    return multi ? [build(list)] : list.map(f => build([f]));
}

// Launch bounce: tiles that were launched and have no window yet. `launching` maps key -> start (ms); entries older
// than `timeoutMs` or whose app now has a window are dropped.
function bounceKeys(launching, items, now, timeoutMs) {
    const out = {};
    for (const key of Object.keys(launching ? launching : {})) {
        if (now - launching[key] > timeoutMs)
            continue;
        const item = items.find(it => (it.kind === "app" || it.kind === "files") && it.key === key);
        if (!item || item.windows.length > 0)
            continue;
        out[key] = launching[key];
    }
    return out;
}

// ---- Layout transitions ----
// Tiles are rebuilt when apps open, quit or move between sections (an app that quits and is not kept in the Dock leaves the
// app section and joins the recents section after the divider). To keep that from jumping, every rebuild animates the
// tiles from where their key was to where it is now (FLIP): the window records the x of each tile before the rebuild and
// compares it with the new layout.

// Identity of an item across rebuilds.
function tileKey(item) {
    if (!item)
        return "";
    if (item.kind === "separator")
        return item.divider ? "sep:divider" : "sep";
    if (item.kind === "trash")
        return "trash";
    return item.kind + ":" + item.key;
}

// {slide: {key: before - after}, enter: [key]} for two {key: x} maps in the same coordinates: tiles in both that moved by
// more than `min` px start offset by the difference and glide to 0; tiles only in `after` fade in. An empty `before`
// (first build) animates nothing.
function layoutTransition(before, after, min) {
    const slide = {};
    const enter = [];
    const known = Object.keys(before ? before : {}).length > 0;
    if (!known)
        return {slide: slide, enter: enter};
    for (const key of Object.keys(after ? after : {})) {
        if (before[key] === undefined)
            enter.push(key);
        else if (Math.abs(before[key] - after[key]) > min)
            slide[key] = before[key] - after[key];
    }
    return {slide: slide, enter: enter};
}

// ---- Stable tile model ----
// The Dock tiles live in a keyed list model updated by diffing, so a delegate (and its animations) survives a rebuild.

// Steps that turn the key list `from` into `to`: [{op: "remove", at}, {op: "insert", at, key}, {op: "move", from, to}], to be
// applied in order (removals first, so no delegate outlives its key). Keys are meant to be unique; the boundary is safe anyway:
// a repeated key in `from` loses its later rows (removed), and a repeated key in `to` is wanted once (its first place).
function diffKeys(from, to) {
    const target = to.filter((k, i) => to.indexOf(k) === i);
    const want = {};
    target.forEach(k => {
        want[k] = true;
    });
    const list = from.slice();
    const ops = [];
    const seen = {};
    const drop = [];
    list.forEach((k, i) => {
        if (!want[k] || seen[k])
            drop.push(i);
        seen[k] = true;
    });
    for (let d = drop.length - 1; d >= 0; d--) {
        ops.push({op: "remove", at: drop[d]});
        list.splice(drop[d], 1);
    }
    for (let i = 0; i < target.length; i++) {
        if (list[i] === target[i])
            continue;
        const at = list.indexOf(target[i], i + 1);
        if (at >= 0) {
            ops.push({op: "move", from: at, to: i});
            list.splice(i, 0, list.splice(at, 1)[0]);
        } else {
            ops.push({op: "insert", at: i, key: target[i]});
            list.splice(i, 0, target[i]);
        }
    }
    return ops;
}
