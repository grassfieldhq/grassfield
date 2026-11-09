#!/usr/bin/env bash
# GF-AUDIT-001 SEC-03/SEC-04: the shell's IPC surface (Quickshell IpcHandler, callable by any process of the user) is
# exactly the table in docs/specs/security.md "IPC surface", and each function is what its class says:
#   action    has a real-session caller (a binding or gesture in config/hypr/grassfield/*.lua, a session helper in
#             packaging/bin, packaging/shims or packaging/session-bin, a screen corner in shell/desktop/HotCornerActions.js,
#             the UI's calls into the security process in shell/services/LockClient.js (ADR-0041 S2: the UI asks for a lock
#             and leases the screen saver inhibitors there, the same `["target", "function"]` table form),
#             or a Grassfield app in apps/*/src whose call is built on apps/runmode.h shellIpcArgs(), the target and the
#             function as the first two QStringLiterals of the QStringList appended to it) and is not gated
#   dev       refused outside a dev session: its body checks the one dev rule (ADR-0019) by an exact gate, directly or
#             through a property or a function of the same file:
#               - in a security module (shell/security/**): the call
#                 RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION")), RunMode being
#                 shell/lib/RunMode.js imported by a RELATIVE path; never the qs.lib module or its Mode singleton (a
#                 qs/lib directory on QML_IMPORT_PATH would replace them: integrator decision for slice M2);
#               - elsewhere: Mode.dev (qs.lib) or VisualFixtures.dev, or that same relative RunMode.dev call;
#   fixtures  dev session AND GRASSFIELD_VISUAL_FIXTURES=1: Mode.fixtures or VisualFixtures.active (Notifications.testHooks)
# The gates themselves: RunMode.js defines dev and fixtures exactly as the rule, Mode.qml defines dev, fixtures and refused
# exactly from it (imported as "RunMode.js"), VisualFixtures.dev/active are exactly Mode.dev/Mode.fixtures.
# Also (SEC-03) no security module reads GRASSFIELD_DEV outside the gate call, imports qs.lib or reads Mode.
# Exactness (reviews of 360d6fa and 2b8e13a). This is a lint on the source text (comments and string contents blanked
# first, so a guard in a comment or a string never counts):
#   - the files of shell/ are listed from disk, hidden ones included, and no path under shell/ or ui/ (the packaged QML
#     roots) may be hidden: a glob skipped dot files, and a shell/widgets/.Evil.qml loaded by `Loader { source: ".Evil.qml" }`
#     turned the dev hooks on unseen (re-review of e45bdf3). tests/ci/import_graph.py refuses them in the tracked tree and
#     the PKGBUILD in the package (qmlls's `.qmlls.ini`, which no engine loads and the package deletes, excepted);
#   - the definition lines are whole lines (no "|| true" after them);
#   - RunMode.js defines each export once; inside it an exported function is only ever called and an exported variable
#     only defined (no assignment, destructuring or for-of target), and it never reaches its scope indirectly (this,
#     globalThis, eval, Function, Object, Reflect, Proxy, with, arguments);
#   - everywhere else RunMode appears only as RunMode.<exported function>(...) or a read of RunMode.<exported variable>:
#     never bare (so no alias, no Object.defineProperty/assign/freeze on it, no (RunMode).x, no RunMode["x"], no spread),
#     never as a member (X.RunMode), never an assignment, update, delete, destructuring or for-of target. Freezing cannot
#     replace this rule: in a .pragma library file neither Object.freeze(this) nor non-writable properties stop a write
#     through an importer's alias (measured with qs 0.3, re-review of 2b8e13a), and such a write changes RunMode.dev for
#     every importer;
#   - RunMode.js is imported only by QML files, only under the name RunMode (re-reviews of bf9e280 and f03d65a:
#     `import ".../RunMode.js" as RM` then `RM.dev = ...` opened every dev hook in a real session). The imports are read
#     by Qt's own parsers through tests/ci/import_graph.py, never matched as text: a QML file's from its syntax tree
#     (`qmldom --dump-ast`: every UiImport node, its decoded path, its qualifier, the source of its path token), checked
#     against `qmlimportscanner`; a .js file's from `qmlimportscanner`, checked against every `.import` its text spells (a
#     .js module may not import RunMode.js at all). A quoted import path is resolved as the engine resolves it, and refused
#     when it holds an escape (`\` or `%`), is absolute, has a URL scheme or lands outside shell/. The qmldir files pass
#     import_graph's strict reader (module lines and type entries naming a plain file of their directory) and none names
#     RunMode.js or declares Mode, VisualFixtures or RunMode outside their own module; no other file is named RunMode.js,
#     Mode.qml or VisualFixtures.qml;
#   - Quickshell (its env() feeds the gate) is never written to (Quickshell.x = ..., defineProperty) or used bare, except
#     as a Connections target (`target: Quickshell` on its own line). An assignment to Quickshell.env throws and a
#     defineProperty on it changes nothing for other modules (measured with qs 0.3), so this is a lint only;
#   - no shell module uses eval, Function, with, escaped identifiers, constructor, __proto__, Qt.include or
#     Qt.createQmlObject (code that could reach RunMode by a string), and no file imports something as Mode,
#     VisualFixtures or RunMode other than the relative RunMode.js imports, nor declares one of those names (let, const,
#     var, function, class, inline component, enum);
#   - a gate property must be readonly (no Binding or assignment can change it) and defined once in its file (no decoy
#     in a nested object);
#   - a body counts as gated only by a guard of one of these forms, so "<gate> || true" or "!<gate> && false" never counts:
#       if (!G) ... / if (!G || <more refusals>) ...   (refuse first)
#       if (G) <stmt> / if (G && <more conditions>) <stmt>
#       return G ? <answer> : <refusal>
#     and not when the body (or its parameters) binds Mode, RunMode, VisualFixtures, Quickshell, root or a gate property
#     of the file itself (let/const/var, function, class, catch, parameters), which would make the guard read its own value;
#   - in a security module GRASSFIELD_DEV is read only on a whole line `readonly property bool <name>: <gate call>` or
#     `if (!<gate call>)` (so "x = <gate call> || true" fails), and the leaked-value warning of Lock.qml is exempt as that
#     exact line followed by its exact console.warn line (so it can guard nothing else).
# Known limits (static lint; dev_gate.sh and the unit tests exercise the runtime):
#   - what a guard protects is not analysed: "if (G) {} effect()" or an effect placed before the guard passes;
#   - a gate reached through anything but a property of the same file or a root.<function> of it is not followed (the
#     body then counts as ungated, which fails safe);
#   - values reach RunMode through Quickshell.env at runtime: only the exact call text is checked here;
#   - a write to RunMode by a name the lint cannot see (a JS global, a property path it does not model, a member name
#     built from strings such as x["constr" + "uctor"], QML loaded from a URL built at runtime) is not detected, and
#     nothing at runtime makes RunMode tamper-evident; same-user code is out of scope (security.md);
#   - only shell/ is linted: QML elsewhere (ui/, the apps) is not, though a shell import that lands outside shell/ is
#     refused; a directory link under shell/ is not followed (none exists; the package copies links as links).
#   tests/security/ipc_inventory.sh             check the tree, then run the selftest
#   tests/security/ipc_inventory.sh --selftest  only the same checks on mutated copies (look-alike gates, wrong
#                                               definitions, writes to RunMode, shadowed gates...): each must fail
# Static: python3 -I on the sources. Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
exec python3 -I - "$@" <<'PY'
import functools
import glob
import hashlib
import os
import re
import shutil
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, os.path.join(os.getcwd(), "tests", "ci"))
import import_graph as ig  # noqa: E402  (Qt's parsers: qmlimportscanner, qmldom, the strict qmldir reader)

BASE_KEY = [None]  # the tree_key of the loaded checkout: its imports are read in place

SEC_CALL = 'RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))'
# In the analysis text (comments and string contents blanked) the gate call becomes this token, padded to the call's
# length so that positions match the source. "@" cannot appear in QML or JavaScript code outside strings and comments,
# so no code can spell the token itself.
SEC_TOKEN = "RunMode.dev(@GRASSFIELD_DEV@,@GRASSFIELD_SESSION@)"
SEC_TOKEN_PADDED = SEC_TOKEN.ljust(len(SEC_CALL))
RUNMODE_JS = "shell/lib/RunMode.js"
MODE_QML = "shell/lib/Mode.qml"
FIXTURES_QML = "shell/services/VisualFixtures.qml"
LOCK_QML = "shell/security/lock/Lock.qml"
RULE_DEV = 'function dev(devValue, sessionValue) {\n    return devValue === "1" && sessionValue !== "1";\n}'
RULE_FIXTURES = 'function fixtures(devValue, sessionValue, fixturesValue) {\n    return dev(devValue, sessionValue) && fixturesValue === "1";\n}'
RULE_REFUSED = 'var REFUSED = "refused";'
MODE_DEV = 'readonly property bool dev: ' + SEC_CALL
MODE_FIXTURES = ('readonly property bool fixtures: RunMode.fixtures(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"), '
                 'Quickshell.env("GRASSFIELD_VISUAL_FIXTURES"))')
