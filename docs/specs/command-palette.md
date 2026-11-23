# Command palette spec (plan) · shell-engineer, platform-engineer, compositor-engineer, security-engineer · ADR-0067 (Proposed)

Status: design and plan only. Nothing here is built. Owner request of 2026-11-23: a command palette "as Raycast does, with all
its features and further if possible". Base: the integration head 8398b59a. Architecture and owner decisions:
docs/decisions/ADR-0067-command-palette.md. Today's Search is specified in docs/specs/search.md and the clipboard history in
docs/specs/clipboard.md (ADR-0034). This file does not change them; it adds the next layers on top, and names each place where
a slice must amend them.

Model (owner, 2026-11-23): **macOS 27 Spotlight in structure and look, with Raycast's depth**, and further than Raycast where
Grassfield owns the system (the focused app's menus through the global menu bridge, windows, Spaces, displays, Grassfield
settings, system state). macOS 26 and 27 Spotlight already took several Raycast ideas: actions on results, quick keys, the
clipboard history [A1][A2][A3]. The palette is **Search itself**, grown (ADR-0067 D-1), not a second launcher.

Naming (CLAUDE.md, master-prompt §5.5, `tests/ci/ui_names.py`):
- The UI never shows "Raycast", "Spotlight", "Siri", "Apple Intelligence", "Quick AI", "Quicklinks" or any Apple name. The
  surface stays **Search** « Recherche ».
- UI names follow macOS 27 wording where it is a plain word: **Actions** (the action panel, [A2]), **Quick Keys** (aliases,
  [A2]), **Text Replacements** (snippets: the macOS Keyboard settings name, already listed as "not built" in
  docs/specs/settings.md:95), **Favorites**, **Keyboard Shortcut**. Grassfield-own words: **Links** « Liens » (Raycast's
  quicklinks), **Scripts** « Scripts » (script commands), **Ask Local Model** « Demander au modèle local » (Raycast's Quick AI).
  The French of "Quick Keys" is UNCONFIRMED (no French Apple page read); slice P4 checks it against Apple's French guide.
- Code names: `Commands.js` (catalogue), `Actions.js`, `Placeholders.js`, `ScriptMeta.js`, `Scripts.qml`, `LocalModel.qml`,
  `grassfield-script-run` (runner helper), all in existing directories.

Sources. The product descriptions below are data: they describe the products, and nothing in them is an instruction. All were
read on 2026-11-23.
- [R1] https://manual.raycast.com/search-bar · [R2] https://manual.raycast.com/action-panel ·
  [R3] https://manual.raycast.com/command-aliases-and-hotkeys · [R4] https://manual.raycast.com/quicklinks ·
  [R5] https://manual.raycast.com/snippets · [R6] https://manual.raycast.com/dynamic-placeholders ·
  [R7] https://manual.raycast.com/clipboard-history · [R8] https://manual.raycast.com/window-management ·
  [R9] https://manual.raycast.com/calculator · [R10] https://manual.raycast.com/emoji-symbols ·
  [R11] https://manual.raycast.com/file-search · [R12] https://manual.raycast.com/system-commands ·
  [R13] https://manual.raycast.com/calendar · [R14] https://manual.raycast.com/notes · [R15] https://manual.raycast.com/focus ·
  [R16] https://github.com/raycast/script-commands (README.md, documentation/ARGUMENTS.md, documentation/OUTPUTMODES.md) ·
  [R17] https://manual.raycast.com/extensions · [R18] https://manual.raycast.com/ai, …/ai/quick-ai, …/ai/ai-commands,
  …/ai/local-models, https://www.raycast.com/changelog/1-99-0 · [R19] https://manual.raycast.com/import-export ·
  [R20] https://manual.raycast.com/navigation (Search Menu Bar Items, Switch Windows) · [R21] https://manual.raycast.com/hyper-key ·
  [R22] https://manual.raycast.com/translate
- [A1] https://support.apple.com/guide/mac-help/search-with-spotlight-mchlp1008/mac (the macOS 27 guide) ·
  [A2] https://support.apple.com/guide/mac-help/take-actions-and-shortcuts-in-spotlight-mchl4953dfeb/27/mac/27 ·
  [A3] https://support.apple.com/guide/mac-help/search-your-clipboard-history-mchl40d5b86b/26/mac/26 ·
  [A4] https://support.apple.com/en-us/102650 (Mac keyboard shortcuts)
- [P1] PRESS, not Apple: https://www.macrumors.com/how-to/do-more-with-spotlight-in-macos-tahoe/ (⌘1 to ⌘4 browse views, `/`
  kind filters, clipboard retention choices).

Not found in these sources, so marked UNCONFIRMED where used: a Raycast fallback-commands page (manual.raycast.com/
fallback-commands answered 404; Settings > Launcher > Fallback Commands is named in …/ai/quick-ai), Raycast's colour picker,
compact mode, deeplinks, Quit Applications, Kill Process, Search Screenshots, Dictionary, reminders, timers, store review;
clipboard encryption; Spotlight menu-item search, dictionary source, web suggestions and the ⌘1/⌘2/⌘4 keys on an Apple page
(only ⌘3 is on [A2]). The Script Commands README names no languages besides Bash.

## 1. Inventory: what Grassfield's Search does today (8398b59a)

### 1.1 Components

