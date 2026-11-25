import QtQuick
import QtTest
import "../../shell/search/Scripts.js" as Scripts
import "../../shell/search/Commands.js" as Commands

TestCase {
    name: "Scripts"

    readonly property string rlo: String.fromCharCode(0x202e)

    function header(title, extra) {
        return "#!/bin/sh\n# @raycast.schemaVersion 1\n# @raycast.title " + title + "\n# @raycast.mode silent\n" + (extra || "");
    }

    function file(name, head, extra) {
        const id = "script." + Qt.md5(name).slice(0, 20);
        return Object.assign({name: name, path: "/f/" + name, ok: true, link: false, size: 10, head: head, id: id}, extra || {});
    }

    function report(files, status) {
        return {v: 1, folders: [{path: "/f", status: status || "ok", scripts: files}]};
    }

    function test_failureText() {
        const t = {notRun: "not run", refused: "refused", noSandbox: "no sandbox", failed: "failed (%1)"};
        compare(Scripts.failureText(-1, t), "not run");
        compare(Scripts.failureText(undefined, t), "not run");
        compare(Scripts.failureText(70, t), "refused");
        compare(Scripts.failureText(71, t), "no sandbox");
        compare(Scripts.failureText(2, t), "failed (2)");
    }

    function test_folders() {
        compare(Scripts.folders([], "/home/u", "/home/u/.local/share").join("|"), "/home/u/.local/share/grassfield/script-commands");
        compare(Scripts.folders(["~/Scripts", "/opt/s/", "~/Scripts"], "/home/u/", "/home/u/.local/share/").join("|"),
            "/home/u/.local/share/grassfield/script-commands|/home/u/Scripts|/opt/s");
        // The path rule of the commands file: relative, parent steps, placeholders, network paths and non-strings are left out.
        compare(Scripts.folders(["rel", "/a/../b", "//host/share", "/x/{y}", "/c\u0001d", 5, null, "", "/ok"], "/h", "/d").join("|"), "/d/grassfield/script-commands|/ok");
        compare(Scripts.folders("not a list", "/h", "/d").length, 1);
        const many = [];
        for (let i = 0; i < 40; i++)
            many.push("/m/" + i);
        compare(Scripts.folders(many, "/h", "/d").length, 13);
    }

    function test_listing() {
        const l = Scripts.listing(report([
            file("good.sh", header("Good", "# @raycast.packageName Pack\n# @raycast.description Does a thing\n")),
            file("win.sh", header("Win", "# @raycast.platform windows\n")),
            file("tpl.template.sh", header("Tpl")),
            file("badhead.sh", "#!/bin/sh\n# @raycast.schemaVersion 2\n"),
            file("nomode.sh", "#!/bin/sh\n# @raycast.schemaVersion 1\n# @raycast.title T\n"),
            {name: "gw.sh", path: "/f/gw.sh", ok: false, reason: "writable"},
            {name: "odd.sh", path: "/f/odd.sh", ok: false}
        ]));
        compare(l.scripts.length, 1);
        compare(l.scripts[0].meta.title, "Good");
        compare(l.scripts[0].meta.packageName, "Pack");
        compare(l.scripts[0].folder, "/f");
        compare(l.problems.map(p => p.path + ":" + p.reason).join("|"),
            "/f/badhead.sh:header:schemaVersion:unsupported|/f/nomode.sh:header:mode:missing|/f/gw.sh:writable|/f/odd.sh:refused");
    }

    function test_hostileReports() {
        // A report is data: a malformed one never throws and never lists what it does not vouch for.
        compare(Scripts.parseScan("not json"), null);
        compare(Scripts.parseScan("{\"v\": 2, \"folders\": []}"), null);
        compare(Scripts.parseScan("[]"), null);
        compare(Scripts.parseScan("null"), null);
        verify(Scripts.parseScan("{\"v\": 1, \"folders\": []}") !== null);
        compare(Scripts.listing(null).scripts.length, 0);
        compare(Scripts.listing({v: 1, folders: [null, 5, {path: 3}, {path: "/f", scripts: "x"}]}).scripts.length, 0);
        const good = header("T");
        const bad = [
            file("a.sh", good, {id: "script.zz"}),                       // an id the scanner does not make
            file("b.sh", good, {id: "../../x"}),
            file("c" + rlo + "d.sh", good),                              // a bidirectional override in the name
            file("e​f.sh", good),                                   // a zero-width character
            file("g\u0001h.sh", good),
            file("lone\ud800.sh", good),                                 // an unpaired surrogate
            file(" lead.sh", good),
            file("", good),
            file("x".repeat(300), good),
            file("i.sh", 5),                                             // no text head
            file("j.sh", good, {ok: "yes"})                              // not literally true
        ];
        const l = Scripts.listing(report(bad));
        compare(l.scripts.length, 0);
        compare(l.problems.length, bad.length);
        // A refused folder is a problem, never a listing, even when the report carries scripts.
        const rf = Scripts.listing(report([], "refused-folder"));
        compare(rf.problems[0].reason, "refused-folder");
        compare(rf.scripts.length, 0);
    }

    function test_hostileHeaders() {
        // The header is read by ScriptMeta (strict): a title with a hidden character, a repeated key or a fourth argument is a problem.
        const heads = [
            header("Evil" + rlo + "gnp"),
            header("T", "# @raycast.title Again\n"),
            header("T", "# @raycast.argument1 {\"type\":\"text\"}\n# @raycast.argument2 {\"type\":\"text\"}\n# @raycast.argument3 {\"type\":\"text\"}\n# @raycast.argument4 {\"type\":\"text\"}\n"),
            header("T", "# @raycast.icon https://example.org/i.png\n# @raycast.authorURL http://user:pw@example.org/\n")
        ];
        const l = Scripts.listing(report(heads.map((h, i) => file("h" + i + ".sh", h))));
        compare(l.scripts.length, 0);
        compare(l.problems.length, 4);
    }

    function test_duplicateIdsAreListedOnce() {
        const a = file("same.sh", header("A"));
        const b = Object.assign({}, a, {path: "/other/same.sh"});
        compare(Scripts.listing(report([a, b])).scripts.length, 1);
    }

    function test_entries() {
        const l = Scripts.listing(report([
            file("a.sh", header("Alpha", "# @raycast.packageName Pack\n# @raycast.description Does a thing\n")),
            file("b.sh", header("Beta"))
        ]));
        let locked = false;
        const asked = [];
        const list = Scripts.entries(l.scripts, {subtitle: "Script command", keywordScript: "script"}, () => locked, (s, args, origin) => asked.push([s.name, args.join(), origin]));
        compare(list.length, 2);
        compare(list[0].title, "Alpha");
        compare(list[0].subtitle, "Pack");
        compare(list[1].subtitle, "Script command");
        compare(list[0].kind, "script");
        compare(list[0].keywords.join("|"), "script|Does a thing");
        // The registry takes them as they are (a valid id, a title, a run).
        const reg = Commands.build([list]);
        compare(reg.errors.length, 0);
        compare(reg.entries.length, 2);
        verify(Commands.run(reg, list[0].id, ["x"], "ipc"));
        compare(asked.join("|"), "a.sh,x,ipc");
        verify(Commands.match(reg, "alpha").length > 0);
        // Locked: nothing is asked.
        locked = true;
        Commands.run(reg, list[1].id, [], "row");
        compare(asked.length, 1);
    }
}
