.pragma library

// Read-only parser for the Grassfield bindings file (config/hypr/grassfield/bindings.lua):
// extracts the literal `bind("KEYS", "Description", ...)` lines (and the `word_key(...)` lines of forwarding.lua). Loops and computed keys are skipped.

const BIND = /^\s*(?:bind|word_key)\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"/;

// Key names in English; the Keyboard page shows each through qsTranslate("Bindings", name) (translateKeys).
const NAMES = {
    "SUPER": QT_TRANSLATE_NOOP("Bindings", "Super"), "CTRL": QT_TRANSLATE_NOOP("Bindings", "Ctrl"),
    "ALT": QT_TRANSLATE_NOOP("Bindings", "Alt"), "SHIFT": QT_TRANSLATE_NOOP("Bindings", "Shift"),
    "RETURN": QT_TRANSLATE_NOOP("Bindings", "Return"), "SPACE": QT_TRANSLATE_NOOP("Bindings", "Space"),
    "TAB": QT_TRANSLATE_NOOP("Bindings", "Tab"), "ESCAPE": QT_TRANSLATE_NOOP("Bindings", "Esc"),
    "UP": QT_TRANSLATE_NOOP("Bindings", "Up"), "DOWN": QT_TRANSLATE_NOOP("Bindings", "Down"),
    "LEFT": QT_TRANSLATE_NOOP("Bindings", "Left"), "RIGHT": QT_TRANSLATE_NOOP("Bindings", "Right"),
    "BACKSPACE": QT_TRANSLATE_NOOP("Bindings", "Backspace"), "DELETE": QT_TRANSLATE_NOOP("Bindings", "Delete"),
    "bracketleft": QT_TRANSLATE_NOOP("Bindings", "["), "bracketright": QT_TRANSLATE_NOOP("Bindings", "]"),
    // The key above Tab, bound by keycode so that it works on every layout (grave on US, a different symbol on AZERTY).
    "code:49": QT_TRANSLATE_NOOP("Bindings", "Key above Tab"),
    // The 8, = and - keys of the zoom shortcuts, also by keycode.
    "code:17": QT_TRANSLATE_NOOP("Bindings", "8"), "code:21": QT_TRANSLATE_NOOP("Bindings", "="), "code:20": QT_TRANSLATE_NOOP("Bindings", "-"),
    // The U, I, J and K keys of the tiling quarters, by keycode (the same place on QWERTY and AZERTY).
    "code:30": QT_TRANSLATE_NOOP("Bindings", "U"), "code:31": QT_TRANSLATE_NOOP("Bindings", "I"),
    "code:44": QT_TRANSLATE_NOOP("Bindings", "J"), "code:45": QT_TRANSLATE_NOOP("Bindings", "K"),
    // The L key of the tiling popover, by keycode likewise.
    "code:46": QT_TRANSLATE_NOOP("Bindings", "L"),
    // The 5 key of the capture toolbar (Shift-Super-5), by keycode likewise.
    "code:14": QT_TRANSLATE_NOOP("Bindings", "5"),
    "mouse:272": QT_TRANSLATE_NOOP("Bindings", "Left Mouse Button"),
    "mouse:273": QT_TRANSLATE_NOOP("Bindings", "Right Mouse Button")
};

