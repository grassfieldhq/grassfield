#!/usr/bin/env bash
# GF-AUDIT-001 GF-116 (DT-08), static part: while the session is locked no shell surface opens, whichever path asks.
# The runtime part runs the real controllers offscreen (tests/security/lock_surfaces/shell.qml: Search, Apps, Notification
# Center, Overview, every Popups kind). This script checks, in the sources, what offscreen cannot run:
#   wiring    shell.qml mirrors LockClient.locked (the security process's published state read fail closed, ADR-0041
#             step 1, S2) into SessionState.locked; Overview, Switcher, the capture toolbar and the wallpaper get it;
#   refusal   each surface's entry point refuses while locked as its first decision: Popups.open, Search.show,
#             AppsController.show, Overview.show, Notifications.toggleCenter/openWidgetGallery, Dock.enterKeyboardMode,
#             the four window commands (IPC target "windows"), Switcher.step, the exit cover (ExitCover.cover), Emoji &
#             Symbols (Emoji.toggle, and Emoji.place once the pointer's answer came), the capture toolbar (Capture.show,
#             and the capture it triggered once the toolbar is gone);
#   closing   each surface closes when the lock engages (Popups, Search, Apps, Notification Center, Overview, Dock keyboard
#             mode, Switcher, the capture toolbar);
#   routes    every IPC action that opens a surface goes through that entry point (search toggle, apps toggle/open,
#             overview toggle/open, notifications toggleCenter, menubar open/panel, dock keyboard), and the screen corners
#             call those IPC actions;
#   polkit    a polkit sheet that arrives while locked is neither mapped nor given the keyboard until the unlock; a request
#             the user cannot see (locked, saver, waiting, replaced) is refused once PAM talks without asking (ADR-0045 OC-6);
#             since ADR-0041 S3 the agent runs in the security process and reads the session from SheetSession, which the
#             host binds from that process's lock and idle;
#   saver     SheetSession.saverShown has one writer, the host's Binding from idle's count of the saver (ADR-0032, S3);
#   fingerprint  the lock's only fingerprint unlock is fingerprintPam's PamResult.Success; its pacing (Omarchy v4.5.0 review:
#             backoff, no attempt while the displays are off, resume) never unlocks and reads or logs nothing of the
#             conversation; MaxTries keeps the reader off until LOCKED anew.
# Self-test: the checker fails on a copy of the tree with one refusal removed (mutation). Plain shell test: PASS/FAIL lines.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
pass() { echo "PASS: lock surfaces $*"; }
bad() { echo "FAIL: lock surfaces $*"; fail=1; }
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/lock-surfaces.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/check.py" <<'PY'
import re, sys

root = sys.argv[1]
problems, oks = [], []

def read(path):
    with open(f"{root}/{path}", encoding="utf-8") as f:
        return f.read()

def block_after(text, start):
    # The text between the first "{" at or after `start` and its matching "}" (comments and strings are rare enough here).
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i + 1:j]
    raise ValueError("unbalanced")

def function(text, name):
    m = re.search(r"\bfunction\s+" + re.escape(name) + r"\s*\(", text)
    return block_after(text, m.end()) if m else None

def ipc(text, target):
    m = re.search(r'IpcHandler\s*\{\s*target:\s*"' + re.escape(target) + '"', text)
    return block_after(text, m.start()) if m else None

def code(body):
    return "\n".join(l.split("//", 1)[0] for l in body.split("\n"))

def expect(what, ok):
    (oks if ok else problems).append(what)

def first_decision(path, name, needle, text=None, lines=4):
    body = function(text if text is not None else read(path), name)
    if body is None:
        expect(f"{path}: function {name} exists", False)
        return
    head = "\n".join(l for l in code(body).split("\n") if l.strip())
    head = "\n".join(head.split("\n")[:lines])
    expect(f"{path}: {name}() refuses while locked first ({needle})", needle in head)

shell = read("shell/shell.qml")
expect("shell.qml binds SessionState.locked to LockClient.locked (ADR-0041 S2: the lock lives in the security process)",
       re.search(r"Binding\s*\{\s*target:\s*SessionState\s*property:\s*\"locked\"\s*value:\s*LockClient\.locked\s*\}", shell) is not None
       and len(re.findall(r"property:\s*\"locked\"", code(shell))) == 1)
expect("shell.qml gives the Overview the lock state", re.search(r"Overview\s*\{[^}]*locked:\s*SessionState\.locked\s", shell, re.S) is not None)
expect("shell.qml gives the Switcher the lock state", re.search(r"Switcher\s*\{[^}]*locked:\s*SessionState\.locked\s", shell, re.S) is not None)
expect("shell.qml gives the wallpaper the lock state", re.search(r"Wallpaper\s*\{[^}]*locked:\s*SessionState\.locked\s", shell, re.S) is not None)
expect("shell.qml imports neither the lock nor idle (ADR-0041 S2: they run in the security process only)",
       re.search(r"^\s*import\s+qs\.security\.(lock|idle)\b", code(shell), re.M) is None
       and re.search(r"\bLock\.|\bIdle\s*\{|\bSleepInhibitor\b", code(shell)) is None)

state = read("shell/services/SessionState.qml")
refuses = function(state, "refuses")
expect("SessionState.refuses() returns true while locked", refuses is not None and re.search(r"if\s*\(!locked\)\s*return false;", refuses) is not None and "return true;" in refuses)

# ADR-0041 S2 (the opus review of 77a0ceb3, MAJOR-1): a lock request always ends in a locked session. The paths that only
# lock or end the session (the Grassfield menu, its session confirmations, Search with its Lock Screen command, the lock
# corner) ask SessionState.refusesConfirmed, which refuses only while the lock is confirmed (shell.qml binds lockConfirmed to
# LockClient.lockConfirmed); every other surface keeps SessionState.refuses.
confirmed = function(state, "refusesConfirmed")
expect("SessionState.refusesConfirmed() opens only while locked without a confirmed lock, else asks refuses()",
       confirmed is not None and re.fullmatch(r"\s*if\s*\(!locked\s*\|\|\s*!lockConfirmed\)\s*return false;\s*return refuses\(surface\);\s*", code(confirmed)) is not None)
expect("SessionState.lockConfirmed is true by default (a harness that sets locked gets every refusal)",
       re.search(r"^\s*property bool lockConfirmed: true$", state, re.M) is not None)
expect("shell.qml binds SessionState.lockConfirmed to LockClient.lockConfirmed, once",
       re.search(r"Binding\s*\{\s*target:\s*SessionState\s*property:\s*\"lockConfirmed\"\s*value:\s*LockClient\.lockConfirmed\s*\}", shell) is not None
       and len(re.findall(r"property:\s*\"lockConfirmed\"", code(shell))) == 1)
R = "SessionState.refuses("
first_decision("shell/services/Popups.qml", "open", 'if (PopupKinds.endsOrLocks(popupKind, payload) ? SessionState.refusesConfirmed("popup " + popupKind) : SessionState.refuses("popup " + popupKind))', lines=1)
kinds_js = read("shell/services/PopupKinds.js")
expect("PopupKinds.endsOrLocks: the Grassfield menu, and a confirmation of logout, restart or shutdown only",
       'const sessionActions = ["logout", "restart", "shutdown"];' in kinds_js
       and re.search(r'if \(kind === "system"\)\s*return true;\s*return kind === "confirm" && payload !== null && typeof payload === "object" && sessionActions\.indexOf\(payload\.action\) >= 0;', code(function(kinds_js, "endsOrLocks") or "")) is not None)
first_decision("shell/search/Search.qml", "show", 'SessionState.refusesConfirmed("search")', lines=1)
first_decision("shell/search/Search.qml", "enterClipboard", R, lines=1)
first_decision("shell/launchpad/AppsController.qml", "show", R)
first_decision("shell/overview/Overview.qml", "show", R)
first_decision("shell/notifications/Notifications.qml", "openWidgetGallery", R)
first_decision("shell/dock/Dock.qml", "enterKeyboardMode", R)
first_decision("shell/dock/Dock.qml", "reopen", R, lines=1)
# ADR-0040 step 7 (the integrator's review of e067f26f, NIT): the exit cover stays down while locked.
first_decision("shell/overlay/ExitCover.qml", "cover", R, lines=1)
# ADR-0045 OC-3: Emoji & Symbols (Ctrl+Super+Space) asks nothing and opens nothing while locked (a close comes before the
# refusal: closing is always allowed), and the pointer's answer opens it only when the session is still unlocked.
first_decision("shell/services/Emoji.qml", "toggle", R, lines=8)
emoji = read("shell/services/Emoji.qml")
expect("shell/services/Emoji.qml: place() opens nothing once the session locked", re.search(r"if\s*\(SessionState\.locked\)\s*return;[\s\S]*Popups\.open", code(function(emoji, "place") or "")) is not None)
# ADR-0045 OC-1 (opus security review of e3542510, MINOR-3): the capture toolbar (Shift-Super-5, IPC capture toggle) refuses
# while locked as its first decision, closes when the lock comes (shell.qml gives it the lock state), and the capture it
# triggered runs only if the session is still unlocked once the toolbar is gone.
first_decision("shell/capture/Capture.qml", "show", R, lines=1)
capture = read("shell/capture/Capture.qml")
expect("shell.qml gives the capture toolbar the lock state", re.search(r"\bCapture\s*\{\s*id:\s*captureSurface\s*locked:\s*SessionState\.locked\s*\}", code(shell)) is not None)
expect("shell/capture/Capture.qml: toggle() opens only through show()", re.search(r"^\s*else\s+show\(\);\s*$", code(function(capture, "toggle") or ""), re.M) is not None
       and "open = true" not in code(function(capture, "toggle") or ""))
expect("shell/capture/Capture.qml: the capture runs only if the session is still unlocked when the toolbar is gone",
       re.search(r"id:\s*launch\b[\s\S]*?onTriggered:\s*\{[^}]*?if\s*\(args\s*&&\s*!SessionState\.locked\)\s*CaptureState\.run\(args\);", code(capture)) is not None
       and len(re.findall(r"CaptureState\.run\(", code(capture))) == 1)
expect("shell/capture/Capture.qml: only show() opens the toolbar (one open = true)", len(re.findall(r"\bopen\s*=\s*true\b", code(capture))) == 1
       and re.search(r"\bopen\s*=\s*true\b", code(function(capture, "show") or "")) is not None)
# Opus re-review of the ADR-0045 security fixes (MINOR): the toolbar's per-display keyboard hand-over maps a surface as
# Exclusive, which takes the keyboard from a polkit or secret sheet open over it. While SessionState.authorizing nothing is
# made Exclusive: the toolbar asks for the keyboard only through holdsKeyboard, which is set true in followKeyboard after the
# sheet check and by the hand-over Timer only without a sheet; a sheet opening stops a hand-over under way.
toolbar = code(read("shell/capture/CaptureToolbar.qml"))
follow = code(function(toolbar, "followKeyboard") or "")
expect("shell/capture/CaptureToolbar.qml: no keyboard hand-over and no Exclusive mapping while a security sheet is open",
       # The guard covers the key sinks' linger too (opus re-review 2, MINOR-3): SessionState.securityKeyboard, bound in shell.qml.
       # Since ADR-0041 S3 the sheets run in the security process, which publishes it with the lock state (Lock.securityKeyboard,
       # the host's Binding); the UI reads it fail closed (LockClient.securityKeyboard: true without a fresh state).
       re.search(r"readonly property bool sheetOpen:\s*SessionState\.securityKeyboard\s*\n", toolbar) is not None
       and re.search(r"Binding\s*\{\s*target:\s*SessionState\s*property:\s*\"securityKeyboard\"\s*value:\s*LockClient\.securityKeyboard\s*\}", code(shell)) is not None
       and len(re.findall(r"\"securityKeyboard\"", code(shell))) == 1
       and re.search(r"readonly property bool securityKeyboard:\s*authAgent\.queuePresent\s*\|\|\s*"
                     r"secretAgent\.requestActive\s*\|\|\s*secretAgent\.sinkingKeys\s*\n", code(read("shell/security/host/SheetHost.qml"))) is not None
       and re.search(r"Binding\s*\{\s*target:\s*Lock\s*property:\s*\"securityKeyboard\"\s*value:\s*root\.sheets\s*!==\s*null\s*&&\s*root\.sheets\.securityKeyboard\s*===\s*true\s*\}", read("shell/security/host/SecurityHost.qml")) is not None
       and re.search(r"readonly property bool securityKeyboard:\s*LockState\.uiSheet\(root\.known,\s*root\.stale,\s*root\.last,\s*\"securityKeyboard\"\)", code(read("shell/services/LockClient.qml"))) is not None
       and re.search(r"readonly property bool queuePresent:\s*agent\.isActive\s*\|\|\s*root\.requestOpen\s*\|\|\s*root\.sinkingKeys\s*\n", code(read("shell/security/polkit/AuthAgent.qml"))) is not None
       and len(re.findall(r"WlrKeyboardFocus\.Exclusive", toolbar)) == 1
       and re.search(r"keyboardFocus:\s*holdsKeyboard\s*\?\s*WlrKeyboardFocus\.Exclusive\s*:\s*WlrKeyboardFocus\.None", toolbar) is not None
       and len(re.findall(r"\bholdsKeyboard\s*=\s*(?!=)", toolbar)) == 6
       and len(re.findall(r"\bholdsKeyboard\s*=\s*true\b", toolbar)) == 1
       and re.search(r"if\s*\(win\.sheetOpen\)\s*\{\s*win\.holdsKeyboard\s*=\s*false;\s*return;\s*\}[\s\S]*win\.holdsKeyboard\s*=\s*true;", follow) is not None
       and re.search(r"onTriggered:\s*\{\s*win\.holdsKeyboard\s*=\s*win\.wantsKeyboard\s*&&\s*!win\.sheetOpen;", toolbar) is not None
       and re.search(r"onSheetOpenChanged:\s*\{\s*if\s*\(sheetOpen\)\s*\{\s*keyHandover\.stop\(\);\s*if\s*\(win\.remapping\)\s*\{\s*win\.remapping\s*=\s*false;\s*win\.holdsKeyboard\s*=\s*false;\s*\}\s*\}\s*else\s*\{\s*win\.followKeyboard\(true\);\s*\}", toolbar) is not None
       and re.search(r"onWantsKeyboardChanged:\s*win\.followKeyboard\(false\)", toolbar) is not None)
