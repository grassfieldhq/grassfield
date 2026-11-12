#!/usr/bin/env python3
"""The lock draws the dark palette whatever the user's appearance (ADR-0041 S4; the delta opus reviews of b67472da, MINOR,
and of 0edece99, MINOR-1 and NITs 1-3).

Since S4 the security host binds Appearance.dark to Settings.dark, so the polkit sheet, the secret sheets and the safe-mode
alert follow light and dark. The lock must not: on macOS the lock screen is the same dark one in both appearances, and its
white text is what gate A2 measures over the wallpaper. This check is an allowlist over every file that can draw on the lock
or compute what it draws: the closure of the roots (shell/security/lock/*.qml, the shared shell/security/PasswordField.qml
and idle's dim, shell/security/idle/IdleDim.qml) under
  - their file imports, QML (`import "x.js" as X`, `import "dir"`) and JavaScript (`.import "x.js" as X`), transitively;
  - the types they instantiate that are files of this tree (same directory, a quoted directory, or a qs.* or Grassfield.Ui
    module's qmldir: GrassfieldArtwork, WallClock, LockController, ...), transitively;
  - the JavaScript modules of an imported module's qmldir they use as a qualifier (WallpaperConfig, ...), transitively;
  - the file Lock.qml makes at run time (LockStills.qml, by its one Qt.createComponent).
Singletons are data and are not followed (Appearance and Tokens are what the rules below read). On each file of the closure,
code read with comments removed and string contents blanked:
  1. Appearance only as Appearance.<name>, <name> in ALLOWED_APPEARANCE (the dark palette, motion, fonts, the pure withAlpha),
     through any qualifier (`Ui.Appearance.colors` is refused too); never bare (an alias, a parameter), never subscripted.
     PasswordField alone may read Appearance.colors, and only as the whole default of one of the five colours the lock sets
     itself, one per statement (`property color textColor: Appearance.colors.text`), never two statements on one line.
  2. Tokens colours: only Tokens.colorDark; Tokens never subscripted (`Tokens["colorLight"]`).
  3. No Qt palette (`palette.windowText`: the unit's platform theme follows the desktop's appearance).
  4. No code built at run time: no createQmlObject; no Qt.createComponent but Lock.qml's one of LockStills.qml; no Loader or
     LazyLoader `source:`, no setSource(), no Loader's `.source =` (a `sourceComponent:` is an inline component, held to rule 5).
  5. Each QML file instantiates only the types in ALLOWED_TYPES (the Grassfield.Ui parts whose default colours follow the
     appearance, Icon, Button, Material, FocusRing, TextField, ..., are not there, but for PasswordField's own Icon and
     FocusRing, held below); a JavaScript file imports no module (`.import Grassfield.Ui as Ui` would reach Appearance).
  6. LockView reads its palette from Appearance.darkColors (`colors`), and its PasswordField gives every colour itself, from
     that palette, with no focus ring (the ring's colour follows the appearance); the field's own Icon takes its text colour
     and its FocusRing shows only when the host asks.

  python3 -I tests/security/lock_palette.py <repo>              "ok", or one line per finding and exit 1
  python3 -I tests/security/lock_palette.py --selftest <repo>   the tree is clean and each planted mutant is found
Standard library only."""
import glob
import os
import re
import sys

