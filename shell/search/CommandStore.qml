pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import "CommandsFile.js" as CommandsFile

// CommandStore: the one writer of commands.json (ADR-0067 D-8, docs/specs/command-palette.md slice E1b).
//
// The content (quick keys, keyboard shortcuts, favorites, links, text replacements, user AI commands) lives in `data`, always a
// value CommandsFile.parseText() accepted. Every change, from Search itself (`change`, any list) or from the Settings app over
// IPC (`request`, links, replacements and AI commands only), builds the candidate content, serializes it and reads it back
// through the file reader's own validator before it replaces `data`; so a request is judged exactly as a file is.
//
// Writes: `data` changes at once (two requests in a row both apply, the second on top of the first); the file is written after,
// one write at a time, always the latest `data`, atomically and 0600 through shell/services/write-private.sh.
//
// A file on disk that fails validation (corrupt, a newer version, not JSON, a FIFO) is never overwritten and never served: the
// store keeps the last good content (empty at start), `status` is "invalid" with the reason, and every change is refused
// ("file-invalid") until the person agrees: `keepAside()` renames the file to commands.json.invalid-<time> (the backup is kept,
// `keptAside` names it) and writes the last good content as a fresh file. The Settings app can do the same rename itself; the
// store follows the file. A file that becomes valid again (the person fixed it) is taken as it is.
Scope {
    id: root

    property string path: Mode.configDir + "/commands.json"
    readonly property string dir: path.slice(0, path.lastIndexOf("/"))

    // The last good content, a value CommandsFile accepted.
    property var data: CommandsFile.empty()
    // "loading" until the first read ends, then "ok" or "invalid".
    property string status: "loading"
    property string invalidReason: ""
    property string invalidPath: ""
    // The backup the last keepAside() made ("" if none).
    property string keptAside: ""
    // "" or why the last write of the file failed (the content in memory is kept and written again with the next change).
    property string writeError: ""
    // The outcome of the last importFile(), as importResult() returns it.
    property var lastImport: ({})
    // Counts the contents taken (a change, or the file changed under the store).
    property int revision: 0
    readonly property bool writing: writer.running || root.dirty
    signal changed

    // The newest content is not on disk yet.
    property bool dirty: false
    // The texts this store wrote lately: the file watcher reports them back and they are not external edits.
    property var wrote: []
    // Seconds, after which a read of an imported file that does not end is killed.
    property int importLimitMs: 5000

    readonly property string writerTool: Quickshell.shellPath("services/write-private.sh")
    readonly property string readerTool: Quickshell.shellPath("services/read-import.sh")

    // ---- Reading --------------------------------------------------------------------------------------------------------

    FileView {
        id: file
        path: root.path
        printErrors: false
        watchChanges: true
        onLoaded: root.take(file.text())
        onLoadFailed: error => root.takeMissing(error === FileViewError.FileNotFound)
        onFileChanged: file.reload()
    }

    function take(text: string): void {
        // While a write is on its way the file says what an older write said; the newest content is in memory and goes out next.
        if (root.writing || root.wrote.indexOf(text) >= 0) {
            if (root.status === "loading")
                root.status = "ok";
            return;
        }
        const r = CommandsFile.parseText(text);
        if (!r.ok) {
            const was = root.status === "invalid" && root.invalidReason === r.reason && root.invalidPath === r.path;
            root.status = "invalid";
            root.invalidReason = r.reason;
            root.invalidPath = r.path;
            if (!was)
                console.warn("grassfield: commands.json is not valid (" + r.path + ": " + r.reason + "); it is left as it is");
            return;
        }
        root.status = "ok";
        root.invalidReason = "";
        root.invalidPath = "";
        root.data = r.data;
        root.revision++;
        root.changed();
    }

    // No file (not made yet, or the person removed it): empty content, unless the content is being kept (aside or in flight).
    // A path that is a directory, or a file the shell may not read, is not "no file": it is invalid and left alone.
    function takeMissing(notFound: bool): void {
        if (root.writing || root.status === "invalid" && root.asideRunning)
            return;
        if (!notFound) {
            if (root.status !== "invalid")
                console.warn("grassfield: commands.json cannot be read; it is left as it is");
            root.status = "invalid";
            root.invalidReason = "unreadable";
            root.invalidPath = "";
            return;
        }
        root.status = "ok";
        root.invalidReason = "";
        root.invalidPath = "";
        if (JSON.stringify(root.data) !== JSON.stringify(CommandsFile.empty())) {
            root.data = CommandsFile.empty();
            root.revision++;
            root.changed();
        }
    }

    // ---- Changing -------------------------------------------------------------------------------------------------------

    // {ok: true} once `next` (a candidate content) is accepted and on its way to the file, or {ok: false, reason, path?}.
    function commit(next: var): var {
        if (root.status === "loading")
            return {ok: false, reason: "loading"};
        if (root.status === "invalid")
            return {ok: false, reason: "file-invalid", detail: root.invalidReason};
        const s = CommandsFile.serialize(next);
        // The same reader the file goes through, on the text that would be written.
        const r = CommandsFile.parseText(s.text);
        if (!r.ok)
            return {ok: false, reason: r.reason, path: r.path};
        root.data = r.data;
        root.revision++;
        root.changed();
        root.dirty = true;
        root.pump();
        return {ok: true};
    }

    // An item of any list, from Search itself (a quick key, a favorite, a link, a shortcut): mode "add" or "update".
    function change(list: string, item: var, mode: string): var {
        const r = CommandsFile.validateItem(list, item);
        if (!r.ok)
            return {ok: false, reason: r.reason, path: r.path};
        const c = CommandsFile.withItem(root.data, list, r.value, mode);
        return c.ok ? root.commit(c.data) : {ok: false, reason: c.reason, path: c.path};
    }

    function remove(list: string, key: string): var {
        const next = CommandsFile.copy(root.data);
        if (!(list in next) || !Array.isArray(next[list]))
            return {ok: false, reason: "list", path: String(list)};
        const at = next[list].findIndex(x => CommandsFile.keyOf(list, x) === key);
        if (at < 0)
            return {ok: false, reason: "not-found", path: list};
        next[list].splice(at, 1);
        return root.commit(next);
    }

    // The IPC path (shell/search/Search.qml, the `search` target): op is "add", "update" (payload: `{"list": ..., "item": ...}`),
    // "remove" (payload: the id of a link, replacement or AI command) or "import" (payload: an absolute path). The payload is at
    // most 64 KiB and refused unless it is plain JSON with no duplicate key and no huge integer; the lists are links,
    // replacements and AI commands. Returns {ok, reason?, path?}.
    function request(op: string, payload: string): var {
        if (op === "import")
            return root.importFile(payload);
        if (root.status === "loading")
            return {ok: false, reason: "loading"};
        if (op === "remove") {
            const c = CommandsFile.withoutItem(root.data, payload);
            return c.ok ? root.commit(c.data) : {ok: false, reason: c.reason, path: c.path};
        }
        if (op !== "add" && op !== "update")
            return {ok: false, reason: "op"};
        const q = CommandsFile.parseRequest(payload);
        if (!q.ok)
            return {ok: false, reason: q.reason, path: q.path};
        const c = CommandsFile.withItem(root.data, q.list, q.item, op);
        return c.ok ? root.commit(c.data) : {ok: false, reason: c.reason, path: c.path};
    }

    // ---- Writing --------------------------------------------------------------------------------------------------------

    property string outgoing: ""
    property int outgoingBytes: 0

    function pump(): void {
        if (writer.running || !root.dirty)
            return;
        root.dirty = false;
        const s = CommandsFile.serialize(root.data);
        root.outgoing = s.text;
        root.outgoingBytes = s.bytes;
        root.wrote = root.wrote.concat([s.text]).slice(-4);
        writer.command = ["sh", root.writerTool, root.dir, root.path, "--stdin", String(s.bytes)];
        writer.running = true;
    }

    Process {
        id: writer
        stdinEnabled: true
        onStarted: writer.write(root.outgoing)
        onExited: code => {
            root.writeError = code === 0 ? "" : "write-failed";
            if (code !== 0)
                console.warn("grassfield: commands.json could not be written (" + code + ")");
            root.pump();
            // A file that did not exist when the watch began is watched from its first read on.
            if (!root.dirty && !writer.running)
                file.reload();
        }
    }

    // ---- An invalid file ------------------------------------------------------------------------------------------------

    property bool asideRunning: aside.running

    // The person agrees: the file is renamed (nothing is deleted) and the last good content is written as a new file.
    function keepAside(): bool {
        if (root.status !== "invalid" || aside.running)
            return false;
        root.asideTo = root.path + ".invalid-" + Date.now();
        aside.command = ["mv", "-n", "--", root.path, root.asideTo];
        aside.running = true;
        return true;
    }

    property string asideTo: ""

    Process {
        id: aside
        onExited: code => {
            if (code !== 0) {
                console.warn("grassfield: commands.json could not be kept aside (" + code + ")");
                return;
            }
            root.keptAside = root.asideTo;
            root.status = "ok";
            root.invalidReason = "";
            root.invalidPath = "";
            root.dirty = true;
            root.pump();
        }
    }

    // ---- Importing a file -----------------------------------------------------------------------------------------------

    // Reads the file the person chose through shell/services/read-import.sh (an absolute path; never a link, a FIFO, a file of
    // another user or more than 1 MiB; nothing is run), validates it as a commands.json and adds the links, replacements and
    // AI commands whose id is new. The answer is at once ({ok: true, state: "reading"} or a refusal); the outcome follows in
    // `lastImport` ({ok, added, skipped, ignored} or {ok: false, reason}), which the `importResult` IPC function returns.
    function importFile(path: string): var {
        if (root.status === "loading")
            return {ok: false, reason: "loading"};
        if (root.status === "invalid")
            return {ok: false, reason: "file-invalid", detail: root.invalidReason};
        if (reader.running)
            return {ok: false, reason: "busy"};
        if (typeof path !== "string" || path.length < 1 || path[0] !== "/" || !CommandsFile.checkPath(path))
            return {ok: false, reason: "path"};
        root.lastImport = {ok: false, reason: "reading"};
        reader.command = ["sh", root.readerTool, path];
        root.timedOut = false;
        reader.running = true;
        limit.restart();
        return {ok: true, state: "reading"};
    }

    property bool timedOut: false

    function finishImport(out: string): void {
        limit.stop();
        if (root.timedOut) {
            root.lastImport = {ok: false, reason: "timeout"};
            return;
        }
        if (out.slice(0, 3) !== "OK\n") {
            const m = /^ERR ([a-z-]{1,20})\n?$/.exec(out);
            root.lastImport = {ok: false, reason: m ? m[1] : "unreadable"};
            return;
        }
        const r = CommandsFile.parseText(out.slice(3));
        if (!r.ok) {
            root.lastImport = {ok: false, reason: r.reason, path: r.path};
            return;
        }
        const m = CommandsFile.mergeImport(root.data, r.data);
        const done = root.commit(m.data);
        root.lastImport = done.ok ? {ok: true, added: m.added, skipped: m.skipped, ignored: m.ignored} : done;
    }

    Process {
        id: reader
        stdout: StdioCollector {
            id: readerOut
            onStreamFinished: root.finishImport(readerOut.text)
        }
        onExited: {
            // Killed by the time limit: the stream may end without a word.
            if (root.timedOut && root.lastImport.reason === "reading")
                root.finishImport("");
        }
    }

    Timer {
        id: limit
        interval: root.importLimitMs
        onTriggered: {
            if (reader.running) {
                root.timedOut = true;
                reader.signal(9);
            }
        }
    }
}
