#!/usr/bin/env python3
"""ADR-0041 step 1, S2 and S3: everything that locks, the polkit agent and the secret sheets live in the security process,
and nothing of the UI's world runs there. Static (data layer), read on the code with comments and string contents removed:

  1. the UI tree (shell/** but shell/security/** and shell/security.qml) imports no security module at all (qs.security and
     every qs.security.*, by name or by path; S3) and never names the Lock singleton, Idle, SleepInhibitor, AuthAgent,
     SecretAgent, SheetQueue, SheetSession, PrompterClient or PolkitAgent: no `Lock.lock` caller is left in the UI, and
     referencing Lock there would start a second WlSessionLock and a second `lock` IPC target in the UI process; an
     AuthAgent there would be a second polkit agent of the session, a SecretAgent a second client of grassfield-prompter;
  1b. nor builds one from strings (the opus review of S3, MINOR-2): in the UI tree and in ui/ (Grassfield.Ui, which both
     processes load), no Qt.createQmlObject; a createComponent or a Loader/LazyLoader source only as one plain string
     literal or Qt.resolvedUrl of one (a computed source cannot be read), but for the desktop widgets' one computed source,
     whose function (shell/widgets/Registry.qml `source`) is then held to return only plain resolvedUrl literals of
     builtin/ files or ""; and no string literal (comments aside, string contents read) that names a security path
     (`security/`, `qs.security`), Quickshell.Services.Polkit or a security type (STRING_NAMES), web addresses (http, https)
     aside, which name no file of the tree (file: and qrc: addresses are read; the opus delta review of S3, NIT), but never
     as a Loader or createComponent source (QML from the network: round 2, NIT);
  2. shell/security/host/SecurityHost.qml instantiates Idle exactly once (one idle module, one sleep inhibitor) and only the
     types listed in HOST_TYPES, and makes the sheets at run time (S3: shell/security/host/SheetHost.qml, created once by
     its URL, never declared, so that a sheet that cannot load never keeps the lock from loading); SheetHost.qml instantiates
     AuthAgent, SecretAgent and SheetQueue exactly once each (one polkit agent, one prompter client, one queue for all their
     sheets) and only the types listed in SHEET_HOST_TYPES, and nothing else names it;
  3. the security modules (shell/security/lock/**, idle/**, polkit/**, secret/**, the shared shell/security/*.qml and
     shell/security/host/SecurityHost.qml) import no UI feature module (qs.desktop, qs.notifications, ...) and name only the
     qs.services singletons in SERVICES_ALLOWED; the polkit and secret modules none at all (S3: they read the session from
     SheetSession only): the others start processes, own bus names, write files or empty directories the UI uses (Popups,
     ThemeIcons, WallpaperState, Battery's power profile, Notifications, MenuBridge, ...) and must not run a second time in
     the security process;
  3b. exactly one PolkitAgent in the tree, in shell/security/polkit/AuthAgent.qml, the one file that imports
     Quickshell.Services.Polkit (S3: "exactly one agent in the session");
  3c. the sheets read the session in process (the opus review of 77a0ceb3, MINOR-4): SessionState and LockClient are named
     by no security module, and SheetSession is written only by the host's five Bindings, each from the lock or idle of
     the same process (locked <- Lock.locked || Lock.strandedProbing, displaysOff <- idle.displayOff, saverShown <-
     idle.saverShown, starting <- idle.starting, the held notice's words only: the opus delta review of S3, LOW; sleeping
     <- idle.sleeping, which stops the polkit agent's registration attempts: round 2, MINOR-A): no other
     Binding targets it and no file assigns one of its properties; it fails closed until bound (`locked: true`,
     `displaysOff: true`; the opus review of S3, NIT M3; tests/security/tst_sheetsession.qml reads the same at run time);
  4. shell/lib/LockState.js is the one definition of the state file: the publisher and LockClient import it by a relative
     path, and nothing else writes a file named grassfield-lock-state-*;
  5. the UI never writes the state file (the opus review of 77a0ceb3, MINOR-5): shell/services/LockClient.qml, the one UI file
     that knows its path, has no write of a FileView (setText, setData, atomicWrites, blockWrites, an adapter), starts no
     process with its path, and no other UI file names LockClient.path or LockState.filePath.

  python3 -I tests/security/security_process_scan.py <repo>             "ok" or one line per finding, exit 1
  python3 -I tests/security/security_process_scan.py --selftest <repo>   each planted mutant is found, the tree is clean
Standard library only."""
import os
import re
import sys

SERVICES_ALLOWED = {"Settings", "VisualFixtures", "FixedTime", "WallClock"}
HOST_TYPES = {"Scope", "Binding", "Idle"}
SHEET_HOST = "shell/security/host/SheetHost.qml"
SHEET_HOST_TYPES = {"Scope", "SheetQueue", "AuthAgent", "SecretAgent", "FileView"}
# Exactly once in SheetHost.qml each.
SHEET_HOST_ONCE = ("AuthAgent", "SecretAgent", "SheetQueue")
SHEET_HOST_URL = 'Qt.createComponent(Qt.resolvedUrl("SheetHost.qml"))'
SECURITY_MODULES = ("shell/security/lock/", "shell/security/idle/", "shell/security/polkit/", "shell/security/secret/")
# The sheets: no qs.services type at all (S3).
SHEET_MODULES = ("shell/security/polkit/", "shell/security/secret/")
SECURITY_SHARED = ("shell/security/SheetQueue.qml", "shell/security/SheetSession.qml", "shell/security/PasswordField.qml",
                   "shell/security/LockController.qml")