| Part | Where | What it does |
|---|---|---|
| Search controller | `shell/search/Search.qml` (1050 lines) | • State: `open`, `query`, groups, keyed rows (:34-:64), filter chips (:69-:75), the Clipboard view (:78-:94).<br>• Settings > Search switches (:157-:165), Delete Search History (`forgetHistory` :175).<br>• Providers in `compute()` :317-:430: calculator, conversion, apps (`Ranking.rank`), commands, Settings pages, documents (localsearch then plocate, `spawnSearch` :460, cancelled by sequence :470-:500), recent documents (`recently-used.xbel`, :923). Top Hit rule :361-:381.<br>• **Commands are five fixed rows** (`commandList` :281-:290: Lock Screen, Sleep, Restart, Shut Down, Log Out), run by `runCommand` :552-:571 through `SessionState.requestLock`, `Power` and `Popups.confirm` (`shell/services/Popups.qml:223`).<br>• `activate` :509-:545: one action per kind (open app, copy answer, run command, open Settings page, open or reveal file, paste clip). **No other action exists on a result.**<br>• Usage boost file `search-usage.json` (:879-:905; decay rules in search.md).<br>• IPC target `search` :978-:1049 (`toggle`, `clipboard`, `open`, `close`, `query`, `filter`, `status`). |
| Search surface | `shell/search/SearchPanel.qml` (1175 lines) | • Layer `grassfield-search`, Overlay, keyboard Exclusive while shown, `BackgroundEffect` blur region (:56-:63).<br>• Keys (:478-:538): ↑/↓, Tab/Shift+Tab between groups, Return opens, **Ctrl+Return reveals** (⌘↩ is Super+Return, bound to Terminal: `config/hypr/grassfield/bindings.lua:248`), Esc clears then closes; ⌘4 opens the Clipboard view.<br>• Row menu (secondary click, Menu key, Shift+F10) and More menu (:236-:330, :1140-:1170) exist **for clipboard rows only** (`rowMenuModel` returns nothing for other kinds, :237).<br>• Preview pane beside the results (clipboard items). |
| Pure logic | `shell/search/Ranking.js` (494: `textScore` :87, `rank` :210, usage :228-:260, `rankFiles` :479), `Calc.js` (233: own tokenizer and parser, `answer` :225, no eval), `Units.js` (131: `answer` :113; length, mass, temperature, data sizes; no currency), `Numbers.js`, `Files.js`, `Filters.js` (chips), `KeyedRows.js`, `SettingsPages.js` (`match` :40), `ClipboardView.js` (`keyAction` :74, `opensView` :119, `menuIds` :135) | Unit tests: `tests/unit/tst_search{calc,units,ranking,filters,rows,settings}.qml`, `tst_clipboard.qml`, `tst_settingssearch.qml`; shell tests `tests/shell/search_chips`, `search_clipboard`, `search_locale`. |
| Clipboard history | `shell/services/Clipboard.qml` (IPC :644; `paste` :494, `pasteOwned` :516), `apps/clipboard-helper/` | ADR-0034: native ext-data-control helper, pins, retention, never records `x-kde-passwordManagerHint` copies (PV-1); **targeted paste**: one Hyprland Lua function checks the remembered window address and sends Ctrl+V (Ctrl+Shift+V in terminals), key up armed first (ADR-0034:196-:215, PV-14). The helper **never reads the primary selection** (ADR-0034:118). |
| Emoji & Symbols | `shell/services/Emoji.qml` (IPC `emoji` :345), `EmojiLogic.js`, `shell/overlay/EmojiPanel.qml` | Ctrl+Super+Space popover; inserts through `omarchy-menu-emoji-insert` (sensitive copy + Shift+Insert) or `wtype` (docs/specs/clipboard.md ES-7). Opens at the pointer: the shell has no caret position. |
| In-process key requests | `shell/platform/shortcuts/Shortcuts.js:17-:41`, `Shortcuts.qml` | Key bindings reach shell IPC handlers in process (`gfkey/1 <target> <function> [args]` on socket2), with a fixed table of allowed requests and argument kinds (`word`: `^[A-Za-z][A-Za-z0-9-]{0,31}$`). `search: {toggle, clipboard}` today. |
| Key bindings | `config/hypr/grassfield/bindings.lua:251` (Super+Space), `:253` (Super+Ctrl+V), `:304` (XF86Search); `forwarding.lua:117` (Super+1…9 sent as Ctrl+1…9) | Hotkeys per command would be new binds here or in a generated file (ADR-0067 D-2). |
| Window commands | `shell/platform/Compositor.qml:1361-` IPC `windows`: `minimize`, `tile(place)`, `arrange(layout)`, `tilePopover`, `nextOutput(direction)`, `hide`, `showDesktop`, `cycleApp` | The tiling places and layouts of docs/specs/tiling.md (TL4, TL23); the plugin verbs `tile`, `arrange`, `move_to` (tiling.md:695-:711). |
| Global menus | `shell/platform/MenuBridge.qml` (`items` :57, `menus` :61, `aboutToShow(dbusId)` :144, `activate(dbusId, keyboardHeld)` :157); `bridges/menu-bridge/` (menu/1 protocol, docs/specs/menu-bridge.md:307-) | The focused window's DBusMenu tree, submenus filled on about-to-show. T0 apps (no exported menu) have none. No menu-item search and no Help-menu search exist (docs/specs/menubar.md:80 lists the T0 Help menu as missing). |
| System services the commands can call | `shell/services/`: `Power.qml`, `SessionState.qml`, `Trash.qml` (`open` :34, `emptyNow` :40), `NightShift.qml` (`setOn` :27), `Rfkill.qml` (`setBlocked` :37), `BluetoothState.qml`, `Connectivity.qml`, `Battery.qml`, `Audio.qml`, `Brightness.qml`, `Media.qml`, `Settings.qml` (`notificationsDnd`, `dark`, `reduceMotion`, `dockAutohide`, `windowsStages`…), `SettingsApp.qml` (`openSection`), `Apps.qml` (`launch`, `openDetached`), `CaptureState.qml`; `shell/overlay/ForceQuitPanel.qml`; `shell/platform/Displays.qml`, `QuickLook.js` (Glance) | The functions Control Center, the menu bar and the keys already call. |
| Memos | `apps/memos/` (docs/specs/memos.md, ADR-0051) | Desktop notes app (macOS 27's notes model). |
| Calendar | `shell/widgets/Calendar.js` | A month grid for the widget only. **No event store exists** on the system Grassfield targets (no EDS, Akonadi or .ics reader). |
| Settings | `config/schema/grassfield.schema.json:1124` (`search.*`); Settings > Search (search.md:103-:112); Settings > Keyboard (settings.md:95: "Text Replacements" not built) | — |
| Tokens | `ui/tokens/tokens.json:644-` (`search.*`: capsule 520 wide, rows 63, selection fill) | — |

### 1.2 Tools on this machine (read-only checks, 2026-11-23)

| Tool | Present | Ships with | Use in this plan |
|---|---|---|---|
| systemd-run | yes | systemd | Script runner unit: limits, timeout, cleanup (ADR-0067 D-3). |
| bubblewrap 0.13.1 | yes | **grassfield-desktop `depends`** (packaging/arch/PKGBUILD:285; used by `packaging/session-bin/chromium:84`) | Script namespaces (network, hidden private stores). |
| hyprpicker | yes | Omarchy base (`omarchy-base.packages:64`) | Pick Color. Looked up at use time. |
| wtype | yes | Omarchy base (:158) | Not used by the palette (the targeted paste is). |
| localsearch, plocate | yes | Omarchy base / optdepends (PKGBUILD:300-:301) | File results, unchanged. |
| tesseract | yes | Omarchy base | Not used by the palette. |
| ollama | **no** | — (Arch `extra`) | Detected at use time on loopback only (ADR-0067 D-4). |
| qalc (libqalculate), espanso, sdcv/dictd | **no** | — | Not used (new dependencies). |

### 1.3 Compositor facts relevant to text expansion (headers, Hyprland 0.56)
- `/usr/include/hyprland/src/protocols/TextInputV3.hpp:28-:63`: per text input the plugin can read `contentType.purpose`
  (`ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_*`, so PASSWORD and PIN), `contentType.hint` (so SENSITIVE_DATA), `surrounding` text and
  the caret `box`. Whether clients send them while no input method is bound is UNCONFIRMED (spike T5).
- The plugin already observes key events, never cancelling them (`compositor/src/main.cpp:191`, `OverviewFocus.cpp:499`;
  docs/specs/capture-suite.md §1.1).

## 2. Feature matrix

**Effort:** S is one slice of at most a day; M is 2 to 3 slices; L is 4 or more slices, or a compositor or security gate.
"Slices" names the §4 slices that build the row. Several S rows may share one slice.

**Rules for every row:** nothing leaves the machine (D-net); no command runs while the session is locked (Search already
refuses: `SessionState.refuses`); new private files are 0600 in a 0700 folder through `shell/services/write-private.sh`; no
text from a result, a script, a menu or a model is ever drawn as rich text (`Text.PlainText`, PV-8).

### 2.1 Root search, actions and navigation

| # | Feature [source] | Raycast | macOS 27 Spotlight | Grassfield today | Proposal | Effort | Security note | Deps | Slices |
|---|---|---|---|---|---|---|---|---|---|
| N1 | Root search over apps, files, commands, settings [R1] | yes | yes [A1] | yes (search.md) | Unchanged; the command catalogue (N2) feeds the Commands group. | — | — | — | — |
| N2 | Command catalogue (every built-in command one row, with keywords) [R1][R12] | yes | yes, Actions [A2] | 5 fixed rows (Search.qml:281) | `Commands.js`: a registry of ids, titles, keywords (en and fr), glyph, availability, argument schema, action list; providers plug in (system, windows, settings, scripts, links, snippets, menus). | M | Every `run` goes through the service function the UI already uses; no new IPC. | — | P1, P2 |
| N3 | Action panel: ⌘K, primary Return, more actions, shortcuts on actions [R2] | yes | yes: "select a result and press Tab" shows Quick Actions [A1] | none outside the Clipboard view | Tab (macOS 27) **and** ⌘K open **Actions** for the selected row: a glass list beside the row, typed filter, Return runs, Esc closes. Ctrl+Return stays the secondary action. Actions per kind in `Actions.js`. | M | Destructive actions marked, confirm where the UI already confirms. | N2 | P3, P4 |
| N4 | Favorites, shown on an empty field, reorderable [R1] | yes | no (the empty field shows nothing, search.md:48) | none | **Favorites** row strip under the capsule when the field is empty and at least one favorite exists; macOS shows nothing otherwise, so nothing changes for a user with none. Add or remove from Actions. | S | — | N3 | P6 |
| N5 | Frecency ranking, Reset Ranking [R1] | yes | — | usage boost, decayed (search.md:51), Delete Search History | Extend the existing usage file to commands, links, snippets, scripts (`cmd:<id>`); "Reset Ranking" action per row. Menu items never recorded. | S | Menu labels can name documents: never stored. | N2 | P6 |
| N6 | Aliases (exact then prefix match) [R3] / quick keys [A2] | yes | yes (quick keys, suggested after one run [A2]) | none | **Quick Keys**: lowercase letters, digits, spaces; exact match puts the row first, prefix next (Raycast rule [R1]); "ft Ashley" passes the rest as the argument (macOS example [A2]). Suggested quick keys: not planned (macOS assigns them silently; a surprise binding is worse than none). | S | — | N2 | P5 |
| N7 | Global hotkey per command [R3] | yes | no | Settings > Keyboard lists fixed bindings | **Keyboard Shortcut** action: records a chord, refused when it collides with `bindings.lua`/`forwarding.lua` or Omarchy's; written to a generated, validated binds file; the bind sends `gfkey/1 search run <slot>` (ADR-0067 D-2). Listed in Settings > Keyboard > Keyboard Shortcuts. | M | The socket payload is a slot word, never a command line. | N2 | P7, P8 |
| N8 | Arguments on commands, filled inline [R16][R6] | yes (up to 3) | yes: "fill in its fields in the search field" [A2] | none | Argument chips inside the capsule after the title (macOS model), Tab between them, Return runs; types text, password (dots, never stored or logged), dropdown. | M | Password values: memory only, cleared on close. | N2 | P9, P10 |
| N9 | Navigation: Esc clears then closes, Backspace on empty goes back, pop to root after idle [R1] | yes | Esc returns from an action to search [A2] | Esc clears then closes; Backspace leaves the Clipboard view | Same stack model for detail views (script output, answers, AI): Esc or Backspace on empty pops one level. Pop to root: Search already forgets its query on close; nothing to add. | S | — | P11 | P11 |
| N10 | Detail view (long output, previews) [R16 fullOutput] | yes | preview pane (Quick Look [A1]) | the clipboard preview pane | One **detail pane** in the panel's right half (the clipboard preview's geometry, tokens `search.detail*`): plain text, monospace option, ANSI colour subset, Copy, scroll. | M | ANSI parser strips everything but SGR colours; no links. | — | P11, P12 |
| N11 | Browse views ⌘1 Apps, ⌘2 Files, ⌘3 Actions, ⌘4 Clipboard [P1]; `/` kind filter [P1] | — | ⌘3 confirmed [A2]; others PRESS | ⌘4 (Clipboard), chips | ⌘1, ⌘2, ⌘3 select the matching chip view (forwarded Super+digit → Ctrl+digit, forwarding.lua:117). `/` filter: not planned (the chips already filter). | S | — | N2 | P13 |
| N12 | Fallback commands when nothing matches [R18 quick-ai] (page UNCONFIRMED) | yes | Return asks Siri AI [A1] | "No Results for …" | The no-results notice gains rows: **Search Files for "…"** (content search), **Ask Local Model** (when present, D-4), **Create Link / Text Replacement from "…"**. No web search (D-net). | S | — | P11 | P14 |
| N13 | Import / export settings (encrypted .rayconfig) [R19] | yes | no | none | **Export Commands…** and **Import…** in Settings > Search: one JSON file (quick keys, shortcuts, favorites, links, text replacements; no clipboard, no AI history, no script trust). Importing Raycast's documented snippet and quicklink JSON (R5, R4) maps fields; .rayconfig is encrypted and proprietary: not planned. | S | Imported links and snippets are data; imported scripts are never trusted (D-3). | X, T | E5 |
| N14 | Hyper key [R21] | yes | no | none | Not planned: Super is ⌘ in Grassfield; key remapping belongs to Settings > Keyboard. | — | — | — | — |
| N15 | Themes, compact mode (UNCONFIRMED) | yes | — | Grassfield appearance | Not planned: the palette follows Grassfield's appearance and glass. | — | — | — | — |
| N16 | Deeplinks / URL scheme (UNCONFIRMED) | yes | no | IPC `search` | Not planned beyond IPC (`search run <slot>` for hotkeys). | — | — | — | — |

