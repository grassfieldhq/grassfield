import QtQuick
import Quickshell

// A window that keeps drawing with late frames: every third frame the GUI thread is busy for 200 ms (what a busy security
// process or UI looks like to the scene graph: the idle dim's fade, the lock surfaces, a display plugged in, a video starting).
// With QSG_RENDER_LOOP=threaded (every Wayland session) the animation clock, and with it every QML Timer, then falls far behind
// wall time (measured: a 2 s Timer every 8.9 s).
FloatingWindow {
    id: win

    visible: true
    implicitWidth: 120
    implicitHeight: 120
    color: "black"
    property int frames: 0

    Rectangle {
        width: 40
        height: 40
        color: "white"
        RotationAnimation on rotation {
            from: 0
            to: 360
            duration: 1000
            loops: Animation.Infinite
        }
    }

    FrameAnimation {
        running: true
        onTriggered: {
            win.frames++;
            if (win.frames % 3 !== 0)
                return;
            const t = Date.now();
            while (Date.now() - t < 200) {
                // busy: a late frame
            }
        }
    }
}
