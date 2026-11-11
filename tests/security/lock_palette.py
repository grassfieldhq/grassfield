#!/usr/bin/env python3
"""The lock draws the dark palette whatever the user's appearance (ADR-0041 S4; the delta opus review of b67472da, MINOR).

Since S4 the security host binds Appearance.dark to Settings.dark, so the polkit sheet, the secret sheets and the safe-mode
alert follow light and dark. The lock must not: on macOS the lock screen is the same dark one in both appearances, and its
white text is what gate A2 measures over the wallpaper. This check is an allowlist, read on the code (comments removed,
string contents blanked) of the files that draw the lock: shell/security/lock/*.qml and the shared
shell/security/PasswordField.qml, and idle's dim (shell/security/idle/IdleDim.qml: the dark shade before the lock).

  1. Appearance is read only as Appearance.<name> with <name> in ALLOWED_APPEARANCE (the dark palette, motion, fonts, the pure
     withAlpha); never bare (an alias, a parameter) and never another member (colors, highlight, buttonFill, inactiveFill,
     focusRingColor, ...). PasswordField alone may read Appearance.colors, and only as the default of the five colours the lock
     sets itself (rule 3).
  2. Tokens colours: only Tokens.colorDark.
  3. LockView reads its palette from Appearance.darkColors (`colors`), and its PasswordField gives every colour itself, from
     that palette, with no focus ring (the ring's colour follows the appearance).
  4. Each file instantiates only the types in ALLOWED_TYPES: the Grassfield.Ui parts whose default colours follow the
     appearance (Icon, Button, Material, FocusRing, TextField, ...) are not in it, but for PasswordField's own Icon and
     FocusRing, whose colours it sets (the field's text colour) or the lock turns off (the ring).

  python3 -I tests/security/lock_palette.py <repo>              "ok", or one line per finding and exit 1
  python3 -I tests/security/lock_palette.py --selftest <repo>   the tree is clean and each planted mutant is found
Standard library only."""
import glob
import os
import re
import sys

LOCK_DIR = "shell/security/lock"
FIELD = "shell/security/PasswordField.qml"
DIM = "shell/security/idle/IdleDim.qml"
VIEW = "shell/security/lock/LockView.qml"
ALLOWED_APPEARANCE = {"darkColors", "duration", "fontFamily", "fontFamilyFor", "reduceMotion", "trackingFor", "withAlpha"}
# PasswordField: the defaults of the five colours the lock gives itself (rule 3), and these only.
FIELD_DEFAULTS = ("textColor", "placeholderColor", "fillColor", "selectionColor", "selectedTextColor")
ALLOWED_TYPES = {
    "shell/security/lock/Lock.qml": {"Connections", "FileView", "Instantiator", "IpcHandler", "Item", "LockAvatar", "LockController",
                                     "LockPublisher", "LockView", "LockViewLoader", "PamContext", "PersistentProperties", "Singleton",
                                     "Timer", "WlSessionLock", "WlSessionLockSurface"},
    "shell/security/lock/LockView.qml": {"Column", "Gradient", "GradientStop", "GrassfieldArtwork", "Image", "Item", "MouseArea",
                                         "MultiEffect", "NumberAnimation", "PasswordField", "Rectangle", "SequentialAnimation", "Text",
                                         "TextShadow", "Timer", "WallClock"},
    "shell/security/lock/LockViewLoader.qml": {"Loader", "Timer"},
    "shell/security/lock/LockStills.qml": {"Image", "Item", "LockStill", "LockWallpaper", "Variants"},
    "shell/security/lock/LockStill.qml": {"Component", "Image", "Item", "Process", "StdioCollector", "Timer"},
    "shell/security/lock/LockAvatar.qml": {"Process", "Scope"},
    "shell/security/lock/LockPublisher.qml": {"FileView", "Scope", "Timer"},
    "shell/security/lock/LockWallpaper.qml": {"FileView", "Process", "Scope", "StdioCollector"},
    FIELD: {"FocusRing", "FocusScope", "Icon", "Item", "MouseArea", "QtObject", "Rectangle", "Text", "TextInput"},
    DIM: {"NumberAnimation", "PanelWindow", "Rectangle", "Region", "Scope", "Variants"},
}
_TOKENS = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'', re.S)


