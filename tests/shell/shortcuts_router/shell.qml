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
// committed end opens or closes only while no surface follows the gesture. Prints "shortcuts-router: PASS" or the failures.
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
            root.check("gesture steps " + JSON.stringify(root.steps), root.steps.join("|") === "overview-open begin 0|overview-open update 0.4|overview-open end 0.6 commit|overview-close end 0.2|overview-close end 0.9 commit|overview-close end 0.9 commit");
            if (root.failures.length === 0)
                console.log("shortcuts-router: PASS");
            else
                console.log("shortcuts-router: FAIL " + root.failures.join("; "));
            Qt.quit();
        }
    }
}
