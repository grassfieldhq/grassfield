import QtQuick
import QtTest
import "../../shell/search/CommandsFile.js" as CommandsFile

TestCase {
    name: "CommandsFile"

    readonly property string rlo: String.fromCharCode(0x202e)
    readonly property string nul: String.fromCharCode(0)

    function link(target, extra) {
        return Object.assign({id: "link.a1", name: "Docs", target: target}, extra || {});
    }

    function file(list, items) {
        const o = {v: 1};
        o[list] = items;
        return o;
    }

    function bad(value, path, reason) {
        const r = CommandsFile.validate(value);
        verify(!r.ok, "must be refused: " + JSON.stringify(value).slice(0, 120));
        if (path !== undefined)
            compare(r.path, path);
        if (reason !== undefined)
            compare(r.reason, reason);
    }

    function target(t) {
        return CommandsFile.checkTarget(t);
    }

    function test_emptyAndDefaults() {
        const r = CommandsFile.validate({v: 1});
        verify(r.ok);
        compare(JSON.stringify(r.data), JSON.stringify(CommandsFile.empty()));
        compare(r.data.v, 1);
        verify(CommandsFile.parseText("{\"v\": 1}").ok);
        verify(CommandsFile.parseText("{\"v\": 1, \"links\": []}").ok);
    }

    function test_fullFile() {
        const r = CommandsFile.parseText(JSON.stringify({
            v: 1,
            quickKeys: [{key: "gh", command: "sys.lock"}, {key: "to do", command: "sys.sleep"}],
            shortcuts: [{slot: "k1", chord: "Super+Shift+K", command: "sys.lock"}, {slot: "k99", chord: "Ctrl+Alt+code:61", command: "sys.sleep"}],
            favorites: ["sys.lock", "script.0123abcd"],
            links: [link("https://example.org/?q={argument}", {openWith: "firefox.desktop", args: [{placeholder: "Query"}]}),
                    {id: "link.b2", name: "Mail", target: "mailto:me@example.org?subject={argument}"},
                    {id: "link.c3", name: "Notes", target: "~/Documents/notes"},
                    {id: "link.d4", name: "Editor", target: "", openWith: "org.kde.kate.desktop"}],
            replacements: [{id: "text.e5", replace: "brb", with: "be right back\nsoon\t{cursor}"}],
            aiCommands: [{id: "ai.f6", name: "Summarize", prompt: "Summarize: {clipboard}"}]
        }));
        verify(r.ok);
        compare(r.data.links.length, 4);
        compare(r.data.links[0].args[0].optional, false);
        compare(r.data.links[3].target, "");
        compare(r.data.replacements[0].with, "be right back\nsoon\t{cursor}");
    }

    function test_topLevel() {
        bad(null, "", "shape");
        bad([], "", "shape");
        bad("x", "", "shape");
        bad({}, "v", "version");
        bad({v: 2}, "v", "version");
        bad({v: "1"}, "v", "version");
        bad({v: 1, extra: 1}, "", "unknown-key");
        bad({v: 1, __proto__: 1, "constructor": 1}, "", "unknown-key");
        bad({v: 1, links: {}}, "links", "type");
        bad({v: 1, favorites: "sys.lock"}, "favorites", "type");
    }

    function test_oversize() {
        const many = [];
        for (let i = 0; i < 2001; i++)
            many.push("sys.a" + i);
        bad({v: 1, favorites: many}, "favorites", "too-many");
        many.pop();
        verify(CommandsFile.validate({v: 1, favorites: many}).ok);
        // 256 KiB: bytes, not characters
        compare(CommandsFile.parseText("{\"v\": 1, \"pad\": \"" + "x".repeat(262144) + "\"}").reason, "too-big");
        const head = "{\"v\": 1, \"replacements\": [], \"pad\":\"";
        verify(CommandsFile.parseText(head + "é".repeat((262144 - 40) / 2) + "\"}").reason !== "too-big", "just under the cap is not too-big");
        compare(CommandsFile.parseText(head + "é".repeat(131072) + "\"}").reason, "too-big", "two-byte characters are counted in bytes");
        compare(CommandsFile.parseText("{\"v\": 1, \"pad\": \"" + "\u20ac".repeat(400000) + "\"}").reason, "too-big");
        bad(file("replacements", [{id: "text.a", replace: "r", with: "x".repeat(16385)}]), "replacements[0].with", "with");
        verify(CommandsFile.validate(file("replacements", [{id: "text.a", replace: "r", with: "x".repeat(16384)}])).ok);
        bad(file("aiCommands", [{id: "ai.a", name: "n", prompt: "x".repeat(16385)}]), "aiCommands[0].prompt", "prompt");
        bad(file("links", [link("https://example.org/" + "a".repeat(2048))]), "links[0].target", "length");
        bad(file("links", [link("https://example.org/", {name: "n".repeat(81)})]), "links[0].name", "name");
    }

    function test_text() {
        compare(CommandsFile.parseText(5).reason, "text");
        compare(CommandsFile.parseText("{").reason, "json");
        compare(CommandsFile.parseText("").reason, "json");
        compare(CommandsFile.parseText("{\"v\": 1, \"v\": 1}").reason, "unsafe-json");
        compare(CommandsFile.parseText("{\"v\": 1, \"links\": [], \"links\": []}").reason, "unsafe-json");
        compare(CommandsFile.parseText("{\"v\": 1, \"__proto__\": {}, \"__proto__\": {}}").reason, "unsafe-json");
        compare(CommandsFile.parseText("{\"v\": 1, \"favorites\": [], \"n\": 12345678901234567890}").reason, "unsafe-json");
        compare(CommandsFile.parseText("{\"v\": 1, \"__proto__\": {\"x\": 1}}").reason, "unknown-key");
    }

    function test_wrongTypes() {
        bad(file("quickKeys", ["gh"]), "quickKeys[0]", "shape");
        bad(file("quickKeys", [null]), "quickKeys[0]", "shape");
        bad(file("quickKeys", [{key: 1, command: "sys.lock"}]), "quickKeys[0].key", "key");
        bad(file("quickKeys", [{key: "gh", command: 5}]), "quickKeys[0].command", "id");
        bad(file("favorites", [5]), "favorites[0]", "id");
        bad(file("favorites", [["sys.lock"]]), "favorites[0]", "id");
        bad(file("links", [{id: "link.a", name: 5, target: "https://x.org/"}]), "links[0].name", "name");
        bad(file("links", [link("https://x.org/", {args: "x"})]), "links[0].args", "args");
        bad(file("links", [link("https://x.org/", {args: [{placeholder: 1}]})]), "links[0].args[0]", "arg");
        bad(file("links", [link("https://x.org/", {args: [{placeholder: "q", optional: "yes"}]})]), "links[0].args[0].optional", "type");
        bad(file("links", [link("https://x.org/", {args: [{placeholder: "q", type: "password"}]})]), "links[0].args[0]", "arg");
        bad(file("links", [link("https://x.org/", {args: [{placeholder: "a"}, {placeholder: "b"}, {placeholder: "c"}, {placeholder: "d"}]})]), "links[0].args", "args");
        bad(file("links", [link("https://x.org/", {extra: 1})]), "links[0]", "shape");
        bad(file("links", [link("https://x.org/", {openWith: "-rf"})]), "links[0].openWith", "openWith");
        bad(file("links", [link("https://x.org/", {openWith: "a b.desktop"})]), "links[0].openWith", "openWith");
        bad(file("links", [link("https://x.org/", {openWith: 5})]), "links[0].openWith", "openWith");
        bad(file("links", [link("", {})]), "links[0].target", "length");
        bad(file("replacements", [{id: "text.a", replace: "a b", with: "x"}]), "replacements[0].replace", "replace");
        bad(file("replacements", [{id: "text.a", replace: "r", with: ""}]), "replacements[0].with", "with");
        bad(file("replacements", [{id: "text.a", replace: "r", with: 5}]), "replacements[0].with", "with");
        bad(file("replacements", [{id: "text.a", replace: "r", with: "x", name: "n"}]), "replacements[0]", "shape");
    }

    function test_ids() {
        for (const id of ["Link.a", "link.", "link", "link.A", "text.a", "link.a b", "link." + "a".repeat(60), "ai.a", "1link.a", "link.a\n"])
            bad(file("links", [{id: id, name: "n", target: "https://x.org/"}]), "links[0].id", "id");
        bad({v: 1, links: [link("https://x.org/")], replacements: [{id: "link.a1", replace: "r", with: "x"}]}, "replacements[0].id", "id");
        bad({v: 1, links: [link("https://x.org/"), link("https://y.org/")]}, "links[1].id", "duplicate");
        bad(file("favorites", ["Sys.Lock"]), "favorites[0]", "id");
        bad(file("favorites", ["sys.lock", "sys.lock"]), "favorites[1]", "duplicate");
        bad(file("quickKeys", [{key: "gh", command: "sys lock"}]), "quickKeys[0].command", "id");
    }

    function test_quickKeys() {
        for (const k of ["GH", "g h ", " gh", "", "g-h", "g_h", "ghghghghghghghghg", "g\nh", "g.h"])
            bad(file("quickKeys", [{key: k, command: "sys.lock"}]), "quickKeys[0].key", "key");
        bad(file("quickKeys", [{key: "gh", command: "a.b"}, {key: "gh", command: "c.d"}]), "quickKeys[1].key", "duplicate");
        verify(CommandsFile.validate(file("quickKeys", [{key: "1", command: "a.b"}, {key: "a b 2", command: "c.d"}])).ok);
    }

    function test_shortcuts() {
        const ok = (slot, chord) => CommandsFile.validate(file("shortcuts", [{slot: slot, chord: chord, command: "sys.lock"}])).ok;
        verify(ok("k1", "Super+K"));
        verify(ok("k10", "Super+Shift+Alt+Ctrl+F12"));
        verify(ok("k99", "Alt+code:61"));
        for (const slot of ["k0", "k100", "K1", "k01", "1", "k", "k1 ", "slot"])
            verify(!ok(slot, "Super+K"), slot);
        // the chord reaches the compositor: a fixed list of modifiers and a plain key only
        for (const c of ["K", "Super", "Super+", "+K", "Super+Super+K", "super+k", "Mod4+K", "Super+K;exec,rm", "Super+K, exec", "Super+code:1234", "Super+code:", "Super+a-b",
                         "Super+" + "a".repeat(33), "Super+K\n", "Super Shift+K", "Super+K+L", "Meta+K", "Super+Shift+Alt+Ctrl+Super+K", "Super+" + nul])
            verify(!ok("k1", c), c);
        bad(file("shortcuts", [{slot: "k1", chord: "Super+K", command: "a.b"}, {slot: "k1", chord: "Super+L", command: "a.b"}]), "shortcuts[1].slot", "duplicate");
        bad(file("shortcuts", [{slot: "k1", chord: "Super+K", command: "a.b"}, {slot: "k2", chord: "SUPER+K".replace("SUPER", "Super"), command: "c.d"}]), "shortcuts[1].chord", "duplicate");
        bad(file("shortcuts", [{slot: "k1", chord: "Super+K", command: "a.b", extra: 1}]), "shortcuts[0]", "shape");
    }

    // The link allowlist (ADR-0067 D-7).
    function test_targetAllowed() {
        compare(target("https://example.org/path?q=1#x").kind, "web");
        compare(target("http://example.org:8080/").kind, "web");
        compare(target("HTTPS://Example.org/").target, "https://Example.org/");
        compare(target("https://example.org/?q={argument}&d={date}").kind, "web");
        compare(target("https://[::1]:8080/a").kind, "web");
        compare(target("mailto:me@example.org").kind, "mail");
        compare(target("mailto:me@example.org?subject={argument}&body=hi%20there").kind, "mail");
        compare(target("/home/u/Documents").kind, "path");
        compare(target("~/My Documents/a b").kind, "path");
        compare(target("~/Documents").kind, "path");
        compare(target("file:///home/u/a%20b.txt").target, "/home/u/a b.txt");
        compare(target("file://localhost/home/u/x").target, "/home/u/x");
        compare(target("FILE:///home/u/x").target, "/home/u/x");
    }

    function test_targetRefused() {
        const refusedList = [
            "javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,<b>x</b>", "blob:https://example.org/uuid", "vbscript:x",
            "smb://host/share", "sftp://host/x", "ftp://host/x", "dav://host/x", "davs://host/x", "nfs://host/x", "ssh://host", "telnet://host", "tel:+123",
            "x-scheme-handler/http", "steam://run/1", "slack://open", "ms-settings:", "about:blank", "chrome://settings", "view-source:https://x.org/",
            "file://host/etc/passwd", "file://user@localhost/x", "file:///a/../etc/passwd", "file:///a/%2e%2e/b", "file:///x?y", "file:///x#y", "file:relative", "file://",
            "relative/path", "./a", "../a", "~", "~user/x", "$HOME/x", "C:\\Windows", "\\\\host\\share", "/a/../b", "~/../x", "/a\\b",
            "https://", "https:///x", "https://user@example.org/", "https://user:pw@example.org/", "https://example.org@evil.org/", "https://exa mple.org/", "https://{clipboard}.org/", "https://example.org/{", "https://example.org/}",
            "https://example.org/{Clipboard}", "https://example.org/{x" , "https://ex\u00e4mple.org/", "https://example.org\\@evil.org/", "https://-bad.org/", "https://a..b/", "https://example.org:99999999/",
            "https://example.org/\n", "~/a ", "/a\tb", "https://example.org/\u0001", "https://example.org/ x", "mailto:", "mailto:a b", "mailto:{", "/a{argument}", "~/{clipboard}", "{clipboard}", "{argument}://x",
            "https://example.org/" + rlo, nul, " https://example.org/"
        ];
        for (const t of refusedList)
            verify(!target(t).ok, "must be refused: " + JSON.stringify(t));
        for (const t of refusedList)
            verify(!CommandsFile.validate(file("links", [link(t)])).ok, "link must be refused: " + JSON.stringify(t));
        verify(!target(5).ok);
        verify(!target(null).ok);
        verify(!target(undefined).ok);
        verify(!target(["https://example.org/"]).ok);
    }

    function test_mailtoQuery() {
        const ok = ["mailto:a@b.org", "mailto:a@b.org?subject=Hi", "mailto:a@b.org?to=c@d.org&cc=e@f.org&bcc=g@h.org&subject=S&body=B", "mailto:a@b.org?SUBJECT=Hi&Body=x",
                    "mailto:a@b.org?%73ubject=Hi", "mailto:a@b.org?to=x@y.org&to=z@y.org", "mailto:a@b.org,c@d.org?subject={argument}"];
        for (const t of ok)
            verify(target(t).ok, t);
        const bad = ["mailto:a@b.org?attach=/home/u/.ssh/id_rsa", "mailto:a@b.org?attachment=/home/u/.ssh/id_rsa", "mailto:a@b.org?Attach=/x", "mailto:a@b.org?%61ttach=/x",
                     "mailto:a@b.org?%41TTACH=/x", "mailto:a@b.org?attach%3D/x", "mailto:a@b.org?subject=S&attach=/x", "mailto:a@b.org?subject=S&&attach=/x",
                     "mailto:a@b.org?subject=S&Attachment=/x", "mailto:a@b.org?in-reply-to=x", "mailto:a@b.org?x-custom=1", "mailto:a@b.org?attach", "mailto:a@b.org?=x",
                     "mailto:a@b.org?subject=A&subject=B", "mailto:a@b.org?body=A&body=B", "mailto:a@b.org%3Fattach=/x", "mailto:a@b.org%3fattach=/x", "mailto:a@b.org%26attach=/x",
                     "mailto:a@b.org?subject=S;attach=/x", "mailto:a@b.org#?attach=/x", "mailto:a@b.org?{argument}=/x", "mailto:a@b.org?%00=x",
                     "mailto:a@b.org?attach=/x&to=c@d.org", "mailto:?attach=/x"];
        for (const t of bad)
            verify(!target(t).ok, "must be refused: " + t);
    }

    function test_uncPaths() {
        for (const t of ["//host/share", "file:////host/share", "file://localhost//host/share", "file:///%2F%2Fhost/share", "//", "///a"])
            verify(!target(t).ok, "must be refused: " + t);
        verify(target("/host/share").ok);
        verify(target("file:///host/share").ok);
    }

    function test_chordModifierOrder() {
        const pair = (a, b) => file("shortcuts", [{slot: "k1", chord: a, command: "a.b"}, {slot: "k2", chord: b, command: "c.d"}]);
        bad(pair("Super+Shift+K", "Shift+Super+K"), "shortcuts[1].chord", "duplicate");
        bad(pair("Ctrl+Alt+Shift+Super+x", "Super+Shift+Alt+Ctrl+X"), "shortcuts[1].chord", "duplicate");
        verify(CommandsFile.validate(pair("Super+K", "Super+Shift+K")).ok);
    }

    function test_invisibleCharacters() {
        const names = ["a\u200bb", "a\u2060b", "a" + String.fromCodePoint(0xe0041) + "b", "a\ufff9b", "a\u3164b", "a\u2800b", "a\u00adb", "\u200b", "\u3000", "\u00a0\u00a0"];
        for (const n of names) {
            bad(file("links", [{id: "link.a", name: n, target: "https://x.org/"}]), "links[0].name", "name");
            bad(file("aiCommands", [{id: "ai.a", name: n, prompt: "p"}]), "aiCommands[0].name", "name");
            bad(file("links", [link("https://x.org/", {args: [{placeholder: n}]})]), "links[0].args[0]", "arg");
        }
        bad(file("replacements", [{id: "text.a", replace: "a\u200bb", with: "x"}]), "replacements[0].replace", "replace");
        // mailto addresses with hidden characters
        verify(!target("mailto:a%E2%80%8Bb@x.org").ok);
    }

    function test_openWithAlone() {
        verify(CommandsFile.validate(file("links", [{id: "link.a", name: "n", target: "", openWith: "a.desktop"}])).ok);
        bad(file("links", [{id: "link.a", name: "n", target: ""}]), "links[0].target", "length");
        bad(file("links", [{id: "link.a", name: "n"}]), "links[0].target", "length");
        bad(file("links", [{id: "link.a", name: "n", target: "javascript:x", openWith: "a.desktop"}]), "links[0].target", "not-allowed");
    }

    function test_hostileTexts() {
        for (const s of ["a\u0001b", "a\nb", "a" + rlo + "b", "a\u2028b", "a\u0085b", " a", "a "])
            bad(file("links", [{id: "link.a", name: s, target: "https://x.org/"}]), "links[0].name", "name");
        for (const s of ["a" + rlo + "b", "a\u0001b", "a" + nul + "b", "a\u007fb"])
            bad(file("replacements", [{id: "text.a", replace: "r", with: s}]), "replacements[0].with", "with");
        for (const s of ["a" + rlo + "b", "a\u0001b"])
            bad(file("aiCommands", [{id: "ai.a", name: "n", prompt: s}]), "aiCommands[0].prompt", "prompt");
        bad(file("replacements", [{id: "text.a", replace: "a\tb", with: "x"}]), "replacements[0].replace", "replace");
        bad(file("replacements", [{id: "text.a", replace: "x".repeat(33), with: "x"}]), "replacements[0].replace", "replace");
        // a multi-line replacement and a tab are kept
        verify(CommandsFile.validate(file("replacements", [{id: "text.a", replace: "r", with: "a\n\tb"}])).ok);
    }

    function test_normalizedCopy() {
        // the result holds new objects with the known fields only
        const input = file("links", [link("https://x.org/")]);
        const r = CommandsFile.validate(input);
        verify(r.ok);
        verify(r.data !== input);
        verify(r.data.links[0] !== input.links[0]);
        compare(Object.keys(r.data.links[0]).join(","), "id,name,target,args");
    }

    function test_validateItem() {
        verify(CommandsFile.validateItem("links", link("https://x.org/")).ok);
        verify(!CommandsFile.validateItem("links", link("javascript:x")).ok);
        verify(CommandsFile.validateItem("favorites", "sys.lock").ok);
        verify(!CommandsFile.validateItem("favorites", "Sys").ok);
        verify(!CommandsFile.validateItem("nope", {}).ok);
        verify(!CommandsFile.validateItem("constructor", {}).ok);
        verify(!CommandsFile.validateItem("toString", {}).ok);
        verify(!CommandsFile.validateItem("links", null).ok);
    }

    // ---- E1b: the request layer (CommandStore, the `search` IPC item functions) ----

    function req(list, item) {
        return JSON.stringify({list: list, item: item});
    }

    function test_parseRequest() {
        const ok = CommandsFile.parseRequest(req("links", link("mailto:a@example.org?subject=x")));
        verify(ok.ok);
        compare(ok.list, "links");
        compare(ok.item.id, "link.a1");
        // The same rules as the file reader, for the same item.
        for (const t of ["javascript:x", "smb://h/s", "mailto:a@b.org?attach=/etc/passwd", "//h/s", "https://u:p@example.org/", "relative"]) {
            verify(!CommandsFile.parseRequest(req("links", link(t))).ok, t);
            verify(!CommandsFile.parseText(JSON.stringify(file("links", [link(t)]))).ok, t);
        }
        // Only the lists the Settings app may change.
        for (const l of ["shortcuts", "quickKeys", "favorites", "constructor", "__proto__", ""])
            compare(CommandsFile.parseRequest(req(l, {})).reason, "list", l);
        compare(CommandsFile.parseRequest("{nope").reason, "json");
        compare(CommandsFile.parseRequest("[]").reason, "shape");
        compare(CommandsFile.parseRequest(5).reason, "text");
        compare(CommandsFile.parseRequest("{\"list\":\"links\",\"item\":{},\"x\":1}").reason, "shape");
        compare(CommandsFile.parseRequest("{\"list\":\"links\",\"list\":\"links\",\"item\":{}}").reason, "unsafe-json");
        compare(CommandsFile.parseRequest("{\"list\":\"links\",\"item\":{},\"n\":9007199254740993}").reason, "unsafe-json");
        // A caller may widen the lists (Search's own actions).
        verify(CommandsFile.parseRequest(req("shortcuts", {slot: "k1", chord: "Super+K", command: "sys.lock"}), ["shortcuts"]).ok);
    }

    function test_requestBound() {
        const base = req("replacements", {id: "text.a", replace: "a", with: "\u00e9"});
        const bytes = CommandsFile.utf8Length(base);
        verify(CommandsFile.parseRequest(base + " ".repeat(65536 - bytes)).ok, "65 536 bytes");
        compare(CommandsFile.parseRequest(base + " ".repeat(65537 - bytes)).reason, "too-big");
        // Counted in bytes, not characters: 32 769 two-byte characters are over the bound.
        compare(CommandsFile.parseRequest(base + "\u00e9".repeat(32769)).reason, "too-big");
    }

    function test_withItem() {
        const d = CommandsFile.empty();
        const a = CommandsFile.withItem(d, "links", link("https://x.org/"), "add");
        verify(a.ok);
        compare(d.links.length, 0, "the data given is not changed");
        compare(a.data.links.length, 1);
        compare(CommandsFile.withItem(a.data, "links", link("https://x.org/"), "add").reason, "exists");
        const u = CommandsFile.withItem(a.data, "links", Object.assign(link("https://y.org/"), {name: "New"}), "update");
        compare(u.data.links[0].name, "New");
        compare(CommandsFile.withItem(d, "links", link("https://x.org/"), "update").reason, "not-found");
        compare(CommandsFile.keyOf("shortcuts", {slot: "k2"}), "k2");
        compare(CommandsFile.keyOf("quickKeys", {key: "gh"}), "gh");
        compare(CommandsFile.keyOf("favorites", "sys.lock"), "sys.lock");
    }

    function test_withoutItem() {
        const d = CommandsFile.validate({v: 1, links: [link("https://x.org/")], replacements: [{id: "text.b", replace: "b", with: "c"}], aiCommands: [{id: "ai.c", name: "n", prompt: "p"}]}).data;
        compare(CommandsFile.withoutItem(d, "link.a1").data.links.length, 0);
        compare(CommandsFile.withoutItem(d, "text.b").data.replacements.length, 0);
        compare(CommandsFile.withoutItem(d, "ai.c").data.aiCommands.length, 0);
        compare(CommandsFile.withoutItem(d, "link.zz").reason, "not-found");
        compare(CommandsFile.withoutItem(d, "sys.lock").reason, "id");
        compare(CommandsFile.withoutItem(d, "link." + "a".repeat(200)).reason, "id");
        compare(CommandsFile.withoutItem(d, 5).reason, "id");
        compare(d.links.length, 1, "the data given is not changed");
    }

    function test_mergeImport() {
        const d = CommandsFile.validate({v: 1, links: [link("https://x.org/")]}).data;
        const incoming = CommandsFile.validate({v: 1, links: [link("https://other.org/"), {id: "link.b2", name: "B", target: "https://b.org/"}],
            replacements: [{id: "text.r", replace: "r", with: "x"}], quickKeys: [{key: "gh", command: "sys.lock"}],
            shortcuts: [{slot: "k1", chord: "Super+K", command: "sys.lock"}], favorites: ["sys.lock"]}).data;
        const m = CommandsFile.mergeImport(d, incoming);
        compare(m.added, 2);
        compare(m.skipped, 1);
        compare(m.ignored, 3);
        compare(m.data.links[0].target, "https://x.org/", "what is there wins");
        compare(m.data.shortcuts.length, 0);
        compare(m.data.quickKeys.length, 0);
        compare(m.data.favorites.length, 0);
        verify(CommandsFile.validate(m.data).ok);
    }

    function test_serializeRoundTrip() {
        const d = CommandsFile.validate({v: 1, links: [link("https://x.org/?q={argument}", {args: [{placeholder: "Query"}]})],
            replacements: [{id: "text.b", replace: "b", with: "caf\u00e9\n\ttext"}]}).data;
        const s = CommandsFile.serialize(d);
        compare(s.bytes, CommandsFile.utf8Length(s.text));
        verify(s.text.endsWith("}\n"));
        const back = CommandsFile.parseText(s.text);
        verify(back.ok);
        compare(JSON.stringify(back.data), JSON.stringify(d));
    }

    function test_loneSurrogate() {
        const hi = String.fromCharCode(0xd800);
        const lo = String.fromCharCode(0xdc00);
        const pair = hi + lo;
        verify(CommandsFile.validate(file("replacements", [{id: "text.a", replace: "a", with: "x" + pair + "y"}])).ok, "a pair is fine");
        for (const bad of [hi, lo, "a" + hi + "b", lo + hi, hi + hi + lo + lo]) {
            if (bad === hi + hi + lo + lo)
                continue;
            compare(CommandsFile.validate(file("replacements", [{id: "text.a", replace: "a", with: "x" + bad}])).reason, "surrogate", JSON.stringify(bad));
        }
        compare(CommandsFile.validate(file("aiCommands", [{id: "ai.a", name: "n", prompt: "p" + hi}])).reason, "surrogate");
        compare(CommandsFile.parseText("{\"v\":1,\"replacements\":[{\"id\":\"text.a\",\"replace\":\"a\",\"with\":\"a\\ud800b\"}]}").reason, "surrogate");
        compare(CommandsFile.parseRequest("{\"list\":\"links\",\"item\":{},\"\\udc00\":1}").reason, "surrogate");
        compare(CommandsFile.parseRequest(JSON.stringify({list: "replacements", item: {id: "text.a", replace: "a", with: "a" + hi + "b"}})).reason, "surrogate");
        verify(CommandsFile.parseRequest(JSON.stringify({list: "replacements", item: {id: "text.a", replace: "a", with: "a" + pair + "b"}})).ok);
        // An over-long text is refused before it is scanned.
        compare(CommandsFile.parseRequest("x".repeat(65537)).reason, "too-big");
    }
}
