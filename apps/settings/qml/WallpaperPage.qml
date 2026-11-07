pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Dialogs
import QtQuick.Effects
import Grassfield.Ui
import "Displays.js" as Displays

// Settings > Wallpaper (ADR-0016) as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Wallpaper): a preview
// of the current wallpaper beside a group with its name, its status and the options that apply to it, then sections of
// thumbnails (the Grassfield artwork, folders and pictures added and the tiles that add them, videos, online, the pictures
// folder, colours). Changes apply at once: the page writes the `wallpaper` keys of grassfield.json
// in one write and the shell follows the file; the shell reports what happened in wallpaper-state.json (read here).
// Pictures are parsed by grassfield-wallpaper only (thumbnails, listing): this page never decodes a file of the user's.
// Online (ADR-0016 step 2): one tile, the Wikimedia Commons Picture of the Day. Choosing it shows what is contacted and asks
// before anything is turned on; then the picture shows with its attribution (Title, Author, Source, Licence, Last updated).
// This page never touches the network: the shell fetches, and reports the state in wallpaper-state.json.
SettingsPage {
    id: root

    required property var store
    required property var backend

    // Screen Saver… asks Main for its sheet (ScreenSaverSheet.qml, ADR-0032).
    signal screenSaverRequested

    title: qsTr("Wallpaper")

    // ---- which display the options are for (ADR-0016 section 8: "Display", shown with more than one output) ----
    // "all" = All Displays (the top-level keys), else a display key (WallpaperConfig.displayKey): its entry of `wallpaper.outputs`
    // overrides the top level for that display only. Every row below reads and writes through `eff` and `setFields`.
    property string displayId: "all"
    // The connected displays: [{key, name, model, serial, label}], read when the page opens and when the file changes.
    property var displays: []
    readonly property var currentDisplay: root.displayId === "all" ? null : (root.displays.find(d => d.key === root.displayId) || null)
    // The whole stored object, as WallpaperConfig reads it.
    readonly property var stored: ({
            source: root.store.value("wallpaper.source"),
            path: root.store.value("wallpaper.path"),
            color: root.store.value("wallpaper.color"),
            fit: root.store.value("wallpaper.fit"),
            interval: root.store.value("wallpaper.interval"),
            shuffle: root.store.value("wallpaper.shuffle"),
            videoOnBattery: root.store.value("wallpaper.videoOnBattery"),
            online: {provider: root.store.value("wallpaper.online.provider")},
            outputs: root.store.value("wallpaper.outputs")
        })
    // The settings that apply to the chosen display (the top level for All Displays).
    readonly property var eff: root.currentDisplay ? WallpaperConfig.resolve(root.stored, root.currentDisplay) : WallpaperConfig.resolve(root.stored, {name: "", model: "", serial: ""})
    // The chosen display has a wallpaper of its own (an entry that chooses a picture, a video, a colour or the artwork; an entry
    // that only sets Fit does not count).
    readonly property bool overridden: root.currentDisplay !== null && WallpaperConfig.sourceOverridden(root.stored.outputs, root.currentDisplay)

    readonly property string source: root.eff.source
    readonly property string path: root.eff.path
    readonly property string color: root.eff.color
    readonly property string fit: root.eff.fit
    readonly property string interval: root.eff.interval
    readonly property bool shuffle: root.eff.shuffle
    readonly property bool videoOnBattery: root.store.value("wallpaper.videoOnBattery")
    readonly property string provider: root.store.value("wallpaper.online.provider")
    // The Grassfield artworks (ADR-0040 step 2): which one the artwork source draws and which variant shows (stored values,
    // normalised: an unknown one reads as the default).
    readonly property var artworkCfg: WallpaperConfig.normalize({artwork: root.store.value("wallpaper.artwork"), artworkVariant: root.store.value("wallpaper.artworkVariant")})
    readonly property string artwork: root.artworkCfg.artwork
    readonly property string artworkVariant: root.artworkCfg.artworkVariant
    // The four artworks, each tile drawn in the current appearance (macOS's dynamic wallpapers show the appearance's look).
    readonly property var artworkModel: [{id: "grassfield", text: qsTr("Grassfield")}, {id: "meadow", text: qsTr("Meadow")}, {id: "rows", text: qsTr("Field Rows")}, {id: "ridgeline", text: qsTr("Ridgeline")}]
    // The choice of variant: Time of Day for the Grassfield artwork only.
    readonly property var variantModel: (root.artwork === "grassfield" ? [{id: "timeOfDay", text: qsTr("Time of Day")}] : []).concat([{id: "automatic", text: qsTr("Automatic")}, {id: "light", text: qsTr("Light")}, {id: "dark", text: qsTr("Dark")}])
    // The tool's answer for the output the user looks at: {state, reason, source, path, name, files, file, video, progress}.
    property var status: ({})
    // Every output's answer, by output name.
    property var allStatus: ({})
    // The online daily picture as the shell reports it: {phase, failure, entry: {title, author, credit, caption, licenseShort,
    // licenseUrl, sourceUrl, fetchedAt, file} | null}; {} before it reports. Plain text only.
    property var online: ({})
    // The opt-in disclosure is open (the tile was chosen, the source is not on yet).
    property bool disclosing: false
    readonly property var onlineEntry: root.online.entry || null

    // The shipped photographs (ADR-0040 step 2c): their list beside them (photos.json), read once; none when the package did
    // not install them. A photograph is a picture for the shell (source "file").
    property var photos: []
    readonly property string photosDir: root.backend.wallpaperPhotosDir || ""
    readonly property string language: Qt.uiLanguage !== "" ? Qt.uiLanguage : Qt.locale().name
    readonly property var currentPhoto: root.source === "file" ? WallpaperConfig.photoAt(root.photos, root.path) : null
    // What About This Wallpaper shows: the picture of the day's attribution, or the photograph's.
    readonly property var aboutEntry: root.source === "online" ? root.onlineEntry : WallpaperConfig.photoAbout(root.currentPhoto, root.language)

    function loadPhotos(): void {
        const r = root.photosDir !== "" ? root.backend.readText(root.photosDir + "/photos.json") : null;
        root.photos = r && r.ok && r.exists ? WallpaperConfig.parsePhotos(r.text, root.photosDir) : [];
    }
    // The refusal of a choice (outside the dev folder, bad path): shown under the grids.
    property string refusal: ""
    property var pictures: []
    property var thumbs: ({})
    property var recents: []
    property var suffixes: ["jpg", "jpeg", "png", "webp", "tif", "tiff", "bmp", "gif"]

    // ---- names and captions ----
    function baseName(p: string): string {
        const i = p.lastIndexOf("/");
        return i >= 0 ? p.substring(i + 1) : p;
    }

    // A picture's or a video's name as a tile and the header show it: its file name without the extension (a name that starts
    // with a dot keeps it).
    function displayName(p: string): string {
        const name = root.baseName(p);
        const dot = name.lastIndexOf(".");
        return dot > 0 ? name.substring(0, dot) : name;
    }

    function intervalText(id: string): string {
        switch (id) {
        case "login":
            return qsTr("When logging in");
        case "5s":
            return qsTr("Every 5 seconds");
        case "1m":
            return qsTr("Every minute");
        case "5m":
            return qsTr("Every 5 minutes");
        case "15m":
            return qsTr("Every 15 minutes");
        case "30m":
            return qsTr("Every 30 minutes");
        case "1h":
            return qsTr("Every hour");
        case "1d":
            return qsTr("Every day");
        }
        return id;
    }

    readonly property var intervalModel: WallpaperConfig.INTERVAL_NAMES.map(id => ({id: id, text: root.intervalText(id)}))
    readonly property var fitModel: [{id: "fill", text: qsTr("Fill Screen")}, {id: "fit", text: qsTr("Fit to Screen")}, {id: "stretch", text: qsTr("Stretch to Fill Screen")}, {id: "center", text: qsTr("Center")}, {id: "tile", text: qsTr("Tile")}]
    readonly property var colorNames: [qsTr("Blue"), qsTr("Purple"), qsTr("Pink"), qsTr("Red"), qsTr("Orange"), qsTr("Yellow"), qsTr("Green"), qsTr("Graphite")]

    // The sentence for a failure id of the shell or the helper. The name is the user's, shown as plain text.
    function reasonText(id: string, name: string): string {
        switch (id) {
        case "not-found":
            return qsTr("The picture \"%1\" can't be found.").arg(name);
        case "unreadable":
            return qsTr("The picture \"%1\" can't be read.").arg(name);
        case "unsupported":
            return qsTr("This picture format isn't supported.");
        case "too-large":
            return qsTr("This picture is too large.");
        case "not-regular":
            return qsTr("This item can't be used as a wallpaper.");
        case "folder-unavailable":
            return qsTr("The folder \"%1\" isn't available.").arg(name);
        case "folder-empty":
            return qsTr("No pictures in this folder.");
        case "all-failed":
            return qsTr("None of the pictures in this folder can be shown.");
        case "helper-missing":
            return qsTr("Wallpapers can't be prepared: the helper is missing.");
        case "timeout":
            return qsTr("Preparing the picture took too long.");
        case "outside-dev":
            return qsTr("In a development session only pictures inside the project's .dev folder can be used.");
        case "invalid-path":
            return qsTr("This path can't be used.");
        case "video-unsupported":
            return qsTr("The video \"%1\" can't be played.").arg(name);
        case "video-too-long":
            return qsTr("This video is too long for a wallpaper (10 minutes at most).");
        case "transcode-failed":
            return qsTr("The video \"%1\" couldn't be prepared.").arg(name);
        case "ffmpeg-missing":
            return qsTr("Video wallpapers can't be prepared: ffmpeg is missing.");
        case "cancelled":
            return qsTr("Preparing the video was cancelled.");
        case "video-crashed":
            return qsTr("The video wallpaper was stopped; a still is shown.");
        case "network":
            return qsTr("The picture of the day can't be downloaded right now.");
        case "skipped":
            return qsTr("Today's entry is not a picture; yesterday's picture is shown.");
        case "bad-response":
            return qsTr("The picture of the day can't be read.");
        }
        return qsTr("The wallpaper can't be shown.");
    }

    // "26/10/22 09:41" in the user's locale, "" when the date does not parse.
    function formatUpdated(iso: string): string {
        const d = new Date(iso || "");
        return isNaN(d.getTime()) ? "" : Qt.locale().toString(d, Locale.ShortFormat);
    }

    // The source page as it reads: no scheme, percent-escapes decoded (WallpaperConfig.displayUrl).
    function sourceText(url: string): string {
        return WallpaperConfig.displayUrl(url);
    }

    // The licence name and the source page are links (CC BY 4.0 section 3(a)(1)(C)): a click or Return opens a clean https
    // address with xdg-open through the backend's guarded action path (an argument vector, never a shell string; a dev
    // session suppresses it). The page itself never touches the network.
    function openLink(url: string): void {
        const u = WallpaperConfig.linkOf(url);
        if (u !== "")
            root.backend.act(qsTr("Open a link"), ["xdg-open", u], "wallpaper.link");
    }

    readonly property string headline: {
        if (root.source === "builtin")
            return root.artworkModel.find(a => a.id === root.artwork).text;
        if (root.source === "color")
            return root.colorName(root.color);
        if (root.source === "online")
            return root.onlineEntry && root.onlineEntry.title ? root.onlineEntry.title : root.providerName(root.provider);
        if (root.source === "folder")
            return root.baseName(root.path);
        if (root.currentPhoto)
            return WallpaperConfig.photoName(root.currentPhoto, root.language);
        return root.displayName(root.path);
    }

    // A palette colour's name, "Colour" for any other.
    function colorName(c: string): string {
        const i = Tokens.iconModeTintColors.findIndex(t => t.toLowerCase() === String(c).toLowerCase());
        return i >= 0 ? root.colorNames[i] : qsTr("Colour");
    }

    // The name of an online source as the disclosure calls it.
    function providerName(id: string): string {
        return id === "apod" ? qsTr("Astronomy Picture of the Day (NASA)") : qsTr("Picture of the Day (Wikimedia Commons)");
    }

    // The hosts a provider contacts, as the disclosure names them.
    function providerHosts(id: string): string {
        return id === "apod" ? "api.nasa.gov, apod.nasa.gov" : "commons.wikimedia.org, thumb.wikimedia.org, upload.wikimedia.org";
    }

    // A video is being transcoded for the display shown (the shell reports its progress, 0..1).
    readonly property bool transcoding: root.source === "video" && typeof root.status.progress === "number" && root.status.progress >= 0

    readonly property string caption: {
        if (root.status.state === "error")
            return root.reasonText(root.status.reason, root.source === "file" ? root.baseName(root.path) : root.baseName(root.path));
        if (root.source === "video" && root.transcoding)
            return qsTr("Preparing the video… %1%").arg(Math.round(root.status.progress * 100));
        if (root.status.state === "preparing")
            return qsTr("Preparing…");
        // A video that crashed the shell is shown as its poster: said here, once the page shows it.
        if (root.source === "video" && root.status.reason === "video-crashed")
            return root.reasonText("video-crashed", "");
        if (root.source === "online") {
            // Nothing cached yet: the artwork shows, and the page says why.
            if (root.status.state === "waiting")
                return root.online.phase === "fetching" ? qsTr("Downloading today's picture…") : qsTr("Waiting for a connection");
            // Today's entry cannot be used (a video, a licence): the previous picture stays, and the page says so.
            if (root.online.failure === "skipped")
                return root.reasonText("skipped", "");
            return root.onlineEntry && root.onlineEntry.caption ? root.onlineEntry.caption : "";
        }
        if (root.source === "folder") {
            const every = root.shuffle ? qsTr("%1, shuffled").arg(root.intervalText(root.interval)) : root.intervalText(root.interval);
            return root.status.files > 0 ? qsTr("%1 · Pictures in the folder: %2").arg(every).arg(root.status.files) : every;
        }
        return "";
    }

    // ---- dev guard and choosing ----
    function problem(p: string): string {
        return WallpaperConfig.sourceProblem(p, root.backend.devSession, root.backend.devRoot);
    }

    // False, with the refusal shown, for a path the dev guard or the path rules refuse.
    function allowed(p: string): bool {
        const why = root.problem(p);
        if (why !== "")
            root.refusal = root.reasonText(why === "outside-dev" ? "outside-dev" : "invalid-path", root.baseName(p));
        return why === "";
    }

    function choose(entries: var, recentKind: string, recentPath: string): bool {
        if (recentKind !== "" && !root.allowed(recentPath))
            return false;
        root.refusal = "";
        if (!root.writeFields(entries))
            return false;
        if (recentKind !== "")
            root.remember(recentKind, recentPath);
        return true;
    }

    // Writes keys of grassfield.json in one write. For a chosen display the per-display keys go to that display's entry of
    // wallpaper.outputs (the top level stays); the keys that are not per display (the online provider, play on battery)
    // always go to the top level.
    function writeFields(entries: var): bool {
        if (root.currentDisplay === null)
            return root.store.setMany(entries);
        const perDisplay = ["source", "path", "color", "fit", "interval", "shuffle"];
        const fields = {};
        const next = {};
        for (const k of Object.keys(entries)) {
            const name = k.substring("wallpaper.".length);
            if (perDisplay.indexOf(name) >= 0)
                fields[name] = entries[k];
            else
                next[k] = entries[k];
        }
        if (Object.keys(fields).length > 0)
            next["wallpaper.outputs"] = WallpaperConfig.withOutput(root.stored.outputs, root.currentDisplay, fields);
        return root.store.setMany(next);
    }

    // The chosen display follows All Displays again (its override is removed).
    function useAllDisplays(): void {
        if (root.currentDisplay === null)
            return;
        // Back to following All Displays: what Cancel would have restored for this display is stale.
        root.previousBy = WallpaperConfig.forgetPrevious(root.previousBy, root.displayId);
        root.store.set("wallpaper.outputs", WallpaperConfig.withOutput(root.stored.outputs, root.currentDisplay, null));
    }

    // An artwork tile: the artwork source and which artwork (wallpaper.artwork is not per display: it applies everywhere the
    // artwork shows).
    function useArtwork(name: string): void {
        root.choose({"wallpaper.source": "builtin", "wallpaper.artwork": name}, "", "");
    }

    // The online tile asks first: what is contacted is shown, and nothing is turned on until the user agrees.
    function askOnline(provider: string): void {
        if (root.source === "online" && root.provider === provider)
            return;
        root.disclosedProvider = provider;
        root.disclosing = true;
        Qt.callLater(root.revealDisclosure);
    }

    // The disclosure opens below the fold: scroll it into view (its bottom at the bottom of the pane) and give the keyboard to the
    // default button.
    function revealDisclosure(): void {
        const bottom = disclosure.mapToItem(root.contentItem, 0, disclosure.height).y;
        root.contentY = Math.max(0, Math.min(root.contentHeight - root.height, Math.max(root.contentY, bottom - root.height + Tokens.spacingLg)));
        useOnlineButton.forceActiveFocus();
    }

    // The provider whose disclosure is open ('' when none).
    property string disclosedProvider: "commons"

    function useOnline(): void {
        root.disclosing = false;
        root.choose({"wallpaper.source": "online", "wallpaper.online.provider": root.disclosedProvider}, "", "");
    }

    // What each scope ("all" or a display key) showed before a video was chosen there: {key: {source, path, overridden}}. Cancel on
    // the progress row puts it back in that scope (macOS: Cancel leaves things as they were), see WallpaperConfig.cancelPlan.
    property var previousBy: ({})

    function useVideo(p: string): void {
        // `overridden`: the chosen display had a wallpaper of its own. Without one, Cancel removes the override again (the display
        // follows All Displays as before) instead of writing a copy of the inherited values.
        const was = {source: root.source, path: root.path, overridden: root.overridden};
        const key = root.displayId;
        if (root.choose({"wallpaper.source": "video", "wallpaper.path": p}, "video", p))
            root.previousBy = WallpaperConfig.rememberPrevious(root.previousBy, key, was, p);
    }

    // Cancel the preparation of the video: the wallpaper that was there before (the shell stops the job when the setting changes).
    function cancelVideo(): void {
        // The plan is for the display the page shows now; the entries of other displays stay (WallpaperConfig.cancelPlan).
        const plan = WallpaperConfig.cancelPlan(root.previousBy, root.displayId, root.currentDisplay !== null, root.overridden, root.source, root.path);
        root.previousBy = plan.map;
        const entries = plan.fields ? {"wallpaper.source": plan.fields.source, "wallpaper.path": plan.fields.path} : null;
        if (plan.action === "follow-all")
            // The display had no wallpaper of its own before the video: only its source and path go, what else it set (Fit...) stays.
            root.store.set("wallpaper.outputs", WallpaperConfig.withoutSource(root.stored.outputs, root.currentDisplay));
        else if (plan.action === "restore" && plan.scope === "all")
            // The choice was made for All Displays: undone there (the top level), whatever display the picker shows.
            root.store.setMany(entries);
        else if (plan.action === "restore")
            root.writeFields(entries);
        else if (plan.action === "artwork" && plan.scope === "all")
            // Nothing to restore, and the choice was for All Displays: the artwork there, no override for the display shown.
            root.store.setMany({"wallpaper.source": "builtin"});
        else if (plan.action === "artwork")
            root.useArtwork(root.artwork);
    }

    function useColor(c: string): void {
        root.choose({"wallpaper.source": "color", "wallpaper.color": c}, "", "");
    }

    function usePicture(p: string): void {
        root.choose({"wallpaper.source": "file", "wallpaper.path": p}, "file", p);
    }

    // A shipped photograph: shown like a picture, not added to Folders and Pictures (it has its own section).
    function usePhoto(p: string): void {
        if (!root.allowed(p))
            return;
        root.refusal = "";
        root.writeFields({"wallpaper.source": "file", "wallpaper.path": p});
    }

    function useFolder(p: string): void {
        root.choose({"wallpaper.source": "folder", "wallpaper.path": p}, "folder", p);
    }

    // A file, a folder or a video dropped on the preview: a video or a picture by its suffix, anything else is asked of the helper
    // (a folder lists, a file does not).
    function dropped(p: string): void {
        if (p === "" || !WallpaperConfig.validPath(p)) {
            root.refusal = root.reasonText("invalid-path", "");
            return;
        }
        const why = root.problem(p);
        if (why !== "") {
            root.refusal = root.reasonText(why === "outside-dev" ? "outside-dev" : "invalid-path", root.baseName(p));
            return;
        }
        const dot = p.lastIndexOf(".");
        const ext = dot > p.lastIndexOf("/") ? p.substring(dot + 1).toLowerCase() : "";
        if (WallpaperConfig.VIDEO_SUFFIXES.indexOf(ext) >= 0)
            root.useVideo(p);
        else if (root.suffixes.indexOf(ext) >= 0)
            root.usePicture(p);
        else
            root.backend.query([root.backend.wallpaperTool, "list", "--max", "1", "--", p], "wp.drop:" + p, 10000);
    }

    function urlToPath(u: url): string {
        const s = u.toString();
        return s.indexOf("file://") === 0 ? decodeURIComponent(s.substring(7)) : "";
    }

    // ---- recents (wallpaper-recent.json, written by this page) ----
    function loadRecents(): void {
        const f = root.backend.readText(root.backend.wallpaperRecentFile);
        let list = [];
        if (f.exists && f.ok) {
            try {
                const o = JSON.parse(f.text);
                if (Array.isArray(o))
                    list = o.filter(e => e && (e.kind === "file" || e.kind === "folder" || e.kind === "video") && typeof e.path === "string" && WallpaperConfig.validPath(e.path));
            } catch (e) {
                list = [];
            }
        }
        root.recents = list.slice(0, 12);
    }

    function remember(kind: string, p: string): void {
        const next = [{kind: kind, path: p}].concat(root.recents.filter(e => !(e.kind === kind && e.path === p))).slice(0, 12);
        root.recents = next;
        root.backend.writeText(root.backend.wallpaperRecentFile, JSON.stringify(next, null, 2) + "\n");
    }

    // ---- the helper: listing and thumbnails, two at a time ----
    property var thumbQueue: []
    property var thumbFailed: ({})
    // The pictures the helper is preparing now (asked once: Show All asks again for the tiles already drawn).
    property var thumbRunning: ({})
    readonly property int thumbBusy: Object.keys(root.thumbRunning).length

    function requestThumb(p: string): void {
        if (p === "" || root.thumbs[p] !== undefined || root.thumbFailed[p] || root.thumbRunning[p] || root.thumbQueue.indexOf(p) >= 0)
            return;
        root.thumbQueue = root.thumbQueue.concat([p]);
        root.pump();
    }

    function requestThumbs(paths: var): void {
        for (const p of paths)
            root.requestThumb(p);
    }

    function pump(): void {
        while (root.thumbBusy < 2 && root.thumbQueue.length > 0) {
            const p = root.thumbQueue[0];
            root.thumbQueue = root.thumbQueue.slice(1);
            const running = Object.assign({}, root.thumbRunning);
            running[p] = true;
            root.thumbRunning = running;
            root.backend.query([root.backend.wallpaperTool, "thumb", "--width", String(Tokens.settingsWallpaperThumbWidth), "--out", root.backend.wallpaperCache + "/thumbs", "--", p], "wp.thumb:" + p, 20000);
        }
    }

    function refreshPictures(): void {
        root.backend.query([root.backend.wallpaperTool, "list", "--max", "500", "--", root.backend.picturesDir], "wp.list", 10000);
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "wp.list") {
                if (!ok)
                    return;
                try {
                    const o = JSON.parse(output);
                    root.pictures = Array.isArray(o.files) ? o.files : [];
                } catch (e) {
                    root.pictures = [];
                }
            } else if (tag === "wp.formats") {
                if (!ok)
                    return;
                try {
                    const o = JSON.parse(output);
                    if (Array.isArray(o.suffixes) && o.suffixes.length > 0)
                        root.suffixes = o.suffixes;
                } catch (e) {
                    // The built-in list stays.
                }
            } else if (tag.indexOf("wp.drop:") === 0) {
                const p = tag.substring(8);
                if (ok)
                    root.useFolder(p);
                else
                    root.refusal = root.reasonText("not-regular", root.baseName(p));
            } else if (tag.indexOf("wp.thumb:") === 0) {
                const p = tag.substring(9);
                const running = Object.assign({}, root.thumbRunning);
                delete running[p];
                root.thumbRunning = running;
                let file = "";
                if (ok) {
                    try {
                        const o = JSON.parse(output);
                        // The helper names the picture it really read: in a dev session it must lie inside .dev (a symlink
                        // there must not show an owner's photo), as the shell checks it. The thumbnail must be in the cache.
                        const okReal = typeof o.real === "string" && root.problem(o.real) === "";
                        const okFile = typeof o.file === "string" && WallpaperConfig.isUnder(o.file, root.backend.wallpaperCache);
                        file = okReal && okFile ? o.file : "";
                    } catch (e) {
                        file = "";
                    }
                }
                if (file !== "") {
                    const t = Object.assign({}, root.thumbs);
                    t[p] = file;
                    root.thumbs = t;
                } else {
                    const f = Object.assign({}, root.thumbFailed);
                    f[p] = true;
                    root.thumbFailed = f;
                }
                root.pump();
            }
        }

        function onFileChanged(p: string): void {
            if (p === root.backend.wallpaperStatusFile)
                root.loadStatus();
        }
    }

    // ---- the shell's status ----
    function loadStatus(): void {
        const f = root.backend.readText(root.backend.wallpaperStatusFile);
        let outputs = {};
        let online = {};
        if (f.exists && f.ok) {
            try {
                const parsed = JSON.parse(f.text);
                online = parsed.online && typeof parsed.online === "object" ? parsed.online : {};
                outputs = parsed.outputs && typeof parsed.outputs === "object" ? parsed.outputs : {};
            } catch (e) {
                outputs = {};
            }
        }
        root.allStatus = outputs;
        root.online = online;
        root.pickStatus();
    }

    // The answer for the display the options are for; for All Displays the one worth showing among the displays that follow All
    // Displays (an error first), so that the preview never shows the picture of a display with its own wallpaper (owner
    // 2026-11-07); every output's when none follows.
    function pickStatus(): void {
        const outputs = root.allStatus;
        if (root.currentDisplay !== null && outputs[root.currentDisplay.name]) {
            root.status = outputs[root.currentDisplay.name];
            return;
        }
        const following = root.displays.filter(d => !WallpaperConfig.sourceOverridden(root.stored.outputs, d) && outputs[d.name]).map(d => outputs[d.name]);
        const all = following.length > 0 ? following : Object.keys(outputs).map(k => outputs[k]);
        root.status = all.find(o => o.state === "error") || all[all.length - 1] || {};
    }

    onCurrentDisplayChanged: root.pickStatus()
    // A display that gains or loses a wallpaper of its own changes which display All Displays is shown by.
    onStoredChanged: root.pickStatus()

    // The displays with a wallpaper of their own, by name (what a choice under All Displays does not change).
    readonly property var ownWallpaperNames: root.displays.filter(d => WallpaperConfig.sourceOverridden(root.stored.outputs, d)).map(d => d.label)

    // The line under the picker: which displays a choice changes, by name.
    readonly property string targetText: {
        if (root.currentDisplay !== null)
            return root.overridden ? qsTr("Changes apply to %1 only: it has a wallpaper of its own.").arg(root.currentDisplay.label)
                                   : qsTr("Changes apply to %1 only. It follows All Displays until you choose a wallpaper for it.").arg(root.currentDisplay.label);
        const own = root.ownWallpaperNames;
        if (own.length === 0)
            return qsTr("The same wallpaper on every display. Choose a display to give it a wallpaper of its own.");
        if (own.length >= root.displays.length)
            return qsTr("Every display has a wallpaper of its own, so a choice here shows on none of them. Choose a display to change its wallpaper.");
        return own.length === 1 ? qsTr("Changes apply to every display except %1, which has a wallpaper of its own.").arg(own[0])
                                : qsTr("Changes apply to every display except %1, which have wallpapers of their own.").arg(own.join(", "));
    }

    // The picture the preview shows: the shell's prepared picture for the display once its report names the choice; right after a
    // choice, while the shell prepares it, the chosen tile's thumbnail, so that the change is seen in the pane at once (owner
    // 2026-11-07). "" for the artwork and a colour (drawn, not pictures).
    readonly property string previewFile: {
        if (root.source === "builtin" || root.source === "color")
            return "";
        const shown = root.status.source === root.source && root.status.path === root.path;
        if (shown && root.status.file)
            return root.status.file;
        const thumb = root.thumbs[root.path] || "";
        return thumb !== "" ? thumb : (root.status.file || "");
    }

    // The connected displays (QScreen: name, model, serial), the same identity the shell uses (WallpaperConfig.displayKey), by the
    // names Settings > Displays gives them (DisplayHeader): the laptop's panel is the Built-in Display, another its model (its
    // connector without one); two of one name add their connectors.
    function refreshDisplays(): void {
        const list = root.backend.screens();
        const named = list.map(s => {
            const d = {name: s.name, model: s.model || "", serial: s.serial || ""};
            d.key = WallpaperConfig.displayKey(d);
            d.label = Displays.isBuiltIn(d) ? qsTr("Built-in Display") : (String(d.model).trim() !== "" ? String(d.model).trim() : d.name);
            return d;
        });
        const twins = named.map(d => named.filter(o => o.label === d.label).length > 1);
        root.displays = named.map((d, i) => {
            if (twins[i])
                d.label = qsTr("%1 (%2)").arg(d.label).arg(d.name);
            return d;
        });
        if (root.displayId !== "all" && !root.displays.some(d => d.key === root.displayId))
            root.displayId = "all";
    }

    // The display another surface asks for (the desktop's Change Wallpaper…: `grassfield-settings --section=wallpaper --display=<output
    // name>`, or the display's key): the pane opens on it. "" asks for nothing. An unknown one shows All Displays.
    property string requestedDisplay: ""

    function applyRequest(): void {
        if (root.requestedDisplay === "")
            return;
        root.refreshDisplays();
        const d = root.displays.find(x => x.name === root.requestedDisplay || x.key === root.requestedDisplay);
        // An unknown output (unplugged, a stale request) shows All Displays, never the display the pane showed before.
        root.displayId = d ? d.key : "all";
    }

    onRequestedDisplayChanged: root.applyRequest()

    Component.onCompleted: {
        root.backend.watch(root.backend.wallpaperStatusFile);
        root.refreshDisplays();
        root.applyRequest();
        root.loadStatus();
        root.loadRecents();
        root.refreshPictures();
        root.loadPhotos();
        root.backend.query([root.backend.wallpaperTool, "formats"], "wp.formats", 5000);
    }

    // macOS 27 lays the pane out in one column of its own (docs/audits/settings-parity-2026-10-26.md § Wallpaper): the current
    // wallpaper (its preview, a group of its options, push buttons, a line across the pane), then sections of tiles on the window's
    // background, each title placed from the previous row (WallpaperSection), not with the page's group gap.
    Column {
        width: parent.width

        // ---- which display the pane is for (ADR-0016 section 8, ADR-0044 D-5): at the top, with more than one output ----
        // "All Displays" (one wallpaper everywhere, the default) or one display with a wallpaper of its own. Every row and
        // tile below reads and writes the chosen display's entry of `wallpaper.outputs`.
        Item {
            id: displayPicker
            visible: root.displays.length > 1
            width: parent.width
            height: visible ? pickerRow.height + pickerCaption.height + Tokens.spacingSm : 0

            Row {
                id: pickerRow
                spacing: Tokens.spacingSm

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: qsTr("Display")
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                    font.weight: Font.DemiBold
                }

                ComboBox {
                    inline: true
                    anchors.verticalCenter: parent.verticalCenter
                    accessibleName: qsTr("Display")
                    model: [{id: "all", text: qsTr("All Displays")}].concat(root.displays.map(d => ({id: d.key, text: d.label})))
                    value: root.displayId
                    onPicked: id => root.displayId = id
                }
            }

            // Names the displays a choice changes (owner 2026-11-07: which display a change is for must be plain in the pane).
            Text {
                id: pickerCaption
                objectName: "wallpaperTarget"
                anchors.top: pickerRow.bottom
                anchors.topMargin: Tokens.spacingXs
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: root.targetText
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }

        // ---- the current wallpaper ----
        Item {
            id: header
            width: parent.width
            height: line.y + line.height

            // The block is wallpaperHeaderInset from the pane's edges, a little wider than the groups below.
            readonly property real outset: Tokens.settingsContentMargin - Tokens.settingsWallpaperHeaderInset

            Item {
                id: preview
                x: -header.outset
                y: Tokens.settingsWallpaperHeaderTop
                width: Tokens.settingsWallpaperPreviewWidth
                height: Tokens.settingsWallpaperPreviewHeight
                Accessible.role: Accessible.Graphic
                Accessible.name: root.currentDisplay !== null ? qsTr("Current wallpaper of %1: %2").arg(root.currentDisplay.label).arg(root.headline) : qsTr("Current wallpaper: %1").arg(root.headline)

                // Dropping a file, a folder or a video on the preview sets it (ADR-0016 section 8).
                DropArea {
                    anchors.fill: parent
                    keys: ["text/uri-list"]
                    onDropped: drop => {
                        if (drop.urls.length > 0)
                            root.dropped(root.urlToPath(drop.urls[0]));
                    }
                }

                Item {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: previewMask
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: root.source === "color" ? root.color : Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
                    }

                    // The artwork and the variant the desktop shows (its phase of the day from the shell's report).
                    GrassfieldArtwork {
                        anchors.fill: parent
                        visible: root.source === "builtin" || (root.source !== "color" && preparedImage.status !== Image.Ready)
                        artwork: root.artwork
                        variant: WallpaperConfig.artworkVariantFor(root.artwork, root.artworkVariant, Appearance.dark, root.status.phase ?? "")
                    }

                    Image {
                        id: preparedImage
                        anchors.fill: parent
                        // The prepared picture the shell drew (the tool's own output, never the user's file), cropped as the display shows
                        // it; right after a choice the tile's thumbnail (previewFile).
                        source: root.previewFile !== "" ? "file://" + root.previewFile : ""
                        asynchronous: true
                        cache: false
                        fillMode: Image.PreserveAspectCrop
                        sourceSize: Qt.size(Tokens.settingsWallpaperThumbWidth * 2, Tokens.settingsWallpaperThumbWidth * 2)
                    }
                }

                Rectangle {
                    id: previewMask
                    visible: false
                    layer.enabled: true
                    width: parent.width
                    height: parent.height
                    radius: Tokens.settingsWallpaperPreviewRadius
                }
            }

            SettingsGroup {
                id: options
                x: preview.x + Tokens.settingsWallpaperGroupX
                y: Tokens.settingsWallpaperHeaderTop
                width: header.width + header.outset - x

                // The wallpaper's name (and what the shell says about it), with how it fills the screen, or its colour.
                SettingsRow {
                    title: root.headline
                    subtitle: root.caption

                    // The artwork's variant: Time of Day, Automatic, Light or Dark (ADR-0040 section 2, IQ-W1 C).
                    ComboBox {
                        visible: root.source === "builtin"
                        inline: true
                        accessibleName: qsTr("Appearance of the wallpaper")
                        model: root.variantModel
                        // Time of Day on another artwork reads as Automatic (WallpaperConfig.artworkVariantFor).
                        value: root.variantModel.some(m => m.id === root.artworkVariant) ? root.artworkVariant : "automatic"
                        onPicked: id => root.store.set("wallpaper.artworkVariant", id)
                    }

                    ComboBox {
                        visible: root.source === "file" || root.source === "folder" || root.source === "online" || root.source === "video"
                        inline: true
                        accessibleName: qsTr("Fit")
                        // A video is filled or fitted only; the other modes are for pictures.
                        model: root.source === "video" ? root.fitModel.filter(m => m.id === "fill" || m.id === "fit") : root.fitModel
                        value: root.fit
                        onPicked: id => root.writeFields({"wallpaper.fit": id})
                    }

                    ColorWell {
                        visible: root.source === "color"
                        accessibleName: qsTr("Wallpaper colour")
                        color: root.color
                        presets: Tokens.iconModeTintColors.map((c, i) => ({color: c, name: root.colorNames[i]}))
                        onEdited: c => root.writeFields({"wallpaper.color": c})
                    }
                }

                // The moving Grassfield artwork (ADR-0040 IQ-W3 A, step 9): off by default; it moves on the lock screen only (the
                // integrator's decision in the review of e067f26f).
                SettingsRow {
                    visible: root.source === "builtin" && root.artwork === "grassfield"
                    title: qsTr("Moving clouds")
                    subtitle: qsTr("On the lock screen, clouds drift and the light changes slowly, coming to rest as you unlock; the desktop shows them still. Still with Reduce Motion.")

                    Toggle {
                        accessibleName: qsTr("Moving clouds")
                        checked: root.store.value("wallpaper.moving") === true
                        onToggled: c => root.store.set("wallpaper.moving", c)
                    }
                }

                SettingsRow {
                    visible: (root.source === "file" || root.source === "folder" || root.source === "online" || root.source === "video") && (root.fit === "fit" || root.fit === "center" || root.fit === "tile")
                    title: qsTr("Colour")
                    subtitle: qsTr("Shown around a picture that does not fill the screen.")

                    ColorWell {
                        accessibleName: qsTr("Wallpaper colour")
                        color: root.color
                        presets: Tokens.iconModeTintColors.map((c, i) => ({color: c, name: root.colorNames[i]}))
                        onEdited: c => root.writeFields({"wallpaper.color": c})
                    }
                }

                SettingsRow {
                    visible: root.source === "folder"
                    title: qsTr("Change picture")

                    ComboBox {
                        inline: true
                        accessibleName: qsTr("Change picture")
                        model: root.intervalModel
                        value: root.interval
                        onPicked: id => root.writeFields({"wallpaper.interval": id})
                    }
                }

                SettingsRow {
                    visible: root.source === "folder"
                    title: qsTr("Shuffle")
                    subtitle: qsTr("Random order, every picture once before any is repeated.")

                    Toggle {
                        accessibleName: qsTr("Shuffle")
                        checked: root.shuffle
                        onToggled: c => root.writeFields({"wallpaper.shuffle": c})
                    }
                }

                SettingsRow {
                    visible: root.source === "video"
                    title: qsTr("Play on battery power")
                    subtitle: qsTr("A video wallpaper pauses on battery, when you are away, under a full-screen window, and with Reduce Motion.")

                    Toggle {
                        accessibleName: qsTr("Play on battery power")
                        checked: root.videoOnBattery
                        onToggled: c => root.store.set("wallpaper.videoOnBattery", c)
                    }
                }

                // The shell transcodes the video once (H.264 with at most the pixels of 4K UHD, in the display's orientation); its
                // progress is reported in wallpaper-state.json, and the name row above says it in words.
                Item {
                    visible: root.transcoding
                    width: parent.width
                    height: Tokens.settingsRowHeight

                    Rectangle {
                        x: Tokens.settingsRowInset
                        width: parent.width - 2 * Tokens.settingsRowInset
                        height: Tokens.appsBorderWidth
                        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                    }

                    ProgressBar {
                        x: Tokens.settingsRowInset
                        anchors.verticalCenter: parent.verticalCenter
                        width: cancelVideoButton.x - x - Tokens.spacingLg
                        accessibleName: qsTr("Preparing the video")
                        from: 0
                        to: 1
                        value: root.transcoding ? Math.max(0, Math.min(1, root.status.progress)) : 0
                    }

                    // Cancel: the wallpaper that was there before (the shell stops the job).
                    Button {
                        id: cancelVideoButton
                        anchors.right: parent.right
                        anchors.rightMargin: Tokens.settingsRowInset
                        anchors.verticalCenter: parent.verticalCenter
                        push: true
                        text: qsTr("Cancel")
                        onClicked: root.cancelVideo()
                    }
                }
            }

            // Push buttons under the group, right-aligned (macOS 27: Screen Saver…, last on the right); a long pair wraps.
            Flow {
                id: buttons
                x: options.x
                y: options.y + options.height + Tokens.settingsWallpaperButtonsGap
                width: options.width
                layoutDirection: Qt.RightToLeft
                spacing: Tokens.settingsWallpaperButtonSpacing

                Button {
                    push: true
                    text: qsTr("Screen Saver…")
                    onClicked: root.screenSaverRequested()
                }

                Button {
                    visible: root.status.state === "error" && root.source !== "builtin"
                    push: true
                    text: qsTr("Use the Grassfield Wallpaper")
                    onClicked: root.useArtwork(root.artwork)
                }

                Button {
                    visible: root.overridden
                    push: true
                    text: qsTr("Use the All Displays Wallpaper")
                    onClicked: root.useAllDisplays()
                }
            }

            // A line across the whole pane, under the preview or the buttons, whichever ends lower.
            Rectangle {
                id: line
                x: -root.columnX
                y: Math.max(preview.y + preview.height + Tokens.settingsWallpaperSeparatorPreviewGap, (buttons.height > 0 ? buttons.y + buttons.height : options.y + options.height) + Tokens.settingsWallpaperSeparatorGap)
                width: root.width
                height: Tokens.appsBorderWidth
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }
        }

        // ---- sections ----
        WallpaperSection {
            // The first title is placed from the line's top.
            lead: Tokens.settingsWallpaperTitleBaseline - line.height
            title: qsTr("Grassfield")
            model: root.artworkModel.map(a => ({kind: "art", artwork: a.id, variant: WallpaperConfig.artworkVariantFor(a.id, "automatic", Appearance.dark, ""), label: a.text, selected: root.source === "builtin" && root.artwork === a.id}))
            onActivated: index => root.useArtwork(root.artworkModel[index].id)
        }

        // The shipped photographs (ADR-0040 step 2c), named in the session's language; the section is absent without them.
        WallpaperSection {
            id: photosSection
            visible: root.photos.length > 0
            title: qsTr("Photographs")
            model: root.photos.map(p => ({kind: "image", label: WallpaperConfig.photoName(p, root.language), thumb: root.thumbs[p.path] || "", selected: root.source === "file" && root.path === p.path}))
            onActivated: index => root.usePhoto(root.photos[index].path)

            // The thumbnails of the tiles drawn (the row, or all of them once shown).
            readonly property var drawn: root.photos.slice(0, photosSection.grid.shown).map(p => p.path)
            onDrawnChanged: root.requestThumbs(photosSection.drawn)
        }

        // Pictures and folders added here, after the tiles that add them: a picture shows its thumbnail, a folder reads
        // "Shuffle <name>" (macOS wording).
        WallpaperSection {
            id: addedSection
            title: qsTr("Folders and Pictures")
            readonly property var items: root.recents.filter(e => e.kind !== "video")
            readonly property var adds: [{kind: "add", icon: "picture-add", label: qsTr("Add Picture…")}, {kind: "add", icon: "folder-add", label: qsTr("Add Folder…")}]
            model: adds.concat(items.map(e => ({
                            kind: e.kind === "file" ? "image" : "folder",
                            label: e.kind === "folder" ? qsTr("Shuffle %1").arg(root.baseName(e.path)) : root.displayName(e.path),
                            thumb: e.kind === "file" ? (root.thumbs[e.path] || "") : "",
                            selected: root.source === e.kind && root.path === e.path
                        })))
            onActivated: index => {
                if (index === 0)
                    fileDialog.open();
                else if (index === 1)
                    folderDialog.open();
                else if (addedSection.items[index - 2].kind === "file")
                    root.usePicture(addedSection.items[index - 2].path);
                else
                    root.useFolder(addedSection.items[index - 2].path);
            }
            onItemsChanged: root.requestThumbs(addedSection.items.filter(e => e.kind === "file").map(e => e.path))
        }

        // ---- videos (ADR-0016 W7): a video is prepared once by the shell, then plays under the pause policy ----
        WallpaperSection {
            id: videosSection
            title: qsTr("Videos")
            readonly property var items: root.recents.filter(e => e.kind === "video")
            model: [{kind: "add", icon: "video-add", label: qsTr("Add Video…")}].concat(items.map(e => ({kind: "video", label: root.displayName(e.path), thumb: root.thumbs[e.path] || "", selected: root.source === "video" && root.path === e.path})))
            onActivated: index => {
                if (index === 0)
                    videoDialog.open();
                else
                    root.useVideo(videosSection.items[index - 1].path);
            }
            onItemsChanged: root.requestThumbs(videosSection.items.map(e => e.path))
        }

        // ---- online (ADR-0016 step 2) ----
        WallpaperSection {
            title: qsTr("Online")
            model: [{kind: "image", label: qsTr("Wikimedia"), fullName: root.providerName("commons"), thumb: root.source === "online" && root.provider === "commons" && root.onlineEntry && root.onlineEntry.file ? root.onlineEntry.file : "", selected: root.source === "online" && root.provider === "commons"},
                {kind: "image", label: qsTr("NASA APOD"), fullName: root.providerName("apod"), thumb: root.source === "online" && root.provider === "apod" && root.onlineEntry && root.onlineEntry.file ? root.onlineEntry.file : "", selected: root.source === "online" && root.provider === "apod"}]
            onActivated: index => root.askOnline(index === 1 ? "apod" : "commons")

            Text {
                visible: !disclosure.visible
                width: parent.width
                topPadding: Tokens.settingsWallpaperTilesTop
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: qsTr("Once a day Grassfield contacts the source you choose: commons.wikimedia.org, thumb.wikimedia.org and upload.wikimedia.org, or api.nasa.gov and apod.nasa.gov. These services see your IP address.")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            // The opt-in: what is contacted, how often, who sees what. Esc or Cancel leaves everything as it was.
            Item {
                id: disclosure
                visible: root.disclosing && !(root.source === "online" && root.provider === root.disclosedProvider)
                width: parent.width
                height: visible ? disclosureColumn.y + disclosureColumn.height : 0
                Accessible.role: Accessible.Grouping
                Accessible.name: root.providerName(root.disclosedProvider)
                Keys.onEscapePressed: root.disclosing = false

                Column {
                    id: disclosureColumn
                    y: Tokens.settingsWallpaperTilesTop
                    width: parent.width
                    spacing: Tokens.spacingSm

                    Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        text: root.disclosedProvider === "apod" ? qsTr("Grassfield will download NASA's Astronomy Picture of the Day once a day. It contacts api.nasa.gov and apod.nasa.gov, and only while you are online on a connection that is not metered. These services see your IP address and the day you ask for; the shared demonstration key is used, so no account is involved. A picture that has a copyright holder is shown with its credit. Nothing is contacted until you choose Use Picture of the Day.") : qsTr("Grassfield will download the Wikimedia Commons Picture of the Day once a day. It contacts commons.wikimedia.org, thumb.wikimedia.org and upload.wikimedia.org, and only while you are online on a connection that is not metered. These services see your IP address and the picture you ask for. Nothing is contacted until you choose Use Picture of the Day.")
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                        Accessible.role: Accessible.StaticText
                        Accessible.name: text
                    }

                    Row {
                        anchors.right: parent.right
                        spacing: Tokens.settingsWallpaperButtonSpacing

                        Button {
                            push: true
                            text: qsTr("Cancel")
                            onClicked: root.disclosing = false
                        }

                        Button {
                            id: useOnlineButton
                            push: true
                            primary: true
                            text: qsTr("Use Picture of the Day")
                            onClicked: root.useOnline()
                        }
                    }
                }
            }
        }

        // The attribution of the picture on screen (the same fields as the desktop menu's "About This Wallpaper"): the picture of
        // the day's, or a shipped photograph's (ADR-0040 step 2c); a group, its title where the next section's would be.
        Item {
            visible: root.aboutEntry !== null
            width: parent.width
            height: visible ? aboutGroup.y + aboutGroup.height : 0

            SettingsGroup {
                id: aboutGroup
                // A group's caption sits settingsCaptionGap - settingsGroupGap under its top when it follows another.
                y: Tokens.settingsWallpaperAddSectionGap - (Tokens.settingsCaptionGap - Tokens.settingsGroupGap)
                caption: qsTr("About This Wallpaper")

                SettingsRow {
                    visible: !!(root.aboutEntry && root.aboutEntry.title)
                    title: qsTr("Title")
                    valueText: root.aboutEntry ? root.aboutEntry.title : ""
                }

                // A photograph's credit is its author's own attribution line, with its copyright notice (WallpaperConfig.photoAbout).
                SettingsRow {
                    visible: !!(root.aboutEntry && (root.aboutEntry.author || root.aboutEntry.credit))
                    title: root.aboutEntry && root.aboutEntry.author ? qsTr("Author") : qsTr("Credit")
                    valueText: root.aboutEntry ? (root.aboutEntry.author || root.aboutEntry.credit) : ""
                }

                SettingsRow {
                    id: sourceRow
                    readonly property string link: root.aboutEntry ? WallpaperConfig.linkOf(root.aboutEntry.sourceUrl) : ""
                    title: qsTr("Source")
                    subtitle: sourceRow.link === "" && root.aboutEntry ? root.sourceText(root.aboutEntry.sourceUrl) : ""
                    valueText: sourceRow.link === "" ? (root.provider === "apod" ? qsTr("NASA APOD") : qsTr("Wikimedia Commons")) : ""

                    LinkText {
                        visible: sourceRow.link !== ""
                        width: Math.min(implicitWidth, sourceRow.width - Tokens.settingsGroupLabelWidth - 3 * Tokens.spacingLg)
                        text: root.aboutEntry ? root.sourceText(root.aboutEntry.sourceUrl) : ""
                        target: sourceRow.link
                        maximumLineCount: 3
                        onActivated: root.openLink(sourceRow.link)
                    }
                }

                SettingsRow {
                    id: licenceRow
                    readonly property string link: root.aboutEntry ? WallpaperConfig.linkOf(root.aboutEntry.licenseUrl) : ""
                    visible: !!(root.aboutEntry && root.aboutEntry.licenseShort)
                    title: qsTr("Licence")
                    valueText: licenceRow.link === "" && root.aboutEntry ? root.aboutEntry.licenseShort : ""

                    LinkText {
                        visible: licenceRow.link !== ""
                        width: Math.min(implicitWidth, licenceRow.width - Tokens.settingsGroupLabelWidth - 3 * Tokens.spacingLg)
                        text: root.aboutEntry ? root.aboutEntry.licenseShort : ""
                        target: licenceRow.link
                        onActivated: root.openLink(licenceRow.link)
                    }
                }

                // What Grassfield did to a shipped photograph (THIRD_PARTY.md): the licence's "indicate if You modified" it.
                SettingsRow {
                    visible: !!root.aboutEntry && root.aboutEntry.modified === true
                    title: qsTr("Changes")
                    valueText: qsTr("Resized and re-encoded by Grassfield, metadata removed")
                }

                SettingsRow {
                    visible: !!root.aboutEntry && root.formatUpdated(root.aboutEntry.fetchedAt) !== ""
                    title: qsTr("Last updated")
                    valueText: root.aboutEntry ? root.formatUpdated(root.aboutEntry.fetchedAt) : ""
                }
            }
        }

        // The pictures of the Pictures folder (macOS: Pictures, the last but one section).
        WallpaperSection {
            id: picturesSection
            title: qsTr("Pictures")
            model: root.pictures.map(p => ({kind: "image", label: root.displayName(p), thumb: root.thumbs[p] || "", selected: root.source === "file" && root.path === p}))
            onActivated: index => root.usePicture(root.pictures[index])

            // The thumbnails of the tiles drawn (the row, or all of them once shown).
            readonly property var drawn: root.pictures.slice(0, picturesSection.grid.shown)
            onDrawnChanged: root.requestThumbs(picturesSection.drawn)

            Text {
                visible: root.pictures.length === 0
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: qsTr("No pictures were found in the Pictures folder.")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }

        WallpaperSection {
            title: qsTr("Colours")
            model: Tokens.iconModeTintColors.map((c, i) => ({kind: "color", color: c, label: root.colorNames[i], selected: root.source === "color" && root.color.toLowerCase() === c.toLowerCase()}))
            onActivated: index => root.useColor(Tokens.iconModeTintColors[index])
        }

        Text {
            visible: root.refusal !== ""
            width: parent.width
            topPadding: Tokens.settingsWallpaperTilesTop
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.refusal
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }
    }

    // The pickers are Qt Quick Dialogs: with the session's GTK platform theme they are the native chooser (a documented
    // limit: it does not look like a Grassfield window). Esc closes them and changes nothing.
    FolderDialog {
        id: folderDialog
        title: qsTr("Choose a folder of pictures")
        onAccepted: {
            const p = root.urlToPath(selectedFolder);
            if (p !== "")
                root.useFolder(p);
        }
    }

    FileDialog {
        id: videoDialog
        title: qsTr("Choose a video")
        nameFilters: [qsTr("Videos (%1)").arg(WallpaperConfig.VIDEO_SUFFIXES.map(s => "*." + s).join(" "))]
        onAccepted: {
            const p = root.urlToPath(selectedFile);
            if (p !== "")
                root.useVideo(p);
        }
    }

    FileDialog {
        id: fileDialog
        title: qsTr("Choose a picture")
        nameFilters: [qsTr("Pictures (%1)").arg(root.suffixes.map(s => "*." + s).join(" "))]
        onAccepted: {
            const p = root.urlToPath(selectedFile);
            if (p !== "")
                root.usePicture(p);
        }
    }
}
