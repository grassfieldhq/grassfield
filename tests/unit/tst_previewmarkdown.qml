pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/preview/qml"
import "../../apps/preview/qml/Markdown.js" as Markdown

// Owner report on 1.0.0-rc9: "Preview does not preview .md files" (they showed their source). A Markdown document shows
// rendered in Preview and in the Glance (rich text from the backend, pictures fitted to the column, the theme's link colour),
// read only and selectable, with its source a click away (View > Show Markdown Source, the toolbar's source button).
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
        + "<p><img src=\"image://preview/0/1\" alt=\"wide\" title=\"\" width=\"1600\" height=\"800\" /> <img src=\"image://preview/0/2\" alt=\"small\" title=\"\" width=\"100\" height=\"50\" /></p>"
        + "<pre><span style=\" font-family:'monospace';\">echo hi</span></pre></body></html>"

    // The backend double: what PreviewApp.inspect answers for a .md file, and the links it was asked to open.
    QtObject {
        id: linkBackend
        property var opened: []
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

    function test_picturesFitTheColumn() {
        const out = Markdown.fitImages(tc.html, 400);
        verify(out.indexOf("src=\"image://preview/0/1\" alt=\"wide\" title=\"\" width=\"400\" height=\"200\"") >= 0, out);
        verify(out.indexOf("width=\"100\" height=\"50\"") >= 0, "a small picture is never enlarged");
        compare(Markdown.fitImages(tc.html, 0), tc.html);
        compare(Markdown.fitImages(undefined, 300), "");
    }

    function test_themeColoursGoInTheStyleSheet() {
        const out = Markdown.styled(tc.html, 2000, {link: Qt.rgba(0, 0.5, 1, 1), code: Qt.rgba(0, 0, 0, 0.05)});
        verify(out.indexOf("a { color: #0080ff; }") >= 0, out);
        verify(out.indexOf("pre { background-color: rgba(0, 0, 0, 0.05); }") >= 0, out);
        verify(out.indexOf("a { color") < out.indexOf("</style>"));
        compare(Markdown.styled("", 300, {}), "");
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
        // The picture is fitted to the column it is shown in.
        verify(rich.text.indexOf("width=\"" + Math.floor(rich.width) + "\"") >= 0, rich.text.substring(0, 400));
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
}
