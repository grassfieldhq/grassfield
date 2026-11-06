# Software Update spec · platform-engineer (client, channel), shell-engineer (pane, badge, menu, banner) · owner brief 2026-10-27
Status: step 0 (this spec and ADR-0033), revised after the first opus review (FAIL, 5 MAJOR); every owner decision of
2026-10-27 (ADR-0033 O1-O20) is included; revised again after the second review. Step 1 (built; ADR-0033 "Step 1 as
built") has the checker, the channel command and its root helper, the persistence and the container test. Step 2 (built;
ADR-0033 "Step 2 as built") has the shell service (schedule, waiter, `software-update.json`, `updates.automaticCheck`, the
shim's forward), the pane, the badges, the menu count and the notification. Measured parity and the real flows (A12) are
still open.
Decisions and evidence: `docs/decisions/ADR-0033-software-update.md` (the contract with grassfieldhq/grassfield-packages,
probes P0–P13, Q0–Q8 and R0–R5). UI names: "Software Update" (fr « Mise à jour de logiciels »), "Beta Updates" (fr « Mises à jour bêta »),
"Update Now" (fr « Mettre à jour maintenant »).

## macOS reference behavior (described in words; no Apple image committed)
- System Settings > General > Software Update. A first group has two rows, each with its value text and an info button:
  "Automatic updates" (its sheet has switches: check for updates, download, install the system, install apps, install
  security responses) and "Beta updates" (its sheet has a menu: Off, Public Beta, Developer Beta).
- Below it a status area: "Checking for updates…" with a spinner. Then either the system is up to date (the installed version
  shown) or the updates are listed: the system update with its name, a "More Info…" link to its notes, and "Update Now".
  After an update that needs it: "Restart to finish installing" with "Restart Now".
- Pending updates show a red badge on System Settings in the Dock, on the General row and the Software Update row inside
  System Settings, and a count after "System Settings…" in the Apple menu ("1 update"). A notification announces an update
  found in the background.
- With automatic checks off, opening the pane still checks.
- Measures and parity are taken in step 2 on the reference capture `General-Software-Update.png` (macOS 15; no macOS 26 or
  27 capture exists, `docs/audits/settings-parity-2026-10-26.md`), with that audit's method and the macOS 27 panes' rows,
  groups and type. Visual NOT verified until then.

## Purpose and non-goals
Purpose: show the user, in Grassfield, that a Grassfield release (and Omarchy's) is available, with its notes; let them
start Omarchy's own update; let them choose the stable or beta channel; keep the `[grassfield]` repository working across
Omarchy's own changes.

Non-goals:
- no installation code (the install is `omarchy update`). The only Grassfield code of Software Update that runs as root
  writes pacman's configuration for `[grassfield]` and its trust: `grassfield-channel-helper` (pkexec, owner decision O1)
  and `grassfield-channel-scriptlet` (pacman's scriptlets), ADR-0033 c. (Grassfield Store's own root helper installs apps
  the user picks there: ADR-0037 b.1, which amends ADR-0033);
- no automatic download or install;
- no per-package choice, no rollback button (Omarchy's snapshots are the rollback);
- no App Center (master-prompt §4);
- no publication of anything before the owner's decision (ADR-0033 h).

## Functional requirements
Checker (`grassfield-update-check`, a one-shot child of the shell, ADR-0033 d)
- U1. Runs as the user, never as root.
  - It writes only under `$XDG_CACHE_HOME/grassfield/`: `checkup-db/`, `health-db/` and `checkup.lock`.
  - It returns one JSON object on stdout (at most 256 KiB, `version: 1`). The shell writes it to
    `$XDG_STATE_HOME/grassfield/software-update.json` (0600, atomic, ADR-0020).
  - It holds `flock -n` on `checkup.lock`, and a second run answers `busy`. Under that lock, a `db.lck` left in its own
    database folders is stale and is removed first (Q8).
  - It is stopped after 180 s: SIGTERM, then SIGKILL 5 s later.
  - Every child runs with stdin from `/dev/null`.
- U2. States:
  - `not-set-up`: no `[grassfield]` and no `/etc/pacman.d/grassfield.conf` (never set up, or turned off). The system's
    updates are still checked and listed (Omarchy's release, the other updates), never a Grassfield release: macOS always
    offers its system updates (the integrator's decision of 2026-10-28, ADR-0033 "Step 2 as built");
  - `repair`: the file is there, the `[grassfield]` lines are not; or the lines are there twice, or without their file
    (every pacman command fails then);
  - `blocking`: two `[grassfield]`-only syncs in a row (15 minutes apart) failed while the network works, so every
    `omarchy update` fails (U22);
  - `up-to-date`, `available`;
  - `failed`, with `offline` or `unavailable` and the time of the last success;
  - `update-running`: Omarchy's update lock is held (U4).
  `checking` is the shell's state while the child runs. Every result carries the channel: `stable`, `beta`, or `custom` when
  the primary Server is not `<base>/<channel>/$arch` for the current base.
- U3. Before `checkupdates`, the checker syncs `[grassfield]` alone:
  - its own minimal configuration (`[options]` plus the `Include`, no `DisableSandbox`) and its own `health-db/`;
  - under `fakeroot`, with checkupdates' flag `--disable-sandbox-filesystem` (ADR-0033 a2, Q3, R5).
  A first failure with the network up schedules a second sync 15 minutes later; a second failure in a row is `blocking`. A
  success clears the count.
  `available` lists, from one `checkupdates` run:
  - the Grassfield release (`grassfield-desktop` installed → candidate, pkgver-pkgrel) with its notes;
  - Omarchy's release (`omarchy` or `omarchy-dev`) as `omarchy-update-available` reports it;
  - the number of other package updates.
  Other `grassfield-*` packages are not listed on their own.
- U4. One check at a time. A request while one runs joins it.
  - A request while `omarchy update` holds `$XDG_RUNTIME_DIR/omarchy-update.lock` (tested with `flock -n`, released at
    once) is handed to one waiter. The waiter blocks on `flock -x -w 7200` on that file, releases it at once, then checks.
  - This covers the shim's request, which comes from inside `omarchy update` (ADR-0033 d.5, Q8).
  - The state is `update-running` meanwhile.
  - A waiter whose own answer is `update-running` again (its 2-hour wait ended with the lock held) starts the next one only
    60 s later, never in a loop. A file that still says `update-running` when the shell starts (its waiter ended with the
    session: a reboot or a log out during the update, a crash) is checked at once; the pane checks it when it opens, and
    "Check Now" is never disabled by the stored state alone.
- U5. When the Server differs from the one it last synced, the checker deletes its own `[grassfield]` database files first
  (ADR-0033 c, P7).
- U6. Notes: fetched only for an available Grassfield release; https only (`file` in the container test); at most 64 KiB,
  15 s; signature checked with `gpgv` against `/usr/share/grassfield/pacman-keyring/grassfield.gpg`. The signer is VALIDSIG's argument
  10, the primary key (argument 1 is a signing subkey, Q7). It must be in `grassfield-trusted` and not in
  `grassfield-revoked`; JSON validated (`version` 1, at most 20 releases, `en` required, at most 8000 characters a
  text, UTF-8). The notes of every release newer than the installed one are shown, newest first, `fr` when the session is
  French and present, else `en`. Anything invalid: no notes, "Release notes are not available" (fr « Les notes de version ne
  sont pas disponibles »).

When it runs (shell)
- U7. `updates.automaticCheck` (bool, default true; schema-generated, ADR-0020): 10 min after the session starts, then every
  6 h, skipped while the shell's connectivity says offline or metered, or while the computer runs on its battery at 30 % or
  less (ADR-0050 6: checked again when it is plugged in; a computer with no battery, or whose power is unknown, checks).
- U8. The pane checks when it opens (unless a check finished less than 60 s ago or one is running) and on "Check Now"
  (fr « Vérifier maintenant »), whatever U7 says.
- U9. `omarchy-shell -q omarchy.system-update refresh|clear` (called by `omarchy update`, under its lock) reaches
  Grassfield's shim. The shim only sends the shell a check request, which U4 hands to the waiter. It starts no process
  itself, since a child inheriting Omarchy's lock descriptor would keep the lock. No other IPC verb of the shim is new;
  everything else keeps failing quietly.
- U10. Settings reads `software-update.json` (bounded read) and asks the shell to check over IPC. Without a shell it runs the
  checker itself and keeps the result in memory.

Actions (never in a dev session)
- U11. Without the step 3 runner (U24: a build before it, or no pkexec), "Update Now" runs exactly
  `omarchy-launch-floating-terminal-with-presentation omarchy-update`, in Omarchy's floating terminal; with it, "Update in
  Terminal…" (U28) runs the same command. Omarchy asks "Continue with update?" there; the user can cancel. While the update lock is held the button is
  disabled and the pane says the update runs in the terminal. The pane checks again when the lock is released: 5 s after the
  launch it asks for a check, which finds the lock held and waits for it (U4). While `blocking` (U22) the button is disabled
  with a sentence, since every Omarchy update fails then.
- U12. "Beta Updates" (Off / Grassfield Beta) runs `grassfield-channel-set beta` or `grassfield-channel-set stable` as a child
  process of Settings, with no terminal. The polkit dialog asks for the administrator's password; the row says "Waiting for
  permission…" meanwhile, up to 120 s. A refusal or a cancel shows one line ("Beta updates were not changed: not allowed"),
  and nothing is retried. The shown value is read from `/etc/pacman.d/grassfield.conf` (watched), never stored per user; the
  switch shows the old value until the file changes. Switching installs nothing (O2); the pane then checks.
- U13. "Set Up…" (`not-set-up`) runs `grassfield-channel-set stable`; "Repair…" (`repair`, `custom`) runs
  `grassfield-channel-set repair` (in `custom` it rewrites the file, U15); "Turn Off Grassfield Updates…" (`blocking`, and in the Beta Updates info sheet) runs
  `grassfield-channel-set off`. All work as U12 does.
- U14. After a Grassfield update in this session (GF-083's `updatePending`), the pane shows "Log out to finish updating
  Grassfield" with "Log Out…". When Omarchy's `~/.local/state/omarchy/reboot-required` exists or the running kernel's modules
  are gone, it shows "Restart to finish updating" with "Restart…" instead. Both use the existing session-end path: the pane
  asks first in a sheet, then Settings starts `grassfield-session-end logout|restart` (never in a dev session).

`grassfield-channel-set`, `grassfield-channel-helper`, `grassfield-channel-scriptlet` (ADR-0033 a–c; owner decision O1: polkit)
- U15. `grassfield-channel-set` (the user's command; it refuses to run as root):
  - with no argument it prints the channel (`stable`, `beta`, `off`, `repair`, `custom`);
  - `stable` and `beta` set up or switch: `pkexec grassfield-channel-helper set <channel>`, then the hook link;
  - `repair` runs the helper's `restore` in the `repair` state. In the `custom` state it runs `set <channel>` instead, the
    channel named by the Server's path (`/stable/$arch` or `/beta/$arch`), else `stable`. Then it makes the hook link;
  - `off` runs the helper's `off`, then removes the hook link.
  Exit 0 on success; 1 on a refusal, a cancelled or refused authentication, or a failed step (the message names it).
- U16. Two root programs over one library, `grassfield-channel.sh` (opus security review).
  - `grassfield-channel-helper`, the polkit action's program, accepts exactly `set stable`, `set beta`, `restore` and `off`.
    All are refused while pacman's `db.lck` exists.
  - `grassfield-channel-scriptlet`, run only by `grassfield-desktop`'s install script, accepts exactly `remove` (`pre_remove`)
    and `upgrade` (`post_upgrade`), and does not check `db.lck` (pacman holds it).
  - Neither reads an environment variable. Under `pkexec pacman -R`, whose scriptlets inherit `PKEXEC_UID`, the removal still
    takes the section and the keys away.
  - Layout written: two lines at the end of `pacman.conf`, `[grassfield]` and `Include = /etc/pacman.d/grassfield.conf`. The
    file holds `SigLevel = Required` and the `Server` lines, the primary then the mirrors (ADR-0033 a.1, Q4, Q5).
  - Order of `set`:
    1. validate;
    2. the trust bootstrap when the pinned key's validity in pacman's keyring is not full or ultimate (trust, not presence):
       the shipped key file is checked against the pinned fingerprint, then `pacman-key --add` and `--lsign-key`;
    3. `pacman-key --populate-from /usr/share/grassfield/pacman-keyring --populate grassfield`, so a key newer than the
       pinned one is trusted too (R3);
    4. the file from the packaged template (to `.new`, then a rename);
    5. the two lines if missing (temporary file in `/etc`, rename, mode kept);
    6. drop pacman's synced `[grassfield]` files.
  - `off` and the scriptlet's `remove`: the two lines, then the file, then the synced files, then `pacman-key --delete` of every key
    in `grassfield-trusted` and of the pinned key (ADR-0033 b.8, Q6), skipping any empty fingerprint (an empty pin in
    `repository.conf` or an empty trusted list, as with the keyless keyring of U23).
  - The scriptlet's `upgrade`: when the primary Server is `<previous base>/<channel>/$arch`, it rewrites the file for that channel
    and drops the synced files; otherwise it does nothing (ADR-0033 h.3).
  - A step that fails stops the helper and leaves `pacman.conf` valid: the `[grassfield]` lines are never present without
    their file.
  - It installs no package (`grassfield-keyring` comes as a dependency of `grassfield-desktop`), uses no network, reads no
    environment variable and writes nothing in a user's home.
- U17. The hook `pre-refresh-pacman` (linked by `grassfield-channel-set`, owner decision O4) adds the two lines with `sudo tee
  -a` (Omarchy's warm sudo cache) when the file exists and `pacman.conf` has no `[grassfield]` line; otherwise it does
  nothing. It never writes the file.
- U22. `blocking` (owner decision O18), only after two failures in a row (U3):
  - the pane says that Grassfield's repository cannot be used and that this stops every system update, and offers "Turn Off
    Grassfield Updates…" (U13);
  - one notification per episode says the same, and its action opens the pane;
  - nothing is turned off without the user;
  - after "Turn Off…", `omarchy update` works again (ADR-0033 a2, Q1).
- U23. `grassfield-keyring` (ADR-0033 b.2, b.8):
  - its files sit in `/usr/share/grassfield/pacman-keyring/`;
  - its install script populates from there only when `grassfield.gpg` is not empty and `/etc/pacman.d/grassfield.conf`
    exists;
  - its `pre_remove` deletes the keys of its trusted list from pacman's keyring.
  After "Turn Off…", a plain `pacman-key --populate` does not trust a Grassfield key again (R2). After `pacman -Rns
  grassfield-desktop grassfield-keyring …` no `[grassfield]` line and no Grassfield key remain, and pacman works (Q6).
  **Until the owner's key exists (O11, O20) it holds no key** and trusts nothing (R1). Test keys are made per run inside
  test containers, never committed or installed elsewhere.

Badge, menu, notification (step 2)
- U18. The Dock's Settings tile shows the number of available releases (0, 1 or 2: Grassfield, Omarchy), set by the shell as
  that application's own count (ADR-0018: the count of an app that sets one wins over the notification-derived one).
- U19. The Grassfield menu's "Settings…" item shows "1 update" / "2 updates" (fr « 1 mise à jour » / « 2 mises à jour »)
  after its label. In Settings, the General row in the sidebar and the Software Update row show the same badge.
- U20. One notification per newly found version (Grassfield or Omarchy), never repeated for a version already announced
  (`software-update.json` keeps the announced versions): title "Grassfield 1.0.1 is available" (fr « Grassfield 1.0.1 est
  disponible »), a click opens Settings > General > Software Update. No banner for a check the user started.

Pane (step 2)
- U21. Layout per the macOS 27 panes (tokens only, light and dark, keyboard, `qsTr` en and fr). First group:
  - "Automatic Updates": value "Check for updates" or "Off"; an info sheet with the one switch Grassfield can honour, and a
    sentence saying that downloading and installing stay manual;
  - "Beta Updates": value "Off" or "Grassfield Beta"; an info sheet with the menu and a sentence on leaving the beta
    (U12, Known limitations).
  Status area: the U2 states; "Grassfield X.Y.Z" with "More Info…" (the notes, U6), "Omarchy X.Y.Z" (the text "Omarchy's
  release notes are on its project page", no link opened by Grassfield), "N other updates", "Update Now"; the installed
  version and the time of the last check when up to date. With Grassfield updates off (`not-set-up`), Omarchy's release and
  the other updates are listed with "Update Now" under "Set Up…", and the badge counts Omarchy's release.

Update Now without a terminal (step 3, owner decision SU-M1; ADR-0033 "Step 3")
- U24. "Update Now" starts exactly `/usr/lib/grassfield/grassfield-update-run`, detached, with no argument (Settings'
  `isLaunch`; never in a dev session). It runs only when the runner, `grassfield-update-helper` and `/usr/bin/pkexec` are
  installed; otherwise U11 applies. The runner (as the user) takes Omarchy's update lock for the whole run, lists the
  migrations already pending (`omarchy-migrate --pending`) and runs `pkexec /usr/lib/grassfield/grassfield-update-helper run
  <op-id> [<migration>...]`: Grassfield's own polkit dialog (`org.grassfield.packages.update-system`, an administrator's
  password every time, never for an inactive or remote session). The helper (root) runs in a transient system service when
  systemd manages the system, so neither closing Settings nor a log out can stop pacman. Its order (ADR-0033 s3.2): the plan
  from a copy of the sync databases, the compatibility check (U27), the steps that need a person (U28), then the cache prune,
  the snapshot (every snapper configuration; none, unconfigured or failed: the update goes on, as Omarchy's does), the checked
  databases made the system's, the Arch keyring, and `pacman -Su --noconfirm --overwrite '/usr/share/omarchy/*'` with
  `OMARCHY_UPDATE_PACMAN=1` (Omarchy's guard hook). Nothing is changed before the snapshot. After the helper, the runner runs
  Omarchy's `omarchy-migrate`, `omarchy-hook post-update` and `omarchy-update-mise` as the user, without a terminal.
- U25. While it runs, the status shows the phase ("Waiting for permission…", "Preparing the update…", "Saving a snapshot of
  this computer…", "Downloading updates…", "Installing updates…", "Finishing the update…"), "12 of 132" when a count is known,
  and one bar (0-5 % preparing, 5-45 % downloading, 45-95 % installing, 95-100 % finishing; indeterminate when nothing is
  counted). No pacman output is shown. The pane reads the runner's state and the helper's progress every 500 ms while the run
  goes on, and when it opens: closing Settings stops nothing, and opening it again shows the run where it is. A runner that
  ended without its last state (a log out) shows the helper while it runs; a process id reused by another process (another
  start time) is not the run. Update Now is hidden while it runs.
- U26. Before the transaction, the helper refuses with nothing changed: less than 10 GB free on `/` ("This computer needs 10
  GB of free space to update."); on battery below 50 % with no power supply online ("Connect this computer to power to
  update."); another run, or a `db.lck` a process holds ("Another update is running."); a `db.lck` no process holds, left by
  a pacman that stopped mid-way ("An earlier update stopped before it finished.", with Update in Terminal…, where pacman
  says how to clear it); Omarchy's signing key missing (U28, after the compatibility check of U27). A dismissed dialog says
  nothing; a refused one says "Software Update was not allowed to update this computer.".
- U27. Compatibility (ADR-0033 s3.4). grassfield-desktop records the toolkit it was built with
  (`/usr/share/grassfield/BUILD-DEPS`: `qt6-base`, `quickshell`, `hyprland`, `aquamarine`, `kcoreaddons`). When the plan
  changes grassfield-desktop or one of them, every one installed after the transaction must match the record of the
  grassfield-desktop installed after it (the plan's, so a matching Grassfield build joins the same transaction): Qt, Hyprland,
  aquamarine and KF6 by major.minor, Quickshell by its whole version. A missing record fails closed. Otherwise nothing changes
  and the pane says "This update needs a newer version of Grassfield, which isn't available yet." and "Software Update checks
  again later and tells you when it's ready.", with no technical step.
- U28. What needs a person (ADR-0033 s3.6, the prompt table): a pending migration that names `pkexec`, `su`, `run0`, `doas`,
  `gum`, `/dev/tty` or a `sudo` by its path, or an Omarchy command that does; a pending migration that needs root (it names
  `sudo`, or a command that does, or Omarchy's `requires-sudo` header) when U32's conditions do not hold (the command files of `usr/bin/omarchy-*` and
  `usr/share/omarchy/bin/`, Omarchy 4.x's layout); a pending migration the scan cannot read (not a regular file, no command
  file to read, a new package with no migration, a migration or file name outside the scan's forms, more than 64 pending,
  a name the helper refuses); Omarchy's key missing; a package conflict or files no
  package owns (pacman stops before changing a package). The update stops with nothing installed and the pane says "This update asks
  questions that need Omarchy's terminal." with "Update in Terminal…" (U11's command). A migration that fails anyway leaves
  the update installed and says "Some of Omarchy's last steps need its terminal." with "Finish in Terminal…"
  (`omarchy-launch-floating-terminal-with-presentation omarchy-migrate`). When apps from the AUR are installed, the end says
  "Apps from the AUR are updated in Omarchy's terminal." with "Update in Terminal…". Orphans are kept (Omarchy's own
  non-interactive answer); firmware and Omarchy's channel are never touched.
- U29. The end (U14's rule, plus the run's own answer): a kernel update, Hyprland, a toolkit package of U27, Omarchy's
  `reboot-required` or a `restart-*-required` marker ask for a restart; grassfield-desktop alone asks for a log out. When the
  run ends while the window watches it, a sheet asks once: "Restart your computer to finish updating" with "Restart Later" and
  "Restart" (or "Log out to finish updating Grassfield" with "Log Out Later" and "Log Out"); Later keeps the pane's row.
  Nothing restarts by itself. When the update could not prepare the startup files (Omarchy's initramfs check), the pane says
  "Don't restart this computer yet" and offers no restart. While a run goes on, the pane's Restart… and Log Out… wait for
  its end (step 4).
- U31. A toolkit replaced under the running session (ADR-0041 step 2b). Every check, in every state, lists the toolkit as
  installed (`toolkit`): each package of U27's record (`qt6-base`, `quickshell`, `hyprland`, `aquamarine`, `kcoreaddons`)
  pacman names, with its version, the time pacman installed it (`/var/lib/pacman/local/<name>-<version>/desc`,
  `%INSTALLDATE%`), the version this Grassfield was built with (`/usr/share/grassfield/BUILD-DEPS`) and whether it moved
  away from that record by U27's rule (`null` without a record, `true` when the record does not name it). A package
  installed at or after the session started (Hyprland's start, read from `HYPRLAND_INSTANCE_SIGNATURE`, so the same after a
  crash and restart of the shell; a time that cannot be read counts as this session), whatever the record says, means the
  session runs on a file that was replaced under it: the shell posts "Log out to finish updating" once per session ("Some
  updates finish when you log out. Log out and back in to use them.", opening Software Update; no package name in a
  sentence, the journal names them) and writes U14's pending log out with its reason, so the pane shows "Log out to finish
  updating Grassfield" with "Log Out…" and the subtitle "Some of the update is used only after you log in again."; the
  log out stays due until the session ends, through a restart of the shell (re-read from the file). A package installed
  before the session started is what the session already runs on, and asks for nothing. Where the check comes from: the
  scheduled checks (U7), the check `omarchy update` asks for at its end (U9), Update Now's own, and `grassfield-pacman-watch`:
  a user path unit watches `/var/lib/pacman/local` (it changes at every transaction, readable by every user) and starts a
  oneshot service that waits 5 s for the transaction's burst to settle and asks the shell for a check (origin `system`,
  announced as a scheduled check is), so a `pacman -Syu` typed in a terminal is seen within seconds of its end. The shell's
  reloads of the session configuration (a display trial, the input files) wait while pacman holds its database lock
  (`/var/lib/pacman/db.lck`), at most 10 s, so a trial never reloads a half-written tree.
- U30. A failure before any change says "The update could not be installed. Nothing was changed." (offline, a mirror, a
  download, a plan pacman refuses or that cannot be read); once the checked sync databases became the system's, it says "The
  update could not be installed." and "The updates were not installed…" instead (and the terminal answer of U28 the same);
  one during the transaction "The update stopped before it finished.", and names the snapshot only when one was taken.
  Update Now stays available to try again after every outcome.
- U32. One password (owner decision SU-M2, ADR-0033 "Step 5"). When the migrations this update adds need root and nothing
  that needs a person, the update goes on. After its transaction, the helper runs those migrations (by name, the loop of
  `omarchy-migrate`) as the person, without a terminal and without a second password: each `sudo` command runs as root in its
  own transient system unit. polkit grants that only to the migrations' unit, `grassfield-update-migrate.service`, which
  runs under a group of its own (`grassfield-update`, no member) so that none of the person's other processes can reach
  into it.
  - Conditions: systemd; a person (uid 1000 or more) who is an administrator (`wheel`); no migration from before the update
    pending; the unit's group without a member or a password; Omarchy's migrations and commands folders and the sudo root's
    alone; and a
    trial `sudo true` through the channel before any change. Otherwise U28's terminal, with nothing changed.
  - The migrations' `sudo` accepts `-n`, `-H`, `-u root`, `-v`, `-k`, `-K`, `-l`, `--` and refuses every other option or
    target, and any command that is not root's alone (it and its folders). The unit has no namespace of its own. A
    migration
    it refuses, or whose command fails, stays pending ("Some of Omarchy's last steps need its terminal.", Finish in
    Terminal…).
- U33. The end of a run the shell saw going on (step 4) is one notice whose click opens Settings > General > Software
  Update: "Restart to finish updating", "Log out to finish updating", "Some of Omarchy's last steps need its terminal",
  "Updates installed" (with "Apps from the AUR are updated in Omarchy's terminal." when some wait for it, as the pane says),
  "Don't restart this computer yet", "This update needs a newer version of Grassfield", "This update needs Omarchy's
  terminal", "The update stopped before it finished" or "The update could not be installed", each with one line saying
  what to do. What finishes the update comes first: a restart, then a log out, then the migrations, then the AUR's apps
  (the pane lists every one). A restart or a log out is not posted when Settings' window is in front, since its sheet of
  U29 asks it; every other end is (the pane may show another section, and About This Computer has no pane). Nothing for a
  run that installed nothing (up to date), a dialog cancelled or refused, or a run that had already ended when the shell
  started. GF-083's "Log out to finish updating" waits while a run goes on and is never posted after the run's restart or
  log out (a restart covers the log out, ADR-0033 s3.7); a run still going on after an hour no longer holds it, and the
  next run holds it again. The run's restart or log out also covers U31's "Log out to finish updating" for a toolkit
  replaced under the session: a later check in the same session does not post it (one update, one notice); the pane's row
  stays. The shell
  watches the runner's state in its runtime folder (made 0700 first, as the runner makes it); a dev session watches its own
  folder (ADR-0019 `UPDATE_RUN_DIR`).
- U34. Staged rollout (ADR-0050): a machine syncs `[grassfield]` from one of 20 cohort paths
  (`<base>/<channel>/cohort/<NN>/$arch`, then the plain lines), chosen from a wariness root draws once and keeps in
  `/var/lib/grassfield/rollout-wariness`. Only `grassfield-desktop`'s `post_upgrade` enrolls, and only when the verified
  database lists the marker `grassfield-rollout 1`; a listing without it gives the plain form, as before; no listing, or a
  file an administrator changed, changes nothing. The synced `[grassfield]` files are never deleted inside the transaction
  (GF-045: `yay -Sua` later in `omarchy update`); their time goes to the epoch when they must be downloaded again. Set Up…, Beta Updates and Repair…
  write the plain form (the next Grassfield upgrade enrolls again). `grassfield-channel-set` and Grassfield Store read the
  cohort form as its channel.
- U35. With the marker, the checker reads the signed `grassfield-rollout.json` (strict schema, freshness, anti-replay;
  ADR-0050 3). A newer release still being released gradually shows a row "Grassfield 1.0.1 is being released gradually."
  with "It will be offered to this computer soon." (fr « Grassfield 1.0.1 est en cours de déploiement progressif. » /
  « Elle sera bientôt proposée sur cet ordinateur. »), with no button: Update Now installs only what the database offers.
- U36. A Grassfield release the descriptor marks as a security release says "Important security update. Installed: …" in
  its row and is announced as "Important security update" (once per version, whatever a later descriptor says); one not
  yet in the database reads "Grassfield 1.0.2 is an important security update."
- U37. An installed release the descriptor withdraws, while nothing newer is offered: the status headline is
  "Grassfield 1.0.1 has been withdrawn" (never "This computer is up to date" above it) and the row under it says "A corrected
  version is on its way." / "It will be offered to this computer as soon as it's ready." A paused release shows nothing.
- U38. A descriptor that is missing, invalid, unsigned, stale or expired removes the explanation only: the database
  decides what is offered, and the check succeeds as before.

## Refusals (what is refused, and what the user sees)
| Case | Behaviour |
|---|---|
| `grassfield-channel-set` run as root (`sudo grassfield-channel-set …`) | refused: "run it as your user; it asks for permission itself" |
| The helper started without root, with another verb or more arguments, or (pkexec verbs) while pacman's `db.lck` exists | refused, nothing changed |
| `grassfield-channel-helper` given a scriptlet verb, or `grassfield-channel-scriptlet` given a helper verb | refused, nothing changed (each program knows only its own verbs) |
| The polkit dialog cancelled, the password wrong, or no agent | the helper does not run; one line under the row; nothing changed |
| Unknown channel argument | refused, usage printed, nothing changed |
| A build without the pinned signing key, or whose `GRASSFIELD_REPO_BASE` is the `.invalid` placeholder (both the case until the owner provides a key and hosting) | refused: "no signing key in this build" / "no package repository in this build"; the pane hides "Set Up…", says that Grassfield's own updates are not available in this build, and still offers the system's updates (the container tests build their own `repository.conf` with a `file://` base and a throwaway key) |
| The shipped key file is not the pinned fingerprint | refused before `pacman-key` runs |
| `omarchy update` running (its lock held) | `grassfield-channel-set` refuses (and the helper while pacman runs); "Update Now" disabled; checks wait for the release (U4) |
| A package unsigned, signed by an unknown or disabled key, or changed after signing | pacman refuses it in Omarchy's terminal, nothing is upgraded (P8, P13); the next check still lists the update |
| A `[grassfield]` database unsigned, badly signed or signed by a revoked key, or a server offline with no mirror answering | pacman refuses the database (P5, P7, P8, P13, Q1) and every `omarchy update` fails; the checker reports `blocking` and offers "Turn Off…" (U22) |
| Notes unsigned, badly signed, revoked signer, over 64 KiB, not UTF-8, invalid JSON, not https | not shown (U6); the update is still offered |
| A first installation from downloaded files (`pacman -U ./…`) | not verified by pacman (`LocalFileSigLevel = Optional`, Q0); not a documented procedure. The verified one is ADR-0033 b.3a (out-of-band fingerprint, `--lsign-key`, install from the repository). The owner accepted the residual risk of the helper's bootstrap (O17). |
| A dev session | "Update Now", "Set Up…", "Repair…", "Turn Off…", the beta switch, "Log Out…" and "Restart…" log `dev guard: … suppressed` and do nothing (Settings refuses them, and its Backend again); `grassfield-channel-set` run by hand honours `GRASSFIELD_UPDATE_PKEXEC` (step 1) |
| A second check while one runs | joins the running one |
| `grassfield-update-helper` without root, with another verb, a bad operation id or migration name, more than 64 names, an operation id used before | refused (exit 2), nothing written but the reused operation's own files |
| `grassfield-update-run` as root, or with an argument | refused (exit 2) |
| Update Now while another run, an `omarchy update` or a Store operation holds Omarchy's update lock | "Another update is running.", nothing runs |
| A `db.lck` no process holds (a pacman that stopped mid-way) | nothing read or changed; "An earlier update stopped before it finished." with Update in Terminal… |
| A pacman plan line the helper cannot read (a field too many) | nothing changed; "The update could not be installed. Nothing was changed." |
| An update the compatibility check refuses (U27) | nothing changed, the system's sync databases untouched; "This update needs a newer version of Grassfield…" |
| An update that needs a person (U28) | nothing installed; "Update in Terminal…" |

## Acceptance criteria (each mapped to a test; level)
| Id | Criterion | Test | Level |
|---|---|---|---|
| A1 | 1.0.0 installed; 1.0.1 published → detected, then installed by `pacman -Syu` | container test (step 1) | L0 (container) |
| A2 | beta: 1.1.0beta1 detected and installed; back to stable: no downgrade, nothing listed; 1.1.0 stable → upgraded | container test | L0 |
| A3 | unsigned, foreign-key and changed packages refused, installed version unchanged | container test | L0 |
| A4 | corrupt database, offline channel: checker exits cleanly with `failed`, no crash, pacman's databases untouched | container test | L0 |
| A5 | Omarchy's `omarchy-refresh-pacman` (v4.0.4 script) overwrites `pacman.conf`: with the hook `[grassfield]` survives; without, the checker says `repair` and `grassfield-channel-set` repairs | container test | L0 |
| A6 | `grassfield-channel-set off` leaves a working pacman (no Include without its file) | container test | L0 |
| A6b | the helper, run as root in the container: every verb, the refusals (verb, `db.lck`, missing or mismatching key file), atomic writes; `grassfield-channel-set` on a recording pkexec stand-in | container test | L0 |
| A7 | channel switch drops the synced database (P7 case passes) | container test | L0 |
| A7b | layout against Omarchy's rewrites: the 3.x→4 awk, migrations 1787589206, 1788112314 (4.0.4) and 1791403252 (4.0.6) keep `[grassfield]` last (Q4, Q5) | container test | L0 |
| A7c | `blocking`: an offline or badly signed `[grassfield]` is detected by the `[grassfield]`-only sync; "Turn Off" (`off`) makes `pacman -Syu` work again; a mirror covers an offline primary (Q1, Q3) | container test | L0 |
| A7d | `off` and `pacman -Rns`: no `[grassfield]` line, no Grassfield key left, pacman works (Q6) | container test | L0 |
| A7e | host change: the scriptlet's `upgrade` rewrites a config on a previous base, leaves a custom one alone; "Repair…" in `custom` rewrites it | container test | L0 |
| A7g | the keyring: an empty one trusts nothing; after `off` a plain `pacman-key --populate` trusts nothing; `set` populates a newer key (R1–R3) | container test | L0 |
| A7h | `blocking` only after two failures in a row (fake clock) | checker tests | L0 |
| A7i | rollback by a new snapshot; a pointer moved back fails for clients already updated (R4) | grassfield-packages end-to-end | L0 |
| A7f | update lock: a request under the lock waits and checks after the release; a stale `db.lck` is removed (Q8) | checker tests | L0 |
| A8 | notes: good, rogue, changed, revoked signer, oversize, bad JSON | checker unit tests (Python, fixtures) | L0 |
| A9 | checker output parsing, states, announced versions, schedule (fake clock), dev guard of the actions | `tests/unit/tst_softwareupdate.qml`; `tests/shell/software_update_service.sh` (the service under Quickshell with a fake checker, its IPC); `tests/unit/tst_settingssoftwareupdate.qml` (the dev guard) | L0 |
| A10 | grassfield-packages' real packages: stable install, update, beta and back, bad signature, the client sees each update | grassfield-packages end-to-end (step 1b) | L0 |
| A11 | pane, badge, menu count, notification, light and dark, en and fr, keyboard | `tests/unit/tst_settingssoftwareupdate.qml`, `tst_settingsmain.qml`, `tst_dockmodel.qml`; the Backend's doors in `tests/unit/settings/tst_systemguard.cpp` and `tst_backend.cpp`; captures `docs/audits/settings-parity-2026-10-26/software-update*.png` (offscreen; nested: visual NOT verified) | L0/L1 |
| A12 | real flows: the polkit dialog of Set Up…, Beta Updates and Turn Off… (cancel once, a wrong password once, then accept), Update in Terminal… in Omarchy's floating terminal | owner, real session | L2 |
| A13 | the update helper as root: usage and privilege refusals, a hostile environment dropped, up to date without touching the sync databases, a `db.lck` held (busy) or left behind (stale) before anything is read, its own lock busy, Omarchy's key missing (after an incompatible update is said so), a plan line it cannot read, pacman's lock taken for the swap and gone after it, Omarchy's 4.x layout (commands in `usr/bin`, links in `usr/share/omarchy/bin`), a migration reading `/dev/tty`, no command file to scan, a migration that is a link, more than 64 pending (the runner), an update through Omarchy's real guard hook, the compatibility check (a toolkit change refused; joined by a matching Grassfield build; major.minor; Quickshell whole; a build without a record), Omarchy's migrations (a new one that calls a `sudo` command through another; a plain one; one named pending), conflicts inside the transaction, the 16 newest operations kept; through real polkitd and pkexec (a password each time, a wrong one, a user refused); the runner as a user (its state file, migrations run as the user without a terminal, a pending one that asks, Omarchy's lock held) | `tests/integration/update_helper.sh` (throwaway Arch container) | L0 (container) |
| A14 | the pane's run: Update Now's one launch, each phase and count, the bar, the pane opened again mid-run, a runner gone with or without its helper, a reused process id, each outcome's sentence and action, the end's sheet, no restart after a failed startup image, the dev guard | `tests/unit/tst_softwareupdate.qml` (the run's logic), `tst_settingssoftwareupdate.qml`, `tst_settingsmain.qml`; the launch vectors in `tst_systemguard.cpp`, `tst_backend.cpp`; captures `software-update-run.png` | L0/L1 |
| A16 | one password (U32): the migrations' sudo inside its unit (root, input, folder, status, arguments, temporary files, options, lookup; other names, verbs and operations refused) and refused everywhere else without a dialog; the person's other processes kept out of the unit's `/proc` entries; the real helper from a runner through pkexec: a non-administrator, a group with a member, an older migration pending, a rule that grants nothing or none, all to the terminal; an administrator's migration as the person with its sudo as root, `migrations ran`, its output root's; a failed sudo left pending; `gum` to the terminal; root without a person; the unit form outside the unit | `tests/integration/update_migrate.sh` (throwaway Arch container run by systemd) | L0 (container) |
| A17 | staged rollout (U34-U38): the root enrollment (wariness drawn once, kept, a damaged one redrawn, a link refused; a link or another user's state folder refused; cohort bounds; marker present, absent, of another scheme, or no listing: pacman failing or no synced database (unchanged); plain↔cohort; a custom or administrator-changed file untouched; the synced files never deleted inside the transaction, their time set to the epoch on every change of form or cohort and a host migration (GF-045); a previous host's cohort form migrated); the descriptor's schema, bounds, freshness, anti-replay and signature; the reach formula and cohort offering; staged, withdrawn, security; the pane's rows; the battery gate; the Store's channel | `tests/shell/staged_rollout_root.sh`, `tests/shell/update_check.sh`, `tests/shell/channel_set_rule.sh`, `tests/fuzz/fuzz_helpers.py` (update-check), `tests/unit/tst_softwareupdate.qml`, `tst_settingssoftwareupdate.qml`, `tests/unit/store/tst_channel.cpp`; end to end with a publisher: NOT VERIFIED | L0 |
| A15 | real flow: Update Now with a published test channel (the dialog once, the snapshot, the progress, closing and reopening Settings mid-run, Restart Later then Restart); a toolkit update without a matching build refused; an Omarchy release with a `sudo` migration sent to the terminal | owner, real session (the integrator's L2) | L2 |

## Interfaces / contracts (versions)
- ADR-0033 § g (the repository contract; `grassfield-notes.json` version 1).
- `grassfield-update-check` output, version 1: `{"version":1,"state":…,"channel":…,"checkedAt":…,"lastSuccessAt":…,
  "error":…,"grassfield":{"installed":…,"available":…,"notes":[…]},"omarchy":{"installed":…,"available":…},"others":N}`.
  Step 2 adds `otherPackages` (the list behind `others`), cut first when the output would pass 256 KiB (ADR-0033 d.3).
  ADR-0041 step 2b adds `toolkit` (U31: `{"record":bool,"packages":[{"name","installed","installedAt","built","moved"}]}`,
  one entry per tracked package pacman names), in every state that runs the checker (not in `busy` or `update-running`,
  answered before it: the shell then keeps the file's).
- `software-update.json`, version 1: the last output plus `announced` (versions already notified), `logoutPending` (U14) and
  `toolkitLogout` (U31: the pending log out is for a toolkit replaced under the session).
  State class, ADR-0020.
- `grassfield.json`: `updates.automaticCheck` (boolean, default true), schema-generated (ADR-0020).
- Step 3: `/usr/share/grassfield/BUILD-DEPS` (`<name> <version>` lines, U27); `/run/grassfield-update/<op>.progress`
  (`checking | snapshot | keyring | downloading <done> <total> | installing <done> <total> | finishing`), `<op>.exit` (the code,
  then `key value` lines: `packages`, `snapshot`, `restart`, `logout`, `bootimage`, `needs`, `incompatible`), `<op>.started`,
  `last`; `$XDG_RUNTIME_DIR/grassfield/software-update-run.json` (version 1: `op`, `pid`, `startTime`, `phase`, `result`,
  `restart`, `snapshot`, `deferred`, `startedAt`, `finishedAt`). The polkit action `org.grassfield.packages.update-system`.
- Shell IPC: `update check` (Settings → shell). The `omarchy-shell` shim forwards `omarchy.system-update refresh|clear` to it.

## Dependencies (verified versions)
On Omarchy 4.0.4 (its `install/omarchy-base.packages`): `pacman-contrib` (`checkupdates`; P0: 1.13.1-1), `fakeroot`, `jq`,
`gum`, `uwsm`, `xdg-terminal-exec`; pacman 7.1 (P0); gnupg 2.4 (`gpgv`); curl; python; polkit (`pkexec`). `omarchy` 4.0.6
itself depends on `omarchy-keyring`, `pacman-contrib` and `fakeroot`. `pacman-contrib` and `fakeroot` are in
`grassfield-desktop`'s `depends` since step 1 (declared, not assumed); `grassfield-keyring` joined them once
grassfield-packages built it (owner decision O21; until the repository is published, a source build installs it first,
owner decision O22). Omarchy's commands used:
`omarchy-launch-floating-terminal-with-presentation`, `omarchy-update`, `omarchy-hook` (through Omarchy itself); step 3:
`omarchy-migrate`, `omarchy-hook`, `omarchy-update-mise` (run by the runner as the user). Step 3's root steps use pacman,
`pacman-key --list-keys`, `paccache` (pacman-contrib), snapper when installed, bsdtar (libarchive), `systemd-inhibit` and
`systemd-run`; `quickshell` joins the build's `makedepends` so BUILD-DEPS records it.

## Degraded behavior
- `checkupdates` missing: state `failed`/`unavailable` with "pacman-contrib is not installed"; no other effect.
- Omarchy's launcher missing (not an Omarchy system): the actions are disabled, with a sentence; the check still works.
- The runner, its helper or pkexec missing: Update Now opens Omarchy's terminal (U11).
- No systemd as the system's manager (a container): the helper runs in place, under pkexec.
- snapper missing or unconfigured: the update goes on without a snapshot, as Omarchy's does; the failure sentence then names
  none.
- No shell (Settings alone): Settings runs the checker (U10); no badge, no banner.
- Offline: automatic checks skipped; a manual check fails cleanly (U2, A4).

## Automated tests · Manual verification steps
- Step 1 container test (`tests/integration/software_update.sh [--omarchy DIR] [--omarchy-next DIR]`, which starts a
  throwaway Arch container itself and refuses to run outside one, as the ADR's probes): the A1–A7 cases with fake
  packages signed by throwaway keys made in the container, Omarchy's v4.0.4 `omarchy-refresh-pacman` and migrations (and
  4.0.6's 1791403252), the real `grassfield-channel-set`, helper, scriptlet program, policy (real polkitd and pkexec), hook
  and checker. Never on the owner's machine. The checker's own cases: `tests/shell/update_check.sh` (logic layer, stubs).
- Checker unit tests (A8), QML tests (A9), grassfield-packages end-to-end (A10).
- Step 3 container test (`tests/integration/update_helper.sh [--omarchy DIR]`, a throwaway Arch container with network:
  Arch's mirrors and keys.openpgp.org for Omarchy's public key): A13. Never on the owner's machine.
- Owner, real session (L2): Set Up… (Grassfield's polkit sheet), Update Now with a published test channel, Beta
  Updates on and off, an Omarchy channel change with the hook, Log Out… after an update.

## Performance (gates affected) · Accessibility · i18n
- No resident process; a check every 6 h at most in the background. `checkupdates` downloads a database only when it changed
  (Omarchy's `extra.db` is about 8.8 MB). P1 (idle CPU) is unaffected. The UI never waits on the child (U1, U4).
- Every control has a name and is reachable by keyboard (A1 gate). Notes are plain text, readable by assistive technology.
- Every string is in `qsTr` (en, fr). The release notes come in en and fr from the channel.

## Known limitations
- A `[grassfield]` that cannot sync (server down with no mirror answering, a wrong signature, a revoked key) makes every
  `omarchy update` fail, security fixes included, until it is fixed or turned off (U22). Mirrors cover outages, not a bad
  publication (Q1).
- How Landlock treats the user-side check under `fakeroot` on a real Omarchy machine is NOT VERIFIED: Docker refuses
  Landlock (R5). The check uses checkupdates' own `--disable-sandbox-filesystem`.
- A client whose two requests straddle a publication's pointer write gets a mismatched pair once; that `omarchy update` fails,
  the next one works (ADR-0033 h.2).
- The update-lock waiter and the quick test hold Omarchy's lock for microseconds. An `omarchy update` started at that very
  instant reports "already running".
- Omarchy's own channel change (`omarchy-channel-set`, through `omarchy-refresh-pacman`'s `pacman -Syyuu`) and
  `omarchy-reinstall-pkgs` (`pacman -Suu`) allow downgrades. After leaving the Grassfield beta, they replace the beta with
  the stable version at once (P11), instead of waiting for a newer stable. Omarchy's own packages behave the same way.
- Leaving the beta keeps the beta build until a stable version passes it, so stable-only fixes released meanwhile are not
  received (macOS behaves the same way).
- No automatic download or install, no install at logout: pacman's cache and the install need root, and the owner wants no
  install without the user.
- "Update Now" updates the whole system (Omarchy's update), not Grassfield alone.
- One password (U32).
  - What a migration reads from the person's own files can still steer it, as in Omarchy's terminal (ADR-0033 s5.3).
  - A migration's own `pacman -Syu` is not checked by U27, as in Omarchy's terminal; its changes give the end its restart.
  - Files a migration creates get the group `grassfield-update`.
  - A process a migration leaves running ends with the migrations' unit.
  - The channel needs systemd ≥ 254, polkit with `system_unit` and a bus that hands polkit a pidfd (dbus-broker); without
    them, the trial fails and U28's terminal follows.
  - Omarchy 4.0.4 → 4.0.6 still goes to the terminal: two of its migrations reach `gum` through Omarchy commands
    (ADR-0033 s5.4).
- An Omarchy release whose new migrations use `sudo` runs them without a terminal, with the password of Update Now (U32),
  when nothing in them needs a person; otherwise it goes to Omarchy's terminal (U28, ADR-0033 s3.6, s5). Omarchy 4.0.4 →
  4.0.6 still does: two of its migrations reach `gum`.
- AUR apps are not updated by Update Now (U28).
- The compatibility check covers five packages; another library Grassfield links can move unchecked.
- A package conflict is found by pacman only inside the transaction (`--print` does not check them), after the checked
  databases became the system's: nothing is installed, and Grassfield Store refuses installs until an update finishes.
- The end-of-run notice (U33) needs the shell to have seen the run going on: a run that started and ended while the shell
  was not running (a crash, a restart of the shell) is said only by the pane's row. A runner killed during the run leaves
  its state going on: no notice, and GF-083's waits an hour. A run folder removed during the session is no longer followed
  until the shell starts again (Quickshell's FileView, measured by the step 4 review).
- The transient system service, the real polkit dialog and snapper are verified only on a real machine (A15).
- A host can replay an old, validly signed database and hold back updates; pacman has no database expiry.
- One signing key (owner decision O6): if it is ever compromised, revoking it stops every client's `[grassfield]` (`blocking`)
  until the user turns it off or trusts a new key through the verified first-installation steps (ADR-0033 b.3a, b.5).
- The first `grassfield-desktop` installed is the trust anchor of the helper's bootstrap (owner decision O17). A package
  installed from a file with `pacman -U` is not verified.
- Omarchy can ship a new Hyprland before the matching plugin is published: the session runs degraded (ADR-0009) until then.
- The channel is per machine. Another user's Omarchy channel change, without their own hook, puts this machine in `repair`
  until someone runs "Repair…".
- `checkupdates` gives one message for every failure ("Cannot fetch updates"): the pane tells offline apart only through the
  shell's connectivity, not an untrusted key from a corrupt database.
- In a nested dev session the polkit agent cannot register (`docs/specs/security.md` L5); the actions are suppressed there
  anyway. In an Omarchy session the dialog is Omarchy's agent, not Grassfield's sheet.
- Nothing is published: until the owner enables hosting, the base is the `.invalid` placeholder and "Set Up…" is hidden
  (Refusals).
- "Software Update" is a descriptive name, as on macOS; it is on the legal review list with the pane
  (`docs/legal/visual-review.md` E37, question 13).
- Without a shell, Settings runs the checker itself without `--offline` (it does not know the connectivity): a failure while
  offline then counts towards `blocking` like one online.
- Measured parity with macOS is not verified: no capture of the pane is on the machine that built it.
- The restart rule (U14) is close to Omarchy's `omarchy-update-restart`, not the same. Omarchy:
  - treats the kernel as updated when no package-owned `/usr/lib/modules/*/vmlinuz` belongs to the running release
    (`pacman -Qo`);
  - also offers a reboot when the running Hyprland binary was replaced;
  - restarts the services its `restart-*-required` markers name;
  - clears its markers when it reboots.
  Grassfield's pane only reads Omarchy's `reboot-required` marker and whether the running kernel's modules folder is gone (no
  pacman query). It says nothing for a replaced Hyprland or a service restart, and changes no marker.
