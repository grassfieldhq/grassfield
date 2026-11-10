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
- **D-6 Session defaults (decided 2026-11-09; amended after the review of PR #38).** In the Grassfield session links open in Sanaga
  and `.md` files in Notes, and a later choice of the user always wins, whoever makes it.
  - Where: the XDG mime-apps specification reads, for a type, `$XDG_CONFIG_HOME/$desktop-mimeapps.list`, then
    `$XDG_CONFIG_HOME/mimeapps.list`, then `$XDG_CONFIG_DIRS/...`, then the data dirs. The session's `XDG_CURRENT_DESKTOP` is
    `Grassfield:Hyprland`, so `$XDG_CONFIG_HOME/grassfield-mimeapps.list` is read first in this session and never in the Omarchy
    session. A packaged list in `$XDG_CONFIG_DIRS` cannot work: Omarchy writes `~/.config/mimeapps.list` (`chromium.desktop`) at
    install and that is read before every system list. The seed and Settings never edit `~/.config/mimeapps.list` themselves.
  - Seed: Grassfield Files' session-start `--seed-default-apps` also runs `DefaultApps::seedBundledApps`. Two groups, `web`
    (`x-scheme-handler/http`, `https`, `text/html`, `application/xhtml+xml` to `sanaga.desktop`) and `notes` (`text/markdown`,
    `text/x-markdown` to `grassfield-notes.desktop`), each once, and only when its desktop file is installed and its `Exec` is no
    launcher (`isLauncherExec`: quotes read, `uwsm app --` and `uwsm-app` judged by the program they start; a `~/.local`
    `sanaga.desktop` running `xdg-open` is never a target). A record, `default-apps.state` in Grassfield's state folder
    (`$GRASSFIELD_STATE_HOME`, else `$XDG_STATE_HOME/grassfield`), holds `<group>.state` = `seeded` | `done` | `user`, what the
    user's own lists named for each type (`<group>.<type>`, "-" for nothing: the baseline) and `<group>.chosen`. The record is
    written before the list, so a failed write never leaves entries that the next start would read as the person's own choice;
    entries that already name the group's own application are never a choice.
  - Rule 1, first start: Omarchy's own stock browser is no choice. `chromium.desktop` in `mimeapps.list` (equal to what its shipped
    `default/applications/mimeapps.list` names) and `omarchy-browser.desktop` (the routing entry of its `hyprland-mimeapps.list`)
    read as "nothing chosen", as a Mac starts with Safari. Any other application named by any list the lookup reads (the system's
    and the data directories' too) for one of the group's types, or named in the session list, keeps the whole group out for good
    (`done`). Without Omarchy's shipped lists every value counts as a choice.
  - Rule 2, a later choice wins: after the seed only the user's own lists are watched (the configuration folder's `mimeapps.list` and
    desktop lists; a package update of `/usr/share/applications/mimeapps.list` is nothing) and the session list. A different value
    in the user's lists (xdg-settings outside the session, a browser's check), or a session-list entry that is no more ours
    (Change All… in Files), is the person's choice: the seeded entries go from the session list (the person's own entry stays) and
    the group is `done`. One exception that is no change of mind: every changed type now naming the group's own application
    (`xdg-mime default sanaga.desktop …`, Notes' own "open .md with Notes", `gio mime`) agrees with the seed; only the baseline moves.
    A `user` record yields the same way: a later value in the user's own list that is not the choice itself is followed (the
    session entries go, `done`); lists that agree with the choice only move the baseline. Never re-seeded after that. An
    unreadable or non-UTF-8 list, a corrupt record, an unknown record value, a record without its baseline, a linked session list:
    nothing is written. **Grassfield never writes, edits or deletes a line of `~/.config/mimeapps.list` or of any list of the user's
    own**: the lines the person or an app makes (xdg-mime, gio, a browser) survive every start byte for byte and win
    (`tests/integration/seed_real_xdg.sh` runs the real `xdg-mime default` and `gio mime`). Writes to the session list: a removal
    (a group the person took over) before the record, an addition (a first seed) after it, so that a failed write never leaves
    our entries behind for a group that is no more ours, nor entries that the next start would read as the person's own.
  - A browser's "make default" through xdg-settings works at once (decision of the review of PR #38): the real
    `xdg-settings set default-web-browser X` writes `~/.config/mimeapps.list`, then checks the lookup, which still answers Sanaga
    from the session list, so it exits 4 and its rollback writes our own entry into the user's list.
    `packaging/session-bin/xdg-settings`, on the PATH of the Grassfield session only (as the Chromium stand-in), handles
    `set default-web-browser X` and `set default-url-scheme-handler http|https X`. X is validated first and nothing is written when
    it fails (exit 2): it must be an installed desktop entry, found as xdg-settings finds it, whose `Exec` is no launcher (the
    rule of `isLauncherExec`: omarchy-*, xdg-*, gio, a shell, env; `uwsm app --` and `uwsm-app` judged by the program they start).
    A linked session list or record is refused (exit 1) without calling the real tool. Then the record says `user` and the choice,
    the session list names X for the four web types, the real `/usr/bin/xdg-settings` runs (by absolute path, never by PATH; a
    real path that is the stand-in stops with an error, a test covers it) so `~/.config/mimeapps.list` follows the explicit
    choice, the baseline is refreshed, and the exit is 0 only when the effective session default really is X. `get` and `check` for
    the web browser and the http/https schemes answer from the effective session default, so a browser's own check passes;
    everything else is the real tool. `omarchy default browser` runs it (tested). The stand-in is the one writer besides Settings
    that touches `~/.config/mimeapps.list`, and only through the real tool, for an explicit "make default".
    Limit: an app that writes `mimeapps.list` itself through GLib/GIO (Firefox's "make default" calls
    `g_app_info_set_as_default_for_type`, as `gio mime` does) does not pass through xdg-settings: its choice wins at the next
    session start (the session list shadows `mimeapps.list` until then). A watcher that re-runs the seed when `mimeapps.list`
    changes would close that gap; it is not built here.
    Same-browser re-selection (Chromium again after a seed that recorded Chromium) is a choice like any other there.
  - Settings > Desktop & Dock "Default web browser" (macOS 27 has it in that pane): a popup of the installed browsers, i.e. desktop
    entries with `WebBrowser` in `Categories` that handle http or https, are shown, and are not `omarchy-browser.desktop` nor an
    entry whose `Exec` is a launcher that resolves the default again. It records `user`, the choice and the baseline first, then
    writes the four types to `grassfield-mimeapps.list`, both through the backend's guarded writer (`writeDefaultAppsFile`: only
    those two files, never through a link, and a dev session only under `<worktree>/.dev`, ADR-0019); a list that is not valid
    UTF-8 is refused; a failure shows a short sentence under the row (fr in `grassfield_fr.ts`) and leaves the list as it was.
  - The keyboard web key (`grassfield-launch-key`) reads the session's desktop lists before `mimeapps.list`, as `xdg-mime` does, and
    never takes Omarchy's routing entry as a handler.
  - No handler can launch itself: the seeded ids run their own binary (`tests/integration/bundled_apps.sh` reads the desktop files of
    the PINNED commits, vendored in `tests/fixtures/bundled-apps/`), the routing entry is never a target of the seed, the row or the
    stand-in, and a launcher `Exec` is never offered or seeded (the fork storm of 2026-10-30, load 1100).
  - Why this rule: the owner decided Sanaga is the session's default browser, so a fresh session must open links in it with no
    step for the user; and a person who chose something else, or chooses later by any tool, is never overridden (the macOS model).
    Reading Omarchy's stock `chromium.desktop` as no choice is the one trade: a person who chose Chromium on purpose in Omarchy
    cannot be told from the install default, and picks Chromium again in the row or with `omarchy default browser`.
