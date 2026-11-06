# ADR-0051: Grassfield Memos, desktop memos as small windows
Status: Proposed (2026-11-05), applied provisionally (owner rule of 2026-10-28: decide alone, the recommended option, macOS
model first) · Date: 2026-11-05 · Decider: owner (revisit), integrator (merge) · Number: 0051

## Context
- Owner request (2026-11-05, the "Luma ideas" work package): a native sticky-notes app "with the macOS 27 UI". The macOS 27
  model is the system's desktop notes app: each note is its own small coloured window with a thin title strip (a close box
  on the left, a collapse box on the right), double-click on the strip collapses it to the strip, resizable, styled text,
  Color menu, Translucent per note, every note back where it was at the next launch, Quit keeps them.
- Idea inspired by Project Luma's `luma-sticky-notes` (Apache-2.0): its store's rules (a private directory re-asserted at
  each launch, a schema version migrated forward only, a newer schema refused, no note text in any log, colours checked
  against a fixed set). No code copied: Luma keeps SQLite from Python; Memos reimplements the rules in C++ with one JSON
  file written atomically.
- Grassfield constraints: the apps' pattern (`apps/preview`, `apps/activity`: C++ main and QML, `runmode.h`, `keywindow.h`,
  `windowchrome.h`, `globalmenu.h`), tokens only, no Apple names ("Stickies" is not used anywhere in the UI), a Wayland
  client cannot place its own window (ADR-0026 Context), the shell owns the menu bar's Window menu (T0, `shell/menubar`).

## Decision