toggle = function(read("shell/notifications/Notifications.qml"), "toggleCenter") or ""
opening = code(toggle).split("closeCenter();", 1)[-1]
expect("shell/notifications/Notifications.qml: toggleCenter() refuses before it opens", R in opening and opening.index(R) < opening.index("centerOpen = true"))
compositor = read("shell/platform/Compositor.qml")
windows = ipc(compositor, "windows")
for name in ("minimize", "tile", "arrange", "tilePopover", "nextOutput", "hide", "cycleApp"):
    first_decision("shell/platform/Compositor.qml", f"windows.{name}", R) if windows is None else first_decision("shell/platform/Compositor.qml", name, R, text=windows, lines=2)
# The plugin's minimize-request event (the titlebar button and, since GF-056 P8, a tagged window's own minimize button)
# moves nothing behind the lock either.
first_decision("shell/platform/Compositor.qml", "minimizeByAddress", R, text=compositor, lines=2)
# Tiling step 3 (integrator review of 4ead6fb): the plugin's hover event and Super+Ctrl+L open the popover only through here.
first_decision("shell/services/TilingHover.qml", "show", R)
# Tiling step 4a: the suggestions that follow a layout or an arrangement open only through here.
first_decision("shell/services/TilingSuggest.qml", "show", R)
# Tiling step 4b (integrator review of cd74af2): a tile group comes forward only through Compositor.groupForward, which
# refuses while locked; a menu's window row or Show Tile Group runs after the menu's surface is gone, and refuses then if
# the lock engaged meanwhile (a restore is not refused while locked, GF-116).
first_decision("shell/platform/Compositor.qml", "groupForward", R, text=compositor, lines=1)
# Tiling step 5: Show Tile Group brings the group forward through groupFront whatever "Bring tile groups forward together"
# says (groupForward's switch is not its gate); it refuses first too.
first_decision("shell/platform/Compositor.qml", "groupFront", R, text=compositor, lines=1)
first_decision("shell/platform/Compositor.qml", "runPendingActivation", R, text=compositor, lines=4)
# Tiling step 6a (TL33): Full Screen › Left or Right of Screen and a Split View window's Exit Full Screen move windows and
# show a Desktop; both refuse first (the plugin refuses them while locked too). A Split View whose picker ended without a
# second window fills through fillAlone and tile, which both refuse first (integrator review of c7a6b6e, MAJOR 2), and
# TilingSuggest sends nothing while locked (it acts at the unlock).
first_decision("shell/platform/Compositor.qml", "split", R, text=compositor, lines=1)
first_decision("shell/platform/Compositor.qml", "unsplit", R, text=compositor, lines=1)
first_decision("shell/platform/Compositor.qml", "tile", R, text=compositor, lines=1)
first_decision("shell/platform/Compositor.qml", "fillAlone", R, text=compositor, lines=1)
def calls(path, name, pattern, text=None):
    body = function(text if text is not None else read(path), name) if name else (text if text is not None else read(path))
    expect(f"{path}: {name or 'the file'} goes through {pattern}", body is not None and re.search(pattern, code(body)) is not None)
# Only a window in a group of the last reply sends group_front (integrator NIT on PR #38).
calls("shell/platform/Compositor.qml", "groupFront", r"WindowTiling\.membersOf\(TilingLink\.groups, address\)\.length === 0", compositor)
calls("shell/platform/Compositor.qml", "activateWithGroup", r"groupForward\(addressOf\(toplevel\)\)", compositor)
calls("shell/platform/Compositor.qml", "unminimizeWithGroup", r"groupForward\(addressOf\(toplevel\)\)", compositor)
calls("shell/platform/Compositor.qml", "groupForward", r"return groupFront\(address\)", compositor)
calls("shell/platform/Compositor.qml", "showTileGroup", r"groupFront\(step\.address\)", compositor)
calls("shell/platform/Compositor.qml", "fillAlone", r"return root\.tile\(toplevel, \"fill\"\)", compositor)
calls("shell/services/TilingSuggest.qml", "", r"readonly property var lonely: SessionState\.locked \? \[\] : WindowTiling\.lonelyMembers\(")
calls("shell/platform/Compositor.qml", "runPendingActivation", r"showTileGroup\(p\.toplevel, p\.members\)[\s\S]*activateWithGroup\(p\.toplevel\)", compositor)
calls("shell/dock/Dock.qml", "", r"Compositor\.groupForward\(Compositor\.addressOf\(plan\[plan\.length - 1\]\)\)")
calls("shell/dock/Dock.qml", "", r"Compositor\.unminimizeWithGroup\(item\.toplevel\)")
calls("shell/switcher/Switcher.qml", "activateTarget", r"Compositor\.activateWithGroup\(main\)")
calls("shell/menubar/AppMenus.qml", "", r"case \"window\":\s*FocusReturn\.skip\(\);\s*Compositor\.activateWithGroup\(item\.ref\)")
calls("shell/overlay/DockMenu.qml", "", r"Compositor\.activateAfterLayer\(item\.ref, \"grassfield-overlay\"\)")
calls("shell/overlay/DockMenu.qml", "", r"Compositor\.showTileGroupAfterLayer\(item\.ref, \"grassfield-overlay\", item\.members\)")
calls("shell/overview/Overview.qml", "closeAnd", r"if \(target\.kind === \"window\" && !locked\)\s*Compositor\.groupForward\(target\.address\)")
# The group forward follows the window's focus request, as from the other entry points (#38's first NIT; integrator review
# of a6d04df: untested): no group_front before overview_focus in closeAnd.
calls("shell/overview/Overview.qml", "closeAnd",
      r"^(?:(?!Compositor\.groupForward)[\s\S])*Compositor\.overviewFocus\(target\)[\s\S]*Compositor\.groupForward\(target\.address\)")
calls("shell/overview/Overview.qml", "", r"if \(restore && !locked\)\s*Compositor\.unminimizeWithGroup\(restore\)")
first_decision("shell/switcher/Switcher.qml", "step", "if (locked)", lines=8)
# Review of 1d2c856: the desktop's context menu, its attribution card and the widget menu (an Overlay layer with the
# keyboard) also refuse and close.
first_decision("shell/desktop/IconsView.qml", "openMenu", R)
first_decision("shell/desktop/IconsView.qml", "openAbout", R)
widgets = code(read("shell/desktop/DesktopWidgets.qml"))
m = re.search(r"onMenuRequested:\s*\(px, py\)\s*=>\s*\{", widgets)
expect("shell/desktop/DesktopWidgets.qml: the widget menu refuses while locked first", m is not None and R in "\n".join(l for l in block_after(widgets, m.start()).split("\n") if l.strip())[:200])

# Closing when the lock engages.
def closes(path, pattern, what):
    expect(f"{path}: {what}", re.search(pattern, code(read(path)), re.S) is not None)
closes("shell/services/Popups.qml", r"target:\s*SessionState.*?onLockedChanged.*?if\s*\(SessionState\.locked\)\s*root\.close\(\)", "closes when the session locks")
closes("shell/search/Search.qml", r"target:\s*SessionState.*?onLockedChanged.*?SessionState\.locked.*?root\.hide\(\)", "closes when the session locks")
closes("shell/launchpad/AppsController.qml", r"target:\s*SessionState.*?onLockedChanged.*?SessionState\.locked.*?root\.hide\(\)", "closes when the session locks")
closes("shell/notifications/Notifications.qml", r"onSessionLockedChanged:.*?sessionLocked\s*&&\s*centerOpen.*?closeCenter\(\)", "closes the Center when the session locks")
closes("shell/overview/Overview.qml", r"onLockedChanged:.*?if\s*\(locked\)\s*requestCloseForOther\(\)", "closes when the session locks")
closes("shell/dock/Dock.qml", r"target:\s*SessionState.*?onLockedChanged.*?SessionState\.locked.*?keyboardMode\s*=\s*false", "leaves keyboard mode when the session locks")
closes("shell/switcher/Switcher.qml", r"onLockedChanged:.*?if\s*\(locked\)\s*cancel\(\)", "ends when the session locks")
closes("shell/desktop/IconsView.qml", r"target:\s*SessionState.*?onLockedChanged.*?SessionState\.locked.*?root\.closeMenu\(\"outside\"\).*?root\.closeAbout\(\"outside\"\)", "closes its menu and card when the session locks")
closes("shell/desktop/DesktopWidgets.qml", r"target:\s*SessionState.*?onLockedChanged.*?SessionState\.locked.*?scope\.closeMenu\(\)", "closes the widget menu when the session locks")
closes("shell/services/Emoji.qml", r"target:\s*SessionState.*?onLockedChanged.*?root\.placing\s*=\s*false;.*?root\.cancelInsert\(\"locked\"\)", "stops placing the panel and drops a waiting insertion when the session locks")
closes("shell/capture/Capture.qml", r"onLockedChanged:\s*\{\s*if\s*\(locked\)\s*hide\(\);\s*\}", "closes the toolbar when the session locks")

# IPC actions route through the refusing entry points.
def route(path, target, name, pattern):
    handler = ipc(read(path), target)
    body = function(handler, name) if handler else None
    expect(f"IPC {target} {name} goes through {pattern}", body is not None and re.search(pattern, code(body)) is not None)
route("shell/search/Search.qml", "search", "toggle", r"root\.toggle\(\)")
route("shell/search/Search.qml", "search", "open", r"root\.show\(")
route("shell/search/Search.qml", "search", "clipboard", r"root\.toggleClipboard\(\)")
route("shell/launchpad/AppsController.qml", "apps", "toggle", r"root\.toggle\(\)")
route("shell/launchpad/AppsController.qml", "apps", "open", r"root\.show\(\)")
route("shell/overview/Overview.qml", "overview", "toggle", r"root\.toggle\(\)")
route("shell/overview/Overview.qml", "overview", "open", r"root\.show\(\)")
route("shell/notifications/Notifications.qml", "notifications", "toggleCenter", r"root\.toggleCenter\(")
route("shell/menubar/MenuBar.qml", "menubar", "open", r"bar\.popup\(")
route("shell/menubar/MenuBar.qml", "menubar", "panel", r"Popups\.open\(")
route("shell/dock/Dock.qml", "dock", "keyboard", r"root\.enterKeyboardMode\(\)")
route("shell/services/Emoji.qml", "emoji", "toggle", r"root\.toggle\(\)")
route("shell/capture/Capture.qml", "capture", "toggle", r"root\.toggle\(\)")
route("shell/capture/Capture.qml", "capture", "open", r"root\.show\(\)")
search =read("shell/search/Search.qml")
expect("Search.toggle() opens only through show()", re.search(r"else\s+show\(", code(function(search, "toggle") or "")) is not None)
expect("Search.toggleClipboard() opens only through show()", re.search(r"if\s*\(!open\)\s*show\(", code(function(search, "toggleClipboard") or "")) is not None
       and re.search(r"\bview\s*=", code(function(search, "toggleClipboard") or "")) is None)
apps = read("shell/launchpad/AppsController.qml")
expect("AppsController.toggle() opens only through show()", re.search(r"else\s+show\(\)", code(function(apps, "toggle") or "")) is not None)
overview = read("shell/overview/Overview.qml")
expect("Overview.toggle() opens only through show()", re.search(r"else\s+show\(\)", code(function(overview, "toggle") or "")) is not None)
popups = read("shell/services/Popups.qml")
for name in ("toggle", "openCentered"):
    expect(f"Popups.{name}() opens only through open()", re.search(r"\bopen\(", code(function(popups, name) or "")) is not None and "kind = " not in code(function(popups, name) or ""))
corners = read("shell/desktop/HotCornerActions.js")
expect("screen corners call the IPC actions (overview toggle, apps toggle) or Notifications.toggleCenter",
       '["overview", "toggle"]' in corners and '["apps", "toggle"]' in corners and '"notifications"' in corners)

# Polkit: held behind the lock.
agent = code(read("shell/security/polkit/AuthAgent.qml"))
arrive = code(function(agent, "arrive") or "")
expect("polkit sheet: shown only while active and unlocked", re.search(r"property bool shown:\s*dialogModel\.active\s*&&\s*!SheetSession\.locked", agent) is not None)
# Check of c1ca44f (M1): `visible` and `takesKeys` read the base state only; through `shown` or `lingering` one went false for
# a moment when a request ended while the sink had the keys, and a hidden PanelWindow is destroyed and made again.
# Security counter-review of f9e24e1 (LOW-1): they read the agent's `requestOpen`, which only arrive writes (after the sink at
# an end), never the model's `active`: a request that ends unanswered under the user's typing never unmaps the window before
# the sink holds the keys.
notice_m = re.search(r"\bMaterial\s*\{\s*id:\s*endedNotice\b", agent)
notice = block_after(agent, notice_m.start()) if notice_m else ""
window_props = agent.replace(notice, "") if notice else agent
expect("polkit sheet: mapped only when a request is open, or while the sink lingers (never while locked), from the base state",
       re.search(r"\bvisible:\s*!SheetSession\.locked\s*&&\s*\(root\.requestOpen\s*\|\|\s*root\.sinkingKeys\)\s*\n", agent) is not None
       and re.search(r"property bool lingering:\s*root\.sinkingKeys\s*&&\s*!dialogModel\.active\s*&&\s*!SheetSession\.locked\s*\n", agent) is not None)
expect("polkit sheet: takes the keyboard only when a request is open and not held, or for the sink, from the base state", re.search(r"keyboardFocus:\s*win\.takesKeys\s*\?\s*WlrKeyboardFocus\.Exclusive", agent) is not None
       and re.search(r"property bool takesKeys:\s*!SheetSession\.locked\s*&&\s*\(\(root\.requestOpen\s*&&\s*\(!root\.heldByLock\s*\|\|\s*root\.userFocused\)\)\s*\|\|\s*root\.sinkingKeys\)\s*\n", agent) is not None
       and notice != "" and not re.search(r"\b(?:visible|takesKeys):[^\n]*\b(?:shown|lingering|dialogModel\.active)\b", window_props))
expect("polkit sheet: requestOpen is written only by arrive, after the sink, false before the hold changes at an end and true after it at an arrival",
       len(re.findall(r"\brequestOpen\s*=(?!=)", agent)) == 2 and len(re.findall(r"\brequestOpen\s*=(?!=)", arrive)) == 2
       and re.search(r"^\s*property bool requestOpen:\s*false\s*$", agent, re.M) is not None
       and re.search(r"root\.sinkingKeys\s*=\s*typing;\s*if\s*\(!dialogModel\.active\)\s*root\.requestOpen\s*=\s*false;\s*root\.heldWhy\s*=[^;]*;\s*"
                     r"root\.heldByLock\s*=[^;]*;\s*root\.userFocused\s*=\s*false;\s*if\s*\(dialogModel\.active\)\s*root\.requestOpen\s*=\s*true;", arrive) is not None)
