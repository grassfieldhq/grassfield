#!/usr/bin/env python3
"""Shell layering (ADR-0021, GF-087): the import graph of shell/ obeys the layers, stays acyclic, and keeps raw Hyprland events in platform.

  python3 -I tests/ci/import_graph.py             check the tree, exit 1 on any violation
  python3 -I tests/ci/import_graph.py --graph     print the modules, their layer, the edges and the strongly connected components
  python3 -I tests/ci/import_graph.py --selftest  the rules on fixed synthetic trees

Layers, low to high: lib < platform < store < services < features < shell.qml. A module may import only a lower layer; two
feature modules may import each other only while no cycle forms (a feature edge inside a strongly connected component of the
feature graph is a violation). Security modules (shell/security/**) may import only lib, services and other security
modules. `Quickshell.Hyprland` and `rawEvent` belong to platform. `qs.security.secret` (the secret sheets, ADR-0035 D-9) is imported
by shell/security/host/SheetHost.qml alone, which wires it to the one queue it shares with the polkit sheet in the security
process (ADR-0041 S3; shell/shell.qml before): no marker excuses another importer (the integrator's review of PR #95).

Rule choices: a feature-to-feature edge is a violation only when it lies on a cycle of the feature graph once every layer
violation is removed from that graph. A raw-event violation is reported once per file, on its `import Quickshell.Hyprland`
line (else on its first `rawEvent` or `onRawEvent` name).

No hand parsing of QML or JavaScript. Imports come from Qt's own parser: `qmlimportscanner` (qt6-declarative) reads every
file, one process per file, a few at a time and at the lowest priority; `qmldom --dump-ast` (same package) gives the lines of
the imports and the identifiers named `rawEvent` or `onRawEvent` in the files that need them (a file with a violation, a
Hyprland import or a text that could name rawEvent: a sound prefilter, since identifiers are spelled as named except for
unicode escapes). A comment or a string is therefore never a use. Both tools are run with QT_QPA_PLATFORM=offscreen.
- A file the scanner reports syntax errors on (it prints them on stderr and drops the imports) is a failure.
- The scanner's JS reader skips a `.import` after code or after a split `.pragma`: a `.import X` in the text that the scanner
  does not report is a failure too (a false positive on a comment that spells one, never a miss).
- qmldom does not escape quotes in its dump, so its tag lines are read one by one, not as XML.
- A quoted import must be a plain relative path that resolves (percent escapes decoded) to an existing file or directory inside
  shell/; `root:/...`, `file:///...`, absolute and missing paths are refused. The qmldir files are read too: only `module` lines
  and type entries naming an existing plain file of the same directory pass (no import, depends, plugin or outside path).
  `.mjs`, `Qt.include` and a bare `import qs` are refused (none is used), and so is any hidden path under shell/ (a name
  that starts with a dot, qmlls's `.qmlls.ini` excepted): QML loads one by name and a glob skips it (re-review of e45bdf3). A raw event name counts as an identifier, a destructured
  property name or a string literal in QML, and anywhere in the text of a .js file (qmldom gives .js no tree). Names built at run
  time are out of reach.
- A canary runs first: both tools must exist and read a tiny file as relied on, so a missing tool or a changed dump fails loudly.
Needs qt6-declarative's /usr/lib/qt6/qmlimportscanner and /usr/lib/qt6/bin/qmldom (the PKGBUILD makedepends it).

A module is a directory with a qmldir (`qs.overlay.controlcenter` is shell/overlay/controlcenter); a directory without one
belongs to its nearest ancestor module; shell/shell.qml and the other files of shell/ itself are the composition root.
An import is `import qs.<module>` or a relative `import "<dir or file>"` (also `.import` in JS), as the scanner reports it.

Ratchet: a violating import line passes only with a trailing `// layering-exception: <tag>` marker on that line. Tags:
`GF-087` (temporary: the slice that removes the violation removes the marker; L9 refuses any), `GF-050` (temporary, accepted
only on the `import qs.notifications` line of shell/security/idle/SleepInhibitor.qml), `ADR-0021 security` (permanent,
accepted only in shell/security/lock and shell/security/idle, only on a raw Hyprland event line: the lock and idle modules).
An unknown tag, a tag where it is not accepted, and a marker on a line that is not a violation are failures, so no marker
outlives its violation. A marker covers exactly one import: a violating line that holds another import is a failure.

Limit: a test tree whose module is made of file links plus a `qmldir` link (no directory link, like tests/security/lock_surfaces/launchpad)
is not covered by the test-tree `lib` check; only a link to a module directory is.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

LAYER = {"lib": 0, "platform": 1, "store": 2, "services": 3}
FEATURE = 4
ROOT_LAYER = 5
JS_IMPORT = re.compile(r"""\.\s*import\s+(?:"([^"]*)"|'([^']*)'|([A-Za-z_][\w.]*))""")
TAGS = ("GF-087", "GF-050", "ADR-0021 security")
MARKER = re.compile(r"//\s*layering-exception:\s*(.*?)\s*$")
SECURITY_ALLOWED = {"lib", "services"}
SECRET_MODULE = "security.secret"
SECRET_REASON = "qs.security.secret is imported by shell/security/host/SheetHost.qml only"
# Its one importer (ADR-0041 S3: the sheets run in the security process; shell/shell.qml before).
SECRET_IMPORTER = "security/host/SheetHost.qml"
PERMANENT_DIRS = ("security/lock/", "security/idle/")  # the only places the permanent tag is accepted (not polkit)
GF050_FILE = "security/idle/SleepInhibitor.qml"
GF050_TARGET = "notifications"


MULTI = "multi-import line"
GAP = r"(?:\s|/\*.*?\*/|//[^\n]*(?:\n|$))*"  # whitespace and comments
QT_INCLUDE = re.compile(r"\bQt" + GAP + r"(?:\." + GAP + r"include\b|\[" + GAP + r"[\"']include[\"']" + GAP + r"\])", re.S)
QMLDIR_ENTRY = re.compile(r"^(?:internal\s+[A-Z]\w*\s+|(?:singleton\s+)?[A-Z]\w*\s+\d+(?:\.\d+)?\s+)([A-Za-z0-9_]+\.(?:qml|js))$")
QMLDIR_MODULE = re.compile(r"^module\s+[A-Za-z_][\w.]*$")
IMPORT_SCANNER = "/usr/lib/qt6/qmlimportscanner"
QMLDOM = "/usr/lib/qt6/bin/qmldom"
QT_QML = "/usr/lib/qt6/qml"
# A sound prefilter for the raw event rule: an identifier is spelled in the file as it is named, and a string can spell a name only
# with a backslash (\u, \x, octal, a line continuation), so a file with neither is never read from its tree.
RAW_PREFILTER = re.compile(r"rawevent|\\", re.I)
RAW_TEXT = re.compile(r"rawevent|hyprland", re.I)
RAW_JS = re.compile(r"[rR]awEvent")
RAW_NAMES = {"rawEvent", "onRawEvent"}
HYPRLAND = "Quickshell.Hyprland"


QT_EOL = re.compile("\r\n|[\n\r\u2028\u2029]")  # the line terminators of QML and JS: not \f, \v or \x85, which str.splitlines also splits at


def file_lines(path):
    """The lines of a file counted the way Qt counts them, so that its line numbers index this list."""
    return QT_EOL.split(path.read_text(encoding="utf-8", errors="replace"))


class QtToolError(Exception):
    pass


