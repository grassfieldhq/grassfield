# Memos spec · apps-engineer · owner brief 2026-11-05 (the "Luma ideas" work package)
Decision record: `docs/decisions/ADR-0051-memos.md` (D-1 to D-7). The app is "Memos" / « Mémos »; internal names `apps/memos`,
`grassfield-memos`, `org.grassfield.Memos`. No Apple name ("Stickies") appears in the UI, the desktop entry or the code's strings.

## macOS reference behavior (macOS 27's desktop notes app, described in words, no Apple image committed)
- Each note is a small window of its own: a thin strip at the top in a darker shade of the note's colour, a close box at the
  left end and a collapse box at the right end; the rest is the note's text on its coloured paper. A grip at the bottom-right
  corner resizes it; dragging the strip moves it; double-clicking the strip collapses the note to its strip (showing its first
  line) and back.
- Colours: yellow (the default), blue, green, pink, purple, grey (Color menu, Command-1 to Command-6).
- Font menu: Bold, Italic, Underline, Bigger, Smaller; lists in the text; Paste and Match Style.
- Note menu: Translucent (the desktop shows through), Collapse. (macOS also has Float on Top; Memos does not ship it for now, ADR-0051 D-6.)
- Closing a note with text asks before deleting it. Quitting keeps every note; at the next launch each one comes back where it
  was, at its size and colour. A new note opens near the front note.

## Requirements
| # | Requirement | Status |
|---|---|---|
| MM1 | One window per memo, its strip with a close box (left) and a collapse box (right), drawn with tokens (`memos.*`) | built |
| MM2 | Drag the strip to move (`startSystemMove`); the bottom-right grip resizes (`startSystemResize`) | built (compositor side NOT VERIFIED) |
| MM3 | Double-click on the strip, the collapse box or Note > Collapse: the window becomes the strip, with the first line; again expands to the stored height. The window really resizes: the tag is sent again with `!<w>x<h>` and `placement.lua` `memo_resize` applies it (ADR-0051 D-6) | built, proved in nested at 1.25 |
| MM4 | Six colours, paper and strip tokens, ink 4.5:1 or more on each (`tests/visual/test_contrast_tokens.py`) | built |
| MM5 | Rich text: Bold, Italic, Underline, Bigger, Smaller, Bulleted List (`MemoFormatter`, `QTextCursor`) | built |
| MM6 | Every paste and drop is plain text; stored HTML is cleaned of images, links and background images on load (ADR-0051 D-4) | built |
| MM7 | Translucent per memo, with a check mark (Note menu). Float on Top is not shipped (ADR-0051 D-6) | built |
| MM8 | Memos restored at launch with size, colour, collapsed state, flags; position through the tag and `placement.lua` | built (positions NOT VERIFIED) |
| MM9 | A new memo opens `memos.cascadeStep` down and right of the front memo (when its position is known) | built (NOT VERIFIED on screen) |
| MM10 | Close on an empty memo deletes it; with text, the in-memo alert "Delete this memo?" (Cancel, Delete) | built |
| MM11 | Quit keeps every memo; the last memo deleted quits the app; a compositor close (the Dock's Quit) keeps the memo; SIGTERM and SIGINT save first | built |
| MM12 | Global menus T1 (File, Edit, Font, Color, Note) while the registrar exists, the same keys without it | built (export NOT VERIFIED) |
| MM13 | One instance per user (D-Bus name); a second launch brings the memos forward, or opens a new memo when none is open | built |
| MM14 | Store: one JSON file, 0700/0600 re-asserted, atomic, debounced (each window flushed first; a memo left is saved), dropped entries kept aside, forward-only migration, newer schema refused untouched, no text in logs | built, gtest |
| MM15 | Dock icon and Apps entry (`org.grassfield.Memos.desktop`, `branding/icons/apps/org.grassfield.Memos.svg`) | built |
| MM16 | Shell Search finds memo text | not built (optional; ADR-0051 Options rejected) |

## Keys (Grassfield's Command is Ctrl, as in the other apps)
| Key | Action |
|---|---|
| Ctrl+N | New Memo |
| Ctrl+W | Close (deletes the memo; asks first when it has text) |
| Ctrl+Q | Quit (keeps every memo) |
| Ctrl+Z, Ctrl+Shift+Z | Undo, Redo |
| Ctrl+X, Ctrl+C, Ctrl+V, Ctrl+A | Cut, Copy, Paste (plain text), Select All |
| Ctrl+B, Ctrl+I, Ctrl+U | Bold, Italic, Underline |
| Ctrl++ (Ctrl+=), Ctrl+- | Bigger, Smaller |
| Ctrl+Shift+7 | Bulleted List |
| Ctrl+1 to Ctrl+6 | Yellow, Blue, Green, Pink, Purple, Grey |
| Ctrl+Alt+T, Ctrl+Alt+C | Translucent, Collapse |

## Interfaces
- Store: `$XDG_DATA_HOME/grassfield/memos/memos.json` (ADR-0051 D-3), schema 1.
- Session bus: `org.grassfield.Memos` (`.Dev` and a digest in dev or isolated runs), object `/org/grassfield/Memos`, method
  `Activate(s token)`.
- Hyprland: `j/clients` read on the request socket (read only); window tag `memo:<id>[@<x>,<y>]`
  (`config/hypr/grassfield/placement.lua`, `windows.lua`).
- Reads `grassfield.json` (appearance, accessibility, accent, shortcut style), never writes it.

## Tests
- `tests/unit/memos/tst_memostore.cpp`, `tst_hyprframes.cpp`, `tst_memosapp.cpp` (gtest; `apps/memos/build-direct.sh --tests`).
- `tests/unit/tst_memos.qml`: `apps/memos/qml/MemoLogic.js` and a memo window offscreen with a fake backend.

## NOT VERIFIED
Everything that needs Hyprland or a nested session (ADR-0051 "NOT VERIFIED"): positions, the global menu export, the window's look on a real screen.
