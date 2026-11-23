import QtQuick
import QtTest
import "../../shell/search/Placeholders.js" as Placeholders

// Palette slice T1 (spec command-palette.md T1): the placeholder expander and the provenance of every substituted piece.
TestCase {
    name: "Placeholders"

    readonly property var fr: Qt.locale("fr_FR")
    // Monday 23 November 2026, 14:05:09 local time.
    readonly property var now: new Date(2026, 10, 23, 14, 5, 9)

    function ex(template, extra) {
        const ctx = {now: now, clipboard: "copied text", argument: "typed", uuid: () => "00000000-0000-4000-8000-000000000000"};
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

    function test_plainTextIsUntouched() {
        compare(text("hello world"), "hello world");
        compare(text(""), "");
        compare(text("{}"), "{}");
        compare(text("a { b } c"), "a { b } c");
        compare(text("{{clipboard}"), "{copied text");
        compare(ex("hello").carriesData, false);
    }

    function test_clipboardAndModifiers() {
        compare(text("{clipboard}"), "copied text");
        compare(text("[{clipboard}]"), "[copied text]");
        compare(text("{clipboard | uppercase}"), "COPIED TEXT");
        compare(text("{clipboard|uppercase}"), "COPIED TEXT");
        compare(text("{clipboard | trim | lowercase}", {clipboard: "  MiXed  "}), "mixed");
        compare(text("{clipboard | percent-encode}", {clipboard: "a b&c/é"}), "a%20b%26c%2F%C3%A9");
        compare(text("{clipboard | json-stringify}", {clipboard: "say \"hi\"\nnow\\"}), "say \\\"hi\\\"\\nnow\\\\");
        compare(text("{clipboard | raw}"), "copied text");
        compare(text("{clipboard | trim | nonsense}"), "{clipboard | trim | nonsense}", "an unknown modifier leaves the group as written");
        compare(text("{clipboard}", {clipboard: undefined}), "");
    }

    function test_dateTimePlaceholders() {
        compare(text("{date}"), "Nov 23, 2026");
        compare(text("{time}"), "2:05 PM");
        compare(text("{datetime}"), "Nov 23, 2026 2:05 PM");
        compare(text("{day}"), "Monday");
        compare(text("{date}", {locale: fr}), "23 nov. 2026");
        compare(text("{time}", {locale: fr}), "14:05");
        compare(text("{day}", {locale: fr}), "lundi");
    }

    function test_formats() {
        compare(text("{date format=\"yyyy-MM-dd\"}"), "2026-11-23");
        compare(text("{date format=\"dd/MM/yy\"}"), "23/11/26");
        compare(text("{date format=\"EEEE d MMMM yyyy\"}"), "Monday 23 November 2026");
        compare(text("{date format=\"EEE, MMM d\"}"), "Mon, Nov 23");
        compare(text("{time format=\"HH:mm:ss\"}"), "14:05:09");
        compare(text("{time format=\"hh:mm a\"}"), "02:05 PM");
        compare(text("{datetime format=\"yyyy-MM-dd'T'HH:mm\"}"), "2026-11-23T14:05");
        compare(text("{date format=\"'week' d\"}"), "week 23");
        compare(text("{date format='dd.MM.yyyy'}"), "23.11.2026");
        compare(text("{date format=yyyy}"), "2026");
        compare(text("{date format=\"yyyy-MM-dd\" | uppercase}"), "2026-11-23");
        compare(text("{date format=\"QQ\"}"), "{date format=\"QQ\"}", "an unknown pattern letter leaves the group as written");
    }

    function test_localeAndFormatAreExclusive() {
        compare(text("{date locale=\"fr\"}"), "23 nov. 2026");
        compare(text("{date locale=\"fr_FR\"}"), "23 nov. 2026");
        compare(text("{day locale=\"fr\"}"), "lundi");
        compare(text("{day locale=\"en\"}", {locale: fr}), "Monday");
        compare(text("{date format=\"yyyy\" locale=\"fr\"}"), "{date format=\"yyyy\" locale=\"fr\"}");
        compare(text("{date locale=\"xx\"}"), "{date locale=\"xx\"}");
    }

    function test_offsetsHaveNoSpaceAfterTheSign() {
        compare(text("{date offset=\"+1d\" format=\"yyyy-MM-dd\"}"), "2026-11-24");
        compare(text("{date offset=\"-1d\" format=\"yyyy-MM-dd\"}"), "2026-11-22");
        compare(text("{date offset=\"+1w\" format=\"yyyy-MM-dd\"}"), "2026-11-30");
        compare(text("{date offset=\"+1M\" format=\"yyyy-MM-dd\"}"), "2026-12-23");
        compare(text("{date offset=\"+1y\" format=\"yyyy-MM-dd\"}"), "2027-11-23");
        compare(text("{date offset=\"+1y -2d\" format=\"yyyy-MM-dd\"}"), "2027-11-21");
        compare(text("{time offset=\"+90m\" format=\"HH:mm\"}"), "15:35");
        compare(text("{time offset=\"-5h\" format=\"HH:mm\"}"), "09:05");
        compare(text("{date offset=+1d format=\"d\"}"), "24", "unquoted value");
        compare(text("{date offset=\"+ 1d\"}"), "{date offset=\"+ 1d\"}");
        compare(text("{date offset=\"1d\"}"), "{date offset=\"1d\"}");
        compare(text("{date offset=\"+1x\"}"), "{date offset=\"+1x\"}");
        compare(text("{date offset=\"+1d\"}"), "Nov 24, 2026");
    }

    function test_monthOffsetClampsTheDay() {
        const jan31 = new Date(2026, 0, 31, 10, 0, 0);
        compare(text("{date offset=\"+1M\" format=\"yyyy-MM-dd\"}", {now: jan31}), "2026-02-28");
        const leap = new Date(2028, 1, 29, 10, 0, 0);
        compare(text("{date offset=\"+1y\" format=\"yyyy-MM-dd\"}", {now: leap}), "2029-02-28");
    }

    function test_uuidAndCursorAndCalculator() {
        compare(text("{uuid}"), "00000000-0000-4000-8000-000000000000");
        const r = Placeholders.expand("{uuid}", {});
        verify(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(r.text), r.text);
        compare(text("{calculator expression=\"2*(3+4)\"}"), "14");
        compare(text("{calculator expression=\"10 / 4\"}", {locale: fr}), "2,5");
        compare(text("{calculator expression=\"1/0\"}"), "{calculator expression=\"1/0\"}");
        compare(text("{calculator}"), "{calculator}");
    }

    function test_cursorPositionCountsCharactersAfterIt() {
        const r = ex("Hello {cursor}world!");
        compare(r.text, "Hello world!");
        compare(r.cursor, 6);
        compare(ex("{cursor}abc").cursor, 3);
        compare(ex("abc{cursor}").cursor, 0);
        compare(ex("a{cursor}b{cursor}c").cursor, 2, "the first {cursor} wins");
        compare(ex("a{cursor}😀b").cursor, 2, "a character is a code point");
        compare(ex("no cursor").cursor, null);
        compare(ex("a{cursor}{clipboard}", {clipboard: "xyz"}).cursor, 3);
        compare(ex("{cursor | uppercase}").text, "{cursor | uppercase}");
    }

    function test_arguments() {
        compare(text("hi {argument}"), "hi typed");
        compare(text("{argument name=\"who\"}", {arguments: {who: "Ada"}}), "Ada");
        compare(text("{argument name=\"who\" default=\"you\"}", {arguments: {}}), "you");
        compare(text("{argument name=\"who\" default=\"you\"}", {arguments: {who: ""}}), "you");
        compare(text("{argument default=\"nobody\"}", {argument: ""}), "nobody");
        compare(text("{argument name=\"who\"}", {arguments: {}}), "");
        compare(text("{argument name=\"constructor\"}", {arguments: {}}), "", "inherited names are not arguments");
        compare(text("{argument name=\"who\" | uppercase}", {arguments: {who: "ada"}}), "ADA");
        compare(text("{argument name=\"a|b\" default=\"x|y\"}", {arguments: {}}), "x|y", "a bar inside quotes is not a modifier");
        compare(text("{argument name=\"say \\\"hi\\\"\"}", {arguments: {"say \"hi\"": "ok"}}), "ok");
    }

    function test_unknownAndUnsupportedPlaceholdersStayAsWritten() {
        compare(text("{foo}"), "{foo}");
        compare(text("{selection}"), "{selection}");
        compare(text("{browser-tab}"), "{browser-tab}");
        compare(text("{clipboard what=1}"), "{clipboard what=1}");
        compare(text("{date nonsense=1}"), "{date nonsense=1}");
        compare(text("{uuid x=1}"), "{uuid x=1}");
        compare(text("{snippet}"), "{snippet}");
        compare(text("{snippet name=\"missing\"}"), "{snippet name=\"missing\"}");
        compare(text("{Clipboard}"), "{Clipboard}", "names are lowercase");
        compare(ex("{selection}").carriesData, false, "nothing was substituted");
        compare(text("{argument name=\"x\" name=\"y\"}"), "{argument name=\"x\" name=\"y\"}");
    }

    function test_clipboardOffsetIsRefused() {
        let r = ex("{clipboard offset=1}");
        compare(r.ok, false);
        compare(r.error, "clipboard-offset");
        compare(r.carriesData, true);
        r = ex("x {clipboard offset=\"2\"} y");
        compare(r.error, "clipboard-offset");
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
    }

    function test_snippetNestingUpToThreeLevels() {
        const s = {a: "A{snippet name=\"b\"}", b: "B{snippet name=\"c\"}", c: "C{snippet name=\"d\"}", d: "D{snippet name=\"e\"}", e: "E"};
        // Template -> a (1) -> b (2) -> c (3): allowed.
        compare(text("{snippet name=\"a\"}", {snippet: {a: "A{snippet name=\"b\"}", b: "B{snippet name=\"c\"}", c: "C"}}), "ABC");
        // Template -> a (1) -> b (2) -> c (3) -> d (4): refused.
        const r = ex("{snippet name=\"a\"}", {snippet: s});
        compare(r.ok, false);
        compare(r.error, "nesting");
        compare(r.text, "");
        compare(r.carriesData, true, "an error is never a data-free result");
        compare(ex("{snippet name=\"c\"}", {snippet: s}).text, "CDE", "three levels, the last one allowed");
        compare(ex("{snippet name=\"b\"}", {snippet: s}).error, "nesting");
    }

    function test_snippetCycleIsRefused() {
        const self = ex("{snippet name=\"x\"}", {snippet: {x: "again {snippet name=\"x\"}"}});
        compare(self.error, "nesting");
        const pair = ex("{snippet name=\"p\"}", {snippet: {p: "{snippet name=\"q\"}", q: "{snippet name=\"p\"}"}});
        compare(pair.error, "nesting");
    }

    function test_snippetExplosionIsBounded() {
        const bomb = "{snippet name=\"b\"}".repeat(200);
        const r = ex("{snippet name=\"b\"}", {snippet: {b: bomb}});
        compare(r.ok, false);
        verify(r.error === "too-many" || r.error === "too-long" || r.error === "nesting", r.error);
        compare(r.carriesData, true);
    }

    function test_outputIsCapped() {
        const big = "x".repeat(65536);
        const r = ex("{snippet name=\"b\"}".repeat(20), {snippet: {b: big}});
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
        compare(r.pieces[1].text, "copied text");
        compare(r.carriesData, true);
    }

    function test_typedAndGeneratedDoNotCarryData() {
        compare(ex("{argument}").carriesData, false);
        compare(ex("{date}{time}{datetime}{day}{uuid}").carriesData, false);
        compare(ex("{calculator expression=\"1+1\"}").carriesData, false);
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
        const r = ex("{snippet name=\"withclip\"}", {snippet: s});
        compare(sources(r).join(","), "literal,clipboard");
    }

    // ---- links: every substituted piece is percent-encoded, the literal text is not

    function test_urlModeEncodesSubstitutedPieces() {
        const r = ex("https://example.org/search?q={argument}&c={clipboard}", {url: true, argument: "a b&c", clipboard: "x/y z"});
        compare(r.text, "https://example.org/search?q=a%20b%26c&c=x%2Fy%20z");
        compare(r.carriesData, true);
        compare(ex("https://example.org/?d={date format=\"yyyy MM\"}", {url: true}).text, "https://example.org/?d=2026%2011");
        compare(ex("https://x/?q={argument | percent-encode}", {url: true, argument: "a b"}).text, "https://x/?q=a%20b", "no double encoding");
        const s = {t: "w {clipboard}"};
        compare(ex("https://x/?q={snippet name=\"t\"}", {url: true, snippet: s, clipboard: "a b"}).text, "https://x/?q=w a%20b", "the literal text of the snippet is not encoded");
        compare(ex("https://x/?q={snippet name=\"t\" | uppercase}", {url: true, snippet: s, clipboard: "a b"}).text, "https://x/?q=W%20A%20B", "a modifier collapses the snippet, all of it is encoded");
        compare(ex("https://x/?q={clipboard}", {url: false, clipboard: "a b"}).text, "https://x/?q=a b");
    }

    function test_urlModeLoneSurrogateIsAnError() {
        const r = ex("https://x/?q={clipboard}", {url: true, clipboard: "\ud800"});
        compare(r.ok, false);
        compare(r.error, "encoding");
        compare(r.carriesData, true);
    }

    function test_neverThrows() {
        compare(Placeholders.expand(null, {}).ok, false);
        compare(Placeholders.expand(undefined).ok, false);
        compare(Placeholders.expand("{clipboard}").ok, true);
        compare(Placeholders.expand("{clipboard}", null).text, "");
        compare(Placeholders.expand("{", {}).text, "{");
        compare(Placeholders.expand("{argument name=\"unterminated}", {}).text, "{argument name=\"unterminated}");
        compare(Placeholders.expand("}{", {}).text, "}{");
    }
}