AGENT = "shell/security/polkit/AuthAgent.qml"
# Named nowhere in the UI (rule 1).
SECURITY_NAMES = ("Lock", "SleepInhibitor", "AuthAgent", "SecretAgent", "SheetQueue", "SheetSession", "PrompterClient",
                  "PolkitAgent")
# SheetSession's one writer and what each property is bound to (rule 3c).
SHEET_BINDINGS = {"locked": "Lock.locked || Lock.strandedProbing", "displaysOff": "idle.displayOff", "saverShown": "idle.saverShown",
                  "starting": "idle.starting", "sleeping": "idle.sleeping"}
HOST = "shell/security/host/SecurityHost.qml"
# Rule 1b: what no string of the UI tree or of ui/ may name (a security path, the polkit module, a security type).
STRING_NAMES = re.compile(r"security/|qs\.security|Quickshell\.Services\.Polkit|\b(?:PolkitAgent|AuthAgent|SecretAgent|PrompterClient"
                          r"|SheetHost|SheetSession|SheetQueue|SecurityHost)\b")
_STRING = re.compile(r'"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|`(?:\\.|[^`\\])*`', re.S)
# The one computed Loader source of the UI tree, allowed only while its function returns plain literals (global_findings).
ALLOWED_COMPUTED = {("shell/widgets/WidgetHost.qml", "Registry.source(root.widgetId)")}
REGISTRY = "shell/widgets/Registry.qml"
_LITERAL = re.compile(r'^\s*("(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\')\s*;?\s*$')
# A source that is one plain literal resolved against the file (the opus delta review of S3, NIT): as readable as the literal,
# which the string rule still reads.
_RESOLVED_LITERAL = re.compile(r'^\s*Qt\.resolvedUrl\(\s*("(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\')\s*\)\s*;?\s*$')
# A web address (http or https): it names no file of the tree, whatever its path says (the same NIT). file: and qrc: do.
_WEB_URL = re.compile(r'^["\'`]https?://')


# A source naming a web address (http, https, any case): QML fetched from the network is code no scan of the tree reads
# (the opus review of S3, round 2, NIT). The web exception of the string rule is for plain strings only.
_WEB_SOURCE = re.compile(r'^\s*(?:Qt\.resolvedUrl\(\s*)?["\']https?://', re.I)


def readable_source(text):
    """One plain string literal, or Qt.resolvedUrl of one, that is not a web address."""
    return bool((_LITERAL.match(text) or _RESOLVED_LITERAL.match(text)) and not _WEB_SOURCE.match(text))


def top_level(block):
    """The text of a { } block at its own level: nested blocks' contents removed."""
    out, depth = [], 0
    for ch in block:
        if ch == "{":
            depth += 1
            if depth == 1:
                out.append(ch)
            continue
        if ch == "}":
            depth -= 1
            if depth == 0:
                out.append(ch)
            continue
        if depth == 1:
            out.append(ch)
    return "".join(out)


def built_from_strings(path, src):
    """Rule 1b's findings for one file of the UI tree or of ui/."""
    out = []
    code = strip(src)
    with_strings = strip(src, keep_strings=True)
    if re.search(r"\bcreateQmlObject\b", code):
        out.append(f"{path}: calls createQmlObject (code built from a string cannot be checked; the security types live in the security process)")
    for m in re.finditer(r"\bcreateComponent\s*\(", with_strings):
        depth, i = 1, m.end()
        while i < len(with_strings) and depth:
            depth += {"(": 1, ")": -1}.get(with_strings[i], 0)
            i += 1
        args = with_strings[m.end():i - 1]
        if not readable_source(args):
            out.append(f"{path}: createComponent with a computed or remote source ({args.strip()[:60]}): only one plain string literal (or Qt.resolvedUrl of one), not a web address, can be checked")
    for m in re.finditer(r"\b(?:Lazy)?Loader\s*\{", with_strings):
        depth, i = 0, m.end() - 1
        for j in range(m.end() - 1, len(with_strings)):
            depth += {"{": 1, "}": -1}.get(with_strings[j], 0)
            if depth == 0:
                i = j + 1
                break
        own = top_level(with_strings[m.end() - 1:i])
        for s in re.finditer(r"(?:^|[\s;{])source\s*:\s*([^\n;}]*)", own):
            if (path, s.group(1).strip()) in ALLOWED_COMPUTED:
                continue
            if not readable_source(s.group(1)):
                out.append(f"{path}: a Loader with a computed or remote source ({s.group(1).strip()[:60]}): only one plain string literal (or Qt.resolvedUrl of one), not a web address, can be checked")
    for s in _STRING.finditer(with_strings):
        if STRING_NAMES.search(s.group(0)) and not _WEB_URL.match(s.group(0)):
            out.append(f"{path}: a string names a security path, module or type ({s.group(0)[:60]}): the UI builds no security code")
    return out
