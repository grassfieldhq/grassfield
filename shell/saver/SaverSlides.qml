pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.desktop
import qs.services

// The slideshow's pictures for one display (ADR-0032): the folder is listed and each picture prepared at the display's size by
// grassfield-wallpaper, as the folder wallpaper does (the shell decodes only the helper's output, ADR-0016). The order is the
// wallpaper carousel's shuffle without repeat (WallpaperConfig.advance). Works only while `running` (the saver shows); a new
// start lists the folder again. `url` is the picture to show ("" until the first is ready); `empty` turns on when the folder
// cannot be read, has no picture or every picture failed (the saver then shows the artwork).
Scope {
    id: root

    required property var screenInfo
    property string folder: ""
    property bool running: false
    // Prepared files the cache pruning must keep besides the wallpapers' and this display's slide (the other displays').
    property var keepAlso: []

    readonly property real scale: screenInfo && screenInfo.devicePixelRatio > 0 ? screenInfo.devicePixelRatio : 1
    readonly property int pixelWidth: Math.max(1, Math.round((screenInfo ? screenInfo.width : 0) * scale))
    readonly property int pixelHeight: Math.max(1, Math.round((screenInfo ? screenInfo.height : 0) * scale))

    property string url: ""
    property bool empty: false
    property var files: []
    property var bad: ({})
    property var carousel: null
    property string currentFile: ""
    // The picture being prepared (skipped for this run when it fails).
    property string pending: ""
    property int generation: 0
    property var activeJob: null

    onRunningChanged: {
        generation++;
        watchdog.stop();
        if (activeJob && activeJob.running)
            activeJob.stop(15);
        activeJob = null;
        if (!running)
            return;
        empty = false;
        bad = {};
        list();
    }

    function startJob(kind: string, args: var, timeoutMs: int): void {
        if (!args) {
            empty = true;
            return;
        }
        const job = jobFactory.createObject(root, {
            token: generation,
            kind: kind,
            timeoutMs: timeoutMs,
            command: args,
            callback: root.jobFinished
        }) as WallpaperJob;
        activeJob = job;
        watchdog.interval = timeoutMs + Tokens.saverSlideFadeMs;
        watchdog.restart();
        job.start();
    }

    function list(): void {
        // The dev guard of the wallpaper (a dev shell reads only under the worktree's .dev); a helper that is not installed
        // (a process that cannot start never answers: the feed checks the same).
        if (WallpaperState.toolMissing || WallpaperConfig.sourceProblem(folder, WallpaperState.dev, WallpaperState.repoRoot) !== "") {
            empty = true;
            return;
        }
        startJob("list", WallpaperConfig.listArgs(WallpaperState.tool, folder, Tokens.wallpaperMaxListEntries), Tokens.wallpaperListTimeoutMs);
    }

    // The next picture, prepared at the display's size, filling it.
    function next(): void {
        if (!running || (activeJob && activeJob.running) || files.length === 0)
            return;
        const r = WallpaperConfig.advance(files, true, carousel || {seed: Math.floor(Math.random() * 2147483647), index: 0, last: "", avoid: ""}, bad);
        if (r.file === "") {
            empty = url === "";
            return;
        }
        carousel = r.state;
        const keep = WallpaperState.currentFiles().concat(keepAlso.filter(f => typeof f === "string" && f !== ""));
        if (currentFile !== "")
            keep.push(currentFile);
        startJob("prepare", WallpaperConfig.prepareArgs(WallpaperState.tool, r.file, pixelWidth, pixelHeight, "fill", "#000000", WallpaperState.preparedDir, 0, Tokens.wallpaperCacheMaxBytes, keep), Tokens.wallpaperToolTimeoutMs);
        pending = r.file;
    }

    function jobFinished(token: int, kind: string, code: int, out: string, timedOut: bool): void {
        if (token !== generation)
            return;
        activeJob = null;
        watchdog.stop();
        let o = null;
        try {
            o = JSON.parse(out);
        } catch (e) {
            o = null;
        }
        if (kind === "list") {
            files = o && o.ok === true && Array.isArray(o.files) ? o.files : [];
            if (files.length === 0) {
                empty = true;
                return;
            }
            next();
            return;
        }
        // A prepared picture is shown only when it is the helper's own file under the cache (and, in a dev shell, came from .dev).
        const why = o && typeof o.real === "string" ? WallpaperConfig.sourceProblem(o.real, WallpaperState.dev, WallpaperState.repoRoot) : "";
        if (o && o.ok === true && typeof o.file === "string" && why === "" && WallpaperConfig.isUnder(o.file, WallpaperState.preparedDir)) {
            currentFile = o.file;
            url = "file://" + o.file;
            return;
        }
        // A picture that fails is skipped for this run; the next one is tried at once.
        const skipped = Object.assign({}, bad);
        skipped[pending] = true;
        bad = skipped;
        next();
    }

    // A job that never answers (its process did not start): the slideshow gives up for this run, the artwork shows.
    Timer {
        id: watchdog
        onTriggered: {
            root.generation++;
            // The job is not left behind: a process still running is stopped (the job destroys itself once it has exited),
            // a job whose process never ran is destroyed here.
            if (root.activeJob) {
                if (root.activeJob.running)
                    root.activeJob.stop(15);
                else
                    root.activeJob.destroy();
            }
            root.activeJob = null;
            if (root.url === "")
                root.empty = true;
        }
    }

    Timer {
        interval: Tokens.saverSlideIntervalMs
        repeat: true
        running: root.running && root.url !== ""
        onTriggered: root.next()
    }

    Component {
        id: jobFactory
        WallpaperJob {}
    }
}
