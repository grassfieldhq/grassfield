pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.services

// What one output's wallpaper shows, decided from the settings (ADR-0016). Not a surface: Wallpaper.qml draws `display`.
//   - source builtin / color: no picture (`imageUrl` ""), the artwork or the colour is drawn.
//   - source file: grassfield-wallpaper prepares the picture at this output's physical size and fit (the shell decodes only
//     the helper's own output), `imageUrl` names the prepared file, `strip` holds the menu bar strip statistics.
//   - source online (ADR-0016 step 2): the newest picture WallpaperOnline has on disk is prepared like a file (`label` is its
//     title); with nothing cached the artwork shows and the state is "waiting" (Settings: "Waiting for a connection"). A newer
//     picture (a day later) replaces it through the same crossfade.
//   - source video (ADR-0016 W7): `probe`, then `transcode` (H.264 with at most the pixels of 4K UHD, in the output's orientation; its progress is published for
//     Settings), then the poster frame is the picture (`imageUrl`, the lock screen's still) and `display.video` names the file
//     Wallpaper.qml plays under the pause policy. A video that crashed the shell (WallpaperState.isVideoBlocked) shows its poster
//     and is not played; the reason is "video-crashed".
//   - source folder: the helper lists the folder, WallpaperConfig.advance picks the next picture (sorted or shuffled without
//     repeat, position kept in WallpaperState), the interval timer asks for the next one. A file that fails is skipped for the
//     session; with every file failing the current picture stays and `reason` says why.
// One job at a time per output: a newer request supersedes (the running process gets SIGTERM, its answer is ignored); a job
// that runs too long is killed. On any failure the previous wallpaper stays (never a blank frame) and `status` is "error".
Scope {
    id: root

    required property var screenInfo

    // An output that is removed leaves its feed alive for a moment with a null screen: every use is guarded.
    readonly property string outputName: screenInfo ? screenInfo.name : ""
    readonly property real scale: screenInfo && screenInfo.devicePixelRatio > 0 ? screenInfo.devicePixelRatio : 1
    readonly property int pixelWidth: Math.max(1, Math.round((screenInfo ? screenInfo.width : 0) * scale))
    readonly property int pixelHeight: Math.max(1, Math.round((screenInfo ? screenInfo.height : 0) * scale))
    // The same identity Settings and the Dock overrides use (DisplayScope.identity: serialNumber when the monitor reports one).
    readonly property var outputIdentity: DisplayScope.identity(screenInfo)
    readonly property string displayKey: WallpaperConfig.displayKey(outputIdentity)
    // Effective settings of this output.
    readonly property var cfg: WallpaperConfig.resolve(Settings.wallpaper, outputIdentity)
    // The online source also follows the picture on disk (a new day's picture is a change).
    readonly property string onlineFile: cfg.source === "online" && WallpaperOnline.entry ? WallpaperOnline.entry.file : ""
    readonly property bool onlineLoaded: cfg.source === "online" && WallpaperOnline.entryLoaded
    readonly property string cfgKey: JSON.stringify([cfg, pixelWidth, pixelHeight, onlineFile, onlineLoaded])

    // builtin | color | preparing | ready | error | waiting
    property string status: "builtin"
    // Failure id (WallpaperConfig.reasonOf ids, plus folder-unavailable, folder-empty, all-failed, outside-dev, invalid-path,
    // helper-missing, timeout): translated by the Settings app.
    property string reason: ""
    // What the output is to show, as the slot model of Wallpaper.qml takes it: {kind: "art" | "color" | "picture", color, url,
    // strip}. Replaced as a whole on every SUCCESSFUL outcome only (the artwork, a colour, a prepared picture); a failure
    // or a pending preparation never changes it, so the screen keeps whatever it shows.
    property var display: ({kind: "art", color: "", url: "", strip: null})
    // file: URL of the prepared picture, "" for the artwork or a colour.
    property string imageUrl: ""
    property string currentFile: ""
    // Strip statistics of the prepared picture ({rows, all, left, right}), null without a picture.
    property var strip: null
    // File name of the picture shown (Settings caption).
    property string label: ""
    // The transcode under way, 0..1 (-1: none). Published for Settings' progress row.
    property real progress: -1
    // The transcoded H.264 file of a video wallpaper on screen ("" for anything else).
    property string videoFile: ""
    property var files: []
    property var bad: ({})
    property int generation: 0
    // Observable by tests.
    property int started: 0
    property int cancelled: 0

    // The first apply of this feed has happened; the video path of the previous apply ("" when it was not a video).
    property bool appliedOnce: false
    property string lastVideoPath: ""

    property string identity: ""
    property string currentSrc: ""
    property bool advanceRequested: false
    property bool completed: false

    // The settings are read too (Entrance.settingsFinal: read, or the bound ran out): before that `cfg` is the defaults, and
    // the feed would answer with the default artwork, the first frame, ahead of the configured wallpaper.
    readonly property bool ready: WallpaperState.stateReady && WallpaperState.toolChecked && Entrance.settingsFinal

    onCfgKeyChanged: schedule()
    onReadyChanged: schedule()
    Component.onCompleted: {
        completed = true;
        schedule();
    }

    function schedule(): void {
        if (completed && ready)
            debounce.restart();
    }

    Timer {
        id: debounce
        interval: Tokens.wallpaperChangeDebounceMs
        onTriggered: root.apply()
    }

    // The carousel clock: only a folder with a timed interval.
    Timer {
        interval: Math.max(1000, WallpaperConfig.intervalMs(root.cfg.interval))
        repeat: true
        running: root.ready && root.cfg.source === "folder" && WallpaperConfig.intervalMs(root.cfg.interval) > 0 && root.files.length > 1
        onTriggered: root.requestAdvance()
    }

    // ---- jobs: one WallpaperJob (one Process) per request ----
    Component {
        id: jobFactory
        WallpaperJob {}
    }

    property var activeJob: null

    function startJob(kind: string, args: var, timeoutMs: int, streaming: bool): void {
        if (!args) {
            fail("invalid-path");
            return;
        }
        const job = jobFactory.createObject(root, {
            token: generation,
            kind: kind,
            timeoutMs: timeoutMs,
            command: args,
            streaming: streaming === true,
            progressCallback: root.jobProgress,
            callback: root.jobFinished
        }) as WallpaperJob;
        activeJob = job;
        started++;
        job.start();
    }

    // A newer request: the running job is told to stop and its answer will be ignored (the token no longer matches).
    // This output's turn at the transcode (WallpaperState.transcodeOwner).
    property bool transcodeWaiting: false
    property bool transcoding: false
    function releaseTranscode(): void {
        if (root.transcoding) {
            root.transcoding = false;
            if (WallpaperState.transcodeOwner === root.outputName)
                WallpaperState.transcodeOwner = "";
        }
    }
    Connections {
        target: WallpaperState
        function onTranscodeOwnerChanged(): void {
            if (root.transcodeWaiting && WallpaperState.transcodeOwner === "")
                root.startTranscode();
        }
    }
    Component.onDestruction: releaseTranscode()

    function supersede(): void {
        releaseTranscode();
        transcodeWaiting = false;
        generation++;
        if (activeJob && activeJob.running) {
            cancelled++;
            activeJob.stop(15);
        }
        activeJob = null;
    }

    // ---- states ----
    function publish(): void {
        WallpaperState.report(outputName, {
            state: status,
            reason: reason,
            source: cfg.source,
            path: cfg.path,
            name: label,
            files: files.length,
            // The picture on screen: for a video wallpaper its poster frame (the lock screen's still).
            file: status === "ready" || (status === "error" && currentFile !== "") ? currentFile : "",
            video: videoFile,
            // 0..1 while a video is being transcoded, -1 otherwise.
            progress: progress,
            // The phase of the day the Grassfield artwork shows (ADR-0040 IQ-W1 C; Settings' preview draws the same variant).
            phase: DayPhase.shown
        });
    }

    Connections {
        target: DayPhase
        function onShownChanged(): void {
            if (root.cfg.source === "builtin")
                root.publish();
        }
    }

    function showNone(state: string): void {
        status = state;
        reason = "";
        imageUrl = "";
        currentFile = "";
        strip = null;
        label = "";
        files = [];
        identity = "";
        currentSrc = "";
        progress = -1;
        videoFile = "";
        display = {kind: state === "color" ? "color" : "art", color: state === "color" ? cfg.color : "", url: "", strip: null, video: ""};
        publish();
    }

    function fail(why: string): void {
        // The journal keeps every failure (the owner reads it in a live session), the Settings pane shows the reason.
        console.warn("wallpaper: " + outputName + ": " + why + (currentSrc !== "" ? " (" + currentSrc + ")" : ""));
        // The reason first: whoever reacts to the status reads it (the desktop's "the source failed (…)" line).
        reason = why;
        status = "error";
        progress = -1;
        publish();
    }

    // ---- the request ----
    function apply(): void {
        supersede();
        advanceRequested = false;
        const c = cfg;
        // The block of a video that crashed the shell is for the automatic restart only. A change of wallpaper after the shell started
        // is the user's own choice, and a choice is consent to try again: the video left and the video chosen are both unblocked.
        // (The first apply of the shell's life is the automatic one: it keeps the block.)
        const firstApply = !appliedOnce;
        appliedOnce = true;
        const previousVideo = lastVideoPath;
        lastVideoPath = c.source === "video" ? c.path : "";
        if (!firstApply) {
            if (previousVideo !== "" && previousVideo !== lastVideoPath)
                WallpaperState.unblockVideo(previousVideo);
            if (lastVideoPath !== "" && lastVideoPath !== previousVideo)
                WallpaperState.unblockVideo(lastVideoPath);
        }
        if (c.source === "builtin") {
            showNone("builtin");
            return;
        }
        if (c.source === "video") {
            applyVideo();
            return;
        }
        if (c.source === "color") {
            showNone("color");
            return;
        }
        if (c.source === "online") {
            applyOnline();
            return;
        }
        const why = WallpaperConfig.sourceProblem(c.path, WallpaperState.dev, WallpaperState.repoRoot);
        if (why !== "") {
            fail(why === "outside-dev" ? "outside-dev" : "invalid-path");
            return;
        }
        if (WallpaperState.toolMissing) {
            fail("helper-missing");
            return;
        }
        if (c.source === "file") {
            files = [];
            label = fileName(c.path);
            startPrepare(c.path);
        } else {
            startList();
        }
    }

    // The online daily picture: the helper's own file in the cache, prepared for this output like any picture.
    function applyOnline(): void {
        if (WallpaperState.toolMissing) {
            fail("helper-missing");
            return;
        }
        // The cache has not been read yet: what is on screen stays (no flash of the artwork); the feed runs again when it has.
        if (!WallpaperOnline.entryLoaded)
            return;
        const e = WallpaperOnline.entry;
        if (!e) {
            // Nothing cached (yet): the artwork, and Settings says why.
            showNone("builtin");
            status = "waiting";
            publish();
            return;
        }
        const why = WallpaperConfig.sourceProblem(e.file, WallpaperState.dev, WallpaperState.repoRoot);
        if (why !== "") {
            fail(why === "outside-dev" ? "outside-dev" : "invalid-path");
            return;
        }
        files = [];
        label = e.title;
        // The aspect rule (ADR-0016 step 2): within 35 % of the output's aspect the picture fills, any other (a panorama, a
        // portrait) is fitted on its own mean colour.
        const f = WallpaperConfig.onlineFit(e.width, e.height, pixelWidth, pixelHeight, e.mean);
        startPrepare(e.file, f.fit, f.color);
    }

    // The video wallpaper: probe (is it a video, how long, which codec), then transcode with progress.
    function applyVideo(): void {
        const c = cfg;
        const why = WallpaperConfig.sourceProblem(c.path, WallpaperState.dev, WallpaperState.repoRoot);
        if (why !== "") {
            fail(why === "outside-dev" ? "outside-dev" : "invalid-path");
            return;
        }
        if (WallpaperState.toolMissing) {
            fail("helper-missing");
            return;
        }
        files = [];
        label = fileName(c.path);
        currentSrc = c.path;
        status = imageUrl === "" ? "preparing" : status;
        reason = "";
        progress = -1;
        publish();
        startJob("probe", WallpaperConfig.probeArgs(WallpaperState.tool, c.path), Tokens.wallpaperToolTimeoutMs, false);
    }

    function startTranscode(): void {
        // Another output is transcoding: this one waits for its turn (the status stays "preparing").
        if (WallpaperState.transcodeOwner !== "" && WallpaperState.transcodeOwner !== root.outputName) {
            transcodeWaiting = true;
            return;
        }
        transcodeWaiting = false;
        WallpaperState.transcodeOwner = root.outputName;
        transcoding = true;
        progress = 0;
        publish();
        // A video uses Fill or Fit only (WallpaperConfig.settle makes it so).
        startJob("transcode", WallpaperConfig.transcodeArgs(WallpaperState.tool, cfg.path, pixelWidth, pixelHeight, cfg.fit === "fit" ? "fit" : "fill", cfg.color, WallpaperState.videoDir, Tokens.menubarHeight * scale, Tokens.wallpaperCacheMaxBytes, WallpaperState.currentVideoFiles(), Tokens.wallpaperVideoMaxSeconds, Tokens.wallpaperVideoMaxBytes), Tokens.wallpaperVideoToolTimeoutMs, true);
    }

    // The transcode's output so far: its progress lines. Only the job that is current counts.
    function jobProgress(token: int, text: string): void {
        if (token !== generation)
            return;
        const t = WallpaperConfig.transcodeOutput(text);
        if (t.progress >= 0 && t.progress !== progress) {
            progress = t.progress;
            publish();
        }
    }

    function probed(o: var, code: int, timedOut: bool): void {
        if (o && o.ok === true) {
            startTranscode();
            return;
        }
        const id = failureId(o, code, timedOut);
        // The codec or container cannot be read: "This video can't be played".
        fail(id === "unsupported" || id === "unreadable" ? "video-unsupported" : id);
    }

    function transcoded(r: var, code: int, timedOut: bool): void {
        if (r && r.ok === true && typeof r.file === "string" && typeof r.video === "string") {
            const why = typeof r.real === "string" ? WallpaperConfig.sourceProblem(r.real, WallpaperState.dev, WallpaperState.repoRoot) : "";
            if (why === "" && WallpaperConfig.isUnder(r.file, WallpaperState.videoDir) && WallpaperConfig.isUnder(r.video, WallpaperState.videoDir)) {
                const blocked = WallpaperState.isVideoBlocked(cfg.path);
                currentFile = r.file;
                videoFile = r.video;
                strip = r.strip || null;
                imageUrl = "file://" + r.file;
                display = {kind: "picture", color: cfg.color, url: imageUrl, strip: strip, mean: typeof r.mean === "string" ? r.mean : "", video: blocked ? "" : "file://" + r.video, fit: cfg.fit === "fit" ? "fit" : "fill", posterMs: typeof r.posterMs === "number" ? r.posterMs : 0, path: cfg.path};
                progress = -1;
                status = "ready";
                // The poster is shown and the video is not played again: said once, by the Settings pane.
                reason = blocked ? "video-crashed" : "";
                publish();
                return;
            }
            fail("outside-dev");
            return;
        }
        fail(failureId(r, code, timedOut));
    }

    function fileName(path: string): string {
        return path.substring(path.lastIndexOf("/") + 1);
    }

    // `fit` and `color` are the settings' own unless the caller decides (the online aspect rule).
    // `var`, not `string`: an omitted argument of a typed `string` parameter arrives as the text "undefined" (Qt 6.11 and
    // 6.12), which no fit accepts, so every file wallpaper failed with invalid-path ("This path can't be used", rc1-18).
    function startPrepare(path: string, fit: var, color: var): void {
        currentSrc = path;
        status = imageUrl === "" ? "preparing" : status;
        reason = "";
        publish();
        startJob("prepare", WallpaperConfig.prepareArgs(WallpaperState.tool, path, pixelWidth, pixelHeight, typeof fit === "string" && fit !== "" ? fit : cfg.fit, typeof color === "string" && color !== "" ? color : cfg.color, WallpaperState.preparedDir, Tokens.menubarHeight * scale, Tokens.wallpaperCacheMaxBytes, WallpaperState.currentFiles()), Tokens.wallpaperToolTimeoutMs, false);
    }

    function startList(): void {
        startJob("list", WallpaperConfig.listArgs(WallpaperState.tool, cfg.path, Tokens.wallpaperMaxListEntries), Tokens.wallpaperListTimeoutMs, false);
    }

    // The interval elapsed: list again (the folder may have changed) and show the next picture.
    function requestAdvance(): void {
        if (activeJob && activeJob.running)
            return;
        advanceRequested = true;
        generation++;
        startList();
    }

    function jobFinished(token: int, kind: string, code: int, out: string, timedOut: bool): void {
        if (token !== generation)
            return;
        activeJob = null;
        // A transcode prints progress lines before its result: the result is the line that has an exit code.
        if (kind === "transcode") {
            releaseTranscode();
            transcoded(WallpaperConfig.transcodeOutput(out).result, code, timedOut);
            return;
        }
        let o = null;
        try {
            o = JSON.parse(out);
        } catch (e) {
            o = null;
        }
        if (kind === "probe")
            probed(o, code, timedOut);
        else if (kind === "list")
            listed(o, code, timedOut);
        else
            prepared(o, code, timedOut);
    }

    function failureId(o: var, code: int, timedOut: bool): string {
        if (timedOut)
            return "timeout";
        if (o && typeof o.code === "number")
            return WallpaperConfig.reasonOf(o.code);
        // No answer: the helper could not run at all (missing, not executable) or crashed.
        return code === 127 || code === -1 || code === -2 ? "helper-missing" : "failed";
    }

    function listed(o: var, code: int, timedOut: bool): void {
        if (!o || o.ok !== true) {
            const id = failureId(o, code, timedOut);
            // A folder that cannot be read keeps the current picture and is tried again at the next change.
            fail(id === "not-found" || id === "not-regular" || id === "unreadable" || id === "timeout" ? "folder-unavailable" : id);
            return;
        }
        files = o.files;
        if (files.length === 0) {
            fail("folder-empty");
            return;
        }
        pick();
    }

    // Chooses the picture: the one kept in the state while its interval has not elapsed, else the next of the carousel.
    function pick(): void {
        const key = displayKey;
        const folder = cfg.path;
        let state = WallpaperState.carousel(key);
        const sameFolder = state !== null && state.folder === folder;
        if (!sameFolder)
            state = {seed: Math.floor(Math.random() * 2147483647), index: 0, last: "", avoid: "", folder: folder, changedAt: 0};
        const sameSession = identity === folder && currentSrc !== "" && files.indexOf(currentSrc) >= 0;
        const interval = WallpaperConfig.intervalMs(cfg.interval);
        let keep = "";
        if (!advanceRequested) {
            if (sameSession) {
                keep = currentSrc;
            } else if (sameFolder) {
                // After a shell restart: the same picture while its interval has not elapsed; "login" advances only for a
                // new login (another compositor instance), never for a restart of the shell within the same one.
                keep = WallpaperConfig.keepPicture(state, interval, Date.now(), WallpaperState.loginKey, files, bad);
            }
        }
        advanceRequested = false;
        identity = folder;
        if (keep !== "") {
            startPrepare(keep);
            return;
        }
        advanceFrom(state);
    }

    function advanceFrom(state: var): void {
        const r = WallpaperConfig.advance(files, cfg.shuffle, state, bad);
        if (r.file === "") {
            fail("all-failed");
            return;
        }
        const next = r.state;
        next.folder = cfg.path;
        next.changedAt = Date.now();
        next.loginKey = WallpaperState.loginKey;
        WallpaperState.setCarousel(displayKey, next);
        label = fileName(r.file);
        startPrepare(r.file);
    }

    function prepared(o: var, code: int, timedOut: bool): void {
        if (o && o.ok === true && typeof o.file === "string") {
            // Dev guard on the resolved path too: a symlink under .dev must not lead out of it.
            const why = typeof o.real === "string" ? WallpaperConfig.sourceProblem(o.real, WallpaperState.dev, WallpaperState.repoRoot) : "";
            if (why === "" && WallpaperConfig.isUnder(o.file, WallpaperState.preparedDir)) {
                currentFile = o.file;
                strip = o.strip || null;
                imageUrl = "file://" + o.file;
                // `image`: the whole picture's luminance {mean, p5, p95} (the helper's sidecar; absent from older caches): the
                // backdrop of the adaptive glass on a bare desktop (Backdrop.qml).
                // `mean`: the picture's mean colour, its ground (ADR-0040 ID-2).
                display = {kind: "picture", color: "", url: imageUrl, strip: strip, image: o.image || null, mean: typeof o.mean === "string" ? o.mean : "", video: ""};
                videoFile = "";
                progress = -1;
                status = "ready";
                reason = "";
                publish();
                return;
            }
            fail("outside-dev");
            return;
        }
        const id = failureId(o, code, timedOut);
        if (cfg.source === "folder" && files.length > 0 && id !== "helper-missing" && id !== "timeout") {
            // One bad file in a folder: journal only, then the next picture.
            console.warn("wallpaper: skipping " + currentSrc + " (" + id + ")");
            const b = Object.assign({}, bad);
            b[currentSrc] = true;
            bad = b;
            advanceFrom(WallpaperState.carousel(displayKey) || {seed: 1, index: 0, last: "", avoid: ""});
            return;
        }
        fail(id);
    }
}