# Review of 1d2c856: a request held behind the lock takes the keyboard only after a click past the guard, never at once.
expect("polkit sheet: a held request takes the keyboard only after a click past the guard",
       re.search(r"enabled:\s*root\.heldByLock\s*&&\s*!root\.userFocused.*?if\s*\(!dialogModel\.heldClickAccepted\(\)\)\s*return;.*?root\.userFocused\s*=\s*true", agent, re.S) is not None
       and re.search(r"onShownChanged:\s*\{\s*if\s*\(shown\)\s*dialogModel\.noteShown\(\);", agent) is not None)
expect("polkit sheet: a request arriving while locked, or just after an unlock, is held",
       re.search(r"heldByLock\s*=\s*dialogModel\.active\s*&&\s*\(follows\s*\|\|\s*typing\s*\|\|\s*dialogModel\.arrivesHeld\(SheetSession\.locked\s*\|\|\s*SheetSession\.saverShown\)\);", agent) is not None
       and re.search(r"const queued\s*=\s*follows\s*\|\|\s*typing\s*\|\|\s*\(dialogModel\.active\s*&&\s*dialogModel\.followsAnother\(\)\);", arrive) is not None
       and re.search(r"if\s*\(!SheetSession\.locked\)\s*\{\s*dialogModel\.noteUnlock\(\);", agent) is not None)
# Review of 6e24d36: the unlock hold and the click guard are timed by Timers (monotonic), never by the wall clock; the
# agent reads Date.now() only for the arrival time the notice shows.
model = code(read("shell/security/polkit/AuthDialogModel.qml"))
bodies = {n: code(function(model, n) or "") for n in ("noteUnlock", "noteShown", "heldClickAccepted", "arrivesHeld", "noteUncovered", "noteEnded", "followsAnother")}
expect("polkit holds: timed by Timers, never by the wall clock",
       len(re.findall(r"\bDate\b", agent)) == 1 and re.search(r"requestStartedAt\s*=\s*dialogModel\.active\s*\?\s*new Date\(\)\s*:\s*null", agent) is not None
       and not any(re.search(r"\bDate\b", b) for b in bodies.values())
       and re.search(r"property Timer unlockHold:\s*Timer\s*\{\s*interval:\s*root\.heldAfterUnlockMs\s*\}", model) is not None
       and re.search(r"property Timer clickGuard:\s*Timer\s*\{\s*interval:\s*root\.heldGuardMs\s*\}", model) is not None
       and re.search(r"^\s*unlockHold\.restart\(\);\s*$", bodies["noteUnlock"], re.M) is not None
       and re.search(r"priv\.shown\s*=\s*true;\s*clickGuard\.restart\(\);", bodies["noteShown"]) is not None
       and re.search(r"^\s*return\s+priv\.shown\s*&&\s*!clickGuard\.running;\s*$", bodies["heldClickAccepted"], re.M) is not None
       and re.search(r"^\s*return\s+locked\s*\|\|\s*unlockHold\.running\s*\|\|\s*afterRequest\.running;\s*$", bodies["arrivesHeld"], re.M) is not None
       and re.search(r"^\s*clickGuard\.restart\(\);\s*$", bodies["noteUncovered"], re.M) is not None
       and re.search(r"property Timer afterRequest:\s*Timer\s*\{\s*interval:\s*root\.heldAfterUnlockMs\s*\}", model) is not None
       and re.search(r"^\s*afterRequest\.restart\(\);\s*$", bodies["noteEnded"], re.M) is not None
       and re.search(r"^\s*return\s+afterRequest\.running;\s*$", bodies["followsAnother"], re.M) is not None)
# Re-check of b5d7657 (MEDIUM-3): each hold Timer is used only where it is meant to be, and never from the agent.
expect("polkit holds: each Timer only in its own functions (clickGuard 4, unlockHold 3, afterRequest 4 uses), none in the agent",
       len(re.findall(r"\bclickGuard\b", model)) == 4 and len(re.findall(r"\bunlockHold\b", model)) == 3
       and len(re.findall(r"\bafterRequest\b", model)) == 4
       and not re.search(r"\b(clickGuard|unlockHold|afterRequest)\b", agent))
# ADR-0032 (owner decision 2026-10-26): the screen saver holds a request as the lock does, its waking click answers nothing,
# and the click guard starts over when it ends.
saver_hold = code(function(agent, "onSaverShownChanged") or "")
expect("polkit sheet: the screen saver takes the sink's keys, then a request open when it comes up is held, its field emptied (nothing but the lock and no request return first)",
       re.match(r"\s*if\s*\(SheetSession\.saverShown\)\s*root\.sinkingKeys\s*=\s*false;\s*if\s*\(!dialogModel\.active\s*\|\|\s*SheetSession\.locked\)\s*return;\s*if\s*\(SheetSession\.saverShown\)\s*\{", saver_hold) is not None
       and re.search(r"if\s*\(SheetSession\.saverShown\)\s*\{.*?root\.heldByLock\s*=\s*true;\s*root\.userFocused\s*=\s*false;\s*dialogModel\.clearRequested\(\);", saver_hold, re.S) is not None)
# Review of f513b3b (MEDIUM-1): the link that carries the saver's state, and who may give the keyboard or set the hold.
# ADR-0041 S3: the sheets run in the security process, which cannot see the UI's saver; idle counts the same idle time by the
# saver's rule (Idle.saverShown, IdleModel.saverArmed) and the host binds it into SheetSession.
host_src = read("shell/security/host/SecurityHost.qml")
expect("the security process's host binds SheetSession.saverShown to idle's count of the screen saver",
       re.search(r"Binding\s*\{\s*target:\s*SheetSession\s*property:\s*\"saverShown\"\s*value:\s*idle\.saverShown\s*\}", host_src) is not None
       and re.search(r"readonly property bool saverShown:\s*saverMonitor\.enabled\s*&&\s*saverMonitor\.isIdle\s*\n", code(read("shell/security/idle/Idle.qml"))) is not None)
# ADR-0032: that Binding is the only writer of SheetSession.saverShown in the shell, the apps and Grassfield.Ui: no
# assignment, no other Binding, PropertyChanges or object property, no other quoted name (setProperty and the like). A
# wrong saverShown holds every polkit request (true) or lets the sheet take the keyboard over the saver (false).
def saver_writes():
    import os
    found = []
    for top in ("shell", "apps", "ui"):
        for dirpath, dirnames, filenames in os.walk(f"{root}/{top}"):
            dirnames[:] = [d for d in dirnames if d not in (".dev", "build")]
            for name in filenames:
                if not name.endswith((".qml", ".js")):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, root)
                with open(path, encoding="utf-8", errors="replace") as f:
                    text = code(f.read())
                for m in re.finditer(r"\bsaverShown\s*=(?!=)|[\"']saverShown[\"']|\bsaverShown\s*:", text):
                    line = text[text.rfind("\n", 0, m.start()) + 1:text.find("\n", m.start()) if text.find("\n", m.start()) >= 0 else len(text)].strip()
                    if rel == "shell/security/SheetSession.qml" and re.fullmatch(r"property bool saverShown:\s*false", line):
                        continue
                    found.append(f"{rel}: {line}")
    return found
writes = saver_writes()
expect("SheetSession.saverShown has one writer, the host's Binding, from idle's own (" + "; ".join(writes) + ")",
       sorted(writes) == ['shell/security/host/SecurityHost.qml: property: "saverShown"',
                          'shell/security/idle/Idle.qml: readonly property bool saverShown: saverMonitor.enabled && saverMonitor.isIdle'])
expect("polkit sheet: only a click past the guard gives the keyboard (one userFocused = true), and an arrival, a lock and the saver take it back (three userFocused = false)",
       len(re.findall(r"userFocused\s*=\s*true", agent)) == 1 and len(re.findall(r"userFocused\s*=\s*false", agent)) == 3)
# Re-check of b5d7657 (MEDIUM-3): the sheet, then the held click's guard over it, then the saver's swallowing area on top.
order = [m.start() if m else -1 for m in (re.search(r"\bLoader\s*\{\s*id:\s*holder", agent),
                                          re.search(r"enabled:\s*root\.heldByLock\s*&&\s*!root\.userFocused", agent),
                                          re.search(r"enabled:\s*SheetSession\.saverShown", agent))]
expect("polkit sheet: the sheet, its held-click guard above it, the saver's swallowing area on top", -1 not in order and order == sorted(order))
# Re-check of b5d7657 (MEDIUM-2): a request that replaces the one being typed into keeps the keyboard on a sink, never
# handing the rest of a password to the window underneath, until a click past the guard.
# Check of 38dbfe8: `typing` is read before arrive changes what takesKeys reads (its LOW-2 M1), the sink keeps the keys when
# the request ends (MEDIUM-B) and takes back any focus while it has them (MEDIUM-A), and Esc cancels a held request (LOW-1).
expect("polkit sheet: a request replacing the one being typed into, ending unanswered while the window has the keys, or arriving or ending while the sink has them, keeps them on the sink (read first)",
       re.match(r"\s*const typing\s*=\s*\(follows\s*&&\s*win\.takesKeys\)\s*\|\|\s*root\.sinkingKeys\s*\|\|\s*\(!dialogModel\.active\s*&&\s*win\.takesKeys\s*&&\s*!dialogModel\.answered\);\s*\n", arrive) is not None
       and re.search(r"root\.sinkingKeys\s*=\s*typing;", arrive) is not None
       and re.search(r"onSinkingKeysChanged:\s*if\s*\(sinkingKeys\)\s*keySink\.forceActiveFocus\(\)", agent) is not None
       and re.search(r"Item\s*\{\s*id:\s*keySink\s*Keys\.onPressed:\s*event\s*=>\s*\{\s*event\.accepted\s*=\s*true;\s*if\s*\(root\.lingering\)\s*sinkIdle\.restart\(\);\s*"
                     r"else if\s*\(event\.key\s*===\s*Qt\.Key_Escape\)\s*dialogModel\.cancel\(\);\s*\}\s*Keys\.onReleased:\s*event\s*=>\s*event\.accepted\s*=\s*true\s*\}", agent) is not None
       # Check of c1ca44f (M2): while the sink has the keys the sheet's input is disabled and any focus it gets goes back to the
       # sink, whether or not its window has the keyboard; its focusField does nothing while the input is disabled.
       and re.search(r"inputEnabled:\s*!root\.sinkingKeys\s*onActiveFocusChanged:\s*if\s*\(activeFocus\s*&&\s*root\.sinkingKeys\)\s*keySink\.forceActiveFocus\(\)", agent) is not None
       and re.search(r"root\.userFocused\s*=\s*true;\s*root\.sinkingKeys\s*=\s*false;", agent) is not None)
expect("polkit sheet: the sink lets go only on a click past the guard, the lock, the screen saver, or the linger's click or timers (six sinkingKeys = false, one = typing)",
       len(re.findall(r"\bsinkingKeys\s*=\s*false\b", agent)) == 6 and len(re.findall(r"\bsinkingKeys\s*=(?!=)", agent)) == 7
       and re.search(r"function onLockedChanged\(\):\s*void\s*\{\s*if\s*\(!SheetSession\.locked\)\s*\{\s*dialogModel\.noteUnlock\(\);\s*return;\s*\}\s*root\.sinkingKeys\s*=\s*false;", agent) is not None)
expect("polkit sheet: the linger ends after heldAfterUnlockMs without a key or sinkLingerMaxMs, both started when it starts, neither touching a request's sink",
       len(re.findall(r"Timer\s*\{\s*id:\s*sink(?:Idle|Cap)\s*interval:\s*dialogModel\.(?:heldAfterUnlockMs|sinkLingerMaxMs)\s*onTriggered:\s*if\s*\(root\.lingering\)\s*root\.sinkingKeys\s*=\s*false\s*\}", agent)) == 2
       and re.search(r"id:\s*sinkIdle\s*interval:\s*dialogModel\.heldAfterUnlockMs\b", agent) is not None
       and re.search(r"id:\s*sinkCap\s*interval:\s*dialogModel\.sinkLingerMaxMs\b", agent) is not None
       and re.search(r"if\s*\(typing\s*&&\s*!dialogModel\.active\s*&&\s*!SheetSession\.locked\)\s*\{\s*sinkIdle\.restart\(\);\s*sinkCap\.restart\(\);\s*\}", arrive) is not None
       and "lingering" not in arrive
       and re.search(r"readonly property int sinkLingerMaxMs:\s*3000\s*\n", model) is not None)
# Security counter-review of f9e24e1 (LOW-1): `answered` is set by the user's answer only (submit, cancel), cleared when polkit
# asks again (a failure, a new prompt) and for a new request, never when a request ends (the agent reads it then); the
# agent never writes it.
expect("polkit sheet: `answered` is set by submit and cancel only, cleared on a failure, a new prompt or a new request, never at the end",
       re.search(r"readonly property bool answered:\s*priv\.answered\s*\n", model) is not None
       and len(re.findall(r"\banswered\s*=(?!=)", model)) == 5
       and len(re.findall(r"\bpriv\.answered\s*=\s*true;", model)) == 2 and len(re.findall(r"\bpriv\.answered\s*=\s*false;", model)) == 3
       and re.search(r"priv\.submitted\s*=\s*true;\s*priv\.answered\s*=\s*true;", code(function(model, "submit") or "")) is not None
       and re.search(r"priv\.answered\s*=\s*true;", code(function(model, "cancel") or "")) is not None
       and re.search(r"onFlowChanged:\s*\{\s*priv\.submitted\s*=\s*false;\s*priv\.error\s*=\s*\"\";\s*if\s*\(flow\)\s*priv\.answered\s*=\s*false;\s*clearRequested\(\);\s*\}", model) is not None
       and re.search(r"if\s*\(root\.flow\s*&&\s*root\.flow\.isResponseRequired\)\s*\{\s*root\.priv\.submitted\s*=\s*false;\s*root\.priv\.answered\s*=\s*false;\s*\}", model) is not None
       and re.search(r"function onAuthenticationFailed\(\):\s*void\s*\{\s*root\.priv\.submitted\s*=\s*false;\s*root\.priv\.answered\s*=\s*false;", model) is not None
       and not re.search(r"\banswered\s*=(?!=)", agent))
# LOW-3: the linger is shown by a card of fixed text where the sheet was, only while the sink lingers; it takes no input and no
# focus (a press goes through to the backdrop, which ends the linger) and shows nothing of the requester's.
expect("polkit sheet: the ended notice shows only while the sink lingers, fixed text, no input, no focus, nothing of the request",
       re.match(r"\s*id:\s*endedNotice\s*objectName:\s*\"polkitEndedNotice\"\s*visible:\s*root\.lingering\s*\n", notice) is not None
       and not re.search(r"MouseArea|TapHandler|Handler\s*\{|\bfocus\s*:|activeFocusOnTab|Keys\.|TextInput|TextEdit|Button|forceActiveFocus|dialogModel|model\.|\bflow\b", notice)
       and re.findall(r"\btext:\s*([^\n]*)", notice) == ['qsTr("Request cancelled")', 'qsTr("What you type is ignored for a moment.")']
       and re.findall(r"textFormat:\s*(\S+)", notice) == ["Text.PlainText", "Text.PlainText"])
