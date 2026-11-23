.pragma library

// The built-in commands of Search beyond the five it always had (ADR-0067 D-2; docs/specs/command-palette.md B1, B3, B7;
// slices S1, S3, S6): system, window and toggle commands. Pure: no QML, no service. BuiltinCommands.qml owns the qsTr calls and
// the services and hands over `t` (translated words), `st` (the state read now) and `act` (the function each command calls:
// the one Control Center, the menu bar, the Window menu or the keys already call, so no new privilege). Every entry's `run` is
// wrapped by `guarded`, which does nothing while the session is locked. Entries follow Commands.js (id, title, keywords...).

const KIND_SYSTEM = "system";
const KIND_WINDOW = "window";
const KIND_SETTING = "setting";

// A command that does nothing while `refuses()` is true (SessionState.refuses: the lock). `refuses` is called at each run.
function guarded(refuses, run) {
    return (args, origin) => {
        if (refuses())
            return;
        run(args, origin);
    };
}

function _entry(spec, refuses) {
    return {
        id: spec.id,
        title: spec.title,
        subtitle: spec.subtitle,
        keywords: spec.words || [],
        keywordsEn: spec.wordsEn || [],
        glyph: spec.glyph,
        kind: spec.kind,
        provider: "builtin",
        available: spec.available !== false,
        run: guarded(refuses, spec.run)
    };
}

// ---- S1: system commands --------------------------------------------------------------------------------------------

// Toggle Appearance, Empty and Open Trash, Show Desktop, volume and media. `st`: {dark, trashEmpty, audioReady, muted,
// mediaAvailable, playing}; `act`: {appearance(dark), emptyTrash, openTrash, showDesktop, volume(direction), media(verb)}.
// Empty Trash is the Dock menu's confirmation (act.emptyTrash asks, then Power.run("emptytrash")): never a silent delete.
// Sleep Displays is not offered: it needs the security side (idle module), a slice of its own (spec B1).
function systemCommands(t, st, act, refuses) {
    const sys = (id, title, words, wordsEn, glyph, run, available, subtitle) =>
        _entry({id: id, title: title, subtitle: subtitle !== undefined ? subtitle : t.subtitleSystem, words: words, wordsEn: wordsEn,
            glyph: glyph, kind: KIND_SYSTEM, run: run, available: available}, refuses);
    return [
        sys("sys.appearance", t.appearance, t.appearanceWords, ["appearance", "dark mode", "light mode", "theme"], "paintbrush",
            () => act.appearance(!st.dark), true, st.dark ? t.appearanceDark : t.appearanceLight),
        sys("sys.saver", t.saver, t.saverWords, ["screen saver", "screensaver"], "display",
            () => act.startSaver(), true),
        sys("sys.trash.empty", t.trashEmpty, t.trashEmptyWords, ["empty trash", "bin"], "trash-full",
            () => act.emptyTrash(), !st.trashEmpty),
        sys("sys.trash.open", t.trashOpen, t.trashOpenWords, ["open trash", "bin"], "trash",
            () => act.openTrash(), true),
        sys("sys.desktop", t.showDesktop, t.showDesktopWords, ["show desktop"], "display",
            () => act.showDesktop(), true),
        sys("sys.volume.up", t.volumeUp, t.volumeUpWords, ["volume up", "louder"], "volume-3",
            () => act.volume("up"), st.audioReady),
        sys("sys.volume.down", t.volumeDown, t.volumeDownWords, ["volume down", "quieter"], "volume-1",
            () => act.volume("down"), st.audioReady),
        sys("sys.volume.mute", st.muted ? t.unmute : t.mute, t.muteWords, ["mute", "unmute", "sound"], st.muted ? "volume-3" : "volume-mute",
            () => act.volume("mute"), st.audioReady, st.muted ? t.stateMuted : t.stateNotMuted),
        sys("sys.media.toggle", st.playing ? t.pause : t.play, t.playWords, ["play", "pause", "music"], st.playing ? "media-pause" : "media-play",
            () => act.media("toggle"), st.mediaAvailable, st.playing ? t.statePlaying : t.statePaused),
        sys("sys.media.next", t.nextTrack, t.nextTrackWords, ["next track", "skip"], "media-next",
            () => act.media("next"), st.mediaAvailable),
        sys("sys.media.previous", t.previousTrack, t.previousTrackWords, ["previous track", "back"], "media-prev",
            () => act.media("previous"), st.mediaAvailable)
    ];
}

// ---- S3: window commands --------------------------------------------------------------------------------------------

// The places and arrangements of the Window menu (Minimized.tilePlaces, arrangeLayouts), in the menu's order.
const PLACES = ["left", "right", "top", "bottom", "top-left", "top-right", "bottom-left", "bottom-right", "fill", "center", "previous"];
const LAYOUTS = ["left-right", "right-left", "top-bottom", "bottom-top", "quarters", "left-quarters", "right-quarters", "top-quarters", "bottom-quarters"];

