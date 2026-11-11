#!/usr/bin/env python3
"""Only shell/lib reads GRASSFIELD_* (ADR-0019, GF-089): the one run-mode rule cannot be bypassed by a module that reads the variable itself.

  python3 -I tests/ci/run_mode.py             check the tree, exit 1 on any violation
  python3 -I tests/ci/run_mode.py --selftest  the rule on fixed synthetic trees

Every .qml file of shell/ outside shell/lib is read from Qt's own syntax tree (qmldom --dump-ast, the reader of tests/ci/import_graph.py):
- a string literal that starts with `GRASSFIELD_` is refused (that is how an environment variable is named, whatever calls it: `Quickshell.env`,
  an alias of it, `Quickshell["env"]`);
- a call of `env` whose single argument is not a string literal is refused (a name built at run time cannot be checked);
- `Quickshell.env("HOME")`, `XDG_*`, `LANG` and the other variables that are not GRASSFIELD_* stay free.
A .js file that imports the Quickshell module is refused (its calls cannot be read: it has no tree).
Exception, documented in ADR-0019 and docs/specs/security.md: shell/security/** keeps its own reads of GRASSFIELD_DEV and GRASSFIELD_SESSION (and
the lock's GRASSFIELD_DEV_ALLOW_PAM) because a qs/lib directory on QML_IMPORT_PATH would replace qs.lib; those modules import RunMode.js by a
relative path and pass it the two values themselves (tests/security/ipc_inventory.sh and tests/shell/run_mode_env.sh pin both forms).
Since ADR-0041 S3 the secret sheets run in the security process, which cannot ask Mode either: shell/security/host/SheetHost.qml alone
may also spell GRASSFIELD_PROMPTER_SOCKET, the dev plumbing value `Mode.devValue("PROMPTER_SOCKET")` gave the UI before, read behind
the file's own RunMode.dev gate (Prompter.socketPath ignores it outside a dev session; ADR-0019's amendment of 2026-11-09).
Remove the exception when the packaged shell's import path is fixed.
"""
import importlib.util
import re
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SECURITY_NAMES = {"GRASSFIELD_DEV", "GRASSFIELD_SESSION", "GRASSFIELD_DEV_ALLOW_PAM"}
# One file of shell/security may spell one more name (ADR-0041 S3): path relative to shell/ -> names.
SECURITY_FILE_NAMES = {"security/host/SheetHost.qml": {"GRASSFIELD_PROMPTER_SOCKET"}}
PREFILTER = re.compile(r"env|GRASSFIELD|\\")  # a sound prefilter: the file names no variable without one of these (a backslash can spell a name)
LINE = re.compile(r"\bl:(\d+)")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


IG = load(ROOT / "tests" / "ci" / "import_graph.py", "import_graph")
RUN = load(ROOT / "tests" / "shell" / "run_mode_env.d" / "run.py", "run_mode_env_run")


def walk(node):
    yield node
    for child in node.children:
        yield from walk(child)


def line_of(node):
    for key, value in node.attrs.items():
        if key.endswith("Token"):
            m = LINE.search(value)
            if m:
                return int(m.group(1))
    return 0


def qml_problems(path, in_security, extra=frozenset()):
    """[(line, message)] for one .qml file; `extra`: the names this file of shell/security may spell besides SECURITY_NAMES."""
    text = path.read_text(encoding="utf-8", errors="replace")
    if not PREFILTER.search(text):
        return []
    try:
        tree = RUN.dom_tree(path)
    except (ValueError, OSError) as e:
        return [(0, f"qmldom could not read the file: {e}")]
    out = []
    for node in walk(tree):
        if node.tag == "StringLiteral":
            value = node.attrs.get("value", "")
            if value.startswith("GRASSFIELD_") and not (in_security and (value in SECURITY_NAMES or value in extra)):
                out.append((line_of(node), f"reads {value} itself: ask Mode (Mode.dev, Mode.session, Mode.stateDir, Mode.devValue(\"NAME\"), ...)"))
        elif node.tag == "CallExpression" and len(node.children) == 2:
            callee, args = node.children
            if callee.tag == "FieldMemberExpression" and callee.attrs.get("name") == "env" and args.tag == "ArgumentList":
                if len(args.children) != 1 or args.children[0].tag != "StringLiteral":
                    out.append((line_of(node), "calls env with a name that is not one string literal: it cannot be checked, so it is refused"))
    return out


