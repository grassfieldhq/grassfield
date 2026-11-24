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
        // The rate limit of the IPC path has its own step (stepSafety); the others send many requests in a row.
        store.rateBurst = 1000000;
        store.ratePerSecond = 1000000;
        store.tokens = 1000000;
        store.dutyFactor = 0;
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
                {name: "a file over 256 KiB", path: f("big.json"), reason: "too-big"},
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

    // A file of 15 large replacements (245 760 bytes of text): one more is over 256 KiB, refused by the read-back.
    function stepBig(): void {
        const p = root.dir + "/big/commands.json";
        const gen = "rm -rf \"$1\"; mkdir -p \"$(dirname \"$1\")\"; awk 'BEGIN{x=sprintf(\"%16384s\",\"\"); gsub(/ /,\"x\",x); printf \"{\\\"v\\\":1,\\\"replacements\\\":[\"; for(i=0;i<15;i++){if(i)printf \",\"; printf \"{\\\"id\\\":\\\"text.b%d\\\",\\\"replace\\\":\\\"b%d\\\",\\\"with\\\":\\\"%s\\\"}\",i,i,x}; printf \"]}\"}' >\"$1\"";
        root.secondPath = "";
        sh(gen, [p], () => {
            root.secondPath = p;
            until("the second store reads 15 large items", () => second.item && second.item.status !== "loading", () => {
                const s = second.item;
                check("15 large items are read (" + s.status + " " + s.invalidReason + ")", s.status === "ok" && s.data.replacements.length === 15);
                const r = s.change("replacements", {id: "text.over", replace: "over", with: "y".repeat(16384)}, "add");
                check("one more is over 256 KiB and refused (" + JSON.stringify(r) + ")", r.ok === false && r.reason === "too-big" && s.data.replacements.length === 15);
                const small = s.change("replacements", {id: "text.small", replace: "small", with: "y"}, "add");
                check("a small one still fits", small.ok === true && s.data.replacements.length === 16);
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
                        root.stepSafety();
                    });
                });
            });
        });
    }

    // ---- 10. review fixes: surrogates, a restored file, an outside edit during a write, the rate limit, the lock during an import --

    property var safe: null

    function stepSafety(): void {
        const lone = "{\"list\":\"replacements\",\"item\":{\"id\":\"text.s\",\"replace\":\"zz\",\"with\":\"a\\ud800b\"}}";
        // The main store is left invalid by step 7 (a newer version): the person agrees, it is kept aside and the store works again.
        sh("printf '{\"v\":1,\"replacements\":[{\"id\":\"text.f\",\"replace\":\"ff\",\"with\":\"a\\\\ud800b\"}]}' >\"$1/lone-file.json\"", [root.fixtures], () => {
            check("keepAside agrees again", store.keepAside() === true);
            until("the store works again", () => store.status === "ok" && !store.writing && store.keptAside !== "", () => {
                const s = store;
                const p = store.path;
                s.rateBurst = 1000000;
                s.ratePerSecond = 1000000;
                s.tokens = 1000000;
                s.dutyFactor = 0;
                root.safe = s;
                const rev = s.revision;
                // Unpaired surrogates: refused everywhere (a pair is fine).
                const a = JSON.parse(search.ipc.addItem(lone));
                check("a lone surrogate in a request is refused (" + JSON.stringify(a) + ")", a.ok === false && a.reason === "surrogate");
                const k = JSON.parse(search.ipc.addItem(lone.slice(0, -1) + ",\"\\ud800\":1}"));
                check("a lone surrogate in a key is refused", k.ok === false && k.reason === "surrogate");
                const low = JSON.parse(search.ipc.addItem(lone.replace("\\ud800b", "\\udc00")));
                check("a lone low surrogate is refused", low.ok === false && low.reason === "surrogate");
                check("a lone surrogate in a replacement is refused in process", s.change("replacements", {id: "text.p", replace: "pp", with: "a" + String.fromCharCode(0xd800) + "b"}, "add").ok === false);
                check("refused requests changed nothing", s.revision === rev && !s.writing);
                const pair = JSON.parse(search.ipc.addItem(JSON.stringify({list: "replacements", item: {id: "text.pair", replace: "pp", with: "x\ud83d\ude00y"}})));
                check("a valid surrogate pair is accepted", pair.ok === true);
                until("the pair is written", () => !s.writing, () => {
                    root.sh("cat \"$1\"", [p], out => {
                        const f = CommandsFile.parseText(out);
                        check("the file holds the pair, the store is not stuck (" + s.writeError + ")", f.ok && f.data.replacements.some(x => x.id === "text.pair") && s.writeError === "" && !s.writing);
                        root.safeImport();
                    });
                });
            });
        });
    }

    function safeImport(): void {
        const s = root.safe;
        const f = name => root.fixtures + "/" + name;
        const r = JSON.parse(search.ipc.importFile(f("lone-file.json")));
        check("importFile starts on a file with a lone surrogate", r.ok === true);
        until("the import ends", () => JSON.parse(search.ipc.importResult()).reason !== "reading", () => {
            const res = JSON.parse(search.ipc.importResult());
            check("a file with a lone surrogate is refused by an import (" + JSON.stringify(res) + ")", res.ok === false && res.reason === "surrogate");
            // importResult is not left with an older outcome by a refused call.
            s.importFile("relative.json");
            check("a refused importFile is the last outcome", s.lastImport.reason === "path");
            root.safeRestore();
        });
    }

    // A file made invalid and put back exactly as the store wrote it is valid again.
    function safeRestore(): void {
        const s = root.safe;
        const p = s.path;
        sh("cp \"$1\" \"$1.keep\"; printf 'oops' >\"$1\"", [p], () => {
            until("the file is invalid", () => s.status === "invalid", () => {
                root.sh("cp \"$1.keep\" \"$1\"", [p], () => {
                    root.until("the restored file is valid again", () => s.status === "ok", () => {
                        check("a file restored to the store's last write: status ok, invalid reason cleared", s.invalidReason === "" && s.status === "ok");
                        check("and a change is accepted again", s.change("replacements", {id: "text.r1", replace: "r1", with: "x"}, "add").ok === true);
                        root.until("the write", () => !s.writing, root.safeExternal);
                    });
                });
            });
        });
    }

    // An outside edit seen while a write runs: the next change is refused (changed-on-disk), the edit is kept, then the caller retries.
    function safeExternal(): void {
        const s = root.safe;
        const mine = s.change("replacements", {id: "text.w1", replace: "w1", with: "x"}, "add");
        check("a change starts a write (" + JSON.stringify(mine) + " " + s.writing + " " + s.status + ")", mine.ok === true && s.writing);
        s.take("{\"v\":1,\"favorites\":[\"sys.lock\"]}");
        const r = s.change("replacements", {id: "text.w2", replace: "w2", with: "x"}, "add");
        check("a change queued behind an outside edit is refused (" + JSON.stringify(r) + ")", r.ok === false && r.reason === "changed-on-disk");
        until("the store settles", () => !s.writing && s.external === "", () => {
            check("the outside edit became the content, and the store says so", s.data.favorites.length === 1 && s.data.replacements.length === 0 && s.writeError === "changed-on-disk");
            const again = s.change("replacements", {id: "text.w2", replace: "w2", with: "x"}, "add");
            check("the retry is accepted", again.ok === true && s.data.favorites.length === 1);
            until("the retry is written", () => !s.writing, root.safeRate);
        });
    }

    // The IPC rate limit: a loop of 400 requests is bounded to the burst, and the refusal is cheap.
    function safeRate(): void {
        const s = root.safe;
        s.rateBurst = 10;
        s.ratePerSecond = 5;
        s.tokens = 10;
        s.tokensAt = 0;
        const t0 = Date.now();
        let ok = 0;
        let busy = 0;
        let noRetry = 0;
        for (let i = 0; i < 400; i++) {
            const r = s.request("add", JSON.stringify({list: "replacements", item: {id: "text.l" + i, replace: "l" + i, with: "x"}}));
            if (r.ok)
                ok++;
            else if (r.reason === "busy") {
                busy++;
                if (!(r.retryAfterMs > 0))
                    noRetry++;
            }
        }
        check("every busy answer says when to retry", busy > 0 && noRetry === 0);
        const ms = Date.now() - t0;
        check("400 requests in a loop: the burst at most is accepted (" + ok + " accepted, " + busy + " busy, " + ms + " ms)", ok >= 1 && ok <= 12 && busy > 0 && ok + busy === 400);
        check("the in-process path is not limited", s.change("replacements", {id: "text.inproc", replace: "ip", with: "x"}, "add").ok === true);
        s.dutyFactor = 0;
        s.cooldownUntil = 0;
        s.tokensAt = Date.now() - 1000;
        s.tokens = 0;
        check("tokens come back with time (5 per second)", s.request("remove", "text.inproc").ok === true);
        s.rateBurst = 1000000;
        s.ratePerSecond = 1000000;
        s.tokens = 1000000;
        until("the writes", () => !s.writing, root.safeLock);
    }

    // An import that finishes reading after the session locked commits nothing.
    function safeLock(): void {
        const s = root.safe;
        const before = JSON.stringify(s.data);
        const r = s.importFile(root.fixtures + "/good.json");
        check("an import starts", r.ok === true);
        SessionState.locked = true;
        check("the store follows the session's lock", search.commandStore.locked === true);
        s.locked = true;
        until("the import ends", () => s.lastImport.reason !== "reading", () => {
            check("an import that ends while locked is refused (" + JSON.stringify(s.lastImport) + ")", s.lastImport.ok === false && s.lastImport.reason === "locked");
            check("and committed nothing", JSON.stringify(s.data) === before && !s.writing);
            SessionState.locked = false;
            s.locked = false;
            check("the store is unlocked with the session", search.commandStore.locked === false);
            root.safeHang();
        });
    }

    // A writer that never ends is killed after the limit: the store reports it, is not stuck, and writes again with the next change.
    function safeHang(): void {
        const s = root.safe;
        const real = s.writerTool;
        sh("printf 'sleep 30\\n' >\"$1/hang.sh\"", [root.fixtures], () => {
            s.writerTool = root.fixtures + "/hang.sh";
            s.writeLimitMs = 400;
            check("a change is accepted", s.change("replacements", {id: "text.h1", replace: "h1", with: "x"}, "add").ok === true && s.writing);
            until("the hung write is ended", () => !s.writing, () => {
                check("the hung write is reported (" + s.writeError + ")", s.writeError === "write-timeout");
                s.writerTool = real;
                check("the next change is accepted", s.change("replacements", {id: "text.h2", replace: "h2", with: "x"}, "add").ok === true);
                until("the next write ends", () => !s.writing, () => {
                    root.sh("cat \"$1\"", [s.path], out => {
                        const f = CommandsFile.parseText(out);
                        check("the file then holds both changes, the error is cleared (" + s.writeError + " ok=" + f.ok + " " + out.length + " " + (f.ok ? f.data.replacements.map(x => x.id).join() : f.reason) + ")", f.ok && f.data.replacements.some(x => x.id === "text.h1") && f.data.replacements.some(x => x.id === "text.h2") && s.writeError === "");
                        root.safeRace();
                    });
                });
            });
        });
    }

    // The person saves the file while a (slow) write of the store runs: the write lands over it, and the person's text is not lost.
    function safeRace(): void {
        const s = root.safe;
        const real = s.writerTool;
        const p = s.path;
        s.writeLimitMs = 10000;
        const valid = "{\"v\":1,\"favorites\":[\"sys.lock\"]}";
        sh("printf 'sleep 1\\nexec sh \"%s\" \"$@\"\\n' \"$2\" >\"$1/slow.sh\"", [root.fixtures, real], () => {
            s.writerTool = root.fixtures + "/slow.sh";
            check("a change starts a slow write", s.change("replacements", {id: "text.q1", replace: "q1", with: "x"}, "add").ok === true && s.writing);
            root.sh("printf '%s' \"$2\" >\"$1\"", [p, valid], () => {
                root.until("the store sees the edit during the write", () => s.external !== "", () => {
                    root.until("the write and the write-back end", () => !s.writing && s.external === "", () => {
                        root.sh("cat \"$1\"", [p], out => {
                            check("a valid edit during a write is written back as the person saved it (" + out.slice(0, 60) + ")", out === valid);
                            check("and is the content (" + s.writeError + ")", s.data.favorites.length === 1 && s.data.replacements.every(x => x.id !== "text.q1") && s.writeError === "changed-on-disk");
                            root.safeRaceInvalid(real);
                        });
                    });
                });
            });
        });
    }

    function safeRaceInvalid(real: string): void {
        const s = root.safe;
        const p = s.path;
        const before = JSON.stringify(s.data);
        check("a change starts a slow write", s.change("replacements", {id: "text.q2", replace: "q2", with: "x"}, "add").ok === true && s.writing);
        sh("printf '{broken by person' >\"$1\"", [p], () => {
            until("the store sees the edit during the write", () => s.external !== "", () => {
                until("the write and the aside end", () => !s.writing && s.external === "", () => {
                    root.sh("cat \"$1\"; echo ---; cat \"$2\"", [p, s.keptAside], out => {
                        const parts = out.split("---\n");
                        const f = CommandsFile.parseText(parts[0]);
                        check("an invalid edit during a write is kept aside, the store's file stays (" + s.keptAside.slice(-30) + ")", parts[1] === "{broken by person\n".slice(0, -1) + "\n" || parts[1].indexOf("{broken by person") === 0);
                        check("and the store's file is the store's content, valid", f.ok && f.data.replacements.some(x => x.id === "text.q2"));
                        check("and the store reports it", s.writeError === "changed-on-disk" && s.status === "ok" && JSON.stringify(s.data) !== before);
                        s.writerTool = real;
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
