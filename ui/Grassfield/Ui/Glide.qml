import QtQuick

// An offset that glides back to 0 and keeps its velocity when it is moved again on the way (audit B-17): a list keeps an item
// where it was on screen when the layout moves it (displace) and lets it settle at its place. A bezier restarted on each
// layout change started again from rest over the full duration: with arrivals or clears faster than the motion, the items
// visibly stalled and set off again. This is a critically damped spring, stepped exactly per frame (any frame time), whose
// settling time is `duration`; a new displacement adds to the offset and keeps the speed, so the motion stays smooth.
// Bind the item's offset to `value`. `duration` 0 (Reduce Motion) puts it at its place at once.
FrameAnimation {
    id: root

    property real value: 0
    // Pixels per second, toward or away from 0.
    property real velocity: 0
    // About the time to settle from rest (to a hundredth of the offset), in ms.
    property int duration: Appearance.duration(Tokens.motionNormal)
    readonly property real omega: 6.6 * 1000 / Math.max(1, root.duration)

    // The layout moved the item by -delta: it stays where it was on screen and glides from there, at the speed it had.
    function displace(delta: real): void {
        if (root.duration <= 0) {
            root.stop();
            root.value = 0;
            root.velocity = 0;
            return;
        }
        root.value += delta;
        if (!root.running)
            root.start();
    }

    // At its place, at rest, now.
    function settle(): void {
        root.stop();
        root.value = 0;
        root.velocity = 0;
    }

    running: false
    onTriggered: {
        // x(t) = (x + c t) e^(-wt), v(t) = (v - w c t) e^(-wt), c = v + w x: exact for any step.
        const t = Math.min(root.frameTime, 0.1);
        const c = root.velocity + root.omega * root.value;
        const e = Math.exp(-root.omega * t);
        const x = (root.value + c * t) * e;
        const v = (root.velocity - root.omega * c * t) * e;
        if (Math.abs(x) < 0.25 && Math.abs(v) < 10) {
            root.settle();
            return;
        }
        root.value = x;
        root.velocity = v;
    }
}
