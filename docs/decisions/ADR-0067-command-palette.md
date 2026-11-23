# ADR-0067: The command palette (Search with actions, commands, scripts, links, text replacements and a local model)
Status: Proposed · Date: 2026-11-23 · Decider: owner (scope; D-ext, D-net and D-when answered 2026-11-23; Q-1 and Q-2 open);
integrator (design, delegated answers below, merge after review) · Number: 0067 (the next free number on every ref on
2026-11-23: `git log --all` names ADRs up to 0066 and none mentions 0067; `docs/decisions/` ends at ADR-0066)

## Context
The owner asked on 2026-11-23 for a command palette "as Raycast does, with all its features and further if possible", with the
design rule "macOS first": macOS 26 and 27 Spotlight already took several Raycast ideas (actions on results, quick keys, the
clipboard history), so the model is **Spotlight of macOS 27 in structure and look, with Raycast's depth**, and further than
Raycast where Grassfield owns the system.

Grassfield's Search (docs/specs/search.md) already is a Spotlight: apps, Settings pages, calculator, units, five system
commands, files through localsearch and plocate, recent documents, and the clipboard history view (ADR-0034). It has no
actions beyond one per kind, no command catalogue, no aliases, hotkeys, favorites, links, text replacements, scripts or AI.
The inventory, the sourced feature matrix, the UX model and the slice plan are in docs/specs/command-palette.md.

Constraints:
- CLAUDE.md: no new service, dependency, language, directory or abstraction without need; an ADR when something crosses
  modules; security-relevant work gets an opus reviewer.
- master-prompt §5.8: no new daemon without its own ADR. §5.5 and ADR-0024: tokens only, glass by `BackgroundEffect`, A2.
- ADR-0034's privacy rules (PV-1 to PV-14) bind anything that copies, pastes or reads the clipboard.
- Owner delegation (memory "delegated decisions"): decide by "closest to macOS 27, no technical step for the end user";
  legal, public, root, security, spending and irreversible questions go to the owner.

## Owner decisions (2026-11-23, asked with options)
- **D-ext. Extensibility.** Built-in commands plus the user's own **script commands** only: a folder the user fills, read with
  Raycast Script Commands' metadata format, each run as a separate, confined process. **No** third-party extension store and
  **no** distribution of third-party code for now.
- **D-net. Nothing leaves the machine.** A **local** AI model may be used when present (for example Ollama on localhost),
  detected, **opt-in by its presence**. No cloud AI, no currency rates, no web search over the network.
- **D-when. Schedule.** Code starts in parallel with the ongoing capture suite (ADR-0066) as soon as this plan is reviewed.

## Decision

### D-1. The palette is Search, grown; no second surface
The palette lives in `shell/search/` (an existing directory) and uses the existing `grassfield-search` layer, key (Super+Space)
and window. Reasons:
- **macOS model.** macOS 27 puts actions (⌘3, Tab on a result), quick keys and the clipboard history in Spotlight itself
  ([A1], [A2], [A3] in the spec). A second launcher would be the Raycast model, which the owner put below macOS's for UX.
- **Precedent.** ADR-0034 already chose this for the clipboard history (⌘4 in Search, not a separate window).
- **One focus and lock path.** Search already handles exclusive keyboard focus, FocusReturn, the lock refusal and the blur
  region; a second surface would duplicate all four.