def qt_run(cmd):
    """One of Qt's own tools, headless and at the lowest priority (a stray banner or window must never appear)."""
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen")
    env.pop("DISPLAY", None)
    env.pop("WAYLAND_DISPLAY", None)
    try:
        return subprocess.run(["nice", "-n", "19", *cmd], capture_output=True, text=True, env=env, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise QtToolError(f"{cmd[0]}: {e}")


_IMPORTS = {}


def scanner_imports(path):
    """The imports of one .qml/.js file as Qt's own parser reads them (qmlimportscanner): [(type, name)] with type module,
    directory or javascript, `name` as written. Cached by file content (the same content imports the same things anywhere)."""
    key = (path.suffix, hashlib.sha1(path.read_bytes()).hexdigest())
    if key not in _IMPORTS:
        r = qt_run([IMPORT_SCANNER, "-qmlFiles", str(path), "-importPath", QT_QML])
        if r.returncode != 0 or r.stderr.strip():
            # Syntax errors come on stderr with exit 0 and the file's imports are silently dropped: never trust such a file.
            raise QtToolError(f"{path.name} does not parse (qmlimportscanner: {(r.stderr or r.stdout).strip()[:160]})")
        try:
            entries = json.loads(r.stdout)
        except ValueError as e:
            raise QtToolError(f"qmlimportscanner gave no JSON for {path.name}: {e}")
        _IMPORTS[key] = [(e.get("type"), e.get("name") or e.get("path")) for e in entries]
    return _IMPORTS[key]


def prefetch_imports(paths):
    """Fills the scanner cache with a few processes at a time; errors are raised again, per file, by scanner_imports."""
    def one(p):
        try:
            scanner_imports(p)
        except QtToolError:
            pass
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(one, paths))


_ASTS = {}
AST_IMPORT = re.compile(r'<UiImport\b[^>]*?\bfileName="([^"]*)"[^>]*?\bimportToken="[^"]*?\bl:(\d+)[^"]*"(?:[^>]*?\bsemicolonToken="[^"]*?\bl:(\d+))?')
AST_QID = re.compile(r'<UiQualifiedId\b[^>]*?\bname="([^"]*)"')
AST_NAME = re.compile(r'\b(?:name|id|value)="(?:on)?[rR]awEvent"')  # identifiers, destructured property names (id=), string literals (value=)
AST_LINE = re.compile(r"\bl:(\d+)")


def ast_of(path):
    """The syntax tree of a .qml file from Qt's own code model (qmldom --dump-ast), reduced to what the rules need:
    {"imports": [(key, first line, last line)], "raw": [lines naming rawEvent or onRawEvent]}, or None when it does not parse.
    `key` is the module name (`qs.dock`, joined from the qualified-id nodes, whatever the spacing or comments) or the quoted path.
    The dump is not well-formed XML (string literal values hold raw quotes), so its tag lines are read one by one; a string
    literal can only add a false name, never hide a node."""
    key = hashlib.sha1(path.read_bytes()).hexdigest()
    if key not in _ASTS:
        r = qt_run([QMLDOM, "--dump-ast", str(path)])
        result = None
        if r.returncode == 0 and "<UiProgram>" in r.stdout:
            imports, raw, current = [], [], None
            for line in r.stdout.split("\n"):
                m = AST_IMPORT.search(line) if "<UiImport" in line else None
                if m:
                    first = int(m.group(2))
                    current = [m.group(1), first, max(first, int(m.group(3))) if m.group(3) else first, []]
                    continue
                if current is not None:
                    q = AST_QID.search(line)
                    if q:
                        current[3].append(q.group(1))
                    elif "</UiImport>" in line:
                        imports.append((current[0] or ".".join(current[3]), current[1], current[2]))
                        current = None
                    continue
                if "awEvent" in line and AST_NAME.search(line):
                    t = AST_LINE.search(line)
                    raw.append(int(t.group(1)) if t else 0)
            result = {"imports": imports, "raw": sorted(raw)}
        _ASTS[key] = result
    return _ASTS[key]


def prefetch_asts(paths):
    """Runs qmldom on several files at a time (the results are cached by content)."""
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(ast_of, paths))


def listing(root, sub):
    """The files (and symlinks) under root/sub: what the checkout tracks when root is its top level (an untracked scratch
    file or build tree is not the source; same rule as scripts/dev/upstream-drift.sh), every plain file otherwise (an
    export without .git, a fixture tree inside another checkout)."""
    top = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if top.returncode == 0 and Path(top.stdout.strip()).resolve() == Path(root).resolve():
        names = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--", sub], check=True, capture_output=True, text=True).stdout
        return sorted(p for p in (Path(root) / n for n in names.split("\0") if n) if os.path.lexists(p))
    out = []
    for dirpath, dirnames, filenames in os.walk(Path(root) / sub):
        dirnames[:] = [d for d in dirnames if d not in (".git", ".dev")]
        out += [Path(dirpath) / n for n in filenames]
        out += [Path(dirpath) / d for d in dirnames if (Path(dirpath) / d).is_symlink()]
    return sorted(out)


def shell_sources(shell):
    return [p for p in listing(shell.parent, shell.name) if p.suffix in (".qml", ".js")]


def layer_of(module):
    if module == "shell":
        return ROOT_LAYER
    return LAYER.get(module, FEATURE)


def is_security(module):
    return module == "security" or module.startswith("security.")


def modules_of(shell):
    """Directory (relative, '' for shell/ itself) of every module: a directory holding a qmldir."""
    return {str(p.parent.relative_to(shell)) if p.parent != shell else "" for p in listing(shell.parent, shell.name) if p.name == "qmldir"}


def module_of_path(shell, mods, path):
    """Module name of a path inside shell/ (nearest ancestor with a qmldir; the root files are 'shell'); None outside."""
    try:
        rel = path.resolve().relative_to(shell.resolve())
    except ValueError:
        return None
    d = rel if path.is_dir() else rel.parent
    while True:
        key = "" if str(d) == "." else str(d)
        if key and key in mods:
            return key.replace("/", ".")
        if not key:
            return "shell"
        d = d.parent