dialog_src = code(read("shell/security/polkit/AuthDialog.qml"))
backdrop = re.search(r"MouseArea\s*\{\s*anchors\.fill:\s*parent\s*onPressed:\s*\{\s*if\s*\(root\.lingering\)\s*\{\s*root\.sinkingKeys\s*=\s*false;\s*return;\s*\}\s*"
                     r"const dialog\s*=\s*holder\.item as AuthDialog;\s*if\s*\(dialog\s*&&\s*win\.takesKeys\s*&&\s*!root\.sinkingKeys\)\s*dialog\.focusField\(\);\s*\}\s*\}", agent)
# ADR-0045 OC-6 (opus security review of e3542510, BLOCKER-1): the sheet's fourth site, PAM's password prompt after a device
# wait, goes through focusField (inputEnabled) and only when PAM asks (never when the request ends); the field takes no key
# while the sink has the keys or PAM awaits a device. Each site is pinned by its guard, not only counted.
expect("polkit sheet: the field is focused only where it may be (the agent: when shown unheld, a backdrop click with the keyboard and no sink, the click past the guard; the sheet: when it loads, after a failure, and when PAM's prompt follows a device wait)",
       backdrop is not None and len(re.findall(r"\.focusField\(\)", agent)) == 3
       and len(re.findall(r"\bfocusField\(\)", dialog_src)) == 4 and re.search(r"Component\.onCompleted:\s*focusField\(\)", dialog_src) is not None
       and len(re.findall(r"\bfield\.forceActiveFocus\(\)", dialog_src)) == 1 and "forceActiveFocus" not in dialog_src.replace("field.forceActiveFocus()", "", 1)
       and re.search(r"function focusField\(\):\s*void\s*\{\s*if\s*\(root\.inputEnabled\)\s*field\.forceActiveFocus\(\);\s*\}", dialog_src) is not None
       and len(re.findall(r"enabled:\s*root\.inputEnabled\b", dialog_src)) == 3 and re.search(r"id:\s*identityList\s*enabled:\s*root\.inputEnabled\b", dialog_src) is not None and re.search(r"property bool inputEnabled:\s*true\s*\n", dialog_src) is not None
       and re.search(r"id:\s*field\s*enabled:\s*root\.inputEnabled\s*&&\s*!root\.model\.awaitingDevice\s*\n", dialog_src) is not None
       and re.search(r"function onFailed\(\):\s*void\s*\{\s*shakeAnimation\.restart\(\);\s*root\.focusField\(\);\s*\}", dialog_src) is not None
       and re.search(r"function onAwaitingDeviceChanged\(\):\s*void\s*\{\s*if\s*\(!root\.model\.awaitingDevice\s*&&\s*root\.model\.responseRequired\)\s*root\.focusField\(\);\s*\}", dialog_src) is not None)
# ADR-0045 OC-6 (opus security review of e3542510, MAJOR-2): no device answers a request the user cannot see and answer.
# Quickshell runs PAM as soon as polkit asks (AuthFlow's constructor), so the model refuses the flow Quickshell has open as
# soon as PAM talks without asking while it is not answerable, whatever was sent; the agent hands it every flow (also one
# waiting behind a secret sheet) and makes it answerable only while its sheet is on screen in front (the click hold and the
# key sink do not count: integrator decision after the re-review, Remote Login and Add Printer ask several times in a row).
# A request Quickshell replaced (re-review MAJOR-1) is watched and refused, the current request first, once its PAM talks.
# The refusals are the only answers the model gives on its own (cancels: the user's, the unseen request's, the current and
# the replaced ones' of refuseReplaced; one submit, the user's).
expect("polkit sheet: a request the user cannot answer is refused as soon as PAM talks without asking (the model)",
       re.search(r"^\s*property var request:\s*null\s*$", model, re.M) is not None
       and re.search(r"^\s*property bool answerable:\s*false\s*$", model, re.M) is not None
       and re.search(r"readonly property bool refusesUnseen:\s*!answerable\s*&&\s*pamTalks\(request\)\s*\n", model) is not None
       # From the event loop, never inside the binding's own change (Quickshell ends the request inside the cancel: binding loop).
       and re.search(r"onRefusesUnseenChanged:\s*if\s*\(refusesUnseen\)\s*Qt\.callLater\(root\.refuseUnseen\)\s*\n", model) is not None
       and re.search(r"function refuseUnseen\(\):\s*void\s*\{\s*if\s*\(refusesUnseen\)\s*request\.cancelAuthenticationRequest\(\);\s*\}", model) is not None
       and len(re.findall(r"\brefuseUnseen\b", model)) == 2
       and re.search(r"function pamTalks\(f:\s*var\):\s*bool\s*\{\s*return\s+!!f\s*&&\s*f\.isResponseRequired\s*!==\s*true\s*&&\s*"
                     r"plainLine\(f\.supplementaryMessage,\s*maxDetailLength\)\s*!==\s*\"\";\s*\}", model) is not None
       and len(re.findall(r"\.cancelAuthenticationRequest\(\)", model)) == 4 and len(re.findall(r"\.submit\(", model)) == 1
       and re.search(r"\bflow\.submit\(password\);", model) is not None
       and not re.search(r"\b(?:request|answerable|refusesUnseen|replacedTalks)\s*=(?!=)", model))
replaced_body = code(function(model, "refuseReplaced") or "")
expect("polkit sheet: a request Quickshell replaced is watched and, once its PAM talks without asking, refused after the current request (the model)",
       re.search(r"readonly property bool replacedTalks:\s*liveReplaced\(\)\.some\(f\s*=>\s*pamTalks\(f\)\)\s*\n", model) is not None
       and re.search(r"onReplacedTalksChanged:\s*if\s*\(replacedTalks\)\s*Qt\.callLater\(root\.refuseReplaced\)\s*\n", model) is not None
       and re.search(r"onRequestChanged:\s*\{\s*const before\s*=\s*priv\.seen;\s*priv\.seen\s*=\s*request;\s*if\s*\(before\s*&&\s*request\s*&&\s*before\s*!==\s*request\s*&&\s*"
                     r"before\.isCompleted\s*!==\s*true\)\s*priv\.replaced\s*=\s*liveReplaced\(\)\.concat\(\[before\]\);\s*\}", model) is not None
       and re.search(r"function liveReplaced\(\):\s*var\s*\{\s*return\s+priv\.replaced\.filter\(f\s*=>\s*!!f\s*&&\s*f\.isCompleted\s*!==\s*true\);\s*\}", model) is not None
       and re.match(r"\s*if\s*\(!replacedTalks\)\s*return;\s*const replaced\s*=\s*liveReplaced\(\);\s*priv\.replaced\s*=\s*\[\];\s*"
                    r"if\s*\(request\s*&&\s*request\.isCompleted\s*!==\s*true\s*&&\s*replaced\.indexOf\(request\)\s*<\s*0\)\s*request\.cancelAuthenticationRequest\(\);\s*"
                    r"for\s*\(const f of replaced\)\s*f\.cancelAuthenticationRequest\(\);\s*$", replaced_body) is not None
       and len(re.findall(r"\bpriv\.replaced\s*=(?!=)", model)) == 2 and len(re.findall(r"\bpriv\.seen\s*=(?!=)", model)) == 1)
dialog_model_m = re.search(r"\bAuthDialogModel\s*\{\s*id:\s*dialogModel\b", agent)
dialog_model = block_after(agent, dialog_model_m.start()) if dialog_model_m else ""
# Opus re-review 2: not while the displays are off (MINOR-2; SheetSession.displaysOff, bound by the host from idle in the
# same process since ADR-0041 S3, true without the host's Binding), and a held
# request only when it is held as "right after another one" or clicked past its guard (MINOR-1: not just after an unlock).
expect("polkit sheet: the agent hands the model every flow Quickshell has open and makes it answerable only while its sheet is on screen in front (unlocked, no screen saver, displays on, not waiting, in the sheet; held only right after another one or once clicked)",
       re.search(r"^\s*request:\s*agent\.flow\s*$", dialog_model, re.M) is not None
       and re.search(r"^\s*answerable:\s*!SheetSession\.locked\s*&&\s*!SheetSession\.saverShown\s*&&\s*!SheetSession\.displaysOff\s*&&\s*!root\.waiting\s*&&\s*root\.requestOpen\s*"
                     r"&&\s*\(!root\.heldByLock\s*\|\|\s*root\.userFocused\s*\|\|\s*root\.heldWhy\s*===\s*\"queued\"\)\s*$", dialog_model, re.M) is not None
       and re.search(r"Binding\s*\{\s*target:\s*SheetSession\s*property:\s*\"displaysOff\"\s*value:\s*idle\.displayOff\s*\}", host_src) is not None
       and len(re.findall(r"\"displaysOff\"", code(host_src))) == 1
       and re.search(r"Binding\s*\{\s*target:\s*SheetSession\s*property:\s*\"locked\"\s*value:\s*Lock\.locked\s*\}", host_src) is not None
       and len(re.findall(r"\b(?:request|answerable)\s*:", agent)) == 2
       and not re.search(r"\b(?:request|answerable|refusesUnseen)\s*=(?!=)|\.cancelAuthenticationRequest\b", agent))
expect("polkit sheet: a request that comes right after another one ended is held (noteEnded when none is left)",
       re.search(r"if\s*\(!dialogModel\.active\)\s*dialogModel\.noteEnded\(\);", arrive) is not None)
expect("polkit sheet: the hold is set only on an arrival, a lock and the screen saver",
       len(re.findall(r"\bheldByLock\s*=(?!=)", agent)) == 3)
# Review of f513b3b (MEDIUM-2): a queued request that follows another in the same sheet is a new arrival, held; whether a
# request is in the sheet is a flag, never a flow read back (it reads null once destroyed; review of 9ad4307..b38618f).
flow_changed = code(block_after(agent, re.search(r"onFlowChanged:", agent).end()) if re.search(r"onFlowChanged:", agent) else "")
expect("polkit sheet: a queued request that follows another is held, emptied, its guard started over",
       re.search(r"const follows\s*=\s*root\.flowShown\s*&&\s*flow\s*!==\s*null\s*&&\s*flow\s*!==\s*root\.shownFlow;\s*root\.flowShown\s*=\s*flow\s*!==\s*null;\s*root\.shownFlow\s*=\s*flow;\s*if\s*\(follows\)\s*root\.arrive\(true\);", flow_changed) is not None
       and re.search(r"^\s*property bool flowShown:\s*false\s*$", agent, re.M) is not None
       and re.search(r"onActiveChanged:\s*root\.arrive\(false\)", agent) is not None
       and re.search(r"if\s*\(follows\)\s*\{\s*dialogModel\.clearRequested\(\);\s*dialogModel\.noteShown\(\);\s*\}", arrive) is not None)
expect("polkit sheet: the click guard starts over when the screen saver ends",
       re.search(r"else if\s*\(root\.heldByLock\)\s*\{\s*dialogModel\.noteUncovered\(\);", saver_hold) is not None)
expect("polkit sheet: a press goes nowhere while the screen saver shows",
       re.search(r"MouseArea\s*\{\s*anchors\.fill:\s*parent\s*enabled:\s*SheetSession\.saverShown\s*acceptedButtons:\s*Qt\.AllButtons\s*onPressed:\s*mouse\s*=>\s*mouse\.accepted\s*=\s*true\s*onWheel:\s*wheel\s*=>\s*wheel\.accepted\s*=\s*true\s*\}", agent) is not None)
expect("polkit sheet: a request open when the lock engages is held",
       re.search(r"root\.sinkingKeys\s*=\s*false;\s*if\s*\(dialogModel\.active\)\s*\{\s*root\.heldByLock\s*=\s*true;\s*root\.heldWhy\s*=\s*\"locked\";\s*root\.userFocused\s*=\s*false;\s*\}", agent) is not None)
expect("polkit sheet: a held request is not focused when it appears", re.search(r"if\s*\(shown\s*&&\s*!root\.heldByLock\)\s*dialog\.focusField\(\)", agent) is not None)
expect("polkit sheet: the typed text is dropped when the lock hides it", re.search(r"onShownChanged:.*?clearRequested\(\)", agent, re.S) is not None)

# Review of 2dfd992: no wall clock in shell/security. Every delay is a Qt Timer (monotonic); the only Dates left are the
# arrival times the held polkit and secret sheets print. Any other `Date` (Date.now, new Date, Date.parse), getTime, valueOf or
# performance.now in the code (comments excluded) fails.
import os
def nocomments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", l) for l in text.split("\n"))
allowed_dates = {
    "shell/security/lock/LockView.qml": ["WallClock {\n        id: clock\n    }"],
    "shell/security/polkit/AuthAgent.qml": ["root.requestStartedAt = dialogModel.active ? new Date() : null;"],
    "shell/security/polkit/AuthDialogModel.qml": ["Qt.formatTime(new Date(arrivedAt), Qt.locale().timeFormat(Locale.ShortFormat))"],
    # The secret sheets (ADR-0035 D-9, step 9b): the arrival time a held secret sheet prints, stamped once and only formatted.
    "shell/security/secret/SecretAgent.qml": ["request.arrivedAt = new Date();"],
    "shell/security/secret/SecretSheetModel.qml": ["Qt.formatTime(new Date(arrivedAt), Qt.locale().timeFormat(Locale.ShortFormat))"],
}
clock_hits = []
for base, _, files in os.walk(f"{root}/shell/security"):
    for name in sorted(files):
        if not name.endswith((".qml", ".js")):
            continue
        rel = os.path.relpath(os.path.join(base, name), root)
        text = nocomments(read(rel))
        spans = []
        for snippet in allowed_dates.get(rel, []):
            i = text.find(snippet)
            if i >= 0:
                spans.append((i, i + len(snippet)))
        for m in re.finditer(r"\bDate\b|\bSystemClock\b|\bWallClock\b|\bgetTime\s*\(|\bperformance\s*\.\s*now\b|\bvalueOf\s*\(", text):
            if not any(a <= m.start() < b for a, b in spans):
                clock_hits.append(f"{rel}:{text.count(chr(10), 0, m.start()) + 1} {m.group(0)}")
