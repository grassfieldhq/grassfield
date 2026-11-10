"""The polkit agent as an offscreen test component (tests/security/authagent_flows.sh): the real
shell/security/polkit/AuthAgent.qml with its Quickshell types replaced by plain QML, its logic untouched.

    make_harness.py [--panel | --real] <AuthAgent.qml> <out.qml>

PolkitAgent becomes a plain object the tests drive (isActive, flow), Scope an Item, and PanelWindow an Item of the window's
size, or with --panel the FakePanel beside the output (a window made again each time it is shown, which gets the keyboard
only once mapped, as Quickshell's PanelWindow and a compositor do); the layer-shell, blur and IPC parts go. Each replacement must find exactly what it expects: when AuthAgent.qml changes shape,
the script fails (exit 1) rather than test something else.

The plain PolkitAgent keeps what Quickshell 0.3.2 does with registration (src/services/polkit/qml.cpp, agentimpl.cpp; the
opus delta review of S3, MAJOR-1): it asks once, when it is made, with the path it was made with; a later path is refused
with Quickshell's warning and the path stays (setPath sets an empty path only); and there is one agent per process: one
made while an earlier one still lives (a Loader deletes later) stays inert and never asks. The harness's root gets what the
tests read and set: `agentMock` (the agent the Loader holds now), `mockRegistrations` (registration attempts) and
`mockTimes` (when each was made, Date.now()), `mockInert` (agents made inert), `mockRefused` (the answer to the next
attempt: refused, never registered) and `mockBlockMs` (each registering agent then stops the event loop that long an
event-loop turn after it is made, as Quickshell's synchronous D-Bus call does when polkitd hangs: round 2, MINOR-A).
Quickshell's ElapsedTimer becomes a Date.now() clock (test code; the stall stops both).

With --real (tests/security/authagent_registration.sh) Quickshell's own PolkitAgent stays, with its imports, the dev gate
and the IPC handler: only the window becomes an Item (offscreen, Quickshell has no window backend), so the registration code
runs as written against the installed Quickshell.
"""
import re
import sys


def block_end(text, start):
    """The end of the { } block whose head starts at `start`."""
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return j + 1
    raise ValueError("unbalanced block at %d" % start)


def replace_block(text, head, replacement):
    m = re.search(head, text)
    if not m:
        raise ValueError("not found: " + head)
    return text[:m.start()] + replacement + text[block_end(text, m.start()):]


def main():
    args = sys.argv[1:]
    panel = args[:1] == ["--panel"]
    real = args[:1] == ["--real"]
    if panel or real:
        args = args[1:]
    if len(args) != 2:
        raise ValueError("usage: make_harness.py [--panel | --real] <AuthAgent.qml> <out.qml>")
    src, out = args
    s = open(src).read()
    if not real:
        s = mock_quickshell(s)
    s = window_as_item(s, panel, real)
    if not real:
        aliases = ("    property alias agentMock: agentHolder.item\n    property alias model: dialogModel\n    property alias sheet: win\n"
                   "    property alias holderItem: holder\n    property alias sink: keySink\n"
                   "    property bool mockRefused: false\n    property int mockRegistrations: 0\n    property int mockInert: 0\n"
                   "    property QtObject mockOwner: null\n    property var mockTimes: []\n    property int mockBlockMs: 0\n"
                   "    function mockBlock(): void {\n        const end = Date.now() + root.mockBlockMs;\n"
                   "        while (Date.now() < end) {}\n    }\n")
        if s.count("    id: root\n") != 1:
            raise ValueError("root id not found once")
        s = s.replace("    id: root\n", "    id: root\n" + aliases, 1)
    open(out, "w").write(s)


