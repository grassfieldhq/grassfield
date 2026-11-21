import QtQuick
import QtTest
import Grassfield.Ui
import "memos"
import "../../apps/memos/qml/MemoLogic.js" as MemoLogic

// Grassfield Memos (apps/memos/qml, ADR-0051, docs/specs/memos.md): MemoLogic.js, a memo window with a fake backend (colours,
// collapse, the close rule and its alert, Translucent, the collapse's size tag, the Font keys and the plain paste, the text
// pushed to the backend), and Main.qml opening the stored memos, a new one near the front one, and a memo the compositor
// closed coming back on activation. The backend's own logic has its gtest cases (tests/unit/memos).
TestCase {
    id: testCase
    name: "Memos"
    width: 400
    height: 300
    visible: true
    when: windowShown
    // The backend of the refusal test (typed var: a created object is a QObject to qmllint).
    property var refusingBackend: null

    Component {
        id: fakeBackend
        FakeMemosBackend {}
    }

    Component {
        id: otherWindow
        Window {
            width: 50
            height: 50
            visible: true
        }
    }

    Component {
        id: fakeManager
        QtObject {
            property var lastActive: null
            property var quitAlertWindow: null
            property int quitRequests: 0
            property var deleted: []
            property var closed: []
            property int newMemos: 0
            function deleteMemo(w) {
                deleted = deleted.concat([w.memoId]);
                w.deleting = true;
                w.close();
            }
            function windowClosed(w) {
                closed = closed.concat([w.memoId]);
            }
            function newMemo() {
                newMemos++;
            }
            function requestQuit() {
                quitRequests++;
            }
            function cancelQuit() {
                quitAlertWindow = null;
            }
            function quitAnyway() {
            }
        }
    }

    // `toplevel`: the memo has no transient parent (Main.qml's windows have none): a window with one reads as active while
    // its parent's family has the focus, so only a toplevel memo can be seen losing it.
    function makeMemo(props, toplevel) {
        const backend = fakeBackend.createObject(testCase);
        backend.stored = [{id: "a", color: "blue", html: "", width: 240, height: 200, collapsed: false, translucent: false}];
        backend.open(240, 200);
        const manager = fakeManager.createObject(testCase);
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/memos/qml/MemoWindow.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const all = Object.assign({backend: backend, manager: manager, memoId: "a", colorName: "blue", width: 240, height: 200,
            expandedHeight: 200, gfChromeRole: "memo:a"}, props || {});
        const win = toplevel ? comp.createObject(null, all) : createTemporaryObject(comp, testCase, all);
        verify(win);
        win.requestActivate();
        tryVerify(() => win.active, 2000, "the memo is active");
        return {backend: backend, manager: manager, win: win};
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

    // ---- MemoLogic.js ----

    function test_logicColours() {
        compare(MemoLogic.colors, ["yellow", "blue", "green", "pink", "purple", "grey"]);
        compare(MemoLogic.validColor("pink"), "pink");
        compare(MemoLogic.validColor("magenta"), "yellow");
        compare(MemoLogic.paper(Tokens, "green"), Tokens.memosGreenPaper);
        compare(MemoLogic.strip(Tokens, "grey"), Tokens.memosGreyStrip);
        compare(MemoLogic.paper(Tokens, "nope"), Tokens.memosYellowPaper);
        compare(MemoLogic.colorForKey(1), "yellow");
        compare(MemoLogic.colorForKey(6), "grey");
        compare(MemoLogic.colorForKey(7), "");
        compare(MemoLogic.colorShortcut(2), "Ctrl+3");
    }

    function test_logicHeightsAndClose() {
        compare(MemoLogic.windowHeight(true, 300, 18, 72), 18);
        compare(MemoLogic.windowHeight(false, 300, 18, 72), 300);
        compare(MemoLogic.windowHeight(false, 40, 18, 72), 72);
        verify(!MemoLogic.keepsHeight(true, 300, 18));
        verify(!MemoLogic.keepsHeight(false, 18, 18));
        verify(MemoLogic.keepsHeight(false, 200, 18));
        verify(!MemoLogic.closeNeedsConfirm(""));
        verify(!MemoLogic.closeNeedsConfirm("  \n\t"));
        verify(!MemoLogic.closeNeedsConfirm(undefined));
        verify(MemoLogic.closeNeedsConfirm("milk"));
        compare(MemoLogic.title("  Groceries ", "Memo"), "Groceries");
        compare(MemoLogic.title("", "Memo"), "Memo");
    }

    function test_logicFrontMemo() {
        const a = {}, b = {}, c = {};
        compare(MemoLogic.frontMemo([a, b], b), b);
        compare(MemoLogic.frontMemo([a, b], c), b, "a memo no longer open: the newest");
        compare(MemoLogic.frontMemo([a, b], null), b);
        compare(MemoLogic.frontMemo([], null), null);
    }

    // ---- the memo window ----

    function test_paperStripAndColour() {
        const t = makeMemo();
        const strip = find(t.win.contentItem, "memoStrip");
        verify(strip);
        compare(strip.height, Tokens.memosStripHeight);
        verify(Qt.colorEqual(strip.color, Tokens.memosBlueStrip));
        verify(Qt.colorEqual(t.win.paperColor, Tokens.memosBluePaper));
        compare(t.win.title, "Memo");
        t.win.setColor("pink");
        verify(Qt.colorEqual(strip.color, Tokens.memosPinkStrip));
        compare(t.backend.lastUpdate("a", "color"), "pink");
        // A colour key (Ctrl+5: purple).
        keyClick(Qt.Key_5, Qt.ControlModifier);
        compare(t.win.colorName, "purple");
        t.win.setColor("magenta");
        compare(t.win.colorName, "yellow", "an unknown name is the default colour");
    }

    function test_boxesShowWhileKey() {
        const t = makeMemo();
        const close = find(t.win.contentItem, "memoCloseBox");
        const collapse = find(t.win.contentItem, "memoCollapseBox");
        verify(close.visible && collapse.visible);
        compare(close.Accessible.name, "Close");
        compare(collapse.Accessible.name, "Collapse");
        verify(close.x < collapse.x, "close at the left end, collapse at the right end");
    }

    // A Wayland client cannot resize its floating window: a collapse and an expand send the tag again with the size the
    // compositor's rule gives the window (ADR-0051 D-6, placement.lua memo_resize).
    function test_collapseAndExpandSendTheSizeOnTheTag() {
        const t = makeMemo({height: 260, expandedHeight: 260, width: 250});
        t.win.toggleCollapsed();
        tryVerify(() => t.backend.retags.length === 1, 2000, "the tag goes out once the new size is committed");
        compare(t.backend.retags[0], "memo:a!250x" + Tokens.memosStripHeight);
        t.win.toggleCollapsed();
        tryVerify(() => t.backend.retags.length === 2, 2000);
        compare(t.backend.retags[1], "memo:a!250x260");
        compare(MemoLogic.sizedTag("memo:a@5,6!240x18", 250, 260.4), "memo:a@5,6!250x260", "an older size is replaced");
    }

    function test_collapseKeepsTheMemosHeight() {
        const t = makeMemo({height: 260, expandedHeight: 260});
        t.win.toggleCollapsed();
        verify(t.win.collapsed);
        compare(t.win.height, Tokens.memosStripHeight);
        compare(t.win.maximumHeight, Tokens.memosStripHeight);
        compare(t.win.expandedHeight, 260, "the stored height is not the strip's");
        compare(t.backend.lastUpdate("a", "collapsed"), true);
        compare(t.backend.lastUpdate("a", "height"), undefined, "the strip's height is never pushed as the memo's");
        verify(!find(t.win.contentItem, "memoGrip").visible);
        verify(find(t.win.contentItem, "memoCollapsedLine").visible);
        compare(find(t.win.contentItem, "memoCollapseBox").Accessible.name, "Expand");
        const strip = find(t.win.contentItem, "memoStrip");
        tryVerify(() => strip.width > 0 && t.win.contentItem.height === Tokens.memosStripHeight, 2000, "the window is the strip");
        // Collapse again expands it (the strip's double-click calls the same function; QtTest's synthetic double-click
        // carries no TapHandler double-tap, as UnifiedToolbar's tests note).
        keyClick(Qt.Key_C, Qt.ControlModifier | Qt.AltModifier);
        verify(!t.win.collapsed);
        compare(t.win.height, 260);
        tryVerify(() => t.win.contentItem.height === 260, 2000);
        compare(t.backend.lastUpdate("a", "collapsed"), false);
    }

    function test_emptyMemoClosesAtOnce() {
        const t = makeMemo();
        t.win.requestClose();
        compare(t.manager.deleted, ["a"]);
    }

    function test_memoWithTextAsksBeforeDeleting() {
        const t = makeMemo({initialHtml: "<p>milk</p>"});
        compare(t.win.title, "milk");
        const alert = find(t.win.contentItem, "memoDeleteAlert");
        verify(!alert.visible);
        keyClick(Qt.Key_W, Qt.ControlModifier);
        verify(alert.visible);
        compare(t.manager.deleted, []);
        // Escape cancels and keeps the memo.
        keyClick(Qt.Key_Escape);
        verify(!alert.visible);
        compare(t.manager.deleted, []);
        // The close box asks again; Delete deletes.
        mouseClick(find(t.win.contentItem, "memoCloseBox"));
        verify(alert.visible);
        mouseClick(find(t.win.contentItem, "memoConfirmDelete"));
        compare(t.manager.deleted, ["a"]);
    }

    function test_aCompositorCloseKeepsTheMemo() {
        const t = makeMemo({initialHtml: "<p>keep</p>"});
        t.win.close();
        compare(t.manager.closed, ["a"]);
        compare(t.manager.deleted, []);
        compare(t.backend.removed, []);
    }

    function test_translucentAndNoFloatOnTop() {
        const t = makeMemo();
        const body = t.win.contentItem.children[0];
        compare(t.win.paperOpacity, 1);
        keyClick(Qt.Key_T, Qt.ControlModifier | Qt.AltModifier);
        verify(t.win.translucent);
        compare(t.win.paperOpacity, Tokens.memosTranslucentOpacity);
        compare(t.backend.lastUpdate("a", "translucent"), true);
        // Float on Top is not shipped (ADR-0051 D-6): its key does nothing and no tag is sent again.
        keyClick(Qt.Key_F, Qt.ControlModifier | Qt.AltModifier);
        verify(t.win.floating === undefined);
    }

    function test_fontKeysAndPlainPaste() {
        const t = makeMemo({initialHtml: "<p>hello world</p>"});
        const edit = t.win.editor;
        edit.forceActiveFocus();
        edit.select(0, 5);
        keyClick(Qt.Key_B, Qt.ControlModifier);
        keyClick(Qt.Key_I, Qt.ControlModifier);
        keyClick(Qt.Key_U, Qt.ControlModifier);
        keyClick(Qt.Key_Minus, Qt.ControlModifier);
        const calls = t.backend.formatter.calls;
        compare(calls.map(c => c.name), ["bold", "italic", "underline", "size"]);
        compare(calls[0].args[1], 0);
        compare(calls[0].args[2], 5);
        compare(calls[3].args[3], -Tokens.memosTextSizeStep);
        compare(calls[3].args[4], Tokens.memosTextSize);
        // Ctrl+V never reaches the TextEdit's own rich paste: the backend inserts the clipboard's plain text.
        keyClick(Qt.Key_V, Qt.ControlModifier);
        const last = t.backend.formatter.calls[t.backend.formatter.calls.length - 1];
        compare(last.name, "insert");
        compare(last.args[3], "pasted");
    }

    function test_textReachesTheBackend() {
        const t = makeMemo();
        const edit = t.win.editor;
        edit.forceActiveFocus();
        keyClick(Qt.Key_H);
        keyClick(Qt.Key_I);
        tryVerify(() => t.backend.lastUpdate("a", "html") !== undefined, 2000);
        verify(t.backend.lastUpdate("a", "html").indexOf("hi") >= 0);
        compare(t.win.title, "hi");
    }

    // Review of the memos slice (MAJOR): text typed in the last 300 ms was lost on a close, a Quit or SIGTERM.
    function test_aCloseKeepsTextTypedJustBefore() {
        const t = makeMemo();
        t.win.editor.forceActiveFocus();
        keyClick(Qt.Key_Z);
        compare(t.backend.lastUpdate("a", "html"), undefined, "still in the window's short pause");
        t.win.close();
        const html = t.backend.lastUpdate("a", "html");
        verify(html !== undefined && html.indexOf("z") >= 0, "pushed by the close itself");
    }

    function test_deactivationSavesWhatWasTyped() {
        const t = makeMemo({}, true);
        t.win.editor.forceActiveFocus();
        keyClick(Qt.Key_Q);
        const saves = t.backend.asyncSaves;
        const other = otherWindow.createObject(null);
        other.requestActivate();
        tryVerify(() => other.active && !t.win.active, 2000, "another window takes the focus");
        verify(t.backend.asyncSaves > saves, "a memo that loses the focus is written (on the backend's worker: save(), not saveNow())");
        const html = t.backend.lastUpdate("a", "html");
        verify(html !== undefined && html.indexOf("q") >= 0);
        other.destroy();
        t.win.deleting = true;
        t.win.destroy();
    }

    function test_resizeIsStored() {
        const t = makeMemo();
        t.win.width = 300;
        t.win.height = 250;
        // The platform reports the new size on its own turn.
        tryVerify(() => t.backend.lastUpdate("a", "width") === 300 && t.backend.lastUpdate("a", "height") === 250, 2000);
        verify(t.backend.updates.every(u => u.id === "a"), "nothing is pushed before the memo knows its id");
        compare(t.win.expandedHeight, 250);
    }

    // ---- Main.qml ----

    function makeMain(stored) {
        const backend = fakeBackend.createObject(testCase);
        backend.stored = stored;
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/memos/qml/Main.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const main = createTemporaryObject(comp, testCase, {backend: backend, globalMenu: false});
        verify(main);
        return {backend: backend, main: main};
    }

    function cleanupMain(m) {
        const ws = m.main.windows.slice();
        for (let i = 0; i < ws.length; i++) {
            ws[i].deleting = true;
            ws[i].destroy();
        }
    }

    function test_mainOpensTheStoredMemos() {
        const m = makeMain([{id: "a", color: "green", html: "<p>one</p>", width: 250, height: 210, collapsed: false, translucent: false},
                            {id: "b", color: "pink", html: "", width: 200, height: 300, collapsed: true, translucent: true}]);
        compare(m.main.windows.length, 2);
        const a = m.main.windows[0], b = m.main.windows[1];
        compare(a.colorName, "green");
        compare(a.width, 250);
        compare(a.height, 210);
        compare(a.gfChromeRole, "memo:a");
        verify(b.collapsed);
        compare(b.height, Tokens.memosStripHeight);
        compare(b.expandedHeight, 300);
        verify(b.translucent);
        cleanupMain(m);
    }

    function test_mainOpensANewMemoWhenThereIsNone() {
        const m = makeMain([]);
        compare(m.main.windows.length, 1);
        compare(m.backend.created, 1);
        compare(m.main.windows[0].colorName, "yellow");
        compare(m.main.windows[0].width, Tokens.memosWindowWidth);
        cleanupMain(m);
    }

    function test_mainReopensWhatTheCompositorClosed() {
        const m = makeMain([{id: "a", color: "yellow", html: "<p>x</p>", width: 240, height: 200, collapsed: false, translucent: false},
                            {id: "b", color: "blue", html: "<p>y</p>", width: 240, height: 200, collapsed: false, translucent: false}]);
        m.main.windowClosed(m.main.windows[0]);
        compare(m.main.windows.length, 1);
        compare(m.backend.removed, [], "the memo is kept");
        m.main.activate();
        compare(m.main.windows.length, 2);
        compare(m.main.windows.map(w => w.memoId).sort(), ["a", "b"]);
        // New Memo near the front one.
        m.main.newMemo();
        compare(m.main.windows.length, 3);
        cleanupMain(m);
    }

    // Quit and SIGTERM save through backend.saveNow(): every window pushes what it holds first.
    function test_mainFlushesEveryWindowBeforeASave() {
        const m = makeMain([{id: "a", color: "yellow", html: "", width: 240, height: 200, collapsed: false, translucent: false},
                            {id: "b", color: "blue", html: "", width: 240, height: 200, collapsed: false, translucent: false}]);
        m.main.windows[0].editor.insert(0, "first");
        m.main.windows[1].editor.insert(0, "second");
        compare(m.backend.lastUpdate("a", "html"), undefined);
        m.backend.saveNow();
        verify(String(m.backend.lastUpdate("a", "html")).indexOf("first") >= 0);
        verify(String(m.backend.lastUpdate("b", "html")).indexOf("second") >= 0);
        // A window the compositor closes pushes its text before it is destroyed.
        m.main.windows[1].editor.insert(0, "more ");
        m.main.windows[1].close();
        compare(m.main.windows.length, 1);
        verify(String(m.backend.lastUpdate("b", "html")).indexOf("more second") >= 0);
        cleanupMain(m);
    }

    function test_mainRefusesANewerStore() {
        const m = makeMain([{id: "a", color: "yellow", html: "", width: 240, height: 200, collapsed: false, translucent: false}]);
        cleanupMain(m);
        testCase.refusingBackend = fakeBackend.createObject(testCase, {refusal: "newer"});
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/memos/qml/Main.qml"));
        const main = createTemporaryObject(comp, testCase, {backend: testCase.refusingBackend, globalMenu: false});
        compare(main.windows.length, 0);
        verify(main.refusalWindow);
        compare(testCase.refusingBackend.created, 0);
        verify(main.newMemo() === null);
        main.refusalWindow.destroy();
    }

    // ---- 2026-11 audit, round 2 ----

    // M3: the first line comes from the live document's plain text (no HTML written and parsed again for it).
    function test_logicFirstLine() {
        compare(MemoLogic.firstLine(""), "");
        compare(MemoLogic.firstLine("     Groceries  milk"), "Groceries");
        compare(MemoLogic.firstLine("a b"), "a");
        compare(MemoLogic.firstLine("\n\r\n x \n"), "x");
        compare(MemoLogic.firstLine("￼ Second"), "Second", "an object placeholder alone is not a line");
        compare(MemoLogic.firstLine(undefined), "");
    }

    function test_firstLineFromTheLiveDocument() {
        const t = makeMemo({initialHtml: "<p></p><p>  <b>Shopping</b> list</p><p>eggs</p>"});
        compare(t.win.firstLine, "Shopping list");
        // The fake backend has no firstLine(html) any more: a window that asked it would throw.
        t.win.editor.insert(0, "nb");
        tryVerify(() => t.win.firstLine === "nbShopping list", 2000, "first line: " + t.win.firstLine);
        verify(String(t.backend.lastUpdate("a", "html")).indexOf("nb") >= 0);
        compare(t.win.title, "nbShopping list");
    }

    // M3: a collapse waits for the frames the backend reads on its worker, then sends the corner it read.
    function test_collapseWaitsForTheFrames() {
        const t = makeMemo({height: 260, expandedHeight: 260, width: 250});
        t.backend.deferFrames = true;
        t.win.toggleCollapsed();
        compare(t.backend.frameReads, 1);
        verify(!t.win.collapsed, "not before the frames are in");
        t.win.toggleCollapsed(); // changed its mind before they came: nothing to do once they are in
        t.win.toggleCollapsed(); // and back: a collapse is waiting again
        t.backend.memos[0].id = "a";
        t.backend.emitFrames();
        verify(t.win.collapsed);
        compare(t.win.height, Tokens.memosStripHeight);
        tryVerify(() => t.backend.retags.length === 1, 2000);
        compare(t.backend.retags[0], "memo:a!250x" + Tokens.memosStripHeight);
    }

    // M1: a write that fails is said in every memo, until one passes.
    function test_unsavedBandWhileTheWriteFails() {
        const t = makeMemo();
        const band = find(t.win.contentItem, "memoUnsavedBand");
        verify(band);
        verify(!band.visible);
        t.backend.saveError = "The disk is full.";
        verify(band.visible);
        compare(find(t.win.contentItem, "memoUnsavedText").text, "Not saved: The disk is full.");
        t.win.toggleCollapsed();
        verify(t.win.collapsed);
        verify(!band.visible, "collapsed, the strip says it");
        compare(find(t.win.contentItem, "memoCollapsedLine").text, "Not saved");
        t.win.toggleCollapsed();
        t.backend.saveError = "";
        verify(!band.visible);
    }

    // M1: Quit waits while the memos cannot be written; the front memo asks; a write that passes lets it go on.
    function test_quitWaitsForAWriteThatPasses() {
        const m = makeMain([{id: "a", color: "yellow", html: "<p>x</p>", width: 240, height: 200, collapsed: false, translucent: false},
                            {id: "b", color: "blue", html: "<p>y</p>", width: 240, height: 200, collapsed: false, translucent: false}]);
        m.backend.saveResult = false;
        m.backend.saveError = "The disk is full.";
        m.main.requestQuit();
        compare(m.backend.quits, 0, "no quit while the write fails");
        const front = m.main.windows[1];
        compare(m.main.quitAlertWindow, front);
        verify(front.confirmingQuit);
        const alert = find(front.contentItem, "memoQuitAlert");
        verify(alert && alert.visible);
        compare(find(front.contentItem, "memoQuitReason").text, "The disk is full.");
        // Cancel: the app stays.
        mouseClick(find(front.contentItem, "memoCancelQuit"));
        compare(m.main.quitAlertWindow, null);
        verify(!alert.visible);
        compare(m.backend.quits, 0);
        // Again; then the backend's retry passes: Quit goes on by itself.
        m.main.requestQuit();
        verify(front.confirmingQuit);
        m.backend.saveResult = true;
        m.backend.saveError = "";
        m.backend.saved(true);
        compare(m.backend.quits, 1);
        cleanupMain(m);
    }

    function test_quitAnywayLeavesAndTheCompositorsCloseComesBack() {
        const m = makeMain([{id: "a", color: "yellow", html: "<p>x</p>", width: 240, height: 200, collapsed: false, translucent: false}]);
        m.backend.saveResult = false;
        // The Dock's Quit closes every window: they come back, with the alert, while the write fails.
        m.main.windowClosed(m.main.windows[0]);
        compare(m.backend.quits, 0);
        compare(m.main.windows.length, 1, "the memo is shown again");
        verify(m.main.windows[0].confirmingQuit);
        mouseClick(find(m.main.windows[0].contentItem, "memoQuitAnyway"));
        compare(m.backend.quits, 1);
        cleanupMain(m);
    }

    function test_deletingTheLastMemoQuitsEvenUnsaved() {
        // Only the deletion itself would be lost: no alert.
        const m = makeMain([{id: "a", color: "yellow", html: "", width: 240, height: 200, collapsed: false, translucent: false}]);
        m.backend.saveResult = false;
        m.main.deleteMemo(m.main.windows[0]);
        compare(m.backend.quits, 1);
    }

    // M3: New Memo near a memo waits for the frames (where the front memo is now); with none it opens at once.
    function test_newMemoWaitsForTheFrames() {
        const m = makeMain([{id: "a", color: "yellow", html: "", width: 240, height: 200, collapsed: false, translucent: false}]);
        m.backend.deferFrames = true;
        verify(m.main.newMemo() === null);
        m.main.newMemo();
        compare(m.main.windows.length, 1, "not before the frames are in");
        m.backend.emitFrames();
        compare(m.main.windows.length, 3, "both wait and open");
        compare(m.backend.created, 2);
        cleanupMain(m);
    }
}