LOCK_DIR = "shell/security/lock"
FIELD = "shell/security/PasswordField.qml"
VIEW = "shell/security/lock/LockView.qml"
DIM = "shell/security/idle/IdleDim.qml"
LOCK = "shell/security/lock/Lock.qml"
ALLOWED_APPEARANCE = {"darkColors", "duration", "fontFamily", "fontFamilyFor", "reduceMotion", "trackingFor", "withAlpha"}
# PasswordField: the defaults of the five colours the lock gives itself (rule 6), and these only.
FIELD_DEFAULTS = ("textColor", "placeholderColor", "fillColor", "selectionColor", "selectedTextColor")
# PasswordField's own shared parts, whose colours rule 6 holds (the Icon takes the field's text colour, the FocusRing shows
# only when the host asks and the lock does not): not followed into Grassfield.Ui, whose defaults follow the appearance.
FIELD_HELD_PARTS = {"Icon", "FocusRing"}
# Lock.qml's one run-time creation (rule 4), followed into the closure.
ALLOWED_CREATE = {LOCK: ('Qt.createComponent(Qt.resolvedUrl("LockStills.qml"))', "shell/security/lock/LockStills.qml")}
ALLOWED_TYPES = {
    LOCK: {"Connections", "FileView", "Instantiator", "IpcHandler", "Item", "LockAvatar", "LockController", "LockPublisher", "LockView",
           "LockViewLoader", "PamContext", "PersistentProperties", "Singleton", "Timer", "WlSessionLock", "WlSessionLockSurface"},
    VIEW: {"Column", "Gradient", "GradientStop", "GrassfieldArtwork", "Image", "Item", "MouseArea", "MultiEffect", "NumberAnimation",
           "PasswordField", "Rectangle", "SequentialAnimation", "Text", "TextShadow", "Timer", "WallClock"},
    "shell/security/lock/LockViewLoader.qml": {"Loader", "Timer"},
    "shell/security/lock/LockStills.qml": {"Image", "Item", "LockStill", "LockWallpaper", "Variants"},
    "shell/security/lock/LockStill.qml": {"Component", "Image", "Item", "Process", "StdioCollector", "Timer"},
    "shell/security/lock/LockAvatar.qml": {"Process", "Scope"},
    "shell/security/lock/LockPublisher.qml": {"FileView", "Scope", "Timer"},
    "shell/security/lock/LockWallpaper.qml": {"FileView", "Process", "Scope", "StdioCollector"},
    FIELD: {"FocusRing", "FocusScope", "Icon", "Item", "MouseArea", "QtObject", "Rectangle", "Text", "TextInput"},
    DIM: {"NumberAnimation", "PanelWindow", "Rectangle", "Region", "Scope", "Variants"},
    "shell/security/LockController.qml": {"Connections", "Private", "QtObject", "Timer"},
    "ui/Grassfield/Ui/GrassfieldArtwork.qml": {"Gradient", "GradientStop", "Item", "PathAngleArc", "PathCubic", "PathLine", "PathSvg",
                                              "RadialGradient", "Rectangle", "Repeater", "Shape", "ShapePath", "Timer"},
    "shell/services/WallClock.qml": {"QtObject", "Timer"},
}
_TOKENS = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|`(?:\\.|[^`\\])*`', re.S)


def template_expressions(t):
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


def code_of(src, keep_strings=False):
    """The source with comments removed and string contents blanked (unless keep_strings); a template literal keeps the code
    of its ${...} expressions, read as code (the delta opus review of 00eff2bd, MINOR-C: `${Appearance.colors.text}` hid
    inside a blanked literal)."""
    def repl(m):
        t = m.group(0)
        if t.startswith("//"):
            return ""
        if t.startswith("/*"):
            return " " + "\n" * t.count("\n")
        if keep_strings:
            return t
        if t.startswith("`"):
            return "``" + "".join(" (" + code_of(e) + ")" for e in template_expressions(t))
        return t[0] + t[0]
    return _TOKENS.sub(repl, src)


def blocks(code, type_name):
    """The bodies of every `type_name {` block, brace matched (the delta opus review of 00eff2bd, MINOR-A: a regex without
    inner braces missed `Icon { anchors { ... } ... }`), each with its own top-level text (nested blocks removed)."""
    out = []
    for m in re.finditer(r"\b" + re.escape(type_name) + r"\s*\{", code):
        depth, end = 0, len(code)
        for j in range(m.end() - 1, len(code)):
            depth += {"{": 1, "}": -1}.get(code[j], 0)
            if depth == 0:
                end = j
                break
        body = code[m.end():end]
        own, prev = body, None
        while own != prev:
            prev, own = own, re.sub(r"\{[^{}]*\}", "", own)
        out.append((body, own))
    return out


