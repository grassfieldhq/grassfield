# ADR-0053: A diagnostic report for beta testers
Status: Proposed (2026-11-05), applied provisionally (owner rule of 2026-10-28: decide alone, the recommended option, the
macOS model first) · Date: 2026-11-05 · Decider: owner (revisit), integrator (merge) · Number: 0053

Inspired by Project Luma's support report (`scripts/support/audio-report.py`, MPL-2.0: local evidence, no sudo, no network,
no recording or playback, no configuration change, a private file the person decides to share); no code copied.

## Context

Beta testers report failures in words ("the Dock vanished after I plugged the screen in"). The integrator then asks for the
version, the packages, the journal, the displays, one command at a time, and some answers never come. macOS gives the user
one file to attach (System Information > File > Save, Feedback Assistant's sysdiagnose): the person sees what it holds and
sends it, or not. A fix for a reported failure also needs a record that outlives the conversation: which version had it, how
to reproduce it, which version shipped the fix.

## Decision

### D-1 `grassfield-report`: one private local file
`packaging/bin/grassfield-report` (Python 3 standard library, like the other helpers), installed in `/usr/lib/grassfield/` by
the PKGBUILD's `packaging/bin` line and linked as `/usr/bin/grassfield-report` (a command a person types). It writes one file
and prints its path:
- Where: the user's Downloads folder (`XDG_DOWNLOAD_DIR` of `user-dirs.dirs`, so "Téléchargements" on a French session),
  else `~/Downloads` when it exists, else the home; `--output PATH` chooses a file or an existing folder.
- Name: `grassfield-report-<YYYYMMDD-HHMMSS>.txt`; never overwrites (`-2`, `-3`... when it exists); created with
  `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600 (whatever the umask), so a link planted at that name is not followed.
- Format: one UTF-8 text file in sections, not a `.tar.zst` and not JSON. Reason: the person decides whether to share it, so
  they must be able to read all of it first in any text editor; one plain file attaches to an issue or a mail as it is, needs
  no extraction tool and no zstd; JSON answers (the monitors) are embedded pretty-printed. Size is bounded (each section has a
  cap; the whole file stays under about 1 MiB).
- Never as root (it refuses: it would read and write root's files), never sudo, never a network tool, no recording or playback,
  no configuration change. Every command is read-only, run without a shell, with a timeout, `LC_ALL=C`; a missing tool is one
  line ("not available"), never a failure of the report.

### D-2 What it holds
1. Header: the time (UTC), Grassfield's version (`/usr/share/grassfield/VERSION`), the session (`GRASSFIELD_SESSION`,
   `XDG_CURRENT_DESKTOP`, `XDG_SESSION_TYPE`), kernel release and machine.
2. Packages: `pacman -Q` (the local database, read-only) filtered to `grassfield*`, `omarchy*`, `hyprland`, `quickshell`,
   `quickshell-git`, `qt6-base`, `qt6-declarative`, `qt6-wayland`.
3. Omarchy: `NAME`, `VERSION_ID` and `BUILD_ID` of `/etc/os-release`. Omarchy's own `omarchy-version` script is not run (a
   script nobody here has read; the os-release and the package version say the same).
4. Compositor and plugin: `hyprctl version` and `hyprctl grassfield` (the plugin's own read-only reply; "unknown request"
   means the plugin is not loaded), through the session's `hyprctl` (its `HYPRLAND_INSTANCE_SIGNATURE`).
5. Displays: `hyprctl -j monitors`, reduced to name, make, model, mode, position, scale, transform, focus, DPMS, VRR, mirror,
   disabled; the serial is replaced by whether there is one.
6. Audio devices: `wpctl status` (at most 64 KiB).
7. Crashes: `coredumpctl --no-pager --no-legend list --since=-7d` (the user's dumps of the last 7 days, at most 100 lines;
   no dump, command line or environment is read). The summary of `scripts/dev/coredump-summary.py` stays a dev tool.
8. Journal: `journalctl --user -b 0 -u grassfield-* -o short-iso -n 3000`, its last 512 KiB at most.
9. Configuration: the regular files directly in Grassfield's config folder (`$GRASSFIELD_CONFIG_HOME`, else
   `$XDG_CONFIG_HOME/grassfield`), at most 20 files of 256 KiB each; JSON is walked and every value under a key that names a
   secret (password, passphrase, secret, token, credential, cookie, psk, auth, private, a key qualified as api, access,
   private, secret, ssh, session, client, master, shared, signing, encryption, gpg, pgp, wifi, wpa or licence: `sshKey`,
   `session_key`) is `[redacted]`; the user's free text (`lock.message`, the lock screen message) is `[redacted]`; monitor
   serials never leave (review fix 2026-11-05): a `serial` field becomes `present`, and so does the serial field of every
   display identity string (`s:<make>|<model>|<serial>` of `displays.main`'s `set` and `main`, ADR-0044 D-2;
   `s:<model>|<serial>` of the wallpaper outputs), the `m:` and `n:` keys (connector-bound) staying as they are. Other text
   files have `key = value` / `key: value` lines with such a key redacted. Paths of the user's own folders stay out
   (security review of the Luma pull request, finding 2): `folder-styles.json` (up to 20,000 folder paths) is replaced by
   the count of its entries, and a wallpaper path (any value under a `wallpaper*` key or in a `wallpaper*` file) keeps only
   its file name.

### D-3 Redaction (the whole file, last)
The home path becomes `~`. The user name, the real name and the host name become `<user>`, `<name>` and `<host>` wherever
they stand as words, case-insensitively: the real name is the first GECOS field, replaced whole and then word by word
(each word of 3 characters or more that is not generic, so "Jean’s AirPods" loses "Jean" too). A device named after a person
("Marie’s AirPods", "Paul's Headphones": a capitalised word before 's or ’s, product names excepted) becomes "<name>’s
AirPods", where device names are: the whole audio devices section, and the journal lines about audio or Bluetooth (sink,
source, output, speaker, headphones, Bluetooth, PipeWire...); other journal lines keep their possessives, which are the
interface's own words ("the Dock's tile", "Wayland's socket"). Hardware addresses (Bluetooth and network, `:`, `-` or `_`
separated, also inside PipeWire node names) become `XX:XX:XX:XX:XX:XX`. Private key blocks, `Authorization: Bearer ...`,
`password=...`-style pairs (`pass=` and `pwd=` too) and quoted values after a
secret's name (`psk 'x'`, `password "x"`) anywhere (the journal included) are `[redacted]`. What stays: package versions,
monitor makes and models, audio device kinds, Grassfield's settings. The file says at its top what was removed and that
nothing was sent.

### D-4 Settings > General > About: "Create Diagnostic Report…"
macOS keeps "System Report…" at the bottom of About. A group "Diagnostic Report" at the end of the pane: one row with a
subtitle ("Saves a report about this computer to your Downloads folder. Nothing is sent: you decide whether to share it.")
and a push button "Create Diagnostic Report…". It runs `/usr/lib/grassfield/grassfield-report` through `Backend.act` (the
installed path exactly, no argument: `systemguard.cpp` `isAllowedAction`, timeout 90 s); while it runs the button is off and
the subtitle says "Creating the report…"; when it ends the subtitle names the file (any clean absolute
`grassfield-report-*.txt` path the tool printed: `XDG_DOWNLOAD_DIR` may lie outside the home, `General.reportPath`) and, when
the file is inside the home (`General.revealable`), Files opens the folder holding it (`Backend.launch` of
`/usr/bin/grassfield-files -- <folder>`, `isRevealInFiles`: a clean absolute folder inside the home, in the session's own
language); outside the home Files is not opened. A failure says "The report could not be created." In a dev session the dev guard suppresses it
("dev: not applied"), as every action. The group is shown when the tool is installed (`Backend.reportTool`) or in a dev session.
Files has no option to select an item at start, so the folder opens with the report in it, not selected (known limit).

### D-5 The regression ledger
`docs/testing/user-reported-regressions.md`: one stable ID per reported failure (`URR-NNN`), with the report date and the
version it was seen on, the reproduction, the cause, the verification, and the first shipped version with the fix. A fix in
the sources is not a shipped fix: an entry stays open until a released version carries it. Seeded with the format only.

## Consequences
- New file in the package (`/usr/lib/grassfield/grassfield-report`, `/usr/bin/grassfield-report`); no new dependency (Python 3
  is already one of the helpers'), no service, no daemon.
- Settings' guard grows by one exact action and one launch form (`tests/unit/settings/tst_systemguard.cpp`).
- Tests: `tests/shell/diagnostic_report.sh` (logic layer: fake `pacman`, `hyprctl`, `wpctl`, `journalctl`, `coredumpctl` on
  PATH, a fake home; the sections, the 0600 mode, no overwrite, the redaction of the home, user name, host name and secrets,
  the bounded journal, missing tools, the dev-only file-root hook; run as root it checks the refusal for real and runs the
  report as nobody through `setpriv`), `tests/unit/tst_settingsgeneral.qml` (the report path parser),
  `tests/unit/tst_settingsabout.qml` (the button, the states, the reveal), `tests/unit/settings/tst_systemguard.cpp` (the
  exact action, its timeout, `isRevealInFiles`).
- Known limits: a host name, user name or real name shorter than 3 characters, or a generic one ("user", "admin"...), is not
  replaced as a word (it would mangle the report); the home path is always replaced. The word-by-word real-name
  replacement can mangle everyday words that are also first names ("Will", "Rose", "Mark": "<name> retry"); the report
  stays readable, and a name left in is worse than a word lost. A device named after a person without a possessive
  ("AirPods de Jean") keeps the name unless it is the user's own. The no-privilege/no-network rule is checked on the syntax
  tree (every spawning call, any string of its arguments), with negative controls (`tests/shell/diagnostic_report.sh`).
- NOT VERIFIED here (no session, no pacman database, no journal): the real commands' output on the owner's machine, the
  button and Files opening (visual NOT verified). Owner L2: Settings > General > About > Create Diagnostic Report…, then read
  the file in Downloads; `grassfield-report --output /tmp` from a terminal.
