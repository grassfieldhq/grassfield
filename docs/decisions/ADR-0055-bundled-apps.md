# ADR-0055: Bundled apps: Sanaga is the browser and Grassfield Notes is the notebook of the session
Status: Proposed (2026-11-09); D-1 to D-5 and D-7 follow the owner decision of 2026-11-08; D-6 (the session default) is OPEN,
awaiting the owner's answer on one point (see D-6) · Date: 2026-11-09 · Decider: owner (ratify), integrator (merge) · Number:
0055

## Context

Owner decision of 2026-11-08: two sibling apps of the grassfieldhq organisation ship with the desktop.
- Sanaga (github.com/grassfieldhq/sanaga, Rust, GTK 4 and WebKitGTK 6) is the default web browser of the Grassfield session.
  Chromium stays installed (Omarchy ships it) and stays selectable. Sanaga's own Apple device names and "Safari" identity are an
  owner-approved exception to the no-Apple-names rule; Grassfield does not touch Sanaga's code.
- Grassfield Notes (github.com/grassfieldhq/grassfield-notes, Rust, egui) is the built-in Notes app: in the Dock and the Apps
  panel, and the default `.md` handler of the session.
Both passed a security audit and were merged (sanaga a9e0e56, grassfield-notes 2daf1c8).

macOS model: Safari and Notes come with the OS, update with it, open links and notes by default, and a person who picks another
browser keeps it.

## Decisions

- **D-1 Separate packages, not vendored code.** Each app keeps its own repository, release rhythm, licence and audit trail.
  grassfield-desktop gains `depends` on `grassfield-sanaga` and `grassfield-notes`; nothing of either app is copied into this
  repository (a Rust toolchain and WebKitGTK stay out of the desktop's build).
- **D-2 Names.** ADR-0033 b.6 allows only `grassfield-*` package names in the signed channel (the key is trusted for every
  repository of it), so the browser's package is `grassfield-sanaga`, with `provides=(sanaga)` and `conflicts=(sanaga)` and no
  `replaces`. The binary stays `/usr/bin/sanaga` and the desktop id `sanaga.desktop` (MimeType `text/html`,
  `application/xhtml+xml`, `x-scheme-handler/http`, `x-scheme-handler/https`). Notes is `grassfield-notes`:
  `/usr/bin/grassfield-notes`, `grassfield-notes.desktop` (`text/markdown`, `text/x-markdown`). A machine with a self-built
  `sanaga` package must remove it once (`pacman -R sanaga`, run by the owner); only the owner's machines can have one.
  The desktop `depends` never names `sanaga` itself.
- **D-3 Pinned commit and checksum.** grassfieldhq/grassfield-packages builds each package from one pinned commit of the sibling
  repository, the source archive of that commit verified by a SHA-256 recorded in the PKGBUILD; a build with a different
  checksum fails. Both go into the same signed channel as grassfield-desktop (ADR-0033). Today's pins: sanaga `a9e0e56`,
  grassfield-notes `2daf1c8`.
- **D-4 Updates are Software Update's.** The apps update with the OS: a new pin is a new package version in the channel, shown
  and installed by Settings > Software Update like every other package (ADR-0033), with the same staged rollout (ADR-0050). The
  apps have no updater of their own in this session.
- **D-5 Security review rule.** A new pinned commit is published only after a review of the diff between the new pin and the
  last pinned commit (not of the whole tree), by an agent other than the one that wrote the change; the review and the two
  commits are named in the pin's commit message in grassfield-packages. Sanaga is a browser: a diff touching its network,
  profile, permission or extension code needs the opus security reviewer. A failed review keeps the old pin.
- **D-6 Session defaults (OPEN).** In the Grassfield session links open in Sanaga and `.md` files in Notes, and a later choice of
  the user always wins. Mechanism and what is open:
  - XDG mime-apps specification, lookup order for a type: `$XDG_CONFIG_HOME/$desktop-mimeapps.list`, then
    `$XDG_CONFIG_HOME/mimeapps.list`, then `$XDG_CONFIG_DIRS/$desktop-mimeapps.list`, then `$XDG_CONFIG_DIRS/mimeapps.list`, then
    the same two names in the data directories' `applications/`. The session's `XDG_CURRENT_DESKTOP` is `Grassfield:Hyprland`, so
    the session's own list is `$XDG_CONFIG_HOME/grassfield-mimeapps.list` and the Omarchy session never reads it.
  - A packaged default in `$XDG_CONFIG_DIRS` (`/usr/share/grassfield/xdg-config`) cannot work: Omarchy writes
    `~/.config/mimeapps.list` (`text/html`, `x-scheme-handler/http(s)` = `chromium.desktop`) at install, and that list is read
    before every system one.
  - The mechanism already in the tree is the right one: `--seed-default-apps` of Grassfield Files (`config/hypr/grassfield/autostart.lua`,
    `DefaultApps::seedSessionDefaults`, F-19) writes `grassfield-mimeapps.list` at session start for a type only when none of
    the user's lists names a default for it, or names exactly what Omarchy ships (`seedsAllowed`). It never edits
    `~/.config/mimeapps.list`. The types of Sanaga and Notes would be added to `seededTypes`.
  - OPEN, for the owner: that rule reads a `chromium.desktop` in `~/.config/mimeapps.list` as Omarchy's stock default, which it
    cannot tell from a person who chose Chromium on purpose in Omarchy (`omarchy default browser chromium` writes the same
    line), so an existing Omarchy install switches to Sanaga in the Grassfield session at its first start, and its Chromium choice
    is lost. Any other browser the user picked (Firefox, Brave, Zen...) is kept. A second point follows: an entry in
    `grassfield-mimeapps.list` shadows `mimeapps.list`, so a later `xdg-settings set default-web-browser` or
    `omarchy default browser` (which write `mimeapps.list`) would lose to the seeded Sanaga; the choice must be made in a place
    that writes the session's own list (Files > Change All... for `.md`, a "Default web browser" row in Settings > Desktop &
    Dock, proposed, not built in this step). No code of D-6 is merged until the owner answers.
  - No handler can launch itself: `sanaga.desktop` and `grassfield-notes.desktop` run their own binary; the session never lists
    `omarchy-browser.desktop` (which runs `omarchy-launch-browser`, which reads the default browser) as the target of a
    Grassfield default, and `tests/integration/bundled_apps.sh` fails on an entry whose Exec is a launcher that resolves the
    default again (the fork storm of 2026-10-30, load 1100).
- **D-7 Dock and Apps panel.** The default Dock is Sanaga, Notes, Terminal, Settings (`dock.pinned`; Files and Apps are fixed
  tiles before them): the browser first as in macOS, Notes among the productivity apps, the lists of the earlier releases
  (`["chromium","foot","org.grassfield.Settings"]`, and the first one) read as the new default and are not rewritten; any other
  list is the user's. Both entries are ordinary applications (no `NoDisplay`), so the Apps panel lists them. Their icons
  (`sanaga`, `grassfield-notes`) are hicolor icons installed by the two packages and are drawn in the user's icon mode like any
  third-party icon.

## How a user changes the default

A browser: Settings > Desktop & Dock "Default web browser" row (proposed; until it exists, Files' Change All... on an HTML
document, or a line in `~/.config/grassfield-mimeapps.list`), which writes the session's own list. Notes: Files > Get Info >
Open with > Change All... Chromium is never removed by this change; the Dock's Chromium tile is dragged back in like any app.

## Not done

- D-6 code (the seed of Sanaga's and Notes' types, the Settings row): see D-6.
- Nested visual proof of the Dock and the Apps panel (the packages are not built yet).
