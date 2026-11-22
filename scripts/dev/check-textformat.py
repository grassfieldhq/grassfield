#!/usr/bin/env python3
"""Guard against rich-text injection: every QML `Text {` block in shell/, ui/ and apps/ must set `textFormat`.

Untrusted strings (app ids, titles, desktop entries, SSIDs, notification fields) rendered as rich text can
spoof UI or fetch remote resources. `Text.StyledText`/`Text.RichText` are allowed only in ALLOW. A `TextEdit` is plain
text by default; `TextEdit.RichText`, `TextEdit.MarkdownText` and `TextEdit.AutoText`, and a `textFormat` set to the same
values through the `Text.` enum (`TextEdit { textFormat: Text.RichText }`, `edit.textFormat = Text.MarkdownText`) or as a
number other than 0 (`textFormat: 1`), are allowed only in ALLOW_EDIT.
Usage: check-textformat.py   (exit 1 on violations)
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
# file → reason; only the sanitized notification body may use StyledText.
ALLOW = {"shell/notifications/NotificationContent.qml": "sanitized body (Sanitizer.js) rendered as StyledText"}
# file -> reason for a rich TextEdit.
ALLOW_EDIT = {
    "apps/memos/qml/MemoWindow.qml": "the memo editor: the user's own formatted text (ADR-0051)",
    "apps/preview/qml/TextView.qml": "a Markdown document rendered by Qt's reader with raw HTML off, pictures only from "
                                     "Preview's image provider (previewlogic markdownHtml, docs/specs/preview.md P5)",
}
# Either spelling of a rich format: the TextEdit enum anywhere, or a textFormat binding or assignment through the Text enum
# (both enums share the values; review 2026-11-22: `TextEdit { textFormat: Text.RichText }` passed). Text.StyledText stays
# the `Text {` block check's (a TextEdit has no styled text). A number other than 0 (PlainText) is a format too: 1 RichText,
# 2 AutoText, 3 MarkdownText, 4 StyledText (re-review 2026-11-22: `textFormat: 1` passed), in decimal or hexadecimal.
RICH_EDIT = re.compile(r"TextEdit\.(?:RichText|MarkdownText|AutoText)\b"
                       r"|textFormat\s*[:=]\s*Text\.(?:RichText|MarkdownText|AutoText)\b"
                       r"|textFormat\s*[:=]\s*\(?\s*(?:0[xX]0*[1-9a-fA-F][0-9a-fA-F]*|0*[1-9]\d*)\b")
OPEN = re.compile(r"(^|[^\w.])Text\s*\{")


def blocks(src):
    """Yield (line, body) for each `Text {` block, matching braces."""
    for m in OPEN.finditer(src):
        start = m.end()
        depth, i = 1, start
        while i < len(src) and depth:
            depth += {"{": 1, "}": -1}.get(src[i], 0)
            i += 1
        body = src[start:i - 1]
        # Only the block's own properties: drop nested child objects.
        own, d = [], 0
        for ch in body:
            if ch == "{":
                d += 1
            elif ch == "}":
                d -= 1
            elif d == 0:
                own.append(ch)
        yield src.count("\n", 0, m.start()) + 1, "".join(own)


def main():
    bad = []
    for path in sorted(list(ROOT.glob("shell/**/*.qml")) + list(ROOT.glob("ui/**/*.qml")) + list(ROOT.glob("apps/**/*.qml"))):
        rel = str(path.relative_to(ROOT))
        text = path.read_text()
        if rel not in ALLOW_EDIT:
            for m in RICH_EDIT.finditer(text):
                bad.append(f"{rel}:{text.count(chr(10), 0, m.start()) + 1}: {m.group(0)} outside the allowlist")
        for line, own in blocks(text):
            fmt = re.search(r"textFormat\s*:\s*([\w.]+)", own)
            if not fmt:
                bad.append(f"{rel}:{line}: Text without textFormat")
            elif fmt.group(1) != "Text.PlainText" and rel not in ALLOW:
                bad.append(f"{rel}:{line}: {fmt.group(1)} outside the allowlist")
    for b in bad:
        print(b, file=sys.stderr)
    print(f"check-textformat: {'FAIL' if bad else 'ok'} ({len(bad)} issue(s))")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
