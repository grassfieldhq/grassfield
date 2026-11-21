pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "MemoLogic.js" as MemoLogic

// Grassfield Memos (ADR-0051): one window per memo. At start the stored memos open (a new one when there are none); New Memo
// opens one near the front memo; the last memo deleted, or every memo window closed by the compositor, quits (the memos are
// kept). A store this build may not write (a newer schema, an I/O error) opens no memo, only the alert that says so.
QtObject {
    id: root

    // Set by the launcher (src/main.cpp): a MemosApp.
    required property var backend
    // The registrar is there (kept up to date by src/main.cpp): each memo exports its menus to the global menu bar.
    required property bool globalMenu

    // The open memo windows, oldest first.
    property var windows: []
    // The memo the user worked in last (New Memo opens near it).
    property var lastActive: null
    property var refusalWindow: null
    // Quit waits for a write that passes (M1 of the 2026-11 audit): the memo that holds the alert, null when none.
    property var quitAlertWindow: null
    // New Memo near the front memo waits for the frames the backend reads on its worker: how many are waiting, and the
    // front memo's id when they were asked for.
    property int newMemosWaiting: 0
    property string newMemoFront: ""

    property Theme theme: Theme {
        backend: root.backend
    }

    // Every save (Quit, SIGTERM, a memo left, the debounce) first takes the text each window still holds: the backend asks,
    // the windows push, synchronously, before it writes.
    property Connections saves: Connections {
        target: root.backend
        function onAboutToSave(): void {
            root.flushAll();
        }
        // A write passed while Quit waited for one: Quit goes on.
        function onSaved(ok: bool): void {
            if (ok && root.quitAlertWindow)
                root.requestQuit();
        }
        function onFramesRead(): void {
            const n = root.newMemosWaiting;
            root.newMemosWaiting = 0;
            for (let i = 0; i < n; i++)
                root.createNear(root.newMemoFront);
        }
    }

    function flushAll(): void {
        for (let i = 0; i < root.windows.length; i++)
            root.windows[i].flush();
    }

    property Component memoComponent: Component {
        MemoWindow {}
    }

    property Component refusalComponent: Component {
        RefusalWindow {}
    }

    function openMemo(m: var): var {
        const w = root.memoComponent.createObject(root, {
            backend: root.backend,
            manager: root,
            memoId: m.id,
            colorName: m.color,
            initialHtml: m.html,
            collapsed: m.collapsed,
            translucent: m.translucent,
            expandedHeight: m.height,
            width: m.width,
            height: MemoLogic.windowHeight(m.collapsed, m.height, Tokens.memosStripHeight, Tokens.memosWindowMinHeight),
            gfChromeRole: m.tag,
            globalMenu: Qt.binding(() => root.globalMenu)
        });
        if (!w) {
            console.warn("grassfield-memos: cannot create a memo window:", root.memoComponent.errorString());
            return null;
        }
        root.windows = root.windows.concat([w]);
        return w;
    }

    // With a memo open, the new one waits for the frames (where the front memo is now, read on the backend's worker) and
    // opens when they are in (null is returned); with none, it opens at once.
    function newMemo(): var {
        if (root.backend.refusal !== "")
            return null;
        const front = MemoLogic.frontMemo(root.windows, root.lastActive);
        if (!front)
            return root.createNear("");
        root.newMemoFront = front.memoId;
        root.newMemosWaiting++;
        root.backend.refreshFrames();
        return null;
    }

    function createNear(frontId: string): var {
        const m = root.backend.createMemo(frontId, Tokens.memosWindowWidth, Tokens.memosWindowHeight, Tokens.memosCascadeStep);
        if (!m.id)
            return null;
        const w = root.openMemo(m);
        if (w)
            w.requestActivate();
        return w;
    }

    function forget(w: var): void {
        root.windows = root.windows.filter(x => x !== w);
        if (root.lastActive === w)
            root.lastActive = null;
        if (root.quitAlertWindow === w)
            root.quitAlertWindow = null;
    }

    function quitWhenEmpty(): void {
        if (root.windows.length > 0)
            return;
        root.requestQuit();
    }

    // Quit (Ctrl+Q, the last memo closed): every change is written first, and the app stays while that fails. The memos come
    // back if the compositor had closed them, and the front one asks: Cancel (the backend keeps trying; each memo says "Not
    // saved") or Quit Anyway. With no memo left only deletions would be lost: it quits.
    function requestQuit(): void {
        // Cleared before the write: saveNow() reports saved(true) synchronously, and onSaved must not come back here.
        root.quitAlertWindow = null;
        if (root.backend.saveNow() || root.backend.count() === 0) {
            root.backend.quit();
            return;
        }
        if (root.windows.length === 0)
            root.reopenStored();
        const front = MemoLogic.frontMemo(root.windows, root.lastActive);
        if (!front) {
            root.backend.quit();
            return;
        }
        if (front.collapsed)
            front.setCollapsed(false);
        root.quitAlertWindow = front;
        front.raise();
        front.requestActivate();
    }

    function cancelQuit(): void {
        const w = root.quitAlertWindow;
        root.quitAlertWindow = null;
        if (w)
            w.editor.forceActiveFocus();
    }

    function quitAnyway(): void {
        root.quitAlertWindow = null;
        root.backend.quit();
    }

    // Every stored memo without a window gets one again.
    function reopenStored(): void {
        const open = root.windows.map(w => w.memoId);
        const stored = root.backend.current();
        for (let i = 0; i < stored.length; i++) {
            if (open.indexOf(stored[i].id) < 0)
                root.openMemo(stored[i]);
        }
    }

    // Close box, Ctrl+W, File > Close (after the alert for a memo with text): the memo is deleted.
    function deleteMemo(w: var): void {
        root.backend.remove(w.memoId);
        root.forget(w);
        w.deleting = true;
        w.close();
        w.destroy();
        root.quitWhenEmpty();
    }

    // The compositor closed a memo's window (Quit from the Dock or the app menu closes them all): the memo is kept.
    function windowClosed(w: var): void {
        root.forget(w);
        w.destroy();
        root.quitWhenEmpty();
    }

    // A second launch (src/main.cpp, MemosInstance): the memos come forward, those the compositor closed open again, and a
    // new memo opens when there is none.
    function activate(): void {
        if (root.refusalWindow) {
            root.refusalWindow.raise();
            root.refusalWindow.requestActivate();
            return;
        }
        root.reopenStored();
        if (root.windows.length === 0) {
            root.newMemo();
            return;
        }
        for (let i = 0; i < root.windows.length; i++)
            root.windows[i].raise();
        const front = MemoLogic.frontMemo(root.windows, root.lastActive);
        front.raise();
        front.requestActivate();
    }

    Component.onCompleted: {
        const stored = root.backend.open(Tokens.memosWindowWidth, Tokens.memosWindowHeight);
        if (root.backend.refusal !== "") {
            root.refusalWindow = root.refusalComponent.createObject(root, {reason: root.backend.refusal});
            return;
        }
        for (let i = 0; i < stored.length; i++)
            root.openMemo(stored[i]);
        // macOS: launching the app with no note opens a new one.
        if (root.windows.length === 0)
            root.newMemo();
    }
}
