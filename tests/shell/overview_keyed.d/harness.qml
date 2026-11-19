pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.overview

// TestWins is the harness's own singleton, staged into the overview module (overview/TestWins.qml); qmllint reads the shipped module.
// qmllint disable unqualified

// The real Overview (shell/overview, staged by tests/shell/overview_keyed.sh with a PanelWindow stand-in and the windows of the
// active workspace given by the harness), offscreen, in thumbnail mode (no compositor plugin):
//   - A-11: while the overview zooms open, a thumbnail's offscreen layers keep one size (the zoom is a scale);
//   - A-06: a window that opens while the overview is open adds its own item only: the other windows keep their items (the same
//     objects), glide to their new places (their rectangles pass through values between the old and the new), and a drag in
//     progress on another window survives it; a window that closes takes only its own item.
// Prints "overview-keyed: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property int step: 0
    property var win: null
    property var before: ({})
    property var trace: []
    property var layerSizes: []
    property real startA: 0
    property bool done: false

    function check(name: string, ok: bool): void {
        if (!ok)
            root.failures.push(name);
    }

    function w(addr: string, x: real, y: real): var {
        return {address: addr, x: x, y: y + 30, w: 640, h: 400, title: "Window " + addr, appId: "test." + addr, toplevel: null, workspaceId: 1, floating: true, fullscreen: false};
    }

    Overview {
        id: ov
    }

    function find(item: Item, test: var, out: var): var {
        for (const c of item.children) {
            if (test(c))
                out.push(c);
            root.find(c, test, out);
        }
        return out;
    }
    function thumbs(): var {
        const out = {};
        for (const t of root.find(root.win.contentItem, c => c.key !== undefined && c.tx !== undefined && c.realX !== undefined, []))
            out[t.key] = t;
        return out;
    }

    function finish(): void {
        if (root.done)
            return;
        root.done = true;
        console.log(root.failures.length === 0 ? "overview-keyed: PASS" : "overview-keyed: FAIL " + root.failures.join("; "));
        Qt.quit();
    }

    Timer {
        interval: 60000
        running: true
        onTriggered: {
            root.check("finished in time (step " + root.step + ")", false);
            root.finish();
        }
    }

    FrameAnimation {
        id: sampler
        onTriggered: {
            const t = root.thumbs();
            if (root.step === 2 && t.A) {
                const layers = root.find(t.A, c => c.objectName === "thumbContent", []);
                if (layers.length > 0)
                    root.layerSizes.push(layers[0].width + "x" + layers[0].height + " at " + t.A.width.toFixed(1));
            }
            if (root.step === 4 && t.A)
                root.trace.push(t.A.tx);
        }
    }

    Timer {
        interval: 50
        repeat: true
        running: true
        property real at: 0
        onTriggered: {
            if (root.step === 0) {
                TestWins.list = [root.w("A", 100, 100), root.w("B", 900, 100), root.w("C", 500, 500)];
                sampler.running = true;
                ov.show();
                root.step = 1;
                return;
            }
            if (root.step === 1) {
                root.win = ov.windowOf("A");
                if (!root.win)
                    return;
                root.step = 2;
                return;
            }
            if (root.step === 2) {
                if (root.win.progress < 1)
                    return;
                const sizes = new Set(root.layerSizes.map(s => s.split(" ")[0]));
                const drawn = new Set(root.layerSizes.map(s => s.split(" at ")[1]));
                root.check("the zoom ran (" + drawn.size + " sizes drawn)", drawn.size >= 3);
                root.check("one layer size through the zoom (" + [...sizes].join(", ") + ")", sizes.size === 1);
                const t = root.thumbs();
                root.check("three window items", Object.keys(t).length === 3);
                root.before = t;
                root.startA = t.A.tx;
                // A drag in progress on B, then D opens.
                root.win.dragKey = "B";
                root.trace = [];
                TestWins.list = TestWins.list.concat([root.w("D", 300, 600)]);
                root.step = 4;
                at = Date.now();
                return;
            }
            if (root.step === 4) {
                if (Date.now() - at < 800)
                    return;
                const t = root.thumbs();
                root.check("four window items", Object.keys(t).length === 4);
                root.check("A, B and C keep their items", t.A === root.before.A && t.B === root.before.B && t.C === root.before.C);
                root.check("the drag on B survives a window opening", root.win.dragKey === "B");
                const from = root.startA, to = t.A.tx;
                const between = root.trace.filter(v => Math.abs(v - from) > 0.5 && Math.abs(v - to) > 0.5);
                root.check("A glides to its new place (" + from.toFixed(0) + " -> " + to.toFixed(0) + ", " + between.length + " frames between)", Math.abs(to - from) > 1 && between.length >= 2);
                // C closes.
                TestWins.list = TestWins.list.filter(x => x.address !== "C");
                root.step = 5;
                at = Date.now();
                return;
            }
            if (root.step === 5) {
                if (Date.now() - at < 300)
                    return;
                const t = root.thumbs();
                root.check("C's item goes, the others stay", !t.C && t.A === root.before.A && t.B === root.before.B && Object.keys(t).length === 3);
                root.check("the drag on B survives a window closing", root.win.dragKey === "B");
                TestWins.list = TestWins.list.filter(x => x.address !== "B");
                root.step = 6;
                at = Date.now();
                return;
            }
            if (root.step === 6) {
                if (Date.now() - at < 300)
                    return;
                root.check("the drag ends with its window", root.win.dragKey === "");
                root.finish();
            }
        }
    }
}