def module_dir(name):
    """The directory of a module of this tree, or None (Qt, Quickshell: no file of ours)."""
    if name == "Grassfield.Ui":
        return "ui/Grassfield/Ui"
    if name.startswith("qs."):
        return "shell/" + name[3:].replace(".", "/")
    return None


def qmldir_entries(repo, d, files=None):
    """{name: (file, singleton)} of a module directory's qmldir (read through `files` when given: the selftest's mutants)."""
    out = {}
    rel = os.path.normpath(os.path.join(d, "qmldir"))
    text = read(repo, rel, files) if files is not None else (open(os.path.join(repo, rel), encoding="utf-8").read() if os.path.isfile(os.path.join(repo, rel)) else None)
    if text is None:
        return out
    for line in text.splitlines():
        m = re.match(r"^\s*(singleton\s+|internal\s+)?([A-Z]\w*)\s+(?:\d[\d.]*\s+)?(\S+\.(?:qml|js))\s*$", line)
        if m:
            out[m.group(2)] = (os.path.normpath(os.path.join(d, m.group(3))), (m.group(1) or "").strip() == "singleton")
    return out


def read(repo, rel, files):
    if rel not in files:
        p = os.path.join(repo, rel)
        files[rel] = open(p, encoding="utf-8").read() if os.path.isfile(p) else None
    return files[rel]


def closure(repo, files=None):
    """{relative path: source} of every file the lock can draw or compute with (see the module's text)."""
    files = {} if files is None else files
    roots = [os.path.relpath(p, repo) for p in sorted(glob.glob(os.path.join(repo, LOCK_DIR, "*.qml")))] + [FIELD, DIM]
    todo, seen, out = list(roots), set(), {}
    while todo:
        rel = os.path.normpath(todo.pop())
        if rel in seen:
            continue
        seen.add(rel)
        src = read(repo, rel, files)
        if src is None:
            out[rel] = None
            continue
        out[rel] = src
        here = os.path.dirname(rel)
        if rel.endswith(".js"):
            for path in re.findall(r'^\s*\.import\s+"([^"]+)"', src, re.M):
                todo.append(os.path.join(here, path))
            continue
        code = code_of(src)
        types = set(re.findall(r"\b([A-Z]\w*)\s*\{", code))
        if rel == FIELD:
            types -= FIELD_HELD_PARTS
        qualifiers = set(re.findall(r"\b([A-Z]\w*)\s*\.", code))
        # Quoted imports: a JavaScript file, or a directory whose files are types.
        scopes = [here]
        for path in re.findall(r'^\s*import\s+"([^"]+)"', src, re.M):
            target = os.path.normpath(os.path.join(here, path))
            if target.endswith(".js"):
                todo.append(target)
            else:
                scopes.append(target)
        for d in scopes:
            entries = qmldir_entries(repo, d, files)
            for t in types:
                if t in entries and not entries[t][1]:
                    f = entries[t][0]  # the engine follows the directory's qmldir, wherever it points
                else:
                    f = os.path.join(d, t + ".qml")
                if os.path.isfile(os.path.join(repo, f)) and os.path.normpath(f) != rel:
                    todo.append(f)
        # Module imports: their qmldir types (not singletons: data) and the JavaScript modules used as qualifiers.
        for mod in re.findall(r"^\s*import\s+([A-Za-z_][\w.]*)", src, re.M):
            d = module_dir(mod)
            if d is None:
                continue
            for name, (f, singleton) in qmldir_entries(repo, d, files).items():
                if f.endswith(".js") and name in qualifiers:
                    todo.append(f)
                elif f.endswith(".qml") and not singleton and name in types:
                    todo.append(f)
        made = ALLOWED_CREATE.get(rel)
        if made and made[0] in code_of(src, keep_strings=True):
            todo.append(made[1])
    return out


def statement_prefix(code, pos):
    """The text of the statement before `pos` (from the last newline, `;`, `{` or `}`)."""
    start = max(code.rfind(c, 0, pos) for c in "\n;{}") + 1
    return code[start:pos]


