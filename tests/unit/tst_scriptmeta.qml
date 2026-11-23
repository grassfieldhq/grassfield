import QtQuick
import QtTest
import "../../shell/search/ScriptMeta.js" as ScriptMeta

TestCase {
    name: "ScriptMeta"

    // The README example of the script commands format, verbatim (command-palette.md [R16]).
    readonly property string readme: "#!/bin/bash\n\n"
        + "# Required parameters:\n"
        + "# @raycast.schemaVersion 1\n"
        + "# @raycast.title Dismiss Notifications\n"
        + "# @raycast.mode silent\n\n"
        + "# Optional parameters:\n"
        + "# @raycast.icon 🔕\n"
        + "# @raycast.packageName Mac Utils\n"
        + "# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"Placeholder\" }\n"
        + "# @raycast.argument2 { \"type\": \"text\", \"placeholder\": \"Placeholder\", \"optional\": true }\n\n"
        + "# Documentation:\n"
        + "# @raycast.description Dismiss notifications\n"
        + "# @raycast.author Jane Doe\n"
        + "# @raycast.authorURL https://example.com/jane\n\n"
        + "echo done\n"

    function head(extra) {
        return "#!/bin/bash\n# @raycast.schemaVersion 1\n# @raycast.title T\n# @raycast.mode silent\n" + (extra || "");
    }

    function refused(text, key, reason) {
        const r = ScriptMeta.parse(text);
        verify(!r.ok, "must be refused: " + String(text).slice(0, 80));
        if (key !== undefined)
            compare(r.key, key);
        if (reason !== undefined)
            compare(r.reason, reason);
    }

    function arg(n) {
        return "# @raycast.argument" + n + " { \"type\": \"text\", \"placeholder\": \"P\" }\n";
    }

    function test_readmeExample() {
        const r = ScriptMeta.parse(readme);
        verify(r.ok);
        verify(!r.hidden);
        compare(r.meta.title, "Dismiss Notifications");
        compare(r.meta.mode, "silent");
        compare(r.meta.icon.kind, "emoji");
        compare(r.meta.icon.value, "🔕");
        compare(r.meta.packageName, "Mac Utils");
        compare(r.meta.description, "Dismiss notifications");
        compare(r.meta.author, "Jane Doe");
        compare(r.meta.authorURL, "https://example.com/jane");
        compare(r.meta.arguments.length, 2);
        compare(r.meta.arguments[0].type, "text");
        compare(r.meta.arguments[0].optional, false);
        compare(r.meta.arguments[1].optional, true);
    }

    function test_argumentsExamples() {
        const r = ScriptMeta.parse(head(
            "# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"Placeholder\", \"optional\": true, \"percentEncoded\": true }\n"
            + "// @raycast.argument2 { \"type\": \"password\", \"placeholder\": \"Secret\" }\n"
            + "# @raycast.argument3 { \"type\": \"dropdown\", \"placeholder\": \"Pick\", \"data\": [{ \"title\": \"Item 1\", \"value\": \"item1\" }, { \"title\": \"Item 2\", \"value\": \"item2\" }] }\n"));
        verify(r.ok);
        compare(r.meta.arguments.length, 3);
        compare(r.meta.arguments[0].percentEncoded, true);
        compare(r.meta.arguments[1].type, "password");
        compare(r.meta.arguments[2].type, "dropdown");
        compare(r.meta.arguments[2].data.length, 2);
        compare(r.meta.arguments[2].data[1].value, "item2");
    }

    function test_secureTextIsPassword() {
        const r = ScriptMeta.parse(head("# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"P\", \"secure\": true }\n"));
        verify(r.ok);
        compare(r.meta.arguments[0].type, "password");
        refused(head("# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"P\", \"secure\": true, \"percentEncoded\": true }\n"), "argument1", "percentEncoded");
        refused(head("# @raycast.argument1 { \"type\": \"dropdown\", \"placeholder\": \"P\", \"secure\": true, \"data\": [{\"title\": \"a\", \"value\": \"a\"}] }\n"), "argument1", "secure");
    }

    function test_slashPrefixAndAlias() {
        const r = ScriptMeta.parse("// @grassfield.schemaVersion 1\n// @grassfield.title Hi\n//@raycast.mode compact\n  # @raycast.packageName Pkg\n");
        verify(r.ok);
        compare(r.meta.title, "Hi");
        compare(r.meta.mode, "compact");
        compare(r.meta.packageName, "Pkg");
        refused("# @raycast.schemaVersion 1\n# @grassfield.title A\n# @raycast.title B\n# @raycast.mode silent\n", "title", "duplicate");
    }

    function test_required() {
        refused("# @raycast.title T\n# @raycast.mode silent\n", "schemaVersion", "missing");
        refused("# @raycast.schemaVersion 2\n# @raycast.title T\n# @raycast.mode silent\n", "schemaVersion", "unsupported");
        refused("# @raycast.schemaVersion 1\n# @raycast.mode silent\n", "title", "missing");
        refused("# @raycast.schemaVersion 1\n# @raycast.title\n# @raycast.mode silent\n", "title", "invalid");
        refused("# @raycast.schemaVersion 1\n# @raycast.title T\n", "mode", "missing");
        refused("# @raycast.schemaVersion 1\n# @raycast.title T\n# @raycast.mode loud\n", "mode", "invalid");
        refused(7, "", "text");
        refused("", "schemaVersion", "missing");
    }

    function test_modes() {
        for (const m of ["fullOutput", "compact", "silent", "inline"]) {
            const r = ScriptMeta.parse("# @raycast.schemaVersion 1\n# @raycast.title T\n# @raycast.mode " + m + "\r\n");
            verify(r.ok);
            compare(r.meta.mode, m);
        }
    }

    function test_unknownKeysIgnored() {
        const r = ScriptMeta.parse(head("# @raycast.futureThing whatever\n# @raycast.__proto__ x\n# @raycast.constructor y\n# @other.title Z\n"));
        verify(r.ok);
        compare(r.meta.title, "T");
        compare(Object.keys(r.meta).indexOf("futureThing"), -1);
    }

    function test_platform() {
        verify(ScriptMeta.parse(head("# @raycast.platform windows\n")).hidden);
        verify(!ScriptMeta.parse(head("# @raycast.platform macos,windows\n")).hidden);
        verify(!ScriptMeta.parse(head("# @raycast.platform linux\n")).hidden);
        verify(!ScriptMeta.parse(head()).hidden);
        refused(head("# @raycast.platform win;dows rm\n"), "platform", "invalid");
    }

    function test_needsConfirmationAndRefresh() {
        verify(ScriptMeta.parse(head("# @raycast.needsConfirmation true\n")).meta.needsConfirmation);
        verify(!ScriptMeta.parse(head("# @raycast.needsConfirmation false\n")).meta.needsConfirmation);
        refused(head("# @raycast.needsConfirmation yes\n"), "needsConfirmation", "invalid");
        refused(head("# @raycast.needsConfirmation True\n"), "needsConfirmation", "invalid");
        const inl = "# @raycast.schemaVersion 1\n# @raycast.title T\n# @raycast.mode inline\n";
        compare(ScriptMeta.parse(inl + "# @raycast.refreshTime 1m\n").meta.refreshSeconds, 60);
        compare(ScriptMeta.parse(inl + "# @raycast.refreshTime 10s\n").meta.refreshSeconds, 10);
        compare(ScriptMeta.parse(inl + "# @raycast.refreshTime 2h\n").meta.refreshSeconds, 7200);
        refused(inl + "# @raycast.refreshTime 9s\n", "refreshTime", "invalid");
        refused(inl + "# @raycast.refreshTime 100d\n", "refreshTime", "invalid");
        refused(inl + "# @raycast.refreshTime soon\n", "refreshTime", "invalid");
        refused(inl + "# @raycast.refreshTime 0s\n", "refreshTime", "invalid");
        // not inline: validated, never scheduled
        compare(ScriptMeta.parse(head("# @raycast.refreshTime 1m\n")).meta.refreshSeconds, 0);
    }

    function test_currentDirectory() {
        compare(ScriptMeta.parse(head("# @raycast.currentDirectoryPath ~/Documents\n")).meta.currentDirectoryPath, "~/Documents");
        compare(ScriptMeta.parse(head("# @raycast.currentDirectoryPath /tmp/x\n")).meta.currentDirectoryPath, "/tmp/x");
        compare(ScriptMeta.parse(head("# @raycast.currentDirectoryPath ~\n")).meta.currentDirectoryPath, "~");
        for (const bad of ["relative/dir", "/a/../b", "~/..", "~user/x", "$HOME", "/a\u0001b", "/a\u202eb", ""])
            refused(head("# @raycast.currentDirectoryPath " + bad + "\n"), "currentDirectoryPath", "invalid");
        refused(head("# @raycast.currentDirectoryPath /" + "a".repeat(600) + "\n"), "currentDirectoryPath", "invalid");
    }

    function icon(v) {
        return ScriptMeta.parse(head("# @raycast.icon " + v + "\n")).meta.icon;
    }

    function test_iconKinds() {
        compare(icon("🚀").kind, "emoji");
        compare(icon("👨‍👩‍👧").kind, "emoji");
        compare(icon("images/ok.png").kind, "file");
        compare(icon("a b.svg").kind, "file");
        compare(ScriptMeta.parse(head("# @raycast.iconDark icons/dark.png\n")).meta.iconDark.value, "icons/dark.png");
        compare(ScriptMeta.parse(head()).meta.icon.kind, "none");
        compare(ScriptMeta.parse(head("# @raycast.icon\n")).meta.icon.kind, "none");
    }

    function test_iconHostile() {
        // the script stays listed with the generic glyph and the reason; no path survives
        const hostile = ["https://example.com/a.png", "http://x/a.png", "file:///etc/passwd", "data:image/png;base64,AAAA", "/etc/passwd", "~/a.png",
            "../a.png", "a/../../b.png", "a/./b.png", "a//b.png", "a\\b.png", ".hidden.png", "a/.b.png", "a.txt", "no-extension", "-rf.png",
            "$(id).png", "`id`.png", "a;b.png", "a\u0001.png", "a\u202e.png", "x".repeat(200) + ".png", "emoji🚀text", "abc"];
        for (const h of hostile) {
            const r = ScriptMeta.parse(head("# @raycast.icon " + h + "\n"));
            verify(r.ok, h);
            compare(r.meta.icon.kind, "none", h);
            compare(r.meta.icon.value, "", h);
            verify(r.meta.icon.rejected !== "", h);
        }
    }

    function test_hostileTexts() {
        const bad = ["a\u0001b", "a\u007fb", "a\u0085b", "a\u202eb", "a\u2066b", "a\u200eb", "a\ufeffb"];
        for (const b of bad) {
            refused(head("# @raycast.description " + b + "\n"), "description", "invalid");
            refused("# @raycast.schemaVersion 1\n# @raycast.title " + b + "\n# @raycast.mode silent\n", "title", "invalid");
            refused(head("# @raycast.author " + b + "\n"), "author", "invalid");
            refused(head("# @raycast.packageName " + b + "\n"), "packageName", "invalid");
        }
        // a line separator ends the match: the line is not read, so a required field on it is missing
        refused("# @raycast.schemaVersion 1\n# @raycast.title A\u2028B\n# @raycast.mode silent\n", "title", "missing");
        refused(head("# @raycast.authorURL javascript:alert(1)\n"), "authorURL", "invalid");
        refused(head("# @raycast.authorURL https://a b\n"), "authorURL", "invalid");
        refused(head("# @raycast.authorURL https://" + "a".repeat(300) + "\n"), "authorURL", "invalid");
        refused("# @raycast.schemaVersion 1\n# @raycast.title " + "t".repeat(81) + "\n# @raycast.mode silent\n", "title", "invalid");
        verify(ScriptMeta.parse("# @raycast.schemaVersion 1\n# @raycast.title " + "t".repeat(80) + "\n# @raycast.mode silent\n").ok);
        refused(head("# @raycast.description " + "d".repeat(257) + "\n"), "description", "invalid");
        // a carriage return in the middle of a line is no line end and the dot of the pattern skips it: the line is ignored
        refused("# @raycast.schemaVersion 1\r# @raycast.title T\n# @raycast.mode silent\n", "schemaVersion", "missing");
    }

    function test_hugeValues() {
        refused(head("# @raycast.description " + "x".repeat(5000) + "\n"), "description", "line-length");
        refused(head("# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"" + "p".repeat(5000) + "\" }\n"), "argument1", "line-length");
        // a huge line that is no key is skipped (and counts against the 8 KiB)
        const r = ScriptMeta.parse(head("# " + "y".repeat(100000) + "\n# @raycast.description x\n"));
        verify(r.ok);
        compare(r.meta.description, "");
    }

    function test_limits64LinesAnd8KiB() {
        // the required keys on lines 64 and 65: the title is not read
        let t = "";
        for (let i = 0; i < 62; i++)
            t += "# filler\n";
        t += "# @raycast.schemaVersion 1\n# @raycast.title T\n# @raycast.mode silent\n";
        refused(t, "mode", "missing");
        let u = "# @raycast.schemaVersion 1\n# @raycast.title T\n# @raycast.mode silent\n";
        for (let i = 0; i < 60; i++)
            u += "# filler\n";
        u += "# @raycast.description late\n";
        compare(ScriptMeta.parse(u).meta.description, "late");   // line 64
        u += "# @raycast.author late\n";
        compare(ScriptMeta.parse(u).meta.author, "");            // line 65
        // a 9 KiB header: the required keys within the first 8 KiB are read, a key beyond is not
        const pad = "# " + "z".repeat(1000) + "\n";
        let v = head();
        for (let i = 0; i < 9; i++)
            v += pad;
        v += "# @raycast.description beyond\n";
        const rv = ScriptMeta.parse(v);
        verify(rv.ok);
        compare(rv.meta.description, "");
        // the byte budget counts UTF-8 (2 and 3 byte characters), not UTF-16 units
        let w = head();
        for (let i = 0; i < 4; i++)
            w += "# " + "é".repeat(1000) + "\n";
        w += "# " + "€".repeat(500) + "\n";
        w += "# @raycast.description beyond\n";
        compare(ScriptMeta.parse(w).meta.description, "");
    }

    function test_argumentsMalformed() {
        const base = "# @raycast.argument1 ";
        const bad = [
            ["{not json}", "json"],
            ["[1,2]", "shape"],
            ["null", "shape"],
            ["\"text\"", "shape"],
            ["", "length"],
            ["{ \"type\": \"number\", \"placeholder\": \"P\" }", "type"],
            ["{ \"type\": 1, \"placeholder\": \"P\" }", "type"],
            ["{ \"placeholder\": \"P\" }", "type"],
            ["{ \"type\": \"text\" }", "placeholder"],
            ["{ \"type\": \"text\", \"placeholder\": 5 }", "placeholder"],
            ["{ \"type\": \"text\", \"placeholder\": \"a" + String.fromCharCode(92) + "u0001b\" }", "placeholder"],
            ["{ \"type\": \"text\", \"placeholder\": \"" + "p".repeat(65) + "\" }", "placeholder"],
            ["{ \"type\": \"text\", \"placeholder\": \"P\", \"optional\": \"true\" }", "optional"],
            ["{ \"type\": \"text\", \"placeholder\": \"P\", \"percentEncoded\": 1 }", "percentEncoded"],
            ["{ \"type\": \"text\", \"placeholder\": \"P\", \"cmd\": \"rm -rf /\" }", "unknown-field"],
            ["{ \"type\": \"text\", \"placeholder\": \"P\", \"__proto__\": {} }", "unknown-field"],
            ["{ \"type\": \"text\", \"placeholder\": \"P\", \"data\": [] }", "data"],
            ["{ \"type\": \"dropdown\", \"placeholder\": \"P\" }", "data"],
            ["{ \"type\": \"dropdown\", \"placeholder\": \"P\", \"data\": [] }", "data"],
            ["{ \"type\": \"dropdown\", \"placeholder\": \"P\", \"data\": \"x\" }", "data"],
            ["{ \"type\": \"dropdown\", \"placeholder\": \"P\", \"data\": [\"a\"] }", "data"],
            ["{ \"type\": \"dropdown\", \"placeholder\": \"P\", \"data\": [{\"title\": \"a\"}] }", "data"],
            ["{ \"type\": \"dropdown\", \"placeholder\": \"P\", \"data\": [{\"title\": \"a\", \"value\": \"b\", \"cmd\": \"c\"}] }", "data"],
            ["{ \"type\": \"dropdown\", \"placeholder\": \"P\", \"data\": [{\"title\": \"a\", \"value\": \"b\\nc\"}] }", "data"],
            ["{ \"type\": \"dropdown\", \"placeholder\": \"P\", \"data\": [{\"title\": \"a\", \"value\": 1}] }", "data"],
            ["{ \"type\": \"dropdown\", \"placeholder\": \"P\", \"data\": [{\"title\": \"a\", \"value\": \"b\"}, {\"title\": \"c\", \"value\": \"b\"}] }", "data"]
        ];
        for (const [value, reason] of bad)
            refused(head(base + value + "\n"), "argument1", reason);
        const items = [];
        for (let i = 0; i < 33; i++)
            items.push("{\"title\": \"t" + i + "\", \"value\": \"v" + i + "\"}");
        refused(head(base + "{ \"type\": \"dropdown\", \"placeholder\": \"P\", \"data\": [" + items.join(",") + "] }\n"), "argument1", "data");
        items.pop();
        verify(ScriptMeta.parse(head(base + "{ \"type\": \"dropdown\", \"placeholder\": \"P\", \"data\": [" + items.join(",") + "] }\n")).ok);
    }

    function test_fourArgumentsRefused() {
        verify(ScriptMeta.parse(head(arg(1) + arg(2) + arg(3))).ok);
        refused(head(arg(1) + arg(2) + arg(3) + arg(4)), "argument4", "too-many");
        refused(head(arg(1) + arg(2) + arg(3) + arg(0)), "argument0", "too-many");
        refused(head(arg(1) + arg("01")), "argument01", "too-many");
        refused(head(arg(1) + arg(99999)), "argument99999", "too-many");
        refused(head(arg(2)), "argument2", "gap");
        refused(head(arg(1) + arg(3)), "argument3", "gap");
    }

    function test_templateName() {
        verify(ScriptMeta.isTemplateName("hello.template.sh"));
        verify(!ScriptMeta.isTemplateName("hello.sh"));
        verify(!ScriptMeta.isTemplateName(5));
    }

    function test_noInjectionIntoResult() {
        // nothing of an unknown key or of a hostile value is carried into the result
        const r = ScriptMeta.parse(head("# @raycast.unknown $(id)\n# @raycast.icon $(id).png\n"));
        verify(r.ok);
        compare(JSON.stringify(r).indexOf("$(id)"), -1);
    }
}
