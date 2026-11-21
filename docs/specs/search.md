# Search spec · shell-engineer · M2

## macOS reference behavior (described in words)
- `Cmd+Space` opens a centered floating search field (~680 pt wide, ~1/4 from the top), large type
  (~22 pt), magnifier glyph, material background, rounded ~26 pt.
- Typing shows results below, ordered by group (Top Hit, Applications, Documents, Folders, Settings,
  Calculator/Conversion inline answers) without group headers (macOS 27). Arrow keys move, Return opens, Cmd+Return
  reveals in Files, Esc clears then closes. The top hit is preselected and drawn on a neutral light fill, not the accent.

## Purpose and non-goals
Providers: apps (DesktopEntries), Grassfield settings pages, calculator, unit conversion, commands
(lock, sleep, restart… as real actions), files (localsearch/TinySPARQL via `localsearch` CLI or D-Bus;
`plocate` fallback), recent documents (`~/.local/share/recently-used.xbel`, read when it changes, a second after the last write, not on each opening; the newest `Files.MAX_RECENT` (400) kept; audit B-20). Non-goals: own indexer, web search.
The clipboard history (⌘4, the Clipboard view) has its own spec: `docs/specs/clipboard.md` (ADR-0034).

## Functional requirements
1. S1 Open/close via IPC `search toggle` (bound to SUPER+SPACE) within 100 ms warm (P4).
2. S2 App results ≤ 50 ms per keystroke on 300 desktop entries; fuzzy + prefix ranking, usage boost.
3. S3 Calculator: arithmetic, parentheses, %, ^, constants; result copyable with Return (clipboard via wl-copy).
4. S4 Units: length, mass, temperature, data sizes; currency excluded (needs network).
5. S5 Files: query localsearch asynchronously (max 20 results, ≤ 300 ms on 100k files), cancel stale queries.
6. S6 Keyboard: ↑/↓, Tab between groups, Return open, Ctrl+Return reveal in Files, Esc clear/close.
7. S7 Results show icon, name, subtitle (path/category); no network calls.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| S2/S3/S4 | QML TestCase for ranking, calculator parser, unit converter | L0 |
| S1/S2 | timestamped log scenario in nested | L1 |
| S5 | `localsearch` provider latency test on the owner's index | L2† |

## Calculator and conversions in the session's language
`Calc.js` and `Units.js` take the session's `Qt.locale()` (`Numbers.js` holds the shared reading and writing): a decimal comma
and grouping spaces are read ("2,5 km en m", "1 000 + 5"; in English a comma between groups of three is grouping), the answer is
written with the language's decimal point and grouping ("19 560", "15,5343 mi"), conversions round like Spotlight (4 decimals
from 1 up, the integer part never rounded, 4 significant digits below 1; exponent form beyond 1e15 and under 1e-6), the
connectors are in, to, as, -> everywhere and also en, vers in French, and French unit names (kilomètres, pouces, pieds, livres,
onces, grammes, octets, Ko, Mo, Go, Kio…) are understood. A command and a Settings page of the same title are one row (the
command); in French the Settings page reads "Écran verrouillé" and the command "Verrouiller l’écran". Tests: `tst_searchunits`,
`tst_searchcalc`, `tests/shell/search_locale`.

## Known limitations
- File results depend on localsearch indexing settings of the user.

