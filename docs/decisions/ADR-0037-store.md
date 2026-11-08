# ADR-0037: Grassfield Store: an app that installs, opens and uninstalls apps through pacman and Omarchy, with a signed catalog
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (cloud session, owner brief 2026-10-27, step 0; docs only, no code in either repository before the opus
PASS). The owner answered ST1 to ST10 on 2026-10-27, recorded below in the owner's own words. Later questions follow the
owner's working rule of 2026-10-27: decided in this session, recorded in "Decisions delegated by the owner" (SD1 to SD5,
then SD6 to SD10 with step 2, SD11 to SD17 with step 3a, SD18 and SD19 with step 3b1, SD20 to SD23 with step 3b2, SD25 to
SD31 with step 3c, SD32 to SD35 with step 4), checked
by the integrator. The first opus review (FAIL, 3 MAJOR) and the counter-review (FAIL, 1 MAJOR) are answered in
"Review history". · Date: 2026-10-27 · Decider: owner (ST1 to ST10), delegated (SD1 to SD5), integrator (merge after the
opus PASS) · Number: 0037 (0033 Software Update, 0034 clipboard, 0035 dialogs and 0036 tiling are merged)

This ADR is also part of the contract between this repository (the app, `apps/store`, packaged as `grassfield-store`) and
`grassfieldhq/grassfield-packages` (the catalog Grassfield edits: the Discover selection, the sections, the categories and
our texts, built and signed there). That contract extends ADR-0033's (channel URLs and tree, signing key, trust, atomic
publication), and this PR amends ADR-0033 where the Store needs it (d, g, h.2; section "Amendments"). Parity with macOS 27:
`docs/audits/store-2026-10-27/parity.md`. Behaviour, keyboard, accessibility, refusals and limits: `docs/specs/store.md`.
Evidence: the probes S0 to S15 of `docs/audits/store-2026-10-27/store-probes.sh`, S16 to S18 of `store-probes-2.sh` and S19
of `store-probes-3.sh`, each run in a throwaway `archlinux:base` container, outputs next to them. Legal points are marked "needs legal review"
(master-prompt §14); none is a conclusion.

## Context

### The owner's brief (2026-10-27)
- An app with the look of the macOS 27 store application (Discover, categories, product pages, search, updates) that
  installs, opens and uninstalls apps on Grassfield.
- Two repositories. Here: the app in `apps/store` with the shared design system (`ui/Grassfield/Ui`), tokens, translations,
  tests and the single build definition (ADR-0023), shipped as its own package `grassfield-store` from the same PKGBUILD (as
  `grassfield-compositor`). In grassfield-packages: the catalog Grassfield edits, published and signed beside each channel's
  repository with the same key, under ADR-0033's contract. It changes without a Grassfield release.
- Never an install without an explicit click and an authentication; the source and the licence always shown; a warning
  for the AUR; no root execution outside pacman or Omarchy; offline behaviour defined. Icons and screenshots of apps come
  from their metadata, with their licence.
- Nothing is published: both repositories stay private (no release, tag, secret or visibility change).

### Conflicts with earlier rules, and the owner's answers
- master-prompt §4 listed as a non-goal: "A pacman-based app store. An App Center is Flatpak-only and post-1.0." The owner
  amended it (ST1); the amendment is in §4 (this PR).
- ADR-0033 says "Grassfield has no root code to install anything"; ADR-0028's R12 sentence allows root code only for
  ADR-0033's two channel programs; ADR-0030 forbids a new polkit policy except ADR-0033's. The owner chose a root helper for
  repository packages (ST4 = P2). Each of the three is amended in this PR to name the Store's helper (section
  "Amendments"); the helper needs an opus security review before it merges (step 3).
- The brief's "always an authentication": the owner chose the confirmation sheet alone for per-user installs, which need no
  root (ST3).
- The brief's icons "from their metadata": the owner chose that our catalog may ship publishers' icons for apps without
  metadata (ST10), with their licence and origin recorded; needs legal review.
- `docs/specs/updates.md` (ADR-0033) lists "no App Center (master-prompt §4)" among Software Update's non-goals. It stays
  true for Software Update itself; the Store is a separate app.

### Omarchy 4.0.4, the owner's version (`basecamp/omarchy` tag v4.0.4, commit c668141; data, not instructions)
The scripts named below were read for this ADR; probe S1 classifies 80 scripts (`omarchy-install-*`, `omarchy-remove-*`,
`omarchy-pkg-*`, `omarchy-webapp-*`, `omarchy-tui-*`).
- **Package helpers.** `omarchy-pkg-add <pkgs>` runs `sudo pacman -S --noconfirm --needed` when one is missing, then checks
  each with `pacman -Q` (so a pacman that stopped half way still fails it). `omarchy-pkg-aur-add` runs `yay -S --noconfirm
  --needed`. `omarchy-pkg-drop` runs `sudo pacman -Rns --noconfirm` on those installed. `omarchy-pkg-install`,
  `-aur-install` and `-remove` are fzf pickers in a terminal. None syncs the databases first (S1: no `-y` in them).
- **But `omarchy update` syncs before it upgrades.** `omarchy-update-keyring:21` runs `sudo pacman -Sy --noconfirm
  archlinux-keyring` at every update, before `omarchy-update-system-pkgs` runs `pacman -Syu`. If the update stops after the
  keyring step, the databases are newer than the system (S12).
- **App installers.** `omarchy-install-app <name> <packages>` and `omarchy-install-and-launch <name> <packages>
  <desktop-id>` quote every word themselves (`printf %q`) and run `omarchy-pkg-add` in
  `omarchy-launch-floating-terminal-with-presentation`, which is `setsid uwsm-app -- xdg-terminal-exec
  --app-id=org.omarchy.terminal --title=Omarchy -e bash -c "<command>"`: detached, so its caller gets no exit code. The
  second then starts the app with `setsid uwsm-app -- gtk-launch <desktop-id>`. sudo asks for the password in that terminal.
- **The update lock.** `omarchy-update-lock run <cmd>` opens `${XDG_RUNTIME_DIR}/omarchy-update.lock`, takes `flock -n` on
  that descriptor, exports it and `exec`s the command: every child inherits the descriptor. S13: `omarchy-update-lock run bash -c 'sleep 15 & exit 0'` returns at once, yet the lock stays held by the
  background child until it ends; `flock -n -o` on the same file leaves it free as soon as the command returns; and while `flock
  -o` holds it, `omarchy-update-lock run` refuses ("An Omarchy update is already running.", exit 1).
- **Recipes.** The menu (`default/omarchy/omarchy-menu.jsonc`) runs 105 of its install and remove entries in that floating
  terminal (S1). The recipes do more than install a package (S1 table):
  - service setups enable system units with sudo (`omarchy-install-service-tailscale`, `-nordvpn` also adds the user to a
    group and offers a reboot, `-sunshine`, `-once`); browser setups create root-owned policy folders under `/etc`
    (Chromium-based browsers) or in the browser's `distribution` folder (Firefox, Zen) and copy Omarchy's Chromium flags;
  - `omarchy-install-gaming-lutris` runs pacman twice (`omarchy-pkg-add`, then the 32-bit graphics libraries) and then
    rewrites `/usr/bin/lutris`'s first line with `sudo sed -i`;
  - `omarchy-install-gaming-geforce-now` downloads NVIDIA's installer with curl and runs it; `-battlenet` downloads a Windows
    installer and runs it under Wine; `omarchy-install-dev-env` pipes `curl … | sh` for several languages;
  - 11 removal recipes delete user data with `rm -rf` (S1 "rm-home"): Steam's game libraries (`~/.steam`,
    `~/.local/share/Steam`), Heroic's (`~/Games/Heroic`), Battle.net's Wine prefix, and others;
  - `omarchy-remove-launcher-entry <desktop-id>` (hidden, used by Omarchy's launcher) removes a web app, a TUI, a user entry,
    a pacman package (`sudo pacman -Rns` in the floating terminal) or a Flatpak (`flatpak uninstall`).
- **Where the recipes' packages come from (S2, by name on Omarchy stable).** 22 from `[extra]`, 2 from `[multilib]`, 30 from
  `[omarchy]` (243 packages: prebuilt `google-chrome`, `brave-bin`, `visual-studio-code-bin`, `spotify`, `1password`, …), 1 not
  found by name (`libappindicator-gtk3`). The recipes that call `omarchy-pkg-aur-add` (Chrome, Brave, Edge, Zen, Emacs) name
  packages `[omarchy]` serves prebuilt.
- **Omarchy's own apps.** `install/omarchy-base.packages` (150 lines) lists what an Omarchy install brings, among them
  `chromium`, `libreoffice-fresh`, `mpv`, `nautilus` and `obsidian`.
- **Web apps.** `omarchy-webapp-install <name> <url> <icon>` writes `~/.local/share/applications/<name>.desktop` (Exec
  `omarchy-launch-webapp "<url>"`; the name keeps its spaces: "Example Mail.desktop", S9) and an icon under
  `~/.local/share/icons/hicolor/256x256/apps/`, as the user, no root. It refuses a name with `/` and a URL that is not
  http(s) or has whitespace. Given a local icon file it makes no network request (S9: 0 calls); given an icon URL or nothing
  it downloads from that URL, the site and, as a last resort, Google's favicon service. `omarchy-webapp-remove <name>`
  removes both (S9). `omarchy-launch-webapp <url>` starts the browser itself with `setsid uwsm-app -- <browser> --app=<url>`.
- **Updates.** `omarchy update`: snapshot, keyrings (the `-Sy` above), `pacman -Syu`, migrations, `yay -Sua` for AUR packages
  (`omarchy-update-aur-pkgs`), mise, orphans; under the update lock. No Flatpak update. Omarchy installs a Flatpak only for
  GeForce NOW; its launcher can remove any Flatpak.

### Arch Linux facts measured here (S3 to S18)
- **A database newer than the system breaks installs (S4).** System at the Arch snapshot of 2026-03-01 with python, gtk3,
  qt6-base and ffmpeg; database of 2026-10-20 (`pacman -Syy` without `-u`; 220 of the 322 installed packages have newer
  versions in it). `pacman -S gimp` is refused: "installing libjxl (0.12.0-1) breaks dependency 'libjxl.so=0.11-64' required
  by ffmpeg" (the same for x265); `blender` and `thunderbird` cannot be resolved either; `pacman -S mpv` would upgrade the
  installed `ffmpeg`, `libbluray` and `libvpx` alone. With the database the system was upgraded from, gimp's plan installs
  44 packages and upgrades nothing installed. The rule is Arch's (wiki, System maintenance: "Partial upgrades are
  unsupported"). Nothing in Grassfield may run `pacman -Sy`.
- **A plan can look clean while the database is ahead (S12).** After Omarchy's keyring line (`pacman -Sy --noconfirm
  archlinux-keyring`) and an update that stops there, `pacman -Qu` lists 122 packages, while `pacman -S --print
  inkscape` installs 61 packages and upgrades 0 installed ones (so do gimp, vlc, mpv, jq, ripgrep, fd, tree and nano): a
  check of the plan alone accepts it, yet the
  new packages come from a database the system was never upgraded to. Only `pacman -Qu` sees it. With `IgnorePkg`, pacman
  marks the held package "[ignored]" (S12: "adwaita-cursors 50.0-1 -> 51.0-1 [ignored]").
- **A database older than the mirror fails cleanly (S5).** System and database at 2026-09-01, Server = Omarchy's stable
  mirror (2026-10-22): `pacman -S fd` asks for `fd-10.5.0-2`, the mirror answers 404, "failed to commit transaction", exit 1,
  nothing installed. The cure is a full update first.
- **Interrupting pacman (S6: 110 packages, none installed before, a signal sent to pacman itself during the commit).** SIGINT
  and SIGHUP stop after the current package and **exit 0** with 15 and 11 of 110 installed. SIGTERM (exit 143) and SIGKILL
  (exit 137) leave `db.lck` (the next pacman refuses: "unable to lock database"), an incomplete database entry for the package being
  extracted (`pacman -Dk`: "description file is missing", "file list is missing") and some of its files on disk with no
  owner (7 and 10). So an exit code alone says nothing about success, and nothing may signal pacman. A real terminal closing,
  with sudo between it and pacman, was not tested: NOT VERIFIED.
- **One transaction at a time (S11).** With `db.lck` held: "failed to init transaction (unable to lock database)", exit 1.
- **What a user can read and ask (S10).** `/var/log/pacman.log` (0644) and `/var/lib/pacman/local` (0755, its mtime changes
  on each transaction); `pacman -S --print`, `pacman -Sp` and `pacman -Rs --print` answer as the user, without root or the
  lock (`-n` cannot be combined with `--print`); a removal that would break another package is refused there too ("removing
  glib2 breaks dependency … required by accountsservice"); `pacman -Qlq`/`-Qqo` map a package to its `.desktop` file and back.
- **uwsm's desktop ids (S14).** uwsm 0.27.1's `misc.py:87` accepts a desktop entry id only if it matches
  `\A[a-zA-Z0-9_][a-zA-Z0-9_.-]*.desktop\Z`: "example-mail.desktop" matches, "Example Mail.desktop" (the name
  `omarchy-webapp-install` writes, S9) does not. So a web app is opened by its URL, never by its entry's file name.
- **What a removal rule must see (S16).** Omarchy 4.0.4's `omarchy-base.packages` omits the kernel, the firmware, `base`,
  `sudo`, `systemd` and the boot tools; its `omarchy-other.packages` has them (`base`, `linux-omarchy`, `linux-firmware`,
  `limine`, `snapper`, `btrfs-progs`, …; 204 names in the two lists), and pacman's `HoldPkg` is only `pacman glibc`. b.1's
  rule (explicit, an application entry, the deny list, the whole plan) refused every system package S16 registered (linux,
  sudo, systemd, limine, snapper, btrfs-progs, base, pacman, glibc), a command-line tool (tree: no entry), an app pulled in as
  a dependency (galculator), an Omarchy app (btop) and a local app whose plan takes a boot tool with it (`probe-app`: `pacman
  -Rs --print` lists probe-app, efibootmgr, efivar); it allowed xterm (its plan: xterm and seven libraries). The deny list
  denied all 252 names checked (Omarchy's two lists, the fixed list, HoldPkg and ten variants such as `linux-zen`,
  `sof-firmware`, `yay-bin`); without Omarchy's lists the rule refused everything. pacman refuses `-Rns --print` ("'--nosave'
  and '--print' may not be used together", exit 1): the plan is read with `-Rs --print`, which lists what `-Rns` removes.
- **Polkit and the Store's action (S18, polkit 127-3).** An action's `<message>` may hold `$(command_line)`: pkexec puts the
  program and its arguments in the details (`command_line`, polkit 128 `src/programs/pkexec.c:864`), and polkitd expands
  `$(…)` in the message before any agent sees it (`src/polkitbackend/polkitbackendinteractiveauthority.c:2327`). S18's agent
  showed "Authentication is required to install or remove apps: /usr/lib/grassfield/grassfield-store-helper install
  0123456789abcdef0123456789abcdef xterm". Only trusted callers (uid 0, as pkexec is, or the action's owner) may pass details
  (`polkitbackendinteractiveauthority.c:1130`). With `auth_admin`, each of three calls asked for the password, two of them from
  one process. What `auth_admin_keep` keeps in a session is NOT VERIFIED: in the container pkexec registers its own text agent
  for each call and there is no logind session, and it kept nothing there either.
- **AppStream for Arch (S3, S15).** `archlinux-appstream-data` 20261017-1 (`[extra]`, 20.6 MiB download, 21 MiB installed):
  `/usr/share/swcatalog/xml/extra.xml.gz` (8.2 MB) has 1390 desktop applications, all with `pkgname`, a desktop-id
  `launchable`, categories and a cached icon; 946 with `project_license`; 916 with screenshots, hosted on 280 different hosts
  (raw.githubusercontent.com, cdn.kde.org, gitlab.gnome.org first). Its 3860 cached icons are JPEG XL (`.jxl`). `[core]` has
  none, `[multilib]` one (Steam), `[omarchy]` none: Spotify, 1Password, Heroic, Visual Studio Code, Chrome have no AppStream
  entry. `appstreamcli search` reads the pool as a user. Without the package
  installed, a user can fetch the package file from pacman's own mirror (`pacman -Sp`): it has the SHA-256 pacman's sync
  database lists (S15: 21 563 985 bytes), but Arch's databases are not signed, so that match alone proves nothing. The
  package's own signature sits beside it on the mirror (`<url>.sig`, 310 bytes) and a user can check it by pacman's own rule
  (S17): pacman's keyring is readable by everyone (`/etc/pacman.d/gnupg` 0755, `pubring.gpg` and `trustdb.gpg` 0644);
  `pacman-key --verify` runs as the user ("Note: trustdb not writable" is all it adds), shows `[GNUPG:] TRUST_FULLY` for Arch's
  signer and exits 0; with one byte of the file changed it exits 1. Arch's other copy, on sources.archlinux.org, carries no
  signature. **Corrected after the step-1 review (S19):** S17 never tried a signer pacman does not trust, and its exit code
  does not say trust. With a throwaway packager key in pacman's keyring, `pacman-key --verify` (pacman 7.1.0) exits 0 for a
  good signature while gpg says `TRUST_UNDEFINED` (the key added, not locally signed); its trust test reads
  `${PIPESTATUS[1]}` after a `[[ ]]` has reset it, so it never runs. gpg says `TRUST_FULLY` once the key is locally signed,
  and still `TRUST_FULLY` once the key is disabled (what `pacman-key --populate` does to a revoked packager): only the key
  listing shows it (capabilities `scSCD`). A signed message given as the `.sig` makes gpg exit 2 (NODATA). So the Store reads
  gpg itself (c).
- **The AUR (S7).** RPC v5 `info` gives Name, Version, Description, Maintainer, NumVotes, Popularity, OutOfDate,
  LastModified, License, URL, URLPath, Depends, OptDepends, Keywords, FirstSubmitted. `search` by name answers
  in one request (72 results for "chrome"). The whole-AUR dump `packages-meta-v1.json.gz` is 10.6 MB (123 087 packages, no
  licence field, served with `cache-control: max-age=300`); `packages-meta-ext-v1.json.gz` 14.6 MB.
- **Flatpak and Flathub (S8).** `flatpak` 1:1.18.2-1 (Arch's archive of 2026-09-01) adds 20 packages to the probe's machine; 2 (pipewire, python-gobject) of them are in
  Omarchy 4.0.4's package lists. `flatpak remote-add --user flathub …` works as a user without root (the user owns
  `~/.local/share/flatpak`). Flathub lists 3502 apps; its AppStream is 10.8 MB compressed plus a 50.9 MB uncompressed copy;
  117 MB under `~/.local/share/flatpak` before any app. No app was installed (runtimes are hundreds of MB): NOT VERIFIED.
- S5 to S15 ran on Arch's archive snapshot of 2026-09-01 (S12 moves the database to 2026-10-20), S1 to S3 on Omarchy's stable
  mirror. S16 to S18 (`store-probes-2.sh`) ran on the same 2026-09-01 snapshot. S19 (`store-probes-3.sh`) needs no network:
  pacman 7.1.0 and gnupg 2.4.9 of the image itself.

### The owner's machine (integrator's survey, 2026-10-27)
pacman, yay and the `appstream` library are installed; flatpak, PackageKit and `archlinux-appstream-data` are not. The owner's
own `makepkg -si` builds of `grassfield-*` are foreign packages (`pacman -Qm` lists them; integrator's check).

### Grassfield today
- `apps/` holds the Grassfield apps (Settings, Files, Preview, helpers), each a Qt/QML front end over a C++ backend, built by
  CMake (ADR-0023) and packaged by `packaging/arch/PKGBUILD` (split packages `grassfield-desktop`, `grassfield-compositor`,
  `grassfield-icons`).
- ADR-0011: one launch path; native apps start applications with `apps/appscope.h` (`uwsm-app -- …` in a real session,
  through `QProcess::startDetached`: no exit code comes back).
- ADR-0018: badges are set by the application itself (Unity LauncherEntry through the menu bridge).
- ADR-0019: one run-mode rule; dev plumbing honoured only in a dev session.
- ADR-0020: persisted files (config, state), single writer of `grassfield.json`.
- ADR-0030: privileged changes through the system services' own polkit actions; amended for ADR-0033's channel helper.
- ADR-0033 (merged 609017f after its opus PASS; status Proposed): the `[grassfield]` repository in two channels, one signing
  key in CI, `grassfield-keyring` (its files in the private folder `/usr/share/grassfield/pacman-keyring/`, no key until the
  owner's exists, O20), signed release notes verified with `gpgv`, atomic publication by snapshot and pointer, Software Update
  (its checker in the shell, the Settings pane, the Dock badge on Settings for Grassfield and Omarchy releases, "Update Now" =
  Omarchy's update in its floating terminal), and two root programs for the channel only.

## Decision

### Overview
```
grassfieldhq/grassfield-packages                     grassfieldhq/grassfield: apps/store → package grassfield-store
  catalog/ (texts, sections, categories, icons)        grassfield-store (Qt/QML + C++, runs as the user)
     └ one serialized publisher per channel:            ├ catalog: fetch (https), gpgv, validate, cache
       build from the current snapshot →                ├ sources: pacman, AppStream, Omarchy recipes, web apps, AUR RPC, flatpak
       grassfield-catalog.v1.json + .sig +              ├ plan check: pacman -Qu empty, -S --print, mirror, locks
       catalog/<sha256>.png → conditional               ├ queue, one operation at a time, each ending with an exit code:
       pointer write (ADR-0033 h.2 amended)             │   repository packages → pkexec grassfield-store-helper (root, pacman only)
                                                        │   AUR, Omarchy setups → Omarchy's terminal → grassfield-store-run (user)
                                                        │   web apps, Flatpaks  → the Store's own children (user)
                                                        ├ success = exit code 0 AND the system's state
                                                        └ Open: ADR-0011 (uwsm-app -- <id>.desktop; web apps: omarchy-launch-webapp <url>)
Updates: ADR-0033's checker (shell) → software-update.json → the Store's Updates page; "Update All…" = ADR-0033's "Update Now"
```

### a. Sources (owner, ST2)
Every app in the Store comes from one source, shown on its button row, its product page and its confirmation sheet:

| Source | What | Installed by | Default |
|---|---|---|---|
| Arch repositories | `[core]`, `[extra]`, `[multilib]` through Omarchy's mirror | the Store's helper (b.1) | on |
| `[omarchy]` | Omarchy's own repository (prebuilt Chrome, Spotify, VS Code, 1Password, …) | the Store's helper (b.1) | on |
| Omarchy setups | Omarchy's `omarchy-install-*` recipes our catalog lists, each with what it changes, written after reading it | the recipe, in Omarchy's terminal (b.2) | on, except the recipes that download and run code outside pacman (GeForce NOW, Battle.net, dev environments, and those that install through mise or a language installer, such as Hermes) |
| Omarchy web apps | sites our catalog lists | `omarchy-webapp-install`, as the user (b.3) | on |
| AUR | user packages, not reviewed by anyone | `omarchy-pkg-aur-add` (yay), in Omarchy's terminal (b.2) | **off until turned on** in the Store's settings; the warning on every install |
| Flathub | Flatpak apps, sandboxed, per-user installs without root | `flatpak --user`, as the user (b.3) | **off until turned on**, and offered only when `flatpak` is installed (an `optdepends`, no dependency added); without it the settings offer "Get Flatpak…" (b.2, SD24) |

An app that exists in several sources shows the first of: Omarchy setup (it configures what Omarchy configures), Arch or
`[omarchy]` package, Flathub, AUR. The catalog can pin a source per app.

**Flathub.** Turning it on adds the Flathub remote to the user's installation (`flatpak remote-add --user --if-not-exists
flathub https://dl.flathub.org/repo/flathub.flatpakrepo`, S8, S21: a second, no root) and fetches its AppStream; turned on
while offline, it is added once the Store is online. Everything happens in that installation, as the user, without root or
terminal: `flatpak install --user --noninteractive flathub <ref>` (the ref Flathub's AppStream names,
`app/<id>/<arch>/<branch>`), `flatpak uninstall --user --noninteractive <app-id>` then `--unused` (SD27; the app's data in
`~/.var/app/<app-id>` is kept, and the sheet says where), `flatpak update --user --noninteractive [--commit=<c>] -- <ref>`
(step 4, SD33). The
sheet adds what a Flatpak can reach (every grant of its metadata, `flatpak remote-info --show-metadata`, in plain words:
the classes the Store knows, each bus name it may talk to or own outside a short harmless list, and any grant the Store
does not know as flatpak writes it; "only its own window and files" only when nothing more is granted, and nothing said
when the metadata could not be read; SD25) and flatpak's own plan: every ref it would add, with the most each downloads
(SD25). Flathub's signing key comes in Flathub's `.flatpakrepo`, fetched over TLS from dl.flathub.org with the system's
certificate authorities, as Flathub's own setup instructions do; no fingerprint is pinned, and flatpak checks every
commit's signature against that key. `--if-not-exists` keeps a "flathub" remote the user's installation already has,
whatever its address or signature setting (SD31). Its metadata is
Flathub's AppStream in the user's installation (`appstream/flathub/<arch>/active`), refreshed by `flatpak update --user
--appstream` on the catalog's schedule (c: older than 6 hours at start, and Refresh). Flathub's desktop applications join
the model while it is on, after the catalog's and Arch's: an app of the same id (or whose Arch id is that id with
`.desktop`) shows Arch's package. A running install can be stopped (SD26, measured in S25). Installed lists the user's
Flatpaks (`flatpak list --user --app`), those Flathub's AppStream does not have too ("flatpak:<id>", opened and removed as
the others).

