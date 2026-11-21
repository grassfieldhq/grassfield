import QtQuick
import Grassfield.Ui

// A surface that follows its trackpad gesture (CIO-01 R2, macOS: Mission Control and Launchpad move with the fingers):
// Overview (target "overview") and Apps ("apps") each hold one. While it exists the router leaves the gesture's end to it
// (Shortcuts.follow: no discrete open or close). It asks the surface to `show()` at the begin of `<target>-open` (refused over
// the lock screen by the surface itself, SessionState.refuses, as for the key), sets `progress` (0..1) from the fingers, and
// at the end leaves it to the surface's own state (completed: animated the rest of the way from there) or asks it to `close()`
// (gone back, or `<target>-close` completed): `progress` then stays where the fingers left it until `open` is false, and the
// surface animates to 0 from there. `active`: steps are being drawn as they come (no animation between them). `opening`: an
// opening gesture is in flight (Overview holds its live layout until it completes). Reduce Motion: nothing follows the
// fingers; the completed end alone opens or closes (Shortcuts.js followStep).
QtObject {
    id: follower

    required property string target
    // The surface is open (bound to its own state).
    property bool open: false
    property bool reduceMotion: Appearance.reduceMotion

    // What the surface draws while a gesture drives it (0 = closed, 1 = open), -1 when it draws its own state.
    property real progress: -1
    property bool active: false
    property bool opening: false

    signal show
    signal close

    function set(value: real): void {
        // In this order: the surface's animation is switched off before the value it animates changes, and on again before
        // the value goes back to the surface's own state.
        if (value >= 0) {
            active = true;
            progress = value;
        } else {
            active = false;
            progress = -1;
        }
    }

    function step(kind: string, phase: string, value: real, commit: bool): void {
        const r = Shortcuts.followStep(target, open, progress, kind, phase, value, commit, reduceMotion);
        if (!r) {
            // A begin refused by the surface (the lock screen) leaves nothing to follow: its end or cancel still clears
            // `opening`, which would otherwise hold the next open's layout.
            if (phase === "end" || phase === "cancel" || !open)
                opening = false;
            return;
        }
        // Set before the surface opens (it holds its live layout from the start), cleared once it has completed or closed.
        if (phase === "begin")
            opening = r.action === "show" && r.progress >= 0;
        if (r.action === "show") {
            set(r.progress);
            follower.show();
        } else if (r.action === "close") {
            active = false;
            follower.close();
        } else {
            set(r.progress);
        }
        if (phase === "end" || phase === "cancel")
            opening = false;
        if (!open) {
            // Not open after `show()`: the surface refused (it opens synchronously), so nothing is opening.
            opening = false;
            set(-1);
        }
    }

    onOpenChanged: {
        if (!open) {
            opening = false;
            set(-1);
        }
    }

    property Connections router: Connections {
        target: Shortcuts

        function onGesture(kind: string, phase: string, value: real, commit: bool): void {
            follower.step(kind, phase, value, commit);
        }
    }

    Component.onCompleted: {
        Shortcuts.follow(target + "-open", true);
        Shortcuts.follow(target + "-close", true);
    }

    Component.onDestruction: {
        Shortcuts.follow(target + "-open", false);
        Shortcuts.follow(target + "-close", false);
    }
}
