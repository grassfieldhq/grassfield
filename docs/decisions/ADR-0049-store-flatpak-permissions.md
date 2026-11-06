# ADR-0049: What a Flatpak can reach, shown as the App Store shows privacy, and updates that ask for more held back
Status: Proposed (2026-11-05), applied provisionally (owner's standing instruction: decide alone, the recommended option,
macOS first, decisions recorded here) · Date: 2026-11-05 · Decider: owner (revisit), integrator (merge) · Number: 0049
(amends ADR-0037 SD25 and SD33; spec `docs/specs/store.md` SR11, SR24)

Inspired by Project Luma's `luma-depot` and `luma-installer` (`autoupdate.py` `pending_for`, `depot_permissions.py`
`diff`/`widens`; Apache-2.0): the idea of classifying an update's permission changes and holding the ones that widen.
No code copied; the classes, the vocabulary and the rules below are Grassfield's own.

## Context

The owner asked (2026-11-05, French, through the integrator) for the Luma idea "Flatpak permissions in the Store, with the
macOS 27 UI".

What the Store did before this ADR (main 78733ac):
- **Before an install and on the product page** (ADR-0037 SD25, spec SR11): `flatpakAccess` read the metadata into a flat
  list of classes (`network`, `home`, `folders`…, `sessionService:<name>`, `other:<text>`; 30 lines at most) shown as one
  comma-separated "Can Access" line in Information and in the install sheet. It never said *which* folder, nor read only or
  read and write, nor grouped anything.
- **On update** (SD33): the plan read the newer commit's metadata and listed the classes it *added*. A sheet then asked
  "Update / Cancel" for that app, and Update All asked once for all apps together: one click on Update in that sheet applied
  every widening update of the group. A grant made wider inside the same class (Downloads read only to read and write, a
  bus name from talk to own, `org.example.A` to `org.example.*`) was not seen at all.
- **Who applies Flatpak updates.** Only the Store (Update per app, Update All of the Flatpak group). Software Update
  (ADR-0033, `packaging/bin/grassfield-update-run`) runs `omarchy update` and its own steps, none of which touches
  Flatpaks; Omarchy 4.5.0's `bin/` calls `flatpak` only to install, remove and uninstall GeForce NOW and for a launcher
  entry's removal (checked in a clone of `basecamp/omarchy` v4.5.0). Grassfield has no automatic Flatpak update. The
  `flatpak` package itself ships no update timer.

flatpak's facts (from its source, `github.com/flatpak/flatpak` at 13665cf, 1.19.2; the owner runs Arch's 1.18):
- `flatpak remote-info --show-metadata <remote> <ref>` prints the commit's metadata key file; with `--commit=<c>` that
  commit's (S32a). `flatpak info --show-metadata <ref>` prints the deployed `metadata` file as is (`flatpak-builtins-info.c`).
- `flatpak info --show-permissions` prints the *effective* context: the metadata merged with `flatpak override`
  (`flatpak_context_load_for_deploy`), as a bare [Context] key file without [Application]. It has no counterpart before an
  install, so a diff of it against `remote-info` would compare two different things.
- Conditional grants (since 1.17): `if:<grant>:<condition>` in `shared`, `sockets`, `devices`, `features`; conditions
  `true`, `false`, `has-input-device`, `has-usb-device`, `has-wayland`, `has-usb-portal`, each may be `!`-negated; flatpak
  writes a plain `x` before `if:x:…` for older versions and reverts it when it reads the conditions
  (`flatpak_permission_serialize`, `flatpak_permission_deserialize`, `doc/flatpak-metadata.xml`).

## Decision

