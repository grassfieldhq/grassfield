# ADR-0043 — Public installation script (amends ADR-0033 b.3a)

Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (2026-11-03); the owner answered the open questions the same day (section "Owner decisions"). The script is
**prepared, not published**: hosting (O8) and the signing key (O11) are not chosen, and the legal review comes before any
public release. Cross-module (packaging, pacman helper contract, session login, boot and login themes, docs), hence its own ADR.
The script runs as the user and uses `sudo` for root steps, so it needs the opus security review before it ships; review 1
(2026-11-03) failed it on the keyserver trust and on a failed sync leaving the system blocked, both fixed below.

## Context
ADR-0033 b.3a documents a first installation of five manual steps (key by pinned fingerprint, `lsign`, the section and its
file, sync and install, `grassfield-channel-set`). The final-1.0 audit (11-installation-and-updates.md: INST-01, INST-06,
ARCH-08) found the path never run from a clean Omarchy, and Omarchy 4.0.4 ordered `[omarchy]` after `[extra]`, where extra's
quickshell 0.3.2-1 (its session lock fails open) wins and `grassfield-desktop` conflicts with it on purpose. This script is
b.3a automated, with its preconditions checked first, an exact way back, and the login and boot themes of ADR-0042 activated.

## Decision

### a. Where it lives, and who publishes it
`packaging/install/` in this repository:
- `grassfield-install.sh.in`, the template (bash, `set -euo pipefail`, every statement in a function, `main` called on the
  last line: that last line is what protects against a partial download, since a truncated file never reaches the call);
- `render.py`, which reads `packaging/pacman/repository.conf` with `packaging/pacman/generate.py`'s own parser (one source of
  truth) and writes `grassfield-install.sh` and `grassfield-install.sh.sha256` (`just render-install`).

`grassfieldhq/grassfield-packages` already reads `repository.conf` from this repository's checkout (g); its publishing job runs
`render.py` and uploads the two files next to the repository (`<base>/install/`), with the key file. Nothing here uploads.

### b. Host, fingerprint, and the test hook
Both are substituted at render time; the published script pins them as `readonly` constants. `render.py` **refuses** (exit 1,
nothing written) while the host ends in `.invalid`, the fingerprint is empty, or the base is not `https://`; the unrendered
template refuses to run (exit 2). The template carries one test hook (a file prefix read from the environment, used by
`tests/shell/public_install.sh`); `render.py` deletes its two marked lines unless `--test-hook` is given, refuses to write a
published script that still names it, and the test checks that the two renderings differ by exactly those lines.

### c. Trust model and the commands
**The key.** The pinned value is a full fingerprint F of a *primary* key. gpg accepts a downloaded key when F matches its
primary key **or any subkey**, and `pacman-key --lsign-key F` acts on whichever key holds F: a party on the path could serve its
own key K' carrying a copy of F's public subkey and have K' trusted for every repository (b.6). So pacman never sees an
unchecked key: the key is fetched from `hkps://keys.openpgp.org` (TLS) into a **temporary** gpg keyring and exported, or, when
the keyserver does not answer or returns something else, downloaded from the host's `.asc`; on **both** paths the file must
have exactly one primary key, equal to F, and no secret key. Only then `pacman-key --add` of that exported file and `--lsign-key
F`, and pacman's keyring must then show F as the primary of the key it holds, or the run is rolled back (section d).

**What the keys and checksum prove, and what they do not.**
- Packages are accepted only if their signature verifies against a key pacman trusts (`SigLevel = Required`); that key is the
  Grassfield key, **and a locally signed key is trusted for every repository** (b.6): anyone holding it can sign a package
  for `[core]` or `[extra]` too. That is the cost of installing Grassfield; it is removed by `--uninstall`.
