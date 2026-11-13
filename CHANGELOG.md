# Changelog

All notable changes of Grassfield Desktop. The version of every package, library and log line comes from the `VERSION`
file at the repository root (`scripts/dev/check-version.sh`, part of `just check`, keeps the consumers equal to it).
Format: one section per version, newest first.

## 1.0.0-rc8 (release candidate, 2026-11-13)

Bundled apps, safe mode, the Qt panels and the rc7 follow-ups.

Bundled apps (PR #38, ADR-0055): Sanaga is the default web browser of the Grassfield session and Grassfield Notes the
built-in Notes app (Dock, Apps, default `.md` handler), as separate signed packages updated by Software Update. Chromium
stays installed and selectable, a choice of the user always wins, and the Omarchy session keeps its own defaults.
Chromium and Google Chrome are changed only in the Grassfield session, and fresh profiles open with the traffic lights
(PR #23).

Safe mode (ADR-0041): the lock, idle and the sleep inhibitor run only in the security process, a crash ends it with no
core file, and a lock is confirmed on its ground (S2, PR #32). The polkit agent and the secret sheets run only there too
(S3, PR #36). After repeated shell failures a centred alert offers Try Again or Log Out, follows the light or dark
appearance, is never shown over the lock, and Try Again keeps the flag until the shell is confirmed active (S4, PRs #45
and #47). The rc7 security lows are closed: reviewed migrations only, the prompter and the share picker accept only the
main process of their unit, one password-manager list, no serials (PR #26).

Open and Save (PR #25, ADR-0054): Qt apps use Grassfield's panels through a grassfield platform-theme plugin, and
LibreOffice runs its Qt 6 plugin.

Files (PR #29, ADR-0011): launchers never run, and a program or script downloaded from the Internet, or one with a
disguised name, asks before it opens.

Windows (grassfield-compositor): every window has its controls, and a frameless window draws its own bar only with a
frame of its own (PR #33). A tab dragged out of Chrome follows the pointer: the plugin serves xdg_toplevel_drag_v1 (PR
#28, ADR-0036 amendment). A password manager's window stays black in every capture with the plugin loaded (PR #34).

Shell: the UI is loaded by file: URLs so Qt's disk cache works, two invisible surfaces are deferred and the restart delay
is 100 ms (PR #37, ADR-0056). Search, Apps, Overview, the OSD and the switcher are built right after the shell starts,
and early requests are replayed (PR #42). A running app can be dragged out of the Dock, and apps are identified by their
resolved entry id (PR #24). The menu bar's keyboard walk keeps the keyboard through a menu swap (PR #22). Every D-Bus call
of the menu bridge gets a reply, which ends the portal's 25 s start at login (PR #20). Icon modes reach their A2 floor in
every cell with no exemption (PR #30), and accent text on glass reaches 4.5:1 (PR #31).

Updates (PR #21, ADR-0041 option A): the hold pair. Qt and Quickshell are held at the versions this Grassfield was built
for, so a system update waits for a tested toolkit. Settings > Software Update has Allow… and Hold Again.

Store (PR #50, ADR-0046): grassfield-store-run follows the helper's deny list again: the session's runtime and
Grassfield's optional dependencies are protected, Omarchy's optional preinstalls can be removed unless HoldPkg names them,
and when the optional dependencies cannot be read nothing is run.

Installer: Omarchy development builds at or above the tested floor 4.0.0.r7608 are recognized, an older one is refused with
a fix in English and French (PRs #17, #46, contributed by 3j27). The installer offers the pending updates and the
uninstall leaves a stock system (PR #43).

Also: docker test containers go through one guarded wrapper (PRs #27, #48), ADR and ledger updates (PRs #18, #19, #39), and
test fixes (PRs #35, #40, #44, #49, #51).

## 1.0.0-rc7 (release candidate, 2026-11-07)

The owner's rc6 report, on two machines.

Displays (PR #10): a display that comes back from sleep without a mode is reloaded until it has one (Omarchy's
recovery, inside the shell). A resume lights the lock screen's displays, as macOS does (security module, display only).
"Use as" is on every display, and the menu bar can be dragged in Arrange (ADR-0044 A-2). Panels below 150 ppi offer their
native resolution.

Shell (PR #13): the menu bar band takes the wallpaper under it as its backdrop on every display. The Wallpaper pane
names the displays a choice changes. Screenshots go to Pictures/Screenshots (one folder in any language) and recordings
to Videos, and the keys follow the toolbar's Save to. The numeric keypad has the capture keys, and there is an optional
Screen Capture menu bar item.

Files (PR #14): Favorites take the user's folders. Cut and Paste move items, with the Finder's Move Item Here. The
clipboard is emptied only while it holds that cut. The Columns view's selection no longer goes back, and item menus
shorten long names. Default apps of the Grassfield session live in grassfield-mimeapps.list: they are seeded only where
no list names an explicit choice, and set with Change All…. The desktop's Paste Item moves a cut without ever replacing a
file (PR #12).

Windows (PR #15, grassfield-compositor): a window moved to another display fits its work area. The title bar drag
follows the pointer, and the menu bar fills at once. Windows are held below a remapped menu bar. One title bar per window
comes from the decoration the client negotiated (P9, ADR-0015 amendment). A machine-wide Chromium and Google Chrome
policy keeps their GTK window buttons under Omarchy's colour policy.

Screen sharing and dialogs (PR #16): the share picker receives xdph's --allow-token. Opening "Remember this choice" from
it (so a browser asks once) is built but held off until the owner agrees to amend Q14. Settings > Privacy > Screen
Sharing lists and removes grants under the empty app id (Other Apps). The callers that bypass the Open and Save panels
(Qt under the gtk3 theme, LibreOffice, Chromium started before the portal) are documented.

Also: the Settings singleton mirrors keyboard.dictation, and settings_vectors reads displays.main (PR #11).

## 1.0.0-rc6 (release candidate, 2026-11-06)

The UI audit of 2026-11-05 (docs/audits): the notification banners move as one stack (no jump after an exit, the blur
under them follows), alerts and countdowns translated in their handlers, French alerts and toolbars that fit, lighter
placeholders, rounded artwork, selection states and the 1.25 scale. The ideas retained from Project Luma (ADR-0047 to
ADR-0053): audio routing to headphones and an original MIT sound set with Sound Effects; lower CPU and IO weights for the
apps you cannot see on battery (`grassfield-energy`); Flatpak permissions in the Store, with an update that asks for more
held from Update All; staged rollout cohorts (inactive until the signed database lists its marker); Memos; ongoing
activities in the menu bar; the diagnostic report, search file ranking and a notice for a never-seen display combination.
The Store reads repository.conf through its fixture in dev sessions.

## 1.0.0-rc5 (release candidate, 2026-11-05)

Omarchy 4.5.0 support, beside 4.0.6: the lock's fingerprint pacing (Omarchy 4.5's backoff, no attempt with the displays
off, a 20 s reach timeout), Software Update's keyring refresh and kernel restart rule, the portal routing kept against 4.5's
hyprland-portals.conf (the session is Grassfield:Hyprland and links its own grassfield-portals.conf), owed.service kept out of
the Grassfield session, Dictation on 4.5's commands, hibernation's disk check, the herdr theme sync stopped, and a drift
lock per Omarchy version.

## 1.0.0-rc4 (release candidate, 2026-11-05)

Omarchy's capabilities in the Grassfield session (ADR-0045): the screenshot and recording toolbar (Super+Shift+5), text and
QR codes in images (Preview, Glance), Emoji & Symbols, external display brightness over DDC/CI, the Settings setups through
the system services (Dictation, Fingerprint & Key, Remote Login, Disk Encryption, Hibernation on Battery and Energy, Share
Network), terminal themes that follow the appearance, per-app rules, LocalSend in Files and a Weather widget. The polkit
sheet waits for a fingerprint or a security key, and refuses a request nobody can see once a device prompt starts.

## 1.0.0-rc3 (release candidate, 2026-11-05)

The owner's report from a second machine (a desktop PC with several disks and displays), on the beta channel: uninstalling
apps from the launcher and Files with the Store's own confirmation (ADR-0046); the main display and a wallpaper per display
(ADR-0044); the desktop menu on every display; Files' disks, mouse back and forward, Columns drags and copy progress; the
Input menu and Ctrl+Space; the Energy pane and prevent-sleep (ADR-0010 amendment); the Dock click that minimizes; traffic
lights in GTK apps and browsers that draw their own title bar.

## 1.0.0-rc2 (release candidate, 2026-11-04)

The first signed build published at packages.grassfield.site, on the beta channel (ADR-0033, owner decision of 2026-11-04):
the window corners follow one measured radius, the dark rim and smaller refinements since rc1. A prerelease build sets Software
Update up on beta; the public install script defaults to beta.

## 1.0.0-rc1 (release candidate, 2026-10-23)

First candidate of 1.0.0, the first version with a changelog. It is the state after the independent audit GF-AUDIT-001
(verdict RELEASE BLOCKED at 0.4.0-12) and its remediation: the open items and the gates that still need an owner run
are listed in the maintainers' private remediation plan.

What the candidate is: a desktop session for Omarchy (Hyprland, Quickshell): the shell (menu bar with global menus,
Dock, Overview, Apps, Search, notifications, Quick Settings, lock, idle, polkit agent), the compositor plugin
(titlebars, minimize with the Genie animation, appmenu protocol, Overview, tiling), the menu bridge, the apps (Settings,
Files, Preview, wallpaper helper), the design system, the cursor theme and the icon theme package.

Release engineering of this candidate: one version source (`VERSION`); `just release-check` (a clean build of a
`git archive` of HEAD, `just check` with clang-tidy, `just test`, coverage, gitleaks, the plugin build against the
installed and, when given, rc-channel Hyprland headers); gate tooling under `scripts/gates/` (P1 idle CPU, P2 memory,
P3 frame pacing, P5 session start from the journal, Q3 gcov coverage); PKGBUILD that builds from a snapshot of HEAD;
corrected licence notices.

Known limitations of the 1.0 line are in the release notes and in `docs/audits/final-1.0/16-final-release-verdict.md`.

The history below is summarised from `git log` (merge commits excluded), grouped by the Conventional Commit type and
scope of each commit.

1194 commits (merges excluded), 2026-10-17 to 2026-10-23: 364 docs, 341 fix, 224 feat, 191 test, 23 chore, 16 perf, 10 build, 9 style, 6 i18n, 4 refactor, 4 wip.

### Features, by area

#### ui (29)

- add grassfield-ui tokens, appearance and frosted material
- add Icon, PopupMenu, Slider, Toggle, Button, Tooltip and gaussian Material shadow
- add lock screen, idle dim and polkit tokens
- add Files app tokens
- add preview tokens and monospace family
- swatch rows in PopupMenu
- TintedIcon with default, dark, clear and tinted modes; icons.mode and icons.tint settings; call sites move to TintedIcon
- add TintedIcon, IconEffect, IconModes and the Settings icon picker
- tune icon modes on the first third-party pack (hue-keeping dark, tinted ramp, A2 contrast), fixed-size effect texture, tint caption
- Quick Settings keyboard model, capsule weights, tokens, Notifications footer
- folder colour pipeline, icons.folderColor setting and folder style store
- icon appearance modes drawn by a plate-detecting shader
- Dark keeps saturated plates brighter; full-bleed logo fixture, A2 rule margin and documented limits
- robust plate detection for the icon shader (ring probes, dominant colour cluster), no-plate context, rim scaled with size
- plain icon when the shader fails to load (logged once); schema patterns end anchored like ECMA
- every icon sits on a system plate in Clear and Tinted, desktop styled for the wallpaper, plain-icon fallback at its own size
- Dark gets the system plate for plate-less icons, steeper glyph separation, A2 watchdog with retry
- folder symbol plate modelled on the current icon shader per mode, LRU plate cache, symbol follows the folder onto the system plate
- rim fully opaque over the bare wallpaper; A2 exemptions 12 to 5 with measured values and the measurement limit stated
- single-pass icon shader with a system plate for every icon (ADR-0014)
- tune the system-plate shader, accent rows, A2 for every mode
- contrast-preserving fixed recolour (lightness of luminance, affine Dark), Files rows over accent, internal-contrast A2
- linear-light recolour maps, Clear ink solved for contrast, unit test of internal contrast
- accent colour tokens and live Appearance resolution (accent.color)
- distinct green accent, apps use the tree's Grassfield.Ui in dev, accent-live capture script
- Inter dynamic tracking token and Appearance.tracking() for the shared Ui text
- dark monochrome glyphs stand out from the plate (Dark lift, Tinted ramp, Clear ink floor); internal-contrast tiers re-set to the measured trade
- an icon that is already a rounded square is not put inside the system plate again
- remove the edge highlight of the icon modes (owner decision 2026-10-23)

#### compositor (24)

- add gfc/1 protocol and titlebar layout core
- add grassfield-compositor plugin with titlebars and gfc/1 IPC
- dragging a maximized titlebar un-zooms the window under the pointer
- minimize and restore with a Scale animation, config verb
- validate and track appmenu registrations
- org_kde_kwin_appmenu_manager global (feature appmenu)
- pid of the registering client in gfc/1 appmenu events
- event throttle and log limiter core (FR24)
- overview v2 request parsing and animation math
- overview v2 live window transforms
- desktop focus policy (desktop-focus capability)
- advertise desktop-focus-v2 and relax the overview chrome rule
- Stages prototype behind a feature flag (M5 spike)
- cursor-refresh verb redraws a still pointer at its new size
- log the Dock rectangle the shell sends with each minimize
- overview-focus restores the keyboard after the Overview (0.8.0-ovfocus)
- genie mesh math, minimize effect setting and feature (core)
- draw the Genie minimize effect on a deformed mesh
- the keyboard back after an unlock, refusal reasons named, one shared focus; plugin 0.8.2
- macOS 26 titlebar geometry (32-px bar, 14-px lights, 23-px pitch)
- hover glyphs on the traffic lights
- bar and content join square; grey lights on inactive windows
- pointer focus on shell layers that appear under a resting pointer
- window tiling by dragging to the screen edges, corners and menu bar (macOS 15+), tile verb

#### dock (19)

- glass shelf (translucent tint, rim) and theme Trash icons
- launch bounce, notification badges, drag to reorder/remove with poof, file drops on app tiles, recent apps, minimize-into-app setting
- icon menu with Options submenu, tail and window commands; Open at Login
- resolve the real type of dropped folders and extensionless files at drop time
- tiles glide between sections instead of jumping, bounce lands, spec cleanup
- fixed Files tile before the Apps tile, new default pins, old default list migrated
- macOS launch and activation rules
- hold a Dock icon about half a second to open its menu, badge not clipped by the press dim
- smootherstep magnification, time-based smoothing, auto-hide state machine, headless feel test
- wire smoothed magnification, hover hold, tooltip dwell and the auto-hide machine into the Dock
- the app's windows at the top of its Dock menu
- Option variants in the Dock menu (Force Quit, Hide Others)
- attention requests bounce the app's Dock icon (urgent event)
- Trash menu with Open and Empty Trash… (isolated Trash in dev)
- Animate opening applications, Show indicators, dock toggleAutohide
- dock.size, the Size setting (tile size 32-96, default 48), live
- dock.position, the Dock on the left, bottom or right edge
- one Dock across displays, resize by dragging the separator
- badge, progress bar and attention set by the application itself (ADR-0018)

#### config (18)

- add nested dev session, Grassfield Lua config and dev scripts
- load grassfield-compositor at nested startup when built
- add real session entry config with guarded Omarchy include
- add grassfield.json v1 schema, defaults and stdlib validator
- add dock.magnificationEnabled to the schema
- bind menu bar/Dock keyboard access, Notification Center, Force Quit and hardware keys
- expose lock.idleMinutes through Settings
- add trackpad gestures for Spaces and Overview
- add hotCorners to the grassfield.json v1 schema (default none)
- bind SUPER+M minimize and SUPER+H hide to shell IPC
- float and center the Glance window
- select the Grassfield cursor theme for the session
- F4, XF86LaunchA and a four-finger pinch open Apps (macOS 26); pkgrel 3
- corner radius 26 for Grassfield windows, 12 for third-party windows
- wallpaper.source online and wallpaper.online.provider (ADR-0016 O2/O3)
- radius 20 for Grassfield windows through a rule, default 12
- radius 26 for Grassfield windows again, through the global value
- Super+Alt+D turns Dock hiding on or off (macOS Option-Command-D); focus_on_activate stays on

#### shell (15)

- add menu bar, dock and wallpaper on frosted material with platform capability detection
- persist Settings, add services and compositor actions
- menu bar menus, status items, Control Center and dialogs
- wire the security modules and enable Lock Screen
- T0 app menu with File and Window menus, minimize and hot corners
- launch grassfield-settings from the Grassfield menu
- notify when Glance (grassfield-preview) is missing
- allow the appmenu plugin verb
- dev sessions launch apps with isolated XDG config/cache/state homes
- apps started by the shell get XCURSOR_SIZE and HYPRCURSOR_SIZE of the chosen pointer size
- fixed Apps tile as the first Dock tile (macOS 26 Launchpad/Apps), spec for F4 and pinch
- shell, Settings, Files and Preview follow accent.color live
- folders opened by a real session open in Grassfield Files
- Window > Fill, Center, Move & Resize, tiling keys and settings (macOS 15+ window tiling)
- log 'grassfield-shell: usable' once every bar and Dock drew a frame (gate P5)

#### menubar (14)

- clock opens Notification Center, DND moon and Control Center toggle
- applications' own menus from the menu bridge (T1/T2)
- transparent by default with a Show menu bar background setting; reference insets, regular titles, capsule highlight (F1 gap 3); Dock magnification off by default (gap 4)
- adaptive foreground model (luminance to light/dark tone with hysteresis, per output), tokens, A2 roles and tests
- name the Stages front app while Hyprland has no active window
- the bar slides over full-screen windows on the overlay layer and reveals at the top edge
- Automatically hide and show the menu bar setting (Always, On Desktop Only, In Full Screen Only, Never)
- press, drag, release on a title chooses a menu row (macOS), PopupMenu pointer relay API
- third-party status items (StatusNotifierItem tray) with their DBusMenu
- Now Playing status item with the Quick Settings module as popover
- Search status item
- crowding hides status items that would collide with the menus
- Recent Items in the Grassfield menu (macOS Apple menu): applications, documents, Clear Menu
- the menu bar of an output that is not the active one is dimmed (macOS, several displays)

#### settings (12)

- add notifications.dnd/previews, notification and OSD tokens
- grassfield-settings v1 app with Store logic, tokens and lint/test coverage
- opaque menus, wrapped values, plural-safe minutes; add settings spec
- Show items on the desktop control in Desktop & Dock
- pointer.size key, Accessibility > Pointer pane, live setcursor from the shell
- pointer follows the slider drag (shape toggle), Pointer spec
- pointer outline and fill colour keys with shared PointerColors logic
- Accessibility pointer outline and fill colour wells, preview and Reset Colour
- "Minimize windows using" Genie or Scale (dock.minimizeEffect)
- Accent colour row, specs, unit/contrast/e2e tests
- own names for the minimize animation (Minimize animation: Funnel / Shrink)
- Size slider and Position on screen in Desktop & Dock

#### packaging (12)

- add session entry, shell user unit and local PKGBUILD
- build and install Grassfield Settings in the desktop package
- build and install Grassfield Files (KIO) in the desktop package
- hardened grassfield-menu-bridge user unit, started before apps
- split icon package for the first third-party pack (since dropped), session icon files, pkgrel 4 (ADR-0017 I2)
- perceptual Apple-artwork detector for the icon-pack guard (work in progress)
- curated Apple-artwork blocklist, parallel detector, alias removal in the icon-pack guard
- session fontconfig preferring Inter, selected through FONTCONFIG_FILE
- GTK font defaults in the session dconf profile (Inter 10, grayscale, slight)
- icon theme composer and Apple-logo removal list
- split package grassfield-icons (composed MacTahoe + Pebble theme), grassfield-desktop depends on it
- final Apple-logo list from the by-eye sweep, signature guard, alias-only drops

#### files (9)

- KIO-backed launcher, folder and places models, file operations
- QML browser with icon, list and column views, tabs and sidebar
- Space and the item menu start Glance
- gallery view
- tag storage in user.xdg.tags
- colour tags in every view, Get Info and the sidebar, with tag search
- Customize Folder window, folder icons in every Files view, desktop folder looks, fr strings
- Customize Folder window fixes, File menu item, capture scripts, specs and fr strings
- grassfield-files --info shows only the Get Info window of each location

#### desktop (8)

- add desktop.showIcons setting and desktop icon tokens
- pure grid, rename, positions and URI logic for desktop icons
- desktop icons surface with selection, rename, menus, drag and drop and Dock Trash drop
- Space on a desktop icon toggles Glance
- click-to-focus desktop keyboard model (ADR-0012), grabbed popup menu, in-surface rename with A2 field colours
- Esc closes Glance, spec and ADR-0012 acceptance evidence, safe-mode section replaced
- follow the compositor desktop-focus policy
- the desktop's context menus follow macOS

#### wallpaper (8)

- contract keys, WallpaperConfig rules, stores and unit tests (ADR-0016 W1)
- grassfield-wallpaper helper (prepare, thumb, list) with gtest and ASan (ADR-0016 W2)
- picture and folder wallpapers on the desktop with crossfade, per-output prepare, state files (ADR-0016 W3, W4)
- Settings > Wallpaper pane with picture, folder and colour choices, French strings, e2e script (ADR-0016 W5)
- percentile tone and automatic frosted band for the menu bar, A2 generated wallpapers, specs and packaging (ADR-0016 W6)
- one two-slot model for the artwork, colours and pictures; slot probes for every kind transition
- online daily picture service, Settings section and About This Wallpaper (ADR-0016 O2/O3)
- online dev clock, disclosure reveal, 3-line tile label, visual tests and specs (ADR-0016 O1-O3)

#### overview (7)

- layout algorithm with tests and overview tokens
- Overview surface, Spaces bar, IPC target and platform helpers
- release keyboard before focusing, balanced row packing, event refresh
- balanced capture profile, spec notes and S4 results
- v2 shell side, real windows transformed by the compositor
- close focus through the plugin overview_focus verb, checked shell fallback, one selection across outputs
- full-width Desktops band, names under thumbnails, add button 18 from the edge, ring and name on the window active at open

#### dev (5)

- private D-Bus bus option for the nested shell; notifications and OSD specs
- fixed clock and wallpaper override hooks for visual tests
- visual fixtures and glyph-mask hooks for the visual suite
- --render-timing option for nested-up.sh and shell-run.sh (QSG_RENDER_TIMING set inside the script)
- provision the composed grassfield-icons theme (just icons), devenv.sh uses it when present

#### notifications (4)

- add body sanitizer and history model with unit tests
- add notification server, banners, history and Notification Center
- macOS 26 column of floating glass cards with per-card blur regions; specs, contrast regions, detail scenario
- macOS 26 clear model, no permanent Clear All pill

#### apps (4)

- paged Apps overlay with search, folders and persisted layout
- spec, backdrop dim for folders, cheaper per-keystroke rebuild
- application menus in the global menu bar (T1)
- floating launcher panel with category chips

#### widgets (4)

- widgets/1 registry, placements, grid and calendar logic with tokens and tests
- host, built-in widgets, Center widgets area, gallery and desktop layer
- separate keyboard-capable desktop menu window, active timer, qmlformat, widgets spec
- the gallery is a glass panel anchored bottom-left with its own blur region (F2c)

#### preview (4)

- add Preview viewer and Glance mode
- list the folder of a single opened file in the Files sort order
- macOS 26 browsing, floating toolbar capsules, thumbnail sidebar, info, slideshow, Glance arrows
- show the opened file at once, list its folder in a worker thread

#### icons (4)

- Breeze/Adwaita as the base for the plate measurements (wrapper theme, A2 fixtures, theme folder plate)
- Grassfield's own device glyphs shadow the Apple device pictures of Breeze and Adwaita (E27); executable shell tests
- icon modes apply from iconMode.minSize (24 px): smaller icons draw the Default artwork; A2 limits scoped and measured, per-mode N tiers, robust Files-row statistic, plate-less sample glyph
- Grassfield's apps, the Apps tile and the system tools take their icons from the pack

#### branding (3)

- add original symbolic icon set and provenance list
- Grassfield cursor sources and build script
- own org.grassfield.* app icons (Files folder, Settings, Preview), no Finder-like generic icon

#### search (3)

- add Search window with app, calculator, conversion, command, file and recent providers
- dev knobs for the files provider, tighter fuzzy matching and spec notes
- filter chips under the field and a No Results notice (F2c)

#### security (3)

- add session lock with PAM state machine and crash recovery
- add polkit authentication agent and dialog
- add idle dim and lock, and the lock-before-sleep inhibitor

#### platform (2)

- plugin minimize/restore with the Dock rectangle, push titlebar settings
- validated focusWindow(address) helper

#### i18n (2)

- Grassfield.I18n Translator module and catalog loading in shell and apps
- French catalog, lupdate/lrelease scripts and check-i18n gate (I1)

#### session (2)

- grassfield-icons wrapper theme and Qt session environment (ADR-0017 I1)
- locked dconf profile for the icon theme (ADR-0017 I3)

#### osd (1)

- add volume and brightness OSD with real-change IPC

#### controlcenter (1)

- connectivity, sound, now playing and brightness tiles with dev guards

#### menu-bridge (1)

- grassfield-menu-bridge daemon (C++/Qt, menu/1 socket)

#### quicksettings (1)

- floating glass modules on a 4-column grid, detail module, per-module blur regions

#### switcher (1)

- app switcher surface (SUPER+TAB, MRU apps, quick switch, key map release detection), tokens, spec, tests, fr strings

#### cursors (1)

- regenerate the cursor theme for the pointer colours at runtime

#### wallpaper-tool (1)

- fetch commons and latest (ADR-0016 O1)

#### wallpapers (1)

- the attribution links the licence and the source page

#### bridge (1)

- LauncherEntry badges, progress and urgent forwarded to the shell (ADR-0018)

### Fixes, by area

dock 29, shell 27, compositor 27, files 23, settings 19, ui 19, desktop 19, overview 15, packaging 15, dev 14, notifications 12, apps 12, preview 10, config 9, security 8, lock 8, platform 7, cursors 7, menubar 6, menu-bridge 6, wallpaper 6, search 4, widgets 4, i18n 4, pointer 4, switcher 3, controlcenter 2, store 2, visual 2, a2 2, overlay 2, forcequit 1, launchpad 1, test 1, autostart 1, quicksettings 1, branding 1, tokens 1, placement 1, bindings 1, glance 1, tests 1, wallpapers 1, wallpaper-tool 1, menus 1.

### Performance

- notifications: mirror center/banner keys so Notify no longer scans the models
- overview: bounded layout with direct row packing and timing tests
- notifications: drop stored rank/groupCount, O(1) group bookkeeping and ListView sections
- notifications: O(dropped) prune on insert, defer dismissing evicted notifications
- notifications: feed the Center only displayed rows, header inside the row delegate
- search: cache normalized fields and avoid localeCompare when ranking
- apps: keep one persistent cell per item so a search keystroke only moves cells
- apps: window cell slots, per-cell selection flag, char-mask ranking prefilter; Up reaches folder title
- files: compare only the active sort key while listing
- widgets: per-widget layer surfaces, hide when covered, shared System sampler, no gauge animation
- files: cache the selection's tag state; test(widgets): duplicate-uid parse checked by growth ratio
- apps: virtualised AppsGrid with pooled cells, panel perf harness
- lock: read one monitor map per answer while locked
- ui: plate analysis once per icon texture (icon_analysis.frag into a 2x1 texture), not 16 probes and a clustering per pixel
- ui: icon effects sample the Image texture; Apps frame analysis and Search transparency scripts
- compositor: damage the funnel band by band, not its whole bounding box
