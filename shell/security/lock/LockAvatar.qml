pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// The lock screen's account picture as a PNG this process made (ADR-0041 step 1, S2: the UI's ThemeIcons empties and fills a
// directory of its own, so the security process makes its one picture itself, with the same helper and the same rules:
// services/image-copy.py `file`, review of 423766f: the shell only ever decodes images it produced). One picture at a time,
// one attempt per path and process start: `sourceOf(path)` asks for it and gives its file URL once made ("" until then and
// when refused), `stateOf(path)` says "pending", "ok", "no" or "" (never asked), as LockMachine.avatarSource expects. The copy
// is $XDG_RUNTIME_DIR/grassfield-lock-avatar-<display>-<pid>-<n>.png (0600, made new by the helper; the copies of earlier runs
// are deleted before the first one). Display only: nothing here can lock, unlock or keep the lock from engaging; a helper that hangs is stopped by
// `timeout`, and the initials show.
Scope {
    id: root

    readonly property string helper: Quickshell.shellPath("services/image-copy.py")
    readonly property string base: {
        const runtime = Quickshell.env("XDG_RUNTIME_DIR");
        const display = String(Quickshell.env("WAYLAND_DISPLAY") || "none").replace(/[^A-Za-z0-9._-]/g, "_");
        return runtime ? runtime + "/grassfield-lock-avatar-" + display : "";
    }
    // A picture source file at most this large (a photo may be big); the copy is at most 256 x 256 pixels.
    readonly property real maxBytes: 16 * 1024 * 1024
    // path -> {state: "pending" | "ok" | "no", url}; reassigned on every change so that the bindings asking re-evaluate.
    property var copies: ({})
    // Paths asked and not started yet. Mutated in place, never reassigned: a binding that asks notifies nobody (no binding
    // loop through the queue).
    readonly property var queue: ({list: []})
    property int counter: 0

    function sourceOf(path: string): string {
        const entry = root.copies[path];
        if (entry === undefined) {
            root.ask(path);
            return "";
        }
        return entry.state === "ok" ? entry.url : "";
    }

    function stateOf(path: string): string {
        const entry = root.copies[path];
        return entry === undefined ? "" : entry.state;
    }

    function set(path: string, entry: var): void {
        const next = Object.assign({}, root.copies);
        next[path] = entry;
        root.copies = next;
    }

    // Asked from a binding: recorded now, started later in the turn.
    function ask(path: string): void {
        if (path === "" || root.queue.list.indexOf(path) >= 0)
            return;
        root.queue.list.push(path);
        Qt.callLater(root.run);
    }

    function run(): void {
        if (maker.running || cleaner.running || root.queue.list.length === 0)
            return;
        const path = root.queue.list.shift();
        if (root.copies[path] !== undefined) {
            Qt.callLater(root.run);
            return;
        }
        if (root.base === "") {
            root.set(path, {state: "no", url: ""});
            Qt.callLater(root.run);
            return;
        }
        root.counter += 1;
        const out = root.base + "-" + Quickshell.processId + "-" + root.counter + ".png";
        root.set(path, {state: "pending", url: ""});
        maker.path = path;
        maker.out = out;
        // The helper creates the copy (O_EXCL, 0600). Argument vector, no shell.
        maker.command = ["timeout", "-k", "2", "20", "setpriv", "--pdeathsig", "KILL", "--", "python3", "-I", root.helper, "file", path, String(root.maxBytes), out];
        // The first copy of this process waits for the copies of earlier runs to be deleted (a restart leaves its own).
        if (root.cleaned)
            maker.running = true;
        else
            cleaner.running = true;
    }

    property bool cleaned: false

    Process {
        id: maker
        property string path: ""
        property string out: ""
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.set(maker.path, code === 0 ? {state: "ok", url: "file://" + maker.out} : {state: "no", url: ""});
            Qt.callLater(root.run);
        }
    }

    // The copies of earlier runs of this process (same display), deleted once before the first copy is made.
    Process {
        id: cleaner
        command: ["sh", "-c", "case $1 in /*/grassfield-lock-avatar-*) ;; *) exit 1 ;; esac; for f in \"$1\"-*.png; do [ -e \"$f\" ] && rm -f -- \"$f\"; done; exit 0", "gf-lock-avatar-clean", root.base]
        // qmllint disable signal-handler-parameters
        onExited: () => {
            // qmllint enable signal-handler-parameters
            root.cleaned = true;
            maker.running = true;
        }
    }
}
