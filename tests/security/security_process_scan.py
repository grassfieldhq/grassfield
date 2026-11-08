#!/usr/bin/env python3
"""ADR-0041 step 1, S2: everything that locks lives in the security process, and nothing of the UI's world runs there.
Static (data layer), read on the code with comments and string contents removed:

  1. the UI tree (shell/** but shell/security/** and shell/security.qml) never imports qs.security.lock or qs.security.idle
     and never names the Lock singleton, Idle or SleepInhibitor: no `Lock.lock` caller is left in the UI, and referencing
     Lock there would start a second WlSessionLock and a second `lock` IPC target in the UI process;
  2. shell/security/SecurityHost.qml instantiates Idle exactly once (one idle module, one sleep inhibitor) and only the
     types listed in HOST_TYPES;
  3. the lock and idle modules (shell/security/lock/**, shell/security/idle/**, shell/security/SecurityHost.qml) import no
     UI feature module (qs.desktop, qs.notifications, ...) and name only the qs.services singletons in SERVICES_ALLOWED:
     the others start processes, own bus names, write files or empty directories the UI uses (Popups, ThemeIcons,
     WallpaperState, Battery's power profile, Notifications, MenuBridge, ...) and must not run a second time in the
     security process;
  4. shell/lib/LockState.js is the one definition of the state file: the publisher and LockClient import it by a relative
     path, and nothing else writes a file named grassfield-lock-state-*.

  python3 -I tests/security/security_process_scan.py <repo>             "ok" or one line per finding, exit 1
  python3 -I tests/security/security_process_scan.py --selftest <repo>   each planted mutant is found, the tree is clean
Standard library only."""
import os
import re
import sys

SERVICES_ALLOWED = {"Settings", "VisualFixtures", "FixedTime", "WallClock"}
HOST_TYPES = {"Scope", "Binding", "Idle"}
SECURITY_MODULES = ("shell/security/lock/", "shell/security/idle/")
HOST = "shell/security/SecurityHost.qml"


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
    for base in ("shell",):
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
    if ui:
        for m in mods:
            if m in ("qs.security.lock", "qs.security.idle"):
                out.append(f"{path}: imports {m} (the lock and idle run in the security process only)")
        for p in paths:
            if re.search(r"(^|/)security/(lock|idle)(/|$)", p):
                out.append(f"{path}: imports {p} (the lock and idle run in the security process only)")
        if re.search(r"\bLock\b", code) or re.search(r"\bIdle\s*\{", code) or re.search(r"\bSleepInhibitor\b", code):
            out.append(f"{path}: names the Lock singleton, Idle or SleepInhibitor (the UI asks the security process over IPC)")
        if path.endswith(".qml") and re.search(r"\bSecurityHost\s*\{", code):
            out.append(f"{path}: instantiates SecurityHost (shell/security.qml only)")
    if path.startswith(SECURITY_MODULES) or path == HOST:
        for m in mods:
            if m.startswith("qs.") and m not in ("qs.services", "qs.security", "qs.security.lock", "qs.security.idle"):
                out.append(f"{path}: imports {m} (a UI module in the security process)")
        used = set(re.findall(r"\b([A-Z]\w*)\s*\.", code)) | set(re.findall(r"\b([A-Z]\w*)\s*\{", code))
        for name in sorted((used & singletons) - SERVICES_ALLOWED):
            out.append(f"{path}: uses the qs.services type {name}, which must not run in the security process (allowed: {', '.join(sorted(SERVICES_ALLOWED))})")
    if "grassfield-lock-state-" in strip(src, keep_strings=True) and path != "shell/lib/LockState.js":
        out.append(f"{path}: spells the state file's name (shell/lib/LockState.js is its one definition)")
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
            ("the UI importing the lock module", "shell/shell.qml", lambda s: s.replace("import qs.security.polkit\n", "import qs.security.polkit\nimport qs.security.lock\n", 1)),
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
