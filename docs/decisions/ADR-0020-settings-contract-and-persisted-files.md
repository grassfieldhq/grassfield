# ADR-0020: Settings contract and persisted files (schema as the single source; config vs state; one writer)
Status: Proposed (integrator, under owner delegation D-5); accepted when its first slice merges (C1) · Date: 2026-10-24 ·
Decider: integrator

## Context
Plan: docs/audits/final-1.0/refactor-plan.md §4 (GF-084), §5 (GF-092). Lines re-checked on main 370a45f.
The contract exists in 7 copies:
1. `config/schema/grassfield.schema.json` (540 lines, one `default` keyword);
2. `config/defaults/grassfield.json`;
3. `shell/store/SettingsStore.qml` (adapter defaults :123-243, :541-558; views :35-87; `resetMissingPointerKeys`
   :479-520; `version` declared at :543 and never checked);
4. `apps/settings/qml/Store.js` (`DEFAULTS` :13-67, `RULES` :72-133, `validate` :136-178, version refusal :234-237, :262-265);
5. `Tokens.dockSizeMin/Max` (`ui/Grassfield/Ui/Tokens.qml:246,248`, used at `SettingsStore.qml:92`);
6. Files (`apps/files/src/filesapp.cpp:168-208`);
7. Preview (`apps/preview/src/previewapp.cpp:150-170`). Files and Preview re-type enums and patterns and ignore `version`.

Divergences found: an out-of-range number is clamped by the shell (`SettingsStore.qml:37`) but replaced by the default by
Settings (`Store.js:212-219`), so `material.transparency: 9` shows 1.0 in the shell and 0.25 in Settings; a missing
`version` is accepted by the shell and refused by Settings (`apps/settings/qml/ConfigStore.qml:36`).

Two unlocked writers: the shell (merge-write after an async `sh -c cat` re-read, `SettingsStore.qml:385-431`, `:561-567`)
and Settings (synchronous read-modify-write, `ConfigStore.qml:44-84`).

Persisted files today (GF-092). Several state-like files live in `~/.config` and have no `version`:

