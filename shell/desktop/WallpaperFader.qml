import QtQuick

// The desktop wallpaper's crossfades (Wallpaper.qml). One fade of a slot's opacity from `from` to `to` in `duration` ms: every frame (an animation), or `stepped` in steps of
// stepMs (the slow phase fade: a fraction of a percent of opacity per step reads as smooth and redraws the two full-screen
// wallpapers a few times a second instead of at every frame). `remaining()` is the time left, for a retarget.
Item {
    id: fader
    property Item target: null
    property real from: 0
    property real to: 1
    property int duration: 0
    property bool stepped: false
    readonly property int stepMs: 100
    readonly property bool running: anim.running || ticker.running
    property real startedAt: 0
    signal done

    function start(): void {
        stop();
        startedAt = Date.now();
        if (stepped) {
            target.opacity = from;
            ticker.start();
        } else {
            anim.target = target;
            anim.from = from;
            anim.to = to;
            anim.duration = duration;
            anim.start();
        }
    }
    function stop(): void {
        anim.stop();
        ticker.stop();
    }
    function remaining(): int {
        return Math.max(0, duration - (Date.now() - startedAt));
    }

    NumberAnimation {
        id: anim
        property: "opacity"
        onFinished: fader.done()
    }
    Timer {
        id: ticker
        interval: fader.stepMs
        repeat: true
        onTriggered: {
            const p = fader.duration > 0 ? Math.min(1, (Date.now() - fader.startedAt) / fader.duration) : 1;
            fader.target.opacity = fader.from + (fader.to - fader.from) * p;
            if (p >= 1) {
                ticker.stop();
                fader.done();
            }
        }
    }
}
