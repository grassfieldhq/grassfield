#!/usr/bin/env python3
"""The security root (shell/security.qml) holds nothing but ShellRoot, one SecurityHost and one IpcHandler (ADR-0041 step 1,
S1; S2 adds the host of the lock, idle and the sleep inhibitor, shell/security/SecurityHost.qml, reviewed in its own file): a bounded,
readable check beside the hash pin of tests/security/security_unit.sh (the integrator's decision on #75, round 2: a static
check cannot model all of QML, so the reviewed root is pinned by its SHA-256 and every change to it goes through the opus
security review; this check stays as the second, readable one). Read as the engine reads it, not line by line (round 1: a
next-line brace, a comment before the brace, an indented import and a singleton's property slipped past a grep).

  python3 -I tests/security/root_check.py <root.qml>            exit 0 "ok", or 1 with every rule the root breaks
  python3 -I tests/security/root_check.py --selftest <root.qml>  the root passes and each planted mutant is refused

Rules:
  1. the whole file is ASCII (a U+2028 ends a `//` comment for QML's lexer, and would hide code behind one; no other
     non-ASCII character has a place in this root) and holds no `\\` (no escape spells a name) and no backtick;
  2. with comments (// and /* */) removed and string literals blanked: no `/` (a regex literal's `//` would read as a
     comment) and no `[` (a name written as a string: Qt["createQmlObject"], Quickshell["execDetached"]);
  3. every identifier of the code is one the root uses today (ALLOWED_IDENTIFIERS: an allow-list, never a deny-list: a
     window, a loader, a process, Qt, Reflect, reload, an animation or a security module is simply not in it);
  4. every `import` stands at the start of a line (wherever indented) and names QtQuick, Quickshell, Quickshell.Io or
     qs.security (S2: the module of SecurityHost; never qs.security.lock, .idle, .polkit or .secret, whose types the host
     instantiates in its own reviewed file);
  5. every object instantiated (`Name {`, the file joined on whitespace) is ShellRoot, SecurityHost or IpcHandler,
     SecurityHost exactly once (a second host would run a second idle module and sleep inhibitor) and IpcHandler exactly
     once, with target "security" and the two functions state and heartbeat and no other function.
Standard library only; no Qt needed."""
import re
import sys

ALLOWED_IMPORTS = {"QtQuick", "Quickshell", "Quickshell.Io", "qs.security"}
ALLOWED_TYPES = {"ShellRoot", "SecurityHost", "IpcHandler"}
ALLOWED_IDENTIFIERS = {"import", "QtQuick", "Quickshell", "Io", "qs", "security", "ShellRoot", "id", "root", "settings",
                       "watchFiles", "false", "SecurityHost", "host", "IpcHandler", "target", "function", "state", "string",
                       "return", "hosted", "heartbeat"}


