pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.notifications

// The REAL banner stack (shell/notifications/BannerStack.qml, the content of the banner window) on the real Notifications
// singleton (scripts/dev/test.sh: `qs -p tests/shell/banner_stack`, offscreen, a dev session without the D-Bus server; see
// the dev-session marker file), in a plain window: the PanelWindow needs a Wayland compositor.
//  A. B-11: a sixth banner pushes the oldest shown one back into the queue; that one leaves as a dismissed banner does (its
//     slot stays shown while it fades and closes) instead of vanishing in the frame the newer one arrives; then its slot is
//     an empty queued one; it comes back (the newer one dismissed) and slides in again.
//  B. B-02: while a banner arrives and the slots open, the area every banner's glass is judged over (backdropRect) does not
//     change on every frame: it takes the stack's height at rest at once.
//  C. Flood: 300 notifications in one go leave at most Notifications.bannerQueueMax banners in the queue (a critical one
//     stays), the stack's rows follow the model's order by key, and the stack's pass stays cheap.
// Prints "banner-stack: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property int seq: 0
    property string phase: "start"
    property int frames: 0
    property var heights: ({})
    property var demotedOpacities: []
    property string demotedKey: ""
    property string critical: ""
    property real floodMs: 0

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function post(urgency: int): string {
        seq++;
        const key = "b-" + seq;
        Notifications.showBanner({key: key, nid: -1, appName: "App" + (seq % 3), appIcon: "", image: "", summary: "Banner " + seq, bodyHtml: "", time: Date.now(), urgency: urgency, actions: []}, 0);
        return key;
    }

    // The slot of `key` (a live one), or null.
    function slotOf(key: string): var {
        const col = stack.column;
        for (let i = 0; i < col.children.length; i++) {
            const s = col.children[i];
            if (s.key === key && !s.gone)
                return s;
        }
        return null;
    }

    function liveKeys(): var {
        const out = [];
        for (let i = 0; i < stack.rowModel.count; i++) {
            const r = stack.rowModel.get(i);
            if (!r.gone)
                out.push(r.key);
        }
        return out;
    }

    function modelKeys(): var {
        const out = [];
        for (let i = 0; i < Notifications.bannerModel.count; i++)
            out.push(Notifications.bannerModel.get(i).key);
        return out;
    }

    // The backdrop height a shown banner's glass is judged over.
    function judgedHeight(): real {
        const col = stack.column;
        for (let i = 0; i < col.children.length; i++) {
            const s = col.children[i];
            if (s.card)
                return s.card.parent.backdropRect.height;
        }
        return -1;
    }

    Window {
        id: win
        visible: true
        width: 500
        height: 1200

        BannerStack {
            id: stack
            anchors.fill: parent
            screenWidth: 1920
        }
    }

    // One step per frame-ish tick: the stack animates on its own; the checks sample it.
    Timer {
        id: tick
        interval: 16
        repeat: true
        running: true
        onTriggered: root.step()
    }

    function step(): void {
        frames++;
        if (phase === "start") {
            for (let i = 0; i < Tokens.notificationBannerMaxVisible; i++)
                post(1);
            phase = "settle";
            frames = 0;
        } else if (phase === "settle" && frames > 60) {
            check("A: five banners shown", liveKeys().length === Tokens.notificationBannerMaxVisible && stack.rowModel.count === Tokens.notificationBannerMaxVisible);
            demotedKey = modelKeys()[Tokens.notificationBannerMaxVisible - 1];
            post(1);
            phase = "demote";
            frames = 0;
            heights = {};
        } else if (phase === "demote") {
            const s = slotOf(demotedKey);
            heights[judgedHeight()] = true;
            if (frames === 1) {
                check("A: the demoted banner's slot is still shown in the frame the new one arrives", s !== null && s.shown && s.height > 0);
                check("A: it is leaving (no input, no timer hold)", s !== null && s.leaving);
            }
            if (s !== null && s.shown)
                demotedOpacities.push(s.opacity);
            if (frames > 60) {
                const o = demotedOpacities;
                check("A: it fades out over several frames (" + o.length + " frames)", o.length >= 3 && o[o.length - 1] < o[0]);
                check("A: then its slot is an empty queued one", s !== null && !s.shown && s.height === 0 && s.queued && !s.demoting);
                check("B: the glass is judged over the stack at rest, not each frame of the opening (" + Object.keys(heights).length + " heights)", Object.keys(heights).length <= 3);
                check("B: the rest height is the five shown banners", stack.restHeight > 0 && Math.abs(judgedHeight() - stack.restHeight) < 0.5);
                // The newest goes: the demoted one comes back and slides in again.
                Notifications.expireBanner(modelKeys()[0]);
                phase = "back";
                frames = 0;
            }
        } else if (phase === "back" && frames > 60) {
            const s = slotOf(demotedKey);
            check("A: back from the queue it is shown again, whole", s !== null && s.shown && !s.queued && s.opacity === 1 && s.height > 0 && s.slide === 0);
            phase = "flood";
            frames = 0;
        } else if (phase === "flood") {
            root.critical = post(2);
            const t0 = Date.now();
            for (let i = 0; i < 300; i++)
                post(1);
            root.floodMs = Date.now() - t0;
            check("C: the stack waits for the end of the burst (one pass, not one per arrival)", stack.rowModel.count <= Notifications.bannerQueueMax + 2 * Tokens.notificationBannerMaxVisible + 1);
            phase = "flooded";
            frames = 0;
        } else if (phase === "flooded") {
            const t0 = Date.now();
            stack.sync();
            const ms = root.floodMs + Date.now() - t0;
            check("C: the queue is bounded (" + Notifications.bannerCount + ")", Notifications.bannerCount <= Notifications.bannerQueueMax);
            check("C: the critical banner stays in the queue", modelKeys().indexOf(root.critical) >= 0);
            check("C: 300 arrivals take " + ms + " ms (limit 3000)", ms < 3000);
            check("C: the stack's rows follow the model by key", JSON.stringify(liveKeys()) === JSON.stringify(modelKeys()));
            check("C: no more rows than the queue and the leaving ones (" + stack.rowModel.count + ")", stack.rowModel.count <= Notifications.bannerQueueMax + Tokens.notificationBannerMaxVisible);
            phase = "random";
            frames = 0;
        } else if (phase === "random") {
            // Arrivals and expiries in a seeded order: the rows always follow the model.
            let seed = 11;
            const rnd = n => {
                seed = (seed * 1103515245 + 12345) & 0x7fffffff;
                return seed % n;
            };
            let bad = 0;
            for (let i = 0; i < 400; i++) {
                const keys = modelKeys();
                if (keys.length > 0 && rnd(3) === 0)
                    Notifications.expireBanner(keys[rnd(keys.length)]);
                else
                    post(rnd(10) === 0 ? 2 : 1);
                stack.sync();
                if (JSON.stringify(liveKeys()) !== JSON.stringify(modelKeys()))
                    bad++;
            }
            check("C: rows follow the model through 400 random steps (" + bad + " mismatches)", bad === 0);
            phase = "done";
            tick.running = false;
            if (failures.length === 0)
                console.log("banner-stack: PASS");
            else
                console.log("banner-stack: FAIL " + failures.join("; "));
            Qt.quit();
        }
    }
}