### 2.2 Built-in commands (further than Raycast where Grassfield owns the system)

| # | Feature [source] | Raycast | macOS 27 | Grassfield today | Proposal | Effort | Security note | Slices |
|---|---|---|---|---|---|---|---|---|
| B1 | System commands: Lock, Sleep, Sleep Displays, Restart, Shut Down, Log Out, Screen Saver, Toggle Appearance, Empty/Open Trash, Show Desktop, volume and media [R12] | yes | partly, as actions [A2] | 5 rows | All of them, through `Power`, `Trash.emptyNow` (asks, as Trash does), `Settings.dark`, `windows showDesktop`, `Audio`, `Media`, screen saver IPC. Eject All Disks, Toggle Hidden Files: not planned (no system-wide hidden-files state; Files owns it). | S | Empty Trash keeps its confirmation. | S1 |
| B2 | Quit All Apps, Quit All Except Frontmost, Restart Frontmost App, Hide Others [R12]; Force Quit; Kill Process (UNCONFIRMED) | yes | no | Force Quit panel | **Quit All Applications…** (asks, the Log Out dialog's list), **Hide Others**, **Force Quit…** opens the existing panel. Kill Process: through Activity Monitor (not a palette list). | S | Quit asks first. | S2 |
| B3 | Window management: halves, thirds, quarters, center, maximize, next display, custom layouts [R8] | yes | Window menu tiling | `windows tile/arrange/nextOutput` IPC | Every TL4 place, TL23 arrangement and layout, "Move to <display>", Minimize, Full Screen, for the window active when Search opened. Greyed when the plugin lacks the feature (tiling.md degraded rules). | S | Acts only on the remembered window address (FocusReturn), dropped if it closed. | S3 |
| B4 | Switch Windows (with minimize, close in ⌘K) [R20] | yes | no | Overview, switcher | **Windows** provider: open windows by title and app, Return focuses (un-minimizes), Actions: Close, Minimize, Move to Space, Move to display. | S | Titles never stored. | S4 |
| B5 | Search Menu Bar Items of the frontmost app [R20] | yes (needs Accessibility) | Help menu (⇧⌘? [A4]); its menu search UNCONFIRMED on Apple pages | none | **Menu items** group for the window Search opened over, from `MenuBridge` (walk submenus with `aboutToShow`, capped); path "Edit › Find › Find Next", shortcut, toggle state; Return activates after focus returns. Also the T0 Help menu's search later (menubar.md:80). | M | Not stored, not logged, not in usage; only T1/T2 apps; the walk is capped in items, depth and time. | M1, M2, M3 |
| B6 | Spaces and displays commands | Previous/Next Space [R8] | Mission Control keys | stages, overview | **Go to Space n**, **Move Window to Space n**, **New Space**, **Mission Control**, **Display Settings**, **Mirror Displays** (when two), **Use as Main Display**: through `Displays.qml` and the stages/overview IPC. | S | — | S5 |
| B7 | Grassfield settings toggles | Toggle Appearance, Bluetooth [R12] | Control Center | Control Center | **Wi-Fi**, **Bluetooth**, **Airplane Mode**, **Do Not Disturb** (with "for 1 hour", "until tomorrow"), **Night Light**, **Dark Mode**, **Reduce Motion**, **Reduce Transparency**, **Dock Hiding**, **Stage Manager**-class toggle (Grassfield's name), **Menu Bar Hiding**, **Microphone mute**: one row each reading its state ("Turn Wi-Fi Off"), through the Control Center functions. | M | Same functions as Control Center; no new privileges. | S6, S7 |
| B8 | System state answers | no | partly (calculator-like inline answers) | none | Inline answers: "battery" (charge, time left, health), "wifi" (network, local IP), "ip" (local addresses only, D-net), "disk" (free space per mount), "memory", "uptime", "version" (Grassfield, Omarchy, kernel), "displays". | S | No public IP (D-net). | S8 |
| B9 | Colour picker (UNCONFIRMED in [R*]) | UNCONFIRMED | Digital Color Meter (app) | none | **Pick Color**: `hyprpicker` (at use time), copies hex; Actions: copy as rgb(), hsl(), QML; the last 20 colours kept (0600). | S | hyprpicker freezes the screen: refused under the lock. | S9 |
| B10 | Focus sessions blocking apps and sites [R15] | yes | Focus modes | Do Not Disturb, menu bar Focus | **Do Not Disturb for…** (B7). App and site blocking: not planned (no site control without a proxy; app blocking would fight the user). | — | — | S6 |
| B11 | Timers, reminders (UNCONFIRMED in [R*]) | UNCONFIRMED | Reminders app | none (Omarchy has a reminder flow: `/usr/share/omarchy/shell/plugins/reminders`, reference only) | **Timer** "timer 10 min tea": a notification at the end, listed in Notifications with Cancel; held by the shell (lost on logout: said in its row). Reminders with dates: not planned (no reminders store). | S | — | S10 |
| B12 | Calendar, My Schedule, join meeting [R13] | yes | Calendar | month grid widget only | Not planned: no event store on the system (§1.1). Would need a calendar data source (owner decision on a dependency) first. | — | — | — |
| B13 | Notes [R14] | yes | Notes, Quick Note | Memos app | **New Memo**, **Search Memos** (titles and first lines, read from Memos' store through its documented format, ADR-0051), opens the memo. | M | Memo text never stored by Search. | S11, S12 |
| B14 | Search Screenshots (UNCONFIRMED) | UNCONFIRMED | no | none | **Recent Captures** command once the capture suite's history exists (capture-suite.md H1, B15). | S | — | S13 |
| B15 | Translate [R22], Dictionary (UNCONFIRMED) | yes (Pro) | Dictionary in Spotlight [A1] | none | Translate: only through the local model (A3). Dictionary: not planned (no local dictionary installed; a new dependency). | — | — | — |
| B16 | Open Settings pages | — | yes | yes (search.md:80) | Unchanged; each page also gets Actions "Open", "Copy Link" not planned. | — | — | — |

### 2.3 Text: links, text replacements, clipboard, emoji

| # | Feature [source] | Raycast | macOS 27 | Grassfield today | Proposal | Effort | Security note | Slices |
|---|---|---|---|---|---|---|---|---|
| T1 | Quicklinks with `{argument}` and "open with" [R4] | yes | no | none | **Links**: name, target (URL, file, folder, or app + target), optional "Open With" app; placeholders (T4); a link with an argument shows the argument chip (N8). Create, edit, delete from Actions and Settings > Search > Links. Grassfield ships **no** web link and no web fallback (D-net); whether a user's own http(s) link may open is owner question Q-2. | M | Opened with `xdg-open` or the app's desktop entry (argv only). A `file:` target is checked to exist; `javascript:` and `data:` refused. | T2, T3 |
| T2 | Snippets: search and insert [R5] | yes | Text Replacements (System Settings > Keyboard) | none (settings.md:95) | **Text Replacements**: name, keyword, text (≤ 65 536 characters as [R5]); searchable in Search, Return inserts into the window Search opened over through the ADR-0034 targeted paste, copied **not recorded** by the history; edited in Settings > Keyboard > Text Replacements (macOS location) and from Actions. | M | Insertion reuses PV-14's rules; the copy carries the helper's own-copy marker and is never recorded. | T4, T5, E3 |
| T3 | Text expansion as you type (Immediately / After Delimiter, per-app exclusions) [R5] | yes | yes (Text Replacements in apps) | none | **Owner question Q-1 (ADR-0067).** Recommended: the compositor plugin matches keywords in the focused window and asks the shell to replace them; protected like the capture suite's keystroke display. | L | Observes typing: opus review, suppressed for passwords, sheets, lock, protected windows. | T6, T7, T8 |
| T4 | Dynamic placeholders `{clipboard}`, `{date}`, `{time}`, `{datetime}`, `{day}`, `{uuid}`, `{cursor}`, `{argument}`, `{snippet}`, `{calculator}`, modifiers, offsets, format, locale [R6]; `{selection}`, `{browser-tab}` [R6] | yes | no | none | `Placeholders.js` (pure): every [R6] placeholder except `{selection}` (D-4: shown before use, later), `{browser-tab}` (no browser extension) and `{clipboard offset=n}` (reads the history: refused, the history stays in its view). `{cursor}`: the caret is moved back with Left keys after the paste (one per character after it). | M | `{clipboard}` reads the current clipboard only when the user runs the item. | T1 |
| T5 | Clipboard history: retention, pins, types, search, OCR search, disabled apps [R7] | yes | yes [A3] | yes (ADR-0034) | Deltas only: **Paste as Text Replacement…** action; images' text search: not planned (would store recognised text); a per-app ignore list: not planned (PV-1 already drops password managers' hinted copies; more is an owner privacy call, not asked now). | S | — | T9 |
| T6 | Emoji & Symbols [R10] | yes | Character Viewer [A4] | panel (ES-1…ES-10) | Emoji rows in Search when the query is `:word` (macOS has none; Raycast has a command) inserting like the panel; skin tones: not planned (Omarchy's list has none). | S | Same insertion as ES-7. | T10 |

### 2.4 Calculator and conversions

| # | Feature [source] | Raycast | macOS 27 | Grassfield today | Proposal | Effort | Security note | Slices |
|---|---|---|---|---|---|---|---|---|
| C1 | Math, percentages [R9] | yes | yes [A1] | yes (Calc.js, `%`) | Unchanged. "15% of 85" phrasing ([A1] example) added if missing. | S | No eval (search.md:49). | C1 |
| C2 | Units [R9] | yes | yes [A1] | length, mass, temperature, data | Add speed, area, volume, time durations, pressure, energy, angles, number bases (hex, bin). | S | — | C2 |
| C3 | Currency, crypto [R9] | yes | yes [A1] | excluded (S4) | **Not planned (D-net):** rates need the network. | — | — | — |
| C4 | Dates and time zones: "time in tokyo", date math [R9] | yes | UNCONFIRMED | none | "time in Tokyo", "15:00 Paris in Tokyo", "monday + 3 weeks", "days until 25 Dec", "2026-12-25 - today", in en and fr. Zones from the system tzdata through `QTimeZone` (a small invokable in `Grassfield.Ui`, ui API changelog), city names from `zone1970.tab`. | M | — | C3, C4 |
| C5 | Calculator history [R9] | yes (3 months) | no | none | Last 50 answers, a "Calculator History" row; private file, cleared by Delete Search History. | S | Results can hold amounts: 0600, cleared with history. | C5 |

### 2.5 Files

| # | Feature [source] | Raycast | macOS 27 | Grassfield today | Proposal | Effort | Slices |
|---|---|---|---|---|---|---|---|
| F1 | File search, local index [R11] | yes | yes | yes (localsearch, plocate) | Unchanged. | — | — |
| F2 | Content search [R11] | optional | yes | localsearch content hits score 10 | Unchanged. | — | — |
| F3 | Actions on files: Open With, Show in Files, Copy Path, Quick Look, Move to Trash, Open in Terminal [R2] | yes | Quick Actions [A1] | Open, reveal | All through Actions (N3); Quick Look opens Glance (`QuickLook.js`); Move to Trash through `gio trash` (path checks as capture-suite A3). | S | P4 |
| F4 | .gitignore / .rayignore [R11] | yes | no | hidden segments excluded | Not planned (localsearch's own configuration). | — | — |

### 2.6 Extensibility

| # | Feature [source] | Raycast | macOS 27 | Grassfield today | Proposal | Effort | Security note | Slices |
|---|---|---|---|---|---|---|---|---|
| X1 | Script Commands (network for scripts: owner question Q-2): metadata header `@raycast.*` in `#` or `//` comments; required `schemaVersion` (1), `title`, `mode`; optional `packageName`, `icon`, `iconDark`, `currentDirectoryPath`, `needsConfirmation`, `refreshTime`, `argument1..3`, `author`, `authorURL`, `description`, `platform` [R16] | yes | no (Shortcuts app) | none | **Scripts** (owner decision D-ext): the same header is read (and `@grassfield.*` as an alias prefix); files in the user's script folders (D-3); one row per script. `.template.` files skipped [R16]. | M | Runs the user's own code: opus review of the runner. | X1, X2 |
| X2 | Output modes `fullOutput`, `compact`, `silent`, `inline` (+ `refreshTime` ≥ 10 s) [R16 OUTPUTMODES] | yes | — | — | fullOutput → detail pane (N10), streamed, ANSI SGR colours; compact → last line in the row's notice; silent → last line in a HUD after Search closes (the OSD); inline → first line as the row's subtitle, refreshed while Search is open, at most 5 inline scripts. Non-zero exit: failed, last line as the error [R16]. | M | Output capped (1 MiB, 2 000 lines), plain text. | X4, X5 |
| X3 | Arguments: `type` text, password, dropdown (`data` [{title, value}]), `placeholder`, `optional`, `percentEncoded`; at most 3; passed as `$1..$3` [R16 ARGUMENTS] | yes | — | — | N8's chips; values passed as argv (no shell). Password: dots, never logged, never in the unit's description. | S | argv is visible to the user's own processes (`/proc`): documented. | X6 |
| X4 | `needsConfirmation` [R16] | yes | — | — | A confirmation alert before each run. Plus, always, a **first-run approval** for a new or changed file (D-3). | S | — | X7 |
| X5 | Extensions and Store (React/TypeScript API) [R17] | yes | — | — | **Not planned (owner decision D-ext):** no third-party code distribution or store. | — | — | — |
| X6 | AI Extensions, @-mentions, tools [R18] | yes | Siri actions | — | Not planned: a model never calls tools or runs commands (D-4). | — | — | — |

### 2.7 Local AI (owner decision D-net: local model only, opt-in by its presence)

| # | Feature [source] | Raycast | macOS 27 | Grassfield today | Proposal | Effort | Security note | Slices |
|---|---|---|---|---|---|---|---|---|
| A1 | Local models through Ollama [R18 local-models, changelog 1.99.0] | yes (also a remote Ollama host) | — | none | Detection of Ollama on **loopback only** (127.0.0.1 or ::1, port 11434); remote hosts refused; models that run remotely through Ollama refused (spike A1 finds how to tell; UNCONFIRMED). | S | D-4 data rules; opus review. | A1 |
| A2 | Quick AI: question in the root search, Tab [R18 quick-ai] | yes (Pro) | Return sends the question to Siri AI [A1] | none | **Ask Local Model** row at the end of the results (and the fallback, N12) when a model is present; Return streams the answer into the detail pane (macOS 27 model: Return asks). Tab stays Actions (N3). | M | Sends only the typed text. | A2, A3 |
| A3 | AI Chat, continue a quick answer in a chat [R18] | yes | — | none | Follow-up questions in the same detail pane (a conversation), Actions: Copy Answer, Paste Answer, New Conversation. Kept in memory only unless "Keep conversations" is on (7 days, 0600). A separate chat window: not planned. | M | History off by default. | A4, A5 |
| A4 | AI Commands with `{selection}`, `{argument}`, output "Replace Selection" [R18 ai-commands] | yes | Writing Tools | none | Built-in prompts **Summarize**, **Improve Writing**, **Translate to…**, **Explain**, on `{clipboard}` or a typed argument; user-defined ones (name, prompt, placeholders). `{selection}` later and only through a visible "Selected text" chip showing what will be sent (D-4). Output: Copy or Paste (the targeted paste), never automatic. | M | Placeholders resolved only on the user's run; the exact text sent is visible. | A6, A7 |
| A5 | Model choice, settings | yes | — | — | Settings > Search > Local Model: on/off (on when present, owner), model, keep conversations, Clear. | S | — | E4 |

## 3. UX model (macOS 27 Spotlight structure, Raycast depth)

### 3.1 Entry points
- **Unchanged:** Super+Space and XF86Search open Search; Super+Ctrl+V opens the Clipboard view; Ctrl+Super+Space the Emoji &
  Symbols panel; the menu bar's search item.
- **New:** a Keyboard Shortcut per command (N7) opens nothing when the command needs no input: it runs (Raycast [R3]), with a
  HUD when the command has a visible result; a command with arguments opens Search on its argument chips.
- **Browse:** ⌘1 Applications, ⌘2 Documents, ⌘3 Actions (the commands view), ⌘4 Clipboard (P1 PRESS; ⌘3 [A2]).

### 3.2 Keyboard model

| Key | Action | Source |
|---|---|---|
| Type | query; a Quick Key match is first (N6) | [A2][R3] |
| ↑ ↓ | move the selection | search.md S6 |
| Return | primary action | [R2][A1] |
| Ctrl+Return | secondary action (reveal, today) — ⌘↩ is Super+Return, the Terminal key (`bindings.lua:248`) | search.md S6 |
| **Tab** | **Actions of the selected row** (macOS 27: "select a result and press Tab" [A1]). Changes search.md S6, where Tab moves between groups | [A1] |
| ⌘K (Super+K, unbound in bindings.lua; Ctrl+K as a fallback) | Actions (Raycast [R2]) | [R2] |
| Page Down / Page Up, Ctrl+↓ / Ctrl+↑ | next / previous group (was Tab) | delegated, ADR-0067 |
| Shift+Tab | focus ring to the chips (as today past the first group) | search.md F2c |
| Esc | close Actions, else pop a detail view, else clear, else close | [R1][A2] |
| Backspace on an empty field | pop one level (detail, Clipboard view) | [R1], search.md |
| In argument chips: Tab / Shift+Tab | next / previous argument | [A2] "fill in its fields" |
| In Actions: type, ↑ ↓, Return, Esc; each action's own chord shown at the right (`MenuShortcut.label`) | [R2] |

Slice P3 proves in nested that Super+K reaches the Exclusive layer (no Grassfield or Omarchy bind takes it) before it is
listed; if it does not, ⌘K is not offered and Tab alone opens Actions.

### 3.3 Actions panel
- A glass list of the `menu` class (the PopupMenu used by the clipboard row menu, SearchPanel.qml:1165) anchored to the
  selected row's right side, with a filter field at its top when it has more than 7 actions (Raycast's searchable panel [R2];
  macOS 27 shows a short list).
- Order: the primary action first (with ↩), the secondary (with ⌃↩), then the kind's actions, a separator, then **Add to
  Favorites**, **Add Quick Key…**, **Keyboard Shortcut…**, **Reset Ranking**. Destructive ones last, in the destructive colour.
- Per kind (`Actions.js`): app (Open, Show in Files, Quit, Hide, Force Quit, New Window when the entry has the action, Open
  Desktop Actions), file (Open, Open With ›, Show in Files, Quick Look, Copy Path, Copy, Move to Trash), command (Run), window
  (Focus, Close, Minimize, Move to Space ›, Move to Display ›), link (Open, Open With ›, Copy URL, Edit, Delete), text
  replacement (Paste, Copy, Edit, Delete), script (Run, Show in Files, Edit Script, Copy Command, Forget Approval), calculator
  (Copy, Paste, Copy Expression), clipboard (unchanged: CB-8 menu), menu item (Choose), model answer (Copy, Paste, Ask
  Follow-up, New Conversation).

### 3.4 Layout, glass and tokens (ADR-0024; master-prompt §5.5)
- The capsule and panel are unchanged (search.md: 520 wide, rows 63, Inter 17/15). The detail pane takes the clipboard
  preview's place and width (tokens `search.detail*` derived from the existing `search.clipPreview*` and `search.clipPage*`), so the window grows the way
  the Clipboard view already does.
- Argument chips sit inside the capsule after the command title: the filter chips' geometry and fill (`search.fieldInset`, `search.chipBottom`, `colors.chipFill`), a placeholder in the
  secondary text colour, a password chip with dots.
- Rows: Quick Key shown as a key cap at the row's right (the menu shortcut style), an inline script output as the subtitle, a
  toggle row shows its state word ("On", "Off") in the secondary colour, never a switch control (macOS lists actions as rows).
- Glass: the panel's existing material and blur region; the Actions list and argument chips use existing material classes
  (`menu`, `control`), nothing new; A2 holds at every transparency ≤ 0.6 (`just check-contrast`).
- Motion: the Actions list opens with the menus' timing; Reduce Motion fades in ≤ 100 ms. Every value is a token; `just
  check-literals` holds.
- French: every string in en and fr (`ui/i18n`), command keywords in both languages plus English always (Search's rule for
  commands, Search.qml:284).

### 3.5 Accessibility
Each row has an accessible name with its kind ("Wi-Fi, command, On"); the Actions list is a menu (role menu, items with their
shortcut); argument chips are text fields with their placeholder as name; the detail pane is a read-only text area.

## 4. Slice plan

Each slice is at most one day for one writing agent in its own worktree. Levels: **L0** pure-JS or helper fakes, **unit** QML
TestCase or C++ gtest, **L1** nested at scale 1.25 with a screenshot path or "visual NOT verified", **L2** the owner. Every
slice runs `just check-quick`, the tests it touches, `just check-inventory` for new tests, and gitleaks over its range.

### 4.1 Slices by lane

**Lane P: palette core** (`shell/search/`)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| P1 | `Commands.js` registry (pure): entry schema, id rules (`[a-z][a-z0-9.-]{0,63}`), providers, availability, keyword matching reusing `Ranking.textScore`; the five existing commands moved into it unchanged. | — | Unit `tst_searchcommands.qml`: schema validation, duplicate ids refused, en/fr keywords, the 5 commands' rows equal today's (`tests/shell/search_locale` unchanged). |
| P2 | Search.qml reads the registry (Commands group, Top Hit) and `runCommand` dispatches by id; no visible change. | P1 | `tests/shell/search_chips`, `search_locale` pass unchanged; unit: dispatch table. |
| P3 | `Actions.js` (pure) per kind + the Actions panel (Tab, ⌘K, filter field over 7, Esc); search.md S6 and F2c amended (groups on Page Down/Up and Ctrl+↓/↑). | P2 | Unit `tst_searchactions.qml`: actions per kind, order, shortcuts, destructive last; key map. L1: Actions over an app row and a file row at 1.25 (screenshot); Super+K reach proved or ⌘K withdrawn. |
| P4 | File and app actions: Open With ›, Show in Files, Quick Look (Glance), Copy Path, Move to Trash (path checks), Quit, Hide, desktop actions. | P3 | Unit: argv per action, a link or folder refused for Trash; L1: Open With submenu screenshot. |
| P5 | Quick Keys: store, matcher (exact, prefix, rest as argument), Add Quick Key… sheet. | P3, E1 | Unit: match order vectors from [R1]; invalid keys refused; L1 screenshot of the key cap. |
| P6 | Favorites strip (empty field, reorder by drag and by Actions Move Up/Down) and Reset Ranking; usage file gains `cmd:` keys (version 3, v2 migrated). | P3 | Unit `tst_searchranking.qml`: v2→v3 migration, reset per id, menu ids never recorded; L1 empty-field screenshot with and without favorites. |
| P7 | Keyboard Shortcut… recorder: chord capture, collision check against the parsed `bindings.lua`/`forwarding.lua` (`Bindings.js`) and Omarchy's, slots `k1`…`k99`. | P3 | Unit: collisions refused, slot allocation, the chord's label. |
| P8 | Generated binds file and its loader (ADR-0067 D-2) + `Shortcuts.js` `search: {run: ["word"]}` + IPC `run(slot)`; Settings > Keyboard > Keyboard Shortcuts lists them. | P7 | Unit `tst_shortcuts.qml`: `run` accepted with a slot word only; generator vectors with hostile titles produce no Lua outside string literals (fuzz 1 000 cases); `tests/security/ipc_inventory.sh` updated; L1 nested: a bound chord runs Toggle Dark Mode. |
| P9 | Argument chips model (pure): types, required/optional, dropdown data, percent-encoding. | P1 | Unit: [R16] ARGUMENTS vectors; password values absent from every log and model dump. |
| P10 | Argument chips UI in the capsule, Tab between them, Return runs. | P9 | L1 screenshot with three chips at 1.25; unit key map. |
| P11 | Detail view stack (push/pop, Esc/Backspace), plain text pane, Copy. | P3 | Unit: stack transitions; L1 screenshot. |
| P12 | ANSI SGR subset parser (pure) and monospace streaming view (caps 1 MiB, 2 000 lines). | P11 | Unit: SGR colours mapped to tokens, every other escape stripped (OSC 8 links, cursor moves), caps. |
| P13 | ⌘1, ⌘2, ⌘3 browse views on the chips. | P2 | Unit `ClipboardView.opensView`-style key tests on AZERTY scan codes; L1. |
| P14 | Fallback rows on no results (Search Files for, Ask Local Model when present, Create Link / Text Replacement). | P11, (A2 for the AI row) | Unit: rows per state; L1 screenshot. |

**Lane S: built-in commands** (`shell/search/Commands*.js` providers, calling `shell/services/*`)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| S1 | System commands batch (B1). | P2 | Unit: each id calls the expected service function (fakes); Empty Trash asks; nothing runs while locked. |
| S2 | Quit All Applications…, Hide Others, Force Quit… (B2). | P2 | Unit with fake toplevels; the dialog lists apps; L1. |
| S3 | Window commands (B3) on the remembered window; greyed without the plugin features. | P2 | Unit: places map to `windows tile` args; dropped when the address closed; L1 nested with the plugin. |
| S4 | Windows provider (B4). | P3 | Unit: rows from a fake toplevel list; titles never in `search-usage.json`; L1. |
| S5 | Spaces and displays commands (B6). | P2 | Unit with fake displays; L1 with two nested outputs (or NOT VERIFIED). |
| S6 | Toggles batch 1: Wi-Fi, Bluetooth, Airplane, Do Not Disturb (+ for 1 hour / until tomorrow), Night Light (B7, B10). | P2 | Unit: title follows state ("Turn Wi-Fi Off"); calls the Control Center functions; DND expiry restores. |
| S7 | Toggles batch 2: Dark Mode, Reduce Motion, Reduce Transparency, Dock Hiding, Menu Bar Hiding, Stage Manager-class toggle, Microphone. | S6 | Unit as S6; `tests/ci/ui_names.py` passes on the new strings. |
| S8 | System state answers (B8). | P2 | Unit: answer text from fake services, en/fr; no network call (grep test: no `http` in the provider). |
| S9 | Pick Color (hyprpicker at use time) and colour history. | P3 | Unit: argv, hex parsing, formats; absent tool hides the row; refused under the lock. |
| S10 | Timers (B11). | S1 | Unit: parse "10 min", "1h30", "10 minutes thé"; notification at end (fake clock); Cancel. |
| S11 | New Memo, Memos provider read of the store (ADR-0051 format, read-only, size caps). | P2 | Unit with a fixture store; malformed store gives no rows. |
| S12 | Search Memos rows and open. | S11 | L1 screenshot. |
| S13 | Recent Captures command. | capture-suite B15 | Unit: runs `grassfield-screenshot --history`. |

**Lane M: menu items** (`shell/platform/MenuBridge.qml`, `shell/search/`; bridge unchanged unless M1 shows otherwise)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| M1 | Spike: walk a real DBusMenu tree through `aboutToShow` in nested (Qt app, Chromium, Firefox), measure items and time, check side effects; decide shell-side walk vs a bridge `layout` request (menu/1 additive). Report in the spec. | — | Spike report with numbers; no code merged unless trivial. |
| M2 | Menu items provider: capped walk (depth 4, 500 items, 300 ms, 50 rows shown), path labels, shortcut, toggle state; Return activates after FocusReturn. | M1, P2 | Unit with a fake MenuBridge tree: caps, disabled items, separators skipped, labels mnemonic-stripped (`_File`); activation only for the remembered window. |
| M3 | Privacy and degradation: no record in usage, no log of labels; T0 apps show nothing; bridge absent shows nothing. | M2 | Unit; grep test on logs in `tests/shell/search_menu` (new). L1 nested with a Qt test app. |

**Lane T: text** (`shell/search/Placeholders.js`, `Links.js`, `TextReplacements.js`; `apps/settings/` pane; `compositor/` for T6)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| T1 | `Placeholders.js` (pure): every supported [R6] placeholder, modifiers chain, offsets, format, locale; unknown placeholders left as written. | — | Unit `tst_placeholders.qml`: [R6] examples verbatim, offsets with no space after the sign, `format` and `locale` exclusive, `json-stringify`. |
| T2 | Links store (`commands.json`, JsonSafety caps) + provider + run (xdg-open / app). | T1, E1 | Unit: scheme allow-list (http, https, file, mailto, app targets), `javascript:` and `data:` refused, percent-encoding of arguments. |
| T3 | Links create/edit sheet in Search and Settings > Search > Links list. | T2 | L1 screenshots; unit form validation. |
| T4 | Text Replacements store + provider + insert through the targeted paste, not recorded. | T1, E1 | `tests/shell/search_clipboard`-style test: the copy carries the own-copy marker; the history records nothing; insert refused when the window closed (PV-14 vectors). |
| T5 | `{cursor}`: Left keys after the paste, in the same compositor call. | T4 | Unit: key count from the text after `{cursor}` (grapheme clusters); L1 nested into a Qt text field. |
| T6 | Spike (only after the owner's Q-1 answer): text-input-v3 purpose and hints seen by the plugin per toolkit (GTK 4, Qt 6, Chromium, Firefox, foot); keysym→UTF-8 through the xkb state; compose and IME cases. | Q-1 | Spike report; nothing merged. |
| T7 | Plugin matcher (per Q-1, recommended option): ring buffer per focused surface, suppression rules, `expand` event with the keyword id only. | T6 | Plugin gtest for each suppression case; gates C1–C3; opus reviewer PASS. |
| T8 | Shell expansion: delete the keyword (BackSpace ×n) and paste the replacement in one compositor call to the address; Immediately / After Delimiter; per-app exclusions. | T7, T4 | Unit: the call's key sequence; refused under the lock and when the address changed; L1 nested in a Qt and a GTK field; opus reviewer PASS. |
| T9 | Clipboard row action "Save as Text Replacement…". | T4 | Unit: menu ids; the history item is copied into the store only on the user's action. |
| T10 | `:word` emoji rows in Search inserting like ES-7. | P2 | Unit with `tests/fixtures/emojis.json`. |

**Lane C: calculator** (`shell/search/Calc.js`, `Units.js`, new `DateCalc.js`; `ui/Grassfield` for zones)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| C1 | "x% of y", "y + x%", "x% off y" phrasings (en, fr). | — | `tst_searchcalc.qml` vectors. |
| C2 | New unit families and number bases. | — | `tst_searchunits.qml` vectors, French names. |
| C3 | `Grassfield.Ui` `TimeZones` invokable (QTimeZone, city table from `zone1970.tab`), ui API changelog line. | — | gtest/unit; `just check-contracts` (ui_api). |
| C4 | `DateCalc.js` (pure): time in a city, a time between zones, date math, days until, in en and fr. | C3 | Unit vectors including DST changes (not run inside the DST fall-back hour: memory "DST SystemClock spin"). |
| C5 | Calculator History row and file, cleared with Delete Search History. | P11 | Unit: 50 entries, 0600, clearing. |

**Lane X: scripts** (`shell/search/ScriptMeta.js`, `shell/search/Scripts.qml`, `packaging/bin/grassfield-script-run`)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| X1 | `ScriptMeta.js` (pure) parser: first 64 lines or 8 KiB, `#` and `//` comments, `@raycast.` and `@grassfield.` keys, required fields, values validated, argument JSON, unknown keys ignored, `platform` only `windows` hides it. | — | Unit `tst_scriptmeta.qml`: [R16] README and ARGUMENTS examples verbatim, malformed JSON, 4 arguments refused, a 9 KiB header. |
| X2 | Discovery: folders from settings (default `$XDG_DATA_HOME/grassfield/script-commands/`, created on "Open Scripts Folder"), checks (regular file, owned by the user, not group/world-writable, executable, ≤ 256 KiB, folder not group/world-writable, a link only to a file passing the same checks), watch for changes. | X1, E1 | Shell test with a temp folder: each refused case; `.template.` skipped; changes picked up. |
| X3 | `grassfield-script-run` (Python stdlib, `-I`): `systemd-run --user --wait --pipe --collect --quiet --description=<fixed>` with limits, inside `bwrap` per ADR-0067 D-3 (network per the owner's Q-2 answer, Grassfield private stores hidden); stdout/stderr capped; exit status; kill on timeout and on lock. | X2 | L0 with fake systemd-run and bwrap: argv exact; the description never contains arguments; env scrubbed; timeout kills; lock kills; caps. L1 nested: a real script prints. Opus reviewer PASS. |
| X4 | Modes compact and silent (row notice, HUD), exit status handling. | X3, P11 | Unit: last line selection, failure text; L1. |
| X5 | Modes fullOutput (streamed into the detail pane) and inline (refresh while open, ≥ 10 s, ≤ 5 scripts). | X4, P12 | Unit: refresh scheduler stops when Search closes or locks; L1 screenshot. |
| X6 | Arguments wired (chips → argv), percent-encoding, password handling. | X3, P10 | L0: argv; password absent from journal (`journalctl --user` scan in the test unit), the unit's description, and every Grassfield log. |
| X7 | First-run approval (hash of the file), `needsConfirmation`, Forget Approval. | X3 | Unit: changed file asks again; imported settings never carry approvals; opus reviewer PASS (with X3). |

**Lane A: local AI** (`shell/search/LocalModel.qml`, `AiPrompt.js`)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| A1 | Spike + detection: loopback only, `/api/version` and `/api/tags`, cached 60 s, cloud/remote models excluded (method established in the spike from Ollama's API docs), absent → nothing shown. | — | Unit with a fake responder (XHR mocked): a non-loopback URL is impossible to configure; remote models dropped; timeouts. Spike notes in the spec. Opus review with A2. |
| A2 | Ask Local Model row + streaming answer into the detail pane (NDJSON over XHR), Stop, Copy, Paste. | A1, P11 | Unit: stream parser (partial lines, errors); the request body contains exactly the typed text; aborted on close and on lock. L1 with a fake local server (sandbox-local). |
| A3 | Answer actions and the fallback row. | A2, P14 | Unit. |
| A4 | Conversation in the pane (follow-ups), memory only. | A2 | Unit: context window cap, New Conversation clears. |
| A5 | Keep conversations (7 days, 0600 store, Clear). | A4, E4 | Unit: retention pruning, modes, clear. |
| A6 | Built-in AI commands (Summarize, Improve Writing, Translate to…, Explain) on `{clipboard}` or an argument, with the "text to send" chip shown before sending. | A2, T1 | Unit: prompts built from templates; nothing sent until Return on the chip view. Opus review. |
| A7 | User-defined AI commands (name, prompt, placeholders) in `commands.json`. | A6 | Unit: placeholders resolved only at run; export excludes nothing secret (no history). |

**Lane E: settings and schema** (`config/schema/grassfield.schema.json`, `apps/settings/`)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| E1 | Schema keys (ADR-0067 D-8) and the `commands.json` v1 format with its validator. | — | Schema tests: defaults, enums; validator vectors (oversize, wrong types). |
| E2 | Settings > Search: Scripts folders (Add Folder…, Open Folder), show Menu Items, show System State, Links list entry. | E1 | `tst_settingssearch.qml` extended; L1 screenshot. |
| E3 | Settings > Keyboard > Text Replacements (macOS pane: table Replace / With, +, −). | E1, T4 | Unit for the model; L1 screenshot en and fr. |
| E4 | Settings > Search > Local Model (on/off, model, keep conversations, Clear). | E1, A1 | Unit; L1. |
| E5 | Export Commands… / Import… (and Raycast snippet and quicklink JSON import). | E1, T2, T4 | Unit: round trip; Raycast fixtures map; approvals and history never exported. |

### 4.2 Waves (owner-visible value first) and parallel lanes

| Wave | Lane P | Lane S | Lane M | Lane T | Lane C | Lane X | Lane A | Lane E |
|---|---|---|---|---|---|---|---|---|
| 1 | P1, P2 | — | M1 | T1 | C1, C2 | X1 | A1 | E1 |
| 2 (commands, actions) | P3 | S1, S3, S6 | — | T2 | C3 | X2 | — | — |
| 3 (depth) | P4, P5, P11 | S2, S4, S7, S8 | M2 | T3, T4 | C4 | X3 | A2 | E2 |
| 4 | P6, P7, P9, P12 | S5, S9, S10 | M3 | T5, T9 | C5 | X4, X6 | A3, A4 | E3 |
| 5 | P8, P10, P13, P14 | S11, S12 | — | T10 | — | X5, X7 | A5, A6 | E4 |
| 6 | — | S13 (after capture B15) | — | — | — | — | A7 | E5 |
| last | — | — | — | T6, T7, T8 (after the owner's Q-1) | — | — | — | — |

Rules: within a wave each lane runs its slices in the order listed; a slice depends only on earlier waves of other lanes or
earlier slices of its lane. P3 is the first owner-visible change (Actions on every row) and lands with S1, S3 and S6 in wave 2,
so the first merged weeks already give: Actions, every system command, window commands and the main toggles.

**Running beside the capture suite (owner decision D-when).** The capture suite's lanes (capture-suite.md §4) touch
`shell/capture/`, `packaging/bin/grassfield-capture`, `apps/screenshot/`, `compositor/` (D1–D3) and the schema. This plan's lanes
touch `shell/search/` (P, S, M, T, C, X, A), `shell/platform/` (P8, M), `apps/settings/` (E) and the schema. With the "one writing
agent per worktree" rule, three palette lanes (P, S, then T or X) can run beside the capture's three without touching the same
files except those in the table below.

### 4.3 Shared files (one slice at a time on each)

| File | Edited by (this plan) | Also edited by |
|---|---|---|
| `config/schema/grassfield.schema.json` | E1 (and E2–E4 additions) | capture suite A, B18, C |
| `shell/search/Search.qml`, `SearchPanel.qml` | lane P; S, M, T, X, A only through provider registration in P2's hook | — |
| `shell/platform/shortcuts/Shortcuts.js`, `docs/specs/security.md` (IPC surface) | P8 | — |
| `config/hypr/grassfield/bindings.lua` (loader line) | P8 | capture A4 (Shift-Super-2) |
| `shell/platform/MenuBridge.qml`, `bridges/menu-bridge/` | M1–M3 | — |
| `compositor/` | T7 | capture D1–D3 |
| `packaging/arch/PKGBUILD` (the runner script, `ollama` optdepend line) | X3, A1 | capture B1, B21, B22 |
| `ui/Grassfield/` (+ `docs/specs/ui-api.md` changelog) | C3 | — |
| `apps/settings/` | E2–E5 | capture B19 (app settings live in the Screenshot app: no overlap expected) |
| `docs/specs/search.md` | P3 (keys), P13, P14 | — |

### 4.4 Review rules
Following the owner's "review every step" rule: an independent reviewer pass after each merged slice. **Opus security review**
(PASS required) for:
- **anything that runs scripts:** X3, X6, X7 (runner, argument passing, approvals);
- **anything that reads the clipboard or the selection:** T1 (`{clipboard}`), T4, T9, A6, A7;
- **text expansion and keystroke injection:** T5, T7, T8, and P8 (the generated binds file and the new `search run` request);
- **AI prompts with local data:** A1, A2, A6, A7 (loopback-only, what is sent, history);
- **menu activation for another app:** M2 (activation only for the remembered window).
T7 also goes through the compositor gates C1–C3. Nested L1 runs follow the memory rule "nested verifiers need their own worktree".
