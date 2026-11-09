"""The polkit agent as an offscreen test component (tests/security/authagent_flows.sh): the real
shell/security/polkit/AuthAgent.qml with its Quickshell types replaced by plain QML, its logic untouched.

    make_harness.py [--panel] <AuthAgent.qml> <out.qml>

PolkitAgent becomes a plain object the tests drive (isActive, flow), Scope an Item, and PanelWindow an Item of the window's
size, or with --panel the FakePanel beside the output (a window made again each time it is shown, which gets the keyboard
only once mapped, as Quickshell's PanelWindow and a compositor do); the layer-shell, blur and IPC parts go. Each replacement must find exactly what it expects: when AuthAgent.qml changes shape,
the script fails (exit 1) rather than test something else.
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
    if panel:
        args = args[1:]
    if len(args) != 2:
        raise ValueError("usage: make_harness.py [--panel] <AuthAgent.qml> <out.qml>")
    src, out = args
    s = open(src).read()
    for imp in ("import Quickshell\n", "import Quickshell.Io\n", "import Quickshell.Services.Polkit\n", "import Quickshell.Wayland\n",
                'import "../../lib/RunMode.js" as RunMode\n'):
        if s.count(imp) != 1:
            raise ValueError("import not found once: " + imp.strip())
        s = s.replace(imp, "", 1)
    s = replace_block(s, r"\n    PolkitAgent \{", "\n    QtObject {\n        id: agent\n        property bool isActive: false\n"
                      "        property var flow: null\n        property bool isRegistered: true\n"
                      "        property string path: \"/org/grassfield/PolkitAgent\"\n    }")
    # The dev gate reads Quickshell, which the harness has not: a writable flag the tests set (false: a real session).
    dev = '    readonly property bool devSession: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))\n'
    if s.count(dev) != 1:
        raise ValueError("devSession line not found once")
    s = s.replace(dev, "    property bool devSession: false\n", 1)
    s = replace_block(s, r"\n    IpcHandler \{", "\n")
    s = replace_block(s, r"\n        anchors \{\n            top: true", "\n        width: 800\n        height: 600")
    s = replace_block(s, r"\n        Region \{", "\n")
    # The dim's fade animates the window's colour, which goes below (an Item has none).
    s = replace_block(s, r"\n        Behavior on color \{", "\n")
    for old, new in (("\n    PanelWindow {\n", "\n    FakePanel {\n" if panel else "\n    Item {\n"), ("\nScope {\n", "\nItem {\n")):
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
    s = "\n".join(kept)
    aliases = ("    property alias agentMock: agent\n    property alias model: dialogModel\n    property alias sheet: win\n"
               "    property alias holderItem: holder\n    property alias sink: keySink\n")
    if s.count("    id: root\n") != 1:
        raise ValueError("root id not found once")
    s = s.replace("    id: root\n", "    id: root\n" + aliases, 1)
    open(out, "w").write(s)


if __name__ == "__main__":
    try:
        main()
    except ValueError as e:
        sys.exit("make_harness: AuthAgent.qml changed shape: %s" % e)
