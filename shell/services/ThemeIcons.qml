pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.I18n
import Grassfield.Ui
import "../widgets/ArtUrl.js" as ArtUrl // layering-exception: GF-087

// The one way an icon or picture the shell does not own reaches an Image: named by a notification, the polkit sheet, a
// desktop entry, an application, a tray item (StatusNotifierItem) or a file (Notifications, AuthAgent, the Dock, the
// Launchpad, the desktop, Search, the Switcher, the Overview, Stages, Force Quit, About, the menu bar's tray, media art,
// the lock screen's account picture). Integrator decisions after the reviews of 5ee6240 and 423766f: Qt never reads a
// user-writable icon file, and the shell only ever decodes images it produced itself.
//  - Qt's theme and fallback search paths hold only directories the user can neither write nor replace (Grassfield.I18n,
//    ui/i18n/iconsearchpaths.h, applied when that module is imported, before any binding; imported here too so no
//    lookup can come first). A plain theme name is looked up there (Quickshell.hasThemeIcon on the GUI thread reads only
//    root-owned theme files) and shown by its image://icon URL.
//  - Everything else is shown as a PNG the shell made: a name found only in the user's icon folders (a user-installed
//    application, a flatpak user export), an absolute Icon= path, a tray icon from the app's own IconThemePath, a
//    desktop picture's thumbnail, a stack preview, a media art file, the account picture. services/image-copy.py (python3
//    -I, a process of its own, never the GUI thread) finds the file (a plain lookup: theme directory x size folder x
//    apps|status|mimetypes|places|devices x png|svg, hicolor first, then pixmaps; no index.theme), opens it safely
//    (real path under an allowed root, O_NOFOLLOW|O_NONBLOCK, fstat: a regular file within the size cap) and re-encodes
//    it with rsvg-convert, fed on stdin (no base URL: no reference to another file is ever followed), into
//    $XDG_RUNTIME_DIR/grassfield-icons-<display>/<n>.png (0700, emptied at start, maxCopyBytes in all, the least
//    recently used copies deleted to make room). The Image loads only that PNG, asynchronously. Anything else (refused,
//    not made yet): the caller's generic icon.
// Media art named by an https URL (macOS shows the artwork apps provide; Spotify and browsers name https URLs) is fetched
// by the same helper (curl, https only, public addresses only, 5 MiB, 5 s, no cookies or credentials) and re-encoded like
// a file; one URL key per address, in the same budget and least-recently-used order. Only the newest asked URL is fetched
// (older queued ones are forgotten, asked again if still shown). No fetch starts while the session is locked, and a run
// fetching art when it locks is stopped (its items wait for the unlock): then only art already made shows. A URL that
// fails is asked again after retryDelaysMs (60 s, then 10 min) while still shown, then no more this session.
// The copy directory belongs to the user, like every file of the session: a process of the same user can replace a copy,
// as it could the shell's own QML. The copies protect against what applications NAME (a path, a theme file, a FIFO, an
// SVG with references), not against code already running as the user.
// A copy is made once per run (a new notification naming the icon, or a new media art, makes a new one); until then, and
// when refused, the fallback shows. A helper that hangs is stopped (TERM, then KILL) and its keys refused.
Singleton {
    id: root

    readonly property real maxIconBytes: 8 * 1024 * 1024
    // A picture's source file (a photo may be big); its copy is at most 256 x 256 pixels like any other.
    readonly property real maxPictureBytes: 16 * 1024 * 1024
    // All copies together; past it, the least recently used are deleted to make room.
    readonly property real maxCopyBytes: 128 * 1024 * 1024
    // Past this many keys the least recently used quarter is forgotten (and its copies deleted).
    readonly property int maxKeys: 4096
    readonly property int batchSize: 24
    readonly property string helperPath: Quickshell.shellPath("services/image-copy.py")
    // One directory per Wayland display: a nested dev shell never empties the real session's.
    readonly property string copyDir: {
        const runtime = Quickshell.env("XDG_RUNTIME_DIR");
        const display = String(Quickshell.env("WAYLAND_DISPLAY") || "none").replace(/[^A-Za-z0-9._-]/g, "_");
        return runtime ? runtime + "/grassfield-icons-" + display : "";
    }
    property bool copyDirReady: false
    // Key ("name:<theme name>", "icon:<path>", "picture:<path>", "tray:<name>|<IconThemePath>") -> {state: "pending" |
    // "ok" | "no", url, file}; reassigned on every change (setCopies), for the code that reads the whole map.
    property var copies: ({})
    // The same map as the views read it (copyOf, fileState, artSource): through `held`, a constant holder, so a view does not
    // depend on the map as a whole, only on the revision of its key's bucket (`buckets`: 32 revisions, a key's hash picks
    // one). A copy made (a helper batch, an ask) re-evaluates the views of the keys it changed and of their bucket's
    // neighbours, not every icon binding of the shell (audit fluidity note: each track change of the media art, each batch,
    // re-evaluated every icon of the Dock, Launchpad, menu bar, notifications ...).
    readonly property var held: ({map: {}})
    QtObject {
        id: buckets
        property int b0: 0
        property int b1: 0
        property int b2: 0
        property int b3: 0
        property int b4: 0
        property int b5: 0
        property int b6: 0
        property int b7: 0
        property int b8: 0
        property int b9: 0
        property int b10: 0
        property int b11: 0
        property int b12: 0
        property int b13: 0
        property int b14: 0
        property int b15: 0
        property int b16: 0
        property int b17: 0
        property int b18: 0
        property int b19: 0
        property int b20: 0
        property int b21: 0
        property int b22: 0
        property int b23: 0
        property int b24: 0
        property int b25: 0
        property int b26: 0
        property int b27: 0
        property int b28: 0
        property int b29: 0
        property int b30: 0
        property int b31: 0
    }
    // The bucket revisions moved (tests).
    property int bucketMoves: 0

    function bucketOf(key: string): string {
        let h = 0;
        for (let i = 0; i < key.length; i++)
            h = (h * 31 + key.charCodeAt(i)) | 0;
        return "b" + ((h >>> 0) % 32);
    }

    // The entry of `key` as a view reads it: the view depends on the key's bucket only.
    function entryOf(key: string): var {
        void buckets[root.bucketOf(key)];
        return root.held.map[key];
    }

    // The new map: the buckets of the keys whose entry changed (added, replaced, removed) move.
    function setCopies(next: var): void {
        const old = root.held.map;
        const moved = {};
        for (const key in old) {
            if (old[key] !== next[key])
                moved[root.bucketOf(key)] = true;
        }
        for (const key in next) {
            if (!(key in old))
                moved[root.bucketOf(key)] = true;
        }
        root.held.map = next;
        root.copies = next;
        for (const b in moved) {
            buckets[b] = buckets[b] + 1;
            root.bucketMoves++;
        }
    }
    // The least-recently-used order: at[key] is the value of `tick` at the key's last use. Mutated in place, never
    // reassigned: a use (a binding asking) notifies nobody.
    readonly property var lru: ({tick: 0, at: {}})
    property var queue: []
    property var batch: []
    // Copies replaced by a newer one or forgotten, deleted by the next helper run.
    property var dropped: []
    property int counter: 0
    property var activeRun: null
    // Keys asked by bindings during this event-loop turn, requested together by flushAsks (Qt.callLater runs a function
    // once per turn with the last arguments, so asking per key would request only the last). Mutated in place.
    readonly property var asks: ({list: []})
    // Art URL retries after a failure: the delays (a test may shorten them), in ticks of retryTickMs; key -> {tries, left,
    // idle}. Mutated in place. At most maxRetries entries (the oldest goes first); an entry leaves on success, after the
    // last try (the "no" entry in `copies` then keeps the URL from being fetched again), when no view asked for its due
    // retry within retryIdleTicks ticks (no longer shown: forgotten, asked afresh if shown again), and with its key.
    property var retryDelaysMs: [60000, 600000]
    property int retryTickMs: 5000
    property int maxRetries: 256
    readonly property int retryIdleTicks: 2
    readonly property var retries: ({})

    // An absolute icon path (Icon=/path, file:///path) as a plain path, or "": no control character, at most 4096 characters.
    function plainIconPath(icon: string): string {
        let path = String(icon || "");
        if (path.toLowerCase().startsWith("file://")) {
            try {
                path = decodeURIComponent(path.slice(7));
            } catch (e) {
                return "";
            }
        }
        return path.startsWith("/") && path.length <= 4096 && !/[\u0000-\u001f\u007f]/.test(path) ? path : "";
    }

    // The image URL for theme icon `name`: the system theme's (only root-owned directories are searched), else the copy
    // of the user's icon of that name (a copy is requested; "" until it exists or when there is none).
    function source(name: string): string {
        const safe = NotificationPrefs.safeIconName(name);
        if (safe === "")
            return "";
        if (Quickshell.hasThemeIcon(safe))
            return Quickshell.iconPath(safe);
        return copyOf("name", safe);
    }

    // The copy of picture file `icon` (an absolute path or file: URL), "" until it exists or when refused.
    function fileSource(icon: string): string {
        const path = plainIconPath(icon);
        return path !== "" ? copyOf("picture", path) : "";
    }

    // "pending", "ok" or "no" for picture file `icon` (fileSource's), "" when never asked.
    function fileState(icon: string): string {
        const entry = entryOf("picture:" + plainIconPath(icon));
        return entry === undefined ? "" : entry.state;
    }

    // Picture file `icon` may have new content (a player reuses its art file): a new copy is made, the old one shown
    // until then.
    function refreshFile(icon: string): void {
        const path = plainIconPath(icon);
        if (path !== "")
            request("picture", path, true);
    }

    // An icon from a desktop entry, an application or a file (Icon=: a theme name or an absolute path), as
    // Quickshell.iconPath(icon, fallback) gave it: the system theme's icon or the copy of the user's; until then, and when
    // there is none or it is refused, the fallback theme icon.
    function appIcon(icon: string, fallback: string): string {
        const value = String(icon || "");
        const path = plainIconPath(value);
        const own = path !== "" ? copyOf("icon", path) : (value !== "" ? source(value) : "");
        return own !== "" ? own : (fallback !== "" ? source(fallback) : "");
    }

    // A tray item's icon (Quickshell's SystemTrayItem.icon). Quickshell would resolve an app's IconThemePath and a
    // path-like IconName itself, reading whatever file they name (review of 423766f): only its pixmap images
    // (image://qspixmap/, the IconPixmap pixels the app sent) pass as they are. From image://icon/<name>[?path=<dir>]
    // only a plain theme name is kept: the system theme's icon, else a copy made by the helper from the app's own folder
    // (a user-writable directory like any other), then from the user's icon folders. Anything else: "" (no icon).
    function trayIcon(icon: string): string {
        const value = String(icon || "");
        if (value.startsWith("image://qspixmap/"))
            return value;
        if (!value.startsWith("image://icon/"))
            return "";
        const rest = value.slice(13);
        const q = rest.indexOf("?");
        const raw = q < 0 ? rest : rest.slice(0, q);
        const name = NotificationPrefs.safeIconName(raw);
        if (name === "" || name !== raw)
            return "";
        if (Quickshell.hasThemeIcon(name))
            return Quickshell.iconPath(name);
        const query = q < 0 ? "" : rest.slice(q + 1);
        const dir = query.startsWith("path=") ? query.slice(5).replace(/&fallback=.*$/, "") : "";
        if (dir !== "" && plainIconPath(dir) === dir)
            return copyOf("tray", name + "|" + dir);
        return copyOf("name", name);
    }

    // Media art (Media.artShown): a local file: URL as fileSource, an https URL fetched and re-encoded (ArtUrl.remoteUrl),
    // anything else "". While the session is locked nothing is fetched: only art already made shows.
    function artSource(url: string): string {
        const path = ArtUrl.localPath(url);
        if (path !== "")
            return fileSource(path);
        const remote = ArtUrl.remoteUrl(url);
        if (remote === "" || (SessionState.locked && entryOf("url:" + remote) === undefined))
            return "";
        return copyOf("url", remote);
    }

    // A new notification names `name`: a user icon of that name is copied again (it may have changed); the current copy
    // shows until then.
    function check(name: string, fresh: bool): void {
        const safe = NotificationPrefs.safeIconName(name);
        if (safe === "" || Quickshell.hasThemeIcon(safe))
            return;
        request("name", safe, fresh);
    }

    function copyOf(kind: string, value: string): string {
        const key = kind + ":" + value;
        const entry = entryOf(key);
        if (entry === undefined) {
            asks.list.push([kind, value]);
            Qt.callLater(root.flushAsks);
            return "";
        }
        if (entry.state === "retry") {
            asks.list.push([kind, value]);
            Qt.callLater(root.flushAsks);
            return "";
        }
        if (entry.state !== "ok")
            return "";
        lru.tick++;
        lru.at[key] = lru.tick;
        return entry.url;
    }

    function flushAsks(): void {
        const list = asks.list;
        asks.list = [];
        requestAll(list, false);
    }

    function request(kind: string, value: string, fresh: bool): void {
        requestAll([[kind, value]], fresh);
    }

    // Queues [kind, value] pairs not queued yet (`fresh`: also when already answered), with one change of `copies`.
    function requestAll(pairs: var, fresh: bool): void {
        if (copyDir === "")
            return;
        const added = [];
        let next = null;
        for (const [kind, value] of pairs) {
            const key = kind + ":" + value;
            if (queue.some(q => q.key === key) || batch.some(q => q.key === key) || added.some(q => q.key === key))
                continue;
            const entry = (next || copies)[key];
            if (!fresh && entry !== undefined && entry.state !== "retry")
                continue;
            counter++;
            added.push({key: key, kind: kind, value: value, n: counter});
            // A copy already made stays shown until its replacement is made (or refused): done() drops it then.
            if (entry === undefined || entry.state !== "ok") {
                next = next || Object.assign({}, copies);
                next[key] = {state: "pending", url: "", file: ""};
            }
        }
        if (added.length === 0)
            return;
        queue = queue.concat(added);
        if (next !== null)
            setCopies(Object.keys(next).length > maxKeys ? forget(next) : next);
        run();
    }

    // Past maxKeys keys: the least recently used quarter of the settled keys is forgotten, their copies deleted by the
    // next run (a key asked again is copied again).
    function forget(map: var): var {
        const settled = Object.keys(map).filter(k => map[k].state !== "pending");
        settled.sort((a, b) => (lru.at[a] || 0) - (lru.at[b] || 0));
        const files = [];
        for (const key of settled.slice(0, Math.ceil(maxKeys / 4))) {
            if (map[key].file)
                files.push(map[key].file);
            delete map[key];
            delete lru.at[key];
            delete retries[key];
        }
        dropped = dropped.concat(files);
        return map;
    }

    // The copies the helper may delete to make room, least recently used first.
    function evictable(): var {
        const keys = Object.keys(copies).filter(k => copies[k].state === "ok" && copies[k].file);
        keys.sort((a, b) => (lru.at[a] || 0) - (lru.at[b] || 0));
        return keys.map(k => copies[k].file);
    }

    // One helper run at a time, each its own Process with its batch (Process.running turns true only once started, so two
    // starts in one turn would otherwise both run and the first batch's answer be lost).
    function run(): void {
        if (activeRun !== null || !copyDirReady || queue.length === 0)
            return;
        // Media art over https: only the newest asked URL is fetched; older queued ones are forgotten (asked again while
        // shown). While the session is locked, URLs wait in the queue.
        const urls = queue.filter(q => q.kind === "url");
        if (urls.length > 1) {
            const stale = urls.slice(0, -1);
            queue = queue.filter(q => stale.indexOf(q) < 0);
            const next = Object.assign({}, copies);
            for (const q of stale) {
                if (next[q.key] !== undefined && next[q.key].state === "pending")
                    delete next[q.key];
            }
            setCopies(next);
        }
        const ready = SessionState.locked ? queue.filter(q => q.kind !== "url") : queue;
        if (ready.length === 0)
            return;
        batch = ready.slice(0, batchSize);
        queue = queue.filter(q => batch.indexOf(q) < 0);
        const args = [];
        for (const file of dropped)
            args.push("drop", "0", file);
        dropped = [];
        for (const file of evictable())
            args.push("lru", "0", file);
        for (const q of batch)
            args.push(q.kind, String(q.n), q.value);
        const proc = helperRun.createObject(root, {
            keys: batch.map(q => q.key),
            command: ["timeout", "-k", "2", "60", "setpriv", "--pdeathsig", "KILL", "--", "python3", "-I", helperPath, "batch", copyDir,
                String(maxIconBytes), String(maxPictureBytes), String(maxCopyBytes)].concat(args)
        });
        activeRun = proc;
        // A handler of that change may have stopped the run already (the session locked inside it: review of 684ed6d);
        // then it never starts. Its items are back in the queue (stopArtRun).
        if (activeRun !== proc) {
            proc.destroy();
            return;
        }
        watchdog.restart();
        proc.running = true;
    }

    // A run's answer; one abandoned by the watchdog is dropped (its keys were already refused).
    function runFinished(proc: var, output: string): void {
        if (proc !== activeRun) {
            proc.destroy();
            return;
        }
        activeRun = null;
        watchdog.stop();
        done(proc.keys, output);
        proc.destroy();
    }

    // "ok<TAB><key><TAB><copy>" for each copy made, "gone<TAB><file>" for each copy deleted to make room, "later<TAB><key>"
    // for an item the helper had no time left for (asked again first by the next run); a key with no line is refused.
    function done(keys: var, output: string): void {
        const said = {};
        const gone = {};
        const later = {};
        for (const line of String(output || "").split("\n")) {
            const f = line.split("\t");
            if (f[0] === "ok" && f.length === 3 && f[2].startsWith(copyDir + "/") && /^[0-9]+\.png$/.test(f[2].slice(copyDir.length + 1)))
                said[f[1]] = f[2];
            else if (f[0] === "gone" && f.length === 2)
                gone[f[1]] = true;
            else if (f[0] === "later" && f.length === 2)
                later[f[1]] = true;
        }
        const next = Object.assign({}, copies);
        for (const key in next) {
            if (next[key].file && gone[next[key].file]) {
                delete next[key];
                delete lru.at[key];
            }
        }
        const again = batch.filter(q => later[q.key] && said[q.key] === undefined && next[q.key] !== undefined);
        for (const key of keys) {
            if (again.some(q => q.key === key))
                continue;
            const file = said[key];
            if (next[key] !== undefined && next[key].file)
                dropped = dropped.concat([next[key].file]);
            if (file !== undefined) {
                next[key] = {state: "ok", url: "file://" + file.split("/").map(encodeURIComponent).join("/"), file: file.slice(copyDir.length + 1)};
                delete retries[key];
            } else {
                next[key] = {state: "no", url: "", file: ""};
                console.info("grassfield-icons: no usable image for a " + key.slice(0, key.indexOf(":")) + " request (none found, not a regular file within its size cap, or not an image rsvg-convert could re-encode)");
                if (key.startsWith("url:"))
                    scheduleRetry(key);
            }
        }
        batch = [];
        queue = again.concat(queue);
        setCopies(next);
        Qt.callLater(run);
    }

    // A failed art URL: asked again after the next delay of retryDelaysMs, while still shown; after the last, never again
    // this session.
    function scheduleRetry(key: string): void {
        const r = retries[key] || {tries: 0, left: 0, idle: 0};
        delete retries[key];
        if (r.tries >= retryDelaysMs.length) {
            retryTimer.running = Object.keys(retries).length > 0;
            return;
        }
        r.left = retryDelaysMs[r.tries];
        r.tries++;
        r.idle = 0;
        retries[key] = r; // re-inserted: the newest
        const keys = Object.keys(retries);
        for (let i = 0; i < keys.length - maxRetries; i++)
            delete retries[keys[i]];
        retryTimer.running = Object.keys(retries).length > 0;
    }

    // One tick: a URL whose delay ran out is marked "retry", so the views still showing it ask for it again (copyOf);
    // one that none asks for within retryIdleTicks ticks is forgotten.
    function retryTick(): void {
        let next = null;
        for (const key of Object.keys(retries)) {
            const r = retries[key];
            const entry = copies[key];
            if (r.left > 0) {
                r.left -= retryTickMs;
                if (r.left <= 0 && entry !== undefined && entry.state === "no") {
                    next = next || Object.assign({}, copies);
                    next[key] = {state: "retry", url: "", file: ""};
                }
                continue;
            }
            if (entry === undefined || entry.state !== "retry") {
                if (entry === undefined || entry.state !== "pending")
                    delete retries[key];
                continue;
            }
            r.idle++;
            if (r.idle >= retryIdleTicks) {
                next = next || Object.assign({}, copies);
                delete next[key];
                delete retries[key];
            }
        }
        if (next !== null)
            setCopies(next);
        retryTimer.running = Object.keys(retries).length > 0;
    }

    // The session locks while a run fetches art: the run is stopped (TERM to timeout's process group: python and curl),
    // its items wait in the queue with new numbers, and whatever it wrote is deleted by the next run.
    function stopArtRun(): void {
        const proc = activeRun;
        if (proc === null || !batch.some(q => q.kind === "url"))
            return;
        activeRun = null;
        watchdog.stop();
        // Quickshell only signals a process it reports started: one locked in the turn it was started is stopped as soon
        // as it is (onStarted).
        proc.stopped = true;
        proc.signal(15);
        killer.proc = proc;
        killer.restart();
        const again = batch.map(q => {
            counter++;
            return {key: q.key, kind: q.kind, value: q.value, n: counter};
        });
        dropped = dropped.concat(batch.map(q => q.n + ".png"));
        batch = [];
        queue = again.concat(queue);
        console.info("grassfield-icons: the session locked during an art fetch: stopped, asked again once unlocked");
    }

    Timer {
        id: retryTimer
        interval: root.retryTickMs
        repeat: true
        onTriggered: root.retryTick()
    }

    Component {
        id: helperRun

        Process {
            id: proc
            property var keys: []
            property bool stopped: false
            // Stopped before it started (stopArtRun), or started while the session is locked with art in its batch.
            onStarted: {
                if (proc.stopped || (SessionState.locked && proc.keys.some(k => k.startsWith("url:")))) {
                    if (!proc.stopped && root.activeRun === proc)
                        root.stopArtRun();
                    proc.signal(15);
                }
            }
            stdout: StdioCollector {
                onStreamFinished: root.runFinished(proc, text)
            }
        }
    }

    // A run that does not answer within its own timeout (60 s, KILL 2 s later; the helper itself stops starting items
    // after 20 s) is stopped: TERM, then KILL 2 s later (the
    // helper dies with it: --pdeathsig; rsvg-convert, in timeout's process group, too, and it has its own CPU limit), and
    // its keys are refused.
    Timer {
        id: watchdog
        interval: 70000
        onTriggered: {
            const proc = root.activeRun;
            if (proc === null)
                return;
            root.activeRun = null;
            proc.signal(15);
            killer.proc = proc;
            killer.restart();
            root.done(proc.keys, "");
        }
    }

    Timer {
        id: killer
        property var proc: null
        interval: 2000
        onTriggered: {
            if (proc !== null && proc.running)
                proc.signal(9);
            proc = null;
        }
    }

    // Media art URLs held while the session was locked are fetched once it is unlocked.
    Connections {
        target: SessionState

        function onLockedChanged(): void {
            if (SessionState.locked)
                root.stopArtRun();
            root.run();
        }
    }

    // Empties (and creates, 0700) the private copy directory once at start; copies wait for it.
    Process {
        running: root.copyDir !== ""
        command: ["sh", "-c", "case $1 in /*/grassfield-icons-*) ;; *) exit 1 ;; esac; rm -rf -- \"$1\" && mkdir -m 700 -- \"$1\"", "gf-icons-prepare", root.copyDir]
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.copyDirReady = code === 0;
            if (code !== 0)
                console.warn("grassfield-icons: the private icon directory could not be prepared; user icons are not shown");
            root.run();
        }
    }
}
