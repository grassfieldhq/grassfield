pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/preview/qml"

// Preview off the window's thread (2026-11 audit, round 2): a file is inspected on the backend's worker (P4) and the view
// waits for the answer without a message or a flash, keeping only the newest answer; a long text is laid out in pieces (P7)
// while Select All and Copy still take it whole.
TestCase {
    id: testCase
    name: "PreviewAsync"
    width: 400
    height: 300
    visible: true
    when: windowShown

    QtObject {
        id: backendItem
        property var files: [
            {name: "a.txt", path: "/x/a.txt", url: "file:///x/a.txt", kind: "text"},
            {name: "b.txt", path: "/x/b.txt", url: "file:///x/b.txt", kind: "text"}
        ]
        property var errors: []
        property bool textInImages: false
        property int last: 0
        property var asked: []
        property var copied: []
        signal inspected(int request, var info)
        function requestInspect(i) {
            last++;
            asked = asked.concat([{request: last, index: i}]);
            return last;
        }
        function inspect(i) {
            testCase.fail("the view inspected on its own thread");
            return {};
        }
        function copyText(text, concealed) {
            copied = copied.concat([text]);
        }
    }

    Component {
        id: contentComponent
        Content {
            width: 400
            height: 300
            backend: backendItem
        }
    }

    function find(item, name) {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const f = find(kids[i], name);
            if (f)
                return f;
        }
        if (item.contentItem && item.contentItem !== item)
            return find(item.contentItem, name);
        return null;
    }

    function textInfo(name, chunks) {
        return {ok: true, kind: "text", name: name, url: "file:///x/" + name, text: chunks.join(""), chunks: chunks};
    }

    function test_theViewWaitsForTheWorkersAnswer() {
        backendItem.asked = [];
        const c = createTemporaryObject(contentComponent, testCase, {fileIndex: 0});
        verify(c);
        compare(backendItem.asked.length, 1);
        compare(c.info.name, "a.txt", "the list's name until the answer");
        verify(c.info.pending === true);
        const message = find(c, "contentMessage");
        verify(!message.visible, "no \"nothing to show\" while the worker reads");
        verify(!find(c, "contentLoader").active);
        // Another file before the answer: the old answer is dropped.
        const old = backendItem.asked[0].request;
        c.fileIndex = 1;
        compare(backendItem.asked.length, 2);
        const current = backendItem.asked[1].request;
        backendItem.inspected(old, textInfo("a.txt", ["stale\n"]));
        compare(c.info.name, "b.txt");
        verify(c.info.pending === true);
        backendItem.inspected(current, {ok: true, kind: "text", name: "b.txt", url: "file:///x/b.txt", text: "hello\n"});
        verify(c.info.ok === true);
        tryVerify(() => find(c, "contentLoader").item !== null, 2000);
        verify(!message.visible);
        // An error answer shows the message.
        c.fileIndex = 0;
        backendItem.inspected(backendItem.asked[backendItem.asked.length - 1].request, {ok: false, name: "a.txt", error: "This file cannot be read."});
        verify(message.visible);
    }

    function test_aLongTextIsLaidOutInPieces() {
        backendItem.asked = [];
        backendItem.copied = [];
        const c = createTemporaryObject(contentComponent, testCase, {fileIndex: 0});
        const pieces = [];
        for (let i = 0; i < 200; i++) {
            let piece = "";
            for (let j = 0; j < 40; j++)
                piece += "piece " + i + " line " + j + "\n";
            pieces.push(piece);
        }
        backendItem.inspected(backendItem.asked[0].request, textInfo("a.txt", pieces));
        tryVerify(() => find(c, "contentLoader").item !== null, 2000);
        const view = find(c, "contentLoader").item;
        verify(view.chunked);
        const list = find(view, "textChunks");
        verify(list && list.visible);
        compare(list.count, 200);
        verify(list.contentItem.children.length < 50, "only the pieces on screen are made: " + list.contentItem.children.length);
        // Select All and Copy take the whole text.
        verify(!view.canCopy);
        view.selectAll();
        verify(view.canCopy);
        view.copy();
        compare(backendItem.copied.length, 1);
        compare(backendItem.copied[0], pieces.join(""));
        // A zoom step re-lays out the pieces on screen only (they all follow the factor).
        view.zoomIn();
        verify(view.factor > 1);
        list.positionViewAtEnd();
        tryVerify(() => list.contentItem.children.length < 50, 2000);
    }
}