### D-1 One parser, grant by grant (`apps/store/src/flatpakpermissions.{h,cpp}`)
`flatpakPermissions(metadata, reading)` reads the same key file with the same reviewed rules as before (SD25 and its review
amendments: GLib's escapes, a filesystems entry's own, paths normalised, the harmless bus names, the escapes from the
sandbox, `login`, `outside`), and returns grants `{key, name, level}`: a place (`/`, `~`, `xdg-download`, `~/…`, `$RUN/…`,
`*`) with level 1 read only, 2 read and write, 3 create (flatpak's own ranking of `FlatpakFilesystemMode`); a bus name with
level 1 talk or 2 own; every other class as before, except that the grants flatpak keeps apart stay apart (amended after
the review of this ADR's PR, 2026-11-05; flatpak 13665cf, `flatpak_context_adds_permissions`, `common/flatpak-context.c`):
- **X11**: `x11` (the X11 display) and `x11Fallback` (X11 only where Wayland is missing). flatpak 1.17's
  `flatpak_context_compute_allowed_sockets` makes `fallback-x11` turn `x11` itself into `if:x11:!has-wayland`, so
  `fallback-x11`, `if:x11:!has-wayland` and `x11` beside `fallback-x11` are all `x11Fallback`, which grants no X11 in
  Grassfield's Wayland session; `x11` alone is X11.
- **USB**: `usb` (`devices=usb`: every USB device, directly, noted "without asking"), `usbPortal` (each
  `[USB Devices] enumerable-devices` query: what the USB portal lets it list and open) and `usbHidden` (each
  `hidden-devices` query: a restriction).
- **Shared memory**: `ipc` (`shared=ipc`) and `shm` (`devices=shm`).
`flatpakAccess` stays SD25's flat list of the same parse (x11 written, or fallback-x11 without a Wayland socket; ipc and
shm as sharedMemory; the portal's devices as usb): every case of `tst_flatpak` WhatItCanReach passes unchanged. Also:
- conditional grants are read as flatpak 1.17 reads them, under Grassfield's session: always Wayland, flatpak ≥ 1.17 (input
  and USB permissions always there); `if:x11:!has-wayland` is `x11Fallback`. Before, `x11;if:x11:!has-wayland` said "X11"
  plus an unknown grant; flatpak gives no X11 there.
- **two readings** (`FlatpakReading`). *Widest* (the product page, the install sheet, the newer side of an update):
  `!x` takes away only what the list grants after it, a key written twice counts every time, a condition the Store
  cannot check (`has-usb-portal`, an unknown one) grants. *Narrowest* (the installed side of an update): `!x` takes x
  away as flatpak does (a filesystems place too), a key written twice counts once (its last line, as GLib keeps it), such a
  condition grants nothing. An old grant read generously can then never hide a new one.
- an empty filesystems path is named as an unknown grant (was "Some of your folders");
- metadata over 1 MiB is unread (nothing said, no install plan, the update held); at most 200 grants are listed and the
  rest counted (`more`), so a hostile metadata cannot make the page or the diff quadratic.
`--show-metadata` stays the source on both sides (what the developer grants, the same before and after an install);
the user's own `flatpak override` is not shown (limit, below).

### D-2 The product page: "Permissions", cards as the App Store's privacy section
Under Information, a section "Permissions" (« Autorisations ») with one line ("What “X” can reach beyond its own window
and files, as Flatpak grants it.") and a grid of cards, one per group present, each with its glyph, title and items, as the
macOS 27 App Store lays out its privacy cards (no Apple name or asset; the "Can Access" line leaves Information). Groups
and their order: Files and Folders · Network · Camera and Other Devices · Microphone and Speakers · Display · Keys and
Passwords · Other Apps and Services · Background and Login · Outside Its Sandbox · Other. Items in plain words with the
mode ("Downloads (read and write)", "Your home folder (read only)"), a bus name with a friendly name when Grassfield knows
it ("Network settings (org.freedesktop.NetworkManager)"). A short honest note under each wide grant: all files, the home
folder, all devices, raw USB, the whole session or system bus, a bus wildcard, X11 (and, for its fallback, that this
Wayland session gives it none), the sound server's microphone, programs at login, outside the sandbox. A place written
with create says "read and write, created if missing"; the USB portal's devices and those hidden from it are named. Files and Folders ends with "Other files:
only those you choose in an Open or Save dialog." when neither all files nor the home folder is granted. Nothing granted:
one card "Only Its Own Window and Files". Unread metadata: no section (never "nothing"). The install sheet says the same
groups by title, one per short line, then the warning notes (a wide grant) each once under "Take care:", and points to the
page for the items (review of the Luma pull request, nested finding 10: the sheet had been a wall of text without the notes).
Cards of one row are as tall as the tallest.

### D-3 What an update changes: added, widened, removed, narrowed
`diffFlatpakPermissions(installed read narrowest, newer read widest)`, as pessimistic as flatpak's own
`flatpak_context_adds_permissions`: a grant the other side covers is no change. Covers means holds at its level or above:
the same place or name; host (`/`) holds the home folder, the user folders and the paths it mounts, never `/run` nor the
system's own folders; `*` and host-root hold everything; a folder holds nothing inside it (`~` does not hold `~/foo` nor
`xdg-download`: a new path may be a link out of it, which flatpak's own check treats as new too); `org.example.*` holds
`org.example.A` and `org.example.A.*`, never `org.exampleevil`; the whole bus every name; all devices input, raw USB, KVM
and the portal's USB devices; raw USB the portal's devices; the portal's `all` any of its queries; `x11` its fallback
(flatpak: "if we used to allow X11, also allow new fallback X11"). Otherwise **widened** when the other side had the same
grant at a lower level (read only < read and write < create; talk < own) or a related grant one holds of the other
(`x11Fallback` to `x11`, a portal device to raw USB or to `all`, input to all devices, a name to its wildcard), **added**
when nothing related, and the same the other way: **narrowed**, **removed**. A USB query no longer hidden is widened (as
flatpak's `adds_usb_device`), one newly hidden narrowed. A cut list (`more`) is always added. `asksForMore` = any added
or widened grant. The document portal (the files picked in an Open or Save dialog) is never a grant, so it never asks
(Luma's one exception, here by construction).

### D-4 Updates that ask for more are held from Update All
- After each Flatpak check the Store reviews every listed app (Flathub's commit, both metadata; on the updates pool, now 3
  threads) and the Updates list says under the app "Asks for more: Your home folder, Network" (« Demande davantage : … »),
  or "What this update can reach couldn't be checked." when unread; the group says "Apps that ask for more update only
  when you update them one by one."
- **Update All** plans as before, but leaves out every app that asks for more or could not be read (`held`); the others
  and the runtimes update at once with no sheet. Everything held: the sheet says so ("Each of these apps asks for more
  than before. Update them one by one to see what they ask for.").
- **Update** of one app: the sheet shows that app's changes, grouped: what it can newly reach (added, widened, with the
  mode it had) and what it can no longer reach (removed, narrowed); Update / Cancel. An update that only narrows or removes
  starts at once, as before.
- Narrowing and removal apply normally. No other path applies Flatpak updates (Context); nothing else to hold.

## Data
`StoreBackend::plan(id, "update")` answers `{refusal, detail ("held" when Update All has nothing it may do alone), refs,
asks (the sheet must ask), changed [{name, asks, changes}], unknown [names], held [names]}`; `updates().flatpak.apps[]`
gain `asksForMore`, `permissionsUnknown`, `permissionChanges` once reviewed; `flatpakInfo` and the install plan gain
`permissions` (`view::permissions`); a change is `{change, key, name, level, detail, previous}` (`view::permissionChanges`,
64 at most then a count). No file, no setting, no new process, no root path (Flatpaks are `--user`).

## Failure modes
Metadata unread or of another app (the parse checks the id against the ref): the app is held from Update All and its own
Update says what could not be read (SD33, now also for Update All). A review not finished: the list shows no line; Update
All's own plan re-reads every app before it runs, so a widening app is never taken unchecked. A newer commit between the
review and the plan: the plan's reading wins (S32). Offline: the review reads nothing new (no commit), the app shows
"couldn't be checked", Update All is blocked offline anyway.

## Tests
`tests/unit/store/tst_flatpakpermissions.cpp` (fixtures `tests/fixtures/store/flatpak/{browser,conditional}-metadata.txt`,
`update-{before,after}.txt`): the browser's grants and flat list; places and modes; bus names; conditional grants;
malformed input (no app, bad escapes, binary, broken headers, over 1 MiB, UTF-8); long lists (8001 grants cut at 200, flat
list at 30, diff and view bounded); every change kind both ways; QML maps. `tst_flatpak` UpdatePermissionChanges (the
commands, unread sides, another app's metadata, a cut list); `tst_storebackend` Updates (the list's "asks for more", Update
All holding Notes and taking the runtime, the single app's sheet); `tst_storetext.qml` (groups, words, notes, change lines);
`tst_storemain.qml` (the sheets).

## NOT VERIFIED (here: no flatpak, no Flathub, no display)
Real Flathub metadata (the fixtures are modelled, not copied), a real update that widens, the review's time on a real
connection with many apps, the cards' look (visual NOT verified: no nested session), French line lengths in the cards.
Owner L2: open a Flathub app's page (Permissions cards), install one (the sheet's groups), and with an app whose next
version asks for more, check Update All leaves it and its own Update asks.

## Limits
`flatpak override` changes are not shown; Flathub's runtime extensions' own permissions are not shown (they have none of
their own in the metadata); the review re-reads each app on every check (three `flatpak` calls per app, one online).

## Review history
- Independent review of the first PR (2026-11-05): **FAIL**. MAJOR: widenings classed as no change, so Update All applied
  them silently: fallback-x11 to x11 (and `wayland;x11;fallback-x11` to `wayland;x11`); raw USB, the USB portal's queries
  and its hidden devices folded into one `usb`; `shared=ipc` and `devices=shm` folded into one class. MINOR: the installed
  side read generously (`!x`, a key written twice, unknown conditions); `create` read as read and write; `~` taken to cover
  a new `~/foo`. NIT: no test killed the mutants "wildcard without its dot" and "host covering /run". Fixed in D-1 and D-3
  (separate grants, the two readings, create as level 3, folders never holding their inside). Each case is a test in
  `tst_flatpakpermissions` UpdateChanges, and the parser at 8a5c014 gave `asks=0` for every MAJOR and MINOR case of the
  review (a probe linked against that commit's `flatpakpermissions.cpp`), `asks=1` after the fix.
- Counter-review (2026-11-05): **PASS**, with two MINOR follow-ups, fixed: in the narrowest reading `!host-reset` also
  takes host away (`flatpak_context_take_filesystem`); `hidden-devices` keeps only its last line in both readings (GLib's
  rule, and for a restriction the widest reading is the fewest hidden). Both are tests in UpdateChanges (6 assertions
  failing before). Left as is (NIT): `flatpakAccess`'s flat list still says x11 for fallback-x11 without a Wayland socket
  (SD25's list, no longer shown; the grants say `x11Fallback`).
