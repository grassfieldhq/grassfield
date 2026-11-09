# ADR-0055: Bundled apps: Sanaga is the browser and Grassfield Notes is the notebook of the session
Status: Proposed (2026-11-09), applied provisionally (owner rule of 2026-10-28), awaiting the owner's ratification; D-1 to D-5 and D-7
follow the owner decision of 2026-11-08, D-6 was decided on 2026-11-09 under the owner's delegated rule (closest to macOS 27, no
technical step for the end user) · Date: 2026-11-09 · Decider: owner (ratify), integrator (merge) · Number:
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
- **D-6 Session defaults (decided 2026-11-09).** In the Grassfield session links open in Sanaga and `.md` files in Notes, and a
  later choice of the user always wins.
  - Where: the XDG mime-apps specification reads, for a type, `$XDG_CONFIG_HOME/$desktop-mimeapps.list`, then
    `$XDG_CONFIG_HOME/mimeapps.list`, then `$XDG_CONFIG_DIRS/$desktop-mimeapps.list`, then `$XDG_CONFIG_DIRS/mimeapps.list`, then
    the same two names in the data directories' `applications/`. The session's `XDG_CURRENT_DESKTOP` is `Grassfield:Hyprland`, so
    `$XDG_CONFIG_HOME/grassfield-mimeapps.list` is read first in this session and never in the Omarchy session. A packaged list
    in `$XDG_CONFIG_DIRS` cannot work: Omarchy writes `~/.config/mimeapps.list` (`chromium.desktop`) at install and that is read
    before every system list. Nothing edits `~/.config/mimeapps.list`.
  - How: Grassfield Files' session-start `--seed-default-apps` (F-19) also runs `DefaultApps::seedBundledApps`. Two groups, `web`
    (`x-scheme-handler/http`, `https`, `text/html`, `application/xhtml+xml` to `sanaga.desktop`) and `notes` (`text/markdown`,
    `text/x-markdown` to `grassfield-notes.desktop`), each once, and only when its desktop file is installed. A record,
    `default-apps.state` in Grassfield's state folder (`$GRASSFIELD_STATE_HOME`, else `$XDG_STATE_HOME/grassfield`), holds
    `<group>.state` = `seeded` | `done` | `user` and what the user's lists named for each type at the seed.
  - Rule 1, first start: Omarchy's own stock browser is no choice. `chromium.desktop` in `mimeapps.list` (what Omarchy's
    install writes, equal to the value its shipped `default/applications/mimeapps.list` names) and `omarchy-browser.desktop`
    (the routing entry of its `hyprland-mimeapps.list`, which runs `omarchy-launch-browser`) are read as "nothing chosen", as a Mac
    starts with Safari; the group is seeded. Any other browser named for one of the four types (Firefox, Brave, Zen, a
    Chromium-family browser other than Omarchy's stock one) keeps the whole group out, recorded as `done`, for good. A
    Markdown editor named for `text/markdown` keeps Notes out the same way. Without Omarchy's shipped lists (not found) every
    value counts as a choice: nothing is seeded.
  - Rule 2, a later choice wins: at each start, a `seeded` group whose types now resolve differently in the user's lists than
    at the seed (`xdg-settings set default-web-browser`, `omarchy default browser`, a browser's "make default"; all write
    `mimeapps.list`) has its seeded entries removed from `grassfield-mimeapps.list`, and becomes `done`: that choice is honoured
    and the seed never runs for the group again. Known limit: setting the very same browser as at the seed (Omarchy's Chromium
    again) changes no value and is not seen, because the content is identical; the Settings row below is how to make that choice.
  - Doubt: an unreadable or non-UTF-8 list, a corrupt record, a session list reached through a link: nothing is written and the
    user's choice stays. A record value this version does not know is left alone. A desktop file not installed yet records
    nothing, so the seed runs once it is.
  - Settings > Desktop & Dock "Default web browser" (macOS 27 has it in that pane): a popup of the installed browsers, i.e.
    desktop entries with `WebBrowser` in `Categories` that handle http or https, are shown, and are not
    `omarchy-browser.desktop` nor an entry whose `Exec` is a launcher that resolves the default again (`omarchy-*`, `xdg-open`,
    `gio`, `xdg-settings`, a shell, `env`, `uwsm-app`...). It records `web.state=user` first, then writes the four types to
    `grassfield-mimeapps.list`; a failure of the record leaves the list as it was. Chromium is a choice like any other there.
  - No handler can launch itself: the seeded ids run their own binary (`tests/integration/bundled_apps.sh`), the routing entry
    is never a target of the seed or the row, and a launcher `Exec` is never offered (the fork storm of 2026-10-30, load 1100).
  - Why this rule: the owner decided Sanaga is the session's default browser, so a fresh session must open links in it with no
    step for the user; and a person who chose something else, or chooses later, is never overridden (the macOS model).
    Reading Omarchy's stock `chromium.desktop` as no choice is the one trade: a person who chose Chromium on purpose in Omarchy
    cannot be told from the install default, and picks Chromium again in the row.
- **D-7 Dock and Apps panel.** The default Dock is Sanaga, Notes, Terminal, Settings (`dock.pinned`; Files and Apps are fixed
  tiles before them): the browser first as in macOS, Notes among the productivity apps, the lists of the earlier releases
  (`["chromium","foot","org.grassfield.Settings"]`, and the first one) read as the new default and are not rewritten; any other
  list is the user's. Both entries are ordinary applications (no `NoDisplay`), so the Apps panel lists them. Their icons
  (`sanaga`, `grassfield-notes`) are hicolor icons installed by the two packages and are drawn in the user's icon mode like any
  third-party icon.

## How a user changes the default

A browser: Settings > Desktop & Dock > Default web browser, which writes the session's own list and marks it the user's. Tools
that write `mimeapps.list` (`xdg-settings`, `omarchy default browser`, a browser's "make default") also win, at the next session
start (D-6). Notes: Files > Get Info > Open with > Change All... (a different application than Notes at the next start removes
the seeded entries). Chromium is never removed by this change; the Dock's Chromium tile is dragged back in like any app.

## Not done

- Nested visual proof of the Dock and the Apps panel (the packages are not built yet).
