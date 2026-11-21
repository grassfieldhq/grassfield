pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.store

// What a settings change costs (audit SC-01, SC-08). Before: every change and every load moved one revision that every one of
// the ~150 views read (each normalized again), the object views (dockPinned, dockRecent, wallpaper, ...) gave a new array or
// object each time (the Dock rebuilt every Dock on a Transparency step), a write was read back twice, and a stat child ran every
// 10 s for a usable file. Now:
//   - a change re-evaluates the views of its own section only, a change that changes nothing re-evaluates none;
//   - an object view whose value is the same keeps its object (its readers hear nothing);
//   - the shell's own write is read back exactly once;
//   - a usable file is never looked at on a timer (no stat child while nothing happens), and a link retargeted two links
//     away (no file event) is still followed at once (the folders of the links are watched).
// Every section of the contract has a revision of its own. Offscreen (scripts/dev/test.sh: `qs -p tests/shell/settings_churn`).
// Prints "settings-churn: PASS" or the failing step.
ShellRoot {
    id: root

    readonly property string base: (Quickshell.env("GRASSFIELD_TEST_TMP") || "/tmp") + "/gf-churn-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)
    readonly property string seed: '{"version":1,"material":{"transparency":0.25},"dock":{"size":48,"pinned":["foot","chromium"],"recent":[]},"wallpaper":{"source":"color","color":"#336699"}}'

    property bool finished: false
    property string phase: "idle"
    property string stepName: ""
    property int stepIndex: -1
    property double stepStart: 0
    // Counters taken at a step's start.
    property int reads0: 0
    property int fullReads0: 0
    property int probes0: 0
    property var views0: ({})
    property var pinned0: null
    // Change signals of the object views.
    property var viewChanges: ({dockPinned: 0, dockRecent: 0, dockFolders: 0, dockStackOptions: 0, wallpaper: 0, displaysMain: 0, notificationsAppPreviews: 0, notificationsAppStyles: 0})
    property bool savedSeen: false

    function bump(view: string): void {
        const v = root.viewChanges;
        v[view]++;
        root.viewChanges = v;
    }

    function mark(): void {
        root.reads0 = store.readCount();
        root.fullReads0 = store.fullReads;
        root.probes0 = store.probes;
        root.views0 = Object.assign({}, root.viewChanges);
        root.pinned0 = store.dockPinned;
    }

    function readsSince(): int {
        return store.readCount() - root.reads0;
    }

    // "" when no object view changed since mark() except those named.
    function viewsQuiet(except: var): string {
        for (const k in root.viewChanges) {
            if (except.indexOf(k) < 0 && root.viewChanges[k] !== root.views0[k])
                return k + " signalled a change " + (root.viewChanges[k] - root.views0[k]) + " time(s)";
        }
        return "";
    }

    function finish(ok: bool, message: string): void {
        if (root.finished)
            return;
        root.finished = true;
        root.phase = "idle";
        console.log(ok ? "settings-churn: PASS" : "settings-churn: FAIL " + message);
        cleanup.running = true;
    }

    function fail(message: string): void {
        root.finish(false, "step \"" + root.stepName + "\": " + message + " (reads since " + root.readsSince() + ", fullReads " + store.fullReads + ", probes " + store.probes + ")");
    }

    function sectionsCheck(): string {
        for (const path in SettingsContract.ALL_DEFAULTS) {
            const top = path.split(".")[0];
            if (store.sectionNames.indexOf(top) < 0)
                return "the section " + top + " has no revision of its own";
        }
        return "";
    }

    // sh: a script ($B = base); run: a function; wait: ms; until/within: a condition; check: "" or an error.
    readonly property var steps: [
        {name: "load", until: () => store.loaded && store.validRead && store.transparency === 0.25 && store.dockPinned.length === 2, check: root.sectionsCheck},
        {name: "settle", wait: 600, run: () => root.mark()},
        // One key of `material`: its views only (transparency, materialProfile), never the ~150.
        {name: "transparency", run: () => { root.mark(); store.setTransparency(0.5); }, check: () => store.transparency !== 0.5 ? "transparency " + store.transparency
            : root.readsSince() > 4 ? root.readsSince() + " views re-evaluated for one material key (wanted at most 4)" : root.viewsQuiet([])},
        // The same value again: nothing re-evaluated.
        {name: "same value", run: () => { root.mark(); store.setTransparency(0.5); }, check: () => root.readsSince() !== 0 ? root.readsSince() + " views re-evaluated for no change" : ""},
        // A key of `dock`: the dock views are re-evaluated, the object views among them keep their objects.
        {name: "dock size", run: () => { root.mark(); store.setDockSize(60); }, check: () => store.dockSize !== 60 ? "dockSize " + store.dockSize
            : root.readsSince() > 40 ? root.readsSince() + " views re-evaluated for one dock key (wanted the dock section's only)"
            : store.dockPinned !== root.pinned0 ? "dockPinned is a new object" : root.viewsQuiet([])},
        {name: "dock recent", run: () => { root.mark(); store.setDockRecent(["org.gnome.Calculator"]); }, check: () => store.dockRecent.length !== 1 ? "dockRecent not set"
            : root.viewChanges.dockRecent !== root.views0.dockRecent + 1 ? "dockRecent signalled " + (root.viewChanges.dockRecent - root.views0.dockRecent) + " changes, wanted 1"
            : root.viewsQuiet(["dockRecent"])},
        // The write is read back once (the rename's events and the write's own request make one read).
        {name: "write", run: () => { root.mark(); root.savedSeen = false; store.flush(); }, until: () => root.savedSeen, within: 4000},
        {name: "read back once", wait: 1500, check: () => store.fullReads - root.fullReads0 !== 1 ? (store.fullReads - root.fullReads0) + " reads after the write, wanted exactly 1"
            : root.viewsQuiet([])},
        {name: "read back changes nothing", check: () => store.transparency === 0.5 && store.dockSize === 60 && store.dockRecent.length === 1 ? "" : "values lost on read back"},
        // Another writer changes dock.size (a rename, as the Settings app writes): the dock views only, the objects kept.
        {name: "external write", run: () => root.mark(),
            sh: 'f="$B/cfg/grassfield.json"; sed "s/\\"size\\": 60/\\"size\\": 70/" "$f" > "$f.new" && mv -f "$f.new" "$f"'},
        {name: "external write read", until: () => store.dockSize === 70, within: 2000},
        {name: "external write cost", check: () => root.readsSince() > 40 ? root.readsSince() + " views re-evaluated for a dock change on disk"
            : store.dockPinned !== root.pinned0 ? "dockPinned is a new object" : root.viewsQuiet([])},
        // Nothing happens: no read and no stat, even with a short pollInterval (a usable file has no timer).
        {name: "idle", run: () => { store.pollInterval = 200; root.mark(); }, wait: 2500,
            check: () => store.fullReads !== root.fullReads0 || store.probes !== root.probes0 ? "while idle: " + (store.fullReads - root.fullReads0) + " reads, " + (store.probes - root.probes0) + " stats" : ""},
        // grassfield.json -> ../ext/link -> a.json; then ext/link is retargeted to b.json: no event on the file or in the
        // configuration folder, only in ext/. No timer would see it within the second (pollInterval one minute).
        {name: "links", run: () => { store.pollInterval = 60000; },
            sh: 'mkdir -p "$B/ext" && printf \'{"version":1,"dock":{"size":50}}\' > "$B/ext/a.json" && printf \'{"version":1,"dock":{"size":52}}\' > "$B/ext/b.json" && ln -s a.json "$B/ext/link" && ln -s ../ext/link "$B/cfg/new" && mv -fT "$B/cfg/new" "$B/cfg/grassfield.json"'},
        {name: "links read", until: () => store.dockSize === 50 && store.hopDirs.length >= 1, within: 2000},
        {name: "retarget", sh: 'ln -s b.json "$B/ext/link.new" && mv -fT "$B/ext/link.new" "$B/ext/link"'},
        {name: "retarget followed", until: () => store.dockSize === 52, within: 1000}
    ]

    function enter(i: int): void {
        root.stepIndex = i;
        if (i >= root.steps.length) {
            root.finish(true, "");
            return;
        }
        const s = root.steps[i];
        root.stepName = s.name;
        root.stepStart = Date.now();
        if (s.sh !== undefined) {
            if (s.run !== undefined)
                s.run();
            runner.command = ["sh", "-c", "B=$1; " + s.sh, "sh", root.base];
            runner.running = true;
            return;
        }
        if (s.run !== undefined)
            s.run();
        root.stepStart = Date.now();
        root.phase = "wait";
    }

    Process {
        id: runner
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            if (root.finished)
                return;
            if (exitCode !== 0) {
                root.fail("script failed (exit " + exitCode + ")");
                return;
            }
            root.stepStart = Date.now();
            root.phase = "wait";
        }
    }

    Timer {
        interval: 25
        running: root.phase === "wait"
        repeat: true
        onTriggered: {
            if (root.finished)
                return;
            const s = root.steps[root.stepIndex];
            const elapsed = Date.now() - root.stepStart;
            if (s.until !== undefined && !s.until()) {
                if (elapsed > (s.within !== undefined ? s.within : 8000))
                    root.fail("condition not reached within " + (s.within !== undefined ? s.within : 8000) + " ms");
                return;
            }
            if (s.wait !== undefined && elapsed < s.wait)
                return;
            if (s.check !== undefined) {
                const err = s.check();
                if (err !== "") {
                    root.fail(err);
                    return;
                }
            }
            root.phase = "idle";
            root.enter(root.stepIndex + 1);
        }
    }

    property bool seeded: false

    Process {
        running: true
        command: ["sh", "-c", 'mkdir -p "$1/cfg" && printf "%s\\n" "$2" > "$1/cfg/grassfield.json"', "sh", root.base, root.seed]
        onRunningChanged: {
            if (!running) {
                root.seeded = true;
                root.enter(0);
            }
        }
    }

    SettingsStore {
        id: store
        configDir: root.seeded ? root.base + "/cfg" : ""
        // Written on flush() only: the write step below is the one write.
        saveDelay: 600000
        onSaved: root.savedSeen = true
        onDockPinnedChanged: root.bump("dockPinned")
        onDockRecentChanged: root.bump("dockRecent")
        onDockFoldersChanged: root.bump("dockFolders")
        onDockStackOptionsChanged: root.bump("dockStackOptions")
        onWallpaperChanged: root.bump("wallpaper")
        onDisplaysMainChanged: root.bump("displaysMain")
        onNotificationsAppPreviewsChanged: root.bump("notificationsAppPreviews")
        onNotificationsAppStylesChanged: root.bump("notificationsAppStyles")
    }

    Process {
        id: cleanup
        command: ["rm", "-rf", root.base]
        onRunningChanged: {
            if (!running)
                Qt.exit(root.finished && root.stepIndex >= root.steps.length ? 0 : 1);
        }
    }

    Timer {
        interval: 60000
        running: true
        onTriggered: root.finish(false, "timeout at step \"" + root.stepName + "\"")
    }
}