- The script is checked with a SHA-256. A checksum fetched from the **same host** proves nothing against a compromised host or
  CDN, which can serve both. It protects against a truncated or corrupted download and against a mismatch with the copy
  published elsewhere (the README and the project site, b.3a's two out-of-band places): the user compares them.
- `curl … | bash` runs what the host serves at that moment, with no chance to read it or compare anything; it relies on TLS and the
  host alone. The download-check-run form lets the user read the file and compare the checksum with the other places.

**The commands** (placeholders until O8/O11), both published, the one-liner first:
```
curl -fsSL https://<host>/install/grassfield-install.sh | bash
```
```
curl -fsSLO https://<host>/install/grassfield-install.sh
curl -fsSLO https://<host>/install/grassfield-install.sh.sha256
sha256sum -c grassfield-install.sh.sha256 && bash grassfield-install.sh
```
The script reads the whole file before it runs a line, takes its answers from `/dev/tty` when piped, and asks for confirmation
after a plan, so even the one-liner stops at a screen listing every change.

### d. What it does, in order, and what it changes
Root is refused **before** the log is opened. Read-only **preflight** (all problems listed at once, each with its exact fix,
exit 1, nothing changed): sudo; Arch x86_64; Omarchy ≥ 4.0.6 (`pacman -Q omarchy`); `[omarchy]` before `[extra]` and
quickshell offered by `[omarchy]` (the repository field is parsed with `LC_ALL=C`: a French pacman prints "Dépôt"), never the
installed 0.3.2-N build; an existing `[grassfield]` section holding anything but the Include is refused; no `db.lck`, no
running Omarchy update; ≥ 4 GiB free; two HEAD requests to the host; `checkupdates` (required: it reads a copy of the
databases, so pacman's own are not touched) must succeed and show no pending update, and its failure is reported, never read
as "up to date". It **never edits the repository order**: it prints the remedy (move the whole `[omarchy]` block just after
`[options]`, the change `.claude/integrator/owner/omarchy-first.py` made on the owner's machine). Then a **plan screen** and a
confirmation (`--yes` skips it; `--dry-run` stops there; `--channel stable|beta`, `--session`, `--without-login-themes`,
`--no-snapshot`, `--help`; English or French from the locale). Omarchy's update lock is then held (released for
`grassfield-channel-set`, which refuses while it is held). Then:
1. **Snapshot**: `omarchy-snapshot create` (SU-M1's tool). Exit 127 (no snapper): continue, as Omarchy does; another failure
   stops, unless `--no-snapshot`.
2. **Key** (root), checked as in c.
3. **Repository** (root): `/etc/pacman.d/grassfield.conf` (`SigLevel = Required`, `Server = <base>/<channel>/$arch`) written
   when absent, or when the existing one is not exactly one `SigLevel = Required` plus https `Server` lines naming this host (the
   channel helper's own file, with mirrors, passes; `SigLevel = Never` does not, and the old file is kept as
   `grassfield.conf.grassfield-install-bak.<date>`); then `[grassfield]` + `Include` appended to `/etc/pacman.conf` when there
   is no such section, after a copy `pacman.conf.grassfield-install-bak.<date>` taken **by this run** (never an older one);
   `pacman-conf` must still list `grassfield`. File first, Include second (P2).
4. **Install** (root): `pacman -Sy`; `pacman -S --print` resolves dependencies and conflicts (Hyprland, Qt, quickshell) with
   nothing installed; then `pacman -S --needed grassfield-desktop grassfield-compositor grassfield-store grassfield-login-themes`.
   Dependencies (`grassfield-icons`, `-wallpapers`, `-keyring`) come with `grassfield-desktop`.
5. **Hand over**: `grassfield-channel-set <channel>` (its polkit prompt; the helper then owns the file and links Omarchy's hook).
6. **Session**: `grassfield-login set grassfield` (the package's `/etc/sddm.conf.d/grassfield.conf` already makes the "Grassfield
   (uwsm)" entry the one Omarchy's greeter picks; ADR-0042; INST-01).
7. **Themes** (root, unless `--without-login-themes`): `/etc/sddm.conf.d/zz-grassfield-theme.conf` (`[Theme] Current=grassfield`,
   the guide's one file; `/etc/sddm.conf` with its own `Current=` is reported, not edited); the boot theme as Omarchy does
   (`omarchy-plymouth-set`): `plymouth-set-default-theme grassfield`, then `limine-mkinitcpio` when present, else
   `mkinitcpio -P`. The previous theme name is remembered in the state folder. **The snapshot does not cover boot images**:
   `/boot` is the vfat ESP, outside the btrfs snapshot, so no snapshot can bring a boot image back. **No boot image is copied or
   restored** by the script: Limine records each installed image's BLAKE2 checksum in `limine.conf` (UKIs and hash checks are on
   in Omarchy), and `limine-mkinitcpio` installs each good kernel's image and its checksum but, when another kernel fails,
   only prints it and exits 0. Putting old images back would leave old bytes under new checksums and the boot would refuse
   them (and a `cp` into the ESP is not atomic). Failure is detected from the exit status **and** the output
   (`mkinitcpio failed for kernel`, as Omarchy's migration 1791621765 greps its log). On failure the previous theme is set back
   and **Omarchy's rebuild is run again**, the same command, which re-records the checksums of what it installs. If that second
   rebuild is clean, the script says the boot theme was **not changed** and why (exit non-zero, Grassfield stays installed). If
   it fails too, the script stops with what failed, that the computer may start the previous entry or a snapshot entry from
   Limine's menu, and the exact command to retry (`sudo limine-mkinitcpio`, else `sudo mkinitcpio -P`); it never says "back to
   normal" unless the second rebuild was clean, and "active" is printed only after a clean rebuild. The boot-theme step runs
   last, under the update lock. A boot problem found after a good rebuild is met with Esc at the disk prompt (text prompt),
   Limine's menu, or `--uninstall`, which switches the theme back and rebuilds again (the same two-rebuild logic). A theme
   failure ends non-zero with a warning but keeps Grassfield (ADR-0042's text-prompt fallback applies).

**Rollback (review 1, major 2).** Between the first change of step 2 and the end of step 4, **any** failure (a command, `Ctrl-C`,
the sync, the dependency check, a pending update after the sync, the install transaction) puts back the exact state: the
`[grassfield]` lines and `grassfield.conf` from **this run's** copies, the key if this run added it, the synced database files;
it says what happened and how to retry, and exits non-zero. pacman.conf is restored only when it is still exactly this run's
copy plus the two lines; a change made meanwhile (SigLevel hardening, `[multilib]`) is never undone, and the script then prints
the manual steps. After the packages are installed nothing is rolled back (Turn Off is then available); likewise, if the install
transaction fails after **some** packages went in (checked with `pacman -Q` against what was installed when the run started), the
repository and the key are kept and the message says exactly that and how to finish or remove. A refused install after a sync
leaves pacman's package lists synced, which the message says (run Omarchy's update before any `pacman -S`); a database that
existed before the run (a rerun) is never deleted by a rollback. A second `Ctrl-C` during the rollback is ignored (the ignored
disposition is inherited by sudo and what it runs), so the key is never left trusted by an interrupted rollback. `INT`, `TERM`
and `HUP` run the same rollback (status 130). The temporary gpg-agents are stopped on exit. The key is signed only **after**
pacman's keyring is checked to hold F as the primary of exactly one key (a key already there that merely carries F as a
subkey makes the run stop, nothing signed), and the "already present" test is primary-only. Omarchy's update lock is held from
the confirmation to the end, released only around `grassfield-channel-set` (which refuses while it is held).

Root is used only by the commands above, each through one `as_root` function that logs it. Idempotent: a rerun checks the key
again, skips what is done, repairs a missing file, never duplicates a line, and updates. Log: `${XDG_STATE_HOME:-~/.local/state}/
grassfield/install.log` (never through a symlink, created exclusively, mode 600 only when created).

### e. Undo: `--uninstall`
Reuses, never duplicates: snapshot; `grassfield-channel-set off` (Turn Off: section, file, keys, hook link); `grassfield-login set
omarchy` and the choice file deleted; the login theme drop-in removed and, when the boot theme is Grassfield's, the remembered
one (else `omarchy`) set again with the same rebuild, **before** the packages go; `pacman -Rns` of the installed Grassfield
packages (their `pre_remove` runs `off` again, b.8). Leftovers only if the packages were never installed or were removed by
hand: `pacman.conf` goes back from one of **this script's** copies **only when it is exactly that copy plus the two lines**, else
the script prints the manual fix and exits 1; the key is deleted when still present. The script's own copies are then removed.
Omarchy is never modified, so stock Omarchy is back after one restart.

### f. Tests
`tests/shell/public_install.sh` (logic layer): render refusals and the hook-stripping check, then the rendered script on **stub**
commands in a fake root (the script's `PATH` holds only stubs and harmless coreutils, so nothing real can run): each preflight
failure, dry-run, the exact root commands in order, idempotent rerun and repair, the key on both paths (a stub keyring whose
SUBKEY, not its primary, matches F; a secret key; a substituted key), the post-add keyring check, a rollback test for each
failure point (sync, resolution, install, pending update, unreadable conf, lsign, keyring), rollback keeping a pre-existing
key, an old `grassfield.conf`, and a concurrent edit, themes and `--without-login-themes`, the rebuild fallback, uninstall
(also with leftovers and with an edited pacman.conf), French, the log. Mutation check: removing the secret-key test makes four
cases fail. shellcheck runs when installed (**NOT VERIFIED** where it is not).

### g. Container test in grassfield-packages (described, not done here)
As `tests/integration/update_helper.sh` does: an `archlinux:base@sha256:…` container, a local `[omarchy]`/`[extra]` stand-in
and a signed `[grassfield]` repository built with a throwaway key, `render.py` run with a conf whose base is served by a local
`https` server, the real script run as an unprivileged user with passwordless sudo, asserting the same cases against real pacman
(and a real gpg keyring with a subkey-carrying impostor). That repository owns it; this one's test covers the logic.

## Owner decisions (2026-11-03, asked by the integrator)
| Id | Question | Options | Recommended | Decision |
|---|---|---|---|---|
| IN1 | Grassfield as the next-login session at install? | yes (`--session grassfield`) · no (`--session omarchy`) | yes | **yes, by default**; `--session omarchy` opts out; uninstall restores Omarchy |
| IN2 | Login and boot themes (`grassfield-login-themes`) | not by default · install and activate | no (recommended) | **install AND activate by default**; `--without-login-themes` opts out; install and uninstall handle the SDDM drop-in and Plymouth, the boot image rebuilt the way Omarchy does; the snapshot does not cover `/boot` and no image is copied or restored: a failed rebuild sets the previous theme back and runs Omarchy's rebuild again, and a second failure stops with the retry command and Limine's menu as the way out |
| IN3 | Command published | download-check-run · `curl \| bash` · both | download-check-run | **both**: the one-liner first, the download-check-run form below it; the docs say what each protects against |
| IN4 | Minimum free space and Omarchy floor | 4 GiB, 4.0.6 | as built | **as built** |
| IN5 | The `[omarchy]` order | print the fix · opt-in fix | print | **print the fix** |
| IN6 | Snapshot failure other than "no snapper" | stop · warn | stop | **stop**, `--no-snapshot` overrides |
| IN7 | Languages | EN + FR · EN | EN + FR | **EN + FR** |
| IN8 | Where the checksum is published | host, README, site | all three | **host, README and site** |

### h. Activation (owner decision of 2026-11-04)
The owner decided to publish the repository at `https://packages.grassfield.site` now, **unannounced** (no link from the site,
the site stays noindex), before the legal review, which stays mandatory before any public announcement. This amends ADR-0033
h's "activated after the legal review" (recorded there too). `repository.conf` now carries
`GRASSFIELD_SIGNING_FINGERPRINT=E4921A382C349308BAA50D2F44C31B5D862EBEFA` and `grassfield-signing-key.asc` holds the owner's
public key (v4 EdDSA, one primary, no subkey), so `just render-install` renders the real script (sha256
`c395efb528b93bcc0ea2f6a43d1fed8bba7ae4d364ce62bc4e79263740964df2`, to be recomputed whenever the template, the conf or `VERSION` changes: all three are inputs of the render, and `VERSION` decides the default channel; the checksum is served from the same host as the script, a known limit: it guards against a damaged download, not a compromised host, until the site and the README carry an independent copy). Rendered files are build output (`build/install/`, ignored
by the repository) and are not committed.

**Amendment (owner decision of 2026-11-05).** The owner asked for the site to give the installation: the official site's
Download page (grassfieldhq/website) now carries the install script's two command forms (IN3 order), the requirements (the
script's own checks), the options, the signing key's fingerprint and the script's SHA-256 (IN8: the independent copy). This
lifts "no link from the site" above; the rest stands: the site stays noindex, the channel is beta only, and the legal review
stays mandatory before any public announcement (no promotion beyond the page). The site's checksum must change with every
render of the script.

Bucket keys, so that the documented commands work (the bucket is `grassfield`, objects are served at the base):
`install/grassfield-install.sh` and `install/grassfield-install.sh.sha256` (both `Cache-Control: no-cache`), and
`grassfield-signing-key.asc` at the root (the script's host-file fallback, `$GF_BASE/grassfield-signing-key.asc`). The owner
uploads them with `wrangler r2 object put` (commands in the maintainers' private hosting notes); the packages arrive with the
first run of grassfield-packages' publishing job.

**Installer default channel (owner decision O15b of 2026-11-04, ADR-0033).** `render.py` takes the default channel from `VERSION`
(`--version-file`, default the repository's): `X.Y.Z-betaN` / `X.Y.Z-rcN` renders `CHANNEL=beta` and `GF_STABLE_EMPTY=1`, a plain
`X.Y.Z` renders `CHANNEL=stable` and `GF_STABLE_EMPTY=0`, anything else is refused. While stable is empty, `--channel stable` (and
`--dry-run --channel stable`) exits 2 from argument parsing, before the log, root, network or any file is touched, with a message in
English and French; `--uninstall` is not affected. The first published script is rendered from `1.0.0-rc2`.

**The channel rule on the installed system (ADR-0033 O15b, same decision).** The render-time default above is the script's half.
The installed half is one rule, applied by Settings, `grassfield-channel-set`, the root helper's `gf_set` and the Store: an installed
`VERSION` that is a prerelease, or missing, empty, unreadable or malformed, can only follow beta; a plain `X.Y.Z` can follow stable.
The script ends with `grassfield-channel-set beta` on a prerelease, which the rule always allows.

## Consequences
- `just render-install` refuses a conf with the `.invalid` host or an empty fingerprint, by design. It succeeds since 2026-11-04 (h).
- A source build (`makepkg -si`, the owner's flow) is unaffected; the script targets users of the repository.
- The default install changes the boot screen and rebuilds the boot image (root, minutes): ADR-0042's owner-run guide
  (`docs/owner-setup/login-boot-themes.md`) remains the reference for the fallback and for the manual revert; the owner's
  first-boot test (Esc at the disk prompt) is still the check that cannot be made offline (NOT VERIFIED here).
- Hyprland is never pinned (packaging rule): a Hyprland newer than the plugin's ABI degrades the session (C2) rather than failing
  the install; the exact dependency check is pacman's own dry run after the sync.
- Review: security (root steps, trust bootstrap, boot image) with opus before any publication; the legal review precedes it.
