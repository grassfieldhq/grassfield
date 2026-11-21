# Clipboard history spec · shell-engineer, platform-engineer · ADR-0034

The clipboard history of macOS 26/27 Spotlight, in Grassfield's Search (never called "Spotlight" in the UI, §14), with the
power of Windows' clipboard history: pins, formats, a direct key, paste on choice. Decisions: ADR-0034 (owner, 2026-10-27,
Q1 to Q11, recorded there with the options offered and the answers). Steps: 0 docs (this file, the ADR); 1 helper, worker,
shell service, settings keys; 2 the view in Search and Super+Ctrl+V; 3 Settings > Search (after the Settings PRs #8, #9 and
#10 are on main).

## macOS reference behavior (described in words)
Checked on 2026-10-27. VERIFIED = an Apple page or a capture shows it; PRESS = third-party articles only; UNKNOWN = no source.

| # | Behavior | Status | Source |
|---|---|---|---|
| M-1 | ⌘Space opens Spotlight; "Press Command-4 or click [Clipboard button] to the right of the search field." (⌘1 Applications, ⌘2 Files, ⌘3 Actions) | VERIFIED | Apple A (27 and 26), C; capture W-36 |
| M-2 | Off until allowed. macOS 27: "When you first search your Clipboard, you may be asked if you want to allow search results from the Clipboard. Click Allow. Sensitive information may appear on the Clipboard." macOS 26: "you may be asked to click Enable in Spotlight"; the 26.0 capture shows the title "Clipboard Search", "Spotlight can search and display items you've copied to your clipboard. Personal and sensitive information may appear in search results. You can manage Clipboard Search at any time in Spotlight Settings.", buttons "Not Now" and "Turn On" | VERIFIED | Apple A; W-35 |
| M-3 | The field shows the clipboard symbol and the placeholder "Clipboard"; typing searches the history | VERIFIED | Apple A; W-38, W-40 |
| M-4 | A row: a thumbnail (a page with the text, or the picture) with the source app's icon as a badge at its bottom right; the title (the text's first line, or a file name); the subtitle "Text · Copied 11:23 AM", "PNG image · Copied 11:01 AM"; a round copy button at the right | VERIFIED (26.0) | W-38 |
| M-5 | "Copy from your Clipboard: Click [icon] to the right of the item, or select the item and press Command-C." | VERIFIED | Apple A (27 and 26); W-38 |
| M-6 | Apple: "To paste the item, click where you want it to appear, then press Command-V." No automatic paste is documented. Press: Return or a click pastes into the frontmost app and Spotlight closes (Cult of Mac, NotchBay; Office Watch: double-click); ClipBook: Spotlight only copies. Grassfield pastes on choice (owner, Q9) and keeps Apple's copy flow (⌘C, the copy button) | VERIFIED (Apple: copy then ⌘V) / PRESS (paste on Return) | Apple A |
| M-7 | The row menu (secondary click): Paste, Copy, Delete Item (26.0). A later build is reported with Paste, Share, Open, Remove | VERIFIED (26.0) / PRESS | W-37; Make Tech Easier |
| M-8 | "Erase your Clipboard history: Click [More button] to the right of the search field, then choose Clear History." The More menu also holds Settings… | VERIFIED | Apple A; W-40 |
| M-9 | Settings > Spotlight: "Results from Clipboard" (switch), "Clipboard history is available in Spotlight" for 30 minutes, 8 hours or 7 days, "Clear Clipboard History" then "Clear" (26.0 had 8 hours only) | VERIFIED (27); 8 hours as 27's default: PRESS | Apple B; W-39; Make Tech Easier, ClipBook |
| M-10 | Copies an app marks as concealed or transient (Apple's Passwords, password managers) are not kept; ordinary copies of a password are | PRESS | Make Tech Easier, NotchBay, ClipBook |
| M-11 | Pasting from the history drops the formatting (plain text) | PRESS | Cult of Mac, ClipBook |
| M-12 | Text, links (as text), images, files are kept; the history stays on the Mac | PRESS (W-38 shows text, a URL as Text, PNG images) | Paste blog, NotchBay, W-38 |
| M-13 | Space opens a result in Quick Look; Return opens it | VERIFIED for Spotlight results in general | Apple C |
| M-14 | Item limit; what happens at logout or when the history is turned off; a key that deletes an item; the macOS 27 view's exact look; pinning (none) | UNKNOWN / none | — |

## Windows reference behavior (described in words)
Windows 11, checked on 2026-10-27. VERIFIED = Microsoft Support; PRESS = third-party guides.

| # | Behavior | Status | Source |
|---|---|---|---|
| W-1 | Windows key + V opens the clipboard history anywhere; the first time it offers "Turn on" | VERIFIED | Microsoft A |
| W-2 | Text, HTML and bitmaps; at most 4 MB an item; the 25 latest entries, the oldest unpinned removed first | VERIFIED | Microsoft A |
| W-3 | Pin: a pin icon on the item; a pinned item is never pushed out and goes to the front | VERIFIED (pin) / PRESS (icon, front) | Microsoft A; PCWorld, Eleven Forum |
| W-4 | The history is cleared at each restart, except pinned items | VERIFIED | Microsoft A |
| W-5 | Choosing an item pastes it; "See more" (…) on an item: Delete; for text, "Paste as Text" (pasted without formatting) | VERIFIED (paste, Delete) / PRESS (Paste as Text) | Microsoft A; GeekRewind, Eleven Forum |
| W-6 | "Clear all" at the top of the panel and Settings > System > Clipboard > "Clear clipboard data" > "Clear": everything except pinned items | VERIFIED | Microsoft A |
| W-7 | Sync across devices through a Microsoft or work account (automatic or manual) | VERIFIED | Microsoft A |
| W-8 | Suggested actions on a copied phone number or date | PRESS: deprecated by Microsoft | TechRadar, Thurrott |
| W-9 | Search inside the history; keyboard keys inside the panel (delete, pin) | UNKNOWN (no source found) | — |

Sources: Apple A "Search your Clipboard history in Spotlight on Mac" (support.apple.com/guide/mac-help/mchl40d5b86b/mac;
…/mchl40d5b86b/27/mac/27 and …/26/mac/26, read verbatim on 2026-10-27); Apple B "Spotlight settings on Mac"
(…/mchl54d95e8a/mac, macOS 27); Apple C "Spotlight keyboard shortcuts" (…/mh26783, macOS 27); W-35 to W-40: Office Watch,
"macOS 26 clipboard history" (office-watch.com/2025/macos-26-clipboard-history, captures of macOS 26.0); Cult of Mac "Mac
clipboard history"; Make Tech Easier "check Mac clipboard history"; NotchBay "macOS Tahoe clipboard history"; ClipBook "how to
see clipboard history on Mac"; pasteapp.io "macOS Tahoe clipboard history"; Microsoft A "Clipboard in Windows"
(support.microsoft.com/windows/clipboard-in-windows-c436501e-985d-1c8d-97ea-fe46ddf338c6); PCWorld "how to permanently save
clips in Windows 11's clipboard"; Eleven Forum tutorials (pin and unpin, paste as plain text, clear clipboard data);
GeekRewind "paste as plain text from clipboard history in Windows 11"; TechRadar and Thurrott on the deprecation of suggested
actions. 512 Pixels (macOS 26 and 27 libraries) has Spotlight and Settings > Spotlight captures but no clipboard view.
Reference captures are downloaded to `design/reference/clipboard/` (git-ignored), never committed.

## Measurements
From W-38 (macOS 26.0, light). Scale 2 px/pt: its row pitch is 112 px, the 56 pt pitch of the 512 Pixels
`26-Tahoe-Spotlight.png` (2880 px for 1440 pt). Grassfield's Search follows macOS 27 (ADR-0024; rows 63, icon 36 at 26,
text at 80, `docs/specs/search.md`), so the clipboard rows take the 27 Search rows and only the parts specific to the clipboard
are measured here.

