.pragma library
.import "../platform/Minimized.js" as Minimized

// The clipboard history's decisions on the shell side (ADR-0034): whether a copy may be recorded, where the helper looks, the
// helper's lines, the item list, and the paste request sent to Hyprland. Pure functions, unit-tested (tests/unit/tst_clipboard.qml);
// shell/services/Clipboard.qml runs them.

const US = "\x1f";
// No copy is recorded this long after an authorization request ended (ADR-0034 Q11): an echo-on answer is copyable.
const AUTH_GRACE_MS = 2000;
// The paste is sent only this long after Search's close asked for the keyboard back (ADR-0034 §4).
const PASTE_WAIT_MS = 1000;
// How often the service looks whether the target window is active again.
const PASTE_POLL_MS = 50;
// macOS 27's three durations (Settings > Search), in milliseconds.
const RETENTION = {"30m": 30 * 60 * 1000, "8h": 8 * 3600 * 1000, "7d": 7 * 24 * 3600 * 1000};

// The windows the session hides from screen sharing (config/hypr/grassfield/privacy.lua, its BUILTIN matches, class regexes,
// the same strings: Omarchy 4.5.0's no_screen_share rules): password managers that may set no hint (Bitwarden). A copy is not
// recorded while one of them is the active window. tests/security/screenshare_rules.sh fails when the installed Omarchy
// protects a window privacy.lua's list does not name (R7-SEC-03).
const PROTECTED_CLASSES = ["^(1[pP]assword|com\\.onepassword\\.OnePassword)$", "^([bB]itwarden)$", ".*nngceckbapebfimnlniiiahkandclblb.*"];
// The terminal test of config/hypr/grassfield/forwarding.lua (terminal_focused), whole: its classes (lower case, exact) and its
// prefixes. tests/unit/tst_clipboard.qml reads forwarding.lua and checks both lists.
const TERMINAL_CLASSES = ["alacritty", "kitty", "com.mitchellh.ghostty", "foot", "org.codeberg.dnkl.foot", "wezterm", "org.wezfurlong.wezterm"];
const TERMINAL_PREFIXES = ["org.omarchy.", "tui."];

// A clear's time as the helper takes it (--cleared-at, CH <ms>): whole milliseconds, digits only; 0 for none or a bad value.
function clearTimeArg(ms) {
    const n = Math.floor(Number(ms));
    return isFinite(n) && n > 0 && n <= Number.MAX_SAFE_INTEGER ? String(n) : "0";
}

function retentionMs(key) {
    return RETENTION[key] !== undefined ? RETENTION[key] : RETENTION["8h"];
}

function isProtectedClass(cls) {
    const c = String(cls || "");
    return c !== "" && PROTECTED_CLASSES.some(p => new RegExp(p).test(c));
}

function isTerminalClass(cls) {
    const c = String(cls || "").toLowerCase();
    return TERMINAL_CLASSES.indexOf(c) >= 0 || TERMINAL_PREFIXES.some(p => c.startsWith(p));
}

// The helper's answer to an offer: true only while the history is on, neither lock source says locked, no authorization request
// is open or ended less than AUTH_GRACE_MS ago (authorizingGrace: the service's Timer), and the active window is not a protected
// password manager (ADR-0034 §2). s: {enabled, locked, helperLocked, authorizing, authorizingGrace, activeClass}
function mayRecord(s) {
    if (!s || s.enabled !== true || s.locked !== false || s.helperLocked !== false || s.authorizing !== false
            || s.authorizingGrace !== false)
        return false;
    return !isProtectedClass(s.activeClass);
}

// The display socket the helper is given (ADR-0034 §8): in a dev session only GRASSFIELD_CLIPBOARD_DISPLAY, which must be
// absolute; in a real session $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY (or WAYLAND_DISPLAY when absolute). "" = no helper.
function displayPath(dev, devDisplay, runtimeDir, waylandDisplay) {
    if (dev === true) {
        const d = String(devDisplay || "");
        return d.charAt(0) === "/" ? d : "";
    }
    const w = String(waylandDisplay || "");
    if (w.charAt(0) === "/")
        return w;
    const r = String(runtimeDir || "");
    if (w === "" || w.indexOf("/") >= 0 || r.charAt(0) !== "/")
        return "";
    return r.replace(/\/+$/, "") + "/" + w;
}

// The helper's runtime directory (thumbnails, previews; tmpfs), one per display so that a dev session never shares the real
// session's: $XDG_RUNTIME_DIR/grassfield/clipboard-<display name>.
function runtimeDir(xdgRuntimeDir, display) {
    const r = String(xdgRuntimeDir || "");
    const d = String(display || "");
    if (r.charAt(0) !== "/" || d === "")
        return "";
    const name = d.split("/").pop().replace(/[^A-Za-z0-9._-]/g, "_");
    return r.replace(/\/+$/, "") + "/grassfield/clipboard-" + (name || "display");
}

function escapeField(text) {
    return String(text).replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/\r/g, "\\r").replace(/\x1f/g, "\\u");
}

function unescapeField(text) {
    let out = "";
    const s = String(text);
    for (let i = 0; i < s.length; i++) {
        const c = s.charAt(i);
        if (c !== "\\" || i + 1 >= s.length) {
            out += c;
            continue;
        }
        const n = s.charAt(++i);
        out += n === "n" ? "\n" : n === "r" ? "\r" : n === "u" ? US : n;
    }
    return out;
}