CLIENT = "shell/services/LockClient.qml"
# What would write a file from LockClient.qml: a FileView write, its write options or an adapter, or a process given the path.
CLIENT_WRITES = (
    ("writes a FileView (setText)", r"\.\s*setText\s*\("),
    ("writes a FileView (setData)", r"\.\s*setData\s*\("),
    ("sets a FileView write option (atomicWrites)", r"\batomicWrites\s*:"),
    ("sets a FileView write option (blockWrites)", r"\bblockWrites\s*:"),
    ("gives a FileView an adapter (writeAdapter, JsonAdapter)", r"\bwriteAdapter\b|\bJsonAdapter\b|\badapter\s*:"),
    ("passes the state file's path to a process", r"command\s*:[^\n]*\b(root\.)?path\b|\[[^\]\n]*\b(root\.|file\.)path\b[^\]\n]*\]"),
)


_CACHE = {}


def strip(src, keep_strings=False):
    """The source without comments and with string contents blanked unless `keep_strings` (a scanner, not a parser: enough
    for this tree). Cached by text: the selftest scans the tree once per mutant."""
    key = (src, keep_strings)
    if key not in _CACHE:
        _CACHE[key] = _strip(src, keep_strings)
    return _CACHE[key]


_TOKENS = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|`(?:\\.|[^`\\])*`', re.S)


def _strip(src, keep_strings):
    def repl(m):
        t = m.group(0)
        if t.startswith("//"):
            return ""
        if t.startswith("/*"):
            return " "
        return t if keep_strings else t[0] + t[0]
    return _TOKENS.sub(repl, src)


def imports_of(src):
    """The QML imports (module names and quoted paths) of a file, from its raw text (import lines are not in comments)."""
    mods = re.findall(r"^\s*import\s+([A-Za-z_][\w.]*)", src, re.M)
    paths = re.findall(r"^\s*import\s+\"([^\"]+)\"", src, re.M)
    return mods, paths


def tree(repo):
    files = {}
    for base in ("shell", "ui"):
        for d, _, names in os.walk(os.path.join(repo, base)):
            for name in names:
                if name.endswith((".qml", ".js")):
                    p = os.path.join(d, name)
                    files[os.path.relpath(p, repo)] = open(p, encoding="utf-8", errors="replace").read()
    return files


def services_singletons(repo):
    out = set()
    for line in open(os.path.join(repo, "shell/services/qmldir"), encoding="utf-8"):
        m = re.match(r"^\s*(?:singleton\s+)?([A-Z]\w*)\s+\d", line)
        if m:
            out.add(m.group(1))
    return out


_PER_FILE = {}


def findings(files, singletons):
    out = []
    for path, src in sorted(files.items()):
        key = (path, src)
        if key not in _PER_FILE:
            _PER_FILE[key] = file_findings(path, src, singletons)
        out += _PER_FILE[key]
    return out + global_findings(files)


def file_findings(path, src, singletons):
    """The findings of one file (cached by its text: the selftest scans the tree once per mutant)."""
    out = []
    ui = path.startswith("shell/") and not path.startswith("shell/security/") and path != "shell/security.qml"
    code = strip(src)
    mods, paths = imports_of(src)
    if ui or path.startswith("ui/"):
        out += built_from_strings(path, src)
    if ui:
        for m in mods:
            if m == "qs.security" or m.startswith("qs.security."):
                out.append(f"{path}: imports {m} (the lock, idle, the polkit agent and the secret sheets run in the security process only)")
        for p in paths:
            if re.search(r"(^|/)security(/|$)", p):
                out.append(f"{path}: imports {p} (the security modules run in the security process only)")
        if re.search(r"\bIdle\s*\{", code) or any(re.search(r"\b" + n + r"\b", code) for n in SECURITY_NAMES):
            out.append(f"{path}: names a security module's type ({', '.join(SECURITY_NAMES)} or Idle): the UI asks the security process over IPC and reads what it publishes")
        if path.endswith(".qml") and re.search(r"\bSecurityHost\s*\{", code):
            out.append(f"{path}: instantiates SecurityHost (shell/security.qml only)")
    security = path.startswith(SECURITY_MODULES) or path in (HOST, SHEET_HOST) or path in SECURITY_SHARED
    if security:
        for m in mods:
            if m.startswith("qs.") and m not in ("qs.services", "qs.security", "qs.security.lock", "qs.security.idle", "qs.security.polkit", "qs.security.secret"):
                out.append(f"{path}: imports {m} (a UI module in the security process)")
        used = set(re.findall(r"\b([A-Z]\w*)\s*\.", code)) | set(re.findall(r"\b([A-Z]\w*)\s*\{", code))
        sheets = path.startswith(SHEET_MODULES) or path in SECURITY_SHARED or path == SHEET_HOST
        allowed = set() if sheets else SERVICES_ALLOWED
        for name in sorted((used & singletons) - allowed):
            out.append(f"{path}: uses the qs.services type {name}, which must not run in the security process (allowed here: {', '.join(sorted(allowed)) or 'none'})")
        if sheets and "qs.services" in mods:
            out.append(f"{path}: imports qs.services (the sheets read the session from SheetSession only, ADR-0041 S3)")
        for name in ("SessionState", "LockClient"):
            if re.search(r"\b" + name + r"\b", code):
                out.append(f"{path}: names {name}, the UI's reading of the lock (the security process reads its own lock: MINOR-4)")
    if path.endswith(".qml") and path != HOST:
        if re.search(r"\bBinding\s*\{[^{}]*?\btarget\s*:\s*SheetSession\b", code):
            out.append(f"{path}: binds SheetSession (only the host does, from its own lock and idle)")
    if re.search(r"\bSheetSession\s*\.\s*\w+\s*(=(?!=)|\+=|-=|\+\+|--)", code) or re.search(r"(\+\+|--)\s*SheetSession\s*\.", code):
        out.append(f"{path}: assigns a SheetSession property (only the host's Bindings write it)")
    if path != AGENT:
        if re.search(r"\bPolkitAgent\s*\{", code):
            out.append(f"{path}: instantiates a PolkitAgent (the session's one agent is AuthAgent.qml's, in the security process)")
        if "Quickshell.Services.Polkit" in mods:
            out.append(f"{path}: imports Quickshell.Services.Polkit (only AuthAgent.qml does)")
    if "grassfield-lock-state-" in strip(src, keep_strings=True) and path != "shell/lib/LockState.js":
        out.append(f"{path}: spells the state file's name (shell/lib/LockState.js is its one definition)")
    if path == CLIENT:
        for what, pattern in CLIENT_WRITES:
            if re.search(pattern, code):
                out.append(f"{path}: {what} (the UI never writes the state file; only the security process does)")
    elif ui and (re.search(r"\bLockClient\s*\.\s*path\b", code) or re.search(r"\bLockState\s*\.\s*filePath\b", code)):
        out.append(f"{path}: names the state file's path (LockClient.qml reads it, the UI writes it nowhere)")
    return out


def global_findings(files):
    out = []
    host = files.get(HOST)
    if host is None:
        out.append(f"{HOST}: missing")
    else:
        code = strip(host)
        types = set(re.findall(r"\b([A-Z]\w*)\s*\{", code))
        if types - HOST_TYPES:
            out.append(f"{HOST}: instantiates {', '.join(sorted(types - HOST_TYPES))} (allowed: {', '.join(sorted(HOST_TYPES))})")
        if len(re.findall(r"\bIdle\s*\{", code)) != 1:
            out.append(f"{HOST}: not exactly one Idle (one idle module, one sleep inhibitor)")
        made = strip(host, keep_strings=True)
        if made.count(SHEET_HOST_URL) != 1 or len(re.findall(r"\bcreateObject\s*\(", code)) != 1 or len(re.findall(r"\bcreateComponent\s*\(", code)) != 1:
            out.append(f"{HOST}: does not make SheetHost.qml exactly once, by its URL ({SHEET_HOST_URL}, one createObject)")
        if not re.search(r"Binding\s*\{\s*target\s*:\s*Lock\s*property\s*:\s*\"authorizing\"\s*value\s*:\s*root\.sheets\s*!==\s*null\s*&&\s*root\.sheets\.authorizing\s*===\s*true\s*\}", made) \
                or not re.search(r"Binding\s*\{\s*target\s*:\s*Lock\s*property\s*:\s*\"securityKeyboard\"\s*value\s*:\s*root\.sheets\s*!==\s*null\s*&&\s*root\.sheets\.securityKeyboard\s*===\s*true\s*\}", made):
            out.append(f"{HOST}: does not publish the sheets' authorizing and securityKeyboard (false without sheets)")
        bound = re.findall(r"Binding\s*\{\s*target\s*:\s*SheetSession\s*property\s*:\s*\"\"\s*value\s*:\s*([^\n}]*?)\s*\}", code)
        named = re.findall(r"Binding\s*\{\s*target\s*:\s*SheetSession\s*property\s*:\s*\"(\w+)\"\s*value\s*:\s*([^\n}]*?)\s*\}", strip(host, keep_strings=True))
        if len(re.findall(r"\bBinding\s*\{[^{}]*?\btarget\s*:\s*SheetSession\b", code)) != len(SHEET_BINDINGS) or len(bound) != len(SHEET_BINDINGS) \
                or dict(named) != SHEET_BINDINGS:
            out.append(f"{HOST}: SheetSession is not bound exactly as {SHEET_BINDINGS} (the sheets read the lock and idle of this process)")
    registry = strip(files.get(REGISTRY, ""), keep_strings=True)
    body = re.search(r"function source\(id: string\): url \{(.*?)\n    \}", registry, re.S)
    returns = re.findall(r"\breturn\b([^;]*);", body.group(1)) if body else []
    if not returns or any(not (r.strip() == '""' or re.fullmatch(r'\s*Qt\.resolvedUrl\("builtin/[A-Za-z0-9_/]+\.qml"\)\s*', r)) for r in returns):
        out.append(f"{REGISTRY}: source() returns something else than Qt.resolvedUrl(\"builtin/....qml\") or \"\" (WidgetHost's computed Loader source must stay a known built-in widget)")
    session = strip(files.get("shell/security/SheetSession.qml", ""))
    if not (re.search(r"^\s*property bool locked:\s*true\s*$", session, re.M) and re.search(r"^\s*property bool displaysOff:\s*true\s*$", session, re.M)):
        out.append("shell/security/SheetSession.qml: does not fail closed until bound (locked: true, displaysOff: true)")
    sheet_host = files.get(SHEET_HOST)
    if sheet_host is None:
        out.append(f"{SHEET_HOST}: missing")
    else:
        code = strip(sheet_host)
        types = set(re.findall(r"\b([A-Z]\w*)\s*\{", code))
        if types - SHEET_HOST_TYPES:
            out.append(f"{SHEET_HOST}: instantiates {', '.join(sorted(types - SHEET_HOST_TYPES))} (allowed: {', '.join(sorted(SHEET_HOST_TYPES))})")
        for name in SHEET_HOST_ONCE:
            if len(re.findall(r"\b" + name + r"\s*\{", code)) != 1:
                out.append(f"{SHEET_HOST}: not exactly one {name} (one polkit agent, one prompter client, one queue)")
    for path, src in files.items():
        if path in (HOST, SHEET_HOST):
            continue
        if re.search(r"\bSheetHost\b", strip(src, keep_strings=True)):
            out.append(f"{path}: names SheetHost (the host makes it, once)")
    agent = files.get(AGENT, "")
    if len(re.findall(r"\bPolkitAgent\s*\{", strip(agent))) != 1:
        out.append(f"{AGENT}: not exactly one PolkitAgent")
    for path, needle in (("shell/security/lock/LockPublisher.qml", '"../../lib/LockState.js" as LockState'),
                         ("shell/services/LockClient.qml", '"../lib/LockState.js" as LockState')):
        if needle not in files.get(path, ""):
            out.append(f"{path}: does not import shell/lib/LockState.js by its relative path")
    return out


def main(argv):
    if argv[:1] == ["--selftest"]:
        repo = argv[1]
        files, singletons = tree(repo), services_singletons(repo)
        ok = True
        base = findings(files, singletons)
        print(("PASS: " if not base else "FAIL: ") + "security process scan selftest: the tree is clean" + ("" if not base else " [" + "; ".join(base) + "]"))
        ok = ok and not base
        mutants = [
            ("a UI caller of Lock.lock", "shell/overlay/SystemMenu.qml", lambda s: s.replace("SessionState.requestLock(\"menu\");", "Lock.lock(\"menu\");", 1)),
            ("a Connections on Lock in the UI", "shell/saver/Saver.qml", lambda s: s.replace("    Connections {\n        target: SessionState\n", "    Connections {\n        target: Lock\n", 1)),
            ("the UI importing the lock module", "shell/shell.qml", lambda s: s.replace("import qs.services\n", "import qs.services\nimport qs.security.lock\n", 1)),
            # ADR-0041 S3: the polkit agent and the secret sheets, in the security process only.
            ("the UI importing the polkit module", "shell/shell.qml", lambda s: s.replace("import qs.services\n", "import qs.services\nimport qs.security.polkit\n", 1)),
            ("the UI importing the secret module", "shell/shell.qml", lambda s: s.replace("import qs.services\n", "import qs.services\nimport qs.security.secret\n", 1)),
            ("the UI importing qs.security", "shell/shell.qml", lambda s: s.replace("import qs.services\n", "import qs.services\nimport qs.security\n", 1)),
            ("the UI importing the polkit module by path", "shell/saver/Saver.qml", lambda s: s.replace("import \"SaverModel.js\" as SaverModel\n", "import \"SaverModel.js\" as SaverModel\nimport \"../security/polkit\"\n", 1)),
            ("a second polkit agent in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    AuthAgent {\n    }\n    Saver {\n", 1)),
            ("a prompter client in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    SecretAgent {\n    }\n    Saver {\n", 1)),
            ("a queue in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    SheetQueue {\n    }\n    Saver {\n", 1)),
            ("the UI writing SheetSession", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Binding {\n        target: SheetSession\n        property: \"locked\"\n        value: false\n    }\n    Saver {\n", 1)),
            ("a raw PolkitAgent in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    PolkitAgent {\n    }\n    Saver {\n", 1)),
            ("a second AuthAgent in the sheets", SHEET_HOST, lambda s: s.replace("    // The session's one polkit authentication agent", "    AuthAgent {\n    }\n    // The session's one polkit authentication agent", 1)),
            ("no SecretAgent in the sheets", SHEET_HOST, lambda s: s.replace("    SecretAgent {\n        id: secretAgent\n", "    Item {\n        id: secretAgent\n", 1)),
            ("a second queue in the sheets", SHEET_HOST, lambda s: s.replace("    // The session's one polkit authentication agent", "    SheetQueue {\n    }\n    // The session's one polkit authentication agent", 1)),
            ("a window in the sheets", SHEET_HOST, lambda s: s.replace("    // The session's one polkit authentication agent", "    FloatingWindow {\n    }\n    // The session's one polkit authentication agent", 1)),
            ("Settings in the sheets", SHEET_HOST, lambda s: s.replace("readonly property bool authorizing: authAgent.requestActive", "readonly property bool authorizing: Settings.reduceMotion || authAgent.requestActive", 1)),
            ("the sheets declared in the host (a load failure would take the lock down)", HOST, lambda s: s.replace("    Idle {\n        id: idle\n    }\n", "    Idle {\n        id: idle\n    }\n    SheetHost {\n    }\n", 1)),
            ("the sheets declared in the host instead of made", HOST, lambda s: s.replace('Qt.createComponent(Qt.resolvedUrl("SheetHost.qml"))', 'Qt.createComponent(Qt.resolvedUrl("Other.qml"))', 1).replace("    Idle {\n        id: idle\n    }\n", "    Idle {\n        id: idle\n    }\n    SheetHost {\n    }\n", 1)),
            ("the sheets made twice", HOST, lambda s: s.replace("            root.sheets = o;\n", "            root.sheets = o;\n            c.createObject(root);\n", 1)),
            ("the sheets made by another file", "shell/security/idle/Idle.qml", lambda s: s.replace("    IdleMonitor {\n        id: saverMonitor\n", "    property var extra: Qt.createComponent(Qt.resolvedUrl(\"../host/SheetHost.qml\"))\n    IdleMonitor {\n        id: saverMonitor\n", 1)),
            ("the sheets' state published from a constant", HOST, lambda s: s.replace("        value: root.sheets !== null && root.sheets.authorizing === true\n", "        value: false\n", 1)),
            ("a second PolkitAgent in AuthAgent.qml", "shell/security/polkit/AuthAgent.qml", lambda s: s.replace("    AuthDialogModel {\n        id: dialogModel\n", "    PolkitAgent {\n    }\n    AuthDialogModel {\n        id: dialogModel\n", 1)),
            ("a PolkitAgent in the secret agent", "shell/security/secret/SecretAgent.qml", lambda s: s.replace("    SecretSheetModel {\n        id: sheetModel\n", "    PolkitAgent {\n    }\n    SecretSheetModel {\n        id: sheetModel\n", 1).replace("import Quickshell.Io\n", "import Quickshell.Io\nimport Quickshell.Services.Polkit\n", 1)),
            ("the polkit agent reading the UI's SessionState (MINOR-4)", "shell/security/polkit/AuthAgent.qml", lambda s: s.replace("answerable: !SheetSession.locked", "answerable: !SessionState.locked", 1)),
            ("the secret agent reading LockClient (MINOR-4)", "shell/security/secret/SecretAgent.qml", lambda s: s.replace("readonly property bool shown: sheetModel.active && !SheetSession.locked", "readonly property bool shown: sheetModel.active && !LockClient.locked", 1)),
            ("the polkit agent importing qs.services", "shell/security/polkit/AuthAgent.qml", lambda s: s.replace("import qs.security\n", "import qs.security\nimport qs.services\n", 1)),
            ("ThemeIcons in the secret agent", "shell/security/secret/SecretAgent.qml", lambda s: s.replace("appIconSource: root.iconSource(sheetModel.appIcon)", "appIconSource: ThemeIcons.source(sheetModel.appIcon)", 1)),
            ("Popups in the polkit agent", "shell/security/polkit/AuthAgent.qml", lambda s: s.replace("        onIsRegisteredChanged: {\n", "        onAuthenticationRequestStarted: Popups.close()\n        onIsRegisteredChanged: {\n", 1)),
            ("Settings in the queue", "shell/security/SheetQueue.qml", lambda s: s.replace("    property bool polkitPresent: false\n", "    property bool polkitPresent: Settings.reduceMotion\n", 1)),
            ("SheetSession bound to a constant in the host", HOST, lambda s: s.replace("        property: \"locked\"\n        value: Lock.locked || Lock.strandedProbing\n", "        property: \"locked\"\n        value: false\n", 1)),
            ("SheetSession's displays bound to the lock in the host", HOST, lambda s: s.replace("        property: \"displaysOff\"\n        value: idle.displayOff\n", "        property: \"displaysOff\"\n        value: Lock.displaysOff\n", 1)),
            ("SheetSession's sleep bound to a constant in the host", HOST, lambda s: s.replace("        property: \"sleeping\"\n        value: idle.sleeping\n", "        property: \"sleeping\"\n        value: false\n", 1)),
            ("SheetSession's start bound to the saver in the host", HOST, lambda s: s.replace("        property: \"starting\"\n        value: idle.starting\n", "        property: \"starting\"\n        value: idle.saverShown\n", 1)),
            ("SheetSession's saver unbound in the host", HOST, lambda s: s.replace("    Binding {\n        target: SheetSession\n        property: \"saverShown\"\n        value: idle.saverShown\n    }\n", "", 1)),
            ("SheetSession bound in idle", "shell/security/idle/Idle.qml", lambda s: s.replace("    IdleMonitor {\n        id: saverMonitor\n", "    Binding {\n        target: SheetSession\n        property: \"saverShown\"\n        value: false\n    }\n    IdleMonitor {\n        id: saverMonitor\n", 1)),
            # The opus review of S3, MINOR-2: code built from strings (M1, M2 are the reviewer's own).
            ("M1: a PolkitAgent built by createQmlObject in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property var extraAgent: Qt.createQmlObject(\"import Quickshell.Services.Polkit\\nPolkitAgent { path: \\\"/x\\\" }\", root)\n    Saver {\n", 1)),
            ("M2: a Loader of the agent's file in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Loader {\n        source: \"security/polkit/AuthAgent.qml\"\n    }\n    Saver {\n", 1)),
            ("a Loader with a computed source in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Loader {\n        source: \"sec\" + \"urity/polkit/AuthAgent.qml\"\n    }\n    Saver {\n", 1)),
            ("a LazyLoader with a source from a property in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    LazyLoader {\n        active: true\n        source: root.agentFile\n    }\n    Saver {\n", 1)),
            ("createComponent with a computed source in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property var made: Qt.createComponent(Quickshell.shellPath(\"x.qml\"))\n    Saver {\n", 1)),
            ("createComponent of the agent's file in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property var made: Qt.createComponent(\"security/polkit/AuthAgent.qml\")\n    Saver {\n", 1)),
            ("a security type named in a string of a UI script", "shell/services/LockClient.js", lambda s: s + "\nvar kind = \"SecretAgent\";\n"),
            ("the polkit module named in a string in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property string m: \"Quickshell.Services.Polkit\"\n    Saver {\n", 1)),
            ("a Loader of Qt.resolvedUrl of the agent's file in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Loader {\n        source: Qt.resolvedUrl(\"security/polkit/AuthAgent.qml\")\n    }\n    Saver {\n", 1)),
            ("a Loader of Qt.resolvedUrl of a computed file in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Loader {\n        source: Qt.resolvedUrl(\"sec\" + \"urity/polkit/AuthAgent.qml\")\n    }\n    Saver {\n", 1)),
            ("createComponent of Qt.resolvedUrl of a property in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property var made: Qt.createComponent(Qt.resolvedUrl(root.agentFile))\n    Saver {\n", 1)),
            ("a Loader of an https address in the UI (round 2, NIT)", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Loader {\n        source: \"https://example.invalid/security/polkit/AuthAgent.qml\"\n    }\n    Saver {\n", 1)),
            ("createComponent of Qt.resolvedUrl of an http address in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property var made: Qt.createComponent(Qt.resolvedUrl(\"HTTP://example.invalid/Thing.qml\"))\n    Saver {\n", 1)),
            ("a file: address of the agent in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property string f: \"file:///usr/share/grassfield/shell/security/polkit/AuthAgent.qml\"\n    Saver {\n", 1)),
            ("the widget registry returning a computed file", REGISTRY, lambda s: s.replace('            return Qt.resolvedUrl("builtin/clock/Clock.qml");', '            return Qt.resolvedUrl(id);', 1)),
            ("the widget registry returning a file outside builtin/", REGISTRY, lambda s: s.replace('            return Qt.resolvedUrl("builtin/clock/Clock.qml");', '            return Qt.resolvedUrl("../" + "Clock.qml");', 1)),
            ("another computed Loader source next to the allowed one", "shell/widgets/WidgetHost.qml", lambda s: s.replace("Registry.source(root.widgetId)", "Registry.source(root.widgetId + \"\")", 1)),
            ("M3: SheetSession open by default", "shell/security/SheetSession.qml", lambda s: s.replace("    property bool locked: true\n", "    property bool locked: false\n", 1).replace("    property bool displaysOff: true\n", "    property bool displaysOff: false\n", 1)),
            ("SheetSession's displays on by default", "shell/security/SheetSession.qml", lambda s: s.replace("    property bool displaysOff: true\n", "    property bool displaysOff: false\n", 1)),
            ("createQmlObject in Grassfield.Ui", "ui/Grassfield/Ui/Material.qml", lambda s: s.replace("import QtQuick.Effects\n", "import QtQuick.Effects\nimport Quickshell\n", 1).rstrip("\n").rstrip("}") + "    property var x: Qt.createQmlObject(\"import QtQuick\\nItem {}\", this)\n}\n"),
            ("a PolkitAgent in Grassfield.Ui", "ui/Grassfield/Ui/Material.qml", lambda s: s.replace("import QtQuick.Effects\n", "import QtQuick.Effects\nimport Quickshell.Services.Polkit\n", 1).rstrip("\n").rstrip("}") + "    PolkitAgent {\n    }\n}\n"),
            ("SheetSession assigned by the secret agent", "shell/security/secret/SecretAgent.qml", lambda s: s.replace("        root.serial++;\n", "        root.serial++;\n        SheetSession.locked = false;\n", 1)),
            ("the UI instantiating Idle", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Idle {\n    }\n    Saver {\n", 1)),
            ("the UI importing the idle module by path", "shell/saver/Saver.qml", lambda s: s.replace("import \"SaverModel.js\" as SaverModel\n", "import \"SaverModel.js\" as SaverModel\nimport \"../security/idle\"\n", 1)),
            ("a second Idle in the host", HOST, lambda s: s.replace("    Idle {\n        id: idle\n    }\n", "    Idle {\n        id: idle\n    }\n    Idle {\n    }\n", 1)),
            ("a window in the host", HOST, lambda s: s.replace("    Idle {\n", "    FloatingWindow {\n    }\n    Idle {\n", 1)),
            ("Popups in the lock", "shell/security/lock/Lock.qml", lambda s: s.replace("        writeMarker(\"locked\");\n        controller.requestLock();", "        Popups.close();\n        writeMarker(\"locked\");\n        controller.requestLock();", 1)),
            ("ThemeIcons in the lock", "shell/security/lock/Lock.qml", lambda s: s.replace("path => avatar.sourceOf(path)", "path => ThemeIcons.fileSource(path)", 1)),
            ("WallpaperState in the stills", "shell/security/lock/LockStill.qml", lambda s: s.replace("root.wallpaper ? root.wallpaper.lockBackdrop(root.output) : null", "WallpaperState.lockBackdrop(root.output)", 1)),
            ("Battery in idle", "shell/security/idle/Idle.qml", lambda s: s.replace("UPower.onBattery)", "Battery.onBattery)", 1)),
            ("the notification server in the inhibitor", "shell/security/idle/SleepInhibitor.qml", lambda s: s.replace("import qs.security.lock\n", "import qs.security.lock\nimport qs.notifications\n", 1)),
            ("the desktop in the lock view", "shell/security/lock/LockView.qml", lambda s: s.replace("import qs.security\n", "import qs.security\nimport qs.desktop\n", 1)),
            ("the state file's name spelled in the UI", "shell/services/LockClient.qml", lambda s: s.replace("readonly property string path:", "readonly property string other: \"grassfield-lock-state-x\"\n    readonly property string path:", 1)),
            ("the client not importing LockState.js", "shell/services/LockClient.qml", lambda s: s.replace('"../lib/LockState.js" as LockState', '"LockState.js" as LockState', 1)),
            ("the client writing the state file (setText)", CLIENT, lambda s: s.replace("        file.reload();\n", "        file.setText(\"{}\");\n        file.reload();\n", 1)),
            ("the client's FileView with atomicWrites", CLIENT, lambda s: s.replace("        watchChanges: true\n", "        watchChanges: true\n        atomicWrites: true\n", 1)),
            ("the client's FileView with blockWrites", CLIENT, lambda s: s.replace("        watchChanges: true\n", "        watchChanges: true\n        blockWrites: true\n", 1)),
            ("the client's FileView with an adapter", CLIENT, lambda s: s.replace("        watchChanges: true\n", "        watchChanges: true\n        adapter: JsonAdapter {}\n", 1)),
            ("the client removing the state file", CLIENT, lambda s: s.replace("    // ---- asking for a lock ----\n", "    Process {\n        command: [\"rm\", \"-f\", root.path]\n    }\n\n    // ---- asking for a lock ----\n", 1)),
            ("another UI file with the state file's path", "shell/saver/Saver.qml", lambda s: s.replace("import \"SaverModel.js\" as SaverModel\n", "import \"SaverModel.js\" as SaverModel\n", 1).replace("    Connections {\n        target: SessionState\n", "    FileView {\n        path: LockClient.path\n    }\n    Connections {\n        target: SessionState\n", 1)),
        ]
        for what, path, change in mutants:
            before = files[path]
            after = change(before)
            if after == before:
                print(f"FAIL: security process scan selftest: the mutant '{what}' does not apply to {path} (stale)")
                ok = False
                continue
            found = findings(dict(files, **{path: after}), singletons)
            print(("PASS: " if found else "FAIL: ") + f"security process scan selftest: {what} is found" + (f" ({found[0]})" if found else ""))
            ok = ok and bool(found)
        # What the rules allow (the opus delta review of S3, NIT): planted, none is a finding; M1 and M2 above still are.
        allowed = [
            ("a Loader of Qt.resolvedUrl(\"<a UI file>\") in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Loader {\n        source: Qt.resolvedUrl(\"saver/Saver.qml\")\n    }\n    Saver {\n", 1)),
            ("createComponent(Qt.resolvedUrl(\"<a UI file>\")) in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property var made: Qt.createComponent(Qt.resolvedUrl('saver/Saver.qml'))\n    Saver {\n", 1)),
            ("an https link whose path says security/ in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property string help: \"https://example.org/security/advisories\"\n    Saver {\n", 1)),
            ("an http link whose path says security/ in Grassfield.Ui", "ui/Grassfield/Ui/Material.qml", lambda s: s.rstrip("\n").rstrip("}") + "    property string help: \"http://example.org/security/\"\n}\n"),
        ]
        for what, path, change in allowed:
            before = files[path]
            after = change(before)
            if after == before:
                print(f"FAIL: security process scan selftest: the allowed case '{what}' does not apply to {path} (stale)")
                ok = False
                continue
            found = findings(dict(files, **{path: after}), singletons)
            print(("PASS: " if not found else "FAIL: ") + f"security process scan selftest: {what} is allowed" + (f" (found: {found[0]})" if found else ""))
            ok = ok and not found
        return 0 if ok else 1
    repo = argv[0]
    found = findings(tree(repo), services_singletons(repo))
    for f in found:
        print("security process scan: " + f)
    if not found:
        print("security process scan: ok")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