MODE_REFUSED = 'readonly property string refused: RunMode.REFUSED'
# The one line of a security module that may read GRASSFIELD_DEV besides the gate call: Lock.qml's warning that a leaked
# value is ignored (it tests the gate's own result), followed by exactly its warning.
LEAK_WARNING = 'if (Quickshell.env("GRASSFIELD_DEV") === "1" && !root.devHooks)'
LEAK_WARNING_NEXT = ('console.warn("grassfield-lock: GRASSFIELD_DEV=1 ignored in a real session (GRASSFIELD_SESSION=1): no dev hook, '
                     'PAM not suppressed");')
# The only whole lines of a security module that may hold the gate call.
SEC_CALL_LINES = (r"readonly property bool [a-z]\w*: " + re.escape(SEC_CALL), r"if \(!" + re.escape(SEC_CALL) + r"\)")
# Names a hook body must not bind itself (its guard would read its own value).
SHADOW_BASE = ("Mode", "RunMode", "VisualFixtures", "Quickshell", "root")
ASSIGN_AFTER = re.compile(r"\s*(?:=(?![=>])|(?:\*\*|<<|>>>|>>|&&|\|\||\?\?|[-+*/%&|^])=|\+\+|--|(?:of|in)(?![\w$]))")


def SEC_CALL_LINE(line):
    """The line itself when it is one of the accepted gate-call lines of a security module, else None."""
    s = line.strip()
    return s if any(re.fullmatch(p, s) for p in SEC_CALL_LINES) else None


def walk_all(top):
    """Every file and directory link under `top` on disk, hidden ones included (glob skips dot files: re-review of e45bdf3,
    a shell/widgets/.Evil.qml loaded by a Loader was never read)."""
    out = []
    for dirpath, dirnames, filenames in os.walk(top):
        out += [os.path.join(dirpath, n) for n in filenames]
        out += [os.path.join(dirpath, d) for d in dirnames if os.path.islink(os.path.join(dirpath, d))]
    return sorted(out)


def is_hidden(path):
    """A path with a component that starts with a dot (`.qmlls.ini`, qmlls's own configuration, which no engine loads and the
    package deletes, excepted)."""
    parts = path.split("/")
    return any(p.startswith(".") for p in parts[:-1]) or (parts[-1].startswith(".") and parts[-1] != ".qmlls.ini")


def read(path):
    return open(path, encoding="utf-8", errors="replace").read() if os.path.isfile(path) else ""


def load():
    files = {}
    # The packaged QML roots, walked whole: their modules, and every hidden path (refused, see definitions).
    for path in walk_all("shell"):
        if path.endswith((".qml", ".js")) or os.path.basename(path) == "qmldir" or is_hidden(path):
            files[path] = read(path)
    for path in walk_all("ui"):
        if is_hidden(path):
            files[path] = read(path)
    for pattern in ("config/hypr/grassfield/*.lua", "packaging/bin/*", "packaging/shims/*", "packaging/session-bin/*"):
        for path in sorted(glob.glob(pattern)):
            if os.path.isfile(path):
                files[path] = read(path)
    # The apps that call the shell: only through apps/runmode.h shellIpcArgs() (the shell named by its directory).
    for path in sorted(glob.glob("apps/*/src/*.cpp")):
        text = read(path)
        if "shellIpcArgs()" in text:
            files[path] = text
    files["docs/specs/security.md"] = open("docs/specs/security.md", encoding="utf-8").read()
    return files


def _blank(text):
    return [ch if ch == "\n" else " " for ch in text]


def _close(text, i):
    """Index of the "}" closing the "${" substitution whose code starts at i (strings, comments, nesting skipped)."""
    depth, n = 1, len(text)
    while i < n:
        c = text[i]
        if c in "\"'`" or text.startswith("//", i) or text.startswith("/*", i):
            i = _skip(text, i)
            continue
        depth += {"{": 1, "}": -1}.get(c, 0)
        if depth == 0:
            return i
        i += 1
    return n


def _skip(text, i):
    """End of the string, template or comment starting at i."""
    return len(_walk(text[i:], False, False, once=True)) + i


SPECIAL = re.compile(r"[/\"'`]")
BRACKETS = re.compile(r"[()\[\]{};]")


def _walk(text, drop_comments, blank_strings, once=False):
    """`text` with comments and/or string contents replaced by spaces (newlines and the quotes kept: same length).
    The code of a template substitution ${...} stays code (walked again); a "/" where an expression starts opens a
    regular expression literal, skipped as a whole (so a quote inside it opens no string). With `once`, only the token
    at the start is walked and returned."""
    out, i, n = list(text), 0, len(text)
    prev = ""  # last significant character of code before i
    while i < n:
        c = text[i]
        start = i
        if c not in "/\"'`":
            # Plain code up to the next character that may open a comment, a string or a regular expression.
            if once:
                return text[i]
            m = SPECIAL.search(text, i)
            j = m.start() if m else n
            seg = text[i:j].rstrip()
            if seg:
                prev = seg[-1]
            i = j
            continue
        if c == "/" and text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            if drop_comments:
                out[i:j] = " " * (j - i)
            i = j
        elif c == "/" and text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            if drop_comments:
                out[i:j] = _blank(text[i:j])
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            j = min(j, n)
            if blank_strings:
                out[i + 1:j] = _blank(text[i + 1:j])
            i = j + 1
            prev = ")"
        elif c == "`":
            j = i + 1
            while j < n and text[j] != "`":
                if text[j] == "\\":
                    if blank_strings:
                        out[j:j + 2] = _blank(text[j:j + 2])
                    j += 2
                elif text.startswith("${", j):
                    end = _close(text, j + 2)
                    out[j + 2:end] = _walk(text[j + 2:end], drop_comments, blank_strings)
                    j = end + 1
                else:
                    if blank_strings:
                        out[j:j + 1] = _blank(text[j])
                    j += 1
            i = min(j, n) + 1
            prev = ")"
        elif c == "/" and (prev == "" or prev in "(,=:[!&|?{};+-*%<>~^" or re.search(r"(?<![\w$.])(?:return|typeof|case|do|else|in|of|void|yield)\s*$", text[max(0, i - 16):i])):
            j, cls = i + 1, False
            while j < n and text[j] != "\n" and (cls or text[j] != "/"):
                if text[j] == "\\":
                    j += 1
                elif text[j] == "[":
                    cls = True
                elif text[j] == "]":
                    cls = False
                j += 1
            j = min(j, n)
            if blank_strings:
                out[i + 1:j] = _blank(text[i + 1:j])
            i = j + 1
            prev = ")"
        else:
            if not c.isspace():
                prev = c
            i += 1
        if once:
            return text[start:min(i, n)]
    return "".join(out)


@functools.lru_cache(maxsize=None)
def analysis(text):
    """The text the gate analysis reads: comments dropped, the exact gate call replaced by SEC_TOKEN, string contents
    blanked. Same length as `text`."""
    return _walk(_walk(text, True, False).replace(SEC_CALL, SEC_TOKEN_PADDED), False, True)


def block_end(text, start):
    depth, i = 1, start
    while depth and i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    return i


def is_security(path):
    return path.startswith("shell/security/")


def is_module(path):
    return path.startswith("shell/") and path.endswith((".qml", ".js"))


@functools.lru_cache(maxsize=None)
def runmode_aliases(text):
    return re.findall(r'^\s*\.?import\s+"([^"]+)"\s+as\s+RunMode\s*$', text, re.M)


# --- Imports of RunMode.js, read by Qt's own parsers (decision after the re-review of f03d65a: no hand matching of import
# text; the machinery of tests/ci/import_graph.py). A QML file's imports come from its syntax tree (`qmldom --dump-ast`:
# each UiImport node with its decoded file name, its qualifier and the place of the path token in the source); a .js
# file's from `qmlimportscanner`, checked against every `.import` its text spells. Import paths are resolved as the engine
# resolves them; a `\` or `%` in an import path is refused outright (the engine decodes both, nothing in the tree uses
# them), and so is a quoted import that is absolute, has a URL scheme or lands outside shell/.
_DOM = {}
GATE_NAMES = ("Mode", "VisualFixtures", "RunMode")
UI_IMPORT_ATTR = re.compile(r'\b(fileName|importId|fileNameToken)="([^"]*)"')
TOKEN_SPAN = re.compile(r"\boff:(\d+) len:(\d+)\b")


