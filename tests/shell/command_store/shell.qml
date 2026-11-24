pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.search
import qs.services
import "search/CommandsFile.js" as CommandsFile

// CommandStore (command palette E1b) on the REAL Search controller and its IPC handler (scripts/dev/test.sh:
// `qs -p tests/shell/command_store`, offscreen, a dev session whose config home is a scratch directory; prints
// "command-store: PASS" or the failures). The `search` IPC functions are called as a client calls them (Search.ipc is the handler).
// - every request is judged as the file reader judges a file (parity over valid and invalid links), at most 64 KiB, only the
//   links, replacements and AI commands lists, plain JSON only;
// - the file is 0600 in a 0700 directory, atomic (no .tmp), and always holds the newest content; requests in a row are all kept;
// - every function is refused while the session is locked, and nothing changes;
// - importFile refuses a link, a FIFO, a directory, a file of another user, a file over 1 MiB, invalid content and a relative
//   path, runs nothing, and adds only what is new; key bindings in the file are ignored;
// - a corrupt, foreign or unreadable commands.json is never overwritten: the store serves the last good content, refuses changes,
//   and after keepAside() the backup holds the old file and the new file the last good content; an edit that makes it valid
//   again is followed.
ShellRoot {
    id: root

    property var failures: []
    property int checks: 0

    function check(name: string, ok: bool): void {
        checks++;
        if (!ok)
            failures.push(name);
    }

    Search {
        id: search
    }

    readonly property var store: search.commandStore
    readonly property string file: store.path
    readonly property string dir: store.dir
    readonly property string fixtures: dir + "/fixtures"

    // The second store of the "invalid at start" cases.
    property string secondPath: ""
    Loader {
        id: second
        active: root.secondPath !== ""
        sourceComponent: Component {
            CommandStore {
                path: root.secondPath
            }
        }
    }

    // ---- helpers ----------------------------------------------------------------------------------------------------------

    Process {
        id: probe
        property var done: null
        stdout: StdioCollector {
            id: probeOut
            onStreamFinished: {
                const f = probe.done;
                probe.done = null;
                if (f)
                    f(probeOut.text);
            }
        }
    }

    // Runs a shell script (arguments $1...) and hands its output to `then`.
    function sh(script: string, args: var, then: var): void {
        probe.done = then;
        probe.command = ["sh", "-c", script, "x"].concat(args || []);
        probe.running = true;
    }

    function link(id: string, target: string): var {
        return {id: id, name: "Docs " + id, target: target, args: []};
    }

    function add(list: string, item: var): var {
        return JSON.parse(search.ipc.addItem(JSON.stringify({list: list, item: item})));
    }

    function settled(): bool {
        return root.store.status !== "loading" && !root.store.writing;
    }

    // Waits for `cond`, then runs `then` (a step of the scenario), failing after 8 s.
    property var waiting: null
    property var after: null
    property int waited: 0
    property string waitName: ""

    function until(name: string, cond: var, then: var): void {
        root.waitName = name;
        root.waiting = cond;
        root.after = then;
        root.waited = 0;
        tick.start();
    }

    Timer {
        id: tick
        interval: 50
        repeat: true
        onTriggered: {
            root.waited += interval;
            if (root.waiting()) {
                tick.stop();
                const f = root.after;
                root.after = null;
                f();
            } else if (root.waited > 8000) {
                tick.stop();
                root.check("timeout waiting for " + root.waitName, false);
                root.finish();
            }
        }
    }

    function finish(): void {
        if (root.failures.length === 0) {
            console.log("command-store: PASS (" + root.checks + " checks)");
            Qt.exit(0);
        } else {
            console.log("command-store: FAIL: " + root.failures.join("; "));
            Qt.exit(1);
        }
    }

    function same(a: var, b: var): bool {
        return JSON.stringify(a) === JSON.stringify(b);
    }

    // ---- 1. a missing file, then the requests -----------------------------------------------------------------------------

    function step1(): void {
        check("no file: status ok, nothing in it", store.status === "ok" && same(store.data, CommandsFile.empty()));
        check("the store is in a dev config directory", root.file.indexOf("/commands.json") > 0 && root.file.indexOf("config") > 0);
        const rev = store.revision;
        // Three requests in a row, before any write finished: all kept.
        const a = add("links", link("link.a1", "https://example.org/?q={argument}"));
        const b = add("replacements", {id: "text.b1", replace: "brb", with: "be right back"});
        const c = JSON.parse(search.ipc.updateItem(JSON.stringify({list: "links", item: {id: "link.a1", name: "Renamed", target: "https://example.org/", args: []}})));
        const d = add("aiCommands", {id: "ai.c1", name: "Summarize", prompt: "Summarize: {clipboard}"});
        check("add link, add replacement, update link, add AI command are accepted", a.ok && b.ok && c.ok && d.ok);
        check("two quick requests are both kept in memory", store.data.links.length === 1 && store.data.links[0].name === "Renamed" && store.data.replacements.length === 1 && store.data.aiCommands.length === 1);
        check("revision follows the changes", store.revision === rev + 4);
        until("the first writes", () => root.settled(), step1b);
    }

    function step1b(): void {
        sh("stat -c %a \"$1\"; stat -c %a \"$2\"; ls -A \"$2\"; cat \"$1\"", [root.file, root.dir], out => {
            const lines = out.split("\n");
            check("commands.json is 0600 (" + lines[0] + ")", lines[0] === "600");
            check("its directory is 0700 (" + lines[1] + ")", lines[1] === "700");
            check("no temporary file is left (" + lines.slice(2, 4).join(",") + ")", out.indexOf(".tmp") < 0);
            const text = lines.slice(3).join("\n");
            const r = CommandsFile.parseText(text);
            check("the file is a valid commands.json", r.ok);
            check("the file holds the newest content", r.ok && root.same(r.data, root.store.data) && r.data.links[0].name === "Renamed");
            step2();
        });
    }

    // ---- 2. validation through the IPC path -------------------------------------------------------------------------------

    function request(op: string, payload: string): var {
        const fn = {add: search.ipc.addItem, update: search.ipc.updateItem}[op];
        return JSON.parse(fn(payload));
    }

    function step2(): void {
        const rev = store.revision;
        const before = JSON.stringify(store.data);
        let accepted = 0;
        const refused = (name, r, reason) => check(name + " (" + JSON.stringify(r) + ")", r.ok === false && (reason === undefined || r.reason === reason));
        // The link allowlist and the file reader's rules: parity. Each target is tried as a file and as a request.
        const targets = ["https://example.org/", "http://localhost:8080/x", "mailto:a@example.org?subject=Hi", "/etc/hosts", "file:///etc/hosts",
            "javascript:alert(1)", "data:text/html,x", "blob:x", "smb://host/share", "sftp://h/p", "ftp://h/p", "dav://h/p", "x-scheme-handler/foo:bar",
            "https://user:pw@example.org/", "https://exämple.org/", "mailto:a@example.org?attach=/etc/passwd", "//host/share", "relative/path",
            "/a/../b", "https://example.org/{nope}", "", "https://example.org/" + "a".repeat(2100)];
        let parity = true;
        for (let i = 0; i < targets.length; i++) {
            const item = root.link("link.p" + i, targets[i]);
            const asFile = CommandsFile.parseText(JSON.stringify({v: 1, links: [item]}));
            const asRequest = root.add("links", item);
            if (asFile.ok !== asRequest.ok) {
                parity = false;
                console.log("parity differs for " + targets[i].slice(0, 60) + ": file " + asFile.ok + " request " + asRequest.ok);
            }
            if (asRequest.ok)
                accepted++;
            if (asRequest.ok && !asFile.ok)
                parity = false;
        }
        check("a request is accepted exactly when the file reader accepts it (" + accepted + " of " + targets.length + ")", parity && accepted >= 5 && accepted < targets.length);
        // Take the accepted ones out again.
        for (let i = 0; i < targets.length; i++)
            search.ipc.removeItem("link.p" + i);
        check("the removals leave the content as it was", before === JSON.stringify(store.data));

        refused("a key binding list is not reachable over IPC", root.add("shortcuts", {slot: "k1", chord: "Super+K", command: "sys.lock"}), "list");
        refused("favorites are not reachable over IPC", root.add("favorites", "sys.lock"), "list");
        refused("quick keys are not reachable over IPC", root.add("quickKeys", {key: "gh", command: "sys.lock"}), "list");
        refused("an unknown list", root.add("__proto__", {}), "list");
        refused("an id that exists", root.add("links", link("link.a1", "https://example.org/")), "exists");
        refused("update of an id that is not there", root.request("update", JSON.stringify({list: "links", item: link("link.zz", "https://example.org/")})), "not-found");
        refused("an unknown key in the item", root.request("add", JSON.stringify({list: "links", item: {id: "link.k1", name: "x", target: "https://example.org/", extra: 1}})));
        refused("an unknown key in the request", root.request("add", JSON.stringify({list: "links", item: link("link.k2", "https://example.org/"), more: 1})));
        refused("a wrong id prefix", root.add("links", link("text.k3", "https://example.org/")));
        refused("a hidden character in a name", root.add("links", {id: "link.k4", name: "a‮b", target: "https://example.org/", args: []}));
        refused("a replacement with white space in it", root.add("replacements", {id: "text.k5", replace: "a b", with: "x"}));
        refused("a replacement text over 16 384 characters", root.add("replacements", {id: "text.k6", replace: "k6", with: "x".repeat(16385)}));
        refused("not JSON", root.request("add", "{nope"), "json");
        refused("an array", root.request("add", "[]"), "shape");
        refused("a duplicate key (JsonSafety)", root.request("add", "{\"list\":\"links\",\"list\":\"links\",\"item\":{}}"), "unsafe-json");
        refused("an integer beyond 2^53 (JsonSafety)", root.request("add", "{\"list\":\"links\",\"item\":{},\"n\":9007199254740993}"), "unsafe-json");
        refused("an unknown op", JSON.parse(search.commandRequest("explode", "{}")), "op");
        refused("removeItem of an id that is not a link, replacement or AI command", JSON.parse(search.ipc.removeItem("sys.lock")), "id");
        refused("removeItem of an id that is not there", JSON.parse(search.ipc.removeItem("link.nothere")), "not-found");
        refused("removeItem of an overlong id", JSON.parse(search.ipc.removeItem("link." + "a".repeat(200))), "id");

        // The 64 KiB bound: exactly 65 536 bytes pass, one more is refused before anything is parsed.
        const base = JSON.stringify({list: "replacements", item: {id: "text.big", replace: "big", with: "é".repeat(100)}});
        const pad = n => base + " ".repeat(n);
        const baseBytes = CommandsFile.utf8Length(base);
        const exact = pad(65536 - baseBytes);
        check("the payload is exactly 65 536 bytes", CommandsFile.utf8Length(exact) === 65536);
        const ok = root.request("add", exact);
        check("65 536 bytes are accepted", ok.ok === true);
        refused("65 537 bytes are refused", root.request("update", pad(65537 - baseBytes)), "too-big");
        const hugeName = JSON.stringify({list: "links", item: {id: "link.huge", name: "n".repeat(70000), target: "https://example.org/"}});
        refused("a 70 000-character item is refused", root.request("add", hugeName), "too-big");
        search.ipc.removeItem("text.big");
        check("refused requests did not move the revision (" + (store.revision - rev) + " changes)", store.revision === rev + 2 * accepted + 2);
        check("the content is as before", before === JSON.stringify(store.data));
        until("the writes", () => root.settled(), step3);
    }

    // ---- 3. refusal while locked ------------------------------------------------------------------------------------------

    function step3(): void {
        const rev = store.revision;
        const before = JSON.stringify(store.data);
        SessionState.locked = true;
        const item = JSON.stringify({list: "links", item: link("link.lk", "https://example.org/")});
        const answers = [search.ipc.addItem(item), search.ipc.updateItem(item), search.ipc.removeItem("link.a1"), search.ipc.importFile("/etc/hostname"), search.ipc.importResult()];
        check("every function is refused while locked (" + answers.join(" ") + ")", answers.every(a => a === "{\"ok\":false,\"reason\":\"locked\"}"));
        check("a locked session changes nothing", store.revision === rev && before === JSON.stringify(store.data) && !store.writing);
        SessionState.locked = false;
        const r = root.add("links", link("link.lk", "https://example.org/"));
        check("unlocked again, the same request is accepted", r.ok === true);
        search.ipc.removeItem("link.lk");
        until("the writes", () => root.settled(), step4);
    }

    // ---- 4. many requests in a row ----------------------------------------------------------------------------------------

    function step4(): void {
        for (let i = 0; i < 40; i++)
            root.add("replacements", {id: "text.m" + i, replace: "m" + i, with: "value " + i});
        check("40 requests in a row are all in memory", store.data.replacements.length === 41);
        until("the writes", () => root.settled(), () => {
            root.sh("cat \"$1\"", [root.file], out => {
                const r = CommandsFile.parseText(out);
                check("and all on disk, none lost", r.ok && r.data.replacements.length === 41 && root.same(r.data, root.store.data));
                root.step5();
            });
        });
    }

    // ---- 5. importFile ----------------------------------------------------------------------------------------------------

    property var importCases: []
    property int importAt: 0

    function step5(): void {
        const good = JSON.stringify({v: 1, links: [link("link.i1", "https://example.org/i1"), link("link.a1", "https://example.org/other")],
            replacements: [{id: "text.i2", replace: "i2", with: "two"}], aiCommands: [], quickKeys: [{key: "xx", command: "sys.lock"}],
            shortcuts: [{slot: "k1", chord: "Super+K", command: "sys.lock"}], favorites: ["sys.lock"]});
        const script = "set -e; d=$1; mkdir -p \"$d\"; printf '%s' \"$2\" >\"$d/good.json\"; ln -sf \"$d/good.json\" \"$d/link.json\"; rm -f \"$d/fifo\"; mkfifo \"$d/fifo\"; " +
            "printf '{nope' >\"$d/bad.json\"; printf '{\"v\":2}' >\"$d/foreign.json\"; head -c 1048577 /dev/zero | tr '\\0' ' ' >\"$d/big.json\"; mkdir -p \"$d/dir\"; " +
            "printf '#!/bin/sh\\ntouch %s/ran\\n' \"$d\" >\"$d/script.json\"; chmod +x \"$d/script.json\"; printf '{\"v\":1,\"links\":[{\"id\":\"link.x\",\"name\":\"x\",\"target\":\"javascript:alert(1)\"}]}' >\"$d/evil.json\"";
        root.sh(script, [root.fixtures, good], () => {
            const f = name => root.fixtures + "/" + name;
            root.importCases = [
                {name: "a relative path", path: "good.json", now: "path"},
                {name: "a path with a parent step", path: root.fixtures + "/../fixtures/good.json", now: "path"},
                {name: "a path with a control character", path: f("good.json") + "\n", now: "path"},
                {name: "a symbolic link", path: f("link.json"), reason: "link"},
                {name: "a FIFO", path: f("fifo"), reason: "not-regular"},
                {name: "a directory", path: f("dir"), reason: "not-regular"},
                {name: "a file that is not there", path: f("nothere.json"), reason: "missing"},
                {name: "a file of another user", path: "/etc/passwd", reason: "not-yours"},
                {name: "a file over 1 MiB", path: f("big.json"), reason: "too-big"},
                {name: "content that is not JSON", path: f("bad.json"), reason: "json"},
                {name: "a file of a newer version", path: f("foreign.json"), reason: "version"},
                {name: "a link with a javascript: target", path: f("evil.json"), reason: "not-allowed"},
                {name: "an executable file (never run)", path: f("script.json"), reason: "json"}
            ];
            root.importAt = 0;
            root.nextImport();
        });
    }

    function nextImport(): void {
        if (root.importAt >= root.importCases.length) {
            root.importGood();
            return;
        }
        const c = root.importCases[root.importAt];
        const rev = store.revision;
        const r = JSON.parse(search.ipc.importFile(c.path));
        if (c.now !== undefined) {
            check("importFile refuses " + c.name + " at once (" + JSON.stringify(r) + ")", r.ok === false && r.reason === c.now);
            root.importAt++;
            root.nextImport();
            return;
        }
        check("importFile starts on " + c.name, r.ok === true && r.state === "reading");
        until("the import of " + c.name, () => JSON.parse(search.ipc.importResult()).reason !== "reading", () => {
            const res = JSON.parse(search.ipc.importResult());
            check("importFile refuses " + c.name + " (" + JSON.stringify(res) + ")", res.ok === false && res.reason === c.reason);
            check("and the content did not change", store.revision === rev);
            root.importAt++;
            root.nextImport();
        });
    }

    function importGood(): void {
        sh("test -e \"$1/ran\" && echo ran || echo clean", [root.fixtures], out => {
            check("an executable file that was imported ran nothing", out.trim() === "clean");
            const links = store.data.links.length;
            const rev = store.revision;
            const r = JSON.parse(search.ipc.importFile(root.fixtures + "/good.json"));
            check("importFile accepts a good file", r.ok === true && r.state === "reading");
            const busy = JSON.parse(search.ipc.importFile(root.fixtures + "/good.json"));
            check("a second import while one reads is refused (busy)", busy.ok === false && busy.reason === "busy");
            until("the good import", () => JSON.parse(search.ipc.importResult()).reason !== "reading", () => {
                const res = JSON.parse(search.ipc.importResult());
                check("the import adds the new link and replacement, skips the existing id, ignores the bindings (" + JSON.stringify(res) + ")",
                    res.ok === true && res.added === 2 && res.skipped === 1 && res.ignored === 3);
                check("the existing link was not replaced", store.data.links.find(x => x.id === "link.a1").name === "Renamed");
                check("no key binding came in", store.data.shortcuts.length === 0 && store.data.quickKeys.length === 0 && store.data.favorites.length === 0);
                check("the new link is there", store.data.links.length === links + 1 && store.revision === rev + 1);
                until("the writes", () => root.settled(), root.step6);
            });
        });
    }

    // ---- 6. a corrupt file under a running store --------------------------------------------------------------------------

    property string lastGood: ""

    function step6(): void {
        root.lastGood = JSON.stringify(store.data);
        sh("printf '{\"v\": 1, \"links\": [oops' >\"$1\"", [root.file], () => {
            until("the store sees the corrupt file", () => store.status === "invalid", () => {
                check("a corrupt file: status invalid with a reason (" + store.invalidReason + ")", store.invalidReason === "json");
                check("the store keeps serving the last good content", JSON.stringify(store.data) === root.lastGood);
                const r = root.add("links", link("link.n1", "https://example.org/n1"));
                check("a change is refused while the file is invalid (" + JSON.stringify(r) + ")", r.ok === false && r.reason === "file-invalid" && r.detail === "json");
                const imp = JSON.parse(search.ipc.importFile(root.fixtures + "/good.json"));
                check("an import is refused too", imp.ok === false && imp.reason === "file-invalid");
                const rm = JSON.parse(search.ipc.removeItem("link.a1"));
                check("a removal is refused too", rm.ok === false && rm.reason === "file-invalid");
                root.sh("cat \"$1\"", [root.file], out => {
                    check("the corrupt file was not overwritten", out === "{\"v\": 1, \"links\": [oops");
                    check("keepAside agrees", root.store.keepAside() === true);
                    root.until("the backup", () => root.store.keptAside !== "" && root.settled(), () => {
                        root.sh("cat \"$1\"; echo; echo ---; cat \"$2\"; stat -c %a \"$2\"", [root.store.keptAside, root.file], out2 => {
                            const parts = out2.split("---\n");
                            check("the backup holds the corrupt file exactly", parts[0] === "{\"v\": 1, \"links\": [oops\n");
                            const body = parts[1].slice(0, parts[1].lastIndexOf("}") + 1);
                            const r2 = CommandsFile.parseText(body);
                            check("the new file holds the last good content", r2.ok && JSON.stringify(r2.data) === root.lastGood);
                            check("the new file is 0600", parts[1].trim().endsWith("600"));
                            check("the store works again", root.add("links", root.link("link.n2", "https://example.org/n2")).ok === true);
                            root.until("the writes", () => root.settled(), root.step7);
                        });
                    });
                });
            });
        });
    }

    // ---- 7. an edit by the person that makes it valid, and a foreign file ----------------------------------------------------

    function step7(): void {
        const edited = JSON.stringify({v: 1, replacements: [{id: "text.e1", replace: "e1", with: "edited"}]});
        sh("printf '%s' \"$2\" >\"$1\"", [root.file, edited], () => {
            until("the store follows the edit", () => store.data.replacements.length === 1 && store.data.replacements[0].id === "text.e1", () => {
                check("a valid edit of the file is followed", store.status === "ok" && store.data.links.length === 0);
                sh("printf '{\"v\": 2, \"links\": []}' >\"$1\"", [root.file], () => {
                    until("the foreign file", () => store.status === "invalid", () => {
                        check("a newer version is invalid (" + store.invalidReason + ")", store.invalidReason === "version");
                        check("and the last good content is served", store.data.replacements.length === 1);
                        sh("cat \"$1\"", [root.file], out => {
                            check("and the foreign file is untouched", out === "{\"v\": 2, \"links\": []}");
                            root.step8();
                        });
                    });
                });
            });
        });
    }

    // ---- 8. a file that is invalid at start ---------------------------------------------------------------------------------

    property var startCases: []
    property int startAt: 0

    function step8(): void {
        root.startCases = [
            {name: "a corrupt file", make: "printf 'garbage' >\"$1\"", reason: "json", text: "garbage"},
            {name: "a newer version", make: "printf '{\"v\":2}' >\"$1\"", reason: "version", text: "{\"v\":2}"},
            {name: "an empty file", make: ": >\"$1\"", reason: "json", text: ""},
            {name: "a file with an unknown key", make: "printf '{\"v\":1,\"zzz\":1}' >\"$1\"", reason: "unknown-key", text: "{\"v\":1,\"zzz\":1}"},
            {name: "a directory", make: "mkdir \"$1\"", reason: "unreadable", text: null}
        ];
        root.startAt = 0;
        root.nextStart();
    }

    function nextStart(): void {
        if (root.startAt >= root.startCases.length) {
            root.stepBig();
            return;
        }
        const c = root.startCases[root.startAt];
        const p = root.dir + "/start" + root.startAt + "/commands.json";
        root.secondPath = "";
        sh("rm -rf \"$1\"; mkdir -p \"$(dirname \"$1\")\"; " + c.make, [p], () => {
            root.secondPath = p;
            until("the second store reads " + c.name, () => second.item && second.item.status !== "loading", () => {
                const s = second.item;
                check(c.name + " at start: invalid (" + s.status + " " + s.invalidReason + ")", s.status === "invalid" && s.invalidReason === c.reason);
                check(c.name + " at start: nothing served", root.same(s.data, CommandsFile.empty()));
                const r = JSON.parse(JSON.stringify(s.change("links", link("link.s1", "https://example.org/"), "add")));
                check(c.name + " at start: a change is refused", r.ok === false && r.reason === "file-invalid");
                const k = s.keepAside();
                check(c.name + " at start: keepAside agrees", k === true);
                until("the backup of " + c.name, () => s.keptAside !== "" && !s.writing, () => {
                    sh("stat -c %F \"$1\"; stat -c %F \"$2\"; " + (c.text === null ? "echo -" : "cat \"$2\"; echo"), [p, s.keptAside], out => {
                        const lines = out.split("\n");
                        check(c.name + " at start: a valid empty file replaced it (" + lines[0] + ")", lines[0] === "regular file");
                        check(c.name + " at start: the old one is kept (" + lines[1] + ")", c.text === null ? lines[1] === "directory" : out.indexOf(c.text) > 0 || c.text === "");
                        root.startAt++;
                        root.nextStart();
                    });
                });
            });
        });
    }

    // A file of 63 large replacements (1 032 192 bytes of text): one more is over 1 MiB, refused by the read-back.
    function stepBig(): void {
        const p = root.dir + "/big/commands.json";
        const gen = "rm -rf \"$1\"; mkdir -p \"$(dirname \"$1\")\"; awk 'BEGIN{x=sprintf(\"%16384s\",\"\"); gsub(/ /,\"x\",x); printf \"{\\\"v\\\":1,\\\"replacements\\\":[\"; for(i=0;i<63;i++){if(i)printf \",\"; printf \"{\\\"id\\\":\\\"text.b%d\\\",\\\"replace\\\":\\\"b%d\\\",\\\"with\\\":\\\"%s\\\"}\",i,i,x}; printf \"]}\"}' >\"$1\"";
        root.secondPath = "";
        sh(gen, [p], () => {
            root.secondPath = p;
            until("the second store reads 63 large items", () => second.item && second.item.status !== "loading", () => {
                const s = second.item;
                check("63 large items are read (" + s.status + " " + s.invalidReason + ")", s.status === "ok" && s.data.replacements.length === 63);
                const r = s.change("replacements", {id: "text.over", replace: "over", with: "y".repeat(16384)}, "add");
                check("one more is over 1 MiB and refused (" + JSON.stringify(r) + ")", r.ok === false && r.reason === "too-big" && s.data.replacements.length === 63);
                const small = s.change("replacements", {id: "text.small", replace: "small", with: "y"}, "add");
                check("a small one still fits", small.ok === true && s.data.replacements.length === 64);
                until("the writes", () => !s.writing, root.stepCap);
            });
        });
    }

    // A list of 1 999 items: the 2 000th is accepted, the next is refused by the read-back.
    function stepCap(): void {
        const p = root.dir + "/cap/commands.json";
        const gen = "rm -rf \"$1\"; mkdir -p \"$(dirname \"$1\")\"; awk 'BEGIN{printf \"{\\\"v\\\":1,\\\"replacements\\\":[\"; for(i=0;i<1999;i++){if(i)printf \",\"; printf \"{\\\"id\\\":\\\"text.n%d\\\",\\\"replace\\\":\\\"n%d\\\",\\\"with\\\":\\\"v\\\"}\",i,i}; printf \"]}\"}' >\"$1\"";
        root.secondPath = "";
        sh(gen, [p], () => {
            root.secondPath = p;
            until("the second store reads 1 999 items", () => second.item && second.item.status !== "loading", () => {
                const s = second.item;
                check("1 999 items are read (" + s.status + " " + s.invalidReason + ")", s.status === "ok" && s.data.replacements.length === 1999);
                const r1 = s.change("replacements", {id: "text.last", replace: "last", with: "v"}, "add");
                const r2 = s.change("replacements", {id: "text.over", replace: "over", with: "v"}, "add");
                check("the 2 000th item is accepted, the 2 001st is refused (" + JSON.stringify(r2) + ")", r1.ok === true && r2.ok === false && r2.reason === "too-many" && s.data.replacements.length === 2000);
                until("the writes", () => !s.writing, root.step9);
            });
        });
    }

    // ---- 9. a valid file at start is served, and a change on top of it keeps it ------------------------------------------------

    function step9(): void {
        const p = root.dir + "/valid/commands.json";
        const content = JSON.stringify({v: 1, favorites: ["sys.lock"], replacements: [{id: "text.v1", replace: "v1", with: "valid"}]});
        root.secondPath = "";
        sh("rm -rf \"$1\"; mkdir -p \"$(dirname \"$1\")\"; printf '%s' \"$2\" >\"$1\"", [p, content], () => {
            root.secondPath = p;
            until("the second store reads the valid file", () => second.item && second.item.status !== "loading", () => {
                const s = second.item;
                check("a valid file at start: ok and served", s.status === "ok" && s.data.favorites.length === 1 && s.data.replacements[0].id === "text.v1");
                const r = s.change("quickKeys", {key: "gh", command: "sys.lock"}, "add");
                check("a quick key is added in process (any list)", r.ok === true && s.data.quickKeys.length === 1 && s.data.favorites.length === 1);
                check("a duplicate quick key is refused", s.change("quickKeys", {key: "gh", command: "sys.lock"}, "add").reason === "exists");
                check("a shortcut with a bad chord is refused in process", s.change("shortcuts", {slot: "k1", chord: "K", command: "sys.lock"}, "add").ok === false);
                check("a favorite is removed in process", s.remove("favorites", "sys.lock").ok === true && s.data.favorites.length === 0);
                until("the writes", () => !s.writing, () => {
                    sh("cat \"$1\"", [p], out => {
                        const f = CommandsFile.parseText(out);
                        check("the file holds the old and the new content", f.ok && f.data.quickKeys.length === 1 && f.data.replacements.length === 1 && f.data.favorites.length === 0);
                        root.finish();
                    });
                });
            });
        });
    }

    Timer {
        interval: 300
        running: true
        onTriggered: root.until("the store reads its file", () => root.store.status !== "loading", root.step1)
    }
}
