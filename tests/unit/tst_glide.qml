import QtQuick
import QtTest
import Grassfield.Ui

// Glide (audit B-17): the offset a list gives an item the layout moved, gliding back to 0. The Notifications column restarted
// a bezier from rest on every layout change, so with arrivals faster than the motion the cards below stalled (velocity 0) and
// set off again. Glide is a critically damped spring stepped exactly per frame:
// - from rest it settles at 0 within about its duration, without overshoot, and ends exactly at 0, at rest;
// - a displacement on the way keeps the velocity it had (no stall), and the motion stays monotonic toward the place;
// - duration 0 (Reduce Motion) is at its place at once; the step is exact for any frame time (one long frame never
//   overshoots).
// The column's wiring (NotificationList's cards use it) is checked on its source.
TestCase {
    id: tc

    name: "Glide"
    when: windowShown

    Glide {
        id: glide
        duration: 220
    }

    // Steps the spring by hand (its frame handler's arithmetic, at a fixed frame time) through `frames` frames.
    function stepFrames(g, frames, dt) {
        const out = [];
        for (let i = 0; i < frames; i++) {
            const c = g.velocity + g.omega * g.value;
            const e = Math.exp(-g.omega * dt);
            const x = (g.value + c * dt) * e;
            const v = (g.velocity - g.omega * c * dt) * e;
            g.value = x;
            g.velocity = v;
            out.push({x: x, v: v});
        }
        return out;
    }

    function init() {
        glide.settle();
        glide.duration = 220;
    }

    function test_settlesFromRest() {
        glide.displace(100);
        verify(glide.running);
        tryVerify(() => !glide.running && glide.value === 0 && glide.velocity === 0, 2000, "at its place, at rest, exactly");
    }

    function test_noOvershootAndOnTime() {
        glide.stop();
        glide.value = 100;
        glide.velocity = 0;
        const path = stepFrames(glide, 30, 1 / 120);  // 250 ms at 120 Hz
        for (const p of path)
            verify(p.x >= 0, "never past its place: " + p.x);
        verify(path[path.length - 1].x < 1, "within 1 % after its duration and a frame or so: " + path[path.length - 1].x);
        glide.settle();
    }

    function test_aSecondMoveKeepsTheSpeed() {
        glide.stop();
        glide.value = 60;
        glide.velocity = 0;
        stepFrames(glide, 6, 1 / 60);
        const before = glide.velocity;
        verify(before < -50, "moving toward its place: " + before);
        // The layout moves the card again (another arrival): it stays where it is on screen, its speed is kept.
        glide.displace(60);
        glide.stop();
        compare(glide.velocity, before, "the velocity is kept through the new displacement (a restarted bezier set it to 0)");
        const start = glide.value;
        const path = stepFrames(glide, 40, 1 / 60);
        verify(start - path[0].x > 0.5, "it moves on at once, at speed: " + (start - path[0].x));
        for (let i = 1; i < path.length; i++)
            verify(path[i].x <= path[i - 1].x + 1e-9, "monotonic toward its place");
        glide.settle();
    }

    function test_reduceMotionIsAtOnce() {
        glide.duration = 0;
        glide.displace(80);
        compare(glide.value, 0);
        verify(!glide.running);
    }

    function test_longFrameNeverOvershoots() {
        glide.stop();
        glide.value = 100;
        glide.velocity = -2000;
        const path = stepFrames(glide, 1, 0.1);
        verify(Math.abs(path[0].x) < 100, "a 100 ms frame lands near the place: " + path[0].x);
        glide.settle();
    }

    function test_theColumnUsesIt() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/notifications/NotificationList.qml"), false);
        xhr.send();
        const s = xhr.responseText;
        verify(s.indexOf("readonly property real shift: glide.value") >= 0, "the card's offset is the glide's");
        verify(s.indexOf("glide.displace(item.lastY - item.y)") >= 0, "a layout move displaces it");
        compare(s.indexOf("glide.restart()"), -1, "no bezier restarted from rest");
    }
}
