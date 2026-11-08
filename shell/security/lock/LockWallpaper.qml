pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.services
import "../../lib/RunMode.js" as RunMode

// What the desktop last showed on each output, as the lock reads it (ADR-0041 step 1, S2; ADR-0040 step 4a's first item left to
// S2: the security process needs its own watched reader of wallpaper.json `shown`, with the pure WallpaperConfig.lockBackdropOf;
// the desktop's WallpaperState starts processes and writes files, and lives in the UI). Read-only: it reads
// $XDG_STATE_HOME/grassfield/wallpaper.json (the UI's state folder; see stateFile), written by the UI's WallpaperState,
// with a bounded read (one `head` at start and after each change the watch reports), and writes nothing. Display only: nothing here can lock, unlock or keep the lock from engaging; a file that
// is missing, too large or not JSON gives no record (the lock surfaces then show the ground, then the artwork).
Scope {
    id: root

    readonly property bool dev: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    // The same paths as the desktop's (shell/services/WallpaperState.qml): the cache of prepared pictures and video posters.
    readonly property string repoRoot: root.dev ? WallpaperConfig.normalizePath(Quickshell.shellDir + "/..") : ""
    readonly property string cacheDir: WallpaperConfig.cacheRoot({
        dev: root.dev,
        repoRoot: root.repoRoot,
        home: Quickshell.env("HOME") || "",
        xdgCache: Quickshell.env("XDG_CACHE_HOME") || ""
    })
    readonly property string preparedDir: root.cacheDir + "/prepared"
    readonly property string videoDir: root.cacheDir + "/video"
    // $XDG_STATE_HOME/grassfield (else ~/.local/state/grassfield), the UI's state folder in a real session. A security module
    // reads no GRASSFIELD_* variable but the dev gate's (ADR-0019, tests/ci/run_mode.py), so not GRASSFIELD_STATE_HOME: the dev
    // session gives this process an XDG_STATE_HOME whose grassfield folder is the dev state (scripts/dev/shell-run.sh).
    readonly property string stateFile: RunMode.stateDir("", Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME") || "") + "/wallpaper.json"
    // A real wallpaper.json holds 16 outputs at most; anything larger is not read.
    readonly property int maxBytes: 262144

    // {shown: {<output>: record}, ground: "#RRGGBB" | ""}: the parts of wallpaper.json the lock uses.
    property var saved: ({shown: {}, ground: ""})
    // Counts the reads, so that a binding asking lockBackdrop() is evaluated again.
    property int revision: 0

    // What the lock draws on `output` (WallpaperConfig.lockBackdropOf): {kind, file, color, artwork, variant} or null.
    function lockBackdrop(output: string): var {
        void root.revision;
        return WallpaperConfig.lockBackdropOf(root.saved, output, root.preparedDir, root.videoDir);
    }

    // The colour a lock surface shows before its backdrop is decided: the ground the compositor was last given, else the
    // session's.
    readonly property string ground: /^#[0-9A-Fa-f]{6}$/.test(String(root.saved.ground || "")) ? root.saved.ground : Tokens.sessionGround

    // wallpaper.moving (ADR-0040 step 9): the lock's clouds move.
    readonly property bool moving: WallpaperConfig.normalize(Settings.wallpaper).moving

    function take(text: string): void {
        let shown = {};
        let ground = "";
        try {
            if (text.length > 0 && text.length <= root.maxBytes) {
                const o = JSON.parse(text);
                if (o && typeof o.shown === "object" && o.shown !== null && !Array.isArray(o.shown))
                    shown = o.shown;
                if (o && typeof o.ground === "string" && /^#[0-9A-Fa-f]{6}$/.test(o.ground))
                    ground = o.ground;
            }
        } catch (e) {
            shown = {};
        }
        root.saved = {shown: shown, ground: ground};
        root.revision += 1;
    }

    // Read with a bound (`head -c`, a timeout for a FIFO): Quickshell's FileView reads a file whole, and a huge or blocking
    // wallpaper.json must not take the lock's process down. The watch only says "changed" (preload: false: it reads nothing).
    function read(): void {
        if (reader.running) {
            root.again = true;
            return;
        }
        reader.running = true;
    }
    property bool again: false

    Process {
        id: reader
        command: ["timeout", "-k", "1", "5", "head", "-c", String(root.maxBytes + 1), "--", root.stateFile]
        stdout: StdioCollector {
            onStreamFinished: root.take(String(text))
        }
        onRunningChanged: {
            if (!running && root.again) {
                root.again = false;
                Qt.callLater(root.read);
            }
        }
    }

    FileView {
        path: root.stateFile
        watchChanges: true
        preload: false
        printErrors: false
        onFileChanged: root.read()
    }

    Component.onCompleted: root.read()
}
