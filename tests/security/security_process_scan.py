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
     as a Loader or createComponent source (QML from the network: round 2, NIT); strings are read decoded (JavaScript
     escapes: round 3, NIT-1);
  1d. the security tree (shell/security/**, shell/security.qml) calls no Qt.createQmlObject either (the delta opus review of
     0edece99, NIT-2);
  1c. in every file of shell/ and ui/, the security tree included (round 3, NIT-1): no import (QML `import "..."`, script
     `.import "..."`) and no literal Loader or createComponent source that is no file of this tree: an address with a
     scheme (http:, https:, data:, file:, qrc:, ...), an absolute path, or a relative path out of shell/ and ui/. The tree
     uses none today (shell/security makes SheetHost.qml and LockStills.qml by Qt.resolvedUrl of a relative literal);
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
     process with its path, and no other UI file names LockClient.path or LockState.filePath;
  6. safe mode (ADR-0041 S4) runs in the security process only: the host instantiates exactly one SafeMode, its inputs bound
     exactly from this process's lock and sheets (SAFE_MODE_INPUTS), and SafeMode.qml reads true for both until bound (the
     notice never shows on a default); the UI names no safe-mode type (SECURITY_NAMES, STRING_NAMES) and imports no
     qs.security.* module (rule 1); shell/security/safemode/ uses no qs.services type at all (rule 3).

  python3 -I tests/security/security_process_scan.py <repo>             "ok" or one line per finding, exit 1
  python3 -I tests/security/security_process_scan.py --selftest <repo>   each planted mutant is found, the tree is clean
Standard library only."""
import os
import re
import sys

SERVICES_ALLOWED = {"Settings", "VisualFixtures", "FixedTime", "WallClock"}
HOST_TYPES = {"Scope", "Binding", "Idle", "SafeMode"}
SHEET_HOST = "shell/security/host/SheetHost.qml"
SHEET_HOST_TYPES = {"Scope", "SheetQueue", "AuthAgent", "SecretAgent", "FileView"}
# Exactly once in SheetHost.qml each.
SHEET_HOST_ONCE = ("AuthAgent", "SecretAgent", "SheetQueue")
SHEET_HOST_URL = 'Qt.createComponent(Qt.resolvedUrl("SheetHost.qml"))'
SECURITY_MODULES = ("shell/security/lock/", "shell/security/idle/", "shell/security/polkit/", "shell/security/secret/",
                    "shell/security/safemode/")
# The sheets: no qs.services type at all (S3).
SHEET_MODULES = ("shell/security/polkit/", "shell/security/secret/")
# Safe mode (ADR-0041 S4): no qs.services type either; it reads the lock and the sheets through the host's bindings only.
SAFE_MODE_MODULE = "shell/security/safemode/"
SAFE_MODE = "shell/security/safemode/SafeMode.qml"
# The host's one SafeMode and what each input is bound to (rule 6).
SAFE_MODE_INPUTS = {"locked": "Lock.locked || Lock.strandedProbing || Lock.publicState !== \"unlocked\"",
                    "sheetUp": "root.sheets !== null && (root.sheets.authorizing === true || root.sheets.securityKeyboard === true)",
                    "displaysOff": "idle.displayOff"}
SECURITY_SHARED = ("shell/security/SheetQueue.qml", "shell/security/SheetSession.qml", "shell/security/PasswordField.qml",
                   "shell/security/LockController.qml")
AGENT = "shell/security/polkit/AuthAgent.qml"
# Named nowhere in the UI (rule 1).
SECURITY_NAMES = ("Lock", "SleepInhibitor", "AuthAgent", "SecretAgent", "SheetQueue", "SheetSession", "PrompterClient",
                  "PolkitAgent", "SafeMode", "SafeModeNotice", "SafeModeCard")
# SheetSession's one writer and what each property is bound to (rule 3c).
SHEET_BINDINGS = {"locked": "Lock.locked || Lock.strandedProbing", "displaysOff": "idle.displayOff", "saverShown": "idle.saverShown",
                  "starting": "idle.starting", "sleeping": "idle.sleeping"}
HOST = "shell/security/host/SecurityHost.qml"
# Rule 1b: what no string of the UI tree or of ui/ may name (a security path, the polkit module, a security type).
STRING_NAMES = re.compile(r"security/|qs\.security|Quickshell\.Services\.Polkit|\b(?:PolkitAgent|AuthAgent|SecretAgent|PrompterClient"
                          r"|SheetHost|SheetSession|SheetQueue|SecurityHost|SafeMode|SafeModeNotice|SafeModeCard)\b")
_STRING = re.compile(r'"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|`(?:\\.|[^`\\])*`', re.S)
# The one computed Loader source of the UI tree, allowed only while its function returns plain literals (global_findings).
ALLOWED_COMPUTED = {("shell/widgets/WidgetHost.qml", "Registry.source(root.widgetId)")}
REGISTRY = "shell/widgets/Registry.qml"
_LITERAL = re.compile(r'^\s*("(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\')\s*;?\s*$')
# A source that is one plain literal resolved against the file (the opus delta review of S3, NIT): as readable as the literal,
# which the string rule still reads.
_RESOLVED_LITERAL = re.compile(r'^\s*Qt\.resolvedUrl\(\s*("(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\')\s*\)\s*;?\s*$')
# A web address (http or https, any case), read on a string's decoded value: it names no file of the tree, whatever its path
# says (the same NIT). The exception is for plain strings only, never for a source or an import.
_WEB_URL = re.compile(r'^https?://', re.I)
# JavaScript string escapes, decoded before a string is read (the opus review of S3, round 3, NIT-1: "\x68ttps://...",
# "\u0068ttps://..." or "secu\x72ity/..." are read as what the engine makes of them).
_JS_ESCAPE = re.compile(r"\\(x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]{1,6}\}|u[0-9a-fA-F]{4}|[0-7]{1,3}|\r\n|[\s\S])")
_SIMPLE_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "v": "\v"}
# A target with a scheme (http:, https:, file:, data:, qrc:, ...).
_SCHEME = re.compile(r"^\s*[A-Za-z][A-Za-z0-9+.\-]*:")


def js_unescape(body):
    """The value of a JavaScript string literal's body."""
    def one(m):
        e = m.group(1)
        if e[0] == "x" and len(e) == 3:
            return chr(int(e[1:], 16))
        if e.startswith("u{"):
            return chr(min(int(e[2:-1], 16), 0x10FFFF))
        if e[0] == "u" and len(e) == 5:
            return chr(int(e[1:], 16))
        if e[0] in "01234567":
            return chr(int(e, 8))
        if e in ("\n", "\r", "\r\n", "\u2028", "\u2029"):
            return ""
        return _SIMPLE_ESCAPES.get(e, e)
    return _JS_ESCAPE.sub(one, body)


def string_value(literal):
    """The decoded value of a quoted literal (its quotes included)."""
    return js_unescape(literal[1:-1])


def foreign_target(path, value):
    """Why `value`, a source or an import named in the file `path`, is no file of this tree ("" when it is one): an address
    with a scheme (the network, data:, file:, ...), an absolute path, or a relative one that leaves shell/ and ui/ (the opus
    review of S3, round 3, NIT-1: such code is read by no scan of the tree)."""
    v = value.strip()
    if _SCHEME.match(v):
        return "an address with a scheme (" + v.split(":", 1)[0] + ":)"
    if v.startswith(("/", "~", "\\")):
        return "an absolute path"
    target = os.path.normpath(os.path.join(os.path.dirname(path), v))
    if not (target in ("shell", "ui") or target.startswith(("shell" + os.sep, "ui" + os.sep))):
        return "a path outside the tree"
    return ""


def source_problem(path, text):
    """Why a Loader or createComponent source cannot be checked ("" when it can): it must be one plain string literal or
    Qt.resolvedUrl of one, naming a file of this tree."""
    m = _LITERAL.match(text) or _RESOLVED_LITERAL.match(text)
    if not m:
        return "a computed source: only one plain string literal (or Qt.resolvedUrl of one) can be checked"
    why = foreign_target(path, string_value(m.group(1)))
    return why and why + ": only a file of this tree can be checked"


def sources_of(with_strings):
    """("createComponent" | "Loader", the source's text) for each createComponent call and Loader/LazyLoader source."""
    for m in re.finditer(r"\bcreateComponent\s*\(", with_strings):
        depth, i = 1, m.end()
        while i < len(with_strings) and depth:
            depth += {"(": 1, ")": -1}.get(with_strings[i], 0)
            i += 1
        yield "createComponent", with_strings[m.end():i - 1]
    for m in re.finditer(r"\b(?:Lazy)?Loader\s*\{", with_strings):
        depth, i = 0, m.end() - 1
        for j in range(m.end() - 1, len(with_strings)):
            depth += {"{": 1, "}": -1}.get(with_strings[j], 0)
            if depth == 0:
                i = j + 1
                break
        own = top_level(with_strings[m.end() - 1:i])
        for s in re.finditer(r"(?:^|[\s;{])source\s*:\s*([^\n;}]*)", own):
            yield "Loader", s.group(1)


def foreign_code(path, src, paths):
    """Every file of shell/ and ui/ (the security tree included): no import, and no literal Loader or createComponent source,
    that is no file of this tree (round 3, NIT-1)."""
    out = []
    for p in paths:
        why = foreign_target(path, js_unescape(p))
        if why:
            out.append(f"{path}: imports \"{p[:60]}\", {why} (code no scan of this tree reads)")
    for kind, text in sources_of(strip(src, keep_strings=True)):
        m = _LITERAL.match(text) or _RESOLVED_LITERAL.match(text)
        why = foreign_target(path, string_value(m.group(1))) if m else ""
        if why:
            out.append(f"{path}: a {kind} source ({text.strip()[:60]}) is {why} (code no scan of this tree reads)")
    return out


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
    for kind, text in sources_of(with_strings):
        if kind == "Loader" and (path, text.strip()) in ALLOWED_COMPUTED:
            continue
        why = source_problem(path, text)
        if why:
            out.append(f"{path}: a {kind} source ({text.strip()[:60]}): {why}")
    for s in _STRING.finditer(with_strings):
        value = string_value(s.group(0))
        if STRING_NAMES.search(value) and not _WEB_URL.match(value):
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


def _template_expressions(t):
    """The ${...} expressions of a template literal (its backticks included), brace matched."""
    out, i = [], 1
    while i < len(t) - 1:
        if t[i] == "\\":
            i += 2
            continue
        if t.startswith("${", i):
            depth, j = 0, i + 1
            while j < len(t):
                depth += {"{": 1, "}": -1}.get(t[j], 0)
                if depth == 0:
                    break
                j += 1
            out.append(t[i + 2:j])
            i = j + 1
            continue
        i += 1
    return out


def _strip(src, keep_strings):
    """Comments removed; string contents blanked unless keep_strings; a template literal keeps the code of its ${...}
    expressions, read as code (the delta opus review of 00eff2bd, MINOR-C: `${Qt.createQmlObject(...)}` hid inside a blanked
    literal)."""
    def repl(m):
        t = m.group(0)
        if t.startswith("//"):
            return ""
        if t.startswith("/*"):
            return " "
        if keep_strings:
            return t
        if t.startswith("`"):
            return "``" + "".join(" (" + _strip(e, False) + ")" for e in _template_expressions(t))
        return t[0] + t[0]
    return _TOKENS.sub(repl, src)


def imports_of(src):
    """The QML imports (module names and quoted paths) of a file, from its raw text (import lines are not in comments)."""
    mods = re.findall(r"^\s*import\s+([A-Za-z_][\w.]*)", src, re.M)
    paths = re.findall(r"^\s*\.?import\s+\"([^\"]+)\"", src, re.M)
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
    # The security tree builds no QML from a string either (the delta opus review of 0edece99, NIT-2): code no scan reads.
    if (path.startswith("shell/security/") or path == "shell/security.qml") and re.search(r"\bcreateQmlObject\b", code):
        out.append(f"{path}: calls createQmlObject (code built from a string cannot be checked)")
    out += foreign_code(path, src, paths)
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
            if m.startswith("qs.") and m not in ("qs.services", "qs.security", "qs.security.lock", "qs.security.idle", "qs.security.polkit", "qs.security.secret",
                                                  "qs.security.safemode"):
                out.append(f"{path}: imports {m} (a UI module in the security process)")
            if m == "qs.security.safemode" and path != HOST:
                out.append(f"{path}: imports qs.security.safemode (the host makes the one SafeMode; the opus review of a0df9c3e, NIT)")
        used = set(re.findall(r"\b([A-Z]\w*)\s*\.", code)) | set(re.findall(r"\b([A-Z]\w*)\s*\{", code))
        sheets = path.startswith(SHEET_MODULES) or path in SECURITY_SHARED or path == SHEET_HOST
        safe_mode = path.startswith(SAFE_MODE_MODULE)
        allowed = set() if sheets or safe_mode else SERVICES_ALLOWED
        for name in sorted((used & singletons) - allowed):
            out.append(f"{path}: uses the qs.services type {name}, which must not run in the security process (allowed here: {', '.join(sorted(allowed)) or 'none'})")
        if sheets and "qs.services" in mods:
            out.append(f"{path}: imports qs.services (the sheets read the session from SheetSession only, ADR-0041 S3)")
        if safe_mode and "qs.services" in mods:
            out.append(f"{path}: imports qs.services (safe mode reads the lock and the sheets from the host's bindings only, ADR-0041 S4)")
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
        # Rule 6: one SafeMode, its two inputs bound exactly from this process's lock and sheets, nothing else set on it.
        safe = re.findall(r"\bSafeMode\s*\{([^{}]*)\}", strip(host, keep_strings=True))
        given = dict(re.findall(r"^\s*(\w+)\s*:\s*(.*?)\s*$", safe[0], re.M)) if len(safe) == 1 else {}
        if len(re.findall(r"\bSafeMode\s*\{", code)) != 1 or given != SAFE_MODE_INPUTS:
            out.append(f"{HOST}: not exactly one SafeMode bound as {SAFE_MODE_INPUTS} (safe mode reads the lock and the sheets of this process)")
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
    safe_mode = strip(files.get(SAFE_MODE, ""))
    if not (re.search(r"^\s*property bool locked:\s*true\s*$", safe_mode, re.M) and re.search(r"^\s*property bool sheetUp:\s*true\s*$", safe_mode, re.M)
            and re.search(r"^\s*property bool displaysOff:\s*true\s*$", safe_mode, re.M)):
        out.append(f"{SAFE_MODE}: does not fail closed until bound (locked: true, sheetUp: true, displaysOff: true)")
    for path, src in files.items():
        if path != HOST and not path.startswith(SAFE_MODE_MODULE) and re.search(r"\bSafeMode\s*\{", strip(src)):
            out.append(f"{path}: instantiates SafeMode (the host does, once)")
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
            # Round 3, NIT-1: escapes decoded, other schemes, absolute paths and paths out of the tree, remote imports.
            ("a Loader of an https address in \\u escapes in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Loader {\n        source: \"\\u0068ttps://example.invalid/x.qml\"\n    }\n    Saver {\n", 1)),
            ("createComponent of an http address in \\x escapes in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property var made: Qt.createComponent(\"\\x68ttp://example.invalid/x.qml\")\n    Saver {\n", 1)),
            ("a Loader of a data: address in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Loader {\n        source: \"data:text/plain,Item {}\"\n    }\n    Saver {\n", 1)),
            ("a Loader of a file:///tmp address in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Loader {\n        source: \"file:///tmp/x.qml\"\n    }\n    Saver {\n", 1)),
            ("createComponent of /tmp in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property var made: Qt.createComponent(\"/tmp/x.qml\")\n    Saver {\n", 1)),
            ("a Loader of Qt.resolvedUrl of a path out of the tree in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    Loader {\n        source: Qt.resolvedUrl(\"../../../../tmp/x.qml\")\n    }\n    Saver {\n", 1)),
            ("a remote import in the UI", "shell/shell.qml", lambda s: s.replace("import qs.services\n", "import qs.services\nimport \"https://example.invalid/mod\"\n", 1)),
            ("a remote .import in a UI script", "shell/dock/Geometry.js", lambda s: s.replace(".import \"Magnify.js\" as Magnify\n", ".import \"Magnify.js\" as Magnify\n.import \"https://example.invalid/x.js\" as X\n", 1)),
            ("an import of /tmp in the lock view", "shell/security/lock/LockView.qml", lambda s: s.replace("import \"../LockMachine.js\" as Machine\n", "import \"../LockMachine.js\" as Machine\nimport \"/tmp/mod\"\n", 1)),
            ("a Loader of file:///tmp in the lock view", "shell/security/lock/LockView.qml", lambda s: s.rstrip("\n").rstrip("}") + "    Loader {\n        source: \"file:///tmp/x.qml\"\n    }\n}\n"),
            ("a security path in \\x escapes in a UI string", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property string m: \"secu\\x72ity/polkit/AuthAgent.qml\"\n    Saver {\n", 1)),
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
            # ADR-0041 S4: safe mode, in the security process only, bound from its own lock and sheets.
            ("createQmlObject in the lock view (NIT-2 of the review of 0edece99)", "shell/security/lock/LockView.qml", lambda s: s.replace("    component TextShadow: MultiEffect {", "    property var made: Qt.createQmlObject(\"import QtQuick; Item {}\", root)\n    component TextShadow: MultiEffect {", 1)),
            ("createQmlObject in a template literal of the lock view (MINOR-C of the review of 00eff2bd)", "shell/security/lock/LockView.qml", lambda s: s.replace("    component TextShadow: MultiEffect {", "    readonly property string made: `${Qt.createQmlObject(\"import QtQuick; Item {}\", root)}`\n    component TextShadow: MultiEffect {", 1)),
            ("createQmlObject in a template literal of the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    readonly property string made: `x${Qt.createQmlObject(\"import QtQuick; Item {}\", root)}y`\n    Saver {\n", 1)),
            ("createQmlObject in the safe-mode notice", "shell/security/safemode/SafeModeCard.qml", lambda s: s.replace("    signal tryAgain\n", "    signal tryAgain\n    property var made: Qt.createQmlObject(\"import QtQuick; Item {}\", root)\n", 1)),
            ("a second SafeMode in the host", HOST, lambda s: s.replace("    // The state and the beat for `security heartbeat`", "    SafeMode {\n        locked: Lock.locked || Lock.strandedProbing || Lock.publicState !== \"unlocked\"\n        sheetUp: root.sheets !== null && (root.sheets.authorizing === true || root.sheets.securityKeyboard === true)\n    }\n    // The state and the beat for `security heartbeat`", 1)),
            ("SafeMode's lock input bound to a constant in the host", HOST, lambda s: s.replace("        locked: Lock.locked || Lock.strandedProbing || Lock.publicState !== \"unlocked\"\n", "        locked: false\n", 1)),
            ("SafeMode's lock input without the asked-for lock (locking)", HOST, lambda s: s.replace("        locked: Lock.locked || Lock.strandedProbing || Lock.publicState !== \"unlocked\"\n", "        locked: Lock.locked || Lock.strandedProbing\n", 1)),
            ("SafeMode's sheet input without the key sink", HOST, lambda s: s.replace("(root.sheets.authorizing === true || root.sheets.securityKeyboard === true)", "root.sheets.authorizing === true", 1)),
            ("SafeMode's inputs left unbound in the host", HOST, lambda s: s.replace("        sheetUp: root.sheets !== null && (root.sheets.authorizing === true || root.sheets.securityKeyboard === true)\n", "", 1)),
            ("SafeMode open by default (locked)", SAFE_MODE, lambda s: s.replace("    property bool locked: true\n", "    property bool locked: false\n", 1)),
            ("SafeMode open by default (displaysOff)", SAFE_MODE, lambda s: s.replace("    property bool displaysOff: true\n", "    property bool displaysOff: false\n", 1)),
            ("SafeMode's displays left unbound in the host (MINOR-2)", HOST, lambda s: s.replace("        displaysOff: idle.displayOff\n", "", 1)),
            ("SafeMode's displays bound to a constant in the host", HOST, lambda s: s.replace("        displaysOff: idle.displayOff\n", "        displaysOff: false\n", 1)),
            ("idle importing the safe-mode module (only the host does: NIT)", "shell/security/idle/Idle.qml", lambda s: s.replace("import qs.security.lock\n", "import qs.security.lock\nimport qs.security.safemode\n", 1)),
            ("SafeMode open by default (sheetUp)", SAFE_MODE, lambda s: s.replace("    property bool sheetUp: true\n", "    property bool sheetUp: false\n", 1)),
            ("SafeMode in the UI", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    SafeMode {\n    }\n    Saver {\n", 1)),
            ("the UI importing the safe-mode module", "shell/shell.qml", lambda s: s.replace("import qs.services\n", "import qs.services\nimport qs.security.safemode\n", 1)),
            ("SafeMode made in the lock", "shell/security/lock/LockView.qml", lambda s: s.rstrip("\n").rstrip("}") + "    SafeMode {\n    }\n}\n"),
            ("safe mode importing qs.services", SAFE_MODE, lambda s: s.replace("import Quickshell.Io\n", "import Quickshell.Io\nimport qs.services\n", 1)),
            ("safe mode reading the UI's SessionState", SAFE_MODE, lambda s: s.replace("    readonly property bool shown: Model.shown(root.confirmed, root.locked, root.sheetUp, root.displaysOff)", "    readonly property bool shown: Model.shown(root.confirmed, SessionState.locked, root.sheetUp, root.displaysOff)", 1)),
            ("Settings in the safe-mode notice", "shell/security/safemode/SafeModeCard.qml", lambda s: s.replace("    readonly property bool busy: root.running !== \"\"\n", "    readonly property bool busy: root.running !== \"\" || Settings.reduceMotion\n", 1)),
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
            ("createComponent of a UI file spelled with escapes", "shell/shell.qml", lambda s: s.replace("    Saver {\n", "    property var made: Qt.createComponent(\"saver/S\\x61ver.qml\")\n    Saver {\n", 1)),
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
