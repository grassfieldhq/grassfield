#!/usr/bin/env python3
"""tests/security/lock_palette_render.sh: the REAL content of a lock surface, taken from Lock.qml, for the render probe.

Lock.qml is a singleton that holds the session lock (WlSessionLock, PAM, the marker files): it cannot be loaded offscreen,
and must not be. What a lock surface draws is its `WlSessionLockSurface { ... }` block (the ground colour, the view's loader
and every binding given to the LockView it creates) and the one function of Lock.qml that block calls to colour the ground,
groundOf(). Both are copied here, as they are, into a QML file whose root stands in for the rest of Lock.qml with fixed data
(the same in both appearances) and the surface's own type, a window, becomes a Rectangle of the same colour. A member of
Lock.qml (`root.<name>`) or of its controller (`controller.<name>`) that the block or groundOf() reads and that this file does
not stand in for is an error (exit 3): the probe never draws a surface that is not Lock.qml's.

  python3 -I surface.py <Lock.qml> <out.qml>
Standard library only."""
import re
import sys

ROOT_MEMBERS = {"userName", "avatarReady", "backdrops", "backdropOf", "moving", "displaysOff", "motionOf", "restMotion", "resumes",
                "fromDim", "recoveryDegraded", "filledFields", "focusedSurface", "verify", "groundOf", "stills"}
CONTROLLER_MEMBERS = {"locked", "authenticating", "releasing", "pamAvailable", "pamSuppressed", "message", "submit", "clearMessage",
                      "failed", "clearRequested"}


def skip_string(src, i):
    """The end (exclusive) of the string literal opening at i (a line break ends an unterminated one)."""
    q, j = src[i], i + 1
    while j < len(src):
        if src[j] == "\\":
            j += 2
            continue
        if src[j] == q or src[j] == "\n":
            return j + 1
        j += 1
    return len(src)


def skip_template(src, i):
    """The end (exclusive) of the template literal opening at i, its ${...} expressions read as code."""
    j = i + 1
    while j < len(src):
        if src[j] == "\\":
            j += 2
            continue
        if src[j] == "`":
            return j + 1
        if src.startswith("${", j):
            j = block_end(src, j + 1) + 1
            continue
        j += 1
    return len(src)


def block_end(src, i):
    """The index of the brace closing the one at i, braces in strings, template literals and comments not counted."""
    depth, j = 0, i
    while j < len(src):
        c = src[j]
        if c in "\"'":
            j = skip_string(src, j)
            continue
        if c == "`":
            j = skip_template(src, j)
            continue
        if src.startswith("//", j):
            n = src.find("\n", j)
            j = len(src) if n < 0 else n
            continue
        if src.startswith("/*", j):
            n = src.find("*/", j + 2)
            j = len(src) if n < 0 else n + 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    raise SystemExit(f"surface.py: unbalanced braces from offset {i}")


def one(src, pattern, what):
    found = list(re.finditer(pattern, src, re.M))
    if len(found) != 1:
        sys.stderr.write(f"surface.py: Lock.qml has {len(found)} {what} (expected 1): the probe is stale\n")
        raise SystemExit(3)
    return found[0]


def main(argv):
    src = open(argv[0], encoding="utf-8").read()
    m = one(src, r"^([ \t]*)WlSessionLockSurface\s*\{", "WlSessionLockSurface blocks")
    surface = src[m.start():block_end(src, m.end() - 1) + 1]
    g = one(src, r"^[ \t]*function groundOf\(", "groundOf() functions")
    ground = src[g.start():block_end(src, src.index("{", g.end())) + 1]
    code = surface + "\n" + ground
    for name in sorted(set(re.findall(r"\broot\.(\w+)", code)) - ROOT_MEMBERS):
        sys.stderr.write(f"surface.py: Lock.qml's surface reads root.{name}, which the probe does not stand in for\n")
        raise SystemExit(3)
    for name in sorted(set(re.findall(r"\bcontroller\.(\w+)", code)) | set(re.findall(r"\bfunction on([A-Z]\w*)\(", code))):
        name = name[0].lower() + name[1:]
        if name not in CONTROLLER_MEMBERS:
            sys.stderr.write(f"surface.py: Lock.qml's surface reads controller.{name}, which the probe does not stand in for\n")
            raise SystemExit(3)
    indent = m.group(1)
    head = surface[:surface.index("{") + 1]
    stand_in = (indent + "Rectangle {\n" + indent + "    // The stand-in for the surface window (Quickshell's WlSessionLockSurface): its colour, its screen, its size.\n"
                + indent + "    property var screen: root.screen\n" + indent + "    width: root.width\n" + indent + "    height: root.height")
    surface = stand_in + surface[len(head):]
    out = f"""pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.security
import qs.services
import qs.security.lock

// GENERATED by tests/security/lock_palette_render.d/surface.py from shell/security/lock/Lock.qml (its WlSessionLockSurface
// block and its groundOf(), copied as they are below the stand-ins); never edited, never committed.
Item {{
    id: root

    // The surface's screen (null: not known yet, the ground stays the surface's own colour).
    property var screen: null

    // ---- stand-ins for the rest of Lock.qml: fixed data, the same in both appearances ----
    property string userName: "Robin Example"
    property string avatarReady: ""
    property int backdrops: 0
    property var backdrop: ({{kind: "art", still: "", color: "", artwork: "grassfield", variant: "evening.dark"}})
    function backdropOf(output: string): var {{
        return root.backdrop;
    }}
    property bool moving: false
    property bool displaysOff: false
    function motionOf(output: string): real {{
        return 0;
    }}
    function restMotion(output: string, at: real): void {{
    }}
    property int resumes: 0
    property bool fromDim: false
    // The notice line shows: crash recovery unavailable, and (below) the dev hint of PAM suppressed.
    property bool recoveryDegraded: true
    property int filledFields: 0
    property var focusedSurface: null
    function verify(): void {{
    }}
    property var stills: null

    QtObject {{
        id: controller

        property bool locked: true
        property bool authenticating: false
        property bool releasing: false
        property bool pamAvailable: true
        property bool pamSuppressed: true
        property string message: "Incorrect password"
        signal failed
        signal clearRequested
        function submit(password: string): void {{
        }}
        function clearMessage(): void {{
        }}
    }}

    // ---- copied from Lock.qml ----
{ground}

{surface}
}}
"""
    open(argv[1], "w", encoding="utf-8").write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
