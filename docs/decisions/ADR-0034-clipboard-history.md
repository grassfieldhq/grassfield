# ADR-0034: Clipboard history in Search (macOS presentation, Windows power), served by a native data-control helper
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (owner decisions of 2026-10-27, clipboard-history cloud session; revised after the opus review FAIL of
step 0); accepted after the opus review PASS of step 0 · Date: 2026-10-27 · Decider: owner

## Context
Owner brief (2026-10-27, verbatim): « l'historique du presse-papiers de macOS 26/27, dans la Recherche (Spotlight) de
Grassfield : le même accès, la même présentation, les mêmes comportements (choisir un élément le remet dans le
presse-papiers et le colle dans l'app au premier plan, comme sur macOS), avec les mêmes protections de la vie privée. »
Non-negotiable: a copy a password manager marks as secret (`x-kde-passwordManagerHint=secret` and equivalents) or made while
the screen is locked is never recorded; an off switch and a "clear all"; nothing leaves the machine; no content preview in
logs; a size limit per item, a count limit, bounded image thumbnails. Added the same day (verbatim): « Il fait savoir qu'on
doit pouvoir epingler les donnees etc... il doit etre aussi puissznt que l'historique du presse papier sur windows ».

macOS (verified 2026-10-27; sources, measurements and what stays unverified: `docs/specs/clipboard.md`). Apple's help page
"Search your Clipboard history in Spotlight on Mac", macOS 27 text (the 26 text is the same except the button), verbatim:
"Press Command-4 or click [Clipboard button] to the right of the search field."; "When you first search your Clipboard, you
may be asked if you want to allow search results from the Clipboard. Click Allow." (macOS 26: "click Enable"); "Copy from
your Clipboard: Click [icon] to the right of the item, or select the item and press Command-C."; "To paste the item, click
where you want it to appear, then press Command-V."; "Erase your Clipboard history: Click [More button] to the right of the
search field, then choose Clear History." Apple describes no automatic paste; press sources say Return or a click pastes into
the frontmost app (decision Q9 below). System Settings > Spotlight: "Results from Clipboard", "Clipboard history is available
in Spotlight" for 30 minutes, 8 hours or 7 days, "Clear Clipboard History" (then "Clear"). macOS 26.0 captures: rows with a
thumbnail and the source app's badge, "Text · Copied 11:23 AM", a copy button; the row menu Paste, Copy, Delete Item. macOS
has no pinning.

Windows 11 (Microsoft Support "Clipboard in Windows", checked 2026-10-27; details in the spec): Windows key + V, "Turn on"
the first time; text, HTML and bitmap, at most 4 MB an item, the 25 latest entries, the oldest unpinned ones removed first;
choosing an item pastes it; pinned items are never pushed out, survive a restart (the rest of the history does not) and
survive "Clear all" and Settings > System > Clipboard > "Clear clipboard data"; an item's "See more" (…) menu has Delete and,
for text, "Paste as Text" (press sources); sync across devices through a Microsoft account; "suggested actions" (call a
copied phone number, add a copied date to a calendar) are deprecated by Microsoft.

What Grassfield has: Search (`shell/search/`), `FocusReturn` (the window active when Search opened gets the keyboard back
when it closes), `SessionState.locked` (= `Lock.locked`: locking, locked or authenticating, `shell/security/LockController.qml:30`;
it reflects this shell's lock only: a lock taken by another program during the session sends no event, and the ownership
probe runs only while this shell holds a lock, `docs/specs/security.md` "Lock ownership and foreign lockers"), `wl-clipboard`
in the package's `depends` (Search's calculator and the desktop copy with `wl-copy`). Quickshell 0.3.1's only clipboard API
is `Quickshell.clipboardText`, empty unless a Quickshell window has the keyboard (`src/core/qmlglobal.hpp:139` at v0.3.1):
it cannot watch. Keys: Grassfield uses Super as ⌘ for shell commands (`bindings.lua`: Q, W, H, M, Super+1..9 forwarded as
Ctrl+1..9); physical Ctrl+1..9 switch Spaces (`bindings.lua:114`); Super+Ctrl+V is free. The authorization dialog's field
(`shell/security/polkit/AuthDialog.qml:271`, `PasswordField`) shows an echo-on answer in clear (`reveal`), and then allows
copying it.

Platform, read in the sources:
- Hyprland 0.56.2 (`efb5099`) exposes `zwlr_data_control_manager_v1` v2 and `ext_data_control_manager_v1` v1
  (`src/managers/ProtocolManager.cpp:202,218`) and sends the current selection to a new data-control device
  (`src/protocols/ExtDataDevice.cpp:156`). Data control is not in the list allowed to sandboxed (security-context) clients
  (`ProtocolManager.cpp:348`); any other client of the user can read the clipboard today.
- It also registers `hyprland_lock_notifier_v1` v1 (`ProtocolManager.cpp:190`). A new lock notification gets `locked` at once
  when the session is locked (`src/protocols/LockNotify.cpp`, `onGetNotification`), then `locked` when Hyprland confirms a
  lock to its locker (`SessionLock.cpp:149`, `forceLock` :259) and `unlocked` at `unlock_and_destroy` (:130) or `forceUnlock`
  (:249), whichever client locked. Protocol XML: `hyprwm/hyprland-protocols` (BSD-3-Clause).
- Hyprland's `send_shortcut` / `send_key_state` take a window selector (`src/config/lua/bindings/LuaBindingsDispatchers.cpp:402-440`):
  the keys go to that window's surface, then the keyboard focus goes back to the previous surface
  (`src/config/shared/actions/ConfigActions.cpp:1530`). `CSeatManager::setKeyboardFocus` does not look at the session lock,
  and the Lua API has no lock query.
- wl-clipboard 2.3.0 (Arch extra `1:2.3.0-1`): `wl-paste --watch` sets `CLIPBOARD_STATE=sensitive` when the offer lists
  `x-kde-passwordManagerHint` (presence only, `src/wl-paste.c:103`), but only after it asked the source for the data and piped
  it to the command (`wl-paste.c:316-342`); one MIME type per watcher.
