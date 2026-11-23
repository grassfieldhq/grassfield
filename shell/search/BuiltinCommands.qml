pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.lib
import qs.platform
import qs.platform.shortcuts
import qs.services
import qs.notifications
import "BuiltinCommands.js" as Builtin
import "../platform/Minimized.js" as Minimized

// The built-in commands of Search beyond its five system ones (ADR-0067; docs/specs/command-palette.md slices S1, S3, S6):
// Toggle Appearance, Trash, Show Desktop, volume and media; window commands for the window that was active when Search opened;
// the Wi-Fi, Bluetooth, Airplane Mode, Do Not Disturb and Night Light toggles. This file owns the qsTr calls and the services;
// BuiltinCommands.js decides (titles that follow the state, availability, the guard under the lock). Every command calls the
// function Control Center, the menu bar, the Window menu or the keys already call: no new privilege, no compositor request of
// its own. `entries` is a provider for Commands.build; it is rebuilt when a state it reads changes.
Scope {
    id: root

    // The screen Search is on (the confirmation of Empty Trash opens there, as the Log Out one does).
    property string screenName: ""

    // ---- Do Not Disturb for a while: the deadline (ms since the epoch, 0 none) ----------------------------------------
    // Held by the shell only (not saved): after a shell restart Do Not Disturb stays as set until it is turned off.
    property double dndUntil: 0

    function armDnd(kind: string): void {
        const until = Builtin.dndDeadline(kind, Date.now());
        if (until <= 0)
            return;
        Notifications.setDnd(true);
        dndUntil = until;
        dndTimer.restart();
    }

    // Turning it on or off by hand forgets a deadline (the Control Center switch, the menu bar's Focus item, these commands).
    function dndByHand(on: bool): void {
        dndUntil = 0;
        Notifications.setDnd(on);
    }

    // Checked every minute while armed, and at the deadline: a timer does not count the time asleep, so a long interval could
    // end Do Not Disturb late after a resume.
    Timer {
        id: dndTimer
        interval: Math.max(1000, Math.min(60000, root.dndUntil - Date.now()))
        repeat: true
        running: root.dndUntil > 0
        onTriggered: root.dndTick()
    }

    function dndTick(): void {
        switch (Builtin.dndStep(dndUntil, Notifications.dnd, Date.now())) {
        case "expire":
            dndUntil = 0;
            Notifications.setDnd(false);
            return;
        case "clear":
            dndUntil = 0;
            return;
        }
    }

    Connections {
        target: Notifications

        function onDndChanged(): void {
            root.dndTick();
        }
    }

    function untilText(until: double): string {
        if (until <= 0)
            return "";
        const d = new Date(until);
        const same = d.toDateString() === new Date().toDateString();
        return same ? Qt.locale().toString(d, Qt.locale().timeFormat(Locale.ShortFormat)) : Qt.locale().toString(d, Qt.locale().dateTimeFormat(Locale.ShortFormat));
    }

    // ---- The remembered window (S3) -------------------------------------------------------------------------------------
    // The window that was active when Search opened (FocusReturn); nothing once it closed. Commands act on it only.
    readonly property string windowAddress: FocusReturn.previous ? Minimized.normalizeAddress(FocusReturn.previous.address) : ""
    readonly property var windowTop: windowAddress !== "" ? Compositor.toplevelByAddress(windowAddress) : null

    function withWindow(fn: var): void {
        // Looked up again at run time: a window closed since the list was built is dropped (never another one).
        const address = windowAddress;
        const top = address !== "" ? Compositor.toplevelByAddress(address) : null;
        if (top)
            fn(top);
    }

    readonly property var entries: {
        const t = {
            subtitleSystem: qsTr("System command"),
            subtitleWindow: qsTr("Window"),
            appearance: qsTr("Toggle Appearance"), appearanceWords: [qsTr("appearance"), qsTr("dark mode"), qsTr("light mode"), qsTr("theme")],
            appearanceDark: qsTr("Dark"), appearanceLight: qsTr("Light"),
            trashEmpty: qsTr("Empty Trash"), trashEmptyWords: [qsTr("empty the trash"), qsTr("delete everything")],
            trashOpen: qsTr("Open Trash"), trashOpenWords: [qsTr("trash"), qsTr("bin")],
            showDesktop: qsTr("Show Desktop"), showDesktopWords: [qsTr("desktop"), qsTr("hide all windows")],
            volumeUp: qsTr("Volume Up"), volumeUpWords: [qsTr("louder"), qsTr("sound")],
            volumeDown: qsTr("Volume Down"), volumeDownWords: [qsTr("quieter"), qsTr("sound")],
            mute: qsTr("Mute"), unmute: qsTr("Unmute"), muteWords: [qsTr("silence"), qsTr("sound")],
            stateMuted: qsTr("Muted"), stateNotMuted: qsTr("Sound on"),
            play: qsTr("Play"), pause: qsTr("Pause"), playWords: [qsTr("music"), qsTr("media")],
            statePlaying: qsTr("Playing"), statePaused: qsTr("Paused"),
            nextTrack: qsTr("Next Track"), nextTrackWords: [qsTr("skip"), qsTr("next song")],
            previousTrack: qsTr("Previous Track"), previousTrackWords: [qsTr("previous song"), qsTr("back")],
            tileWord: qsTr("window"),
            tileFmt: qsTr("Move Window: %1"),
            arrangeFmt: qsTr("Arrange Windows: %1"),
            places: {
                "left": qsTr("Left"), "right": qsTr("Right"), "top": qsTr("Top"), "bottom": qsTr("Bottom"),
                "top-left": qsTr("Top Left"), "top-right": qsTr("Top Right"), "bottom-left": qsTr("Bottom Left"), "bottom-right": qsTr("Bottom Right"),
                "fill": qsTr("Fill"), "center": qsTr("Center"), "previous": qsTr("Return to Previous Size")
            },
            layouts: {
                "left-right": qsTr("Left & Right"), "right-left": qsTr("Right & Left"), "top-bottom": qsTr("Top & Bottom"), "bottom-top": qsTr("Bottom & Top"),
                "quarters": qsTr("Quarters"), "left-quarters": qsTr("Left & Quarters"), "right-quarters": qsTr("Right & Quarters"),
                "top-quarters": qsTr("Top & Quarters"), "bottom-quarters": qsTr("Bottom & Quarters")
            },
            nextDisplay: qsTr("Move Window to Next Display"), previousDisplay: qsTr("Move Window to Previous Display"),
            displayWords: [qsTr("monitor"), qsTr("screen")],
            minimize: qsTr("Minimize Window"), minimizeWords: [qsTr("minimize"), qsTr("hide")],
            enterFullscreen: qsTr("Enter Full Screen"), exitFullscreen: qsTr("Exit Full Screen"), fullscreenWords: [qsTr("full screen"), qsTr("fullscreen")],
            stateOn: qsTr("On"), stateOff: qsTr("Off"), stateOnUntil: qsTr("On until %1"),
            wifiTurnOn: qsTr("Turn Wi-Fi On"), wifiTurnOff: qsTr("Turn Wi-Fi Off"), wifiWords: [qsTr("wifi"), qsTr("wireless"), qsTr("network")],
            bluetoothTurnOn: qsTr("Turn Bluetooth On"), bluetoothTurnOff: qsTr("Turn Bluetooth Off"), bluetoothWords: [qsTr("bluetooth")],
            airplaneTurnOn: qsTr("Turn Airplane Mode On"), airplaneTurnOff: qsTr("Turn Airplane Mode Off"), airplaneWords: [qsTr("flight mode"), qsTr("radios")],
            dndTurnOn: qsTr("Turn Do Not Disturb On"), dndTurnOff: qsTr("Turn Do Not Disturb Off"),
            dndHour: qsTr("Do Not Disturb for 1 Hour"), dndTomorrow: qsTr("Do Not Disturb Until Tomorrow"),
            dndWords: [qsTr("focus"), qsTr("silence"), qsTr("notifications")],
            nightLightTurnOn: qsTr("Turn Night Light On"), nightLightTurnOff: qsTr("Turn Night Light Off"), nightLightWords: [qsTr("warm colors"), qsTr("blue light")]
        };
        const refuses = () => SessionState.refuses("search");
        const top = root.windowTop;
        const hyprTop = top ? Compositor.hyprlandToplevel(top) : null;
        const inFull = top ? top.fullscreen === true : false;
        const stateSystem = {
            dark: Settings.dark,
            trashEmpty: Trash.empty,
            audioReady: Audio.deviceReady,
            muted: Audio.muted,
            mediaAvailable: Media.available,
            playing: Media.playing
        };
        const actSystem = {
            appearance: dark => Settings.setAppearance(dark ? "dark" : "light"),
            // The Dock menu's question; Power.run("emptytrash") deletes only after it is confirmed.
            emptyTrash: () => Popups.confirm(qsTr("Are you sure you want to permanently erase the items in the Trash?"), qsTr("You can’t undo this action."), qsTr("Empty Trash"), "emptytrash", {}, true, root.screenName),
            openTrash: () => Trash.open(),
            // The keys' own request, answered in process (platform/shortcuts): the volume keys, with their on-screen feedback, and Show Desktop.
            showDesktop: () => Shortcuts.deliver({target: "windows", fn: "showDesktop", args: []}),
            volume: direction => Shortcuts.deliver({target: "volume", fn: direction, args: []}),
            media: verb => verb === "toggle" ? Media.togglePlaying() : verb === "next" ? Media.next() : Media.previous()
        };
        const ctx = {
            hasTarget: top !== null && hyprTop !== null,
            canTile: Compositor.canTile && !inFull,
            canArrange: Compositor.canArrange && !inFull,
            canMoveOutput: Compositor.canTileHover && top !== null && Compositor.otherOutputs(top).length > 0,
            canMinimize: top !== null && !inFull && !Compositor.inSplit(top),
            fullscreen: inFull
        };
        const actWindow = {
            tile: place => root.withWindow(w => Compositor.tile(w, place)),
            arrange: layout => root.withWindow(w => Compositor.arrange(w, layout)),
            nextOutput: direction => root.withWindow(w => Compositor.moveToNextOutput(w, direction)),
            minimize: () => root.withWindow(w => Compositor.minimize(w)),
            fullscreen: () => root.withWindow(w => Compositor.toggleFullscreen(w))
        };
        const stateToggles = {
            wifi: {available: Connectivity.available && Connectivity.wifiDevice !== null, on: Connectivity.wifiEnabled && Connectivity.wifiDevice !== null},
            bluetooth: {available: BluetoothState.available, on: BluetoothState.enabled},
            airplane: {available: Connectivity.airplaneAvailable, on: Connectivity.airplane},
            dnd: {available: true, on: Notifications.dnd, until: root.dndUntil, untilText: root.untilText(root.dndUntil)},
            nightLight: {available: NightShift.available, on: NightShift.on}
        };
        const actToggles = {
            wifi: on => Connectivity.toggleWifi(on),
            bluetooth: on => BluetoothState.setEnabled(on),
            airplane: on => Connectivity.setAirplane(on),
            dnd: on => root.dndByHand(on),
            dndFor: kind => root.armDnd(kind),
            nightLight: on => NightShift.setOn(on)
        };
        return Builtin.systemCommands(t, stateSystem, actSystem, refuses)
            .concat(Builtin.windowCommands(t, ctx, actWindow, refuses))
            .concat(Builtin.toggleCommands(t, stateToggles, actToggles, refuses));
    }
}