def strip(src, blank_strings=True):
    """The source without comments; its string literals blanked to "" unless `blank_strings` is False. Raises ValueError on
    a backtick, an unterminated comment or string."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                raise ValueError("an unterminated comment")
            out.append(" ")
            i = j + 2
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            if j >= n or src[j] != c:
                raise ValueError("an unterminated string")
            out.append('""' if blank_strings else src[i:j + 1])
            i = j + 1
        elif c == "`":
            raise ValueError("a template string")
        else:
            out.append(c)
            i += 1
    return "".join(out)


def problems(src):
    out = []
    if any(ord(c) > 127 for c in src):
        out.append("a character outside ASCII")
    if "\\" in src:
        out.append("a backslash")
    if out:
        return out  # the scanner below trusts an ASCII, escape-free file
    try:
        code = strip(src)
        with_strings = strip(src, blank_strings=False)
    except ValueError as e:
        return [str(e)]
    if "/" in code:
        out.append("a `/` outside comments and strings (a regex literal, or code hidden behind one)")
    if "[" in code:
        out.append("a `[` outside strings (a name written as a string)")
    for name in sorted(set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", code)) - ALLOWED_IDENTIFIERS):
        out.append(f"the identifier {name}")
    imports = []
    for line in code.splitlines():
        m = re.match(r"^\s*import\s+(\S+)", line)
        if m:
            imports.append(m.group(1))
    if len(re.findall(r"\bimport\b", code)) != len(imports):
        out.append("an `import` that is not an import line")
    for name in imports:
        if name not in ALLOWED_IMPORTS:
            out.append(f"import {name}")
    joined = " ".join(code.split())
    for name in sorted(set(re.findall(r"\b([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\s*\{", joined))):
        if name not in ALLOWED_TYPES:
            out.append(f"{name} instantiated")
    if len(re.findall(r"\bIpcHandler\s*\{", joined)) != 1:
        out.append("not exactly one IpcHandler")
    if len(re.findall(r"\bSecurityHost\s*\{", joined)) != 1 or len(re.findall(r"\bSecurityHost\b", joined)) != 1:
        out.append("not exactly one SecurityHost")
    joined_strings = " ".join(with_strings.split())
    if joined_strings.count('target: "security"') != 1 or re.search(r"\btarget\b", joined_strings) is None or len(re.findall(r"\btarget\s*:", joined_strings)) != 1:
        out.append("the IpcHandler's target is not security, once")
    functions = re.findall(r"\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*:\s*string\s*\{", joined)
    if sorted(functions) != ["heartbeat", "state"] or len(re.findall(r"\bfunction\b", joined)) != 2:
        out.append("the functions are not state and heartbeat, each once")
    return out


def mutants(src):
    """(description, mutated source): each must be refused."""
    head = "import Quickshell.Io\n"
    body = "    id: root\n"
    assert src.count(head) == 1 and src.count(body) == 1, "the root is not the one this selftest knows"
    top = lambda line: src.replace(head, head + line, 1)
    into = lambda text: src.replace(body, body + text + "\n", 1)
    handler = "IpcHandler\n{\ntarget: \"security2\"\nfunction x(): string { return \"\"; }\n}"
    return [
        ("a window with its brace on the next line", into("FloatingWindow\n{\n}")),
        ("a window with a comment before its brace", into("FloatingWindow /* x */ {\n}")),
        ("a window with a comment line before its next-line brace", into("FloatingWindow\n// c\n{\n}")),
        ("an indented import of Quickshell.Wayland and a WlSessionLock with a next-line brace", top("  import Quickshell.Wayland\n").replace(body, body + "WlSessionLock\n{\n}\n", 1)),
        ("a tab-indented import of the lock module and a singleton's property (no brace at all)", top("\timport qs.security.lock\n").replace(body, body + "property bool lk: Lock.locked\n", 1)),
        ("Quickshell.execDetached", into("function f() { Quickshell.execDetached([\"qs\", \"ipc\"]); }")),
        ("Qt.openUrlExternally", into("function g() { Qt.openUrlExternally(\"https://x\"); }")),
        ("a Process", into("Process {\n}")),
        ("Qt.callLater", into("function h() { Qt.callLater(root.state); }")),
        ("a Loader with a source", into("Loader {\nsource: \"x.qml\"\n}")),
        ("a file import", top("import \"lock.js\" as L\n")),
        ("a regex literal hiding a window behind its //", into("property var r: /\\//; PanelWindow {\n}")),
        ("a template string", into("property string t: `x`")),
        ("another module", top("import QtQuick.Controls\n")),
        ("a dynamic import()", into("function i() { return import(\"x\"); }")),
        ("two windows on one line", into("FloatingWindow { PanelWindow { } }")),
        ("a Component", into("Component { id: c }")),
        ("Qt.createComponent", into("function j() { Qt.createComponent(\"x\"); }")),
        ("a second import line of an allowed module with a version and a hidden one after it", top("import QtQuick 2.15 as Q\nimport Quickshell.Wayland as W\n")),
        ("eval", into("function k() { return eval(\"1\"); }")),
        ("a name written as a string: Qt[\"createQmlObject\"]", into("Component.onDestruction: Qt[\"createQmlObject\"](\"import Quickshell.Wayland; WlSessionLock { locked: true }\", root)")),
        ("a name taken through Reflect.get", into("Component.onDestruction: Reflect.get(Qt, \"createQmlObject\")(\"x\", root)")),
        ("a name written as a string: Quickshell[\"execDetached\"]", into("Component.onDestruction: Quickshell[\"execDetached\"]([\"qs\"])")),
        ("a U+2028 ending a // comment before a window", into("// note FloatingWindow { }")),
        ("a window spelled with Unicode escapes", into("\\u0046loatingWindow {\n}")),
        ("execDetached spelled with Unicode escapes", into("Component.onDestruction: Quickshell.\\u0065xecDetached([\"qs\"])")),
        ("a second IpcHandler with a next-line brace", into(handler)),
        ("a NumberAnimation on sequence", into("NumberAnimation on sequence { }")),
        ("Quickshell.reload(true)", into("Component.onDestruction: Quickshell.reload(true)")),
        ("a third function in the handler", src.replace("        function state(): string {", "        function third(): string { return \"\"; }\n        function state(): string {", 1)),
        ("the handler's target renamed", src.replace('target: "security"', 'target: "lock"', 1)),
        ("CRLF line endings with a hidden window", into("FloatingWindow\r\n{\r\n}")),
        ("a second SecurityHost (a second idle module and sleep inhibitor)", into("SecurityHost {\n}")),
        ("a second SecurityHost with a next-line brace and a comment", into("SecurityHost /* x */\n{\n}")),
        ("the lock module imported into the root and its singleton named", top("import qs.security.lock\n").replace(body, body + "property bool lk: Lock.locked\n", 1)),
        ("the idle module imported into the root and an Idle", top("import qs.security.idle\n").replace(body, body + "Idle {\n}\n", 1)),
        ("the polkit module imported into the root (S3 goes through the host)", top("import qs.security.polkit\n")),
    ]


def main(argv):
    if argv[:1] == ["--selftest"]:
        src = open(argv[1], encoding="utf-8").read()
        ok = True
        found = problems(src)
        print(("PASS: " if not found else "FAIL: ") + "security unit root selftest: the root itself passes" + ("" if not found else " [" + "; ".join(found) + "]"))
        ok = ok and not found
        found = problems(src.replace("\n", "\r\n"))
        print(("PASS: " if not found else "FAIL: ") + "security unit root selftest: the root itself passes with CRLF line endings" + ("" if not found else " [" + "; ".join(found) + "]"))
        ok = ok and not found
        for what, text in mutants(src):
            found = problems(text)
            print(("PASS: " if found else "FAIL: ") + "security unit root selftest: " + what + " is refused" + (" (" + found[0] + ")" if found else ""))
            ok = ok and bool(found)
        return 0 if ok else 1
    src = open(argv[0], encoding="utf-8").read()
    found = problems(src)
    if found:
        print("root check: " + argv[0] + ": " + "; ".join(found))
        return 1
    print("root check: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