# The lock screen's clock (review of eee45cc; WallClock since cf6d3df, and a WallClock anywhere else in shell/security is a
# wall clock too) only feeds the two displayed texts, and is refreshed on resume from sleep (ADR-0040 step 4a, ID-7: one
# `onResumesChanged: clock.refresh()`, nothing else).
lockview = nocomments(read("shell/security/lock/LockView.qml"))
clock_uses = sorted(re.sub(r"\s+", "", u) for u in re.findall(r"\bclock\s*\.\s*\w+", lockview))
if not (clock_uses == ["clock.date", "clock.date", "clock.refresh"] and lockview.count("FixedTime.date(clock.date)") == 2
        and len(re.findall(r"^\s*onResumesChanged:\s*clock\.refresh\(\)\s*$", lockview, re.M)) == 1):
    clock_hits.append("LockView.qml clock uses " + ", ".join(clock_uses))
expect("no wall clock in shell/security (" + ", ".join(clock_hits) + ")", not clock_hits)
lock = code(read("shell/security/lock/Lock.qml"))
expect("lock ownership check: the grace window after a confirmed lock is a single-shot Timer",
       re.search(r"Timer\s*\{\s*id:\s*secureGrace\s+interval:\s*ownershipProbe\.verifyGraceMs\s*\}", lock) is not None
       and re.search(r"onSecureStateChanged:\s*\{\s*if\s*\(secure\)\s*\{[^}]*?secureGrace\.restart\(\);", lock) is not None
       and re.search(r"if\s*\(!holding\s*\|\|\s*!hyprland\s*\|\|\s*secureGrace\.running\)\s*return;", code(function(lock, "verify") or "")) is not None
       and re.search(r"if\s*\(!holding\s*\|\|\s*secureGrace\.running\)\s*\{", code(function(lock, "checkOwnership") or "")) is not None)
# Review of eee45cc: the window is exactly 500 ms and nothing else touches the Timer (a 1 h or 0 ms grace, or a
# `secureGrace.repeat = true` after the first lock, passed every offscreen test). Every mention of secureGrace is its id,
# one restart() and the two `running` reads.
grace_uses = re.findall(r"\bsecureGrace\b(?:\s*\.\s*\w+(?:\s*\(\s*\))?)?", lock)
expect("lock ownership check: the grace is 500 ms and only restart() and `running` touch its Timer (" + ", ".join(grace_uses) + ")",
       re.search(r"Timer\s*\{\s*id:\s*ownershipProbe\b[^}]*?^\s*readonly property int verifyGraceMs: 500[ \t]*\n\s*(\}|[A-Za-z_][\w.]*\s*:|readonly\s|property\s|function\s)", lock, re.S | re.M) is not None
       and len(re.findall(r"\bverifyGraceMs\s*:", lock)) == 1
       and sorted(re.sub(r"\s+", "", u) for u in grace_uses) == sorted(["secureGrace", "secureGrace.restart()", "secureGrace.running", "secureGrace.running"]))
# Review of the lock's monitor queries (Quickshell 0.3.1 IPC, read in its source): Hyprland.refreshMonitors() from QML never
# creates a monitor object, and one sent before Hyprland answered Quickshell's own first query (`j/status`) makes Quickshell
# drop its start-up query: Hyprland.monitors then stays empty until a monitor event, and the stranded check, the ownership
# check and verify() never get an answer (the re-lock after a foreign release was inert, the sleep delay ran out unconfirmed).
#   queries  the shell (shell/ and ui/) has two Hyprland.refreshMonitors() calls: Lock.qml requestMonitors() behind the guard
#            on the live model's count (Machine.monitorQueryAllowed), through which every lock query goes, and Displays.qml's
#            Hyprland event handler (opus review of 94ab527, MINOR-2: the bug first came from a Displays start-up call);
#   watcher  monitorAnswers follows the live model, its delegates hand every answer to checkOwnership, and a monitor added
#            while holding asks for a fresh answer at once (monitorsAdded);
#   stranded only Hyprland's answers decide; an empty model is "unknown" (LockMachine, unit-tested): no takeover and no stop
#            as "nothing stranded" until the ticks run out; a check still undecided (running, or out of ticks because
#            Quickshell's first answer came later) runs again when monitors appear, before this shell locked (MINOR-1);
#   log      the empty model is logged once: the flag is read before the warning, set after it, cleared only in monitorsAdded.
refresh_hits = []
for top in ("shell", "ui"):
    for base, _, files in os.walk(f"{root}/{top}"):
        for name in sorted(files):
            if name.endswith((".qml", ".js")):
                rel = os.path.relpath(os.path.join(base, name), root)
                refresh_hits += [rel for _ in re.finditer(r"\brefreshMonitors\s*\(", nocomments(read(rel)))]
request = code(function(lock, "requestMonitors") or "")
expect("lock monitor queries: one Hyprland.refreshMonitors() in shell/security, in requestMonitors() behind the empty-model guard (" + ", ".join(refresh_hits) + ")",
       refresh_hits.count("shell/security/lock/Lock.qml") == 1
       and not any(h.startswith("shell/security/") and h != "shell/security/lock/Lock.qml" for h in refresh_hits)
       and re.fullmatch(r"\s*if\s*\(!Machine\.monitorQueryAllowed\(Hyprland\.monitors\.values\.length\)\)\s*\{\s*if\s*\(!emptyModelLogged\)\s*console\.warn\(\"[^\"]*\"\);\s*emptyModelLogged\s*=\s*true;\s*return false;\s*\}\s*Hyprland\.refreshMonitors\(\);\s*return true;\s*", request) is not None)
# The only other call: Displays.qml's handler of Hyprland events (monitors added or removed, configreloaded). Safe: Hyprland
# events reach QML only once Hyprland answered Quickshell's first query (Quickshell connects its event socket in that answer's
# callback, right before its own refreshMonitors(true)), so this call can never come before Quickshell's start-up query; on
# configreloaded Quickshell's own refreshMonitors(true) is already sent (this one is dropped as a duplicate), and a monitor
# added later is created by Quickshell's monitoraddedv2 handler itself, not by a monitors answer.
displays = nocomments(read("shell/platform/Displays.qml"))
handler_m = re.search(r"Connections\s*\{\s*target:\s*Hyprland\s+function onRawEvent\(event:\s*HyprlandEvent\):\s*void\s*\{", displays)
handler = block_after(displays, handler_m.start()) if handler_m else ""
expect("monitor queries outside the lock: only Displays.qml's Hyprland event handler (" + ", ".join(refresh_hits) + ")",
       sorted(refresh_hits) == ["shell/platform/Displays.qml", "shell/security/lock/Lock.qml"]
       and len(re.findall(r"\brefreshMonitors\s*\(", handler)) == 1
       and re.search(r"if\s*\(event\.name\s*===\s*\"monitoradded\"[^{]*\"configreloaded\"\)\s*\{\s*Hyprland\.refreshMonitors\(\);", handler) is not None)
monitors_added = code(function(lock, "monitorsAdded") or "")
expect("lock monitor queries: verify(), the ownership confirmation, the stranded check, ownershipProbe and monitorsAdded go through requestMonitors()",
       re.search(r"verified\s*=\s*false;\s*requestMonitors\(\);\s*$", code(function(lock, "verify") or "")) is not None
       and re.search(r"if\s*\(action\s*===\s*\"confirm\"\)\s*requestMonitors\(\);\s*else if", code(function(lock, "checkOwnership") or "")) is not None
       and re.search(r"\}\s*else\s*\{\s*requestMonitors\(\);\s*\}\s*$", code(function(lock, "checkStranded") or "")) is not None
       and re.search(r"Timer\s*\{\s*id:\s*ownershipProbe\b[^}]*?onTriggered:\s*root\.requestMonitors\(\)\s*\}", lock, re.S) is not None
       and re.search(r"if\s*\(holding\)\s*requestMonitors\(\);", monitors_added) is not None)
expect("lock ownership watcher: follows the live monitor model, every answer reaches checkOwnership, an added monitor calls monitorsAdded",
       re.search(r"Instantiator\s*\{\s*id:\s*monitorAnswers\s+active:\s*root\.hyprland\s+model:\s*Hyprland\.monitors\s+onObjectAdded:\s*Qt\.callLater\(root\.monitorsAdded\)\s+"
                 r"delegate:\s*Connections\s*\{\s*required property HyprlandMonitor modelData\s+target:\s*modelData\s+"
                 r"function onLastIpcObjectChanged\(\):\s*void\s*\{\s*Qt\.callLater\(root\.checkOwnership\);\s*\}\s*\}\s*\}", lock) is not None)
stranded = code(function(lock, "checkStranded") or "")
expect("lock stranded check: only Hyprland's answers decide; unknown (an empty model) neither takes over nor stops before the ticks run out",
       re.search(r"if\s*\(currentlyLocked\(\)\)\s*\{\s*strandedProbe\.stop\(\);\s*strandedUndecided\s*=\s*false;\s*return;\s*\}\s*"
                 r"const monitors\s*=\s*Hyprland\.monitors\.values\.map\(m\s*=>\s*m\.lastIpcObject\);\s*const state\s*=\s*Machine\.compositorLockState\(monitors\);\s*"
                 r"if\s*\(state\s*===\s*\"locked\"\)\s*\{\s*strandedProbe\.stop\(\);\s*strandedUndecided\s*=\s*false;[^}]*\}\s*"
                 r"else if\s*\(state\s*===\s*\"unlocked\"\)\s*\{\s*strandedProbe\.stop\(\);\s*strandedUndecided\s*=\s*false;\s*\}\s*"
                 r"else if\s*\(--strandedProbe\.remaining\s*<=\s*0\)\s*\{", stranded) is not None)
unknown_m = re.search(r"else if\s*\(--strandedProbe\.remaining\s*<=\s*0\)\s*\{", stranded)
unknown_branch = block_after(stranded, unknown_m.start()) if unknown_m else "strandedUndecided"
expect("lock stranded check: undecided from its start until Hyprland answers locked or unlocked (or this shell locks); "
       "monitors appearing before this shell locked run it again (only ever a takeover)",
       re.search(r"^\s*property bool strandedUndecided:\s*false\s*$", lock, re.M) is not None
       and re.search(r"if\s*\(!controller\.locked\s*&&\s*root\.hyprland\)\s*\{\s*strandedUndecided\s*=\s*true;\s*strandedProbe\.start\(\);\s*\}", lock) is not None
       and len(re.findall(r"\bstrandedUndecided\s*=\s*true;", lock)) == 1
       and len(re.findall(r"\bstrandedUndecided\s*=\s*false;", lock)) == 4
       and re.search(r"strandedProbe\.stop\(\);\s*strandedUndecided\s*=\s*false;\s*console\.info\(\"grassfield-lock: lock requested \(\"", code(function(lock, "lock") or "")) is not None
       and len(re.findall(r"\bstrandedUndecided\s*=\s*false;", stranded)) == 3
       and "strandedUndecided" not in unknown_branch
       and re.search(r"if\s*\(holding\)\s*requestMonitors\(\);\s*else if\s*\(strandedUndecided\)\s*checkStranded\(\);\s*$", monitors_added) is not None)
expect("lock monitor queries: the empty model is logged once, the flag cleared only when a monitor appears",
       re.search(r"^\s*property bool emptyModelLogged:\s*false\s*$", lock, re.M) is not None
       and len(re.findall(r"\bemptyModelLogged\s*=\s*true;", lock)) == 1
       and len(re.findall(r"\bemptyModelLogged\s*=\s*false;", lock)) == 1
       and re.search(r"^\s*if\s*\(emptyModelLogged\)\s*\{\s*emptyModelLogged\s*=\s*false;", monitors_added) is not None)
sleep = code(read("shell/security/idle/SleepInhibitor.qml"))
idle = code(read("shell/security/idle/IdleModel.js"))
# Reviews of 2dfd992 and eee45cc: a child is healthy only when its health Timer saw it running FAST_EXIT_MS AND it showed
# progress (the inhibitor's "held", the watcher's first line); one without progress within PROGRESS_BUDGET_MS is stopped
# and counted as a failure.
expect("sleep inhibitor: a child is healthy only after FAST_EXIT_MS with progress; a hung one is a failure",
       re.search(r"^var PROGRESS_BUDGET_MS = 35000;$", idle, re.M) is not None
       and re.search(r'if\s*\(!watcher\.progressed && IdleModel\.watcherSubscribed\(line\)\)', sleep) is not None
       and re.search(r'return typeof line === "string" && line\.indexOf\("The name org\.freedesktop\.login1 is owned by "\) === 0;', code(function(idle, "watcherSubscribed") or "")) is not None
       and re.search(r"return ranLong === true \? 0 : n \+ 1;", code(function(idle, "failuresAfterRun") or "")) is not None
       and '"systemd-inhibit", "--what=sleep", "--mode=delay", "--who=Grassfield", "--why=" + qsTr("Lock the screen before sleep"), "sh", "-c", "echo held; exec cat"]' in sleep
       and re.search(r'if\s*\(line === "held" && !inhibitor\.progressed\)', sleep) is not None
       and all(re.search(r"root\." + c + r"Failures\s*=\s*IdleModel\.failuresAfterRun\(root\." + c + r"Failures,\s*ranLong\);", sleep) is not None
               and re.search(r"if\s*\(" + c + r"\.running\s*&&\s*" + c + r"\.progressed\)\s*\{\s*" + c + r"\.ranLong\s*=\s*true;", sleep) is not None
               and re.search(c + r"\.progressed\s*=\s*true;\s*" + c + r"Progress\.stop\(\);.*?if\s*\(" + c + r"\.running\s*&&\s*!" + c + r"Healthy\.running\)\s*\{\s*" + c + r"\.ranLong\s*=\s*true;", sleep, re.S) is not None
               and re.search(r"onStarted:\s*\{\s*ranLong\s*=\s*false;\s*progressed\s*=\s*false;\s*" + c + r"Healthy\.restart\(\);\s*" + c + r"Progress\.restart\(\);", sleep) is not None
               and re.search(r"Timer\s*\{\s*id:\s*" + c + r"Progress\s+interval:\s*IdleModel\.PROGRESS_BUDGET_MS\s+onTriggered:\s*\{\s*if\s*\(" + c + r"\.running\s*&&\s*!" + c + r"\.progressed\)\s*\{[^}]*?" + c + r"\.running\s*=\s*false;", sleep) is not None
               for c in ("inhibitor", "watcher")))