- Omarchy 4.0.4 (`c668141`, installed) and 4.0.6 (`237f1b4`), `default/hypr/bindings/clipboard.lua`: SUPER+V "Universal
  paste" sends Ctrl+V, or Shift+Insert to a window tagged `terminal`; SUPER+C sends Ctrl+C or Ctrl+Insert; SUPER+CTRL+V is the
  "Clipboard manager". Its terminal configs make Shift+Insert paste the clipboard (`config/alacritty/alacritty.toml:22`,
  `config/foot/foot.ini:20`, `config/ghostty/config:26`); its kitty config does not (kitty's default Shift+Insert pastes the
  primary selection). The unreleased `quattro` branch (`bedf37a`) sends Ctrl+Shift+V to terminals instead. Its clipboard
  plugin (`shell/plugins/clipboard/` at `bedf37a`): two `wl-paste --watch` (text, `image/png`) running a bash/perl/jq script
  per copy; history in `~/.local/state/omarchy/clipboard-history.json` (500 entries, no expiry); no lock check; paste with
  `wtype -M shift -k Insert`. Grassfield's session loads none of Omarchy's bindings and replaces `omarchy-shell`, so neither
  runs there; Grassfield never reads Omarchy's file.
- The hint: `x-kde-passwordManagerHint` with the value `secret` (Klipper ignores such copies since 2018; KeePassXC and
  Firefox's password manager set it; 1Password for Linux according to its release notes, not verified here; Bitwarden does not,
  an open request).

