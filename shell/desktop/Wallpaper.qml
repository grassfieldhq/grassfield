pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import Grassfield.Ui
import qs.platform
import qs.services

// Desktop wallpaper: the Grassfield artwork, a colour, a picture or a video (WallpaperFeed decides which) on the background
// layer of every screen.
Scope {
    id: root

    // The session is locked (set from shell.qml, as Overview and the switcher get it): a video wallpaper pauses.
    property bool locked: false

    // The measurement's clock and the entrance's bounds start with the desktop (ADR-0040 ID-16, step 6).
    Component.onCompleted: {
        Journal.begin();
        Entrance.begin();
    }

    // Dev-only wallpaper override for tests/visual (contrast on worst-case wallpapers): with
    // GRASSFIELD_DEV=1, GRASSFIELD_WALLPAPER_FILE (initial, trusted: set by the dev scripts) or
    // `qs ipc call wallpaper set <path>` covers the artwork with that image; an empty path restores the artwork.
    // The IPC path must be absolute, end in .png/.jpg/.jpeg and name an existing regular file of at most
    // maxBytes (checked with stat before it is used; `wallpaper status` reports the outcome in plain text).
    // Inert outside dev: every call is refused. The accepted path is kept in VisualFixtures (wallpaperOverride; read
    // back as wallpaperFile, "" outside dev), which the lock screen backdrop draws too.
    // The shell's one dev gate (GRASSFIELD_DEV=1 and no GRASSFIELD_SESSION=1, SEC-03/SEC-04).
    readonly property bool dev: VisualFixtures.dev
    readonly property real maxBytes: 64 * 1024 * 1024
    property string pendingFile: ""
    property string outcome: "idle"
    // Dev hook `qs ipc call wallpaper loadDelay <ms>`: the decode of every new picture starts that late (0 = off).
    property int loadDelayMs: 0
    // Dev hooks `qs ipc call wallpaper videoIdle 1|0|real` and `videoBattery 1|0|real`: the pause policy's idle and battery
    // inputs are forced (a nested test cannot make the compositor idle or unplug a laptop). "" = the real input.
    property string devIdle: ""
    property string devBattery: ""
    // Dev hook `qs ipc call wallpaper fadeLength <ms>`: the crossfade lasts that long (0 = the token), so that a capture lands in it.
    property int fadeLengthMs: 0

    // "" when the path is acceptable for a stat check, else the reason it is refused.
    function pathProblem(path: string): string {
        if (path.charAt(0) !== "/")
            return "path must be absolute";
        if (/[\u0000-\u001f]/.test(path))
            return "path contains control characters";
        if (!/\.(png|jpe?g)$/i.test(path))
            return "only .png, .jpg and .jpeg files are accepted";
        return "";
    }

    // stat output "<file type>|<size>": a regular file under the size cap, or the reason it is refused.
    function statProblem(out: string): string {
        const m = out.trim().match(/^(.*)\|(\d+)$/);
        if (!m)
            return "file not found";
        if (m[1] !== "regular file" && m[1] !== "regular empty file")
            return "not a regular file";
        if (parseInt(m[2]) > maxBytes)
            return "file larger than " + (maxBytes / (1024 * 1024)) + " MB";
        return "";
    }

    Process {
        id: stat
        stdout: StdioCollector {
            onStreamFinished: {
                const why = root.statProblem(text);
                if (why !== "") {
                    root.outcome = "refused: " + why;
                } else {
                    VisualFixtures.wallpaperOverride = root.pendingFile;
                    root.outcome = "applied";
                }
            }
        }
    }

    IpcHandler {
        target: "wallpaper"

        // Dev only: start the decode of every new picture this many ms late (0 = off).
        function loadDelay(ms: int): string {
            if (!root.dev)
                return "refused";
            root.loadDelayMs = Math.max(0, Math.min(5000, ms));
            return "ok";
        }

        // Dev only: the crossfade lasts this many ms (0 = the token).
        function fadeLength(ms: int): string {
            if (!root.dev)
                return "refused";
            root.fadeLengthMs = Math.max(0, Math.min(60000, ms));
            return "ok";
        }

        // Dev only: force the idle input of the video pause policy ("1", "0", or "real").
        function videoIdle(value: string): string {
            if (!root.dev)
                return "refused";
            root.devIdle = value === "1" || value === "0" ? value : "";
            return "ok";
        }

        // Dev only: force the battery input of the video pause policy ("1", "0", or "real").
        function videoBattery(value: string): string {
            if (!root.dev)
                return "refused";
            root.devBattery = value === "1" || value === "0" ? value : "";
            return "ok";
        }

        // Dev only: one line of JSON about the video of an output: the policy and why, whether a frame is decoding, whether the
        // player shows a frame, the video on screen.
        function videoStatus(output: string): string {
            if (!root.dev)
                return "refused";
            for (const w of variants.instances) {
                if (w.modelData && w.modelData.name === output) {
                    const inputs = WallpaperConfig.playbackInputs(root.locked, w.fullscreen, w.idle, w.onBattery, w.effective, Settings.reduceMotion, Settings.materialProfile);
                    return JSON.stringify({policy: w.videoPolicy, reason: WallpaperConfig.playbackState(inputs).reason, playing: w.shown.videoPlaying, shown: w.shown.videoShown, video: w.shown.video, locked: root.locked, fullscreen: w.fullscreen, idle: w.idle, onBattery: w.onBattery});
                }
            }
            return "unknown output";
        }

        // Dev only: where the crossfade of an output is, as the incoming slot's opacity (0 to 1; 0 also while a picture
        // still loads), or -1 when nothing is incoming. Lets a capture test know where its capture sits in the fade.
        function progress(output: string): string {
            if (!root.dev)
                return "refused";
            for (const w of variants.instances) {
                if (w.modelData && w.modelData.name === output)
                    return String(w.incoming !== null ? w.incoming.opacity : -1);
            }
            return "unknown output";
        }

        // Dev only, with the loopback test server (GRASSFIELD_ONLINE_BASE_URL): the online scheduler's clock runs this many hours ahead.
        function onlineClock(hours: int): string {
            return root.dev ? WallpaperOnline.devClock(hours) : "refused";
        }

        // Dev only: the online scheduler's state as JSON.
        function onlineStatus(): string {
            return root.dev ? WallpaperOnline.devStatus() : "refused";
        }

        // Dev only: show this phase of the day ("dawn", "day", "evening", "night"; "" = the real one, ADR-0040 IQ-W1 C).
        function phase(name: string): string {
            if (!root.dev)
                return "refused";
            DayPhase.override = ["dawn", "day", "evening", "night"].indexOf(name) >= 0 ? name : "";
            return DayPhase.shown;
        }

        function set(path: string): string {
            if (!root.dev)
                return "refused";
            if (path === "") {
                VisualFixtures.wallpaperOverride = "";
                root.outcome = "idle";
                return "ok";
            }
            const why = root.pathProblem(path);
            if (why !== "") {
                root.outcome = "refused: " + why;
                return root.outcome;
            }
            root.pendingFile = path;
            root.outcome = "validating";
            stat.command = ["stat", "-L", "-c", "%F|%s", "--", path];
            stat.running = false;
            stat.running = true;
            return "validating";
        }

        // idle | validating | applied | refused: <reason>
        function status(): string {
            return root.dev ? root.outcome : "refused";
        }
    }

    Variants {
        id: variants
        model: Quickshell.screens

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData

            screen: modelData
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            focusable: false
            // The ground under the wallpaper (ADR-0040 ID-2): what a hotplugged output shows before its first frame is drawn.
            color: Ground.of(win.modelData ? win.modelData.name : "")
            // Mapped only once the first frame is drawn (ADR-0040 ID-3).
            visible: win.firstReady
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "grassfield-wallpaper"

            HoverHandler {
                onPointChanged: if (hovered)
                    PointerTracker.report(win.modelData.name, point.position.x, point.position.y)
            }

            // The strip under this output's menu bar decides the bar's foreground (BarTone, per output): reported when a
            // wallpaper becomes dominant (reportTone: the artwork's known gradient, a colour's luminance, a picture's strip
            // statistics from the helper), never per frame. The dev image override (VisualFixtures.wallpaperFile) is grabbed
            // into a small canvas and averaged instead. Nothing is shown of the canvas (it sits under the wallpaper).
            readonly property string imageFile: VisualFixtures.wallpaperFile
            readonly property string imageUrl: imageFile !== "" ? "file://" + imageFile : ""
            function measure(): void {
                if (imageFile !== "") {
                    if (probe.isImageLoaded(imageUrl))
                        probe.requestPaint();
                    else
                        probe.loadImage(imageUrl);
                    return;
                }
                // The override is gone (or never was): the bar follows what is on screen. Before the first frame nothing is on
                // screen: the first frame reports its own tone (showFirst), never the default artwork's first.
                if (win.firstReady)
                    reportTone(toneDesc());
            }
            onImageFileChanged: Qt.callLater(measure)
            onHeightChanged: Qt.callLater(measure)
            // The entrance's key for this output, taken once (modelData is already null when a removed screen destroys the window).
            property string entranceKey: ""
            Component.onCompleted: {
                // The entrance waits for this output's first frame (ADR-0040 step 6: the wallpaper first).
                win.entranceKey = "wallpaper:" + (win.modelData ? win.modelData.name : "");
                Entrance.expect(win.entranceKey);
                Qt.callLater(measure);
                Qt.callLater(win.begin);
            }

            // The whole image is drawn stretched onto a canvas scaled so that the bar's strip is toneSampleRows px tall; only
            // that top strip is read back.
            Canvas {
                id: probe
                z: -1
                width: Tokens.menubarToneSampleColumns
                height: Math.max(Tokens.menubarToneSampleRows, Math.round(win.height * Tokens.menubarToneSampleRows / Tokens.menubarHeight))
                renderTarget: Canvas.Image
                renderStrategy: Canvas.Immediate
                onImageLoaded: requestPaint()
                onPaint: {
                    const url = win.imageUrl;
                    if (url === "" || !isImageLoaded(url))
                        return;
                    const ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    ctx.drawImage(url, 0, 0, width, height);
                    // The canvas keeps its picture at the window's pixel ratio (1.25 on the owner's panel): the whole strip is read, not the
                    // top-left width x rows pixels (about a fifth of it too little on a 1.25 output, half of it on a 2x one).
                    const k = Math.max(1, win.devicePixelRatio);
                    const lum = BarTone.pixelsLuminance(ctx.getImageData(0, 0, Math.round(width * k), Math.round(Tokens.menubarToneSampleRows * k)).data);
                    // The same canvas gives the backdrop of the adaptive glass and of the Dock's icons (ADR-0024 G-3, R7-REQ-13): the whole image's lowest and highest luminance
                    // (one cell of GlassTint.gridOf), so Backdrop.wallpaperUnder answers under the dev override as it does for a picture with statistics.
                    const whole = ctx.getImageData(0, 0, Math.round(width * k), Math.round(height * k));
                    const span = GlassTint.gridOf(whole.data, whole.width, whole.height, 1, 1, win.width, win.height);
                    const range = {lumMin: span.min[0], lumMax: span.max[0]};
                    unloadImage(url);
                    // Not inside the paint: the bar's bindings must change outside the render sync.
                    Qt.callLater(() => {
                        BarTone.report(win.modelData.name, lum);
                        Backdrop.reportWallpaper(win.modelData.name, range);
                    });
                }
            }

            // The luminance grid of what this output shows (ADR-0024 G-3 per surface: the backdrop under each glass surface,
            // GlassTint.gridRange): the shown slot is grabbed small and read back cell by cell when a wallpaper becomes dominant,
            // never per frame. None for a colour (its one luminance is exact), a video or the dev image override.
            property var gridGrab: null
            function measureGrid(desc: var): void {
                if (!win.modelData)
                    return;
                // (Not before the first frame: the window is not mapped yet, nothing can be grabbed; markReady measures again.)
                if (!desc || desc.kind === "color" || (desc.video !== undefined && desc.video !== "") || VisualFixtures.wallpaperFile !== "" || !win.shown || win.width <= 0 || !win.firstReady) {
                    Backdrop.reportGrid(win.modelData.name, null);
                    return;
                }
                win.shown.grabToImage(result => {
                    win.gridGrab = result;
                    if (gridProbe.isImageLoaded(result.url))
                        gridProbe.requestPaint();
                    else
                        gridProbe.loadImage(result.url);
                }, Qt.size(gridProbe.width, gridProbe.height));
            }

            Canvas {
                id: gridProbe
                z: -1
                width: Tokens.glassGridColumns * Tokens.glassGridSample
                height: Tokens.glassGridRows * Tokens.glassGridSample
                renderTarget: Canvas.Image
                renderStrategy: Canvas.Immediate
                onImageLoaded: requestPaint()
                onPaint: {
                    const grab = win.gridGrab;
                    if (!grab || !isImageLoaded(grab.url))
                        return;
                    const ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    ctx.drawImage(grab.url, 0, 0, width, height);
                    // width x height as is, not at the window's ratio: the grab is tagged at the window's ratio, and drawImage to
                    // width x height fills only its top-left 1/ratio of a canvas that has that ratio (tests/unit/tst_wallpapergrab.qml).
                    const grid = GlassTint.gridOf(ctx.getImageData(0, 0, width, height).data, width, height, Tokens.glassGridColumns, Tokens.glassGridRows, win.width, win.height);
                    unloadImage(grab.url);
                    win.gridGrab = null;
                    // Not inside the paint: the glass bindings must change outside the render sync.
                    Qt.callLater(() => Backdrop.reportGrid(win.modelData.name, grid));
                }
            }

            // What the output is to show (the artwork, a colour, a prepared picture), decided from the settings.
            WallpaperFeed {
                id: feed
                screenInfo: win.modelData
                onDisplayChanged: {
                    // Not the feed's initial `display` (the placeholder artwork): the change signal fires once when the feed is
                    // created, before any request (seen in the journal at rc1-16: the default artwork was the first frame).
                    if (!feed.appliedOnce)
                        return;
                    win.feedSeen = true;
                    win.show(win.withArt(feed.display), "normal");
                }
            }

            // ---- the first frame (ADR-0040 step 3, ID-3) ----
            // The window maps with its final first frame: the output's last picture (its still from wallpaper.json, its tone from
            // the stored statistics, so the bar is right before anything shows), once decoded; the artwork or a colour at once; at
            // most wallpaper.firstShowTimeoutMs, then the artwork. Until then the feed's result goes straight into slot A, no fade;
            // a feed result that is the still's file changes nothing; a phase or an appearance known before that result changes
            // nothing either (WallpaperConfig.firstFrameChoice: the result carries them).
            property bool firstReady: false
            // The feed has given its first result (its initial `display` is a placeholder, never shown).
            property bool feedSeen: false
            // The first frame is the artwork because nothing else came in time (the timeout, a still that cannot be read): it
            // follows the phase and the appearance like the feed's own artwork (a feed that never answers leaves it there).
            property bool fallbackArt: false
            readonly property bool artLive: win.feedSeen || win.fallbackArt
            function stillDesc(): var {
                const st = win.modelData && Entrance.settingsFinal ? WallpaperState.stillOf(win.modelData.name) : null;
                // Only the still of the wallpaper now chosen (settings read): any other would show first and change after.
                if (st !== null && !WallpaperConfig.stillMatches(st, WallpaperConfig.sourceKey(feed.cfg)))
                    return null;
                return st ? {kind: "picture", color: "", url: "file://" + st.file, strip: st.strip, image: st.image, mean: st.mean, video: ""} : null;
            }
            function begin(): void {
                if (win.firstReady)
                    return;
                const still = win.stillDesc();
                const choice = WallpaperConfig.firstFrameChoice(win.feedSeen, WallpaperState.stateReady, still !== null);
                if (choice === "feed")
                    win.showFirst(win.withArt(feed.display));
                else if (choice === "still")
                    win.showFirst(still);
            }
            function showFirst(desc: var): void {
                // The feed's result is the still already in slot A: nothing changes (its description is the fuller one).
                if (slotA.kind === desc.kind && sameContent(desc, shownDesc) && (desc.kind !== "picture" || slotA.url === desc.url)) {
                    shownDesc = desc;
                    if (desc.kind !== "picture" || slotA.pictureReady)
                        win.markReady();
                    return;
                }
                loadTimer.stop();
                fadeIn.stop();
                incoming = null;
                pendingDesc = null;
                fadePending = false;
                shown = slotA;
                slotA.z = 2;
                slotB.opacity = 0;
                shownDesc = desc;
                slotA.kind = desc.kind;
                if (desc.kind === "color")
                    slotA.color = desc.color;
                if (desc.kind === "art") {
                    slotA.artwork = desc.artwork || "grassfield";
                    slotA.variant = desc.variant || "evening.dark";
                }
                slotA.video = desc.video || "";
                slotA.videoFit = desc.fit || "fill";
                slotA.posterMs = desc.posterMs || 0;
                slotA.videoPath = desc.path || "";
                reportTone(desc);
                if (desc.kind === "picture") {
                    slotA.url = desc.url;
                    if (slotA.pictureReady)
                        win.markReady();
                } else {
                    slotA.url = "";
                    win.markReady();
                }
            }
            function markReady(): void {
                if (win.firstReady)
                    return;
                win.firstReady = true;
                firstTimer.stop();
                shownOnce = true;
                win.settled(win.shownDesc, win.shown);
                // The window maps now: what needs its size (the glass grid) is measured again.
                Qt.callLater(win.measure);
                console.info("grassfield-shell: wallpaper first " + win.shownDesc.kind + (win.shownDesc.kind === "art" ? " " + (win.shownDesc.artwork || "grassfield") + " " + (win.shownDesc.variant || "evening.dark") : "") + " source=" + feed.cfg.source + " output=" + (win.modelData ? win.modelData.name : ""));
                Journal.shown("wallpaper", win.modelData ? win.modelData.name : "");
                Entrance.ready(win.entranceKey);
            }
            // What is on screen now is final: its ground (ADR-0040 ID-2) and its record in wallpaper.json (`shown`: the first frame
            // of the next start, ID-3, and the lock's backdrop, ID-7; with the artwork it would draw instead).
            function settled(desc: var, slot: WallpaperSlot): void {
                if (!win.modelData)
                    return;
                Ground.report(win.modelData.name, WallpaperConfig.groundOf(desc, slot.artPalette.ground, Tokens.sessionGround));
                WallpaperState.setShown(win.modelData.name, desc, {artwork: feed.cfg.artwork, variant: win.artVariant, src: WallpaperConfig.sourceKey(feed.cfg)});
            }
            // The default artwork is a FALLBACK for a source that failed, never a replacement for a wallpaper that is still
            // loading (macOS: the owner's picture or its poster from the first frame). The desktop picture comes first and the
            // bar, the Dock and the icons after it, together (ADR-0040 P-3): a slow picture holds the entrance (its own hard
            // bound ends the hold if the picture never comes); only a failed source shows the artwork, and with it the bars.
            // No decode is ever cancelled.
            function artFallback(why: string): void {
                if (win.firstReady)
                    return;
                console.warn("wallpaper: " + (win.modelData ? win.modelData.name : "") + ": " + why + "; the artwork shows");
                win.fallbackArt = true;
                Entrance.noteWallpaperFailed();
                win.showFirst(win.withArt({kind: "art", color: "", url: "", strip: null, video: ""}));
            }
            Timer {
                id: firstTimer
                interval: Tokens.wallpaperFirstShowTimeoutMs
                running: true
                onTriggered: {
                    if (win.firstReady)
                        return;
                    if (WallpaperConfig.firstFrameStep("bound", feed.status, feed.appliedOnce, win.firstReady) === "fallback") {
                        win.artFallback("the first frame took longer than " + interval + " ms and the source failed");
                        return;
                    }
                    // Still loading: nothing is painted and nothing is released (the entrance waits, P-3).
                    console.info("grassfield-shell: wallpaper " + (win.modelData ? win.modelData.name : "") + " still loading after " + interval + " ms");
                }
            }
            Connections {
                target: feed
                // The source failed (an error, a missing file, a failed transcode) before anything was shown: the artwork.
                function onStatusChanged(): void {
                    if (WallpaperConfig.firstFrameStep("status", feed.status, feed.appliedOnce, win.firstReady) === "fallback")
                        win.artFallback("the source failed (" + feed.reason + ")");
                }
            }
            Connections {
                target: WallpaperState
                function onStateReadyChanged(): void {
                    win.begin();
                }
            }
            Connections {
                target: Entrance
                function onSettingsFinalChanged(): void {
                    win.begin();
                }
            }
            Component.onDestruction: {
                if (win.firstReady)
                    Journal.hidden("wallpaper", win.modelData ? win.modelData.name : "");
                else
                    Entrance.forget(win.entranceKey);
            }

            // The output's height: the window's own is not known before it maps (the first frame's tone is reported before).
            readonly property real fullHeight: win.modelData ? win.modelData.height : win.height

            // ---- the artwork's variant (ADR-0040 section 2): the choice, the appearance and the phase of the day ----
            readonly property string artVariant: WallpaperConfig.artworkVariantFor(feed.cfg.artwork, feed.cfg.artworkVariant, Appearance.dark, DayPhase.shown)
            function withArt(desc: var): var {
                return desc && desc.kind === "art" ? Object.assign({}, desc, {artwork: feed.cfg.artwork, variant: win.artVariant}) : desc;
            }
            // A new phase: a slow crossfade (wallpaper.phaseFadeMs), never under a full-screen window (it waits for it to go).
            // A new appearance: the usual crossfade, the tone switching at its midpoint (ID-14).
            // Only once the feed has given its first result (its initial `display` is a placeholder artwork, review of
            // c5d43be4): that result carries the phase and the appearance known by then (withArt).
            property bool phaseWaiting: false
            // The phase as last seen: the first one known (at start) is a cut, not a change.
            property string lastPhase: DayPhase.shown
            Connections {
                target: DayPhase
                function onShownChanged(): void {
                    const first = win.lastPhase === "";
                    win.lastPhase = DayPhase.shown;
                    if (win.artLive && feed.display.kind === "art") {
                        if (first)
                            win.show(win.withArt(feed.display), "cut");
                        else
                            win.showPhase();
                    }
                }
            }
            Connections {
                target: Appearance
                function onDarkChanged(): void {
                    if (win.artLive && feed.display.kind === "art")
                        win.show(win.withArt(feed.display), "appearance");
                }
            }
            function showPhase(): void {
                win.phaseWaiting = win.fullscreen;
                if (!win.phaseWaiting)
                    win.show(win.withArt(feed.display), "phase");
            }
            onFullscreenChanged: {
                if (!win.fullscreen && win.phaseWaiting && win.artLive && feed.display.kind === "art")
                    win.showPhase();
            }

            // ---- ONE two-slot model for every kind of wallpaper (the artwork, a colour, a picture) ----
            // `shown` is the slot on screen, `incoming` the one being prepared. Rules, the same for every kind:
            //   - the incoming slot is on top (z 2), the shown one below (z 1) and fully visible until the fade completes;
            //   - the incoming slot becomes visible only when it is ready: the artwork and a colour at once, a picture once
            //     its Image is Ready (decoded off the GUI thread); a request replaces a pending one in the same slot;
            //   - it crossfades over the outgoing slot (one fixed length; a plain switch with Reduce Motion);
            //   - a failure (a picture that cannot be decoded, a file the helper refused) keeps whatever is on screen;
            //   - nothing else sets the opacity of a layer from the REQUESTED state: only the fade does.
            property WallpaperSlot shown: slotA
            property WallpaperSlot incoming: null
            property var shownDesc: ({kind: "art", artwork: "grassfield", variant: "evening.dark", color: "", url: "", strip: null, video: ""})

            // ---- the pause policy of a video wallpaper (ADR-0016 section 5), re-evaluated by every event ----
            // Nothing polls: the lock state, the compositor's full-screen state of this output, the idle monitor, UPower and the
            // settings each notify. The idle monitor only exists while a video is wanted, and it is NOT an inhibitor (a
            // wallpaper never creates one, so the idle lock still fires while a video plays); it ignores inhibitors because it
            // asks whether the user is away, not whether the session may sleep.
            readonly property bool videoWanted: shownDesc.video !== undefined && shownDesc.video !== ""
            readonly property bool fullscreen: win.modelData ? Compositor.fullscreenOn(win.modelData.name, Compositor.topologyRevision) : false
            readonly property var effective: feed.cfg
            readonly property bool idle: root.devIdle !== "" ? root.devIdle === "1" : idleMonitor.isIdle
            readonly property bool onBattery: root.devBattery !== "" ? root.devBattery === "1" : UPower.onBattery
            readonly property string videoPolicy: WallpaperConfig.playbackState(WallpaperConfig.playbackInputs(root.locked, fullscreen, idle, onBattery, feed.cfg, Settings.reduceMotion, Settings.materialProfile)).state

            IdleMonitor {
                id: idleMonitor
                enabled: win.videoWanted
                timeout: Tokens.wallpaperVideoIdleSeconds
                respectInhibitors: false
            }
            property var pendingDesc: null
            property bool fadePending: false

            WallpaperSlot {
                id: slotA
                z: 1
                opacity: 1
                moving: feed.cfg.moving === true
                // Still on the desktop: its clouds where the last lock left them (ADR-0040 step 9; WallpaperSlot.qml).
                motionMs: WallpaperState.motionOf(win.modelData ? win.modelData.name : "")
                pictureSize: Qt.size(feed.pixelWidth, feed.pixelHeight)
                onScreen: win.shown === slotA
                playPolicy: win.videoPolicy
                markerOwner: feed.outputName
                onPictureLoaded: win.slotLoaded(slotA)
                onPictureFailed: win.slotFailed(slotA)
                onVideoFailed: message => console.warn("wallpaper: " + feed.outputName + ": the video stopped: " + message)
            }

            WallpaperSlot {
                id: slotB
                z: 1
                moving: feed.cfg.moving === true
                // Still on the desktop: its clouds where the last lock left them (ADR-0040 step 9; WallpaperSlot.qml).
                motionMs: WallpaperState.motionOf(win.modelData ? win.modelData.name : "")
                pictureSize: Qt.size(feed.pixelWidth, feed.pixelHeight)
                onScreen: win.shown === slotB
                playPolicy: win.videoPolicy
                markerOwner: feed.outputName
                onPictureLoaded: win.slotLoaded(slotB)
                onPictureFailed: win.slotFailed(slotB)
                onVideoFailed: message => console.warn("wallpaper: " + feed.outputName + ": the video stopped: " + message)
            }

            function sameContent(a: var, b: var): bool {
                return a.kind === b.kind && (a.kind !== "color" || a.color === b.color) && (a.kind !== "art" || ((a.artwork || "") === (b.artwork || "") && (a.variant || "") === (b.variant || ""))) && (a.kind !== "picture" || (a.url === b.url && (a.video || "") === (b.video || "")));
            }

            // "normal" | "phase" (a slow fade) | "appearance" (the tone at the midpoint) | "cut": how the next change shows.
            property string fadeMode: "normal"
            // Nothing has been shown yet: the first content cuts in (no fade from the default artwork).
            property bool shownOnce: false
            function show(desc: var, mode: string): void {
                // Before the first frame: the first-frame choice decides (a phase or an appearance alone changes nothing).
                if (!win.firstReady) {
                    win.begin();
                    return;
                }
                // A fade in flight is complete at once: its content is ready (a fade only starts then).
                if (fadeIn.running)
                    finishFade();
                if (sameContent(desc, shownDesc)) {
                    cancelPending();
                    // The output's first wallpaper is already on screen: later changes fade.
                    shownOnce = true;
                    // The feed's own description of the still on screen (its statistics are the helper's, fresh): tone, ground, record.
                    if (desc.kind === "picture" && desc !== shownDesc) {
                        shownDesc = desc;
                        reportTone(desc);
                        win.settled(desc, shown);
                    }
                    return;
                }
                if (incoming === null) {
                    incoming = shown === slotA ? slotB : slotA;
                    shown.z = 1;
                    incoming.z = 2;
                    incoming.opacity = 0;
                }
                // A newer request replaces the pending one in the same slot; what is on screen is not touched.
                pendingDesc = desc;
                fadePending = true;
                fadeMode = mode;
                incoming.kind = desc.kind;
                if (desc.kind === "color")
                    incoming.color = desc.color;
                if (desc.kind === "art") {
                    incoming.artwork = desc.artwork || "grassfield";
                    incoming.variant = desc.variant || "evening.dark";
                }
                // A video wallpaper: the slot plays it once it is on screen (its poster is the picture that fades in).
                incoming.video = desc.video || "";
                incoming.videoFit = desc.fit || "fill";
                incoming.posterMs = desc.posterMs || 0;
                incoming.videoPath = desc.path || "";
                if (desc.kind === "picture") {
                    // Dev hook `wallpaper loadDelay <ms>`: the decode is started late, to test changes that arrive faster.
                    if (root.loadDelayMs > 0) {
                        console.info("wallpaper: decode of the next picture delayed by " + root.loadDelayMs + " ms (dev hook)");
                        loadTimer.restart();
                    } else {
                        startLoad();
                    }
                } else {
                    loadTimer.stop();
                    incoming.url = "";
                    beginFade();
                }
            }

            function startLoad(): void {
                if (incoming === null || pendingDesc === null || pendingDesc.kind !== "picture")
                    return;
                incoming.url = pendingDesc.url;
                if (incoming.pictureReady)
                    beginFade();
            }

            Timer {
                id: loadTimer
                interval: root.loadDelayMs
                onTriggered: win.startLoad()
            }

            // The pending request goes away (the screen already shows what is wanted): what is on screen stays as it is.
            function cancelPending(): void {
                loadTimer.stop();
                fadePending = false;
                pendingDesc = null;
                toneDone = false;
                if (incoming !== null) {
                    incoming.url = "";
                    incoming.video = "";
                    incoming.opacity = 0;
                    incoming = null;
                }
            }

            function slotLoaded(slot: WallpaperSlot): void {
                // The first frame's picture is decoded: the window maps.
                if (!win.firstReady) {
                    if (slot === slotA && win.shownDesc.kind === "picture" && slot.url === win.shownDesc.url)
                        win.markReady();
                    return;
                }
                // Only the picture that is wanted NOW may start a fade: a decode that a newer request superseded (its slot
                // still holds the old url, or the dev hook has not started the new decode yet) never does.
                // (The signal itself says the Image is Ready for a non-empty url; the slot's own `pictureReady` binding may not
                // have been re-evaluated yet when the handler runs, so it is not read here.)
                if (slot === incoming && fadePending && pendingDesc !== null && pendingDesc.kind === "picture" && slot.url === pendingDesc.url)
                    beginFade();
            }

            function slotFailed(slot: WallpaperSlot): void {
                // The first frame's picture cannot be read: the artwork shows instead.
                if (!win.firstReady && slot === slotA) {
                    console.warn("wallpaper: cannot load the first frame " + slot.url + "; the artwork shows");
                    win.fallbackArt = true;
                    win.showFirst(win.withArt({kind: "art", color: "", url: "", strip: null, video: ""}));
                    return;
                }
                if (slot !== incoming || !fadePending)
                    return;
                // The previous wallpaper stays.
                console.warn("wallpaper: cannot load " + slot.url);
                cancelPending();
            }

            // The incoming slot is ready. One fixed crossfade (macOS: a crossfade of fixed length); Reduce Motion: a plain
            // switch. P3 for the fade is measured on real hardware with real frame timing (owner L2, docs/specs/desktop.md).
            function beginFade(): void {
                fadePending = false;
                // (The dev hook `wallpaper fadeLength <ms>` lengthens the fade so that a capture lands inside it.)
                const ms = Settings.reduceMotion || !shownOnce || fadeMode === "cut" ? 0 : (root.fadeLengthMs > 0 ? root.fadeLengthMs : (fadeMode === "phase" ? Tokens.wallpaperPhaseFadeMs : Tokens.wallpaperCrossfadeMs));
                if (ms === 0) {
                    incoming.opacity = 1;
                    completeFade();
                    return;
                }
                // Two artworks blend for the whole fade: the band covers the moments neither tone reads (gate A2).
                if (shownDesc.kind === "art" && pendingDesc.kind === "art" && win.modelData && win.fullHeight > 0)
                    BarTone.reportArtFade(win.modelData.name, Qt.color(shown.art.skyTop), Qt.color(shown.art.skyMid), Tokens.menubarHeight / (shown.artPalette.tone.at * win.fullHeight), Qt.color(incoming.art.skyTop), Qt.color(incoming.art.skyMid), Tokens.menubarHeight / (incoming.artPalette.tone.at * win.fullHeight), win.toneSwitchAt);
                // The bar's tone follows the new wallpaper once it dominates: from the fade's own progress (the incoming
                // slot's opacity reaching 60 %), not from a timer (a fade is frame-driven, a timer is not).
                toneDone = false;
                fadeIn.duration = ms;
                fadeIn.target = incoming;
                fadeIn.restart();
            }

            // A fade in flight is completed at once when the next change arrives.
            function finishFade(): void {
                fadeIn.stop();
                if (incoming !== null) {
                    incoming.opacity = 1;
                    completeFade();
                }
            }

            function completeFade(): void {
                if (win.modelData)
                    BarTone.endArtFade(win.modelData.name);
                shownOnce = true;
                const old = shown;
                shown = incoming;
                shownDesc = pendingDesc;
                incoming = null;
                pendingDesc = null;
                // The next pending picture has not dominated anything yet (toneDesc must not report it while it loads).
                toneDone = false;
                if (old !== shown) {
                    old.opacity = 0;
                    old.url = "";
                    old.video = "";
                }
                // The tone of the wallpaper that is on screen now.
                reportTone(shownDesc);
                win.settled(shownDesc, shown);
            }

            function reportTone(desc: var): void {
                if (!win.modelData)
                    return;
                // The backdrop of the adaptive glass (ADR-0024 G-3): the luminance range of what is on screen, when known.
                const slot = desc === win.pendingDesc && win.incoming !== null ? win.incoming : win.shown;
                // (Under the dev image override the probe canvas reports the range once it has read the image.)
                if (VisualFixtures.wallpaperFile === "")
                    Backdrop.reportWallpaper(win.modelData.name, Backdrop.rangeOf(desc, slot.art));
                win.measureGrid(desc);
                if (VisualFixtures.wallpaperFile !== "")
                    return;
                // The tone comes from the pixels of what is on screen: a picture's or a video's own strip (the helper measured the
                // video's poster and sampled frames), never the artwork's gradient.
                const source = BarTone.toneSource(desc);
                if (source === "strip")
                    BarTone.reportStrip(win.modelData.name, desc.strip);
                else if (source === "color")
                    BarTone.reportColor(win.modelData.name, Qt.color(desc.color));
                else if (source === "none")
                    BarTone.reportUnmeasured(win.modelData.name);
                else if (win.fullHeight > 0)
                    BarTone.reportGradient(win.modelData.name, Qt.color(slot.art.skyTop), Qt.color(slot.art.skyMid), Tokens.menubarHeight / (slot.artPalette.tone.at * win.fullHeight));
            }

            NumberAnimation {
                id: fadeIn
                property: "opacity"
                from: 0
                to: 1
                onFinished: win.completeFade()
            }

            // The bar's tone switches when the incoming wallpaper dominates: 60 % of the crossfade's own progress; at the midpoint
            // for a change of appearance (ADR-0040 ID-14).
            property bool toneDone: false
            readonly property real toneSwitchAt: fadeMode === "appearance" ? 0.5 : 0.6
            Connections {
                target: win.incoming
                ignoreUnknownSignals: true

                function onOpacityChanged(): void {
                    if (!win.toneDone && win.incoming !== null && fadeIn.running && win.incoming.opacity >= win.toneSwitchAt && win.pendingDesc !== null) {
                        win.toneDone = true;
                        win.reportTone(win.pendingDesc);
                    }
                }
            }

            // The wallpaper whose tone the bar should show: the incoming one once it dominates its fade, else the shown one.
            function toneDesc(): var {
                return incoming !== null && toneDone && pendingDesc !== null ? pendingDesc : shownDesc;
            }

            Image {
                anchors.fill: parent
                // On top of the two slots (z 1 and 2): the contrast run covers whatever the wallpaper shows.
                z: 10
                visible: VisualFixtures.wallpaperFile !== ""
                source: VisualFixtures.wallpaperFile !== "" ? "file://" + VisualFixtures.wallpaperFile : ""
                fillMode: Image.Stretch
                sourceSize: Qt.size(win.width, win.height)
                cache: false
                smooth: false
            }
        }
    }
}