| Element | 26.0 measurement | Grassfield (27 structure) |
|---|---|---|
| Row pitch | 56 pt | 63 (Search rows) |
| Title | cap height 12.5 pt (≈ 17.7 pt type), one line, ellipsis | 17 (Search title) |
| Subtitle | cap height ≈ 10.5 pt (≈ 15 pt type), "Kind · Copied time" | 15 (Search subtitle) |
| Thumbnail | ≈ 36 pt box; badge ≈ 10 pt at its bottom right, overhanging | 36 at 26 (Search icon); badge 10, new token |
| Copy button | disc 26.5 pt (53 px); fill (221, 221, 222) on (247, 247, 249): black at ≈ 0.10; glyph (66, 67, 69) | disc 26, `colors.fill` at the control fill opacity, centred on the row, its right edge 12 from the selection's right edge (to measure on a 27 capture) |
| Pin button | none on macOS (Windows has a pin icon on the item) | the copy button's disc and fill, 8 to its left, on the selected or hovered row; on a pinned row a filled pin is always shown there |
| More button | circle outline 20 pt, right end of the field | 20 in the capsule, right of the query |
| Field symbol | ≈ 24 × 29 pt (two stacked pages) | the magnifier's size and place in the capsule (26) |
| Selection (26.0) | accent fill, full pitch | neutral fill as Search (ADR-0024: `search.selectionFillOpacity`, inset 12, radius 18) |

The F1 target (ADR-0024): geometry within ±1 pt, tints within ±0.1, A2 contrast. A macOS 27 capture of the clipboard view is
missing: step 2 measures one if it can be found (or the owner provides it) before its pull request, and says otherwise. The pin
glyph is Grassfield's own symbol (no Apple or Microsoft artwork).

