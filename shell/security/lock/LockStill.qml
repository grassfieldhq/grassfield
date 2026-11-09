pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui

// The lock's backdrop for one output, ready before it is needed (ADR-0040 step 4a, ID-7; ADR-0016 section 6, W8). Display
// only: nothing here can lock, unlock or keep the lock from engaging, and no lock waits for it.
//
// What the desktop last showed on the output (LockWallpaper.lockBackdrop, the security process's own reader of wallpaper.json
// `shown`: a plain cache name in the prepared or video folder for a picture) is decided while the session is unlocked, when the wallpaper changes, never when it
// locks: a picture is checked here (its real path, `realpath -m` with the two cache folders' own real paths, a plain cache
// name directly in one of them; a regular file of at most wallpaper.lockStillMaxBytes, `stat %f|%s`, the raw mode, which
// no locale translates; both run by absolute path, by argument vector, never a shell) and then decoded by the
// Image below, which keeps the decoded picture in Qt's pixmap cache: a lock surface asking for the same url gets it at once,
// already decoded. No sourceSize on either side: the helper prepared the picture at the output's physical size, and a
// sourceSize would key the cache on each window's scale; Qt's image allocation limit bounds a file that is not what it should
// be. Any failure (a file that is gone, outside the cache, too large, not decodable, a check that hangs) gives the artwork.
// No user original and no video decoder ever enters the module: only the helper's own JPEG or PNG.
//
// `backdrop` is null until decided, then {kind: "picture", still: url} | {kind: "color", color} | {kind: "art"}, each with the
// artwork and variant to draw underneath (the picture's fallback). A lock surface adopts the first decided value it sees and
// keeps it (LockView.adopt): once the lock shows, nothing on it changes.
Item {
    id: root

    required property ShellScreen modelData
    // The reader of wallpaper.json (LockWallpaper, one for every output: LockStills).
    required property var wallpaper
    readonly property string output: modelData ? modelData.name : ""
    // What the desktop shows on this output now (null: nothing yet).
    readonly property var wanted: root.wallpaper ? root.wallpaper.lockBackdrop(root.output) : null

    property var backdrop: null
    // The picture asked for (the record's file), its real path once checked, and the request they belong to (a newer one
    // supersedes it: answers of an older request are dropped).
    property string requested: ""
    property string pending: ""
    property int generation: 0

    onWantedChanged: Qt.callLater(root.decide)
    Component.onCompleted: root.decide()

    function art(w: var): var {
        return {kind: w.kind === "color" ? "color" : "art", still: "", color: w.kind === "color" ? w.color : "", artwork: w.artwork, variant: w.variant};
    }

    function decide(): void {
        const w = root.wanted;
        if (w === null) {
            // Nothing shown on the output yet: undecided (a lock surface waits, bounded, then draws the artwork).
            root.reset();
            return;
        }
        if (w.kind !== "picture" || w.file === "") {
            root.reset();
            root.backdrop = root.art(w);
            return;
        }
        // The same picture, already decided or under way: nothing to do.
        if (w.file === root.requested)
            return;
        root.reset();
        root.requested = w.file;
        root.pending = w.file;
        root.run("real", ["/usr/bin/realpath", "-m", "--", root.wallpaper.preparedDir, root.wallpaper.videoDir, w.file]);
        checkTimeout.restart();
    }

    function reset(): void {
        root.generation += 1;
        root.requested = "";
        root.pending = "";
        root.backdrop = null;
        checkTimeout.stop();
        image.source = "";
    }

    // The picture cannot be shown: the artwork the output would draw instead.
    function fail(why: string): void {
        console.warn("grassfield-lock: " + root.output + ": no wallpaper still on the lock (" + why + "); the artwork shows");
        const w = root.wanted;
        checkTimeout.stop();
        // A decode that ends after this is not kept.
        image.source = "";
        root.backdrop = {kind: "art", still: "", color: "", artwork: w ? w.artwork : "grassfield", variant: w ? w.variant : "evening.dark"};
    }

    // Its real path must still be a plain cache name directly in the real prepared or video folder (WallpaperConfig.lockStillReal).
    function realChecked(text: string, gen: int): void {
        if (gen !== root.generation)
            return;
        const real = WallpaperConfig.lockStillReal(text);
        if (real === "") {
            root.fail("not a picture of the wallpaper cache");
            return;
        }
        root.pending = real;
        root.run("stat", ["/usr/bin/stat", "--printf", "%f|%s", "--", real]);
    }

    // A regular file of at most wallpaper.lockStillMaxBytes (WallpaperConfig.lockStillStatOk): then it is decoded.
    function statChecked(text: string, gen: int): void {
        if (gen !== root.generation)
            return;
        if (!WallpaperConfig.lockStillStatOk(text, Tokens.wallpaperLockStillMaxBytes)) {
            root.fail("not a regular file of at most " + Tokens.wallpaperLockStillMaxBytes + " bytes");
            return;
        }
        image.source = "file://" + root.pending;
    }

    // One process per step of a request, tagged with that request: an answer of a superseded request is dropped (a process is
    // never stopped half-way, whose partial output would then be read as the newer request's). Each answers once and goes.
    function run(step: string, command: var): void {
        checkProcess.createObject(root, {step: step, gen: root.generation, command: command});
    }

    Component {
        id: checkProcess

        Process {
            id: proc
            property string step: ""
            property int gen: 0
            property bool answered: false
            function answer(text: string): void {
                if (proc.answered)
                    return;
                proc.answered = true;
                if (proc.step === "real")
                    root.realChecked(text, proc.gen);
                else
                    root.statChecked(text, proc.gen);
            }
            stdout: StdioCollector {
                onStreamFinished: proc.answer(text)
            }
            // Exited (or never started) without an answer: an empty one, which fails the check.
            onRunningChanged: {
                if (!running)
                    Qt.callLater(() => {
                        proc.answer("");
                        proc.destroy();
                    });
            }
            Component.onCompleted: running = true
        }
    }

    // A check or a decode that never ends gives the artwork (wallpaper.toolTimeoutMs: what a prepare may take).
    Timer {
        id: checkTimeout
        interval: Tokens.wallpaperToolTimeoutMs
        onTriggered: {
            if (root.backdrop === null && root.pending !== "")
                root.fail("the check or the decode took longer than " + interval + " ms");
        }
    }

    // The decoded still, kept while the output shows it (one per output: gate P2). Never drawn here.
    Image {
        id: image
        visible: false
        asynchronous: true
        cache: true
        fillMode: Image.Stretch
        onStatusChanged: {
            if (status === Image.Ready && root.backdrop === null && root.pending !== "") {
                checkTimeout.stop();
                const w = root.wanted;
                root.backdrop = {kind: "picture", still: String(source), color: "", artwork: w ? w.artwork : "grassfield", variant: w ? w.variant : "evening.dark"};
            } else if (status === Image.Error && root.pending !== "") {
                root.fail("cannot decode " + root.pending);
            }
        }
    }
}
