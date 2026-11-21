.pragma library

// The file the shell writes so that the Grassfield apps know which window to draw as key (ADR-0039 step 17; the integrator's
// macOS decision on #88): a window keeps its key look while a shell menu or the Control Center holds the keyboard, and only
// another window taking the focus makes it inactive. Hyprland withdraws the window's activation as soon as a shell layer takes
// the keyboard, so the app cannot tell a menu from another window by itself. Pure functions, unit-tested
// (tests/unit/tst_keywindowfile.qml); shell/services/KeyWindow.qml writes the file, apps/keywindow.h reads it.
//
//   {"v":1,"pid":1234,"appId":"org.grassfield.Settings"}   the client whose last focused window looks key
//   {"v":1,"pid":0,"appId":""}                             nobody (another shell surface or the desktop has the keyboard)
//
// pid is 0 while Hyprland's window data does not have it yet: the app id names the client then.

var VERSION = 1;

var none = Object.freeze({pid: 0, appId: ""});

// $GRASSFIELD_STATE_HOME/keywindow.json in a dev session, else $XDG_RUNTIME_DIR/grassfield/keywindow.json (per session, gone
// at logout; in Grassfield's own runtime folder, so the apps watch that folder and not all of $XDG_RUNTIME_DIR: apps-misc H1).
// "" when neither directory is known.
function path(stateHome, runtimeDir) {
    if (stateHome)
        return String(stateHome) + "/keywindow.json";
    if (runtimeDir)
        return String(runtimeDir) + "/grassfield/keywindow.json";
    return "";
}

// The folder of path() that the shell makes, private (0700, as the menu bridge, the prompter, the security process and the
// capture make it), before the first write: "" in a dev session (the state folder is the dev session's own).
function runtimeFolder(stateHome, runtimeDir) {
    if (stateHome || !runtimeDir)
        return "";
    return String(runtimeDir) + "/grassfield";
}

// A client: a positive integer pid (else 0) and a string app id (else "").
function client(pid, appId) {
    return {
        pid: typeof pid === "number" && isFinite(pid) && pid > 0 ? Math.floor(pid) : 0,
        appId: typeof appId === "string" ? appId : ""
    };
}

function isNone(c) {
    return !c || (c.pid === 0 && c.appId === "");
}

// The surfaces holding the keyboard (FocusReturn's holder names) leave the key look where it was: the Overlay's popup alone
// ("popup") while it shows a menu, a status menu, the Control Center or a popover (any kind it draws but a dialog: an alert or
// a sheet is a window of its own, as on macOS).
function keepsLook(holders, popupKind, kinds, dialogs) {
    if (!Array.isArray(holders) || holders.length === 0 || !holders.every(h => h === "popup"))
        return false;
    return kinds.indexOf(popupKind) >= 0 && dialogs.indexOf(popupKind) < 0;
}

// What KeyWindow.qml keeps between events, {opener, kept, returning}:
//  - opener: the front client when the first surface opened (taken before the compositor moves the keyboard to it);
//  - kept: whether the surfaces holding the keyboard keep the look (keepsLook), as last known: a closing popup (its kind
//    cleared, its holder not released yet) keeps the value it had;
//  - returning: the surfaces that kept it closed and no window is focused again yet (FocusReturn gives the opener the keyboard
//    back after the surface's release hold): the opener stays key meanwhile, at most focusReturn.menuActionWaitMs.
var start = Object.freeze({opener: none, kept: false, returning: false});

// The holders changed (`front`: the focused client now).
function holdersChanged(l, holders, front, popupKind, kinds, dialogs) {
    if (holders.length > 0) {
        const opener = !l.returning && isNone(l.opener) ? front : l.opener;
        return kindChanged({opener: opener, kept: l.kept, returning: false}, holders, popupKind, kinds, dialogs);
    }
    return l.kept ? {opener: l.opener, kept: true, returning: true} : start;
}

// The Overlay's popup changed kind (or the holders changed): `kept` follows, but for a closing popup.
function kindChanged(l, holders, popupKind, kinds, dialogs) {
    if (holders.length === 0 || (holders.indexOf("popup") >= 0 && popupKind === ""))
        return l;
    return {opener: l.opener, kept: keepsLook(holders, popupKind, kinds, dialogs), returning: l.returning};
}

// A window is focused again (or the bound ran out: `front` none, `timedOut`): the return is over.
function frontChanged(l, front, timedOut) {
    return l.returning && (timedOut || !isNone(front)) ? start : l;
}

// The client drawn as key. s: {locked, holders, keeps (the latch's kept), front, opener, returning}.
//  - the session lock: nobody;
//  - no shell surface holds the keyboard: the focused window's client (`front`, none while the desktop has the keyboard), or,
//    in the moment after a menu closed (`returning`) and before a window is focused again, the menu's opener still;
//  - a menu holds it: the client that was key when the first surface opened (`opener`);
//  - any other surface (Spotlight, the app switcher, Notification Center, a dialog): nobody.
function keyClient(s) {
    if (s.locked)
        return none;
    if (s.holders.length > 0)
        return s.keeps ? s.opener : none;
    return s.returning && isNone(s.front) ? s.opener : s.front;
}

// The file's text.
function payload(c) {
    const k = isNone(c) ? none : client(c.pid, c.appId);
    return JSON.stringify({v: VERSION, pid: k.pid, appId: k.appId}) + "\n";
}
