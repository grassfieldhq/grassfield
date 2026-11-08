pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.lib
import qs.services
import "SaverModel.js" as SaverModel

// The screen saver (ADR-0032; Settings > Wallpaper > Screen Saver): after screensaver.idleMinutes without input while the
// session is unlocked, one opaque surface per display on the overlay layer shows the chosen saver (SaverView). The first
// input ends it and goes no further: the surfaces hold the pointer and the keyboard while shown, so the waking key or click
// is consumed, as on macOS (owner's choice, 2026-10-26). Never in place of the lock: the idle lock, the dim before it and the
// display power-off keep their own timers (shell/security/idle, untouched); while the session is locked the saver is hidden
// (the session-lock surfaces cover every layer anyway) and after the unlock it waits for its delay again. A Wayland idle
// inhibitor (respectInhibitors) or an application's org.freedesktop.ScreenSaver inhibitor (`busInhibited`, bound in shell.qml
// as the idle lock's) keeps it off.
Scope {
    id: root

    // Applications' org.freedesktop.ScreenSaver inhibitors, served by the menu bridge (GF-016).
    property bool busInhibited: false
    // The idle module switched the displays off (bound in shell.qml): nobody sees the saver, the slideshow stops preparing
    // pictures until the input that ends it.
    property bool displaysOff: false
    // Each display's slide (screen name -> prepared file), so one display's cache pruning keeps the others' pictures.
    property var slideFiles: ({})

    // Dev session only (Mode.dev, ADR-0019): the dev hooks answer, and the delay is the test's (0 = never) rather than the
    // user's, so a nested session never starts the saver on its own.
    readonly property bool devHooks: Mode.dev
    property int devSeconds: 0
    readonly property int idleSeconds: devHooks ? devSeconds : Settings.screenSaverIdleMinutes * 60
    readonly property string kind: SaverModel.kindOf(Settings.screenSaverKind)
    readonly property string folder: SaverModel.folderOf(Settings.screenSaverFolder, WallpaperConfig.picturesRoot(WallpaperState.environment))

    // Quickshell's IdleMonitor keeps the timeout it was enabled with (Idle.qml): re-enabled when the delay changes.
    property bool rearming: false
    // `saver devShow` (dev only): shown without waiting, for captures; ends like the real one, at the first input.
    property bool devShown: false
    // The first input ended it: hidden at once, before the compositor's activity report reaches the monitor.
    property bool dismissed: false

    // ADR-0040 step 5 (ID-8): a saver on screen when a lock starts stays until the lock holds (then it is under the lock
    // surfaces), so the lock is not preceded by a flash of the desktop; at most SaverModel.UNTIL_LOCK_MAX_MS (a lock that
    // never confirms keeps trying on its own). `wasShown` is what was on screen before the lock flipped `locked`.
    property bool wasShown: false
    readonly property bool lockStarting: SessionState.lockStarting
    readonly property bool shown: (root.lockStarting && root.wasShown) || (!SessionState.locked && !root.dismissed && (root.devShown || (monitor.enabled && monitor.isIdle)))
    onLockStartingChanged: {
        if (root.lockStarting && root.wasShown)
            untilLockBound.restart();
    }
    Timer {
        id: untilLockBound
        interval: SaverModel.UNTIL_LOCK_MAX_MS
        onTriggered: root.wasShown = false
    }

    onShownChanged: {
        console.info("grassfield-saver: " + (shown ? "shown (" + kind + ")" : "hidden"));
        root.wasShown = shown;
        if (!shown)
            root.slideFiles = {};
    }

    function noteSlide(screenName: string, file: string): void {
        const next = Object.assign({}, root.slideFiles);
        next[screenName] = file;
        root.slideFiles = next;
    }

    function dismiss(): void {
        if (!root.shown)
            return;
        root.dismissed = true;
        root.devShown = false;
    }

    Connections {
        target: SessionState

        function onLockedChanged(): void {
            root.devShown = false;
        }
    }

    IdleMonitor {
        id: monitor
        // Armed only once its timeout is the one wanted, so a new delay never arms it with the previous one.
        enabled: timeout === Math.max(1, root.idleSeconds) && SaverModel.armed(root.idleSeconds, SessionState.locked, root.busInhibited, root.rearming)
        timeout: Math.max(1, root.idleSeconds)
        respectInhibitors: true
        // Activity ends a saver shown by `devShow` too; the next idle period may show it again.
        onIsIdleChanged: {
            if (isIdle)
                return;
            root.devShown = false;
            root.dismissed = false;
        }
        onTimeoutChanged: {
            root.rearming = true;
            Qt.callLater(() => root.rearming = false);
        }
    }

    Variants {
        model: Quickshell.screens

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData

            screen: modelData
            // Hidden at once on input; only the appearance fades.
            visible: root.shown
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "grassfield-saver"
            // The keyboard while shown: the waking key lands here and goes no further.
            WlrLayershell.keyboardFocus: root.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            SaverView {
                id: view

                anchors.fill: parent
                screenInfo: win.modelData
                kind: root.kind
                folder: root.folder
                active: root.shown
                paused: root.displaysOff
                keepFiles: Object.keys(root.slideFiles).filter(n => n !== win.modelData.name).map(n => root.slideFiles[n])
                onSlideShown: file => root.noteSlide(win.modelData.name, file)
                // Fades in (macOS fades the saver in); the window itself goes at once on input.
                opacity: root.shown ? 1 : 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.saverFadeIn)
                    }
                }
            }

            // The waking click (any button, the wheel) ends the saver here and reaches nothing under it; the pointer is hidden
            // while it shows, as on macOS.
            MouseArea {
                anchors.fill: parent
                enabled: root.shown
                acceptedButtons: Qt.AllButtons
                cursorShape: root.shown ? Qt.BlankCursor : Qt.ArrowCursor
                onPressed: mouse => {
                    mouse.accepted = true;
                    root.dismiss();
                }
                onWheel: wheel => {
                    wheel.accepted = true;
                    root.dismiss();
                }
            }

            // The waking key ends it here.
            Item {
                id: keys

                anchors.fill: parent
                focus: true
                Keys.onPressed: event => {
                    event.accepted = true;
                    root.dismiss();
                }
            }

            onVisibleChanged: if (visible)
                keys.forceActiveFocus()
        }
    }

    IpcHandler {
        target: "saver"

        // Test hook (dev only, else "refused"): the saver's state as JSON.
        function status(): string {
            if (!root.devHooks)
                return Mode.refused;
            return JSON.stringify({
                shown: root.shown,
                kind: root.kind,
                folder: root.folder,
                idleSeconds: root.idleSeconds,
                armed: monitor.enabled,
                idle: monitor.isIdle,
                busInhibited: root.busInhibited
            });
        }

        // Dev hook (dev only, else "refused"): the delay in seconds, 0..600 (0 = never), for a nested test.
        function devDelay(seconds: int): string {
            if (!root.devHooks || seconds < 0 || seconds > 600)
                return Mode.refused;
            root.devSeconds = seconds;
            return "ok";
        }

        // Dev hook (dev only, else "refused"): show the saver now (captures); the first input ends it. Refused while locked.
        function devShow(): string {
            if (!root.devHooks || SessionState.locked)
                return Mode.refused;
            root.dismissed = false;
            root.devShown = true;
            return "ok";
        }
    }
}