**What the Store removes (counter-review MAJOR).** "Uninstall…" exists only for an app the user installed: a package
installed explicitly that owns an application entry (an AUR package needs no entry, b.2) and that b.1's deny list does not
name (the system's packages, Omarchy's two package lists, `grassfield-*`, `HoldPkg`), with a removal plan that takes no
denied package. Otherwise the page says why and offers nothing: "Part of Omarchy" (an app Omarchy ships, such as
`chromium`), "Part of Grassfield", "Part of the system" (the fixed list), "Installed with another app" (pulled in as a
dependency). Removing them stays possible outside the Store. The Store installs from the repositories only apps that own an
entry (SD1), so it can remove whatever it installed.

**Foreign packages.** `pacman -Qm` lists every package no repository has: AUR packages, but also local builds such as the
owner's `makepkg -si` of Grassfield. The Store calls them "Not from a repository" and says "AUR" only when the AUR's
`info` knows the name (AUR turned on); Grassfield's own packages are never shown there.

### b. The install paths (owner, ST4: P2 for repository packages, Omarchy's terminal for the AUR and the recipes)
Each path ends with an exit code the Store receives, and success is that code being 0 **and** the system's state matching
the plan (packages present at the planned versions, the web app's entry present, the Flatpak listed). An exit code alone
is not enough (S6: an interrupted pacman exits 0); the state alone is not enough either (a recipe runs pacman twice and then
`sudo sed`, so its packages appear before it ends).

**b.1 Repository packages: `grassfield-store-helper`, a root helper behind the Store's own polkit action (P2).**
- `/usr/lib/grassfield/grassfield-store-helper`, run by `pkexec` as a direct, waited-for child of the Store, so the Store
  gets its exit code. Polkit action `org.grassfield.store.manage-packages` in
  `/usr/share/polkit-1/actions/org.grassfield.store.policy`: `allow_active` **`auth_admin`** (the password at every
  operation, never kept: counter-review MAJOR, S18), `allow_any` and `allow_inactive` `no`,
  `org.freedesktop.policykit.exec.path` the helper; message "Authentication is required to install or remove apps:
  $(command_line)" / « Une authentification est nécessaire pour installer ou supprimer des apps : $(command_line) ». polkitd
  replaces `$(command_line)` with the helper's argument vector as pkexec reports it (S18), so the names come from polkit, not
  from the Store. The dialog is Grassfield's polkit sheet (SEC6). For this one action id it shows "Install" or "Remove" and
  the package names, read from that line by a strict pattern (the helper's path, `install` or `remove`, an operation id,
  names of e.5); a line that does not match is shown as polkit gives it (SD2). Each operation asks once: a queue of three
  operations asks three times.
- Verbs, its argument vector only: `install <op-id> <package>…` and `remove <op-id> <package>…` (1 to 64 names). It reads no
  environment variable at all (as `grassfield-channel-helper`: `bash -p`, then itself again under `env -i` while its
  environment holds anything, so not even `PKEXEC_UID`); it sets its own `PATH`, `LC_ALL=C` and `umask 022`; it refuses
  unless its effective uid is 0. An operation id is used once (its log is created exclusively).
- It runs exactly `pacman -S --needed --noconfirm --noprogressbar -- <names>` or `pacman -Rns --noconfirm --noprogressbar --
  <names>`. Never `-y`, `--overwrite`, `-dd`, `-U`, a file path, a hook, or anything else. It installs from the repositories
  only (names, not files). Before an install it reads the whole plan first, `pacman -S --needed --print --print-format
  '%n %v %l' -- <names>`: every line must be a package, and no installed package may change in it, which would be a partial
  upgrade or downgrade (5). A package IgnorePkg holds back (`pacman -Qu` shows it "[ignored]") is one pacman asks about,
  and under `--noconfirm` installs anyway: the plan is read without `--noconfirm`, the question reads `/dev/null` and the
  plan fails ("could not satisfy dependencies"); an older version a dependency asks for comes with no question, and the
  plan names an installed package (integrator's review of 19d2e9e; the Store refuses the same plans, e.4). It then applies
  SD1 itself (SD12): `pacman -Sw --noconfirm --noprogressbar -- <names not installed>` downloads them into pacman's cache
  and checks their signatures as an install does, the plan names each one's file, and `pacman -Qlpq -- <that file>` must
  list an application entry (`/usr/share/applications/<id>.desktop`); an installed name is read from pacman's database
  (`pacman -Qlq`). A name that owns none is refused before anything is installed.
- Before pacman, it checks again (MAJOR 1): no `db.lck`; `pacman -Qu` lists nothing that is not "[ignored]" (S12), and an
  install names nothing it lists at all: a name IgnorePkg holds back is refused by name (5), whatever pacman would answer
  about it, since `pacman -S --noconfirm` would update it (re-review of 64cdaa9); every name
  matches the pattern of e.5 and is a package a repository has by that exact name (`pacman -Slq`; a name only provided by
  another package, such as `sh`, is refused). One run at a time: a lock only root can open (`/run/grassfield-store/helper.lock`,
  0600), refused at once when held. Its descriptor is closed for every program the helper starts (`9<&-`), so neither pacman
  nor a process a package's scriptlet leaves running holds it after the helper ends.
- Its exit code says what happened (the Store's words for each, spec SR19): 0 done; 1 pacman failed (its message in the
  log); 2 usage, or an operation id used before; 3 busy (another run, or `db.lck`); 4 the last system update did not finish;
  5 a name no repository has, a plan pacman cannot resolve, or one that would change an installed package; 6 a removal the
  rule refuses; 7 an install of a package that
  owns no application entry. pkexec's own are 126 (not authorized, or the dialog dismissed) and 127 (authentication failed).
- **`remove` takes apps only (counter-review MAJOR; S16).** Every name must be a package of a repository (`pacman -Si`; a
  package no repository has is removed through b.2), installed explicitly (`pacman -Qqe`), the owner of an application entry
  (a file `/usr/share/applications/<id>.desktop` in `pacman -Qlq`), and not denied. Denied:
  - the fixed list `base`, `base-devel`, `filesystem`, `glibc`, `bash`, `coreutils`, `util-linux`, `shadow`, `pam`, `sudo`,
    `polkit`, `dbus`, `dbus-broker`, `dbus-broker-units`, `kmod`, `mkinitcpio`, `dracut`, `grub`, `efibootmgr`, `refind`,
    `syslinux`, `snapper`, `btrfs-progs`, `cryptsetup`, `lvm2`, `plymouth`, `archlinux-keyring`, `intel-ucode`, `amd-ucode`;
  - every name that is `linux`, `systemd`, `limine`, `pacman`, `yay`, `omarchy` or `grassfield`, or one of them followed by
    `-` and anything (kernels and their headers, the boot manager's hooks, Omarchy's and Grassfield's packages);
  - every name that ends in `-firmware` or holds `-firmware-`;
  - every name in Omarchy's `omarchy-base.packages` and `omarchy-other.packages`, read at `/usr/share/omarchy/install/`, never
    a path from the environment (both missing or empty: every `remove` is refused);
  - pacman's `HoldPkg`.

  Then the whole plan: `pacman -Rs --print --print-format '%n' -- <names>` (what `-Rns` removes; pacman refuses `--print`
  with `-n`) must resolve and name no denied package, since `-s` also removes dependencies. The list is in the helper's code,
  not in a file: changing it is a reviewed change.
- Its own descriptors go to `/dev/null` and to a log, never to the pipe it was started with, and it ignores SIGHUP and SIGPIPE:
  the Store quitting cannot kill pacman through a closed pipe (S6 shows what a killed pacman leaves). It writes, in the
  root-owned `/run/grassfield-store/` (0755): `<op-id>.started` (its pid and start time), `<op-id>.log` (pacman's output, 0644,
  at most 8 MiB, for the progress and the error), `<op-id>.exit` (the exit code, written by rename). The files of the 16
  newest operations are kept (the Store needs the last one after a crash; `/run` is emptied at boot).
- While it runs, the Store holds Omarchy's update lock (the same file, opened with close-on-exec, so neither pkexec nor
  pacman inherits it): `omarchy update` cannot start meanwhile, and Software Update, which reads the same lock (ADR-0033
  d.5), shows "Update in progress" until the operation ends. The same holds while `grassfield-store-run` holds it (b.2).
- Waits: the authentication up to 120 s (ADR-0030); the transaction up to 2 h, after which the Store stops waiting, says it
  lost track, and reads the state; it never signals the helper (a user cannot signal a root process anyway).
- It and its policy need the security reviewer's (opus) PASS before they merge (step 3), like ADR-0033's two programs.

**b.2 AUR packages and Omarchy setups: Omarchy's terminal, through `grassfield-store-run` (P1).** yay must not run as root,
and the recipes call sudo themselves and write in the user's home, so the helper cannot run them. As built for the setups
(step 3b1; the AUR comes with 3b2, SD18):
- The Store checks that `db.lck` is absent and Omarchy's update lock is free (it does not take the lock: the script does),
  writes `$XDG_RUNTIME_DIR/grassfield/store/<op-id>.pins` (the folder the user's own and 0700, the file 0600, written whole
  then renamed: one `<sha256>  <path>` line per pin of the signed catalog, g), then starts
  `omarchy-launch-floating-terminal-with-presentation "/usr/lib/grassfield/grassfield-store-run <op-id> <deadline> setup
  <recipe> [<arg>...]"`, the command string built only from the validated tokens of e.5 (the launcher hands it to
  `bash -c`: no token may hold a character the shell reads, and the script checks them again). The terminal is detached
  (`setsid uwsm-app`), so the exit code comes back through files. Omarchy's launcher shows its logo first and, unless the
  code is 130, waits for a key after it ("Done! Press any key to close"): the window stays to show what happened, and the
  Store's Details do not have that output.
- `grassfield-store-run` (`packaging/store/grassfield-store-run`) is Grassfield's script, run as the user inside that
  terminal. It refuses to run as root, checks its arguments (exit 2, nothing written, an operation id used once), and
  runs every program with `PATH=<Omarchy's folder>/bin:/usr/bin`, without `BASH_ENV` or the caller's exported shell
  functions (`bash -p` reads neither for itself; the recipe gets an environment without them), so the commands a recipe
  names are Omarchy's pinned ones and the system's, whatever the caller's environment holds. Then:
  1. refuses to start after `<deadline>` (Unix seconds, 60 s after the Store asked: the terminal opened too late): exit 6;
  2. takes Omarchy's update lock (`$XDG_RUNTIME_DIR/omarchy-update.lock`, the file `omarchy-update-lock` locks, so
     `omarchy update` says it is already running) with `flock -n` on a descriptor of its own, closed for every program it
     starts (`9>&-`): no process the recipe leaves running keeps the lock (S13), and the lock goes when the script ends,
     whatever ends it; exit 3 when it is held. Step 0 wrote `flock -n -o` here; measured while building it, a `flock`
     process holding the lock for the recipe dies on Ctrl+C before the recipe has stopped and lets the lock go while pacman
     may still run, and ignoring SIGINT in it would pass to the recipe: one process holds it for its whole life instead;
  3. writes `<op-id>.started` (its pid and start time), by rename;
  4. checks again, under the lock: no `db.lck` (exit 3); `pacman -Qu` answers (exit 0 or 1; anything else is exit 1) and
     lists nothing that is not "[ignored]" (S12; exit 4);
     the recipe is an executable file of `${OMARCHY_PATH:-/usr/share/omarchy}/bin/`, and `<op-id>.pins` (the user's own
     file, not a link) has only lines that parse, paths without `.` or `..` segments, each matching the installed file's
     SHA-256, one of them the recipe (exit 5, nothing run);
  5. runs the recipe with its arguments, as an argument vector. Ctrl+C in the terminal, from the script's start, is
     answered with 130: before the recipe nothing of it runs (a check Ctrl+C cut short is not passed), during it the
     recipe stops (SIGINT's own action there; the script catches it rather than ignoring it, which the recipe would
     inherit);
  6. writes `<op-id>.exit` with the code (by rename) and exits with it: 0 done, 1 the recipe failed, 130 stopped.
- The Store follows the files (every 500 ms). An `exit` file before the `started` one is a refusal: 3 "Another installation
  or an update is running", 4 "Finish the system update first", 5 "This setup hasn't been checked with your version of
  Omarchy yet", 6 as below. No `started` file 75 s after the request (the 60 s deadline, and 15 s for a script already past
  its deadline check): "The terminal did not open", and the operation is dropped. While it runs, the `started` file's pid
  and start time tell whether the script still runs; gone without an `exit` file (the terminal closed; SIGHUP through sudo
  to pacman is NOT VERIFIED, S6), the state is read: "interrupted", or "did not finish". Exit 130 with nothing changed says
  nothing (the user's own choice, like a dismissed polkit dialog). A running operation is waited for up to 3 h (setups
  download large apps), then the Store stops waiting and reads the state; it never signals the terminal. Success is exit 0
  and every package of the plan there (an install) or gone (a removal). A concluded operation's files are removed; at
  start the Store removes those older than 4 h.
- The next operation in the queue starts only when the `exit` file exists, Omarchy's lock is free and `db.lck` is absent.
  The Lutris recipe (pacman twice, then `sudo sed`) is one operation: the Store waits for its end.
