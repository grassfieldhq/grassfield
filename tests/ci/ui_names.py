#!/usr/bin/env python3
"""No banned name in a user-visible string (docs/legal/visual-review.md section 3.1, master-prompt section 14).

  python3 -I tests/ci/ui_names.py            scan the tree, exit 1 on any hit
  python3 -I tests/ci/ui_names.py --selftest the scanner on fixed samples

A string is user-visible when it is the argument of qsTr/qsTranslate/QT_TR_NOOP/QT_TRANSLATE_NOOP/tr/translate in
shell/, ui/, apps/ (qml, js, cpp, h), a <source> or <translation> of translations/*.ts, or a Name/GenericName/Comment/
Keywords line of a .desktop file. Comments and internal identifiers are not scanned (D-13 renames those later).
Owner decisions of 2026-10-27: "Night Shift" and "Notification Center" never come back (the UI says "Night Light" and
"Notifications"); "Focus" stays allowed (owner decision, same day), so it is not in the list. Tiling step 6a (2026-10-29):
macOS's "Split View" is not shown either (the UI says Full Screen, Left of Screen, Right of Screen, Full Screen Tile; the
specs keep the name as the macOS reference). The rest of the list is the pattern of visual-review section 3.1. Exception:
`ui-names-ignore` on the line.
"""
import re
import subprocess
import sys
from pathlib import Path

BANNED = [
    "Finder", "Spotlight", "Mission Control", "Launchpad", "Stage Manager", "Quick Look", "Siri", "iCloud", "macOS",
    "Mac OS", "Apple", "Liquid Glass", "Tahoe", "Golden Gate", "AirDrop", "AirPlay", "Exposé", "Time Machine",
    "Handoff", "Sidecar", "FaceTime", "Safari", "Keychain", "Retina", "Touch ID", "Aqua", "Cupertino", "Sequoia",
    "Sonoma", "SF Pro", "SF Symbols", "San Francisco", "Night Shift", "True Tone", "Notification Center",
    "Dashboard", "Continuity", "Ventura", "Monterey", "Big Sur", "Catalina", "Mojave", "Split View",
    "Apple Intelligence", "Raycast",
]
# Whole words only. "Mac" is matched case-sensitively (the Mac, not a "MAC address").
PATTERN = re.compile(r"(?<!\w)(?:" + "|".join(re.escape(n) for n in BANNED) + r")(?!\w)", re.I)
MAC = re.compile(r"(?<!\w)Mac(?!\w)")
CALL = re.compile(
    r"\b(?:qsTr|qsTrId|QT_TR_NOOP|QT_TRANSLATE_NOOP|qsTranslate|tr|translate)\s*\(\s*((?:\"(?:[^\"\\]|\\.)*\"\s*,?\s*)+)")
STRING = re.compile(r"\"((?:[^\"\\]|\\.)*)\"")
TS_TEXT = re.compile(r"<(?:source|translation)[^>]*>([^<]*)</(?:source|translation)>")
DESKTOP = re.compile(r"^(?:Name|GenericName|Comment|Keywords)(?:\[[^\]]+\])?=(.*)$")
IGNORE = "ui-names-ignore"


def hits_in(text, kind):
    out = []
    for number, line in enumerate(text.splitlines(), 1):
        if IGNORE in line:
            continue
        if kind == "code":
            strings = [s for m in CALL.finditer(line) for s in STRING.findall(m.group(1))]
        elif kind == "ts":
            strings = TS_TEXT.findall(line)
        else:
            m = DESKTOP.match(line)
            strings = [m.group(1)] if m else []
        for s in strings:
            found = PATTERN.search(s) or MAC.search(s)
            if found:
                out.append((number, found.group(0), s))
    return out


def repo_root():
    return Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())


def classify(files):
    """(path, kind) of the files this check scans; paths are relative to the repository root."""
    for f in files:
        if f.startswith(("shell/", "ui/", "apps/")) and f.endswith((".qml", ".js", ".cpp", ".h")):
            yield f, "code"
        elif f.startswith("translations/") and f.endswith(".ts"):
            yield f, "ts"
        elif f.endswith(".desktop"):
            yield f, "desktop"


def tracked(root):
    return classify(subprocess.check_output(["git", "-C", str(root), "ls-files"], text=True).splitlines())


def scan(root, entries):
    """Returns (hits, files scanned); an empty scan is the caller's failure, never a pass."""
    bad = 0
    count = 0
    for rel, kind in entries:
        count += 1
        for number, word, s in hits_in((root / rel).read_text(encoding="utf-8", errors="replace"), kind):
            print(f"{rel}:{number}: banned name \"{word}\" in a visible string: {s}")
            bad += 1
    return bad, count


def selftest():
    cases = [
        ('text: qsTr("Night Shift")', "code", 1),
        ('text: qsTr("Notification Center")', "code", 1),
        ('x: QT_TRANSLATE_NOOP("B", "Show in Finder")', "code", 1),
        ('text: qsTr("Night Light")', "code", 0),
        ('text: qsTr("Focus")', "code", 0),
        ('text: qsTr("Notifications")', "code", 0),
        ('"Notification Center": QT_TRANSLATE_NOOP("B", "Notifications")', "code", 0),
        ('// the Notification Center (comment)', "code", 0),
        ('text: qsTr("Night Shift") // ui-names-ignore', "code", 0),
        ('text: qsTr("Machine")', "code", 0),
        ('text: qsTr("MAC address")', "code", 0),
        ('text: qsTr("Your Mac")', "code", 1),
        ('<source>Night Shift</source>', "ts", 1),
        ('<translation>Centre de notifications</translation>', "ts", 0),
        ('<translation>Notification Center</translation>', "ts", 1),
        ('Name[fr]=Aperçu', "desktop", 0),
        ('Comment=Like Spotlight', "desktop", 1),
        ('text: qsTr("Exit Split View")', "code", 1),
        ('text: qsTr("Left of Screen")', "code", 0),
        ('// a Split View Desktop (comment)', "code", 0),
        ('text: qsTr("Ask Apple Intelligence")', "code", 1),
        ('text: qsTr("Raycast script")', "code", 1),
        ('text: qsTr("Ask Local Model")', "code", 0),
    ]
    bad = [c for c in cases if len(hits_in(c[0], c[1])) != c[2]]
    for text, kind, want in bad:
        print(f"selftest FAIL ({kind}, want {want} hits): {text}")
    # Nothing to scan (a run from a subdirectory used to list no files) must fail, not pass.
    if run(Path("."), []) != 1:
        print("selftest FAIL: a scan of 0 files must exit 1")
        bad.append(("zero files", "", 1))
    if not bad:
        print(f"ui_names selftest: {len(cases)} cases ok")
    return 1 if bad else 0


def run(root, entries):
    bad, count = scan(root, entries)
    if count == 0:
        print("ui_names: 0 files scanned: the check found nothing to look at (wrong directory?)")
        return 1
    if bad:
        print(f"ui_names: {bad} banned name(s); see ADR-0003 and CONTRIBUTING.md, section Design rules")
        return 1
    print(f"ui_names: {count} files scanned, no banned name in a visible string")
    return 0


def main():
    if "--selftest" in sys.argv:
        return selftest()
    root = repo_root()
    return run(root, tracked(root))


sys.exit(main())