// The literal descriptions of config/hypr/grassfield/bindings.lua and forwarding.lua, listed for translation: the Keyboard page shows a
// description through qsTranslate("Bindings", description) (an unlisted one stays in English).
// tests/unit/tst_settingsstore.qml checks that every literal description of the real file is listed here.
const DESCRIPTIONS = [
    QT_TRANSLATE_NOOP("Bindings", "Terminal"),
    QT_TRANSLATE_NOOP("Bindings", "Close window"),
    QT_TRANSLATE_NOOP("Bindings", "Toggle floating/tiling"),
    QT_TRANSLATE_NOOP("Bindings", "Full screen"),
    QT_TRANSLATE_NOOP("Bindings", "Zoom (fill the screen)"),
    QT_TRANSLATE_NOOP("Bindings", "Tile the window to the left half"),
    QT_TRANSLATE_NOOP("Bindings", "Tile the window to the right half"),
    QT_TRANSLATE_NOOP("Bindings", "Tile the window to the top half"),
    QT_TRANSLATE_NOOP("Bindings", "Tile the window to the bottom half"),
    QT_TRANSLATE_NOOP("Bindings", "Return the window to its previous size"),
    QT_TRANSLATE_NOOP("Bindings", "Tile the window to the top-left quarter"),
    QT_TRANSLATE_NOOP("Bindings", "Tile the window to the top-right quarter"),
    QT_TRANSLATE_NOOP("Bindings", "Tile the window to the bottom-left quarter"),
    QT_TRANSLATE_NOOP("Bindings", "Tile the window to the bottom-right quarter"),
    QT_TRANSLATE_NOOP("Bindings", "Fill the screen with the window"),
    QT_TRANSLATE_NOOP("Bindings", "Center the window"),
    QT_TRANSLATE_NOOP("Bindings", "Arrange the windows left and right"),
    QT_TRANSLATE_NOOP("Bindings", "Arrange the windows right and left"),
    QT_TRANSLATE_NOOP("Bindings", "Arrange the windows top and bottom"),
    QT_TRANSLATE_NOOP("Bindings", "Arrange the windows bottom and top"),
    QT_TRANSLATE_NOOP("Bindings", "Arrange the windows left and in quarters"),
    QT_TRANSLATE_NOOP("Bindings", "Arrange the windows right and in quarters"),
    QT_TRANSLATE_NOOP("Bindings", "Arrange the windows top and in quarters"),
    QT_TRANSLATE_NOOP("Bindings", "Arrange the windows bottom and in quarters"),
    QT_TRANSLATE_NOOP("Bindings", "Move the window to the display on the left"),
    QT_TRANSLATE_NOOP("Bindings", "Move the window to the display on the right"),
    QT_TRANSLATE_NOOP("Bindings", "Show the tiling options of the window"),
    QT_TRANSLATE_NOOP("Bindings", "Minimize window"),
    QT_TRANSLATE_NOOP("Bindings", "Hide app"),
    QT_TRANSLATE_NOOP("Bindings", "Next window"),
    QT_TRANSLATE_NOOP("Bindings", "Previous window"),
    QT_TRANSLATE_NOOP("Bindings", "Raise window"),
    QT_TRANSLATE_NOOP("Bindings", "Switch application"),
    QT_TRANSLATE_NOOP("Bindings", "Switch to the previous application"),
    QT_TRANSLATE_NOOP("Bindings", "Next window of the application"),
    QT_TRANSLATE_NOOP("Bindings", "Move window"),
    QT_TRANSLATE_NOOP("Bindings", "Resize window"),
    "Next Space",
    "Previous Space",
    QT_TRANSLATE_NOOP("Bindings", "Overview"),
    QT_TRANSLATE_NOOP("Bindings", "Search"),
    QT_TRANSLATE_NOOP("Bindings", "Clipboard history"),
    QT_TRANSLATE_NOOP("Bindings", "Emoji & Symbols"),
    QT_TRANSLATE_NOOP("Bindings", "Previous input source"),
    QT_TRANSLATE_NOOP("Bindings", "Next input source"),
    QT_TRANSLATE_NOOP("Bindings", "Start or stop dictation"),
    QT_TRANSLATE_NOOP("Bindings", "Apps"),
    "Notification Center",
    QT_TRANSLATE_NOOP("Bindings", "Screenshot and recording options"),
    QT_TRANSLATE_NOOP("Bindings", "Lock screen"),
    QT_TRANSLATE_NOOP("Bindings", "Force Quit Applications"),
    QT_TRANSLATE_NOOP("Bindings", "Focus the menu bar"),
    QT_TRANSLATE_NOOP("Bindings", "Focus the status menus"),
    QT_TRANSLATE_NOOP("Bindings", "Focus the Dock"),
    QT_TRANSLATE_NOOP("Bindings", "Turn Dock hiding on or off"),
    QT_TRANSLATE_NOOP("Bindings", "Show Desktop"),
    QT_TRANSLATE_NOOP("Bindings", "Turn screen zoom on or off"),
    QT_TRANSLATE_NOOP("Bindings", "Zoom in"),
    QT_TRANSLATE_NOOP("Bindings", "Zoom out"),
    QT_TRANSLATE_NOOP("Bindings", "Bring Stage 1 forward"),
    QT_TRANSLATE_NOOP("Bindings", "Bring Stage 2 forward"),
    QT_TRANSLATE_NOOP("Bindings", "Bring Stage 3 forward"),
    QT_TRANSLATE_NOOP("Bindings", "Bring Stage 4 forward"),
    QT_TRANSLATE_NOOP("Bindings", "Move the window to a stage of its own"),
    QT_TRANSLATE_NOOP("Bindings", "Calculator"),
    QT_TRANSLATE_NOOP("Bindings", "Mail"),
    QT_TRANSLATE_NOOP("Bindings", "Web browser"),
    QT_TRANSLATE_NOOP("Bindings", "Files"),
    QT_TRANSLATE_NOOP("Bindings", "Grassfield Settings"),
    QT_TRANSLATE_NOOP("Bindings", "Music"),
    QT_TRANSLATE_NOOP("Bindings", "Activity Monitor"),
    QT_TRANSLATE_NOOP("Bindings", "Mute"),
    QT_TRANSLATE_NOOP("Bindings", "Volume up"),
    QT_TRANSLATE_NOOP("Bindings", "Volume down"),
    QT_TRANSLATE_NOOP("Bindings", "Brightness up"),
    QT_TRANSLATE_NOOP("Bindings", "Brightness down"),
    QT_TRANSLATE_NOOP("Bindings", "Keyboard brightness up"),
    QT_TRANSLATE_NOOP("Bindings", "Keyboard brightness down"),
    QT_TRANSLATE_NOOP("Bindings", "Previous word"),
    QT_TRANSLATE_NOOP("Bindings", "Next word"),
    QT_TRANSLATE_NOOP("Bindings", "Select to the previous word"),
    QT_TRANSLATE_NOOP("Bindings", "Select to the next word"),
    QT_TRANSLATE_NOOP("Bindings", "Delete the previous word"),
    QT_TRANSLATE_NOOP("Bindings", "Delete the next word"),
    QT_TRANSLATE_NOOP("Bindings", "Back"),
    QT_TRANSLATE_NOOP("Bindings", "Forward"),
    QT_TRANSLATE_NOOP("Bindings", "Beginning of the line"),
    QT_TRANSLATE_NOOP("Bindings", "End of the line"),
    QT_TRANSLATE_NOOP("Bindings", "Select to the beginning of the line"),
    QT_TRANSLATE_NOOP("Bindings", "Select to the end of the line"),
    QT_TRANSLATE_NOOP("Bindings", "Beginning of the document"),
    QT_TRANSLATE_NOOP("Bindings", "End of the document"),
    QT_TRANSLATE_NOOP("Bindings", "Select to the beginning of the document"),
    QT_TRANSLATE_NOOP("Bindings", "Select to the end of the document"),
    QT_TRANSLATE_NOOP("Bindings", "Delete to the beginning of the line")
];