### D-1 Identity
"Memos" / « Mémos »; `apps/memos`, `grassfield-memos`, Wayland app id and desktop entry `org.grassfield.Memos`, icon
`branding/icons/apps/org.grassfield.Memos.svg` (an original drawing on the own icons' grammar of ADR-0040: a light tile, two
overlapping memo sheets in Grassfield's own paper colours; no Apple artwork). Packaged in `grassfield-desktop` like Activity
Monitor; in the Dock and Apps through its desktop entry.

### D-2 One process, one window per memo, one instance per user
`grassfield-memos` owns `org.grassfield.Memos` on the session bus (`.Dev` and the state directory's digest in a dev or isolated
run, Store's rule, `apps/memos/src/memosinstance.h`). A second launch hands its xdg-activation token over and leaves; the
running app brings its memos forward, or opens a new memo when none is open (macOS: launching the app with no note opens
one). Two processes never write the one store. Without a session bus the app runs alone.

### D-3 Store
- One file, `$XDG_DATA_HOME/grassfield/memos/memos.json` (`~/.local/share/...` when the variable is empty or relative):
  `{"schema": 1, "memos": [{"id", "color", "html", "width", "height", "x", "y", "collapsed", "floating", "translucent",
  "created", "modified"}]}`, oldest first (the order memos open in).
- The directory is made 0700 and the file 0600 at every launch and at every write (an older directory or a restored backup
  becomes private), written atomically through `QSaveFile` (temporary file, fsync, rename).
- Forward-only migration: a file at an older schema is migrated step by step in memory, a copy of the original is kept once
  as `memos.json.schema-<n>` (0600) and the migrated file written; a file at a newer schema is refused and never rewritten:
  the app shows one alert and opens no memo (read only, nothing written until the user runs a newer Memos). Schema 1 is the
  first; the step table is empty and its mechanism is tested with an injected step.
- A file that is not JSON (or not the expected object) is kept aside as `memos.json.unreadable-<UTC time>` (0600) and the app
  starts empty; an I/O error (permission, a directory in the way) refuses like a newer schema. Files above 16 MiB are refused.
- Each memo is checked on load: an id of 32 hex digits (else a new one), a colour of the six (else yellow), sizes clamped to
  the memo minimum and 16384, booleans, a position only when both coordinates are integers.
- A readable file whose `memos` is not a list, or holds entries that are not memos, is read for what it has; since the next
  save would write it without the rest, the original is first kept as `memos.json.dropped-<UTC time>` (0600; read only when
  that copy cannot be made). Review of the memos slice, 2026-11-05.
- Saves are debounced (800 ms, `MemosApp::kSaveDelayMs`) and run at once on Quit, on SIGTERM and SIGINT (a self-pipe, the
  session's logout), when a memo window loses the focus, and when the last memo closes. Every save first asks each window
  for the text it still holds (`aboutToSave`, a direct call to `MemoWindow.flush`: the window's own 300 ms pause before it
  pushes its text), and a closing window pushes its text before it goes (review: text typed in the last 300 ms was lost on
  Quit, SIGTERM and a compositor close). A lost Wayland connection makes Qt exit without Quit: what was typed since the
  memo was last left (or 800 ms before) can be lost then. No log line carries memo text: messages name the file and the error, ids at most
  (tested with a sentinel string).

### D-4 Text
Rich text (Qt's HTML subset) edited in a `TextEdit`; Font menu Bold, Italic, Underline, Bigger, Smaller and Bulleted List
through `QTextCursor` on the window's document (`MemoFormatter`). Every paste and every drop is plain text (macOS's Paste and
Match Style is the only paste): pasted HTML could carry remote images, which Qt Quick's rich text loads over the network.
Stored HTML is cleaned on load the same way (images and links dropped, and every background image of the body, a frame, a
table, a cell, a paragraph or a run; the text kept), so a hand-edited file loads nothing.

### D-5 Window behaviour and menus
- A memo window draws its own chrome (`gfChromeRole`, ADR-0015): a strip of `memos.stripHeight` in a darker shade of the
  memo's colour, a close box on the left, a collapse box on the right; dragging the strip moves the window
  (`startSystemMove`), a grip at the bottom-right corner resizes it (`startSystemResize`), double-click on the strip collapses
  and expands. Collapsed, the window is the strip's height and shows the memo's first line.
- Close (the close box, Ctrl+W, File > Close) on an empty memo deletes it; on a memo with text an in-window alert asks
  "Delete this memo?" (Cancel, Delete). Quitting keeps every memo. A close the compositor asks for (the Dock's or the app
  menu's Quit sends one to every window, a key binding to one) cannot be told from a user's per-window close, so it keeps the
  memo: the window goes, the memo opens again at the next launch or activation; when no memo window is left the app quits.
  The last memo deleted quits the app too (a later launch opens a new memo, as macOS does with no note).
- The middle button pastes the primary selection, plain text like every paste.
- Global menus (T1, the other apps' pattern: Qt.labs.platform MenuBar only while the registrar exists, each memo window its
  own): File (New Memo Ctrl+N, Close Ctrl+W), Edit (Undo, Redo, Cut, Copy, Paste, Select All), Font (Bold Ctrl+B, Italic
  Ctrl+I, Underline Ctrl+U, Bigger Ctrl++, Smaller Ctrl+-, Bulleted List), Color (the six, Ctrl+1 to Ctrl+6), and Note
  (Translucent Ctrl+Alt+T, Collapse Ctrl+Alt+C, a check mark on the first; Stickies' own name for that menu, so that the
  French menu "Note" never reads as the app menu "Mémos"). macOS puts both in its Window menu, and a third item, Float on Top
  (not shipped, D-6); the shell owns Window (T0, `shell/menubar`: its items are the shell's own, it takes no app
  items, and an app's own "Window" would show twice), so they get a menu of their own, as Files and Activity Monitor put
  their window items in View (F-10). If the shell's Window menu learns to take app items, they move there. The same keys
  work without the registrar.
- A new memo opens near the memo in front: down and to the right by `memos.cascadeStep` (D-6).

### D-6 Positions: the compositor's part (Float on Top is not shipped)
- The app cannot place or find its windows on Wayland. It reads its own windows' frames (`at`, `size`) from Hyprland's
  request socket (`j/clients`, read only, filtered on its own pid and its `memo:` tags; `apps/memos/src/hyprframes.cpp`) when
  it saves, and keeps them in the store. It never sends a dispatch.
- Each memo window's xdg-toplevel tag (ADR-0015's role) is `memo:<id>[@<x>,<y>]`. `config/hypr/grassfield/placement.lua`
  moves a new Memos window to the `@x,y` its tag names before the usual `fit` (layout coordinates, as Hyprland reported them).
- **Float on Top is not shipped** (security review of the Luma pull request, finding 1, integrator decision). The first
  design raised the Memos windows whose tag said `:top` after every focus change (`stacking.lua`). Both the app id and the
  tag are chosen by the client: any Wayland client, a Flatpak included, could claim them and have its window raised over the
  focused one after every focus change, and could cover the Store's widened-permission sheet with an empty input region.
  The menu item, its shortcut, its state in the store, the `:top` tag suffix and the stacking rule are removed. **Float on
  Top returns only with a compositor-plugin check of the client's real credentials** (the executable path read from the
  kernel, and not sandboxed), never from names the client sets. The nested review also found it did not work (a floating
  memo went behind any clicked window), so nothing that worked is lost.
- The placement rule matches the app id exactly (`org.grassfield.Memos`, case-sensitive) and a tag of exactly 32 lowercase hex digits
  (`tests/shell/memos_rules.sh`). Residual risk (review of the memos slice): a Wayland client chooses its own app id and
  tag, so another program can claim Memos' and open its window at a position of its choice inside the free area (the
  position only: no stacking is granted by a name any more). Binding the rules to Memos' process
  needs a pid that Lua can trust (Hyprland 0.56's Lua window object is not known here to carry one, and a pid alone does not
  name the program); left for the nested session with the `hl.meta.lua` stub at hand.
- **Collapse resizes the window** (nested review, finding 6). Hyprland 0.56 keeps a floating window at the size it has when
  its client only commits a smaller or larger surface, so a collapsed memo sat on an empty rectangle. The app cannot ask for a
  size on Wayland, so a collapse or an expand sends the xdg-toplevel tag again with `!<w>x<h>` (`memo:<id>[@x,y]!<w>x<h>`),
  once the window has committed its new constraints, and with the corner it had before (read from Hyprland just before).
  `placement.lua` (`memo_resize`, on `window.update_rules`) resizes the window to that size when the suffix changes, and puts
  the corner back inside the free area (macOS's notes shrink to their strip in place). Only a change of the suffix acts, so
  a resize by the user is never undone; the size is bounded and the request is only ever about the window that sent it.
  Proved in nested at scale 1.25: 240x200 to 240x18 and back, four transitions, the corner at the same place.
- **Square corners** (finding 8): macOS's notes have square corners and the resize grip sits in the bottom-right one, which a
  rounded window cut. `windows.lua` sets `rounding = 0` for the Memos app id (`gf-memos-square`); a name claimed by another
  client gets square corners and nothing else.
- `windows.lua` lists `org.grassfield.Memos` with the apps that draw their own chrome (no plugin titlebar) and lets its
  windows send their own maximize request (there is none, the list is the client-chrome one).
- Without Hyprland's socket (another compositor, an error) frames stay unknown: memos open where the compositor puts them,
  at their stored size; nothing else changes. Without the plugin nothing changes (the rules are Lua).

### D-7 Translucent
The memo's paper is drawn at `memos.translucentOpacity`; the window itself is transparent (no fake blur: Hyprland blurs
what is behind it when its decoration blur is on, ADR-0024).

## Options rejected
- A file per memo: more files to keep private and consistent; one small JSON is enough at memo scale.
- SQLite (Luma's choice): a new dependency for a few kilobytes.
- Hyprland's `pin` for Float on Top: on every Desktop too. Dispatches from the app: an app driving the compositor is new
  architecture; the Lua rules keep the compositor's side in the compositor's config (ADR-0026's direction).
- A "Window" menu of the app's own: a second Window in the bar.
- Shell Search over memo text: optional in the brief and not cheap (a new search provider reading another app's private
  file); left for later.

## Failure modes
Newer schema or I/O error: alert, read only, the file untouched. Corrupt file: kept aside, empty start. Save failure: the
memo stays in memory, a warning without content is logged, the next change tries again. No registrar: no global menu, the
keys still work. No compositor socket: no stored positions (sizes and colours still restored).

## Tests (L0)
`tests/unit/memos/tst_memostore.cpp` (gtest): round trip, 0700/0600 re-asserted, atomic write leaves no temporary file and a
failed write leaves the old file, migration with an injected step and its backup, newer schema refused and untouched,
corrupt file kept aside, validation, no memo text in any log message. `tst_hyprframes.cpp`: the clients JSON parsed and
filtered, the tag built and read. `tests/unit/tst_memos.qml`: MemoLogic.js (colours, cascade, first line, tags, collapse)
and a memo window offscreen with a fake backend (strip, collapse, close alert, colour, translucent, menu-less keys).

The Lua placement rule (the collapse resize, the square corners and the Cancel button were checked in nested, review fix 2026-11-06), the
The Lua placement rule, (the collapse resize, the square corners and the Cancel button were checked in nested, review fix 2026-11-06), the
global menu export, the window's look on screen (visual NOT verified unless the spec says otherwise), multi-display
positions (a memo whose display is gone is fitted onto the display it opens on).
