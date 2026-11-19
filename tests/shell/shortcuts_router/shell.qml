pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform.shortcuts

// CIO-01, on the REAL router singleton (scripts/dev/test.sh: `qs -p tests/shell/shortcuts_router`, offscreen): a key
// request read from socket2 (`custom>>gfkey/1 ...`, given to Shortcuts.receive as the Hyprland connection would) reaches the
// IpcHandler of its target that attached itself with `Component.onCompleted: Shortcuts.attach(this)` (the form every host
// file uses), with its arguments; when two handlers share a target the enabled one answers (shell.qml's early hand-over);
// a request the bindings never send, a test hook, or a malformed argument reaches nothing; gesture steps are signalled, and a
// committed end opens or closes only while no surface follows the gesture; a GestureFollower (Apps', Overview's) opens at the
// begin, draws the fingers' progress, completes or goes back from there, mirrors it for the close gesture, takes a refusal
// and Reduce Motion (the end alone). Prints "shortcuts-router: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property var calls: []
    property var steps: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function took(expected: string): void {
        check("calls " + JSON.stringify(root.calls) + " = [" + expected + "]", root.calls.join(",") === expected);
        root.calls = [];
    }

    IpcHandler {
        id: early
        target: "search"
        enabled: true
        Component.onCompleted: Shortcuts.attach(this)

        function toggle(): void {
            root.calls = root.calls.concat(["early.toggle"]);
        }

        function clipboard(): void {
            root.calls = root.calls.concat(["early.clipboard"]);
        }

        function status(): string {
            root.calls = root.calls.concat(["early.status"]);
            return "";
        }
    }

    IpcHandler {
        id: surface
        target: "search-surface" // renamed to "search" below: Quickshell keeps one handler per target, as shell.qml does by `enabled`
        enabled: false
        Component.onCompleted: Shortcuts.attach(this)

        function toggle(): void {
            root.calls = root.calls.concat(["surface.toggle"]);
        }

        function clipboard(): void {
            root.calls = root.calls.concat(["surface.clipboard"]);
        }
    }

    IpcHandler {
        target: "windows"
        Component.onCompleted: Shortcuts.attach(this)

        function tile(place: string): void {
            root.calls = root.calls.concat(["tile " + place]);
        }

        function minimize(): void {
            root.calls = root.calls.concat(["minimize"]);
        }
    }

    IpcHandler {
        target: "menubar"
        Component.onCompleted: Shortcuts.attach(this)

        function open(kind: string, screen: string): void {
            root.calls = root.calls.concat(["open " + kind + "@" + screen]);
        }
    }

    IpcHandler {
        target: "stages"
        Component.onCompleted: Shortcuts.attach(this)

        function activate(position: int): string {
            root.calls = root.calls.concat(["activate " + (position + 1)]); // an int, not a string ("3" + 1 would be "31")
            return "ok";
        }
    }

    IpcHandler {
        target: "overview"
        Component.onCompleted: Shortcuts.attach(this)

        function open(): void {
            root.calls = root.calls.concat(["overview.open"]);
        }

        function close(): void {
            root.calls = root.calls.concat(["overview.close"]);
        }
    }

    // R2: a surface that follows its gesture (as Apps and Overview do, with the same GestureFollower). `refuses` stands for
    // the lock screen (SessionState.refuses in the real show()).
    QtObject {
        id: appsSurface

        property bool open: false
        property bool refuses: false
        property var log: []
    }

    GestureFollower {
        id: follower
        target: "apps"
        open: appsSurface.open
        reduceMotion: false
        onShow: {
            appsSurface.log = appsSurface.log.concat(["show@" + follower.progress]);
            if (!appsSurface.refuses)
                appsSurface.open = true;
        }
        onClose: {
            appsSurface.log = appsSurface.log.concat(["close@" + follower.progress]);
            appsSurface.open = false;
        }
    }

    function followerChecks(): void {
        const s = text => Shortcuts.receive("gfgesture/1 " + text);
        const near = (a, b) => Math.abs(a - b) < 1e-6;
        check("the follower took the apps gestures from the router", Shortcuts.tracking["apps-open"] === true && Shortcuts.tracking["apps-close"] === true);
        s("apps-open begin 0");
        check("begin: shown at progress 0, drawn step by step, held as opening", appsSurface.open && follower.progress === 0 && follower.active && follower.opening && appsSurface.log.join() === "show@0");
        s("apps-open update 0.35");
        check("update: the fingers' progress (" + follower.progress + ")", near(follower.progress, 0.35));
        s("apps-open end 0.6 commit");
        check("a completed pinch: open, its own state again", appsSurface.open && follower.progress === -1 && !follower.active && !follower.opening);
        s("apps-close begin 0");
        s("apps-close update 0.25");
        check("pinch out: 1 - p", near(follower.progress, 0.75));
        s("apps-close end 0.25 back");
        check("a pinch out gone back stays open", appsSurface.open && follower.progress === -1);
        s("apps-close begin 0");
        s("apps-close update 0.7");
        s("apps-close end 0.7 commit");
        check("a completed pinch out closes from where the fingers left it", !appsSurface.open && follower.progress === -1 && appsSurface.log[appsSurface.log.length - 1].startsWith("close@0.3"));
        s("apps-open begin 0");
        s("apps-open update 0.2");
        s("apps-open cancel 0.2");
        check("a cancelled pinch closes again", !appsSurface.open && follower.progress === -1 && !follower.opening);
        // Over the lock screen the surface refuses: nothing is drawn, the end asks again and is refused again.
        appsSurface.refuses = true;
        s("apps-open begin 0");
        s("apps-open update 0.5");
        check("refused: nothing drawn", !appsSurface.open && follower.progress === -1 && !follower.active);
        s("apps-open end 0.8 commit");
        check("refused: still closed", !appsSurface.open && follower.progress === -1);
        appsSurface.refuses = false;
        // Reduce Motion: the end alone.
        follower.reduceMotion = true;
        s("apps-open begin 0");
        s("apps-open update 0.5");
        check("reduce motion: nothing follows the fingers", !appsSurface.open && follower.progress === -1);
        s("apps-open end 0.7 commit");
        check("reduce motion: a completed pinch opens", appsSurface.open && follower.progress === -1);
        s("apps-close begin 0");
        s("apps-close end 0.7 commit");
        check("reduce motion: a completed pinch out closes", !appsSurface.open);
        follower.reduceMotion = false;
        // Closed by anything else mid-gesture (Esc, the lock): the gesture no longer drives it.
        s("apps-open begin 0");
        s("apps-open update 0.5");
        appsSurface.open = false;
        check("closed elsewhere: progress dropped", follower.progress === -1 && !follower.active && !follower.opening);
        s("apps-open end 0.5 back");
        root.took("");
    }

    Connections {
        target: Shortcuts

        function onGesture(kind: string, phase: string, progress: real, commit: bool): void {
            root.steps = root.steps.concat([kind + " " + phase + " " + progress + (commit ? " commit" : "")]);
        }
    }

    Timer {
        running: true
        interval: 50
        onTriggered: {
            // Keys reach the attached handler, with their arguments.
            Shortcuts.receive("gfkey/1 search toggle");
            root.took("early.toggle");
            Shortcuts.receive("gfkey/1 windows tile top-left");
            Shortcuts.receive("gfkey/1 windows minimize");
            root.took("tile top-left,minimize");
            Shortcuts.receive("gfkey/1 menubar open status");
            Shortcuts.receive("gfkey/1 menubar open system DP-2");
            root.took("open status@,open system@DP-2");
            Shortcuts.receive("gfkey/1 stages activate 3");
            root.took("activate 4");
            // The surface takes over the target: the enabled handler answers.
            surface.target = "search";
            Shortcuts.attach(surface);
            early.enabled = false;
            surface.enabled = true;
            Shortcuts.receive("gfkey/1 search clipboard");
            root.took("surface.clipboard");
            // Nothing else reaches a handler: a test hook, an unknown function, a bad argument, another payload.
            Shortcuts.receive("gfkey/1 search status");
            Shortcuts.receive("gfkey/1 windows tile");
            Shortcuts.receive("gfkey/1 windows tile ../x");
            Shortcuts.receive("gfkey/1 stages activate 0");
            Shortcuts.receive("search toggle");
            Shortcuts.receive("{\"v\":\"gfc/1\"}");
            root.took("");
            // Gestures: every step is signalled; with nobody following, a committed end opens (a gone-back one does not).
            Shortcuts.receive("gfgesture/1 overview-open begin 0");
            Shortcuts.receive("gfgesture/1 overview-open update 0.4");
            Shortcuts.receive("gfgesture/1 overview-open end 0.6 commit");
            root.took("overview.open");
            Shortcuts.receive("gfgesture/1 overview-close end 0.2 back");
            root.took("");
            // A surface that follows the gesture does the opening itself: no discrete request.
            Shortcuts.follow("overview-close", true);
            Shortcuts.receive("gfgesture/1 overview-close end 0.9 commit");
            root.took("");
            Shortcuts.follow("overview-close", false);
            Shortcuts.receive("gfgesture/1 overview-close end 0.9 commit");
            root.took("overview.close");
            root.check("gesture steps " + JSON.stringify(root.steps.filter(x => x.startsWith("overview"))), root.steps.filter(x => x.startsWith("overview")).join("|") === "overview-open begin 0|overview-open update 0.4|overview-open end 0.6 commit|overview-close end 0.2|overview-close end 0.9 commit|overview-close end 0.9 commit");
            root.followerChecks();
            if (root.failures.length === 0)
                console.log("shortcuts-router: PASS");
            else
                console.log("shortcuts-router: FAIL " + root.failures.join("; "));
            Qt.quit();
        }
    }
}
