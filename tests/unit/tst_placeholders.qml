import QtQuick
import QtTest
import "../../shell/search/Placeholders.js" as Placeholders

// Palette slice T1 (spec command-palette.md T1): the placeholder expander and the provenance of every substituted piece.
// The examples marked [R6] are copied from https://manual.raycast.com/dynamic-placeholders (read 2026-11-23).
TestCase {
    name: "Placeholders"

    readonly property var fr: Qt.locale("fr_FR")
    // [R6]'s date: Wednesday 15 June 2022, 13:44:39.945 local time.
    readonly property var r6now: new Date(2022, 5, 15, 13, 44, 39, 945)
    // Wednesday 1 June 2022, 15:05 and 18:45.
    readonly property var junAfternoon: new Date(2022, 5, 1, 15, 5, 9)
    readonly property var junEvening: new Date(2022, 5, 1, 18, 45, 0)
    // Monday 23 November 2026, 14:05:09.
    readonly property var now: new Date(2026, 10, 23, 14, 5, 9)

    function ex(template, extra) {
        const ctx = {now: now, clipboard: "copied text", arguments: {"#1": "typed"}, uuid: () => "00000000-0000-4000-8000-000000000000"};
        if (extra) {
            for (const k of Object.keys(extra))
                ctx[k] = extra[k];
        }
        return Placeholders.expand(template, ctx);
    }

    function text(template, extra) {
        const r = ex(template, extra);
        verify(r.ok, template + " -> " + r.error);
        return r.text;
    }

    function at(template, when, extra) {
        const e = {now: when};
        if (extra) {
            for (const k of Object.keys(extra))
                e[k] = extra[k];
        }
        return text(template, e);
    }

    function zoneOf(d) {
        const off = -d.getTimezoneOffset();
        const a = Math.abs(off);
        return (off < 0 ? "-" : "+") + ("0" + Math.floor(a / 60)).slice(-2) + ("0" + a % 60).slice(-2);
    }

    function test_plainTextIsUntouched() {
        compare(text("hello world"), "hello world");
        compare(text(""), "");
        compare(text("{}"), "{}");
        compare(text("a { b } c"), "a { b } c");
        compare(text("{{clipboard}"), "{copied text");
        compare(ex("hello").carriesData, false);
    }

    // ---- [R6] modifiers

    function test_r6Modifiers() {
        compare(text("{clipboard | uppercase}", {clipboard: "Foo"}), "FOO");
        compare(text("{clipboard | lowercase}", {clipboard: "Foo"}), "foo");
        compare(text("{clipboard | trim}", {clipboard: " Foo Bar "}), "Foo Bar");
        compare(text("{clipboard | percent-encode}", {clipboard: "Foo Bar"}), "Foo%20Bar");
        compare(text("{clipboard | json-stringify}", {clipboard: "Foo \"Bar\""}), "\"Foo \\\"Bar\\\"\"");
        compare(text("{clipboard | trim | uppercase}", {clipboard: "  foo "}), "FOO");
        compare(text("{clipboard|uppercase}"), "COPIED TEXT");
        compare(text("{clipboard | raw}"), "copied text");
        compare(text("{clipboard | json-stringify}", {clipboard: "a\nb\\"}), "\"a\\nb\\\\\"");
        compare(text("{clipboard | trim | nonsense}"), "{clipboard | trim | nonsense}", "an unknown modifier leaves the group as written");
        compare(text("{clipboard}", {clipboard: undefined}), "");
        compare(text("{uuid | lowercase}", {uuid: () => "ABC-DEF"}), "abc-def", "modifiers work on every placeholder");
    }

    // ---- [R6] date, time, weekday: defaults

    function test_r6Defaults() {
        compare(at("{date}", junAfternoon), "1 Jun 2022");
        compare(at("{time}", junAfternoon), "3:05 pm");
        compare(at("{datetime}", junEvening), "1 Jun 2022 at 6:45 pm");
        compare(at("{day}", new Date(2022, 5, 6)), "Monday");
        compare(at("{date}", junAfternoon, {locale: fr}), "1 juin 2022");
        compare(at("{time}", junAfternoon, {locale: fr}), "15:05");
        compare(at("{datetime}", junEvening, {locale: fr}), "1 juin 2022 à 18:45");
        compare(at("{day}", new Date(2022, 5, 6), {locale: fr}), "lundi");
    }

    // ---- [R6] custom date formats: the table, verbatim

    function test_r6CustomFormats() {
        compare(at("{date format=\"EEEE, MMM d, yyyy\"}", r6now), "Wednesday, Jun 15, 2022");
        compare(at("{date format=\"MM/dd/yyyy\"}", r6now), "06/15/2022");
        compare(at("{date format=\"MM-dd-yyyy HH:mm\"}", r6now), "06-15-2022 13:44");
        compare(at("{date format=\"MMM d, h:mm a\"}", r6now), "Jun 15, 1:44 PM");
        compare(at("{date format=\"MMMM yyyy\"}", r6now), "June 2022");
        compare(at("{date format=\"MMM d, yyyy\"}", r6now), "Jun 15, 2022");
        compare(at("{date format=\"E, d MMM yyyy HH:mm:ss Z\"}", r6now), "Wed, 15 Jun 2022 13:44:39 " + zoneOf(r6now));
        compare(at("{date format=\"yyyy-MM-dd'T'HH:mm:ssZ\"}", r6now), "2022-06-15T13:44:39" + zoneOf(r6now));
        compare(at("{date format=\"dd.MM.yy\"}", r6now), "15.06.22");
        compare(at("{date format=\"HH:mm:ss.SSS\"}", r6now), "13:44:39.945");
        compare(at("{date format=\"h:mm 'on the eve of' MMMM d\"}", new Date(2022, 5, 5, 8, 30)), "8:30 on the eve of June 5");
        compare(at("{date format=\"yyyy-MM-dd\" offset=\"+3M -5d\"}", r6now), "2022-09-10");
    }

    function test_moreFormatLetters() {
        compare(at("{time format=\"HH:mm:ss.S\"}", r6now), "13:44:39.9");
        compare(at("{time format=\"ss.SS\"}", r6now), "39.94");
        compare(at("{time format=\"SSSSSS\"}", r6now), "945000");
        compare(at("{time format=\"hh:mm a\"}", r6now), "01:44 PM");
        compare(at("{date format=\"EEE\"}", r6now), "Wed");
        compare(at("{date format=\"yyyy''MM\"}", r6now), "2022'06");
        compare(at("{date format=\"d MMMM yyyy\"}", r6now, {locale: fr}), "15 juin 2022");
        compare(at("{date format='dd.MM.yyyy'}", r6now), "15.06.2022");
        compare(at("{date format=yyyy}", r6now), "2022");
        compare(at("{date format=\"QQ\"}", r6now), "{date format=\"QQ\"}", "an unknown pattern letter leaves the group as written");
        compare(at("{date format=\"ZZZZ\"}", r6now), "{date format=\"ZZZZ\"}");
        compare(at("{date format=\"'open\"}", r6now), "{date format=\"'open\"}");
    }

    // ---- [R6] offsets

    function test_r6Offsets() {
        compare(at("{date offset=\"+2y +5M\" format=\"yyyy-MM-dd\"}", r6now), "2024-11-15");
        compare(at("{time offset=\"+3h +30m\" format=\"HH:mm\"}", r6now), "17:14");
        compare(at("{day offset=-3d}", r6now), "Sunday");
        compare(at("{datetime offset=+1h format=\"yyyy-MM-dd HH:mm\"}", r6now), "2022-06-15 14:44");
        compare(at("{date offset=\"+ 2d\"}", r6now), "{date offset=\"+ 2d\"}", "no space after the sign");
        compare(at("{date offset=\"+1d\" format=\"d\"}", r6now), "16");
        compare(at("{date offset=\"-1d\" format=\"d\"}", r6now), "14");
        compare(at("{date offset=\"1d\"}", r6now), "{date offset=\"1d\"}");
        compare(at("{date offset=\"+1D\"}", r6now), "{date offset=\"+1D\"}", "units are case-sensitive");
        compare(at("{date offset=\"+1w\"}", r6now), "{date offset=\"+1w\"}", "w is not an [R6] unit");
        compare(at("{date offset=\"+1s\"}", r6now), "{date offset=\"+1s\"}", "s is not an [R6] unit");
        compare(at("{date offset=\"+1d+2d\"}", r6now), "{date offset=\"+1d+2d\"}", "offsets are separated by spaces");
        compare(at("{time offset=\"+90m\" format=\"HH:mm\"}", r6now), "15:14");
        compare(at("{time offset=\"+5m\" format=\"mm\"}", r6now), "49");
        compare(at("{date offset=\"+1M\" format=\"M\"}", r6now), "7", "M is months");
    }

    function test_monthOffsetClampsTheDay() {
        compare(at("{date offset=\"+1M\" format=\"yyyy-MM-dd\"}", new Date(2026, 0, 31, 10)), "2026-02-28");
        compare(at("{date offset=\"+1y\" format=\"yyyy-MM-dd\"}", new Date(2028, 1, 29, 10)), "2029-02-28");
    }

    // ---- [R6] locale

    function test_r6Locale() {
        compare(at("{date locale=\"fr-FR\"}", r6now), "15 juin 2022");
        compare(at("{date locale=\"fr-FR\" offset=\"+1d\"}", r6now), "16 juin 2022");
        compare(at("{time locale=\"en-US-u-hc-h23\"}", r6now), "13:44");
        compare(at("{time locale=\"en-US\"}", r6now), "1:44 pm");
        compare(at("{time locale=\"fr-FR-u-hc-h12\"}", r6now), "1:44 pm");
        compare(at("{day locale=\"fr-FR\"}", r6now), "mercredi");
        compare(at("{day locale=\"en\"}", r6now, {locale: fr}), "Wednesday");
        compare(at("{datetime locale=\"fr-FR\"}", r6now), "15 juin 2022 à 13:44");
        compare(at("{date format=\"yyyy\" locale=\"fr-FR\"}", r6now), "{date format=\"yyyy\" locale=\"fr-FR\"}", "format and locale are exclusive");
        compare(at("{date locale=\"fr_FR\"}", r6now), "{date locale=\"fr_FR\"}", "hyphens, not underscores");
        compare(at("{date locale=\"de-DE\"}", r6now), "{date locale=\"de-DE\"}", "a language without names here is not valid (documented subset)");
        compare(at("{date locale=\"xx\"}", r6now), "{date locale=\"xx\"}");
    }

    function test_uuidIsUpperCase() {
        compare(text("{uuid}", {uuid: undefined}).length, 36);
        const r = Placeholders.expand("{uuid}", {});
        verify(/^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/.test(r.text), r.text);
        compare(r.carriesData, false);
    }

    // ---- cursor

    function test_cursorPositionCountsCharactersAfterIt() {
        const r = ex("Hello {cursor}world!");
        compare(r.text, "Hello world!");
        compare(r.cursor, 6);
        compare(ex("{cursor}abc").cursor, 3);
        compare(ex("abc{cursor}").cursor, 0);
        compare(ex("a{cursor}😀b").cursor, 2, "a character is a code point");
        compare(ex("no cursor").cursor, null);
        compare(ex("a{cursor}{clipboard}", {clipboard: "xyz"}).cursor, 3);
        compare(ex("{cursor | uppercase}").text, "{cursor | uppercase}");
    }

    function test_secondCursorIsRefused() {
        // [R6]: "A snippet can contain only one {cursor} placeholder." Refused, never silently dropped.
        const r = ex("a{cursor}b{cursor}c");
        compare(r.ok, false);
        compare(r.error, "cursor");
        compare(r.carriesData, true);
        compare(ex("{cursor}{snippet name=\"s\"}", {snippet: {s: "x{cursor}"}}).error, "cursor");
    }

    // ---- calculator

    function test_calculatorIsAField() {
        let r = ex("= {calculator}", {arguments: {"#1": "2*(3+4)"}});
        compare(r.text, "= 14");
        compare(r.fields.length, 1);
        compare(r.fields[0].calculator, true);
        compare(r.carriesData, false);
        compare(r.pieces[1].source, "typed");
        compare(ex("{calculator}", {arguments: {"#1": "10 / 4"}, locale: fr}).text, "2,5");
        r = ex("{calculator}", {arguments: {}});
        compare(r.ok, true);
        compare(r.missing.join(","), "#1");
        compare(ex("{calculator}", {arguments: {"#1": "1/0"}}).missing.join(","), "#1");
        compare(text("{calculator expression=\"2*3\"}"), "{calculator expression=\"2*3\"}", "no invented attribute");
    }

    // ---- arguments ([R6])

    function test_everyBareArgumentIsItsOwnField() {
        const r = ex("{argument} and {argument}", {arguments: {"#1": "one", "#2": "two"}});
        compare(r.text, "one and two");
        compare(r.fields.map(f => f.id).join(","), "#1,#2");
        compare(r.missing.length, 0);
        const m = ex("{argument} {argument}", {arguments: {"#1": "one"}});
        compare(m.missing.join(","), "#2");
    }

    function test_sameNameSharesAValue() {
        const r = ex("{argument name=\"tone\"} / {argument name=\"tone\" | uppercase}", {arguments: {tone: "happy"}});
        compare(r.text, "happy / HAPPY");
        compare(r.fields.length, 1);
        compare(r.fields[0].name, "tone");
    }

    function test_argumentDefaultsMakeItOptional() {
        let r = ex("{argument default=\"happy\"}", {arguments: {}});
        compare(r.text, "happy");
        compare(r.missing.length, 0);
        compare(r.pieces[0].source, "literal");
        compare(ex("{argument name=\"sport\" default=\"skiing\"}", {arguments: {sport: "golf"}}).text, "golf");
        compare(ex("{argument name=\"sport\" default=\"skiing\"}", {arguments: {sport: ""}}).text, "skiing");
        r = ex("{argument name=\"sport\"}", {arguments: {}});
        compare(r.text, "");
        compare(r.missing.join(","), "sport", "required until a value is typed");
        compare(r.carriesData, false);
    }

    function test_argumentOptions() {
        const t = "{argument name=\"tone\" options=\"happy, sad, professional\"}";
        let r = ex(t, {arguments: {tone: "sad"}});
        compare(r.text, "sad");
        compare(r.fields[0].options.join("|"), "happy|sad|professional");
        r = ex(t, {arguments: {tone: "angry"}});
        compare(r.text, "");
        compare(r.missing.join(","), "tone", "a value outside the options is not accepted");
        compare(ex("{argument name=\"tone\" default=\"happy\" options=\"happy, sad\"}", {arguments: {}}).text, "happy");
    }

    function test_atMostThreeArguments() {
        compare(ex("{argument}{argument}{argument}").ok, true);
        compare(ex("{argument name=\"a\"}{argument name=\"a\"}{argument name=\"b\"}{argument name=\"c\"}").ok, true);
        const r = ex("{argument}{argument}{argument}{argument}");
        compare(r.ok, false);
        compare(r.error, "arguments");
        compare(r.carriesData, true);
        compare(ex("{argument}{argument}{calculator}{argument}").error, "arguments", "a calculator is one of the three");
    }

    function test_argumentEdgeCases() {
        compare(text("{argument name=\"constructor\"}", {arguments: {}}), "", "inherited names are not arguments");
        compare(text("{argument name=\"a|b\" default=\"x|y\"}", {arguments: {}}), "x|y", "a bar inside quotes is not a modifier");
        compare(text("{argument name=\"say \\\"hi\\\"\"}", {arguments: {"say \"hi\"": "ok"}}), "ok");
        compare(text("{argument name=\"#1\"}"), "{argument name=\"#1\"}");
        compare(text("{argument name=\"x\" name=\"y\"}"), "{argument name=\"x\" name=\"y\"}");
        compare(text("{argument what=1}"), "{argument what=1}");
    }

    // ---- unknown and unsupported

    function test_unknownAndUnsupportedPlaceholdersStayAsWritten() {
        compare(text("{foo}"), "{foo}");
        compare(text("{selection}"), "{selection}");
        compare(text("{browser-tab}"), "{browser-tab}");
        compare(text("{browser-tab format=\"text\"}"), "{browser-tab format=\"text\"}");
        compare(text("{clipboard what=1}"), "{clipboard what=1}");
        compare(text("{date nonsense=1}"), "{date nonsense=1}");
        compare(text("{uuid x=1}"), "{uuid x=1}");
        compare(text("{snippet}"), "{snippet}");
        compare(text("{snippet name=\"missing\"}"), "{snippet name=\"missing\"}");
        compare(text("{Clipboard}"), "{Clipboard}", "names are lowercase");
        compare(ex("{selection}").carriesData, false, "nothing was substituted");
    }

    function test_clipboardOffsetIsRefused() {
        let r = ex("{clipboard offset=1}");
        compare(r.ok, false);
        compare(r.error, "clipboard-offset");
        compare(r.carriesData, true);
        compare(ex("x {clipboard offset=\"2\"} y").error, "clipboard-offset");
        compare(ex("{clipboard offset=abc}").text, "{clipboard offset=abc}");
    }

    // ---- snippets and their nesting

    function test_snippetExpandsRecursively() {
        const snippets = {sig: "Best,\n{argument name=\"me\" default=\"Me\"}", outer: "[{snippet name=\"sig\"}]"};
        compare(text("{snippet name=\"sig\"}", {snippet: snippets}), "Best,\nMe");
        compare(text("{snippet name=\"outer\"}", {snippet: snippets}), "[Best,\nMe]");
        compare(text("{snippet name=\"sig\" | uppercase}", {snippet: snippets}), "BEST,\nME");
        compare(text("{snippet name=\"s\"}", {snippet: name => name === "s" ? "from a function" : undefined}), "from a function");
        compare(text("{snippet name=\"constructor\"}", {snippet: {}}), "{snippet name=\"constructor\"}");
        compare(ex("{snippet name=\"sig\"}", {snippet: snippets}).fields.length, 1, "a snippet's arguments are fields of the whole");
    }

    function test_snippetNestingUpToThreeLevels() {
        const s = {a: "A{snippet name=\"b\"}", b: "B{snippet name=\"c\"}", c: "C{snippet name=\"d\"}", d: "D{snippet name=\"e\"}", e: "E"};
        compare(text("{snippet name=\"a\"}", {snippet: {a: "A{snippet name=\"b\"}", b: "B{snippet name=\"c\"}", c: "C"}}), "ABC");
        const r = ex("{snippet name=\"a\"}", {snippet: s});
        compare(r.ok, false);
        compare(r.error, "nesting");
        compare(r.text, "");
        compare(r.carriesData, true, "an error is never a data-free result");
        compare(ex("{snippet name=\"c\"}", {snippet: s}).text, "CDE", "three levels, the last one allowed");
        compare(ex("{snippet name=\"b\"}", {snippet: s}).error, "nesting");
    }

    function test_snippetCycleIsRefused() {
        compare(ex("{snippet name=\"x\"}", {snippet: {x: "again {snippet name=\"x\"}"}}).error, "nesting");
        compare(ex("{snippet name=\"p\"}", {snippet: {p: "{snippet name=\"q\"}", q: "{snippet name=\"p\"}"}}).error, "nesting");
    }

    function test_snippetExplosionIsBounded() {
        const r = ex("{snippet name=\"b\"}", {snippet: {b: "{snippet name=\"b\"}".repeat(200)}});
        compare(r.ok, false);
        verify(r.error === "too-many" || r.error === "too-long" || r.error === "nesting", r.error);
        compare(r.carriesData, true);
    }

    function test_outputIsCapped() {
        const r = ex("{snippet name=\"b\"}".repeat(20), {snippet: {b: "x".repeat(65536)}});
        compare(r.ok, false);
        compare(r.error, "too-long");
    }

    // ---- provenance

    function sources(r) {
        return r.pieces.map(p => p.source);
    }

    function test_provenanceOfEachPiece() {
        const r = ex("a {clipboard} b {argument} c {date format=\"yyyy\"} d");
        compare(r.text, "a copied text b typed c 2026 d");
        compare(sources(r).join(","), "literal,clipboard,literal,typed,literal,generated,literal");
        compare(r.carriesData, true);
    }

    function test_typedAndGeneratedDoNotCarryData() {
        compare(ex("{argument}").carriesData, false);
        compare(ex("{date}{time}{datetime}{day}{uuid}").carriesData, false);
        compare(ex("{argument name=\"q\" default=\"x\"}", {arguments: {}}).carriesData, false);
        compare(ex("plain https://example.org/?q={argument}").carriesData, false);
    }

    function test_clipboardCarriesDataEvenWhenEmpty() {
        compare(ex("{clipboard}", {clipboard: ""}).carriesData, true);
        compare(ex("{clipboard | trim}").carriesData, true, "a modifier does not wash the origin");
        compare(ex("{clipboard | percent-encode}").carriesData, true);
    }

    function test_snippetHoldingClipboardCarriesData() {
        const s = {withclip: "see {clipboard}", noclip: "plain {argument} {date}", deep: "{snippet name=\"withclip\"}",
            deeper: "{snippet name=\"deep\"}"};
        compare(ex("{snippet name=\"withclip\"}", {snippet: s}).carriesData, true);
        compare(ex("{snippet name=\"noclip\"}", {snippet: s}).carriesData, false);
        compare(ex("{snippet name=\"deep\"}", {snippet: s}).carriesData, true);
        compare(ex("{snippet name=\"deeper\"}", {snippet: s}).carriesData, true, "three levels down still marked");
        compare(ex("{snippet name=\"withclip\" | uppercase}", {snippet: s}).carriesData, true, "a modifier on the snippet keeps the mark");
        compare(sources(ex("{snippet name=\"withclip\"}", {snippet: s})).join(","), "literal,clipboard");
    }

    // ---- links: every substituted piece, a snippet's whole text included, is percent-encoded

    function test_urlModeEncodesSubstitutedPieces() {
        const r = ex("https://example.org/search?q={argument}&c={clipboard}", {url: true, arguments: {"#1": "a b&c"}, clipboard: "x/y z"});
        compare(r.text, "https://example.org/search?q=a%20b%26c&c=x%2Fy%20z");
        compare(r.carriesData, true);
        compare(ex("https://example.org/?d={date format=\"yyyy MM\"}", {url: true}).text, "https://example.org/?d=2026%2011");
        compare(ex("https://x/?q={argument | percent-encode}", {url: true, arguments: {"#1": "a b"}}).text, "https://x/?q=a%20b", "no double encoding");
        compare(ex("https://x/?q={clipboard}", {url: false, clipboard: "a b"}).text, "https://x/?q=a b");
        compare(ex("https://x/?q={clipboard | uppercase}", {url: true, clipboard: "a b"}).text, "https://x/?q=A%20B");
    }

    function test_urlModeRawDoesNotLiftTheEncoding() {
        // ADR-0067 D-7: [R6]'s `raw` opts out of the default encoding in Raycast; here it never does, so a copied
        // "&evil=1#frag" cannot add a parameter or a fragment to the link.
        compare(ex("https://x/?q={clipboard | raw}", {url: true, clipboard: "a b&evil=1#frag"}).text, "https://x/?q=a%20b%26evil%3D1%23frag");
        compare(ex("https://x/?q={argument | raw}", {url: true, arguments: {"#1": "a&b"}}).text, "https://x/?q=a%26b");
        compare(ex("https://x/?q={clipboard | raw}", {url: false, clipboard: "a&b"}).text, "https://x/?q=a&b", "outside a link raw is plain");
    }

    function test_urlModeEncodesAnUnmodifiedSnippetsOwnText() {
        const s = {t: "a b&evil=1#frag {clipboard}", plain: "a b&evil=1#frag"};
        compare(ex("https://x/?q={snippet name=\"plain\"}", {url: true, snippet: s}).text, "https://x/?q=a%20b%26evil%3D1%23frag");
        const r = ex("https://x/?q={snippet name=\"t\"}", {url: true, snippet: s, clipboard: "c d"});
        compare(r.text, "https://x/?q=a%20b%26evil%3D1%23frag%20c%20d");
        compare(r.carriesData, true);
        compare(sources(r).join(","), "literal,clipboard");
        compare(ex("https://x/?q={snippet name=\"plain\" | uppercase}", {url: true, snippet: s}).text, "https://x/?q=A%20B%26EVIL%3D1%23FRAG");
        compare(ex("https://x/?q={snippet name=\"plain\"}", {url: false, snippet: s}).text, "https://x/?q=a b&evil=1#frag");
    }

    function test_urlModeLoneSurrogateIsAnError() {
        const r = ex("https://x/?q={clipboard}", {url: true, clipboard: "\ud800"});
        compare(r.ok, false);
        compare(r.error, "encoding");
        compare(r.carriesData, true);
    }

    // ---- robustness

    function test_neverThrows() {
        compare(Placeholders.expand(null, {}).ok, false);
        compare(Placeholders.expand(undefined).ok, false);
        compare(Placeholders.expand("{clipboard}").ok, true);
        compare(Placeholders.expand("{clipboard}", null).text, "");
        compare(Placeholders.expand("{", {}).text, "{");
        compare(Placeholders.expand("{argument name=\"unterminated}", {}).text, "{argument name=\"unterminated}");
        compare(Placeholders.expand("}{", {}).text, "}{");
    }

    // A hundred kilobytes of hostile text is read in linear time: each case stays far under a second, and doubling the
    // size does not quadruple the time.
    function timeOf(template) {
        const t = Date.now();
        const r = Placeholders.expand(template, {});
        const ms = Date.now() - t;
        verify(r.ok, "expansion failed");
        compare(r.text, template, "a text that holds no valid placeholder comes back unchanged");
        return ms;
    }

    function test_parserIsLinear() {
        const hostile = ["{\"", "{'", "{a ", "{\"}", "{date ", "{clipboard|", "{x=\"", "{a b=\"{", "x", "{\"\\", "}{"];
        for (const unit of hostile) {
            const small = unit.repeat(Math.ceil(50000 / unit.length));
            const big = unit.repeat(Math.ceil(100000 / unit.length));
            const t1 = timeOf(small);
            const t2 = timeOf(big);
            verify(t2 < 1500, "100 KB of " + unit + " took " + t2 + " ms");
            verify(t2 < 4 * Math.max(t1, 25), unit + ": " + t1 + " ms for 50 KB, " + t2 + " ms for 100 KB");
        }
    }

    function test_oneLongOpenGroupIsPlainText() {
        const t = "{clipboard " + "a".repeat(6000) + "}";
        compare(timeOf(t) < 1500, true);
    }
}