def mock_quickshell(s):
    """The Quickshell imports, the PolkitAgent, the dev gate and the IPC handler replaced by plain QML."""
    for imp in ("import Quickshell\n", "import Quickshell.Io\n", "import Quickshell.Services.Polkit\n", "import Quickshell.Wayland\n",
                'import "../../lib/RunMode.js" as RunMode\n'):
        if s.count(imp) != 1:
            raise ValueError("import not found once: " + imp.strip())
        s = s.replace(imp, "", 1)
    mock = ("\n        sourceComponent: QtObject {\n"
            "            id: mockAgent\n"
            "            property bool isActive: false\n"
            "            property var flow: null\n"
            "            property bool isRegistered: false\n"
            "            property string path: root.agentPath\n"
            "            property string pathSet: \"\"\n"
            "            onPathChanged: {\n"
            "                if (pathSet !== \"\" && path !== pathSet) {\n"
            "                    console.warn(\"cannot change path after it has been set.\");\n"
            "                    path = pathSet;\n"
            "                }\n"
            "            }\n"
            "            Component.onCompleted: {\n"
            "                pathSet = path;\n"
            "                if (root.mockOwner !== null) {\n"
            "                    root.mockInert += 1;\n"
            "                    return;\n"
            "                }\n"
            "                root.mockOwner = mockAgent;\n"
            "                root.mockRegistrations += 1;\n"
            "                root.mockTimes = root.mockTimes.concat([Date.now()]);\n"
            "                isRegistered = !root.mockRefused;\n"
            "                if (root.mockBlockMs > 0)\n"
            "                    Qt.callLater(root.mockBlock);\n"
            "            }\n"
            "        }")
    s = replace_block(s, r"\n        sourceComponent: PolkitAgent \{", mock)
    typed = "    readonly property PolkitAgent agent: agentHolder.item as PolkitAgent\n"
    if s.count(typed) != 1:
        raise ValueError("agent property line not found once")
    s = s.replace(typed, "    readonly property var agent: agentHolder.item\n", 1)
    # The dev gate reads Quickshell, which the harness has not: a writable flag the tests set (false: a real session).
    dev = '    readonly property bool devSession: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))\n'
    if s.count(dev) != 1:
        raise ValueError("devSession line not found once")
    s = s.replace(dev, "    property bool devSession: false\n", 1)
    # Quickshell's ElapsedTimer (monotonic) as the wall clock: the harness is test code, and the tests stall the event loop
    # itself (mockBlock), which both clocks see.
    clock = "    ElapsedTimer {\n        id: stallClock\n    }\n"
    if s.count(clock) != 1:
        raise ValueError("stall clock not found once")
    s = s.replace(clock, "    QtObject {\n        id: stallClock\n        property real last: Date.now()\n"
                  "        function restart(): void {\n            last = Date.now();\n        }\n"
                  "        function restartMs(): real {\n            const now = Date.now();\n            const since = now - last;\n"
                  "            last = now;\n            return since;\n        }\n    }\n", 1)
    return replace_block(s, r"\n    IpcHandler \{", "\n")


def window_as_item(s, panel, real):
    """The PanelWindow as an Item (or the FakePanel), its layer-shell, blur and colour properties gone."""
    s = replace_block(s, r"\n        anchors \{\n            top: true", "\n        width: 800\n        height: 600")
    s = replace_block(s, r"\n        Region \{", "\n")
    # The dim's fade animates the window's colour, which goes below (an Item has none).
    s = replace_block(s, r"\n        Behavior on color \{", "\n")
    swaps = [("\n    PanelWindow {\n", "\n    FakePanel {\n" if panel else "\n    Item {\n")]
    if not real:
        swaps.append(("\nScope {\n", "\nItem {\n"))
    for old, new in swaps:
        if s.count(old) != 1:
            raise ValueError("not found once: " + old.strip())
        s = s.replace(old, new, 1)
    # The panel asks the compositor for the keyboard where the agent sets keyboardFocus (FakePanel.wantsKeyboard).
    focus = "        WlrLayershell.keyboardFocus: win.takesKeys ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None\n"
    if s.count(focus) != 1:
        raise ValueError("keyboardFocus line not found once")
    if panel:
        s = s.replace(focus, "        wantsKeyboard: win.takesKeys\n", 1)
    # The window's other layer-shell, blur and colour properties (an Item has none of them).
    dropped = r"\s*(WlrLayershell\.|BackgroundEffect\.|exclusionMode:|color: win\.shown \? Appearance\.withAlpha)"
    lines = s.split("\n")
    kept = [line for line in lines if not re.match(dropped, line)]
    if len(lines) - len(kept) != (5 if panel else 6):
        raise ValueError("expected %d window property lines, found %d" % (5 if panel else 6, len(lines) - len(kept)))
    return "\n".join(kept)


if __name__ == "__main__":
    try:
        main()
    except ValueError as e:
        sys.exit("make_harness: AuthAgent.qml changed shape: %s" % e)