// Descriptions of the bindings file that carry an internal feature name (Space, Notification Center) are shown under
// their UI name (renamed 2026-10-18); the file itself keeps the internal wording.
const UI_NAMES = {
    "Next Space": QT_TRANSLATE_NOOP("Bindings", "Next Desktop"),
    "Previous Space": QT_TRANSLATE_NOOP("Bindings", "Previous Desktop"),
    "Notification Center": QT_TRANSLATE_NOOP("Bindings", "Notifications")
};

function uiName(description) {
    return UI_NAMES[description] !== undefined ? UI_NAMES[description] : description;
}

function unescapeLua(s) {
    return s.replace(/\\(["\\])/g, "$1");
}

function prettyKey(token) {
    const t = token.trim();
    if (NAMES[t] !== undefined)
        return NAMES[t];
    return t.length === 1 ? t.toUpperCase() : t;
}

function prettyKeys(keys) {
    return keys.split("+").map(prettyKey).join(" + ");
}

// "Super + Shift + Q" with each key name passed through tr (the page's qsTranslate); other keys stay as they are.
function translateKeys(keys, tr) {
    return String(keys).split(" + ").map(k => tr(k)).join(" + ");
}

// Returns [{keys, description}] in file order; duplicate (keys, description) pairs are dropped.
function parse(text) {
    const out = [];
    const seen = {};
    for (const line of String(text).split("\n")) {
        if (/^\s*--/.test(line))
            continue;
        const m = BIND.exec(line);
        if (!m)
            continue;
        const keys = prettyKeys(unescapeLua(m[1]));
        const description = unescapeLua(m[2]);
        const id = keys + "\u0000" + description;
        if (seen[id])
            continue;
        seen[id] = true;
        out.push({keys: keys, description: description});
    }
    return out;
}