- The AUR (as built in step 3b2; SD21 to SD23): the same script and path, kind `aur`, with Omarchy's own commands:
  `grassfield-store-run <op-id> <deadline> aur omarchy-pkg-aur-add <name>` to install (yay builds, sudo installs, in the
  user's terminal) and `... aur omarchy-pkg-drop <name>` to remove (`sudo pacman -Rns`). The Store passes one package per
  operation, the one the user chose (SD22); the script accepts 1 to 4 names. The command is checked like a setup's recipe:
  an executable file of Omarchy's `bin/`, one of the catalog's pins (for `omarchy-pkg-aur-add`, with the
  `omarchy-pkg-missing` it calls first; the Store asks the same of the catalog), every pin matching (exit 5). The script's
  checks run in the C locale, as the Store's and the helper's children (bash's `[a-z]` follows the locale's collation:
  under en_US.UTF-8 "exämple" would pass), the recipe in the user's own. Then, under the lock, the script checks the AUR's
  plan again (exit 7, nothing run): for both commands, no name that b.1's deny list names (the helper's case list, copied
  as it is, Omarchy's two lists read from `$OMARCHY_PATH/install`, missing lists refusing, `HoldPkg`): what the Store
  could not remove it does not build either, and anyone can name an AUR package `omarchy-*` or `grassfield-*` (SD30; the
  Store's plan refuses the same for every package it would build from the AUR); an install only of names pacman does
  not resolve from the repositories (`pacman -Sp`, as the user: a package of that name, a provider of it or a group is
  what yay would install; the Store's plan asks the same), "not there" being pacman's whole line `error: target not
  found: <name>`, never a longer name's; a removal only of packages installed explicitly (`-Qqe`) from outside the
  repositories (`-Qqm`) and whose whole `pacman -Rs --print` plan names no denied package (read one name a line, never
  as words or patterns). The script checks the names it is given; the packages yay builds as their dependencies are
  checked by the Store's plan before the terminal opens (each denied name refused, SD30), not again there: the script has
  no copy of the AUR's answer, and yay builds what each PKGBUILD asks, which the user accepted with the warning. No application entry is needed: the user installed it from
  the AUR. Success is exit 0 and every planned package present by name (an AUR package's version is whatever its build
  makes; the repositories' packages at their planned versions), or, for a removal, every planned package gone.
- "Get Flatpak…" (step 3c part 3, SD24): the same script and path, kind `flatpak`, with Omarchy's own command and exactly
  one argument: `grassfield-store-run <op-id> <deadline> flatpak omarchy-pkg-add flatpak` (`sudo pacman -S --noconfirm
  --needed flatpak` after `omarchy-pkg-missing`, as Omarchy's GeForce NOW recipe installs it, S20), nothing else (exit 2
  for any other command or argument). The command is checked like a setup's recipe, with the `omarchy-pkg-missing` it
  calls first among the pins; the Store's plan is a setup's (the pins, then pacman's plan of `flatpak` and what it adds,
  the unfinished update, the mirror), and the catalog pins the command always (grassfield-packages, SD24). Success is exit 0
  and every planned package there. Grassfield adds no root surface: the root helper and its policy are unchanged, sudo
  asks in Omarchy's terminal as for every setup. The `flatpak` package brings flatpak's own, for system installs the
  Store never makes (SD24).

**b.3 Web apps and Flatpaks: the Store's own children, as the user.** `omarchy-webapp-install <name> <url> <icon-file>` (a
local icon file from the catalog, S9), `omarchy-webapp-remove <name>`, and the `flatpak --user` commands of a. They are
waited for (exit code), stdin from `/dev/null`, with a 10-minute limit for web apps (SIGTERM, then SIGKILL 5 s later; they
touch only the user's files) and none for Flatpaks: a Flatpak install runs as long as its downloads take, the user can stop
it (SIGTERM, SD26), and it stops with the Store (the child's PDEATHSIG is SIGTERM, which flatpak handles cleanly, S25; never
SIGKILL, which leaves a staging folder). Success is the exit code 0 and the app listed (`flatpak info --user <id>`), or gone
for a removal; an operation found in `store.json` at start is judged by that state alone (flatpak deploys the app last).

**b.4 Every path.** The plan check comes first (e.4), one operation at a time, success = exit code 0 and the state, and
nothing ever signals pacman.

### c. Catalog and metadata (owner, ST5, ST6, ST7)
- **Sources of metadata.** (1) Our catalog (g): sections, cards, categories, our texts, icons for apps without metadata (ST10),
  the list of setups and web apps. (2) AppStream for Arch packages (ST5): the installed `archlinux-appstream-data` when there
  is one (an `optdepends`, signed by Arch, updated with the system); otherwise the Store fetches the same package file and
  its signature (`<url>.sig`) from pacman's own mirror (`pacman -Sp archlinux-appstream-data`, as the user), checks the
  signature as pacman does (pacman's keyring and pacman's rule, S17, S19; the SHA-256 of the unsigned sync database is not
  enough, counter-review; SD4): gpg `--verify` as the user against a private copy of pacman's public keyring and trust
  database (`pubring.gpg` or `pubring.kbx`, `trustdb.gpg`; nothing written in `/etc`), passing only with exactly one good
  detached signature (one `VALIDSIG`), `TRUST_FULLY` or `TRUST_ULTIMATE`, the key's listing valid and not disabled, and none
  of `PLAINTEXT`, `BADSIG`, `ERRSIG`, `EXPSIG`, `EXPKEYSIG`, `REVKEYSIG`; `pacman-key --verify`'s exit code is not used (S19).
  Only then does it extract the XML and icons into its cache (`bsdtar` given only `usr/share/swcatalog`, with no owner,
  permission, extended attribute or ACL from the archive). That copy is used for display only: a package name it
  gives must exist in pacman's database, and the sheet shows the package that will be installed. It is replaced when
  pacman's database names another version. When there is none, the Store says why in its own words, one reason each
  (the integrator's note on PR #36): the package or its signature could not be downloaded ("Arch's app data couldn't be
  downloaded. Check for updates, then try again.", with Open Software Update: the usual cause is databases older than
  the mirror, e.4), the signature did not pass ("could not be verified": that alone), or the copy could not be made
  (unpacked, cached); the details go to the log. The Store works with what it has: the catalog alone, or Arch's data
  alone when there is no catalog host. (3) pacman for every package: version, sizes, licence (`License`, used when
  AppStream has none), description. (4) The AUR RPC for AUR packages (ST7). (5) Flathub's AppStream through `flatpak` (ST2).
- **Display.** Every remote or package-provided text is plain text (`Text.PlainText`), control and format characters
  removed (by code point, so the ones beyond U+FFFF too) except line feeds, bounded (name 80, summary 200, description 4000 characters); AppStream's description markup (`<p>`, `<ul>`,
  `<li>`) becomes paragraphs and bullet characters, never rich text; no link inside a text is active. URLs (homepage, bug
  tracker) are buttons that open the default browser on click only (ADR-0011's open path), https only.
- **Screenshots (ST6).** Loaded when a product page opens, https only, no cookie, no `Referer`, cached; a switch in the
  Store's settings turns them off. They are the publishers' images: shown as the app's metadata gives them; needs legal
  review.
- **What is fetched, when, and from where.**

  | Host | What | When |
  |---|---|---|
  | Grassfield's host (ADR-0033 g) | `grassfield-catalog.v1.json` and `.sig` (ETag), catalog icons by hash | at Store start when the cached catalog is older than 6 h; Ctrl+R; never while the Store is closed |
  | Arch and Omarchy mirrors (pacman's own `Server`) | `archlinux-appstream-data`'s package file and its `.sig`, when that package is not installed (ST5) | when pacman's database names a version the cache does not have |
  | Arch and Omarchy mirrors | one HEAD request for the first package of a plan (e.4) | before an install |
  | Screenshot hosts named by AppStream | the images of one product page | when it opens (ST6), unless turned off |
  | aur.archlinux.org | `info` (RPC v5, at most 50 names a request) for the AUR page opened, for foreign packages' names and for an install's plan (its dependencies, in turn); `search` by name after Return (two characters at least, at most 50 results kept, the most voted first); the PKGBUILD text on "View Build Script" (`/cgit/aur.git/plain/PKGBUILD?h=<package base>`) | only while the AUR is turned on (ST7) |
  | dl.flathub.org (through `flatpak`) | Flathub's `.flatpakrepo` (the switch); Flathub's AppStream; an app's `remote-info` (its version, sizes and metadata, when its page or sheet opens) and flatpak's own plan; Flatpak update checks (step 4); the apps and runtimes installed | only while Flathub is turned on |
  | the user's browser | homepage, bug tracker | on click |
  | Arch and Omarchy mirrors | packages | by pacman, during an install, not by the Store |

  Requests carry no cookie, no `Referer`, the User-Agent `Grassfield-Store/1`, https only (redirects too; `file://` only
  through dev plumbing), a 15 s transfer timeout (5 minutes for the AppStream package) and a size cap (catalog 1 MiB, icon
  256 KiB, screenshot 4 MiB, AUR answer 512 KiB, AppStream package 64 MiB, its signature 4 KiB). Nothing that identifies
  the user or the machine leaves it: no installed-app list, no identifier, no telemetry, no search query to Grassfield's host (search is local; AUR
  searches go to the AUR, ST7). Metered connections: no automatic fetch (the AUR's names of the foreign packages included,
  3b2's review); what the user asks for (Refresh, Return, a page opened) goes.
- **Cache (bounded, ADR-0020 classes).** `$XDG_CACHE_HOME/grassfield/store/` (regenerable): the verified catalog per channel
  with its ETag, catalog icons (32 MiB, least recently used first), screenshots (128 MiB, 30 days), AUR answers (4 MiB, 1 h),
  the fetched AppStream (one version, at most 64 MiB); AUR answers are files of `aur/` (`info/<name>.json`, `search/<key>`,
  `pkgbuild/<package base>`), the oldest dropped first. `$XDG_STATE_HOME/grassfield/store.json` (state, `version: 1`): the
  last accepted catalog serial per channel, the operation in flight (f), the last fetch time. The Store's preferences are
  keys of `grassfield.json` (`store.sources.aur`, `store.sources.flathub`, `store.screenshots`; the schema's defaults:
  off, off, on), read with the contract's rule and written by the Store itself as Settings writes its own keys, until the
  shell is the single writer (ADR-0020 item 4; SD20). The rows are in
  ADR-0020's table of persisted files (step 1; `docs/specs/persisted-files.md` does not exist yet).

### d. Updates and the one badge (owner, ST8)
- **No partial upgrade, ever.** The Store never runs `pacman -Sy`, `-Syu` or `yay -Sua` itself, and never offers "Update"
  for one repository or AUR app: those update only with the whole system (S4, S12).
- **One checker.** The Store reads ADR-0033's result (`$XDG_STATE_HOME/grassfield/software-update.json`, written by the
  shell's checker) and asks the shell to check, as Settings does (ADR-0033 d.7). **Software Update's step 2 adds the list**
  of the other updates beside their count (`otherPackages`: name, installed and available version, sorted by name; ADR-0033
  d.3.5 as PR #16 writes it), so the Store shows which apps the next update brings without a second `checkupdates`; until
  then the Updates page shows the count (`others`, step 1). At the checker's 256 KiB cap that list is cut first
  (`otherPackagesTruncated: true`), then the notes; the counts always stay, and the Store then says "N other updates"
  without names (SD3).
- **Updates page.** The apps (entries with a desktop id) that the next system update upgrades, each marked "Updates with the
  system" (no per-app button), then "N other system packages", then "Update All…", which opens Software Update, where
  ADR-0033's "Update Now" updates the whole system (since ADR-0033's step 3 a run Settings owns, with its password, progress
  and restart; SD32). While Omarchy's update runs: "Update in progress". When `pacman -Qu` lists packages while
  no update runs (an update that stopped, S12), the page says the last system update did not finish, with "Update All…",
  and every "Get" of a repository, AUR or setup app is refused until then (e.4).
- **Flatpak updates (Flathub on).** A Flatpak updates outside pacman's transaction: the Updates page lists them in their own
  group with "Update" per app and "Update All" for that group (every ref the check lists, 512 at most: one operation),
  checked by the Store when it opens and on "Check Now" (`flatpak remote-ls --user --updates`, S31; Flathub's refs only).
  Its plan reads, for each app, the commit Flathub serves (`remote-info --show-commit`) and that commit's metadata
  (`--commit=<c> --show-metadata`, S32a), shown as it goes ("Checking what the updates change: N of M apps…"); an update
  that lets an app reach more than the installed version, or whose commit or metadata could not be read, says so in a sheet
  first (SD33). Each app is then updated to the commit its plan checked, on its own (`flatpak update --user --noninteractive
  --commit=<c> -- <ref>`: `--commit` takes one ref, S32d), the rest together; a newer commit published meanwhile is not
  taken (S32c) but listed again and asked about by a new plan (S32e). A pinned ref is done when its installed commit is that
  one, another when a new check no longer lists it, never on flatpak's exit code alone (S31d); a command that fails ends
  the update ("interrupted", N of M). `omarchy update` does not update Flatpaks. **Amended by ADR-0049** (2026-11-05):
  what an app can reach is read grant by grant (folder and mode, bus name and policy) and shown as cards on its page; an
  update's changes are added, widened, removed or narrowed; Update All leaves out every app whose update asks for more or
  could not be read ("Asks for more: …" on the list), and that app's own Update says what changes.
- **Badge (owner, ST8).** The only Dock badge for updates stays on Settings (ADR-0033 U18: Grassfield and Omarchy releases).
  The Store's tile has no badge, Flatpaks included; the Store's sidebar shows the number of apps with an update.

### e. Security
1. **Explicit click, then a sheet, then an authentication.** "Get" opens a confirmation sheet; nothing starts without its
   default button. The sheet shows the source, the licence, the download and installed sizes, every package the plan adds
   (`pacman -S --print`, as the user, S10), and: for a setup, what it changes (our catalog's text, written after reading the
   recipe, plus the recipe's name); for a removal recipe, the user data it deletes; for a Flatpak, what it can reach; for the
   AUR, the warning (spec). The authentication: repository packages, the polkit sheet of b.1 at every operation, naming
   the packages (`auth_admin`, never kept); the AUR and setups, sudo's
   prompt in Omarchy's terminal (b.2); per-user installs (web apps, Flatpaks), **the sheet alone** (owner, ST3): its default
   button is the user's consent; anything running as the user can already write those files.
2. **Source and licence always shown**, on results, cards, the product page and the sheet. Without a licence the Store says
   "Licence not stated"; it never hides the row.
3. **Root code.** Only `grassfield-store-helper` (b.1) runs as root, and it runs pacman only, on validated names; it
   removes only apps the user installed, never a package of the system (b.1, S16). The Store,
   `grassfield-store-run` and everything else run as the user. Omarchy's recipes and yay call sudo themselves, as in
   Omarchy's own menu.
4. **The plan is checked before anything runs**, as the user, without root or the lock (S10), and checked again right before
   (b.1 step "checks again", b.2 step 4, under Omarchy's lock):
   - **`pacman -Qu` must list nothing but "[ignored]" packages** (MAJOR 1; S12): otherwise the databases are newer than the
     system (an `omarchy update` stopped after its keyring step, or a hand-run `pacman -Sy`): "Finish the system update first"
     with a button to Software Update. Packages the user holds with `IgnorePkg` are the user's own choice and do not block.
     With this rule the databases equal the system, so whatever a recipe or yay installs from the repositories beyond the
     Store's plan comes from those same databases: no partial upgrade from them either. That holds only while nothing syncs:
     S1 shows no recipe or helper of Omarchy's runs `-y`, and grassfield-packages' CI refuses a catalog that names a recipe
     whose text has `-Sy`, `-Syu` or `yay -Sy` (g);
   - `pacman -S --print` must resolve and must not upgrade an installed package (S4);
   - the system no older than its mirror (S5; the integrator's notes on PR #36 and the review of ff2fd83; SD29):
     Software Update's last successful answer (`software-update.json` as the shell writes it: up-to-date, available or
     not-set-up, the three states that list the system's updates, or after a failed check the success the shell keeps as
     `previous`) that counts other updates or an Omarchy release, given after pacman last completed a sync of the
     databases (the newest ctime of its sync databases: pacman writes one only with the mirror's newer copy, and a sync
     that found nothing new or failed leaves them as they were, while pacman.log logs all three alike and the mtime is the
     mirror's Last-Modified, S27), means the mirror has moved on (its checker compares what is installed with a fresh copy of the
     mirror's databases) and refuses before anything downloads, AUR installs included; then every file of the plan (256
     at most), the AUR's repository dependencies included, is asked with a HEAD request, all at once within 20 s, and one
     the mirror no longer has (404, 410) refuses too; after the fact, an install pacman ended because the mirror answered 404, 410 or more than the allowed
     size for a package or its `.sig` ends "outdated". Each says "Your system needs to be updated before you can install
     apps." with one action, Update Now… (Software Update, SD14), and the app is offered again after the update; the
     mirror's and pacman's words go to the log, never to the sheet. The Store never syncs the databases alone (a partial
     upgrade, S12);
   - no `db.lck` and Omarchy's update lock free (S11, ADR-0033 d.5).
5. **Validated input, argument vectors only.** Package names `^[a-z0-9@_+][a-z0-9@._+-]{0,127}$`; a setup's `install` field
   `^omarchy-install-[a-z0-9-]+$` and its `remove` field `^omarchy-remove-[a-z0-9-]+$` (one cannot name the other kind), run
   only when `${OMARCHY_PATH:-/usr/share/omarchy}/bin/<name>` exists; recipe arguments `^[a-z0-9][a-z0-9.-]{0,63}$` (at most
   4); web app names, in every language, any plain text (g) of 1 to 64 characters without `/`, not starting with `.`
   (Omarchy writes them as file names with their spaces, S9), URLs `https://` with a host name and no user information,
   without whitespace, control or format characters, at most 2048 bytes; desktop
   ids of package entries `^[A-Za-z0-9._-]{1,250}\.desktop$` (web apps are not opened by id, f); Flatpak app ids
   `^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$` (at most 255 bytes; no leading `-`); operation ids
   `^[0-9a-f]{32}$`; the catalog's pins as g says (paths without `.` or `..`, SHA-256 in lowercase hexadecimal, written to
   `<op-id>.pins` as `<sha256>  <path>` lines); for the AUR (b.2), the kind `aur`, one of the two commands
   `omarchy-pkg-aur-add` and `omarchy-pkg-drop`, and package names as above. The one command string is b.2's terminal command, built only from those tokens; Omarchy's
   `omarchy-install-app` / `-and-launch` quote their own arguments.
6. **Untrusted data stays data.** The catalog is verified before it is parsed (g); AppStream comes from a signed Arch
   package, installed, or fetched and checked by its own signature with pacman's keyring (S17); AUR answers, Flathub data
   and screenshots are third-party: bounded, never executed, never rendered as rich text. An AUR package's PKGBUILD is
   shown as plain text on request, never run by the Store (yay builds it, in Omarchy's terminal).
7. **The AUR warning** before every AUR install (the sheet's first paragraph, every time), and the AUR's facts on the
   product page: maintainer (or "orphaned"), votes, popularity, last change, out-of-date flag, and "View Build Script" (the
   PKGBUILD as plain text, saying that yay fetches it again when it builds and that the package's other files, such as
   its install script run with administrator rights, are not shown). The sheet lists what yay builds (marked "AUR") and
   what pacman adds from the repositories, and says when a dependency could not be read (the build may install more). Its
   default button is **Cancel** (the integrator's decision at 3b2's review, common rule 3: the build runs the package's
   script as the user before any password, so Return never starts it); "Install from the AUR" takes a click, or Tab and
   Space (`Sheet.returnCancels`, as the certificate-override sheet of `system-dialogs.md`).
8. **Dev sessions (ADR-0019)** never install, uninstall or start Omarchy's commands, pkexec or flatpak operations: the queue
   runs fake programs only (dev plumbing `GRASSFIELD_STORE_INSTALLER` for b.2 and b.3, `GRASSFIELD_STORE_PKEXEC` for b.1;
   both come with step 3; for Flathub, the fixture's `bin/flatpak`, step 3c: without a fixture a dev session reads the
   user's installation but adds nothing to it and runs no flatpak operation);
   catalogs and keys come from fixtures (`GRASSFIELD_STORE_CATALOG_URL`, `GRASSFIELD_STORE_KEYRING`,
   `GRASSFIELD_STORE_FIXTURE` for fake pacman, AppStream and flatpak roots; `GRASSFIELD_STORE_AUR_URL`, step 3b2, for a
   folder of the AUR's answers); "Open" follows ADR-0011's dev open policy. The names join ADR-0019's dev plumbing table
   with the code.
9. **Reviews.** The catalog verification (step 1), and the helper, its policy, `grassfield-store-run` and the launch code
   (step 3) need an opus security review before merge.
10. **Legal (§14), each one needs legal review:** the sidebar's structure and the section names copying Apple's store
    application (Discover, Create, Work, Play, Develop, Categories, Updates); the name "Grassfield Store"; publishers' icons in
    our catalog (ST10); screenshots and AppStream texts shown as the apps' metadata gives them; the AUR's and Flathub's data
    shown in the Store.
    **Owner decisions of 2026-10-27** (legal review with the integrator; the full list is in grassfield's legal dossier):
    - the section names stay as they are (Discover, Create, Work, Play, Develop): a risk the owner accepts;
    - the category names stay the neutral ones;
    - publishers' icons, screenshots and AppStream texts are shown as provided, with their source;
    - the app name "Grassfield Store" and "Get" / "Open" stay, with the macOS command labels (the owner: labels kept).

### f. The app and its processes
- **A new app, `apps/store`, packaged as `grassfield-store`.** `apps/` is where Grassfield's apps live (master-prompt §5.2,
  §6); the new folder is the brief's deliverable. It is a separate application (macOS has one), not a Settings pane: its
  window, queue and caches have no place in Settings, and a separate package lets Grassfield ship without it and lets a user
  remove it. No new language (C++, QML and a shell script for b.2), no new service or daemon (the Store runs only while open;
  background checks are ADR-0033's), no new design components before the shared ones (`ui/Grassfield/Ui`). The package also
  ships `grassfield-store-helper`, its polkit policy and `grassfield-store-run`. New runtime dependencies of
  `grassfield-store` only: `kimageformats` (the JPEG XL icons, S3), `gnupg` (`gpgv`, already pulled by pacman, declared);
  `archlinux-appstream-data` and `flatpak` as `optdepends` (ST5, ST2). AppStream is read by the Store's own reader
  (`QXmlStreamReader` and zlib, both already linked by Qt), not by `appstream-qt` (SD5). PackageKit, GNOME Software and KDE
  Discover are not used: they need PackageKit's root daemon (§5.8, not installed) and bypass Omarchy's commands (D1).
- **Build.** A CMake target in `apps/store/CMakeLists.txt` with the same wrapper as the other apps (ADR-0023), and
  `package_grassfield-store()` in `packaging/arch/PKGBUILD`, depending on `grassfield-desktop=$pkgver-$pkgrel` (design system,
  translations, menu bridge).
- **Child processes the Store owns for reading** (pacman queries, `gpgv`, gpg on a copy of pacman's keyring, `bsdtar`,
  `flatpak` queries; `apps/store/src/childprocess.cpp`): an
  argument vector, `LC_ALL=C`, stdin from `/dev/null`, output capped (8 MiB), each in its own process group, stopped after
  20 s with SIGTERM then SIGKILL 5 s later (60 s for gpg's check of the AppStream package and 120 s for `bsdtar`'s unpacking
  of it, a package of up to 64 MiB), and all stopped the same way when the Store quits. None of them writes outside the
  Store's own cache and temporary folders.
- **Operations** follow b: pkexec is waited for (b.1); the terminal is followed through its files (b.2); web apps and
  Flatpaks are waited for (b.3). The Store never sends a signal to pacman, yay, makepkg, a recipe, their terminal or the
  helper (S6).
- **One operation at a time**, in a queue the user fills (Get, Uninstall, Update All). Before it starts, the operation is
  written to `store.json`: its id, kind, path, app, source, planned packages and versions, start time.
- **After an operation**, and whenever `/var/lib/pacman/local`, `pacman.log`, `~/.local/share/applications` or the Flatpak
  installation change (watched), the Store reads the state again. Progress: b.1 and b.2 count `[ALPM] installed` lines of
  pacman's log since the start against the plan (S10), indeterminate before the first; b.3 has none.
- **Recovery after a failure or a crash.** On start, a record is compared with what is there: an `exit` file (b.1, b.2), a
  running helper or script (their `started` pid and start time), the system's state:
  - exit code 0 and everything planned is there: done, nothing said;
  - a part is there (an exit code other than 0, or none): "The installation was interrupted: 15 of 110 packages were
    installed", with "Try Again" (the same plan; `--needed` completes it) and the list;
  - nothing is there: "The installation did not finish", with "Try Again";
  - still running: the Store follows it again;
  - `db.lck` exists and no pacman runs: the Store explains that a package manager stopped mid-way and shows Arch's recovery
    (remove the lock file only when no pacman runs), as text to copy. It never removes the root-owned lock itself;
  - pacman later reports files that "exist in filesystem" (left by a killed pacman, S6): the message is shown as is, with
    the explanation; the Store never runs `--overwrite`.
- **Open.** A package's app opens through ADR-0011: `uwsm-app -- <desktop-id>` in a real session, through `apps/appscope.h`
  (a desktop-id variant beside `startApplication`); the desktop id comes from AppStream's launchable, our catalog, or the
  package's files (`pacman -Qlq`, S10). Several entries: the catalog's choice, else the one AppStream names, else the first;
  none: no "Open", and the product page says the app has no window. **A web app opens with `omarchy-launch-webapp <url>`**
  (Omarchy's own launcher, which scopes the browser itself), never by its entry's file name, which has spaces uwsm refuses
  (S14). A Flatpak opens with its exported desktop id (`uwsm-app -- <id>.desktop`) when the session's `XDG_DATA_DIRS` names
  the user's export folder and the entry is there, else with `uwsm-app -- /usr/bin/flatpak run <app-id>` (S20: a session
  started before flatpak was installed does not see the exports until the next login).

### Offline
- The Store opens with the cached catalog, AppStream (local) and pacman's databases: Discover, Categories, search and product
  pages work, with a bar "You're offline. The catalog is from 27 October." Screenshots not cached show a placeholder.
- "Get" and "Update All…" are disabled with the reason. "Open" and "Uninstall" work (no network needed).
- No catalog yet (first start offline, or no hosting: the base is still `packages.grassfield.invalid`): Discover shows what
  AppStream allows (no editorial sections), with a line saying the Grassfield catalog is unavailable. A catalog older than
  30 days is used, with a note.
- Connectivity and metering come from Qt's network information (NetworkManager backend): no new dependency.

### g. The catalog: format, signature, publication (contract with grassfield-packages)
**Where.** Beside each channel's repository, in its snapshot (ADR-0033 g, h.2): `<base>/<channel>/<arch>/
grassfield-catalog.v1.json`, `grassfield-catalog.v1.json.sig`, and `<base>/<channel>/<arch>/catalog/<sha256>.png`. The fixed
names are redirected to the snapshot like the database, so one pointer write switches the database, the notes and the catalog
together; icons have immutable names. A catalog change is a new snapshot with the same packages: no Grassfield release, no
`pkgrel`. The Store derives the URL from the primary `Server` of `/etc/pacman.d/grassfield.conf` (`<base>/<channel>/$arch`,
ADR-0033 a), else from `GRASSFIELD_REPO_BASE` of `packaging/pacman/repository.conf` and `stable`. While the base is the
`.invalid` placeholder, nothing is fetched.

**Publication: one serialized publisher, built from the current snapshot, a conditional pointer write (MAJOR 3; ADR-0033 h.2
amended).** Package releases and catalog updates share each channel's pointer. A catalog job built from snapshot A and
published after a release B would point the channel back to A's `grassfield.db`: every client already on B would then get
"signature … is invalid" (ADR-0033 R4), and, by ADR-0033 a2, every `omarchy update` would fail. So, per channel:
1. **One publisher, publishing the latest state.** Releases and catalog updates go through one publishing job per channel,
   serialized by a CI concurrency group per channel (one run at a time, never cancelled half way). GitHub keeps one run
   pending per group and cancels it when a newer one queues (GitHub Docs, "Control the concurrency of workflows and jobs":
   "any existing `pending` job or workflow in the same concurrency group will be canceled"), and ADR-0033 builds each tag
   once (counter-review). So a run takes nothing from the event that started it: it publishes the latest state, the newest
   release built and signed for the channel (each tag's build keeps its packages, databases and notes where the publisher
   reads them, never under the pointer) and the catalog of `main`'s head. A cancelled pending run loses nothing: the next run
   publishes what it would have; a run with nothing new writes nothing.
2. **Built from the current snapshot.** The job reads the pointer (the snapshot id and its version tag), takes that snapshot's
   manifest (every file with its SHA-256), and builds the new snapshot from it: the newest built release's packages,
   databases and notes when that release is newer than the snapshot's, else the snapshot's own; the catalog of `main`'s head
   when it differs from the snapshot's, else the snapshot's own. The catalog is used only once it passes the Store's own
   checks for that channel (the signature by a trusted key, the rules, the icons); "differs" compares a hash of its content
   with the serial and the build time left out (recorded in the manifest), and a changed catalog also needs a higher
   serial; only the icons the signed file lists are uploaded. Every file a new release brings (both databases, the notes,
   every package) must be signed the same way, checked with gpgv against the keyring before anything is uploaded. The job checks out `main` when it runs, never the commit that
   started it, so a re-run of an old run publishes nothing old. It lives in a workflow of its own that no pull request
   starts, with a protected environment per channel (ADR-0033 b.7).
3. **Never backwards.** The job refuses a snapshot whose `grassfield.db` names an older version of any package than the
   current one, unless it is ADR-0033 h.2's deliberate rollback (a new snapshot with a pkgrel above the bad one).
4. **A conditional pointer write.** The pointer is written only if it still names the snapshot step 2 read (a
   compare-and-swap: the storage's conditional write on the version tag); otherwise the new snapshot is discarded and the
   job starts again from step 2. Whether the chosen storage offers a conditional write is NOT VERIFIED (the host is not
   chosen, ADR-0033 O8); without one, step 1 alone serializes, and the job reads the pointer again just before writing it.

**Format (UTF-8 JSON, at most 1 MiB, no comments).** The major version is in the file name: a v2 would be published beside
v1 for as long as v1 clients exist. Unknown keys are ignored (additions stay v1).
```json
{
  "version": 1,
  "channel": "stable",
  "serial": 1793095200,
  "generated": "2026-10-27T10:00:00Z",
  "omarchy": { "tag": "v4.0.4", "commit": "c668141e9c42b13c80c9ca4ea108e11708c5e8a5",
               "files": { "bin/omarchy-install-browser": "…64 hex…", "install/helpers/browser-policy.sh": "…64 hex…" } },
  "sections": [
    { "id": "discover", "title": {"en": "Discover", "fr": "Découvrir"}, "symbol": "discover",
      "blocks": [
        { "kind": "hero",  "items": [ { "app": "org.gimp.GIMP", "eyebrow": {"en": "New in the Store"},
                                        "title": {"en": "…"}, "text": {"en": "…", "fr": "…"} } ] },
        { "kind": "cards", "items": [ { "app": "…", "eyebrow": {"en": "…"}, "title": {"en": "…"}, "text": {"en": "…"} } ] },
        { "kind": "row",   "title": {"en": "Tools for work"}, "apps": ["org.libreoffice.LibreOffice", "…"] } ] } ],
  "categories": [
    { "id": "graphics", "title": {"en": "Graphics", "fr": "Graphisme"}, "symbol": "category-graphics",
      "freedesktop": ["Graphics", "2DGraphics", "VectorGraphics", "RasterGraphics", "Photography"] } ],
  "apps": [
    { "id": "org.mozilla.firefox", "source": {"kind": "omarchy-setup", "install": "omarchy-install-browser", "args": ["firefox"],
        "remove": "omarchy-remove-browser", "removeArgs": ["firefox"], "packages": ["firefox"],
        "changes": {"en": "Installs Firefox and Omarchy's browser policy and Wayland setting."}},
      "categories": ["internet"] },
    { "id": "com.spotify.Client", "source": {"kind": "repo", "repo": "omarchy", "package": "spotify"},
      "name": {"en": "Spotify"}, "summary": {"en": "…", "fr": "…"}, "developer": {"en": "Spotify AB"},
      "license": "LicenseRef-proprietary", "homepage": "https://www.spotify.com/", "desktopId": "spotify.desktop",
      "icon": {"sha256": "…64 hex…", "bytes": 18234, "license": "LicenseRef-trademark-of-its-owner", "origin": "https://…"},
      "categories": ["music"] },
    { "id": "grassfield.webapp.hey", "source": {"kind": "webapp", "url": "https://app.hey.com"},
      "name": {"en": "HEY"}, "license": "LicenseRef-web-service", "icon": {"sha256": "…", "bytes": 9120, "license": "…", "origin": "…"},
      "categories": ["productivity"] },
    { "id": "org.inkscape.Inkscape", "source": {"kind": "flatpak", "remote": "flathub", "app": "org.inkscape.Inkscape"},
      "categories": ["graphics"] } ]
}
```
Rules (grassfield-packages' CI refuses a catalog that breaks one; the Store drops an entry that breaks one and keeps the rest,
and refuses the whole file when its top level is invalid):
- `channel` must be the channel the file was fetched from (the Store's `Server` path, or `stable` for the fallback); another
  value refuses the whole file. `serial` is per channel.
- Localized text: an object with `en` (required) and `fr` (optional); other languages are ignored by v1. Plain text: no
  control, format (bidirectional, zero-width, BOM, soft hyphen) or line and paragraph separator characters, except `\n` in
  texts; no markup (`<`, `>`, `&entity;`); Unicode NFC, no space at an end; lengths: section title 40, eyebrow 40, title 80,
  text and summary 200, description 4000 code points.
- `serial`: an integer that grows with every publication of the channel (CI uses the build's Unix time). The Store refuses a
  catalog whose serial is lower than the one it accepted for that channel (a replayed old catalog), and keeps its own.
- `sections`: at most 8, `discover` first; ids `^[a-z][a-z0-9-]{0,31}$`; at most 12 blocks each; `hero` 1 to 8 items,
  `cards` up to 12, `row` up to 24 apps; `symbol` from the Store's own symbol list (an unknown one falls back to a default).
- `categories`: at most 32, each with freedesktop category names; apps outside our list are placed by their AppStream
  categories.
- `apps`: at most 2000; `id` `^[A-Za-z0-9._-]{1,255}$`, unique (an AppStream id when one exists, so our texts overlay its
  metadata; AppStream's data joins an entry only when that component's package is one of the entry's packages, so an id
  alone never lends an entry another package's texts or desktop id); `source.kind` is `repo` (`repo` among `core`, `extra`, `multilib`, `omarchy`; the Store hides the entry when
  pacman's database has no such package), `aur` (shown only while the AUR is on), `omarchy-setup` (`install` and `remove`
  as in e.5, each of its own kind; `packages` say when it is installed; optional `removes`, the user data its removal
  deletes), `webapp` (an https URL; `icon` required), or `flatpak` (`remote` `flathub`, `app` a Flatpak id; shown only while
  Flathub is on). `license` is SPDX or `LicenseRef-…`; the package's or AppStream's licence wins when present.
- `icon` assets (owner, ST10: publishers' icons for apps without metadata, such as `[omarchy]` apps and web apps): PNG only,
  at most 256 KiB and 512 x 512, named by the SHA-256 of their bytes, which the signed file lists, so the Store checks the
  hash, with no signature per icon. Each records its licence and where it came from (`origin`, never fetched by the
  Store). An app with AppStream or Flathub metadata uses that icon, never ours. Publishers' icons are their owners'
  trademarks: needs legal review before any publication.
- `omarchy` (step 3b1): the Omarchy release the setups were read against (`tag` `^v[0-9]+(\.[0-9]+){0,3}$`, `commit` 40
  lowercase hexadecimal digits) and its pins, `files`: a path in Omarchy's folder to its SHA-256 (64 lowercase
  hexadecimal digits), 1 to 512 of them, each path 1 to 8 segments of `[A-Za-z0-9_.+-]`, no `.` or `..` segment, at most
  255 bytes. grassfield-packages' build writes it from `catalog/omarchy.lock` (below), and CI requires it whenever `apps`
  holds a setup, with each setup's `bin/<install>` and `bin/<remove>` pinned. The Store drops every setup of a catalog
  without valid pins and a setup whose recipes they do not name, hides a setup whose recipes the installed Omarchy lacks,
  and refuses every setup (Get and Uninstall… dimmed with the reason) while a pinned file of the installed Omarchy differs
  or is missing (SD19): checked when it reads the system, again in the plan check, and by `grassfield-store-run` under
  the lock (b.2).
- CI also refuses: a `repo` package absent from the build container's Omarchy stable package set (ADR-0033 f), or one that
  owns no application entry (its file list, `pacman -Fl`; SD1); a recipe name
  absent from the pinned Omarchy release, or whose text, or anything it calls or sources, syncs (any `-y` cluster,
  `--refresh` or `--sysupgrade` on pacman, yay or paru, and a `yay` or `paru` with no operation, which is `-Syu`; e.4),
  downloads code (`curl`, `wget`, `makepkg`, `git clone`, `pull` or `fetch`, `yay -G` or `-B`, and the language installers:
  mise except its read-only commands, npm, npx, pipx, pip, cargo, uv, go, gem; a) or builds from the AUR (a name no
  repository serves, or one known only at run time). **The control is the pin** (after grassfield-packages PR #4's review):
  `catalog/omarchy.lock` records the SHA-256 of every Omarchy file the catalog's setups run or read, transitively (43 for
  the three setups of v4.0.4), and CI refuses any such file that differs from its pin, is missing or is not pinned, until
  a person has read it and `catalog.py pin` writes the new pins. A shell cannot be judged by patterns alone, so the scan is
  the second line, run at pin time (no pin is written over a finding) and in CI: it reads the text as shell, comments and
  heredoc bodies set apart, each command found after its wrappers (`sudo -u`, `env`, `command`, `exec`, `timeout`...),
  `$(...)`, backquotes, process substitutions, a shell's `-c` argument and a terminal launcher's command read as commands;
  it refuses text it cannot read, `eval`, a script read from a pipe or a heredoc, a command made by a substitution, an
  Omarchy command named at run time, pacman's options known only at run time, pacman `-U` and the starts of `--refresh` and
  `--sysupgrade`, and lists a command named by a variable it cannot resolve for the person reading the files. Also refused:
  a `flatpak` id absent from Flathub's AppStream in the build container; a URL that is not https.

**Signature and verification.** `grassfield-catalog.v1.json.sig` is a detached binary OpenPGP signature by the repository's
key (ADR-0033 b, O6: the same key, in CI; tests use throwaway keys). The Store verifies it before parsing, exactly as
ADR-0033 d.8 verifies the release notes: `gpgv --keyring /usr/share/grassfield/pacman-keyring/grassfield.gpg --status-fd 1`
(the keyring's private folder, ADR-0033 b.2), the signer is VALIDSIG's argument 10 (the primary key's fingerprint), listed in
`grassfield-trusted` and absent from `grassfield-revoked` of that folder (their entries compared in upper case, spaces
around them ignored, so a hand-written revoked entry always counts; a list with any other line, such as a grouped
fingerprint, a `0x` prefix or a trailing comment, or a `grassfield-revoked` that is there but cannot be read, is not used
at all, and then no catalog is; a signature file with two signers is refused, and so is a `.sig` that is a signed message
of its own rather than a detached signature, `PLAINTEXT`). The check reads those files, not pacman's keyring,
so it works whether or not Grassfield updates are on. A catalog that fails is not used and not cached; the previous one
stays. While `grassfield-keyring` holds no key (until the owner's key exists, ADR-0033 O20) or is not installed, no catalog is
used and the Store says why.

**Built in grassfield-packages** from source files in its `catalog/` folder (one file per app, one per section, the
categories, the icons), by a standard-library Python tool, in CI, with the checks above. CI produces the catalog as an
artifact; publication stays disabled with ADR-0033's, and is the serialized publisher above once enabled.

## Owner decisions (2026-10-27, asked again after the first review; the answers in the owner's words)
| Id | Question | Options (the integrator's recommendation first) | Owner's answer |
|---|---|---|---|
| ST1 | master-prompt §4 lists a pacman-based store as a non-goal | amend §4: the Store in scope as the optional package `grassfield-store`, published after M5 · keep §4 (Flatpak-only App Center after 1.0) · the Store browsing only | « Amender §4 (Recommandé) » |
| ST2 | AUR and Flathub (the Arch and `[omarchy]` packages, web apps and Omarchy setups without downloaded code always on) | AUR opt-in, Flathub later · AUR opt-in, Flathub optional · neither · AUR on by default | « AUR et Flathub »; asked to clarify: « Les deux opt-in (Recommandé) » (both off until turned on; Flathub only when the user installed flatpak, no dependency) |
| ST3 | Authentication of per-user installs (web apps, Flatpaks), which need no root | the sheet alone · the user's password through a Grassfield polkit `auth_self` action (a new policy, against ADR-0030) | « Feuille seule (Recommandé) » |
| ST4 | The install path | P1: Omarchy's terminal, under its lock, with an exit-code file and time limits · P2: a Grassfield root helper behind polkit (repository packages only; against ADR-0033 and ADR-0028's R12 sentence, which must be amended) | « P2 : assistant root polkit »; asked about the AUR and the recipes: « Terminal pour AUR et recettes (Recommandé) » |
| ST5 | AppStream for Arch apps | depend on `archlinux-appstream-data` with `appstream-qt` · the Store downloads it · none | « melange du premier et du deuxieme »; asked to clarify: « Paquet, sinon téléchargement (Recommandé) » (the installed package when there is one, else the Store fetches it and keeps it in its cache) |
| ST6 | Screenshots (third-party hosts) | when the product page opens, with a switch · on a click · never | « À l'ouverture de la fiche (Recommandé) » |
| ST7 | AUR metadata, when the AUR is on | the AUR's web service (`info`, `search` after Return) · a daily copy of the whole AUR (10.6 MB) | « Service web de l'AUR (Recommandé) » |
| ST8 | The one update badge | Settings only (ADR-0033 U18) · both tiles · move it to the Store | « Réglages seulement (Recommandé) » |
| ST9 | Order of the steps | 1 catalog read-only and its build and signature; 2 the UI; 3 install, open, uninstall; 4 updates · UI first · 1 and 2 together | « Ordre proposé (Recommandé) » |
| ST10 | Icons of apps without metadata (the brief: "from their metadata, with their licence") | metadata only (the package's own icon, else a Grassfield glyph) · publishers' icons in our catalog, licence and origin recorded, legal review · a generic glyph | « Icônes d'éditeurs » |

## Decisions delegated by the owner (2026-10-27)
The owner's working rule of 2026-10-27, until further notice: the session decides, choosing the option that (a) brings
Grassfield closest to macOS 27 (behaviour, presentation, vocabulary) and (b) lets the end user do everything without technical
intervention (never a terminal, a configuration file, a command or a manual step of their own). Still asked: legal questions
(§14, marks, licences, publication), making anything public, a key, a secret or a release, wider root rights or changed
security rules (the project's working rules, master-prompt, ADR-0010, polkit beyond what is approved), money or an external service, and any
irreversible action on the owner's machine. The integrator checks each row in the review.

| Id | Question | Options | Choice | Rule applied |
|---|---|---|---|---|
| SD1 | Which repository apps the Store installs, now that `remove` takes apps with an application entry only (b.1) | only packages that own an application entry (AppStream desktop applications; catalog `repo` entries, checked by CI) · also command-line tools (AppStream `console-application`), which the helper could then not remove without a wider rule | only apps with an entry | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) the Store can always remove what it installed, with no terminal; a wider removal rule would widen root rights, which stays the owner's; (a) the macOS store application installs apps, not tools |
| SD2 | How the polkit sheet names the packages (counter-review) | the sheet shows "Install" or "Remove" and the names, read by a strict pattern from the line polkit expands for this action id only, else the line as is · the line as polkit expands it (the helper's path, the operation id, the names) · no names (refused by the review) | the verb and the names; the raw line when it does not match | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS's authorization sheet is plain words, no path; (b) the user reads what they authorize. The names still come from polkit (pkexec's argument vector), not from the Store; the sheet is a security module (step 3, opus review); no polkit rule changes |
| SD3 | Which step adds the list of other updates to the checker, and what goes first at its 256 KiB cap (counter-review, PR #16) | Software Update's step 2 adds it (`otherPackages`, PR #16's plan after its own review), the list cut before the notes · Store step 4 adds it · the notes cut first | Software Update's step 2, as PR #16 writes it; the list first | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS's Software Update always shows its release notes, while the per-app list is an addition; one checker, one list, one name for both PRs |
| SD4 | How the Store checks a fetched AppStream package (counter-review) | its own `.sig` with `pacman-key --verify` as the user (pacman's keyring and trust rule) · `gpgv` with pacman's public keyring (no trust check) · the sync database's SHA-256 (unsigned; refused by the review) | `pacman-key --verify`; **amended after the step-1 review**: gpg against a private copy of pacman's keyring, pacman's rule read from gpg's status lines and the key listing (c), since `pacman-key --verify`'s exit code passes any key of the keyring and a disabled one (S19) | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) nothing to set up; the Store trusts exactly what pacman trusts (S17, S19) |
| SD5 | How the Store reads Arch's AppStream (step 1) | its own reader of the catalog XML (`QXmlStreamReader`, zlib; the fields the Store shows, every text made plain) · `appstream-qt` (libappstream's pool, a new runtime dependency; it reads the system's data locations, so the fetched copy would need its extra-location API) | its own reader | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) nothing for the user to install or set up, and one reader for the installed and the fetched copy; the project's working rules "no new dependency without need": f's list loses `appstream-qt` |
| SD6 | Where "Settings…" goes in the menu bar (step 2) | File · a menu of the Store's own named after the app, beside the shell's · the toolbar's gear only | File, with Ctrl+, as on macOS; the gear in the toolbar only when there is no global menu bar | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS has the command and its shortcut in the app menu, which Grassfield's shell owns with Window (T0, ADR-0008), so the command keeps macOS's name and shortcut in the first menu the app fills (File, the first menu of Files and Preview too); the spec's "Store" menu becomes File |
| SD7 | What the local user's row at the bottom of the sidebar opens (step 2) | Installed · nothing (a label) · an "Installed" sidebar row | Installed | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS 27's account row opens the account page with the apps bought; Installed is the closest real list, in the same place, with no sign-in |
| SD8 | The app's button before step 3 can install or open (step 2) | shown with its state ("Get", "Open", "Installed"), disabled, a tooltip saying installing comes in a later version · hidden until step 3 | shown, disabled, with the tooltip | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) every macOS page has the button in its place, so the measured layout is the one step 3 fills; (b) the tooltip says why nothing happens, with no step to take |
| SD9 | When the Store is packaged and shows in Apps (step 2) | with step 3, when it can install · now, read only | with step 3 (the CMake install rules, the desktop entry and the icon are ready) | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) a Store whose every button is disabled would send the user elsewhere to install; step 2 runs in dev sessions and captures only |
| SD10 | The AUR and Flathub in the UI, and the Sources switches (step 2) | with step 3, with their install paths and the AUR warning · the switches now, without effect | with step 3; the settings window shows the switches' state, read only | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) a switch that changes nothing would be a step for nothing; macOS has no such sources, so nothing is lost against the reference meanwhile |
| SD11 | How step 3 is delivered | in three parts, each complete for its sources and reviewed on its own: 3a repository packages (the root helper and its policy, the polkit sheet's names) and web apps; 3b Omarchy's terminal (setups, with the pins of the installed Omarchy, and the AUR with its warning and switch); 3c Flathub (its switch, `flatpak --user`, the measured cancel) · one PR for everything | three parts | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: the root helper and its policy get a review of their own (e.9), and each part leaves no button that does nothing (SD8's tooltip stays on the sources still to come); the user's path is the same at the end |
| SD12 | SD1 in the helper's install (the integrator's note at step 0's PASS: "applied, or the gap accepted in writing") | the helper downloads the packages (pacman checks their signatures), reads each one's file list and refuses one without an application entry, before installing anything · the gap accepted (the Store offers only apps; a direct `pkexec` call with the administrator's password could install a tool the Store then cannot remove) | applied | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) whatever the helper installs, the Store can remove again, without a terminal; the extra commands are pacman's own (`-Sw`, `-Sp`, `-Qlp`), as root on files pacman has just checked; no root right is added |
| SD13 | The Store's window closes (Ctrl+W, Ctrl+Q, its close button) while an operation runs | the window closes, the Store stays without a window until the operation ends (it keeps Omarchy's lock and records the outcome), then quits; waiting ones are dropped · quit at once (the helper goes on; Omarchy's lock is let go) | stays until it ends | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS's installs go on after the store's window closes; (b) `omarchy update` cannot start in the middle of an install the user cannot see |
| SD14 | Where "Open Software Update" (a plan refused until the system is updated, SR15) goes while Settings has no Software Update pane of its own | Settings at General, where ADR-0033 puts Software Update · the shell's update indicator · nothing (the sheet's text alone) | Settings at General | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS sends there; (b) one click to where the update is, never a terminal |
| SD15 | The web apps in Installed that our catalog does not list (Omarchy's own, the user's) | Open and Uninstall… like the catalog's (the user's own launchers, b.3) · Open only | Open and Uninstall… | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) Omarchy's menu already removes any web app; a launcher in the user's files is the user's to remove, with the sheet alone (ST3) |
| SD16 | The polkit dialog left unanswered (the 120 s of b.1) | the Store ends pkexec (still the user's process until it starts the helper, a root process no user can signal) and says the request timed out · it keeps waiting | ends pkexec | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) the queue does not stay stuck behind a dialog the user may not see; nothing is ever signalled after the helper started |
| SD17 | The form of SD2's sheet for the Store's action (the integrator's note at step 0's PASS: "keeps Action: <id> and the helper path") | "Install xterm, gimp" (or "Remove …") in place of polkit's message, every name shown (past eight lines the list scrolls: wheel, drag, its scroll bar, Tab then the arrow keys), then "Enter your password to allow this.", "Action: org.grassfield.store.manage-packages" and "Program: /usr/lib/grassfield/grassfield-store-helper" · the message as polkit gives it | the plain words, then the action and the program | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS's authorization sheet says what is asked in plain words; the action and the program stay for whoever checks; the names come from polkit's own message, read by a strict pattern for this action id only (a message that does not match is shown as polkit gives it) |
| SD18 | How step 3b (SD11) is delivered | in two parts, each reviewed on its own: 3b1 the Omarchy setups (`grassfield-store-run`, Omarchy's terminal from the Store, the catalog's Omarchy pins, published by grassfield-packages and checked by the Store and the script), then 3b2 the AUR (its switch, its warning, its RPC, its verbs in the same script) · one part | two parts | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: the script and the terminal path are reviewed (e.9) before the AUR adds yay and packages no one reviews; each part leaves no button that does nothing (the AUR's stays dimmed with SD8's reason); the user's path is the same at the end |
| SD19 | What the catalog's Omarchy pins guard in the Store (3b1) | the whole set: any pinned file of the installed Omarchy that differs or is missing refuses every setup, until a catalog checked with that Omarchy comes · each setup's own files only (the files it runs or reads, transitively) | the whole set | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: the pins record what a person read for one Omarchy release (g); which file each setup reaches is the scan's reading, not part of the signed file, and shared helpers (the 32-bit drivers of the game setups) differ for several setups at once; Omarchy's updates replace its files together. (b) one reason for every setup, nothing to do but wait for the next catalog (each run of the Store reads the system again); a setup never runs a file no one has read |
| SD20 | Who writes the Store's preferences (`store.sources.aur`, `store.screenshots`, then `store.sources.flathub` in 3c) in `grassfield.json` (3b2) | the Store itself, as the Settings app writes its own keys today: the file read whole, every other key kept in its order, a malformed, unsafe or newer file never written, an atomic replace (`QSaveFile`, 1 MiB at most); until the shell's single writer of ADR-0020 item 4 exists · wait for that writer, the switches read only · a file of the Store's own | the Store, with the contract's rules | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS's App Store settings take effect when switched; (b) nothing to edit by hand. The keys are in the schema and the generated contract, read with its rule (not a boolean: the default); when the single writer comes, the Store sends its keys there like Settings (C6/C7) |
| SD21 | Which Omarchy commands the AUR runs, and what vouches for them (3b2) | Omarchy's own `omarchy-pkg-aur-add` and `omarchy-pkg-drop` (Omarchy's menu installs and removes AUR packages with them), pinned by the catalog always, whether or not it lists an AUR app; every AUR operation refused ("not checked with your version of Omarchy yet") while the catalog does not pin both or the installed Omarchy differs (SD19's rule) · `yay` and `pacman -Rns` run by the script itself · the commands unpinned | Omarchy's two commands, pinned always | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) the AUR installs as in Omarchy's own menu, in Omarchy's terminal; (b) nothing to configure. The same control as the setups: a person read the files for that Omarchy release (grassfield-packages' scan and pins, ADR-0037 g), the script checks them again |
| SD22 | How much one AUR operation does, its plan and its success (3b2) | one AUR package per operation, the one the user chose; the plan before the sheet: pacman does not resolve the name from the repositories (`pacman -Sp`: a package of that name, a provider of it or a group; else the repositories install it), the AUR knows it, the dependencies the system lacks (`pacman -T`) split into those pacman resolves (checked as any install: `pacman -S --print`, never an upgrade, the first file on the mirror) and those asked of the AUR in turn (at most 25 packages in 6 rounds; one the AUR does not have refuses the plan, one it cannot read marks it incomplete); success by name for what yay builds · several packages per operation · no plan, yay's own prompts | one package, the plan, success by name | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) the sheet lists what the operation adds before anything runs, as for every source; (b) yay's questions never reach the user (`--noconfirm`, Omarchy's own flags), and an AUR package's version is whatever its build makes, unknown before it |
| SD23 | The script's AUR checks and their exit code (3b2) | `grassfield-store-run` kind `aur`: the add refuses a name pacman resolves from the repositories (the package, a provider, a group); the drop requires a package installed explicitly from outside the repositories, not denied, whose whole `-Rs` plan names no denied package; a refusal is exit 7, nothing run (the Store says "The installation was refused: the system changed since the Store checked it. Try again from its page.", or for a removal "This app can't be uninstalled from the Store.") · the Store's checks only | the script checks again, exit 7 | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) the state can change between the sheet and the terminal (another window, Omarchy's menu); a check under the lock refuses what the plan no longer matches, the same way for every path (b.1's helper checks again too) |

| SD24 | How "Get Flatpak…" installs the `flatpak` package (a: Flathub "offered only when the user has installed `flatpak`"; step 3c part 3) | Omarchy's own `omarchy-pkg-add flatpak` in Omarchy's terminal through `grassfield-store-run` (kind `flatpak`, that command and that argument only), the password asked there as for a setup; the sheet over the settings window says what Flatpak is, that Omarchy installs it in a Terminal window, and that Flathub's apps reach the launcher after the next login (S20), then pacman's plan; grassfield-packages pins and scans the command always and checks that Omarchy's mirror has the package · the root helper with the Store's own password sheet (SD2): `flatpak` owns no application entry, so SD1 would have to make an exception, a wider root surface (the owner's to decide) · a line telling the user to run `omarchy-pkg-add flatpak` (a technical step) · `flatpak` as a dependency of `grassfield-store` (ST2 keeps Flathub optional) | Omarchy's `omarchy-pkg-add flatpak` in its terminal | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS installs nothing for an app store, but its way is one button and one password; the button is in the settings, beside the switch it unlocks; (b) one click and the password, nothing typed: the terminal asks for the password as every setup does, and the root helper is not widened (that choice stays the owner's: the polkit sheet would be closer to macOS). **Amended after PR #65's review** (what "no root surface" covers): Grassfield adds none, but the `flatpak` package brings flatpak's own, for system installs (read from Arch's `flatpak` 1:1.18.4-2: S30, `store-probes-6.sh`): `flatpak-system-helper`, a root D-Bus service started on demand; its polkit policy; a rules file under which a member of `wheel` in an active local session installs and removes system-wide apps and runtimes, and changes the system repository, with no password; and a system `flathub` remote (`/usr/share/flatpak/remotes.d/flathub.flatpakrepo`). Adding a system remote, a bundle, or changing the configuration still asks (`auth_admin_keep`). Omarchy's GeForce NOW recipe leaves the same; Omarchy 4.0.4 does not install `flatpak` otherwise. The Store uses `--user` only and touches neither the system installation nor its remotes |
| SD25 | What a Flatpak's sheet shows before it installs (a: "what a Flatpak can reach … and the size of the runtimes it pulls"; step 3c part 2) | flatpak's own plan, read on a pseudo-terminal of the Store's (flatpak asks only on one) and answered yes for the runtime it requires, no to proceed: every ref it would add (the app, its runtime, their GL, codecs and locale extensions) with the most each downloads, nothing installed (S23); and the app's metadata (`remote-info --show-metadata`: `[Context]`, `[Session Bus Policy]`) in plain words · the app's and its runtime's `remote-info` alone (misses the extensions: about 700 MB of S23's 1.1 GB) · no sizes, the permissions only | flatpak's own plan, and the metadata | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS's App Store gives the size before Get, and says what an app may reach before it does; flatpak's own plan is what flatpak then does, not an estimate; (b) the sheet alone, no terminal; a plan flatpak cannot give (another question, which is answered no or 0, no table, 60 s) refuses with flatpak's words. **Amended after PR #58's review** (the access list understated: a bus name, `ssh-auth`, `gpg-agent`, `pcsc`, `kvm`, `shm`, `devel` gave "only its own window and files"): every grant of the metadata is named, a grant the Store does not know as flatpak writes it, every bus name outside a harmless list (notifications, tray, menus, screen saver, accessibility, file manager, the portals, media-player names, its own), and "outside its sandbox" for the whole session bus and for org.freedesktop.Flatpak, org.freedesktop.systemd1 and the permission store (by name or a wildcard; `see` grants nothing); metadata that names no app gives no plan, and an unread one nothing on the page. **Amended after PR #65's review**: `X.*` is X and every name below it (as xdg-dbus-proxy reads it), and an app whose id is an escape, or holds one, owns it; paths are normalised before they are read (`//`, `/./`, a trailing `/.`; `..` could be anywhere; `/home/<user>`, `/var/home`, `/run/user/<uid>`); "Programs that start when you log in" for every writable place a program starts from at the next login (autostart, systemd user units, Hyprland's and uwsm's configuration, environment.d, the shells' start files, `~/.local/bin`); "outside its sandbox" for the session bus's and systemd's sockets (`xdg-run/bus`, `xdg-run/systemd`, read-only too) and for flatpak's own folder, the session's D-Bus services and the launcher's entries written. **Amended again after PR #65's re-review**: every list is read as flatpak reads it (S29): the key file's escapes and `;`, then a filesystems entry's own (`\x` is x, the first `:` not escaped starts its mode), its path normalised before `host`, `host-os`, `host-etc` and `home` are matched; a value flatpak cannot interpret makes the metadata unread (no plan); anything in the runtime folder but the sound server's sockets and the app's own folder (Hyprland's IPC, docker, the bus...), and the system's `/run` but removable media (`/var/run` is `/run`), are "outside", read-only too; `~/.config/omarchy` (its post-boot hooks run at each login) starts programs at login; a writable folder above flatpak's own, the D-Bus services or the launcher's entries (home, xdg-data, host) is "outside" too; owning a portal's or the notifications' name is named (they are harmless only to talk to) |
| SD26 | Stopping a Flatpak install (a: "measured before a cancel is offered"; S25) | Stop on the ring (its square, as a waiting operation's) and in the queue's menu: SIGTERM to flatpak, which ends in milliseconds and leaves nothing half-installed (what it finished, runtimes, stays for the next install or `--unused`; what it was downloading waits in flatpak's own folder and the next install takes it up, which `store_flatpak.sh` checks; `repair --dry-run` finds nothing); no time limit; the Store's child stops with it (SIGTERM) · no stop · SIGKILL · a time limit | Stop, by SIGTERM | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS stops a download from its ring; (b) one click, and the next Get installs what is missing; nothing to clean. A removal is not stopped (seconds) |
| SD27 | What uninstalling a Flatpak removes (S26) | the app (with its locale), then `flatpak uninstall --user --noninteractive --unused`: the runtimes no installed app needs (a runtime installed by name stays, S26); its data in `~/.var/app/<id>` stays and the sheet says where · the app alone (gigabytes of runtimes left, which the Store never shows) · its data too | the app, then the unused runtimes; the data stays | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) deleting a macOS app leaves no shared part the user never chose, and keeps its data; (b) nothing left to clean, no command |
| SD28 | How step 3c (SD11) is delivered | in three parts, each reviewed on its own: 3c part 1, the review notes on grassfield PR #36 (3b2's follow-ups, Arch's app data, the system older than its mirror) and Flathub's groundwork (the probes S20 to S26, the AppStream reader taking Flathub's components); part 2 the Flathub source (its switch, `flatpak --user`, flatpak's own plan, the stop, the uninstall, the runtimes left); part 3 "Get Flatpak…" (the `flatpak` package, which no Omarchy install has, through Omarchy's own `omarchy-pkg-add` in its terminal, pinned) · one PR | three parts | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: the integrator asked for the fixes now (the 3c PR opened with them); the Flathub source then rests on measured facts, and the package install, which changes the system, gets a review of its own (e.9); Flathub's switch stays dimmed with SD8's reason meanwhile |
| SD29 | How the Store knows the system is older than its mirror before anything downloads (the integrator's note on PR #36: "a sync DB older than a threshold, Software Update's own staleness rule"; amended after the review of ff2fd83, which found the first rule read only the `available` state, never written for Arch's updates alone nor with Grassfield's repository off, the owner's case) | Software Update's own answer, whatever the state it carries the counts in (up-to-date, available, not-set-up; a failed check's `previous`): pending other updates or an Omarchy release, checked after pacman last completed a sync (the newest database's ctime, S27; amended again after PR #54's merge, which found pacman.log's line counted a failed sync); then a HEAD of every file of the plan, all at once with one deadline; pacman's 404, 410 or oversize after the fact · an age of our own for the databases (a week), or the mirror's database date against ours · the Store refreshes the databases (`pacman -Sy`) | Software Update's answer, the HEADs, pacman's errors | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: Software Update has no age rule (its only freshness is the pane's 60 s, ADR-0033); its checker's count is the mirror's own answer (checkupdates against a fresh copy of the mirror's databases), where an age, or a database date on a mirror that changes every hour (Arch's own), says nothing of whether the files are still there. The HEADs are the exact test, its count the early one. (a) macOS's App Store sends to Software Update first; (b) one button, never a command; a refresh of the databases alone is the partial upgrade e.4 forbids |
| SD30 | AUR packages with a name of the deny list (the integrator's note on PR #36: "refuse `grassfield-*`/`omarchy-*` on the AUR path, or label by origin") | refused: every name b.1's deny list names (the system's, Omarchy's prefix and lists, `yay`, Grassfield's prefix, `HoldPkg`), the app's and every package its plan builds from the AUR, in the Store (Get dimmed with the reason, the plan refused) and again in the script (exit 7); Omarchy's lists unread refuse · only `grassfield-*` and `omarchy-*` · labelled by origin, installable | the whole deny list, refused | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) what the Store installs, it can remove again (b.1's list refuses the removal of every such name); an AUR package that takes Omarchy's or Grassfield's name is not theirs, and the user should not have to tell. An AUR app whose name only looks like the system's (`linux-wifi-hotspot`) is refused too, as its removal would be |
| SD31 | A "flathub" remote the user's installation already has, and how Flathub's key is trusted (the integrator's INFO on PR #58) | `remote-add --if-not-exists`: the user's own remote is kept, whatever its address (a mirror the user set) or signature setting; Flathub's key as its `.flatpakrepo` carries it, over TLS to dl.flathub.org, no fingerprint pinned · check the existing remote's address and signature setting and refuse another (the user repairs it in a terminal) · say where it points in the settings · pin Flathub's key fingerprint in Grassfield (a release for every rotation) | keep the user's remote; trust Flathub's key by TLS, as Flathub's own instructions do | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS's App Store has one source the user never sets up, and Flathub's switch keeps that; (b) refusing would leave a switch that only a terminal repairs; the remote's file is in the user's own installation, writable only by the account that runs the Store, so a refusal protects nothing that account could not change; flatpak still checks each commit against the remote's key unless that account turned it off. Revisit with step 4 if the integrator wants the settings to say where Flathub points |
| SD32 | What the Updates page's "Update All…" does for the system (d), now that ADR-0033's Update Now is a run Settings owns (its step 3, SU-M1: Grassfield's password dialog, the progress, Restart or a terminal for what needs a person) | it opens Software Update (Settings > General, the Store's "Open Software Update" path), where Update Now updates the whole system; the page names what the update brings and follows Omarchy's update lock while it runs · the Store starts `grassfield-update-run` itself and shows the run (a second launcher of the run, its progress, Restart and terminal paths repeated in the Store) · a new request to Settings over its D-Bus name that starts Update Now (a new IPC method that starts a root-asking run) | Software Update opened | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) on macOS the App Store sends system updates to Software Update; (b) one click to Software Update, then its own Update Now and password: nothing technical, and one owner of the run, its password and its end |
| SD33 | How a Flatpak updates, and what it says first (d, SD25 for an update) | `flatpak update --user --noninteractive -- <refs>` as the Store's child (an app's ref, or the group's apps and runtimes from Flathub); before it, what the newer commit's metadata (`remote-info --show-metadata`) lets the app reach that the installed one's (`info --show-metadata`) does not: nothing new, it starts at once; something new, or unread, a sheet says it with Update and Cancel; done when a new check no longer lists the refs (S31d: offline, flatpak exits 0 with "Nothing to update.") · always a sheet · never a sheet (flatpak's `--noninteractive` accepts new permissions silently) · `flatpak update` with no ref (every remote's, the user's own too) | a sheet only when it reaches more. **Amended after PR #97's review** (MINOR 6: a newer commit published between the plan and the update was accepted silently): the plan reads each app's commit (`remote-info --show-commit`) and that commit's metadata (`--commit=<c>`); the update deploys that commit (`--commit=<c>`, one ref per command, S32), done when it is installed; Update All takes every listed ref (MINOR 4: no 64-ref dead end). **After PR #97's merge** (its note): the plan also reads each pinned app's installed commit, and an app installed with another commit by its turn was updated outside the Store (a terminal, another store) and is left as it is: its pinned command is not run (never a downgrade), and it counts as done | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS updates an app without asking, and asks when an app wants something new; (b) one click; an update the Store could not check is never silent |
| SD34 | How the Store searches by document type (ADR-0035 5c-3's follow-up: Files' "Search the Store") | the media types AppStream gives (`<provides><mediatype>`, the older `<mimetypes>`, Arch's and Flathub's), the type first, then its parents in the MIME database's order (never `application/octet-stream`), by name in each; `grassfield-store --page=type:<type>`; Files offers the button only when the Store is installed and the type is well formed · the type alone (a C file finds no text editor) · the words of the type's description as a text search (finds apps by name, not by what they open) | AppStream's types, then parents | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) Finder's alert has "App Store…", which searches by the document's type; (b) one click from the alert to the apps that open it |
| SD35 | One Store window (the page Files asks for while the Store runs) | one Store per user: the running Store owns `org.grassfield.Store` on the session bus (`.Dev` and a digest of the state directory in a dev or isolated run, as Settings'), a second launch hands it its `--page` and activation token (`Open(s page, s token)`) and leaves; the page is checked again by the window (StoreNav); the Dock brings an off-screen window back (`dock reopen`) · a second Store process (two queues, two windows) | one Store per user | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS has one App Store window; (b) nothing for the user to close or choose. The method opens a page and brings the window forward, nothing else: no install, no plan (docs/specs/security.md) |

## Amendments made in this PR (other documents)
- **master-prompt §4** (ST1): the non-goal "a pacman-based app store" is amended for Grassfield Store.
- **ADR-0033**: d (the Store reads the list of other updates that Software Update's step 2 adds, `otherPackages`, in PR #16's
  words), g (the catalog's files in the contract; the publication row), h.2 (one serialized publisher that publishes
  the latest state, built from the current snapshot, a conditional pointer write), and the
  "no root code to install anything" of its context (ST4's helper is the exception). Its spec `docs/specs/updates.md`: U3 and
  the non-goals likewise.
- **ADR-0028**: its R12 sentence names `grassfield-store-helper` beside ADR-0033's two programs.
- **ADR-0030**: an amendment for the Store's helper and its polkit policy (`auth_admin`, never kept; the names in the
  message), beside ADR-0033's.
- **ADR-0035** (step 4): 5c-3's follow-up done: Finder's alert gets "Search the Store" once Grassfield Store is installed
  (SD34); its spec `docs/specs/system-dialogs.md` likewise.
- **docs/specs/security.md** (step 4): the Store's session-bus name (SD35) and the Store among `dock reopen`'s callers.

## Evidence
- `docs/audits/store-2026-10-27/store-probes.sh` (S0 to S15) and its output `probes-output.txt` (docker exit 0). It ran in this
  cloud session's container (Ubuntu 24.04, root in the session's sandbox) with the Docker 29.9.2 daemon started in the
  session: `docker run --rm --network host` with the session's HTTPS proxy and its CA mounted read-only, on
  `archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0` (ADR-0033's image). Mounted read-only,
  as data: Omarchy v4.0.4 (c668141), cloned from github.com/basecamp/omarchy. The script refuses to run outside a container;
  inside it is root, makes a user `alice`, installs packages from Omarchy's stable mirror and from Arch's archive
  (archive.archlinux.org, snapshots 2026-03-01, 2026-09-01, 2026-10-20), interrupts pacman on purpose, and everything goes with
  the container. The one change to Omarchy's template is `DisableSandbox` (Docker has no Landlock), as in ADR-0033.
- `docs/audits/store-2026-10-27/store-probes-3.sh` (S19, after the opus review of step 1) and its output `probes-3-output.txt`
  (docker exit 0): a throwaway packager key in the image's own pacman keyring, added, locally signed, then disabled.
- `docs/audits/store-2026-10-27/store-probes-2.sh` (S16 to S18, after the counter-review) and its output
  `probes-2-output.txt` (docker exit 0), with the same container, image and Omarchy checkout. It registers system packages
  with `pacman -S --dbonly --noscriptlet` (the rule reads pacman's database; nothing of theirs runs), builds one local package
  with `makepkg` as the user, starts a system bus and polkitd, and gives the user `alice` a throwaway password. The rule and
  the helper in it are models for the probe; the helper is step 3's code. S18 ran polkit 127-3 (the 2026-09-01 snapshot);
  the source lines cited are polkit 128's (Arch's current version; tag 128 of github.com/polkit-org/polkit), where they read
  the same.
- `docs/audits/store-2026-10-27/store-probes-5.sh` (S27, after PR #54's merge) and its output `probes-5-output.txt` (docker
  exit 0), the same image, Arch's archive at 2026-10-20: a sync that downloads the databases sets each file's ctime to
  that moment and its mtime to the mirror's Last-Modified (2026-10-19 and 2026-10-20); the same sync again (not modified)
  and a forced `-Syy` to a mirror that does not exist (exit 1) change neither, while pacman.log has the same "synchronizing
  package lists" line for all three.
- S29 to S32 (`store-probes-6.sh`, `store-probes-7.sh`, `store-probes-8.sh`, outputs `probes-6-output.txt` to
  `probes-8-output.txt`; flatpak 1:1.18.4-2 in throwaway containers): how flatpak reads a filesystems entry (S29), what the
  package installs for system installs (S30), and its updates (S31): `remote-ls --user --updates` lists apps and runtimes
  with their origin and ref; an app's update takes the newer runtime it needs with it (S31b); nothing to update says
  "Nothing to update." and exits 0, and so does an update offline, which updated nothing (S31d). Pinning (S32):
  `remote-info --show-commit` prints the 64-digit commit, and `--commit=<c> --show-metadata` that commit's metadata even
  once a newer one is published (S32a, S32b); `update --commit=<c>` deploys that commit while a newer one is the newest
  (S32c), which a new check then lists (S32e); `--commit` with two refs is refused ("With --commit, only one REF may be
  specified", exit 1), an unknown or malformed commit exits 1 (status 404) (S32d).
- `tests/integration/store_flatpak.sh` (step 3c part 2; S28): the real flatpak 1.18.4 in a throwaway Arch container, with a
  local repository standing for Flathub (a runtime with a 20 MB file and an app made with flatpak's own `build-export` and
  `build-update-repo`, served slowly over http on 127.0.0.1, added as `flathub` to root's own installation; nothing reaches
  Flathub), driven through the Store's own code: Flathub's AppStream as flatpak copies it, flatpak's own plan on the
  Store's pseudo-terminal (its table with the escape sequences and the no-break spaces of a real terminal), the app's
  facts, an install stopped half-way (nothing installed; what it was downloading waits in a staging folder, which the next
  install takes up), an install, a removal followed by `--unused`. S28: for a remote without a collection id, flatpak
  1.18.4's `info` and `remote-info` print every field, then abort on an assertion (exit 134), so the Store reads their lines
  whatever the exit code and asks `list` whether an app is installed.
- `docs/audits/store-2026-10-27/store-probes-4.sh` (S20 to S26, step 3c) and its outputs `probes-4-output.txt` and
  `probes-4-output-run1.txt` (docker exit 0 both), the same image and Omarchy checkout, Arch's archive at 2026-10-20 and
  Flathub as it was on 2026-10-28: the `flatpak` package owns no application entry and adds its exports to
  `XDG_DATA_DIRS` only from the next login; `flatpak remote-add --user` takes a second, no root; Flathub's AppStream
  (3316 desktop apps, 2540 verified) and icons in the user's installation; `remote-info` gives sizes and permissions;
  flatpak's own plan on a pseudo-terminal, answered no; an install, stopped with SIGTERM, SIGINT and SIGKILL at several
  moments and resumed; uninstalling keeps `~/.var/app`, `--unused` keeps the runtimes installed explicitly. Flathub's key
  is printed by its long id only (its fingerprint reads as a secret to gitleaks; the integrator's note); the two outputs,
  which ran before that change, have that one line cut to the long id the same way.
- The macOS 27 reference: `docs/audits/store-2026-10-27/parity.md` (Apple's user guide, two public captures, not committed).

## Consequences
- **Step 1, grassfield-packages:** `catalog/` sources, the build and validation tool, a CI job producing the signed catalog
  as an artifact with a throwaway key, the serialized publisher written and disabled; its README and the project's working rules name the role
  (done in step 0).
- **Step 1, here:** `apps/store` backend read-only: fetch, `gpgv` verification, validation, cache, AppStream (package or
  fetched) and pacman readers, the merged model and search, all tested with fake catalogs, a throwaway keyring and fake
  pacman/AppStream roots; ADR-0019 dev plumbing rows; ADR-0020 persisted-file rows; opus security review of the
  verification. Delivered as a static library and its gtest suite (`apps/store/src`, `tests/unit/store`, 45 tests, plain
  and ASan) plus `tests/integration/store_catalog.sh` (the real gpgv against throwaway keys in a throwaway container); no
  app binary and no package yet (step 2).
- **Step 2:** the UI (Discover, sections, Categories, product page, search, Installed, the Updates list read-only), measured
  F1 against the captures, en and fr, light and dark, keyboard; offscreen captures with the fake backend; the nested shot by
  the integrator. The legal items of e.10 go to `docs/legal/visual-review.md`.
  Delivered (2026-10-27): the app `grassfield-store` (`apps/store/src/main.cpp`, `storebackend`, `storeview`, the screenshot
  provider; `apps/store/qml`), its desktop entry and icon, 138 `store.*` tokens, the Store's strings in French; the
  backend loads in a worker after the window's first frame and gives the QML immutable snapshots; screenshots only over
  https, at most 8 MiB, 15 s, 8192 px a side, every decoder bounded to 128 MiB; links open only over https, never in a dev
  session. Captures and F1 measures in `docs/audits/store-2026-10-27/step2.md` (every item within 1 pt but the card text's
  ink, which follows the words); E36 and question 12 in `docs/legal/visual-review.md`; decisions SD6 to SD10. Two
  corrections to step 1's code: the AppStream reader takes only a component's own children (a `<provides>`, `<suggests>` or
  `<extends>` id, or a release's or an agreement's name and description, no longer overwrite the app's), and it now reads
  releases, languages, the content rating, the bug tracker and screenshot captions for the product page.
  `RimmedCapsule` moved from Settings to `Grassfield.Ui` (shared with the Store; `docs/specs/ui-api.md`). `--page` opens a
  page first (discover, `section:<id>`, categories, `category:<id>`, `app:<id>`, `search:<words>`, installed, updates);
  `GRASSFIELD_STORE_OFFLINE` is ADR-0019 dev plumbing.
- **Step 3:** install, open, uninstall: `grassfield-store-helper` and its policy (b.1: `auth_admin`, the remove rule with
  S16's cases as tests, the plan check), the polkit sheet's names for this action (SD2), `grassfield-store-run` (b.2), web
  apps and Flatpaks (b.3); container tests with real pacman installs, a real recipe, a real `flatpak install --user` of a
  small app and an interrupted one (throwaway container), fake programs everywhere else; opus security review; the owner
  checks the real polkit dialog, sudo in Omarchy's terminal and a closed terminal in a real session. In three parts (SD11):
  - **3a (delivered for review, 2026-10-27):** repository packages and web apps. `packaging/store/grassfield-store-helper`
    and `org.grassfield.store.policy` (b.1, SD12); the polkit sheet's plain words for this action (SD2, SD17;
    `shell/security/polkit/AuthDialogModel.qml`); the plan check (`apps/store/src/plancheck.*`: pacman -Qu, -S --print,
    the first file's HEAD, the locks; -Rs --print and its dependents), the removal rule as the user
    (`removal.*`, held to the helper's answers by `tests/fixtures/store/removal-vectors.json`), the queue
    (`operations.*`: one at a time, pkexec in a session of its own while the Store holds Omarchy's lock, the helper's files,
    pacman's log for the count, store.json's record and the recovery at start, SD13, SD16), web apps through Omarchy's
    commands as the Store's children, Open (`uwsm-app -- <id>`, `omarchy-launch-webapp <url>`), Installed's other web apps
    (SD15); the confirmation sheet, the button's ring and the queue in the toolbar, Uninstall… in the product page's menu
    and in Installed's context menu with the reasons, how an operation ended (Try Again, Details…), a lock pacman left
    (Arch's way, as text); the window's keys gated on the key window, as Files (the integrator's note at step 2's merge);
    the package `grassfield-store` (SD9). Tests: `tests/integration/store_helper.sh` (the real helper, policy, polkitd
    and pkexec, a local repository of test packages and xterm from Arch's mirror, in a throwaway container),
    `tests/unit/store/tst_{plancheck,removal,operations}.cpp` (fake pkexec, pacman and Omarchy commands),
    `tests/unit/tst_storeoperations.qml`, `tests/security/tst_authdialog{,model}.qml`; the window's keys under a real
    Wayland compositor (`docs/audits/store-2026-10-27/tools/wayland-keys.sh`, sway headless).
  - **3b1 (delivered for review, 2026-10-28; SD18):** the Omarchy setups. `packaging/store/grassfield-store-run` (b.2, its
    lock on a descriptor of its own instead of step 0's `flock -n -o`); the catalog's `omarchy` object (g; SD19), parsed by
    the Store (`catalog.*`), compared with the installed Omarchy (`plancheck.*`: `omarchyDifference`, `checkSetupInstall`,
    `checkSetupRemove`, `Refusal::OmarchyChanged`) and written to `<op-id>.pins` for the script; the queue's terminal path
    (`operations.*`: the launcher's command, the script's files, 75 s to start, 3 h to run, recovery, its exit codes); Get
    and Uninstall… for setups (`storebackend.*`: hidden without its recipes, refused while Omarchy differs, never a
    package of the deny list, Open by its first package's entry); the sheet's setup text (what it changes, the recipe and
    its terminal, the files its removal deletes), "Opening Terminal…", "Installing in Terminal…", the new outcomes.
    Tests: `tests/integration/store_run.sh` (the script as a user in a throwaway container: usage, the lock while the
    recipe runs and after a process it leaves, Ctrl+C, every refusal, the pins), `tst_plancheck.cpp` Setups,
    `tst_operations.cpp` Terminal*, `tst_catalog.cpp` OmarchyPins, `tst_storebackend.cpp` (with the real gpgv),
    `tst_storeoperations.qml` test_setupSheet, `tst_storetext.qml`. grassfield-packages publishes the pins in the same
    step, with the next catalog change (find's -exec and run-parts in the scan).
  - **3b2 (delivered for review, 2026-10-28; SD20 to SD23):** the AUR. Its switch and the screenshots' in the Store's
    settings, written to `grassfield.json` (`Preferences.js`, SD20); the AUR's web service (`aur.*`: RPC v5 `info` and
    `search`, the PKGBUILD, 512 KiB an answer, an hour's cache of 4 MiB, dev plumbing `GRASSFIELD_STORE_AUR_URL`); search
    after Return with its own section; AUR pages (`aur:<name>`) with the AUR's facts and "View Build Script"; the plan
    (`plancheck.*`: `checkAurInstall`, `Refusal::Repository`, `Refusal::NotOnAur`) and the sheet with the warning;
    Uninstall… through `omarchy-pkg-drop` with b.1's deny list and the whole plan; Installed's "AUR" group;
    `grassfield-store-run` kind `aur` (b.2, exit 7). Tests: `tst_aur.cpp`, `tst_plancheck.cpp` AurPlans,
    `tst_operations.cpp` AurThroughTheTerminal, `tst_storebackend.cpp` TheAur and SourcesFromGrassfieldJson,
    `tst_storepreferences.qml`, `tst_storemain.qml`, `tst_storeoperations.qml`, `tst_storetext.qml`;
    `tests/integration/store_run.sh` (the AUR's refusals); `tests/integration/store_helper.sh` (an AUR package installed
    and removed end to end, with a stand-in yay). grassfield-packages pins and scans the two commands always (SD21) and
    checks a catalog's AUR apps against the AUR.
  - **3c:** Flathub (its switch, `flatpak --user`, its metadata, the measured cancel). Part 2 (SD25 to SD27):
    `apps/store/src/flatpak.{h,cpp}` (the user's installation, the plan on a pseudo-terminal, what an app can reach, the
    progress), the model's Flathub apps, the `flatpak` path of the queue (install, Stop, uninstall then `--unused`,
    recovery), Open, Installed's Flathub group, the switch, the sheet and the page's facts. Tests: `tst_flatpak.cpp` (a fake
    flatpak that asks on a terminal only), `tst_storemodel.cpp` Flathub, `tst_operations.cpp` Flatpak*, `tst_storebackend.cpp`
    Flathub, `tst_storetext.qml`, `tst_storeoperations.qml`, `tst_storemain.qml`.
    Part 3 (SD24): "Get Flatpak…" in the settings, `grassfield-store-run` kind `flatpak` (b.2), the operation's record
    (`kFlatpakAdd`), its plan and its pins (`requiredPins`), the settings' line and the launcher's note after the next
    login. Tests: `tst_operations.cpp` GetFlatpakThroughTheTerminal, `tst_plancheck.cpp` Setups, `tst_storebackend.cpp`
    GetFlatpak, `tst_storemain.qml` getFlatpak; `tests/integration/store_run.sh` (its refusals);
    `tests/integration/store_helper.sh` (the real `flatpak` package through Omarchy's own `omarchy-pkg-add`).
    grassfield-packages pins and scans `omarchy-pkg-add` always and checks the `flatpak` package on Omarchy's mirror.
- **Step 4:** the Updates page (system updates through ADR-0033's checker and its `otherPackages`, SD3; Flatpak updates checked by the Store) and the sidebar count; no Dock badge of the
  Store's own (ST8). Built (`docs/audits/store-2026-10-27/step4.md`):
  - the page: the file watched and the shell asked to check (Check Now, the page's opening), `pacman -Qu` for an unfinished
    update, Omarchy's update lock followed while it is shown, "Update All…" opening Software Update (SD32);
  - Flatpak updates: `remote-ls --user --updates` (S31), each app's Update and the group's Update All as the Store's child,
    the product page's Update, a sheet only when an update reaches more (SD33), each app pinned to the commit its plan read
    (S32), done by that commit installed or a new check (S31d);
  - the sidebar's count; the remaining step 3 follow-ups (the dimmed Sources line names Flathub, the notice's lifetime a
    token, `store.noticeLifetime`);
  - the search by document type (SD34) and Files' "Search the Store" (ADR-0035 5c-3), with one Store per user (SD35).
- **IPC.** Steps 1 to 4 add no shell IPC function: Check Now calls ADR-0033's `update check user`, whose row already names the
  Store, and an off-screen window asks the Dock's `dock reopen` (its row now names the Store). Step 4 adds the Store's own
  session-bus name `org.grassfield.Store` (SD35: `Open(page, token)` opens a page and brings the window forward, nothing
  else), recorded in `docs/specs/security.md` (Grassfield Store's session-bus name).
- **Known limits** (spec): a password for every repository install or removal (no grace period); "Uninstall…" only for apps
  the user installed, never for Omarchy's, Grassfield's or the system's packages; no per-app update for repository and AUR
  apps (Flatpaks have one; the system's Update All… opens Software Update, SD32); nothing installs while the last
  system update is unfinished; Flatpak updates are not part of `omarchy update` and have no Dock badge; no ratings or
  reviews; no pause or resume; the AUR and setups cancel only in Omarchy's terminal; apps outside AppStream and our catalog
  show pacman's text only; Omarchy's recipes are Omarchy's, their effects as they are in the installed release; a replayed
  old catalog is refused only once a newer one was seen.

## Review history
First opus review of PR #15 (integrator, 2026-10-27): FAIL, no blocker, 3 MAJOR, all in the docs. Confirmed by the reviewer:
the Omarchy recipe claims, the parity geometry, the free number 0037, the author without trailer, the hard rules kept in
grassfield-packages. Each finding and where it is answered:
- **MAJOR 1**, a partial upgrade still passed the install check (the keyring step's `-Sy` of `omarchy update`, then a plan
  that upgrades nothing): e.4 refuses while `pacman -Qu` lists anything but "[ignored]", checked again right before running
  (b.1, b.2), and CI refuses recipes that sync (g); S12.
- **MAJOR 2**, the Store could not tell when a detached terminal's installation ended: every path ends with an exit code
  (b): pkexec waited for (b.1), the terminal's script under Omarchy's lock with `started` and `exit` files and time limits
  (b.2; `flock -o` rather than `omarchy-update-lock run`, whose descriptor a launched app keeps, S13), the user's own
  children waited for (b.3); success = exit code 0 and state.
- **MAJOR 3**, catalog snapshots could roll the package database back: g "Publication", one serialized publisher per
  channel, built from the current snapshot, never backwards, a conditional pointer write; ADR-0033 h.2 amended in this PR.
- **Minors:** web apps open by URL (`omarchy-launch-webapp`), their ids having spaces uwsm refuses (f, S14); foreign packages
  are "Not from a repository", Grassfield's own builds excluded, Omarchy's base apps and Grassfield's packages protected (a);
  ADR-0033 d, g and h.2 amended, and ADR-0028 and ADR-0030 for the helper ("Amendments"); ST3's polkit option recorded as
  against ADR-0030 and P2 as against ADR-0033 (decisions table); "needs legal review" on every legal point (e.10, c, g);
  `install` and `remove` patterns of their own kind and the `channel` field checked (e.5, g); evidence: the S0 label
  corrected (S5 to S15 on Arch's archive), the S7 and S8 values now in the output (flatpak's version, the overlap with
  Omarchy's lists, `cache-control` instead of a refresh period), the closed real terminal marked NOT VERIFIED (S6), the
  parity matrix's capture URLs in full. All ten owner decisions asked again and recorded in the owner's words.

Opus counter-review of PR #15 at 3292292 and grassfield-packages PR #1 at 7ea772e (integrator, 2026-10-27): FAIL, 1 MAJOR.
The three earlier MAJORs confirmed closed. Each finding and where it is answered:
- **MAJOR** (P2 wider than the owner's choice): `auth_admin`, never `_keep` (b.1; S18: every call asks); `remove` takes only
  explicitly installed packages that own an application entry, with a fixed deny list (kernels, firmware, `base`, `sudo`,
  `systemd`, the boot tools, pacman, Omarchy's two package lists, Grassfield's packages, `HoldPkg`) and the whole `-Rs
  --print` plan checked (b.1, a); the package names in the polkit sheet, through the policy's `$(command_line)` (b.1, SD2;
  S18); the probe S16 proves the rule and the deny list (and found that `-Rns --print` is refused, so the plan is read with
  `-Rs --print` and a plan that does not resolve refuses).
- **Minors:** the list of other updates is Software Update's step 2 (`otherPackages`, PR #16's text, carried word for word
  into ADR-0033 here) and goes first at the checker's cap (d, SD3); the Store's hold
  on Omarchy's lock shows "Update in progress" in Software Update (b.1, spec); a fetched AppStream package is checked by its
  own signature with `pacman-key --verify` (c, SD4; S17); the publisher publishes the latest state, so a cancelled pending
  run loses nothing (g); `store-probes.sh:11` names S13 too; the AUR field list matches the output (no MakeDepends).
- Delegated decisions SD1 to SD4 recorded under the owner's working rule of 2026-10-27.

Opus review of step 1 in grassfield-packages PR #2 at 2dae23f (integrator, 2026-10-27): FAIL, 1 MAJOR. Each finding and
where it is answered, in both halves (tools/catalog.py and the Store's `catalog.cpp` and `signature.cpp` apply the same rules):
- **MAJOR**, the web-app name rule was never applied: every language of a web app's `name` follows e.5's rule, tested
  through the whole catalog's validation on both sides.
- **Minors:** plain text refuses format and separator characters and markup (g); URLs need a host name and no user
  information (e.5); keyring lists are compared in upper case with spaces ignored (g "Signature and verification");
  malformed input is a problem, never a crash; CI's recipe check covers every sync, download and AUR build (g); the
  publisher checks the catalog as the Store does, decides on its content, uploads only the icons it lists, builds from
  `main` and lives in its own workflow (g "Publication" 2); tests for a truncated catalog or `.sig`, a missing `.sig`, a
  signer absent from the keyring and an oversize file; the category names made neutral ("Graphics", "Photos and Video",
  "Music and Audio", "Development"), whether the Mac App Store's own list may be followed being the owner's legal question
  (e.10, not settled here).
- **grassfield-packages PR #4's review** (FAIL, the recipe check did not fail closed): the integrator's decision, pinning
  first and the scan second (g "CI also refuses"); the publisher reads a release's database only after its signature.
- **Merged with PASS** (grassfield-packages b76bebe), with items before publishing is ever enabled, taken in
  grassfield-packages PR #4 and, for the Store's half, here: keyring lists fail closed on a line that does not parse (both
  sides); two signers refused (both sides); recipes read as shell, catching wrapped, quoted and continued commands, `git -C
  d clone` and the language installers (11 of Omarchy v4.0.4's 63 recipes refused, the catalog's three setups still pass);
  every release file's signature checked before upload; deep JSON a one-line problem (Qt's parser stops at its nesting
  limit); the owner creates and protects the `publish-<channel>` environments before the job is enabled.

Opus review of step 1 here, at 17567e8 (integrator, 2026-10-27): FAIL, 1 MAJOR. Each finding and where it is answered:
- **MAJOR**, `pacman-key --verify`'s exit code was trusted: it is 0 for a good signature by any key of pacman's keyring,
  trusted or not (S19, a probe this time with an untrusted signer, which S17 never had). The Store now reads gpg itself
  against a private copy of pacman's keyring: one `VALIDSIG`, `TRUST_FULLY` or `TRUST_ULTIMATE`, the key valid and not
  disabled in its listing, none of `PLAINTEXT`, `BADSIG`, `ERRSIG`, `EXPSIG`, `EXPKEYSIG`, `REVKEYSIG` (c, SD4). The
  container test has the untrusted, trusted and disabled cases with the real gpg, and a real package unpacked by the real
  `bsdtar`.
- **Minors:** a `grassfield-revoked` that is there but unreadable or over 1 MiB, or any list with a line that does not
  parse, refuses the catalog (g); text and URL checks go by code point, so format characters beyond U+FFFF are caught (c,
  e.5); AppStream's data joins a catalog entry only for one of the entry's packages (g `apps`); a `.sig` that is a signed
  message of its own is refused (g); leftover work folders are removed when a refresh starts; the longer limits of gpg's
  check (60 s) and of the unpacking (120 s) are written above (f); the request's cookie, Referer, cache and redirect
  settings, a real https server's redirects (five followed, a sixth refused, http refused), cookies never sent back and
  the size cap, and `bsdtar`'s argument vector are tested.

Opus review of step 2 here, at 0fe0c60 (integrator, 2026-10-27): FAIL, 1 MAJOR and 8 MINOR. Each finding and where it is
answered:
- **MAJOR**, LeakSanitizer failed the ASan suite on Qt 6.11.2 with ICU 78: `QString::localeAwareCompare` keeps a shared
  default `QCollator` that is never freed. The two sorts that used it (the product page's languages, `storeview.cpp`;
  Installed's names, `storebackend.cpp`) now use a `QCollator` of their own on the formats locale.
- **Minors:** with a larger text size the hero's and the cards' title line heights and the gaps under them grow with the
  fonts, and the title's distance from the eyebrow too (`textScale` tokens; `tst_storemain` test_largeText); the shared
  `Toggle` has the disabled look of the other controls (dimmed, `materialDisabledOpacity`; three Settings callers no
  longer set it themselves); `branding/LICENSES.md` counts every symbolic icon (96 with main's clipboard glyphs) and has
  the Store icon's row; the screenshot
  provider checks the backend's gate (screenshots on and online) right before each fetch, and the product page reads the
  source again when the Store goes offline or comes back; the notice's rim, the generic icon's glyph and the "See All"
  link's centring use tokens or the title's own height; the screenshots line says the addresses come from each app's
  description, often another site; the spec lists `GRASSFIELD_STORE_QML`, the dev plumbing and `--page`, and
  `StoreEnv.OfflineOnlyInADevSession` tests `GRASSFIELD_STORE_OFFLINE` (honoured in dev, ignored in a packaged session);
  Tab (and any keyboard focus move) scrolls the focused item into view below the toolbar (`ScrollPage.reveal`;
  test_focusScrollsIntoView).

Counter-review of f978601 (integrator, 2026-10-27): PASS; the integrator's nested pass found three gaps, answered here:
- **The menu bar showed "org.grassfield.Store" and Window only.** The name: the Store is not packaged before step 3 (SD9),
  so `apps/store/build-direct.sh` now puts its desktop entry (Exec on the dev build) and icon under `.dev/share`, which
  `scripts/dev/devenv.sh` puts first in `XDG_DATA_DIRS`. The window rules: `config/hypr/grassfield/windows.lua` now
  counts `org.grassfield.Store` among the apps that draw their own chrome (`gf-client-chrome`, and the maximize exemption),
  as Files, Settings and Preview. Qt's export was probed under KWin's virtual backend (it serves `org_kde_kwin_appmenu`)
  with a stand-in registrar on a private bus: the Store calls `org_kde_kwin_appmenu.set_address(<its bus name>,
  "/MenuBar/1")` as Settings does, and `GetLayout` returns File (Settings…, Close Window), Edit and View in 21 ms. The T1 menus are then the
  bridge's and the shell's to show; if they still do not, the bridge's log line for the window (opened, or refused with
  its reason) and the plugin's `appmenu: set_address` line tell which step drops them.
- **Ctrl+, opened nothing.** With the global menu, the window's shortcut and the menu item carry the same key: on Qt 6.11.2
  (Arch Linux Archive), `tst_storemain` test_keysWithTheGlobalMenu opens the settings window with Ctrl+, and picks the
  second sidebar item with Ctrl+2, and test_globalMenuAndSettingsBuild builds the menu (File, Edit, View) and the window.
  Not reproduced in a real session here (no nested Hyprland): the nested pass checks it again.
- **No catalog and no app data: an empty page.** Discover now says "The Store Isn't Available Right Now" with the reason
  (spec "Degraded behavior") and Try Again; with Arch's apps but no catalog, a notice says the catalog isn't available
  (this ADR's "Offline").
- **Also from the counter-review:** a disabled `Toggle` keeps its track (an off switch stays visible on white) and fades its
  knob (`controlToggleDisabledKnobOpacity`), and its accent when on; it does not dim again inside a disabled container
  that dims itself (Settings' blocked page); `tst_controlsbuttons` test_disabledToggleLook. be35a43 does not build on its
  own (two lines of fcc9a30's screenshot gate went into it); the history is not rewritten (the project's working rules), so a bisect skips
  it (`git bisect skip be35a43`): be35a43 and fcc9a30 build together.


Opus security review of step 3a at 19d2e9e (integrator, 2026-10-28): PASS, no BLOCKER or MAJOR; four fixes asked before
merge, each answered here:
- **The explicit-only rule had no test of its own** (a mutant without it survived): `tests/integration/store_helper.sh`
  removes `gs-orphan`, an app with an application entry installed as a dependency that nothing needs, and expects exit 6.
- **IgnorePkg and a partial upgrade:** the helper reads the whole plan before anything is downloaded, without
  `--noconfirm`, and refuses one that fails or that would change an installed package (b.1, exit 5). The test installs
  `gs-newer`, which needs a `gs-app` IgnorePkg holds back (pacman's question gets no answer: the plan fails), and
  `gs-wants-old`, which needs a `gs-pinned` older than the installed one (no question: the plan names it); both exit 5 with
  nothing changed.
- **The polkit sheet could hide names** past its eight lines while the helper takes 64 names of 128 characters: the Store's
  request now shows every name, scrolling past eight lines (SD17, the security spec's "Polkit details";
  `tst_authdialog` test_13_storeRequestNamesEveryPackage).
- **The lock's descriptor reached pacman:** every program the helper starts gets `9<&-`; the test checks that only the
  helper holds the lock while pacman and a scriptlet run, and that a process a scriptlet leaves running neither holds it nor
  makes the next run busy.

Opus security re-review of 19d2e9e..64cdaa9 (integrator, 2026-10-28): PASS, one MINOR left before merge, answered here:
- **An app IgnorePkg holds back, asked for by name** (a direct pkexec call with the admin password): its "[ignored]" line
  passes the `-Qu` check, and `pacman -S --noconfirm` would update it past the hold. The review read from pacman's source
  that `pacman -S --print` skips such a target with an empty plan. Measured on archlinux:base (pacman 7.1), with the
  question reading `/dev/null` the plan lists the target at the new version, so 64cdaa9's installed-package check already
  refused it (exit 5, "would replace the installed gs-app with 2-1 alone", `gs-app` unchanged). The helper now refuses an
  install of any name `pacman -Qu` lists, "[ignored]" included, by name and before the plan (b.1, exit 5), so the refusal
  no longer depends on how pacman answers; `store_helper.sh` installs `gs-app` by name while IgnorePkg holds it at 1 with 2
  in the repository and expects exit 5, `gs-app` unchanged and that reason in the log. The sheet's scroll reset on a new
  request, the one mutant the re-review saw survive, has its check in `tst_authdialog` test_13.

Integrator review of step 3b2 (grassfield PR #36 at 48e2463, opus security; 2026-10-28): FAIL, one gate failure. Each
finding and what changed:
- MAJOR, gate Q1: qmllint flagged `tst_storepreferences.qml` (`this.file`, `this.written` on a plain object); the fake
  backend keeps its state in closure variables. The audit's lint had covered only the Store's own QML: the Store's QML
  tests are now linted with the script's flags too.
- Decided by the integrator: the AUR sheet's default button is Cancel (common rule 3); e.7 and SR14 say so; `Sheet` gains
  `returnCancels` (worded as the one PR #33 adds, so the two meet without conflict).
- MINOR: the script's name and token checks followed the locale (bash's ranges): it runs its checks with `LC_ALL=C` and
  gives the recipe the user's own locale back; `store_run.sh` generates en_US.UTF-8 and checks "exämple", "ﬁle", "ab²"
  and an operation id with "á" (exit 2) and the recipe's locale.
- MINOR: the foreign names were asked of the AUR on a metered connection: no longer (c); dev plumbing
  `GRASSFIELD_STORE_OFFLINE=metered` (and `0`, online whatever the network) makes it testable.
- MINOR: the settings window's privacy lines: the AUR's line shows whether the AUR is on or off, and the closing line
  says what leaves while it is on.
- MINOR: the repository check matched exact names; the Store's plan and the script now refuse whatever pacman resolves
  (`-Sp`: a provider, a group), a pacman that does not answer is no answer.
- MINOR, test gaps: the gates of the AUR's requests, the foreign-names ask, `storeApp`, the explicit-only removal, the
  plan's resolution and the catalog's `aurOff` and `aurUnchecked` each have a test that fails without them.
- INFO: View Build Script now says that yay fetches the script again and that the package's other files are not shown.
- From grassfield-packages #12's note: `omarchy-pkg-missing`, which `omarchy-pkg-aur-add` calls, must be pinned too; the
  Store (`requiredPins`) and the script require it.

Step 3b2 merged (grassfield PR #36, opus security PASS, 2026-10-28) with follow-ups for step 3c, and three notes on the
same PR after it (2026-10-28 20:50, 2026-10-29 00:42 and 00:56). Each and what changed (step 3c, part 1; SD28):
- MINOR: the AUR's info request sent a `+` as it is (a space in a query): each name is percent-encoded, as the search's
  term (`tst_aur` with `libc++`).
- MINOR: an AUR install could take a name of the deny list (`omarchy-*`, `grassfield-*`: the AUR is anyone's): refused,
  the whole list, the app's and each package the plan builds, in the Store and in the script (b.2, SD30).
- MINOR, test gaps: `aurOff` in Get and Uninstall… and `aurUnchecked` were held only by the container's signed catalog:
  `tst_storebackend` AurBlocksAgainstACatalog hands the backend a snapshot with a catalog and kills the three mutants
  outside the container (`apply` protected for it).
- INFO: "target not found: <name>" was matched as a substring (a longer name's line passed): pacman's whole line, in the
  Store's plan and in the script.
- The probes' output printed Flathub's key fingerprint, which gitleaks reads as a secret (handled on main by
  `.gitleaksignore`): the probe prints the long id only.
- "Arch's app data could not be verified" showed for a download that failed: the reason is typed (download, signature
  download, verification, the rest), each with its own words, the download's with Open Software Update (c); the Store
  works on Arch's data alone without a catalog host (`tst_storebackend` NoCatalogHostButArchsData, ArchsAppDataProblems
  with a 404 on the package, a 404 on the `.sig` and a bad signature).
- A package database older than the mirror (404s): told to update the system first, before anything downloads, with
  Update Now… to Software Update and no raw output, never a refresh of the databases alone (e.4, SD29; `tst_plancheck`
  and `tst_storebackend` SystemOlderThanTheMirror with a fake mirror answering 404 and a database older than Software
  Update's check, `tst_operations` for pacman's 404 after the fact, `tst_storeoperations` for the words).

Integrator review of step 3c part 1 (grassfield PR #54 at ff2fd83, independent opus security review; 2026-10-29): FAIL,
one MAJOR; no widening of the root surface. Each finding and what changed:
- MAJOR: the system-older check read only the `available` state, which the checker writes only for a Grassfield or
  Omarchy release: Arch's updates alone answer up-to-date, Grassfield's repository off not-set-up (the owner's machine:
  384 other updates and Omarchy 4.0.6, so the check never fired). It now reads any of the three states that carry the
  counts, and a failed check's `previous`; AUR installs get it too, and their repository dependencies the HEADs (e.4,
  SD29 amended). Tested on fixtures the real checker writes (`tests/fixtures/store/software-update/`, made by
  `docs/audits/store-2026-10-27/tools/make-software-update-fixtures.sh`).
- MINOR: the last sync was the newest database's mtime, which pacman sets to the mirror's Last-Modified (a sync on 10-29
  left a database dated 10-16, so an older answer kept refusing): pacman.log's last "synchronizing package lists" now,
  the mtime only without it.
- MINOR: up to 64 HEADs one after another, each on a new connection: now every file (256 at most) at once on one
  connection pool, within 20 s for the whole set, the rest dropped once one is gone (fetch.h headStatuses).
- NITs: the helper condition of the "outdated" outcome has its test (a web app's failure with pacman's words stays
  "failed"); the probe outputs' trailing spaces removed; the French sheet text reworded and the new texts' apostrophes
  typographic; b.2 says the script checks the names it is given and the Store's plan the dependencies yay builds.

Step 3c part 1 merged (grassfield PR #54, opus security PASS on 41c2235, 2026-10-29) with follow-ups for part 2. Each and
what changed (step 3c, part 2):
- `lastSync` counted a failed sync: pacman.log logs "synchronizing package lists" for a sync that downloads, one that
  finds nothing new and one that fails (an offline `-Syu`; S27), so Software Update's answer stopped counting and only the
  HEADs were left. The last completed sync is now the newest ctime of the sync databases, which only a sync that wrote a
  database moves (S27); pacman.log is no longer read for it, so its offset (N6, which survived in Europe/Paris only) is
  gone with it. `tst_plancheck` reads a database whose mtime is the mirror's; `tst_storebackend` keeps refusing after a
  sync line in pacman.log that wrote nothing, and stops once the answer predates the database's write.
- `plancheck.cpp:98`: no test had an Omarchy release alone (N10 survived): the fixture `available-omarchy` (Omarchy 4.0.6
  and nothing else, by the real checker) is behind.
- The HEADs' deadline and early stop (N13, N14) were held only by the HTTPS server of `store_catalog.sh`'s container:
  `tst_fetch` HeadStatusesAgainstALocalServer runs a server of its own on 127.0.0.1 with a throwaway certificate openssl
  makes for the test, everywhere openssl is.

Integrator review of step 3c part 2 (grassfield PR #58 at 2e52297, independent opus security review; 2026-10-30): FAIL,
two MAJOR; the security of the flatpak calls confirmed (`--user` only, argument lists, ids and refs checked, the plan's
answers, the metadata's access, Stop by SIGTERM, nothing outside the user's installation). Each finding and what changed:
- MAJOR: the ASan run exited 1: `tst_fetch` read `QNetworkProxy::applicationProxy()`, which asks libproxy 0.5.12, and
  libproxy leaks once a proxy is set (reproduced with `http_proxy` set; this container had none). The test now sets no
  proxy and restores the system setting without reading the system's proxy.
- MAJOR: the access list understated: a bus name other than org.freedesktop.Flatpak (org.freedesktop.systemd1, which
  runs host commands, the permission store, secrets), the `ssh-auth`, `gpg-agent` and `pcsc` sockets, `devices=kvm` and
  `shm`, `features=devel` gave "It can reach only its own window and files." Every grant is now named (SD25 amended):
  the known classes, each bus name outside a short harmless list, "outside its sandbox" for the session's services that
  run host commands or grant permissions (a wildcard covering one too), and any grant the Store does not know as
  flatpak writes it; the window says a key it does not know as it is. Metadata that names no app gives no plan; the
  page says nothing when it could not be read. `tst_flatpak` WhatItCanReach has each case and an unknown grant.
- NIT: a ref's arch and branch accepted `..` and a leading `-` or `.`: refused.
- NIT: mutants F19 and F20 survived: `tst_storemodel` Flathub has a ref with `..` and a ref of another app (neither
  listed nor offered, our entry hidden); `tst_flatpak` RuntimesAtMostEight answers yes eight times and refuses a ninth.
  The backend's own ref check (`getBlock`) stays as a second guard behind the model's.
- INFO: Flathub's key is trusted by TLS to dl.flathub.org, no fingerprint pinned, and `--if-not-exists` keeps the
  user's own "flathub" remote: said in "Flathub" above and decided in SD31.

Step 3c part 2 merged (grassfield PR #58, opus security PASS on d212773, 2026-10-30) with follow-ups for part 3. Each and
what changed (step 3c, part 3):
- MINOR: the rule that keeps an app's own bus names harmless ran before the escapes, so an app whose id is
  `org.freedesktop.systemd1` (or covers an escape, `org.freedesktop.impl`) came back empty: the escapes are checked first.
- NIT: `filesystems=xdg-config/autostart` read only "Some of your folders": a writable grant that holds
  `~/.config/autostart` or `~/.config/systemd` (host, home, `xdg-config`, a home folder by its absolute path; never `:ro`)
  adds "Programs that start when you log in" (`login`).
- NIT: F19 (`storebackend.cpp:1131`, Get for a bad ref) could not be reached: the model never offers a ref
  `installableFlatpak` refuses (tested since PR #58), and `checkFlatpakInstall` refuses one again. The unreachable check is
  removed rather than kept as a mutant no test can kill.

Integrator review of step 3c part 3 (grassfield PR #65 at e68ef77, independent opus security review, with
grassfield-packages PR #13 at 14a34af; 2026-10-30): FAIL, one MAJOR in the access list; Get Flatpak… held (the runner's
kind, the record, the plan and the pins, no root surface in Grassfield, the texts, Qt 6.11.2). Each finding and what
changed:
- MAJOR: a rule ending in `.*` did not cover its own base name, so `org.freedesktop.Flatpak.*=talk` or
  `org.freedesktop.systemd1.*=talk` named the service without "outside", and an app whose id is
  `org.freedesktop.Flatpak` came back empty (its own names). `X.*` now covers X and every name below it, and an app
  whose id is an escape, or holds one (`org.freedesktop.impl.portal`), is "outside" whatever its policy says: flatpak
  lets it own its id and every name below it (SD25 amended).
- MINOR: paths were not normalised (`~/.config//autostart`, `~/./.config/autostart`, `xdg-config/./autostart`, `~/.`):
  every path is now read in one canonical form first (`//`, `/./` and a trailing `/.` collapsed, `..` anywhere,
  `/home/<user>`, `/var/home/<user>` and `/run/user/<uid>` mapped).
- MINOR: too few login targets: `~/.config/hypr`, `~/.config/uwsm`, `~/.config/environment.d`, `~/.config/fish`,
  `~/.local/share/systemd`, `~/.local/bin` and the shells' start files (bash, sh, zsh) added. `xdg-run/bus` and
  `xdg-run/systemd` (and the runtime folder above them, read-only too) are "outside": they bypass the bus filter. In the
  same rule, beyond the review's list: `~/.local/share/dbus-1` (a session service D-Bus starts on the host) and
  `~/.local/share/applications` (entries the launcher runs on the host), written, are "outside".
- NIT: no test drove a successful `install("store:flatpak")` (mutants B1, B5): `tst_storebackend` GetFlatpakInstalls
  plans it, is refused while `flatpak` is there, queues the record with the catalog's pins, finds them written for
  `grassfield-store-run`, and is refused again while it is queued, planned again or not.
- NIT: SD24's "no root surface" holds for Grassfield only: the `flatpak` package's own system helper, polkit policy and
  rules, and its system Flathub remote, are said in SD24 and b.2.

Integrator re-review of 0f1481c (independent opus security review; 2026-10-30): PASS on the five findings (342 cases of
the reviewer's own driver); four understatements to fix before the merge, and NITs. Each and what changed:
- Regression: `host/`, `host/.` and `host//` read only "Some of your folders" (`host` was matched before the path was
  normalised; flatpak strips the slash, S29). The path is normalised first, then `host`, `host-os`, `host-etc` and
  `home` are matched.
- Backslash escapes were not decoded (`filesystems=ho\\st;` is `host` for flatpak). Each list is decoded as GLib
  decodes it for flatpak (`\s`, `\n`, `\t`, `\r`, `\\`, `\;`; `;` separates), then each filesystems entry as flatpak
  does (`\x` is x, the first `:` not escaped starts the mode); a value GLib cannot interpret, which flatpak refuses
  (S29), makes the metadata unread: no plan, nothing on the page.
- Runtime paths read only "folders" (`xdg-run/hypr`, whose IPC can `dispatch exec`; `xdg-run/docker.sock`;
  `/run/dbus`; `/var/run/user/1000/bus`; `/var/run`): anything in the runtime folder but the sound server's sockets
  (`pipewire-0`, `pulse`) and the app's own folder (`app/<id>`) is "outside", read-only too; so is the system's `/run`
  but removable media (`/run/media`); `/var/run` is read as `/run`.
- `~/.config/omarchy` was not a login target (Grassfield's autostart runs `omarchy-hook post-boot`, which runs
  `~/.config/omarchy/hooks/post-boot`): added.
- NIT, done here (same function): a writable home, xdg-data or host reaches flatpak's own folder, the D-Bus services and
  the launcher's entries, so it says "outside" too; owning `org.freedesktop.portal.Desktop` (or the notifications' name)
  is named: the harmless names are harmless to talk to only (its own and media-player names stay its to own).
- NIT, follow-ups: the dimmed Sources line does not name Flathub (a text change for the next step's settings work);
  the reviewer's mutants B2, P10 and R5 are not this branch's names (this branch's R5, an id that is only the start of
  an escape, is killed since 0f1481c), asked for.

Store step 4, grassfieldhq/grassfield#97 (opus review of a8f9c7c5 merged with main c6ea2f30: FAIL on one MAJOR; the
security review clean), answered in the next commit:
- MAJOR: the Store could quit with its window open: Ctrl+Q or a closed window while an operation ran left the quit
  pending, and SD35's hand-over brought that process's window back, which disappeared when the operation ended. A launch
  handed over (`Open`) clears it (`StoreBackend::reopened`), and an operation's end keeps a shown window.
- MINOR: SD33's sheet for an update the Store could not check now has tests (an unread commit or metadata names the app;
  a cut access list counts as added; the sheet opens on `unknown` alone).
- MINOR: Files' alert test is hermetic (no Store on the PATH, not a dev session).
- MINOR: Update All above 64 refs had no way through: it takes every ref the check lists (512 at most, the check's cap).
- MINOR: Updates' jobs held a quit (the global pool, no cancel): they run on their own pool, and the cancel flag stops a
  child within 100 ms; a plan says what it checks while it runs.
- MINOR: the commit could change between the plan and the update: SD33 amended, the update pinned to the commit checked
  (S32).
- NITs: security.md's comma; the French sheet title without a gender agreement (and the group's own words); the update's
  "interrupted" outcome is reachable (a command that fails after others).

After PR #97's merge (2ac0ff8f, opus delta PASS), its note's follow-ups, answered in the next pull request:
- e0f5be2e (the integrator's: `tst_kiodialogs` leaves the session's `GRASSFIELD_SESSION` out) confirmed: files-kio-tests 58
  passed in Arch, also as from a session terminal with a Store installed and a dev build beside the test binary.
- NIT: a pin could downgrade an app updated outside the Store after its plan: the plan reads its installed commit, and a
  pinned command runs only while that commit is still installed (SD33's amendment).
- NIT: « %1 apps sur %2 » had no plural form: one app has its own text ("Checking what the update changes…"), more say
  "%1 of %2 apps" (« %1 sur %2 apps »), the noun plural whatever %1.