# Fingerprint pacing (Omarchy v4.5.0 review, docs/specs/security.md "Fingerprint pacing"). Lock.qml cannot run offscreen
# (WlSessionLock); the pure helpers are unit-tested in tst_lockmachine.qml. Here: the only fingerprint unlock is
# fingerprintPam's PamResult.Success; the pacing (start guard, display pause, settle, reach timeout, resume) never unlocks,
# reads nothing of the conversation but whether a line is an error, and logs nothing of it; MaxTries keeps the reader off
# until LOCKED anew. Opus review of 59a576f1: an attempt unreached after 20 s ends as a miss (MINOR 1); a resume while
# unlocked leaves no pass for the next lock (MINOR 2).
fp_pam_m = re.search(r"PamContext\s*\{\s*id:\s*fingerprintPam\b", lock)
fp_pam = block_after(lock, fp_pam_m.start()) if fp_pam_m else ""
fp_start = code(function(lock, "startFingerprint") or "")
fp_ended = code(function(lock, "fingerprintEnded") or "")
fp_resume = code(function(lock, "fingerprintAfterResume") or "")
fp_reach = code(function(lock, "fingerprintReachTimedOut") or "")
fp_wake_m = re.search(r"^\s*onDisplaysOffChanged:\s*\{", lock, re.M)
fp_wake = block_after(lock, fp_wake_m.start()) if fp_wake_m else ""
fp_msg_m = re.search(r"onPamMessage:\s*\{", fp_pam)
fp_msg = block_after(fp_pam, fp_msg_m.start()) if fp_msg_m else ""
fp_done_m = re.search(r"onCompleted:\s*result\s*=>\s*\{", fp_pam)
fp_done = block_after(fp_pam, fp_done_m.start()) if fp_done_m else ""
def stmts(body):
    return [l.strip() for l in body.split("\n") if l.strip()]
expect("fingerprint: the one fingerprint unlock is fingerprintPam's PamResult.Success",
       len(re.findall(r"\bcontroller\.fingerprintSucceeded\s*\(", lock)) == 1
       and re.match(r"\s*if\s*\(result === PamResult\.Success\)\s*\{\s*root\.fingerprintOpen\s*=\s*false;\s*fingerprintFastEnd\.stop\(\);\s*fingerprintReach\.stop\(\);\s*controller\.fingerprintSucceeded\(\);\s*\}\s*else if\s*\(result === PamResult\.MaxTries\)\s*\{", fp_done) is not None)
expect("fingerprint: MaxTries keeps the reader off (fingerprintSpent), no retry armed",
       re.search(r"else if\s*\(result === PamResult\.MaxTries\)\s*\{\s*root\.fingerprintOpen\s*=\s*false;\s*root\.fingerprintSpent\s*=\s*true;\s*fingerprintFastEnd\.stop\(\);\s*fingerprintReach\.stop\(\);\s*\}\s*else\s*\{\s*root\.fingerprintEnded\(\);\s*\}\s*$", fp_done) is not None
       and re.search(r"^\s*onError:\s*root\.fingerprintEnded\(\)\s*$", fp_pam, re.M) is not None
       and len(re.findall(r"\bfingerprintSpent\s*=\s*true;", lock)) == 1)
expect("fingerprint: startFingerprint's first decisions (file, LOCKED, secure, not active, not spent; displays off without a resume pass)",
       stmts(fp_start)[:4] == ["if (!fingerprintFile.available || controller.lockState !== Machine.LOCKED || !sessionLock.secure || fingerprintPam.active || root.fingerprintSpent)",
                               "return;", "if (root.displaysOff && !root.fingerprintResumePass)", "return;"])
expect("fingerprint: an attempt is settled once, then the next waits Machine.fingerprintRetryMs(misses)",
       stmts(fp_ended)[:3] == ["if (!root.fingerprintOpen)", "return;", "root.fingerprintOpen = false;"]
       and "root.fingerprintMisses = Machine.fingerprintMisses(before, root.fingerprintReached, fingerprintFastEnd.running);" in fp_ended
       and re.search(r"fingerprintRetry\.interval\s*=\s*Machine\.fingerprintRetryMs\(root\.fingerprintMisses\);\s*fingerprintRetry\.restart\(\);\s*$", fp_ended) is not None
       and "fingerprintReach.stop();" in stmts(fp_ended)
       and re.search(r"root\.fingerprintOpen\s*=\s*true;\s*fingerprintReach\.restart\(\);\s*if\s*\(!fingerprintPam\.start\(\)\)\s*root\.fingerprintEnded\(\);\s*$", fp_start) is not None)
expect("fingerprint: an attempt still unreached after Machine.FINGERPRINT_REACH_TIMEOUT_MS ends (abort) and counts as a miss",
       re.search(r"Timer\s*\{\s*id:\s*fingerprintReach\s+interval:\s*Machine\.FINGERPRINT_REACH_TIMEOUT_MS\s+onTriggered:\s*root\.fingerprintReachTimedOut\(\)\s*\}", lock) is not None
       and stmts(fp_reach) == ["if (!root.fingerprintOpen || root.fingerprintReached)", "return;", "if (fingerprintPam.active)",
                               "fingerprintPam.abort();", "root.fingerprintEnded();"]
       and len(re.findall(r"\bfingerprintReach\.restart\(\)", lock)) == 1
       and len(re.findall(r"\broot\.fingerprintReachTimedOut\(\)", lock)) == 1
       and len(re.findall(r"\bfingerprintReach\.stop\(\);", lock)) == 6)
expect("fingerprint: the reader counts as reached on the first line that is not an error, only for an open attempt",
       stmts(fp_msg) == ["if (root.fingerprintOpen && !root.fingerprintReached && !fingerprintPam.messageIsError) {",
                         "root.fingerprintReached = true;", "fingerprintReach.stop();", "fingerprintFastEnd.restart();", "}"]
       and re.search(r"Timer\s*\{\s*id:\s*fingerprintFastEnd\s+interval:\s*Machine\.FINGERPRINT_FAST_END_MS\s*\}", lock) is not None
       and len(re.findall(r"\bfingerprintFastEnd\.restart\(\)", lock)) == 1)
fp_pam_words = re.findall(r"\b(?:message|responseRequired|responseVisible|respond)\b|\bconsole\s*\.", fp_pam)
expect("fingerprint: nothing of the conversation is read but messageIsError, nothing answered, nothing logged (" + ", ".join(fp_pam_words) + ")",
       fp_pam_m is not None and not fp_pam_words)
fp_paths = fp_start + fp_ended + fp_resume + fp_wake + fp_msg + fp_reach
fp_controller = sorted(set(re.findall(r"\bcontroller\s*\.\s*\w+", fp_paths)))
expect("fingerprint: the pacing never unlocks (reads controller.lockState only; no release, marker or lock change: " + ", ".join(fp_controller) + ")",
       all(b for b in (fp_start, fp_ended, fp_resume, fp_wake, fp_msg, fp_reach))
       and fp_controller == ["controller.lockState"]
       and re.search(r"\brelease\s*\(|\bwriteMarker\s*\(|sessionLock\s*\.\s*locked\s*=|persist\s*\.\s*intent\s*=|\bunlockRequested\b|\bfingerprintSucceeded\b", fp_paths) is None)
expect("fingerprint: the displays going off drop the pending attempt, their wake offers the reader",
       stmts(fp_wake) == ["if (root.displaysOff)", "fingerprintRetry.stop();", "else", "root.startFingerprint();"])
expect("fingerprint: a resume forgets the misses, drops the attempt open across the sleep and offers the reader once, to a lock only (not after MaxTries, not while unlocked)",
       re.search(r"function resumed\(\): void \{\s*root\.resumes \+= 1;\s*root\.fingerprintAfterResume\(\);\s*\}", lock) is not None
       and stmts(fp_resume)[:3] == ["root.fingerprintMisses = 0;", "if (!Machine.fingerprintOfferedOnResume(fingerprintFile.available, root.fingerprintSpent, controller.lockState))", "return;"]
       and "fingerprintReach.stop();" in stmts(fp_resume)
       and re.search(r"if\s*\(fingerprintPam\.active\)\s*fingerprintPam\.abort\(\);\s*root\.fingerprintResumePass\s*=\s*true;\s*fingerprintRetry\.interval\s*=\s*Machine\.FINGERPRINT_RETRY_MS;\s*fingerprintRetry\.restart\(\);\s*$", fp_resume) is not None)
fp_release = code(function(lock, "release") or "")
expect("fingerprint: LOCKED anew clears MaxTries and offers the reader; the unlock resets the pacing",
       re.search(r"if\s*\(lockState === Machine\.LOCKED\)\s*\{\s*root\.fingerprintSpent\s*=\s*false;\s*root\.startFingerprint\(\);\s*\}", lock) is not None
       and all(s in fp_release for s in ("fingerprintRetry.stop();", "fingerprintFastEnd.stop();", "fingerprintReach.stop();", "root.fingerprintOpen = false;",
                                         "root.fingerprintMisses = 0;", "root.fingerprintSpent = false;", "root.fingerprintResumePass = false;"))
       and re.search(r"if\s*\(fingerprintPam\.active\)\s*fingerprintPam\.abort\(\);", fp_release) is not None)

for o in oks:
    print("OK " + o)
for p in problems:
    print("PROBLEM " + p)
sys.exit(1 if problems else 0)
PY

out=$(python3 -I "$tmp/check.py" "$root" 2>&1)
rc=$?
while IFS= read -r line; do
  case $line in
    "OK "*) pass "${line#OK }" ;;
    "PROBLEM "*) bad "${line#PROBLEM }" ;;
    *) [[ -n $line ]] && bad "checker: $line" ;;
  esac
done <<<"$out"
((rc == 0)) || bad "checker exit $rc"

# Mutation: the checker must fail when one refusal is removed (a copy of the files it reads).
mut=$tmp/mutant
for f in shell/shell.qml shell/services/SessionState.qml shell/services/Popups.qml shell/search/Search.qml shell/launchpad/AppsController.qml \
  shell/overview/Overview.qml shell/notifications/Notifications.qml shell/dock/Dock.qml shell/platform/Compositor.qml shell/switcher/Switcher.qml \
  shell/menubar/MenuBar.qml shell/desktop/HotCornerActions.js shell/security/polkit/AuthAgent.qml shell/security/polkit/AuthDialogModel.qml \
  shell/desktop/IconsView.qml shell/desktop/DesktopWidgets.qml shell/platform/Displays.qml shell/services/TilingHover.qml \
  shell/services/TilingSuggest.qml shell/menubar/AppMenus.qml shell/overlay/DockMenu.qml shell/overlay/ExitCover.qml \
  shell/services/Emoji.qml shell/capture/Capture.qml shell/capture/CaptureToolbar.qml shell/services/PopupKinds.js \
  shell/services/LockClient.qml; do
  mkdir -p "$mut/$(dirname "$f")"
  cp "$root/$f" "$mut/$f"