// For the window that was active when Search opened. `ctx`: {hasTarget (it still exists), canTile, canArrange, canMoveOutput
// (the plugin's tile-hover and another output), canMinimize, fullscreen}; `act`: {tile(place), arrange(layout), nextOutput(
// direction), minimize(), fullscreen()}, each acting on that remembered window only (BuiltinCommands.qml resolves it by its
// address and drops it when it closed). `t`: {subtitle, tileFmt, arrangeFmt, places{}, layouts{}, ...}. Unavailable (hidden by Commands.match)
// without the plugin feature, never faked.
function windowCommands(t, ctx, act, refuses) {
    const win = (id, title, words, wordsEn, glyph, run, available) =>
        _entry({id: id, title: title, subtitle: t.subtitleWindow, words: words, wordsEn: wordsEn, glyph: glyph, kind: KIND_WINDOW,
            run: run, available: ctx.hasTarget && available}, refuses);
    const out = [];
    for (const place of PLACES) {
        const name = t.places[place];
        out.push(win("win.tile." + place, place === "previous" ? name : t.tileFmt.arg(name), [t.tileWord, name], ["window", "tile", "move", "resize"],
            "zoom-glyph", () => act.tile(place), ctx.canTile));
    }
    for (const layout of LAYOUTS) {
        const name = t.layouts[layout];
        out.push(win("win.arrange." + layout, t.arrangeFmt.arg(name), [t.tileWord, name], ["window", "arrange", "tile", "layout"],
            "zoom-glyph", () => act.arrange(layout), ctx.canArrange));
    }
    out.push(win("win.display.next", t.nextDisplay, t.displayWords, ["move window to next display", "monitor", "screen"], "display",
        () => act.nextOutput("right"), ctx.canMoveOutput));
    out.push(win("win.display.previous", t.previousDisplay, t.displayWords, ["move window to previous display", "monitor", "screen"], "display",
        () => act.nextOutput("left"), ctx.canMoveOutput));
    out.push(win("win.minimize", t.minimize, t.minimizeWords, ["minimize", "hide window"], "minimize-glyph",
        () => act.minimize(), ctx.canMinimize));
    out.push(win("win.fullscreen", ctx.fullscreen ? t.exitFullscreen : t.enterFullscreen, t.fullscreenWords, ["full screen", "fullscreen"], "zoom-glyph",
        () => act.fullscreen(), true));
    return out;
}

// ---- S6: toggles ----------------------------------------------------------------------------------------------------

// Wi-Fi, Bluetooth, Airplane Mode, Do Not Disturb (and for 1 hour, until tomorrow), Night Light. One row each, reading its
// state in the title ("Turn Wi-Fi Off") and the subtitle ("On"). `st`: {wifi: {available, on}, bluetooth: {...}, airplane:
// {...}, dnd: {on, until (ms, 0 none), untilText}, nightLight: {...}}; `act`: {wifi(on), bluetooth(on), airplane(on), dnd(on),
// dndFor(kind), nightLight(on)}: the functions Control Center calls. An entry whose service is missing is unavailable
// (no Bluetooth toggle without an adapter).
function toggleCommands(t, st, act, refuses) {
    const tog = (id, on, titleOn, titleOff, words, wordsEn, glyph, run, available, subtitle) =>
        _entry({id: id, title: on ? titleOn : titleOff, subtitle: subtitle !== undefined ? subtitle : (on ? t.stateOn : t.stateOff), words: words,
            wordsEn: wordsEn, glyph: glyph, kind: KIND_SETTING, run: run, available: available}, refuses);
    const dndSub = st.dnd.on ? (st.dnd.until > 0 ? t.stateOnUntil.arg(st.dnd.untilText) : t.stateOn) : t.stateOff;
    return [
        tog("set.wifi", st.wifi.on, t.wifiTurnOff, t.wifiTurnOn, t.wifiWords, ["wifi", "wi-fi", "wireless", "network"],
            st.wifi.on ? "wifi-3" : "wifi-off", () => act.wifi(!st.wifi.on), st.wifi.available),
        tog("set.bluetooth", st.bluetooth.on, t.bluetoothTurnOff, t.bluetoothTurnOn, t.bluetoothWords, ["bluetooth"],
            "bluetooth", () => act.bluetooth(!st.bluetooth.on), st.bluetooth.available),
        tog("set.airplane", st.airplane.on, t.airplaneTurnOff, t.airplaneTurnOn, t.airplaneWords, ["airplane mode", "flight mode", "radios"],
            "airplane", () => act.airplane(!st.airplane.on), st.airplane.available),
        tog("set.dnd", st.dnd.on, t.dndTurnOff, t.dndTurnOn, t.dndWords, ["do not disturb", "dnd", "focus", "silence", "notifications"],
            "moon", () => act.dnd(!st.dnd.on), st.dnd.available, dndSub),
        tog("set.dnd.hour", false, "", t.dndHour, t.dndWords, ["do not disturb for 1 hour", "dnd", "focus"],
            "moon", () => act.dndFor("hour"), st.dnd.available && !st.dnd.on, t.stateOff),
        tog("set.dnd.tomorrow", false, "", t.dndTomorrow, t.dndWords, ["do not disturb until tomorrow", "dnd", "focus"],
            "moon", () => act.dndFor("tomorrow"), st.dnd.available && !st.dnd.on, t.stateOff),
        tog("set.nightlight", st.nightLight.on, t.nightLightTurnOff, t.nightLightTurnOn, t.nightLightWords, ["night light", "warm", "blue light"],
            "sun", () => act.nightLight(!st.nightLight.on), st.nightLight.available)
    ];
}
