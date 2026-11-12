# ADR-0033: Software Update: a signed [grassfield] pacman repository in two channels, installed through Omarchy
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed, applied provisionally until the owner accepts it (cloud session, owner brief 2026-10-27). Step 0 (this
ADR and the spec) passed the opus review on its third round and was merged in 609017f (PR #11); step 1 is grassfield PR
#16 (the client) and grassfield-packages PR #3 (step 1b, the infrastructure), both merged; O21's follow-up adds
`grassfield-keyring` to grassfield-desktop's `depends`; step 2 (the pane) was merged in bf829c7. Step 3 (owner decision
SU-M1: Update Now without a terminal, through a root helper) is "Step 3" below. The owner's answers O1-O22 and SU-M1 are
recorded below; the opus reviews are in "Review history". ·
Date: 2026-10-27 · Decider: owner (every choice in "Owner decisions"), integrator (merge after the opus PASS)

This ADR is the contract between this repository (the desktop, its `PKGBUILD` and the Software Update client) and
`grassfieldhq/grassfield-packages` (building, signing and, later, serving the repository). Its README and the project's working rules cite it
by this number. Behaviour, refusals and limits for users are in `docs/specs/updates.md`. Evidence:
- the probes quoted as P0 to P13 are `docs/audits/software-update-2026-10-27/adr0033-probes.sh`;
- those quoted as Q0 to Q8 (the first review's round) are `adr0033-probes-2.sh` in the same folder;
- those quoted as R0 to R5 (the second review's round) are `adr0033-probes-3.sh` in the same folder.
Both ran in a throwaway `archlinux:base` container ("Evidence" says where and how). Their full outputs sit next to them.

## Context

### Owner decisions (brief of 2026-10-27)
- The Omarchy model (D1: never fork Omarchy). Grassfield gets a `[grassfield]` repository with two channels, **stable** and
  **beta**, on the same pattern as Omarchy's `pkgs.omarchy.org/{stable,rc,edge}/$arch`.
- "Update Now" updates the **whole system through Omarchy**, in a terminal, as Omarchy's own menu does. Grassfield has no
  root code to install anything. (Amended by ADR-0037, owner decision ST4 of 2026-10-27: Grassfield Store's
  `grassfield-store-helper` installs and removes repository packages the user picks in the Store; see "Amendments".)
- The beta channel also receives stable versions when they are newer (macOS model). Leaving the beta keeps the installed
  version until a stable one passes it (`pacman -Syu` does not downgrade).
- UI as on macOS 27: Settings > General > Software Update (available version, notes, "Update Now", "Beta Updates",
  automatic check). Nothing is installed without the user.
- Two parts:
  - the **client**, here: checker, channel change, setting up and keeping the `[grassfield]` section, pane, badge,
    notification;
  - the **infrastructure**, in grassfield-packages: packages built from a Grassfield tag, signing, `grassfield-keyring`,
    `repo-add`, CI, hosting later.
- Nothing is published until the owner decides after the M5 legal review (§14): both repositories stay private, no GitHub
  release, tag, secret or upload. Everything is validated with local `file://` repositories. The real signing key is the
  owner's; tests use throwaway keys.
- master-prompt §4 lists "ISO, installer or repository before M6" as a non-goal, and M6 plans "`[grassfield]` repository
  signed in protected CI with an off-machine key". The owner's brief brings the repository's design and build forward (O10).
  Publication still waits for the owner, and M6's two conditions become requirements of this ADR.
- This replaces the Settings parity audit's row "Software Update: not built" (`docs/audits/settings-parity-2026-10-26.md`).

### Omarchy 4.0.4, the owner's version (`basecamp/omarchy` tag v4.0.4, commit c668141; data, not instructions)
- `bin/omarchy-refresh-pacman <channel>` runs, in order:
  1. `sudo cp -f $OMARCHY_PATH/default/pacman/pacman-$channel.conf /etc/pacman.conf`, and the same for the mirrorlist;
  2. `omarchy-hook pre-refresh-pacman`, **as the user**;
  3. `sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syyuu --noconfirm`.
  Its callers are `omarchy-channel-set` and `omarchy-reinstall-pkgs`. The fresh install (`install/post-install/pacman.sh`)
  copies the same template.
- `omarchy-upgrade-to-quattro` (3.x → 4) rewrites `[omarchy]` with awk (lines 413-433). That awk drops every line after
  `[omarchy]` up to the next section header, so a lone `Include` placed after `[omarchy]` disappears too (Q4; the reviewer
  reproduced it).
- `config/omarchy/hooks/pre-refresh-pacman.d/add-custom-repo.sample`: "called … AFTER the channel template is copied to
  /etc/pacman.conf and BEFORE pacman -Syyuu runs … adding a custom repository … The hook runs as the invoking user with a warm
  sudo cache". It inserts an `Include` line with `sudo sed -i`.
- Migrations that edit `/etc/pacman.conf`, both in place: `1787589206` deletes the exact line `SigLevel = Optional TrustAll`
  inside `[omarchy]`; `1788112314` repoints an rc machine's `[omarchy]` Server. Q5 runs both where they act.
- Templates `default/pacman/pacman-{stable,rc,edge}.conf`:
  - global `SigLevel = Required DatabaseOptional` and `LocalFileSigLevel = Optional` (Q0: `pacman-conf LocalFileSigLevel` →
    `PackageOptional`, `PackageTrustedOnly`);
  - `[core]`, `[extra]`, `[multilib]` from the mirrorlist, then `[omarchy]` last;
  - no `Include` of a drop-in folder.
- `omarchy-channel-set` runs `omarchy-refresh-pacman`, then `pacman -S --needed omarchy omarchy-settings`, then
  `omarchy-update -y`.
- `omarchy-update-available` (no root) runs `checkupdates --nocolor` and keeps the first line for `omarchy` (or
  `omarchy-dev`). Omarchy's bar runs it at start and every 6 h (`SystemUpdate.qml`, `interval: 21600000`). The bar's click and
  the menu entry `update.omarchy` run `omarchy-launch-floating-terminal-with-presentation omarchy-update`
  (`default/omarchy/omarchy-menu.jsonc:341`).
- `omarchy update` (no `-y`):
  - it takes `${XDG_RUNTIME_DIR:-/tmp}/omarchy-update.lock` (lines 15-16) and asks "Continue with update?";
  - snapshot, keyrings, `pacman -Syu`, migrations, `post-update` hooks;
  - `omarchy-update-status` (line 55, still under the lock): `omarchy-shell -q omarchy.system-update refresh|clear`;
  - `omarchy-update-restart`: a reboot offer when the kernel changed, when `~/.local/state/omarchy/reboot-required` exists or
    when Hyprland was replaced; then `omarchy-restart-shell`.
  A pacman hook (`00-omarchy-update-guard.hook`) refuses a direct `pacman -Syu` without `OMARCHY_UPDATE_PACMAN=1`.
- `omarchy-keyring` 20251027-1: `/usr/share/pacman/keyrings/omarchy{.gpg,-trusted,-revoked}` and an install script running
  `pacman-key --populate omarchy`, with no removal step. `omarchy-update-keyring` bootstraps it (`--recv-keys <fingerprint>
  --keyserver keys.openpgp.org`, `--lsign-key`, `pacman -Sy`, then the keyring package). `omarchy-4.0.6-1` depends on
  `omarchy-keyring`, `pacman-contrib` and `fakeroot`.

### Omarchy 4.0.6, now its stable channel (tag v4.0.6, commit 237f1b4)
Every Omarchy file this ADR relies on is byte-identical to 4.0.4, except these:
- `default/pacman/pacman-*.conf` now put **`[omarchy]` first**, before `[core]`;
- **new migration `1791403252`** moves the `[omarchy]` section of an existing `pacman.conf` to the top (awk by section
  headers, then `omarchy-update-system-pkgs`). A lone `Include` placed after `[omarchy]` would travel with it (Q4);
- the sample hook now inserts its `Include` above `[omarchy]`;
- `omarchy-channel-set` clones from `omacom/omarchy`, and `omarchy-update-keyring` installs `archlinux-keyring` with
  `--needed`.
Files compared with sha256: `bin/omarchy-{refresh-pacman,hook,update,update-available,update-status,update-restart,
update-lock,update-system-pkgs,update-pacman-guard,launch-floating-terminal-with-presentation,state,system-reboot,
reinstall-pkgs}`, `default/libalpm/hooks/00-omarchy-update-guard.hook`, `default/omarchy/omarchy-menu.jsonc`,
`shell/plugins/bar/widgets/SystemUpdate.qml`, migrations `1787589206` and `1788112314`, `install/omarchy-base.packages`.

### Omarchy's servers (2026-10-27)
- `pkgs.omarchy.org/{stable,rc,edge}/x86_64/omarchy.db` answer 200. `stable/x86_64/omarchy.db.sig` answers 404: the database
  is not signed, the packages are. Stable serves `omarchy-4.0.6-1`; rc and edge serve `omarchy-4.5.0rc1-1`.
- **Hyprland is not in `[omarchy]`.** It comes from Arch's `[extra]` through Omarchy's dated mirrors (`stable-mirror`,
  `rc-mirror`, `mirror.omarchy.org`). All three serve `hyprland-0.56.2-4`.
- Omarchy's own plugin package `omarchy-hyprland-titlebars-0.2.2-2` depends on `hyprland=0.56.2`. Grassfield keeps ADR-0009
  (no pin, degraded mode on a mismatch).

### Grassfield today
- `VERSION` is 1.0.0-rc1. `packaging/arch/PKGBUILD` builds `grassfield-desktop`, `grassfield-compositor` and
  `grassfield-icons` from a `git archive` of HEAD, with `pkgver=${VERSION//-/}` and `pkgrel=3`. Its install script is
  `grassfield-desktop.install`.
- `shell/platform/UpdateNotice.qml` (GF-083) shows "Log out to finish updating". The ADR-0009 loader degrades on a
  plugin/Hyprland mismatch.
- Shims in a Grassfield session: `omarchy-shell` (only `lock lock|status`; anything else fails silently with `-q`) and
  `omarchy-restart-shell` (no-op). `grassfield-session-end` clears Omarchy's `re*-required` markers on restart.

## Decision

### Overview
```
grassfield tag vX.Y.Z[-betaN|-rcN]
  └ grassfield-packages CI: an Arch container with Omarchy stable's package set → makepkg (this repository's PKGBUILD)
      → sign packages, database and notes → repo-add → an immutable snapshot of the channel (a CI artifact; published later)
User's machine (Omarchy 4)
  /etc/pacman.conf, last two lines:  [grassfield]
                                     Include = /etc/pacman.d/grassfield.conf   ← put back by Omarchy's pre-refresh-pacman hook
  /etc/pacman.d/grassfield.conf:     SigLevel = Required
                                     Server = <base>/<channel>/$arch   (+ mirrors)
        written only by grassfield-channel-helper (pkexec, from grassfield-channel-set) or grassfield-channel-scriptlet (pacman)
  grassfield-shell → grassfield-update-check (the user; checkupdates and a [grassfield]-only check on its own databases)
        → pane, Dock badge, menu, banners; "Turn Off Grassfield Updates…" when [grassfield] blocks every update
  "Update Now" → omarchy-launch-floating-terminal-with-presentation omarchy-update        (Omarchy's command, unchanged)
```

### a. The [grassfield] section survives Omarchy
1. **Layout.** `/etc/pacman.conf` gets two lines, last: `[grassfield]` and `Include = /etc/pacman.d/grassfield.conf`. This is
   how `[core]` includes its mirrorlist. The included file holds `SigLevel = Required` and the `Server` lines (one per mirror,
   g). Omarchy never writes that file. Why the header sits in `pacman.conf` (round 1 had it in the included file): Omarchy
   rewrites `pacman.conf` section by section.
   - Q4, the 3.x→4 upgrade's awk: the old layout is reduced to `core extra multilib omarchy`; the new one keeps `grassfield`.
   - Q4, 4.0.6's migration 1791403252: the old layout ends as `omarchy grassfield core extra multilib` (Grassfield ahead of
     Arch); the new one as `omarchy core extra multilib grassfield`.
   - Q5: migrations 1788112314 and 1787589206, run where they act (an rc mirror with `[omarchy]` on edge; `SigLevel =
     Optional TrustAll` in `[omarchy]`), leave both lines in place.
   - P2: both layouts parse (`--repo grassfield` shows `DatabaseRequired`, `PackageRequired` and the Server).
2. **Last.** `[grassfield]` comes after every Omarchy and Arch repository (4.0.4 and 4.0.6 templates alike, Q4) and never
   shadows one of their packages. Nothing may be appended after the `Include` without a section header (P2 "after").
3. **Never owned by a package, never left half.** An `Include` whose file is missing stops every pacman command (P2: `pacman
   -Qq pacman` exits 1 with "config file … could not be read"; a glob that matches nothing fails the same way). The file is
   written and removed only by `grassfield-channel-helper` and `grassfield-channel-scriptlet` (c). `off` removes the two lines
   before the file. Uninstalling cannot leave the lines without their file: `grassfield-desktop`'s `pre_remove` runs the
   scriptlet's `remove`, which does what `off` does (c, b.8). In Q6, `pacman -R` of a
   package whose `pre_remove` does the same leaves `--repo-list` without `grassfield` and `pacman -Qq pacman` exits 0.
4. **Persistence: Omarchy's own extension point (O4).** `grassfield-channel-set` links
   `~/.config/omarchy/hooks/pre-refresh-pacman.d/50-grassfield` to the packaged
   `/usr/share/grassfield/omarchy-hooks/pre-refresh-pacman`. When `/etc/pacman.d/grassfield.conf` exists and `pacman.conf` has
   no `[grassfield]` line, the hook appends the two lines with `sudo tee -a`, under the warm sudo cache of Omarchy's sample.
   Omarchy's `-Syyuu` then syncs `[grassfield]` too.
   - P10: without the hook the section is gone and the file stays; with it the two lines are back, last, and
     `/var/lib/pacman/sync/grassfield.db` exists.
   - It is a link, not a copy, so a package update updates the hook.
   - After an uninstall the dangling link is skipped silently (P11: `omarchy-hook pre-refresh-pacman` exit 0, no "Hook
     failed").
5. **Fallback.** The checker reads `pacman-conf --repo-list`, with no root. When `grassfield` is not listed:
   - if `/etc/pacman.d/grassfield.conf` exists, the state is `repair`: the pane says Omarchy reset the package configuration
     and offers "Repair…" (the helper's `restore`, c);
   - otherwise the state is `not-set-up` ("Set Up…").
   This covers another user's Omarchy channel change (the hook is per user), a sudo cache that is cold with no terminal, and a
   hand edit.

Rejected: an alpm hook re-adding the lines (Grassfield code as root in every transaction, and no hook fires on Omarchy's
`cp`); the whole section in `pacman.conf` (more lines to restore, the same loss); detection and "Repair…" alone (every Omarchy
channel change would pause Grassfield updates until the user acts).

### a2. A [grassfield] that cannot sync stops every update
pacman aborts `-Syu` when any database fails to sync.
- Q1: `[grassfield]` offline → "failed to synchronize all databases", exit 1, and `other-pkg 1.1`, waiting in another
  repository, is not installed.
- P7 and P8: a database without its signature or with a mismatched one fails the same way.
So a `[grassfield]` that cannot sync makes **every** `omarchy update` fail, security fixes of Arch and Omarchy included, and
4.0.6's migration 1791403252 with it (it runs `omarchy-update-system-pkgs`). The causes: the server offline, a missing `.sig`,
a rotation done wrong, the only key revoked, an upload caught half way. The defences:
1. **Mirrors.** `grassfield.conf` may hold several `Server` lines. pacman tries the next one when a download fails (Q1: the
   first offline, the second answering → exit 0, `other-pkg` upgraded). It does not when a signature is wrong (Q1: a mismatched
   `.sig` on the first server, a good copy on the second → exit 1). Mirrors therefore cover outages, not bad publications.
2. **Atomic publication (h).** The database and its signature switch together, through one pointer to an immutable snapshot
   (Q2).
3. **Key rotation with an overlap (b.4).**
4. **Detection and "Turn Off" (owner decision O18).** The checker also syncs `[grassfield]` alone, as the user:
   - its own minimal configuration (`[options]` plus the `Include`, no `DisableSandbox`) and its own database;
   - under `fakeroot`, with stdin from `/dev/null`;
   - with checkupdates' own flag `--disable-sandbox-filesystem` (pacman-contrib 1.13.1, line 150).
   Q3: reachable → exit 0; offline → exit 1 within a second; untrusted key → exit 1 at once with "keyring is not writable",
   no prompt. Q3 ran with `DisableSandbox` in that configuration. R5 runs it as specified (no `DisableSandbox`, the flag):
   exit 0. In the same container, root pacman without `DisableSandbox` fails: "the Landlock ruleset could not be applied:
   Operation not permitted", Docker refusing Landlock. With `--disable-sandbox-filesystem` it works. The containers'
   `DisableSandbox` is therefore a Docker necessity. How Landlock behaves for a user under `fakeroot` on a real Omarchy
   machine is NOT VERIFIED here; the flag follows checkupdates, which runs the same way.
   **One failure is not enough:** a failed `[grassfield]`-only sync while online schedules a second one 15 minutes later, and
   only two failures in a row make the state `blocking`. A transient error never raises the notification. In `blocking`:
   - the pane says that Grassfield's repository cannot be used and that this stops every system update;
   - it offers **"Turn Off Grassfield Updates…"**, the helper's `off` behind the polkit dialog;
   - one notification per episode says the same, and its action opens the pane.
   Nothing is turned off without the user. Once turned off, `pacman -Syu` works again (Q1: `--repo-list` without `grassfield`,
   exit 0), and "Set Up…" brings the section back later.
5. **Documented** as a known limit in the spec.

### b. Signing and trust
1. **What is signed (O5).** `SigLevel = Required` in Grassfield's own file covers both databases and packages, with trusted
   keys only, so a change to the global setting cannot weaken it. Omarchy signs only its packages; Grassfield signs its
   database too:
   - P8: no `grassfield.db.sig` → "failed to synchronize all databases";
   - P7: a database that does not match its signature → "signature … is invalid".
   Packages are refused in three cases, and nothing is upgraded (`pacman -Q` keeps the version installed before):
   - unsigned (P8, 1.1.1);
   - signed by an unknown key (1.1.2, "required key missing from keyring");
   - changed after signing (1.1.3, "signature … is invalid").
2. **`grassfield-keyring`**, built in grassfield-packages (infrastructure; the desktop's single build definition, ADR-0023,
   stays this repository's PKGBUILD):
   - `arch=any`, `pkgver` = date (`YYYYMMDD`);
   - `grassfield.gpg`, `grassfield-trusted` (`<fingerprint>:4:` lines) and `grassfield-revoked`, in a **private folder,
     `/usr/share/grassfield/pacman-keyring/`**, not in `/usr/share/pacman/keyrings/`;
   - an install script whose `post_install`/`post_upgrade` run `pacman-key --populate-from
     /usr/share/grassfield/pacman-keyring --populate grassfield`, only when `grassfield.gpg` is not empty and
     `/etc/pacman.d/grassfield.conf` exists (Grassfield updates are on);
   - a `pre_remove` step (b.8).
   This departs from omarchy-keyring's layout on purpose (R2):
   - in `/usr/share/pacman/keyrings/`, a plain `pacman-key --populate`, run by a user or by any other keyring's install,
     made a key that "Turn Off…" had deleted trusted again (`f`);
   - in the private folder it stays absent, and only `--populate-from` brings it back;
   - an upgrade of the keyring package while Grassfield updates are off trusts nothing.
   `grassfield-desktop` depends on it, as `omarchy` depends on `omarchy-keyring` (O12).
   **Until the owner's key exists (O11, owner decision O20), `grassfield-keyring` holds no key** (empty files). It installs
   and trusts nothing (R1: 184 keys in pacman's keyring before and after; the install script skips an empty keyring, since
   `--populate` of it only prints "no valid OpenPGP data found"). So the owner's machine, which needs the package for local
   `makepkg -si` builds (O12), never trusts a test key.
   **Test keys** are generated at each test run, inside the throwaway test container (P3, Q0, R0). They are never committed,
   never installed outside a container, and never part of a published artifact. A test keyring is built inside the container
   from them and dies with it.
3. **Bootstrap by the helper (kept, owner decision O17).** This repository pins the signing key: `packaging/pacman/
   repository.conf` holds its fingerprint, and the public key ships beside it. Until the owner provides them (O11), both are
   empty and `grassfield-channel-set` refuses ("no signing key in this build"). The helper's `set` tests the key's **trust**,
   not its presence: its validity in pacman's keyring must be full or ultimate (`--with-colons`). pacman can import a key on
   its own (P5: "Import PGP key …? [Y/n]"), which leaves it present but untrusted. When the key is not trusted, `set` checks
   that the shipped key file has exactly the pinned fingerprint, then runs `pacman-key --add` and `--lsign-key <fingerprint>`
   (P5: before, the database is refused, "key … is unknown"; after, the packages install). `set` then always runs
   `pacman-key --populate-from /usr/share/grassfield/pacman-keyring --populate grassfield`, so every key of the installed
   keyring is trusted again, including one newer than the pinned key, and every revoked one disabled. R3: after "Turn Off…",
   trusting only the pinned K1 left a database signed by the newer K2 refused ("key … is unknown"); after `--populate-from`,
   `pacman -Sy` and the install worked.
   Residual risk, accepted by the owner: the first `grassfield-desktop` installed is the trust anchor. A package installed
   with `pacman -U ./file` is not verified (`LocalFileSigLevel = Optional`, Q0) and could pin a key of its own. The first
   installation is therefore specified as a verified procedure (b.3a); `pacman -U` of downloaded files is not one.
3a. **First installation, verified.** The signing key's fingerprint is published out of band: at least two places the owner
   controls, such as the project site and the public repository's README, once hosting exists. The documented steps:
   1. `sudo pacman-key --recv-keys <FINGERPRINT> --keyserver keys.openpgp.org` (gpg checks that the key it receives has that
      fingerprint). Without a keyserver: `sudo pacman-key --add grassfield.asc`, downloaded from the host.
   2. `sudo pacman-key --lsign-key <FINGERPRINT>`. It signs only a key with exactly that full fingerprint and fails when the
      keyring holds none, so a substituted key file is refused at this step.
   3. The section, by hand this once: `printf 'SigLevel = Required\nServer = <base>/stable/$arch\n' | sudo tee
      /etc/pacman.d/grassfield.conf`, then `printf '\n[grassfield]\nInclude = /etc/pacman.d/grassfield.conf\n' | sudo tee -a
      /etc/pacman.conf`.
   4. `omarchy update` (which syncs `[grassfield]`), then `sudo pacman -S grassfield-desktop grassfield-compositor
      grassfield-icons`. These come from the repository, so every signature is required and checked against the key of step 2
      (P5, P8): an unsigned or foreign package is refused and nothing is installed.
   5. `grassfield-channel-set stable`. It rewrites the hand-written file from the packaged template (with the mirrors),
      populates the installed keyring (b.3), and links the Omarchy hook (a.4). Until then, an Omarchy channel change would
      drop the section.
   The same five steps, with the fingerprint pinned in the script and the preconditions checked first, are automated by the
   public installation script (ADR-0043, Proposed; not published until O8 and O11).
   The owner's own `makepkg -si` build trusts the owner's own checkout and needs `grassfield-keyring` installed first (O12).
4. **Rotation, with an overlap.** A new key K2 is added to `grassfield-keyring`'s trusted list while K1 still signs. CI starts
   signing with K2 only after that keyring has been in both channels for at least 30 days and one release. K1 stays trusted
   for 30 more days, and only then goes to `grassfield-revoked`. Throughout, any database or package signed by K1 or K2
   verifies, so no client is ever left with a database it cannot check. The key that signs the current database is never
   revoked: that stops every client's update (P13 with Q1).
5. **Revocation and compromise** (P13): a keyring that lists a key in `grassfield-revoked` disables it ("Disabled 1 key").
   After that, a database signed by it is refused ("key … is disabled", "database 'grassfield' is not valid"). With one key
   (O6), a compromise proceeds as follows:
   - the revoking keyring, signed by that key, still installs, and then every client's `[grassfield]` stops;
   - every system update therefore fails (a2) until the user turns Grassfield updates off ("Turn Off…") or trusts a new key
     through b.3a. The owner publishes the incident with those steps, and tells users to come back through b.3a only,
     never through "Set Up…": a user who turned updates off before receiving the revoking keyring would otherwise trust
     the compromised pinned key again (b.3 bootstrap plus populate).
   The owner accepted this rather than a second, offline key trusted from day one.
6. **What the key can do.** A locally signed key is trusted for **every** repository; pacman does not scope keys (Q6: a
   package of another repository, signed by the Grassfield key under `SigLevel = Required`, installs). Packages also run their
   install scripts as root, and `omarchy update` runs `pacman --noconfirm`, which accepts package replacements. The channel
   holds only packages named `grassfield-*`, none with `replaces=`; grassfield-packages' CI refuses anything else.
7. **Where the key lives (O6, one key in CI).** It is a secret (`GRASSFIELD_SIGNING_KEY`, plus
   `GRASSFIELD_SIGNING_PASSPHRASE` if it has one) of a protected GitHub environment of grassfield-packages:
   - only the signing and publishing jobs use it, never on a `pull_request`;
   - the owner approves each run;
   - builds and tests sign with throwaway keys, and every CI build artifact carries the keyless `grassfield-keyring` (U23)
     until O11.
   The owner creates the environment and the secret after M5.
8. **The key leaves with Grassfield.** Grassfield takes back the trust it gave:
   - the helper's `off` deletes from pacman's keyring every key of `grassfield-trusted` and the pinned key (`pacman-key
     --delete`), after removing the section; `off` and the scriptlet's `remove` skip `pacman-key --delete` for an empty
     fingerprint (an empty pin in `repository.conf`, or an empty `grassfield-trusted` list, as with the keyless keyring of
     U23). Since the keyring lives in its private folder (b.2), a later plain `pacman-key --populate` does not trust them
     again (R2);
   - `grassfield-keyring`'s `pre_remove` deletes the keys of its own trusted list. omarchy-keyring has no such step; Grassfield
     adds one;
   - `grassfield-desktop`'s `pre_remove` runs `off`, so `pacman -Rns grassfield-desktop …` leaves no `[grassfield]` and no
     trusted Grassfield key.
   Q6: after `pacman-key --delete`, a package signed by that key is refused in any repository ("key … is unknown"). After
   `pacman -R` of a package whose `pre_remove` deletes it, the key is absent from pacman's keyring.

9. **Renewing the key's expiry (security review of 2026-11-04).** The key made by `docs/owner-setup/make-signing-key.sh` is
   an Ed25519 sign-only primary key with no subkey and **expires after 2 years**. After that date pacman rejects the key's
   signatures: every client's `[grassfield]` sync fails (a2), and an extended key cannot reach a client through a keyring that
   is itself signed by the expired key. So the expiry is a deadline, with a margin:
   - **Procedure.** The owner runs `docs/owner-setup/renew-signing-key.sh --secret <offline copy> --fingerprint <pinned>`:
     a throwaway GNUPGHOME on tmpfs (same safety as the creation script: never `~/.gnupg`, passphrase never on a command line,
     cleanup on every exit but SIGKILL), `--quick-set-expire` on **the same primary key**, so the fingerprint, the pin in
     `repository.conf` and `grassfield-trusted` do not change. It proves its output (a signature made from a fresh home that
     holds only the new SECRET file, checked with gpgv against the new public key alone) and writes the extended public key,
     the new SECRET file, `expiry.txt` and a README with the dates. The revocation certificate is not remade: it stays valid.
   - **Margin.** The integrator puts the extended public key in `grassfield-keyring` (and
     `packaging/pacman/grassfield-signing-key.asc`) and publishes it in both channels **at least 6 months before the expiry
     date**. That is far above b.4's minimum for a new key (30 days in both channels and one release) because most machines
     update rarely, and a machine that misses the deadline can no longer update at all. The owner replaces
     `GRASSFIELD_SIGNING_KEY` in `publish-stable` and `publish-beta` and the two offline copies at the same time (gpg
     refuses to sign with an expired key, so CI needs the extended secret key before the expiry date too).
   - **A client that missed it** proceeds as in b.5's compromise case: "Turn Off…", then b.3a with the extended key.
   - **Reminder (proposal; not built here, grassfield-packages is not touched).** A scheduled workflow in grassfield-packages
     (weekly) reads the expiry date of the key in its `keyring/` (`gpg --with-colons --show-keys`) and of the last published
     database's signing key, and **fails the run when either expires within 9 months** (a failed scheduled run emails the
     owner; it can also open or refresh one issue). 9 months leaves three months to renew before the 6-month shipping
     deadline. The creation and renewal scripts print the expiry date, the shipping deadline and the date from which the
     reminder is expected.
   - NOT VERIFIED: that `pacman-key --populate-from` of the extended public key updates the expiry of a key already in
     pacman's keyring (gpg merges the new self-signature on import). To be tested in the container before the first renewal;
     if it does not, the keyring's scriptlet must delete and re-add the key.

### c. Changing the channel: a helper behind Grassfield's own polkit action (owner decision O1)
Writing `/etc/pacman.d/*` and `/etc/pacman.conf` needs root, and no system service owns these files, so there is no service
polkit action to call (ADR-0030's route). The owner chose a Grassfield helper behind its own polkit action (option B). The
other option was Omarchy's model, sudo in its floating terminal (A). The pieces:
1. **`/usr/lib/grassfield/grassfield-channel-helper`** and **`/usr/lib/grassfield/grassfield-channel-scriptlet`** are the only
   Grassfield code that runs as root. They are two entry points over one shared library,
   `/usr/lib/grassfield/grassfield-channel.sh`. **They need an opus security review before merge.**
   - Its interface is its argument vector, nothing else.
   - pkexec gives it a clean environment; both set their own `PATH` and `umask 022` and read **no environment variable**.
   - It refuses to run unless its effective uid is 0.
   - It writes to `/etc` only from root-owned packaged files: `/usr/share/grassfield/pacman/grassfield-<channel>.conf`,
     generated at build time from `repository.conf`. Each write goes through a temporary file in the same folder and a rename,
     keeping the mode, so pacman never sees a file missing (P2).
   - It installs no package, uses no network and writes nothing in a user's home. The only variable input is the channel
     name, checked against the two names.

   `grassfield-channel-helper`, the polkit action's only program, knows only these verbs, all refused while pacman's
   `/var/lib/pacman/db.lck` exists:
   - `set stable|beta`:
     1. the trust bootstrap of b.3 when the pinned key is not trusted;
     2. `pacman-key --populate-from … --populate grassfield` (b.3);
     3. the file from the template;
     4. the two lines in `pacman.conf` when missing;
     5. delete pacman's synced `[grassfield]` files (`/var/lib/pacman/sync/grassfield.{db,files}{,.sig}`, below).
   - `restore` ("Repair…" in the `repair` state): the two lines, only when the file exists.
   - `off` ("Turn Off…"): the two lines, then the file, then the synced files, then the keys (b.8).

   `grassfield-channel-scriptlet`, called only by `grassfield-desktop`'s install script (pacman holds `db.lck`, so it does not
   check it), knows only:
   - `remove` (`pre_remove`): what `off` does;
   - `upgrade` (`post_upgrade`): the host migration of h.3.
   It is not the polkit action's program. Through pkexec it falls under polkit's generic `org.freedesktop.policykit.exec`
   (an administrator's password, not kept), the same as running any program as root, so it adds no privilege. Unlike the
   first version of this section, nothing depends on `PKEXEC_UID`. A `pkexec pacman -R grassfield-desktop`, whose scriptlets
   inherit that variable, therefore still removes the section and the keys.

   Editing `pacman.conf` inside a transaction affects only the next run (Q6).
2. **The polkit action** `org.grassfield.packages.set-channel`, in `/usr/share/polkit-1/actions/org.grassfield.packages.policy`:
   - `allow_any` and `allow_inactive` are `no`, `allow_active` is `auth_admin_keep`;
   - `org.freedesktop.policykit.exec.path` is the helper;
   - the message, in English and French: "Authentication is required to change where Grassfield gets its updates" (« Une
     authentification est nécessaire pour changer la source des mises à jour de Grassfield »).
   - Amended 2026-11-08 (ADR-0041 step 2a, after the opus review): the swap of grassfield-hold and grassfield-unhold is a package
     transaction, so it is NOT this action (a kept password, "no other privilege is added") but its own,
     `org.grassfield.packages.hold`: program `/usr/lib/grassfield/grassfield-hold-helper` (verbs `hold` and `unhold` only;
     pkexec maps a program path to one action, so the helper runs under that action and no other), `allow_any` and
     `allow_inactive` `no`, `allow_active` `auth_admin` (a password every time, as for Update Now, SU-M1). Its message says what
     it does: "Authentication is required to let system updates install versions Grassfield has not tested, or to hold them
     back again". The channel helper has no hold verb.
   The dialog is Grassfield's polkit sheet in a Grassfield session (SEC6), Omarchy's agent in an Omarchy session, and pkexec
   itself on a text console.
3. **`grassfield-channel-set [stable|beta|off|repair]`**, in `/usr/bin`, is the user's command; it refuses to run as root.
   - It runs `pkexec <helper> <verb>`, then, as the user, links the hook (or, for `off`, removes the link).
   - `repair` runs `restore` in the `repair` state. In the `custom` state, `restore` would not touch the file, so `repair`
     runs `set <channel>` instead, rewriting it from the template. The channel is the one the file's Server names when its
     path ends in `/stable/$arch` or `/beta/$arch`; otherwise it is `stable`.
   - Without an argument it prints the channel.
   - Settings' "Beta Updates", "Set Up…", "Repair…" and "Turn Off…" run it as a child process, with no terminal, following
     ADR-0030's pattern: a worker; the argument checked in QML and in C++; "Waiting for permission…" while the dialog is up;
     one action at a time; up to 120 s; a refusal or a cancel shown on one line.

The persistence hook (a.4) keeps `sudo tee -a`. It runs inside `omarchy-refresh-pacman`, whose sudo cache is warm, so it adds
no prompt; a pkexec dialog there would interrupt Omarchy's channel change.

**Why `set` drops the synced database.** After a Server change, pacman kept the other channel's newer database and fetched
the new channel's signature, so every `[grassfield]` operation failed (P7: "signature … is invalid"). After the drop, `-Syu`
works and does not downgrade (P7).

**O2: switch only.** Switching installs nothing. Leaving the beta keeps the installed version (P7: "local (1.1.0beta1-1) is
newer than grassfield (1.0.1-1)"). The pane watches `/etc/pacman.d/grassfield.conf`, checks again, and offers the beta with
"Update Now", as macOS does.

Rejected:
- option A, by the owner;
- `pkexec` on `install`, `sed` and `rm` themselves, since a policy for generic programs authorises any argument.

### d. Checking for updates
1. **`grassfield-update-check`** (Python 3, standard library only; `/usr/lib/grassfield/`) is a one-shot child of
   grassfield-shell; there is no daemon (§5.8).
   - It runs as a Quickshell `Process`, asynchronously, so the UI never waits. Its output is capped at 256 KiB, one JSON
     object (`version: 1`).
   - **One at a time:** it holds `flock -n` on `$XDG_CACHE_HOME/grassfield/checkup.lock`, and a second run answers `busy`.
     Because only one checker can run, a `db.lck` left in its own database folder is stale by definition and is removed
     before `checkupdates` runs (Q8: a leftover `db.lck` gives "Cannot fetch updates"; removed, exit 2).
   - It is stopped after 180 s: SIGTERM first, so checkupdates' trap clears its lock, then SIGKILL 5 s later.
   - Every child runs with stdin from `/dev/null`. Q8 saw no hang either way, since the user cannot import a key ("keyring is
     not writable"), but nothing reads a terminal.
2. It never runs as root and never touches pacman's databases (P6, P9). `checkupdates` gets its own folder,
   `CHECKUPDATES_DB=$XDG_CACHE_HOME/grassfield/checkup-db`. Omarchy's checker uses the default `/tmp/checkup-db-$UID`, so the
   two never lock each other out. The checker drops its own `[grassfield]` files when the Server changes (P7).
3. **Steps:**
   1. `pacman-conf --repo-list` → `not-set-up` or `repair` (`not-set-up` still runs steps 4 and 5 without `[grassfield]`:
      "Step 2 as built").
   2. `pacman-conf --repo grassfield Server` → the channel (P6: the Server comes back with `$arch` expanded).
   3. The `[grassfield]`-only sync of a2 → `blocking`.
   4. `checkupdates --nocolor`: exit 0 updates, 2 none, 1 failure (P9).
   5. Split the result:
      - `[grassfield]` packages: the names that `pacman --dbpath <own db> -Sql grassfield` lists;
      - Omarchy: the `omarchy` or `omarchy-dev` line;
      - the rest: a count (`others`).
      Step 2 adds the list beside the count (`otherPackages`: name, installed and available version, sorted by name), which
      the pane and the Store (PR #15, ADR-0037) need. When the output would pass its 256 KiB cap, that list is cut first
      (truncated, `otherPackagesTruncated: true`), then the notes (`notesError`); the counts always stay.
4. **What counts as an update (O3)** for the badge, the menu and the notification: a Grassfield release (a new
   `grassfield-desktop` version, pkgrel included) and an Omarchy release.
5. **When.**
   - Automatic checks (`updates.automaticCheck`, default on): 10 minutes after login, then every 6 hours, skipped while
     offline or on a metered connection.
   - The pane checks when it opens and on "Check Now".
   - **During `omarchy update`:** a check that finds the lock held does not run. It hands over to a waiter, which checks once
     the lock is released. This applies to the shim's `omarchy.system-update refresh|clear`, which `omarchy-update-status`
     sends from inside the update while the lock is still held.
     - The waiter opens the lock file and blocks on `flock -x -w 7200`; once it gets the lock it releases it at once, then
       checks (Q8: while `omarchy-update-lock run sleep 3` holds it, the waiter returns 0 when it is released).
     - The quick test before a check is `flock -n`, released at once.
     - For the microseconds either one holds the lock, an `omarchy update` started at that very instant would report
       "already running". This is accepted.
     - A lock-free watch through `/proc/locks` is not relied on: in the test container, `/proc/locks` and `lslocks` showed
       nothing while the lock was held (Q8).
     - The waiter never inherits Omarchy's lock descriptor, since a child holding it would keep the lock: the shim starts
       nothing itself; it only sends the request to the shell.
     The pane says "Update in progress" meanwhile.
   - A check downloads databases and notes only, never packages.
6. **Failure kinds:** `offline`, `unavailable` (a check failed and the cause is not known), and `blocking` (a2, with "Turn
   Off…"). The previous successful result is kept with its time. Nothing crashes, and nothing retries in a loop.
7. **Where the result lives.** The shell is the only checker. It writes `$XDG_STATE_HOME/grassfield/software-update.json`
   (state class, `version: 1`, ADR-0020). Settings reads it and asks the shell to check over IPC; with no shell, Settings runs
   the checker itself.
8. **Release notes.**
   - Source: `grassfield-notes.json` and its `.sig`, in the channel's snapshot.
   - Fetched only for an available Grassfield release, with curl (`--proto =https`, plus `file` in tests; `--max-filesize
     65536`; `--max-time 15`).
   - Verified with `gpgv --keyring /usr/share/grassfield/pacman-keyring/grassfield.gpg --status-fd 1` (the keyring's private
     folder, b.2). The signer is VALIDSIG's
     **argument 10, the primary key's fingerprint**; argument 1 is the subkey that signed (Q7). That primary must be listed in
     `grassfield-trusted` and absent from `grassfield-revoked`. P12: good → exit 0; rogue → exit 2; changed text → exit 1.
   - Invalid or missing notes are not shown; the update is still offered.
   - Display: plain text, no link opened, control characters removed except line feeds, at most 8000 characters per release.

### e. Versions
- `VERSION` is `X.Y.Z`, `X.Y.Z-betaN` or `X.Y.Z-rcN`. pkgver is `VERSION` without the hyphen. P1 (vercmp):
  - `1.0.0rc1 < 1.0.0 < 1.0.1 < 1.1.0beta1 < 1.1.0beta2 < 1.1.0rc1 < 1.1.0`;
  - `1.1.0beta9 < 1.1.0beta10`;
  - `1.1.0beta1-1 > 1.0.1-1`.
  A dot before the suffix is refused: `1.1.0.beta1` sorts after `1.1.0` (`vercmp` = 1).
- A suffixed version goes to beta only (O15). A plain one goes to stable, and to beta when it is newer
  (`repo-add --prevent-downgrade`, P4).
- pkgrel (O7): the PKGBUILD reads `GRASSFIELD_PKGREL` (`^[1-9][0-9]*$`) when it is set and keeps its committed pkgrel
  otherwise.

### f. The compositor plugin and Omarchy's Hyprland
- The build container has an **Omarchy stable machine's package set** (P0): Hyprland, but also Qt and KF6, at the versions
  users run. The build records `pacman -Q` and the plugin's ABI stamp with the artifact.
- When Omarchy moves Hyprland first, ADR-0009's degraded mode and its notice apply. A scheduled watch job compares
  `stable-mirror`'s and `rc-mirror`'s Hyprland ABI with the channel's stamp and builds pkgrel + 1 for the owner to publish.
  The watch job stays disabled while nothing is published.

### g. The contract between the two repositories
| Item | Value |
|---|---|
| Base URLs | `packaging/pacman/repository.conf` in this repository: `GRASSFIELD_REPO_BASE` (the primary; `https://packages.grassfield.site`, owner decisions O8, O8b of 2026-11-03), `GRASSFIELD_REPO_MIRRORS` (more bases serving the same snapshots, each a `Server` line after the primary), `GRASSFIELD_REPO_BASE_PREVIOUS` (bases a migration rewrites, h). grassfield-packages reads them from the checkout it builds. |
| Channel URL | `<base>/<channel>/<arch>/`, channel `stable` or `beta`, arch `x86_64`; `Server = <base>/<channel>/$arch` |
| Repository | `grassfield`: `grassfield.db`, `grassfield.files`, each with `.sig`; real files, not repo-add's links |
| Packages | exactly the files the database names, each with `.sig`: `grassfield-desktop`, `grassfield-compositor`, `grassfield-icons` (this PKGBUILD) and `grassfield-keyring` (grassfield-packages). Names `grassfield-*` only, no `replaces=`. Package file names never change content. `grassfield-desktop` depends on `grassfield-keyring` (O22): grassfield-packages refuses a release whose `grassfield-desktop` does not (its build, from the package's `.PKGINFO`, and its tree check, from the database). |
| Signatures | detached, binary; packages, both databases and the notes; by a key in `grassfield-trusted` or its signing subkey |
| Release notes | `grassfield-notes.json` and `.sig`, UTF-8, at most 64 KiB: `{"version":1,"channel":"stable","releases":[{"version":"1.0.1-1","date":"2026-11-02","notes":{"en":"…","fr":"…"}}]}`. Newest first, at most 20, `en` required, plain text, at most 8000 characters each. |
| Notes source | `packaging/release-notes/<VERSION>.{en,fr}.txt` in this repository at the tag (O9). A pkgrel rebuild gets "Rebuilt for Hyprland X.Y.Z" / « Reconstruit pour Hyprland X.Y.Z ». |
| Publication | atomic (h): one serialized publisher per channel builds an immutable snapshot from the current one, then writes the pointer only if it has not moved (h.2 as amended by ADR-0037) |
| Store catalog | `grassfield-catalog.v1.json`, its `.sig` and `catalog/<sha256>.png` in each channel's snapshot, signed with the repository's key; format, rules and checks in ADR-0037 g (amendment) |
| Trust anchor | the pinned fingerprint and key (b.3) are in `grassfield-keyring`'s trusted list; CI checks it |
| Build input | a tag (or, for tests, a commit) of grassfield; `VERSION` decides the channel; `makepkg` of `packaging/arch/PKGBUILD` with `GRASSFIELD_PKGREL` |
| Source access | a read-only deploy key on grassfield (O13), secret `GRASSFIELD_DEPLOY_KEY`. Until it exists, the build is tested in a container with both checkouts. |
| Triggers | a poll of grassfield's tags every 15 minutes (O14; GitHub may start scheduled runs late), only when the deploy key exists. A tag is built once. `workflow_dispatch` with a `ref` stays for manual runs. Publishing is written and disabled. |
| From the owner, later | `GRASSFIELD_DEPLOY_KEY`; `GRASSFIELD_SIGNING_KEY` and its passphrase (b.7); `GRASSFIELD_S3_ACCESS_KEY_ID` and `GRASSFIELD_S3_SECRET_ACCESS_KEY` (write to the bucket only); the bucket name and S3 endpoint (variables); the public key, its fingerprint and the host name (this repository). None is created by the agent. |

### h. Hosting: own domain on S3-compatible storage behind a CDN (O8; activated after the legal review)
1. **The tree.** A bucket of S3-compatible storage (Cloudflare R2, AWS S3 or an equivalent) behind a CDN and a host name of
   the owner's, decided later. The publishing job runs only when the built tag's primary base is not the `.invalid`
   placeholder and the credentials exist.
2. **Atomic publication.** The fixed names of a channel are not objects: `grassfield.db`, `grassfield.files`, the notes and
   their signatures. The CDN's edge rule answers them with a redirect (302, not cached) to
   `<channel>/<arch>/snap/<id>/<name>`, where `<id>` comes from one pointer object (not cached). A publication runs in order:
   1. upload the packages, which have immutable names;
   2. upload a complete new snapshot;
   3. write the pointer, once.
   Snapshots are kept for 7 days. Q2: pacman followed the redirects for the database and its signature (`302`, then `200` from
   `/snap/A/`); one pointer write switched both to `/snap/B/`, and `-Syu` installed 1.0.1.
   **Rolling back is a new snapshot, never the pointer moved back.**
   - R4: with a client on B (1.0.1 installed), pointing back to the older A failed: its database answered `304`, since the
     client's copy is newer, while A's signature came as `200`, so "signature … is invalid", which is P7 over HTTP, for
     every client already on B.
   - A new snapshot C, built now with A's packages, worked: `200` for both, `-Sy` exit 0, and `-Syu` "local (1.0.1-1) is
     newer than grassfield (1.0.0-1)", no downgrade.
   **Amended by ADR-0037 (2026-10-27): one serialized publisher, built from the current snapshot, a conditional pointer
   write.** Releases and Grassfield Store's catalog updates share each channel's pointer, so a job built from an older
   snapshot and published later would move the pointer back (R4 above, then a2: every `omarchy update` fails). Per channel:
   one publishing job, serialized (one run at a time, never cancelled half way); since GitHub cancels a pending run when a
   newer one queues and each tag is built once, a run takes nothing from its trigger and publishes the latest state: the
   newest release built and signed for the channel and the catalog of `main`'s head (a cancelled pending run loses nothing);
   it reads the pointer and builds the new snapshot from the current snapshot's manifest (the newest release's packages,
   databases and notes when newer than the snapshot's, the catalog when it differs, the rest kept); it refuses a `grassfield.db` older than the current one
   for any package, except a deliberate rollback below; it writes the pointer only if it still names the snapshot it read
   (a compare-and-swap on the storage's version tag), else it starts again. A conditional write on the chosen storage is NOT
   VERIFIED (the host is chosen, R2, but nothing is published to test it on; h.5); without one, the serialization alone holds, with a fresh read of the pointer just
   before the write. Details: ADR-0037 g.
   So the previous release is published again as a new snapshot (a pkgrel above the bad one when clients must move to it). Residual: a client whose two
   requests straddle the pointer write gets a mismatched pair once; that run fails ("signature … is invalid"), the next one
   works. The window is the time between pacman's two requests. Mirrors serve the same snapshots and pointer.
3. **Changing hosts (O19), the migration path.** "One value" was wrong for installed machines: their `grassfield.conf` keeps
   the old Server until it is rewritten, and would drift to `custom`. So a change of host proceeds as follows:
   1. The release that carries the new `GRASSFIELD_REPO_BASE` lists the old base in `GRASSFIELD_REPO_BASE_PREVIOUS`, and is
      published on both hosts.
   2. `grassfield-desktop`'s `post_upgrade` runs `grassfield-channel-scriptlet upgrade`. When the file's primary Server is
      `<previous base>/<channel>/$arch` for `stable` or `beta`, it rewrites the file from the current template for that
      channel and drops the synced files. Any other content is left alone, and the pane shows `custom` with "Repair…", which
      rewrites the file from the template (c.3).
   3. The old host keeps serving, then redirects (301) to the new one, for at least 90 days. After that, the old base can
      leave `GRASSFIELD_REPO_BASE_PREVIOUS`.
   GitHub Releases (not chosen) would change the Server's shape too (`…/download/<channel>-$arch`). A shape change needs the
   same migration.
4. Considered and not chosen: GitHub Pages (a public repository and a 1 GB site), GitHub Releases, GitLab.
5. **Concrete layout on Cloudflare R2 (owner decisions O8, O8b, 2026-11-03; amendment).** Nothing is created or published
   by this record; the owner's steps are in the maintainers' private hosting notes. What is NOT VERIFIED is marked.
   - **Bucket** `grassfield` (created by the owner on 2026-11-03: location WEUR, Standard class, empty). Its **custom domain** is
     `packages.grassfield.site` (the zone `grassfield.site` was already on Cloudflare DNS, in the same account as R2: no nameserver move. The owner connected it on 2026-11-03 with wrangler's `r2 bucket domain add` (minimum TLS 1.2); ownership and SSL were still pending minutes later; the certificate is Cloudflare's. Agents change no DNS, domain or certificate). The public
     `r2.dev` address stays disabled, so the only public name is the one in `repository.conf`.
   - **Paths**, at the bucket's root, exactly as grassfield-packages writes its tree: `<channel>/x86_64/...` with channel
     `stable` or `beta` (so `Server = https://packages.grassfield.site/<channel>/$arch`):
     `<package>.pkg.tar.zst` and `.sig` (immutable), `snap/<id>/...` (immutable snapshots), `pointer` (`{"snapshot": "<id>"}`)
     and `catalog/<sha256>.png`. `releases/<channel>/` and `withdrawn/<channel>/` are the publisher's inputs in the same
     bucket; they hold no secret (packages and signatures already public), but nothing links to them.
   - **OPEN DESIGN ITEM: how the fixed names resolve the pointer (h.2's edge rule).** Cloudflare's Redirect Rules cannot read
     the pointer's content, so h.2's "edge rule" needs one of these. Nothing is built now: it is not needed before the first
     publish, which waits for the legal review. Options:
     (a) **A Cloudflare Worker on the custom domain** (free tier: 100,000 requests a day, enough to start) reproducing
         grassfield-packages' `scripts/serve.py`: for the fixed names (`grassfield.db`, `grassfield.files`,
         `grassfield-notes.json`, `grassfield-catalog.v1.json`, each with `.sig`) it reads `<channel>/x86_64/pointer` through an
         R2 binding (no key) and answers `302` to `snap/<id>/<name>`, `Cache-Control: no-store`; a missing or malformed
         pointer gives `404`; every other path goes to the bucket. Keeps h.2 as tested (Q2, R4: one pointer write switches
         the database and its signature together). Costs one new component (JavaScript, about 40 lines), the owner's approval
         and, above the free tier, a paid plan.
     (b) **The publisher copies the snapshot's database and signature to the fixed names** (real objects), in the least
         harmful order (the `.db` first, then its `.sig`). No order is safe for a client that reads the two files separately:
         whichever is written first leaves a window in which a client gets a new file next to an old one ("signature ... is invalid", the
         once-failed run of h.2's residual). Consistency window: the time between the two writes (about a second) plus any
         cache lifetime; it can be shortened, never removed. No new component.
     (c) **A pacman-side fix**: none exists. pacman fetches `<name>.db` and `<name>.db.sig` as two independent requests, and
         `Server` has no indirection; a client-side workaround (a `CacheServer`, a hook) would add code as root's neighbour on
         every machine.
     **Recommendation: (a)**, because it is the only option that keeps h.2's atomic switch, and (b) only as a fallback if the
     owner refuses a Worker, with its window stated in the pane's "failed once, then fine" behaviour. NOT VERIFIED: that a
     Worker route in front of an R2 custom domain passes other requests to the bucket as assumed (to test on a scratch bucket
     before the first publish), and R2's conditional `PutObject` (`If-Match` / `If-None-Match`) for the pointer's
     compare-and-swap (below; without it, serialization alone holds).
   - **Cache rules** (Cloudflare Cache Rules on `packages.grassfield.site`), consistent with h.2's pointer and
     serialization: (1) the fixed names and `pointer` (path ends in `/pointer`, or in one of the names above): **Bypass
     cache**, so a pointer write is seen at once by both the database and its signature (a stale `.db` next to a fresh
     `.sig` is the R4 failure); (2) `/snap/`, `*.pkg.tar.zst`, `*.pkg.tar.zst.sig` and `/catalog/*.png`: **eligible, Edge
     TTL and Browser TTL one year** (immutable names; a snapshot's files never change, and a snapshot deleted after 7 days
     only leaves a copy nobody is pointed to). **Rule (2) carries a status-code TTL**, because an overriding Edge TTL would
     otherwise cache errors for a year: `404` (and every other 4xx and 5xx) is **not cached** (`status_code_ttl` with value
     -1, "no store"). Without it, a file requested a moment before its upload would stay "not found" at the edge for a
     year. The exact `status_code_ttl` value for "do not cache" is to be confirmed in the dashboard (NOT VERIFIED here).
     The publisher also sets the headers on upload, so the rule is not the only
     line: `Cache-Control: no-store` on `pointer`, `public, max-age=31536000, immutable` on packages, signatures,
     snapshot files and catalog images. Keep Always Online and Cache Reserve off, and no Cloudflare feature that rewrites
     bodies (Rocket Loader, minify, Polish) for this host.
   - **Credentials.** An **R2 API token scoped to the bucket `grassfield` only**, permission *Object Read & Write*, no other bucket, no
     account permission; its Access Key ID and Secret Access Key become `GRASSFIELD_S3_ACCESS_KEY_ID` and
     `GRASSFIELD_S3_SECRET_ACCESS_KEY` in the protected environments `publish-stable` and `publish-beta` of
     grassfield-packages (the names its workflows read); the variables `GRASSFIELD_S3_BUCKET` (`grassfield`) and
     `GRASSFIELD_S3_ENDPOINT` (`https://<account id>.r2.cloudflarestorage.com`) are not secrets; the integrator set both in
     both environments. The token lives only there,
     never on a `pull_request`. NOT VERIFIED: R2's S3 API honouring `If-Match` / `If-None-Match` on `PutObject` for h.2's
     compare-and-swap of the pointer (to test on a scratch bucket); without it, h.2's serialization alone holds.
   - **b.7's approval gap, resolved on 2026-11-03.** GitHub had refused the required-reviewers rule (HTTP 422):
     `grassfieldhq` is on the Free plan and `grassfield-packages` was private. Options were (a) make it public (free
     reviewers; the packages are public anyway), (b) GitHub Team (paid), (c) a weaker gate (`workflow_dispatch` only plus
     branch protection). **The owner chose (a)**: a gitleaks scan of the full history (93 commits) found 3 false positives,
     all Omarchy's public packaging-key fingerprint, then the owner made the repository public. The integrator then set, on
     both environments `publish-stable` and `publish-beta`, the owner as required reviewer and a deployment branch policy
     for `main` only; and on `main` branch protection with no force-push and no deletion (no required reviews). So b.7's
     "the owner approves each run" holds. Secrets are still set by the owner only, in their own terminal.
   - **What gates publication now.** The base is no longer the `.invalid` placeholder (h.1's first condition), so the gate is
     what grassfield-packages already has: `publish.yml` and the release job stay `if: false` until the owner, after the
     legal review, creates the two environments, sets the secrets and removes it. The shipped client with this base and no
     key: Set Up refused, the checker never fetches (`not-set-up`), and Grassfield Store requests nothing either: its
     `buildChannel` (`apps/store/src/channel.cpp`) takes the build's base only when `GRASSFIELD_SIGNING_FINGERPRINT` is
     non-empty, the same condition as the others, so no installed Store contacts the host for a catalog it cannot verify.

### i. After an update
- Logging out is needed and enough for a Grassfield update: Hyprland keeps the loaded plugin, and the shell and the plugin
  must stay the same version (ADR-0007). The pane shows "Log out to finish updating Grassfield" with "Log Out…". GF-083's
  notice stays the one banner.
- Omarchy's reboot marker (`~/.local/state/omarchy/reboot-required`) and the running kernel's modules folder are read, never
  written. When they say so, the pane offers "Restart…" instead.

### Dev sessions (ADR-0019)
The checker runs in a dev session read-only, with its cache under the dev state. "Update Now", "Set Up…", "Repair…", "Turn
Off…" and the beta switch never run there. Dev plumbing: `GRASSFIELD_UPDATE_FIXTURE`, `GRASSFIELD_UPDATE_CHECK_CMD`,
`GRASSFIELD_UPDATE_PKEXEC` (`GRASSFIELD_UPDATE_LAUNCHER` was dropped in step 2: "Step 2 as built").

## Owner decisions (2026-10-27; O1-O16 confirmed again after the first review)
| Id | Question | Options | Answer |
|---|---|---|---|
| O1 | Channel change (c) | A: `grassfield-channel-set` in Omarchy's terminal with sudo (recommended) · B: a pkexec helper behind Grassfield's own polkit action | **B** |
| O2 | After switching to beta | switch only, the pane offers the beta (recommended) · switch then `omarchy-update -y` (Omarchy's model) | **switch only** |
| O3 | Badge, menu count, banner | Grassfield and Omarchy releases (recommended) · Grassfield only · every package | **Grassfield and Omarchy** |
| O4 | A link in `~/.config/omarchy/hooks/pre-refresh-pacman.d/` | yes, made by `grassfield-channel-set` (recommended) · no, detection and "Repair…" only | **yes** |
| O5 | Signed besides packages | database and notes (recommended) · packages only (Omarchy's level) · database only | **database and notes** |
| O6 | Keys | offline master + CI signing subkey + a second offline key (recommended) · the owner signs each channel by hand · one key in CI | **one key in CI** (b.5, b.7) |
| O7 | pkgrel of a rebuild | `GRASSFIELD_PKGREL` read by the PKGBUILD (recommended) · a commit and tag per rebuild | **`GRASSFIELD_PKGREL`** |
| O8 | Hosting, after the legal review | GitHub Pages (recommended) · GitHub Releases · own domain · decide after M5 | **own domain** |
| O8b | Own domain: storage | S3-compatible storage + CDN (recommended) · own server (rsync/SSH) · after M5 | **S3 + CDN**; host name later |
| O9 | Release notes source | `packaging/release-notes/<VERSION>.{en,fr}.txt` (recommended) · CHANGELOG.md sections · written at publication | **the text files** |
| O10 | master-prompt §4/M6 | build and contract now, publication after M5 (recommended) · wait for M6 | **now, unpublished** |
| O11 | Public key and fingerprint | later (recommended) · now | **later** |
| O12 | `grassfield-desktop` depends on `grassfield-keyring` | always (recommended) · only in channel builds | **always** |
| O13 | CI access to grassfield | read-only deploy key (recommended) · fine-grained read token · none for now | **deploy key** |
| O14 | Build trigger | manual + `repository_dispatch` (recommended) · tag poll · manual only | **tag poll every 15 minutes**, plus manual runs |
| O15 | rc versions | beta channel (recommended) · not published | **beta** |
| O16 | After the opus PASS | watch the PR and open step 1 at once (recommended) · watch and wait for the owner · no watch | **at once** |
| O17 | Trust at the first installation (review 1, MAJOR 4) | out-of-band fingerprint only, the helper never adds trust (recommended) · verified files then `pacman -U` · keep the helper's bootstrap | **keep the bootstrap**; b.3a documented, residual risk accepted |
| O18 | A `[grassfield]` that blocks every update (review 1, MAJOR 1) | pane + notification offering "Turn Off…" (recommended) · pane only · automatic removal | **pane + notification**, never automatic |
| O19 | Change of host (review 1, MAJOR 5) | `post_upgrade` migration + old host serving and redirecting ≥ 90 days (recommended) · redirect only · manual "Repair…" | **migration + redirect** |
| O20 | Keyring before the owner's key exists (review 2, MAJOR) | a keyring with no key until O11 (recommended) · withhold the dependency until O11 | **no key until O11** (b.2) |
| O21 | `grassfield-keyring` dependency until grassfield-packages builds the package (step 1 review, minor 5) | hold it back; a follow-up adds it once grassfield-packages' step 1b is merged (recommended) · keep it, the owner builds the keyring once · a keyless keyring from this repository's PKGBUILD | **hold it back**; added once grassfield-packages PR #3 was merged (follow-up, O22) |
| O22 | O21's follow-up, `grassfield-keyring` in grassfield-desktop's `depends`: its install script then runs as root wherever grassfield-desktop is installed, the owner's machine included, and until `[grassfield]` is published a source build needs the keyring installed first (otherwise the install half of `makepkg -si`, its `pacman -U`, refuses grassfield-desktop) | add it now; a source build installs grassfield-packages' `keyring/` once with `makepkg -si` (keyless until O11: three empty files, it trusts nothing) (recommended) · hold it back until the repository is published (after M5) | **add it now** (« Accepter maintenant »); the owner builds the keyring once before the next `makepkg -si` (`docs/owner-setup/real-session.md` section 3) |
| SU-M1 | Update Now (2026-10-29, the integrator's question after the incident of 2026-10-29) | as on a Mac: Grassfield's password dialog, a snapshot, Omarchy's update without a terminal through a Grassfield root helper behind its own polkit action, progress in Settings, Restart at the end, a compatibility check before the transaction (recommended) · keep Omarchy's terminal | **as on a Mac** (« Comme sur Mac », confirmed by the owner in the Claude Code session of step 3); "Step 3" |
| SU-D4 | Telling the end of an Update Now run (step 4, delegated) | a notice for each end that leaves something to do or to know, whose click opens the pane, none for a restart or a log out while Settings' window is in front, whose end sheet asks it (recommended: macOS posts such a notification when its window is not in front) · a notice for a restart only · nothing outside the pane | **a notice for each end**, « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »; "Step 4 as built" |
| SU-M2 | Omarchy migrations that need `sudo` (2026-10-31, step 3's limit s3.8) | keep Omarchy's terminal for them (recommended by the session: no root widening) · Grassfield's own password window for each migration's `sudo` (a new password surface outside polkit) · one password: the password of Update Now also covers the migrations' `sudo` commands, run as root through Grassfield's helper (the widest root change; a dedicated design and an opus security review) | **one password** (« Mot de passe unique », the owner's answer to the question tool of the 2026-10-31 session); "Step 5" |
| O8 (2026-11-03) | Domain and host name for the own-domain hosting (O8), asked in the integrator session | the owner's own domain, packages served from a sub-domain | **grassfield.site**; the repository is served at **https://packages.grassfield.site** (`GRASSFIELD_REPO_BASE`); still activated only after the legal review |
| O8b (2026-11-03) | Storage and CDN behind that name (O8b) | S3-compatible storage + CDN | **Cloudflare R2** with Cloudflare's CDN, the host name as the bucket's custom domain; layout, cache rules and token in h.5 |
| O11 (2026-11-03) | Who creates the signing key, and when (O11 said "later") | an agent or CI generates it · the owner generates it on their own machine | **now, by the owner, on their machine**, with `docs/owner-setup/make-signing-key.sh` (a throwaway GNUPGHOME, never `~/.gnupg`; the passphrase typed by the owner). The integrator and agents never see the secret key; they receive only the public key and the fingerprint (the maintainers' private hosting notes). `GRASSFIELD_SIGNING_FINGERPRINT` stays empty until the owner sends it (b.3), so a build still refuses ("no signing key in this build") |
| O15b (2026-11-04) | What the first publication is, and which channel a prerelease build sets up on | 1.0.0-rc1 on both channels · 1.0.0-rc2 on beta, a prerelease build enrolls in beta (the macOS model) | **1.0.0-rc2, beta channel only (O15 unchanged), stable stays empty until after the legal review; a build whose VERSION has a -betaN or -rcN suffix sets Software Update up on `beta` (Settings "Set Up…" reads `/usr/share/grassfield/VERSION`), a plain version on `stable`; the public install script follows the same rule (ADR-0043 h)**. Reason: Set Up on rc2 pointing at an empty stable would fail its checks and block every Omarchy update (a2). **The rule, applied everywhere (security review of b8e96bc1):** an installed `/usr/share/grassfield/VERSION` that is a prerelease, or missing, empty, unreadable or malformed, can only follow beta (beta carries every release); a plain `X.Y.Z` can follow stable ("you can turn off beta updates once the release is installed"). Applied by Settings (Set Up, the Beta Updates picker's Off is disabled with a footnote), `grassfield-channel-set` (`stable` refused, repair falls back to beta), the root helper's `gf_set` (a direct call is no way round) and the Store's default channel. |
| O15c (2026-11-08) | Whether the legal review must come before the first stable publication (O15b kept stable empty until it) | keep · lift | **lift: 1.0.0 may be published on stable without the legal review, risk accepted by the owner; the release is the desktop alone (Grassfield OS later); announcing it still needs the owner** |

The owner gave every answer of O1-O22 on 2026-10-27: O1-O21 in this Claude Code session, through its question tool, and
O22 to the integrator. SU-M1 was asked by the integrator on 2026-10-29 and confirmed by the owner through the question tool
of the step 3 session, since it widens what runs as root. SU-M2 was asked in the Claude Code session of 2026-10-31 through the
question tool, with the three options and the root widening of each spelled out, and answered by the owner. SU-D4 was decided under
the owner's delegation of 2026-10-27 (it changes nothing that runs as root and no security rule). The answers to O1-O16 were recorded in `fd49abc` and confirmed again after the first review; O21 was asked
after the step 1 review. O22 was asked by the integrator on grassfield PR #24: it changes what runs as root on the owner's machine, which the owner's
delegation of 2026-10-27 leaves to the owner. Why now rather than at publication: a user of the repository installs
grassfield-desktop and gets the keyring with nothing to do, as omarchy depends on omarchy-keyring
(`docs/audits/software-update-2026-10-27/o21-dependency-probe.sh` step 5, output beside it); holding it back only moves
the change to the first published release, where a miss would ship a desktop without the keyring that carries its key
(b.2, b.3a); a keyless keyring built by this repository's PKGBUILD (O21's third option) would split the package's source,
since the channel's keyring must be grassfield-packages' `keyring/`, the whole package (its `keyring-check.sh`).

## Amendments
- **ADR-0050 (staged rollout), Proposed 2026-11-05.** a/c: `grassfield.conf` may hold the cohort form (20 cohort paths
  `<base>/<channel>/cohort/<NN>/$arch` before the plain lines), written only by `grassfield-channel-scriptlet upgrade` when
  the verified database lists the marker package `grassfield-rollout` 1, from a wariness root keeps in
  `/var/lib/grassfield/rollout-wariness`; `set` still writes the plain form. d: the checker reads the signed
  `grassfield-rollout.json` (pane only) and the automatic check also waits on battery at 30 % or less. g/h: the publisher's
  per-cohort paths, monotonic resolution, marker and descriptor (ADR-0050 g). Root code changed: the scriptlet and its
  library (opus security review).
- **The site gives the installation (owner decision of 2026-11-05).** Amends the activation entry below: the official
  site's Download page carries the install script, its requirements, the key's fingerprint and the script's checksum (ADR-0043 h
  amendment). The site stays noindex; the legal review stays mandatory before any public announcement.
- **Activation (owner decision of 2026-11-04), recorded 2026-11-04.** Amends h's "activated after the legal review": the
  repository is published at `https://packages.grassfield.site` now, **unannounced** (no link from the site, the site stays
  noindex), before the legal review, which stays mandatory before any public announcement. The owner's key
  (`E4921A382C349308BAA50D2F44C31B5D862EBEFA`, created 2026-11-04) is in `repository.conf` and
  `grassfield-signing-key.asc`: builds set Software Update up for real ("Set Up…" appears) and the Store fetches the catalog.
  The first release is a Grassfield tag (`v1.0.0-rc2`, beta channel only: e, O15, owner decision O15b of 2026-11-04, pkgrel 1);
  publishing still needs the owner's approval of each run in `publish-beta`. A prerelease build sets Software Update up on beta
  (`SoftwareUpdateLogic.defaultChannel`, from `/usr/share/grassfield/VERSION`), so Set Up never points at the empty stable. The same rule refuses `stable` in `grassfield-channel-set` and the root helper, disables "Off" in Beta Updates, makes Repair fall back to beta and the Store's unset default channel beta (`releaseChannelOf`); tests: `tests/shell/channel_set_rule.sh`, `tst_channel.cpp`, the Settings and Update logic unit tests.
- **Hosting and key (owner decisions O8, O8b, O11 of 2026-11-03), recorded 2026-11-03.** The host is
  `packages.grassfield.site` on Cloudflare R2 (h.5); `repository.conf` carries the base and no fingerprint; the owner makes the
  key with `docs/owner-setup/make-signing-key.sh`. Nothing is published.
- **ADR-0037 (Grassfield Store), 2026-10-27, Proposed with it.** d.3.5: the Store reads the list of other updates that
  step 2 adds (`otherPackages`, cut first at the 256 KiB cap), so it runs no second `checkupdates`. g: the Store catalog's files join the contract, and publication is the serialized
  publisher of h.2. h.2: one serialized publisher per channel that publishes the latest state, building from the current
  snapshot, never backwards, writing the pointer only if it has not moved. Context: "Grassfield has no root code
  to install anything" no longer holds for the Store's `grassfield-store-helper` (owner decision ST4: pkexec, its own polkit
  action, `pacman -S --needed` / `pacman -Rns` of validated repository names only, ADR-0037 b.1); Software Update itself
  still installs nothing.
- **SU-M1 (step 3), 2026-10-29.** Update Now installs through `grassfield-update-helper` behind the polkit action
  `org.grassfield.packages.update-system` instead of Omarchy's terminal ("Step 3"). d.5's waiter and i's restart rule stay; the
  pane's "Update Now" of step 2 remains as "Update in Terminal…" for an update that needs a person (s3.6). ADR-0030's root
  helpers gain this one.
- **SU-M2 (step 5), 2026-10-31.** A migration that needs root (it names `sudo`, or an Omarchy command that does) no longer
  sends the update to Omarchy's terminal by itself: the helper runs that update's migrations after the transaction as the
  person (an administrator), in `grassfield-update-migrate.service` under a group of its own, whose `sudo` gets each
  command a transient root unit, granted by polkit to that unit alone ("Step 5"). s3.6's rejected option is now the owner's decision; what needs a person (`gum`,
  `/dev/tty`, `pkexec`, `su`, `run0`, `doas`, a `sudo` by its path) still goes to the terminal. ADR-0030's amendment for
  step 3 gains the rule.

## Evidence
- `adr0033-probes.sh` (P0-P13), `adr0033-probes-2.sh` (Q0-Q8) and `adr0033-probes-3.sh` (R0-R5), in
  `docs/audits/software-update-2026-10-27/`. Their outputs are `probes-output.txt`, `probes-2-output.txt` and
  `probes-3-output.txt` (docker exit 0 each).
- Where and how they ran: in this cloud session's container (Ubuntu 24.04, root inside the session's sandbox), with the
  Docker 29.9.2 daemon started in the session. The command was `docker run --rm --network host` with the session's HTTPS proxy
  and CA bundle mounted read-only, on `archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0`.
  Mounted read-only, as data:
  - Omarchy v4.0.4 (c668141), for all three scripts;
  - Omarchy v4.0.6 (237f1b4), for the Q round; both cloned from github.com/basecamp/omarchy;
  - `omarchy-keyring-20251027-1` from pkgs.omarchy.org, for the Q round.
  Each script refuses to run outside a container. Inside it is root, makes a `builder` user for makepkg and an `alice` user
  with passwordless sudo (standing for Omarchy's warm sudo cache), and generates throwaway ed25519 keys that expire in a day.
  Everything goes with the container. pacman 7.1.0.r9.g54d9411-3, pacman-contrib 1.13.1-1, gnupg 2.4.9-3, all from
  Omarchy's stable mirror.
- One deviation from Omarchy's template: `DisableSandbox`. Docker refuses Landlock (R5: root pacman without it fails with
  "the Landlock ruleset could not be applied: Operation not permitted"); R5 then removes it and shows the user-side checks
  working with checkupdates' `--disable-sandbox-filesystem`.

## Consequences
- **Step 1, here:**
  - `grassfield-channel-set`; `grassfield-channel-helper` with its polkit policy; `grassfield-channel-scriptlet`; their
    shared `grassfield-channel.sh`; `grassfield-update-check`; the hook;
  - `packaging/pacman/` (repository.conf, the section templates);
  - the shim's `omarchy.system-update` forward;
  - `pre_remove` and `post_upgrade` in `grassfield-desktop.install`, calling `grassfield-channel-scriptlet`;
  - in `depends`: `grassfield-keyring`, `pacman-contrib` and `fakeroot` (`omarchy` depends on the last two as well;
    declared, not assumed);
  - `GRASSFIELD_PKGREL`, `updates.automaticCheck`, `software-update.json`;
  - a container test.
  The Omarchy files it relies on are pinned in `docs/upstream/omarchy.lock`, with the step 1 files as their derived files.
  `scripts/dev/upstream-drift.sh` requires derived files that exist, so the pins land with them. The files to pin:
  - `bin/omarchy-refresh-pacman`, `omarchy-hook`, `omarchy-update`, `omarchy-update-lock`, `omarchy-update-status`,
    `omarchy-update-available` and `omarchy-launch-floating-terminal-with-presentation`: identical in 4.0.4 and 4.0.6;
  - `default/pacman/pacman-stable.conf`: different in 4.0.6.
- **Step 1, in grassfield-packages:**
  - the snapshot build;
  - `grassfield-keyring`: private folder, `--populate-from`, `pre_remove`, and **no key until O11**;
  - the workflows, publishing disabled;
  - the end-to-end exercise, with throwaway keys made per run in its container.
- **Step 2:** the pane, badge, menu count and notification, including the `blocking` state and "Turn Off…".
- **ADR-0030 is amended** (its end): Settings' Software Update runs a root helper through pkexec, by owner decision O1,
  where ADR-0030 had none.
- **Privileged code** (helper, scriptlet program, shared library, policy, package scriptlets, the hook's `sudo tee -a`) is named in the step 1 PR and needs an opus
  security review before merge. The owner checks the real polkit dialog in the real session.
- **Known limits** (spec):
  - a `[grassfield]` that cannot sync stops every `omarchy update` until it is fixed or turned off (a2);
  - Omarchy's own channel change (`-Syyuu`) and `omarchy-reinstall-pkgs` (`-Suu`) move a Grassfield beta back to stable
    (P11);
  - an old but validly signed database can be replayed;
  - a pointer switch can fail one run; a rollback is a new snapshot (h.2);
  - a Hyprland update can come before the matching plugin.

## Step 1 as built (2026-10-27, branch `claude/software-update-step1`)
Landed in this repository:
- `packaging/pacman/`: `repository.conf` (the base `https://packages.grassfield.site` since 2026-11-03, no key yet, O11), the empty
  `grassfield-signing-key.asc`, `generate.py` (build time: checks the values and the key file, which must be exactly the
  pinned public key, and writes `/usr/share/grassfield/pacman/{repository.conf,grassfield-stable.conf,grassfield-beta.conf,
  grassfield-signing-key.asc}`), `grassfield-channel-helper`, `grassfield-channel-scriptlet`, `grassfield-channel.sh`,
  `org.grassfield.packages.policy`, `pre-refresh-pacman` (the hook);
- `packaging/bin/grassfield-channel-set` (also `/usr/bin`) and `packaging/bin/grassfield-update-check`;
- `packaging/arch/PKGBUILD` (`GRASSFIELD_PKGREL`, the three dependencies, the files above) and
  `grassfield-desktop.install` (`pre_remove`, `post_upgrade`);
- the Omarchy pins of `docs/upstream/omarchy.lock`;
- `tests/shell/update_check.sh` (the checker, logic layer) and `tests/integration/software_update.sh` (the container test).

`grassfield-keyring` was held back from grassfield-desktop's `depends` (owner decision O21) until grassfield-packages' step 1b,
which builds it, was merged (its PR #3); the follow-up adds it, and a machine that builds from source builds the keyring
once until the repository is published (O22). `makedepends` now holds everything the build compiles against (`makepkg -s` installs the global depends and
makedepends only): `hyprwayland-scanner`, `kio`, `solid`, `kcoreaddons`, `kservice`, `qt6-webengine`, `qt6-multimedia`,
found by the first builds in a clean container.

Moved to step 2, with the shell code that uses them: the shim's `omarchy.system-update` forward (its target, the shell's
`update check` IPC, belongs to the step 2 shell service), `updates.automaticCheck` (a key goes through
`ui/Grassfield/Ui/SettingsContract.js`, the settings vectors and the store, which the open Settings stack #8-#10 changes;
its only reader is the step 2 scheduler) and `software-update.json` (written by that service). The pins of
`omarchy-update-status` and `omarchy-launch-floating-terminal-with-presentation` move with their derived files. The
waiter of d.5 is the checker's `--after-update-lock` mode, which the step 2 service starts.

Choices made within this ADR:
- "Reads no environment variable" (c.1): both root programs start as `#!/bin/bash -p` (no `BASH_ENV`, no imported
  function) and remove every exported variable before sourcing their library, which then sets `PATH=/usr/bin`, `LC_ALL=C`,
  `umask 022` and `cd /`.
- One change at a time: both root programs take `flock` on `/run/grassfield/channel.lock`, in a folder only root can
  open (0700; the file 0600, made under umask 077 and checked before use: flock needs no write access, so a lock others
  can read would let any user block "Turn Off…" and the removal, step 1 review MAJOR 1). The helper refuses when it is
  held; the scriptlet program waits up to 120 s, since the helper can start just before a pacman transaction whose
  scriptlet runs it, and two rewrites of `pacman.conf` could otherwise lose one another. Under the lock, temporary files
  a killed run left in `/etc` are removed.
- No environment at all: while their environment holds anything, both programs run themselves again under `env -i`
  (entries such as `BASH_FUNC_x%%` are no variables, so no unset loop removes them, and `pacman-key` is a bash script).
- Exactly one `[grassfield]` section: `set` and `restore` replace several by one (the hook can append between the
  helper's read and its rename; pacman then refuses a database "already registered"). Several sections, or the lines
  without their file, read `repair` in the checker and in `grassfield-channel-set`.
- `[grassfield]` lines whose file is missing (pacman cannot run at all then) are removed first by `set`, `restore` and
  `off`, so `pacman-key` and `pacman-conf` can run; `grassfield-channel-set` shows that state as `repair`, and its
  `repair` runs `set stable` there.
- The checker keeps its failure count, the Server lines it last synced and its last success in `health-db/` (ADR-0020's
  row). Its `--offline` flag carries the shell's connectivity: a failure while offline is not counted.
- A notes file whose `channel` is not the client's channel is refused, like any other invalid notes.
- `grassfield-channel-set` honours `GRASSFIELD_UPDATE_PKEXEC` only in a dev session (ADR-0019's predicate) and never makes
  or removes the hook link there; without the stand-in, a dev session refuses the change.

## Step 1b as built (grassfield-packages PR #3, merged 2026-10-27)
grassfield-packages builds what g lists; its README has the details and `docs/evidence/step1b-2026-10-27/` the runs.
Where it goes further than this ADR's text:
- Each tag is built once into a release build per channel (its packages, a database of that release alone and its notes);
  the channel's one publisher (h.2 as amended by ADR-0037) makes each snapshot from the newest release build.
- Signing with the project's key (b.7) is split over three containers, so that the key never meets a program that reads
  package contents (`repo-add` evaluates `.PKGINFO` lines): the database is made without the key, the key's container
  runs gpg only on an allowlist of file names, and the result is checked as a client would, without the key.
- `grassfield-keyring` is built once per version, and each release build's copy must be `keyring/` in grassfield-packages,
  the whole package (paths, file types, contents, install script, `.PKGINFO` fields), before it is signed.
- A deliberate rollback (h.2) also withdraws the newer release builds from what the publisher reads, and puts them back if
  the publisher refuses it.
- Nothing is published: publishing jobs are written and disabled, and every key in its tests is a throwaway one.

## Step 2 as built (2026-10-28, branch `claude/software-update-step2`)
Landed in this repository, in three parts:
- **The checker** lists the other updates beside their count (`otherPackages`, d.3.5), cut first at the 256 KiB cap.
- **The shell** (`shell/services/SoftwareUpdate.qml`, its pure decisions in `ui/Grassfield/Ui/SoftwareUpdateLogic.js`):
  the one-shot checker with `--offline` from the shell's connectivity, one check at a time (a request joins the running one),
  the waiter of d.5 (`--after-update-lock`) when the answer is `update-running`, `software-update.json` (0600 in a 0700
  folder, atomic, `version` 1, the announced versions, the last success kept as `previous` through `failed`, `blocking` and
  `update-running`, GF-083's pending logout), the automatic schedule (`updates.automaticCheck`, schema-generated: 10 minutes
  after the start, then every 6 hours, the checker's `retryAt` first, skipped while offline or metered: one `nmcli` query),
  the IPC target `update check <user|omarchy>` (`docs/specs/security.md`'s inventory), the shim's forward of
  `omarchy.system-update refresh|clear`, one notification per new version or `blocking` episode (never for a check the user
  asked for; its click opens the pane), the Dock count on Settings and "1 update" after the Grassfield menu's Settings…
- **Settings** (`apps/settings/qml/SoftwareUpdate{State,Page,Sheet}.qml`, `CountBadge.qml`): General > Software Update with
  the red count on the sidebar's General row and on General's row, the Backend's new doors (below), and the shell's Search
  lists the pane.

Choices made within this ADR:
- One logic for both readers: `SoftwareUpdateLogic.js` moved from the shell to the shared `Grassfield.Ui` module (as
  `WallpaperConfig.js` is shared), so the shell's badge and Settings' count the same releases (O3) from the same file.
- Settings asks the shell first (d.7): `qs ipc -p <shell dir> call update check user` (`apps/runmode.h` `shellIpcArgs`, the
  `QS_*` variables removed, so the installed shell or, in a dev session, only the one `GRASSFIELD_SHELL_DIR` names); an
  answer other than `ok` (no shell, a refusal) runs the checker in Settings, whose answer stays in memory: the shell remains
  the only writer of `software-update.json`. Settings does not know the connectivity, so its own check passes no `--offline`
  (Known limitations).
- The pane waits for the shell's answer by the file's `checkedAt` (a pending logout written alone is no answer), at most the
  checker's 200 s backstop; it checks when it opens unless a check finished less than 60 s ago (U8), and after a channel
  change that succeeded (U12).
- The channel shown is what `grassfield-channel-set` prints with no argument (a read-only query, also in a dev session),
  read again whenever `/etc/pacman.d/grassfield.conf` changes; never stored per user (U12).
- Whether the build can set updates up is `grassfield-channel-set`'s own rule (`require_build`) applied to the installed
  `repository.conf`: without a key, or with the `.invalid` base, Set Up… is hidden and the pane says that Grassfield's own
  updates are not available in this build, under the up-to-date or available headline of the system's updates (Refusals;
  the integrator's re-review of 5ae52b1).
- The Backend's doors (`apps/settings/src/systemguard.cpp`, opus review): `grassfield-channel-set stable|beta|repair|off`
  joins the action allowlist (exactly one verb; never the helper itself), as an action that may wait for a password (one per
  tag, 130 s, `pendingActions`: "Waiting for permission…"); a new `Backend::launch` starts, detached and in the session's own
  environment and language, exactly `omarchy-launch-floating-terminal-with-presentation omarchy-update` (Update Now) or
  `/usr/lib/grassfield/grassfield-session-end logout|restart` (`isLaunch`); `askShellToCheck` and `runUpdateChecker` build
  their commands themselves. A dev session runs none of the actions or launches (SystemService and the Backend both refuse).
  Nothing new runs as root: the only root code stays the helper behind the polkit action of c, which
  `grassfield-channel-set` asks for.
- Update Now (U11): 5 s after the launch (`softwareUpdate.launchCheckMs`) the pane asks for a check, which finds Omarchy's
  update lock held and goes to the waiter, so the button stays disabled until the update ends; the pane says "An update is
  running in Omarchy's terminal" (d.5's "Update in progress"). When the terminal is not up by then, the button comes back and
  the check that `omarchy-update-status` sends from inside the update disables it again. « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »
- While `blocking`, Update Now is disabled with a sentence: every `omarchy update` fails at its first sync then (a2), so the
  pane's one action is Turn Off Grassfield Updates…. « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »
- Log Out… and Restart… (U14) ask first in a sheet with the Grassfield menu's words, then Settings starts
  `grassfield-session-end` itself, as the shell's Power service does: the existing session-end path, with no new IPC
  function. Restart… is offered when Omarchy's `reboot-required` marker exists or the running kernel's modules folder is gone
  (`omarchy-update-restart`'s rule, pinned in `docs/upstream/omarchy.lock`); a restart covers the log out. « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »
- The other updates (`otherPackages`) are listed in an (i) sheet of the "N other updates" row (name, installed → available),
  with a line when the checker cut the list. « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »
- `GRASSFIELD_UPDATE_LAUNCHER` is not used: a dev session suppresses Update Now like every action, and its exact command is
  held by `tst_systemguard` (`LaunchGuard`), `tst_backend` and the pane's test with a fake backend. It leaves ADR-0019's
  table. `GRASSFIELD_UPDATE_PKEXEC` stays `grassfield-channel-set`'s (step 1).

After the integrator's opus review of a9a5974 (FAIL: three MAJORs, the privilege path sound):
- **After Turn Off…, Software Update still offers the system's updates.** Decided by the integrator, under the owner's
  delegation of 2026-10-27 (closest to macOS 27, no technical step). The checker's `not-set-up` no longer stops after
  `pacman-conf`: it runs `checkupdates` without `[grassfield]` (no `[grassfield]` sync, no notes) and reports Omarchy's release
  and the other updates, never a Grassfield release. A failure there is `failed`, never counted towards `blocking`.
  `not-set-up` counts as a success in `SoftwareUpdateLogic.js`: the badge, the announcement and the pane show Omarchy's
  release, with Update Now under Set Up…. The pane also offers Set Up… after a failed check while `grassfield-channel-set`
  says `off`.
- A stored `update-running` is never kept. The shell checks it as soon as it reads the file: the waiter ended with the
  session after a reboot or a log out during the update, or a crash. The pane checks it when it opens. Check Now is never
  disabled by the stored state alone.
- A waiter whose own answer is `update-running` again starts the next one after `softwareUpdate.waitRetryMs` (60 s), never in
  a loop.
- Settings runs the installed `/usr/lib/grassfield/grassfield-channel-set`, never one found on PATH.
- The Grassfield menu's "N updates" is `SoftwareUpdate.menuDetail`, which the service probe holds.
- Omarchy's notification ends with "Update Now in Software Update installs it.", since the pane shows no Omarchy notes.
- The restart rule's differences from `omarchy-update-restart` are listed in the spec's limits.
- After the re-review of 5ae52b1 (PASS, two minors): in a build without a host or key the pane never says Software Update is
  unavailable while it offers the system's updates; Turn Off… (`not-set-up`) deletes the checker's failure count, so a later
  Set Up… starts a new count instead of reporting `blocking` from the old episode at its first failure (a gap since step 1).

Evidence (the branch's PR): the C++ tests of Settings (103, `apps/settings/build-direct.sh --tests`), the QML suite (2036; 2050 with main c5643400,
none failed, no runtime warning), `tests/shell/software_update_service.sh`, `tests/security/ipc_inventory.sh` and the shim's
cases, `scripts/dev/upstream-drift.sh --require` against Omarchy v4.0.4, `check-i18n`, captures in
`docs/audits/settings-parity-2026-10-26/software-update*.png`. Not verified here: measured parity against a macOS capture
(none on this machine), a nested shot, and the real polkit, terminal and session-end flows (A12, the owner's L2).

## Step 3: Update Now without a terminal (SU-M1, 2026-10-29, branch `claude/software-update-step3`)
**Owner decision SU-M1** (2026-10-29, asked by the integrator and confirmed by the owner in this session, « Comme sur
Mac »): Update Now no longer opens Omarchy's terminal. It works as on a Mac: Grassfield's own password dialog, a snapshot
first, Omarchy's update without a terminal through a Grassfield root helper behind Grassfield's own polkit action, its
progress in Settings (a phase, a package count, a percentage where it is known, never pacman's output), and at the end
Restart or Restart Later. Before the transaction, a compatibility check refuses an update that would leave Grassfield on a
toolkit it was not built for (the incident below). This widens what runs as root, which the owner's delegation of
2026-10-27 keeps for the owner: the owner confirmed it. The privileged code needs an opus security review before merge.

**The incident of 2026-10-29** (integrator): an `omarchy update` brought Quickshell 0.3.1 → 0.3.2 (then 0.3.2.r7), Qt 6.11 →
6.12 and KF 6.29 → 6.31. The shell crash-looped: Quickshell 0.3.2 crashes when a `Socket` is closed inside its own error
signal. The fix (`fix/qs-socket-reentrancy`, merged in 439cee1) closes no socket inside the signal, and grassfield-desktop
refuses `quickshell=0.3.2`. A pacman conflict names one known-bad version; it cannot say "a toolkit this build never ran
on". Hence s3.4.

### s3.1 Who does what
- **Settings** starts one program, detached, with no argument: `/usr/lib/grassfield/grassfield-update-run` (an exact vector
  in `isLaunch`; never in a dev session). It then only reads files (s3.5). Closing Settings stops nothing; opening it again
  shows the run where it is.
- **`grassfield-update-run`** runs as the user, never as root, without a terminal. It owns the run:
  1. It takes Omarchy's update lock (`$XDG_RUNTIME_DIR/omarchy-update.lock`, the file `omarchy-update-lock` locks), on a
     descriptor every program it starts gets closed. `omarchy update`, the Store (ADR-0037 b.2) and the shell's checker (d.5)
     then see an update running. A held lock is `busy`: nothing runs.
  2. It makes the operation id (32 hexadecimal digits from `/proc/sys/kernel/random/uuid`) and writes its state file (s3.5).
  3. It lists the migrations already pending for this user (`omarchy-migrate --pending`, Omarchy's own reader of the
     markers).
  4. It runs `pkexec /usr/lib/grassfield/grassfield-update-helper run <op-id> [<migration>...]`: the shell's polkit agent
     shows Grassfield's dialog. Dismissed (126) or refused (127): nothing ran.
  5. After a helper that installed something, it runs Omarchy's steps that act for the user (s3.6: migrations, the
     `post-update` hook, mise), as the user, standard input `/dev/null`, no terminal.
  6. It writes the outcome, with what finishes the update (s3.7), and releases the lock by ending.
- **`grassfield-update-helper`** (root, through pkexec and the polkit action `org.grassfield.packages.update-system`: an
  administrator's password each time, `auth_admin`; never for an inactive or remote session; `exec.path` names the
  helper). It follows grassfield-store-helper's and grassfield-channel-helper's rules:
  - its argument vector is its only input: no variable is read, not even `PKEXEC_UID`; it runs itself again under
    `env -i` while it has an environment; `PATH=/usr/bin`, `LC_ALL=C`, umask 022;
  - it refuses unless its effective uid is 0;
  - no shell interpolation: every program gets an argument vector;
  - pacman's `db.lck` is respected before every step that changes something;
  - failures fail closed: any doubt stops the run before the transaction, with nothing changed.

  It runs **no Omarchy script**: every root step is the system program an Omarchy script calls with `sudo` (pacman,
  paccache, snapper, pacman-key `--list-keys` only, systemd-inhibit), with Omarchy's arguments. Those scripts are pinned in
  `docs/upstream/omarchy.lock` with the helper as their derived file, so `upstream-drift.sh` makes the next Omarchy
  change a reviewed one. Only the user's runner runs Omarchy commands, as the user, by absolute path under
  `/usr/share/omarchy/bin`. Omarchy's pacman hooks run inside pacman, as in `omarchy update`.
- **The run survives Settings and the session.** On a system run by systemd, the helper starts itself again as a transient
  system service, `systemd-run --unit=grassfield-update --collect --wait`, and waits for it. The transaction then belongs to
  no user session: closing Settings, a crash of the runner, or a log out cannot kill pacman. The unit's fixed name makes a
  second run `busy`. A stop of the unit (`systemctl stop`, a shutdown that overrides the inhibitor) sends SIGTERM to the
  helper alone (`KillMode=mixed`): before step 7 it ends the run at once (exit 8, nothing changed); from step 7 on it is
  logged and the run goes on to its end, pacman never signalled, within `TimeoutStopSec=30min`, after which systemd kills
  what is left (the snapshot is the way back). A container has no systemd: the helper runs in place there (the container
  test). The helper ignores SIGHUP and SIGPIPE. It blocks sleep, idle and shutdown while it changes the system (`systemd-inhibit --mode=block`, as
  `omarchy-update-stay-awake` does), and its descriptors are `/dev/null` and its log.

### s3.2 The helper's run, in order
Nothing changes on the system before step 7. Steps 1-6 decide, and every refusal there leaves the system as it was.
1. **Usage and state.** Exactly `run <op-id> [<migration>...]`: up to 64 names of `[0-9]{1,20}\.sh`, the operation id
   used once. Its folder `/run/grassfield-update` is root's own, 0755, never a link. In it: `<op-id>.log` (0644, at most
   8 MiB), `<op-id>.started` (pid and start time), `<op-id>.progress` (one line, by rename), `<op-id>.exit` (by rename,
   last), `last` (the newest operation id, by rename), `helper.lock` (0600). The 16 newest operations are kept.
2. **One run.** `helper.lock` with `flock -n` (the descriptor closed for every child), the unit's name, and pacman's
   `db.lck`: held open by a process (libalpm keeps its descriptor until it unlocks), it is a running pacman, `busy` (exit 3);
   held by none a second time a second later (a pacman that unlocks closes the lock before it removes it), it was left by a
   pacman that stopped mid-way, which a person clears (exit 7, `needs stalelock`: the pane says "An earlier update stopped
   before it finished." with Update in Terminal…, where pacman says how). Both before anything is read.
3. **Preconditions** (macOS's and Omarchy's): at least 10 GiB free on `/` (`omarchy-update-requires-free-space`, without
   its `OMARCHY_UPDATE_FORCE`); on battery, at least 50 % (`/sys/class/power_supply`: refused only when no supply is
   online and a battery is discharging below 50 %, macOS's rule).
4. **The plan, from a copy.** A temporary database folder in `/run/grassfield-update/sync.<op-id>` (0755: pacman 7 downloads
   as its `alpm` user), with `local` a link to pacman's own and a copy of the current sync databases, synchronised there
   (`pacman -Sy --dbpath`, `checkupdates`' method). The system's databases are not touched (measured: `pacman -Qu` is
   unchanged). The plan is `pacman -Su --print --print-format '%n %v %l' --noconfirm` on the copy. An empty plan ends the
   run: up to date. No plan (a dependency pacman cannot resolve) ends it: nothing changed.
5. **The files the checks read.** The plan's `grassfield-desktop` and `omarchy`, when the plan has them, are each downloaded
   into pacman's cache from the copy when its check needs it (`pacman -Sw`, signatures checked with the current keyring).
   Read, never run, as data:
   - `usr/share/grassfield/BUILD-DEPS` from grassfield-desktop's package file (s3.4);
   - Omarchy's `usr/share/omarchy/migrations/`, `usr/share/omarchy/bin/` and `usr/bin/omarchy-*` from omarchy's (Omarchy
     4.x ships its commands as files in `usr/bin` and links to them in `usr/share/omarchy/bin`), the members taken from
     the package's own list and extracted into a folder only root can read (s3.6, migrations). bsdtar's defaults refuse
     absolute paths, `..` and extraction through a symbolic link (no `-P`); owners and modes are not restored, and the scan
     reads regular files only. bsdtar's `-T` reads patterns, so a name is taken only in `[A-Za-z0-9/._+-]` (no pattern
     character); any other name in those folders fails closed.
   - **No here-string or here-document** in the helper or the runner: bash writes a large one to a file in `/tmp`, and an
     unwritable or full `/tmp` would make a list read empty, so a scan would find nothing and the update would go on (the
     integrator's re-review of 1ce7c37, MAJOR). Lists go through pipes or files in the run's own folder, every write
     checked; a plan with text but no package read is refused, never "up to date". The package's listing is read through
     a pipe whose status is checked (bsdtar -t exits 0 even when it cannot write its list).
   - **No read that comes back empty passes** (the re-review of 0294373): an empty `pacman -Q` (it would skip the
     compatibility and key checks), an empty `pacman-conf --repo-list` (the checked databases would never be swapped in)
     or `CacheDir` are refused (exit 8); in the runner, Omarchy's `omarchy-migrate --pending` must answer by its contract
     (exit 0 with names, exit 1 with none), anything else sends the update to the terminal path.
6. **The checks**, in this order: the compatibility check (s3.4); Omarchy's signing key in pacman's keyring and
   `omarchy-keyring` installed (`omarchy-update-keyring`'s test; when it fails, its bootstrap is a trust decision, s3.6:
   after the compatibility check, so an update it refuses is said so, never sent to the terminal); the migrations that
   need a person (s3.6). Each refusal is final for this run: nothing was changed.
7. **Snapshot**, after pruning the package cache first (`paccache -rk2`, Omarchy's order: the cache is on the snapshotted
   subvolume). Every snapper configuration gets `snapper -c <config> create -c number -d "<Omarchy's version>"`, then
   `snapper -c <config> cleanup number` (`omarchy-snapshot create`). Without snapper, without a configuration, or when it
   fails, the update goes on without a snapshot, as Omarchy's does. The outcome records it: the failure sentences never
   promise a snapshot that was not made.
8. **The databases checked become the system's.** The copy's sync databases (and their signatures) replace the system's, by
   rename, under pacman's own lock: `db.lck` checked again (step 2's rule), then made by the helper exclusively, as libalpm
   makes it, and removed after the swap (or when the helper ends). The transaction then installs exactly what was checked,
   never what a mirror published in between: a second `-Sy` would bring a plan nobody checked. From here every exit file
   carries `synced`.
9. **Keyring** (`omarchy-update-keyring`): `pacman -S --needed --noconfirm --noprogressbar archlinux-keyring`, Omarchy
   4.0.6's form (4.0.4 reinstalled it each time; 4.0.6 notes that new or revoked keys come as a new version).
10. **The transaction** (`omarchy-update-system-pkgs`): `env LC_ALL=C OMARCHY_UPDATE_PACMAN=1 pacman -Su --noconfirm
    --noprogressbar --overwrite '/usr/share/omarchy/*'`. `OMARCHY_UPDATE_PACMAN=1` is what Omarchy's guard hook
    (`00-omarchy-update-guard.hook`) accepts from its own update. Its output goes to the log, read line by line for the
    progress (s3.5).
11. **After it:** Omarchy's initramfs check (`omarchy-update-analyze-logs`) on the helper's own log; the restart rule's root
    half (s3.7); the exit file. Orphans are left (s3.6).

Exit codes (`<op-id>.exit`: the code on its first line, then `key value` lines: `packages`, `snapshot made|none|failed`,
`synced`, `restart kernel|hyprland|toolkit`, `logout grassfield`, `bootimage failed`, `needs keyring|stalelock|scan|conflict`,
`needs migration <name>`, `incompatible <package>`): 0 done, or up to date (`packages 0`); 1 failed during the transaction
(the system can be partly updated: the snapshot is the way back); 2 usage, or an operation id used before; 3 busy; 4 less
than 10 GiB free; 5 on battery below 50 %; 6 needs a newer Grassfield (s3.4); 7 needs a person (s3.6, and a `db.lck` no
process holds); 8 failed before installing anything (offline, a mirror, a download, a plan pacman refuses or that cannot be
read, a stop of the unit before step 7), with `synced` when the checked databases were already the system's. pkexec itself
exits 126 (dismissed) and 127 (not authorized).

### s3.3 What the run changes, and when it stops
- Before step 7, nothing but pacman's cache (two packages at most) and `/run/grassfield-update`.
- From step 8, the sync databases; from step 9, the keyring package; from step 10, the system.
- A failure inside the transaction before pacman's ":: Processing package changes" (a conflict, a file conflict, a
  signature) changes no package: pacman says "no packages were upgraded". The outcome is then 7 or 8 with `synced`, the
  databases newer than the system, and the pane does not say "Nothing was changed": it says the updates were not
  installed. Grassfield Store refuses to install until an update finishes (its S12), and the pane offers the
  update again, or Omarchy's terminal when a person must answer (s3.6).
- A failure after that line is 1: the pane says the update did not finish and that the snapshot taken before it can be chosen
  when the computer starts (only when `snapshot made`).

### s3.4 The compatibility check
- **The record.** The PKGBUILD writes `/usr/share/grassfield/BUILD-DEPS` into grassfield-desktop, next to `BUILD-COMMIT`:
  `pacman -Q` of the build environment for the tracked packages, one `<name> <version>` per line. Every split package of a
  build depends on `grassfield-desktop=<pkgver>-<pkgrel>`, so one record covers them all. `quickshell` joins `makedepends`
  so the build records the version it ran against (the build environment is an Omarchy stable machine's set, f).
- **Tracked, and compared at:**

  | Package | Compared | Why |
  |---|---|---|
  | `qt6-base` | major.minor | Grassfield's C++ modules and apps link Qt's private QML ABI; 6.11 → 6.12 in the incident |
  | `quickshell` | its version without pkgrel | 0.3.1 → 0.3.2 crash-looped the shell (the incident) |
  | `hyprland` | major.minor | the Lua configuration and the plugin's API; a patch release is ADR-0009's degraded mode with the plugin's rebuild (f) |
  | `aquamarine` | major.minor | Hyprland's backend, which moves with it |
  | `kcoreaddons` | major.minor | KDE Frameworks release together (6.29 → 6.31 in the incident); Files and the portal link them |

- **The rule.** Compared only when the plan changes `grassfield-desktop` or a tracked package: an update that changes
  neither keeps today's state. The record is the one of the grassfield-desktop the transaction leaves installed: the plan's,
  read from its package file, so a matching build in Grassfield's repository joins the same transaction (a newer
  grassfield-desktop is part of `-Su`'s plan), or else the installed one's. The update goes on when every tracked package
  installed after the transaction has the record's value at its comparison. A missing record (a build before step 3), or a
  tracked package the record lacks, fails closed.
- **Residual risk (integrator's review of a060504).** Qt's private symbols carry the version tag `Qt_6_PRIVATE_API`, the same
  for every 6.x release: the dynamic loader cannot refuse a patch release whose private ABI moved. major.minor stays the
  comparison, since Grassfield's only private Qt use is `QNativeInterface`, which Qt keeps within a minor release.
- **Refused:** the run stops before any change (exit 6, `incompatible <package>` in the log). The pane says "This update
  needs a newer version of Grassfield, which isn't available yet." and "Software Update checks again later and tells you
  when it's ready." Its Check Now stays; the schedule checks again (d). No technical step is offered: not Omarchy's terminal,
  which has no such check.
- grassfield-desktop's `conflicts=('quickshell=0.3.2')` stays: pacman refuses that version on every path, `omarchy update`
  included.
- Amended 2026-11-08 (owner decision, ADR-0041 step 2a, built): `grassfield-hold` now carries exactly that bound for `qt6-base` and
  `quickshell` (never `hyprland`, never `kcoreaddons`), with the watch job of f (daily, ABI stamp, Omarchy stable and rc) to end the refusal
  and Settings' "Allow system updates Grassfield hasn't tested…" as the way out; this check stays as the second line (exit 6 for the
  hold's own refusal too). The wait for a matching build is bounded at 7 days (owner decision of 2026-11-08, ADR-0041 step 2a as built):
  the shell's state file keeps the first refusal's time, and past 7 days the notice puts "Allow…" forward. The rejection below was the first reading.
- Rejected: tight versioned `depends` (`qt6-base<6.13`). pacman would then refuse a toolkit update on every path, and an
  `omarchy update` in the terminal would fail with a dependency error until Grassfield rebuilds, blocking security fixes
  (a2's lesson). The check keeps that choice to Update Now, which can say it plainly.

### s3.5 Progress and reconnection
- `<op-id>.progress`, written by the helper by rename: `checking`, `snapshot`, `keyring`, `downloading <done> <total>`,
  `installing <done> <total>`, `finishing`. Downloads are counted from pacman's ` <file> downloading...` lines against the
  plan's packages not yet in the cache. Installs are counted from its `installing|upgrading|reinstalling|downgrading|removing
  <name>...` lines against the `Packages (N)` it prints (measured: pacman 7.1 prints no counters with `--noprogressbar`).
- The runner's state, `$XDG_RUNTIME_DIR/grassfield/software-update-run.json` (0600 in a 0700 folder, by rename): `op`, its
  `pid` and start time, `phase` (`authorizing`, `updating`, `configuring`, `done`), `result`, `restart`, `deferred`, the
  times. Only fixed tokens and numbers.
- Settings reads both while a run is alive (a 500 ms timer; the files are replaced by rename), and on opening. The pane
  shows the phase, "12 of 132", and one bar: 0-5 % checking and the snapshot, 5-45 % downloading, 45-95 % installing, 95-100 %
  finishing and Omarchy's steps for the user. The bar is determinate when a count is known, indeterminate otherwise.
- A runner that ended without its state (a log out took it and its runtime folder) leaves the helper's files: with no
  runner's state, the pane reads `last` and shows that helper's progress while it runs (its `.started` process, no `.exit`),
  then nothing; the user's steps of that run were not run (Omarchy's login notifier offers its migrations). `/run` is empty
  after a restart, so nothing stale is shown then.

### s3.6 Omarchy's prompts (Omarchy 4.0.4's `omarchy-update` and what it calls; data, read 2026-10-29)
Each prompt or need for a terminal, and Grassfield's answer. « décision déléguée par le propriétaire le 2026-10-27 : macOS
d'abord, aucune intervention technique pour l'utilisateur » for every row that chooses (the integrator's brief sets the
rule: a safe non-interactive answer, or the step deferred, or the update stopped before it).

| Omarchy step | Prompt or terminal need | Grassfield's answer |
|---|---|---|
| `omarchy-update` | its transcript through `script -qefc` (a terminal) into `/tmp/omarchy-update.log` | the helper's log, `/run/grassfield-update/<op-id>.log` |
| `omarchy-update-lock` | none | the runner holds the same lock (s3.1) |
| `omarchy-update-requires-free-space` | none; `OMARCHY_UPDATE_FORCE` skips it | same 10 GiB rule, never skipped; "This computer needs 10 GB of free space to update." |
| `omarchy-update-confirm` | `gum confirm` "Continue with update?", warns about power | the password dialog is the consent; on battery below 50 %: "Connect this computer to power to update." |
| `omarchy-update-pkg-prune` | `sudo` | `paccache -rk2` as root; a failure is ignored, as Omarchy does |
| `omarchy-snapshot create` | `sudo`; no configuration is a message | snapper as root; none, unconfigured or failed: the update goes on (Omarchy's answer), recorded |
| `omarchy-update-stay-awake` | `sudo -v` or `pkexec` (a second password) | `systemd-inhibit` from the helper, already root; Omarchy's idle toggle is not used |
| `omarchy-update-dev` | none (`git pull` of a dev checkout) | not run: Update Now updates the packaged Omarchy only |
| `omarchy-update-keyring`, bootstrap | `sudo`; fetches Omarchy's key from a keyserver and signs it locally | not run: a trust decision. Stops before any change: Omarchy's terminal (below) |
| `omarchy-update-keyring`, refresh | `sudo` | `pacman -S --needed --noconfirm archlinux-keyring` as root (s3.2 step 9) |
| `omarchy-update-system-pkgs` | `sudo`; pacman's questions under `--noconfirm` | as root, the same arguments without `-y` (s3.2 step 10); pacman's own `--noconfirm` answers: a replacement yes, a conflict no, a key import yes (an imported key is trusted only if the keyring signs it) |
| `omarchy-update-system-pkgs-when-conflicted`, package conflict | reruns pacman for a person to answer | not run: nothing was installed (pacman stops before), then Omarchy's terminal |
| idem, unowned files of Omarchy's packages | moves them to `/var/lib/omarchy/replaced` as root and retries | not run (moving live files on a reading of pacman's errors): nothing was installed, then Omarchy's terminal |
| `omarchy-migrate` | runs as the user; a migration may call `sudo`, `gum`, or an Omarchy command that does | scanned before any change (below); then run by the runner as the user, standard input `/dev/null` |
| `omarchy-hook post-update` | the user's own scripts | run by the runner as the user, standard input `/dev/null`, at most 300 s; a failure is ignored, as Omarchy's `omarchy-hook` does |
| `omarchy-update-aur-pkgs` | `yay -Sua --noconfirm`, whose installs `sudo` | deferred: not run (it needs a password in a terminal and builds code). When AUR packages are installed (`pacman -Qm`), the end of the run says "Apps from the AUR are updated in Omarchy's terminal." with Update in Terminal… |
| `omarchy-update-mise` | none (`mise up`) | run by the runner as the user when mise is installed; a failure is ignored |
| `omarchy-update-orphan-pkgs` | `gum confirm`; without a terminal it keeps them | not run: Omarchy's own non-interactive answer (keep) |
| `omarchy-update-analyze-logs` | none | the same check on the helper's log; a failure: no Restart, "Don't restart this computer yet: the update could not prepare its startup files." |
| `omarchy-update-status` | none (Omarchy's bar) | not run: the shell's checker sees the lock released (d.5) |
| `omarchy-update-restart`, reboot | `gum confirm` "Reboot?" (kernel, `reboot-required`, Hyprland replaced) | Restart / Restart Later at the end (s3.7), never automatic |
| idem, `restart-*-required` | restarts Omarchy services | not run: the end asks for a restart, which covers them |
| idem, `omarchy-restart-shell` | none | not run: Grassfield's shell is not Omarchy's. A toolkit or Grassfield change asks for a restart or a log out (s3.7) |
| `omarchy-channel-set`, `omarchy-update-firmware` | `gum confirm`, `sudo` | not part of `omarchy-update`; never run by Update Now |

**Migrations that need a person.** The helper scans, before any change, every migration that will be pending after the
update: those the new `omarchy` package adds (its file list against the installed package's) and those the runner named as
already pending. A migration needs a person when a line names `sudo`, `pkexec`, `su`, `run0`, `doas`, `gum`, or `/dev/tty`,
or an Omarchy command that does. That set is computed over the regular files of the new package's `usr/bin/omarchy-*` and
`usr/share/omarchy/bin/` (else the installed `/usr/bin/omarchy-*` and `/usr/share/omarchy/bin/`) until it stops growing,
starting from the same words and Omarchy's own `omarchy:requires-sudo=true` header. Comments count: the scan is
conservative. It fails closed: with no command file to read (`needs scan`), for a new package with no migration at all, for a
new `*.sh` migration whose name is not `[0-9]{1,20}.sh` (omarchy-migrate runs every `*.sh`) or a member name outside the
safe charset, for a pending migration that is not a regular file, and in the runner for more pending migrations than the
helper's 64 names or a name it refuses (`terminal`, no helper started). (Integrator's review of a060504, MAJOR: the first version read `usr/share/omarchy/bin` alone, where Omarchy 4.x
has only links, so it found no command; on 4.0.6's data the scan now flags six migrations, not three.) Then the
run stops before any change (exit 7, `needs migration <name>`) and the pane says: "This update asks questions that need
Omarchy's terminal." with Update in Terminal…, which starts `omarchy update` in Omarchy's terminal (step 2's path). Omarchy
4.0.4 → 4.0.6 adds 14 migrations; three call `sudo` (`1791403252`, `1791581004`, `1791621765`) and three call Omarchy
commands that do (`1790017600`, `1790114905`, `1792334754`: `omarchy-install-hermes-cli`, `omarchy-install-openclaw-cli`),
so that release goes to the terminal; a package update without an Omarchy release adds none.
- A migration that fails anyway (the scan missed it; `sudo` fails at once without a terminal) leaves the update installed and
  that migration pending, a state Omarchy itself supports (its login notifier, `omarchy-migrate-notify`). The pane then says
  "Some of Omarchy's last steps need its terminal." with Finish in Terminal… (`omarchy-migrate` in Omarchy's terminal).
- Rejected here: giving migrations root through the helper (a `sudo` that asks nothing), or an askpass dialog for `sudo`.
  Either would widen root or add a password surface beyond SU-M1 and the security rules (`shell/security/`); the owner
  decides that, not this delegation. **The owner decided it on 2026-10-31: SU-M2, one password ("Step 5").**

### s3.7 The end of the run
- **Restart** when the kernel changed (a `vmlinuz` under `/usr/lib/modules` owned by a package, none for the running release:
  `omarchy-update-restart`'s rule), Hyprland or a toolkit package of s3.4 was in the plan, the user's
  `~/.local/state/omarchy/reboot-required` or a `restart-*-required` marker exists. **Log out** when grassfield-desktop
  alone of those changed (GF-083, i). A restart covers the log out.
- The pane then opens a sheet: "Restart to finish updating" with Restart Later and Restart. Restart runs
  `grassfield-session-end restart` (step 2's path). Restart Later keeps the pane's "Restart to finish updating" row. Nothing
  restarts by itself.
- Otherwise: "This computer is up to date", and the shell's checker runs when the lock is released (d.5).

### s3.8 Limits
- The update of an Omarchy release that ships a migration using `sudo` goes to Omarchy's terminal (s3.6). Grassfield's flow
  covers the system's packages, Omarchy's packages without such a migration, and Grassfield's. (Step 5, SU-M2: a migration
  that needs root and nothing that needs a person now runs without the terminal.)
- AUR packages are not updated by Update Now (s3.6).
- The compatibility check covers five packages; another library Grassfield links can still move unchecked.
- A conflict pacman reports only inside the transaction (`--print` does not check conflicts: measured) is found after the
  databases are committed; nothing is installed, and the pane offers Omarchy's terminal.
- Settings follows the run by files; Omarchy's own `omarchy update`, started meanwhile, says an update is running.
- When the run ends while Settings is closed, nothing announced it until Settings opened (the pane's row): step 4 adds the
  shell's notice (below).

### s3.9 Evidence (this branch)
- `tests/integration/update_helper.sh` in a throwaway `archlinux:base` container (pacman 7.1, polkit 128): 80 PASS, 0 FAIL
  after the integrator's re-review of 0294373 (76 after the re-review of 1ce7c37, 72 after the review of a060504, 62 before it; the helper of 1ce7c37 fails
  the new `/tmp` and fail-closed cases; `docs/audits/software-update-2026-10-27/update-helper-2026-10-29.txt`).
  Its `omarchy` package now has Omarchy 4.x's layout (command files in `usr/bin`, links in `usr/share/omarchy/bin`). The real helper, runner and policy; Omarchy
  4.0.4's own `omarchy-migrate`, `omarchy-hook`, `omarchy-update-mise` and update guard (hook and program) in a test
  `omarchy` package; Omarchy's real public key from keys.openpgp.org; real polkitd and pkexec.
- Probes behind s3.2 and s3.5 (same container image): a plan from a temporary `--dbpath` leaves `pacman -Qu` unchanged;
  `--print` does not check conflicts; pacman 7.1 prints `upgrading <name>...` without counters under `--noprogressbar`, and a
  file conflict ends with "no packages were upgraded".
- Settings: C++ 104 tests (`tst_systemguard` LaunchGuard, `tst_backend`); QML `tst_softwareupdate` 25,
  `tst_settingssoftwareupdate` 22, `tst_settingsmain` 7; the whole QML suite 2163 passed, the same 2 failures as main in this
  image (`ControlsMisc` combo list sizes), no runtime warning in product code (`qml_warnings.py`); qmllint's warning set
  identical to main's; `check-i18n` (0 unfinished, 0 bare literals), `i18n-update.sh --check`, `upstream-drift.sh --require`
  against Omarchy v4.0.4, inventory, contracts, schema, scripts, version, licences; captures `software-update-run.png`.
- NOT verified here: the transient systemd unit, snapper, paccache, the free-space and battery refusals, the real polkit
  dialog through the shell's agent, the PKGBUILD's BUILD-DEPS in grassfield-packages' build container (quickshell from its
  Omarchy package set), a nested shot. They are the integrator's nested pass and L2 (spec A15).

## Step 4 as built (2026-10-31, branch `claude/software-update-step4`)
The owner asked to go on while the integrator is away ("tu peux continuer et vérifier après"); the integrator reviews it
afterwards. Three changes, none to the privileged code (the helper, the runner, the policy and Settings' allowlist are
untouched):
- **The flaky test of #44's merge note.** `test_theShellsAnswerEndsTheWait` built the "same" `software-update.json` with two
  `Date.now()` calls around the page's creation; `checkedAt` keeps whole seconds, so across a second the pending logout looked
  like a new answer (`answered()` compares `checkedAt`). One time for both: 2 failures in 30 runs before, 0 in 60 after.
- **The end of a run is announced** (spec U33). The shell's service watches the runner's state
  (`$XDG_RUNTIME_DIR/grassfield/software-update-run.json`, replaced by rename: measured with Quickshell's FileView, which
  follows a rename, a removal and a late creation only while the folder exists, so the service makes the folder first, 0700
  as the runner does). A run it saw going on is announced once when it ends, by `SoftwareUpdateLogic.runNotice`; a run
  already ended when the shell started is not. shell.qml posts one notice opening the pane; a restart or a log out is not
  posted while Settings' window (not About This Computer) is in front, since its end sheet asks it. GF-083's log-out notice
  waits while a run goes on (an hour at most) and is never posted after the run's restart or log out: one notice says what
  finishes the update. A dev session watches its own folder (ADR-0019 `UPDATE_RUN_DIR`). Decision SU-D4: « décision
  déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: macOS
  tells about a finished install that asks for a restart with a notification when its window is not in front.
- **Restart… and Log Out… wait for the run's end** in the pane: the system changes until then (the helper also blocks a
  shutdown with logind).

Evidence: `tests/shell/software_update_service.sh` (the real Quickshell, offscreen) with a new step r: a run found already
ended is not announced, one seen going on is announced once as a restart, the same end written again alone says nothing, a
run configuring is a run going on, a cancelled run ends with no notice, an incompatible one is announced; a dev session's
run folder is its own (0700) and the runtime folder is left alone. `tst_softwareupdate` 26 (`test_runNotice`),
`tst_settingssoftwareupdate` 22 (Restart… and Log Out… disabled during a run, enabled after it), `tst_settingsmain` 8;
check-i18n 0 unfinished. Not verified here: the notice in a real session (the integrator's nested pass, with
`GRASSFIELD_UPDATE_RUN_DIR`), Settings in front skipping a restart, GF-083's notice held during a run (shell.qml, which no
headless test loads).

## Step 5: one password for the migrations' sudo (SU-M2, 2026-10-31, branch `claude/software-update-su-m2`)
The owner chose « Mot de passe unique » (SU-M2): the password typed for Update Now also covers the `sudo` commands of
Omarchy's migrations. This step widens what runs as root, and the security rules ask for an opus PASS before the merge. It
says what the person's single authorization now covers, and what keeps anything else from using it. An independent opus
review of the first version (b369f16) failed it (see "Review history"); this text is the version that answers it.

### s5.1 What changes
- **The scan has two sets** (s3.6). What needs a person: `pkexec`, `su`, `run0`, `doas`, `gum`, `/dev/tty`, or a `sudo` by
  its path (`/usr/bin/sudo`, `/usr/sbin/sudo`, `/bin/sudo`: not the unit's `sudo`), or an Omarchy command that reaches one of
  them. What needs root: `sudo` and Omarchy's `omarchy:requires-sudo=true` header, or a command that reaches one of them.
  Both are computed the same way as before (the command files of the new package, else the installed ones, until the set
  stops growing; comments count). A migration that needs a person still sends the run to the terminal before any change
  (`needs migration`, now listing those that need root too).
- **A run whose new migrations need root and nothing that needs a person** goes on when the conditions below hold. After
  `pacman -Su` succeeded, the helper runs those migrations itself, before it reads its log (Omarchy's own order: migrations
  after the transaction). It does not call `omarchy-migrate`; it runs the same loop (Omarchy 4.0.6, `bin/omarchy-migrate`:
  each migration in order, `bash -euo pipefail`, its marker after it, the first failure stops), but only for this update's
  scanned migrations, by name. A marker removed meanwhile never brings another migration into the unit.
  It runs them in the transient system unit `grassfield-update-migrate.service`:
  - as the person's uid, with the **primary group `grassfield-update`**, which has no member (sysusers.d). systemd adds
    the person's groups as supplementary ones (its `initgroups`), and the helper adds the person's own primary group, so
    the person's files stay theirs. The kernel lets a process open another's `/proc` entries (descriptors, environment,
    memory, folder) or attach to it only when all its uids and all its real, effective and saved gids match; supplementary
    groups do not count. None of the person's other processes can therefore reach into the unit; this is measured in s5.6;
  - with **no namespace of its own** (`RestrictNamespaces=yes`). A user namespace a migration made (bwrap, flatpak, rootless
    podman, a browser's sandbox, `unshare -U`) would belong to the person, whose other processes could then reach into it
    (the integrator's review, MINOR 1). Its personality is locked, and it makes no setuid or setgid file
    (`LockPersonality`, `RestrictSUIDSGID`);
  - with `NoNewPrivileges=yes`, so no setuid program runs (no real `sudo`, `pkexec` or `su`, no `newgrp`);
  - with `PrivateTmp=yes`: its `/tmp` is its own, and the root units of its `sudo` join it (`JoinsNamespaceOf`). A
    temporary file a migration hands to a root command (4.0.6's `1791403252` does `mktemp` then `sudo install`) is out of
    other processes' reach;
  - with `PATH=/usr/lib/grassfield/update-sudo:/usr/share/omarchy/bin:/usr/bin` and `OMARCHY_PATH=/usr/share/omarchy`;
  - with the person's runtime folder and session bus, and two session values (s5.2);
  - with standard input `/dev/null`, and its output in `/run/grassfield-update/<op-id>.migrations` (root's, 0600, cut at
    the log's 8 MiB, read with the log for a failed startup image). Its output holds root commands' output too, so it never
    joins the 0644 log. No file the unit's own processes write may pass 64 MiB (`LimitFSIZE`). Its root commands run in
    units of their own and are not bound by it, since a boot image or a package is bigger; their output is cut with the
    rest when the migrations end;
  - at most 30 minutes; when it ends, every process left is stopped within 5 seconds (`TimeoutStopSec=5s`,
    `KillMode=control-group`).
- **After the unit, the helper waits** (30 minutes at most) for any root unit its `sudo` started. A long command (pacman)
  therefore ends under the run's lock and sleep inhibitor, never after the pane says the run is done. It then reads again
  the packages s3.4 and s3.7 follow: a migration may run pacman itself, as `1791403252` does. A change there gives the end
  its restart or log out, and is logged as not checked against the record.
- **The exit file says `migrations ran`.** The runner then does not run `omarchy-migrate`, but still reads what is left
  pending: a migration that failed stays pending (`deferred migrations`, "Finish in Terminal…"), as before.
- **Otherwise** the run goes to Omarchy's terminal before any change, exactly as in step 3 (exit 7, `needs migration`), and
  its log says why.

The conditions, checked in this order:
1. The helper runs in `grassfield-update.service` (a system run by systemd; never in place).
2. A person: pkexec's caller has a real uid of 1000 or more with an entry in the password database.
3. That person is an administrator: a member of `wheel` (Arch's polkit rule and Omarchy's sudoers). The grant is that
   person's own `sudo`, never more than they have in Omarchy's terminal (the review's BLOCKER).
4. No migration from before this update is pending (the runner's names): the unit runs this update's own migrations only.
5. The group `grassfield-update` exists, has no member and a locked password (`newgrp` would take a password), and is
   not the person's own group.
6. The sudo and the rule are installed. Omarchy's migrations folder, its commands folder (the migrations call its commands
   inside the unit) and the sudo are root's alone: every folder on the path as written, each link on it owned by root, then
   the file and every folder above it with links resolved, all belong to root and no one else can write them (the
   integrator's MINOR 2 and follow-ups 1-2). After the transaction, the commands folder and each migration file must be
   too; otherwise none runs here (the runner runs them without root, and what needs root stays pending).
7. A trial `sudo -n /usr/bin/true` through a migrations' unit succeeded. This proves the whole channel (the unit, the rule,
   polkit, systemd) before anything changes.

### s5.2 The person
- The helper reads no variable for itself; step 3's rule stands. The instance pkexec started reads two things from its
  parent's `/proc` entries. The parent is pkexec's caller, the runner, which waits for it. pkexec refuses a caller that has
  been re-parented to PID 1; a caller re-parented to a subreaper runs as the same uid, so it is harmless.
  - **Its real uid.** Below 1000 (root, a system user), no migration runs here.
  - **`WAYLAND_DISPLAY` and `HYPRLAND_INSTANCE_SIGNATURE`**, kept only when they match `wayland-[0-9]{1,4}` and
    `[A-Za-z0-9_]{1,128}`, so a migration can reach the session as it does in Omarchy's terminal. They go into the user
    unit's environment only; nothing as root reads them.
- It passes them to its unit instance as `unit <op-id> <uid> <wayland> <hyprland> [<migration>...]`. The helper takes that
  form only inside `grassfield-update.service` (its cgroup, which only root can create); elsewhere it is a usage error.
  pkexec's caller can only start the `run` form.

### s5.3 The channel, and what keeps anything else from using it
- **The migrations' `sudo`** (`/usr/lib/grassfield/update-sudo/sudo`, alone in its folder, first in the unit's PATH) runs
  as the person and is not the boundary. It takes Omarchy 4.0.6's forms of sudo's command line:
  - `-n`, `-H`, `--`, and `-u` with root as the target (`root`, `0`, `#0`);
  - `-v`, `-k`, `-K` without a command: success;
  - `-l`: exit 1.
  It refuses every other form (`-E`, `-i`, `-s`, a variable before the command, an unknown letter in a cluster such as
  `-nHE`, ...) and any other target. A process of the
  person's own identity started by a root unit would be outside the unit's group but inside its `/tmp`, open to the
  person's other processes (the re-review's MINOR 1, reproduced). Omarchy 4.0.6's migrations never use `-u`. A refused
  form fails the migration, which stays pending.
  It looks a name up in fixed root-owned folders (`/usr/share/omarchy/bin`, `/usr/local/sbin`, `/usr/local/bin`,
  `/usr/bin`), never in the caller's PATH. Whatever the command, it must be root's alone, or it is refused: every folder
  on its path as written and each link on it (the folder that holds a link decides who can swap it), then the file and
  every folder above it with links resolved. A migration therefore cannot point a root command at a file of the
  person's, or at one anyone else could swap between the check and the run. Then it
  runs `systemd-run --wait --pipe --no-ask-password --expand-environment=no` with:
  - a unit named `grassfield-update-root-<32 hex>.service`;
  - root as the user;
  - `/` as its working folder, never the caller's (the migrations' unit works in the person's home: rc7 audit R7-SEC-01,
    integrator's decision of 2026-11-08), and the caller's standard input, output and error;
  - the unit's `/tmp`;
  - `SUDO_USER`, `SUDO_UID`, `SUDO_GID`.
  The command's exit status is sudo's. Its arguments reach it unexpanded. Its environment is systemd's for a root service
  plus `SUDO_*`, nothing of the caller's (no `LD_*`, `PYTHON*`, `PERL5LIB`, `BASH_ENV`): the test checks the list.
- **The boundary is polkit's rule** `/usr/share/polkit-1/rules.d/49-grassfield-update.rules`. For
  `org.freedesktop.systemd1.manage-units` asked by a subject whose `system_unit` is `grassfield-update-migrate.service`:
  - YES when `no_new_privileges` is set, the verb is `start` and the unit is `grassfield-update-root-<32 hex>.service`;
  - NO for anything else that unit asks;
  - untouched for every other subject.
  polkit 128 sets `system_unit` only from a pidfd it got from the bus (dbus-broker), which a process cannot forge. The review
  logged it: a unit of that name in the person's own manager is `user@<uid>.service`, and a pkexec subject has none.
- **Who can be in that unit.** Only root can create a system unit and its cgroup, and only the unit's own descendants are
  in it. The review confirmed this: writing `cgroup.procs` is refused, and `AttachProcessesToUnit` is refused for a unit that
  is not delegated. The helper creates the unit only after an administrator's password, only for this update's migrations
  (and the trial), and stops what is left within 5 seconds of their end.
- **Who could steer a process in that unit.**
  - The first version relied on Yama, which was wrong. Yama restricts attaching, not opening `/proc/<pid>/fd`. The review
    reopened the pipe on which the migration loop reads its list, and the standard input of a root command, from another
    process of the same uid, and got root.
  - The unit's own primary group closes that path. The kernel's `ptrace_may_access` requires all uids and gids to match
    unless the caller has `CAP_SYS_PTRACE`, for `/proc/<pid>/fd`, `environ`, `cwd`, `mem` and attaching alike. Measured:
    a process of the person's is refused the unit's pipe, environment, folder and temporary files.
  - NoNewPrivileges keeps the unit's processes from leaving that group (`newgrp`, `sg`). The person cannot join it: it has
    no member and a locked password, both checked before each run. RestrictNamespaces keeps them from making a user
    namespace the person would own. A file of the person's cannot carry the group's setgid bit, since the kernel clears it for
    an owner who is not a member.
- **What remains.**
  - **Signals.** They follow the uid: the person's other processes can stop or kill the unit's, or raise their
    `oom_score_adj`. That gives a delay or a failed migration, as in the terminal, never root. They can list the numbers of
    its descriptors but not open them.
  - **A root command that drops to the person itself** (`runuser`, `setpriv`) would make a process outside the unit's group,
    inside its `/tmp`. No 4.0.6 migration does; the shim's `-u` is refused for that reason.
  - **The person's own files that a migration reads.** A command a migration runs may read the person's configuration, in
    their home folder or their runtime folder. Their session's servers (bus, Hyprland) answer it.
  - **Omarchy's own terminal update has the same exposure, and more.** It authenticates `sudo` once (`sudo -v`, in
    `omarchy-update-stay-awake`). Any process in that terminal can then use the credential while it lasts, and can reopen
    its pipes.
  - **Grassfield's channel is narrower:**
    - one unit, for this update's own migrations, chosen by name;
    - only while they run;
    - only for an administrator who typed a password for it;
    - temporary files and `/proc` out of other processes' reach.
- **What a root command can do:** anything, as with `sudo`. That is the decision: the authorization of Update Now covers
  the `sudo` commands of the migrations Omarchy ships with this update in `/usr/share/omarchy/migrations` (root's files).
  Grassfield does not filter them; a filter would break migrations it cannot foresee.

### s5.4 What still goes to Omarchy's terminal (data: Omarchy 4.0.6)
Omarchy 4.0.4 → 4.0.6 adds 14 migrations. Under the two sets:
- four need root only: `1790114905`, `1791403252`, `1791581004`, `1791621765`;
- two need a person: `1790017600` and `1792334754`. They reach `gum` through `omarchy-install-hermes-cli` /
  `omarchy-install-openclaw-cli` → `omarchy-agent` → `omarchy-default-agent` →
  `omarchy-launch-floating-terminal-with-presentation`. That chain is a name the scan finds in a command's text, not a path
  known to run.
So that release still goes to the terminal: the scan stays conservative, and loosening it is a separate question. A release
whose new migrations only call `sudo` runs without one. A migration pending from before the update also sends the run to
the terminal, a rare case (Omarchy runs pending migrations at login).

### s5.5 Limits
- **Files a migration creates in the person's home get the group `grassfield-update`.** They are still the person's own
  (owner and permissions unchanged).
- **A migration's own `pacman -Syu` is not checked by s3.4.** For example, `1791403252` calls
  `omarchy-update-system-pkgs`; the same is true in Omarchy's terminal. Its changes to the packages s3.7 follows are read
  again and give the end its restart.
- **A process a migration starts to outlive it** (a detached daemon) is stopped with the unit. Omarchy's restarts that go
  through the user's systemd manager (`uwsm-app`, `systemctl --user`) are not affected.
- **A migration that needs a namespace of its own** (bwrap, flatpak, rootless podman, `unshare`), **or writes a file past
  64 MiB itself**, fails in the unit and stays pending for Omarchy's terminal. No 4.0.6 migration does either.
- **The migrations' output file on `/run` is bounded only for what the unit's own processes write.** Their root commands'
  output, which can include a boot image's build log, is cut to 8 MiB only when the migrations end.
- **The ownership checks are on paths, not on opened descriptors** (bash cannot run a program through a descriptor, and
  systemd-run takes a path). They hold because every folder they accept is root's alone, so only root could swap
  anything between the check and the run.
- **The channel needs** systemd ≥ 254 (`--expand-environment`), polkit with `system_unit` (128 measured), a bus that hands
  polkit a pidfd (dbus-broker 37 measured) and `JoinsNamespaceOf`. Anything else fails the trial, and the run goes to the
  terminal with nothing changed.
- **Root commands run in the unit's mount namespace** (its `/tmp`): a root `mount` made by a migration would not be seen
  outside. No 4.0.6 migration mounts anything.
- **The migrations' output is cut at 8 MiB only once they end** (it can grow on `/run` meanwhile). A cut that drops the end of
  a boot image's build says "Don't restart this computer yet", the safe side.
- **The scan does not follow `source`.** A migration that sources another migration file is judged by its own text alone
  (pre-existing from step 3; the review's NIT 11). It runs in the unit only if it is this update's.

### s5.7 The allow-list (rc7 audit R7-SEC-01, integrator's decision of 2026-11-08)
The word scans of s3.6 and s5 cannot be the guarantee: the rc7 security review listed the ways of running code from the
person's home folder that they miss (`zsh -c`, `bash -l`, `bash < ~/x`, AUR builds, `$XDG_DATA_HOME`, `eval "$(cat ~/…)"`,
`/home/$USER`, node, bun, ruby, pip, uv and more). The guarantee is now an allow-list: the run uses the migrations' unit only
when the Omarchy version being installed is a release of `packaging/pacman/omarchy-migrations.allow` (installed as
`/usr/share/grassfield/update/omarchy-migrations.allow`, root's alone; the helper refuses a list that is not, or that holds a
line it cannot read) and every migration it would run there has an `allow` line for that version. The line holds the
migration's closure: the migration, every file of the package a word of it names (`$OMARCHY_PATH/...`,
`$OMARCHY_INSTALL/...`, `/usr/share/omarchy/...`, anywhere: sourced, run, run directly or copied; a small folder with its
files), the `omarchy-*` commands it names, transitively, and a file under `/etc` it sources (listed, not hashed: it must be
root's alone), with the sha256 of the package files' "<file> <sha256>" lines. The closure is hashed in the new package before the transaction and in the installed tree (each
file root's alone, the same Omarchy version) just before the migrations run (the second security review: 1792474908 sourced
1786643346, an excluded migration that runs `python3 -c`, while the unit worked in the person's home, where a `json.py`
would have been imported). The list is generated by `scripts/dev/omarchy-migrations-allow.py` from each supported Omarchy
release (one per drift lock, `docs/upstream/omarchy*.lock`): 4.0.6-1 (120 migrations, 49 allowed) and 4.5.0-3 (218, 85
allowed). A migration is excluded when a file of its closure needs a person, reaches code of the home folder or the
generator's wider review patterns (other interpreters and package builders, login, interactive or `-c` shells, `eval`,
input or code under a home path, the XDG folders, `/home/`), when a package path or a source cannot be resolved (a
variable, the package root, a large folder), when it runs code the closure cannot follow (a pipe into a shell, `exec`, a
shell after a prefix word such as `env`, `timeout` or `as_root`, an `omarchy-*` name built at run time: the third security
review; 1781984677's `as_root env ... bash "$snapper_config_script"` is one), or when it
relies on its working folder (a relative path, `$PWD`, `cd -`; the generator flags 1781043107 for a literal `../` string,
conservatively). The unit now works from `/` with `PYTHONSAFEPATH=1` and `PYTHONNOUSERSITE=1`.
`tests/shell/omarchy_migrations_allow.sh` fails while a supported release is not listed whole. A release Grassfield has not
pinned yet brings unlisted migrations, so its update takes Omarchy's terminal until its lock and its list lines are reviewed.
The scans stay, as defence in depth. Root commands run from `/` (no `--same-dir`).

### s5.6 Evidence (this branch)
- **`tests/integration/update_migrate.sh` (new, A16): 69 PASS, 0 FAIL.** It runs in an `archlinux:base` container (CAP_SYS_ADMIN minus MKNOD, no device; it was `--privileged` until the
  2026-11-11 session losses, see docs/testing/README.md, and only runs in a VM now)
  with systemd 262 as PID 1 (cgroup2 mounted), dbus-broker 37, polkit 128, sudo 1.9.17, and the REAL helper, runner,
  policy, `sudo`, rule and group (no change to any of them).
  - **The channel:**
    - root id; standard input, folder, exit status, arguments and the unit's temporary files passed through;
    - `-u`, `-v`, `-n`, `-l`; `-E`, `-i` and an assignment refused; no lookup in the caller's PATH;
    - another unit name, a root unit name without its 32 hex digits, another verb on a root unit, and any other unit
      operation refused;
    - the real sudo blocked; nothing left.
  - **The review's MAJOR:** a process of the person's cannot open the unit's pipe, environment, folder or temporary files.
    The same holds for the helper's own unit during a real run, for each of its processes: the migration loop, the
    migration, the `sudo` and its `systemd-run` client. The migration's temporary file never reached the shared `/tmp`.
  - **`sudo -u` with another target is refused** (the re-review's MINOR 1); `-u root` and `-u #0` work.
  - **The integrator's review:**
    - no user namespace in the unit (the test's and the helper's);
    - an unknown letter in a cluster refused;
    - a command of the person's, or in a folder others can write, refused;
    - the root unit's environment is the fixed list;
    - a group with a password, a person whose own group is the unit's, and a migrations folder others can write, all go
      to the terminal.
    - Its three surviving mutants each fail the test now: `LD_PRELOAD` passed to the root unit, the locked-password check
      dropped, and the person's-group check dropped (RestrictNamespaces dropped too).
    - The test sets `umask 022`: `docker exec` runs with 0000 under systemd, so the test packages had world-writable
      folders, which the new ownership check rightly refused.
  - **The integrator's follow-ups after its PASS:**
    - a link kept in a folder others can write is refused, even to a root-alone program;
    - Omarchy's commands folder others can write sends the run to the terminal, and so does the sudo in such a folder;
    - a migration the transaction leaves writable by all: no migration runs with root, they stay pending.
  - **Refusals:** outside the unit, in another unit, and without NoNewPrivileges.
  - **The helper from a runner through pkexec:**
    - a user who is not an administrator goes to the terminal (the review's BLOCKER);
    - so does a run while the group has a member, while a migration from before the update is pending, with a rule that
      grants nothing, and with no rule;
    - for an administrator, the update installed, the migration ran as the person (its file the person's, group
      `grassfield-update`) with its sudo commands as root, a temporary file reached its root command, `migrations ran`,
      and its output was root's alone;
    - a failing sudo left the migration pending;
    - `gum`, and `sudo` with `gum`, went to the terminal;
    - root without pkexec's user has no person;
    - the unit's form outside the unit is a usage error.
  - **Mutants of the rule:** dropping its verb check or loosening its unit name each fail the test. `NO` → `NOT_HANDLED` is
    equivalent here: the unit has no session, so no agent and no implicit authorization.
- **`tests/integration/update_helper.sh` (step 3's, no systemd: the helper in place): 80 PASS, 0 failures.**
- **Probes before the design:** a pkexec subject never carries `system_unit` (polkit sets it only from a bus pidfd), so a
  rule on pkexec could not work. `systemd-run` from the unit carries it; unit names and verbs reach the rule as `unit` and
  `verb`. A primary group of its own keeps another process of the same uid out of a unit's `/proc` entries. A root unit
  can join a unit's private `/tmp`.
- **Not verified here:**
  - the whole flow on the owner's machine (L2);
  - a real Omarchy 4.0.6 migration that needs root;
  - the polkit dialog (the container lets the runner through).

## Review history
Software Update step 4 (PR #82), the integrator's opus review of b6fdedf: **PASS on its own**; with #77 merged first
(ADR-0041 step 2b, U31), three things before the merge, answered in the next commits:
- main merged; this PR's rule renumbered U33 (#77 took U31, #89 U32), the catalog keeping both sides' messages;
- **minor:** with Settings closed, #77's toolkit "Log out to finish updating" could follow the run's "Restart to finish
  updating" at the next automatic check. The run's restart or log out now marks this session's toolkit announcement made
  (`withToolkitCovered`; the pane's row stays); a unit test and a step of the service test;
- **nit:** a run still going on after an hour stopped holding GF-083's notice for good; the next run's end resets it.

Software Update step 4 (PR #82), an independent opus review of 9dbacaa7 while the integrator was away (read-only, mutants on
copies): **PASS**, no BLOCKER or MAJOR; five minors and six nits, answered in the next commit:
- **Minor 1**, step r did not test what it claimed: the same end written again was overwritten before it was read, and two
  waits never checked their condition (mutants M2, a lost reset of the run going on, and M5, `configuring` not counted,
  survived). The same end is now read alone after a pause, and each wait checks its condition.
- **Minor 2**, a Settings window in front hid every end, About This Computer and other sections included (a failed startup
  image's "Don't restart this computer yet" too): only a restart or a log out is skipped, and only for Settings' main window.
- **Minor 3**, a run whose AUR apps wait for Omarchy's terminal said "This computer is up to date.": its own notice.
- **Minor 4**, GF-083 posted "Log out to finish updating" during the run, then the run posted "Restart…"; a pkgrel-only
  rebuild of grassfield-desktop was announced by nobody: GF-083's notice waits for the run, the run's log out is posted with
  GF-083's text, and one notice says what finishes the update.
- **Minor 5**, a dev shell watched the real session's runs: dev plumbing `UPDATE_RUN_DIR` (ADR-0019).
- **Nits:** a relative `XDG_RUNTIME_DIR` is refused and `mkdir` gets `--`; the pane test checks the buttons enabled after a
  run; the terminal notice names Omarchy's terminal; precedence and the unannounced ends are in U33 and the limits; SU-D4 is a
  row of the decision table.

Software Update step 5 (SU-M2), the integrator's delta re-review of 935981b: **security PASS**; the merge waits for the
owner's agreement on the polkit rule and the group. Four small follow-ups, folded in before the merge:
- the folder that holds a link is checked too, every folder on the path as written;
- Omarchy's commands folder gets the same root-only check, before any change and after the transaction;
- the text no longer says `/run` stays bounded: the root commands' output is not bound while it runs, which is a limit in
  s5.5. Binding the root units instead would break a boot image's build or a package;
- tests for the after-install check of each migration file and for the helper's check of its sudo.

Software Update step 5 (SU-M2), the integrator's opus security review of db67a5f: **no MAJOR; the design holds** (the rule,
the empty group, removal leaving no grant). Required before the merge, answered in the next commit:
- **MINOR 1**, the unit could make user namespaces; one would belong to the person, whose other processes could reach into it
  and use the unit's grant. `RestrictNamespaces=yes` (with `LockPersonality`, `RestrictSUIDSGID`); the test checks
  `unshare -U` fails in the unit.
- **MINOR 2**, no ownership check before running. The migrations folder and the sudo must be root's alone before any change,
  and each migration file after the transaction; the sudo refuses a command that is not root's alone (its folders
  included).
- **Test gaps:** the root unit's environment is checked against a fixed list; a group with a password; a person whose own
  group is the unit's. The three surviving mutants each fail now.
- **Nits:**
  - an unknown letter in a sudo option cluster is refused;
  - the supplementary groups are described as systemd sets them;
  - `LimitFSIZE=64M` bounds the output on `/run` while it runs.
The owner sees the rule before the merge, as the integrator asks.

Software Update step 5 (SU-M2), the same reviewer's re-review of 3b41c95: **PASS**, no BLOCKER or MAJOR. It confirmed the
premise (Linux's `__ptrace_may_access` compares uids and gids), measured the unit's identity (gid `grassfield-update`,
NoNewPrivileges), and found both first-round attacks and the marker-deletion path closed. It also checked: `newgrp` refused,
setgid bits cleared, `cgroup.procs` and `AttachProcessesToUnit` refused, the `systemd-run` clients protected. Two minors and
six nits, answered in the next commit:
- **Minor 1**, reproduced to root through the real flow with a synthetic migration: `sudo -u <person>` made a process outside
  the unit's group inside its `/tmp`. The shim refuses any target but root; s5.3 says what a root command that drops to the
  person would do.
- **Minor 2:** the test now probes the helper's own unit during a real run, and checks the temporary file stayed out of the
  shared `/tmp`.
- **Nits:**
  - `wait_root_units` stops waiting, with a message, when systemd cannot list them;
  - the group must also have a locked password (`!`, `*`);
  - the copied loop is noted in `docs/upstream/omarchy.lock` beside `omarchy-migrate`'s pin;
  - s5.5 names the root units' mount namespace and when the output is cut;
  - s5.3 names signals.
  - The loop's differences from `omarchy-migrate` (no wait for a concurrent pacman, a fixed environment) are accepted: a
    concurrent pacman makes the migration fail and stay pending.

Software Update step 5 (SU-M2), an independent opus security review of b369f16 while the integrator was away: **FAIL**, 1
BLOCKER and 1 MAJOR, both reproduced in a container that runs systemd. The rule itself could not be spoofed, and the
helper's new inputs held. Answered in the next commit:
- **BLOCKER**, a non-administrator got root. Update Now is `auth_admin`, so a standard account gets an administrator's
  password for it, and the first version then ran the migrations as that account with root's sudo. Now the person must be
  in `wheel` (condition 3); a test runs a user outside it.
- **MAJOR**, Yama does not keep the person's other processes out. `/proc/<pid>/fd` is a read check, which Yama leaves
  alone. A process of the same uid reopened the pipe the migration list is read from, and a root command's standard input,
  and got root; it could also force a run by deleting a marker. The fix has three parts:
  - the unit runs under a primary group of its own with no member, which closes every `/proc` and ptrace access by a
    different gid (measured);
  - the unit has its own `/tmp`, joined by its root units;
  - the helper runs this update's own migrations by name instead of `omarchy-migrate`, and goes to the terminal while an
    older one is pending.
  Yama is no longer a condition. s5.3 now says what remains: the person's files, as in Omarchy's terminal.
- **Minors.**
  - The unit's leftovers get 5 seconds; the helper waits for the root units before it ends.
  - The packages a migration's own pacman changes are read again for the end.
  - The migrations' output is root's alone (0600, capped), no longer in the 0644 log.
  - The test now covers the rule's verb and unit name (the review's surviving mutants), a non-administrator, a group with
    a member, a pending older migration, root without a person, the unit form outside the unit, and a migration with both
    `sudo` and `gum`.
- **Nits.**
  - The spec's stale limit is fixed.
  - The counts are fixed (the earlier "41" counted the summary line).
  - The pkexec sentence is corrected.
  - `/usr/bin/id` is now called by its path.
  - `/usr/sbin/sudo` now counts as a sudo by its path.
  - The scan's `source` gap is listed in s5.5.

Software Update step 3 (PR #44), the integrator's re-review of 1ce7c37..0294373 (independent opus): **PASS**, with two
fail-open guards asked before the merge, answered in the next commits: an empty `pacman -Q` and an empty
`pacman-conf --repo-list` are refused (exit 8), and the runner's `omarchy-migrate --pending` must answer by its contract;
fault-injection cases for each (a wrapper in place of the real program). The nit (bsdtar -t exits 0 when it cannot write)
is answered by reading the listing through a pipe whose status is checked. The survivor M34 (a stale lock looked at once)
depends on timing and stays untested.

Software Update step 3 (PR #44), the integrator's re-review of a060504..1ce7c37 (independent opus): the first round's MAJOR
and minors confirmed fixed (30 mutants, 30 killed); FAIL on one new MAJOR, answered in the next commits:
- **MAJOR**, the scan failed open when `/tmp` could not be written: the member list came from a here-string, which bash
  writes to `/tmp` past a pipe's size. No here-string or here-document is left (s3.2 step 5); a new package without a
  migration, a migration name omarchy-migrate would run under another form and a member name with a pattern character fail
  closed; a test runs the helper with `/tmp` replaced by a file on a 3500-file package.
- **Minors:** the plan's loop has no here-string either, and text without a package is no "up to date"; a lock that looks
  stale is looked at again a second later; the `-T` names are pattern-free.

Software Update step 3 (PR #44), the integrator's independent opus security review of a060504: FAIL, one MAJOR, no path to
root escalation. Answered in the next commits:
- **MAJOR**, the migration scan found no Omarchy command (Omarchy 4.x has only links in `usr/share/omarchy/bin`): the scan
  reads the command files of `usr/bin/omarchy-*` and `usr/share/omarchy/bin/` (new package, else installed), fails closed
  without a command file or for a migration that is not a regular file, and the test package has the real layout (s3.6).
- **Minors:** more than 64 pending, or a name the helper refuses, sends the update to the terminal path (runner); the key
  check runs after the compatibility check; the swap takes pacman's own lock; the transient unit's stop (`KillMode=mixed`,
  `TimeoutStopSec=30min`, the run goes on once the system changes); `timeout -k` for the user's steps; a `db.lck` no process
  holds is said so, with the terminal path; a failure after the swap no longer says "Nothing was changed" (`synced`); the
  pane follows `last` when no runner's state is left (s3.5); Qt's `Qt_6_PRIVATE_API` residual risk recorded (s3.4); tests
  for the surviving mutants (the first `db.lck` check, `/dev/tty`, the plan's line check).

First opus review of PR #11 (integrator, 2026-10-27): FAIL, no blocker, 5 MAJOR. Each finding and where it is answered:
- **MAJOR 1**, a failing `[grassfield]` stops every update: a2 (Q1), mirrors, atomic publication (h.2, Q2), rotation
  overlap (b.4), detection and "Turn Off…" (O18, Q3).
- **MAJOR 2**, a check run under the update lock went stale: d.5, a waiter that checks once the lock is released (Q8).
- **MAJOR 3**, trust left behind: b.8, `off` and the two `pre_remove` steps delete the keys (Q6).
- **MAJOR 4**, the first installation: b.3a, a verified procedure; the owner kept the bootstrap (O17), and b.3 tests trust,
  not presence.
- **MAJOR 5**, "one value" did not hold for installed machines: h.3, the migration path (O19).
- **Minors:**
  - the quattro claim corrected (Q4);
  - migrations run where they act (Q5);
  - the trust test (b.3);
  - VALIDSIG argument 10 (Q7);
  - the checker's own lock, stale `db.lck` and stdin (d.1, Q8);
  - `fakeroot` declared;
  - the Omarchy pins (Consequences);
  - 4.0.6 rechecked (Context).
  The layout moved to a `[grassfield]` header in `pacman.conf`, because of 4.0.6's migration 1791403252 (Q4).

Second opus review (integrator, 2026-10-27): FAIL. Review 1's five MAJOR and its minors are confirmed closed. One new MAJOR
and minors, answered here:
- **MAJOR**, test keys trusted on the owner's machine through the O12 dependency: `grassfield-keyring` holds no key until
  O11 (owner decision O20, b.2, R1). Test keys are made per run inside containers only.
- **Minors:**
  - scriptlet verbs no longer depend on `PKEXEC_UID`: a separate program, and nothing reads the environment (c.1);
  - "Repair…" in `custom` rewrites the file (c.3);
  - `set` populates the installed keyring, and the keyring lives in a private folder that a plain `pacman-key --populate`
    does not reach (b.2, b.3, R2, R3);
  - rollback by a new snapshot (h.2, R4);
  - `blocking` after two failures in a row (a2.4);
  - the sandbox flag of the `[grassfield]`-only check, and why the containers use `DisableSandbox` (a2.4, R5);
  - b.3a ends with `grassfield-channel-set` (step 5);
  - stale text fixed (spec non-goals, ADR-0020's amendment), ADR-0030 amended;
  - the decisions table has its options again.