## Implementation notes (v1, `shell/search/`)
- Files: `Calc.js`, `Units.js`, `Ranking.js`, `Files.js` (pure, unit-tested in `tests/unit/tst_search*.qml`), `Search.qml` (state, providers, activation, IPC), `SearchPanel.qml` (layer-shell window `grassfield-search`, keyboard exclusive, blur region, one per screen, shown on the focused screen).
- IPC target `search`: `toggle()`, `open(text)`, `close()`, `query(text)` (sets the query without opening), `status()` (JSON of visible groups).
- Groups: Top Hit (best app, else command, else document; absent when an inline answer exists), Calculator, Conversion, Applications, Commands, Documents, Recent. An empty query shows no results at all (macOS Tahoe: the field alone until the first keystroke; there is no browse row to keep); documents, recent ones included, appear from the first keystroke.
- Calculator never uses eval/Function: own tokenizer and recursive-descent parser, depth limit 250, input limit 200 chars, function/constant lookup by `switch`.
- Files: `localsearch search -f -l 60 -- term`, then `plocate -i -b` when localsearch returns nothing or is unusable (on the dev machine `localsearch status` reports 0 files indexed, so plocate answers). Results are limited to `$HOME` and exclude hidden path segments. The 60 candidates (`Ranking.FILE_CANDIDATES`) are ranked (see "File ranking") and the best `Tokens.searchMaxFiles` (20) are shown. argv arrays only, wrapped in `timeout 2`, stale queries ignored by sequence number. Dev knobs: `GRASSFIELD_SEARCH_ROOT`, `GRASSFIELD_SEARCH_PLOCATE_DB`.
- Usage boost: `$GRASSFIELD_STATE_HOME` or `$XDG_STATE_HOME/grassfield/search-usage.json`, mode 0600, directory 0700, at most 500 apps (by desktop id) and, capped apart so they never push the apps out, 200 files opened from Search (`file:<path>`), the most recent of each kind. Version 2 (2026-11-05): each entry is `{count, last, weight}`; a pick adds 1 to the weight decayed since the last pick (half-life `USAGE_HALF_LIFE_DAYS` = 14 days, weight capped at 50, a decayed weight under 0.01 counts as nothing) and the boost is `min(20, 5·log2(1 + decayed weight))`, so it fades when an app or a file is no longer used. A version 1 file (`{count, last}`) is migrated on read (weight = count, capped, decaying from its last pick); the next pick writes version 2. A newer version is read as empty.
- File ranking (2026-11-05): the Documents group orders the provider's candidates with `Ranking.rankFiles` (pure,
  `tests/unit/tst_searchranking.qml`), on the scale of the app scores. Inspired by Project Luma's luma-search ranking
  (Apache-2.0; mechanism only, no code copied).
  - Text: the best of the whole name and the name without its extension (`textScore`: 100 exact, 80 prefix, 65 word prefix,
    50 substring, ≤25 fuzzy); a query of several words matches when every word does (0.8 of the weakest); a file found by
    its content only (localsearch) scores 10.
  - Junk names, at most 40 in all: an editor backup (`name~`, `#name#`) 26; a backup extension (`.bak .old .orig .tmp .swp
    .swo .part .crdownload .rej`) 26; a duplicate mark (`(2)`, ` copy`, ` copy 3`, ` - Copy`, ` (copie)`, ` - copie 2`) 20;
    the first junk word of the name (camelCase and digits split words), English and French: backup(s)/bak/bck/bkp/copy/tmp/
    autosave/sauvegarde(s)/copie 22, old/temp/conflicted/temporaire(s)/conflit 20, orig/ancien(ne)(s) 18, stale/obsolete/
    vieux/vieille/périmé 16, archived 12. A word or extension the query touches is not junk (a search for "backup" wants the
    backups).
  - Location: below the home, two levels are free (`~/Documents/a.txt`) and each further level costs 3 (at most 18); a path
    outside the home costs 12; a generated, cache or hidden folder on the way (node_modules, __pycache__, cache, build,
    builddir, _build, dist, target, obj, venv, site-packages, vendor, deps, cmakefiles, rpmbuild, buildroot, tmp, temp,
    bower_components, __macosx, `.anything`) costs 45. The result's own name is not judged as a folder (a folder named
    "build" answers "build").
  - XDG folders: +20 for one of the user's Desktop, Documents, Download, Music, Pictures, Videos folders, +8 for what lies in
    one. They are read from `$XDG_CONFIG_HOME/user-dirs.dirs` (`Files.parseUserDirs`, followed live), so they carry the
    user's language ("Téléchargements"); without that file no folder is favoured (no English name is assumed); a folder set
    to the home itself (xdg-user-dirs' "off") is ignored.
  - Usage: the decayed boost above, for the files opened from Search (Documents or Recent, `file:<path>`). Delete Search
    History forgets them with the apps.
  - Order: score, then the shorter path, then code unit order. Cost (S2/P4): `test_filePerformanceOn300Paths` ranks 300
    paths with 50 usage records in about 6 ms in the container (limit 50 ms); it runs once per file answer, not per
    keystroke. The app ranking with a usage record per app (`test_performanceOn300Entries`) stays about 2.5 ms per keystroke.
- Apps: entries with NoDisplay, or hidden by OnlyShowIn/NotShowIn for `$XDG_CURRENT_DESKTOP`, are not listed. Search uses the same list as the Apps window (`Apps.isListed()` in `shell/services/Apps.qml`, fed by `launchpad/hidden-entries.sh`); the list is rebuilt, debounced, when desktop entries change and Search re-ranks on `Apps.listChanged`.
- Commands: Sleep, Restart, Shut Down, Log Out reuse `Power` and the confirmation dialogs. Lock Screen (REQ-SRCH-PRV-d2) locks through the lock module (`Lock.lock("search")`, the singleton behind the `lock` IPC target of shell/security/lock; the System menu calls the same function); `Search.lockAvailable` is true.
- Settings pages provider (REQ-SRCH-PRV-d1, macOS model: Spotlight lists System Settings panes): typing a page name or one of its keywords (title scores like a command, keywords at 0.8 of that) lists the page in a "Settings" group (also as Top Hit when it beats the best app and command) and Return opens Grassfield Settings on it (`SettingsApp.openSection(id)`, `grassfield-settings --section=<id>`). Pure matching in `shell/search/SettingsPages.js` (page ids = the Settings sections); a fourth filter chip "Settings" joins Applications, Commands and Documents. Test: `tests/unit/tst_searchsettings.qml`.
- The results list is keyed (`Search.rowModel`, `KeyedRows.js`): a result that stays from one keystroke to the next keeps its row delegate, only new results make one (audit B-05). The panel's height glides, its glass judged over its height at rest.
- Rows (ADR-0024 lot 2, macOS 27 Spotlight; measured in `docs/audits/visual-tahoe-2026-10-25.md` § Search — partly close, 6/10
  and `docs/audits/ui-finesse-2026-10-25.md` § 7.1 macOS 27 changed the target): one row per result, no header rows (the groups
  still order the list, Tab moves between them and `status()` reports them); 17 / 15 type (Inter sizes with the cap height of
  macOS's 17.7 / 15); rows 63 tall (two lines), the 36-pt icon 26 and the title and subtitle 80 from the panel edge; the
  selected row 12 from the panel sides, radius 18, a neutral fill (`colors.fill` at `search.selectionFillOpacity`, ordinary
  text colours, inside the A2 material fill overlay).
- Capsule (macOS 27, owner decision 2026-10-26; `docs/audits/ui-finesse-2026-10-25/f1-macos27.md` § Search): the query sits in
  a glass capsule (`search.capsule*`: 520 x 85, fully round, top at 0.157 of the screen, the 26-pt magnifier 32 and the query
  at 22 pt, Inter Display, 75 from its edge), with its own blur region. The chips and results come in a 520-wide panel
  (`search.width`) `capsuleGap` 11 under it, chips 20 from its top and 20 from its sides; the panel exists only when it has
  something to show (chips, results or "No Results").
- Latency is logged by the shell: `search open->visible N ms` (IPC call to first frame) and `search keystroke->results N ms`.

- Filter chips (F2c): with a query that has results in two or more of Applications, Commands and Documents (files and recents), a chip row sits under the field (`Filters.js`; the capsule is the Apps category chip). A click narrows the results to that kind (the Top Hit joins its kind; inline answers are hidden) and a second click clears it; a new query clears it. IPC `search filter <apps|commands|documents|"">` is the test hook. The field keeps the text focus; the chips are reachable by keyboard: Tab past the last result group (Shift+Tab before the first) moves the focus ring to the first (last) chip, Left/Right/Home/End move along them, Space or Return selects or clears, Esc or Tab past the end returns to the field, and any other key (typing, Up, Down) leaves the chips and acts on the field. The ring is the shared outside accent ring (`control.focusOutline`). Test: `tests/shell/search_chips`. The `filter` hook answers only in a visual fixture session (`VisualFixtures.active`).
- No-results notice: a non-empty query that nothing answers, once the file search settled (`filesPending`: the debounce timer and every live `localsearch`/`plocate` process, so the plocate fallback is waited for), shows "No Results for ...", centred under the field.
- Clipboard view (ADR-0034, `docs/specs/clipboard.md`): ⌘4 in the field (Super+4, forwarded as Ctrl+4), the Clipboard button right of the empty field, or Super+Ctrl+V (IPC `search clipboard`, opening only through `show()`) switch the same window to the clipboard history: the clipboard symbol and "Clipboard" in the field, the More button, the history's rows, the row and More menus and a preview panel beside the results. Backspace in the empty field returns to the results. Test: `tests/shell/search_clipboard`.

## Limitations (v1)
- Ctrl+Return reveals with `gio open <parent folder>` (default file manager) until Grassfield Files exists (M4).
- localsearch output parsing (`file://` URIs per line) could not be verified against real results: nothing is indexed on the dev machine.

## Settings > Search (2026-10-26)
Settings > Search (macOS 27's Spotlight pane) chooses which kinds of results Search shows: `search.showApps`,
`showDocuments` (no `localsearch`/`plocate` process runs while it is off, and the results already in are dropped),
`showRecents`, `showCalculator`, `showConversions`, `showSettings`, `showCommands`; a kind turned off never shows, the Top Hit
included. Delete Search History writes `search.historyResetAt` (milliseconds); the shell forgets the results picked before it
(`Ranking.forgetUsageBefore`), in memory and in `search-usage.json`, also when the deletion happened while it was not running.
Tests: `tests/shell/search_chips` (the switches and the deletion on the real controller), `tests/unit/tst_searchranking.qml`.
The clipboard history's group comes last (ADR-0034 step 3, `docs/specs/clipboard.md` CB-13): Results from Clipboard, the time
the history is available (30 minutes, 8 hours, 7 days), Keep clipboard history after logging out, and Clear Clipboard History…
(asks first; "Also delete pinned items" deletes the pins too). Test: `tests/unit/tst_settingssearch.qml`.