## Owner decisions (2026-10-27, asked with options; answers verbatim)
Each question was asked in French with these options (the first one marked "Recommandé"); the answer is the owner's choice.
| # | Question (short) | Options offered | Answer |
|---|---|---|---|
| Q1 | Source de capture du presse-papiers | « Helper natif (Recommandé) » (a native ext-data-control helper that never requests a hinted copy's data); « wl-paste --watch » (Omarchy 4's model) | « Helper natif (Recommandé) » |
| Q2 | Stockage de l'historique | « Mémoire seule (Recommandé) »; « Mémoire + tmpfs session »; « Disque en option » (memory by default, an option to keep it under `$XDG_STATE_HOME`, 0600, bounded, purged at the retention) | « Disque en option » |
| Q3 | Comment coller dans l'app au premier plan sans jamais agir sur une autre fenêtre | « Raccourci ciblé (Recommandé) » (one Lua function checks the remembered window and sends it the paste key; its description said the terminal key followed Omarchy 4's universal paste, which is wrong for 4.0.4, where it is Shift+Insert: the key is now chosen from the terminals' defaults, §4); « Copier seulement »; « wtype (clavier virtuel) » | « Raccourci ciblé (Recommandé) » |
| Q4 | État par défaut et limites | « Modèle macOS (Recommandé) » (off until allowed, 8 h; 100 items, text 256 KiB, image 16 MiB and 8,192 px, 64 MiB, thumbnails 256 px); « Activé par défaut »; « Limites plus strictes » | « Modèle macOS (Recommandé) » |
| Q5 | Où garder les éléments épinglés ? | « Toujours sur disque (Recommandé) » (Windows' model, 50 items, 32 MiB); « Disque seulement avec l'option »; « Mémoire seule » | « Toujours sur disque (Recommandé) » |
| Q6 | Texte mis en forme : garder la mise en forme comme Windows, ou texte brut comme macOS ? | « Mise en forme + texte brut (Recommandé) » (HTML and RTF kept, "Paste as Plain Text"); « Texte brut seulement » | « Mise en forme + texte brut (Recommandé) » |
| Q7 | Raccourci direct vers l'historique | first asked with « Super+V (Recommandé) », « Ctrl+Super+V », « Aucun » → « Super+V (Recommandé) »; the review showed the premise wrong (Omarchy's SUPER+V is its universal paste, Super is ⌘ here); asked again with « Super+Ctrl+V (Recommandé) » (Omarchy's "Clipboard manager" key), « Super+Shift+V », « Aucun » | « Super+Ctrl+V (Recommandé) » |
| Q8 | Effacement quand il y a des épinglés | « Modèle Windows (Recommandé) » (Clear History spares pins; Settings' confirmation can also delete them; turning off keeps pins); « Tout effacer toujours » | « Modèle Windows (Recommandé) » |
| Q9 | Choisir un élément (asked with Apple's text: "Click [icon] … or select the item and press Command-C." then "To paste the item, click where you want it to appear, then press Command-V."): que fait Retour (ou un clic) ? | « Coller automatiquement (Recommandé) » (Windows' model and the brief; ⌘C and the copy button only copy, as Apple documents); « Copier puis ⌘V (Apple) »; « Les deux » | « Coller automatiquement (Recommandé) » |
| Q10 | Libellé du bouton de l'invite au premier usage | « Autoriser (Recommandé) » (macOS 27's "Allow"); « Activer » (macOS 26 "Enable", Windows "Turn on") | « Autoriser (Recommandé) » |
| Q11 | Une invite polkit en écho peut être copiée depuis son champ : que fait l'historique ? | « Ne rien enregistrer (Recommandé) » (no copy recorded while an authorization dialog is shown and 2 s after it closes; described as needing no change in `shell/security`, which proved wrong: the binding needs one read-only property in `AuthAgent`, §2); « Bloquer aussi la copie » (also change `PasswordField.qml`, opus PASS); « Enregistrer normalement » | « Ne rien enregistrer (Recommandé) » |

## Decisions delegated by the owner (2026-10-27)
Asked of no one: « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour
l'utilisateur » (the owner's work rule of 2026-10-27); each choice follows that rule and is checked in the integrator's review.
| # | Question | Options | Choice | Rule applied |
|---|---|---|---|---|
| Q12 | New copies' images wait for the one image worker (each up to 16 MiB in memory): what when they come faster than it decodes? (review of 963e173, minor 6) | no bound (every image kept, memory unbounded); at most 4 waiting, a newer one not recorded; the newest replaces the oldest waiting | at most 4 waiting, a newer one not recorded (logged by reason) | macOS first: every copy made at a person's pace is recorded (a worker ends within 2 s, so only images copied faster than one every half second for seconds on end reach the bound); nothing for the user to do; memory stays bounded like the history (64 MiB) |
| Q13 | A stored image (pinned, or in the opt-in history) whose thumbnail fails (a worker late under load, one that cannot start): what happens to it? (review of 963e173, MAJOR 2) | delete it (step 1's first code); keep it without a thumbnail and try again by itself; keep it and ask the user to act | keep it, shown without a thumbnail, tried again up to 3 times a minute apart, then at each start | macOS first: macOS never drops a clipboard item because its preview failed; no technical intervention: nothing to click, run or repair |
| Q14 | "Not Now" on the first-use prompt: where does the person land? (step 2) | close Search; back to Search's results with the field emptied; stay in the empty view | back to Search's results, Search stays open (the history stays off) | macOS first: the prompt belongs to Search and declining it leaves Search as it was, as Backspace leaves the view; nothing else to do |
| Q15 | A paste chosen when Search opened over no window (the desktop) or over a window that closed since (step 2) | keep Search open and do nothing; copy only and close Search; refuse with a notice | the item is copied and Search closes, ready for Ctrl+V | macOS first: Apple's own flow is copy then ⌘V (M-6) and a choice closes Search; no key is ever sent to a window the person did not leave Search from |
| Q16 | How a pinned row is marked (step 2) | a pin glyph after the title; a "Pinned" header; the row's pin button kept visible, filled | the filled pin button stays visible on a pinned row (its accessible name adds "Pinned") | macOS has no pins (M-14) and no group headers in Search (macOS 27); Windows marks a pinned item by its filled pin; one control shows and undoes it |
| Q17 | Where the item preview opens and what it follows (step 2) | a sheet over the results; a panel beside the results; a separate window | a glass panel beside the results (right, or left without room), as tall as the results, following the selection until Space, Ctrl+Y or Esc | macOS first: Quick Look sits beside Spotlight's results and follows the selection; no window to manage |
| Q18 | A copy arriving while the view is open: where does the selection go? (step 2) | to the new top row; it stays on the selected item | it stays on the selected item (the first row when the view opens) | macOS first: a list never moves the selection under the person's keys; a Return never pastes an item that was not picked |
| Q19 | Super+Ctrl+V while another program holds the session locked (the helper's `L 1`) (step 2) | open Search on its results; open nothing | open nothing; either lock closes Search and drops its query | PV-9, as for this shell's lock; nothing for the person to do |
| Q20 | How long a row says "Copied" after a copy (step 2) | while selected; 1.5 s; until Search closes | 1.5 s (token `search.clipCopiedMs`), then its time again | macOS first: a short confirmation in place, as Spotlight's copy button gives; nothing to dismiss |
| Q21 | The time on a row copied before today (step 2) | the time alone; the date and the time; a relative day ("Yesterday") | the date and time in the locale's short formats ("Copied on …", « Copié le … »); today the time alone ("Copied 11:23", « Copié à 11:23 ») | macOS first: macOS 26 shows the clock time (M-4); a date only where the time alone would mislead |
| Q22 | How the keyboard reaches the More button (step 2) | the mouse only; Tab from the field; a key of its own | Tab from the field puts the focus ring on More; Return, Space or Down opens its menu; Tab or Esc goes back to the field | macOS first: full keyboard access reaches every control with Tab (the spec's table: "Tab reaches it"); every action has a key (CB-12) |
| Q23 | The helper refuses or does not answer a copy or a paste (another program's lock, the item gone, no helper): what does the person see? (review of 28d2651) | Search closes as after any choice; Search stays open with a notice; an alert | Search stays open, the selection where it was, and the view says "The item could not be copied" (« L’élément n’a pas pu être copié ») for 3 s; nothing is pasted | macOS first: a choice that did nothing must not look like one that worked; the person can try again or press Esc, with nothing to repair |
| Q24 | Where Settings > Search puts the clipboard history's settings (step 3) | first, above Search History; between Search History and Search Results; last, after Search Results | last, in a group of its own after Search Results | macOS first: macOS 26.0 shows its Clipboard Search group last in the pane (W-39); macOS 27's layout of it is not captured |
| Q25 | The duration pop-up and Keep clipboard history after logging out while the history is off (step 3) | always active; inactive (dimmed) while off; hidden while off | inactive while off; Clear Clipboard History… stays active (pinned items stay while the history is off and can be cleared) | macOS first: a setting that does nothing is dimmed, not hidden, as macOS dims dependent controls; nothing to set by hand |
| Q26 | Clear Clipboard History…'s "Also delete pinned items" (step 3) | checked by default; unchecked each time the sheet opens; remembered | unchecked each time; Clear keeps pins unless the person checks it then | macOS first: Clear deletes what macOS's history holds (no pins there); deleting pins, Windows' "Clear all" never does, only on an explicit choice; nothing irreversible by default |
| Q27 | grassfield.json becomes unusable (malformed, unreadable, too large, unsafe, missing, empty) while the history runs: what does the clipboard history do? (review of c1fc254) | follow the values read then (the defaults: the history off, which deletes it); stop recording but delete nothing; keep the last usable values until the file is usable again | keep the last usable values: nothing is started, stopped, cleared or deleted until a usable read; then only what differs from them is applied | macOS first: preferences that cannot be read never erase a person's data, and the history keeps working as the person set it; no technical intervention: the history keeps working as set, with nothing to repair for it |

## Decision
1. **Capture and serving: `grassfield-clipboard-helper`.** One native C++17 process (`apps/clipboard-helper/`, Qt 6 Core and
   Gui, libwayland-client; precedent ADR-0025), installed to `/usr/lib/grassfield/`, started by the shell service
   `shell/services/Clipboard.qml` only while the history is on, killed with the shell (`PR_SET_PDEATHSIG`, end of stdin), at
   nice 10, with `umask(077)` set first. It connects only to the display named by its `--display` argument (8) and binds
   `ext_data_control_manager_v1` and `hyprland_lock_notifier_v1`; without either it captures nothing (fail closed) and the
   view says so. It never reads the primary selection. On each `selection` event:
   a. it reads the offer's MIME list (at most 64 types of at most 255 bytes; more: the copy is not recorded);
   b. it drops the offer **without requesting any data** when the list has `x-kde-passwordManagerHint` (any value: the
      presence is enough, the value is never read) or `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`,
      `org.nspasteboard.AutoGeneratedType`; when the offer is its own (marker type, 4); when it is the first selection after
      a start, an unlock or a resume (6);
   c. it picks one kind: files (`text/uri-list` holding only `file://` URIs), else an image (`image/png`, `image/jpeg` or
      `image/webp`, the first offered in that order; other image types are not recorded), else text. A text item has a plain
      part (`text/plain;charset=utf-8`, `UTF8_STRING`, `text/plain`, `STRING`, `TEXT`, the first offered) and keeps the
      formatted parts offered with it (`text/html`; `text/rtf` or `application/rtf`), as Windows keeps HTML (Q6). With HTML and
      no plain type, the plain part is made from the HTML by a linear tag stripper in the helper (no HTML engine, nothing
      loaded). Anything else is not recorded;
   d. it asks the shell (`O`, 2) and reads the data only on its answer `Y`;
   e. it reads each chosen type through a non-blocking pipe with a cap (plain text 256 KiB, HTML 1 MiB, RTF 1 MiB, files
      64 KiB and 1,000 URIs, image 16 MiB) and a 2 s deadline per type; plain text, files or an image over the cap or late:
      the copy is not recorded, never truncated; a formatted part over its cap or late is dropped and the plain text kept.
      Text must decode (UTF-8; Latin-1 for `STRING` and `TEXT` only) and not be blank;
   f. an image is decoded only to make its thumbnail, and never in the helper: a worker process (the same binary,
      `--thumbnail <png|jpeg|webp> <max px>`, started per image with an environment holding only `LC_ALL=C`, the image's bytes
      on stdin and nothing of the history) reads it with `QImageReader` given that one format, `setAutoDetectImageFormat(false)` and
      `setDecideFormatFromContent(false)`, so no other image plugin (PDF, SVG, TIFF, JPEG 2000…) can be reached; it checks the
      size before decoding (at most 8,192 px a side and 64 megapixels, allocation limit 256 MiB) and runs under
      `RLIMIT_AS` 1 GiB, `RLIMIT_CPU` 2 s, `RLIMIT_FSIZE` 0, `PR_SET_PDEATHSIG`, and a 2 s wall deadline after which it is
      killed; it writes a PNG of at most 256 px on its long side (1 MiB at most) to stdout. A worker that fails, is killed or
      answers anything else: the copy is not recorded. The original bytes are kept as they came, for pasting. One worker runs
      at a time for every image, new copies before stored thumbnails (up to 150 at start); at most 4 new images wait for it (a newer one is not
      recorded), and Clear History and Clear Pinned cancel the new images waiting or running (one whose worker ends after a
      clear is never added). A stored image (pinned, or in the opt-in history) whose worker fails is never deleted: it is shown
      without a thumbnail, which is tried again up to 3 times a minute apart, then at the next start (review of 963e173);
   g. an item with the same kind and data (SHA-256 of the plain part, the file list or the image) as an unpinned one moves to
      the top with the new time instead of being added twice; one equal to a pinned item leaves the pinned item where it is
      and adds nothing.
   Limits: the history (unpinned items) holds 100 items and 64 MiB; past either, its oldest items go. Pinned items: 50 and
   32 MiB, never pushed out and never expired; a pin past either limit is refused with a notice. Retention of unpinned items
   (30 minutes, 8 hours, 7 days; default 8 hours): an older item is removed, checked every minute, at each copy and when the
   view opens. Each item keeps its wall-clock time, the boot id (`/proc/sys/kernel/random/boot_id`) and its `CLOCK_BOOTTIME`
   time; its age is the larger of the wall-clock and boot-clock differences when the boot id is the current one, and the
   wall-clock difference alone otherwise; an item dated in the future is removed (a clock set back never keeps an item
   longer).

2. **Shell and helper.** One line protocol on stdin and stdout, fields separated by US and escaped (ADR-0025's rule), no
   other channel. Shell to helper: retention, history store on or off, pause, resume, clear the unpinned items, clear the
   pinned items, delete an item, pin, unpin, set the clipboard to an item (with or without its formatted parts), search, make
   or drop an item's preview (through the worker of 1f, at most 1,024 px on its long side, in the runtime directory below,
   only while the preview is open), and the answer to each offer (`Y <n> <app id>` or `N <n>`). Helper to shell: the lock
   state the compositor reports (`L 1` / `L 0`), an offer to decide (`O <n> <kind>`), item metadata (id, kind, MIME types,
   size, time, pinned, formatted, title: the first line cut to 200 characters with control characters removed, an excerpt of
   at most 400 characters for the text thumbnail, the thumbnail path, the source app), removals, "the clipboard now holds
   item n", search results (ids), notices (pin limit), and its state (`ok`, `unsupported`, `error <why>`; a pause is the
   shell's own command and is not echoed). The full text stays in
   the helper: the search runs there (case- and accent-insensitive substring of the plain text and file names).
   The shell answers `Y` only while the history is on, the session is not locked by either source (6), no authorization
   dialog is shown and none closed in the last 2 s (Q11), and the active window is not a password manager
   the session hides from screen sharing (`config/hypr/grassfield/privacy.lua`; for apps that set no hint, such as
   Bitwarden). Neither process logs content: counts, kinds, sizes and reasons only, never text, file names, URLs, titles or
   hashes.
   The authorization state (counter-review of the step 0 PASS, minor d): `AuthAgent` exposes no "dialog shown" property
   (`win.shown` is internal; `requestStartedAt` is for display only and never compared). Step 1 adds one read-only property
   to `shell/security/polkit/AuthAgent.qml`, `requestActive: dialogModel.active` (a request is open: its sheet shown, or held
   behind the lock), which nothing in the agent reads; `shell.qml` gives the agent an id and binds it to a new
   `SessionState.authorizing`, as it binds `Lock.locked` to `SessionState.locked`. When `authorizing` becomes false the
   service starts a 2 s Timer (monotonic: a clock set back never lengthens it) and answers `N` until it fires. That line under `shell/security` needs an opus PASS (R12) and is
   named in the step 1 pull request.

3. **Source app.** Data control does not say which client set the selection. The shell's `Y` carries the app of the window
   active when the offer was decided (Hyprland's active window), and the row shows its icon as macOS shows the source app;
   no badge when no window was active. Known limit: a copy made by a background program is attributed to the frontmost app.

4. **Copy and paste.** To copy an item (the copy button, ⌘C, the menu's Copy; Apple's documented flow) the helper becomes the
   clipboard owner with an `ext_data_control_source_v1` offering the item's types: text as the five plain types above plus its
   formatted parts; an image as its own MIME type; files as `text/uri-list` and `x-special/gnome-copied-files` ("copy", never a
   cut: a cut item from the history is pasted as a copy); plus the marker type `application/x-grassfield-clipboard-item` (the
   item id), by which the helper knows its own selection (the item moves to the top, step 1g). "Paste as Plain Text" (the
   menu, Shift+Return) offers the plain types and the marker only. The helper serves until another client takes the selection
   or it exits (the clipboard is then empty, as when any Wayland app that owns it quits); a reader that takes nothing for 2 s
   has its pipe closed (one that stops reading never holds the helper; a slow one that keeps reading, such as an X11 app
   pasting a large image through XWayland, gets the whole answer).
   To paste (Q9: Return, Enter, a click, the menu's Paste; Shift+Return or the menu's Paste as Plain Text): the helper copies
   the item; when it reports owning the selection, Search closes and `FocusReturn` gives the keyboard back to the window active
   when Search opened; once that window is active again (at most 1 s), and only while neither `SessionState.locked` nor the
   helper's `L 1` says the session is locked, the shell sends Hyprland one Lua function (`Hyprland.dispatch`, the `Zoom.js`
   pattern) that checks that the active window is still that address and only then sends it Ctrl+V, or Ctrl+Shift+V when the
   window is a terminal, with `window = "address:<addr>"`: the same function first arms a Hyprland timer for the key up 50 ms
   later, to the same address, then sends the key down. The key up does **not** check the active window again: a V that went
   down is always
   released in the window that got it, whatever became active meanwhile (counter-review, minor b); if that window has closed,
   the up is a no-op (`window not found`). Window addresses can be reused by a new window (counter-review, minor c): the
   shell drops the paste when Hyprland reports `closewindow` for the remembered address at any time between Search's opening
   and the dispatch, so a new window that took the address never gets the keys (step 1 has the decision, `mayPaste`'s
   `closedSinceOpen`; step 2 tracks `closewindow` with the paste it guards). Ctrl+Shift+V is the clipboard
   paste of alacritty, kitty, ghostty, foot and wezterm by default and is kept by Omarchy 4.0.4's terminal configs
   (`foot.ini:20` lists it beside Shift+Insert); Shift+Insert is not used, as kitty pastes the primary selection with it. The
   terminal test is the one of `config/hypr/grassfield/forwarding.lua:26-37` as a whole (its class list and its
   `org.omarchy.` and `tui.` prefixes): step 1 moves it into one Lua module that both `forwarding.lua` and the paste function
   use, or, if Hyprland's Lua state cannot load it from a dispatched function, the shell embeds the same predicate and a test
   runs both on shared vectors. The check and the keys run in one compositor call: the keys can reach no other window.
   Nothing is sent while the session is locked, when no window was active at open (the desktop), when another window became
   active, while another full-attention shell surface is open, or after 1 s: the item then stays on the clipboard only. No
   virtual keyboard.
   Residual risk: Hyprland would still deliver a window-targeted key behind a session lock (no lock check in
   `setKeyboardFocus`) and the Lua API cannot ask; the shell checks both lock sources just before it dispatches, and the
   helper's `L 1` arrives only when Hyprland confirms a lock to its locker (`CSessionLock::sendLocked`). A paste can therefore
   still reach the chosen window, with the chosen item, if a lock is requested between that check and Hyprland running the
   function, or before Hyprland confirmed a lock requested just earlier; nothing leaves the window.

5. **Storage.** `$XDG_STATE_HOME/grassfield/clipboard/` holds up to two stores, each an `index.json`
   (`{version: 1, items: [{id, kind, mimes, size, copiedAt, bootId, bootAt, pinnedAt, title, app}]}`) and one `<id>.item` per
   item (its parts, length-prefixed). Directories are created 0700 and files 0600: the helper's `umask(077)` and an explicit
   `QSaveFile::setPermissions(ReadOwner | WriteOwner)` before each commit (QSaveFile creates its file 0666 minus the umask: 0644
   under the usual 022, as the integrator measured), written atomically:
   - `pinned/`, always (Q5, Windows' model): an item is written when it is pinned and removed when it is unpinned, deleted,
     or when the pinned items are cleared; it never expires;
   - `history/`, only with the opt-in `search.clipboard.keepOnDisk` (Q2; off by default; a Grassfield addition, macOS has no
     such switch): the unpinned items, same limits and retention (applied again when the store is loaded); turning the switch
     off deletes it at once.
   Without `history/`, unpinned items live in the helper's memory only and are lost at logout and when the shell restarts (as
   Windows loses them at a restart). Thumbnails and previews are 0600 files in `$XDG_RUNTIME_DIR/grassfield/clipboard/`
   (0700, tmpfs: RAM), removed with their item and when the helper starts or exits. Only the helper reads the stores, with
   bounds: regular files of the user, opened with `O_NOFOLLOW`, mode 0600, `index.json` at most 1 MiB, each item at most
   its kind's caps; a store that breaks a rule is deleted, not read. The files of a store that its index does not name (an
   item removed or expired whose file a crash left, the index being written first; the temporary of an interrupted write) are
   deleted when it is loaded. Known limit: a deleted file's blocks can stay on the disk
   until reused (btrfs copy-on-write, SSD); Omarchy's full-disk encryption covers them at rest. In a dev session the stores
   are under `Mode.stateDir`.

6. **Lock, off switch, clearing.** Two lock sources, either one is enough: the compositor's (the helper's
   `hyprland_lock_notifier_v1`, whichever program locked) and the shell's (`SessionState.locked`, which also covers this
   shell's "locking" phase before Hyprland confirms). The helper starts paused: it creates its data-control device only after
   the lock notification is bound and a roundtrip brought no `locked` event, and only while the shell has not paused it. On
   `locked`, or on the shell's `pause` (sent while `SessionState.locked`), it destroys the device: no selection event reaches
   it and nothing is read. On `unlocked` with the shell's `resume` it creates the device again and never records the selection
   it then receives first (it may have been copied during the lock). The view cannot open while either source says locked
   (GF-116 `SessionState.refuses`, plus the helper's `L 1`); items keep expiring. Residual risk: between a foreign locker's
   request and Hyprland's confirmation of its lock, a copy can still be recorded (no event exists for that phase).
   Clearing follows Windows (Q8): Clear History (the view's More menu) and Clear Clipboard History (Settings > Search, asks
   first, then writes `search.clipboard.clearedAt`, the pattern of `search.historyResetAt` in PR #9) delete every unpinned
   item, memory and `history/` (with no helper running, as while it waits to restart after a crash, the shell runs it once
   with `--clear-history`, and no helper starts before that ends); Settings' confirmation also offers "Also delete pinned items" (writes
   `search.clipboard.pinnedClearedAt` as well), which empties `pinned/`: that is the "clear all". Turning the history off
   (`search.clipboard.enabled`, off by default) stops the helper and deletes the unpinned items (a running helper deletes its
   `history/` before it ends; otherwise the shell runs it once with `--clear-history`, also at each shell start while the
   history is off; a helper started with the history store off deletes any `history/` left); pinned items stay in
   `pinned/`, unread and not shown, until the history is turned on again (or deleted from Settings: with the history off,
   the shell runs the helper once with `--apply-clears`). The current clipboard is left as it is (both systems clear the
   history, not the clipboard).
   Clears asked while no helper runs (review of f7cd664): Settings writes `clearedAt` and `pinnedClearedAt` whether the shell
   runs or not, so the helper keeps the values it carried out in `<state>/clears` (0600, read with the stores' rules, a broken
   record deleted and read as missing) and is given the settings' values: `--cleared-at` and `--pinned-cleared-at` at start,
   `CH <ms>` and `CP <ms>` while it runs (Search's own Clear History sends `CH` alone, which records nothing). At start, before
   anything is loaded, shown or recorded, a value other than the one carried out deletes that store (also after a clock set
   back: never fewer deletions); with no record (a store from before it existed) only the items from before the clear go (the
   copy's time for the history, the pin's for the pinned store). With the history off the shell runs the helper once with
   `--apply-clears`, at its first decision and at each change; the store jobs (`--clear-history`, `--apply-clears`) run one
   after the other, never beside each other or the helper, and `--apply-clears` is given the times as they are when it starts.
   If the record cannot be written, the next start finds it older than the setting and deletes that store again, items
   copied or pinned since the clear included: never fewer deletions, so a failed write costs data, never privacy.
   The settings the shell acts on (reviews of c1fc254 and 3f924d9): only a usable read of grassfield.json, valid
   (`Settings.validRead`) and not empty (`Settings.emptyFile`: empty or only whitespace, what a cut write leaves). Before
   the first read every key reads its default (the history off, no clear asked); a malformed, unreadable, too large or
   unsafe file reads the defaults or the last good values, a missing or empty one the defaults. Acting on those deleted a
   kept history at each shell start, and an unreadable or empty file would delete a history the person kept. So the service takes the
   history's settings only from a usable read, once the read is complete, and keeps the last usable values while the file
   is not usable (Q27). Nothing is decided, run or deleted before the first usable read; with no usable file (a missing
   one included) the history stays off and nothing is deleted until Settings or Search's Allow writes one.

7. **Presentation and settings** (`docs/specs/clipboard.md`): the Clipboard view of Search, reached by ⌘4 (Super+4, which
   `forwarding.lua` sends to Search as Ctrl+4; physical Ctrl+4 switches to Space 4), the Clipboard button to the right of the
   empty field, and Super+Ctrl+V from anywhere (Q7; Omarchy's "Clipboard manager" key: `bindings.lua` calls the action-class
   IPC function `search clipboard`, which opens Search in that view or closes it); macOS 27's capsule and rows (ADR-0024);
   pinned items first, with a pin mark, then the history newest first; a pin button and a copy button on each row; the
   first-use prompt with macOS 27's wording, "Not Now" and "Allow" (Q10: « Plus tard », « Autoriser »); the More menu; the
   row menu (Paste, Paste as Plain Text, Copy, Pin or Unpin, Delete Item); an item preview. Settings > Search gets "Results
   from Clipboard", the retention pop-up, "Clear Clipboard History…" (with "Also delete pinned items") and "Keep clipboard
   history after logging out" (step 3, after the Settings PRs #8, #9 and #10). The keys (`search.clipboard.enabled`,
   `.retention`, `.keepOnDisk`, `.clearedAt`, `.pinnedClearedAt`) come from the schema (ADR-0020) in step 1, as the shell
   reads them.
   Step 2 builds the view in `shell/search/` (`Search.qml` the controller, `SearchPanel.qml` the window, `ClipboardView.js`
   the pure parts: rows, kinds, the key map, the row menu, the selection after a delete), with four glyphs (`clipboard`, `copy`,
   `pin`, `pin-fill`) and the `search.clip*` tokens. The rows come from the service's items in the helper's order, filtered by
   the helper's answer to `Q` (stale answers ignored); the row menu and the More menu are `PopupMenu`s inside Search's window,
   which already covers the screen and holds the keyboard; the preview panel shows the helper's `V` answer (text as plain text
   in a scrollable area, an image by its path in the runtime directory) and drops it (`VD`) when it closes or moves on. The paste
   of §4 lives in the service (`Clipboard.paste`): Search remembers the window active at its opening
   (`Compositor.activeWindow()`, never the desktop) with `watchTarget`, `Compositor.windowClosed` (from Hyprland's
   `closewindow`) marks it closed, the helper's `A` closes Search, and a 50 ms timer checks `pasteStep` until it dispatches
   `pasteRequest` or drops the paste. Review of 28d2651 (paste safety): the paste keeps its own target and whether that window
   closed, so a later `watchTarget` never redirects it; closing Search before the helper's `A` (Esc, a click outside, a lock,
   another surface) drops the paste, so a late `A` pastes nothing; Search opening again drops a paste still waiting; after the
   `A`, each check drops the paste at once when either lock source says locked, the target closed, or a full-attention
   surface is open (Search has released FocusReturn by then, so one open at a check opened after the choice), and the 1 s is
   one Qt timer started at the `A` (monotonic), never a count of checks. Search closes only once the helper owns the item,
   also for a copy only; a copy or paste the helper refuses or leaves unanswered for 1 s keeps Search open with "The item
   could not be copied" (Q23), and Copy's "Copied" shows on the helper's `A`. ⌘4 is matched by the 4 key's place (xkb
   keycode 13, what `forwarding.lua` sends) as well as its symbol, so it works on AZERTY, where that key types an apostrophe.
   The step 2 counter-review's nits (fixed in step 3): a paste also needs the helper to still own the item chosen (`ownedId`,
   from each `A`): a Copy chosen before the `A` drops the waiting paste ("another item copied"), and a check that finds the
   clipboard taken by another app or holding another item drops it ("the clipboard changed"), so Ctrl+V never pastes what
   was not chosen; one function (`pasteState`) builds what each check sees from the paste's own target, and the tests make
   the live `pasteTarget` differ from it.
   Step 3 builds Settings > Search's clipboard group (`apps/settings/qml/SearchPage.qml`, after Search Results, Q24): Results
   from Clipboard (`search.clipboard.enabled`, its explanation says that turning it off deletes the items not pinned),
   "Clipboard history is available in Search for" (a pop-up: 30 minutes, 8 hours, 7 days; `.retention`), Keep clipboard history
   after logging out (`.keepOnDisk`), both inactive while the history is off (Q25), and Clipboard History with Clear Clipboard
   History…, which asks first in a sheet (Main.qml): "Clear your clipboard history?", the check box "Also delete pinned items"
   (unchecked each time, Q26) and Clear; `SearchPage.clearClipboard` then writes `.clearedAt`, and `.pinnedClearedAt` too
   when the box is checked, in one write. The shell follows the keys live (step 1). The Settings sidebar's search finds the
   pane with "clipboard", "copy" and "paste".