## Purpose and non-goals
Purpose: recent copies (text with its formatting, images, files) searchable in Search, pinned when they are worth keeping,
put back on the clipboard or pasted into the frontmost app in one step, private by construction. Non-goals: sync between
machines (nothing leaves the machine), suggested actions (deprecated by Microsoft), the emoji, GIF and symbol tabs Windows
shows in the same panel (not the clipboard), colours (no shared colour type on Linux), image types other than PNG, JPEG and
WebP, link previews or any network access, the primary selection, Share (no Linux equivalent), Search views for ⌘1 to ⌘3
(Grassfield's Search has none).

## Functional requirements
| ID | Requirement | Step |
|---|---|---|
| CB-1 | `grassfield-clipboard-helper` records copies as ADR-0034 §1 decides: kinds, text with its HTML and RTF parts, images (PNG, JPEG, WebP) thumbnailed by the worker only, caps, refusal before any read, dedupe, history limits (100 items, 64 MiB), retention (30 min, 8 h, 7 days; default 8 h; boot id kept with each time), pins (50, 32 MiB, never expired) | 1 |
| CB-2 | The shell service `Clipboard` (shell/services) starts the helper only while `search.clipboard.enabled` is true, with `--display` (ADR-0034 §8); answers each offer (`Y`/`N`, ADR-0034 §2); pauses it while `SessionState.locked`, resumes after; keeps the helper's `L` lock state; applies retention, the history store switch, `clearedAt` and `pinnedClearedAt`; exposes the items to Search | 1 |
| CB-3 | Settings keys in `config/schema/grassfield.schema.json`: `search.clipboard.enabled` (false), `.retention` ("30m", "8h", "7d"; "8h"), `.keepOnDisk` (false), `.clearedAt` (0), `.pinnedClearedAt` (0) | 1 |
| CB-4 | The pinned store (always) and the opt-in history store (ADR-0034 §5), directories 0700 and files 0600 whatever the umask | 1 |
| CB-5 | Search's Clipboard view: ⌘4 (Super+4, which `forwarding.lua` sends to Search as Ctrl+4; physical Ctrl+4 switches to Space 4, `bindings.lua:114`), the Clipboard button to the right of the empty field, and Super+Ctrl+V from anywhere (opens Search in the view; again closes it; `bindings.lua`, IPC `search clipboard`); the field shows the clipboard symbol and the placeholder "Clipboard"; Backspace in an empty field leaves the view | 2 |
| CB-6 | The first visit while the history is off (⌘4, the button or Super+Ctrl+V) shows the prompt with macOS 27's wording (M-2): "Allow results from the clipboard in Search?" with "Not Now" and "Allow" (Q10); "Not Now" leaves it off, "Allow" sets `search.clipboard.enabled` through `settings apply`; recording starts with the next copy; existing pins show again | 2 |
| CB-7 | Rows (M-4): pinned items first (newest pin first) with a pin mark, then the history newest first, all filtered by the query (the helper's search); empty: "No Items"; a query with no match: "No Results for …" (Search's notice) | 2 |
| CB-8 | Paste on choice (Q9): Return, Enter, a click, the menu's Paste (with formatting when the item has it); Shift+Return and the menu's Paste as Plain Text (text items with formatting) paste the plain text only (ADR-0034 §4); the copy button, ⌘C (Ctrl+C) and the menu's Copy only copy (Apple's flow, M-5, M-6) and leave Search open with a short "Copied" state on the row | 2 |
| CB-9 | Delete one item: the menu's Delete Item, or Ctrl+Backspace on the selected row while the field is empty (no macOS key is documented, M-14); the selection moves to the next row; a pinned item is deleted from the disk too | 2 |
| CB-10 | More menu (…): Clear History (at once, as the 26.0 menu shows no confirmation; pinned items stay, W-6) and Settings… (opens Settings > Search) | 2 |
| CB-11 | Item preview: Space on a selected row while the field is empty, or ⌘Y (Ctrl+Y) at any time, opens a preview panel next to Search (text: the plain part, up to 64 KiB, plain text only, scrollable, never rendered as HTML; image: a preview at most 1,024 px on its long side made on demand by the worker in the runtime directory and deleted when the panel closes; files: names and kinds); Space or Esc closes it | 2 |
| CB-12 | Keyboard and mouse parity: every action has both (table below); the row menu opens with a secondary click, the Menu key or Shift+F10 | 2 |
| CB-13 | Settings > Search, a group of its own after Search Results (ADR-0034 Q24): "Results from Clipboard", "Clipboard history is available in Search for" (30 minutes, 8 hours, 7 days), "Keep clipboard history after logging out" (both inactive while the history is off, Q25), "Clear Clipboard History…" (asks; "Clear" writes `clearedAt`; the dialog's "Also delete pinned items", unchecked each time (Q26), also writes `pinnedClearedAt`, in the same write) | 3 |
| CB-14 | Every string in English and French (`translations/`), Search's names only (never "Spotlight"); the Super+Ctrl+V binding's description in `apps/settings/qml/Bindings.js` and the French catalog | 2, 3 |
| CB-15 | Pin and unpin: the row's pin button, the menu's Pin / Unpin, ⌘P (Ctrl+P) on the selected row; a pin past 50 items or 32 MiB is refused with "Pinned items are full"; pinned items never expire, are never pushed out, and survive logout, restarts and Clear History (W-3, W-4, W-6) | 2 (1 for the store) |

### Keyboard and mouse
| Action | Keyboard | Mouse |
|---|---|---|
| Open the view | Super+Ctrl+V; or ⌘Space then ⌘4 (the 4 key by its place: AZERTY too) | the Clipboard button right of the field |
| Move | ↑ ↓ | hover |
| Paste | Return, Enter | click, double-click |
| Paste as plain text | Shift+Return | the menu's Paste as Plain Text |
| Copy only | ⌘C (Ctrl+C) | the copy button |
| Pin, unpin | ⌘P (Ctrl+P) | the pin button, the menu |
| Row menu | Menu key, Shift+F10 | secondary click |
| Delete item | Ctrl+Backspace (empty field), or the menu | the menu's Delete Item |
| Preview | Space (empty field), ⌘Y (Ctrl+Y) | — (the menu has no preview item on macOS) |
| Clear (unpinned) | the More menu (Tab reaches it after the rows) | More (…) > Clear History |
| Leave the view | Backspace in the empty field | — |
| Close | Esc (clears the query first, as Search), Super+Ctrl+V | click outside |

## Privacy requirements
| ID | Requirement |
|---|---|
| PV-1 | A copy whose types include `x-kde-passwordManagerHint` (any value) or an nspasteboard.org concealed, transient or auto-generated type is never recorded, and its data is never requested (ADR-0034 §1b); it can therefore never be pinned |
| PV-2 | Nothing is recorded while the session is locked by any program: the helper starts paused and has no data-control device while the compositor's lock notifier says `locked` or the shell says `SessionState.locked`; the shell answers `N` in both cases; the first selection after the unlock is skipped (ADR-0034 §6) |
| PV-3 | Nothing is recorded while a screen-share-protected password manager is the active window (`privacy.lua`) |
| PV-4 | Off switch (CB-13, CB-6): turning off deletes the unpinned items; clear (CB-10, CB-13) deletes the unpinned items; "Also delete pinned items" (CB-13) deletes everything, memory and disk; a clear asked while the shell or the helper was not running is carried out at the next start, before anything is shown or recorded (ADR-0034 §6, `<state>/clears`); if that record cannot be written, the next start deletes the store again, items copied or pinned since the clear included (data lost, never privacy). The shell acts only on a usable read of grassfield.json: a missing, malformed, unreadable, too large, unsafe or empty (or whitespace-only) file never starts, stops, clears or deletes anything; while the history runs, the last usable values stay until the file is usable again (ADR-0034 Q27) |
| PV-5 | No network: the helper links no network module; the shell fetches nothing for an item (no link preview, no favicon, no remote icon, HTML never rendered) |
| PV-6 | No content in logs: counts, kinds, sizes and reasons only; titles, text, file names, URLs and hashes never appear (a canary test) |
| PV-7 | Caps and limits of ADR-0034 §1; images decoded only by the time-limited worker, with the format given and detection off; thumbnails at most 256 px, previews at most 1,024 px, both in the runtime directory, 0600 |
| PV-8 | Text is shown as plain text only (`textFormat: Text.PlainText`, `scripts/dev/check-textformat.py`): a copied string cannot inject rich text |
| PV-9 | The view is never shown while either lock source says locked (GF-116 `SessionState.refuses`, the helper's `L 1`) and closes when the lock engages; Super+Ctrl+V is refused while locked |
| PV-10 | Tests never read the owner's clipboard or session: `env -i`, the fake server in a `mktemp -d` runtime directory, its socket passed as `--display` and checked to lie in that directory, scratch `HOME` and state |
| PV-11 | Only an explicit pin writes an item to the disk without the opt-in switch; the pinned store is read only by the helper, with the bounds of ADR-0034 §5 |
| PV-12 | Nothing is recorded while an authorization (polkit) request is open (its sheet shown or held behind the lock) or in the 2 s after it ends (Q11, a monotonic timer), so an echo-on answer copied from its field is never kept; the state comes from `AuthAgent.requestActive` through `SessionState.authorizing` (ADR-0034 §2) |
| PV-13 | The helper reaches only the display named by `--display` (an absolute path to a socket owned by the user): it unsets `WAYLAND_DISPLAY` and `WAYLAND_SOCKET`, connects the socket itself, checks the peer's user (`SO_PEERCRED`) and uses `wl_display_connect_to_fd`, never `wl_display_connect` (which takes `WAYLAND_SOCKET` first); it has no default display |
| PV-14 | The paste's key up is never conditional: its Hyprland timer is armed before the key down is sent, and it follows the key down after 50 ms to the same window address, so no V stays pressed in the target app; the paste is dropped if Hyprland reported `closewindow` for the remembered address since Search opened (an address can be reused) |

## Strings (English, French)
| English | French |
|---|---|
| Clipboard | Presse-papiers |
| Clipboard history (binding description) | Historique du presse-papiers |
| Allow results from the clipboard in Search? | Autoriser les résultats du presse-papiers dans la Recherche ? |
| Personal and sensitive information may appear in the results. You can change this at any time in Search settings. | Des informations personnelles et sensibles peuvent apparaître dans les résultats. Vous pouvez modifier ce choix à tout moment dans les réglages de la Recherche. |
| Not Now · Allow | Plus tard · Autoriser |
| Text · Formatted Text · %1 image · Files · %1 Items (two or more files) | Texte · Texte mis en forme · Image %1 · Fichiers · %1 éléments |
| Image (an image whose format is not known) | Image |
| Copied %1 (today: the time) · Copied on %1 (before: the date and time; ADR-0034 Q21) | Copié à %1 · Copié le %1 |
| Copied | Copié |
| Paste · Paste as Plain Text · Copy · Pin · Unpin · Delete Item | Coller · Coller en texte brut · Copier · Épingler · Désépingler · Supprimer l'élément |
| Pinned | Épinglé |
| Pinned items are full | Le nombre maximal d'éléments épinglés est atteint |
| The item could not be copied (a refused or unanswered copy or paste; ADR-0034 Q23) | L’élément n’a pas pu être copié |
| Clear History · Settings… | Effacer l'historique · Réglages… |
| No Items | Aucun élément |
| Type to search the clipboard history · More · Preview · Clipboard item (accessible description and names) | Saisissez pour rechercher dans l’historique du presse-papiers · Plus · Aperçu · Élément du presse-papiers |
| Clipboard history is off in development (set GRASSFIELD_CLIPBOARD_DISPLAY) | dev only, English |
| Clipboard history needs a compositor with ext-data-control and lock notifications | L'historique du presse-papiers nécessite un compositeur compatible ext-data-control et notifications de verrouillage |
| Results from Clipboard | Résultats du presse-papiers |
| Clipboard history is available in Search for | L'historique du presse-papiers est disponible dans la Recherche pendant |
| 30 minutes · 8 hours · 7 days | 30 minutes · 8 heures · 7 jours |
| Clear Clipboard History… · Clear · Also delete pinned items | Effacer l'historique du presse-papiers… · Effacer · Supprimer aussi les éléments épinglés |
| Keep clipboard history after logging out | Conserver l'historique après la déconnexion |
| Clipboard History (the row of Clear Clipboard History…) | Historique du presse-papiers |
| Clear your clipboard history? · The items you copied are deleted from Search. Pinned items stay unless you delete them too. | Effacer votre historique du presse-papiers ? · Les éléments que vous avez copiés sont supprimés de la Recherche. Les éléments épinglés restent, sauf si vous les supprimez aussi. |
| Results from Clipboard's explanation: Allows Search to find and show items you copied. Personal and sensitive information may appear in the results. Turning it off deletes the items you did not pin. | Permet à la Recherche de trouver et d’afficher les éléments que vous avez copiés. Des informations personnelles et sensibles peuvent apparaître dans les résultats. La désactivation supprime les éléments que vous n’avez pas épinglés. |
| Keep's explanation: The items you did not pin are kept on this computer, readable only by you, until they are no longer available. | Les éléments que vous n’avez pas épinglés sont conservés sur cet ordinateur, lisibles par vous seul, jusqu’à ce qu’ils ne soient plus disponibles. |

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| CB-1, CB-15, PV-1, PV-7 | `tests/unit/clipboard-helper/tst_cliplogic.cpp` (gtest, ASan build too): type choice, HTML and RTF parts and their caps, the plain part made from HTML, hint and marker refusal, caps, UTF-8 and Latin-1, dedupe (also against a pin), history and pin limits, retention with the clock set back and forward and with another boot id (pins never expire), escaping of the line protocol, the clears carried out at start (`clearAction`: not given, never, already carried out, newer, older after a clock set back, no record; `keptAfterClear` by the copy's or the pin's time) | L0 |
| CB-4, PV-7, PV-11 | `tests/unit/clipboard-helper/tst_diskstore.cpp` and `tst_thumbnail.cpp` (gtest, ASan build too): store modes 0700/0600 under umask 022, a store that breaks a rule deleted, a broken item alone, a newer index left alone, the files the index does not name deleted at load (a link removed, never its target); the clears record (0600 in a 0700 directory whatever the umask, read back, every broken form read as missing and deleted, a link never read); the worker's decoding (only the format given, size limits), a worker still running at 2 s killed, the worker's rlimits, environment (`LC_ALL=C` only), arguments and stdin, a worker that cannot start, a deleted job that reports nothing | L0 |
| CB-1, CB-4, CB-15, PV-1, PV-2, PV-7, PV-10, PV-11, PV-13 | `tests/shell/clipboard_helper.sh`, under `env -i`: the helper against `tests/fixtures/fake-clipboard-server` (data control and lock notifier) in a `mktemp -d` runtime directory, its socket passed as `--display` and asserted to lie there; refusal without `--display`, with a relative name and with a non-socket; a decoy `WAYLAND_SOCKET` (a descriptor connected to a second fake server) gets no client; paused until resumed, the first selection skipped; Y and N; HTML kept; a hinted copy (the server records no receive request); a source that never closes (2 s); oversized data; images (a thumbnail 0600 of at most 256 px; PDF, SVG and TIFF bytes behind a PNG offer: nothing decoded by another plugin, nothing recorded; GIF not offered); `locked` at bind and mid-run (no receive request until `unlocked`, first selection skipped); a lock during a read (the copy dropped although its source answers in full later); pause and resume; serving every type and the own-copy marker, Paste as Plain Text offers no HTML, a reader that stops reading closed after 2 s, a slow reader that keeps reading gets the whole answer; the stores (modes 0700/0600 under umask 022, pins present after a helper restart, a pinned image whose worker fails kept without a thumbnail, a new image recorded before 16 stored thumbnails are done, the history store read back and deleted when switched off, retention, expiry at load: past the retention and dated in the future by another boot, `--clear-pinned` and `--clear-history` from the command line); clears asked while no helper ran (the record 0600; a history clear and a pinned clear carried out at start or by `--apply-clears`, the same values not carried out again, `CH <ms>` recorded and `CH` alone not, no record: only what came before the clear goes); every helper ends with exit 0 on QUIT or a closed stdin | L0 |
| CB-2, CB-8, PV-2, PV-3, PV-12 | `tests/unit/tst_clipboard.qml`: offer answers (locked by either source, off, protected window, authorization dialog shown or closed less than 2 s ago), the paste request (address validation, the terminal test equal to `forwarding.lua`'s on shared vectors, the key up's timer armed unconditionally in the same function, before the key down, refused when either source says locked, when another window is active, after 1 s, after a `closewindow` for the address), the clear keys (unpinned only, then everything) | L0 |
| PV-6 | log canary: a copy of a unique string through the fake server, pinned then unpinned, then the helper's and the shell's logs do not contain it | L0 |
| PV-8 | `scripts/dev/check-textformat.py` | L0 |
| CB-5 to CB-12, CB-15 | `tests/unit/tst_clipboard.qml` (`ClipboardView.js`): the rows a query shows, the kinds a row names, the keyboard map (the keys of the table below, with and without modifiers, empty field or not, a selection in the field), ⌘4 from the results, the row menu (Paste as Plain Text only for formatted text, Pin or Unpin), the selection after a delete | L0 |
| CB-5 to CB-11, CB-15, PV-9 | `tests/shell/search_clipboard` (step 2): the real Search controller and Clipboard service in a dev session with no helper (`dev-off`); the helper's lines are handed to `Clipboard.handle()` as it prints them. ⌘4 and Super+Ctrl+V in and out of the view, the prompt, Not Now, Allow (the setting applied), rows pinned first, the helper's search (a stale answer ignored), Copy (Search stays, "Copied"), Delete (the next row, then the new last row), "Pinned items are full", the preview (another item's answer ignored, it follows the selection, Space closes it), Backspace leaves; the paste: Search closes only on the helper's `A` (copied only with no target, or with a target closed before the choice); Search closed before the `A` drops it and a late `A` pastes nothing; once copied it is dropped by this shell's lock, another program's lock, a surface opening, the target closing, Search opening again and the 1 s deadline; a refused or unanswered copy or paste keeps Search open with its notice; the helper's lock closes Search and Super+Ctrl+V then opens nothing. Each of those checks fails when its line in `Clipboard.qml` or `Search.qml` is removed or forced (review of 28d2651). The helper's side of pin, delete and clear is `tests/shell/clipboard_helper.sh` | L1 |
| CB-13, PV-4 | `tests/shell/clipboard_settings.sh` (reviews of f7cd664, c1fc254 and 3f924d9): the real Clipboard and Settings services in a dev session under `env -i`, with `GRASSFIELD_CLIPBOARD_HELPER` set to `tests/shell/clipboard_settings.d/fake-helper`, which records its arguments and the lines it is sent and touches no clipboard, compositor or store. No file, a file too large, a malformed one, an unsafe one, an empty one and a whitespace-only one at start: nothing runs. The first usable read with the history off: `--clear-history`, then `--apply-clears` with the settings' times, one after the other; a clear while off: `--apply-clears` with its time. The history on: the helper's arguments (retention, history store, both times); Clear sends `CH <ms>`, Clear with the pins `CH <ms>` and `CP <ms>`. The file unsafe, malformed, too large, missing or empty while the history runs, then usable again with the same values: nothing is sent. The duration sends `T`, Keep off `D 0`, the history off `D 0` then `QUIT`. Each check fails when its line in `Clipboard.qml` is removed or changed (review of c1fc254) | L1 |
| CB-13 | `tests/unit/tst_settingssearch.qml` (step 3): Results from Clipboard off by default and writing `search.clipboard.enabled`; the duration pop-up (8 hours by default, 30m/8h/7d, writing `.retention`) and Keep (off by default, writing `.keepOnDisk`) inactive while the history is off; Clear Clipboard History… only asks, available while off; `clearClipboard` writes `.clearedAt` alone, or with `.pinnedClearedAt` (same time) in one write | L0 |
| CB-5 | `search clipboard` in the IPC inventory (action, caller SUPER+CTRL+V), refused while locked: `lock_surfaces.sh` checks that it routes to `toggleClipboard()`, which opens only through `show()`, and that `enterClipboard()` refuses first; `tests/security/lock_surfaces` runs Super+Ctrl+V's function while locked | L0 (`tests/security/ipc_inventory.sh`, `lock_surfaces`) |
| CB-8 | nested: a real copy in a test window, Return pastes into it, Shift+Return pastes plain text into a rich-text app, Ctrl+Shift+V reaches alacritty, kitty, foot and ghostty; Search opened over window A, A closed meanwhile: nothing is pasted | L1 (integrator) |
| PV-2, PV-9 | nested: copy while locked by the shell and while locked by another locker started mid-session (a program running `wl-copy` under the lock): absent after the unlock | L1 (integrator) |
| CB-5 to CB-15 | `just shot` light and dark, en and fr; geometry and tints against the measurements, A2 | visual |

## Known limitations
- Wayland does not say which client made a copy: the source badge is the app that was frontmost (ADR-0034 §3).
- A program the history pastes into must accept Ctrl+V (Ctrl+Shift+V in terminals); an app with another paste key gets the
  item on its clipboard only.
- Formatted text is pasted as the source app produced it; HTML may reference remote images that the target app chooses to
  load (as with any paste). Grassfield itself never renders it.
- When the helper exits (history turned off, logout) while it owns the clipboard, the clipboard becomes empty, as with any
  Wayland app that owns it. When the shell goes (a crash, a restart: the helper's stdin or stdout closes, or the shell's
  process ends), a helper that serves the clipboard keeps serving that one item (audit round 2; it forgets the history,
  records nothing, says nothing) until another client takes the clipboard, the compositor connection ends, or 8 h. To
  outlive a restart of the shell's unit it leaves that unit at start for a scope of its own
  (`grassfield-clipboard-helper-<pid>.scope`, StartTransientUnit through `busctl --user`); without a user manager or
  `busctl` it stays in the shell's unit and a unit restart still empties the clipboard. Not verified in a real session.
- Helper protocol additions (audit round 2): `N pin-failed <id>`: the pinned item's file could not be written (full disk, a
  read-only store): the item stays in the history, unpinned (B-09). `K <id>`: the clipboard was cleared, or replaced by
  blank text, less than 60 s after that copy was recorded (and it is the last copy, not pinned, not served by the helper):
  the source may be a password manager that clears what it copied; the shell removes the item (`X <id>`) when the copying
  application still runs and keeps it when it has gone (the compositor clears the clipboard of a client that closes), B-10.
  `pass -c` restores the previous clipboard instead of clearing it: not detected.
- Reading a copy (B-13): the source may take 10 s before its first byte (an image encoded when asked), then 2 s without
  progress and 60 s in all. A data-control device the compositor ends is made again after 0.5 s, its first selection
  skipped; five such ends within a minute stop the helper (`S error`), B-15. The helper's output never blocks it: lines
  wait in a queue while the shell does not read (B-14). With the history store on, the index is written once per change
  (a copy and the items it pushed out, or the switch turned on with 100 items), 200 ms after it. A text copied again
  takes the new copy's formats (HTML, RTF) in the history (B-11); a pinned item keeps its own. Titles and excerpts keep a
  zero-width joiner or non-joiner between two letters, marks or symbols (emoji sequences, Persian, Indic), B-19.
- The view is not hidden from screen capture or sharing, as on macOS.
- A password manager that neither sets the hint nor is in the screen-share list is recorded like any app (macOS and Windows
  have the same limit); such a copy is deleted with the history unless the user pins it.
- Without the opt-in history store the unpinned items end at logout and when the shell restarts; pinned items stay.
- A deleted pinned item's blocks can stay on the disk until reused (btrfs, SSD); Omarchy's full-disk encryption covers them.
- Hyprland reports a lock when it confirms it to the locker: a copy made between another locker's request and that
  confirmation can be recorded, and a paste dispatched in that phase (or as a lock is requested) can still reach the chosen
  window with the chosen item (ADR-0034 §4, §6). This shell's own lock is covered from its request (`SessionState.locked`).
- GIF, BMP, TIFF and other image types are not recorded (only PNG, JPEG and WebP are decoded, and only by the worker).
- A compositor without `ext-data-control-v1` or `hyprland_lock_notifier_v1` (Hyprland 0.56.2 has both): no history (the
  view says so).

## Not verified (step 0)
- The macOS 27 clipboard view (no capture), M-6's paste on Return beyond press sources, 8 hours as macOS 27's default, M-14;
  W-9.
- In Hyprland 0.56.2's Lua: the format of a window object's `address`, the `address:` selector of `send_key_state`, and
  loading a Grassfield Lua module from a dispatched function (nested, step 1, before the paste code).
- The terminals' default Ctrl+Shift+V paste (their documented defaults; nested, step 2).
- Real copies from KeePassXC, 1Password, Bitwarden, Firefox's password manager, a GTK and a Qt app (with HTML), XWayland
  (owner or integrator, nested); which hints password managers really set.

## Emoji & Symbols (ADR-0045 OC-3)
macOS 27's Character Viewer in its compact popover (Control-Command-Space), named "Emoji & Symbols" « Emojis et symboles »
(ADR-0045 OC-0.5; never Apple's name). It lives in this spec because it inserts the way the history pastes: into the window
that was active when it opened, once the keyboard is back there, through the clipboard. Code: `shell/services/Emoji.qml` (data,
recents, placement, insertion, IPC `emoji`), `shell/services/EmojiLogic.js` (pure: categories, search, recents, grid keys,
placement, insertion step and command), `shell/overlay/EmojiPanel.qml` (the popover, popup kind `emoji` of the Overlay),
`shell/services/emoji-insert.sh` (the insertion's command chain). Tests: `tests/unit/tst_emoji.qml` (fixture
`tests/fixtures/emojis.json`: 28 entries of our own, each group's first emoji where Omarchy's list has it; never Omarchy's
file), `tests/shell/emoji_insert.sh` (the command chain on stubs), `tests/unit/tst_overlayblur.qml` (the popover's blur corner),
`tests/security/lock_surfaces.sh` and `tests/security/lock_surfaces/shell.qml` (nothing opens while locked, GF-116).

### Requirements
| ID | Requirement |
|---|---|
| ES-1 | Ctrl+Super+Space (macOS Control-Command-Space; `config/hypr/grassfield/bindings.lua`, IPC `emoji toggle`; "Emoji & Symbols" in Settings > Keyboard > Keyboard Shortcuts) opens the panel; again, or Esc, or a click outside closes it. It opens at the pointer (`hyprctl cursorpos -j`, read only) on the output under it, its top left corner just under the pointer, above the pointer when the output has no room below, kept inside the output (the Overlay's placement, align `below`); without an answer within 500 ms it opens centred on the active display. Refused while the session is locked (`SessionState.refuses`); it closes when the session locks (Popups). |
| ES-2 | The popover (macOS 27 compact layout): glass of the `menu` class with its blur region at the popovers' corner (`radius.popover`, shared with the Weather widget's Edit Location popover; `PopupKinds.blurCorner`); from the top: the shared `SearchField` ("Search", focused at once, without the 3-px focus ring: `focusRing: false`, as macOS 27's picker leaves the app's window key and draws none; the caret shows the focus), the grid of glyphs 9 to a row (`emoji.columns`, `cellSize` 36, `glyphSize` 26) under section titles in the secondary colour (an empty search: Recently Used when there is any, then the categories in macOS's order), the category bar at the bottom: one glyph button per section (Recently Used: clock, Smileys & People: face, Animals & Nature: paw, Food & Drink: cup, Activity: ball, Travel & Places: car, Objects: light bulb, Symbols: number sign, Flags: flag; All: grid), the section in view checked, its name in a tooltip; a click scrolls the grid to it (and clears a search). The keyboard selection is a square in the menus' selection role (`Appearance.colors.selection` under `selectionText`, as `MenuItem`; never the text highlight colour, which the user may set apart; `emoji.cellRadius`), the pointer's a neutral hover square. Open: the overlay layer's fade (Hyprland `layersIn`). |
| ES-3 | Data: Omarchy's `$OMARCHY_PATH/shell/plugins/emojis/emojis.json` (`OMARCHY_PATH` when it is an absolute path, else `/usr/share/omarchy`; 1870 entries `{e, k}` in v4.0.6, MIT), read at the first opening (again at an opening after it was missing), never copied into Grassfield. Entries are validated (`EmojiLogic.parse`: a glyph of at most 48 UTF-16 units without control, separator or bidi characters, drawn as plain text; keywords at most 512 characters; at most 8000 entries). A missing, unreadable or empty file: the panel says "Emoji list not available" and offers nothing else. |
| ES-4 | Categories: the file names no groups, so they come from the first emoji of each CLDR group in its order: 😀 Smileys & Emotion and 👋 People & Body (one Smileys & People), 🐵 Animals & Nature, 🍇 Food & Drink, 🌍 Travel & Places, 🎃 Activities (Activity), 👓 Objects, 🏧 Symbols, 🏁 Flags (indices 0, 166, 529, 681, 814, 1032, 1117, 1378, 1601 in v4.0.6, checked with jq). A first emoji missing, out of order, or a file that does not begin with 😀: one "All" section (nothing guessed). The sections show in macOS's order: Activity before Travel & Places. |
| ES-5 | Search: typing goes to the field; every word of the query must match the entry's English keywords (Omarchy's) or the translated title of its category, as a whole word, a word's beginning or anywhere inside, case and accents ignored; keyword matches first (whole word, then beginning, then inside), category matches after, ties in the file's order; the results are one untitled section, the first one selected (Return inserts it); none: "No Results". |
| ES-6 | Keyboard (macOS: the selection moves over the grid while the field keeps typing): arrows move the selection (left and right in reading order, up and down to the same column, a shorter row's last glyph, across sections), Page Up and Page Down by the rows in view, Tab and Shift+Tab to the next and the previous section's first glyph, Return or Enter inserts the selection, Esc clears the search, then closes. With no selection the first arrow selects the first glyph. The selection is kept in view, its section title too. |
| ES-7 | Insert (a click or Return): the glyph goes first in Recently Used, the panel closes and FocusReturn gives the keyboard back to the window that was active when it opened (the window FocusReturn remembers when another surface was open); once that window is active again (checked every 50 ms, at most 1 s, `EmojiLogic.insertStep`) the shell runs Omarchy's `omarchy-menu-emoji-insert <glyph>` (PATH, else `$OMARCHY_PATH/bin`), which copies the glyph with `wl-copy --sensitive` (so the history never records it, PV-1) and sends Shift+Insert; without it, `wtype -- <glyph>` when wtype is installed; without either, one journal line ("neither omarchy-menu-emoji-insert nor wtype is installed") and nothing else. The detection is at use time (`command -v` in `shell/services/emoji-insert.sh`, ADR-0045 OC-0.3); the glyph and the path are arguments of that script (`EmojiLogic.insertCommand`: an argument vector, never a command line; a glyph that would read as an option is refused). Nothing is inserted when no window was active (the desktop, or nothing), the window closed, the session locked, another full-attention surface opened, or the window did not come back in time: a journal line says which. |
| ES-8 | Recently Used: at most 30 glyphs, newest first, in `~/.local/state/grassfield/emoji-recents.json` (`$XDG_STATE_HOME/grassfield`, `GRASSFIELD_STATE_HOME` in a dev session), `{"v": 1, "recents": [...]}`, written through `shell/services/write-private.sh` (directory 0700, file 0600, atomic); read at the shell's start; a glyph no longer in Omarchy's list is not shown. |
| ES-9 | IPC (docs/specs/security.md "IPC surface"): `emoji toggle` (action, the binding); `emoji status` (dev: the state, the counts, the last insertion's outcome; it would tell another process what the user inserted). |
| ES-10 | The T0 Edit menu item of ADR-0045 is not built: T0 has no Edit menu (docs/specs/menubar.md: "a T0 Edit and Help menu for apps that export no menus" is still missing). An application's own Edit menu (T1/T2) is the application's. As on macOS, the Input menu has Show Emoji & Symbols (« Afficher les emojis et symboles »; `shell/overlay/InputMenu.qml`), which opens the panel over the window the menu opened over. |

### Keyboard and mouse
| Action | Keyboard | Mouse |
|---|---|---|
| Open, close | Ctrl+Super+Space; Esc closes (after clearing a search) | click outside closes |
| Search | type (the field has the focus) | the field |
| Move | arrows, Page Up, Page Down; Tab, Shift+Tab by section | hover (a neutral square) |
| Insert | Return, Enter | click |
| Go to a category | Tab, Shift+Tab | the category bar |

### Strings (English, French)
| English | French |
|---|---|
| Emoji & Symbols (the panel's accessible name and the binding's description) | Emojis et symboles |
| Recently Used | Utilisés récemment |
| Smileys & People · Animals & Nature · Food & Drink · Activity · Travel & Places · Objects · Symbols · Flags · All | Smileys et personnes · Animaux et nature · Nourriture et boissons · Activités · Voyages et lieux · Objets · Symboles · Drapeaux · Tous |
| Search · No Results | Rechercher · Aucun résultat |
| Emoji list not available | Liste d’emojis indisponible |
| Emoji grid · Categories (accessible names) | Grille d’emojis · Catégories |

### Known limitations
- English keywords only: Omarchy's list has no French names, so a French search finds emoji by the words of a category's
  title (« animaux » gives Animals & Nature) or by their English keywords (« chat » finds nothing unless an English keyword
  holds it).
- The clipboard does not keep its previous content: `omarchy-menu-emoji-insert` puts the glyph on it (sensitive, so the history
  does not record it) and ends its copy after the paste, so the clipboard is empty afterwards (Wayland has no way to restore
  another client's selection).
- Insertion is Shift+Insert, which most toolkits read as Paste; an application where Shift+Insert pastes the primary selection
  (some terminals) or nothing gets that instead. The wtype fallback types the glyph and leaves the clipboard alone, but a glyph
  the keyboard layout cannot type may come out differently in some applications.
- The panel opens at the pointer, not at the text caret as on macOS: Wayland gives the shell no caret position.
- No skin tone or gender variants menu (Omarchy's list has one glyph per entry), no Frequently Used (Recently Used is what
  the shell knows), no expanded Character Viewer window, no symbols beyond Omarchy's emoji list.
- The close has no fade: the Overlay unloads its popup at once (as for every menu and popover); the open fades with the
  overlay layer.
- Inserting into a shell surface (Search's field, a Grassfield sheet) is not supported: the window must be an application's.

### Not verified
- The macOS 27 measurements (no capture of the compact Character Viewer in `design/reference/`): every `emoji.*` token is an
  estimate; F1 pending.
- The whole panel on screen (nested session, light and dark, en and fr), the insertion into GTK, Qt, Chromium, Firefox and
  terminal windows, the wtype fallback, and the placement at the pointer on two outputs (`hyprctl cursorpos` layout
  coordinates against Quickshell's screen geometry at a fractional scale).