- **D-7 Dock and Apps panel.** The default Dock is Sanaga, Notes, Terminal, Settings (`dock.pinned`; Files and Apps are fixed
  tiles before them): the browser first as in macOS, Notes among the productivity apps, the lists of the earlier releases
  (`["chromium","foot","org.grassfield.Settings"]`, and the first one) read as the new default and are not rewritten; any other
  list is the user's. Both entries are ordinary applications (no `NoDisplay`), so the Apps panel lists them. Their icons
  (`sanaga`, `grassfield-notes`) are hicolor icons installed by the two packages and are drawn in the user's icon mode like any
  third-party icon.

## How a user changes the default

A browser: Settings > Desktop & Dock > Default web browser, `omarchy default browser`, or a browser's own "make default" through
xdg-settings: all of them win at once in the session (D-6); a browser that writes the list through GLib/GIO (Firefox) wins at the next
session start. Notes: Files > Get Info > Open with > Change All…, which writes the session list's entry for the type: the seed sees
an entry that is no more Notes, marks the group done and removes its own other entry, leaving the person's. `xdg-mime default` and
`gio mime` write `mimeapps.list`: their lines are never touched; naming Notes or Sanaga they agree with the seed, naming another
application the next session start follows them.
Chromium is never removed by this change; the Dock's Chromium tile is dragged back in like any app.

## Not done

- Nested visual proof of the Dock and the Apps panel (the packages are not built yet).