8. **Display and dev mode (ADR-0019).** The helper never reads `WAYLAND_DISPLAY` or `WAYLAND_SOCKET` and never calls
   `wl_display_connect`: libwayland takes `WAYLAND_SOCKET` first even when a display name is given (the counter-review
   connected through a decoy `WAYLAND_SOCKET` and the path was ignored, minor a). The helper unsets both variables first, then
   checks the path named by `--display <absolute path>` (no default; `lstat`: a socket owned by the user), opens an `AF_UNIX`
   socket itself, `connect()`s to that path, checks the peer (`SO_PEERCRED`: the same user) and hands the descriptor to
   `wl_display_connect_to_fd`. A missing or relative path, a path that is not such a socket, a failed connect or another peer
   user stops it with an error. So no test, script or debugging run of the helper can reach a display it was not explicitly
   given; a test passes a decoy `WAYLAND_SOCKET` (a connected descriptor to a second fake server) and checks that this server
   sees no client and that the helper talks to the `--display` server only. The shell names the socket: in a real session
   `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` (or `WAYLAND_DISPLAY` when absolute); in a dev session only the absolute path in
   `GRASSFIELD_CLIPBOARD_DISPLAY` (`scripts/dev/shell-run.sh` sets the nested socket), and without it no helper starts and the
   view says the history is off in development. `CLIPBOARD_HELPER` names another helper binary in dev. Tests run the helper
   under `env -i` with a `mktemp -d` runtime directory, start the fake server there, pass its socket as `--display` and
   assert that path lies inside that directory; they also check that the helper refuses to start without `--display`, with a
   relative name and with a non-socket. The shell's own tests start no real helper: QML unit tests drive the service's pure
   logic, and the headless Search scenario runs under `env -i` with `GRASSFIELD_DEV=1`, no `GRASSFIELD_SESSION`, a fake helper
   (`CLIPBOARD_HELPER`) and a fake socket, and fails if the helper it started was given any other `--display`.