def findings(files, writers=None):
    out = []
    writers = writers or {}
    for path, src in sorted(files.items()):
        if src is None:
            out.append(f"{path}: imported or instantiated by the lock but not found")
            continue
        code = code_of(src)
        lines = code.split("\n")

        def where(pos):
            n = code[:pos].count("\n")
            return f"{path}:{n + 1}: {lines[n].strip()[:80]}"
        # Rule 1: Appearance only as an allowed member, never bare or subscripted.
        for m in re.finditer(r"\bAppearance\b(\s*\.\s*(\w+)|\s*\[)?", code):
            member = m.group(2)
            if m.group(1) is None:
                out.append(f"{where(m.start())}: Appearance used bare (only Appearance.<allowed member>)")
            elif member is None:
                out.append(f"{where(m.start())}: Appearance subscripted (only Appearance.<allowed member>)")
            elif member in ALLOWED_APPEARANCE:
                continue
            elif path == FIELD and member == "colors" and re.fullmatch(r"\s*property color (" + "|".join(FIELD_DEFAULTS) + r"):\s*(Appearance\.withAlpha\(\s*)?", statement_prefix(code, m.start())):
                continue
            else:
                out.append(f"{where(m.start())}: reads Appearance.{member}, which follows the user's appearance (the lock draws the dark palette only)")
        # Rule 2: no Tokens colour but the dark one, no subscript.
        for m in re.finditer(r"\bTokens\s*(\.\s*(color\w*)|\[)", code):
            if m.group(2) is None:
                out.append(f"{where(m.start())}: Tokens subscripted (only Tokens.<name>)")
            elif m.group(2) != "colorDark":
                out.append(f"{where(m.start())}: reads Tokens.{m.group(2)} (only Tokens.colorDark on the lock)")
        # Rule 3: no Qt palette (also bare: `pal: palette`), and nothing that says which appearance is chosen.
        # (QML only: a .pragma library script has no Item scope, so a `palette` there is its own name: Artwork.js's function.)
        for m in re.finditer(r"(?<![\w.])palette\b", code if path.endswith(".qml") else ""):
            out.append(f"{where(m.start())}: reads Qt's palette, which follows the platform theme's appearance")
        for m in re.finditer(r"\bSettings\s*\.\s*(dark|appearance)\b", code):
            out.append(f"{where(m.start())}: reads Settings.{m.group(1)}, the user's appearance")
        # Rule 4: no code built at run time.
        for m in re.finditer(r"\bcreateQmlObject\b", code):
            out.append(f"{where(m.start())}: builds QML from a string (createQmlObject)")
        for m in re.finditer(r"\bQt\s*\[", code):
            out.append(f"{where(m.start())}: Qt subscripted (Qt[\"createQmlObject\"] builds QML from a string)")
        allowed = ALLOWED_CREATE.get(path)
        with_strings = code_of(src, keep_strings=True)
        made = len(re.findall(r"\bcreateComponent\b", code))
        if made and not (allowed and made == 1 and with_strings.count(allowed[0]) == 1):
            out.append(f"{path}: Qt.createComponent (only Lock.qml's one of LockStills.qml)")
        for m in re.finditer(r"\bsetSource\s*\(", code):
            out.append(f"{where(m.start())}: setSource() (a Loader from a URL)")
        loader_ids = set()
        for m in re.finditer(r"\b(?:Lazy)?Loader\s*\{", code):
            depth, end = 0, len(code)
            for j in range(m.end() - 1, len(code)):
                depth += {"{": 1, "}": -1}.get(code[j], 0)
                if depth == 0:
                    end = j
                    break
            block = code[m.end():end]
            own = re.sub(r"\{[^{}]*\}", "", block)
            while own != (own := re.sub(r"\{[^{}]*\}", "", own)):
                pass
            if re.search(r"(^|[\s;])source\s*:", own):
                out.append(f"{where(m.start())}: a Loader with a source URL")
            idm = re.search(r"(^|[\s;])id\s*:\s*(\w+)", own)
            if idm:
                loader_ids.add(idm.group(2))
        if path.endswith(".qml") and re.match(r"\s*(?:pragma[^\n]*\n\s*|import[^\n]*\n\s*)*(?:Lazy)?Loader\s*\{", code):
            loader_ids.add("root")
        for lid in loader_ids:
            for m in re.finditer(r"\b" + lid + r"\s*\.\s*source\s*=(?!=)", code):
                out.append(f"{where(m.start())}: a Loader's source set to a URL")
        # Rule 5: types, and the JavaScript's imports.
        if path.endswith(".js"):
            for mod in re.findall(r"^\s*\.import\s+([A-Za-z_][\w.]*)", src, re.M):
                out.append(f"{path}: imports the module {mod} (a lock script imports files only)")
            continue
        types = set(re.findall(r"\b([A-Z]\w*)\s*\{", code))
        allowed_types = ALLOWED_TYPES.get(path)
        if allowed_types is None:
            out.append(f"{path}: a file the lock reaches that this check does not know (add its types to ALLOWED_TYPES after a review)")
        elif types - allowed_types:
            out.append(f"{path}: instantiates {', '.join(sorted(types - allowed_types))} (allowed: {', '.join(sorted(allowed_types))}); a shared part "
                       "whose default colours follow the appearance draws light on the dark lock")
    # Rule 6: the view's palette and its field's colours.
    view = code_of(files.get(VIEW) or "")
    if not re.search(r"^\s*readonly property var colors: Appearance\.darkColors\s*$", view, re.M):
        out.append(f"{VIEW}: its palette is not Appearance.darkColors")
    field = re.search(r"\bPasswordField\s*\{", view)
    if not field or len(re.findall(r"\bPasswordField\s*\{", view)) != 1:
        out.append(f"{VIEW}: not exactly one PasswordField")
    else:
        depth, i = 0, field.end() - 1
        for j in range(field.end() - 1, len(view)):
            depth += {"{": 1, "}": -1}.get(view[j], 0)
            if depth == 0:
                i = j
                break
        body = view[field.end():i]
        wanted = {"textColor": r"root\.colors\.text", "placeholderColor": r"root\.colors\.textSecondary",
                  "fillColor": r"Appearance\.withAlpha\(root\.colors\.shadow, Tokens\.lockFieldFillOpacity\)",
                  "selectionColor": r"root\.colors\.accent", "selectedTextColor": r"root\.colors\.accentText", "focusRing": r"false"}
        for prop, value in wanted.items():
            if not re.search(r"^\s*" + prop + r":\s*" + value + r"\s*$", body, re.M):
                out.append(f"{VIEW}: its PasswordField does not set {prop} to {value.replace(chr(92), '')} (the field's default follows the appearance)")
    fcode = code_of(files.get(FIELD) or "")
    icons = blocks(fcode, "Icon")
    if len(icons) != 1 or not re.search(r"^\s*color:\s*root\.textColor\s*$", icons[0][1], re.M):
        out.append(f"{FIELD}: not exactly one Icon, taking the field's text colour (an Icon's default follows the appearance)")
    rings = blocks(fcode, "FocusRing")
    if len(rings) != 1 or not re.search(r"^\s*visible:\s*root\.focusRing\s*&&", rings[0][1], re.M):
        out.append(f"{FIELD}: not exactly one FocusRing, shown only when the host asks (the ring's colour follows the appearance)")
    # Rule 7: nothing outside the lock writes an appearance into it (a Binding on Lock, or Lock.<property> = ...), from any
    # file of the security tree (Idle.qml and SecurityHost.qml write into Lock).
    for wpath, wsrc in sorted(writers.items()):
        wcode = code_of(wsrc)
        values = [b[1] for b in blocks(wcode, "Binding") if re.search(r"(^|[\s;])target\s*:\s*Lock\b", b[1])]
        values += [m.group(1) for m in re.finditer(r"\bLock\s*\.\s*\w+\s*=(?!=)([^;\n]*)", wcode)]
        for v in values:
            if re.search(r"\bAppearance\b|(?<![\w.])palette\b|\bSettings\s*\.\s*(dark|appearance)\b", v):
                out.append(f"{wpath}: writes an appearance into Lock ({v.strip()[:80]})")
    return out