def code_of(src):
    def repl(m):
        t = m.group(0)
        if t.startswith("//"):
            return ""
        if t.startswith("/*"):
            return " "
        return t[0] + t[0]
    return _TOKENS.sub(repl, src)


def files_of(repo):
    out = {}
    for p in sorted(glob.glob(os.path.join(repo, LOCK_DIR, "*.qml"))) + [os.path.join(repo, FIELD), os.path.join(repo, DIM)]:
        out[os.path.relpath(p, repo)] = open(p, encoding="utf-8").read()
    return out


def findings(files):
    out = []
    for path, src in sorted(files.items()):
        code = code_of(src)
        # Rule 1: Appearance only as an allowed member.
        for m in re.finditer(r"\bAppearance\b(\s*\.\s*(\w+))?", code):
            name = m.group(2)
            line = code[:m.start()].count("\n") + 1
            text = code.splitlines()[line - 1].strip()
            if name is None:
                out.append(f"{path}:{line}: Appearance used bare ({text[:80]}): only Appearance.<allowed member>")
            elif name in ALLOWED_APPEARANCE:
                continue
            elif path == FIELD and name == "colors" and re.match(r"property color (" + "|".join(FIELD_DEFAULTS) + r"):", text):
                continue
            else:
                out.append(f"{path}:{line}: reads Appearance.{name}, which follows the user's appearance (the lock draws the dark palette only)")
        # Rule 2: no Tokens colour but the dark one.
        for m in re.finditer(r"\bTokens\s*\.\s*(color\w*)", code):
            if m.group(1) != "colorDark":
                out.append(f"{path}: reads Tokens.{m.group(1)} (only Tokens.colorDark on the lock)")
        # Rule 4: only the allowed types.
        allowed = ALLOWED_TYPES.get(path)
        types = set(re.findall(r"\b([A-Z]\w*)\s*\{", code))
        if allowed is None:
            out.append(f"{path}: a lock file this check does not know (add its types to ALLOWED_TYPES after a review)")
        elif types - allowed:
            out.append(f"{path}: instantiates {', '.join(sorted(types - allowed))} (allowed: {', '.join(sorted(allowed))}); a shared part "
                       "whose default colours follow the appearance draws light on the dark lock")
    # Rule 3: the view's palette and its field's colours.
    view = code_of(files.get(VIEW, ""))
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
    # PasswordField's own shared parts (rule 4): its Icon takes the field's text colour, its FocusRing shows only when the host
    # asks for it (the lock does not).
    fcode = code_of(files.get(FIELD, ""))
    icons = re.findall(r"\bIcon\s*\{([^{}]*)\}", fcode)
    if len(icons) != 1 or not re.search(r"^\s*color:\s*root\.textColor\s*$", icons[0], re.M):
        out.append(f"{FIELD}: its Icon does not take the field's text colour (an Icon's default follows the appearance)")
    rings = re.findall(r"\bFocusRing\s*\{([^{}]*)\}", fcode)
    if len(rings) != 1 or not re.search(r"^\s*visible:\s*root\.focusRing\s*&&", rings[0], re.M):
        out.append(f"{FIELD}: its FocusRing does not depend on focusRing (the ring's colour follows the appearance)")
    return out


