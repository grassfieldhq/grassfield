# ADR-0053: A diagnostic report for beta testers
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (2026-11-05), applied provisionally (owner rule of 2026-10-28: decide alone, the recommended option, the
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
   files have `key = value` / `key: value` lines with such a key redacted, and every `desc:` display description
   (`displays.conf`, ADR-0031: Hyprland's "<make> <model> <serial>") loses its serial: a connected display's is cut from
   its end, a display not connected now loses the last word, where Hyprland puts the serial, and every word that could be a
   serial (6 characters or more with a digit: a serial with a space in it; a model name with digits goes too) (rc7 audit
   R7-SEC-04 and its security review). Across the whole report (the journal too) every `desc:` description gets the same
   treatment, the connected displays' serials (4 characters or more) become `[serial]`, and so do a USB device's serial in
   the shell's audio routing key (`usb:<vendor>:<product>:[serial]`; the shell's log line no longer carries it,
   `AudioRoutingLogic.logKey`) and the udev `ID_SERIAL` of a USB device in ALSA and PipeWire names
   (`alsa_output.usb-[usb device]-00.analog-stereo`: the serial cannot be told from the model there; the device's
   description stays in the audio devices list); an answer of
   `hyprctl -j monitors` that is not JSON is shown only when it does not look like JSON. Paths of the user's own folders stay out
   (security review of the Luma pull request, finding 2): `folder-styles.json` (up to 20,000 folder paths) is replaced by
   the count of its entries, and a wallpaper path (any value under a `wallpaper*` key or in a `wallpaper*` file) keeps only
   its file name. The rule is generic (second review fix, 2026-11-06): every setting whose schema type is a path
   (`x-grassfield.rule` `pathList` or `wallpaperPath`, read from the installed `grassfield.schema.json`: `dock.folders`,
   `screensaver.folder`, `wallpaper.path`) becomes a count or, for a picture, its file name (a folder: left out); so does any
   other value that is an absolute path, a `~/` or `$HOME/` path or a `file://` URL (percent-decoded to its file name); a
   key that is itself a path (`dock.stackOptions`) becomes a numbered label; in a file that is not JSON, everything from the
   first path of a line on is the path (a folder name may hold spaces). Without the schema the shape of the values still applies.

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

## Amendment to ADR-0053 (the diagnostic report), report audit round 2 · 2026-11-21 · Proposed

Context: the owner ran `grassfield-report` on their machine. The shell had been SIGKILLed twice and nothing in the report
said who sent the signal. Its memory peak was 1.3 GB (only in a "Consumed" line) and the report had no memory figures.
2,496 of the journal's 3,000 lines were the liveness probe's "Starting/Finished" pairs, so the journal covered only about
10 hours. Amended D-2 (what the report holds). The rules of D-1 (read-only, local, never root, no sudo, no network) and
the redaction of D-3 still apply to every new section.

D-2 is amended as follows (the section titles are given in quotes):

8. Journal ("Journal of the Grassfield units (this boot)"): `journalctl --user -b 0 -u grassfield-* -q -o short-iso -n 100000`.
   The glob covers every Grassfield user unit: the shell, the security process, the menu bridge, the prompter, the portals,
   the liveness probe and the rest. The `-n` is a memory bound, not the window. The report then:
   - leaves out the liveness probe's routine lines: the user manager's "Starting/Started/Finished Grassfield shell liveness
     probe" lines, and its "Deactivated successfully" and "Consumed" lines. The probe's own lines (a miss, a kill) and any
     failure of its unit stay;
   - folds each run of identical consecutive lines (the same text after the time) into its first line, marked
     "(×N, last <time>)";
   - keeps the last 512 KiB.
   A heading line gives the window covered (first and last time), whether older lines were left out, how many routine probe
   runs were left out and how many lines were folded.
10. "Processes and units":
   - `systemctl --user show --property=Id,ActiveState,SubState,Result,MainPID,ExecMainCode,ExecMainStatus,NRestarts,
     MemoryCurrent,MemoryPeak,MemorySwapPeak,MemoryMax,CPUUsageNSec,ActiveEnterTimestamp grassfield-*` (the loaded units),
     three lines per unit, sizes in KiB/MiB/GiB;
   - each Quickshell process of the user (comm `qs`/`quickshell`, the user's uid), labelled by its unit (the UI, the security
     process, other): RSS, PSS (anonymous, file, shared memory) and swap from `/proc/<pid>/smaps_rollup`, the peak RSS
     (VmHWM) and the thread count from `/proc/<pid>/status`. The command line is not shown;
   - `free -m` and `/proc/pressure/memory`.
11. "Units stopped by a signal (this boot)": for each of the last 5 "Main process exited, code=killed|dumped" lines of a
   Grassfield unit in this boot's journal, the user journal and the system journal from 5 s before to 5 s after it
   (`journalctl [--user] -b 0 --since @<t-5> --until @<t+6> -n 150`, every unit, folded as in 8). Neither Linux nor systemd
   records which process sent a signal, and the processes that could have sent it cannot be listed after the fact. So the
   section names the known killers whose trace is in those lines or in the kernel's lines of the same 5 s:
   - the liveness probe (its "SIGKILL" line);
   - the unit's memory limit ("killed by the OOM killer", result 'oom-kill');
   - the kernel's OOM killer;
   - systemd-oomd;
   - earlyoom;
   - systemd's watchdog;
   - a stop timeout;
   - a crash of the process itself (a dump, or SEGV, ABRT, BUS, ILL, FPE, TRAP or SYS).
   When none of these left a trace, the section says that the signal came from a process that writes no journal line (kill,
   pkill or killall by hand, from a script or from a shortcut). Shell history is never read.
12. "Crash details of Quickshell, Hyprland and Grassfield programs (last 7 days)": for the 5 most recent rows of item 7 whose
   executable is `qs`, `quickshell`, `Hyprland` or `grassfield-*`, `coredumpctl --no-pager --since=-7d -1 info <pid>`,
   reduced to PID, Signal, Timestamp, Executable, Unit, User Unit, Package, the message's first line and the first 8 frames
   of the first stack (the crashing thread). The command line, the boot, machine and host IDs and the core file's path are
   never copied. The UI and the security process keep no core file (ADR-0041, `LimitCORE=0`), so their entries say "no
   stack". Nothing reads a core file: ADR-0041's statement stays true.
13. "Kernel: out of memory and crashes (this boot)": `journalctl -k -b 0 -n 50000`, filtered to the lines about memory
   exhaustion or a crash (out of memory, oom-kill, memory cgroup, segfault, general protection, traps, killed process, page
   allocation failure), folded, the last 200 lines and 32 KiB at most. A user outside the wheel, adm and systemd-journal
   groups cannot read the kernel's lines, and the section says so.
14. "Memory killers: systemd-oomd and earlyoom (this boot)": `journalctl -b 0 -u systemd-oomd.service -u earlyoom.service -n 200`.
15. "Quickshell's own logs": for the UI and the security process (their units' MainPID), the running instance's log and the
   log of the instance of the same shell before it (the one that ended), found under `$XDG_RUNTIME_DIR/quickshell`
   (`by-pid/<pid>` and `by-shell/<shell>/<instance>`). The binary `log.qslog` is decoded by
   `qs log --no-color --log-times --tail 150 <file>` (Quickshell 0.3: `qs log [file]`). The plain `log.log` is the fallback
   when qs cannot decode it. Each log is 24 KiB at most.

Free text (D-3, SU-15) is now replaced in every log section (11 to 15), not only the journal: window titles, network names,
notification text. Device names after a person are replaced in the lines about audio or Bluetooth. The home, user,
real-name, host, secret and serial redaction covers the whole file as before. The header says "in the logs" instead of
"in the journal".

One time budget: every command runs within 75 s in total (Settings' button waits 90 s, `Backend.act`). A command that would
start after the budget is spent becomes one line, "(left out: the report's time budget of 75 s is spent)", and a running
command is cut at the budget. Dev hook `GRASSFIELD_REPORT_BUDGET` (dev sessions only, ADR-0019); `GRASSFIELD_REPORT_ROOT`
now also prefixes `/proc`.

The syntax-tree check of the read-only rule (Consequences) gains guarded tools, with negative controls:
- `systemctl` only with `show` and no writing verb;
- `qs`/`quickshell` only with `log` and no `ipc`, `kill`, `msg` or `--follow`;
- `journalctl` without `--vacuum-*`, `--rotate`, `--flush`, `--sync`, `--setup-keys` or `--follow`;
- `coredumpctl` only with `list` or `info` and no `debug`, `dump` or `--output`.
`kill`, `pkill`, `killall` and `loginctl` are banned outright.

## Related: ADR-0041 step 6a, the liveness probe is quiet in the journal

`grassfield-shell-watchdog.service` gains `LogLevelMax=notice` and `SyslogLevel=notice`. systemd.exec(5) (systemd 262,
checked in the chroot): LogLevelMax= "is applied to any log messages written by any of the processes belonging to this unit,
as well as any log messages written by the system or user manager processes in reference to this unit". The manager's
routine job lines ("Starting…", "Finished…", "Deactivated successfully") are info and are dropped. A failure stays:
"Main process exited" with a failure is notice, "Failed with result" is warning, "Failed to start" is err. The probe's own
`say` lines go to stderr with no level prefix (SyslogLevelPrefix= is on by default), so they would take the default info and
be dropped too. SyslogLevel=notice gives them notice, so a miss and a kill are still logged. The report's filter (item 8)
still drops the routine lines of journals written before this change, and of any system where the setting is not applied.

Owner check (L2): after an update, `journalctl --user -b -u grassfield-shell-watchdog` shows no new Starting/Finished pair
every 30 s. A `grassfield-report` names the window covered and the killers, and has the new sections.
