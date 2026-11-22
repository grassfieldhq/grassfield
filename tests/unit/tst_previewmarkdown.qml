pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/preview/qml"
import "../../apps/preview/qml/Markdown.js" as Markdown

// Owner report on 1.0.0-rc9: "Preview does not preview .md files" (they showed their source). A Markdown document shows
// rendered in Preview and in the Glance (rich text from the backend, pictures fitted to the column by the backend without a
// new parse, the theme's link colour and a code fill that shows in both appearances), read only and selectable, with its source a click away (View > Show Markdown Source, the toolbar's source button).
TestCase {
    id: tc
    name: "PreviewMarkdown"
    width: 700
    height: 500
    visible: true
    when: windowShown

    readonly property string html: "<!DOCTYPE HTML><html><head><style type=\"text/css\">\np, li { white-space: pre-wrap; }\n</style></head><body>"
        + "<h1><span style=\" font-size:xx-large; font-weight:700;\">Release notes</span></h1>"
        + "<p>Some <a href=\"https://example.com\">link</a> and <a href=\"other.md\">a file</a>.</p>"
        + "<p><img src=\"image://preview/fit/1600x800/1\" alt=\"wide\" title=\"\" width=\"1600\" height=\"800\" /> <img src=\"image://preview/fit/100x50/2\" alt=\"small\" title=\"\" width=\"100\" height=\"50\" /></p>"
        + "<pre><span style=\" font-family:'monospace';\">echo hi</span></pre></body></html>"

    // The backend double: what PreviewApp.inspect answers for a .md file, and the links it was asked to open.
    QtObject {
        id: linkBackend
        property var opened: []
        // The resize path (PreviewApp.fitMarkdownImages): the widths it was asked to fit to.
        property var fits: []
        function fitMarkdownImages(document, width) {
            fits.push(width);
            return 0;
        }
        function openLink(link) {
            opened.push(link);
            return true;
        }
    }

    Component {
        id: viewComponent
        TextView {
            width: 600
            height: 400
            backend: linkBackend
        }
    }

    function makeView(info: var): var {
        const v = createTemporaryObject(viewComponent, tc, {info: info});
        verify(v !== null);
        return v;
    }

    function test_themeColoursGoInTheStyleSheet() {
        const out = Markdown.styled(tc.html, {link: Qt.rgba(0, 0.5, 1, 1), code: Qt.rgba(0, 0, 0, 0.05)});
        verify(out.indexOf("a { color: #0080ff; }") >= 0, out);
        verify(out.indexOf("pre { background-color: rgba(0, 0, 0, 0.05); }") >= 0, out);
        verify(out.indexOf("a { color") < out.indexOf("</style>"));
        compare(Markdown.styled("", {}), "");
        // Never the view's width: the HTML depends on the document and the theme only.
        verify(Markdown.fitImages === undefined);
    }

    function test_onlyWebLinksOpen() {
        verify(Markdown.isWebLink("https://example.com/a"));
        verify(Markdown.isWebLink("http://example.com"));
        verify(!Markdown.isWebLink("other.md"));
        verify(!Markdown.isWebLink("file:///etc/passwd"));
        verify(!Markdown.isWebLink("javascript:alert(1)"));
        verify(!Markdown.isWebLink("#section"));
        verify(!Markdown.isWebLink(undefined));
    }

    function test_markdownShowsRenderedThenItsSource() {
        const v = makeView({ok: true, kind: "text", name: "notes.md", markdown: true, html: tc.html, text: "# Release notes\n"});
        const rich = findChild(v, "markdownText");
        verify(rich !== null);
        verify(v.canShowSource);
        verify(v.rendered);
        verify(rich.visible);
        compare(rich.textFormat, TextEdit.RichText);
        verify(rich.readOnly);
        verify(rich.selectByMouse);
        // The document's text, not its markup: Select All and Copy take the words.
        v.selectAll();
        verify(v.canCopy);
        verify(rich.selectedText.indexOf("Release notes") >= 0, rich.selectedText);
        verify(rich.selectedText.indexOf("<h1") < 0);
        // The pictures are fitted to the column by the backend, never in the HTML.
        verify(linkBackend.fits.indexOf(rich.width) >= 0, JSON.stringify(linkBackend.fits));
        verify(rich.text.indexOf("width=\"1600\"") >= 0);
        // The source: the plain text, monospace, never markup.
        v.showSource = true;
        verify(!v.rendered);
        verify(!rich.visible);
        compare(v.edit.textFormat, TextEdit.PlainText);
        compare(v.edit.text, "# Release notes\n");
        v.showSource = false;
        verify(v.rendered);
    }

    function test_aLinkOpensOnlyOnTheWeb() {
        const v = makeView({ok: true, kind: "text", name: "notes.md", markdown: true, html: tc.html, text: "x"});
        const rich = findChild(v, "markdownText");
        linkBackend.opened = [];
        rich.linkActivated("https://example.com");
        rich.linkActivated("other.md");
        rich.linkActivated("file:///etc/passwd");
        compare(linkBackend.opened, ["https://example.com"]);
    }

    function test_plainTextHasNoSourceToggle() {
        const v = makeView({ok: true, kind: "text", name: "notes.txt", text: "# not rendered\n"});
        verify(!v.canShowSource);
        verify(!v.rendered);
        compare(v.edit.textFormat, TextEdit.PlainText);
        compare(v.edit.text, "# not rendered\n");
    }

    // A long Markdown file without its rendered HTML (past the bound): its source, in pieces as any long text.
    function test_longMarkdownShowsItsSourceInPieces() {
        const v = makeView({ok: true, kind: "text", name: "big.md", markdown: true, text: "a\nb\n", chunks: ["a\n", "b\n"]});
        verify(!v.rendered);
        verify(v.chunked);
    }

    // Review 2026-11-22: a resize re-parsed the whole document (the text bound to the width) and lost the selection. Now a
    // new width only refits the pictures: the text stays, the selection stays.
    function test_aResizeKeepsTheTextAndTheSelection() {
        const v = makeView({ok: true, kind: "text", name: "notes.md", markdown: true, html: tc.html, text: "x"});
        const rich = findChild(v, "markdownText");
        rich.select(0, 7);
        const selected = rich.selectedText;
        verify(selected.length > 0);
        const before = rich.text;
        let reparsed = false;
        const watch = () => reparsed = true;
        rich.textChanged.connect(watch);
        linkBackend.fits = [];
        v.width = 420;
        tryVerify(() => linkBackend.fits.length > 0, 2000, "the pictures are refitted to the new width");
        compare(linkBackend.fits[linkBackend.fits.length - 1], rich.width);
        verify(!reparsed, "no new parse");
        compare(rich.text, before);
        compare(rich.selectedText, selected);
        rich.textChanged.disconnect(watch);
    }
}