done
cp -a "$root/shell/security" "$mut/shell/" # the wall-clock scan reads every file of shell/security
python3 -I "$tmp/check.py" "$mut" >/dev/null 2>&1 && pass "mutation: the unchanged copy passes" || bad "mutation: the unchanged copy fails"
for case_ in 'shell/dock/Dock.qml#SessionState.refuses("dock keyboard")#false' \
  'shell/overlay/ExitCover.qml#SessionState.refuses("exit cover")#false' \
  'shell/services/Emoji.qml#SessionState.refuses("emoji")#false' \
  'shell/services/Emoji.qml#        if (SessionState.locked)\n            return;\n        root.cancelInsert#        root.cancelInsert' \
  'shell/desktop/DesktopWidgets.qml#SessionState.refuses("widget menu")#false' \
  'shell/desktop/IconsView.qml#root.closeMenu("outside");#root.closeAbout("outside");' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows cycleApp")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows arrange")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows tilePopover")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows nextOutput")#false' \
  'shell/services/TilingHover.qml#SessionState.refuses("tiling popover")#false' \
  'shell/services/TilingSuggest.qml#SessionState.refuses("tiling suggestions")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("tile group forward")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows split")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows unsplit")#false' \
  'shell/platform/Compositor.qml#return root.tile(toplevel, "fill");#return dispatchRequest(Minimized.tileCall(address, "fill"));' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows tile")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows fill alone")#false' \
  'shell/services/TilingSuggest.qml#readonly property var lonely: SessionState.locked ? [] : #readonly property var lonely: #' \
  'shell/platform/Compositor.qml#if (WindowTiling.membersOf(TilingLink.groups, address).length === 0)#if (false)' \
  'shell/platform/Compositor.qml#function groupFront(address: string): string {\n        if (SessionState.refuses("tile group forward"))#function groupFront(address: string): string {\n        if (false)' \
  'shell/platform/Compositor.qml#if (!p || SessionState.refuses("menu activation"))#if (!p)' \
  'shell/overview/Overview.qml#if (target.kind === "window" && !locked)#if (target.kind === "window")' \
  'shell/overview/Overview.qml#        focusViaPlugin = target.kind !== "skip" && !locked && Capabilities.has("overview-focus") && Compositor.overviewFocus(target);\n        // A window chosen brings its tile group forward (TL29), sent after its focus request as from the other entry points.\n        if (target.kind === "window" && !locked)\n            Compositor.groupForward(target.address);#        if (target.kind === "window" && !locked)\n            Compositor.groupForward(target.address);\n        focusViaPlugin = target.kind !== "skip" && !locked && Capabilities.has("overview-focus") && Compositor.overviewFocus(target);' \
  'shell/overview/Overview.qml#if (restore && !locked)\n            Compositor.unminimizeWithGroup(restore);#if (restore)\n            Compositor.unminimizeWithGroup(restore);' \
  'shell/switcher/Switcher.qml#Compositor.activateWithGroup(main)#Compositor.activate(main)' \
  'shell/menubar/AppMenus.qml#Compositor.activateWithGroup(item.ref)#Compositor.activate(item.ref)' \
  'shell/dock/Dock.qml#Compositor.unminimizeWithGroup(item.toplevel)#Compositor.unminimize(item.toplevel)' \
  'shell/dock/Dock.qml#            Compositor.groupForward(Compositor.addressOf(plan[plan.length - 1]));#            ;' \
  'shell/platform/Compositor.qml#        unminimize(toplevel);\n        groupForward(addressOf(toplevel));#        unminimize(toplevel);' \
  'shell/overlay/DockMenu.qml#Compositor.showTileGroupAfterLayer(item.ref, "grassfield-overlay", item.members)#Compositor.activateAfterLayer(item.ref, "grassfield-overlay")' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows minimize request")#false' \
  'shell/services/Popups.qml#SessionState.refuses("popup " + popupKind)#false' \
  'shell/services/Popups.qml#SessionState.refusesConfirmed("popup " + popupKind)#false' \
  'shell/services/Popups.qml#PopupKinds.endsOrLocks(popupKind, payload) ?#true ?' \
  'shell/search/Search.qml#SessionState.refusesConfirmed("search")#false' \
  'shell/services/SessionState.qml#if (!locked || !lockConfirmed)#if (!locked)' \
  'shell/services/SessionState.qml#if (!locked || !lockConfirmed)\n            return false;\n        return refuses(surface);#return false;' \
  'shell/services/SessionState.qml#    property bool lockConfirmed: true#    property bool lockConfirmed: false' \
  'shell/services/PopupKinds.js#const sessionActions = ["logout", "restart", "shutdown"];#const sessionActions = ["logout", "restart", "shutdown", "emptytrash"];' \
  'shell/services/PopupKinds.js#    return kind === "confirm" && payload#    return payload' \
  'shell/shell.qml#        property: "lockConfirmed"\n        value: LockClient.lockConfirmed#        property: "lockConfirmed"\n        value: false' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.active && !SheetSession.locked#dialogModel.active' \
  'shell/security/polkit/AuthAgent.qml#((root.requestOpen && (!root.heldByLock || root.userFocused)) || root.sinkingKeys)#(root.requestOpen || root.sinkingKeys)' \
  'shell/security/polkit/AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = false;' \
  'shell/security/polkit/AuthAgent.qml#                event.accepted = true;\n                if (root.lingering)#                event.accepted = false;\n                if (root.lingering)' \
  'shell/security/polkit/AuthAgent.qml#        root.userFocused = false;\n        if (dialogModel.active)\n            root.requestOpen = true;#        if (dialogModel.active)\n            root.requestOpen = true;' \
  'shell/security/polkit/AuthAgent.qml#            dialogModel.noteEnded();#            ;' \
  'shell/security/polkit/AuthDialogModel.qml#return locked || unlockHold.running || afterRequest.running;#return locked || unlockHold.running;' \
  'shell/security/polkit/AuthAgent.qml#if (shown && !root.heldByLock)#if (shown)' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.arrivesHeld(SheetSession.locked || SheetSession.saverShown)#SheetSession.locked || SheetSession.saverShown' \
  'shell/security/polkit/AuthAgent.qml#arrivesHeld(SheetSession.locked || SheetSession.saverShown)#arrivesHeld(SheetSession.locked)' \
  'shell/security/polkit/AuthAgent.qml#                root.heldByLock = true;\n                root.userFocused = false;\n                dialogModel.clearRequested();#                root.userFocused = false;' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.noteUncovered();#;' \
  'shell/security/polkit/AuthAgent.qml#enabled: SheetSession.saverShown#enabled: false' \
  'shell/security/polkit/AuthAgent.qml#acceptedButtons: Qt.AllButtons#acceptedButtons: Qt.LeftButton' \
  'shell/security/host/SecurityHost.qml#        property: "saverShown"\n        value: idle.saverShown#        property: "saverShown"\n        value: false' \
  'shell/security/SheetSession.qml#    property bool saverShown: false#    property bool saverShown: false\n    function hideSaver(): void {\n        saverShown = false;\n    }' \
  'shell/security/host/SecurityHost.qml#        property: "saverShown"\n        value: idle.saverShown\n    }#        property: "saverShown"\n        value: idle.saverShown\n    }\n    Binding {\n        target: SheetSession\n        property: "saverShown"\n        value: false\n        when: false\n    }' \
  'shell/security/idle/Idle.qml#readonly property bool saverShown: saverMonitor.enabled && saverMonitor.isIdle#readonly property bool saverShown: false' \
  'shell/security/polkit/AuthAgent.qml#if (!dialogModel.active || SheetSession.locked)#if (!dialogModel.active || SheetSession.locked || !SheetSession.saverShown)' \
  'shell/security/polkit/AuthAgent.qml#        root.userFocused = false;\n        if (dialogModel.active)\n            root.requestOpen = true;#        root.userFocused = true;\n        if (dialogModel.active)\n            root.requestOpen = true;' \
  'shell/security/polkit/AuthAgent.qml#const follows = root.flowShown#const follows = false && root.flowShown' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.active && (follows || #dialogModel.active && (' \
  'shell/security/polkit/AuthAgent.qml#            dialogModel.clearRequested();\n            dialogModel.noteShown();#            dialogModel.clearRequested();' \
  'shell/security/polkit/AuthDialogModel.qml#        clickGuard.restart();\n    }\n\n    // The request in the sheet ended#    }\n\n    // The request in the sheet ended' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.noteUnlock();#root.unlockedAt = Date.now();' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.noteShown();#root.shownAt = Date.now();' \
  'shell/security/polkit/AuthDialogModel.qml#return locked || unlockHold.running || afterRequest.running;#return locked || Date.now() - priv.unlockedAt < heldAfterUnlockMs;' \
  'shell/security/polkit/AuthDialogModel.qml#return priv.shown && !clickGuard.running;#return !clickGuard.running;' \
  'shell/security/polkit/AuthAgent.qml#active ? new Date() : null#active ? Date.now() : 0' \
  'shell/security/polkit/AuthAgent.qml#onActiveFocusChanged: if (activeFocus && root.sinkingKeys)#onActiveFocusChanged: if (false)' \
  'shell/security/polkit/AuthAgent.qml#visible: !SheetSession.locked && (root.requestOpen || root.sinkingKeys)#visible: shown || root.lingering' \
  'shell/security/polkit/AuthAgent.qml#takesKeys: !SheetSession.locked && ((root.requestOpen && (!root.heldByLock || root.userFocused)) || root.sinkingKeys)#takesKeys: (shown && (!root.heldByLock || root.userFocused || root.sinkingKeys)) || root.lingering' \
  'shell/security/polkit/AuthAgent.qml#inputEnabled: !root.sinkingKeys#inputEnabled: true' \
  'shell/security/polkit/AuthAgent.qml#if (typing && !dialogModel.active && !SheetSession.locked) {#if (root.lingering) {' \
  'shell/security/polkit/AuthDialog.qml#        if (root.inputEnabled)\n            field.forceActiveFocus();#        field.forceActiveFocus();' \
  'shell/security/polkit/AuthDialog.qml#                enabled: root.inputEnabled && !root.model.awaitingDevice#                enabled: !root.model.awaitingDevice' \
  'shell/security/polkit/AuthDialog.qml#                enabled: root.inputEnabled && !root.model.awaitingDevice#                enabled: root.inputEnabled' \
  'shell/security/polkit/AuthDialog.qml#            if (!root.model.awaitingDevice && root.model.responseRequired)\n                root.focusField();#            if (!root.model.awaitingDevice)\n                root.focusField();' \
  'shell/security/polkit/AuthDialog.qml#            if (!root.model.awaitingDevice && root.model.responseRequired)\n                root.focusField();#            if (!root.model.awaitingDevice && root.model.responseRequired)\n                field.forceActiveFocus();' \
  'shell/security/polkit/AuthDialog.qml#            if (!root.model.awaitingDevice && root.model.responseRequired)\n                root.focusField();#            root.focusField();' \
  'shell/security/polkit/AuthDialogModel.qml#        if (refusesUnseen)\n            request.cancelAuthenticationRequest();#        if (refusesUnseen)\n            console.info("refused");' \
  'shell/security/polkit/AuthDialogModel.qml#        Qt.callLater(root.refuseUnseen)#        root.refuseUnseen()' \
  'shell/security/polkit/AuthDialogModel.qml#    onRefusesUnseenChanged: if (refusesUnseen)\n        Qt.callLater(root.refuseUnseen)#    onRefusesUnseenChanged: {}' \
  'shell/security/polkit/AuthDialogModel.qml#readonly property bool refusesUnseen: !answerable && pamTalks(request)#readonly property bool refusesUnseen: !answerable && pamTalks(flow)' \
  'shell/security/polkit/AuthDialogModel.qml#readonly property bool refusesUnseen: !answerable && pamTalks(request)#readonly property bool refusesUnseen: !answerable && pamTalks(request) && !priv.submitted' \
  'shell/security/polkit/AuthDialogModel.qml#    property bool answerable: false#    property bool answerable: true' \
  'shell/security/polkit/AuthDialogModel.qml#        return !!f && f.isResponseRequired !== true && #        return !!f && ' \
  'shell/security/polkit/AuthAgent.qml#        request: agent.flow#        request: agent.isActive && !root.waiting ? agent.flow : null' \
  'shell/security/polkit/AuthAgent.qml#        answerable: !SheetSession.locked && #        answerable: ' \
  'shell/security/polkit/AuthAgent.qml#answerable: !SheetSession.locked && !SheetSession.saverShown && #answerable: !SheetSession.locked && ' \
  'shell/security/polkit/AuthAgent.qml# && !root.waiting && root.requestOpen# && root.requestOpen' \
  'shell/security/polkit/AuthAgent.qml#!root.waiting && root.requestOpen\n#!root.waiting\n' \
  'shell/security/polkit/AuthAgent.qml#!root.waiting && root.requestOpen\n#!root.waiting && root.requestOpen && !root.sinkingKeys\n' \
  'shell/security/polkit/AuthDialogModel.qml#            priv.replaced = liveReplaced().concat([before]);#            ;' \
  'shell/security/polkit/AuthDialogModel.qml#        Qt.callLater(root.refuseReplaced)#        root.refuseReplaced()' \
  'shell/security/polkit/AuthDialogModel.qml#        if (request && request.isCompleted !== true && replaced.indexOf(request) < 0)\n            request.cancelAuthenticationRequest();\n#' \
  'shell/security/polkit/AuthDialogModel.qml#        priv.replaced = [];\n        if (request#        if (request' \
  'shell/security/polkit/AuthDialogModel.qml#before.isCompleted !== true)#true)' \
  'shell/security/polkit/AuthDialogModel.qml#liveReplaced().some(f => pamTalks(f))#false' \
  'shell/capture/Capture.qml#SessionState.refuses("capture")#false' \
  'shell/capture/CaptureToolbar.qml#            if (win.sheetOpen) {\n                win.holdsKeyboard = false;\n                return;\n            }\n#' \
  'shell/capture/CaptureToolbar.qml#                win.holdsKeyboard = win.wantsKeyboard && !win.sheetOpen;#                win.holdsKeyboard = win.wantsKeyboard;' \
  'shell/capture/CaptureToolbar.qml#                keyHandover.stop();\n                if (win.remapping) {#                if (win.remapping) {' \
  'shell/capture/CaptureToolbar.qml#readonly property bool sheetOpen: SessionState.securityKeyboard#readonly property bool sheetOpen: false' \
  'shell/capture/CaptureToolbar.qml#readonly property bool sheetOpen: SessionState.securityKeyboard#readonly property bool sheetOpen: SessionState.authorizing' \
  'shell/security/host/SheetHost.qml#securityKeyboard: authAgent.queuePresent || secretAgent.requestActive || secretAgent.sinkingKeys#securityKeyboard: authAgent.requestActive || secretAgent.requestActive' \
  'shell/security/host/SheetHost.qml#securityKeyboard: authAgent.queuePresent || secretAgent.requestActive || secretAgent.sinkingKeys#securityKeyboard: authAgent.queuePresent || secretAgent.requestActive' \
  'shell/security/host/SecurityHost.qml#        value: root.sheets !== null && root.sheets.securityKeyboard === true#        value: false' \
  'shell/shell.qml#        property: "securityKeyboard"\n        value: LockClient.securityKeyboard#        property: "securityKeyboard"\n        value: false' \
  'shell/services/LockClient.qml#readonly property bool securityKeyboard: LockState.uiSheet(root.known, root.stale, root.last, "securityKeyboard")#readonly property bool securityKeyboard: root.known && root.last !== null && root.last.securityKeyboard === true' \
  'shell/security/polkit/AuthAgent.qml#readonly property bool queuePresent: agent.isActive || root.requestOpen || root.sinkingKeys#readonly property bool queuePresent: agent.isActive || root.requestOpen' \
  'shell/security/polkit/AuthAgent.qml#!SheetSession.displaysOff && #' \
  'shell/security/host/SecurityHost.qml#        property: "displaysOff"\n        value: idle.displayOff#        property: "displaysOff"\n        value: false' \
  'shell/security/host/SecurityHost.qml#        property: "locked"\n        value: Lock.locked#        property: "locked"\n        value: false' \
  'shell/security/polkit/AuthAgent.qml#root.userFocused || root.heldWhy === "queued")#root.userFocused || root.heldWhy !== "locked")' \
  'shell/security/polkit/AuthAgent.qml#                    && (!root.heldByLock || root.userFocused || root.heldWhy === "queued")#' \
  'shell/capture/Capture.qml#        if (locked)\n            hide();#        ;' \
  'shell/capture/Capture.qml#            if (args && !SessionState.locked)#            if (args)' \
  'shell/capture/Capture.qml#        else\n            show();#        else\n            open = true;' \
  'shell/shell.qml#        id: captureSurface\n        // The session lock owns the screen and the keyboard: the toolbar closes and does not open.\n        locked: SessionState.locked#        id: captureSurface' \
  'shell/shell.qml#        property: "locked"\n        value: LockClient.locked#        property: "locked"\n        value: false' \
  'shell/security/polkit/AuthDialog.qml#            id: identityList\n            enabled: root.inputEnabled#            id: identityList' \
  'shell/security/polkit/AuthDialog.qml#                // No focus while AuthAgent keeps the keys on its sink (as the identity rows).\n                enabled: root.inputEnabled#                // No focus while AuthAgent keeps the keys on its sink (as the identity rows).' \
  'shell/security/polkit/AuthAgent.qml#        const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);\n        const queued = follows || typing || (dialogModel.active && dialogModel.followsAnother());#        let typing = false;\n        const queued = follows || typing || (dialogModel.active && dialogModel.followsAnother());\n        typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);' \
  'shell/security/polkit/AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = (follows && win.takesKeys) || (!dialogModel.active && win.takesKeys && !dialogModel.answered);' \
  'shell/security/polkit/AuthAgent.qml#visible: !SheetSession.locked && (root.requestOpen || root.sinkingKeys)#visible: !SheetSession.locked && root.requestOpen' \
  'shell/security/polkit/AuthAgent.qml#root.sinkingKeys && !dialogModel.active && !SheetSession.locked#root.sinkingKeys && !dialogModel.active' \
  'shell/security/polkit/AuthAgent.qml#                return;\n            }\n            root.sinkingKeys = false;#                return;\n            }' \
  'shell/security/polkit/AuthAgent.qml#            if (SheetSession.saverShown)\n                root.sinkingKeys = false;\n#' \
  'shell/security/polkit/AuthAgent.qml#        interval: dialogModel.heldAfterUnlockMs\n        onTriggered: if (root.lingering)#        interval: dialogModel.heldAfterUnlockMs\n        onTriggered: if (true)' \
  'shell/security/polkit/AuthAgent.qml#        if (typing && !dialogModel.active && !SheetSession.locked) {\n            sinkIdle.restart();\n            sinkCap.restart();\n        }\n#' \
  'shell/security/polkit/AuthAgent.qml#if (dialog && win.takesKeys && !root.sinkingKeys)#if (dialog)' \
  'shell/security/polkit/AuthAgent.qml#(follows || typing || dialogModel.arrivesHeld(#(follows || dialogModel.arrivesHeld(' \
  'shell/security/polkit/AuthDialog.qml#            field.clear();\n#            field.clear();\n            root.focusField();\n' \
  'shell/security/polkit/AuthAgent.qml#                else if (event.key === Qt.Key_Escape)\n                    dialogModel.cancel();#                else if (event.key === Qt.Key_Escape)\n                    ;' \
  'shell/security/polkit/AuthDialogModel.qml#readonly property int sinkLingerMaxMs: 3000#readonly property int sinkLingerMaxMs: 30000' \
  'shell/security/polkit/AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = (follows && win.takesKeys) || root.sinkingKeys;' \
  'shell/security/polkit/AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys);' \
  'shell/security/polkit/AuthAgent.qml#visible: !SheetSession.locked && (root.requestOpen || root.sinkingKeys)#visible: !SheetSession.locked && (dialogModel.active || root.sinkingKeys)' \
  'shell/security/polkit/AuthAgent.qml#((root.requestOpen && (!root.heldByLock || root.userFocused)) || root.sinkingKeys)#((dialogModel.active && (!root.heldByLock || root.userFocused)) || root.sinkingKeys)' \
  'shell/security/polkit/AuthAgent.qml#        root.sinkingKeys = typing;\n        if (!dialogModel.active)\n            root.requestOpen = false;#        if (!dialogModel.active)\n            root.requestOpen = false;\n        root.sinkingKeys = typing;' \
  'shell/security/polkit/AuthAgent.qml#            root.sinkingKeys = false;\n            if (dialogModel.active) {#            root.sinkingKeys = false;\n            root.requestOpen = false;\n            if (dialogModel.active) {' \
  'shell/security/polkit/AuthDialogModel.qml#        if (flow)\n            priv.answered = false;#        priv.answered = false;' \
  'shell/security/polkit/AuthDialogModel.qml#        priv.submitted = false;\n        priv.answered = true;#        priv.submitted = false;' \
  'shell/security/polkit/AuthDialogModel.qml#            root.priv.submitted = false;\n            root.priv.answered = false;\n            root.priv.error#            root.priv.submitted = false;\n            root.priv.error' \
  'shell/security/polkit/AuthAgent.qml#            visible: root.lingering#            visible: root.sinkingKeys' \
  'shell/security/polkit/AuthAgent.qml#            radius: Tokens.radiusDialog\n\n            Column {#            radius: Tokens.radiusDialog\n            MouseArea { anchors.fill: parent }\n\n            Column {' \
  'shell/security/polkit/AuthAgent.qml#                    text: qsTr("Request cancelled")#                    text: dialogModel.message' \
  'shell/security/lock/Lock.qml#secureGrace.restart();#root.securedAt = Date.now();' \
  'shell/security/lock/Lock.qml#if (!holding || secureGrace.running) {#if (!holding || Date.now() - root.securedAt < 500) {' \
  'shell/security/lock/Lock.qml#if (!holding || !hyprland || secureGrace.running)#if (!holding || !hyprland)' \
  'shell/security/idle/SleepInhibitor.qml#IdleModel.failuresAfterRun(root.inhibitorFailures, ranLong)#IdleModel.failuresAfterRun(root.inhibitorFailures, true)' \
  'shell/security/idle/SleepInhibitor.qml#            if (watcher.running && watcher.progressed) {#            if (watcher.running) {' \
  'shell/security/idle/SleepInhibitor.qml#            if (inhibitor.running && !inhibitor.progressed) {#            if (false) {' \
  'shell/security/idle/SleepInhibitor.qml#"sh", "-c", "echo held; exec cat"#"cat"' \
  'shell/security/idle/IdleModel.js#var PROGRESS_BUDGET_MS = 35000;#var PROGRESS_BUDGET_MS = 10000;' \
  'shell/security/idle/SleepInhibitor.qml#if (!watcher.progressed && IdleModel.watcherSubscribed(line)) {#if (!watcher.progressed) {' \
  'shell/security/lock/Lock.qml#readonly property int verifyGraceMs: 500#readonly property int verifyGraceMs: 500\n            * 7200' \
  'shell/security/lock/LockView.qml#            text: Qt.formatTime(FixedTime.date(clock.date), #            visible: clock.minutes >= 0; text: Qt.formatTime(FixedTime.date(clock.date), ' \
  'shell/security/idle/IdleModel.js#var FAST_RETRY_MS = 5000;#var FAST_RETRY_MS = 5000; var WALL = SystemClock;' \
  'shell/security/idle/IdleModel.js#var FAST_RETRY_MS = 5000;#var FAST_RETRY_MS = 5000; var WALL = WallClock;' \
  'shell/security/lock/Lock.qml#readonly property int verifyGraceMs: 500#readonly property int verifyGraceMs: 500\n    WallClock { id: wallProbe }' \
  'shell/security/lock/LockView.qml#        id: clock#        id: clock\n    }\n    WallClock {\n        id: probe' \
  'shell/security/lock/LockView.qml#    onResumesChanged: clock.refresh()#    onResumesChanged: clock.enabled = false' \
  'shell/security/idle/IdleModel.js#var FAST_EXIT_MS = 2000;#var FAST_EXIT_MS = 2000 + 0 * new Date().getTime();' \
  'shell/security/idle/IdleModel.js#var MAX_FAST_FAILURES = 5;#var MAX_FAST_FAILURES = 5 + 0 * performance.now();' \
  'shell/security/lock/Lock.qml#readonly property int verifyGraceMs: 500#readonly property int verifyGraceMs: 3600000' \
  'shell/security/lock/Lock.qml#readonly property int verifyGraceMs: 500#readonly property int verifyGraceMs: 0' \
  'shell/security/lock/Lock.qml#                secureGrace.restart();#                secureGrace.restart(); secureGrace.repeat = true;' \
  'shell/security/lock/Lock.qml#        interval: ownershipProbe.verifyGraceMs#        interval: ownershipProbe.verifyGraceMs; repeat: true' \
  'shell/security/lock/Lock.qml#                secureGrace.restart();#                secureGrace.restart(); secureGrace.interval = 3600000;' \
  'shell/security/lock/Lock.qml#if (!Machine.monitorQueryAllowed(Hyprland.monitors.values.length)) {#if (false) {' \
  'shell/security/lock/Lock.qml#if (!Machine.monitorQueryAllowed(Hyprland.monitors.values.length)) {#if (!Machine.monitorQueryAllowed(1)) {' \
  'shell/security/lock/Lock.qml#        onTriggered: root.requestMonitors()#        onTriggered: Hyprland.refreshMonitors()' \
  'shell/security/lock/Lock.qml#        verified = false;\n        requestMonitors();#        verified = false;\n        Hyprland.refreshMonitors();' \
  'shell/security/lock/Lock.qml#        if (action === "confirm")\n            requestMonitors();#        if (action === "confirm")\n            Hyprland.refreshMonitors();' \
  'shell/security/lock/Lock.qml#            requestMonitors(); // none while#            Hyprland.refreshMonitors(); // none while' \
  'shell/security/lock/Lock.qml#        restore(false, "start");#        restore(false, "start");\n        Hyprland.refreshMonitors();' \
  'shell/security/lock/Lock.qml#        active: root.hyprland\n        model: Hyprland.monitors#        active: false\n        model: Hyprland.monitors' \
  'shell/security/lock/Lock.qml#        onObjectAdded: Qt.callLater(root.monitorsAdded)\n#' \
  'shell/security/lock/Lock.qml#        if (holding)\n            requestMonitors();#        if (false)\n            requestMonitors();' \
  'shell/security/lock/Lock.qml#                Qt.callLater(root.checkOwnership);#                ;' \
  'shell/security/lock/Lock.qml#        } else if (state === "unlocked") {\n            strandedProbe.stop();#        } else if (state !== "locked") {\n            strandedProbe.stop();' \
  'shell/security/lock/Lock.qml#            if (!emptyModelLogged)\n                console.warn(#            if (true)\n                console.warn(' \
  'shell/security/lock/Lock.qml#            emptyModelLogged = true;#            ;' \
  'shell/security/lock/Lock.qml#        if (emptyModelLogged) {\n            emptyModelLogged = false;#        if (emptyModelLogged) {\n            ;' \
  'shell/security/lock/Lock.qml#        else if (strandedUndecided)\n            checkStranded();\n#' \
  'shell/security/lock/Lock.qml#        else if (strandedUndecided)\n            checkStranded();#        else if (strandedUndecided)\n            release();' \
  'shell/security/lock/Lock.qml#            strandedUndecided = true;\n#' \
  'shell/security/lock/Lock.qml#        strandedUndecided = false;\n        console.info("grassfield-lock: lock requested (#        console.info("grassfield-lock: lock requested (' \
  'shell/security/lock/Lock.qml#            strandedProbe.stop(); // still undecided#            strandedProbe.stop(); strandedUndecided = false; // still undecided' \
  'shell/security/lock/Lock.qml# || fingerprintPam.active || root.fingerprintSpent)# || fingerprintPam.active)' \
  'shell/security/lock/Lock.qml#if (root.displaysOff && !root.fingerprintResumePass)#if (false)' \
  'shell/security/lock/Lock.qml#                root.fingerprintSpent = true;#                root.fingerprintSpent = true;\n                fingerprintRetry.restart();' \
  'shell/security/lock/Lock.qml#        if (!root.fingerprintOpen)\n            return;\n        root.fingerprintOpen = false;#        root.fingerprintOpen = false;' \
  'shell/security/lock/Lock.qml#fingerprintRetry.interval = Machine.fingerprintRetryMs(root.fingerprintMisses);#fingerprintRetry.interval = Machine.FINGERPRINT_RETRY_MS;' \
  'shell/security/lock/Lock.qml#                root.fingerprintReached = true;#                root.fingerprintReached = true;\n                console.info("grassfield-lock: " + fingerprintPam.message);' \
  'shell/security/lock/Lock.qml#&& !fingerprintPam.messageIsError) {#&& fingerprintPam.message !== "") {' \
  'shell/security/lock/Lock.qml#                fingerprintFastEnd.restart();#                root.fingerprintReachedAt = Date.now();' \
  'shell/security/lock/Lock.qml#onError: root.fingerprintEnded()#onError: controller.fingerprintSucceeded()' \
  'shell/security/lock/Lock.qml#if (result === PamResult.Success) {#if (result !== PamResult.MaxTries) {' \
  'shell/security/lock/Lock.qml#        if (root.displaysOff)\n            fingerprintRetry.stop();#        if (root.displaysOff)\n            ;' \
  'shell/security/lock/Lock.qml#        else\n            root.startFingerprint();#        else\n            ;' \
  'shell/security/lock/Lock.qml#        root.resumes += 1;\n        root.fingerprintAfterResume();#        root.resumes += 1;' \
  'shell/security/lock/Lock.qml#Machine.fingerprintOfferedOnResume(fingerprintFile.available, root.fingerprintSpent, controller.lockState)#Machine.fingerprintOfferedOnResume(fingerprintFile.available, false, controller.lockState)' \
  'shell/security/lock/Lock.qml#        root.fingerprintResumePass = true;\n        fingerprintRetry.interval#        root.fingerprintResumePass = true;\n        root.release();\n        fingerprintRetry.interval' \
  'shell/security/lock/Lock.qml#        fingerprintReach.stop();\n        root.fingerprintOpen = false;\n        root.fingerprintMisses = 0;#        fingerprintReach.stop();\n        root.fingerprintOpen = false;' \
  'shell/security/lock/Lock.qml#                root.fingerprintSpent = false;\n                root.startFingerprint();#                root.startFingerprint();' \
  'shell/security/lock/Lock.qml#        fingerprintReach.restart();\n        if (!fingerprintPam.start())#        if (!fingerprintPam.start())' \
  'shell/security/lock/Lock.qml#            fingerprintPam.abort();\n        root.fingerprintEnded();#            fingerprintPam.abort();' \
  'shell/security/lock/Lock.qml#        if (!root.fingerprintOpen || root.fingerprintReached)\n            return;\n        if (fingerprintPam.active)#        if (!root.fingerprintOpen)\n            return;\n        if (fingerprintPam.active)' \
  'shell/security/lock/Lock.qml#        interval: Machine.FINGERPRINT_REACH_TIMEOUT_MS#        interval: 600000' \
  'shell/security/lock/Lock.qml#        onTriggered: root.fingerprintReachTimedOut()#        onTriggered: {}' \
  'shell/security/lock/Lock.qml#                root.fingerprintReached = true;\n                fingerprintReach.stop();#                root.fingerprintReached = true;' \
  'shell/security/lock/Lock.qml#        if (!Machine.fingerprintOfferedOnResume(fingerprintFile.available, root.fingerprintSpent, controller.lockState))#        if (!fingerprintFile.available || root.fingerprintSpent)' \
  'shell/security/lock/Lock.qml#        fingerprintFastEnd.stop();\n        fingerprintReach.stop();\n        root.fingerprintOpen = false;\n        root.fingerprintMisses = 0;#        fingerprintFastEnd.stop();\n        root.fingerprintOpen = false;\n        root.fingerprintMisses = 0;' \
  'shell/platform/Displays.qml#    Component.onCompleted: {\n        publishDebounce.restart();#    Component.onCompleted: {\n        Hyprland.refreshMonitors();\n        publishDebounce.restart();' \
  'shell/platform/Compositor.qml#        const all = Hyprland.monitors ? Hyprland.monitors.values : [];#        Hyprland.refreshMonitors();\n        const all = Hyprland.monitors ? Hyprland.monitors.values : [];'; do
  IFS='#' read -r file from to <<<"$case_"
  cp "$root/$file" "$mut/$file"
  python3 -I - "$mut/$file" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3]
s = open(p).read()
assert a in s, a
open(p, "w").write(s.replace(a, b.replace("\\n", "\n"), 1))
PY
  if python3 -I "$tmp/check.py" "$mut" >/dev/null 2>&1; then bad "mutation: removing '$from' in $file is not caught"; else pass "mutation: removing '$from' in $file is caught"; fi
  cp "$root/$file" "$mut/$file"
done

exit $fail