def dom_imports(path):
    """The UiImport nodes of a .qml file from qmldom: [(file name or "", qualifier or "", (offset, length) of the path token)],
    or a string when the file does not parse. Cached by content."""
    key = hashlib.sha1(path.read_bytes()).hexdigest()
    if key not in _DOM:
        try:
            r = ig.qt_run([ig.QMLDOM, "--dump-ast", str(path)])
        except ig.QtToolError as e:
            _DOM[key] = str(e)
            return _DOM[key]
        if r.returncode != 0 or "<UiProgram>" not in r.stdout:
            _DOM[key] = "qmldom cannot parse it"
        else:
            out = []
            for line in r.stdout.split("\n"):
                if "<UiImport " not in line:
                    continue
                attrs = dict(UI_IMPORT_ATTR.findall(line))
                span = TOKEN_SPAN.search(attrs.get("fileNameToken", ""))
                out.append((attrs.get("fileName", ""), attrs.get("importId", ""), (int(span.group(1)), int(span.group(2))) if span else None))
            _DOM[key] = out
    return _DOM[key]


def prefetch_dom(paths):
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(dom_imports, paths))


def source_span(path, span):
    """The source text of a token from its qmldom offset and length (UTF-16 code units, as Qt counts them)."""
    data = path.read_text(encoding="utf-8", errors="replace").encode("utf-16-le")
    return data[2 * span[0]:2 * (span[0] + span[1])].decode("utf-16-le", errors="replace")


def resolve_import(path, shell, name):
    """(resolved Path inside shell/ or None, refusal or None) for a quoted import `name` of file `path`."""
    if "\\" in name or "%" in name:
        return None, "an escape (\\ or %%) in the import path \"%s\"" % name
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", name) or name.startswith("/"):
        return None, "import \"%s\" is not a plain relative path" % name
    target = Path(os.path.normpath(path.parent / name))
    try:
        target.resolve().relative_to(shell.resolve())
    except ValueError:
        return None, "import \"%s\" lands outside shell/" % name
    if not target.exists():
        return None, "import \"%s\" names nothing that exists" % name
    return target, None


def is_runmode(target, shell):
    rm = shell / "lib" / "RunMode.js"
    try:
        return target.name == "RunMode.js" or (rm.exists() and os.path.samefile(target, rm))
    except OSError:
        return False


def runmode_import_failures(tree, rels):
    """Failures of the imports of the modules `rels` (paths relative to `tree`, which holds shell/)."""
    shell = tree / "shell"
    out = []
    qml = [tree / r for r in rels if r.endswith(".qml")]
    js = [tree / r for r in rels if r.endswith(".js")]
    prefetch_dom(qml)
    ig.prefetch_imports(qml + js)
    for path in qml:
        rel = str(path.relative_to(tree))
        nodes = dom_imports(path)
        if isinstance(nodes, str):
            out.append("%s: %s" % (rel, nodes))
            continue
        quoted = set()
        for name, qualifier, span in nodes:
            if name:
                quoted.add(name)
                raw = source_span(path, span) if span else ""
                if raw not in ('"%s"' % name, "'%s'" % name):
                    out.append("%s: the import path token %s is not the plain string \"%s\" (an escape?)" % (rel, raw or "?", name))
                    continue
                target, why = resolve_import(path, shell, name)
                if why:
                    out.append("%s: %s" % (rel, why))
                    continue
                runmode = is_runmode(target, shell)
            else:
                runmode = False
            if runmode and qualifier != "RunMode":
                out.append("%s: imports RunMode.js as %s (only as RunMode)" % (rel, qualifier or "nothing"))
            elif not runmode and qualifier in GATE_NAMES:
                out.append("%s: imports %s as %s (a gate name)" % (rel, name or "a module", qualifier))
        # The scanner reads the same file with the same parser: every quoted import it reports must be a node above.
        try:
            for kind, name in ig.scanner_imports(path):
                if kind in ("directory", "javascript") and name not in quoted:
                    out.append("%s: qmlimportscanner reports an import \"%s\" the syntax tree does not show" % (rel, name))
        except ig.QtToolError as e:
            out.append("%s: %s" % (rel, e))
    for path in js:
        rel = str(path.relative_to(tree))
        try:
            entries = ig.scanner_imports(path)
        except ig.QtToolError as e:
            out.append("%s: %s" % (rel, e))
            continue
        seen = {name for _, name in entries}
        # The scanner skips a directive after code or after a split pragma: an `.import` the text spells and the scanner does
        # not report is refused (a comment that spells one is a false positive, never a miss), as is any escape in it.
        for m in ig.JS_IMPORT.finditer(path.read_text(encoding="utf-8", errors="replace")):
            arg = next(g for g in m.groups() if g is not None)
            if arg not in seen or "\\" in arg or "%" in arg:
                out.append("%s: `.import %s` is not read as written by qmlimportscanner (an escape, or a directive after code?)" % (rel, arg))
        for kind, name in entries:
            if kind != "javascript":
                continue
            target, why = resolve_import(path, shell, name)
            if why:
                out.append("%s: %s" % (rel, why))
            elif is_runmode(target, shell):
                out.append("%s: a .js module imports RunMode.js (only QML files may, as RunMode)" % rel)
    return out


def qmldir_failures_text(files):
    """The qmldir files of `files` by the strict reader of import_graph: only `module` lines and type entries naming a plain
    file of the same directory (no import, depends, plugin, path or escape); and no entry may name RunMode.js, under any type
    name, nor declare Mode or VisualFixtures anywhere but their own module."""
    out = []
    allowed = {("shell/lib/qmldir", "singleton Mode 1.0 Mode.qml"), ("shell/services/qmldir", "singleton VisualFixtures 1.0 VisualFixtures.qml")}
    for path in sorted(p for p in files if p.startswith("shell/") and os.path.basename(p) == "qmldir"):
        for n, raw in enumerate(ig.QT_EOL.split(files[path]), 1):
            line = raw.split("#", 1)[0].strip()
            if not line or ig.QMLDIR_MODULE.match(line):
                continue
            m = ig.QMLDIR_ENTRY.match(line)
            if m is None:
                out.append("%s:%d `%s` is not a plain module line or a type entry naming a file of this directory" % (path, n, line))
            elif m.group(1) == "RunMode.js":
                out.append("%s:%d `%s` exposes RunMode.js" % (path, n, line))
            elif (line.split()[0] in GATE_NAMES or line.split()[:2][-1] in GATE_NAMES) and (path, line) not in allowed:
                out.append("%s:%d `%s` declares a gate name" % (path, n, line))
    return out