def problems(shell):
    """Every violation under shell/: [(path, line, message)]."""
    out = []
    lib = (shell / "lib").resolve()
    files = IG.shell_sources(shell)
    qml = [p for p in files if p.suffix == ".qml" and lib not in p.resolve().parents]

    def one(p):
        rel = p.relative_to(shell)
        security = "security" in rel.parts[:1]
        extra = SECURITY_FILE_NAMES.get(rel.as_posix(), frozenset()) if security else frozenset()
        return [(p, ln, msg) for ln, msg in qml_problems(p, security, extra)]

    with ThreadPoolExecutor(max_workers=8) as pool:
        for res in pool.map(one, qml):
            out += res
    for p in files:
        if p.suffix == ".js" and lib not in p.resolve().parents:
            try:
                imports = IG.scanner_imports(p)
            except IG.QtToolError as e:
                out.append((p, 0, str(e)))
                continue
            if ("module", "Quickshell") in imports:
                out.append((p, 0, "a .js file that imports Quickshell can read the environment unseen (it has no syntax tree): refused outside shell/lib"))
    return sorted(out, key=lambda x: (str(x[0]), x[1]))


# --- selftest ---------------------------------------------------------------------------------------------------------

def selftest():
    failures = []

    def run(name, files, expect):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            shell = tmp / "shell"
            for rel, text in {"lib/qmldir": "module qs.lib\nsingleton Mode 1.0 Mode.qml\n", "lib/Mode.qml": 'import Quickshell\nQtObject { property string x: Quickshell.env("GRASSFIELD_DEV") }\n',
                              **files}.items():
                p = shell / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(text, encoding="utf-8")
            got = [f"{p.relative_to(shell)}:{ln}: {msg}" for p, ln, msg in problems(shell)]
            ok = (not got) if expect is None else any(expect in g for g in got)
            if not ok:
                failures.append(f"{name}: expected {'no problem' if expect is None else repr(expect)}, got {got}")

    def svc(body):
        return {"services/S.qml": "import QtQuick\nimport Quickshell\n" + body}

    run("shell/lib may read GRASSFIELD_*", {}, None)
    run("a read in a service is refused", svc('Item { property bool d: Quickshell.env("GRASSFIELD_DEV") === "1" }\n'), "reads GRASSFIELD_DEV itself")
    run("a read of any GRASSFIELD_ name is refused", svc('Item { property string d: Quickshell.env("GRASSFIELD_OPEN_POLICY") }\n'), "reads GRASSFIELD_OPEN_POLICY")
    run("HOME and XDG_* stay free", svc('Item { property string d: Quickshell.env("HOME") + Quickshell.env("XDG_RUNTIME_DIR") }\n'), None)
    run("an alias of Quickshell is seen through its string", svc('Item { property var q: Quickshell; property string d: q.env("GRASSFIELD_DEV") }\n'), "reads GRASSFIELD_DEV")
    run("Quickshell[\"env\"] is seen", svc('Item { property string d: Quickshell["env"]("GRASSFIELD_DEV") }\n'), "reads GRASSFIELD_DEV")
    run("a name built at run time is refused", svc('Item { property string d: Quickshell.env("GRASSFIELD_" + "DEV") }\n'), "not one string literal")
    run("a variable as the name is refused", svc('Item { property string n: "HOME"; property string d: Quickshell.env(n) }\n'), "not one string literal")
    run("an escaped spelling is seen", svc('Item { property string d: Quickshell.env("\\u0047RASSFIELD_DEV") }\n'), "reads GRASSFIELD_DEV")
    run("a template literal name is refused", svc('Item { property string d: Quickshell.env(`HOME`) }\n'), "not one string literal")
    run("a comment naming the variable is fine", svc('// GRASSFIELD_DEV is read by Mode\nItem { /* Quickshell.env("GRASSFIELD_DEV") */ }\n'), None)
    run("a Mode call is fine", {"services/S.qml": 'import QtQuick\nimport qs.lib\nItem { property bool d: Mode.dev; property string c: Mode.devValue("OPEN_POLICY") }\n'}, None)
    run("security may read GRASSFIELD_DEV and GRASSFIELD_SESSION", {"security/L.qml": 'import QtQuick\nimport Quickshell\nItem { property string d: Quickshell.env("GRASSFIELD_DEV") + Quickshell.env("GRASSFIELD_SESSION") + Quickshell.env("GRASSFIELD_DEV_ALLOW_PAM") }\n'}, None)
    run("security may not read another name", {"security/L.qml": 'import QtQuick\nimport Quickshell\nItem { property string d: Quickshell.env("GRASSFIELD_STATE_HOME") }\n'}, "reads GRASSFIELD_STATE_HOME")
    run("the security process's sheets may read the prompter's dev socket (ADR-0041 S3)",
        {"security/host/SheetHost.qml": 'import QtQuick\nimport Quickshell\nItem { property string d: Quickshell.env("GRASSFIELD_PROMPTER_SOCKET") }\n'}, None)
    run("another security file may not read the prompter's dev socket",
        {"security/secret/SecretAgent.qml": 'import QtQuick\nimport Quickshell\nItem { property string d: Quickshell.env("GRASSFIELD_PROMPTER_SOCKET") }\n'},
        "reads GRASSFIELD_PROMPTER_SOCKET")
    run("the sheets' file may not read another name",
        {"security/host/SheetHost.qml": 'import QtQuick\nimport Quickshell\nItem { property string d: Quickshell.env("GRASSFIELD_STATE_HOME") }\n'}, "reads GRASSFIELD_STATE_HOME")
    run("the sheets' exception does not cover the same name elsewhere",
        {"services/SheetHost.qml": 'import QtQuick\nimport Quickshell\nItem { property string d: Quickshell.env("GRASSFIELD_PROMPTER_SOCKET") }\n'}, "reads GRASSFIELD_PROMPTER_SOCKET")
    run("the security exception does not cover another directory", {"services/L.qml": 'import QtQuick\nimport Quickshell\nItem { property string d: Quickshell.env("GRASSFIELD_SESSION") }\n'}, "reads GRASSFIELD_SESSION")
    run("a .js importing Quickshell is refused", {"services/S.js": ".pragma library\n.import Quickshell 1.0 as Q\n"}, "imports Quickshell")
    run("a .js without it is fine", {"services/S.js": ".pragma library\n// GRASSFIELD_DEV in a comment\nfunction f() { return 1; }\n"}, None)
    run("a file that does not parse is refused", svc('Item { property string d: Quickshell.env("GRASSFIELD_DEV" \n'), "qmldom could not read")
    return failures


def main(argv):
    broken = IG.tool_problems()
    if broken:
        for b in broken:
            print("run-mode: " + b)
        print("run-mode: FAILED (the Qt tools are unusable)")
        return 1
    if "--selftest" in argv:
        failures = selftest()
        for f in failures:
            print("FAIL: " + f)
        print("run-mode selftest: " + ("FAILED" if failures else "ok"))
        return 1 if failures else 0
    shell = ROOT / "shell"
    bad = problems(shell)
    for p, ln, msg in bad:
        print(f"{p.relative_to(ROOT)}:{ln}: {msg}")
    print(f"run-mode: {'FAILED, ' + str(len(bad)) + ' problem(s)' if bad else 'ok'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
