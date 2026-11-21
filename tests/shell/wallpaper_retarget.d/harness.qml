pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.desktop

// The real wallpaper (shell/desktop/Wallpaper.qml, staged by tests/shell/wallpaper_retarget.sh with a PanelWindow stand-in),
// offscreen: a change that arrives during a crossfade (audit, wallpaper fade jump) and the slow phase fade.
//   1. A -> B starts a fade; C arrives in the middle of it: the B fade goes on underneath from where it was (no slot's opacity
//      jumps on any frame), C fades in over it, and C ends alone on screen.
//   2. A -> B, then A again in the middle: the fade runs back from where it is to nothing, and A stays on screen.
//   3. A phase change fades in steps (a few opacity changes a second), not at every frame, and still ends on screen.
// Prints "wallpaper-retarget: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property var win: null
    property int step: 0
    property var samples: []
    property bool done: false

    function check(name: string, ok: bool): void {
        if (!ok)
            root.failures.push(name);
    }

    Wallpaper {
        id: wallpaper
    }

    function windowOf(): var {
        return wallpaper.windows.length > 0 ? wallpaper.windows[0] : null;
    }

    function color(c: string): var {
        return {kind: "color", color: c, url: "", strip: null, video: ""};
    }

    function finish(): void {
        if (root.done)
            return;
        root.done = true;
        console.log(root.failures.length === 0 ? "wallpaper-retarget: PASS" : "wallpaper-retarget: FAIL " + root.failures.join("; "));
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

    // The largest change of what is seen (a colour channel, 0..1) between two frames.
    function worstJump(): real {
        let worst = 0;
        for (let i = 1; i < root.samples.length; i++) {
            for (let k = 0; k < 3; k++)
                worst = Math.max(worst, Math.abs(root.samples[i].seen[k] - root.samples[i - 1].seen[k]));
        }
        return worst;
    }

    FrameAnimation {
        id: sampler
        onTriggered: {
            const w = root.win;
            const slots = w.contentItem.children.filter(c => c.pictureReady !== undefined);
            // What is seen: the slots blended bottom to top (each a colour here).
            const seen = [0, 0, 0];
            for (const sl of slots.slice().sort((x, y) => x.z - y.z)) {
                if (!sl.visible || sl.kind !== "color")
                    continue;
                const c = Qt.color(sl.color);
                seen[0] = seen[0] * (1 - sl.opacity) + c.r * sl.opacity;
                seen[1] = seen[1] * (1 - sl.opacity) + c.g * sl.opacity;
                seen[2] = seen[2] * (1 - sl.opacity) + c.b * sl.opacity;
            }
            root.samples.push({a: slots[0].opacity, b: slots[1].opacity, c: slots[2].opacity, seen: seen, t: Date.now()});
        }
    }

    Timer {
        id: driver
        interval: 50
        repeat: true
        running: true
        property real at: 0
        onTriggered: {
            const w = root.win;
            if (root.step === 0) {
                root.win = root.windowOf();
                if (!root.win || !root.win.firstReady)
                    return;
                wallpaper.fadeLengthMs = 1200;
                root.win.show(root.color("#102030"), "cut");
                root.step = 1;
                return;
            }
            if (root.step === 1) {
                // Test 1: A -> B, C in the middle.
                root.check("A on screen", w.incoming === null && w.shownDesc.color === "#102030");
                root.samples = [];
                sampler.running = true;
                w.show(root.color("#204060"), "normal");
                at = Date.now();
                root.step = 2;
                return;
            }
            if (root.step === 2) {
                if (Date.now() - at < 500)
                    return;
                const b = w.incoming;
                const before = b.opacity;
                w.show(root.color("#306090"), "normal");
                root.check("B goes on underneath (" + before.toFixed(2) + " -> " + b.opacity.toFixed(2) + ")", w.under === b && Math.abs(b.opacity - before) < 0.05 && before > 0.1 && before < 0.9);
                root.check("C fades in over it", w.incoming !== null && w.incoming !== b && w.incoming.opacity < 0.05 && w.incoming.z > b.z);
                root.step = 3;
                return;
            }
            if (root.step === 3) {
                if (w.incoming !== null || w.under !== null)
                    return;
                sampler.running = false;
                const jump = root.worstJump();
                root.check("no jump during the retarget (largest step " + jump.toFixed(3) + ")", jump < 0.05);
                root.check("C on screen", w.shownDesc.color === "#306090" && w.shown.opacity === 1);
                // Test 2: A -> B, A again.
                w.show(root.color("#102030"), "cut");
                root.samples = [];
                sampler.running = true;
                w.show(root.color("#405060"), "normal");
                at = Date.now();
                root.step = 4;
                return;
            }
            if (root.step === 4) {
                if (Date.now() - at < 600)
                    return;
                const b = w.incoming;
                const before = b.opacity;
                w.show(root.color("#102030"), "normal");
                root.check("the fade turns back from where it is", w.incoming === b && Math.abs(b.opacity - before) < 0.05 && before > 0.1);
                root.step = 5;
                return;
            }
            if (root.step === 5) {
                if (w.incoming !== null)
                    return;
                sampler.running = false;
                const jump = root.worstJump();
                root.check("no jump when the fade turns back (largest step " + jump.toFixed(3) + ")", jump < 0.05);
                root.check("A stays on screen", w.shownDesc.color === "#102030" && w.shown.opacity === 1);
                // Test 3: a phase fade, in steps.
                wallpaper.fadeLengthMs = 2000;
                root.samples = [];
                sampler.running = true;
                w.show(root.color("#506070"), "phase");
                at = Date.now();
                root.step = 6;
                return;
            }
            if (root.step === 6) {
                if (w.incoming !== null)
                    return;
                sampler.running = false;
                let changes = 0;
                for (let i = 1; i < root.samples.length; i++) {
                    const p = root.samples[i - 1], q = root.samples[i];
                    if (p.a !== q.a || p.b !== q.b || p.c !== q.c)
                        changes++;
                }
                const seconds = (Date.now() - at) / 1000;
                root.check("the phase fade changes the opacity a few times a second (" + changes + " changes in " + root.samples.length + " frames, " + seconds.toFixed(1) + " s)", changes <= seconds * 12 + 2 && changes < root.samples.length / 2);
                root.check("the phase wallpaper on screen", w.shownDesc.color === "#506070" && w.shown.opacity === 1);
                root.finish();
            }
        }
    }
}