def main(argv):
    if argv[:1] == ["--selftest"]:
        repo = argv[1]
        files = files_of(repo)
        base = findings(files)
        ok = not base
        print(("PASS" if ok else "FAIL") + ": lock palette selftest: the tree is clean" + ("" if ok else " [" + "; ".join(base) + "]"))
        anchor = "    component TextShadow: MultiEffect {"
        mutants = [
            ("an Icon in LockView (its glyph follows the appearance)", VIEW, lambda s: s.replace(anchor, "    Icon {\n        name: \"lock\"\n    }\n" + anchor, 1)),
            ("a Button in LockView", VIEW, lambda s: s.replace(anchor, "    Button {\n        text: \"x\"\n    }\n" + anchor, 1)),
            ("Appearance.highlight in LockView", VIEW, lambda s: s.replace(anchor, "    readonly property color probe: Appearance.highlight\n" + anchor, 1)),
            ("Appearance.colors in LockView", VIEW, lambda s: s.replace(anchor, "    readonly property color probe: Appearance.colors.text\n" + anchor, 1)),
            ("Appearance.buttonFill in LockView", VIEW, lambda s: s.replace(anchor, "    readonly property color probe: Appearance.buttonFill\n" + anchor, 1)),
            ("Appearance.iconTint in the stills", "shell/security/lock/LockStills.qml", lambda s: s.rstrip("\n").rstrip("}") + "    readonly property color probe: Appearance.iconTint\n}\n"),
            ("a Material in LockView", VIEW, lambda s: s.replace(anchor, "    Material {\n    }\n" + anchor, 1)),
            ("Appearance aliased in LockView", VIEW, lambda s: s.replace(anchor, "    readonly property var look: Appearance\n" + anchor, 1)),
            ("Appearance spelled with spaces in LockView", VIEW, lambda s: s.replace(anchor, "    readonly property color probe: Appearance . windowSecondary\n" + anchor, 1)),
            ("a light Tokens colour on the lock surface", "shell/security/lock/Lock.qml", lambda s: s.replace("Tokens.colorDark", "Tokens.colorLight", 1)),
            ("the view's palette following the appearance", VIEW, lambda s: s.replace("readonly property var colors: Appearance.darkColors", "readonly property var colors: Appearance.colors", 1)),
            ("the field's focus ring left on", VIEW, lambda s: s.replace("                focusRing: false\n", "", 1)),
            ("the field's text colour left to its default", VIEW, lambda s: s.replace("                textColor: root.colors.text\n", "", 1)),
            ("the field's selection left to its default", VIEW, lambda s: s.replace("                selectionColor: root.colors.accent\n", "", 1)),
            ("the field's default read from another member", FIELD, lambda s: s.replace("property color textColor: Appearance.colors.text", "property color textColor: Appearance.inactiveFill", 1)),
            ("Appearance.colors outside the field's defaults", FIELD, lambda s: s.rstrip("\n").rstrip("}") + "    readonly property color probe: Appearance.colors.text\n}\n"),
            ("the field's Icon left to its default colour", FIELD, lambda s: s.replace("            color: root.textColor\n", "", 1)),
            ("the field's FocusRing shown whatever the host asks", FIELD, lambda s: s.replace("visible: root.focusRing && input.activeFocus", "visible: input.activeFocus", 1)),
            ("the idle dim in the current palette", DIM, lambda s: s.replace("color: Tokens.colorDark.shadow", "color: Appearance.colors.shadow", 1)),
            ("a FocusRing in LockView", VIEW, lambda s: s.replace(anchor, "    FocusRing {\n    }\n" + anchor, 1)),
        ]
        for what, path, change in mutants:
            before = files[path]
            after = change(before)
            if after == before:
                print(f"FAIL: lock palette selftest: the mutant '{what}' does not apply to {path} (stale)")
                ok = False
                continue
            found = findings(dict(files, **{path: after}))
            print(("PASS" if found else "FAIL") + f": lock palette selftest: {what} is found" + (f" ({found[0]})" if found else ""))
            ok = ok and bool(found)
        return 0 if ok else 1
    found = findings(files_of(argv[0]))
    for f in found:
        print("lock palette: " + f)
    if not found:
        print("lock palette: ok")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