def writers_of(repo, files, overrides=None):
    """The security tree's files outside the closure (they may write into Lock: rule 7)."""
    out = {}
    for p in sorted(glob.glob(os.path.join(repo, "shell/security/**/*.qml"), recursive=True)) + sorted(glob.glob(os.path.join(repo, "shell/security/**/*.js"), recursive=True)):
        rel = os.path.relpath(p, repo)
        if rel not in files:
            out[rel] = (overrides or {}).get(rel) or open(p, encoding="utf-8").read()
    return out


def main(argv):
    if argv[:1] == ["--selftest"]:
        repo = argv[1]
        base_files = {}
        files = closure(repo, base_files)
        base = findings(files, writers_of(repo, files))
        ok = not base
        print(("PASS" if ok else "FAIL") + ": lock palette selftest: the tree is clean (" + str(len(files)) + " files: " + ", ".join(sorted(files)) + ")"
              + ("" if ok else " [" + "; ".join(base) + "]"))
        anchor = "    component TextShadow: MultiEffect {"
        machine = "shell/security/LockMachine.js"
        mutants = [
            ("an Icon in LockView (its glyph follows the appearance)", {VIEW: lambda s: s.replace(anchor, "    Icon {\n        name: \"lock\"\n    }\n" + anchor, 1)}),
            ("a Button in LockView", {VIEW: lambda s: s.replace(anchor, "    Button {\n        text: \"x\"\n    }\n" + anchor, 1)}),
            ("Appearance.highlight in LockView", {VIEW: lambda s: s.replace(anchor, "    readonly property color probe: Appearance.highlight\n" + anchor, 1)}),
            ("Appearance.colors in LockView", {VIEW: lambda s: s.replace(anchor, "    readonly property color probe: Appearance.colors.text\n" + anchor, 1)}),
            ("Appearance.buttonFill in LockView", {VIEW: lambda s: s.replace(anchor, "    readonly property color probe: Appearance.buttonFill\n" + anchor, 1)}),
            ("Appearance.iconTint in the stills", {"shell/security/lock/LockStills.qml": lambda s: s.rstrip("\n").rstrip("}") + "    readonly property color probe: Appearance.iconTint\n}\n"}),
            ("a Material in LockView", {VIEW: lambda s: s.replace(anchor, "    Material {\n    }\n" + anchor, 1)}),
            ("Appearance aliased in LockView", {VIEW: lambda s: s.replace(anchor, "    readonly property var look: Appearance\n" + anchor, 1)}),
            ("Appearance spelled with spaces in LockView", {VIEW: lambda s: s.replace(anchor, "    readonly property color probe: Appearance . windowSecondary\n" + anchor, 1)}),
            ("a light Tokens colour on the lock surface", {LOCK: lambda s: s.replace("Tokens.colorDark", "Tokens.colorLight", 1)}),
            ("the view's palette following the appearance", {VIEW: lambda s: s.replace("readonly property var colors: Appearance.darkColors", "readonly property var colors: Appearance.colors", 1)}),
            ("the field's focus ring left on", {VIEW: lambda s: s.replace("                focusRing: false\n", "", 1)}),
            ("the field's text colour left to its default", {VIEW: lambda s: s.replace("                textColor: root.colors.text\n", "", 1)}),
            ("the field's selection left to its default", {VIEW: lambda s: s.replace("                selectionColor: root.colors.accent\n", "", 1)}),
            ("the field's default read from another member", {FIELD: lambda s: s.replace("property color textColor: Appearance.colors.text", "property color textColor: Appearance.inactiveFill", 1)}),
            ("Appearance.colors outside the field's defaults", {FIELD: lambda s: s.rstrip("\n").rstrip("}") + "    readonly property color probe: Appearance.colors.text\n}\n"}),
            ("the field's Icon left to its default colour", {FIELD: lambda s: s.replace("            color: root.textColor\n", "", 1)}),
            ("the field's FocusRing shown whatever the host asks", {FIELD: lambda s: s.replace("visible: root.focusRing && input.activeFocus", "visible: input.activeFocus", 1)}),
            ("the idle dim in the current palette", {DIM: lambda s: s.replace("color: Tokens.colorDark.shadow", "color: Appearance.colors.shadow", 1)}),
            ("a FocusRing in LockView", {VIEW: lambda s: s.replace(anchor, "    FocusRing {\n    }\n" + anchor, 1)}),
            # The delta opus review of 0edece99, MINOR-1: the JavaScript the lock imports, and an allowed type that draws.
            ("MINOR-1: LockMachine.js importing Grassfield.Ui and returning its palette, used by LockView",
             {machine: lambda s: s.replace(".pragma library\n", ".pragma library\n.import Grassfield.Ui as Ui\n", 1) + "\nfunction textColor() {\n    return Ui.Appearance.colors.text;\n}\n",
              VIEW: lambda s: s.replace("                textColor: root.colors.text\n", "                textColor: Machine.textColor()\n", 1)}),
            ("MINOR-1: LockMachine.js reading Appearance from a qualifier alone",
             {machine: lambda s: s + "\nfunction tint(ui) {\n    return ui.Appearance.colors.text;\n}\n"}),
            ("MINOR-1: a JavaScript file of the lock importing another that reads the palette",
             {machine: lambda s: s.replace(".pragma library\n", ".pragma library\n.import \"../lib/RunMode.js\" as RunModeAgain\n", 1),
              "shell/lib/RunMode.js": lambda s: s + "\nfunction probe(a) {\n    return a.Appearance.highlight;\n}\n"}),
            ("MINOR-1: GrassfieldArtwork (an allowed type that draws) reading the palette",
             {"ui/Grassfield/Ui/GrassfieldArtwork.qml": lambda s: s.replace("import QtQuick.Shapes\n", "import QtQuick.Shapes\nimport Grassfield.Ui\n", 1).rstrip("\n").rstrip("}") + "    readonly property color probe: Appearance.colors.text\n}\n"}),
            ("MINOR-1: GrassfieldArtwork instantiating an Icon", {"ui/Grassfield/Ui/GrassfieldArtwork.qml": lambda s: s.rstrip("\n").rstrip("}") + "    Icon {\n    }\n}\n"}),
            ("NIT-1: Qt's palette in LockView", {VIEW: lambda s: s.replace(anchor, "    readonly property color probe: palette.windowText\n" + anchor, 1)}),
            ("NIT-2: createQmlObject of an Icon in LockView", {VIEW: lambda s: s.replace(anchor, "    property var made: Qt.createQmlObject(\"import Grassfield.Ui; Icon {}\", root)\n" + anchor, 1)}),
            ("NIT-2: Qt.createComponent in LockView", {VIEW: lambda s: s.replace(anchor, "    property var made: Qt.createComponent(\"Other.qml\")\n" + anchor, 1)}),
            ("NIT-2: a Loader source URL in LockView", {VIEW: lambda s: s.replace(anchor, "    Loader {\n        source: \"Other.qml\"\n    }\n" + anchor, 1)}),
            ("NIT-2: the lock's view loader given a source URL", {"shell/security/lock/LockViewLoader.qml": lambda s: s.replace("        root.sourceComponent = view;\n", "        root.sourceComponent = view;\n        root.source = \"Other.qml\";\n", 1)}),
            ("NIT-2: setSource on the view loader", {"shell/security/lock/LockViewLoader.qml": lambda s: s.replace("        root.sourceComponent = view;\n", "        root.sourceComponent = view;\n        root.setSource(\"Other.qml\", {});\n", 1)}),
            ("NIT-3: Tokens subscripted", {LOCK: lambda s: s.replace("Tokens.colorDark", "Tokens[\"colorLight\"]", 1)}),
            ("NIT-3: Appearance subscripted", {VIEW: lambda s: s.replace(anchor, "    readonly property color probe: Appearance[\"colors\"].text\n" + anchor, 1)}),
            # The delta opus review of 00eff2bd: MINOR-A, MINOR-C and the NITs that passed.
            ("MINOR-A: a second Icon with a nested block in PasswordField", {FIELD: lambda s: s.rstrip("\n").rstrip("}") + "    Icon {\n        anchors {\n            left: parent.left\n        }\n        name: \"lock\"\n    }\n}\n"}),
            ("MINOR-A: the field's Icon colour hidden behind a nested block", {FIELD: lambda s: s.replace("            color: root.textColor\n", "            anchors {\n                centerIn: parent\n            }\n", 1)}),
            ("MINOR-C: a template literal reading the palette", {VIEW: lambda s: s.replace(anchor, "    readonly property color probe: `${Appearance.colors.text}`\n" + anchor, 1)}),
            ("MINOR-C: a template literal building QML", {VIEW: lambda s: s.replace(anchor, "    readonly property string probe: `${Qt.createQmlObject(\"import QtQuick; Item {}\", root)}`\n" + anchor, 1)}),
            ("NIT: Settings.dark in LockView", {VIEW: lambda s: s.replace(anchor, "    readonly property color probe: Settings.dark ? \"white\" : \"black\"\n" + anchor, 1)}),
            ("NIT: Qt's palette aliased", {VIEW: lambda s: s.replace(anchor, "    readonly property var pal: palette\n" + anchor, 1)}),
            ("NIT: Qt.createComponent named without a call", {VIEW: lambda s: s.replace(anchor, "    readonly property var make: Qt.createComponent\n" + anchor, 1)}),
            ("NIT: Qt subscripted", {VIEW: lambda s: s.replace(anchor, "    property var made: Qt[\"createQmlObject\"](\"import QtQuick; Item {}\", root)\n" + anchor, 1)}),
            ("NIT: the lock's qmldir mapping a type elsewhere", {"shell/security/lock/qmldir": lambda s: s.replace("LockStill 1.0 LockStill.qml", "LockStill 1.0 ../polkit/AuthDialog.qml", 1)}),
            ("NIT: SecurityHost writing an appearance into Lock", {"shell/security/host/SecurityHost.qml": lambda s: s.replace("    Binding {\n        target: Lock\n        property: \"authorizing\"", "    Binding {\n        target: Lock\n        property: \"fromDim\"\n        value: Appearance.dark\n    }\n    Binding {\n        target: Lock\n        property: \"authorizing\"", 1)}),
            ("NIT: Idle assigning an appearance into Lock", {"shell/security/idle/Idle.qml": lambda s: s.rstrip("\n").rstrip("}") + "    function probe(): void {\n        Lock.fromDim = Settings.dark;\n    }\n}\n"}),
            ("NIT-3: a second statement on the field's default line", {FIELD: lambda s: s.replace("property color textColor: Appearance.colors.text", "property color textColor: Appearance.colors.text; property color probe: Appearance.colors.danger", 1)}),
        ]
        for what, changes in mutants:
            mutated = dict(base_files)
            stale = False
            for path, change in changes.items():
                before = read(repo, path, mutated)
                after = change(before or "")
                if after == before:
                    stale = True
                mutated[path] = after
            if stale:
                print(f"FAIL: lock palette selftest: the mutant '{what}' does not apply (stale)")
                ok = False
                continue
            mfiles = closure(repo, mutated)
            found = findings(mfiles, writers_of(repo, mfiles, mutated))
            print(("PASS" if found else "FAIL") + f": lock palette selftest: {what} is found" + (f" ({found[0]})" if found else ""))
            ok = ok and bool(found)
        return 0 if ok else 1
    files = closure(argv[0])
    found = findings(files, writers_of(argv[0], files))
    for f in found:
        print("lock palette: " + f)
    if not found:
        print("lock palette: ok")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