What grows:
- a **command catalogue** (`Commands.js`, pure) that replaces the five fixed rows (Search.qml:281) and that providers fill;
- an **Actions** panel on every row (Tab, as macOS 27 [A1]; ⌘K, as Raycast [R2]);
- a **detail pane** (the clipboard preview's place) for long output, answers and conversations, with a pop stack;
- **argument chips** in the capsule (macOS 27: "fill in its fields in the search field" [A2]).

Search.qml is 1050 lines: new logic goes to pure JS modules (`Commands.js`, `Actions.js`, `Placeholders.js`, `ScriptMeta.js`,
`DateCalc.js`, `AiPrompt.js`) with unit tests, and to two QML singletons in `shell/search/` (`Scripts.qml`, `LocalModel.qml`).
Search.qml only registers providers and dispatches. No new directory: every file goes into an existing one, including the
one new helper, `packaging/bin/grassfield-script-run`.

A separate window (a chat window, an extensions manager) is **not** built: macOS has none for Spotlight, and the detail pane
covers long answers.

### D-2. Commands, quick keys, keyboard shortcuts and favorites
**Command entry** (`Commands.js`): `{id, title, subtitle, keywords (en, fr, English kept), glyph, kind, provider, args[],
actions[], available(), run(args)}`. Ids match `^[a-z][a-z0-9.-]{0,63}$` (`sys.lock`, `win.tile.left-half`, `set.wifi`,
`script.<sha1-of-path>`, `link.<uuid>`, `text.<uuid>`). Menu items get ephemeral ids that are never stored.

**Every built-in command calls the function the existing UI calls** (Control Center, the menu bar, keys, Settings): `Power`,
`SessionState.requestLock`, `Trash.emptyNow`, `NightShift.setOn`, `Rfkill.setBlocked`, `Settings.*` writers, the `windows`
IPC handler's functions in process (Compositor.qml:1361), `Displays`, `Popups.confirm`. So no command gains a privilege or a
code path that the UI does not already have, and the lock refusal stays where it is.

**Quick Keys** (macOS 27's name [A2]; Raycast's aliases [R3]): lowercase letters, digits and spaces; an exact match is the first
row, a prefix match next ([R1]); text after a quick key and a space is the first argument ("ft Ashley" [A2]). macOS's
automatic suggested quick keys are not built (a binding the person did not choose is a surprise).

**Keyboard Shortcuts per command** ([R3]):
- Recorded in the Actions panel; refused when the chord collides with `bindings.lua`, `forwarding.lua` (parsed by the Settings
  app's `Bindings.js`) or Omarchy's binds.
- Stored in `commands.json` as `{slot: "k1".."k99", chord, command id}`.
- The Settings app (the writer, as it writes `keyboard.lua` under ADR-0031's amendment) writes
  `$XDG_CONFIG_HOME/grassfield/commands-keys.lua`: `k<n> = "<chord>"` pairs only. Like `keyboard.lua`, the file is **read as
  text and never run** (`config/hypr/grassfield/input.lua:62-:70`, `read_table`: review of 2026-10-26, a run chunk could stall
  the compositor). A new Grassfield-owned module, `config/hypr/grassfield/commands.lua`, required by `bindings.lua`, reads it
  with the same reader and binds only chords whose modifiers come from a fixed list and whose key matches
  `^[A-Za-z0-9_]{1,32}$` or `code:<n>`, skipping any chord `bindings.lua` or `forwarding.lua` already binds. **No title, id or
  user text reaches Hyprland.**
- Each bind sends Hyprland's `event` dispatcher `gfkey/1 search run <slot>`; `Shortcuts.js` gains `search: {run: ["word"]}`,
  so the socket payload stays a checked word; the shell maps the slot to the command and runs it (or opens Search on its
  argument chips). `docs/specs/security.md` "IPC surface" and `tests/security/ipc_inventory.sh` list `search run`.
- `shell/platform/SessionConfig.qml` (which already watches `keyboard.lua`, :27) also watches `commands-keys.lua`, so a new
  shortcut applies at once.

**Favorites** ([R1]) show as a strip when the field is empty and at least one exists; with none, the empty field shows
nothing, as today (macOS model, search.md:48).

**Ranking:** the existing decayed usage file (search.md:51) gains `cmd:<id>` keys (version 3, v2 migrated on read); Reset
Ranking per row; menu items, window titles and model answers are never recorded.

### D-3. Script commands: discovery, approval and a confined process per run
**Format.** Raycast Script Commands' header ([R16]): `@raycast.<key>` in `#` or `//` comments in the first 64 lines (8 KiB);
`@grassfield.<key>` is accepted as the same key. Required `schemaVersion` (1), `title`, `mode` (`fullOutput`, `compact`,
`silent`, `inline`); optional `packageName`, `icon` (an emoji or a local path; **an https icon is not fetched**, D-net),
`iconDark`, `currentDirectoryPath`, `needsConfirmation`, `refreshTime` (inline, ≥ 10 s), `argument1..3` (JSON: `type` text,
password or dropdown with `data`, `placeholder`, `optional`, `percentEncoded`), `author`, `authorURL`, `description`,
`platform` (a script that lists only `windows` is hidden). `.template.` files are skipped. Parsing is pure JS
(`ScriptMeta.js`); unknown keys are ignored. The UI never names Raycast; the spec and the user documentation may say the format
is compatible.

**Folders.** Settings > Search > Scripts lists folders (Add Folder…, Open Folder, Remove). The default folder,
`$XDG_DATA_HOME/grassfield/script-commands/`, is created only by "Open Scripts Folder". A script is listed only when:
- it is a regular file owned by the user, executable, at most 256 KiB, not group- or world-writable;
- its folder is owned by the user and not group- or world-writable;
- a link resolves to a file that passes the same checks.
Folders are watched; a changed file is re-read.

**Approval (macOS model: the first-open prompt for downloaded code).** The first run of a script, and the first run after its
content changes (SHA-256 of the file), asks: "Run “<title>”? It is a script from <folder> and runs with your permissions."
(Cancel, Run). Approvals are hashes in the state file; Forget Approval is an action; imported settings never carry approvals.
`needsConfirmation: true` adds a confirmation at every run ([R16]).

**Process model.** The shell never runs a script in its own process tree. It runs the runner helper
`grassfield-script-run` (Python stdlib, `-I`, beside `grassfield-capture`), which:
1. re-checks the file (the checks above, and the approved hash) right before running, so a file swapped after approval is
   refused;
2. starts `systemd-run --user --wait --pipe --collect --quiet --description="Grassfield script"` (a **fixed** description: the
   default would put the command line, with password arguments, in the journal) with `RuntimeMaxSec` (60 s by default; 10 s
   for inline), `MemoryMax=512M`, `TasksMax=64`, `NoNewPrivileges=yes`, so the run has its own cgroup, limits, and is killed
   whole on timeout;
3. inside it, runs `bwrap` (already a dependency, PKGBUILD:285) with the host filesystem bound, the user's home writable (the
   scripts' purpose is to act on the user's files), **Grassfield's private stores hidden** (`$XDG_STATE_HOME/grassfield`,
   the clipboard store, `$XDG_RUNTIME_DIR/grassfield`), a new PID namespace, `--die-with-parent`, and the network per the
   owner's answer to **Q-2**;
4. passes arguments as argv (`$1..$3`), never through a shell; `currentDirectoryPath` relative to the script's folder;
5. gives a scrubbed environment: HOME, USER, LANG, LC_*, PATH, XDG_* (runtime, data, config, state, cache), WAYLAND_DISPLAY,
   DBUS_SESSION_BUS_ADDRESS (scripts may start apps and send notifications); no `GRASSFIELD_*` variable;
6. caps stdout at 1 MiB and 2 000 lines and stderr at 64 KiB, then kills the run; exit 0 is success, any other is a failure
   whose last output line is the message ([R16]).

The shell kills every running script when the session locks (`systemctl --user kill` on the unit, by its recorded name), and
inline refreshes run only while Search is open, at most five scripts.

The spike in slice X3 verifies that the user manager runs the unit with these properties (user namespaces are enabled on Arch)
and that `bwrap` works inside it; if a property is refused, the runner fails closed (the script does not run) and the slice
says which property and why.

Residual risks (documented, opus review): a script runs with the user's rights on the user's files, by design; argv is
readable by the user's own processes through `/proc`, so a password argument is visible to them while it runs (as with
Raycast's `$1`); a script can start long-lived children outside the unit only through D-Bus activation or `systemd-run`.

### D-4. The local model (D-net)
**Detection.** `LocalModel.qml` asks `http://127.0.0.1:11434/api/version` and `/api/tags` (then `[::1]`) when Search opens,
cached 60 s, through QML `XMLHttpRequest` (no new dependency). The base URL is a constant: no setting, environment variable or
`OLLAMA_HOST` value can point it elsewhere. Nothing answers → no AI row anywhere. Present → the features appear (opt-in by
presence, owner); Settings > Search > Local Model can turn them off and choose the model.

**Remote models.** Ollama can serve models that run on a remote service; such a model would send the prompt off the machine,
against D-net. How `/api/tags` or `/api/show` marks them is UNCONFIRMED; slice A1 establishes it from Ollama's API
documentation and a test install, and the rule is **fail closed**: a model that cannot be shown to run locally is not offered.

**What is sent.** Only:
- the text the person typed (Ask Local Model, a follow-up, an argument);
- the placeholders of an AI command the person runs, resolved at that moment: `{clipboard}` (the current clipboard, never the
  history), `{date}` and the like. `{selection}` comes later and only through a "Selected text" chip that shows the exact text
  before Return sends it (the clipboard helper never reads the primary selection today, ADR-0034:118; adding that is its own
  opus-reviewed slice);
- the conversation's previous turns, in a follow-up.
Never: files, the clipboard history, screen contents, window titles, menu items, the Search query of another view.

**What comes back** is plain text, drawn with `Text.PlainText`, never executed, never pasted without the person's choice (Copy
or Paste, the latter through ADR-0034's targeted paste). The model gets no tools and cannot run commands (X6 not planned).

**History.** Conversations are in memory and dropped when Search closes, unless "Keep conversations" is on: then 7 days,
`$XDG_STATE_HOME/grassfield/model-conversations.json`, 0600 in 0700, pruned at start, Clear in Settings; Delete Search History
clears it too. Requests are aborted when the session locks.

Residual risk (documented): another local program could listen on 11434 and receive prompts; Ollama's Arch service runs as its
own user, so an owner check on the socket would refuse the normal case. Loopback-only keeps the data on the machine either way.

### D-5. Text replacements and text expansion
**Phase 1 (no keystroke observation):** Text Replacements (macOS's name for snippets, System Settings > Keyboard) are rows in
Search; Return inserts the expanded text into the window Search opened over through ADR-0034's targeted paste (PV-14's
checks), copied with the helper's own-copy marker so the history never records it. `{cursor}` moves the caret with Left keys
sent in the same compositor call after the paste. They are edited in Settings > Keyboard > Text Replacements (the pane
settings.md:95 lists as not built) and from the Actions panel.

**Phase 2 (expansion as you type) waits for the owner's answer to Q-1.** The recommended design:
- the compositor plugin, which already observes keys without cancelling them (`compositor/src/main.cpp:191`), keeps a ring
  buffer of at most 32 characters of the **focused surface only**, converted through its xkb state, in plugin memory only;
- the buffer is cleared, and nothing is matched, on any focus change, any chord with Ctrl, Alt or Super, an active input
  method or compose sequence, while the session is locked or locking, while a polkit, secret or other security sheet or a key
  sink holds the keyboard, for windows in `shell/services/protected-classes.txt` or with `no_screen_share`, and when the
  focused text input reports purpose PASSWORD or PIN or the SENSITIVE_DATA hint (`/usr/include/hyprland/src/protocols/TextInputV3.hpp:46-:49`);
- the shell sends the plugin the keyword list (keywords are not secret); on a match (Immediately, or After Delimiter [R5]) the
  plugin posts `expand {keyword index, window address}` and never the typed text;
- the shell deletes the keyword (BackSpace × its length) and pastes the replacement in **one** compositor call that first
  checks the window address, as PV-14 does;
- per-app exclusions in Settings; off when the person has no keyword;
- nested first, gates C1 to C3, graceful absence (no plugin → no expansion, Phase 1 unchanged), opus reviewer PASS.

### D-6. Menu items of the focused app (further than Raycast's macOS-only command)
Search lists the menu items of the window it opened over (T1/T2 apps, through the global menu bridge), as Raycast's Search
Menu Bar Items ([R20]) and the macOS Help menu (⇧⌘? [A4]) do. The shell walks the tree that `MenuBridge.qml` already holds,
asking `aboutToShow` for submenus (as opening the menu bar does), capped at depth 4, 500 items and 300 ms. Rows show the path,
the shortcut and the toggle state; Return activates the item (`MenuBridge.activate`) after FocusReturn gives the window back,
and only for that window's address. Labels (which may name documents) are never stored, logged or used for ranking. Slice M1
measures real apps and decides whether a menu/1 additive `layout` request in the bridge is needed (then it is versioned in
menu-bridge.md and ADR-0008's contract table).

### D-7. Links (Raycast's quicklinks)
A link is `{name, target, openWith?, args}`; the target is a URL, a file or folder, or an app with a target; placeholders as
in T4 (`Placeholders.js`), `{argument}` values percent-encoded in URLs ([R6]). Opened with `xdg-open` or the app's desktop
entry (argv only). `javascript:` and `data:` targets are refused; a file target must exist. Grassfield ships no web link and no
web-search fallback (D-net). Whether a person's own http(s) links may open is part of **Q-2**.

### D-8. Storage, settings and export
- **User content** (quick keys, keyboard shortcuts, favorites, links, text replacements, user AI commands):
  `$XDG_CONFIG_HOME/grassfield/commands.json`, `{"v": 1, …}`, 0600, written atomically by the Settings app and the shell
  through `write-private.sh`, read with the JsonSafety rules and caps (1 MiB; 2 000 items per list).
- **State** (usage v3, script approvals, calculator history, colour history, kept conversations):
  `$XDG_STATE_HOME/grassfield/`, 0600 in 0700. Delete Search History clears usage, calculator history and conversations.
- **Schema** (`config/schema/grassfield.schema.json`, `search.*`): `showMenuItems` (true), `showSystemState` (true),
  `showScripts` (true), `scriptFolders` (list), `localModel.enabled` (true; inert without a model), `localModel.model` (""),
  `localModel.keepConversations` (false), `textReplacements.expandWhileTyping` (per Q-1), `textReplacements.mode`
  (`delimiter`). One slice at a time edits the schema; the capture suite edits it too (spec §4.3).
- **Export / Import** (Settings > Search): one JSON file of the user content above; never clipboard items, approvals, usage or
  conversations. Raycast's documented snippet and quicklink JSON can be imported ([R4], [R5]); `.rayconfig` (encrypted,
  proprietary) is not read.

### D-9. Calculator, dates and time zones
`Calc.js` and `Units.js` grow (percent phrasings, more units, number bases). Dates and time zones go to a new pure
`DateCalc.js`; zone offsets come from the system tzdata through `QTimeZone`, exposed by a small invokable in `Grassfield.Ui`
(C++, `ui/Grassfield/`, an additive API change recorded in docs/specs/ui-api.md and checked by `just check-contracts`).
QML's `Date` has no time-zone support, and running `date` per keystroke would cost a process per answer. Currency stays
excluded (D-net).

### D-10. Dependencies: none new at run time

| Need | Tool | Status |
|---|---|---|
| Script limits and cleanup | systemd-run (systemd) | present on every target system |
| Script namespaces | bubblewrap | grassfield-desktop `depends` already |
| Pick Color | hyprpicker | Omarchy base; looked up at use time |
| Paste, copy | wl-clipboard, the clipboard helper | already |
| Local model | Ollama | **optional**, never required; an `optdepends` line ("ollama: answers from a local model in Search") is documentation only |
| Time zones | Qt 6 `QTimeZone`, system tzdata | already |

Not used: qalc/libqalculate, espanso, a dictionary, any HTTP library (XHR to loopback suffices), any JavaScript engine for
scripts.

### D-11. Keys and UI names (delegated, macOS 27 first)
- **Tab opens Actions** on the selected row (macOS 27 [A1]); groups move to Page Down/Page Up and Ctrl+↓/↑; search.md S6 and
  F2c are amended in slice P3. ⌘K (Super+K) also opens Actions if slice P3 proves it reaches the layer.
- Ctrl+Return stays the secondary action (⌘↩ is Super+Return, the Terminal key).
- UI names: Actions, Quick Keys, Text Replacements, Favorites, Keyboard Shortcut (macOS words); Links, Scripts, Ask Local Model
  (Grassfield words). Never Raycast, Spotlight, Siri, Apple Intelligence, Quick AI, Quicklinks. Slice P1 adds "Raycast" to
  `tests/ci/ui_names.py`'s banned list.

## Owner questions (open)

- **Q-1. Text expansion while typing (a security decision: the compositor reads what is typed in every app).**
  - « Oui, protégée (Recommandé) »: the plugin matches keywords in the focused window only, never stores or sends what is
    typed, and is suppressed for password fields, the lock, polkit and secret sheets, protected and `no_screen_share` windows;
    off while the person has no keyword; opus reviewer PASS before it ships (D-5 phase 2). Same pattern as the owner's
    answer to ADR-0066 Q-3.
  - « Non, recherche seulement »: Text Replacements are inserted only from Search (phase 1); no keystroke observation.
  - « Plus tard »: phase 1 now, decide phase 2 after the palette ships.

- **Q-2. Network for the person's own content (a security and D-net scope decision).** D-net says nothing leaves the machine;
  this asks whether that binds the person's own scripts and links, which Grassfield neither writes nor ships.
  - « Contenu de l'utilisateur, sur son choix explicite (Recommandé) »: a script runs without network unless the person turns
    on "Allow network" for that script (shown in its Actions, remembered with its approval); a link with an http(s) target
    opens in the browser only when the person picks it; Grassfield ships no web link or fallback.
  - « Sans restriction »: scripts have the network like any program the person runs (Raycast's behaviour); links open freely.
  - « Jamais de réseau »: scripts always run without network and http(s) links are refused.

## Delegated answers (integrator, 2026-11-23, under the owner's delegation)
- **DA-1** One surface (D-1): macOS 27's Spotlight holds actions, quick keys and the clipboard.
- **DA-2** Tab opens Actions (D-11): macOS 27's documented key [A1].
- **DA-3** No suggested quick keys (D-2): no binding the person did not choose.
- **DA-4** A first-run approval for every new or changed script (D-3): macOS's first-open model for code from elsewhere.
- **DA-5** Conversations are not kept by default (D-4): privacy first, nothing to clean up.
- **DA-6** Not planned, with reasons in the spec matrix: currency, web search and dictionary (D-net or a new dependency);
  calendar and reminders (no data store); app and site blocking; skin-tone emoji; extensions and store (D-ext); Hyper key.
- **DA-7** French UI wording follows Apple's French guides where they exist (Quick Keys' French name is checked in P5).

## Alternatives considered
1. **A separate palette window beside Search** (Raycast's model). Rejected: two launchers with overlapping results, a second
   focus and lock path, and further from macOS 27.
2. **Run scripts with Quickshell `Process` directly.** Rejected: the script would live in the shell's cgroup (its memory limit
   and its crash domain), with no timeout kill of its children and no namespaces.
3. **Script confinement with bwrap alone.** Rejected: no resource limits and no whole-tree kill; systemd-run provides both, and
   bwrap inside it provides the namespaces.
4. **A JavaScript extension API in the shell.** Rejected by D-ext and by the shell's stability: third-party code would run in
   the process that holds the lock screen's neighbours.
5. **Text expansion through an input method (zwp_input_method_v2).** Rejected as the recommendation: it would replace the
   person's input method (fcitx5 and the like), work only in apps with text-input-v3, and still read every key.
6. **Text expansion through uinput/evdev (espanso's model).** Rejected: needs the `input` group or root (master-prompt non-goal).
7. **libqalculate for dates, zones and units.** Rejected: a new dependency; its currency update reaches the network.
8. **Ollama via `curl` processes.** Rejected: a process per stream for no gain over XHR to loopback.

## Failure modes
- **No plugin:** window commands degrade as in tiling.md; no expansion (phase 1 unchanged).
- **No bridge or a T0 app:** no menu-item rows.
- **systemd-run or bwrap refuses a property:** the script does not run; its row says "This script could not be started" and the
  journal says which property.
- **A script hangs:** killed at its limit; the row shows the failure.
- **Ollama absent or slow:** no AI rows; a request times out after 60 s with a message; Stop aborts.
- **commands.json invalid:** Search shows no user content and Settings offers to keep the file aside (JsonSafety pattern).
- **A hotkey chord already taken after an Omarchy update:** `commands.lua` skips it and Settings marks it as a conflict.

## Tests
Per slice, in docs/specs/command-palette.md §4: L0 (pure JS, helper fakes), unit (QML TestCase, gtest), L1 nested at scale 1.25
with a screenshot path or "visual NOT verified", L2 for the owner. Opus security reviews: spec §4.4.

## Consequences
- 64 slices of at most a day across eight lanes (spec §4.1); the first owner-visible result (Actions on every row, the system
  and window commands, the main toggles) needs six of them: P1, P2, P3, S1, S3 and S6.
- New code stays in existing directories: `shell/search/`, `shell/platform/`, `apps/settings/`, `ui/Grassfield/`,
  `config/hypr/grassfield/` (`commands.lua`), `compositor/` (phase 2 only), plus `packaging/bin/grassfield-script-run`.
- One new IPC request (`search run <slot>`), one generated data file read as text by a new `commands.lua`, one user-content
  file and a few state files.
- No new run-time dependency and no new daemon.

Sources: as listed in docs/specs/command-palette.md ([R1]–[R22], [A1]–[A4], [P1]); read 2026-11-23.