def import_failures(files, base_key):
    """runmode_import_failures on the tree `files` describes: the checkout itself when it is the loaded tree, else a scratch
    copy of its shell/ modules (the Qt tools read files)."""
    shell_files = {p: t for p, t in files.items() if p.startswith("shell/") and (p.endswith((".qml", ".js")) or os.path.basename(p) == "qmldir")}
    rels = sorted(p for p in shell_files if p.endswith((".qml", ".js")))
    if tree_key(files) == base_key:
        return runmode_import_failures(Path(os.getcwd()), rels)
    tmp = Path(tempfile.mkdtemp(prefix="ipc-inventory-"))
    try:
        for rel, text in shell_files.items():
            (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            (tmp / rel).write_text(text, encoding="utf-8")
        return runmode_import_failures(tmp, rels)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def tree_key(files):
    h = hashlib.sha1()
    for rel in sorted(files):
        if rel.startswith("shell/"):
            h.update(rel.encode() + b"\0" + files[rel].encode("utf-8", errors="replace") + b"\0")
    return h.hexdigest()


@functools.lru_cache(maxsize=None)
def relative_runmode(path, text):
    """The file imports shell/lib/RunMode.js by a relative path, as RunMode, once."""
    aliases = runmode_aliases(text)
    return len(aliases) == 1 and os.path.normpath(os.path.join(os.path.dirname(path), aliases[0])) == RUNMODE_JS


@functools.lru_cache(maxsize=None)
def imports_qs_lib(text):
    return re.search(r"^\s*import\s+qs\.lib\b", text, re.M) is not None


def whole_line(text, line):
    return re.search(r"^[ \t]*" + re.escape(line) + r"[ \t]*$", text, re.M) is not None


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def write_target(code, start, end):
    """The reference code[start:end] is written to: an assignment, update, delete, for-of/in or destructuring target."""
    before = code[max(0, start - 64):start].rstrip()
    if before.endswith(("++", "--", "...")) or re.search(r"(?<![\w$])delete$", before):
        return True
    if ASSIGN_AFTER.match(code, end):
        return True
    # A pattern around it: a group that encloses the reference and is itself followed by an assignment (multi-line
    # destructuring included), up to the end of the statement.
    depth = 0
    for m in BRACKETS.finditer(code, end):
        c = m.group()
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                if ASSIGN_AFTER.match(code, m.end()):
                    return True
            else:
                depth -= 1
        elif depth == 0:
            break
    return False


def runmode_exports(rmcode):
    return (tuple(re.findall(r"^function\s+(\w+)\s*\(", rmcode, re.M)), tuple(re.findall(r"^var\s+(\w+)\s*=", rmcode, re.M)))


def runmode_misuse(files, fn_exports, var_exports):
    """Lines (path:line) that use RunMode other than as RunMode.<function>(...) or a read of RunMode.<variable>."""
    return ["%s:%d" % (path, n) for path in sorted(p for p in files if is_module(p) and p != RUNMODE_JS)
            for n in file_runmode_misuse(files[path], fn_exports, var_exports)]


MEMBER = re.compile(r"\s*\.\s*([A-Za-z_$][\w$]*)")
CALL = re.compile(r"\s*\(")


@functools.lru_cache(maxsize=None)
def file_runmode_misuse(text, fn_exports, var_exports):
    """Line numbers of one file's misuses of RunMode (cached: a selftest mutant re-analyses only the file it changes)."""
    out = []
    a = code_without_imports(text)
    # Every RunMode token, also after a dot (X.RunMode: RunMode.js reached as a member of something else) or in a
    # spread (...RunMode): only RunMode.<function>(...) and reads of RunMode.<variable> pass.
    for m in re.finditer(r"(?<![\w$])RunMode(?![\w$])", a):
        u = MEMBER.match(a, m.end())
        name = u.group(1) if u else None
        if member_dot_before(a, m.start()):
            ok = False
        elif name in fn_exports:
            ok = CALL.match(a, u.end()) is not None
        elif name in var_exports:
            ok = not write_target(a, m.start(), u.end())
        else:
            ok = False
        if not ok:
            out.append(line_of(a, m.start()))
    return tuple(out)


@functools.lru_cache(maxsize=None)
def code_without_imports(text):
    return re.sub(r"^[ \t]*\.?import\b[^\n]*", lambda m: " " * len(m.group(0)), analysis(text), flags=re.M)


def member_dot_before(a, start):
    """The token at `start` follows a member dot (x.Name, x?.Name), not a spread (...Name)."""
    before = a[max(0, start - 64):start].rstrip()
    return before.endswith(".") and not before.endswith("...")


def quickshell_misuse(files):
    """Lines (path:line) that write to a member of Quickshell (whose env() feeds the gate) or use it bare, except as a
    Connections target (`target: Quickshell` on its own line)."""
    return ["%s:%d" % (path, n) for path in sorted(p for p in files if is_module(p)) for n in file_quickshell_misuse(files[path])]


@functools.lru_cache(maxsize=None)
def file_quickshell_misuse(text):
    out = []
    a = code_without_imports(text)
    for m in re.finditer(r"(?<![\w$])Quickshell(?![\w$])", a):
        end = a.find("\n", m.end())
        line = a[a.rfind("\n", 0, m.start()) + 1:end if end >= 0 else len(a)]
        u = MEMBER.match(a, m.end())
        if member_dot_before(a, m.start()):
            ok = False
        elif u:
            ok = not write_target(a, m.start(), u.end())
        else:
            ok = line.strip() == "target: Quickshell"
        if not ok:
            out.append(line_of(a, m.start()))
    return tuple(out)


@functools.lru_cache(maxsize=None)
def file_dynamic_shadowing(text):
    """Line numbers of one file's dynamic-code uses and of its own Mode/VisualFixtures/RunMode (cached per text)."""
    a = analysis(text)
    words = ("eval", "Function", "with", "\\u", "constructor", "__proto__", "createQmlObject", "include")
    dyn = [] if not any(w in a for w in words) else [line_of(a, m.start()) for m in re.finditer(
        r"(?<![\w$.])(?:eval|Function)\s*\(|(?<![\w$.])with\s*\(|\bnew\s+Function\b|\\u"
        r"|(?<![\w$])(?:constructor|__proto__|createQmlObject)(?![\w$])|\bQt\s*\.\s*include\b", a)]
    shadow = [line_of(a, m.start()) for m in re.finditer(
        r"\b(?:let|const|var|function|class|component|enum)\s+(?:Mode|VisualFixtures|RunMode)(?![\w$])", a)]
    return tuple(dyn), tuple(shadow)


def definitions(files):
    """Failures of the gate definitions (RunMode.js, Mode.qml, VisualFixtures.qml) and of the uses of RunMode."""
    out = []
    rm = files.get(RUNMODE_JS, "")
    if RULE_DEV not in rm or rm.count("function dev(") != 1:
        out.append("RunMode.js does not define dev exactly as the rule")
    if RULE_FIXTURES not in rm or rm.count("function fixtures(") != 1:
        out.append("RunMode.js does not define fixtures exactly as dev and GRASSFIELD_VISUAL_FIXTURES")
    if not whole_line(rm, RULE_REFUSED):
        out.append('RunMode.js does not define REFUSED as "refused"')
    # Inside RunMode.js: each export defined once, at the top level; an exported function only ever called afterwards,
    # an exported variable never named again (no assignment, destructuring or for-of target can rebind either).
    rmcode = analysis(rm)
    fn_exports, var_exports = runmode_exports(rmcode)
    for name in sorted(set(fn_exports + var_exports)):
        defs = re.findall(r"^(?:function\s+%s\s*\(|var\s+%s\s*=)" % (name, name), rmcode, re.M)
        bad = len(defs) != 1
        for m in re.finditer(r"(?<![\w$.])%s(?![\w$])" % re.escape(name), rmcode):
            prefix = rmcode[rmcode.rfind("\n", 0, m.start()) + 1:m.start()]
            if re.fullmatch(r"(?:function|var)\s+", prefix):
                continue
            if name in fn_exports and re.compile(r"\s*\(").match(rmcode, m.end()) and not re.search(r"\bfunction\s*$", prefix):
                continue
            bad = True
        if bad:
            out.append("RunMode.js defines, rebinds or passes %s other than by its one definition and calls" % name)
    if re.search(r"(?<![\w$.])(?:this|globalThis|eval|Function|Object|Reflect|Proxy|with|arguments)(?![\w$])", rmcode):
        out.append("RunMode.js reaches its own scope indirectly (this, globalThis, eval, Function, Object, Reflect, Proxy, with, arguments)")
    misuse = runmode_misuse(files, fn_exports, var_exports)
    if misuse:
        out.append("RunMode used other than as RunMode.<function>(...) or a read of RunMode.<variable> (bare, aliased, written): " + ", ".join(misuse))
    # RunMode.js is imported only under the name RunMode (re-reviews of bf9e280 and f03d65a, B1: `import ".../RunMode.js" as RM`
    # then `RM.dev = ...` opened every dev hook in a real session), read by Qt's own parsers, whatever the spelling.
    renamed = import_failures(files, BASE_KEY[0]) + qmldir_failures_text(files)
    if renamed:
        out.append("imports of RunMode.js or the gate names that are not exactly `import \"<relative path>\" as RunMode` from QML: "
                   + "; ".join(renamed[:8]) + ("" if len(renamed) <= 8 else " (+%d more)" % (len(renamed) - 8)))
    qs_misuse = quickshell_misuse(files)
    if qs_misuse:
        out.append("modules write to a member of Quickshell (env() feeds the gate) or use it bare: " + ", ".join(qs_misuse))
    # No module can reach RunMode by a string or shadow the gate names at file level.
    dynamic, shadowing = [], []
    hidden = sorted(p for p in files if p.startswith(("shell/", "ui/")) and is_hidden(p))
    if hidden:
        out.append("hidden paths under shell/ or ui/ (QML loads them by name, e.g. Loader { source: \".Evil.qml\" }, and the package "
                   "would ship them): " + ", ".join(hidden))
    canonical = {"RunMode.js": RUNMODE_JS, "Mode.qml": MODE_QML, "VisualFixtures.qml": FIXTURES_QML}
    for path in sorted(files):
        if not path.startswith("shell/"):
            continue
        base = os.path.basename(path)
        if base in canonical and path != canonical[base]:
            shadowing.append("%s (a second %s)" % (path, base))
    for path in sorted(p for p in files if is_module(p)):
        dyn, shadow = file_dynamic_shadowing(files[path])
        dynamic += ["%s:%d" % (path, n) for n in dyn]
        shadowing += ["%s:%d" % (path, n) for n in shadow]
    if dynamic:
        out.append("modules use eval, Function, with, an escaped identifier, constructor, __proto__, Qt.include or createQmlObject "
                   "(they could reach RunMode unseen): " + ", ".join(dynamic))
    if shadowing:
        out.append("modules import or declare their own Mode, VisualFixtures or RunMode: " + ", ".join(shadowing))
    mode = files.get(MODE_QML, "")
    if runmode_aliases(mode) != ["RunMode.js"]:
        out.append("Mode.qml does not import RunMode.js (its own directory) as RunMode")
    for line, what in ((MODE_DEV, "dev"), (MODE_FIXTURES, "fixtures"), (MODE_REFUSED, "refused")):
        if not whole_line(mode, line) or len(re.findall(r"property\s+\w+\s+%s\s*:" % what, mode)) != 1:
            out.append("Mode.qml does not define %s exactly from RunMode.js" % what)
    fx = files.get(FIXTURES_QML, "")
    if not imports_qs_lib(fx) or not whole_line(fx, "readonly property bool dev: Mode.dev") or len(re.findall(r"property\s+bool\s+dev\s*:", fx)) != 1:
        out.append("VisualFixtures.dev is not exactly Mode.dev")
    if not whole_line(fx, "readonly property bool active: Mode.fixtures") or len(re.findall(r"property\s+bool\s+active\s*:", fx)) != 1:
        out.append("VisualFixtures.active is not exactly Mode.fixtures")
    return out


def gate_exprs(path, text, defs_ok):
    """The exact dev and fixtures gate expressions (as in the analysis text) a file may use."""
    dev, fixtures = [], []
    if relative_runmode(path, text) and not (is_security(path) and imports_qs_lib(text)):
        dev.append(SEC_TOKEN)
    if not is_security(path) and defs_ok:
        dev.append("VisualFixtures.dev")
        fixtures.append("VisualFixtures.active")
        if imports_qs_lib(text):
            dev.append("Mode.dev")
            fixtures.append("Mode.fixtures")
    return tuple(dev), tuple(fixtures)


@functools.lru_cache(maxsize=None)
def prop_index(atext):
    """(how many times each property name is declared, the first whole-line `readonly property bool` expression of each)."""
    counts = {}
    for name in re.findall(r"\bproperty\s+\w+\s+(\w+)\s*:", atext):
        counts[name] = counts.get(name, 0) + 1
    exprs = {}
    for name, expr in re.findall(r"^[ \t]*readonly\s+property\s+bool\s+(\w+)\s*:\s*(.+?)[ \t]*$", atext, re.M):
        exprs.setdefault(name, expr)
    return counts, exprs


def prop_expr(atext, prop):
    """The expression of `readonly property bool <prop>` when the file defines that property exactly once (any kind), as
    a whole line; None otherwise (not readonly, defined twice, e.g. a decoy in a nested object, or absent)."""
    counts, exprs = prop_index(atext)
    return exprs.get(prop) if counts.get(prop, 0) == 1 else None


@functools.lru_cache(maxsize=None)
def gate_props(atext, exprs):
    return frozenset(p for p in re.findall(r"\bproperty\s+bool\s+(\w+)\s*:", atext) if prop_expr(atext, p) in exprs)


def fn_def(atext, fn):
    """(parameters, body) of `function <fn>(...)` in the file, or None."""
    m = re.search(r"function\s+%s\s*\(([^)]*)\)[^{]*\{" % re.escape(fn), atext)
    return (m.group(1), atext[m.end():block_end(atext, m.end())]) if m else None


def declared(body, pos):
    """The binding part of each declarator of the let/const/var declaration whose declarators start at `pos`."""
    out, depth, i, init = [], 0, pos, False
    while i < len(body):
        c = body[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth < 0:
                break
        elif depth == 0 and c in ";\n":
            break
        elif depth == 0 and c == "=" and body[i + 1:i + 2] not in ("=", ">") and body[i - 1:i] not in ("=", "!", "<", ">"):
            init = True
        elif depth == 0 and c == ",":
            init = False
        elif depth == 0 and not init and re.match(r"(?:of|in)(?![\w$])", body[i:i + 3]) and not re.match(r"[\w$]", body[i - 1:i]):
            init = True
        if not init:
            out.append(c)
        i += 1
    return "".join(out)


def shadows(params, body, names):
    """The body (or its parameters) binds one of `names`, or uses eval/Function/with: its guard proves nothing."""
    if re.search(r"(?<![\w$.])(?:eval|Function|with)(?![\w$])", body):
        return True
    bound = [params]
    bound += [declared(body, m.end()) for m in re.finditer(r"(?<![\w$.])(?:let|const|var)(?![\w$])", body)]
    bound += re.findall(r"\b(?:function|class)\s+([A-Za-z_$][\w$]*)", body)
    bound += re.findall(r"\bfunction\s*[\w$]*\s*\(([^)]*)\)", body)
    bound += re.findall(r"\(([^()]*)\)\s*=>", body)
    bound += re.findall(r"([A-Za-z_$][\w$]*)\s*=>", body)
    bound += re.findall(r"\bcatch\s*\(([^)]*)\)", body)
    return bool(set(re.findall(r"[A-Za-z_$][\w$]*", " ".join(bound))) & set(names))


def guarded(body, gate):
    """`gate` (a regex) guards the body in one of the accepted forms (see the header)."""
    g = r"(?<![\w.])" + gate + r"(?![\w.(])"
    return bool(re.search(r"\bif\s*\(\s*!\s*" + g + r"\s*(?:\)|\|\|)", body)
                or re.search(r"\bif\s*\(\s*" + g + r"\s*(?:\)|&&)", body)
                or re.search(r"\breturn\s+" + g + r"\s*\?", body))


def gated_by(params, body, atext, exprs, depth=0):
    """The body (analysis text) checks one of `exprs` in an accepted guard form, without binding the gate names itself."""
    if not exprs or shadows(params, body, set(SHADOW_BASE) | gate_props(atext, exprs)):
        return False
    # Exact gates (follow-up N6: a name that merely starts or ends like a gate, e.g. root.devSession reading GRASSFIELD_DEV
    # alone, MyMode.dev or Mode.devx, is not one), in a guard form only.
    for expr in exprs:
        if guarded(body, re.escape(expr)):
            return True
    # Properties read by the body (root.x or a bare x), defined in this file once, readonly, as exactly a gate expression.
    for prop in set(re.findall(r"(?<![\w.])(?:root\.)?([A-Za-z_]\w*)(?![\w(])", body)):
        if prop_expr(atext, prop) in exprs and guarded(body, r"(?:root\.)?" + re.escape(prop)):
            return True
    # Forwarding to a function of the same file (root.devStatus(), root.hookInvoke(id)): that function must be gated.
    if depth == 0:
        for fn in set(re.findall(r"\broot\.(\w+)\(", body)):
            found = fn_def(atext, fn)
            if found is not None and gated_by(found[0], found[1], atext, exprs, 1):
                return True
    return False


def check(files):
    """(passes, failures) of every check on this set of files."""
    passes, fails = [], []
    code, own_gates = {}, []
    for path in sorted(p for p in files if p.startswith("shell/") and p.endswith(".qml")):
        src = files[path]
        atext = analysis(src)
        for m in re.finditer(r"IpcHandler\s*\{", atext):
            end = block_end(atext, m.end())
            block, ablock = src[m.end():end], atext[m.end():end]
            t = re.search(r'\btarget:\s*"([^"\n]*)"', ablock)
            target = block[t.start(1):t.end(1)] if t else "?"
            # SEC-03: one gate. An IPC handler never reads the dev variables itself (it checks one of the exact gates).
            if re.search(r'Quickshell\.env\("GRASSFIELD_(DEV|SESSION)"\)', block.replace(SEC_CALL, "")):
                own_gates.append("%s (%s)" % (target, path))
            for f in re.finditer(r"function\s+(\w+)\s*\(([^)]*)\)[^{]*\{", ablock):
                code[(target, f.group(1))] = (path, f.group(2), ablock[f.end():block_end(ablock, f.end())])

    section = re.search(r"<!-- ipc-inventory:begin -->(.*?)<!-- ipc-inventory:end -->", files["docs/specs/security.md"], re.S)
    doc = {}
    if not section:
        fails.append("docs/specs/security.md has no ipc-inventory table")
    else:
        for line in section.group(1).splitlines():
            cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|")]
            if len(cells) < 3 or cells[0] in ("Target", "") or set(cells[0]) <= {"-", ":"}:
                continue
            for fn in cells[1].split(","):
                doc[(cells[0], fn.strip().strip("`"))] = cells[2]
    missing = sorted(set(code) - set(doc))
    stale = sorted(set(doc) - set(code))
    if missing:
        fails.append("functions not in docs/specs/security.md: " + ", ".join(t + "." + f for t, f in missing))
    if stale:
        fails.append("documented functions that do not exist: " + ", ".join(t + "." + f for t, f in stale))
    if not missing and not stale:
        passes.append("%d functions of %d targets, all documented" % (len(code), len({t for t, _ in code})))

    # Real-session callers: the Hyprland config, the session helpers and stand-ins, the screen corners. A `call <target> <fn>`
    # counts only on a line that runs `qs ipc` (comments say "call" too).
    bindings = files.get("config/hypr/grassfield/bindings.lua", "")
    callers = set(re.findall(r'shell\("(\w+)",\s*"(\w+)', bindings))
    # The lock key goes to the security instance (ADR-0041 S2): bindings.lua's security() helper.
    callers |= set(re.findall(r'security\("(\w+)",\s*"(\w+)', bindings))
    callers |= {("switcher", f) for f in re.findall(r'(?:switcher_request|in_switcher_else)\("(\w+)"', bindings)}
    for path in sorted(files):
        if path.startswith(("config/hypr/grassfield/", "packaging/bin/", "packaging/shims/", "packaging/session-bin/")):
            for line in files[path].splitlines():
                # bindings.lua builds its requests on `qs_ipc` (the qs ipc command with Quickshell's option variables
                # cleared, re-review of bf9e280 M1).
                if "qs ipc" in line or (path.endswith(".lua") and "qs_ipc .." in line):
                    callers |= set(re.findall(r"call (\w+) (\w+)", line))
    callers |= set(re.findall(r'\["(\w+)",\s*"(\w+)"\]', files.get("shell/desktop/HotCornerActions.js", "")))
    callers |= set(re.findall(r'\["(\w+)",\s*"(\w+)"\]', files.get("shell/services/LockClient.js", "")))
    # A Grassfield app: `QStringList{QStringLiteral("qs")} + shellIpcArgs() + QStringList{QStringLiteral("<target>"),
    # QStringLiteral("<function>"), ...}` or the same with `ipc` held in a variable: the list appended right after the
    # shellIpcArgs() result names the call. A file that does not build on shellIpcArgs() calls nothing.
    for path in sorted(files):
        if path.startswith("apps/") and path.endswith(".cpp") and "shellIpcArgs()" in files[path]:
            callers |= set(re.findall(r'(?:shellIpcArgs\(\)|\bipc)\s*\+\s*QStringList\s*\{\s*QStringLiteral\("(\w+)"\)\s*,\s*QStringLiteral\("(\w+)"\)', files[path]))

    defs = definitions(files)
    fails += defs
    if not defs:
        passes.append("the gates are defined exactly: RunMode.dev/fixtures/REFUSED, Mode.dev/fixtures/refused from RunMode.js, "
                      "VisualFixtures.dev/active = Mode.dev/fixtures; RunMode is only called or read, never aliased or written")

    before = len(fails)
    for key in sorted(code):
        if key not in doc:
            continue
        path, params, body = code[key]
        atext = analysis(files[path])
        dev_exprs, fixture_exprs = gate_exprs(path, files[path], not defs)
        name = "%s.%s (%s)" % (key[0], key[1], path)
        cls = doc[key]
        dev_gated = gated_by(params, body, atext, dev_exprs)
        fixtures_gated = gated_by(params, body, atext, fixture_exprs)
        if cls == "action":
            if key not in callers:
                fails.append(name + ": class action but no binding, gesture, screen corner or app calls it")
            elif dev_gated or fixtures_gated:
                fails.append(name + ": class action but gated")
        elif cls == "dev":
            if not dev_gated:
                fails.append(name + ": class dev but its body checks no exact dev gate")
        elif cls == "fixtures":
            if not fixtures_gated:
                fails.append(name + ": class fixtures but its body checks no exact fixtures gate")
        else:
            fails.append(name + ": unknown class " + repr(cls))
    for key in sorted(callers - set(code)):
        fails.append("a binding or screen corner calls %s.%s, which no IpcHandler has" % key)
    if len(fails) == before:
        passes.append("every action has a real-session caller; every dev and fixtures function checks its exact gate")

    # The security modules: the gate only through the relative RunMode.js import; never qs.lib or Mode; GRASSFIELD_DEV read
    # only on an accepted gate-call line (or the leaked-value warning, which tests the call's own result).
    leaks, on_mode, bad_import = [], [], []
    for path in sorted(p for p in files if is_security(p) and p.endswith((".qml", ".js"))):
        text = files[path]
        if imports_qs_lib(text) or re.search(r"(?<![\w.])Mode\.\w", text):
            on_mode.append(path)
        if (runmode_aliases(text) or re.search(r"(?<![\w.])RunMode\.", text)) and not relative_runmode(path, text):
            bad_import.append(path)
        lines = text.splitlines()
        for n, line in enumerate(lines, 1):
            exempt = (path == LOCK_QML and line.strip() == LEAK_WARNING and n < len(lines) and lines[n].strip() == LEAK_WARNING_NEXT)
            if 'Quickshell.env("GRASSFIELD_DEV")' in line and SEC_CALL_LINE(line) is None and not exempt:
                leaks.append("%s:%d" % (path, n))
    if on_mode:
        fails.append("security modules on the qs.lib module or the Mode singleton (use the relative RunMode.js import): " + ", ".join(on_mode))
    else:
        passes.append("no security module imports qs.lib or reads Mode")
    if bad_import:
        fails.append("security modules whose RunMode is not shell/lib/RunMode.js by a relative path: " + ", ".join(bad_import))
    else:
        passes.append("the security modules import shell/lib/RunMode.js by a relative path")
    if leaks:
        fails.append("security modules read GRASSFIELD_DEV outside an accepted gate-call line: " + ", ".join(leaks))
    else:
        passes.append("security modules read GRASSFIELD_DEV only on a readonly gate property or an if (!<gate call>) line")
    if own_gates:
        fails.append("IPC handlers with their own dev gate (use an exact gate): " + ", ".join(own_gates))
    else:
        passes.append("no IPC handler has a dev gate of its own")
    return passes, fails


def mutate(files, path, old, new):
    copy = dict(files)
    assert copy[path].count(old) >= 1, (path, old)
    copy[path] = copy[path].replace(old, new)
    return copy


def selftest(files):
    base_pass, base_fail = check(files)
    ok = not base_fail
    print(("PASS" if ok else "FAIL") + ": ipc inventory selftest: the tree itself passes" + ("" if ok else ": " + "; ".join(base_fail)))
    sec_look = SEC_CALL.replace('"GRASSFIELD_SESSION"', '"GRASSFIELD_SESION"')
    aa, idle, bt = "shell/security/polkit/AuthAgent.qml", "shell/security/idle/Idle.qml", "shell/services/BarTone.qml"
    on_start = "Scope {\n    Component.onCompleted: "
    warn_line = LEAK_WARNING_NEXT
    idle_status = "            if (!root.devHooks)\n                return RunMode.REFUSED;\n            return JSON"
    cases = [
        ("a security gate with a look-alike variable name", aa, SEC_CALL, sec_look),
        ("a security gate with a look-alike function", LOCK_QML, "devHooks: " + SEC_CALL, "devHooks: " + SEC_CALL.replace("RunMode.dev(", "RunMode.devx(")),
        ("a security gate behind a look-alike alias", idle, "devHooks: " + SEC_CALL, "devHooks: My" + SEC_CALL),
        ("a security module on the Mode singleton", idle, "devHooks: " + SEC_CALL, "devHooks: Mode.dev"),
        ("a security module importing qs.lib", aa, "import qs.services\n", "import qs.services\nimport qs.lib\n"),
        ("a security module on a local RunMode.js", LOCK_QML, 'import "../../lib/RunMode.js" as RunMode', 'import "RunMode.js" as RunMode'),
        ("a non-security gate on a look-alike property", bt, "if (!Mode.dev)", "if (!Mode.devMode)"),
        ("a non-security gate behind a look-alike singleton", "shell/platform/Capabilities.qml", "if (!Mode.dev)", "if (!MyMode.dev)"),
        ("a wrong dev definition in Mode.qml", MODE_QML, MODE_DEV, MODE_DEV.replace('Quickshell.env("GRASSFIELD_SESSION")', 'Quickshell.env("GRASSFIELD_DEV")')),
        ("a dev definition in Mode.qml that ignores the session", MODE_QML, MODE_DEV, 'readonly property bool dev: Quickshell.env("GRASSFIELD_DEV") === "1"'),
        ("Mode.qml on another rule file", MODE_QML, 'import "RunMode.js" as RunMode', 'import "OtherMode.js" as RunMode'),
        ("a wrong rule in RunMode.js", RUNMODE_JS, RULE_DEV, 'function dev(devValue, sessionValue) {\n    return devValue === "1";\n}'),
        ("a wrong fixtures rule in RunMode.js", RUNMODE_JS, RULE_FIXTURES, 'function fixtures(devValue, sessionValue, fixturesValue) {\n    return fixturesValue === "1";\n}'),
        ("VisualFixtures.dev not Mode.dev", FIXTURES_QML, "readonly property bool dev: Mode.dev\n", "readonly property bool dev: Mode.session\n"),
        ("an IPC handler reading GRASSFIELD_DEV itself", bt, "if (!Mode.dev)", 'if (Quickshell.env("GRASSFIELD_DEV") !== "1")'),
        # Review of 360d6fa: substrings, reassigned exports, loose properties, weak guards.
        ("Mode.qml dev followed by || true", MODE_QML, MODE_DEV, MODE_DEV + " || true"),
        ("Mode.qml fixtures followed by || true", MODE_QML, MODE_FIXTURES, MODE_FIXTURES + " || true"),
        ("VisualFixtures.dev followed by || true", FIXTURES_QML, "readonly property bool dev: Mode.dev\n", "readonly property bool dev: Mode.dev || true\n"),
        ("RunMode.js reassigning dev", RUNMODE_JS, RULE_DEV, RULE_DEV + "\ndev = function (devValue, sessionValue) {\n    return true;\n};"),
        ("RunMode.js reassigning REFUSED", RUNMODE_JS, RULE_REFUSED, RULE_REFUSED + '\nREFUSED = "ok";'),
        ("RunMode.js redefining dev through this", RUNMODE_JS, RULE_DEV, RULE_DEV + "\nthis.dev = function () { return true; };"),
        ("a module assigning to a RunMode export", aa, "Scope {\n", on_start + "RunMode.dev = () => true\n"),
        ("a security gate property that is not readonly", idle, "    readonly property bool devHooks: " + SEC_CALL, "    property bool devHooks: " + SEC_CALL),
        ("a decoy gate property in a nested object", "shell/widgets/Widgets.qml", "    readonly property bool devHooks: Mode.dev\n",
         "    readonly property bool devHooks: true\n    QtObject {\n        readonly property bool devHooks: Mode.dev\n    }\n"),
        ("a gate property followed by || true", LOCK_QML, "devHooks: " + SEC_CALL + "\n", "devHooks: " + SEC_CALL + " || true\n"),
        ("a guard weakened by || true", bt, "if (!Mode.dev)", "if (!(Mode.dev || true))"),
        ("a positive guard weakened by || true", bt, "if (!Mode.dev)\n                return Mode.refused;", "if (Mode.dev || true) {}"),
        ("a ternary weakened by || true", LOCK_QML, "return root.devHooks ? root.lockState : RunMode.REFUSED;", "return root.devHooks || true ? root.lockState : RunMode.REFUSED;"),
        ("a GRASSFIELD_DEV read hidden behind !root.devHooks", idle, idle_status,
         '            if (!root.devHooks && Quickshell.env("GRASSFIELD_DEV") !== "1")\n                return RunMode.REFUSED;\n            return JSON'),
        # Re-review of 2b8e13a: writes to RunMode through any expression, RunMode.js rebinding, shadowed gates, the
        # exempt warning line, gate calls outside the accepted lines.
        ("Object.defineProperty on RunMode", aa, "Scope {\n", on_start + 'Object.defineProperty(RunMode, "dev", {value: () => true})\n'),
        ("Object.assign on RunMode", aa, "Scope {\n", on_start + "Object.assign(RunMode, {dev: () => true})\n"),
        ("Object.freeze-style call taking RunMode bare", aa, "Scope {\n", on_start + "Object.setPrototypeOf(RunMode, null)\n"),
        ("an alias of RunMode written through (const R = RunMode; R.dev = ...)", aa, "Scope {\n", on_start + "{ const R = RunMode; R.dev = () => true; }\n"),
        ("a parenthesised RunMode written through", aa, "Scope {\n", on_start + "(RunMode).dev = () => true\n"),
        ("a logical assignment to a RunMode export (&&=)", aa, "Scope {\n", on_start + "RunMode.dev &&= () => true\n"),
        ("a computed write to a RunMode export", aa, "Scope {\n", on_start + 'RunMode["dev"] = () => true\n'),
        ("an assignment to RunMode.REFUSED", aa, "Scope {\n", on_start + 'RunMode.REFUSED = "ok"\n'),
        ("a compound assignment to RunMode.REFUSED", aa, "Scope {\n", on_start + 'RunMode.REFUSED += "ok"\n'),
        ("a multi-line destructuring write to RunMode.REFUSED", aa, "Scope {\n", on_start + '{\n        [\n            RunMode.REFUSED\n        ] = ["ok"];\n    }\n'),
        ("an object destructuring write to RunMode.REFUSED", aa, "Scope {\n", on_start + '({x: RunMode.REFUSED} = {x: "ok"})\n'),
        ("a for-of write to RunMode.REFUSED", aa, "Scope {\n", on_start + 'for (RunMode.REFUSED of ["ok"]) {}\n'),
        ("a write inside a template substitution", aa, "Scope {\n", on_start + 'console.log(`${RunMode.REFUSED = "ok"}`)\n'),
        ("a write hidden after a quote in a regular expression", aa, "Scope {\n", on_start + '{ const r = /"/; RunMode.REFUSED = "ok"; const s = "x"; }\n'),
        ("a write through an escaped identifier", aa, "Scope {\n", on_start + 'Run\\u004Dode.REFUSED = "ok"\n'),
        ("RunMode.js destructuring reassignment of dev", RUNMODE_JS, RULE_DEV, RULE_DEV + "\n[dev] = [function () { return true; }];"),
        ("RunMode.js for-of reassignment of dev", RUNMODE_JS, RULE_DEV, RULE_DEV + "\nfor (dev of [function () { return true; }]);"),
        ("RunMode.js compound assignment to REFUSED", RUNMODE_JS, RULE_REFUSED, RULE_REFUSED + '\nREFUSED ||= "ok";'),
        ("RunMode.js eval of a built assignment", RUNMODE_JS, RULE_DEV, RULE_DEV + '\neval("d" + "ev = function () { return true; }");'),
        ('RunMode.js Object["defineProperty"](this, ...)', RUNMODE_JS, RULE_DEV, RULE_DEV + '\nObject["defineProperty"](this, "dev", {value: function () { return true; }});'),
        ("a module evaluating a string (eval)", "shell/widgets/Widgets.qml", "Singleton {\n", 'Singleton {\n    Component.onCompleted: eval("RunMode" + ".dev = 1")\n'),
        ("a module importing something as Mode", bt, "import qs.lib\n", 'import qs.lib\nimport "Fake.js" as Mode\n'),
        ("a module declaring its own RunMode", "shell/widgets/Widgets.qml", "Singleton {\n", "Singleton {\n    function RunMode() {}\n"),
        ("a local const shadowing Mode before the guard", bt, "if (!Mode.dev)", 'const Mode = {dev: true, refused: ""};\n            if (!Mode.dev)'),
        ("a local const shadowing root in a forwarded body", LOCK_QML, "return root.devHooks ? root.lockState : RunMode.REFUSED;",
         'const root = {devHooks: true, lockState: "x"};\n        return root.devHooks ? root.lockState : RunMode.REFUSED;'),
        ("a local let shadowing a gate property", idle, idle_status, "            let devHooks = true;\n            if (!devHooks)\n                return RunMode.REFUSED;\n            return JSON"),
        ("a destructuring declaration shadowing a gate property", idle, idle_status,
         "            const {devHooks} = {devHooks: true};\n            if (!devHooks)\n                return RunMode.REFUSED;\n            return JSON"),
        ("a parameter shadowing root in a forwarded function", LOCK_QML, "function devStatus(): string {", "function devStatus(root): string {"),
        ("a local const shadowing RunMode before the guard", aa, "            if (!RunMode.dev(",
         '            const RunMode = {dev: () => true, REFUSED: ""};\n            if (!RunMode.dev('),
        ("a guard that only exists in a comment", bt, "if (!Mode.dev)\n                return Mode.refused;", "// if (!Mode.dev)\n                // return Mode.refused;"),
        ("a guard that only exists in a string", bt, "if (!Mode.dev)\n                return Mode.refused;", 'const note = "if (!Mode.dev) return";'),
        ("an effect under the exempt warning line", LOCK_QML, warn_line, "controller.pamSuppressed = true;"),
        ("pamSuppressed set from the gate call || true", LOCK_QML, 'controller.pamSuppressed = root.devHooks && Quickshell.env("GRASSFIELD_DEV_ALLOW_PAM") !== "1";',
         "controller.pamSuppressed = " + SEC_CALL + " || true;"),
        # An app is a caller only through shellIpcArgs() (PR #47, Activity Monitor's `dock reopen`).
        ("an app's call not built on shellIpcArgs()", "apps/activity/src/activityapp.cpp", "grassfield::apps::runmode::shellIpcArgs()",
         'QStringList{QStringLiteral("ipc"), QStringLiteral("call")}'),
        ("an app calling a function no IpcHandler has", "apps/activity/src/activityapp.cpp", 'QStringLiteral("reopen")', 'QStringLiteral("reopenx")'),
    ]
    # Re-review of bf9e280 (B1 and the reviewer's other probes): RunMode.js under another name, in QML and JS, any path
    # spelling; RunMode reached as a member or spread; Quickshell (env() feeds the gate) written or passed bare; the
    # Function constructor reached through .constructor; local copies of the gate files or names. Steps: (path, old, new),
    # old None = a new file.
    bt_sg = "Singleton {\n"
    bt_on = bt_sg + "    Component.onCompleted: "
    rm_import = 'import "../../lib/RunMode.js" as RunMode\n'
    tamper = "RM.dev = () => true\n"
    multi = [
        ("a security module importing RunMode.js again as RM and writing RM.dev",
         [(aa, rm_import, rm_import + 'import "../../lib/RunMode.js" as RM\n'), (aa, "Scope {\n", on_start + tamper)]),
        ("a non-security module importing RunMode.js as RM and writing RM.dev",
         [(bt, "import qs.lib\n", 'import qs.lib\nimport "../lib/RunMode.js" as RM\n'), (bt, bt_sg, bt_on + tamper)]),
        ("a new JS module importing RunMode.js as R and writing R.dev",
         [("shell/lib/Helpers.js", None, '.pragma library\n.import "RunMode.js" as R\n\nfunction init() {\n    R.dev = function () { return true; };\n}\n')]),
        ("RunMode.js imported as RM by ./RunMode.js", [("shell/lib/Helpers.js", None, '.pragma library\n.import "./RunMode.js" as RM\n')]),
        ("RunMode.js imported as RM by a path with ./ inside", [(bt, "import qs.lib\n", 'import qs.lib\nimport "../lib/./RunMode.js" as RM\n')]),
        ("RunMode.js imported as RM by the packaged absolute path", [(bt, "import qs.lib\n", 'import qs.lib\nimport "/usr/share/grassfield/shell/lib/RunMode.js" as RM\n')]),
        ("RunMode.js imported as RM by a file: URL", [(bt, "import qs.lib\n", 'import qs.lib\nimport "file:///usr/share/grassfield/shell/lib/RunMode.js" as RM\n')]),
        ("RunMode.js imported as RM by a percent-encoded path", [(bt, "import qs.lib\n", 'import qs.lib\nimport "../lib/Run%4Dode.js" as RM\n')]),
        ("RunMode.js imported as RM in single quotes", [(bt, "import qs.lib\n", "import qs.lib\nimport '../lib/RunMode.js' as RM\n")]),
        ("a qmldir exposing RunMode.js", [("shell/lib/qmldir", "singleton Mode 1.0 Mode.qml\n", "singleton Mode 1.0 Mode.qml\nRunMode 1.0 RunMode.js\n")]),
        ("RunMode reached as a member (L.RunMode.dev = ...)", [(bt, "import qs.lib\n", "import qs.lib\nimport qs.lib as L\n"), (bt, bt_sg, bt_on + "L.RunMode.dev = () => true\n")]),
        ("a spread of RunMode", [(aa, "Scope {\n", on_start + "{ const c = {...RunMode}; }\n")]),
        ("Quickshell.env overwritten", [("shell/widgets/Widgets.qml", "Singleton {\n", 'Singleton {\n    Component.onCompleted: Quickshell.env = (n) => "1"\n')]),
        ("Object.defineProperty on Quickshell", [("shell/widgets/Widgets.qml", "Singleton {\n",
                                                  'Singleton {\n    Component.onCompleted: Object.defineProperty(Quickshell, "env", {value: (n) => "1"})\n')]),
        ("the Function constructor reached through .constructor", [("shell/widgets/Widgets.qml", "Singleton {\n",
                                                                     'Singleton {\n    Component.onCompleted: [].constructor.constructor("return 1")()\n')]),
        ("QML compiled from a string (Qt.createQmlObject)", [("shell/widgets/Widgets.qml", "Singleton {\n",
                                                             'Singleton {\n    Component.onCompleted: Qt.createQmlObject("import QtQuick; QtObject {}", root)\n')]),
        ("a local Mode.qml beside a module", [("shell/services/Mode.qml", None, "pragma Singleton\nimport QtQuick\nimport Quickshell\n\nSingleton {\n    readonly property bool dev: true\n}\n")]),
        ("a local VisualFixtures.qml in another directory", [("shell/widgets/VisualFixtures.qml", None, "pragma Singleton\nimport QtQuick\nimport Quickshell\n\nSingleton {\n    readonly property bool dev: true\n    readonly property bool active: true\n}\n")]),
        ("a qmldir naming another file Mode", [("shell/services/qmldir", "singleton VisualFixtures 1.0 VisualFixtures.qml\n",
                                                "singleton VisualFixtures 1.0 VisualFixtures.qml\nsingleton Mode 1.0 BarTone.qml\n")]),
        ("an inline component named Mode", [(bt, bt_sg, bt_sg + "    component Mode: QtObject {\n        readonly property bool dev: true\n    }\n")]),
        # Re-review of f03d65a (B1, each proven at run time: RM.dev written turned Lock.devHooks true in a simulated real session):
        # the forms a text match missed; the imports are now read by Qt's parsers.
        ("B1 form 1: a comment before the import on the same line",
         [(bt, "import qs.lib\n", 'import qs.lib\n/* x */ import "../lib/RunMode.js" as RM\n'), (bt, bt_sg, bt_on + tamper)]),
        ("B1 form 2: no space before `as`",
         [(bt, "import qs.lib\n", 'import qs.lib\nimport "../lib/RunMode.js"as RM\n'), (bt, bt_sg, bt_on + tamper)]),
        ("B1 form 3: the qualifier on the next line",
         [(bt, "import qs.lib\n", 'import qs.lib\nimport "../lib/RunMode.js"\n    as RM\n'), (bt, bt_sg, bt_on + tamper)]),
        ("B1 form 4: a unicode escape (\\u002e) in the import path",
         [(bt, "import qs.lib\n", 'import qs.lib\nimport "../lib/RunMode\\u002ejs" as RM\n'), (bt, bt_sg, bt_on + tamper)]),
        ("B1 form 5: a hex escape (\\x4D) in the import path",
         [(bt, "import qs.lib\n", 'import qs.lib\nimport "../lib/Run\\x4Dode.js" as RM\n'), (bt, bt_sg, bt_on + tamper)]),
        ("B1 form 6: a qmldir JS resource with a percent-encoded name",
         [("shell/widgets/qmldir", None, "module qs.widgets\nRM 1.0 ../lib/Run%4Dode.js\n")]),
        ("a .js module importing RunMode.js as RunMode and re-exporting it",
         [("shell/lib/Helpers.js", None, '.pragma library\n.import "RunMode.js" as RunMode\n\nvar M = RunMode;\n')]),
        ("a shell file importing a JS file outside shell/ (not linted) that writes RunMode",
         [(bt, "import qs.lib\n", 'import qs.lib\nimport "../../ui/Grassfield/Ui/Evil.js" as Evil\n'), (bt, bt_sg, bt_on + "Evil.hit()\n"),
          ("ui/Grassfield/Ui/Evil.js", None, '.pragma library\n.import "/usr/share/grassfield/shell/lib/RunMode.js" as RM\nfunction hit() { RM.dev = function () { return true; }; }\n')]),
        # Re-review of e45bdf3: a hidden file (glob skipped it), loaded by name; at run time it turned Lock.devHooks true.
        ("a hidden QML file shell/widgets/.Evil.qml loaded by a Loader",
         [("shell/widgets/.Evil.qml", None, 'import QtQuick\nimport "../lib/RunMode.js" as RM\n\nItem {\n    Component.onCompleted: RM.dev = function () { return true; }\n}\n'),
          ("shell/widgets/Widgets.qml", "Singleton {\n", 'Singleton {\n    property Loader probeLoader: Loader {\n        source: ".Evil.qml"\n    }\n')]),
        ("a QML file in a hidden directory shell/widgets/.x/",
         [("shell/widgets/.x/Evil.qml", None, "import QtQuick\nItem {}\n")]),
        ("a hidden file under ui/", [("ui/Grassfield/Ui/.Evil.qml", None, "import QtQuick\nItem {}\n")]),
        ("a .js module importing RunMode.js after code (a directive the scanner skips)",
         [("shell/lib/Helpers.js", None, '.pragma library\nvar x = 1;\n.import "RunMode.js" as RM\n')]),
    ]
    for label, steps in [(c[0], [c[1:]]) for c in cases] + multi:
        m = files
        for path, old, new in steps:
            if old is None:
                m = dict(m)
                m[path] = new
            else:
                m = mutate(m, path, old, new)
        _, fails = check(m)
        caught = bool(fails)
        ok = ok and caught
        print(("PASS" if caught else "FAIL") + ": ipc inventory selftest: %s is caught%s" % (label, (" (" + fails[0][:140] + ")") if caught else ""))
    return ok


files = load()
BASE_KEY[0] = tree_key(files)
if sys.argv[1:] == ["--selftest"]:
    sys.exit(0 if selftest(files) else 1)
passes, fails = check(files)
for p in passes:
    print("PASS: ipc inventory " + p)
for f in fails:
    print("FAIL: ipc inventory " + f)
sys.exit(0 if selftest(files) and not fails else 1)
PY