def qmldir_failures(shell):
    """The qmldir files are read too, because the engine follows them: a qmldir `import qs.dock` or `import Quickshell.Hyprland`,
    a `depends`, a plugin, or a type entry that points outside its directory loads and would pass unseen. Only `module <uri>` and
    type entries (`[singleton] Name 1.0 File.qml|js`, `internal Name File.qml|js`) naming a plain file of the same directory that
    exists are accepted; any other line is refused (none of the others is used)."""
    out = []
    for q in listing(shell.parent, shell.name):
        if q.name != "qmldir":
            continue
        for n, raw in enumerate(file_lines(q), 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            m = QMLDIR_ENTRY.match(line)
            if QMLDIR_MODULE.match(line):
                continue
            if m is None:
                out.append((q, f"{q.parent.name}/qmldir:{n}: `{line}` is not a plain `module` line or a type entry naming a file of this directory"))
            elif not (q.parent / m.group(1)).is_file():
                out.append((q, f"{q.parent.name}/qmldir:{n}: `{line}` names a file that does not exist in this directory"))
    return out


def shape_failures(shell):
    """What the reader cannot follow and the tree does not use is refused: `.mjs` modules and `Qt.include` (a script pulled in
    by name at run time), anywhere in shell/ (the text is searched whole, a comment included: a false positive, never a miss);
    and any hidden path (a file or directory whose name starts with a dot, qmlls's own `.qmlls.ini` excepted): QML loads one by
    name (`Loader { source: ".Evil.qml" }`), a glob skips it, and none is part of the tree (re-review of e45bdf3)."""
    out = []
    for p in listing(shell.parent, shell.name):
        rel = p.relative_to(shell.parent)
        if any(part.startswith(".") for part in rel.parts[:-1]) or (rel.name.startswith(".") and rel.name != ".qmlls.ini"):
            out.append((p, f"{rel}: a hidden path under shell/ is refused (QML loads it by name; none is part of the tree)"))
        elif p.suffix == ".mjs":
            out.append((p, f"{p.name}: .mjs modules are not read by this check and are not used; refused"))
        elif p.suffix in (".qml", ".js") and QT_INCLUDE.search(p.read_text(encoding="utf-8", errors="replace")):
            out.append((p, f"{p.name}: Qt.include pulls in a script this check cannot follow; refused"))
    return out


def scan(shell):
    """Every import of every .qml/.js file of shell/ from Qt's import scanner: ([(file, source module, kind, target, key)], failures).
    kind is module or unknown (an `import qs.<name>` without a qmldir); a directory or file import is resolved against the
    file and counted when it lands in shell/. `key` is how the import is written, to find its lines in the syntax tree."""
    mods = modules_of(shell)
    files = shell_sources(shell)
    prefetch_imports(files)
    out, failures = [], list(qmldir_failures(shell)) + shape_failures(shell)
    for path in files:
        src = module_of_path(shell, mods, path)
        try:
            entries = scanner_imports(path)
        except QtToolError as e:
            failures.append((path, str(e)))
            continue
        if path.suffix == ".js":
            # The scanner's JS reader skips a directive that comes after code or after a split `.pragma`: whatever the text imports
            # that it does not report is a failure (a false positive on a mention in a comment, never a miss).
            seen = {name for _, name in entries}
            for m in JS_IMPORT.finditer(path.read_text(encoding="utf-8", errors="replace")):
                arg = next(g for g in m.groups() if g is not None)
                if arg not in seen:
                    failures.append((path, f"{path.name} has `.import {arg}` that Qt's import scanner does not report (a directive after code or a split pragma?)"))
        for kind, name in entries:
            if kind == "module" and name == "qs":
                failures.append((path, f"{path.name}: a bare `import qs` is refused (name a module: `import qs.<module>`)"))
            elif kind == "module" and name.startswith("qs."):
                module = name[3:]
                out.append((path, src, "module" if module.replace(".", "/") in mods else "unknown", module if module.replace(".", "/") in mods else name, name))
            elif kind in ("directory", "javascript"):
                # A quoted import is a plain relative path that resolves inside shell/: anything else (a URL scheme such as
                # `root:/` or `file:///`, an absolute path, a path that does not exist or leaves the tree) is refused, never
                # skipped. Percent escapes are decoded before resolving, as the engine does (`../%64ock/Helper.js` is dock).
                decoded = urllib.parse.unquote(name)
                if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", decoded) or decoded.startswith("/") or "\\" in decoded:
                    failures.append((path, f"{path.name}: unresolvable import \"{name}\" (not a plain relative path)"))
                    continue
                tgt = Path(os.path.normpath(path.parent / decoded))
                dst = module_of_path(shell, mods, tgt) if tgt.exists() else None
                if dst is None:
                    failures.append((path, f"{path.name}: unresolvable import \"{name}\" (no such file or directory inside shell/)"))
                    continue
                out.append((path, src, "module", dst, name))
    return out, failures


def tarjan(nodes, edges):
    """Strongly connected components with more than one node (self edges are not imports between modules)."""
    index, low, on, stack, comps = {}, {}, set(), [], []
    counter = [0]

    def visit(v):
        index[v] = low[v] = counter[0]
        counter[0] += 1
        stack.append(v)
        on.add(v)
        for w in sorted(edges.get(v, ())):
            if w not in index:
                visit(w)
                low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                on.discard(w)
                comp.append(w)
                if w == v:
                    break
            if len(comp) > 1:
                comps.append(sorted(comp))

    sys.setrecursionlimit(10000)
    for v in sorted(nodes):
        if v not in index:
            visit(v)
    return sorted(comps)


def lines_for(path, key):
    """The (first line, last line) of every import of `key` in a file: from the syntax tree for a .qml file; for a .js file
    (the code model has no tree for it) or one that does not parse, the lines that say `import` and name the target, or (0, 0)."""
    if path.suffix == ".qml":
        tree = ast_of(path)
        if tree is not None:
            return [(a, b) for k, a, b in tree["imports"] if k == key] or [(0, 0)]
    base = os.path.basename(key.rstrip("/")) if ("/" in key or key.endswith(".js")) else key.split(".")[-1]
    lines = file_lines(path)
    hits = [(n, n) for n, line in enumerate(lines, 1) if "import" in line and base in line]
    return hits or [(0, 0)]


def imports_overlapping(path, a, b):
    """How many imports share lines a..b: a marker covers exactly one."""
    if path.suffix == ".qml":
        tree = ast_of(path)
        if tree is not None:
            return sum(1 for _, x, y in tree["imports"] if x <= b and y >= a)
    lines = file_lines(path)
    return max(1, sum(lines[n - 1].count("import") for n in range(max(a, 1), b + 1)))


def needs_tree(path):
    """Whether raw_event_line must read the syntax tree of a .qml file: it imports Quickshell.Hyprland (Qt's import scanner says
    so) or its text holds a name that could be rawEvent (a sound prefilter: identifiers are spelled as named and strings need a backslash to spell another name)."""
    if path.suffix != ".qml":
        return False
    try:
        if ("module", HYPRLAND) in scanner_imports(path):
            return True
    except QtToolError:
        return True
    return bool(RAW_PREFILTER.search(path.read_text(encoding="utf-8", errors="replace")))


def raw_event_line(path):
    """The line to report for raw Hyprland events in a file: its `Quickshell.Hyprland` import, else its first rawEvent or
    onRawEvent name; None when there is none. A .qml file is read from the syntax tree: identifiers, destructured property names
    (`const {rawEvent: e} = o`) and string literals (`o["rawEvent"]`) count, a comment does not. A .js file has no tree (qmldom
    gives it none), so Qt's import scanner says whether it imports the module and the name anywhere in its text counts, a
    comment included (a false positive, never a miss). Names built at run time (`"raw" + "Event"`) are out of reach."""
    if path.suffix == ".js":
        if ("module", HYPRLAND) in scanner_imports(path):
            return lines_for(path, HYPRLAND)[0][0]
        return next((n for n, line in enumerate(file_lines(path), 1) if RAW_JS.search(line)), None)
    if not needs_tree(path):
        return None
    tree = ast_of(path)
    if tree is not None:
        for k, a, _ in tree["imports"]:
            if k == HYPRLAND:
                return a
        return tree["raw"][0] if tree["raw"] else None
    return next((n for n, line in enumerate(file_lines(path), 1) if RAW_TEXT.search(line)), None)  # the tree failure is reported by analyze


def analyze(shell):
    """Returns (violations, graph): violations are (file, line number, reason, marker tag or None); graph is (nodes, edges)."""
    imports, failures = scan(shell)
    nodes, edges = set(), {}
    for _, src, kind, tgt, _ in imports:
        nodes.add(src)
        if kind == "module" and tgt != src:
            nodes.add(tgt)
            edges.setdefault(src, set()).add(tgt)

    def upward(src, tgt):
        if is_security(src) and not is_security(tgt):
            return tgt not in SECURITY_ALLOWED
        a, b = layer_of(src), layer_of(tgt)
        return b >= a and not (a == b == FEATURE)

    # Feature edges that lie on a cycle of the feature graph with every layer violation removed.
    kept = {s: {t for t in ts if not upward(s, t)} for s, ts in edges.items()}
    in_cycle = {frozenset((s, t)) for comp in tarjan(nodes, kept) for s in comp for t in kept.get(s, ()) if t in comp}

    found = []  # (path, reason, key of the import or None, line when the key is None)
    for path, src, kind, tgt, key in imports:
        if kind == "unknown":
            found.append((path, f"{tgt} is not a module of shell/ (no qmldir)", key, None))
        elif kind == "module" and tgt != src:
            if tgt == SECRET_MODULE and path.resolve() != (shell / SECRET_IMPORTER).resolve():
                found.append((path, f"{SECRET_REASON} (it wires the secret sheets to the one queue they share with the polkit sheet, in the security process); "
                                    f"{src} imports it", key, None))
            elif upward(src, tgt):
                why = (f"a security module may import only lib, services and security (imports {tgt})" if is_security(src) and not is_security(tgt)
                       else f"{src} (layer {layer_of(src)}) imports {tgt} (layer {layer_of(tgt)}): imports go to a lower layer only")
                found.append((path, why, key, None))
            elif frozenset((src, tgt)) in in_cycle:
                found.append((path, f"{src} and {tgt} import each other through a cycle of feature modules", key, None))
    for path, message in failures:
        found.append((path, message, None, 0))
    mods = modules_of(shell)
    need_tree = sorted({p for p, _, k, _ in found if k is not None and p.suffix == ".qml"}
                       | {p for p in shell_sources(shell) if module_of_path(shell, mods, p) != "platform" and needs_tree(p)})
    prefetch_asts(need_tree)
    for p in need_tree:
        if ast_of(p) is None:
            found.append((p, f"{p.name}: qmldom could not read the file although the scanner did (did its dump change?)", None, 0))
    for path in shell_sources(shell):
        if module_of_path(shell, mods, path) == "platform":
            continue
        n = raw_event_line(path)
        if n is not None:
            found.append((path, f"{HYPRLAND} or rawEvent outside platform: raw Hyprland events go through qs.platform", None, n))

    violations, covered = [], {}
    for path, reason, key, fixed in sorted(found, key=lambda f: (str(f[0]), f[1])):
        spans = lines_for(path, key) if key is not None else [(fixed, fixed)]
        for a, b in spans:
            marker_line, tag = a, None
            for n in range(a, b + 1):
                m = MARKER.search(file_lines(path)[n - 1]) if n > 0 else None
                if m:
                    marker_line, tag = n, m.group(1)
                    break
            r = reason
            if tag is not None and imports_overlapping(path, a, b) > 1:
                r, tag = f"{reason}; a marker covers exactly one import and these lines hold several", MULTI
            violations.append((path, marker_line, r, tag))
            covered.setdefault(path, set()).update(range(a, b + 1))
    # Markers on lines that are not violations (stale), over every file.
    for path in shell_sources(shell):
        text = path.read_text(encoding="utf-8", errors="replace")
        if "layering-exception" not in text:
            continue
        for n, line in enumerate(QT_EOL.split(text), 1):
            m = MARKER.search(line)
            if m and n not in covered.get(path, ()):
                violations.append((path, n, "stale marker: this line is not a layering violation", m.group(1)))
    return violations, (nodes, edges)


def problems(shell, root=None):
    root = root or shell.parent
    out = []
    violations, _ = analyze(shell)
    for path, n, reason, tag in violations:
        where = f"{path.relative_to(root)}:{n}"
        rel = path.relative_to(shell).as_posix()
        stale = reason.startswith("stale marker")
        if reason.startswith(SECRET_REASON):
            out.append(f"{where}: {reason}; no layering-exception marker covers it")
        elif tag is None:
            out.append(f"{where}: {reason}; fix the import or mark the line `// layering-exception: GF-087`")
        elif tag == MULTI:
            out.append(f"{where}: {reason}; put each import on its own line")
        elif tag not in TAGS:
            out.append(f"{where}: unknown layering-exception tag {tag!r} (known: {', '.join(TAGS)})")
        elif stale:
            out.append(f"{where}: {reason} (remove the `layering-exception: {tag}` marker)")
        elif tag == "ADR-0021 security" and not rel.startswith(PERMANENT_DIRS):
            out.append(f"{where}: the permanent `ADR-0021 security` marker is for shell/security/lock and shell/security/idle only")
        elif tag == "ADR-0021 security" and "Quickshell.Hyprland" not in reason and "rawEvent" not in reason:
            out.append(f"{where}: the permanent `ADR-0021 security` marker covers raw Hyprland events only ({reason})")
        elif tag == "GF-050" and not (rel == GF050_FILE and f"(imports {GF050_TARGET})" in reason):
            out.append(f"{where}: the `GF-050` marker is for the `import qs.notifications` line of shell/{GF050_FILE} only")
    return out


def tree_problems(root):
    """A test tree that links shell module directories (qs.<module> resolves through them) must link shell/lib too:
    every module may import qs.lib, and a tree without the link fails at load time (main 31bce38: lock_surfaces)."""
    shell = (root / "shell").resolve()
    lib = shell / "lib"
    out = []
    by_dir = {}
    for p in listing(root, "tests"):
        if p.is_symlink():
            by_dir.setdefault(p.parent, []).append(p)
    for here, links in sorted(by_dir.items()):
        targets = {}
        for link in links:
            real = link.resolve()
            if real.is_dir() and real != lib and (real / "qmldir").exists():
                try:
                    real.relative_to(shell)
                except ValueError:
                    continue
                targets[link.name] = real
        if targets and not any(p.name == "lib" and p.resolve() == lib for p in links):
            out.append(f"{here.relative_to(root)}: links the shell module(s) {', '.join(sorted(targets))} but has no `lib` link to shell/lib "
                       f"(add `lib -> {os.path.relpath(lib, here)}`)")
    return out


def describe(shell):
    violations, (nodes, edges) = analyze(shell)
    lines = ["modules (layer):"]
    for m in sorted(nodes, key=lambda x: (layer_of(x), x)):
        lines.append(f"  {m} ({layer_of(m)})")
    lines.append("edges:")
    for s in sorted(edges):
        lines.append(f"  {s} -> {', '.join(sorted(edges[s]))}")
    comps = tarjan(nodes, edges)
    lines.append("strongly connected components (all imports): " + (("; ".join(", ".join(c) for c in comps)) or "none"))
    counts = {}
    for path, _, _, tag in violations:
        counts[(str(path.relative_to(shell)), tag)] = counts.get((str(path.relative_to(shell)), tag), 0) + 1
    lines.append(f"violations: {len(violations)}")
    for (f, tag), c in sorted(counts.items()):
        lines.append(f"  {f}: {c} ({tag or 'UNMARKED'})")
    for path, n, reason, tag in violations:
        lines.append(f"  {path.relative_to(shell)}:{n}: {reason} [{tag or 'UNMARKED'}]")
    return "\n".join(lines)


# --- selftest ---------------------------------------------------------------------------------------------------------

def build(tmp, files):
    shell = tmp / "shell"
    for rel, text in files.items():
        p = shell / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    return shell


def modules(*names):
    return {f"{n.replace('.', '/')}/qmldir": f"module qs.{n}\n" for n in names}


def selftest():
    failures = []
    base_mods = modules("lib", "platform", "store", "services", "dock", "desktop", "search", "launchpad", "notifications", "security", "security.lock", "security.idle", "security.polkit")

    def run(name, files, expect):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            shell = build(tmp, {**base_mods, **files})
            got = problems(shell, tmp)
            ok = (not got) if expect is None else any(expect in g for g in got)
            if not ok:
                failures.append(f"{name}: expected {'no problem' if expect is None else repr(expect)}, got {got}")

    clean = {
        "services/Apps.qml": "import qs.platform\nimport qs.store\nimport qs.lib\nItem {}\n",
        "dock/Dock.qml": "import qs.services\nimport qs.platform\nimport \"DockModel.js\" as M\nItem {}\n",
        "dock/DockModel.js": ".pragma library\n",
        "platform/Compositor.qml": "import Quickshell.Hyprland\nimport qs.lib\nItem { function onRawEvent() {} }\n",
        "lib/Mode.qml": "Item {}\n",
        "shell.qml": "import qs.dock\nimport qs.services\nShellRoot {}\n",
    }
    run("clean tree", clean, None)
    run("new unmarked upward import fails (qs)", {**clean, "services/Apps.qml": "import qs.dock\nItem {}\n"}, "imports go to a lower layer only")
    run("the same line marked passes", {**clean, "services/Apps.qml": "import qs.dock // layering-exception: GF-087\nItem {}\n"}, None)
    run("new unmarked upward import fails (relative file)", {**clean, "services/Apps.qml": 'import "../dock/DockModel.js" as M\nItem {}\n'}, "imports go to a lower layer only")
    run("relative file marked passes", {**clean, "services/Apps.qml": 'import "../dock/DockModel.js" as M // layering-exception: GF-087\nItem {}\n'}, None)
    run("relative directory import counts", {**clean, "platform/Compositor.qml": 'import "../services"\nItem {}\n'}, "imports go to a lower layer only")
    run("JS .import counts", {**clean, "platform/X.js": '.import "../services/Y.js" as Y\n', "services/Y.js": ".pragma library\n"}, "imports go to a lower layer only")
    run("lib imports no module", {**clean, "lib/Mode.qml": "import qs.platform\nItem {}\n"}, "imports go to a lower layer only")
    run("platform imports lib only", {**clean, "platform/Compositor.qml": "import Quickshell.Hyprland\nimport qs.store\nItem {}\n"}, "imports go to a lower layer only")
    run("a commented import is not an import", {**clean, "services/Apps.qml": "// import qs.dock\nItem {}\n"}, None)
    run("a hidden file is refused", {**clean, "dock/.Evil.qml": "Item {}\n"}, "a hidden path under shell/")
    run("a file in a hidden directory is refused", {**clean, "dock/.x/Evil.qml": "Item {}\n"}, "a hidden path under shell/")
    run("a tag naming nothing known fails", {**clean, "services/Apps.qml": "import qs.dock // layering-exception: because\nItem {}\n"}, "unknown layering-exception tag")
    run("a stale marker fails", {**clean, "services/Apps.qml": "import qs.platform // layering-exception: GF-087\nItem {}\n"}, "stale marker")
    run("an unknown module fails", {**clean, "services/Apps.qml": "import qs.nothing\nItem {}\n"}, "is not a module")
    run("a second import on the same line counts", {**clean, "services/Apps.qml": "import QtQuick; import qs.dock\nItem {}\n"}, "imports go to a lower layer only")
    run("a marker covers exactly one import (another import on the line)",
        {**clean, "services/Apps.qml": "import QtQuick; import qs.dock // layering-exception: GF-087\nItem {}\n"}, "a marker covers exactly one import")
    run("a marker on a line of one import passes", {**clean, "services/Apps.qml": "import qs.dock // layering-exception: GF-087\nItem {}\n"}, None)
    run("two violations on a marked line fail",
        {**clean, "services/Apps.qml": "import qs.dock; import qs.desktop // layering-exception: GF-087\nItem {}\n"}, "a marker covers exactly one import")
    run("the permanent marker does not cover a second import on the line",
        {**clean, "security/lock/Lock.qml": "import Quickshell.Hyprland; import qs.desktop // layering-exception: ADR-0021 security\nItem {}\n"},
        "a marker covers exactly one import")
    run("GF-050 does not cover a second import on the line",
        {**clean, "security/idle/SleepInhibitor.qml": "import qs.notifications; import qs.search // layering-exception: GF-050\nItem {}\n"},
        "a marker covers exactly one import")
    run("GF-050 needs the import in code, not in a comment",
        {**clean, "security/idle/SleepInhibitor.qml": "import qs.search /* qs.notifications */ // layering-exception: GF-050\nItem {}\n"}, "`GF-050` marker is for the")
    run("a block comment before an import does not hide it", {**clean, "services/Apps.qml": "/* x */ import qs.dock\nItem {}\n"}, "imports go to a lower layer only")
    run("a block comment around an import hides it", {**clean, "services/Apps.qml": "/* import qs.dock */\nItem {}\n"}, None)
    run("a multi-line block comment hides its imports", {**clean, "services/Apps.qml": "/*\nimport qs.dock\n*/\nItem {}\n"}, None)
    run("a line comment after an import hides a second one", {**clean, "services/Apps.qml": "import qs.platform // import qs.dock\nItem {}\n"}, None)
    # No hand parsing: imports and raw event names come from Qt's own parser (qmlimportscanner and qmldom). The cases are the reviewers'
    # evasions of the earlier hand-written readers; every one must be caught.
    low = "imports go to a lower layer only"
    raw = "raw Hyprland events go through qs.platform"
    bad = "does not parse"

    def svc(text):
        return {**clean, "services/Apps.qml": text}

    qd = "is not a plain `module` line or a type entry"
    run("a qmldir singleton entry naming its own file passes", {**clean, "lib/qmldir": "module qs.lib\n# a comment\nsingleton Mode 1.0 Mode.qml\n"}, None)
    run("a qmldir `import qs.dock` is refused", {**clean, "services/qmldir": "module qs.services\nimport qs.dock\n"}, qd)
    run("a qmldir `import Quickshell.Hyprland` is refused", {**clean, "search/qmldir": "module qs.search\nimport Quickshell.Hyprland\n"}, qd)
    run("a qmldir `depends` is refused", {**clean, "search/qmldir": "module qs.search\ndepends qs.dock\n"}, qd)
    run("a qmldir plugin line is refused", {**clean, "search/qmldir": "module qs.search\nplugin Evil\n"}, qd)
    run("a qmldir type entry pointing outside its directory is refused", {**clean, "search/qmldir": "module qs.search\nEvil 1.0 ../dock/X.qml\n"}, qd)
    run("a qmldir entry with another extension is refused", {**clean, "search/qmldir": "module qs.search\nEvil 1.0 Evil.qmlx\n"}, qd)
    run("a qmldir entry naming a missing file is refused", {**clean, "search/qmldir": "module qs.search\nEvil 1.0 Evil.qml\n"}, "names a file that does not exist")
    run("a .mjs module is refused", {**clean, "services/X.mjs": "export const a = 1;\n"}, ".mjs modules are not read")
    run("Qt.include in a JS file is refused", {**clean, "services/X.js": '.pragma library\nQt.include("../dock/DockModel.js");\n'}, "Qt.include")
    run("Qt.include in a QML file is refused", svc('Item { Component.onCompleted: Qt.include("x.js") }\n'), "Qt.include")
    run("Qt[\"include\"] is refused", svc('Item { Component.onCompleted: Qt["include"]("x.js") }\n'), "Qt.include")
    run("Qt with a comment before .include is refused", {**clean, "services/X.js": '.pragma library\nQt/**/.include("../dock/DockModel.js");\n'}, "Qt.include")
    run("Qt with a comment and a line break before .include is refused", {**clean, "services/X.js": '.pragma library\nQt // x\n  /* y */ .include("../dock/DockModel.js");\n'}, "Qt.include")
    run("Qt[ comment \"include\" ] is refused", svc('Item { Component.onCompleted: Qt[/**/"include"/**/]("x.js") }\n'), "Qt.include")
    run("a \\x escape spelling rawEvent is seen", {**clean, "search/S.qml": 'Item { function f(o) { return o["\\x72awEvent"]; } }\n'}, raw)
    run("an octal escape does not parse (so it cannot spell rawEvent)", {**clean, "search/S.qml": 'Item { function f(o) { return o["\\162awEvent"]; } }\n'}, "does not parse")
    run("a line continuation spelling rawEvent is seen", {**clean, "search/S.qml": 'Item { function f(o) { return o["raw\\\nEvent"]; } }\n'}, raw)
    run("a bare `import qs` is refused", svc("import qs\nItem {}\n"), "bare `import qs`")
    run("a root: import is refused even when such a directory exists",
        {**clean, "services/root:/X.js": ".pragma library\n", "services/Apps.qml": 'import "root:/X.js" as X\nItem {}\n'}, "unresolvable import")
    run("an import spelled `qs .dock` is seen", svc("import qs .dock\nItem {}\n"), low)
    run("an import spelled `qs .dock`, marked, passes (the marker finds the import by its parsed name)", svc("import qs .dock // layering-exception: GF-087\nItem {}\n"), None)
    run("an import with a comment inside the dotted name is seen", svc("import qs/**/.dock\nItem {}\n"), low)
    unres = "unresolvable import"
    run("a root: directory import is refused", svc('import "root:/dock"\nItem {}\n'), unres)
    run("a root: file import is refused", svc('import "root:/dock/DockModel.js" as M\nItem {}\n'), unres)
    run("a file: URL import is refused", svc('import "file:///somewhere/dock"\nItem {}\n'), unres)
    run("an absolute path import is refused", svc('import "/etc"\nItem {}\n'), unres)
    run("an import of a path that does not exist is refused", svc('import "../nothing"\nItem {}\n'), unres)
    run("an import that leaves the tree is refused", svc('import "../../outside"\nItem {}\n'), unres)
    run("a percent-escaped path is decoded and seen", svc('import "../%64ock/DockModel.js" as M\nItem {}\n'), low)
    run("a percent-escaped path, marked, passes", svc('import "../%64ock/DockModel.js" as M // layering-exception: GF-087\nItem {}\n'), None)
    run("a directory import with a doubled slash is seen", svc('import "..//dock"\nItem {}\n'), low)
    run("a directory import with a doubled slash, marked, passes", svc('import "..//dock" // layering-exception: GF-087\nItem {}\n'), None)
    run("a string holding /* in a pragma does not swallow the next import", svc('pragma Translator: "a/*"\nimport qs.dock\nItem {}\n'), low)
    run("a shebang line does not end the header", svc("#!/usr/bin/env qml\n/**/ import qs.dock\nItem {}\n"), low)
    run("an import split over lines with a form feed is seen", svc("import\n\fqs.dock\nItem {}\n"), low)
    run("a marker on the last line of an import split over lines covers it", svc("import\n\fqs.dock // layering-exception: GF-087\nItem {}\n"), None)
    run("a path import split over lines with a form feed is seen", svc('import\n\f"../dock"\nItem {}\n'), low)
    run("a byte order mark before a single import is seen", svc("﻿import qs.dock\nItem {}\n"), low)
    run("an import after a block comment on the same line is seen", svc("/**/ import qs.dock\nItem {}\n"), low)
    run("a pragma split over two lines does not end the header", svc("pragma\n    Singleton\n/**/ import qs.dock\nItem {}\n"), low)
    run("a JS .import after a comment is seen", {**clean, "dock/Z.js": ".pragma library\n", "services/Y.js": '.pragma library\n/**/ .import "../dock/Z.js" as Z\n'}, low)
    unseen = "that Qt's import scanner does not report"
    run("a JS .import the scanner skips after a split .pragma is refused",
        {**clean, "dock/Z.js": ".pragma library\n", "services/Y.js": '.pragma\n    library\n/**/ .import "../dock/Z.js" as Z\n'}, unseen)
    run("a JS .import the scanner skips after code is refused", {**clean, "services/Y.js": 'var x = 1;\n.import "../dock/DockModel.js" as M\n'}, unseen)
    run("an import after the root object does not parse", svc("Item {}\nimport qs.dock\n"), bad)
    run("a syntax error anywhere does not parse", svc("import qs.dock\nItem { property var x: \n"), bad)
    run("a second root object does not parse", {**clean, "search/S.qml": "Item {}\nItem { function onRawEvent() {} }\n"}, bad)
    # Raw events: the syntax tree names the identifier, so the spelling of the surrounding code cannot hide it, and a comment is not a use.
    body = "Item {\n    %s\n    function onRawEvent() {}\n}\n"
    run("N01: `.in /` and strings holding /* and */ hide nothing",
        {**clean, "search/S.qml": body % 'property var x: a.in / b + "x/ " + "/*"; property string t: "*/"'}, raw)
    run("N03: `a++ + /[/*]/` hides nothing", {**clean, "search/S.qml": body % "property var x: a++ + /[/*]/"}, raw)
    run("N17: `a - -/[/*]/` hides nothing", {**clean, "search/S.qml": body % "property var x: a - -/[/*]/"}, raw)
    run("N20: a regex holding /* and a nested template hide nothing",
        {**clean, "search/S.qml": body % 'property var x: p.replace(/\\/*$/, "") + `a ${ `b/*c` } d`'}, raw)
    run("a regex after return and a long comment hides nothing",
        {**clean, "search/S.qml": body % "function f(p) { return /* a comment longer than 24 chars */ /\\/*/.test(p); }"}, raw)
    run("a block comment opened in the body hides nothing", {**clean, "search/S.qml": "Item {\n    /* a comment\n    */\n    function onRawEvent() {}\n}\n"}, raw)
    run("`function onRawEvent` is seen", {**clean, "search/S.qml": "Item { function onRawEvent(e) {} }\n"}, raw)
    run("a rawEvent binding is seen", {**clean, "search/S.qml": "Item { Connections { function onRawEvent(event) {} } }\n"}, raw)
    run("a rawEvent member access is seen", {**clean, "search/S.qml": "Item { property var h; Component.onCompleted: h.rawEvent.connect(null) }\n"}, raw)
    run("a Quickshell.Hyprland import is seen", {**clean, "search/S.qml": "import Quickshell.Hyprland\nItem {}\n"}, raw)
    run("a Quickshell.Hyprland import spelled with spaces is seen", {**clean, "search/S.qml": "import Quickshell .Hyprland\nItem {}\n"}, raw)
    run("a JS file importing Quickshell.Hyprland is seen", {**clean, "search/S.js": ".import Quickshell.Hyprland 1.0 as H\n"}, raw)
    run("a JS body calling h.rawEvent.connect is seen", {**clean, "search/S.js": ".pragma library\nfunction f(h, cb) { h.rawEvent.connect(cb); }\n"}, raw)
    run("a JS rawEvent mention in a comment counts (no tree for JS: a false positive, never a miss)", {**clean, "search/S.js": ".pragma library\n// rawEvent\n"}, raw)
    run("a JS onRawEvent function is seen", {**clean, "search/S.js": ".pragma library\nfunction onRawEvent(e) {}\n"}, raw)
    run("a destructured rawEvent property is seen", {**clean, "search/S.qml": "Item { function f(o) { const {rawEvent: ev} = o; } }\n"}, raw)
    run("a rawEvent string key is seen", {**clean, "search/S.qml": 'Item { function f(o) { return o["rawEvent"]; } }\n'}, raw)
    run("a single-quoted rawEvent string key is seen", {**clean, "search/S.qml": "Item { function f(o) { return o['rawEvent']; } }\n"}, raw)
    run("an escaped spelling of rawEvent is seen", {**clean, "search/S.qml": 'Item { function f(o) { return o["\\u0072awEvent"]; } }\n'}, raw)
    run("a rawEvent mention in a JS file of platform is fine", {**clean, "platform/X.js": ".pragma library\nfunction onRawEvent(e) {}\n"}, None)
    run("a rawEvent mention in a comment is not a use", {**clean, "search/S.qml": "Item {\n    // onRawEvent is not used here\n    /* Quickshell.Hyprland */\n}\n"}, None)
    run("a platform file may use raw events", {**clean, "platform/Compositor.qml": "import Quickshell.Hyprland\nItem { function onRawEvent() {} }\n"}, None)
    run("a marked Hyprland import is one violation, covered by its marker",
        {**clean, "search/S.qml": "import Quickshell.Hyprland // layering-exception: GF-087\nItem { function onRawEvent() {} }\n"}, None)
    run("pragmas belong to the header", {**clean, "services/Apps.qml": "pragma Singleton\npragma ComponentBehavior: Bound\nimport qs.platform\nItem {}\n"}, None)
    run("a block comment before the imports is part of the header", {**clean, "services/Apps.qml": "/*\n licence\n*/\nimport qs.dock\nItem {}\n"}, "imports go to a lower layer only")
    run("a JS .pragma and .import header", {**clean, "services/Y.js": '.pragma library\n.import "../dock/DockModel.js" as M\n'}, "imports go to a lower layer only")
    run("a single-quoted path counts", {**clean, "services/Apps.qml": "import '../dock/DockModel.js' as M\nItem {}\n"}, "imports go to a lower layer only")
    run("a single-quoted path, marked, passes", {**clean, "services/Apps.qml": "import '../dock/DockModel.js' as M // layering-exception: GF-087\nItem {}\n"}, None)
    run("Hyprland as a second import counts", {**clean, "search/S.qml": "import QtQuick; import Quickshell.Hyprland\nItem {}\n"}, "raw Hyprland events go through qs.platform")
    run("feature to feature while acyclic passes", {**clean, "desktop/D.qml": "import qs.dock\nItem {}\n"}, None)
    cycle = {**clean, "desktop/D.qml": "import qs.dock\nItem {}\n", "dock/Dock.qml": "import qs.services\nimport qs.desktop\nItem {}\n"}
    run("a feature cycle fails", cycle, "through a cycle of feature modules")
    run("a feature cycle marked on both lines passes",
        {**cycle, "desktop/D.qml": "import qs.dock // layering-exception: GF-087\nItem {}\n",
         "dock/Dock.qml": "import qs.services\nimport qs.desktop // layering-exception: GF-087\nItem {}\n"}, None)
    run("raw Hyprland events outside platform fail", {**clean, "search/S.qml": "import Quickshell.Hyprland\nItem {}\n"}, "raw Hyprland events go through qs.platform")
    run("rawEvent without the import fails", {**clean, "search/S.qml": "Item { function onRawEvent() {} }\n"}, "raw Hyprland events go through qs.platform")
    run("a temporary marker covers a raw event import", {**clean, "search/S.qml": "import Quickshell.Hyprland // layering-exception: GF-087\nItem {}\n"}, None)
    run("raw Hyprland in the lock without a marker fails", {**clean, "security/lock/Lock.qml": "import Quickshell.Hyprland\nItem {}\n"}, "raw Hyprland events go through qs.platform")
    run("raw Hyprland in the lock with the permanent marker passes",
        {**clean, "security/lock/Lock.qml": "import Quickshell.Hyprland // layering-exception: ADR-0021 security\nItem {}\n"}, None)
    run("the permanent marker outside security fails",
        {**clean, "search/S.qml": "import Quickshell.Hyprland // layering-exception: ADR-0021 security\nItem {}\n"}, "shell/security/lock and shell/security/idle only")
    run("the permanent marker covers raw events only",
        {**clean, "security/lock/Lock.qml": "import qs.dock // layering-exception: ADR-0021 security\nItem {}\n"}, "covers raw Hyprland events only")
    run("security imports lib, services and security", {**clean, "security/lock/Lock.qml": "import qs.lib\nimport qs.services\nimport qs.security.idle\nItem {}\n"}, None)
    run("security importing a feature fails", {**clean, "security/lock/Lock.qml": "import qs.desktop\nItem {}\n"}, "may import only lib, services and security")
    run("security importing platform fails", {**clean, "security/lock/Lock.qml": "import qs.platform\nItem {}\n"}, "may import only lib, services and security")
    run("a security import marked GF-050 passes",
        {**clean, "security/idle/SleepInhibitor.qml": "import qs.notifications // layering-exception: GF-050\nItem {}\n"}, None)
    run("GF-050 on another import of that file fails",
        {**clean, "security/idle/SleepInhibitor.qml": "import qs.search // layering-exception: GF-050\nItem {}\n"}, "`GF-050` marker is for the")
    run("GF-050 in another file fails",
        {**clean, "security/idle/Idle.qml": "import qs.notifications // layering-exception: GF-050\nItem {}\n"}, "`GF-050` marker is for the")
    run("GF-050 outside security fails", {**clean, "services/Apps.qml": "import qs.dock // layering-exception: GF-050\nItem {}\n"}, "`GF-050` marker is for the")
    run("the permanent marker in the idle module passes",
        {**clean, "security/idle/Idle.qml": "import Quickshell.Hyprland // layering-exception: ADR-0021 security\nItem {}\n"}, None)
    run("the permanent marker in polkit fails",
        {**clean, "security/polkit/Auth.qml": "import Quickshell.Hyprland // layering-exception: ADR-0021 security\nItem {}\n"}, "shell/security/lock and shell/security/idle only")
    run("the permanent marker in security itself fails",
        {**clean, "security/Mod.qml": "import Quickshell.Hyprland // layering-exception: ADR-0021 security\nItem {}\n"}, "shell/security/lock and shell/security/idle only")
    run("a feature importing security is a feature edge", {**clean, "dock/Dock.qml": "import qs.services\nimport qs.security.lock\nItem {}\n"}, None)
    secret = {**clean, **modules("security.secret", "security.host"), "security/secret/SecretAgent.qml": "import qs.security\nItem {}\n",
              "security/host/SheetHost.qml": "import qs.security\nimport qs.security.polkit\nimport qs.security.secret\nItem {}\n"}
    run("SheetHost.qml imports qs.security.secret", secret, None)
    run("shell.qml importing qs.security.secret fails (ADR-0041 S3: the sheets run in the security process)",
        {**secret, "shell.qml": "import qs.dock\nimport qs.services\nimport qs.security.secret\nShellRoot {}\n"}, SECRET_REASON)
    run("a feature importing qs.security.secret fails", {**secret, "dock/Dock.qml": "import qs.services\nimport qs.security.secret\nItem {}\n"},
        SECRET_REASON)
    run("another security module importing qs.security.secret fails",
        {**secret, "security/lock/Lock.qml": "import qs.security.secret\nItem {}\n"}, SECRET_REASON)
    run("another file of the host importing qs.security.secret fails",
        {**secret, "security/host/SecurityHost.qml": "import qs.security.secret\nItem {}\n"}, SECRET_REASON)
    run("another root file importing qs.security.secret fails", {**secret, "Other.qml": "import qs.security.secret\nItem {}\n"},
        SECRET_REASON)
    run("a relative import of the secret sheets' directory fails", {**secret, "dock/Dock.qml": 'import "../security/secret"\nItem {}\n'},
        SECRET_REASON)
    run("a marker does not excuse it",
        {**secret, "dock/Dock.qml": "import qs.security.secret // layering-exception: GF-087\nItem {}\n"}, "no layering-exception marker covers it")
    run("a file of the module itself is no edge", {**clean, "dock/Dock.qml": 'import "."\nimport "DockModel.js" as M\nItem {}\n'}, None)

    # Test trees: a tree that links a shell module directory links lib too.
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        shell = build(tmp, {**base_mods, **clean})
        tree = tmp / "tests" / "shell" / "case"
        tree.mkdir(parents=True)
        (tree / "services").symlink_to("../../../shell/services")
        (tree / "Dock.qml").symlink_to("../../../shell/dock/Dock.qml")  # a file link is no module link
        if not any("no `lib` link" in p for p in tree_problems(tmp)):
            failures.append("test tree without lib passes")
        (tree / "lib").symlink_to("../../../shell/lib")
        if tree_problems(tmp):
            failures.append(f"test tree with lib fails: {tree_problems(tmp)}")
        (tree / "lib").unlink()
        (tree / "lib").symlink_to("../../../shell/store")
        if not any("no `lib` link" in p for p in tree_problems(tmp)):
            failures.append("a lib link to another module passes")
        other = tmp / "tests" / "shell" / "files_only"
        other.mkdir()
        (other / "Dock.qml").symlink_to("../../../shell/dock/Dock.qml")
        if any("files_only" in p for p in tree_problems(tmp)):
            failures.append("a tree with file links only needs no lib")

    # The tools: present and read as relied on; a missing one is a loud failure, not an empty reading.
    if tool_problems():
        failures.append(f"the canary fails on the installed tools: {tool_problems()}")
    saved = globals()["IMPORT_SCANNER"]
    try:
        globals()["IMPORT_SCANNER"] = "/nonexistent/qmlimportscanner"
        if not any("is missing" in x for x in tool_problems()):
            failures.append("a missing qmlimportscanner is not reported")
    finally:
        globals()["IMPORT_SCANNER"] = saved

    # Tools that run but say nothing useful (a changed output) are caught by the canary and by the tree failure, not read as "no imports".
    def with_fake_tools(scanner_body, dom_body, check):
        with tempfile.TemporaryDirectory() as fake_dir:
            fakes = {}
            for key, body in (("IMPORT_SCANNER", scanner_body), ("QMLDOM", dom_body)):
                if body is not None:
                    f = Path(fake_dir) / key
                    f.write_text("#!/bin/sh\n" + body + "\n")
                    f.chmod(0o755)
                    fakes[key] = str(f)
            saved = {k: globals()[k] for k in fakes}
            _IMPORTS.clear()
            _ASTS.clear()
            try:
                globals().update(fakes)
                check()
            finally:
                globals().update(saved)
                _IMPORTS.clear()
                _ASTS.clear()

    def expect_canary(text):
        def check():
            if not any(text in x for x in tool_problems()):
                failures.append(f"the canary did not report {text!r}: {tool_problems()}")
        return check

    with_fake_tools("echo '[]'", None, expect_canary("did not report the canary"))
    with_fake_tools(None, "true", expect_canary("did not read the canary as expected"))

    def expect_loud():
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            shell = build(tmp, {**base_mods, **clean, "services/Apps.qml": "import qs.dock\nItem {}\n"})
            if not any("qmldom could not read" in x for x in problems(shell, tmp)):
                failures.append("a qmldom that gives nothing for a file that needs its tree is not a loud failure")

    with_fake_tools(None, "true", expect_loud)

    # In a checkout top level only tracked files count: an untracked stray file with a violating import, or a stray test tree
    # without lib, is not the source.
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        shell = build(tmp, {**base_mods, **clean})
        tree = tmp / "tests" / "shell" / "case"
        tree.mkdir(parents=True)
        (tree / "services").symlink_to("../../../shell/services")
        (tree / "lib").symlink_to("../../../shell/lib")

        def vcs(*a):
            return subprocess.run(["git", "-C", str(tmp), *a], capture_output=True, text=True)

        if vcs("init", "-q").returncode != 0:
            failures.append("git init failed in the selftest tree")
        else:
            vcs("add", "-A")
            (shell / "services" / "Stray.qml").write_text("import qs.dock\nItem {}\n", encoding="utf-8")
            stray = tmp / "tests" / "shell" / "stray"
            stray.mkdir()
            (stray / "services").symlink_to("../../../shell/services")
            if problems(shell, tmp) or tree_problems(tmp):
                failures.append(f"an untracked stray file counts: {problems(shell, tmp) + tree_problems(tmp)}")
            vcs("add", "-A")
            if not any("Stray.qml" in x for x in problems(shell, tmp)) or not any("stray" in x for x in tree_problems(tmp)):
                failures.append("a tracked stray file is not seen")

    # The strongly connected components: the whole graph, then the feature graph without layer violations.
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        shell = build(tmp, {**base_mods, **cycle, "services/Apps.qml": "import qs.dock\nItem {}\n"})
        _, (nodes, edges) = analyze(shell)
        comps = tarjan(nodes, edges)
        if comps != [["desktop", "dock", "services"]]:
            failures.append(f"SCC of the whole graph: {comps}")
    return failures


def tool_problems():
    """A canary for the two Qt tools: each must exist and read a tiny file the way this check relies on. Without it a missing tool or
    a changed dump would make the readers see nothing and the tree pass."""
    for tool in (IMPORT_SCANNER, QMLDOM):
        if not os.access(tool, os.X_OK):
            return [f"{tool} is missing: this check needs qt6-declarative (qmlimportscanner and qmldom)"]
    with tempfile.TemporaryDirectory() as t:
        f = Path(t) / "Canary.qml"
        f.write_text("import QtQuick\nimport qs .canary // note\nItem { function onRawEvent() {} }\n", encoding="utf-8")
        try:
            seen = scanner_imports(f)
            tree = ast_of(f)
        except QtToolError as e:
            return [f"the Qt tools fail on a canary file: {e}"]
    out = []
    if ("module", "qs.canary") not in seen:
        out.append(f"qmlimportscanner did not report the canary's `import qs .canary` (reported {seen[:4]}): has its output changed?")
    if tree is None or ("qs.canary", 2, 2) not in tree["imports"] or tree["raw"] != [3]:
        out.append(f"qmldom --dump-ast did not read the canary as expected (got {tree}): has its dump changed?")
    return out


def main(argv):
    root = Path(__file__).resolve().parents[2]
    shell = root / "shell"
    broken = tool_problems()
    if broken:
        for b in broken:
            print("import-graph: " + b)
        print("import-graph: FAILED (the Qt tools are unusable)")
        return 1
    if "--selftest" in argv:
        failures = selftest()
        for f in failures:
            print("FAIL: " + f)
        print("import-graph selftest: " + ("FAILED" if failures else "ok"))
        return 1 if failures else 0
    if "--graph" in argv:
        print(describe(shell))
        return 0
    bad = problems(shell, root) + tree_problems(root)
    for line in bad:
        print(line)
    violations, _ = analyze(shell)
    print(f"import-graph: {'FAILED, ' + str(len(bad)) + ' problem(s)' if bad else 'ok'} ({sum(1 for v in violations if v[3])} marked exception(s))")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