// One line to the helper.
function line(fields) {
    return fields.map(escapeField).join(US);
}

function parseLine(text) {
    return String(text).split(US).map(unescapeField);
}

// An "I" line: the item's metadata (never its full text).
function parseItem(f) {
    if (!f || f[0] !== "I" || f.length < 13 || !/^[0-9a-f]{16}$/.test(f[1]))
        return null;
    return {
        id: f[1],
        kind: f[2],
        mimes: f[3] === "" ? [] : f[3].split(","),
        size: Number(f[4]) || 0,
        copiedAt: Number(f[5]) || 0,
        pinnedAt: Number(f[6]) || 0,
        pinned: (Number(f[6]) || 0) > 0,
        formatted: f[7] === "1",
        files: Number(f[8]) || 0,
        title: f[9],
        excerpt: f[10],
        thumbnail: f[11],
        app: f[12]
    };
}

// Pinned items first (newest pin first), then the history (newest copy first).
function order(items) {
    return items.slice().sort((a, b) => {
        if (a.pinned !== b.pinned)
            return a.pinned ? -1 : 1;
        if (a.pinned)
            return b.pinnedAt - a.pinnedAt;
        return b.copiedAt - a.copiedAt;
    });
}

function upsert(items, item) {
    return order(items.filter(i => i.id !== item.id).concat([item]));
}

function removeId(items, id) {
    return items.filter(i => i.id !== id);
}

// Whether the paste may be sent now (ADR-0034 §4). s: {locked, helperLocked, rememberedAddress, activeAddress, closedSinceOpen,
// otherSurfaceOpen, ownsItem, expired}. closedSinceOpen: Hyprland reported `closewindow` for the remembered address since Search
// opened (an address can be reused by a new window); ownsItem: the helper still owns the item chosen (a Copy chosen since, or
// another app taking the clipboard, would make Ctrl+V paste something else); expired: the PASTE_WAIT_MS since the helper owned
// the item have passed (the service measures them with one Qt timer, monotonic, never by counting checks).
function mayPaste(s) {
    if (!s || s.locked !== false || s.helperLocked !== false || s.closedSinceOpen !== false || s.otherSurfaceOpen !== false
            || s.ownsItem !== true || s.expired !== false)
        return false;
    const want = Minimized.normalizeAddress(s.rememberedAddress || "");
    return want !== "" && Minimized.normalizeAddress(s.activeAddress || "") === want;
}

// One check of a paste waiting for its window (every PASTE_POLL_MS once the helper owns the item, and at the deadline): "send",
// "wait", or why the paste is dropped. Search has closed by then and released the keyboard, so a full-attention surface open
// at a check opened after the choice: the paste is dropped, as for a lock or the target closing.
function pasteStep(s) {
    if (mayPaste(s))
        return "send";
    if (!s || s.locked !== false || s.helperLocked !== false)
        return "locked";
    if (s.ownsItem !== true)
        return "the clipboard changed";
    if (s.closedSinceOpen !== false)
        return "the window closed";
    if (s.otherSurfaceOpen !== false)
        return "another surface opened";
    if (s.expired !== false)
        return "the window did not come back";
    return "wait";
}

// A window address as Hyprland names it, with or without "0x" (Minimized.normalizeAddress, the platform's one validator).
function isAddress(address) {
    return Minimized.normalizeAddress(address) !== "";
}

// The address as the service keeps it: lower-case hex without 0x, "" when invalid.
function addressHex(address) {
    return Minimized.normalizeAddress(address || "");
}

// The Lua function Hyprland runs for a paste (Quickshell sends it as `return hl.dispatch(<request>)`, the Zoom.js pattern). It
// checks, in the same compositor call, that the active window is still the remembered address (compared without "0x" and in
// lower case, whichever form Hyprland's Lua gives), then sends that window Ctrl+V (Ctrl+Shift+V when its class passes
// forwarding.lua's terminal test) by `address:0x<hex>`, the selector Minimized.js uses. The key up's timer is armed before the
// key down is sent, in the same call, and is unconditional: a V that went down is always released in the window that got it.
// "" for an invalid address.
function pasteRequest(address) {
    const hex = Minimized.normalizeAddress(address);
    if (hex === "")
        return "";
    const quote = s => "\"" + s + "\"";
    const classes = "{ " + TERMINAL_CLASSES.map(quote).join(", ") + " }";
    const prefixes = "{ " + TERMINAL_PREFIXES.map(p => quote(p.replace(/\./g, "%."))).join(", ") + " }";
    const target = quote("address:0x" + hex);
    return "function() "
        + "local w = hl.get_active_window(); "
        + "if not w or (string.lower(tostring(w.address or \"\")):gsub(\"^0x\", \"\")) ~= " + quote(hex) + " then return end; "
        + "local c = (w.class or \"\"):lower(); local terminal = false; "
        + "for _, n in ipairs(" + classes + ") do if c == n then terminal = true end end; "
        + "for _, p in ipairs(" + prefixes + ") do if c:find(\"^\" .. p) then terminal = true end end; "
        + "local mods = terminal and \"CTRL SHIFT\" or \"CTRL\"; "
        + "hl.timer(function() hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = \"V\", state = \"up\", window = " + target + " })) end, "
        + "{ timeout = 50, type = \"oneshot\" }); "
        + "hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = \"V\", state = \"down\", window = " + target + " })) "
        + "end";
}