| File | Directory now | Writer / reader | `version` | Target |
|---|---|---|---|---|
| `grassfield.json` | config | shell and Settings, Grassfield Store for its `store` keys (ADR-0037 SD20) / all | 1 | stays (GF-084) |
| `folder-styles.json` | config | Files / Files, shell | 1 | stays (user data) |
| `mouse-trackpad.lua` | config | Settings (`MousePage.qml:16`) / Hyprland | n/a (Lua) | stays |
| Files QSettings | config | Files / Files, Preview | n/a | stays |
| `software-update.json` (ADR-0033) | state | shell / Settings | 1 | none (versioned from the start) |
| `checkup-db/`, `health-db/`, `checkup.lock` (ADR-0033) | cache (`$XDG_CACHE_HOME/grassfield`) | the update checker (`checkupdates`, the `[grassfield]`-only sync, its lock) / the checker | n/a (pacman databases, a lock file) | none (regenerable; the `[grassfield]` files are deleted when the channel's Server changes, a stale `db.lck` under the checker's lock) |
| `software-update-run.json`, `software-update-run.log` (ADR-0033 "Step 3") | runtime (`$XDG_RUNTIME_DIR/grassfield`, tmpfs; 0700, files 0600) | `grassfield-update-run` / Settings | 1 (the JSON; the log is plain text) | none (versioned from the start; the last Update Now run, its state by rename; gone at log out) |
| `pre-refresh-pacman.d/50-grassfield` (ADR-0033) | Omarchy's user hooks (`~/.config/omarchy/hooks/`) | `grassfield-channel-set` / Omarchy's `omarchy-hook` | n/a (a symbolic link to a packaged file) | stays (removed by `grassfield-channel-set off`) |
| `wallpaper-state.json` | config (`WallpaperState.qml:43`, `backend.cpp:105`) | shell / Settings | none | state, v1 |
| `pointer-theme.json` | config (`shell.qml:151`) | shell (`PointerTheme.qml:254`) / Settings (`PointerThemeStatus.qml:16`) | none | state, v1 |
| `notification-apps.json` | config (`Notifications.qml:94`) | shell / Settings (`NotificationsPage.qml:16`) | none | state, v1 |
| `wallpaper-recent.json` | config (`backend.cpp:110`) | Settings (top-level array) | none | state, `{version, recents}` |
| `recent-items.json` | state | shell | none | add v1 |
| `wallpaper-online.json` | state | shell | none | add v1 |
| `wallpaper.json` (carousel; `shown` since ADR-0040 step 3) | state | shell | none | add v1 (`shown`: per output, the last wallpaper shown, `{kind: picture, file, video, strip, image, mean}` or `{kind: art}` or `{kind: color, color}`, each with `artwork` and `variant`: the desktop's first frame at the next start and the lock's backdrop; additive, ignored by an older shell; a file that is not a plain cache name of the helper is not read; at most 16 outputs) |
| `airplane.json` | state (`Airplane.js:82`) | shell | none | add v1 |
| `show-desktop.json` | state (shell UX branch) | shell | check after the merge | add v1 |
| `notifications.json`, `widgets.json`, `desktop-icons.json`, `search-usage.json` | state | shell | yes | none |
| `files-views.json` (2026-10-26, Files PR 1) | state | Files / Files | 1 | none (versioned from the start) |
| `grassfield-mimeapps.list` (2026-11-07, Files decision F-19) | config (`$XDG_CONFIG_HOME`: the XDG MIME applications specification's list of the desktop named Grassfield) | Files (Get Info > Change All…, Always Open With; `grassfield-files --seed-default-apps` at session start adds Grassfield's apps' types the file has no entry for) / every toolkit in the Grassfield session (GLib, KService, xdg-mime and xdg-open), never the Omarchy session | n/a (XDG key file) | stays: the user's entries are never replaced, other groups and lines are kept, a link is written through to its file |
| `grassfield/saved-searches/<name>.json` (ADR-0027, Files search) | data (`$XDG_DATA_HOME`; folder 0700, files 0600) | Files / Files | 1 | none (versioned from the start): one saved search per file (`SearchLogic::toJson`: name, scope, text, criteria, sidebar), written atomically; at most 200 read, each at most 64 KiB; a file that is not version 1 JSON is left as it is and not listed |
| `portal-filechooser.json` (ADR-0035 D-4, step 4b) | state | `grassfield-portal` / the portal only | 1 | none (versioned from the start): per application id, the Open and Save panels' last folder (a local folder URL), view and whether the Save panel was expanded; at most 64 applications, the least recently used dropped; a file that is unreadable, malformed or larger than 256 KiB is an empty memory, and the next write replaces it whole |
| `activity.json` (ADR-0038 j, step 2a) | state (0600) | Activity Monitor / Activity Monitor | 1 | none (versioned from the start): the window's size, the tab, the view, the update frequency, and per tab the columns shown in order, their widths and the sort; what the Disk and Network graphs show (`diskGraph`, `networkGraph`; step 2b); a file that is not version 1 JSON is renamed `.bad` and the defaults are used; the later keys (Dock icon, "Don't ask again", App History's period) come with their steps |
| `clipboard/pinned/` (`index.json` + one `<id>.item` per item; ADR-0034, written when an item is pinned) | state (0700, files 0600) | `grassfield-clipboard-helper` / the helper only | 1 (`index.json`) | none (versioned from the start; at most 50 items and 32 MiB, never expired; emptied by unpin, Delete Item or Settings' "Also delete pinned items") |
| `clipboard/history/` (same layout; ADR-0034, only when `search.clipboard.keepOnDisk` is on) | state (0700, files 0600) | `grassfield-clipboard-helper` / the helper only | 1 (`index.json`) | none (versioned from the start; at most 100 items and 64 MiB, expired at the chosen retention, deleted when the switch or the history is turned off and by Clear History) |
| `clipboard/` thumbnails and previews (ADR-0034) | runtime (`$XDG_RUNTIME_DIR/grassfield`, tmpfs; 0700, files 0600) | the clipboard helper / the shell | n/a (PNG) | none (never on disk; removed with their item and when the helper starts or exits) |
| `store.json` (ADR-0037 c) | state | Grassfield Store / the Store | 1 | none (versioned from the start): the accepted catalog serial and fetch time per channel; from step 3, `operation`: the one in flight (id, kind, path, app, name, packages, plan, a setup's recipe and its arguments, the web app's name and URL, start time), written before it starts and removed once its outcome is read (ADR-0037 f); other keys kept on rewrite (one writer at a time, `apps/store/src/statefile.cpp`) |
| `store/` (ADR-0037 c) | cache (`$XDG_CACHE_HOME/grassfield/store`) | Grassfield Store / the Store | n/a | none (regenerable): `<channel>/grassfield-catalog.v1.json`, its `.sig` and `etag`, checked again at each use; `icons/<sha256>.png` (32 MiB, checked against the signed hash); `appstream/<version>/` and `appstream/current` (the fetched AppStream, one version); `aur/` (step 3b2: the AUR's answers, `info/<name>.json`, `search/<key>`, `pkgbuild/<package base>`, fresh for an hour, 4 MiB in all, the oldest dropped first) |

Every existing reader of files versioned in place ignores unknown top-level keys (`RecentItemsLogic.normalize`,
`Airplane.parse`, `WallpaperConfig.onlineStateOf`, `WallpaperState`'s `.displays`, the Settings status readers), so
adding `version` is safe for a downgrade.

## Decision
1. **Schema as the single source.** Every leaf gets a `default`; rules the schema cannot express are `x-grassfield`
   annotations (`tint`, `folderColor`, `pointerColor`, `wallpaperPath`, `wallpaperOutputs`, `notificationApps`, `notificationStyles`, `pathList`,
   `settable: false`, `qmlType`). `scripts/dev/gen-settings.py` (stdlib only, the `ui/tools/gen-tokens.py` pattern)
   writes `config/defaults/grassfield.json`, `ui/Grassfield/Ui/SettingsContract.js` (`VERSION`, `DEFAULTS`, `RULES`,
   `validate`, `normalize`, `versionStatus`, `ALL_DEFAULTS`) and `apps/settingscontract.h`. (No generated JsonAdapter
   exists: Quickshell's adapter reads a file without a bound and keeps old values, so the shell's store parses the file
   itself, see 2.) `just check-schema` runs `--check` and `--selftest`, so stale output fails `check-quick`.
2. **Normalisation, identical everywhere.** Numbers are clamped; integers are rounded then clamped; any other invalid
   value takes its default. A key where 0 switches a protection off (`lock.idleMinutes`, 0 = never lock) fails closed
   (`x-grassfield.zeroIsExact` in the schema): only an exact 0 reads 0; a value below 0, or a fraction that would round to
   0, is invalid and reads the default. A value above the maximum is still clamped (240 minutes: a bounded choice, and the
   lock still fires). The shell reads the last parse of the file text for every key, not the JSON adapter's properties
   (the adapter keeps an old value that loosely equals the new one), so a running shell and a fresh start agree: a deleted
   file is a fresh start without a file, and a write is built from the file on disk or the schema defaults, never from the
   adapter. The one exception is a malformed file: the cosmetic keys keep their last good values (a restart shows the
   defaults), the idle lock fails closed (`lock.*` reads the default at once, as a restart does) and nothing is written.
   Known limit: no lock between the fresh read and the atomic replace, so a concurrent external edit can be lost.
   **The file is never read without a bound.** Both reads of the shell (the load, and the fresh read before a write) are one
   shell script: a file that is not a regular file (a FIFO, a device such as /dev/zero through a symlink, a directory) is
   not opened, a file over 1 MiB (a real one is a few KiB) is not read, a read that hangs is cut after 5 s, and a read counts
   only when it ended without error with exactly the file's size (otherwise it is "incomplete", never an empty file). Such a file, and
   one that is not readable (chmod 000), is read as malformed: the cosmetic keys keep their last good values, `lock.*`
   reads the default 5 (what a restart reads), nothing is written, the file is left as it is. A symlinked
   `grassfield.json` is followed for reading and for writing (the target is replaced, the link stays); the path is looked at
   again every 10 s and after each read, so replacing the link with a regular file is noticed. A write that fails (a
   read-only directory, a full disk) keeps its change pending and is retried (2 s, 4 s, ... 60 s) instead of being lost.
   The write keeps the replaced file's mode, syncs before the rename and refuses a directory in the way; a file that could
   not be used is read again at every poll.
3. **Version policy.** Missing `version` is read as 1 and written on the next write. `1` reads normally. An integer above
   1 makes the file read-only: valid keys apply best-effort, nothing is written, in-memory changes last for the session;
   Settings shows one banner and disables its controls. A non-integer is malformed and refused, as today.
4. **The shell is the single writer** of `grassfield.json` (`settings apply(entries)` IPC: validate with the generated
   rules, merge, write atomically; hand edits are merged before each write). The Settings app goes through it and writes
   directly, with the same rules, only when no shell instance answers (2 s timeout).
5. **Two classes.** config (`~/.config/grassfield`): preferences and user-authored data. state
   (`$XDG_STATE_HOME/grassfield`): status, recents, history. Every JSON file has a top-level integer `version`
   (`Persisted.js`: `versionOf()` returns legacy | current | newer | invalid). Newer-version policy: config and
   user-visible state are read-only; regenerable status files may be overwritten. The inventory is
   `docs/specs/persisted-files.md`, checked against the code by `tests/ci/persisted_formats.py` (every persisted file name
   is in the table; no state-class name is joined to a config directory). It covers every file in the table above,
   including `show-desktop.json` and `airplane.json`.
6. **Migration.** Read the legacy location only when the new file does not exist; write the new file atomically (0600 in
   a 0700 directory, `services/write-private.sh` or QSaveFile); read it back to verify; never delete a legacy file during
   1.0.x (deletion later, and only when the new file exists). Status files carry no migration (the shell regenerates them);
   `notification-apps.json` is written once after the history loads; `wallpaper-recent.json` is copied forward once from
   the legacy array. Downgrade: older builds keep using the legacy paths, which are stale but intact; `grassfield.json`
   stays at v1 in place.

## macOS reference
cfprefsd owns preference writes; apps never write the plist themselves and fall back only when it is absent. The Dock
clamps an out-of-range `defaults write com.apple.dock tilesize`. System Settings shows "Some settings are managed" for
managed preferences. Preferences live in `~/Library/Preferences`, status and caches elsewhere.

## Alternatives rejected
- Keep hand-synchronised copies with a parity test: seven copies already diverge.
- Replace out-of-range values by defaults (the Settings app's behaviour): loses user intent; the macOS model clamps.
- A resident settings daemon: a new service for one file (the project's working rules: no new service without need).
- Delete legacy files at migration: breaks downgrade.
- Refuse a newer file entirely: the user loses all valid keys for no reason.

## Consequences
- Tests: generator `--selftest` (leaf without default, stale output); `tst_settingscontract.qml` with
  `tests/fixtures/settings-vectors.json`; `tst_appearancesettings.cpp` with the same vectors;
  `tests/shell/settings_version/` (v2 never written, valid keys apply; missing version accepted and written as 1);
  `tests/shell/settings_ipc/` (apply valid, invalid, blocked; concurrent hand edit kept);
  `tests/shell/settings_one_writer.sh`; `tst_persisted.qml`; `tests/shell/state_migration.sh` (fake HOME; 0600/0700;
  legacy byte-identical; second run does not re-read legacy); downgrade cases for P6a/P6b/P6c; existing
  `tst_settingsstore`, `settings_roundtrip`, `settings_external_write`, `check-schema`.
- The only on-disk change to `grassfield.json` is `"version": 1` appearing on the next write of a hand-written file.
- New IPC surface (C6) needs a security review and a new `app` class in `ipc_inventory`; no new privilege (any user process
  can already write the file, and the rules are stricter).
- Slices (plan §4, §5): C1 to C7 (GF-084); P1 to P7 (GF-092). Dependencies: C5 and C7 need M6 (ADR-0019); C3 needs the
  Stages merge; P2 to P4 need `Mode.stateDir` (M3, M4, M5*).

## Amendment (ADR-0033, Software Update, 2026-10-27, Proposed)
Three rows were added to the table:
- `software-update.json` (state; the shell writes it, Settings reads it; `version` 1 from the start; the last checker answer
  and the versions already announced);
- the checker's caches (`checkup-db/`, `health-db/`, `checkup.lock`);
- the link in Omarchy's user hook folder (`grassfield-channel-set` writes it as the user).
`grassfield.json` gains one key, `updates.automaticCheck` (boolean, default true), generated from the schema like every other
key (decision 1).
System files outside the user's home are not user files and are not in the table: `/etc/pacman.d/grassfield.conf` and the
two `[grassfield]` lines at the end of `/etc/pacman.conf`. Only `grassfield-channel-helper` (through pkexec) and
`grassfield-channel-scriptlet` (from pacman's scriptlets) write them, and no package owns them (ADR-0033 a, c). The keyring's
files in `/usr/share/grassfield/pacman-keyring/` belong to the `grassfield-keyring` package. Step 3 (owner decision SU-M1)
adds the runner's runtime row above; the root helper's status files in `/run/grassfield-update/` (root, 0755) are system
files, as the Store's `/run/grassfield-store/` are, and `/usr/share/grassfield/BUILD-DEPS` belongs to grassfield-desktop.

## Amendment (ADR-0047, audio routing and sound effects, 2026-11-05, Proposed)
One state file: `audio-routing.json` (state, 0600 in the 0700 folder, written by `services/write-private.sh`; the shell writes
and reads it; `version` 1 from the start): the output devices that stopped taking the sound by themselves (ADR-0047 A-6).
`grassfield.json` gains `sound.alert`, `sound.alertVolume`, `sound.effectsOutput` (a new pattern rule, `nodeName`),
`sound.uiEffects` and `sound.volumeFeedback`, generated from the schema like every other key (decision 1).