## macOS reference
Spotlight keeps a rolling clipboard history on the Mac only, off until allowed, for 30 minutes, 8 hours or 7 days; copies an
app marks as concealed or transient (Apple's Passwords) are not kept (press); Apple's help documents copying an item (⌘C or
its copy button) and pasting it with ⌘V; press sources say Return or a click pastes into the frontmost app; the history can be
cleared from the view or from Spotlight settings.

## Windows reference
Win+V opens the history anywhere; choosing an item pastes it; text, HTML and bitmaps up to 4 MB, 25 entries; pinned items
stay through restarts and "Clear all"; an item can be deleted or pasted as text; sync goes through a Microsoft account.
Grassfield takes the direct key (on Super+Ctrl+V), the paste on choice, the pins, the formats and Paste as Plain Text, with
larger limits; it keeps everything on the machine.

## Alternatives rejected
- `wl-paste --watch` (Omarchy 4's model): the data of a hinted copy is requested and piped before the script can refuse it; one
  type per watcher (two watchers, and a second `wl-paste --list-types` can see a newer selection); a process chain per copy;
  `wl-copy` restores one type and leaves one forked process per item; no way to know its own copies.
- `wlr-data-control` as well: the same capabilities; the `ext` protocol is the standard one and Hyprland 0.56.2 has both.
- `Quickshell.clipboardText`: empty unless a Quickshell window has the keyboard.
- Capture inside the shell (a C++ QML plugin) or the compositor plugin: data from any app (images) decoded in the shell or
  the compositor, where a crash or a stall takes the session down; the compositor plugin is optional (D3).
- Decoding images in the helper, or letting `QImageReader` guess the format: the helper holds the whole history, and content
  sniffing reaches every installed image plugin (PDF, SVG, TIFF, JPEG 2000) with no time limit.
- Reading the display from `WAYLAND_DISPLAY`, guarded by the dev rule: the guard holds only when `dev` is true; with
  `GRASSFIELD_SESSION=1` and `WAYLAND_DISPLAY=wayland-1` a test or a debugging run would watch the owner's clipboard.
- Pausing on `SessionState.locked` alone: it misses a lock taken by another program during the session.
- A virtual keyboard (`wtype`, `zwp_virtual_keyboard_v1`) for the paste: a new dependency, types into whatever has the
  keyboard at that moment, may raise Hyprland's keyboard permission prompt, and Shift+Insert pastes the primary selection in
  kitty.
- Copy only, as Apple's help describes (owner, Q9: paste on choice, as Windows; ⌘C and the copy button keep Apple's flow).
- The whole history on disk by default: privacy first, and macOS keeping the history across a logout is not verified.
- Pinned items in memory only, or on disk only with the opt-in switch: a pin that vanishes at logout is not Windows' pin
  (owner, Q5).
- Plain text only (macOS): less than Windows, which keeps HTML (owner, Q6). The preview never renders HTML.
- Super+V (first Q7 answer): Omarchy's universal paste and ⌘V for Grassfield's ⌘ users; Super+Shift+V or no direct key
  (owner, Q7 asked again).
- Sync across devices (Windows): nothing leaves the machine (brief, non-negotiable).
- Suggested actions on a copied phone number or date (Windows): deprecated by Microsoft; Search already offers commands.
- Changing `shell/security/PasswordField.qml` so that a revealed answer cannot be copied (owner, Q11: not recording is enough).
- A resident service (a systemd user unit) so that a shell restart keeps the history: a new service for a small gain; the
  opt-in store covers it.

## Consequences
- New binary in `grassfield-desktop`; no new runtime dependency (Qt 6, its image formats and libwayland-client are already
  required) and no new build dependency (`wayland-scanner` comes with `wayland`, already in `makedepends`). Vendored under
  `apps/clipboard-helper/protocols/`: `ext-data-control-v1.xml` (wayland-protocols 1.49, MIT) and
  `hyprland-lock-notify-v1.xml` (hyprland-protocols, BSD-3-Clause: its notice ships in `packaging/licenses/`); both listed in
  `THIRD_PARTY.md`.
- New settings keys (5), a state directory with an always-on pinned store and an opt-in history store (ADR-0020 table), two
  dev plumbing variables (ADR-0019 table), one binding (Super+Ctrl+V, with its Settings > Keyboard description in
  `apps/settings/qml/Bindings.js` and the French catalog), one read-only `AuthAgent.requestActive` (the only change under
  `shell/security`, opus PASS required) bound in `shell.qml` to a new `SessionState.authorizing`.
- IPC, documented in `docs/specs/security.md` with its code: one action-class function, `search clipboard` (Super+Ctrl+V;
  opens or closes the view, returns nothing, refused while locked: it opens only through `Search.show()`), and the dev-class
  `clipboard status` (step 2 adds the paste's target and outcome) and `search status` (step 2 adds the view, the prompt, the
  notice and the preview). No other hook was needed: the headless scenario drives the real controller and service. The Settings app clears through `search.clipboard.clearedAt` and
  `.pinnedClearedAt`.
- Tests never touch a real clipboard: the helper's logic under gtest (ASan too); the process under `env -i` against
  `tests/fixtures/fake-clipboard-server` (a test-only libwayland-server program offering `wl_seat`,
  `ext_data_control_manager_v1` and `hyprland_lock_notifier_v1` on a socket in a `mktemp -d` runtime directory, passed as
  `--display`) with copies of every kind, HTML with and without plain text, a hinted copy (no receive request may reach it),
  a source that hangs, oversized data, the own-copy marker, pins across a restart of the helper, a foreign lock (`locked` at
  bind and mid-run: no receive request until `unlocked`, first selection skipped), file modes, and the thumbnail worker
  (wrong format, oversized, too slow: killed, nothing recorded); the shell's decisions and the paste request under QML unit
  tests; a log canary. The real paste, Hyprland's data control and lock notifier, and a lock during a copy are checked by the
  integrator in the nested session; never in the owner's session.
- Steps: 0 this ADR and the spec (docs only); 1 the helper, the worker, the fake server, the shell service and the keys; 2 the
  view in Search and Super+Ctrl+V; 3 Settings > Search.
- Not verified: the macOS 27 clipboard view's exact look (no capture found), what macOS does at logout and when the history
  is turned off, its item limit, 8 hours as macOS 27's default (Apple's page lists the three durations only); Windows' keys
  inside Win+V; which hints password managers really set; the Lua `address` format, the `address:` selector and loading a
  Grassfield Lua module from a dispatched function in Hyprland 0.56.2 (nested, step 1); the terminals' default Ctrl+Shift+V
  (documented defaults, checked in nested in step 2).
- Not verified in step 2 (no Hyprland and no display in the cloud container where it was built): the view's look (`just shot`
  light and dark, en and fr), the real paste into a window and a terminal, ⌘4 forwarded as Ctrl+4 in the field, and the
  `address:` selector of the dispatched function; the integrator checks them in the nested session.
